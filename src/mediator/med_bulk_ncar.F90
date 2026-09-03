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
                                cfg_use_sis2_dynamic,     &
                                cfg_docn_ice_init_only,   &  ! Sprint B.1
                                cfg_write_fixdiag
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
                             i1, i2, j1, j2, clock, rc)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    real(ESMF_KIND_R8),      intent(in)    :: uas(:,:), vas(:,:), tas(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: rain(:,:), shum(:,:)
    real(ESMF_KIND_R8),      intent(in)    :: snow_g(:,:)
    integer,                 intent(in)    :: i1, i2, j1, j2
    type(ESMF_Clock),        intent(in)    :: clock
    integer,                 intent(out)   :: rc

    ! Fase 2.5 (B-ZENITH-01): angulo zenital solar, calculado uma vez por
    ! chamada (nao depende de i,j) e reaproveitado por todas as celulas.
    real(ESMF_KIND_R8) :: coszen_ij, lat_ij, lon_ij, hour_angle, decl, gamma_doy
    real(ESMF_KIND_R8) :: utc_hour, alb_ocn_dir
    integer :: doy, yy, mm, dd, hh, mn, ss
    type(ESMF_Time) :: currT
    integer, parameter :: NX_ATM_ZEN = 360, NY_ATM_ZEN = 180
    real(ESMF_KIND_R8), parameter :: PI_ZEN = 3.14159265358979_ESMF_KIND_R8
    ! Briegleb et al. (1986) — albedo direto de agua aberta em funcao do
    ! angulo zenital solar; usado em CESM/CAM. Faixa fisica tipica: ~0.03
    ! (sol a pino) a >0.3 (sol raso). Substitui albedo_ocn constante nas
    ! bandas DIRETAS (vis_dir, nir_dir); as bandas DIFUSAS mantêm
    ! albedo_ocn constante (a formula de Briegleb e' so' para feixe direto —
    ! luz difusa nao tem um unico angulo de incidencia).

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    real(ESMF_KIND_R8), pointer :: uocn(:,:), vocn(:,:)
    real(ESMF_KIND_R8) :: wspd, qsat, sst_eff
    integer :: i, j

    rc = ESMF_SUCCESS
    nullify(fptr, sst, uocn, vocn)

    !==========================================================================
    ! Fase 2.5 (B-ZENITH-01): dia-do-ano e hora UTC decimal, uma vez por
    ! chamada (o angulo zenital muda por celula via lat/lon, mas doy/hora
    ! sao os mesmos para toda a grade neste instante de acoplamento).
    !==========================================================================
    call ESMF_ClockGet(clock, currTime=currT, rc=rc)
    if (rc == ESMF_SUCCESS) then
      call ESMF_TimeGet(currT, yy=yy, mm=mm, dd=dd, h=hh, m=mn, s=ss, &
        dayOfYear=doy, rc=rc)
    end if
    if (rc /= ESMF_SUCCESS) then
      ! Fallback seguro: meio-dia do equinocio (decl~0, zenite so' por
      ! latitude) — nunca deixa a formula indefinida se o clock falhar.
      doy = 80; utc_hour = 12.0_ESMF_KIND_R8
      rc = ESMF_SUCCESS
    else
      utc_hour = real(hh, ESMF_KIND_R8) + real(mn, ESMF_KIND_R8)/60.0_ESMF_KIND_R8 &
                 + real(ss, ESMF_KIND_R8)/3600.0_ESMF_KIND_R8
    end if

    ! Declinacao solar — aproximacao de Spencer (1971), erro tipico < 0,1
    ! grau. gamma = angulo fracionario do ano [rad].
    gamma_doy = 2.0_ESMF_KIND_R8 * PI_ZEN * real(doy-1, ESMF_KIND_R8) / 365.0_ESMF_KIND_R8
    decl = 0.006918_ESMF_KIND_R8 &
         - 0.399912_ESMF_KIND_R8 * cos(gamma_doy)   + 0.070257_ESMF_KIND_R8 * sin(gamma_doy) &
         - 0.006758_ESMF_KIND_R8 * cos(2.0_ESMF_KIND_R8*gamma_doy) + 0.000907_ESMF_KIND_R8 * sin(2.0_ESMF_KIND_R8*gamma_doy) &
         - 0.002697_ESMF_KIND_R8 * cos(3.0_ESMF_KIND_R8*gamma_doy) + 0.001480_ESMF_KIND_R8 * sin(3.0_ESMF_KIND_R8*gamma_doy)

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
      ! BUG-CALC-06 (v14.21): pular celulas sem psl fisico, simetrico as
      ! guardas BUG-CALC-03 (lwdn) e BUG-CALC-04 (tas).
      !
      ! O `max(psl,1.0)` no denominador de qsat, logo abaixo, protege contra
      ! divisao por zero mas produz um resultado fisicamente absurdo em vez de
      ! pular a celula: com psl=0 o divisor vira 1 Pa em lugar de ~101325 Pa, e
      ! qsat sai cinco ordens de grandeza alto. A evaporacao entao satura no
      ! clamp de +1e-4 kg/m²/s (~8,6 mm/d) no globo inteiro — e esse fluxo
      ! saturado e' entregue ao oceano, nao fica so' no diagnostico.
      !
      ! Isso aparecia no passo 1 de coupling_mode='sequential': ali o mediador
      ! roda ANTES do primeiro avanco do MPAS, e os diagnosticos de fisica da
      ! atmosfera (radiacao, precipitacao, pressao ao nivel do mar) ainda estao
      ! zerados. As demais guardas ja' tratavam lwdn e swdn; psl nao tinha.
      ! Pressao ao nivel do mar nunca desce de ~870 hPa na natureza, entao
      ! 500 hPa e' um limiar seguro para "ausencia de dado".
      if (psl(i,j) < 5.0e4_ESMF_KIND_R8) cycle
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
    !
    ! Fase 2 (B-ICE-ALBEDO-01): o albedo efetivo de cada célula passa a ser
    ! uma média ponderada pela fração de gelo real (is%f_ifrac_atm, regrid
    ! Sprint B.2 de Si_ifrac_sis2) entre a constante de água aberta
    ! (albedo_ocn = 0,06) e o albedo real do gelo por banda vindo do SIS2
    ! (is%f_alb_*_ice, regrid de Si_a*sdr/f_sis2 — ver export_si_albedo em
    ! sis_cap_MONAN.F90). Antes desta correção, toda celula — com ou sem
    ! gelo — usava albedo_ocn = 0,06, superestimando fortemente a absorcao
    ! de SW sob gelo/neve (albedo real tipicamente 0,5-0,85).
    !==========================================================================
    block
      real(ESMF_KIND_R8), pointer :: ifr(:,:)
      real(ESMF_KIND_R8), pointer :: alb_vdr(:,:), alb_vdf(:,:)
      real(ESMF_KIND_R8), pointer :: alb_idr(:,:), alb_idf(:,:)
      real(ESMF_KIND_R8) :: alb_eff, fi
      integer :: rc_alb

      nullify(ifr, alb_vdr, alb_vdf, alb_idr, alb_idf)
      call ESMF_FieldGet(is%f_ifrac_atm,   farrayPtr=ifr,     rc=rc_alb)
      call ESMF_FieldGet(is%f_alb_vdr_ice, farrayPtr=alb_vdr, rc=rc_alb)
      call ESMF_FieldGet(is%f_alb_vdf_ice, farrayPtr=alb_vdf, rc=rc_alb)
      call ESMF_FieldGet(is%f_alb_idr_ice, farrayPtr=alb_idr, rc=rc_alb)
      call ESMF_FieldGet(is%f_alb_idf_ice, farrayPtr=alb_idf, rc=rc_alb)
      rc_alb = ESMF_SUCCESS

      if (associated(ifr) .and. associated(alb_vdr) .and. associated(alb_vdf) &
          .and. associated(alb_idr) .and. associated(alb_idf)) then

        ! Fase 4 (B-ICE-SWNET-01, Set/2026): ANTES desta correcao, Foxx_swnet_*
        ! era calculado com alb_eff (media ponderada por Si_ifrac entre
        ! albedo de agua aberta e albedo do gelo) e esse MESMO valor era
        ! enviado tanto ao MOM6 (Foxx_swnet_*) quanto ao SIS2 (que importava
        ! Foxx_swnet_* diretamente — ver sis_cap_MONAN.F90). Isso fazia o
        ! gelo absorver SW calculada com um albedo mais baixo que o seu
        ! proprio (contaminado pela agua aberta), e o oceano absorver SW
        ! calculada com um albedo mais alto que o seu proprio (contaminado
        ! pelo gelo) — dupla contabilizacao fisica incorreta em qualquer
        ! celula com 0 < Si_ifrac < 1.
        !
        ! Agora: Foxx_swnet_* usa SOMENTE o albedo de agua aberta (alb_ocn_dir
        ! nas bandas diretas, albedo_ocn nas difusas) — vai para o MOM6, que
        ! representa so' a fracao (1-Si_ifrac) da celula. Fioi_swnet_* (novo)
        ! usa SOMENTE o albedo do gelo por banda (alb_vdr/vdf/idr/idf) — vai
        ! para o SIS2 (ver mudanca em sis_cap_MONAN.F90::import_forcing).
        ! alb_eff (blend ponderado por Si_ifrac) continua sendo calculado e
        ! acumulado em is%f_albedo_atm (Sf_albedo) sem nenhuma mudanca —
        ! esse composto de banda larga PARA A ATMOSFERA continua correto e
        ! necessario (a atmosfera so' enxerga uma celula, nao duas fracoes).

        call ESMF_FieldGet(is%f_swvdr_atm, farrayPtr=fptr, rc=rc)
        block
          real(ESMF_KIND_R8), pointer :: fptr_cz(:,:) => null()
          real(ESMF_KIND_R8), pointer :: fptr_alb(:,:) => null()
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_coszen_atm, farrayPtr=fptr_cz, rc=rc)
          call ESMF_FieldGet(is%f_albedo_atm, farrayPtr=fptr_alb, rc=rc)
          call ESMF_FieldGet(is%f_swvdr_ice,  farrayPtr=fptr_ice2, rc=rc)
          do j=j1,j2; do i=i1,i2
            fi = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifr(i,j)))
            ! Fase 2.5: lat/lon analiticos da grade ATM 360x180 (mesma formula
            ! usada na criacao da grade em MED_cap.F90::InitializeRealize).
            lon_ij = (real(i,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * (360.0_ESMF_KIND_R8/NX_ATM_ZEN) &
                     + 0.5_ESMF_KIND_R8*(360.0_ESMF_KIND_R8/NX_ATM_ZEN)
            lat_ij = -90.0_ESMF_KIND_R8 + (real(j,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * (180.0_ESMF_KIND_R8/NY_ATM_ZEN) &
                     + 0.5_ESMF_KIND_R8*(180.0_ESMF_KIND_R8/NY_ATM_ZEN)
            hour_angle = (PI_ZEN/12.0_ESMF_KIND_R8) * (utc_hour + lon_ij/15.0_ESMF_KIND_R8 - 12.0_ESMF_KIND_R8)
            coszen_ij = sin(lat_ij*PI_ZEN/180.0_ESMF_KIND_R8) * sin(decl) + &
                        cos(lat_ij*PI_ZEN/180.0_ESMF_KIND_R8) * cos(decl) * cos(hour_angle)
            coszen_ij = max(0.0_ESMF_KIND_R8, coszen_ij)
            if (associated(fptr_cz)) fptr_cz(i,j) = coszen_ij
            ! Briegleb et al. (1986); clip coszen>=0.02 evita blowup perto do
            ! horizonte (celula ja recebe swdn~0 ali de qualquer forma).
            alb_ocn_dir = 0.026_ESMF_KIND_R8/(max(coszen_ij,0.02_ESMF_KIND_R8)**1.7_ESMF_KIND_R8 + 0.065_ESMF_KIND_R8) &
                        + 0.15_ESMF_KIND_R8*(max(coszen_ij,0.02_ESMF_KIND_R8)-0.1_ESMF_KIND_R8) &
                                            *(max(coszen_ij,0.02_ESMF_KIND_R8)-0.5_ESMF_KIND_R8) &
                                            *(max(coszen_ij,0.02_ESMF_KIND_R8)-1.0_ESMF_KIND_R8)
            alb_ocn_dir = max(0.03_ESMF_KIND_R8, min(0.99_ESMF_KIND_R8, alb_ocn_dir))
            ! Foxx_swnet_vdr (MOM6): SOMENTE albedo de agua aberta (Briegleb).
            fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_ocn_dir) * f_vis_dir
            ! Fioi_swnet_vdr (SIS2): SOMENTE albedo do gelo por banda.
            if (associated(fptr_ice2)) &
              fptr_ice2(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_vdr(i,j)) * f_vis_dir
            ! Sf_albedo (atmosfera): mantem o blend ponderado por Si_ifrac,
            ! inalterado — Fase 2.6.
            alb_eff = (1.0_ESMF_KIND_R8 - fi) * alb_ocn_dir + fi * alb_vdr(i,j)
            if (associated(fptr_alb)) fptr_alb(i,j) = f_vis_dir * alb_eff
          end do; end do
          rc = ESMF_SUCCESS
        end block

        call ESMF_FieldGet(is%f_swvdf_atm, farrayPtr=fptr, rc=rc)
        block
          real(ESMF_KIND_R8), pointer :: fptr_alb(:,:) => null()
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_albedo_atm, farrayPtr=fptr_alb, rc=rc)
          call ESMF_FieldGet(is%f_swvdf_ice,  farrayPtr=fptr_ice2, rc=rc)
          do j=j1,j2; do i=i1,i2
            fi = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifr(i,j)))
            ! Banda DIFUSA: mantem albedo_ocn constante (Briegleb e' so' p/ feixe direto).
            fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_vis_dif
            if (associated(fptr_ice2)) &
              fptr_ice2(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_vdf(i,j)) * f_vis_dif
            alb_eff = (1.0_ESMF_KIND_R8 - fi) * albedo_ocn + fi * alb_vdf(i,j)
            if (associated(fptr_alb)) fptr_alb(i,j) = fptr_alb(i,j) + f_vis_dif * alb_eff
          end do; end do
          rc = ESMF_SUCCESS
        end block

        call ESMF_FieldGet(is%f_swidr_atm, farrayPtr=fptr, rc=rc)
        block
          real(ESMF_KIND_R8), pointer :: fptr_alb(:,:) => null()
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_albedo_atm, farrayPtr=fptr_alb, rc=rc)
          call ESMF_FieldGet(is%f_swidr_ice,  farrayPtr=fptr_ice2, rc=rc)
          do j=j1,j2; do i=i1,i2
            fi = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifr(i,j)))
            lon_ij = (real(i,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * (360.0_ESMF_KIND_R8/NX_ATM_ZEN) &
                     + 0.5_ESMF_KIND_R8*(360.0_ESMF_KIND_R8/NX_ATM_ZEN)
            lat_ij = -90.0_ESMF_KIND_R8 + (real(j,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * (180.0_ESMF_KIND_R8/NY_ATM_ZEN) &
                     + 0.5_ESMF_KIND_R8*(180.0_ESMF_KIND_R8/NY_ATM_ZEN)
            hour_angle = (PI_ZEN/12.0_ESMF_KIND_R8) * (utc_hour + lon_ij/15.0_ESMF_KIND_R8 - 12.0_ESMF_KIND_R8)
            coszen_ij = sin(lat_ij*PI_ZEN/180.0_ESMF_KIND_R8) * sin(decl) + &
                        cos(lat_ij*PI_ZEN/180.0_ESMF_KIND_R8) * cos(decl) * cos(hour_angle)
            coszen_ij = max(0.0_ESMF_KIND_R8, coszen_ij)
            alb_ocn_dir = 0.026_ESMF_KIND_R8/(max(coszen_ij,0.02_ESMF_KIND_R8)**1.7_ESMF_KIND_R8 + 0.065_ESMF_KIND_R8) &
                        + 0.15_ESMF_KIND_R8*(max(coszen_ij,0.02_ESMF_KIND_R8)-0.1_ESMF_KIND_R8) &
                                            *(max(coszen_ij,0.02_ESMF_KIND_R8)-0.5_ESMF_KIND_R8) &
                                            *(max(coszen_ij,0.02_ESMF_KIND_R8)-1.0_ESMF_KIND_R8)
            alb_ocn_dir = max(0.03_ESMF_KIND_R8, min(0.99_ESMF_KIND_R8, alb_ocn_dir))
            fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_ocn_dir) * f_nir_dir
            if (associated(fptr_ice2)) &
              fptr_ice2(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_idr(i,j)) * f_nir_dir
            alb_eff = (1.0_ESMF_KIND_R8 - fi) * alb_ocn_dir + fi * alb_idr(i,j)
            if (associated(fptr_alb)) fptr_alb(i,j) = fptr_alb(i,j) + f_nir_dir * alb_eff
          end do; end do
          rc = ESMF_SUCCESS
        end block

        call ESMF_FieldGet(is%f_swidf_atm, farrayPtr=fptr, rc=rc)
        block
          real(ESMF_KIND_R8), pointer :: fptr_alb(:,:) => null()
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_albedo_atm, farrayPtr=fptr_alb, rc=rc)
          call ESMF_FieldGet(is%f_swidf_ice,  farrayPtr=fptr_ice2, rc=rc)
          do j=j1,j2; do i=i1,i2
            fi = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifr(i,j)))
            fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_nir_dif
            if (associated(fptr_ice2)) &
              fptr_ice2(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - alb_idf(i,j)) * f_nir_dif
            alb_eff = (1.0_ESMF_KIND_R8 - fi) * albedo_ocn + fi * alb_idf(i,j)
            ! Fase 2.6: ultima banda — fptr_alb(i,j) agora contem o albedo de
            ! banda larga efetivo completo (soma das 4 contribuicoes ponderadas).
            if (associated(fptr_alb)) fptr_alb(i,j) = fptr_alb(i,j) + f_nir_dif * alb_eff
          end do; end do
          rc = ESMF_SUCCESS
        end block

      else
        ! Fallback: campos de albedo/ifrac do gelo indisponiveis — mantem
        ! o comportamento antigo (albedo_ocn constante em toda celula) para
        ! Foxx_swnet_*, e copia o mesmo valor para Fioi_swnet_* (sem dado
        ! real de gelo, nao ha' base para calcular algo diferente).
        call ESMF_LogWrite('MED(bulk_ncar): f_ifrac_atm/f_alb_*_ice nao ' // &
          'associados — SW usa albedo_ocn constante (sem Fase 2/4)', &
          ESMF_LOGMSG_WARNING)

        call ESMF_FieldGet(is%f_swvdr_atm, farrayPtr=fptr, rc=rc)
        do j=j1,j2; do i=i1,i2
          fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_vis_dir
        end do; end do
        block
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_swvdr_ice, farrayPtr=fptr_ice2, rc=rc)
          if (associated(fptr_ice2)) fptr_ice2(i1:i2,j1:j2) = fptr(i1:i2,j1:j2)
        end block

        call ESMF_FieldGet(is%f_swvdf_atm, farrayPtr=fptr, rc=rc)
        do j=j1,j2; do i=i1,i2
          fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_vis_dif
        end do; end do
        block
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_swvdf_ice, farrayPtr=fptr_ice2, rc=rc)
          if (associated(fptr_ice2)) fptr_ice2(i1:i2,j1:j2) = fptr(i1:i2,j1:j2)
        end block

        call ESMF_FieldGet(is%f_swidr_atm, farrayPtr=fptr, rc=rc)
        do j=j1,j2; do i=i1,i2
          fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_nir_dir
        end do; end do
        block
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_swidr_ice, farrayPtr=fptr_ice2, rc=rc)
          if (associated(fptr_ice2)) fptr_ice2(i1:i2,j1:j2) = fptr(i1:i2,j1:j2)
        end block

        call ESMF_FieldGet(is%f_swidf_atm, farrayPtr=fptr, rc=rc)
        do j=j1,j2; do i=i1,i2
          fptr(i,j) = max(swdn(i,j),0.0_ESMF_KIND_R8) * (1.0_ESMF_KIND_R8 - albedo_ocn) * f_nir_dif
        end do; end do
        block
          real(ESMF_KIND_R8), pointer :: fptr_ice2(:,:) => null()
          call ESMF_FieldGet(is%f_swidf_ice, farrayPtr=fptr_ice2, rc=rc)
          if (associated(fptr_ice2)) fptr_ice2(i1:i2,j1:j2) = fptr(i1:i2,j1:j2)
        end block

        ! Fase 2.6: sem dado de gelo/zenite -- exporta a constante antiga
        ! como albedo de banda larga tambem (degrada de forma consistente).
        block
          real(ESMF_KIND_R8), pointer :: fptr_alb(:,:) => null()
          call ESMF_FieldGet(is%f_albedo_atm, farrayPtr=fptr_alb, rc=rc)
          if (associated(fptr_alb)) fptr_alb(i1:i2,j1:j2) = albedo_ocn
          rc = ESMF_SUCCESS
        end block
      end if
    end block

    !==========================================================================
    ! Fase 3 (B-ICE-FLUX-DIFF-01): fluxos Fioi_* — mesma forma bulk NCAR
    ! acima, mas usando a temperatura de pele REAL do gelo (is%f_tice_atm,
    ! regrid de Si_t_sis2) em vez de SST. Antes desta correcao, o SIS2
    ! recebia os MESMOS Foxx_* calculados com SST que o MOM6 recebe —
    ! fisicamente incorreto: a diferenca de temperatura ar-superficie sobre
    ! gelo frio pode ser MUITO maior que ar-SST (SST fica travada perto do
    ! ponto de congelamento; T_gelo pode chegar a -40 C ou mais frio).
    !
    ! Coeficientes de transferencia: reusa Cd_neut/Ch_neut/Ce_neut (mesmos
    ! da agua aberta) como base, MODULADOS por um fator de estabilidade
    ! (Louis, 1979 — "A parametric model of vertical eddy fluxes in the
    ! atmosphere", Boundary-Layer Meteorology 17, constantes b=c=d=5) —
    ! necessario porque o ar sobre gelo frio tipicamente forma uma camada
    ! ESTAVELMENTE estratificada (T_ar > T_gelo), onde a troca turbulenta
    ! REAL e' bem menor que a que os coeficientes "neutros" (calibrados
    ! para agua aberta, tipicamente proxima do neutro) preveem — sem essa
    ! correcao, FIX-DIAG-ICESTAB-01 mostrou Fioi_sen saturando repetidamente
    ! no teto de seguranca de ±500 W/m^2 em varios PETs, sinal de
    ! superestimativa sistematica, nao de evento fisico isolado.
    !
    ! Ambos os ramos de Louis (1979) estao implementados: Rib>0 (estavel,
    ! amortece) e Rib<0 (INSTAVEL — superficie mais quente que o ar, ex.
    ! polinias/gelo fino sob ar frio — REFORCA a troca turbulenta em vez de
    ! amortecer). STAB_FAC_MAX=3,0 e' um teto de seguranca numerico
    ! (nao vem do artigo original) para evitar crescimento sem limite do
    ! fator de reforco em Rib muito negativo.
    !
    ! Refinamento futuro adicional: coeficientes proprios de rugosidade de
    ! gelo (ex. Andreas et al.), ainda nao implementado.
    !
    ! Emissividade do gelo/neve (0,99) e' ligeiramente maior que a de agua
    ! aberta (0,97) usada acima — valor padrao bem estabelecido na
    ! literatura, nao e' erro de digitacao.
    block
      real(ESMF_KIND_R8), pointer :: tice(:,:) => null()
      real(ESMF_KIND_R8), pointer :: fptr_ice(:,:) => null()
      real(ESMF_KIND_R8), pointer :: ifr_g(:,:) => null()
      real(ESMF_KIND_R8), pointer :: f_taux_ocn(:,:), f_tauy_ocn(:,:)
      real(ESMF_KIND_R8), pointer :: f_sen_ocn(:,:), f_evap_ocn(:,:)
      real(ESMF_KIND_R8), pointer :: f_lwnet_ocn(:,:)
      real(ESMF_KIND_R8) :: tice_eff, qsat_ice, rib, stab_fac
      integer :: rc_ice2
      real(ESMF_KIND_R8), parameter :: Z_REF = 10.0_ESMF_KIND_R8      ! altura de referencia [m]
      real(ESMF_KIND_R8), parameter :: G_ACCEL = 9.81_ESMF_KIND_R8    ! gravidade [m/s^2]
      real(ESMF_KIND_R8), parameter :: LOUIS_B = 5.0_ESMF_KIND_R8     ! Louis (1979), caso estavel
      real(ESMF_KIND_R8), parameter :: LOUIS_C = 5.0_ESMF_KIND_R8     ! Louis (1979), caso instavel
      real(ESMF_KIND_R8), parameter :: STAB_FAC_MIN = 0.05_ESMF_KIND_R8  ! piso p/ nao zerar o fluxo
      real(ESMF_KIND_R8), parameter :: STAB_FAC_MAX = 3.0_ESMF_KIND_R8   ! teto de seguranca (nao e' do Louis original)
      ! FIX B-ICEFLUX-ARTIFACT-01: abaixo deste limiar de fracao de gelo,
      ! Si_t_sis2 e' o FALLBACK de export_si_tskin (ponto de congelamento),
      ! nao uma temperatura real. Usa-lo como se fosse T_gelo real produz
      ! um deltaT fabricado (ex.: ar polar genuino sobre agua aberta SEM
      ! gelo, deltaT de 40-50K fictício) — foi a causa da maior parte das
      ! saturacoes em FIX-DIAG-ICESTAB-01 (tice=271.4 identico em centenas
      ! de celulas). Abaixo do limiar, copia o Foxx_* (agua aberta, SST
      ! real) ja calculado acima em vez de inventar um gradiente de gelo.
      real(ESMF_KIND_R8), parameter :: IFRAC_MIN_FIOI = 1.0e-3_ESMF_KIND_R8

      call ESMF_FieldGet(is%f_tice_atm,  farrayPtr=tice,       rc=rc_ice2)
      call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=ifr_g,      rc=rc_ice2)
      call ESMF_FieldGet(is%f_taux_atm,  farrayPtr=f_taux_ocn, rc=rc_ice2)
      call ESMF_FieldGet(is%f_tauy_atm,  farrayPtr=f_tauy_ocn, rc=rc_ice2)
      call ESMF_FieldGet(is%f_sen_atm,   farrayPtr=f_sen_ocn,  rc=rc_ice2)
      call ESMF_FieldGet(is%f_evap_atm,  farrayPtr=f_evap_ocn, rc=rc_ice2)
      call ESMF_FieldGet(is%f_lwnet_atm, farrayPtr=f_lwnet_ocn, rc=rc_ice2)
      rc_ice2 = ESMF_SUCCESS

      if (associated(tice)) then

        call ESMF_FieldGet(is%f_taux_ice, farrayPtr=fptr_ice, rc=rc)
        do j=j1,j2; do i=i1,i2
          if (associated(ifr_g) .and. associated(f_taux_ocn)) then
            if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
              fptr_ice(i,j) = f_taux_ocn(i,j)
              cycle
            end if
          end if
          wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
          tice_eff = merge(tice(i,j), 271.35_ESMF_KIND_R8, &
            tice(i,j) > 180.0_ESMF_KIND_R8 .and. tice(i,j) <= 273.16_ESMF_KIND_R8)
          ! Numero de Richardson bulk; positivo = estratificacao estavel
          ! (ar mais quente que a superficie — caso tipico sobre gelo).
          rib = G_ACCEL * Z_REF * (tas(i,j) - tice_eff) / &
                (max(tas(i,j), 100.0_ESMF_KIND_R8) * wspd**2)
          if (rib > 0.0_ESMF_KIND_R8) then
            stab_fac = 1.0_ESMF_KIND_R8 / &
              (1.0_ESMF_KIND_R8 + 2.0_ESMF_KIND_R8*LOUIS_B*rib/sqrt(1.0_ESMF_KIND_R8+LOUIS_B*rib))
            stab_fac = max(STAB_FAC_MIN, min(1.0_ESMF_KIND_R8, stab_fac))
          else
            ! Louis (1979), caso instavel: turbulencia REFORCADA (nao
            ! amortecida) em relacao ao neutro — superficie mais quente
            ! que o ar gera conveccao que intensifica a troca turbulenta.
            stab_fac = 1.0_ESMF_KIND_R8 - &
              (2.0_ESMF_KIND_R8*LOUIS_B*rib) / &
              (1.0_ESMF_KIND_R8 + 3.0_ESMF_KIND_R8*LOUIS_B*LOUIS_C*sqrt(-rib))
            stab_fac = max(1.0_ESMF_KIND_R8, min(STAB_FAC_MAX, stab_fac))
          end if
          fptr_ice(i,j) = max(-5.0_ESMF_KIND_R8, min(5.0_ESMF_KIND_R8, &
            rho_air * Cd_neut * stab_fac * wspd * uas(i,j)))
        end do; end do

        call ESMF_FieldGet(is%f_tauy_ice, farrayPtr=fptr_ice, rc=rc)
        do j=j1,j2; do i=i1,i2
          if (associated(ifr_g) .and. associated(f_tauy_ocn)) then
            if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
              fptr_ice(i,j) = f_tauy_ocn(i,j)
              cycle
            end if
          end if
          wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
          tice_eff = merge(tice(i,j), 271.35_ESMF_KIND_R8, &
            tice(i,j) > 180.0_ESMF_KIND_R8 .and. tice(i,j) <= 273.16_ESMF_KIND_R8)
          rib = G_ACCEL * Z_REF * (tas(i,j) - tice_eff) / &
                (max(tas(i,j), 100.0_ESMF_KIND_R8) * wspd**2)
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
          fptr_ice(i,j) = max(-5.0_ESMF_KIND_R8, min(5.0_ESMF_KIND_R8, &
            rho_air * Cd_neut * stab_fac * wspd * vas(i,j)))
        end do; end do

        block
          real(ESMF_KIND_R8) :: raw_sen
          integer :: n_sat, i_sat, j_sat
          real(ESMF_KIND_R8) :: wspd_sat, dt_sat, raw_sat, tas_sat, tice_sat, rib_sat, stab_sat
          call ESMF_FieldGet(is%f_sen_ice, farrayPtr=fptr_ice, rc=rc)
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
            ! blindagem fisica: T_gelo em [180,273.15] K (mesma faixa validada
            ! em export_si_tskin); fora disso, cai para o ponto de
            ! congelamento (mesmo fallback usado la).
            tice_eff = merge(tice(i,j), 271.35_ESMF_KIND_R8, &
              tice(i,j) > 180.0_ESMF_KIND_R8 .and. tice(i,j) <= 273.16_ESMF_KIND_R8)
            rib = G_ACCEL * Z_REF * (tas(i,j) - tice_eff) / &
                  (max(tas(i,j), 100.0_ESMF_KIND_R8) * wspd**2)
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
            raw_sen = rho_air * Cp_air * Ch_neut * stab_fac * wspd * (tas(i,j) - tice_eff)
            ! FIX-DIAG-ICESTAB-01: rastreia saturacao no teto de seguranca
            ! ANTES do clamp, para distinguir evento fisico real (vento e/ou
            ! delta-T genuinamente extremos) de artefato numerico. Com os
            ! dois ramos de Louis (1979) + a guarda de ifrac (fix
            ! B-ICEFLUX-ARTIFACT-01), espera-se n_sat ~ 0 na maioria dos
            ! passos — se persistir, e' sinal de vento/deltaT realmente
            ! extremos (ver rib_sat/stab_sat no log para confirmar; note
            ! que stab_sat pode agora ser > 1 no ramo instavel, reforco
            ! de transporte turbulento, nao amortecimento).
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

          if (cfg_write_fixdiag .and. n_sat > 0) then
            block
              character(len=320) :: diag_msg10
              write(diag_msg10,'(A,I0,A,I0,A,I0,A,ES10.3,A,ES10.3,A,ES10.3, &
                &A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
                'FIX-DIAG-ICESTAB-01: n_saturado=', n_sat, &
                ' primeira_celula(i,j)=(', i_sat, ',', j_sat, &
                ') wspd=', wspd_sat, ' tas=', tas_sat, ' tice=', tice_sat, &
                ' deltaT=', dt_sat, ' Rib=', rib_sat, ' stab_fac=', stab_sat, &
                ' valor_bruto=', raw_sat
              call ESMF_LogWrite(trim(diag_msg10), ESMF_LOGMSG_WARNING)
            end block
          end if
        end block

        call ESMF_FieldGet(is%f_evap_ice, farrayPtr=fptr_ice, rc=rc)
        do j=j1,j2; do i=i1,i2
          if (psl(i,j) < 5.0e4_ESMF_KIND_R8) cycle
          if (associated(ifr_g) .and. associated(f_evap_ocn)) then
            if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
              fptr_ice(i,j) = f_evap_ocn(i,j)
              cycle
            end if
          end if
          wspd = sqrt(uas(i,j)**2 + vas(i,j)**2) + 1.0e-10_ESMF_KIND_R8
          tice_eff = merge(tice(i,j), 271.35_ESMF_KIND_R8, &
            tice(i,j) > 180.0_ESMF_KIND_R8 .and. tice(i,j) <= 273.16_ESMF_KIND_R8)
          ! Mesmo Rib/fator de estabilidade do calor sensivel acima —
          ! teoria de similaridade usa a MESMA funcao de estabilidade para
          ! calor e umidade (ambos escalares passivos).
          rib = G_ACCEL * Z_REF * (tas(i,j) - tice_eff) / &
                (max(tas(i,j), 100.0_ESMF_KIND_R8) * wspd**2)
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
          ! qsat sobre GELO usa a mesma formula de Clausius-Clapeyron do
          ! bulk de agua aberta acima — aproximacao (formula exata sobre
          ! gelo usa constantes ligeiramente diferentes); adequado para
          ! a precisao pretendida aqui.
          qsat_ice = eps_q * es_coef_a * &
            exp(es_coef_b*(tice_eff-T_freeze)/(tice_eff-T_freeze+es_coef_c)) / &
            max(psl(i,j), 1.0_ESMF_KIND_R8)
          fptr_ice(i,j) = max(-1.0e-4_ESMF_KIND_R8, min(1.0e-4_ESMF_KIND_R8, &
            rho_air * Ce_neut * stab_fac * wspd * (qsat_ice - shum(i,j))))
        end do; end do

        call ESMF_FieldGet(is%f_lwnet_ice, farrayPtr=fptr_ice, rc=rc)
        do j=j1,j2; do i=i1,i2
          if (lwdn(i,j) < 1.0_ESMF_KIND_R8) cycle
          if (associated(ifr_g) .and. associated(f_lwnet_ocn)) then
            if (ifr_g(i,j) < IFRAC_MIN_FIOI) then
              fptr_ice(i,j) = f_lwnet_ocn(i,j)
              cycle
            end if
          end if
          tice_eff = merge(tice(i,j), 271.35_ESMF_KIND_R8, &
            tice(i,j) > 180.0_ESMF_KIND_R8 .and. tice(i,j) <= 273.16_ESMF_KIND_R8)
          fptr_ice(i,j) = max( &
            max(lwdn(i,j), 0.0_ESMF_KIND_R8) - 0.99_ESMF_KIND_R8 * sigma_sb * tice_eff**4, &
            -300.0_ESMF_KIND_R8)
        end do; end do

        call ESMF_LogWrite('MED(Fase3-ICE): Fioi_taux/tauy/sen/evap/lwnet ' // &
          'calculados com T_gelo real (nao mais SST)', ESMF_LOGMSG_INFO)

        ! FIX-DIAG-ICEFLUX-01: validacao. Compara T_gelo vs SST e
        ! Fioi_sen vs Foxx_sen (calculado com SST, secao acima) nas MESMAS
        ! celulas. Ja validado em producao (Set/2026).
        if (cfg_write_fixdiag) then
          block
            real(ESMF_KIND_R8), pointer :: p_sen_ice(:,:), p_sen_ocn(:,:)
            real(ESMF_KIND_R8), pointer :: p_lwnet_ice(:,:)
            character(len=250) :: diag_msg9
            call ESMF_FieldGet(is%f_sen_ice,   farrayPtr=p_sen_ice,   rc=rc)
            call ESMF_FieldGet(is%f_sen_atm,   farrayPtr=p_sen_ocn,   rc=rc)
            call ESMF_FieldGet(is%f_lwnet_ice, farrayPtr=p_lwnet_ice, rc=rc)
            rc = ESMF_SUCCESS
            if (associated(p_sen_ice) .and. associated(p_sen_ocn) .and. &
                associated(p_lwnet_ice)) then
              write(diag_msg9,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
                'FIX-DIAG-ICEFLUX-01: T_gelo min=', minval(tice), ' max=', maxval(tice), &
                ' | Fioi_sen min=', minval(p_sen_ice), ' max=', maxval(p_sen_ice), &
                ' | Foxx_sen(SST) min=', minval(p_sen_ocn), ' max=', maxval(p_sen_ocn)
              call ESMF_LogWrite(trim(diag_msg9), ESMF_LOGMSG_INFO)
            end if
          end block
        end if
      else
        call ESMF_LogWrite('MED(Fase3-ICE): f_tice_atm nao associado — ' // &
          'Fioi_* permanecem no fallback inicial', ESMF_LOGMSG_WARNING)
      end if
      rc = ESMF_SUCCESS
    end block

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
      real(ESMF_KIND_R8), pointer :: p_omask_z(:,:) => null()
      real(ESMF_KIND_R8) :: tau_mag, ustar, z0_charnock, z0_smith, z0_total
      integer :: rc_z

      call ESMF_FieldGet(is%f_taux_atm, farrayPtr=p_taux, rc=rc_z)
      call ESMF_FieldGet(is%f_tauy_atm, farrayPtr=p_tauy, rc=rc_z)
      call ESMF_FieldGet(is%f_zorl_atm, farrayPtr=p_zorl, rc=rc_z)
      ! FIX B-LANDMASK-01: mascara real (So_omask regridada), nao mais
      ! heuristica de SST~=T_FILL_LAND (colidia com agua aberta genuina no
      ! ponto de congelamento, perto da borda do gelo).
      call ESMF_FieldGet(is%f_omask_atm, farrayPtr=p_omask_z, rc=rc_z)

      if (associated(p_taux) .and. associated(p_tauy) .and. associated(p_zorl)) then
        do j = j1, j2
          do i = i1, i2
            tau_mag     = sqrt(p_taux(i,j)**2 + p_tauy(i,j)**2)
            ustar       = sqrt(tau_mag / rho_air)
            ustar       = max(ustar, USTAR_MIN)
            z0_charnock = ALPHA_CHARNOCK * ustar**2 / G_GRAV
            z0_smith    = BETA_SMITH * NU_AIR / ustar
            z0_total    = max(Z0_MIN, min(Z0_MAX, z0_charnock + z0_smith))
            ! Sobre terra (mascara real So_omask, ver B-LANDMASK-01): usar default
            if (associated(p_omask_z)) then
              if (p_omask_z(i,j) < 0.5_ESMF_KIND_R8) z0_total = Z0_MIN
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
    ! FIX B-IFRAC-OVERWRITE-01 (Set/2026): todo o bloco abaixo — que le
    ! "Si_ifrac" (SEM sufixo, campo diferente de "Si_ifrac_sis2") via
    ! rh_ocn2atm generico SEM mascara, e ainda aplica a mascara SST~=
    ! T_FILL_LAND (Sprint A.5.2) que zera ifrac tambem em agua aberta
    ! genuina proxima da borda do gelo (SST no congelamento e' fisicamente
    ! esperado ali, nao e' sinal de terra) — so' deveria rodar quando NAO
    ! ha fonte melhor disponivel. Antes so' era gated por cfg_use_docn_ice;
    ! como cfg_use_docn_ice=.false. e' o estado correto agora (ver correcao
    ! do decaimento OISST artificial, Set/2026), esse bloco passou a rodar
    ! INCONDICIONALMENTE, sobrescrevendo is%f_ifrac_atm por cima do
    ! pipeline Sprint B.2/B-ICEREGRID-01..04 (mascarado, CONSERVE,
    ! extrapolacao com alcance limitado) que roda ANTES desta subrotina
    ! ser chamada (calc_bulk_ncar e' chamado depois de tudo isso em
    ! MED_cap.F90). Com cfg_use_sis2_dynamic=.true. (gelo real do SIS2
    ! ativo), o pipeline Sprint B.2 e' a fonte AUTORITATIVA -- este bloco
    ! legado deve ficar totalmente inativo nesse caso, nao so' o ramo
    ! regrid_ok=T original.
    !==========================================================================
    if (.not. cfg_use_sis2_dynamic) then
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
    end if

    rc = ESMF_SUCCESS

  end subroutine calc_bulk_ncar

end module med_bulk_ncar_mod
