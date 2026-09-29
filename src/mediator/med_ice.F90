!> @file med_ice.F90
!! @brief Gelo do SIS2 na grade da atmosfera.
!!
!! update_ice_fields_on_atm_grid e as suas oito etapas: rota mascarada
!! 'ocn2atm_ice', sentinelas, interpolação da fração, dos albedos e da
!! temperatura do gelo, extrapolação por vizinhança e diagnósticos do log.
!!
!! Separado de MED_cap.F90 sem mudar instruções (R-FASE8-01).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_ice_mod
  use ESMF
  use coupler_constants_mod, only: ATM_NX, ATM_NY, T_FREEZE_SEAWATER, T_ICE_MIN, &
                                   T_ICE_MAX, ALB_ICE_DEFAULT
  use diag_bitsum_mod, only: diag_bitsum_log
  use regrid_base_mod, only: regrid_fill_t, neighbor_fill
  use regrid_manager_mod, only: regrid_spec, regrid_manager_t
  use coupler_config_mod, only: cfg_write_fixdiag
  use med_cap_types_mod, only: MED_InternalState
  use med_cap_methods_mod, only: FillInternalField

  implicit none
  private

  public :: update_ice_fields_on_atm_grid

contains

  !============================================================================
  !> @brief Traz o gelo do SIS2 para a grade ATM: fração, albedos e temperatura.
  !!
  !! Etapas, nesta ordem:
  !!   1. cria a rota mascarada 'ocn2atm_ice' na primeira chamada;
  !!   2. preenche os seis campos de destino com a sentinela -999;
  !!   3. interpola Si_ifrac_sis2 (com diagnósticos antes e depois);
  !!   4. interpola os quatro albedos e Si_t_sis2;
  !!   5. extrapola por vizinhança cada campo, com faixa válida e valor
  !!      padrão próprios (com a checagem geográfica da fração de gelo).
  !!
  !! O código de retorno rc_ice encadeia as etapas 2 e 3: o diagnóstico da
  !! origem e a interpolação da fração dependem do resultado do último
  !! preenchimento da etapa 2, e o diagnóstico do destino depende do
  !! resultado da interpolação.
  !============================================================================
  subroutine update_ice_fields_on_atm_grid(is, importState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field) :: f_ifrac_src
    integer :: rc_ice
    real(ESMF_KIND_R8), pointer :: p_ifrac_out(:,:)
    integer :: rc_nfe
    integer :: rc_bs

    call ESMF_StateGet(importState, itemName="Si_ifrac_sis2", &
      field=f_ifrac_src, rc=rc_ice)

    if (.not. is%regrid%has('ocn2atm_ice') .and. rc_ice == ESMF_SUCCESS) &
      call add_ice_route(is, importState, f_ifrac_src)

    call fill_ice_sentinels(is, rc_ice)

    if (cfg_write_fixdiag .and. rc_ice == ESMF_SUCCESS) &
      call log_ice_source(f_ifrac_src)

    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_ifrac_src, is%ice%ifrac, rc_ice, &
        zero_total=.false.)

    if (cfg_write_fixdiag .and. rc_ice == ESMF_SUCCESS) &
      call log_ice_destination(is)

    if (cfg_write_fixdiag) call log_ifrac_raw(is)

    call regrid_ice_member(is%regrid, importState, "Si_avsdr_sis2", is%ice%alb_vdr)
    call regrid_ice_member(is%regrid, importState, "Si_avsdf_sis2", is%ice%alb_vdf)
    call regrid_ice_member(is%regrid, importState, "Si_anidr_sis2", is%ice%alb_idr)
    call regrid_ice_member(is%regrid, importState, "Si_anidf_sis2", is%ice%alb_idf)
    call regrid_ice_member(is%regrid, importState, "Si_t_sis2",     is%ice%tice)

    ! Extrapolação por vizinhança: fecha buracos e a costura da região de
    ! deformação tripolar, com o mesmo algoritmo usado para So_t.
    call ESMF_FieldGet(is%ice%ifrac,   farrayPtr=p_ifrac_out, rc=rc_nfe)
    if (associated(p_ifrac_out)) &
      call neighbor_fill(p_ifrac_out, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.0_ESMF_KIND_R8))

    ! Checksum exato de is%ice%ifrac depois da extrapolação.
    if (cfg_write_fixdiag) then
        call diag_bitsum_log('etapa3 f_ifrac_atm pos-extrapolacao', &
                             is%ice%ifrac, rc_bs)
    end if

    if (cfg_write_fixdiag .and. associated(p_ifrac_out)) &
      call check_ice_geography(p_ifrac_out)

    call extrapolate_ice_field(is%ice%alb_vdr, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT))
    call extrapolate_ice_field(is%ice%alb_vdf, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT))
    call extrapolate_ice_field(is%ice%alb_idr, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT))
    call extrapolate_ice_field(is%ice%alb_idf, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT))
    call extrapolate_ice_field(is%ice%tice, regrid_fill_t(enabled=.true., &
      vmin=T_ICE_MIN, vmax=T_ICE_MAX, vfill=T_FREEZE_SEAWATER))

    call ESMF_LogWrite('MED(B-ICEREGRID-01): Si_ifrac_sis2/Si_a*_sis2/' // &
      'Si_t_sis2 regridados via rh_ocn2atm_ice + extrapolacao de vizinhanca', &
      ESMF_LOGMSG_INFO)
  end subroutine update_ice_fields_on_atm_grid

  !============================================================================
  !> @brief Cria a rota 'ocn2atm_ice' (conservativa, com máscara na origem).
  !!
  !! Antes de criar a rota, copia So_omask (1 = oceano, 0 = terra) para a
  !! máscara de is%ocn_grid, de modo que a rota não dependa de a SST ter
  !! sido interpolada antes. O método é 'conserve', que conserva a área e
  !! é o adequado para uma fração; 'bilinear' fica como reserva.
  !!
  !! Com cfg_write_fixdiag, registra quantos pontos de terra e de oceano
  !! este PET viu na máscara (FIX-DIAG-ICEMASK-01), para confirmar que
  !! So_omask foi encontrada e não está toda em terra ou toda em oceano.
  !============================================================================
  subroutine add_ice_route(is, importState, f_ifrac_src)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    type(ESMF_Field),        intent(inout) :: f_ifrac_src
    real(ESMF_KIND_R8), pointer :: omask_src(:,:)
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    type(ESMF_Field) :: omask_field
    integer :: lde_s
    integer :: ldec_ocn
    integer :: rc_omask
    integer :: rc_store
    integer :: n_land_ice
    integer :: n_sea_ice
    character(len=200) :: diag_msg_mask

    n_land_ice = 0; n_sea_ice = 0
    call ESMF_StateGet(importState, itemName="So_omask", &
      field=omask_field, rc=rc_omask)
    if (rc_omask == ESMF_SUCCESS) then
      call ESMF_GridGet(is%ocn_grid, localDeCount=ldec_ocn, rc=rc_store)
      if (rc_store == ESMF_SUCCESS) then
        do lde_s = 0, ldec_ocn - 1
          call ESMF_FieldGet(omask_field, localDe=lde_s, &
            farrayPtr=omask_src, rc=rc_store)
          if (rc_store /= ESMF_SUCCESS .or. .not. associated(omask_src)) cycle
          call ESMF_GridGetItem(is%ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
            staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_s, &
            farrayPtr=maskptr, rc=rc_store)
          if (rc_store == ESMF_SUCCESS .and. associated(maskptr)) then
            maskptr = nint(omask_src)
            ! conta terra/oceano vistos por
            ! ESTE PET, para confirmar que So_omask foi de fato
            ! encontrada e tem uma mistura sensata dos dois
            ! valores (nao tudo-terra nem tudo-oceano por engano).
            n_land_ice = n_land_ice + count(maskptr == 0)
            n_sea_ice  = n_sea_ice  + count(maskptr == 1)
          end if
        end do
      end if
    end if
    if (cfg_write_fixdiag) then
        write(diag_msg_mask,'(A,L1,A,I0,A,I0)') &
          'FIX-DIAG-ICEMASK-01: So_omask encontrada=', &
          (rc_omask == ESMF_SUCCESS), ' n_land=', n_land_ice, &
          ' n_sea=', n_sea_ice
        call ESMF_LogWrite(trim(diag_msg_mask), ESMF_LOGMSG_INFO)
    end if
    call is%regrid%add('ocn2atm_ice', regrid_spec('conserve,bilinear', mask_src=.true.), &
      f_ifrac_src, is%ice%ifrac, rc_store, fallback='ocn2atm')
  end subroutine add_ice_route

  !============================================================================
  !> @brief Preenche os seis campos de gelo na grade ATM com a sentinela -999.
  !!
  !! A interpolação da fração usa zero_total=.false.: só escreve onde a rota
  !! mapeou algum ponto. As demais células ficam com -999, fora de qualquer
  !! faixa válida, e a extrapolação por vizinhança as reconhece como
  !! inválidas. Com zero, que está dentro da faixa [0,1], essas células
  !! passariam por válidas.
  !!
  !! rc recebe o resultado do último preenchimento (is%ice%tice).
  !============================================================================
  subroutine fill_ice_sentinels(is, rc_ice)
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc_ice

    call FillInternalField(is%ice%ifrac,   -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%ice%alb_vdr,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%ice%alb_vdf,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%ice%alb_idr,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%ice%alb_idf,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%ice%tice,     -999.0_ESMF_KIND_R8, rc_ice)
  end subroutine fill_ice_sentinels

  !============================================================================
  !> @brief Diagnóstico da fração de gelo na grade do oceano, antes da interpolação.
  !!
  !! FIX-DIAG-ICESRC-01 registra mínimo, máximo e soma de Si_ifrac_sis2 no
  !! DE local, com quinze algarismos, e o checksum exato do campo (etapa 1
  !! de 4). Os valores são locais ao PET: compare sempre o mesmo PET entre
  !! execuções. Com o ICESRC-02, permite saber se uma divergência entre
  !! execuções já vem do SIS2 ou nasce na interpolação.
  !============================================================================
  subroutine log_ice_source(f_ifrac_src)
    type(ESMF_Field), intent(in) :: f_ifrac_src
    real(ESMF_KIND_R8), pointer :: p_ifrac_in(:,:)
    character(len=300) :: diag_msg_src
    integer :: rc_src
    integer :: rc_bs

    call ESMF_FieldGet(f_ifrac_src, farrayPtr=p_ifrac_in, rc=rc_src)
    if (rc_src == ESMF_SUCCESS .and. associated(p_ifrac_in)) then
      write(diag_msg_src,'(A,ES24.16,A,ES24.16,A,ES24.16,A,I0)') &
        'FIX-DIAG-ICESRC-01: Si_ifrac_sis2 (ORIGEM, pre-regrid)' // &
        ' min=', minval(p_ifrac_in), &
        ' max=', maxval(p_ifrac_in), &
        ' soma=', sum(p_ifrac_in),   &
        ' n_local=', size(p_ifrac_in)
      call ESMF_LogWrite(trim(diag_msg_src), ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite('FIX-DIAG-ICESRC-01: farrayPtr de ' // &
        'Si_ifrac_sis2 indisponivel; origem NAO medida', &
        ESMF_LOGMSG_WARNING)
    end if

    call diag_bitsum_log('etapa1 Si_ifrac_sis2 ORIGEM pre-regrid', &
                         f_ifrac_src, rc_bs)
  end subroutine log_ice_source

  !============================================================================
  !> @brief Diagnóstico da fração de gelo na grade ATM, logo após a interpolação.
  !!
  !! FIX-DIAG-ICESRC-02 registra, com quinze algarismos, o máximo e a soma
  !! das células mapeadas e o número de células com a sentinela -999 (não
  !! mapeadas), antes da extrapolação. Em seguida, o checksum exato do
  !! campo (etapa 2 de 4).
  !============================================================================
  subroutine log_ice_destination(is)
    type(MED_InternalState), intent(in) :: is
    real(ESMF_KIND_R8), pointer :: p_ifrac_dst(:,:)
    character(len=300) :: diag_msg_dst
    integer :: rc_dst
    integer :: n_sent
    integer :: rc_bs

    call ESMF_FieldGet(is%ice%ifrac, farrayPtr=p_ifrac_dst, rc=rc_dst)
    if (rc_dst == ESMF_SUCCESS .and. associated(p_ifrac_dst)) then
      ! A sentinela -999 marca celula nao mapeada pelo regrid; ela
      ! domina min e soma, entao entra contada a parte para que o
      ! numero de nao mapeadas seja comparavel entre execucoes.
      n_sent = count(p_ifrac_dst < -900.0_ESMF_KIND_R8)
      write(diag_msg_dst,'(A,ES24.16,A,ES24.16,A,I0,A,I0)') &
        'FIX-DIAG-ICESRC-02: f_ifrac_atm (DESTINO, pos-regrid)' // &
        ' max=', maxval(p_ifrac_dst), &
        ' soma_validos=', &
        sum(p_ifrac_dst, mask=(p_ifrac_dst > -900.0_ESMF_KIND_R8)), &
        ' n_sentinela=', n_sent, &
        ' n_local=', size(p_ifrac_dst)
      call ESMF_LogWrite(trim(diag_msg_dst), ESMF_LOGMSG_INFO)
    end if

    call diag_bitsum_log('etapa2 f_ifrac_atm DESTINO pos-regrid', &
                         is%ice%ifrac, rc_bs)
  end subroutine log_ice_destination

  !============================================================================
  !> @brief Diagnóstico FIX-DIAG-ICEMASK-02 da fração de gelo interpolada.
  !!
  !! Registra mínimo e máximo antes da extrapolação e conta as células
  !! exatamente iguais a zero. Muitas células em zero indicam problema na
  !! interpolação ou na máscara, e não na física do SIS2.
  !============================================================================
  subroutine log_ifrac_raw(is)
    type(MED_InternalState), intent(in) :: is
    real(ESMF_KIND_R8), pointer :: p_ifrac_raw(:,:)
    character(len=250) :: diag_msg_raw
    integer :: n_exact_zero
    integer :: n_total
    integer :: rc_ice

    call ESMF_FieldGet(is%ice%ifrac, farrayPtr=p_ifrac_raw, rc=rc_ice)
    if (associated(p_ifrac_raw)) then
      n_exact_zero = count(p_ifrac_raw == 0.0_ESMF_KIND_R8)
      n_total = size(p_ifrac_raw)
      write(diag_msg_raw,'(A,ES10.3,A,ES10.3,A,I0,A,I0)') &
        'FIX-DIAG-ICEMASK-02: ifrac (bruto, pre-extrapolacao) min=', &
        minval(p_ifrac_raw), ' max=', maxval(p_ifrac_raw), &
        ' | n_exact_zero=', n_exact_zero, ' de n_total=', n_total
      call ESMF_LogWrite(trim(diag_msg_raw), ESMF_LOGMSG_INFO)
    end if
  end subroutine log_ifrac_raw

  !============================================================================
  !> @brief Interpola um campo do SIS2 pela rota 'ocn2atm_ice', se ele existir.
  !!
  !! Sem o campo no importState, o destino fica como está (com a sentinela).
  !============================================================================
  subroutine regrid_ice_member(regrid, importState, item_name, dst)
    type(regrid_manager_t), intent(inout) :: regrid
    type(ESMF_State),       intent(inout) :: importState
    character(len=*),       intent(in)    :: item_name
    type(ESMF_Field),       intent(inout) :: dst
    type(ESMF_Field) :: f_src
    integer :: rc_ice

    call ESMF_StateGet(importState, itemName=item_name, &
      field=f_src, rc=rc_ice)
    if (rc_ice == ESMF_SUCCESS) &
      call regrid%apply('ocn2atm_ice', f_src, dst, rc_ice, &
        zero_total=.false.)
  end subroutine regrid_ice_member

  !============================================================================
  !> @brief Extrapola por vizinhança um campo de gelo na grade ATM.
  !============================================================================
  subroutine extrapolate_ice_field(field, fill)
    type(ESMF_Field),    intent(in) :: field
    type(regrid_fill_t), intent(in) :: fill
    real(ESMF_KIND_R8), pointer :: p_out(:,:)
    integer :: rc_nfe

    call ESMF_FieldGet(field, farrayPtr=p_out, rc=rc_nfe)
    if (associated(p_out)) &
      call neighbor_fill(p_out, fill)
  end subroutine extrapolate_ice_field

  !============================================================================
  !> @brief Alerta de gelo em latitude implausível (FIX-DIAG-ICEGEO-01).
  !!
  !! Calcula a latitude e a longitude de cada célula da grade ATM 360x180
  !! pela fórmula analítica da grade, sem depender de qual PET cuida de
  !! qual parte do domínio. Conta as células com ifrac > 0,05 em
  !! |lat| < 55 graus, onde não existe gelo marinho em nenhuma época do
  !! ano, e registra a primeira encontrada neste PET.
  !============================================================================
  subroutine check_ice_geography(p_ifrac_out)
    real(ESMF_KIND_R8), pointer, intent(in) :: p_ifrac_out(:,:)
    real(ESMF_KIND_R8), parameter :: LAT_MAX_GELO = 55.0_ESMF_KIND_R8
    integer :: ii_geo
    integer :: jj_geo
    integer :: n_bad_geo
    real(ESMF_KIND_R8) :: lat_bad
    real(ESMF_KIND_R8) :: lon_bad
    real(ESMF_KIND_R8) :: val_bad
    character(len=250) :: diag_msg_geo
    real(ESMF_KIND_R8) :: lat_here
    real(ESMF_KIND_R8) :: lon_here

    n_bad_geo = 0; lat_bad = -999.0_ESMF_KIND_R8
    lon_bad = -999.0_ESMF_KIND_R8; val_bad = -999.0_ESMF_KIND_R8
    do jj_geo = lbound(p_ifrac_out,2), ubound(p_ifrac_out,2)
      do ii_geo = lbound(p_ifrac_out,1), ubound(p_ifrac_out,1)
        if (p_ifrac_out(ii_geo,jj_geo) > 0.05_ESMF_KIND_R8) then
            lon_here = (real(ii_geo,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * &
                       (360.0_ESMF_KIND_R8/ATM_NX) + 0.5_ESMF_KIND_R8*(360.0_ESMF_KIND_R8/ATM_NX)
            lat_here = -90.0_ESMF_KIND_R8 + (real(jj_geo,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * &
                       (180.0_ESMF_KIND_R8/ATM_NY) + 0.5_ESMF_KIND_R8*(180.0_ESMF_KIND_R8/ATM_NY)
            if (abs(lat_here) < LAT_MAX_GELO) then
              n_bad_geo = n_bad_geo + 1
              if (lat_bad < -900.0_ESMF_KIND_R8) then
                lat_bad = lat_here; lon_bad = lon_here
                val_bad = p_ifrac_out(ii_geo,jj_geo)
              end if
            end if
        end if
      end do
    end do
    if (n_bad_geo > 0) then
      write(diag_msg_geo,'(A,I0,A,ES10.3,A,ES10.3,A,ES10.3)') &
        'FIX-DIAG-ICEGEO-01: ALERTA -- ', n_bad_geo, &
        ' celula(s) com ifrac>0,05 em |lat|<55 (implausivel). ' // &
        'Primeira ocorrencia: lat=', lat_bad, ' lon=', lon_bad, &
        ' ifrac=', val_bad
      call ESMF_LogWrite(trim(diag_msg_geo), ESMF_LOGMSG_WARNING)
    end if
  end subroutine check_ice_geography

end module med_ice_mod
