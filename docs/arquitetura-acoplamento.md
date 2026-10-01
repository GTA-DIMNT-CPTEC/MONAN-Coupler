# Arquitetura de acoplamento do MONAN-Coupler: malhas, trocas e interpolação

Versão de 30/09/2026, sobre a tag `fase9-07-validada`; no repositório desde a R-FASE11-01, atualizada na R-FASE11-02 (seções 3.5 e 6) na R-FASE11-03 (seções 3.6 e 6) e na R-FASE11-04 (seções 4.2 e 6). Substitui a versão de 29/09/2026 e a proposta de interpolação anterior. Corresponde à arquitetura descrita na NTC "Arquitetura de acoplamento do MONAN-Coupler: malhas, trocas e interpolação" (INPE, 2026), com o plano de migração detalhado para execução.

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
| `src/coupling/cpl_fields.F90` | dicionário de campos (`CAMPOS`) |
| `src/coupling/cpl_map.F90` | mapa de acoplamento: tabelas `TROCAS` e `ROTAS` |

A migração é a **fase 11** do roteiro, com as mesmas regras das fases 1 a 9: uma etapa por patch, conferências locais e validação bit a bit na Jaci. A fase 10 continua reservada às decisões que mudam resultados.

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
| Configurações alternativas | não tratadas | coluna `quando` nas trocas (`docn`, `sis2`, `med_to_mpas`, `datm`) |
| Criação das rotas | "máscara aplicada antes de criar as rotas que a pedem" (mudaria o momento de criação da `ocn2atm_sst` e os resultados) | coluna `criar` (`inicio` ou `mascara_mista`), que reproduz o momento de hoje |
| Preenchimento do gelo | dentro da rota (mudaria o diagnóstico que registra o campo antes do preenchimento) | explícito onde a ordem importa, com comentário na linha da rota |
| Decomposição | `decomp=DECOMP_FROM_MOM6` / `DECOMP_FROM_SIS2` (os dois caps descrevem a decomposição de formas diferentes) | decomposição sempre como lista de blocos por PET (`cpl_blocos_t`) |
| Método dos conectores | escrito no `CplList` sem conferência | só depois de confirmar no log que é igual ao padrão usado hoje |
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
  cpl_map.F90      tabelas TROCAS e ROTAS e as consultas sobre elas
  cpl_check.F90    conferência do mapa e relatório de acoplamento no log
src/regrid/        framework de interpolação (como hoje, mais a base de pesos)
src/mediator/
  med_exchange.F90 executa as trocas do mediador, por fase
```

### 3.2 Onde escrever cada mudança

| Quero | Onde |
| --- | --- |
| levar um campo novo de um componente a outro | uma linha em `CAMPOS` e as linhas da troca em `TROCAS` |
| mudar o método ou o esquema de uma rota | a linha da rota em `ROTAS`, ou só o `nuopc.input` para experimentar |
| escrever um esquema de interpolação | um arquivo em `src/regrid/` e uma linha em `regrid_schemes.F90` |
| acrescentar ou alterar uma malha | `cpl_grids.F90` |
| mudar uma fórmula de fluxo | física do mediador, que não conhece rotas nem estados |
| converter unidade ou sinal de um modelo | o cap do modelo, com a convenção registrada em `CAMPOS` |

### 3.3 Catálogo de malhas

```fortran
type :: cpl_blocos_t                     ! decomposição: um bloco por PET
  integer, allocatable :: i0(:), i1(:), j0(:), j1(:)
end type cpl_blocos_t

type :: cpl_malha_t
  character(len=16) :: nome       = ''       ! 'atm_med', 'ocn_med', ...
  character(len=8)  :: tipo       = ''       ! 'latlon', 'tripolar', 'voronoi'
  character(len=8)  :: origem_lon = ''       ! 'leste0' ou 'oeste180'
  integer           :: nx = 0, ny = 0
  logical           :: cantos     = .false.  ! exigido pelo método conservativo
  type(ESMF_Grid)   :: grade
