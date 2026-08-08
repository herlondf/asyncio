# Notas de Plataforma & Limitações Conhecidas

O Poseidon é dual-face: Windows (IOCP / RIO) e Linux (io_uring / epoll), e
compila sob **Delphi e Free Pascal**. O backend é escolhido uma vez na
construção (defines de compilação sobrepõem o padrão).

| Plataforma | Backend padrão | Alternativo | Define para forçar |
|---|---|---|---|
| Windows 64-bit | IOCP | RIO (Registered I/O) | `FORCE_RIO` |
| Linux 64-bit | io_uring | epoll | `FORCE_EPOLL` |

## Windows: I/O de extensão sobreposto do Winsock

O backend IOCP carrega `AcceptEx` / `GetAcceptExSockaddrs` via
`WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER, …)`. Alguns ambientes — certos
builds Windows Insider, ou hosts com um produto de segurança que faz hook do
catálogo Winsock — rejeitam essa chamada com `WSAEINVAL (10022)`. O Poseidon
trata isso **caindo para os exports estáticos do `mswsock.dll`** para o
`AcceptEx`, então o servidor continua funcional nesses hosts.

Um bug real (já corrigido) derrubava ~1-em-4 conexões sob churn: um socket
reciclado via `DisconnectEx(TF_REUSE_SOCKET)` permanece associado ao IOCP, e
re-chamar `CreateIoCompletionPort` retornava `ERROR_INVALID_PARAMETER`, tratado
como fatal. Isso agora é tolerado. A suíte de integração via socket passa limpa
(0 falhas ambientais toleradas).

## Linux: TLS

O build Linux (io_uring / epoll) serve tráfego HTTP puro **e** TLS. A corrida /
use-after-free de SSL pós-handshake que derrubava HTTPS/HTTP2-over-TLS foi
resolvida (todo acesso por conexão a SSL / `H2Conn` / accum-buffer agora é
serializado sob o lock da conexão; SIGPIPE ignorado). Evidência: h2spec **145/146
sobre TLS/ALPN** e Autobahn **247/247** verdes contra o backend io_uring do
Linux, e um soak de 5,4 h no io_uring sem leak/crash.

## OpenSSL

O TLS carrega o OpenSSL dinamicamente na primeira chamada de `ConfigureSSL` —
sem dependência em tempo de compilação:

- Windows: `libssl-3-x64.dll` / `libssl-1_1-x64.dll` (e `libcrypto`) no `PATH`.
- Linux: `libssl.so.3` / `libssl.so.1.1` (e `libcrypto`) — ex.:
  `apt install openssl` / `libssl3`.

## Free Pascal / Lazarus

O Poseidon compila e serve HTTP sob **FPC 3.3.1** (trunk) no Win64 (IOCP) e Linux
(io_uring / epoll), além do Delphi. O build Delphi é byte-idêntico (todo o
suporte a FPC fica atrás de `{$IFDEF FPC}` + a camada só-FPC `src/compat/`).

- **Compilador:** exige FPC **3.3.1** (trunk) — `reference to` / métodos anônimos
  e RTTI de atributos não existem no release 3.2.2. Flags:
  `-MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes`.
- **Threading no Linux:** `cthreads` deve ser a **primeira** unit do programa
  (`{$IFDEF UNIX}`) ou `TEvent` / `TThread` falham em runtime.
- **Modo de dispatch:** sob FPC o servidor usa **SyncDispatch** por padrão
  (dispatch inline na IO thread). O caminho async (worker pool) é best-effort — o
  trunk atual do FPC tem problemas de codegen de closure / startup de thread que
  o SyncDispatch evita. O Delphi mantém async por padrão.
- **`TMonitor`** é não-funcional no FPC; os pools usam `TCriticalSection` no ramo
  FPC.
- **Gates:** `tests/fpc/build-server-fpc.ps1` (Windows) e
  `tests/fpc/build-linux-fpc.sh` (Linux) buildam a clausura completa e rodam um
  smoke de serve HTTP real.
- **Crash handler ainda nao compila sob FPC:** `Poseidon.Diagnostics` (o
  handler de SIGSEGV/SIGABRT no Linux, ver
  [Diagnostico de crash](diagnostico-de-crash.md)) falha ao compilar sob FPC —
  `Poseidon.Compat.Posix.pas` esta sem as constantes de numero de sinal e os
  bindings brutos de `raise`/`write` da libc que aquela unit espera.
  Confirmado em 2026-08 ao construir um harness de benchmark FPC/Linux. Builds
  Delphi/`dcclinux64` nao sao afetados. Ate isso ser corrigido a montante, um
  deploy FPC/Linux roda **sem** o crash handler instalado.
