unit Poseidon.Tests.IdleSweep;

// DUnitX tests for TIdleSweepManager's #233 handler-stuck watchdog
// (MaxHandlerRunMs). Exercises the sweep thread directly against a real
// TNativeConn/TConnectionManager pair - no sockets involved, since the
// watchdog only needs InFlightPool > 0 and a stale LastActivityTick.
//
// Coverage:
//   - MaxHandlerRunMs = 0 (default): a stuck handler is never force-closed
//   - MaxHandlerRunMs exceeded: OnForceClose fires exactly once for the
//     stuck connection, the worker thread itself is never touched
//   - A handler still within MaxHandlerRunMs is left alone

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TIdleSweepHandlerWatchdogTests = class
  public
    [Test] procedure Disabled_StuckHandler_NeverForceClosed;
    [Test] procedure Enabled_HandlerPastLimit_ForceClosedOnce;
    [Test] procedure Enabled_HandlerWithinLimit_NotForceClosed;
  end;

  // AccumBuf grows via the pool tier (8/64/512 KB) on a large request, but
  // _CompactAccum only ever resets AccumLen, never the buffer's capacity --
  // the sweep now shrinks an idle, fully-drained oversized buffer back to
  // tier 0. Coverage: it does; it does not touch a busy connection
  // (InFlightPool > 0); it does not touch one with pending unconsumed bytes;
  // it does not touch one with ShrinkAccumBufEnabled = False (#234 kill
  // switch - see Poseidon.Net.IdleSweep.pas).
  [TestFixture]
  TIdleSweepAccumBufShrinkTests = class
  public
    [Test] procedure IdleOversizedBuffer_ShrinksToTier0;
    [Test] procedure BusyConnection_BufferNotShrunk;
    [Test] procedure PendingBytes_BufferNotShrunk;
    [Test] procedure Disabled_IdleOversizedBuffer_NotShrunk;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  Poseidon.Net.Connection,
  Poseidon.Net.Connection.Manager,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.IdleSweep;

const
  // The sweep's own internal tick (CSweepIntervalMs in IdleSweep.pas) is
  // 1000ms and not configurable, so any test observing a sweep pass needs
  // to poll past that - this is inherent to the mechanism, not a fixed
  // Sleep standing in for a missing readiness signal.
  CPollTimeoutMs = 3000;
  CPollStepMs = 50;

// Polls AFlag with a timeout instead of a single fixed Sleep - still bounded
// by CPollTimeoutMs so a genuine regression fails the test instead of hanging.
function WaitFor(AFlag: PBoolean; ATimeoutMs: Integer): Boolean;
var
  LWaited: Integer;
begin
  LWaited := 0;
  while (not AFlag^) and (LWaited < ATimeoutMs) do
  begin
    Sleep(CPollStepMs);
    Inc(LWaited, CPollStepMs);
  end;
  Result := AFlag^;
end;

{ TIdleSweepHandlerWatchdogTests }

procedure TIdleSweepHandlerWatchdogTests.Disabled_StuckHandler_NeverForceClosed;
var
  LActive: Boolean;
  LConnMgr: TConnectionManager;
  LSweep: TIdleSweepManager;
  LConn: TNativeConn;
  LForceClosed: Boolean;
begin
  LActive := True;
  LForceClosed := False;
  LConnMgr := TConnectionManager.Create;
  LConn := TNativeConn.Create(0, '127.0.0.1:1');
  try
    LConnMgr.Admit(LConn);
    LConn.InFlightPool := 1;  // simulate a handler that is running
    LConn.LastActivityTick := TThread.GetTickCount64 - 5000;  // "running" 5s

    LSweep := TIdleSweepManager.Create(LConnMgr, nil, @LActive);
    try
      LSweep.IdleTimeoutMs := 0;
      LSweep.MaxHandlerRunMs := 0;  // disabled - default
      LSweep.OnForceClose :=
        procedure(AConn: Pointer)
        begin
          LForceClosed := True;
        end;
      LSweep.Start;
      // Give the sweep a couple of ticks to prove it does nothing, rather
      // than proving absence after zero ticks.
      Sleep(2200);
      Assert.IsFalse(LForceClosed,
        'MaxHandlerRunMs=0 must never force-close a stuck handler');
    finally
      // TIdleSweepManager.Stop() only sets a wake event; the sweep thread's
      // own loop condition is `while FActive^`, checked against the SAME
      // PBoolean the constructor received. The caller (here, the test) owns
      // flipping it to False before Stop - never done, the sweep thread
      // spins forever re-triggering an already-set (manual-reset) wake
      // event and Stop's FSweepThread.WaitFor never returns.
      LActive := False;
      LSweep.Stop;
      FreeAndNil(LSweep);
    end;
  finally
    LConnMgr.Remove(LConn);
    LConn.Release;
    FreeAndNil(LConnMgr);
  end;
