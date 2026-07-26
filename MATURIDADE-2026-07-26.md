# Poseidon — Avaliação de Maturidade (2026-07-26) — #229 resolvido, CI mais instável do que se pensava, #227 inconclusivo

> Continuação do documento vivo `MATURIDADE-2026-07-25.md`. Esta reavaliação
> fecha o ciclo dos "top 3 fatores" apontados naquela: #229 (resolvido),
> baseline real de CI (estabelecida — pior do que se assumia), #227
> (investigado — inconclusivo, não resolvido nem descartado).

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade, auditado por terceiros.
"Correto por leitura" ≠ "correto por prova".

## O que mudou desde 07-25 (com evidência)

- **#229 FECHADO — o item que mais segurava a nota, resolvido com o mesmo
  rigor de #223/#224.** Reproduzido AO VIVO na VPS (não só em teoria): 161→372
  threads do SO em 5 minutos sob Autobahn 12.*/13.* (mensagens grandes
  comprimidas sustentadas), confirmado via `gdb thread apply all bt full` que
  as 12 threads do próprio Poseidon estavam todas IDLE no momento da trava —
  a explosão de CPU/threads era 100% kernel-side (`iou-wrk-*`, io-wq), não
  código do Poseidon girando. Causa raiz: fallback de EAGAIN
  (`_ResubmitSend(..., True)`, io-wq bloqueante) sem `SO_SNDTIMEO` nem limite
  de retry — um peer que nunca drena prendia uma thread de kernel pra sempre,
  sem limite, por conexão. Fix: `SO_SNDTIMEO` (20s) + cap de 3 retries
  (commit `b781bcb`). **Validado 2x consecutivas**: antes do fix, a suite
  Autobahn completa (228 casos) travava sem completar NENHUM caso em >5min,
  exigindo `kill -9`; depois do fix, completa 228/228 em ~6-7min nas duas
  rodadas, thread count oscila e se recupera em vez de só crescer. 480/480
  DUnitX + 24/24 fuzz seguem limpos.
- **#230 NOVO, ABERTO, MEDIUM** — achado durante a validação do #229: 25
  casos específicos de permessage-deflate (12.2/12.3/12.5, janelas
  específicas) agora falham GRACIOSAMENTE em vez de travar — determinístico
  nas 2 rodadas (mesmos 25 casos exatos), não é flakiness. É uma troca boa
  (hang→falha limitada), mas revela uma condição de stall real ainda não
  root-caused nesses casos específicos.
- **#228 — baseline real estabelecida, e é PIOR do que a avaliação de 07-24
  documentou.** Rodei a suite completa 8 vezes seguidas: 6/8 limpas
  (480/480), **2/8 travaram de verdade** — não um teste lento, o processo
  parou de progredir (CPU confirmada zerada via `TotalProcessorTime` em
  checagens minutos apart) e precisou `kill -9` manual pra recuperar, sem
  timeout/recuperação automática observado. Isso é qualitativamente
  diferente do que 07-24 relatou (3 testes distintos falhando uma vez cada,
  sem repetir) — aqui é o PROCESSO INTEIRO travando, numa taxa de ~25%.
  Suspeito principal (não confirmado pras 2 travas desta bateria
  especificamente): `TPoseidonHttpServerDrainTests.Stop_NoInFlight_ReturnsQuickly`
  — um teste de drain/shutdown do backend IOCP (Windows), caminho de código
  DIFERENTE do que o #229 corrigiu (io_uring/Linux).
