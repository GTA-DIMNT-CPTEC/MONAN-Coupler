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
!!   indices       as funções de índice e de longitude dão, bit a bit, o
!!                 mesmo resultado que as expressões que substituíram,
!!                 escritas aqui como estavam nas rotinas (com o passo 1 como
!!                 constante, como no cap atmosférico), num conjunto de
!!                 coordenadas que inclui os múltiplos exatos do passo e os
!!                 seus vizinhos imediatos, valores negativos, -0 e valores
!!                 fora de [-360, 360]
!!   centros_gelo  os centros que check_ice_geography calculava são, bit a
!!                 bit, os de center_lon_east0 e center_lat_east0
!!
!! Os valores esperados são exatos em binário (múltiplos de 0,5), por isso a
!! comparação é de igualdade.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_cpl_grids
  use ESMF,          only : ESMF_KIND_R8
  use cpl_grids_mod, only : cpl_regdecomp, center_lon_east0, center_lat_east0, &
                            corner_lon_east0, corner_lat_east0, center_lon_west180, &
                            center_lat_west180
  use cpl_grids_mod, only : index_trunc, index_round, lon_0to360_floor, &
                            lon_m180to180_floor, lon_0to360_loop, lon_m180to180_loop
  use, intrinsic :: ieee_arithmetic, only : ieee_next_after
  use, intrinsic :: iso_fortran_env, only : int64
  implicit none

  integer, parameter :: r8 = ESMF_KIND_R8
  real(r8), parameter :: ONE = 1.0_r8  !< passo constante, como DLON e DLAT no cap
  integer :: nfailures, i, j, n
  logical :: ok

  nfailures = 0

  ! --- decomposição -------------------------------------------------------------
  call outcome('decomposicao: 16 PETs em 4 x 4',    all(cpl_regdecomp(16, 360, 180)  == [4, 4]))
  call outcome('decomposicao: 32 PETs em 8 x 4',    all(cpl_regdecomp(32, 360, 180)  == [8, 4]))
  call outcome('decomposicao: 64 PETs em 8 x 8',    all(cpl_regdecomp(64, 360, 180)  == [8, 8]))
  call outcome('decomposicao: 128 PETs em 16 x 8',  all(cpl_regdecomp(128, 360, 180) == [16, 8]))
  call outcome('decomposicao: 512 PETs em 32 x 16', all(cpl_regdecomp(512, 360, 180) == [32, 16]))
  call outcome('decomposicao: 17 PETs em 17 x 1',   all(cpl_regdecomp(17, 360, 180)  == [17, 1]))
  call outcome('decomposicao: 1 PET em 1 x 1',      all(cpl_regdecomp(1, 360, 180)   == [1, 1]))
  call outcome('decomposicao: 6 PETs em 3 x 2',     all(cpl_regdecomp(6, 360, 180)   == [3, 2]))
  ok = .true.
  do n = 1, 600
    ok = ok .and. product(cpl_regdecomp(n, 360, 180)) == n
    ok = ok .and. product(cpl_regdecomp(n, 1440, 720)) == n
  end do
  call outcome('decomposicao: colunas x linhas = PETs, de 1 a 600', ok)

  ! --- atm_med -----------------------------------------------------------------------
  call outcome('atm_med: centro da coluna 1 em 0,5',     center_lon_east0(1, 360) == 0.5_r8)
  call outcome('atm_med: centro da coluna 360 em 359,5', center_lon_east0(360, 360) == 359.5_r8)
  call outcome('atm_med: centro da linha 1 em -89,5',    center_lat_east0(1, 180) == -89.5_r8)
  call outcome('atm_med: centro da linha 180 em 89,5',   center_lat_east0(180, 180) == 89.5_r8)
  call outcome('atm_med: canto da coluna 1 em 0',        corner_lon_east0(1, 360) == 0.0_r8)
  call outcome('atm_med: canto da coluna 360 em 359',    corner_lon_east0(360, 360) == 359.0_r8)
  call outcome('atm_med: canto da linha 1 em -90',       corner_lat_east0(1, 180) == -90.0_r8)
  call outcome('atm_med: canto da linha 181 em 90',      corner_lat_east0(181, 180) == 90.0_r8)

  ! --- atm_cap -----------------------------------------------------------------------
  call outcome('atm_cap: centro da coluna 1 em -179,5',  center_lon_west180(1, 360) == -179.5_r8)
  call outcome('atm_cap: centro da coluna 360 em 179,5', center_lon_west180(360, 360) == 179.5_r8)
  call outcome('atm_cap: centro da linha 1 em -89,5',    center_lat_west180(1, 180) == -89.5_r8)
  call outcome('atm_cap: centro da linha 180 em 89,5',   center_lat_west180(180, 180) == 89.5_r8)

  ! --- igualdade das duas regras na grade 360 x 180 ----------------------------------
  ok = .true.
  do i = 1, 360
    ok = ok .and. center_lon_west180(i, 360) + 180.0_r8 == center_lon_east0(i, 360)
  end do
  do j = 1, 180
    ok = ok .and. center_lat_west180(j, 180) == center_lat_east0(j, 180)
  end do
  call outcome('igualdade: as duas regras dao os mesmos centros', ok)

  call check_indices()
  call check_ice_centers()

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Coordenadas de teste: passos de 0,001 entre -400 e 400, os múltiplos de
  !! 0,25 entre -720 e 720 e os seus vizinhos imediatos, -0, e alguns
  !! valores grandes.
  function coordinates() result(x)
    real(r8), allocatable :: x(:)
    integer :: k, m
    real(r8) :: v

    allocate(x(0))
    m = 0
    x = [(real(k, r8) * 0.001_r8, k = -400000, 400000)]
    do k = -2880, 2880
      v = real(k, r8) * 0.25_r8
      x = [x, v, ieee_next_after(v, -huge(v)), ieee_next_after(v, huge(v))]
    end do
    x = [x, -0.0_r8, 1.0e4_r8, -1.0e4_r8, 12345.678_r8, -9876.54321_r8]
  end function coordinates

  logical function same_bits(a, b)
    real(r8), intent(in) :: a, b
    same_bits = transfer(a, 1_int64) == transfer(b, 1_int64)
  end function same_bits

  !> Cada função contra a expressão que ela substituiu.
  subroutine check_indices()
    real(r8), allocatable :: x(:)
    real(r8), parameter :: STEPS(*) = [1.0_r8, 0.5_r8, 0.25_r8, 360.0_r8/1440, 180.0_r8/720]
    integer,  parameter :: NS(*) = [360, 180, 1440, 720]
    real(r8) :: d, l, lon_d
    integer :: k, ip, in, n, e
    logical :: ok_t, ok_p, ok_a, ok_t1, ok_l1, ok_l2, ok_l3, ok_l4, ok_l5

    x = coordinates()
    ok_t = .true.; ok_p = .true.; ok_a = .true.; ok_t1 = .true.
    do ip = 1, size(STEPS)
      d = STEPS(ip)
      do in = 1, size(NS)
        n = NS(in)
        do k = 1, size(x)
          ! int(x/d) + 1, limitado como em bin_cells_local e oisst_to_atm_nearest
          e = int(x(k) / d) + 1
          e = max(1, min(e, n))
          ok_t = ok_t .and. index_trunc(x(k), d, n) == e
          ! floor(x/d) + 1, limitado como em voronoi_to_grid: com o limite,
          ! igual ao truncamento
          e = floor(x(k) / d) + 1
          e = min(max(e, 1), n)
          ok_p = ok_p .and. index_trunc(x(k), d, n) == e
          ! nint(x/d) + 1, limitado como em voronoi_accum_local
          e = nint(x(k) / d) + 1
          e = min(max(e, 1), n)
          ok_a = ok_a .and. index_round(x(k), d, n) == e
        end do
      end do
    end do
    ! passo 1 constante, como DLON e DLAT no cap atmosférico
    do k = 1, size(x)
      e = int(x(k) / ONE) + 1
      e = max(1, min(e, 360))
      ok_t1 = ok_t1 .and. index_trunc(x(k), ONE, 360) == e
      e = int((x(k) + 90.0_r8) / ONE) + 1
      e = max(1, min(e, 180))
      ok_t1 = ok_t1 .and. index_trunc(x(k) + 90.0_r8, ONE, 180) == e
    end do
    call outcome('indices: int(x/d) + 1, limitado', ok_t)
    call outcome('indices: floor(x/d) + 1, limitado, igual ao truncamento', ok_p)
    call outcome('indices: nint(x/d) + 1, limitado', ok_a)
    call outcome('indices: int(x/1) + 1 com o passo constante do cap', ok_t1)

    ok_l1 = .true.; ok_l2 = .true.; ok_l3 = .true.; ok_l4 = .true.
    do k = 1, size(x)
      ! bin_cells_local
      lon_d = x(k) - floor(x(k) / 360.0_r8) * 360.0_r8
      ok_l1 = ok_l1 .and. same_bits(lon_0to360_floor(x(k)), lon_d)
      ! state_get_field_1d
      lon_d = x(k) - floor((x(k) + 180.0_r8) / 360.0_r8) &
                     * 360.0_r8
      ok_l2 = ok_l2 .and. same_bits(lon_m180to180_floor(x(k)), lon_d)
      ! mom_si_ifrac
      l = x(k)
      do while (l <   0.0_r8); l = l + 360.0_r8; end do
      do while (l >= 360.0_r8); l = l - 360.0_r8; end do
      ok_l3 = ok_l3 .and. same_bits(lon_0to360_loop(x(k)), l)
      ! voronoi_to_grid e voronoi_accum_local
      l = x(k)
      do while (l >= 180.0_r8);  l = l - 360.0_r8; end do
      do while (l < -180.0_r8);  l = l + 360.0_r8; end do
      ok_l4 = ok_l4 .and. same_bits(lon_m180to180_loop(x(k)), l)
    end do
    call outcome('longitude: [0, 360) pelo piso', ok_l1)
    call outcome('longitude: [-180, 180) pelo piso', ok_l2)
    call outcome('longitude: [0, 360) por laco', ok_l3)
    call outcome('longitude: [-180, 180) por laco', ok_l4)

    ! copy_to_local_grid: centro da coluna com o passo constante
    ok_l5 = .true.
    do k = 1, 360
      l = -180.0_r8 + (real(k, r8) - 0.5_r8) * ONE
      ok_l5 = ok_l5 .and. same_bits(center_lon_west180(k, 360), l)
    end do
    call outcome('centro do cap igual ao de copy_to_local_grid', ok_l5)
  end subroutine check_indices

  !> Centros calculados por check_ice_geography (med_ice) até a R-FASE11-08.
  subroutine check_ice_centers()
    integer :: i, j
    real(r8) :: lon_here, lat_here
    logical :: ok

    ok = .true.
    do i = 1, 360
      lon_here = (real(i,r8)-1.0_r8) * &
                 (360.0_r8/360) + 0.5_r8*(360.0_r8/360)
      ok = ok .and. same_bits(center_lon_east0(i, 360), lon_here)
    end do
    do j = 1, 180
      lat_here = -90.0_r8 + (real(j,r8)-1.0_r8) * &
                 (180.0_r8/180) + 0.5_r8*(180.0_r8/180)
      ok = ok .and. same_bits(center_lat_east0(j, 180), lat_here)
    end do
    call outcome('centros_gelo: iguais aos de check_ice_geography', ok)
  end subroutine check_ice_centers

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

end program test_cpl_grids
