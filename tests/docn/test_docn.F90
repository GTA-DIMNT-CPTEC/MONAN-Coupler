!> @file test_docn.F90
!! @brief Teste de regressão do oceano de dados (DOCN) num driver NUOPC mínimo.
!!
!! O driver registra o DOCN (componente OCN), um componente fonte (SRC) que
!! anuncia e exporta os 14 campos que o DOCN importa e importa os 6 que ele
!! exporta, e os dois conectores entre eles. O relógio vai de 2026-03-29 06h
!! a 2026-03-30 18h, com passo de 9 h (4 passos), sobre os arquivos
!! sintéticos de tests/docn/gera-dados-docn.py.
!!
!! Com o argumento "inicio", o programa para depois da inicialização (valores
!! iniciais e carimbo de tempo de InitializeDataComplete); sem argumento, roda
!! os 4 passos. Em ambos os casos, cada PET grava saida_<pet>.bin com o nome,
!! os limites, o carimbo de tempo e os valores de cada campo exportado pelo
!! DOCN. O DOCN grava também os diagnósticos em diag_import/, conforme o
!! nuopc.input do cenário.
!!
!! Usado por tests/docn/compara-docn.bash; não entra no executável.
module tsrc_mod
  use ESMF
  use NUOPC
  use NUOPC_Model, modelSS => SetServices
  implicit none
  private
  public :: SetServices
  character(len=16), parameter :: EXPN(14) = [character(len=16) :: "Foxx_taux","Foxx_tauy","Foxx_sen", &
    "Foxx_evap","Foxx_lwnet","Foxx_swnet_vdr","Foxx_swnet_vdf","Foxx_swnet_idr","Foxx_swnet_idf", &
    "Faxa_rain","Faxa_snow","Sa_pslv","Si_ifrac","So_duu10n"]
  character(len=16), parameter :: IMPN(6) = [character(len=16) :: "So_t","Si_ifrac","Sf_zorl","So_s","So_u","So_v"]