end type cpl_malha_t

function malha_latlon(nome, nx, ny, origem_lon, cantos, blocos, rc) result(m)
function malha_tripolar(nome, arquivo_hgrid, blocos, rc) result(m)
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

### 3.4 Dicionário de campos

```fortran
type :: cpl_campo_t
  character(len=24) :: nome
  character(len=12) :: unidade
  character(len=48) :: sinal          ! convenção de sinal, quando houver
  character(len=64) :: descricao
end type cpl_campo_t

type(cpl_campo_t), parameter :: CAMPOS(*) = [                                        &
  cpl_campo_t('So_t',     'K',     '', 'temperatura da superficie do oceano'),       &
  cpl_campo_t('Si_ifrac', '1',     '', 'fracao de gelo, entre 0 e 1'),               &
  cpl_campo_t('Fioi_sen', 'W m-2', 'do mediador; o cap do SIS2 inverte',             &
              'calor sensivel sobre o gelo') ]
```

### 3.5 Mapa de acoplamento

O mapa está em `src/coupling/cpl_map.F90` desde a R-FASE11-02, e a versão em tabelas, gerada dele, em `docs/acoplamento.md`.

`TROCAS` tem uma linha por passagem de um campo de uma malha a outra. As colunas são: campo, `componente@malha` de origem, `componente@malha` de destino, meio (`conector`, nome de rota ou `cap`) e `quando`, a lista de condições em que a troca vale, separadas por vírgula (vazia: vale sempre). Cada chave de `&nuopc_mode` tem as duas condições, a de cada valor, para que toda troca diga onde vale sem precisar de negação:

| Condições | Chave |
| --- | --- |
| `mpas` / `datm` | `use_datm` |
| `mom6` / `docn` | `use_docn` |
| `med_to_mpas` / `ocn_to_mpas` | `use_med_to_mpas` |
| `sis2` | `use_sis2_dynamic` |

Exemplo com o caminho da temperatura de superfície:

```fortran
type(cpl_troca_t), parameter :: TROCAS(*) = [                                                &
  !           campo            de              para            meio           quando
  cpl_troca_t('So_t',          'OCN@ocn_mom6', 'MED@ocn_med',  'conector',    'mom6'),              &
  cpl_troca_t('So_t',          'OCN@docn',     'MED@ocn_med',  'conector',    'docn'),              &
  cpl_troca_t('So_t',          'MED@ocn_med',  'MED@atm_med',  'ocn2atm_sst', ''),                  &
  cpl_troca_t('Sx_tsfc',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',     ''),                  &
  cpl_troca_t('Sx_tsfc',       'MED@ocn_med',  'ATM@atm_cap',  'conector',    'mpas,med_to_mpas'),  &
  cpl_troca_t('Sx_tsfc',       'ATM@atm_cap',  'ATM@mpas',     'cap',         'mpas'),              &
  cpl_troca_t('Si_ifrac_sis2', 'ICE@ice_sis2', 'MED@ocn_med',  'conector',    'sis2'),              &
  cpl_troca_t('Si_ifrac_sis2', 'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice', 'sis2') ]
```

No mediador, o mesmo nome pode existir duas vezes em `MED@ocn_med`: o campo importado e o exportado (`So_t`, `So_u` e `So_v`). A regra de leitura do mapa é que uma rota que parte de `MED@ocn_med` lê o campo importado, e um conector que parte dali leva o exportado, que chegou de `MED@atm_med` pela rota `atm2ocn`.

O DATM está no mapa como o cap dele anuncia os campos (malha `datm`, condição `datm`), mas o driver não o registra: com `use_datm=.true.` o componente atmosférico continua sendo o MONAN-A. Duas lacunas de hoje ficam registradas no teste do mapa: com o DOCN, `So_omask` não chega ao mediador (o DOCN não a exporta); com o DOCN e o contorno direto do oceano, `Sx_tsfc`, `Sf_albedo` e `Sx_omask` não chegam ao MONAN-A, e o cap atmosférico interrompe a rodada.

