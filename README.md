# Poseidon

> *God of the seas — raw power, unmatched speed.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  Zero-dependency, native async HTTP framework for Delphi and Free Pascal.<br/>
  IOCP/RIO on Windows, io_uring/epoll on Linux — HTTP/1.1, HTTP/2, WebSocket and 20 built-in middlewares out of the box.<br/>
  <strong>128k RPS, zero errors under 500 concurrent connections.</strong>
</p>

---

## Quick Start

```pascal
program MyServer;
{$APPTYPE CONSOLE}
uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"message":"pong"}');
      end);

    App.Get('/hello/:name',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"hello":"' + Ctx.Param('name') + '"}');
      end);

    App.Listen(9000, '0.0.0.0',
      procedure
      begin
        Writeln('Server ready on http://localhost:9000');
        Readln;
        App.Stop;
      end);
  finally
    App.Free;
  end;
end.
```

## Why Poseidon

| | Poseidon v2 | Horse Epoll 4.0 |
|---|---|---|
| **Throughput** (500 conn, 16 cores) | **127,532 RPS** | 3,780 RPS (61% errors) |
| **Latency p50** | **1.92ms** | 103ms |
| **Latency p99** | **5.51ms** | 287ms |
| **Errors** | **0** | 35K+ Non-2xx |
| **Architecture** | Shared-nothing per-core | Single epoll |
| **HTTP/2** | Built-in | No |
| **WebSocket** | Built-in | No |
| **SSL/TLS** | Native OpenSSL (SNI, mTLS, ALPN) | Via Indy |
| **Middlewares** | 20 built-in | Community |
| **Native API** | Zero-copy, instance-based | N/A |

## Architecture: Shared-Nothing Per-Core

```
Kernel distributes via SO_REUSEPORT (IP hash)
              │
    ┌─────────┼─────────┐
    ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐
│ Core 0 │ │ Core 1 │ │ Core N │
│ listen │ │ listen │ │ listen │  ← own socket
│ epoll  │ │ epoll  │ │ epoll  │  ← own epoll fd
│ accept │ │ accept │ │ accept │
│ recv   │ │ recv   │ │ recv   │  ← all inline
│ parse  │ │ parse  │ │ parse  │
│ handle │ │ handle │ │ handle │
│ send   │ │ send   │ │ send   │
└────────┘ └────────┘ └────────┘
  ~170 conn  ~170 conn  ~170 conn
```

Each core does everything: accept, recv, parse, execute handler, send response. No queues, no locks, no contention. Linear scaling with core count.

The I/O backend is selected **once** at startup, with automatic fallback: **IOCP** (Windows default) or **RIO** (opt-in, zero-syscall polling via `FORCE_RIO`); **io_uring** ≥ 5.1 (Linux default) or **epoll** (fallback / opt-in via `FORCE_EPOLL`).

---

## Features

**Engine** — HTTP/1.1 keep-alive · HTTP/2 (ALPN h2, h2c, server push, flow control) · WebSocket (RFC 6455, permessage-deflate) · HTTPS native OpenSSL (SNI, mTLS) · gzip + Brotli compression · Proxy Protocol v1/v2 · Graceful reload (PID file, SIGTERM, zero-downtime) · Windows 64-bit (IOCP/RIO) + Linux 64-bit (io_uring/epoll) · Delphi 11+ and Free Pascal 3.3.1

**Framework** — Hash-map router, O(1) lookup, `:param` support · Fluent route registration (Get/Post/Put/Delete/Patch/Head/All) · Zero-copy, stack-allocated request context · DTO binding with validation attributes · OpenAPI 3.x + Swagger UI · RFC 7807 Problem Details · Signed cookies (HMAC-SHA256)

**Performance engineering** — Cache-line padded atomic counters · Vectored I/O (writev/WSASend) · io_uring registered files + multishot accept · DisconnectEx socket recycling (Windows) · Thread-local header arena · 8 KB buffer pool (Acquire/Release)

**20 built-in middlewares** — CORS, JWT, Logger, RateLimit, Compression, Timeout, BodyLimit, RequestID, CircuitBreaker, Metrics, Static, HealthCheck, Security, Proxy, Digest, Guard, Validation, ProblemDetails, OpenAPI, Cache

