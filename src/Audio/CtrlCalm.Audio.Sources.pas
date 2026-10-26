unit CtrlCalm.Audio.Sources;

{
  Audio sources produce PCM frames on demand for the streaming engine.

  All sources are used from the Ctrl+Calm worker thread only. They allocate
  their working memory once at construction; Fill never allocates.
}

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Winapi.MMSystem,
  CtrlCalm.Core.Types, CtrlCalm.Audio.Wav;

type
  TAudioFormat = record
    SampleRate: Cardinal;
    Channels: Word;
    BitsPerSample: Word;
    IsFloat: Boolean;
    function BlockAlign: Integer;
    function ToWaveFormatEx: TWaveFormatEx;
  end;

  IAudioSource = interface
    ['{6A0E3B1C-6D0B-4C77-9C8B-2F7B6B0F3E11}']
    function GetFormat: TAudioFormat;
    /// <summary>Writes exactly Frames frames to Dest. Looping sources never run
    /// out; on an I/O failure silence is written and Failed becomes True.</summary>
    procedure Fill(Dest: Pointer; Frames: Integer);
    function Failed: Boolean;
    function ErrorMessage: string;
    property Format: TAudioFormat read GetFormat;
  end;

  /// <summary>Streams a 16-bit PCM WAV file from disk and loops it seamlessly.
  /// The loop seam is an equal-power crossfade of the file's last
  /// CrossfadeFrames frames into its first CrossfadeFrames frames, so the
  /// steady-state loop is [X, L) with [L-X, L) blended against [0, X).</summary>
  TLoopingWavSource = class(TInterfacedObject, IAudioSource)
  private
    FStream: TFileStream;
    FInfo: TWavInfo;
    FFormat: TAudioFormat;
    FFrames: Int64;
    FXFade: Integer;
    FHead: TArray<SmallInt>;      // first FXFade frames, interleaved
    FFadeOut, FFadeIn: TArray<Single>;
    FScratch: TArray<SmallInt>;
    FPos: Int64;                  // next frame to read, 0..FFrames-1
    FStreamFrame: Int64;          // frame the file stream is positioned at (-1 unknown)
    FFailed: Boolean;
    FError: string;
    function ReadFrames(Dest: PSmallInt; FrameIndex: Int64; Count: Integer): Boolean;
  public
    const MaxChunkFrames = 48000;
    /// <summary>Raises EAudioSourceError if the file is missing or unsupported.</summary>
    constructor Create(const FileName: string; CrossfadeMs: Integer = 1500);
    destructor Destroy; override;
    function GetFormat: TAudioFormat;
    procedure Fill(Dest: Pointer; Frames: Integer);
    function Failed: Boolean;
    function ErrorMessage: string;
    property Info: TWavInfo read FInfo;
    property CrossfadeFrames: Integer read FXFade;
    property Position: Int64 read FPos;
  end;

  /// <summary>Deterministic xoshiro128** generator (public-domain algorithm by
  /// Blackman and Vigna). Small, fast and statistically strong.</summary>
  TXoshiro128 = record
  private
    S: array[0..3] of Cardinal;
  public
    procedure Seed(Value: UInt64);
    function Next: Cardinal; inline;
    /// <summary>Uniform in [-1, 1).</summary>
    function NextBipolar: Single; inline;
  end;

  /// <summary>Per-channel noise filter state.</summary>
  TNoiseChannel = record
    Rng: TXoshiro128;
    B0, B1, B2, B3, B4, B5, B6: Double;  // pink filter poles
    Brown: Double;                        // leaky integrator
    DcX, DcY: Double;                     // DC blocker
  end;

  /// <summary>Procedural white / pink / brown noise, stereo float32 at 48 kHz,
  /// with independent decorrelated generators per channel. Output is scaled to
  /// roughly -20 dBFS RMS so it sits at a similar level to recorded tracks.</summary>
  TNoiseSource = class(TInterfacedObject, IAudioSource)
  private
    FColor: TNoiseColor;
    FChannels: array[0..1] of TNoiseChannel;
    FGain: Double;
    function NextSample(var C: TNoiseChannel): Double; inline;
  public
    const SampleRate = 48000;
    constructor Create(Color: TNoiseColor; Seed: UInt64);
    function GetFormat: TAudioFormat;
    procedure Fill(Dest: Pointer; Frames: Integer);
    function Failed: Boolean;
    function ErrorMessage: string;
    property Color: TNoiseColor read FColor;
  end;

  EAudioSourceError = class(Exception);

