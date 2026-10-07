!> @file test_atm_grid.F90
!! @brief Testes com valor esperado da passagem das células MPAS para a
!! grade regular 360 x 180 do cap atmosférico.
!!
!! O teste de regressão tests/atmgrid compara duas versões de mpas_export
!! e responde "o resultado mudou?". Este confere, sem MPI, as duas etapas
!! de cálculo de map_cells_to_regular_grid (mpas_cell_binning_mod) contra
!! valores esperados calculados à parte:
!!
!!   bin_cells_local  cada célula cai na caixa de 1 grau certa: longitude
!!                    trazida para [0°, 360°), latitude presa às linhas 1 e
!!                    180 nos polos; soma e contagem por caixa; só as n
!!                    primeiras células contam
!!   fill_empty_bins  uma caixa sem célula recebe a média dos vizinhos
!!                    preenchidos (8 vizinhos, longitude periódica, latitude
!!                    presa nas bordas); a caixa preenchida passa a servir de
!!                    vizinha na mesma passada, na ordem dos laços (linha a
!!                    linha, de oeste para leste)
!!
!! Os valores esperados de fill_empty_bins foram calculados em aritmética
!! exata (frações do Python) para o campo f(i, j) = i + 1000 j, com quatro
!! caixas vazias:
!!   (10, 50)   350069/7   vizinha (11, 50) ainda vazia, não conta
!!   (11, 50)   2800615/56 usa o valor recém-calculado de (10, 50)
!!   (1, 90)    90136      usa a coluna 360 (longitude periódica)
!!   (100, 180) 1257700/7  na borda norte, a linha 181 vira a própria linha
!!                         180: os vizinhos (99, 180) e (101, 180) contam duas
!!                         vezes (comportamento atual, registrado aqui)
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_atm_grid
  use ESMF, only: ESMF_KIND_R8
  use coupler_constants_mod, only: ATM_NX, ATM_NY
  use mpas_atm_types_mod, only: MPAS_RKIND
  use mpas_cell_binning_mod, only: bin_cells_local, fill_empty_bins
  implicit none

  integer, parameter :: R8 = ESMF_KIND_R8
  real(R8), parameter :: TOL = 1.0e-12_R8
  integer, parameter :: NCEL = 7
  real(R8), parameter :: DEGREE = acos(-1.0_R8) / 180.0_R8
  integer :: nfailures
  real(MPAS_RKIND) :: lon(NCEL), lat(NCEL), val(NCEL)
  real(R8), allocatable :: total(:,:), cont(:,:), buf(:,:)
  integer :: i, j, n_pre, n_pos

  nfailures = 0
  allocate(total(ATM_NX, ATM_NY), cont(ATM_NX, ATM_NY), buf(ATM_NX, ATM_NY))

  ! --- bin_cells_local -----------------------------------------------------
  ! células (lon°, lat°, valor); a 7a fica fora porque n = 6
  lon = [0.5_R8, 0.7_R8, -0.5_R8, 180.25_R8, 45.5_R8, 45.5_R8, 10.5_R8] * DEGREE
  lat = [0.5_R8, 0.2_R8, 10.5_R8, -89.75_R8, 90.0_R8, -90.0_R8, 10.5_R8] * DEGREE
  val = [2.0_R8, 4.0_R8, 7.0_R8, 1.0_R8, 3.0_R8, 5.0_R8, 100.0_R8]
  call bin_cells_local(NCEL - 1, lon, lat, val, total, cont)
  call check('bin: duas células na caixa (1, 91), soma', total(1, 91), 6.0_R8)
  call check('bin: duas células na caixa (1, 91), contagem', cont(1, 91), 2.0_R8)
  call check('bin: longitude -0,5° vai para a caixa 360', total(360, 101), 7.0_R8)
  call check('bin: longitude 180,25°, latitude -89,75°', total(181, 1), 1.0_R8)
  call check('bin: latitude 90° presa na linha 180', total(46, 180), 3.0_R8)
  call check('bin: latitude -90° na linha 1', total(46, 1), 5.0_R8)
  call check('bin: célula além de n não conta', cont(11, 101), 0.0_R8)
  call check('bin: contagem total igual a n', sum(cont), 6.0_R8)
  call check('bin: soma total', sum(total), 22.0_R8)

  ! --- fill_empty_bins -----------------------------------------------------
  call field_with_holes(buf, cont)
  call fill_empty_bins(1, buf, cont, n_pre, n_pos)
  call check('fill: caixas vazias antes', real(n_pre, R8), 4.0_R8)
  call check('fill: caixas vazias depois', real(n_pos, R8), 0.0_R8)
  call check('fill: (10, 50) média de 7 vizinhos', buf(10, 50), 350069.0_R8 / 7.0_R8)
  call check('fill: (11, 50) usa (10, 50) já preenchida', buf(11, 50), 2800615.0_R8 / 56.0_R8)
  call check('fill: (1, 90) usa a coluna 360', buf(1, 90), 90136.0_R8)
  call check('fill: (100, 180) borda norte', buf(100, 180), 1257700.0_R8 / 7.0_R8)
  call check('fill: caixa preenchida marca contagem 0,5', cont(10, 50), 0.5_R8)
  call check('fill: caixa com célula não muda', buf(200, 60), 200.0_R8 + 60000.0_R8)

  call field_with_holes(buf, cont)
  call fill_empty_bins(0, buf, cont, n_pre, n_pos)
  call check('fill: zero passadas, nada preenchido', real(n_pos, R8), 4.0_R8)

  buf  = 0.0_R8
  cont = 0.0_R8
  call fill_empty_bins(12, buf, cont, n_pre, n_pos)
  call check('fill: grade toda vazia continua vazia', real(n_pos, R8), real(ATM_NX * ATM_NY, R8))
  call check('fill: grade toda vazia continua zero', maxval(abs(buf)), 0.0_R8)

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Campo f(i, j) = i + 1000 j com contagem 1, exceto em quatro caixas vazias.
  subroutine field_with_holes(b, c)
    real(R8), intent(out) :: b(:,:)
    real(R8), intent(out) :: c(:,:)

    do j = 1, ATM_NY
      do i = 1, ATM_NX
        b(i, j) = real(i, R8) + 1000.0_R8 * real(j, R8)
      end do
    end do
    c = 1.0_R8
    b(10, 50)  = 0.0_R8; c(10, 50)  = 0.0_R8
    b(11, 50)  = 0.0_R8; c(11, 50)  = 0.0_R8
    b(1, 90)   = 0.0_R8; c(1, 90)   = 0.0_R8
    b(100, 180) = 0.0_R8; c(100, 180) = 0.0_R8
  end subroutine field_with_holes

  !> Compara obtido com esperado, com tolerância relativa TOL (absoluta
  !! quando o esperado é menor que 1), e imprime PASSOU ou FALHOU.
  subroutine check(name, obtained, expected)
    character(len=*), intent(in) :: name
    real(R8),         intent(in) :: obtained
    real(R8),         intent(in) :: expected
    logical :: ok

    ok = abs(obtained - expected) <= TOL * max(abs(expected), 1.0_R8)
    if (ok) then
      write(*, '(A, A)') 'PASSOU  ', name
    else
      write(*, '(A, A, A, ES24.16, A, ES24.16)') 'FALHOU  ', name, ': obtido ', obtained, &
        ', esperado ', expected
      nfailures = nfailures + 1
    end if
  end subroutine check

end program test_atm_grid
