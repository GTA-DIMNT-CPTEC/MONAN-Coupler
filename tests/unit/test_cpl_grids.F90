!> @file test_cpl_grids.F90
!! @brief Decomposição e fórmulas de centro e canto das malhas regulares.
!!
!! Confere, sem MPI e sem ESMF inicializado, as funções de cpl_grids_mod:
!!
!!   decomposicao  cpl_regdecomp na grade 360 x 180, com os casos do
!!                 comentário da rotina (16, 32, 64, 128 e 512 PETs, um
!!                 primo e 1 PET) e a grade 1440 x 720 do DOCN; colunas x
!!                 linhas = PETs sempre
!!   atm_med       centros de 0,5 a 359,5 graus em longitude e de -89,5 a
!!                 89,5 em latitude; cantos de 0 a 359 e de -90 a 90
!!   atm_cap       centros de -179,5 a 179,5 graus e de -89,5 a 89,5
!!   igualdade     as duas regras dão o mesmo centro, em graus, a menos de
!!                 180 graus na longitude, em todas as colunas e linhas
!!
!! Os valores esperados são exatos em binário (múltiplos de 0,5), por isso a
!! comparação é de igualdade.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_cpl_grids
  use ESMF,          only : ESMF_KIND_R8
  use cpl_grids_mod, only : cpl_regdecomp, centro_lon_leste0, centro_lat_leste0, &
                            canto_lon_leste0, canto_lat_leste0, centro_lon_oeste180, &
                            centro_lat_oeste180
  implicit none

  integer, parameter :: r8 = ESMF_KIND_R8
  integer :: nfalhas, i, j, n
  logical :: ok

  nfalhas = 0

  ! --- decomposição -------------------------------------------------------------
  call resultado('decomposicao: 16 PETs em 4 x 4',    all(cpl_regdecomp(16, 360, 180)  == [4, 4]))
  call resultado('decomposicao: 32 PETs em 8 x 4',    all(cpl_regdecomp(32, 360, 180)  == [8, 4]))
  call resultado('decomposicao: 64 PETs em 8 x 8',    all(cpl_regdecomp(64, 360, 180)  == [8, 8]))
  call resultado('decomposicao: 128 PETs em 16 x 8',  all(cpl_regdecomp(128, 360, 180) == [16, 8]))
  call resultado('decomposicao: 512 PETs em 32 x 16', all(cpl_regdecomp(512, 360, 180) == [32, 16]))
  call resultado('decomposicao: 17 PETs em 17 x 1',   all(cpl_regdecomp(17, 360, 180)  == [17, 1]))
  call resultado('decomposicao: 1 PET em 1 x 1',      all(cpl_regdecomp(1, 360, 180)   == [1, 1]))
  call resultado('decomposicao: 6 PETs em 3 x 2',     all(cpl_regdecomp(6, 360, 180)   == [3, 2]))
  ok = .true.
  do n = 1, 600
    ok = ok .and. product(cpl_regdecomp(n, 360, 180)) == n
    ok = ok .and. product(cpl_regdecomp(n, 1440, 720)) == n
  end do
  call resultado('decomposicao: colunas x linhas = PETs, de 1 a 600', ok)

  ! --- atm_med -----------------------------------------------------------------------
  call resultado('atm_med: centro da coluna 1 em 0,5',     centro_lon_leste0(1, 360) == 0.5_r8)
  call resultado('atm_med: centro da coluna 360 em 359,5', centro_lon_leste0(360, 360) == 359.5_r8)
  call resultado('atm_med: centro da linha 1 em -89,5',    centro_lat_leste0(1, 180) == -89.5_r8)
  call resultado('atm_med: centro da linha 180 em 89,5',   centro_lat_leste0(180, 180) == 89.5_r8)
  call resultado('atm_med: canto da coluna 1 em 0',        canto_lon_leste0(1, 360) == 0.0_r8)
  call resultado('atm_med: canto da coluna 360 em 359',    canto_lon_leste0(360, 360) == 359.0_r8)
  call resultado('atm_med: canto da linha 1 em -90',       canto_lat_leste0(1, 180) == -90.0_r8)
  call resultado('atm_med: canto da linha 181 em 90',      canto_lat_leste0(181, 180) == 90.0_r8)

  ! --- atm_cap -----------------------------------------------------------------------
  call resultado('atm_cap: centro da coluna 1 em -179,5',  centro_lon_oeste180(1, 360) == -179.5_r8)
  call resultado('atm_cap: centro da coluna 360 em 179,5', centro_lon_oeste180(360, 360) == 179.5_r8)
  call resultado('atm_cap: centro da linha 1 em -89,5',    centro_lat_oeste180(1, 180) == -89.5_r8)
  call resultado('atm_cap: centro da linha 180 em 89,5',   centro_lat_oeste180(180, 180) == 89.5_r8)

  ! --- igualdade das duas regras na grade 360 x 180 ----------------------------------
  ok = .true.
  do i = 1, 360
    ok = ok .and. centro_lon_oeste180(i, 360) + 180.0_r8 == centro_lon_leste0(i, 360)
  end do
  do j = 1, 180
    ok = ok .and. centro_lat_oeste180(j, 180) == centro_lat_leste0(j, 180)
  end do
  call resultado('igualdade: as duas regras dao os mesmos centros', ok)

  if (nfalhas == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfalhas, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  subroutine resultado(nome, ok)
    character(len=*), intent(in) :: nome
    logical,          intent(in) :: ok
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', nome
    else
      write(*, '(2A)') 'FALHOU  ', nome
      nfalhas = nfalhas + 1
    end if
  end subroutine resultado

end program test_cpl_grids
