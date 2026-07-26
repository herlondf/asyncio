# Poseidon — Avaliação de Maturidade (2026-07-25) — pós #225/#226 fechados, #229 novo, benchmark comparativo real

> Continuação do documento vivo `MATURIDADE-2026-07-24.md`. Esta reavaliação
> cobre: o fechamento de #225 (TSocketPool per-instância) e #226 (crash do
> RecvPool), a descoberta de #229 (hang HIGH não resolvido, achado durante a
> validação do fix do #226), o estreitamento de #228 (de 3 falhas misteriosas
> para 1), e três rodadas de benchmark comparativo Poseidon vs Horse numa VPS
> real (Hostinger), fora do WSL2 local pela primeira vez.

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade, auditado por terceiros.
"Correto por leitura" ≠ "correto por prova".

## O que mudou desde 07-24 (com evidência)

- **#226 FECHADO — crash real confirmado e corrigido.** `_RecvPoolAcquire`
  (`Poseidon.Net.IO.IOUring.pas`) alocava via `New(Result)` num `Pointer`
  genérico (não tipado) no caminho de exaustão do pool — em vez de um bloco de
  `SizeOf(TRecvCtx)`, retornava NULL, causando `EAccessViolation` silenciosa
  (capturada, não derrubava o processo, mas descartava o recv). Reproduzido
  746 vezes em UM run do Autobahn 12.2.17 antes do fix; **0 depois** (commit
  `661e7c7`).
- **#225 FECHADO — `TSocketPool` agora é por-instância, não global-por-classe**
  (`3929c7c`), validado 25/25 execuções limpas na fixture que exibia a
  flakiness (`Poseidon.Tests.DeferredResponse`).
- **#229 NOVO, ABERTO, HIGH — achado ao validar o fix do #226.** Rodando a
  suite Autobahn completa (228 casos, backend io_uring) depois do fix do
  crash, o servidor **travou completamente 2 vezes** (uma no primeiro caso,
  outra no caso ~65). Evidência real coletada (não hipótese solta): Send-Q
  não drena (`ss -tnp`, dezenas de KB presos), CPU do processo em 200-276%
  concentrada nas 16 threads do worker pool (não nas threads de completion do
  io_uring), 2 snapshots de `gdb thread apply all bt` mostrando os workers
  ociosos em `TSemaphore.WaitFor` no instante capturado, e ~40 threads extras
  `iou-wrk-<N>` (io-wq do KERNEL, não código Poseidon). Hipóteses levantadas
  (SEND_ZC sobre loopback; efeito colateral do sweep periódico do #224) —
  **nenhuma confirmada com a profundidade que resolveu #223/#224**.
- **#228 parcialmente explicado — de 3 falhas misteriosas para 1.** A falha
  `Sync_PlainRoute_Works` (commit `18c108a`) tinha a MESMA causa raiz do
  #225 — já corrigida e validada. Sobra genuinamente inexplicada só
  `Post_BurstAboveMin_SpawnsAdditional` (hipótese de contenção de CPU do
  runner compartilhado, não confirmada). Nenhuma repetição de falha nos runs
  de CI desde então (`gh run list`: todos os runs de `661e7c7` e `e2af3a9`
  em diante = success).
- **#227 segue aberto** — hipótese principal (race no heurístico de spawn do
  `TElasticWorkerPool`) testada diretamente com um probe isolado e
  **descartada** (`ActiveWorkers` ficou travado em `Min=8` por 175s sob 150
  posts/s de work-items instantâneos, zero crescimento). Causa raiz real
  ainda não identificada; próximo passo (logar `ActiveWorkers` durante um
  soak real e correlacionar com o degrau de RSS) não executado.
- **Novo: três rodadas de benchmark comparativo Poseidon vs Horse (Epoll) numa
  VPS real** (Hostinger KVM, 4 vCPU/15GiB — não mais só WSL2 local):
  1. **CRUD com Postgres** (500 VUs, pool `Pool4D` idêntico nos dois lados):
     Poseidon ~2,27× mais requisições bem-sucedidas (96,5% vs 28,9% de
     sucesso) — causa raiz do erro do Horse provada no código-fonte dele
     (ordem de middleware sem try/except escondendo esgotamento de pool).
  2. **JSON sem DB via k6**: resultado inconclusivo pro throughput (client-bound
     pelo próprio k6), mas CPU/memória por requisição já favoreciam Poseidon.
  3. **JSON sem DB via wrk** (gerador muito mais leve, achou o teto real):
     Poseidon **~6,13× mais throughput real** sob o mesmo cap de CPU por
     instância (7.362 vs 1.200 req/s), p95 ~9,4× menor, zero erros vs 20 do
     Horse. Processo também achou e corrigiu um bug de metodologia próprio
     (nginx sem `worker_processes` explícito = 1 worker só, tirado da
     equação) — rigor demonstrado, não só o número reportado.

## Pontuação por dimensão (Δ vs 07-24)

