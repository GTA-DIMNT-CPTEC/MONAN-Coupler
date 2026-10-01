# Estado do projeto: refatoração do MONAN-Coupler

Documento de passagem, para retomar o trabalho em outra sessão ou com outra pessoa sem precisar reconstruir o contexto. Atualizado na R-FASE11-15 (01/10/2026), décima quinta etapa da fase 11. Para retomar, comece pela seção 10.

## 1. O que é o projeto

O MONAN-Coupler acopla a atmosfera MONAN-A 2.0 (baseada no MPAS-A) ao oceano MOM6 e ao gelo marinho SIS2 por ESMF/NUOPC, com um mediador próprio que calcula os fluxos ar-mar. O código próprio do acoplador está em `src/` (Fortran moderno, compilado pelo `Makefile`). A refatoração teve uma regra única: melhorar a estrutura sem mudar nenhum resultado numérico, conferido bit a bit contra uma linha de base a cada etapa.

## 2. Ambiente

| Item | Valor |
| --- | --- |
| Repositório | `GTA-DIMNT-CPTEC/MONAN-Coupler`, partindo do commit `ea10fb6` do ramo `develop` |
| Ramo da refatoração | `refactor/principal`, também no GitHub; cada etapa validada tem a tag `faseN-NN-validada` (a mais recente marca o último ponto validado) |
| Instalação na Jaci | `/p/projetos/gta/daniel.massaru/refatorado/Coupler-Install/MONAN-Coupler` |
| Instalação de produção (não usar para validar) | `/p/projetos/gta/daniel.massaru/coupling/Coupler-Install/MONAN-Coupler` |
| Linhas de base | `/p/projetos/gta/daniel.massaru/refatorado/baseline/` |
| Experimento modelo (entradas) | `/p/projetos/gta/daniel.massaru/refatorado/exp_monan2xmom6` |
| Rodadas de validação | `/p/projetos/gta/daniel.massaru/refatorado/exp/<nome>` |
| Compilador e bibliotecas | Cray PrgEnv-gnu (gfortran), MPICH, ESMF 8.9.1, NetCDF 4.9, processadores AMD Turin |
| Configuração de validação | 128 PETs ATM + 20 OCN + 4 ICE (152), execução concorrente, SIS2 dinâmico, 24 passos de 3600 s (29 a 30/03/2026) |

## 3. Etapas entregues e validadas

Cada etapa é um patch com um único commit, aplicado com `git am` na ordem abaixo sobre `ea10fb6`. Todas reproduziram a linha de base bit a bit.

