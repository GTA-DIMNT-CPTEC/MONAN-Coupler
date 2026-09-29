!> @file med_cap_types.F90
!! @brief Tipos derivados, constantes físicas e listas de campos do mediador NUOPC.
!!
!! Contém as definições compartilhadas entre os módulos do mediador:
!!   MED_InternalState, MED_InternalStateWrapper — estado interno ESMF,
!!   agrupado nos subtipos med_ocn_flux_fields_t, med_ocn_fields_t,
!!   med_ice_fields_t, med_sfc_fields_t, med_par_t e med_diag_config_t
!!   Constantes físicas Large & Yeager (2009) — usadas pelo bulk NCAR
!!   Listas de campos import/export — usadas em Advertise e Advance
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

  implicit none
  private

  public :: MED_InternalState, MED_InternalStateWrapper
  public :: med_ocn_flux_fields_t, med_ocn_fields_t, med_ice_fields_t, med_sfc_fields_t
  public :: med_par_t, med_diag_config_t, med_run_flags_t
  ! Constantes físicas de coupler_constants_mod, re-exportadas
  public :: rho_air, Cp_air, L_evap, T_freeze, eps_q
  public :: es_coef_a, es_coef_b, es_coef_c, sigma_sb
  ! Parâmetros do bulk e do balanço radiativo
  public :: Cd_neut, Ch_neut, Ce_neut, albedo_ocn
  public :: SST_BULK_FALLBACK, SHUM_OCEAN_DEFAULT
  public :: f_vis_dir, f_vis_dif, f_nir_dir, f_nir_dif
  ! Listas de campos
  public :: n_import_mpas, import_mpas_names
  public :: n_import_datm, import_datm_names
  public :: n_export, export_names

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
  ! Estado interno do mediador, agrupado por assunto
  !
  ! Todos os campos ESMF abaixo estão na grade ATM regular 360×180 do
  ! mediador (is%atm_grid).
  !----------------------------------------------------------------------------

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
    !> primeira gravação de mom6_import_*.nc (registro da fatia de cada PET)
    logical :: first_import_write = .true.
  end type med_run_flags_t

  type :: MED_InternalState

    type(ESMF_Grid) :: atm_grid   !< Grade ATM regular 360×180 para cálculo do bulk
    type(ESMF_Grid) :: ocn_grid   !< Grade OCN para campos exportados ao oceano

    type(med_ocn_flux_fields_t) :: ocn_flx   !< enviados ao oceano
    type(med_ocn_fields_t)      :: ocn       !< estado do oceano
    type(med_ice_fields_t)      :: ice       !< gelo marinho
    type(med_sfc_fields_t)      :: sfc       !< superfície para a atmosfera

    !> Rotas de interpolação do mediador (ver src/regrid):
    !!   atm2ocn          ATM -> OCN, vizinho mais próximo (fluxos exportados)
    !!   ocn2atm          OCN -> ATM, bilinear (So_t inicial, correntes, reserva)
    !!   ocn2atm_sst      OCN -> ATM, conservativo mascarado (So_t)
    !!   ocn2atm_ice      OCN -> ATM, conservativo mascarado (campos do SIS2)
    !!   ocn2atm_landmask OCN -> ATM, vizinho mais próximo (So_omask)
    !!   atm2ocn_ice      ATM -> OCN, conservativo (Si_ifrac exportado)
    !! Cada rota pode ser trocada em nuopc.input, grupo &nuopc_regrid.
    type(regrid_manager_t) :: regrid

    logical :: use_mpas_atm     = .false.   !< .true. = MPAS, .false. = DATM (de use_datm)
    logical :: use_med_to_mpas  = .false.   !< cópia de cfg_use_med_to_mpas

    type(med_par_t)         :: par    !< comunicador e PETs
    type(med_diag_config_t) :: diag   !< diagnóstico de importação
    type(med_run_flags_t)   :: run    !< marcas de primeira vez e contadores

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
  !! is%ocn%omask). Tem StandardName proprio, como o Sx_tsfc: e' um campo
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

end module med_cap_types_mod
