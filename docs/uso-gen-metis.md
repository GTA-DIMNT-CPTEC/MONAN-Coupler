# gen-metis.bash: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/atmos/gen-metis.bash`.

## 1. Para que serve

O MPAS divide a malha entre os processadores lendo um arquivo de partição gerado pelo METIS, `x1.<N>.graph.info.part.<P>`, em que `<P>` é o número de tarefas MPI **no comunicador do MPAS**, e não o total do job. Sem o arquivo certo, o MPAS não inicia.

O script gera as partições necessárias para uma execução, lendo a malha e o modo de acoplamento do `nuopc.input`:

| Configuração | Partição que o MPAS usa |
| --- | --- |
| `pet_layout = 'shared'` (todos os PETs no MPAS) | `.part.<NPES>`, o total do job |
| `pet_layout = 'split'` (MPAS num subconjunto) | `.part.<atm_pet_count>` |

O oceano não usa METIS: o MOM6 e o SIS2 dividem a própria grade lógica pelo `LAYOUT`.

Com `split`, o script gera as duas partições (`.part.<NPES>` e `.part.<atm_pet_count>`). A primeira existia para satisfazer uma conferência antiga do `run_esmApp.jaci`, que pedia a partição do total; as versões recentes já conferem a partição de `atm_pet_count` (a verificação de pré-requisitos informa "partição METIS dimensionada por atm_pet_count"). Gerar as duas não faz mal.

## 2. Uso

No diretório do experimento, onde estão o `x1.<N>.graph.info` e o `nuopc.input`:

```bash
bash $COUPLER_ROOT/tools/atmos/gen-metis.bash -n 144 --dry-run     # mostra o que geraria
bash $COUPLER_ROOT/tools/atmos/gen-metis.bash -n 144               # gera o que falta
bash $COUPLER_ROOT/tools/atmos/gen-metis.bash --parts "64 128 256" # gera exatamente estas
```

| Opção | Significado |
| --- | --- |
| `-n`, `--np N` | total de PETs do job; com `pet_layout = 'shared'`, é a partição usada |
| `--parts "L"` | lista explícita de partições, que substitui a dedução pelo `nuopc.input` |
| `--input ARQ` | `nuopc.input` a ler (padrão `./nuopc.input`) |
| `--mesh x1.N` | malha; o grafo usado passa a ser `x1.N.graph.info` |
| `--graph ARQ` | arquivo de grafo explícito |
| `--force` | regera mesmo se a partição já existir |
| `--dry-run` | só mostra o que seria gerado |
| `-h`, `--help` | ajuda |

**Detecção do grafo.** Sem `--mesh` nem `--graph`, o script usa o único `x1.*.graph.info` do diretório. Se houver mais de um, pede que você escolha. Se não houver nenhum, tenta deduzir o nome a partir do `x1.*.init.nc` e informa qual arquivo falta.

**O `gpmetis`.** Se não estiver no `PATH`, o script tenta `module load METIS/5.1.0`.

Partições com `P = 1` são puladas: uma tarefa única não precisa de partição. Com `atm_pet_count = 0` (automático), o script assume metade do total e avisa; nesse caso, confira com `--parts`.

## 3. Quando usar

Sempre que mudar o número de PETs da atmosfera, por exemplo ao seguir uma sugestão do `analisa_balanceamento_pets.py` ou ao planejar com o `plan-layout.py`. As partições já geradas ficam no diretório e são reaproveitadas.

A partição é uma **entrada** da execução: duas execuções com o mesmo arquivo de partição usam a mesma divisão da malha. Mudar a partição (outro número de PETs da atmosfera) muda o resultado numérico, porque as somas passam a ser feitas em outros pedaços; isso é esperado, e a configuração nova precisa de sua própria bateria de reprodutibilidade (`docs/uso-mede-taxa-repro.md`).

## 4. Documentos relacionados

`docs/uso-plan-layout.md` e `docs/uso-smoke-tests.md`, que citam a partição como pré-requisito.

`docs/uso-analisa-balanceamento.md`, para escolher o número de PETs da atmosfera a partir do tempo medido.

`docs/ferramentas.md`, catálogo de todas as ferramentas.
