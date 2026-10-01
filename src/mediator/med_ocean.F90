!> @file med_ocean.F90
!! @brief Campos do oceano na grade da atmosfera.
!!
!! SST, máscara de oceano, correntes superficiais e fração de gelo do OISST
!! (use_docn_ice), levados da grade OCN para a grade ATM interna do mediador.
!! Usa med_ice_mod para o gelo do SIS2.
!!
!! Separado de MED_cap.F90 sem mudar instruções (R-FASE8-01).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_ocean_mod
  use ESMF
  use netcdf
  use coupler_constants_mod, only: ATM_NX, ATM_NY, SI_IFRAC_DECAY
  use coupler_config_mod, only: cfg_docn_nx, cfg_docn_ny, cfg_use_docn_ice, &
                                cfg_write_fixdiag, cfg_docn_ice_init_only, &
                                cfg_docn_ice_file, cfg_docn_ice_varname, &
                                cfg_docn_ice_pct, cfg_docn_dt_data, &
                                cfg_docn_epoch_year, cfg_docn_epoch_month, &
                                cfg_docn_epoch_day, cfg_use_sis2_dynamic
  use med_cap_types_mod, only: MED_InternalState, med_completa_t, COMPL_SST
  use med_diag_mod, only: registra_completa
  use med_cap_methods_mod, only: ZeroInternalField, cria_rota, set_ocn_grid_mask, &
                                 completar_da_rota
  use med_ice_mod, only: update_ice_fields_on_atm_grid
  use cpl_grids_mod, only: indice_trunca

  implicit none
  private

  public :: update_ocean_fields_on_atm_grid
  public :: regrid_ocean_currents
  public :: update_ice_fraction_from_docn

  ! ── Si_ifrac do OISST ──────────────────────────────────────────────────
  !
  ! is%run%ifrac_init_done : .true. após fill_ifrac_from_oisst ser chamado
  !   na primeira MediatorAdvance (estado interno, med_cap_types).
  !
  ! SI_IFRAC_DECAY (coupler_constants): fator de decaimento de Si_ifrac por
  !   passo de acoplamento (dt=3600 s, τ=86400 s): exp(-dt/τ) = exp(-1/24)
  !   ≈ 0.9592. O cap do oceano (mom_si_ifrac.F90) usa a mesma constante.