`ROTAS` tem uma linha por interpolação do mediador. Toda rota tem as mesmas quatro etapas, na mesma ordem, e as colunas que não aparecem ficam com o valor padrão, que desliga a etapa:

| Etapa | Colunas |
| --- | --- |
| 1. preparar | `mascara` (campo que dá a máscara da origem), `sem_valor` (`zerar`, `manter`, `sentinela`) |
| 2. interpolar | `metodos` (em ordem de preferência), `reserva`, esquema (padrão `esmf`, trocável no `nuopc.input`) |
| 3. completar | `completar` (um `regrid_fill_t`: faixa válida, valor fixo, passadas) |
| 4. limitar | `limite_min`, `limite_max`, `nan_para` |

E uma coluna que não é etapa: `criar`, o momento em que a rota é criada: `inicio` (em `InitializeDataComplete`), `primeiro_uso` (na primeira vez que o mediador precisa dela; é o caso de `ocn2atm_ice`, `ocn2atm_landmask` e `atm2ocn_ice`) ou `mascara_mista` (no primeiro passo em que a máscara do oceano tem terra e mar). O valor `primeiro_uso` foi acrescentado na R-FASE11-02, ao escrever as seis rotas: com só `inicio` e `mascara_mista`, o mapa não reproduziria o momento de criação de três delas.

```fortran
type(cpl_rota_t), parameter :: ROTAS(*) = [                                      &
  cpl_rota_t(nome='ocn2atm',     de='ocn_med', para='atm_med',                   &
             metodos='bilinear'),                                                &
  cpl_rota_t(nome='ocn2atm_sst', de='ocn_med', para='atm_med',                   &
             metodos='conserve,bilinear', mascara='So_omask',                    &
             reserva='ocn2atm', criar='mascara_mista',                           &
             completar=regrid_fill_t(enabled=.true., vmin=270.0_r8,              &
                 vmax=310.0_r8, vfill=T_FREEZE_SEAWATER, max_iter=40,            &
                 skip_fraction=1.0_r8, overflow_to_fill=.true.)),                &
  cpl_rota_t(nome='ocn2atm_ice', de='ocn_med', para='atm_med',                   &
             metodos='conserve,bilinear', mascara='So_omask',                    &
             reserva='ocn2atm', sem_valor='sentinela', criar='primeiro_uso'),    &
  cpl_rota_t(nome='atm2ocn',     de='atm_med', para='ocn_med',                   &
             metodos='nearest_stod', nan_para=0.0_r8) ]
```

Na `ocn2atm_ice`, o preenchimento continua explícito em `med_exchange`, porque hoje ele acontece depois de diagnósticos que registram o campo antes dele. As colunas `limite_min`, `limite_max` e `nan_para` ficam desligadas com o valor `CPL_AUSENTE` (`huge(1.0_r8)`). As seis rotas completas estão em `cpl_map.F90`.

### 3.6 Conferência e relatório de acoplamento

`cpl_check` usa o mapa de duas formas:

- **Conferência, na inicialização.** Depois do anúncio dos campos, confere o mapa contra o que cada componente anunciou:
  - todo campo importado tem exatamente uma troca que chega a ele;
  - toda troca parte de um campo exportado;
  - toda malha e toda rota citadas existem;
  - todo campo está em `CAMPOS`.

  Enquanto a migração não termina, só registra as diferenças no log; no fim, passa a interromper a rodada com a linha do mapa.

  Desde a R-FASE11-03, `cpl_check_acoplamento` faz essa conferência no fim do `ModifyCplLists` do driver, só no PET 0, e escreve linhas `CPL-REL: DIFERENCA:` e, para campos exportados que ninguém consome (normais, como o `So_s` do MOM6), `CPL-REL: AVISO:`. A conferência é feita nos dois níveis: a CplList de cada conector contra as trocas do mapa entre os dois componentes, e os estados de cada componente contra as trocas que chegam a ele e partem dele. O mesmo módulo escreve o relatório dos conectores (campos e opções de cada CplList).
