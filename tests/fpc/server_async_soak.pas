program server_async_soak;

// FPC / Linux concurrent-load check for issue #219 item 1: server_async_run
// only proved sequential single-connection dispatch works. This forces
// SyncDispatch := False (async worker pool) and stays up under real
// concurrent load (driven externally by wrk) until a real SIGTERM, to prove
// the pool's multi-thread spawn/steal/dispatch path survives concurrency
// under FPC 3.3.1 — the exact scenario the issue's "closure/threading
// codegen bug" concern was about, not just one thread at a time.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$H+}
{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes,
  SysUtils,
  BaseUnix,
  Poseidon,
  Poseidon.GracefulReload;

const
  CPort = 19784;

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
  FApp.Listen(CPort, '0.0.0.0');
end;

var
  GApp: TPoseidonServer;
  GThread: TListenThread;
  GHandlers: THandlers;
  GHandler: TNativeHandler;
  GShutdownCalled: Boolean = False;
begin
  Writeln(Format('=== Poseidon FPC/Linux ASYNC worker-pool concurrent soak (#219 item 1), pid=%d ===', [fpGetPid]));

  GHandlers := THandlers.Create;
  GApp := TPoseidonServer.Create;
  try
    GHandler := GHandlers.Ping;
    GApp.Get('/ping', GHandler);
    GApp.SyncDispatch := False;  // force the async worker-pool path under real concurrency

    InstallSignalHandler(procedure
      begin
        GShutdownCalled := True;
        GApp.Stop;
      end);

    GThread := TListenThread.Create(GApp);
    try
      Writeln('READY');
      Flush(Output);

      while not GShutdownCalled do
      begin
        CheckShutdownSignal;
        if GShutdownCalled then Break;
        Sleep(200);
      end;

      Writeln('SIGTERM received, shutting down');
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
