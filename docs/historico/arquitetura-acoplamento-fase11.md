# Arquitetura de acoplamento do MONAN-Coupler: malhas, trocas e interpolação

Versão de 30/09/2026, sobre a tag `fase9-07-validada`; no repositório desde a R-FASE11-01, atualizada na R-FASE11-02 (seções 3.5 e 6), na R-FASE11-03 (seções 3.6 e 6), na R-FASE11-04 (seções 4.2 e 6), na R-FASE11-05 (seções 3.5 e 6), na R-FASE11-06 (seções 3.5 e 6), na R-FASE11-07 (seções 3.5 e 6), na R-FASE11-08 (seções 3.3, 4.2 e 6), na R-FASE11-09 (seções 3.3 e 6), na R-FASE11-10 (seções 3.3 e 6), na R-FASE11-11 (seções 3.3, 4.3 e 6), na R-FASE11-12 (seções 3.5, 4.3 e 6), na R-FASE11-13 (seções 3.5, 4.3 e 6), na R-FASE11-14 (seções 3.5, 4.3 e 6), na R-FASE11-15 (seções 3.7 e 6), na R-FASE11-16 (seções 3.7 e 6) e na R-FASE11-17 (seções 3.7, 4.3 e 6, com a etapa R-FASE11-18 nova e as seguintes renumeradas) na R-FASE11-18 (seções 3.7 e 6), na R-FASE11-19 (seções 3.7, 4.3 e 6), na R-FASE11-20 (seções 3.7 e 6), na R-FASE11-21 (seções 3.5 e 6), na R-FASE11-22 (seções 2, 3.5 e 6), na R-FASE11-23 (seções 3.8 e 6), na R-FASE11-24 (seções 3.1, 3.9 e 6), na R-FASE11-25 (seções 3.6 e 6) e na R-FASE11-26 (seções 4.4, 4.5 e 6), que encerrou a fase 11: esta é a versão final do documento para a fase. Substitui a versão de 29/09/2026 e a proposta de interpolação anterior. Corresponde à arquitetura descrita na NTC "Arquitetura de acoplamento do MONAN-Coupler: malhas, trocas e interpolação" (INPE, 2026), com o plano de migração detalhado para execução.

## Resumo

A descrição do acoplamento (que campos vão de onde para onde, em que malha e por qual interpolação) não existe em nenhum lugar do código. Ela está espalhada por mais de dez arquivos. A mesma malha tripolar é construída três vezes, e a interpolação acontece em quatro camadas, uma delas implícita (os conectores) e outra dentro da física do mediador.

A arquitetura proposta se apoia em três conceitos, quatro camadas e três arquivos de descrição:

| Conceito | O que é |
| --- | --- |
| Malha | onde um campo está definido: nome, tipo (regular, tripolar, Voronoi), convenção de longitude, construtor único |
| Campo | o que é trocado: nome padrão, unidade, convenção de sinal, descrição |
| Troca | um campo que passa de uma malha a outra: origem, destino, meio (conector, rota ou cap) e configuração em que vale |

| Camada | Responsabilidade |
| --- | --- |
| Modelos | calculam; não sabem que estão acoplados |
| Adaptadores (caps) | traduzem arrays do modelo em campos ESMF na malha do componente, com as conversões de unidade e sinal do modelo |
| Transporte (conectores) | levam campos de um componente a outro, com o método escrito na descrição |
| Mediador | faz toda interpolação espacial, por rotas, e calcula os fluxos |

| Arquivo | Conteúdo |
| --- | --- |
| `src/coupling/cpl_grids.F90` | catálogo de malhas e fórmulas de índice das grades regulares |
| `src/coupling/cpl_fields.F90` | dicionário de campos (`FIELDS`) |
| `src/coupling/cpl_map.F90` | mapa de acoplamento: tabelas `EXCHANGES` e `ROUTES` |

A migração é a **fase 11** do roteiro, com as mesmas regras das fases 1 a 9: uma etapa por patch, conferências locais e validação bit a bit na Jaci. A fase 10 continua reservada às decisões que mudam resultados.

A fase 11 terminou na R-FASE11-26 (tag `fase11-26-validada`), com 26 etapas, todas reproduzindo bit a bit a linha de base R-NOFMA-02 e com todos os indicadores da seção 4.4 nas metas. O estado final está na seção 6.

---

## 1. Retrato do acoplamento hoje

### 1.1 Malhas

| Malha | Tipo | Onde é construída | Longitude e observações |
| --- | --- | --- | --- |
| MPAS `x1.40962` | Voronoi | o próprio modelo | radianos, 0 a 2π; não é objeto ESMF |
| grade do cap atmosférico | regular 1° | `mpas_create_grid` (`mpas_cap_methods`) | centros de -179,5° a 179,5° |
| grade ATM do mediador | regular 1°, com cantos | `create_atm_grid` (`med_init`) | centros de 0,5° a 359,5°; malha da física bulk |
| grade OCN do mediador | tripolar | `create_ocn_grid` (`med_init`) | lida de `ocean_hgrid.nc`, normalizada para [0°, 360°) |
| grade do MOM6 | tripolar | `create_ocean_grid` (`mom_cap_MONAN`) | `geoLonT` do MOM6; blocos do MOM6 (`deBlockList`) |
| grade do SIS2 | tripolar | `InitializeRealize` (`sis_cap_MONAN`) | lida de `ocean_hgrid.nc`; contagens por direção e mapa de PETs do SIS2 |
| grade do DOCN | regular | `DOCN_cap` | conforme o arquivo; modo alternativo |
| grade do DATM | regular | `DATM_cap` | o driver não registra o DATM |
| OISST no mediador | regular 0,25° | `fill_ifrac_from_oisst` (`med_ocean`) | array comum |
| grades dos diagnósticos | regulares | gravadores do cap atmosférico | 360 por 181 pontos em graus inteiros; arrays comuns |

### 1.2 Trocas na configuração de produção

| Troca | Campos | De, para | Interpolação | Código |
| --- | --- | --- | --- | --- |
| MPAS, interno | 13 forçantes | Voronoi, grade do cap | média por caixa, código próprio | `mpas_cell_binning` |
| ATM para MED | 13 forçantes | grade do cap, ATM do MED | conector, implícita | `esm.F90` |
| OCN para MED | 4 campos | MOM6, OCN do MED | conector, implícita | `esm.F90` |
| ICE para MED | 6 campos | SIS2, OCN do MED | conector, implícita | `esm.F90` |
| MED, OCN para ATM | SST, correntes, gelo, máscara | OCN do MED, ATM do MED | 4 rotas `ocn2atm*` | `med_init`, `med_ocean`, `med_ice`, `med_export`, `med_bulk_ncar` |
| MED, ATM para OCN | 31 campos exportados | ATM do MED, OCN do MED | 2 rotas `atm2ocn*` | `med_cap_methods`, `med_export` |
| MED para OCN | 14 fluxos | OCN do MED, MOM6 | conector, implícita | `esm.F90` |
| MED para ICE | 16 campos | OCN do MED, SIS2 | conector, implícita | `esm.F90` |
| MED para ATM | 7 campos | OCN do MED, grade do cap | conector, implícita | `esm.F90` |
| MPAS, interno | 7 campos | grade do cap, Voronoi | caixa do centro, código próprio | `mpas_cap_methods` |

A lista completa dos campos de cada conector e das rotas está no Apêndice A.

### 1.3 Dificuldades

1. **Sem fonte única de verdade.** Os nomes dos campos estão em listas separadas em cada cap e no mediador. O dicionário do NUOPC está em acréscimo automático (`NUOPC_FieldDictionarySetAutoAdd`), então um nome errado só aparece na execução, como "Import Fields not all connected".
2. **A mesma malha construída três vezes.** A tripolar é montada no mediador, no MOM6 e no SIS2, com três códigos e três formas de decompor.
3. **Interpolação em quatro camadas.** As camadas são os conectores (implícita), as rotas do mediador, o código próprio no cap atmosférico e o código próprio no mediador (OISST) e nos diagnósticos. As fórmulas de índice da grade regular aparecem em nove rotinas, com `int`, `floor` e `nint`.
4. **Rotas espalhadas.** São seis rotas, criadas em sete pontos de cinco arquivos, uma delas usada dentro de `med_bulk_ncar`.
5. **Regras implícitas.**
   - A máscara é gravada na malha por dois trechos repetidos.
   - Há uma sentinela -999 antes das rotas do gelo e um preenchimento depois.
   - `RegridOrCopy` troca NaN por zero.
   - `med_bulk_ncar` limita a fração de gelo a [0, 1].
6. **Convenções de campo não escritas.** O calor sensível sobre o gelo é invertido dentro do cap do SIS2; unidade e sinal só se descobrem lendo o código.
7. **Comunicação, transformação e física misturadas.** `med_export` interpola, preenche, zera fluxos sobre terra, exporta e carimba o tempo. O carimbo de tempo é feito em cinco arquivos, e outros dois (DOCN e DATM) importam a rotina sem chamá-la.

---

## 2. Revisão da versão de 29/09/2026

| Tema | Na versão anterior | Nesta versão |
| --- | --- | --- |
| Conceitos | três verbos (`exchange`, `route`, `transform`), hierarquia de objetos de etapa, cinco regras | três conceitos, uma tabela de trocas e uma de rotas com colunas fixas |
| Etapas das rotas | lista de objetos de tipos diferentes (`steps=[step_fill(...), step_nan_to(...)]`), que não compila em Fortran | quatro etapas fixas (preparar, interpolar, completar, limitar), cada uma configurada por colunas da linha da rota |
| Literais | inteiros onde o tipo espera `real(r8)` | todos os valores com `kind` |
| Configurações alternativas | não tratadas | coluna `when` nas trocas (`docn`, `sis2`, `med_to_mpas`, `datm`) |
| Criação das rotas | "máscara aplicada antes de criar as rotas que a pedem" (mudaria o momento de criação da `ocn2atm_sst` e os resultados) | coluna `create` (`inicio` ou `mascara_mista`), que reproduz o momento de hoje |
| Preenchimento do gelo | dentro da rota (mudaria o diagnóstico que registra o campo antes do preenchimento) | explícito onde a ordem importa, com comentário na linha da rota |
| Decomposição | `decomp=DECOMP_FROM_MOM6` / `DECOMP_FROM_SIS2` (os dois caps descrevem a decomposição de formas diferentes) | decomposição sempre como lista de blocos por PET (`cpl_blocks_t`) |
| Método dos conectores | escrito no `CplList` sem conferência | só depois de confirmar no log que é igual ao padrão usado hoje (confirmado na R-FASE11-22: o relatório da R-FASE11-03 mostrava a `CplList` sem `remapmethod`, e o padrão do conector no ESMF 8.9.1 é o bilinear) |
| Tempo, sinal, conferência | ausentes | carimbo de tempo num lugar só; sinal no dicionário de campos; conferência do mapa na inicialização |
| Organização | 11 arquivos novos em 4 subdiretórios | 4 arquivos em `src/coupling/`, `src/regrid/` como está, `med_exchange.F90` no mediador |
| Registro no log | "manifesto" | **relatório de acoplamento**, para não confundir com o `MANIFEST` da linha de base |

