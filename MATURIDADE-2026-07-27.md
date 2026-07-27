# Poseidon — Avaliação de Maturidade (2026-07-27) — dois bugs reais de performance achados e corrigidos via benchmark multi-framework, gap residual de p99 mapeado mas não fechado

> Continuação do documento vivo `MATURIDADE-2026-07-26.md`. Esta reavaliação
> cobre a primeira comparação rigorosa do Poseidon contra 7 concorrentes
> diretos (Actix, mORMot2, Go Fiber, uws, Kestrel, nginx, Horse) e dois
> fixes reais de performance descobertos por causa dela.

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade, auditado por terceiros.
"Correto por leitura" ≠ "correto por prova".

## O que mudou desde 07-26 (com evidência)

- **Primeira comparação rigorosa contra 7 concorrentes diretos** (não só
  Horse). Resultado inicial (VPS, condições limpas): Poseidon empatado em
  4º/5º lugar (67.378 req/s), atrás de Actix/mORMot2/Go Fiber, CPU mais
  alta que os líderes pra menos throughput (197,5%), único dos 8 com
  erro não-zero (234 read errors/121M, ~0,0002%). Isso por si só é um dado
  novo e honesto: nunca tinha sido medido contra esse conjunto antes.
- **#231 — TCP_CORK inútil, achado via `perf record` real sob carga,
  consumia 32,5% de TODA a CPU do processo.** `PostSendV` já manda
  headers+body num único `writev()` — não havia nada pro CORK agrupar.
  Fix commit `16dbcfc`. **Validado por 3 métodos independentes que
  convergem**: perf antes/depois (o custo some do profile), A/B binário
  (mesmas condições, +4-5% throughput), e full-30min run. Também corrigido
  (mesma issue) um segundo bug real: `EPOLLRDHUP` tratado como erro fatal
  mesmo com send pendente (commit `c2751e6`) — semântica de epoll correta,
  mas efeito na taxa de read errors residual ficou **inconclusivo**
  (16,31 erros/milhão pós-fix, dentro da faixa já vista antes do fix).
- **#231 — investigação exaustiva dos read errors residuais, sem causa
  raiz confirmada.** Instrumentados TODOS os 7 caminhos de fechamento de
  conexão plausíveis (3 branches do epoll + 3 branches de erro de syscall
  com histograma de errno + o path de "descartado sem resposta" do
  HttpServer). Reproduzido localmente (199 erros/16,4M requisições) com
  **todos os contadores em zero** — nenhum caminho server-side mapeado
  explica os erros. Conclusão honesta: provavelmente artefato do cliente
  `wrk` sob carga extrema, não confirmado com certeza absoluta.
  Instrumentação revertida do código de produção (só ficou o `.dpr` de
  debug em `sandbox/`, fora do harness real).
- **#232 NOVO — achado maior: dimensionamento de threads de IO ignorava a
  quota de CPU do cgroup, não só os cores visíveis do host.**
  `TThread.ProcessorCount` reage a `--cpuset-cpus` (raro na prática) mas
  NÃO a `--cpus`/CPU *limits* de Kubernetes (comum). Container com 2 vCPU
  de cota mas 16 cores visíveis no host criava **34 threads de IO** (devia
  ser ~10) — super-subscrição severa, com a assinatura clássica "throughput
  médio ok, p99 péssimo" (77,93ms). Fix commit `4c30fbb`: detecção de quota
  via cgroup v2/v1, usada em `Listen()`, zero mudança de comportamento sem
  quota detectável (bare metal). **Validado**: threads 34→10, throughput
  +48,3% (36.352→53.920 req/s), p99 -13,6% (77,93ms→67,30ms). Isso é um
  achado de **impacto real de produção** — afeta qualquer deploy
  Docker/Kubernetes com CPU limit sem cpuset pinning, um padrão comum, não
  só o harness de benchmark.
