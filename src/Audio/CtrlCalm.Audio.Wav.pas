unit CtrlCalm.Audio.Wav;

{
  RIFF/WAVE header parsing with full chunk traversal.

  Supported input (documented in docs/AUDIO_ENGINE.md):
  - WAVE_FORMAT_PCM, or WAVE_FORMAT_EXTENSIBLE with the PCM sub-format
  - 16-bit signed little-endian samples
  - 1 or 2 channels
  - 8 000 .. 192 000 Hz (XAudio2 resamples to the device rate)
  Anything else is rejected with a descriptive error; nothing here raises on
  malformed input.
}

interface

uses
  System.SysUtils, System.Classes;

type
  TWavInfo = record
    FormatTag: Word;
    Channels: Word;
    SampleRate: Cardinal;
    BitsPerSample: Word;
    BlockAlign: Word;
    DataOffset: Int64;   // absolute file offset of the first sample
    DataBytes: Int64;    // whole frames only
    function FrameCount: Int64;
    function DurationSeconds: Double;
  end;

const
  MinWavSampleRate = 8000;
  MaxWavSampleRate = 192000;

/// <summary>Parses a RIFF/WAVE stream. Returns False with a reason on any
/// malformed or unsupported input. The stream position is left undefined.</summary>
function ParseWav(Stream: TStream; out Info: TWavInfo; out Error: string): Boolean;

function ParseWavFile(const FileName: string; out Info: TWavInfo; out Error: string): Boolean;

implementation

const
  WAVE_FORMAT_PCM_TAG = $0001;
  WAVE_FORMAT_EXTENSIBLE_TAG = $FFFE;
  // KSDATAFORMAT_SUBTYPE_PCM
  SubtypePCM: TGUID = '{00000001-0000-0010-8000-00AA00389B71}';

type
  TChunkHeader = packed record
    Id: array[0..3] of AnsiChar;
    Size: Cardinal;
  end;

function TWavInfo.FrameCount: Int64;
begin
  if BlockAlign = 0 then
    Result := 0
  else
    Result := DataBytes div BlockAlign;
end;

function TWavInfo.DurationSeconds: Double;
begin
  if SampleRate = 0 then
    Result := 0
  else
    Result := FrameCount / SampleRate;
end;

function ReadExact(Stream: TStream; var Buffer; Count: Integer): Boolean;
begin
  Result := Stream.Read(Buffer, Count) = Count;
end;

function ParseWav(Stream: TStream; out Info: TWavInfo; out Error: string): Boolean;
var
  Riff: TChunkHeader;
  WaveId: array[0..3] of AnsiChar;
  Chunk: TChunkHeader;
  FileSize, ChunkStart, ChunkEnd, RiffEnd: Int64;
  HaveFmt, HaveData: Boolean;
  FmtBuf: TBytes;
  CbSize: Word;
  SubFormat: TGUID;
