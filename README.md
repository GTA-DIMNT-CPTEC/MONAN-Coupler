# MONAN-Coupler

Sistema acoplado atmosfera, oceano e gelo marinho: **MONAN-A 2.0** (MPAS-A, malha Voronoi hexagonal) acoplado ao **MOM6 + SIS2** (grade tripolar) pelo framework **NUOPC/ESMF 8.9.1**. Um mediador próprio calcula os fluxos turbulentos ar-mar por fórmulas bulk NCAR (Large e Yeager, 2009).

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos. Máquina de referência: supercomputador Jaci (Cray XD 2000, PrgEnv-gnu). Licença GPLv3.

Componentes: MPAS-A 8.3.1 · MOM6 + SIS2 · ESMF/NUOPC 8.9.1. Branch de desenvolvimento: `develop`.


Para o estado atual da refatoração, as linhas de base e como validar uma alteração, veja [`docs/estado-do-projeto.md`](docs/estado-do-projeto.md).

## Arquitetura

Quatro componentes NUOPC orquestrados por um driver único sob um relógio ESMF global. O componente de gelo (ICE, cap do SIS2) é opcional e só é criado com `use_sis2_dynamic = .true.`.

```text
        esmApp.F90  (programa principal)
              |
        esm.F90  (driver NUOPC: relogio, PETs, componentes e conectores)
        |          |          |            |
      ATM        MED         OCN          ICE
   MONAN-A    bulk NCAR      MOM6         SIS2
    (MPAS)   (mediador)   (dinamico)   (opcional)
```

O mediador reside em todos os PETs, então os conectores de e para o mediador funcionam como barreiras de sincronização. A cada intervalo de acoplamento os componentes trocam campos pelo mediador: o oceano e o gelo enviam SST, correntes e fração de gelo; a atmosfera envia vento, temperatura, umidade, pressão, radiação e precipitação; o mediador calcula os fluxos e os devolve. O detalhamento das RunSequences está em [`docs/analise-sequential-split-sis2.md`](docs/analise-sequential-split-sis2.md).

## Início rápido

