# Arquitetura de acoplamento do MONAN-Coupler

Resumo da arquitetura atual, para quem vai usar ou estender o acoplador. A descrição completa da fase 11 (diagnóstico, plano, etapas e indicadores) está em [`historico/arquitetura-acoplamento-fase11.md`](historico/arquitetura-acoplamento-fase11.md); a nota técnica "A nova arquitetura do MONAN-Coupler" traz o mesmo conteúdo com figuras.

## 1. Antes e depois

Na versão original, a descrição do acoplamento estava espalhada: nomes de campos escritos à mão em oito arquivos, sete construções de malha em seis arquivos, rotas de interpolação criadas em lugares diferentes (uma delas dentro da física) e o carimbo de tempo dos campos feito por cinco arquivos. Hoje ela está num lugar só, `src/coupling`, escrita como tabelas que os componentes, o driver e o mediador consultam, e uma conferência compara as tabelas com o que os componentes anunciam.

| Tarefa | Antes | Agora |
| --- | --- | --- |
| incluir um campo | editar as listas do componente de origem, do mediador e do destino | uma linha em `FIELDS` e uma por passagem em `EXCHANGES` |
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
| `EXCHANGES` | passagem de um campo de um ponto a outro | `field`, `src`, `dst`, `via` (`'conector'`, `'cap'` ou nome de rota), `when`, `method` (só nos conectores) |
| `EXPORTS` | campo que um modelo exporta, na ordem do anúncio | `field`, `point`, `when` |
| `ROUTES` | interpolação do mediador | `name`, `src`, `dst`, `methods`, `scheme`, `mask`, `fallback`, `no_value`, `fill`, `nan_to`, `create` (`min_limit` e `max_limit` existem, mas ainda não são aplicadas) |
| `GAPS` | lacuna conhecida, que não interrompe a rodada | `field`, `point`, `when`, `reason` |

Exemplo, o caminho da SST até a malha de fluxo:

```fortran
cpl_exchange_t('So_t', 'OCN@ocn_mom6', 'MED@ocn_med', 'conector',    'mom6', 'bilinear'), &
cpl_exchange_t('So_t', 'MED@ocn_med',  'MED@atm_med', 'ocn2atm_sst', '',     ''),         &
```

Os componentes perguntam ao mapa: `cpl_arrivals(ponto, ...)` devolve a lista de importação e `cpl_exports(ponto, ...)` a de exportação, na ordem das tabelas e só com as linhas da configuração atual (`cpl_current_config`). O driver registra os conectores que têm troca válida (`cpl_driver_connectors`, entre os pares de `CONNECTOR_SRC`/`CONNECTOR_DST`) e escreve o método de cada campo na `CplList` (`cpl_write_methods`). `tools/dev/mapa-acoplamento.py` gera [`acoplamento.md`](acoplamento.md), a versão em tabelas por componente e por conector.

## 4. Como incluir um campo

1. Uma linha em `FIELDS` (sem ela, o anúncio do campo para a rodada).
2. Uma linha por passagem em `EXCHANGES`. A linha por conector faz o destino anunciar o campo e o driver escrever o método; a linha por rota registra a passagem para a conferência, e a chamada que aplica a rota fica numa fase do mediador.
3. Se o campo sai de um modelo, uma linha em `EXPORTS`. O cap (ou o adaptador) preenche os valores.
4. `tools/dev/mapa-acoplamento.py` e `tools/dev/confere-tudo.bash HEAD`. Na rodada, uma linha faltando ou sobrando aparece como `CPL-REL: DIFERENCA:` e interrompe a inicialização; uma diferença esperada vai para `GAPS`, com o motivo.

## 5. Como incluir um componente

1. **Malha**: linha em `GRIDS`; o cap a constrói pelo catálogo (`cpl_grids`). Malha de tipo novo: função nova em `cpl_grids`.
2. **Campos e passagens**: `FIELDS`, `EXCHANGES`, `EXPORTS` (seção 4); rotas novas do mediador em `ROUTES`.
3. **Chave e condições** (componente opcional): chave em `&nuopc_mode` e `coupler_config`; campo em `cpl_config_t` e em `cpl_current_config`; condições em `CONDITIONS` e `condition_holds`; regras em `cpl_config_is_valid`; configurações em `mapa-acoplamento.py` e no teste do mapa.
4. **Cap**: como o do DOCN. Constante `POINT_<COMP>`, listas por `cpl_arrivals` e `cpl_exports`, rotinas de `cap_common` (`cap_realize_fields`, `cap_put_field`, `cap_stamp_export`); o que é do modelo fica num adaptador.
5. **Driver** (`esm.F90`): `add_model` e a divisão de PETs; os pares de conectores em `CONNECTOR_SRC`/`CONNECTOR_DST` (um conector do mapa fora da lista para a inicialização); as linhas em `SetRunSequence`.
6. **Compilação**: `SRCS` e dependências no `Makefile`; `compila-local.bash`, se compilar fora da Jaci.

## 6. Como incluir um esquema de interpolação

1. Copiar `src/regrid/regrid_idw.F90` (modelo comentado) para `regrid_<nome>.F90` e trocar `idw` pelo nome.
2. Escrever `compute_weights(this, src_points, dst_points, factors, orig, dest, rc)`: recebe os pontos de origem (todos) e de destino (os do processo), com `lon`, `lat`, `valid` e `global_index`, e devolve peso, índice de origem e índice de destino de cada termo. A base `weights_regridder_t` cuida do ESMF e da reprodutibilidade com qualquer número de processos.
3. Opções em texto (`'chave=valor,...'`) com `regrid_option_int`, `regrid_option_real` e `regrid_options_check`.
4. Uma linha em `regrid_schemes.F90` (`call register('<nome>', new_<nome>, rc)`) e o arquivo no `Makefile`.
5. Comparar: `tests/regrid/compara-esquema.bash <nome> '<opções>'` (erro contra uma função analítica e o mesmo campo, bit a bit, com 1 e 4 processos).
6. Usar: coluna `scheme` de `ROUTES` ou, sem recompilar, `regrid_scheme` e `regrid_options` em `&nuopc_regrid`. Trocar o esquema de uma rota da produção muda resultados e exige linha de base nova.

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
