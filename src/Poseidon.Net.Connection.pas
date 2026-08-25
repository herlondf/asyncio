unit Poseidon.Net.Connection;

// TNativeConn — per-connection state (R-4 SRP extraction from HttpServer.pas).
//
// Owns the socket handle, the accumulation buffer, SSL BIO pointers, WebSocket
// and HTTP/2 upgrade state, and (on Linux) the non-blocking send state.
//
// Lifecycle (IOCP race fix):
//   Created  -> FRefCount = 1  (server "owns" one ref)
//   PostRecv / PostSend -> AddRef before WSARecv/WSASend (one ref per in-flight op)
//   Worker loop completion -> Release after the callback (drops the IOCP-op ref)
//   _CloseConn -> Release (drops the server ref); may not reach zero yet if ops
//                are still in-flight — the object lives until the last Release.
//   AddRef/Release are thread-safe via TInterlocked.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  syncobjs,
    {$IFDEF MSWINDOWS}
  WinSock2,
    {$ENDIF}
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
    {$IFDEF MSWINDOWS}
  Winapi.Winsock2,
    {$ENDIF}
  {$ENDIF}
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.HTTP2,
  Poseidon.Net.WebSocket;

const
  CCMHttp = 0;
  CCMWebSocket = 1;

type
  TNativeConn = class
  private
    FRefCount: Integer; // Atomic ref count; reaches 0 -> Destroy
    FPadRef: array[0..14] of Integer; // Cache-line padding — isolate FRefCount
  public
{$IFDEF MSWINDOWS}
    Socket: TSocket;
    RioRQ: Pointer;
{$ELSE}
    Socket: Integer;
{$ENDIF}
    RemoteAddr: string;
    // #213: serializes ALL per-connection access to the SSL object, AccumBuf,
    // and H2Conn across the IO/core thread (_ProcessRecvSSL) and the request
    // worker pool (dispatch / _EncryptAndSend). Recursive (TCriticalSection),
    // so nested same-thread acquisition (e.g. _ProcessRecvSSL -> _EncryptAndSend
    // during handshake) does not deadlock.
    Lock: TCriticalSection;
    AccumBuf: TBytes;
    AccumLen: Integer;
    KeepAlive: Boolean;
    // Deferred-response teardown guard. Set to 1 (atomically) inside _CloseConn
    // so a deferred completion arriving from another thread (TPoseidonResponder)
    // knows the socket is already gone and skips the send — the object itself is
    // kept alive by the responder's AddRef, but the fd is closed.
    Closed: Integer;
    LastActivityTick: UInt64;
    // #224 mitigation: set by TIdleSweepManager when it calls ShutdownConn
    // (0 = not yet shut down). If the connection is still open on a LATER
    // sweep pass past the grace period, the expected recv-error completion
    // never arrived — force a full close instead of leaking the fd forever
    // (observed as sockets stuck in FIN_WAIT2 with no kernel timeout).
    ShutdownRequestedTick: UInt64;
    InFlightPool: Integer;
    FPadInflight: array[0..14] of Integer; // Cache-line padding — isolate InFlightPool
    SSLHandle: Pointer;
    SSLReadBio: Pointer;
    SSLWriteBio: Pointer;
    SSLHandshook: Boolean;
    WSMode: Byte;
    WSPath: string;
    WSConn: IPoseidonWSConn;
    WSDeflate: Boolean;
    H2Conn: TH2Conn;
    PPParsed: Boolean;
{$IFNDEF MSWINDOWS}
    PendingSend: TBytes;
    PendingSendActual: Integer;
    SentBytes: Integer;
    // #229: counts consecutive EAGAIN-triggered io-wq async resubmits for the
    // CURRENT send. Reset whenever a new PostSend begins. Combined with
    // CSO_SNDTIMEO (bounds each blocking attempt), this bounds a permanently
    // -stalled peer to a finite number of retries instead of retrying forever
    // one connection at a time — see Poseidon.Net.IO.IOUring.pas CMaxSendEAGAINRetries.
    SendEAGAINRetries: Integer;
    OwnerEpollFd: Integer;
    // #234: guards Socket/epoll_ctl against a race between SocketClose
    // (called from _CloseConn under LConn.Lock, but reachable from ANY
    // thread — e.g. TIdleSweepManager's #224 force-close) and _ArmSendReady
    // (explicitly LOCK-FREE by design — called from the epoll core thread
    // exactly when it could NOT get LConn.Lock, and that thread must never
    // block). Without this, _ArmSendReady's epoll_ctl(MOD) can land AFTER
    // SocketClose's close(fd), and if the kernel already reused that fd
    // number for a brand-new connection on the SAME epfd, the stale MOD
    // silently overwrites the new connection's epoll entry back to this
    // (about to be freed) TNativeConn — the next event delivered for that fd
    // then dereferences freed memory. 0 = free, 1 = held. SocketClose spins
    // briefly to acquire it (its guarded section is two syscalls, never runs
    // on a core thread); _ArmSendReady only TryAcquires (skips the rearm
    // entirely on contention — a missed EPOLLOUT rearm is always safe, the
    // send retries on the next event).
    SocketOpGuard: Integer;
    // io_uring multi-ring: index of the ring (completion thread + SQ) this
    // connection is pinned to. Set in TIOUringBackend.RegisterConn from the
    // GCurrentRingIdx threadvar (stamped by the accepting ring's accept thread),
    // then read by every PostRecv/PostSend/_ResubmitSend/SocketClose so a
    // connection's SQEs always go to the ring whose completion thread owns it —
    // the epoll OwnerEpollFd model. Unused by the epoll backend.
    OwnerRingIdx: Integer;
    // #11: io_uring send serialization. TLS requires strict byte ordering, but
    // io_uring does NOT order independent SEND SQEs — several frames in one
    // dispatch would submit concurrent sends that interleave on the wire ->
    // 'bad record MAC'. Enforce ONE send in flight per connection; queue the
    // rest here (guarded by Lock) and submit on completion.
    // SendBacklog/SendBacklogLen are shared with the epoll backend, which uses
    // them for the same purpose (PendingSend <> nil means a send is in flight);
    // SendInFlight itself is io_uring-only.
    SendInFlight: Boolean;
    SendBacklog: TBytes;
    SendBacklogLen: Integer;
    // #230: io_uring recv serialization. PostRecv could be invoked again
    // (post-upgrade re-arm racing a StepWSBranch re-arm, or an EAGAIN retry
    // overlapping a normal re-arm) while a previous IORING_OP_RECV for this
    // same connection was still outstanding. Two in-flight recvs on the same
    // socket can complete out of submission order, and _ProcessRecvPlain
    // appends strictly in COMPLETION order -- silently reordering bytes
    // relative to the wire and desyncing the WebSocket frame parser under
    // sustained small-fragment load. Enforce ONE recv in flight per
    // connection, guarded by Lock like SendInFlight above.
    RecvInFlight: Boolean;
{$ENDIF}
    // R-1: ASocket is NativeUInt so callers need no {$IFDEF} for socket type.
    // Internally cast to TSocket (Windows) or Integer (Linux).
    constructor Create(ASocket: NativeUInt; const AAddr: string);
    destructor Destroy; override;

    // Ref-counting — thread-safe via TInterlocked.
    // Do NOT call Free directly; use Release instead.
    procedure AddRef;
    procedure Release;
    // #234: for callers holding only a raw pointer with no pre-existing
    // reference (the epoll core loop's LEvents[I].data.ptr, a weak pointer
    // the kernel hands back independent of this object's Delphi-side
    // lifetime) — see TryAddRef body for why plain AddRef is unsafe there.
    function TryAddRef: Boolean;
  end;

