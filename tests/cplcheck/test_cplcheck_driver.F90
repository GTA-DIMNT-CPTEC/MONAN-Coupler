!> @file test_cplcheck_driver.F90
!! @brief Conferência do mapa de acoplamento num driver NUOPC mínimo.
!!
!! Quatro componentes de teste, com os rótulos do driver real (MPAS, MED,
!! OCN e ICE), anunciam as mesmas listas de campos que os caps anunciam hoje
!! na configuração de produção (escritas aqui a partir dos caps, não do mapa)
!! e são ligados pelos mesmos seis conectores do driver real. A
!! especialização ModifyCplLists do driver de teste chama
!! cpl_check_acoplamento, como o esm.F90, e o relatório sai no log do PET 0
!! (linhas CPL-REL:).
!!
!! Com o argumento "defeito", o OCN anuncia uma importação a mais (So_teste)
!! e o MED deixa de anunciar So_omask, e a conferência tem de acusar as
!! diferenças. Os campos são realizados só se conectados, numa grade
!! regular de 36 x 18, para que a inicialização termine.
!!
!! Usado por tests/cplcheck/confere-cplcheck.bash; não entra no executável.
module tcomp_mod
  use ESMF
  use NUOPC
  use NUOPC_Model, modelSS => SetServices
  implicit none
  private
  public :: SetServices, defeito

  logical :: defeito = .false.   !< modo com defeitos de propósito

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
    call ESMF_GridCompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, userRoutine=Fase0, phase=0, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv03p1"/), &
      userRoutine=Anuncia, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSetEntryPoint(m, ESMF_METHOD_INITIALIZE, phaseLabelList=(/"IPDv03p3"/), &
      userRoutine=Realiza, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSpecialize(m, specLabel=label_Advance, specRoutine=Avanca, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompSpecialize(m, specLabel=label_DataInitialize, specRoutine=IniciaDados, rc=rc)
  end subroutine SetServices

  !> Fase 0: usa as fases IPDv03 (anúncio em p1, realização em p3).
  subroutine Fase0(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    call NUOPC_CompFilterPhaseMap(m, ESMF_METHOD_INITIALIZE, acceptStringList=(/"IPDv03p"/), rc=rc)
  end subroutine Fase0

  subroutine Anuncia(m, is, es, c, rc)
    type(ESMF_GridComp) :: m
    type(ESMF_State) :: is, es
    type(ESMF_Clock) :: c
    integer, intent(out) :: rc
    character(len=ESMF_MAXSTR) :: nome
    call ESMF_GridCompGet(m, name=nome, rc=rc); if (rc /= ESMF_SUCCESS) return
    select case (trim(nome))
    case ('MPAS')
      call anuncia_lista(is, ATM_IMP, rc); call anuncia_lista(es, ATM_EXP, rc)
    case ('MED')
      if (defeito) then
        call anuncia_lista(is, pack(MED_IMP, MED_IMP /= 'So_omask'), rc)
      else
        call anuncia_lista(is, MED_IMP, rc)
      end if
      call anuncia_lista(es, MED_EXP, rc)
    case ('OCN')
      if (defeito) then
        call anuncia_lista(is, [character(len=24) :: OCN_IMP, 'So_teste'], rc)
      else
        call anuncia_lista(is, OCN_IMP, rc)
      end if
      call anuncia_lista(es, OCN_EXP, rc)
    case ('ICE')
      call anuncia_lista(is, ICE_IMP, rc); call anuncia_lista(es, ICE_EXP, rc)
    end select
  end subroutine Anuncia

  subroutine anuncia_lista(estado, nomes, rc)
    type(ESMF_State), intent(inout) :: estado
    character(len=*), intent(in)    :: nomes(:)
    integer,          intent(out)   :: rc
    integer :: i
    rc = ESMF_SUCCESS
    do i = 1, size(nomes)
      call NUOPC_Advertise(estado, StandardName=trim(nomes(i)), rc=rc)
      if (rc /= ESMF_SUCCESS) return
    end do
  end subroutine anuncia_lista

  subroutine Realiza(m, is, es, c, rc)
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
  end subroutine Realiza

  !> Dados prontos desde o início: carimbo de tempo e InitializeDataComplete.
  subroutine IniciaDados(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    type(ESMF_State) :: es
    type(ESMF_Clock) :: c
    call NUOPC_ModelGet(m, modelClock=c, exportState=es, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_SetTimestamp(es, c, rc=rc); if (rc /= ESMF_SUCCESS) return
    call NUOPC_CompAttributeSet(m, name="InitializeDataComplete", value="true", rc=rc)
  end subroutine IniciaDados

  subroutine Avanca(m, rc)
    type(ESMF_GridComp) :: m
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
  end subroutine Avanca

end module tcomp_mod

module tdrv_mod
  use ESMF
  use NUOPC
  use NUOPC_Driver, driverSS => SetServices, label_SetModelServices => label_SetModelServices, &
                    label_ModifyCplLists => label_ModifyCplLists
  use NUOPC_Connector, only: cplSS => SetServices
  use tcomp_mod,       only: compSS => SetServices
  use cpl_check_mod,   only: cpl_check_acoplamento
  implicit none
  private
  public :: SetServices
  character(len=4), parameter :: ROTULOS(4) = ['MPAS', 'MED ', 'OCN ', 'ICE ']
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
      call NUOPC_DriverAddComp(driver, trim(ROTULOS(i)), compSS, comp=child, rc=rc)
      if (rc /= ESMF_SUCCESS) return
    end do
    call liga('MPAS', 'MED', rc); call liga('OCN', 'MED', rc); call liga('MED', 'OCN', rc)
    call liga('MED', 'MPAS', rc); call liga('MED', 'ICE', rc); call liga('ICE', 'MED', rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_TimeSet(t0, yy=2026, mm=3, dd=29, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    call ESMF_TimeSet(t1, yy=2026, mm=3, dd=29, h=1, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    call ESMF_TimeIntervalSet(dt, h=1, rc=rc)
    clock = ESMF_ClockCreate(dt, t0, stopTime=t1, rc=rc)
    call ESMF_GridCompSet(driver, clock=clock, rc=rc)
  contains
    subroutine liga(de, para, rc)
      character(len=*), intent(in) :: de, para
      integer, intent(inout) :: rc
      if (rc /= ESMF_SUCCESS) return
      call NUOPC_DriverAddComp(driver, srcCompLabel=de, dstCompLabel=para, &
                               compSetServicesRoutine=cplSS, rc=rc)
    end subroutine liga
  end subroutine SetModelServices

  subroutine ModifyCplLists(driver, rc)
    type(ESMF_GridComp) :: driver
    integer, intent(out) :: rc
    call cpl_check_acoplamento(driver, ROTULOS, [character(len=4) :: 'ATM', 'MED', 'OCN', 'ICE'], rc)
  end subroutine ModifyCplLists
end module tdrv_mod

program test_cplcheck_driver
  use ESMF
  use NUOPC
  use coupler_config_mod, only: config_read
  use tcomp_mod, only: defeito
  use tdrv_mod,  only: tdrvSS => SetServices
  implicit none
  type(ESMF_GridComp) :: drv
  integer :: rc, urc
  character(len=16) :: modo

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, defaultLogFilename='teste', &
                       logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call config_read(rc, 'nuopc.input')
  if (rc /= ESMF_SUCCESS) call falha('config_read')
  call get_command_argument(1, modo)
  defeito = trim(modo) == 'defeito'
  call NUOPC_FieldDictionarySetAutoAdd(.true., rc=rc)
  drv = ESMF_GridCompCreate(name='drv', rc=rc)
  call ESMF_GridCompSetServices(drv, tdrvSS, userRc=urc, rc=rc)
  if (rc /= ESMF_SUCCESS .or. urc /= ESMF_SUCCESS) call falha('setservices')
  call ESMF_GridCompInitialize(drv, userRc=urc, rc=rc)
  if (rc /= ESMF_SUCCESS .or. urc /= ESMF_SUCCESS) call falha('initialize')
  call ESMF_GridCompFinalize(drv, userRc=urc, rc=rc)
  call ESMF_Finalize(rc=rc)
contains
  subroutine falha(onde)
    character(len=*), intent(in) :: onde
    print *, 'FALHA em ', onde
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
  end subroutine falha
end program test_cplcheck_driver
