# Análise do modo sequential+split com SIS2 dinâmico

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.
Setembro de 2026.

## 1. Objetivo e escopo

Este documento registra a análise do modo de execução `coupling_mode = 'sequential'` combinado com `pet_layout = 'split'` e `use_sis2_dynamic = .true.`, com os três componentes ativos: atmosfera (MPAS), oceano (MOM6) e gelo marinho (SIS2). A comparação é feita contra `coupling_mode = 'concurrent'` no mesmo layout e com os mesmos componentes.

A base analisada é o branch `develop` do repositório `GTA-DIMNT-CPTEC/MONAN-Coupler`. A análise é de código-fonte: os componentes não foram compilados nem executados durante este trabalho. Onde uma afirmação depende de execução, isso está dito no texto.

## 2. Como o driver NUOPC sincroniza a RunSequence

Todo o resto deste documento depende de um único mecanismo, que vale a pena enunciar antes.

O conjunto de PETs percorre a lista da RunSequence junto, linha por linha. Não há um coordenador distribuindo trabalho.

Ao chegar numa linha de componente (`MPAS`, `OCN`, `ICE`), cada PET verifica se pertence àquele componente. Se pertence, executa. Se não pertence, atravessa a linha sem fazer nada e segue para a linha seguinte. Uma linha de componente, portanto, não sincroniza ninguém.

O que sincroniza são as linhas de conector que envolvem o mediador. Um conector NUOPC executa na união dos PETs de origem e destino. Como o MED é registrado em todos os PETs (`medPetList = petCount` em `esm.F90::SetModelServices`), toda linha `MED -> X` ou `X -> MED` executa em 100% dos PETs e funciona como ponto de encontro obrigatório.

Consequência prática: a fronteira entre duas fases de uma RunSequence é sempre uma linha de conector do mediador, nunca uma linha de componente.

## 3. Sequências de execução comparadas

### 3.1 Sequencial com gelo

```
@dt_coupling
  OCN -> MED
  ICE -> MED
  MPAS -> MED
  MED
  MED -> MPAS
  MPAS
  MED -> OCN
  OCN
  MED -> ICE
  ICE
@
```

Fases, separadas pelos pontos de encontro: coleta e execução do mediador em todos os PETs; avanço do MPAS; avanço do MOM6; avanço do SIS2. Uma de cada vez.

### 3.2 Concorrente com gelo

```
@dt_coupling
  MED -> MPAS
  MED -> OCN
  MED -> ICE
  MPAS
  OCN
  ICE
  MPAS -> MED
  OCN -> MED
  ICE -> MED
  MED
@
```

As três entregas do mediador acontecem antes dos três avanços, e não há conector entre `MPAS`, `OCN` e `ICE`. Os três blocos de PET entram nos seus componentes assim que a última entrega libera, e avançam ao mesmo tempo.

## 4. Ocupação de PETs

Com a configuração corrente do `nuopc.input` (`atm_pet_count = 64`, `ocn_pet_count = 4`, `ice_pet_count = 4`, total de 72 PETs):

| fase | trabalhando | parados |
| - | - | - |
| coleta e `MED` | 72 | 0 |
| `MPAS` | 64 (PET 0 a 63) | 8 |
| `OCN` | 4 (PET 64 a 67) | 68 |
| `ICE` | 4 (PET 68 a 71) | 68 |

Tempo por passo no modo sequencial: soma das quatro fases. No modo concorrente: tempo do mediador mais o maior entre os três avanços.

O termo dominante do modo sequencial não é a serialização entre oceano e gelo, e sim o bloco de 8 PETs parado durante todo o avanço da atmosfera somado aos 64 PETs parados durante toda a fase oceânica. Esse termo é intrínseco ao modo e não tem correção possível sem transformá-lo em concorrente.

Esta é a razão pela qual o grupo 7 do `nuopc.input` já registrava que `sequential+split` existe para contornar restrição de decomposição do MOM6 ou de memória, e não para reduzir tempo de parede.

## 5. Achados

### 5.1 Carimbo de tempo adiantado nos diagnósticos (BUG-SEQ-STAMP-01)