| Patch | Conteúdo |
| --- | --- |
| R-FASE1-01 | código morto, duplicação e remendos; módulos `coupler_config`, `coupler_utils`, `diag_bitsum`; driver e programa principal reescritos |
| R-FASE1-01-FIX01 | RunSequence truncada ('MPA'); mensagens só no PET 0 |
| R-FASE1-01-FIX02 | opções de compilação do MOM6 restritas aos seus fontes |
| R-FASE2A-01 | framework de interpolação plugável (`src/regrid/`); eliminação das 109 construções BLOCK |
| R-FASE2A-01-FIX01 | parser de streams do MPAS em procedimento próprio |
| R-RUN-EXE-01 | `ESMAPP_BIN` repassado ao trabalho PBS; executável registrado no log |
| R-FASE2A-02 | compilação sem FMA (`FP_CONTRACT ?= off`); ferramentas de linha de base |
| R-FASE2B-01 | procedimentos internos convertidos em procedimentos de módulo com `intent`; `MediatorAdvance` em etapas |
| R-FASE2B-02 e FIX01 | `coupler_constants`, `mom6_supergrid`; `tools/dev/valida_rodada.bash`; aviso de executável de outra instalação no `--check` |
| R-FASE2B-03 | `InitializeRealize` do mediador e `state_set_field_1d` em etapas; `grid_regdecomp` |
| R-FASE3-01 | calendário do gravador NetCDF pelo `ESMF_Time` (corrige datas inválidas em rodadas que cruzam o início do mês) |
| R-FASE3-02 | módulo comum dos gravadores NetCDF (`nc_writer`) |
| R-FASE3-03 | comentários sem marcas de histórico; veredito visível no `valida_rodada` |
| R-FASE3-04 | linha de base padrão R-NOFMA-02; este documento |
| R-FASE4-01 | `mpas_atm_init`, `write_mpas_import_diag`, `med_write_import_fields` e `InitializeRealize` do oceano divididos em etapas |
| R-FASE4-02 | `anota-linha-base.bash`; `valida_rodada compara` distingue "comparação não feita" de FAIL e devolve o código da comparação |
| R-FASE4-03 | `MediatorAdvance` dividida em etapas |
| R-FASE4-04 | ferramentas de conferência local no repositório; documentação (sem mudança em `src/`: validada pela compilação na Jaci, tag `fase4-04-validada`) |
| R-FASE4-05 | `update_ice_fields_on_atm_grid` e `compute_ice_fluxes` divididas em etapas; teste da física bulk (`tests/bulk`) |
| R-FASE4-06 | `WriteDOCNDiag` dividida em etapas; teste dos gravadores estendido ao DOCN |
| R-FASE4-07 | `InitializeRealize` do cap do gelo dividida em etapas; `intent` refinados; interfaces mínimas do SIS2 |
| R-FASE4-08 | `nuopc.input` do repositório com as contagens de PETs da configuração de validação |
| R-FASE5-01 | comentários do `nuopc.input` atualizados; aviso antigo do `run_esmApp.jaci` retirado |
| R-FASE5-02 | comentários do mediador sem marcas de histórico e com o comportamento atual |
| R-FASE5-03 | comentários dos caps do oceano e do gelo sem marcas de histórico; histórico do `mom_cap_MONAN` resumido no CHANGELOG |
| R-FASE5-04 | comentários do cap atmosférico e de `src/shared` sem marcas de histórico; históricos de `mpas_cap_MONAN` e `mpas_cap_netcdf` resumidos no CHANGELOG |
| R-FASE5-05 | `map_cells_to_regular_grid` dividida em etapas; teste da grade do cap atmosférico |
| R-FASE5-06 | `InitializeDataComplete` e `blend_albedo_with_ice` divididas em etapas |
| R-FASE5-07 | comentários dos scripts de `tools/` sem marcas de histórico; históricos dos cabeçalhos em `docs/historico-scripts.md` |
| R-FASE11-01 | início da fase 11: `docs/arquitetura-acoplamento.md` (arquitetura e plano), indicadores da fase em `indicadores.py`, testes do supergrid do MOM6 e do DOCN no repositório e em `confere-tudo.bash`, seção de retomada deste documento; só documentação e ferramentas |
| R-FASE11-02 | mapa de acoplamento em `src/coupling/` (`cpl_fields.F90` com `CAMPOS`; `cpl_map.F90` com `MALHAS`, `TROCAS` e `ROTAS`), compilado e ligado, sem uso; teste `tests/unit/test_cpl_map.F90`; `tools/dev/mapa-acoplamento.py` e `docs/acoplamento.md` |
| R-FASE11-03 | `cpl_check.F90`: relatório dos conectores e conferência do mapa no log do PET 0 (prefixo `CPL-REL:`), chamados pelo `ModifyCplLists` do driver; testes `tests/unit/test_cpl_check.F90` e `tests/cplcheck/` |
| R-FASE11-04 | relatório das rotas do mediador (na criação) e contagem dos pontos completados por vizinhança; `valida_rodada.bash compara` extrai e compara o relatório de acoplamento; teste `tests/unit/test_completa.F90` |
| R-FASE11-04-FIX01 | as linhas dos pontos completados saem no último passo do mediador, e não na finalização, que o programa principal não chama |
| R-FASE11-05 | o mediador anuncia e realiza os campos a partir do mapa (`cpl_chegadas`, chaves `MED_CHAVES`); listas de `med_cap_types` retiradas; caso `mediador` em `tests/cplcheck` |
| R-FASE11-06 | os caps do MOM6 e do SIS2 anunciam e realizam os campos a partir do mapa (`cpl_chegadas` e `cpl_exportacoes`, tabela nova `EXPORTACOES`); listas dos dois caps retiradas; `tests/unit/listas_caps.inc` |
| R-FASE11-07 | os caps do MONAN-A, do DOCN e do DATM anunciam e realizam os campos a partir do mapa; valores iniciais escolhidos pelo nome do campo; fim do bloco B (nenhum componente escreve à mão os nomes dos campos que anuncia) |
| R-FASE11-08 | `cpl_grids.F90`: malha de fluxo do mediador e grade do cap atmosférico construídas por `cpl_malha_latlon`, com a decomposição `cpl_regdecomp` e as fórmulas de centro e canto em funções; teste `tests/malhas` (conferência `malhas`) e `test_cpl_grids` |
| R-FASE11-09 | fórmulas de índice e de longitude das grades regulares (cap atmosférico, gravadores de diagnóstico, mediador, OISST no cap do MOM6) em `cpl_grids`, uma função por regra; equivalência bit a bit conferida em `test_cpl_grids` |
| R-FASE11-10 | oceano no mediador (`ocn_med`, com o MOM6 e com o DOCN) e malha do SIS2 (`ice_sis2`) construídos por `cpl_grids` (`cpl_malha_tripolar`, `cpl_blocos_t`); teste `malhas` estendido e `tests/malhas/test_malha_gelo.F90` |
| R-FASE11-11 | grade do cap do MOM6 (`ocn_mom6`) por `cpl_malha_de_blocos`, com as chamadas do ESMF de hoje e as coordenadas do modelo (etapa redefinida: o plano original mudaria resultados); `test_malha_gelo.F90` passa a `test_malhas_modelos.F90`, com a grade do MOM6; fim do bloco C |
| R-FASE11-12 | rotas do mediador criadas por `cria_rota` com a configuração de `ROTAS`; `set_ocn_grid_mask` no lugar das duas cópias da máscara do oceano; teste `test_rotas` |
| R-FASE11-13 | `sem_valor` e `nan_para` de `ROTAS` aplicados pela rota (`regrid_manager` guarda a configuração de cada rota); chamadas de interpolação sem `zero_total`; NaN de `RegridOrCopy` pela rota `atm2ocn` |
| R-FASE11-14 | etapa completar pela rota (`regrid_manager%apply`, com as contagens do relatório) na SST e na fração de gelo exportada; `fill_sst_gaps` sai; teste `tests/completar` (conferência `completar`); fim do bloco D |
| R-FASE11-15 | `med_exchange.F90` com a fase `entregar` (exportação e carimbo de tempo dos campos do mediador); `RouteOcnToAtm` sai; `tests/completar` grava os carimbos; início do bloco E |
| R-FASE9-07 | encerramento da fase 9: indicadores finais, RPQ na sexta versão e procedimento de integração ao `develop`; só documentação |
| R-FASE9-06 | zeragem dos fluxos do oceano numa rotina (`ZeroOcnFluxFields`), `ZeroInternalField` e `GetFieldPtrOptional` reaproveitando `FillInternalField` e `GetFieldPtr`, busca de campos do cap atmosférico em `find_local_field`; trechos repetidos de 54 para 42 |
| R-FASE9-05 | leitura do supergrid do MOM6 (`mom6_supergrid_tcoords` e `mom6_supergrid_corners`) numa rotina privada; trechos repetidos de 67 para 54; conferida com teste avulso |
| R-FASE9-04 | inicialização de dados (valores iniciais por nome, atributos de conclusão) e carimbo de tempo dos caps de dados em `cap_common.F90`; trechos repetidos de 82 para 67; conferida localmente com o driver NUOPC avulso do DOCN |
| R-FASE9-03 | revisão final dos comentários: arquivos e rotinas citados passam a ser os de depois das divisões, histórico de mudanças trocado pela descrição do comportamento atual, comentários errados corrigidos; zero diferenças de instruções |
| R-FASE9-02 | números fixos que são constantes físicas ou valores padrão (271,35 K, 273,15 K, faixa de temperatura do gelo, albedos padrão, `_FillValue`, π, `RAD2DEG`) trocados pelos nomes de `coupler_constants`, só onde valor e `kind` são idênticos; código de máquina conferido igual |
| R-FASE9-01 | procedimentos comuns aos caps (fase 0 da inicialização, criação e realização de campos, cópia de arranjo para campo) no módulo compartilhado `cap_common.F90`; conferida localmente com o driver NUOPC avulso do DOCN |
| R-FASE8-15 | cópia das células MPAS para a grade regular (`state_set_field_1d`, `map_cells_to_regular_grid` e as suas etapas) sai de `mpas_cap_methods.F90` para `mpas_cell_binning.F90`; com ela terminam as divisões de arquivo |
| R-FASE8-14 | troca de campos do cap do gelo (`import_forcing`, `export_si_*`) e o seu estado interno saem de `sis_cap_MONAN.F90` para `sis_cap_fields.F90` |
| R-FASE8-13 | fração de gelo do cap do oceano (`set_si_ifrac_from_file`, `compute_si_ifrac_proxy`) sai de `mom_cap_MONAN.F90` para `mom_si_ifrac.F90` |
| R-FASE8-12 | diagnóstico de importação do cap atmosférico (`monan2_import_*.nc`) sai de `mpas_cap_netcdf.F90` para `mpas_import_diag.F90` |
| R-FASE8-11 | `ModelAdvance` do DOCN: leitura dos campos e das correntes e carimbo de tempo em rotinas próprias; conferida localmente com driver NUOPC avulso; nome do job PBS `GTA-COUPLER` |
| R-FASE8-10 | `compute_instantaneous_fluxes`: uma rotina por grandeza (radiação, precipitação, umidade, vento de reserva, tensão); conferida localmente com teste avulso |
| R-FASE8-09 | `mpas_atm_run`: injeção do contorno do oceano (`inject_ocean_cells`) e diagnóstico do albedo (`log_albedo_feedback`) em rotinas próprias |
| R-FASE8-08 | `fill_ifrac_from_oisst`: número de instantes, leitura no PET 0 e remapeamento em rotinas próprias; conferida localmente com teste avulso |
| R-FASE8-07 | `get_atm_forcing`: leitura do DATM (`get_datm_forcing`) e umidade e neve opcionais do MPAS (`select_optional_mpas_forcing`) em rotinas próprias |
| R-FASE8-06 | `mpas_export`: o bloco repetido para os 13 campos vira `export_mpas_member` |
| R-FASE8-05 | `write_mpas_import_diag`: reunião das coordenadas (`gather_cell_coords`) e gravação no PET 0 (`write_import_diag_file`) em rotinas próprias |
| R-FASE8-04 | `calc_bulk_ncar`: geometria solar (`solar_time_and_declination`) e fluxos de água aberta (`compute_ocean_fluxes`) em rotinas próprias |
| R-FASE8-03 | `export_write_netcdf` dividida (`define_export_file`, `read_export_field_local`); último `BLOCK` e buffers mortos retirados |
| R-FASE8-02 | `mpas_atm_model.F90` dividido: pontos de entrada no arquivo principal, etapas da inicialização em `mpas_atm_setup` e fluxos instantâneos em `mpas_atm_fluxes` |
| R-FASE8-01 | `MED_cap.F90` dividido por assunto: pontos de entrada NUOPC no arquivo principal e seis módulos novos (`med_init`, `med_flux`, `med_ocean`, `med_ice`, `med_export`, `med_diag`) |
| R-FASE7-06 | marcas de primeira vez e contadores com `save` no estado interno de cada componente; fase 7 completa |
| R-FASE7-05 | cap atmosférico com estado interno ESMF (`mpas_cap_state_t`); relógio do diagnóstico de importação num tipo próprio |
| R-FASE7-04 | estado do MPAS (domínio, ponteiros dos pools, acumulados e buffers) de `mpas_atm_model` no `mpas_atm_state_type` |
| R-FASE7-03 | gravador `monan_export_*.nc` do cap atmosférico com estado próprio (`mpas_diag_export_t`); teste dos gravadores cobre `export_write_netcdf` |
| R-FASE7-02 | `MED_InternalState` agrupado em seis subtipos (fluxos para o oceano, oceano, gelo, superfície, paralelismo, diagnóstico) |
| R-FASE7-01 | mediador: comunicador MPI, PETs e configuração do diagnóstico de importação no `MED_InternalState`; `med_cap_types` com `private` padrão |
| R-FASE6-03 | testes com valor esperado da passagem das células MPAS para a grade do cap atmosférico |
| R-FASE6-02 | testes com valor esperado das fórmulas da física bulk (`tests/unit`) |
| R-FASE6-01 e FIX01 | `confere-tudo.bash` e `indicadores.py`; roteiro de código limpo e levantamento do DTN-01; scripts de `tools/dev/` compatíveis com o Python 3.6 da Jaci |

