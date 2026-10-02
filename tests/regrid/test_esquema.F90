!> Interpola um campo analítico com um esquema e com uma referência, para
!! tests/regrid/compara-esquema.bash.
!!
!! Uso: mpirun -np N ./test_esquema ESQUEMA OPCOES REFERENCIA SAIDA
!!   ESQUEMA     nome na lista de src/regrid/regrid_schemes.F90 (ex.: idw)
!!   OPCOES      opções do esquema ('-' para nenhuma)
!!   REFERENCIA  método do esquema esmf usado como referência (ex.: bilinear)
!!   SAIDA       arquivo binário com o campo de destino do esquema, em ordem
!!               do índice global (gravado pelo PET 0)
!!
!! Origem: grade global de 4 graus (90 x 45); destino: grade global de 1 grau
!! (360 x 180); campo f = 2 + cos(lat) cos(lon). Imprime, no PET 0, o erro
!! do esquema e da referência contra a função (só onde |lat| < 85 graus) e
!! a diferença máxima entre os dois. Termina com código 1 se a rota do
!! esquema ou a da referência não puder ser criada ou aplicada.
program test_esquema

  use ESMF
  use mpi
  use regrid_base_mod,    only : regrid_spec_t
  use regrid_manager_mod, only : regrid_manager_t, regrid_spec

  implicit none

  real(ESMF_KIND_R8), parameter :: PI  = 3.14159265358979323846_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: D2R = PI / 180.0_ESMF_KIND_R8

  type(ESMF_VM)    :: vm
  type(ESMF_Grid)  :: gsrc, gdst
  type(ESMF_Field) :: fsrc, fesq, fref
  type(regrid_manager_t) :: mgr
  type(regrid_spec_t)    :: spec
  character(len=128) :: esquema, opcoes, referencia, saida
  real(ESMF_KIND_R8) :: e_max, e_med, r_max, r_med, d_max
  integer :: rc, rc_ref, localPet, petCount

  call ESMF_Initialize(defaultLogFileName='test_esquema.log', logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
  call get_command_argument(1, esquema)
  call get_command_argument(2, opcoes)
  call get_command_argument(3, referencia)
  call get_command_argument(4, saida)
  if (trim(opcoes) == '-') opcoes = ''

  gsrc = make_grid(90, 45)
  gdst = make_grid(360, 180)
  fsrc = ESMF_FieldCreate(gsrc, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  fesq = ESMF_FieldCreate(gdst, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  fref = ESMF_FieldCreate(gdst, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  call set_analytic(fsrc, gsrc)

  spec = regrid_spec('', scheme=trim(esquema), options=trim(opcoes))
  call mgr%add('esquema', spec, fsrc, fesq, rc)
  if (rc == ESMF_SUCCESS) call mgr%apply('esquema', fsrc, fesq, rc)
  call mgr%add('referencia', regrid_spec(trim(referencia)), fsrc, fref, rc_ref)
  if (rc_ref == ESMF_SUCCESS) call mgr%apply('referencia', fsrc, fref, rc_ref)
  if (rc /= ESMF_SUCCESS .or. rc_ref /= ESMF_SUCCESS) then
    if (localPet == 0) write(*,'(A)') 'ERRO: rota do esquema ou da referencia (ver PET*.test_esquema.log)'
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
  end if

  call erros(fesq, gdst, e_max, e_med)
  call erros(fref, gdst, r_max, r_med)
  d_max = global_max(maxval(abs(local(fesq) - local(fref))))
  if (localPet == 0) then
    write(*,'(A,I0)')         'PETS ', petCount
    write(*,'(A,A)')          'METODO ', trim(mgr%method('esquema'))
    write(*,'(A,ES12.5)')     'ERRO_MAX_ESQUEMA ', e_max
    write(*,'(A,ES12.5)')     'ERRO_MED_ESQUEMA ', e_med
    write(*,'(A,ES12.5)')     'ERRO_MAX_REFERENCIA ', r_max
    write(*,'(A,ES12.5)')     'ERRO_MED_REFERENCIA ', r_med
    write(*,'(A,ES12.5)')     'DIF_MAX ', d_max
  end if
  call grava(fesq, gdst, trim(saida))

  call mgr%destroy(rc)
  call ESMF_Finalize(rc=rc)

contains

  function make_grid(nx, ny) result(g)
    integer, intent(in) :: nx, ny
    type(ESMF_Grid) :: g
    real(ESMF_KIND_R8), pointer :: x(:,:), y(:,:)
    integer :: i, j, lb(2), ub(2), irc
    real(ESMF_KIND_R8) :: dx, dy

    g = ESMF_GridCreate1PeriDim(maxIndex=[nx, ny], indexflag=ESMF_INDEX_GLOBAL, &
      coordSys=ESMF_COORDSYS_SPH_DEG, rc=irc)
    call ESMF_GridAddCoord(g, staggerloc=ESMF_STAGGERLOC_CENTER, rc=irc)
    call ESMF_GridAddCoord(g, staggerloc=ESMF_STAGGERLOC_CORNER, rc=irc)
    dx = 360.0_ESMF_KIND_R8 / nx; dy = 180.0_ESMF_KIND_R8 / ny
    call ESMF_GridGetCoord(g, 1, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=x, &
      computationalLBound=lb, computationalUBound=ub, rc=irc)
    call ESMF_GridGetCoord(g, 2, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=y, rc=irc)
    do j = lb(2), ub(2)
      do i = lb(1), ub(1)
        x(i,j) = (i - 0.5_ESMF_KIND_R8) * dx
        y(i,j) = -90.0_ESMF_KIND_R8 + (j - 0.5_ESMF_KIND_R8) * dy
      end do
    end do
    call ESMF_GridGetCoord(g, 1, staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=x, &
      computationalLBound=lb, computationalUBound=ub, rc=irc)
    call ESMF_GridGetCoord(g, 2, staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=y, rc=irc)
    do j = lb(2), ub(2)
      do i = lb(1), ub(1)
        x(i,j) = (i - 1) * dx
        y(i,j) = -90.0_ESMF_KIND_R8 + (j - 1) * dy
      end do
    end do
  end function make_grid

  elemental function analytic(lon, lat) result(f)
    real(ESMF_KIND_R8), intent(in) :: lon, lat
    real(ESMF_KIND_R8) :: f
    f = 2.0_ESMF_KIND_R8 + cos(lat*D2R) * cos(lon*D2R)
  end function analytic

  subroutine set_analytic(f, g)
    type(ESMF_Field), intent(inout) :: f
    type(ESMF_Grid),  intent(in)    :: g
    real(ESMF_KIND_R8), pointer :: p(:,:), x(:,:), y(:,:)
    integer :: irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    call ESMF_GridGetCoord(g, 1, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=x, rc=irc)
    call ESMF_GridGetCoord(g, 2, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=y, rc=irc)
    p = analytic(x, y)
  end subroutine set_analytic

  function local(f) result(a)
    type(ESMF_Field), intent(inout) :: f
    real(ESMF_KIND_R8), allocatable :: a(:,:)
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    a = p
  end function local

  real(ESMF_KIND_R8) function global_max(v)
    real(ESMF_KIND_R8), intent(in) :: v
    integer :: ierr
    call MPI_Allreduce(v, global_max, 1, MPI_DOUBLE_PRECISION, MPI_MAX, MPI_COMM_WORLD, ierr)
  end function global_max

  !> Erro máximo e médio contra a função, onde |lat| < 85 graus.
  subroutine erros(f, g, e_max, e_med)
    type(ESMF_Field),   intent(inout) :: f
    type(ESMF_Grid),    intent(in)    :: g
    real(ESMF_KIND_R8), intent(out)   :: e_max, e_med
    real(ESMF_KIND_R8), pointer :: p(:,:), x(:,:), y(:,:)
    real(ESMF_KIND_R8) :: soma(2), soma_g(2)
    integer :: irc, ierr
    logical, allocatable :: dentro(:,:)
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    call ESMF_GridGetCoord(g, 1, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=x, rc=irc)
    call ESMF_GridGetCoord(g, 2, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=y, rc=irc)
    dentro = abs(y) < 85.0_ESMF_KIND_R8
    e_max = global_max(maxval(abs(p - analytic(x, y)), mask=dentro))
    soma = [sum(abs(p - analytic(x, y)), mask=dentro), real(count(dentro), ESMF_KIND_R8)]
    call MPI_Allreduce(soma, soma_g, 2, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, ierr)
    e_med = soma_g(1) / max(soma_g(2), 1.0_ESMF_KIND_R8)
  end subroutine erros

  !> Grava o campo inteiro, na ordem do índice global, pelo PET 0.
  subroutine grava(f, g, arquivo)
    type(ESMF_Field), intent(inout) :: f
    type(ESMF_Grid),  intent(in)    :: g
    character(len=*), intent(in)    :: arquivo
    real(ESMF_KIND_R8), pointer :: p(:,:)
    real(ESMF_KIND_R8), allocatable :: todos(:), val(:)
    integer, allocatable :: idx(:), idx_todos(:), contagens(:), desl(:)
    integer :: irc, ierr, lb(2), ub(2), maxIndex(2), i, j, n, k, unidade
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    call ESMF_FieldGetBounds(f, exclusiveLBound=lb, exclusiveUBound=ub, rc=irc)
    call ESMF_GridGet(g, tile=1, staggerloc=ESMF_STAGGERLOC_CENTER, maxIndex=maxIndex, rc=irc)
    n = size(p)
    allocate(idx(n), val(n))
    k = 0
    do j = lb(2), ub(2)
      do i = lb(1), ub(1)
        k = k + 1
        idx(k) = i + (j - 1) * maxIndex(1)
        val(k) = p(i, j)
      end do
    end do
    allocate(contagens(petCount), desl(petCount))
    call MPI_Allgather(n, 1, MPI_INTEGER, contagens, 1, MPI_INTEGER, MPI_COMM_WORLD, ierr)
    desl = [(sum(contagens(1:k-1)), k = 1, petCount)]
    allocate(idx_todos(sum(contagens)), todos(sum(contagens)))
    call MPI_Gatherv(idx, n, MPI_INTEGER, idx_todos, contagens, desl, MPI_INTEGER, 0, &
      MPI_COMM_WORLD, ierr)
    call MPI_Gatherv(val, n, MPI_DOUBLE_PRECISION, todos, contagens, desl, MPI_DOUBLE_PRECISION, &
      0, MPI_COMM_WORLD, ierr)
    if (localPet == 0) then
      val = todos
      todos(idx_todos) = val(1:size(todos))
      open(newunit=unidade, file=arquivo, access='stream', form='unformatted', status='replace')
      write(unidade) todos
      close(unidade)
    end if
  end subroutine grava

end program test_esquema
