unit CtrlCalm.Tests.Audio;

interface

var
  /// <summary>False when the run was started with /nodevice.</summary>
  DeviceTestsEnabled: Boolean = True;

implementation

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes, System.Math, System.IOUtils,
  CtrlCalm.TestFramework, CtrlCalm.TestUtils, CtrlCalm.Core.Types, CtrlCalm.Audio.Wav,
  CtrlCalm.Audio.Sources, CtrlCalm.Audio.Engine, CtrlCalm.Audio.XAudio2;

function Ramp(Frame, Channel: Integer): SmallInt;
begin
  // A deterministic, non-periodic pattern so that every frame is distinguishable.
  Result := SmallInt(((Frame * 37 + Channel * 1001) mod 30000) - 15000);
end;

function ParseBuilder(B: TWavBuilder; out Info: TWavInfo; out Err: string; RiffSize: Int64 = -1): Boolean;
var
  F: string;
begin
  F := TPath.Combine(TPath.GetTempPath, 'cc-wavtest.wav');
  B.SaveRiff(F, RiffSize);
  try
    Result := ParseWavFile(F, Info, Err);
  finally
    DeleteFile(F);
  end;
end;

procedure ExpectReject(const Name: string; const Build: TProc<TWavBuilder>);
var
  B: TWavBuilder;
  Info: TWavInfo;
  Err: string;
begin
  B := TWavBuilder.Create;
  try
    Build(B);
    Check(not ParseBuilder(B, Info, Err), Name + ' should be rejected');
    Check(Err <> '', Name + ' needs a reason');
  finally
    B.Free;
  end;
end;

{ Spectrum helpers }

procedure FFT(var Re, Im: TArray<Double>);
var
  N, I, J, K, M, Step: Integer;
  Ang, WR, WI, TR, TI, UR, UI: Double;
begin
  N := Length(Re);
  J := 0;
  for I := 0 to N - 2 do
  begin
    if I < J then
    begin
      TR := Re[I]; Re[I] := Re[J]; Re[J] := TR;
      TI := Im[I]; Im[I] := Im[J]; Im[J] := TI;
    end;
    K := N shr 1;
    while K <= J do
    begin
      Dec(J, K);
      K := K shr 1;
    end;
    Inc(J, K);
  end;
  Step := 1;
  while Step < N do
  begin
    Ang := -Pi / Step;
    for M := 0 to Step - 1 do
    begin
      WR := Cos(Ang * M);
      WI := Sin(Ang * M);
      I := M;
      while I < N do
      begin
        J := I + Step;
        TR := WR * Re[J] - WI * Im[J];
        TI := WR * Im[J] + WI * Re[J];
        UR := Re[I];
        UI := Im[I];
        Re[I] := UR + TR;
        Im[I] := UI + TI;
        Re[J] := UR - TR;
        Im[J] := UI - TI;
        Inc(I, Step * 2);
      end;
    end;
    Step := Step * 2;
  end;
end;

/// <summary>Welch-averaged power spectrum slope (dB per octave) between 250 Hz
/// and 8 kHz, using the mean PSD of each octave band.</summary>
function SpectralSlope(const X: TArray<Single>; Rate: Integer): Double;
const
  N = 4096;
var
  Psd: TArray<Double>;
  Re, Im: TArray<Double>;
  Seg, Segs, I, B, Lo, Hi: Integer;
  W: Double;
  BandDb: array[0..4] of Double;
  SX, SY, SXX, SXY: Double;
