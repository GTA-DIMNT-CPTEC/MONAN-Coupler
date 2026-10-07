# Arquitetura de acoplamento do MONAN-Coupler

Resumo da arquitetura atual, para quem vai usar ou estender o acoplador. A descrição completa da fase 11 (diagnóstico, plano, etapas e indicadores) está em [`historico/arquitetura-acoplamento-fase11.md`](historico/arquitetura-acoplamento-fase11.md); a nota técnica "A nova arquitetura do MONAN-Coupler" traz o mesmo conteúdo com figuras.

## 1. Antes e depois

Na versão original, a descrição do acoplamento estava espalhada: nomes de campos escritos à mão em oito arquivos, sete construções de malha em seis arquivos, rotas de interpolação criadas em lugares diferentes (uma delas dentro da física) e o carimbo de tempo dos campos feito por cinco arquivos. Hoje ela está num lugar só, `src/coupling`, escrita como tabelas que os componentes, o driver e o mediador consultam, e uma conferência compara as tabelas com o que os componentes anunciam.

| Tarefa | Antes | Agora |
| --- | --- | --- |
| incluir um campo | editar as listas do componente de origem, do mediador e do destino | uma linha em `FIELDS` e o nome no grupo de cada caminho em `EXCHANGES` |
| saber por onde um campo passa | ler os caps, o mediador e o driver | ler o mapa ou `docs/acoplamento.md` |
| trocar o método de um conector | não havia escolha explícita | coluna `method` da troca |
| mudar uma rota do mediador | editar a chamada no mediador | linha em `ROUTES`, ou `&nuopc_regrid` no `nuopc.input` |
| escrever um esquema de interpolação | implementar tudo com chamadas ao ESMF | uma rotina que calcula pesos, a partir de um modelo |
| descobrir um erro de acoplamento | durante a rodada, longe da causa | na inicialização, com a lista das diferenças |

Nenhum resultado mudou: cada etapa das fases 11 e 12 reproduziu bit a bit os 73 arquivos da linha de base R-NOFMA-02.

## 2. As peças

| Peça | Onde | O que faz |
| --- | --- | --- |
| dicionário de campos | `src/coupling/cpl_fields.F90` (`FIELDS`) | os 59 campos: nome, unidade, sinal, descrição; registrados no dicionário do NUOPC, sem acréscimo automático |
| mapa de acoplamento | `src/coupling/cpl_map.F90` | as tabelas `GRIDS`, `EXCHANGES`, `EXPORTS`, `ROUTES` e `GAPS` e as consultas sobre elas |
| catálogo de malhas | `src/coupling/cpl_grids.F90` | `cpl_latlon_grid`, `cpl_tripolar_grid`, `cpl_block_grid` e as fórmulas de índice e longitude |
| conferência e relatório | `src/coupling/cpl_check.F90` | compara o mapa com os estados e os conectores; escreve as linhas `CPL-REL:`; interrompe a rodada em caso de diferença |
| mediador por fases | `src/mediator/med_exchange.F90` | `initialize_data`, `go_to_flux_grid`, `compute_fluxes`, `ice_fraction_without_sis2`, `deliver`; todas as rotas são criadas aqui |
| interpolação | `src/regrid/` | `regridder_t`, rotas com nome (`regrid_manager_t`), base de pesos (`weights_regridder_t`), lista de esquemas (`regrid_schemes`) |
| adaptador do MPAS | `src/caps/atmos/mpas_adapter.F90` | o que é próprio do MPAS; o cap NUOPC (`mpas_cap_MONAN`) fica pequeno |

## 3. O mapa

Um **ponto** é um componente numa malha, `COMPONENTE@malha` (ex.: `OCN@ocn_mom6`). Uma **condição** diz em que configuração a linha vale (`mpas`, `datm`, `mom6`, `docn`, `med_to_mpas`, `ocn_to_mpas`, `sis2`, das chaves de `&nuopc_mode`); lista vazia vale sempre.

