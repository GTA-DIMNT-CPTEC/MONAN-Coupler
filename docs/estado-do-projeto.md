# Estado do projeto: refatoração do MONAN-Coupler

Documento de passagem, para retomar o trabalho em outra sessão ou com outra pessoa sem precisar reconstruir o contexto. Atualizado na fase 4 (setembro de 2026).

## 1. O que é o projeto

O MONAN-Coupler acopla a atmosfera MONAN-A 2.0 (baseada no MPAS-A) ao oceano MOM6 e ao gelo marinho SIS2 por ESMF/NUOPC, com um mediador próprio que calcula os fluxos ar-mar. O código próprio do acoplador está em `src/` (Fortran moderno, compilado pelo `Makefile`). A refatoração teve uma regra única: melhorar a estrutura sem mudar nenhum resultado numérico, conferido bit a bit contra uma linha de base a cada etapa.

## 2. Ambiente

| Item | Valor |
| --- | --- |
| Repositório | `GTA-DIMNT-CPTEC/MONAN-Coupler`, partindo do commit `ea10fb6` do ramo `develop` |
| Ramo local da refatoração | `refactor/principal` (tag `fase3-03-validada` no último ponto validado) |
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
| R-FASE8-08 | `fill_ifrac_from_oisst`: número de instantes, leitura no PET 0 e remapeamento em rotinas próprias; conferida localmente com teste avulso (validação pendente) |
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

O uso das cinco últimas, antes de levar uma mudança à Jaci, está em `docs/conferencias-locais.md`.

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

Numeração provisória, na ordem da tabela. As etapas 2 a 4 só mudam comentários: a conferência das instruções tem de mostrar zero diferenças.

### Fases 6 a 10: roteiro para código limpo

Decisões de 28/09/2026: o DTN-01 fica de lado por enquanto (o levantamento está em `docs/conformidade-dtn01.md`); a integração de `refactor/principal` ao `develop` só acontece ao fim da limpeza. O roteiro completo, com os indicadores de partida e as metas, está em `docs/roteiro-codigo-limpo.md`.

| Fase | Objetivo | Etapas previstas | Situação |
| --- | --- | --- | --- |
| 6 | rede de segurança: `confere-tudo.bash`, script de indicadores, testes com valor esperado | R-FASE6-01 a R-FASE6-03 | R-FASE6-01 concluída (PASS, 73 iguais, tag `fase6-01-validada`); R-FASE6-02 concluída (PASS, 73 iguais, tag `fase6-02-validada`); R-FASE6-03 concluída (PASS, 73 iguais, tag `fase6-03-validada`); fase concluída |
| 7 | estado explícito: variáveis de módulo com estado de componente levadas ao tipo interno de cada componente | R-FASE7-01 a R-FASE7-06 | R-FASE7-01 concluída (PASS, 73 iguais, tag `fase7-01-validada`); R-FASE7-02 concluída (PASS, 73 iguais, tag `fase7-02-validada`); R-FASE7-03 concluída (PASS, 73 iguais, tag `fase7-03-validada`); R-FASE7-04 concluída (PASS, 73 iguais, tag `fase7-04-validada`); R-FASE7-05 concluída (PASS, 73 iguais, tag `fase7-05-validada`); R-FASE7-06 concluída (PASS, 73 iguais, tag `fase7-06-validada`); fase 7 concluída |
| 8 | módulos coesos: `MED_cap.F90` e `mpas_atm_model.F90` divididos por assunto; rotinas entre 100 e 150 linhas revistas | R-FASE8-01 em diante (a R-FASE8-03 virou uma etapa por rotina) | R-FASE8-01 concluída (PASS, 73 iguais, tag `fase8-01-validada`); R-FASE8-02 concluída (PASS, 73 iguais, tag `fase8-02-validada`); R-FASE8-03 concluída (PASS, 73 iguais, tag `fase8-03-validada`); R-FASE8-04 concluída (PASS, 73 iguais, tag `fase8-04-validada`); R-FASE8-05 concluída (PASS, 73 iguais, tag `fase8-05-validada`); R-FASE8-06 concluída (PASS, 73 iguais, tag `fase8-06-validada`); R-FASE8-07 concluída (PASS, 73 iguais, tag `fase8-07-validada`); R-FASE8-08 entregue (validação pendente) |
| 9 | duplicação e consistência; ao fim, RPQ atualizado e integração ao `develop` | R-FASE9-01 a R-FASE9-03 | a fazer |
| 10 | trilha de decisões que podem mudar resultados (DATM, `u_star`, precisão da configuração, `-fdefault-real-8`, variáveis não inicializadas, `mpassit`) | uma etapa por decisão | aguardando decisões |

## 9. Convenções

As convenções de código estão no `README.md` (seção de convenções). Em resumo: sem BLOCK; procedimentos de módulo com `intent` em vez de procedimentos internos; interpolação só por rotas do `regrid_manager_t`; erros com `ChkErr`; constantes em `coupler_constants`; NetCDF por `nc_writer`; configuração só em `coupler_config.F90`; comentários explicam o que e por quê, o histórico fica no CHANGELOG; toda mudança validada contra a linha de base.

## 10. Para retomar numa nova sessão do assistente

Envie, no início da conversa:

- este arquivo;
- o `docs/CHANGELOG.md`;
- o relatório RPQ em PDF (e a fonte LaTeX, se for atualizá-lo);
- o código atual: um arquivo `.tar.gz` do repositório no ramo `refactor/principal`, sem `build/`, `bin/` e `models/`, ou o link do ramo no GitHub, se o assistente tiver acesso.

E descreva o que quer fazer a seguir, por exemplo um dos itens da seção 8.

Para as conferências locais (`docs/conferencias-locais.md`), o assistente precisa compilar o ESMF 8.9.1 no próprio ambiente, o que leva cerca de 40 minutos no início da sessão; depois disso, `compila-local.bash` leva menos de um minuto.
