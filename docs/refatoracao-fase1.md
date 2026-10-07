# Refatoração do código Fortran: fase 1

Este documento registra a auditoria do código Fortran do MONAN-Coupler (ramo `develop`, commit `ea10fb6`, 24/09/2026) e a primeira fase da refatoração. O relatório técnico completo, no padrão da Biblioteca Digital do INPE, acompanha a entrega.

## Objetivo

Deixar o código mais claro e fácil de manter por uma equipe: sem código morto, sem duplicação, sem remendos e sem construções complicadas. A fase 1 reúne as mudanças de baixo risco, que não devem alterar resultados numéricos.

## Números

| Medida | Antes | Depois |
| --- | --- | --- |
| Arquivos Fortran em `src/` | 30 | 27 |
| Linhas em `src/` | 26 170 | 21 664 |
| Linhas de código (sem comentários e linhas vazias) | 16 098 | 13 482 |
| Blocos de erro com `ESMF_LogFoundError` escritos à mão | 438 | 87 (só os com mensagem própria) |
| `DOCN_cap.F90` | 1 287 linhas | 746 linhas |
| `esm.F90` | 1 253 linhas | 469 linhas |
| Leituras de `nuopc.input` por execução | 3 | 1 |

## O que mudou

**Módulos compartilhados.** `src/shared/coupler_utils.F90` reúne `ChkErr` e as conversões de texto que estavam repetidas em oito lugares. `src/shared/coupler_config.F90` substitui `src/caps/atmos/mpas_cap_config.F90`, que servia ao sistema inteiro apesar de estar na pasta da atmosfera. `src/shared/diag_bitsum.F90` recebe o módulo de soma de verificação que estava colado dentro de `MED_cap.F90`.

**Código morto removido.** Arquivos que não eram compilados (`ocn_comp_NUOPC.F90`, `upstream/mom_cap.F90`, `upstream/mom_cap_time.F90`), rotinas nunca chamadas (`config_print`, `mpas_atm_resize`, `RegridOptionalCurrent`, `WriteMOM6ImportDiag`, `fms2esmf_time`, `string_to_date`), atributos NUOPC que nenhum componente lia (`restart_n`, `stop_ymd`, `stop_tod`), 36 variáveis locais sem uso e trechos de código comentado.

**Duplicação removida.** O `DOCN_cap.F90` tinha cópias completas das rotinas de leitura e escrita de `docn_cap_netcdf.F90`, e as cópias já tinham divergido. Ficou uma só versão, com a checagem que existia apenas numa delas.

**Remendos removidos.** O cap ATM chamava o modelo por rotinas externas e um bloco `interface` em vez de usar o módulo; agora usa `mpas_atm_model_mod`. A configuração chegava ao mediador e ao cap ATM por atributos NUOPC em forma de texto, e num dos casos era lida antes de ser definida e depois relida para corrigir; agora os módulos consultam `coupler_config_mod`. Erros eram descartados com `if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS`; esses trechos saíram. O `Makefile` forçava a recompilação de dois arquivos a cada build para contornar dependências faltantes; as dependências foram completadas e o `FORCE` saiu.

**Driver e programa principal.** `esm.F90` descreve as sete RunSequences como listas curtas numa única rotina e isola a divisão de PETs em `split_pets`. `esmApp.F90` usa uma rotina `check` no lugar de treze blocos repetidos. As mensagens de log lidas pelas ferramentas de `tools/` foram mantidas.

## Mudanças de comportamento a validar no Jaci

| Mudança | Antes | Agora |
| --- | --- | --- |
| `write_diag` em `&nuopc_atm` | ignorado (o driver o forçava para falso) | respeitado |
| Grupo do namelist com erro de sintaxe | tratado como ausente, com valores padrão | erro fatal |
| `dt_atm <= 0` | aviso, e divisão por zero em seguida | erro fatal |
| `userRc` dos componentes | ignorado pelo `esmApp` | interrompe a execução |
| `use_mommesh`, `restart_n` em `&nuopc_ocn` | lidas, sem efeito | aviso de chave obsoleta |
| Entrada de `CplList` sem espaço para as opções de reprodutibilidade | aviso | erro |

## Validação feita

O ESMF 8.9.1 foi compilado com gfortran 13 e MPICH 4.2. Os fontes que não dependem das bibliotecas do MPAS, do MOM6 ou do FMS foram compilados antes e depois da refatoração, com módulos substitutos apenas para as interfaces externas: todos compilam sem erro. `mpas_atm_model.F90`, `mom_cap_MONAN.F90`, `sis_cap_MONAN.F90`, `time_utils.F90` e os três arquivos de `upstream/` não puderam ser compilados fora do Jaci; neles as mudanças são mecânicas e foram conferidas por verificação de balanço de blocos. Falta a compilação completa e uma rodada curta no Jaci, comparando com uma linha de base (`tools/dev/cria-linha-base.bash` e `compara-linha-base.bash`).

## Decisão pendente: DATM

`DATM_cap.F90` é compilado, mas o driver nunca o registra. Com `use_datm = .true.` o mediador anuncia campos que ninguém fornece e a execução não se completa; o `roda_repro_datm_mom6.sh` depende desse caminho. É preciso escolher entre registrar o DATM no driver ou retirá-lo.

## Próximas fases

| Fase | Conteúdo |
| --- | --- |
| 2 | Dividir `MediatorAdvance` (1 956 linhas), `calc_bulk_ncar` (883) e `MED InitializeRealize` (746) em rotinas menores; reunir as constantes físicas num módulo, conferindo valor a valor para não mudar resultados; uma só rotina de decomposição de grade (hoje em quatro cópias, com `int` e `nint` diferentes); um só `ReadMom6TGridDims` para MED e ICE; `mpi_f08` no lugar dos três arquivos de `MPI_Allreduce`; grade ATM 360 x 180 definida num único lugar |
| 3 | Trocar o calendário escrito à mão de `mpas_cap_netcdf.F90` por `ESMF_Time`; módulo auxiliar para os quatro escritores NetCDF; retirar dos comentários o histórico de correções (cerca de 743 marcas), que pertence ao CHANGELOG; verificação automática de compilação |