O detalhe de cada etapa está em `docs/CHANGELOG.md` e no relatório técnico (RPQ, versão 5, que cobre todas as etapas até a R-FASE5-07).

## 4. Linhas de base

| Rótulo | Código | FMA | Uso |
| --- | --- | --- | --- |
| R-REF-00 | `ea10fb6` | ligada | registro histórico |
| R-NOFMA-01 | `ea10fb6` | desligada | referência das fases 2A a 3 |
| **R-NOFMA-02** | tag `fase3-03-validada` | desligada | **referência atual** |

A R-NOFMA-02 tem dados idênticos aos da R-NOFMA-01; os 24 arquivos `monan2_import_*` têm atributos CF novos nos eixos. Em 27/09/2026 o MANIFEST dela recebeu uma observação sobre a reescrita do histórico (troca do autor dos commits), e a soma do MANIFEST no SHA256SUMS foi atualizada; o SHA256SUMS anterior está em `~/SHA256SUMS.R-NOFMA-02.antes-manifest`. Na mesma data, o `anota-linha-base.bash` registrou nele que o submódulo MONAN-Model usado é o `01962f0`. O MANIFEST marca "árvore suja" por causa do submódulo `models/atmos/MONAN-Model`, que está num commit diferente do registrado no repositório desde antes da refatoração; o código do acoplador estava limpo.

## 5. Como validar uma alteração

```bash
export COUPLER_ROOT=/p/projetos/gta/daniel.massaru/refatorado/Coupler-Install/MONAN-Coupler
cd $COUPLER_ROOT
source run/setenv-gnu.bash > /tmp/setenv.txt 2>&1   # nunca dentro de um encadeamento com |
grep -E 'MPAS_DIR|MOM6_ROOT' /tmp/setenv.txt         # os dois dentro de /refatorado/
make clean && make 2>&1 | tee ../make.log
grep -c 'Error' ../make.log                          # esperado: 0
bash tools/dev/valida_rodada.bash prepara <nome>
bash tools/dev/valida_rodada.bash submete <nome>
bash tools/dev/valida_rodada.bash compara <nome>
```

Resultado esperado contra a R-NOFMA-02: 73 iguais, 0 com metadados diferentes, PASS. O roteiro completo está em `docs/validacao-refatoracao.md`.

## 6. Armadilhas já encontradas

| Situação | Sintoma | Como evitar |
| --- | --- | --- |
| FMA ligada | versões diferentes do código divergem no último bit, a partir de 01:10 do primeiro dia | compilar com `FP_CONTRACT=off` (padrão); com FMA, criar linha de base própria |
| `COUPLER_ROOT` definido depois do `setenv` | executável ligado às bibliotecas da instalação de produção; FAIL sem mudança de cálculo | definir antes; o `prepara` e o `--check` acusam |
| `source setenv ... \| grep` | `ESMFMKFILE não definido` no make | redirecionar para arquivo, como no roteiro |
| Colar blocos longos no terminal | comandos misturados com saída anterior; diretórios preparados pela metade | usar o `valida_rodada.bash`, um comando por vez |
| MANIFEST da linha de base editado à mão | `compara` para antes de comparar, com `MANIFEST.txt: FAILED` | anotar com `anota-linha-base.bash`; se já foi editado, `anota-linha-base.bash -r` |
| Mudança de atributos NetCDF | "difere só nos METADADOS" | não reprova; conferir com `ncdump -h` que é a mudança esperada |
| `python3` do sistema na Jaci é o 3.6 | script Python pára com `TypeError: ... unexpected keyword argument 'capture_output'` (recurso do 3.7) ou com `UnicodeEncodeError` ao imprimir acentos com o locale C | scripts de `tools/dev/` escritos para o Python 3.6: `subprocess.run` com `stdout=subprocess.PIPE` e decodificação UTF-8 explícita; conferir com `vermin -t=3.6-` |
| Arquivos que não compilam fora da Jaci com as bibliotecas reais | `mpas_atm_model.F90`, `sis_cap_MONAN.F90` e `mom_cap_MONAN.F90` dependem de bibliotecas do MPAS, MOM6, FMS e SIS2 | fora da Jaci, compilam só contra as interfaces mínimas de `tests/interfaces/`, que conferem tipos e assinaturas; a compilação na Jaci continua sendo a conferência final |