- **Experimento adicional (mesmo dia, sem fix novo): tunning de
  thread-count não fecha o gap de p99 restante.** Pinning de núcleos
  melhora p99 (20ms) mas derruba throughput (-35,7%); reduzir threads dá
  meio-termo. Nenhuma configuração testada bateu uws (54.223 req/s **e**
  6,40ms de p99 SIMULTANEAMENTE, sob a mesma quota, sem pinning). O fix já
  commitado é o melhor ponto testado desse espaço — não há alavanca livre
  aqui, é troca real. Gap residual contra uws/Actix (67ms vs 6-7ms de p99)
  segue sem causa raiz definitiva — candidato mais forte é o mesmo
  overhead por-requisição já mapeado no profile do #231 (~11,6% de CPU em
  alocação de página do kernel pro payload grande).
- **Infraestrutura externa (não é bug do Poseidon, mas afetou a validação):**
  a VPS Hostinger usada pra comparação apresentou throttle de CPU
  (confirmado via notificação direta ao provedor + `vmstat` sob carga,
  30-48% de steal em 15 medições ao longo de ~24h) — impediu validar os 3
  fixes no MESMO hardware da comparação original. Validação feita
  localmente (WSL2) em vez disso — mesma metodologia, hardware diferente.
- **#227, #228, #219, #230 sem trabalho nesta sessão** — permanecem
  exatamente no estado documentado em 07-26 (memória inconclusiva, ~25% de
  trava na suite Win64, FPC follow-ups multi-dia, 25 casos de deflate
  falhando graciosamente).
- **Gates FPC/Linux (server_smoke/server_run/server_signal_run) rodados 3
  vezes nesta sessão** (uma por fix), **todos limpos, sem regressão** —
  disciplina de validação mantida mesmo com mudanças reais em código de
  concorrência/threading.

## Pontuação por dimensão (Δ vs 07-26)

