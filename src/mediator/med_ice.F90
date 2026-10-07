!> @file med_ice.F90
!! @brief Gelo do SIS2 na grade da atmosfera.
!!
!! update_ice_fields_on_atm_grid e as suas etapas: sentinelas, interpolação
!! da fração, dos albedos e da temperatura do gelo pela rota mascarada
!! 'ocn2atm_ice' e extrapolação por vizinhança. A rota é criada pela fase
!! go_to_flux_grid (med_exchange). Os diagnósticos do caminho da fração de
!! gelo ficam em med_diag.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_ice_mod
  use ESMF
  use coupler_constants_mod, only: T_FREEZE_SEAWATER, T_ICE_MIN, T_ICE_MAX, &
                                   ALB_ICE_DEFAULT
  use regrid_base_mod, only: regrid_fill_t, neighbor_fill
  use regrid_manager_mod, only: regrid_manager_t
  use coupler_log_mod, only: COMP_MED, log_debug, log_debug_enabled
  use med_cap_types_mod, only: MED_InternalState, med_fill_count_t, COMPL_ICE_IFRAC, &
                               COMPL_ICE_AVSDR, COMPL_ICE_AVSDF, COMPL_ICE_ANIDR, &
                               COMPL_ICE_ANIDF, COMPL_ICE_T
  use med_diag_mod, only: record_fill, log_ice_source, log_ice_destination, log_ice_raw, &
                          log_ice_extrapolated, check_ice_geography
  use med_cap_methods_mod, only: FillInternalField

  implicit none
  private

  public :: update_ice_fields_on_atm_grid

