!> @file mpas_cap_MONAN.F90
!! @brief Cap NUOPC/ESMF para o modelo atmosferico MPAS-A 8.3 / MONAN-A 2.0.
!!
!! Protocolo NUOPC completo via NUOPC_CompDerive (InitializeAdvertise,
!! InitializeRealize, DataInitialize, ModelAdvance, ModelFinalize). O
!! cap exporta a forcante atmosferica do MONAN-A ao mediador e importa dele
!! a superficie do oceano e do gelo (PONTO_ATM, abaixo). A troca com o
!! MPAS-A fica em mpas_cap_methods.F90, e os diagnosticos NetCDF em
!! mpas_cap_netcdf.F90 e mpas_import_diag.F90.
!!
!! As coordenadas para o NetCDF vem de lonCell(1:n_local), com
!! n_local = min(localCells_ESMF, nCells_MPAS), e nao de ownedElemCoords,
!! que causa double-free no ESMF 8.9.1 em Cray/gfortran. O historico das
!! versoes 7.0 a 9.2 deste cap esta em docs/CHANGELOG.md.

module mpas_cap_MONAN_mod

  use ESMF
  use coupler_constants_mod, only : RAD2DEG, ALB_OCEAN_DEFAULT
  use NUOPC,       only : NUOPC_CompDerive,        NUOPC_CompSpecialize,   &
                           NUOPC_CompSetEntryPoint, NUOPC_CompFilterPhaseMap, &
                           NUOPC_Advertise,         NUOPC_Realize,           &
                           NUOPC_CompAttributeGet,  NUOPC_CompAttributeSet,  &
                           NUOPC_IsConnected
  use NUOPC_Model, only : model_routine_SS           => SetServices,          &
                           model_label_CheckImport    => label_CheckImport,  &
                           model_label_DataInitialize => label_DataInitialize, &
                           model_label_Advance        => label_Advance,        &
                           model_label_Finalize       => label_Finalize,       &
                           NUOPC_ModelGet,             SetVM

  use mpas_atm_types_mod,   only : mpas_atm_public_type,    &
                                    mpas_atm_state_type,     &
                                    atm_ocean_boundary_type

  use mpas_atm_model_mod,   only : mpas_atm_init, mpas_atm_init_sfc, mpas_atm_run, &
                                    mpas_atm_final

  use mpas_cap_methods_mod, only : mpas_import,         &
                                    mpas_export,         &
                                    mpas_create_grid,    &
                                    state_diagnose

  use mpas_cap_netcdf_mod,  only : export_write_netcdf, &
                                    mpas_diag_export_t,  &
                                    netcdf_init_coords,  &
                                    netcdf_config_set
  use mpas_import_diag_mod, only : mpas_import_diag_clock_t, &
                                    set_mpas_diag_clock   ! timestamp do diag import (mpas_import_diag)

  use coupler_config_mod,  only : cfg_write_netcdf, cfg_write_diag, &
                                    cfg_config_dir,                   &
                                    cfg_dt_coupling, cfg_dt_atm,      &
                                    cfg_output_dir, cfg_grid_res_deg, &
                                    cfg_sst_default,                  &
                                    cfg_ice_fraction_default,         &
                                    cfg_zorl_default

  use coupler_utils_mod,   only : ChkErr, int_to_str
  use cap_common_mod,      only : cap_initialize_p0, cap_realize_fields
  use cpl_fields_mod,      only : CPL_NOME_LEN
  use cpl_map_mod,         only : cpl_chegadas, cpl_exportacoes, cpl_config_atual

  implicit none
  private


  public :: SetServices
  public :: SetVM

  !> Estado interno do cap, guardado no componente ESMF
  !! (ESMF_GridCompSetInternalState) e recuperado em cada fase por
  !! get_cap_state. Criado em InitializeRealize.
  type :: mpas_cap_state_t
    type(mpas_atm_public_type),    pointer :: atm_public => null()
    type(mpas_atm_state_type),     pointer :: atm_state  => null()
    type(atm_ocean_boundary_type), pointer :: atm_bnd    => null()
    type(ESMF_Grid) :: grid   !< grade regular 360x180 do cap
    !> Gravador monan_export_*.nc: grade de saída, coordenadas e campos
    !! MPAS guardados. Configurado em InitializeRealize.
    type(mpas_diag_export_t) :: diag_export
    !> Relógio do diagnóstico de importação monan2_import_*.nc.
    type(mpas_import_diag_clock_t) :: diag_clock
    integer :: step_count = 0   !< passos de acoplamento já executados
  end type mpas_cap_state_t

  type :: mpas_cap_state_wrapper_t
    type(mpas_cap_state_t), pointer :: ptr => null()
  end type mpas_cap_state_wrapper_t

  ! ── Campos importados do mediador (MED→MPAS) ───────────────────────────────
  !
  ! O NUOPC só cria RouteHandle para campos MUTUAMENTE anunciados: o MED
  ! anuncia estes campos no exportState, e o MPAS os anuncia espelhadamente
  ! no importState (este array).
  !
  ! Sx_tsfc (e nao So_t) alimenta atm_bnd%sst: So_t e' a SST pura do MOM6,
  ! que o SIS2 tambem importa e precisa pura para o fluxo de calor basal do
  ! gelo (ICE_KMELT); Sx_tsfc e' o composto (1-Si_ifrac)*So_t +
  ! Si_ifrac*Si_t_sis2, calculado no MED (med_export.F90) para a atmosfera, que
  ! enxerga uma unica celula mista agua+gelo.
  !
  ! Sf_zorl e' a rugosidade calculada no MED por Charnock + Smith a partir de
  ! Foxx_taux/tauy, no lugar do valor fixo cfg_zorl_default = 0.01 m
  ! (realimentacao vento <-> rugosidade, importante em tempestades).
  !
  ! Sx_omask e' a mascara terra/oceano REAL do MOM6 (ocean_grid%mask2dT).
  ! Nao alimenta a fisica do MONAN-A, que tem a propria landmask; serve para
  ! mascarar continentes no diagnostico monan2_import_*.nc, em vez de contar
  ! so' com o filtro ocean_frac_min do binning Voronoi, um criterio de
  ! COBERTURA de celula Voronoi por bin, sem relacao com terra/oceano.
  !
  ! Os campos saem do mapa de acoplamento (src/coupling/cpl_map.F90), no
  ! ponto ATM@atm_cap: a importacao sao os 7 campos que chegam por conector
  ! (cpl_chegadas: Sx_tsfc, Si_ifrac, So_u, So_v, Sf_zorl, Sf_albedo e
  ! Sx_omask), e a exportacao, os 13 campos *_mpas de EXPORTACOES
  ! (cpl_exportacoes), a forcante nativa do MONAN-A. O cap anuncia sempre as
  ! mesmas listas: nao consulta chaves de &nuopc_mode. O valor inicial de
  ! cada campo importado esta em valor_inicial_importacao.
  character(len=*), parameter :: PONTO_ATM = 'ATM@atm_cap'

  character(len=*), parameter :: u_FILE_u = __FILE__

