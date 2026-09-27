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

O detalhe de cada etapa está em `docs/CHANGELOG.md` e no relatório técnico (RPQ, versão 2).

## 4. Linhas de base

| Rótulo | Código | FMA | Uso |
| --- | --- | --- | --- |
| R-REF-00 | `ea10fb6` | ligada | registro histórico |
| R-NOFMA-01 | `ea10fb6` | desligada | referência das fases 2A a 3 |
| **R-NOFMA-02** | tag `fase3-03-validada` | desligada | **referência atual** |

A R-NOFMA-02 tem dados idênticos aos da R-NOFMA-01; os 24 arquivos `monan2_import_*` têm atributos CF novos nos eixos. Em 27/09/2026 o MANIFEST dela recebeu uma observação sobre a reescrita do histórico (troca do autor dos commits), e a soma do MANIFEST no SHA256SUMS foi atualizada; o SHA256SUMS anterior está em `~/SHA256SUMS.R-NOFMA-02.antes-manifest`. O MANIFEST também marca "árvore suja" por causa do submódulo `models/atmos/MONAN-Model`, que está num commit diferente do registrado no repositório desde antes da refatoração; o código do acoplador estava limpo.

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

## 8. Pendências e próximos passos

1. Enviar a refatoração ao GitHub num ramo próprio e abrir um pedido de integração (pull request) para o `develop`.
2. Verificação automática de compilação a cada envio ao repositório. Os fontes que não dependem do MPAS, MOM6 e FMS compilam com ESMF e NetCDF instalados; os demais precisam das bibliotecas dos modelos.
3. Refinar os `intent` dos procedimentos do cap do gelo (hoje `intent(inout)` por precaução).
4. Decidir se o esquema `mpassit` substitui o algoritmo atual do cap atmosférico (muda resultados; decisão científica).
5. Decidir o destino do DATM, que o driver não registra (o script `roda_repro_datm_mom6.sh` depende dele).
6. Trocar os três arquivos de `MPI_Allreduce` por uma interface genérica com `mpi_f08`.
7. Dividir as rotinas que ainda passam de 200 linhas de código (sem comentários): `MediatorAdvance` (308), `compute_ice_fluxes` (224), `update_ice_fields_on_atm_grid` (222), `WriteDOCNDiag` (210) e `InitializeRealize` do cap do gelo (202). O `config_read` (267) é quase todo declaração de namelist e pode ficar como está. As quatro rotinas listadas antes foram divididas na R-FASE4-01.
8. Registrar no MANIFEST da R-NOFMA-02 que o submódulo MONAN-Model usado é o `01962f0` (a linha `MONAN-Model` já traz o commit; falta a observação que explica a "árvore suja"): `tools/dev/anota-linha-base.bash -o $REF/baseline -l R-NOFMA-02 -m "..."`.

## 9. Convenções

As convenções de código estão no `README.md` (seção de convenções). Em resumo: sem BLOCK; procedimentos de módulo com `intent` em vez de procedimentos internos; interpolação só por rotas do `regrid_manager_t`; erros com `ChkErr`; constantes em `coupler_constants`; NetCDF por `nc_writer`; configuração só em `coupler_config.F90`; comentários explicam o que e por quê, o histórico fica no CHANGELOG; toda mudança validada contra a linha de base.

## 10. Para retomar numa nova sessão do assistente

Envie, no início da conversa:

- este arquivo;
- o `docs/CHANGELOG.md`;
- o relatório RPQ em PDF (e a fonte LaTeX, se for atualizá-lo);
- o código atual: um arquivo `.tar.gz` do repositório no ramo `refactor/principal`, sem `build/`, `bin/` e `models/`, ou o link do ramo no GitHub, se o assistente tiver acesso.

E descreva o que quer fazer a seguir, por exemplo um dos itens da seção 8.
