!> @file med_bulk_ncar.F90
!! @brief Física bulk NCAR do mediador: cálculo de fluxos superficiais e rugosidade.
!!
!! Versão 1.0 (Mai/2026) — GT Acoplamento MONAN / INPE/CGCT/DIMNT
!!
!! Contém a seção 4 + Charnock extraída de MediatorAdvance (Passo 4):
!!
!!   calc_bulk_ncar   — calcula os 14 fluxos bulk + duu10n + ifrac + Charnock
!!
!! Formulações:
!!   Large & Yeager (2009) — taux, tauy, fluxo sensível, evaporação, LW, SW
!!   Smith (1988)           — rugosidade Charnock + viscosa (Sprint C Maio 2026)
!!
!! A sub-rotina recebe os campos ATM globais reunidos por MPI_Allreduce e
!! escreve os resultados diretamente nos campos ESMF do estado interno (is).

module med_bulk_ncar_mod

  use ESMF

  use mpas_cap_config_mod, only: cfg_use_docn_ice,        &
                                cfg_docn_ice_init_only   ! Sprint B.1
  use med_cap_types_mod, only: MED_InternalState,    &
                                rho_air,              &
                                Cd_neut,              &
                                Ch_neut,              &
                                Ce_neut,              &
                                Cp_air,               &
                                L_evap,               &
                                T_freeze,             &
                                eps_q,                &
                                es_coef_a,            &
                                es_coef_b,            &
                                es_coef_c,            &
                                sigma_sb,             &
                                albedo_ocn,           &
                                SST_BULK_FALLBACK,    &
                                f_vis_dir, f_vis_dif, &
                                f_nir_dir, f_nir_dif

  implicit none
  private

  public :: calc_bulk_ncar

