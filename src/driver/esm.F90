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
                                NUOPC_CompAttributeGet
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
                                 cfg_ice_pet_count, cpl_current_config, &
                                 cfg_run_sequence_file
  use coupler_utils_mod,  only : ChkErr, int_to_str
  use coupler_log_mod,    only : COMP_DRV, log_error, log_info
  use cpl_check_mod,      only : cpl_check_coupling, cpl_write_methods, cpl_nuopc_dictionary
  use run_sequences_mod,  only : RUN_SEQUENCES, RUN_SEQUENCE_LINE_LEN, MAX_RUN_SEQUENCE_LINES, &
                                 RUN_SEQUENCE_LABEL, run_sequence_name, run_sequence_index,     &
                                 run_sequence_lines, run_sequence_from_file
  use cpl_map_mod,        only : cpl_driver_connectors, &
                                 CONNECTOR_SRC, CONNECTOR_DST, N_CONNECTORS, EXCHANGES

  implicit none
  private
  public :: SetServices

  character(len=*), parameter :: MPAS_LABEL = 'MPAS'
  character(len=*), parameter :: MED_LABEL  = 'MED'
  character(len=*), parameter :: OCN_LABEL  = 'OCN'
  character(len=*), parameter :: ICE_LABEL  = 'ICE'

