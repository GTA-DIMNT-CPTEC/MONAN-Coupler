! Teste de regressão dos gravadores de diagnóstico: med_write_import_fields,
! write_mpas_import_diag, export_write_netcdf e WriteDOCNDiag, com dados sintéticos e vários
! PETs. Ligado uma
! vez com os objetos antigos e uma vez com os novos; os arquivos gravados
! têm de ser idênticos. Executado por tests/writers/compara-gravadores.bash,
! com um número par de processos (a grade é dividida em 2 x NP/2).
program test_writers
  use ESMF
  use mpi
  use med_cap_types_mod, only : MED_InternalState
  use med_init_mod, only : create_internal_fields
  use med_cap_netcdf_mod, only : med_write_import_fields
  use mpas_atm_types_mod, only : atm_ocean_boundary_type, MPAS_RKIND
  use mpas_import_diag_mod, only : write_mpas_import_diag, set_mpas_diag_clock, &
                                  mpas_import_diag_clock_t
  use mpas_cap_netcdf_mod, only : mpas_diag_export_t, netcdf_config_set, &
                                  netcdf_init_coords, netcdf_push_raw_field, &
                                  export_write_netcdf
  use docn_cap_netcdf_mod, only : WriteDOCNDiag
  use coupler_config_mod, only : config_read
  use netcdf
  implicit none

  ! export_names e n_export: os 31 campos exportados pelo mediador, na ordem
  ! de antes da R-FASE11-05 (desde então eles saem do mapa de acoplamento)
  include '../unit/listas_mediador.inc'

  type(ESMF_VM) :: vm
  type(ESMF_Grid) :: grid
  type(ESMF_State) :: expState
  type(ESMF_Time) :: t1, t2
  type(MED_InternalState), pointer :: is
  type(ESMF_Field) :: fld
  type(atm_ocean_boundary_type) :: bnd
  type(mpas_import_diag_clock_t) :: clk
  real(MPAS_RKIND), allocatable :: lonc(:), latc(:)
  integer :: rc, localPet, petCount, comm, k, n, nloc, i0
  character(len=32) :: nm

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, mpiCommunicator=comm, rc=rc)

  ! log_level='debug': a mensagem da máscara do diagnóstico do mediador é de
  ! depuração desde a R-FASE13-10
  if (localPet == 0) then
    open(newunit=k, file='debug.nml', status='replace', action='write')
    write(k,'(A)') '&nuopc_driver'
    write(k,'(A)') "  log_level = 'debug'"
    write(k,'(A)') '/'
    close(k)
  end if
  call ESMF_VMBarrier(vm, rc=rc)
  call config_read(rc, 'debug.nml')

  ! ── mediador ─────────────────────────────────────────────────────────
  allocate(is)
  is%diag%write_import = .true.
  is%diag%import_dir   = 'out_med'
  is%par%comm  = comm
  is%par%local_pet = localPet
  is%par%pet_count = petCount

  grid = ESMF_GridCreateNoPeriDim(maxIndex=[360,180], regDecomp=[2,petCount/2], &
           indexflag=ESMF_INDEX_GLOBAL, rc=rc)
  ! Os campos internos são criados como no mediador e depois recebem os
  ! valores sintéticos (mk, mkmask), na mesma ordem de antes.
  call create_internal_fields(is, grid, rc)
  k = 0
  call mk(is%ocn_flx%taux);  call mk(is%ocn_flx%tauy);  call mk(is%ocn_flx%sen);  call mk(is%ocn_flx%evap)
  call mk(is%ocn_flx%lwnet); call mk(is%ocn_flx%swvdr); call mk(is%ocn_flx%swvdf)
  call mk(is%ocn_flx%swidr); call mk(is%ocn_flx%swidf)
  call mk(is%ocn_flx%rain);  call mk(is%ocn_flx%snow);  call mk(is%ocn_flx%pslv)
  call mk(is%ice%ifrac); call mk(is%ocn_flx%duu10n); call mk(is%ocn%sst)
  call mk(is%ocn%u);  call mk(is%ocn%v);  call mk(is%sfc%zorl)
  call mk(is%sfc%albedo); call mk(is%sfc%coszen)
  call mk(is%ice%taux);  call mk(is%ice%tauy);  call mk(is%ice%sen)
  call mk(is%ice%evap);  call mk(is%ice%lwnet)
  call mk(is%ice%swvdr); call mk(is%ice%swvdf); call mk(is%ice%swidr); call mk(is%ice%swidf)
  call mk(is%sfc%tsfc)
  call mkmask(is%ocn%omask)

  expState = ESMF_StateCreate(name='exp', rc=rc)
  do n = 1, n_export + 1
    if (n <= n_export) then
      nm = export_names(n)
    else
      nm = 'Xx_sem_mapeamento'
    end if
    fld = ESMF_FieldCreate(grid, typekind=ESMF_TYPEKIND_R8, name=trim(nm), rc=rc)
    call ESMF_StateAdd(expState, [fld], rc=rc)
  end do

  call ESMF_TimeSet(t1, yy=2026, mm=3, dd=29, h=1, m=0, s=0, rc=rc)
  call ESMF_TimeSet(t2, yy=2026, mm=3, dd=29, h=2, m=30, s=0, rc=rc)
  call med_write_import_fields(expState, t1, is, rc)
  call med_write_import_fields(expState, t2, is, rc)

  ! ── cap atmosférico ──────────────────────────────────────────────────
  nloc = 700 + 37*localPet
  i0 = 0
  do n = 0, localPet - 1
    i0 = i0 + 700 + 37*n
  end do
  allocate(lonc(nloc), latc(nloc))
  allocate(bnd%sst(nloc), bnd%ice_fraction(nloc), bnd%uocn(nloc), bnd%vocn(nloc), &
           bnd%zorl(nloc), bnd%alb(nloc), bnd%omask(nloc))
  do n = 1, nloc
    k = i0 + n
    lonc(n) = real(mod(k*7919, 62832), MPAS_RKIND) * 1.0e-4_MPAS_RKIND
    latc(n) = asin(real(mod(k*104729, 20000) - 10000, MPAS_RKIND) * 1.0e-4_MPAS_RKIND)
    bnd%sst(n)          = 268.0_MPAS_RKIND + 0.013_MPAS_RKIND * mod(k, 3500)
    bnd%ice_fraction(n) = mod(k, 23) / 20.0_MPAS_RKIND
    bnd%uocn(n)         = sin(real(k, MPAS_RKIND)) * 6.0_MPAS_RKIND
    bnd%vocn(n)         = cos(real(k, MPAS_RKIND)) * 3.0_MPAS_RKIND
    bnd%zorl(n)         = 1.0e-4_MPAS_RKIND * (1 + mod(k, 50))
    bnd%alb(n)          = 0.06_MPAS_RKIND + 0.01_MPAS_RKIND * mod(k, 90)
    bnd%omask(n)        = merge(1.0_MPAS_RKIND, 0.0_MPAS_RKIND, mod(k, 5) /= 0)
  end do
  call set_mpas_diag_clock(clk, 2026, 3, 29, 1, 0, 0)
  call write_mpas_import_diag(clk, bnd, nloc, lonc, latc, rc)
  deallocate(bnd%alb, bnd%omask)
  call set_mpas_diag_clock(clk, 2026, 3, 29, 2, 0, 0)
  call write_mpas_import_diag(clk, bnd, nloc, lonc, latc, rc)
  call export_cases(nloc, lonc, latc, i0)

  ! ── oceano de dados (DOCN) ───────────────────────────────────────────
  call docn_cases()

  call ESMF_Finalize(rc=rc)

