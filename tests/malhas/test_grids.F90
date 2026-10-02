!> @file test_grids.F90
!! @brief Grava as coordenadas das malhas do mediador e do cap atmosférico.
!!
!! Cria, e grava em saida_<PET>.bin, para cada DE local, os limites
!! computacionais e os limites e valores dos vetores de coordenadas:
!!
!!   atm_med   malha de fluxo do mediador (create_atm_grid, de med_init),
!!             360 x 180, centros e cantos
!!   atm_cap   grade do cap do MONAN-A (mpas_create_grid), 360 x 180, centros
!!   ocn_med   oceano no mediador (create_ocn_grid, de med_init) com o MOM6,
!!             lida do supergrid sintético hgrid.nc (grade T de 10 x 7),
!!             centros, cantos e máscara (configuração mom6.nml)
!!   ocn_med   o mesmo com o DOCN, grade regular de 36 x 18 (docn.nml)
!!
!! Usa só as interfaces que essas rotinas tinham antes de cpl_grids, para
!! que o mesmo programa sirva às duas versões comparadas por
!! compara-malhas.bash. Desde a R-FASE11-24, mpas_create_grid está no
!! adaptador do MPAS (mpas_adapter_mod); o script compila com
!! -DCOM_ADAPTADOR a versão que o tem. O hgrid.nc vem de tests/supergrid/gera-supergrid.py.
program test_grids
  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY
  use med_init_mod,          only : create_atm_grid
#ifdef COM_ADAPTADOR
  use mpas_adapter_mod,      only : mpas_create_grid
#else
  use mpas_cap_methods_mod,  only : mpas_create_grid
#endif
  use med_init_mod,          only : create_ocn_grid
  use coupler_config_mod,    only : config_read
  use mom6_supergrid_mod,    only : mom6_supergrid_dims
  implicit none

  type(ESMF_VM)   :: vm
  type(ESMF_Grid) :: med_grid, cap_grid, ocn_grid, docn_grid
  integer :: rc, localPet, petCount, un, nx, ny
  character(len=32) :: file_name

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, &
                       defaultLogFileName='teste_malhas', &
                       logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 'ESMF_Initialize'
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)

  rc = ESMF_SUCCESS
  call create_atm_grid(petCount, ATM_NX, ATM_NY, med_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'create_atm_grid'
  call mpas_create_grid(cap_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'mpas_create_grid'

  ! Oceano no mediador com o MOM6 (supergrid sintético) e com o DOCN
  if (localPet == 0) then
    call write_nml('mom6.nml', '.false.')
    call write_nml('docn.nml', '.true.')
  end if
  call ESMF_VMBarrier(vm, rc=rc)
  call config_read(rc, 'mom6.nml')
  if (rc /= ESMF_SUCCESS) error stop 'config_read mom6.nml'
  call mom6_supergrid_dims('hgrid.nc', nx, ny, rc)
  if (rc /= ESMF_SUCCESS) error stop 'mom6_supergrid_dims'
  rc = ESMF_SUCCESS
  call create_ocn_grid(petCount, nx, ny, ocn_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'create_ocn_grid (MOM6)'
  call config_read(rc, 'docn.nml')
  if (rc /= ESMF_SUCCESS) error stop 'config_read docn.nml'
  rc = ESMF_SUCCESS
  call create_ocn_grid(petCount, 36, 18, docn_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'create_ocn_grid (DOCN)'

  write(file_name, '(A,I0,A)') 'saida_', localPet, '.bin'
  open(newunit=un, file=trim(file_name), access='stream', form='unformatted', status='replace')
  call write_grid(un, med_grid, ESMF_STAGGERLOC_CENTER)
  call write_grid(un, med_grid, ESMF_STAGGERLOC_CORNER)
  call write_grid(un, cap_grid, ESMF_STAGGERLOC_CENTER)
  call write_grid(un, ocn_grid, ESMF_STAGGERLOC_CENTER)
  call write_grid(un, ocn_grid, ESMF_STAGGERLOC_CORNER)
  call write_mask(un, ocn_grid)
  call write_grid(un, docn_grid, ESMF_STAGGERLOC_CENTER)
  call write_grid(un, docn_grid, ESMF_STAGGERLOC_CORNER)
  call write_mask(un, docn_grid)
  close(un)

  call ESMF_Finalize(rc=rc)

contains

  !> Configuração com use_docn dado, o supergrid sintético e a grade do DOCN.
  subroutine write_nml(file_name, use_docn)
    character(len=*), intent(in) :: file_name, use_docn
    integer :: u
    open(newunit=u, file=file_name, status='replace', action='write')
    write(u,'(A)') '&nuopc_mode'
    write(u,'(2A)') '  use_docn = ', use_docn
    write(u,'(A)') '/'
    write(u,'(A)') '&nuopc_docn'
    write(u,'(A)') '  docn_nx = 36, docn_ny = 18'
    write(u,'(A)') '/'
    write(u,'(A)') '&nuopc_ocn'
    write(u,'(A)') "  mesh_ocn = 'hgrid.nc'"
    write(u,'(A)') '/'
    close(u)
  end subroutine write_nml

  !> Para cada DE local: limites e valores do item de máscara (centros).
  subroutine write_mask(un, grade)
    integer,         intent(in) :: un
    type(ESMF_Grid), intent(in) :: grade
    integer(ESMF_KIND_I4), pointer :: m(:,:)
    integer :: nde, lde, rc

    call ESMF_GridGet(grade, localDeCount=nde, rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'ESMF_GridGet'
    write(un) nde
    do lde = 0, nde - 1
      nullify(m)
      call ESMF_GridGetItem(grade, itemflag=ESMF_GRIDITEM_MASK, staggerloc=ESMF_STAGGERLOC_CENTER, &
                            localDE=lde, farrayPtr=m, rc=rc)
      if (rc /= ESMF_SUCCESS) error stop 'ESMF_GridGetItem'
      write(un) lde, lbound(m), ubound(m)
      write(un) m
    end do
  end subroutine write_mask

  !> Para cada DE local: limites computacionais, limites do vetor e valores,
  !! das duas coordenadas.
  subroutine write_grid(un, grade, stagger)
    integer,                intent(in) :: un
    type(ESMF_Grid),        intent(in) :: grade
    type(ESMF_StaggerLoc),  intent(in) :: stagger
    real(ESMF_KIND_R8), pointer :: c(:,:)
    integer :: nde, lde, dim, clb(2), cub(2), rc

    call ESMF_GridGet(grade, localDeCount=nde, rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'ESMF_GridGet'
    write(un) nde
    do lde = 0, nde - 1
      do dim = 1, 2
        nullify(c)
        call ESMF_GridGetCoord(grade, coordDim=dim, localDE=lde, staggerloc=stagger, &
                               computationalLBound=clb, computationalUBound=cub, &
                               farrayPtr=c, rc=rc)
        if (rc /= ESMF_SUCCESS) error stop 'ESMF_GridGetCoord'
        write(un) lde, dim, clb, cub, lbound(c), ubound(c)
        write(un) c
      end do
    end do
  end subroutine write_grid

end program test_grids
