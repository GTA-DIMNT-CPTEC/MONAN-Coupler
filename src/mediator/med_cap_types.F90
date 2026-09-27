!> @file med_cap_types.F90
!! @brief Tipos derivados, constantes físicas e listas de campos do mediador NUOPC.
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
  use coupler_constants_mod, only : rho_air, Cp_air, L_evap, T_freeze => T0_KELVIN, eps_q, es_coef_a, es_coef_b, es_coef_c, sigma_sb
  use regrid_manager_mod, only : regrid_manager_t

  implicit none
  public

  character(len=*), parameter :: u_FILE_u = __FILE__

  !----------------------------------------------------------------------------
  ! Parâmetros do bulk e do balanço radiativo do mediador (Large & Yeager 2009).
  ! As constantes físicas vêm de coupler_constants_mod e são re-exportadas aqui.
  !----------------------------------------------------------------------------
  real(ESMF_KIND_R8), parameter :: Cd_neut    = 1.3e-3_ESMF_KIND_R8  !< Coef. arrasto neutro
  real(ESMF_KIND_R8), parameter :: Ch_neut    = 1.0e-3_ESMF_KIND_R8  !< Coef. calor sensível
  real(ESMF_KIND_R8), parameter :: Ce_neut    = 1.15e-3_ESMF_KIND_R8 !< Coef. calor latente
  real(ESMF_KIND_R8), parameter :: albedo_ocn = 0.06_ESMF_KIND_R8    !< Albedo médio do oceano
  !real(ESMF_KIND_R8), parameter :: albedo_ocn = 0.26_ESMF_KIND_R8    !< Albedo médio do oceano
  !> SST de segurança para bulk quando o valor recebido está fora de [271, 308] K.
  !! NÃO é fonte de dado — guard para evitar instabilidade numérica.
  real(ESMF_KIND_R8), parameter :: SST_BULK_FALLBACK = 290.0_ESMF_KIND_R8
  !> Umidade específica padrão ~80% UR a 290 K (Sa_shum_mpas ausente).
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

    !> Temperatura de superficie COMPOSTA (Si_ifrac pondera SST e Si_t_sis2),
    !! util so' para a atmosfera (radiacao e camada limite sobre a celula
    !! mista), exportada como "Sx_tsfc" (ver MED_cap.F90 e mpas_cap_MONAN.F90).
    !! So_t, exportado ao SIS2 e ao MOM6, permanece SST PURA: o SIS2 precisa da
    !! temperatura real do oceano sob o gelo para o fluxo de calor basal
    !! (ICE_KMELT), e misturar Si_t_sis2 ali seria circular. f_sst_atm nunca
    !! e' sobrescrito.
    type(ESMF_Field) :: f_tsfc_atm
    !> Correntes oceânicas interpoladas para a grade ATM.
    !! Necessárias para So_duu10n = |(V_atm − V_ocn)|² (protocolo CMEPS).
    type(ESMF_Field) :: f_uocn_atm   !< So_u interpolado OCN → ATM [m/s]
    type(ESMF_Field) :: f_vocn_atm   !< So_v interpolado OCN → ATM [m/s]
    !> Rugosidade superficial via Charnock + Smith.
    !! Calculada no MED a partir de Foxx_taux/tauy; exportada como Sf_zorl → MPAS.
    type(ESMF_Field) :: f_zorl_atm   !< Sf_zorl rugosidade Charnock [m]
    !> Angulo zenital solar, calculado no bulk NCAR a partir de lat/lon/clock;
    !! exportado como Faxa_coszen -> SIS2 (is%aib%coszen, ver
    !! sis_cap_MONAN.F90::import_forcing).
    type(ESMF_Field) :: f_coszen_atm !< Faxa_coszen — cos(ângulo zenital solar) [nondim]
    !> Albedo de banda larga efetivo
    !! (água aberta dinâmica + gelo real, ponderado por f_vis_dir/f_vis_dif/
    !! f_nir_dir/f_nir_dif), exportado como Sf_albedo -> MONAN-A.
    type(ESMF_Field) :: f_albedo_atm

    !> Temperatura de pele real do gelo (Si_t_sis2, pela rota 'ocn2atm_ice')
    !! e o segundo conjunto de fluxos turbulentos calculado a partir dela,
    !! Fioi_*, enviado ao SIS2 no lugar dos Foxx_* (calculados com a SST).
    type(ESMF_Field) :: f_tice_atm
    type(ESMF_Field) :: f_taux_ice, f_tauy_ice, f_sen_ice, f_evap_ice, f_lwnet_ice

    !> Fluxo liquido de onda curta ESPECIFICO do gelo, calculado com o albedo
    !! REAL do gelo por banda (is%f_alb_*_ice), sem misturar com o albedo de
    !! agua aberta. Se o SIS2 recebesse Foxx_swnet_*, calculado com um albedo
    !! MEDIO da celula (agua e gelo ponderados por Si_ifrac), o gelo absorveria
    !! SW com um albedo mais BAIXO que o seu proprio (ex.: ifrac=0,5, albedo
    !! gelo~0,7, albedo agua~0,06 -> albedo medio~0,38 -> gelo absorve ~62%
    !! de swdn em vez dos ~30% fisicamente corretos). Ver med_bulk_ncar.F90
    !! para o calculo; Foxx_swnet_* usa SOMENTE o albedo de agua aberta.
    type(ESMF_Field) :: f_swvdr_ice, f_swvdf_ice, f_swidr_ice, f_swidf_ice

    ! RouteHandles
    !> Rotas de interpolação do mediador (ver src/regrid):
    !!   atm2ocn          ATM -> OCN, vizinho mais próximo (fluxos exportados)
    !!   ocn2atm          OCN -> ATM, bilinear (So_t inicial, correntes, reserva)
    !!   ocn2atm_sst      OCN -> ATM, conservativo mascarado (So_t)
    !!   ocn2atm_ice      OCN -> ATM, conservativo mascarado (campos do SIS2)
    !!   ocn2atm_landmask OCN -> ATM, vizinho mais próximo (So_omask)
    !!   atm2ocn_ice      ATM -> OCN, conservativo (Si_ifrac exportado)
    !! Cada rota pode ser trocada em nuopc.input, grupo &nuopc_regrid.
    type(regrid_manager_t) :: regrid

    !> Máscara terra/oceano real (So_omask) na grade ATM, obtida uma vez.
    type(ESMF_Field) :: f_omask_atm
    logical          :: landmask_done = .false.   !< regrid da máscara já tentado
    !! Si_ifrac_sis2 e os 4 albedos do gelo sao realizados pelo MED na MESMA
    !! ocn_grid de So_t (a grade do ICE usa a mesma ocean_hgrid.nc), e nao
    !! precisam de grade propria; a rota do gelo e' 'ocn2atm_ice'.

    !> Albedo do gelo por banda, interpolado do SIS2 (ocn_grid) para a grade
    !! ATM pela rota 'ocn2atm_ice'. Usado em med_bulk_ncar.F90 no lugar da
    !! constante albedo_ocn nas células com gelo (ponderado por f_ifrac_atm).
    type(ESMF_Field) :: f_alb_vdr_ice   !< Si_avsdr_sis2 regridado [visível direto]
    type(ESMF_Field) :: f_alb_vdf_ice   !< Si_avsdf_sis2 regridado [visível difuso]
    type(ESMF_Field) :: f_alb_idr_ice   !< Si_anidr_sis2 regridado [NIR direto]
    type(ESMF_Field) :: f_alb_idf_ice   !< Si_anidf_sis2 regridado [NIR difuso]

    real(ESMF_KIND_R8), allocatable :: ocn_mask_atm(:,:)  !< Máscara oceano/continente

    logical :: use_mpas_atm     = .false.   !< .true. = MPAS, .false. = DATM (de use_datm)
    logical :: use_med_to_mpas  = .false.   !< cópia de cfg_use_med_to_mpas

  end type MED_InternalState

  type :: MED_InternalStateWrapper
    type(MED_InternalState), pointer :: wrap => null()
  end type MED_InternalStateWrapper

  !----------------------------------------------------------------------------
  ! Listas de campos — usadas em InitializeAdvertise e MediatorAdvance
  !----------------------------------------------------------------------------

  !> Campos de import do MPAS (primário) — com sufixo _mpas.
  integer, parameter :: n_import_mpas = 13
  character(len=32), parameter :: import_mpas_names(n_import_mpas) = [ &
    "Sa_u10m_mpas  ", "Sa_v10m_mpas  ", "Sa_tbot_mpas  ", "Sa_pslv_mpas  ", &
    "Faxa_swdn_mpas", "Faxa_lwdn_mpas", "Faxa_rain_mpas", &
    "Sa_shum_mpas  ", "Faxa_snow_mpas", &
    "Faxa_sen_mpas ", "Faxa_lat_mpas ", "Faxa_taux_mpas", "Faxa_tauy_mpas" ]

  !> Campos de import do DATM (fallback) — sem sufixo.
  integer, parameter :: n_import_datm = 9
  character(len=32), parameter :: import_datm_names(n_import_datm) = [ &
    "Sa_u10m   ", "Sa_v10m   ", "Sa_tbot   ", "Sa_shum   ", "Sa_pslv   ", &
    "Faxa_swdn ", "Faxa_lwdn ", "Faxa_rain ", "Faxa_snow "]

  !> Campos de export: 14 fluxos e estados para o OCN e o ICE, So_t, So_u,
  !! So_v e Sf_zorl para o MPAS, Faxa_coszen (angulo zenital solar real,
  !! para is%aib%coszen do SIS2), Sf_albedo, os fluxos Fioi_* do gelo,
  !! Sx_tsfc e Sx_omask.
  !! Sx_omask e' a mascara terra/oceano REAL do MOM6 (ocean_grid%mask2dT,
  !! importada como So_omask e interpolada para a grade ATM em
  !! is%f_omask_atm). Tem StandardName proprio, como o Sx_tsfc: e' um campo
  !! produzido pelo MED para o lado atmosferico e o diagnostico, e reusar o
  !! nome So_omask no exportState criaria um par import/export homonimo no
  !! mesmo componente. Serve a dois consumidores: (a) a variavel de mascara
  !! gravada em mom6_import_*.nc (med_cap_netcdf.F90) e (b) o cap do MPAS,
  !! que a recebe pelo conector MED->MPAS e mascara os continentes em
  !! monan2_import_*.nc.
  integer, parameter :: n_export = 31
  character(len=32), parameter :: export_names(n_export) = [ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", "Foxx_lwnet    ", &
    "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", "Foxx_swnet_idf", &
    "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", "Si_ifrac      ", "So_duu10n     ", &
    "So_t          ",                                                                          &
    "So_u          ", "So_v          ",  &
    "Sf_zorl       ", &  ! rugosidade Charnock → MPAS
    "Faxa_coszen   ", &                      ! angulo zenital solar → SIS2
    "Sf_albedo     ", &                      ! albedo de banda larga → MPAS
    "Fioi_taux     ", "Fioi_tauy     ", "Fioi_sen      ", "Fioi_evap     ", &  ! fluxos do gelo
    "Fioi_lwnet    ", &                      ! fluxos calc. c/ T_gelo → SIS2
    "Fioi_swnet_vdr", "Fioi_swnet_vdf", "Fioi_swnet_idr", "Fioi_swnet_idf", &  ! onda curta do gelo
    "Sx_tsfc       ", &  ! composto p/ MPAS-A
    "Sx_omask      " ]  ! mascara terra/oceano MOM6 → diag + MPAS

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
