! Teste de regressão dos gravadores de diagnóstico: med_write_import_fields
! e write_mpas_import_diag, com dados sintéticos e vários PETs. Ligado uma
! vez com os objetos antigos e uma vez com os novos; os arquivos gravados
! têm de ser idênticos. Executado por tests/writers/compara-gravadores.bash,
! com um número par de processos (a grade é dividida em 2 x NP/2).
program test_writers
  use ESMF
  use mpi
  use med_cap_types_mod
  use med_cap_netcdf_mod, only : med_write_import_fields
  use mpas_atm_types_mod, only : atm_ocean_boundary_type, MPAS_RKIND
  use mpas_cap_netcdf_mod, only : write_mpas_import_diag, set_mpas_diag_clock
  implicit none

  type(ESMF_VM) :: vm
  type(ESMF_Grid) :: grid
  type(ESMF_State) :: expState
  type(ESMF_Time) :: t1, t2
  type(MED_InternalState) :: is
  type(ESMF_Field) :: fld
  type(atm_ocean_boundary_type) :: bnd
  real(MPAS_RKIND), allocatable :: lonc(:), latc(:)
  integer :: rc, localPet, petCount, comm, k, n, nloc, i0
  character(len=32) :: nm

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, mpiCommunicator=comm, rc=rc)

  ! ── mediador ─────────────────────────────────────────────────────────
  med_write_import_diag = .true.
  med_import_diag_dir   = 'out_med'
  med_mpi_comm  = comm
  med_local_pet = localPet
  med_pet_count = petCount

  grid = ESMF_GridCreateNoPeriDim(maxIndex=[360,180], regDecomp=[2,petCount/2], &
           indexflag=ESMF_INDEX_GLOBAL, rc=rc)
  k = 0
  call mk(is%f_taux_atm);  call mk(is%f_tauy_atm);  call mk(is%f_sen_atm);  call mk(is%f_evap_atm)
  call mk(is%f_lwnet_atm); call mk(is%f_swvdr_atm); call mk(is%f_swvdf_atm)
  call mk(is%f_swidr_atm); call mk(is%f_swidf_atm)
  call mk(is%f_rain_atm);  call mk(is%f_snow_atm);  call mk(is%f_pslv_atm)
  call mk(is%f_ifrac_atm); call mk(is%f_duu10n_atm); call mk(is%f_sst_atm)
  call mk(is%f_uocn_atm);  call mk(is%f_vocn_atm);  call mk(is%f_zorl_atm)
  call mk(is%f_albedo_atm); call mk(is%f_coszen_atm)
  call mk(is%f_taux_ice);  call mk(is%f_tauy_ice);  call mk(is%f_sen_ice)
  call mk(is%f_evap_ice);  call mk(is%f_lwnet_ice)
  call mk(is%f_swvdr_ice); call mk(is%f_swvdf_ice); call mk(is%f_swidr_ice); call mk(is%f_swidf_ice)
  call mk(is%f_tsfc_atm)
  call mkmask(is%f_omask_atm)

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
  call set_mpas_diag_clock(2026, 3, 29, 1, 0, 0)
  call write_mpas_import_diag(bnd, nloc, lonc, latc, rc)
  deallocate(bnd%alb, bnd%omask)
  call set_mpas_diag_clock(2026, 3, 29, 2, 0, 0)
  call write_mpas_import_diag(bnd, nloc, lonc, latc, rc)

  call ESMF_Finalize(rc=rc)

contains

  subroutine mk(f)
    type(ESMF_Field), intent(out) :: f
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: i, j
    k = k + 1
    f = ESMF_FieldCreate(grid, typekind=ESMF_TYPEKIND_R8, rc=rc)
    call ESMF_FieldGet(f, farrayPtr=p, rc=rc)
    do j = lbound(p,2), ubound(p,2)
      do i = lbound(p,1), ubound(p,1)
        p(i,j) = sin(0.01_ESMF_KIND_R8*i*k) * cos(0.02_ESMF_KIND_R8*j) * 100.0_ESMF_KIND_R8 + k
        if (mod(i*j + k, 997) == 0) p(i,j) = ieee_nan()
      end do
    end do
  end subroutine mk

  subroutine mkmask(f)
    type(ESMF_Field), intent(out) :: f
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: i, j
    f = ESMF_FieldCreate(grid, typekind=ESMF_TYPEKIND_R8, rc=rc)
    call ESMF_FieldGet(f, farrayPtr=p, rc=rc)
    do j = lbound(p,2), ubound(p,2)
      do i = lbound(p,1), ubound(p,1)
        p(i,j) = merge(1.0_ESMF_KIND_R8, 0.0_ESMF_KIND_R8, mod(i/13 + j/7, 3) /= 0)
      end do
    end do
  end subroutine mkmask

  real(ESMF_KIND_R8) function ieee_nan()
    use, intrinsic :: ieee_arithmetic
    ieee_nan = ieee_value(1.0_ESMF_KIND_R8, ieee_quiet_nan)
  end function ieee_nan
end program test_writers