contains

  !> @brief Registra o driver NUOPC e as três especializações usadas.
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

  !> @brief Registra componentes e conectores.
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

    ! Nomes de campo do acoplador (_mpas, Foxx_* etc.): os de FIELDS, no
    ! dicionário do NUOPC, sem acréscimo automático
    call cpl_nuopc_dictionary(rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridCompGet(driver, petCount=petCount, clock=driverClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Divisão de PETs entre componentes
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

    ! Componentes
    call add_model(driver, MPAS_LABEL, MPAS_SetServices, atmPets, driverClock, mpasComp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call add_model(driver, MED_LABEL, MED_SetServices, allPets, driverClock, medComp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (cfg_use_docn) then
      call add_model(driver, OCN_LABEL, DOCN_SetServices, ocnPets, driverClock, ocnComp, rc)
      call log_info(COMP_DRV, 'OCN = DOCN OISST (use_docn=T)')
    else
      call add_model(driver, OCN_LABEL, OCN_SetServices, ocnPets, driverClock, ocnComp, rc)
      call log_info(COMP_DRV, 'OCN = MOM6+SIS2 dinamico (use_docn=F)')
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
      call log_info(COMP_DRV, 'componente ICE (SIS2) registrado')
    end if

    ! Conectores
    ! Escolhidos pelo mapa de acoplamento (EXCHANGES, coluna when), na ordem
    ! de CONNECTOR_SRC/CONNECTOR_DST.
    call add_connectors(driver, driverClock, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DRV, 'componentes e conectores registrados')
  end subroutine SetModelServices

  !> @brief Calcula o tamanho dos blocos ATM | OCN | ICE no layout split.
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
      if (on_root()) call log_error(COMP_DRV, 'particao split invalida: nAtm='//int_to_str(nAtm)// &
        ' nOcn='//int_to_str(nOcn)//' nIce='//int_to_str(nIce)// &
        ' devem somar petCount='//int_to_str(petCount)//'.')
      rc = ESMF_FAILURE
    end if
  end subroutine split_pets

  !> @brief Registra no log a divisão de PETs. O formato destas linhas é lido pelas
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
      call log_info(COMP_DRV, 'layout SHARED (execucao '//exec//'): '//msg)
      return
    end if

    msg = 'layout SPLIT (execucao '//exec//'): ATM=PET[0..'//int_to_str(nAtm-1)// &
          '] OCN=PET['//int_to_str(nAtm)//'..'//int_to_str(nAtm+nOcn-1)//']'
    if (use_ice) then
      msg = msg//' ICE=PET['//int_to_str(nAtm+nOcn)//'..'//int_to_str(petCount-1)// &
            '] MED=todos'
    else
      msg = msg//' MED=todos (ICE desativado)'
    end if
    call log_info(COMP_DRV, msg)

    ! No sequential+split parte dos PETs fica parada em cada fase; registrar
    ! quantos ajuda a interpretar o consumo de fila (nós x tempo de parede).
    if (exec == 'SEQUENTIAL') then
      msg = 'sequential+split: PETs parados: '//int_to_str(petCount-nAtm)// &
            ' durante o ATM, '//int_to_str(petCount-nOcn)//' durante o OCN'
      if (use_ice) msg = msg//', '//int_to_str(petCount-nIce)//' durante o ICE'
      call log_info(COMP_DRV, msg//' (de '//int_to_str(petCount)//').')
    end if
  end subroutine log_layout

  !> @brief Registra um componente de modelo e lhe entrega uma CÓPIA do relógio do
  !! driver. Motivos: (1) com três ou mais componentes em PETs disjuntos, o
  !! NUOPC deixa de atribuir relógio a alguns deles ("Clock object is not
  !! present"); (2) ESMF_Clock é referência, e um relógio compartilhado seria
  !! avançado uma vez por componente a cada passo. Use esta rotina para
  !! qualquer componente novo.
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

  !> @brief Registra os conectores que o mapa de acoplamento tem na configuração
  !! atual, na ordem de CONNECTOR_SRC/CONNECTOR_DST (cpl_driver_connectors,
  !! em cpl_map). Um conector do mapa que não está na lista é erro.
  !!
  !! @param[inout] driver       o driver
  !! @param[in]    driverClock  relógio do driver (copiado para cada conector)
  !! @param[out]   rc           ESMF_SUCCESS ou o código do erro
  subroutine add_connectors(driver, driverClock, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    type(ESMF_Clock),    intent(in)    :: driverClock
    integer,             intent(out)   :: rc
    integer :: order(N_CONNECTORS), n, k, t

    rc = ESMF_SUCCESS
    call cpl_driver_connectors(cpl_current_config(), order, n, t)
    if (t > 0) then
      call ESMF_LogSetError(ESMF_RC_NOT_IMPL, &
        msg='ESM: conector do mapa sem registro no driver: '//trim(EXCHANGES(t)%src)// &
            ' -> '//trim(EXCHANGES(t)%dst), &
        line=__LINE__, file=__FILE__, rcToReturn=rc)
      return
    end if

    do k = 1, n
      call add_connector(driver, trim(comp_label(CONNECTOR_SRC(order(k)))), &
                         trim(comp_label(CONNECTOR_DST(order(k)))), driverClock, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

  contains

    !> Rótulo do componente no driver ('MPAS' para o ATM do mapa).
    function comp_label(comp) result(label)
      character(len=*), intent(in) :: comp
      character(len=4) :: label
      label = comp
      if (comp == 'ATM') label = MPAS_LABEL
    end function comp_label

  end subroutine add_connectors

  !> @brief Registra um conector NUOPC padrão com cópia própria do relógio do driver
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

  !> @brief Torna reprodutíveis, bit a bit, as somas feitas dentro dos conectores.
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
  !! Em seguida, escreve em cada entrada o método de interpolação do mapa de
  !! acoplamento (remapmethod, coluna method de EXCHANGES; cpl_write_methods).
  !! Hoje é bilinear em todas.
  !!
  !! Depois, com as listas prontas, registra no log o relatório dos conectores
  !! e a conferência do mapa de acoplamento (cpl_check_coupling), que não
  !! muda as listas; uma diferença na conferência interrompe a inicialização
  !! aqui.
  subroutine ModifyCplLists(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    character(len=*), parameter :: OPT_ORDER = ':termorder=srcseq'
    character(len=*), parameter :: OPT_SRC   = ':srcTermProcessing=0'
    character(len=512), allocatable :: cplList(:)
    type(ESMF_CplComp),     pointer :: connectors(:)
    integer :: i, j, n, n_order, n_src, n_full, n_method, n_full_method

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

    call log_info(COMP_DRV, 'reprodutibilidade dos conectores: termorder=srcseq em '// &
      int_to_str(n_order)//' entrada(s), srcTermProcessing=0 em '//int_to_str(n_src)// &
      ' entrada(s)')

    call cpl_write_methods(driver,                                                   &
      [character(len=4) :: MPAS_LABEL, MED_LABEL, OCN_LABEL, ICE_LABEL],             &
      [character(len=4) :: 'ATM', 'MED', 'OCN', 'ICE'], n_method, n_full_method, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call log_info(COMP_DRV, 'metodo dos conectores pelo mapa: remapmethod em '// &
      int_to_str(n_method)//' entrada(s)')

    call cpl_check_coupling(driver, cpl_current_config(),                            &
      [character(len=4) :: MPAS_LABEL, MED_LABEL, OCN_LABEL, ICE_LABEL],             &
      [character(len=4) :: 'ATM', 'MED', 'OCN', 'ICE'], rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (n_full > 0) then
      if (on_root()) call log_error(COMP_DRV, int_to_str(n_full)//' entrada(s) de CplList '// &
        'sem espaco para as opcoes de reprodutibilidade; aumentar len de cplList')
      rc = ESMF_FAILURE
    end if
    if (n_full_method > 0) then
      if (on_root()) call log_error(COMP_DRV, int_to_str(n_full_method)//' entrada(s) de '// &
        'CplList sem espaco para o metodo do mapa; aumentar len em cpl_write_methods')
      rc = ESMF_FAILURE
    end if

  contains

    !> Acrescenta option à entrada, se key ainda não está nela, e conta a mudança.
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

  !> @brief Define a sequência de execução de cada passo de acoplamento.
  !!
  !! A sequência vem da tabela RUN_SEQUENCES (run_sequences.F90), escolhida
  !! pela configuração:
  !!   modo        oceano     gelo   seq_repro   sequência
  !!   concurrent  MOM6       sim    -           conc_mom6_ice
  !!   concurrent  MOM6       não    -           conc_mom6
  !!   concurrent  DOCN       -      -           conc_docn
  !!   sequential  MOM6       sim    sim         seq_mom6_ice_repro
  !!   sequential  MOM6       sim    não         seq_mom6_ice
  !!   sequential  MOM6       não    -           seq_mom6
  !!   sequential  DOCN       -      -           seq_docn
  !! ("MOM6" aqui significa use_med_to_mpas=.true.). Com a chave
  !! run_sequence_file, vem do arquivo dado (run_sequence_from_file).
  subroutine SetRunSequence(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    character(len=RUN_SEQUENCE_LINE_LEN)   :: steps(MAX_RUN_SEQUENCE_LINES)
    character(len=RUN_SEQUENCE_LINE_LEN+2) :: lines(MAX_RUN_SEQUENCE_LINES+2)
    integer :: n, k
    character(len=:), allocatable :: title
    type(NUOPC_FreeFormat)  :: runSeqFF
    type(ESMF_Clock)        :: driverClock
    type(ESMF_TimeInterval) :: timeStep
    integer(ESMF_KIND_I8)   :: dt_s
    logical :: ice
    integer :: i

    rc = ESMF_SUCCESS

    ! Período do laço = passo do relógio do driver (dt_coupling)
    call ESMF_GridCompGet(driver, clock=driverClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_ClockGet(driverClock, timeStep=timeStep, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_TimeIntervalGet(timeStep, s_i8=dt_s, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (len_trim(cfg_run_sequence_file) > 0) then
      call run_sequence_from_file(cfg_run_sequence_file, runSeqFF, rc)
      if (rc /= ESMF_SUCCESS) then
        if (on_root()) call log_error(COMP_DRV, 'run_sequence_file: nao foi possivel ler a '// &
          'sequencia '//RUN_SEQUENCE_LABEL//' de '//trim(cfg_run_sequence_file))
        return
      end if
      title = 'do arquivo '//trim(cfg_run_sequence_file)
    else
      ice = cfg_use_sis2_dynamic .and. cfg_use_med_to_mpas
      k = run_sequence_index(run_sequence_name(trim(cfg_coupling_mode) == 'concurrent', &
                                               cfg_use_med_to_mpas, ice, cfg_seq_repro))
      call run_sequence_lines(RUN_SEQUENCES(k)%text, steps, n)
      title = trim(RUN_SEQUENCES(k)%title)

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
    end if
    call NUOPC_DriverIngestRunSequence(driver, runSeqFF, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_FreeFormatDestroy(runSeqFF, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DRV, 'RunSequence '//title//' (dt='//int_to_str(int(dt_s))//' s)')
  end subroutine SetRunSequence

  !> @brief Verdadeiro no PET 0 da VM atual: erros que valem em todos os PETs são
  !! registrados por log_error só uma vez (a saída padrão não repete a linha).
  logical function on_root()
    type(ESMF_VM) :: vm
    integer :: localPet, lrc
    on_root = .true.
    call ESMF_VMGetCurrent(vm, rc=lrc)
    if (lrc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, rc=lrc)
    if (lrc /= ESMF_SUCCESS) return
    on_root = (localPet == 0)
  end function on_root

end module ESM_MONAN