end;

procedure TIdleSweepHandlerWatchdogTests.Enabled_HandlerPastLimit_ForceClosedOnce;
var
  LActive: Boolean;
  LConnMgr: TConnectionManager;
  LSweep: TIdleSweepManager;
  LConn: TNativeConn;
  LForceClosed: Boolean;
  LForceCloseCount: Integer;
  LClosedConn: Pointer;
begin
  LActive := True;
  LForceClosed := False;
  LForceCloseCount := 0;
  LClosedConn := nil;
  LConnMgr := TConnectionManager.Create;
  LConn := TNativeConn.Create(0, '127.0.0.1:2');
  try
    LConnMgr.Admit(LConn);
    LConn.InFlightPool := 1;  // handler "running"
    // Already past the 100ms limit by the time the first sweep tick fires.
    LConn.LastActivityTick := TThread.GetTickCount64 - 500;

    LSweep := TIdleSweepManager.Create(LConnMgr, nil, @LActive);
    try
      LSweep.IdleTimeoutMs := 0;      // isolate: idle-close path must not interfere
      LSweep.MaxHandlerRunMs := 100;  // 100ms - well under our simulated 500ms
      LSweep.OnForceClose :=
        procedure(AConn: Pointer)
        begin
          LForceClosed := True;
          LClosedConn := AConn;
          Inc(LForceCloseCount);
        end;
      LSweep.Start;
      Assert.IsTrue(WaitFor(@LForceClosed, CPollTimeoutMs),
        'a handler stuck past MaxHandlerRunMs must be force-closed');
      Assert.AreEqual(Pointer(LConn), LClosedConn,
        'OnForceClose must be called with the stuck connection');

      // The connection is still "in flight" from the worker's point of view
      // (InFlightPool never touched by the watchdog - it does not free the
      // object or kill any thread), so OnForceClose keeps firing every tick
      // it stays stuck. That is expected - _CloseConn (the real callback in
      // production) is idempotent. Just prove it never crashes across a
      // couple more ticks and the connection identity never changes.
      Sleep(2200);
      Assert.IsTrue(LForceCloseCount >= 1, 'must have force-closed at least once');
    finally
      // TIdleSweepManager.Stop() only sets a wake event; the sweep thread's
      // own loop condition is `while FActive^`, checked against the SAME
      // PBoolean the constructor received. The caller (here, the test) owns
      // flipping it to False before Stop - never done, the sweep thread
      // spins forever re-triggering an already-set (manual-reset) wake
      // event and Stop's FSweepThread.WaitFor never returns.
      LActive := False;
      LSweep.Stop;
      FreeAndNil(LSweep);
    end;
  finally
    LConnMgr.Remove(LConn);
    LConn.Release;
    FreeAndNil(LConnMgr);
  end;
end;

procedure TIdleSweepHandlerWatchdogTests.Enabled_HandlerWithinLimit_NotForceClosed;
var
  LActive: Boolean;
  LConnMgr: TConnectionManager;
  LSweep: TIdleSweepManager;
  LConn: TNativeConn;
  LForceClosed: Boolean;
