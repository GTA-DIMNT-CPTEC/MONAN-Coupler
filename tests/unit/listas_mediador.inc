! listas_mediador.inc: campos que o mediador anunciava e realizava até a
! R-FASE11-04-FIX01, copiados sem mudança de med_cap_types.F90 (tag
! fase11-04-fix01). Desde a R-FASE11-05 essas listas saem do mapa de
! acoplamento; aqui ficam como referência independente para os testes
! (test_cpl_map, test_cpl_check), que as comparam nome a nome com o mapa.
!
! Além delas, o mediador anunciava e realizava, na grade do oceano, So_t,
! So_u, So_v e So_omask sempre e, com use_sis2_dynamic, os seis campos
! *_sis2, nessa ordem (MED_IMP_OCN e MED_IMP_SIS2).
integer, parameter :: n_import_mpas = 13
character(len=32), parameter :: import_mpas_names(n_import_mpas) = [ &
    "Sa_u10m_mpas  ", "Sa_v10m_mpas  ", "Sa_tbot_mpas  ", "Sa_pslv_mpas  ", &
    "Faxa_swdn_mpas", "Faxa_lwdn_mpas", "Faxa_rain_mpas", &
    "Sa_shum_mpas  ", "Faxa_snow_mpas", &
    "Faxa_sen_mpas ", "Faxa_lat_mpas ", "Faxa_taux_mpas", "Faxa_tauy_mpas" ]

integer, parameter :: n_import_datm = 9
character(len=32), parameter :: import_datm_names(n_import_datm) = [ &
    "Sa_u10m   ", "Sa_v10m   ", "Sa_tbot   ", "Sa_shum   ", "Sa_pslv   ", &
    "Faxa_swdn ", "Faxa_lwdn ", "Faxa_rain ", "Faxa_snow "]

integer, parameter :: n_export = 31
character(len=32), parameter :: export_names(n_export) = [ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", "Foxx_lwnet    ", &
    "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", "Foxx_swnet_idf", &
    "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", "Si_ifrac      ", "So_duu10n     ", &
    "So_t          ",                                                                          &
    "So_u          ", "So_v          ",  &
    "Sf_zorl       ", &  ! rugosidade Charnock → MPAS
    "Faxa_coszen   ", &                      ! angulo zenital solar → SIS2
    "Sf_albedo     ", &                      ! albedo de banda larga → MPAS
    "Fioi_taux     ", "Fioi_tauy     ", "Fioi_sen      ", "Fioi_evap     ", &  ! fluxos do gelo
    "Fioi_lwnet    ", &                      ! fluxos calc. c/ T_gelo → SIS2
    "Fioi_swnet_vdr", "Fioi_swnet_vdf", "Fioi_swnet_idr", "Fioi_swnet_idf", &  ! onda curta do gelo
    "Sx_tsfc       ", &  ! composto p/ MPAS-A
    "Sx_omask      " ]  ! mascara terra/oceano MOM6 → diag + MPAS
character(len=32), parameter :: MED_IMP_OCN(4) = [character(len=32) :: &
  'So_t', 'So_u', 'So_v', 'So_omask']
character(len=32), parameter :: MED_IMP_SIS2(6) = [character(len=32) :: &
  'Si_ifrac_sis2', 'Si_avsdr_sis2', 'Si_avsdf_sis2', 'Si_anidr_sis2', 'Si_anidf_sis2', 'Si_t_sis2']
