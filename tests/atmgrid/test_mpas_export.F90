!> @file test_mpas_export.F90
!! @brief Teste de regressão da passagem das células MPAS para a grade
!! regular 360x180 do cap atmosférico (mpas_export).
!!
!! Cria a grade do cap (mpas_create_grid) e três campos de exportação,
!! monta células MPAS sintéticas em cada PET e chama mpas_export duas
!! vezes. Cada chamada passa por state_set_field_1d e
!! map_cells_to_regular_grid: soma e contagem por caixa de 1 grau, soma
!! reprodutível entre PETs, média, preenchimento das caixas vazias e cópia
!! para a porção local da grade. Os campos são reunidos no PET 0 e gravados
!! em binário; o log do ESMF guarda as mensagens de diagnóstico.
!!
!! As células sintéticas são deterministas e desiguais entre PETs: cada PET
!! cobre uma faixa de longitude com densidade própria, há caixas com células
!! de até três PETs (a ordem da soma entre PETs afeta o último bit) e lacunas
!! que o preenchimento tem de fechar.
program test_mpas_export
  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY
  use mpas_atm_types_mod,    only : mpas_atm_public_type, MPAS_RKIND
  use mpas_cap_methods_mod,  only : mpas_export, mpas_create_grid
  implicit none

  integer, parameter :: NCAMPOS = 3
  character(len=16), parameter :: nomes(NCAMPOS) = &
    [character(len=16) :: 'Sa_pslv_mpas', 'Sa_u10m_mpas', 'Faxa_swdn_mpas']
  type(ESMF_VM)    :: vm
  type(ESMF_Grid)  :: grid
  type(ESMF_State) :: expst
  type(ESMF_Field) :: campo(NCAMPOS)
  type(mpas_atm_public_type) :: pub
  real(ESMF_KIND_R8), allocatable :: glob(:,:)
  integer :: rc, localPet, petCount, n, k, i, chamada, u
  real(ESMF_KIND_R8) :: lon0, lon1, x
  character(len=64) :: arq

  call ESMF_Initialize(defaultLogFileName='teste_grade_atm', &
    logkindflag=ESMF_LOGKIND_MULTI, vm=vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)

  call mpas_create_grid(grid, rc)
  if (rc /= ESMF_SUCCESS) call ESMF_Finalize(endflag=ESMF_END_ABORT)
  expst = ESMF_StateCreate(name='export', rc=rc)
  do k = 1, NCAMPOS
    campo(k) = ESMF_FieldCreate(grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(nomes(k)), rc=rc)
    call ESMF_StateAdd(expst, [campo(k)], rc=rc)
  end do

  ! Células sintéticas: o PET p cobre a faixa [p*360/P - 60, (p+1)*360/P + 60)
  ! de longitude, em sequência quase aleatória (razão áurea) própria do PET;
  ! latitude entre -89,7 e 89,7.
  n = 6000 + 1500 * localPet
  pub%nCells = n
  pub%nCellsSolve = n
  allocate(pub%lonCell(n), pub%latCell(n), pub%pslv(n), pub%u10(n), pub%swdn_sfc(n))
  lon0 = real(localPet, ESMF_KIND_R8) * 360.0_ESMF_KIND_R8 / petCount - 60.0_ESMF_KIND_R8
  lon1 = real(localPet + 1, ESMF_KIND_R8) * 360.0_ESMF_KIND_R8 / petCount + 60.0_ESMF_KIND_R8
  do i = 1, n
    x = modulo(real(i, ESMF_KIND_R8) * 0.618033988749895_ESMF_KIND_R8 + 0.2113_ESMF_KIND_R8 * localPet, &
               1.0_ESMF_KIND_R8)
    pub%lonCell(i) = real((lon0 + (lon1 - lon0) * x) &
                     * acos(-1.0_ESMF_KIND_R8) / 180.0_ESMF_KIND_R8, MPAS_RKIND)
    x = modulo(real(i, ESMF_KIND_R8) * 0.754877666246693_ESMF_KIND_R8 + 0.3871_ESMF_KIND_R8 * localPet, &
               1.0_ESMF_KIND_R8)
    pub%latCell(i) = real((-89.7_ESMF_KIND_R8 + 179.4_ESMF_KIND_R8 * x) &
                     * acos(-1.0_ESMF_KIND_R8) / 180.0_ESMF_KIND_R8, MPAS_RKIND)
  end do

  do chamada = 1, 2
    do i = 1, n
      x = real(i + 13 * localPet, ESMF_KIND_R8) / 97.0_ESMF_KIND_R8
      pub%pslv(i)     = real(101325.0_ESMF_KIND_R8 + 800.0_ESMF_KIND_R8 * sin(x * chamada), MPAS_RKIND)
      pub%u10(i)      = real(7.3_ESMF_KIND_R8 * cos(1.7_ESMF_KIND_R8 * x) + chamada / 3.0_ESMF_KIND_R8, MPAS_RKIND)
      pub%swdn_sfc(i) = real(max(0.0_ESMF_KIND_R8, 900.0_ESMF_KIND_R8 * sin(0.3_ESMF_KIND_R8 * x + chamada)), MPAS_RKIND)
    end do
    call mpas_export(pub, expst, rc)
    if (rc /= ESMF_SUCCESS) call ESMF_Finalize(endflag=ESMF_END_ABORT)
    do k = 1, NCAMPOS
      if (localPet == 0) then
        allocate(glob(ATM_NX, ATM_NY))
      else
        allocate(glob(1,1))
      end if
      call ESMF_FieldGather(campo(k), farray=glob, rootPet=0, rc=rc)
      if (localPet == 0) then
        write(arq,'(A,A,A,I0,A)') 'saida_', trim(nomes(k)), '_', chamada, '.bin'
        open(newunit=u, file=trim(arq), access='stream', form='unformatted', status='replace')
        write(u) glob
        close(u)
      end if
      deallocate(glob)
    end do
  end do

  call ESMF_Finalize(rc=rc)
end program test_mpas_export