begin
  Result := False;
  Error := '';
  Info := Default(TWavInfo);
  HaveFmt := False;
  HaveData := False;
  FileSize := Stream.Size;
  Stream.Position := 0;
  if (FileSize < 12) or not ReadExact(Stream, Riff, SizeOf(Riff)) then
  begin
    Error := 'File too small to be a WAV file';
    Exit;
  end;
  if Riff.Id <> 'RIFF' then
  begin
    Error := 'Missing RIFF signature';
    Exit;
  end;
  if not ReadExact(Stream, WaveId, 4) or (WaveId <> 'WAVE') then
  begin
    Error := 'Missing WAVE form type';
    Exit;
  end;

  // Some writers leave the RIFF size at 0 or 0xFFFFFFFF; trust the real file size.
  RiffEnd := Int64(Riff.Size) + 8;
  if (Riff.Size = 0) or (Riff.Size = $FFFFFFFF) or (RiffEnd > FileSize) then
    RiffEnd := FileSize;

  while Stream.Position + SizeOf(TChunkHeader) <= RiffEnd do
  begin
    if not ReadExact(Stream, Chunk, SizeOf(Chunk)) then
      Break;
    ChunkStart := Stream.Position;
    ChunkEnd := ChunkStart + Chunk.Size;

    if Chunk.Id = 'fmt ' then
    begin
      if HaveFmt then
      begin
        Error := 'Duplicate fmt chunk';
        Exit;
      end;
      if (Chunk.Size < 16) or (Chunk.Size > 1024) or (ChunkEnd > FileSize) then
      begin
        Error := 'Invalid fmt chunk size';
        Exit;
      end;
      SetLength(FmtBuf, Chunk.Size);
      if not ReadExact(Stream, FmtBuf[0], Chunk.Size) then
      begin
        Error := 'Truncated fmt chunk';
        Exit;
      end;
      Info.FormatTag := PWord(@FmtBuf[0])^;
      Info.Channels := PWord(@FmtBuf[2])^;
      Info.SampleRate := PCardinal(@FmtBuf[4])^;
      Info.BlockAlign := PWord(@FmtBuf[12])^;
      Info.BitsPerSample := PWord(@FmtBuf[14])^;
      if Info.FormatTag = WAVE_FORMAT_EXTENSIBLE_TAG then
      begin
        if Chunk.Size < 40 then
        begin
          Error := 'Truncated WAVE_FORMAT_EXTENSIBLE header';
          Exit;
        end;
        CbSize := PWord(@FmtBuf[16])^;
        if CbSize < 22 then
        begin
          Error := 'Invalid WAVE_FORMAT_EXTENSIBLE extension size';
          Exit;
        end;
        Move(FmtBuf[24], SubFormat, SizeOf(TGUID));
        if SubFormat <> SubtypePCM then
        begin
          Error := 'Unsupported WAVE_FORMAT_EXTENSIBLE sub-format (only PCM is supported)';
          Exit;
        end;
      end
      else if Info.FormatTag <> WAVE_FORMAT_PCM_TAG then
      begin
        Error := Format('Unsupported format tag $%.4x (only PCM is supported)', [Info.FormatTag]);
        Exit;
      end;
      HaveFmt := True;
    end
    else if Chunk.Id = 'data' then
    begin
      if HaveData then
      begin
        Error := 'Duplicate data chunk';
        Exit;
      end;
      Info.DataOffset := ChunkStart;
      Info.DataBytes := Chunk.Size;
      // Tolerate a data size that overruns the file (truncated download or
      // streaming writer); keep only bytes that actually exist.
      if (Chunk.Size = $FFFFFFFF) or (ChunkEnd > FileSize) then
        Info.DataBytes := FileSize - ChunkStart;
      HaveData := True;
      ChunkEnd := ChunkStart + Info.DataBytes;
    end
    else if ChunkEnd > FileSize then
    begin
      Error := Format('Chunk "%s" extends past the end of the file', [string(Chunk.Id)]);
      Exit;
    end;

    // Chunks are word aligned: odd sizes carry one pad byte.
    if Odd(ChunkEnd - ChunkStart) then
      Inc(ChunkEnd);
    if ChunkEnd > RiffEnd then
      Break;
    Stream.Position := ChunkEnd;
  end;

  if not HaveFmt then
  begin
    Error := 'Missing fmt chunk';
    Exit;
  end;
  if not HaveData then
  begin
    Error := 'Missing data chunk';
    Exit;
  end;
  if Info.BitsPerSample <> 16 then
  begin
    Error := Format('Unsupported bit depth %d (only 16-bit PCM is supported)', [Info.BitsPerSample]);
    Exit;
  end;
  if not (Info.Channels in [1, 2]) then
  begin
    Error := Format('Unsupported channel count %d (mono or stereo only)', [Info.Channels]);
    Exit;
  end;
  if (Info.SampleRate < MinWavSampleRate) or (Info.SampleRate > MaxWavSampleRate) then
  begin
    Error := Format('Unsupported sample rate %d Hz', [Info.SampleRate]);
    Exit;
  end;
  if Info.BlockAlign <> Info.Channels * 2 then
  begin
    Error := 'Inconsistent block alignment';
    Exit;
  end;
  Info.DataBytes := (Info.DataBytes div Info.BlockAlign) * Info.BlockAlign;
  if Info.FrameCount = 0 then
  begin
    Error := 'No audio samples';
    Exit;
  end;
  Result := True;
end;

function ParseWavFile(const FileName: string; out Info: TWavInfo; out Error: string): Boolean;
var
  Stream: TFileStream;
begin
  Info := Default(TWavInfo);
  if not FileExists(FileName) then
  begin
    Error := 'File not found: ' + FileName;
    Exit(False);
  end;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      Error := 'Cannot open file: ' + E.Message;
      Exit(False);
    end;
  end;
  try
    try
      Result := ParseWav(Stream, Info, Error);
    except
      on E: Exception do
      begin
        Error := 'Cannot read file: ' + E.Message;
        Result := False;
      end;
    end;
  finally
    Stream.Free;
  end;
end;

end.
