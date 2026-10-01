! listas_caps.inc: campos que os caps dos modelos anunciam, escritos aqui
! como referência independente do mapa de acoplamento para os testes
! (test_cpl_map), que os comparam nome a nome com EXPORTACOES e com as
! chegadas geradas por cpl_chegadas.
!
! MOM6 e SIS2: listas de mom_cap_MONAN.F90 e sis_cap_MONAN.F90 até a
! R-FASE11-05 (tag fase11-05-validada), copiadas sem mudança, só com os
! nomes trocados para não colidir com os de listas_mediador.inc. Desde a
! R-FASE11-06 esses caps geram as listas a partir do mapa. O SIS2 anunciava
! primeiro sis_import_names_atm e depois sis_import_names_ocn.
!
! MONAN-A, DATM e DOCN: exportações anunciadas por mpas_cap_MONAN.F90
! (EXP_NAMES), DATM_cap.F90 (na ordem das chamadas a NUOPC_Advertise) e
! DOCN_cap.F90 (EXP_NAMES), na R-FASE11-06.
character(len=32), parameter :: mom_export_names(7) = [ &
    "So_t    ", "So_s    ", "So_u    ", "So_v    ", &
    "So_omask", "Fioo_q  ", "Si_ifrac" ]
character(len=32), parameter :: mom_import_names(14) = [ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", &
    "Foxx_lwnet    ", "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", &
    "Foxx_swnet_idf", "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", &
    "Si_ifrac      ", "So_duu10n     " ]

character(len=32), parameter :: sis_import_names_atm(13) = [ &
    "Fioi_taux     ", "Fioi_tauy     ", "Fioi_sen      ", "Fioi_evap     ", &
    "Fioi_lwnet    ", "Fioi_swnet_vdr", "Fioi_swnet_vdf", "Fioi_swnet_idr", &
    "Fioi_swnet_idf", "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", &
    "Faxa_coszen   " ]
character(len=32), parameter :: sis_import_names_ocn(3) = [ &
    "So_t       ", "So_u       ", "So_v       " ]
character(len=32), parameter :: sis_export_names(6) = [ character(len=32) :: &
    "Si_ifrac_sis2", "Si_avsdr_sis2", "Si_avsdf_sis2", "Si_anidr_sis2", &
    "Si_anidf_sis2", "Si_t_sis2" ]

character(len=32), parameter :: mpas_exp_names(13) = [ character(len=32) :: &
    'Sa_pslv_mpas', 'Sa_tbot_mpas', 'Sa_u10m_mpas', 'Sa_v10m_mpas', 'Faxa_swdn_mpas', &
    'Faxa_lwdn_mpas', 'Faxa_rain_mpas', 'Sa_shum_mpas', 'Faxa_snow_mpas', &
    'Faxa_sen_mpas', 'Faxa_lat_mpas', 'Faxa_taux_mpas', 'Faxa_tauy_mpas' ]
character(len=32), parameter :: datm_exp_names(9) = [ character(len=32) :: &
    'Sa_u10m', 'Sa_v10m', 'Sa_tbot', 'Sa_shum', 'Sa_pslv', &
    'Faxa_swdn', 'Faxa_lwdn', 'Faxa_rain', 'Faxa_snow' ]
character(len=32), parameter :: docn_exp_names(6) = [ character(len=32) :: &
    'So_t', 'Si_ifrac', 'Sf_zorl', 'So_s', 'So_u', 'So_v' ]
