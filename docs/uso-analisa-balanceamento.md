# analisa_balanceamento_pets.py: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/coupler/analisa_balanceamento_pets.py`, versão 14.22 (23/09/2026).

## 1. Para que serve

Este script lê os logs ESMF de uma execução já concluída, extrai o tempo de parede gasto por cada componente (atmosfera, oceano, gelo e mediador) e sugere uma repartição de PETs que equilibre os componentes.

Ele responde à pergunta que o `plan-layout.py` não responde: dadas as contagens que você escolheu, elas ficaram equilibradas? E, se não ficaram, quais seriam as contagens equilibradas para o mesmo total de PETs, ou para outro total?

A diferença entre os dois é o momento de uso. O `plan-layout.py` roda antes, sobre uma razão arbitrária como 2:1, e trata de topologia de nós. Este roda depois, sobre tempo medido, e trata de balanceamento de trabalho. O ciclo natural é planejar com um, executar, medir com o outro, replanejar.

**Um exemplo do que ele revela.** Na execução de 144 PETs de 23/09/2026 (128 para a atmosfera, 8 para o oceano, 8 para o gelo), a suposição natural era que a atmosfera, com física completa em 40 962 colunas, fosse o componente mais caro. O script mostrou o contrário: o oceano levava 201 s de cálculo, a atmosfera 97 s e o gelo 3,6 s. A atmosfera passava metade do tempo parada esperando o oceano. Sem a medida, o passo seguinte teria sido dar mais processadores à atmosfera, o que não aceleraria nada.

## 2. Por que somar todas as chamadas Run

Vale entender isto antes de ler qualquer número que o script produz.

Cada linha do log ESMF marca o início e o fim de uma fase, com `intro.` e `extro.`. A fase `Run` de um componente não corresponde necessariamente a um passo de acoplamento: versões anteriores do acoplador chegaram a registrar cerca de 301 pares `intro`/`extro` do oceano para 24 passos de acoplamento. Na versão atual, cada PET registra uma chamada por troca, mas o script não depende disso.

Por isso ele sempre soma a duração de **todas** as chamadas `Run` de um componente em cada PET, toma o maior total entre os PETs do componente (o componente termina quando o seu PET mais lento termina) e só depois divide pelo número de passos de acoplamento. Essa métrica é robusta, independente de quantas sub-chamadas internas existirem.

O número de passos vem do `esmApp_run.log`, campo `Passos (est.)`, ou da opção `--steps`.

## 3. Uso básico

Do diretório de experimento, depois de uma execução concluída:

```bash
python3 $COUPLER_ROOT/tools/coupler/analisa_balanceamento_pets.py
```

Rodar a partir do diretório de experimento também permite ao script encontrar sozinho o `MOM_input` e os arquivos `x1.<N>.*` do MPAS, de onde tira o tamanho das grades (seção 6).

Para logs arquivados em outro diretório:

```bash
python3 $COUPLER_ROOT/tools/coupler/analisa_balanceamento_pets.py --logdir repro-conc-144-4/logs
```

O relatório, com os tempos medidos na execução de 144 PETs, tem esta forma:

```
======================================================================
  Análise de balanceamento de PETs - MONAN-A x MOM6+SIS2
======================================================================
  Configuração         : concurrent + split
  PETs do ATM (MPAS)   : [0, 1, ..., 127]
  PETs do OCN (MOM6)   : [128, ..., 135]
  PETs do ICE (SIS2)   : [136, ..., 143]
  Passos de acoplamento: 24
----------------------------------------------------------------------
  Componente    PETs     Tempo total     Tempo/passo     Run por PET
  MPAS (ATM)     128        97.056 s         4.044 s              24
  OCN (MOM6)       8       200.660 s         8.361 s              24
  ICE (SIS2)       8         3.600 s         0.150 s              24
  MED          todos         8.199 s
----------------------------------------------------------------------
  Gargalo (mais lento)  : OCN (MOM6), 200.7 s
  Tempo parado esperando o gargalo:
    MPAS (ATM)    51.6%
    OCN (MOM6)     0.0%  <- gargalo
    ICE (SIS2)    98.2%
  Ganho vs. soma serial :  33.4%  (max(97.1, 200.7, 3.6) vs. soma 301.3 s)
----------------------------------------------------------------------
  Grades consideradas   : oceano/gelo 180 x 155, MPAS 40962 células
----------------------------------------------------------------------
  Sugestão de partição para 144 PETs totais:
    atm_pet_count = 126
    ocn_pet_count = 17
    ice_pet_count = 1
  (divisão proporcional ao trabalho medido, supondo escala linear)
  AVISO sugestão, OCN (MOM6): 17 PETs: melhor layout 17 x 1, blocos de 10 x 155 pontos, lado menor que 20 (número primo: só há 1 x n ou n x 1)
  Ajuste prático (contagens viáveis mais próximas, 144 PETs):
    atm_pet_count = 127
    ocn_pet_count = 16
    ice_pet_count = 1
    (OCN (MOM6): melhor layout 4 x 4, blocos de 45 x 38)
    (ICE (SIS2): melhor layout 1 x 1, blocos de 180 x 155)
    (gelo com 1 PET: piso da divisão, pelo trabalho medido; arranjo sem troca de bordas, a validar)
  (partição atual: atm=128 ocn=8 ice=8 - ajuste sugerido acima.)
======================================================================
```

