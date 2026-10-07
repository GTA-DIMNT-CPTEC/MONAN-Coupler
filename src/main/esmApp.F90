!> @file esmApp.F90
!! @brief Programa principal do sistema acoplado MONAN-A 2.0 x MOM6 + SIS2.
!!
!! Etapas:
!!   1. lê nuopc.input (antes do ESMF, portanto sem MPI);
!!   2. inicializa o ESMF, com os logs PET*.esmApp.log em cfg_log_dir;
!!   3. cria o relógio global (start_date, stop_date, dt_coupling);
!!   4. cria o driver ESM, inicializa e executa um passo de acoplamento por
!!      chamada a ESMF_GridCompRun, até stop_date;
!!   5. encerra o ESMF sem finalizar o MPI.
!!
!! Mensagens na saída padrão marcadas com [OK], "Passos (est.)" e
!! "SIMULACAO CONCLUIDA COM SUCESSO" são lidas pelas ferramentas de
!! tools/coupler: não alterar sem ajustá-las.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

program esmApp

  use ESMF
  use ESM_MONAN,          only : ESM_SetServices => SetServices
  use coupler_config_mod, only : config_read, config_parse_date, CONFIG_FILE_DEFAULT, &
                                 cfg_start_date, cfg_stop_date, cfg_dt_coupling,   &
                                 cfg_log_dir, cfg_log_kind
  use coupler_utils_mod,  only : ChkErr, int_to_str

  implicit none

  type(ESMF_GridComp)     :: esmComp
  type(ESMF_Clock)        :: clock
  type(ESMF_Time)         :: startTime, stopTime
  type(ESMF_TimeInterval) :: timeStep
  type(ESMF_LogKind_Flag) :: logKind
  integer(ESMF_KIND_I8)   :: total_s
  integer :: rc, userRc, petCount, step, nSteps, ios
  integer :: localPet = 0

  ! 1. Configuração
  call config_read(rc)
  if (rc == 2) error stop 'ERRO fatal na leitura de nuopc.input'

  ! 2. ESMF
  ! O ESMF cria PET*.esmApp.log no diretório corrente; por isso entramos em
  ! cfg_log_dir durante a inicialização. chdir é extensão do gfortran.
  call execute_command_line('mkdir -p '//trim(cfg_log_dir))
  call chdir(trim(cfg_log_dir), status=ios)
  if (ios /= 0) write(*,'(A)') 'AVISO: chdir para log_dir falhou; logs no diretorio corrente'

  logKind = ESMF_LOGKIND_MULTI
  if (trim(cfg_log_kind) == 'multi_on_error') logKind = ESMF_LOGKIND_MULTI_ON_ERROR

  call ESMF_Initialize(defaultCalkind=ESMF_CALKIND_GREGORIAN, logKindFlag=logKind, &
                       defaultLogFileName='esmApp.log', rc=rc)
  if (ios == 0) call chdir('..')
  if (rc /= ESMF_SUCCESS) error stop 'ERRO: ESMF_Initialize falhou'

  ! 3. Relógio global
  call set_time(cfg_start_date, startTime)
  call set_time(cfg_stop_date,  stopTime)
  call ESMF_TimeIntervalSet(timeStep, s=cfg_dt_coupling, rc=rc)
  call check(rc, __LINE__)

  ! Número de passos a partir do intervalo real do calendário gregoriano
  call ESMF_TimeIntervalGet(stopTime - startTime, s_i8=total_s, rc=rc)
  call check(rc, __LINE__)
  nSteps = max(1, int(total_s / int(cfg_dt_coupling, ESMF_KIND_I8)))

  clock = ESMF_ClockCreate(timeStep=timeStep, startTime=startTime, stopTime=stopTime, &
                           name='esmApp_clock', rc=rc)
  call check(rc, __LINE__)
  call print_banner()

  ! 4. Driver
  esmComp = ESMF_GridCompCreate(name='ESM', clock=clock, rc=rc)
  call check(rc, __LINE__)
  call ESMF_GridCompSetServices(esmComp, ESM_SetServices, userRc=userRc, rc=rc)
  call check(rc, __LINE__, userRc)
  call say('[OK] Driver ESM registrado')

  call ESMF_GridCompInitialize(esmComp, clock=clock, userRc=userRc, rc=rc)
  call check(rc, __LINE__, userRc)
  call say('[OK] Inicializacao concluida')

  ! Cada ESMF_GridCompRun executa exatamente um passo da RunSequence; uma
  ! única chamada até stop_date encerra a rodada antes da hora.
  call say('--- Loop de execucao: '//int_to_str(nSteps)//' passo(s) de acoplamento de '// &
           int_to_str(cfg_dt_coupling)//' s')
  do step = 1, nSteps
    call ESMF_GridCompRun(esmComp, clock=clock, userRc=userRc, rc=rc)
    call check(rc, __LINE__, userRc)
  end do
  call say('[OK] Todos os passos de acoplamento concluidos')

  ! 5. Encerramento
  ! ESMF_GridCompFinalize não é chamado: a limpeza do ESMF é incompatível com
  ! o MOAB e o SMIOL nesta versão. ESMF_END_KEEPMPI deixa o MPI_Finalize para
  ! o encerramento do processo, evitando SIGSEGV secundários de MPI_Abort.
  call say('SIMULACAO CONCLUIDA COM SUCESSO')
  call ESMF_Finalize(endflag=ESMF_END_KEEPMPI)

contains

  !> @brief Aborta a execução se rc (ou o userRc do componente) indicar erro.
  subroutine check(rc, line, userRc)
    integer, intent(in)           :: rc, line
    integer, intent(in), optional :: userRc

    if (ChkErr(rc, line, __FILE__)) call abort_run()
    if (present(userRc)) then
      if (ChkErr(userRc, line, __FILE__)) call abort_run()
    end if
  end subroutine check

  !> @brief Encerra todos os processos (ESMF_Finalize com ESMF_END_ABORT).
  subroutine abort_run()
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
    error stop
  end subroutine abort_run

  !> @brief Converte 'AAAA-MM-DD' em ESMF_Time às 00:00:00.
  subroutine set_time(date_str, t)
    character(len=*), intent(in)  :: date_str
    type(ESMF_Time),  intent(out) :: t
    integer :: yy, mm, dd, prc

    call config_parse_date(date_str, yy, mm, dd, prc)
    if (prc /= 0) then
      write(*,'(2A)') 'ERRO: data invalida em nuopc.input: ', trim(date_str)
      call abort_run()
    end if
    call ESMF_TimeSet(t, yy=yy, mm=mm, dd=dd, calkindflag=ESMF_CALKIND_GREGORIAN, rc=prc)
    call check(prc, __LINE__)
  end subroutine set_time

  !> @brief Escreve na saída padrão apenas no PET 0.
  subroutine say(msg)
    character(len=*), intent(in) :: msg
    if (localPet == 0) write(*,'(A)') msg
  end subroutine say

  !> @brief Escreve na saída padrão (PET 0) o cabeçalho da rodada com a configuração lida.
  subroutine print_banner()
    type(ESMF_VM) :: vm
    integer :: vrc

    call ESMF_VMGetGlobal(vm, rc=vrc)
    call check(vrc, __LINE__)
    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=vrc)
    call check(vrc, __LINE__)
    if (localPet /= 0) return
    write(*,'(A)') '================================================='
    write(*,'(A)') '  Sistema Acoplado MONAN-A 2.0 x MOM6+SIS2'
    write(*,'(A)') '================================================='
    write(*,'(2A)')        '  Configuracao   = ', CONFIG_FILE_DEFAULT
    write(*,'(A,I0)')      '  PETs           = ', petCount
    write(*,'(2A)')        '  Inicio         = ', trim(cfg_start_date)
    write(*,'(2A)')        '  Fim            = ', trim(cfg_stop_date)
    write(*,'(A,I0,A)')    '  dt_coupling    = ', cfg_dt_coupling, ' s'
    write(*,'(A,I0)')      '  Passos (est.)  = ', nSteps
    write(*,'(A)') '================================================='
  end subroutine print_banner

end program esmApp