| Tabela | Uma linha para cada | Colunas |
| --- | --- | --- |
| `GRIDS` | malha citada no mapa | `name`, `component`, `grid_type`, `description` |
| `EXCHANGES` | passagem de um campo de um ponto a outro, escrita por grupo de campos (`GROUP_*`: uma passagem leva um grupo inteiro) ou, para um campo só, numa linha | `field`, `src`, `dst`, `via` (`'conector'`, `'cap'` ou nome de rota), `when`, `method` (só nos conectores) |
| `EXPORTS` | campo que um modelo exporta, na ordem do anúncio; escrita por grupos, como `EXCHANGES` | `field`, `point`, `when` |
| `ROUTES` | interpolação do mediador | `name`, `src`, `dst`, `methods`, `scheme`, `options`, `mask`, `fallback`, `no_value`, `fill`, `nan_to`, `create` |
| `GAPS` | lacuna conhecida, que não interrompe a rodada | `field`, `point`, `when`, `reason` |

Exemplo, o caminho da SST até a malha de fluxo. O MOM6 envia ao mediador o grupo `GROUP_OCN_STATE` (So_t, So_u e So_v) por conector, e a SST segue sozinha pela rota `ocn2atm_sst`:

```fortran
character(len=CPL_NAME_LEN), parameter :: GROUP_OCN_STATE(*) = [character(len=CPL_NAME_LEN) :: 'So_t', 'So_u', 'So_v']

(cpl_exchange_t(GROUP_OCN_STATE(i_group), 'OCN@ocn_mom6', 'MED@ocn_med', 'conector', 'mom6', 'bilinear'), &
  i_group = 1, size(GROUP_OCN_STATE)),                                                                    &
cpl_exchange_t('So_t', 'MED@ocn_med', 'MED@atm_med', 'ocn2atm_sst', '', ''),                               &
```

A passagem é um laço implícito que o compilador expande numa linha por campo do grupo, na ordem do grupo: `EXCHANGES` continua sendo uma tabela constante com uma linha por campo e passagem, e as consultas a percorrem assim. Um grupo pode incluir outro (`GROUP_OCN_EXPORT` começa por `GROUP_OCEAN_FLUXES`). A ordem das linhas expandidas define a ordem do anúncio dos campos; `tests/unit/test_cpl_map.F90` a confere contra uma cópia congelada das 151 linhas escritas uma a uma até a R-FASE13-22 (`tests/unit/exchanges_frozen.inc`).

Os componentes perguntam ao mapa: `cpl_arrivals(ponto, ...)` devolve a lista de importação e `cpl_exports(ponto, ...)` a de exportação, na ordem das tabelas e só com as linhas da configuração pedida, que chega como argumento (`cfg`, um `cpl_config_t`); o mapa não lê o `nuopc.input`, e quem chama passa a configuração da rodada (`cpl_current_config`, de `coupler_config`). O driver registra os conectores que têm troca válida (`cpl_driver_connectors`, entre os pares de `CONNECTOR_SRC`/`CONNECTOR_DST`) e escreve o método de cada campo na `CplList` (`cpl_write_methods`). `tools/dev/mapa-acoplamento.py` gera [`acoplamento.md`](acoplamento.md), a versão em tabelas por componente e por conector.

## 4. Como incluir um campo

