!> @file med_export.F90
!! @brief Exportação dos campos do mediador para os componentes.
!!
!! Campos da malha de fluxo levados aos campos do exportState, com a zeragem
!! sobre terra: os que voltam pela rota 'atm2ocn', num laço sobre o mapa de
!! acoplamento, e a fração de gelo, pela rota 'atm2ocn_ice'. Chamado
!! pela fase deliver (med_exchange), que carimba o tempo dos campos
!! exportados.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_export_mod
  use ESMF
  use med_cap_types_mod, only: MED_InternalState, COMPL_IFRAC_EXP, med_field_index
  use cpl_fields_mod, only: CPL_NAME_LEN
  use cpl_map_mod, only: cpl_route_fields
  use coupler_config_mod, only: cpl_current_config
  use med_diag_mod, only: record_fill
  use med_cap_methods_mod, only: FillInternalField, RegridOrCopy, route_fill
  use coupler_constants_mod, only: T_ICE_MIN
  use coupler_log_mod, only: COMP_MED, log_error, log_info, log_warning, log_debug

  implicit none
  private

  public :: export_to_components

contains

  !> @brief Leva os campos da malha de fluxo para o exportState: máscara de
  !! terra (uma vez), zeragem dos fluxos sobre terra, fração de gelo,
  !! temperatura de superfície composta e, pelo mapa, os demais campos.
  !!
  !! Os campos que chegam a MED@ocn_med pela rota 'atm2ocn' no mapa de
  !! acoplamento (cpl_route_fields) são exportados num laço, na ordem do
  !! mapa: cada um sai do registro de campos internos (MED_FIELDS) e vai ao
  !! exportState por RegridOrCopy. Cada interpolação é independente das
  !! outras, e a ordem não muda os valores. Uma falha de um campo fica no
  !! log (RegridOrCopy a registra) e não interrompe a exportação: o campo
  !! mantém o valor anterior.
  !!
  !! Ficam explícitos, antes do laço:
  !!  - Si_ifrac, pela rota conservativa 'atm2ocn_ice' (export_ice_fraction):
  !!    a 'atm2ocn' (vizinho mais próximo, sem máscara nem extrapolação)
  !!    deixaria zeradas as células não alcançadas perto da dobra tripolar,
  !!    com manchas isoladas em vez de calota contínua;
  !!  - o cálculo de Sx_tsfc (export_surface_temperature), a temperatura
  !!    composta (1-ifrac)*SST + ifrac*Si_t_sis2, num campo separado, só
  !!    para o MONAN-A. So_t continua SST pura: o SIS2 a importa para o
  !!    fluxo de calor da BASE do gelo, e uma So_t misturada com a própria
  !!    temperatura do gelo reduziria o gradiente que controla o
  !!    derretimento basal.
  !!
  !! Sx_omask, So_u, So_v e Sf_zorl seguem o caminho de So_t: da malha de
  !! fluxo à grade do oceano por 'atm2ocn' e, pelo conector MED -> MPAS, até
  !! o cap atmosférico. O diagnóstico mom6_import_*.nc lê is%ocn%omask
  !! direto na malha de fluxo, sem essa ida e volta.
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação (So_omask)
  !! @param[inout] exportState  estado de exportação
  !! @param[inout] rc           código de retorno
  subroutine export_to_components(is, importState, exportState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    integer, intent(inout) :: rc
    character(len=CPL_NAME_LEN), allocatable :: names(:)
    integer :: i, k

    ! So_omask não muda no tempo: interpolada na primeira chamada,
    ! is%ocn%omask vale para os passos seguintes.
    if (.not. is%ocn%omask_done) then
      call regrid_land_mask(is, importState)
    end if

    call zero_fluxes_over_land(is, rc)
    call export_ice_fraction(is, exportState, rc)
    call export_surface_temperature(is)

    call cpl_route_fields('atm2ocn', 'MED@ocn_med', cpl_current_config(), '', names)
    do i = 1, size(names)
      k = med_field_index(is, names(i))
      if (k == 0) then
        call log_error(COMP_MED, 'export_to_components: '//trim(names(i))// &
          ' chega pela rota atm2ocn no mapa, mas nao esta em MED_FIELDS')
        rc = ESMF_FAILURE
        return
      end if
      call RegridOrCopy(is%fields(k)%field, exportState, names(i), is, rc)
    end do
    rc = ESMF_SUCCESS

  end subroutine export_to_components

  !> @brief Temperatura de superfície composta (Sx_tsfc), média da SST e da
  !! temperatura do gelo ponderada pela fração de gelo.
  !! @param[in] is  estado interno do mediador
  subroutine export_surface_temperature(is)
    type(MED_InternalState), pointer :: is
    real(ESMF_KIND_R8), pointer :: p_sst_src(:,:), p_tice_comp(:,:), p_ifrac_comp(:,:)
    real(ESMF_KIND_R8), pointer :: p_tsfc_out(:,:)
    integer :: rc_tsfc
    real(ESMF_KIND_R8) :: ifrac_c
    integer :: ii_c, jj_c

    call ESMF_FieldGet(is%ocn%sst,   farrayPtr=p_sst_src,   rc=rc_tsfc)
    call ESMF_FieldGet(is%ice%tice,  farrayPtr=p_tice_comp, rc=rc_tsfc)
    call ESMF_FieldGet(is%ice%ifrac, farrayPtr=p_ifrac_comp,rc=rc_tsfc)
    call ESMF_FieldGet(is%sfc%tsfc,  farrayPtr=p_tsfc_out,  rc=rc_tsfc)
    if (associated(p_sst_src) .and. associated(p_tice_comp) .and. &
        associated(p_ifrac_comp) .and. associated(p_tsfc_out)) then
      do jj_c = lbound(p_sst_src,2), ubound(p_sst_src,2)
        do ii_c = lbound(p_sst_src,1), ubound(p_sst_src,1)
          ! Clamp defensivo local: não confia cegamente nas extrapolações
          ! upstream, mesma filosofia dos guards de NaN/faixa física
          ! usados no resto do arquivo (ex. clamp de Sf_albedo, So_t).
          ifrac_c = p_ifrac_comp(ii_c,jj_c)
          if (ifrac_c /= ifrac_c) ifrac_c = 0.0_ESMF_KIND_R8   ! NaN guard
          ifrac_c = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifrac_c))
          if (p_tice_comp(ii_c,jj_c) == p_tice_comp(ii_c,jj_c) .and. &
              p_tice_comp(ii_c,jj_c) > T_ICE_MIN .and. &
              p_tice_comp(ii_c,jj_c) < 280.0_ESMF_KIND_R8) then
            p_tsfc_out(ii_c,jj_c) = (1.0_ESMF_KIND_R8 - ifrac_c) * p_sst_src(ii_c,jj_c) &
                                     + ifrac_c * p_tice_comp(ii_c,jj_c)
          else
            ! Si_t_sis2 não regridou/extrapolou para um valor físico
            ! nesta célula: mantém SST pura em vez de contaminar com
            ! um valor suspeito, mesma lógica defensiva do fallback de
            ! Sf_albedo.
            p_tsfc_out(ii_c,jj_c) = p_sst_src(ii_c,jj_c)
          end if
        end do
      end do
    else
      ! Sem dado para compor: Sx_tsfc degrada para SST pura.
      if (associated(p_sst_src) .and. associated(p_tsfc_out)) &
        p_tsfc_out(:,:) = p_sst_src(:,:)
      call log_warning(COMP_MED, 'ponteiros de So_t/Si_t_sis2/Si_ifrac ' // &
        'indisponiveis: Sx_tsfc so com a SST')
    end if
  end subroutine export_surface_temperature

  !> @brief Fração de gelo exportada ao oceano (Si_ifrac), pela rota
  !! conservativa 'atm2ocn_ice', com a contagem dos pontos completados.
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] exportState  estado de exportação
  !! @param[inout] rc           código de retorno
  subroutine export_ice_fraction(is, exportState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: exportState
    integer, intent(inout) :: rc
    type(ESMF_Field) :: f_ifrac_exp
    integer :: rc_ifrac2
    integer :: n_invalid_pts, n_fixed_pts

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_ifrac_exp, rc=rc_ifrac2)
    if (rc_ifrac2 == ESMF_SUCCESS) then
      call FillInternalField(f_ifrac_exp, -999.0_ESMF_KIND_R8, rc_ifrac2)

      ! Rota conservativa 'atm2ocn_ice', como a 'ocn2atm_ice' na ida, com
      ! 'atm2ocn' como reserva; criada pela fase deliver (med_exchange).
      ! A rota completa por vizinhança os pontos fora de [0, 1] (coluna
      ! completar da atm2ocn_ice), também com a reserva atm2ocn.
      if (is%regrid%has('atm2ocn_ice')) then
        call is%regrid%apply('atm2ocn_ice', is%ice%ifrac, f_ifrac_exp, rc_ifrac2, &
                             n_invalid=n_invalid_pts, n_left=n_fixed_pts)
      else
        call is%regrid%apply('atm2ocn', is%ice%ifrac, f_ifrac_exp, rc_ifrac2, &
                             fill=route_fill('atm2ocn_ice'), &
                             n_invalid=n_invalid_pts, n_left=n_fixed_pts)
      end if
      if (n_invalid_pts >= 0) &
        call record_fill(is%run%fill_counts(COMPL_IFRAC_EXP), n_invalid_pts, n_fixed_pts)
    else
      ! exportState sem Si_ifrac realizado (não deveria acontecer): cópia
      ! direta, em vez de parar a rodada.
      call RegridOrCopy(is%ice%ifrac, exportState, "Si_ifrac", is, rc)
    end if
  end subroutine export_ice_fraction

  !> @brief Zera, sobre terra (máscara is%ocn%omask), os fluxos que o
  !! mediador envia ao oceano.
  !! @param[in]    is  estado interno do mediador
  !! @param[inout] rc  código de retorno
  subroutine zero_fluxes_over_land(is, rc)
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    integer :: n_land_masked
    real(ESMF_KIND_R8), pointer :: p_taux(:,:), p_tauy(:,:), p_sen(:,:)
    real(ESMF_KIND_R8), pointer :: p_evap(:,:), p_lwnet(:,:)
    real(ESMF_KIND_R8), pointer :: p_swvdr(:,:), p_swvdf(:,:)
    real(ESMF_KIND_R8), pointer :: p_swidr(:,:), p_swidf(:,:)
    real(ESMF_KIND_R8), pointer :: p_rain(:,:),  p_snow(:,:)
    real(ESMF_KIND_R8), pointer :: p_omask(:,:)
    logical, allocatable :: land_mask(:,:)
    character(len=160) :: logmsg

    nullify(p_taux, p_tauy, p_sen, p_evap, p_lwnet)
    nullify(p_swvdr, p_swvdf, p_swidr, p_swidf, p_rain, p_snow, p_omask)

    call ESMF_FieldGet(is%ocn%omask, farrayPtr=p_omask, rc=rc)
    if (associated(p_omask)) then
      ! Máscara REAL (So_omask regridada), e não
      ! inferida por SST. p_omask < 0.5 = terra (limiar central entre
      ! 0=terra e 1=oceano; robusto a pequena mistura de borda do
      ! regrid NEAREST_STOD, que deveria ser quase sempre exatamente
      ! 0 ou 1 de qualquer forma).
      allocate(land_mask(lbound(p_omask,1):ubound(p_omask,1), &
                         lbound(p_omask,2):ubound(p_omask,2)))
      land_mask = (p_omask < 0.5_ESMF_KIND_R8)
      n_land_masked = count(land_mask)

      ! Helper macro: aplicar máscara em cada fluxo
      call ESMF_FieldGet(is%ocn_flx%taux,  farrayPtr=p_taux,  rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_taux))  &
        where (land_mask) p_taux  = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%tauy,  farrayPtr=p_tauy,  rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_tauy))  &
        where (land_mask) p_tauy  = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%sen,   farrayPtr=p_sen,   rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_sen))   &
        where (land_mask) p_sen   = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%evap,  farrayPtr=p_evap,  rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_evap))  &
        where (land_mask) p_evap  = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%lwnet, farrayPtr=p_lwnet, rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_lwnet)) &
        where (land_mask) p_lwnet = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%swvdr, farrayPtr=p_swvdr, rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_swvdr)) &
        where (land_mask) p_swvdr = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%swvdf, farrayPtr=p_swvdf, rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_swvdf)) &
        where (land_mask) p_swvdf = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%swidr, farrayPtr=p_swidr, rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_swidr)) &
        where (land_mask) p_swidr = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%swidf, farrayPtr=p_swidf, rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_swidf)) &
        where (land_mask) p_swidf = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%rain,  farrayPtr=p_rain,  rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_rain))  &
        where (land_mask) p_rain  = 0.0_ESMF_KIND_R8
      call ESMF_FieldGet(is%ocn_flx%snow,  farrayPtr=p_snow,  rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(p_snow))  &
        where (land_mask) p_snow  = 0.0_ESMF_KIND_R8
      rc = ESMF_SUCCESS

      write(logmsg, '(A,I0,A)') 'fluxos zerados em ', n_land_masked, &
        ' celulas de terra (mascara So_omask)'
      call log_debug(COMP_MED, trim(logmsg))

      deallocate(land_mask)
    end if
  end subroutine zero_fluxes_over_land

  !> @brief Interpola So_omask para a grade ATM (is%ocn%omask), uma vez por
  !! rodada, pela rota 'ocn2atm_landmask'.
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação
  subroutine regrid_land_mask(is, importState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field) :: omask_src_field
    integer :: rc_lm

    ! A rota ocn2atm_landmask é criada pela fase deliver (med_exchange).
    call ESMF_StateGet(importState, itemName="So_omask", &
      field=omask_src_field, rc=rc_lm)
    if (rc_lm == ESMF_SUCCESS) then
      if (is%regrid%has('ocn2atm_landmask')) then
        call is%regrid%apply('ocn2atm_landmask', omask_src_field, is%ocn%omask, rc_lm)
        call log_info(COMP_MED, 'mascara terra/oceano interpolada para a grade ATM')
      else
        ! is%ocn%omask continua 1.0 (tudo oceano)
        call log_warning(COMP_MED, 'rota ocn2atm_landmask ausente: mascara ' // &
          'mantida em tudo oceano (1.0)')
      end if
    else
      call log_warning(COMP_MED, 'So_omask indisponivel: mascara mantida em ' // &
        'tudo oceano (1.0)')
    end if
    is%ocn%omask_done = .true.
  end subroutine regrid_land_mask


end module med_export_mod