Defeito confirmado por leitura de código. Corrigido.

O relógio do mediador marca `currTime = t` durante toda a execução do passo nos dois modos: o NUOPC só avança o relógio depois que o `Advance` retorna. O que muda entre os modos é o conteúdo que chega ao `importState`.

No modo concorrente o elemento `MED` é o último do passo. Os conectores que o alimentam já executaram depois dos avanços, portanto os campos importados descrevem o estado em `t + dt`. O rótulo correto é `nextTime`.

No modo sequencial o elemento `MED` é o quarto, antes dos três avanços. Os conectores que o alimentam executaram no início do passo, portanto os campos importados descrevem o estado em `t`, que é o que cada componente escreveu ao final do passo anterior. O rótulo correto é `currTime`.

Até esta correção, `MediatorAdvance` usava `nextTime` nos dois modos. Duas consequências no modo sequencial.

A primeira é que todo arquivo `mom6_import_YYYYMMDD_HHMMSS.nc` e `monan2_import_YYYYMMDD_HHMMSS.nc` saía com o nome e a variável de tempo adiantados em um `dt_coupling` em relação ao dado que continha. Comparar uma execução sequencial com uma concorrente mostrava as duas deslocadas de um passo, e as animações geradas a partir desses arquivos ficavam fora de fase.

A segunda é que o `exportState` era carimbado com `t + dt` e entregue a componentes cujo relógio marcava `t`. Isso não abortava a execução porque os três caps usam `CheckImport` tolerante, com janela de mais ou menos um `dt_coupling`, ou no-op. Passava sem sinal nenhum no log.

### 5.2 O smoke test não conseguia testar o gelo (BUG-SEQ-TEST-ICE-01)

Lacuna de cobertura. Corrigida.

O `tools/coupler/test-sequential-split.bash` só conhecia as opções `--atm` e `--ocn`. A função `gen_config` remove o grupo `&nuopc_petlayout` inteiro da `nuopc.input` base e reinjeta um grupo próprio, e esse grupo não continha `use_sis2_dynamic`. Valia então o padrão Fortran `.false.`.

O efeito é que uma `nuopc.input` com gelo ligado era testada sem gelo, e o veredito saía como PASSOU. É a mesma classe de problema que motivou a separação dos dois eixos na v14.20: configuração lida e descartada sem aviso.

A medição de sobreposição temporal também considerava apenas `MPAS` e `OCN`, ignorando o terceiro bloco.

O `tools/coupler/test-concurrent.bash` tem a mesma lacuna e não foi tratado aqui.

### 5.3 Reordenação de `MED -> ICE`: avaliada e descartada

Não é defeito. Registro de decisão.

Mover a linha `MED -> ICE` para junto de `MED -> OCN` deixaria `OCN` e `ICE` consecutivos, sem ponto de encontro entre eles, e os dois blocos avançariam ao mesmo tempo. O tempo por passo cairia da soma das quatro fases para o tempo do mediador mais o avanço da atmosfera mais o maior entre oceano e gelo.

O dado entregue seria idêntico. O mediador executa uma única vez por passo, na linha `MED`, e não executa de novo entre `OCN` e `ICE`. Além disso o SIS2 não importa nada diretamente do MOM6: as três entradas oceânicas do gelo, `So_t`, `So_u` e `So_v`, vêm do `exportState` do MED, conforme `import_names_ocn` em `sis_cap_MONAN.F90`.

A reordenação chegou a ser implementada e foi descartada por três motivos.

O ganho é limitado ao menor entre o avanço do oceano e o do gelo. Com o SIS2 na mesma grade do MOM6 e com o mesmo número de PETs, espera-se que o gelo consuma uma fração do tempo do oceano, de modo que o ganho seria pequeno. Ele também não toca no termo dominante identificado na seção 4.

O propósito declarado do modo, no grupo 7 do `nuopc.input`, não é desempenho. Otimizar tempo de parede num modo cuja razão de existir é contornar restrição de decomposição e de memória rende pouco.

A chave chama-se `sequential`. Fazer dois componentes avançarem ao mesmo tempo sem que nada na `nuopc.input` diga isso é o modo entregando comportamento que não foi pedido.

