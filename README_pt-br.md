# Poseidon

> *Deus dos mares — poder bruto, velocidade incomparavel.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  Framework HTTP assincrono nativo, zero dependencias, para Delphi e Free Pascal.<br/>
  IOCP/RIO no Windows, io_uring/epoll no Linux — HTTP/1.1, HTTP/2, WebSocket e 20 middlewares integrados de fabrica.<br/>
  <strong>128k RPS, zero erros com 500 conexoes simultaneas.</strong>
</p>

---

## Inicio Rapido

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
        Writeln('Servidor pronto em http://localhost:9000');
        Readln;
        App.Stop;
      end);
  finally
    App.Free;
  end;
end.
```

## Por que Poseidon

| | Poseidon v2 | Horse Epoll 4.0 |
|---|---|---|
| **Throughput** (500 conn, 16 cores) | **127.532 RPS** | 3.780 RPS (61% erros) |
| **Latencia p50** | **1,92ms** | 103ms |
| **Latencia p99** | **5,51ms** | 287ms |
| **Erros** | **0** | 35K+ Non-2xx |
| **Arquitetura** | Shared-nothing per-core | Single epoll |
| **HTTP/2** | Integrado | Nao |
| **WebSocket** | Integrado | Nao |
| **SSL/TLS** | OpenSSL nativo (SNI, mTLS, ALPN) | Via Indy |
| **Middlewares** | 20 integrados | Comunidade |
| **API Nativa** | Zero-copy, baseada em instancia | N/A |

## Arquitetura: Shared-Nothing Per-Core

<p align="center">
  <img src="docs/architecture-flow_pt-br.svg" alt="Fluxo de requisicoes shared-nothing per-core do Poseidon vs. o loop unico de epoll do Horse" width="880"/>
</p>

Cada core faz tudo: accept, recv, parse, executa handler, envia resposta. Sem filas, sem locks, sem contencao. Escalamento linear com o numero de cores.

O backend de I/O e selecionado **uma unica vez** na inicializacao, com fallback automatico: **IOCP** (padrao no Windows) ou **RIO** (opt-in, polling sem syscall via `FORCE_RIO`); **io_uring** >= 5.1 (padrao no Linux) ou **epoll** (fallback / opt-in via `FORCE_EPOLL`).

---

## Performance vs. o Mercado

Comparacao multi-framework — carga mista plaintext/JSON/JSON grande (40/30/30), `wrk -t4 -c200 -d300s`, rodada local sob limite de cgroup de 2 vCPU / 1 GB, com as duas correcoes de performance do Poseidon aplicadas (#231 TCP_CORK, #232 dimensionamento de workers ciente de cgroup):

| Posicao | Framework | Req/s | Latencia p99 |
|---:|---|---:|---:|
| 1 | uws | 54.223 | 6,40 ms |
| **2** | **Poseidon v2** | **53.920** | 67,30 ms |
| 3 | Actix | 52.708 | 7,03 ms |
| 4 | Go Fiber | 38.110 | 68,71 ms |
| 5 | mORMot2 | 33.372 | 46,99 ms |
| 6 | nginx | 27.393 | 71,61 ms |
| 7 | Kestrel | 23.785 | 54,12 ms |
| 8 | Horse (Epoll) | 2.475 | 493,02 ms |

Segundo lugar entre 8, a frente de todos os outros frameworks Delphi/Pascal e de todos os frameworks de proposito geral exceto o uws — e **21,8x o Horse**. O p99 reflete a fatia de JSON grande da carga mista; uws/Actix trocam superficie de funcionalidades por uma cauda mais achatada (ver a matriz abaixo). A metodologia completa vive no harness `Benchmark` separado (ponteiros em [`docs/playbook_pt-br/07-benchmarking`](docs/playbook_pt-br/07-benchmarking)); os numeros reproduziveis deste proprio repo estao em [`samples/08-benchmark/`](samples/08-benchmark/).

<p align="center">
  <img src="docs/framework-features_pt-br.svg" alt="Comparacao de recursos de protocolo do Poseidon contra 7 outros frameworks" width="880"/>
</p>

Toda mudanca no caminho quente e validada com uma comparacao controlada antes/depois antes de ser mergeada — mesmo binario, uma mudanca por vez. A rodada de parser/dispatcher de 2026-08-07 (removeu uma alocacao redundante no header `Connection`, pulou a varredura de deteccao de upgrade em GETs sem upgrade) mediu **+1,7% de throughput**, com toda repeticao do lado "depois" superando toda repeticao do lado "antes".

---

## Funcionalidades

**Engine** — HTTP/1.1 keep-alive · HTTP/2 (ALPN h2, h2c, server push, flow control) · WebSocket (RFC 6455, permessage-deflate) · HTTPS com OpenSSL nativo (SNI, mTLS) · Compressao gzip + Brotli · Proxy Protocol v1/v2 · Graceful reload (PID file, SIGTERM, zero-downtime) · Windows 64-bit (IOCP/RIO) + Linux 64-bit (io_uring/epoll) · Delphi 11+ e Free Pascal 3.3.1

**Framework** — Router hash-map, lookup O(1), suporte a `:param` · Registro fluente de rotas (Get/Post/Put/Delete/Patch/Head/All) · Contexto de requisicao zero-copy, stack-allocated · Binding de DTO com atributos de validacao · OpenAPI 3.x + Swagger UI · RFC 7807 Problem Details · Cookies assinados (HMAC-SHA256)

**Engenharia de performance** — Contadores atomicos com padding de cache-line · I/O vetorizado (writev/WSASend) · Arquivos registrados no io_uring + multishot accept · Reciclagem de sockets via DisconnectEx (Windows) · Arena de headers thread-local · Buffer pool de 8 KB (Acquire/Release)

**20 middlewares integrados** — CORS, JWT, Logger, RateLimit, Compression, Timeout, BodyLimit, RequestID, CircuitBreaker, Metrics, Static, HealthCheck, Security, Proxy, Digest, Guard, Validation, ProblemDetails, OpenAPI, Cache

---

## Requisitos

- **Delphi 11 Alexandria ou superior**, ou **Free Pascal 3.3.1** (trunk)
- Windows 64-bit ou Linux 64-bit
- OpenSSL no PATH (apenas para HTTPS/HTTP2)

## Instalacao

Adicione `src/`, `src/compat/` e `middlewares/` ao search path do projeto:

```
<poseidon>\src
<poseidon>\src\compat
<poseidon>\middlewares
```

### Free Pascal / Lazarus

O Poseidon compila e serve sob FPC 3.3.1 no Win64 (IOCP) e Linux (io_uring/epoll)
alem do Delphi. Notas:

- Requer **FPC 3.3.1** (trunk) — `reference to` / metodos anonimos e RTTI de
  atributos nao existem no release 3.2.2. Compile com
  `-MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes`.
- No Linux, `cthreads` deve ser a **primeira** unit do programa (`{$IFDEF UNIX}`)
  para ativar o RTL com threads.
- Sob FPC o servidor usa **SyncDispatch** por padrao (dispatch inline); o modo
  async (worker pool) e best-effort no trunk atual do FPC.
- Gates de referencia: `tests/fpc/build-server-fpc.ps1` (Windows),
  `tests/fpc/build-linux-fpc.sh` (Linux).

## Exemplos de Uso

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
  App.Use(JWTMiddleware('meu-segredo'));

  App.Get('/api/dados',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Status := 200;
      Ctx.ContentType := 'application/json';
      Ctx.Body := TEncoding.UTF8.GetBytes('{"dados":"protegidos"}');
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
App.AddSSLCert('api.exemplo.com', 'api-cert.pem', 'api-key.pem');  // SNI
App.EnableHTTP2;
App.Listen(443);
```