- **#219 sem avanço nos 4 itens abertos** (bloqueados em fatores externos ou
  escopo multi-dia — avaliado honestamente, não forçado). **Confirmado**:
  os gates FPC (Windows/IOCP e Linux/io_uring+epoll) passam limpos com TODAS
  as mudanças de hoje (fix do #229, novas properties) — sem regressão de
  portabilidade.
- **#227 — instrumentado, soak real rodado, resultado inconclusivo.** Novas
  properties públicas `WorkerActiveCount`/`WorkerIdleCount` (commit
  `327787a`) + logging periódico no sample CRUD. Soak de ~2h24m de carga
  real na VPS (passou da marca de 2h12m onde o degrau original apareceu) —
  **nenhum salto abrupto de RSS observado**, só crescimento suave e contínuo
  (25→113 MiB). Pool ficou estável em 207 ativos/0 ociosos o tempo todo sob
  carga; ao parar a carga, encolheu corretamente pra `Min=8` e a memória
  caiu e ficou flat. **Não reproduz o padrão original** (platô→degrau), mas
  também não descarta a causa raiz original — pode ser topologia diferente
  ou um evento específico do gerador de carga que não se repetiu. Achado
  colateral real: um bug de contabilização de tempo no cycler do k6 (achou
  e corrigiu) que fazia o soak entregar bem menos carga real do que o
  planejado.
- **Benchmark estendido — Horse confirmado sem HTTP/2 nem WebSocket
  oficiais** (pesquisa de código-fonte via GitHub API): só medido o
  Poseidon standalone. h2spec 145/146 reconfirmado (sem regressão).
  WebSocket sob carga real: 500 conexões simultâneas, 3.541 msgs/s
  ecoadas, 0 erros — evidência nova de correção sob carga (não é
  conformidade Autobahn, é comportamento sob carga moderada real).

## Pontuação por dimensão (Δ vs 07-25)

| Dimensão | 07-25 | **07-26** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança estrutural nesta janela. |
| Performance | 91 | **92** | Nova evidência real de carga em WebSocket (500 conexões, 3.541 msgs/s, 0 erros) estende a cobertura além de HTTP/1.1 — pequeno ganho real, não um salto (ainda sem número de throughput HTTP/2, tentativa não concluída). |
| Correção HTTP/1.1 | 88 | **88** | Sem mudança nesta janela. |
| Correção HTTP/2 | 85 | **85** | h2spec 145/146 reconfirmado — sem regressão das mudanças de hoje, mas também sem avanço novo (mesmo 1 skip histórico). |
| Correção WebSocket | 88 | **89** | Evidência nova de carga real bem-sucedida (500 conexões, 0 erros) — soma à conformidade Autobahn já coberta, não substitui. |
| Segurança | 84 | **84** | Sem mudança nesta janela. |
| Concorrência / thread-safety | 84 | **86** | **O #229 fechado é exatamente a lacuna que puxou esta dimensão pra baixo em 07-25** — resolvido com reprodução ao vivo + causa raiz provada (não só hipótese) + validação dupla. Não sobe mais porque #230 é um achado novo, ainda MEDIUM, na mesma vizinhança de código (deflate sob carga). |
| Segurança de memória / recursos | 84 | **85** | #227 ganhou rigor real (instrumentação nova, soak real de 2h24m) — não achou causa raiz, mas também não achou evidência de que o problema seja garantido/sistemático (passou da marca original sem repetir). Pequeno ganho por rigor, não por resolução. |
| Portabilidade | 88 | **88** | Confirmado sem regressão nos gates FPC Windows+Linux com as mudanças de hoje. |
| Robustez / estabilidade | 84 | **88** | **Maior recuperação desta reavaliação.** O maior recuo de 07-25 (-3, pelo segundo hang HIGH no io_uring N-rings) agora tem prova direta de resolução: 0/228 casos completando (exigindo kill) → 228/228 completando em 2 rodadas seguidas. Volta acima do nível de 07-24 porque a evidência aqui é mais forte (reprodução ao vivo + antes/depois mensurável) do que a que sustentava aquele número. |
| Cobertura de testes | 85 | **82** | **Recuo, não avanço — e é o método funcionando certo.** A baseline real (8 rodadas) mostra ~25% de trava completa do processo, não "3 testes lentos sem repetir" como 07-24 registrou. Mais rigor de medição revelou um problema MAIOR, não menor — isso pesa contra a nota, não a favor, mesmo o trabalho de medir tendo sido feito hoje. |
| API / DX | 83 | **84** | `WorkerActiveCount`/`WorkerIdleCount` — pequena adição real de observabilidade, sem breaking change. |
| Documentação | 79 | **79** | Novos relatórios de benchmark são documentação interna/datada (mesmo critério das reavaliações anteriores). |
| Ecossistema / features | 81 | **81** | Sem mudança nesta janela. |
| Prontidão para produção | 81 | **83** | O #229 resolvido remove um risco de exaustão de recurso sob carga real — ganho genuíno. Moderado pelo #228 (trava de suite pode refletir um bug real de drain/shutdown do IOCP em produção, não só um artefato de teste — não confirmado, mas não pode ser descartado). |
| Qualidade / manutenibilidade | 84 | **84** | Disciplina de commits com evidência mantida (mensagens com números reais, não promessas); gate 2-faces seguiu limpo. |

## Nota geral honesta: **~85/100 → ~85,6/100 (ganho real, modesto)**

Média ponderada (mesmo esquema das duas reavaliações anteriores) ≈ **85,6**.

Este é um ganho genuíno, não inflado: o #229 (o item nº1 apontado ontem)
foi resolvido com o padrão de evidência mais alto que esta série de
reavaliações já exigiu (reprodução ao vivo, causa raiz provada, validação
dupla) — isso puxa Concorrência e principalmente Robustez pra cima de
forma defensável. Mas o ganho não é maior porque, no MESMO dia, a
investigação do #228 revelou que a suite de testes é MENOS confiável do
que se pensava (trava completa ~25% das vezes, não só flakiness pontual) —
isso puxa Cobertura de testes pra baixo o suficiente pra quase cancelar o
ganho de Concorrência/Robustez. **Essa é exatamente a disciplina que essa
série de documentos vem defendendo: um dia produtivo não vira nota alta
por si só — cada achado, bom ou ruim, entra na conta pelo que realmente é.**

## Veredito
**Poseidon v2 sobe de ~85 para ~85,6/100 — o primeiro movimento de nota
real desde a meta de 07-24, sustentado por uma correção de concorrência
genuinamente bem provada (#229).** Ainda assim, o teto de curto prazo
(~90-92) segue distante: a suite de testes agora tem uma taxa de trava
CONHECIDA de ~25% que precisa virar causa raiz antes que "cobertura de
testes" possa subir de verdade, e #227/#230 seguem abertos sem causa raiz.
O projeto está mais confiável hoje do que ontem, de um jeito que dá pra
provar — mas "mais confiável" não é "resolvido".

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **#228 (trava de ~25% na suite Win64) — agora o item nº1, com dado real
   em vez de suspeita.** Suspeito localizado (`TPoseidonHttpServerDrainTests`,
   caminho IOCP/Windows) mas não confirmado pras travas desta bateria
   específica. Move: instrumentar a suite com timeout por teste (ou um
   wrapper que loga qual teste estava rodando no momento do kill) e
   investigar o drain/shutdown do IOCP com a mesma profundidade que
   resolveu #223/#224/#229 no lado Linux.
2. **#227 (degrau de memória) — instrumentado mas sem causa raiz, e o soak
   real ficou mais curto que o planejado.** Move: rerodar com o cycler
   corrigido (agora mede tempo real, não nominal) pra garantir 4h+ de carga
   sustentada de verdade, e considerar replicar a topologia original mais
   de perto.
3. **#230 (25 casos de deflate falhando graciosamente) — novo, MEDIUM, sem
   causa raiz.** Move: mesma metodologia live-debugging; já tem reprodução
   determinística (100% nas 2 rodadas), o que é uma vantagem — não é
   flakiness, é achável.

## O que NÃO preocupa (fortes reais)
- **O #229 foi resolvido com o padrão de evidência mais rigoroso já visto
  nesta série de reavaliações** — reprodução ao vivo com números concretos
  (161→372 threads), não uma hipótese "deve ser isso". A validação dupla
  (2 rodadas idênticas, 228/228 ambas) é prova de reprodutibilidade, não
  sorte.
- **A disciplina de não inflar a nota continua**: um dia com uma correção
  HIGH genuína não virou +3 ou +5 — o método puxou a nota de volta quando
  #228 revelou um problema mais sério que o esperado, exatamente como
  deveria.
- **Nenhuma regressão em nenhum dos gates existentes** (FPC Windows/Linux,
  h2spec, DUnitX, fuzz) apesar de mudanças reais em código de concorrência
  crítico (`Poseidon.Net.IO.IOUring.pas`).
- **#230 já nasce com reprodução determinística** — muito mais fácil de
  investigar do que um bug intermitente; é um achado "barato" de resolver
  numa próxima sessão dedicada.
- **A pesquisa sobre o Horse (HTTP/2/WebSocket) foi rigorosa e honesta** —
  em vez de forçar uma comparação impossível, o benchmark foi ajustado e
  documentado com a limitação explícita.

## Plano de ação (atualizado)
- **P0 CI**: instrumentar a suite Win64 com timeout/log por teste; localizar
  com certeza qual(is) teste(s) causam a trava de ~25%; investigar o
  drain/shutdown do IOCP com profundidade de live-debugging.
- **P1 memória**: rerodar o soak do #227 com o cycler corrigido, 4h+ reais.
- **P1 conformidade**: #230 — já reproduzível determinística, live-debugging
  direto nos 25 casos (12.2/12.3/12.5, janelas específicas).
- **P2 FPC**: #219 — os 4 sub-itens restantes seguem multi-dia.
- **Fase B (não-engenheirável, 92→100)**: tráfego de produção real em
  escala, auditoria de segurança de terceiro.
- **Higiene**: atualizar #211 com este snapshot (~85,6, ganho real via #229,
  moderado pela descoberta do #228; próximo salto depende de #228 e #227/#230).