begin
  SetLength(Psd, N div 2);
  Segs := Length(X) div N;
  for Seg := 0 to Segs - 1 do
  begin
    SetLength(Re, N);
    SetLength(Im, N);
    for I := 0 to N - 1 do
    begin
      W := 0.5 - 0.5 * Cos(2 * Pi * I / (N - 1)); // Hann window
      Re[I] := X[Seg * N + I] * W;
      Im[I] := 0;
    end;
    FFT(Re, Im);
    for I := 0 to N div 2 - 1 do
      Psd[I] := Psd[I] + Sqr(Re[I]) + Sqr(Im[I]);
  end;
  for B := 0 to 4 do
  begin
    Lo := Round(250 * Power(2, B) * N / Rate);
    Hi := Round(500 * Power(2, B) * N / Rate);
    W := 0;
    for I := Lo to Hi - 1 do
      W := W + Psd[I];
    BandDb[B] := 10 * Log10(W / (Hi - Lo));
  end;
  SX := 0; SY := 0; SXX := 0; SXY := 0;
  for B := 0 to 4 do
  begin
    SX := SX + B;
    SY := SY + BandDb[B];
    SXX := SXX + B * B;
    SXY := SXY + B * BandDb[B];
  end;
  Result := (5 * SXY - SX * SY) / (5 * SXX - SX * SX);
end;

function NoiseSamples(Color: TNoiseColor; Seed: UInt64; Frames: Integer; Channel: Integer = 0): TArray<Single>;
var
  Src: TNoiseSource;
  Buf: TArray<Single>;
  I: Integer;
begin
  Src := TNoiseSource.Create(Color, Seed);
  try
    SetLength(Buf, Frames * 2);
    Src.Fill(@Buf[0], Frames);
  finally
    Src.Free;
  end;
  SetLength(Result, Frames);
  for I := 0 to Frames - 1 do
    Result[I] := Buf[I * 2 + Channel];
end;

