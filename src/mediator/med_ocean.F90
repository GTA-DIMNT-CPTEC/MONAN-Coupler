!> @file med_ocean.F90
!! @brief Campos do oceano na grade da atmosfera.
!!
!! SST, máscara de oceano, correntes superficiais e fração de gelo do OISST
!! (use_docn_ice), levados da grade OCN para a grade ATM interna do mediador.
!! Usa med_ice_mod para o gelo do SIS2.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_ocean_mod
  use ESMF
  use netcdf
  use coupler_constants_mod, only: ATM_NX, ATM_NY, SI_IFRAC_DECAY, T_FREEZE_SEAWATER
  use coupler_config_mod, only: cfg_docn_nx, cfg_docn_ny, cfg_use_docn_ice, &
                                cfg_docn_ice_init_only, &
                                cfg_docn_ice_file, cfg_docn_ice_varname, &
                                cfg_docn_ice_pct, cfg_docn_dt_data, &
                                cfg_docn_epoch_year, cfg_docn_epoch_month, &
                                cfg_docn_epoch_day, cfg_use_sis2_dynamic
  use med_cap_types_mod, only: MED_InternalState, med_fill_count_t, COMPL_SST, SST_BULK_FALLBACK
  use med_diag_mod, only: record_fill, log_sst_raw
  use coupler_log_mod, only: COMP_MED, log_info, log_debug, log_debug_enabled
  use med_cap_methods_mod, only: ZeroInternalField, route_fill
  use med_ice_mod, only: update_ice_fields_on_atm_grid
  use cpl_grids_mod, only: index_trunc

  implicit none
  private

  public :: update_ocean_fields_on_atm_grid
  public :: regrid_ocean_currents
  public :: update_ice_fraction_from_docn
  public :: legacy_ice_fraction

  ! Si_ifrac do OISST
  !
  ! is%run%ifrac_init_done : .true. após fill_ifrac_from_oisst ser chamado
  !   na primeira MediatorAdvance (estado interno, med_cap_types).
  !
  ! SI_IFRAC_DECAY (coupler_constants): fator de decaimento de Si_ifrac por
  !   passo de acoplamento (dt=3600 s, τ=86400 s): exp(-dt/τ) = exp(-1/24)
  !   ≈ 0.9592. O cap do oceano (mom_si_ifrac.F90) usa a mesma constante.