## 7. Ferramentas de apoio

| Ferramenta | Função |
| --- | --- |
| `tools/dev/valida_rodada.bash` | prepara, submete e compara uma rodada de validação |
| `tools/dev/cria-linha-base.bash` | grava uma linha de base a partir de uma rodada |
| `tools/dev/compara-linha-base.bash` | compara dados (`nccmp -d`) e metadados; opção `-e` confere entradas |
| `tools/dev/anota-linha-base.bash` | anota o MANIFEST de uma base congelada e atualiza a soma dele (`-r` registra uma edição já feita) |
| `tests/regrid/` | testes MPI do framework de interpolação (`make test NP=4`) |
| `tools/dev/confere-tudo.bash` | todas as conferências locais de uma vez, com resumo e indicadores |
| `tools/dev/indicadores.py` | indicadores de código limpo de uma ou mais versões |
| `tools/dev/compila-local.bash` | compila o acoplador fora da Jaci (ESMF local e interfaces mínimas de `tests/interfaces/`) |
| `tools/dev/confere-literais.py` | compara as constantes de texto com as de um commit |
| `tools/dev/confere-instrucoes.py` | compara as instruções de um fonte com as de um commit |
| `tests/writers/compara-gravadores.bash` | compara byte a byte os arquivos dos gravadores de diagnóstico de duas versões (mediador, cap atmosférico e DOCN) |
| `tests/bulk/compara-bulk.bash` | compara bit a bit os campos calculados por `calc_bulk_ncar` em duas versões |
| `tests/unit/roda-unitarios.bash` | testes com valor esperado (fórmulas comparadas com valores calculados à parte) |
| `tests/atmgrid/compara-grade-atm.bash` | compara bit a bit a passagem das células MPAS para a grade 360 x 180 do cap atmosférico (`mpas_export`) em duas versões |
| `tests/supergrid/compara-supergrid.bash` | compara bit a bit a leitura do supergrid do MOM6 (`mom6_supergrid_mod`) em duas versões, com supergrids sintéticos e casos de erro |
| `tests/docn/compara-docn.bash` | roda o DOCN num driver NUOPC mínimo, com dados sintéticos, e compara bit a bit os campos exportados, os diagnósticos e as mensagens de duas versões |
| `tests/unit/test_cpl_map.F90` | consistência do mapa de acoplamento nas cinco combinações de `&nuopc_mode` e contra as listas de campos do mediador (roda com `roda-unitarios.bash`) |
| `tools/dev/mapa-acoplamento.py` | gera `docs/acoplamento.md` a partir do mapa de acoplamento; com `-c`, confere se ele está em dia (conferência `mapa`) |
| `tests/unit/test_cpl_check.F90` | rotinas de conferência de `cpl_check` com as listas de campos dos caps e com defeitos de propósito |
| `tests/cplcheck/confere-cplcheck.bash` | conferência do mapa num driver NUOPC mínimo com as listas de hoje, nos casos normal e com defeitos (conferência `cplcheck`) |
| `relatorio_acoplamento.txt` (em cada rodada) | linhas `CPL-REL:` do log, gravadas e comparadas com as da rodada aprovada anterior pelo `valida_rodada.bash compara` (`docs/validacao-refatoracao.md`, seção 2.1) |

O uso das ferramentas de conferência local, antes de levar uma mudança à Jaci, está em `docs/conferencias-locais.md`.

## 8. Pendências e próximos passos

Sequência combinada em 27/09/2026. Cada item de código é um patch validado na Jaci contra a R-NOFMA-02 antes do seguinte.

| Ordem | Etapa | Conteúdo | Situação |
| --- | --- | --- | --- |
| 1 | R-FASE4-04 | ferramentas de conferência local no repositório (`compila-local.bash`, `confere-literais.py`, `confere-instrucoes.py`, interfaces mínimas, teste dos gravadores) e documentação | concluída (compilação na Jaci sem erros, tag `fase4-04-validada`) |
| 2 | (Daniel) | enviar `refactor/principal` ao GitHub (sem pedido de integração por enquanto) e repetir o envio a cada etapa validada | feito em 27/09/2026 (`9ef3183`, tags `fase4-01-validada` a `fase4-04-validada`) |
| 3 | R-FASE4-05 | dividir `update_ice_fields_on_atm_grid` (`MED_cap`, 222 linhas de código) e `compute_ice_fluxes` (`med_bulk_ncar`, 224), numa rodada só; a segunda é cálculo de fluxo, e a ordem das operações tem de ficar intacta | concluída (PASS, 73 iguais, tag `fase4-05-validada`) |
| 4 | R-FASE4-06 | dividir `WriteDOCNDiag` (`docn_cap_netcdf`, 210); estender o teste dos gravadores a ele, porque a linha de base não roda com DOCN | concluída (PASS, 73 iguais, tag `fase4-06-validada`) |
| 5 | R-FASE4-07 | cap do gelo: dividir o `InitializeRealize` (202) e refinar os `intent` hoje `intent(inout)` por precaução; antes, escrever interfaces mínimas do SIS2 para compilar `sis_cap_MONAN.F90` fora da Jaci | concluída (PASS, 73 iguais, tag `fase4-07-validada`) |
| 6 | R-FASE4-08 | `nuopc.input` do repositório com as contagens de PETs da configuração de validação (128 + 20 + 4), as mesmas dos experimentos de reprodutibilidade; só mudam `atm_pet_count` e `ocn_pet_count` | concluída (valores iguais aos da linha de base, tag `fase4-08-validada`) |
| 7 | (opcional) | trocar os três arquivos de `MPI_Allreduce` por uma interface genérica com `mpi_f08`; antes, confirmar na Jaci que o `cray-mpich` oferece o módulo `mpi_f08` com o gfortran | em avaliação (o `cray-mpich` 8.1.31 da Jaci oferece o `mpi_f08` para o gfortran 12.3, conferido em 27/09/2026): sem ganho de desempenho; o benefício é a conferência de tipos pelo compilador, mas a migração alcança cerca de 50 chamadas MPI em oito fontes. Recomendação: tirar da sequência principal e, se houver interesse, só juntar os três arquivos numa interface genérica `allreduce_sum` com `use mpi` |

A troca pelo `mpi_f08` ficou sem número de etapa: só entra na sequência se for decidida.

Decisões de 27/09/2026:

