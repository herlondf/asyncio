# 08 — Native API

Reference for `TPoseidonServer` and its associated types. This is the primary
interface for building HTTP services directly on Poseidon without a higher-level
framework provider.

---

## TPoseidonServer

`TPoseidonServer` is the central object of every Poseidon application. It owns
the listener socket, worker pool, buffer pool, and route table. Create one
instance per process (multiple instances on distinct ports are supported).

```pascal
var
  LApp: TPoseidonServer;
begin
  LApp := TPoseidonServer.Create;
  try
    LApp.WorkerCount := 8;
    LApp.MaxConnections := 10000;
    LApp.Get('/ping', procedure(var ACtx: TNativeRequestContext)
    begin
      ACtx.Body := TEncoding.UTF8.GetBytes('pong');
    end);
    LApp.Listen(9000);
  finally
    LApp.Free;
  end;
end;
```

---

## TNativeRequestContext

`TNativeRequestContext` is a stack-allocated record that represents a single
HTTP request/response pair. It is passed by `var` reference to every route
handler and middleware — no heap allocation, no reference counting.

Key fields:

| Field | Type | Description |
|-------|------|-------------|
| `Method` | `string` | HTTP verb (GET, POST, …) |
| `Path` | `string` | URL path, without query string |
| `QueryString` | `string` | Raw query string (after `?`) |
| `Headers` | `TArray<TPair<string,string>>` | Request headers |
| `RawBody` | `TBytes` | Raw inbound request body |
| `Status` | `Integer` | HTTP response status code (default 200) |
| `ContentType` | `string` | Response `Content-Type` header |
| `Body` | `TBytes` | Response body bytes |
| `ExtraHeaders` | `TArray<TPair<string,string>>` | Additional response headers |

### Accessing parameters

```pascal
// Route parameter defined as /users/:id
var LId: string;
LId := ACtx.Param('id');

// Query string parameter (?page=2)
var LPage: string;
LPage := ACtx.Query('page');

// Request header
var LAuth: string;
LAuth := ACtx.Header('Authorization');
```

### Setting the response

```pascal
var LLen: Integer;

ACtx.Status      := 201;
ACtx.ContentType := 'application/json';
ACtx.Body        := TEncoding.UTF8.GetBytes('{"id":42}');

LLen := Length(ACtx.ExtraHeaders);
SetLength(ACtx.ExtraHeaders, LLen + 1);
ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create('X-Request-Id', '...');
```

---

## Route registration

All registration methods return `Self`, enabling a fluent call chain.

```pascal
App
  .Get('/users',         HandleListUsers)
  .Post('/users',        HandleCreateUser)
  .Put('/users/:id',     HandleReplaceUser)
  .Patch('/users/:id',   HandleUpdateUser)
  .Delete('/users/:id',  HandleDeleteUser)
  .Head('/users',        HandleHead)
  .All('/probe',         HandleAny);
```

Signatures accepted by every verb method:

```pascal
// Simple handler
procedure(var ACtx: TNativeRequestContext)

// Handler with next (same as middleware)
procedure(var ACtx: TNativeRequestContext; ANext: TProc)
```

Route parameters use `:name` syntax. Wildcard segments use `*`.

---

## Middleware

### Type definition

```pascal
TNativeMiddlewareFunc =
  reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

Calling `ANext` passes control to the next middleware or to the route handler.
Not calling `ANext` short-circuits the chain (useful for auth, rate limiting).

### Global middleware

```pascal
App.Use(LoggerMiddleware);
App.Use(CORSMiddleware);
App.Use(RequestIDMiddleware);
```

Middleware is executed in registration order before every matched route.

### Per-route middleware

```pascal
App.Get('/admin', JWTMiddleware('secret'), HandleAdmin);
```

Multiple middleware arguments are accepted before the final handler.

---

## Route groups

Groups apply a common prefix (and optionally shared middleware) to a set of routes.

### Inline group

```pascal
var LApi: TNativeGroup;
LApi := App.Group('/api/v1');
LApi.Get('/users', HandleListUsers);
LApi.Post('/users', HandleCreateUser);
```

### Block group

```pascal
App.GroupBlock('/api/v1',
  procedure(G: TNativeGroup)
  begin
    G.Get('/users',  HandleListUsers);
    G.Post('/users', HandleCreateUser);
  end);
```

Groups cannot be nested — `TNativeGroup` does not expose its own `Group`/
`GroupBlock`. Middleware passed to `Group` or `GroupBlock` applies only
to routes registered within that group.

---

## WebSocket

```pascal
App.WebSocket('/ws/chat',
  procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
  begin
    if AFrame.Opcode = OPCODE_TEXT then
      AConn.Send('echo: ' + TEncoding.UTF8.GetString(AFrame.Payload))
    else if AFrame.Opcode = OPCODE_BINARY then
      AConn.SendBinary(AFrame.Payload)
    else if AFrame.Opcode = OPCODE_CLOSE then
      AConn.Close(1000);
  end);
