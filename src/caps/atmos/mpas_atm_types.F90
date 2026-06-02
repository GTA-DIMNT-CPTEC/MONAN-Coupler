!> @file mpas_atm_types.F90
!! @brief Tipos públicos do cap MONAN-A 2.0 — sem dependência direta do ESMF.
!!
!! Versão 7.0 — Sprint A Fase 2 (Maio 2026):
!!   atm_ocean_boundary_type estendido com 2 campos do oceano dinâmico:
!!     uocn, vocn : correntes superficiais [m/s] do MOM6 via mediador
!!   Habilita cálculo correto do vento relativo ao oceano:
!!     |V_atm − V_ocn|² em vez de |V_atm|² (era erro em correntes fortes).
!!
!! Versão 6.0 — Campos ajustados ao mediador MED_cap (ESMF/NUOPC 8.9.1):
!!   mpas_atm_public_type agora inclui:
!!     q2m       : umidade específica a 2 m [kg/kg]  → Sa_shum_mpas
!!     prec_rain : precipitação líquida  [kg/m²/s]   → Faxa_rain_mpas
!!     prec_snow : precipitação sólida   [kg/m²/s]   → Faxa_snow_mpas
!!
!!   O campo prec_total é mantido para compatibilidade, mas NÃO é exportado
!!   ao mediador. O mediador espera rain e snow separados.
!!
!! Depende apenas de mpas_kind_types (sem ESMF).
!! Usado por: mpas_atm_model_mod, mpas_cap_methods_mod, mpas_cap_mod.

module mpas_atm_types_mod

  use mpas_kind_types, only : RKIND

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
    integer :: nCellsSolve = 0  !< células próprias sem halos (B-32 — para NetCDF/export)
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
  end type mpas_atm_state_type

  ! ── Condições de contorno vindas do oceano (via mediador) ─────────────────
  !
  ! Mapeamento mediador → campo do cap (conector MED→MPAS, Fase 2):
  !   So_t      → sst           SST [K]
  !   Si_ifrac  → ice_fraction  fração de gelo [0–1]
  !   So_u      → uocn          corrente zonal      a 0 m [m/s]
  !   So_v      → vocn          corrente meridional a 0 m [m/s]
  !   Sf_zorl   → zorl          rugosidade [m]  (Charnock no MED — Sprint C)
  !
  ! Sprint A (Maio 2026): adicionados uocn/vocn para habilitar vento
  !   relativo ao oceano nos esquemas de superfície do MPAS-A.
  !   Antes: zorl/ice_fraction/uocn/vocn fixos em defaults; SST do MOM6.
  !   Agora: SST/ifrac/uocn/vocn dinâmicos do MOM6; zorl ainda default.
  type, public :: atm_ocean_boundary_type
    real(MPAS_RKIND), allocatable :: sst(:)          !< SST                      [K]
    real(MPAS_RKIND), allocatable :: ice_fraction(:) !< fração de gelo           [0–1]
    real(MPAS_RKIND), allocatable :: uocn(:)         !< corrente zonal      0 m  [m/s]
    real(MPAS_RKIND), allocatable :: vocn(:)         !< corrente meridional 0 m  [m/s]
    real(MPAS_RKIND), allocatable :: zorl(:)         !< rugosidade               [m]
  end type atm_ocean_boundary_type

end module mpas_atm_types_mod
