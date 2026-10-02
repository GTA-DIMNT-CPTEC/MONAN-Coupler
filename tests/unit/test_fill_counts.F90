!> @file test_fill_counts.F90
!! @brief Contagem dos pontos completados por vizinhança (relatório de acoplamento).
!!
!! Confere, sem MPI, a contagem que alimenta as linhas "completar" do
!! relatório de acoplamento:
!!
!!   neighbor_fill   n_invalid conta os pontos fora da faixa antes do
!!                   preenchimento (NaN conta; com overflow_to_fill, o que
!!                   passa de vmax vira vfill e não conta); n_left, os que
!!                   ficaram com o valor fixo; pedir as contagens não muda
!!                   nenhum valor preenchido (comparação bit a bit), nem no
!!                   caminho normal nem quando a fração inválida passa do
!!                   limiar e a difusão é pulada
!!   SST             a contagem de neighbor_fill com as opções da SST é a
!!                   que fill_sst_gaps (med_ocean, até a R-FASE11-13, tag
!!                   fase11-13-validada) fazia à parte, copiada aqui; desde
!!                   a R-FASE11-14 a rota ocn2atm_sst usa a de neighbor_fill
!!   record_fill        acumula aplicações, pontos fora da faixa e pontos
!!                   com valor fixo
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_fill_counts
  use ESMF,              only : ESMF_KIND_R8, ESMF_KIND_I8
  use, intrinsic :: ieee_arithmetic, only : ieee_value, ieee_quiet_nan
  use regrid_base_mod,   only : regrid_fill_t, neighbor_fill
  use med_cap_types_mod, only : med_fill_count_t
  use med_diag_mod,      only : record_fill
  implicit none

  integer, parameter :: R8 = ESMF_KIND_R8
  type(regrid_fill_t), parameter :: RANGE01 = regrid_fill_t(enabled=.true., vmin=0.0_R8, &
                                                            vmax=1.0_R8, vfill=0.0_R8)
  type(regrid_fill_t), parameter :: SST = regrid_fill_t(enabled=.true., vmin=270.0_R8,   &
    vmax=310.0_R8, vfill=271.35_R8, max_iter=40, skip_fraction=1.0_R8, overflow_to_fill=.true.)
  real(R8) :: a(6,5), b(6,5), c(3,3), d(3,3), e(40,30)
  integer :: nfailures, n_inv, n_fix, n_before, i, j
  type(med_fill_count_t) :: cont

  nfailures = 0

  ! --- caminho normal: 4 pontos inválidos (2 acima, 1 abaixo, 1 NaN) -------
  call field(a)
  b = a
  call neighbor_fill(a, RANGE01, n_left=n_fix, n_invalid=n_inv)
  call neighbor_fill(b, RANGE01)
  call outcome('normal: 4 pontos fora da faixa', n_inv == 4)
  call outcome('normal: nenhum com valor fixo', n_fix == 0)
  call outcome('normal: contagem nao muda os valores', equal(a, b))

  ! --- overflow_to_fill: o que passa de vmax vira vfill e não conta ---------
  a = 280.0_R8
  a(2,2) = 350.0_R8          ! acima de vmax: vira 271,35, válido
  a(4,3) = 250.0_R8          ! abaixo de vmin: inválido
  b = a
  call neighbor_fill(a, SST, n_left=n_fix, n_invalid=n_inv)
  call neighbor_fill(b, SST)
  call outcome('overflow: so o ponto abaixo de vmin conta', n_inv == 1 .and. n_fix == 0)
  call outcome('overflow: contagem nao muda os valores', equal(a, b))

  ! --- difusão pulada: fração inválida acima de skip_fraction (0,25) -------
  c = 5.0_R8
  c(1,1) = 0.5_R8; c(2,2) = 0.5_R8; c(3,3) = 0.5_R8
  d = c
  call neighbor_fill(c, RANGE01, n_left=n_fix, n_invalid=n_inv)
  call neighbor_fill(d, RANGE01)
  call outcome('limiar: 6 fora da faixa, 6 com valor fixo', n_inv == 6 .and. n_fix == 6)
  call outcome('limiar: contagem nao muda os valores', equal(c, d))

  ! --- SST: contagem de antes (fill_sst_gaps) e de neighbor_fill -----------
  do j = 1, size(e, 2)
    do i = 1, size(e, 1)
      e(i,j) = 285.0_R8 + 12.0_R8 * sin(0.37_R8 * i) * cos(0.21_R8 * j)
      if (mod(7*i + 3*j, 11) == 0) e(i,j) = 0.0_R8
      if (mod(i + 2*j, 13) == 0)   e(i,j) = 315.0_R8
      if (mod(5*i + j, 29) == 0)   e(i,j) = ieee_value(1.0_R8, ieee_quiet_nan)
    end do
  end do
  n_before = count(.not. (e >= SST%vmin .and. e <= SST%vmax) .and. .not. (e > SST%vmax))
  call neighbor_fill(e, SST, n_left=n_fix, n_invalid=n_inv)
  call outcome('SST: n_invalid igual a contagem de fill_sst_gaps', &
                 n_inv == n_before .and. n_before > 0)

  ! --- acumulação ---------------------------------------------------------
  call record_fill(cont, 4, 0)
  call record_fill(cont, 6, 6)
  call outcome('registra_completa: 2 aplicacoes, 10 fora da faixa, 6 fixos', &
    cont%n_applied == 2_ESMF_KIND_I8 .and. cont%n_invalid_pts == 10_ESMF_KIND_I8 .and. &
    cont%n_fixed_pts == 6_ESMF_KIND_I8)

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Campo entre 0 e 1 com quatro pontos inválidos espalhados.
  subroutine field(x)
    real(R8), intent(out) :: x(:,:)
    integer :: i, j
    do j = 1, size(x, 2)
      do i = 1, size(x, 1)
        x(i, j) = real(i + 10*j, R8) / 100.0_R8
      end do
    end do
    x(2,2) = 1.5_R8
    x(5,1) = 3.0_R8
    x(3,4) = -1.0_R8
    x(6,5) = ieee_value(1.0_R8, ieee_quiet_nan)
  end subroutine field

  !> Igualdade bit a bit de dois campos.
  logical function equal(x, y)
    real(R8), intent(in) :: x(:,:), y(:,:)
    equal = all(transfer(x, 1_ESMF_KIND_I8, size(x)) == transfer(y, 1_ESMF_KIND_I8, size(y)))
  end function equal

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

end program test_fill_counts
