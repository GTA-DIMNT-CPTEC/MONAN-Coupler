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
!!   'conector'  conector NUOPC entre dois componentes; a interpolação é a
!!               da coluna metodo, que o driver escreve na CplList como
!!               remapmethod (desde a R-FASE11-22; antes, o conector usava
!!               o seu padrão, bilinear, sem a opção escrita);
!!   'cap'       código próprio do cap, dentro do mesmo componente;
!!   nome de rota, de ROTAS: interpolação do mediador por regrid_manager_t.
!!
!! No mediador, um mesmo nome pode existir duas vezes em MED@ocn_med: o
!! campo importado (importState) e o exportado (exportState). É o caso de
!! So_t, So_u e So_v. A regra de leitura é: uma rota que parte de
!! MED@ocn_med lê o campo importado; um conector que parte de MED@ocn_med
!! leva o campo exportado, que chegou de MED@atm_med pela rota 'atm2ocn'.
!!
!! Método (coluna metodo): só nas trocas por conector, um dos valores de
!! METODOS_CONECTOR; vazio nas demais. Hoje todas usam 'bilinear', o padrão
!! do conector NUOPC, que era o que valia antes de a opção ser escrita.
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
!! a atual nas chaves pedidas, na ordem de TROCAS, sem repetição. O
!! mediador e os caps dos modelos anunciam e realizam os campos nessa ordem
!! (e na de EXPORTACOES, abaixo): mudar a ordem das linhas muda a ordem do
!! anúncio.
!!
!! LACUNAS: campos que um componente anuncia na importação e que, numa
!! configuração, não têm origem no mapa. São conhecidas e não são erro: a
!! conferência do mapa (cpl_check) as registra como aviso, e não como
!! diferença, que interrompe a rodada desde a R-FASE11-25. O cap
!! atmosférico, porém, interrompe a rodada por conta própria quando um campo
!! que ele importa não está conectado (verify_import_connected), o que
!! acontece nas lacunas do MONAN-A.
!!
!! EXPORTACOES: o que cada modelo exporta (anuncia no exportState) em cada
!! ponto, consumido ou não, na ordem do anúncio do cap. Toda troca por
!! conector que parte de um modelo parte de uma linha desta tabela; um campo
!! exportado sem troca (So_s e Fioo_q do MOM6, por exemplo) só aparece aqui.
!! A exportação do mediador não está nesta tabela: ela é o que chega a
!! MED@ocn_med pelas rotas atm2ocn e atm2ocn_ice (ver cpl_chegadas).
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
  public :: CPL_AUSENTE, CPL_PONTO_LEN, CPL_MEIO_LEN, CPL_QUANDO_LEN, CPL_METODO_LEN
  public :: METODOS_CONECTOR, cpl_metodo_conector
  public :: cpl_troca_vale, cpl_condicoes_validas
  public :: cpl_rota_indice, cpl_malha_indice
  public :: cpl_ponto_componente, cpl_ponto_malha
  public :: cpl_config_atual, cpl_config_valida, cpl_chegadas
  public :: cpl_conector_vale, cpl_conector_fora, cpl_conectores_do_driver
  public :: N_CONECTORES, CONECTOR_DE, CONECTOR_PARA
  public :: cpl_exporta_t, EXPORTACOES, cpl_exportacoes
  public :: cpl_lacuna_t, LACUNAS, cpl_lacuna

  integer, parameter :: r8 = ESMF_KIND_R8

  integer, parameter :: CPL_PONTO_LEN  = 16   !< 'COMPONENTE@malha'
  integer, parameter :: CPL_MEIO_LEN   = 16   !< 'conector', 'cap' ou nome de rota
  integer, parameter :: CPL_QUANDO_LEN = 32   !< lista de condições
  integer, parameter :: CPL_METODO_LEN = 16   !< método de um conector

  !> Métodos aceitos na coluna metodo: os valores da opção remapmethod do
  !! conector NUOPC (NUOPC_Connector, ESMF 8.9.1).
  character(len=CPL_METODO_LEN), parameter :: METODOS_CONECTOR(*) =                 &
    [character(len=CPL_METODO_LEN) :: 'bilinear', 'patch', 'nearest_stod',          &
     'nearest_dtos', 'conserve', 'conserve_2nd', 'redist']

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
    character(len=CPL_METODO_LEN) :: metodo = ''  !< só nas trocas por conector
  end type cpl_troca_t

  !> Um campo que um modelo exporta num ponto, na configuração quando.
  type :: cpl_exporta_t
    character(len=CPL_NOME_LEN)   :: campo  = ''
    character(len=CPL_PONTO_LEN)  :: ponto  = ''
    character(len=CPL_QUANDO_LEN) :: quando = ''
  end type cpl_exporta_t

  !> Um campo importado num ponto que fica sem origem na configuração quando.
  type :: cpl_lacuna_t
    character(len=CPL_NOME_LEN)   :: campo  = ''
    character(len=CPL_PONTO_LEN)  :: ponto  = ''
    character(len=CPL_QUANDO_LEN) :: quando = ''
    character(len=64)             :: motivo = ''
  end type cpl_lacuna_t

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
  type(cpl_troca_t), parameter :: TROCAS(*) = [                                                                                  &
    !           campo             de              para            meio                quando                    metodo
    ! 1. MONAN-A: das células para a grade do cap (mpas_cell_binning) e ao mediador
    cpl_troca_t('Sa_u10m_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sa_v10m_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sa_tbot_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sa_pslv_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_swdn_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_lwdn_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_rain_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sa_shum_mpas',   'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_snow_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_sen_mpas',  'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_lat_mpas',  'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_taux_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Faxa_tauy_mpas', 'ATM@mpas',     'ATM@atm_cap',  'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sa_u10m_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Sa_v10m_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Sa_tbot_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Sa_pslv_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_swdn_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_lwdn_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_rain_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Sa_shum_mpas',   'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_snow_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_sen_mpas',  'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_lat_mpas',  'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_taux_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    cpl_troca_t('Faxa_tauy_mpas', 'ATM@atm_cap',  'MED@atm_med',  'conector',         'mpas',                   'bilinear'), &
    ! 2. DATM para o mediador (o driver não registra o DATM; ver o cabeçalho)
    cpl_troca_t('Sa_u10m',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Sa_v10m',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Sa_tbot',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Sa_shum',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Sa_pslv',        'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Faxa_swdn',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Faxa_lwdn',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Faxa_rain',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    cpl_troca_t('Faxa_snow',      'ATM@datm',     'MED@atm_med',  'conector',         'datm',                   'bilinear'), &
    ! 3. Oceano para o mediador. O DOCN não exporta So_omask: nesse modo o
    !    campo do mediador fica sem origem e mantém o valor inicial.
    cpl_troca_t('So_t',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('So_u',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('So_v',           'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('So_omask',       'OCN@ocn_mom6', 'MED@ocn_med',  'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('So_t',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('So_u',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('So_v',           'OCN@docn',     'MED@ocn_med',  'conector',         'docn',                   'bilinear'), &
    ! 4. Gelo para o mediador, na grade do oceano do mediador
    cpl_troca_t('Si_ifrac_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Si_avsdr_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Si_avsdf_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Si_anidr_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Si_anidf_sis2',  'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Si_t_sis2',      'ICE@ice_sis2', 'MED@ocn_med',  'conector',         'sis2',                   'bilinear'), &
    ! 5. Mediador: da grade do oceano para a malha de fluxo
    cpl_troca_t('So_t',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm_sst',      '',                       ''),         &
    cpl_troca_t('So_u',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm',          '',                       ''),         &
    cpl_troca_t('So_v',           'MED@ocn_med',  'MED@atm_med',  'ocn2atm',          '',                       ''),         &
    cpl_troca_t('So_omask',       'MED@ocn_med',  'MED@atm_med',  'ocn2atm_landmask', '',                       ''),         &
    cpl_troca_t('Si_ifrac_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_troca_t('Si_avsdr_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_troca_t('Si_avsdf_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_troca_t('Si_anidr_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_troca_t('Si_anidf_sis2',  'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    cpl_troca_t('Si_t_sis2',      'MED@ocn_med',  'MED@atm_med',  'ocn2atm_ice',      'sis2',                   ''),         &
    ! 6. Mediador: da malha de fluxo para a grade do oceano (exportState),
    !    na ordem em que o mediador anuncia e realiza a exportação
    cpl_troca_t('Foxx_taux',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_tauy',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_sen',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_evap',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_lwnet',     'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_swnet_vdr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_swnet_vdf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_swnet_idr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Foxx_swnet_idf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Faxa_rain',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Faxa_snow',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Sa_pslv',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Si_ifrac',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn_ice',      '',                       ''),         &
    cpl_troca_t('So_duu10n',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('So_t',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('So_u',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('So_v',           'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Sf_zorl',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Faxa_coszen',    'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Sf_albedo',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_taux',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_tauy',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_sen',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_evap',      'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_lwnet',     'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_swnet_vdr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_swnet_vdf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_swnet_idr', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Fioi_swnet_idf', 'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Sx_tsfc',        'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    cpl_troca_t('Sx_omask',       'MED@atm_med',  'MED@ocn_med',  'atm2ocn',          '',                       ''),         &
    ! 7. Mediador para o oceano: os 14 campos que o MOM6 e o DOCN importam
    cpl_troca_t('Foxx_taux',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_tauy',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_sen',       'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_evap',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_lwnet',     'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_vdr', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_vdf', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_idr', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_idf', 'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Faxa_rain',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Faxa_snow',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Sa_pslv',        'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Si_ifrac',       'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('So_duu10n',      'MED@ocn_med',  'OCN@ocn_mom6', 'conector',         'mom6',                   'bilinear'), &
    cpl_troca_t('Foxx_taux',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_tauy',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_sen',       'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_evap',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_lwnet',     'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_vdr', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_vdf', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_idr', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Foxx_swnet_idf', 'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Faxa_rain',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Faxa_snow',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Sa_pslv',        'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('Si_ifrac',       'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    cpl_troca_t('So_duu10n',      'MED@ocn_med',  'OCN@docn',     'conector',         'docn',                   'bilinear'), &
    ! 8. Mediador para o gelo: forçante atmosférica e depois So_t, So_u e
    !    So_v, na ordem do anúncio do SIS2
    cpl_troca_t('Fioi_taux',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_tauy',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_sen',       'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_evap',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_lwnet',     'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_swnet_vdr', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_swnet_vdf', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_swnet_idr', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Fioi_swnet_idf', 'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Faxa_rain',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Faxa_snow',      'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Sa_pslv',        'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('Faxa_coszen',    'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('So_t',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('So_u',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    cpl_troca_t('So_v',           'MED@ocn_med',  'ICE@ice_sis2', 'conector',         'sis2',                   'bilinear'), &
    ! 9. Contorno oceânico da atmosfera pelo mediador, na ordem do anúncio do
    !    MONAN-A
    cpl_troca_t('Sx_tsfc',        'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_troca_t('Si_ifrac',       'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_troca_t('So_u',           'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_troca_t('So_v',           'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_troca_t('Sf_zorl',        'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_troca_t('Sf_albedo',      'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    cpl_troca_t('Sx_omask',       'MED@ocn_med',  'ATM@atm_cap',  'conector',         'mpas,med_to_mpas',       'bilinear'), &
    ! 10. Contorno oceânico direto do oceano (use_med_to_mpas=.false.): só
    !     os nomes que o oceano exporta e o MONAN-A importa. Sx_tsfc,
    !     Sf_albedo e Sx_omask ficam sem origem, e o cap atmosférico
    !     interrompe a rodada (verify_import_connected). Com o MOM6, esta
    !     combinação é desaconselhada no nuopc.input.
    cpl_troca_t('Si_ifrac',       'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    cpl_troca_t('So_u',           'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    cpl_troca_t('So_v',           'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    cpl_troca_t('Sf_zorl',        'OCN@docn',     'ATM@atm_cap',  'conector',         'mpas,docn,ocn_to_mpas',  'bilinear'), &
    cpl_troca_t('Si_ifrac',       'OCN@ocn_mom6', 'ATM@atm_cap',  'conector',         'mpas,mom6,ocn_to_mpas',  'bilinear'), &
    cpl_troca_t('So_u',           'OCN@ocn_mom6', 'ATM@atm_cap',  'conector',         'mpas,mom6,ocn_to_mpas',  'bilinear'), &
    cpl_troca_t('So_v',           'OCN@ocn_mom6', 'ATM@atm_cap',  'conector',         'mpas,mom6,ocn_to_mpas',  'bilinear'), &
    ! 11. MONAN-A: da grade do cap para as células (caixa do centro, mpas_adaptador)
    cpl_troca_t('Sx_tsfc',        'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_troca_t('Si_ifrac',       'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_troca_t('So_u',           'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_troca_t('So_v',           'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sf_zorl',        'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sf_albedo',      'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   ''),         &
    cpl_troca_t('Sx_omask',       'ATM@atm_cap',  'ATM@mpas',     'cap',              'mpas',                   '') ]

  !--------------------------------------------------------------------------
  ! EXPORTACOES
  !--------------------------------------------------------------------------
  type(cpl_exporta_t), parameter :: EXPORTACOES(*) = [                          &
    !             campo             ponto           quando
    ! MONAN-A (mpas_cap_MONAN)
    cpl_exporta_t('Sa_pslv_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Sa_tbot_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Sa_u10m_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Sa_v10m_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_swdn_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_lwdn_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_rain_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Sa_shum_mpas',   'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_snow_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_sen_mpas',  'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_lat_mpas',  'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_taux_mpas', 'ATM@atm_cap',  'mpas'),                     &
    cpl_exporta_t('Faxa_tauy_mpas', 'ATM@atm_cap',  'mpas'),                     &
    ! DATM (DATM_cap)
    cpl_exporta_t('Sa_u10m',        'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Sa_v10m',        'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Sa_tbot',        'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Sa_shum',        'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Sa_pslv',        'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Faxa_swdn',      'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Faxa_lwdn',      'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Faxa_rain',      'ATM@datm',     'datm'),                     &
    cpl_exporta_t('Faxa_snow',      'ATM@datm',     'datm'),                     &
    ! MOM6 (mom_cap_MONAN); So_s e Fioo_q não têm consumidor, e Si_ifrac só
    ! vai ao MONAN-A com use_med_to_mpas=.false.
    cpl_exporta_t('So_t',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_exporta_t('So_s',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_exporta_t('So_u',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_exporta_t('So_v',           'OCN@ocn_mom6', 'mom6'),                     &
    cpl_exporta_t('So_omask',       'OCN@ocn_mom6', 'mom6'),                     &
    cpl_exporta_t('Fioo_q',         'OCN@ocn_mom6', 'mom6'),                     &
    cpl_exporta_t('Si_ifrac',       'OCN@ocn_mom6', 'mom6'),                     &
    ! DOCN (DOCN_cap)
    cpl_exporta_t('So_t',           'OCN@docn',     'docn'),                     &
    cpl_exporta_t('Si_ifrac',       'OCN@docn',     'docn'),                     &
    cpl_exporta_t('Sf_zorl',        'OCN@docn',     'docn'),                     &
    cpl_exporta_t('So_s',           'OCN@docn',     'docn'),                     &
    cpl_exporta_t('So_u',           'OCN@docn',     'docn'),                     &
    cpl_exporta_t('So_v',           'OCN@docn',     'docn'),                     &
    ! SIS2 (sis_cap_MONAN)
    cpl_exporta_t('Si_ifrac_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_exporta_t('Si_avsdr_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_exporta_t('Si_avsdf_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_exporta_t('Si_anidr_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_exporta_t('Si_anidf_sis2',  'ICE@ice_sis2', 'sis2'),                     &
    cpl_exporta_t('Si_t_sis2',      'ICE@ice_sis2', 'sis2') ]

  !--------------------------------------------------------------------------
  ! LACUNAS
  !--------------------------------------------------------------------------
  type(cpl_lacuna_t), parameter :: LACUNAS(*) = [                                                      &
    !            campo        ponto          quando                  motivo
    ! O mediador anuncia So_omask também com o DOCN, que não o exporta
    cpl_lacuna_t('So_omask',  'MED@ocn_med', 'docn',                 'o DOCN nao exporta So_omask'),       &
    ! Contorno direto do oceano (use_med_to_mpas=.false.): o oceano não
    ! exporta estes campos; o cap atmosférico interrompe a rodada
    cpl_lacuna_t('Sx_tsfc',   'ATM@atm_cap', 'mpas,ocn_to_mpas',     'o oceano nao exporta Sx_tsfc'),      &
    cpl_lacuna_t('Sf_albedo', 'ATM@atm_cap', 'mpas,ocn_to_mpas',     'o oceano nao exporta Sf_albedo'),    &
    cpl_lacuna_t('Sx_omask',  'ATM@atm_cap', 'mpas,ocn_to_mpas',     'o oceano nao exporta Sx_omask'),     &
    cpl_lacuna_t('Sf_zorl',   'ATM@atm_cap', 'mpas,mom6,ocn_to_mpas', 'o MOM6 nao exporta Sf_zorl') ]

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

  !> Conectores que o driver (esm.F90) sabe registrar, na ordem de registro
  !! (a ordem em que o NUOPC os inicializa e a das linhas dos conectores no
  !! relatório de acoplamento), com os componentes como o mapa os chama.
  !! Cada um é registrado se TROCAS tem troca por conector entre os dois
  !! componentes na configuração (cpl_conectores_do_driver); MED->ATM e
  !! OCN->ATM se excluem pela chave use_med_to_mpas. Esta ordem não é a de
  !! TROCAS, que define a ordem do anúncio dos campos.
  integer, parameter :: N_CONECTORES = 7
  character(len=3), parameter :: CONECTOR_DE(N_CONECTORES)   = &
    ['ATM', 'OCN', 'MED', 'MED', 'OCN', 'MED', 'ICE']
  character(len=3), parameter :: CONECTOR_PARA(N_CONECTORES) = &
    ['MED', 'MED', 'OCN', 'ATM', 'ATM', 'ICE', 'MED']

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

    integer :: t

    allocate(nomes(0))
    do t = 1, size(TROCAS)
      if ((TROCAS(t)%meio == 'conector') .neqv. por_conector) cycle
      if (.not. ponto_confere(TROCAS(t)%para, ponto)) cycle
      if (any(nomes == TROCAS(t)%campo)) cycle
      if (vale_em_alguma(TROCAS(t)%quando, cfg, chaves)) &
        nomes = [character(len=CPL_NOME_LEN) :: nomes, TROCAS(t)%campo]
    end do
  end subroutine cpl_chegadas

  !> Campos que um modelo exporta num ponto, na ordem de EXPORTACOES e sem
  !! repetição, com a mesma regra de chaves de cpl_chegadas.
  !!
  !! @param[in]  ponto   'COMPONENTE@malha', ou só 'COMPONENTE' (qualquer malha)
  !! @param[in]  cfg     configuração atual
  !! @param[in]  chaves  chaves de cfg que o componente consulta
  !! @param[out] nomes   campos, na ordem de EXPORTACOES
  subroutine cpl_exportacoes(ponto, cfg, chaves, nomes)
    character(len=*),                         intent(in)  :: ponto
    type(cpl_config_t),                       intent(in)  :: cfg
    character(len=*),                         intent(in)  :: chaves
    character(len=CPL_NOME_LEN), allocatable, intent(out) :: nomes(:)

    integer :: e

    allocate(nomes(0))
    do e = 1, size(EXPORTACOES)
      if (.not. ponto_confere(EXPORTACOES(e)%ponto, ponto)) cycle
      if (any(nomes == EXPORTACOES(e)%campo)) cycle
      if (vale_em_alguma(EXPORTACOES(e)%quando, cfg, chaves)) &
        nomes = [character(len=CPL_NOME_LEN) :: nomes, EXPORTACOES(e)%campo]
    end do
  end subroutine cpl_exportacoes

  !> O ponto p é o ponto pedido ('COMPONENTE@malha' exato, ou só o componente).
  pure logical function ponto_confere(p, pedido) result(ok)
    character(len=*), intent(in) :: p, pedido
    if (index(pedido, '@') > 0) then
      ok = p == pedido
    else
      ok = cpl_ponto_componente(p) == pedido
    end if
  end function ponto_confere

  !> A lista de condições quando vale em alguma configuração válida que
  !! concorda com cfg nas chaves listadas.
  logical function vale_em_alguma(quando, cfg, chaves) result(vale)
    character(len=*),   intent(in) :: quando, chaves
    type(cpl_config_t), intent(in) :: cfg
    type(cpl_config_t) :: c
    type(cpl_troca_t)  :: t
    integer :: k

    t%quando = quando
    vale = .false.
    do k = 0, 15
      c = cpl_config_t(datm=btest(k, 0), docn=btest(k, 1), med_to_mpas=btest(k, 2), &
                       sis2=btest(k, 3))
      if (.not. cpl_config_valida(c)) cycle
      if (.not. concorda(c, cfg, chaves)) cycle
      if (cpl_troca_vale(t, c)) then
        vale = .true.
        return
      end if
    end do
  end function vale_em_alguma

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

  !> O campo importado no ponto é uma lacuna conhecida na configuração cfg
  !! (tabela LACUNAS). ponto é 'COMPONENTE@malha' ou só o componente.
  pure logical function cpl_lacuna(cfg, campo, ponto) result(lacuna)
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: campo, ponto
    integer :: k

    lacuna = .false.
    do k = 1, size(LACUNAS)
      if (LACUNAS(k)%campo /= campo) cycle
      if (.not. ponto_confere(LACUNAS(k)%ponto, ponto)) cycle
      if (.not. cpl_troca_vale(cpl_troca_t(quando=LACUNAS(k)%quando), cfg)) cycle
      lacuna = .true.
      return
    end do
  end function cpl_lacuna

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

  !> Há troca por conector, válida em cfg, do componente de para o
  !! componente para ('ATM', 'OCN', 'ICE', 'MED')? É o que decide se o
  !! driver registra o conector de para para (desde a R-FASE11-21).
  pure logical function cpl_conector_vale(de, para, cfg) result(vale)
    character(len=*),   intent(in) :: de, para
    type(cpl_config_t), intent(in) :: cfg
    integer :: t

    vale = .false.
    do t = 1, size(TROCAS)
      if (trim(TROCAS(t)%meio) /= 'conector') cycle
      if (trim(cpl_ponto_componente(TROCAS(t)%de)) /= de) cycle
      if (trim(cpl_ponto_componente(TROCAS(t)%para)) /= para) cycle
      if (.not. cpl_troca_vale(TROCAS(t), cfg)) cycle
      vale = .true.
      return
    end do
  end function cpl_conector_vale

  !> Método da troca por conector do campo, do componente de para o
  !! componente para (coluna metodo), ou vazio se o mapa não tem essa troca.
  !! Não depende da configuração: as trocas por conector do mesmo campo entre
  !! os mesmos dois componentes têm o mesmo método em todas as linhas de
  !! TROCAS (conferido por tests/unit/test_cpl_map.F90). É o método que o
  !! driver escreve na CplList (cpl_escreve_metodos, em cpl_check).
  !!
  !! @param[in] campo  nome do campo (StandardName)
  !! @param[in] de     componente de origem ('ATM', 'OCN', 'ICE', 'MED')
  !! @param[in] para   componente de destino
  pure function cpl_metodo_conector(campo, de, para) result(metodo)
    character(len=*), intent(in) :: campo, de, para
    character(len=CPL_METODO_LEN) :: metodo
    integer :: t

    metodo = ''
    do t = 1, size(TROCAS)
      if (trim(TROCAS(t)%meio) /= 'conector') cycle
      if (TROCAS(t)%campo /= campo) cycle
      if (trim(cpl_ponto_componente(TROCAS(t)%de)) /= trim(de)) cycle
      if (trim(cpl_ponto_componente(TROCAS(t)%para)) /= trim(para)) cycle
      metodo = TROCAS(t)%metodo
      return
    end do
  end function cpl_metodo_conector

  !> Conectores que o driver registra na configuração cfg: ordem(1:n) são os
  !! índices em CONECTOR_DE/CONECTOR_PARA, na ordem de registro. O
  !! componente atmosférico registrado é sempre o MONAN-A, também com
  !! use_datm (o DATM está no mapa, mas o driver não o registra); por isso o
  !! mapa é consultado com a chave datm desligada. t_fora é a primeira troca
  !! por conector válida que não tem lugar na lista (0 se não há).
  !!
  !! @param[in]  cfg     configuração (cpl_config_atual)
  !! @param[out] ordem   índices dos conectores registrados
  !! @param[out] n       quantos
  !! @param[out] t_fora  índice em TROCAS de um conector sem lugar, ou 0
  pure subroutine cpl_conectores_do_driver(cfg, ordem, n, t_fora)
    type(cpl_config_t), intent(in)  :: cfg
    integer,            intent(out) :: ordem(N_CONECTORES)
    integer,            intent(out) :: n, t_fora
    type(cpl_config_t) :: c
    integer :: k

    c = cfg
    c%datm = .false.
    ordem = 0
    n = 0
    t_fora = cpl_conector_fora(CONECTOR_DE, CONECTOR_PARA, c)
    do k = 1, N_CONECTORES
      if (.not. cpl_conector_vale(CONECTOR_DE(k), CONECTOR_PARA(k), c)) cycle
      n = n + 1
      ordem(n) = k
    end do
  end subroutine cpl_conectores_do_driver

  !> Primeira troca por conector válida em cfg cujo par de componentes não
  !! está na lista (des(k), paras(k)); 0 se todas estão. Serve ao driver
  !! para recusar um conector do mapa que ele não sabe registrar.
  pure integer function cpl_conector_fora(des, paras, cfg) result(t_fora)
    character(len=*),   intent(in) :: des(:), paras(:)
    type(cpl_config_t), intent(in) :: cfg
    integer :: t, k
    logical :: achou

    t_fora = 0
    do t = 1, size(TROCAS)
      if (trim(TROCAS(t)%meio) /= 'conector') cycle
      if (.not. cpl_troca_vale(TROCAS(t), cfg)) cycle
      achou = .false.
      do k = 1, size(des)
        if (trim(cpl_ponto_componente(TROCAS(t)%de)) == trim(des(k)) .and. &
            trim(cpl_ponto_componente(TROCAS(t)%para)) == trim(paras(k))) achou = .true.
      end do
      if (.not. achou) then
        t_fora = t
        return
      end if
    end do
  end function cpl_conector_fora

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
