# Mapa de acoplamento do MONAN-Coupler

Arquivo gerado por `tools/dev/mapa-acoplamento.py` a partir de
`src/coupling/cpl_fields.F90` e `src/coupling/cpl_map.F90`. Não editar à
mão: mudar o Fortran e gerar de novo. A consistência das tabelas é
conferida por `tests/unit/test_cpl_map.F90`; a arquitetura está em
`docs/arquitetura-acoplamento.md`.

O mapa descreve o acoplamento que o código faz hoje. O mediador e os caps
dos cinco modelos anunciam e realizam os campos a partir dele, na ordem
das linhas de `EXCHANGES` (importação) e de `EXPORTS` (exportação).

59 campos, 8 malhas, 151 trocas, 41 exportações e 6 rotas.

## 1. Configurações

Cada troca vale numa lista de condições (coluna `when`), escolhidas
pelas chaves do grupo `&nuopc_mode` do `nuopc.input`:

| Condição | Vale quando |
| --- | --- |
| `mpas` / `datm` | componente atmosférico é o MONAN-A / o DATM (`use_datm`) |
| `mom6` / `docn` | componente oceânico é o MOM6 / o DOCN (`use_docn`) |
| `med_to_mpas` / `ocn_to_mpas` | contorno oceânico da atmosfera pelo mediador / direto do oceano (`use_med_to_mpas`) |
| `sis2` | gelo dinâmico (`use_sis2_dynamic`) |

As quatro chaves formam 16 combinações. A tabela `COUPLER_MODES`
(`src/shared/coupler_config.F90`) diz o que acontece com cada uma, e é
consultada pela leitura do `nuopc.input` e pelo mapa: `suportada` é a
produção, com ou sem o SIS2; `nao_validada` é aceita com aviso no início
da rodada; `recusada` para a rodada na leitura, e a nota é a mensagem.
Os valores padrão das chaves formam a configuração de produção.

| `use_datm` | `use_docn` | `use_med_to_mpas` | `use_sis2_dynamic` | Situação | Nota |
| --- | --- | --- | --- | --- | --- |
| F | F | T | T | `suportada` | producao: MONAN-A, MOM6 e SIS2, contorno pelo mediador |
| F | F | T | F | `suportada` | MONAN-A e MOM6 sem o SIS2, contorno pelo mediador |
| F | T | F | F | `nao_validada` | o DOCN nao exporta Sx_tsfc, Sf_albedo e Sx_omask, que o MONAN-A importa. |
| F | T | T | F | `nao_validada` | DOCN com contorno pelo mediador nunca foi executado. |
| T | F | T | T | `nao_validada` | o driver nao registra o DATM; o componente ATM continua sendo o MONAN-A. |
| T | F | T | F | `nao_validada` | o driver nao registra o DATM; o componente ATM continua sendo o MONAN-A. |
| T | T | F | F | `nao_validada` | o driver nao registra o DATM; o componente ATM continua sendo o MONAN-A. |
| T | T | T | F | `nao_validada` | o driver nao registra o DATM; o componente ATM continua sendo o MONAN-A. |
| F | F | F | T | `recusada` | use_docn=.false. (MOM6) exige use_med_to_mpas=.true.; o MOM6 nao exporta o contorno da atmosfera. |
| F | F | F | F | `recusada` | use_docn=.false. (MOM6) exige use_med_to_mpas=.true.; o MOM6 nao exporta o contorno da atmosfera. |
| T | F | F | T | `recusada` | use_docn=.false. (MOM6) exige use_med_to_mpas=.true.; o MOM6 nao exporta o contorno da atmosfera. |
| T | F | F | F | `recusada` | use_docn=.false. (MOM6) exige use_med_to_mpas=.true.; o MOM6 nao exporta o contorno da atmosfera. |
| F | T | F | T | `recusada` | use_sis2_dynamic=.true. exige use_docn=.false. (SIS2 precisa do MOM6). |
| F | T | T | T | `recusada` | use_sis2_dynamic=.true. exige use_docn=.false. (SIS2 precisa do MOM6). |
| T | T | F | T | `recusada` | use_sis2_dynamic=.true. exige use_docn=.false. (SIS2 precisa do MOM6). |
| T | T | T | T | `recusada` | use_sis2_dynamic=.true. exige use_docn=.false. (SIS2 precisa do MOM6). |

