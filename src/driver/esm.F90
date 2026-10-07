!> @file esm.F90
!! @brief Driver NUOPC do sistema acoplado MONAN-A 2.0 x MOM6 + SIS2.
!!
!! O driver registra os componentes e os conectores e define a ordem de
!! execução de cada passo de acoplamento (RunSequence). Tudo o que ele faz é
!! decidido pela configuração lida de nuopc.input (coupler_config_mod).
!!
!! Componentes (rótulo no driver, por posição):
!!   MPAS  atmosfera MONAN-A 2.0 (MPAS-A 8.3.1)
!!   MED   mediador: fluxos ar-mar por fórmulas bulk NCAR
!!   OCN   oceano: MOM6 dinâmico, ou DOCN (SST lida de arquivo OISST)
!!   ICE   gelo marinho SIS2 (opcional, use_sis2_dynamic)
!! Os modelos que podem ocupar cada posição são registrados uma vez, com a
!! rotina SetServices e os atributos de cada um (register_models); o driver
!! percorre as posições de POSITIONS (driver_layout.F90), na ordem, e
!! registra em cada uma o modelo escolhido pela configuração
!! (chosen_model).
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
  use driver_layout_mod,  only : POSITIONS, N_POSITIONS, position_index, split_blocks, &
                                 layout_split_line, layout_shared_line, idle_pets_line
  use run_sequences_mod,  only : RUN_SEQUENCES, RUN_SEQUENCE_LINE_LEN, MAX_RUN_SEQUENCE_LINES, &
                                 RUN_SEQUENCE_LABEL, run_sequence_name, run_sequence_index,     &
                                 run_sequence_lines, run_sequence_from_file
  use cpl_map_mod,        only : cpl_driver_connectors, &
                                 CONNECTOR_SRC, CONNECTOR_DST, N_CONNECTORS, EXCHANGES

  implicit none
  private
  public :: SetServices

  !> Interface das rotinas SetServices dos caps.
  abstract interface
    subroutine set_services_iface(gcomp, rc)
      import :: ESMF_GridComp
      type(ESMF_GridComp)  :: gcomp
      integer, intent(out) :: rc
    end subroutine set_services_iface
  end interface

  !> Modelo que pode ocupar uma posição do acoplamento (register_model).
  type :: model_t
    character(len=4)  :: position = ''        !< posição (POSITIONS, em driver_layout)
    character(len=8)  :: name     = ''        !< nome do modelo ('mpas', 'mom6', ...)
    character(len=4)  :: label    = ''        !< rótulo do componente no driver
    logical           :: check_time_stamps = .true.  !< timeStampValidation do NUOPC
    character(len=64) :: note     = ''        !< mensagem no registro, depois do registro
    procedure(set_services_iface), pointer, nopass :: set_services => null()
  end type model_t

  integer, parameter :: MAX_MODELS = 8
  type(model_t) :: models(MAX_MODELS)
  integer :: n_models = 0

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

  !> @brief Registra os modelos que podem ocupar cada posição (models), um por
  !! chamada a register_model. O rótulo é o nome do componente no driver, na
  !! sequência de execução, no registro e no relatório de acoplamento.
  subroutine register_models()
    n_models = 0
    call register_model('ATM', 'mpas', 'MPAS', MPAS_SetServices)
    call register_model('MED', 'med',  'MED',  MED_SetServices)
    ! O FMS (MOM6 e SIS2) tem relógio próprio, e o DOCN segue o mesmo
    ! tratamento do oceano: pequenas diferenças de carimbo de tempo são
    ! esperadas e não devem abortar a rodada (check_time_stamps=.false.).
    call register_model('OCN', 'mom6', 'OCN',  OCN_SetServices,  .false., &
                        'OCN = MOM6+SIS2 dinamico (use_docn=F)')
    call register_model('OCN', 'docn', 'OCN',  DOCN_SetServices, .false., &
                        'OCN = DOCN OISST (use_docn=T)')
    call register_model('ICE', 'sis2', 'ICE',  ICE_SetServices,  .false., &
                        'componente ICE (SIS2) registrado')
  end subroutine register_models

  !> @brief Acrescenta um modelo à tabela models.
  !!
  !! @param[in] position           posição que o modelo pode ocupar (POSITIONS)
  !! @param[in] name               nome do modelo, como o escolhe chosen_model
  !! @param[in] label              rótulo do componente no driver
  !! @param[in] set_services       rotina SetServices do cap
  !! @param[in] check_time_stamps  se falso, timeStampValidation=false no componente
  !! @param[in] note               mensagem no registro depois de registrar o componente
  subroutine register_model(position, name, label, set_services, check_time_stamps, note)
    character(len=*), intent(in) :: position, name, label
    procedure(set_services_iface) :: set_services
    logical,          intent(in), optional :: check_time_stamps
    character(len=*), intent(in), optional :: note

    if (n_models == MAX_MODELS) error stop 'register_model: MAX_MODELS insuficiente'
    n_models = n_models + 1
    models(n_models)%position = position
    models(n_models)%name     = name
    models(n_models)%label    = label
    models(n_models)%set_services => set_services
    if (present(check_time_stamps)) models(n_models)%check_time_stamps = check_time_stamps
    if (present(note)) models(n_models)%note = note
  end subroutine register_model

  !> @brief Modelo escolhido para a posição pela configuração ('none': posição
  !! vazia). A atmosfera é sempre o MONAN-A: o driver não registra o DATM.
  !!
  !! @param[in] position  nome da posição (POSITIONS)
  function chosen_model(position) result(name)
    character(len=*), intent(in) :: position
    character(len=8) :: name

    select case (trim(position))
    case ('ATM')
      name = 'mpas'
    case ('MED')
      name = 'med'
    case ('OCN')
      name = merge('docn', 'mom6', cfg_use_docn)
    case ('ICE')
      name = merge('sis2', 'none', cfg_use_sis2_dynamic)
    case default
      name = 'none'
    end select
  end function chosen_model

  !> @brief Contagem de PETs pedida no nuopc.input para a posição (0 = automática).
  !!
  !! @param[in] position  nome da posição (POSITIONS)
  integer function requested_pets(position) result(n)
    character(len=*), intent(in) :: position

    select case (trim(position))
    case ('ATM')
      n = cfg_atm_pet_count
    case ('OCN')
      n = cfg_ocn_pet_count
    case ('ICE')
      n = cfg_ice_pet_count
    case default
      n = 0
    end select
  end function requested_pets

  !> @brief Índice em models do modelo name na posição (0 se não registrado).
  !!
  !! @param[in] position  nome da posição
  !! @param[in] name      nome do modelo
  integer function model_index(position, name) result(m)
    character(len=*), intent(in) :: position, name
    do m = 1, n_models
      if (trim(models(m)%position) == trim(position) .and. trim(models(m)%name) == trim(name)) return
    end do
    m = 0
  end function model_index

  !> @brief Rótulo no driver do componente da posição (o do primeiro modelo
  !! registrado para ela; os modelos de uma mesma posição têm o mesmo rótulo).
  !!
  !! @param[in] position  nome da posição ('ATM', 'MED', 'OCN', 'ICE')
  function position_label(position) result(label)
    character(len=*), intent(in) :: position
    character(len=4) :: label
    integer :: m

    label = position
    do m = 1, n_models
      if (trim(models(m)%position) == trim(position)) then
        label = models(m)%label
        return
      end if
    end do
  end function position_label

  !> @brief Registra componentes e conectores.
  !!
  !! Em cada posição de POSITIONS, na ordem, registra o modelo escolhido pela
  !! configuração (chosen_model), com os atributos da tabela models. No
  !! layout split, as posições com bloco próprio recebem PETs disjuntos
  !! (split_blocks, em driver_layout); o mediador fica em todos os PETs.
  subroutine SetModelServices(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    type(ESMF_GridComp)  :: comp
    type(ESMF_Clock)     :: driverClock
    integer              :: petCount, i, k, m, first
    integer              :: chosen(N_POSITIONS), requested(N_POSITIONS), counts(N_POSITIONS)
    logical              :: active(N_POSITIONS), split, ok
    integer, allocatable :: allPets(:), pets(:)
    character(len=4), allocatable :: labels(:)
    character(len=:), allocatable :: exec

    rc = ESMF_SUCCESS
    call register_models()

    ! Nomes de campo do acoplador (_mpas, Foxx_* etc.): os de FIELDS, no
    ! dicionário do NUOPC, sem acréscimo automático
    call cpl_nuopc_dictionary(rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridCompGet(driver, petCount=petCount, clock=driverClock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    do k = 1, N_POSITIONS
      chosen(k) = model_index(POSITIONS(k)%name, chosen_model(POSITIONS(k)%name))
      requested(k) = requested_pets(POSITIONS(k)%name)
    end do
    active = chosen > 0

    ! Divisão de PETs entre componentes
    allPets = [(i - 1, i = 1, petCount)]
    split = trim(cfg_pet_layout) == 'split'
    exec = merge('CONCURRENT', 'SEQUENTIAL', trim(cfg_coupling_mode) == 'concurrent')
    if (split) then
      call split_blocks(petCount, requested, active, counts, ok)
      if (.not. ok) then
        if (on_root()) call log_error(COMP_DRV, 'particao split invalida: nAtm='// &
          int_to_str(counts(position_index('ATM')))//' nOcn='// &
          int_to_str(counts(position_index('OCN')))//' nIce='// &
          int_to_str(counts(position_index('ICE')))//' devem somar petCount='// &
          int_to_str(petCount)//'.')
        rc = ESMF_FAILURE
        return
      end if
      call log_info(COMP_DRV, layout_split_line(exec, counts, active))
      ! No sequential+split parte dos PETs fica parada em cada fase; registrar
      ! quantos ajuda a interpretar o consumo de fila (nós x tempo de parede).
      if (exec == 'SEQUENTIAL') call log_info(COMP_DRV, idle_pets_line(petCount, counts, active))
    else
      labels = [character(len=4) :: (models(chosen(k))%label, k = 1, N_POSITIONS)]
      labels = pack(labels, active)
      call log_info(COMP_DRV, layout_shared_line(exec, labels))
    end if

    ! Componentes, na ordem das posições
    first = 0
    do k = 1, N_POSITIONS
      if (.not. active(k)) cycle
      m = chosen(k)
      if (split .and. POSITIONS(k)%own_block) then
        pets = allPets(first+1:first+counts(k))
        first = first + counts(k)
      else
        pets = allPets
      end if
      call add_model(driver, trim(models(m)%label), models(m)%set_services, pets, driverClock, comp, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      if (.not. models(m)%check_time_stamps) then
        call NUOPC_CompAttributeSet(comp, name='timeStampValidation', value='false', rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
      end if
      if (len_trim(models(m)%note) > 0) call log_info(COMP_DRV, trim(models(m)%note))
    end do

    ! Conectores
    ! Escolhidos pelo mapa de acoplamento (EXCHANGES, coluna when), na ordem
    ! de CONNECTOR_SRC/CONNECTOR_DST.
    call add_connectors(driver, driverClock, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call log_info(COMP_DRV, 'componentes e conectores registrados')
  end subroutine SetModelServices

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
      call add_connector(driver, trim(position_label(CONNECTOR_SRC(order(k)))), &
                         trim(position_label(CONNECTOR_DST(order(k)))), driverClock, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

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
      [position_label('ATM'), position_label('MED'), position_label('OCN'), position_label('ICE')],             &
      [character(len=4) :: 'ATM', 'MED', 'OCN', 'ICE'], n_method, n_full_method, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call log_info(COMP_DRV, 'metodo dos conectores pelo mapa: remapmethod em '// &
      int_to_str(n_method)//' entrada(s)')

    call cpl_check_coupling(driver, cpl_current_config(),                            &
      [position_label('ATM'), position_label('MED'), position_label('OCN'), position_label('ICE')],             &
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
