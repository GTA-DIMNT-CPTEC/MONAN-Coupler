!> @file med_bulk_ncar.F90
!! @brief Física bulk NCAR do mediador: cálculo de fluxos superficiais e rugosidade.
!!
!! calc_bulk_ncar calcula os 14 fluxos bulk, duu10n, os fluxos sobre o gelo,
!! o albedo de banda larga e a rugosidade de Charnock, na grade ATM do
!! mediador.
!!
!! Formulações:
!!   Large & Yeager (2009) — taux, tauy, fluxo sensível, evaporação, LW, SW
!!   Smith (1988) — rugosidade Charnock + viscosa
!!
!! A sub-rotina recebe os campos ATM globais reunidos por MPI_Allreduce e lê e
!! escreve só arrays (med_flux_t), associados pela fase compute_fluxes de
!! med_exchange: a física não conhece o estado interno do mediador, os
!! campos do ESMF nem as rotas.

module med_bulk_ncar_mod

  use ESMF
  use coupler_constants_mod, only : GRAV, T_FREEZE_SEAWATER, ATM_NX, ATM_NY, &
                                    T_ICE_MIN, T_ICE_MAX

  use coupler_config_mod, only: cfg_docn_ice_init_only      ! 1
  use coupler_log_mod, only: COMP_MED, log_warning, log_debug, log_debug_enabled
  use med_diag_mod, only: log_ice_stability
  use med_cap_types_mod, only: med_flux_t,           &
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
  ! Fórmulas puras, públicas para os testes com valor esperado (tests/unit).
  public :: ice_temp_eff, louis_stability, ocean_direct_albedo

  ! Parâmetros dos fluxos sobre o gelo (compute_ice_fluxes).
  real(ESMF_KIND_R8), parameter :: Z_REF = 10.0_ESMF_KIND_R8      ! altura de referência [m]
  real(ESMF_KIND_R8), parameter :: LOUIS_B = 5.0_ESMF_KIND_R8     ! Louis (1979), caso estável
  real(ESMF_KIND_R8), parameter :: LOUIS_C = 5.0_ESMF_KIND_R8     ! Louis (1979), caso instável
  real(ESMF_KIND_R8), parameter :: STAB_FAC_MIN = 0.05_ESMF_KIND_R8  ! piso p/ não zerar o fluxo
  real(ESMF_KIND_R8), parameter :: STAB_FAC_MAX = 3.0_ESMF_KIND_R8   ! teto de segurança (não é do Louis original)
  ! Abaixo desta fração de gelo, Si_t_sis2 é o valor padrão do cap do gelo
  ! (ponto de congelamento), e não uma temperatura real: os Fioi_* recebem
  ! os fluxos da água aberta (Foxx_*).
  real(ESMF_KIND_R8), parameter :: IFRAC_MIN_FIOI = 1.0e-3_ESMF_KIND_R8

