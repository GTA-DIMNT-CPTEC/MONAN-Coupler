!> @file mpas_cap_MONAN.F90
!! @brief Cap NUOPC/ESMF para o modelo atmosférico MPAS-A 8.3 / MONAN-A 2.0.
!!
!! Protocolo NUOPC completo via NUOPC_CompDerive (InitializeAdvertise,
!! InitializeRealize, DataInitialize, ModelAdvance, ModelFinalize). O
!! cap exporta a forçante atmosférica do MONAN-A ao mediador e importa dele
!! a superfície do oceano e do gelo (POINT_ATM, abaixo). A tradução entre
!! o MPAS-A e o ESMF fica no adaptador (mpas_adapter.F90), e os
!! diagnósticos NetCDF em mpas_cap_netcdf.F90 e mpas_import_diag.F90.
!!
!! As coordenadas para o NetCDF vêm de lonCell(1:n_local), com
!! n_local = min(localCells_ESMF, nCells_MPAS), e não de ownedElemCoords,
!! que causa double-free no ESMF 8.9.1 em Cray/gfortran.

module mpas_cap_MONAN_mod

  use ESMF
  use coupler_constants_mod, only : RAD2DEG, ALB_OCEAN_DEFAULT
  use NUOPC,       only : NUOPC_CompDerive,        NUOPC_CompSpecialize,   &
                           NUOPC_CompSetEntryPoint, NUOPC_CompFilterPhaseMap, &
                           NUOPC_Realize,                                     &
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

  use mpas_adapter_mod,     only : mpas_import,         &
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
                                    cfg_zorl_default, cpl_current_config

  use coupler_utils_mod,   only : ChkErr, int_to_str
  use coupler_log_mod,     only : COMP_ATM, log_error, log_info
  use cap_common_mod,      only : cap_initialize_p0, cap_realize_fields, cap_advertise, &
                                  ADVERTISE_DEFAULT
  use cpl_fields_mod,      only : CPL_NAME_LEN
  use cpl_map_mod,         only : cpl_arrivals, cpl_exports

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

  ! Campos importados do mediador (MED→MPAS)
  !
  ! O NUOPC só cria RouteHandle para campos MUTUAMENTE anunciados: o MED
  ! anuncia estes campos no exportState, e o MPAS os anuncia espelhadamente
  ! no importState (este array).
  !
  ! Sx_tsfc (e não So_t) alimenta atm_bnd%sst: So_t é a SST pura do MOM6,
  ! que o SIS2 também importa e precisa pura para o fluxo de calor basal do
  ! gelo (ICE_KMELT); Sx_tsfc é o composto (1-Si_ifrac)*So_t +
  ! Si_ifrac*Si_t_sis2, calculado no MED (med_export.F90) para a atmosfera, que
  ! enxerga uma única célula mista água+gelo.
  !
  ! Sf_zorl é a rugosidade calculada no MED por Charnock + Smith a partir de
  ! Foxx_taux/tauy, no lugar do valor fixo cfg_zorl_default = 0.01 m
  ! (realimentação vento <-> rugosidade, importante em tempestades).
  !
  ! Sx_omask é a máscara terra/oceano REAL do MOM6 (ocean_grid%mask2dT).
  ! Não alimenta a física do MONAN-A, que tem a própria landmask; serve para
  ! mascarar continentes no diagnóstico monan2_import_*.nc, em vez de contar
  ! só com o filtro ocean_frac_min do binning Voronoi, um critério de
  ! COBERTURA de célula Voronoi por bin, sem relação com terra/oceano.
  !
  ! Os campos saem do mapa de acoplamento (src/coupling/cpl_map.F90), no
  ! ponto ATM@atm_cap: a importação são os 7 campos que chegam por conector
  ! (cpl_arrivals: Sx_tsfc, Si_ifrac, So_u, So_v, Sf_zorl, Sf_albedo e
  ! Sx_omask), e a exportação, os 13 campos *_mpas de EXPORTS
  ! (cpl_exports), a forçante nativa do MONAN-A. O cap anuncia sempre as
  ! mesmas listas: não consulta chaves de &nuopc_mode. O valor inicial de
  ! cada campo importado está em initial_import_value.
  character(len=*), parameter :: POINT_ATM = 'ATM@atm_cap'

  character(len=*), parameter :: u_FILE_u = __FILE__

