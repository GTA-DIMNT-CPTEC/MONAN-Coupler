! exchanges_frozen.inc: cópia congelada da tabela EXCHANGES de src/coupling/cpl_map.F90
! como era até a R-FASE13-22, escrita linha a linha (151 trocas), antes de a
! tabela passar a ser escrita por grupos de campos e passagens. Incluída por
! test_cpl_map.F90, que confere que EXCHANGES a reproduz, linha a linha e na
! mesma ordem (a ordem define a ordem do anúncio dos campos). Não editar: um
! campo novo muda EXCHANGES, e este arquivo e a conferência saem quando o GT
! decidir que a cópia já não é necessária.
  type(cpl_exchange_t), parameter :: FROZEN_EXCHANGES(*) = [                                                                            &
    !           field             src             dst             via                 when                      method
    ! 1. MONAN-A: das células para a grade do cap (mpas_cell_binning) e ao mediador
    cpl_exchange_t('Sa_u10m_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sa_v10m_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sa_tbot_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sa_pslv_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_swdn_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_lwdn_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_rain_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sa_shum_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_snow_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_sen_mpas',  'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_lat_mpas',  'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_taux_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Faxa_tauy_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sa_u10m_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Sa_v10m_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Sa_tbot_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Sa_pslv_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_swdn_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_lwdn_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_rain_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Sa_shum_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_snow_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_sen_mpas',  'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_lat_mpas',  'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_taux_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_exchange_t('Faxa_tauy_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    ! 2. DATM para o mediador (o driver não registra o DATM; ver o cabeçalho)
    cpl_exchange_t('Sa_u10m',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Sa_v10m',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Sa_tbot',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Sa_shum',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Sa_pslv',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Faxa_swdn',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Faxa_lwdn',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Faxa_rain',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_exchange_t('Faxa_snow',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    ! 3. Oceano para o mediador. O DOCN não exporta So_omask: nesse modo o
    !    campo do mediador fica sem origem e mantém o valor inicial.
    cpl_exchange_t('So_t',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('So_u',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('So_v',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('So_omask',       'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('So_t',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('So_u',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('So_v',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn',                   'bilinear'), &
    ! 4. Gelo para o mediador, na grade do oceano do mediador
    cpl_exchange_t('Si_ifrac_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Si_avsdr_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Si_avsdf_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Si_anidr_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Si_anidf_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Si_t_sis2',      'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    ! 5. Mediador: da grade do oceano para a malha de fluxo
    cpl_exchange_t('So_t',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm_sst',      '',                       ''),         &
    cpl_exchange_t('So_u',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm',          '',                       ''),         &
    cpl_exchange_t('So_v',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm',          '',                       ''),         &
    cpl_exchange_t('So_omask',       'MED@ocn_med',  'MED@atm_med',  'ocn2atm_landmask', '',                       ''),         &
    cpl_exchange_t('Si_ifrac_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_exchange_t('Si_avsdr_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_exchange_t('Si_avsdf_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_exchange_t('Si_anidr_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_exchange_t('Si_anidf_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_exchange_t('Si_t_sis2',      'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    ! 6. Mediador: da malha de fluxo para a grade do oceano (exportState),
    !    na ordem em que o mediador anuncia e realiza a exportação
    cpl_exchange_t('Foxx_taux',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_tauy',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_sen',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_evap',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_lwnet',     'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_swnet_vdr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_swnet_vdf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_swnet_idr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Foxx_swnet_idf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Faxa_rain',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Faxa_snow',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Sa_pslv',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Si_ifrac',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn_ice',      '',                       ''),         &
    cpl_exchange_t('So_duu10n',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('So_t',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('So_u',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('So_v',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Sf_zorl',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Faxa_coszen',    'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Sf_albedo',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_taux',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_tauy',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_sen',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_evap',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_lwnet',     'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_swnet_vdr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_swnet_vdf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_swnet_idr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Fioi_swnet_idf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Sx_tsfc',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_exchange_t('Sx_omask',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    ! 7. Mediador para o oceano: os 14 campos que o MOM6 e o DOCN importam
    cpl_exchange_t('Foxx_taux',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_tauy',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_sen',       'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_evap',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_lwnet',     'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_vdr', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_vdf', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_idr', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_idf', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Faxa_rain',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Faxa_snow',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Sa_pslv',        'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Si_ifrac',       'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('So_duu10n',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_exchange_t('Foxx_taux',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_tauy',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_sen',       'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_evap',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_lwnet',     'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_vdr', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_vdf', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_idr', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Foxx_swnet_idf', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Faxa_rain',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Faxa_snow',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Sa_pslv',        'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('Si_ifrac',       'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_exchange_t('So_duu10n',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    ! 8. Mediador para o gelo: forçante atmosférica e depois So_t, So_u e
    !    So_v, na ordem do anúncio do SIS2
    cpl_exchange_t('Fioi_taux',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_tauy',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_sen',       'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_evap',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_lwnet',     'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_swnet_vdr', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_swnet_vdf', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_swnet_idr', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Fioi_swnet_idf', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Faxa_rain',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Faxa_snow',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Sa_pslv',        'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('Faxa_coszen',    'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('So_t',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('So_u',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_exchange_t('So_v',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    ! 9. Contorno oceânico da atmosfera pelo mediador, na ordem do anúncio do
    !    MONAN-A
    cpl_exchange_t('Sx_tsfc',        'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_exchange_t('Si_ifrac',       'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_exchange_t('So_u',           'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_exchange_t('So_v',           'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_exchange_t('Sf_zorl',        'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_exchange_t('Sf_albedo',      'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_exchange_t('Sx_omask',       'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    ! 10. Contorno oceânico direto do DOCN (use_med_to_mpas=.false.): só
    !     os nomes que o DOCN exporta e o MONAN-A importa. Sx_tsfc,
    !     Sf_albedo e Sx_omask ficam sem origem, e o cap atmosférico
    !     interrompe a rodada (verify_import_connected). Com o MOM6, o
    !     contorno direto é recusado na leitura (COUPLER_MODES).
    cpl_exchange_t('Si_ifrac',       'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    cpl_exchange_t('So_u',           'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    cpl_exchange_t('So_v',           'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    cpl_exchange_t('Sf_zorl',        'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    ! 11. MONAN-A: da grade do cap para as células (caixa do centro, mpas_adapter)
    cpl_exchange_t('Sx_tsfc',        'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Si_ifrac',       'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_exchange_t('So_u',           'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_exchange_t('So_v',           'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sf_zorl',        'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sf_albedo',      'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_exchange_t('Sx_omask',       'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   '') ]
