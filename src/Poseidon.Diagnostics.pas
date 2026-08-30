unit Poseidon.Diagnostics;

// Crash diagnostics - turns a fatal signal into a usable report instead of a
// bare address.
//
// WHY: without this, a heap corruption in a long-running server surfaces on
// Linux as nothing but glibc's own line plus the RTL's
//
//   malloc(): unaligned tcache chunk detected
//   Runtime error 232 at 000000000048A2C5
//
// (232 = "Fatal signal raised on a non-Delphi thread"). That address alone is
// useless without the exact binary, and the offending thread is not
// identified. glibc calls abort() the moment it detects corrupted heap
// metadata, so a backtrace taken from the SIGABRT handler points straight at
// the malloc/free call chain that tripped it.
//
// ASYNC-SIGNAL SAFETY: the handler must not allocate - the heap is exactly
// what is already broken when SIGABRT arrives. So it only calls write(2),
// backtrace(3) and backtrace_symbols_fd(3). Everything it prints is a literal
// or is formatted into a stack buffer; there is no string type in the path
// (passing a literal to a `string`/`RawByteString` parameter can allocate).
// backtrace_symbols_fd is specified as not calling malloc - unlike
// backtrace_symbols, which does and must never be used here.
//
// After reporting, the signal goes to the handler installed before this one. On
// a Delphi app that is the RTL's SignalDispatcher, which turns SIGSEGV/BUS/FPE/
// ILL into EAccessViolation, so a nil deref reports its stack here and fails as
// a 500 instead of taking the process down.
//
// SIGABRT is never delegated, since glibc raises it with the heap already
// corrupt, and neither is a signal with no previous handler: those restore the
// default disposition and re-raise so the kernel can still write a core dump.
//
// For readable frames the binary needs symbols: link with -g (dcclinux64 keeps
// them by default) and do NOT strip. Addresses still print without symbols.
//
// Usage:
//   TPoseidonDiagnostics.InstallCrashHandler;   // once, before Listen
//
// Windows: no-op (the RTL already reports faults with an address, and WER
// captures the rest).

interface

type
  TPoseidonDiagnostics = class
  public
    // Installs handlers for SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL. Idempotent.
    // No-op on Windows.
    class procedure InstallCrashHandler; static;
    // True once InstallCrashHandler has run successfully.
    class function CrashHandlerInstalled: Boolean; static;
    // Short (6 hex chars) id generated once per process, stable for its
    // lifetime. Lets operators visually separate interleaved log lines from
    // different replicas/instances sharing one aggregated log stream, and
    // correlates a crash report back to that same instance's [health] lines.
    class function InstanceId: string; static;
  end;

implementation

{$IFNDEF MSWINDOWS}

uses
  {$IFDEF FPC}
  SysUtils,
  syncobjs,
  Poseidon.Compat.Posix;
  {$ELSE}
  System.SysUtils,
  System.SyncObjs,
  Posix.Signal,
  Posix.Unistd;
  {$ENDIF}

const
  CMaxFrames = 64;
  CStdErr = 2;
  CInstanceIdLen = 6;
  // x86-64 syscall number. glibc only exposes gettid() as a function from
  // 2.30 on, and Poseidon targets Linux x86-64 only, so the raw syscall is
  // both safer across base images and async-signal-safe.
  CSysGetTid = 186;

function backtrace(ABuffer: PPointer; ASize: Integer): Integer; cdecl;
  external 'libc.so.6' name 'backtrace';
procedure backtrace_symbols_fd(ABuffer: PPointer; ASize: Integer;
  AFd: Integer); cdecl;
  external 'libc.so.6' name 'backtrace_symbols_fd';
function _syscall(ANum: NativeInt): NativeInt; cdecl varargs;
  external 'libc.so.6' name 'syscall';

const
  CHandledSignals: array[0..4] of Integer =
    (SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL);

