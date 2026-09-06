# analisa_balanceamento_pets.py: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/coupler/analisa_balanceamento_pets.py`.

## 1. Para que serve

Este script lê os logs ESMF de uma execução já concluída, extrai o tempo de parede gasto por cada componente e sugere uma repartição de PETs que equilibre a atmosfera e o oceano.

Ele responde à pergunta que o `plan-layout.py` não responde: dadas as contagens que você escolheu, elas ficaram equilibradas? E se não ficaram, quais seriam as contagens equilibradas para o mesmo total de PETs?

A diferença entre os dois é o momento de uso. O `plan-layout.py` roda antes, sobre uma razão arbitrária como 2:1, e trata de topologia de nós. Este roda depois, sobre tempo medido, e trata de balanceamento de trabalho. O ciclo natural é planejar com um, executar, medir com o outro, replanejar.

## 2. Por que somar todas as chamadas Run

Vale entender isto antes de ler qualquer número que o script produz.

Cada linha do log ESMF marca o início e o fim de uma fase, com `intro.` e `extro.`. A fase `Run` de um componente **não** corresponde a um passo de acoplamento. O MOM6 subcicla internamente: na prática se observam cerca de 301 pares `intro`/`extro` do oceano para 24 passos de acoplamento. O MPAS costuma ficar mais perto de uma chamada por passo.

Por isso o script sempre soma a duração de **todas** as chamadas `Run` de um componente, e só depois divide pelo número de passos de acoplamento. Essa métrica é robusta, independente de quantas sub-chamadas internas existirem. Contar pares `intro`/`extro` e chamar isso de "número de passos" daria um resultado errado por um fator próximo de doze no caso do oceano.

O número de passos vem do `esmApp_run.log`, campo `Passos (est.)`, ou da opção `--steps`.

## 3. Uso básico

Do diretório de experimento, depois de uma execução concluída:

```bash
python3 tools/coupler/analisa_balanceamento_pets.py
```

O relatório tem esta forma:

```
======================================================================
  Análise de balanceamento de PETs - MONAN-A x MOM6+SIS2
======================================================================
  Configuração         : concurrent + split
  PETs do ATM (MPAS)   : [0, 1, ..., 63]
  PETs do OCN (MOM6)   : [64, 65, 66, 67]
  PETs do ICE (SIS2)   : [68, 69, 70, 71]
  Passos de acoplamento: 24
----------------------------------------------------------------------
  Componente    PETs     Tempo total     Tempo/passo    Chamadas Run
  MPAS (ATM)      64        ...             ...             ...
  OCN (MOM6)       4        ...             ...             ...
  ICE (SIS2)       4        ...             ...             ...
  MED          todos        ...
----------------------------------------------------------------------
  Componente mais lento : MPAS (ATM)  (razão 8.00x)
  Componente mais rápido: ICE (SIS2)
  Desbalanceamento      : 700.0% de tempo ocioso no mais rápido
  Ganho vs. soma serial :  33.3%  (max(32.0, 12.0, 4.0) vs. soma 48.0 s)
----------------------------------------------------------------------
  Sugestão de partição para 72 PETs totais:
    atm_pet_count = ...
    ocn_pet_count = ...
    ice_pet_count = ...
  (partição atual: atm=64 ocn=4 ice=4 - ajuste sugerido acima.)
======================================================================
```

Sem o gelo, a linha de PETs do ICE diz `(componente desativado)`, o componente some da tabela e a sugestão traz duas contagens, seguidas de `use_sis2_dynamic = .false.` como lembrete de que a medição não incluiu gelo.

Apontando o diretório de logs e o número de passos explicitamente:

```bash
python3 tools/coupler/analisa_balanceamento_pets.py --logdir logs --steps 24
```

## 4. Como o layout é detectado

O script tenta dois caminhos, nesta ordem.

Primeiro, lê a linha que o `esm.F90` grava no log em nível INFO:

