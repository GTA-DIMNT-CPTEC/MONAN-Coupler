!> @file test_driver_layout.F90
!! @brief Divisão de PETs por posição e linhas de layout do driver (driver_layout_mod).
!!
!! Confere, sem MPI e sem ESMF, que a divisão por blocos (split_blocks) e as
!! linhas de layout do log (layout_split_line, layout_shared_line,
!! idle_pets_line) são as mesmas do driver de antes da R-FASE13-26, cuja
!! rotina split_pets e cujo texto de log_layout estão copiados aqui sem
!! mudança de regra. Casos: 1 a 200 PETs; contagens pedidas zero
!! (automáticas) ou fixas para ATM, OCN e ICE; gelo ligado e desligado;
!! execução concorrente e sequencial. Para cada caso: a validade da divisão
!! e, nos casos válidos, os tamanhos dos blocos e o texto das linhas. Nos
!! inválidos (contagens fixas que passam do total), os tamanhos que a
!! mensagem de erro mostra podem diferir dos de antes, porque a divisão
!! inteira de um resto negativo arredonda de outro modo; a divisão é
!! recusada do mesmo jeito.
!!
!! Saída: uma linha PASSOU/FALHOU por grupo de casos e, no fim, "TODOS OS
!! TESTES PASSARAM" ou o número de falhas; termina com código 1 se algum
!! falhar.
program test_driver_layout
  use coupler_utils_mod, only : int_to_str
  use driver_layout_mod, only : POSITIONS, N_POSITIONS, position_index, split_blocks, &
                                layout_split_line, layout_shared_line, idle_pets_line
  implicit none

  integer, parameter :: FIXED(4) = [0, 1, 7, 64]
  integer :: nfailures, ncases, ndiff_counts, ndiff_lines, ndiff_ok, ninvalid
  integer :: p, ia, io, ii, ie, ice_flag
  integer :: nAtm, nOcn, nIce, counts(N_POSITIONS), requested(N_POSITIONS)
  logical :: use_ice, ok_old, ok_new, active(N_POSITIONS)
  character(len=10) :: exec
  integer :: k_atm, k_med, k_ocn, k_ice

  nfailures = 0
  ncases = 0; ndiff_counts = 0; ndiff_lines = 0; ndiff_ok = 0; ninvalid = 0
  k_atm = position_index('ATM'); k_med = position_index('MED')
  k_ocn = position_index('OCN'); k_ice = position_index('ICE')

  do p = 1, 200
    do ice_flag = 0, 1
      use_ice = ice_flag == 1
      do ia = 1, size(FIXED)
        do io = 1, size(FIXED)
          do ii = 1, size(FIXED)
            call old_split_pets(p, use_ice, FIXED(ia), FIXED(io), FIXED(ii), nAtm, nOcn, nIce, ok_old)
            requested = 0
            requested(k_atm) = FIXED(ia); requested(k_ocn) = FIXED(io); requested(k_ice) = FIXED(ii)
            active = .true.
            active(k_ice) = use_ice
            call split_blocks(p, requested, active, counts, ok_new)
            ncases = ncases + 1
            if (ok_old .neqv. ok_new) ndiff_ok = ndiff_ok + 1
            if (.not. ok_old) ninvalid = ninvalid + 1
            if (ok_old .and. (counts(k_atm) /= nAtm .or. counts(k_ocn) /= nOcn .or. &
                counts(k_ice) /= nIce .or. counts(k_med) /= 0)) then
              ndiff_counts = ndiff_counts + 1
              if (ndiff_counts <= 5) write(*,'(A,6I5,L2,3I5,L2)') '  divisao: ', p, ice_flag, &
                FIXED(ia), FIXED(io), FIXED(ii), nAtm, ok_old, counts(k_atm), counts(k_ocn), &
                counts(k_ice), ok_new
            end if
            if (.not. ok_old) cycle
            do ie = 1, 2
              exec = merge('CONCURRENT', 'SEQUENTIAL', ie == 1)
              if (layout_split_line(trim(exec), counts, active) /= &
                  old_split_line(trim(exec), p, nAtm, nOcn, use_ice)) then
                ndiff_lines = ndiff_lines + 1
                if (ndiff_lines <= 5) write(*,'(2A)') '  linha: ', layout_split_line(trim(exec), counts, active)
              end if
              if (ie == 2) then
                if (idle_pets_line(p, counts, active) /= old_idle_line(p, nAtm, nOcn, nIce, use_ice)) then
                  ndiff_lines = ndiff_lines + 1
                  if (ndiff_lines <= 5) write(*,'(2A)') '  parados: ', idle_pets_line(p, counts, active)
                end if
              end if
            end do
          end do
        end do
      end do
    end do
  end do
  call outcome('validade da divisao igual a de split_pets em '//int_to_str(ncases)//' casos', &
               ndiff_ok == 0)
  call outcome('blocos iguais aos de split_pets nos '//int_to_str(ncases - ninvalid)// &
               ' casos validos', ndiff_counts == 0)
  call outcome('linhas SPLIT e de PETs parados iguais as de log_layout', ndiff_lines == 0)

  call outcome('linha SHARED com gelo', layout_shared_line('CONCURRENT', &
    [character(len=4) :: 'MPAS', 'MED', 'OCN', 'ICE']) == &
    'layout SHARED (execucao CONCURRENT): MPAS, MED, OCN e ICE em todos os PETs')
  call outcome('linha SHARED sem gelo', layout_shared_line('SEQUENTIAL', &
    [character(len=4) :: 'MPAS', 'MED', 'OCN']) == &
    'layout SHARED (execucao SEQUENTIAL): MPAS, MED e OCN em todos os PETs')
  call outcome('posicoes na ordem de registro de antes (ATM, MED, OCN, ICE)', &
    k_atm == 1 .and. k_med == 2 .and. k_ocn == 3 .and. k_ice == 4 .and. &
    .not. POSITIONS(k_med)%own_block)

  if (nfailures == 0) then
    write(*,'(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*,'(I0,A)') nfailures, ' teste(s) falharam'
    error stop 1
  end if

contains

  !> @brief Cópia da regra de split_pets (esm.F90) de antes da R-FASE13-26,
  !! sem o registro do erro: ok falso onde ela devolvia ESMF_FAILURE.
  subroutine old_split_pets(petCount, use_ice, atm_count, ocn_count, ice_count, nAtm, nOcn, nIce, ok)
    integer, intent(in)  :: petCount, atm_count, ocn_count, ice_count
    logical, intent(in)  :: use_ice
    integer, intent(out) :: nAtm, nOcn, nIce
    logical, intent(out) :: ok

    nAtm = atm_count
    nOcn = ocn_count
    nIce = merge(ice_count, 0, use_ice)

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

    ok = .not. (nAtm < 1 .or. nOcn < 1 .or. (use_ice .and. nIce < 1) .or. &
                nAtm + nOcn + nIce /= petCount)
  end subroutine old_split_pets

  !> @brief Linha SPLIT de log_layout (esm.F90) de antes da R-FASE13-26.
  function old_split_line(exec, petCount, nAtm, nOcn, use_ice) result(msg)
    character(len=*), intent(in) :: exec
    integer,          intent(in) :: petCount, nAtm, nOcn
    logical,          intent(in) :: use_ice
    character(len=:), allocatable :: msg

    msg = 'layout SPLIT (execucao '//exec//'): ATM=PET[0..'//int_to_str(nAtm-1)// &
          '] OCN=PET['//int_to_str(nAtm)//'..'//int_to_str(nAtm+nOcn-1)//']'
    if (use_ice) then
      msg = msg//' ICE=PET['//int_to_str(nAtm+nOcn)//'..'//int_to_str(petCount-1)// &
            '] MED=todos'
    else
      msg = msg//' MED=todos (ICE desativado)'
    end if
  end function old_split_line

  !> @brief Linha de PETs parados de log_layout de antes da R-FASE13-26.
  function old_idle_line(petCount, nAtm, nOcn, nIce, use_ice) result(msg)
    integer, intent(in) :: petCount, nAtm, nOcn, nIce
    logical, intent(in) :: use_ice
    character(len=:), allocatable :: msg

    msg = 'sequential+split: PETs parados: '//int_to_str(petCount-nAtm)// &
          ' durante o ATM, '//int_to_str(petCount-nOcn)//' durante o OCN'
    if (use_ice) msg = msg//', '//int_to_str(petCount-nIce)//' durante o ICE'
    msg = msg//' (de '//int_to_str(petCount)//').'
  end function old_idle_line

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

end program test_driver_layout