- o pedido de integração para o `develop` fica para depois das próximas etapas de limpeza; até lá, `refactor/principal` é atualizado no GitHub a cada etapa validada, com a tag correspondente;
- a verificação automática de compilação (antes prevista como R-FASE4-05) saiu da sequência: o repositório não usa GitHub Actions e a equipe ainda não tem experiência com a ferramenta. A conferência antes de cada envio continua manual, com `tools/dev/compila-local.bash` e as demais ferramentas de `docs/conferencias-locais.md`.

Fora da sequência, em paralelo:

- **Decisões do GT (não são refatoração):** se o esquema `mpassit` substitui o algoritmo atual do cap atmosférico (muda resultados e exige nova linha de base); e o destino do DATM, que o driver não registra (o `roda_repro_datm_mom6.sh` depende dele).
- O `config_read` (267 linhas de código) é quase todo declaração de namelist e fica como está.

Já concluído: as rotinas `mpas_atm_init`, `write_mpas_import_diag`, `med_write_import_fields` e `InitializeRealize` do oceano (R-FASE4-01), `MediatorAdvance` (R-FASE4-03), `update_ice_fields_on_atm_grid` e `compute_ice_fluxes` (R-FASE4-05), `WriteDOCNDiag` (R-FASE4-06) e o `InitializeRealize` do gelo (R-FASE4-07). Com isso, nenhuma rotina própria passa de 200 linhas de código, exceto o `config_read` (267, quase todo declaração de namelist).

### Fase 5: limpeza

Levantamento de 27/09/2026, depois da fase 4. Os números de marcas contam só linhas de comentário com marcas de histórico (`FIX`, `TODO-`, `Sprint`, `[N1]`, versões como `v12.0`, datas de correção); mensagens de log e nomes de diagnóstico, como `FIX-DIAG-*` e `B-ICE-DECOMP-01`, são constantes de texto e não mudam.

| Ordem | Etapa | Conteúdo | Situação |
| --- | --- | --- | --- |
| 1 | R-FASE5-01 | `nuopc.input`: comentários sem histórico, nomes de módulos e do driver corretos, grupos numerados de 1 a 9, nota da fração de gelo atualizada (caminho do `Si_ifrac` do SIS2 até o MPAS validado); `run_esmApp.jaci` sem o aviso de caminho não validado | concluída (PASS, 73 iguais, tag `fase5-01-validada`) |
| 2 | R-FASE5-02 | marcas de histórico nos comentários do mediador (`MED_cap` 38, `med_cap_types` 12, `med_bulk_ncar` 6, `med_cap_methods` 3, `med_cap_netcdf` 1); também comentários desatualizados e fragmentos de limpezas anteriores | concluída (PASS, 73 iguais, tag `fase5-02-validada`) |
| 3 | R-FASE5-03 | idem nos caps do oceano e do gelo (`mom_cap_MONAN` 23, `sis_cap_MONAN` 23, `DOCN_cap` 6, `docn_cap_netcdf` 1); também documentação desatualizada da fração de gelo do oceano | concluída (PASS, 73 iguais, tag `fase5-03-validada`) |
| 4 | R-FASE5-04 | idem no cap atmosférico e em `src/shared` (`mpas_cap_methods` 14, `mpas_cap_MONAN` 13, `mpas_cap_netcdf` 11, `mpas_atm_model` 3, `mpas_atm_types` 2, `DATM_cap` 2, `shared` 6); também documentação desatualizada e texto corrompido | concluída (PASS, 73 iguais, tag `fase5-04-validada`) |
| 5 | R-FASE5-05 | dividir `map_cells_to_regular_grid` (`mpas_cap_methods`, 192 linhas de código) | concluída (PASS, 73 iguais, tag `fase5-05-validada`; 40 linhas de código, sete etapas) |
| 6 | R-FASE5-06 | dividir `InitializeDataComplete` (`MED_cap`, 160) e `blend_albedo_with_ice` (`med_bulk_ncar`, 153; coberta pelo teste da física bulk) | concluída (PASS, 73 iguais, tag `fase5-06-validada`; 48 e 45 linhas de código) |
| 7 | R-FASE5-07 | scripts de pós-processamento com marcas de histórico nos comentários (`postproc_mom6_import.py` 89, `postproc_monan2_import.py` 63, `mede-taxa-repro.sh` 30 e outros) | concluída (PASS, 73 iguais, tag `fase5-07-validada`); marcas de 268 para 9 nos scripts Python e de 37 para 7 nos bash, as restantes são formatos de log e nomes de diagnóstico |

Para decidir (questão científica, não de refatoração): no cap do gelo, `is%aib%u_star` (velocidade de fricção sobre o gelo) é sempre zero, porque o mediador não a envia; o comentário no código aponta para esta nota.

Para decidir (DATM, fora da configuração de validação): em `DATM_cap.F90`, `ReadJRAFieldInterp` usa a época 2016-01-01 01:30:00 para o arquivo JRA55, enquanto comentários antigos diziam que ela fora trocada para 00:00. Com um arquivo que começa em 00:00, o instante inicial fica antes da época. Mudar a época altera resultados do modo DATM, então é uma decisão separada da limpeza.

Defeito conhecido (encontrado na R-FASE8-10, não corrigido): em `wind_10m_fallback` (`mpas_atm_fluxes.F90`), `associated(atm_state%pool_zgrid) .and. size(atm_state%pool_zgrid,1) > 1` pode avaliar `size` de um ponteiro não associado; com `-fcheck=all` a execução aborta se o vento de reserva estiver ativo e `zgrid` faltar. Não ocorre na configuração de validação. A correção é trocar o teste por dois `if` aninhados, sem efeito nos resultados quando `zgrid` existe; pode entrar numa etapa própria da fase 9.

Defeito conhecido (encontrado na R-FASE8-11, não corrigido): em `ReadOcnFieldInterp` (`docn_cap_netcdf.F90`), uma falha de leitura no PET 0 faz ele retornar antes do `ESMF_VMBroadcast`, e os outros PETs do DOCN ficam esperando: a execução trava. O caso mais provável é um arquivo de correntes sem uma das variáveis, em que o código pretendia seguir com corrente zero. Não ocorre na configuração de validação (sem DOCN). A correção (difundir o código de retorno do PET 0 antes do campo) muda o comportamento em caso de erro e fica para uma etapa própria.

Numeração provisória, na ordem da tabela. As etapas 2 a 4 só mudam comentários: a conferência das instruções tem de mostrar zero diferenças.

### Fases 6 a 10: roteiro para código limpo

Decisões de 28/09/2026: o DTN-01 fica de lado por enquanto (o levantamento está em `docs/conformidade-dtn01.md`); a integração de `refactor/principal` ao `develop` só acontece ao fim da limpeza. O roteiro completo, com os indicadores de partida e as metas, está em `docs/roteiro-codigo-limpo.md`.

