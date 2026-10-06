# Inventário das sondas de investigação

Sondas são trechos que registram, no meio do cálculo, valores de investigações passadas (rótulos `FIX-DIAG-*` e `[MED-DIAG]`). Nenhuma muda resultado: só leem campos e escrevem no log. O inventário foi feito sobre `fase13-07-validada` (proposta P10 da NTC de análise da arquitetura), e o destino de cada uma foi decidido pelo Daniel em 06/10/2026.

| Rótulo | Onde | O que registra | Destino |
| --- | --- | --- | --- |
| `FIX-DIAG-BITSUM-01` | `diag_bitsum`, `med_diag`, `MED_cap`, `med_ice` | soma de bits de `Si_ifrac` em 4 etapas do caminho gelo para atmosfera; lida por `tools/coupler/mede-taxa-repro.sh` | fica: `DIAG ice_fraction bitsum etapa1` a `etapa4` (depuração; R-FASE13-10) |
| `FIX-DIAG-ICESRC-01` e `-02` | `med_ice` | `Si_ifrac` antes e depois da interpolação, com 15 a 17 algarismos; 01 lida por `mede-taxa-repro.sh` | fica: `DIAG ice_fraction source` e `destination` (depuração; R-FASE13-10) |
| `FIX-DIAG-ICEMASK-01` e `-02` | `med_exchange`, `med_ice` | máscara do oceano vista pelo PET; fração de gelo antes da extrapolação; lidas por `mede-taxa-repro.sh` | fica: `DIAG ocean_mask` e `DIAG ice_fraction raw` (depuração; R-FASE13-10) |
| `FIX-DIAG-ICESTAB-01` | `med_bulk_ncar` | células que saturam o fator de estabilidade sobre o gelo | fica: `DIAG ice_stability` (depuração; R-FASE13-10) |
| `FIX-DIAG-ICEGEO-01` | `med_ice` | alerta de gelo em latitude implausível | fica: aviso "gelo em latitude implausível" (R-FASE13-10) |
| `FIX-DIAG-CONSERVE02-01: ALERTA` | `med_init` | dois alertas de dobra tripolar degenerada na inicialização | fica: avisos "grade OCN: ..." (R-FASE13-10) |
| `[MED BUG-CALC-08 + BUG-MPAS-01 DIAG]` (saída padrão) | `med_diag` | resumo da forçante atmosférica no primeiro passo; fora do inventário original | fica: `DIAG atm_forcing summary`, no log do ESMF (depuração; R-FASE13-10) |
| `MED B-OCNGRID-02 DIAG` | `med_ocean` | `So_t` como chega do oceano, no primeiro passo; fora do inventário original | fica: `DIAG sst raw` (depuração; R-FASE13-10) |
| `FIX-DIAG-CONSERVE01-01` | `med_init` | cantos da grade do oceano | retirada (R-FASE13-08) |
| `FIX-DIAG-CONSERVE02-01` (linha informativa) | `med_init` | linha mais ao norte da grade | retirada (R-FASE13-08) |
| `FIX-DIAG-ICEFLUX-01` | `med_bulk_ncar` | faixa de `T_gelo`, `Fioi_sen` e `Foxx_sen` | retirada (R-FASE13-08) |
| `FIX-DIAG-NCWRITE-01` | `med_cap_netcdf` | fatia global de cada PET no gravador | retirada (R-FASE13-08) |
| `[MED-DIAG]` (4 `write(*)`) | `med_export` | faixa de `f_sst_atm` e resultado da exportação de `So_t` | retirada (R-FASE13-08) |
| `FIX-DIAG-SPRINTB2-01` | `med_ocean` | faixa de `f_ifrac_atm` e de dois albedos | retirada (R-FASE13-08) |
| `FIX-DIAG-TSFCCOMP-01` | `med_export` | faixa de `Sx_tsfc` composto | retirada (R-FASE13-08) |
| `FIX-DIAG-ICEREGRID04-01` | `med_export` | faixa de `Si_ifrac` exportado | retirada (R-FASE13-08) |
| `FIX-DIAG-SLOWSPLIT-01` | `sis_cap_MONAN` | 3 somas de controle de `part_size` por passo | retirada (R-FASE13-08) |
| `FIX-DIAG-FASTSYNC-01` | `sis_cap_fields` | `part_size` da fachada pública do SIS2 | retirada (R-FASE13-08) |
| `FIX-DIAG-ALBEDO-01` | `sis_cap_fields` | faixa dos albedos do gelo | retirada (R-FASE13-08) |
| `FIX-DIAG-TSKIN-01` | `sis_cap_fields` | faixa de `Si_t_sis2` (investigação da oscilação, encerrada) | retirada (R-FASE13-08) |
| `FIX-DIAG-ALBFEEDBACK-01` | `mpas_atm_model` | albedo de uma célula antes e depois do MPAS | retirada (R-FASE13-08) |

Desde a R-FASE13-10, os diagnósticos que ficam estão em `src/mediator/med_diag.F90` (exceto os alertas da grade, em `med_init`), com nomes que dizem o que medem (`DIAG <grandeza> <ponto>`), e todas as mensagens do mediador passam pelo `coupler_log_mod`. A troca de cada texto antigo pelo novo está em `tests/log-traduzido.sed`. Na R-FASE13-12, os rótulos `MED B-OCNGRID-01` e `MED B-CONSERVE-01` passados a `cpl_grids` e `mom6_supergrid` deram lugar à marca do componente, e o diagnóstico da leitura dos centros do supergrid passou a `DIAG supergrid tcoords` (depuração).

Desde a R-FASE13-09, as sondas de depuração só rodam com `log_level = 'debug'` no `&nuopc_driver` (antes, com `write_fixdiag`, que valia `.true.` por padrão); com o padrão `'info'`, nem são calculadas. Os avisos são gravados em qualquer nível.

As marcas `B-DIAGMASK-01` e `B-DIAG-IMPORT-INCOMPLETO-01` não são sondas: são atributos de versão gravados nos NetCDF de diagnóstico e lidos por `tools/postproc/`.

As linhas de log retiradas estão em `tests/log-retirado.txt`, que os testes de comparação com uma versão anterior (`bulk`, `malhas`, `gravadores`, `completar`) usam para ignorá-las no log dessa versão.