contains

  !> @brief Traz o gelo do SIS2 para a grade ATM: fração, albedos e temperatura.
  !!
  !! Etapas, nesta ordem (a rota mascarada 'ocn2atm_ice' já foi criada pela
  !! fase go_to_flux_grid, em med_exchange):
  !!   1. preenche os seis campos de destino com a sentinela -999;
  !!   2. interpola Si_ifrac_sis2 (com diagnósticos antes e depois);
  !!   3. interpola os quatro albedos e Si_t_sis2;
  !!   4. extrapola por vizinhança cada campo, com faixa válida e valor
  !!      padrão próprios (com a checagem geográfica da fração de gelo).
  !!
  !! O código de retorno rc_ice encadeia as etapas 1 e 2: o diagnóstico da
  !! origem e a interpolação da fração dependem do resultado do último
  !! preenchimento da etapa 1, e o diagnóstico do destino depende do
  !! resultado da interpolação.
  subroutine update_ice_fields_on_atm_grid(is, importState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field) :: f_ifrac_src
    integer :: rc_ice
    real(ESMF_KIND_R8), pointer :: p_ifrac_out(:,:)
    integer :: rc_nfe
    integer :: n_invalid_pts, n_fixed_pts

    call ESMF_StateGet(importState, itemName="Si_ifrac_sis2", &
      field=f_ifrac_src, rc=rc_ice)

    call fill_ice_sentinels(is, rc_ice)

    if (log_debug_enabled() .and. rc_ice == ESMF_SUCCESS) &
      call log_ice_source(f_ifrac_src)

    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_ifrac_src, is%ice%ifrac, rc_ice)

    if (log_debug_enabled() .and. rc_ice == ESMF_SUCCESS) &
      call log_ice_destination(is%ice%ifrac)

    if (log_debug_enabled()) call log_ice_raw(is%ice%ifrac)

    call regrid_ice_member(is%regrid, importState, "Si_avsdr_sis2", is%ice%alb_vdr)
    call regrid_ice_member(is%regrid, importState, "Si_avsdf_sis2", is%ice%alb_vdf)
    call regrid_ice_member(is%regrid, importState, "Si_anidr_sis2", is%ice%alb_idr)
    call regrid_ice_member(is%regrid, importState, "Si_anidf_sis2", is%ice%alb_idf)
    call regrid_ice_member(is%regrid, importState, "Si_t_sis2",     is%ice%tice)

    ! Extrapolação por vizinhança: fecha buracos e a costura da região de
    ! deformação tripolar, com o mesmo algoritmo usado para So_t.
    call ESMF_FieldGet(is%ice%ifrac,   farrayPtr=p_ifrac_out, rc=rc_nfe)
    if (associated(p_ifrac_out)) then
      call neighbor_fill(p_ifrac_out, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.0_ESMF_KIND_R8), &
        n_left=n_fixed_pts, n_invalid=n_invalid_pts)
      call record_fill(is%run%fill_counts(COMPL_ICE_IFRAC), n_invalid_pts, n_fixed_pts)
    end if

    if (log_debug_enabled()) call log_ice_extrapolated(is%ice%ifrac)

    ! Alerta de gelo em latitude implausível: gravado em qualquer log_level.
    if (associated(p_ifrac_out)) &
      call check_ice_geography(p_ifrac_out)

    call extrapolate_ice_field(is%ice%alb_vdr, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT), &
      is%run%fill_counts(COMPL_ICE_AVSDR))
    call extrapolate_ice_field(is%ice%alb_vdf, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT), &
      is%run%fill_counts(COMPL_ICE_AVSDF))
    call extrapolate_ice_field(is%ice%alb_idr, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT), &
      is%run%fill_counts(COMPL_ICE_ANIDR))
    call extrapolate_ice_field(is%ice%alb_idf, regrid_fill_t(enabled=.true., &
      vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=ALB_ICE_DEFAULT), &
      is%run%fill_counts(COMPL_ICE_ANIDF))
    call extrapolate_ice_field(is%ice%tice, regrid_fill_t(enabled=.true., &
      vmin=T_ICE_MIN, vmax=T_ICE_MAX, vfill=T_FREEZE_SEAWATER), &
      is%run%fill_counts(COMPL_ICE_T))

    call log_debug(COMP_MED, 'Si_ifrac_sis2, Si_a*_sis2 e Si_t_sis2 interpolados ' // &
      'pela rota ocn2atm_ice e completados por vizinhanca')
  end subroutine update_ice_fields_on_atm_grid


  !> @brief Preenche os seis campos de gelo na grade ATM com a sentinela -999.
  !!
  !! A rota 'ocn2atm_ice' não zera o destino (sem_valor 'sentinela' em
  !! ROUTES): só escreve onde a interpolação alcança algum ponto. As demais células ficam com -999, fora de qualquer
  !! faixa válida, e a extrapolação por vizinhança as reconhece como
  !! inválidas. Com zero, que está dentro da faixa [0,1], essas células
  !! passariam por válidas.
  !!
  !! rc recebe o resultado do último preenchimento (is%ice%tice).
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

  !> @brief Interpola um campo do SIS2 pela rota 'ocn2atm_ice', se ele existir.
  !!
  !! Sem o campo no importState, o destino fica como está (com a sentinela).
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
      call regrid%apply('ocn2atm_ice', f_src, dst, rc_ice)
  end subroutine regrid_ice_member

  !> @brief Extrapola por vizinhança um campo de gelo na grade ATM.
  subroutine extrapolate_ice_field(field, fill, cont)
    type(ESMF_Field),     intent(in)    :: field
    type(regrid_fill_t),  intent(in)    :: fill
    type(med_fill_count_t), intent(inout) :: cont !< contagem para o relatório
    real(ESMF_KIND_R8), pointer :: p_out(:,:)
    integer :: rc_nfe, n_invalid_pts, n_fixed_pts

    call ESMF_FieldGet(field, farrayPtr=p_out, rc=rc_nfe)
    if (associated(p_out)) then
      call neighbor_fill(p_out, fill, n_left=n_fixed_pts, n_invalid=n_invalid_pts)
      call record_fill(cont, n_invalid_pts, n_fixed_pts)
    end if
  end subroutine extrapolate_ice_field

end module med_ice_mod