contains

  !> Casos do export_write_netcdf (monan_export_*.nc, em out_mpas_export):
  !! grade de saída de 2°, coordenadas reunidas por netcdf_init_coords, dois
  !! campos guardados por netcdf_push_raw_field (um com valor acima do limiar
  !! de descarte) e um campo sem dado guardado, lido do exportState (caminho
  !! de reserva). Duas escritas, a segunda com o campo guardado atualizado.
  subroutine export_cases(n, lon_rad, lat_rad, ioff)
    integer,          intent(in) :: n, ioff
    real(MPAS_RKIND), intent(in) :: lon_rad(:), lat_rad(:)
    type(mpas_diag_export_t) :: dx
    type(ESMF_State) :: est
    type(ESMF_Field) :: f3(3)
    real(ESMF_KIND_R8), allocatable :: lond(:), latd(:), v1(:), v2(:)
    real(ESMF_KIND_R8), pointer :: p(:,:)
    character(len=16), parameter :: names3(3) = &
      [character(len=16) :: 'Sa_pslv_mpas', 'Faxa_swdn_mpas', 'Sa_tbot_mpas']
    integer :: m, i, j

    allocate(lond(n), latd(n), v1(n), v2(n))
    lond = real(lon_rad(1:n), ESMF_KIND_R8) * 180.0_ESMF_KIND_R8 / acos(-1.0_ESMF_KIND_R8)
    latd = real(lat_rad(1:n), ESMF_KIND_R8) * 180.0_ESMF_KIND_R8 / acos(-1.0_ESMF_KIND_R8)
    do m = 1, n
      v1(m) = 101325.0_ESMF_KIND_R8 + 900.0_ESMF_KIND_R8 * sin(0.013_ESMF_KIND_R8 * (ioff + m))
      v2(m) = max(0.0_ESMF_KIND_R8, 1000.0_ESMF_KIND_R8 * cos(0.021_ESMF_KIND_R8 * (ioff + m)))
      if (mod(ioff + m, 211) == 0) v2(m) = 5.0e4_ESMF_KIND_R8   ! descartado pelo limiar
    end do

    call netcdf_config_set(dx, 2.0, 'out_mpas_export', localPet)
    call netcdf_init_coords(dx, lond, latd, n, vm, rc)

    est = ESMF_StateCreate(name='exp_mpas', rc=rc)
    do m = 1, 3
      f3(m) = ESMF_FieldCreate(grid, typekind=ESMF_TYPEKIND_R8, name=trim(names3(m)), rc=rc)
      call ESMF_FieldGet(f3(m), farrayPtr=p, rc=rc)
      do j = lbound(p,2), ubound(p,2)
        do i = lbound(p,1), ubound(p,1)
          p(i,j) = 250.0_ESMF_KIND_R8 + 0.1_ESMF_KIND_R8 * i + 0.2_ESMF_KIND_R8 * j + m
        end do
      end do
      call ESMF_StateAdd(est, [f3(m)], rc=rc)
    end do

    call netcdf_push_raw_field(dx, 'Sa_pslv_mpas', v1, n, vm, rc)
    call netcdf_push_raw_field(dx, 'Faxa_swdn_mpas', v2, n, vm, rc)
    call export_write_netcdf(dx, est, 3600, 2026, 3, 29, 1, 0, 0, vm, rc)
    v1 = v1 + 7.5_ESMF_KIND_R8
    call netcdf_push_raw_field(dx, 'Sa_pslv_mpas', v1, n, vm, rc)
    call export_write_netcdf(dx, est, 7200, 2026, 3, 29, 2, 0, 0, vm, rc)
    deallocate(lond, latd, v1, v2)
  end subroutine export_cases

  subroutine mk(f)
    type(ESMF_Field), intent(inout) :: f
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: i, j
    k = k + 1
    call ESMF_FieldGet(f, farrayPtr=p, rc=rc)
    do j = lbound(p,2), ubound(p,2)
      do i = lbound(p,1), ubound(p,1)
        p(i,j) = sin(0.01_ESMF_KIND_R8*i*k) * cos(0.02_ESMF_KIND_R8*j) * 100.0_ESMF_KIND_R8 + k
        if (mod(i*j + k, 997) == 0) p(i,j) = ieee_nan()
      end do
    end do
  end subroutine mk

  subroutine mkmask(f)
    type(ESMF_Field), intent(inout) :: f
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: i, j
    call ESMF_FieldGet(f, farrayPtr=p, rc=rc)
    do j = lbound(p,2), ubound(p,2)
      do i = lbound(p,1), ubound(p,1)
        p(i,j) = merge(1.0_ESMF_KIND_R8, 0.0_ESMF_KIND_R8, mod(i/13 + j/7, 3) /= 0)
      end do
    end do
  end subroutine mkmask

  !> Casos do WriteDOCNDiag. A configuração vem de arquivos &nuopc_docn
  !! gravados aqui e lidos por config_read; os dados, de arquivos NetCDF
  !! sintéticos na grade 36 x 18. Casos: (1) sem correntes, gelo em fração,
  !! dimensão de tempo 'time' no gelo; (2) com correntes (valores >= 10
  !! descartados), gelo em porcentagem, dimensão 'Time' no gelo e 'TIME'
  !! na SST, outro dt_data; (3) arquivo de SST ausente (só o aviso no log).
  subroutine docn_cases()
    integer, parameter :: NXD = 36, NYD = 18
    type(ESMF_GridComp) :: gc
    type(ESMF_Time) :: td
    integer :: ierr

    gc = ESMF_GridCompCreate(name='docn_teste', rc=rc)
    if (localPet == 0) then
      call create_nc('in_sst_1.nc', 'time', ['sst '], 4, 1)
      call create_nc('in_ice_1.nc', 'time', ['icec'], 4, 2)
      call create_nc('in_sst_2.nc', 'TIME', ['sst '], 5, 1)
      call create_nc('in_ice_2.nc', 'Time', ['icec'], 3, 3)
      call create_nc('in_cur_2.nc', 'time', ['uo  ', 'vo  '], 2, 4)
      call nml('docn_1.nml', 'in_sst_1.nc', 'in_ice_1.nc', '', 86400, '.false.')
      call nml('docn_2.nml', 'in_sst_2.nc', 'in_ice_2.nc', 'in_cur_2.nc', 43200, '.true.')
      call nml('docn_3.nml', 'nao_existe.nc', 'in_ice_1.nc', '', 86400, '.false.')
    end if
    call MPI_Barrier(comm, ierr)

    call config_read(rc, 'docn_1.nml')
    call ESMF_TimeSet(td, yy=2026, mm=3, dd=29, h=6, m=0, s=0, rc=rc)
    call WriteDOCNDiag(gc, td, NXD, NYD, rc)
    call config_read(rc, 'docn_2.nml')
    call ESMF_TimeSet(td, yy=2026, mm=3, dd=29, h=10, m=30, s=0, rc=rc)
    call WriteDOCNDiag(gc, td, NXD, NYD, rc)
    call config_read(rc, 'docn_3.nml')
    call ESMF_TimeSet(td, yy=2026, mm=3, dd=29, h=12, m=0, s=0, rc=rc)
    call WriteDOCNDiag(gc, td, NXD, NYD, rc)
  end subroutine docn_cases

  !> Grava um arquivo &nuopc_docn para config_read.
  subroutine nml(fname, sst, ice, cur, dt_data, ice_pct)
    character(len=*), intent(in) :: fname, sst, ice, cur, ice_pct
    integer,          intent(in) :: dt_data
    integer :: u
    open(newunit=u, file=fname, status='replace', action='write')
    write(u,'(A)') '&nuopc_docn'
    write(u,'(3A)') "  docn_sst_file = '", sst, "'"
    write(u,'(3A)') "  docn_ice_file = '", ice, "'"
    write(u,'(3A)') "  docn_cur_file = '", cur, "'"
    write(u,'(A,I0)') '  docn_dt_data = ', dt_data
    write(u,'(A)') '  docn_epoch_year = 2026, docn_epoch_month = 3, docn_epoch_day = 27'
    write(u,'(2A)') '  docn_ice_pct = ', ice_pct
    write(u,'(A)') "  import_diag_dir = 'out_docn'"
    write(u,'(A)') '/'
    close(u)
  end subroutine nml

  !> Grava um arquivo NetCDF (lon, lat, tempo) com as variáveis pedidas.
  !! tipo 1: SST em graus Celsius; 2: fração de gelo; 3: gelo em %;
  !! 4: correntes. Todos com alguns pontos de valor ausente (1e20).
  subroutine create_nc(fname, tdim, vars, nt, var_type)
    character(len=*), intent(in) :: fname, tdim
    character(len=*), intent(in) :: vars(:)
    integer,          intent(in) :: nt, var_type
    integer, parameter :: NXD = 36, NYD = 18
    integer :: ncid, dx, dy, dt, v, vid, i, j, t, st
    real(ESMF_KIND_R8) :: a(NXD, NYD, nt)
    st = nf90_create(fname, NF90_CLOBBER, ncid)
    st = nf90_def_dim(ncid, 'lon', NXD, dx)
    st = nf90_def_dim(ncid, 'lat', NYD, dy)
    st = nf90_def_dim(ncid, tdim, nt, dt)
    do v = 1, size(vars)
      st = nf90_def_var(ncid, trim(vars(v)), NF90_DOUBLE, [dx, dy, dt], vid)
    end do
    st = nf90_enddef(ncid)
    do v = 1, size(vars)
      do t = 1, nt
        do j = 1, NYD
          do i = 1, NXD
            select case (var_type)
            case (1); a(i,j,t) = 28.0d0*cos(0.17d0*(j-9.5d0)) - 1.8d0 + 0.3d0*t + 0.01d0*i
            case (2); a(i,j,t) = max(0.0d0, min(1.0d0, (abs(j-9.5d0) - 6.0d0)/3.0d0 + 0.05d0*t))
            case (3); a(i,j,t) = max(0.0d0, min(100.0d0, (abs(j-9.5d0) - 6.0d0)*35.0d0 + t + 0.5d0*i))
            case default; a(i,j,t) = (3.0d0*v + t)*sin(0.3d0*i)*cos(0.2d0*j) + 0.1d0*v
            end select
            if (mod(i*7 + j*3 + t + v, 29) == 0) a(i,j,t) = 1.0d20
          end do
        end do
      end do
      st = nf90_inq_varid(ncid, trim(vars(v)), vid)
      st = nf90_put_var(ncid, vid, a)
    end do
    st = nf90_close(ncid)
  end subroutine create_nc

  real(ESMF_KIND_R8) function ieee_nan()
    use, intrinsic :: ieee_arithmetic
    ieee_nan = ieee_value(1.0_ESMF_KIND_R8, ieee_quiet_nan)
  end function ieee_nan
end program test_writers
