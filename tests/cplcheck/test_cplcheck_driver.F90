!> @file test_cplcheck_driver.F90
!! @brief Conferência do mapa de acoplamento num driver NUOPC mínimo.
!!
!! Quatro componentes de teste, com os rótulos do driver real (MPAS, MED,
!! OCN e ICE), anunciam as mesmas listas de campos que os caps anunciam hoje
!! na configuração de produção (escritas aqui a partir dos caps, não do mapa)
!! e são ligados pelos mesmos seis conectores do driver real. A
!! especialização ModifyCplLists do driver de teste chama
!! cpl_write_methods e cpl_check_coupling, como o esm.F90, e o
!! relatório sai no log do PET 0 (linhas CPL-REL:).
!!
!! Nos modos normal e mediador, o dicionário do NUOPC é o do acoplador
!! (cpl_nuopc_dictionary, como no esm.F90): só os nomes de FIELDS, sem
!! acréscimo automático.
!!
!! Com o argumento "defeito", o OCN anuncia uma importação a mais (So_teste)
!! e o MED deixa de anunciar So_omask, e a conferência tem de acusar as
!! diferenças; desde a R-FASE11-25, ela também interrompe a inicialização
!! logo depois do relatório. Para que So_teste chegue à conferência, este
!! modo usa o acréscimo automático do dicionário. Com o argumento
!! "dicionario", as listas são as do modo defeito, mas o dicionário é o do
!! acoplador, e o anúncio de So_teste tem de parar a inicialização com a
!! mensagem do NUOPC. Os campos são realizados só se conectados, numa grade
!! regular de 36 x 18, para que a inicialização termine no modo normal.
!!
!! Com o argumento "mediador", o componente MED é o mediador real
!! (MED_cap_MONAN_mod): a conferência compara com o mapa o que ele de fato
!! anuncia. A inicialização para logo depois da conferência (ModifyCplLists
!! devolve falha de propósito), antes da realização, que precisaria das
!! grades reais; o programa então termina com "FALHA em initialize", o que
!! nesse caso é o esperado.
!!
!! Usado por tests/cplcheck/confere-cplcheck.bash; não entra no executável.
module tcomp_mod
  use ESMF
  use NUOPC
  use NUOPC_Model, modelSS => SetServices
  implicit none
  private
  public :: SetServices, defect

  logical :: defect = .false.    !< modo com defeitos de propósito

  character(len=24), parameter :: ATM_IMP(7) = [character(len=24) :: &
    'Sx_tsfc', 'Si_ifrac', 'So_u', 'So_v', 'Sf_zorl', 'Sf_albedo', 'Sx_omask']
  character(len=24), parameter :: ATM_EXP(13) = [character(len=24) :: &
    'Sa_pslv_mpas', 'Sa_tbot_mpas', 'Sa_u10m_mpas', 'Sa_v10m_mpas', 'Faxa_swdn_mpas', &
    'Faxa_lwdn_mpas', 'Faxa_rain_mpas', 'Sa_shum_mpas', 'Faxa_snow_mpas', 'Faxa_sen_mpas', &
    'Faxa_lat_mpas', 'Faxa_taux_mpas', 'Faxa_tauy_mpas']
  character(len=24), parameter :: MED_IMP(23) = [character(len=24) :: &
    'Sa_u10m_mpas', 'Sa_v10m_mpas', 'Sa_tbot_mpas', 'Sa_pslv_mpas', 'Faxa_swdn_mpas', &
    'Faxa_lwdn_mpas', 'Faxa_rain_mpas', 'Sa_shum_mpas', 'Faxa_snow_mpas', 'Faxa_sen_mpas', &
    'Faxa_lat_mpas', 'Faxa_taux_mpas', 'Faxa_tauy_mpas', 'So_t', 'So_u', 'So_v', 'So_omask', &
    'Si_ifrac_sis2', 'Si_avsdr_sis2', 'Si_avsdf_sis2', 'Si_anidr_sis2', 'Si_anidf_sis2', 'Si_t_sis2']
  character(len=24), parameter :: MED_EXP(31) = [character(len=24) :: &
    'Foxx_taux', 'Foxx_tauy', 'Foxx_sen', 'Foxx_evap', 'Foxx_lwnet', 'Foxx_swnet_vdr', &
    'Foxx_swnet_vdf', 'Foxx_swnet_idr', 'Foxx_swnet_idf', 'Faxa_rain', 'Faxa_snow', 'Sa_pslv', &
    'Si_ifrac', 'So_duu10n', 'So_t', 'So_u', 'So_v', 'Sf_zorl', 'Faxa_coszen', 'Sf_albedo', &
    'Fioi_taux', 'Fioi_tauy', 'Fioi_sen', 'Fioi_evap', 'Fioi_lwnet', 'Fioi_swnet_vdr', &
    'Fioi_swnet_vdf', 'Fioi_swnet_idr', 'Fioi_swnet_idf', 'Sx_tsfc', 'Sx_omask']
  character(len=24), parameter :: OCN_IMP(14) = [character(len=24) :: &
    'Foxx_taux', 'Foxx_tauy', 'Foxx_sen', 'Foxx_evap', 'Foxx_lwnet', 'Foxx_swnet_vdr', &
    'Foxx_swnet_vdf', 'Foxx_swnet_idr', 'Foxx_swnet_idf', 'Faxa_rain', 'Faxa_snow', 'Sa_pslv', &
    'Si_ifrac', 'So_duu10n']
  character(len=24), parameter :: OCN_EXP(7) = [character(len=24) :: &
    'So_t', 'So_s', 'So_u', 'So_v', 'So_omask', 'Fioo_q', 'Si_ifrac']
  character(len=24), parameter :: ICE_IMP(16) = [character(len=24) :: &
    'Fioi_taux', 'Fioi_tauy', 'Fioi_sen', 'Fioi_evap', 'Fioi_lwnet', 'Fioi_swnet_vdr', &
    'Fioi_swnet_vdf', 'Fioi_swnet_idr', 'Fioi_swnet_idf', 'Faxa_rain', 'Faxa_snow', 'Sa_pslv', &
    'Faxa_coszen', 'So_t', 'So_u', 'So_v']
  character(len=24), parameter :: ICE_EXP(6) = [character(len=24) :: &
    'Si_ifrac_sis2', 'Si_avsdr_sis2', 'Si_avsdf_sis2', 'Si_anidr_sis2', 'Si_anidf_sis2', 'Si_t_sis2']

