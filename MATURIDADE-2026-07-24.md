# Poseidon — Avaliação de Maturidade (2026-07-24) — sprint de 5 issues + CI ao vivo

> Continuação do documento vivo `MATURIDADE-2026-07-22.md`. Esta reavaliação
> cobre um sprint do mesmo dia que atacou #223, #215, #218, #216 e #219, mais
> a verificação em produção real do runner CI registrado em 07-22 (dormente
> naquela avaliação) sob 3 pushes reais de hoje.

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade, auditado por terceiros.
"Correto por leitura" ≠ "correto por prova".

## O que mudou desde 07-22 (com evidência)

- **#223 FECHADO — a "concorrência nova sem segundo par de olhos" que 07-22
  apontou agora TEM esse segundo olhar.** Ctx.Defer/SyncDispatch investigado a
  fundo: 3 causas raiz reais (guarda de reentrância ausente, `WSACleanup`
  process-wide chamado por instância, AcceptEx sem retry de re-arm) — nenhuma
  delas era a hipótese original de threadvar. Corrigido em `43fd911`. Achado
  residual (`TSocketPool` global-por-classe entre instâncias) não escondido,
  virou #225.
- **#224 FECHADO — hang de accept sob carga sustentada no N-rings io_uring
  (Linux nativo).** Exatamente o risco que 07-22 apontou ("N-rings é reescrita
  recente... ainda sem tempo de maturação"): o worker não varria o próprio
  deque no caminho de timeout do semáforo. Corrigido com varredura periódica;
  **30/30 limpo** no reprodutor original.
- **#215 FECHADO — soak de 3h do app COMPLETO (CRUD+Postgres) rodando no
  master ATUAL** (pós-N-rings #220, pós-#223, pós-#224) — fecha exatamente a
  lacuna que 07-22 apontou ("o soak de 5,4h que provou memória flat rodou
  ANTES do refactor N-rings"). Resultado: 1.622.242 requisições, **0% falha**,
  0 iterações interrompidas, p95 4,76ms. Memória: platô em ~48MB por 45min,
  DEGRAU para ~118MB aos 2h12m (não escondido, virou #227), depois **flat por
  1h inteira sem variar 1 KB**. Sem vazamento; degrau não explicado ainda.
- **#218 FECHADO — benchmark de perf rigoroso, o gap nº1 apontado em
  Performance desde 07-15.** wrk real na VPS (mesmo host do #224), 200
  conexões concorrentes, 0 erros: /ping 44,7K req/s (nginx estático 80,1K,
  1,8×) e /json 37,2K req/s (nginx 39,8K, 1,07×). Uma tentativa de saturação
  via k6 mostrou um teto bem mais baixo (~19K/s) — identificado como limite do
  PRÓPRIO gerador k6 sob CPU compartilhada, e descartado explicitamente em vez
  de reportado como teto do servidor.
- **#216 FECHADO — conformidade quase total.** Autobahn 227/228 (permessage-
  deflate 12/13, 9.7-9.9) + h2spec 145/146 reconfirmado. Único caso residual
  (12.2.17, deflate de mensagens grandes fragmentadas) não escondido, virou
  #226.
- **#219 parcial — item 4 (SIGTERM/SIGHUP) agora com prova de RUNTIME real**,
  não só compile-test: `server_signal_run.pas` recebe um `kill -TERM` externo
  de verdade (não auto-sinal) e verifica que `CheckShutdownSignal` dispara o
  callback. Os outros 4 sub-itens seguem honestamente em aberto (1 bloqueador
  externo do compilador FPC, 1 porte de 480+ testes DUnitX para FPC — escopo
  de dias, não de uma sessão —, 1 Lazarus/LCL não iniciado, 1 soak FPC
  separado não feito).
- **Runner CI (registrado dormente em 07-22) agora VERIFICADO ONLINE e rodando
  de verdade.** 3 commits de hoje dispararam CI real (`gh api
  .../actions/runners` → `status: online`); `compile-and-test` e
  `CI — dual-face build` executaram nos 3 pushes.

### Achado novo de PROCESSO (não estava em 07-22): CI "verde" exige re-run

Ao verificar os runs de hoje, **3 execuções falharam**, cada uma em um teste
DIFERENTE do `win64-suite`, nenhum presente na lista de tolerados (que desde
o #203 diz "no tests are tolerated here anymore"):
1. `78284ad` (pré-fix #223): `Defer_UnderSyncDispatch_AsyncHandlerWorks` —
   esperado, é a própria flakiness que o #223 corrigiu (boa corroboração
   independente).
2. `43fd911` (fix do #223 já aplicado): `Post_BurstAboveMin_SpawnsAdditional`
   — teste de burst-scaling do worker pool, sem relação com o que o commit
   mudou.
3. `18c108a` (teste de sinal FPC/Linux): `Sync_PlainRoute_Works` — de novo,
   sem relação com o que o commit mudou.

Nenhuma das duas últimas se repetiu no re-run. Hipótese mais provável (não
confirmada): o runner roda nesta MESMA máquina de desenvolvimento, que hoje
também sustentava o soak de 3h do #215 + trabalho na VPS — contenção de CPU
afetando testes sensíveis a timing. Isso é **pior do que "CI dormente"**: um
CI que roda mas não é confiavelmente verde num único shot é uma lacuna real
de infraestrutura, não um bug do produto. Aberto como **#228** em vez de
tratado como ruído.

## Pontuação por dimensão (Δ vs 07-22)

| Dimensão | 07-22 | **07-24** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança estrutural nesta janela. |
| Performance | 86 | **90** | **O gap nº1 apontado (benchmark pesado real) fechou com número**: wrk real na VPS, comparativo vs nginx, 200 conexões, 0 erro. Segura: 1,07× no /json é modesto; gap de custo-por-request vs mORMot2 (#220) segue documentado, não escondido. |
| Correção HTTP/1.1 | 88 | **88** | Sem mudança nesta janela. |
| Correção HTTP/2 | 85 | **85** | h2spec 145/146 reconfirmado; ainda 1 skip. |
| Correção WebSocket | 87 | **88** | Autobahn 227/228 nos ranges antes pulados (deflate 12/13, 9.7-9.9). 1 falha residual não escondida (#226). |
| Segurança | 84 | **84** | Sem mudança nesta janela. |
| Concorrência / thread-safety | 82 | **85** | **A lacuna exata de 07-22** ("Ctx.Defer sem revisão independente registrada") foi fechada: investigação rigorosa encontrou 3 causas raiz reais, nenhuma a hipótese original — mais rigoroso que o auto-teste que existia antes. #224 (hang do N-rings) também é uma correção de concorrência real, verificada 30/30. |
| Segurança de memória / recursos | 81 | **85** | **A lacuna exata de 07-22** ("soak de 5,4h é anterior ao N-rings") foi fechada: novo soak de 3h no master ATUAL (pós-N-rings/#223/#224), app completo com DB, memória estabiliza. Segura: o degrau 48→118MB no meio do teste não tem causa raiz identificada ainda (#227) — honesto, não é "flat" perfeito. |
| Portabilidade | 87 | **88** | #219 item 4 ganhou prova de RUNTIME (kill -TERM externo real), não só compile-test. Segura: 4/5 sub-itens do #219 seguem abertos. |
| Robustez / estabilidade | 84 | **87** | #224 (hang de accept sob carga) era exatamente o risco de maturação que 07-22 apontou para o N-rings — encontrado e corrigido com prova (30/30). Soak do #215 roda no binário atual, não num predecessor. |
| Cobertura de testes | 84 | **83** | Suite cresceu 480→**508** (Defer + signal tests). Mas achado novo: **3 falhas distintas e não-repetidas no win64-suite em um único dia**, nenhuma tolerada pela baseline — o gate não é confiavelmente verde num único run (#228, novo). Pequeno recuo honesto: mais teste ≠ automaticamente mais cobertura confiável se o gate em si é instável. |
| API / DX | 83 | **83** | Sem mudança nesta janela. |
| Documentação | 79 | **79** | Sem mudança material nesta janela (relatórios internos não contam como docs públicas). |
| Ecossistema / features | 81 | **81** | Sem mudança nesta janela. |
| Prontidão para produção | 76 | **82** | **Os dois bloqueadores nº1 de 07-22 caíram no mesmo dia**: CI deixou de ser dormente (verificado online, 3 pushes reais processados) e #215 (soak app completo) fechou com dado real. Segura FORTE, sem mudança: zero quilometragem de produção real; review obrigatório segue bypassado por padrão (aceito para projeto solo, não é um defeito novo). Novo achado (#228) mostra que "CI rodando" ainda não é "CI confiável de primeira", o que modera o tamanho do salto. |
| Qualidade / manutenibilidade | 83 | **84** | Disciplina de gate 2-faces mantida ao longo de um sprint de 5 issues no mesmo dia; nenhum commit quebrou a outra face. |

## Nota geral honesta: **~84/100 → ~85/100**

Média ponderada (reliability-critical ×3: correção HTTP/1-2-WS, segurança,
concorrência, memória, robustez, testes, prontidão; importantes ×2:
performance, portabilidade, API, qualidade; contexto ×1: arquitetura, docs,
ecossistema) ≈ **85,2**.

**Isto cruza a META 85 do #211** — mas por um caminho específico, não por
inflação genérica: os DOIS fatores que as duas avaliações anteriores nomearam,
de forma consistente e repetida, como "o que mais segura a nota" (soak do app
completo pós-N-rings, e CI dormente) caíram no mesmo dia, com prova direta e
sem atalho. Ao mesmo tempo, a sessão também **encontrou e não escondeu** três
achados que uma reavaliação otimista teria varrido para debaixo do tapete: o
degrau de memória no soak (#227), o caso Autobahn residual (#226), e a
flakiness de 3 testes distintos no CI hoje (#228). O salto de 84→85 é real,
mas magro — não é "tudo resolvido", é "os dois maiores buracos taparam e
apareceram três menores".

## Veredito
**Poseidon v2 atinge a meta interna de 85/100 — production-grade sólido para
cargas não-críticas, com evidência de que os dois maiores riscos em aberto
(endurance pós-refactor, CI operacional) foram endereçados com prova, não
promessa.** O teto agora não é mais "será que os fixes recentes se sustentam
sob carga" — é o que a Fase B do #211 sempre disse: quilometragem de produção
real, que nenhuma sessão, por mais longa, substitui. Engenheiravelmente, o
projeto está perto do teto de ~90-92 que o próprio roadmap havia projetado.

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **Prontidão (82) — falta produção real; CI ainda não é verde de primeira.**
   Move: tráfego de staging real por dias; investigar #228 (a suite precisa
   de re-run hoje, o que não é aceitável como estado permanente).
2. **Cobertura de testes (83) — gate win64-suite instável sob concorrência da
   máquina.** Move: rodar a suite 5-10× numa janela ociosa para estabelecer
   taxa-base real de flakiness (#228); se confirmado que é contenção de CPU,
   isolar a suite ou dar tolerância de timing aos testes afetados.
3. **Memória/Concorrência (85/85) — degrau de memória no soak sem causa raiz
   (#227), TSocketPool global entre instâncias (#225).** Move: sessão dedicada
   de profiling no degrau; revisar o design do `TSocketPool` para não ser
   compartilhado entre instâncias de servidor.

## O que NÃO preocupa (fortes reais)
- **Os dois maiores riscos identificados nas duas avaliações anteriores foram
  fechados no mesmo dia, com prova direta e sem atalho** — não é comum um
  roadmap prever exatamente os dois maiores buracos e vê-los fecharem juntos.
- **Disciplina de não esconder achados desconfortáveis**: 3 issues novas
  (#225/#226/#227) abertas no mesmo dia que os fixes que as geraram, mais uma
  quarta (#228) sobre o próprio processo de CI — nenhuma varrida para debaixo
  do tapete para "fechar bonito".
- **N-rings io_uring e Ctx.Defer, os dois trechos de concorrência mais
  arriscados do projeto, agora têm prova de endurance/revisão dedicada cada
  um** — não é mais "código novo sem segundo olhar".
- **Gate de 2 faces (Delphi/FPC) mantido perfeito ao longo de um sprint de 5
  issues no mesmo dia** — disciplina de processo não escorregou sob pressão
  de "terminar hoje".

## Plano de ação (atualizado)
- **P1 processo:** investigar #228 (flakiness de 3 testes distintos no CI) —
  estabelecer se é contenção de CPU do runner compartilhado ou algo real.
- **P2 memória:** #227 (degrau 48→118MB no soak) — profiling dedicado.
- **P2 concorrência:** #225 (`TSocketPool` global entre instâncias).
- **P2 conformidade:** #226 (Autobahn 12.2.17, único caso residual).
- **P2 FPC:** #219 — os 4 sub-itens restantes (worker-pool async sob FPC,
  porte da suíte DUnitX, Lazarus/LCL, soak em binário FPC).
- **Fase B (não-engenheirável, 92→100):** tráfego de produção real em escala,
  auditoria de segurança de terceiro — sem atalho, é tempo e mundo real.
- **Higiene:** atualizar #211 com este snapshot (~85, META atingida; próximo
  teto é ~90-92 via Fase A residual, depois Fase B não-engenheirável).
