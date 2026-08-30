unit Poseidon.Tests.Heartbeat;

// DUnitX integration test for the periodic [health] heartbeat line -
// specifically the rss_kb field added to help diagnose memory growth in
// production (issue #235). Proves the platform-specific process-memory
// read (Winapi.PsAPI on Windows, /proc/self/status on Linux) actually
// returns a sane positive value at runtime, not just that it compiles.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  THeartbeatTests = class
  public
    [Test] procedure Heartbeat_EmitsHealthLine_WithPositiveRSS;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.RegularExpressions,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer;

const
  HEARTBEAT_PORT = 19012;

procedure THeartbeatTests.Heartbeat_EmitsHealthLine_WithPositiveRSS;
var
  LServer: TPoseidonNativeServer;
  LReady: TEvent;
  LHealthLine: string;
  LGotLine: Boolean;
  LWaited: Integer;
  LMatch: TMatch;
  LRssKB: Int64;
begin
  LGotLine := False;
  LHealthLine := '';
  LReady := TEvent.Create(nil, True, False, '');
  try
    LServer := TPoseidonNativeServer.Create;
    try
      LServer.HeartbeatMs := 100;  // fast tick - this test should not take seconds
      LServer.OnLog :=
        procedure(ALevel: TLogLevel; const AMessage: string)
        begin
          if (not LGotLine) and AMessage.Contains('[health]') then
          begin
            LHealthLine := AMessage;
            LGotLine := True;
          end;
        end;
      TThread.CreateAnonymousThread(
        procedure
        begin
          LServer.Listen('127.0.0.1', HEARTBEAT_PORT,
            procedure(const AReq: TPoseidonNativeRequest;
              out AStatus: Integer; out AContentType: string;
              out ABody: TBytes;
              out AExtraHeaders: TArray<TPair<string,string>>)
            begin
              AStatus := 200; AContentType := 'text/plain';
              ABody := TEncoding.UTF8.GetBytes('ok'); AExtraHeaders := [];
            end,
            procedure begin LReady.SetEvent; end);
        end).Start;
      Assert.AreEqual(TWaitResult.wrSignaled, LReady.WaitFor(5000),
        'Heartbeat test server did not start within 5 s');

      LWaited := 0;
      while (not LGotLine) and (LWaited < 3000) do
      begin
        Sleep(50);
        Inc(LWaited, 50);
      end;
      Assert.IsTrue(LGotLine,
        'No [health] line was logged within 3 s of HeartbeatMs=100');

      LMatch := TRegEx.Match(LHealthLine, 'rss_kb=(-?\d+)');
      Assert.IsTrue(LMatch.Success,
        'Health line does not contain rss_kb=<n>: ' + LHealthLine);
      LRssKB := StrToInt64(LMatch.Groups[1].Value);
      // -1 is the documented "could not read" sentinel; anything else must be
      // a real, positive resident-set size. A live process is never 0 KB.
      Assert.IsTrue(LRssKB > 0,
        'rss_kb must be a positive KB value, got ' + IntToStr(LRssKB) +
        ' (line: ' + LHealthLine + ')');
    finally
      LServer.Stop;
      LServer.Free;
    end;
  finally
    LReady.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(THeartbeatTests);

end.
