unit CtrlCalm.Core.Types;

{ Shared value types and the static sound catalog. No dependencies beyond the RTL. }

interface

uses
  System.SysUtils;

type
  /// <summary>The 16 Ctrl+Calm sound categories. Ordinal order is the display order.</summary>
  TSoundId = (
    sndRain, sndThunderstorm, sndWind, sndForest, sndLeaves, sndStream,
    sndSeaside, sndWater, sndFireplace, sndSummerNight, sndCoffeeShop,
    sndTrain, sndFan, sndWhiteNoise, sndPinkNoise, sndBrownNoise);

  TSoundKind = (skRecorded, skProcedural);

  TNoiseColor = (ncWhite, ncPink, ncBrown);

  TSoundDefinition = record
    Id: TSoundId;
    Number: Integer;          // 1..16, as in the product catalog
    Key: string;              // stable persisted identifier
    Name: string;             // display name
    Description: string;
    Kind: TSoundKind;
    FileName: string;         // relative to the sounds folder (recorded only)
    Noise: TNoiseColor;       // procedural only
  end;

  /// <summary>Per-sound playback state as reported by the worker.</summary>
  TTrackState = (tsStopped, tsStarting, tsPlaying, tsStopping, tsUnavailable);

  TAudioStatus = (asNotStarted, asReady, asNoDevice, asRecovering, asUnavailable, asShutDown);

  TTimerMode = (tmCountdown, tmPomodoro);
  TTimerRunState = (trsIdle, trsRunning, trsPaused, trsCompleted);
  TPomodoroPhase = (ppFocus, ppShortBreak, ppLongBreak);

  TTimerCompletionAction = (tcaStopSounds, tcaFadeOut, tcaKeepPlaying);

  TSoundVolumes = array[TSoundId] of Single;
  TSoundFlags = array[TSoundId] of Boolean;

  /// <summary>A complete mix: which sounds are on and at which level (0..1).</summary>
  TMix = record
    Active: TSoundFlags;
    Volumes: TSoundVolumes;
    class function Empty: TMix; static;
    function ActiveCount: Integer;
    function SameAs(const Other: TMix): Boolean;
  end;

  /// <summary>Pomodoro durations in seconds.</summary>
  TPomodoroConfig = record
    FocusSec: Integer;
    ShortBreakSec: Integer;
    LongBreakSec: Integer;
    LongBreakEvery: Integer;   // focus sessions per long break
    AutoStartNext: Boolean;
    class function Default: TPomodoroConfig; static;
    function Normalized: TPomodoroConfig;
    function PhaseSeconds(Phase: TPomodoroPhase): Integer;
  end;

const
  DefaultSoundVolume = 0.5;
  TimerMinSec = 1;
  TimerMaxSec = 24 * 60 * 60 - 1; // 23:59:59
  DefaultMasterVolume = 0.3;
  VolumeTaperExponent = 1.6;

function SoundDef(Id: TSoundId): TSoundDefinition;
function TryParseSoundKey(const Key: string; out Id: TSoundId): Boolean;
function SoundKey(Id: TSoundId): string;

function ClampVolume(V: Double): Single;
function ValidTimerDuration(Seconds: Integer): Boolean;

/// <summary>Maps a linear slider position (0..1) to an amplitude gain using a
/// power taper (exponent 1.6, about -9.6 dB at the half-way point), which tracks
/// perceived loudness far better than a linear map.</summary>
function SliderToGain(V: Single): Single;

implementation

uses
  System.Math;

