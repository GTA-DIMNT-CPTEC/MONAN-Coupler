!> @file cpl_map.F90
!! @brief Mapa de acoplamento: tabelas TROCAS e ROTAS e as consultas sobre elas.
!!
!! O mapa descreve, num lugar só, o acoplamento que o código faz hoje (tag
!! fase11-01-validada): que campo vai de qual malha para qual, por qual meio
!! e em que configuração. Ele não comanda nada: nenhum componente o usa
!! ainda. As etapas seguintes da fase 11 passam a conferi-lo na execução
!! (R-FASE11-03) e a gerar dele as listas de campos (R-FASE11-05 em diante).
!! Plano em docs/arquitetura-acoplamento.md; versão legível em
!! docs/acoplamento.md, gerada por tools/dev/mapa-acoplamento.py.
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
!! Meios:
!!   'conector'  conector NUOPC entre dois componentes (interpolação
!!               implícita, com as opções padrão do conector);
!!   'cap'       código próprio do cap, dentro do mesmo componente;
!!   nome de rota, de ROTAS: interpolação do mediador por regrid_manager_t.
!!
!! No mediador, um mesmo nome pode existir duas vezes em MED@ocn_med: o
!! campo importado (importState) e o exportado (exportState). É o caso de
!! So_t, So_u e So_v. A regra de leitura é: uma rota que parte de
!! MED@ocn_med lê o campo importado; um conector que parte de MED@ocn_med
!! leva o campo exportado, que chegou de MED@atm_med pela rota 'atm2ocn'.
!!
!! Condições (coluna quando): lista separada por vírgulas; a troca vale se
!! todas as condições da lista valem. Lista vazia: vale sempre.
!!   mpas / datm               componente atmosférico (use_datm)
!!   mom6 / docn               componente oceânico (use_docn)
!!   med_to_mpas / ocn_to_mpas contorno oceânico da atmosfera pelo mediador
!!                             ou direto do oceano (use_med_to_mpas)
!!   sis2                      gelo dinâmico (use_sis2_dynamic)
!!
!! O DATM está descrito como o cap dele anuncia os campos, mas o driver
!! (esm.F90) não o registra hoje: com use_datm=.true. o componente ATM
!! continua sendo o MONAN-A. O destino do DATM é uma decisão pendente do GT.
!!
!! Listas de campos (cpl_chegadas): o que um componente anuncia e realiza
!! sai do mapa, como os campos que chegam a um ponto. Cada componente decide
!! o que anuncia por algumas chaves de &nuopc_mode, não por todas (o
!! mediador, por exemplo, só por use_datm e use_sis2_dynamic, e anuncia
!! So_omask mesmo com o DOCN, que não a exporta); as demais chaves ficam
!! livres, e a lista é a união das configurações válidas que concordam com
!! a atual nas chaves pedidas, na ordem de TROCAS, sem repetição.
!!
!! ROTAS: uma linha por interpolação do mediador. Toda rota tem as mesmas
!! quatro etapas, na mesma ordem; a coluna com o valor padrão desliga a
!! etapa (ou, no caso de sem_valor, deixa o comportamento padrão do ESMF):
!!   1. preparar    mascara (campo que dá a máscara da origem, gravada na
!!                  grade antes da criação) e sem_valor, o que acontece com
!!                  os pontos de destino que a rota não alcança:
!!                  'zerar' (zeroregion total do ESMF), 'manter' (ficam
!!                  como estavam) ou 'sentinela' (recebem -999 antes da
!!                  interpolação e ficam com ele, fora de qualquer faixa
!!                  válida, como em med_ice e med_export)
!!   2. interpolar  metodos (em ordem de preferência), reserva (rota usada se
!!                  nenhum método servir) e esquema (padrão 'esmf', trocável
!!                  no grupo &nuopc_regrid do nuopc.input)
!!   3. completar   completar: preenchimento por vizinhança (regrid_fill_t)
!!   4. limitar     limite_min, limite_max e nan_para; CPL_AUSENTE desliga
!! E a coluna criar, que não é etapa: o momento em que a rota é criada.
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
                                    cfg_use_sis2_dynamic
  use regrid_base_mod,       only : regrid_fill_t
  use cpl_fields_mod,        only : CPL_NOME_LEN

  implicit none
  private

  public :: cpl_malha_ref_t, cpl_troca_t, cpl_rota_t, cpl_config_t
  public :: MALHAS, TROCAS, ROTAS, CONDICOES
  public :: CPL_AUSENTE, CPL_PONTO_LEN, CPL_MEIO_LEN, CPL_QUANDO_LEN
  public :: cpl_troca_vale, cpl_condicoes_validas
  public :: cpl_rota_indice, cpl_malha_indice
  public :: cpl_ponto_componente, cpl_ponto_malha
  public :: cpl_config_atual, cpl_config_valida, cpl_chegadas

  integer, parameter :: r8 = ESMF_KIND_R8

  integer, parameter :: CPL_PONTO_LEN  = 16   !< 'COMPONENTE@malha'
  integer, parameter :: CPL_MEIO_LEN   = 16   !< 'conector', 'cap' ou nome de rota
  integer, parameter :: CPL_QUANDO_LEN = 32   !< lista de condições

  !> Valor que desliga as colunas limite_min, limite_max e nan_para.
  real(r8), parameter :: CPL_AUSENTE = huge(1.0_r8)

  !> Condições aceitas na coluna quando.
  character(len=12), parameter :: CONDICOES(*) = [character(len=12) ::              &
    'mpas', 'datm', 'mom6', 'docn', 'med_to_mpas', 'ocn_to_mpas', 'sis2' ]

  !> Malha citada no mapa: nome, componente em que existe, tipo.
  type :: cpl_malha_ref_t
    character(len=12) :: nome       = ''
    character(len=4)  :: componente = ''
    character(len=8)  :: tipo       = ''  !< 'latlon', 'tripolar', 'voronoi'
    character(len=64) :: descricao  = ''
  end type cpl_malha_ref_t

  type(cpl_malha_ref_t), parameter :: MALHAS(*) = [                                        &
    cpl_malha_ref_t('mpas',     'ATM', 'voronoi',  'celulas do MONAN-A (x1.40962)'),        &
    cpl_malha_ref_t('atm_cap',  'ATM', 'latlon',   'grade do cap atmosferico, 1 grau'),     &
    cpl_malha_ref_t('datm',     'ATM', 'latlon',   'grade do DATM (JRA55, 640 x 320)'),     &
    cpl_malha_ref_t('ocn_mom6', 'OCN', 'tripolar', 'grade do MOM6'),                        &
    cpl_malha_ref_t('docn',     'OCN', 'latlon',   'grade do DOCN, conforme o arquivo'),    &
    cpl_malha_ref_t('ice_sis2', 'ICE', 'tripolar', 'grade do SIS2'),                        &
    cpl_malha_ref_t('atm_med',  'MED', 'latlon',   'malha de fluxo do mediador, 1 grau'),   &
    cpl_malha_ref_t('ocn_med',  'MED', 'tripolar', 'oceano no mediador') ]

  !> Uma passagem de um campo de uma malha a outra.
  type :: cpl_troca_t
    character(len=CPL_NOME_LEN)   :: campo  = ''
    character(len=CPL_PONTO_LEN)  :: de     = ''
    character(len=CPL_PONTO_LEN)  :: para   = ''
    character(len=CPL_MEIO_LEN)   :: meio   = ''
    character(len=CPL_QUANDO_LEN) :: quando = ''
  end type cpl_troca_t

  !> Uma interpolação do mediador (ver as quatro etapas no cabeçalho).
  type :: cpl_rota_t
    character(len=CPL_MEIO_LEN)  :: nome       = ''
    character(len=12)            :: de         = ''       !< malha de origem
    character(len=12)            :: para       = ''       !< malha de destino
    character(len=48)            :: metodos    = ''
    character(len=16)            :: esquema    = 'esmf'
    character(len=CPL_NOME_LEN)  :: mascara    = ''
    character(len=CPL_MEIO_LEN)  :: reserva    = ''
    character(len=12)            :: sem_valor  = 'zerar'
    type(regrid_fill_t)          :: completar  = regrid_fill_t()
    real(r8)                     :: limite_min = CPL_AUSENTE
    real(r8)                     :: limite_max = CPL_AUSENTE
    real(r8)                     :: nan_para   = CPL_AUSENTE
    character(len=16)            :: criar      = 'inicio'
  end type cpl_rota_t

  !> Chaves de nuopc.input que escolhem as trocas.
  type :: cpl_config_t
    logical :: datm        = .false.
    logical :: docn        = .false.
    logical :: med_to_mpas = .true.
    logical :: sis2        = .true.
  end type cpl_config_t

  !--------------------------------------------------------------------------
  ! TROCAS
  !--------------------------------------------------------------------------
  type(cpl_troca_t), parameter :: TROCAS(*) = [                                                        &
    !           campo             de              para            meio                quando
    ! 1. MONAN-A: das células para a grade do cap (mpas_cell_binning) e ao mediador
    cpl_troca_t('Sa_u10m_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Sa_v10m_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Sa_tbot_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Sa_pslv_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_swdn_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_lwdn_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_rain_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Sa_shum_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_snow_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_sen_mpas',  'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_lat_mpas',  'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_taux_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Faxa_tauy_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas'),                   &
    cpl_troca_t('Sa_u10m_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Sa_v10m_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Sa_tbot_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Sa_pslv_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_swdn_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_lwdn_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_rain_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Sa_shum_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_snow_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_sen_mpas',  'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_lat_mpas',  'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_taux_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    cpl_troca_t('Faxa_tauy_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas'),                   &
    ! 2. DATM para o mediador (o driver não registra o DATM; ver o cabeçalho)
    cpl_troca_t('Sa_u10m',        'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Sa_v10m',        'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Sa_tbot',        'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Sa_shum',        'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Sa_pslv',        'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Faxa_swdn',      'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Faxa_lwdn',      'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Faxa_rain',      'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    cpl_troca_t('Faxa_snow',      'ATM@datm',     'MED@atm_med',  'conector',         'datm'),                   &
    ! 3. Oceano para o mediador. O DOCN não exporta So_omask: nesse modo o
    !    campo do mediador fica sem origem e mantém o valor inicial.
    cpl_troca_t('So_t',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6'),                   &
    cpl_troca_t('So_u',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6'),                   &
    cpl_troca_t('So_v',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6'),                   &
    cpl_troca_t('So_omask',       'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6'),                   &
    cpl_troca_t('So_t',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn'),                   &
    cpl_troca_t('So_u',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn'),                   &
    cpl_troca_t('So_v',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn'),                   &
    ! 4. Gelo para o mediador, na grade do oceano do mediador
    cpl_troca_t('Si_ifrac_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2'),                   &
    cpl_troca_t('Si_avsdr_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2'),                   &
    cpl_troca_t('Si_avsdf_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2'),                   &
    cpl_troca_t('Si_anidr_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2'),                   &
    cpl_troca_t('Si_anidf_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2'),                   &
    cpl_troca_t('Si_t_sis2',      'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2'),                   &
    ! 5. Mediador: da grade do oceano para a malha de fluxo
    cpl_troca_t('So_t',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm_sst',      ''),                       &
    cpl_troca_t('So_u',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm',          ''),                       &
    cpl_troca_t('So_v',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm',          ''),                       &
    cpl_troca_t('So_omask',       'MED@ocn_med',  'MED@atm_med',  'ocn2atm_landmask', ''),                       &
    cpl_troca_t('Si_ifrac_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2'),                   &
    cpl_troca_t('Si_avsdr_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2'),                   &
    cpl_troca_t('Si_avsdf_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2'),                   &
    cpl_troca_t('Si_anidr_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2'),                   &
    cpl_troca_t('Si_anidf_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2'),                   &
    cpl_troca_t('Si_t_sis2',      'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2'),                   &
    ! 6. Mediador: da malha de fluxo para a grade do oceano (exportState),
    !    na ordem em que o mediador anuncia e realiza a exportação
    cpl_troca_t('Foxx_taux',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_tauy',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_sen',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_evap',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_lwnet',     'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_swnet_vdr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_swnet_vdf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_swnet_idr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Foxx_swnet_idf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Faxa_rain',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Faxa_snow',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Sa_pslv',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Si_ifrac',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn_ice',      ''),                       &
    cpl_troca_t('So_duu10n',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('So_t',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('So_u',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('So_v',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Sf_zorl',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Faxa_coszen',    'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Sf_albedo',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_taux',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_tauy',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_sen',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_evap',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_lwnet',     'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_swnet_vdr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_swnet_vdf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_swnet_idr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Fioi_swnet_idf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Sx_tsfc',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    cpl_troca_t('Sx_omask',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          ''),                       &
    ! 7. Mediador para o oceano: os 14 campos que o MOM6 e o DOCN importam
    cpl_troca_t('Foxx_taux',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_tauy',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_sen',       'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_evap',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_lwnet',     'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_swnet_vdr', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_swnet_vdf', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_swnet_idr', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_swnet_idf', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Faxa_rain',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Faxa_snow',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Sa_pslv',        'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Si_ifrac',       'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('So_duu10n',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6'),                   &
    cpl_troca_t('Foxx_taux',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_tauy',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_sen',       'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_evap',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_lwnet',     'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_swnet_vdr', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_swnet_vdf', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_swnet_idr', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Foxx_swnet_idf', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Faxa_rain',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Faxa_snow',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Sa_pslv',        'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('Si_ifrac',       'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    cpl_troca_t('So_duu10n',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn'),                   &
    ! 8. Mediador para o gelo, na ordem de import_names_atm e
    !    import_names_ocn (sis_cap_MONAN)
    cpl_troca_t('Fioi_taux',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_tauy',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_sen',       'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_evap',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_lwnet',     'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_swnet_vdr', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_swnet_vdf', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_swnet_idr', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Fioi_swnet_idf', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Faxa_rain',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Faxa_snow',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Sa_pslv',        'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('Faxa_coszen',    'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('So_t',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('So_u',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    cpl_troca_t('So_v',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2'),                   &
    ! 9. Contorno oceânico da atmosfera pelo mediador, na ordem de IMP_NAMES
    !    (mpas_cap_MONAN)
    cpl_troca_t('Sx_tsfc',        'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas'),       &
    cpl_troca_t('Si_ifrac',       'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas'),       &
    cpl_troca_t('So_u',           'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas'),       &
    cpl_troca_t('So_v',           'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas'),       &
    cpl_troca_t('Sf_zorl',        'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas'),       &
    cpl_troca_t('Sf_albedo',      'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas'),       &
    cpl_troca_t('Sx_omask',       'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas'),       &
    ! 10. Contorno oceânico direto do oceano (use_med_to_mpas=.false.): só
    !     os nomes que o oceano exporta e o MONAN-A importa. Sx_tsfc,
    !     Sf_albedo e Sx_omask ficam sem origem, e o cap atmosférico
    !     interrompe a rodada (verify_import_connected). Com o MOM6, esta
    !     combinação é desaconselhada no nuopc.input.
    cpl_troca_t('Si_ifrac',       'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas'),  &
    cpl_troca_t('So_u',           'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas'),  &
    cpl_troca_t('So_v',           'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas'),  &
    cpl_troca_t('Sf_zorl',        'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas'),  &
    cpl_troca_t('Si_ifrac',       'OCN@ocn_mom6', 'ATM@atm_cap',  'conector',         'mpas,mom6,ocn_to_mpas'),  &
    cpl_troca_t('So_u',           'OCN@ocn_mom6', 'ATM@atm_cap',  'conector',         'mpas,mom6,ocn_to_mpas'),  &
    cpl_troca_t('So_v',           'OCN@ocn_mom6', 'ATM@atm_cap',  'conector',         'mpas,mom6,ocn_to_mpas'),  &
    ! 11. MONAN-A: da grade do cap para as células (caixa do centro, mpas_cap_methods)
    cpl_troca_t('Sx_tsfc',        'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas'),                   &
    cpl_troca_t('Si_ifrac',       'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas'),                   &
    cpl_troca_t('So_u',           'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas'),                   &
    cpl_troca_t('So_v',           'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas'),                   &
    cpl_troca_t('Sf_zorl',        'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas'),                   &
    cpl_troca_t('Sf_albedo',      'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas'),                   &
    cpl_troca_t('Sx_omask',       'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas') ]

  !--------------------------------------------------------------------------
  ! ROTAS
  !--------------------------------------------------------------------------
  ! Criação e uso hoje (Apêndice A de docs/arquitetura-acoplamento.md):
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
  type(cpl_rota_t), parameter :: ROTAS(*) = [                                                &
    cpl_rota_t(nome='atm2ocn',          de='atm_med', para='ocn_med',                         &
               metodos='nearest_stod', nan_para=0.0_r8),                                      &
    cpl_rota_t(nome='ocn2atm',          de='ocn_med', para='atm_med',                         &
               metodos='bilinear'),                                                           &
    cpl_rota_t(nome='ocn2atm_sst',      de='ocn_med', para='atm_med',                         &
               metodos='conserve,bilinear', mascara='So_omask',                               &
               reserva='ocn2atm', criar='mascara_mista',                                      &
               completar=regrid_fill_t(enabled=.true., vmin=270.0_r8,                         &
                   vmax=310.0_r8, vfill=T_FREEZE_SEAWATER, max_iter=40,                       &
                   skip_fraction=1.0_r8, overflow_to_fill=.true.)),                           &
    cpl_rota_t(nome='ocn2atm_ice',      de='ocn_med', para='atm_med',                         &
               metodos='conserve,bilinear', mascara='So_omask',                               &
               reserva='ocn2atm', sem_valor='sentinela', criar='primeiro_uso'),               &
    cpl_rota_t(nome='ocn2atm_landmask', de='ocn_med', para='atm_med',                         &
               metodos='nearest_stod', sem_valor='manter', criar='primeiro_uso'),             &
    cpl_rota_t(nome='atm2ocn_ice',      de='atm_med', para='ocn_med',                         &
               metodos='conserve,nearest_stod', reserva='atm2ocn',                            &
               sem_valor='sentinela', criar='primeiro_uso',                                   &
               completar=regrid_fill_t(enabled=.true., vmin=0.0_r8,                           &
                   vmax=1.0_r8, vfill=0.0_r8)) ]

contains

  !> Configuração do mapa correspondente às chaves de &nuopc_mode lidas do
  !! nuopc.input (coupler_config).
  function cpl_config_atual() result(cfg)
    type(cpl_config_t) :: cfg

    cfg%datm        = cfg_use_datm
    cfg%docn        = cfg_use_docn
    cfg%med_to_mpas = cfg_use_med_to_mpas
    cfg%sis2        = cfg_use_sis2_dynamic
  end function cpl_config_atual

  !> Combinação de chaves aceita por config_read: o SIS2 exige o MOM6.
  pure logical function cpl_config_valida(cfg) result(ok)
    type(cpl_config_t), intent(in) :: cfg
    ok = .not. (cfg%sis2 .and. cfg%docn)
  end function cpl_config_valida

  !> Campos que chegam a um ponto, na ordem de TROCAS e sem repetição.
  !!
  !! A troca conta se vale em alguma configuração válida que concorda com
  !! cfg nas chaves listadas em chaves ('datm', 'docn', 'med_to_mpas',
  !! 'sis2', separadas por vírgula; '' deixa todas livres).
  !!
  !! @param[in]  ponto         'COMPONENTE@malha', ou só 'COMPONENTE' (qualquer malha)
  !! @param[in]  por_conector  .true.: chegadas por conector (importação);
  !!                           .false.: por rota ou cap (dentro do componente)
  !! @param[in]  cfg           configuração atual
  !! @param[in]  chaves        chaves de cfg que o componente consulta
  !! @param[out] nomes         campos, na ordem de TROCAS
  subroutine cpl_chegadas(ponto, por_conector, cfg, chaves, nomes)
    character(len=*),                         intent(in)  :: ponto
    logical,                                  intent(in)  :: por_conector
    type(cpl_config_t),                       intent(in)  :: cfg
    character(len=*),                         intent(in)  :: chaves
    character(len=CPL_NOME_LEN), allocatable, intent(out) :: nomes(:)

    type(cpl_config_t) :: c
    integer :: t, k
    logical :: vale

    allocate(nomes(0))
    do t = 1, size(TROCAS)
      if ((TROCAS(t)%meio == 'conector') .neqv. por_conector) cycle
      if (index(ponto, '@') > 0) then
        if (TROCAS(t)%para /= ponto) cycle
      else
        if (cpl_ponto_componente(TROCAS(t)%para) /= ponto) cycle
      end if
      if (any(nomes == TROCAS(t)%campo)) cycle
      vale = .false.
      do k = 0, 15
        c = cpl_config_t(datm=btest(k, 0), docn=btest(k, 1), med_to_mpas=btest(k, 2), &
                         sis2=btest(k, 3))
        if (.not. cpl_config_valida(c)) cycle
        if (.not. concorda(c, cfg, chaves)) cycle
        if (cpl_troca_vale(TROCAS(t), c)) then
          vale = .true.
          exit
        end if
      end do
      if (vale) nomes = [character(len=CPL_NOME_LEN) :: nomes, TROCAS(t)%campo]
    end do
  end subroutine cpl_chegadas

  !> c e cfg têm o mesmo valor em cada chave listada.
  pure logical function concorda(c, cfg, chaves) result(ok)
    type(cpl_config_t), intent(in) :: c, cfg
    character(len=*),   intent(in) :: chaves
    character(len=CPL_QUANDO_LEN) :: resto, chave

    ok = .true.
    resto = adjustl(chaves)
    do while (len_trim(resto) > 0 .and. ok)
      call proxima_condicao(resto, chave)
      select case (trim(chave))
      case ('datm');        ok = c%datm .eqv. cfg%datm
      case ('docn');        ok = c%docn .eqv. cfg%docn
      case ('med_to_mpas'); ok = c%med_to_mpas .eqv. cfg%med_to_mpas
      case ('sis2');        ok = c%sis2 .eqv. cfg%sis2
      case default;         ok = .false.
      end select
    end do
  end function concorda

  !> Verdadeiro se a troca vale na configuração cfg (todas as condições da
  !! coluna quando valem; lista vazia vale sempre).
  pure logical function cpl_troca_vale(troca, cfg) result(vale)
    type(cpl_troca_t),  intent(in) :: troca
    type(cpl_config_t), intent(in) :: cfg
    character(len=CPL_QUANDO_LEN) :: resto, cond

    vale  = .true.
    resto = adjustl(troca%quando)
    do while (len_trim(resto) > 0)
      call proxima_condicao(resto, cond)
      if (.not. condicao_vale(cond, cfg)) then
        vale = .false.
        return
      end if
    end do
  end function cpl_troca_vale

  !> Verdadeiro se todas as condições da lista estão em CONDICOES.
  pure logical function cpl_condicoes_validas(quando) result(ok)
    character(len=*), intent(in) :: quando
    character(len=CPL_QUANDO_LEN) :: resto, cond

    ok    = .true.
    resto = adjustl(quando)
    do while (len_trim(resto) > 0)
      call proxima_condicao(resto, cond)
      if (.not. any(CONDICOES == cond)) then
        ok = .false.
        return
      end if
    end do
  end function cpl_condicoes_validas

  !> Posição da rota nome em ROTAS, ou 0.
  pure integer function cpl_rota_indice(nome) result(k)
    character(len=*), intent(in) :: nome
    integer :: i

    k = 0
    do i = 1, size(ROTAS)
      if (trim(ROTAS(i)%nome) == trim(nome)) then
        k = i
        return
      end if
    end do
  end function cpl_rota_indice

  !> Posição da malha nome em MALHAS, ou 0.
  pure integer function cpl_malha_indice(nome) result(k)
    character(len=*), intent(in) :: nome
    integer :: i

    k = 0
    do i = 1, size(MALHAS)
      if (trim(MALHAS(i)%nome) == trim(nome)) then
        k = i
        return
      end if
    end do
  end function cpl_malha_indice

  !> Componente de um ponto 'COMPONENTE@malha' ('' se não houver '@').
  pure function cpl_ponto_componente(ponto) result(comp)
    character(len=*), intent(in) :: ponto
    character(len=CPL_PONTO_LEN) :: comp
    integer :: p

    comp = ''
    p = index(ponto, '@')
    if (p > 1) comp = ponto(1:p-1)
  end function cpl_ponto_componente

  !> Malha de um ponto 'COMPONENTE@malha' ('' se não houver '@').
  pure function cpl_ponto_malha(ponto) result(malha)
    character(len=*), intent(in) :: ponto
    character(len=CPL_PONTO_LEN) :: malha
    integer :: p

    malha = ''
    p = index(ponto, '@')
    if (p > 0) malha = ponto(p+1:)
  end function cpl_ponto_malha

  !> Tira a primeira condição da lista resto (separada por vírgula) e a
  !! devolve em cond; resto fica com as demais.
  pure subroutine proxima_condicao(resto, cond)
    character(len=CPL_QUANDO_LEN), intent(inout) :: resto
    character(len=CPL_QUANDO_LEN), intent(out)   :: cond
    integer :: p

    p = index(resto, ',')
    if (p == 0) then
      cond  = resto
      resto = ''
    else
      cond  = resto(1:p-1)
      resto = adjustl(resto(p+1:))
    end if
  end subroutine proxima_condicao

  !> Uma condição da coluna quando, na configuração cfg.
  pure logical function condicao_vale(cond, cfg) result(vale)
    character(len=*),   intent(in) :: cond
    type(cpl_config_t), intent(in) :: cfg

    select case (trim(cond))
    case ('mpas');        vale = .not. cfg%datm
    case ('datm');        vale = cfg%datm
    case ('mom6');        vale = .not. cfg%docn
    case ('docn');        vale = cfg%docn
    case ('med_to_mpas'); vale = cfg%med_to_mpas
    case ('ocn_to_mpas'); vale = .not. cfg%med_to_mpas
    case ('sis2');        vale = cfg%sis2
    case default;         vale = .false.
    end select
  end function condicao_vale

end module cpl_map_mod