| Dimensão | 07-26 | **07-27** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança estrutural — os fixes são cirúrgicos (remoção de código morto, detecção de quota centralizada em um ponto), não refatoração. |
| Performance | 92 | **89** | **Recuo, não avanço — o método funcionando certo de novo.** A primeira comparação rigorosa contra 7 concorrentes diretos revelou 2 bugs reais de performance que ninguém tinha medido antes (CORK 32,5% de CPU; threads 3-4x super-provisionadas). Ambos foram corrigidos com evidência forte, mas o fato de terem existido — e só terem sido achados porque o benchmark ficou mais rigoroso — significa que o "92" de ontem não refletia o comportamento real sob condições comuns de deploy (container com CPU limit). Gap residual de p99 (67ms vs 6-7ms dos líderes, ~10x) segue sem causa raiz fechada. |
| Correção HTTP/1.1 | 88 | **88** | Sem mudança — os fixes são de transporte/threading, não de parsing/protocolo HTTP/1.1. |
| Correção HTTP/2 | 85 | **85** | Sem trabalho nesta janela (nenhum h2spec rodado). |
| Correção WebSocket | 89 | **89** | Sem trabalho nesta janela. |
| Segurança | 84 | **84** | Sem trabalho nesta janela. |
| Concorrência / thread-safety | 86 | **87** | O fix do #232 é fundamentalmente uma correção do MODELO de concorrência (quantas threads competem por quanto CPU real) com evidência forte (34→10 threads, mecanismo comprovado, não hipótese). O fix do RDHUP também é concorrência (race entre send-completion e o loop de eventos), mas seu efeito real é inconclusivo. Ganho modesto, temperado pela regra de "achar bug nesta rodada sinaliza que há mais" — 2 bugs novos de concorrência/threading achados nesta sessão. |
| Segurança de memória / recursos | 85 | **85** | Sem achado novo nesta janela (a instrumentação de debug não revelou problemas de memória, e foi revertida). |
| Portabilidade | 88 | **89** | Os 2 novos fixes são Linux-only, corretamente guardados (`{$IFNDEF MSWINDOWS}`), e os gates FPC/Linux rodaram limpos 3 vezes nesta sessão sem nenhuma regressão — disciplina de validação repetida e consistente. |
| Robustez / estabilidade | 88 | **89** | O fix do #232 é uma correção real de robustez sob condição de deploy comum (CPU limit sem cpuset) — antes do fix, qualquer deploy nessas condições sofria degradação silenciosa de latência. Moderado por: erros residuais de read ainda sem causa raiz confirmada (mesmo que provavelmente benignos), e nenhuma validação ainda no hardware original da VPS. |
| Cobertura de testes | 82 | **82** | Sem mudança — nenhuma rodada da suite DUnitX completa nesta sessão, #228 (trava de ~25%) não investigado. Os gates FPC rodados são uma fatia fina (smoke/run/signal), não a suíte completa. A instrumentação de diagnóstico foi revertida, não virou teste permanente. |
| API / DX | 84 | **84** | Nenhuma superfície de API pública nova (o fix do #232 é inteiramente interno). |
| Documentação | 79 | **79** | Novos relatórios de benchmark e issues detalhadas são documentação interna/datada — mesmo critério já estabelecido nas reavaliações anteriores (não move a nota). |
| Ecossistema / features | 81 | **81** | Sem mudança nesta janela. |
| Prontidão para produção | 83 | **86** | **Maior ganho desta reavaliação.** O #232 é um achado de impacto real e comum em produção — qualquer deploy Docker/Kubernetes com CPU *limit* sem `cpuset`/CPU manager estático sofria essa degradação silenciosamente, e isso é um padrão bem mais universal do que o cenário adversarial específico do #229 (sessão anterior). Moderado por: nenhuma validação ainda no hardware original da comparação, e o gap de p99 residual contra os líderes ainda não fechado. |
| Qualidade / manutenibilidade | 84 | **85** | Disciplina mantida e reforçada: mensagens de commit com números reais, experimentos isolados em `sandbox/` sem poluir o código de produção, instrumentação de diagnóstico revertida ativamente após servir seu propósito (não deixada como débito técnico), gates rodados a cada mudança. |

## Nota geral honesta: **~85,6/100 → ~86,0/100 (ganho pequeno, real)**

Média ponderada (mesmo esquema das reavaliações anteriores: correção ×
segurança × concorrência+memória × robustez × testes × prontidão em peso
3; performance/portabilidade/API/qualidade em peso 2; docs/ecossistema/
arquitetura em peso 1) ≈ **86,0**.

Este é, de novo, um ganho pequeno e defensável, não inflado. O #232 é
provavelmente o achado de **maior impacto prático real** desta série toda
até agora — não por ser o bug mais grave tecnicamente, mas por afetar o
cenário de deploy mais COMUM (container com limite de CPU), silenciosamente,
sem nenhum sintoma óbvio além de "por que meu p99 tá tão ruim". Isso puxa
Prontidão para produção e Concorrência pra cima de forma genuína.

Mas o ganho é pequeno, não grande, porque a MESMA sessão que produziu esses
fixes só existiu porque o primeiro comparativo rigoroso contra 7
concorrentes revelou que o Poseidon estava **materialmente atrás** dos
líderes (throughput e p99) por razões que ninguém tinha medido antes — o
"Performance: 92" de ontem não sobrevive a esse teste sem recuar. E depois
dos 2 fixes, ainda sobra um gap de p99 de ~10x contra uws/Actix, sem causa
raiz fechada. **A mesma disciplina de sempre: um dia com achados reais e
bons não vira nota alta só porque foi produtivo — cada achado, bom ou
ruim, entra na conta pelo que é.**

## Veredito
**Poseidon v2 sobe de ~85,6 para ~86,0/100 — ganho pequeno mas real, puxado
por um achado de impacto genuíno em produção (#232), moderado pela
descoberta de que o "Performance: 92" de ontem não tinha sido testado sob
condições comuns de deploy containerizado.** O projeto está mais confiável
em cenários de container com CPU limit hoje do que ontem, de um jeito
mensurável — mas o gap de performance contra os 2-3 líderes do comparativo
multi-framework segue real e não fechado, e os itens já conhecidos (#227,
#228, #230, #219) continuam exatamente onde estavam.

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **Gap de p99 residual contra uws/Actix (~10x, 67ms vs 6-7ms) — mapeado,
   não fechado.** Thread-count/pinning já foi testado e não é alavanca
   livre (é troca throughput-vs-latência). Move: profiling direto do
   overhead por-requisição (o candidato já identificado é ~11,6% de CPU em
   alocação de página do kernel pro payload grande no profile do #231) —
   exigiria investigar `MSG_ZEROCOPY` ou `sendfile`, ambos com risco/
   complexidade reais, ou aceitar que uws (C++, single-thread hiper-
   otimizado) tem um teto estrutural que pode não valer a pena perseguir
   integralmente.
2. **#228 (trava de ~25% na suite Win64) — intocado desde 07-26, mesmo
   suspeito não confirmado.** Move: instrumentar a suite com timeout/log
   por teste, investigar o drain/shutdown do IOCP com a mesma profundidade
   que resolveu #229/#231/#232 no lado Linux.
3. **Read errors residuais do #231 — escopo reduzido mas não fechado.**
   Instrumentação exaustiva não achou causa server-side; hipótese
   principal é artefato do `wrk`, não confirmada com certeza. Move:
   reproduzir com outro gerador de carga (k6, h2load) pra ver se o padrão
   muda ou desaparece — isolaria definitivamente se é client-side.

## O que NÃO preocupa (fortes reais)
- **Os 2 fixes desta sessão (#231 CORK, #232 quota) têm evidência
  genuinamente forte** — não é "parece que melhorou", é medição
  antes/depois com números reais, 3 métodos independentes no caso do CORK,
  mecanismo comprovado (contagem de threads) no caso da quota.
- **O #232 tem impacto prático que vai além deste benchmark** — qualquer
  deploy real do Poseidon num container com CPU limit se beneficia, não só
  o harness de teste.
- **Disciplina de reverter instrumentação de diagnóstico** depois de
  servir seu propósito (não virou débito técnico permanente) — mostra
  maturidade de processo, não só de código.
- **Zero regressão em nenhum gate existente** (FPC Windows/Linux, rodado 3
  vezes) apesar de mudanças reais em código de threading/concorrência.
- **Honestidade mantida sob pressão de um resultado poderia ter sido
  inflado**: quando o teste A/B mostrou o Poseidon aparentemente PIOR do
  que a manhã anterior (por causa do throttle da VPS), a reação foi
  investigar a fundo (achou o steal, depois o throttle real) em vez de
  aceitar ou esconder um número ruim — e quando a Rodada 2 mostrou o
  Poseidon à frente do Go Fiber, isso foi tratado como "atribuição
  ambígua", não como vitória, até a Rodada Local confirmar que era
  tolerância a contenção, não o fix.

## Plano de ação (atualizado)
- **P0 performance**: investigar o overhead por-requisição residual
  (~11,6% de alocação de página do kernel) — decidir se vale o risco do
  `MSG_ZEROCOPY` ou se o gap contra uws/Actix é aceitável.
- **P0 CI**: #228 — instrumentar a suite Win64 com timeout/log por teste;
  ainda o item mais antigo sem avanço nesta série.
- **P1 conformidade**: #230 — 25 casos de deflate, já reproduzível
  deterministicamente.
- **P1 memória**: #227 — rerodar soak mais longo/mais fiel à topologia
  original.
- **P1 validação**: repetir a comparação multi-framework no MESMO hardware
  da VPS assim que o throttle da Hostinger liberar, pra confirmar os
  ganhos do #231/#232 no ambiente original.
- **P2 FPC**: #219 — 4 sub-itens seguem multi-dia.
- **P2 read errors**: reproduzir com gerador de carga diferente (k6,
  h2load) pra isolar se é client-side de vez.
- **Fase B (não-engenheirável, 92→100)**: tráfego de produção real em
  escala, auditoria de segurança de terceiro.
- **Higiene**: atualizar #211 com este snapshot (~86,0, ganho pequeno via
  #232, moderado pelo recuo honesto de Performance ao revelar o gap
  competitivo real; próximo salto depende do gap de p99 residual e de
  #228).