var
  GInstalled: Integer = 0;
  // Captured by sigaction's oldact at install time; read only from signal context.
  GPrevAction: array[0..High(CHandledSignals)] of sigaction_t;
  // Pre-touched at install time so the first backtrace() inside the handler
  // cannot be the one that lazily loads libgcc's unwinder (which allocates).
  GWarmup: array[0..CMaxFrames - 1] of Pointer;
  // Null-terminated, generated once by _EnsureInstanceId. Read directly (no
  // string type) from _CrashHandler, which must stay async-signal-safe.
  GInstanceId: array[0..CInstanceIdLen] of AnsiChar;
  GInstanceIdReady: Integer = 0;

// Not called from signal context - TGUID.NewGuid is a normal (allocating)
// call, safe here because this only ever runs from ordinary thread code
// (InstanceId's first call, or InstallCrashHandler). _CrashHandler itself
// only ever READS the already-populated GInstanceId buffer.
procedure _EnsureInstanceId;
const
  CHexDigits: array[0..15] of AnsiChar = '0123456789abcdef';
var
  LGuid: TGUID;
  I: Integer;
begin
  if TInterlocked.CompareExchange(GInstanceIdReady, 1, 0) <> 0 then Exit;
  LGuid := TGUID.NewGuid;
  for I := 0 to CInstanceIdLen - 1 do
    GInstanceId[I] := CHexDigits[LGuid.D4[I] and $0F];
  GInstanceId[CInstanceIdLen] := #0;
end;

procedure _Emit(AMsg: PAnsiChar);
var
  LLen: Integer;
begin
  if AMsg = nil then Exit;
  LLen := 0;
  while AMsg[LLen] <> #0 do Inc(LLen);
  if LLen > 0 then
    __write(CStdErr, AMsg, LLen);
end;

// Unsigned/signed to decimal in a stack buffer. IntToStr allocates.
procedure _EmitInt(AValue: Int64);
var
  LBuf: array[0..23] of AnsiChar;
  LPos: Integer;
  LNeg: Boolean;
begin
  LNeg := AValue < 0;
  if LNeg then AValue := -AValue;
  LPos := High(LBuf);
  if AValue = 0 then
  begin
    LBuf[LPos] := '0';
    Dec(LPos);
  end
  else
    while AValue > 0 do
    begin
      LBuf[LPos] := AnsiChar(Ord('0') + (AValue mod 10));
      AValue := AValue div 10;
      Dec(LPos);
    end;
  if LNeg then
  begin
    LBuf[LPos] := '-';
    Dec(LPos);
  end;
  __write(CStdErr, @LBuf[LPos + 1], High(LBuf) - LPos);
end;

// Returns a pointer to a literal - no allocation, unlike a string result.
function _SignalName(ASigNum: Integer): PAnsiChar;
begin
  if ASigNum = SIGSEGV then
    Result := 'SIGSEGV (invalid memory access)'
  else if ASigNum = SIGABRT then
    Result := 'SIGABRT (abort - usually glibc heap corruption)'
  else if ASigNum = SIGBUS then
    Result := 'SIGBUS (bad memory alignment/access)'
  else if ASigNum = SIGFPE then
    Result := 'SIGFPE (arithmetic fault)'
  else if ASigNum = SIGILL then
    Result := 'SIGILL (illegal instruction)'
  else
    Result := 'unknown signal';
end;