Campos por conector em cada configuração conferida pelo teste:

| Conector | `producao` | `mom6_sem_sis2` | `mpas_docn` | `datm_mom6` | `datm_docn` |
| --- | --- | --- | --- | --- | --- |
| ATM para MED | 13 | 13 | 13 | 9 | 9 |
| OCN para MED | 4 | 4 | 3 | 4 | 3 |
| ICE para MED | 6 | 0 | 0 | 0 | 0 |
| MED para OCN | 14 | 14 | 14 | 14 | 14 |
| MED para ICE | 16 | 0 | 0 | 0 | 0 |
| MED para ATM | 7 | 7 | 0 | 0 | 0 |
| OCN para ATM | 0 | 0 | 4 | 0 | 0 |

`producao` é a configuração de validação (MONAN-A, MOM6 e SIS2, contorno
pelo mediador). O driver não registra o DATM: as trocas com `datm`
descrevem o que o cap do DATM anuncia, e a conferência do mapa
interrompe uma rodada com `use_datm`.

Lacunas conhecidas (tabela `GAPS`): campos que um componente anuncia
na importação e que, na configuração indicada, não têm origem. A
conferência do mapa as registra como aviso, e não como diferença; nas
lacunas do MONAN-A, o cap atmosférico interrompe a rodada por conta
própria.

| Campo | Ponto | Quando | Motivo |
| --- | --- | --- | --- |
| `So_omask` | `MED@ocn_med` | `docn` | o DOCN nao exporta So_omask |
| `Sx_tsfc` | `ATM@atm_cap` | `mpas`, `ocn_to_mpas` | o oceano nao exporta Sx_tsfc |
| `Sf_albedo` | `ATM@atm_cap` | `mpas`, `ocn_to_mpas` | o oceano nao exporta Sf_albedo |
| `Sx_omask` | `ATM@atm_cap` | `mpas`, `ocn_to_mpas` | o oceano nao exporta Sx_omask |

## 2. Trocas por conector

A coluna "Método" é o método de interpolação do conector NUOPC para o
campo (coluna `method` de `EXCHANGES`), que o driver escreve na `CplList`
como `remapmethod` (`cpl_write_methods`, em `src/coupling/cpl_check.F90`).

### ATM para MED

| Campo | De | Para | Método | Quando |
| --- | --- | --- | --- | --- |
| `Sa_u10m_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Sa_v10m_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Sa_tbot_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Sa_pslv_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_swdn_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_lwdn_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_rain_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Sa_shum_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_snow_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_sen_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_lat_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_taux_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Faxa_tauy_mpas` | `ATM@atm_cap` | `MED@atm_med` | `bilinear` | `mpas` |
| `Sa_u10m` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Sa_v10m` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Sa_tbot` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Sa_shum` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Sa_pslv` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Faxa_swdn` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Faxa_lwdn` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Faxa_rain` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |
| `Faxa_snow` | `ATM@datm` | `MED@atm_med` | `bilinear` | `datm` |

### OCN para MED

| Campo | De | Para | Método | Quando |
| --- | --- | --- | --- | --- |
| `So_t` | `OCN@ocn_mom6` | `MED@ocn_med` | `bilinear` | `mom6` |
| `So_u` | `OCN@ocn_mom6` | `MED@ocn_med` | `bilinear` | `mom6` |
| `So_v` | `OCN@ocn_mom6` | `MED@ocn_med` | `bilinear` | `mom6` |
| `So_omask` | `OCN@ocn_mom6` | `MED@ocn_med` | `bilinear` | `mom6` |
| `So_t` | `OCN@docn` | `MED@ocn_med` | `bilinear` | `docn` |
| `So_u` | `OCN@docn` | `MED@ocn_med` | `bilinear` | `docn` |
| `So_v` | `OCN@docn` | `MED@ocn_med` | `bilinear` | `docn` |

### ICE para MED

| Campo | De | Para | Método | Quando |
| --- | --- | --- | --- | --- |
| `Si_ifrac_sis2` | `ICE@ice_sis2` | `MED@ocn_med` | `bilinear` | `sis2` |
| `Si_avsdr_sis2` | `ICE@ice_sis2` | `MED@ocn_med` | `bilinear` | `sis2` |
| `Si_avsdf_sis2` | `ICE@ice_sis2` | `MED@ocn_med` | `bilinear` | `sis2` |
| `Si_anidr_sis2` | `ICE@ice_sis2` | `MED@ocn_med` | `bilinear` | `sis2` |
| `Si_anidf_sis2` | `ICE@ice_sis2` | `MED@ocn_med` | `bilinear` | `sis2` |
| `Si_t_sis2` | `ICE@ice_sis2` | `MED@ocn_med` | `bilinear` | `sis2` |

### MED para OCN

| Campo | De | Para | Método | Quando |
| --- | --- | --- | --- | --- |
| `Foxx_taux` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_tauy` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_sen` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_evap` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_lwnet` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_swnet_vdr` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_swnet_vdf` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_swnet_idr` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_swnet_idf` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Faxa_rain` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Faxa_snow` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Sa_pslv` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Si_ifrac` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `So_duu10n` | `MED@ocn_med` | `OCN@ocn_mom6` | `bilinear` | `mom6` |
| `Foxx_taux` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_tauy` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_sen` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_evap` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_lwnet` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_swnet_vdr` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_swnet_vdf` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_swnet_idr` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Foxx_swnet_idf` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Faxa_rain` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Faxa_snow` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Sa_pslv` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `Si_ifrac` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |
| `So_duu10n` | `MED@ocn_med` | `OCN@docn` | `bilinear` | `docn` |

