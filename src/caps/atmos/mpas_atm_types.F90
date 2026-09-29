!> @file mpas_atm_types.F90
!! @brief Tipos públicos do cap MONAN-A 2.0 — sem dependência direta do ESMF.
!!
!! mpas_atm_public_type: campos que o MONAN-A exporta ao mediador, entre
!!   eles q2m (-> Sa_shum_mpas), prec_rain (-> Faxa_rain_mpas) e prec_snow
!!   (-> Faxa_snow_mpas). prec_total continua no tipo, mas nao e' exportado:
!!   o mediador espera chuva e neve separadas.
!! atm_ocean_boundary_type: contorno inferior vindo do mediador, com as
!!   correntes superficiais uocn/vocn do MOM6 para o vento relativo ao
!!   oceano (|V_atm - V_ocn|^2).
!!
!! Depende apenas de mpas_kind_types (sem ESMF).
!! Usado por: mpas_atm_model_mod, mpas_atm_setup_mod, mpas_atm_fluxes_mod,
!! mpas_cap_methods_mod, mpas_cap_MONAN_mod e mpas_import_diag_mod.

module mpas_atm_types_mod

  use mpas_kind_types, only : RKIND
  use mpas_derived_types, only : domain_type

  implicit none
  private

  ! ── Parâmetro de kind ──────────────────────────────────────────────────────
  integer, parameter, public :: MPAS_RKIND = RKIND

  ! ── Campos diagnósticos exportados pelo MPAS-A para o mediador ────────────
  !
  ! Mapeamento cap → mediador (nomes NUOPC com sufixo _mpas):
  !   u10       → Sa_u10m_mpas    vento zonal      10 m [m/s]
  !   v10       → Sa_v10m_mpas    vento meridional 10 m [m/s]
  !   t2m       → Sa_tbot_mpas    temperatura       2 m [K]
  !   q2m       → Sa_shum_mpas    umidade específica 2 m [kg/kg]
  !   pslv      → Sa_pslv_mpas    pressão ao nível do mar [Pa]
  !   swdn_sfc  → Faxa_swdn_mpas  radiação SW descendente [W/m²]
  !   lwdn_sfc  → Faxa_lwdn_mpas  radiação LW descendente [W/m²]
  !   prec_rain → Faxa_rain_mpas  precipitação líquida    [kg/m²/s]
  !   prec_snow → Faxa_snow_mpas  precipitação sólida     [kg/m²/s]
  !
  type, public :: mpas_atm_public_type
    integer :: nCells      = 0  !< células locais incluindo halos (para zero-copy)
    integer :: nCellsSolve = 0  ! < células próprias sem halos (para NetCDF/export)
    integer :: nVertLevels = 0

    ! ── Geometria (ponteiros zero-copy → pool 'mesh') ─────────────────────
    real(MPAS_RKIND), pointer :: latCell(:)    => null()  !< lat [rad]
    real(MPAS_RKIND), pointer :: lonCell(:)    => null()  !< lon [rad]
    real(MPAS_RKIND), pointer :: areaCell(:)   => null()  !< área [m²]

    ! ── Vento e temperatura em baixa atmosfera ────────────────────────────
    real(MPAS_RKIND), pointer :: t2m(:)        => null()  !< T a 2 m [K]
    real(MPAS_RKIND), pointer :: q2m(:)        => null()  !< Hum. específica 2 m [kg/kg]
    real(MPAS_RKIND), pointer :: u10(:)        => null()  !< U a 10 m [m/s]
    real(MPAS_RKIND), pointer :: v10(:)        => null()  !< V a 10 m [m/s]

    ! ── Pressão ───────────────────────────────────────────────────────────
    real(MPAS_RKIND), pointer :: pslv(:)       => null()  !< PSLV [Pa]

    ! ── Radiação (médias do intervalo de acoplamento) ─────────────────────
    real(MPAS_RKIND), pointer :: swdn_sfc(:)   => null()  !< SWdn [W/m²]
    real(MPAS_RKIND), pointer :: lwdn_sfc(:)   => null()  !< LWdn [W/m²]

    ! ── Precipitação (separada em líquida e sólida) ───────────────────────
    real(MPAS_RKIND), pointer :: prec_rain(:)  => null()  !< Prec. líquida [kg/m²/s]
    real(MPAS_RKIND), pointer :: prec_snow(:)  => null()  !< Prec. sólida  [kg/m²/s]
    !> Campo legado: prec_rain + prec_snow. Mantido para compatibilidade interna.
    real(MPAS_RKIND), pointer :: prec_total(:) => null()  !< Prec. total [kg/m²/s]

    ! ── Fluxos turbulentos de superfície ─────────────────────────────────
    real(MPAS_RKIND), pointer :: taux_sfc(:)   => null()  !< τx [N/m²]
    real(MPAS_RKIND), pointer :: tauy_sfc(:)   => null()  !< τy [N/m²]
    real(MPAS_RKIND), pointer :: lhflx(:)      => null()  !< LH [W/m²]
    real(MPAS_RKIND), pointer :: shflx(:)      => null()  !< SH [W/m²]
  end type mpas_atm_public_type

  ! ── Estado interno do cap (sem tipos ESMF) ─────────────────────────────────
  type, public :: mpas_atm_state_type
    logical            :: initialized    = .false.
    logical            :: running        = .false.
    character(len=256) :: config_dir     = './'
    character(len=64)  :: calendar_type  = 'gregorian'
    integer            :: dt_seconds     = 1800
    integer            :: nCells         = 0
    integer            :: nVertLevels    = 55
    integer            :: mpi_comm       = -1
    !> .true. até o fim do primeiro mpas_atm_run: em partida a frio, o primeiro
    !! passo de acoplamento trata a superfície de forma especial.
    logical            :: first_coupling_call = .true.

    ! ── Estado do modelo, preenchido por mpas_atm_init ────────────────────
    type(domain_type), pointer :: domain => null()   !< domínio MPAS

    !> Ponteiros para arrays dos pools do MPAS (lidos em mpas_atm_run), para
    !! calcular incrementos de acumulados e a tensão superficial. Apontam
    !! para memória do MPAS: não devem ser desalocados aqui.
    real(MPAS_RKIND), pointer :: pool_acswdnb(:) => null()   !< J/m² acumulado
    real(MPAS_RKIND), pointer :: pool_aclwdnb(:) => null()   !< J/m² acumulado
    real(MPAS_RKIND), pointer :: pool_rainnc(:)  => null()   !< mm acumulado (estratiforme)
    real(MPAS_RKIND), pointer :: pool_rainc(:)   => null()   !< mm acumulado (convectiva)
    real(MPAS_RKIND), pointer :: pool_ust(:)     => null()   !< vel. de atrito [m/s]
    real(MPAS_RKIND), pointer :: pool_snownc(:)  => null()   !< mm acum. neve estratiforme
    real(MPAS_RKIND), pointer :: pool_q2(:)      => null()   !< umidade específica a 2 m [kg/kg]
    !> uReconstructZonal/Meridional e zgrid do pool 'diag' (nVertLevels x
    !! nCells; nível 1 = camada mais próxima da superfície), usados pelo
    !! cálculo de u10/v10 por perfil logarítmico.
    real(MPAS_RKIND), pointer :: pool_uZonal(:,:) => null()  !< [m/s]
    real(MPAS_RKIND), pointer :: pool_vMerid(:,:) => null()  !< [m/s]
    real(MPAS_RKIND), pointer :: pool_zgrid(:,:)  => null()  !< altura geopotencial [m]

    !> Acumulados do passo anterior, para os incrementos.
    real(MPAS_RKIND), allocatable :: prev_acswdnb(:)   !< J/m²
    real(MPAS_RKIND), allocatable :: prev_aclwdnb(:)   !< J/m²
    real(MPAS_RKIND), allocatable :: prev_precip(:)    !< mm (rainnc + rainc)
    real(MPAS_RKIND), allocatable :: prev_snow(:)      !< mm acumulado

    !> Buffers em unidades instantâneas, apontados por mpas_atm_public_type
    !! (swdn_sfc, lwdn_sfc, prec_total, taux_sfc, tauy_sfc, q2m, prec_rain,
    !! prec_snow e, no cálculo por perfil logarítmico, u10 e v10). Para
    !! esses ponteiros valerem, o objeto tem de ser alvo (TARGET) ou ter sido
    !! alocado por ponteiro, como faz o cap.
    real(MPAS_RKIND), allocatable :: swdn_inst(:)       !< W/m²
    real(MPAS_RKIND), allocatable :: lwdn_inst(:)       !< W/m²
    real(MPAS_RKIND), allocatable :: prec_inst(:)       !< kg/m²/s
    real(MPAS_RKIND), allocatable :: taux_buf(:)        !< N/m²
    real(MPAS_RKIND), allocatable :: tauy_buf(:)        !< N/m²
    real(MPAS_RKIND), allocatable :: q2m_buf(:)         !< kg/kg
    real(MPAS_RKIND), allocatable :: prec_rain_buf(:)   !< kg/m²/s
    real(MPAS_RKIND), allocatable :: prec_snow_buf(:)   !< kg/m²/s
    real(MPAS_RKIND), allocatable :: u10_buf(:)         !< m/s
    real(MPAS_RKIND), allocatable :: v10_buf(:)         !< m/s
  end type mpas_atm_state_type

  ! ── Condições de contorno vindas do oceano (via mediador) ─────────────────
  !
  ! Mapeamento mediador → campo do cap (conector MED→MPAS):
  !   So_t      → sst           SST [K]
  !   Si_ifrac  → ice_fraction  fração de gelo [0–1]
  !   So_u      → uocn          corrente zonal      a 0 m [m/s]
  !   So_v      → vocn          corrente meridional a 0 m [m/s]
  ! Sf_zorl → zorl rugosidade [m] (Charnock no MED —)
  !
  ! uocn/vocn permitem o vento relativo ao oceano nos esquemas de
  !   superfície do MPAS-A.
  type, public :: atm_ocean_boundary_type
    real(MPAS_RKIND), allocatable :: sst(:)          !< SST                      [K]
    real(MPAS_RKIND), allocatable :: ice_fraction(:) !< fração de gelo           [0–1]
    real(MPAS_RKIND), allocatable :: uocn(:)         !< corrente zonal      0 m  [m/s]
    real(MPAS_RKIND), allocatable :: vocn(:)         !< corrente meridional 0 m  [m/s]
    real(MPAS_RKIND), allocatable :: zorl(:)         !< rugosidade               [m]
    real(MPAS_RKIND), allocatable :: alb(:)          !< albedo de superfície [0–1]
    ! > máscara terra/oceano REAL do MOM6
    !! (ocean_grid%mask2dT), recebida do mediador como Sx_omask. Chega
    !! fracionária, porque atravessou dois regrids (OCN→ATM no MED e
    !! ATM→Voronoi no conector); o corte binário fica no consumidor final.
    !! Usada hoje apenas para mascarar continentes em monan2_import_*.nc —
    !! NÃO alimenta a física do MONAN-A, que tem a própria landmask.
    real(MPAS_RKIND), allocatable :: omask(:)        !< 1=oceano, 0=terra       [0–1]
  end type atm_ocean_boundary_type

end module mpas_atm_types_mod
