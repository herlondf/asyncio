# 08 — API Nativa

Referência de `TPoseidonServer` e seus tipos associados. Esta é a interface
principal para construir serviços HTTP diretamente sobre o Poseidon, sem um
provider de framework de nível mais alto.

---

## TPoseidonServer

`TPoseidonServer` é o objeto central de toda aplicação Poseidon. Ele possui o
socket de escuta, o worker pool, o buffer pool e a tabela de rotas. Crie uma
instância por processo (múltiplas instâncias em portas distintas são
suportadas).

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

`TNativeRequestContext` é um record alocado na stack que representa um par
requisição/resposta HTTP. É passado por referência (`var`) para cada handler
de rota e middleware — sem alocação em heap, sem contagem de referências.

Campos principais:

| Campo | Tipo | Descrição |
|-------|------|-----------|
| `Method` | `string` | Verbo HTTP (GET, POST, …) |
| `Path` | `string` | Caminho da URL, sem query string |
| `QueryString` | `string` | Query string bruta (após o `?`) |
| `Headers` | `TArray<TPair<string,string>>` | Headers da requisição |
| `RawBody` | `TBytes` | Corpo bruto da requisição |
| `Status` | `Integer` | Código HTTP de resposta (padrão 200) |
| `ContentType` | `string` | Header `Content-Type` da resposta |
| `Body` | `TBytes` | Bytes do corpo da resposta |
| `ExtraHeaders` | `TArray<TPair<string,string>>` | Headers adicionais da resposta |

### Acessando parâmetros

```pascal
// Parametro de rota definido como /usuarios/:id
var LId: string;
LId := ACtx.Param('id');

// Parametro de query string (?page=2)
var LPage: string;
LPage := ACtx.Query('page');

// Header da requisicao
var LAuth: string;
LAuth := ACtx.Header('Authorization');
```

### Definindo a resposta

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

## Registro de rotas

Todos os métodos de registro retornam `Self`, permitindo encadeamento fluente.

```pascal
App
  .Get('/usuarios',         HandleListUsers)
  .Post('/usuarios',        HandleCreateUser)
  .Put('/usuarios/:id',     HandleReplaceUser)
  .Patch('/usuarios/:id',   HandleUpdateUser)
  .Delete('/usuarios/:id',  HandleDeleteUser)
  .Head('/usuarios',        HandleHead)
  .All('/probe',            HandleAny);
```

Assinaturas aceitas por todo método de verbo:

```pascal
// Handler simples
procedure(var ACtx: TNativeRequestContext)

// Handler com next (igual ao middleware)
procedure(var ACtx: TNativeRequestContext; ANext: TProc)
```

Parâmetros de rota usam a sintaxe `:nome`. Segmentos curinga usam `*`.

---

## Middleware

### Definição de tipo

```pascal
TNativeMiddlewareFunc =
  reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

Chamar `ANext` passa o controle para o próximo middleware ou para o handler
da rota. Não chamar `ANext` interrompe a cadeia (útil para autenticação,
rate limiting).

### Middleware global

```pascal
App.Use(LoggerMiddleware);
App.Use(CORSMiddleware);
App.Use(RequestIDMiddleware);
```

Middlewares são executados na ordem de registro, antes de cada rota
correspondente.

### Middleware por rota

```pascal
App.Get('/admin', JWTMiddleware('segredo'), HandleAdmin);
```

Múltiplos argumentos de middleware são aceitos antes do handler final.

---

## Grupos de rotas

Grupos aplicam um prefixo comum (e opcionalmente middleware compartilhado) a
um conjunto de rotas.

### Grupo inline

```pascal
var LApi: TNativeGroup;
LApi := App.Group('/api/v1');
LApi.Get('/usuarios', HandleListUsers);
LApi.Post('/usuarios', HandleCreateUser);
```

### Grupo em bloco

```pascal
App.GroupBlock('/api/v1',
  procedure(G: TNativeGroup)
  begin
    G.Get('/usuarios',  HandleListUsers);
    G.Post('/usuarios', HandleCreateUser);
  end);
```

Grupos não podem ser aninhados — `TNativeGroup` não expõe `Group`/
`GroupBlock` próprios. Middleware passado a `Group` ou `GroupBlock` se aplica
apenas às rotas registradas dentro daquele grupo.

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

O upgrade de WebSocket é tratado automaticamente quando o cliente envia uma
requisição `Upgrade: websocket` válida para o caminho registrado.
`TWebSocketFrame.Payload` carrega os bytes brutos do frame — decodifique com
`TEncoding.UTF8.GetString` para frames de texto (`OPCODE_TEXT`).

---

## Ciclo de vida

```pascal
// Inicia a escuta (bloqueia ate Stop ser chamado de outra thread ou sinal)
App.Listen(9000);