- **Relatório de acoplamento, no log.** É uma tabela com cada troca, as malhas, o método que o ESMF aceitou, se a rota caiu na reserva e quantos pontos foram completados. Durante a migração, ele serve também de conferência: o relatório de uma etapa tem de ser igual ao da etapa anterior.

### 3.7 Mediador por fases

```fortran
! Inicialização (InitializeDataComplete)
call cria_rotas(is, criar='inicio')
call aguarda_primeira_sst(is, importState)
! A cada passo (MediatorAdvance)
call ir_para_malha_de_fluxo(is, importState)    ! OCN e ICE -> atm_med
call calcula_fluxos(is%fluxo, clock)            ! física bulk, só arrays
call voltar_para_malha_do_oceano(is)            ! atm_med -> ocn_med
call entregar(is, exportState, clock)           ! exportação e carimbo de tempo
```

### 3.8 Esquemas de interpolação

`src/regrid/` continua como está. A migração acrescenta três coisas:

- **Uma base para esquemas de pesos** (`weights_regridder_t`). O esquema escreve só `calcula_pesos`, com arrays comuns do Fortran; a base cuida do *route handle*, da reprodutibilidade (`srcTermProcessing=0`, `termorder=srcseq`) e da liberação.
- **Opções em texto** (`'expoente=2,vizinhos=4'`), lidas pelo próprio esquema.
- **Uma lista de esquemas** em `regrid_schemes.F90`, com um modelo de esquema e o teste `compara-esquema.bash`.

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
| fórmula movida para `cpl_grids` | código de máquina comparado (`objdump`), como na R-FASE9-02: só números de linha diferem; testes `grade` e unitários | |
| construção de malha movida | teste do supergrid (`tests/supergrid/compara-supergrid.bash`, conferência `supergrid`): dimensões, coordenadas e mensagens idênticas bit a bit; a partir da R-FASE11-10, estendido aos blocos | relatório de acoplamento igual |
| configuração de rota movida para `ROTAS` | teste de interpolação (`tests/regrid`); comparação da configuração efetiva de cada rota, antes e depois | relatório de acoplamento igual (métodos, reservas, pontos completados) |
| chamadas movidas entre módulos | `confere-instrucoes.py` sobre a soma dos arquivos: só estrutura de módulo muda; teste da física bulk | relatório de acoplamento igual |
| DOCN ou DATM | teste do DOCN num driver NUOPC (`tests/docn/compara-docn.bash`, conferência `docn`); DATM pela compilação | |

A partir da etapa que cria o relatório de acoplamento (R-FASE11-04), `valida_rodada.bash compara` passa a extrair o relatório do log e compará-lo com o da última rodada validada. Uma diferença ali aponta o problema antes da comparação dos arquivos. O relatório tem quatro partes: configuração e conectores, conferência do mapa (R-FASE11-03), rotas na criação e pontos completados por vizinhança no fim da rodada (R-FASE11-04); o formato está em `docs/validacao-refatoracao.md`, seção 2.1. Os pontos completados são contados onde o preenchimento roda hoje, fora das rotas, com o nome `rota campo`; quando a R-FASE11-14 levar o preenchimento para dentro da rota, as linhas têm de sair iguais.

### 4.3 Etapas

As etapas estão agrupadas em seis blocos. Os blocos A e B dão visibilidade sem tocar em cálculo; C e D reorganizam malhas e rotas; E reorganiza o mediador; F fecha a fase.