Como ler cada bloco:

| Bloco | O que diz |
| --- | --- |
| tabela de componentes | tempo total de cálculo (maior entre os PETs do componente), tempo por troca e chamadas `Run` por PET |
| MED | o mediador roda em todos os PETs, entre as fases dos componentes; não entra na divisão |
| gargalo e tempo parado | no modo concorrente, cada troca termina quando o mais lento termina; o tempo parado de um componente é 1 − t / t_max. É a medida de desequilíbrio que interessa |
| ganho vs. soma serial | quanto a execução concorrente economiza em relação a rodar os componentes um depois do outro |
| grades consideradas | de onde vieram os tamanhos usados para avaliar as contagens (ou o aviso de que não foram encontrados) |
| sugestão de partição | a divisão proporcional ao trabalho medido (seção 5) |
| avisos e ajuste prático | contagens que o modelo não aproveitaria e a alternativa viável mais próxima (seção 6) |

Sem o gelo, a linha de PETs do ICE diz `(componente desativado)`, o componente some da tabela, e a sugestão traz duas contagens seguidas de `use_sis2_dynamic = .false.`, como lembrete de que a medição não incluiu gelo.

Na execução sequencial, ou com `pet_layout = 'shared'`, os componentes não rodam ao mesmo tempo. O bloco de tempo parado é substituído pela participação de cada componente no tempo total.

## 4. Como o layout é detectado

O script tenta dois caminhos, nesta ordem.

Primeiro, lê a linha que o `esm.F90` grava no log em nível INFO:

```
ESM: layout SPLIT (execucao SEQUENTIAL) - ATM=PET[0..5] OCN=PET[6..7] MED=todos (ICE desativado)
ESM: layout SPLIT (execucao CONCURRENT) - ATM=PET[0..127] OCN=PET[128..135] ICE=PET[136..143] MED=todos
ESM: layout SHARED (execucao CONCURRENT) - MPAS, MED e OCN em todos os PETs
```

O bloco do gelo vem na mesma linha, logo depois do de oceano, e só aparece com `use_sis2_dynamic = .true.`. O formato anterior à v14.20, em que os dois eixos eram um só, continua reconhecido, para que logs arquivados sigam legíveis.

Segundo, se essa linha não existir, o layout é **inferido** a partir de quais PETs efetivamente reportam atividade de cada componente. Conjuntos disjuntos indicam `split`; conjuntos idênticos indicam `shared`. Esse é o caso comum em produção, porque `log_kind = 'multi_on_error'` suprime as mensagens de nível INFO.

A execução (sequencial ou concorrente) **não** é inferida: `sequential+split` e `concurrent+split` produzem os mesmos conjuntos de PETs. Nesse caso o script reporta a execução como indeterminada e omite a linha de ganho, em vez de anunciar um ganho que talvez não exista. Para saber se houve sobreposição real, o instrumento é o `test-sequential-split.bash`.

Acima de 99 PETs, os logs passam a ter três algarismos (`PET000.esmApp.log`). O padrão `PET*.esmApp.log` cobre os dois formatos, e nada precisa ser informado.

## 5. A divisão proporcional

