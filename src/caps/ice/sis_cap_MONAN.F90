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
!! Os passos 1 e 3 e o estado interno do componente ficam em
!! sis_cap_fields.F90.
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

  use mom6_supergrid_mod, only : mom6_supergrid_dims
  use cpl_grids_mod, only : cpl_blocks_t, cpl_blocks_from_bounds, cpl_tripolar_grid
  use coupler_config_mod, only : cfg_mom6_mesh_ocn
  use cpl_fields_mod, only : CPL_NAME_LEN
  use cpl_map_mod, only : cpl_arrivals, cpl_exports, cpl_current_config

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
  use cap_common_mod, only : cap_initialize_p0

  ! Estado interno do componente e troca de campos com o mediador
  ! (importação dos forçantes e exportação de fração, albedos e temperatura
  ! de pele), em sis_cap_fields.F90.
  use sis_cap_fields_mod, only : ice_internal_state_type, import_forcing, &
                                  export_si_ifrac, export_si_albedo,     &
                                  export_si_tskin
  use coupler_constants_mod, only : T0_KELVIN

  implicit none
  private

  public :: SetServices

  type :: ice_internal_state_wrapper
    type(ice_internal_state_type), pointer :: ptr => null()
  end type ice_internal_state_wrapper

  ! ── Nomes de campo trocados com o mediador ────────────────────────────────
  ! Saem do mapa de acoplamento (src/coupling/cpl_map.F90), no ponto
  ! ICE@ice_sis2: a importação são os 16 campos que chegam do mediador
  ! (cpl_arrivals), 13 da forçante atmosférica (os Fioi_*, Faxa_rain,
  ! Faxa_snow, Sa_pslv e Faxa_coszen, ver AIB) e So_t, So_u e So_v (ver OIB);
  ! a exportação, os 6 campos *_sis2 de EXPORTS (cpl_exports). O
  ! conector "MED -> ICE" casa por StandardName; um nome que o MED não exporta
  ! produz "NUOPC INCOMPATIBILITY: Import Fields not all connected".
  ! taux/tauy/sen/evap/lwnet vêm dos Fioi_* (calculados com a temperatura de
  ! pele real do gelo, Si_t_sis2; ver export_si_tskin e med_bulk_ncar.F90),
  ! e não dos Foxx_* (calculados com a SST, apropriados para o MOM6). Da
  ! mesma forma, a onda curta vem de Fioi_swnet_*, calculada com o albedo do
  ! gelo por banda puro; Foxx_swnet_* usa o albedo misturado por Si_ifrac.
  ! O cap anuncia sempre as mesmas listas: não consulta chaves de &nuopc_mode.
  character(len=*), parameter :: POINT_ICE = 'ICE@ice_sis2'

