!> @file DATM_cap.F90
!! @brief Atmosfera de dados (DATM): campos brutos do JRA55 para o mediador.
!!
!! Componente NUOPC baseado no exemplo AtmOcnMedPetListProto do ESMF. Lê os
!! arquivos do JRA55 (passo de 3 h), interpola no tempo e exporta os campos
!! brutos ao mediador, que calcula os fluxos bulk NCAR (med_bulk_ncar.F90).
!!
!! | Campo     | Grandeza                    | Unidade    | Variável JRA55 |
!! | --------- | --------------------------- | ---------- | -------------- |
!! | Sa_u10m   | vento zonal a 10 m          | m s-1      | uas            |
!! | Sa_v10m   | vento meridional a 10 m     | m s-1      | vas            |
!! | Sa_tbot   | temperatura do ar a 2 m     | K          | tas            |
!! | Sa_shum   | umidade específica          | kg kg-1    | huss           |
!! | Sa_pslv   | pressão ao nível do mar     | Pa         | psl            |
!! | Faxa_swdn | radiação solar descendente  | W m-2      | rsds           |
!! | Faxa_lwdn | radiação de onda longa desc.| W m-2      | rlds           |
!! | Faxa_rain | precipitação líquida        | kg m-2 s-1 | prra           |
!! | Faxa_snow | precipitação sólida         | kg m-2 s-1 | prsn           |
!!
!! A época dos arquivos JRA55 é 2016-01-01 01:30:00 (ver a nota antes de
!! ReadJRAFieldInterp). O DATM não depende de MOM_io.

module DATM_cap_mod
  use ESMF
  use ESMF, only: ESMF_GridComp, ESMF_GridCompGet, ESMF_GridCompSetEntryPoint
  use ESMF, only: ESMF_GridCompGetInternalState, ESMF_GridCompSetInternalState
  use ESMF, only: ESMF_State, ESMF_StateGet
  use ESMF, only: ESMF_Field, ESMF_FieldCreate, ESMF_FieldGet
  use ESMF, only: ESMF_Grid, ESMF_GridCreate1PeriDim, ESMF_GridAddCoord, ESMF_GridGetCoord
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

  use netcdf

  use coupler_log_mod, only: COMP_DATM, log_error, log_info, log_warning, log_debug
  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Realize
  use NUOPC, only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet
  use NUOPC_Model, &
    model_routine_SS           => SetServices,         &
    model_label_DataInitialize => label_DataInitialize, &
    model_label_Advance        => label_Advance
  use NUOPC_Model, only: NUOPC_ModelGet
  ! Sem dependência de MOM_io: o DATM não usa stdout nem io_infra_end e não
  ! precisa ser acoplado ao MOM6.
  use coupler_utils_mod, only : ChkErr
  use cap_common_mod, only : cap_initialize_p0, cap_realize_fields, cap_put_field, &
                             cap_fill_export_initial, cap_set_data_complete, &
                             cap_stamp_export, cap_advertise, ADVERTISE_DEFAULT
  use cpl_fields_mod, only : CPL_NAME_LEN
  use cpl_map_mod,    only : cpl_exports
  use coupler_config_mod, only : cpl_current_config

  implicit none
  private

  ! Os campos exportados saem do mapa de acoplamento (src/coupling/
  ! cpl_map.F90), no ponto ATM@datm: os 9 campos de EXPORTS
  ! (cpl_exports), na ordem do anúncio. O DATM não importa nada.
  character(len=*), parameter :: POINT_DATM = 'ATM@datm'

  ! Início da mensagem de erro de cap_put_field quando o campo não existe.
  character(len=*), parameter :: PUT_TAG = "PutField: "

  public :: SetServices

  ! Estado interno do DATM
  type :: DATM_InternalState
    type(ESMF_Grid) :: grid
    ! Campos JRA55 lidos do NetCDF
    real(ESMF_KIND_R8), pointer :: uas(:,:)  => null()  ! vento zonal 10m
    real(ESMF_KIND_R8), pointer :: vas(:,:)  => null()  ! vento merid. 10m
    real(ESMF_KIND_R8), pointer :: tas(:,:)  => null()  ! temperatura ar 2m
    real(ESMF_KIND_R8), pointer :: huss(:,:) => null()  ! umidade específica
    real(ESMF_KIND_R8), pointer :: psl(:,:)  => null()  ! pressão niv. mar
    real(ESMF_KIND_R8), pointer :: rsds(:,:) => null()  ! rad. sol. desc.
    real(ESMF_KIND_R8), pointer :: rlds(:,:) => null()  ! rad. LW desc.
    real(ESMF_KIND_R8), pointer :: prra(:,:) => null()  ! precip. líquida
    real(ESMF_KIND_R8), pointer :: prsn(:,:) => null()  ! precip. sólida
    logical :: initialized = .false.
  end type DATM_InternalState

  type :: DATM_InternalStateWrapper
    type(DATM_InternalState), pointer :: wrap => null()
  end type DATM_InternalStateWrapper

