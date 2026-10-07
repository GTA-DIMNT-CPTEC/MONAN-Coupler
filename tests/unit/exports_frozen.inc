! exports_frozen.inc: cópia congelada da tabela EXPORTS de src/coupling/cpl_map.F90
! como era até a R-FASE13-30, escrita linha a linha (41 exportações), antes
! de a tabela passar a ser escrita por grupos de campos. Incluída por
! test_cpl_map.F90, que confere que EXPORTS a reproduz, linha a linha e na
! mesma ordem (a ordem define a ordem do anúncio da exportação de cada cap).
! Não editar: um campo novo muda EXPORTS, e este arquivo e a conferência saem
! quando o GT decidir que a cópia já não é necessária.
  type(cpl_export_t), parameter :: FROZEN_EXPORTS(*) = [                        &
    !             field             point           when
    ! MONAN-A (mpas_cap_MONAN)
    cpl_export_t('Sa_pslv_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Sa_tbot_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Sa_u10m_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Sa_v10m_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_swdn_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_lwdn_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_rain_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Sa_shum_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_snow_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_sen_mpas',  'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_lat_mpas',  'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_taux_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_export_t('Faxa_tauy_mpas', 'ATM@atm_cap',  'mpas'),                     &
    ! DATM (DATM_cap)
    cpl_export_t('Sa_u10m',        'ATM@datm',     'datm'),                     &
    cpl_export_t('Sa_v10m',        'ATM@datm',     'datm'),                     &
    cpl_export_t('Sa_tbot',        'ATM@datm',     'datm'),                     &
    cpl_export_t('Sa_shum',        'ATM@datm',     'datm'),                     &
    cpl_export_t('Sa_pslv',        'ATM@datm',     'datm'),                     &
    cpl_export_t('Faxa_swdn',      'ATM@datm',     'datm'),                     &
    cpl_export_t('Faxa_lwdn',      'ATM@datm',     'datm'),                     &
    cpl_export_t('Faxa_rain',      'ATM@datm',     'datm'),                     &
    cpl_export_t('Faxa_snow',      'ATM@datm',     'datm'),                     &
    ! MOM6 (mom_cap_MONAN); So_s e Fioo_q não têm consumidor, e Si_ifrac só
    ! vai ao MONAN-A com atm_boundary=ocn.
    cpl_export_t('So_t',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_export_t('So_s',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_export_t('So_u',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_export_t('So_v',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_export_t('So_omask',       'OCN@ocn_mom6', 'mom6'),                     &
    cpl_export_t('Fioo_q',         'OCN@ocn_mom6', 'mom6'),                     &
    cpl_export_t('Si_ifrac',       'OCN@ocn_mom6', 'mom6'),                     &
    ! DOCN (DOCN_cap)
    cpl_export_t('So_t',           'OCN@docn',     'docn'),                     &
    cpl_export_t('Si_ifrac',       'OCN@docn',     'docn'),                     &
    cpl_export_t('Sf_zorl',        'OCN@docn',     'docn'),                     &
    cpl_export_t('So_s',           'OCN@docn',     'docn'),                     &
    cpl_export_t('So_u',           'OCN@docn',     'docn'),                     &
    cpl_export_t('So_v',           'OCN@docn',     'docn'),                     &
    ! SIS2 (sis_cap_MONAN)
    cpl_export_t('Si_ifrac_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_export_t('Si_avsdr_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_export_t('Si_avsdf_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_export_t('Si_anidr_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_export_t('Si_anidf_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_export_t('Si_t_sis2',      'ICE@ice_sis2', 'sis2') ]
