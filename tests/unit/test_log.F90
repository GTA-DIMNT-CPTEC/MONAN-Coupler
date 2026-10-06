!> @file test_log.F90
!! @brief Níveis do registro do acoplador (coupler_log_mod) e chave log_level.
!!
!! Confere, num só processo:
!!
!!   leitura      log_level de &nuopc_driver: o padrão é 'info'; o valor
!!                vai para minúsculas; um valor fora de warning|info|debug
!!                é erro fatal e não muda o nível; a chave obsoleta
!!                write_fixdiag é aceita e não muda o nível
!!   gravação     com cada nível, quais de log_warning, log_info e
!!                log_debug chegam ao log do ESMF, e com que severidade;
!!                log_error e log_report gravam mesmo com 'warning';
!!                log_debug_enabled só é verdadeiro com 'debug'
!!
!! O log do ESMF é um arquivo só (ESMF_LOGKIND_SINGLE), lido de volta no
!! fim. Cada mensagem leva o nível pedido no texto, para que se saiba de
!! qual leitura ela veio.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_log
  use ESMF,               only : ESMF_Initialize, ESMF_Finalize, ESMF_LogFlush, &
                                 ESMF_LOGKIND_SINGLE, ESMF_SUCCESS
  use coupler_config_mod, only : config_read, cfg_log_level
  use coupler_log_mod,    only : log_error, log_warning, log_info, log_debug, &
                                 log_debug_enabled, log_report, COMP_MED
  implicit none

  character(len=*), parameter :: NML = 'test_log.nml'
  character(len=*), parameter :: LOGFILE = 'test_log.ESMF_LogFile'
  integer :: nfailures, rc

  nfailures = 0
  call delete_file(LOGFILE)
  call ESMF_Initialize(defaultLogFileName=LOGFILE, logkindflag=ESMF_LOGKIND_SINGLE, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 2

  ! --- leitura -------------------------------------------------------------
  call outcome('padrao: log_level = info', trim(cfg_log_level) == 'info')
  call outcome('padrao: depuracao desligada', .not. log_debug_enabled())

  call read_level("log_level = 'DEBUG'", rc)
  call outcome('DEBUG: lido sem erro e em minusculas', rc == 0 .and. trim(cfg_log_level) == 'debug')
  call outcome('debug: depuracao ligada', log_debug_enabled())
  call write_all()

  call read_level("log_level = 'verbose'", rc)
  call outcome('verbose: erro fatal', rc == 2)
  call outcome('verbose: nivel anterior mantido', trim(cfg_log_level) == 'debug')

  call read_level("log_level = 'warning'", rc)
  call outcome('warning: lido sem erro', rc == 0 .and. trim(cfg_log_level) == 'warning')
  call outcome('warning: depuracao desligada', .not. log_debug_enabled())
  call write_all()

  call read_level("log_level = 'info'", rc)
  call outcome('info: lido sem erro', rc == 0 .and. trim(cfg_log_level) == 'info')
  call write_all()

  call read_level("write_fixdiag = .true.", rc)
  call outcome('write_fixdiag: aceita e sem efeito', rc == 0 .and. trim(cfg_log_level) == 'info')
  call outcome('write_fixdiag: depuracao continua desligada', .not. log_debug_enabled())

  ! --- gravação --------------------------------------------------------------
  call ESMF_LogFlush(rc=rc)
  call outcome('debug: grava aviso, informacao e depuracao', &
    count_lines('WARNING', 'MED: aviso com debug') == 1 .and. &
    count_lines('INFO', 'MED: informacao com debug') == 1 .and. &
    count_lines('INFO', 'MED: depuracao com debug') == 1)
  call outcome('warning: grava erro, aviso e relatorio, sem informacao', &
    count_lines('ERROR', 'MED: erro com warning') == 1 .and. &
    count_lines('WARNING', 'MED: aviso com warning') == 1 .and. &
    count_lines('INFO', 'CPL-REL: relatorio com warning') == 1 .and. &
    count_lines('', 'MED: informacao com warning') == 0 .and. &
    count_lines('', 'MED: depuracao com warning') == 0)
  call outcome('info: grava aviso e informacao, sem depuracao', &
    count_lines('WARNING', 'MED: aviso com info') == 1 .and. &
    count_lines('INFO', 'MED: informacao com info') == 1 .and. &
    count_lines('', 'MED: depuracao com info') == 0)

  call ESMF_Finalize(rc=rc)
  call delete_file(NML)

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Lê um nuopc.input só com &nuopc_driver e a linha dada.
  subroutine read_level(line, rc)
    character(len=*), intent(in)  :: line
    integer,          intent(out) :: rc
    integer :: u
    open(newunit=u, file=NML, status='replace', action='write')
    write(u, '(A)') '&nuopc_driver'
    write(u, '(2A)') '  ', line
    write(u, '(A)') '/'
    close(u)
    call config_read(rc, NML)
  end subroutine read_level

  !> Uma mensagem de cada nível, com o nível pedido no texto (o erro e a
  !! linha do relatório, só com 'warning', o nível mais restrito).
  subroutine write_all()
    if (trim(cfg_log_level) == 'warning') then
      call log_error(COMP_MED, 'erro com warning')
      call log_report('relatorio com warning')
    end if
    call log_warning(COMP_MED, 'aviso com '//trim(cfg_log_level))
    call log_info(COMP_MED, 'informacao com '//trim(cfg_log_level))
    call log_debug(COMP_MED, 'depuracao com '//trim(cfg_log_level))
  end subroutine write_all

  !> Linhas do log que terminam com o texto dado e, se severity não for
  !! vazio, trazem essa severidade.
  integer function count_lines(severity, text)
    character(len=*), intent(in) :: severity
    character(len=*), intent(in) :: text
    character(len=512) :: buf
    integer :: u, ios, n
    count_lines = 0
    open(newunit=u, file=LOGFILE, status='old', action='read', iostat=ios)
    if (ios /= 0) return
    do
      read(u, '(A)', iostat=ios) buf
      if (ios /= 0) exit
      n = len_trim(buf)
      if (n < len(text)) cycle
      if (buf(n-len(text)+1:n) /= text) cycle
      if (len(severity) > 0 .and. index(buf, ' '//severity//' ') == 0) cycle
      count_lines = count_lines + 1
    end do
    close(u)
  end function count_lines

  !> Apaga um arquivo, se existir.
  subroutine delete_file(path)
    character(len=*), intent(in) :: path
    integer :: u, ios
    open(newunit=u, file=path, status='old', iostat=ios)
    if (ios == 0) close(u, status='delete')
  end subroutine delete_file

  subroutine outcome(name, ok)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: ok
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', name
    else
      write(*, '(2A)') 'FALHOU  ', name
      nfailures = nfailures + 1
    end if
  end subroutine outcome

end program test_log