contains

  !> @brief Registra as fases de inicialização e a especialização do avanço.
  !! @param[inout] gcomp  componente DATM
  !! @param[out]   rc     código de retorno
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

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

  end subroutine SetServices

  !> @brief Anuncia os campos brutos do JRA55 exportados ao mediador.
  !!
  !! O DATM não anuncia fluxos (Foxx_*): exporta somente o que vem
  !! diretamente do JRA55.
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS

    ! Campos de estado atmosférico bruto (JRA55): vento a 10 m, temperatura,
    ! umidade e pressão; radiação descendente (sem decomposição em bandas, o
    ! MED faz isso) e precipitação.
    call cpl_exports(POINT_DATM, cpl_current_config(), '', names)
    call cap_advertise(exportState, names, ADVERTISE_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DATM, 'InitializeAdvertise concluido (campos brutos JRA55)')
  end subroutine InitializeAdvertise

  !> @brief Cria a grade 640x320 do JRA55 e realiza os campos exportados.
  !!
  !! Centros das células: coordX = (i-1)*dx + dx/2 e coordY = (j-1)*dy + dy/2,
  !! com i e j índices globais (INDEX_GLOBAL).
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    type(ESMF_Grid)   :: grid
    integer           :: nx_global, ny_global, i, j
    real(ESMF_KIND_R8)              :: dx, dy
    real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)
    type(DATM_InternalStateWrapper) :: iswrap
    type(DATM_InternalState), pointer :: is
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS

    nx_global = 640
    ny_global = 320
    dx = 360.0_ESMF_KIND_R8 / nx_global   ! 0.5625 graus
    dy = 180.0_ESMF_KIND_R8 / ny_global   ! 0.5625 graus

    grid = ESMF_GridCreate1PeriDim( &
      minIndex  = (/1, 1/),                 &
      maxIndex  = (/nx_global, ny_global/), &
      indexflag = ESMF_INDEX_GLOBAL,        &
      coordSys  = ESMF_COORDSYS_SPH_DEG,   &
      rc        = rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridAddCoord(grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Longitude: com ESMF_INDEX_GLOBAL, i é o índice global da coluna
    ! (1..640; lbound(coordX,1) é 1 no PET 0 e, por exemplo, 161 no PET 1), e
    ! lon_centro_i = (i-1)*dx + dx/2, de 0.28125 a 359.71875.
    call ESMF_GridGetCoord(grid, coordDim=1, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    do j = lbound(coordX,2), ubound(coordX,2)
      do i = lbound(coordX,1), ubound(coordX,1)
        coordX(i,j) = (i - 1) * (360.0_ESMF_KIND_R8/nx_global) &
          + (360.0_ESMF_KIND_R8/nx_global) * 0.5_ESMF_KIND_R8
      end do
    end do
    ! Latitude: lat_centro_j = -90 + (j-1)*dy + dy/2
    call ESMF_GridGetCoord(grid, coordDim=2, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    do j = lbound(coordY,2), ubound(coordY,2)
      do i = lbound(coordY,1), ubound(coordY,1)
        coordY(i,j) = -90.0_ESMF_KIND_R8 + (j-1)*(180.0_ESMF_KIND_R8/ny_global) &
          + (180.0_ESMF_KIND_R8/ny_global)/2.0_ESMF_KIND_R8
      end do
    end do

    ! Realiza campos brutos
    call cpl_exports(POINT_DATM, cpl_current_config(), '', names)
    call cap_realize_fields(exportState, grid, names, size(names), rc)
    if (rc/=ESMF_SUCCESS) return

    allocate(iswrap%wrap)
    is => iswrap%wrap
    is%grid        = grid
    is%initialized = .false.

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DATM, 'InitializeRealize concluido')
  end subroutine InitializeRealize

  !> @brief Fase IPDv03p7: valores de partida do exportState (componente de dados).
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)  :: exportState

    rc = ESMF_SUCCESS

    call ESMF_GridCompGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Valores de partida, substituídos pelos campos do JRA55 no primeiro
    ! ModelAdvance: pressão padrão e Sa_tbot de 290 K (ativo APENAS quando
    ! atm_model=datm); os demais campos começam em zero.
    call cap_fill_export_initial(exportState, [character(len=7) :: 'Sa_pslv', 'Sa_tbot'], &
      [101325.0_ESMF_KIND_R8, 290.0_ESMF_KIND_R8], rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cap_set_data_complete(gcomp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DATM, 'InitializeDataComplete SATISFIED')
  end subroutine InitializeDataComplete

  !> @brief Lê o JRA55 no instante corrente e preenche o exportState.
  !!
  !! Não calcula fluxos: copia as variáveis do JRA55 para os campos da
  !! tabela do cabeçalho do arquivo.
  !! @param[inout] gcomp  componente DATM
  !! @param[out]   rc     código de retorno
  subroutine ModelAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)         :: exportState
    type(ESMF_Clock)         :: clock
    type(ESMF_Time)          :: currTime, nextTime
    type(ESMF_TimeInterval)  :: dt
    type(ESMF_Field)         :: field
    type(DATM_InternalStateWrapper) :: iswrap
    type(DATM_InternalState), pointer :: is
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: i1, i2, j1, j2
    integer :: year, month, day, hour, minute, sec
    character(len=256) :: msg

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap

    call NUOPC_ModelGet(gcomp, modelClock=clock, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_ClockGet(clock, currTime=currTime, timeStep=dt, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    nextTime = currTime + dt

    call ESMF_TimeGet(currTime, yy=year, mm=month, dd=day, &
      h=hour, m=minute, s=sec, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    write(msg,'(A,I4,5(A,I2.2))') 'avancando para ', year, '-', &
      month, '-', day, ' ', hour, ':', minute, ':', sec
    call log_info(COMP_DATM, trim(msg))

    ! Obtém limites locais a partir do primeiro campo
    call ESMF_StateGet(exportState, itemName="Sa_u10m", field=field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    i1 = lbound(fptr,1); i2 = ubound(fptr,1)
    j1 = lbound(fptr,2); j2 = ubound(fptr,2)

    ! Aloca arrays temporários se necessário
    if (.not. associated(is%uas)) then
      allocate(is%uas(i1:i2,  j1:j2))
      allocate(is%vas(i1:i2,  j1:j2))
      allocate(is%tas(i1:i2,  j1:j2))
      allocate(is%huss(i1:i2, j1:j2))
      allocate(is%psl(i1:i2,  j1:j2))
      allocate(is%rsds(i1:i2, j1:j2))
      allocate(is%rlds(i1:i2, j1:j2))
      allocate(is%prra(i1:i2, j1:j2))
      allocate(is%prsn(i1:i2, j1:j2))
    end if

    ! Lê os campos do JRA55 com interpolação temporal linear (3h -> dt_driver)
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_uas.nc",  "uas",  currTime, is%uas,  rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha uas",  line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_vas.nc",  "vas",  currTime, is%vas,  rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha vas",  line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_tas.nc",  "tas",  currTime, is%tas,  rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha tas",  line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_huss.nc", "huss", currTime, is%huss, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha huss", line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_psl.nc",  "psl",  currTime, is%psl,  rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha psl",  line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_rsds.nc", "rsds", currTime, is%rsds, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha rsds", line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_rlds.nc", "rlds", currTime, is%rlds, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha rlds", line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_prra.nc", "prra", currTime, is%prra, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha prra", line=__LINE__, file=__FILE__)) return
    call ReadJRAFieldInterp(gcomp, "INPUT/JRA_prsn.nc", "prsn", currTime, is%prsn, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="Falha prsn", line=__LINE__, file=__FILE__)) return

    ! Escreve campos lidos no exportState
    call cap_put_field(exportState, "Sa_u10m",   is%uas,  PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Sa_v10m",   is%vas,  PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Sa_tbot",   is%tas,  PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Sa_shum",   is%huss, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Sa_pslv",   is%psl,  PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Faxa_swdn", is%rsds, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Faxa_lwdn", is%rlds, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Faxa_rain", is%prra, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return
    call cap_put_field(exportState, "Faxa_snow", is%prsn, PUT_TAG, rc); if (rc/=ESMF_SUCCESS) return

    ! Atualizar timestamps
    call cap_stamp_export(exportState, nextTime, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DATM, 'ModelAdvance concluido (campos brutos)')
  end subroutine ModelAdvance

  !> @brief Campo do JRA55 no instante currTime, por interpolação linear entre registros de 3 h.
  !!
  !! O PET 0 lê o campo global inteiro do NetCDF e o difunde com
  !! ESMF_VMBroadcast; cada PET copia só o seu subdomínio. Os arquivos do
  !! JRA55 não são particionados, e a leitura paralela exigiria PIO ou
  !! NetCDF-4 paralelo; para 640x320 pontos, 2 registros de 8 bytes (cerca
  !! de 3 MB por variável), a difusão custa pouco.
  !!
  !! Época do arquivo: epochTime marca o primeiro registro do JRA55. O
  !! código usa 2016-01-01 01:30:00, o centro do primeiro intervalo; se o
  !! arquivo começar em 00:00, a época deve ser 00:00, senão
  !! sec_since_epoch fica < 0 no instante inicial do experimento
  !! (2016-01-01 00:00:00).
  !! @param[in]    gcomp     componente DATM (fornece a VM)
  !! @param[in]    filename  arquivo NetCDF do JRA55
  !! @param[in]    varname   variável a ler
  !! @param[in]    currTime  instante corrente
  !! @param[inout] array     subdomínio local do campo, com índices globais
  !! @param[out]   rc        código de retorno
  subroutine ReadJRAFieldInterp(gcomp, filename, varname, currTime, array, rc)
    type(ESMF_GridComp),  intent(in)    :: gcomp
    character(len=*),    intent(in)  :: filename
    character(len=*),    intent(in)  :: varname
    type(ESMF_Time),     intent(in)  :: currTime
    real(ESMF_KIND_R8),  pointer     :: array(:,:)
    integer,             intent(out) :: rc

    type(ESMF_VM)           :: vm
    type(ESMF_Time)         :: epochTime
    type(ESMF_TimeInterval) :: dt_since_epoch, interval3h
    integer(ESMF_KIND_I8)   :: sec_since_epoch
    integer                 :: tidx0, tidx1
    real(ESMF_KIND_R8)      :: alpha

    ! Arrays globais (usados apenas no PET 0 para leitura, depois difundidos).
    ! A interpolação temporal é feita em f0_global antes do broadcast.
    integer, parameter :: NX = 640, NY = 320
    real(ESMF_KIND_R8), target    :: f0_global(NX,NY), f1_global(NX,NY)
    real(ESMF_KIND_R8), allocatable :: buf_global(:)

    ! Limites locais do subdomínio deste PET
    integer :: i1, i2, j1, j2, i, j, localPet
    integer :: ni, nj!local
    character(len=256) :: msg

    rc = ESMF_SUCCESS
    ni = size(array, 1)
    nj = size(array, 2)
    allocate(buf_global(NX*NY))
    ! VM do componente, não a global (ver ocn_data_reader.F90): evita
    ! broadcast coletivo sobre todos os PETs quando o DATM roda só no
    ! subconjunto da atmosfera (teste DATM concorrente).
    call ESMF_GridCompGet(gcomp, vm=vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    f0_global = 0.0_ESMF_KIND_R8
    f1_global = 0.0_ESMF_KIND_R8
    ! Calcula índices de interpolação temporal
    ! epochTime = 2016-01-01 01:30:00 (centro do primeiro intervalo JRA55).
    ! Para currTime anterior a época, sec_since_epoch < 0 (ver o aviso abaixo);
    ! com arquivo iniciado em 00:00, a época correta é 00:00.
    call ESMF_TimeSet(epochTime, yy=2016, mm=1, dd=1, h=1, m=30, s=0, &
      calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_TimeIntervalSet(interval3h, s=10800, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    dt_since_epoch = currTime - epochTime

    call ESMF_TimeIntervalGet(dt_since_epoch, s_i8=sec_since_epoch, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Garantir sec_since_epoch >= 0 (currTime não pode ser anterior ao epoch)
    if (sec_since_epoch < 0_ESMF_KIND_I8) then
      call log_warning(COMP_DATM, 'ReadJRAFieldInterp: currTime anterior ao epochTime')
      rc = ESMF_FAILURE
      ! Sem return: a execução segue, e o rc é refeito pelas chamadas abaixo.
    end if

    ! tidx0 é base-1 (primeiro snapshot = índice 1)
    tidx0 = int(sec_since_epoch / 10800.0_ESMF_KIND_R8) + 1
    tidx1 = tidx0 + 1
    alpha = real(mod(sec_since_epoch, 10800_ESMF_KIND_I8), ESMF_KIND_R8) / &
            10800.0_ESMF_KIND_R8
    alpha = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, alpha))

    ! Leitura: apenas o PET 0 acessa o disco
    if (localPet == 0) then
      call ReadGlobalField(filename, varname, tidx0, NX, NY, f0_global, rc)
      if (rc /= ESMF_SUCCESS) return
      call ReadGlobalField(filename, varname, tidx1, NX, NY, f1_global, rc)
      if (rc /= ESMF_SUCCESS) return

      ! Interpolação temporal in-place
      f0_global = f0_global + alpha * (f1_global - f0_global)
      buf_global = reshape(f0_global, [NX*NY])
    end if

    ! Broadcast: PET0 envia campo global para todos os PETs
    ! ESMF_VMBroadcast usa contagem de elementos (NX*NY doubles)
    call ESMF_VMBroadcast(vm, bcstData=buf_global, count=NX*NY, rootPet=0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Cada PET copia apenas o seu subdomínio local
    ! array tem índices globais (ESMF_INDEX_GLOBAL): lbound/ubound dão i1,i2,j1,j2 globais
    ! Layout Fortran: i varia mais rápido.
    i1 = lbound(array,1); i2 = ubound(array,1)
    j1 = lbound(array,2); j2 = ubound(array,2)

    do j = j1, j2
      do i = i1, i2
        array(i,j) = buf_global((j-1)*NX + i)
      end do
    end do

    deallocate(buf_global)

    write(msg,'(A,A,A,I5,A,I5,A,F6.4)') &
      'interp ', trim(varname), &
      ' tidx0=', tidx0, ' tidx1=', tidx1, ' alpha=', alpha
    call log_debug(COMP_DATM, trim(msg))
  end subroutine ReadJRAFieldInterp

  !> @brief Lê um registro do campo global (nx x ny) do NetCDF; chamada só no PET 0.
  !! @param[in]  filename  arquivo NetCDF
  !! @param[in]  varname   variável a ler
  !! @param[in]  tidx      registro de tempo (base 1)
  !! @param[in]  nx        pontos em longitude
  !! @param[in]  ny        pontos em latitude
  !! @param[out] array     campo lido
  !! @param[out] rc        código de retorno
  subroutine ReadGlobalField(filename, varname, tidx, nx, ny, array, rc)
    character(len=*),    intent(in)  :: filename
    character(len=*),    intent(in)  :: varname
    integer,             intent(in)  :: tidx
    integer,             intent(in)  :: nx, ny
    real(ESMF_KIND_R8),  intent(out) :: array(nx,ny)
    integer,             intent(out) :: rc

    integer :: ncid, varid, start(3), count(3), nc_rc

    rc     = ESMF_SUCCESS
    nc_rc  = nf90_open(filename, NF90_NOWRITE, ncid)
    if (nc_rc /= NF90_NOERR) then
      call log_error(COMP_DATM, "ReadGlobalField: falha ao abrir "//trim(filename)// &
        ": "//trim(nf90_strerror(nc_rc)))
      rc = ESMF_FAILURE; return
    end if

    nc_rc = nf90_inq_varid(ncid, varname, varid)
    if (nc_rc /= NF90_NOERR) then
      call log_error(COMP_DATM, "ReadGlobalField: variavel nao encontrada: "// &
        trim(varname))
      rc = ESMF_FAILURE; nc_rc = nf90_close(ncid); return
    end if

    ! Lê o campo global inteiro: [1:nx, 1:ny, tidx]
    start = [1, 1, tidx]; count = [nx, ny, 1]
    nc_rc = nf90_get_var(ncid, varid, array, start=start, count=count)
    if (nc_rc /= NF90_NOERR) then
      call log_error(COMP_DATM, "ReadGlobalField: falha ao ler "//trim(varname)// &
        ": "//trim(nf90_strerror(nc_rc)))
      rc = ESMF_FAILURE; nc_rc = nf90_close(ncid); return
    end if

    nc_rc = nf90_close(ncid)

  end subroutine ReadGlobalField

end module DATM_cap_mod
