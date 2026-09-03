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
  !real(ESMF_KIND_R8), parameter :: albedo_ocn = 0.26_ESMF_KIND_R8    !< Albedo médio do oceano
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

    !> Fase 4b (B-TSFC-DUALEXPORT-01, Set/2026): So_t exportado ao SIS2 e ao
    !! MOM6-side deve permanecer SST PURA (o SIS2 precisa da temperatura real
    !! do oceano sob o gelo para o fluxo de calor basal, ICE_KMELT — misturar
    !! com Si_t_sis2 ali seria circular/errado). A temperatura de pele
    !! COMPOSTA (blend por Si_ifrac com Si_t_sis2), util so' para a
    !! atmosfera (radiacao/camada limite sobre a celula mista), vai por um
    !! StandardName SEPARADO, "Sx_tsfc" — ver MED_cap.F90 e
    !! mpas_cap_MONAN.F90. f_sst_atm permanece intocado (SST pura).
    type(ESMF_Field) :: f_tsfc_atm
    !> Correntes oceânicas interpoladas para a grade ATM (BUG-CALC-DUU fix v13.0).
    !! Necessárias para So_duu10n = |(V_atm − V_ocn)|² (protocolo CMEPS).
    type(ESMF_Field) :: f_uocn_atm   !< So_u interpolado OCN → ATM [m/s]
    type(ESMF_Field) :: f_vocn_atm   !< So_v interpolado OCN → ATM [m/s]
    !> Rugosidade superficial via Charnock + Smith (Sprint C, Maio 2026).
    !! Calculada no MED a partir de Foxx_taux/tauy; exportada como Sf_zorl → MPAS.
    type(ESMF_Field) :: f_zorl_atm   !< Sf_zorl rugosidade Charnock [m]
    !> Fase 2.5 (B-ZENITH-01): angulo zenital solar, calculado no bulk NCAR
    !! a partir de lat/lon/clock; exportado como Faxa_coszen -> SIS2
    !! (is%aib%coszen, antes zerado — ver sis_cap_MONAN.F90::import_forcing).
    type(ESMF_Field) :: f_coszen_atm !< Faxa_coszen — cos(ângulo zenital solar) [nondim]
    !> Fase 2.6 (B-ALBEDO-FEEDBACK-01): albedo de banda larga efetivo
    !! (água aberta dinâmica + gelo real, ponderado por f_vis_dir/f_vis_dif/
    !! f_nir_dir/f_nir_dif), exportado como Sf_albedo -> MONAN-A.
    type(ESMF_Field) :: f_albedo_atm

    !> Fase 3 (B-ICE-FLUX-DIFF-01): temperatura de pele real do gelo
    !! (Si_t_sis2, regrid via rh_ocn2atm) e o segundo conjunto de fluxos
    !! turbulentos calculado a partir dela — Fioi_* — em vez de reusar
    !! Foxx_* (calculado com SST) para o SIS2, como acontecia antes.
    type(ESMF_Field) :: f_tice_atm
    type(ESMF_Field) :: f_taux_ice, f_tauy_ice, f_sen_ice, f_evap_ice, f_lwnet_ice

    !> Fase 4 (B-ICE-SWNET-01, Set/2026): fluxo liquido de onda curta
    !! ESPECIFICO do gelo, calculado com o albedo REAL do gelo por banda
    !! (is%f_alb_*_ice), sem misturar com o albedo de agua aberta. Antes
    !! desta correcao, o SIS2 recebia Foxx_swnet_* — o MESMO valor enviado
    !! ao MOM6, calculado com um albedo MEDIO da celula (agua+gelo
    !! ponderados por Si_ifrac). Isso fazia o gelo absorver SW calculada
    !! com um albedo mais BAIXO que o seu proprio (ex.: ifrac=0,5, albedo
    !! gelo~0,7, albedo agua~0,06 -> albedo medio~0,38 -> gelo absorve
    !! ~62% de swdn em vez dos ~30% fisicamente corretos). Ver
    !! med_bulk_ncar.F90 para o calculo; Foxx_swnet_* passa a usar SOMENTE
    !! o albedo de agua aberta (sem blend), simetrico a esta correcao.
    type(ESMF_Field) :: f_swvdr_ice, f_swvdf_ice, f_swidr_ice, f_swidf_ice

    ! RouteHandles
    type(ESMF_RouteHandle) :: rh_atm2ocn      !< ATM → OCN
    type(ESMF_RouteHandle) :: rh_ocn2atm      !< OCN → ATM bilinear — So_t, So_u, So_v
    !> Regrid bilinear OCN→ATM ciente de máscara dedicado a So_t (v4.18).
    !! Máscara pelo fill MOM6 (~200 K); bordas por extrapolação de vizinhança.
    type(ESMF_RouteHandle) :: rh_ocn2atm_sst
    logical :: rh_sst_masked = .false.
    !> FIX B-ICEREGRID-01 (Set/2026): regrid bilinear OCN(SIS2)→ATM ciente
    !! de máscara (So_omask), dedicado aos campos do gelo (Si_ifrac_sis2,
    !! Si_avsdr/vdf/idr/idf, Si_t_sis2). Antes, esses campos usavam o
    !! rh_ocn2atm generico (sem máscara nem extrapolação de vizinhança) —
    !! mesma classe de problema que motivou o rh_ocn2atm_sst acima, so' que
    !! sem correção: pior aqui, pois gelo se concentra justamente na região
    !! de deformação da malha tripolar (alta latitude), onde o rh_ocn2atm_sst
    !! ja' provou ser necessário mesmo para SST (campo global, onde o mesmo
    !! artefato fica diluído no resto do domínio).
    type(ESMF_RouteHandle) :: rh_ocn2atm_ice
    logical :: rh_ice_masked = .false.

    !> FIX B-LANDMASK-01 (Set/2026): mascara terra/oceano REAL (So_omask),
    !! regridada uma unica vez de ocn_grid para atm_grid. Substitui a
    !! heuristica "SST~=271,35K = terra" (Sprint A.5.1/A.5.2), que colide
    !! numericamente com agua aberta genuina no ponto de congelamento
    !! (justamente a borda do gelo marinho). Metodo NEAREST_STOD (nao
    !! precisa de precisao subcelular, so' discriminar terra/oceano).
    type(ESMF_Field)       :: f_omask_atm
    type(ESMF_RouteHandle) :: rh_ocn2atm_landmask
    logical :: rh_landmask_created = .false.

    !> FIX B-CONSERVE-03 (Set/2026): RouteHandle DEDICADO ATM->OCN para a
    !! perna de exportacao de Si_ifrac (B-ICEREGRID-04) usando CONSERVE.
    !! Nao reusa rh_atm2ocn (compartilhado com Foxx_taux/tauy/sen/... via
    !! NEAREST_STOD) para nao alterar o metodo de regrid desses outros
    !! campos, que nunca foi pedido nem validado para CONSERVE.
    type(ESMF_RouteHandle) :: rh_atm2ocn_ice
    logical :: rh_atm2ocn_ice_created = .false.
    !> Sprint B.2 (Set/2026) — ENTREGUE. Si_ifrac_sis2 (e agora os 4 campos
    !! de albedo do gelo, Fase 2) sao realizados pelo MED na MESMA ocn_grid
    !! usada por So_t (ver InitializeRealize: "geometricamente equivalente
    !! a ocn_grid" — mesma ocean_hgrid.nc). Por isso NAO precisam de um
    !! RouteHandle proprio: o rh_ocn2atm ja existente (linha ~1130) e'
    !! reutilizado, exatamente como ja e' feito para So_u/So_v. O slot
    !! antes reservado como "rh_ifrac_ocn2atm" (Sprint E) fica sem uso —
    !! a premissa de que precisaria de uma grade ICE dedicada nao se
    !! confirmou; o bloqueio real era a fisica do SIS2 (ver
    !! FIX B-ICE-FASTSYNC-01/02 em sis_cap_MONAN.F90), nao a geometria.

    !> Fase 2 (B-ICE-ALBEDO-01) — albedo do gelo por banda, regridado do
    !! SIS2 (ocn_grid, ver acima) para a grade ATM via rh_ocn2atm. Usado em
    !! med_bulk_ncar.F90 para substituir a constante albedo_ocn nas células
    !! com cobertura de gelo (ponderado por f_ifrac_atm).
    type(ESMF_Field) :: f_alb_vdr_ice   !< Si_avsdr_sis2 regridado [visível direto]
    type(ESMF_Field) :: f_alb_vdf_ice   !< Si_avsdf_sis2 regridado [visível difuso]
    type(ESMF_Field) :: f_alb_idr_ice   !< Si_anidr_sis2 regridado [NIR direto]
    type(ESMF_Field) :: f_alb_idf_ice   !< Si_anidf_sis2 regridado [NIR difuso]

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

  !> Campos de export para OCN (14 fluxos bulk) + 4 campos OCN→MPAS dinâmicos.
  !! Sprint A (Mai/2026): +So_t; Sprint B: +So_u, So_v; Sprint C: +Sf_zorl.
  !! Fase 2.5 (B-ZENITH-01): +Faxa_coszen — angulo zenital solar real p/ SIS2
  !! (antes zerado em is%aib%coszen, ver sis_cap_MONAN.F90::import_forcing).
  !! FIX B-DIAGMASK-01 (Set/2026): +Sx_omask — mascara terra/oceano REAL do
  !! MOM6 (ocean_grid%mask2dT, importada como So_omask e regridada para a
  !! grade ATM em is%f_omask_atm pelo B-LANDMASK-01). Exportada sob um
  !! StandardName NOVO, no mesmo espirito do Sx_tsfc: e' um campo produzido
  !! pelo MED para consumo do lado atmosferico/diagnostico, e nao o campo
  !! So_omask original do oceano — reusar o mesmo nome no exportState
  !! criaria um par import/export homonimo no mesmo componente. Serve a dois
  !! consumidores: (a) a variavel de mascara gravada em mom6_import_*.nc
  !! (med_cap_netcdf.F90) e (b) o cap do MPAS, que a recebe pelo conector
  !! MED->MPAS e mascara os continentes em monan2_import_*.nc.
  integer, parameter :: n_export = 31
  character(len=32), parameter :: export_names(n_export) = [ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", "Foxx_lwnet    ", &
    "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", "Foxx_swnet_idf", &
    "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", "Si_ifrac      ", "So_duu10n     ", &
    "So_t          ",                                                                          &
    "So_u          ", "So_v          ",  &   ! Sprint B
    "Sf_zorl       ", &                      ! Sprint C — rugosidade Charnock → MPAS
    "Faxa_coszen   ", &                      ! Fase 2.5 — angulo zenital solar → SIS2
    "Sf_albedo     ", &                      ! Fase 2.6 — albedo de banda larga → MPAS
    "Fioi_taux     ", "Fioi_tauy     ", "Fioi_sen      ", "Fioi_evap     ", &  ! Fase 3
    "Fioi_lwnet    ", &                      ! Fase 3 — fluxos calc. c/ T_gelo → SIS2
    "Fioi_swnet_vdr", "Fioi_swnet_vdf", "Fioi_swnet_idr", "Fioi_swnet_idf", & ! Fase 4 — B-ICE-SWNET-01
    "Sx_tsfc       ", &                     ! Fase 4b — B-TSFC-DUALEXPORT-01 — composto p/ MPAS-A
    "Sx_omask      " ]                      ! B-DIAGMASK-01 — mascara terra/oceano MOM6 → diag + MPAS

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
