!> @file MED_cap.F90
!! @brief Mediador NUOPC do acoplamento atmosfera-oceano-gelo do MONAN.
!!
!! Ciclo de vida NUOPC do mediador (SetServices, Initialize*, MediatorAdvance).
!! As partes especializadas ficam em módulos próprios:
!!   med_cap_types.F90    tipos, listas de campos e constantes
!!   med_init.F90         grades, campos e rotas da inicialização
!!   med_flux.F90         forçante atmosférica e fluxos do mediador
!!   med_bulk_ncar.F90    fluxos turbulentos por fórmulas bulk NCAR
!!   med_ocean.F90        SST, máscara, correntes e gelo do OISST na grade ATM
!!   med_ice.F90          gelo do SIS2 na grade ATM
!!   med_export.F90       exportação dos campos para os componentes
!!   med_diag.F90         resumos e diagnósticos do log
!!   med_cap_methods.F90  utilitários ESMF (campos internos, regrid, roteamento)
!!   med_cap_netcdf.F90   diagnóstico NetCDF dos campos importados
!!
!! A fonte atmosférica (MPAS ou DATM) e a rota OCN -> ATM (pelo mediador ou
!! direta) vêm de nuopc.input (coupler_config_mod). O histórico de correções
!! está em docs/CHANGELOG.md.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module MED_cap_MONAN_mod
  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY
  use coupler_utils_mod, only: ChkErr
  use cap_common_mod, only: cap_initialize_p0
  use mom6_supergrid_mod, only : mom6_supergrid_dims
  use coupler_log_mod, only: COMP_MED, log_info, log_debug, log_debug_enabled
  use coupler_config_mod, only: cfg_docn_nx, cfg_docn_ny,         &
                                  cfg_use_docn, cfg_mom6_mesh_ocn,  &
                                  cfg_use_datm, cfg_use_med_to_mpas, &
                                  cfg_use_sis2_dynamic,             & ! gelo dinâmico do SIS2
                                  cfg_coupling_mode,                &
                                  cfg_seq_repro,                    & ! seq_repro (reprodutibilidade)
                                  cfg_stop_date, config_parse_date, &
                                  cpl_current_config
  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Advertise
  use NUOPC_Mediator, only: med_routine_SS          => SetServices
  use NUOPC_Mediator, only: med_label_DataInitialize => label_DataInitialize
  use NUOPC_Mediator, only: med_label_Advance        => label_Advance
  use NUOPC_Mediator, only: med_label_CheckImport    => label_CheckImport
  use NUOPC_Mediator, only: NUOPC_MediatorGet
  ! Módulos especializados do mediador
  use med_cap_types_mod,   only: MED_InternalState,            &
                                  MED_InternalStateWrapper,     &
                                  MED_KEYS
  use cpl_fields_mod,      only: CPL_NAME_LEN
  use cpl_map_mod,         only: cpl_arrivals
  use med_cap_netcdf_mod,  only: med_read_import_config, med_write_import_fields
  use med_init_mod,        only: create_atm_grid, create_ocn_grid,           &
                                  realize_component_fields,                   &
                                  create_internal_fields
  use med_flux_mod,        only: get_atm_forcing, gather_atm_forcing,        &
                                  local_atm_bounds, apply_native_fluxes,      &
                                  zero_med_fluxes
  use med_exchange_mod,    only: initialize_data, go_to_flux_grid, &
                                  compute_fluxes, ice_fraction_without_sis2, deliver
  use med_diag_mod,        only: log_ice_export, report_fills

  implicit none
  private
  public :: SetServices


