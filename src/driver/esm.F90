!> @file esm.F90
!! @brief Driver NUOPC do sistema acoplado MONAN-A 2.0 x MOM6 + SIS2.
!!
!! O driver registra os componentes e os conectores e define a ordem de
!! execução de cada passo de acoplamento (RunSequence). Tudo o que ele faz é
!! decidido pela configuração lida de nuopc.input (coupler_config_mod).
!!
!! Componentes:
!!   MPAS  atmosfera MONAN-A 2.0 (MPAS-A 8.3.1)
!!   MED   mediador: fluxos ar-mar por fórmulas bulk NCAR
!!   OCN   oceano: MOM6 dinâmico, ou DOCN (SST lida de arquivo OISST)
!!   ICE   gelo marinho SIS2 (opcional, use_sis2_dynamic)
!!
!! Dois eixos independentes definem a execução:
!!   pet_layout    (espaço)  shared: todos em todos os PETs;
!!                           split: blocos disjuntos ATM | OCN | ICE, MED em todos.
!!   coupling_mode (tempo)   sequential: um componente depois do outro;
!!                           concurrent: ATM, OCN e ICE avançam ao mesmo tempo,
!!                           com defasagem de um passo nos dados trocados.
!!
!! Sincronização: uma linha de modelo na RunSequence não sincroniza PETs. Os
!! conectores de e para o MED rodam na união dos PETs de origem e destino e,
!! como o MED está em todos os PETs, cada um deles é um ponto de encontro de
!! todos os PETs. Ver docs/analise-sequential-split-sis2.md.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module ESM_MONAN

  use ESMF
  use NUOPC,             only : NUOPC_FreeFormat, NUOPC_FreeFormatCreate,   &
                                NUOPC_FreeFormatDestroy, NUOPC_CompDerive,  &
                                NUOPC_CompSpecialize, NUOPC_CompAttributeSet, &
                                NUOPC_CompAttributeGet,                     &
                                NUOPC_FieldDictionarySetAutoAdd
  use NUOPC_Driver,      driver_routine_SS             => SetServices,            &
                         driver_label_SetModelServices => label_SetModelServices, &
                         driver_label_SetRunSequence   => label_SetRunSequence,   &
                         driver_label_ModifyCplLists   => label_ModifyCplLists
  use NUOPC_Connector,   only : CPL_SetServices  => SetServices
  use mpas_cap_MONAN_mod, only : MPAS_SetServices => SetServices
  use MED_cap_MONAN_mod,  only : MED_SetServices  => SetServices
  use MOM_cap_MONAN_mod,  only : OCN_SetServices  => SetServices
  use DOCN_cap_mod,       only : DOCN_SetServices => SetServices
  use sis_cap_MONAN_mod,  only : ICE_SetServices  => SetServices
  use coupler_config_mod, only : cfg_use_docn, cfg_use_med_to_mpas,     &
                                 cfg_use_sis2_dynamic, cfg_seq_repro,   &
                                 cfg_coupling_mode, cfg_pet_layout,     &
                                 cfg_atm_pet_count, cfg_ocn_pet_count,  &
                                 cfg_ice_pet_count
  use coupler_utils_mod,  only : ChkErr, int_to_str
  use cpl_check_mod,      only : cpl_check_acoplamento

  implicit none
  private
  public :: SetServices

  character(len=*), parameter :: MPAS_LABEL = 'MPAS'
  character(len=*), parameter :: MED_LABEL  = 'MED'
  character(len=*), parameter :: OCN_LABEL  = 'OCN'
  character(len=*), parameter :: ICE_LABEL  = 'ICE'