/// <summary>Generates a short, soft two-tone chime (mono float32, 48 kHz) used
/// as the optional timer-completion sound.</summary>
function GenerateChime: TArray<Single>;

implementation

uses
  System.Math;

{ TAudioFormat }

function TAudioFormat.BlockAlign: Integer;
begin
  Result := Channels * (BitsPerSample div 8);
end;

function TAudioFormat.ToWaveFormatEx: TWaveFormatEx;
begin
  Result := Default(TWaveFormatEx);
  if IsFloat then
    Result.wFormatTag := $0003 // WAVE_FORMAT_IEEE_FLOAT
  else
    Result.wFormatTag := WAVE_FORMAT_PCM;
  Result.nChannels := Channels;
  Result.nSamplesPerSec := SampleRate;
  Result.wBitsPerSample := BitsPerSample;
  Result.nBlockAlign := BlockAlign;
  Result.nAvgBytesPerSec := SampleRate * Cardinal(BlockAlign);
  Result.cbSize := 0;
end;

{ TLoopingWavSource }

constructor TLoopingWavSource.Create(const FileName: string; CrossfadeMs: Integer);
var
  Err: string;
  I: Integer;
  T: Double;
begin
  inherited Create;
  FStreamFrame := -1;
  try
    FStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
      raise EAudioSourceError.Create('Cannot open ' + ExtractFileName(FileName) + ': ' + E.Message);
  end;
  if not ParseWav(FStream, FInfo, Err) then
    raise EAudioSourceError.Create(ExtractFileName(FileName) + ': ' + Err);
  FFrames := FInfo.FrameCount;
  if FFrames < FInfo.SampleRate div 2 then
    raise EAudioSourceError.Create(ExtractFileName(FileName) + ': loop is shorter than 0.5 s');

  FFormat.SampleRate := FInfo.SampleRate;
  FFormat.Channels := FInfo.Channels;
  FFormat.BitsPerSample := 16;
  FFormat.IsFloat := False;

  FXFade := MulDiv(FInfo.SampleRate, Max(CrossfadeMs, 0), 1000);
  FXFade := Min(FXFade, Integer(FFrames div 4));

  SetLength(FScratch, MaxChunkFrames * FInfo.Channels);
  if FXFade > 0 then
  begin
    SetLength(FHead, FXFade * FInfo.Channels);
    if not ReadFrames(@FHead[0], 0, FXFade) then
      raise EAudioSourceError.Create(ExtractFileName(FileName) + ': ' + FError);
    SetLength(FFadeOut, FXFade);
    SetLength(FFadeIn, FXFade);
    for I := 0 to FXFade - 1 do
    begin
      T := (I + 0.5) / FXFade;
      FFadeOut[I] := Cos(T * Pi / 2);
      FFadeIn[I] := Sin(T * Pi / 2);
    end;
  end;
  FPos := 0;
end;

destructor TLoopingWavSource.Destroy;
begin
  FStream.Free;
  inherited;
end;

function TLoopingWavSource.ReadFrames(Dest: PSmallInt; FrameIndex: Int64; Count: Integer): Boolean;
var
  Bytes, Got: Integer;
begin
  Result := False;
  try
    if FStreamFrame <> FrameIndex then
      FStream.Position := FInfo.DataOffset + FrameIndex * FInfo.BlockAlign;
    Bytes := Count * FInfo.BlockAlign;
    Got := FStream.Read(Dest^, Bytes);
    if Got <> Bytes then
    begin
      FStreamFrame := -1;
      FError := 'Unexpected end of audio data';
      Exit;
    end;
    FStreamFrame := FrameIndex + Count;
    Result := True;
  except
    on E: Exception do
    begin
      FStreamFrame := -1;
      FError := E.Message;
    end;
  end;