contains
  subroutine SetServices(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    call NUOPC_CompDerive(m, modelSS, rc=rc); if (rc/=ESMF_SUCCESS) return
    call ESMF_GridCompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, userRoutine=P0, phase=0, rc=rc)
    call NUOPC_CompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv03p1"/), userRoutine=Adv, rc=rc)
    call NUOPC_CompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv03p3"/), userRoutine=Rea, rc=rc)
    call NUOPC_CompSpecialize(m, specLabel=label_Advance, specRoutine=Adva, rc=rc)
    call NUOPC_CompSpecialize(m, specLabel=label_DataInitialize, specRoutine=DInit, rc=rc)
  end subroutine
  subroutine P0(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    call NUOPC_CompFilterPhaseMap(m, ESMF_METHOD_INITIALIZE, acceptStringList=(/"IPDv03p"/), rc=rc)
  end subroutine
  subroutine Adv(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    integer :: i
    rc = ESMF_SUCCESS
    do i = 1, 14
      call NUOPC_Advertise(es, StandardName=trim(EXPN(i)), rc=rc); if (rc/=ESMF_SUCCESS) return
    end do
    do i = 1, 6
      call NUOPC_Advertise(is, StandardName=trim(IMPN(i)), rc=rc); if (rc/=ESMF_SUCCESS) return
    end do
  end subroutine
  subroutine Rea(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    type(ESMF_Grid) :: g
    type(ESMF_Field) :: f
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: i
    g = ESMF_GridCreate1PeriDimUfrm(maxIndex=[72,36], minCornerCoord=[0._ESMF_KIND_R8,-90._ESMF_KIND_R8], &
        maxCornerCoord=[360._ESMF_KIND_R8,90._ESMF_KIND_R8], staggerLocList=[ESMF_STAGGERLOC_CENTER], rc=rc)
    if (rc/=ESMF_SUCCESS) return
    do i = 1, 14
      f = ESMF_FieldCreate(g, typekind=ESMF_TYPEKIND_R8, name=trim(EXPN(i)), rc=rc)
      call ESMF_FieldGet(f, farrayPtr=p, rc=rc); p = 1.0_ESMF_KIND_R8
      call NUOPC_Realize(es, field=f, rc=rc); if (rc/=ESMF_SUCCESS) return
    end do
    do i = 1, 6
      f = ESMF_FieldCreate(g, typekind=ESMF_TYPEKIND_R8, name=trim(IMPN(i)), rc=rc)
      call NUOPC_Realize(is, field=f, rc=rc); if (rc/=ESMF_SUCCESS) return
    end do
  end subroutine
  subroutine DInit(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    type(ESMF_State) :: es
    type(ESMF_Clock) :: c
    call NUOPC_ModelGet(m, modelClock=c, exportState=es, rc=rc)
    call NUOPC_SetTimestamp(es, c, rc=rc)
    call NUOPC_CompAttributeSet(m, name="InitializeDataComplete", value="true", rc=rc)
  end subroutine
  subroutine Adva(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
  end subroutine
end module

module tdrv_mod
  use ESMF
  use NUOPC
  use NUOPC_Driver, driverSS => SetServices, label_SetModelServices => label_SetModelServices
  use DOCN_cap_mod, only: docnSS => SetServices
  use tsrc_mod, only: srcSS => SetServices
  use NUOPC_Connector, only: cplSS => SetServices
  implicit none
  private
  public :: SetServices
contains
  subroutine SetServices(driver, rc)
    type(ESMF_GridComp) :: driver
    integer, intent(out) :: rc
    call NUOPC_CompDerive(driver, driverSS, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSpecialize(driver, specLabel=label_SetModelServices, specRoutine=SetModelServices, rc=rc)
  end subroutine
  subroutine SetModelServices(driver, rc)
    type(ESMF_GridComp) :: driver
    integer, intent(out) :: rc
    type(ESMF_GridComp) :: child
    type(ESMF_Time) :: t0, t1
    type(ESMF_TimeInterval) :: dt
    type(ESMF_Clock) :: clock
    call NUOPC_DriverAddComp(driver, "OCN", docnSS, comp=child, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompAttributeSet(child, name="Verbosity", value="0", rc=rc)
    call NUOPC_DriverAddComp(driver, "SRC", srcSS, comp=child, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_DriverAddComp(driver, srcCompLabel="SRC", dstCompLabel="OCN", compSetServicesRoutine=cplSS, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_DriverAddComp(driver, srcCompLabel="OCN", dstCompLabel="SRC", compSetServicesRoutine=cplSS, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_TimeSet(t0, yy=2026, mm=3, dd=29, h=6, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    call ESMF_TimeSet(t1, yy=2026, mm=3, dd=30, h=18, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    call ESMF_TimeIntervalSet(dt, h=9, rc=rc)
    clock = ESMF_ClockCreate(dt, t0, stopTime=t1, rc=rc)
    call ESMF_GridCompSet(driver, clock=clock, rc=rc)
  end subroutine
end module

program test_docn
  use ESMF
  use NUOPC
  use coupler_config_mod, only: config_read
  use NUOPC_Driver, only: NUOPC_DriverGetComp
  use tdrv_mod, only: tdrvSS => SetServices
  implicit none
  type(ESMF_GridComp) :: drv, ocn
  type(ESMF_State) :: es
  type(ESMF_Field) :: f
  type(ESMF_Time) :: ts
  real(ESMF_KIND_R8), pointer :: p(:,:)
  integer :: rc, urc, localPet, u, k, n, yy, mm, dd, hh
  character(len=64), allocatable :: names(:)
  character(len=64) :: fn
  character(len=16) :: mode
  type(ESMF_VM) :: vm
  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, defaultLogFilename='teste', logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call ESMF_VMGetGlobal(vm, rc=rc); call ESMF_VMGet(vm, localPet=localPet, rc=rc)
  call config_read(rc, 'nuopc.input')
  call NUOPC_FieldDictionarySetAutoAdd(.true., rc=rc)
  drv = ESMF_GridCompCreate(name="drv", rc=rc)
  call ESMF_GridCompSetServices(drv, tdrvSS, userRc=urc, rc=rc); call chk('ss')
  call ESMF_GridCompInitialize(drv, userRc=urc, rc=rc); call chk('init')
  call get_command_argument(1, mode)
  if (trim(mode) /= 'inicio') then
    call ESMF_GridCompRun(drv, userRc=urc, rc=rc); call chk('run')
  end if
  call NUOPC_DriverGetComp(drv, "OCN", comp=ocn, rc=rc); call chk('get')
  call ESMF_GridCompGet(ocn, exportState=es, rc=rc)
  call ESMF_StateGet(es, itemCount=n, rc=rc); allocate(names(n))
  call ESMF_StateGet(es, itemNameList=names, rc=rc)
  write(fn,'(A,I0,A)') 'saida_', localPet, '.bin'
  open(newunit=u, file=fn, form='unformatted', access='stream', status='replace')
  do k = 1, n
    call ESMF_StateGet(es, itemName=trim(names(k)), field=f, rc=rc)
    call ESMF_FieldGet(f, farrayPtr=p, rc=rc)
    call NUOPC_GetTimestamp(f, time=ts, rc=rc)
    call ESMF_TimeGet(ts, yy=yy, mm=mm, dd=dd, h=hh, rc=rc)
    write(u) names(k), lbound(p), ubound(p), yy, mm, dd, hh, p
  end do
  close(u)
  call ESMF_GridCompFinalize(drv, userRc=urc, rc=rc)
  call ESMF_Finalize(rc=rc)
contains
  subroutine chk(w)
    character(*), intent(in) :: w
    if (rc /= ESMF_SUCCESS .or. urc /= ESMF_SUCCESS) then
      print *, 'FALHA em ', w, rc, urc
      call ESMF_Finalize(endflag=ESMF_END_ABORT)
    end if
  end subroutine
end program
