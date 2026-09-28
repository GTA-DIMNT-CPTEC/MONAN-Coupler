!> @file med_export.F90
!! @brief Exportação dos campos do mediador para os componentes.
!!
!! Fluxos, temperatura de superfície e fração de gelo levados da grade ATM
!! interna para os campos do exportState, com a zeragem sobre terra e o
!! carimbo de tempo dos campos exportados.
!!
!! Separado de MED_cap.F90 sem mudar instruções (R-FASE8-01).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_export_mod
  use ESMF
  use regrid_base_mod, only: regrid_fill_t, neighbor_fill
  use regrid_manager_mod, only: regrid_spec
  use coupler_config_mod, only: cfg_write_fixdiag
  use NUOPC, only: NUOPC_SetTimestamp
  use med_cap_types_mod, only: MED_InternalState
  use med_cap_methods_mod, only: FillInternalField, RegridOrCopy

  implicit none
  private

  public :: export_to_components
  public :: stamp_export_fields

contains

  subroutine export_to_components(is, importState, exportState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    integer, intent(inout) :: rc
    integer :: rc_sst
    real(ESMF_KIND_R8), pointer :: sst_diag(:,:)
    if (.not. is%ocn%omask_done) then
      call regrid_land_mask(is, importState)
    end if
    ! (So_omask e' estatico no tempo -- uma vez regridada corretamente na
    ! 1a chamada, is%ocn%omask permanece valida sem precisar refazer o
    ! regrid a cada passo.)

    call zero_fluxes_over_land(is, rc)

    call RegridOrCopy(is%ocn_flx%taux,   exportState, "Foxx_taux",      is, rc)
    call RegridOrCopy(is%ocn_flx%tauy,   exportState, "Foxx_tauy",      is, rc)
    call RegridOrCopy(is%ocn_flx%sen,    exportState, "Foxx_sen",       is, rc)
    call RegridOrCopy(is%ocn_flx%evap,   exportState, "Foxx_evap",      is, rc)
    call RegridOrCopy(is%ocn_flx%lwnet,  exportState, "Foxx_lwnet",     is, rc)
    call RegridOrCopy(is%ocn_flx%swvdr,  exportState, "Foxx_swnet_vdr", is, rc)
    call RegridOrCopy(is%ocn_flx%swvdf,  exportState, "Foxx_swnet_vdf", is, rc)
    call RegridOrCopy(is%ocn_flx%swidr,  exportState, "Foxx_swnet_idr", is, rc)
    call RegridOrCopy(is%ocn_flx%swidf,  exportState, "Foxx_swnet_idf", is, rc)
    call RegridOrCopy(is%ocn_flx%rain,   exportState, "Faxa_rain",      is, rc)
    call RegridOrCopy(is%ocn_flx%snow,   exportState, "Faxa_snow",      is, rc)
    call RegridOrCopy(is%ocn_flx%pslv,   exportState, "Sa_pslv",        is, rc)
    ! Si_ifrac e' exportado SEM o RegridOrCopy generico, que faria a perna
    ! ATM->OCN pela rota 'atm2ocn' (NEAREST_STOD, zeroregion=TOTAL, sem
    ! mascara nem extrapolacao) e deixaria zeradas as celulas nao mapeadas
    ! perto da dobra tripolar: manchas isoladas em vez de calota continua,
    ! mesmo com is%ice%ifrac correto. export_ice_fraction usa a rota
    ! conservativa 'atm2ocn_ice' e extrapola por vizinhanca.
    call export_ice_fraction(is, exportState, rc)
    call RegridOrCopy(is%ocn_flx%duu10n, exportState, "So_duu10n",      is, rc)
    ! Mascara terra/oceano REAL do MOM6 no exportState. is%ocn%omask ja'
    ! esta' pronta neste ponto (regridada uma unica vez logo acima). Aqui ela
    ! segue para o conector MED->MPAS, que a leva ate' o cap atmosferico; o diagnostico
    ! mom6_import_*.nc NAO passa por este caminho — le is%ocn%omask
    ! diretamente na grade ATM (med_cap_netcdf.F90), evitando o ida-e-volta
    ! ATM->OCN->Voronoi. O corte binario fica sempre no consumidor final,
    ! nunca no meio do caminho, para nao criar escadinha na linha de costa.
    call RegridOrCopy(is%ocn%omask,  exportState, "Sx_omask",       is, rc)
    call RegridOrCopy(is%sfc%coszen, exportState, "Faxa_coszen",    is, rc)  ! angulo zenital solar -> SIS2
    call RegridOrCopy(is%sfc%albedo, exportState, "Sf_albedo",      is, rc)  ! albedo de banda larga -> MPAS
    ! Fluxos turbulentos e de onda longa sobre o gelo -> SIS2
    call RegridOrCopy(is%ice%taux,   exportState, "Fioi_taux",      is, rc)
    call RegridOrCopy(is%ice%tauy,   exportState, "Fioi_tauy",      is, rc)
    call RegridOrCopy(is%ice%sen,    exportState, "Fioi_sen",       is, rc)
    call RegridOrCopy(is%ice%evap,   exportState, "Fioi_evap",      is, rc)
    call RegridOrCopy(is%ice%lwnet,  exportState, "Fioi_lwnet",     is, rc)
    ! Onda curta liquida sobre o gelo, por banda -> SIS2
    call RegridOrCopy(is%ice%swvdr,  exportState, "Fioi_swnet_vdr", is, rc)
    call RegridOrCopy(is%ice%swvdf,  exportState, "Fioi_swnet_vdf", is, rc)
    call RegridOrCopy(is%ice%swidr,  exportState, "Fioi_swnet_idr", is, rc)
    call RegridOrCopy(is%ice%swidf,  exportState, "Fioi_swnet_idf", is, rc)

    ! Sx_tsfc: temperatura de superficie composta para o MPAS-A,
    ! (1-ifrac)*SST + ifrac*Si_t_sis2, num campo SEPARADO (is%sfc%tsfc).
    ! is%ocn%sst NUNCA e' sobrescrito: "So_t" (abaixo) permanece SST pura,
    ! porque o sis_cap_MONAN.F90 tambem importa "So_t" para o fluxo de calor
    ! da BASE do gelo (ICE_KMELT no SIS2, que precisa da SST REAL do oceano
    ! sob o gelo). Devolver ao SIS2 uma So_t misturada com a propria
    ! temperatura de pele do gelo seria circular: o gradiente T_oceano -
    ! T_congelamento que controla o derretimento/crescimento basal ficaria
    ! artificialmente reduzido em celulas com gelo, suprimindo o derretimento
    ! basal e engrossando o gelo em excesso (efeito observado quando a mistura
    ! era feita na propria So_t). Sx_tsfc so' e' importado pelo MPAS-A
    ! (IMP_NAMES em mpas_cap_MONAN.F90, para atm_bnd%sst).
    call export_surface_temperature(is)

    ! So_t: SST dinâmica MOM6 → exportState para escrita NetCDF e conector MED→MPAS
    ! Diagnóstico: imprimir min/max de is%ocn%sst para confirmar que tem dados reais.
      call ESMF_FieldGet(is%ocn%sst, farrayPtr=sst_diag, rc=rc_sst)
      if (rc_sst == ESMF_SUCCESS .and. associated(sst_diag)) then
        write(*,'(A,F10.3,A,F10.3,A,I0)') &
          '[MED-DIAG] f_sst_atm antes RegridOrCopy: min=', minval(sst_diag), &
          '  max=', maxval(sst_diag), '  size=', size(sst_diag)
        flush(6)
      else
        write(*,'(A,I0)') '[MED-DIAG] f_sst_atm: FieldGet falhou rc=', rc_sst
        flush(6)
      end if
    call RegridOrCopy(is%ocn%sst,    exportState, "So_t",           is, rc)
    if (rc /= ESMF_SUCCESS) then
      write(*,'(A,I0)') '[MED-DIAG] RegridOrCopy So_t FALHOU rc=', rc
      flush(6)
      rc = ESMF_SUCCESS  ! não fatal — para debug
    else
      write(*,'(A)') '[MED-DIAG] RegridOrCopy So_t OK'
      flush(6)
    end if

    ! Sx_tsfc — composto (SST+Si_t_sis2 por
    ! Si_ifrac), exclusivo para o MPAS-A (atm_bnd%sst via IMP_NAMES em
    ! mpas_cap_MONAN.F90). So_t acima permanece SST pura para o SIS2.
    call RegridOrCopy(is%sfc%tsfc,   exportState, "Sx_tsfc",        is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy Sx_tsfc FALHOU — exportState ' // &
        'mantem fallback (ver FillInternalField f_tsfc_atm)', ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

    ! ──────────────────────────────────────────
    ! So_u, So_v: correntes superficiais MOM6 -> exportState para conector
    ! MED -> MPAS. Os campos is%ocn%u/is%ocn%v já contêm os valores
    ! regridados OCN -> ATM (preenchidos no bloco acima a partir
    ! do importState.So_u/So_v). RegridOrCopy faz ATM -> OCN para o exportState;
    ! depois o conector MED -> MPAS fará OCN -> ATM. Mesmo round-trip que So_t —
    ! mantém consistência arquitetural até a refatoração para grade unificada.
    !
    ! Sobre regiões continentais e PETs sem dados: ZeroInternalField em
    ! InitializeRealize e os clamps em RegridOrCopy garantem zeros físicos.
    ! O cap MPAS (mpas_import) também clampa |V_ocn| <= 5 m/s defensivamente.
    call RegridOrCopy(is%ocn%u, exportState, "So_u", is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy So_u FALHOU — exportState mantem zeros', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

    call RegridOrCopy(is%ocn%v, exportState, "So_v", is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy So_v FALHOU — exportState mantem zeros', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

    ! ──────────────────────────────────────────
    ! Sf_zorl: rugosidade superficial Charnock+Smith calculada no bulk NCAR
    ! a partir de Foxx_taux/tauy. Mesmo padrão arquitetural de So_t/So_u/So_v:
    ! is%sfc%zorl (grade ATM interna) -> RegridOrCopy -> exportState.Sf_zorl
    ! (grade OCN) -> conector MED -> MPAS faz o regrid final para Voronoi.
    ! O cap MPAS atualiza atm_bnd%zorl com este valor a cada passo
    ! em vez de manter o default fixo de 0.01 m.
    call RegridOrCopy(is%sfc%zorl, exportState, "Sf_zorl", is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy Sf_zorl FALHOU — exportState mantem default 0.01 m', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

  end subroutine export_to_components

  subroutine export_surface_temperature(is)
    type(MED_InternalState), pointer :: is
    real(ESMF_KIND_R8), pointer :: p_sst_src(:,:), p_tice_comp(:,:), p_ifrac_comp(:,:)
    real(ESMF_KIND_R8), pointer :: p_tsfc_out(:,:)
    integer :: rc_tsfc
    real(ESMF_KIND_R8) :: ifrac_c
    integer :: ii_c, jj_c
    character(len=220) :: diag_msg_tsfc

    call ESMF_FieldGet(is%ocn%sst,   farrayPtr=p_sst_src,   rc=rc_tsfc)
    call ESMF_FieldGet(is%ice%tice,  farrayPtr=p_tice_comp, rc=rc_tsfc)
    call ESMF_FieldGet(is%ice%ifrac, farrayPtr=p_ifrac_comp,rc=rc_tsfc)
    call ESMF_FieldGet(is%sfc%tsfc,  farrayPtr=p_tsfc_out,  rc=rc_tsfc)
    if (associated(p_sst_src) .and. associated(p_tice_comp) .and. &
        associated(p_ifrac_comp) .and. associated(p_tsfc_out)) then
      do jj_c = lbound(p_sst_src,2), ubound(p_sst_src,2)
        do ii_c = lbound(p_sst_src,1), ubound(p_sst_src,1)
          ! Clamp defensivo local — nao confia cegamente nas extrapolacoes
          ! upstream, mesma filosofia dos guards de NaN/faixa fisica
          ! usados no resto do arquivo (ex. clamp de Sf_albedo, So_t).
          ifrac_c = p_ifrac_comp(ii_c,jj_c)
          if (ifrac_c /= ifrac_c) ifrac_c = 0.0_ESMF_KIND_R8   ! NaN guard
          ifrac_c = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifrac_c))
          if (p_tice_comp(ii_c,jj_c) == p_tice_comp(ii_c,jj_c) .and. &
              p_tice_comp(ii_c,jj_c) > 180.0_ESMF_KIND_R8 .and. &
              p_tice_comp(ii_c,jj_c) < 280.0_ESMF_KIND_R8) then
            p_tsfc_out(ii_c,jj_c) = (1.0_ESMF_KIND_R8 - ifrac_c) * p_sst_src(ii_c,jj_c) &
                                     + ifrac_c * p_tice_comp(ii_c,jj_c)
          else
            ! Si_t_sis2 nao regridou/extrapolou para um valor fisico
            ! nesta celula — mantem SST pura em vez de contaminar com
            ! um valor suspeito, mesma logica defensiva do fallback de
            ! Sf_albedo.
            p_tsfc_out(ii_c,jj_c) = p_sst_src(ii_c,jj_c)
          end if
        end do
      end do
      if (cfg_write_fixdiag) then
          write(diag_msg_tsfc,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
            'FIX-DIAG-TSFCCOMP-01: Sx_tsfc(composto) min=', minval(p_tsfc_out), &
            ' max=', maxval(p_tsfc_out), ' | So_t(pura, INTOCADA) min=', &
            minval(p_sst_src), ' max=', maxval(p_sst_src)
          call ESMF_LogWrite(trim(diag_msg_tsfc), ESMF_LOGMSG_INFO)
      end if
    else
      ! Sem dado para compor — Sx_tsfc degrada para SST pura.
      if (associated(p_sst_src) .and. associated(p_tsfc_out)) &
        p_tsfc_out(:,:) = p_sst_src(:,:)
      call ESMF_LogWrite('MED(B-TSFC-DUALEXPORT-01): AVISO — ponteiros ' // &
        'de So_t/Si_t_sis2/Si_ifrac indisponiveis, Sx_tsfc degradado ' // &
        'para SST pura', ESMF_LOGMSG_WARNING)
    end if
  end subroutine export_surface_temperature

  subroutine export_ice_fraction(is, exportState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: exportState
    integer, intent(inout) :: rc
    type(ESMF_Field) :: f_ifrac_exp
    integer :: rc_ifrac2
    real(ESMF_KIND_R8), pointer :: p_ifrac_exp(:,:)
    integer :: rc_store2
    character(len=200) :: diag_msg_ifrac2

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_ifrac_exp, rc=rc_ifrac2)
    if (rc_ifrac2 == ESMF_SUCCESS) then
      call FillInternalField(f_ifrac_exp, -999.0_ESMF_KIND_R8, rc_ifrac2)

      ! Rota conservativa 'atm2ocn_ice', como a 'ocn2atm_ice' na ida, com
      ! 'atm2ocn' como reserva.
      if (.not. is%regrid%has('atm2ocn_ice') .and. is%regrid%has('atm2ocn')) &
        call is%regrid%add('atm2ocn_ice', regrid_spec('conserve,nearest_stod'), &
          is%ice%ifrac, f_ifrac_exp, rc_store2, fallback='atm2ocn')

      if (is%regrid%has('atm2ocn_ice')) then
        call is%regrid%apply('atm2ocn_ice', is%ice%ifrac, f_ifrac_exp, rc_ifrac2, &
          zero_total=.false.)
      else
        call is%regrid%apply('atm2ocn', is%ice%ifrac, f_ifrac_exp, rc_ifrac2, &
          zero_total=.true.)
      end if
      call ESMF_FieldGet(f_ifrac_exp, farrayPtr=p_ifrac_exp, rc=rc_ifrac2)
      if (associated(p_ifrac_exp)) &
        call neighbor_fill(p_ifrac_exp, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.0_ESMF_KIND_R8))
      if (cfg_write_fixdiag .and. associated(p_ifrac_exp)) then
          write(diag_msg_ifrac2,'(A,ES10.3,A,ES10.3)') &
            'FIX-DIAG-ICEREGRID04-01: Si_ifrac(exportState, pos ATM->OCN+' // &
            'extrapolacao) min=', minval(p_ifrac_exp), ' max=', maxval(p_ifrac_exp)
          call ESMF_LogWrite(trim(diag_msg_ifrac2), ESMF_LOGMSG_INFO)
      end if
    else
      ! Fallback: exportState sem Si_ifrac realizado (nao deveria
      ! acontecer) -- mantem o comportamento antigo em vez de travar.
      call RegridOrCopy(is%ice%ifrac, exportState, "Si_ifrac", is, rc)
    end if
  end subroutine export_ice_fraction

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
      ! Mascara REAL (So_omask regridada), e nao
      ! inferida por SST. p_omask < 0.5 = terra (limiar central entre
      ! 0=terra e 1=oceano; robusto a pequena mistura de borda do
      ! regrid NEAREST_STOD, que deveria ser quase sempre exatamente
      ! 0 ou 1 de qualquer forma).
      allocate(land_mask(lbound(p_omask,1):ubound(p_omask,1), &
                         lbound(p_omask,2):ubound(p_omask,2)))
      land_mask = (p_omask < 0.5_ESMF_KIND_R8)
      n_land_masked = count(land_mask)

      ! Helper macro: aplicar mascara em cada fluxo
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

      ! Log diagnostico
        write(logmsg, '(A,I0,A)') &
          'MED Sprint A.5.1: fluxos zerados em ', n_land_masked, &
          ' celulas de terra (mascara real So_omask, ver B-LANDMASK-01)'
        call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)

      deallocate(land_mask)
    end if
  end subroutine zero_fluxes_over_land

  subroutine regrid_land_mask(is, importState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field) :: omask_src_field
    integer :: rc_lm

    call ESMF_StateGet(importState, itemName="So_omask", &
      field=omask_src_field, rc=rc_lm)
    if (rc_lm == ESMF_SUCCESS) then
      call is%regrid%add('ocn2atm_landmask', regrid_spec('nearest_stod'), &
        omask_src_field, is%ocn%omask, rc_lm)
      if (rc_lm == ESMF_SUCCESS) then
        call is%regrid%apply('ocn2atm_landmask', omask_src_field, is%ocn%omask, rc_lm, &
          zero_total=.false.)
        call ESMF_LogWrite('MED: mascara terra/oceano real regridada para a grade ATM', &
          ESMF_LOGMSG_INFO)
      else
        ! is%ocn%omask continua 1.0 (tudo oceano)
        call ESMF_LogWrite('MED: falha no regrid da mascara So_omask; ' // &
          'mantido tudo-oceano (1.0)', ESMF_LOGMSG_WARNING)
      end if
    else
      call ESMF_LogWrite('MED B-LANDMASK-01: So_omask indisponivel -- ' // &
        'mantendo fallback tudo-oceano (1.0)', ESMF_LOGMSG_WARNING)
    end if
    is%ocn%omask_done = .true.
  end subroutine regrid_land_mask

  subroutine stamp_export_fields(exportState, field, stampTime, rc)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: field
    type(ESMF_Time), intent(inout) :: stampTime
    integer, intent(inout) :: rc
    integer :: fieldCount
    character(len=64), allocatable :: fieldNameList(:)
    integer :: k
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fieldNameList(k)), &
        field=field, rc=rc)
      call NUOPC_SetTimestamp(field, stampTime, rc=rc)
    end do
    deallocate(fieldNameList)
  end subroutine stamp_export_fields

end module med_export_mod