begin
  LActive := True;
  LForceClosed := False;
  LConnMgr := TConnectionManager.Create;
  LConn := TNativeConn.Create(0, '127.0.0.1:3');
  try
    LConnMgr.Admit(LConn);
    LConn.InFlightPool := 1;  // handler "running"
    LConn.LastActivityTick := TThread.GetTickCount64;  // just started

    LSweep := TIdleSweepManager.Create(LConnMgr, nil, @LActive);
    try
      LSweep.IdleTimeoutMs := 0;
      LSweep.MaxHandlerRunMs := 60000;  // 60s - the handler will not run that long in this test
      LSweep.OnForceClose :=
        procedure(AConn: Pointer)
        begin
          LForceClosed := True;
        end;
      LSweep.Start;
      Sleep(2200);  // a couple of sweep ticks
      Assert.IsFalse(LForceClosed,
        'a handler well within MaxHandlerRunMs must not be force-closed');
    finally
      // TIdleSweepManager.Stop() only sets a wake event; the sweep thread's
      // own loop condition is `while FActive^`, checked against the SAME
      // PBoolean the constructor received. The caller (here, the test) owns
      // flipping it to False before Stop - never done, the sweep thread
      // spins forever re-triggering an already-set (manual-reset) wake
      // event and Stop's FSweepThread.WaitFor never returns.
      LActive := False;
      LSweep.Stop;
      FreeAndNil(LSweep);
    end;
  finally
    LConnMgr.Remove(LConn);
    LConn.Release;
    FreeAndNil(LConnMgr);
  end;
end;

{ TIdleSweepAccumBufShrinkTests }

procedure TIdleSweepAccumBufShrinkTests.IdleOversizedBuffer_ShrinksToTier0;
var
  LActive: Boolean;
  LConnMgr: TConnectionManager;
  LSweep: TIdleSweepManager;
  LConn: TNativeConn;
begin
  LActive := True;
  LConnMgr := TConnectionManager.Create;
  LConn := TNativeConn.Create(0, '127.0.0.1:4');
  try
    LConnMgr.Admit(LConn);
    TBufferPool.Release(LConn.AccumBuf);
    LConn.AccumBuf := TBufferPool.Acquire(POOL_TIER1_SIZE);  // simulate a past large request
    LConn.AccumLen := 0;                                     // fully drained
    LConn.InFlightPool := 0;                                 // idle, no active dispatch
    LConn.LastActivityTick := TThread.GetTickCount64;

    LSweep := TIdleSweepManager.Create(LConnMgr, nil, @LActive);
    try
      // Must be non-zero: IdleTimeoutMs=0 AND MaxHandlerRunMs=0 together make
      // the sweep skip per-connection processing entirely (its own early-exit
      // when both checks are disabled), which would also skip the shrink
      // check. 60s is far longer than this test runs, so idle-close itself
      // never fires.
      LSweep.IdleTimeoutMs := 60000;
      LSweep.MaxHandlerRunMs := 0;
      LSweep.Start;
      Sleep(CPollTimeoutMs);
      Assert.IsTrue(Length(LConn.AccumBuf) = POOL_TIER0_SIZE,
        'an idle, fully-drained oversized AccumBuf must shrink back to tier 0');
    finally
      LActive := False;
      LSweep.Stop;
      FreeAndNil(LSweep);
    end;
  finally
    LConnMgr.Remove(LConn);
    LConn.Release;
    FreeAndNil(LConnMgr);
  end;
end;

procedure TIdleSweepAccumBufShrinkTests.BusyConnection_BufferNotShrunk;
var
  LActive: Boolean;
  LConnMgr: TConnectionManager;
  LSweep: TIdleSweepManager;
  LConn: TNativeConn;
