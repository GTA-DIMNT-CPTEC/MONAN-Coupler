!==============================================================================!
! DOCN_cap.F90 — Data Ocean NUOPC Component (MOM6 forçado por dados)        !
!                                                                              !
! Analogia exata com DATM_cap.F90 (Data Atmosphere / JRA55) porém para o      !
! componente oceânico: lê campos de SST e gelo marinho de arquivos NetCDF      !
! (ex: OISST v2.1 diário, OSTIA) e os exporta para o mediador MED_cap e para  !
! o cap atmosférico MPAS (condições de contorno de superfície).                !
!                                                                              !
! Campos exportados (para MED e para OCN→MPAS):                               !
!   So_t      temperatura da superfície do mar (SST)    [K]                   !
!   Si_ifrac  fração de gelo marinho                    [0–1]                 !
!   Sf_zorl   comprimento de rugosidade oceânica        [m]                   !
!   So_s      salinidade superficial do mar (opcional)  [psu]                 !
!   So_u      corrente superficial zonal                [m/s]                 !
!   So_v      corrente superficial meridional           [m/s]                 !
!                                                                              !
! Campos importados (do mediador MED→OCN — recebidos mas não processados):    !
!   Foxx_taux, Foxx_tauy, Foxx_sen, Foxx_evap, Foxx_lwnet,                   !
!   Foxx_swnet_vdr, Foxx_swnet_vdf, Foxx_swnet_idr, Foxx_swnet_idf,          !
!   Faxa_rain, Faxa_snow, Sa_pslv, Si_ifrac, So_duu10n                       !
!                                                                              !
! Modo de operação único (nuopc.input &nuopc_docn):                           !
!   docn_mode = 'netcdf'   — lê SST/gelo/correntes de arquivo NetCDF          !
!                             com interpolação temporal linear entre snapshots  !
!                                                                              !
! Estratégia de leitura paralela:                                              !
!   PET0 lê o campo global inteiro do NetCDF e faz broadcast via              !
!   ESMF_VMBroadcast. Cada PET copia o seu subdomínio local.                  !
!   Adequado para grids até ~1440×1080 (OISST 0.25°): ~12 MB/campo/snapshot. !
!                                                                              !
! Arquivo NetCDF esperado (OISST v2.1 compatível, CF-1.8):                   !
!   dims  : lon(1440), lat(720), time(N)                                      !
!   vars  : sst(lon,lat,time) [°C], aice(lon,lat,time) [0–1]                  !
!   Nota  : SST é convertida de °C → K internamente (+273.15).                !
!           Se o arquivo já estiver em K, ajuste SST_CELSIUS_TO_K = 0.0.      !
!                                                                              !
! Referência de design: DATM_cap.F90 (JRA55), AtmOcnMedPetListProto/ESMF.    !
! Versão 2.0 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026.           !
!   Remoção do modo 'stub' (dados sintéticos constantes) — produção OISST.   !
!==============================================================================!

