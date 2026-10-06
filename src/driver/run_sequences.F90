!> @file run_sequences.F90
!! @brief Sequências de execução de um passo de acoplamento, escritas como texto.
!!
!! Cada sequência tem um nome, o título que vai para o registro e o texto:
!! as linhas que o NUOPC executa a cada passo, na ordem, separadas por ';'.
!! Uma linha é um componente ('MPAS', 'OCN', 'ICE', 'MED'), que avança um
!! passo, ou um conector ('MED -> OCN'), que leva os campos de um para o
!! outro. O driver (esm.F90) escolhe a sequência pelo nome
!! (run_sequence_name), põe antes a linha '@<dt_coupling>' e depois a linha
!! '@', e a entrega ao NUOPC. Os rótulos são os do driver.
!!
!! No modo concorrente, MPAS, OCN e ICE aparecem em linhas consecutivas, sem
!! conector entre eles, e por isso avançam ao mesmo tempo em PETs
!! disjuntos; o mediador entrega no início do passo o que calculou no fim do
!! passo anterior. Na sequência seq_mom6_ice_repro, a ordem imita esse fluxo
!! de dados, mas executa um componente de cada vez; o resultado é
!! comparável bit a bit ao concorrente. Na seq_mom6_ice, a linha
!! 'MED -> ICE' entre OCN e ICE é intencional: ela impede que os dois
!! avancem juntos.
!!
!! Para experimentar outra ordem sem recompilar, a chave run_sequence_file
!! (&nuopc_driver) dá um arquivo com a sequência no formato do NUOPC, sob o
!! rótulo RUN_SEQUENCE_LABEL (run_sequence_from_file).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module run_sequences_mod

  use ESMF,  only : ESMF_Config, ESMF_ConfigCreate, ESMF_ConfigLoadFile, ESMF_ConfigDestroy, &
                    ESMF_SUCCESS, ESMF_FAILURE
  use NUOPC, only : NUOPC_FreeFormat, NUOPC_FreeFormatCreate

  implicit none
  private

  public :: run_sequence_t, RUN_SEQUENCES, RUN_SEQUENCE_LINE_LEN, MAX_RUN_SEQUENCE_LINES
  public :: RUN_SEQUENCE_LABEL
  public :: run_sequence_name, run_sequence_index, run_sequence_lines, run_sequence_from_file

  integer, parameter :: RUN_SEQUENCE_LINE_LEN  = 24   !< comprimento de uma linha
  integer, parameter :: MAX_RUN_SEQUENCE_LINES = 10   !< linhas de uma sequência, no máximo

  !> Rótulo da sequência no arquivo dado por run_sequence_file.
  character(len=*), parameter :: RUN_SEQUENCE_LABEL = 'runSeq::'

  !> Sequência de execução: nome, título no registro e linhas separadas por ';'.
  type :: run_sequence_t
    character(len=24)  :: name
    character(len=48)  :: title
    character(len=200) :: text
  end type run_sequence_t

  ! "MOM6", nos nomes e títulos, quer dizer use_med_to_mpas=.true.: o
  ! contorno da atmosfera vem do mediador. Sem ele (DOCN), vem direto do
  ! oceano pelo conector OCN -> MPAS.
  type(run_sequence_t), parameter :: RUN_SEQUENCES(*) = [                                          &
    run_sequence_t('conc_mom6_ice', 'Fase 2 CONCORRENTE + ICE (SIS2)',                             &
      'MED -> MPAS; MED -> OCN; MED -> ICE; MPAS; OCN; ICE; '//                                    &
      'MPAS -> MED; OCN -> MED; ICE -> MED; MED'),                                                 &
    run_sequence_t('conc_mom6', 'Fase 2 CONCORRENTE (MED->MPAS)',                                  &
      'MED -> MPAS; MED -> OCN; MPAS; OCN; MPAS -> MED; OCN -> MED; MED'),                         &
    run_sequence_t('conc_docn', 'Fase 1 CONCORRENTE (OCN->MPAS)',                                  &
      'OCN -> MPAS; MED -> OCN; MPAS; OCN; MPAS -> MED; OCN -> MED; MED'),                         &
    run_sequence_t('seq_mom6_ice_repro', 'Fase 2 SEQUENCIAL REPRODUTIVEL + ICE (SIS2)',            &
      'MED -> MPAS; MPAS; MED -> OCN; OCN; MED -> ICE; ICE; '//                                    &
      'MPAS -> MED; OCN -> MED; ICE -> MED; MED'),                                                 &
    run_sequence_t('seq_mom6_ice', 'Fase 2 SEQUENCIAL + ICE (SIS2)',                               &
      'OCN -> MED; ICE -> MED; MPAS -> MED; MED; '//                                               &
      'MED -> MPAS; MPAS; MED -> OCN; OCN; MED -> ICE; ICE'),                                      &
    run_sequence_t('seq_mom6', 'Fase 2 (MED->MPAS)',                                               &
      'OCN -> MED; MPAS -> MED; MED; MED -> MPAS; MPAS; MED -> OCN; OCN'),                         &
    run_sequence_t('seq_docn', 'Fase 1 (OCN->MPAS direto)',                                        &
      'OCN -> MPAS; MPAS; MPAS -> MED; OCN -> MED; MED; MED -> OCN; OCN') ]