---

## 3. Arquitetura

### 3.1 Organização dos fontes

```
src/coupling/
  cpl_grids.F90    catálogo de malhas: tipos, construtores, fórmulas de índice
  cpl_fields.F90   dicionário de campos: nome, unidade, sinal, descrição
  cpl_map.F90      tabelas EXCHANGES e ROUTES e as consultas sobre elas
  cpl_check.F90    conferência do mapa e relatório de acoplamento no log
src/regrid/        framework de interpolação (como hoje, mais a base de pesos)
src/mediator/
  med_exchange.F90 executa as trocas do mediador, por fase
src/caps/atmos/
  mpas_adapter.F90  tradução entre o MONAN-A e o ESMF (desde a R-FASE11-24)
```

### 3.2 Onde escrever cada mudança

| Quero | Onde |
| --- | --- |
| levar um campo novo de um componente a outro | uma linha em `FIELDS` e as linhas da troca em `EXCHANGES` |
| mudar o método ou o esquema de uma rota | a linha da rota em `ROUTES`, ou só o `nuopc.input` para experimentar |
| escrever um esquema de interpolação | um arquivo em `src/regrid/` e uma linha em `regrid_schemes.F90` |
| acrescentar ou alterar uma malha | `cpl_grids.F90` |
| mudar uma fórmula de fluxo | física do mediador, que não conhece rotas nem estados |
| converter unidade ou sinal de um modelo | o cap do modelo, com a convenção registrada em `FIELDS` |

### 3.3 Catálogo de malhas

```fortran
type :: cpl_blocks_t                     ! decomposição: um bloco por PET
  integer, allocatable :: i0(:), i1(:), j0(:), j1(:)
end type cpl_blocks_t

type :: cpl_malha_t
  character(len=16) :: name       = ''       ! 'atm_med', 'ocn_med', ...
  character(len=8)  :: grid_type       = ''       ! 'latlon', 'tripolar', 'voronoi'
  character(len=8)  :: lon_origin = ''       ! 'leste0' ou 'oeste180'
  integer           :: nx = 0, ny = 0
  logical           :: corners     = .false.  ! exigido pelo método conservativo
  type(ESMF_Grid)   :: grid
end type cpl_malha_t

function malha_latlon(name, nx, ny, lon_origin, corners, blocks, rc) result(m)
function malha_tripolar(name, arquivo_hgrid, blocks, rc) result(m)
```

| Nome | Tipo | Uso |
| --- | --- | --- |
| `mpas` | Voronoi | células do MONAN-A; só descrita |
| `atm_cap` | latlon | grade do cap atmosférico, longitude a partir de -180° |
| `atm_med` | latlon | malha de fluxo do mediador, longitude a partir de 0°, com cantos |
| `ocn_med` | tripolar | oceano no mediador, blocos do mediador |
| `ocn_mom6` | tripolar | MOM6, blocos do MOM6 |
| `ice_sis2` | tripolar | SIS2, blocos do SIS2 |

As fórmulas de centro e de índice das grades regulares ficam em `cpl_grids`. Onde duas rotinas usam regras de arredondamento diferentes, ficam duas funções, com nomes que dizem a diferença, para que nada mude.

Como ficou na R-FASE11-08, para as duas malhas regulares do lado atmosférico:

| Item | Em `cpl_grids` |
| --- | --- |
| construtor | `cpl_latlon_grid(nome, nx, ny, lon_origin, cantos, petCount, grade, rc)`, uma sub-rotina que devolve a `ESMF_Grid`; `atm_med` com `ORIGIN_EAST0` e cantos, `atm_cap` com `ORIGIN_WEST180` e sem cantos |
| decomposição | `cpl_regdecomp(petCount, nx, ny)`, a fatoração em um DE por PET que o mediador e o cap atmosférico já usavam (antes escrita duas vezes) |
| centros e cantos | `center_lon_east0`, `center_lat_east0`, `corner_lon_east0`, `corner_lat_east0` (as expressões de `atm_med`) e `center_lon_west180`, `center_lat_west180` (as de `atm_cap`) |

O tipo `cpl_malha_t` do esboço acima não foi criado: a descrição de cada malha (nome, componente, tipo) já está na tabela `GRIDS` de `cpl_map`, e a `ESMF_Grid` continua guardada pelo componente que a usa. `create_atm_grid` e `mpas_create_grid` ficaram como rotinas curtas que chamam o construtor, com as mesmas interfaces, o que permite comparar as duas versões com o mesmo programa de teste. Na R-FASE11-09 entraram as fórmulas de índice (de coordenada para coluna e linha) e as de longitude numa faixa de 360 graus:

| Função | Expressão | Usada por |
| --- | --- | --- |
| `index_trunc(x, d, n)` | `int(x/d) + 1`, limitado a [1, n] | `bin_cells_local`, `copy_to_local_grid`, `state_get_field_1d`, `oisst_to_atm_nearest`, OISST no cap do MOM6 (`mom_si_ifrac`), diagnóstico da importação (`voronoi_to_grid`, que usava `floor`: com o limite, dá sempre o mesmo índice) |
| `index_round(x, d, n)` | `nint(x/d) + 1`, limitado a [1, n] | diagnóstico da exportação (`voronoi_accum_local`) |
| `lon_0to360_floor(lon)` | `lon - floor(lon/360)*360` | `bin_cells_local` |
| `lon_m180to180_floor(lon)` | `lon - floor((lon+180)/360)*360` | `state_get_field_1d` |
| `lon_0to360_loop(lon)` | soma ou subtrai 360 até [0, 360) | `mom_si_ifrac` |
| `lon_m180to180_loop(lon)` | subtrai ou soma 360 até [-180, 180) | os dois diagnósticos |

Quem chama soma a origem antes (`lat + 90`, `lon + 180`), como as expressões faziam. `check_ice_geography` passou a usar `center_lon_east0` e `center_lat_east0`, que dão os mesmos valores, bit a bit, que as expressões dela. Ficaram fora, por serem regras próprias e usadas uma vez: a soma única de 360 em `copy_to_local_grid` (que não é o mesmo que o laço, ver `cpl_grids`) e os centros de `oisst_to_atm_nearest`, que recebem os passos como argumento.

Na R-FASE11-10 entraram as malhas do oceano no mediador e do SIS2:

| Item | Em `cpl_grids` |
| --- | --- |
| construtor | `cpl_tripolar_grid(nome, arquivo, nx, ny, petCount, cantos, grade, rc, blocos, tag, tag_corners)`: grade periódica em longitude com os centros (e, com `cantos`, os vértices) lidos do supergrid por `mom6_supergrid_tcoords` e `mom6_supergrid_corners`, em cada DE local |
| blocos | `cpl_blocks_t` (tamanhos por coluna e por linha de blocos e o PET de cada bloco, a forma que `ESMF_GridCreate1PeriDim` recebe) e `cpl_blocks_from_bounds`, que os monta a partir dos limites de cada PET e confere cobertura e unicidade (antes `ICE_DecompFromBlocks`, no cap do SIS2); sem blocos, a decomposição é `cpl_regdecomp` |
| `ocn_med` com o MOM6 | `cpl_tripolar_grid` sem blocos, com cantos |
| `ocn_med` com o DOCN | `cpl_latlon_grid` com a origem nova `ORIGIN_EAST0_CORNER` |
| `ice_sis2` | `cpl_tripolar_grid` com os blocos do domínio do SIS2, sem cantos |

Com o DOCN, o mediador descreve a grade do OISST com a longitude do centro igual à do canto oeste da célula, `(i-1)*360/nx`, sem a meia célula, enquanto a latitude do centro tem a meia célula. O cap do DOCN põe os centros na meia célula; com isso, o conector interpola em vez de copiar, e o campo sai suavizado em longitude. A etapa preservou isso como uma origem própria (`ORIGIN_EAST0_CORNER`), porque nenhuma etapa da fase 11 muda resultados; fica registrado como ponto a examinar fora da fase (ver `docs/estado-do-projeto.md`, seção 8). A conferência dos cantos e a máscara de `ocn_med` continuam em `med_init`, e a conferência do bloco de cada PET contra o do SIS2 continua no cap do gelo. Todas as malhas de `cpl_grids` passam `periodicDim = 1` explicitamente, que é o padrão do ESMF (`ESMF_Grid.F90`, `ESMF_GridCreate1PeriDim`); as malhas do lado atmosférico o omitiam.

Na R-FASE11-11, a grade do cap do MOM6 (`ocn_mom6`) passou para `cpl_grids` como `cpl_block_grid(nome, ni, nj, limites, petMap, grade, rc)`: DELayout com o mapa de PETs, DistGrid com a lista de blocos do MOM6 (`deBlockList`), grade sem halo, stagger dos centros; as coordenadas continuam vindo de `geoLonT` e `geoLatT`, copiadas pelo cap. O plano previa construí-la por `cpl_tripolar_grid` se as coordenadas lidas do supergrid fossem idênticas às do modelo, mas a grade difere da de `ocn_med` em mais do que as coordenadas:

| Aspecto | `ocn_mom6` (cap do MOM6) | `ocn_med` e `ice_sis2` |
| --- | --- | --- |
| criação | `ESMF_GridCreate` sobre DistGrid com `deBlockList` | `ESMF_GridCreate1PeriDim` |
| periodicidade em longitude | não declarada | `periodicDim = 1` |
| índices | locais de cada DE | globais |
| coordenadas | `geoLonT`, `geoLatT` do MOM6 | do supergrid, em [0, 360) |

Só a periodicidade já muda os pesos que o conector OCN para MED calcula. Unificar as malhas do oceano é, então, uma mudança de resultados, com linha de base própria, fora da fase 11.

### 3.4 Dicionário de campos

```fortran
type :: cpl_field_t
  character(len=24) :: name
  character(len=12) :: units
  character(len=48) :: sign_conv          ! convenção de sinal, quando houver
  character(len=64) :: description
end type cpl_field_t

type(cpl_field_t), parameter :: FIELDS(*) = [                                        &
  cpl_field_t('So_t',     'K',     '', 'temperatura da superficie do oceano'),       &
  cpl_field_t('Si_ifrac', '1',     '', 'fracao de gelo, entre 0 e 1'),               &
  cpl_field_t('Fioi_sen', 'W m-2', 'do mediador; o cap do SIS2 inverte',             &
              'calor sensivel sobre o gelo') ]
```

### 3.5 Mapa de acoplamento

O mapa está em `src/coupling/cpl_map.F90` desde a R-FASE11-02, e a versão em tabelas, gerada dele, em `docs/acoplamento.md`.