Assumindo escalonamento aproximadamente linear, ou seja, tempo proporcional a trabalho dividido pelo número de PETs, o trabalho de cada componente ativo é estimado como o tempo total multiplicado pelo número de PETs em que ele rodou. A nova partição, para um total de PETs `N`, é a quota proporcional de cada componente:

```
quota_c = N * W_c / soma(W)
```

As quotas são arredondadas pelo método do maior resto, de modo que as contagens somem exatamente `N`, com piso de 1 PET por componente ativo. O piso existe porque o arredondamento pode zerar um componente muito rápido, e o driver rejeita contagem zero.

A conta para o exemplo da seção 3:

| Componente | Trabalho (tempo × PETs) | Quota exata | Maior resto | Com o piso |
| --- | --- | --- | --- | --- |
| atmosfera | 97,06 × 128 = 12 423 | 127,27 | 127 | 126 |
| oceano | 200,66 × 8 = 1 605 | 16,44 | 17 | 17 |
| gelo | 3,60 × 8 = 29 | 0,30 | 0 | 1 |

**O gelo com 1 PET.** A quota do gelo é 0,3 PET: o trabalho dele é tão pequeno que, para acompanhar os outros, bastaria um terço de um processador. O piso o leva a 1. Com 1 PET, a estimativa linear dá cerca de 29 s de cálculo, contra cerca de 100 s dos outros componentes na divisão sugerida: o gelo continuaria longe de ser o gargalo. O valor é plausível, mas é o piso da divisão, não um ótimo: qualquer contagem entre 1 e 4 deixa o gelo bem abaixo dos outros, e a escolha entre elas é de conveniência. Com 1 PET o SIS2 não troca bordas entre processadores, o que é um caminho de código diferente e ainda não testado.

**Limites da aproximação.** O escalonamento real não é linear: comunicação, desequilíbrio interno do domínio e efeitos de cache fazem o tempo cair menos que proporcionalmente ao número de PETs. Trate o resultado como ponto de partida para a próxima execução, não como valor exato. Com `pet_layout = 'shared'` a extrapolação é mais frágil ainda, porque cada componente foi medido usando todos os PETs; o script avisa quando é esse o caso.

## 6. Viabilidade das contagens e ajuste prático

A divisão proporcional só olha o trabalho medido. Ela pode propor contagens que o modelo não aproveita. O caso típico é um número primo de PETs para o oceano: o MOM6 só consegue dividir o domínio em 1 × n ou n × 1, e com 17 PETs a grade de 180 × 155 vira faixas de 10 pontos de largura, com muita troca de bordas para pouco cálculo.

Por isso, desde a v14.22, o script avalia cada contagem, a atual e a sugerida:

| Componente | Critério | Limite padrão |
| --- | --- | --- |
| oceano e gelo | menor lado do bloco, no melhor layout possível para aquela contagem | 20 pontos (`--min-block`) |
| atmosfera | células da malha MPAS por PET | 150 (`--min-cells-per-pet`) |

"Melhor layout" é a fatoração a × b que dá os maiores blocos. O layout automático do MOM6 e do SIS2 pode escolher outra, mas não consegue fazer melhor que esta.

Quando a contagem sugerida para o oceano ou o gelo não passa, o script mostra um **ajuste prático**: a contagem viável mais próxima da quota exata (em empate, a de blocos maiores), com a atmosfera absorvendo a diferença, porque a malha do MPAS aceita qualquer número de PETs. No exemplo, 17 vira 16 (layout 4 × 4, blocos de 45 × 38), e a atmosfera fica com 127. Para 272 PETs, a sugestão 240 + 31 + 1 vira 239 + 32 + 1 (oceano em 8 × 4, blocos de 22 × 38).

Os limites de 20 pontos e 150 células são referências práticas, não regras: blocos menores ainda funcionam, só escalam pior. Ajuste-os se as medições indicarem outros valores.

**De onde vêm as grades.** `NIGLOBAL` e `NJGLOBAL` são lidos de `MOM_parameter_doc.all`, `MOM_input` ou `MOM_override`; o número de células do MPAS, do nome dos arquivos `x1.<N>.*` (por exemplo, `x1.40962.graph.info`). A busca é feita no diretório atual, no diretório dos logs e no de cima. Se nada for encontrado, o relatório diz que as grades não foram encontradas e segue sem a avaliação; nesse caso, informe-as com `--ocn-grid` e `--atm-cells`.