```
ESM: layout SPLIT (execucao SEQUENTIAL) - ATM=PET[0..5] OCN=PET[6..7] MED=todos (ICE desativado)
ESM: layout SPLIT (execucao SEQUENTIAL) - ATM=PET[0..63] OCN=PET[64..67] ICE=PET[68..71] MED=todos
ESM: layout SHARED (execucao CONCURRENT) - MPAS, MED e OCN em todos os PETs
```

O terceiro bloco vem na mesma linha, logo depois do de oceano, e só aparece com `use_sis2_dynamic = .true.`. Sem ele, o gelo é tratado como ausente.

O formato anterior à v14.20, em que os dois eixos eram um só, continua reconhecido, para que logs arquivados sigam legíveis.

Segundo, se essa linha não existir, o layout é **inferido** a partir de quais PETs efetivamente reportam atividade de cada componente. Conjuntos disjuntos indicam `split`; conjuntos idênticos indicam `shared`.

Esse segundo caminho é o caso comum em produção, porque `ESMF_LOGKIND_Multi_On_Error` suprime as mensagens de nível INFO.

Repare no que **não** é inferido: a execução. `sequential+split` e `concurrent+split` produzem exatamente os mesmos conjuntos de PETs, então não há como distingui-los a partir de quem reportou o quê. Nesse caso o script reporta a execução como indeterminada e **omite a linha de ganho de tempo de parede**, em vez de anunciar um ganho que talvez não exista. Para saber se houve sobreposição real, o instrumento é o `test-sequential-split.bash`, que mede a interseção das janelas de execução.

## 5. A fórmula de rebalanceamento

Assumindo escalonamento aproximadamente linear, ou seja, tempo proporcional a trabalho dividido pelo número de PETs, o trabalho de cada componente ativo é estimado como o tempo total multiplicado pelo número de PETs em que ele rodou.

A nova partição, para um total de PETs `N`, é a quota proporcional de cada componente:

```
quota_c = N * W_c / soma(W)
```

As quotas são arredondadas pelo método do maior resto, de modo que as contagens somem exatamente `N`, com piso de 1 PET por componente ativo. O piso existe porque o arredondamento pode zerar um componente muito rápido, e o driver rejeita contagem zero.

Com dois componentes o resultado é idêntico ao da fórmula anterior a esta revisão. Com três, a mesma conta se aplica ao gelo.

Isto é uma aproximação de primeira ordem. O escalonamento real não é linear: comunicação, desbalanceamento interno de domínio e efeitos de cache fazem o tempo cair menos que proporcionalmente ao número de PETs. Trate o resultado como ponto de partida para a próxima execução, não como valor exato.

O gelo tende a ser o caso em que a aproximação mais escorrega, porque o SIS2 costuma ser o componente mais barato e a quota proporcional o empurra para poucos PETs, região em que o custo fixo de comunicação pesa proporcionalmente mais. Se a sugestão der uma contagem muito pequena para o gelo, vale arredondar para cima e conferir na execução seguinte.

Com `pet_layout = 'shared'` a extrapolação é mais frágil ainda, porque cada componente foi medido usando todos os PETs, e a sugestão é para uma partição que nunca existiu. O script avisa quando é esse o caso. Uma medição em `split` real, mesmo curta, vale mais que a extrapolação.

## 6. Opções

| opção | padrão | significado |
| - | - | - |
| `--logdir DIR` | `./logs` | diretório com os `PET*.esmApp.log` |
| `--pattern GLOB` | `PET*.esmApp.log` | padrão dos arquivos de log |
| `--steps N` | detectado | número de passos de acoplamento |
| `--run-log ARQ` | procurado | caminho do `esmApp_run.log`, de onde os passos são lidos |
| `--target-pets N` | total observado | total de PETs para a partição sugerida |
| `--csv-out ARQ` | - | exporta o detalhe de cada chamada `Run` |
| `--json-out ARQ` | - | exporta o resumo, útil como referência futura |
| `--plot-out ARQ` | - | gera um PNG comparando o tempo por PET |
| `--baseline-json ARQ` | - | compara com um resumo JSON de calibração anterior |
| `-h` | - | ajuda |