Mais receitas (grupos de rotas, graceful reload, hardening de seguranca, metricas) vivem no [playbook](docs/playbook_pt-br/README.md).

---

## Documentacao

- [Referência de API](docs/API-REFERENCE_pt-br.md) · [API Reference (EN)](docs/API-REFERENCE.md)
- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Portugues)](docs/playbook_pt-br/README.md)
- [FuzzRunner — fuzzing contínuo dos parsers](tests/FUZZING.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## A Familia Olimpica

> *Poseidon comanda os mares — poder bruto, a engine assíncrona sob as ondas.*
> *Triton, seu filho, guarda as profundezas — retém as conexões que não podem se perder.*
> *Hermes percorre todos os reinos — carrega mensagens, mais rápido que qualquer onda.*
> *Hefesto forja nas profundezas — invisível, incansável, transformando matéria bruta em obra acabada.*
> *Apollo é o deus da luz e da verdade — traz tudo à luz.*

| Projeto | Mito | Papel |
|---------|------|-------|
| **Poseidon** (este) | Deus dos mares | Framework HTTP assíncrono nativo + engine de I/O — IOCP/RIO, io_uring/epoll |
| [**Triton**](https://github.com/herlondf/triton) | Filho de Poseidon, guardião das profundezas | Pool de recursos genérico — conexões, clientes, SMTP |
| [**Hermes**](https://github.com/herlondf/hermes) | Mensageiro dos deuses, guia entre os reinos | Cliente Redis — chave-valor, pub/sub, mensageria |
| [**Hefesto**](https://github.com/herlondf/hefesto) | Forjador dos deuses, trabalha nas sombras | Jobs em background — filas, workers, retry, agendamento |
| [**Apollo**](https://github.com/herlondf/apollo) | Deus da luz e da verdade, traz as coisas à luz | Logging estruturado — sinks assíncronos, OTLP, Seq, Loki, Datadog |

---

## Licenca

MIT

---

> 🇺🇸 Read this document in English: [README.md](./README.md)
