!> @file cpl_map.F90
!! @brief Mapa de acoplamento: tabelas EXCHANGES e ROUTES e as consultas sobre elas.
!!
!! O mapa descreve, num lugar só, o acoplamento: que campo vai de qual
!! malha para qual, por qual meio e em que configuração. Dele saem as
!! listas de campos que o mediador e os caps anunciam (cpl_arrivals,
!! cpl_exports), o método de cada campo dos conectores (cpl_write_methods,
!! em cpl_check) e as rotas do mediador; na inicialização, cpl_check confere
!! o que o NUOPC montou contra ele. Arquitetura em
!! docs/arquitetura-acoplamento.md; versão legível em docs/acoplamento.md,
!! gerada por tools/dev/mapa-acoplamento.py.
!!
!! Pontos. Origem e destino de uma troca são escritos 'COMPONENTE@malha':
!!   ATM@mpas      células do MONAN-A (malha Voronoi, não é objeto ESMF)
!!   ATM@atm_cap   grade regular de 1 grau do cap atmosférico
!!   ATM@datm      grade do DATM (JRA55)
!!   OCN@ocn_mom6  grade tripolar do MOM6
!!   OCN@docn      grade do DOCN
!!   ICE@ice_sis2  grade tripolar do SIS2
!!   MED@atm_med   grade regular de 1 grau do mediador, malha da física bulk
!!   MED@ocn_med   grade tripolar do mediador
!!
!! Meios (coluna via):
!!   'conector'  conector NUOPC entre dois componentes; a interpolação é a
!!               da coluna method, que o driver escreve na CplList como
!!               remapmethod;
!!   'cap'       código próprio do cap, dentro do mesmo componente;
!!   nome de rota, de ROUTES: interpolação do mediador por regrid_manager_t.
!!
!! No mediador, um mesmo nome pode existir duas vezes em MED@ocn_med: o
!! campo importado (importState) e o exportado (exportState). É o caso de
!! So_t, So_u e So_v. A regra de leitura é: uma rota que parte de
!! MED@ocn_med lê o campo importado; um conector que parte de MED@ocn_med
!! leva o campo exportado, que chegou de MED@atm_med pela rota 'atm2ocn'.
!!
!! Método (coluna method): só nas trocas por conector, um dos valores de
!! CONNECTOR_METHODS; vazio nas demais. Hoje todas usam 'bilinear'.
!!
!! Condições (coluna when): lista separada por vírgulas; a troca vale se
!! todas as condições da lista valem. Lista vazia: vale sempre.
!!   mpas / datm               componente atmosférico (use_datm)
!!   mom6 / docn               componente oceânico (use_docn)
!!   med_to_mpas / ocn_to_mpas contorno oceânico da atmosfera pelo mediador
!!                             ou direto do oceano (use_med_to_mpas)
!!   sis2                      gelo dinâmico (use_sis2_dynamic)
!! As consultas que percorrem configurações (cpl_arrivals, cpl_exports)
!! consideram só as combinações aceitas pela tabela COUPLER_MODES
!! (coupler_config), a mesma que config_read consulta.
!!
!! O DATM está descrito como o cap dele anuncia os campos, mas o driver
!! (esm.F90) não o registra hoje: com use_datm=.true. o componente ATM
!! continua sendo o MONAN-A. O destino do DATM é uma decisão pendente do GT.
!!
!! Listas de campos (cpl_arrivals): o que um componente anuncia e realiza
!! sai do mapa, como os campos que chegam a um ponto. Cada componente decide
!! o que anuncia por algumas chaves de &nuopc_mode, não por todas (o
!! mediador, por exemplo, só por use_datm e use_sis2_dynamic, e anuncia
!! So_omask mesmo com o DOCN, que não a exporta); as demais chaves ficam
!! livres, e a lista é a união das configurações válidas que concordam com
!! a atual nas chaves pedidas, na ordem de EXCHANGES, sem repetição. O
!! mediador e os caps dos modelos anunciam e realizam os campos nessa ordem
!! (e na de EXPORTS, abaixo): mudar a ordem das linhas muda a ordem do
!! anúncio.
!!
!! GAPS: campos que um componente anuncia na importação e que, numa
!! configuração, não têm origem no mapa. São conhecidas e não são erro: a
!! conferência do mapa (cpl_check) as registra como aviso, e não como
!! diferença, que interrompe a rodada. O cap atmosférico, porém, interrompe
!! a rodada por conta própria quando um campo que ele importa não está
!! conectado (verify_import_connected), o que acontece nas lacunas do
!! MONAN-A.
!!
!! EXPORTS: o que cada modelo exporta (anuncia no exportState) em cada
!! ponto, consumido ou não, na ordem do anúncio do cap. Toda troca por
!! conector que parte de um modelo parte de uma linha desta tabela; um campo
!! exportado sem troca (So_s e Fioo_q do MOM6, por exemplo) só aparece aqui.
!! A exportação do mediador não está nesta tabela: ela é o que chega a
!! MED@ocn_med pelas rotas atm2ocn e atm2ocn_ice (ver cpl_arrivals).
!!
!! ROUTES: uma linha por interpolação do mediador, de src para dst (malhas).
!! Toda rota tem as mesmas quatro etapas, na mesma ordem; a coluna com o
!! valor padrão desliga a etapa (ou, no caso de no_value, deixa o
!! comportamento padrão do ESMF):
!!   1. preparar    mask (campo que dá a máscara da origem, gravada na grade
!!                  antes da criação) e no_value, o que acontece com os
!!                  pontos de destino que a rota não alcança: 'zerar'
!!                  (zeroregion total do ESMF), 'manter' (ficam como
!!                  estavam) ou 'sentinela' (recebem -999 antes da
!!                  interpolação e ficam com ele, fora de qualquer faixa
!!                  válida, como em med_ice e med_export)
!!   2. interpolar  methods (em ordem de preferência), fallback (rota usada
!!                  se nenhum método servir) e scheme (padrão 'esmf',
!!                  trocável no grupo &nuopc_regrid do nuopc.input)
!!   3. completar   fill: preenchimento por vizinhança (regrid_fill_t)
!!   4. limitar     nan_to, o valor que substitui NaN no destino; CPL_UNSET
!!                  desliga
!! E a coluna create, que não é etapa: o momento em que a rota é criada.
!!   'inicio'         em InitializeDataComplete
!!   'primeiro_uso'   na primeira vez que o mediador precisa dela
!!   'mascara_mista'  no primeiro passo em que a máscara do oceano tem terra
!!                    e mar; até lá, o campo usa a rota de reserva
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module cpl_map_mod

  use ESMF,                  only : ESMF_KIND_R8
  use coupler_constants_mod, only : T_FREEZE_SEAWATER
  use coupler_config_mod,    only : cfg_use_datm, cfg_use_docn, cfg_use_med_to_mpas, &
                                    cfg_use_sis2_dynamic, COUPLER_MODES, coupler_mode_index
  use regrid_base_mod,       only : regrid_fill_t
  use cpl_fields_mod,        only : CPL_NAME_LEN

  implicit none
  private

  public :: cpl_grid_ref_t, cpl_exchange_t, cpl_route_t, cpl_config_t
  public :: GRIDS, EXCHANGES, ROUTES, CONDITIONS
  public :: CPL_UNSET, CPL_POINT_LEN, CPL_VIA_LEN, CPL_WHEN_LEN, CPL_METHOD_LEN
  public :: CONNECTOR_METHODS, cpl_connector_method
  public :: cpl_exchange_applies, cpl_valid_conditions
  public :: cpl_route_index, cpl_grid_index
  public :: cpl_point_component, cpl_point_grid
  public :: cpl_current_config, cpl_config_is_valid, cpl_arrivals
  public :: cpl_connector_applies, cpl_unlisted_connector, cpl_driver_connectors
  public :: N_CONNECTORS, CONNECTOR_SRC, CONNECTOR_DST
  public :: cpl_export_t, EXPORTS, cpl_exports
  public :: cpl_gap_t, GAPS, cpl_is_gap

  integer, parameter :: r8 = ESMF_KIND_R8

  integer, parameter :: CPL_POINT_LEN  = 16   !< 'COMPONENTE@malha'
  integer, parameter :: CPL_VIA_LEN    = 16   !< 'conector', 'cap' ou nome de rota
  integer, parameter :: CPL_WHEN_LEN = 32     !< lista de condições
  integer, parameter :: CPL_METHOD_LEN = 16   !< método de um conector

  !> Métodos aceitos na coluna method: os valores da opção remapmethod do
  !! conector NUOPC (NUOPC_Connector, ESMF 8.9.1).
  character(len=CPL_METHOD_LEN), parameter :: CONNECTOR_METHODS(*) =                &
    [character(len=CPL_METHOD_LEN) :: 'bilinear', 'patch', 'nearest_stod',          &
     'nearest_dtos', 'conserve', 'conserve_2nd', 'redist']

  !> Valor que desliga a coluna nan_to.
  real(r8), parameter :: CPL_UNSET = huge(1.0_r8)

  !> Condições aceitas na coluna when.
  character(len=12), parameter :: CONDITIONS(*) = [character(len=12) ::             &
    'mpas', 'datm', 'mom6', 'docn', 'med_to_mpas', 'ocn_to_mpas', 'sis2' ]

  !> Malha citada no mapa: nome, componente em que existe, tipo.
  type :: cpl_grid_ref_t
    character(len=12) :: name       = ''
    character(len=4)  :: component = ''
    character(len=8)  :: grid_type  = ''  !< 'latlon', 'tripolar', 'voronoi'
    character(len=64) :: description = ''
  end type cpl_grid_ref_t

  type(cpl_grid_ref_t), parameter :: GRIDS(*) = [                                          &
    cpl_grid_ref_t('mpas',     'ATM', 'voronoi',  'celulas do MONAN-A (x1.40962)'),        &
    cpl_grid_ref_t('atm_cap',  'ATM', 'latlon',   'grade do cap atmosferico, 1 grau'),     &
    cpl_grid_ref_t('datm',     'ATM', 'latlon',   'grade do DATM (JRA55, 640 x 320)'),     &
    cpl_grid_ref_t('ocn_mom6', 'OCN', 'tripolar', 'grade do MOM6'),                        &
    cpl_grid_ref_t('docn',     'OCN', 'latlon',   'grade do DOCN, conforme o arquivo'),    &
    cpl_grid_ref_t('ice_sis2', 'ICE', 'tripolar', 'grade do SIS2'),                        &
    cpl_grid_ref_t('atm_med',  'MED', 'latlon',   'malha de fluxo do mediador, 1 grau'),   &
    cpl_grid_ref_t('ocn_med',  'MED', 'tripolar', 'oceano no mediador') ]

  !> Uma passagem de um campo de uma malha a outra.
  type :: cpl_exchange_t
    character(len=CPL_NAME_LEN)   :: field  = ''
    character(len=CPL_POINT_LEN)  :: src    = ''
    character(len=CPL_POINT_LEN)  :: dst    = ''
    character(len=CPL_VIA_LEN)    :: via    = ''
    character(len=CPL_WHEN_LEN) :: when = ''
    character(len=CPL_METHOD_LEN) :: method = ''  !< só nas trocas por conector
  end type cpl_exchange_t

  !> Um campo que um modelo exporta num ponto, nas configurações de when.
  type :: cpl_export_t
    character(len=CPL_NAME_LEN)   :: field  = ''
    character(len=CPL_POINT_LEN)  :: point  = ''
    character(len=CPL_WHEN_LEN) :: when = ''
  end type cpl_export_t

  !> Um campo importado num ponto que fica sem origem nas configurações de when.
  type :: cpl_gap_t
    character(len=CPL_NAME_LEN)   :: field  = ''
    character(len=CPL_POINT_LEN)  :: point  = ''
    character(len=CPL_WHEN_LEN) :: when = ''
    character(len=64)             :: reason = ''
  end type cpl_gap_t

  !> Uma interpolação do mediador (ver as quatro etapas no cabeçalho).
  type :: cpl_route_t
    character(len=CPL_VIA_LEN)   :: name       = ''
    character(len=12)            :: src        = ''       !< malha de origem
    character(len=12)            :: dst        = ''       !< malha de destino
    character(len=48)            :: methods    = ''
    character(len=16)            :: scheme     = 'esmf'
    character(len=CPL_NAME_LEN)  :: mask       = ''
    character(len=CPL_VIA_LEN)   :: fallback   = ''
    character(len=12)            :: no_value   = 'zerar'
    type(regrid_fill_t)          :: fill       = regrid_fill_t()
    real(r8)                     :: nan_to     = CPL_UNSET
    character(len=16)            :: create     = 'inicio'
  end type cpl_route_t

  !> Chaves de nuopc.input que escolhem as trocas.
  type :: cpl_config_t
    logical :: datm        = .false.
    logical :: docn        = .false.
    logical :: med_to_mpas = .true.
    logical :: sis2        = .true.
  end type cpl_config_t

  ! EXCHANGES
  type(cpl_exchange_t), parameter :: EXCHANGES(*) = [                                                                            &
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

  ! EXPORTS
  type(cpl_export_t), parameter :: EXPORTS(*) = [                               &
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
    ! vai ao MONAN-A com use_med_to_mpas=.false.
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

  ! GAPS
  type(cpl_gap_t), parameter :: GAPS(*) = [                                                            &
    !            field        point          when                    reason
    ! O mediador anuncia So_omask também com o DOCN, que não o exporta
    cpl_gap_t('So_omask',  'MED@ocn_med', 'docn',                 'o DOCN nao exporta So_omask'),       &
    ! Contorno direto do DOCN (use_med_to_mpas=.false.; com o MOM6 é
    ! recusado): o DOCN não exporta estes campos; o cap atmosférico
    ! interrompe a rodada
    cpl_gap_t('Sx_tsfc',   'ATM@atm_cap', 'mpas,ocn_to_mpas',     'o oceano nao exporta Sx_tsfc'),      &
    cpl_gap_t('Sf_albedo', 'ATM@atm_cap', 'mpas,ocn_to_mpas',     'o oceano nao exporta Sf_albedo'),    &
    cpl_gap_t('Sx_omask',  'ATM@atm_cap', 'mpas,ocn_to_mpas',     'o oceano nao exporta Sx_omask') ]

  ! ROUTES
  ! Onde cada rota é criada e usada:
  !   atm2ocn           idc_create_routes (med_init), ou antes em RegridOrCopy
  !                     (med_cap_methods), se a exportação vier primeiro;
  !                     RegridOrCopy troca NaN por zero depois da interpolação
  !   ocn2atm           idc_create_routes (med_init)
  !   ocn2atm_sst       set_ocean_mask_for_sst (med_ocean); máscara de
  !                     So_omask ou, sem ela, do limiar de SST
  !   ocn2atm_ice       add_ice_route (med_ice); o preenchimento por
  !                     vizinhança fica explícito em med_ice, com faixa e
  !                     valor próprios para cada um dos seis campos, depois
  !                     de diagnósticos que registram o campo antes dele
  !   ocn2atm_landmask  regrid_land_mask (med_export)
  !   atm2ocn_ice       export_ice_fraction (med_export)
  type(cpl_route_t), parameter :: ROUTES(*) = [                                              &
    cpl_route_t(name='atm2ocn',          src='atm_med', dst='ocn_med',                         &
               methods='nearest_stod', nan_to=0.0_r8),                                        &
    cpl_route_t(name='ocn2atm',          src='ocn_med', dst='atm_med',                         &
               methods='bilinear'),                                                           &
    cpl_route_t(name='ocn2atm_sst',      src='ocn_med', dst='atm_med',                         &
               methods='conserve,bilinear', mask='So_omask',                               &
               fallback='ocn2atm', create='mascara_mista',                                      &
               fill=regrid_fill_t(enabled=.true., vmin=270.0_r8,                              &
                   vmax=310.0_r8, vfill=T_FREEZE_SEAWATER, max_iter=40,                       &
                   skip_fraction=1.0_r8, overflow_to_fill=.true.)),                           &
    cpl_route_t(name='ocn2atm_ice',      src='ocn_med', dst='atm_med',                         &
               methods='conserve,bilinear', mask='So_omask',                               &
               fallback='ocn2atm', no_value='sentinela', create='primeiro_uso'),               &
    cpl_route_t(name='ocn2atm_landmask', src='ocn_med', dst='atm_med',                         &
               methods='nearest_stod', no_value='manter', create='primeiro_uso'),             &
    cpl_route_t(name='atm2ocn_ice',      src='atm_med', dst='ocn_med',                         &
               methods='conserve,nearest_stod', fallback='atm2ocn',                            &
               no_value='sentinela', create='primeiro_uso',                                   &
               fill=regrid_fill_t(enabled=.true., vmin=0.0_r8,                                &
                   vmax=1.0_r8, vfill=0.0_r8)) ]

  !> Conectores que o driver (esm.F90) sabe registrar, na ordem de registro
  !! (a ordem em que o NUOPC os inicializa e a das linhas dos conectores no
  !! relatório de acoplamento), com os componentes como o mapa os chama.
  !! Cada um é registrado se EXCHANGES tem troca por conector entre os dois
  !! componentes na configuração (cpl_driver_connectors); MED->ATM e
  !! OCN->ATM se excluem pela chave use_med_to_mpas. Esta ordem não é a de
  !! EXCHANGES, que define a ordem do anúncio dos campos.
  integer, parameter :: N_CONNECTORS = 7
  character(len=3), parameter :: CONNECTOR_SRC(N_CONNECTORS) = &
    ['ATM', 'OCN', 'MED', 'MED', 'OCN', 'MED', 'ICE']
  character(len=3), parameter :: CONNECTOR_DST(N_CONNECTORS) = &
    ['MED', 'MED', 'OCN', 'ATM', 'ATM', 'ICE', 'MED']

contains

  !> @brief Configuração do mapa correspondente às chaves de &nuopc_mode lidas do
  !! nuopc.input (coupler_config).
  function cpl_current_config() result(cfg)
    type(cpl_config_t) :: cfg

    cfg%datm        = cfg_use_datm
    cfg%docn        = cfg_use_docn
    cfg%med_to_mpas = cfg_use_med_to_mpas
    cfg%sis2        = cfg_use_sis2_dynamic
  end function cpl_current_config

  !> @brief Combinação de chaves aceita por config_read: não recusada na tabela
  !! COUPLER_MODES (coupler_config), suportada ou não validada.
  pure logical function cpl_config_is_valid(cfg) result(ok)
    type(cpl_config_t), intent(in) :: cfg
    integer :: k

    k = coupler_mode_index(cfg%datm, cfg%docn, cfg%med_to_mpas, cfg%sis2)
    ok = COUPLER_MODES(k)%status /= 'recusada'
  end function cpl_config_is_valid

  !> @brief Campos que chegam a um ponto, na ordem de EXCHANGES e sem repetição.
  !!
  !! A troca conta se vale em alguma configuração válida que concorda com
  !! cfg nas chaves listadas em keys ('datm', 'docn', 'med_to_mpas',
  !! 'sis2', separadas por vírgula; '' deixa todas livres).
  !!
  !! @param[in]  point         'COMPONENTE@malha', ou só 'COMPONENTE' (qualquer malha)
  !! @param[in]  by_connector  .true.: chegadas por conector (importação);
  !!                           .false.: por rota ou cap (dentro do componente)
  !! @param[in]  cfg           configuração atual
  !! @param[in]  keys          chaves de cfg que o componente consulta
  !! @param[out] names         campos, na ordem de EXCHANGES
  subroutine cpl_arrivals(point, by_connector, cfg, keys, names)
    character(len=*),                         intent(in)  :: point
    logical,                                  intent(in)  :: by_connector
    type(cpl_config_t),                       intent(in)  :: cfg
    character(len=*),                         intent(in)  :: keys
    character(len=CPL_NAME_LEN), allocatable, intent(out) :: names(:)

    integer :: t

    allocate(names(0))
    do t = 1, size(EXCHANGES)
      if ((EXCHANGES(t)%via == 'conector') .neqv. by_connector) cycle
      if (.not. point_matches(EXCHANGES(t)%dst, point)) cycle
      if (any(names == EXCHANGES(t)%field)) cycle
      if (applies_in_some(EXCHANGES(t)%when, cfg, keys)) &
        names = [character(len=CPL_NAME_LEN) :: names, EXCHANGES(t)%field]
    end do
  end subroutine cpl_arrivals

  !> @brief Campos que um modelo exporta num ponto, na ordem de EXPORTS e sem
  !! repetição, com a mesma regra de chaves de cpl_arrivals.
  !!
  !! @param[in]  point   'COMPONENTE@malha', ou só 'COMPONENTE' (qualquer malha)
  !! @param[in]  cfg     configuração atual
  !! @param[in]  keys    chaves de cfg que o componente consulta
  !! @param[out] names   campos, na ordem de EXPORTS
  subroutine cpl_exports(point, cfg, keys, names)
    character(len=*),                         intent(in)  :: point
    type(cpl_config_t),                       intent(in)  :: cfg
    character(len=*),                         intent(in)  :: keys
    character(len=CPL_NAME_LEN), allocatable, intent(out) :: names(:)

    integer :: e

    allocate(names(0))
    do e = 1, size(EXPORTS)
      if (.not. point_matches(EXPORTS(e)%point, point)) cycle
      if (any(names == EXPORTS(e)%field)) cycle
      if (applies_in_some(EXPORTS(e)%when, cfg, keys)) &
        names = [character(len=CPL_NAME_LEN) :: names, EXPORTS(e)%field]
    end do
  end subroutine cpl_exports

  !> @brief O ponto p é o ponto pedido ('COMPONENTE@malha' exato, ou só o componente).
  pure logical function point_matches(p, requested) result(ok)
    character(len=*), intent(in) :: p, requested
    if (index(requested, '@') > 0) then
      ok = p == requested
    else
      ok = cpl_point_component(p) == requested
    end if
  end function point_matches

  !> @brief A lista de condições when vale em alguma configuração válida que
  !! concorda com cfg nas chaves listadas.
  logical function applies_in_some(when, cfg, keys) result(applies)
    character(len=*),   intent(in) :: when, keys
    type(cpl_config_t), intent(in) :: cfg
    type(cpl_config_t) :: c
    type(cpl_exchange_t) :: t
    integer :: k

    t%when = when
    applies = .false.
    do k = 0, 15
      c = cpl_config_t(datm=btest(k, 0), docn=btest(k, 1), med_to_mpas=btest(k, 2), &
                       sis2=btest(k, 3))
      if (.not. cpl_config_is_valid(c)) cycle
      if (.not. agrees(c, cfg, keys)) cycle
      if (cpl_exchange_applies(t, c)) then
        applies = .true.
        return
      end if
    end do
  end function applies_in_some

  !> @brief c e cfg têm o mesmo valor em cada chave listada.
  pure logical function agrees(c, cfg, keys) result(ok)
    type(cpl_config_t), intent(in) :: c, cfg
    character(len=*),   intent(in) :: keys
    character(len=CPL_WHEN_LEN) :: rest, key

    ok = .true.
    rest = adjustl(keys)
    do while (len_trim(rest) > 0 .and. ok)
      call next_condition(rest, key)
      select case (trim(key))
      case ('datm');        ok = c%datm .eqv. cfg%datm
      case ('docn');        ok = c%docn .eqv. cfg%docn
      case ('med_to_mpas'); ok = c%med_to_mpas .eqv. cfg%med_to_mpas
      case ('sis2');        ok = c%sis2 .eqv. cfg%sis2
      case default;         ok = .false.
      end select
    end do
  end function agrees

  !> @brief O campo importado no point é uma lacuna conhecida na configuração cfg
  !! (tabela GAPS). point é 'COMPONENTE@malha' ou só o componente.
  pure logical function cpl_is_gap(cfg, field, point) result(is_gap)
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: field, point
    integer :: k

    is_gap = .false.
    do k = 1, size(GAPS)
      if (GAPS(k)%field /= field) cycle
      if (.not. point_matches(GAPS(k)%point, point)) cycle
      if (.not. cpl_exchange_applies(cpl_exchange_t(when=GAPS(k)%when), cfg)) cycle
      is_gap = .true.
      return
    end do
  end function cpl_is_gap

  !> @brief Verdadeiro se a troca vale na configuração cfg (todas as condições da
  !! coluna when valem; lista vazia vale sempre).
  pure logical function cpl_exchange_applies(xchg, cfg) result(applies)
    type(cpl_exchange_t), intent(in) :: xchg
    type(cpl_config_t), intent(in) :: cfg
    character(len=CPL_WHEN_LEN) :: rest, cond

    applies = .true.
    rest = adjustl(xchg%when)
    do while (len_trim(rest) > 0)
      call next_condition(rest, cond)
      if (.not. condition_holds(cond, cfg)) then
        applies = .false.
        return
      end if
    end do
  end function cpl_exchange_applies

  !> @brief Há troca por conector, válida em cfg, do componente de para o
  !! componente para ('ATM', 'OCN', 'ICE', 'MED')? É o que decide se o
  !! driver registra o conector de para para.
  pure logical function cpl_connector_applies(src, dst, cfg) result(applies)
    character(len=*),   intent(in) :: src, dst
    type(cpl_config_t), intent(in) :: cfg
    integer :: t

    applies = .false.
    do t = 1, size(EXCHANGES)
      if (trim(EXCHANGES(t)%via) /= 'conector') cycle
      if (trim(cpl_point_component(EXCHANGES(t)%src)) /= src) cycle
      if (trim(cpl_point_component(EXCHANGES(t)%dst)) /= dst) cycle
      if (.not. cpl_exchange_applies(EXCHANGES(t), cfg)) cycle
      applies = .true.
      return
    end do
  end function cpl_connector_applies

  !> @brief Método da troca por conector do campo, do componente de para o
  !! componente para (coluna method), ou vazio se o mapa não tem essa troca.
  !! Não depende da configuração: as trocas por conector do mesmo campo entre
  !! os mesmos dois componentes têm o mesmo método em todas as linhas de
  !! EXCHANGES (conferido por tests/unit/test_cpl_map.F90). É o método que o
  !! driver escreve na CplList (cpl_write_methods, em cpl_check).
  !!
  !! @param[in] field  nome do campo (StandardName)
  !! @param[in] src    componente de origem ('ATM', 'OCN', 'ICE', 'MED')
  !! @param[in] dst    componente de destino
  pure function cpl_connector_method(field, src, dst) result(method)
    character(len=*), intent(in) :: field, src, dst
    character(len=CPL_METHOD_LEN) :: method
    integer :: t

    method = ''
    do t = 1, size(EXCHANGES)
      if (trim(EXCHANGES(t)%via) /= 'conector') cycle
      if (EXCHANGES(t)%field /= field) cycle
      if (trim(cpl_point_component(EXCHANGES(t)%src)) /= trim(src)) cycle
      if (trim(cpl_point_component(EXCHANGES(t)%dst)) /= trim(dst)) cycle
      method = EXCHANGES(t)%method
      return
    end do
  end function cpl_connector_method

  !> @brief Conectores que o driver registra na configuração cfg: ordem(1:n) são os
  !! índices em CONNECTOR_SRC/CONNECTOR_DST, na ordem de registro. O
  !! componente atmosférico registrado é sempre o MONAN-A, também com
  !! use_datm (o DATM está no mapa, mas o driver não o registra); por isso o
  !! mapa é consultado com a chave datm desligada. t_unlisted é a primeira troca
  !! por conector válida que não tem lugar na lista (0 se não há).
  !!
  !! @param[in]  cfg     configuração (cpl_current_config)
  !! @param[out] order   índices dos conectores registrados
  !! @param[out] n       quantos
  !! @param[out] t_unlisted índice em EXCHANGES de um conector sem lugar, ou 0
  pure subroutine cpl_driver_connectors(cfg, order, n, t_unlisted)
    type(cpl_config_t), intent(in)  :: cfg
    integer,            intent(out) :: order(N_CONNECTORS)
    integer,            intent(out) :: n, t_unlisted
    type(cpl_config_t) :: c
    integer :: k

    c = cfg
    c%datm = .false.
    order = 0
    n = 0
    t_unlisted = cpl_unlisted_connector(CONNECTOR_SRC, CONNECTOR_DST, c)
    do k = 1, N_CONNECTORS
      if (.not. cpl_connector_applies(CONNECTOR_SRC(k), CONNECTOR_DST(k), c)) cycle
      n = n + 1
      order(n) = k
    end do
  end subroutine cpl_driver_connectors

  !> @brief Primeira troca por conector válida em cfg cujo par de componentes não
  !! está na lista (des(k), paras(k)); 0 se todas estão. Serve ao driver
  !! para recusar um conector do mapa que ele não sabe registrar.
  pure integer function cpl_unlisted_connector(srcs, dsts, cfg) result(t_unlisted)
    character(len=*),   intent(in) :: srcs(:), dsts(:)
    type(cpl_config_t), intent(in) :: cfg
    integer :: t, k
    logical :: found

    t_unlisted = 0
    do t = 1, size(EXCHANGES)
      if (trim(EXCHANGES(t)%via) /= 'conector') cycle
      if (.not. cpl_exchange_applies(EXCHANGES(t), cfg)) cycle
      found = .false.
      do k = 1, size(srcs)
        if (trim(cpl_point_component(EXCHANGES(t)%src)) == trim(srcs(k)) .and. &
            trim(cpl_point_component(EXCHANGES(t)%dst)) == trim(dsts(k))) found = .true.
      end do
      if (.not. found) then
        t_unlisted = t
        return
      end if
    end do
  end function cpl_unlisted_connector

  !> @brief Verdadeiro se todas as condições da lista estão em CONDITIONS.
  pure logical function cpl_valid_conditions(when) result(ok)
    character(len=*), intent(in) :: when
    character(len=CPL_WHEN_LEN) :: rest, cond

    ok    = .true.
    rest = adjustl(when)
    do while (len_trim(rest) > 0)
      call next_condition(rest, cond)
      if (.not. any(CONDITIONS == cond)) then
        ok = .false.
        return
      end if
    end do
  end function cpl_valid_conditions

  !> @brief Posição da rota nome em ROUTES, ou 0.
  pure integer function cpl_route_index(name) result(k)
    character(len=*), intent(in) :: name
    integer :: i

    k = 0
    do i = 1, size(ROUTES)
      if (trim(ROUTES(i)%name) == trim(name)) then
        k = i
        return
      end if
    end do
  end function cpl_route_index

  !> @brief Posição da malha nome em GRIDS, ou 0.
  pure integer function cpl_grid_index(name) result(k)
    character(len=*), intent(in) :: name
    integer :: i

    k = 0
    do i = 1, size(GRIDS)
      if (trim(GRIDS(i)%name) == trim(name)) then
        k = i
        return
      end if
    end do
  end function cpl_grid_index

  !> @brief Componente de um ponto 'COMPONENTE@malha' ('' se não houver '@').
  pure function cpl_point_component(point) result(comp)
    character(len=*), intent(in) :: point
    character(len=CPL_POINT_LEN) :: comp
    integer :: p

    comp = ''
    p = index(point, '@')
    if (p > 1) comp = point(1:p-1)
  end function cpl_point_component

  !> @brief Malha de um ponto 'COMPONENTE@malha' ('' se não houver '@').
  pure function cpl_point_grid(point) result(grid_name)
    character(len=*), intent(in) :: point
    character(len=CPL_POINT_LEN) :: grid_name
    integer :: p

    grid_name = ''
    p = index(point, '@')
    if (p > 0) grid_name = point(p+1:)
  end function cpl_point_grid

  !> @brief Tira a primeira condição da lista resto (separada por vírgula) e a
  !! devolve em cond; resto fica com as demais.
  pure subroutine next_condition(rest, cond)
    character(len=CPL_WHEN_LEN), intent(inout) :: rest
    character(len=CPL_WHEN_LEN), intent(out)     :: cond
    integer :: p

    p = index(rest, ',')
    if (p == 0) then
      cond  = rest
      rest = ''
    else
      cond  = rest(1:p-1)
      rest = adjustl(rest(p+1:))
    end if
  end subroutine next_condition

  !> @brief Uma condição da coluna when, na configuração cfg.
  pure logical function condition_holds(cond, cfg) result(applies)
    character(len=*),   intent(in) :: cond
    type(cpl_config_t), intent(in) :: cfg

    select case (trim(cond))
    case ('mpas');        applies = .not. cfg%datm
    case ('datm');        applies = cfg%datm
    case ('mom6');        applies = .not. cfg%docn
    case ('docn');        applies = cfg%docn
    case ('med_to_mpas'); applies = cfg%med_to_mpas
    case ('ocn_to_mpas'); applies = .not. cfg%med_to_mpas
    case ('sis2');        applies = cfg%sis2
    case default;         applies = .false.
    end select
  end function condition_holds

end module cpl_map_mod