1. Uma linha em `FIELDS` (sem ela, o anúncio do campo para a rodada).
2. Em `EXCHANGES`, o nome no grupo (`GROUP_*`) de cada caminho que o campo segue, na posição em que deve ser anunciado; um caminho novo é uma passagem nova (um grupo novo ou uma linha). A passagem por conector faz o destino anunciar o campo e o driver escrever o método; a passagem por rota registra o caminho para a conferência, e a chamada que aplica a rota fica numa fase do mediador. Mudar um grupo muda a tabela congelada do teste do mapa: atualizar `tests/unit/exchanges_frozen.inc` é uma decisão do GT, registrada no CHANGELOG.
3. Se o campo sai de um modelo, o nome no grupo de exportação do modelo em `EXPORTS` (`EXPORT_*` ou, para o DATM e o SIS2, o próprio grupo da passagem para o mediador, que tem a mesma ordem), na posição em que o cap o anuncia. O cap (ou o adaptador) preenche os valores. Mudar um grupo de exportação muda a tabela congelada do teste do mapa (`tests/unit/exports_frozen.inc`), como em `EXCHANGES`.
4. `tools/dev/mapa-acoplamento.py` e `tools/dev/confere-tudo.bash HEAD`. Na rodada, uma linha faltando ou sobrando aparece como `CPL-REL: DIFERENCA:` e interrompe a inicialização; uma diferença esperada vai para `GAPS`, com o motivo.

**Campo calculado no mediador** (exemplo: `So_duu10n`, enviado ao oceano). Além da linha em `FIELDS` e do nome no grupo da passagem do mediador ao destino (itens 1 e 2; a exportação do mediador sai do mapa, sem código):

| Lugar | O que fazer |
| --- | --- |
| `MED_FIELDS` (`med_cap_types`) | uma linha: nome de acoplamento, nome do campo ESMF, valor inicial e se é zerado no início de cada passo; `create_internal_fields` (`med_init`) cria o campo na malha de fluxo, `zero_med_fluxes` (`med_flux`) o zera se for o caso, e os gravadores o encontram pelo nome |
| constante `F_*` (`med_cap_types`) | a posição do campo na tabela (`integer, parameter :: F_DUU10N = 15`); `associate_fluxes` (`med_exchange`) dá à física o array de cada campo em `fluxes%p(k)%a`, sem código por campo |
| a física (`med_bulk_ncar` ou outro módulo de cálculo) | o cálculo, por `fluxes%p(F_DUU10N)%a` |

São 5 lugares em 4 arquivos, contando `FIELDS` e o mapa. O teste `tests/unit/test_med_fields.F90` confere cada constante `F_*` contra o nome do campo: incluir um campo inclui uma chamada a `check` ali. Os componentes nomeados do estado interno (`is%ocn_flx`, `is%ocn`, `is%ice`, `is%sfc`, ligados em `bind_internal_fields`) só são necessários quando o código fora da física (as fases de interpolação, a exportação explícita, os diagnósticos) precisa do `ESMF_Field` pelo nome.

## 5. Como incluir um componente

1. **Malha**: linha em `GRIDS`; o cap a constrói pelo catálogo (`cpl_grids`). Malha de tipo novo: função nova em `cpl_grids`.
2. **Campos e passagens**: `FIELDS`, `EXCHANGES`, `EXPORTS` (seção 4); rotas novas do mediador em `ROUTES`.
3. **Escolha e condições**: modelo novo numa posição existente (ATM, OCN, ICE) é uma linha em `COMPONENTS` (`coupler_config`: posição, nome, malha de `GRIDS`, rótulo no driver). O nome passa a ser aceito na chave da posição (`atm_model`, `ocn_model`, `ice_model`) e a ser uma condição da coluna `when`, sem código novo: `config_read`, `condition_holds` (mapa) e `mapa-acoplamento.py` leem a tabela. As combinações com o modelo novo (aceita, não validada ou recusada) entram em `COUPLER_MODES`, que o teste do mapa exige completa. Uma posição nova (ondas, por exemplo) pede mais: uma chave e um campo em `cpl_config_t`, `CONFIG_KEYS` e `MODEL_POSITIONS` (`coupler_config`), e os laços que percorrem as combinações (`applies_in_some`, no mapa, e `all_configs`, no teste).
4. **Cap**: a partir do cap modelo `src/caps/template/template_cap.F90`, que lista os passos (copiar, trocar o ponto, escolher as políticas de anúncio, a grade, os valores e o avanço, registrar no driver). Constante `POINT_<COMP>`, listas por `cpl_arrivals` e `cpl_exports`, rotinas de `cap_common` (`cap_advertise`, com a política de anúncio pelo nome, `cap_realize_fields`, `cap_put_field`, `cap_stamp_export`); o que é do modelo fica num adaptador.
5. **Driver** (`esm.F90`): uma chamada a `register_model` (posição, nome do modelo, `SetServices`, `timeStampValidation`, mensagem no registro; o rótulo vem de `COMPONENTS`), e `chosen_model` já devolve o modelo da chave da posição; uma posição nova ganha uma linha em `POSITIONS` (`driver_layout.F90`), e a divisão de PETs por blocos (`split_blocks`) passa a incluí-la; os pares de conectores em `CONNECTOR_SRC`/`CONNECTOR_DST` (um conector do mapa fora da lista para a inicialização); a sequência de execução em `RUN_SEQUENCES` (`src/driver/run_sequences.F90`), escolhida por `run_sequence_name`; para experimentar outra ordem sem recompilar, a chave `run_sequence_file` do `&nuopc_driver`.
6. **Compilação**: basta o arquivo estar num diretório de `SRC_SUBDIRS` e rodar `tools/dev/dependencias.py gera` (dependências em `src/dependencies.mk`); o `Makefile`, o `compila-local.bash` e os testes tiram dali a lista e a ordem. Com real de 8 bytes, incluir o fonte em `MOM6_SRCS`.