### MED para ICE

| Campo | De | Para | Método | Quando |
| --- | --- | --- | --- | --- |
| `Fioi_taux` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_tauy` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_sen` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_evap` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_lwnet` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_swnet_vdr` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_swnet_vdf` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_swnet_idr` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Fioi_swnet_idf` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Faxa_rain` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Faxa_snow` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Sa_pslv` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `Faxa_coszen` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `So_t` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `So_u` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |
| `So_v` | `MED@ocn_med` | `ICE@ice_sis2` | `bilinear` | `sis2` |

### MED para ATM

| Campo | De | Para | Método | Quando |
| --- | --- | --- | --- | --- |
| `Sx_tsfc` | `MED@ocn_med` | `ATM@atm_cap` | `bilinear` | `mpas`, `med_to_mpas` |
| `Si_ifrac` | `MED@ocn_med` | `ATM@atm_cap` | `bilinear` | `mpas`, `med_to_mpas` |
| `So_u` | `MED@ocn_med` | `ATM@atm_cap` | `bilinear` | `mpas`, `med_to_mpas` |
| `So_v` | `MED@ocn_med` | `ATM@atm_cap` | `bilinear` | `mpas`, `med_to_mpas` |
| `Sf_zorl` | `MED@ocn_med` | `ATM@atm_cap` | `bilinear` | `mpas`, `med_to_mpas` |
| `Sf_albedo` | `MED@ocn_med` | `ATM@atm_cap` | `bilinear` | `mpas`, `med_to_mpas` |
| `Sx_omask` | `MED@ocn_med` | `ATM@atm_cap` | `bilinear` | `mpas`, `med_to_mpas` |

### OCN para ATM

| Campo | De | Para | Método | Quando |
| --- | --- | --- | --- | --- |
| `Si_ifrac` | `OCN@docn` | `ATM@atm_cap` | `bilinear` | `mpas`, `docn`, `ocn_to_mpas` |
| `So_u` | `OCN@docn` | `ATM@atm_cap` | `bilinear` | `mpas`, `docn`, `ocn_to_mpas` |
| `So_v` | `OCN@docn` | `ATM@atm_cap` | `bilinear` | `mpas`, `docn`, `ocn_to_mpas` |
| `Sf_zorl` | `OCN@docn` | `ATM@atm_cap` | `bilinear` | `mpas`, `docn`, `ocn_to_mpas` |

## 3. Trocas dentro dos componentes

Passagens entre duas malhas do mesmo componente: código próprio do cap
(`cap`) ou rota do mediador.

| Campo | De | Para | Meio | Quando |
| --- | --- | --- | --- | --- |
| `Sa_u10m_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Sa_v10m_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Sa_tbot_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Sa_pslv_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_swdn_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_lwdn_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_rain_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Sa_shum_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_snow_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_sen_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_lat_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_taux_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `Faxa_tauy_mpas` | `ATM@mpas` | `ATM@atm_cap` | `cap` | `mpas` |
| `So_t` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_sst` | sempre |
| `So_u` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm` | sempre |
| `So_v` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm` | sempre |
| `So_omask` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_landmask` | sempre |
| `Si_ifrac_sis2` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_ice` | `sis2` |
| `Si_avsdr_sis2` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_ice` | `sis2` |
| `Si_avsdf_sis2` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_ice` | `sis2` |
| `Si_anidr_sis2` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_ice` | `sis2` |
| `Si_anidf_sis2` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_ice` | `sis2` |
| `Si_t_sis2` | `MED@ocn_med` | `MED@atm_med` | `ocn2atm_ice` | `sis2` |
| `Foxx_taux` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_tauy` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_sen` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_evap` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_lwnet` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_swnet_vdr` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_swnet_vdf` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_swnet_idr` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Foxx_swnet_idf` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Faxa_rain` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Faxa_snow` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Sa_pslv` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Si_ifrac` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn_ice` | sempre |
| `So_duu10n` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `So_t` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `So_u` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `So_v` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Sf_zorl` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Faxa_coszen` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Sf_albedo` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_taux` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_tauy` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_sen` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_evap` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_lwnet` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_swnet_vdr` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_swnet_vdf` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_swnet_idr` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Fioi_swnet_idf` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Sx_tsfc` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Sx_omask` | `MED@atm_med` | `MED@ocn_med` | `atm2ocn` | sempre |
| `Sx_tsfc` | `ATM@atm_cap` | `ATM@mpas` | `cap` | `mpas` |
| `Si_ifrac` | `ATM@atm_cap` | `ATM@mpas` | `cap` | `mpas` |
| `So_u` | `ATM@atm_cap` | `ATM@mpas` | `cap` | `mpas` |
| `So_v` | `ATM@atm_cap` | `ATM@mpas` | `cap` | `mpas` |
| `Sf_zorl` | `ATM@atm_cap` | `ATM@mpas` | `cap` | `mpas` |
| `Sf_albedo` | `ATM@atm_cap` | `ATM@mpas` | `cap` | `mpas` |
| `Sx_omask` | `ATM@atm_cap` | `ATM@mpas` | `cap` | `mpas` |

