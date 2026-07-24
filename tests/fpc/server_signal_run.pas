program server_signal_run;

// FPC / Linux RUNTIME signal smoke for issue #219 item 4.
//
// InstallSignalHandler/CheckShutdownSignal (Poseidon.GracefulReload) were only
// compile-tested under FPC before. This proves it actually WORKS at runtime:
// installs the handler, boots the server, waits for a REAL external SIGTERM
// (sent by the wrapper shell script via `kill -TERM <pid>`), and checks the
// poll-based flag correctly triggers the shutdown callback.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$H+}
{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes,
  SysUtils,
  Poseidon,
  Poseidon.GracefulReload;

const
  CPort = 19781;

type
  THandlers = class
    procedure Ping(var ACtx: TNativeRequestContext);
  end;

  TListenThread = class(TThread)
  private
    FApp: TPoseidonServer;
  public
    constructor Create(AApp: TPoseidonServer);
    procedure Execute; override;
  end;

procedure THandlers.Ping(var ACtx: TNativeRequestContext);
begin
  ACtx.Status := 200;
  ACtx.ContentType := 'text/plain';
  ACtx.Body := TEncoding.UTF8.GetBytes('pong');
end;

constructor TListenThread.Create(AApp: TPoseidonServer);
begin
  FApp := AApp;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TListenThread.Execute;
begin
  FApp.Listen(CPort, '127.0.0.1');
end;

var
  GApp: TPoseidonServer;
  GThread: TListenThread;
  GHandlers: THandlers;
  GHandler: TNativeHandler;
  GShutdownCalled: Boolean = False;
  I: Integer;
begin
  Writeln('=== Poseidon FPC/Linux SIGTERM runtime smoke (#219) ===');

  GHandlers := THandlers.Create;
  GApp := TPoseidonServer.Create;
  try
    GHandler := GHandlers.Ping;
    GApp.Get('/ping', GHandler);

    InstallSignalHandler(procedure
      begin
        GShutdownCalled := True;
        GApp.Stop;
      end);

    GThread := TListenThread.Create(GApp);
    try
      Writeln('READY');
      Flush(Output);

      // Wait up to 10s for the external `kill -TERM` sent by the wrapper
      // script, polling CheckShutdownSignal (the documented, signal-safe way
      // to invoke the callback outside the actual signal handler).
      for I := 1 to 100 do
      begin
        CheckShutdownSignal;
        if GShutdownCalled then Break;
        Sleep(100);
      end;

      if GShutdownCalled then
        Writeln('  ok   SIGTERM received and callback fired (App.Stop called)')
      else
      begin
        Writeln(' FAIL  SIGTERM never observed within 10s');
        Halt(1);
      end;
    finally
      GThread.WaitFor;
      GThread.Free;
    end;
  finally
    GApp.Free;
    GHandlers.Free;
  end;

  Writeln('DONE');
end.