`--plot-out` exige `matplotlib` no ambiente. O script usa o backend `Agg`, então não precisa de display.

## 7. Casos de uso

**Dimensionar para outro total de PETs.** Se a rodada de calibração usou 68 PETs e a produção vai usar 128:

```bash
python3 tools/coupler/analisa_balanceamento_pets.py --target-pets 128
```

**Guardar uma calibração e comparar depois.** Salve o resumo de hoje e use como referência na próxima medição, para ver se uma alteração de código mudou o custo de algum componente:

```bash
# hoje
python3 tools/coupler/analisa_balanceamento_pets.py --json-out calib-2026-09.json

# depois de alterar o código e rodar de novo
python3 tools/coupler/analisa_balanceamento_pets.py --baseline-json calib-2026-09.json
```

A comparação imprime o tempo anterior, o atual e a diferença para cada componente. Isso não substitui a linha de base do `compara-linha-base.bash`, que verifica **resultado numérico**; aqui se verifica **custo**. As duas coisas são independentes: uma alteração pode preservar o resultado bit a bit e mesmo assim dobrar o tempo.

Referências gravadas antes desta revisão continuam utilizáveis: os campos de atmosfera e oceano são os mesmos. Quando as duas medições diferem na presença do gelo, isso aparece explicitamente, em vez de a diferença ser omitida:

```
    MPAS (ATM) : 32.000 s -> 32.000 s  (Δ +0.000 s)
    OCN (MOM6) : 12.000 s -> 12.000 s  (Δ +0.000 s)
    ICE (SIS2) : ausente na referência -> 4.000 s (novo componente)
```

Ou, no sentido inverso, `ICE (SIS2) : 4.000 s -> componente ausente nesta medição`. Nos dois casos o que mudou foi a configuração, não o desempenho, e comparar os totais entre as duas seria enganoso.

**Inspecionar chamada a chamada.** `--csv-out` exporta cada par `intro`/`extro` individualmente, com o PET e o componente. Útil quando o desbalanceamento não é entre componentes, e sim entre PETs do mesmo componente.

## 8. Avisos que aparecem no relatório

**Pares intro/extro incompletos.** O log foi truncado ou a execução foi cancelada no meio. Os pares incompletos são descartados e o script segue. Se o número for grande em relação ao total, o resultado perde confiabilidade.

**Passos de acoplamento N/D.** O `esmApp_run.log` não foi encontrado ou não trazia o campo. Sem isso, o tempo total continua válido, mas o tempo por passo não é calculado. Informe `--steps`.

**Total de PETs insuficiente para sugerir partição.** Aparece quando não há PETs suficientes para um bloco por componente ativo.

**Atividade de ICE sem bloco atribuído.** Há pares `Run` do SIS2 nos logs, mas o script não conseguiu dizer a quais PETs o componente pertence: nem a linha `ESM: layout ...` trazia a faixa `ICE=PET[a..b]`, nem a inferência resolveu. O componente é omitido do relatório, e o aviso existe para que essa omissão não passe em silêncio. Confira a linha de layout nos logs.

## 9. Limitações conhecidas

**Escalonamento linear.** Ver a seção 5. A sugestão precisa de validação por execução, não é resultado fechado.

**A execução não é inferida sem a linha de INFO.** Ver a seção 4. Com o log em `Multi_On_Error`, a linha de ganho de tempo de parede é omitida por construção.

## 10. Documentos relacionados

`docs/uso-plan-layout.md`, para planejar a topologia antes de rodar. O `plan-layout.py` aceita `--ice K`, então a contagem de `ice_pet_count` sugerida aqui pode ser levada direto para lá e conferida quanto a nós e limites de fila.

`docs/uso-smoke-tests.md`, para verificar que a combinação escolhida chega ao primeiro passo sem travar, e para medir sobreposição real entre componentes.

`docs/uso-linha-base.md`, para verificar que uma alteração de código não mudou o resultado numérico.