contains

  !============================================================================
  !> @brief Calcula fluxos superficiais bulk NCAR + rugosidade Charnock/Smith.
  !!
  !! Executa as seções 4 (bulk NCAR) e Charnock do MediatorAdvance.
  !! Os resultados são escritos diretamente nos campos ESMF de `is`.
  !!
  !! Inputs atmosféricos (grade ATM global 360×180, após MPI_Allreduce):
  !!   uas, vas  — vento zonal/meridional a 10 m  [m/s]
  !!   tas       — temperatura do ar a 2 m        [K]
  !!   psl       — pressão ao nível do mar        [Pa]
  !!   swdn      — onda curta incidente            [W/m²]
  !!   lwdn      — onda longa incidente            [W/m²]
  !!   rain      — precipitação líquida            [kg/m²/s]
  !!   shum      — umidade específica              [kg/kg]
  !!   snow_g    — precipitação sólida (opcional) [kg/m²/s]
  !!
  !! Saídas escritas nos campos internos de `is`:
  !!   f_taux_atm, f_tauy_atm  — tensão de cisalhamento  [Pa]
  !!   f_sen_atm               — calor sensível          [W/m²]
  !!   f_evap_atm              — evaporação              [kg/m²/s]
  !!   f_lwnet_atm             — balanço LW              [W/m²]
  !!   f_swvdr_atm .. f_swidf_atm — componentes SW       [W/m²]
  !!   f_rain_atm, f_snow_atm, f_pslv_atm — pass-through
  !!   f_duu10n_atm            — |V_atm − V_ocn|²        [m²/s²]
  !!   f_zorl_atm              — rugosidade Charnock+Smith [m]
  !!   f_ifrac_atm             — fração de gelo (regrid SIS2 ou fallback SST)
  !!
  !! @param[inout] is          Estado interno do mediador
  !! @param[inout] importState State de import (Si_ifrac do SIS2 para regrid)
  !! @param[in]   uas, vas    Vento zonal/meridional [m/s]
  !! @param[in]   tas         Temperatura do ar [K]
  !! @param[in]   psl         Pressão ao nível do mar [Pa]
  !! @param[in]   swdn        Radiação onda curta incidente [W/m²]
  !! @param[in]   lwdn        Radiação onda longa incidente [W/m²]
  !! @param[in]   rain        Precipitação líquida [kg/m²/s]
  !! @param[in]   shum        Umidade específica [kg/kg]
  !! @param[in]   snow_g      Precipitação sólida (alocável, pode ser vazia) [kg/m²/s]
  !! @param[in]   i1,i2,j1,j2 Limites locais da DE na grade ATM
  !! @param[out]  rc          Código de retorno ESMF
  !============================================================================
  subroutine calc_bulk_ncar(is, importState, &
                             uas, vas, tas, psl, swdn, lwdn, rain, shum, snow_g, &
                             i1, i2, j1, j2, rc)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    real(ESMF_KIND_R8),      intent(in)    :: uas(:,:), vas(:,:), tas(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: rain(:,:), shum(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: snow_g(:,:)
    integer,                 intent(in)    :: i1, i2, j1, j2
    integer,                 intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    real(ESMF_KIND_R8), pointer :: uocn(:,:), vocn(:,:)
    real(ESMF_KIND_R8) :: wspd, qsat, sst_eff
    integer :: i, j

    rc = ESMF_SUCCESS
    nullify(fptr, sst, uocn, vocn)

    ! Obter SST da grade ATM interna (preenchida na seção 3 por regrid OCN→ATM)
    call ESMF_FieldGet(is%f_sst_atm, farrayPtr=sst, rc=rc)
    if (rc /= ESMF_SUCCESS) nullify(sst)

    ! Obter correntes oceânicas na grade ATM (preenchidas na seção 3 ou zeros)
    call ESMF_FieldGet(is%f_uocn_atm, farrayPtr=uocn, rc=rc)
    if (rc /= ESMF_SUCCESS) nullify(uocn)
    call ESMF_FieldGet(is%f_vocn_atm, farrayPtr=vocn, rc=rc)
    if (rc /= ESMF_SUCCESS) nullify(vocn)
    rc = ESMF_SUCCESS

    !==========================================================================
    ! Taux = rho * Cd * |V| * u10
    !==========================================================================
    call ESMF_FieldGet(is%f_taux_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      ! BUG-CALC-05: clamp ±5 Pa (limite físico cat-5 ~3 Pa)
      fptr(i,j) = max(-5.0_ESMF_KIND_R8, min(5.0_ESMF_KIND_R8, &
        rho_air * Cd_neut * wspd * uas(i,j)))
    end do; end do

    !==========================================================================
    ! Tauy = rho * Cd * |V| * v10
    !==========================================================================
    call ESMF_FieldGet(is%f_tauy_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      fptr(i,j) = max(-5.0_ESMF_KIND_R8, min(5.0_ESMF_KIND_R8, &
        rho_air * Cd_neut * wspd * vas(i,j)))
    end do; end do

    !==========================================================================
    ! Calor sensível = rho * Cp * Ch * |V| * (Tair - SST)
    !==========================================================================
    call ESMF_FieldGet(is%f_sen_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      ! BUG-CALC-04: pular células sem tas físico (tas < 100 K = sem dado)
      if (tas(i,j) < 100.0_ESMF_KIND_R8) cycle
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      sst_eff = merge(sst(i,j), SST_BULK_FALLBACK, &
        associated(sst) .and. sst(i,j) > 271.0_ESMF_KIND_R8 .and. sst(i,j) < 308.0_ESMF_KIND_R8)
      ! BUG-CALC-05: clamp ±500 W/m²
      fptr(i,j) = max(-500.0_ESMF_KIND_R8, min(500.0_ESMF_KIND_R8, &
        rho_air * Cp_air * Ch_neut * wspd * (tas(i,j) - sst_eff)))
    end do; end do

    !==========================================================================
    ! Evaporação = rho * Ce * |V| * (qsat(SST) − qair)
    !==========================================================================
    call ESMF_FieldGet(is%f_evap_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      if (tas(i,j) < 100.0_ESMF_KIND_R8) cycle
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      sst_eff = merge(sst(i,j), SST_BULK_FALLBACK, &
        associated(sst) .and. sst(i,j) > 271.0_ESMF_KIND_R8 .and. sst(i,j) < 308.0_ESMF_KIND_R8)
      qsat = eps_q * es_coef_a * &
        exp(es_coef_b*(sst_eff-T_freeze)/(sst_eff-T_freeze+es_coef_c)) / &
        max(psl(i,j), 1.0_ESMF_KIND_R8)
      ! Convenção CMEPS: E > 0 = oceano → atmosfera  (BUG-FORT-EVAP fix)
      ! BUG-CALC-05: clamp ±1e-4 kg/m²/s (~±8.6 mm/d)
      fptr(i,j) = max(-1.0e-4_ESMF_KIND_R8, min(1.0e-4_ESMF_KIND_R8, &
        rho_air * Ce_neut * wspd * (qsat - shum(i,j))))
    end do; end do

    !==========================================================================
    ! Balanço LW = lwdn − emissividade·σ·SST⁴
    !==========================================================================
    call ESMF_FieldGet(is%f_lwnet_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      ! BUG-CALC-03: pular células sem lwdn real (lwdn=0 indica ausência)
      if (lwdn(i,j) < 1.0_ESMF_KIND_R8) cycle
      sst_eff = merge(sst(i,j), SST_BULK_FALLBACK, &
        associated(sst) .and. sst(i,j) > 271.0_ESMF_KIND_R8 .and. sst(i,j) < 308.0_ESMF_KIND_R8)
      fptr(i,j) = max( &
        max(lwdn(i,j), 0.0_ESMF_KIND_R8) - 0.97_ESMF_KIND_R8 * sigma_sb * sst_eff**4, &
        -300.0_ESMF_KIND_R8)
    end do; end do

    !==========================================================================
    ! Componentes SW: 4 bandas (vis-dir, vis-dif, nir-dir, nir-dif)
    !==========================================================================
    call ESMF_FieldGet(is%f_swvdr_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_vis_dir
    end do; end do

    call ESMF_FieldGet(is%f_swvdf_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_vis_dif
    end do; end do

    call ESMF_FieldGet(is%f_swidr_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_nir_dir
    end do; end do

    call ESMF_FieldGet(is%f_swidf_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_nir_dif
    end do; end do

    !==========================================================================
    ! Rain, snow, pslv — cópia direta (pass-through para o OCN)
    !==========================================================================
    call ESMF_FieldGet(is%f_rain_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(rain(i,j), 0.0_ESMF_KIND_R8)  ! clamp ≥ 0 (artefato bilinear)
    end do; end do

    call ESMF_FieldGet(is%f_snow_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(snow_g(i,j), 0.0_ESMF_KIND_R8)
    end do; end do

    call ESMF_FieldGet(is%f_pslv_atm, farrayPtr=fptr, rc=rc)
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = psl(i,j)
    end do; end do

    !==========================================================================
    ! Sprint C (Maio 2026): rugosidade superficial via Charnock + Smith (1988)
    !
    ! z0 = alpha * u*² / g  +  beta * nu / u*
    !       (Charnock)              (Smith — termo viscoso)
    !
    ! alpha = 0.018   (constante de Charnock)
    ! beta  = 0.11    (Smith 1988)
    ! g     = 9.81 m/s²
    ! nu    = 1.5e-5 m²/s  (viscosidade cinemática do ar a 20 °C)
    ! u*    = sqrt( |tau| / rho_ar )
    !==========================================================================
    block
      real(ESMF_KIND_R8), parameter :: ALPHA_CHARNOCK = 0.018_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: BETA_SMITH     = 0.11_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: G_GRAV         = 9.81_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: NU_AIR         = 1.5e-5_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: USTAR_MIN      = 1.0e-4_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: Z0_MIN         = 1.0e-5_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: Z0_MAX         = 0.1_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: Z0_DEFAULT     = 0.01_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: T_FILL_LAND    = 271.35_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: TOL_LAND       = 1.0e-6_ESMF_KIND_R8

      real(ESMF_KIND_R8), pointer :: p_taux(:,:) => null()
      real(ESMF_KIND_R8), pointer :: p_tauy(:,:) => null()
      real(ESMF_KIND_R8), pointer :: p_zorl(:,:) => null()
      real(ESMF_KIND_R8) :: tau_mag, ustar, z0_charnock, z0_smith, z0_total
      integer :: rc_z

      call ESMF_FieldGet(is%f_taux_atm, farrayPtr=p_taux, rc=rc_z)
      call ESMF_FieldGet(is%f_tauy_atm, farrayPtr=p_tauy, rc=rc_z)
      call ESMF_FieldGet(is%f_zorl_atm, farrayPtr=p_zorl, rc=rc_z)

      if (associated(p_taux) .and. associated(p_tauy) .and. associated(p_zorl)) then
        do j = j1, j2
          do i = i1, i2
            tau_mag     = sqrt(p_taux(i,j)**2 + p_tauy(i,j)**2)
            ustar       = sqrt(tau_mag / rho_air)
            ustar       = max(ustar, USTAR_MIN)
            z0_charnock = ALPHA_CHARNOCK * ustar**2 / G_GRAV
            z0_smith    = BETA_SMITH * NU_AIR / ustar
            z0_total    = max(Z0_MIN, min(Z0_MAX, z0_charnock + z0_smith))
            ! Sobre terra (marcador Sprint A.5): usar default
            if (associated(sst)) then
              if (abs(sst(i,j) - T_FILL_LAND) < TOL_LAND) z0_total = Z0_DEFAULT
            end if
            p_zorl(i,j) = z0_total
          end do
        end do
        call ESMF_LogWrite( &
          'MED Sprint C: Sf_zorl calculado via Charnock + Smith', &
          ESMF_LOGMSG_INFO)
      end if
    end block

    !==========================================================================
    ! duu10n = |V_atm − V_ocn|²  (protocolo CMEPS — BUG-CALC-DUU fix v13.0)
    !==========================================================================
    call ESMF_FieldGet(is%f_duu10n_atm, farrayPtr=fptr, rc=rc)
    if (associated(uocn) .and. associated(vocn)) then
      do j=j1,j2; do i=i1,i2
        fptr(i,j) = (uas(i,j) - uocn(i,j))**2 + (vas(i,j) - vocn(i,j))**2
      end do; end do
    else
      ! Fallback: sem correntes disponíveis, usa vento absoluto²
      call ESMF_LogWrite( &
        'MED: AVISO BUG-CALC-DUU: uocn/vocn nulos — So_duu10n calculado com vento absoluto', &
        ESMF_LOGMSG_WARNING)
      do j=j1,j2; do i=i1,i2
        fptr(i,j) = uas(i,j)**2 + vas(i,j)**2
      end do; end do
    end if

    !==========================================================================
    ! Si_ifrac: regrid OCN→ATM via rh_ocn2atm (SIS2) + mascara terra (A.5.2)
    ! Fallback: limiar de SST quando routehandle não disponível
    !==========================================================================
    block
      type(ESMF_Field) :: f_ifrac_src
      integer          :: rc_if
      logical          :: regrid_ok

      ! Fonte de Si_ifrac por modo (nuopc.input &nuopc_mode):
      !   use_docn_ice=T  init_only=F  → is%f_ifrac_atm já preenchida
      !     com OISST por fill_ifrac_from_oisst (Alternativa 1 original).
      !     regrid_ok=T pula o ESMF_FieldRegrid (rh_ocn2atm falha para
      !     Si_ifrac ≠ So_t) e o fallback SST.
      !   use_docn_ice=T  init_only=T  → Sprint B.1:
      !     fill_ifrac_from_oisst NÃO foi chamado em MediatorAdvance.
      !     Usar Si_ifrac do OCN (sigmoid) via importState.
      !   use_docn_ice=F              → sigmoid do OCN via importState.
      ! regrid_ok=T: usar is%f_ifrac_atm (de fill_ifrac_from_oisst).
      ! NÃO reutilizar rh_ocn2atm para Si_ifrac (específico de So_t).
      ! Sprint B.2 criará rh dedicado para Si_ifrac dinâmico.
      if (cfg_use_docn_ice) then
        regrid_ok = .true.   ! is%f_ifrac_atm de fill_ifrac_from_oisst
      else
        regrid_ok = .false.  ! OCN sigmoid via importState (Sprint B.2+)
      end if

      if (.not. regrid_ok .and. is%rh_created) then
        call ESMF_StateGet(importState, itemName="Si_ifrac", &
                           field=f_ifrac_src, rc=rc_if)
        if (rc_if == ESMF_SUCCESS) then
          call ESMF_FieldRegrid(f_ifrac_src, is%f_ifrac_atm, &
            is%rh_ocn2atm, zeroregion=ESMF_REGION_TOTAL, rc=rc_if)
          if (rc_if == ESMF_SUCCESS) then
            regrid_ok = .true.
            call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=fptr, rc=rc_if)
            if (rc_if == ESMF_SUCCESS .and. associated(fptr)) then
              where (fptr < 0.0_ESMF_KIND_R8) fptr = 0.0_ESMF_KIND_R8
              where (fptr > 1.0_ESMF_KIND_R8) fptr = 1.0_ESMF_KIND_R8
              where (fptr /= fptr)            fptr = 0.0_ESMF_KIND_R8  ! NaN
              ! Sprint A.5.2: defesa em profundidade — zera ifrac onde sst = T_FILL_LAND
              block
                real(ESMF_KIND_R8), parameter :: T_FILL_LAND = 271.35_ESMF_KIND_R8
                real(ESMF_KIND_R8), parameter :: TOL_LAND    = 1.0e-6_ESMF_KIND_R8
                integer :: n_ifrac_land
                if (associated(sst)) then
                  n_ifrac_land = count(abs(sst - T_FILL_LAND) < TOL_LAND &
                                       .and. fptr > 0.0_ESMF_KIND_R8)
                  where (abs(sst - T_FILL_LAND) < TOL_LAND) fptr = 0.0_ESMF_KIND_R8
                  if (n_ifrac_land > 0) then
                    block
                      character(len=160) :: logmsg
                      write(logmsg,'(A,I0,A)') &
                        'MED Sprint A.5.2: Si_ifrac zerado em ', &
                        n_ifrac_land, ' celulas terra (mascara T_FILL_LAND)'
                      call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)
                    end block
                  end if
                end if
              end block
            end if
            call ESMF_LogWrite( &
              'MED: Si_ifrac regridado do SIS2 + mascara terra (A.5.2)', &
              ESMF_LOGMSG_INFO)
          end if
        end if
      end if

      ! Fallback: limiar de SST (Sprint A.5.2 — condicao mais restritiva)
      if (.not. regrid_ok) then
        call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=fptr, rc=rc_if)
        if (rc_if == ESMF_SUCCESS .and. associated(fptr) .and. associated(sst)) then
          ! Construto block (Fortran 2008): escopo local para sst_eff_if.
          ! Declarações são inválidas dentro de do-loops em Fortran.
          block
            real(ESMF_KIND_R8) :: sst_eff_if  ! SST efetiva após clamp [271, 308] K
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
          end block
          call ESMF_LogWrite( &
            'MED: Si_ifrac calculado via limiar SST (fallback — Sprint A.5.2)', &
            ESMF_LOGMSG_INFO)
        end if
      end if
    end block

    rc = ESMF_SUCCESS

  end subroutine calc_bulk_ncar

end module med_bulk_ncar_mod