contains

  !> Registra o driver NUOPC e as três especializações usadas.
  subroutine SetServices(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    call NUOPC_CompDerive(driver, driver_routine_SS, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSpecialize(driver, specLabel=driver_label_SetModelServices, &
      specRoutine=SetModelServices, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSpecialize(driver, specLabel=driver_label_ModifyCplLists, &
      specRoutine=ModifyCplLists, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSpecialize(driver, specLabel=driver_label_SetRunSequence, &
      specRoutine=SetRunSequence, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine SetServices

  !> Registra componentes e conectores.
  subroutine SetModelServices(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    type(ESMF_GridComp)  :: mpasComp, medComp, ocnComp, iceComp
    type(ESMF_Clock)     :: driverClock
    integer              :: petCount, i, nAtm, nOcn, nIce
    integer, allocatable :: allPets(:), atmPets(:), ocnPets(:), icePets(:)
    logical              :: use_ice

    rc = ESMF_SUCCESS
    use_ice = cfg_use_sis2_dynamic

    ! Nomes de campo próprios do acoplador (_mpas, Foxx_* etc.)
    call NUOPC_FieldDictionarySetAutoAdd(.true., rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridCompGet(driver, petCount=petCount, clock=driverClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! ---- Divisão de PETs entre componentes --------------------------------
    allPets = [(i - 1, i = 1, petCount)]
    if (trim(cfg_pet_layout) == 'split') then
      call split_pets(petCount, use_ice, nAtm, nOcn, nIce, rc)
      if (rc /= ESMF_SUCCESS) return
      atmPets = allPets(1:nAtm)
      ocnPets = allPets(nAtm+1:nAtm+nOcn)
      icePets = allPets(nAtm+nOcn+1:petCount)
    else
      nAtm = petCount; nOcn = petCount; nIce = merge(petCount, 0, use_ice)
      atmPets = allPets; ocnPets = allPets; icePets = allPets(1:nIce)
    end if
    call log_layout(petCount, nAtm, nOcn, nIce, use_ice)

    ! ---- Componentes --------------------------------------------------------
    call add_model(driver, MPAS_LABEL, MPAS_SetServices, atmPets, driverClock, mpasComp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call add_model(driver, MED_LABEL, MED_SetServices, allPets, driverClock, medComp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (cfg_use_docn) then
      call add_model(driver, OCN_LABEL, DOCN_SetServices, ocnPets, driverClock, ocnComp, rc)
      call ESMF_LogWrite('ESM: OCN = DOCN OISST (use_docn=T)', ESMF_LOGMSG_INFO)
    else
      call add_model(driver, OCN_LABEL, OCN_SetServices, ocnPets, driverClock, ocnComp, rc)
      call ESMF_LogWrite('ESM: OCN = MOM6+SIS2 dinamico (use_docn=F)', ESMF_LOGMSG_INFO)
    end if
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! O FMS tem relógio próprio; pequenas diferenças de carimbo de tempo são
    ! esperadas e não devem abortar a rodada.
    call NUOPC_CompAttributeSet(ocnComp, name='timeStampValidation', value='false', rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (use_ice) then
      call add_model(driver, ICE_LABEL, ICE_SetServices, icePets, driverClock, iceComp, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_CompAttributeSet(iceComp, name='timeStampValidation', value='false', rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call ESMF_LogWrite('ESM: componente ICE (SIS2) registrado', ESMF_LOGMSG_INFO)
    end if

    ! ---- Conectores ---------------------------------------------------------
    call add_connector(driver, MPAS_LABEL, MED_LABEL, driverClock, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call add_connector(driver, OCN_LABEL, MED_LABEL, driverClock, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call add_connector(driver, MED_LABEL, OCN_LABEL, driverClock, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Condição de contorno oceânica da atmosfera: pelo mediador (MOM6) ou
    ! direto do oceano de dados (DOCN).
    if (cfg_use_med_to_mpas) then
      call add_connector(driver, MED_LABEL, MPAS_LABEL, driverClock, rc)
    else
      call add_connector(driver, OCN_LABEL, MPAS_LABEL, driverClock, rc)
    end if
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (use_ice) then
      call add_connector(driver, MED_LABEL, ICE_LABEL, driverClock, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call add_connector(driver, ICE_LABEL, MED_LABEL, driverClock, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if

    call ESMF_LogWrite('ESM: componentes e conectores registrados', ESMF_LOGMSG_INFO)
  end subroutine SetModelServices

  !> Calcula o tamanho dos blocos ATM | OCN | ICE no layout split.
  !! Contagem zero em nuopc.input significa "automático": o que sobra é
  !! dividido em partes aproximadamente iguais.
  subroutine split_pets(petCount, use_ice, nAtm, nOcn, nIce, rc)
    integer, intent(in)  :: petCount
    logical, intent(in)  :: use_ice
    integer, intent(out) :: nAtm, nOcn, nIce, rc

    rc   = ESMF_SUCCESS
    nAtm = cfg_atm_pet_count
    nOcn = cfg_ocn_pet_count
    nIce = merge(cfg_ice_pet_count, 0, use_ice)

    if (use_ice .and. nIce <= 0) then
      if (nAtm <= 0 .and. nOcn <= 0) then
        nAtm = petCount / 3
        nOcn = petCount / 3
      else if (nAtm <= 0) then
        nAtm = (petCount - nOcn) / 2
      else if (nOcn <= 0) then
        nOcn = (petCount - nAtm) / 2
      end if
      nIce = petCount - nAtm - nOcn
    else if (nAtm <= 0 .and. nOcn <= 0) then
      nAtm = (petCount - nIce + 1) / 2
      nOcn = petCount - nAtm - nIce
    else if (nAtm <= 0) then
      nAtm = petCount - nOcn - nIce
    else if (nOcn <= 0) then
      nOcn = petCount - nAtm - nIce
    end if

    if (nAtm < 1 .or. nOcn < 1 .or. (use_ice .and. nIce < 1) .or. &
        nAtm + nOcn + nIce /= petCount) then
      call ESMF_LogWrite('ESM: ERRO particao split invalida: nAtm='//int_to_str(nAtm)// &
        ' nOcn='//int_to_str(nOcn)//' nIce='//int_to_str(nIce)// &
        ' devem somar petCount='//int_to_str(petCount)//'.', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if
  end subroutine split_pets

  !> Registra no log a divisão de PETs. O formato destas linhas é lido pelas
  !! ferramentas de tools/coupler e tools/dev: não alterar sem ajustá-las.
  subroutine log_layout(petCount, nAtm, nOcn, nIce, use_ice)
    integer, intent(in) :: petCount, nAtm, nOcn, nIce
    logical, intent(in) :: use_ice

    character(len=:), allocatable :: exec, msg

    exec = merge('CONCURRENT', 'SEQUENTIAL', trim(cfg_coupling_mode) == 'concurrent')

    if (trim(cfg_pet_layout) /= 'split') then
      if (use_ice) then
        msg = 'MPAS, MED, OCN e ICE em todos os PETs'
      else
        msg = 'MPAS, MED e OCN em todos os PETs'
      end if
      call ESMF_LogWrite('ESM: layout SHARED (execucao '//exec//'): '//msg, ESMF_LOGMSG_INFO)
      return
    end if

    msg = 'ESM: layout SPLIT (execucao '//exec//'): ATM=PET[0..'//int_to_str(nAtm-1)// &
          '] OCN=PET['//int_to_str(nAtm)//'..'//int_to_str(nAtm+nOcn-1)//']'
    if (use_ice) then
      msg = msg//' ICE=PET['//int_to_str(nAtm+nOcn)//'..'//int_to_str(petCount-1)// &
            '] MED=todos'
    else
      msg = msg//' MED=todos (ICE desativado)'
    end if
    call ESMF_LogWrite(msg, ESMF_LOGMSG_INFO)

    ! No sequential+split parte dos PETs fica parada em cada fase; registrar
    ! quantos ajuda a interpretar o consumo de fila (nós x tempo de parede).
    if (exec == 'SEQUENTIAL') then
      msg = 'ESM: sequential+split: PETs parados: '//int_to_str(petCount-nAtm)// &
            ' durante o ATM, '//int_to_str(petCount-nOcn)//' durante o OCN'
      if (use_ice) msg = msg//', '//int_to_str(petCount-nIce)//' durante o ICE'
      call ESMF_LogWrite(msg//' (de '//int_to_str(petCount)//').', ESMF_LOGMSG_INFO)
    end if
  end subroutine log_layout

  !> Registra um componente de modelo e lhe entrega uma CÓPIA do relógio do
  !! driver. Motivos: (1) com três ou mais componentes em PETs disjuntos o
  !! NUOPC não atribuía relógio a alguns deles ("Clock object is not present");
  !! (2) ESMF_Clock é referência, e o relógio compartilhado era avançado uma
  !! vez por componente a cada passo. Use esta rotina para qualquer componente novo.
  subroutine add_model(driver, label, setServices, petList, driverClock, comp, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    character(len=*),    intent(in)    :: label
    interface
      subroutine setServices(gcomp, rc)
        use ESMF, only : ESMF_GridComp
        type(ESMF_GridComp)  :: gcomp
        integer, intent(out) :: rc
      end subroutine setServices
    end interface
    integer,             intent(in)    :: petList(:)
    type(ESMF_Clock),    intent(in)    :: driverClock
    type(ESMF_GridComp), intent(out)   :: comp
    integer,             intent(out)   :: rc

    type(ESMF_Clock) :: compClock

    call NUOPC_DriverAddComp(driver, compLabel=label, compSetServicesRoutine=setServices, &
      petList=petList, comp=comp, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    compClock = ESMF_ClockCreate(driverClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_GridCompSet(comp, clock=compClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompAttributeSet(comp, name='Verbosity', value='high', rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine add_model

  !> Registra um conector NUOPC padrão com cópia própria do relógio do driver
  !! (mesmos motivos de add_model).
  subroutine add_connector(driver, srcLabel, dstLabel, driverClock, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    character(len=*),    intent(in)    :: srcLabel, dstLabel
    type(ESMF_Clock),    intent(in)    :: driverClock
    integer,             intent(out)   :: rc

    type(ESMF_CplComp) :: cplComp
    type(ESMF_Clock)   :: cplClock

    call NUOPC_DriverAddComp(driver, srcCompLabel=srcLabel, dstCompLabel=dstLabel, &
      compSetServicesRoutine=CPL_SetServices, comp=cplComp, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    cplClock = ESMF_ClockCreate(driverClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_CplCompSet(cplComp, clock=cplClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine add_connector

  !> Torna reprodutíveis, bit a bit, as somas feitas dentro dos conectores.
  !!
  !! Cada conector faz um produto matriz esparsa: o valor de destino é a soma
  !! de contribuições vindas de vários PETs. Por padrão o ESMF soma na ordem
  !! de chegada das mensagens (varia entre execuções) e escolhe por
  !! auto-ajuste onde fazer somas parciais. Como a soma em ponto flutuante
  !! não é associativa, o último bit muda. Duas opções fixam isso:
  !!   termorder=srcseq       soma na ordem do índice de origem
  !!   srcTermProcessing=0    toda a aritmética no destino
  !! Entradas que já tragam a opção não são alteradas.
  !!
  !! Depois, com as listas prontas, registra no log o relatório dos conectores
  !! e a conferência do mapa de acoplamento (cpl_check_acoplamento), que só
  !! escreve no log e não muda as listas.
  subroutine ModifyCplLists(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    character(len=*), parameter :: OPT_ORDER = ':termorder=srcseq'
    character(len=*), parameter :: OPT_SRC   = ':srcTermProcessing=0'
    character(len=512), allocatable :: cplList(:)
    type(ESMF_CplComp),     pointer :: connectors(:)
    integer :: i, j, n, n_order, n_src, n_full

    rc = ESMF_SUCCESS
    n_order = 0; n_src = 0; n_full = 0
    nullify(connectors)

    call NUOPC_DriverGetComp(driver, compList=connectors, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    do i = 1, size(connectors)
      call NUOPC_CompAttributeGet(connectors(i), name='CplList', itemCount=n, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      if (n == 0) cycle

      allocate(cplList(n))
      call NUOPC_CompAttributeGet(connectors(i), name='CplList', valueList=cplList, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      do j = 1, n
        call append_option(cplList(j), 'termorder=', OPT_ORDER, n_order)
        call append_option(cplList(j), 'srcTermProcessing=', OPT_SRC, n_src)
      end do
      call NUOPC_CompAttributeSet(connectors(i), name='CplList', valueList=cplList, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      deallocate(cplList)
    end do
    deallocate(connectors)

    call ESMF_LogWrite('ESM: reprodutibilidade dos conectores: termorder=srcseq em '// &
      int_to_str(n_order)//' entrada(s), srcTermProcessing=0 em '//int_to_str(n_src)// &
      ' entrada(s)', ESMF_LOGMSG_INFO)

    call cpl_check_acoplamento(driver,                                               &
      [character(len=4) :: MPAS_LABEL, MED_LABEL, OCN_LABEL, ICE_LABEL],             &
      [character(len=4) :: 'ATM', 'MED', 'OCN', 'ICE'], rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (n_full > 0) then
      call ESMF_LogWrite('ESM: '//int_to_str(n_full)//' entrada(s) de CplList sem espaco '// &
        'para as opcoes de reprodutibilidade; aumentar len de cplList', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

  contains

    subroutine append_option(entry, key, option, counter)
      character(len=*), intent(inout) :: entry
      character(len=*), intent(in)    :: key, option
      integer,          intent(inout) :: counter

      if (index(entry, key) > 0) return
      if (len_trim(entry) + len(option) > len(entry)) then
        n_full = n_full + 1
        return
      end if
      entry = trim(entry)//option
      counter = counter + 1
    end subroutine append_option

  end subroutine ModifyCplLists

  !> Define a sequência de execução de cada passo de acoplamento.
  !!
  !! Sete variantes, escolhidas pela configuração:
  !!   modo        oceano     gelo   seq_repro   variante
  !!   concurrent  MOM6       sim    -           conc_mom6_ice
  !!   concurrent  MOM6       não    -           conc_mom6
  !!   concurrent  DOCN       -      -           conc_docn
  !!   sequential  MOM6       sim    sim         seq_mom6_ice_repro
  !!   sequential  MOM6       sim    não         seq_mom6_ice
  !!   sequential  MOM6       não    -           seq_mom6
  !!   sequential  DOCN       -      -           seq_docn
  !! ("MOM6" aqui significa use_med_to_mpas=.true.)
  !!
  !! No modo concorrente MPAS, OCN e ICE aparecem em linhas consecutivas, sem
  !! conector entre eles, e por isso avançam ao mesmo tempo em PETs
  !! disjuntos; o mediador entrega no início do passo o que calculou no fim
  !! do passo anterior. Na variante seq_mom6_ice_repro a ordem imita esse
  !! fluxo de dados, mas executa um componente de cada vez; o resultado é
  !! comparável bit a bit ao concorrente. Na seq_mom6_ice a linha MED -> ICE
  !! entre OCN e ICE é intencional: ela impede que os dois avancem juntos.
  subroutine SetRunSequence(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    character(len=*), parameter :: M2A = 'MED -> MPAS', M2O = 'MED -> OCN', M2I = 'MED -> ICE'
    character(len=*), parameter :: A2M = 'MPAS -> MED', O2M = 'OCN -> MED', I2M = 'ICE -> MED'
    character(len=*), parameter :: O2A = 'OCN -> MPAS'
    integer, parameter :: LW = 24
    character(len=LW)   :: steps(10)      ! no máximo 10 linhas por passo
    character(len=LW+2) :: lines(12)
    integer :: n
    character(len=:),  allocatable :: title
    type(NUOPC_FreeFormat)  :: runSeqFF
    type(ESMF_Clock)        :: driverClock
    type(ESMF_TimeInterval) :: timeStep
    integer(ESMF_KIND_I8)   :: dt_s
    logical :: concurrent, mom6, ice
    integer :: i

    rc = ESMF_SUCCESS
    concurrent = (trim(cfg_coupling_mode) == 'concurrent')
    mom6       = cfg_use_med_to_mpas
    ice        = cfg_use_sis2_dynamic .and. mom6

    if (concurrent .and. ice) then
      title = 'Fase 2 CONCORRENTE + ICE (SIS2)'
      n = 10
      steps(1:n) = [character(len=LW) :: M2A, M2O, M2I, 'MPAS', 'OCN', 'ICE', A2M, O2M, I2M, 'MED']
    else if (concurrent .and. mom6) then
      title = 'Fase 2 CONCORRENTE (MED->MPAS)'
      n = 7
      steps(1:n) = [character(len=LW) :: M2A, M2O, 'MPAS', 'OCN', A2M, O2M, 'MED']
    else if (concurrent) then
      title = 'Fase 1 CONCORRENTE (OCN->MPAS)'
      n = 7
      steps(1:n) = [character(len=LW) :: O2A, M2O, 'MPAS', 'OCN', A2M, O2M, 'MED']
    else if (ice .and. cfg_seq_repro) then
      title = 'Fase 2 SEQUENCIAL REPRODUTIVEL + ICE (SIS2)'
      n = 10
      steps(1:n) = [character(len=LW) :: M2A, 'MPAS', M2O, 'OCN', M2I, 'ICE', A2M, O2M, I2M, 'MED']
    else if (ice) then
      title = 'Fase 2 SEQUENCIAL + ICE (SIS2)'
      n = 10
      steps(1:n) = [character(len=LW) :: O2M, I2M, A2M, 'MED', M2A, 'MPAS', M2O, 'OCN', M2I, 'ICE']
    else if (mom6) then
      title = 'Fase 2 (MED->MPAS)'
      n = 7
      steps(1:n) = [character(len=LW) :: O2M, A2M, 'MED', M2A, 'MPAS', M2O, 'OCN']
    else
      title = 'Fase 1 (OCN->MPAS direto)'
      n = 7
      steps(1:n) = [character(len=LW) :: O2A, 'MPAS', A2M, O2M, 'MED', M2O, 'OCN']
    end if

    ! O DOCN não tem estado oceânico ao qual o SIS2 possa se acoplar.
    if (cfg_use_sis2_dynamic .and. .not. mom6) call ESMF_LogWrite('ESM: AVISO: ' // &
      'use_sis2_dynamic=.true. com use_med_to_mpas=.false.: o ICE e registrado ' // &
      'mas nunca executado.', ESMF_LOGMSG_WARNING)

    ! Período do laço = passo do relógio do driver (dt_coupling)
    call ESMF_GridCompGet(driver, clock=driverClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_ClockGet(driverClock, timeStep=timeStep, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_TimeIntervalGet(timeStep, s_i8=dt_s, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! As linhas vão para uma variável antes da chamada: passado direto como
    ! argumento, um construtor [character(len=...) :: ...] tem o comprimento
    ! ignorado pelo gfortran (fica o do primeiro elemento, '@3600', e 'MPAS'
    ! vira 'MPA').
    lines(1) = '@'//int_to_str(int(dt_s))
    do i = 1, n
      lines(i+1) = '  '//steps(i)
    end do
    lines(n+2) = '@'
    runSeqFF = NUOPC_FreeFormatCreate(stringList=lines(1:n+2), rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_DriverIngestRunSequence(driver, runSeqFF, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_FreeFormatDestroy(runSeqFF, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_LogWrite('ESM: RunSequence '//title//' (dt='//int_to_str(int(dt_s))//' s)', &
      ESMF_LOGMSG_INFO)
  end subroutine SetRunSequence

end module ESM_MONAN