contains

  !> @brief Registra o cap no NUOPC: fases de inicialização e especializações
  !! (DataInitialize, Advance, Finalize e CheckImport).
  !! @param[inout] gcomp  componente do cap
  !! @param[out]   rc     código de retorno
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
    ! Suprimir validação de timestamp de import (lag OCN->MPAS: t-1 != currTime)
    call NUOPC_CompSpecialize(gcomp, &
         specLabel=model_label_CheckImport, &
         specRoutine=CheckImportAlwaysOK, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call log_info(COMP_ATM, 'SetServices concluido')
  end subroutine SetServices

  !> @brief Fase 0: mapa de fases do cap (cap_initialize_p0) e registro do instante inicial no log.
  !! @param[inout] gcomp        componente do cap
  !! @param[inout] importState  estado de importação
  !! @param[inout] exportState  estado de exportação
  !! @param[in]    clock        relógio do componente
  !! @param[out]   rc           código de retorno
  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp) :: gcomp
    type(ESMF_State)    :: importState, exportState
    type(ESMF_Clock)    :: clock
    integer,             intent(out) :: rc
    type(ESMF_Time)    :: startTimeLoc
    character(len=32)  :: value
    integer            :: yr, mo, dy, hr, mn, sc
    rc = ESMF_SUCCESS
    call cap_initialize_p0(gcomp, importState, exportState, clock, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_ClockGet(clock, startTime=startTimeLoc, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_TimeGet(startTimeLoc, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    write(value, '(I4.4,"-",I2.2,"-",I2.2,"T",I2.2,":",I2.2,":",I2.2)') &
          yr, mo, dy, hr, mn, sc
    call log_info(COMP_ATM, 'start_time = '//trim(value))
    call log_info(COMP_ATM, 'InitializeP0 concluido')
  end subroutine InitializeP0

  !> @brief Anuncia os campos importados e exportados, lidos do mapa de acoplamento (POINT_ATM).
  !! @param[inout] gcomp        componente do cap
  !! @param[inout] importState  estado de importação
  !! @param[inout] exportState  estado de exportação
  !! @param[in]    clock        relógio do componente
  !! @param[out]   rc           código de retorno
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp) :: gcomp
    type(ESMF_State)    :: importState, exportState
    type(ESMF_Clock)    :: clock
    integer,             intent(out) :: rc
    character(len=CPL_NAME_LEN), allocatable :: imp(:), exp(:)
    rc = ESMF_SUCCESS
    call cpl_arrivals(POINT_ATM, .true., cpl_current_config(), '', imp)
    call cpl_exports(POINT_ATM, cpl_current_config(), '', exp)
    call cap_advertise(importState, imp, ADVERTISE_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call cap_advertise(exportState, exp, ADVERTISE_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call log_info(COMP_ATM, 'InitializeAdvertise: anunciados '// &
         int_to_str(size(imp))//' imp + '// &
         int_to_str(size(exp))//' exp')
  end subroutine InitializeAdvertise

  !> @brief Cria a grade e os campos do cap, inicializa o MONAN-A e prepara o gravador NetCDF.
  !!
  !! A grade e os campos ESMF são criados antes de mpas_atm_init, que inicia
  !! o SMIOL; as coordenadas do gravador são reunidas depois.
  !! @param[inout] gcomp        componente do cap
  !! @param[inout] importState  estado de importação
  !! @param[inout] exportState  estado de exportação
  !! @param[in]    clock        relógio do componente
  !! @param[out]   rc           código de retorno
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
    character(len=CPL_NAME_LEN), allocatable :: names(:)
    rc = ESMF_SUCCESS

    ! 0. VM: obter localMpiComm e localPet ANTES de qualquer outra chamada
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_VMGet(vm, localPet=localPet, mpiCommunicator=localMpiComm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! Estado interno do cap, guardado no componente
    allocate(wrap%ptr)
    st => wrap%ptr
    call ESMF_GridCompSetInternalState(gcomp, wrap, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! 1. ESMF_Grid 360x180 (ANTES de mpas_atm_init)
    ! ESMF_Grid não usa MOAB (ver mpas_create_grid) e é criada antes do
    ! SMIOL (mpas_atm_init), com o MPI ainda limpo.
    call mpas_create_grid(st%grid, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! 2. Campos ESMF e NUOPC_Realize (ANTES de mpas_atm_init)
    ! ESMF_FieldCreate sobre ESMF_Grid: sem MOAB, sem deadlock.
    ! ESMF_Grid distribui automaticamente -> todos os PETs têm células locais.
    call cpl_arrivals(POINT_ATM, .true., cpl_current_config(), '', names)
    call cap_realize_fields(importState, st%grid, names, size(names), rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call cpl_exports(POINT_ATM, cpl_current_config(), '', names)
    call cap_realize_fields(exportState, st%grid, names, size(names), rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! 3. Inicializar MPAS-A (SMIOL começa aqui)
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

    ! 4. Coordenadas NetCDF (MPI_Allgather após SMIOL — seguro)
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

    call log_info(COMP_ATM, 'InitializeRealize concluido')
  end subroutine InitializeRealize

  !> @brief DataInitialize: confere a conexão dos importados, aplica os valores
  !! iniciais e exporta os campos de t=0.
  !! @param[inout] gcomp  componente do cap
  !! @param[out]   rc     código de retorno
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
    ! importState. Ver o cabeçalho de verify_import_connected para o motivo.
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
    call log_info(COMP_ATM, 'DataInitialize SATISFIED')
  end subroutine InitializeDataComplete

  !> @brief Avança um intervalo de acoplamento: importa o contorno, roda o MONAN-A e exporta a forçante.
  !! @param[inout] gcomp  componente do cap
  !! @param[out]   rc     código de retorno
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

    ! Timestamp para o diagnóstico de importação
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
    call log_info(COMP_ATM, 'ModelAdvance concluido')
  end subroutine ModelAdvance

  !> @brief Recupera o estado interno do cap, criado em InitializeRealize.
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

  !> @brief Finaliza o MONAN-A (mpas_atm_final); a grade fica para o ESMF_Finalize.
  !! @param[inout] gcomp  componente do cap
  !! @param[out]   rc     código de retorno
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
    ! ainda referenciam st%grid quando ModelFinalize é chamado.
    ! Destruir o grid aqui causa SIGSEGV no cleanup posterior do framework.
    ! O ESMF finaliza o grid automaticamente em ESMF_Finalize.
    deallocate(st%atm_public, st%atm_state, st%atm_bnd)
    st%atm_public => null()
    st%atm_state  => null()
    st%atm_bnd    => null()
    call log_info(COMP_ATM, 'ModelFinalize concluido')
  end subroutine ModelFinalize

  !> @brief Aborta se algum campo importado não estiver conectado.
  !!
  !! Quando o componente OCN não oferece todos os campos que este cap
  !! anuncia, o NUOPC registra no log do PET
  !!     MPAS: Import Field not connected: <nome>
  !!     ERROR ... NUOPC INCOMPATIBILITY DETECTED: Import Fields not all connected
  !! e mesmo assim DEVOLVE ESMF_SUCCESS, e a execução segue. No primeiro
  !! passo, mpas_import leria os campos importados, inclusive os nunca
  !! realizados, e o farrayPtr de um campo não conectado levaria a SIGSEGV
  !! dentro do libesmf.so, sem pista no esmApp_run.log. Por isso esta rotina
  !! confere a conexão antes de tocar no importState e aborta nomeando os
  !! campos ausentes. Custo: uma chamada a NUOPC_IsConnected por campo
  !! importado, uma vez por execução.
  !!
  !! A conferência fica no cap, e não no driver, porque precisa dos campos
  !! que este cap importa (do mapa, no ponto POINT_ATM); no esm.F90 seria
  !! preciso percorrer os cplLists de cada conector e reconstruir a mesma
  !! informação de segunda mão.
  !!
  !! Não confundir com CheckImportAlwaysOK, logo abaixo. Aquela suprime a
  !! validação de TIMESTAMP, que é legítima porque o conector OCN->MPAS
  !! entrega com atraso de um passo. Esta verifica CONECTIVIDADE: um campo
  !! desconectado nunca fica correto, em nenhum passo, e suprimir a
  !! primeira não implica suprimir a segunda.
  subroutine verify_import_connected(importState, rc)
    type(ESMF_State), intent(in)  :: importState
    integer,          intent(out) :: rc

    character(len=*), parameter :: subname = '(mpas_cap:verify_import_connected)'
    integer            :: i, n_missing, localPet
    logical            :: connected
    character(len=512) :: missing
    character(len=640) :: msg
    type(ESMF_VM)      :: vm
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS
    n_missing = 0
    missing   = ''
    call cpl_arrivals(POINT_ATM, .true., cpl_current_config(), '', names)

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    do i = 1, size(names)
      connected = NUOPC_IsConnected(importState, &
                                    fieldName=trim(names(i)), rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      if (.not. connected) then
        n_missing = n_missing + 1
        if (len_trim(missing) > 0) missing = trim(missing)//', '
        missing = trim(missing)//trim(names(i))
      end if
    end do

    if (n_missing > 0) then
      write(msg,'(A,I0,A,I0,A)') subname//': ABORTANDO — ', n_missing, &
        ' de ', size(names), ' campos de importacao nao estao conectados: '
      msg = trim(msg)//trim(missing)
      ! log_error grava também na saída padrão (esmApp_run.log), onde o
      ! motivo da parada precisa aparecer; a condição vale em todos os PETs,
      ! por isso só o PET 0 a registra.
      if (localPet == 0) call log_error(COMP_ATM, 'verify_import_connected: '// &
        int_to_str(n_missing)//' de '//int_to_str(size(names))// &
        ' campos de importacao nao conectados: '//trim(missing)// &
        '. O componente OCN configurado nao oferece todos os campos que o cap '// &
        'do MPAS anuncia (ATM@atm_cap no mapa de acoplamento); prosseguir levaria '// &
        'a SIGSEGV no primeiro passo. Verifique a combinacao de componentes '// &
        '(&nuopc_mode e &nuopc_petlayout, tabela COUPLER_MODES).')
      call ESMF_LogSetError(ESMF_FAILURE, msg=trim(msg), &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if

    call log_info(COMP_ATM, 'verify_import_connected: todos os '// &
      int_to_str(size(names))//' campos de importacao estao conectados')

  end subroutine verify_import_connected

  !> @brief Suprime validação de timestamp dos campos de importação.
  !!
  !! O conector OCN->MPAS fornece SST com lag de 1 passo (t-1), portanto
  !! os campos de importação nunca têm timestamp = currTime. A validação
  !! padrão NUOPC (label_CheckImport) geraria "INCOMPATIBILITY: Import Fields
  !! not at current time" em todos os 48 passos. Esta rotina substitui o
  !! CheckImport padrão com sucesso incondicional.
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
  !! O valor de cada campo vem de initial_import_value; um campo do mapa
  !! sem valor previsto lá interrompe a inicialização.
  !!
  !! Após o primeiro ciclo MED→MPAS, todos serão sobrescritos pelos campos
  !! reais do MOM6+SIS2.
  subroutine init_import_defaults(importState, rc)
    type(ESMF_State), intent(inout) :: importState
    integer,          intent(out)   :: rc
    type(ESMF_Field)               :: field
    real(ESMF_KIND_R8), pointer    :: fptr1d(:)
    real(ESMF_KIND_R8), pointer    :: fptr2d(:,:)
    real(ESMF_KIND_R8)             :: init_val
    logical                        :: known
    character(len=CPL_NAME_LEN), allocatable :: names(:)
    integer :: i, fld_rank, localDeCount_imp
    rc = ESMF_SUCCESS

    call cpl_arrivals(POINT_ATM, .true., cpl_current_config(), '', names)
    do i = 1, size(names)
      call initial_import_value(names(i), init_val, known)
      if (.not. known) then
        call ESMF_LogSetError(ESMF_FAILURE, msg='(mpas_cap:init_import_defaults): '// &
             'campo importado sem valor inicial: '//trim(names(i)), &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc)
        return
      end if
      nullify(fptr1d, fptr2d)
      call ESMF_StateGet(importState, itemName=trim(names(i)), &
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
        fptr1d = init_val
        nullify(fptr1d)
      else
        call ESMF_FieldGet(field, farrayPtr=fptr2d, rc=rc)
        if (ChkErr(rc, __LINE__, u_FILE_u)) return
        fptr2d = init_val
        nullify(fptr2d)
      end if
    end do
  end subroutine init_import_defaults

  !> @brief Valor inicial de um campo importado, antes do primeiro passo.
  !!
  !! conhecido = .false. se o campo não tem valor previsto aqui.
  !!   Sx_tsfc   temp. de pele padrão tropical (cfg_sst_default ≈ 298 K)
  !!   Si_ifrac  fração de gelo (cfg_ice_fraction_default = 0.0)
  !!   So_u      corrente zonal (0.0 m/s, oceano em repouso)
  !!   So_v      corrente meridional (0.0 m/s, oceano em repouso)
  !!   Sf_zorl   rugosidade (cfg_zorl_default) [m]
  !!   Sf_albedo o mesmo valor de água aberta usado em mpas_adapter.F90 e
  !!             mpas_atm_setup.F90 (ALB_OCEAN_DEFAULT)
  !!   Sx_omask  1, tudo oceano
  subroutine initial_import_value(name, init_val, known)
    character(len=*),   intent(in)  :: name
    real(ESMF_KIND_R8), intent(out) :: init_val
    logical,            intent(out) :: known

    known = .true.
    select case (trim(name))
    case ('Sx_tsfc')
      init_val = real(cfg_sst_default, ESMF_KIND_R8)
    case ('Si_ifrac')
      init_val = real(cfg_ice_fraction_default, ESMF_KIND_R8)
    case ('So_u', 'So_v')
      init_val = 0.0_ESMF_KIND_R8
    case ('Sf_zorl')
      init_val = real(cfg_zorl_default, ESMF_KIND_R8)
    case ('Sf_albedo')
      init_val = ALB_OCEAN_DEFAULT
    case ('Sx_omask')
      init_val = 1.0_ESMF_KIND_R8
    case default
      init_val = 0.0_ESMF_KIND_R8
      known = .false.
    end select
  end subroutine initial_import_value


end module mpas_cap_MONAN_mod