| Fase | Objetivo | Etapas previstas | Situação |
| --- | --- | --- | --- |
| 6 | rede de segurança: `confere-tudo.bash`, script de indicadores, testes com valor esperado | R-FASE6-01 a R-FASE6-03 | R-FASE6-01 concluída (PASS, 73 iguais, tag `fase6-01-validada`); R-FASE6-02 concluída (PASS, 73 iguais, tag `fase6-02-validada`); R-FASE6-03 concluída (PASS, 73 iguais, tag `fase6-03-validada`); fase concluída |
| 7 | estado explícito: variáveis de módulo com estado de componente levadas ao tipo interno de cada componente | R-FASE7-01 a R-FASE7-06 | R-FASE7-01 concluída (PASS, 73 iguais, tag `fase7-01-validada`); R-FASE7-02 concluída (PASS, 73 iguais, tag `fase7-02-validada`); R-FASE7-03 concluída (PASS, 73 iguais, tag `fase7-03-validada`); R-FASE7-04 concluída (PASS, 73 iguais, tag `fase7-04-validada`); R-FASE7-05 concluída (PASS, 73 iguais, tag `fase7-05-validada`); R-FASE7-06 concluída (PASS, 73 iguais, tag `fase7-06-validada`); fase 7 concluída |
| 8 | módulos coesos: `MED_cap.F90` e `mpas_atm_model.F90` divididos por assunto; rotinas entre 100 e 150 linhas revistas | R-FASE8-01 em diante (a R-FASE8-03 virou uma etapa por rotina) | R-FASE8-01 concluída (PASS, 73 iguais, tag `fase8-01-validada`); R-FASE8-02 concluída (PASS, 73 iguais, tag `fase8-02-validada`); R-FASE8-03 concluída (PASS, 73 iguais, tag `fase8-03-validada`); R-FASE8-04 concluída (PASS, 73 iguais, tag `fase8-04-validada`); R-FASE8-05 concluída (PASS, 73 iguais, tag `fase8-05-validada`); R-FASE8-06 concluída (PASS, 73 iguais, tag `fase8-06-validada`); R-FASE8-07 concluída (PASS, 73 iguais, tag `fase8-07-validada`); R-FASE8-08 concluída (PASS, 73 iguais, tag `fase8-08-validada`); R-FASE8-09 concluída (PASS, 73 iguais, tag `fase8-09-validada`); R-FASE8-10 concluída (PASS, 73 iguais, tag `fase8-10-validada`); R-FASE8-11 concluída (PASS, 73 iguais, tag `fase8-11-validada`), com ela terminam as revisões de rotinas longas; R-FASE8-12 concluída (PASS, 73 iguais, tag `fase8-12-validada`), primeira das quatro divisões de arquivo; R-FASE8-13 concluída (PASS, 73 iguais, tag `fase8-13-validada`); R-FASE8-14 concluída (PASS, 73 iguais, tag `fase8-14-validada`); R-FASE8-15 concluída (PASS, 73 iguais, tag `fase8-15-validada`), última das quatro divisões de arquivo; fase concluída |
| 9 | duplicação e consistência; ao fim, RPQ atualizado e integração ao `develop` | R-FASE9-01 a R-FASE9-07 | R-FASE9-01 concluída (PASS, 73 iguais, tag `fase9-01-validada`); R-FASE9-02 concluída (PASS, 73 iguais, tag `fase9-02-validada`); R-FASE9-03 concluída (PASS, 73 iguais, tag `fase9-03-validada`); R-FASE9-04 concluída (PASS, 73 iguais, tag `fase9-04-validada`), pedida em 29/09/2026 para reduzir os trechos repetidos; R-FASE9-05 concluída (PASS, 73 iguais, tag `fase9-05-validada`); R-FASE9-06 concluída (PASS, 73 iguais, tag `fase9-06-validada`); R-FASE9-07 encerra a fase (só documentação); fase concluída, RPQ na sexta versão, integração ao `develop` pelo procedimento abaixo |
| 10 | trilha de decisões que podem mudar resultados (DATM, `u_star`, precisão da configuração, `-fdefault-real-8`, variáveis não inicializadas, `mpassit`) | uma etapa por decisão | aguardando decisões |
| 11 | arquitetura de acoplamento: malhas, campos e trocas descritos em `src/coupling/`, trocas do mediador em `med_exchange.F90`, sem mudar resultados | R-FASE11-01 a R-FASE11-25 (plano em `docs/arquitetura-acoplamento.md`, seção 4) | R-FASE11-01 concluída (só documentação e ferramentas, tag `fase11-01-validada`); R-FASE11-02 concluída (mapa de acoplamento, sem uso pelos componentes; PASS, 73 iguais, tag `fase11-02-validada`); R-FASE11-03 concluída (conferência do mapa e relatório dos conectores no log; PASS, 73 iguais, tag `fase11-03-validada`; no log do PET 0, `conferencia do mapa: 0 diferenca(s), 3 aviso(s)`); R-FASE11-04 concluída (relatório das rotas e comparação do relatório no `valida_rodada`; PASS, 73 iguais, tag `fase11-04-validada`); R-FASE11-04-FIX01 concluída (linhas dos pontos completados no último passo; PASS, 73 iguais, tag `fase11-04-fix01`); R-FASE11-05 concluída (campos do mediador a partir do mapa; PASS, 73 iguais, tag `fase11-05-validada`; relatório de acoplamento igual ao da `fase11-04-fix01`); R-FASE11-06 concluída (campos dos caps do MOM6 e do SIS2 a partir do mapa; PASS, 73 iguais, tag `fase11-06-validada`; relatório de acoplamento igual ao da `fase11-05-validada`); R-FASE11-07 concluída (campos dos caps do MONAN-A, do DOCN e do DATM a partir do mapa; fim do bloco B; PASS, 73 iguais, tag `fase11-07-validada`; relatório de acoplamento igual ao da `fase11-06-validada`); R-FASE11-08 concluída (malhas regulares do lado atmosférico por `cpl_grids`; início do bloco C; PASS, 73 iguais, tag `fase11-08-validada`; relatório de acoplamento igual ao da `fase11-07-validada`); R-FASE11-09 concluída (fórmulas de índice e de longitude em `cpl_grids`; PASS, 73 iguais, tag `fase11-09-validada`; relatório de acoplamento igual ao da `fase11-08-validada`); R-FASE11-10 concluída (malhas `ocn_med` e `ice_sis2` por `cpl_grids`; PASS, 73 iguais, tag `fase11-10-validada`; relatório de acoplamento igual ao da `fase11-09-validada`); R-FASE11-11 concluída (grade do cap do MOM6 por `cpl_grids`; fim do bloco C; PASS, 73 iguais, tag `fase11-11-validada`; relatório de acoplamento igual ao da `fase11-10-validada`); R-FASE11-12 concluída (rotas do mediador pela tabela `ROTAS`; início do bloco D; PASS, 73 iguais, tag `fase11-12-validada`; relatório de acoplamento igual ao da `fase11-11-validada`); R-FASE11-13 concluída (`sem_valor` e `nan_para` pela rota; PASS, 73 iguais, tag `fase11-13-validada`; relatório de acoplamento igual ao da `fase11-12-validada`); R-FASE11-14 concluída (etapa completar pela rota; fim do bloco D; PASS, 73 iguais, tag `fase11-14-validada`; relatório de acoplamento igual ao da `fase11-13-validada`); R-FASE11-15 entregue (fase `entregar` em `med_exchange`; início do bloco E), aguardando a validação; próxima: R-FASE11-16 |