`EXCHANGES` tem uma linha por passagem de um campo de uma malha a outra. As colunas são: `field`, `componente@malha` de origem (`src`), `componente@malha` de destino (`dst`), `via` (`conector`, nome de rota ou `cap`), `when`, a lista de condições em que a troca vale, separadas por vírgula (vazia: vale sempre), e `method`, o método de interpolação do conector (desde a R-FASE11-22; só nas trocas por conector, vazio nas demais). Cada chave de `&nuopc_mode` tem as duas condições, a de cada valor, para que toda troca diga onde vale sem precisar de negação:

| Condições | Chave |
| --- | --- |
| `mpas` / `datm` | `use_datm` |
| `mom6` / `docn` | `use_docn` |
| `med_to_mpas` / `ocn_to_mpas` | `use_med_to_mpas` |
| `sis2` | `use_sis2_dynamic` |

Exemplo com o caminho da temperatura de superfície:

```fortran
type(cpl_exchange_t), parameter :: EXCHANGES(*) = [                                                            &
  !           field            src             dst             via            when                method
  cpl_exchange_t('So_t',          'OCN@ocn_mom6', 'MED@ocn_med',  'conector',    'mom6',             'bilinear'), &
  cpl_exchange_t('So_t',          'OCN@docn',     'MED@ocn_med',  'conector',    'docn',             'bilinear'), &
  cpl_exchange_t('So_t',          'MED@ocn_med',  'MED@atm_med',  'ocn2atm_sst', '',                 ''),         &
  cpl_exchange_t('Sx_tsfc',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',     '',                 ''),         &
  cpl_exchange_t('Sx_tsfc',       'MED@ocn_med',  'ATM@atm_cap',  'conector',    'mpas,med_to_mpas', 'bilinear'), &
  cpl_exchange_t('Sx_tsfc',       'ATM@atm_cap',  'ATM@mpas',     'cap',         'mpas',             ''),         &
  cpl_exchange_t('Si_ifrac_sis2', 'ICE@ice_sis2', 'MED@ocn_med',  'conector',    'sis2',             'bilinear'), &
  cpl_exchange_t('Si_ifrac_sis2', 'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice', 'sis2',             '') ]
```

No mediador, o mesmo nome pode existir duas vezes em `MED@ocn_med`: o campo importado e o exportado (`So_t`, `So_u` e `So_v`). A regra de leitura do mapa é que uma rota que parte de `MED@ocn_med` lê o campo importado, e um conector que parte dali leva o exportado, que chegou de `MED@atm_med` pela rota `atm2ocn`.

As listas de campos que um componente anuncia e realiza saem do mapa por `cpl_arrivals(point, by_connector, cfg, keys, names)`: os campos que chegam ao ponto (`COMPONENTE@malha`, ou só o componente), por conector (importação) ou por rota e cap (dentro do componente), na ordem de `EXCHANGES` e sem repetição. O componente diz quais chaves de `&nuopc_mode` consulta; as outras ficam livres, e a lista é a união das configurações válidas que concordam com a atual nessas chaves. O mediador consulta só `datm` e `sis2` (`MED_KEYS`): por isso anuncia `So_omask` também com o DOCN, como antes. A importação do mediador é a chegada por conector; a exportação, a chegada em `MED@ocn_med` pelas rotas `atm2ocn` e `atm2ocn_ice`, que já estava na ordem de `export_names`.

A exportação de um modelo não sai de `EXCHANGES`, porque um modelo pode anunciar campos que nenhum conector leva: o MOM6 exporta `So_s`, `Fioo_q` e `Si_ifrac`, que ninguém consome na produção (os três avisos da conferência, seção 3.6). Desde a R-FASE11-06, a tabela `EXPORTS` tem uma linha por campo que um modelo anuncia no estado de exportação (`field`, `point` e `when`), na ordem do anúncio, e `cpl_exports(point, cfg, keys, names)` gera a lista, com a mesma regra de chaves de `cpl_arrivals`. O teste do mapa exige que todo campo que sai de um modelo por conector esteja em `EXPORTS` na mesma configuração. Os caps dos modelos não consultam nenhuma chave: anunciam sempre as mesmas listas, como antes. Desde a R-FASE11-07, o mediador e os caps dos cinco modelos tiram as listas do mapa, e a ordem das linhas de `EXCHANGES` e de `EXPORTS` é a ordem do anúncio. Onde a ordem da lista servia para alinhar outro dado (os valores iniciais da importação do MONAN-A e da exportação do DOCN), o dado passou a ser escolhido pelo nome do campo.

```fortran
type(cpl_export_t), parameter :: EXPORTS(*) = [          &
  !             field        point           when
  cpl_export_t('So_t',      'OCN@ocn_mom6', 'mom6'),         &
  cpl_export_t('So_s',      'OCN@ocn_mom6', 'mom6'),         &
  ...
  cpl_export_t('Si_t_sis2', 'ICE@ice_sis2', 'sis2') ]
```

Desde a R-FASE11-12, o mediador cria as rotas por `create_route(regrid, nome, src, dst, rc)` (`med_cap_methods`), que lê a linha da rota em `ROUTES` (`route_spec`): os métodos, o esquema, a máscara na origem (se a coluna `mask` está preenchida) e a rota de reserva. O grupo `&nuopc_regrid` do `nuopc.input` continua podendo trocar o esquema e os métodos de uma rota. A busca na tabela ficou no mediador, e não em `regrid_manager%add`, como o plano previa: o framework de interpolação (`src/regrid`) não depende do mapa de acoplamento e continua testável sozinho (`tests/regrid`). Desde a R-FASE11-13, a rota também aplica as colunas `no_value` e `nan_to`: `zerar` zera o destino inteiro antes da interpolação, `manter` e `sentinela` preservam o valor anterior nos pontos que a interpolação não alcança, e `nan_to` troca os NaN do destino depois dela. As chamadas de interpolação deixaram de passar `zero_total`. Quando uma rota usa a interpolação da reserva, essas opções continuam sendo as da rota pedida (`regrid_manager` guarda a configuração de cada rota). O valor da sentinela continua sendo escrito por quem usa a rota (`fill_ice_sentinels` em `med_ice` e o preenchimento de `Si_ifrac` em `med_export`), e não pela rota: o preenchimento acontece mesmo quando a rota não é aplicada (um campo do SIS2 ausente fica com a sentinela), e o da fração exportada vale também para a interpolação pela reserva. Desde a R-FASE11-14, a rota também executa a etapa completar (coluna `fill`): o `regrid_manager` faz o preenchimento por vizinhança depois da interpolação e antes da troca de NaN, com as opções da rota pedida, e devolve as contagens para o relatório de acoplamento. Saíram as chamadas à parte na SST (`fill_sst_gaps`, em `med_ocean`) e na fração de gelo exportada (`med_export`). Enquanto a máscara do oceano é uniforme, a SST passa pela rota `ocn2atm`, e a chamada pede o preenchimento da `ocn2atm_sst` (`route_fill`), como antes. As colunas `min_limit`, `max_limit` e `create` ainda não são lidas (bloco E).

Desde a R-FASE11-21, o driver registra os conectores pelo mapa: `cpl_driver_connectors` (`cpl_map`) percorre a lista dos sete pares que o driver sabe registrar (`CONNECTOR_SRC` e `CONNECTOR_DST`, na ordem de registro, que é a ordem de inicialização no NUOPC e a das linhas dos conectores no relatório) e escolhe os que têm troca por conector válida na configuração atual (`cpl_connector_applies`). A ordem da lista não é a de `EXCHANGES`, que define a do anúncio dos campos. Um conector do mapa que não tem lugar na lista é erro na inicialização. Como o driver registra o MONAN-A também com `use_datm`, a escolha consulta o mapa com a chave `datm` desligada.

Desde a R-FASE11-22, o método de cada campo de um conector também sai do mapa. O `ModifyCplLists` do driver, depois das opções de reprodutibilidade (`termorder=srcseq` e `srcTermProcessing=0`), chama `cpl_write_methods` (`cpl_check`), que acrescenta a cada entrada da `CplList` a opção `remapmethod` com o método da troca no mapa (`cpl_connector_method`, coluna `method` de `EXCHANGES`). O método não depende da configuração: as trocas do mesmo campo entre os mesmos dois componentes têm o mesmo método em todas as linhas (conferido pelo teste do mapa). Hoje é `bilinear` em todas, que é o padrão do conector NUOPC do ESMF 8.9.1 quando a `CplList` não traz `remapmethod`: com a opção escrita, o conector faz as mesmas chamadas ao ESMF, com os mesmos parâmetros (`polemethod`, `unmappedaction`, `extrapmethod` e as máscaras continuam no padrão, como antes). A conferência do mapa passou a comparar também o método de cada entrada com o do mapa (`cpl_check_methods`): entrada sem `remapmethod`, ou com outro método, é diferença. A troca de método de um conector, quando vier, é uma linha do mapa; a passagem para `redist` entre representações da mesma malha continua sendo uma decisão da fase 10 (seção 5).

O DATM está no mapa como o cap dele anuncia os campos (malha `datm`, condição `datm`), mas o driver não o registra: com `use_datm=.true.` o componente atmosférico continua sendo o MONAN-A. Duas lacunas de hoje ficam registradas no teste do mapa: com o DOCN, `So_omask` não chega ao mediador (o DOCN não a exporta); com o DOCN e o contorno direto do oceano, `Sx_tsfc`, `Sf_albedo` e `Sx_omask` não chegam ao MONAN-A, e o cap atmosférico interrompe a rodada.

`ROUTES` tem uma linha por interpolação do mediador. Toda rota tem as mesmas quatro etapas, na mesma ordem, e as colunas que não aparecem ficam com o valor padrão, que desliga a etapa:

| Etapa | Colunas |
| --- | --- |
| 1. preparar | `mask` (campo que dá a máscara da origem), `no_value` (`zerar`, `manter`, `sentinela`) |
| 2. interpolar | `methods` (em ordem de preferência), `fallback`, esquema (padrão `esmf`, trocável no `nuopc.input`) |
| 3. completar | `fill` (um `regrid_fill_t`: faixa válida, valor fixo, passadas) |
| 4. limitar | `min_limit`, `max_limit`, `nan_to` |

E uma coluna que não é etapa: `create`, o momento em que a rota é criada: `inicio` (em `InitializeDataComplete`), `primeiro_uso` (na primeira vez que o mediador precisa dela; é o caso de `ocn2atm_ice`, `ocn2atm_landmask` e `atm2ocn_ice`) ou `mascara_mista` (no primeiro passo em que a máscara do oceano tem terra e mar). O valor `primeiro_uso` foi acrescentado na R-FASE11-02, ao escrever as seis rotas: com só `inicio` e `mascara_mista`, o mapa não reproduziria o momento de criação de três delas.