implementation

// TInterlocked imported via SyncObjs — already in interface uses.

procedure TNativeConn.AddRef;
begin
  TInterlocked.Increment(FRefCount);
end;

function TNativeConn.TryAddRef: Boolean;
var
  LCurrent, LPrev: Integer;
begin
  // #234: plain AddRef assumes the caller already owns a valid reference
  // (or the object is otherwise known-alive) and blindly increments —
  // correct for every OTHER caller in this codebase. The epoll core loop's
  // LConn := TNativeConn(LEvents[I].data.ptr) is different: the kernel's
  // epoll interest list holds this pointer independent of the connection's
  // Delphi-side refcount, so a connection can hit FRefCount=0 and start
  // Destroy() (which FreeAndNil's Lock, AccumBuf, etc. on STILL-VALID
  // memory — Self.Free's actual deallocation only happens after Destroy
  // returns) on one thread while the core thread is mid-epoll_wait() with a
  // stale event for the SAME connection already queued. A plain AddRef
  // there resurrects the dying object (0 -> 1) and the caller goes on to
  // dereference fields Destroy already nil'd (LConn.Lock.TryEnter on a nil
  // Lock -> SIGSEGV, Helgrind-confirmed against real crash-loop traffic).
  // CAS-looping and refusing at 0 makes "is this connection still alive"
  // atomic with "take a reference to it" — the caller must skip the event
  // entirely (never touch any other field) when this returns False.
  LCurrent := TInterlocked.CompareExchange(FRefCount, 0, 0);
  while LCurrent > 0 do
  begin
    LPrev := TInterlocked.CompareExchange(FRefCount, LCurrent + 1, LCurrent);
    if LPrev = LCurrent then
      Exit(True);
    LCurrent := LPrev;
  end;
  Result := False;
