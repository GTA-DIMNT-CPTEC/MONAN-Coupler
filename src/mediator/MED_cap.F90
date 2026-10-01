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
  use coupler_config_mod, only: cfg_docn_nx, cfg_docn_ny,         &
                                  cfg_write_fixdiag,                &
                                  cfg_use_docn, cfg_mom6_mesh_ocn,  &
                                  cfg_use_datm, cfg_use_med_to_mpas, &
                                  cfg_use_sis2_dynamic,             & ! gelo dinamico do SIS2
                                  cfg_coupling_mode,                &
                                  cfg_seq_repro,                    & ! seq_repro (reprodutibilidade)
                                  cfg_stop_date, config_parse_date
  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Advertise
  use NUOPC, only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet
  use NUOPC, only: NUOPC_IsAtTime
  use NUOPC_Mediator, only: med_routine_SS          => SetServices
  use NUOPC_Mediator, only: med_label_DataInitialize => label_DataInitialize
  use NUOPC_Mediator, only: med_label_Advance        => label_Advance
  use NUOPC_Mediator, only: med_label_CheckImport    => label_CheckImport
  use NUOPC_Mediator, only: NUOPC_MediatorGet
  ! Módulos especializados do mediador
  use med_cap_types_mod,   only: MED_InternalState,            &
                                  MED_InternalStateWrapper,     &
                                  MED_CHAVES
  use cpl_fields_mod,      only: CPL_NOME_LEN
  use cpl_map_mod,         only: cpl_chegadas, cpl_config_atual
  use med_bulk_ncar_mod,   only: calc_bulk_ncar
  use med_cap_methods_mod, only: RegridOrCopy, RouteOcnToAtm
  use med_cap_netcdf_mod,  only: med_read_import_config, med_write_import_fields
  use med_init_mod,        only: create_atm_grid, create_ocn_grid,           &
                                  realize_component_fields,                   &
                                  create_internal_fields, idc_create_routes
  use med_flux_mod,        only: get_atm_forcing, gather_atm_forcing,        &
                                  local_atm_bounds, apply_native_fluxes,      &
                                  zero_med_fluxes
  use med_ocean_mod,       only: update_ocean_fields_on_atm_grid,            &
                                  regrid_ocean_currents,                      &
                                  update_ice_fraction_from_docn
  use med_export_mod,      only: export_to_components, stamp_export_fields
  use med_diag_mod,        only: log_ifrac_export_bitsum, relata_completas

  implicit none
  private
  public :: SetServices


