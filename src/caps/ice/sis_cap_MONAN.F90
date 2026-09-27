!> @file sis_cap_MONAN.F90
!! @brief Cap NUOPC do SIS2 (gelo marinho dinâmico).
!!
!! Componente NUOPC próprio para o SIS2, com PETs separados dos do MOM6. O cap
!! chama o SIS2 diretamente (ice_model_mod), sem o combined_ice_ocean_driver:
!! esse driver espera o ocean_state_type do cap FMS do MOM6, um tipo opaco
!! incompatível com o do cap NUOPC que mom_cap_MONAN.F90 usa. O SIS2 só
!! precisa das estruturas de troca ocean_ice_boundary_type e
!! atmos_ice_boundary_type, que são arrays simples. Os dados com o mediador
!! passam por campos ESMF, como nos caps do oceano e da atmosfera.
!!
!! Por passo de acoplamento (ModelAdvance):
!!   1. lê os campos importados do mediador (forçantes da atmosfera, SST e
!!      correntes) para atmos_ice_boundary_type e ocean_ice_boundary_type;
!!   2. update_ice_model_fast, termodinâmica lenta e dinâmica do gelo;
!!   3. exporta para o mediador a fração, os albedos e a temperatura de pele
!!      do gelo.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module sis_cap_MONAN_mod

  use ESMF
  use NUOPC,       only : NUOPC_CompDerive,        NUOPC_CompSpecialize,   &
                           NUOPC_CompSetEntryPoint, NUOPC_CompAttributeGet, &
                           NUOPC_Advertise,         NUOPC_Realize,          &
                           NUOPC_CompAttributeSet,  NUOPC_IsUpdated,        &
                           NUOPC_CompFilterPhaseMap
  ! model_label_CheckImport: o CheckImport tolerante (CheckImportTolerant)
  ! aceita campos com carimbo de tempo ligeiramente diferente, porque o
  ! SIS2/FMS tem seu próprio gerenciador de tempo (como no cap do oceano).
  use NUOPC_Model, only : model_routine_SS           => SetServices,          &
                           model_label_DataInitialize => label_DataInitialize, &
                           model_label_Advance        => label_Advance,        &
                           model_label_Finalize        => label_Finalize,       &
                           model_label_CheckImport    => label_CheckImport,    &
                           NUOPC_ModelGet

  use time_utils_mod, only : esmf2fms_time

  use mom6_supergrid_mod, only : mom6_supergrid_dims, mom6_supergrid_tcoords
  use coupler_constants_mod, only : TICE_FALLBACK => T_FREEZE_SEAWATER
  use coupler_config_mod, only : cfg_mom6_mesh_ocn, cfg_write_fixdiag

  ! API do SIS2: models/ocean/MOM6-examples/src/SIS2/src/{ice_model,
  ! ice_type,ice_boundary_types}.F90 (interfaces mínimas para compilar fora
  ! da Jaci em tests/interfaces/sis_stubs.F90).
  use ice_model_mod, only : ice_data_type, ice_model_init, ice_model_end,   &
                             share_ice_domains, ice_model_restart,          &
                             update_ice_slow_thermo, update_ice_dynamics_trans, &
                             unpack_ocean_ice_boundary, update_ice_model_fast, &
                             exchange_slow_to_fast_ice, &
                             set_ice_surface_fields,    &
                             ocean_ice_boundary_type, atmos_ice_boundary_type

  use MOM_time_manager, only : time_type, set_date, set_calendar_type, GREGORIAN
  use MOM_diag_manager_infra, only : diag_manager_set_time_end_infra

  use mpp_domains_mod, only : mpp_get_compute_domain
  use MOM_domains,     only : MOM_infra_init, AGRID

  use coupler_utils_mod, only : ChkErr


  implicit none
  private

  public :: SetServices

  ! ── Estado interno do componente de gelo ──────────────────────────────────
  type :: ice_internal_state_type
    type(ice_data_type)             :: ice
    type(ocean_ice_boundary_type)   :: oib   !< SST/correntes vindas do OCN (via MED)
    type(atmos_ice_boundary_type)   :: aib   !< Forçante vinda do ATM (via MED)
    type(ESMF_Grid)                 :: ice_grid
    integer                         :: isc, iec, jsc, jec  !< domínio computacional local
  end type ice_internal_state_type

  type :: ice_internal_state_wrapper
    type(ice_internal_state_type), pointer :: ptr => null()
  end type ice_internal_state_wrapper

  ! ── Nomes de campo trocados com o mediador ────────────────────────────────
  ! Os nomes seguem med_cap_types.F90::export_names. O conector "MED -> ICE"
  ! (registrado em esm.F90) casa por StandardName, então os campos que o MED
  ! exporta alimentam o ICE sem mudança em MED_cap.F90. Um nome que o MED
  ! não exporta produz "NUOPC INCOMPATIBILITY: Import Fields not all
  ! connected". lprec/fprec/p vêm de Faxa_rain/Faxa_snow/Sa_pslv.
  integer, parameter :: n_import_atm = 13  ! forçante atmosférica (ver AIB)
  integer, parameter :: n_import_ocn = 3   ! So_t, So_u, So_v (ver OIB)
  character(len=32), dimension(n_import_atm) :: import_names_atm = (/ &
    "Fioi_taux     ", "Fioi_tauy     ", "Fioi_sen      ", "Fioi_evap     ", &  ! fluxos turbulentos do gelo
    "Fioi_lwnet    ", "Fioi_swnet_vdr", "Fioi_swnet_vdf", "Fioi_swnet_idr", &  ! onda longa e onda curta do gelo
    "Fioi_swnet_idf", "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", &
    "Faxa_coszen   " /)  ! angulo zenital solar
  ! taux/tauy/sen/evap/lwnet vêm dos Fioi_* (calculados com a temperatura de
  ! pele real do gelo, Si_t_sis2 — ver export_si_tskin e med_bulk_ncar.F90),
  ! e não dos Foxx_* (calculados com a SST, apropriados para o MOM6). Da
  ! mesma forma, a onda curta vem de Fioi_swnet_*, calculada com o albedo do
  ! gelo por banda PURO; Foxx_swnet_* usa o albedo MISTURADO por Si_ifrac
  ! (o enviado ao MOM6), e o gelo absorveria SW calculada com um albedo mais
  ! baixo que o seu proprio.
  character(len=32), dimension(n_import_ocn) :: import_names_ocn = (/ &
    "So_t       ", "So_u       ", "So_v       " /)
  integer, parameter :: n_export = 6
  character(len=32), dimension(n_export) :: export_names = (/ &
    character(len=32) ::                &
    "Si_ifrac_sis2", &
    "Si_avsdr_sis2", &  ! albedo visivel direto (Ice%albedo_vis_dir)
    "Si_avsdf_sis2", &  ! albedo visivel difuso (Ice%albedo_vis_dif)
    "Si_anidr_sis2", &  ! albedo infravermelho prox. direto (Ice%albedo_nir_dir)
    "Si_anidf_sis2", &  ! albedo infravermelho prox. difuso (Ice%albedo_nir_dif)
    "Si_t_sis2"    /)  ! temperatura de pele do gelo (Ice%t_surf)