```

The WebSocket upgrade is handled automatically when the client sends a valid
`Upgrade: websocket` request to the registered path. `TWebSocketFrame.Payload`
carries the raw frame bytes — decode with `TEncoding.UTF8.GetString` for text
frames (`OPCODE_TEXT`).

---

## Lifecycle

```pascal
// Start listening (blocks until Stop is called from another thread or signal)
App.Listen(9000);

// Stop accepting new connections and drain existing ones
App.Stop;
```

`Listen` returns only after `Stop` completes the drain phase. `DrainTimeoutMs`
controls how long Poseidon waits for in-flight requests before forcibly closing
connections.

---

## Graceful reload

```pascal
App.PerCoreAccept := True;              // enables SO_REUSEPORT (Linux)
App.PIDFile        := '/run/poseidon.pid';
InstallSignalHandler(procedure begin App.Stop; end); // Linux only
App.Listen(8080);
```

`InstallSignalHandler` (Linux-only, `{$IFNDEF MSWINDOWS}`) installs a
`SIGTERM`/`SIGINT` handler that sets an atomic flag; `Listen`'s internal wait
loop polls it every 500 ms and invokes the callback. For a zero-downtime
deploy: start the new process (it binds the same port alongside the old one
via `SO_REUSEPORT`, enabled by `PerCoreAccept`), then `kill -TERM` the old
process's PID (read from `PIDFile`) to trigger its graceful `Stop`.

On Windows, the PID file is written but `InstallSignalHandler` is not
available — use a service manager restart instead.

---

## Configuration properties

| Property | Type | Description |
|----------|------|-------------|
| `MaxConnections` | `Integer` | Max total concurrent connections |
| `MaxConnectionsPerIP` | `Integer` | Max concurrent connections per client IP |
| `WorkerCount` | `Integer` | Max worker-thread pool size |
| `MinWorkerCount` | `Integer` | Minimum (baseline) worker-thread count |
| `IOWorkerCount` | `Integer` | IO-event threads (recv/send only). `0` = auto: one per available CPU, capped at 16 |
| `IdleTimeoutMs` | `Integer` | Idle connection timeout, default 10000 ms |
| `MaxRequestSize` | `Integer` | Max accepted request body size, default 8 MB |
| `MaxHeaderSize` | `Integer` | Max accepted header block size, default 65536 bytes |
| `DrainTimeoutMs` | `Integer` | Graceful-drain timeout on `Stop`, default 30000 ms |
| `MaxQueueDepth` | `Integer` | Max depth of the worker dispatch queue (0 = unbounded) |
| `SecureHeadersEnabled` | `Boolean` | Toggles automatic security response headers, default False |
| `ServerBanner` | `string` | Value sent in the `Server` response header, default `'Poseidon/1.0'` |
| `TCPFastOpen` | `Boolean` | Enables TCP Fast Open on the listener, default False |
| `PerCoreAccept` | `Boolean` | Enable `SO_REUSEPORT` per-core accept (Linux), default False |
| `SyncDispatch` | `Boolean` | Dispatches on the IO thread instead of the worker pool. **Also gates SQE batching on the io_uring backend**: without it the ring submits one syscall per operation and lands slower than epoll (measured 70,075 vs 52,446 req/s on the same binary). Non-blocking handlers only - one that waits on a database stalls the IO thread |
| `PIDFile` | `string` | Path to write the process PID file, default `''` |

> See [API-REFERENCE.md](../../API-REFERENCE.md) for the authoritative, hand-maintained
> property list — kept in sync with `src/Poseidon.Native.Server.pas` on every public API change.

---

## SSL / TLS

```pascal
// Single certificate
App.ConfigureSSL('cert.pem', 'key.pem');

// Multiple SNI certificates
App.AddSSLCert('example.com',  'example.pem',  'example.key');
App.AddSSLCert('api.example.com', 'api.pem', 'api.key');

// Mutual TLS (client certificate required)
App.ConfigureMTLS('ca.pem');

// HTTP/2 (requires SSL)
App.EnableHTTP2;

App.Listen(443);
```

SSL is handled by the built-in OpenSSL wrapper. Certificate files are read
once, at `Listen` time — picking up renewed certificates requires a graceful
reload (new process, own fresh `Listen` call; see above), not an in-process
hot-reload.

---

## See also

- [02 — Core Concepts](../02-core-concepts/README.md)
- [09 — Middlewares](../09-middlewares/README.md)
- [05 — Recipes](../05-recipes/README.md)