**Bloco A: descrição do acoplamento, sem efeito no cálculo**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-01 | este documento em `docs/arquitetura-acoplamento.md`; fase 11 no roteiro; estado do projeto; indicadores da fase acrescentados a `indicadores.py` (ver 4.4) | só documentação e ferramenta | resultado de `indicadores.py` em `fase9-07-validada` registrado como partida |
| R-FASE11-02 | `cpl_fields.F90` (`CAMPOS`) e `cpl_map.F90` (`TROCAS` e `ROTAS` descrevendo o acoplamento de hoje, com as quatro configurações); teste unitário `test_cpl_map` (consistência interna: toda troca tem campo em `CAMPOS`, toda rota citada existe, toda importação tem uma única origem em cada configuração); `tools/dev/mapa-acoplamento.py`, que gera `docs/acoplamento.md` | módulos compilados e ligados, mas não chamados | teste unitário; o mapa gerado confere com o Apêndice A |
| R-FASE11-03 | `cpl_check`: conferência do mapa contra os campos anunciados, chamada pelo driver em `ModifyCplLists`, só com registro no log; relatório dos conectores (campos e opções de cada `CplList`) | só escreve no log | a conferência não acusa diferença na configuração de produção |
| R-FASE11-04 | relatório das rotas do mediador (método aceito, reserva, pontos completados), gravado depois da criação de cada rota; extração e comparação do relatório em `valida_rodada.bash compara` | só escreve no log | relatório igual em duas rodadas da mesma revisão |

**Bloco B: listas de campos a partir do mapa**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-05 | anúncio dos campos do mediador (`import_mpas_names`, `import_datm_names`, `export_names` e os campos realizados à mão em `realize_component_fields`) lido de `TROCAS` | mesmos nomes, na mesma ordem, nas mesmas fases | teste compara a lista gerada com a de hoje, nome a nome; literais só mudam de arquivo |
| R-FASE11-06 | idem para os caps do MOM6 e do SIS2 | idem | idem; relatório dos conectores igual |
| R-FASE11-07 | idem para os caps do MONAN-A, do DOCN e do DATM | idem | idem; teste do DOCN |

**Bloco C: malhas**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-08 | `cpl_grids` com `malha_latlon` e as fórmulas de centro e índice; `atm_med` e `atm_cap` construídas por ele | mesmas coordenadas, mesma decomposição, mesmas expressões | `objdump`; testes `grade` e unitários |
| R-FASE11-09 | fórmulas de índice de `bin_cells_local`, `copy_to_local_grid`, `state_get_field_1d`, `check_ice_geography`, `oisst_to_atm_nearest` e dos dois gravadores de diagnóstico passam a vir de `cpl_grids` (uma função por regra de arredondamento) | cada função reproduz a expressão de hoje | `objdump`; testes `grade`, `gravadores` e unitários |
| R-FASE11-10 | `cpl_blocos_t` e `malha_tripolar`; `ocn_med` e `ice_sis2` construídas por ele | mesma leitura, normalização e blocos | teste do supergrid, estendido aos blocos: coordenadas e blocos idênticos bit a bit |
| R-FASE11-11 | `ocn_mom6` por `malha_tripolar`, **somente se** as coordenadas lidas do arquivo forem idênticas bit a bit às `geoLonT` do MOM6; caso contrário, o construtor recebe as coordenadas do modelo e a etapa só unifica a decomposição | coordenadas conferidas antes | diagnóstico avulso na Jaci comparando as duas fontes de coordenadas |