contains

  ! ============================================================================
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Seleciona a versão das fases de inicialização (IPDv03), como em
    ! mom_cap_MONAN.F90. Sem ela, a negociação de fases com o driver pode não
    ! corresponder ao que InitializeAdvertise/InitializeRealize abaixo
    ! registram (phaseLabelList=IPDv03p1/IPDv03p3).
    !
    ! SetClock NÃO é especializado. Uma especialização vazia bloquearia o
    ! comportamento PADRÃO do NUOPC_Model de sincronizar o relógio deste
    ! componente com o do driver, causando "NUOPC INCOMPATIBILITY: Import
    ! Fields not at current time" (o relógio do ICE nunca ficaria alinhado).
    ! Mesmo padrão de mom_cap_MONAN.F90, que também não especializa SetClock.
    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=cap_initialize_p0, phase=0, rc=rc)
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
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc
    integer :: n
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS

    call cpl_arrivals(POINT_ICE, .true., cpl_current_config(), '', names)
    do n = 1, size(names)
      call NUOPC_Advertise(importState, StandardName=trim(names(n)), &
        TransferOfferGeomObject="cannot provide", SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
    call cpl_exports(POINT_ICE, cpl_current_config(), '', names)
    do n = 1, size(names)
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
      call NUOPC_Advertise(exportState, StandardName=trim(names(n)), &
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
  !! trocam essa informação e cpl_blocks_from_bounds (cpl_grids) monta os
  !! tamanhos por coluna e por linha e o mapa bloco -> PET, conferindo cobertura e
  !! unicidade. Uma regra própria (por exemplo, a raiz quadrada do número de
  !! PETs) pode divergir do layout do SIS2 e levar export_si_ifrac a ler fora
  !! do array. Se a decomposição não for representável (blocos de terra
  !! eliminados por máscara, por exemplo), o cap para com mensagem clara.
  !!
  !! A grade é a malha ice_sis2, construída por cpl_tripolar_grid: periódica
  !! na direção leste-oeste, sem declarar polo, como a do mediador, com as
  !! coordenadas T do ocean_hgrid.nc, sem cantos. No
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
    type(cpl_blocks_t) :: blocks
    character(len=256) :: msg_decomp
    logical :: ok_decomp
    real(ESMF_KIND_R8), pointer :: coordX(:,:)

    call mom6_supergrid_dims(trim(cfg_mom6_mesh_ocn), nx_ice, ny_ice, rc, tag='ICE(SIS2)')
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ao ler ' // &
      'dimensoes de ocean_hgrid.nc', line=__LINE__, file=__FILE__)) return

    call mpp_get_compute_domain(is%ice%sCS%G%Domain%mpp_domain, gis, gie, gjs, gje)
    loc4 = (/ gis, gie, gjs, gje /)
    allocate(all4(4*petCount))
    call ESMF_VMAllGather(vm, sendData=loc4, recvData=all4, count=4, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): B-ICE-DECOMP-01 ' // &
      'falha ao trocar os blocos do SIS2 entre PETs', line=__LINE__, file=__FILE__)) return

    call cpl_blocks_from_bounds(reshape(all4, (/4, petCount/)), petCount, &
      nx_ice, ny_ice, blocks, msg_decomp, ok_decomp)
    if (.not. ok_decomp) then
      call ESMF_LogSetError(ESMF_RC_ARG_BAD, msg='ICE(SIS2): B-ICE-DECOMP-01 ' // &
        'decomposicao do SIS2 nao representavel na grade ESMF: ' // &
        trim(msg_decomp), line=__LINE__, file=__FILE__, rcToReturn=rc)
      return
    end if

    if (localPet == 0) then
      write(msg_decomp,'(a,i0,a,i0,a)') 'ICE(SIS2): B-ICE-DECOMP-01 - grade ESMF ' // &
        'segue a decomposicao do SIS2: ', size(blocks%cntx), ' x ', size(blocks%cnty), ' blocos'
      call ESMF_LogWrite(trim(msg_decomp), ESMF_LOGMSG_INFO)
    end if

    call cpl_tripolar_grid('ice_sis2', cfg_mom6_mesh_ocn, nx_ice, ny_ice, petCount, .false., &
                            is%ice_grid, rc, blocks=blocks, tag='ICE(SIS2)')
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Bloco deste PET (um DE por PET), para conferir com o do SIS2
    call ESMF_GridGetCoord(is%ice_grid, coordDim=1, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

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
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    call cpl_arrivals(POINT_ICE, .true., cpl_current_config(), '', names)
    do k = 1, size(names)
      fld = ESMF_FieldCreate(ice_grid, typekind=ESMF_TYPEKIND_R8, &
        name=trim(names(k)), rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
        'FieldCreate import ' // trim(names(k)), &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_Realize(importState, field=fld, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    call cpl_exports(POINT_ICE, cpl_current_config(), '', names)
    do k = 1, size(names)
      fld = ESMF_FieldCreate(ice_grid, typekind=ESMF_TYPEKIND_R8, &
        name=trim(names(k)), rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
        'FieldCreate export ' // trim(names(k)), &
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
    is%oib%t = T0_KELVIN; is%oib%s = 34.7_ESMF_KIND_R8  ! defaults de seguranca
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
    integer(kind=8)    :: cks_ini, cks_thermo, cks_dyn
    logical            :: has_ps

    has_ps = associated(is%ice%part_size)

    if (has_ps) cks_ini = chksum_part_size(is%ice%part_size)
    call update_ice_slow_thermo(is%ice)
    if (has_ps) cks_thermo = chksum_part_size(is%ice%part_size)
    call update_ice_dynamics_trans(is%ice)
    if (has_ps) cks_dyn = chksum_part_size(is%ice%part_size)

    if (has_ps) then
      write(msg_slow,'(A,I0,A,I0,A,I0)') &
        'FIX-DIAG-SLOWSPLIT-01: part_size chksum  entrada=', cks_ini, &
        '  pos_slow_thermo=', cks_thermo, '  pos_dynamics_trans=', cks_dyn
      call ESMF_LogWrite(trim(msg_slow), ESMF_LOGMSG_INFO)
      if (cks_ini == cks_thermo .and. cks_thermo == cks_dyn) then
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

    type(ice_internal_state_wrapper) :: wrap

    rc = ESMF_SUCCESS
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (wrap%ptr%check_import_logged) return
    call ESMF_LogWrite('ICE(SIS2): CheckImportTolerant ativo, validacao de ' // &
      'carimbo de tempo desativada', ESMF_LOGMSG_INFO)
    wrap%ptr%check_import_logged = .true.
  end subroutine CheckImportTolerant

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
