!> Testes do framework de interpolação (src/regrid).
!! Uso: mpirun -np N ./test_regrid     (imprime PASSOU/FALHOU por teste)
!!
!! Desde a R-FASE11-23, o item 9 testa a base de esquemas de pesos
!! (weights_regridder_t), o modelo idw, as opções em texto e a ida e volta
!! dos pesos de um esquema de pesos pelo esquema weights_file.
program test_regrid

  use ESMF
  use mpi
  use netcdf
  use regrid_base_mod,     only : regridder_t, regrid_spec_t, regrid_fill_t, neighbor_fill, &
                                  regrid_option_real, regrid_option_int, regrid_options_check
  use regrid_registry_mod, only : regrid_register, regrid_create
  use regrid_manager_mod,  only : regrid_manager_t, regrid_spec
  use regrid_mpassit_mod,  only : mpas_mesh_create
  use identity_scheme_mod, only : new_identity, new_identity_weights
  use regrid_idw_mod,      only : idw_regridder_t

  implicit none

  real(ESMF_KIND_R8), parameter :: PI = 3.14159265358979323846_ESMF_KIND_R8
  real(ESMF_KIND_R8), parameter :: D2R = PI / 180.0_ESMF_KIND_R8
  character(len=*),   parameter :: WFILE = 'pesos_teste.nc'
  character(len=*),   parameter :: WFILE_IDW = 'pesos_idw.nc'

  type(ESMF_VM)    :: vm
  type(ESMF_Grid)  :: gsrc, gdst, greg, g4
  type(ESMF_Field) :: fsrc, fdst, fdst2, fmesh, freg, fdst3, f4, fa, fb
  type(idw_regridder_t) :: idw
  type(ESMF_Mesh)  :: mesh
  type(regrid_manager_t) :: mgr
  type(regrid_spec_t)    :: spec
  integer :: rc, localPet, petCount, nfail
  ! Etapa completar (item 8)
  type(regrid_fill_t), parameter :: F1 = regrid_fill_t(enabled=.true., vmin=1.0_ESMF_KIND_R8, &
    vmax=2.5_ESMF_KIND_R8, vfill=1.5_ESMF_KIND_R8, max_iter=5, skip_fraction=1.0_ESMF_KIND_R8, &
    overflow_to_fill=.true.)
  type(regrid_fill_t), parameter :: F2 = regrid_fill_t(enabled=.true., vmin=1.0_ESMF_KIND_R8, &
    vmax=3.0_ESMF_KIND_R8, vfill=-5.0_ESMF_KIND_R8)
  real(ESMF_KIND_R8), allocatable :: ref1(:,:), ref2(:,:)
  integer :: ni_ref1, nl_ref1, ni_ref2, nl_ref2, ni, nl

  call ESMF_Initialize(defaultLogFileName='test_regrid.log', logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
  nfail = 0

  gsrc = make_grid(180, 90)     ! 2 graus
  gdst = make_grid(360, 180)    ! 1 grau
  fsrc  = ESMF_FieldCreate(gsrc, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  fdst  = ESMF_FieldCreate(gdst, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  fdst2 = ESMF_FieldCreate(gdst, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  call set_analytic(fsrc, gsrc)

  ! 1. Esquema esmf, bilinear
  call mgr%add('bilinear', regrid_spec('bilinear'), fsrc, fdst, rc)
  call mgr%apply('bilinear', fsrc, fdst, rc)
  call report('esmf bilinear: erro maximo < 2e-3', rc == 0 .and. max_error(fdst, gdst) < 2.0e-3_ESMF_KIND_R8)

  ! 2. Cadeia de métodos: o primeiro inválido é pulado
  call mgr%add('cadeia', regrid_spec('metodo_inexistente,conserve'), fsrc, fdst2, rc)
  call report('cadeia de metodos: usa conserve', rc == 0 .and. trim(mgr%method('cadeia')) == 'conserve')

  ! 2b. Rota de reserva: nenhum método funciona, usa a rota 'bilinear'
  call mgr%add('reserva', regrid_spec('metodo_inexistente'), fsrc, fdst2, rc, fallback='bilinear')
  if (rc == 0) call mgr%apply('reserva', fsrc, fdst2, rc)
  call report('rota de reserva: identica a rota bilinear', &
              rc == 0 .and. max_diff(fdst, fdst2) == 0.0_ESMF_KIND_R8)

  ! 3. Esquema weights_file: pesos gravados em arquivo reproduzem o online
  call write_weights(fsrc, fdst2, WFILE)
  spec = regrid_spec('', scheme='weights_file')
  spec%weights_file = WFILE
  call mgr%add('arquivo', spec, fsrc, fdst2, rc)
  if (rc == 0) call mgr%apply('arquivo', fsrc, fdst2, rc)
  call report('weights_file: identico ao bilinear online', rc == 0 .and. max_diff(fdst, fdst2) == 0.0_ESMF_KIND_R8)

  ! 4. Esquema registrado pelo usuário (plug-in)
  call regrid_register('identidade', new_identity, rc)
  call mgr%add('plugin', regrid_spec('', scheme='identidade'), fdst, fdst2, rc)
  call mgr%apply('plugin', fdst, fdst2, rc)
  call report('esquema externo registrado em tempo de execucao', rc == 0 .and. max_diff(fdst, fdst2) == 0.0_ESMF_KIND_R8)

  ! 5. Preenchimento por vizinhança
  call report('neighbor_fill', test_neighbor_fill())

  ! 6. Esquema mpassit: malha de células poligonais -> grade regular
  call make_quad_mesh(90, 44, mesh)       ! células de 4 x ~4 graus entre 88S e 88N
  fmesh = ESMF_FieldCreate(mesh, ESMF_TYPEKIND_R8, meshloc=ESMF_MESHLOC_ELEMENT, rc=rc)
  call set_analytic_mesh(fmesh, mesh)
  if (rc == 0) call mgr%add('mpassit', mpassit_spec(), fmesh, fdst2, rc)
  if (rc == 0) call mgr%apply('mpassit', fmesh, fdst2, rc)
  call report('mpassit: erro < 5e-3 na area coberta, ausencia fora dela', &
              rc == 0 .and. mpassit_ok(fdst2, gdst))

  ! 7. Opções da rota pedida: com reserva, o zero_total e a troca de NaN são
  !    os da rota pedida, e não os da reserva. Origem regional (40S a 40N):
  !    fora dela, a interpolação não alcança o destino.
  greg  = make_regional(180, 40)
  freg  = ESMF_FieldCreate(greg, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  fdst3 = ESMF_FieldCreate(gdst, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  call set_analytic(freg, greg)
  call mgr%add('regional', regrid_spec('bilinear'), freg, fdst3, rc)
  call mgr%add('mantem', regrid_spec('metodo_inexistente', zero_total=.false.), freg, fdst3, rc, &
               fallback='regional')
  call fill_field(fdst3, -999.0_ESMF_KIND_R8)
  if (rc == 0) call mgr%apply('regional', freg, fdst3, rc)
  call report('rota que zera: fora da origem fica 0', rc == 0 .and. count_value(fdst3, -999.0_ESMF_KIND_R8) == 0)
  call fill_field(fdst3, -999.0_ESMF_KIND_R8)
  if (rc == 0) call mgr%apply('mantem', freg, fdst3, rc)
  call report('reserva com zero_total da rota pedida: fora da origem fica -999', &
              rc == 0 .and. count_value(fdst3, -999.0_ESMF_KIND_R8) > 0)
  call set_nan(freg)
  call mgr%add('com_nan', regrid_spec('bilinear', nan_value=7.0_ESMF_KIND_R8), freg, fdst3, rc)
  if (rc == 0) call mgr%apply('regional', freg, fdst3, rc)
  call report('sem troca de NaN: o NaN da origem chega ao destino', rc == 0 .and. count_nan(fdst3) > 0)
  if (rc == 0) call mgr%apply('com_nan', freg, fdst3, rc)
  call report('troca de NaN: nenhum NaN no destino', rc == 0 .and. count_nan(fdst3) == 0 .and. &
              count_value(fdst3, 7.0_ESMF_KIND_R8) > 0)
  call mgr%add('nan_reserva', regrid_spec('metodo_inexistente', nan_value=7.0_ESMF_KIND_R8), &
               freg, fdst3, rc, fallback='regional')
  if (rc == 0) call mgr%apply('nan_reserva', freg, fdst3, rc)
  call report('reserva com a troca de NaN da rota pedida', rc == 0 .and. count_nan(fdst3) == 0)

  ! 8. Etapa completar pela rota: o resultado e as contagens são os do
  !    preenchimento por vizinhança chamado à parte depois da interpolação.
  !    A origem regional tem um NaN por PET e não alcança as altas latitudes
  !    (zeros, fora da faixa de F1 e F2); com F2, a fração inválida passa
  !    do limiar e a difusão é pulada.
  if (rc == 0) call mgr%apply('regional', freg, fdst3, rc)
  ref1 = local(fdst3)
  call neighbor_fill(ref1, F1, n_left=nl_ref1, n_invalid=ni_ref1)
  ref2 = local(fdst3)
  call neighbor_fill(ref2, F2, n_left=nl_ref2, n_invalid=ni_ref2)
  call report('completar: o caso tem NaN, pontos fora da faixa e acima de vmax', &
              rc == 0 .and. count_nan(fdst3) > 0 .and. acc(ni_ref1) > acc(nl_ref1) .and. &
              acc(nl_ref1) > 0 .and. acc(count(local(fdst3) > F1%vmax)) > 0)
  spec = regrid_spec('bilinear')
  spec%fill = F1
  call mgr%add('completa', spec, freg, fdst3, rc)
  if (rc == 0) call mgr%apply('completa', freg, fdst3, rc, n_invalid=ni, n_left=nl)
  call report('completar pela rota: igual ao preenchimento a parte, com as contagens', &
              rc == 0 .and. equal(local(fdst3), ref1) .and. ni == ni_ref1 .and. nl == nl_ref1)
  spec = regrid_spec('metodo_inexistente')
  spec%fill = F1
  call mgr%add('completa_reserva', spec, freg, fdst3, rc, fallback='regional')
  if (rc == 0) call mgr%apply('completa_reserva', freg, fdst3, rc, n_invalid=ni, n_left=nl)
  call report('reserva com o preenchimento da rota pedida', &
              rc == 0 .and. equal(local(fdst3), ref1) .and. ni == ni_ref1 .and. nl == nl_ref1)
  spec = regrid_spec('bilinear', nan_value=7.0_ESMF_KIND_R8)
  spec%fill = F1
  call mgr%add('completa_nan', spec, freg, fdst3, rc)
  if (rc == 0) call mgr%apply('completa_nan', freg, fdst3, rc)
  call report('completar antes da troca de NaN: os NaN sao completados por vizinhanca', &
              rc == 0 .and. equal(local(fdst3), ref1))
  if (rc == 0) call mgr%apply('completa', freg, fdst3, rc, fill=F2, n_invalid=ni, n_left=nl)
  call report('preenchimento passado na chamada substitui o da rota (difusao pulada)', &
              rc == 0 .and. equal(local(fdst3), ref2) .and. ni == ni_ref2 .and. nl == nl_ref2 .and. &
              acc(nl_ref2) == acc(ni_ref2) .and. acc(ni_ref2) > 0)
  if (rc == 0) call mgr%apply('regional', freg, fdst3, rc, n_invalid=ni, n_left=nl)
  call report('rota sem preenchimento: contagens -1', rc == 0 .and. ni == -1 .and. nl == -1)

  ! 9. Esquemas de pesos (R-FASE11-23): origem de 4 graus, destino de 2.
  g4 = make_grid(90, 45)
  f4 = ESMF_FieldCreate(g4,   ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  fa = ESMF_FieldCreate(gsrc, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  fb = ESMF_FieldCreate(gsrc, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
  call set_analytic(f4, g4)
  call regrid_register('pesos_identidade', new_identity_weights, rc)
  call mgr%add('id_pesos', regrid_spec('', scheme='pesos_identidade'), fsrc, fa, rc)
  if (rc == 0) call mgr%apply('id_pesos', fsrc, fa, rc)
  call report('base de pesos: pesos de identidade copiam o campo, bit a bit', &
              rc == 0 .and. equal(local(fa), local(fsrc)))
  call mgr%add('vizinho', regrid_spec('nearest_stod'), f4, fa, rc)
  if (rc == 0) call mgr%apply('vizinho', f4, fa, rc)
  call mgr%add('idw1', regrid_spec('', scheme='idw', options='vizinhos=1'), f4, fb, rc)
  if (rc == 0) call mgr%apply('idw1', f4, fb, rc)
  call report('idw com vizinhos=1 igual ao nearest_stod do ESMF, bit a bit', &
              rc == 0 .and. equal(local(fa), local(fb)) .and. trim(mgr%method('idw1')) == 'idw')
  call mgr%add('idw', regrid_spec('', scheme='idw'), f4, fb, rc)
  if (rc == 0) call mgr%apply('idw', f4, fb, rc)
  call report('idw padrao (4 vizinhos, expoente 2): erro maximo < 3e-2', &
              rc == 0 .and. max_error(fb, gsrc) < 3.0e-2_ESMF_KIND_R8)
  call mgr%add('idw_errado', regrid_spec('', scheme='idw', options='vizinho=4'), f4, fb, rc)
  call report('idw recusa opcao desconhecida', rc /= 0)
  call mgr%add('idw_errado2', regrid_spec('', scheme='idw', options='vizinhos=quatro'), f4, fb, rc)
  call report('idw recusa valor invalido', rc /= 0)
  call report('opcoes em texto: leitura, padrao e conferencia', test_options())

  ! Ida e volta: os pesos do idw gravados em arquivo e lidos pelo weights_file
  idw%label = 'idw_direto'
  idw%spec  = regrid_spec('', scheme='idw', options='expoente=1.5,vizinhos=6')
  call idw%setup(f4, fa, rc)
  if (rc == 0) call idw%apply(f4, fa, rc)
  if (rc == 0) call write_factors(idw%factors, idw%src_index, idw%dst_index, WFILE_IDW)
  spec = regrid_spec('', scheme='weights_file')
  spec%weights_file = WFILE_IDW
  if (rc == 0) call mgr%add('idw_arquivo', spec, f4, fb, rc)
  if (rc == 0) call mgr%apply('idw_arquivo', f4, fb, rc)
  call report('pesos do idw pelo weights_file: resultado identico, bit a bit', &
              rc == 0 .and. equal(local(fa), local(fb)))
  call idw%release(rc)
  call report('release do esquema de pesos', rc == 0 .and. .not. allocated(idw%factors))

  call mgr%destroy(rc)
  call report('destroy', rc == 0)

  if (localPet == 0) then
    if (nfail == 0) then
      write(*,'(A,I0,A)') 'TODOS OS TESTES PASSARAM (', petCount, ' PETs)'
    else
      write(*,'(I0,A)') nfail, ' TESTE(S) FALHARAM'
    end if
  end if
  call ESMF_Finalize(rc=rc)

contains

  subroutine report(name, ok)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: ok
    logical :: all_ok
    integer :: ierr
    call MPI_Allreduce(ok, all_ok, 1, MPI_LOGICAL, MPI_LAND, MPI_COMM_WORLD, ierr)
    if (.not. all_ok) nfail = nfail + 1
    if (localPet == 0) write(*,'(A,A)') merge('PASSOU  ', 'FALHOU  ', all_ok), name
  end subroutine report

  !> Grade regular de nx x ny entre 40S e 40N, sem periodicidade.
  function make_regional(nx, ny) result(g)
    integer, intent(in) :: nx, ny
    type(ESMF_Grid) :: g
    real(ESMF_KIND_R8), pointer :: x(:,:), y(:,:)
    integer :: i, j, lb(2), ub(2), irc
    real(ESMF_KIND_R8) :: dx, dy

    g = ESMF_GridCreateNoPeriDim(maxIndex=[nx, ny], indexflag=ESMF_INDEX_GLOBAL, &
      coordSys=ESMF_COORDSYS_SPH_DEG, rc=irc)
    call ESMF_GridAddCoord(g, staggerloc=ESMF_STAGGERLOC_CENTER, rc=irc)
    dx = 360.0_ESMF_KIND_R8 / nx; dy = 80.0_ESMF_KIND_R8 / ny
    call ESMF_GridGetCoord(g, 1, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=x, &
      computationalLBound=lb, computationalUBound=ub, rc=irc)
    call ESMF_GridGetCoord(g, 2, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=y, rc=irc)
    do j = lb(2), ub(2)
      do i = lb(1), ub(1)
        x(i,j) = (i - 0.5_ESMF_KIND_R8) * dx
        y(i,j) = -40.0_ESMF_KIND_R8 + (j - 0.5_ESMF_KIND_R8) * dy
      end do
    end do
  end function make_regional

  subroutine fill_field(f, v)
    type(ESMF_Field),   intent(inout) :: f
    real(ESMF_KIND_R8), intent(in)    :: v
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    p = v
  end subroutine fill_field

  !> Põe NaN no primeiro ponto local da origem.
  subroutine set_nan(f)
    type(ESMF_Field), intent(inout) :: f
    real(ESMF_KIND_R8), pointer :: p(:,:)
    real(ESMF_KIND_R8) :: zero
    integer :: irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    zero = 0.0_ESMF_KIND_R8
    p(lbound(p,1), lbound(p,2)) = zero / zero
  end subroutine set_nan

  !> Contagem global de pontos iguais a v.
  integer function count_value(f, v)
    type(ESMF_Field),   intent(inout) :: f
    real(ESMF_KIND_R8), intent(in)    :: v
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: irc, loc, ierr
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    loc = count(p == v)
    call MPI_Allreduce(loc, count_value, 1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, ierr)
  end function count_value

  !> Cópia dos valores locais do campo.
  function local(f) result(a)
    type(ESMF_Field), intent(inout) :: f
    real(ESMF_KIND_R8), allocatable :: a(:,:)
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    a = p
  end function local

  !> Igualdade bit a bit dos valores (NaN igual a NaN).
  logical function equal(a, b)
    real(ESMF_KIND_R8), intent(in) :: a(:,:), b(:,:)
    equal = all(shape(a) == shape(b))
    if (equal) equal = all(transfer(a, 1_8, size(a)) == transfer(b, 1_8, size(b)))
  end function equal

  !> Soma de n em todos os PETs.
  integer function acc(n)
    integer, intent(in) :: n
    integer :: ierr
    call MPI_Allreduce(n, acc, 1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, ierr)
  end function acc

  !> Contagem global de NaN.
  integer function count_nan(f)
    type(ESMF_Field), intent(inout) :: f
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: irc, loc, ierr
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    loc = count(p /= p)
    call MPI_Allreduce(loc, count_nan, 1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, ierr)
  end function count_nan

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

  real(ESMF_KIND_R8) function max_error(f, g)
    type(ESMF_Field), intent(in) :: f
    type(ESMF_Grid),  intent(in) :: g
    real(ESMF_KIND_R8), pointer :: p(:,:), x(:,:), y(:,:)
    integer :: irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    call ESMF_GridGetCoord(g, 1, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=x, rc=irc)
    call ESMF_GridGetCoord(g, 2, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=y, rc=irc)
    max_error = maxval(abs(p - analytic(x, y)), mask=abs(y) < 89.0_ESMF_KIND_R8)
  end function max_error

  real(ESMF_KIND_R8) function max_diff(a, b)
    type(ESMF_Field), intent(in) :: a, b
    real(ESMF_KIND_R8), pointer :: pa(:,:), pb(:,:)
    integer :: irc
    call ESMF_FieldGet(a, farrayPtr=pa, rc=irc)
    call ESMF_FieldGet(b, farrayPtr=pb, rc=irc)
    max_diff = maxval(abs(pa - pb))
  end function max_diff

  !> Grava, no formato SCRIP/ESMF, os pesos bilineares src -> dst.
  subroutine write_weights(src, dst, fname)
    type(ESMF_Field), intent(inout) :: src, dst
    character(len=*), intent(in)    :: fname
    type(ESMF_RouteHandle) :: rh
    real(ESMF_KIND_R8),    pointer :: S(:)
    integer(ESMF_KIND_I4), pointer :: idx(:,:)
    integer, allocatable :: counts(:), displs(:), row(:), col(:)
    real(ESMF_KIND_R8), allocatable :: w(:)
    integer :: n, ntot, ierr, ncid, dimid, vr, vc, vs, k

    call ESMF_FieldRegridStore(src, dst, routehandle=rh, regridmethod=ESMF_REGRIDMETHOD_BILINEAR, &
      unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, factorList=S, factorIndexList=idx, rc=ierr)
    call ESMF_FieldRegridRelease(rh, rc=ierr)
    n = size(S)
    allocate(counts(petCount), displs(petCount))
    call MPI_Allgather(n, 1, MPI_INTEGER, counts, 1, MPI_INTEGER, MPI_COMM_WORLD, ierr)
    displs = [(sum(counts(1:k-1)), k = 1, petCount)]
    ntot = sum(counts)
    allocate(row(ntot), col(ntot), w(ntot))
    call MPI_Gatherv(pack(idx(1,:), .true.), n, MPI_INTEGER, col, counts, displs, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
    call MPI_Gatherv(pack(idx(2,:), .true.), n, MPI_INTEGER, row, counts, displs, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
    call MPI_Gatherv(S, n, MPI_DOUBLE_PRECISION, w, counts, displs, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)
    if (localPet == 0) then
      ierr = nf90_create(fname, NF90_CLOBBER, ncid)
      ierr = nf90_def_dim(ncid, 'n_s', ntot, dimid)
      ierr = nf90_def_var(ncid, 'row', NF90_INT, [dimid], vr)
      ierr = nf90_def_var(ncid, 'col', NF90_INT, [dimid], vc)
      ierr = nf90_def_var(ncid, 'S', NF90_DOUBLE, [dimid], vs)
      ierr = nf90_enddef(ncid)
      ierr = nf90_put_var(ncid, vr, row)
      ierr = nf90_put_var(ncid, vc, col)
      ierr = nf90_put_var(ncid, vs, w)
      ierr = nf90_close(ncid)
    end if
    call MPI_Barrier(MPI_COMM_WORLD, ierr)
    deallocate(S, idx)
  end subroutine write_weights

  !> Grava, no formato SCRIP/ESMF, pesos dados em índices globais (os de
  !! cada PET, reunidos no PET 0).
  subroutine write_factors(S, col_loc, row_loc, fname)
    real(ESMF_KIND_R8), intent(in) :: S(:)
    integer,            intent(in) :: col_loc(:), row_loc(:)
    character(len=*),   intent(in) :: fname
    integer, allocatable :: counts(:), displs(:), row(:), col(:)
    real(ESMF_KIND_R8), allocatable :: w(:)
    integer :: n, ntot, ierr, ncid, dimid, vr, vc, vs, k

    n = size(S)
    allocate(counts(petCount), displs(petCount))
    call MPI_Allgather(n, 1, MPI_INTEGER, counts, 1, MPI_INTEGER, MPI_COMM_WORLD, ierr)
    displs = [(sum(counts(1:k-1)), k = 1, petCount)]
    ntot = sum(counts)
    allocate(row(ntot), col(ntot), w(ntot))
    call MPI_Gatherv(col_loc, n, MPI_INTEGER, col, counts, displs, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
    call MPI_Gatherv(row_loc, n, MPI_INTEGER, row, counts, displs, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)
    call MPI_Gatherv(S, n, MPI_DOUBLE_PRECISION, w, counts, displs, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)
    if (localPet == 0) then
      ierr = nf90_create(fname, NF90_CLOBBER, ncid)
      ierr = nf90_def_dim(ncid, 'n_s', ntot, dimid)
      ierr = nf90_def_var(ncid, 'row', NF90_INT, [dimid], vr)
      ierr = nf90_def_var(ncid, 'col', NF90_INT, [dimid], vc)
      ierr = nf90_def_var(ncid, 'S', NF90_DOUBLE, [dimid], vs)
      ierr = nf90_enddef(ncid)
      ierr = nf90_put_var(ncid, vr, row)
      ierr = nf90_put_var(ncid, vc, col)
      ierr = nf90_put_var(ncid, vs, w)
      ierr = nf90_close(ncid)
    end if
    call MPI_Barrier(MPI_COMM_WORLD, ierr)
  end subroutine write_factors

  !> Leitura das opções em texto: valores, padrão, espaços, chave
  !! desconhecida, chave sem valor e valores inválidos.
  logical function test_options()
    character(len=8), parameter :: KNOWN(2) = ['vizinhos', 'expoente']
    real(ESMF_KIND_R8) :: x
    integer :: n, irc
    logical :: ok

    ok = .true.
    call regrid_option_real(' vizinhos = 6 , expoente=1.5', 'expoente', 2.0_ESMF_KIND_R8, x, irc)
    ok = ok .and. irc == ESMF_SUCCESS .and. x == 1.5_ESMF_KIND_R8
    call regrid_option_int(' vizinhos = 6 , expoente=1.5', 'vizinhos', 4, n, irc)
    ok = ok .and. irc == ESMF_SUCCESS .and. n == 6
    call regrid_option_int('', 'vizinhos', 4, n, irc)
    ok = ok .and. irc == ESMF_SUCCESS .and. n == 4
    call regrid_option_int('vizinhos=2.5', 'vizinhos', 4, n, irc)
    ok = ok .and. irc /= ESMF_SUCCESS .and. n == 4
    call regrid_option_real('expoente=', 'expoente', 2.0_ESMF_KIND_R8, x, irc)
    ok = ok .and. irc /= ESMF_SUCCESS .and. x == 2.0_ESMF_KIND_R8
    call regrid_options_check('vizinhos=6,expoente=1.5', KNOWN, irc)
    ok = ok .and. irc == ESMF_SUCCESS
    call regrid_options_check('', KNOWN, irc)
    ok = ok .and. irc == ESMF_SUCCESS
    call regrid_options_check('vizinhos=6,raio=3', KNOWN, irc)
    ok = ok .and. irc /= ESMF_SUCCESS
    call regrid_options_check('vizinhos', KNOWN, irc)
    ok = ok .and. irc /= ESMF_SUCCESS
    test_options = ok
  end function test_options

  logical function test_neighbor_fill()
    real(ESMF_KIND_R8) :: a(5,5)
    type(regrid_fill_t) :: opt
    a = 1.0_ESMF_KIND_R8
    a(3,3) = -999.0_ESMF_KIND_R8           ! inválido, cercado de válidos
    opt = regrid_fill_t(enabled=.true., vmin=0.0_ESMF_KIND_R8, vmax=2.0_ESMF_KIND_R8, &
                        vfill=0.5_ESMF_KIND_R8)
    call neighbor_fill(a, opt)
    test_neighbor_fill = all(a == 1.0_ESMF_KIND_R8)
    a = -1.0_ESMF_KIND_R8                   ! tudo inválido: pula a difusão
    call neighbor_fill(a, opt)
    test_neighbor_fill = test_neighbor_fill .and. all(a == 0.5_ESMF_KIND_R8)
  end function test_neighbor_fill

  !> Malha global de células quadrilaterais (4 vértices), no formato das
  !! variáveis do MPAS: cellIDs, nEdgesOnCell, verticesOnCell, vértices.
  !! As células são repartidas entre os PETs por faixas de índice.
  subroutine make_quad_mesh(nx, ny, m)
    integer,         intent(in)  :: nx, ny
    type(ESMF_Mesh), intent(out) :: m
    integer, allocatable :: cellIDs(:), nEdges(:), voc(:,:), vIDs(:)
    real(ESMF_KIND_R8), allocatable :: lonC(:), latC(:), lonV(:), latV(:)
    real(ESMF_KIND_R8) :: dx, dy, lat0
    integer :: i, j, c, k, nloc, first, last, nvx, irc

    dx = 360.0_ESMF_KIND_R8 / nx; lat0 = -88.0_ESMF_KIND_R8; dy = 176.0_ESMF_KIND_R8 / ny
    first = localPet * (nx*ny) / petCount + 1
    last  = (localPet + 1) * (nx*ny) / petCount
    nloc  = last - first + 1
    allocate(cellIDs(nloc), nEdges(nloc), voc(6, nloc), lonC(nloc), latC(nloc))
    nEdges = 4; voc = 0
    nvx = nx * (ny + 1)                               ! vértices: (i, j) com i periódico
    do c = first, last
      k = c - first + 1
      j = (c - 1) / nx + 1; i = c - (j - 1) * nx
      cellIDs(k) = c
      voc(1:4, k) = [vid(nx, i, j), vid(nx, i+1, j), vid(nx, i+1, j+1), vid(nx, i, j+1)]
      lonC(k) = ((i - 0.5_ESMF_KIND_R8) * dx) * D2R
      latC(k) = (lat0 + (j - 0.5_ESMF_KIND_R8) * dy) * D2R
    end do
    allocate(vIDs(nvx), lonV(nvx), latV(nvx))
    do j = 1, ny + 1
      do i = 1, nx
        k = vid(nx, i, j)
        vIDs(k) = k
        lonV(k) = ((i - 1) * dx) * D2R
        latV(k) = (lat0 + (j - 1) * dy) * D2R
      end do
    end do
    call mpas_mesh_create(cellIDs, nEdges, voc, lonC, latC, vIDs, lonV, latV, m, irc)
    if (irc /= ESMF_SUCCESS) call report('mpas_mesh_create', .false.)
  end subroutine make_quad_mesh

  !> Identificador do vértice (i, j), com i periódico.
  pure integer function vid(nx, i, j)
    integer, intent(in) :: nx, i, j
    vid = mod(i - 1, nx) + 1 + (j - 1) * nx
  end function vid

  subroutine set_analytic_mesh(f, m)
    type(ESMF_Field), intent(inout) :: f
    type(ESMF_Mesh),  intent(in)    :: m
    real(ESMF_KIND_R8), pointer :: p(:)
    real(ESMF_KIND_R8), allocatable :: coords(:)
    integer :: n, irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    n = size(p)
    allocate(coords(2*n))
    call ESMF_MeshGet(m, ownedElemCoords=coords, rc=irc)
    p = analytic(coords(1::2), coords(2::2))
  end subroutine set_analytic_mesh

  function mpassit_spec() result(spec)
    type(regrid_spec_t) :: spec
    spec%scheme = 'mpassit'
    spec%field_class = 'continuous'
    spec%fill%vfill = -999.0_ESMF_KIND_R8
  end function mpassit_spec

  !> Dentro da faixa coberta pela malha o erro é pequeno; perto dos polos,
  !! fora dela, o destino recebe o valor de ausência.
  logical function mpassit_ok(f, g)
    type(ESMF_Field), intent(in) :: f
    type(ESMF_Grid),  intent(in) :: g
    real(ESMF_KIND_R8), pointer :: p(:,:), x(:,:), y(:,:)
    integer :: irc
    call ESMF_FieldGet(f, farrayPtr=p, rc=irc)
    call ESMF_GridGetCoord(g, 1, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=x, rc=irc)
    call ESMF_GridGetCoord(g, 2, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=y, rc=irc)
    mpassit_ok = maxval(abs(p - analytic(x, y)), mask=abs(y) < 85.0_ESMF_KIND_R8) < 5.0e-3_ESMF_KIND_R8
    if (any(abs(y) > 89.0_ESMF_KIND_R8)) &
      mpassit_ok = mpassit_ok .and. all(p == -999.0_ESMF_KIND_R8 .or. abs(y) < 89.0_ESMF_KIND_R8)
  end function mpassit_ok

end program test_regrid