**Bloco D: rotas**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-12 | `regrid_manager%add(nome, src, dst, rc)` passa a buscar a configuração em `ROTAS`; as chamadas de hoje perdem a configuração, mas continuam nos mesmos pontos; `set_ocn_grid_mask` substitui os dois trechos que copiam a máscara | mesmos métodos, máscaras, reservas e momento de criação | configuração efetiva de cada rota impressa e comparada; relatório de acoplamento igual |
| R-FASE11-13 | etapas preparar e limitar executadas pela rota: `sem_valor` substitui os `zero_total` passados nas chamadas e as sentinelas; `nan_para` substitui o tratamento em `RegridOrCopy` | mesma sequência de operações sobre cada campo | teste de interpolação; relatório igual |
| R-FASE11-14 | etapa completar executada pela rota onde segue a interpolação (SST e fração de gelo exportada); no gelo, continua explícita | mesma sequência de operações | teste da física bulk; relatório igual (pontos completados) |

**Bloco E: mediador por fases e física em arrays**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-15 | `med_exchange.F90` com a fase `entregar`: exportação (`RegridOrCopy` e `med_export`) e carimbo de tempo num lugar só; `RouteOcnToAtm` sai | mesmas chamadas, na mesma ordem | `confere-instrucoes.py` sobre a soma; relatório igual |
| R-FASE11-16 | fase `ir_para_malha_de_fluxo`: interpolações de `med_ocean` e `med_ice` | idem | idem |
| R-FASE11-17 | fase de inicialização (`cria_rotas`, `aguarda_primeira_sst`), com as rotas de `InitializeDataComplete` | idem; mesma sequência do laço de dependência de dados | idem |
| R-FASE11-18 | a interpolação da fração de gelo sai de `calc_bulk_ncar` e vai para imediatamente antes da chamada | mesma sequência de operações | teste da física bulk |
| R-FASE11-19 | física em arrays: tipo `med_fluxo_t`; `med_bulk_ncar` sem estados nem rotas | mesmas expressões, na mesma ordem | teste da física bulk; testes de valor esperado |

**Bloco F: conectores, esquemas, adaptador do MPAS e encerramento**

| Etapa | Conteúdo | Por que não muda resultados | Conferência específica |
| --- | --- | --- | --- |
| R-FASE11-20 | driver escolhe os conectores a partir de `TROCAS` e da coluna `quando` | os mesmos pares de componentes em cada configuração | relatório dos conectores igual nas configurações de produção e DOCN |
| R-FASE11-21 | método de cada campo escrito no `CplList`, se o relatório da R-FASE11-03 mostrar que o padrão de hoje é o bilinear com as opções que serão escritas; senão, a etapa só documenta e fica como decisão da fase 10 | o conector recebe explicitamente o que recebe por padrão | relatório dos conectores igual |
| R-FASE11-22 | `weights_regridder_t`, opções em texto, `regrid_schemes.F90`, modelo de esquema e `compara-esquema.bash` | os esquemas existentes fazem as mesmas chamadas ao ESMF | `tests/regrid`; o `weights_file` dá os mesmos pesos |
| R-FASE11-23 | adaptador do MPAS: a tradução entre o modelo e o ESMF reunida num módulo, com as trocas `cap` declaradas no mapa | código movido, sem mudar operações | `confere-instrucoes.py`; teste `grade` |
| R-FASE11-24 | conferência passa a interromper a rodada em caso de diferença; dicionário do NUOPC com os nomes de `CAMPOS` e acréscimo automático desligado | só muda o comportamento quando há erro | rodada normal igual; uma rodada com um nome errado de propósito tem de parar com a linha do mapa |
| R-FASE11-25 | encerramento: documentação, indicadores finais, NTC e RPQ atualizados | só documentação | |

Ordem e dependências: A antes de tudo; B depois de A; C e D podem alternar; E depois de D; F no fim. As etapas 11 e 21 dependem de uma conferência na Jaci e podem virar só documentação, se a conferência mostrar que a mudança não é neutra.

### 4.4 Indicadores e metas

`indicadores.py` mede, desde a R-FASE11-01, os indicadores desta fase numa segunda tabela (a regra de cada contagem está em `docs/conferencias-locais.md`, seção 2.7). A coluna "Hoje" traz os valores medidos em `fase9-07-validada`, exceto as fórmulas de índice e as trocas sem linha no mapa, conferidas à mão. Cada etapa registra os valores antes e depois no CHANGELOG.

