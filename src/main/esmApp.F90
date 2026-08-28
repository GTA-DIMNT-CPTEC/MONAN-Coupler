!> @file esmApp.F90
!! @brief Aplicativo principal do sistema acoplado MONAN-A 2.0 × MOM6+SIS2.
!!
!! Instancia o driver NUOPC ESM (ESM_MONAN), que gerencia internamente:
!!   - MPAS : modelo atmosférico MONAN-A 2.0 (MPAS 8.3.1)
!!   - MED  : mediador com fórmula bulk NCAR (Large & Yeager 2009)
!!   - OCN  : DOCN_cap (OISST v2.1 netcdf) quando use_docn=.true.  (Fase 1)
!!             MOM6+SIS2 dinâmico           quando use_docn=.false. (Fase 2)
!!
!! Conectores gerenciados pelo driver ESM:
!!   MPAS → MED  : campos atmosféricos (_mpas) → mediador
!!   OCN  → MED  : SST (So_t) → fórmula bulk
!!   MED  → OCN  : fluxos calculados (Foxx_*) → oceano
!!   MED  → MPAS : SST/gelo/correntes (Fase 2, regrid conservativo)
!!   OCN  → MPAS : SST lag t-1 (Fase 1, DOCN direto)
!!
!! O relógio global é criado aqui e passado ao driver NUOPC.
!! O driver distribui o relógio para cada componente conforme o RunSequence.
!!
!! INPE / CGCT / DIMNT — GT Acoplamento de Modelos — Maio 2026.

