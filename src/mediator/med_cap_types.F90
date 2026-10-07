!> @file med_cap_types.F90
!! @brief Tipos derivados, constantes físicas e listas de campos do mediador NUOPC.
!!
!! Contém as definições compartilhadas entre os módulos do mediador:
!!   MED_InternalState, MED_InternalStateWrapper: estado interno ESMF,
!!   agrupado nos subtipos med_ocn_flux_fields_t, med_ocn_fields_t,
!!   med_ice_fields_t, med_sfc_fields_t, med_par_t e med_diag_config_t
!!   Constantes físicas Large & Yeager (2009); usadas pelo bulk NCAR
!!   MED_FIELDS: campos internos do mediador; constantes F_* com a posição
!!   de cada um, usada pela física em med_flux_t%p
!!   MED_KEYS: chaves de configuração que escolhem os campos anunciados,
!!   cujas listas saem do mapa de acoplamento (cpl_map)
!!
!! O módulo não tem variáveis: o que muda durante a rodada (comunicador MPI,
!! PET local e configuração do diagnóstico de importação) fica no estado
!! interno, MED_InternalState.
!!
!! Todos os outros módulos do mediador devem usar este como base:
!!   use med_cap_types_mod, only: MED_InternalState, rho_air, ...

module med_cap_types_mod

  use ESMF
  use coupler_constants_mod, only : rho_air, Cp_air, L_evap, T_freeze => T0_KELVIN, eps_q, es_coef_a, es_coef_b, es_coef_c, sigma_sb
  use regrid_manager_mod, only : regrid_manager_t
  use cpl_fields_mod, only : CPL_NAME_LEN
  use coupler_constants_mod, only : T_FREEZE_SEAWATER, ALB_OCEAN_DEFAULT, ALB_ICE_DEFAULT

  implicit none
  private

  public :: MED_InternalState, MED_InternalStateWrapper
  public :: med_ocn_flux_fields_t, med_ocn_fields_t, med_ice_fields_t, med_sfc_fields_t
  public :: med_par_t, med_diag_config_t, med_run_flags_t
  ! Contagem dos pontos completados por vizinhança (relatório de acoplamento)
  public :: med_fill_count_t, N_FILL, FILL_NAMES
  public :: med_flux_t, med_array_t
  public :: COMPL_SST, COMPL_ICE_IFRAC, COMPL_ICE_AVSDR, COMPL_ICE_AVSDF
  public :: COMPL_ICE_ANIDR, COMPL_ICE_ANIDF, COMPL_ICE_T, COMPL_IFRAC_EXP
  ! Constantes físicas de coupler_constants_mod, re-exportadas
  public :: rho_air, Cp_air, L_evap, T_freeze, eps_q
  public :: es_coef_a, es_coef_b, es_coef_c, sigma_sb
  ! Parâmetros do bulk e do balanço radiativo
  public :: Cd_neut, Ch_neut, Ce_neut, albedo_ocn
  public :: SST_BULK_FALLBACK, SHUM_OCEAN_DEFAULT
  public :: f_vis_dir, f_vis_dif, f_nir_dir, f_nir_dif
  ! Chaves de configuração que escolhem os campos do mediador
  public :: MED_KEYS
  public :: med_field_spec_t, MED_FIELDS, med_named_field_t, med_field_index
  ! Posição de cada campo interno em MED_FIELDS e em med_flux_t%p
  public :: F_TAUX, F_TAUY, F_SEN, F_EVAP, F_LWNET, F_SWVDR, F_SWVDF, F_SWIDR, F_SWIDF
  public :: F_RAIN, F_SNOW, F_PSLV, F_IFRAC, F_OMASK, F_DUU10N, F_SST, F_UOCN, F_VOCN
  public :: F_ZORL, F_ALB_VDR, F_ALB_VDF, F_ALB_IDR, F_ALB_IDF, F_COSZEN, F_ALBEDO, F_TICE, F_TSFC
  public :: F_TAUX_ICE, F_TAUY_ICE, F_SEN_ICE, F_EVAP_ICE, F_LWNET_ICE, F_SWVDR_ICE, F_SWVDF_ICE, F_SWIDR_ICE, F_SWIDF_ICE

  ! Parâmetros do bulk e do balanço radiativo do mediador (Large & Yeager 2009).
  ! As constantes físicas vêm de coupler_constants_mod e são re-exportadas aqui.
  real(ESMF_KIND_R8), parameter :: Cd_neut    = 1.3e-3_ESMF_KIND_R8  !< Coef. arrasto neutro
  real(ESMF_KIND_R8), parameter :: Ch_neut    = 1.0e-3_ESMF_KIND_R8  !< Coef. calor sensível
  real(ESMF_KIND_R8), parameter :: Ce_neut    = 1.15e-3_ESMF_KIND_R8 !< Coef. calor latente
  real(ESMF_KIND_R8), parameter :: albedo_ocn = 0.06_ESMF_KIND_R8    !< Albedo médio do oceano
  !real(ESMF_KIND_R8), parameter :: albedo_ocn = 0.26_ESMF_KIND_R8    !< Albedo médio do oceano
  !> SST de segurança para bulk quando o valor recebido está fora de [271, 308] K.
  !! NÃO é fonte de dado; guard para evitar instabilidade numérica.
  real(ESMF_KIND_R8), parameter :: SST_BULK_FALLBACK = 290.0_ESMF_KIND_R8
  !> Umidade específica padrão ~80% UR a 290 K (Sa_shum_mpas ausente).
  real(ESMF_KIND_R8), parameter :: SHUM_OCEAN_DEFAULT = 0.010_ESMF_KIND_R8
  !> Partição espectral da onda curta incidente (Briegleb 1992; Large & Yeager 2009, eq. 5).
  !! Soma = 1.000 (fechamento radiativo).
  real(ESMF_KIND_R8), parameter :: f_vis_dir = 0.285_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: f_vis_dif = 0.215_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: f_nir_dir = 0.285_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: f_nir_dif = 0.215_ESMF_KIND_R8

  !> Um campo interno do mediador, na malha de fluxo: nome de acoplamento
  !! (o do campo em FIELDS e no mapa), nome do ESMF_Field, valor inicial e se
  !! o campo é zerado no início de cada passo (zero_med_fluxes, med_flux).
  type :: med_field_spec_t
    character(len=CPL_NAME_LEN) :: name      = ''
    character(len=16)           :: esmf_name = ''
    real(ESMF_KIND_R8)          :: initial   = 0.0_ESMF_KIND_R8
    logical                     :: zero_each_step = .false.
  end type med_field_spec_t

  !> Campos internos do mediador, na ordem de criação. create_internal_fields
  !! (med_init) cria cada um na malha de fluxo, guarda-o no registro
  !! is%fields com o nome de acoplamento e o preenche com o valor inicial;
  !! zero_med_fluxes (med_flux) zera, no início de cada passo, os que têm a
  !! última coluna .true.; associate_fluxes (med_exchange) dá à física o
  !! array de cada um em med_flux_t%p, na posição do campo nesta tabela
  !! (constantes F_*, abaixo). Para incluir um campo calculado no mediador:
  !! uma linha aqui, a constante F_* da posição e o cálculo, por
  !! fluxes%p(F_*)%a. Os componentes nomeados de is%ocn_flx, is%ocn, is%ice
  !! e is%sfc (bind_internal_fields, em med_init) só existem para os campos
  !! que o código fora da física usa pelo nome.
  !!   colunas: nome de acoplamento, nome do ESMF_Field, valor inicial, zerado a cada passo
  type(med_field_spec_t), parameter :: MED_FIELDS(*) = [                                    &
    med_field_spec_t('Foxx_taux',       'med_taux',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_tauy',       'med_tauy',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_sen',        'med_sen',        0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_evap',       'med_evap',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_lwnet',      'med_lwnet',      0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_swnet_vdr',  'med_swvdr',      0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_swnet_vdf',  'med_swvdf',      0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_swnet_idr',  'med_swidr',      0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Foxx_swnet_idf',  'med_swidf',      0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Faxa_rain',       'med_rain',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Faxa_snow',       'med_snow',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Sa_pslv',         'med_pslv',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Si_ifrac',        'med_ifrac',      0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Sx_omask',        'med_omask',      1.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('So_duu10n',       'med_duu10n',     0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('So_t',            'med_sst',        SST_BULK_FALLBACK,  .false.),  &
    med_field_spec_t('So_u',            'med_uocn',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('So_v',            'med_vocn',       0.0_ESMF_KIND_R8,   .true. ),  &
    med_field_spec_t('Sf_zorl',         'med_zorl',       0.01_ESMF_KIND_R8,  .false.),  &
    med_field_spec_t('Si_avsdr_sis2',   'med_albvdr_ice', ALB_ICE_DEFAULT,    .false.),  &
    med_field_spec_t('Si_avsdf_sis2',   'med_albvdf_ice', ALB_ICE_DEFAULT,    .false.),  &
    med_field_spec_t('Si_anidr_sis2',   'med_albidr_ice', ALB_ICE_DEFAULT,    .false.),  &
    med_field_spec_t('Si_anidf_sis2',   'med_albidf_ice', ALB_ICE_DEFAULT,    .false.),  &
    med_field_spec_t('Faxa_coszen',     'med_coszen',     0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Sf_albedo',       'med_albedo',     ALB_OCEAN_DEFAULT,  .false.),  &
    med_field_spec_t('Si_t_sis2',       'med_tice',       T_FREEZE_SEAWATER,  .false.),  &
    med_field_spec_t('Sx_tsfc',         'med_tsfc_comp',  T_FREEZE_SEAWATER,  .false.),  &
    med_field_spec_t('Fioi_taux',       'med_taux_ice',   0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_tauy',       'med_tauy_ice',   0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_sen',        'med_sen_ice',    0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_evap',       'med_evap_ice',   0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_lwnet',      'med_lwnet_ice',  0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_swnet_vdr',  'med_swvdr_ice',  0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_swnet_vdf',  'med_swvdf_ice',  0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_swnet_idr',  'med_swidr_ice',  0.0_ESMF_KIND_R8,   .false.),  &
    med_field_spec_t('Fioi_swnet_idf',  'med_swidf_ice',  0.0_ESMF_KIND_R8,   .false.) ]

  !> Posição de cada campo em MED_FIELDS e em med_flux_t%p. Seguem a ordem
  !! da tabela; tests/unit/test_med_fields.F90 confere cada constante contra
  !! o nome do campo.
  integer, parameter :: F_TAUX       =  1   !< Foxx_taux
  integer, parameter :: F_TAUY       =  2   !< Foxx_tauy
  integer, parameter :: F_SEN        =  3   !< Foxx_sen
  integer, parameter :: F_EVAP       =  4   !< Foxx_evap
  integer, parameter :: F_LWNET      =  5   !< Foxx_lwnet
  integer, parameter :: F_SWVDR      =  6   !< Foxx_swnet_vdr
  integer, parameter :: F_SWVDF      =  7   !< Foxx_swnet_vdf
  integer, parameter :: F_SWIDR      =  8   !< Foxx_swnet_idr
  integer, parameter :: F_SWIDF      =  9   !< Foxx_swnet_idf
  integer, parameter :: F_RAIN       = 10   !< Faxa_rain
  integer, parameter :: F_SNOW       = 11   !< Faxa_snow
  integer, parameter :: F_PSLV       = 12   !< Sa_pslv
  integer, parameter :: F_IFRAC      = 13   !< Si_ifrac
  integer, parameter :: F_OMASK      = 14   !< Sx_omask
  integer, parameter :: F_DUU10N     = 15   !< So_duu10n
  integer, parameter :: F_SST        = 16   !< So_t
  integer, parameter :: F_UOCN       = 17   !< So_u
  integer, parameter :: F_VOCN       = 18   !< So_v
  integer, parameter :: F_ZORL       = 19   !< Sf_zorl
  integer, parameter :: F_ALB_VDR    = 20   !< Si_avsdr_sis2
  integer, parameter :: F_ALB_VDF    = 21   !< Si_avsdf_sis2
  integer, parameter :: F_ALB_IDR    = 22   !< Si_anidr_sis2
  integer, parameter :: F_ALB_IDF    = 23   !< Si_anidf_sis2
  integer, parameter :: F_COSZEN     = 24   !< Faxa_coszen
  integer, parameter :: F_ALBEDO     = 25   !< Sf_albedo
  integer, parameter :: F_TICE       = 26   !< Si_t_sis2
  integer, parameter :: F_TSFC       = 27   !< Sx_tsfc
  integer, parameter :: F_TAUX_ICE   = 28   !< Fioi_taux
  integer, parameter :: F_TAUY_ICE   = 29   !< Fioi_tauy
  integer, parameter :: F_SEN_ICE    = 30   !< Fioi_sen
  integer, parameter :: F_EVAP_ICE   = 31   !< Fioi_evap
  integer, parameter :: F_LWNET_ICE  = 32   !< Fioi_lwnet
  integer, parameter :: F_SWVDR_ICE  = 33   !< Fioi_swnet_vdr
  integer, parameter :: F_SWVDF_ICE  = 34   !< Fioi_swnet_vdf
  integer, parameter :: F_SWIDR_ICE  = 35   !< Fioi_swnet_idr
  integer, parameter :: F_SWIDF_ICE  = 36   !< Fioi_swnet_idf

  !> Um array 2D da malha de fluxo, com os limites locais da DE.
  type :: med_array_t
    real(ESMF_KIND_R8), pointer :: a(:,:) => null()
  end type med_array_t

  !> Arrays da física bulk (med_bulk_ncar), na malha de fluxo, com os
  !! limites locais da DE: p(k)%a aponta para os valores do campo interno k
  !! de MED_FIELDS (constantes F_*), associado pela fase compute_fluxes
  !! (med_exchange) a cada passo. Um ponteiro nulo é um campo indisponível.
  !! A física lê e escreve só por aqui, sem conhecer o estado interno, os
  !! campos do ESMF nem as rotas; por exemplo, fluxes%p(F_TAUX)%a é a
  !! tensão zonal sobre a água aberta (Foxx_taux).
  type :: med_flux_t
    type(med_array_t) :: p(size(MED_FIELDS))
  end type med_flux_t

  ! Estado interno do mediador, agrupado por assunto
  !
  ! Todos os campos ESMF abaixo estão na grade ATM regular 360×180 do
  ! mediador (is%atm_grid).

  !> Fluxos e estados que o mediador envia ao oceano (MOM6): os fluxos do bulk
  !! NCAR sobre água aberta (Foxx_*) e os campos da atmosfera repassados
  !! (Faxa_rain, Faxa_snow, Sa_pslv, So_duu10n).
  type :: med_ocn_flux_fields_t
    type(ESMF_Field) :: taux, tauy          !< Foxx_taux, Foxx_tauy [Pa]
    type(ESMF_Field) :: sen, evap           !< Foxx_sen [W/m²], Foxx_evap [kg/m²/s]
    type(ESMF_Field) :: lwnet               !< Foxx_lwnet [W/m²]
    !> Onda curta líquida por banda (Foxx_swnet_*), calculada SOMENTE com o
    !! albedo de água aberta.
    type(ESMF_Field) :: swvdr, swvdf, swidr, swidf
    type(ESMF_Field) :: rain, snow, pslv    !< repassados da atmosfera
    !> So_duu10n = |V_atm − V_ocn|² (protocolo CMEPS).
    type(ESMF_Field) :: duu10n
  end type med_ocn_flux_fields_t

  !> Estado do oceano interpolado para a grade ATM.
  type :: med_ocn_fields_t
    !> SST (So_t) na grade ATM. Permanece SST PURA: o SIS2 precisa da
    !! temperatura real do oceano sob o gelo para o fluxo de calor basal
    !! (ICE_KMELT), e misturar Si_t_sis2 ali seria circular. Nunca é
    !! sobrescrita pela temperatura composta (ver med_sfc_fields_t%tsfc).
    type(ESMF_Field) :: sst
    !> Correntes oceânicas So_u e So_v, interpoladas OCN → ATM [m/s].
    !! Necessárias para So_duu10n.
    type(ESMF_Field) :: u, v
    !> Máscara terra/oceano real (So_omask) na grade ATM, obtida uma vez.
    type(ESMF_Field) :: omask
    logical          :: omask_done = .false.   !< regrid da máscara já tentado
  end type med_ocn_fields_t

  !> Gelo marinho (SIS2) na grade ATM: fração, temperatura de pele, albedos por
  !! banda e o segundo conjunto de fluxos (Fioi_*), calculado com a temperatura
  !! real do gelo e enviado ao SIS2 no lugar dos Foxx_*.
  !!
  !! Si_ifrac_sis2 e os 4 albedos do gelo são realizados pelo MED na MESMA
  !! ocn_grid de So_t (a grade do ICE usa a mesma ocean_hgrid.nc) e chegam à
  !! grade ATM pela rota 'ocn2atm_ice'.
  type :: med_ice_fields_t
    type(ESMF_Field) :: ifrac   !< Si_ifrac (regrid do SIS2 ou fallback pela SST)
    type(ESMF_Field) :: tice    !< Si_t_sis2, temperatura de pele do gelo [K]
    type(ESMF_Field) :: taux, tauy, sen, evap, lwnet   !< Fioi_*
    !> Onda curta líquida ESPECÍFICA do gelo (Fioi_swnet_*), calculada com o
    !! albedo REAL do gelo por banda, sem misturar com o albedo de água
    !! aberta. Se o SIS2 recebesse Foxx_swnet_*, calculado com um albedo
    !! MÉDIO da célula (água e gelo ponderados por Si_ifrac), o gelo
    !! absorveria SW com um albedo mais BAIXO que o seu próprio (ex.:
    !! ifrac=0,5, albedo do gelo~0,7, da água~0,06 -> albedo médio~0,38 ->
    !! gelo absorve ~62% de swdn em vez dos ~30% fisicamente corretos). Ver
    !! med_bulk_ncar.F90 para o cálculo.
    type(ESMF_Field) :: swvdr, swvdf, swidr, swidf
    !> Albedo do gelo por banda, interpolado do SIS2. Usado em
    !! med_bulk_ncar.F90 no lugar da constante albedo_ocn nas células com
    !! gelo (ponderado por ifrac).
    type(ESMF_Field) :: alb_vdr   !< Si_avsdr_sis2 [visível direto]
    type(ESMF_Field) :: alb_vdf   !< Si_avsdf_sis2 [visível difuso]
    type(ESMF_Field) :: alb_idr   !< Si_anidr_sis2 [NIR direto]
    type(ESMF_Field) :: alb_idf   !< Si_anidf_sis2 [NIR difuso]
  end type med_ice_fields_t

  !> Superfície vista pela atmosfera (e, no caso de coszen, pelo SIS2).
  type :: med_sfc_fields_t
    !> Rugosidade Charnock + Smith, calculada a partir de Foxx_taux/tauy;
    !! exportada como Sf_zorl -> MPAS [m].
    type(ESMF_Field) :: zorl
    !> Cosseno do ângulo zenital solar, calculado no bulk NCAR a partir de
    !! lat/lon/clock; exportado como Faxa_coszen -> SIS2 (is%aib%coszen, ver
    !! sis_cap_fields.F90::import_forcing).
    type(ESMF_Field) :: coszen
    !> Albedo de banda larga efetivo (água aberta dinâmica + gelo real,
    !! ponderado por f_vis_dir/f_vis_dif/f_nir_dir/f_nir_dif), exportado como
    !! Sf_albedo -> MONAN-A.
    type(ESMF_Field) :: albedo
    !> Temperatura de superfície COMPOSTA (Si_ifrac pondera SST e Si_t_sis2),
    !! útil só para a atmosfera (radiação e camada limite sobre a célula
    !! mista), exportada como "Sx_tsfc" (ver med_export.F90 e mpas_cap_MONAN.F90).
    type(ESMF_Field) :: tsfc
  end type med_sfc_fields_t

  !> Comunicador MPI e PETs do mediador, obtidos da VM em InitializeRealize.
  !! Alimentam os MPI_Allreduce coletivos do Advance e do diagnóstico.
  type :: med_par_t
    integer :: comm      = -1   !< Comunicador MPI do mediador
    integer :: local_pet = -1   !< PET local
    integer :: pet_count = -1   !< Número de PETs
  end type med_par_t

  !> Diagnóstico de importação (mom6_output.nml, lido por
  !! med_read_import_config e usado por med_write_import_fields).
  type :: med_diag_config_t
    logical            :: write_import = .false.
    character(len=256) :: import_dir   = 'diag_import'
  end type med_diag_config_t

  !> Pontos completados por vizinhança num campo, neste PET, ao longo da
  !! rodada: quantas vezes o preenchimento rodou, quantos pontos estavam fora
  !! da faixa válida e quantos ficaram com o valor fixo. Só alimentam o
  !! relatório de acoplamento (med_diag, report_fills, chamada no último
  !! passo por mediatoradvancereport).
  type :: med_fill_count_t
    integer(ESMF_KIND_I8) :: n_applied = 0_ESMF_KIND_I8
    integer(ESMF_KIND_I8) :: n_invalid_pts = 0_ESMF_KIND_I8
    integer(ESMF_KIND_I8) :: n_fixed_pts = 0_ESMF_KIND_I8
  end type med_fill_count_t

  !> Campos completados por vizinhança no mediador, com a rota que os traz.
  integer, parameter :: N_FILL          = 8
  integer, parameter :: COMPL_SST       = 1   !< So_t na malha de fluxo (med_ocean)
  integer, parameter :: COMPL_ICE_IFRAC = 2   !< gelo do SIS2 na malha de fluxo (med_ice)
  integer, parameter :: COMPL_ICE_AVSDR = 3
  integer, parameter :: COMPL_ICE_AVSDF = 4
  integer, parameter :: COMPL_ICE_ANIDR = 5
  integer, parameter :: COMPL_ICE_ANIDF = 6
  integer, parameter :: COMPL_ICE_T     = 7
  integer, parameter :: COMPL_IFRAC_EXP = 8   !< Si_ifrac exportado (med_export)
  character(len=32), parameter :: FILL_NAMES(N_FILL) = [character(len=32) :: &
    'ocn2atm_sst So_t', 'ocn2atm_ice Si_ifrac_sis2', 'ocn2atm_ice Si_avsdr_sis2',      &
    'ocn2atm_ice Si_avsdf_sis2', 'ocn2atm_ice Si_anidr_sis2', 'ocn2atm_ice Si_anidf_sis2', &
    'ocn2atm_ice Si_t_sis2', 'atm2ocn_ice Si_ifrac']

  !> Marcas de "primeira vez" e contadores que mudam durante a rodada.
  !! Eram variáveis com save; os valores iniciais são os mesmos.
  type :: med_run_flags_t
    !> tentativas do gate da SST em InitializeDataComplete (idc_wait_for_sst)
    integer :: n_gate_tries = 0
    !> diagnóstico da SST bruta do MOM6 já registrado (primeiro Advance)
    logical :: raw_sst_diag_done = .false.
    !> resumo dos forçantes ainda não registrado (log_atm_forcing_summary)
    logical :: first_forcing_summary = .true.
    !> Si_ifrac já preenchido do OISST (fill_ifrac_from_oisst, modo init_only)
    logical :: ifrac_init_done = .false.
    !> pontos completados por vizinhança, por campo (índices COMPL_*)
    type(med_fill_count_t) :: fill_counts(N_FILL)
  end type med_run_flags_t

  !> Uma entrada do registro de campos internos: nome de acoplamento e campo.
  type :: med_named_field_t
    character(len=CPL_NAME_LEN) :: name = ''
    type(ESMF_Field)            :: field
  end type med_named_field_t

  type :: MED_InternalState

    type(ESMF_Grid) :: atm_grid   !< Grade ATM regular 360×180 para cálculo do bulk
    type(ESMF_Grid) :: ocn_grid   !< Grade OCN para campos exportados ao oceano

    type(med_ocn_flux_fields_t) :: ocn_flx   !< enviados ao oceano
    type(med_ocn_fields_t)      :: ocn       !< estado do oceano
    type(med_ice_fields_t)      :: ice       !< gelo marinho
    type(med_sfc_fields_t)      :: sfc       !< superfície para a atmosfera
    !> Registro dos campos internos (MED_FIELDS): nome de acoplamento e campo.
    type(med_named_field_t)     :: fields(size(MED_FIELDS))

    !> Rotas de interpolação do mediador (ver src/regrid):
    !!   atm2ocn          ATM -> OCN, vizinho mais próximo (fluxos exportados)
    !!   ocn2atm          OCN -> ATM, bilinear (So_t inicial, correntes, reserva)
    !!   ocn2atm_sst      OCN -> ATM, conservativo mascarado (So_t)
    !!   ocn2atm_ice      OCN -> ATM, conservativo mascarado (campos do SIS2)
    !!   ocn2atm_landmask OCN -> ATM, vizinho mais próximo (So_omask)
    !!   atm2ocn_ice      ATM -> OCN, conservativo (Si_ifrac exportado)
    !! Cada rota pode ser trocada em nuopc.input, grupo &nuopc_regrid.
    type(regrid_manager_t) :: regrid

    logical :: use_mpas_atm     = .false.   !< .true. = MPAS, .false. = DATM (de atm_model)
    logical :: use_med_to_mpas  = .false.   !< atm_boundary=med (cfg_atm_boundary)

    type(med_par_t)         :: par    !< comunicador e PETs
    type(med_diag_config_t) :: diag   !< diagnóstico de importação
    type(med_run_flags_t)   :: run    !< marcas de primeira vez e contadores

  end type MED_InternalState

  type :: MED_InternalStateWrapper
    type(MED_InternalState), pointer :: wrap => null()
  end type MED_InternalStateWrapper

  ! Campos anunciados e realizados pelo mediador

  !> Chaves de &nuopc_mode que o mediador consulta para anunciar e realizar
  !! os campos: o modelo da atmosfera (atm_model) e o do gelo (ice_model).
  !! As listas saem do mapa de acoplamento, com
  !! cpl_arrivals (src/coupling/cpl_map.F90):
  !!   importação, malha de fluxo (MED@atm_med): forçantes do MONAN-A
  !!     (sufixo _mpas) ou do DATM;
  !!   importação, grade do oceano (MED@ocn_med): So_t, So_u, So_v, So_omask
  !!     e, com o SIS2, os seis campos *_sis2; So_omask é anunciada mesmo com
  !!     o DOCN, que não a exporta (as chaves do oceano ficam livres);
  !!   exportação (MED@ocn_med): os campos que voltam da malha de fluxo pelas
  !!     rotas atm2ocn e atm2ocn_ice.
  !! Sx_omask é a máscara do MOM6 interpolada para a malha de fluxo, com nome
  !! próprio para não formar um par importação e exportação homônimo com
  !! So_omask; vai para o diagnóstico mom6_import_*.nc e para o MONAN-A.
  character(len=*), parameter :: MED_KEYS = 'atm_model,ice_model'

contains

  !> @brief Posição do campo name no registro de campos internos (0 se não está).
  !! @param[in] is    estado interno do mediador
  !! @param[in] name  nome de acoplamento do campo
  pure integer function med_field_index(is, name) result(k)
    type(MED_InternalState), intent(in) :: is
    character(len=*),        intent(in) :: name
    integer :: i

    k = 0
    do i = 1, size(is%fields)
      if (trim(is%fields(i)%name) == trim(name)) then
        k = i
        return
      end if
    end do
  end function med_field_index

end module med_cap_types_mod