procedure Register;
begin
  RegisterTest('Audio.Wav', 'ParsesCanonicalHeader',
    procedure
    var
      B: TWavBuilder;
      Info: TWavInfo;
      Err: string;
    begin
      B := TWavBuilder.Create;
      try
        B.Fmt(1, 2, 48000, 16);
        B.Data(4800, 2, Ramp);
        Check(ParseBuilder(B, Info, Err), Err);
        CheckEquals(2, Info.Channels);
        CheckEquals(48000, Info.SampleRate);
        CheckEquals(4800, Info.FrameCount);
        CheckEquals(44, Info.DataOffset, 'canonical layout');
        CheckNear(0.1, Info.DurationSeconds, 1E-9);
      finally
        B.Free;
      end;
    end);

  RegisterTest('Audio.Wav', 'TraversesExtraAndOddSizedChunks',
    procedure
    var
      B: TWavBuilder;
      Info: TWavInfo;
      Err: string;
    begin
      B := TWavBuilder.Create;
      try
        B.Chunk('LIST', 26);
        B.Chunk('junk', 5);        // odd size: one pad byte follows
        B.Fmt(1, 1, 44100, 16);
        B.Chunk('fact', 4);
        B.Chunk('bext', 3);
        B.Data(1000, 1, Ramp);
        B.Chunk('cue ', 12);       // trailing chunk after data
        Check(ParseBuilder(B, Info, Err), Err);
        CheckEquals(1000, Info.FrameCount);
        CheckEquals(12 + 8 + 26 + 8 + 6 + 8 + 16 + 8 + 4 + 8 + 4 + 8, Info.DataOffset, 'offset after chunks');
      finally
        B.Free;
      end;
    end);

  RegisterTest('Audio.Wav', 'AcceptsExtensiblePcm',
    procedure
    var
      B: TWavBuilder;
      Info: TWavInfo;
      Err: string;
    begin
      B := TWavBuilder.Create;
      try
        B.FmtExtensible(2, 48000, 16, SubtypePCM);
        B.Data(2000, 2, Ramp);
        Check(ParseBuilder(B, Info, Err), Err);
        CheckEquals(2000, Info.FrameCount);
      finally
        B.Free;
      end;
    end);

  RegisterTest('Audio.Wav', 'ClampsTruncatedDataChunk',
    procedure
    var
      B: TWavBuilder;
      Info: TWavInfo;
      Err: string;
    begin
      B := TWavBuilder.Create;
      try
        B.Fmt(1, 2, 48000, 16);
        B.Data(1001, 2, Ramp, 1000000); // header claims far more than exists
        B.Bytes([1, 2]);                // plus a partial frame
        Check(ParseBuilder(B, Info, Err, 4 + 24 + 8 + 1000000), Err);
        CheckEquals(1001, Info.FrameCount, 'only whole frames that exist');
      finally
        B.Free;
      end;
    end);

  RegisterTest('Audio.Wav', 'RejectsMalformedAndUnsupported',
    procedure
    var
      F: string;
      Info: TWavInfo;
      Err: string;
    begin
      ExpectReject('8-bit', procedure(B: TWavBuilder) begin B.Fmt(1, 1, 44100, 8); B.Data(100, 1, Ramp); end);
      ExpectReject('24-bit', procedure(B: TWavBuilder) begin B.Fmt(1, 2, 48000, 24); B.Data(100, 3, Ramp); end);
      ExpectReject('6 channels', procedure(B: TWavBuilder) begin B.Fmt(1, 6, 48000, 16); B.Data(100, 6, Ramp); end);
      ExpectReject('float tag', procedure(B: TWavBuilder) begin B.Fmt(3, 2, 48000, 32); B.Data(100, 4, Ramp); end);
      ExpectReject('extensible float', procedure(B: TWavBuilder) begin B.FmtExtensible(2, 48000, 16, SubtypeFloat); B.Data(100, 2, Ramp); end);
      ExpectReject('ADPCM', procedure(B: TWavBuilder) begin B.Fmt(2, 2, 48000, 16); B.Data(100, 2, Ramp); end);
      ExpectReject('missing data', procedure(B: TWavBuilder) begin B.Fmt(1, 2, 48000, 16); end);
      ExpectReject('missing fmt', procedure(B: TWavBuilder) begin B.Data(100, 2, Ramp); end);
      ExpectReject('no samples', procedure(B: TWavBuilder) begin B.Fmt(1, 2, 48000, 16); B.Data(0, 2, Ramp); end);
      ExpectReject('sample rate', procedure(B: TWavBuilder) begin B.Fmt(1, 2, 4000, 16); B.Data(100, 2, Ramp); end);
      ExpectReject('duplicate fmt', procedure(B: TWavBuilder) begin B.Fmt(1, 2, 48000, 16); B.Fmt(1, 2, 48000, 16); B.Data(100, 2, Ramp); end);
      ExpectReject('chunk past end', procedure(B: TWavBuilder) begin B.Fmt(1, 2, 48000, 16); B.Chunk('LIST', 999999, 10); end);
      ExpectReject('fmt too small', procedure(B: TWavBuilder) begin B.Chunk('fmt ', 8); B.Data(100, 2, Ramp); end);
      ExpectReject('block align', procedure(B: TWavBuilder)
        begin
          B.Tag('fmt '); B.U32(16); B.U16(1); B.U16(2); B.U32(48000); B.U32(192000); B.U16(3); B.U16(16);
          B.Data(100, 2, Ramp);
        end);
      // Not RIFF / not WAVE / empty / garbage
      F := TPath.Combine(TPath.GetTempPath, 'cc-bad.wav');
      TFile.WriteAllBytes(F, TEncoding.ASCII.GetBytes('RIFX....WAVEfmt '));
      Check(not ParseWavFile(F, Info, Err), 'RIFX');
      TFile.WriteAllBytes(F, TEncoding.ASCII.GetBytes('RIFF....AVI LIST'));
      Check(not ParseWavFile(F, Info, Err), 'AVI');
      TFile.WriteAllBytes(F, []);
      Check(not ParseWavFile(F, Info, Err), 'empty');
      TFile.WriteAllBytes(F, TEncoding.ASCII.GetBytes('RIFF'));
      Check(not ParseWavFile(F, Info, Err), 'truncated header');
      DeleteFile(F);
      Check(not ParseWavFile(F, Info, Err), 'missing file');
      Check(Pos('not found', Err) > 0, 'missing file message');
    end);

  RegisterTest('Audio.Loop', 'SeamIsEqualPowerCrossfade',
    procedure
    const
      Rate = 8000;
      Frames = 8000;   // 1.0 s
      XfMs = 250;      // 2000 frames
    var
      F: string;
      Src: TLoopingWavSource;
      Buf: TArray<SmallInt>;
      I, X, L, Idx: Integer;
      T, Expected: Double;
    begin
      F := TPath.Combine(TPath.GetTempPath, 'cc-loop.wav');
      WriteSimpleWav(F, Rate, 1, Frames, Ramp);
      Src := TLoopingWavSource.Create(F, XfMs);
      try
        X := Src.CrossfadeFrames;
        L := Frames;
        CheckEquals(2000, X, 'crossfade length');
        SetLength(Buf, L * 3);
        Src.Fill(@Buf[0], L * 3);
        // First pass: plain file data up to the crossfade region.
        for I := 0 to L - X - 1 do
          CheckEquals(Ramp(I, 0), Buf[I], 'first pass frame ' + IntToStr(I));
        // Crossfade region: tail fading out, head fading in.
        for I := 0 to X - 1 do
        begin
          T := (I + 0.5) / X;
          Expected := Ramp(L - X + I, 0) * Cos(T * Pi / 2) + Ramp(I, 0) * Sin(T * Pi / 2);
          CheckNear(Expected, Buf[L - X + I], 1.01, 'blend frame ' + IntToStr(I));
        end;
        // After the seam playback continues at frame X (right after the head).
        Idx := L;
        for I := X to L - X - 1 do
        begin
          CheckEquals(Ramp(I, 0), Buf[Idx], 'second pass frame ' + IntToStr(I));
          Inc(Idx);
        end;
      finally
        Src.Free;
        DeleteFile(F);
      end;
    end);

  RegisterTest('Audio.Loop', 'BufferBoundariesDoNotChangeOutput',
    procedure
    var
      F: string;
      A, B: TLoopingWavSource;
      Whole, Pieces: TArray<SmallInt>;
      Pos, N, K, Total: Integer;
      Sizes: TArray<Integer>;
    begin
      F := TPath.Combine(TPath.GetTempPath, 'cc-bounds.wav');
      WriteSimpleWav(F, 44100, 2, 30000, Ramp);
      Total := 200000; // several loops
      A := TLoopingWavSource.Create(F, 100);
      B := TLoopingWavSource.Create(F, 100);
      try
        SetLength(Whole, Total * 2);
        A.Fill(@Whole[0], Total);
        SetLength(Pieces, Total * 2);
        Sizes := [1, 7, 4096, 48003, 3, 17640, 999, 2];
        Pos := 0;
        K := 0;
        while Pos < Total do
        begin
          N := Min(Sizes[K mod Length(Sizes)], Total - Pos);
          B.Fill(@Pieces[Pos * 2], N);
          Inc(Pos, N);
          Inc(K);
        end;
        for Pos := 0 to High(Whole) do
          if Whole[Pos] <> Pieces[Pos] then
            Fail('sample ' + IntToStr(Pos) + ' differs');
        Check(not A.Failed and not B.Failed);
      finally
        A.Free;
        B.Free;
        DeleteFile(F);
      end;
    end);

  RegisterTest('Audio.Loop', 'MissingOrTooShortFilesRaiseCleanly',
    procedure
    var
      F: string;
    begin
      CheckRaises(procedure begin TLoopingWavSource.Create('Z:\nope\none.wav').Free; end, EAudioSourceError, 'missing');
      F := TPath.Combine(TPath.GetTempPath, 'cc-short.wav');
      WriteSimpleWav(F, 48000, 2, 1000, Ramp);
      try
        CheckRaises(procedure begin TLoopingWavSource.Create(F).Free; end, EAudioSourceError, 'too short');
      finally
        DeleteFile(F);
      end;
    end);

  RegisterTest('Audio.Noise', 'LevelsMeanAndNoClipping',
    procedure
    var
      C: TNoiseColor;
      X: TArray<Single>;
      I: Integer;
      Sum, SumSq, Peak, Mean, Rms: Double;
    const
      Names: array[TNoiseColor] of string = ('white', 'pink', 'brown');
    begin
      for C := Low(TNoiseColor) to High(TNoiseColor) do
      begin
        X := NoiseSamples(C, 1234, 48000 * 20);
        Sum := 0; SumSq := 0; Peak := 0;
        for I := 0 to High(X) do
        begin
          Sum := Sum + X[I];
          SumSq := SumSq + Sqr(X[I]);
          Peak := Max(Peak, Abs(X[I]));
        end;
        Mean := Sum / Length(X);
        Rms := Sqrt(SumSq / Length(X));
        Report('noise.' + Names[C], Format('rms=%.4f (%.1f dBFS) peak=%.3f mean=%.5f',
          [Rms, 20 * Log10(Rms), Peak, Mean]));
        Check(Abs(Mean) < 0.05 * Rms, Names[C] + ' DC offset');
        Check((Rms > 0.07) and (Rms < 0.14), Names[C] + ' level near -20 dBFS');
        Check(Peak < 0.99, Names[C] + ' clipping');
      end;
    end);

  RegisterTest('Audio.Noise', 'SpectralSlopesMatchColour',
    procedure
    var
      W, P, B: Double;
    begin
      W := SpectralSlope(NoiseSamples(ncWhite, 7, 48000 * 8), 48000);
      P := SpectralSlope(NoiseSamples(ncPink, 7, 48000 * 8), 48000);
      B := SpectralSlope(NoiseSamples(ncBrown, 7, 48000 * 8), 48000);
      Report('noise.slope', Format('white=%.2f pink=%.2f brown=%.2f dB/octave', [W, P, B]));
      CheckNear(0, W, 0.5, 'white flat');
      CheckNear(-3.01, P, 0.6, 'pink -3 dB/octave');
      CheckNear(-6.02, B, 0.8, 'brown -6 dB/octave');
    end);

  RegisterTest('Audio.Noise', 'DeterministicContinuousAndDecorrelated',
    procedure
    var
      A, B, L, R: TArray<Single>;
      Src: TNoiseSource;
      Whole, Parts: TArray<Single>;
      I: Integer;
      SLR, SLL, SRR: Double;
    begin
      A := NoiseSamples(ncPink, 99, 10000);
      B := NoiseSamples(ncPink, 99, 10000);
      for I := 0 to High(A) do
        if A[I] <> B[I] then
          Fail('same seed must reproduce');
      B := NoiseSamples(ncPink, 100, 10000);
      Check(A[5000] <> B[5000], 'different seed');
      // Continuity: one big fill equals many small ones.
      SetLength(Whole, 20000);
      SetLength(Parts, 20000);
      Src := TNoiseSource.Create(ncBrown, 5);
      try
        Src.Fill(@Whole[0], 10000);
      finally
        Src.Free;
      end;
      Src := TNoiseSource.Create(ncBrown, 5);
      try
        for I := 0 to 9 do
          Src.Fill(@Parts[I * 2000], 1000);
      finally
        Src.Free;
      end;
      for I := 0 to High(Whole) do
        if Whole[I] <> Parts[I] then
          Fail('fills must be continuous');
      // Stereo channels come from independent generators.
      L := NoiseSamples(ncWhite, 3, 100000, 0);
      R := NoiseSamples(ncWhite, 3, 100000, 1);
      SLR := 0; SLL := 0; SRR := 0;
      for I := 0 to High(L) do
      begin
        SLR := SLR + L[I] * R[I];
        SLL := SLL + L[I] * L[I];
        SRR := SRR + R[I] * R[I];
      end;
      Check(Abs(SLR / Sqrt(SLL * SRR)) < 0.02, 'channels decorrelated');
    end);

  RegisterTest('Audio.Noise', 'BrownNoiseHasNoLongTermDrift',
    procedure
    var
      X: TArray<Single>;
      I, Blk: Integer;
      Mean: Double;
    begin
      X := NoiseSamples(ncBrown, 42, 48000 * 120); // two minutes
      for Blk := 0 to 11 do
      begin
        Mean := 0;
        for I := Blk * 480000 to (Blk + 1) * 480000 - 1 do
          Mean := Mean + X[I];
        Mean := Mean / 480000;
        Check(Abs(Mean) < 0.01, Format('10 s block %d mean %.4f', [Blk, Mean]));
      end;
    end);

  RegisterTest('Audio.Engine', 'RampReachesTargetExactly',
    procedure
    var
      R: TRamp;
      Steps: Integer;
    begin
      R.Init(0);
      R.MoveTo(1, 100);
      Steps := 0;
      while R.Advance(15) do
        Inc(Steps);
      CheckNear(1, R.Value, 0, 'target');
      CheckEquals(6, Steps, 'about 100 ms of 15 ms ticks');
      R.MoveTo(0.25, 0);
      CheckNear(0.25, R.Value, 0, 'immediate');
      R.MoveTo(1, 1000);
      R.Advance(500);
      CheckNear(0.625, R.Value, 1E-6, 'linear midpoint');
    end);

  RegisterTest('Audio.Engine', 'TrackStatesAndHeadroomWithoutDevice',
    procedure
    var
      Wake: THandle;
      E: TAudioEngine;
      Folder: string;
      S: TSoundId;
      I: Integer;
    begin
      Folder := NewTempFolder('cc-nosounds'); // recorded sounds are absent
      Wake := CreateEvent(nil, False, False, nil);
      E := TAudioEngine.Create(Wake, Folder);
      try
        E.DisableDevice;
        E.ProbeSources;
        Check(E.TrackState(sndRain) = tsUnavailable, 'missing file is unavailable');
        Check(Pos('not found', E.TrackError(sndRain)) > 0, 'reason');
        Check(E.TrackState(sndPinkNoise) = tsStopped, 'procedural is available');
        E.Activate(sndRain, 0.5, 100);
        Check(E.TrackState(sndRain) = tsUnavailable, 'activation of a missing sound is refused');
        E.Activate(sndPinkNoise, 0.5, 100);
        Check(E.TrackState(sndPinkNoise) = tsStarting, 'starting');
        for I := 1 to 20 do
        begin
          E.Process;
          Sleep(10);
        end;
        Check(E.TrackState(sndPinkNoise) = tsPlaying, 'playing after the fade');
        E.Deactivate(sndPinkNoise, 50);
        Check(E.TrackState(sndPinkNoise) = tsStopping, 'stopping');
        for I := 1 to 10 do
        begin
          E.Process;
          Sleep(10);
        end;
        Check(E.TrackState(sndPinkNoise) = tsStopped, 'stopped');
        // Headroom: all three noises at full volume exceed the ceiling.
        for S := sndWhiteNoise to sndBrownNoise do
          E.Activate(S, 1.0, 0);
        E.Process;
        Check(E.Headroom < 1, 'headroom engaged');
        CheckNear(HeadroomCeiling / Sqrt(3), E.Headroom, 1E-4, 'power-sum headroom');
        E.StopAll(0);
        E.Process;
        CheckNear(1, E.Headroom, 0, 'released');
      finally
        E.Free;
        CloseHandle(Wake);
        TDirectory.Delete(Folder, True);
      end;
    end);

  RegisterTest('Audio.Device', 'RepeatedInitAndShutdownAreClean',
    procedure
    var
      Wake: THandle;
      E: TAudioEngine;
      I: Integer;
      Before, After: UInt64;
    begin
      if not DeviceTestsEnabled or not CC_XAudio2Available then
      begin
        Report('Audio.Device', 'skipped (no device requested or XAudio2 missing)');
        Exit;
      end;
      Wake := CreateEvent(nil, False, False, nil);
      try
        Before := ProcessPrivateBytes;
        for I := 1 to 10 do
        begin
          E := TAudioEngine.Create(Wake, TPath.GetTempPath);
          try
            E.SetMasterVolume(0, 0); // silent: this test is about lifecycle
            E.Activate(sndBrownNoise, 0.5, 20);
            E.Process;
            Check(E.Status = asReady, 'engine ready: ' + E.StatusText);
            WaitForSingleObject(Wake, 50);
            E.Process;
            E.Shutdown;
            Check(E.Status = asShutDown);
            E.Shutdown; // idempotent
          finally
            E.Free;
          end;
        end;
        After := ProcessPrivateBytes;
        Report('engine.init-shutdown x10', Format('private bytes delta %d KB', [Int64(After - Before) div 1024]));
      finally
        CloseHandle(Wake);
      end;
    end);
end;

initialization
  Register;

end.