end;

procedure TNativeConn.Release;
var
  LNew: Integer;
begin
  LNew := TInterlocked.Decrement(FRefCount);
  if LNew = 0 then
    Self.Free
  else if LNew < 0 then
    // #234: more Release than AddRef/Create ever handed out somewhere in the
    // codebase -- another caller already dropped the count to zero and this
    // object may already be mid-Destroy/freed. Do NOT touch any field of Self
    // here (that would itself be a use-after-free read) and do NOT call
    // Self.Free (that would double-free -- the corruption class under
    // investigation). Logging only the raw pointer + refcount turns an
    // unattributable, delayed glibc "double free or corruption" abort into an
    // immediate, precise signal that a specific Release call was extra.
    Writeln(ErrOutput, '[poseidon][FATAL] TNativeConn.Release: refcount ' +
      'underflow to ' + IntToStr(LNew) + ' at 0x' +
      IntToHex(NativeUInt(Pointer(Self)), SizeOf(Pointer) * 2));
end;

constructor TNativeConn.Create(ASocket: NativeUInt; const AAddr: string);
begin
{$IFDEF MSWINDOWS}
  Socket := TSocket(ASocket);
  RioRQ := nil;
{$ELSE}
  Socket := Integer(ASocket);
{$ENDIF}
  RemoteAddr := AAddr;
  FRefCount := 1;
  Lock := TCriticalSection.Create;
  AccumBuf := TBufferPool.Acquire;
  AccumLen := 0;
  KeepAlive := False;
  Closed := 0;
  LastActivityTick := TThread.GetTickCount64;
  ShutdownRequestedTick := 0;
  InFlightPool := 0;
  SSLHandle := nil;
  SSLReadBio := nil;
  SSLWriteBio := nil;
  SSLHandshook := False;
  WSMode := CCMHttp;
  WSPath := '';
  WSConn := nil;
  WSDeflate := False;
  H2Conn := nil;
  PPParsed := False;
{$IFNDEF MSWINDOWS}
  OwnerEpollFd := -1;
  OwnerRingIdx := 0;  // valid default ring; overwritten by RegisterConn
  SocketOpGuard := 0;
{$ENDIF}
end;

destructor TNativeConn.Destroy;
begin
  if AccumBuf <> nil then TBufferPool.Release(AccumBuf);
{$IFNDEF MSWINDOWS}
  // P-4: return any in-flight pool buffer if connection closed mid-send
  if PendingSend <> nil then TBufferPool.Release(PendingSend);
{$ENDIF}
  FreeAndNil(H2Conn);
  // Refcount is 0 here — no other thread references this connection, so the
  // lock is uncontended and safe to free last.
  FreeAndNil(Lock);
  inherited Destroy;
end;

end.