---

## Requirements

- **Delphi 11 Alexandria or later**, or **Free Pascal 3.3.1** (trunk)
- Windows 64-bit or Linux 64-bit
- OpenSSL in PATH (only for HTTPS/HTTP2)

## Installation

Add `src/`, `src/compat/` and `middlewares/` to your project search path:

```
<poseidon>\src
<poseidon>\src\compat
<poseidon>\middlewares
```

### Free Pascal / Lazarus

Poseidon compiles and serves under FPC 3.3.1 on Win64 (IOCP) and Linux
(io_uring/epoll) in addition to Delphi. Notes:

- Requires **FPC 3.3.1** (trunk) — `reference to` / anonymous methods and
  attribute RTTI are not in the 3.2.2 release. Compile with
  `-MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes`.
- On Linux, make `cthreads` the **first** unit of your program (`{$IFDEF UNIX}`)
  so the threaded RTL is active.
- Under FPC the server defaults to **SyncDispatch** (inline dispatch); the async
  worker-pool mode is best-effort on the current FPC trunk.
- Reference build/run gates: `tests/fpc/build-server-fpc.ps1` (Windows),
  `tests/fpc/build-linux-fpc.sh` (Linux).

## Usage Examples

### Middleware

```pascal
uses
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Middleware.CORS,
  Poseidon.Middleware.JWT,
  Poseidon.Middleware.Logger;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;

  App.Use(CORSMiddleware);
  App.Use(LoggerMiddleware);
  App.Use(JWTMiddleware('my-secret'));

  App.Get('/api/data',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Status := 200;
      Ctx.ContentType := 'application/json';
      Ctx.Body := TEncoding.UTF8.GetBytes('{"data":"protected"}');
    end);

  App.Listen(9000);
end.
```

### WebSocket

```pascal
App.WebSocket('/ws',
  procedure(Conn: IPoseidonWSConn; MsgType: Byte; Data: TBytes)
  begin
    Conn.Send(Data);  // echo
  end);
```

### SSL/TLS

```pascal
App.ConfigureSSL('cert.pem', 'key.pem');
App.AddSSLCert('api.example.com', 'api-cert.pem', 'api-key.pem');  // SNI
App.EnableHTTP2;
App.Listen(443);
```

More recipes (route groups, graceful reload, security hardening, metrics) live in the [playbook](docs/playbook/README.md).

---

## Documentation

- [API Reference](docs/API-REFERENCE.md) · [Referência de API (pt-BR)](docs/API-REFERENCE_pt-br.md)
- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Portugues)](docs/playbook_pt-br/README.md)
- [FuzzRunner — continuous parser fuzzing](tests/FUZZING.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## The Olympian Family

> *Poseidon commands the seas — raw power, the async engine beneath the waves.*
> *Triton, his son, guards the depths — holds the connections that must not be lost.*
> *Hermes runs between all realms — carries messages, faster than any wave.*
> *Hefesto forges in the depths — invisible, tireless, turning raw material into finished work.*
> *Apollo is the god of light and truth — brings everything to light.*

| Project | Myth | Role |
|---------|------|------|
| **Poseidon** (this) | God of the seas | Async-native HTTP framework + I/O engine — IOCP/RIO, io_uring/epoll |
| [**Triton**](https://github.com/herlondf/triton) | Son of Poseidon, guardian of the depths | Generic resource pool — connections, clients, SMTP |
| [**Hermes**](https://github.com/herlondf/hermes) | Messenger of the gods, guide between realms | Redis client — key-value, pub/sub, messaging |
| [**Hefesto**](https://github.com/herlondf/hefesto) | Forgemaster of the gods, works unseen | Background jobs — queues, workers, retry, scheduling |
| [**Apollo**](https://github.com/herlondf/apollo) | God of light and truth, brings things to light | Structured logging — async sinks, OTLP, Seq, Loki, Datadog |

---

## License

MIT

---

> 🇧🇷 Leia este documento em portugues: [README_pt-br.md](./README_pt-br.md)