contains

  subroutine update_ocean_fields_on_atm_grid(is, importState, field, raw_sst_diag_done, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: field
    logical, intent(inout) :: raw_sst_diag_done
    integer, intent(inout) :: rc
    character(len=300) :: dbgmsg2
    character(len=220) :: diag_msgB2
    integer :: i1r
    integer :: i2r
    integer :: j1r
    integer :: mid_r
    real(ESMF_KIND_R8), pointer :: p_idr(:,:)
    real(ESMF_KIND_R8), pointer :: p_if(:,:)
    real(ESMF_KIND_R8), pointer :: p_vdr(:,:)
    integer :: rc_diag
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    real(ESMF_KIND_R8), pointer :: sst_raw(:,:)
    integer :: n_invalid, n_left
    if (is%regrid%has('ocn2atm')) then
      call ESMF_StateGet(importState, itemName="So_t", field=field, rc=rc)

      ! Diagnostico dos valores BRUTOS de So_t (antes de
      ! qualquer regrid/mascara do MED), para isolar se a falta de estrutura
      ! leste-oeste vem da EXPORTACAO do MOM6 ou do regrid do mediador.
        if (.not. raw_sst_diag_done) then
          call ESMF_FieldGet(field, localDe=0, farrayPtr=sst_raw, rc=rc_diag)
          if (rc_diag == ESMF_SUCCESS .and. associated(sst_raw)) then
            i1r = lbound(sst_raw,1); i2r = ubound(sst_raw,1)
            j1r = lbound(sst_raw,2)
            mid_r = (i1r + i2r) / 2
            write(dbgmsg2,'(A,I0,A,I0,A,I0)') &
              'MED B-OCNGRID-02 DIAG: So_t BRUTO (OCN, DE local) i=[', i1r, &
              ',', i2r, '] j1=', j1r
            call ESMF_LogWrite(trim(dbgmsg2), ESMF_LOGMSG_INFO)
            write(dbgmsg2,'(A,F9.3,A,F9.3,A,F9.3,A,F9.3)') &
              '  sst_raw(i1,j1)=', sst_raw(i1r,j1r), &
              ' sst_raw(mid,j1)=', sst_raw(mid_r,j1r), &
              ' sst_raw(i2,j1)=', sst_raw(i2r,j1r), &
              ' min_row=', minval(sst_raw(:,j1r))
            call ESMF_LogWrite(trim(dbgmsg2), ESMF_LOGMSG_INFO)
            raw_sst_diag_done = .true.
          end if
        end if


      ! Regrid da SST com a mascara real do oceano (So_omask) e extrapolação
      ! por vizinhança para a costa (etapa completar da rota ocn2atm_sst).
      ! Enquanto a máscara é uniforme, a rota ocn2atm interpola e a SST é
      ! completada como na rota ocn2atm_sst.
      if (.not. is%regrid%has('ocn2atm_sst')) call set_ocean_mask_for_sst(is, importState, field, rc)

      if (is%regrid%has('ocn2atm_sst')) then
        call is%regrid%apply('ocn2atm_sst', field, is%ocn%sst, rc, &
                             n_invalid=n_invalid, n_left=n_left)
      else
        call is%regrid%apply('ocn2atm', field, is%ocn%sst, rc, &
                             fill=completar_da_rota('ocn2atm_sst'), &
                             n_invalid=n_invalid, n_left=n_left)
      end if
      if (n_invalid >= 0) call registra_sst(is%run%completa(COMPL_SST), n_invalid, n_left)

      ! Regrid de correntes oceânicas OCN → ATM.
      ! So_u e So_v são anunciados e realizados no importState do MED
      ! (ocn_grid); ESMF_StateGet é seguro.
      ! Fallback seguro: se regrid falhar, mantém zeros em is%ocn%u/is%ocn%v.
      call regrid_ocean_currents(is, importState, zero_on_error=.false.)

      ! Si_ifrac_sis2, albedos e T_gelo, pela rota MASCARADA 'ocn2atm_ice',
      ! com extrapolacao por vizinhanca apos o regrid: o mesmo tratamento da
      ! SST ('ocn2atm_sst'). A rota generica 'ocn2atm' (sem mascara nem
      ! extrapolacao) daria artefatos justamente onde o gelo se concentra, na
      ! regiao de deformacao da malha tripolar (alta latitude).
      if (cfg_use_sis2_dynamic) then
        call update_ice_fields_on_atm_grid(is, importState)

        ! Diagnostico: is%ice%ifrac deve refletir o Ice%part_size real do
        ! SIS2 interpolado para a grade ATM. Os 4 albedos devem ficar entre o
        ! valor padrao (0,65) e o de neve fria (~0,85-0,9) sob gelo espesso.
        if (cfg_write_fixdiag) then
            call ESMF_FieldGet(is%ice%ifrac,   farrayPtr=p_if,  rc=rc)
            call ESMF_FieldGet(is%ice%alb_vdr, farrayPtr=p_vdr, rc=rc)
            call ESMF_FieldGet(is%ice%alb_idr, farrayPtr=p_idr, rc=rc)
            rc = ESMF_SUCCESS
            if (associated(p_if) .and. associated(p_vdr) .and. associated(p_idr)) then
              write(diag_msgB2,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
                'FIX-DIAG-SPRINTB2-01: f_ifrac_atm min=', minval(p_if), &
                ' max=', maxval(p_if), &
                ' | f_alb_vdr_ice min=', minval(p_vdr), ' max=', maxval(p_vdr), &
                ' | f_alb_idr_ice min=', minval(p_idr), ' max=', maxval(p_idr)
              call ESMF_LogWrite(trim(diag_msgB2), ESMF_LOGMSG_INFO)
            end if
        end if
      end if
    else
      ! Routehandles nao criados: usa SST padrao (ja preenchido em InitializeRealize)
      call ESMF_FieldGet(is%ocn%sst, farrayPtr=sst, rc=rc)
    end if
  end subroutine update_ocean_fields_on_atm_grid

  !> Soma os pontos da SST completados pela rota em cont, para o relatório
  !! de acoplamento, e os registra no log. O preenchimento (coluna completar
  !! da rota ocn2atm_sst, em ROTAS): média dos vizinhos válidos, em até 40
  !! passadas; o que sobrar recebe 271,35 K; valores acima de 310 K recebem
  !! 271,35 K antes da difusão.
  !!
  !! @param[inout] cont       contagem da SST
  !! @param[in]    n_invalid  pontos fora da faixa antes do preenchimento
  !! @param[in]    n_left     pontos que ficaram com o valor fixo
  subroutine registra_sst(cont, n_invalid, n_left)
    type(med_completa_t), intent(inout) :: cont
    integer,              intent(in)    :: n_invalid, n_left
    character(len=120) :: msg

    call registra_completa(cont, n_invalid, n_left)
    if (n_invalid > 0) then
      write(msg,'(A,I0,A,I0,A)') 'MED: SST extrapolada em ', n_invalid, &
        ' celulas (', n_left, ' com valor fixo)'
      call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)
    end if
  end subroutine registra_sst

  subroutine set_ocean_mask_for_sst(is, importState, sst_ocn, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: sst_ocn   !< So_t na grade do oceano
    integer, intent(inout) :: rc
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    integer :: lde_s, n_land, ldec_ocn, n_sea
    integer :: n_land_g(1), n_land_s(1), n_sea_g(1), n_sea_s(1)
    type(ESMF_VM) :: vm
    logical :: got_omask, achou
    real(ESMF_KIND_R8), pointer :: sst_src(:,:)
    real(ESMF_KIND_R8), parameter :: LAND_FILL_MAX = 270.0_ESMF_KIND_R8

    call ESMF_VMGetCurrent(vm, rc=rc)

    ! Preferencial: mascara real do MOM6 (So_omask, 1=oceano/0=terra; a
    ! mesma convencao do GRIDITEM_MASK aqui: valores em srcMaskValues sao
    ! EXCLUIDOS da fonte do regrid, logo terra=0 e' o valor a excluir).
    call set_ocn_grid_mask(is%ocn_grid, importState, n_land, n_sea, achou, got_omask)
    if (.not. achou) then
      call ESMF_LogWrite( &
        'MED: So_omask indisponivel no importState - usando ' // &
        'fallback por limiar de SST (menos confiavel na costa)', &
        ESMF_LOGMSG_WARNING)
    end if

    ! Fallback defensivo (nao deveria ocorrer com So_omask anunciado/
    ! realizado): mantem o comportamento antigo em vez de travar.
    if (.not. got_omask) then
        n_land = 0; n_sea = 0
        call ESMF_GridGet(is%ocn_grid, localDeCount=ldec_ocn, rc=rc)
        if (rc == ESMF_SUCCESS) then
          do lde_s = 0, ldec_ocn - 1
            call ESMF_FieldGet(sst_ocn, localDe=lde_s, farrayPtr=sst_src, rc=rc)
            if (rc /= ESMF_SUCCESS .or. .not. associated(sst_src)) cycle
            call ESMF_GridGetItem(is%ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
              staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_s, &
              farrayPtr=maskptr, rc=rc)
            if (rc == ESMF_SUCCESS .and. associated(maskptr)) then
              where (sst_src < LAND_FILL_MAX)
                maskptr = 0
              elsewhere
                maskptr = 1
              end where
              n_land = n_land + count(maskptr == 0)
              n_sea  = n_sea  + count(maskptr == 1)
            end if
          end do
        end if
    end if

    n_land_s(1) = n_land; n_sea_s(1) = n_sea
    call ESMF_VMAllReduce(vm, n_land_s, n_land_g, 1, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) n_land_g(1) = n_land
    call ESMF_VMAllReduce(vm, n_sea_s,  n_sea_g,  1, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) n_sea_g(1) = n_sea
    if (n_land_g(1) == 0 .or. n_sea_g(1) == 0) then
      ! Máscara ainda uniforme (bootstrap): So_t usa a rota ocn2atm neste
      ! passo e a rota mascarada é tentada de novo no próximo.
      call ESMF_LogWrite('MED: mascara oceanica uniforme, rota ocn2atm_sst adiada', &
        ESMF_LOGMSG_INFO)
    else
      ! Conservativo contorna a deformação da costura tripolar; bilinear
      ! mascarado se a grade não tiver cantos; ocn2atm como último recurso.
      call cria_rota(is%regrid, 'ocn2atm_sst', sst_ocn, is%ocn%sst, rc)
    end if
  end subroutine set_ocean_mask_for_sst


  !> Correntes oceânicas So_u/So_v para a grade ATM (rota ocn2atm).
  !! Com zero_on_error, a componente cuja interpolação falhar é zerada.
  subroutine regrid_ocean_currents(is, importState, zero_on_error)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    logical,                 intent(in)    :: zero_on_error

    call regrid_one('So_u', is%ocn%u)
    call regrid_one('So_v', is%ocn%v)

  contains

    subroutine regrid_one(name, dst)
      character(len=*), intent(in)    :: name
      type(ESMF_Field), intent(inout) :: dst
      type(ESMF_Field) :: src
      integer :: rc_c

      call ESMF_StateGet(importState, itemName=name, field=src, rc=rc_c)
      if (rc_c /= ESMF_SUCCESS) return
      call is%regrid%apply('ocn2atm', src, dst, rc_c)
      if (rc_c /= ESMF_SUCCESS .and. zero_on_error) call ZeroInternalField(dst, rc_c)
    end subroutine regrid_one

  end subroutine regrid_ocean_currents

  subroutine update_ice_fraction_from_docn(is, clock, ifrac_ptr, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_Clock), intent(inout) :: clock
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:)
    integer :: ldec
    if (cfg_use_docn_ice .and. &
        (.not. cfg_docn_ice_init_only .or. .not. is%run%ifrac_init_done)) then
      call fill_ifrac_from_oisst(is, clock, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS  ! não fatal
      is%run%ifrac_init_done = .true.               ! inicializado em t=0

    else if (cfg_use_docn_ice .and. cfg_docn_ice_init_only .and. &
             is%run%ifrac_init_done) then
      ! init_only: decaimento exponencial do campo OISST retido em
      ! is%ice%ifrac (zero_med_fluxes nao o zera neste modo).
      ! Multiplica cada célula por SI_IFRAC_DECAY_MED (≈ 0.9592/hora).
      ! Resulta em τ ≈ 24h: gelo antártico/ártico decai fisicamente em vez
      ! de desaparecer instantaneamente no passo seguinte ao t=0.
        call ESMF_FieldGet(is%ice%ifrac, localDeCount=ldec, rc=rc)
        if (rc == ESMF_SUCCESS .and. ldec > 0) then
          call ESMF_FieldGet(is%ice%ifrac, farrayPtr=ifrac_ptr, rc=rc)
          if (rc == ESMF_SUCCESS .and. associated(ifrac_ptr)) then
            ifrac_ptr = ifrac_ptr * SI_IFRAC_DECAY
            where (ifrac_ptr < 0.0_ESMF_KIND_R8) ifrac_ptr = 0.0_ESMF_KIND_R8
          end if
        end if
        rc = ESMF_SUCCESS
        call ESMF_LogWrite( &
          'MED(B.1.1): Si_ifrac decaimento aplicado (SI_IFRAC_DECAY_MED=0.9592)', &
          ESMF_LOGMSG_INFO)
    end if
  end subroutine update_ice_fraction_from_docn


  !============================================================================
  !> @brief Preenche is%ice%ifrac com dados OISST (use_docn_ice).
  !!
  !! Lê arquivo NetCDF OISST diretamente via netcdf + ESMF_VMBroadcast.
  !! Chamada em MediatorAdvance ANTES de calc_bulk_ncar quando
  !! cfg_use_docn_ice=.true. (nuopc.input &nuopc_mode).
  !!
  !! Algoritmo:
  !!   1. PET0 abre o NetCDF, lê snapshots [tidx0, tidx1], interpola
  !!      linearmente e broadcast via ESMF_VMBroadcast.
  !!   2. Nearest-neighbor: converte coordenadas da grade ATM interna
  !!      (360×180, centros em lon=(i-0.5)*dx, lat=(j-0.5)*dy-90)
  !!      em índices OISST.
  !!   3. Copia para ptr(:,:) de is%ice%ifrac.
  subroutine fill_ifrac_from_oisst(is, clock, rc)
    use netcdf  ! deve preceder todas as declarações

    type(MED_InternalState), intent(inout) :: is
    type(ESMF_Clock),        intent(in)    :: clock
    integer,                 intent(out)   :: rc

    type(ESMF_Time)             :: currTime
    type(ESMF_VM)               :: vm
    type(ESMF_TimeInterval)     :: dt_epoch
    type(ESMF_Time)             :: epochTime
    real(ESMF_KIND_R8), pointer :: fptr(:,:) => null()
    real(ESMF_KIND_R8), allocatable :: buf(:)    ! buffer MPI broadcast
    real(ESMF_KIND_R8), allocatable :: f0(:,:), f1(:,:)
    integer :: nx_o, ny_o, nx_a, ny_a
    integer :: tidx0, tidx1, ntime, localDeCount_f, localPet
    integer(ESMF_KIND_I8) :: sec_epoch, dt_data_i8
    real(ESMF_KIND_R8) :: alpha, dx_o, dy_o, dx_a, dy_a
    character(len=256) :: logmsg

    rc = ESMF_SUCCESS

    call ESMF_ClockGet(clock, currTime=currTime, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    ! Dimensões das grades
    nx_o = cfg_docn_nx;   ny_o = cfg_docn_ny
    nx_a = ATM_NX;        ny_a = ATM_NY
    dx_o = 360.0_ESMF_KIND_R8 / real(nx_o, ESMF_KIND_R8)
    dy_o = 180.0_ESMF_KIND_R8 / real(ny_o, ESMF_KIND_R8)
    dx_a = 360.0_ESMF_KIND_R8 / real(nx_a, ESMF_KIND_R8)
    dy_a = 180.0_ESMF_KIND_R8 / real(ny_a, ESMF_KIND_R8)

    ! Calcular índice temporal: tidx = floor((t - epoch) / dt_data) mod ntime
    call ESMF_TimeSet(epochTime,                   &
      yy   = cfg_docn_epoch_year,                  &
      mm   = cfg_docn_epoch_month,                 &
      dd   = cfg_docn_epoch_day,                   &
      calkindflag = ESMF_CALKIND_GREGORIAN, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_epoch   = currTime - epochTime
    call ESMF_TimeIntervalGet(dt_epoch, s_i8=sec_epoch, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_data_i8 = int(cfg_docn_dt_data, ESMF_KIND_I8)

    allocate(f0(nx_o, ny_o), f1(nx_o, ny_o), buf(nx_o * ny_o))
    f0 = 0.0_ESMF_KIND_R8;  f1 = 0.0_ESMF_KIND_R8;  buf = 0.0_ESMF_KIND_R8

    ! PET0 lê o arquivo; todos os outros PETs aguardam o broadcast.
    !
    ! Usa a VM do COMPONENTE, não a global, como DATM_cap.F90, DOCN_cap.F90
    ! e docn_cap_netcdf.F90. Hoje o MED roda em todos os PETs nos dois
    ! layouts e as duas VMs coincidem, mas a chamada global ficaria incorreta
    ! se o mediador ganhasse uma petList própria, e falharia com deadlock, não
    ! com erro. ESMF_VMGetCurrent devolve a VM do componente em execução,
    ! tornando rootPet=0 local ao MED.
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      deallocate(f0, f1, buf); return
    end if
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)

    ! Numero de instantes do arquivo, lido no PET 0 e difundido
    call oisst_ntime(vm, localPet, ntime)

    ! Calcular índices de interpolação
    tidx0 = mod(int(sec_epoch / real(dt_data_i8, ESMF_KIND_R8)), ntime) + 1
    tidx1 = mod(tidx0, ntime) + 1
    alpha = real(mod(sec_epoch, dt_data_i8), ESMF_KIND_R8) / real(dt_data_i8, ESMF_KIND_R8)
    alpha = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, alpha))

    if (localPet == 0) then
      call read_oisst_ifrac(nx_o, ny_o, tidx0, tidx1, alpha, f0, f1)
      buf = reshape(f0, [nx_o * ny_o])
    end if

    ! Distribuir campo OISST para todos os PETs.
    ! ESMF_VMBroadcast tem sobrecarga para real(ESMF_KIND_R8) array — uso direto.
    call ESMF_VMBroadcast(vm, bcstData=buf, count=nx_o*ny_o, rootPet=0, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      deallocate(f0, f1, buf); return
    end if
    f0 = reshape(buf, [nx_o, ny_o])
    deallocate(f1, buf)

    ! Copiar para is%ice%ifrac (grade ATM interna 360×180)
    call ESMF_FieldGet(is%ice%ifrac, localDeCount=localDeCount_f, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localDeCount_f == 0) then
      rc = ESMF_SUCCESS; deallocate(f0); return
    end if
    call ESMF_FieldGet(is%ice%ifrac, farrayPtr=fptr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(fptr)) then
      deallocate(f0); return
    end if

    ! Nearest-neighbor: grade ATM interna (lon centrado em (i-0.5)*dx)
    call oisst_to_atm_nearest(f0, nx_o, ny_o, dx_o, dy_o, dx_a, dy_a, fptr)

    deallocate(f0)

    write(logmsg,'(A,A,A,F5.3)') &
      'MED(Alt1): f_ifrac_atm preenchido de ', trim(cfg_docn_ice_file), &
      '  alpha=', alpha
    call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)
    rc = ESMF_SUCCESS

  end subroutine fill_ifrac_from_oisst

  !> Numero de instantes (dimensao time ou Time) do arquivo de gelo do
  !! OISST, lido pelo PET 0 e difundido a todos os PETs da VM. Sem arquivo
  !! ou sem a dimensao, e se a difusao falhar, vale 365.
  subroutine oisst_ntime(vm, localPet, ntime)
    type(ESMF_VM), intent(in)  :: vm
    integer,       intent(in)  :: localPet
    integer,       intent(out) :: ntime
    integer :: buf_n(1)       ! wrapper para broadcast de ntime (inteiro escalar)
    integer :: ncid, dimid, nc_rc, rc

    ntime = 365  ! default seguro

    if (localPet == 0) then
      ! Descobrir ntime no arquivo
      nc_rc = nf90_open(trim(cfg_docn_ice_file), NF90_NOWRITE, ncid)
      if (nc_rc == NF90_NOERR) then
        nc_rc = nf90_inq_dimid(ncid, 'time', dimid)
        if (nc_rc /= NF90_NOERR) nc_rc = nf90_inq_dimid(ncid, 'Time', dimid)
        if (nc_rc == NF90_NOERR) then
          nc_rc = nf90_inquire_dimension(ncid, dimid, len=ntime)
        end if
        nc_rc = nf90_close(ncid)
      end if
    end if

    ! Broadcast ntime para todos os PETs.
    ! ESMF_VMBroadcast(integer array): usar buf_n(1) como wrapper do escalar.
    buf_n(1) = ntime
    call ESMF_VMBroadcast(vm, bcstData=buf_n, count=1, rootPet=0, rc=rc)
    if (rc /= ESMF_SUCCESS) buf_n(1) = 365
    ntime = buf_n(1)
  end subroutine oisst_ntime

  !> Le do arquivo de gelo do OISST os instantes tidx0 e tidx1, interpola
  !! linearmente com peso alpha, converte de porcentagem se preciso e limita
  !! a [0,1]; o resultado fica em f0. Chamada so' pelo PET 0. Sem arquivo ou
  !! sem a variavel, f0 fica como estava.
  subroutine read_oisst_ifrac(nx_o, ny_o, tidx0, tidx1, alpha, f0, f1)
    integer,            intent(in)    :: nx_o, ny_o, tidx0, tidx1
    real(ESMF_KIND_R8), intent(in)    :: alpha
    real(ESMF_KIND_R8), intent(inout) :: f0(nx_o, ny_o), f1(nx_o, ny_o)
    integer :: ncid, varid, nc_rc

    nc_rc = nf90_open(trim(cfg_docn_ice_file), NF90_NOWRITE, ncid)
    if (nc_rc == NF90_NOERR) then
      nc_rc = nf90_inq_varid(ncid, trim(cfg_docn_ice_varname), varid)
      if (nc_rc == NF90_NOERR) then
        nc_rc = nf90_get_var(ncid, varid, f0, &
          start=[1, 1, tidx0], count=[nx_o, ny_o, 1])
        nc_rc = nf90_get_var(ncid, varid, f1, &
          start=[1, 1, tidx1], count=[nx_o, ny_o, 1])
        ! Interpolação temporal linear
        f0 = f0 + alpha * (f1 - f0)
        if (cfg_docn_ice_pct) f0 = f0 / 100.0_ESMF_KIND_R8
        f0 = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, f0))
      end if
      nc_rc = nf90_close(ncid)
    end if
  end subroutine read_oisst_ifrac

  !> Leva a fracao de gelo do OISST (f0, grade nx_o x ny_o) a porcao local
  !! fptr da grade ATM interna, pelo ponto mais proximo, limitada a [0,1].
  subroutine oisst_to_atm_nearest(f0, nx_o, ny_o, dx_o, dy_o, dx_a, dy_a, fptr)
    integer,            intent(in) :: nx_o, ny_o
    real(ESMF_KIND_R8), intent(in) :: f0(nx_o, ny_o)
    real(ESMF_KIND_R8), intent(in) :: dx_o, dy_o, dx_a, dy_a
    real(ESMF_KIND_R8), pointer, intent(in) :: fptr(:,:)
    integer :: i, j, i_o, j_o
    real(ESMF_KIND_R8) :: lon_a, lat_a

    do j = lbound(fptr,2), ubound(fptr,2)
      lat_a = -90.0_ESMF_KIND_R8 + (real(j,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * dy_a
      j_o   = indice_trunca(lat_a + 90.0_ESMF_KIND_R8, dy_o, ny_o)
      do i = lbound(fptr,1), ubound(fptr,1)
        lon_a = (real(i,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * dx_a
        i_o   = indice_trunca(lon_a, dx_o, nx_o)
        fptr(i,j) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, f0(i_o, j_o)))
      end do
    end do
  end subroutine oisst_to_atm_nearest

end module med_ocean_mod
