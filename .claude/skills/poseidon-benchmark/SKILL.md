---
name: poseidon-benchmark
description: Medir performance do Poseidon (throughput req/s, latência p50/p99, saturação/knee, uso de CPU/memória, vazamento sob carga) e perfilar hot paths, dirigindo o harness externo do repositório Benchmark (D:\IA\Projetos\Delphi\Benchmark — k6 + wrk + Docker + Nginx LB + Grafana/InfluxDB/Tempo/SigNoz). Use SEMPRE que pedirem para benchmarkar/medir/perfilar o Poseidon, comparar v1↔v2 ou Horse↔Poseidon, verificar se uma mudança regrediu performance, ou decidir se um item de perf "vale a pena" (benchmark-gated). É uma skill-PONTE: faz o preparo do lado Poseidon e delega a execução às 11 skills benchmark-* do repo Benchmark. NÃO duplica o harness.
---

# Benchmark & profiling do Poseidon — skill-ponte

O harness NÃO vive aqui. Ele está em **`D:\IA\Projetos\Delphi\Benchmark`**
(builds PowerShell no Windows; runs em WSL, distro `Benchmark` Ubuntu; alvos em
Docker; k6/wrk nativos). Este repositório (`D:\IA\Projetos\Delphi\Poseidon`) é a
**fonte canônica** do código v2. Esta skill: (1) faz o preparo do lado Poseidon,
(2) mapeia objetivo → script/skill certo do Benchmark, (3) fecha o loop
resultado → código do Poseidon.

## ⚠️ REGRA DE FERRO nº1 — sincronizar antes de medir

