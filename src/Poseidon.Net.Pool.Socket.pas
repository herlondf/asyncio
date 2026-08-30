unit Poseidon.Net.Pool.Socket;

// Socket recycling pool using DisconnectEx + TF_REUSE_SOCKET.
//
// Instead of closesocket() + socket(), DisconnectEx resets a connected
// socket to the listening state without kernel object teardown.
// The recycled socket is ready for the next AcceptEx/accept cycle.
//
// Pool is bounded (CMaxPoolSize) to avoid holding too many kernel handles.
// If the pool is full, the socket is closed normally.
//
// #225: one instance per IO backend (TIOCPBackend/TRIOBackend), NOT a
// process-wide singleton. A socket recycled via DisconnectEx stays
// associated with whichever completion port first called
// CreateIoCompletionPort on it; if a different backend instance's pool
// handed that socket back out, RegisterConn's tolerance of
// ERROR_INVALID_PARAMETER (see #203) would silently accept it as "already
// associated with the port we need" when it was actually still bound to a
// different (possibly already-closed) instance's port - completions for
// that connection then never reach the new instance's IOCP.
//
// Windows only. On Linux, this unit compiles as an empty stub.

{$IFDEF MSWINDOWS}

interface

uses
  {$IFDEF FPC}
  WinSock2,
  syncobjs;
  {$ELSE}
  Winapi.Winsock2;
  {$ENDIF}

type
  TSocketPool = class
  private
    FPool: array of TSocket;
    FCount: Integer;
    // FPC's TMonitor is non-functional (TMonitor.Enter AVs), so under FPC this
    // dedicated lock is a real critical section. Delphi keeps TObject+TMonitor.
    {$IFDEF FPC}FLock: TCriticalSection;{$ELSE}FLock: TObject;{$ENDIF}
    FDisconnectEx: Pointer;
    FLoaded: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    // Load DisconnectEx function pointer via WSAIoctl on the given socket.
    // Called once with the listen socket.
    procedure LoadDisconnectEx(ASocket: TSocket);

    // Attempt to recycle a socket via DisconnectEx + TF_REUSE_SOCKET.
    // Returns True if recycled (socket now in pool); False if closed normally.
    function Recycle(ASocket: TSocket): Boolean;

    // Acquire a recycled socket from the pool.
    // Returns INVALID_SOCKET if pool is empty.
    function Acquire: TSocket;

    // Add an already-disconnected socket directly to the pool.
    // Used by async DisconnectEx completion path.
    function AddRecycled(ASocket: TSocket): Boolean;
  end;

implementation

uses
  {$IFDEF FPC}
  Windows,
  SysUtils;
  {$ELSE}
  System.SysUtils,
  System.SyncObjs,
  Winapi.Windows;
  {$ENDIF}

const
  CMaxPoolSize = 2048;
  TF_REUSE_SOCKET = $02;
  SIO_GET_EXTENSION_FUNCTION_POINTER = $C8000006;
  WSAID_DISCONNECTEX: TGUID = '{7FDA2E11-8630-436F-A031-F536A6EEC157}';

type
  TDisconnectExFunc = function(ASocket: TSocket; AOverlapped: POverlapped;
    AFlags: DWORD; AReserved: DWORD): BOOL; stdcall;

constructor TSocketPool.Create;
begin
  inherited Create;
  {$IFDEF FPC}FLock := syncobjs.TCriticalSection.Create;{$ELSE}FLock := TObject.Create;{$ENDIF}
  SetLength(FPool, CMaxPoolSize);
  FCount := 0;
  FDisconnectEx := nil;
  FLoaded := False;
end;

destructor TSocketPool.Destroy;
var
  I: Integer;
begin
  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    for I := 0 to FCount - 1 do
      closesocket(FPool[I]);
    FCount := 0;
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
  FreeAndNil(FLock);
  inherited Destroy;
end;

procedure TSocketPool.LoadDisconnectEx(ASocket: TSocket);
var
  LBytes: DWORD;
  LGuid: TGUID;
begin
  if FLoaded then Exit;
  LGuid := WSAID_DISCONNECTEX;
  LBytes := 0;
  if WSAIoctl(ASocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FDisconnectEx, SizeOf(FDisconnectEx),
    {$IFDEF FPC}@LBytes{$ELSE}LBytes{$ENDIF}, nil, nil) = 0 then
    FLoaded := True;
end;

function TSocketPool.Recycle(ASocket: TSocket): Boolean;
begin
  Result := False;
  if (not FLoaded) or (FDisconnectEx = nil) then Exit;

  // Synchronous DisconnectEx with TF_REUSE_SOCKET
  if not TDisconnectExFunc(FDisconnectEx)(ASocket, nil, TF_REUSE_SOCKET, 0) then
  begin
    // DisconnectEx failed - close normally
    closesocket(ASocket);
    Exit;
  end;

  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    if FCount < CMaxPoolSize then
    begin
      FPool[FCount] := ASocket;
      Inc(FCount);
      Result := True;
    end
    else
      closesocket(ASocket); // Pool full - close normally
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
end;

function TSocketPool.Acquire: TSocket;
begin
  Result := INVALID_SOCKET;
  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    if FCount > 0 then
    begin
      Dec(FCount);
      Result := FPool[FCount];
    end;
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
end;

function TSocketPool.AddRecycled(ASocket: TSocket): Boolean;
begin
  Result := False;
  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    if FCount < CMaxPoolSize then
    begin
      FPool[FCount] := ASocket;
      Inc(FCount);
      Result := True;
    end;
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
end;

{$ELSE}

interface
implementation

{$ENDIF MSWINDOWS}

end.
