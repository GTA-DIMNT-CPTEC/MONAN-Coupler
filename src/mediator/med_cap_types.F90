!> @file med_cap_types.F90
!! @brief Tipos derivados, constantes físicas e listas de campos do mediador NUOPC.
!!
!! Versão 1.0 (Mai/2026) — GT Acoplamento de Modelos / INPE/CGCT/DIMNT
!!
!! Contém as definições compartilhadas entre os módulos do mediador:
!!   MED_InternalState, MED_InternalStateWrapper — estado interno ESMF
!!   Constantes físicas Large & Yeager (2009) — usadas pelo bulk NCAR
!!   Listas de campos import/export — usadas em Advertise e Advance
!!   Variáveis de módulo para diagnóstico NetCDF (save, persistem entre chamadas)
!!
!! Todos os outros módulos do mediador devem usar este como base:
!!   use med_cap_types_mod, only: MED_InternalState, rho_air, ...

module med_cap_types_mod

  use ESMF

  implicit none
  public

  character(len=*), parameter :: u_FILE_u = __FILE__

  !----------------------------------------------------------------------------
  ! Constantes físicas (Large & Yeager 2009)
  !----------------------------------------------------------------------------
  real(ESMF_KIND_R8), parameter :: rho_air    = 1.225_ESMF_KIND_R8   !< Densidade do ar [kg/m³]
  real(ESMF_KIND_R8), parameter :: Cd_neut    = 1.3e-3_ESMF_KIND_R8  !< Coef. arrasto neutro
  real(ESMF_KIND_R8), parameter :: Ch_neut    = 1.0e-3_ESMF_KIND_R8  !< Coef. calor sensível
  real(ESMF_KIND_R8), parameter :: Ce_neut    = 1.15e-3_ESMF_KIND_R8 !< Coef. calor latente
  real(ESMF_KIND_R8), parameter :: Cp_air     = 1004.67_ESMF_KIND_R8 !< Calor específico do ar [J/kg/K]
  real(ESMF_KIND_R8), parameter :: L_evap     = 2.501e6_ESMF_KIND_R8 !< Calor latente de evaporação [J/kg]
  real(ESMF_KIND_R8), parameter :: T_freeze   = 273.15_ESMF_KIND_R8  !< 0 °C em Kelvin
  real(ESMF_KIND_R8), parameter :: eps_q      = 0.622_ESMF_KIND_R8   !< Razão molar água/ar seco
  real(ESMF_KIND_R8), parameter :: es_coef_a  = 611.2_ESMF_KIND_R8   !< Coef. Clausius-Clapeyron [Pa]
  real(ESMF_KIND_R8), parameter :: es_coef_b  = 17.67_ESMF_KIND_R8   !< Coef. Clausius-Clapeyron
  real(ESMF_KIND_R8), parameter :: es_coef_c  = 243.5_ESMF_KIND_R8   !< Coef. Clausius-Clapeyron [°C]
  real(ESMF_KIND_R8), parameter :: sigma_sb   = 5.67e-8_ESMF_KIND_R8 !< Constante de Stefan-Boltzmann
  real(ESMF_KIND_R8), parameter :: albedo_ocn = 0.06_ESMF_KIND_R8    !< Albedo médio do oceano
  !> SST de segurança para bulk quando o valor recebido está fora de [271, 308] K.
  !! NÃO é fonte de dado — guard para evitar instabilidade numérica.
  real(ESMF_KIND_R8), parameter :: SST_BULK_FALLBACK = 290.0_ESMF_KIND_R8
  !> Umidade específica padrão ~80% UR a 290 K (Fase 2: Sa_shum_mpas ausente).
  real(ESMF_KIND_R8), parameter :: SHUM_OCEAN_DEFAULT = 0.010_ESMF_KIND_R8
  !> Partição espectral da onda curta incidente (Briegleb 1992; Large & Yeager 2009, eq. 5).
  !! Soma = 1.000 (fechamento radiativo).
  real(ESMF_KIND_R8), parameter :: f_vis_dir = 0.285_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: f_vis_dif = 0.215_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: f_nir_dir = 0.285_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: f_nir_dif = 0.215_ESMF_KIND_R8

  !----------------------------------------------------------------------------
  ! Estado interno do mediador
  !----------------------------------------------------------------------------
  type :: MED_InternalState

    type(ESMF_Grid) :: atm_grid   !< Grade ATM regular 640×320 para cálculo do bulk
    type(ESMF_Grid) :: ocn_grid   !< Grade OCN para campos exportados ao oceano

    ! Campos internos na grade ATM
    type(ESMF_Field) :: f_taux_atm, f_tauy_atm, f_sen_atm, f_evap_atm
    type(ESMF_Field) :: f_lwnet_atm, f_swvdr_atm, f_swvdf_atm
    type(ESMF_Field) :: f_swidr_atm, f_swidf_atm
    type(ESMF_Field) :: f_rain_atm, f_snow_atm, f_pslv_atm
    type(ESMF_Field) :: f_ifrac_atm, f_duu10n_atm, f_sst_atm
    !> Correntes oceânicas interpoladas para a grade ATM (BUG-CALC-DUU fix v13.0).
    !! Necessárias para So_duu10n = |(V_atm − V_ocn)|² (protocolo CMEPS).
    type(ESMF_Field) :: f_uocn_atm   !< So_u interpolado OCN → ATM [m/s]
    type(ESMF_Field) :: f_vocn_atm   !< So_v interpolado OCN → ATM [m/s]
    !> Rugosidade superficial via Charnock + Smith (Sprint C, Maio 2026).
    !! Calculada no MED a partir de Foxx_taux/tauy; exportada como Sf_zorl → MPAS.
    type(ESMF_Field) :: f_zorl_atm   !< Sf_zorl rugosidade Charnock [m]

    ! RouteHandles
    type(ESMF_RouteHandle) :: rh_atm2ocn      !< ATM → OCN
    type(ESMF_RouteHandle) :: rh_ocn2atm      !< OCN → ATM bilinear — So_t, So_u, So_v
    !> Regrid bilinear OCN→ATM ciente de máscara dedicado a So_t (v4.18).
    !! Máscara pelo fill MOM6 (~200 K); bordas por extrapolação de vizinhança.
    type(ESMF_RouteHandle) :: rh_ocn2atm_sst
    logical :: rh_sst_masked = .false.
    !> Sprint B.2 (Mai/2026) — reservado para regrid Si_ifrac OCN→ATM.
    !! Não utilizado na implementação atual (sigmoide calculada localmente
    !! no MED a partir de is%f_sst_atm). Preservado para Sprint E, quando
    !! Si_ifrac do SIS2 for exposto via cap NUOPC dedicado em ESMF_GEOMTYPE_MESH.
    type(ESMF_RouteHandle) :: rh_ifrac_ocn2atm
    logical :: rh_ifrac_created = .false.   !< reservado; sempre .false. até Sprint E

    real(ESMF_KIND_R8), allocatable :: ocn_mask_atm(:,:)  !< Máscara oceano/continente

    logical :: rh_created       = .false.
    logical :: use_mpas_atm     = .false.   !< Controlado por atributo NUOPC "use_mpas_atm"
    logical :: use_med_to_mpas  = .false.   !< Controlado por atributo NUOPC "use_med_to_mpas"

  end type MED_InternalState

  type :: MED_InternalStateWrapper
    type(MED_InternalState), pointer :: wrap => null()
  end type MED_InternalStateWrapper

  !----------------------------------------------------------------------------
  ! Listas de campos — usadas em InitializeAdvertise e MediatorAdvance
  !----------------------------------------------------------------------------

  !> Campos de import do MPAS (primário) — com sufixo _mpas.
  integer, parameter :: n_import_mpas = 9
  character(len=32), parameter :: import_mpas_names(n_import_mpas) = [ &
    "Sa_u10m_mpas  ", "Sa_v10m_mpas  ", "Sa_tbot_mpas  ", "Sa_pslv_mpas  ", &
    "Faxa_swdn_mpas", "Faxa_lwdn_mpas", "Faxa_rain_mpas", &
    "Sa_shum_mpas  ", "Faxa_snow_mpas" ]

  !> Campos de import do DATM (fallback) — sem sufixo.
  integer, parameter :: n_import_datm = 9
  character(len=32), parameter :: import_datm_names(n_import_datm) = [ &
    "Sa_u10m   ", "Sa_v10m   ", "Sa_tbot   ", "Sa_shum   ", "Sa_pslv   ", &
    "Faxa_swdn ", "Faxa_lwdn ", "Faxa_rain ", "Faxa_snow "]

  !> Campos de export para OCN (14 fluxos bulk) + 4 campos OCN→MPAS dinâmicos.
  !! Sprint A (Mai/2026): +So_t; Sprint B: +So_u, So_v; Sprint C: +Sf_zorl.
  integer, parameter :: n_export = 18
  character(len=32), parameter :: export_names(n_export) = [ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", "Foxx_lwnet    ", &
    "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", "Foxx_swnet_idf", &
    "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", "Si_ifrac      ", "So_duu10n     ", &
    "So_t          ",                                                                          &
    "So_u          ", "So_v          ",  &   ! Sprint B
    "Sf_zorl       " ]                        ! Sprint C — rugosidade Charnock → MPAS

  !----------------------------------------------------------------------------
  ! Variáveis de módulo para diagnóstico de importação NetCDF (save)
  ! Inicializadas em med_read_import_config e usadas em med_write_import_fields.
  !----------------------------------------------------------------------------
  logical,            save :: med_write_import_diag = .false.
  character(len=256), save :: med_import_diag_dir   = 'diag_import'
  integer,            save :: med_mpi_comm  = -1   !< Comunicador MPI do mediador
  integer,            save :: med_local_pet = -1   !< PET local
  integer,            save :: med_pet_count = -1   !< Número de PETs

end module med_cap_types_mod