Os scripts de instalação vivem em repositório separado, [`Coupler-Install`](https://github.com/GTA-DIMNT-CPTEC/Coupler-Install), com um instalador único que baixa o sistema (clone recursivo, com os modelos como submódulos) e compila tudo:

```bash
git clone --branch develop https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash
```

Pré-requisito: ESMF 8.9.1 já instalado, localizado por `run/setenv-gnu.bash`.

Em cada sessão de trabalho, na raiz do sistema acoplado:

```bash
source run/setenv-gnu.bash     # define ESMFMKFILE, MPAS_DIR, MOM6_ROOT, etc.
make                           # (re)compila bin/esmApp
bash run/run_esmApp.jaci       # submete via PBS (Cray PALS)
```

## Configuração do acoplamento

O modo de execução é escolhido no grupo `&nuopc_petlayout` do `nuopc.input`:

| Chave | Valores | Função |
| --- | --- | --- |
| `coupling_mode` | `sequential`, `concurrent` | ordem temporal de execução dos componentes |
| `pet_layout` | `split`, `shared` | ocupação espacial de PETs (blocos próprios ou compartilhados) |
| `use_sis2_dynamic` | `.true.`, `.false.` | ativa o componente de gelo SIS2 |
| `atm_pet_count`, `ocn_pet_count`, `ice_pet_count` | inteiros | número de PETs por componente no `split` (0 = automático) |
| `seq_repro` | `.true.`, `.false.` | variante reprodutível do `sequential+split+SIS2` (ver abaixo) |

Modos de execução. O eixo espacial `split` dá a cada componente um bloco próprio de PETs, e o `shared` faz todos ocuparem todos os PETs. O eixo temporal `sequential` roda os componentes um após o outro, e o `concurrent` os avança ao mesmo tempo em blocos disjuntos. O `concurrent+split` é o modo de produção; o `sequential+split` serve de referência e de recuo. A combinação `concurrent+shared` é proibida e barrada na leitura da configuração.

A chave `seq_repro = .true.` só tem efeito com `coupling_mode = 'sequential'`, `use_sis2_dynamic = .true.` e `pet_layout = 'split'`. Ela faz a RunSequence sequencial emitir o mesmo fluxo de dados do concorrente, tornando as duas rodadas comparáveis, sem alterar o modo concorrente. Fora desse contexto é ignorada, com aviso. O default `.false.` preserva o sequencial recomendado.

A sequência de execução de cada passo (que componente avança e que conector roda, em que ordem) vem da tabela `RUN_SEQUENCES` (`src/driver/run_sequences.F90`): sete sequências escritas como texto, no formato do NUOPC, escolhidas por `coupling_mode`, `use_med_to_mpas`, `use_sis2_dynamic` e `seq_repro`. O nome da escolhida aparece no log (`RunSequence ...`). Para experimentar outra ordem sem recompilar, a chave `run_sequence_file` do `&nuopc_driver` dá um arquivo com a sequência sob o rótulo `runSeq::` (exemplo no `nuopc.input` da raiz); o período da linha `@` deve ser `dt_coupling`. Uma sequência de arquivo não é conferida pelo acoplador: serve a experimentos, não à produção, e a leitura da configuração o lembra com um aviso na saída padrão (`esmApp_run.log`).

Os componentes são escolhidos por quatro chaves: `use_datm`, `use_docn` e `use_med_to_mpas` (grupo `&nuopc_mode`) e `use_sis2_dynamic` (grupo `&nuopc_petlayout`). Os valores padrão formam a configuração de produção: MONAN-A, MOM6 e SIS2, com o contorno da atmosfera pelo mediador. A tabela `COUPLER_MODES`, em `src/shared/coupler_config.F90`, diz o que acontece com cada combinação, e é a mesma que o mapa de acoplamento consulta:

| Situação | Combinações | Efeito na leitura |
| --- | --- | --- |
| suportada | MONAN-A e MOM6 com o contorno pelo mediador, com ou sem o SIS2 | aceita |
| não validada | as que usam o DOCN ou o DATM | aceita, com aviso que diz o problema conhecido |
| recusada | MOM6 com `use_med_to_mpas = .false.`; SIS2 com o DOCN | erro fatal, com mensagem que diz o que mudar |

A lista completa, combinação por combinação, está na seção 1 de [`docs/acoplamento.md`](docs/acoplamento.md).

## Estrutura de diretórios

```text
MONAN-Coupler/
├── src/
│   ├── main/        esmApp.F90 (programa principal)
│   ├── driver/      esm.F90 (driver NUOPC, partição de PETs) e run_sequences.F90 (sequências de execução como texto)
│   ├── mediator/    MED_cap.F90 (pontos de entrada NUOPC) e módulos por assunto: med_init, med_flux, med_bulk_ncar, med_ocean, med_ice, med_export, med_exchange (trocas por fase), med_diag
│   ├── caps/        caps dos componentes: atmos (MPAS, com o adaptador mpas_adapter.F90), ocean (MOM6), ice (SIS2)
│   ├── regrid/      interpolação plugável (esmf, weights_file, mpassit, idw), lista em regrid_schemes.F90
│   ├── coupling/    mapa de acoplamento: malhas regulares (cpl_grids), dicionário de campos (cpl_fields: unidade, nome longo e nome CF, que os gravadores de diagnóstico consultam), trocas, exportações e rotas (cpl_map) e conferência no log (cpl_check)
│   └── shared/      configuração (coupler_config), utilitários (coupler_utils), registro (coupler_log), leitor dos dados oceânicos do DOCN e do MOM6 (ocn_data_reader), allreduce, tempo, diag_bitsum
├── models/          submódulos: atmos/MONAN-Model, ocean/MOM6-examples
├── run/             run_esmApp.jaci, setenv-gnu.bash, setenv-site.bash
├── tools/           apoio: coupler, postproc, animation, atmos, ocean, dev
├── docs/            documentação técnica
├── nuopc.input      configuração da rodada
├── Makefile         compilação de bin/esmApp
└── README.md
```

## Organização do código

A configuração de `nuopc.input` é lida uma única vez, em `esmApp.F90`, pelo módulo `coupler_config_mod` (`src/shared/coupler_config.F90`); os demais módulos consultam as variáveis `cfg_*`, que são somente leitura. Grupo de namelist ausente mantém os valores padrão; grupo com erro de sintaxe é erro fatal.

Convenções para código novo:

| Tema | Regra |
| --- | --- |
| Nomes | identificadores Fortran (variáveis, constantes, tipos, componentes, rotinas, módulos e os nomes dos arquivos que os contêm) em inglês dos EUA; comentários, mensagens de log e textos entre aspas continuam em português. Desde a fase 12; as trocas de nome de cada etapa estão em `tools/dev/nomes/`, e `tools/dev/renomeia-identificadores.py aplica` as leva a um ramo antigo |
| Erros ESMF | `if (ChkErr(rc, __LINE__, __FILE__)) return`, de `coupler_utils_mod` |
| Texto | `int_to_str`, `real_to_str` e `str_lower` de `coupler_utils_mod`; não criar cópias locais |
| Configuração | nova chave em `coupler_config.F90`, nas rotinas do seu grupo: a variável `cfg_*`, o campo no tipo do grupo (`<grupo>_group_t`), a leitura em `read_<grupo>_group`, a regra em `<grupo>_group_valid` (a que envolve mais de um grupo vai para `valid_config`) e a cópia em `publish_<grupo>_group`; um caso novo em `tests/config/compara-config.bash`, se a chave tiver regra ou aviso; não usar atributos NUOPC para repassar configuração |
| Componentes e conectores | modelo novo: uma chamada a `register_model` em `esm.F90` (posição, nome, rótulo no driver, `SetServices`, atributos) e o caso dele em `chosen_model`; posição nova: uma linha em `POSITIONS` (`src/driver/driver_layout.F90`), que dá a ordem de registro, o bloco próprio de PETs no layout split e quem recebe o resto da divisão automática; conectores pelo mapa (`add_connectors`); no cap, o anúncio dos campos por `cap_advertise` (`src/shared/cap_common.F90`), com a política de anúncio escolhida pelo nome (`ADVERTISE_DEFAULT`, `ADVERTISE_SHARED` ou `ADVERTISE_PROVIDES_GRID`, explicadas no cabeçalho do módulo) |
| Comentários | explicar o que o código faz hoje e por quê, em português com acentos; sem citar etapas da refatoração, investigações ou versões (o histórico vai para `docs/CHANGELOG.md` e o `git log`; scripts de `tools/`: `docs/historico-scripts.md`); sem molduras (`!====`, `!----`); cabeçalho de módulo e de rotina no modelo Doxygen descrito abaixo |
| Novo fonte | criá-lo num diretório de `SRC_SUBDIRS` (todo `.F90` desses diretórios é compilado) e gerar de novo as dependências (`tools/dev/dependencias.py gera`, que reescreve `src/dependencies.mk` a partir dos `use`); com real de 8 bytes do MOM6, incluí-lo também em `MOM6_SRCS` |
| Camadas | um fonte só usa módulos do seu diretório ou das camadas de baixo, nesta ordem: `src/shared` (base e serviços comuns), `src/regrid` (interpolação), `src/coupling` (descrição do acoplamento), componentes (`src/mediator` e `src/caps`), `src/driver` e `src/main`; um componente não usa módulo de outro (o cap do MOM6 e o DOCN são componentes diferentes, embora no mesmo diretório), e o que dois componentes usam vai para `src/shared`; `src/regrid` e `src/coupling` não leem as variáveis `cfg_*` de `coupler_config`: a configuração chega por argumento (no mapa, um `cpl_config_t`; a da rodada é `cpl_current_config`). A conferência `camadas` (`tools/dev/confere-camadas.py`) acusa o que foge disso; um diretório novo ganha uma linha na tabela `CAMADAS` do script |
| Interpolação | sempre por uma rota do `regrid_manager_t` (ver [`docs/interpolacao-plugavel.md`](docs/interpolacao-plugavel.md)); não chamar `ESMF_FieldRegridStore` diretamente. No mediador, a rota é criada por `create_route` (`med_cap_methods`), com a configuração da sua linha em `ROUTES` (`src/coupling/cpl_map.F90`); rota nova ganha uma linha na tabela. Esquema novo: um arquivo em `src/regrid/`, a partir do modelo `regrid_idw.F90` (base de pesos), e uma linha em `regrid_schemes.F90`; opções do esquema em texto, na coluna `options` de `ROUTES` ou, sem recompilar, em `regrid_options` no `&nuopc_regrid` |
| Campos trocados | todo campo novo ganha uma linha em `FIELDS` (`src/coupling/cpl_fields.F90`) e o nome no grupo de campos (`GROUP_*`) de cada caminho que segue em `EXCHANGES` (`src/coupling/cpl_map.F90`), ou uma passagem nova; desde a R-FASE11-25, só os nomes de `FIELDS` estão no dicionário do NUOPC, e a conferência do mapa interrompe a rodada em caso de diferença (lacunas conhecidas ficam em `GAPS`); campo que um modelo exporta, a linha em `EXPORTS`, na ordem do anúncio; rota nova ou alterada, a linha em `ROUTES`; depois, `tools/dev/mapa-acoplamento.py` para atualizar [`docs/acoplamento.md`](docs/acoplamento.md). Na rodada, as linhas `CPL-REL: DIFERENCA` do log do PET 0 apontam o que não confere entre o mapa e os campos anunciados |
| Malhas | grade latitude e longitude criada por `cpl_latlon_grid` grade tripolar do supergrid do MOM6 por `cpl_tripolar_grid` e grade do cap do MOM6 nos blocos do modelo por `cpl_block_grid` (`src/coupling/cpl_grids.F90`), com a decomposição de `cpl_regdecomp` ou os blocos do modelo (`cpl_blocks_t`); fórmula de centro, canto ou índice nova vira função em `cpl_grids`, uma por regra de arredondamento |
| Mensagens de log | pelo `coupler_log_mod` (`src/shared/coupler_log.F90`): `log_error`, `log_warning`, `log_info` ou `log_debug`, com a marca do componente (`COMP_ATM`, `COMP_OCN`, `COMP_ICE`, `COMP_DATM`, `COMP_DOCN`, `COMP_MED`, `COMP_DRV` e, para a interpolação, `COMP_REGRID`); `write(*)` só antes de o registro do ESMF existir (leitura do `nuopc.input`) e nas linhas do `esmApp` que as ferramentas leem; erro que para a rodada por `log_error`, que grava também na saída padrão (uma vez, quando a condição vale em todos os PETs); aviso para falha contornada ou valor suspeito, informação para o que acontece uma vez por rodada (ou marca o andamento do passo), depuração para o detalhe de cada passo; diagnóstico permanente numa rotina do módulo de diagnósticos do componente (`med_diag` no mediador), com texto `DIAG <grandeza> <ponto>`, chamado por uma linha protegida por `if (log_debug_enabled())`; relatório de acoplamento por `log_report` (linhas `CPL-REL:`); mudança de texto de uma mensagem ganha uma regra em `tests/log-traduzido.sed` |
| Construção `BLOCK` | não usar: uma etapa completa vira procedimento com nome; variáveis temporárias são declaradas no início do procedimento |
| Constantes físicas e da grade | em `src/shared/coupler_constants.F90`; não redeclarar localmente |
| Etapas de uma rotina longa | procedimento de módulo com argumentos explícitos e `intent` declarado, em vez de procedimento interno (`contains` dentro da rotina), que enxerga todas as variáveis da rotina hospedeira |

Modelo dos cabeçalhos (Doxygen). O módulo começa por `!> @file nome.F90`, `!! @brief` com uma linha e, depois de uma linha `!!` vazia, o que o módulo faz, em texto corrido ou tabela. Cada rotina de módulo tem, logo antes da declaração:

```fortran
  !> @brief O que a rotina faz, numa linha.
  !!
  !! Detalhes, quando ajudam: por que é assim, a ordem das etapas, o que
  !! acontece quando um campo falta.
  !! @param[in]    nome  descrição
  !! @param[inout] rc    código de retorno
  subroutine nome(...)
```

As rotinas internas (`contains` dentro de outra rotina) e as funções curtas podem ter só a linha `!>`. O nome depois de `@param` é o do argumento, como está na declaração da rotina. A conferência `cabecalhos` (`tools/dev/confere-cabecalhos.py`) confere as duas regras.

O andamento da modernização do código está em [`docs/refatoracao-fase1.md`](docs/refatoracao-fase1.md).

## Compilação

O `Makefile` monta apenas o acoplador (`bin/esmApp`), assumindo os componentes já compilados pela instalação. Alvos úteis:

```bash
make            # compila bin/esmApp
make check      # verifica se todos os fontes existem
make test       # testes do framework de interpolação (requer ESMFMKFILE)
make clean      # remove build/ e bin/; distclean remove também lib/ e mod/
make help       # lista os alvos
```

Fora da Jaci, sem as bibliotecas dos modelos, `tools/dev/compila-local.bash` compila os fontes do acoplador contra um ESMF local e as interfaces mínimas de `tests/interfaces/`. Com `confere-literais.py`, `confere-instrucoes.py` e os testes de regressão de `tests/`, forma o conjunto de conferências feitas antes de levar uma mudança à Jaci; `tools/dev/confere-tudo.bash` executa todas de uma vez e mostra os indicadores de código limpo (`tools/dev/indicadores.py`). Ver [`docs/conferencias-locais.md`](docs/conferencias-locais.md).

O código do acoplador é compilado sem fusão de multiplicação e soma (`-ffp-contract=off`, variável `FP_CONTRACT` do Makefile). Com a fusão ligada, o compilador escolhe onde usar a instrução FMA conforme a organização do código, e uma refatoração que não muda nenhum cálculo altera o último bit do resultado. O custo medido foi nulo (rodada de 1 dia com 152 PETs: 142,5 s sem FMA, 144,4 s com). Para ligar a fusão, `make FP_CONTRACT=fast`; isso exige uma linha de base própria.

## Saídas e pós-processamento

Com o diagnóstico ativo, a rodada grava campos exportados em `diag_export/` e campos importados em `diag_import/` (`monan2_import_*.nc` no lado atmosférico e `mom6_import_*.nc` no lado oceânico), além dos logs do ESMF em `logs/`. Os scripts em `tools/` apoiam a análise: `tools/postproc/` para pós-processamento dos NetCDF, `tools/animation/` para animações, `tools/coupler/` para balanceamento de PETs, testes de modo e baterias de reprodutibilidade binária, `tools/atmos/` para as partições METIS e o teste do MPAS autônomo, `tools/ocean/` para a divisão de domínio do MOM6, e `tools/dev/` para linhas de base de comparação e o ambiente do `nccmp`. O catálogo completo, com a pergunta que cada ferramenta responde, está em [`docs/ferramentas.md`](docs/ferramentas.md).

A chave `log_level` do `&nuopc_driver` escolhe quais mensagens do acoplador vão para os logs do ESMF:

| `log_level` | O que é gravado |
| --- | --- |
| `'warning'` | só os avisos |
| `'info'` (padrão) | avisos e mensagens de andamento |
| `'debug'` | tudo, inclusive os diagnósticos do mediador (linhas `DIAG`, somas de bits do `Si_ifrac`) que o `mede-taxa-repro.sh` lê |

A antiga chave `write_fixdiag` é obsoleta: é aceita, não tem efeito e gera um aviso na leitura.

## Reprodutibilidade binária

Desde 22/09/2026, o acoplador é reprodutível bit a bit: execuções idênticas, na mesma configuração de PETs, produzem o mesmo resultado nos modos sequencial e concorrente, com o SIS2 dinâmico e com o módulo de icebergs ligado (na configuração atual não há icebergs na simulação, então o código de icebergs em si ainda não foi exercitado). A causa da não reprodutibilidade anterior estava na ordem das somas dos remapeamentos do ESMF, e a correção fixa as duas camadas dessa ordem em todos os remapeamentos e ligações entre componentes (`B-SRCTERM-01`, `B-METHODS-TERMORDER-01`). A regra vale para qualquer remapeamento novo: ver [`docs/ferramentas.md`](docs/ferramentas.md), seção 6. A reprodutibilidade de uma configuração se verifica com o [`mede-taxa-repro.sh`](docs/uso-mede-taxa-repro.md).

Para validar uma alteração de código que não deve mudar resultados, compare uma rodada com a linha de base de referência, hoje a **R-NOFMA-02** (código da tag `fase3-03-validada` compilado com `-ffp-contract=off`, 152 PETs, rodada de 1 dia). O roteiro completo está em [`docs/validacao-refatoracao.md`](docs/validacao-refatoracao.md); os cuidados principais são:

| Cuidado | Motivo |
| --- | --- |
| Um diretório novo para cada rodada | saídas antigas misturadas às novas já produziram um FAIL sem causa no código |
| `nuopc.input` copiado de `baseline/<rótulo>/config/` | o mesmo arquivo nas duas rodadas |
| `-n` igual à soma das contagens de PET, também no `--check` | o `--check` sem `-n` assume 4 processos |
| Executável alternativo por `ESMAPP_BIN` | o cabeçalho do log registra caminho e data do executável usado |
| `compara-linha-base.bash -e` | confere também as entradas pela soma registrada na linha de base |
| Anotações no MANIFEST de uma base congelada só com `anota-linha-base.bash` | editado à mão, o MANIFEST deixa de conferir com o `SHA256SUMS` e a comparação para antes de começar |

## Documentação

A pasta [`docs/`](docs/) reúne a documentação técnica, entre ela a análise das RunSequences sequencial e concorrente, a integração do componente de gelo, a execução multi-nó e o CHANGELOG do projeto.

Guias de uso das ferramentas:

| Guia | Ferramentas |
| --- | --- |
| [`ferramentas.md`](docs/ferramentas.md) | catálogo de todas as ferramentas, com sequências típicas de uso |
| [`MULTINO-run_esmApp.md`](docs/MULTINO-run_esmApp.md) | `run_esmApp.jaci` |
| [`uso-plan-layout.md`](docs/uso-plan-layout.md) | `plan-layout.py` |
| [`uso-gen-metis.md`](docs/uso-gen-metis.md) | `gen-metis.bash` |
| [`domain-mom6.md`](docs/domain-mom6.md) | `domain-mom6.bash` |
| [`uso-analisa-balanceamento.md`](docs/uso-analisa-balanceamento.md) | `analisa_balanceamento_pets.py` |
| [`uso-mede-smt.md`](docs/uso-mede-smt.md) | `mede_smt.py` |
| [`uso-smoke-tests.md`](docs/uso-smoke-tests.md) | `test-concurrent.bash`, `test-sequential-split.bash` |
| [`uso-mede-taxa-repro.md`](docs/uso-mede-taxa-repro.md) | `mede-taxa-repro.sh` |
| [`uso-duplas-rodadas-repro.md`](docs/uso-duplas-rodadas-repro.md) | `roda-repro-reprodiag.sh`, `roda_repro_producao.sh`, `roda_repro_datm_mom6.sh`, `roda-repro-mpas-standalone.sh`, `set-nccmp-jaci.bash` |
| [`uso-linha-base.md`](docs/uso-linha-base.md) | `cria-linha-base.bash`, `compara-linha-base.bash`, `anota-linha-base.bash` |
| [`validacao-refatoracao.md`](docs/validacao-refatoracao.md) | `valida_rodada.bash` |
| [`conferencias-locais.md`](docs/conferencias-locais.md) | `confere-tudo.bash`, `indicadores.py`, `compila-local.bash`, `confere-literais.py`, `confere-instrucoes.py`, `tests/writers/compara-gravadores.bash`, `tests/bulk/compara-bulk.bash`, `tests/atmgrid/compara-grade-atm.bash`, `tests/unit/roda-unitarios.bash`, `tests/supergrid/compara-supergrid.bash`, `tests/docn/compara-docn.bash`, `mapa-acoplamento.py`, `confere-curto-circuito.py`, `confere-exportacao.py`, `dependencias.py`, `confere-camadas.py`, `confere-cabecalhos.py`, `tests/config/compara-config.bash`, `tests/cplcheck/confere-cplcheck.bash` |
| [`historico-scripts.md`](docs/historico-scripts.md) | histórico das versões dos scripts Python de `tools/` |
| [`roteiro-codigo-limpo.md`](docs/roteiro-codigo-limpo.md) | roteiro das fases 6 a 11 (código limpo), com indicadores e metas |
| [`arquitetura-acoplamento.md`](docs/arquitetura-acoplamento.md) | arquitetura de acoplamento: as peças e como incluir um campo, um componente ou um esquema de interpolação |
| [`historico/`](docs/historico) | versões completas do CHANGELOG, do estado do projeto, das conferências locais e do plano da fase 11, até a fase 12 |
| [`acoplamento.md`](docs/acoplamento.md) | mapa de acoplamento em tabelas (campos, trocas por conector e por configuração, exportações dos modelos, rotas do mediador), gerado por `tools/dev/mapa-acoplamento.py` |
| [`conformidade-dtn01.md`](docs/conformidade-dtn01.md) | levantamento de conformidade com o padrão de codificação DTN-01 |

## Créditos

Desenvolvido pelo Grupo de Trabalho para Acoplamento de Modelos (INPE/CGCT/DIMNT). Distribuído sob a licença GNU GPL v3 (ver [`LICENSE`](LICENSE)).
