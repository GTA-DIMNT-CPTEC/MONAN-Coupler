# Duplas rodadas de reprodutibilidade: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso dos scripts que executam o sistema duas vezes e comparam as saídas:

| Script | Pergunta que responde |
| --- | --- |
| `tools/coupler/roda-repro-reprodiag.sh` | em qual passo de tempo o estado do MPAS começa a divergir? |
| `tools/coupler/roda_repro_producao.sh` | o caso de produção reproduz, em todas as saídas? |
| `tools/coupler/roda_repro_datm_mom6.sh` | sem o MPAS (atmosfera de dados), oceano e gelo reproduzem? |
| `tools/atmos/roda-repro-mpas-standalone.sh` | o MPAS, sozinho, fora do acoplador, reproduz? |

E do utilitário que todos usam, `tools/dev/set-nccmp-jaci.bash`.

## 1. Dupla rodada ou bateria?

Os quatro scripts executam **duas** vezes (A e B). Isso é rápido e responde bem a perguntas de localização, mas tem um limite importante: quando a não reprodutibilidade é **intermitente**, duas execuções podem coincidir por acaso. Foi o que aconteceu em 16/09/2026: duas duplas rodadas na mesma configuração deram resultados opostos.

| Situação | Ferramenta |
| --- | --- |
| confirmar que uma configuração é reprodutível | `mede-taxa-repro.sh` (bateria de 4 ou 8 execuções, todos os pares) |
| saber se uma configuração **não** é reprodutível | uma dupla rodada basta, se divergir: diferença é prova |
| localizar onde ou quando a divergência nasce | as duplas rodadas abaixo, conforme a pergunta |
| verificar que uma alteração de código não mudou o resultado | `cria-linha-base.bash` e `compara-linha-base.bash` |

A leitura é **assimétrica**: "DIFERE" é conclusivo; "IDÊNTICO" em uma dupla rodada é indício, não prova.

## 2. `set-nccmp-jaci.bash`

Todas as comparações usam `nccmp -d`, que compara os **dados** de dois NetCDF e ignora o cabeçalho (onde o carimbo de data de criação faria um `cmp` acusar diferença sempre). Na jaci, o `nccmp` vem de um módulo. O utilitário carrega o ambiente necessário:

```bash
source $COUPLER_ROOT/tools/dev/set-nccmp-jaci.bash
```

Ele faz `module purge` e carrega `libfabric`, `cray-netcdf-hdf5parallel`, `cray-hdf5-parallel` e `nccmp`. Duas consequências:

- O `module purge` descarta os módulos já carregados na sessão, inclusive o do Python: depois dele, o `python3` volta a ser o do sistema operacional, anterior ao 3.7, e ferramentas como o `analisa_balanceamento_pets.py` param com `SyntaxError: future feature annotations is not defined`. Use-o num terminal dedicado às comparações, rode as ferramentas em Python antes dele, ou recarregue os módulos necessários depois (`module load cray-python`, ou o módulo de Python que você usa).
- Precisa ser feito com `source`, não com `bash`: executado como script, os módulos seriam carregados num processo filho e sumiriam ao fim dele.

Os scripts de reprodutibilidade conferem se o `nccmp` está disponível e, alguns, chamam este utilitário sozinhos.

**Código de saída do `nccmp`:** 0 para idêntico, 1 para diferente. Qualquer outro valor significa que ele não rodou (127, se não foi encontrado). Numa comparação com a saída redirecionada para `/dev/null`, conferir o código é a única forma de distinguir "idêntico" de "não rodou".

## 3. `roda-repro-reprodiag.sh`

### 3.1 Para que serve

Executa o acoplado duas vezes, na configuração **atual** (não altera `nuopc.input` nem `streams.atmosphere`), preserva o `reprodiag.nc` de cada execução e informa o **primeiro registro** que difere. Como o stream `reprodiag` grava a cada 10 minutos simulados, a resposta tem resolução de passo de tempo, e não de hora de acoplamento como os diagnósticos `diag_export/` e `diag_import/`.

### 3.2 Como ler

| Primeiro registro divergente | Leitura |
| --- | --- |
| 1 | o estado já difere no registro de t = 0, antes de qualquer integração: a semente entra pela inicialização ou pela injeção dos campos do acoplador |
| maior que 1 | há alguns passos determinísticos antes da separação; o número de passos indica quanta física roda antes de a diferença aparecer |
| nenhum | o estado do MPAS reproduz; se outros diagnósticos divergirem, a diferença vem da escrita ou do pós-processamento, não da integração. Resultado surpreendente: verificar antes de acreditar |

### 3.3 Uso

```bash
cd <diretorio_do_experimento>
bash $COUPLER_ROOT/tools/coupler/roda-repro-reprodiag.sh --npes 72 \
     --runner $COUPLER_ROOT/run/run_esmApp.jaci
```

| Opção | Padrão | Significado |
| --- | --- | --- |
| `--npes N` | 72 | PETs |
| `--walltime T` | 01:00:00 | tempo pedido por execução |
| `--runner CAMINHO` | caminho absoluto de uma instalação específica | script de submissão |
| `--var NOME` | `surface_pressure` | variável comparada |

**Atenção ao `--runner`:** o padrão atual aponta para um caminho absoluto de uma instalação pessoal na jaci. Em outra instalação, informe sempre `--runner $COUPLER_ROOT/run/run_esmApp.jaci`. O pré-requisito é o mesmo do `mede-taxa-repro.sh`: o bloco do stream `reprodiag` no `streams.atmosphere` (ver `docs/uso-mede-taxa-repro.md`, seção 2.1).

## 4. `roda_repro_producao.sh`

### 4.1 Para que serve

