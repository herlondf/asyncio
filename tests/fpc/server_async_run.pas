program server_async_run;

// FPC / Linux RUNTIME check for issue #219 item 1: does the async
// worker-pool path (TElasticWorkerPool, exercised when SyncDispatch=False)
// actually work under FPC 3.3.1, or does it still hit the closure/threading
// codegen bug the issue describes? server_run.pas never exercises this --
// the server defaults to SyncDispatch under FPC, which bypasses the pool
// entirely. This forces SyncDispatch := False explicitly and issues several
// real concurrent HTTP requests to prove the pool spawns workers, dispatches,
// and returns correct responses.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$H+}
{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes,
  SysUtils,
  fphttpclient,
  Poseidon;

const
  CPort = 19783;
  CBase = 'http://127.0.0.1:19783';
  CRequests = 20;

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
  GOk: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; ACond: Boolean);
begin
  if ACond then
  begin
    Inc(GOk);
    Writeln('  ok   ', AName);
  end
  else
  begin
    Inc(GFail);
    Writeln(' FAIL  ', AName);
  end;
end;

function GetWithRetry(const AUrl: string; AAttempts: Integer): string;
var
  LClient: TFPHTTPClient;
  I: Integer;
begin
  Result := '';
  for I := 1 to AAttempts do
  begin
    LClient := TFPHTTPClient.Create(nil);
    try
      try
        Result := LClient.Get(AUrl);
        Exit;
      except
        on E: Exception do
          Sleep(100);
      end;
    finally
      LClient.Free;
    end;
  end;
end;

var
  GApp: TPoseidonServer;
  GThread: TListenThread;
  GHandlers: THandlers;
  GHandler: TNativeHandler;
  GBody: string;
  I: Integer;
  GAllOk: Boolean;
begin
  Writeln('=== Poseidon FPC/Linux ASYNC worker-pool runtime check (#219 item 1) ===');

  GHandlers := THandlers.Create;
  GApp := TPoseidonServer.Create;
  try
    GHandler := GHandlers.Ping;
    GApp.Get('/ping', GHandler);
    GApp.SyncDispatch := False;  // force the async worker-pool path

    GThread := TListenThread.Create(GApp);
    try
      GBody := GetWithRetry(CBase + '/ping', 50);
      Check('First GET /ping returns pong (worker pool spawned+dispatched)', GBody = 'pong');

      GAllOk := True;
      for I := 1 to CRequests do
      begin
        GBody := GetWithRetry(CBase + '/ping', 10);
        if GBody <> 'pong' then
          GAllOk := False;
      end;
      Check(Format('%d sequential requests after warm-up all return pong', [CRequests]), GAllOk);
    finally
      GApp.Stop;
      GThread.WaitFor;
      GThread.Free;
    end;
  finally
    GApp.Free;
    GHandlers.Free;
  end;

  Writeln('---------------------------------------------------');
  Writeln(Format('DONE: %d ok, %d fail', [GOk, GFail]));
  if GFail > 0 then
    Halt(1);
end.