end;

procedure TLoopingWavSource.Fill(Dest: Pointer; Frames: Integer);
var
  POut: PSmallInt;
  N, Ch, K, I, HeadIndex: Integer;
  XStart: Int64;
  V: Single;
begin
  POut := Dest;
  Ch := FInfo.Channels;
  if FFailed then
  begin
    FillChar(Dest^, Frames * FInfo.BlockAlign, 0);
    Exit;
  end;
  XStart := FFrames - FXFade;
  while Frames > 0 do
  begin
    if FPos < XStart then
    begin
      N := Integer(Min(Int64(Min(Frames, MaxChunkFrames)), XStart - FPos));
      if not ReadFrames(POut, FPos, N) then
      begin
        FFailed := True;
        FillChar(POut^, Frames * FInfo.BlockAlign, 0);
        Exit;
      end;
      Inc(POut, N * Ch);
      Inc(FPos, N);
    end
    else
    begin
      // Inside the crossfade region: blend the tail with the cached head.
      N := Integer(Min(Int64(Min(Frames, MaxChunkFrames)), FFrames - FPos));
      if not ReadFrames(@FScratch[0], FPos, N) then
      begin
        FFailed := True;
        FillChar(POut^, Frames * FInfo.BlockAlign, 0);
        Exit;
      end;
      HeadIndex := Integer(FPos - XStart);
      for K := 0 to N - 1 do
        for I := 0 to Ch - 1 do
        begin
          V := FScratch[K * Ch + I] * FFadeOut[HeadIndex + K] +
               FHead[(HeadIndex + K) * Ch + I] * FFadeIn[HeadIndex + K];
          if V > 32767 then V := 32767 else if V < -32768 then V := -32768;
          POut^ := Round(V);
          Inc(POut);
        end;
      Inc(FPos, N);
      if FPos >= FFrames then
        FPos := FXFade; // continue right after the head that was just faded in
    end;
    Dec(Frames, N);
  end;
end;

function TLoopingWavSource.Failed: Boolean;
begin
  Result := FFailed;
end;

function TLoopingWavSource.ErrorMessage: string;
begin
  Result := FError;
end;

function TLoopingWavSource.GetFormat: TAudioFormat;
begin
  Result := FFormat;
end;

{ TXoshiro128 }

procedure TXoshiro128.Seed(Value: UInt64);
var
  I: Integer;
  Z: UInt64;
begin
  // SplitMix64 expansion of the seed, as recommended by the algorithm authors.
  for I := 0 to 3 do
  begin
    Value := Value + UInt64($9E3779B97F4A7C15);
    Z := Value;
    Z := (Z xor (Z shr 30)) * UInt64($BF58476D1CE4E5B9);
    Z := (Z xor (Z shr 27)) * UInt64($94D049BB133111EB);
    Z := Z xor (Z shr 31);
    S[I] := Cardinal(Z);
  end;
  if (S[0] or S[1] or S[2] or S[3]) = 0 then
    S[0] := 1;
end;

function TXoshiro128.Next: Cardinal;
var
  T, R: Cardinal;
begin
  R := S[1] * 5;
  R := ((R shl 7) or (R shr 25)) * 9;
  T := S[1] shl 9;
  S[2] := S[2] xor S[0];
  S[3] := S[3] xor S[1];
  S[1] := S[1] xor S[2];
  S[0] := S[0] xor S[3];
  S[2] := S[2] xor T;
  S[3] := (S[3] shl 11) or (S[3] shr 21);
  Result := R;
end;

function TXoshiro128.NextBipolar: Single;
begin
  // 24 random bits -> [0, 1) -> [-1, 1)
  Result := (Next shr 8) * (2.0 / 16777216.0) - 1.0;
end;

{ TNoiseSource }

constructor TNoiseSource.Create(Color: TNoiseColor; Seed: UInt64);
var
  I: Integer;