```fortran
type(cpl_route_t), parameter :: ROUTES(*) = [                                      &
  cpl_route_t(name='ocn2atm',     src='ocn_med', dst='atm_med',                   &
             methods='bilinear'),                                                &
  cpl_route_t(name='ocn2atm_sst', src='ocn_med', dst='atm_med',                   &
             methods='conserve,bilinear', mask='So_omask',                    &
             fallback='ocn2atm', create='mascara_mista',                           &
             fill=regrid_fill_t(enabled=.true., vmin=270.0_r8,              &
                 vmax=310.0_r8, vfill=T_FREEZE_SEAWATER, max_iter=40,            &
                 skip_fraction=1.0_r8, overflow_to_fill=.true.)),                &
  cpl_route_t(name='ocn2atm_ice', src='ocn_med', dst='atm_med',                   &
             methods='conserve,bilinear', mask='So_omask',                    &
             fallback='ocn2atm', no_value='sentinela', create='primeiro_uso'),    &
  cpl_route_t(name='atm2ocn',     src='atm_med', dst='ocn_med',                   &
             methods='nearest_stod', nan_to=0.0_r8) ]
```

Na `ocn2atm_ice`, o preenchimento continua explícito em `med_exchange`, porque hoje ele acontece depois de diagnósticos que registram o campo antes dele. As colunas `min_limit`, `max_limit` e `nan_to` ficam desligadas com o valor `CPL_UNSET` (`huge(1.0_r8)`). As seis rotas completas estão em `cpl_map.F90`.

### 3.6 Conferência e relatório de acoplamento

`cpl_check` usa o mapa de duas formas:

- **Conferência, na inicialização.** Depois do anúncio dos campos, confere o mapa contra o que cada componente anunciou:
  - todo campo importado tem exatamente uma troca que chega a ele;
  - toda troca parte de um campo exportado;
  - toda malha e toda rota citadas existem;
  - todo campo está em `FIELDS`.

  Enquanto a migração não termina, só registra as diferenças no log; no fim, passa a interromper a rodada com a linha do mapa.

  Desde a R-FASE11-03, `cpl_check_coupling` faz essa conferência no fim do `ModifyCplLists` do driver, só no PET 0, e escreve linhas `CPL-REL: DIFERENCA:` e, para campos exportados que ninguém consome (normais, como o `So_s` do MOM6), `CPL-REL: AVISO:`. A conferência é feita nos dois níveis: a CplList de cada conector contra as trocas do mapa entre os dois componentes, e os estados de cada componente contra as trocas que chegam a ele e partem dele. O mesmo módulo escreve o relatório dos conectores (campos e opções de cada CplList).

  Desde a R-FASE11-25, a conferência interrompe a rodada: havendo diferença, `cpl_check_coupling` escreve o relatório inteiro, distribui o número de diferenças a todos os PETs e devolve erro, e o `ModifyCplLists` para a inicialização. As lacunas conhecidas, campos que um componente anuncia na importação e que numa configuração não têm origem (o `So_omask` do mediador com o DOCN; `Sx_tsfc`, `Sf_albedo`, `Sx_omask` e, com o MOM6, `Sf_zorl` no MONAN-A com o contorno direto do oceano), estão na tabela `GAPS` do mapa e saem como `AVISO: lacuna conhecida:`, sem interromper. A configuração de produção não tem lacuna. Com `use_datm`, que o driver não registra, a conferência acha diferenças e a rodada para. No mesmo passo, o dicionário do NUOPC passou a ter só os nomes de `FIELDS`, com a unidade de cada um, registrados por `cpl_nuopc_dictionary` (`cpl_check`), e o acréscimo automático foi desligado: um nome fora de `FIELDS` para a rodada no anúncio, com a mensagem do NUOPC.
- **Relatório de acoplamento, no log.** É uma tabela com cada troca, as malhas, o método que o ESMF aceitou, se a rota caiu na reserva e quantos pontos foram completados. Durante a migração, ele serve também de conferência: o relatório de uma etapa tem de ser igual ao da etapa anterior.

### 3.7 Mediador por fases

```fortran
! Inicialização (InitializeDataComplete)
call cria_rotas(is, create='inicio')
call wait_first_sst(is, importState)
! A cada passo (MediatorAdvance)
call go_to_flux_grid(is, importState)           ! OCN e ICE -> atm_med
call compute_fluxes(is%fluxes, clock)           ! física bulk, só arrays
call voltar_para_malha_do_oceano(is)            ! atm_med -> ocn_med
call deliver(is, exportState, clock)            ! exportação e carimbo de tempo
```

Desde a R-FASE11-15, `src/mediator/med_exchange.F90` tem a fase `deliver`, chamada no fim do `MediatorAdvance`, depois da física. A assinatura real é `deliver(is, importState, exportState, clock, stampTime, rc)`: a exportação ainda lê `So_omask` do `importState` na primeira vez (`regrid_land_mask`), e o carimbo dos campos usa o instante que rotula o passo (`stampTime`, de `med_stamp_time`), que no modo concorrente é o fim do passo. A fase faz, nesta ordem: a exportação (`export_to_components`, em `med_export`); `stampTime` em cada campo do `exportState` (`stamp_export_fields`, que estava em `med_export`); e, com `use_med_to_mpas`, o tempo atual do relógio no `exportState` inteiro, que prevalece (o que restava de `RouteOcnToAtm`, em `med_cap_methods`). As mensagens do log continuam com o nome `RouteOcnToAtm`, que o pós-processamento procura.

Desde a R-FASE11-16, `med_exchange` tem também a fase `go_to_flux_grid(is, importState, clock, rc)`, chamada antes da física: a SST, as correntes e, com o SIS2, os campos do gelo (`update_ocean_fields_on_atm_grid`, em `med_ocean`, que usa `med_ice`), e depois a fração de gelo do OISST, com `use_docn_ice` (`update_ice_fraction_from_docn`). O código das interpolações continua em `med_ocean` e `med_ice`; a fase só fixa a ordem e o lugar das chamadas. Desde a R-FASE11-18, todas as rotas são criadas pelas fases de `med_exchange`, guiadas pela coluna `create` de `ROUTES`; `med_ocean`, `med_ice` e `med_export` só as aplicam. Antes de chamar quem aplica, cada fase garante as suas rotas, na ordem que define a das linhas `rota` do relatório de acoplamento:

| Fase | Rota | `create` | Quando é criada |
| --- | --- | --- | --- |
| `initialize_data` | `atm2ocn`, `ocn2atm` | `inicio` | fase A da inicialização (`create_start_routes`) |
| `go_to_flux_grid` | `ocn2atm_sst` | `mascara_mista` | no primeiro passo em que a máscara do oceano gravada na grade (etapa preparar, `set_ocean_mask_for_sst`) tem terra e mar; até lá, a SST usa a `ocn2atm` |
| `go_to_flux_grid` | `ocn2atm_ice` | `primeiro_uso` | com o SIS2, na primeira vez que `Si_ifrac_sis2` está no `importState` (`add_ice_route`, que também grava a máscara) |
| `deliver` | `ocn2atm_landmask` | `primeiro_uso` | na primeira exportação, se `So_omask` está no `importState` |
| `deliver` | `atm2ocn_ice` | `primeiro_uso` | se `Si_ifrac` está no `exportState` e a reserva `atm2ocn` existe |

Desde a R-FASE11-20, a física é a fase `compute_fluxes`, de `med_exchange`: ela associa os arrays de `med_flux_t` (`med_cap_types`, um ponteiro para os valores de cada campo interno que a física lê ou escreve, nulo se o ESMF não o entrega) e chama `calc_bulk_ncar(fluxo, forçantes, limites, relógio, rc)`. `med_bulk_ncar` não conhece mais o estado interno, os campos do ESMF nem as rotas; o plano previa `compute_fluxes(is%fluxo, clock)`, e os arrays ficaram locais à fase, associados a cada passo, sem um componente novo no estado interno.

Desde a R-FASE11-19, uma fase curta roda logo depois da física: `ice_fraction_without_sis2(is, importState, i1, i2, j1, j2)`, que, sem o SIS2 dinâmico, recalcula a fração de gelo na malha de fluxo (`legacy_ice_fraction`, agora em `med_ocean`) para a exportação e para o passo seguinte. Ela não pode ir para `go_to_flux_grid`, antes da física, porque a física deste passo usa a fração que já estava em `is%ice%ifrac`.

A `atm2ocn` deixou de ser criada por `RegridOrCopy` como reserva: ela existe desde a fase A, que roda antes de qualquer chamada, e uma falha ali interrompe a inicialização.

Desde a R-FASE11-17, a inicialização também é uma fase de `med_exchange`: `initialize_data(gcomp, is, importState, exportState, clock, rc)`, chamada pelo `InitializeDataComplete` de `MED_cap`, que pode rodar mais de uma vez no laço de dependência de dados do NUOPC. Ela tem três partes: a fase A, só na primeira passagem (`prepare_start`: as rotas com `criar='inicio'` em `ROUTES`, criadas por `create_start_routes` na ordem da tabela, cada uma com o seu par de campos; as correntes; os valores iniciais do `exportState`); o portão `wait_first_sst`, que só abre quando So_t chegou com valor físico; e a fase B (SST de t=0 publicada, carimbo de `startTime` e `InitializeDataComplete` declarado). Uma rota com `criar='inicio'` sem par de campos em `create_start_routes` é erro: a tabela e a rotina andam juntas.

### 3.8 Esquemas de interpolação

`src/regrid/` continua como está. A migração acrescenta três coisas:

- **Uma base para esquemas de pesos** (`weights_regridder_t`). O esquema escreve só `compute_weights`, com arrays comuns do Fortran; a base cuida do *route handle*, da reprodutibilidade (`srcTermProcessing=0`, `termorder=srcseq`) e da liberação.
- **Opções em texto** (`'expoente=2,vizinhos=4'`), lidas pelo próprio esquema.
- **Uma lista de esquemas** em `regrid_schemes.F90`, com um modelo de esquema e o teste `compara-esquema.bash`.

Feito na R-FASE11-23:

| Peça | Onde | Como ficou |
| --- | --- | --- |
| base de pesos | `regrid_weights_base.F90` | `weights_regridder_t`, com `compute_weights(src_points, dst_points, factors, orig, dest, rc)` diferida. Os pontos são do tipo `regrid_points_t` (longitude e latitude em graus, máscara e índice global, o sequencial do ESMF): a origem inteira em cada processo, ordenada pelo índice, e o destino só com os pontos locais. A base guarda os pesos com `ESMF_FieldSMMStore` (`srcTermProcessing=0`), aplica-os com `ESMF_FieldSMM` (`termorder=srcseq`) e libera o *route handle*. Aceita só `ESMF_Grid` de um tile, com um DE por processo |
| opções em texto | `regrid_base.F90` | `regrid_spec_t%options` (`'chave=valor,...'`), lidas por `regrid_option_real` e `regrid_option_int`, com valor padrão; `regrid_options_check` recusa chave desconhecida. Também no `nuopc.input`, em `regrid_options` do grupo `&nuopc_regrid`. A linha da rota no relatório de acoplamento só mostra as opções quando há alguma |
| lista de esquemas | `regrid_schemes.F90` | uma linha por esquema (nome e construtor, exportado pelo módulo do esquema), entregue ao catálogo (`regrid_registry`) por uma rotina passada como argumento, o que evita dependência circular; a interface `regridder_ctor` passou para `regrid_base` |
| modelo de esquema | `regrid_idw.F90` | esquema `idw` (inverso da distância, opções `vizinhos` e `expoente`), comentado como molde; nenhuma rota o usa |
| teste de esquema | `tests/regrid/compara-esquema.bash` | erro do esquema e de uma referência contra um campo analítico e o mesmo campo, bit a bit, com 1 e com vários processos; conferência `esquemas` do `confere-tudo` |