function _SignalSlot(ASigNum: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(CHandledSignals) do
    if CHandledSignals[I] = ASigNum then
      Exit(I);
end;

// Raw pointer compare so this does not depend on how SIG_DFL/SIG_IGN are typed
// on Delphi vs FPC.
function _HasPrevHandler(ASlot: Integer): Boolean;
var
  LPtr: Pointer;
begin
  LPtr := PPointer(@GPrevAction[ASlot]._u)^;
  Result := (LPtr <> nil) and (NativeUInt(LPtr) <> 1);
end;

procedure _CrashHandler(ASigNum: Integer; ASigInfo: Psiginfo_t;
  AContext: Pointer); cdecl;
var
  LFrames: array[0..CMaxFrames - 1] of Pointer;
  LCount: Integer;
  LSlot: Integer;
begin
  _Emit(#10'=== POSEIDON CRASH REPORT (iid=');
  _Emit(PAnsiChar(@GInstanceId[0]));
  _Emit(') ==='#10);
  _Emit('signal : ');
  _EmitInt(ASigNum);
  _Emit(' - ');
  _Emit(_SignalName(ASigNum));
  _Emit(#10'tid    : ');
  _EmitInt(_syscall(CSysGetTid));
  _Emit(#10'frames :'#10);

  LCount := backtrace(@LFrames[0], CMaxFrames);
  if LCount > 0 then
    backtrace_symbols_fd(@LFrames[0], LCount, CStdErr)
  else
    _Emit('  <backtrace unavailable>'#10);

  _Emit('=== END CRASH REPORT ==='#10);

  LSlot := _SignalSlot(ASigNum);
  if (ASigNum <> SIGABRT) and (LSlot >= 0) and _HasPrevHandler(LSlot) then
  begin
    if (GPrevAction[LSlot].sa_flags and SA_SIGINFO) <> 0 then
      GPrevAction[LSlot]._u.sa_sigaction(ASigNum, ASigInfo, AContext)
    else
      GPrevAction[LSlot]._u.sa_handler(ASigNum);
    Exit;
  end;

  signal(ASigNum, TSignalHandler(SIG_DFL));
  __raise(ASigNum);
end;

class procedure TPoseidonDiagnostics.InstallCrashHandler;
var
  LSA: sigaction_t;
  I: Integer;
begin
  if TInterlocked.CompareExchange(GInstalled, 1, 0) <> 0 then Exit;

  // Load the unwinder NOW, while the heap is still healthy.
  backtrace(@GWarmup[0], CMaxFrames);

  FillChar(LSA, SizeOf(LSA), 0);
  LSA._u.sa_sigaction := @_CrashHandler;
  // SA_SIGINFO: the RTL's handler is installed that way and reads the fault
  // context, so delegating to it requires passing siginfo/ucontext through.
  LSA.sa_flags := SA_SIGINFO;
  sigemptyset(LSA.sa_mask);
  for I := 0 to High(CHandledSignals) do
    sigaction(CHandledSignals[I], @LSA, @GPrevAction[I]);
end;

class function TPoseidonDiagnostics.CrashHandlerInstalled: Boolean;
begin
  Result := TInterlocked.CompareExchange(GInstalled, 0, 0) <> 0;
end;

class function TPoseidonDiagnostics.InstanceId: string;
begin
  _EnsureInstanceId;
  Result := string(AnsiString(PAnsiChar(@GInstanceId[0])));
end;

{$ELSE}

uses
  {$IFDEF FPC}
  SysUtils,
  syncobjs;
  {$ELSE}
  System.SysUtils,
  System.SyncObjs;
  {$ENDIF}

const
  CInstanceIdLen = 6;

var
  GInstanceId: array[0..CInstanceIdLen] of AnsiChar;
  GInstanceIdReady: Integer = 0;

procedure _EnsureInstanceId;
const
  CHexDigits: array[0..15] of AnsiChar = '0123456789abcdef';
var
  LGuid: TGUID;
  I: Integer;
begin
  if TInterlocked.CompareExchange(GInstanceIdReady, 1, 0) <> 0 then Exit;
  LGuid := TGUID.NewGuid;
  for I := 0 to CInstanceIdLen - 1 do
    GInstanceId[I] := CHexDigits[LGuid.D4[I] and $0F];
  GInstanceId[CInstanceIdLen] := #0;
end;

class procedure TPoseidonDiagnostics.InstallCrashHandler;
begin
  // Windows: the RTL already reports faults with an address and WER captures
  // the rest.
end;

class function TPoseidonDiagnostics.CrashHandlerInstalled: Boolean;
begin
  Result := False;
end;

class function TPoseidonDiagnostics.InstanceId: string;
begin
  _EnsureInstanceId;
  Result := string(AnsiString(PAnsiChar(@GInstanceId[0])));
end;

{$ENDIF}

end.
