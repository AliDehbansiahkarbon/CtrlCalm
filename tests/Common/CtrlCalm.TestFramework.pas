unit CtrlCalm.TestFramework;

{ A deliberately tiny test harness so the suite needs nothing beyond the RTL.
  Tests register with RegisterTest; RunAllTests prints one line per test and
  returns the number of failures (used as the process exit code). }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  ETestFailure = class(Exception);
  TTestProc = reference to procedure;

procedure RegisterTest(const Suite, Name: string; const Proc: TTestProc);
function RunAllTests(const Filter: string = ''): Integer;

procedure Check(Condition: Boolean; const Msg: string = '');
procedure CheckEquals(Expected, Actual: Int64; const Msg: string = ''); overload;
procedure CheckEquals(const Expected, Actual: string; const Msg: string = ''); overload;
procedure CheckNear(Expected, Actual, Tolerance: Double; const Msg: string = '');
procedure CheckRaises(const Proc: TTestProc; ExClass: ExceptClass; const Msg: string = '');
procedure Fail(const Msg: string);

/// <summary>Records a measured value in the report (performance figures).</summary>
procedure Report(const Key, Value: string);

/// <summary>Pumps the calling thread's message queue for Ms milliseconds, or
/// until Done returns True.</summary>
procedure PumpMessages(Ms: Integer; const Done: TFunc<Boolean> = nil);

implementation

uses
  Winapi.Windows, System.Diagnostics, System.StrUtils;

type
  TTestCase = record
    Suite, Name: string;
    Proc: TTestProc;
  end;

var
  GTests: TList<TTestCase>;
  GReport: TStringList;

procedure RegisterTest(const Suite, Name: string; const Proc: TTestProc);
var
  T: TTestCase;
begin
  if GTests = nil then
    GTests := TList<TTestCase>.Create;
  T.Suite := Suite;
  T.Name := Name;
  T.Proc := Proc;
  GTests.Add(T);
end;

procedure Fail(const Msg: string);
begin
  raise ETestFailure.Create(Msg);
end;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
    Fail(IfThen(Msg = '', 'Check failed', Msg));
end;

procedure CheckEquals(Expected, Actual: Int64; const Msg: string);
begin
  if Expected <> Actual then
    Fail(Format('%s expected %d but was %d', [Msg, Expected, Actual]));
end;

procedure CheckEquals(const Expected, Actual: string; const Msg: string);
begin
  if Expected <> Actual then
    Fail(Format('%s expected "%s" but was "%s"', [Msg, Expected, Actual]));
end;

procedure CheckNear(Expected, Actual, Tolerance: Double; const Msg: string);
begin
  if Abs(Expected - Actual) > Tolerance then
    Fail(Format('%s expected %.6g +/- %.3g but was %.6g', [Msg, Expected, Tolerance, Actual]));
end;

procedure CheckRaises(const Proc: TTestProc; ExClass: ExceptClass; const Msg: string);
begin
  try
    Proc();
  except
    on E: Exception do
    begin
      if not E.InheritsFrom(ExClass) then
        Fail(Format('%s expected %s but got %s: %s', [Msg, ExClass.ClassName, E.ClassName, E.Message]));
      Exit;
    end;
  end;
  Fail(Msg + ' expected an exception of class ' + ExClass.ClassName);
end;

procedure Report(const Key, Value: string);
begin
  if GReport = nil then
    GReport := TStringList.Create;
  GReport.Add(Key + ': ' + Value);
end;

procedure PumpMessages(Ms: Integer; const Done: TFunc<Boolean>);
var
  Msg: TMsg;
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + UInt64(Ms);
  repeat
    while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(Msg);
      DispatchMessage(Msg);
    end;
    if Assigned(Done) and Done() then
      Exit;
    MsgWaitForMultipleObjects(0, nil^, False, 5, QS_ALLINPUT);
  until GetTickCount64 >= Deadline;
end;

function RunAllTests(const Filter: string): Integer;
var
  T: TTestCase;
  SW: TStopwatch;
  Passed, Failed, Skipped: Integer;
  FullName: string;
begin
  Passed := 0;
  Failed := 0;
  Skipped := 0;
  if GTests = nil then
    Exit(0);
  for T in GTests do
  begin
    FullName := T.Suite + '.' + T.Name;
    if (Filter <> '') and (Pos(LowerCase(Filter), LowerCase(FullName)) = 0) then
    begin
      Inc(Skipped);
      Continue;
    end;
    SW := TStopwatch.StartNew;
    try
      T.Proc();
      Inc(Passed);
      Writeln(Format('PASS  %-60s %6d ms', [FullName, SW.ElapsedMilliseconds]));
    except
      on E: Exception do
      begin
        Inc(Failed);
        Writeln(Format('FAIL  %-60s %6d ms', [FullName, SW.ElapsedMilliseconds]));
        Writeln('      ', E.ClassName, ': ', E.Message);
      end;
    end;
  end;
  Writeln;
  if (GReport <> nil) and (GReport.Count > 0) then
  begin
    Writeln('Measurements:');
    for FullName in GReport do
      Writeln('  ', FullName);
    Writeln;
  end;
  Writeln(Format('%d passed, %d failed, %d filtered out', [Passed, Failed, Skipped]));
  Result := Failed;
end;

initialization

finalization
  GTests.Free;
  GReport.Free;

end.