O `weights_file` não foi reescrito sobre a base: isso mudaria as suas chamadas ao ESMF (leitura própria do arquivo em vez de `ESMF_FieldSMMStore` com o nome do arquivo). O critério "o `weights_file` dá os mesmos pesos" ficou num teste de ida e volta: os pesos do `idw` gravados em arquivo e lidos pelo `weights_file` dão o mesmo campo, bit a bit.

### 3.9 Adaptador do MPAS

Desde a R-FASE11-24, a tradução entre o MONAN-A e o ESMF está num módulo só, `src/caps/atmos/mpas_adapter.F90`. O dado passa em duas etapas, com as estruturas `atm_public` (exportação) e `atm_bnd` (importação), de `mpas_atm_types`, no meio:

| Etapa | Módulos | Usa o ESMF |
| --- | --- | --- |
| campos do MPAS para `atm_public`, e `atm_bnd` para os campos do MPAS | `mpas_atm_setup`, `mpas_atm_fluxes`, `mpas_atm_model` | não |
| `atm_public` para o `exportState`, e o `importState` para `atm_bnd` | `mpas_adapter` | sim |

O adaptador tem a grade do cap (`mpas_create_grid`), a exportação dos 13 campos `*_mpas` (`mpas_export`, das células à grade do cap pela média por caixa) e a importação dos 7 campos do contorno oceânico (`mpas_import`, cada célula com o valor da caixa que a contém), que são as trocas `cap` do mapa, além do acesso aos campos do `ESMF_State` (`find_local_field`, `state_set_field_1d`, `state_get_field_1d`) e do diagnóstico `state_diagnose`. O algoritmo da média por caixa (`map_cells_to_regular_grid` e as suas etapas) continua em `mpas_cell_binning`, sem acesso ao `ESMF_State`. Os nomes dos campos continuam escritos no adaptador; o teste do mapa confere que as trocas `cap` são exatamente as exportações e as importações do MONAN-A, e a conferência das constantes de texto, que os nomes não mudam.

---

## 4. Plano de migração: fase 11

### 4.1 Regras

As mesmas das fases 1 a 9:

1. **Nenhuma etapa muda resultados.** Cada uma é validada contra a R-NOFMA-02 (73 arquivos, bit a bit) com `tools/dev/valida_rodada.bash` e recebe a tag `fase11-NN-validada`.
2. **Um patch por etapa**, com um único commit (`R-FASE11-NN.patch`), autor Daniel Massaru, `head -1` e `md5sum` informados.
3. **Conferências locais antes de entregar**: `confere-tudo.bash -i HEAD`, com as diferenças esperadas declaradas no CHANGELOG.
4. **Documentação a cada etapa**: CHANGELOG, `estado-do-projeto.md`, `roteiro-codigo-limpo.md` e, nesta fase, este documento; README quando houver funcionalidade nova.
5. **Etapas pequenas.** Uma etapa mexe num assunto; se tocar muitos módulos, divide-se.

### 4.2 Conferências por tipo de mudança

Cada tipo de mudança tem uma forma de confirmar, antes da rodada, que nada mudou:

| Tipo de mudança | Conferência local | Conferência na Jaci, além da comparação bit a bit |
| --- | --- | --- |
| só documentação | nenhuma compilação muda | não precisa de rodada; tag depois do `git am` |
| código novo que só registra no log | compilação; teste unitário das tabelas; literais novos declarados | relatório de acoplamento presente e coerente |
| nomes de campos saindo das listas dos caps para o mapa | `confere-literais.py`: os nomes só mudam de arquivo; ordem idêntica conferida por teste | log do conector (`CplList`) igual ao da etapa anterior |
| fórmula movida para `cpl_grids` | código de máquina comparado (`objdump`), como na R-FASE9-02: só números de linha diferem; testes `grade`, `malhas` e unitários. Quando a expressão muda de texto sem mudar de valor (na R-FASE11-08, o tamanho da célula do cap atmosférico passou da constante 1 para 360/nx, que dá exatamente 1), o `objdump` não serve, e vale o teste `malhas`, que compara as coordenadas bit a bit em várias decomposições | |
| construção de malha movida | teste do supergrid (`tests/supergrid/compara-supergrid.bash`, conferência `supergrid`): dimensões, coordenadas e mensagens idênticas bit a bit; a partir da R-FASE11-10, estendido aos blocos | relatório de acoplamento igual |
| configuração de rota movida para `ROUTES` | teste de interpolação (`tests/regrid`); comparação da configuração efetiva de cada rota, antes e depois | relatório de acoplamento igual (métodos, reservas, pontos completados) |
| chamadas movidas entre módulos | `confere-instrucoes.py` sobre a soma dos arquivos: só estrutura de módulo muda; teste da física bulk | relatório de acoplamento igual |
| DOCN ou DATM | teste do DOCN num driver NUOPC (`tests/docn/compara-docn.bash`, conferência `docn`); DATM pela compilação | |

A partir da etapa que cria o relatório de acoplamento (R-FASE11-04), `valida_rodada.bash compara` passa a extrair o relatório do log e compará-lo com o da última rodada validada. Uma diferença ali aponta o problema antes da comparação dos arquivos. O relatório tem quatro partes: configuração e conectores, conferência do mapa (R-FASE11-03), rotas na criação e pontos completados por vizinhança no último passo (R-FASE11-04 e R-FASE11-04-FIX01); o formato está em `docs/validacao-refatoracao.md`, seção 2.1. Os pontos completados são contados onde o preenchimento roda hoje, fora das rotas, com o nome `rota campo`; quando a R-FASE11-14 levar o preenchimento para dentro da rota, as linhas têm de sair iguais.

### 4.3 Etapas

As etapas estão agrupadas em seis blocos. Os blocos A e B dão visibilidade sem tocar em cálculo; C e D reorganizam malhas e rotas; E reorganiza o mediador; F fecha a fase.

**Bloco A: descrição do acoplamento, sem efeito no cálculo**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-01 | este documento em `docs/arquitetura-acoplamento.md`; fase 11 no roteiro; estado do projeto; indicadores da fase acrescentados a `indicadores.py` (ver 4.4) | só documentação e ferramenta | resultado de `indicadores.py` em `fase9-07-validada` registrado como partida |
| R-FASE11-02 | `cpl_fields.F90` (`FIELDS`) e `cpl_map.F90` (`EXCHANGES` e `ROUTES` descrevendo o acoplamento de hoje, com as quatro configurações); teste unitário `test_cpl_map` (consistência interna: toda troca tem campo em `FIELDS`, toda rota citada existe, toda importação tem uma única origem em cada configuração); `tools/dev/mapa-acoplamento.py`, que gera `docs/acoplamento.md` | módulos compilados e ligados, mas não chamados | teste unitário; o mapa gerado confere com o Apêndice A |
| R-FASE11-03 | `cpl_check`: conferência do mapa contra os campos anunciados, chamada pelo driver em `ModifyCplLists`, só com registro no log; relatório dos conectores (campos e opções de cada `CplList`) | só escreve no log | a conferência não acusa diferença na configuração de produção |
| R-FASE11-04 | relatório das rotas do mediador (método aceito, reserva, pontos completados), gravado depois da criação de cada rota; extração e comparação do relatório em `valida_rodada.bash compara` | só escreve no log | relatório igual em duas rodadas da mesma revisão |

**Bloco B: listas de campos a partir do mapa**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-05 | anúncio dos campos do mediador (`import_mpas_names`, `import_datm_names`, `export_names` e os campos realizados à mão em `realize_component_fields`) lido de `EXCHANGES` | mesmos nomes, na mesma ordem, nas mesmas fases | teste compara a lista gerada com a de hoje, nome a nome; literais só mudam de arquivo |
| R-FASE11-06 | idem para os caps do MOM6 e do SIS2 | idem | idem; relatório dos conectores igual |
| R-FASE11-07 | idem para os caps do MONAN-A, do DOCN e do DATM | idem | idem; teste do DOCN |

**Bloco C: malhas**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-08 | `cpl_grids` com `malha_latlon` e as fórmulas de centro e índice; `atm_med` e `atm_cap` construídas por ele | mesmas coordenadas, mesma decomposição, mesmas expressões | `objdump`; testes `grade` e unitários |
| R-FASE11-09 | fórmulas de índice de `bin_cells_local`, `copy_to_local_grid`, `state_get_field_1d`, `check_ice_geography`, `oisst_to_atm_nearest` e dos dois gravadores de diagnóstico passam a vir de `cpl_grids` (uma função por regra de arredondamento) | cada função reproduz a expressão de hoje | `objdump`; testes `grade`, `gravadores` e unitários |
| R-FASE11-10 | `cpl_blocks_t` e `malha_tripolar`; `ocn_med` e `ice_sis2` construídas por ele | mesma leitura, normalização e blocos | teste do supergrid, estendido aos blocos: coordenadas e blocos idênticos bit a bit |
| R-FASE11-11 | `ocn_mom6` por um construtor próprio de `cpl_grids` (`cpl_block_grid`), com as chamadas do ESMF de hoje e as coordenadas do modelo, passadas pelo cap. Redefinida antes da etapa: o plano original (por `malha_tripolar`, se as coordenadas coincidissem) mudaria resultados, porque a grade do cap não declara periodicidade e usa índices locais (ver seção 3.3) | mesmas chamadas, mesmos blocos, mesmas coordenadas | grade comparada com a construção de antes num programa de teste (`tests/malhas`); rodada na Jaci |

**Bloco D: rotas**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-12 | `create_route(regrid, nome, src, dst, rc)` (no mediador) cria a rota com a configuração de `ROUTES`; as chamadas de hoje perdem a configuração, mas continuam nos mesmos pontos; `set_ocn_grid_mask` substitui os dois trechos que copiam a máscara. O plano previa a busca dentro de `regrid_manager%add`; ficou fora do framework de interpolação, que não conhece o mapa (seção 3.5) | mesmos métodos, máscaras, reservas e momento de criação | configuração lida da tabela comparada com a de cada chamada de antes (`test_routes`); relatório de acoplamento igual |
| R-FASE11-13 | etapas preparar e limitar executadas pela rota: `no_value` substitui os `zero_total` passados nas chamadas; `nan_to` substitui o tratamento em `RegridOrCopy`. As sentinelas continuam explícitas, porque o preenchimento vale mesmo quando a rota não é aplicada (seção 3.5) | mesma sequência de operações sobre cada campo | teste de interpolação (com a reserva); configuração de cada rota comparada (`test_routes`); relatório igual |
| R-FASE11-14 | etapa completar executada pela rota onde segue a interpolação (SST e fração de gelo exportada); no gelo, continua explícita | mesma sequência de operações | teste novo dos campos completados (`tests/completar`), no lugar do teste da física bulk, que não passa por esses caminhos; teste de interpolação; relatório igual (pontos completados) |

