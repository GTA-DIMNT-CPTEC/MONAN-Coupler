!> @file test_run_sequences.F90
!! @brief Sequências de execução como texto (run_sequences_mod) e chave run_sequence_file.
!!
!! Confere, num só processo:
!!
!!   tabela       cada uma das sete sequências de RUN_SEQUENCES dá
!!                exatamente as linhas e o título que o driver usava antes
!!                de a sequência virar texto (copiados aqui do esm.F90 da
!!                R-FASE13-21); nenhum texto passa do número de linhas ou do
!!                comprimento de linha
!!   escolha      run_sequence_name escolhe, para as 16 combinações das
!!                chaves, a mesma sequência que a cadeia de if do driver
!!                escolhia
!!   arquivo      run_sequence_from_file lê a sequência sob o rótulo
!!                runSeq:: de um arquivo e falha com um arquivo sem o rótulo
!!   chave        run_sequence_file de &nuopc_driver: vazia por padrão;
!!                aceita com um arquivo que existe; erro fatal, sem mudar o
!!                valor, com um arquivo que não existe
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_run_sequences
  use ESMF,               only : ESMF_Initialize, ESMF_Finalize, ESMF_LOGKIND_SINGLE, ESMF_SUCCESS
  use NUOPC,              only : NUOPC_FreeFormat, NUOPC_FreeFormatGet, NUOPC_FreeFormatDestroy, &
                                 NUOPC_FreeFormatLen
  use run_sequences_mod,  only : RUN_SEQUENCES, RUN_SEQUENCE_LINE_LEN, MAX_RUN_SEQUENCE_LINES, &
                                 run_sequence_name, run_sequence_index, run_sequence_lines,    &
                                 run_sequence_from_file
  use coupler_config_mod, only : config_read, cfg_run_sequence_file
  implicit none

  integer, parameter :: LW = RUN_SEQUENCE_LINE_LEN
  character(len=*), parameter :: M2A = 'MED -> MPAS', M2O = 'MED -> OCN', M2I = 'MED -> ICE'
  character(len=*), parameter :: A2M = 'MPAS -> MED', O2M = 'OCN -> MED', I2M = 'ICE -> MED'
  character(len=*), parameter :: O2A = 'OCN -> MPAS'
  character(len=*), parameter :: SEQ_FILE = 'test_run_sequences.seq'
  character(len=*), parameter :: NML = 'test_run_sequences.nml'
  integer :: nfailures, rc

  nfailures = 0
  call ESMF_Initialize(defaultLogFileName='test_run_sequences.ESMF_LogFile', &
                       logkindflag=ESMF_LOGKIND_SINGLE, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 2

  ! --- tabela -------------------------------------------------------------
  call check_table('conc_mom6_ice', 'Fase 2 CONCORRENTE + ICE (SIS2)', &
    [character(len=LW) :: M2A, M2O, M2I, 'MPAS', 'OCN', 'ICE', A2M, O2M, I2M, 'MED'])
  call check_table('conc_mom6', 'Fase 2 CONCORRENTE (MED->MPAS)', &
    [character(len=LW) :: M2A, M2O, 'MPAS', 'OCN', A2M, O2M, 'MED'])
  call check_table('conc_docn', 'Fase 1 CONCORRENTE (OCN->MPAS)', &
    [character(len=LW) :: O2A, M2O, 'MPAS', 'OCN', A2M, O2M, 'MED'])
  call check_table('seq_mom6_ice_repro', 'Fase 2 SEQUENCIAL REPRODUTIVEL + ICE (SIS2)', &
    [character(len=LW) :: M2A, 'MPAS', M2O, 'OCN', M2I, 'ICE', A2M, O2M, I2M, 'MED'])
  call check_table('seq_mom6_ice', 'Fase 2 SEQUENCIAL + ICE (SIS2)', &
    [character(len=LW) :: O2M, I2M, A2M, 'MED', M2A, 'MPAS', M2O, 'OCN', M2I, 'ICE'])
  call check_table('seq_mom6', 'Fase 2 (MED->MPAS)', &
    [character(len=LW) :: O2M, A2M, 'MED', M2A, 'MPAS', M2O, 'OCN'])
  call check_table('seq_docn', 'Fase 1 (OCN->MPAS direto)', &
    [character(len=LW) :: O2A, 'MPAS', A2M, O2M, 'MED', M2O, 'OCN'])
  call outcome('tabela: sete sequencias', size(RUN_SEQUENCES) == 7)
  call check_limits()

  ! --- escolha ------------------------------------------------------------
  call check_choice()

  ! --- arquivo ------------------------------------------------------------
  call check_file()

  ! --- chave --------------------------------------------------------------
  call check_key()

  call ESMF_Finalize(rc=rc)
  if (nfailures == 0) then
    write(*,'(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*,'(I0,A)') nfailures, ' teste(s) falharam'
    error stop 1
  end if

contains

  !> @brief Linhas e título da sequência name iguais aos esperados.
  subroutine check_table(name, title, expected)
    character(len=*),  intent(in) :: name, title
    character(len=LW), intent(in) :: expected(:)
    character(len=LW) :: lines(MAX_RUN_SEQUENCE_LINES)
    integer :: k, n
    logical :: ok

    k = run_sequence_index(name)
    ok = k > 0
    if (ok) then
      call run_sequence_lines(RUN_SEQUENCES(k)%text, lines, n)
      ok = n == size(expected) .and. trim(RUN_SEQUENCES(k)%title) == title
      if (ok) ok = all(lines(1:n) == expected)
    end if
    call outcome('tabela: '//name//' com as linhas e o titulo de antes', ok)
  end subroutine check_table

  !> @brief Nenhuma sequência passa do número de linhas nem do comprimento de linha.
  subroutine check_limits()
    character(len=LW) :: lines(MAX_RUN_SEQUENCE_LINES)
    integer :: k, n
    logical :: ok

    ok = .true.
    do k = 1, size(RUN_SEQUENCES)
      call run_sequence_lines(RUN_SEQUENCES(k)%text, lines, n)
      if (n < 1) ok = .false.
    end do
    call outcome('tabela: textos dentro dos limites', ok)
    call run_sequence_lines('A; B; C; D; E; F; G; H; I; J; K', lines, n)
    call outcome('limites: 11 linhas recusadas', n == -1)
    call run_sequence_lines('linha de mais de vinte e quatro caracteres', lines, n)
    call outcome('limites: linha longa recusada', n == -1)
  end subroutine check_limits

  !> @brief Para as 16 combinações, a mesma sequência da cadeia de if antiga.
  subroutine check_choice()
    logical :: concurrent, mom6, sis2, repro, ice, ok
    character(len=48) :: old_title
    integer :: c, k

    ok = .true.
    do c = 0, 15
      concurrent = btest(c, 0); mom6 = btest(c, 1); sis2 = btest(c, 2); repro = btest(c, 3)
      ice = sis2 .and. mom6
      if (concurrent .and. ice) then
        old_title = 'Fase 2 CONCORRENTE + ICE (SIS2)'
      else if (concurrent .and. mom6) then
        old_title = 'Fase 2 CONCORRENTE (MED->MPAS)'
      else if (concurrent) then
        old_title = 'Fase 1 CONCORRENTE (OCN->MPAS)'
      else if (ice .and. repro) then
        old_title = 'Fase 2 SEQUENCIAL REPRODUTIVEL + ICE (SIS2)'
      else if (ice) then
        old_title = 'Fase 2 SEQUENCIAL + ICE (SIS2)'
      else if (mom6) then
        old_title = 'Fase 2 (MED->MPAS)'
      else
        old_title = 'Fase 1 (OCN->MPAS direto)'
      end if
      k = run_sequence_index(run_sequence_name(concurrent, mom6, ice, repro))
      if (k == 0) then
        ok = .false.
      else if (RUN_SEQUENCES(k)%title /= old_title) then
        ok = .false.
      end if
    end do
    call outcome('escolha: 16 combinacoes como a cadeia de if antiga', ok)
  end subroutine check_choice

  !> @brief Sequência lida de arquivo sob o rótulo runSeq::.
  subroutine check_file()
    type(NUOPC_FreeFormat) :: ff
    character(len=NUOPC_FreeFormatLen), pointer :: list(:)
    character(len=LW), parameter :: expected(9) = [character(len=LW) :: '@3600', &
      O2M, A2M, 'MED', M2A, 'MPAS', M2O, 'OCN', '@']
    integer :: u, n, i
    logical :: ok

    open(newunit=u, file=SEQ_FILE, status='replace', action='write')
    write(u,'(A)') 'outro_rotulo: 1'
    write(u,'(A)') 'runSeq::'
    write(u,'(A)') '@3600'
    write(u,'(A)') '  OCN -> MED'
    write(u,'(A)') '  MPAS -> MED'
    write(u,'(A)') '  MED'
    write(u,'(A)') '  MED -> MPAS'
    write(u,'(A)') '  MPAS'
    write(u,'(A)') '  MED -> OCN'
    write(u,'(A)') '  OCN'
    write(u,'(A)') '@'
    write(u,'(A)') '::'
    close(u)

    call run_sequence_from_file(SEQ_FILE, ff, rc)
    ok = rc == ESMF_SUCCESS
    if (ok) then
      call NUOPC_FreeFormatGet(ff, lineCount=n, stringList=list, rc=rc)
      ok = rc == ESMF_SUCCESS .and. n == size(expected)
      if (ok) then
        do i = 1, n
          if (trim(adjustl(list(i))) /= trim(expected(i))) ok = .false.
        end do
      end if
      call NUOPC_FreeFormatDestroy(ff, rc=rc)
    end if
    call outcome('arquivo: sequencia lida sob runSeq::', ok)

    open(newunit=u, file=SEQ_FILE, status='replace', action='write')
    write(u,'(A)') 'outro_rotulo: 1'
    close(u)
    call run_sequence_from_file(SEQ_FILE, ff, rc)
    call outcome('arquivo: sem o rotulo, falha', rc /= ESMF_SUCCESS)
  end subroutine check_file

  !> @brief Chave run_sequence_file lida por config_read.
  subroutine check_key()
    call outcome('chave: vazia por padrao', len_trim(cfg_run_sequence_file) == 0)

    call write_nml("run_sequence_file = '"//SEQ_FILE//"'")
    call config_read(rc, NML)
    call outcome('chave: arquivo existente aceito', rc == 0 .and. trim(cfg_run_sequence_file) == SEQ_FILE)

    call write_nml("run_sequence_file = 'nao_existe.seq'")
    call config_read(rc, NML)
    call outcome('chave: arquivo ausente e erro fatal sem mudar o valor', &
                 rc == 2 .and. trim(cfg_run_sequence_file) == SEQ_FILE)
  end subroutine check_key

  !> @brief nuopc.input do teste: &nuopc_driver com a linha dada e os grupos obrigatórios vazios.
  subroutine write_nml(line)
    character(len=*), intent(in) :: line
    integer :: u
    open(newunit=u, file=NML, status='replace', action='write')
    write(u,'(A)') '&nuopc_driver'
    write(u,'(A)') '  '//line
    write(u,'(A)') '/'
    write(u,'(A)') '&nuopc_atm /'
    write(u,'(A)') '&nuopc_netcdf /'
    write(u,'(A)') '&nuopc_atm_bnd /'
    write(u,'(A)') '&nuopc_docn /'
    write(u,'(A)') '&nuopc_ocn /'
    write(u,'(A)') '&nuopc_mode /'
    write(u,'(A)') '&nuopc_petlayout /'
    close(u)
  end subroutine write_nml

  !> @brief Escreve PASSOU ou FALHOU para o caso e conta as falhas.
  subroutine outcome(name, ok)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: ok
    if (ok) then
      write(*,'(2A)') 'PASSOU  ', name
    else
      write(*,'(2A)') 'FALHOU  ', name
      nfailures = nfailures + 1
    end if
  end subroutine outcome

end program test_run_sequences