contains

  !> @brief SST na malha de fluxo: interpola So_t pela rota 'ocn2atm_sst'
  !! (ou 'ocn2atm', enquanto a máscara não tem terra e mar), com a contagem
  !! dos pontos completados.
  !! @param[in]    is                 estado interno do mediador
  !! @param[inout] importState        estado de importação
  !! @param[inout] field              So_t no importState
  !! @param[inout] raw_sst_diag_done  .true. depois do diagnóstico "DIAG sst raw"
  !! @param[inout] rc                 código de retorno
  subroutine update_ocean_fields_on_atm_grid(is, importState, field, raw_sst_diag_done, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: field
    logical, intent(inout) :: raw_sst_diag_done
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    integer :: n_invalid, n_left
    if (is%regrid%has('ocn2atm')) then
      call ESMF_StateGet(importState, itemName="So_t", field=field, rc=rc)

      ! So_t como chega do oceano, antes da interpolação (med_diag)
      if (log_debug_enabled()) call log_sst_raw(field, raw_sst_diag_done)


      ! Regrid da SST com a máscara real do oceano (So_omask) e extrapolação
      ! por vizinhança para a costa (etapa completar da rota ocn2atm_sst).
      ! A rota ocn2atm_sst é criada pela fase go_to_flux_grid
      ! (med_exchange) no primeiro passo em que a máscara tem terra e mar;
      ! até lá, a rota ocn2atm interpola e a SST é completada como na rota
      ! ocn2atm_sst.

      if (is%regrid%has('ocn2atm_sst')) then
        call is%regrid%apply('ocn2atm_sst', field, is%ocn%sst, rc, &
                             n_invalid=n_invalid, n_left=n_left)
      else
        call is%regrid%apply('ocn2atm', field, is%ocn%sst, rc, &
                             fill=route_fill('ocn2atm_sst'), &
                             n_invalid=n_invalid, n_left=n_left)
      end if
      if (n_invalid >= 0) call record_sst_fill(is%run%fill_counts(COMPL_SST), n_invalid, n_left)

      ! Regrid de correntes oceânicas OCN → ATM.
      ! So_u e So_v são anunciados e realizados no importState do MED
      ! (ocn_grid); ESMF_StateGet é seguro.
      ! Fallback seguro: se regrid falhar, mantém zeros em is%ocn%u/is%ocn%v.
      call regrid_ocean_currents(is, importState, zero_on_error=.false.)

      ! Si_ifrac_sis2, albedos e T_gelo, pela rota MASCARADA 'ocn2atm_ice',
      ! com extrapolação por vizinhança após o regrid: o mesmo tratamento da
      ! SST ('ocn2atm_sst'). A rota genérica 'ocn2atm' (sem máscara nem
      ! extrapolação) daria artefatos justamente onde o gelo se concentra, na
      ! região de deformação da malha tripolar (alta latitude).
      if (cfg_use_sis2_dynamic) then
        call update_ice_fields_on_atm_grid(is, importState)
      end if
    else
      ! Routehandles não criados: usa SST padrão (já preenchido em InitializeRealize)
      call ESMF_FieldGet(is%ocn%sst, farrayPtr=sst, rc=rc)
    end if
  end subroutine update_ocean_fields_on_atm_grid

  !> @brief Soma os pontos da SST completados pela rota em cont, para o relatório
  !! de acoplamento, e os registra no log. O preenchimento (coluna fill
  !! da rota ocn2atm_sst, em ROUTES): média dos vizinhos válidos, em até 40
  !! passadas; o que sobrar recebe 271,35 K; valores acima de 310 K recebem
  !! 271,35 K antes da difusão.
  !!
  !! @param[inout] cont       contagem da SST
  !! @param[in]    n_invalid  pontos fora da faixa antes do preenchimento
  !! @param[in]    n_left     pontos que ficaram com o valor fixo
  subroutine record_sst_fill(cont, n_invalid, n_left)
    type(med_fill_count_t), intent(inout) :: cont
    integer,              intent(in)    :: n_invalid, n_left
    character(len=120) :: msg

    call record_fill(cont, n_invalid, n_left)
    if (n_invalid > 0) then
      write(msg,'(A,I0,A,I0,A)') 'SST extrapolada em ', n_invalid, &
        ' celulas (', n_left, ' com valor fixo)'
      call log_debug(COMP_MED, trim(msg))
    end if
  end subroutine record_sst_fill



  !> @brief Correntes oceânicas So_u/So_v para a grade ATM (rota ocn2atm).
  !! Com zero_on_error, a componente cuja interpolação falhar é zerada.
  subroutine regrid_ocean_currents(is, importState, zero_on_error)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    logical,                 intent(in)    :: zero_on_error

    call regrid_one('So_u', is%ocn%u)
    call regrid_one('So_v', is%ocn%v)

  contains

    !> Interpola um campo do importState pela rota 'ocn2atm'.
    !! @param[in]    name  nome do campo
    !! @param[inout] dst   destino na malha de fluxo
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

  !> @brief Fração de gelo do OISST (use_docn_ice): lê o arquivo no início
  !! (ou a cada passo, sem docn_ice_init_only) e, com docn_ice_init_only,
  !! aplica o decaimento SI_IFRAC_DECAY nos passos seguintes.
  !! @param[in]    is         estado interno do mediador
  !! @param[inout] clock      relógio do mediador
  !! @param[inout] ifrac_ptr  fração de gelo na malha de fluxo
  !! @param[inout] rc         código de retorno
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
      ! is%ice%ifrac (zero_med_fluxes não o zera neste modo).
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
        call log_debug(COMP_MED, 'Si_ifrac: decaimento SI_IFRAC_DECAY aplicado')
    end if
  end subroutine update_ice_fraction_from_docn

  !> @brief Fração de gelo na malha de fluxo sem o SIS2 dinâmico.
  !!
  !! Com use_docn_ice, is%ice%ifrac já tem o OISST (fill_ifrac_from_oisst).
  !! Sem ele, lê "Si_ifrac" (SEM sufixo, campo diferente de "Si_ifrac_sis2")
  !! pela rota genérica 'ocn2atm', SEM máscara, e aplica a máscara
  !! SST~=T_FILL_LAND, que zera ifrac também em água aberta próxima da borda
  !! do gelo (SST no congelamento é esperada ali, não é sinal de terra). O
  !! mediador não anuncia "Si_ifrac", então a busca falha, e a fração sai
  !! do limiar de SST (docs/estado-do-projeto.md, seção 6).
  subroutine legacy_ice_fraction(is, importState, fptr, sst, j1, j2, i1, i2)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State), intent(inout) :: importState
    integer, intent(in) :: j1
    integer, intent(in) :: j2
    integer, intent(in) :: i1
    integer, intent(in) :: i2
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    integer :: i
    integer :: j
    type(ESMF_Field) :: f_ifrac_src
    integer          :: rc_if
    logical          :: regrid_ok
    real(ESMF_KIND_R8), parameter :: TOL_LAND = 1.0e-6_ESMF_KIND_R8
    integer :: n_ifrac_land
    character(len=160) :: logmsg
    real(ESMF_KIND_R8) :: sst_eff_if

    ! Fonte de Si_ifrac por modo (nuopc.input &nuopc_mode):
    !   use_docn_ice=T  init_only=F  → is%ice%ifrac já preenchida
    !     com OISST por fill_ifrac_from_oisst.
    !     regrid_ok=T pula o regrid e o fallback SST.
    !   use_docn_ice=T  init_only=T  → idem: is%ice%ifrac guarda o OISST
    !     de t=0 (com decaimento) de fill_ifrac_from_oisst.
    !   use_docn_ice=F               → Si_ifrac do OCN via importState,
    !     pela rota 'ocn2atm'.
    if (cfg_use_docn_ice) then
      regrid_ok = .true.   ! is%ice%ifrac de fill_ifrac_from_oisst
    else
      regrid_ok = .false.  ! Si_ifrac do OCN via importState
    end if

    if (.not. regrid_ok .and. is%regrid%has('ocn2atm')) then
      call ESMF_StateGet(importState, itemName="Si_ifrac", &
                         field=f_ifrac_src, rc=rc_if)
      if (rc_if == ESMF_SUCCESS) then
        call is%regrid%apply('ocn2atm', f_ifrac_src, is%ice%ifrac, rc_if)
        if (rc_if == ESMF_SUCCESS) then
          regrid_ok = .true.
          call ESMF_FieldGet(is%ice%ifrac, farrayPtr=fptr, rc=rc_if)
          if (rc_if == ESMF_SUCCESS .and. associated(fptr)) then
            where (fptr < 0.0_ESMF_KIND_R8) fptr = 0.0_ESMF_KIND_R8
            where (fptr > 1.0_ESMF_KIND_R8) fptr = 1.0_ESMF_KIND_R8
            where (fptr /= fptr)            fptr = 0.0_ESMF_KIND_R8  ! NaN
            ! Defesa em profundidade: zera ifrac onde sst = T_FILL_LAND
              if (associated(sst)) then
                n_ifrac_land = count(abs(sst - T_FREEZE_SEAWATER) < TOL_LAND &
                                     .and. fptr > 0.0_ESMF_KIND_R8)
                where (abs(sst - T_FREEZE_SEAWATER) < TOL_LAND) fptr = 0.0_ESMF_KIND_R8
                if (n_ifrac_land > 0) then
                    write(logmsg,'(A,I0,A)') &
                      'Si_ifrac zerado em ', &
                      n_ifrac_land, ' celulas de terra (SST no marcador de terra)'
                    call log_debug(COMP_MED, trim(logmsg))
                end if
              end if
          end if
          call log_debug(COMP_MED, 'Si_ifrac interpolado pela rota ocn2atm, com a ' // &
            'mascara de terra')
        end if
      end if
    end if

    ! Fallback: limiar de SST (.5.2 — condição mais restritiva)
    if (.not. regrid_ok) then
      call ESMF_FieldGet(is%ice%ifrac, farrayPtr=fptr, rc=rc_if)
      if (rc_if == ESMF_SUCCESS .and. associated(fptr) .and. associated(sst)) then
        ! SST efetiva de cada célula em sst_eff_if, com clamp.
          do j = j1, j2
            do i = i1, i2
              ! Clamp: valores fora de [271, 308] K são inválidos ou terra.
              sst_eff_if = merge(sst(i,j), SST_BULK_FALLBACK,          &
                sst(i,j) > 271.0_ESMF_KIND_R8 .and.                    &
                sst(i,j) < 308.0_ESMF_KIND_R8)
              ! Limiar 271.34 K < 271.35 K (marcador de terra):
              ! garante que células terrestres não sejam classificadas como gelo.
              fptr(i,j) = merge(1.0_ESMF_KIND_R8, 0.0_ESMF_KIND_R8,   &
                sst_eff_if < 271.34_ESMF_KIND_R8)
            end do
          end do
        call log_debug(COMP_MED, 'Si_ifrac calculado pelo limiar de SST')
      end if
    end if
  end subroutine legacy_ice_fraction


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

    ! Número de instantes do arquivo, lido no PET 0 e difundido
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
      'f_ifrac_atm preenchido de ', trim(cfg_docn_ice_file), &
      '  alpha=', alpha
    call log_info(COMP_MED, trim(logmsg))
    rc = ESMF_SUCCESS

  end subroutine fill_ifrac_from_oisst

  !> @brief Número de instantes (dimensão time ou Time) do arquivo de gelo do
  !! OISST, lido pelo PET 0 e difundido a todos os PETs da VM. Sem arquivo
  !! ou sem a dimensão, e se a difusão falhar, vale 365.
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

  !> @brief Le do arquivo de gelo do OISST os instantes tidx0 e tidx1, interpola
  !! linearmente com peso alpha, converte de porcentagem se preciso e limita
  !! a [0,1]; o resultado fica em f0. Chamada só pelo PET 0. Sem arquivo ou
  !! sem a variável, f0 fica como estava.
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

  !> @brief Leva a fração de gelo do OISST (f0, grade nx_o x ny_o) a porção local
  !! fptr da grade ATM interna, pelo ponto mais próximo, limitada a [0,1].
  subroutine oisst_to_atm_nearest(f0, nx_o, ny_o, dx_o, dy_o, dx_a, dy_a, fptr)
    integer,            intent(in) :: nx_o, ny_o
    real(ESMF_KIND_R8), intent(in) :: f0(nx_o, ny_o)
    real(ESMF_KIND_R8), intent(in) :: dx_o, dy_o, dx_a, dy_a
    real(ESMF_KIND_R8), pointer, intent(in) :: fptr(:,:)
    integer :: i, j, i_o, j_o
    real(ESMF_KIND_R8) :: lon_a, lat_a

    do j = lbound(fptr,2), ubound(fptr,2)
      lat_a = -90.0_ESMF_KIND_R8 + (real(j,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * dy_a
      j_o   = index_trunc(lat_a + 90.0_ESMF_KIND_R8, dy_o, ny_o)
      do i = lbound(fptr,1), ubound(fptr,1)
        lon_a = (real(i,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * dx_a
        i_o   = index_trunc(lon_a, dx_o, nx_o)
        fptr(i,j) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, f0(i_o, j_o)))
      end do
    end do
  end subroutine oisst_to_atm_nearest

end module med_ocean_mod