## 7. Opções

| Opção | Padrão | Significado |
| --- | --- | --- |
| `--logdir DIR` | `./logs` | diretório com os `PET*.esmApp.log` |
| `--pattern GLOB` | `PET*.esmApp.log` | padrão dos arquivos de log |
| `--steps N` | detectado | número de passos de acoplamento |
| `--run-log ARQ` | procurado | caminho do `esmApp_run.log`, de onde os passos são lidos |
| `--target-pets N` | total observado | total de PETs para a partição sugerida |
| `--ocn-grid NIxNJ` | detectado | grade do oceano e do gelo, por exemplo `180x155` |
| `--atm-cells N` | detectado | células da malha MPAS |
| `--min-block N` | 20 | menor lado aceitável de um bloco do oceano e do gelo |
| `--min-cells-per-pet N` | 150 | mínimo de células MPAS por PET |
| `--csv-out ARQ` | nenhum | exporta o detalhe de cada chamada `Run` |
| `--json-out ARQ` | nenhum | exporta o resumo, útil como referência futura |
| `--plot-out ARQ` | nenhum | gera um PNG comparando o tempo por PET (exige `matplotlib`; usa o backend `Agg`, sem display) |
| `--baseline-json ARQ` | nenhum | compara com um resumo JSON de calibração anterior |
| `-h` | | ajuda |

## 8. Casos de uso

**Descobrir quem limita a velocidade.** Uma execução qualquer, com `log_kind = 'multi'` (o padrão), e o script sobre os logs dela. O bloco de tempo parado responde. Não custa fila: logs de execuções já feitas servem, inclusive os de baterias de reprodutibilidade arquivadas.

**Dimensionar para outro total de PETs.** Com os logs de uma execução de 144 PETs, sugerir a divisão para 272:

```bash
python3 $COUPLER_ROOT/tools/coupler/analisa_balanceamento_pets.py --logdir teste2-decomp --target-pets 272
```

A sugestão é uma extrapolação linear e precisa de uma execução real para confirmar.

**Guardar uma calibração e comparar depois.** Para ver se uma alteração de código mudou o custo de algum componente:

```bash
# hoje
python3 $COUPLER_ROOT/tools/coupler/analisa_balanceamento_pets.py --json-out calib-2026-09.json

# depois de alterar o código e rodar de novo
python3 $COUPLER_ROOT/tools/coupler/analisa_balanceamento_pets.py --baseline-json calib-2026-09.json
```

A comparação imprime o tempo anterior, o atual e a diferença para cada componente. Isso não substitui a verificação de resultado numérico (`compara-linha-base.bash`, `mede-taxa-repro.sh`): aqui se verifica custo. As duas coisas são independentes; uma alteração pode preservar o resultado bit a bit e dobrar o tempo. Um exemplo real: a correção `B-SRCTERM-01`, que tornou os remapeamentos reprodutíveis, desliga uma otimização de comunicação do ESMF, e o efeito dela no tempo é exatamente o tipo de coisa que esta comparação mede.

Referências gravadas por versões anteriores continuam utilizáveis: os campos de atmosfera, oceano e gelo são os mesmos. Quando as duas medições diferem na presença do gelo, isso aparece explicitamente (`ausente na referência` ou `componente ausente nesta medição`), porque o que mudou foi a configuração, não o desempenho.

**Inspecionar chamada a chamada.** `--csv-out` exporta cada par `intro`/`extro` com o PET e o componente. Útil quando o desequilíbrio não é entre componentes, e sim entre PETs do mesmo componente.

## 9. Mudar o número de PETs e a reprodutibilidade

O script trata só de desempenho, mas toda mudança de contagem tem uma consequência para a verificação de resultado, medida em 23/09/2026:

| O que muda | Efeito no resultado |
| --- | --- |
| divisão do domínio do gelo, com o mesmo número de PETs de gelo | nenhum: 4 × 2 e 2 × 4 deram resultado idêntico bit a bit, inclusive no estado interno do SIS2 |
| número de PETs da atmosfera, ou o total (o mediador ocupa todos os PETs) | o resultado muda, como esperado: as somas passam a ser feitas em outros pedaços. Cada configuração nova precisa de uma bateria do `mede-taxa-repro.sh` |
| número de PETs do oceano e do gelo, mantendo atmosfera e total | ainda não medido; a previsão é que não mude, pelo projeto do MOM6 e do SIS2 |

