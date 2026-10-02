!> @file test_completar.F90
!! @brief Grava o que o mediador produz nos dois campos completados por
!! vizinhança depois da interpolação: a SST na malha de fluxo e a fração de
!! gelo exportada ao oceano.
!!
!! Monta o mediador como na inicialização (anúncio dos campos como em
!! InitializeAdvertise, create_atm_grid, create_ocn_grid com o supergrid
!! sintético hgrid.nc, realize_component_fields,
!! create_internal_fields e a fase A da inicialização: desde a R-FASE11-17,
!! prepara_inicio, de med_exchange; antes, idc_create_routes, de med_init) e roda três passos da ida para
!! a malha de fluxo (desde a R-FASE11-16, a fase ir_para_malha_de_fluxo de
!! med_exchange; antes, update_ocean_fields_on_atm_grid e
!! update_ice_fraction_from_docn, de med_ocean) e da exportação com o
!! carimbo de tempo (desde a R-FASE11-15, a fase entregar de med_exchange;
!! antes, a sequência de MediatorAdvance), com dados sintéticos:
!!
!!   So_t       SST com pontos abaixo de 270 K (terra), acima de 310 K e NaN
!!   So_omask   uniforme (só mar) no passo 1, quando a SST passa pela rota
!!              ocn2atm (a rota ocn2atm_sst ainda não existe), e com terra
!!              nos passos 2 e 3, pela rota ocn2atm_sst; com o argumento
!!              "mista", com terra já no passo 1, e então todas as rotas do
!!              passo são criadas no passo 1
!!   *_sis2     campos do SIS2 na grade do oceano (fração, albedos e
!!              temperatura do gelo), com valores fora das faixas válidas;
!!              o SIS2 está ligado, como na produção (desde a R-FASE11-18)
!!   Si_ifrac   fração de gelo na malha de fluxo com valores fora de [0, 1]
!!   demais     campos internos com valores determinísticos
!!   relógio    passo de 1 h; stampTime é o fim do passo, como no modo
!!              concorrente, para diferir do tempo atual do relógio;
!!              use_med_to_mpas ligado só no passo 2
!!
!! Em cada passo, grava em saida_<PET>.bin os valores locais da SST e dos
!! campos do gelo na malha de fluxo e de todos os campos do exportState, com o carimbo de
!! tempo de cada um; no fim, as
!! contagens de pontos completados de cada campo e o relatório de
!! acoplamento (relata_completas, linhas CPL-REL: no log do ESMF).
!!
!! Usa só interfaces que existem desde a R-FASE11-12 (tag
!! fase11-12-validada), para que o mesmo programa sirva às duas versões
!! comparadas por compara-completar.bash. As exceções são as fases do
!! mediador, conforme a versão (o script define as macros pelo fonte):
!!   COM_INICIO    chama prepara_inicio; sem ela, idc_create_routes (até a
!!                 R-FASE11-16, tag fase11-16-validada)
!!   COM_IR_PARA   chama ir_para_malha_de_fluxo; sem ela, repete as duas
!!                 chamadas de MediatorAdvance até a R-FASE11-15 (tag
!!                 fase11-15-validada)
!!   COM_ENTREGAR  chama entregar; sem ela, repete a sequência de
!!                 MediatorAdvance até a R-FASE11-14 (tag
!!                 fase11-14-validada): export_to_components,
!!                 stamp_export_fields e, com use_med_to_mpas, RouteOcnToAtm
!! As sequências de antes estão copiadas sem mudança.
program test_completar
  use ESMF
  use NUOPC,                 only : NUOPC_Advertise, NUOPC_FieldDictionarySetAutoAdd, &
                                    NUOPC_GetTimestamp
  use coupler_constants_mod, only : ATM_NX, ATM_NY
  use coupler_config_mod,    only : config_read
  use mom6_supergrid_mod,    only : mom6_supergrid_dims
  use med_cap_types_mod,     only : MED_InternalState, MED_CHAVES
  use cpl_fields_mod,        only : CPL_NAME_LEN
  use cpl_map_mod,           only : cpl_arrivals, cpl_current_config
  use med_init_mod,          only : create_atm_grid, create_ocn_grid, realize_component_fields, &
                                    create_internal_fields