contains

  !> @brief Calcula fluxos superficiais bulk NCAR + rugosidade Charnock/Smith.
  !!
  !! Executa as seções 4 (bulk NCAR) e Charnock do MediatorAdvance.
  !! Os resultados são escritos nos arrays de `fluxo` (med_flux_t).
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
  !! Saídas escritas nos arrays de `fluxo`:
  !!   fluxo%taux, fluxo%tauy: tensão de cisalhamento [Pa]
  !!   fluxo%sen: calor sensível [W/m²]
  !!   fluxo%evap: evaporação [kg/m²/s]
  !!   fluxo%lwnet: balanço LW [W/m²]
  !!   fluxo%swvdr a fluxo%swidf: componentes SW [W/m²]
  !!   fluxo%rain, fluxo%snow, fluxo%pslv: repassados
  !!   fluxo%duu10n: |V_atm − V_ocn|² [m²/s²]
  !!   fluxo%*_ice: os mesmos fluxos sobre o gelo (Fioi_*)
  !!   fluxo%zorl: rugosidade Charnock+Smith [m]
  !!   fluxo%coszen, fluxo%albedo: cosseno zenital e albedo de banda larga
  !!   (fluxo%ifrac é lida, não escrita: sem o SIS2, a fase
  !!   ice_fraction_without_sis2, de med_exchange, a recalcula logo depois)
  !!
  !! @param[in]   fluxo       Arrays da física (med_flux_t); os valores
  !!                          apontados são lidos e escritos
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
  subroutine calc_bulk_ncar(fluxes, &
                             uas, vas, tas, psl, swdn, lwdn, rain, shum, snow_g, &
                             i1, i2, j1, j2, clock, rc)
    type(med_flux_t),        intent(in)    :: fluxes
    real(ESMF_KIND_R8),      intent(in)    :: uas(:,:), vas(:,:), tas(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: rain(:,:), shum(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: snow_g(:,:)
    integer,                 intent(in)    :: i1, i2, j1, j2
    type(ESMF_Clock),        intent(in)    :: clock
    integer,                 intent(out)   :: rc

    ! Declinação solar e hora UTC, calculadas uma vez por chamada (não
    ! dependem de i,j) e reaproveitadas por todas as células.
    real(ESMF_KIND_R8) :: decl
    real(ESMF_KIND_R8) :: utc_hour

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    real(ESMF_KIND_R8), pointer :: uocn(:,:), vocn(:,:)
    integer :: i, j

    rc = ESMF_SUCCESS
    nullify(fptr, sst, uocn, vocn)

    ! Hora UTC e declinação solar do instante de acoplamento
    call solar_time_and_declination(clock, utc_hour, decl, rc)

    ! SST na malha de fluxo (fase go_to_flux_grid, rota OCN→ATM)
    sst => fluxes%sst

    ! Correntes oceânicas na malha de fluxo (fase go_to_flux_grid, ou zeros)
    uocn => fluxes%uocn
    vocn => fluxes%vocn
    rc = ESMF_SUCCESS

    ! Tensão, calor sensível, evaporação e balanco LW sobre água aberta
    call compute_ocean_fluxes(fluxes, sst, uas, vas, tas, psl, lwdn, shum, &
                              i1, i2, j1, j2)

    ! Componentes SW: 4 bandas (vis-dir, vis-dif, nir-dir, nir-dif)
    !
    ! O albedo efetivo de cada célula é
    ! uma média ponderada pela fração de gelo real (fluxo%ifrac,
    ! interpolada de Si_ifrac_sis2) entre a constante de água aberta
    ! (albedo_ocn = 0,06) e o albedo real do gelo por banda vindo do SIS2
    ! (fluxo%alb_*, interpolado de Si_a*sdr/f_sis2 — ver export_si_albedo
    ! em sis_cap_fields.F90). Com albedo_ocn = 0,06 em toda célula, a absorção
    ! de SW sob gelo/neve (albedo real tipicamente 0,5-0,85) seria fortemente
    ! superestimada.
    call blend_albedo_with_ice(fluxes, j1, j2, i1, i2, utc_hour, decl, swdn, rc)

    ! Fluxos Fioi_*: mesma forma bulk NCAR de acima, mas com a temperatura
    ! de pele REAL do gelo (fluxo%tice, interpolada de Si_t_sis2) em vez
    ! da SST. Enviar ao SIS2 os mesmos Foxx_* calculados com a SST seria
    ! fisicamente incorreto: a diferença de temperatura ar-superficie sobre
    ! gelo frio pode ser MUITO maior que ar-SST (a SST fica travada perto do
    ! ponto de congelamento; T_gelo pode chegar a -40 C ou mais frio).
    !
    ! Coeficientes de transferência: reusa Cd_neut/Ch_neut/Ce_neut (mesmos
    ! da água aberta) como base, MODULADOS por um fator de estabilidade
    ! (Louis, 1979 — "A parametric model of vertical eddy fluxes in the
    ! atmosphere", Boundary-Layer Meteorology 17, constantes b=c=d=5) —
    ! necessário porque o ar sobre gelo frio tipicamente forma uma camada
    ! ESTAVELMENTE estratificada (T_ar > T_gelo), onde a troca turbulenta
    ! REAL é bem menor que a que os coeficientes "neutros" (calibrados
    ! para água aberta, tipicamente próxima do neutro) preveem. Sem o fator,
    ! Fioi_sen satura repetidamente no teto de segurança de ±500 W/m^2,
    ! sinal de superestimativa sistemática, não de evento físico isolado.
    !
    ! Ambos os ramos de Louis (1979) estão implementados: Rib>0 (estável,
    ! amortece) e Rib<0 (INSTÁVEL — superfície mais quente que o ar, ex.
    ! polínias/gelo fino sob ar frio — REFORÇA a troca turbulenta em vez de
    ! amortecer). STAB_FAC_MAX=3,0 é um teto de segurança numérico
    ! (não vem do artigo original) para evitar crescimento sem limite do
    ! fator de reforço em Rib muito negativo.
    !
    ! Refinamento futuro adicional: coeficientes próprios de rugosidade de
    ! gelo (ex. Andreas et al.), ainda não implementado.
    !
    ! Emissividade do gelo/neve (0,99) é ligeiramente maior que a de água
    ! aberta (0,97) usada acima — valor padrão bem estabelecido na
    ! literatura, não é erro de digitação.
    call compute_ice_fluxes(fluxes, j1, j2, i1, i2, uas, vas, tas, psl, shum, lwdn, rc)

    ! Rain, snow, pslv — cópia direta (pass-through para o OCN)
    fptr => fluxes%rain
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(rain(i,j), 0.0_ESMF_KIND_R8)  ! clamp ≥ 0 (artefato bilinear)
    end do; end do

    fptr => fluxes%snow
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(snow_g(i,j), 0.0_ESMF_KIND_R8)
    end do; end do

    fptr => fluxes%pslv
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = psl(i,j)
    end do; end do

    ! rugosidade superficial via Charnock + Smith (1988)
    !
    ! z0 = alpha * u*² / g  +  beta * nu / u*
    !       (Charnock)              (Smith — termo viscoso)
    !
    ! alpha = 0.018   (constante de Charnock)
    ! beta  = 0.11    (Smith 1988)
    ! g     = 9.81 m/s²
    ! nu    = 1.5e-5 m²/s  (viscosidade cinemática do ar a 20 °C)
    ! u*    = sqrt( |tau| / rho_ar )
    call compute_roughness_length(fluxes, j1, j2, i1, i2)

    ! duu10n = |V_atm − V_ocn|² (protocolo CMEPS)
    fptr => fluxes%duu10n
    if (associated(uocn) .and. associated(vocn)) then
      do j=j1,j2; do i=i1,i2
        fptr(i,j) = (uas(i,j) - uocn(i,j))**2 + (vas(i,j) - vocn(i,j))**2
      end do; end do
    else
      ! Fallback: sem correntes disponíveis, usa vento absoluto²
      call log_warning(COMP_MED, 'uocn/vocn nulos: So_duu10n calculado com o vento absoluto')
      do j=j1,j2; do i=i1,i2
        fptr(i,j) = uas(i,j)**2 + vas(i,j)**2
      end do; end do
    end if

    ! Sem o SIS2 dinâmico, a fração de gelo da malha de fluxo é recalculada
    ! logo depois desta rotina, pela fase ice_fraction_without_sis2
    ! (med_exchange). Os fluxos deste passo usam a fração que já estava em
    ! fluxo%ifrac.

    rc = ESMF_SUCCESS
  end subroutine calc_bulk_ncar

  !> @brief Hora UTC decimal e declinação solar do instante corrente do relógio.
  !!
  !! O dia do ano e a hora são os mesmos para toda a grade neste instante de
  !! acoplamento; o ângulo zenital, que muda por célula, é calculado em
  !! ocean_direct_albedo a partir destes dois valores. Se o relógio falhar,
  !! usa o meio-dia do equinócio (rc volta com ESMF_SUCCESS).
  !!
  !! @param[in]  clock     relógio do mediador
  !! @param[out] utc_hour  hora UTC decimal [h]
  !! @param[out] decl      declinação solar [rad]
  !! @param[out] rc        sempre ESMF_SUCCESS
  subroutine solar_time_and_declination(clock, utc_hour, decl, rc)
    type(ESMF_Clock),   intent(in)  :: clock
    real(ESMF_KIND_R8), intent(out) :: utc_hour
    real(ESMF_KIND_R8), intent(out) :: decl
    integer,            intent(out) :: rc

    real(ESMF_KIND_R8), parameter :: PI_ZEN = 3.14159265358979_ESMF_KIND_R8
    real(ESMF_KIND_R8) :: gamma_doy
    integer :: doy, yy, mm, dd, hh, mn, ss
    type(ESMF_Time) :: currT

    ! dia-do-ano e hora UTC decimal, uma vez por
    ! chamada (o ângulo zenital muda por célula via lat/lon, mas doy/hora
    ! são os mesmos para toda a grade neste instante de acoplamento).
    call ESMF_ClockGet(clock, currTime=currT, rc=rc)
    if (rc == ESMF_SUCCESS) then
      call ESMF_TimeGet(currT, yy=yy, mm=mm, dd=dd, h=hh, m=mn, s=ss, &
        dayOfYear=doy, rc=rc)
    end if
    if (rc /= ESMF_SUCCESS) then
      ! Fallback seguro: meio-dia do equinócio (decl~0, zênite só por
      ! latitude) — nunca deixa a formula indefinida se o clock falhar.
      doy = 80; utc_hour = 12.0_ESMF_KIND_R8
      rc = ESMF_SUCCESS
    else
      utc_hour = real(hh, ESMF_KIND_R8) + real(mn, ESMF_KIND_R8)/60.0_ESMF_KIND_R8 &
                 + real(ss, ESMF_KIND_R8)/3600.0_ESMF_KIND_R8
    end if

    ! Declinação solar — aproximação de Spencer (1971), erro típico < 0,1
    ! grau. gamma = ângulo fracionário do ano [rad].
    gamma_doy = 2.0_ESMF_KIND_R8 * PI_ZEN * real(doy-1, ESMF_KIND_R8) / 365.0_ESMF_KIND_R8
    decl = 0.006918_ESMF_KIND_R8 &
         - 0.399912_ESMF_KIND_R8 * cos(gamma_doy)   + 0.070257_ESMF_KIND_R8 * sin(gamma_doy) &
         - 0.006758_ESMF_KIND_R8 * cos(2.0_ESMF_KIND_R8*gamma_doy) + 0.000907_ESMF_KIND_R8 * sin(2.0_ESMF_KIND_R8*gamma_doy) &
         - 0.002697_ESMF_KIND_R8 * cos(3.0_ESMF_KIND_R8*gamma_doy) + 0.001480_ESMF_KIND_R8 * sin(3.0_ESMF_KIND_R8*gamma_doy)
  end subroutine solar_time_and_declination

  !> @brief Fluxos sobre água aberta pelas formulas bulk NCAR, com coeficientes
  !! neutros: tensão do vento (taux, tauy), calor sensível, evaporação e
  !! balanco de onda longa, escritos em fluxo. A SST é a da grade ATM
  !! interna; fora de (271, 308) K, ou sem SST, usa SST_BULK_FALLBACK.
  !!
  !! @param[in]    fluxo   arrays da física (escreve taux, tauy, sen, evap, lwnet)
  !! @param[in]    sst     SST na grade ATM (pode estar desassociado)
  !! @param[in]    uas..shum  campos atmosféricos na grade ATM
  !! @param[in]    i1,i2,j1,j2  limites locais da DE
  subroutine compute_ocean_fluxes(fluxes, sst, uas, vas, tas, psl, lwdn, shum, &
                                  i1, i2, j1, j2)
    type(med_flux_t),   intent(in)    :: fluxes
    real(ESMF_KIND_R8), pointer, intent(in) :: sst(:,:)
    real(ESMF_KIND_R8), intent(in)    :: uas(:,:), vas(:,:), tas(:,:)
    real(ESMF_KIND_R8), intent(in)    :: psl(:,:), lwdn(:,:), shum(:,:)
    integer,            intent(in)    :: i1, i2, j1, j2

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8) :: wspd, qsat, sst_eff
    integer :: i, j

    nullify(fptr)

    ! Taux = rho * Cd * |V| * u10
    fptr => fluxes%taux
    do j=j1,j2; do i=i1,i2
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      ! clamp ±5 Pa (limite físico cat-5 ~3 Pa)
      fptr(i,j) = max(-5.0_ESMF_KIND_R8, min(5.0_ESMF_KIND_R8, &
        rho_air * Cd_neut * wspd * uas(i,j)))
    end do; end do

    ! Tauy = rho * Cd * |V| * v10
    fptr => fluxes%tauy
    do j=j1,j2; do i=i1,i2
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      fptr(i,j) = max(-5.0_ESMF_KIND_R8, min(5.0_ESMF_KIND_R8, &
        rho_air * Cd_neut * wspd * vas(i,j)))
    end do; end do

    ! Calor sensível = rho * Cp * Ch * |V| * (Tair - SST)
    fptr => fluxes%sen
    do j=j1,j2; do i=i1,i2
      ! pular células sem tas físico (tas < 100 K = sem dado)
      if (tas(i,j) < 100.0_ESMF_KIND_R8) cycle
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      sst_eff = effective_sst(sst, i, j)
      ! clamp ±500 W/m²
      fptr(i,j) = max(-500.0_ESMF_KIND_R8, min(500.0_ESMF_KIND_R8, &
        rho_air * Cp_air * Ch_neut * wspd * (tas(i,j) - sst_eff)))
    end do; end do

    ! Evaporação = rho * Ce * |V| * (qsat(SST) − qair)
    fptr => fluxes%evap
    do j=j1,j2; do i=i1,i2
      if (tas(i,j) < 100.0_ESMF_KIND_R8) cycle
      ! Pular células sem psl físico, simétrico as guardas de lwdn e de tas.
      !
      ! O `max(psl,1.0)` no denominador de qsat, logo abaixo, protege contra
      ! divisão por zero mas produz um resultado fisicamente absurdo em vez de
      ! pular a célula: com psl=0 o divisor vira 1 Pa em lugar de ~101325 Pa, e
      ! qsat sai cinco ordens de grandeza alto. A evaporação então satura no
      ! clamp de +1e-4 kg/m²/s (~8,6 mm/d) no globo inteiro — e esse fluxo
      ! saturado é entregue ao oceano, não fica só no diagnóstico.
      !
      ! Isso aparecia no passo 1 de coupling_mode='sequential': ali o mediador
      ! roda ANTES do primeiro avanço do MPAS, e os diagnósticos de física da
      ! atmosfera (radiação, precipitação, pressão ao nível do mar) ainda estão
      ! zerados. As demais guardas já tratavam lwdn e swdn; psl não tinha.
      ! Pressão ao nível do mar nunca desce de ~870 hPa na natureza, então
      ! 500 hPa é um limiar seguro para "ausência de dado".
      if (psl(i,j) < 5.0e4_ESMF_KIND_R8) cycle
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      sst_eff = effective_sst(sst, i, j)
      qsat = eps_q * es_coef_a * &
        exp(es_coef_b*(sst_eff-T_freeze)/(sst_eff-T_freeze+es_coef_c)) / &
        max(psl(i,j), 1.0_ESMF_KIND_R8)
      ! Convenção CMEPS: E > 0 = oceano → atmosfera
      ! clamp ±1e-4 kg/m²/s (~±8.6 mm/d)
      fptr(i,j) = max(-1.0e-4_ESMF_KIND_R8, min(1.0e-4_ESMF_KIND_R8, &
        rho_air * Ce_neut * wspd * (qsat - shum(i,j))))
    end do; end do

    ! Balanço LW = lwdn − emissividade·σ·SST⁴
    fptr => fluxes%lwnet
    do j=j1,j2; do i=i1,i2
      ! pular células sem lwdn real (lwdn=0 indica ausência)
      if (lwdn(i,j) < 1.0_ESMF_KIND_R8) cycle
      sst_eff = effective_sst(sst, i, j)
      fptr(i,j) = max( &
        max(lwdn(i,j), 0.0_ESMF_KIND_R8) - 0.97_ESMF_KIND_R8 * sigma_sb * sst_eff**4, &
        -300.0_ESMF_KIND_R8)
    end do; end do
  end subroutine compute_ocean_fluxes

  !> @brief SST usada nos fluxos sobre água aberta: sst(i,j) dentro de (271, 308) K;
  !! fora da faixa, ou sem SST (ponteiro nulo), SST_BULK_FALLBACK. Os testes
  !! ficam em if separados porque o Fortran não garante o curto-circuito do
  !! .and.: com o ponteiro nulo, sst(i,j) não pode ser lido.
  pure function effective_sst(sst, i, j) result(sst_eff)
    real(ESMF_KIND_R8), pointer, intent(in) :: sst(:,:)
    integer,                     intent(in) :: i, j
    real(ESMF_KIND_R8) :: sst_eff

    sst_eff = SST_BULK_FALLBACK
    if (associated(sst)) then
      if (sst(i,j) > 271.0_ESMF_KIND_R8 .and. sst(i,j) < 308.0_ESMF_KIND_R8) sst_eff = sst(i,j)
    end if
  end function effective_sst

  !> @brief Comprimento de rugosidade do mar (Sf_zorl) pela tensão do vento:
  !! Charnock (ondas) mais Smith (1988, viscosa), limitado a [Z0_MIN, Z0_MAX];
  !! sobre terra (So_omask < 0,5), Z0_MIN.
  !! @param[in] fluxes          arrays da malha de fluxo (lê taux, tauy e omask;
  !!                            escreve zorl)
  !! @param[in] j1, j2, i1, i2  limites locais da DE
  subroutine compute_roughness_length(fluxes, j1, j2, i1, i2)
    type(med_flux_t), intent(in) :: fluxes
    integer, intent(in) :: j1
    integer, intent(in) :: j2
    integer, intent(in) :: i1
    integer, intent(in) :: i2
    integer :: i
    integer :: j
    real(ESMF_KIND_R8), parameter :: ALPHA_CHARNOCK = 0.018_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: BETA_SMITH     = 0.11_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: NU_AIR         = 1.5e-5_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: USTAR_MIN      = 1.0e-4_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: Z0_MIN         = 1.0e-5_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: Z0_MAX         = 0.1_ESMF_KIND_R8

    real(ESMF_KIND_R8), pointer :: p_taux(:,:)
    real(ESMF_KIND_R8), pointer :: p_tauy(:,:)
    real(ESMF_KIND_R8), pointer :: p_zorl(:,:)
    real(ESMF_KIND_R8), pointer :: p_omask_z(:,:)
    real(ESMF_KIND_R8) :: tau_mag, ustar, z0_charnock, z0_smith, z0_total

    p_taux => fluxes%taux
    p_tauy => fluxes%tauy
    p_zorl => fluxes%zorl
    ! máscara real (So_omask interpolada); uma heurística de SST~=T_FILL_LAND
    ! colidiria com água aberta no ponto de congelamento, perto da borda do
    ! gelo.
    p_omask_z => fluxes%omask

    if (associated(p_taux) .and. associated(p_tauy) .and. associated(p_zorl)) then
      do j = j1, j2
        do i = i1, i2
          tau_mag     = sqrt(p_taux(i,j)**2 + p_tauy(i,j)**2)
          ustar       = sqrt(tau_mag / rho_air)
          ustar       = max(ustar, USTAR_MIN)
          z0_charnock = ALPHA_CHARNOCK * ustar**2 / GRAV
          z0_smith    = BETA_SMITH * NU_AIR / ustar
          z0_total    = max(Z0_MIN, min(Z0_MAX, z0_charnock + z0_smith))
          ! Sobre terra (máscara real So_omask, ver): usar default
          if (associated(p_omask_z)) then
            if (p_omask_z(i,j) < 0.5_ESMF_KIND_R8) z0_total = Z0_MIN
          end if
          p_zorl(i,j) = z0_total
        end do
      end do
      call log_debug(COMP_MED, 'Sf_zorl calculado por Charnock + Smith')
    end if
  end subroutine compute_roughness_length

  !> @brief Fluxos entre o gelo e a atmosfera (Fioi_*) com a temperatura real do gelo.
  !!
  !! Calcula, nesta ordem, taux, tauy, calor sensível, evaporação e balanço
  !! de onda longa sobre o gelo, na grade ATM. As fórmulas bulk são as da
  !! água aberta, com a temperatura do gelo no lugar da SST e o fator de
  !! estabilidade de Louis (1979) (ver louis_stability).
  !!
  !! Onde a fração de gelo é menor que IFRAC_MIN_FIOI, Si_t_sis2 é só o
  !! valor padrão do cap do gelo (ponto de congelamento) e não uma
  !! temperatura real; ali cada fluxo recebe o valor já calculado para a
  !! água aberta (Foxx_*), em vez de um gradiente de temperatura fictício.
  !!
  !! Sem fluxo%tice associado, os Fioi_* ficam com o valor inicial.
  subroutine compute_ice_fluxes(fluxes, j1, j2, i1, i2, uas, vas, tas, psl, shum, lwdn, rc)
    type(med_flux_t), intent(in) :: fluxes
    integer, intent(in) :: j1
    integer, intent(in) :: j2
    integer, intent(in) :: i1
    integer, intent(in) :: i2
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), intent(in) :: uas(:,:)
    real(ESMF_KIND_R8), intent(in) :: vas(:,:)
    real(ESMF_KIND_R8), intent(in) :: tas(:,:)
    real(ESMF_KIND_R8), intent(in) :: psl(:,:)
    real(ESMF_KIND_R8), intent(in) :: shum(:,:)
    real(ESMF_KIND_R8), intent(in) :: lwdn(:,:)
    real(ESMF_KIND_R8), pointer :: tice(:,:)
    real(ESMF_KIND_R8), pointer :: fptr_ice(:,:)
    real(ESMF_KIND_R8), pointer :: ifr_g(:,:)
    real(ESMF_KIND_R8), pointer :: f_taux_ocn(:,:), f_tauy_ocn(:,:)
    real(ESMF_KIND_R8), pointer :: f_sen_ocn(:,:), f_evap_ocn(:,:)
    real(ESMF_KIND_R8), pointer :: f_lwnet_ocn(:,:)

    tice        => fluxes%tice
    ifr_g       => fluxes%ifrac
    f_taux_ocn  => fluxes%taux
    f_tauy_ocn  => fluxes%tauy
    f_sen_ocn   => fluxes%sen
    f_evap_ocn  => fluxes%evap
    f_lwnet_ocn => fluxes%lwnet

    if (associated(tice)) then

      fptr_ice => fluxes%taux_ice
      call ice_wind_stress(fptr_ice, f_taux_ocn, ifr_g, tice, uas, vas, tas, uas, &
                           i1, i2, j1, j2)

      fptr_ice => fluxes%tauy_ice
      call ice_wind_stress(fptr_ice, f_tauy_ocn, ifr_g, tice, uas, vas, tas, vas, &
                           i1, i2, j1, j2)

      fptr_ice => fluxes%sen_ice
      call ice_sensible_heat(fptr_ice, f_sen_ocn, ifr_g, tice, uas, vas, tas, &
                             i1, i2, j1, j2)

      fptr_ice => fluxes%evap_ice
      call ice_evaporation(fptr_ice, f_evap_ocn, ifr_g, tice, uas, vas, tas, psl, shum, &
                           i1, i2, j1, j2)

      fptr_ice => fluxes%lwnet_ice
      call ice_longwave(fptr_ice, f_lwnet_ocn, ifr_g, tice, lwdn, i1, i2, j1, j2)

      call log_debug(COMP_MED, 'Fioi_taux/tauy/sen/evap/lwnet calculados com a ' // &
        'temperatura do gelo')
    else
      call log_warning(COMP_MED, 'f_tice_atm nao associado: Fioi_* ficam com o ' // &
        'valor inicial')
    end if
    rc = ESMF_SUCCESS
  end subroutine compute_ice_fluxes

  !> @brief Temperatura efetiva do gelo.
  !!
  !! Si_t_sis2 quando está na faixa física (180 K; 273,16 K], a mesma
  !! validada em export_si_tskin; fora dela, o ponto de congelamento.
  pure function ice_temp_eff(tice) result(tice_eff)
    real(ESMF_KIND_R8), intent(in) :: tice
    real(ESMF_KIND_R8) :: tice_eff

    tice_eff = merge(tice, T_FREEZE_SEAWATER, &
      tice > T_ICE_MIN .and. tice <= T_ICE_MAX)
  end function ice_temp_eff

  !> @brief Número de Richardson bulk e fator de estabilidade de Louis (1979).
  !!
  !! rib > 0 indica estratificação estável (ar mais quente que a superfície,
  !! o caso típico sobre o gelo): a troca turbulenta é amortecida, com fator
  !! entre STAB_FAC_MIN e 1. rib <= 0 indica estratificação instável: a
  !! convecção reforça a troca, com fator entre 1 e STAB_FAC_MAX. O mesmo
  !! fator vale para o momento, o calor e a umidade.
  pure subroutine louis_stability(tas, tice_eff, wspd, rib, stab_fac)
    real(ESMF_KIND_R8), intent(in)  :: tas, tice_eff, wspd
    real(ESMF_KIND_R8), intent(out) :: rib, stab_fac

    rib = GRAV * Z_REF * (tas - tice_eff) / &
          (max(tas, 100.0_ESMF_KIND_R8) * wspd**2)
    if (rib > 0.0_ESMF_KIND_R8) then
      stab_fac = 1.0_ESMF_KIND_R8 / &
        (1.0_ESMF_KIND_R8 + 2.0_ESMF_KIND_R8*LOUIS_B*rib/sqrt(1.0_ESMF_KIND_R8+LOUIS_B*rib))
      stab_fac = max(STAB_FAC_MIN, min(1.0_ESMF_KIND_R8, stab_fac))
    else
      stab_fac = 1.0_ESMF_KIND_R8 - &
        (2.0_ESMF_KIND_R8*LOUIS_B*rib) / &
        (1.0_ESMF_KIND_R8 + 3.0_ESMF_KIND_R8*LOUIS_B*LOUIS_C*sqrt(-rib))
      stab_fac = max(1.0_ESMF_KIND_R8, min(STAB_FAC_MAX, stab_fac))
    end if
  end subroutine louis_stability

  !> @brief Tensão do vento sobre o gelo, numa componente (Fioi_taux ou Fioi_tauy).
  !!
  !! wind é a componente do vento na direção da tensão (uas para taux, vas
  !! para tauy); f_ocn é o fluxo da água aberta na mesma direção.
  subroutine ice_wind_stress(fptr_ice, f_ocn, ifr_g, tice, uas, vas, tas, wind, &
                             i1, i2, j1, j2)
    real(ESMF_KIND_R8), pointer, intent(in) :: fptr_ice(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: f_ocn(:,:), ifr_g(:,:), tice(:,:)
    real(ESMF_KIND_R8), intent(in) :: uas(:,:), vas(:,:), tas(:,:), wind(:,:)
    integer,            intent(in) :: i1, i2, j1, j2
    integer :: i, j
    real(ESMF_KIND_R8) :: wspd, tice_eff, rib, stab_fac

    do j=j1,j2; do i=i1,i2
      if (associated(ifr_g) .and. associated(f_ocn)) then
        if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
          fptr_ice(i,j) = f_ocn(i,j)
          cycle
        end if
      end if
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      tice_eff = ice_temp_eff(tice(i,j))
      call louis_stability(tas(i,j), tice_eff, wspd, rib, stab_fac)
      fptr_ice(i,j) = max(-5.0_ESMF_KIND_R8, min(5.0_ESMF_KIND_R8, &
        rho_air * Cd_neut * stab_fac * wspd * wind(i,j)))
    end do; end do
  end subroutine ice_wind_stress

  !> @brief Calor sensível sobre o gelo (Fioi_sen), limitado a +-500 W/m2.
  !!
  !! Células com tas < 100 K (sem dado da atmosfera) ficam como estão.
  !! Conta, antes do limite, as células com |fluxo| > 490 W/m2 e, com
  !! log_level='debug', registra a primeira delas (log_ice_stability):
  !! saturação frequente indica vento ou diferença de temperatura extremos.
  !! No ramo instável, stab_fac pode passar de 1 (reforço da troca).
  subroutine ice_sensible_heat(fptr_ice, f_sen_ocn, ifr_g, tice, uas, vas, tas, &
                               i1, i2, j1, j2)
    real(ESMF_KIND_R8), pointer, intent(in) :: fptr_ice(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: f_sen_ocn(:,:), ifr_g(:,:), tice(:,:)
    real(ESMF_KIND_R8), intent(in) :: uas(:,:), vas(:,:), tas(:,:)
    integer,            intent(in) :: i1, i2, j1, j2
    integer :: i, j
    real(ESMF_KIND_R8) :: wspd, tice_eff, rib, stab_fac
    real(ESMF_KIND_R8) :: raw_sen
    integer :: n_sat
    integer :: i_sat
    integer :: j_sat
    real(ESMF_KIND_R8) :: wspd_sat
    real(ESMF_KIND_R8) :: dt_sat
    real(ESMF_KIND_R8) :: raw_sat
    real(ESMF_KIND_R8) :: tas_sat
    real(ESMF_KIND_R8) :: tice_sat
    real(ESMF_KIND_R8) :: rib_sat
    real(ESMF_KIND_R8) :: stab_sat

    n_sat = 0; i_sat = -1; j_sat = -1
    wspd_sat = 0.0_ESMF_KIND_R8; dt_sat = 0.0_ESMF_KIND_R8
    raw_sat = 0.0_ESMF_KIND_R8; tas_sat = 0.0_ESMF_KIND_R8; tice_sat = 0.0_ESMF_KIND_R8
    rib_sat = 0.0_ESMF_KIND_R8; stab_sat = 1.0_ESMF_KIND_R8
    do j=j1,j2; do i=i1,i2
      if (tas(i,j) < 100.0_ESMF_KIND_R8) cycle
      if (associated(ifr_g) .and. associated(f_sen_ocn)) then
        if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
          fptr_ice(i,j) = f_sen_ocn(i,j)
          cycle
        end if
      end if
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      tice_eff = ice_temp_eff(tice(i,j))
      call louis_stability(tas(i,j), tice_eff, wspd, rib, stab_fac)
      raw_sen = rho_air * Cp_air * Ch_neut * stab_fac * wspd * (tas(i,j) - tice_eff)
      if (abs(raw_sen) > 490.0_ESMF_KIND_R8) then
        n_sat = n_sat + 1
        if (i_sat < 0) then
          i_sat = i; j_sat = j
          wspd_sat = wspd; dt_sat = tas(i,j) - tice_eff
          raw_sat = raw_sen; tas_sat = tas(i,j); tice_sat = tice_eff
          rib_sat = rib; stab_sat = stab_fac
        end if
      end if
      fptr_ice(i,j) = max(-500.0_ESMF_KIND_R8, min(500.0_ESMF_KIND_R8, raw_sen))
    end do; end do

    if (log_debug_enabled()) call log_ice_stability(n_sat, i_sat, j_sat, &
      [wspd_sat, tas_sat, tice_sat, dt_sat, rib_sat, stab_sat, raw_sat])
  end subroutine ice_sensible_heat

  !> @brief Evaporação sobre o gelo (Fioi_evap), limitada a +-1e-4 kg/m2/s.
  !!
  !! Células com psl < 5e4 Pa (sem dado da atmosfera) ficam como estão. A
  !! umidade de saturação sobre o gelo usa a mesma fórmula de
  !! Clausius-Clapeyron da água aberta; a fórmula exata sobre o gelo tem
  !! constantes um pouco diferentes, e a aproximação basta aqui.
  subroutine ice_evaporation(fptr_ice, f_evap_ocn, ifr_g, tice, uas, vas, tas, psl, shum, &
                             i1, i2, j1, j2)
    real(ESMF_KIND_R8), pointer, intent(in) :: fptr_ice(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: f_evap_ocn(:,:), ifr_g(:,:), tice(:,:)
    real(ESMF_KIND_R8), intent(in) :: uas(:,:), vas(:,:), tas(:,:), psl(:,:), shum(:,:)
    integer,            intent(in) :: i1, i2, j1, j2
    integer :: i, j
    real(ESMF_KIND_R8) :: wspd, tice_eff, rib, stab_fac, qsat_ice

    do j=j1,j2; do i=i1,i2
      if (psl(i,j) < 5.0e4_ESMF_KIND_R8) cycle
      if (associated(ifr_g) .and. associated(f_evap_ocn)) then
        if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
          fptr_ice(i,j) = f_evap_ocn(i,j)
          cycle
        end if
      end if
      wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
      tice_eff = ice_temp_eff(tice(i,j))
      call louis_stability(tas(i,j), tice_eff, wspd, rib, stab_fac)
      qsat_ice = eps_q * es_coef_a * &
        exp(es_coef_b*(tice_eff-T_freeze)/(tice_eff-T_freeze+es_coef_c)) / &
        max(psl(i,j), 1.0_ESMF_KIND_R8)
      fptr_ice(i,j) = max(-1.0e-4_ESMF_KIND_R8, min(1.0e-4_ESMF_KIND_R8, &
        rho_air * Ce_neut * stab_fac * wspd * (qsat_ice - shum(i,j))))
    end do; end do
  end subroutine ice_evaporation

  !> @brief Balanço de onda longa sobre o gelo (Fioi_lwnet), limitado a -300 W/m2.
  !!
  !! Células com lwdn < 1 W/m2 (sem dado da atmosfera) ficam como estão. A
  !! emissividade do gelo e da neve (0,99) é um pouco maior que a da água
  !! aberta (0,97).
  subroutine ice_longwave(fptr_ice, f_lwnet_ocn, ifr_g, tice, lwdn, i1, i2, j1, j2)
    real(ESMF_KIND_R8), pointer, intent(in) :: fptr_ice(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: f_lwnet_ocn(:,:), ifr_g(:,:), tice(:,:)
    real(ESMF_KIND_R8), intent(in) :: lwdn(:,:)
    integer,            intent(in) :: i1, i2, j1, j2
    integer :: i, j
    real(ESMF_KIND_R8) :: tice_eff

    do j=j1,j2; do i=i1,i2
      if (lwdn(i,j) < 1.0_ESMF_KIND_R8) cycle
      if (associated(ifr_g) .and. associated(f_lwnet_ocn)) then
        if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
          fptr_ice(i,j) = f_lwnet_ocn(i,j)
          cycle
        end if
      end if
      tice_eff = ice_temp_eff(tice(i,j))
      fptr_ice(i,j) = max( &
        max(lwdn(i,j), 0.0_ESMF_KIND_R8) - 0.99_ESMF_KIND_R8 * sigma_sb * tice_eff**4, &
        -300.0_ESMF_KIND_R8)
    end do; end do
  end subroutine ice_longwave

  !> @brief Onda curta líquida por banda (água aberta e gelo) e albedo de
  !! banda larga para a atmosfera, com o gelo real do SIS2.
  !!
  !! Foxx_swnet_* usa SOMENTE o albedo de água aberta (Briegleb nas bandas
  !! diretas, albedo_ocn nas difusas) e vai para o MOM6, que representa só a
  !! fração (1-Si_ifrac) da célula. Fioi_swnet_* usa SOMENTE o albedo do gelo
  !! por banda (alb_vdr/vdf/idr/idf) e vai para o SIS2 (ver
  !! sis_cap_fields.F90::import_forcing). Com um único valor calculado pelo
  !! albedo médio para os dois, o gelo absorveria SW com um albedo mais baixo
  !! que o seu próprio (contaminado pela água aberta) e o oceano, com um mais
  !! alto (contaminado pelo gelo): dupla contabilização física incorreta em
  !! qualquer célula com 0 < Si_ifrac < 1. O blend ponderado por Si_ifrac vai
  !! para fluxo%albedo (Sf_albedo): esse composto de banda larga PARA A
  !! ATMOSFERA é correto e necessário (a atmosfera só enxerga uma célula).
  !!
  !! Sem a fração ou os albedos do gelo, usa albedo_ocn constante em toda
  !! célula (sw_band_fallback).
  subroutine blend_albedo_with_ice(fluxes, j1, j2, i1, i2, utc_hour, decl, swdn, rc)
    type(med_flux_t), intent(in) :: fluxes
    integer, intent(in) :: j1
    integer, intent(in) :: j2
    integer, intent(in) :: i1
    integer, intent(in) :: i2
    real(ESMF_KIND_R8), intent(in) :: utc_hour
    real(ESMF_KIND_R8), intent(in) :: decl
    real(ESMF_KIND_R8), intent(in) :: swdn(:,:)
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: ifr(:,:)
    real(ESMF_KIND_R8), pointer :: alb_vdr(:,:), alb_vdf(:,:)
    real(ESMF_KIND_R8), pointer :: alb_idr(:,:), alb_idf(:,:)
    real(ESMF_KIND_R8), pointer :: fptr_alb(:,:)

    ifr     => fluxes%ifrac
    alb_vdr => fluxes%alb_vdr
    alb_vdf => fluxes%alb_vdf
    alb_idr => fluxes%alb_idr
    alb_idf => fluxes%alb_idf

    if (associated(ifr) .and. associated(alb_vdr) .and. associated(alb_vdf) &
        .and. associated(alb_idr) .and. associated(alb_idf)) then
      ! Ordem das bandas: a primeira atribui o albedo de banda larga, as
      ! demais somam; a última deixa em fluxo%albedo o albedo efetivo
      ! completo (soma das 4 contribuições ponderadas).
      call sw_band(fluxes, fluxes%swvdr, fluxes%swvdr_ice, j1, j2, i1, i2, swdn, ifr, &
                   alb_vdr, f_vis_dir, .true., .true., utc_hour, decl, rc)
      call sw_band(fluxes, fluxes%swvdf, fluxes%swvdf_ice, j1, j2, i1, i2, swdn, ifr, &
                   alb_vdf, f_vis_dif, .false., .false., utc_hour, decl, rc)
      call sw_band(fluxes, fluxes%swidr, fluxes%swidr_ice, j1, j2, i1, i2, swdn, ifr, &
                   alb_idr, f_nir_dir, .true., .false., utc_hour, decl, rc)
      call sw_band(fluxes, fluxes%swidf, fluxes%swidf_ice, j1, j2, i1, i2, swdn, ifr, &
                   alb_idf, f_nir_dif, .false., .false., utc_hour, decl, rc)
    else
      ! Sem dado real de gelo: albedo_ocn constante em Foxx_swnet_*, e o
      ! mesmo valor em Fioi_swnet_* (não há base para calcular algo
      ! diferente).
      call log_warning(COMP_MED, 'f_ifrac_atm/f_alb_*_ice nao associados: ' // &
        'onda curta com albedo_ocn constante')
      call sw_band_fallback(fluxes%swvdr, fluxes%swvdr_ice, j1, j2, i1, i2, swdn, f_vis_dir)
      call sw_band_fallback(fluxes%swvdf, fluxes%swvdf_ice, j1, j2, i1, i2, swdn, f_vis_dif)
      call sw_band_fallback(fluxes%swidr, fluxes%swidr_ice, j1, j2, i1, i2, swdn, f_nir_dir)
      call sw_band_fallback(fluxes%swidf, fluxes%swidf_ice, j1, j2, i1, i2, swdn, f_nir_dif)
      ! Sem dado de gelo nem de zênite, exporta a constante também como
      ! albedo de banda larga (degrada de forma consistente).
      fptr_alb => fluxes%albedo
      if (associated(fptr_alb)) fptr_alb(i1:i2,j1:j2) = albedo_ocn
    end if
    rc = ESMF_SUCCESS
  end subroutine blend_albedo_with_ice

  !> @brief Uma banda de onda curta com o gelo real: Foxx_swnet (água aberta),
  !! Fioi_swnet (gelo) e a contribuição da banda ao albedo de banda larga.
  !!
  !! Nas bandas diretas (direct), o albedo da água aberta depende do zênite
  !! solar (ocean_direct_albedo, Briegleb et al. 1986); nas difusas, é a
  !! constante albedo_ocn. A banda visível direta também grava o cosseno do
  !! zênite (fluxo%coszen). Na primeira banda (first), o albedo de banda
  !! larga recebe a contribuição; nas demais, soma-se a ela.
  subroutine sw_band(fluxes, f_sw, f_sw_ice, j1, j2, i1, i2, swdn, ifr, alb_ice, frac, &
                     direct, first, utc_hour, decl, rc)
    type(med_flux_t), intent(in) :: fluxes
    real(ESMF_KIND_R8), pointer, intent(in) :: f_sw(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: f_sw_ice(:,:)
    integer, intent(in) :: j1
    integer, intent(in) :: j2
    integer, intent(in) :: i1
    integer, intent(in) :: i2
    real(ESMF_KIND_R8), intent(in) :: swdn(:,:)
    real(ESMF_KIND_R8), pointer :: ifr(:,:)
    real(ESMF_KIND_R8), pointer :: alb_ice(:,:)
    real(ESMF_KIND_R8), intent(in) :: frac
    logical, intent(in) :: direct
    logical, intent(in) :: first
    real(ESMF_KIND_R8), intent(in) :: utc_hour
    real(ESMF_KIND_R8), intent(in) :: decl
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: fptr_alb(:,:)
    real(ESMF_KIND_R8), pointer :: fptr_cz(:,:)
    real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:)
    real(ESMF_KIND_R8) :: alb_eff
    real(ESMF_KIND_R8) :: alb_ocn
    real(ESMF_KIND_R8) :: coszen_ij
    real(ESMF_KIND_R8) :: fi
    integer :: i
    integer :: j

    nullify(fptr_cz)
    fptr => f_sw
    if (direct .and. first) fptr_cz => fluxes%coszen
    fptr_alb => fluxes%albedo
    fptr_ice2 => f_sw_ice
    do j=j1,j2; do i=i1,i2
      fi = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifr(i,j)))
      if (direct) then
        call ocean_direct_albedo(i, j, utc_hour, decl, coszen_ij, alb_ocn)
        if (associated(fptr_cz)) fptr_cz(i,j) = coszen_ij
      else
        alb_ocn = albedo_ocn
      end if
      ! Foxx_swnet (MOM6): SOMENTE albedo de água aberta.
      fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_ocn) * frac
      ! Fioi_swnet (SIS2): SOMENTE albedo do gelo por banda.
      if (associated(fptr_ice2)) &
        fptr_ice2(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_ice(i,j)) * frac
      ! Sf_albedo (atmosfera): blend ponderado por Si_ifrac.
      alb_eff = (1.0_ESMF_KIND_R8 - fi) * alb_ocn + fi * alb_ice(i,j)
      if (associated(fptr_alb)) then
        if (first) then
          fptr_alb(i,j) = frac * alb_eff
        else
          fptr_alb(i,j) = fptr_alb(i,j) + frac * alb_eff
        end if
      end if
    end do; end do
    rc = ESMF_SUCCESS
  end subroutine sw_band

  !> @brief Cosseno do zênite solar e albedo da água aberta para feixe direto na
  !! célula (i,j) da grade ATM 360x180.
  !!
  !! lat/lon analíticos da grade ATM (mesma formula da criação da grade em
  !! med_init.F90::create_atm_grid). Albedo de Briegleb et al. (1986); o
  !! corte coszen>=0.02 evita divergência perto do horizonte (ali a célula
  !! já recebe swdn~0), e o resultado fica em [0.03, 0.99].
  subroutine ocean_direct_albedo(i, j, utc_hour, decl, coszen_ij, alb_ocn_dir)
    real(ESMF_KIND_R8), parameter :: PI_ZEN = 3.14159265358979_ESMF_KIND_R8
    integer, intent(in) :: i
    integer, intent(in) :: j
    real(ESMF_KIND_R8), intent(in) :: utc_hour
    real(ESMF_KIND_R8), intent(in) :: decl
    real(ESMF_KIND_R8), intent(out) :: coszen_ij
    real(ESMF_KIND_R8), intent(out) :: alb_ocn_dir
    real(ESMF_KIND_R8) :: hour_angle
    real(ESMF_KIND_R8) :: lat_ij
    real(ESMF_KIND_R8) :: lon_ij

    lon_ij = (real(i,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * (360.0_ESMF_KIND_R8/ATM_NX) &
             + 0.5_ESMF_KIND_R8*(360.0_ESMF_KIND_R8/ATM_NX)
    lat_ij = -90.0_ESMF_KIND_R8 + (real(j,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * (180.0_ESMF_KIND_R8/ATM_NY) &
             + 0.5_ESMF_KIND_R8*(180.0_ESMF_KIND_R8/ATM_NY)
    hour_angle = (PI_ZEN/12.0_ESMF_KIND_R8) * (utc_hour + lon_ij/15.0_ESMF_KIND_R8 - 12.0_ESMF_KIND_R8)
    coszen_ij = sin(lat_ij*PI_ZEN/180.0_ESMF_KIND_R8) * sin(decl) + &
                cos(lat_ij*PI_ZEN/180.0_ESMF_KIND_R8) * cos(decl) * cos(hour_angle)
    coszen_ij = max(0.0_ESMF_KIND_R8, coszen_ij)
    alb_ocn_dir = 0.026_ESMF_KIND_R8/(max(coszen_ij,0.02_ESMF_KIND_R8)**1.7_ESMF_KIND_R8 + 0.065_ESMF_KIND_R8) &
                + 0.15_ESMF_KIND_R8*(max(coszen_ij,0.02_ESMF_KIND_R8)-0.1_ESMF_KIND_R8) &
                                    *(max(coszen_ij,0.02_ESMF_KIND_R8)-0.5_ESMF_KIND_R8) &
                                    *(max(coszen_ij,0.02_ESMF_KIND_R8)-1.0_ESMF_KIND_R8)
    alb_ocn_dir = max(0.03_ESMF_KIND_R8, min(0.99_ESMF_KIND_R8, alb_ocn_dir))
  end subroutine ocean_direct_albedo

  !> @brief Uma banda de onda curta sem dado de gelo: albedo_ocn constante em
  !! Foxx_swnet, e o mesmo valor copiado em Fioi_swnet.
  subroutine sw_band_fallback(f_sw, f_sw_ice, j1, j2, i1, i2, swdn, frac)
    real(ESMF_KIND_R8), pointer, intent(in) :: f_sw(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: f_sw_ice(:,:)
    integer, intent(in) :: j1
    integer, intent(in) :: j2
    integer, intent(in) :: i1
    integer, intent(in) :: i2
    real(ESMF_KIND_R8), intent(in) :: swdn(:,:)
    real(ESMF_KIND_R8), intent(in) :: frac
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:)
    integer :: i
    integer :: j

    fptr => f_sw
    do j=j1,j2; do i=i1,i2
      fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * frac
    end do; end do
    fptr_ice2 => f_sw_ice
    if (associated(fptr_ice2)) fptr_ice2(i1:i2,j1:j2) = fptr(i1:i2,j1:j2)
  end subroutine sw_band_fallback

end module med_bulk_ncar_mod