const
  Catalog: array[TSoundId] of TSoundDefinition = (
    (Id: sndRain;         Number: 1;  Key: 'rain';          Name: 'Rain';          Description: 'Gentle continuous rainfall';               Kind: skRecorded;   FileName: 'rain.wav'),
    (Id: sndThunderstorm; Number: 2;  Key: 'thunderstorm';  Name: 'Thunderstorm';  Description: 'Rain with distant thunder';                Kind: skRecorded;   FileName: 'thunderstorm.wav'),
    (Id: sndWind;         Number: 3;  Key: 'wind';          Name: 'Wind';          Description: 'Natural blowing wind';                     Kind: skRecorded;   FileName: 'wind.wav'),
    (Id: sndForest;       Number: 4;  Key: 'forest';        Name: 'Forest';        Description: 'Forest ambience with birds';               Kind: skRecorded;   FileName: 'forest.wav'),
    (Id: sndLeaves;       Number: 5;  Key: 'leaves';        Name: 'Leaves';        Description: 'Rustling tree leaves';                     Kind: skRecorded;   FileName: 'leaves.wav'),
    (Id: sndStream;       Number: 6;  Key: 'stream';        Name: 'Stream';        Description: 'Flowing water stream';                     Kind: skRecorded;   FileName: 'stream.wav'),
    (Id: sndSeaside;      Number: 7;  Key: 'seaside';       Name: 'Seaside';       Description: 'Ocean waves and shoreline ambience';       Kind: skRecorded;   FileName: 'seaside.wav'),
    (Id: sndWater;        Number: 8;  Key: 'water';         Name: 'Water';         Description: 'Water drops or gentle water movement';     Kind: skRecorded;   FileName: 'water.wav'),
    (Id: sndFireplace;    Number: 9;  Key: 'fireplace';     Name: 'Fireplace';     Description: 'Crackling fire';                           Kind: skRecorded;   FileName: 'fireplace.wav'),
    (Id: sndSummerNight;  Number: 10; Key: 'summer-night';  Name: 'Summer Night';  Description: 'Crickets and nighttime ambience';          Kind: skRecorded;   FileName: 'summer-night.wav'),
    (Id: sndCoffeeShop;   Number: 11; Key: 'coffee-shop';   Name: 'Coffee Shop';   Description: 'Distant conversations and cafe ambience';  Kind: skRecorded;   FileName: 'coffee-shop.wav'),
    (Id: sndTrain;        Number: 12; Key: 'train';         Name: 'Train';         Description: 'Gentle rumbling train';                    Kind: skRecorded;   FileName: 'train.wav'),
    (Id: sndFan;          Number: 13; Key: 'fan';           Name: 'Fan';           Description: 'Consistent electric fan';                  Kind: skRecorded;   FileName: 'fan.wav'),
    (Id: sndWhiteNoise;   Number: 14; Key: 'white-noise';   Name: 'White Noise';   Description: 'Full-spectrum noise';                      Kind: skProcedural; Noise: ncWhite),
    (Id: sndPinkNoise;    Number: 15; Key: 'pink-noise';    Name: 'Pink Noise';    Description: 'Spectrally shaped pink noise';             Kind: skProcedural; Noise: ncPink),
    (Id: sndBrownNoise;   Number: 16; Key: 'brown-noise';   Name: 'Brown Noise';   Description: 'Low-frequency brown noise';                Kind: skProcedural; Noise: ncBrown)
  );

function SoundDef(Id: TSoundId): TSoundDefinition;
begin
  Result := Catalog[Id];
end;

function SoundKey(Id: TSoundId): string;
begin
  Result := Catalog[Id].Key;
end;

function TryParseSoundKey(const Key: string; out Id: TSoundId): Boolean;
var
  S: TSoundId;
begin
  for S := Low(TSoundId) to High(TSoundId) do
    if SameText(Catalog[S].Key, Key) then
    begin
      Id := S;
      Exit(True);
    end;
  Result := False;
end;

function ClampVolume(V: Double): Single;
begin
  if IsNan(V) then
    Exit(0);
  Result := EnsureRange(V, 0.0, 1.0);
end;

function SliderToGain(V: Single): Single;
begin
  V := ClampVolume(V);
  if V <= 0 then
    Result := 0
  else
    Result := Power(V, VolumeTaperExponent);
end;

function ValidTimerDuration(Seconds: Integer): Boolean;
begin
  Result := (Seconds >= TimerMinSec) and (Seconds <= TimerMaxSec);
end;

{ TPomodoroConfig }

class function TPomodoroConfig.Default: TPomodoroConfig;
begin
  Result.FocusSec := 25 * 60;
  Result.ShortBreakSec := 5 * 60;
  Result.LongBreakSec := 15 * 60;
  Result.LongBreakEvery := 4;
  Result.AutoStartNext := False;
end;

function TPomodoroConfig.Normalized: TPomodoroConfig;
var
  D: TPomodoroConfig;
begin
  D := TPomodoroConfig.Default;
  Result := Self;
  if not ValidTimerDuration(Result.FocusSec) then Result.FocusSec := D.FocusSec;
  if not ValidTimerDuration(Result.ShortBreakSec) then Result.ShortBreakSec := D.ShortBreakSec;
  if not ValidTimerDuration(Result.LongBreakSec) then Result.LongBreakSec := D.LongBreakSec;
  if (Result.LongBreakEvery < 1) or (Result.LongBreakEvery > 12) then
    Result.LongBreakEvery := D.LongBreakEvery;
end;

function TPomodoroConfig.PhaseSeconds(Phase: TPomodoroPhase): Integer;
begin
  case Phase of
    ppFocus: Result := FocusSec;
    ppShortBreak: Result := ShortBreakSec;
  else
    Result := LongBreakSec;
  end;
end;

{ TMix }

class function TMix.Empty: TMix;
var
  S: TSoundId;
begin
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    Result.Active[S] := False;
    Result.Volumes[S] := DefaultSoundVolume;
  end;
end;

function TMix.ActiveCount: Integer;
var
  S: TSoundId;
begin
  Result := 0;
  for S := Low(TSoundId) to High(TSoundId) do
    if Active[S] then
      Inc(Result);
end;

function TMix.SameAs(const Other: TMix): Boolean;
var
  S: TSoundId;
begin
  for S := Low(TSoundId) to High(TSoundId) do
  begin
    if Active[S] <> Other.Active[S] then
      Exit(False);
    if Active[S] and (Abs(Volumes[S] - Other.Volumes[S]) > 0.005) then
      Exit(False);
  end;
  Result := True;
end;

end.