#ifdef COM_INICIO
  use med_exchange_mod,      only : prepara_inicio
#else
  use med_init_mod,          only : idc_create_routes
#endif
#ifdef COM_IR_PARA
  use med_exchange_mod,      only : ir_para_malha_de_fluxo
#else
  use med_ocean_mod,         only : update_ocean_fields_on_atm_grid, &
                                    update_ice_fraction_from_docn
#endif
#ifdef COM_ENTREGAR
  use med_exchange_mod,      only : entregar
#else
  use med_export_mod,        only : export_to_components, stamp_export_fields
  use med_cap_methods_mod,   only : RouteOcnToAtm
#endif
  use med_diag_mod,          only : relata_completas
  implicit none

  type(MED_InternalState), pointer :: is
  type(ESMF_VM)    :: vm
  type(ESMF_State) :: imp, exp
  type(ESMF_Field) :: f, f_taux
  integer :: rc, localPet, petCount, un, nx, ny, passo, k, n_itens
  integer :: passo_terra        ! primeiro passo com terra na máscara do oceano
  character(len=16) :: caso
  real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:) => null()
  character(len=32) :: arquivo
  character(len=ESMF_MAXSTR), allocatable :: nomes(:)
  character(len=CPL_NAME_LEN), allocatable :: anuncio(:)
  type(ESMF_Clock)        :: relogio
  type(ESMF_Time)         :: t0, agora, carimbo
  type(ESMF_TimeInterval) :: dt

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, &
                       defaultLogFileName='teste_completar', &
                       logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 'ESMF_Initialize'
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)

  ! Argumento "mista": a máscara do oceano tem terra desde o passo 1, e
  ! todas as rotas do passo são criadas no mesmo passo
  caso = ''
  if (command_argument_count() > 0) call get_command_argument(1, caso)
  passo_terra = 2
  if (trim(caso) == 'mista') passo_terra = 1

  if (localPet == 0) call escreve_nml('mom6.nml')
  call ESMF_VMBarrier(vm, rc=rc)
  call config_read(rc, 'mom6.nml')
  if (rc /= ESMF_SUCCESS) error stop 'config_read'

  allocate(is)
  rc = ESMF_SUCCESS
  call create_atm_grid(petCount, ATM_NX, ATM_NY, is%atm_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'create_atm_grid'
  call mom6_supergrid_dims('hgrid.nc', nx, ny, rc)
  if (rc /= ESMF_SUCCESS) error stop 'mom6_supergrid_dims'
  rc = ESMF_SUCCESS
  call create_ocn_grid(petCount, nx, ny, is%ocn_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'create_ocn_grid'

  imp = ESMF_StateCreate(name='importacao', rc=rc)
  exp = ESMF_StateCreate(name='exportacao', rc=rc)
  call NUOPC_FieldDictionarySetAutoAdd(.true., rc=rc)
  call cpl_arrivals('MED', .true., cpl_current_config(), MED_CHAVES, anuncio)
  do k = 1, size(anuncio)
    call NUOPC_Advertise(imp, StandardName=trim(anuncio(k)), rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'NUOPC_Advertise (importacao)'
  end do
  call cpl_arrivals('MED@ocn_med', .false., cpl_current_config(), '', anuncio)
  do k = 1, size(anuncio)
    call NUOPC_Advertise(exp, StandardName=trim(anuncio(k)), rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'NUOPC_Advertise (exportacao)'
  end do
  call realize_component_fields(is, imp, exp, is%atm_grid, is%ocn_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'realize_component_fields'
  call create_internal_fields(is, is%atm_grid, rc)
  if (rc /= ESMF_SUCCESS) error stop 'create_internal_fields'
  call preenche_internos(0)
  call preenche_oceano(0)

  call ESMF_StateGet(exp, itemName='Foxx_taux', field=f_taux, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 'Foxx_taux'
#ifdef COM_INICIO
  call prepara_inicio(is, imp, exp, f_taux, rc)
#else
  call idc_create_routes(is, imp, exp, f_taux, rc)
#endif
  if (rc /= ESMF_SUCCESS) error stop 'fase A da inicializacao'

  call ESMF_StateGet(exp, itemCount=n_itens, rc=rc)
  allocate(nomes(n_itens))
  call ESMF_StateGet(exp, itemNameList=nomes, rc=rc)

  call ESMF_TimeSet(t0, yy=2026, mm=3, dd=29, h=0, rc=rc)
  call ESMF_TimeIntervalSet(dt, h=1, rc=rc)
  relogio = ESMF_ClockCreate(timeStep=dt, startTime=t0, name='relogio', rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 'ESMF_ClockCreate'

  write(arquivo, '(A,I0,A)') 'saida_', localPet, '.bin'
  open(newunit=un, file=trim(arquivo), access='stream', form='unformatted', status='replace')
  do passo = 1, 3
    call preenche_oceano(passo)
    call preenche_internos(passo)
    rc = ESMF_SUCCESS
#ifdef COM_IR_PARA
    call ir_para_malha_de_fluxo(is, imp, relogio, rc)
#else
    call update_ocean_fields_on_atm_grid(is, imp, f, is%run%raw_sst_diag_done, rc)
    call update_ice_fraction_from_docn(is, relogio, ifrac_ptr, rc)
#endif
    write(un) passo, rc
    call grava(un, is%ocn%sst)
    call grava(un, is%ice%ifrac)
    call grava(un, is%ice%alb_vdr)
    call grava(un, is%ice%alb_vdf)
    call grava(un, is%ice%alb_idr)
    call grava(un, is%ice%alb_idf)
    call grava(un, is%ice%tice)
    call ESMF_ClockGet(relogio, currTime=agora, rc=rc)
    carimbo = agora + dt
    is%use_med_to_mpas = passo == 2
    rc = ESMF_SUCCESS
#ifdef COM_ENTREGAR
    call entregar(is, imp, exp, relogio, carimbo, rc)
#else
    call export_to_components(is, imp, exp, rc)
    call stamp_export_fields(exp, f, carimbo, rc)
    if (is%use_med_to_mpas) then
      call RouteOcnToAtm(imp, exp, relogio, is, rc)
      if (rc /= ESMF_SUCCESS) then
        call ESMF_LogWrite('MED: RouteOcnToAtm retornou erro — continuando', &
          ESMF_LOGMSG_WARNING)
        rc = ESMF_SUCCESS
      end if
    end if
#endif
    write(un) rc
    do k = 1, n_itens
      call ESMF_StateGet(exp, itemName=trim(nomes(k)), field=f, rc=rc)
      if (rc /= ESMF_SUCCESS) error stop 'ESMF_StateGet'
      write(un) nomes(k)
      call grava(un, f)
      call grava_carimbo(un, f)
    end do
    call ESMF_ClockAdvance(relogio, rc=rc)
  end do
  do k = 1, size(is%run%completa)
    write(un) k, is%run%completa(k)%aplicacoes, is%run%completa(k)%invalidos, &
              is%run%completa(k)%fixos
  end do
  close(un)
  call relata_completas(is%run%completa, rc)

  call ESMF_Finalize(rc=rc)

contains

  !> Configuração com o MOM6 (supergrid sintético) e o SIS2, como na produção.
  subroutine escreve_nml(arq)
    character(len=*), intent(in) :: arq
    integer :: u
    open(newunit=u, file=arq, status='replace', action='write')
    write(u,'(A)') '&nuopc_mode'
    write(u,'(A)') '  use_docn = .false.'
    write(u,'(A)') '/'
    write(u,'(A)') '&nuopc_ocn'
    write(u,'(A)') "  mesh_ocn = 'hgrid.nc'"
    write(u,'(A)') '/'
    write(u,'(A)') '&nuopc_petlayout'
    write(u,'(A)') '  use_sis2_dynamic = .true.'
    write(u,'(A)') '/'
    close(u)
  end subroutine escreve_nml

  !> So_t, So_u, So_v e So_omask na grade do oceano, no passo dado. O passo
  !! 0 (inicialização) e o 1 têm a máscara uniforme.
  subroutine preenche_oceano(passo)
    integer, intent(in) :: passo
    real(ESMF_KIND_R8), pointer :: t(:,:), u(:,:), v(:,:), m(:,:)
    real(ESMF_KIND_R8) :: zero
    integer :: i, j

    zero = 0.0_ESMF_KIND_R8
    if (.not. ponteiro(imp, 'So_t', t)) return
    if (.not. ponteiro(imp, 'So_u', u)) return
    if (.not. ponteiro(imp, 'So_v', v)) return
    if (.not. ponteiro(imp, 'So_omask', m)) return
    do j = lbound(t, 2), ubound(t, 2)
      do i = lbound(t, 1), ubound(t, 1)
        t(i,j) = 285.0_ESMF_KIND_R8 + 0.5_ESMF_KIND_R8 * passo + &
                 12.0_ESMF_KIND_R8 * sin(0.37_ESMF_KIND_R8 * i) * cos(0.21_ESMF_KIND_R8 * j)
        m(i,j) = 1.0_ESMF_KIND_R8
        if (mod(7*i + 3*j, 11) == 0) then
          t(i,j) = 0.0_ESMF_KIND_R8
          if (passo >= passo_terra) m(i,j) = 0.0_ESMF_KIND_R8
        else if (mod(i + 2*j, 13) == 0) then
          t(i,j) = 315.0_ESMF_KIND_R8
        else if (mod(5*i + j, 29) == 0 .and. passo >= 1) then
          t(i,j) = zero / zero
        end if
        u(i,j) = 0.1_ESMF_KIND_R8 * sin(0.5_ESMF_KIND_R8 * i + passo)
        v(i,j) = 0.1_ESMF_KIND_R8 * cos(0.3_ESMF_KIND_R8 * j - passo)
      end do
    end do
    call preenche_sis2('Si_ifrac_sis2', passo, 0.5_ESMF_KIND_R8, 0.7_ESMF_KIND_R8)
    call preenche_sis2('Si_avsdr_sis2', passo, 0.6_ESMF_KIND_R8, 0.5_ESMF_KIND_R8)
    call preenche_sis2('Si_avsdf_sis2', passo, 0.6_ESMF_KIND_R8, 0.45_ESMF_KIND_R8)
    call preenche_sis2('Si_anidr_sis2', passo, 0.5_ESMF_KIND_R8, 0.55_ESMF_KIND_R8)
    call preenche_sis2('Si_anidf_sis2', passo, 0.5_ESMF_KIND_R8, 0.5_ESMF_KIND_R8)
    call preenche_sis2('Si_t_sis2',     passo, 255.0_ESMF_KIND_R8, 30.0_ESMF_KIND_R8)
  end subroutine preenche_oceano

  !> Campo do SIS2 no importState: centro + amplitude * padrão, com valores
  !! fora da faixa válida de cada campo.
  subroutine preenche_sis2(nome, passo, centro, amplitude)
    character(len=*),   intent(in) :: nome
    integer,            intent(in) :: passo
    real(ESMF_KIND_R8), intent(in) :: centro, amplitude
    real(ESMF_KIND_R8), pointer :: q(:,:)
    integer :: i, j
    if (.not. ponteiro(imp, nome, q)) return
    do j = lbound(q, 2), ubound(q, 2)
      do i = lbound(q, 1), ubound(q, 1)
        q(i,j) = centro + amplitude * sin(0.43_ESMF_KIND_R8 * i + 0.2_ESMF_KIND_R8 * passo) &
                                    * cos(0.31_ESMF_KIND_R8 * j)
      end do
    end do
  end subroutine preenche_sis2

  !> Campos internos da malha de fluxo (exceto a máscara), no passo dado; a
  !! fração de gelo vai de -0,2 a 1,2.
  subroutine preenche_internos(passo)
    integer, intent(in) :: passo
    type(ESMF_Field) :: todos(35)
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: n, i, j, irc

    todos = [is%ocn_flx%taux, is%ocn_flx%tauy, is%ocn_flx%sen, is%ocn_flx%evap,     &
             is%ocn_flx%lwnet, is%ocn_flx%swvdr, is%ocn_flx%swvdf, is%ocn_flx%swidr, &
             is%ocn_flx%swidf, is%ocn_flx%rain, is%ocn_flx%snow, is%ocn_flx%pslv,    &
             is%ice%ifrac, is%ocn_flx%duu10n, is%ocn%sst, is%ocn%u, is%ocn%v,        &
             is%sfc%zorl, is%ice%alb_vdr, is%ice%alb_vdf, is%ice%alb_idr,            &
             is%ice%alb_idf, is%sfc%coszen, is%sfc%albedo, is%ice%tice, is%sfc%tsfc,  &
             is%ice%taux, is%ice%tauy, is%ice%sen, is%ice%evap, is%ice%lwnet,         &
             is%ice%swvdr, is%ice%swvdf, is%ice%swidr, is%ice%swidf]
    do n = 1, size(todos)
      if (n == 15 .and. passo > 0) cycle      ! SST: vem do oceano a partir do passo 1
      call ESMF_FieldGet(todos(n), farrayPtr=p, rc=irc)
      if (irc /= ESMF_SUCCESS) error stop 'ESMF_FieldGet (internos)'
      do j = lbound(p, 2), ubound(p, 2)
        do i = lbound(p, 1), ubound(p, 1)
          if (n == 13) then
            p(i,j) = -0.2_ESMF_KIND_R8 + 1.4_ESMF_KIND_R8 * (0.5_ESMF_KIND_R8 + 0.5_ESMF_KIND_R8 * &
                     sin(0.05_ESMF_KIND_R8 * i + 0.3_ESMF_KIND_R8 * passo) * cos(0.07_ESMF_KIND_R8 * j))
          else if (n == 15) then
            p(i,j) = 290.0_ESMF_KIND_R8
          else
            p(i,j) = 0.001_ESMF_KIND_R8 * i - 0.002_ESMF_KIND_R8 * j + n + passo
          end if
        end do
      end do
    end do
  end subroutine preenche_internos

  !> Ponteiro para os valores locais do campo nome do State.
  logical function ponteiro(st, nome, p)
    type(ESMF_State),            intent(inout) :: st
    character(len=*),            intent(in)    :: nome
    real(ESMF_KIND_R8), pointer, intent(out)   :: p(:,:)
    type(ESMF_Field) :: campo
    integer :: irc
    ponteiro = .false.
    nullify(p)
    call ESMF_StateGet(st, itemName=nome, field=campo, rc=irc)
    if (irc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(campo, farrayPtr=p, rc=irc)
    ponteiro = irc == ESMF_SUCCESS
  end function ponteiro

  !> Carimbo de tempo do campo (válido ou não, e o instante).
  subroutine grava_carimbo(un, campo)
    integer,          intent(in)    :: un
    type(ESMF_Field), intent(inout) :: campo
    type(ESMF_Time) :: t
    logical :: valido
    integer :: yy, mm, dd, h, m, s, irc

    call NUOPC_GetTimestamp(campo, isValid=valido, time=t, rc=irc)
    if (irc /= ESMF_SUCCESS) error stop 'NUOPC_GetTimestamp'
    yy = 0; mm = 0; dd = 0; h = 0; m = 0; s = 0
    if (valido) call ESMF_TimeGet(t, yy=yy, mm=mm, dd=dd, h=h, m=m, s=s, rc=irc)
    write(un) valido, yy, mm, dd, h, m, s
  end subroutine grava_carimbo

  !> Para cada DE local: limites e valores do campo.
  subroutine grava(un, campo)
    integer,          intent(in)    :: un
    type(ESMF_Field), intent(inout) :: campo
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: nde, lde, irc

    call ESMF_FieldGet(campo, localDeCount=nde, rc=irc)
    if (irc /= ESMF_SUCCESS) error stop 'ESMF_FieldGet localDeCount'
    write(un) nde
    do lde = 0, nde - 1
      call ESMF_FieldGet(campo, localDe=lde, farrayPtr=p, rc=irc)
      if (irc /= ESMF_SUCCESS) error stop 'ESMF_FieldGet'
      write(un) lde, lbound(p), ubound(p)
      write(un) p
    end do
  end subroutine grava

end program test_completar