program esmApp

  use ESMF
  use ESM_MONAN,           only : ESM_SetServices => SetServices
  use mpas_cap_config_mod, only : config_read,       &
                                   config_parse_date, &
                                   CONFIG_FILE_DEFAULT, &
                                   cfg_start_date, cfg_stop_date, &
                                   cfg_dt_coupling, cfg_log_dir, cfg_log_kind
  use mpas_cap_utils_mod,  only : ChkErr

  implicit none

  type(ESMF_GridComp)     :: esmComp
  type(ESMF_State)        :: importState, exportState
  type(ESMF_Clock)        :: clock
  type(ESMF_Time)         :: startTime, stopTime
  type(ESMF_TimeInterval) :: timeStep
  type(ESMF_TimeInterval) :: totalInterval
  type(ESMF_VM)           :: vm

  integer :: rc, localPet, iStep, petCount
  integer :: yy_start, mm_start, dd_start
  integer :: yy_stop,  mm_stop,  dd_stop
  integer :: dt_coupling_s, nSteps
  integer(ESMF_KIND_I8) :: total_sec_i8
  integer :: config_rc, parse_rc, chdir_stat
  type(ESMF_LogKind_Flag) :: esmfLogKind

  !---------------------------------------------------------------------------
  ! 1. Leitura do namelist nuopc.input (ou variável de ambiente NUOPC_INPUT)
  !---------------------------------------------------------------------------
  call config_read(config_rc)
  if (config_rc == 2) then
    write(*,'(A)') 'ERRO fatal: falha na leitura do namelist (nuopc.input).'
    stop 2
  end if

  call config_parse_date(cfg_start_date, yy_start, mm_start, dd_start, parse_rc)
  if (parse_rc /= 0) then
    write(*,'(A,A)') 'ERRO: start_date invalida: ', trim(cfg_start_date)
    stop 2
  end if

  call config_parse_date(cfg_stop_date, yy_stop, mm_stop, dd_stop, parse_rc)
  if (parse_rc /= 0) then
    write(*,'(A,A)') 'ERRO: stop_date invalida: ', trim(cfg_stop_date)
    stop 2
  end if

  dt_coupling_s = cfg_dt_coupling

  !---------------------------------------------------------------------------
  ! 2. Inicialização do ESMF — logs gravados em cfg_log_dir (padrão: logs/)
  !
  !    Sequência de inicialização:
  !      a) mkdir -p logs/              (cria diretório se necessário)
  !      b) chdir logs/                 (muda CWD para que ESMF crie PET*.log lá)
  !      c) ESMF_Initialize             (abre os PET*.log no CWD corrente)
  !      d) chdir ..                    (retorna ao diretório de execução)
  !
  !    O nível de log é configurável via cfg_log_kind (&nuopc_driver/log_kind
  !    em nuopc.input — ver mpas_cap_config.F90), sem precisar recompilar:
  !
  !      log_kind = 'multi'           -> ESMF_LOGKIND_MULTI (padrão)
  !      log_kind = 'multi_on_error'  -> ESMF_LOGKIND_MULTI_ON_ERROR
  !
  !    ATENÇÃO ao escolher 'multi_on_error' (risco já validado nesta base):
  !      ESMF_LOGKIND_MULTI abre PET*.log imediatamente ao inicializar,
  !      garantindo que os arquivos sejam criados em logs/ independentemente
  !      de erros. ESMF_LOGKIND_MULTI_ON_ERROR só materializa o log em caso de
  !      erro — numa execução bem-sucedida, logs/PET*.esmApp.log pode ficar
  !      incompleto, no diretório errado (o chdir('..') já ocorreu) ou
  !      ausente. Isso quebra a leitura de logs por `test-concurrent.bash` e
  !      por `analisa_balanceamento_pets.py`, que dependem das marcações
  !      "Run intro."/"extro." gravadas em nível INFO. Use 'multi' durante
  !      calibração/testes; reserve 'multi_on_error' para produção já
  !      calibrada, quando o tempo por passo não precisa mais ser medido.
  !
  !    Nota: defaultLogFileName deve ser apenas o basename (sem '/'), pois o
  !      ESMF constrói o caminho como "PET{N}." + defaultLogFileName. Um
  !      caminho absoluto causa iostat=2 (ENOENT) em sistemas com muitos PETs.
  !---------------------------------------------------------------------------
  call execute_command_line('mkdir -p '//trim(cfg_log_dir))

  call chdir(trim(cfg_log_dir), status=chdir_stat)
  if (chdir_stat /= 0) &
    write(*,'(A)') 'AVISO: chdir para log_dir falhou — logs no diretorio corrente'

  if (trim(cfg_log_kind) == 'multi_on_error') then
    esmfLogKind = ESMF_LOGKIND_MULTI_ON_ERROR
  else
    esmfLogKind = ESMF_LOGKIND_MULTI
  end if

  call ESMF_Initialize(defaultCalkind    = ESMF_CALKIND_GREGORIAN, &
                       logKindFlag       = esmfLogKind,             &
                       defaultLogFileName= 'esmApp.log',            &
                       rc                = rc)

  call chdir('..', status=chdir_stat)
  if (rc /= ESMF_SUCCESS) then
    write(*,'(A)') 'ERRO: ESMF_Initialize falhou!'
    stop 1
  end if

  call ESMF_VMGetGlobal(vm=vm, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
    error stop
  end if

  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
    error stop
  end if

  ! Nota: config_read() é chamado antes de ESMF_Initialize (pré-MPI_Init),
  !   portanto MPI não está disponível naquele ponto. A confirmação de leitura
  !   é feita aqui, após ESMF_VMGet, quando localPet está disponível.
  if (localPet == 0) &
    write(*,'(A,A)') '[mpas_cap_config] Configuracao carregada de: ', &
                     trim(CONFIG_FILE_DEFAULT)

  !---------------------------------------------------------------------------
  ! 3. Relógio global ESMF (movido para antes da estimativa de passos — ver
  !    FIX abaixo)
  !---------------------------------------------------------------------------
  call ESMF_TimeSet(startTime, yy=yy_start, mm=mm_start, dd=dd_start, &
                    h=0, m=0, s=0, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  call ESMF_TimeSet(stopTime, yy=yy_stop, mm=mm_stop, dd=dd_stop, &
                    h=0, m=0, s=0, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  call ESMF_TimeIntervalSet(timeStep, s=dt_coupling_s, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  !---------------------------------------------------------------------------
  ! 4. Informações iniciais (apenas PET 0)
  !---------------------------------------------------------------------------
  ! FIX (corrigido, era bug real — reportado pelo usuário: "o acoplamento
  ! não obedece a data inicial e final da simulação"): a versão anterior
  ! calculava nSteps com um calendário APROXIMADO (365 dias/ano, 30
  ! dias/mês) via aritmética manual em segundos — para 2026-03-29 até
  ! 2026-04-30 isso dava 31 dias (1 mês "de 30" + 1 dia) = 744 passos,
  ! quando o intervalo REAL (março tem 31 dias) é de 32 dias = 768 passos.
  ! Nessa versão antiga, nSteps também era usado como limite de um laço
  ! manual "do iStep = 1, nSteps" chamando ESMF_GridCompRun repetidamente
  ! — a simulação genuinamente parava ~24h antes da stop_date configurada.
  ! Esse laço foi removido (ver FIX mais abaixo, seção 8) — nSteps agora
  ! serve só como valor informativo exibido no banner, não mais como
  ! limite de execução.
  !
  ! Corrigido calculando nSteps a partir do PRÓPRIO intervalo ESMF
  ! (stopTime - startTime), que já respeita o calendário Gregoriano real
  ! (calkindflag=ESMF_CALKIND_GREGORIAN já usado acima) — sem
  ! aproximação de dias por mês.
  totalInterval = stopTime - startTime
  call ESMF_TimeIntervalGet(totalInterval, s_i8=total_sec_i8, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if
  nSteps = max(1, int(total_sec_i8 / int(max(1, dt_coupling_s), ESMF_KIND_I8)))

  if (localPet == 0) then
    write(*,'(A)')
    write(*,'(A)') '================================================='
    write(*,'(A)') '  Sistema Acoplado MONAN-A 2.0 x MOM6+SIS2'
    write(*,'(A)') '  ESMF/NUOPC 8.9.1 | Mediador MED_cap ativo'
    write(*,'(A)') '================================================='
    write(*,'(A,I4)')      '  PETs           = ', petCount
    write(*,'(A,A)')       '  Inicio         = ', trim(cfg_start_date)
    write(*,'(A,A)')       '  Fim            = ', trim(cfg_stop_date)
    write(*,'(A,I7," s")') '  dt_coupling    = ', dt_coupling_s
    write(*,'(A,I5)')      '  Passos (est.)  = ', nSteps
    write(*,'(A)') '-------------------------------------------------'
    write(*,'(A)') '  Componentes: MPAS(real) + MED(bulk) + OCN(OISST|MOM6)'
    write(*,'(A)') '  Conectores : MPAS->MED  OCN->MED  MED->OCN  OCN->MPAS'
    write(*,'(A)') '================================================='
    write(*,'(A)')
  end if

  clock = ESMF_ClockCreate(timeStep=timeStep, startTime=startTime, &
                            stopTime=stopTime, name='esmApp_clock', rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  if (localPet == 0) write(*,'(A)') '[OK] Relogio ESMF criado'

  !---------------------------------------------------------------------------
  ! 5. Estados ESMF (gerenciados pelo driver NUOPC — não usados diretamente)
  !---------------------------------------------------------------------------
  importState = ESMF_StateCreate(name='esmApp_import', rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  exportState = ESMF_StateCreate(name='esmApp_export', rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  !---------------------------------------------------------------------------
  ! 6. Driver ESM — registra e gerencia MPAS + MED + OCN + conectores
  !---------------------------------------------------------------------------
  esmComp = ESMF_GridCompCreate(name='ESM', clock=clock, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  call ESMF_GridCompSetServices(esmComp, ESM_SetServices, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  if (localPet == 0) write(*,'(A)') '[OK] Driver ESM registrado'

  !---------------------------------------------------------------------------
  ! 7. Initialize — protocolo IPDv03 gerenciado pelo driver NUOPC
  !    O driver propaga as fases (AdvertiseFields, RealizeFields,
  !    DataInitialize) para MPAS, MED e OCN automaticamente.
  !---------------------------------------------------------------------------
  if (localPet == 0) write(*,'(A)') '--- Initialize (Driver ESM) ---'

  call ESMF_GridCompInitialize(esmComp, importState=importState, &
       exportState=exportState, clock=clock, rc=rc)
  if (ChkErr(rc, __LINE__, __FILE__)) then
    call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
  end if

  if (localPet == 0) write(*,'(A)') '[OK] Inicializacao concluida (MPAS + MED + OCN)'

  !---------------------------------------------------------------------------
  ! 8. Loop de execução
  !
  !    Cada chamada a ESMF_GridCompRun executa exatamente uma iteração do
  !    RunSequence (dt_coupling_s). O driver avança seu relógio interno e
  !    retorna. O contador iStep (1..nSteps) é mais robusto do que testar
  !    ESMF_ClockIsStopTime, cujo estado após Initialize é dependente da
  !    versão do NUOPC.
  !
  !    Exemplo: dt_coupling=1800 s, integração de 24 h → nSteps = 48.
  !
  !    REVERT (Ago 2026): uma tentativa anterior de trocar este laço por
  !    uma única chamada a ESMF_GridCompRun (baseada numa leitura de
  !    NUOPC_Driver.F90::routine_Run que sugeria que o driver avança
  !    sozinho até o stopTime) foi testada e IMEDIATAMENTE revertida: na
  !    prática, uma única chamada avança só ~1-2h e retorna — a
  !    simulação terminava prematuramente com "[OK] Todos os passos de
  !    acoplamento concluidos" após meia dúzia de linhas de MOM Date. O
  !    laço original estava certo nesse aspecto. A causa raiz real do
  !    relógio do MED avançando mais rápido que o esperado (relatado
  !    pelo usuário: diag_import chegando a datas muito além de
  !    stop_date) permanece em investigação — não é este laço.
  !---------------------------------------------------------------------------
  if (localPet == 0) then
    write(*,'(A)') '--- Loop de execucao (NUOPC Driver) ---'
    write(*,'(A,I0,A,I0,A)') &
      '    ', nSteps, ' passo(s) de acoplamento de ', dt_coupling_s, ' s'
  end if

  do iStep = 1, nSteps
    call ESMF_GridCompRun(esmComp, importState=importState, &
         exportState=exportState, clock=clock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) then
      call ESMF_Finalize(endflag=ESMF_END_ABORT); error stop
    end if
  end do

  if (localPet == 0) write(*,'(A)') '[OK] Todos os passos de acoplamento concluidos'

  !---------------------------------------------------------------------------
  ! 9. Finalização
  !
  !    ESMF_GridCompFinalize omitida: ESMF_MOAB e SMIOL são incompatíveis
  !    com a rotina de cleanup do ESMF nesta versão.
  !
  !    ESMF_END_KEEPMPI: encerra o ESMF sem chamar MPI_Abort/MPI_Finalize.
  !    O atexit handler do MPICH chama MPI_Finalize ao final do processo.
  !    Isso evita o artefato onde MPI_Abort propaga SIGTERM a ranks ainda em
  !    signal handlers, causando SIGSEGV secundária (falso positivo).
  !
  !    'stop' sem argumento encerra silenciosamente (Fortran 2018 §11.4).
  !    'stop 0' imprime "STOP 0" no stderr em gfortran (evitado aqui).
  !---------------------------------------------------------------------------
  if (localPet == 0) write(*,'(A)') '--- Finalize ---'

  if (localPet == 0) then
    write(*,'(A)')
    write(*,'(A)') '================================================='
    write(*,'(A)') '  SIMULACAO CONCLUIDA COM SUCESSO                '
    write(*,'(A)') '================================================='
    write(*,'(A)')
  end if

  call ESMF_Finalize(endflag=ESMF_END_KEEPMPI)
  stop

end program esmApp