contains

  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp) :: gcomp
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         userRoutine=InitializeP0, phase=0, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         phaseLabelList=(/'IPDv03p1'/), userRoutine=InitializeAdvertise, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         phaseLabelList=(/'IPDv03p3'/), userRoutine=InitializeRealize, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_CompSpecialize(gcomp, &
         specLabel=model_label_DataInitialize, &
         specRoutine=InitializeDataComplete, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_CompSpecialize(gcomp, &
         specLabel=model_label_Advance, &
         specRoutine=ModelAdvance, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_CompSpecialize(gcomp, &
         specLabel=model_label_Finalize, &
         specRoutine=ModelFinalize, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    ! Suprimir validacao de timestamp de import (lag OCN->MPAS: t-1 != currTime)
    call NUOPC_CompSpecialize(gcomp, &
         specLabel=model_label_CheckImport, &
         specRoutine=CheckImportAlwaysOK, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_LogWrite('mpas_cap: SetServices concluido (v7.0 NUOPC_CompDerive)', &
         ESMF_LOGMSG_INFO)
  end subroutine SetServices

  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp) :: gcomp
    type(ESMF_State)    :: importState, exportState
    type(ESMF_Clock)    :: clock
    integer,             intent(out) :: rc
    type(ESMF_Time)    :: startTimeLoc
    character(len=32)  :: value
    integer            :: yr, mo, dy, hr, mn, sc
    character(len=*), parameter :: subname = '(mpas_cap:InitializeP0)'
    rc = ESMF_SUCCESS
    call cap_initialize_p0(gcomp, importState, exportState, clock, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_ClockGet(clock, startTime=startTimeLoc, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_TimeGet(startTimeLoc, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    write(value, '(I4.4,"-",I2.2,"-",I2.2,"T",I2.2,":",I2.2,":",I2.2)') &
          yr, mo, dy, hr, mn, sc
    call ESMF_LogWrite(subname//': start_time = '//trim(value), ESMF_LOGMSG_INFO)
    call ESMF_LogWrite(subname//': InitializeP0 concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeP0

  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp) :: gcomp
    type(ESMF_State)    :: importState, exportState
    type(ESMF_Clock)    :: clock
    integer,             intent(out) :: rc
    integer :: i
    character(len=CPL_NOME_LEN), allocatable :: imp(:), exp(:)
    character(len=*), parameter :: subname = '(mpas_cap:InitializeAdvertise)'
    rc = ESMF_SUCCESS
    call cpl_chegadas(PONTO_ATM, .true., cpl_config_atual(), '', imp)
    call cpl_exportacoes(PONTO_ATM, cpl_config_atual(), '', exp)
    do i = 1, size(imp)
      call NUOPC_Advertise(importState, StandardName=trim(imp(i)), rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end do
    do i = 1, size(exp)
      call NUOPC_Advertise(exportState, StandardName=trim(exp(i)), rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end do
    call ESMF_LogWrite(subname//': anunciados '// &
         int_to_str(size(imp))//' imp + '// &
         int_to_str(size(exp))//' exp', ESMF_LOGMSG_INFO)
  end subroutine InitializeAdvertise

  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp) :: gcomp
    type(ESMF_State)    :: importState, exportState
    type(ESMF_Clock)    :: clock
    integer,             intent(out) :: rc
    type(ESMF_VM)      :: vm
    integer            :: localMpiComm, localPet
    type(mpas_cap_state_wrapper_t) :: wrap
    type(mpas_cap_state_t), pointer :: st
    character(len=*), parameter :: subname = '(mpas_cap:InitializeRealize)'
      real(ESMF_KIND_R8), allocatable :: lon_local_nc(:)
      real(ESMF_KIND_R8), allocatable :: lat_local_nc(:)
      integer :: k
      integer :: n_local
    character(len=CPL_NOME_LEN), allocatable :: nomes(:)
    rc = ESMF_SUCCESS

    ! ── 0. VM: obter localMpiComm e localPet ANTES de qualquer outra chamada ─
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_VMGet(vm, localPet=localPet, mpiCommunicator=localMpiComm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! Estado interno do cap, guardado no componente
    allocate(wrap%ptr)
    st => wrap%ptr
    call ESMF_GridCompSetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! ── 1. ESMF_Grid 360x180 (ANTES de mpas_atm_init) ────────────────────
    ! SOLUCAO DEFINITIVA: ESMF_Grid nao usa MOAB. Zero deadlocks possiveis.
    ! Criado ANTES do SMIOL (mpas_atm_init) para MPI completamente limpo.
    call mpas_create_grid(st%grid, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! ── 2. Campos ESMF e NUOPC_Realize (ANTES de mpas_atm_init) ──────────
    ! ESMF_FieldCreate sobre ESMF_Grid: sem MOAB, sem deadlock.
    ! ESMF_Grid distribui automaticamente -> todos os PETs tem celulas locais.
    call cpl_chegadas(PONTO_ATM, .true., cpl_config_atual(), '', nomes)
    call cap_realize_fields(importState, st%grid, nomes, size(nomes), rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call cpl_exportacoes(PONTO_ATM, cpl_config_atual(), '', nomes)
    call cap_realize_fields(exportState, st%grid, nomes, size(nomes), rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! ── 3. Inicializar MPAS-A (SMIOL começa aqui) ────────────────────────
    allocate(st%atm_public)
    allocate(st%atm_state)
    allocate(st%atm_bnd)
    call mpas_atm_init(st%atm_public, st%atm_state, st%atm_bnd, &
                       cfg_dt_atm, trim(cfg_config_dir), localMpiComm, rc)
    if (rc /= 0) then
      call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': mpas_atm_init falhou', &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if

    ! ── 4. Coordenadas NetCDF (MPI_Allgather apos SMIOL — seguro) ────────
      ! usar nCellsSolve (células próprias sem halos) para que a soma
      ! global em netcdf_init_coords seja exatamente 40962 (não 83897 com halos).
      n_local = st%atm_public%nCellsSolve
      if (n_local == 0) n_local = st%atm_public%nCells   ! fallback se não disponível
      allocate(lon_local_nc(n_local), lat_local_nc(n_local))
      do k = 1, n_local
        lon_local_nc(k) = real(st%atm_public%lonCell(k), ESMF_KIND_R8) * RAD2DEG
        lat_local_nc(k) = real(st%atm_public%latCell(k), ESMF_KIND_R8) * RAD2DEG
      end do
      call netcdf_config_set(st%diag_export, cfg_grid_res_deg, cfg_output_dir, localPet)
      call netcdf_init_coords(st%diag_export, lon_local_nc, lat_local_nc, n_local, vm, rc)
      deallocate(lon_local_nc, lat_local_nc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    if (allocated(lon_local_nc)) deallocate(lon_local_nc)
    if (allocated(lat_local_nc)) deallocate(lat_local_nc)

    call ESMF_LogWrite(subname//': InitializeRealize concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeRealize

  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp) :: gcomp
    integer,             intent(out) :: rc
    type(ESMF_State)  :: importState, exportState
    type(ESMF_Clock)  :: clock
    type(mpas_cap_state_t), pointer :: st
    character(len=*), parameter :: subname = '(mpas_cap:InitializeDataComplete)'
    rc = ESMF_SUCCESS
    call get_cap_state(gcomp, st, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_ModelGet(gcomp, &
         importState=importState, exportState=exportState, &
         modelClock=clock, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! barreira antes de qualquer leitura do
    ! importState. Ver o cabecalho de verify_import_connected para o motivo.
    call verify_import_connected(importState, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call init_import_defaults(importState, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call mpas_atm_init_sfc(st%atm_public, st%atm_state, rc)
    if (rc /= 0) then
      call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': mpas_atm_init_sfc falhou', &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if
    call mpas_export(st%diag_export, st%atm_public, exportState, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_CompAttributeSet(gcomp, &
         name='InitializeDataProgress', value='true', rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_CompAttributeSet(gcomp, &
         name='InitializeDataComplete', value='true', rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_LogWrite(subname//': DataInitialize SATISFIED', ESMF_LOGMSG_INFO)
  end subroutine InitializeDataComplete

  subroutine ModelAdvance(gcomp, rc)
    type(ESMF_GridComp) :: gcomp
    integer,             intent(out) :: rc
    type(ESMF_State)    :: importState, exportState
    type(ESMF_Clock)    :: clock
    type(ESMF_VM)       :: vm
    type(ESMF_Time)     :: currTimeLoc
    integer             :: yr, mo, dy, hr, mn, sc
    type(mpas_cap_state_t), pointer :: st
    character(len=*), parameter :: subname = '(mpas_cap:ModelAdvance)'
    rc = ESMF_SUCCESS
    call get_cap_state(gcomp, st, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call NUOPC_ModelGet(gcomp, &
         importState=importState, exportState=exportState, &
         modelClock=clock, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    st%step_count = st%step_count + 1

    ! ── Timestamp para o diagnóstico de importação ────────────────────────────
    ! Lê o tempo corrente do clock ANTES de mpas_import para que
    ! write_mpas_import_diag (acionado dentro de mpas_import quando
    ! cfg_write_import_diag=.true.) nomeie o arquivo como:
    !   monan2_import_YYYYMMDD_HHMMSS.nc
    ! Padrão idêntico ao dos campos importados pelo MOM6 (mom6_import_*.nc).
    call ESMF_ClockGet(clock, currTime=currTimeLoc, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_TimeGet(currTimeLoc, yy=yr, mm=mo, dd=dy, &
                      h=hr, m=mn, s=sc, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call set_mpas_diag_clock(st%diag_clock, yr, mo, dy, hr, mn, sc)

    ! usar nCellsSolve (células próprias sem halos) em vez de nCells.
    ! nCells inclui células halo de PETs vizinhos, que podem conter valores não
    ! inicializados ou de outra região geográfica, corrompendo os campos importados.
    call mpas_import(st%diag_clock, importState, st%atm_bnd, &
         merge(st%atm_public%nCellsSolve, st%atm_public%nCells, &
               st%atm_public%nCellsSolve > 0), rc, &
         st%atm_public%lonCell, st%atm_public%latCell)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    if (cfg_write_diag) then
      call state_diagnose(importState, 'importState@Advance', rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    call mpas_atm_run(st%atm_public, st%atm_state, st%atm_bnd, cfg_dt_coupling, rc)
    if (rc /= 0) then
      call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': mpas_atm_run falhou', &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if
    call mpas_export(st%diag_export, st%atm_public, exportState, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    if (cfg_write_diag) then
      call state_diagnose(exportState, 'exportState@Advance', rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (cfg_write_netcdf) then
      call ESMF_VMGetCurrent(vm, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      call ESMF_ClockGet(clock, currTime=currTimeLoc, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      call ESMF_TimeGet(currTimeLoc, yy=yr, mm=mo, dd=dy, &
                        h=hr, m=mn, s=sc, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      call export_write_netcdf(st%diag_export, exportState, st%step_count * cfg_dt_coupling, &
                                yr, mo, dy, hr, mn, sc, vm, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    call ESMF_LogWrite(subname//': ModelAdvance concluido', ESMF_LOGMSG_INFO)
  end subroutine ModelAdvance

  !> Recupera o estado interno do cap, criado em InitializeRealize.
  !! @param[inout] gcomp  componente do cap
  !! @param[out]   st     estado interno
  !! @param[out]   rc     código de retorno ESMF
  subroutine get_cap_state(gcomp, st, rc)
    type(ESMF_GridComp),             intent(inout) :: gcomp
    type(mpas_cap_state_t), pointer, intent(out)   :: st
    integer,                         intent(out)   :: rc

    type(mpas_cap_state_wrapper_t) :: wrap

    nullify(st)
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    st => wrap%ptr
  end subroutine get_cap_state

  subroutine ModelFinalize(gcomp, rc)
    type(ESMF_GridComp) :: gcomp
    integer,             intent(out) :: rc
    type(mpas_cap_state_t), pointer :: st
    character(len=*), parameter :: subname = '(mpas_cap:ModelFinalize)'
    rc = ESMF_SUCCESS
    call get_cap_state(gcomp, st, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call mpas_atm_final(st%atm_public, st%atm_state, st%atm_bnd, rc)
    if (rc /= 0) then
      call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': mpas_atm_final falhou', &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if
    ! Sem ESMF_GridDestroy: os campos do importState/exportState
    ! ainda referenciam st%grid quando ModelFinalize e chamado.
    ! Destruir o grid aqui causa SIGSEGV no cleanup posterior do framework.
    ! O ESMF finaliza o grid automaticamente em ESMF_Finalize.
    deallocate(st%atm_public, st%atm_state, st%atm_bnd)
    st%atm_public => null()
    st%atm_state  => null()
    st%atm_bnd    => null()
    call ESMF_LogWrite(subname//': ModelFinalize concluido', ESMF_LOGMSG_INFO)
  end subroutine ModelFinalize

  !> @brief Aborta se algum campo importado nao estiver conectado.
  !!
  !!
  !! O PROBLEMA. Quando o componente OCN nao oferece todos os campos que este
  !! cap anuncia, o NUOPC registra no log de PET
  !!     MPAS: Import Field not connected: <nome>
  !!     ERROR ... NUOPC INCOMPATIBILITY DETECTED: Import Fields not all connected
  !! e mesmo assim DEVOLVE ESMF_SUCCESS. O esmApp.F90 ja' confere o rc de
  !! ESMF_GridCompInitialize com ChkErr e abortaria se ele viesse com erro;
  !! como nao vem, a execucao segue. No primeiro passo o mpas_import le os
  !! campos importados assim mesmo, inclusive os que nunca foram realizados, e o
  !! ponteiro do farrayPtr de um campo nao conectado leva a SIGSEGV dentro do
  !! libesmf.so, com backtrace irresoluvel. Foi o que aconteceu no perfil
  !! MPAS+DOCN: tres campos faltando, morte sete
  !! segundos depois, sem nenhuma pista no esmApp_run.log.
  !!
  !! O CONSERTO. Verificar explicitamente, antes de tocar no importState, e
  !! abortar nomeando os campos ausentes. Custo: uma chamada a
  !! NUOPC_IsConnected por campo importado, uma vez por execucao.
  !!
  !! POR QUE AQUI E NAO NO DRIVER. A checagem precisa dos campos que este cap
  !! importa (do mapa, no ponto PONTO_ATM). Um guarda equivalente no esm.F90
  !! teria de percorrer os cplLists de cada conector e reconstruir a mesma
  !! informacao de segunda mao.
  !!
  !! ATENCAO: nao confundir com CheckImportAlwaysOK, logo abaixo. Aquela
  !! suprime a validacao de TIMESTAMP, que e' legitima porque o conector
  !! OCN->MPAS entrega com lag de um passo. Esta aqui verifica CONECTIVIDADE,
  !! que e' outra coisa: um campo desconectado nunca fica correto, em nenhum
  !! passo. Suprimir a primeira nao pode implicar em suprimir a segunda.
  subroutine verify_import_connected(importState, rc)
    type(ESMF_State), intent(in)  :: importState
    integer,          intent(out) :: rc

    character(len=*), parameter :: subname = '(mpas_cap:verify_import_connected)'
    integer            :: i, n_missing, localPet
    logical            :: connected
    character(len=512) :: missing
    character(len=640) :: msg
    type(ESMF_VM)      :: vm
    character(len=CPL_NOME_LEN), allocatable :: nomes(:)

    rc = ESMF_SUCCESS
    n_missing = 0
    missing   = ''
    call cpl_chegadas(PONTO_ATM, .true., cpl_config_atual(), '', nomes)

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    do i = 1, size(nomes)
      connected = NUOPC_IsConnected(importState, &
                                    fieldName=trim(nomes(i)), rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      if (.not. connected) then
        n_missing = n_missing + 1
        if (len_trim(missing) > 0) missing = trim(missing)//', '
        missing = trim(missing)//trim(nomes(i))
        call ESMF_LogWrite(subname//': campo de importacao NAO conectado: '// &
                           trim(nomes(i)), ESMF_LOGMSG_ERROR)
      end if
    end do

    if (n_missing > 0) then
      write(msg,'(A,I0,A,I0,A)') subname//': ABORTANDO — ', n_missing, &
        ' de ', size(nomes), ' campos de importacao nao estao conectados: '
      msg = trim(msg)//trim(missing)
      ! Tambem para a saida padrao: o log de PET nao e' lido quando o
      ! sintoma aparece so' no esmApp_run.log, e foi exatamente esse o
      ! ponto cego que custou dois jobs e um segfault opaco.
      if (localPet == 0) then
        write(*,'(A)') ''
        write(*,'(A)') '=============================================================='
        write(*,'(A)') ' ERRO FATAL: campos de importacao nao conectados'
        write(*,'(A)') '=============================================================='
        write(*,'(A)') ' '//trim(missing)
        write(*,'(A)') ''
        write(*,'(A)') ' O componente OCN configurado nao oferece todos os campos que'
        write(*,'(A)') ' o cap do MPAS anuncia (ATM@atm_cap no mapa de acoplamento).'
        write(*,'(A)') ' Prosseguir levaria a SIGSEGV no primeiro passo, ao ler um'
        write(*,'(A)') ' campo nunca realizado.'
        write(*,'(A)') ''
        write(*,'(A)') ' Verifique a combinacao ATM x OCN em &nuopc_mode:'
        write(*,'(A)') '   use_datm=F use_docn=F use_med=T -> MPAS + MOM6  (producao)'
        write(*,'(A)') '   use_datm=F use_docn=T use_med=F -> MPAS + DOCN  (Fase 1)'
        write(*,'(A)') '=============================================================='
        write(*,'(A)') ''
      end if
      call ESMF_LogSetError(ESMF_FAILURE, msg=trim(msg), &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if

    write(msg,'(A,I0,A)') subname//': todos os ', size(nomes), &
      ' campos de importacao estao conectados'
    call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)

  end subroutine verify_import_connected

  !> @brief Suprime validacao de timestamp dos campos de importacao.
  !!
  !! O conector OCN->MPAS fornece SST com lag de 1 passo (t-1), portanto
  !! os campos de importacao nunca tem timestamp = currTime. A validacao
  !! padrao NUOPC (label_CheckImport) geraria "INCOMPATIBILITY: Import Fields
  !! not at current time" em todos os 48 passos. Esta rotina substitui o
  !! CheckImport padrao com sucesso incondicional.
  subroutine CheckImportAlwaysOK(gcomp, rc)
    type(ESMF_GridComp) :: gcomp
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
  end subroutine CheckImportAlwaysOK

  !> @brief Inicializa todos os campos do importState com defaults seguros.
  !!
  !! Chamado em DataInitialize ANTES do primeiro passo de acoplamento, antes
  !! do MED ter executado. Sem isso, o importState chega ao mpas_import com
  !! valores indefinidos (zero ou lixo de memória), causando NaN em t=0.
  !! O valor de cada campo vem de valor_inicial_importacao; um campo do mapa
  !! sem valor previsto la' interrompe a inicializacao.
  !!
  !! Após o primeiro ciclo MED→MPAS, todos serão sobrescritos pelos campos
  !! reais do MOM6+SIS2.
  subroutine init_import_defaults(importState, rc)
    type(ESMF_State), intent(inout) :: importState
    integer,          intent(out)   :: rc
    type(ESMF_Field)               :: field
    real(ESMF_KIND_R8), pointer    :: fptr1d(:)
    real(ESMF_KIND_R8), pointer    :: fptr2d(:,:)
    real(ESMF_KIND_R8)             :: valor
    logical                        :: conhecido
    character(len=CPL_NOME_LEN), allocatable :: nomes(:)
    integer :: i, fld_rank, localDeCount_imp
    rc = ESMF_SUCCESS

    call cpl_chegadas(PONTO_ATM, .true., cpl_config_atual(), '', nomes)
    do i = 1, size(nomes)
      call valor_inicial_importacao(nomes(i), valor, conhecido)
      if (.not. conhecido) then
        call ESMF_LogSetError(ESMF_FAILURE, msg='(mpas_cap:init_import_defaults): '// &
             'campo importado sem valor inicial: '//trim(nomes(i)), &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc)
        return
      end if
      nullify(fptr1d, fptr2d)
      call ESMF_StateGet(importState, itemName=trim(nomes(i)), &
                         field=field, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      ! PETs sem DE local na grade MPAS (360×180, regDecomp(2)=90) têm
      ! localDeCount=0 com 512 PETs (PETs 90-511). ESMF_FieldGet(farrayPtr)
      ! nestes PETs gera "localDe is out of range". Verificar antes de acessar.
      call ESMF_FieldGet(field, localDeCount=localDeCount_imp, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      if (localDeCount_imp == 0) cycle   ! PET sem dados locais — nada a inicializar
      ! Consultar rank antes de chamar farrayPtr (evita erro rank mismatch)
      call ESMF_FieldGet(field, dimCount=fld_rank, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      if (fld_rank == 1) then
        call ESMF_FieldGet(field, farrayPtr=fptr1d, rc=rc)
        if (ChkErr(rc, __LINE__, u_FILE_u)) return
        fptr1d = valor
        nullify(fptr1d)
      else
        call ESMF_FieldGet(field, farrayPtr=fptr2d, rc=rc)
        if (ChkErr(rc, __LINE__, u_FILE_u)) return
        fptr2d = valor
        nullify(fptr2d)
      end if
    end do
  end subroutine init_import_defaults

  !> @brief Valor inicial de um campo importado, antes do primeiro passo.
  !!
  !! conhecido = .false. se o campo nao tem valor previsto aqui.
  !!   Sx_tsfc   temp. de pele padrão tropical (cfg_sst_default ≈ 298 K)
  !!   Si_ifrac  fração de gelo (cfg_ice_fraction_default = 0.0)
  !!   So_u      corrente zonal (0.0 m/s, oceano em repouso)
  !!   So_v      corrente meridional (0.0 m/s, oceano em repouso)
  !!   Sf_zorl   rugosidade (cfg_zorl_default) [m]
  !!   Sf_albedo o mesmo valor de agua aberta usado em mpas_cap_methods.F90 e
  !!             mpas_atm_setup.F90 (ALB_OCEAN_DEFAULT)
  !!   Sx_omask  1, tudo oceano
  subroutine valor_inicial_importacao(nome, valor, conhecido)
    character(len=*),   intent(in)  :: nome
    real(ESMF_KIND_R8), intent(out) :: valor
    logical,            intent(out) :: conhecido

    conhecido = .true.
    select case (trim(nome))
    case ('Sx_tsfc')
      valor = real(cfg_sst_default, ESMF_KIND_R8)
    case ('Si_ifrac')
      valor = real(cfg_ice_fraction_default, ESMF_KIND_R8)
    case ('So_u', 'So_v')
      valor = 0.0_ESMF_KIND_R8
    case ('Sf_zorl')
      valor = real(cfg_zorl_default, ESMF_KIND_R8)
    case ('Sf_albedo')
      valor = ALB_OCEAN_DEFAULT
    case ('Sx_omask')
      valor = 1.0_ESMF_KIND_R8
    case default
      valor = 0.0_ESMF_KIND_R8
      conhecido = .false.
    end select
  end subroutine valor_inicial_importacao


end module mpas_cap_MONAN_mod
