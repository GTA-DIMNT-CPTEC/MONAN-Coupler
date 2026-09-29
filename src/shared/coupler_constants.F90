!> @file coupler_constants.F90
!! @brief Constantes físicas e da grade atmosférica do acoplador, num só lugar.
!!
!! Os valores são exatamente os que estavam espalhados pelo código (mesmo
!! literal, mesmo tipo), para que a unificação não mude nenhum resultado.
!! Constantes com o mesmo nome e valor diferente continuam separadas até que
!! a diferença seja avaliada (ver "Pendências" no fim do arquivo).
module coupler_constants_mod

  use ESMF, only : ESMF_KIND_R8

  implicit none
  private

  !--------------------------------------------------------------------------
  ! Grade atmosférica regular do mediador (1 grau), usada também nas saídas
  ! diagnósticas do cap atmosférico.
  !--------------------------------------------------------------------------
  integer, parameter, public :: ATM_NX = 360   !< pontos em longitude
  integer, parameter, public :: ATM_NY = 180   !< pontos em latitude

  !--------------------------------------------------------------------------
  ! Constantes físicas
  !--------------------------------------------------------------------------
  real(ESMF_KIND_R8), parameter, public :: GRAV      = 9.81_ESMF_KIND_R8    !< gravidade [m/s²]
  real(ESMF_KIND_R8), parameter, public :: T0_KELVIN = 273.15_ESMF_KIND_R8  !< 0 °C [K]
  real(ESMF_KIND_R8), parameter, public :: T_FREEZE_SEAWATER = 271.35_ESMF_KIND_R8 !< congelamento da água do mar [K]
  real(ESMF_KIND_R8), parameter, public :: rho_air   = 1.225_ESMF_KIND_R8   !< densidade do ar [kg/m³]
  real(ESMF_KIND_R8), parameter, public :: Cp_air    = 1004.67_ESMF_KIND_R8 !< calor específico do ar [J/kg/K]
  real(ESMF_KIND_R8), parameter, public :: L_evap    = 2.501e6_ESMF_KIND_R8 !< calor latente de evaporação [J/kg]
  real(ESMF_KIND_R8), parameter, public :: sigma_sb  = 5.67e-8_ESMF_KIND_R8 !< Stefan-Boltzmann [W/m²/K⁴]
  real(ESMF_KIND_R8), parameter, public :: eps_q     = 0.622_ESMF_KIND_R8   !< razão das massas molares água/ar seco
  !> Pressão de vapor de saturação (Bolton 1980): es = a·exp(b·T/(T+c)), T em °C
  real(ESMF_KIND_R8), parameter, public :: es_coef_a = 611.2_ESMF_KIND_R8   !< [Pa]
  real(ESMF_KIND_R8), parameter, public :: es_coef_b = 17.67_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter, public :: es_coef_c = 243.5_ESMF_KIND_R8   !< [°C]

  !--------------------------------------------------------------------------
  ! Conversões e marcas
  !--------------------------------------------------------------------------
  real(ESMF_KIND_R8), parameter, public :: PI      = 3.14159265358979323846_ESMF_KIND_R8 !< π
  real(ESMF_KIND_R8), parameter, public :: RAD2DEG = 57.29577951308232_ESMF_KIND_R8 !< radianos para graus
  real(ESMF_KIND_R8), parameter, public :: FILL_VALUE_R8 = -9.99e+20_ESMF_KIND_R8   !< _FillValue das saídas NetCDF

  !--------------------------------------------------------------------------
  ! Gelo marinho
  !--------------------------------------------------------------------------
  !> Decaimento horário da fração de gelo retida do OISST (≈ exp(-1/24), τ ≈ 24 h)
  real(ESMF_KIND_R8), parameter, public :: SI_IFRAC_DECAY = 0.95924_ESMF_KIND_R8
  !> Faixa de temperatura válida do gelo [K]: abaixo do mínimo ou acima do
  !! máximo, o valor recebido é tratado como ausente.
  real(ESMF_KIND_R8), parameter, public :: T_ICE_MIN = 180.0_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter, public :: T_ICE_MAX = 273.16_ESMF_KIND_R8

  !--------------------------------------------------------------------------
  ! Albedos padrão (valores de partida e de preenchimento)
  !--------------------------------------------------------------------------
  real(ESMF_KIND_R8), parameter, public :: ALB_OCEAN_DEFAULT = 0.08_ESMF_KIND_R8 !< água aberta
  real(ESMF_KIND_R8), parameter, public :: ALB_ICE_DEFAULT   = 0.65_ESMF_KIND_R8 !< gelo

  ! Pendências (valores próximos, mas não iguais; unificar muda resultados):
  !   - π: med_bulk_ncar usa 3.14159265358979 (15 algarismos) no ângulo zenital,
  !     e mpas_cap_methods faz o mesmo em MPAS_RKIND; PI acima é o π completo.
  !   - Constantes em MPAS_RKIND (pressão de vapor, eps, 0 °C e 271,35 K em
  !     mpas_atm_fluxes e mpas_cap_methods; albedo 0,08 em mpas_cap_methods e
  !     mpas_atm_setup) ficam onde estão: o kind é o do MPAS, que só coincide
  !     com ESMF_KIND_R8 quando o MPAS é compilado em precisão dupla.

end module coupler_constants_mod
