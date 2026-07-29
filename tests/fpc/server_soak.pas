program server_soak;

// FPC / Linux endurance soak for issue #219 item 5.
//
// Long-running counterpart to server_run.pas: boots a real TPoseidonServer
// (FPC-built, SyncDispatch default) on a fixed port and serves /ping until it
// receives a real external SIGTERM (same InstallSignalHandler/
// CheckShutdownSignal mechanism already proven at runtime by
// server_signal_run.pas for item 4). The wrapper shell script drives sustained
// load against it and samples RSS memory for the soak's duration; this
// program's only job is to stay up and answer correctly for hours.

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
  CPort = 19782;

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
  Writeln(Format('=== Poseidon FPC/Linux endurance soak (#219 item 5), pid=%d ===', [fpGetPid]));

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