contains

  !============================================================================
  ! SetServices
  !============================================================================
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
      specRoutine=MediatorAdvanceRelatorio, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_CheckImport, &
      specRoutine=CheckImportNoop, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

  end subroutine SetServices

  !============================================================================
  !> Passo do mediador (MediatorAdvance) e, no último passo da rodada, as
  !! linhas do relatório de acoplamento com os pontos completados por
  !! vizinhança (relata_completas), que só escrevem no log.
  !!
  !! O relatório não pode ficar na finalização do componente: o programa
  !! principal não chama ESMF_GridCompFinalize (esmApp.F90). O último passo
  !! é aquele em que currTime + timeStep alcança stop_date do nuopc.input; o
  !! relógio do próprio mediador não serve, porque o NUOPC o faz parar no fim
  !! de cada passo. Todos os PETs do mediador chegam aqui, inclusive os que
  !! saem cedo de MediatorAdvance, porque relata_completas é coletiva.
  !============================================================================
  subroutine MediatorAdvanceRelatorio(gcomp, rc)
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
    call relata_completas(is%run%completa, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine MediatorAdvanceRelatorio

  !============================================================================
  ! CheckImportNoop
  !============================================================================
  subroutine CheckImportNoop(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
    call ESMF_LogWrite('MED: CheckImport desabilitado (no-op)', ESMF_LOGMSG_INFO)
  end subroutine CheckImportNoop

  !============================================================================
  ! InitializeAdvertise
  !============================================================================
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    integer :: n
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    character(len=CPL_NOME_LEN), allocatable :: nomes(:)

    rc = ESMF_SUCCESS

    allocate(iswrap%wrap)
    is => iswrap%wrap
    is%use_mpas_atm    = .not. cfg_use_datm
    is%use_med_to_mpas = cfg_use_med_to_mpas

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (is%use_mpas_atm) then
      call ESMF_LogWrite('MED: fonte atmosferica = MPAS', ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite('MED: fonte atmosferica = DATM', ESMF_LOGMSG_INFO)
    end if
    if (is%use_med_to_mpas) &
      call ESMF_LogWrite('MED: use_med_to_mpas=true, RouteOcnToAtm ativo', ESMF_LOGMSG_INFO)

    ! Importação e exportação lidas do mapa de acoplamento (cpl_chegadas),
    ! com as chaves de MED_CHAVES, na ordem do mapa, que é a de antes:
    !   - forçantes do MONAN-A (_mpas) ou do DATM, nunca os dois: o NUOPC
    !     aborta em IPDv03p6 se um campo anunciado não tiver conector ativo;
    !   - So_t, So_u, So_v e So_omask, do oceano. Sem o anúncio de So_u e
    !     So_v, o conector OCN -> MED descartaria as correntes; So_omask é a
    !     máscara real do MOM6, usada no lugar de um limiar de SST;
    !   - com o SIS2, os seis campos *_sis2. O sufixo evita que os conectores
    !     OCN -> MED e ICE -> MED cheguem ao mesmo nome (Si_ifrac).
    ! A importação usa SharePolicyField="share", como antes; a exportação
    ! oferece a grade ("will provide").
    call cpl_chegadas('MED', .true., cpl_config_atual(), MED_CHAVES, nomes)
    do n = 1, size(nomes)
      call NUOPC_Advertise(importState, StandardName=trim(nomes(n)), &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    call cpl_chegadas('MED@ocn_med', .false., cpl_config_atual(), '', nomes)
    do n = 1, size(nomes)
      call NUOPC_Advertise(exportState, StandardName=trim(nomes(n)), &
        TransferOfferGeomObject="will provide", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    call ESMF_LogWrite('MED: InitializeAdvertise concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeAdvertise

  !============================================================================
  ! InitializeRealize
  ! Cria as grades internas ATM e OCN e realiza os campos. So_t (SST) e'
  ! realizado na grade OCN, a grade nativa do campo: na atm_grid, a rota
  ! OCN->ATM teria origem e destino na mesma grade e o regrid ficaria
  ! incorreto.
  !============================================================================
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


    ! petCount define a decomposicao das duas grades (cpl_regdecomp): um DE
    ! por PET, sem DEs vazios nem de largura 1, que o conector bilinear
    ! automatico do NUOPC nao aceita.
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha VMGetCurrent', &
      line=__LINE__, file=__FILE__)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha VMGet petCount', &
      line=__LINE__, file=__FILE__)) return

    ! ---------------------------------------------------------------------------
    ! Dimensões das grades internas do mediador:
    !   ATM: ATM_NX x ATM_NY (360x180, 1°), a mesma grade de saída do cap MPAS.
    !   OCN: com DOCN, cfg_docn_nx x cfg_docn_ny de nuopc.input (&nuopc_docn);
    !        com MOM6, a grade T lida de ocean_hgrid.nc (ver abaixo).
    nx_atm = ATM_NX
    ny_atm = ATM_NY
    ! cfg_docn_nx/ny (1440x720) sao a grade do
    ! DOCN/OISST (0.25 grau, regular). Quando o OCN real e' o MOM6+SIS2
    ! dinamico (cfg_use_docn=.false., modo de producao), a grade T real do
    ! MOM6 e' definida por NIGLOBAL/NJGLOBAL no MOM_input e normalmente NAO
    ! coincide com a grade DOCN (ex.: 180x155 vs 1440x720 observado em
    ! producao). Usar cfg_docn_nx/ny nesse caso faz o mediador declarar uma
    ! grade ~8x maior e geometricamente uniforme (lat/lon regular) onde a
    ! grade real e' tripolar/nao-uniforme -> o conector NUOPC OCN->MED monta
    ! um regrid automatico usando coordenadas erradas, contaminando TODOS os
    ! campos (So_t, So_u, So_v, So_omask) antes mesmo da mascara de costa
    ! entrar em acao. Por isso, em modo MOM6 lemos a dimensao real da grade T
    ! diretamente do supergrid ocean_hgrid.nc (nx/ny do arquivo / 2, convencao
    ! FRE-NCtools) em vez de reutilizar a config do DOCN.
    if (cfg_use_docn) then
      nx_ocn = cfg_docn_nx  ! Grade DOCN de nuopc.input (ex: OISST 0.25° = 1440)
      ny_ocn = cfg_docn_ny  ! Grade DOCN de nuopc.input (ex: OISST 0.25° =  720)
    else
      call mom6_supergrid_dims(trim(cfg_mom6_mesh_ocn), nx_ocn, ny_ocn, rc, tag='MED B-OCNGRID-01')
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED: falha ao ler dimensoes reais de ocean_hgrid.nc " // &
            "(NIGLOBAL/NJGLOBAL do MOM6) - verifique cfg_mom6_mesh_ocn", &
        line=__LINE__, file=__FILE__)) return
      write(msg_tmp,'(A,I0,A,I0,A)') 'MED: grade T real do MOM6 lida de ' // &
        trim(cfg_mom6_mesh_ocn) // ' = ', nx_ocn, ' x ', ny_ocn, &
        ' (NIGLOBAL x NJGLOBAL)'
      call ESMF_LogWrite(trim(msg_tmp), ESMF_LOGMSG_INFO)
    end if

    !--------------------------------------------------------------------------
    ! Criar grade ATM regular (ATM_NX x ATM_NY)
    !--------------------------------------------------------------------------
    ! Malha atm_med, construida por cpl_malha_latlon (cpl_grids), com a
    ! decomposicao de cpl_regdecomp: um DE por PET, como a grade do cap MPAS.
    call create_atm_grid(petCount, nx_atm, ny_atm, atm_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    !--------------------------------------------------------------------------
    ! Criar grade OCN (grade do DOCN ou grade T do MOM6)
    !--------------------------------------------------------------------------
    ! Mesma fatoracao exata da grade ATM: um DE por PET, com colunas <=
    ! nx_ocn/2 e linhas <= ny_ocn.
    call create_ocn_grid(petCount, nx_ocn, ny_ocn, ocn_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    !--------------------------------------------------------------------------
    ! Realizar campos de import conforme a fonte atmosferica configurada.
    ! Espelha exatamente o que foi anunciado em InitializeAdvertise.
    !--------------------------------------------------------------------------
    call realize_component_fields(is, importState, exportState, atm_grid, ocn_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    !--------------------------------------------------------------------------
    ! Atualizar estado interno com grades criadas nesta fase.
    ! NAO re-alocar iswrap%wrap: ja alocado em InitializeAdvertise.
    !--------------------------------------------------------------------------
    is%atm_grid   = atm_grid
    is%ocn_grid   = ocn_grid
    ! use_mpas_atm ja lido logo apos GetInternalState (ver acima).
    ! Nao sobrescrever com .false. aqui.


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


    call ESMF_LogWrite('MED: InitializeRealize concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeRealize


  !============================================================================
  ! InitializeDataComplete - cria as rotas de interpolacao
  ! importState/exportState vem de NUOPC_MediatorGet, a API propria dos
  ! mediadores NUOPC. A grade ATM e' obtida de Sa_u10m_mpas (modo MPAS) ou de
  ! Sa_u10m (modo DATM), conforme is%use_mpas_atm.
  !============================================================================
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)         :: importState, exportState
    type(ESMF_Clock)         :: clock
    type(ESMF_Time)          :: startTime
    type(ESMF_Field)         :: ocn_field, exp_field
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    logical :: sst_ready

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap

    ! NUOPC_MediatorGet e a API correta para mediadores
    call NUOPC_MediatorGet(gcomp, mediatorClock=clock, &
      importState=importState, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call idc_check_atm_field(is, importState, rc)
    if (rc /= ESMF_SUCCESS) return

    ! Obter campo de export para o OCN (Foxx_taux esta na grade OCN)
    call ESMF_StateGet(exportState, itemName="Foxx_taux", field=exp_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha Foxx_taux", &
      line=__LINE__, file=__FILE__)) return

  !==========================================================================
  ! FASE A — GEOMETRIA (uma unica vez, na primeira iteracao)
  !
  ! Esta rotina foi dividida em duas fases porque
  ! ela pode ser chamada MAIS DE UMA VEZ. O laco de resolucao de dependencia
  ! de dados do driver NUOPC percorre a RunSequence repetidamente, executando
  ! o Run dos conectores e o label_DataInitialize dos componentes, ate que
  ! todos declarem InitializeDataComplete. Se o MED declarasse "true"
  ! incondicionalmente na primeira passagem, o laco pararia ali.
  !
  ! Na RunSequence SEQUENCIAL o conector "OCN -> MED" vem ANTES do elemento
  ! "OCN", ou seja, antes de o mom_cap escrever So_t em InitializeDataComplete.
  ! Com uma unica passagem, o So_t que chega aqui e' o campo ainda nao
  ! preenchido. Na RunSequence CONCORRENTE a ordem e' inversa ("OCN" antes de
  ! "OCN -> MED"), e uma unica passagem bastaria, mas so' por acidente de
  ! ordenacao. O pet_layout nao tem parte nisso: o mesmo problema ocorreria
  ! em sequential+shared.
  !
  ! O FieldRegridStore abaixo depende so' da GEOMETRIA dos campos, nunca dos
  ! valores, entao permanece na primeira passagem — e' caro e nao deve repetir.
  !==========================================================================
    if (.not. is%regrid%has('ocn2atm')) then
      call idc_create_routes(is, importState, exportState, exp_field, rc)
      if (rc /= ESMF_SUCCESS) return
    end if

  !==========================================================================
  ! GATE DE DADOS — So_t ja' foi escrito pelo OCN?
  !
  ! O mom_cap (e o DOCN) carimbam TODOS os campos exportados com startTime em
  ! seu InitializeDataComplete, e o conector NUOPC propaga o carimbo ao campo
  ! de destino. Portanto NUOPC_IsAtTime distingue exatamente os dois casos:
  ! So_t recem-chegado do oceano (carimbado) contra o campo ainda nao escrito
  ! (sem carimbo). Carimbo, porem, nao e' dado: ver sst_has_physical_values.
  !
  ! Enquanto o dado nao chega, declaramos Progress=true (a fase A progrediu:
  ! os routehandles existem) e Complete=false. Isso forca o driver a percorrer
  ! a RunSequence outra vez; na segunda passagem o "OCN -> MED" ja' encontra o
  ! So_t escrito pelo "OCN" da passagem anterior, e o gate abre.
  !==========================================================================
    call ESMF_ClockGet(clock, startTime=startTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha So_t (gate)", &
      line=__LINE__, file=__FILE__)) return

    sst_ready = NUOPC_IsAtTime(ocn_field, startTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (sst_ready) then
      call sst_has_physical_values(ocn_field, sst_ready, rc)
      if (rc /= ESMF_SUCCESS) return
    end if

    if (.not. sst_ready) then
      call idc_wait_for_sst(gcomp, is, rc)
      return
    end if

  !==========================================================================
  ! FASE B — DADOS (So_t valido em maos)
  !==========================================================================
    call idc_publish_initial_sst(is, importState, exportState, ocn_field)
    call idc_stamp_export(exportState, startTime, rc)

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", value="true", rc=rc)
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", value="true", rc=rc)

    call ESMF_LogWrite('MED: InitializeDataComplete SATISFIED (So_t em t=0)', &
      ESMF_LOGMSG_INFO)
  end subroutine InitializeDataComplete

  !> Confere que o campo de referencia da grade ATM existe no importState:
  !! Sa_u10m_mpas no modo MPAS, Sa_u10m no modo DATM (is%use_mpas_atm, lido
  !! em InitializeRealize). rc de falha quando o campo nao existe.
  subroutine idc_check_atm_field(is, importState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    integer, intent(inout) :: rc
    type(ESMF_Field) :: atm_field

    if (is%use_mpas_atm) then
      call ESMF_StateGet(importState, itemName="Sa_u10m_mpas", &
        field=atm_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED IDC: Sa_u10m_mpas nao encontrado", &
        line=__LINE__, file=__FILE__)) return
    else
      call ESMF_StateGet(importState, itemName="Sa_u10m", &
        field=atm_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED IDC: Sa_u10m nao encontrado", &
        line=__LINE__, file=__FILE__)) return
    end if
  end subroutine idc_check_atm_field

  !> CARIMBO NAO E' DADO: com So_t carimbado (sst_ready), exige tambem VALOR
  !! fisicamente plausivel, em [270,310] K, em alguma celula, contado
  !! GLOBALMENTE (um DE pode legitimamente conter so' terra e gelo). Sem
  !! nenhuma, sst_ready passa a .false.
  !!
  !! O mom_cap aplica NUOPC_SetTimestamp a TODOS os campos do exportState em
  !! seu InitializeDataComplete, em laco cego sobre o itemNameList, sem
  !! verificar quais deles o mom_export realmente preencheu. Um So_t
  !! identicamente nulo passa no NUOPC_IsAtTime. Foi o que aconteceu quando
  !! ocean_model_init_sfc nao era chamado: o gate abria, o mediador seguia, e
  !! a extrapolacao da secao 3 convertia o campo inteiro em T_FILL=271.35 K,
  !! o que levava a mascara de terra, entao baseada na SST, a classificar o
  !! planeta inteiro como terra e zerar os 11 campos de fluxo.
  !!
  !! Coletivo sobre a VM do MED (ESMF_VMAllReduce): todos os PETs do
  !! mediador entram aqui.
  subroutine sst_has_physical_values(ocn_field, sst_ready, rc)
    type(ESMF_Field), intent(in) :: ocn_field
    logical, intent(inout) :: sst_ready
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: sstp(:,:)
    type(ESMF_VM) :: vm
    character(len=160) :: msg_gate
    integer :: lde, ldec_sst, localrc
    integer :: n_phys_s(1), n_phys_g(1)

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    n_phys_s(1) = 0
    call ESMF_FieldGet(ocn_field, localDeCount=ldec_sst, rc=localrc)
    if (localrc == ESMF_SUCCESS) then
      do lde = 0, ldec_sst - 1
        nullify(sstp)
        call ESMF_FieldGet(ocn_field, localDe=lde, farrayPtr=sstp, rc=localrc)
        if (localrc /= ESMF_SUCCESS .or. .not. associated(sstp)) cycle
        n_phys_s(1) = n_phys_s(1) + &
          count(sstp > 270.0_ESMF_KIND_R8 .and. sstp < 310.0_ESMF_KIND_R8)
      end do
    end if

    call ESMF_VMAllReduce(vm, n_phys_s, n_phys_g, 1, ESMF_REDUCE_SUM, rc=localrc)
    if (localrc /= ESMF_SUCCESS) n_phys_g(1) = n_phys_s(1)

    if (n_phys_g(1) == 0) then
      sst_ready = .false.
      call ESMF_LogWrite('MED: IDC — So_t carimbado mas SEM valor fisico '// &
        '(nenhuma celula em [270,310] K no globo)', ESMF_LOGMSG_WARNING)
    else
      write(msg_gate,'(A,I0,A)') 'MED: IDC — So_t com ', n_phys_g(1), &
        ' celulas em [270,310] K'
      call ESMF_LogWrite(trim(msg_gate), ESMF_LOGMSG_INFO)
    end if
  end subroutine sst_has_physical_values

  !> So_t ainda sem dado: pede ao driver mais uma iteracao do laco de
  !! dependencia de dados (Progress=true, Complete=false). Depois de
  !! MAX_GATE_TRIES tentativas, avisa e declara Complete=true.
  !!
  !! Falhar alto em vez de seguir com SST nula: era exatamente esse
  !! prosseguimento silencioso que produzia mapas de fluxo em branco no
  !! passo 1, com a causa escondida a tres camadas de distancia.
  subroutine idc_wait_for_sst(gcomp, is, rc)
    type(ESMF_GridComp) :: gcomp
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    integer, parameter :: MAX_GATE_TRIES = 5

    is%run%n_gate_tries = is%run%n_gate_tries + 1
    if (is%run%n_gate_tries >= MAX_GATE_TRIES) then
      ! AVISO, nao aborto. O modelo de como o driver NUOPC percorre a
      ! RunSequence durante a resolucao de dependencia de dados ainda nao
      ! esta plenamente verificado: o gate ja' foi observado fechando uma
      ! vez em coupling_mode='concurrent', onde a ordem dos elementos
      ! preveria abertura imediata. Enquanto essa discrepancia nao for
      ! entendida, abortar aqui arriscaria derrubar execucoes que hoje
      ! funcionam. O aviso e' alto e nomeia o que inspecionar; o
      ! comportamento anterior a este gate e' preservado.
      call ESMF_LogWrite('MED: AVISO — So_t sem valores fisicos apos '// &
        'varias iteracoes do laco de dependencia de dados; prosseguindo.', &
        ESMF_LOGMSG_WARNING)
      call ESMF_LogWrite('  A SST em t=0 pode estar nula. Inspecione '// &
        '"So_t BRUTO" e "[MED-DIAG] f_sst_atm" no passo 1 antes de '// &
        'confiar nos fluxos.', ESMF_LOGMSG_WARNING)
      call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", &
        value="true", rc=rc)
      call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
        value="true", rc=rc)
      return
    end if
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", &
      value="true", rc=rc)
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
      value="false", rc=rc)
    call ESMF_LogWrite('MED: IDC aguardando So_t do OCN — '// &
      'nova iteracao do laco de dependencia de dados', ESMF_LOGMSG_INFO)
  end subroutine idc_wait_for_sst

  !> Fase B de InitializeDataComplete: correntes e SST de t=0 na grade ATM.
  !!
  !! Primeiro regrid de So_u e So_v para is%ocn%u/is%ocn%v, pela rota
  !! 'ocn2atm' (bilinear, criada na fase A): So_u/So_v compartilham a grade
  !! OCN de So_t. Depois, a SST de t=0: sem ela, is%ocn%sst ficaria no valor
  !! de bootstrap SST_BULK_FALLBACK ate' o primeiro MediatorAdvance, e o
  !! conector MED -> MPAS entregaria essa constante ao MPAS. A SST e'
  !! publicada no exportState (zerado na fase A), para que o "MED -> MPAS"
  !! desta mesma passagem entregue SST fisica, e nao zero.
  subroutine idc_publish_initial_sst(is, importState, exportState, ocn_field)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: ocn_field
    integer :: localrc

    call regrid_ocean_currents(is, importState, zero_on_error=.true.)

    call is%regrid%apply('ocn2atm', ocn_field, is%ocn%sst, localrc, &
          zero_total=.true.)
    if (localrc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: IDC — regrid So_t->ATM falhou; '// &
        'mantido SST_BULK_FALLBACK', ESMF_LOGMSG_WARNING)
    else
      call RegridOrCopy(is%ocn%sst, exportState, "So_t", is, localrc)
      if (localrc /= ESMF_SUCCESS) &
        call ESMF_LogWrite('MED: IDC — RegridOrCopy So_t falhou', &
          ESMF_LOGMSG_WARNING)
    end if
  end subroutine idc_publish_initial_sst

  !> Carimba os campos exportados com startTime: e' o que permite ao MPAS
  !! (e a qualquer consumidor futuro) aplicar o mesmo gate NUOPC_IsAtTime.
  subroutine idc_stamp_export(exportState, startTime, rc)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Time), intent(in) :: startTime
    integer, intent(inout) :: rc
    type(ESMF_Field) :: exp_field
    character(len=64), allocatable :: fieldNameList(:)
    integer :: fieldCount
    integer :: i
    integer :: localrc

    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (fieldCount > 0) then
      allocate(fieldNameList(fieldCount))
      call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
      do i = 1, fieldCount
        call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
          field=exp_field, rc=localrc)
        if (localrc == ESMF_SUCCESS) &
          call NUOPC_SetTimestamp(exp_field, startTime, rc=localrc)
      end do
      deallocate(fieldNameList)
    end if
  end subroutine idc_stamp_export

  !============================================================================
  ! MediatorAdvance - com fallback MPAS -> DATM
  !
  ! Etapas: med_stamp_time, zero_med_fluxes, get_atm_forcing,
  ! gather_atm_forcing, local_atm_bounds, update_ocean_fields_on_atm_grid,
  ! update_ice_fraction_from_docn, calc_bulk_ncar, apply_native_fluxes,
  ! export_to_components, stamp_export_fields, RouteOcnToAtm,
  ! log_ifrac_export_bitsum e med_write_import_fields.
  !============================================================================
  subroutine MediatorAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)         :: importState, exportState
    type(ESMF_Clock)         :: clock
    type(ESMF_Time)          :: currTime, nextTime
    ! instante que representa o CONTEUDO desta execucao do mediador (ver
    ! med_stamp_time).
    type(ESMF_Time)          :: stampTime
    type(ESMF_TimeInterval)  :: dt
    type(ESMF_Field)         :: field
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: localDeCount_med  ! guard para PETs sem DE local
    logical :: proceed

    ! Forcantes atmosfericos na grade ATM local (MPAS ou DATM)
    real(ESMF_KIND_R8), pointer :: uas(:,:), vas(:,:), tas(:,:), shum(:,:)
    real(ESMF_KIND_R8), pointer :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8), pointer :: rain(:,:), snow(:,:)
    ! fluxos nativos do PBL do MONAN-A (opcionais — ausencia mantem
    ! o fallback bulk NCAR via calc_bulk_ncar, ex. modo DATM)
    real(ESMF_KIND_R8), pointer :: sen_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: lat_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: taux_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: tauy_mpas(:,:) => null()
    ! valores padrao quando Sa_shum_mpas / Faxa_snow_mpas estao ausentes
    real(ESMF_KIND_R8), pointer     :: shum_local(:,:) => null()
    real(ESMF_KIND_R8), pointer     :: snow_local(:,:) => null()
    integer :: i1, i2, j1, j2
    ! Forcantes reunidos na grade ATM global (1:ATM_NX, 1:ATM_NY)
    real(ESMF_KIND_R8), allocatable :: uas_g(:,:), vas_g(:,:), tas_g(:,:)
    real(ESMF_KIND_R8), allocatable :: psl_g(:,:), swdn_g(:,:), lwdn_g(:,:)
    real(ESMF_KIND_R8), allocatable :: rain_g(:,:), shum_g(:,:), snow_g(:,:)
    real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:) => null()

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap

    ! NUOPC_MediatorGet e ESMF_ClockGet sao chamados ANTES da guarda
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

    !==========================================================================
    ! zerar f_*_atm antes do bulk para evitar persistência de
    ! valores não inicializados em células fora do alcance de uas/vas
    ! (grade MPAS Voronoi parcialmente sobreposta à grade MED regular).
    ! O loop bulk só preenche (i1:i2, j1:j2) = lbound:ubound(uas); sem
    ! zerar antes, regiões sem dados MPAS aparecem como lixo nos plots.
    !==========================================================================
    call zero_med_fluxes(is, rc)

    !==========================================================================
    ! 1 e 2. FORCANTES ATMOSFERICOS: MPAS (primario) ou DATM (fallback)
    !==========================================================================
    call get_atm_forcing(is, importState, uas, vas, tas, shum, psl, swdn, lwdn, &
                         rain, snow, shum_local, snow_local,                     &
                         sen_mpas, lat_mpas, taux_mpas, tauy_mpas, proceed, rc)
    if (.not. proceed) return

    i1 = lbound(uas,1); i2 = ubound(uas,1)
    j1 = lbound(uas,2); j2 = ubound(uas,2)

    ! Forcantes reunidos na grade ATM global em todos os PETs do mediador
    call gather_atm_forcing(uas, vas, tas, psl, swdn, lwdn, rain, shum, snow, &
                            i1, i2, j1, j2, is%par%comm,                       &
                            uas_g, vas_g, tas_g, psl_g, swdn_g, lwdn_g,        &
                            rain_g, shum_g, snow_g, is%run%first_forcing_summary, rc)

    ! Os arrays globais cobrem 1..ATM_NX, 1..ATM_NY; os campos internos
    ! (is%ocn_flx%*, is%ice%* etc.) tem os limites LOCAIS da DE do PET. O
    ! bulk percorre os limites locais, acessando os arrays globais nas mesmas coordenadas.
    call local_atm_bounds(is, i1, i2, j1, j2, rc)

    !==========================================================================
    ! 3. SST: regrid OCN -> ATM (So_t esta na grade OCN)
    !
    ! Mascara terra/oceano: o mom_cap_methods::state_setexport multiplica a
    ! SST por ocean_grid%mask2dT antes do export; sobre terra, SST=0 K na
    ! grade OCN. Um regrid bilinear sem mascara misturaria esses zeros nas
    ! celulas oceanicas proximas a costa, que cairiam abaixo de 270 K (o
    ! postproc as marcaria como "fill"). A mascara nao e' adivinhada pelo
    ! proprio valor da SST: vem de So_omask = nint(mask2dT), exportada pelo
    ! MOM6 (mom_cap_methods.F90::mom_export). Assim o bilinear so' usa celulas
    ! OCEANICAS VALIDAS como fonte da interpolacao. O residuo nao mapeado na
    ! costa (sem vizinho valido) e' tratado pela extrapolacao por vizinhanca.
    !==========================================================================
    call update_ocean_fields_on_atm_grid(is, importState, field, is%run%raw_sst_diag_done, rc)

    !==========================================================================
    ! 3b. Si_ifrac do OISST (use_docn_ice)
    !
    ! Modos (nuopc.input &nuopc_mode):
    !   use_docn_ice=T  init_only=F  → fill_ifrac_from_oisst a cada passo
    !     (campo congelado em OISST).
    !   use_docn_ice=T  init_only=T  → fill_ifrac_from_oisst apenas na 1ª
    !     MediatorAdvance (flag is%run%ifrac_init_done); nas demais, o campo
    !     decai exponencialmente (SI_IFRAC_DECAY, de coupler_constants).
    !   use_docn_ice=F               → nada a fazer aqui; com SIS2 dinamico,
    !     Si_ifrac ja' veio do gelo na secao 3.
    !==========================================================================
    call update_ice_fraction_from_docn(is, clock, ifrac_ptr, rc)
    ! init_only=F: field preenchido a cada passo via fill_ifrac_from_oisst
    ! use_docn_ice=F: is%ice%ifrac fica como saiu da secao 3

    !==========================================================================
    ! 4. CALCULAR BULK NCAR — delegado ao módulo med_bulk_ncar_mod
    !==========================================================================
    call calc_bulk_ncar(is, importState, &
                        uas_g, vas_g, tas_g, psl_g, swdn_g, lwdn_g, rain_g, shum_g, snow_g, &
                        i1, i2, j1, j2, clock, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: calc_bulk_ncar falhou', &
      line=__LINE__, file=__FILE__)) return

    call apply_native_fluxes(is, sen_mpas, lat_mpas, taux_mpas, tauy_mpas, rc)

    !==========================================================================
    ! 5. REGRID E EXPORTA PARA O OCEANO
    !
    ! RegridOrCopy leva cada campo interno (grade ATM) ao exportState (grade
    ! OCN) pela rota 'atm2ocn'; sem a rota, copia direto, para que os campos
    ! exportados nao fiquem zerados silenciosamente.
    !
    ! Antes do export, os fluxos sobre terra sao zerados no proprio MED
    ! (zero_fluxes_over_land). O bulk NCAR roda em TODAS as celulas da grade
    ! ATM (oceano + terra); com T_2m, U_10m e P_slv continentais, produz
    ! fluxos enormes sobre terra (Foxx_sen saturando em +-500 W/m^2;
    ! Foxx_lwnet em -300 W/m^2 sobre o Saara). O MOM6 descarta essas celulas
    ! em state_setexport (mask2dT), mas o diagnostico NetCDF do MED e' escrito
    ! antes dessa mascara.
    !
    ! A mascara de terra e' So_omask interpolada para a grade ATM uma unica
    ! vez (regrid_land_mask, NEAREST_STOD: so' precisa distinguir terra e
    ! oceano). Uma heuristica pela SST (celulas de terra com exatamente
    ! 271,35 K) colidiria com agua aberta no ponto de congelamento (borda do
    ! gelo).
    !==========================================================================
    call export_to_components(is, importState, exportState, rc)
    if (allocated(uas_g)) deallocate(uas_g)
    if (allocated(vas_g)) deallocate(vas_g)
    if (allocated(tas_g)) deallocate(tas_g)
    if (allocated(psl_g)) deallocate(psl_g)
    if (allocated(swdn_g)) deallocate(swdn_g)
    if (allocated(lwdn_g)) deallocate(lwdn_g)
    if (allocated(rain_g)) deallocate(rain_g)
    if (allocated(shum_g)) deallocate(shum_g)
    if (allocated(snow_g)) deallocate(snow_g)

    ! Atualizar timestamps do exportState
    call stamp_export_fields(exportState, field, stampTime, rc)

    call ESMF_LogWrite('MED: MediatorAdvance concluido', ESMF_LOGMSG_INFO)

    ! ── RouteOcnToAtm — exportar SST/gelo MOM6 dinâmico ao MPAS ────
    ! Chamado quando use_med_to_mpas=.true. (nuopc_mode).
    ! Preenche os campos So_t, Si_ifrac, So_u, So_v no exportState do MED
    ! para que o conector MED→MPAS entregue a SST dinâmica ao MPAS.
    ! Sem esta chamada, o MPAS recebe exportState vazio (campos zerados).
    if (is%use_med_to_mpas) then
      call RouteOcnToAtm(importState, exportState, clock, is, rc)
      if (rc /= ESMF_SUCCESS) then
        call ESMF_LogWrite('MED: RouteOcnToAtm retornou erro — continuando', &
          ESMF_LOGMSG_WARNING)
        rc = ESMF_SUCCESS
      end if
    end if

    ! Si_ifrac como sai do mediador (etapa 4 de 4 do FIX-DIAG-BITSUM-01)
    if (cfg_write_fixdiag) call log_ifrac_export_bitsum(exportState)

    call med_write_import_fields(exportState, stampTime, is, rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS  ! nao-fatal
    ! Liberar arrays temporarios de defaults (se alocados)
    if (associated(shum_local)) then
      deallocate(shum_local); nullify(shum_local)
    end if
    if (associated(snow_local)) then
      deallocate(snow_local); nullify(snow_local)
    end if
  end subroutine MediatorAdvance

  !============================================================================
  !> @brief Instante que rotula o resultado desta execucao do mediador.
  !!
  !! O instante que rotula o resultado do
  !! mediador depende de ONDE o elemento 'MED' esta na RunSequence.
  !!
  !! O relogio do mediador marca currTime = t durante toda a execucao do passo,
  !! nos dois modos: o NUOPC so' avanca o relogio depois que o Advance retorna.
  !! O que muda e' o conteudo que chega ao importState:
  !!
  !!   concurrent : 'MED' e' o ULTIMO elemento do passo. Os conectores
  !!                'MPAS -> MED', 'OCN -> MED' e 'ICE -> MED' ja' rodaram
  !!                DEPOIS dos avancos, entao os campos importados descrevem o
  !!                estado em t+dt. O rotulo correto e' nextTime.
  !!
  !!   sequential : 'MED' e' o QUARTO elemento, ANTES de 'MPAS', 'OCN' e 'ICE'.
  !!                Os conectores que o alimentam rodaram no inicio do passo, e
  !!                os campos importados descrevem o estado em t (o que cada
  !!                componente escreveu no fim do passo anterior). O rotulo
  !!                correto e' currTime.
  !!
  !! Usar nextTime tambem no modo sequencial teria duas consequencias:
  !!
  !!   (a) Todo arquivo de diagnostico mom6_import_YYYYMMDD_HHMMSS.nc e
  !!       monan2_import_YYYYMMDD_HHMMSS.nc sairia com o nome e a variavel de
  !!       tempo adiantados em um dt_coupling em relacao ao dado que contem.
  !!       Uma rodada sequential e uma concurrent ficariam deslocadas de um
  !!       passo, e as animacoes, fora de fase.
  !!   (b) O exportState seria carimbado com t+dt e entregue a componentes
  !!       cujo relogio marca t. Os tres caps usam CheckImport tolerante
  !!       (janela de +/- dt_coupling) ou no-op, entao isso nao abortaria a
  !!       execucao; passaria sem sinal nenhum. Com currTime o carimbo
  !!       coincide exatamente com o relogio do consumidor.
  !!
  !! No modo concorrente, stampTime = nextTime.
  !!--------------------------------------------------------------------------
  !! seq_repro: na variante REPRODUTIVEL do sequential+split+SIS2 o elemento
  !! 'MED' roda no FIM do passo (mesma coreografia do concurrent), portanto os
  !! campos importados descrevem o estado em t+dt e o rotulo correto e'
  !! nextTime — nao currTime. Sem o '.and. .not. cfg_seq_repro' o carimbo
  !! sairia adiantado de um dt e quebraria a comparacao bit-a-bit contra o
  !! concurrent. O sequential classico (cfg_seq_repro=.false.) usa
  !! 'MED' cedo -> currTime; o concurrent usa nextTime.
  !!
  !! @param[in] currTime  instante corrente do relogio do mediador
  !! @param[in] nextTime  currTime + dt_coupling
  !! @return             currTime no sequencial classico, nextTime nos demais
  !============================================================================
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