contains

  ! ============================================================================
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=InitializeP0, phase=0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Advance, &
      specRoutine=ModelAdvance, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! CheckImport tolerante: aceita campos com timestamp em ±dt_coupling, em
    ! vez do padrao estrito do NUOPC_ModelBase, que exige igualdade exata e
    ! falha ("NUOPC INCOMPATIBILITY: Import Fields not at current time")
    ! porque o SIS2/FMS usa seu proprio gerenciador de tempo, divergindo
    ! ligeiramente do relogio do driver ESMF. Mesma solução de
    ! mom_cap_MONAN.F90 para o mesmo problema entre MED e OCN.
    call ESMF_MethodRemove(gcomp, label=model_label_CheckImport, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_CheckImport, &
      specRoutine=CheckImportTolerant, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Finalize, &
      specRoutine=ModelFinalize, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

  end subroutine SetServices

  ! ============================================================================
  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS
    ! Seleciona a versão das fases de inicialização (IPDv03), como em
    ! mom_cap_MONAN.F90. Sem ela, a negociação de fases com o driver pode não
    ! corresponder ao que InitializeAdvertise/InitializeRealize abaixo
    ! registram (phaseLabelList=IPDv03p1/IPDv03p3).
    call NUOPC_CompFilterPhaseMap(gcomp, ESMF_METHOD_INITIALIZE, &
      acceptStringList=(/"IPDv03p"/), rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    ! SetClock NÃO é especializado. Uma especialização vazia bloquearia o
    ! comportamento PADRÃO do NUOPC_Model de sincronizar o relógio deste
    ! componente com o do driver, causando "NUOPC INCOMPATIBILITY: Import
    ! Fields not at current time" (o relógio do ICE nunca ficaria alinhado).
    ! Mesmo padrão de mom_cap_MONAN.F90, que também não especializa SetClock.
  end subroutine InitializeP0

  ! ============================================================================
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc
    integer :: n

    rc = ESMF_SUCCESS

    do n = 1, n_import_atm
      call NUOPC_Advertise(importState, StandardName=trim(import_names_atm(n)), &
        TransferOfferGeomObject="cannot provide", SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
    do n = 1, n_import_ocn
      call NUOPC_Advertise(importState, StandardName=trim(import_names_ocn(n)), &
        TransferOfferGeomObject="cannot provide", SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
    do n = 1, n_export
      ! O campo de export do ICE é realizado numa grade PRÓPRIA (is%ice_grid,
      ! criada em InitializeRealize) e oferece essa geometria ao conector como
      ! "will provide". Os imports usam "cannot provide", como o import do MED;
      ! se o export também usasse, nenhum lado ofereceria geometria e o conector
      ! travaria na inicialização ("Neither side able to provide geom object",
      ! fase IPDv05p3).
      ! Sem SharePolicyField="share" nesta EXPORTACAO, como no cap do OCN
      ! (mom_cap_MONAN.F90), que usa share apenas nas IMPORTACOES. Com share
      ! aqui, Si_ifrac saia correto (max=0.997) mas chegava zerado no mediador
      ! (min=max=0): o conector nao fazia a transferencia real.
      call NUOPC_Advertise(exportState, StandardName=trim(export_names(n)), &
        TransferOfferGeomObject="will provide", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    call ESMF_LogWrite('ICE(SIS2): InitializeAdvertise concluido', ESMF_LOGMSG_INFO)

  end subroutine InitializeAdvertise

  ! ============================================================================
  !> @brief Inicializa o SIS2, cria a grade ESMF do gelo e realiza os campos.
  !!
  !! Etapas: init_sis2 (FMS, calendário, tempos e ice_model_init),
  !! create_ice_grid (grade ESMF com a decomposição do próprio SIS2 e as
  !! coordenadas T do ocean_hgrid.nc), ice_category_count, realize_ice_fields
  !! e alloc_ice_boundaries (estruturas de troca com o SIS2). O gelo vive na
  !! mesma grade tripolar do MOM6.
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is
    type(ESMF_VM)        :: vm
    integer               :: petCount, localPet, ncat

    rc = ESMF_SUCCESS

    allocate(wrap%ptr)
    is => wrap%ptr

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call init_sis2(is, vm, clock, localPet, petCount, rc)
    if (rc /= ESMF_SUCCESS) return

    call create_ice_grid(is, vm, localPet, petCount, rc)
    if (rc /= ESMF_SUCCESS) return

    ncat = ice_category_count(is)
    call realize_ice_fields(is%ice_grid, importState, exportState, rc)
    if (rc /= ESMF_SUCCESS) return
    call alloc_ice_boundaries(is, ncat)

    call ESMF_GridCompSetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_LogWrite('ICE(SIS2): InitializeRealize concluido', ESMF_LOGMSG_INFO)

  end subroutine InitializeRealize

  ! ============================================================================
  !> @brief Inicializa o FMS e o SIS2 neste componente.
  !!
  !! A ordem importa:
  !!   1. MOM_infra_init com o comunicador MPI do próprio componente, antes de
  !!      qualquer chamada do FMS ligada a tempo. Assim o FMS numera os PETs
  !!      de 0 a petCount-1 dentro do componente, como ice_model_init e
  !!      share_ice_domains esperam. Um set_date antes disso inicializaria o
  !!      FMS implicitamente, numa operação coletiva fora de sincronia
  !!      (terminava em abort no mpp_init).
  !!   2. set_calendar_type(GREGORIAN) antes de qualquer set_date; sem
  !!      calendário, set_date para com erro fatal.
  !!   3. Listas de PETs e fast_ice_pe = slow_ice_pe = .true.: com
  !!      Verona_coupler=.false., ice_model_init confia nesses valores para
  !!      decidir o que cada PET processa; sem eles, Ice%sCS não seria alocado.
  !!   4. ice_model_init com passos rápido e lento iguais ao de acoplamento e
  !!      Concurrent_ice=.false. (o componente tem PETs próprios).
  !!   5. diag_manager_set_time_end_infra depois de ice_model_init, que
  !!      reinicializa o diag_manager; antes dele, a chamada se perdia e os
  !!      icebergs do SIS2 paravam com erro fatal ao gravar diagnósticos.
  !!   6. share_ice_domains.
  ! ============================================================================
  subroutine init_sis2(is, vm, clock, localPet, petCount, rc)
    type(ice_internal_state_type), intent(inout) :: is
    type(ESMF_VM),                 intent(in)    :: vm
    type(ESMF_Clock),              intent(in)    :: clock
    integer,                       intent(out)   :: localPet, petCount, rc

    integer               :: mpi_comm_ice, n
    type(time_type)       :: fms_init, fms_start, fms_stop
    type(ESMF_TimeInterval) :: timeStep
    type(time_type)        :: dt_coupling
    type(ESMF_Time)         :: startTime, stopTime
    integer :: yr, mo, dy, hr, mn, sc
    integer :: syy_ice, smm_ice, sdd_ice, shh_ice, smn_ice, sss_ice
    logical :: concurrent_ice_flag

    call ESMF_VMGet(vm, mpiCommunicator=mpi_comm_ice, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha VMGet ' // &
      'mpiCommunicator', line=__LINE__, file=__FILE__)) return
    call MOM_infra_init(mpi_comm_ice)
    call set_calendar_type(GREGORIAN)

    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    allocate(is%ice%fast_pelist(petCount))
    allocate(is%ice%slow_pelist(petCount))
    is%ice%fast_pelist(:) = (/ (n, n=0, petCount-1) /)
    is%ice%slow_pelist(:) = is%ice%fast_pelist(:)
    is%ice%fast_ice_pe = .true.
    is%ice%slow_ice_pe = .true.

    call ESMF_ClockGet(clock, startTime=startTime, timeStep=timeStep, &
      stopTime=stopTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_TimeGet(startTime, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fms_start = set_date(yr, mo, dy, hr, mn, sc)
    fms_init  = fms_start
    dt_coupling = esmf2fms_time(timeStep)

    ! Converte stopTime aqui (usado pelo diag_manager_set_time_end_infra
    ! logo ABAIXO de ice_model_init — ver comentário lá para o motivo da
    ! ordem).
    call ESMF_TimeGet(stopTime, yy=syy_ice, mm=smm_ice, dd=sdd_ice, &
      h=shh_ice, m=smn_ice, s=sss_ice, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fms_stop = set_date(syy_ice, smm_ice, sdd_ice, shh_ice, smn_ice, sss_ice)

    concurrent_ice_flag = .false.
    call ice_model_init(is%ice, fms_init, fms_start, &
      Time_step_fast=dt_coupling, Time_step_slow=dt_coupling, &
      Verona_coupler=.false., Concurrent_ice=concurrent_ice_flag)

    call diag_manager_set_time_end_infra(fms_stop)

    call share_ice_domains(is%ice)
    is%ice%pe = is%ice%fast_ice_pe .or. is%ice%slow_ice_pe

    call ESMF_LogWrite('ICE(SIS2): ice_model_init concluido', ESMF_LOGMSG_INFO)
  end subroutine init_sis2

  ! ============================================================================
  !> @brief Grade ESMF do gelo, com a decomposição escolhida pelo próprio SIS2.
  !!
  !! Cada PET pega os limites globais do seu bloco no domínio do SIS2, os PETs
  !! trocam essa informação e ICE_DecompFromBlocks monta os tamanhos por
  !! coluna e por linha e o mapa bloco -> PET, conferindo cobertura e
  !! unicidade. Uma regra própria (por exemplo, a raiz quadrada do número de
  !! PETs) pode divergir do layout do SIS2 e levar export_si_ifrac a ler fora
  !! do array. Se a decomposição não for representável (blocos de terra
  !! eliminados por máscara, por exemplo), o cap para com mensagem clara.
  !!
  !! A grade é periódica na direção leste-oeste, sem declarar polo, como a do
  !! mediador. As coordenadas T vêm do ocean_hgrid.nc (mom6_supergrid_mod). No
  !! fim, cada PET confere que o seu bloco ESMF é exatamente o bloco do SIS2.
  ! ============================================================================
  subroutine create_ice_grid(is, vm, localPet, petCount, rc)
    type(ice_internal_state_type), intent(inout) :: is
    type(ESMF_VM),                 intent(in)    :: vm
    integer,                       intent(in)    :: localPet, petCount
    integer,                       intent(out)   :: rc

    integer :: nx_ice, ny_ice
    integer :: gis, gie, gjs, gje
    integer :: loc4(4)
    integer, allocatable :: all4(:)
    integer, allocatable :: cntx(:), cnty(:)
    integer, allocatable :: pmap(:,:,:)
    character(len=256) :: msg_decomp
    logical :: ok_decomp
    real(ESMF_KIND_R8), pointer :: coordX(:,:)
    real(ESMF_KIND_R8), pointer :: coordY(:,:)

    call mom6_supergrid_dims(trim(cfg_mom6_mesh_ocn), nx_ice, ny_ice, rc, tag='ICE(SIS2)')
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ao ler ' // &
      'dimensoes de ocean_hgrid.nc', line=__LINE__, file=__FILE__)) return

    call mpp_get_compute_domain(is%ice%sCS%G%Domain%mpp_domain, gis, gie, gjs, gje)
    loc4 = (/ gis, gie, gjs, gje /)
    allocate(all4(4*petCount))
    call ESMF_VMAllGather(vm, sendData=loc4, recvData=all4, count=4, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): B-ICE-DECOMP-01 ' // &
      'falha ao trocar os blocos do SIS2 entre PETs', line=__LINE__, file=__FILE__)) return

    call ICE_DecompFromBlocks(reshape(all4, (/4, petCount/)), petCount, &
      nx_ice, ny_ice, cntx, cnty, pmap, msg_decomp, ok_decomp)
    if (.not. ok_decomp) then
      call ESMF_LogSetError(ESMF_RC_ARG_BAD, msg='ICE(SIS2): B-ICE-DECOMP-01 ' // &
        'decomposicao do SIS2 nao representavel na grade ESMF: ' // &
        trim(msg_decomp), line=__LINE__, file=__FILE__, rcToReturn=rc)
      return
    end if

    if (localPet == 0) then
      write(msg_decomp,'(a,i0,a,i0,a)') 'ICE(SIS2): B-ICE-DECOMP-01 - grade ESMF ' // &
        'segue a decomposicao do SIS2: ', size(cntx), ' x ', size(cnty), ' blocos'
      call ESMF_LogWrite(trim(msg_decomp), ESMF_LOGMSG_INFO)
    end if

    is%ice_grid = ESMF_GridCreate1PeriDim(countsPerDEDim1=cntx, &
      countsPerDEDim2=cnty, periodicDim=1, petMap=pmap, &
      indexflag=ESMF_INDEX_GLOBAL, coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ao criar ' // &
      'grade ESMF periodica', line=__LINE__, file=__FILE__)) return

    call ESMF_GridAddCoord(is%ice_grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridGetCoord(is%ice_grid, coordDim=1, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_GridGetCoord(is%ice_grid, coordDim=2, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call mom6_supergrid_tcoords(trim(cfg_mom6_mesh_ocn), coordX, coordY, rc, tag='ICE(SIS2)')
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ao ler ' // &
      'coordenadas T reais de ocean_hgrid.nc', line=__LINE__, file=__FILE__)) return

    is%isc = lbound(coordX,1); is%iec = ubound(coordX,1)
    is%jsc = lbound(coordX,2); is%jec = ubound(coordX,2)

    if (is%isc /= gis .or. is%iec /= gie .or. is%jsc /= gjs .or. is%jec /= gje) then
      write(msg_decomp,'(a,8(i0,a))') 'ICE(SIS2): B-ICE-DECOMP-01 bloco ESMF i ', &
        is%isc, '..', is%iec, ' j ', is%jsc, '..', is%jec, &
        ' difere do bloco do SIS2 i ', gis, '..', gie, ' j ', gjs, '..', gje, ''
      call ESMF_LogSetError(ESMF_RC_ARG_BAD, msg=trim(msg_decomp), &
        line=__LINE__, file=__FILE__, rcToReturn=rc)
      return
    end if

    call ESMF_LogWrite('ICE(SIS2): grade ESMF criada ' // &
      '(mesma grade tripolar do OCN)', ESMF_LOGMSG_INFO)
  end subroutine create_ice_grid

  ! ============================================================================
  !> @brief Número de categorias de espessura do gelo (Ice%part_size, depois
  !! de ice_model_init). Se part_size não estiver associado, avisa no log e
  !! devolve 1.
  ! ============================================================================
  integer function ice_category_count(is) result(ncat)
    type(ice_internal_state_type), intent(in) :: is

    if (associated(is%ice%part_size)) then
      ncat = size(is%ice%part_size, 3)
    else
      ncat = 1
      call ESMF_LogWrite('ICE(SIS2): AVISO — Ice%part_size nao ' // &
        'associado apos ice_model_init; usando ncat=1 como fallback ' // &
        '(provavelmente ERRADO, precisa investigar)', ESMF_LOGMSG_WARNING)
    end if
  end function ice_category_count

  ! ============================================================================
  !> @brief Cria sobre a grade do gelo e realiza os campos de importação
  !! (forçantes da atmosfera e do oceano) e de exportação.
  ! ============================================================================
  subroutine realize_ice_fields(ice_grid, importState, exportState, rc)
    type(ESMF_Grid),  intent(in)    :: ice_grid
    type(ESMF_State), intent(inout) :: importState, exportState
    integer,          intent(out)   :: rc
    integer :: k
    type(ESMF_Field) :: fld

    do k = 1, n_import_atm
      fld = ESMF_FieldCreate(ice_grid, typekind=ESMF_TYPEKIND_R8, &
        name=trim(import_names_atm(k)), rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
        'FieldCreate import ATM ' // trim(import_names_atm(k)), &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_Realize(importState, field=fld, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    do k = 1, n_import_ocn
      fld = ESMF_FieldCreate(ice_grid, typekind=ESMF_TYPEKIND_R8, &
        name=trim(import_names_ocn(k)), rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
        'FieldCreate import OCN ' // trim(import_names_ocn(k)), &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_Realize(importState, field=fld, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    do k = 1, n_export
      fld = ESMF_FieldCreate(ice_grid, typekind=ESMF_TYPEKIND_R8, &
        name=trim(export_names(k)), rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
        'FieldCreate export ' // trim(export_names(k)), &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_Realize(exportState, field=fld, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
  end subroutine realize_ice_fields

  ! ============================================================================
  !> @brief Aloca e preenche com valores iniciais as estruturas de troca com
  !! o SIS2: is%oib (oceano -> gelo, 2D) e is%aib (atmosfera -> gelo, 3D, com
  !! a dimensão de categoria).
  !!
  !! is%oib%stagger = AGRID: os campos que chegam do mediador são escalares
  !! co-localizados, sem defasagem. Com o padrão do tipo (BGRID_NE),
  !! unpack_ocean_ice_boundary interpretaria as correntes com a geometria
  !! errada. calving e calving_hflx não são usados e ficam sem alocar.
  ! ============================================================================
  subroutine alloc_ice_boundaries(is, ncat)
    type(ice_internal_state_type), intent(inout) :: is
    integer,                       intent(in)    :: ncat
    integer :: ni_loc, nj_loc

    ni_loc = is%iec - is%isc + 1
    nj_loc = is%jec - is%jsc + 1

    allocate(is%oib%u(ni_loc,nj_loc),  is%oib%v(ni_loc,nj_loc))
    allocate(is%oib%t(ni_loc,nj_loc),  is%oib%s(ni_loc,nj_loc))
    allocate(is%oib%frazil(ni_loc,nj_loc), is%oib%sea_level(ni_loc,nj_loc))
    is%oib%u = 0.0_ESMF_KIND_R8; is%oib%v = 0.0_ESMF_KIND_R8
    is%oib%t = 273.15_ESMF_KIND_R8; is%oib%s = 34.7_ESMF_KIND_R8  ! defaults de seguranca
    is%oib%frazil = 0.0_ESMF_KIND_R8; is%oib%sea_level = 0.0_ESMF_KIND_R8
    is%oib%stagger = AGRID

    allocate(is%aib%u_flux(ni_loc,nj_loc,ncat), is%aib%v_flux(ni_loc,nj_loc,ncat))
    allocate(is%aib%u_star(ni_loc,nj_loc,ncat))
    allocate(is%aib%t_flux(ni_loc,nj_loc,ncat), is%aib%q_flux(ni_loc,nj_loc,ncat))
    allocate(is%aib%lw_flux(ni_loc,nj_loc,ncat))
    allocate(is%aib%sw_flux_vis_dir(ni_loc,nj_loc,ncat))
    allocate(is%aib%sw_flux_vis_dif(ni_loc,nj_loc,ncat))
    allocate(is%aib%sw_flux_nir_dir(ni_loc,nj_loc,ncat))
    allocate(is%aib%sw_flux_nir_dif(ni_loc,nj_loc,ncat))
    allocate(is%aib%lprec(ni_loc,nj_loc,ncat), is%aib%fprec(ni_loc,nj_loc,ncat))
    allocate(is%aib%dhdt(ni_loc,nj_loc,ncat),  is%aib%dedt(ni_loc,nj_loc,ncat))
    allocate(is%aib%drdt(ni_loc,nj_loc,ncat),  is%aib%coszen(ni_loc,nj_loc,ncat))
    allocate(is%aib%p(ni_loc,nj_loc,ncat))
    is%aib%u_flux = 0.0_ESMF_KIND_R8; is%aib%v_flux = 0.0_ESMF_KIND_R8
    is%aib%u_star = 0.0_ESMF_KIND_R8   ! nao vem do mediador (decisao em
                                        ! aberto, ver docs/estado-do-projeto.md)
    is%aib%t_flux = 0.0_ESMF_KIND_R8; is%aib%q_flux = 0.0_ESMF_KIND_R8
    is%aib%lw_flux = 0.0_ESMF_KIND_R8
    is%aib%sw_flux_vis_dir = 0.0_ESMF_KIND_R8
    is%aib%sw_flux_vis_dif = 0.0_ESMF_KIND_R8
    is%aib%sw_flux_nir_dir = 0.0_ESMF_KIND_R8
    is%aib%sw_flux_nir_dif = 0.0_ESMF_KIND_R8
    is%aib%lprec = 0.0_ESMF_KIND_R8; is%aib%fprec = 0.0_ESMF_KIND_R8
    is%aib%dhdt = 0.0_ESMF_KIND_R8; is%aib%dedt = 0.0_ESMF_KIND_R8
    is%aib%drdt = 0.0_ESMF_KIND_R8; is%aib%coszen = 0.0_ESMF_KIND_R8
    is%aib%p = 101325.0_ESMF_KIND_R8  ! 1 atm, default de seguranca

    call ESMF_LogWrite('ICE(SIS2): campos ESMF realizados, ' // &
      'oib/aib alocados', ESMF_LOGMSG_INFO)
  end subroutine alloc_ice_boundaries

  ! ============================================================================
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is

    rc = ESMF_SUCCESS
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => wrap%ptr

    ! sincroniza fCS%IST <- sCS%IST logo apos
    ! ice_model_init, para que o primeiro update_ice_model_fast (inicio do
    ! primeiro ModelAdvance) ja opere sobre a condicao inicial real do gelo
    ! (restart ou default de ice_model_init em sCS%IST), em vez do estado
    ! "vazio" com que fCS%IST e alocado por padrao. Mesmo espirito do guard
    ! de first_coupling_call ja usado noutros caps para o passo inicial.
    call exchange_slow_to_fast_ice(is%ice)
    call ESMF_LogWrite('ICE(SIS2): exchange_slow_to_fast_ice inicial ' // &
      'concluido (InitializeDataComplete)', ESMF_LOGMSG_INFO)

    call set_ice_surface_fields(is%ice)
    call ESMF_LogWrite('ICE(SIS2): set_ice_surface_fields inicial ' // &
      'concluido (InitializeDataComplete)', ESMF_LOGMSG_INFO)

    call export_si_ifrac(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
      'export_si_ifrac em InitializeDataComplete', line=__LINE__, file=__FILE__)) return

    call export_si_albedo(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
      'export_si_albedo em InitializeDataComplete', line=__LINE__, file=__FILE__)) return

    call export_si_tskin(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
      'export_si_tskin em InitializeDataComplete', line=__LINE__, file=__FILE__)) return

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
      value="true", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_LogWrite('ICE(SIS2): InitializeDataComplete concluido', &
      ESMF_LOGMSG_INFO)
  end subroutine InitializeDataComplete

  ! ============================================================================
  !> @brief Avanço por passo de acoplamento: importa forçante, atualiza o
  !! SIS2 (termodinâmica + dinâmica), exporta Si_ifrac real.
  subroutine ModelAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is

    rc = ESMF_SUCCESS
    nullify(is)
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => wrap%ptr

    ! ── Passo 1: popular is%aib/is%oib a partir do importState ───────────
    call import_forcing(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha import_forcing', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 1b: desempacotar is%oib (SST/correntes do OCN, ja populado
    ! acima) para dentro de Ice%sCS%OSS, a estrutura interna que a fisica do
    ! SIS2 realmente le (ver update_ice_slow_thermo -> slow_thermodynamics(...,
    ! Ice%sCS%OSS, ...)). Sem esta chamada, as correntes oceanicas (e
    ! SST/salinidade/frazil/nivel do mar) importadas do mediador nunca chegariam
    ! ao SIS2, que rodaria sobre os valores de Ice%sCS%OSS inicializados em
    ! ice_model_init. unpack_ocean_ice_boundary e' a rotina nativa do SIS2 para
    ! essa conversao (ice_model.F90) e faz tambem translate_OSS_to_sOSS,
    ! alimentando a termodinamica rapida. Requer is%oib%stagger=AGRID (ver
    ! InitializeRealize).
    call unpack_ocean_ice_boundary(is%oib, is%ice)

    ! ── Passo 1c: registrar a forcante atmosferica (is%aib, ja populada
    ! acima) em Ice: grava fluxos e calcula a temperatura do gelo no passo
    ! rapido (ver ice_model.F90::update_ice_model_fast). Sem esta chamada,
    ! is%aib nunca chegaria ao SIS2. Padrao de chamada do driver de referencia
    ! coupler_main.F90: la e' condicionada a Ice%fast_ice_pe (que este cap
    ! forca .true., ver ice_model_init) e feita uma vez por avanco do
    ! acoplamento atmosfera-superficie, sem subciclo proprio, a mesma
    ! granularidade do nosso dt_coupling. Vem ANTES da fisica lenta porque
    ! esta consome os campos que update_ice_model_fast grava em Ice.
    call update_ice_model_fast(is%aib, is%ice)

    ! ── Passo 2: avançar o SIS2 ───────────────────────────────────────────
    !
    ! advance_ice_slow separa as duas sub-rotinas do passo lento, que e' onde
    ! a nao reprodutibilidade nasce.
    !
    ! O QUE JA SE SABE. Numa bateria de quatro execucoes (seis pares),
    ! os checksums de IST%part_size que o proprio SIS2 emite (chaves
    ! DEBUG_CHKSUMS/DEBUG_SLOW_ICE/DEBUG_FAST_ICE) mostram, na PRIMEIRA troca
    ! de acoplamento:
    !   Start set_ice_surface_state      334285  identico
    !   End   set_ice_surface_state      334285  identico
    !   Start do_update_ice_model_fast   334285  identico
    !   End   do_update_ice_model_fast   334285  identico
    !   Start update_ice_model_slow      334285  identico
    !   End   ice_state_cleanup          348735 vs 348744   DIVERGE
    ! O estado entra no passo lento identico e sai diferente, e a diferenca e'
    ! de nove unidades no checksum inteiro, ou seja, varias celulas, nao uma.
    ! O unico codigo entre esses dois pontos sao as duas chamadas abaixo.
    !
    ! O QUE ESTE DIAGNOSTICO RESPONDE. Se o checksum ja divergir depois de
    ! update_ice_slow_thermo, o alvo e' slow_thermodynamics. Se so divergir
    ! depois de update_ice_dynamics_trans, o alvo e' SIS_transport, que e'
    ! justamente a rotina que abortou com GLOBAL_INDEXING=True reclamando de
    ! "non-zero snow mass rests atop no ice". Os dois
    ! indicios apontando para o mesmo lugar seria forte.
    !
    ! LIMITE DO INSTRUMENTO, E COMO ELE SE DENUNCIA. Aqui so' ha acesso a
    ! FACHADA is%ice%part_size, nao ao sCS%IST%part_size que o SIS2 usa por
    ! Ja se viu que essa fachada pode ficar
    ! DEFASADA em relacao ao estado interno. Por isso o diagnostico mede TRES
    ! pontos, inclusive ANTES da primeira chamada: se os tres saírem iguais,
    ! a fachada nao esta sendo atualizada por estas rotinas e o instrumento e'
    ! CEGO — o que fica visivel na saida em vez de virar um falso "nao
    ! diverge". Nesse caso a medicao precisa ir para dentro do SIS2.
    !
    ! CUSTO. Tres somas e tres reducoes sobre um arranjo 3D local, uma vez por
    ! troca de acoplamento. O checksum e' inteiro, imune a arredondamento de
    ! impressao, que ja enganou esta investigacao duas vezes.
    call advance_ice_slow(is)

    call ESMF_LogWrite('ICE(SIS2): update_ice_slow_thermo + ' // &
      'update_ice_dynamics_trans concluido', ESMF_LOGMSG_INFO)

    ! ── Passo 2b: sincronizar fCS%IST <- sCS%IST ──
    ! Sem esta chamada, Ice%fCS%IST (a copia "rapida" do estado do gelo,
    ! usada por update_ice_model_fast para popular os campos publicos de
    ! fachada Ice%part_size/Ice%albedo*) fica congelada no estado inicial
    ! de ice_model_init para sempre, enquanto Ice%sCS%IST (a copia "lenta",
    ! atualizada acima por update_ice_slow_thermo/update_ice_dynamics_trans)
    ! evolui com gelo real. E exatamente a mesma causa raiz documentada em
    ! export_si_ifrac para Ice%part_size — so que ali contornada lendo
    ! sCS%IST diretamente; aqui corrigimos na fonte, pois nao ha equivalente
    ! de sCS%IST%albedo para "furar" da mesma forma (albedo e calculado
    ! transientemente dentro do proprio update_ice_model_fast, a partir de
    ! fCS%IST — precisa de fCS%IST atualizado para existir).
    !
    ! Chamada aqui (fim do passo lento) para que o PROXIMO
    ! update_ice_model_fast (inicio do proximo ModelAdvance) opere sobre
    ! estado sincronizado. Mesma defasagem de um passo do driver nativo do
    ! SIS2 (coupler_main.F90) -- nao e uma inconsistencia nova.
    call exchange_slow_to_fast_ice(is%ice)
    call ESMF_LogWrite('ICE(SIS2): exchange_slow_to_fast_ice concluido ' // &
      '(fCS%IST sincronizado com sCS%IST)', ESMF_LOGMSG_INFO)

    ! ── Passo 2c: popular Ice%part_size/Ice%albedo* ──
    ! exchange_slow_to_fast_ice (acima) so ATUALIZA fCS%IST; quem de fato
    ! PREENCHE os campos publicos de fachada (Ice%part_size, Ice%albedo_*)
    ! a partir de fCS%IST e set_ice_surface_fields (-> set_ice_surface_state
    ! internamente). No driver nativo do SIS2 (coupler_main.F90 do FMS) essa
    ! chamada e feita pelo driver externo, nunca pelo proprio SIS2 -- por
    ! isso esta ausencia nao aparece como erro de compilacao nem de link,
    ! so como campo permanentemente zerado. Sem esta chamada, o estado fica
    ! sincronizado mas ninguem o "publica".
    call set_ice_surface_fields(is%ice)
    call ESMF_LogWrite('ICE(SIS2): set_ice_surface_fields concluido ' // &
      '(Ice%part_size/albedo* publicados a partir de fCS%IST)', &
      ESMF_LOGMSG_INFO)

    ! ── Passo 3: exportar Si_ifrac real ───────────────────────────────────
    call export_si_ifrac(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha export_si_ifrac', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 3b: exportar albedo real por banda ──────────────────────────
    call export_si_albedo(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha export_si_albedo', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 3c: exportar temperatura de pele real do gelo ───────────────
    call export_si_tskin(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha export_si_tskin', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('ICE(SIS2): ModelAdvance concluido', ESMF_LOGMSG_INFO)
  end subroutine ModelAdvance

  !> Termodinâmica lenta e dinâmica do SIS2, com soma de verificação da
  !! fração por categoria antes e depois de cada etapa (diagnóstico).
  subroutine advance_ice_slow(is)
    type(ice_internal_state_type), pointer, intent(in) :: is
    character(len=200) :: msg_slow
    integer(kind=8)    :: cks_ini, cks_ter, cks_din
    logical            :: tem_ps

    tem_ps = associated(is%ice%part_size)

    if (tem_ps) cks_ini = chksum_part_size(is%ice%part_size)
    call update_ice_slow_thermo(is%ice)
    if (tem_ps) cks_ter = chksum_part_size(is%ice%part_size)
    call update_ice_dynamics_trans(is%ice)
    if (tem_ps) cks_din = chksum_part_size(is%ice%part_size)

    if (tem_ps) then
      write(msg_slow,'(A,I0,A,I0,A,I0)') &
        'FIX-DIAG-SLOWSPLIT-01: part_size chksum  entrada=', cks_ini, &
        '  pos_slow_thermo=', cks_ter, '  pos_dynamics_trans=', cks_din
      call ESMF_LogWrite(trim(msg_slow), ESMF_LOGMSG_INFO)
      if (cks_ini == cks_ter .and. cks_ter == cks_din) then
        call ESMF_LogWrite('FIX-DIAG-SLOWSPLIT-01: AVISO - os tres ' // &
          'checksums sao IGUAIS. A fachada is%ice%part_size nao reflete o ' // &
          'estado interno do SIS2 (ver B-ICE-TSKIN-SRC-01): este ' // &
          'diagnostico esta CEGO e nao permite concluir nada.', &
          ESMF_LOGMSG_WARNING)
      end if
    else
      call ESMF_LogWrite('FIX-DIAG-SLOWSPLIT-01: is%ice%part_size nao ' // &
        'associado; diagnostico nao realizado', ESMF_LOGMSG_WARNING)
    end if
  end subroutine advance_ice_slow

  ! ============================================================================
  !> @brief CheckImport sem validação de carimbo de tempo.
  !!
  !! O NUOPC padrão exige carimbo igual a currTime; o MED carimba com o
  !! instante do seu próprio relógio enquanto o relógio do SIS2 é mantido pelo
  !! FMS, e as duas marcas podem diferir. A validação é, por isso, desligada;
  !! a rotina só registra uma vez no log que está ativa.
  subroutine CheckImportTolerant(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    logical, save :: logged_once = .false.

    rc = ESMF_SUCCESS
    if (logged_once) return
    call ESMF_LogWrite('ICE(SIS2): CheckImportTolerant ativo, validacao de ' // &
      'carimbo de tempo desativada', ESMF_LOGMSG_INFO)
    logged_once = .true.
  end subroutine CheckImportTolerant

  ! ============================================================================
  !> @brief Le os campos importados do mediador (forcante ATM + SST/correntes
  !! OCN) e popula is%aib/is%oib.
  !!
  !! Nomes de campo iguais a med_cap_types.F90::export_names. Mapeamento:
  !! - Fioi_taux/tauy → u_flux/v_flux; Fioi_sen → t_flux (SINAL INVERTIDO,
  !!   ver broadcast_to_cat_neg); Fioi_evap → q_flux;
  !!   Fioi_lwnet → lw_flux; Fioi_swnet_vdr/vdf/idr/idf → sw_flux_*
  !!   (albedo do gelo puro, sem blend);
  !!   Faxa_rain/snow → lprec/fprec; Sa_pslv → p; Faxa_coszen → coszen.
  !!   Os campos 2D do mediador sao REPLICADOS (broadcast) para todas as
  !!   categorias de espessura de gelo na 3a dimensao de is%aib — o mediador
  !!   nao distingue por categoria.
  !!
  !! t_flux e' o UNICO campo desta lista
  !! que precisa de inversao de sinal. Fioi_sen chega na convencao CMEPS
  !! (positivo = aquece a superficie), mas o SIS2 (ice_boundary_types.F90)
  !! define t_flux como positivo = sai da superficie (convencao legada FMS).
  !! Fioi_evap e Fioi_lwnet ja' chegam na convencao que q_flux/lw_flux
  !! esperam — NAO inverter esses dois.
  !! - u_star e dhdt/dedt/drdt sem fonte no mediador — ficam nos valores de
  !!   seguranca definidos em InitializeRealize (zero). Isso e' uma
  !!   SIMPLIFICACAO: acoplamento explicito, sem os termos de derivada usados
  !!   para acoplamento implicito.
  subroutine import_forcing(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: importState
    real(ESMF_KIND_R8), pointer :: ptr2d(:,:) => null()

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, importState=importState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! -- Forcante atmosferica: le 2D, replica (broadcast) para as N
    !    categorias de espessura de gelo em is%aib. taux/tauy/sen/evap/lwnet
    !    vem de Fioi_* (temperatura de pele do gelo), nao de Foxx_* (SST). --
    call get_field_2d(importState, "Fioi_taux",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%u_flux)
    call get_field_2d(importState, "Fioi_tauy",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%v_flux)
    ! Fioi_sen (convencao CMEPS, positivo =
    ! aquece a superficie) precisa ser INVERTIDO ao entrar em t_flux (SIS2
    ! espera positivo = sai da superficie, convencao legada FMS). Ver
    ! docstring de broadcast_to_cat_neg abaixo para o raciocinio completo.
    call get_field_2d(importState, "Fioi_sen",       ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat_neg(ptr2d, is%aib%t_flux)
    call get_field_2d(importState, "Fioi_evap",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%q_flux)
    call get_field_2d(importState, "Fioi_lwnet",     ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lw_flux)
    ! Fioi_swnet_* (albedo do gelo por banda, PURO, sem blend com agua
    ! aberta), e nao Foxx_swnet_* (albedo MEDIO da celula, o enviado ao
    ! MOM6). Ver o comentario de import_names_atm acima e med_bulk_ncar.F90
    ! para o calculo.
    call get_field_2d(importState, "Fioi_swnet_vdr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dir)
    call get_field_2d(importState, "Fioi_swnet_vdf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dif)
    call get_field_2d(importState, "Fioi_swnet_idr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dir)
    call get_field_2d(importState, "Fioi_swnet_idf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dif)
    ! lprec/fprec/p: chuva, neve e pressao ao nivel do mar do mediador.
    call get_field_2d(importState, "Faxa_rain",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lprec)
    call get_field_2d(importState, "Faxa_snow",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%fprec)
    call get_field_2d(importState, "Sa_pslv",        ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%p)

    ! Angulo zenital solar real. Se o mediador nao exportar Faxa_coszen,
    ! degrada de forma segura para coszen=0 em vez de abortar toda a
    ! forcante.
    call get_field_2d(importState, "Faxa_coszen", ptr2d, rc)
    if (rc == ESMF_SUCCESS) then
      call broadcast_to_cat(ptr2d, is%aib%coszen)
    else
      call ESMF_LogWrite('ICE(SIS2): Faxa_coszen nao encontrado no ' // &
        'importState — is%aib%coszen permanece 0 (mediador antigo?)', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
    end if

    ! -- SST/correntes do oceano: cópia direta 2D para is%oib. --
    call get_field_2d(importState, "So_t", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%t(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_u", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%u(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_v", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%v(:,:) = ptr2d(:,:)
    ! is%oib%s (salinidade): sem fonte confirmada do mediador ainda — ver
    ! nota no plano de integração ("So_s" listado como campo em aberto na
    ! memória do projeto). Mantém o default de seguranca (34.7 psu)
    ! definido em InitializeRealize.

  end subroutine import_forcing

  !> Helper: busca campo 2D no state pelo nome; rc=ESMF_SUCCESS se achou.
  subroutine get_field_2d(state, name, ptr2d, rc)
    type(ESMF_State),    intent(in)    :: state
    character(len=*),    intent(in)    :: name
    real(ESMF_KIND_R8), pointer        :: ptr2d(:,:)
    integer,              intent(out)  :: rc
    type(ESMF_Field) :: fld
    call ESMF_StateGet(state, itemName=trim(name), field=fld, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('ICE(SIS2): campo "' // trim(name) // &
        '" nao encontrado no importState', ESMF_LOGMSG_WARNING)
      return
    end if
    call ESMF_FieldGet(fld, farrayPtr=ptr2d, rc=rc)
  end subroutine get_field_2d

  !> Helper: replica um campo 2D em todas as categorias de espessura (3a
  !! dimensao) de um campo do atmos_ice_boundary_type.
  subroutine broadcast_to_cat(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(out)   :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = src2d(:,:)
    end do
  end subroutine broadcast_to_cat

  ! > variante de broadcast_to_cat que
  !! inverte o sinal antes de replicar. Uso exclusivo para Fioi_sen -> t_flux.
  !!
  !! Fioi_sen chega do MED_cap (med_bulk_ncar.F90) na convencao CMEPS
  !! (positivo = fluxo sensivel PARA a superficie, aquece o gelo) — a mesma
  !! convencao de Foxx_sen, confirmada contra o hfx/lh nativo do MONAN-A
  !! (positivo-para-cima). O SIS2 (ice_boundary_types.F90::atmos_ice_boundary_type)
  !! documenta t_flux como "the net sensible heat flux from the ocean or ice
  !! INTO the atmosphere" — ou seja, positivo = sai da superficie (convencao
  !! legada do acoplador FMS, oposta a CMEPS). broadcast_to_cat (copia pura)
  !! entregava Fioi_sen a t_flux sem essa inversao, fazendo o SIS2 interpretar
  !! aquecimento real da superficie como perda de calor (e vice-versa) —
  !! causa de derretimento espurio em condicoes que deveriam resfriar/
  !! engrossar o gelo (ex. ar frio sobre gelo, comum em inverno polar).
  !!
  !! Fioi_evap -> q_flux e Fioi_lwnet -> lw_flux NAO precisam desta correcao:
  !! Fioi_evap ja segue a convencao CMEPS "E>0 = superficie->atmosfera", que
  !! coincide com q_flux; Fioi_lwnet ja e' liquido-para-dentro, que coincide
  !! com lw_flux ("from the atmosphere into the ice or ocean").
  subroutine broadcast_to_cat_neg(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(out)   :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = -src2d(:,:)
    end do
  end subroutine broadcast_to_cat_neg


  !! Confirmado em ice_type.F90. Ver SIS2_ativacao_plano_integracao.md.
  subroutine export_si_ifrac(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    integer :: ii, jj, lb1, lb2, ub1, ub2
    integer :: i_off, j_off, k_lo, k_hi
          character(len=200) :: diag_msg6

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_ifrac_sis2", field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) return

    if (.not. associated(is%ice%sCS)) then
      call ESMF_LogWrite('ICE(SIS2): Ice%sCS nao associado (slow ice PE ' // &
        'ausente?) — Si_ifrac=0', ESMF_LOGMSG_WARNING)
      ptr_ifrac = 0.0_ESMF_KIND_R8
      return
    end if

    lb1 = lbound(ptr_ifrac,1); ub1 = ubound(ptr_ifrac,1)
    lb2 = lbound(ptr_ifrac,2); ub2 = ubound(ptr_ifrac,2)
    ! ------------------------------------------------------------------
    ! Fracao de gelo marinho exportada ao mediador (Si_ifrac_sis2).
    !
    ! FONTE DO CAMPO — ponto critico: usa Ice%sCS%IST%part_size (estado
    ! interno real do SIS2, ice_state_type), NAO Ice%part_size. Este ultimo
    ! e o campo de fachada do acoplador, preenchido apenas no caminho de
    ! acoplamento rapido (ver ice_type.F90:191 - only available on fast PEs)
    ! e permanece ZERADO nesta configuracao. IST%part_size e o mesmo array
    ! que o proprio SIS2 usa para calcular area/massa em ice_stock_pe, ou
    ! seja, os valores nao-zero que aparecem no log SIS Date.
    !
    ! INDEXACAO: IST%part_size tem halos (isd:ied, jsd:jed) e categorias com
    ! base 0, onde a fatia 0 e AGUA ABERTA e 1..CatIce sao as categorias de
    ! gelo. O deslocamento vem da grade do proprio SIS2 (Ice%sCS%G%isc/jsc),
    ! padrao usado internamente por ice_model.F90 - acompanha corretamente
    ! qualquer decomposicao MPI (verificado: PET6 i_off=4, PET7 i_off=-86).
    ! A soma e feita de k_lo+1 ate k_hi (todas as categorias de gelo, isto e,
    ! todas as fatias menos a primeira), robusto a base 0 ou 1.
    !
    ! IST so existe em slow_ice_PE - garantido aqui, pois o cap forca
    ! fast_ice_pe=.true. e slow_ice_pe=.true. antes de ice_model_init.
    ! ------------------------------------------------------------------
    i_off = is%ice%sCS%G%isc - lb1
    j_off = is%ice%sCS%G%jsc - lb2
    k_lo  = lbound(is%ice%sCS%IST%part_size, 3)
    k_hi  = ubound(is%ice%sCS%IST%part_size, 3)
    do jj = lb2, ub2
      do ii = lb1, ub1
        ! fracao de gelo = soma das categorias de gelo = todas as fatias
        ! menos a primeira (agua aberta), robusto a base 0 ou 1
        ptr_ifrac(ii,jj) = &
          sum(is%ice%sCS%IST%part_size(ii+i_off, jj+j_off, k_lo+1:k_hi))
        ptr_ifrac(ii,jj) = max(0.0_ESMF_KIND_R8, &
          min(1.0_ESMF_KIND_R8, ptr_ifrac(ii,jj)))
      end do
    end do

    ! Diagnostico: compara o campo publico de fachada Ice%part_size (zerado
    ! nesta configuracao, ver acima) com sCS%IST%part_size, a fonte real
    ! usada acima. Condicionado a cfg_write_fixdiag para nao poluir os logs
    ! de rodadas longas.
    if (cfg_write_fixdiag) then
      if (associated(is%ice%part_size)) then
          write(diag_msg6,'(A,ES12.4,A,ES12.4)') &
            'FIX-DIAG-FASTSYNC-01: Ice%part_size(:,:,1) [fachada publica] ' // &
            'min=', minval(is%ice%part_size(:,:,1)), ' max=', &
            maxval(is%ice%part_size(:,:,1))
          call ESMF_LogWrite(trim(diag_msg6), ESMF_LOGMSG_INFO)
      else
        call ESMF_LogWrite('FIX-DIAG-FASTSYNC-01: Ice%part_size ainda nao ' // &
          'associado neste ponto', ESMF_LOGMSG_INFO)
      end if
    end if

  end subroutine export_si_ifrac

  !! exporta o albedo real do gelo, por banda,
  !! calculado pela fisica do proprio SIS2 (esquema optico em
  !! SIS_optics.F90/fast_radiation_diagnostics), agora acessivel porque
  !! Ice%albedo_vis_dir/vis_dif/nir_dir/nir_dif (fachada publica) passaram
  !! a ser preenchidos pelas correcoes /02 acima.
  !!
  !! Diferente de Si_ifrac_sis2 (que le sCS%IST%part_size com deslocamento
  !! i_off/j_off), aqui usamos Ice%part_size e Ice%albedo_* diretamente —
  !! ambos sao campos da MESMA fachada publica, com a MESMA indexacao local
  !! (sem halo, sem offset), confirmados no diagnostico
  !! (que ja le is%ice%part_size(:,:,1) sem nenhum deslocamento).
  !!
  !! *** VERIFICAR ***: os comentarios de ice_type.F90 (fonte NOAA-GFDL/SIS2)
  !! para albedo_vis_dif/albedo_nir_dir parecem trocados entre si ("The
  !! surface albedo for diffuse visible..." vs "...direct near-infrared...").
  !! Usamos aqui os NOMES dos campos (vis_dir/vis_dif/nir_dir/nir_dif), que
  !! sao a fonte de verdade da API, nao a prosa do comentario — mas vale
  !! uma segunda conferencia cruzando com SIS_optics.F90 antes de validar
  !! contra observacoes.
  subroutine export_si_albedo(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_avsdr, f_avsdf, f_anidr, f_anidf
    real(ESMF_KIND_R8), pointer :: ptr_avsdr(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_avsdf(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_anidr(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_anidf(:,:) => null()
    real(ESMF_KIND_R8) :: ice_frac_ij
    integer :: ii, jj, k_lo, k_hi
    ! Fallback usado apenas onde a fracao de gelo e desprezivel (o peso do
    ! termo de gelo no blend por ifrac feito no mediador torna esse valor
    ! quase irrelevante), ou onde Ice%albedo_* ainda nao estiver associado.
    real(ESMF_KIND_R8), parameter :: ALBEDO_ICE_FALLBACK = 0.65_ESMF_KIND_R8
        character(len=200) :: diag_msg7

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_avsdr_sis2", field=f_avsdr, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_avsdf_sis2", field=f_avsdf, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_anidr_sis2", field=f_anidr, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_anidf_sis2", field=f_anidf, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call ESMF_FieldGet(f_avsdr, farrayPtr=ptr_avsdr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_avsdr)) return
    call ESMF_FieldGet(f_avsdf, farrayPtr=ptr_avsdf, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_avsdf)) return
    call ESMF_FieldGet(f_anidr, farrayPtr=ptr_anidr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_anidr)) return
    call ESMF_FieldGet(f_anidf, farrayPtr=ptr_anidf, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_anidf)) return

    if (.not. (associated(is%ice%part_size) .and. &
               associated(is%ice%albedo_vis_dir) .and. &
               associated(is%ice%albedo_vis_dif) .and. &
               associated(is%ice%albedo_nir_dir) .and. &
               associated(is%ice%albedo_nir_dif))) then
      call ESMF_LogWrite('ICE(SIS2): Ice%part_size/albedo_* nao ' // &
        'associados — Si_a*_sis2 = fallback constante', ESMF_LOGMSG_WARNING)
      ptr_avsdr = ALBEDO_ICE_FALLBACK; ptr_avsdf = ALBEDO_ICE_FALLBACK
      ptr_anidr = ALBEDO_ICE_FALLBACK; ptr_anidf = ALBEDO_ICE_FALLBACK
      return
    end if

    ! part_size/albedo_* tem a mesma 3a dimensao (categorias); categoria
    ! k_lo = agua aberta (mesma convencao usada em export_si_ifrac).
    k_lo = lbound(is%ice%part_size, 3)
    k_hi = ubound(is%ice%part_size, 3)

    do jj = lbound(ptr_avsdr,2), ubound(ptr_avsdr,2)
      do ii = lbound(ptr_avsdr,1), ubound(ptr_avsdr,1)
        ice_frac_ij = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8))
        if (ice_frac_ij > 1.0e-6_ESMF_KIND_R8) then
          ! media ponderada pela area de cada categoria de gelo
          ptr_avsdr(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_vis_dir(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_avsdf(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_vis_dif(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_anidr(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_nir_dir(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_anidf(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_nir_dif(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
        else
          ptr_avsdr(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_avsdf(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_anidr(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_anidf(ii,jj) = ALBEDO_ICE_FALLBACK
        end if
        ! blindagem: albedo fisico esta sempre em [0,1]
        ptr_avsdr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdr(ii,jj)))
        ptr_avsdf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdf(ii,jj)))
        ptr_anidr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidr(ii,jj)))
        ptr_anidf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidf(ii,jj)))
      end do
    end do

    ! diagnostico de validacao, mesmo espirito do
    ! Espera-se min proximo do fallback/agua (baixo)
    ! e max na faixa de neve fria (~0,8-0,9) em regioes com gelo espesso.
    if (cfg_write_fixdiag) then
        write(diag_msg7,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
          'FIX-DIAG-ALBEDO-01: Si_avsdr min=', minval(ptr_avsdr), &
          ' max=', maxval(ptr_avsdr), &
          ' | Si_anidr min=', minval(ptr_anidr), ' max=', maxval(ptr_anidr)
        call ESMF_LogWrite(trim(diag_msg7), ESMF_LOGMSG_INFO)
    end if

  end subroutine export_si_albedo

  !! exporta a temperatura de pele real do
  !! gelo, media ponderada por area de categoria (mesmo padrao de
  !! export_si_albedo). Usada pelo mediador para calcular um segundo
  !! conjunto de fluxos turbulentos (Fioi_*) especifico para a fracao de
  !! gelo, em vez de reusar o Foxx_* calculado com SST — que e o que o
  !! SIS2 recebia ate aqui (ver import_names_atm, historicamente
  !! compartilhado com o MOM6).
  !!
  !! Ice%t_surf e' preenchido pela MESMA rotina (set_ice_surface_state) que
  !! Ice%part_size/Ice%albedo_* — ja' confirmada funcionando pelas
  !! correcoes /02.
  subroutine export_si_tskin(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_tice
    real(ESMF_KIND_R8), pointer :: ptr_tice(:,:) => null()
    real(ESMF_KIND_R8) :: ice_frac_ij
    integer :: ii, jj, k_lo, k_hi
    ! Fallback: ponto de congelamento tipico da agua do mar (~-1,8 C),
    ! usado so' onde a fracao de gelo e desprezivel ou o campo nao esta
    ! associado — o peso do termo de gelo no blend a jusante torna esse
    ! valor quase irrelevante nesses casos.
        character(len=150) :: diag_msg8

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_t_sis2", field=f_tice, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_tice, farrayPtr=ptr_tice, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_tice)) return

    if (.not. (associated(is%ice%part_size) .and. associated(is%ice%t_surf))) then
      call ESMF_LogWrite('ICE(SIS2): Ice%part_size/t_surf nao associados ' // &
        '— Si_t_sis2 = fallback (ponto de congelamento)', ESMF_LOGMSG_WARNING)
      ptr_tice = TICE_FALLBACK
      return
    end if

    k_lo = lbound(is%ice%part_size, 3)
    k_hi = ubound(is%ice%part_size, 3)

    do jj = lbound(ptr_tice,2), ubound(ptr_tice,2)
      do ii = lbound(ptr_tice,1), ubound(ptr_tice,1)
        ice_frac_ij = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8))
        if (ice_frac_ij > 1.0e-6_ESMF_KIND_R8) then
          ptr_tice(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                 real(is%ice%t_surf(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
        else
          ptr_tice(ii,jj) = TICE_FALLBACK
        end if
        ! blindagem fisica: temperatura de gelo/neve nunca abaixo de ~180 K
        ! (recorde antartico ~184 K) nem acima do congelamento da agua do mar
        ptr_tice(ii,jj) = max(180.0_ESMF_KIND_R8, min(273.15_ESMF_KIND_R8, ptr_tice(ii,jj)))
      end do
    end do

    if (cfg_write_fixdiag) then
        write(diag_msg8,'(A,ES10.3,A,ES10.3)') &
          'FIX-DIAG-TSKIN-01: Si_t_sis2 min=', minval(ptr_tice), ' max=', maxval(ptr_tice)
        call ESMF_LogWrite(trim(diag_msg8), ESMF_LOGMSG_INFO)
    end if

  end subroutine export_si_tskin

  ! ============================================================================
  subroutine ModelFinalize(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is

    rc = ESMF_SUCCESS
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => wrap%ptr

    call ice_model_restart(is%ice)
    call ice_model_end(is%ice)
    deallocate(wrap%ptr)

    call ESMF_LogWrite('ICE(SIS2): ModelFinalize concluido', ESMF_LOGMSG_INFO)

  end subroutine ModelFinalize

  ! > a partir dos blocos de todos os PETs (inicio e fim
  !! globais em i e em j, na ordem dos PETs), monta a decomposicao retangular
  !! que o ESMF precisa: tamanho de cada coluna (cntx), de cada linha (cnty) e
  !! o PET dono de cada bloco (pmap). Valida que os blocos formam uma
  !! grade produto (layout nbx x nby), cobrem 1..nx e 1..ny sem buraco nem
  !! sobreposicao, e que cada bloco pertence a exatamente um PET.
  !! blocos(1:4, p) = (/ is, ie, js, je /) do PET p-1.
  subroutine ICE_DecompFromBlocks(blocos, npet, nx, ny, cntx, cnty, pmap, msg, ok)
    integer,              intent(in)  :: blocos(:,:)
    integer,              intent(in)  :: npet, nx, ny
    integer, allocatable, intent(out) :: cntx(:), cnty(:), pmap(:,:,:)
    character(len=*),     intent(out) :: msg
    logical,              intent(out) :: ok

    integer, allocatable :: xs(:), xe(:), ys(:), ye(:)
    integer :: p, k, nbx, nby, ix, iy
    logical :: novo

    ok  = .false.
    msg = ''
    allocate(xs(npet), xe(npet), ys(npet), ye(npet))
    nbx = 0 ; nby = 0

    ! colunas e linhas distintas (pelo inicio), com o fim correspondente
    do p = 1, npet
      novo = .true.
      do k = 1, nbx
        if (xs(k) == blocos(1,p)) then
          novo = .false.
          if (xe(k) /= blocos(2,p)) then
            write(msg,'(a,i0,a)') 'colunas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (novo) then ; nbx = nbx + 1 ; xs(nbx) = blocos(1,p) ; xe(nbx) = blocos(2,p) ; end if
      novo = .true.
      do k = 1, nby
        if (ys(k) == blocos(3,p)) then
          novo = .false.
          if (ye(k) /= blocos(4,p)) then
            write(msg,'(a,i0,a)') 'linhas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (novo) then ; nby = nby + 1 ; ys(nby) = blocos(3,p) ; ye(nby) = blocos(4,p) ; end if
    end do

    if (nbx * nby /= npet) then
      write(msg,'(a,i0,a,i0,a,i0,a)') 'layout ', nbx, ' x ', nby, ' nao corresponde a ', npet, &
        ' PETs (blocos mascarados ou decomposicao nao retangular?)'
      return
    end if

    call ordena(xs(1:nbx), xe(1:nbx))
    call ordena(ys(1:nby), ye(1:nby))

    ! cobertura contigua de 1..nx e 1..ny
    if (xs(1) /= 1 .or. xe(nbx) /= nx .or. ys(1) /= 1 .or. ye(nby) /= ny) then
      write(msg,'(a,4(i0,a))') 'blocos nao cobrem a grade: i ', xs(1), '..', xe(nbx), &
        ', j ', ys(1), '..', ye(nby)
      return
    end if
    do k = 1, nbx - 1
      if (xs(k+1) /= xe(k) + 1) then ; msg = 'colunas com buraco ou sobreposicao' ; return ; end if
    end do
    do k = 1, nby - 1
      if (ys(k+1) /= ye(k) + 1) then ; msg = 'linhas com buraco ou sobreposicao' ; return ; end if
    end do

    allocate(cntx(nbx), cnty(nby), pmap(nbx, nby, 1))
    cntx = xe(1:nbx) - xs(1:nbx) + 1
    cnty = ye(1:nby) - ys(1:nby) + 1
    pmap = -1
    do p = 1, npet
      ix = findloc(xs(1:nbx), blocos(1,p), dim=1)
      iy = findloc(ys(1:nby), blocos(3,p), dim=1)
      if (pmap(ix, iy, 1) /= -1) then
        write(msg,'(a,i0,a,i0)') 'bloco atribuido a dois PETs: ', pmap(ix,iy,1), ' e ', p-1
        return
      end if
      pmap(ix, iy, 1) = p - 1
    end do
    ok = .true.

  contains

    pure subroutine ordena(a, b)
      integer, intent(inout) :: a(:), b(:)
      integer :: i, j, ta, tb
      do i = 2, size(a)
        ta = a(i) ; tb = b(i) ; j = i - 1
        do while (j >= 1)
          if (a(j) <= ta) exit
          a(j+1) = a(j) ; b(j+1) = b(j) ; j = j - 1
        end do
        a(j+1) = ta ; b(j+1) = tb
      end do
    end subroutine ordena

  end subroutine ICE_DecompFromBlocks

  !> @brief Checksum inteiro de part_size, no mesmo espirito do chksum do SIS2.
  !!
  !! Inteiro, e nao mean/min/max, porque valor de ponto
  !! flutuante impresso com poucos digitos ja escondeu divergencia duas vezes
  !! nesta investigacao: com quatro digitos ela aparecia na 12a troca, com
  !! quinze, na 3a. Um checksum inteiro nao tem esse problema.
  !!
  !! A transformacao para inteiro usa um fator grande e o padrao de bits do
  !! valor, de modo que diferenca de ultimo bit altere o resultado. A soma
  !! acumula em inteiro de 8 bytes para nao saturar.
  !!
  !! Escopo: arranjo do DE local, nao global. Comparar sempre o MESMO PET
  !! entre execucoes.
  function chksum_part_size(ps) result(cks)
    real(ESMF_KIND_R8), pointer, intent(in) :: ps(:,:,:)
    integer(kind=8) :: cks
    integer :: i1, i2, i3
    cks = 0_8
    if (.not. associated(ps)) return
    do i3 = lbound(ps,3), ubound(ps,3)
      do i2 = lbound(ps,2), ubound(ps,2)
        do i1 = lbound(ps,1), ubound(ps,1)
          cks = cks + int(transfer(ps(i1,i2,i3), 1_8), 8)
        end do
      end do
    end do
  end function chksum_part_size

end module sis_cap_MONAN_mod