// Para de aceitar novas conexoes e drena as existentes
App.Stop;
```

`Listen` só retorna após `Stop` completar a fase de drenagem.
`DrainTimeoutMs` controla quanto tempo o Poseidon espera por requisições em
andamento antes de fechar as conexões à força.

---

## Graceful reload

```pascal
App.PerCoreAccept := True;              // habilita SO_REUSEPORT (Linux)
App.PIDFile        := '/run/poseidon.pid';
InstallSignalHandler(procedure begin App.Stop; end); // apenas Linux
App.Listen(8080);
```

`InstallSignalHandler` (somente Linux, `{$IFNDEF MSWINDOWS}`) instala um
handler de `SIGTERM`/`SIGINT` que apenas seta uma flag atômica; o loop de
espera interno do `Listen` faz polling dela a cada 500 ms e invoca o
callback. Para um deploy sem downtime: suba o processo novo (ele faz bind na
mesma porta ao lado do antigo via `SO_REUSEPORT`, habilitado por
`PerCoreAccept`), depois mande `kill -TERM` no PID do processo antigo (lido
de `PIDFile`) para disparar seu `Stop` gracioso.

No Windows, o arquivo de PID é gravado, mas `InstallSignalHandler` não está
disponível — use um restart via gerenciador de serviços.

---

## Propriedades de configuração

| Propriedade | Tipo | Descrição |
|-------------|------|-----------|
| `MaxConnections` | `Integer` | Máximo de conexões simultâneas |
| `MaxConnectionsPerIP` | `Integer` | Máximo de conexões simultâneas por IP de cliente |
| `WorkerCount` | `Integer` | Tamanho máximo do worker pool |
| `MinWorkerCount` | `Integer` | Quantidade mínima (baseline) de worker threads |
| `IdleTimeoutMs` | `Integer` | Timeout de conexão ociosa, padrão 10000 ms |
| `MaxRequestSize` | `Integer` | Tamanho máximo aceito do corpo da requisição, padrão 8 MB |
| `MaxHeaderSize` | `Integer` | Tamanho máximo aceito do bloco de headers, padrão 65536 bytes |
| `DrainTimeoutMs` | `Integer` | Timeout de drenagem graciosa no `Stop`, padrão 30000 ms |
| `MaxQueueDepth` | `Integer` | Profundidade máxima da fila de dispatch do worker (0 = ilimitado) |
| `SecureHeadersEnabled` | `Boolean` | Ativa headers automáticos de segurança, padrão False |
| `ServerBanner` | `string` | Valor enviado no header `Server` da resposta, padrão `'Poseidon/1.0'` |
| `TCPFastOpen` | `Boolean` | Habilita TCP Fast Open no listener, padrão False |
| `PerCoreAccept` | `Boolean` | Habilita `SO_REUSEPORT` por core (Linux), padrão False |
| `SyncDispatch` | `Boolean` | Despacha na thread de I/O em vez do worker pool |
| `PIDFile` | `string` | Caminho para gravar o arquivo de PID do processo, padrão `''` |

> Veja [API-REFERENCE.md](../../API-REFERENCE.md) para a lista de propriedades
> autoritativa e mantida manualmente — sincronizada com
> `src/Poseidon.Native.Server.pas` a cada mudança de API pública.

---

## SSL / TLS

```pascal
// Certificado unico
App.ConfigureSSL('cert.pem', 'key.pem');

// Multiplos certificados SNI
App.AddSSLCert('example.com',  'example.pem',  'example.key');
App.AddSSLCert('api.example.com', 'api.pem', 'api.key');

// mTLS (exige certificado do cliente)
App.ConfigureMTLS('ca.pem');

// HTTP/2 (requer SSL)
App.EnableHTTP2;

App.Listen(443);
```

SSL é tratado pelo wrapper OpenSSL embutido. Os arquivos de certificado são
lidos uma única vez, no momento do `Listen` — para usar certificados
renovados é preciso um graceful reload (processo novo, com seu próprio
`Listen`; veja acima), não há hot-reload dentro do mesmo processo.

---

## Veja também

- [02 — Conceitos Core](../02-conceitos-core/README.md)
- [09 — Middlewares](../09-middlewares/README.md)
- [05 — Receitas](../05-receitas/README.md)
