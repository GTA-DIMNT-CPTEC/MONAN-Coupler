!> @file DOCN_cap.F90
!! @brief Oceano de dados (DOCN): SST, gelo e correntes lidos de arquivos NetCDF.
!!
!! Equivalente ao DATM_cap.F90 (atmosfera de dados, JRA55) para o
!! componente oceânico: lê SST e gelo marinho de arquivos NetCDF (por
!! exemplo, OISST v2.1 diário ou OSTIA), com interpolação temporal linear
!! entre registros, e os exporta ao mediador e ao cap atmosférico (contorno
!! de superfície). Baseado em DATM_cap.F90 e no exemplo
!! AtmOcnMedPetListProto do ESMF.
!!
!! | Campo exportado | Grandeza                               | Unidade |
!! | --------------- | -------------------------------------- | ------- |
!! | So_t            | temperatura da superfície do mar (SST) | K       |
!! | Si_ifrac        | fração de gelo marinho                 | 0 a 1   |
!! | Sf_zorl         | comprimento de rugosidade oceânica     | m       |
!! | So_s            | salinidade superficial (opcional)      | psu     |
!! | So_u            | corrente superficial zonal             | m/s     |
!! | So_v            | corrente superficial meridional        | m/s     |
!!
!! Os campos importados do mediador (Foxx_taux, Foxx_tauy, Foxx_sen,
!! Foxx_evap, Foxx_lwnet, Foxx_swnet_vdr/vdf/idr/idf, Faxa_rain, Faxa_snow,
!! Sa_pslv, Si_ifrac e So_duu10n) são recebidos, mas não processados.
!!
!! Modo de operação único (nuopc.input, &nuopc_docn): docn_mode = 'netcdf'.
!!
!! Leitura paralela: o PET 0 lê o campo global inteiro do NetCDF e o
!! difunde com ESMF_VMBroadcast; cada PET copia o seu subdomínio. Serve
!! para grades até ~1440×1080 (OISST 0.25°: ~12 MB por campo e registro).
!!
!! Arquivo NetCDF esperado (compatível com OISST v2.1, CF-1.8): dimensões
!! lon(1440), lat(720), time(N); variáveis sst(lon,lat,time) [°C] e
!! aice(lon,lat,time) [0–1]. A SST é convertida de °C para K (+273.15); se
!! o arquivo já estiver em K, ajuste SST_CELSIUS_TO_K = 0.0.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module DOCN_cap_mod

  use ESMF
  use coupler_constants_mod, only : T0_KELVIN
  use ESMF, only: ESMF_GridComp, ESMF_GridCompGet, ESMF_GridCompSetEntryPoint
  use ESMF, only: ESMF_GridCompGetInternalState, ESMF_GridCompSetInternalState
  use ESMF, only: ESMF_State, ESMF_StateGet
  use ESMF, only: ESMF_Field, ESMF_FieldCreate, ESMF_FieldGet
  use ESMF, only: ESMF_Grid, ESMF_GridCreate1PeriDim, ESMF_GridAddCoord, &
                  ESMF_GridGetCoord
  use ESMF, only: ESMF_Clock, ESMF_ClockGet
  use ESMF, only: ESMF_Time, ESMF_TimeGet, ESMF_TimeSet
  use ESMF, only: ESMF_TimeInterval, ESMF_TimeIntervalSet, ESMF_TimeIntervalGet
  use ESMF, only: ESMF_METHOD_INITIALIZE, ESMF_STAGGERLOC_CENTER
  use ESMF, only: ESMF_TYPEKIND_R8, ESMF_KIND_R8, ESMF_KIND_I8
  use ESMF, only: ESMF_INDEX_GLOBAL, ESMF_COORDSYS_SPH_DEG
  use ESMF, only: ESMF_SUCCESS, ESMF_FAILURE, ESMF_LOGERR_PASSTHRU
  use ESMF, only: ESMF_LogFoundError
  use ESMF, only: ESMF_VM, ESMF_VMGetGlobal, ESMF_VMGet, ESMF_VMBroadcast
  use ESMF, only: ESMF_CALKIND_GREGORIAN

  use docn_cap_netcdf_mod, only: WriteDOCNDiag
  use ocn_data_reader_mod, only: ReadOcnFieldInterp
  use coupler_utils_mod,   only: ChkErr, int_to_str
  use coupler_log_mod,     only: COMP_DOCN, log_info, log_warning
  use cap_common_mod,      only: cap_initialize_p0, cap_realize_fields, cap_put_field, &
                                 cap_fill_export_initial, cap_set_data_complete, &
                                 cap_stamp_export, cap_advertise, ADVERTISE_DEFAULT
  use cpl_fields_mod,      only: CPL_NAME_LEN
  use cpl_map_mod,         only: cpl_arrivals, cpl_exports

  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Realize
  use NUOPC, only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet
  use NUOPC_Model, &
    model_routine_SS           => SetServices,          &
    model_label_DataInitialize => label_DataInitialize, &
    model_label_Advance        => label_Advance
  use NUOPC_Model, only: NUOPC_ModelGet, SetVM

  use coupler_config_mod, only: cfg_sst_default,          &
                                  cfg_ice_fraction_default, &
                                  cfg_zorl_default,         &
                                  cfg_docn_mode,          &
                                  cfg_docn_sst_file,      &
                                  cfg_docn_ice_file,      &
                                  cfg_docn_cur_file,      &
                                  cfg_docn_nx,            &
                                  cfg_docn_ny,            &
                                  cfg_docn_dt_data,       &
                                  cfg_docn_epoch_year,    &
                                  cfg_docn_epoch_month,   &
                                  cfg_docn_epoch_day,     &
                                  cfg_docn_sst_varname,   &
                                  cfg_docn_ice_varname,   &
                                  cfg_docn_cur_u_varname, &
                                  cfg_docn_cur_v_varname, &
                                  cfg_write_import_diag,    &
                                  cfg_import_diag_dir,      &
                                  cfg_docn_ice_pct,       &
                                  cfg_grid_res_deg, cpl_current_config

  implicit none
  private

  ! Início da mensagem de erro de cap_put_field quando o campo não existe.
  character(len=*), parameter :: PUT_TAG = "PutField DOCN: "

  public :: SetServices
  public :: SetVM

  ! Conversão de unidades
  ! OISST v2.1 armazena SST em °C. Ajuste para 0.0 se o arquivo já for em K.

  ! Rugosidade oceânica padrão
  real(ESMF_KIND_R8), parameter :: ZORL_DEFAULT = 0.001_ESMF_KIND_R8  ! [m]

  ! Campos trocados
  ! Saem do mapa de acoplamento (src/coupling/cpl_map.F90), no ponto
  ! OCN@docn: a importação são os 14 fluxos e estados que chegam do mediador
  ! (cpl_arrivals: Foxx_*, Faxa_rain, Faxa_snow, Sa_pslv, Si_ifrac e
  ! So_duu10n); a exportação, os 6 campos de EXPORTS (cpl_exports):
  ! So_t [K], Si_ifrac [0-1], Sf_zorl [m], So_s [psu], So_u e So_v [m/s].
  ! O cap anuncia sempre as mesmas listas: não consulta chaves de &nuopc_mode.
  ! O valor inicial de cada campo exportado está em initial_export_value.
  character(len=*), parameter :: POINT_OCN = 'OCN@docn'

  ! Estado interno do DOCN
  type :: DOCN_InternalState
    type(ESMF_Grid) :: grid
    ! Campos oceânicos interpolados (subdomínio local do PET)
    real(ESMF_KIND_R8), pointer :: sst(:,:)   => null()  ! SST [K]
    real(ESMF_KIND_R8), pointer :: aice(:,:)  => null()  ! fração de gelo [0-1]
    real(ESMF_KIND_R8), pointer :: sss(:,:)   => null()  ! salinidade [psu]
    real(ESMF_KIND_R8), pointer :: uocn(:,:)  => null()  ! corrente zonal [m/s]
    real(ESMF_KIND_R8), pointer :: vocn(:,:)  => null()  ! corrente meridional [m/s]
    logical :: initialized = .false.
  end type DOCN_InternalState

  type :: DOCN_InternalStateWrapper
    type(DOCN_InternalState), pointer :: wrap => null()
  end type DOCN_InternalStateWrapper

