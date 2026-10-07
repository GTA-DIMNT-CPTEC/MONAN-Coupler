# upstream/: fontes do cap NUOPC do MOM6

Arquivos originários de `MOM6/config_src/drivers/nuopc_cap/`. Os três são compilados pelo `Makefile` do acoplador, com as opções do MOM6 (real de 8 bytes), e fornecem os símbolos usados por `mom_cap_MONAN.F90`, `sis_cap_MONAN.F90` e `time_utils.F90`.

| Arquivo | Conteúdo usado pelo acoplador |
| --- | --- |
| `mom_surface_forcing_nuopc.F90` | tipo `ice_ocean_boundary_type` e conversão das forçantes |
| `mom_ocean_model_nuopc.F90` | inicialização, avanço e finalização do MOM6 |
| `mom_cap_methods.F90` | `mom_import`, `mom_export`, `ChkErr` |

## Diferenças em relação ao MOM6 original

Os arquivos não são cópias exatas. Há uma alteração local, que deve ser reaplicada a cada sincronização com o repositório do MOM6:

| Arquivo | Alteração | Motivo |
| --- | --- | --- |
| `mom_cap_methods.F90` | guarda por `associated()` nos campos por categoria de gelo (FIX-ICE-NCAT) | evita acesso a ponteiros não alocados quando `ice_ncat` chega sem valor válido |

Qualquer nova alteração local deve ser registrada nesta tabela. `mom_cap.F90` e `mom_cap_time.F90` não são usados: o acoplador tem cap próprio (`../mom_cap_MONAN.F90`).