**Bloco E: mediador por fases e física em arrays**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-15 | `med_exchange.F90` com a fase `deliver`: exportação (`RegridOrCopy` e `med_export`) e carimbo de tempo num lugar só; `RouteOcnToAtm` sai | mesmas chamadas, na mesma ordem | `confere-instrucoes.py` sobre a soma; relatório igual |
| R-FASE11-16 | fase `go_to_flux_grid`: interpolações de `med_ocean` e `med_ice` | idem | idem |
| R-FASE11-17 | fase de inicialização (`create_start_routes`, guiada pela coluna `create`, e `wait_first_sst`), com as rotas de `InitializeDataComplete` | idem; mesma sequência do laço de dependência de dados | idem; `tests/completar` com a fase A nova |
| R-FASE11-18 | rotas criadas durante o passo pelas fases de `med_exchange`, guiadas pela coluna `create` (`primeiro_uso` e `mascara_mista`, com a etapa preparar da máscara); `med_ocean`, `med_ice` e `med_export` só aplicam rotas. Etapa acrescentada na R-FASE11-17 (seção 6); as seguintes foram renumeradas | mesmas criações, no mesmo passo, na mesma condição e na mesma ordem das operações coletivas | `confere-instrucoes.py`; `tests/completar`, estendido com o SIS2; relatório igual (linhas `rota`) |
| R-FASE11-19 | a interpolação da fração de gelo sai de `calc_bulk_ncar` e vai para imediatamente depois da chamada (fase `ice_fraction_without_sis2`, de `med_exchange`). O plano dizia "antes", o que mudaria resultados sem o SIS2: a física lê `is%ice%ifrac` antes de o trecho recalculá-la | mesma sequência de operações | teste da física bulk, que chama a fase logo depois de `calc_bulk_ncar` |
| R-FASE11-20 | física em arrays: tipo `med_flux_t`; `med_bulk_ncar` sem estados nem rotas | mesmas expressões, na mesma ordem | teste da física bulk; testes de valor esperado |

**Bloco F: conectores, esquemas, adaptador do MPAS e encerramento**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-21 | driver escolhe os conectores a partir de `EXCHANGES` e da coluna `when` | os mesmos pares de componentes em cada configuração | relatório dos conectores igual nas configurações de produção e DOCN |
| R-FASE11-22 | método de cada campo escrito no `CplList`, se o relatório da R-FASE11-03 mostrar que o padrão de hoje é o bilinear com as opções que serão escritas; senão, a etapa só documenta e fica como decisão da fase 10 | o conector recebe explicitamente o que recebe por padrão | relatório dos conectores igual |
| R-FASE11-23 | `weights_regridder_t`, opções em texto, `regrid_schemes.F90`, modelo de esquema e `compara-esquema.bash` | os esquemas existentes fazem as mesmas chamadas ao ESMF | `tests/regrid`; o `weights_file` dá os mesmos pesos |
| R-FASE11-24 | adaptador do MPAS: a tradução entre o modelo e o ESMF reunida num módulo, com as trocas `cap` declaradas no mapa | código movido, sem mudar operações | `confere-instrucoes.py`; teste `grade` |
| R-FASE11-25 | conferência passa a interromper a rodada em caso de diferença; dicionário do NUOPC com os nomes de `FIELDS` e acréscimo automático desligado | só muda o comportamento quando há erro | rodada normal igual; uma rodada com um nome errado de propósito tem de parar com a linha do mapa |
| R-FASE11-26 | encerramento: documentação e indicadores finais; o cap do MOM6 carimba o tempo por `cap_stamp_export` (último indicador na meta); NTC e RPQ, que ficam fora do repositório, atualizados à parte | mesmas chamadas ao NUOPC, na mesma ordem | `confere-instrucoes.py`; relatório igual |

Ordem e dependências: A antes de tudo; B depois de A; C e D podem alternar; E depois de D; F no fim. As etapas 11 e 21 dependem de uma conferência na Jaci e podem virar só documentação, se a conferência mostrar que a mudança não é neutra.

### 4.4 Indicadores e metas

`indicadores.py` mede, desde a R-FASE11-01, os indicadores desta fase numa segunda tabela (a regra de cada contagem está em `docs/conferencias-locais.md`, seção 2.7). A coluna "Hoje" traz os valores medidos em `fase9-07-validada`, exceto as fórmulas de índice e as trocas sem linha no mapa, conferidas à mão. Cada etapa registra os valores antes e depois no CHANGELOG.

| Indicador | Hoje | Meta | Fim da fase 11 (R-FASE11-26) |
| --- | --- | --- | --- |
| arquivos com nomes de campos anunciados ou realizados escritos à mão | 8 (os caps do MONAN-A, MOM6, SIS2, DOCN e DATM; `MED_cap`, `med_cap_types` e `med_init`) | 0 | 0 |
| construções de malha ESMF fora de `cpl_grids` | 7 chamadas `ESMF_GridCreate*` em 6 arquivos | só as do DOCN e do DATM, se não migradas | 2 chamadas, em `DOCN_cap` e `DATM_cap` |
| rotas criadas fora de `med_exchange` | 7 pontos em 5 arquivos | 0 | 0 |
| chamadas de rota em módulos de física | 1 (`med_bulk_ncar`) | 0 | 0 |
| fórmulas de índice de grade regular fora de `cpl_grids` | 9 rotinas | 0 | 0 (R-FASE11-09; conferido à mão) |
| arquivos que carimbam o tempo dos campos | 5 (`cap_common`, `mom_cap_MONAN`, `MED_cap`, `med_export`, `med_cap_methods`) | `cap_common` e `med_exchange` | `cap_common` e `med_exchange` (o cap do MOM6 passou a usar `cap_stamp_export` na R-FASE11-26) |
| trocas sem linha no mapa | todas | 0 | 0 (as trocas `cap` do MONAN-A conferidas desde a R-FASE11-24) |

Na `fase9-07-validada`, `indicadores.py` mede 6 rotas criadas fora de `med_exchange`, em 4 arquivos; a coluna "Hoje" desta linha foi contada à mão, antes do script.

### 4.5 Pronto quando

- a conferência do mapa está ativa e interrompe a rodada em caso de diferença;
- os indicadores da seção 4.4 estão nas metas;
- o relatório de acoplamento da última etapa é igual ao da R-FASE11-04;
- todas as etapas reproduziram a R-NOFMA-02, com tag.

Situação no fim da fase (R-FASE11-26):

| Critério | Situação |
| --- | --- |
| conferência ativa e interrompendo a rodada | cumprido desde a R-FASE11-25; as lacunas conhecidas, na tabela `GAPS`, saem como aviso |
| indicadores nas metas | cumprido na R-FASE11-26, com o carimbo de tempo do MOM6 (tabela da seção 4.4) |
| relatório igual ao da R-FASE11-04 | cumprido com um desvio aprovado: a R-FASE11-22 escreveu o método de cada campo na `CplList`, e as 60 linhas de campo dos conectores ganharam `:remapmethod=bilinear` (as 6 linhas do método padrão saíram). Fora isso, o relatório é o da R-FASE11-04, e foi igual de uma etapa para a seguinte em todas as outras |
| todas as etapas com PASS e tag | cumprido: 26 etapas e a R-FASE11-04-FIX01, cada uma com a sua tag `fase11-NN-validada` (`fase11-04-fix01` na correção) |

### 4.6 Riscos e cuidados

- **Momento de criação das rotas.** Os pesos dependem da máscara no momento da criação. A coluna `create` reproduz o momento de hoje; nenhuma etapa muda quando uma rota é criada.
- **Ordem das operações.** Mover uma etapa de uma rota só é seguro se a sequência de operações sobre o campo não mudar. Onde houver diagnóstico no meio (gelo), a etapa fica explícita.
- **Ordem dos campos anunciados.** As listas geradas do mapa mantêm a ordem de hoje. Isso é conferido por teste, porque a ordem define a ordem dos campos no `CplList`.
- **Compilação com `-fdefault-real-8`.** Os caps do MOM6 e do SIS2 são compilados com essa opção. Os módulos de `src/coupling/` declaram `kind` explícito em tudo e ficam fora de `MOM6_SRCS`.
- **Dependências de compilação.** Todo módulo novo entra no `Makefile`, em `compila-local.bash` e nas listas de objetos dos testes, como nas fases 8 e 9.
- **Relatório de acoplamento como texto.** As linhas do relatório são constantes de texto novas. Os scripts de análise não as procuram, e o relatório tem um prefixo próprio (`CPL-REL:`) para facilitar a extração.

---

## 5. Decisões que mudariam resultados (fase 10)

A arquitetura torna visíveis escolhas que hoje estão escondidas. Estas entram na trilha de decisões da fase 10, cada uma com etapa própria e nova linha de base:

| Hoje | Alternativa |
| --- | --- |
| os campos para a atmosfera vão da malha de fluxo para a do oceano (vizinho mais próximo) e voltam a uma malha da atmosfera pelo conector | exportar esses campos em `atm_med` |
| conectores interpolam entre representações da mesma malha (`atm_cap` e `atm_med`; `ocn_mom6`, `ice_sis2` e `ocn_med`) | mesma malha dos dois lados e `remapMethod=redist` |
| passagem entre as células do MPAS e a grade do cap com código próprio | malha `mpas` pelo catálogo e rota com o esquema `mpassit`, quando o `ESMF_Mesh` puder ser usado com o MPAS |
| fração de gelo do OISST pelo ponto mais próximo, com código próprio | OISST como malha do catálogo e rota conservativa |
| três regras de arredondamento para o índice de uma grade regular | uma regra só |

---

## 6. Próximo passo

A R-FASE11-01 trouxe este documento para o repositório, registrou a fase 11 no roteiro e no estado do projeto, acrescentou os indicadores da fase a `indicadores.py` e levou para o repositório os testes do supergrid e do DOCN, que eram avulsos.

A R-FASE11-02 escreveu o mapa: `src/coupling/cpl_fields.F90` (57 campos) e `src/coupling/cpl_map.F90` (8 malhas, 154 trocas, 6 rotas), o teste `tests/unit/test_cpl_map.F90`, que confere o mapa nas cinco combinações de `&nuopc_mode` e contra as listas do mediador, e `tools/dev/mapa-acoplamento.py`, que gera `docs/acoplamento.md`. Os módulos são compilados e ligados, mas nenhum componente os usa. Com isso, o indicador "trocas sem linha no mapa" vai a 0. Ao escrever o mapa, a coluna `when` ganhou as condições dos dois valores de cada chave e a lista de condições, e a coluna `create` ganhou `primeiro_uso` (seção 3.5).