Revalida a reprodutibilidade do **caso de produção** (MPAS, MOM6 e SIS2, concorrente com split, 72 PETs) em todas as saídas: os NetCDF de `diag_export/` e `diag_import/`, os NetCDF da raiz e os balanços `ocean.stats` e `seaice.stats`.

É um orquestrador fino, que reaproveita a maquinaria de linha de base em vez de reimplementar a comparação:

| Etapa | O que faz |
| --- | --- |
| 1 | confere que o `nuopc.input` ativo é o de produção (e não uma variante de teste) |
| 2 | garante o `nccmp` no `PATH`, chamando o `set-nccmp-jaci.bash` se preciso |
| 3 | limpa as saídas, executa A, congela A com `cria-linha-base.bash` (rótulo `reproA-<data-hora>`) e guarda os `.stats` de A em `repro-stats-<rotulo>/` |
| 4 | limpa as saídas e executa B |
| 5 | compara B contra a base A com `compara-linha-base.bash` e faz o `diff` exato dos `.stats` |
| 6 | veredito combinado: `REPRODUTIVEL` ou `NAO REPRODUTIVEL`, com o número de camadas que acusaram diferença |

A execução B só começa depois de A terminar de verdade, porque o `run_esmApp.jaci` chamado do nó de login faz o `qsub` e espera o `qstat`.

### 4.2 Uso

```bash
cd <diretorio_do_experimento>
bash $COUPLER_ROOT/tools/coupler/roda_repro_producao.sh
```

O número de PETs (72) e o tempo pedido estão no topo do script. O comando de submissão pode ser trocado exportando `RUN_CMD`. A limpeza antes de cada execução remove `diag_import/`, `diag_export/`, `logs/`, `RESTART/`, os `MONAN_DIAG_*.nc`, os `log.atmosphere.*` e o `.pbs` gerado; as entradas do experimento são preservadas por uma foto do estado inicial do diretório.

A linha de base da execução A fica guardada (`baseline/reproA-<data-hora>`) e pode servir de referência depois.

## 5. `roda_repro_datm_mom6.sh`

### 5.1 Para que serve

Separa duas hipóteses trocando o MPAS por uma atmosfera de dados (DATM), com o oceano, o gelo e o mediador inalterados:

| Resultado | Leitura |
| --- | --- |
| DATM + MOM6 + SIS2 reproduz | a origem da não reprodutibilidade está no MPAS (ou nos caminhos que só ele exercita) |
| ainda diverge | a origem está no oceano, no gelo, no FMS ou nos remapeamentos do mediador |

### 5.2 Como funciona e uso

O script confere que o `nuopc.input` atual é o de produção, gera `nuopc.input.datm_mom6` trocando só `use_datm` para `.true.`, instala essa variante, roda o `roda_repro_producao.sh` com um rótulo próprio (`datm-reproA-...`) e **restaura o `nuopc.input` de produção no fim**, mesmo que algo falhe.

```bash
cd <diretorio_do_experimento>
bash $COUPLER_ROOT/tools/coupler/roda_repro_datm_mom6.sh
```

A atmosfera de dados é o forçamento sintético do acoplador. Se a instalação exigir um arquivo de dados ou um grupo `&nuopc_datm` que não esteja presente, a execução reclama no log.

## 6. `roda-repro-mpas-standalone.sh`

### 6.1 Para que serve

Executa duas vezes o MPAS-A **autônomo**, fora do acoplador, e compara os `MONAN_DIAG_*.nc` bit a bit. Tira o acoplador inteiro do circuito.

| Veredito | Leitura |
| --- | --- |
| DIFERE | conclusivo: o MPAS-A não é determinístico sozinho, e o acoplamento não tem parte nisso |
| IDÊNTICO | indício, não prova: o binário autônomo é compilado sem `-DCOUPLER` e não exercita os caminhos de código do acoplamento |

Em setembro de 2026, o MPAS autônomo reproduziu em 9 de 9 execuções de 24 horas, o que ajudou a descartar o próprio MPAS como origem e a concentrar a investigação no acoplador.

### 6.2 Uso

```bash
cd <diretorio_do_experimento>
bash $COUPLER_ROOT/tools/atmos/roda-repro-mpas-standalone.sh --npes 64 --duration 1_00:00:00
```

| Opção | Padrão | Significado |
| --- | --- | --- |
| `--exe CAMINHO` | procurado na árvore | o `atmosphere_model` a usar |
| `--npes N` | 64 | PETs; exige o arquivo `x1.*.graph.info.part.N` |
| `--walltime T` | 01:00:00 | tempo pedido por execução |
| `--queue NOME` | `pesqextra` | fila |
| `--duration D` | o do namelist | reescreve `config_run_duration` **nas cópias** (por exemplo, `1_00:00:00`) |

As duas execuções rodam em `repro-standalone/A` e `repro-standalone/B` (o nome pode ser trocado exportando `WORKDIR`). As entradas grandes são ligadas por link simbólico; `namelist.atmosphere`, `streams.atmosphere` e as listas de streams são copiadas, para ficarem congeladas. Se `repro-standalone/` já existir, o script para, para não misturar execuções.

O script recusa binários inadequados: em precisão simples (incompatível com as tabelas `.DBL`) ou compilados para o acoplador. A partição METIS para o número de PETs pedido pode ser gerada com o `gen-metis.bash` (`docs/uso-gen-metis.md`).

## 7. Documentos relacionados

`docs/uso-mede-taxa-repro.md`, para baterias com N execuções e as seções de diagnóstico.

`docs/uso-linha-base.md`, para o `cria-linha-base.bash` e o `compara-linha-base.bash`, que o `roda_repro_producao.sh` usa.

`docs/ferramentas.md`, catálogo de todas as ferramentas.
