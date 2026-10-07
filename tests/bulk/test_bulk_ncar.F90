!> @file test_bulk_ncar.F90
!! @brief Teste de regressão da física bulk do mediador (calc_bulk_ncar).
!!
!! Cria, na grade ATM 360x180 dividida em 2 x NP/2 blocos, todos os campos
!! do estado interno do mediador que calc_bulk_ncar lê ou escreve, preenche
!! as entradas com dados sintéticos e chama calc_bulk_ncar três vezes, em
!! três instantes diferentes. Depois de cada chamada, grava em
!! saida_<PET>.bin o código de retorno e todos os campos, na ordem da lista
!! abaixo. O script compara-bulk.bash compara esses arquivos entre duas
!! versões do código.
!!
!! Os dados cobrem os casos que mudam o caminho do cálculo: vento nulo,
!! ar mais quente e mais frio que a superfície, temperatura do gelo fora
!! da faixa física, fração de gelo abaixo do limiar dos fluxos sobre o
!! gelo, máscara de terra e forçantes ausentes (tas < 100 K, psl < 5e4 Pa,
!! lwdn < 1 W/m2). O gerador aleatório tem semente fixa e é chamado na
!! mesma sequência em todos os PETs, que assim veem a mesma grade global.
!!
!! Desde a R-FASE11-20, a física recebe arrays (med_flux_t) em vez do estado
!! interno; o programa chama a fase compute_fluxes, de med_exchange, que os
!! associa aos mesmos campos e chama calc_bulk_ncar. A associação percorre
!! o registro dos campos internos (is%fields, na ordem de MED_FIELDS); por
!! isso o programa cria os campos no registro e liga a eles os componentes
!! do estado interno com bind_internal_fields (med_init), como a
!! inicialização do mediador.
!!
!! Sem o SIS2, calc_bulk_ncar terminava recalculando a
!! fração de gelo pelo limiar de SST (legacy_ice_fraction). Desde a
!! R-FASE11-19, esse cálculo é a fase ice_fraction_without_sis2, de
!! med_exchange, chamada logo depois; o teste a chama no mesmo ponto, e os
!! campos gravados continuam os de antes.
!!
!! O teste roda sem o SIS2. Até a R-FASE12-07 esse era o valor padrão de
!! use_sis2_dynamic; desde a R-FASE13-01, que fez dos padrões a configuração
!! de produção (com o SIS2), o programa lê um nuopc.input que o desliga.
!! O mesmo arquivo pede log_level='debug', para que as sondas do mediador
!! (FIX-DIAG) entrem no log, como entravam com write_fixdiag, que até a
!! R-FASE13-08 vinha ligada por padrão.
program test_bulk_ncar
  use ESMF
  use med_cap_types_mod, only: MED_InternalState, MED_FIELDS
  use med_init_mod,      only: bind_internal_fields
  use med_exchange_mod,  only: compute_fluxes, ice_fraction_without_sis2
  use coupler_config_mod, only: config_read
  implicit none

  integer, parameter :: NX = 360, NY = 180, NCALLS = 3
  type(MED_InternalState), pointer :: is
  type(ESMF_Grid)  :: grid
  type(ESMF_VM)    :: vm
  type(ESMF_State) :: importState
  type(ESMF_Clock) :: clock
  type(ESMF_Time)  :: t0, t1
  type(ESMF_TimeInterval) :: dt
  type(ESMF_Field), allocatable :: all_fields(:)
  real(ESMF_KIND_R8), allocatable :: uas(:,:), vas(:,:), tas(:,:), psl(:,:), swdn(:,:)
  real(ESMF_KIND_R8), allocatable :: lwdn(:,:), rain(:,:), shum(:,:), snow(:,:)
  real(ESMF_KIND_R8), pointer :: p(:,:)
  integer, allocatable :: seed(:)
  integer :: rc, pet, npet, ns, k, n, u, i1, i2, j1, j2
  character(len=64) :: name

  call ESMF_Initialize(defaultLogFileName='teste_bulk', logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  if (rc /= ESMF_SUCCESS) stop 2
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=pet, petCount=npet, rc=rc)
  if (pet == 0) then
    open(newunit=u, file='sem_sis2.nml', status='replace', action='write')
    write(u,'(A)') '&nuopc_driver'
    write(u,'(A)') "  log_level = 'debug'"
    write(u,'(A)') '/'
    write(u,'(A)') '&nuopc_petlayout'
    write(u,'(A)') '  use_sis2_dynamic = .false.'
    write(u,'(A)') '/'
    close(u)
  end if
  call ESMF_VMBarrier(vm, rc=rc)
  call config_read(rc, 'sem_sis2.nml')
  if (rc /= 0) then
    call ESMF_LogWrite('test_bulk_ncar: config_read falhou', ESMF_LOGMSG_ERROR)
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
  end if
  if (mod(npet, 2) /= 0) then
    call ESMF_LogWrite('test_bulk_ncar: o numero de PETs tem de ser par', ESMF_LOGMSG_ERROR)
    call ESMF_Finalize(endflag=ESMF_END_ABORT)
  end if
  grid = ESMF_GridCreateNoPeriDim(minIndex=(/1,1/), maxIndex=(/NX,NY/), &
    regDecomp=(/2, npet/2/), coordSys=ESMF_COORDSYS_SPH_DEG, &
    indexflag=ESMF_INDEX_GLOBAL, rc=rc)

  ! Todos os campos internos do mediador, no registro, e os componentes do
  ! estado interno ligados a eles
  allocate(is)
  do n = 1, size(MED_FIELDS)
    is%fields(n)%name = MED_FIELDS(n)%name
    call create_field(is%fields(n)%field)
  end do
  call bind_internal_fields(is)
  ! Os campos que calc_bulk_ncar usa, entradas e saídas, na ordem de gravação
  all_fields = [is%ocn_flx%taux, is%ocn_flx%tauy, is%ocn_flx%sen, is%ocn_flx%evap, is%ocn_flx%lwnet, &
           is%ocn_flx%swvdr, is%ocn_flx%swvdf, is%ocn_flx%swidr, is%ocn_flx%swidf,           &
           is%ocn_flx%rain, is%ocn_flx%snow, is%ocn_flx%pslv, is%ice%ifrac,              &
           is%ocn_flx%duu10n, is%ocn%sst, is%ocn%u, is%ocn%v,              &
           is%sfc%zorl, is%sfc%coszen, is%sfc%albedo, is%ice%tice,           &
           is%ice%taux, is%ice%tauy, is%ice%sen, is%ice%evap,                &
           is%ice%lwnet, is%ice%swvdr, is%ice%swvdf, is%ice%swidr,           &
           is%ice%swidf, is%ocn%omask, is%ice%alb_vdr, is%ice%alb_vdf,       &
           is%ice%alb_idr, is%ice%alb_idf]

  importState = ESMF_StateCreate(name='import vazio', rc=rc)
  call ESMF_TimeSet(t0, yy=2026, mm=3, dd=29, h=6, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
  call ESMF_TimeSet(t1, yy=2026, mm=4, dd=29, h=0, calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
  call ESMF_TimeIntervalSet(dt, h=7, rc=rc)
  clock = ESMF_ClockCreate(dt, t0, stopTime=t1, rc=rc)

  allocate(uas(NX,NY), vas(NX,NY), tas(NX,NY), psl(NX,NY), swdn(NX,NY), &
           lwdn(NX,NY), rain(NX,NY), shum(NX,NY), snow(NX,NY))
  call random_seed(size=ns)
  allocate(seed(ns)); seed = 20260927
  call random_seed(put=seed)

  write(name,'(A,I0,A)') 'saida_', pet, '.bin'
  open(newunit=u, file=name, access='stream', form='unformatted', status='replace')
  do k = 1, NCALLS
    ! Forçantes atmosféricos, na grade global
    call draw_random(uas, -30.0d0, 30.0d0); call draw_random(vas, -30.0d0, 30.0d0)
    uas(1:20,1:5) = 0.0d0;                vas(1:20,1:5) = 0.0d0
    call draw_random(tas, 50.0d0, 320.0d0); call draw_random(psl, 4.0d4, 1.05d5)
    call draw_random(swdn, -10.0d0, 1100.0d0); call draw_random(lwdn, -5.0d0, 450.0d0)
    call draw_random(rain, -1.0d-4, 1.0d-3); call draw_random(shum, 0.0d0, 2.0d-2)
    call draw_random(snow, -1.0d-4, 1.0d-3)

    ! Campos do estado interno: primeiro valores quaisquer em todos...
    do n = 1, size(all_fields)
      call fill_random(all_fields(n), -1.0d3, 1.0d3)
    end do
    ! ...depois as entradas, em faixas plausíveis
    call fill_random(is%ocn%sst, 260.0d0, 310.0d0)
    call fill_random(is%ocn%u, -1.0d0, 1.0d0)
    call fill_random(is%ocn%v, -1.0d0, 1.0d0)
    call fill_random(is%ice%tice, 150.0d0, 290.0d0)
    call fill_random(is%ice%ifrac, -0.5d0, 1.0d0)
    call fill_random(is%ocn%omask, -0.5d0, 1.0d0)
    call fill_random(is%ocn_flx%taux, -1.0d0, 1.0d0)
    call fill_random(is%ocn_flx%tauy, -1.0d0, 1.0d0)
    call fill_random(is%ice%alb_vdr, 0.0d0, 1.0d0)
    call fill_random(is%ice%alb_vdf, 0.0d0, 1.0d0)
    call fill_random(is%ice%alb_idr, 0.0d0, 1.0d0)
    call fill_random(is%ice%alb_idf, 0.0d0, 1.0d0)
    call ESMF_FieldGet(is%ice%ifrac, farrayPtr=p, rc=rc)
    where (p < 0.0d0) p = 0.0d0                      ! um terço sem gelo
    p(lbound(p,1):lbound(p,1)+3, :) = 5.0d-4         ! abaixo do limiar dos Fioi_*
    call ESMF_FieldGet(is%ocn%omask, farrayPtr=p, rc=rc)
    p = merge(1.0d0, 0.0d0, p > 0.0d0)               ! terra onde era negativo
    call ESMF_FieldGet(is%ice%tice, farrayPtr=p, rc=rc)
    p(:, lbound(p,2)) = 271.35d0                     ! valor padrão do cap do gelo

    call ESMF_FieldGet(is%ocn_flx%taux, farrayPtr=p, rc=rc)
    i1 = lbound(p,1); i2 = ubound(p,1); j1 = lbound(p,2); j2 = ubound(p,2)
    call compute_fluxes(is, uas, vas, tas, psl, swdn, lwdn, rain, shum, snow, &
                        i1, i2, j1, j2, clock, rc)
    if (rc == ESMF_SUCCESS) call ice_fraction_without_sis2(is, importState, i1, i2, j1, j2)
    write(u) rc
    do n = 1, size(all_fields)
      call ESMF_FieldGet(all_fields(n), farrayPtr=p, rc=rc)
      write(u) p
    end do
    call ESMF_ClockAdvance(clock, rc=rc)
  end do
  close(u)
  call ESMF_Finalize(rc=rc)

contains

  subroutine create_field(field)
    type(ESMF_Field), intent(out) :: field
    field = ESMF_FieldCreate(grid, ESMF_TYPEKIND_R8, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (rc /= ESMF_SUCCESS) call ESMF_Finalize(endflag=ESMF_END_ABORT)
  end subroutine create_field

  subroutine draw_random(a, lo, hi)
    real(ESMF_KIND_R8), intent(out) :: a(:,:)
    real(ESMF_KIND_R8), intent(in)  :: lo, hi
    call random_number(a)
    a = lo + (hi - lo) * a
  end subroutine draw_random

  !> Sorteia a grade global inteira (mesma sequência em todos os PETs) e
  !! copia para o campo o bloco local.
  subroutine fill_random(field, lo, hi)
    type(ESMF_Field),   intent(in) :: field
    real(ESMF_KIND_R8), intent(in) :: lo, hi
    real(ESMF_KIND_R8), allocatable :: g(:,:)
    real(ESMF_KIND_R8), pointer :: q(:,:)
    allocate(g(NX,NY))
    call draw_random(g, lo, hi)
    call ESMF_FieldGet(field, farrayPtr=q, rc=rc)
    q = g(lbound(q,1):ubound(q,1), lbound(q,2):ubound(q,2))
  end subroutine fill_random

end program test_bulk_ncar