A R-FASE11-03 criou `src/coupling/cpl_check.F90`, chamado pelo `ModifyCplLists` do driver: relatório dos conectores e conferência do mapa no log do PET 0, com o prefixo `CPL-REL:`, sem interromper a rodada (seção 3.6). Na configuração de produção, num driver NUOPC de teste com as listas de hoje, a conferência dá 0 diferenças e 3 avisos (o MOM6 exporta `So_s`, `Fioo_q` e `Si_ifrac`, que ninguém consome). No mesmo teste, a CplList saiu em ordem alfabética, e não na ordem do anúncio; se o log da Jaci confirmar, o cuidado da seção 4.6 sobre a ordem dos campos anunciados vale para os estados, não para os conectores.

A R-FASE11-04 fechou o bloco A: o relatório de acoplamento ganhou uma linha por rota do mediador, escrita na criação (esquema, métodos, máscara, método aceito ou reserva usada), e uma linha por campo completado por vizinhança, com a soma dos PETs; `valida_rodada.bash compara` grava o relatório em `relatorio_acoplamento.txt` e o compara com o da rodada aprovada mais recente. Na rodada de validação, as três rotas que pedem `conserve,bilinear` ou `conserve,nearest_stod` (`ocn2atm_sst`, `ocn2atm_ice`, `atm2ocn_ice`) aceitaram o conservativo, e nenhuma caiu na reserva; é o que `ROUTES` descreve. As linhas dos pontos completados não saíram, porque a R-FASE11-04 as escrevia na finalização do mediador, que o programa principal não chama (`esmApp.F90` não chama `ESMF_GridCompFinalize`); a R-FASE11-04-FIX01 as passa para o último passo do mediador.

A R-FASE11-05 abriu o bloco B: o mediador anuncia e realiza os campos a partir do mapa (`cpl_arrivals`, seção 3.5), e as listas `import_mpas_names`, `import_datm_names` e `export_names` saíram de `med_cap_types`, assim como os anúncios e as realizações escritos um a um em `MED_cap` e `med_init`. As listas geradas são iguais às de antes, nome a nome e na mesma ordem, nas cinco configurações do teste; o mediador real, num driver NUOPC de teste, deu o mesmo relatório de acoplamento antes e depois em quatro configurações. Arquivos com nomes de campos escritos à mão: de 8 para 5 (os caps).

A R-FASE11-06 fez o mesmo nos caps do MOM6 e do SIS2. Para a exportação dos modelos, que `EXCHANGES` não descreve por inteiro, entrou a tabela `EXPORTS` (seção 3.5), com os cinco modelos; os caps do MONAN-A, do DATM e do DOCN ainda não a usam, mas o teste do mapa já a confere contra as listas deles. Arquivos com nomes de campos escritos à mão: de 5 para 3.

A R-FASE11-07 fechou o bloco B com os caps do MONAN-A, do DOCN e do DATM. Os valores iniciais da importação do MONAN-A, que dependiam da posição de cada campo em `IMP_NAMES`, e os da exportação do DOCN passaram a ser escolhidos pelo nome do campo. O teste do DOCN, que roda o cap num driver NUOPC, deu resultado idêntico. Arquivos com nomes de campos escritos à mão: de 3 para 0, a meta do bloco.

A R-FASE11-08 abriu o bloco C: `src/coupling/cpl_grids.F90` constrói as malhas `atm_med` (malha de fluxo do mediador) e `atm_cap` (grade do cap atmosférico) por `cpl_latlon_grid`, com a decomposição `cpl_regdecomp`, que estava escrita duas vezes, e com as fórmulas de centro e de canto de cada malha numa função cada uma (seção 3.3). As coordenadas e a decomposição ficaram idênticas, bit a bit, com 1, 4, 6 e 8 processos (teste novo `tests/malhas`, conferência `malhas`). Chamadas `ESMF_GridCreate*` fora de `src/coupling`: de 7 para 5.

A R-FASE11-09 levou para `cpl_grids` as fórmulas de índice e de longitude das sete rotinas da tabela do bloco C e do cap do MOM6 (seção 3.3). Como a fórmula passa a ser chamada de função em outro módulo, o `objdump` não se aplica; a conferência foi o teste unitário, que compara cada função com a expressão que ela substituiu em cerca de 820 mil coordenadas, além dos testes `grade` e `gravadores`. O teste mostrou que o índice por piso e o por truncamento são iguais depois do limite a [1, n] (uma função só) e que a soma única de 360 não equivale ao laço (a cópia do cap manteve a sua).

A R-FASE11-10 construiu por `cpl_grids` as malhas do oceano no mediador (`ocn_med`, com o MOM6 e com o DOCN) e do SIS2 (`ice_sis2`), com o construtor `cpl_tripolar_grid` e os blocos `cpl_blocks_t` (seção 3.3). O teste `malhas` passou a comparar também `ocn_med` nas duas configurações, com um supergrid sintético e 1, 4, 6 e 8 processos; como o cap do SIS2 só roda com o modelo, a malha `ice_sis2` foi comparada, no mesmo programa, com uma cópia da construção de antes, com blocos em ordem x mais rápido e y mais rápido, e a montagem dos blocos com a rotina de antes em onze layouts, válidos e inválidos. Chamadas `ESMF_GridCreate*` fora de `src/coupling`: de 5 para 3 (MOM6, DOCN e DATM). Uma peculiaridade apareceu e foi preservada: com o DOCN, a longitude do centro de `ocn_med` está no canto oeste da célula.

A R-FASE11-11 fechou o bloco C com a grade do cap do MOM6, construída por `cpl_block_grid` com as mesmas chamadas do ESMF e as coordenadas do modelo. A etapa foi redefinida antes de começar, com a concordância do Daniel: a grade do cap não declara periodicidade e usa índices locais, e construí-la por `cpl_tripolar_grid` mudaria os pesos do conector OCN para MED, mesmo com coordenadas iguais; o diagnóstico na Jaci previsto no plano deixou de ser necessário (seção 3.3). Chamadas `ESMF_GridCreate*` fora de `src/coupling`: de 3 para 2 (DOCN e DATM), a meta do bloco.

A R-FASE11-12 abriu o bloco D: as seis rotas do mediador, nos sete pontos de criação de hoje, passam a ser criadas por `create_route`, com a configuração lida de `ROUTES` (seção 3.5), e `set_ocn_grid_mask` (`med_cap_methods`) substitui os dois trechos que copiavam `So_omask` para a máscara da grade do oceano (`add_ice_route` e `set_ocean_mask_for_sst`). Um teste unitário novo (`test_routes`) confere, campo a campo, que a configuração lida da tabela é a que cada chamada passava. O indicador de pontos de criação de rota passou a contar as chamadas a `create_route` (continua 7 pontos em 5 arquivos).

A R-FASE11-13 passou para a rota o tratamento dos pontos sem valor (`no_value`, no lugar dos `zero_total` das onze chamadas de interpolação) e a troca de NaN (`nan_to`, no lugar do tratamento em `RegridOrCopy`). O `regrid_manager` passou a guardar a configuração de cada rota, para que uma rota que usa a interpolação da reserva mantenha as próprias opções; o teste do framework de interpolação ganhou casos com reserva que confirmam isso. As sentinelas continuaram explícitas (seção 3.5).

A R-FASE11-14 fechou o bloco D: a etapa completar passou a ser executada pela rota na SST e na fração de gelo exportada (seção 3.5). O preenchimento, que `regridder_t%apply` fazia com as opções da rota que interpola e só no primeiro DE local, sem uso por nenhuma rota, foi para o `apply` do `regrid_manager`, com as opções da rota pedida, em todos os DEs locais e com as contagens do relatório. A conferência prevista (o teste da física bulk) não passa por esses caminhos; ficou no lugar dela um teste de regressão novo (`tests/completar`), que monta o mediador e compara a SST e todos os campos exportados ao oceano, bit a bit, com 1, 4, 6 e 8 processos, incluindo o passo em que a máscara do oceano ainda é uniforme.

A R-FASE11-15 abriu o bloco E: `med_exchange.F90` com a fase `deliver` (seção 3.7). A exportação e o carimbo de tempo dos campos do mediador ficaram num lugar só, e `RouteOcnToAtm` saiu (restava nela só o carimbo pelo relógio). As instruções são as mesmas, conferidas na soma dos quatro arquivos; saiu só código morto (um ponteiro sem uso e o argumento `importState` de `RouteOcnToAtm`). O teste `tests/completar` passou a gravar também o carimbo de tempo de cada campo exportado, com e sem `use_med_to_mpas`. Arquivos que carimbam o tempo dos campos: de 5 para 4 (`cap_common`, `mom_cap_MONAN`, `MED_cap`, na inicialização, e `med_exchange`).

A R-FASE11-16 acrescentou a fase `go_to_flux_grid` a `med_exchange` (seção 3.7), com as duas chamadas que o `MediatorAdvance` fazia entre a reunião dos forçantes e a física, na mesma ordem. O teste `tests/completar` passou a chamar a fase na versão que a tem. Fica uma decisão para a R-FASE11-17: das 7 criações de rota fora de `med_exchange`, 2 são da inicialização e vão com a fase de inicialização; as outras 5 são feitas durante o passo, na primeira vez que a rota é usada ou quando a máscara do oceano passa a ter terra e mar. Levá-las para `med_exchange` exige mover junto as regras de quando criar cada uma (uma etapa própria, guiada pela coluna `create` de `ROUTES`), ou a meta do indicador passa a ser 5.

A R-FASE11-17 levou a inicialização do mediador para `med_exchange` (seção 3.7): `InitializeDataComplete` passou a só obter os estados e chamar `initialize_data`, e as rotinas `idc_*` de `MED_cap` e `med_init` mudaram de arquivo sem mudar instruções. As rotas da inicialização passaram a ser criadas pela tabela (`criar='inicio'`). Arquivos que carimbam o tempo dos campos: de 4 para 3 (`cap_common`, `mom_cap_MONAN` e `med_exchange`); criações de rota fora de `med_exchange`: de 7 para 5.

Decisão tomada na R-FASE11-17, com a concordância do Daniel: as cinco rotas criadas durante o passo também passam para as fases de `med_exchange`, guiadas pela coluna `create`, em vez de baixar a meta do indicador. Com isso, `ROUTES` descreve a vida inteira de cada rota (preparar, criar, interpolar, completar, limitar) e `med_exchange` é o único lugar que a executa; `med_ocean`, `med_ice` e `med_export` só aplicam rotas. Como `med_exchange` usa `med_ocean`, a criação tem de acontecer na fase, antes de ela chamar quem aplica a rota. A etapa nova é a R-FASE11-18; as seguintes foram renumeradas (R-FASE11-19 a R-FASE11-26).

