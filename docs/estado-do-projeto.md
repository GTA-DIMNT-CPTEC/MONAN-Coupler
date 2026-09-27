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
| R-FASE4-05 | `update_ice_fields_on_atm_grid` e `compute_ice_fluxes` divididas em etapas; teste da física bulk (`tests/bulk`) (validação na Jaci pendente) |

O detalhe de cada etapa está em `docs/CHANGELOG.md` e no relatório técnico (RPQ, versão 3, que cobre todas as etapas até a R-FASE4-03).

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
| Arquivos que não compilam fora da Jaci | `mpas_atm_model.F90`, `sis_cap_MONAN.F90` e `mom_cap_MONAN.F90` dependem de bibliotecas do MPAS, MOM6 e FMS | mudanças nesses arquivos só são conferidas pela compilação na Jaci |

## 7. Ferramentas de apoio

| Ferramenta | Função |
| --- | --- |
| `tools/dev/valida_rodada.bash` | prepara, submete e compara uma rodada de validação |
| `tools/dev/cria-linha-base.bash` | grava uma linha de base a partir de uma rodada |
| `tools/dev/compara-linha-base.bash` | compara dados (`nccmp -d`) e metadados; opção `-e` confere entradas |
| `tools/dev/anota-linha-base.bash` | anota o MANIFEST de uma base congelada e atualiza a soma dele (`-r` registra uma edição já feita) |
| `tests/regrid/` | testes MPI do framework de interpolação (`make test NP=4`) |
| `tools/dev/compila-local.bash` | compila o acoplador fora da Jaci (ESMF local e interfaces mínimas de `tests/interfaces/`) |
| `tools/dev/confere-literais.py` | compara as constantes de texto com as de um commit |
| `tools/dev/confere-instrucoes.py` | compara as instruções de um fonte com as de um commit |
| `tests/writers/compara-gravadores.bash` | compara byte a byte os arquivos dos gravadores de diagnóstico de duas versões |
| `tests/bulk/compara-bulk.bash` | compara bit a bit os campos calculados por `calc_bulk_ncar` em duas versões |

O uso das quatro últimas, antes de levar uma mudança à Jaci, está em `docs/conferencias-locais.md`.

## 8. Pendências e próximos passos

Sequência combinada em 27/09/2026. Cada item de código é um patch validado na Jaci contra a R-NOFMA-02 antes do seguinte.

| Ordem | Etapa | Conteúdo | Situação |
| --- | --- | --- | --- |
| 1 | R-FASE4-04 | ferramentas de conferência local no repositório (`compila-local.bash`, `confere-literais.py`, `confere-instrucoes.py`, interfaces mínimas, teste dos gravadores) e documentação | concluída (compilação na Jaci sem erros, tag `fase4-04-validada`) |
| 2 | (Daniel) | enviar `refactor/principal` ao GitHub (sem pedido de integração por enquanto) e repetir o envio a cada etapa validada | feito em 27/09/2026 (`9ef3183`, tags `fase4-01-validada` a `fase4-04-validada`) |
| 3 | R-FASE4-05 | dividir `update_ice_fields_on_atm_grid` (`MED_cap`, 222 linhas de código) e `compute_ice_fluxes` (`med_bulk_ncar`, 224), numa rodada só; a segunda é cálculo de fluxo, e a ordem das operações tem de ficar intacta | entregue, a validar |
| 4 | R-FASE4-06 | dividir `WriteDOCNDiag` (`docn_cap_netcdf`, 210); estender o teste dos gravadores a ele, porque a linha de base não roda com DOCN | a fazer |
| 5 | R-FASE4-07 | cap do gelo: dividir o `InitializeRealize` (202) e refinar os `intent` hoje `intent(inout)` por precaução; antes, escrever interfaces mínimas do SIS2 para compilar `sis_cap_MONAN.F90` fora da Jaci | a fazer |
| 6 | R-FASE4-08 | trocar os três arquivos de `MPI_Allreduce` por uma interface genérica com `mpi_f08`; antes, confirmar na Jaci que o `cray-mpich` oferece o módulo `mpi_f08` com o gfortran | a fazer |

Numeração dos patches: provisória a partir da R-FASE4-06, na ordem da tabela.

Decisões de 27/09/2026:

- o pedido de integração para o `develop` fica para depois das próximas etapas de limpeza; até lá, `refactor/principal` é atualizado no GitHub a cada etapa validada, com a tag correspondente;
- a verificação automática de compilação (antes prevista como R-FASE4-05) saiu da sequência: o repositório não usa GitHub Actions e a equipe ainda não tem experiência com a ferramenta. A conferência antes de cada envio continua manual, com `tools/dev/compila-local.bash` e as demais ferramentas de `docs/conferencias-locais.md`.

Fora da sequência, em paralelo:

- **Decisões do GT (não são refatoração):** se o esquema `mpassit` substitui o algoritmo atual do cap atmosférico (muda resultados e exige nova linha de base); e o destino do DATM, que o driver não registra (o `roda_repro_datm_mom6.sh` depende dele).
- **Opcional:** `map_cells_to_regular_grid` (`mpas_cap_methods`, 192 linhas de código) já está abaixo do limite. O `config_read` (267) é quase todo declaração de namelist e fica como está.

Já concluído: as rotinas `mpas_atm_init`, `write_mpas_import_diag`, `med_write_import_fields` e `InitializeRealize` do oceano (R-FASE4-01) `MediatorAdvance` (R-FASE4-03), `update_ice_fields_on_atm_grid` e `compute_ice_fluxes` (R-FASE4-05, a validar).

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