`Benchmark\vendor\poseidon-v2\` é uma **cópia rastreada, NÃO sincronizada** (não
é submódulo, nenhum script a atualiza) e **frequentemente está atrasada** em
relação a este repo. Medir sem sincronizar = medir código VELHO — foi exatamente
isso que fez rodadas anteriores obterem 9.6K req/s onde o esperado era ~128K
(ver `Benchmark\docs\PROMPT-COMO-COMPILAR-POSEIDON-V2.md`, histórico).

Antes de QUALQUER build/run:

```bash
# 1. Espelhar o código canônico na cópia vendorizada
cp -r "D:/IA/Projetos/Delphi/Poseidon/src/."         "D:/IA/Projetos/Delphi/Benchmark/vendor/poseidon-v2/src/"
cp -r "D:/IA/Projetos/Delphi/Poseidon/middlewares/." "D:/IA/Projetos/Delphi/Benchmark/vendor/poseidon-v2/middlewares/"
# 2. Purgar objetos velhos — dcclinux64 reusa .o/.dcu silenciosamente (binário stale)
find "D:/IA/Projetos/Delphi/Benchmark/vendor/" -name "*.o"   -delete
find "D:/IA/Projetos/Delphi/Benchmark/vendor/" -name "*.dcu" -delete
```

Confirme que casou: `diff -rq D:/IA/Projetos/Delphi/Poseidon/src D:/IA/Projetos/Delphi/Benchmark/vendor/poseidon-v2/src` deve sair vazio.
`build.ps1` auto-descobre todo `vendor/**/*.pas` no search path — copiar basta,
sem editar path.

## As 11 skills do Benchmark (delegue, não reimplemente)

Rodam DENTRO do repo Benchmark (skills são project-scoped). As três centrais para
esta ponte: **benchmark-linux-build**, **benchmark-infra-stack**,
**benchmark-run-scenario**.

- `benchmark-run-scenario` — escolhe qual `run-*.sh`, mapeia framework→binário→k6, VUs/duração/instâncias, pré-checa infra+binário. **Ponto de entrada da execução.**
- `benchmark-linux-build` — cross-compile Linux64 (dcclinux64), defines por framework, diagnóstico de binário stale / Runtime error 217.
- `benchmark-infra-stack` — sobe/derruba o Docker Compose (Postgres, Redis, InfluxDB, Tempo, Grafana, Nginx), datasources, reset de volumes.
- `benchmark-saturation-test` — breakpoint/knee via k6 `ramping-arrival-rate` (modelo aberto). Saturação NUNCA se mede com VU fixo.
- `benchmark-resource-leak` — CPU/mem por instância + leak vs pooling (docker stats → InfluxDB).
- `benchmark-results-report` — escreve o relatório comparativo em `docs/BENCHMARK-*.md` (todo número precisa de causa-raiz).
- `benchmark-troubleshoot` — runbook sintoma→causa→fix (comece por `docker logs bench-app-1 | tail -30`).
- `benchmark-k6-scenario` — criar script k6 novo em `infra/k6/bench-*.js`.
- `benchmark-new-sample` — criar sample novo em `samples/delphi/` (mexe em 4 lugares).
- `benchmark-dashboard-export` — exportar dashboard Grafana em PNG.

## Objetivo → workflow

| Objetivo | Build (PowerShell, no dir Benchmark) | Run (WSL, em `infra/`) | Framework |
|---|---|---|---|
| Throughput HTTP puro | `build-community-bench.ps1 -Mode poseidon-v2` | `./run-ping.sh poseidon-v2 <nome> [vus=500] [dur=2m] [inst=1]` | `poseidon-v2` |
| Throughput sob **cap de CPU/RAM** (wrk) | `build-community-bench.ps1 -Mode poseidon-v2` | `./run-ping-limited.sh poseidon-v2` (LIMIT_CPUS/LIMIT_MEMORY) | `poseidon-v2` |
| Carga com DB (CRUD) | `build.ps1 -Sample compat-poseidon-v2 -Platform Linux64` | `./run-crud.sh poseidon-v2 <nome> [vus] [dur] [inst] [limites]` | `poseidon-v2` |
| Workload realista NFCe | `build_nfce_linux.ps1 -Mode poseidon` | `./run-nfce.sh poseidon <nome> [vus] [dur]` | `poseidon` |
| Saturação / knee | (build ping ou crud) | `benchmark-saturation-test` → `bench-crud-saturation.js` (arrival-rate) | — |
| Vazamento / soak | (build crud) | `benchmark-resource-leak` / `bench-crud-soak.js` | — |
| v1↔v2 ou Pool4D↔Triton | (builds correspondentes) | `./run-pool-comparison.sh [vus] [dur]` | vários |
| Horse↔Poseidon | build ambos | `./run-crud.sh horse-epoll ...` e `./run-crud.sh poseidon-v2 ...` | `horse-epoll`/`poseidon-v2` |

Regra: **containeriza o alvo, nunca o gerador de carga.** `run-ping-limited` usa
**wrk** (só terminal, sem Grafana); os demais usam **k6** (→ InfluxDB → Grafana).

## Caminho feliz canônico (medir o Poseidon atual)

1. **Sincronizar+purgar** (Regra de Ferro nº1 acima).
2. **Build**: escolher o `.ps1` da tabela conforme o objetivo → produz ELF sem
   extensão em `Benchmark\samples\delphi\bin\linux\` (delegar a `benchmark-linux-build`).
3. **Infra**: `cd Benchmark/infra && docker compose up -d`; confirmar
   postgres+influxdb+tempo+grafana healthy (delegar a `benchmark-infra-stack`).
4. **Seed** (só CRUD/NFCe): aplicar schema (`build.ps1` menu "Seed" ou `psql`).
5. **Run**: em WSL, `cd infra/` e chamar o `run-*.sh` da tabela com `poseidon-v2`
   (ou `poseidon` p/ NFCe) + VUs/duração/instâncias (delegar a `benchmark-run-scenario`).
6. **Ler**: Grafana `http://localhost:16300`, dashboard uid `bench-overview`
   (tiles 101-105, percentis 111-115, throughput 11, latência 12, status 14).
   Cada teste cria um DB InfluxDB `<nome>` = datasource novo.

## Fechar o loop — resultado → código do Poseidon

O valor da skill é traduzir o número/flamegraph num ponto do código:

- **p99 alto / knee cedo** → modelo de dispatch (async `Post` = +1 thread-hop;
  ver `Poseidon.Net.HttpServer._DispatchAccumBuf` / SyncDispatch) e backend
  (epoll vs io_uring). Comparar `SyncDispatch` on/off.