| Indicador | Hoje | Meta |
| --- | --- | --- |
| arquivos com nomes de campos anunciados ou realizados escritos à mão | 8 (os caps do MONAN-A, MOM6, SIS2, DOCN e DATM; `MED_cap`, `med_cap_types` e `med_init`) | 0 |
| construções de malha ESMF fora de `cpl_grids` | 7 chamadas `ESMF_GridCreate*` em 6 arquivos | só as do DOCN e do DATM, se não migradas |
| rotas criadas fora de `med_exchange` | 7 pontos em 5 arquivos | 0 |
| chamadas de rota em módulos de física | 1 (`med_bulk_ncar`) | 0 |
| fórmulas de índice de grade regular fora de `cpl_grids` | 9 rotinas | 0 |
| arquivos que carimbam o tempo dos campos | 5 (`cap_common`, `mom_cap_MONAN`, `MED_cap`, `med_export`, `med_cap_methods`) | `cap_common` e `med_exchange` |
| trocas sem linha no mapa | todas | 0 |

### 4.5 Pronto quando

- a conferência do mapa está ativa e interrompe a rodada em caso de diferença;
- os indicadores da seção 4.4 estão nas metas;
- o relatório de acoplamento da última etapa é igual ao da R-FASE11-04;
- todas as etapas reproduziram a R-NOFMA-02, com tag.

### 4.6 Riscos e cuidados

- **Momento de criação das rotas.** Os pesos dependem da máscara no momento da criação. A coluna `criar` reproduz o momento de hoje; nenhuma etapa muda quando uma rota é criada.
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

A R-FASE11-02 escreveu o mapa: `src/coupling/cpl_fields.F90` (57 campos) e `src/coupling/cpl_map.F90` (8 malhas, 154 trocas, 6 rotas), o teste `tests/unit/test_cpl_map.F90`, que confere o mapa nas cinco combinações de `&nuopc_mode` e contra as listas do mediador, e `tools/dev/mapa-acoplamento.py`, que gera `docs/acoplamento.md`. Os módulos são compilados e ligados, mas nenhum componente os usa. Com isso, o indicador "trocas sem linha no mapa" vai a 0. Ao escrever o mapa, a coluna `quando` ganhou as condições dos dois valores de cada chave e a lista de condições, e a coluna `criar` ganhou `primeiro_uso` (seção 3.5).

A R-FASE11-03 criou `src/coupling/cpl_check.F90`, chamado pelo `ModifyCplLists` do driver: relatório dos conectores e conferência do mapa no log do PET 0, com o prefixo `CPL-REL:`, sem interromper a rodada (seção 3.6). Na configuração de produção, num driver NUOPC de teste com as listas de hoje, a conferência dá 0 diferenças e 3 avisos (o MOM6 exporta `So_s`, `Fioo_q` e `Si_ifrac`, que ninguém consome). No mesmo teste, a CplList saiu em ordem alfabética, e não na ordem do anúncio; se o log da Jaci confirmar, o cuidado da seção 4.6 sobre a ordem dos campos anunciados vale para os estados, não para os conectores.

A R-FASE11-04 fechou o bloco A: o relatório de acoplamento ganhou uma linha por rota do mediador, escrita na criação (esquema, métodos, máscara, método aceito ou reserva usada), e uma linha por campo completado por vizinhança, escrita no fim da rodada com a soma dos PETs; `valida_rodada.bash compara` grava o relatório em `relatorio_acoplamento.txt` e o compara com o da rodada aprovada mais recente.

Próxima etapa: **R-FASE11-05**, primeira do bloco B: o anúncio dos campos do mediador passa a ser lido de `TROCAS`, nos mesmos nomes, na mesma ordem e nas mesmas fases, conferido nome a nome por teste.

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