Se uma calibração mostrar tempo de gelo comparável ao de oceano, a reordenação volta à mesa, porém como chave explícita em `&nuopc_petlayout`, com o padrão na ordem atual, e não como comportamento implícito. O dado necessário para essa decisão sai dos `logs/PET*.esmApp.log` de qualquer execução de calibração.

### 5.4 Observação sobre a defasagem atribuída ao modo concorrente

Ponto para revisão de documentação, sem alteração de código nesta entrega.

O `mpas_cap_config.F90` e o grupo 7 do `nuopc.input` descrevem `concurrent` como tendo defasagem de um `dt_coupling` e `sequential` como não tendo defasagem alguma.

Percorrendo as duas RunSequences, em ambas os fluxos usados para avançar de `t` até `t + dt` são avaliados no estado em `t`. No modo concorrente o mediador executa ao final do passo, a partir dos estados em `t + dt`, e entrega esses fluxos no início do passo seguinte, que avança de `t + dt` em diante. É o mesmo esquema explícito do modo sequencial, com o cálculo deslocado para o outro extremo do passo.

A diferença prática entre os dois modos é ocupação de PET e tempo de parede, não defasagem dos campos trocados. O único ponto em que os dois de fato divergem é o passo inicial, tratado por `InitializeDataComplete` e pelas correções B-SEQINIT-01 e B-SEQINIT-02.

Convém revisar esses textos antes da próxima entrega de documentação, porque a justificativa escrita hoje leva a escolher `sequential` esperando ganho de acurácia que a implementação não oferece.

### 5.5 Resolução de dependência de dados na inicialização

Sem defeito. Registrado para referência.

No modo sequencial o laço de dependência de dados do driver precisa de duas passagens. Na primeira, `OCN -> MED` e `ICE -> MED` executam antes dos respectivos `InitializeDataComplete`, e os campos chegam ao mediador ainda não preenchidos. O gate de `So_t` no mediador fecha e pede nova iteração. Na segunda passagem os dois campos já estão escritos e o gate abre.

No modo concorrente a ordem é inversa e o gate abre na primeira passagem.

O gate verifica apenas `So_t`. `Si_ifrac_sis2` não é verificado, mas na prática chega preenchido na segunda passagem porque o elemento `ICE` fica ao final da sequência. Se a ordem da RunSequence sequencial vier a mudar, este ponto precisa ser reavaliado.

## 6. Modificações entregues

### 6.1 `src/driver/esm.F90`

Nenhuma mudança de comportamento na RunSequence. A ordem dos elementos permanece a mesma do branch `develop`.

Acrescentada, no ramo `pet_layout = 'split'` com `coupling_mode = 'sequential'`, uma linha de log que nomeia quantos PETs ficam parados em cada fase do passo. O objetivo é permitir interpretar o consumo de fila, medido em nós vezes walltime, sem precisar cronometrar as janelas de execução componente a componente.

Acrescentada, na variante sequencial com gelo, uma linha de log nomeando as fases do passo.

Documentado em `SetRunSequence` o mecanismo de sincronização descrito na seção 2 deste documento, e registrada a decisão da seção 5.3, para que a reordenação não seja reproposta sem dado novo.

### 6.2 `src/mediator/MED_cap.F90`

Versão 2.6. Corrige BUG-SEQ-STAMP-01.

Acrescentado `cfg_coupling_mode` à lista de uso de `mpas_cap_config_mod`.

Declaradas em `MediatorAdvance` as variáveis `stampTime` e `med_runs_before_advance`, atribuídas logo após o cálculo de `nextTime`. `stampTime` recebe `currTime` quando `coupling_mode` é `sequential` e `nextTime` caso contrário.

`nextTime` substituído por `stampTime` em três pontos: a chamada de `NUOPC_SetTimestamp` sobre os campos do `exportState` e as duas chamadas de `med_write_import_fields`, incluindo a do caminho de retorno antecipado para PETs sem DE local.

O valor de `cfg_coupling_mode` é idêntico em todos os PETs, porque `config_read` executa em todos, de modo que `stampTime` também é idêntico. Isso é necessário porque `med_write_import_fields` usa esse instante para compor o nome do arquivo e contém operações MPI coletivas.