A R-FASE11-18 levou as cinco criações de rota feitas durante o passo para as fases de `med_exchange` (seção 3.7). As rotinas de preparação (`set_ocean_mask_for_sst`, de `med_ocean`, e `add_ice_route`, de `med_ice`) mudaram de arquivo sem mudar instruções; a criação da `ocn2atm_landmask` foi separada da aplicação, em `med_export`; a criação de reserva da `atm2ocn` em `RegridOrCopy`, nunca alcançada, saiu. Criações de rota fora de `med_exchange`: de 5 para 0, a meta. A criação passou a acontecer no início da fase, no mesmo passo e na mesma condição de antes, e na mesma ordem entre as rotas; mudou de lugar no log só um diagnóstico e algumas mensagens informativas. O teste `tests/completar` passou a rodar com o SIS2 ligado, como na produção, e com um caso em que todas as rotas do passo são criadas no passo 1, para conferir a ordem entre elas; as linhas do relatório de acoplamento são comparadas na ordem, e as demais mensagens, em qualquer ordem.

A R-FASE11-19 tirou de `calc_bulk_ncar` a última chamada de rota da física: a fração de gelo sem o SIS2 (`legacy_ice_fraction`) foi para `med_ocean`, sem mudar instruções, e passou a ser chamada pela fase `ice_fraction_without_sis2`, de `med_exchange`, logo depois da física. O plano dizia "imediatamente antes"; isso mudaria resultados sem o SIS2, porque a física lê `is%ice%ifrac` (albedo e fluxos sobre o gelo) antes de o trecho recalculá-la, e a etapa seguiu a posição de hoje. Chamadas de rota em módulos de física: de 1 para 0, a meta; o maior arquivo deixou de passar de 1000 linhas.

A R-FASE11-20 passou a física bulk para arrays: o tipo `med_flux_t` reúne os 35 campos que `med_bulk_ncar` lê ou escreve, a fase `compute_fluxes` (`med_exchange`) os associa e chama `calc_bulk_ncar`, e as 43 chamadas a `ESMF_FieldGet` da física viraram associações de ponteiro. As expressões e a ordem das operações não mudaram, e o teste da física bulk deu resultado idêntico, bit a bit. Com isso fecha o bloco E.

A R-FASE11-21 abriu o bloco F: o driver passou a registrar os conectores pelo mapa (seção 3.5), no lugar das condições sobre `use_med_to_mpas` e o SIS2. A escolha nova dá os mesmos conectores, na mesma ordem, nas doze configurações válidas (teste unitário `test_connectors`, com as condições de antes copiadas).

A R-FASE11-22 escreveu o método de cada campo no `CplList` (seção 3.5). A condição da etapa foi conferida antes: o relatório dos conectores validado na Jaci mostrava todas as entradas sem `remapmethod` (só `termorder=srcseq` e `srcTermProcessing=0`), e o fonte do conector no ESMF 8.9.1 (`NUOPC_Connector.F90`) usa, sem a opção, o bilinear, sem tratamento dos polos, com `unmappedaction=ignore`, sem extrapolação e sem máscaras. A coluna `method` de `EXCHANGES` recebeu `bilinear` nas 93 trocas por conector, o driver passou a escrever `remapmethod=bilinear` em cada entrada, e a conferência do mapa passou a conferir o método. O relatório de acoplamento muda de propósito: cada linha de campo dos conectores ganha `:remapmethod=bilinear`, e a linha `metodo: padrao do conector (sem remapmethod na CplList)` sai de cada conector.

A R-FASE11-23 completou o framework de interpolação com o que a seção 3.8 previa: a base dos esquemas de pesos, as opções em texto, a lista de esquemas, o modelo `idw` e o teste `compara-esquema.bash`. Os esquemas `esmf`, `weights_file` e `mpassit` só ganharam o construtor exportado, para a lista; as chamadas ao ESMF não mudaram, e nenhuma rota de `ROUTES` mudou de esquema. Desvio do plano, combinado antes da etapa: o `weights_file` continua com a sua implementação (ver seção 3.8).

A R-FASE11-24 reuniu a tradução entre o MONAN-A e o ESMF no adaptador do MPAS (seção 3.9): `mpas_cap_methods.F90` virou `mpas_adapter.F90`, e `find_local_field` e `state_set_field_1d` saíram de `mpas_cell_binning`, que ficou só com o algoritmo da média por caixa. As instruções são as mesmas, conferidas na soma dos arquivos (mudaram só as linhas de `module`, `use` e `public`). As trocas `cap` já estavam declaradas no mapa desde a R-FASE11-02; o teste do mapa passou a conferir que elas são as exportações e as importações do MONAN-A. Ficaram de fora, de propósito, as duas constantes de π locais do adaptador (trocá-las pelas de `coupler_constants` mudaria o último bit) e limpezas de forma (desalocações repetidas, indentação herdada dos BLOCK).

A R-FASE11-25 tornou a conferência do mapa uma barreira (seção 3.6): uma diferença interrompe a inicialização, depois do relatório inteiro. Antes, as lacunas conhecidas das configurações com o DOCN, que a conferência acusava como diferença, foram para a tabela `GAPS` do mapa e passaram a sair como aviso; a lista que estava copiada no `test_cpl_map` saiu. O `test_cpl_check` passou a montar, nas doze configurações válidas, os estados e as `CplList` como a rodada os monta: sem o DATM, nenhuma diferença, e cada lacuna aparece como aviso. O dicionário do NUOPC passou a ter só os nomes de `FIELDS`, sem acréscimo automático; o critério do plano, "uma rodada com um nome errado de propósito tem de parar", ficou no teste `cplcheck` (casos `defeito` e `dicionario`), porque provocá-lo na Jaci exigiria mudar o código. Mudança de comportamento só em erro: com `use_datm`, que o driver não registra, a rodada agora para na conferência.

A R-FASE11-26 encerrou a fase 11. Única mudança de código: o cap do MOM6 deixou de carimbar o tempo dos campos exportados com dois laços próprios e passou a chamar `cap_stamp_export`, de `cap_common`, que faz as mesmas chamadas, na mesma ordem; com isso, o último indicador chegou à meta (seção 4.4). O resto da etapa é documentação: os valores finais dos indicadores, o "pronto quando" item por item (seção 4.5) e este resumo.

**Estado no fim da fase 11.** O acoplamento está descrito num lugar só, `src/coupling/`: as malhas regulares e as fórmulas de índice (`cpl_grids`), os 59 campos (`cpl_fields`), as trocas, as exportações, as lacunas conhecidas, as rotas do mediador e os conectores do driver (`cpl_map`), e o registro no NUOPC, o método dos conectores e a conferência (`cpl_check`). Os caps e o mediador anunciam e realizam os campos a partir do mapa; o driver registra os conectores a partir dele; o mediador cria e aplica as rotas pela tabela `ROUTES`, em fases (`med_exchange`), e a física bulk trabalha só com arrays; a tradução entre o MONAN-A e o ESMF está no adaptador do MPAS; o framework de interpolação aceita esquemas escritos só com pesos, com opções em texto. Na inicialização, a conferência compara o mapa com o que os componentes anunciaram e interrompe a rodada em caso de diferença, e o dicionário do NUOPC só aceita os nomes de `FIELDS`. Nenhum resultado mudou: todas as etapas reproduziram, bit a bit, os 73 arquivos da linha de base R-NOFMA-02.

**Ficam para depois.** As decisões que mudariam resultados (seção 5) são da fase 10, cada uma com etapa própria e linha de base nova; entre elas, a passagem para `redist` nos conectores entre representações da mesma malha, que agora é uma linha da coluna `method` do mapa. O DATM continua descrito no mapa e não registrado pelo driver (decisão pendente do GT); com `use_datm`, a conferência interrompe a rodada. Limpezas de forma no adaptador do MPAS, que mudariam o último bit (as constantes de π locais) ou só a aparência (desalocações repetidas, indentação herdada dos BLOCK), ficaram de fora de propósito. O passo seguinte natural, como no fim da fase 9, é integrar o ramo `refactor/principal` ao `develop`.

---

## Apêndice A. Trocas de campos na configuração de produção

| Conector | Campos |
| --- | --- |
| ATM para MED | `Sa_pslv_mpas`, `Sa_tbot_mpas`, `Sa_u10m_mpas`, `Sa_v10m_mpas`, `Sa_shum_mpas`, `Faxa_swdn_mpas`, `Faxa_lwdn_mpas`, `Faxa_rain_mpas`, `Faxa_snow_mpas`, `Faxa_sen_mpas`, `Faxa_lat_mpas`, `Faxa_taux_mpas`, `Faxa_tauy_mpas` (13) |
| OCN para MED | `So_t`, `So_u`, `So_v`, `So_omask` (4; o MOM6 exporta também `So_s`, `Fioo_q` e `Si_ifrac`, que o mediador não importa) |
| ICE para MED | `Si_ifrac_sis2`, `Si_avsdr_sis2`, `Si_avsdf_sis2`, `Si_anidr_sis2`, `Si_anidf_sis2`, `Si_t_sis2` (6) |
| MED para OCN | `Foxx_taux`, `Foxx_tauy`, `Foxx_sen`, `Foxx_evap`, `Foxx_lwnet`, `Foxx_swnet_vdr`, `Foxx_swnet_vdf`, `Foxx_swnet_idr`, `Foxx_swnet_idf`, `Faxa_rain`, `Faxa_snow`, `Sa_pslv`, `Si_ifrac`, `So_duu10n` (14) |
| MED para ICE | `Fioi_taux`, `Fioi_tauy`, `Fioi_sen`, `Fioi_evap`, `Fioi_lwnet`, `Fioi_swnet_vdr`, `Fioi_swnet_vdf`, `Fioi_swnet_idr`, `Fioi_swnet_idf`, `Faxa_rain`, `Faxa_snow`, `Sa_pslv`, `Faxa_coszen`, `So_t`, `So_u`, `So_v` (16) |
| MED para ATM | `Sx_tsfc`, `Si_ifrac`, `So_u`, `So_v`, `Sf_zorl`, `Sf_albedo`, `Sx_omask` (7) |

| Rota | Sentido | Métodos, máscara, reserva | Criada em (hoje) |
| --- | --- | --- | --- |
| `atm2ocn` | ATM para OCN | vizinho mais próximo | `idc_create_routes` (`med_init`) ou `RegridOrCopy` (`med_cap_methods`) |
| `ocn2atm` | OCN para ATM | bilinear | `idc_create_routes` (`med_init`) |
| `ocn2atm_sst` | OCN para ATM | conservativo, bilinear; máscara; reserva `ocn2atm` | `set_ocean_mask_for_sst` (`med_ocean`), quando a máscara deixa de ser uniforme |
| `ocn2atm_ice` | OCN para ATM | conservativo, bilinear; máscara; reserva `ocn2atm` | `add_ice_route` (`med_ice`) |
| `ocn2atm_landmask` | OCN para ATM | vizinho mais próximo | `regrid_land_mask` (`med_export`) |
| `atm2ocn_ice` | ATM para OCN | conservativo, vizinho mais próximo; reserva `atm2ocn` | `export_ice_fraction` (`med_export`) |