module DOCN_cap_mod

  use ESMF
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
  use ESMF, only: ESMF_LogFoundError, ESMF_LogWrite, ESMF_LOGMSG_INFO
  use ESMF, only: ESMF_VM, ESMF_VMGetGlobal, ESMF_VMGet, ESMF_VMBroadcast
  use ESMF, only: ESMF_CALKIND_GREGORIAN

  use docn_cap_netcdf_mod, only: ReadOcnFieldInterp, WriteDOCNDiag
  use coupler_utils_mod,   only: ChkErr, int_to_str

  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Advertise, NUOPC_Realize
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
                                  cfg_grid_res_deg

  implicit none
  private

  public :: SetServices
  public :: SetVM

  ! ── Conversão de unidades ──────────────────────────────────────────────────
  ! OISST v2.1 armazena SST em °C. Ajuste para 0.0 se o arquivo já for em K.
  real(ESMF_KIND_R8), parameter :: SST_CELSIUS_TO_K = 273.15_ESMF_KIND_R8

  ! ── Rugosidade oceânica padrão ─────────────────────────────────────────────
  real(ESMF_KIND_R8), parameter :: ZORL_DEFAULT = 0.001_ESMF_KIND_R8  ! [m]

  ! ── Campos exportados (OCN → MED e OCN → MPAS) ───────────────────────────
  integer, parameter :: N_EXP = 6
  character(len=32), parameter :: EXP_NAMES(N_EXP) = [ &
    "So_t    ", &  ! SST [K]
    "Si_ifrac", &  ! Fracao de gelo [0-1]
    "Sf_zorl ", &  ! Rugosidade [m]
    "So_s    ", &  ! Salinidade superficial [psu]  (opcional - padrao 35 psu)
    "So_u    ", &  ! Corrente zonal [m/s]          (opcional - padrao 0.0)
    "So_v    " ]   ! Corrente meridional [m/s]     (opcional - padrao 0.0)

  ! ── Campos importados (MED → OCN) ─────────────────────────────────────────
  integer, parameter :: N_IMP = 14
  character(len=32), parameter :: IMP_NAMES(N_IMP) = [ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", &
    "Foxx_lwnet    ", "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", &
    "Foxx_swnet_idf", "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", &
    "Si_ifrac      ", "So_duu10n     " ]

  !----------------------------------------------------------------------------
  ! Estado interno do DOCN
  !----------------------------------------------------------------------------
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

  !=============================================================================
  ! SetServices — registra fases IPDv03 e especializa ModelAdvance
  !=============================================================================
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer,              intent(out)   :: rc

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

    call NUOPC_CompSpecialize(gcomp, &
      specLabel=model_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, &
      specLabel=model_label_Advance, &
      specRoutine=ModelAdvance, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_LogWrite('DOCN: SetServices concluido', ESMF_LOGMSG_INFO)

  end subroutine SetServices

  !=============================================================================
  ! InitializeP0 — filtra protocolo para IPDv03
  !=============================================================================
  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer,              intent(out)   :: rc

    rc = ESMF_SUCCESS
    call NUOPC_CompFilterPhaseMap(gcomp, ESMF_METHOD_INITIALIZE, &
      acceptStringList=(/"IPDv03p"/), rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

  end subroutine InitializeP0

  !=============================================================================
  ! InitializeAdvertise — anuncia campos de SST/gelo/corrente para o MED e MPAS
  !
  ! Todos os N_IMP campos importados (fluxos do mediador MED→OCN) são anunciados.
  ! O conector NUOPC MED→OCN cria RouteHandles bilineares na grade OISST nativa
  ! (1440×720 com decomposição 2D via B-57: sqrt(petCount) tiles por dimensão,
  ! garantindo colunas ≥2 e evitando o erro "DE width 1" em qualquer petCount).
  !
  ! Campos exportados (N_EXP = 6): So_t, Si_ifrac, Sf_zorl, So_s, So_u, So_v.
  ! Campos importados (N_IMP = 14): Foxx_*, Faxa_*, Sa_pslv, Si_ifrac, So_duu10n.
  !=============================================================================
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer,              intent(out)   :: rc

    integer :: i

    rc = ESMF_SUCCESS

    ! Anuncia todos os campos importados do mediador (MED→OCN).
    do i = 1, N_IMP
      call NUOPC_Advertise(importState, StandardName=trim(IMP_NAMES(i)), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    ! Anuncia campos exportados para MED e para OCN→MPAS.
    do i = 1, N_EXP
      call NUOPC_Advertise(exportState, StandardName=trim(EXP_NAMES(i)), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    call ESMF_LogWrite('DOCN: InitializeAdvertise concluido (' &
      //int_to_str(N_EXP)//' exp, ' &
      //int_to_str(N_IMP)//' imp)', ESMF_LOGMSG_INFO)

  end subroutine InitializeAdvertise

  !=============================================================================
  ! InitializeRealize — cria grade regular lat/lon e realiza campos
  !
  ! Grade configurável via nuopc.input (&nuopc_docn):
  !   docn_nx = 1440  (OISST 0.25°)   ou  360 (1.0°)
  !   docn_ny =  720  (OISST 0.25°)   ou  180 (1.0°)
  ! Coordenadas: lon=[0.125..359.875], lat=[-89.875..89.875] (centros de célula).
  !=============================================================================
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

    rc = ESMF_SUCCESS

    ! Grade DOCN: resolução nativa do dado oceânico (nuopc.input &nuopc_docn).
    ! OISST 0.25° → docn_nx=1440, docn_ny=720.
    ! Grade 1°    → docn_nx= 360, docn_ny=180.
    nx = cfg_docn_nx
    ny = cfg_docn_ny
    dx = 360.0_ESMF_KIND_R8 / real(nx, ESMF_KIND_R8)
    dy = 180.0_ESMF_KIND_R8 / real(ny, ESMF_KIND_R8)

    ! B-38 (fix): obter petCount para definir decomposicao explicitamente.
    ! ESMF_GridCreate1PeriDim sem regDecomp usa decomposicao default que,
    ! em ESMF 8.9.1, pode gerar DEs de largura 1 na dimensao latitudinal
    ! quando petCount > ny/2. Isso causa falha no regridding bilinear
    ! do conector MED->OCN com o erro:
    !   "not supported on Grids that contain a DE of width 1"
    ! Fix: forcar decomposicao 1D exclusivamente na dimensao longitudinal
    ! (dim 1 = periodica): cada PET recebe nx/petCount colunas e TODAS
    ! as ny linhas de latitude. Com nx=1440 e petCount=128:
    !   1440/128 = 11.25 -> min 11 colunas/PET >> 1 → OK para bilinear.
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! B-57 (fix B-46/B-52): regDecomp 2D com tiles quadradas — evita strips extremos.
    !
    ! PROBLEMA com B-46 (regDecomp=(/1, min(petCount,ny/2)/)):
    !   Decompõe em latitude → PETs vazios com petCount>ny/2.
    ! PROBLEMA com B-52 (nx_max=nx/2):
    !   netcdf 1440×720 a 512 PETs → regDecomp=(/512,1/) → 2-3 cols×720 rows
    !   → aspecto 256:1 → MOAB trava em ESMF_FieldBundleRegridStore.
    !
    ! SOLUCAO B-57: sqrt(petCount) tiles por dimensão.
    !   nx_tiles_target = nint(sqrt(N)) → aspecto ≈ 1.
    !   nx_max = min(target, nx/2) → garante col ≥ 2.
    !
    !   N=4:   sqrt=2  → nx_max=2   regDecomp=(/2,2/)=4    aspecto 0.5:1 ✓
    !   N=128: sqrt=11 → nx_max=11  regDecomp=(/11,12/)=132 aspecto 0.5:1 ✓
    !   N=512: netcdf(360×180) → regDecomp=(/23,23/)=529  15col× 7row ✓
    !   N=512: netcdf(1440×720)→ regDecomp=(/23,23/)=529  62col×31row ✓

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

      ! B-53: loop sobre DEs locais — com regDecomp 2D e DEs>petCount,
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

    ! Campos importados — anuncia e realiza todos os N_IMP fluxos do mediador.
    call RealizeFields(importState, grid, IMP_NAMES, N_IMP, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Exportados
    call RealizeFields(exportState, grid, EXP_NAMES, N_EXP, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Estado interno
    allocate(iswrap%wrap)
    is             => iswrap%wrap
    is%grid        = grid
    is%initialized = .false.

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_LogWrite('DOCN: InitializeRealize concluido (grade ' &
      //int_to_str(nx)//'x' &
      //int_to_str(ny)//')', ESMF_LOGMSG_INFO)

  end subroutine InitializeRealize

  !=============================================================================
  ! InitializeDataComplete — IPDv03p7: popula exportState e sinaliza conclusao
  !=============================================================================
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer,              intent(out)   :: rc

    type(ESMF_State)               :: exportState
    type(ESMF_Field)               :: field
    type(ESMF_Clock)               :: clock_idc
    type(ESMF_Time)                :: startTime_idc
    integer                        :: fieldCount, i
    integer                        :: fieldCount_ts
    character(len=64), allocatable :: fieldNameList(:)
    character(len=64), allocatable :: fldNames_ts(:)
    real(ESMF_KIND_R8), pointer    :: fptr(:,:)

    rc = ESMF_SUCCESS

    call ESMF_GridCompGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Preencher exportState com valores iniciais fisicamente consistentes
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (fieldCount > 0) then
      allocate(fieldNameList(fieldCount))
      call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      do i = 1, fieldCount
        call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
          field=field, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return

        call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return

        select case (trim(fieldNameList(i)))
          case ('So_t')
            ! SST inicial do namelist &nuopc_atm_bnd (cfg_sst_default)
            fptr = real(cfg_sst_default, ESMF_KIND_R8)
          case ('Si_ifrac')
            fptr = real(cfg_ice_fraction_default, ESMF_KIND_R8)
          case ('Sf_zorl')
            fptr = ZORL_DEFAULT
          case ('So_s')
            fptr = 35.0_ESMF_KIND_R8   ! salinidade media global [psu]
          case ('So_u', 'So_v')
            fptr = 0.0_ESMF_KIND_R8    ! correntes em repouso
          case default
            fptr = 0.0_ESMF_KIND_R8
        end select
        nullify(fptr)
      end do
      deallocate(fieldNameList)
    end if

    ! Atualizar timestamps: NUOPC_ModelBase verifica que os campos no
    ! importState do componente seguinte estejam no currTime do clock.
    ! Sem NUOPC_SetTimestamp os campos ficam em t=0 e o MPAS rejeita.
    call ESMF_GridCompGet(gcomp, clock=clock_idc, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    ! NUOPC_SetTimestamp recebe ESMF_Time, nao ESMF_Clock
    call ESMF_ClockGet(clock_idc, startTime=startTime_idc, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemCount=fieldCount_ts, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    allocate(fldNames_ts(fieldCount_ts))
    call ESMF_StateGet(exportState, itemNameList=fldNames_ts, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    do i = 1, fieldCount_ts
      call ESMF_StateGet(exportState, itemName=trim(fldNames_ts(i)), &
        field=field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_SetTimestamp(field, startTime_idc, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
    deallocate(fldNames_ts)

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", value="true", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete",  value="true", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_LogWrite('DOCN: InitializeDataComplete SATISFIED', ESMF_LOGMSG_INFO)

  end subroutine InitializeDataComplete

  !=============================================================================
  ! ModelAdvance — lê campos oceânicos do NetCDF e popula exportState
  !
  ! Lê SST e gelo do arquivo com interpolação temporal linear entre snapshots.
  !
  ! Dados esperados (OISST v2.1 ou equivalente CF-1.8):
  !   sst_file: sst(lon,lat,time) em °C, dt=24h (diário)
  !   ice_file: aice(lon,lat,time) em [0-1], dt=24h (diário)
  !   cur_file: uo(lon,lat,time) e vo(lon,lat,time) em m/s (opcional)
  !=============================================================================
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
    integer                  :: year, month, day, hour, minu, sec
    integer                  :: fieldCount, k
    character(len=64), allocatable :: fieldNameList(:)
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
      h=hour, m=minu, s=sec, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    write(msg,'(A,I4,5(A,I2.2))') 'DOCN: avancando para ', year, '-', &
      month, '-', day, ' ', hour, ':', minu, ':', sec
    call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)

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

    ! ── Leitura dos campos oceânicos com interpolação temporal ────────────────
    ! B-56: nomes de variável configuráveis via nuopc.input (docn_*_varname).
    ! OISST v2.1: sst_varname='sst'  ice_varname='icec'
    call ReadOcnFieldInterp(gcomp, trim(cfg_docn_sst_file), &
      trim(cfg_docn_sst_varname), &
      currTime, cfg_docn_nx, cfg_docn_ny, is%sst,  rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="DOCN: falha ao ler SST", &
      line=__LINE__, file=__FILE__)) return
    ! Conversão °C → K (OISST armazena em °C)
    is%sst = is%sst + SST_CELSIUS_TO_K

    call ReadOcnFieldInterp(gcomp, trim(cfg_docn_ice_file), &
      trim(cfg_docn_ice_varname), &
      currTime, cfg_docn_nx, cfg_docn_ny, is%aice, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="DOCN: falha ao ler aice", &
      line=__LINE__, file=__FILE__)) return
    ! Conversão % → fração: cfg_docn_ice_pct=.true. para arquivos em (0–100).
    if (cfg_docn_ice_pct) is%aice = is%aice / 100.0_ESMF_KIND_R8
    ! Clamping físico: fração de gelo em [0,1]
    is%aice = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, is%aice))

    ! Correntes superficiais (arquivo opcional)
    if (len_trim(cfg_docn_cur_file) > 0) then
      call ReadOcnFieldInterp(gcomp, trim(cfg_docn_cur_file), &
        trim(cfg_docn_cur_u_varname), &
        currTime, cfg_docn_nx, cfg_docn_ny, is%uocn, rc)
      if (rc /= ESMF_SUCCESS) then
        call ESMF_LogWrite('DOCN: AVISO: falha uo — corrente zonal = 0', &
          ESMF_LOGMSG_INFO)
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
        call ESMF_LogWrite('DOCN: AVISO: falha vo — corrente meridional = 0', &
          ESMF_LOGMSG_INFO)
        is%vocn = 0.0_ESMF_KIND_R8; rc = ESMF_SUCCESS
      else
        where (abs(is%vocn) >= 10.0_ESMF_KIND_R8) is%vocn = 0.0_ESMF_KIND_R8
      end if
    else
      is%uocn = 0.0_ESMF_KIND_R8
      is%vocn = 0.0_ESMF_KIND_R8
    end if

    ! Salinidade: sem arquivo de dado, usar climatologia constante
    is%sss = 35.0_ESMF_KIND_R8

    ! Escreve campos no exportState
    call PutField(exportState, "So_t",    is%sst,  rc); if (rc/=ESMF_SUCCESS) return
    call PutField(exportState, "Si_ifrac",is%aice, rc); if (rc/=ESMF_SUCCESS) return
    call PutField(exportState, "So_s",    is%sss,  rc); if (rc/=ESMF_SUCCESS) return
    call PutField(exportState, "So_u",    is%uocn, rc); if (rc/=ESMF_SUCCESS) return
    call PutField(exportState, "So_v",    is%vocn, rc); if (rc/=ESMF_SUCCESS) return

    ! Diagnóstico: escrita NetCDF dos campos lidos/preparados a cada passo.
    ! Ativado com write_import_diag=.true. em &nuopc_docn no nuopc.input.
    ! Gera: diag_import/docn_import_YYYYMMDD_HHMMSS.nc (grade DOCN, 1°×1°)
    ! Lido por: postproc_mom6_import.py  (validação de SST/gelo vs fonte)
    if (cfg_write_import_diag) then
      call WriteDOCNDiag(gcomp, currTime, cfg_docn_nx, cfg_docn_ny, rc)
      if (rc /= ESMF_SUCCESS) then
        call ESMF_LogWrite('DOCN: AVISO: WriteDOCNDiag falhou — continuando', &
          ESMF_LOGMSG_WARNING)
        rc = ESMF_SUCCESS
      end if
    end if

    ! Sf_zorl: rugosidade constante (funcao de amplitude de onda nao modelada aqui)
    call FillFieldConst(exportState, "Sf_zorl", ZORL_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Atualizar timestamps de todos os campos exportados
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fieldNameList(k)), &
        field=field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_SetTimestamp(field, nextTime, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
    deallocate(fieldNameList)

    call ESMF_LogWrite('DOCN: ModelAdvance concluido (OISST netcdf)', &
      ESMF_LOGMSG_INFO)

  end subroutine ModelAdvance

  !=============================================================================
  ! RealizeFields — cria e realiza um array de campos numa ESMF_Grid
  !=============================================================================
  subroutine RealizeFields(state, grid, names, n, rc)
    type(ESMF_State),  intent(inout) :: state
    type(ESMF_Grid),   intent(in)    :: grid
    character(len=32), intent(in)    :: names(:)
    integer,           intent(in)    :: n
    integer,           intent(out)   :: rc

    type(ESMF_Field) :: field
    integer          :: i

    rc = ESMF_SUCCESS
    do i = 1, n
      field = ESMF_FieldCreate(grid=grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(names(i)), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(state, field=field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

  end subroutine RealizeFields

  !=============================================================================
  ! PutField — copia array 2D local para campo do exportState
  !=============================================================================
  subroutine PutField(state, name, array, rc)
    type(ESMF_State),    intent(inout) :: state
    character(len=*),    intent(in)    :: name
    real(ESMF_KIND_R8),  intent(in)    :: array(:,:)
    integer,             intent(out)   :: rc

    type(ESMF_Field)            :: field
    real(ESMF_KIND_R8), pointer :: fptr(:,:)

    rc = ESMF_SUCCESS
    call ESMF_StateGet(state, itemName=trim(name), field=field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="PutField DOCN: "//trim(name), &
      line=__LINE__, file=__FILE__)) return
    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fptr = array
    nullify(fptr)

  end subroutine PutField

  !=============================================================================
  ! FillFieldConst — preenche campo do State com valor escalar constante
  !=============================================================================
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
