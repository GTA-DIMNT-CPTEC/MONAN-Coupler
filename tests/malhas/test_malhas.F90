!> @file test_malhas.F90
!! @brief Grava as coordenadas das malhas regulares do lado atmosférico.
!!
!! Cria a malha de fluxo do mediador (create_atm_grid, de med_init) e a
!! grade do cap do MONAN-A (mpas_create_grid, de mpas_cap_methods), as duas
!! 360 x 180, e grava, em saida_<PET>.bin, para cada DE local: os limites
!! computacionais e os limites e valores dos vetores de coordenadas dos
!! centros (as duas malhas) e dos cantos (só a do mediador). Usa só as
!! interfaces que essas rotinas tinham antes de cpl_grids, para que o mesmo
!! programa sirva às duas versões comparadas por compara-malhas.bash.
program test_malhas
  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY
  use med_init_mod,          only : create_atm_grid
  use mpas_cap_methods_mod,  only : mpas_create_grid
  implicit none

  type(ESMF_VM)   :: vm
  type(ESMF_Grid) :: grade_med, grade_cap
  integer :: rc, localPet, petCount, un
  character(len=32) :: arquivo

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, &
                       defaultLogFileName='teste_malhas', &
                       logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 'ESMF_Initialize'
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)

  rc = ESMF_SUCCESS
  call create_atm_grid(petCount, ATM_NX, ATM_NY, grade_med, rc)
  if (rc /= ESMF_SUCCESS) error stop 'create_atm_grid'
  call mpas_create_grid(grade_cap, rc)
  if (rc /= ESMF_SUCCESS) error stop 'mpas_create_grid'

  write(arquivo, '(A,I0,A)') 'saida_', localPet, '.bin'
  open(newunit=un, file=trim(arquivo), access='stream', form='unformatted', status='replace')
  call grava(un, grade_med, ESMF_STAGGERLOC_CENTER)
  call grava(un, grade_med, ESMF_STAGGERLOC_CORNER)
  call grava(un, grade_cap, ESMF_STAGGERLOC_CENTER)
  close(un)

  call ESMF_Finalize(rc=rc)

contains

  !> Para cada DE local: limites computacionais, limites do vetor e valores,
  !! das duas coordenadas.
  subroutine grava(un, grade, stagger)
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
  end subroutine grava

end program test_malhas