contains

  subroutine SetServices(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    call NUOPC_CompDerive(m, modelSS, rc=rc); if (rc /= ESMF_SUCCESS) return
    call ESMF_GridCompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, userRoutine=Phase0, phase=0, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv03p1"/), &
      userRoutine=Advertise, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv03p3"/), &
      userRoutine=Realize, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSpecialize(m, specLabel=label_Advance, specRoutine=Advance, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSpecialize(m, specLabel=label_DataInitialize, specRoutine=init_data, rc=rc)
  end subroutine SetServices

  !> Fase 0: usa as fases IPDv03 (anúncio em p1, realização em p3).
  subroutine Phase0(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    call NUOPC_CompFilterPhaseMap(m, ESMF_METHOD_INITIALIZE, acceptStringList=(/"IPDv03p"/), rc=rc)
  end subroutine Phase0

  subroutine Advertise(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    character(len=ESMF_MAXSTR) :: name
    call ESMF_GridCompGet(m, name=name, rc=rc); if (rc /= ESMF_SUCCESS) return
    select case (trim(name))
    case ('MPAS')
      call advertise_list(is, ATM_IMP, rc); call advertise_list(es, ATM_EXP, rc)
    case ('MED')
      if (defect) then
        call advertise_list(is, pack(MED_IMP, MED_IMP /= 'So_omask'), rc)
      else
        call advertise_list(is, MED_IMP, rc)
      end if
      call advertise_list(es, MED_EXP, rc)
    case ('OCN')
      if (defect) then
        call advertise_list(is, [character(len=24) :: OCN_IMP, 'So_teste'], rc)
      else
        call advertise_list(is, OCN_IMP, rc)
      end if
      if (rc /= ESMF_SUCCESS) return
      call advertise_list(es, OCN_EXP, rc)
    case ('ICE')
      call advertise_list(is, ICE_IMP, rc); call advertise_list(es, ICE_EXP, rc)
    end select
  end subroutine Advertise

  subroutine advertise_list(state, names, rc)
    type(ESMF_State), intent(inout) :: state
    character(len=*), intent(in)    :: names(:)
    integer,          intent(out)   :: rc
    integer :: i
    rc = ESMF_SUCCESS
    do i = 1, size(names)
      call NUOPC_Advertise(state, StandardName=trim(names(i)), rc=rc)
      if (rc /= ESMF_SUCCESS) return
    end do
  end subroutine advertise_list

  subroutine Realize(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    type(ESMF_Grid) :: g
    g = ESMF_GridCreate1PeriDimUfrm(maxIndex=[36,18], minCornerCoord=[0._ESMF_KIND_R8,-90._ESMF_KIND_R8], &
        maxCornerCoord=[360._ESMF_KIND_R8,90._ESMF_KIND_R8], staggerLocList=[ESMF_STAGGERLOC_CENTER], rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_Realize(is, grid=g, selection="realize_connected_remove_others", rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_Realize(es, grid=g, selection="realize_connected_remove_others", rc=rc)
  end subroutine Realize

  !> Dados prontos desde o início: carimbo de tempo e InitializeDataComplete.
  subroutine init_data(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    type(ESMF_State) :: es
    type(ESMF_Clock) :: c
    call NUOPC_ModelGet(m, modelClock=c, exportState=es, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_SetTimestamp(es, c, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompAttributeSet(m, name="InitializeDataComplete", value="true", rc=rc)
  end subroutine init_data

  subroutine Advance(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
  end subroutine Advance

end module tcomp_mod

module tdrv_mod
  use ESMF
  use NUOPC
  use NUOPC_Driver, driverSS => SetServices, label_SetModelServices => label_SetModelServices, &
                    label_ModifyCplLists => label_ModifyCplLists
  use NUOPC_Connector, only: cplSS => SetServices
  use tcomp_mod,       only: compSS => SetServices
  use cpl_check_mod,   only: cpl_check_coupling, cpl_write_methods
  use coupler_config_mod, only: cpl_current_config
  use MED_cap_MONAN_mod, only: medSS => SetServices
  implicit none
  private
  public :: SetServices, real_mediator

  logical :: real_mediator = .false.   !< MED é o mediador real (modo "mediador")
  character(len=4), parameter :: LABELS(4) = ['MPAS', 'MED ', 'OCN ', 'ICE ']
contains
  subroutine SetServices(driver, rc)
    type(ESMF_GridComp) :: driver
    integer, intent(out) :: rc
    call NUOPC_CompDerive(driver, driverSS, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSpecialize(driver, specLabel=label_SetModelServices, specRoutine=SetModelServices, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSpecialize(driver, specLabel=label_ModifyCplLists, specRoutine=ModifyCplLists, rc=rc)
  end subroutine SetServices

  subroutine SetModelServices(driver, rc)
    type(ESMF_GridComp) :: driver
    integer, intent(out) :: rc
    type(ESMF_GridComp) :: child
    type(ESMF_Time) :: t0, t1
    type(ESMF_TimeInterval) :: dt
    type(ESMF_Clock) :: clock
    integer :: i
    do i = 1, 4
      if (real_mediator .and. LABELS(i) == 'MED') then
        call NUOPC_DriverAddComp(driver, 'MED', medSS, comp=child, rc=rc)
      else
        call NUOPC_DriverAddComp(driver, trim(LABELS(i)), compSS, comp=child, rc=rc)
      end if
      if (rc /= ESMF_SUCCESS) return
    end do
    call connect('MPAS', 'MED', rc); call connect('OCN', 'MED', rc); call connect('MED', 'OCN', rc)
    call connect('MED', 'MPAS', rc); call connect('MED', 'ICE', rc); call connect('ICE', 'MED', rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_TimeSet(t0, yy=2026, mm=3, dd=29, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    call ESMF_TimeSet(t1, yy=2026, mm=3, dd=29, h=1, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    call ESMF_TimeIntervalSet(dt, h=1, rc=rc)
    clock = ESMF_ClockCreate(dt, t0, stopTime=t1, rc=rc)
    call ESMF_GridCompSet(driver, clock=clock, rc=rc)
  contains
    subroutine connect(src, dst, rc)
      character(len=*), intent(in) :: src, dst
      integer, intent(inout) :: rc
      if (rc /= ESMF_SUCCESS) return
      call NUOPC_DriverAddComp(driver, srcCompLabel=src, dstCompLabel=dst, &
                               compSetServicesRoutine=cplSS, rc=rc)
    end subroutine connect
  end subroutine SetModelServices

  subroutine ModifyCplLists(driver, rc)
    type(ESMF_GridComp) :: driver
    integer, intent(out) :: rc
    type(ESMF_VM) :: vm
    integer :: n_method, n_full
    call cpl_write_methods(driver, LABELS, [character(len=4) :: 'ATM', 'MED', 'OCN', 'ICE'], &
                             n_method, n_full, rc)
    if (rc /= ESMF_SUCCESS .or. n_full /= 0) then
      rc = ESMF_FAILURE
      return
    end if
    call cpl_check_coupling(driver, cpl_current_config(), LABELS, &
      [character(len=4) :: 'ATM', 'MED', 'OCN', 'ICE'], rc)
    if (real_mediator) then
      ! para antes da realização do mediador real (ver o cabeçalho); a
      ! barreira espera o PET 0 terminar o relatório, porque o primeiro PET a
      ! sair com erro aborta o MPI e cortaria o log do PET 0 no meio
      call ESMF_LogWrite('TESTE: parada depois da conferencia', ESMF_LOGMSG_INFO)
      call ESMF_LogFlush(rc=rc)
      call ESMF_VMGetCurrent(vm, rc=rc)
      call ESMF_VMBarrier(vm, rc=rc)
      rc = ESMF_FAILURE
    end if
  end subroutine ModifyCplLists
end module tdrv_mod

program test_cplcheck_driver
  use ESMF
  use NUOPC
  use coupler_config_mod, only: config_read
  use cpl_check_mod,      only: cpl_nuopc_dictionary
  use tcomp_mod, only: defect
  use tdrv_mod,  only: tdrvSS => SetServices, real_mediator
  implicit none
  type(ESMF_GridComp) :: drv
  integer :: rc, urc
  character(len=16) :: mode

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, defaultLogFilename='teste', &
                       logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call config_read(rc, 'nuopc.input')
  if (rc /= ESMF_SUCCESS) call fail_at('config_read')
  call get_command_argument(1, mode)
  defect = trim(mode) == 'defeito' .or. trim(mode) == 'dicionario'
  real_mediator = trim(mode) == 'mediador'
  if (trim(mode) == 'defeito') then
    call NUOPC_FieldDictionarySetAutoAdd(.true., rc=rc)
  else
    call cpl_nuopc_dictionary(rc)
  end if
  if (rc /= ESMF_SUCCESS) call fail_at('dicionario')
  drv = ESMF_GridCompCreate(name='drv', rc=rc)
  call ESMF_GridCompSetServices(drv, tdrvSS, userRc=urc, rc=rc)
  if (rc /= ESMF_SUCCESS .or. urc /= ESMF_SUCCESS) call fail_at('setservices')
  call ESMF_GridCompInitialize(drv, userRc=urc, rc=rc)
  if (rc /= ESMF_SUCCESS .or. urc /= ESMF_SUCCESS) call fail_at('initialize')
  call ESMF_GridCompFinalize(drv, userRc=urc, rc=rc)
  call ESMF_Finalize(rc=rc)
contains
  subroutine fail_at(location)
    character(len=*), intent(in) :: location
    print *, 'FALHA em ', location
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
  end subroutine fail_at
end program test_cplcheck_driver