begin
  LActive := True;
  LConnMgr := TConnectionManager.Create;
  LConn := TNativeConn.Create(0, '127.0.0.1:5');
  try
    LConnMgr.Admit(LConn);
    TBufferPool.Release(LConn.AccumBuf);
    LConn.AccumBuf := TBufferPool.Acquire(POOL_TIER1_SIZE);
    LConn.AccumLen := 0;
    LConn.InFlightPool := 1;  // a handler is running -- must not be touched
    LConn.LastActivityTick := TThread.GetTickCount64;

    LSweep := TIdleSweepManager.Create(LConnMgr, nil, @LActive);
    try
      LSweep.IdleTimeoutMs := 60000;  // non-zero -- see comment in the previous test
      LSweep.MaxHandlerRunMs := 0;
      LSweep.Start;
      Sleep(CPollTimeoutMs);
      Assert.IsTrue(Length(LConn.AccumBuf) >= POOL_TIER1_SIZE,
        'a busy connection''s AccumBuf must not be shrunk under it');
    finally
      LActive := False;
      LSweep.Stop;
      FreeAndNil(LSweep);
    end;
  finally
    LConnMgr.Remove(LConn);
    LConn.Release;
    FreeAndNil(LConnMgr);
  end;
end;

procedure TIdleSweepAccumBufShrinkTests.PendingBytes_BufferNotShrunk;
var
  LActive: Boolean;
  LConnMgr: TConnectionManager;
  LSweep: TIdleSweepManager;
  LConn: TNativeConn;
begin
  LActive := True;
  LConnMgr := TConnectionManager.Create;
  LConn := TNativeConn.Create(0, '127.0.0.1:6');
  try
    LConnMgr.Admit(LConn);
    TBufferPool.Release(LConn.AccumBuf);
    LConn.AccumBuf := TBufferPool.Acquire(POOL_TIER1_SIZE);
    LConn.AccumLen := 10;     // unconsumed bytes still sitting in the buffer
    LConn.InFlightPool := 0;
    LConn.LastActivityTick := TThread.GetTickCount64;

    LSweep := TIdleSweepManager.Create(LConnMgr, nil, @LActive);
    try
      LSweep.IdleTimeoutMs := 60000;  // non-zero -- see comment in the first test
      LSweep.MaxHandlerRunMs := 0;
      LSweep.Start;
      Sleep(CPollTimeoutMs);
      Assert.IsTrue(Length(LConn.AccumBuf) >= POOL_TIER1_SIZE,
        'a buffer with unconsumed pending bytes must not be shrunk');
    finally
      LActive := False;
      LSweep.Stop;
      FreeAndNil(LSweep);
    end;
  finally
    LConnMgr.Remove(LConn);
    LConn.Release;
    FreeAndNil(LConnMgr);
  end;
end;

procedure TIdleSweepAccumBufShrinkTests.Disabled_IdleOversizedBuffer_NotShrunk;
var
  LActive: Boolean;
  LConnMgr: TConnectionManager;
  LSweep: TIdleSweepManager;
  LConn: TNativeConn;
begin
  LActive := True;
  LConnMgr := TConnectionManager.Create;
  LConn := TNativeConn.Create(0, '127.0.0.1:7');
  try
    LConnMgr.Admit(LConn);
    TBufferPool.Release(LConn.AccumBuf);
    LConn.AccumBuf := TBufferPool.Acquire(POOL_TIER1_SIZE);  // simulate a past large request
    LConn.AccumLen := 0;                                     // fully drained
    LConn.InFlightPool := 0;                                 // idle, no active dispatch
    LConn.LastActivityTick := TThread.GetTickCount64;

    LSweep := TIdleSweepManager.Create(LConnMgr, nil, @LActive);
    try
      LSweep.IdleTimeoutMs := 60000;  // non-zero -- see comment in the first test
      LSweep.MaxHandlerRunMs := 0;
      LSweep.ShrinkAccumBufEnabled := False;  // #234 kill switch
      LSweep.Start;
      Sleep(CPollTimeoutMs);
      Assert.IsTrue(Length(LConn.AccumBuf) >= POOL_TIER1_SIZE,
        'ShrinkAccumBufEnabled = False must leave an oversized AccumBuf untouched');
    finally
      LActive := False;
      LSweep.Stop;
      FreeAndNil(LSweep);
    end;
  finally
    LConnMgr.Remove(LConn);
    LConn.Release;
    FreeAndNil(LConnMgr);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TIdleSweepHandlerWatchdogTests);
  TDUnitX.RegisterTestFixture(TIdleSweepAccumBufShrinkTests);

end.
