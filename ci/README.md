# CI harness (issue #204)

Two-face continuous integration for Poseidon: compile **and** test both the
Windows (IOCP/RIO) and Linux (epoll/io_uring) faces from a single entry point,
so a platform-specific bug can never sit latent behind an `{$IFDEF}` the other
platform never exercises.

## One command

```powershell
pwsh ci/run-ci.ps1                    # compile gate + fuzz + Win64 suite
pwsh ci/run-ci.ps1 -Linux             # + h2spec (TLS/ALPN h2) over WSL
pwsh ci/run-ci.ps1 -Linux -Autobahn   # + Autobahn WebSocket suite
```

Exit code `0` = all stages passed; non-zero otherwise.

## Stages

| Stage | What | Gate |
|-------|------|------|
| `compile-gate` | `dcc64` (Win64 test project) + `dcclinux64` (epoll/io_uring compile check) via `build-both-faces.ps1` | any COMPILE error fails |
| `fuzz` | socket-free `Poseidon.FuzzRunner.exe` — HTTP/1 + HPACK + WebSocket fuzz (60k iters each) and the deterministic invariant / smuggling guards | **100% green** (hard gate) |
| `win64-suite` | full DUnitX suite | any **new** failure fails; the 19 environmental Winsock failures (#203) are tolerated via `win64-known-failures.txt` |
| `h2spec` | HTTP/2 conformance over TLS/ALPN, reusing a provisioned WSL distro (CI-safe) | `>= total-1` passing (1 skip allowed) |
| `autobahn` | WebSocket conformance (Autobahn TestSuite) | zero failures |

## The Win64 baseline

On this project's Windows hosts the Winsock stack can reject `AcceptEx`/RIO
(`WSAEINVAL`, #203), so the socket-bound integration tests fail on Windows while
the Linux build serves fine. `win64-known-failures.txt` lists exactly those
tolerated failures; `run-ci.ps1` fails the build on any failure NOT in the list
and warns when a listed test starts passing (time to trim the baseline).

Regenerate the baseline only when the environment legitimately changes:

```powershell
[xml]$x = Get-Content tests/bin/DUnitX-Results.xml
$x.SelectNodes('//test-case') | ? { $_.success -ne 'True' } |
  % { $_.name } | Sort-Object -Unique
```

## O runner self-hosted

O CI só roda se existir um runner com as labels `self-hosted`, `windows`,
`delphi`. Sem ele os jobs ficam `queued` ate morrer no timeout de 24h, em
silencio: nao ha erro, nao ha notificacao, e o repositorio parece verde porque
nada nunca falha. Foi o que aconteceu entre 08-08 e 31-08 - 23 dias sem nenhuma
validacao, com `total_count: 0` na API de runners.

### Verificar se ha runner (primeira coisa a checar quando o CI nao roda)

```bash
gh api repos/herlondf/poseidon/actions/runners
# total_count: 0  -> nao existe runner, nao adianta esperar
```

### Instalar nesta maquina

Nao precisa de maquina nova nem de elevacao. Requisitos ja atendidos pelo host
de desenvolvimento: RAD Studio 22.0 com toolchain Linux64, WSL2 e as distros
`Benchmark` e `PoseidonH2Spec`.

```powershell
# 1. baixar e extrair (versao atual: 2.337.0)
$dir = 'D:ctions-runner'
New-Item -ItemType Directory -Force $dir | Out-Null
# baixe actions-runner-win-x64-<versao>.zip das releases de actions/runner
# e extraia em $dir

# 2. registrar (o token expira em 1h)
$tok = gh api -X POST repos/herlondf/poseidon/actions/runners/registration-token --jq '.token'
& "$dir\config.cmd" --url https://github.com/herlondf/poseidon --token $tok `
  --name "delphi-$env:COMPUTERNAME" --labels "self-hosted,windows,delphi" `
  --work "_work" --unattended --replace
```

### Por que tarefa agendada e nao servico

`svc.cmd install` exige elevacao, e aqui o servico seria pior: os jobs de
conformance usam WSL e Docker Desktop, que dependem da sessao interativa do
usuario. Um servico rodando como SYSTEM nao enxerga essa sessao. A tarefa
agendada roda no logon, na sessao certa, e sobrevive a reboot.

```powershell
$name = 'GitHubActionsRunner-Poseidon'
$act = New-ScheduledTaskAction -Execute "$dir\run.cmd" -WorkingDirectory $dir
$trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set
Start-ScheduledTask -TaskName $name
```

### Operacao

```powershell
Get-ScheduledTask -TaskName 'GitHubActionsRunner-Poseidon'   # estado
Stop-ScheduledTask  -TaskName 'GitHubActionsRunner-Poseidon' # pausar (maquina ocupada)
Start-ScheduledTask -TaskName 'GitHubActionsRunner-Poseidon' # retomar
```

O runner ocupa a maquina em cada push e PR na master, e a suite Win64 sobe
servidores reais em portas locais. Em maquina de trabalho, `Stop-ScheduledTask`
antes de uma sessao pesada evita disputa por CPU e porta.

## Linux conformance — one-time WSL provisioning

The Linux stages reuse **already-provisioned** WSL distros (they never recreate a
distro or run `wsl --shutdown`, so other distros on the machine are untouched):

- **`PoseidonH2Spec`** — provision once (creates the distro, installs OpenSSL +
  h2spec):
  ```powershell
  pwsh tests/run-h2spec.ps1            # first run: creates + provisions + runs
  pwsh tests/run-h2spec.ps1 -Reuse     # thereafter: rebuild ELF + re-run only
  ```
- **`Benchmark`** — a WSL distro with Docker, used to run the
  `crossbario/autobahn-testsuite` container. See `tests/autobahn/`.

## GitHub Actions

`.github/workflows/ci.yml` runs `run-ci.ps1` on a **self-hosted** Windows runner
(label `delphi`) — GitHub-hosted runners cannot build Poseidon (no RAD Studio).
The core `compile-and-test` job runs on every push/PR; the `linux-conformance`
job is opt-in via `workflow_dispatch` so a busy dev machine is not disrupted.