O modo concorrente não muda: `stampTime` recebe `nextTime`, como antes.

### 6.3 `tools/coupler/test-sequential-split.bash`

Corrige BUG-SEQ-TEST-ICE-01.

Acrescentadas as opções `--ice K` e `--no-ice`. Quando nenhuma das duas é dada, `use_sis2_dynamic` e `ice_pet_count` são herdados da `nuopc.input` base, com a leitura ignorando comentários e maiúsculas.

Partição estendida a três blocos, com as mesmas regras de valor automático do `esm.F90`. Com o gelo desligado, `ICE` vale 0 e as contas recaem exatamente na divisão em dois blocos anterior.

`gen_config` passa a emitir `use_sis2_dynamic` e `ice_pet_count` no grupo reinjetado. Em `pet_layout = 'shared'` o gelo pode estar ligado, porém `ice_pet_count` sai como 0, porque `config_read` rejeita contagem com layout compartilhado.

Verificações novas em `analyze`: faixa de PET do terceiro bloco no log de particionamento, registro do componente ICE no driver, seleção da RunSequence sequencial com gelo e, quando o teste foi pedido sem gelo, ausência do componente.

Medição de sobreposição estendida aos três componentes. Os três pares, atmosfera com oceano, atmosfera com gelo e oceano com gelo, devem ter interseção praticamente nula em execução sequencial. Sobreposição em qualquer par indica que um ponto de encontro saiu do lugar na RunSequence.

## 7. Verificações realizadas

As seguintes verificações foram feitas neste trabalho.

Os seis blocos de RunSequence do `esm.F90` foram extraídos e todos os literais conferidos em exatamente 18 caracteres, largura exigida pelo `character(len=18)` do `NUOPC_FreeFormatCreate`.

Os formatos das novas mensagens de log foram compilados e executados em gfortran, em programa isolado, para conferir o pareamento entre descritores e lista de itens e o comprimento resultante contra os 160 caracteres de `msg`.

O balanceamento de blocos dos dois arquivos Fortran foi comparado com os originais. As diferenças correspondem exatamente às edições feitas.

O script de teste passou por `bash -n`. A lógica de partição em três blocos foi executada isoladamente contra oito combinações de entrada e conferida contra as regras do `esm.F90`, incluindo o caso que deve ser rejeitado.

## 8. Verificações pendentes

Os dois arquivos Fortran não foram compilados contra os stubs ESMF e NUOPC. Isso deve ser feito antes do merge, pela mesma disciplina que já pegou defeitos auto-introduzidos em entregas anteriores.

Antes de compilar em Jaci, lembrar que o MPAS continua sendo decomposto por `atm_pet_count`, e não por `-n`. Com a configuração corrente do `nuopc.input`, a partição METIS necessária é `.part.64` para uma execução com `-n 72`.

Para verificar BUG-SEQ-STAMP-01 em execução, rodar dois ou três passos e comparar o primeiro nome de arquivo em `diag_import/` com `start_date` e `dt_coupling`. Antes da correção o primeiro `mom6_import_*.nc` saía carimbado com `start_date` mais um `dt_coupling`. Depois da correção deve sair com `start_date`.

Conferir se `postproc_mom6_import.py` e os scripts de animação não dependem do deslocamento antigo em alguma comparação contra séries já geradas.

Ao congelar uma linha de base para comparar contra estas modificações, usar `tools/dev/cria-linha-base.bash`. Convém congelar em modo concorrente, e não sequencial: a correção BUG-SEQ-STAMP-01 muda os nomes dos arquivos de diagnóstico no modo sequencial, de modo que uma base sequencial anterior à correção acusaria arquivos faltando e sobrando, e não diferença de dados. O modo concorrente não é afetado e isola regressão de renomeação.

Para o smoke test, começar por `test-sequential-split.bash -n 72 --atm 64 --ocn 4 --ice 4 --dry-run`, que mostra o grupo `&nuopc_petlayout` injetado sem submeter nada, e só então repetir sem a opção.