### Fase 11: arquitetura de acoplamento

Decisões de 30/09/2026:

- a fase de arquitetura recebe o número 11, e a 10 continua reservada às decisões que mudam resultados; as duas podem andar em paralelo, nunca na mesma etapa;
- a integração ao `develop` fica para mais adiante, por decisão do Daniel; o procedimento abaixo continua válido e deve ser refeito com o nome da última etapa validada no passo 1 e na mensagem do passo 6;
- as regras são as das fases 1 a 9, e cada tipo de mudança tem a sua conferência local (`docs/arquitetura-acoplamento.md`, seção 4.2);
- os testes do supergrid do MOM6 (usado na R-FASE9-05) e do DOCN (usado na R-FASE8-11), antes avulsos, passam a fazer parte do repositório e de `confere-tudo.bash`, porque as etapas dos blocos B, C e F dependem deles.

Achados ao escrever o mapa (R-FASE11-02), nenhum corrigido, porque a fase 11 não muda resultados:

- Sem o SIS2, `legacy_ice_fraction` (`med_bulk_ncar`) procura `Si_ifrac` no importState do mediador para interpolá-lo pela rota `ocn2atm`, mas o mediador não anuncia esse campo: a busca sempre falha e a fração de gelo sai do OISST ou da SST. A única chamada de rota na física (indicador da fase) nunca interpola. A R-FASE11-18, que tira essa interpolação de `calc_bulk_ncar`, tem de preservar esse comportamento; retirar o trecho é decisão da fase 10.
- Os arquivos `mom6_import_*.nc` gravam `Foxx_sen` e `Fioi_sen` com `standard_name = surface_upward_sensible_heat_flux`, mas `med_bulk_ncar` os calcula positivos para a superfície (ρ cp Ch |V| (Tar - Tsup)), como diz o comentário do cap do SIS2. O dicionário de campos registra a convenção do cálculo. Corrigir o atributo muda só metadados desses arquivos ("difere só nos METADADOS" na comparação); fica para uma etapa própria, se decidido.
- O DOCN não exporta `So_omask`: com ele, o campo do mediador fica sem origem. Com o DOCN e `use_med_to_mpas=.false.`, `Sx_tsfc`, `Sf_albedo` e `Sx_omask` não chegam ao MONAN-A, e o cap atmosférico interrompe a rodada (comportamento já conhecido, agora registrado no teste do mapa).

Achado da R-FASE11-10, não corrigido pelo mesmo motivo: com o DOCN (`use_docn=.true.`), o mediador descreve a grade do OISST (`ocn_med`) com a longitude do centro de cada célula igual à do canto oeste, `(i-1)*360/nx`, sem a meia célula, enquanto a latitude do centro tem a meia célula. O cap do DOCN põe os centros na meia célula (`(i-0,5)*dx`), então as duas grades não coincidem: o conector DOCN para MED interpola os valores para pontos a meia célula (0,125° no OISST de 0,25°) dos dados, o que não desloca o campo mas o suaviza em longitude, onde bastaria uma cópia. A rodada de validação não usa o DOCN. A construção ficou preservada em `cpl_grids` como a origem `ORIGEM_LESTE0_CANTO`; corrigir seria trocá-la por `ORIGEM_LESTE0`, com uma linha de base própria para o DOCN.

Observação da R-FASE11-03, confirmada na rodada de validação da Jaci (01/10/2026): a CplList de cada conector sai em ordem alfabética (no conector MPAS para MED, o primeiro campo é `Faxa_lat_mpas`, embora o cap anuncie `Sa_pslv_mpas` primeiro), como no driver de teste local. A ordem do anúncio, portanto, não define a ordem dos campos nos conectores; o cuidado da seção 4.6 do documento de arquitetura sobre a ordem dos campos anunciados vale para a ordem dos estados (e de tudo que percorre os estados), não para os conectores.

Resultado da R-FASE11-04 na Jaci (01/10/2026): as seis rotas do mediador foram criadas com o primeiro método pedido; `ocn2atm_sst`, `ocn2atm_ice` e `atm2ocn_ice` usam o conservativo, nenhuma caiu na reserva. As linhas `completar` não saíram: a R-FASE11-04 as escrevia na finalização do mediador, e o `esmApp.F90` não chama `ESMF_GridCompFinalize` (a limpeza do ESMF é incompatível com o MOAB e o SMIOL). A R-FASE11-04-FIX01 as escreve no último passo. Lição para as próximas etapas: nada que precise rodar no fim pode depender da finalização dos componentes.

Pontos completados na produção (R-FASE11-04-FIX01, 01/10/2026; 24 passos, soma dos PETs), referência que a R-FASE11-14 tem de reproduzir:

| Linha | Fora da faixa | Com valor fixo |
| --- | --- | --- |
| `ocn2atm_sst So_t` | 556 662 | 70 224 |
| `ocn2atm_ice Si_ifrac_sis2` e os quatro albedos | 478 584 cada | 439 896 cada |
| `ocn2atm_ice Si_t_sis2` | 537 440 | 497 998 |
| `atm2ocn_ice Si_ifrac` | 0 | 0 |

Leitura: na SST, cerca de 23 mil pontos por passo (a terra, na malha de fluxo de 64 800 pontos) ficam fora da faixa e quase todos são completados pela difusão, porque a SST não tem limiar de fração (`skip_fraction` = 1). Nos campos do gelo, cerca de 92% dos pontos fora da faixa recebem o valor fixo: com o limiar padrão de 25%, os PETs com muita terra ou sem gelo pulam a difusão. Na fração de gelo exportada, a rota conservativa alcança todos os pontos da grade do oceano, e o preenchimento não completa nada na produção.

Indicadores da fase na partida (`fase9-07-validada`): 8 arquivos com nomes de campos anunciados ou realizados à mão; 7 chamadas `ESMF_GridCreate*` em 6 arquivos; 7 pontos de criação de rota em 5 arquivos; 1 chamada de rota na física; 5 arquivos que carimbam o tempo. As metas estão no documento de arquitetura, seção 4.4.

### Integração de `refactor/principal` ao `develop`

Autorizada em 29/09/2026, depois da R-FASE9-07; adiada em 30/09/2026 (ver fase 11). A refatoração partiu do commit `ea10fb6` do `develop`. Na Jaci, um comando por vez, na raiz do repositório:

| Passo | Comando | O que conferir |
| --- | --- | --- |
| 1 | `git status` | árvore limpa, no ramo `refactor/principal`, com a R-FASE9-07 aplicada |
| 2 | `git fetch origin` | traz o estado atual do GitHub |
| 3 | `git merge-base --is-ancestor origin/develop refactor/principal && echo SEM-NOVIDADES` | `SEM-NOVIDADES`: o `develop` não recebeu commits desde `ea10fb6` |
| 4 | `git checkout develop` | troca de ramo |
| 5 | `git merge --ff-only origin/develop` | `develop` local igual ao do GitHub |
| 6 | `git merge --no-ff refactor/principal -m "Integra a refatoracao (fases 1 a 9) ao develop"` | um commit de integração, sem conflitos |
| 7 | `git diff refactor/principal develop --stat` | vazio: a árvore do `develop` é a mesma da refatoração validada |
| 8 | `git tag refatoracao-integrada` | marca o ponto de integração |
| 9 | `git push origin develop` | envia o `develop` |
| 10 | `git push origin refatoracao-integrada` | envia a tag |

Se o passo 3 não imprimir `SEM-NOVIDADES`, o `develop` recebeu commits depois de `ea10fb6`: o passo 6 pode ter conflitos, e o passo 7 não fica vazio. Nesse caso, resolver os conflitos, compilar e repetir a rodada de validação no `develop` integrado antes do passo 8. O `--no-ff` guarda um commit de integração mesmo quando o avanço direto seria possível, o que deixa claro no histórico onde a refatoração entrou. O ramo `refactor/principal` e as tags `faseN-NN-validada` continuam no GitHub como registro.

## 9. Convenções

As convenções de código estão no `README.md` (seção de convenções). Em resumo: sem BLOCK; procedimentos de módulo com `intent` em vez de procedimentos internos; interpolação só por rotas do `regrid_manager_t`; erros com `ChkErr`; constantes em `coupler_constants`; NetCDF por `nc_writer`; configuração só em `coupler_config.F90`; comentários explicam o que e por quê, o histórico fica no CHANGELOG; toda mudança validada contra a linha de base.

Commits: autor Daniel Massaru <dmassaru@gmail.com>, sem linhas de coautoria nem outras marcas de ferramentas nas mensagens ou nos arquivos (decisão de 29/09/2026). As mensagens das etapas R-FASE4-01 a R-FASE8-13 foram limpas nessa data com `git filter-branch` (script avulso `remove-coautoria.bash`), sem mudar nenhum arquivo; por isso os códigos (hashes) dos commits e das tags `fase4-*` a `fase8-*` da `refactor/principal` mudaram, e o envio ao GitHub foi forçado. A cópia anterior ficou na branch local `backup/antes-sem-coautoria` da Jaci.

## 10. Para retomar o trabalho em outro ambiente

O trabalho segue a fase 11. O plano está em `docs/arquitetura-acoplamento.md` (seção 4.3, etapas; seção 6, próximo passo) e o andamento, na seção 8 deste documento e no `docs/CHANGELOG.md`.

### 10.1 Numa nova conversa ou com outra pessoa

Basta o ramo `refactor/principal` do GitHub e a descrição do que fazer, por exemplo: "retomar a fase 11 a partir da R-FASE11-02". Os documentos que dão o contexto estão no próprio repositório:

| Documento | Para quê |
| --- | --- |
| `docs/estado-do-projeto.md` | este documento: ambiente, etapas, linhas de base, pendências e decisões |
| `docs/arquitetura-acoplamento.md` | arquitetura proposta e plano da fase 11 |
| `docs/CHANGELOG.md` | o que cada etapa mudou, com as conferências e a validação |
| `docs/conferencias-locais.md` | como conferir uma mudança antes da rodada na Jaci |
| `docs/roteiro-codigo-limpo.md` | critérios, indicadores e metas das fases 6 a 11 |

O relatório técnico (RPQ, sexta versão) e a nota técnica da arquitetura (NTC) ficam fora do repositório, em PDF e com a fonte LaTeX.

### 10.2 Ambiente para as conferências locais

Numa máquina Ubuntu 24.04 (ou semelhante), sem as bibliotecas dos modelos. A compilação do ESMF leva cerca de 40 minutos na primeira vez; depois, `compila-local.bash` leva menos de um minuto e `confere-tudo.bash` cerca de nove.

| Passo | Comando |
| --- | --- |
| 1. Pacotes | `apt-get install -y gfortran g++ make git python3 openmpi-bin libopenmpi-dev libnetcdff-dev netcdf-bin` |
| 2. Fonte do ESMF | `git clone --depth 1 --branch v8.9.1 https://github.com/esmf-org/esmf.git $HOME/esmf` |
| 3. Variáveis da compilação | `ESMF_DIR=$HOME/esmf ESMF_COMPILER=gfortran ESMF_COMM=mpich ESMF_NETCDF=nc-config ESMF_BOPT=O ESMF_PIO=OFF ESMF_INSTALL_PREFIX=$HOME/esmf-install`, todas exportadas |
| 4. Compilação e instalação | `cd $HOME/esmf && make -j2 lib && make install` |
| 5. Arquivo de configuração | `export ESMFMKFILE=$HOME/esmf-install/lib/libO/Linux.gfortran.64.mpich.default/esmf.mk` |
| 6. Execução MPI (Open MPI como root) | `export MPIRUN="mpirun.openmpi --allow-run-as-root --oversubscribe"` |
| 7. Código | `git clone --branch refactor/principal https://github.com/GTA-DIMNT-CPTEC/MONAN-Coupler.git` |
| 8. Conferência | na raiz do repositório, `tools/dev/confere-tudo.bash HEAD`: todas as conferências OK |

Com `ESMF_COMM=mpich`, o ESMF usa o `mpif90` do sistema, que no Ubuntu é o do Open MPI; foi assim que as conferências das fases 6 a 11 rodaram. Sem `--allow-run-as-root`, o Open MPI se recusa a rodar como root, o que é comum em contêineres.

### 10.3 Entrega de uma etapa

1. Conferências locais: `tools/dev/confere-tudo.bash HEAD` antes do commit (ou `HEAD~1` depois), com `-i` quando a etapa só muda comentários.
2. Um commit, autor Daniel Massaru <dmassaru@gmail.com>, sem linhas de coautoria nem marcas de ferramentas (seção 9).
3. `git format-patch -1 --stdout > R-FASE11-NN.patch`; informar `head -1` e `md5sum` do arquivo.
4. Na Jaci, um comando por vez: `git am`, compilação e `valida_rodada.bash` (seção 5); com PASS, `git tag fase11-NN-validada` e envio do ramo e da tag ao GitHub.
5. Atualizar este documento, o CHANGELOG, o roteiro e, nesta fase, o documento de arquitetura.