begin
  inherited Create;
  FColor := Color;
  for I := 0 to 1 do
  begin
    FChannels[I] := Default(TNoiseChannel);
    FChannels[I].Rng.Seed(Seed * 2 + UInt64(I) + 1);
  end;
  // Gains calibrated by tests/AudioTests so each colour lands near 0.1 RMS
  // (-20 dBFS). Uniform white noise has RMS 1/sqrt(3).
  case Color of
    ncWhite: FGain := 0.1 * Sqrt(3);
    ncPink:  FGain := 0.547;
    ncBrown: FGain := 0.628;
  end;
end;

function TNoiseSource.NextSample(var C: TNoiseChannel): Double;
var
  W, X: Double;
begin
  W := C.Rng.NextBipolar;
  case FColor of
    ncWhite:
      X := W;
    ncPink:
      begin
        // Paul Kellet's refined pink filter: a sum of first-order low-passes
        // approximating a -3 dB/octave slope to within +/-0.05 dB above 9.2 Hz
        // (at 44.1 kHz; the deviation at 48 kHz is negligible).
        C.B0 := 0.99886 * C.B0 + W * 0.0555179;
        C.B1 := 0.99332 * C.B1 + W * 0.0750759;
        C.B2 := 0.96900 * C.B2 + W * 0.1538520;
        C.B3 := 0.86650 * C.B3 + W * 0.3104856;
        C.B4 := 0.55000 * C.B4 + W * 0.5329522;
        C.B5 := -0.7616 * C.B5 - W * 0.0168980;
        X := C.B0 + C.B1 + C.B2 + C.B3 + C.B4 + C.B5 + C.B6 + W * 0.5362;
        C.B6 := W * 0.115926;
        X := X * 0.11;
      end;
    ncBrown:
      begin
        // Leaky integrator: -6 dB/octave above ~15 Hz, bounded (no random-walk
        // drift) because the pole sits inside the unit circle.
        C.Brown := 0.998 * C.Brown + W * 0.02;
        X := C.Brown;
      end;
  else
    X := 0;
  end;
  // One-pole DC blocker (~5 Hz) keeps the long-term mean at zero.
  C.DcY := X - C.DcX + 0.99935 * C.DcY;
  C.DcX := X;
  Result := C.DcY;
end;

procedure TNoiseSource.Fill(Dest: Pointer; Frames: Integer);
var
  P: PSingle;
  I, Ch: Integer;
  V: Double;
begin
  P := Dest;
  for I := 0 to Frames - 1 do
    for Ch := 0 to 1 do
    begin
      V := NextSample(FChannels[Ch]) * FGain;
      if V > 1 then V := 1 else if V < -1 then V := -1;
      P^ := V;
      Inc(P);
    end;
end;

function TNoiseSource.Failed: Boolean;
begin
  Result := False;
end;

function TNoiseSource.ErrorMessage: string;
begin
  Result := '';
end;

function TNoiseSource.GetFormat: TAudioFormat;
begin
  Result.SampleRate := SampleRate;
  Result.Channels := 2;
  Result.BitsPerSample := 32;
  Result.IsFloat := True;
end;

function GenerateChime: TArray<Single>;
const
  Rate = 48000;
  Notes: array[0..1] of Double = (880.0, 1318.51); // A5, E6
  NoteStart: array[0..1] of Double = (0.0, 0.18);
  Length = 1.6;
var
  N, I, K: Integer;
  T, Env, V, Local: Double;
begin
  N := Round(Rate * Length);
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    T := I / Rate;
    V := 0;
    for K := 0 to High(Notes) do
    begin
      Local := T - NoteStart[K];
      if Local < 0 then
        Continue;
      // 5 ms attack, exponential decay; soft partial at 2x for a bell colour.
      Env := Min(1.0, Local / 0.005) * Exp(-Local * 3.2);
      V := V + Env * (Sin(2 * Pi * Notes[K] * Local) + 0.25 * Sin(4 * Pi * Notes[K] * Local));
    end;
    // Gentle fade at the very end so the buffer stops at zero.
    if T > Length - 0.05 then
      V := V * (Length - T) / 0.05;
    Result[I] := V * 0.4;
  end;
end;

end.