contains

  !> @brief Registra o mediador no NUOPC: fases de inicialização,
  !! especializações (Advance, CheckImport, DataInitialize) e o relatório
  !! do último passo.
  !! @param[inout] gcomp  componente do mediador
  !! @param[out]   rc     código de retorno
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(gcomp, med_routine_SS, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=cap_initialize_p0, phase=0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_Advance, &
      specRoutine=mediatoradvancereport, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_CheckImport, &
      specRoutine=CheckImportNoop, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

  end subroutine SetServices

  !> @brief Passo do mediador (MediatorAdvance) e, no último passo da rodada, as
  !! linhas do relatório de acoplamento com os pontos completados por
  !! vizinhança (report_fills), que só escrevem no log.
  !!
  !! O relatório não pode ficar na finalização do componente: o programa
  !! principal não chama ESMF_GridCompFinalize (esmApp.F90). O último passo
  !! é aquele em que currTime + timeStep alcança stop_date do nuopc.input; o
  !! relógio do próprio mediador não serve, porque o NUOPC o faz parar no fim
  !! de cada passo. Todos os PETs do mediador chegam aqui, inclusive os que
  !! saem cedo de MediatorAdvance, porque report_fills é coletiva.
  subroutine mediatoradvancereport(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    type(ESMF_Clock)        :: clock
    type(ESMF_Time)         :: currTime, stopTime
    type(ESMF_TimeInterval) :: dt
    integer :: yy, mm, dd

    call MediatorAdvance(gcomp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_MediatorGet(gcomp, mediatorClock=clock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_ClockGet(clock, currTime=currTime, timeStep=dt, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call config_parse_date(cfg_stop_date, yy, mm, dd, rc)
    if (rc /= 0) then
      rc = ESMF_SUCCESS   ! data já conferida por config_read; sem relatório
      return
    end if
    call ESMF_TimeSet(stopTime, yy=yy, mm=mm, dd=dd, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (currTime + dt < stopTime) return

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap
    call report_fills(is%run%fill_counts, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine mediatoradvancereport

  !> @brief CheckImport sem verificação: o mediador aceita os campos
  !! importados com qualquer carimbo de tempo.
  !! @param[inout] gcomp  componente do mediador
  !! @param[out]   rc     sempre ESMF_SUCCESS
  subroutine CheckImportNoop(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
    call log_debug(COMP_MED, 'CheckImport desabilitado (no-op)')
  end subroutine CheckImportNoop

  !> @brief Anuncia os campos importados e exportados, lidos do mapa de
  !! acoplamento, e cria o estado interno do mediador.
  !! @param[inout] gcomp        componente do mediador
  !! @param[inout] importState  estado de importação
  !! @param[inout] exportState  estado de exportação
  !! @param[in]    clock        relógio do mediador
  !! @param[out]   rc           código de retorno
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    integer :: n
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS

    allocate(iswrap%wrap)
    is => iswrap%wrap
    is%use_mpas_atm    = .not. cfg_use_datm
    is%use_med_to_mpas = cfg_use_med_to_mpas

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (is%use_mpas_atm) then
      call log_info(COMP_MED, 'fonte atmosferica = MPAS')
    else
      call log_info(COMP_MED, 'fonte atmosferica = DATM')
    end if
    if (is%use_med_to_mpas) &
      call log_info(COMP_MED, 'use_med_to_mpas=true: contorno da atmosfera pelo mediador')

    ! Importação e exportação lidas do mapa de acoplamento (cpl_arrivals),
    ! com as chaves de MED_KEYS, na ordem do mapa:
    !   - forçantes do MONAN-A (_mpas) ou do DATM, nunca os dois: o NUOPC
    !     aborta em IPDv03p6 se um campo anunciado não tiver conector ativo;
    !   - So_t, So_u, So_v e So_omask, do oceano. Sem o anúncio de So_u e
    !     So_v, o conector OCN -> MED descartaria as correntes; So_omask é a
    !     máscara real do MOM6, usada no lugar de um limiar de SST;
    !   - com o SIS2, os seis campos *_sis2. O sufixo evita que os conectores
    !     OCN -> MED e ICE -> MED cheguem ao mesmo nome (Si_ifrac).
    ! A importação usa SharePolicyField="share"; a exportação
    ! oferece a grade ("will provide").
    call cpl_arrivals('MED', .true., cpl_current_config(), MED_KEYS, names)
    do n = 1, size(names)
      call NUOPC_Advertise(importState, StandardName=trim(names(n)), &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    call cpl_arrivals('MED@ocn_med', .false., cpl_current_config(), '', names)
    do n = 1, size(names)
      call NUOPC_Advertise(exportState, StandardName=trim(names(n)), &
        TransferOfferGeomObject="will provide", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    call log_info(COMP_MED, 'InitializeAdvertise concluido')
  end subroutine InitializeAdvertise

  !> @brief Cria as grades internas ATM e OCN, realiza os campos e cria os
  !! campos internos do mediador.
  !!
  !! So_t (SST) é realizado na grade OCN, a grade nativa do campo: na
  !! atm_grid, a rota OCN->ATM teria origem e destino na mesma grade e a
  !! interpolação ficaria incorreta.
  !! @param[inout] gcomp        componente do mediador
  !! @param[inout] importState  estado de importação
  !! @param[inout] exportState  estado de exportação
  !! @param[in]    clock        relógio do mediador
  !! @param[out]   rc           código de retorno
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    type(ESMF_Grid)  :: atm_grid, ocn_grid
    type(ESMF_VM)    :: vm
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: nx_atm, ny_atm, nx_ocn, ny_ocn
    integer :: petCount
    character(len=256)  :: msg_tmp
      type(ESMF_VM) :: med_vm

    rc = ESMF_SUCCESS

    ! Recuperar estado interno
    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap


    ! petCount define a decomposição das duas grades (cpl_regdecomp): um DE
    ! por PET, sem DEs vazios nem de largura 1, que o conector bilinear
    ! automático do NUOPC não aceita.
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha VMGetCurrent', &
      line=__LINE__, file=__FILE__)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha VMGet petCount', &
      line=__LINE__, file=__FILE__)) return

    ! Dimensões das grades internas do mediador:
    !   ATM: ATM_NX x ATM_NY (360x180, 1°), a mesma grade de saída do cap MPAS.
    !   OCN: com DOCN, cfg_docn_nx x cfg_docn_ny de nuopc.input (&nuopc_docn);
    !        com MOM6, a grade T lida de ocean_hgrid.nc (ver abaixo).
    nx_atm = ATM_NX
    ny_atm = ATM_NY
    ! cfg_docn_nx/ny (1440x720) são a grade do
    ! DOCN/OISST (0.25 grau, regular). Quando o OCN real é o MOM6+SIS2
    ! dinâmico (cfg_use_docn=.false., modo de produção), a grade T real do
    ! MOM6 é definida por NIGLOBAL/NJGLOBAL no MOM_input e normalmente NÃO
    ! coincide com a grade DOCN (ex.: 180x155 vs 1440x720 observado em
    ! produção). Usar cfg_docn_nx/ny nesse caso faz o mediador declarar uma
    ! grade ~8x maior e geometricamente uniforme (lat/lon regular) onde a
    ! grade real é tripolar e não uniforme -> o conector NUOPC OCN->MED monta
    ! um regrid automático usando coordenadas erradas, contaminando TODOS os
    ! campos (So_t, So_u, So_v, So_omask) antes mesmo da máscara de costa
    ! entrar em ação. Por isso, em modo MOM6 lemos a dimensão real da grade T
    ! diretamente do supergrid ocean_hgrid.nc (nx/ny do arquivo / 2, convenção
    ! FRE-NCtools) em vez de reutilizar a config do DOCN.
    if (cfg_use_docn) then
      nx_ocn = cfg_docn_nx  ! Grade DOCN de nuopc.input (ex: OISST 0.25° = 1440)
      ny_ocn = cfg_docn_ny  ! Grade DOCN de nuopc.input (ex: OISST 0.25° =  720)
    else
      call mom6_supergrid_dims(trim(cfg_mom6_mesh_ocn), nx_ocn, ny_ocn, rc, comp=COMP_MED)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED: falha ao ler dimensoes reais de ocean_hgrid.nc " // &
            "(NIGLOBAL/NJGLOBAL do MOM6) - verifique cfg_mom6_mesh_ocn", &
        line=__LINE__, file=__FILE__)) return
      write(msg_tmp,'(A,I0,A,I0,A)') 'grade T real do MOM6 lida de ' // &
        trim(cfg_mom6_mesh_ocn) // ' = ', nx_ocn, ' x ', ny_ocn, &
        ' (NIGLOBAL x NJGLOBAL)'
      call log_info(COMP_MED, trim(msg_tmp))
    end if

    ! Criar grade ATM regular (ATM_NX x ATM_NY)
    ! Malha atm_med, construída por cpl_latlon_grid (cpl_grids), com a
    ! decomposição de cpl_regdecomp: um DE por PET, como a grade do cap MPAS.
    call create_atm_grid(petCount, nx_atm, ny_atm, atm_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Criar grade OCN (grade do DOCN ou grade T do MOM6)
    ! Mesma fatoração exata da grade ATM: um DE por PET, com colunas <=
    ! nx_ocn/2 e linhas <= ny_ocn.
    call create_ocn_grid(petCount, nx_ocn, ny_ocn, ocn_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Realizar campos de import conforme a fonte atmosférica configurada.
    ! Espelha exatamente o que foi anunciado em InitializeAdvertise.
    call realize_component_fields(is, importState, exportState, atm_grid, ocn_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Atualizar estado interno com grades criadas nesta fase.
    ! NÃO re-alocar iswrap%wrap: já alocado em InitializeAdvertise.
    is%atm_grid   = atm_grid
    is%ocn_grid   = ocn_grid
    ! use_mpas_atm já lido logo após GetInternalState (ver acima).
    ! Não sobrescrever com .false. aqui.


    ! Criar campos internos na grade ATM
    call create_internal_fields(is, atm_grid, rc)

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Ler a configuração do diagnóstico de importação
    call med_read_import_config(is%diag)

    ! salvar informação MPI do mediador para uso em med_write_import_fields
    !
    ! Não cair para MPI_COMM_WORLD em
    ! caso de erro. is%par%comm alimenta os MPI_Allreduce coletivos de
    ! med_write_import_fields. No modo concurrent o MED tem seu próprio
    ! comunicador de componente; substituí-lo silenciosamente por
    ! MPI_COMM_WORLD (todos os ranks) num coletivo sobre o comunicador do
    ! componente causaria mismatch / deadlock. Falhar cedo é o correto —
    ! um erro de VM é excepcional e deve abortar, não ser mascarado.
      call ESMF_VMGetCurrent(med_vm, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='MED: falha ESMF_VMGetCurrent em InitializeRealize', &
        line=__LINE__, file=__FILE__)) return
      call ESMF_VMGet(med_vm, localPet=is%par%local_pet, petCount=is%par%pet_count, &
        mpiCommunicator=is%par%comm, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='MED: falha ESMF_VMGet mpiCommunicator em InitializeRealize', &
        line=__LINE__, file=__FILE__)) return


    call log_info(COMP_MED, 'InitializeRealize concluido')
  end subroutine InitializeRealize


  !> @brief Fase de dados da inicialização: obtém os estados por
  !! NUOPC_MediatorGet (a API dos mediadores NUOPC) e chama initialize_data
  !! (med_exchange), que cria as rotas, espera a primeira SST e publica os
  !! valores de t=0.
  !! @param[inout] gcomp  componente do mediador
  !! @param[out]   rc     código de retorno
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)         :: importState, exportState
    type(ESMF_Clock)         :: clock
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap

    ! NUOPC_MediatorGet é a API dos mediadores
    call NUOPC_MediatorGet(gcomp, mediatorClock=clock, &
      importState=importState, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Fase de inicialização (med_exchange): rotas, espera da primeira SST e
    ! valores de t=0 no exportState.
    call initialize_data(gcomp, is, importState, exportState, clock, rc)
  end subroutine InitializeDataComplete

  !> @brief Um passo do mediador: forçante atmosférica (MONAN-A ou DATM),
  !! campos do oceano e do gelo na malha de fluxo, fluxos e exportação.
  !!
  !! Etapas, nesta ordem: med_stamp_time, zero_med_fluxes, get_atm_forcing,
  !! gather_atm_forcing, local_atm_bounds, go_to_flux_grid (med_exchange),
  !! compute_fluxes (med_exchange), ice_fraction_without_sis2 (med_exchange),
  !! apply_native_fluxes, deliver (med_exchange: exportação e carimbo de
  !! tempo), log_ice_export (med_diag, com log_level='debug') e
  !! med_write_import_fields.
  !! @param[inout] gcomp  componente do mediador
  !! @param[out]   rc     código de retorno
  subroutine MediatorAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)         :: importState, exportState
    type(ESMF_Clock)         :: clock
    type(ESMF_Time)          :: currTime, nextTime
    ! instante que representa o CONTEÚDO desta execução do mediador (ver
    ! med_stamp_time).
    type(ESMF_Time)          :: stampTime
    type(ESMF_TimeInterval)  :: dt
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: localDeCount_med  ! guard para PETs sem DE local
    logical :: proceed

    ! Forçantes atmosféricos na grade ATM local (MPAS ou DATM)
    real(ESMF_KIND_R8), pointer :: uas(:,:), vas(:,:), tas(:,:), shum(:,:)
    real(ESMF_KIND_R8), pointer :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8), pointer :: rain(:,:), snow(:,:)
    ! fluxos nativos do PBL do MONAN-A (opcionais — ausência mantém
    ! o fallback bulk NCAR via calc_bulk_ncar, ex. modo DATM)
    real(ESMF_KIND_R8), pointer :: sen_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: lat_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: taux_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: tauy_mpas(:,:) => null()
    ! valores padrão quando Sa_shum_mpas / Faxa_snow_mpas estão ausentes
    real(ESMF_KIND_R8), pointer     :: shum_local(:,:) => null()
    real(ESMF_KIND_R8), pointer     :: snow_local(:,:) => null()
    integer :: i1, i2, j1, j2
    ! Forçantes reunidos na grade ATM global (1:ATM_NX, 1:ATM_NY)
    real(ESMF_KIND_R8), allocatable :: uas_g(:,:), vas_g(:,:), tas_g(:,:)
    real(ESMF_KIND_R8), allocatable :: psl_g(:,:), swdn_g(:,:), lwdn_g(:,:)
    real(ESMF_KIND_R8), allocatable :: rain_g(:,:), shum_g(:,:), snow_g(:,:)

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap

    ! NUOPC_MediatorGet e ESMF_ClockGet são chamados ANTES da guarda
    ! localDeCount==0. med_write_import_fields contém MPI_Allreduce e
    ! MPI_Reduce, operações coletivas que exigem participação de TODOS os
    ! PETs: um PET sem DE local que retornasse sem chamá-la deixaria os PETs
    ! ativos bloqueados no MPI_Allreduce (deadlock). Por isso os PETs sem DE
    ! local chamam a função com contribuição vazia (grid_local = FILL_IMP)
    ! antes de retornar.
    call NUOPC_MediatorGet(gcomp, mediatorClock=clock, &
      importState=importState, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_ClockGet(clock, currTime=currTime, timeStep=dt, rc=rc)
    nextTime = currTime + dt

    stampTime = med_stamp_time(currTime, nextTime)

    ! O atm_grid do MED tem um DE por PET (cpl_regdecomp); a guarda abaixo
    ! protege PETs sem DE local, que não podem acessar campos internos via
    ! farrayPtr.
    call ESMF_FieldGet(is%ocn_flx%taux, localDeCount=localDeCount_med, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (localDeCount_med == 0) then
      ! PET sem DE local: participar nas operações MPI coletivas dentro de
      ! med_write_import_fields antes de retornar (evita deadlock).
      ! Contribuição local = FILL_IMP (neutro no MPI_Reduce MAX).
      call med_write_import_fields(exportState, stampTime, is, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS
      return
    end if

    ! zerar f_*_atm antes do bulk para evitar persistência de
    ! valores não inicializados em células fora do alcance de uas/vas
    ! (grade MPAS Voronoi parcialmente sobreposta à grade MED regular).
    ! O loop bulk só preenche (i1:i2, j1:j2) = lbound:ubound(uas); sem
    ! zerar antes, regiões sem dados MPAS aparecem como lixo nos plots.
    call zero_med_fluxes(is, rc)

    ! 1 e 2. FORÇANTES ATMOSFÉRICOS: MPAS (primário) ou DATM (fallback)
    call get_atm_forcing(is, importState, uas, vas, tas, shum, psl, swdn, lwdn, &
                         rain, snow, shum_local, snow_local,                     &
                         sen_mpas, lat_mpas, taux_mpas, tauy_mpas, proceed, rc)
    if (.not. proceed) return

    i1 = lbound(uas,1); i2 = ubound(uas,1)
    j1 = lbound(uas,2); j2 = ubound(uas,2)

    ! Forçantes reunidos na grade ATM global em todos os PETs do mediador
    call gather_atm_forcing(uas, vas, tas, psl, swdn, lwdn, rain, shum, snow, &
                            i1, i2, j1, j2, is%par%comm,                       &
                            uas_g, vas_g, tas_g, psl_g, swdn_g, lwdn_g,        &
                            rain_g, shum_g, snow_g, is%run%first_forcing_summary, rc)

    ! Os arrays globais cobrem 1..ATM_NX, 1..ATM_NY; os campos internos
    ! (is%ocn_flx%*, is%ice%* etc.) tem os limites LOCAIS da DE do PET. O
    ! bulk percorre os limites locais, acessando os arrays globais nas mesmas coordenadas.
    call local_atm_bounds(is, i1, i2, j1, j2, rc)

    ! 3. Campos do oceano e do gelo na malha de fluxo: fase
    ! go_to_flux_grid (med_exchange)
    call go_to_flux_grid(is, importState, clock, rc)

    ! 4. CALCULAR BULK NCAR — delegado ao módulo med_bulk_ncar_mod
    call compute_fluxes(is, &
                        uas_g, vas_g, tas_g, psl_g, swdn_g, lwdn_g, rain_g, shum_g, snow_g, &
                        i1, i2, j1, j2, clock, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: calc_bulk_ncar falhou', &
      line=__LINE__, file=__FILE__)) return

    ! Sem o SIS2, a fração de gelo da malha de fluxo, depois da física
    ! (med_exchange)
    call ice_fraction_without_sis2(is, importState, i1, i2, j1, j2)

    call apply_native_fluxes(is, sen_mpas, lat_mpas, taux_mpas, tauy_mpas, rc)

    ! 5. REGRID E EXPORTA PARA O OCEANO
    !
    ! RegridOrCopy leva cada campo interno (grade ATM) ao exportState (grade
    ! OCN) pela rota 'atm2ocn'; sem a rota, copia direto, para que os campos
    ! exportados não fiquem zerados silenciosamente.
    !
    ! Antes do export, os fluxos sobre terra são zerados no próprio MED
    ! (zero_fluxes_over_land). O bulk NCAR roda em TODAS as células da grade
    ! ATM (oceano + terra); com T_2m, U_10m e P_slv continentais, produz
    ! fluxos enormes sobre terra (Foxx_sen saturando em +-500 W/m^2;
    ! Foxx_lwnet em -300 W/m^2 sobre o Saara). O MOM6 descarta essas células
    ! em state_setexport (mask2dT), mas o diagnóstico NetCDF do MED é escrito
    ! antes dessa máscara.
    !
    ! A máscara de terra é So_omask interpolada para a grade ATM uma única
    ! vez (regrid_land_mask, NEAREST_STOD: só precisa distinguir terra e
    ! oceano). Uma heurística pela SST (células de terra com exatamente
    ! 271,35 K) colidiria com água aberta no ponto de congelamento (borda do
    ! gelo).
    !
    ! A exportação e o carimbo de tempo dos campos exportados formam a fase
    ! deliver (med_exchange); com use_med_to_mpas, o exportState recebe
    ! depois o tempo atual do relógio.
    call deliver(is, importState, exportState, clock, stampTime, rc)
    if (allocated(uas_g)) deallocate(uas_g)
    if (allocated(vas_g)) deallocate(vas_g)
    if (allocated(tas_g)) deallocate(tas_g)
    if (allocated(psl_g)) deallocate(psl_g)
    if (allocated(swdn_g)) deallocate(swdn_g)
    if (allocated(lwdn_g)) deallocate(lwdn_g)
    if (allocated(rain_g)) deallocate(rain_g)
    if (allocated(shum_g)) deallocate(shum_g)
    if (allocated(snow_g)) deallocate(snow_g)

    call log_info(COMP_MED, 'MediatorAdvance concluido')

    ! Si_ifrac como sai do mediador (etapa 4 das somas de bits)
    if (log_debug_enabled()) call log_ice_export(exportState)

    call med_write_import_fields(exportState, stampTime, is, rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS  ! não-fatal
    ! Liberar arrays temporários de defaults (se alocados)
    if (associated(shum_local)) then
      deallocate(shum_local); nullify(shum_local)
    end if
    if (associated(snow_local)) then
      deallocate(snow_local); nullify(snow_local)
    end if
  end subroutine MediatorAdvance

  !> @brief Instante que rotula o resultado desta execução do mediador.
  !!
  !! O instante que rotula o resultado do
  !! mediador depende de ONDE o elemento 'MED' esta na RunSequence.
  !!
  !! O relógio do mediador marca currTime = t durante toda a execução do passo,
  !! nos dois modos: o NUOPC só avança o relógio depois que o Advance retorna.
  !! O que muda é o conteúdo que chega ao importState:
  !!
  !!   concurrent : 'MED' é o ÚLTIMO elemento do passo. Os conectores
  !!                'MPAS -> MED', 'OCN -> MED' e 'ICE -> MED' já rodaram
  !!                DEPOIS dos avanços, então os campos importados descrevem o
  !!                estado em t+dt. O rótulo correto é nextTime.
  !!
  !!   sequential : 'MED' é o QUARTO elemento, ANTES de 'MPAS', 'OCN' e 'ICE'.
  !!                Os conectores que o alimentam rodaram no início do passo, e
  !!                os campos importados descrevem o estado em t (o que cada
  !!                componente escreveu no fim do passo anterior). O rótulo
  !!                correto é currTime.
  !!
  !! Usar nextTime também no modo sequencial teria duas consequências:
  !!
  !!   (a) Todo arquivo de diagnóstico mom6_import_YYYYMMDD_HHMMSS.nc e
  !!       monan2_import_YYYYMMDD_HHMMSS.nc sairia com o nome e a variável de
  !!       tempo adiantados em um dt_coupling em relação ao dado que contém.
  !!       Uma rodada sequential e uma concurrent ficariam deslocadas de um
  !!       passo, e as animações, fora de fase.
  !!   (b) O exportState seria carimbado com t+dt e entregue a componentes
  !!       cujo relógio marca t. Os três caps usam CheckImport tolerante
  !!       (janela de +/- dt_coupling) ou no-op, então isso não abortaria a
  !!       execução; passaria sem sinal nenhum. Com currTime o carimbo
  !!       coincide exatamente com o relógio do consumidor.
  !!
  !! No modo concorrente, stampTime = nextTime.
  !! seq_repro: na variante REPRODUTÍVEL do sequential+split+SIS2 o elemento
  !! 'MED' roda no FIM do passo (mesma coreografia do concurrent), portanto os
  !! campos importados descrevem o estado em t+dt e o rótulo correto é
  !! nextTime — não currTime. Sem o '.and. .not. cfg_seq_repro' o carimbo
  !! sairia adiantado de um dt e quebraria a comparação bit-a-bit contra o
  !! concurrent. O sequential clássico (cfg_seq_repro=.false.) usa
  !! 'MED' cedo -> currTime; o concurrent usa nextTime.
  !!
  !! @param[in] currTime  instante corrente do relógio do mediador
  !! @param[in] nextTime  currTime + dt_coupling
  !! @return             currTime no sequencial clássico, nextTime nos demais
  function med_stamp_time(currTime, nextTime) result(stampTime)
    type(ESMF_Time), intent(in) :: currTime, nextTime
    type(ESMF_Time)             :: stampTime

    logical :: med_runs_before_advance

    med_runs_before_advance = (trim(cfg_coupling_mode) == 'sequential' &
                               .and. .not. cfg_seq_repro)
    if (med_runs_before_advance) then
      stampTime = currTime
    else
      stampTime = nextTime
    end if
  end function med_stamp_time

end module MED_cap_MONAN_mod