contains

  !> @brief Registra as fases de inicialização (IPDv03) e as especializações do DOCN.
  !! @param[inout] gcomp  componente DOCN
  !! @param[out]   rc     código de retorno
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer,              intent(out)   :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
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

    call NUOPC_CompSpecialize(gcomp, &
      specLabel=model_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, &
      specLabel=model_label_Advance, &
      specRoutine=ModelAdvance, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DOCN, 'SetServices concluido')

  end subroutine SetServices

  !> @brief Anuncia os campos importados do mediador e os exportados ao MED e ao MPAS.
  !!
  !! Todos os campos importados (fluxos do mediador MED→OCN) são
  !! anunciados; o conector MED→OCN cria RouteHandles bilineares na grade
  !! do DOCN (ver InitializeRealize para a decomposição). As listas saem do
  !! mapa de acoplamento (ponto POINT_OCN, acima).
  !! @param[inout] gcomp        componente DOCN
  !! @param[inout] importState  estado de importação
  !! @param[inout] exportState  estado de exportação
  !! @param[in]    clock        relógio do componente
  !! @param[out]   rc           código de retorno
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer,              intent(out)   :: rc

    character(len=CPL_NAME_LEN), allocatable :: imp(:), exp(:)

    rc = ESMF_SUCCESS

    call cpl_arrivals(POINT_OCN, .true., cpl_current_config(), '', imp)
    call cpl_exports(POINT_OCN, cpl_current_config(), '', exp)

    ! Anuncia todos os campos importados do mediador (MED→OCN).
    call cap_advertise(importState, imp, ADVERTISE_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Anuncia campos exportados para MED e para OCN→MPAS.
    call cap_advertise(exportState, exp, ADVERTISE_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DOCN, 'InitializeAdvertise concluido (' &
      //int_to_str(size(exp))//' exp, ' &
      //int_to_str(size(imp))//' imp)')

  end subroutine InitializeAdvertise

  !> @brief Cria a grade regular lat/lon do DOCN e realiza os campos.
  !!
  !! Grade configurável no nuopc.input (&nuopc_docn):
  !!   docn_nx = 1440  (OISST 0.25°)   ou  360 (1.0°)
  !!   docn_ny =  720  (OISST 0.25°)   ou  180 (1.0°)
  !! Coordenadas nos centros das células, por exemplo
  !! lon=[0.125..359.875] e lat=[-89.875..89.875] a 0.25°.
  !! @param[inout] gcomp        componente DOCN
  !! @param[inout] importState  estado de importação
  !! @param[inout] exportState  estado de exportação
  !! @param[in]    clock        relógio do componente
  !! @param[out]   rc           código de retorno
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer,              intent(out)   :: rc

    type(ESMF_Grid)   :: grid
    type(ESMF_VM)     :: vm
    integer           :: nx, ny, i, j, petCount
    real(ESMF_KIND_R8)              :: dx, dy
    real(ESMF_KIND_R8), pointer     :: coordX(:,:), coordY(:,:)
    type(DOCN_InternalStateWrapper) :: iswrap
    type(DOCN_InternalState), pointer :: is
      integer :: nx_tiles_target
      integer :: nx_max
      integer :: ny_tiles
      integer :: regDecomp_2d(2)
      integer :: localDeCount_docn
      integer :: lde_docn
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS

    ! Grade DOCN: resolução nativa do dado oceânico (nuopc.input &nuopc_docn).
    ! OISST 0.25° → docn_nx=1440, docn_ny=720.
    ! Grade 1°    → docn_nx= 360, docn_ny=180.
    nx = cfg_docn_nx
    ny = cfg_docn_ny
    dx = 360.0_ESMF_KIND_R8 / real(nx, ESMF_KIND_R8)
    dy = 180.0_ESMF_KIND_R8 / real(ny, ESMF_KIND_R8)

    ! A decomposição é explícita. Sem regDecomp, ESMF_GridCreate1PeriDim
    ! (ESMF 8.9.1) pode gerar DEs de largura 1 na latitude quando
    ! petCount > ny/2, e o regrid bilinear do conector MED->OCN falha com
    ! "not supported on Grids that contain a DE of width 1". Decompor só em
    ! latitude deixa PETs vazios quando petCount > ny/2; decompor só em
    ! longitude dá blocos muito estreitos (1440×720 a 512 PETs: 2 a 3
    ! colunas × 720 linhas, aspecto 256:1), e o MOAB trava em
    ! ESMF_FieldBundleRegridStore.
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Os blocos são quase quadrados, com sqrt(petCount) por
    ! dimensão:
    !   nx_tiles_target = nint(sqrt(N)) → aspecto ≈ 1;
    !   nx_max = min(target, nx/2) → ao menos 2 colunas por bloco.
    !
    !   N=4:   sqrt=2  → nx_max=2   regDecomp=(/2,2/)=4    aspecto 0.5:1
    !   N=128: sqrt=11 → nx_max=11  regDecomp=(/11,12/)=132 aspecto 0.5:1
    !   N=512: netcdf(360×180) → regDecomp=(/23,23/)=529  15col× 7row
    !   N=512: netcdf(1440×720)→ regDecomp=(/23,23/)=529  62col×31row

      nx_tiles_target = max(1, nint(sqrt(real(petCount))))
      nx_max          = min(nx_tiles_target, nx / 2)
      ny_tiles        = (petCount + nx_max - 1) / nx_max
      regDecomp_2d(1) = min(nx_max, petCount)
      regDecomp_2d(2) = max(1, ny_tiles)

      grid = ESMF_GridCreate1PeriDim( &
        minIndex  = (/1, 1/),                &
        maxIndex  = (/nx, ny/),              &
        regDecomp = regDecomp_2d,            &
        indexflag = ESMF_INDEX_GLOBAL,       &
        coordSys  = ESMF_COORDSYS_SPH_DEG,  &
        rc        = rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      call ESMF_GridAddCoord(grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      ! loop sobre DEs locais — com regDecomp 2D e DEs>petCount,
      ! 17 PETs a 512 PETs têm localDeCount=2; GridGetCoord exige localDE=.
      call ESMF_GridGet(grid, localDeCount=localDeCount_docn, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      do lde_docn = 0, localDeCount_docn - 1
        call ESMF_GridGetCoord(grid, coordDim=1, localDE=lde_docn, &
          staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        do j = lbound(coordX,2), ubound(coordX,2)
          do i = lbound(coordX,1), ubound(coordX,1)
            coordX(i,j) = (real(i,ESMF_KIND_R8) - 1.0_ESMF_KIND_R8)*dx + dx*0.5_ESMF_KIND_R8
          end do
        end do
        call ESMF_GridGetCoord(grid, coordDim=2, localDE=lde_docn, &
          staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        do j = lbound(coordY,2), ubound(coordY,2)
          do i = lbound(coordY,1), ubound(coordY,1)
            coordY(i,j) = -90.0_ESMF_KIND_R8 &
              + (real(j,ESMF_KIND_R8) - 1.0_ESMF_KIND_R8)*dy + dy*0.5_ESMF_KIND_R8
          end do
        end do
      end do  ! lde_docn

    ! Campos importados: todos os fluxos do mediador.
    call cpl_arrivals(POINT_OCN, .true., cpl_current_config(), '', names)
    call cap_realize_fields(importState, grid, names, size(names), rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Exportados
    call cpl_exports(POINT_OCN, cpl_current_config(), '', names)
    call cap_realize_fields(exportState, grid, names, size(names), rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Estado interno
    allocate(iswrap%wrap)
    is             => iswrap%wrap
    is%grid        = grid
    is%initialized = .false.

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DOCN, 'InitializeRealize concluido (grade ' &
      //int_to_str(nx)//'x' &
      //int_to_str(ny)//')')

  end subroutine InitializeRealize

  !> @brief Fase IPDv03p7: preenche o exportState com os valores iniciais e sinaliza a conclusão.
  !! @param[inout] gcomp  componente DOCN
  !! @param[out]   rc     código de retorno
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer,              intent(out)   :: rc

    type(ESMF_State)               :: exportState
    type(ESMF_Clock)               :: clock_idc
    type(ESMF_Time)                :: startTime_idc
    character(len=CPL_NAME_LEN), allocatable :: names(:)
    real(ESMF_KIND_R8),          allocatable :: init_vals(:)
    integer :: k

    rc = ESMF_SUCCESS

    call ESMF_GridCompGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Preencher exportState com valores iniciais fisicamente consistentes
    ! (initial_export_value); os campos sem valor previsto começam em zero.
    call cpl_exports(POINT_OCN, cpl_current_config(), '', names)
    allocate(init_vals(size(names)))
    do k = 1, size(names)
      init_vals(k) = initial_export_value(names(k))
    end do
    call cap_fill_export_initial(exportState, names, init_vals, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Atualizar timestamps: NUOPC_ModelBase verifica que os campos no
    ! importState do componente seguinte estejam no currTime do clock.
    ! Sem NUOPC_SetTimestamp os campos ficam em t=0 e o MPAS rejeita.
    call ESMF_GridCompGet(gcomp, clock=clock_idc, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    ! NUOPC_SetTimestamp recebe ESMF_Time, não ESMF_Clock
    call ESMF_ClockGet(clock_idc, startTime=startTime_idc, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cap_stamp_export(exportState, startTime_idc, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cap_set_data_complete(gcomp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DOCN, 'InitializeDataComplete SATISFIED')

  end subroutine InitializeDataComplete

  !> @brief Valor de um campo exportado antes da primeira leitura.
  !!
  !! SST inicial do namelist &nuopc_atm_bnd (cfg_sst_default), fração de
  !! gelo padrão, rugosidade ZORL_DEFAULT e salinidade média global de 35
  !! psu; as correntes (So_u, So_v) e os demais campos começam em zero
  !! (repouso).
  !! @param[in] name  nome do campo
  function initial_export_value(name) result(init_val)
    character(len=*), intent(in) :: name
    real(ESMF_KIND_R8)           :: init_val

    select case (trim(name))
    case ('So_t')
      init_val = real(cfg_sst_default, ESMF_KIND_R8)
    case ('Si_ifrac')
      init_val = real(cfg_ice_fraction_default, ESMF_KIND_R8)
    case ('Sf_zorl')
      init_val = ZORL_DEFAULT
    case ('So_s')
      init_val = 35.0_ESMF_KIND_R8
    case default
      init_val = 0.0_ESMF_KIND_R8
    end select
  end function initial_export_value

  !> @brief Lê os campos oceânicos do NetCDF no instante corrente e preenche o exportState.
  !!
  !! SST e gelo vêm do arquivo com interpolação temporal linear entre
  !! registros. Dados esperados (OISST v2.1 ou equivalente CF-1.8):
  !!   sst_file: sst(lon,lat,time) em °C, dt=24h (diário)
  !!   ice_file: aice(lon,lat,time) em [0-1], dt=24h (diário)
  !!   cur_file: uo(lon,lat,time) e vo(lon,lat,time) em m/s (opcional)
  !! @param[inout] gcomp  componente DOCN
  !! @param[out]   rc     código de retorno
  subroutine ModelAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer,              intent(out)   :: rc

    type(ESMF_State)         :: importState, exportState
    type(ESMF_Clock)         :: clock
    type(ESMF_Time)          :: currTime, nextTime
    type(ESMF_TimeInterval)  :: dt
    type(ESMF_Field)         :: field
    type(DOCN_InternalStateWrapper) :: iswrap
    type(DOCN_InternalState), pointer :: is
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer                  :: i1, i2, j1, j2
    integer                  :: year, month, day, hour, minute, sec
    character(len=256) :: msg

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap

    call NUOPC_ModelGet(gcomp, modelClock=clock, &
      importState=importState, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_ClockGet(clock, currTime=currTime, timeStep=dt, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    nextTime = currTime + dt

    call ESMF_TimeGet(currTime, yy=year, mm=month, dd=day, &
      h=hour, m=minute, s=sec, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    write(msg,'(A,I4,5(A,I2.2))') 'avancando para ', year, '-', &
      month, '-', day, ' ', hour, ':', minute, ':', sec
    call log_info(COMP_DOCN, trim(msg))

    ! Obtém limites locais do subdomínio a partir do primeiro campo exportado
    call ESMF_StateGet(exportState, itemName="So_t", field=field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    i1 = lbound(fptr,1); i2 = ubound(fptr,1)
    j1 = lbound(fptr,2); j2 = ubound(fptr,2)
    nullify(fptr)

    ! Aloca buffers locais na primeira chamada
    if (.not. associated(is%sst)) then
      allocate(is%sst  (i1:i2, j1:j2))
      allocate(is%aice (i1:i2, j1:j2))
      allocate(is%sss  (i1:i2, j1:j2))
      allocate(is%uocn (i1:i2, j1:j2))
      allocate(is%vocn (i1:i2, j1:j2))
    end if

    call read_docn_fields(gcomp, is, currTime, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Escreve campos no exportState
    call cap_put_field(exportState, "So_t",    is%sst,  PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Si_ifrac",is%aice, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "So_s",    is%sss,  PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "So_u",    is%uocn, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "So_v",    is%vocn, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return

    ! Diagnóstico: escrita NetCDF dos campos lidos/preparados a cada passo.
    ! Ativado com write_import_diag=.true. em &nuopc_docn no nuopc.input.
    ! Gera: diag_import/docn_import_YYYYMMDD_HHMMSS.nc (grade DOCN, 1°×1°)
    ! Lido por: postproc_mom6_import.py  (validação de SST/gelo vs fonte)
    if (cfg_write_import_diag) then
      call WriteDOCNDiag(gcomp, currTime, cfg_docn_nx, cfg_docn_ny, rc)
      if (rc /= ESMF_SUCCESS) then
        call log_warning(COMP_DOCN, 'WriteDOCNDiag falhou; continuando')
        rc = ESMF_SUCCESS
      end if
    end if

    ! Sf_zorl: rugosidade constante (função de amplitude de onda não modelada aqui)
    call FillFieldConst(exportState, "Sf_zorl", ZORL_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Atualizar timestamps de todos os campos exportados
    call cap_stamp_export(exportState, nextTime, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DOCN, 'ModelAdvance concluido (OISST netcdf)')

  end subroutine ModelAdvance

  !> @brief Lê SST e gelo com interpolação temporal, as correntes (opcionais)
  !! e define a salinidade constante, nos buffers do estado interno.
  !! @param[inout] gcomp     componente DOCN
  !! @param[inout] is        estado interno (buffers dos campos)
  !! @param[in]    currTime  instante corrente
  !! @param[out]   rc        código de retorno
  subroutine read_docn_fields(gcomp, is, currTime, rc)
    type(ESMF_GridComp),      intent(inout) :: gcomp
    type(DOCN_InternalState), intent(inout) :: is
    type(ESMF_Time),          intent(in)    :: currTime
    integer,                  intent(out)   :: rc

    rc = ESMF_SUCCESS

    ! Leitura dos campos oceânicos com interpolação temporal
    ! nomes de variável configuráveis via nuopc.input (docn_*_varname).
    ! OISST v2.1: sst_varname='sst'  ice_varname='icec'
    call ReadOcnFieldInterp(gcomp, trim(cfg_docn_sst_file), &
      trim(cfg_docn_sst_varname), &
      currTime, cfg_docn_nx, cfg_docn_ny, is%sst,  rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="DOCN: falha ao ler SST", &
      line=__LINE__, file=__FILE__)) return
    ! Conversão °C → K (OISST armazena em °C)
    is%sst = is%sst + T0_KELVIN

    call ReadOcnFieldInterp(gcomp, trim(cfg_docn_ice_file), &
      trim(cfg_docn_ice_varname), &
      currTime, cfg_docn_nx, cfg_docn_ny, is%aice, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="DOCN: falha ao ler aice", &
      line=__LINE__, file=__FILE__)) return
    ! Conversão % → fração: cfg_docn_ice_pct=.true. para arquivos em (0–100).
    if (cfg_docn_ice_pct) is%aice = is%aice / 100.0_ESMF_KIND_R8
    ! Clamping físico: fração de gelo em [0,1]
    is%aice = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, is%aice))

    call read_docn_currents(gcomp, is, currTime, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Salinidade: sem arquivo de dado, usar climatologia constante
    is%sss = 35.0_ESMF_KIND_R8

  end subroutine read_docn_fields

  !> @brief Correntes superficiais do arquivo opcional; sem arquivo, ou se a
  !! leitura falhar, a componente fica zero.
  !! @param[inout] gcomp     componente DOCN
  !! @param[inout] is        estado interno (buffers dos campos)
  !! @param[in]    currTime  instante corrente
  !! @param[out]   rc        código de retorno
  subroutine read_docn_currents(gcomp, is, currTime, rc)
    type(ESMF_GridComp),      intent(inout) :: gcomp
    type(DOCN_InternalState), intent(inout) :: is
    type(ESMF_Time),          intent(in)    :: currTime
    integer,                  intent(out)   :: rc

    rc = ESMF_SUCCESS

    ! Correntes superficiais (arquivo opcional)
    if (len_trim(cfg_docn_cur_file) > 0) then
      call ReadOcnFieldInterp(gcomp, trim(cfg_docn_cur_file), &
        trim(cfg_docn_cur_u_varname), &
        currTime, cfg_docn_nx, cfg_docn_ny, is%uocn, rc)
      if (rc /= ESMF_SUCCESS) then
        call log_warning(COMP_DOCN, 'falha uo: corrente zonal = 0')
        is%uocn = 0.0_ESMF_KIND_R8; rc = ESMF_SUCCESS
      else
        ! Fill value OSCAR = -999.0 — limiar |v|>10 m/s captura fills oceânicos
        ! e valores fisicamente impossíveis (correntes reais: 0.01–3 m/s).
        where (abs(is%uocn) >= 10.0_ESMF_KIND_R8) is%uocn = 0.0_ESMF_KIND_R8
      end if
      call ReadOcnFieldInterp(gcomp, trim(cfg_docn_cur_file), &
        trim(cfg_docn_cur_v_varname), &
        currTime, cfg_docn_nx, cfg_docn_ny, is%vocn, rc)
      if (rc /= ESMF_SUCCESS) then
        call log_warning(COMP_DOCN, 'falha vo: corrente meridional = 0')
        is%vocn = 0.0_ESMF_KIND_R8; rc = ESMF_SUCCESS
      else
        where (abs(is%vocn) >= 10.0_ESMF_KIND_R8) is%vocn = 0.0_ESMF_KIND_R8
      end if
    else
      is%uocn = 0.0_ESMF_KIND_R8
      is%vocn = 0.0_ESMF_KIND_R8
    end if

  end subroutine read_docn_currents


  !> @brief Preenche um campo do State com um valor constante.
  !! @param[inout] state  State que contém o campo
  !! @param[in]    name   nome do campo
  !! @param[in]    value  valor atribuído a todos os pontos
  !! @param[out]   rc     código de retorno
  subroutine FillFieldConst(state, name, value, rc)
    type(ESMF_State),    intent(inout) :: state
    character(len=*),    intent(in)    :: name
    real(ESMF_KIND_R8),  intent(in)    :: value
    integer,             intent(out)   :: rc

    type(ESMF_Field)            :: field
    real(ESMF_KIND_R8), pointer :: fptr(:,:)

    rc = ESMF_SUCCESS
    call ESMF_StateGet(state, itemName=trim(name), field=field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fptr = value
    nullify(fptr)

  end subroutine FillFieldConst

end module DOCN_cap_mod