Desde a correção `B-ICE-DECOMP-01` (commit `a9e6935`), o cap do SIS2 segue a decomposição do próprio SIS2, e qualquer contagem de PETs de gelo sugerida aqui pode ser usada diretamente, sem fixar o `LAYOUT`. Em binários anteriores a esse commit, contagens de gelo diferentes de 4 exigiam fixar o layout no `SIS_override` (com 8 PETs, `#override LAYOUT = 4, 2`), senão a inicialização quebrava com índice fora do intervalo em `sis_cap_MONAN.F90`.

## 10. Avisos que aparecem no relatório

**AVISO partição atual / AVISO sugestão.** A contagem indicada daria blocos menores que o limite, ou células MPAS por PET abaixo do mínimo. Para a sugestão, veja o ajuste prático logo abaixo.

**Grades consideradas: não encontradas.** O script não achou os arquivos do MOM6 nem os do MPAS. A análise de tempo continua válida; só a avaliação das contagens é omitida. Rode do diretório do experimento ou use `--ocn-grid` e `--atm-cells`.

**Pares intro/extro incompletos.** O log foi truncado ou a execução foi cancelada no meio. Os pares incompletos são descartados. Se o número for grande em relação ao total, o resultado perde confiabilidade.

**Passos de acoplamento N/D.** O `esmApp_run.log` não foi encontrado ou não trazia o campo. O tempo total continua válido; o tempo por passo não é calculado. Informe `--steps`.

**Total de PETs insuficiente para sugerir partição.** Não há PETs suficientes para um bloco por componente ativo.

**Atividade de ICE sem bloco atribuído.** Há pares `Run` do SIS2 nos logs, mas o script não conseguiu dizer a quais PETs o componente pertence. O componente é omitido do relatório; confira a linha `ESM: layout ...` nos logs.

## 11. Limitações conhecidas

**Escalonamento linear.** Ver a seção 5. A sugestão precisa de validação por execução.

**A execução não é inferida sem a linha de INFO.** Ver a seção 4.

**O layout real pode ser pior que o "melhor layout".** O MOM6 e o SIS2 escolhem sozinhos a fatoração com `LAYOUT = 0, 0`. A avaliação usa o melhor caso possível; confira no `MOM_parameter_doc.layout` e no `SIS_parameter_doc.layout` o layout que o modelo escolheu de fato.

**O tempo de inicialização não entra na divisão.** Leitura de condições iniciais, criação dos pesos de remapeamento e escrita de saídas não escalam como o cálculo. Na execução de 144 PETs, cerca de 20 a 30 s dos 230 s do job eram desse tipo.

## 12. Histórico

| Versão | Mudança |
| --- | --- |
| 14.20 | anúncio dos dois eixos (`pet_layout` e `coupling_mode`) na linha de layout |
| 14.21 | componente de gelo: terceiro bloco de PETs, tabela, divisão entre três componentes |
| 14.22 | tempo parado de cada componente em vez da razão entre o mais lento e o mais rápido (que, com o gelo presente, dava números sem significado, como "5470,8% de tempo ocioso"); avaliação das contagens pelo tamanho dos blocos e ajuste prático; coluna "Run por PET"; detecção das grades; opções `--ocn-grid`, `--atm-cells`, `--min-block`, `--min-cells-per-pet`; campos novos no JSON (`<comp>_idle_frac`, `suggested_practical_<comp>_pet_count`) |

## 13. Documentos relacionados

`docs/ferramentas.md`, catálogo de todas as ferramentas.

`docs/uso-plan-layout.md`, para planejar a topologia antes de rodar. O `plan-layout.py` aceita `--ice K`, então a contagem de `ice_pet_count` sugerida aqui pode ser levada direto para lá.

`docs/uso-smoke-tests.md`, para verificar que a combinação escolhida chega ao primeiro passo sem travar, e para medir sobreposição real entre componentes.

`docs/uso-mede-taxa-repro.md`, para verificar a reprodutibilidade de uma configuração nova de PETs.

`docs/uso-linha-base.md`, para verificar que uma alteração de código não mudou o resultado numérico.