| Dimensão | 07-24 | **07-25** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança estrutural nesta janela. |
| Performance | 90 | **91** | Três rodadas de benchmark comparativo real numa VPS (não WSL2), contra um framework de verdade (Horse) sob o mesmo cap de recurso, com causa-raiz provada em pelo menos 2 achados e rigor demonstrado (o processo achou e corrigiu os próprios bugs de metodologia — client-bound do k6, nginx de 1 worker — em vez de reportar número errado). Segura: ainda é medição própria, não third-party; e nenhum desses testes mediu o caminho HTTP/2 ou WebSocket sob carga. |
| Correção HTTP/1.1 | 88 | **88** | Sem mudança nesta janela. |
| Correção HTTP/2 | 85 | **85** | Sem mudança nesta janela. |
| Correção WebSocket | 88 | **88** | #226 fechado é um ganho real (746→0 crashes reproduzidos) — mas a MESMA validação não conseguiu completar a suite Autobahn de 228 casos por causa do #229 (trava antes do fim). Não dá pra reivindicar "228/228 confirmado" agora — a validação ficou mais incompleta, não menos. Fica flat: um ganho real compensado por uma lacuna de validação nova. |
| Segurança | 84 | **84** | Sem mudança nesta janela. |
| Concorrência / thread-safety | 85 | **84** | #225 fechado com prova forte (25/25) — real. Mas #229 é um achado NOVO, HIGH, especificamente nas threads do worker pool, sem fix e sem a mesma profundidade de causa-raiz que #223/#224 tiveram. Regra do próprio método: achar bug novo nesta dimensão pesa contra, mesmo tendo fechado outro. Líquido: leve recuo. |
| Segurança de memória / recursos | 85 | **84** | #227 segue sem causa raiz (hipótese principal descartada honestamente, não substituída por uma nova confirmada). O padrão de sintomas do #229 (Send-Q acumulando, não liberado) também é memória/recurso-adjacente e não resolvido. Sem mudança positiva concreta nesta janela. |
| Portabilidade | 88 | **88** | Sem mudança nesta janela (#219 seguem os mesmos 4/5 sub-itens abertos). |
| Robustez / estabilidade | 87 | **84** | **Maior recuo desta reavaliação.** #229 é um hang completo (não um crash com recuperação) no MESMO subsistema (io_uring N-rings) que já tinha gerado o hang do #224 dias antes — é o segundo hang HIGH nesse caminho de código em menos de uma semana. Não é ruído: é sinal de que o backend io_uring N-rings, mesmo depois de dois rounds de fix, ainda não amadureceu sob carga sustentada com mensagens grandes. #226 fechado é positivo mas não compensa achar um segundo hang no mesmo subsistema logo depois de fechar o primeiro. |
| Cobertura de testes | 83 | **85** | Progresso real e concreto: de 3 falhas de CI inexplicadas em 07-24 para 1 (2 delas tinham a mesma causa raiz do #225, já corrigida e validada). Nenhuma repetição de falha nos runs desde então. Segura: a ação combinada em 07-24 ("rodar a suite 5-10x numa janela ociosa") ainda não foi executada — a taxa-base real de flakiness continua desconhecida. |
| API / DX | 83 | **83** | Sem mudança nesta janela. |
| Documentação | 79 | **79** | Os novos relatórios de benchmark são documentação interna/datada, mesmo critério de 07-24 (não contam como docs públicas). |
| Ecossistema / features | 81 | **81** | Sem mudança nesta janela. |
| Prontidão para produção | 82 | **81** | CI mais estável (2/3 flakes explicados+corrigidos, zero repetição desde então) puxa pra cima; mas #229 é um achado de produção-relevante genuíno — um servidor que trava sob carga sustentada de mensagens grandes comprimidas é exatamente o tipo de risco que "prontidão para produção" precisa capturar. Líquido: leve recuo. Sem mudança na lacuna estrutural (zero quilometragem de produção real). |
| Qualidade / manutenibilidade | 84 | **84** | Disciplina de gate 2-faces mantida (`661e7c7` e `e2af3a9` ambos passaram limpo). Sem mudança material. |

## Nota geral honesta: **~85/100 → ~85/100 (84,9, tecnicamente flat)**

Média ponderada (mesmo esquema de 07-24: reliability-critical ×3 — correção
HTTP/1-2-WS, segurança, concorrência, memória, robustez, testes, prontidão;
importantes ×2 — performance, portabilidade, API, qualidade; contexto ×1 —
arquitetura, docs, ecossistema) ≈ **84,9**.

**Esta é a parte que mais importa desta reavaliação: o trabalho de hoje NÃO
subiu a nota, apesar de ter produzido evidência real e valiosa (o benchmark
comparativo com causa-raiz provada).** O ganho de Performance (+1) e de
Cobertura de testes (+2) foi cancelado quase exatamente pelo recuo em
Robustez (-3), Concorrência (-1) e Prontidão (-1) — todos por causa do MESMO
evento: a descoberta do #229 durante a própria sessão de validação do #226.
Isso é o método funcionando como deveria: achar um bug HIGH novo pesa contra
a nota, mesmo quando aparece como efeito colateral de estar corrigindo outro
bug. Uma reavaliação otimista teria contado só os dois issues fechados
(#225, #226) e ignorado o novo — isso seria desonesto.

## Veredito
**Poseidon v2 continua no patamar de 85/100 — production-grade sólido para
cargas não-críticas — mas o teto de curto prazo (~90-92) ficou mais distante
hoje, não mais perto, porque o subsistema de maior risco do projeto (io_uring
N-rings) acabou de produzir seu segundo hang HIGH em menos de uma semana.**
O benchmark comparativo de hoje é uma evidência genuinamente boa e reforça a
tese de que a arquitetura do Poseidon é eficiente — mas maturidade de
servidor não se resume a throughput: um servidor rápido que trava sob um
padrão de carga específico ainda não é production-grade para esse padrão de
carga. #229 precisa ser resolvido com a MESMA profundidade que resolveu
#223/#224 antes que o próximo salto de nota faça sentido.

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **#229 (HIGH, não resolvido) — hang do io_uring N-rings sob mensagens
   grandes comprimidas sustentadas.** É o único item que, sozinho, está
   impedindo Robustez/Concorrência/Prontidão de subir. Move: sessão dedicada
   de live-debugging na mesma profundidade de #223/#224 — testar a hipótese
   SEND_ZC diretamente (`FSendZC := False` e comparar), instrumentar o
   sweep-loop do #224 pra descartar/confirmar a hipótese de amplificação de
   CPU, rodar sob carga menor pra achar o limiar exato onde a trava começa.
2. **CI ainda não validado como estável de verdade.** A ação mais barata e
   mais adiada do plano de 07-24 continua sem ser feita: rodar a suite
   completa 5-10× numa janela sem carga concorrente na máquina, pra
   estabelecer a taxa-base real de flakiness (só assim dá pra fechar #228
   com confiança, não só "não repetiu ainda").
3. **#227 (memória) segue sem causa raiz** depois de uma hipótese honesta
   mente descartada — falta o passo concreto já identificado (logar
   `ActiveWorkers`/`IdleWorkers` durante um soak real e correlacionar com o
   degrau de RSS), que não é caro, só não foi feito ainda.

## O que NÃO preocupa (fortes reais)
- **O método de reavaliação segurou a linha**: um dia com 2 issues fechados
  (#225, #226) e evidência nova de performance forte NÃO virou nota mais
  alta, porque um achado HIGH novo (#229) foi contabilizado contra, não
  varrido pra debaixo do tapete. Isso é exatamente a disciplina que separa
  esta série de avaliações de uma autoavaliação otimista.
- **#225 fechado com validação forte (25/25) E convergência de evidência**
  (explica também 1 dos 3 mistérios do #228) — sinal de investigação real,
  não coincidência.
- **#226 é uma correção de crash real e mensurável** (746→0 reproduções) —
  não é uma correção especulativa.
- **O benchmark comparativo de hoje tem rigor genuíno**: 3 metodologias
  independentes convergindo na mesma direção, causa-raiz provada no código
  do concorrente (não só inferida), e o processo corrigindo os próprios
  bugs de instrumentação (client-bound do k6, nginx de 1 worker) em vez de
  reportar um número enganoso.
- **Disciplina de não esconder achados desconfortáveis continua**: #229 foi
  filed com evidência extensa (gdb, ss, breakdown de CPU por thread) no
  MESMO dia em que se fechava #226, não abafado para "fechar bonito" o dia.

## Plano de ação (atualizado)
- **P0 concorrência/robustez — #229**: live-debugging dedicado (mesma
  profundidade de #223/#224). Testar hipótese SEND_ZC isoladamente; revisar
  se o sweep periódico do #224 amplifica contenção sob a condição do #229;
  achar o limiar de carga onde a trava começa a ocorrer de forma
  reproduzível (hoje é intermitente: 1º caso numa run, ~65º caso noutra).
- **P1 processo**: rodar a suite Win64 completa 5-10× numa janela ociosa da
  máquina de dev, pra estabelecer taxa-base real de flakiness e fechar #228
  com confiança (não só "não repetiu ainda").
- **P2 memória**: #227 — logar `ActiveWorkers`/`IdleWorkers` durante um soak
  real e correlacionar com o timestamp exato do degrau de RSS.
- **P2 FPC**: #219 — os 4 sub-itens restantes (worker-pool async sob FPC,
  porte da suíte DUnitX, Lazarus/LCL, soak em binário FPC) seguem
  honestamente como trabalho de dias, não de uma sessão.
- **P3 benchmark**: repetir a comparação Poseidon vs Horse cobrindo HTTP/2 e
  WebSocket sob carga (hoje só cobriu HTTP/1.1 CRUD e JSON) — a Performance
  em 91 ainda não tem evidência comparativa nesses dois caminhos.
- **Fase B (não-engenheirável, 92→100)**: tráfego de produção real em
  escala, auditoria de segurança de terceiro — sem atalho.
- **Higiene**: atualizar #211 com este snapshot (~85, flat — nota não subiu
  apesar de progresso real, por causa do #229; próximo salto depende de
  resolver #229 com profundidade, não de mais benchmark).