## 4. Exportações dos modelos

Campos que cada modelo anuncia no estado de exportação, na ordem do
anúncio. Um campo exportado pode não ter consumidor (o conector só leva
os que o destino importa); a conferência do mapa os lista como aviso.
"Consumido em" diz em quais configurações conferidas o campo sai por
algum conector.

| Campo | Ponto | Quando | Consumido em |
| --- | --- | --- | --- |
| `Sa_pslv_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Sa_tbot_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Sa_u10m_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Sa_v10m_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_swdn_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_lwdn_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_rain_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Sa_shum_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_snow_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_sen_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_lat_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_taux_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Faxa_tauy_mpas` | `ATM@atm_cap` | `mpas` | `producao`, `mom6_sem_sis2`, `mpas_docn` |
| `Sa_u10m` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Sa_v10m` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Sa_tbot` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Sa_shum` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Sa_pslv` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Faxa_swdn` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Faxa_lwdn` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Faxa_rain` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `Faxa_snow` | `ATM@datm` | `datm` | `datm_mom6`, `datm_docn` |
| `So_t` | `OCN@ocn_mom6` | `mom6` | `producao`, `mom6_sem_sis2`, `datm_mom6` |
| `So_s` | `OCN@ocn_mom6` | `mom6` | nenhuma |
| `So_u` | `OCN@ocn_mom6` | `mom6` | `producao`, `mom6_sem_sis2`, `datm_mom6` |
| `So_v` | `OCN@ocn_mom6` | `mom6` | `producao`, `mom6_sem_sis2`, `datm_mom6` |
| `So_omask` | `OCN@ocn_mom6` | `mom6` | `producao`, `mom6_sem_sis2`, `datm_mom6` |
| `Fioo_q` | `OCN@ocn_mom6` | `mom6` | nenhuma |
| `Si_ifrac` | `OCN@ocn_mom6` | `mom6` | nenhuma |
| `So_t` | `OCN@docn` | `docn` | `mpas_docn`, `datm_docn` |
| `Si_ifrac` | `OCN@docn` | `docn` | `mpas_docn` |
| `Sf_zorl` | `OCN@docn` | `docn` | `mpas_docn` |
| `So_s` | `OCN@docn` | `docn` | nenhuma |
| `So_u` | `OCN@docn` | `docn` | `mpas_docn`, `datm_docn` |
| `So_v` | `OCN@docn` | `docn` | `mpas_docn`, `datm_docn` |
| `Si_ifrac_sis2` | `ICE@ice_sis2` | `sis2` | `producao` |
| `Si_avsdr_sis2` | `ICE@ice_sis2` | `sis2` | `producao` |
| `Si_avsdf_sis2` | `ICE@ice_sis2` | `sis2` | `producao` |
| `Si_anidr_sis2` | `ICE@ice_sis2` | `sis2` | `producao` |
| `Si_anidf_sis2` | `ICE@ice_sis2` | `sis2` | `producao` |
| `Si_t_sis2` | `ICE@ice_sis2` | `sis2` | `producao` |

## 5. Rotas do mediador

Toda rota tem quatro etapas: preparar (máscara, pontos sem valor),
interpolar (métodos, reserva, esquema), completar (preenchimento por
vizinhança) e limitar (troca de NaN). Coluna vazia: etapa desligada.
"Campos" é o número de campos que passam pela rota em EXCHANGES.

| Rota | Malhas | Métodos | Máscara | Reserva | Sem valor | Completar | Limitar | Criar | Campos |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `atm2ocn` | atm_med para ocn_med | nearest_stod |   |   | zerar |   | NaN para 0 | inicio | 30 |
| `ocn2atm` | ocn_med para atm_med | bilinear |   |   | zerar |   |   | inicio | 2 |
| `ocn2atm_sst` | ocn_med para atm_med | conserve, bilinear | `So_omask` | `ocn2atm` | zerar | faixa 270 a 310, valor `T_FREEZE_SEAWATER`; 40 passadas; fração 1; acima da faixa vira o valor |   | mascara_mista | 1 |
| `ocn2atm_ice` | ocn_med para atm_med | conserve, bilinear | `So_omask` | `ocn2atm` | sentinela |   |   | primeiro_uso | 6 |
| `ocn2atm_landmask` | ocn_med para atm_med | nearest_stod |   |   | manter |   |   | primeiro_uso | 1 |
| `atm2ocn_ice` | atm_med para ocn_med | conserve, nearest_stod |   | `atm2ocn` | sentinela | faixa 0 a 1, valor 0; 15 passadas |   | primeiro_uso | 1 |

Esquema de todas as rotas: `esmf` (trocável no grupo `&nuopc_regrid`).

## 6. Malhas

| Malha | Componente | Tipo | Descrição |
| --- | --- | --- | --- |
| `mpas` | ATM | voronoi | celulas do MONAN-A (x1.40962) |
| `atm_cap` | ATM | latlon | grade do cap atmosferico, 1 grau |
| `datm` | ATM | latlon | grade do DATM (JRA55, 640 x 320) |
| `ocn_mom6` | OCN | tripolar | grade do MOM6 |
| `docn` | OCN | latlon | grade do DOCN, conforme o arquivo |
| `ice_sis2` | ICE | tripolar | grade do SIS2 |
| `atm_med` | MED | latlon | malha de fluxo do mediador, 1 grau |
| `ocn_med` | MED | tripolar | oceano no mediador |

## 7. Campos

Nome longo e nome CF são os atributos `long_name` e `standard_name` que os
gravadores de diagnóstico do mediador e da exportação do MONAN-A escrevem
(`cpl_field_attributes`); campo sem nome longo sai com os atributos padrão.

| Campo | Unidade | Sinal | Descrição | Nome longo | Nome CF |
| --- | --- | --- | --- | --- | --- |
| `Sa_u10m_mpas` | m s-1 |   | vento zonal a 10 m (MONAN-A) | Vento zonal a 10 m | `eastward_wind` |
| `Sa_v10m_mpas` | m s-1 |   | vento meridional a 10 m (MONAN-A) | Vento meridional a 10 m | `northward_wind` |
| `Sa_tbot_mpas` | K |   | temperatura do ar a 2 m (MONAN-A) | Temperatura do ar a 2 m | `air_temperature` |
| `Sa_pslv_mpas` | Pa |   | pressao ao nivel do mar (MONAN-A) | Pressao ao nivel do mar | `air_pressure_at_mean_sea_level` |
| `Faxa_swdn_mpas` | W m-2 |   | onda curta descendente (MONAN-A) | Radiacao SW descendente media no intervalo | `surface_downwelling_shortwave_flux_in_air` |
| `Faxa_lwdn_mpas` | W m-2 |   | onda longa descendente (MONAN-A) | Radiacao LW descendente media no intervalo | `surface_downwelling_longwave_flux_in_air` |
| `Faxa_rain_mpas` | kg m-2 s-1 |   | precipitacao liquida (MONAN-A) | Precipitacao liquida media no intervalo | `rainfall_flux` |
| `Sa_shum_mpas` | kg kg-1 |   | umidade especifica a 2 m (MONAN-A) | Umidade especifica a 2 m | `specific_humidity` |
| `Faxa_snow_mpas` | kg m-2 s-1 |   | precipitacao solida (MONAN-A) | Precipitacao solida (neve) media no intervalo | `snowfall_flux` |
| `Faxa_sen_mpas` | W m-2 | positivo para cima; o mediador inverte | calor sensivel do PBL do MONAN-A (hfx) |   |   |
| `Faxa_lat_mpas` | W m-2 | positivo para cima; o mediador inverte | calor latente do PBL do MONAN-A (lh) |   |   |
| `Faxa_taux_mpas` | N m-2 |   | tensao zonal do MONAN-A (de ust) |   |   |
| `Faxa_tauy_mpas` | N m-2 |   | tensao meridional do MONAN-A (de ust) |   |   |
| `Sa_u10m` | m s-1 |   | vento zonal a 10 m (DATM) |   |   |
| `Sa_v10m` | m s-1 |   | vento meridional a 10 m (DATM) |   |   |
| `Sa_tbot` | K |   | temperatura do ar (DATM) |   |   |
| `Sa_shum` | kg kg-1 |   | umidade especifica (DATM) |   |   |
| `Sa_pslv` | Pa |   | pressao ao nivel do mar | Pressao nivel do mar | `air_pressure_at_mean_sea_level` |
| `Faxa_swdn` | W m-2 |   | onda curta descendente (DATM) |   |   |
| `Faxa_lwdn` | W m-2 |   | onda longa descendente (DATM) |   |   |
| `Faxa_rain` | kg m-2 s-1 |   | precipitacao liquida | Precipitacao liquida | `rainfall_flux` |
| `Faxa_snow` | kg m-2 s-1 |   | precipitacao solida | Precipitacao solida | `snowfall_flux` |
| `So_t` | K |   | temperatura da superficie do mar | SST dinamica MOM6 | `sea_surface_temperature` |
| `So_u` | m s-1 |   | corrente zonal superficial | Corrente zonal superficial | `surface_eastward_sea_water_velocity` |
| `So_v` | m s-1 |   | corrente meridional superficial | Corrente meridional superficial | `surface_northward_sea_water_velocity` |
| `So_omask` | 1 |   | mascara do MOM6 (1 oceano, 0 terra) |   |   |
| `So_s` | psu |   | salinidade da superficie do mar |   |   |
| `Fioo_q` | W m-2 |   | potencial de fusao ou congelamento (frazil) |   |   |
| `Si_ifrac` | 1 |   | fracao de gelo, entre 0 e 1 | Fracao de gelo marinho | `sea_ice_area_fraction` |
| `Sf_zorl` | m |   | rugosidade da superficie | Rugosidade superficial Charnock | `surface_roughness_length` |
| `Si_ifrac_sis2` | 1 |   | fracao de gelo do SIS2 |   |   |
| `Si_avsdr_sis2` | 1 |   | albedo do gelo, visivel direto |   |   |
| `Si_avsdf_sis2` | 1 |   | albedo do gelo, visivel difuso |   |   |
| `Si_anidr_sis2` | 1 |   | albedo do gelo, infravermelho proximo direto |   |   |
| `Si_anidf_sis2` | 1 |   | albedo do gelo, infravermelho proximo difuso |   |   |
| `Si_t_sis2` | K |   | temperatura de pele do gelo |   |   |
| `Foxx_taux` | Pa |   | tensao zonal sobre o oceano | Tensao cisalhamento zonal | `surface_downward_eastward_stress` |
| `Foxx_tauy` | Pa |   | tensao meridional sobre o oceano | Tensao cisalhamento meridional | `surface_downward_northward_stress` |
| `Foxx_sen` | W m-2 | positivo para a superficie | calor sensivel sobre o oceano | Fluxo de calor sensivel | `surface_upward_sensible_heat_flux` |
| `Foxx_evap` | kg m-2 s-1 |   | evaporacao sobre o oceano | Fluxo de evaporacao | `water_evaporation_flux` |
| `Foxx_lwnet` | W m-2 |   | onda longa liquida sobre o oceano | Balanco onda longa | `surface_net_downward_longwave_flux` |
| `Foxx_swnet_vdr` | W m-2 |   | onda curta liquida, visivel direto | Onda curta vis. direto | `surface_net_downward_shortwave_flux` |
| `Foxx_swnet_vdf` | W m-2 |   | onda curta liquida, visivel difuso | Onda curta vis. difuso | `surface_net_downward_shortwave_flux` |
| `Foxx_swnet_idr` | W m-2 |   | onda curta liquida, infravermelho direto | Onda curta IR direto | `surface_net_downward_shortwave_flux` |
| `Foxx_swnet_idf` | W m-2 |   | onda curta liquida, infravermelho difuso | Onda curta IR difuso | `surface_net_downward_shortwave_flux` |
| `So_duu10n` | m2 s-2 |   | quadrado do vento relativo ao oceano | Vento relativo ao oceano^2 | `square_of_air_velocity` |
| `Sx_tsfc` | K |   | temperatura de pele composta agua e gelo | Temperatura de superficie (pele) | `surface_temperature` |
| `Sx_omask` | 1 |   | mascara do MOM6 na grade da atmosfera | Mascara oceano/terra do MOM6 (1=oceano, 0=terra) | `sea_binary_mask` |
| `Sf_albedo` | 1 |   | albedo de banda larga (agua e gelo) | Albedo de banda larga efetivo (agua+gelo) | `surface_albedo` |
| `Faxa_coszen` | 1 |   | cosseno do angulo zenital solar | Cosseno do angulo zenital solar | `cosine_of_solar_zenith_angle` |
| `Fioi_taux` | Pa |   | tensao zonal sobre o gelo | Tensao cisalhamento zonal (gelo, T_gelo) | `surface_downward_eastward_stress` |
| `Fioi_tauy` | Pa |   | tensao meridional sobre o gelo | Tensao cisalhamento meridional (gelo, T_gelo) | `surface_downward_northward_stress` |
| `Fioi_sen` | W m-2 | positivo para a superficie; cap do SIS2 inverte | calor sensivel sobre o gelo | Fluxo de calor sensivel (gelo, T_gelo) | `surface_upward_sensible_heat_flux` |
| `Fioi_evap` | kg m-2 s-1 |   | evaporacao sobre o gelo | Fluxo de evaporacao (gelo, T_gelo) | `water_evaporation_flux` |
| `Fioi_lwnet` | W m-2 |   | onda longa liquida sobre o gelo | Balanco onda longa (gelo, T_gelo) | `surface_net_downward_longwave_flux` |
| `Fioi_swnet_vdr` | W m-2 |   | onda curta liquida no gelo, visivel direto | Onda curta vis. direto (gelo) | `surface_net_downward_shortwave_flux` |
| `Fioi_swnet_vdf` | W m-2 |   | onda curta liquida no gelo, visivel difuso | Onda curta vis. difuso (gelo) | `surface_net_downward_shortwave_flux` |
| `Fioi_swnet_idr` | W m-2 |   | onda curta liquida no gelo, infravermelho direto | Onda curta IR direto (gelo) | `surface_net_downward_shortwave_flux` |
| `Fioi_swnet_idf` | W m-2 |   | onda curta liquida no gelo, infravermelho difuso | Onda curta IR difuso (gelo) | `surface_net_downward_shortwave_flux` |
