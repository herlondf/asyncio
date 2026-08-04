program Poseidon.FuzzRunner;

// Dedicated fuzzing runner — the pure parsing surfaces only (HTTP/1, HPACK,
// WebSocket) plus the deterministic HPACK invariant guards. No sockets, no
// server: fast and self-contained, so it can run continuously (CI loop, local
// endurance) without the live-socket environment the full suite needs.
//
// Covers issues #200 (HTTP/1 parser fuzzing) and #201 (HPACK decoder fuzzing).

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.XML.NUnit,
  Poseidon.Diagnostics,
  Poseidon.Tests.Fuzz;

var
  LRunner:  ITestRunner;
  LResults: IRunResults;
begin
  // Um overflow de heap num parser nao aborta na hora: ele so estoura num
  // malloc posterior, longe da causa. Com o handler instalado (e, no Linux,
  // LD_PRELOAD=libc_malloc_debug.so.0 + glibc.malloc.check=3), o abort vem com
  // backtrace apontando o parser que escreveu fora do bloco.
  TPoseidonDiagnostics.InstallCrashHandler;
  try
    TDUnitX.CheckCommandLine;
    LRunner := TDUnitX.CreateRunner;
    LRunner.UseRTTI          := True;
    LRunner.FailsOnNoAsserts := False;
    LRunner.AddLogger(TDUnitXConsoleLogger.Create(False));
    LRunner.AddLogger(TDUnitXXMLNUnitFileLogger.Create('.\bin\DUnitX-Fuzz-Results.xml'));
    LResults := LRunner.Execute;
    if not LResults.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName + ': ' + E.Message);
      System.ExitCode := 1;
    end;
  end;
end.