- **CPU alta / baixo req/s no ping** → alocações por request (hot path:
  `HTTP1.Parser`, `ResponseBuilder`, `Native.Router.MakeKey`) — casa com os
  itens de perf abertos (issue #197) e os levers de zero-alocação.
- **Escala ruim com concorrência (não com CPU)** → contenção de MM ou lock
  (Pool.Workers, buffer pool). Considerar arenas por-thread.
- **Memória não volta ao baseline** → leak vs pooling (`benchmark-resource-leak`).
- **Horse ganha no ping** → historicamente era single-listen+single-epoll+queue;
  o v2 canônico já tem shared-nothing per-core epoll — confirmar que está ativo
  (ver `docs/PROMPT-POSEIDON-V2-OPTIMIZATION.md`, histórico/aspiracional).

## Cenário mais realista — VPS externa (hardware real, opcionalmente rede real)

O harness WSL2 (acima) é o padrão para o dia a dia: rápido, local, sem custo.
Mas para **testes de benchmark mais elaborados** — validação final de um fix
sensível a timing/concorrência (ex.: #224), uma decisão benchmark-gated
importante antes de merge, ou qualquer suspeita de que o kernel customizado
da WSL2 esteja mascarando ou introduzindo alguma variável — rode também numa
VPS real: Hostinger KVM (4 vCPU / 15 GiB, Ubuntu 24.04), acesso documentado em
`D:\IA\Vault\Self-Hosted-IA.md`. Essa VPS já hospeda outros serviços em
produção (stack "MinhaSuite" + "Self-Hosted-IA") — **nunca são o alvo do
teste**, apenas vizinhos que não podem ser afetados.

### Regras de isolamento (sempre, sem exceção)

1. **Snapshot antes**: `docker ps` + `docker network ls` — guarde a lista.
2. **Nunca** `stop`/`rm`/`restart` um container existente, nunca
   `docker compose down`/`system prune`/`volume rm`.
3. Rede **dedicada e nova** para o teste (`docker network create <nome>`) —
   nunca `minhasuite-net` nem `selfhosted-ia_default`.
4. Nome de container único, `--cpus`/`--memory` sempre definidos (o alvo não
   pode faminar os outros ~19 containers da máquina).
5. **Limpeza total ao final**: parar/remover o(s) container(s) de teste,
   remover a rede dedicada, remover qualquer imagem que teve que ser
   `pull`ada especificamente para o teste (`docker images` antes/depois —
   se uma imagem não existia no snapshot, ela sai no final), apagar
   binário/scripts enviados via `scp`.
6. **Snapshot depois**: `docker ps` + `docker network ls` devem bater
   exatamente com o snapshot do passo 1. Se não bater, investigar antes de
   encerrar a sessão.
7. Na dúvida se um comando afeta algo existente — não rode, pergunte primeiro.

### Dois modos — escolha conforme o que você quer medir

- **Hardware real, sem rede real** (o que foi feito para validar o fix da
  #224): o gerador de carga (`wrk`/k6) roda em OUTRO container na MESMA rede
  Docker dedicada, batendo no alvo pelo nome do container
  (`http://<nome-do-alvo>:9000/...`). Isso tira a variável "kernel
  customizado da WSL2 e virtualização aninhada" da equação, mas o tráfego
  ainda é só loopback/bridge interno — **sem latência de rede real**. Bom
  para: confirmar que um fix de concorrência não era peculiaridade da WSL2.
- **Rede real** (para quando "delay de rede, jitter, etc." importa de
  verdade — ex.: medir p99 sob RTT real, testar timeouts/keep-alive fora de
  condições ideais): o gerador de carga roda **fora** da VPS — na própria
  máquina Windows local (`wrk`/k6 via WSL local, ou um container Docker
  Desktop local) — batendo no IP público da VPS. Isso exige expor a porta
  do container-alvo no IP público (não só `127.0.0.1`) **temporariamente,
  só durante o teste**, e fechar a exposição (remover o container ou
  recriar sem o `-p` público) assim que terminar — nunca deixar uma porta
  de teste aberta ao público depois.

### Exemplo de sequência (modo hardware real, sem rede real)

```bash
# 1. Baseline
ssh -i <chave> root@<ip-vps> "docker ps; docker network ls"

# 2. Enviar o binário já cross-compilado (ver Regra de Ferro nº1 — sincronizar antes)
scp -i <chave> <bin-linux-local> root@<ip-vps>:/root/<nome>_server

# 3. Rede dedicada + alvo isolado, só loopback
ssh -i <chave> root@<ip-vps> "
  docker network create <nome>-net
  chmod +x /root/<nome>_server
  docker run -d --name <nome> --network <nome>-net --cpus=2 --memory=512m \
    -p 127.0.0.1:<porta>:9000 -v /root/<nome>_server:/app/server:ro \
    ubuntu:24.04 /app/server
"

# 4. Carga — gerador em container na MESMA rede dedicada, batendo no nome do container
ssh -i <chave> root@<ip-vps> "
  docker run --rm --network <nome>-net williamyeh/wrk -t4 -c100 -d20s http://<nome>:9000/ping
"

# 5. Limpeza total + verificação
ssh -i <chave> root@<ip-vps> "
  docker stop <nome>; docker rm <nome>; docker network rm <nome>-net
  rm -f /root/<nome>_server
  docker ps; docker network ls   # deve bater com o baseline do passo 1
"
```

Para o modo "rede real", troque o passo 3 para publicar em `0.0.0.0:<porta>`
(não `127.0.0.1`) e rode o `wrk`/k6 do passo 4 na máquina Windows local
contra `http://<ip-publico-vps>:<porta>/...` — e garanta que o passo 5
(remover o container) rode **logo em seguida**, sem deixar a porta pública
exposta além da duração do teste.

## Profiling (flamegraph) — não é pré-fiado no harness

O Benchmark entrega req/s, latência e CPU/mem (docker stats), mas NÃO um
flamegraph. Para perfilar CPU do binário sob carga:
- Linux/container: `perf record -g -F 999 -p <pid do server no container> -- sleep 30`
  → `perf report`/FlameGraph; precisa `perf` no host + símbolos (compilar com
  debug info). `perf stat -p <pid>` p/ ciclos/IPC/cache-miss; `strace -f -c -p <pid>`
  p/ syscalls/resposta.
- É uma extensão razoável ao harness (poderia virar um `run-*-profile.sh`).

## Regra de ouro de perf (igual à das reviews)

Só afirme um ganho/gargalo com NÚMERO. Otimizar hot path sem medir é o risco que
mantém os itens M12/M14/M25/HPACK-O(n²) como **benchmark-gated** — rodar aqui é
o que destrava decidi-los.

## Gotchas (os que mais mordem)

- Binário stale → **sempre** purgar `vendor/` `.o`/`.dcu` antes de buildar.
- Poseidon morre logo após subir → a main thread termina após `Listen`; o DPR de
  bench já tem `while True do TThread.Sleep(60000)` — se criar sample novo, incluir.
- 99% de erro a 200+ VUs → Postgres `max_connections=100`; subir p/ 500 no compose.
- InfluxDB cai sob carga → `INFLUXDB_HTTP_MAX_BODY_SIZE=0`.
- Runtime error 217 no container → lib nativa faltando (libicu74 p/ Horse etc.);
  `strace -e trace=file ./server 2>&1 | grep ENOENT`.
- Datasource novo por teste → adicionar em `grafana/provisioning/datasources/` +
  `docker restart bench-grafana`.

## Não faça
- Não medir sem sincronizar `vendor/poseidon-v2` (Regra de Ferro nº1).
- Não medir saturação com VU fixo (use arrival-rate).
- Não reimplementar as 11 skills do Benchmark aqui — delegue.
- Não containerizar o gerador de carga (harness WSL2 local).
- Não afirmar regressão/ganho de perf sem o número do Grafana/wrk.
- Na VPS: não tocar em container/rede/volume que já existia — sempre rede
  dedicada nova, sempre limpeza total, sempre snapshot antes/depois.
- Na VPS: não chamar de "teste com rede real" um teste cujo gerador de
  carga roda em outro container na mesma máquina — isso é só hardware
  real, ainda sem latência de rede.
- Na VPS: não deixar uma porta pública exposta além da duração do teste de
  "rede real" — remover o container (ou recriar sem `-p 0.0.0.0:...`) assim
  que a rodada termina.