contains

  !> @brief Nome da sequência para a configuração.
  !!
  !! @param[in] concurrent  coupling_mode='concurrent'
  !! @param[in] mom6        use_med_to_mpas (contorno da atmosfera pelo mediador)
  !! @param[in] ice         SIS2 dinâmico (use_sis2_dynamic e use_med_to_mpas)
  !! @param[in] seq_repro   ordem reprodutível no modo sequencial
  pure function run_sequence_name(concurrent, mom6, ice, seq_repro) result(name)
    logical, intent(in) :: concurrent, mom6, ice, seq_repro
    character(len=24) :: name

    if (concurrent .and. ice) then
      name = 'conc_mom6_ice'
    else if (concurrent .and. mom6) then
      name = 'conc_mom6'
    else if (concurrent) then
      name = 'conc_docn'
    else if (ice .and. seq_repro) then
      name = 'seq_mom6_ice_repro'
    else if (ice) then
      name = 'seq_mom6_ice'
    else if (mom6) then
      name = 'seq_mom6'
    else
      name = 'seq_docn'
    end if
  end function run_sequence_name

  !> @brief Posição da sequência em RUN_SEQUENCES (0 se não existe).
  !!
  !! @param[in] name  nome da sequência
  pure integer function run_sequence_index(name) result(k)
    character(len=*), intent(in) :: name
    do k = 1, size(RUN_SEQUENCES)
      if (trim(RUN_SEQUENCES(k)%name) == trim(name)) return
    end do
    k = 0
  end function run_sequence_index

  !> @brief Separa o texto de uma sequência em linhas, sem os brancos das pontas.
  !!
  !! @param[in]  text   linhas separadas por ';'
  !! @param[out] lines  linhas, na ordem
  !! @param[out] n      número de linhas; -1 se passa de MAX_RUN_SEQUENCE_LINES
  !!                    ou se uma linha passa de RUN_SEQUENCE_LINE_LEN
  pure subroutine run_sequence_lines(text, lines, n)
    character(len=*),                     intent(in)  :: text
    character(len=RUN_SEQUENCE_LINE_LEN), intent(out) :: lines(MAX_RUN_SEQUENCE_LINES)
    integer,                              intent(out) :: n
    integer :: start, p, last

    lines = ''
    n = 0
    start = 1
    last = len_trim(text)
    do while (start <= last)
      p = index(text(start:last), ';')
      if (p == 0) then
        p = last + 1
      else
        p = start + p - 1
      end if
      if (n == MAX_RUN_SEQUENCE_LINES .or. len_trim(adjustl(text(start:p-1))) > RUN_SEQUENCE_LINE_LEN) then
        n = -1
        return
      end if
      n = n + 1
      lines(n) = adjustl(text(start:p-1))
      start = p + 1
    end do
  end subroutine run_sequence_lines

  !> @brief Lê de um arquivo a sequência de execução, sob o rótulo
  !! RUN_SEQUENCE_LABEL, no formato do NUOPC (linhas '@<período>', os
  !! componentes e conectores, e '@'). O período deve ser dt_coupling.
  !!
  !! @param[in]  path  arquivo (chave run_sequence_file)
  !! @param[out] ff    sequência, para NUOPC_DriverIngestRunSequence
  !! @param[out] rc    ESMF_SUCCESS ou ESMF_FAILURE
  subroutine run_sequence_from_file(path, ff, rc)
    character(len=*),       intent(in)  :: path
    type(NUOPC_FreeFormat), intent(out) :: ff
    integer,                intent(out) :: rc
    type(ESMF_Config) :: config
    integer :: lrc

    config = ESMF_ConfigCreate(rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_ConfigLoadFile(config, trim(path), rc=rc)
    if (rc == ESMF_SUCCESS) ff = NUOPC_FreeFormatCreate(config, label=RUN_SEQUENCE_LABEL, rc=rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_FAILURE
    call ESMF_ConfigDestroy(config, rc=lrc)
  end subroutine run_sequence_from_file

end module run_sequences_mod