## 6. Como incluir um esquema de interpolação

1. Copiar `src/regrid/regrid_idw.F90` (modelo comentado) para `regrid_<nome>.F90` e trocar `idw` pelo nome.
2. Escrever `compute_weights(this, src_points, dst_points, factors, orig, dest, rc)`: recebe os pontos de origem (todos) e de destino (os do processo), com `lon`, `lat`, `valid` e `global_index`, e devolve peso, índice de origem e índice de destino de cada termo. A base `weights_regridder_t` cuida do ESMF e da reprodutibilidade com qualquer número de processos.
3. Opções em texto (`'chave=valor,...'`) com `regrid_option_int`, `regrid_option_real` e `regrid_options_check`.
4. Uma linha em `regrid_schemes.F90` (`call register('<nome>', new_<nome>, rc)`); o `Makefile` tira a lista de fontes de `src/dependencies.mk` (rodar `tools/dev/dependencias.py gera`).
5. Comparar: `tests/regrid/compara-esquema.bash <nome> '<opções>'` (erro contra uma função analítica e o mesmo campo, bit a bit, com 1 e 4 processos).
6. Usar: colunas `scheme` e `options` de `ROUTES` ou, sem recompilar, `regrid_scheme` e `regrid_options` em `&nuopc_regrid`. Trocar o esquema de uma rota da produção muda resultados e exige linha de base nova.

Um esquema que não é só de pesos (como o `mpassit`) estende `regridder_t` e implementa `setup`, `execute` e `release`; `tests/regrid/identity_scheme.F90` tem um exemplo mínimo dos dois tipos. Detalhes do framework em [`interpolacao-plugavel.md`](interpolacao-plugavel.md).

## 7. Decisões que mudariam resultados (fase 10)

| Hoje | Alternativa |
| --- | --- |
| campos para a atmosfera vão da malha de fluxo à do oceano e voltam a uma malha da atmosfera pelo conector | exportá-los na malha `atm_med` |
| conectores interpolam entre representações da mesma malha | mesma malha dos dois lados e `redist` na coluna `method` |
| células do MPAS para a grade do cap com código próprio | malha `mpas` no catálogo e rota com o esquema `mpassit` |
| fração de gelo do OISST pelo ponto mais próximo, com código próprio | OISST como malha do catálogo e rota conservativa |
| três regras de arredondamento para o índice de uma grade regular | uma regra só |
| DATM no mapa, mas não registrado pelo driver | registrá-lo ou retirá-lo |

Cada uma exige decisão do GT, etapa própria e linha de base nova. As demais decisões em aberto estão em [`estado-do-projeto.md`](estado-do-projeto.md).
