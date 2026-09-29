!> @file mpas_atm_fluxes.F90
!! @brief Fluxos instantâneos de superfície do MONAN-A para o acoplamento.
!!
!! compute_instantaneous_fluxes converte os acumulados do MPAS em fluxos
!! instantâneos (diferença entre passos) e calcula a tensão do vento a partir
!! de ust e do vento relativo à corrente oceânica, nos buffers de
!! mpas_atm_state_type apontados por mpas_atm_public_type.
!!
!! Separado de mpas_atm_model.F90 sem mudar instruções (R-FASE8-02) e
!! dividido em uma rotina por grandeza (R-FASE8-10): radiação,
!! precipitação e neve, umidade a 2 m, vento a 10 m de reserva e tensão
!! do vento.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module mpas_atm_fluxes_mod

  use mpas_atm_types_mod, only : MPAS_RKIND, mpas_atm_public_type, &
                                 mpas_atm_state_type, atm_ocean_boundary_type

  implicit none
  private

  ! Densidade do ar à superfície: constante de referência para cálculo de stress.
  ! Fonte: NIST, condições padrão (1013 hPa, 15°C). Erro < 5% na prática.
  real(MPAS_RKIND), parameter, private :: RHO_AIR_SFC = 1.2_MPAS_RKIND  ! kg/m³

  ! Velocidade mínima para evitar divisão por zero no cálculo de stress
  real(MPAS_RKIND), parameter, private :: VMIN = 0.1_MPAS_RKIND   ! m/s

  public :: compute_instantaneous_fluxes

contains
  ! ============================================================================
  !> @brief Fluxos instantâneos de superfície de um intervalo de acoplamento.
  !!
  !! Chama, nesta ordem, as etapas abaixo. A ordem importa: a partição da
  !! neve usa a precipitação total recém-calculada, e a tensão do vento usa
  !! atm_public%%u10/v10, que podem apontar para os buffers preenchidos pelo
  !! vento a 10 m de reserva.
  ! ============================================================================
  subroutine compute_instantaneous_fluxes(dt_coupling, n, atm_public, atm_state, atm_bnd)
    integer, intent(in) :: dt_coupling
    integer, intent(in) :: n
    type(mpas_atm_public_type), intent(in) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(in) :: atm_bnd
    real(MPAS_RKIND) :: dt_r
    dt_r = real(dt_coupling, MPAS_RKIND)

    call radiation_rates(dt_r, n, atm_state)
    call precipitation_rates(dt_r, n, atm_public, atm_state)
    call humidity_2m(n, atm_public, atm_state)
    call wind_10m_fallback(n, atm_state)
    call surface_stress(n, atm_public, atm_state, atm_bnd)

  end subroutine compute_instantaneous_fluxes

  ! ============================================================================
  !> @brief Radiação de onda curta e longa descendente: incremento dos
  !! acumulados do MPAS dividido pelo intervalo, em W/m2.
  ! ============================================================================
  subroutine radiation_rates(dt_r, n, atm_state)
    real(MPAS_RKIND), intent(in) :: dt_r
    integer, intent(in) :: n
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    integer          :: k

    ! ── SW e LW descendentes: incremento ÷ dt → W/m² ─────────────
    if (associated(atm_state%pool_acswdnb)) then
      do k = 1, n
        atm_state%swdn_inst(k) = max((atm_state%pool_acswdnb(k) - atm_state%prev_acswdnb(k)) / dt_r, &
                             0.0_MPAS_RKIND)
      end do
      atm_state%prev_acswdnb(1:n) = atm_state%pool_acswdnb(1:n)
    end if

    if (associated(atm_state%pool_aclwdnb)) then
      do k = 1, n
        atm_state%lwdn_inst(k) = max((atm_state%pool_aclwdnb(k) - atm_state%prev_aclwdnb(k)) / dt_r, &
                             0.0_MPAS_RKIND)
      end do
      atm_state%prev_aclwdnb(1:n) = atm_state%pool_aclwdnb(1:n)
    end if

  end subroutine radiation_rates

  ! ============================================================================
  !> @brief Precipitação total (rainnc + rainc) e sua partição em chuva e
  !! neve, a partir dos acumulados do MPAS, em kg/m2/s.
  ! ============================================================================
  subroutine precipitation_rates(dt_r, n, atm_public, atm_state)
    real(MPAS_RKIND), intent(in) :: dt_r
    integer, intent(in) :: n
    type(mpas_atm_public_type), intent(in) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    real(MPAS_RKIND) :: precip_now
    integer          :: k
    real(MPAS_RKIND), parameter :: T_FREEZE = 273.15_MPAS_RKIND
    real(MPAS_RKIND) :: snow_now
    real(MPAS_RKIND) :: delta_snow
    real(MPAS_RKIND) :: delta_total

    ! ── Precipitação total: (rainnc + rainc) incremento ÷ dt ──────
    ! rainnc [mm] = precipitação estratiforme acumulada
    ! rainc  [mm] = precipitação convectiva acumulada (esquema GF/KF)
    ! 1 mm = 1 kg/m² → taxa = Δmm / dt [kg/m²/s]
    do k = 1, n
      precip_now = 0.0_MPAS_RKIND
      if (associated(atm_state%pool_rainnc)) precip_now = precip_now + atm_state%pool_rainnc(k)
      if (associated(atm_state%pool_rainc))  precip_now = precip_now + atm_state%pool_rainc(k)
      atm_state%prec_inst(k) = max((precip_now - atm_state%prev_precip(k)) / dt_r, &
                            0.0_MPAS_RKIND)
    end do
    ! Atualizar acumulado anterior
    do k = 1, n
      atm_state%prev_precip(k) = 0.0_MPAS_RKIND
      if (associated(atm_state%pool_rainnc)) atm_state%prev_precip(k) = atm_state%prev_precip(k) + atm_state%pool_rainnc(k)
      if (associated(atm_state%pool_rainc))  atm_state%prev_precip(k) = atm_state%prev_precip(k) + atm_state%pool_rainc(k)
    end do

    ! ── Precipitação sólida (neve): snownc incremento ÷ dt ────────
    ! snownc [mm] = neve estratiforme acumulada (subconjunto de rainnc)
    ! Se snownc não estiver disponível, usa partição por temperatura:
    !   T < T_FREEZE → tudo neve; caso contrário → tudo chuva
      do k = 1, n
        delta_total = atm_state%prec_inst(k)
        if (associated(atm_state%pool_snownc)) then
          snow_now = atm_state%pool_snownc(k)
          delta_snow = max((snow_now - atm_state%prev_snow(k)) / dt_r, 0.0_MPAS_RKIND)
          atm_state%prec_snow_buf(k) = min(delta_snow, delta_total)
          atm_state%prec_rain_buf(k) = max(delta_total - atm_state%prec_snow_buf(k), 0.0_MPAS_RKIND)
        else if (associated(atm_public%t2m)) then
          ! Fallback: partição por temperatura
          if (atm_public%t2m(k) < T_FREEZE) then
            atm_state%prec_snow_buf(k) = delta_total
            atm_state%prec_rain_buf(k) = 0.0_MPAS_RKIND
          else
            atm_state%prec_snow_buf(k) = 0.0_MPAS_RKIND
            atm_state%prec_rain_buf(k) = delta_total
          end if
        else
          atm_state%prec_rain_buf(k) = delta_total
          atm_state%prec_snow_buf(k) = 0.0_MPAS_RKIND
        end if
      end do
      ! Atualizar acumulado anterior de neve
      if (associated(atm_state%pool_snownc)) then
        atm_state%prev_snow(1:n) = atm_state%pool_snownc(1:n)
      end if

  end subroutine precipitation_rates

  ! ============================================================================
  !> @brief Umidade específica a 2 m: q2 do MPAS ou, na falta dele, 80% da
  !! umidade de saturação em T2m (Tetens).
  ! ============================================================================
  subroutine humidity_2m(n, atm_public, atm_state)
    integer, intent(in) :: n
    type(mpas_atm_public_type), intent(in) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    integer          :: k
    real(MPAS_RKIND) :: es
    real(MPAS_RKIND) :: qs
    real(MPAS_RKIND), parameter :: es0 = 611.2_MPAS_RKIND
    real(MPAS_RKIND), parameter :: a = 17.67_MPAS_RKIND
    real(MPAS_RKIND), parameter :: b = 243.5_MPAS_RKIND
    real(MPAS_RKIND), parameter :: eps = 0.622_MPAS_RKIND
    real(MPAS_RKIND), parameter :: p0 = 101325.0_MPAS_RKIND

    ! ── Umidade específica a 2m: q2 [kg/kg] ───────────────────────
    ! atm_state%pool_q2 é ponteiro direto para o pool — sem buffer de incremento.
    ! Valor instantâneo → válido para o instante corrente.
    if (associated(atm_state%pool_q2)) then
      atm_state%q2m_buf(1:n) = atm_state%pool_q2(1:n)
    else if (associated(atm_public%t2m)) then
      ! Fallback: umidade de saturação em T2m (Tetens) × RH=0.8
        do k = 1, n
          es = es0 * exp(a*(atm_public%t2m(k)-273.15_MPAS_RKIND) / &
                         (b + atm_public%t2m(k)-273.15_MPAS_RKIND))
          qs = eps * es / (p0 - es)
          atm_state%q2m_buf(k) = 0.8_MPAS_RKIND * qs   ! RH=80% como fallback
        end do
    end if

  end subroutine humidity_2m

  ! ============================================================================
  !> @brief Vento a 10 m de reserva, por perfil logarítmico neutro a partir
  !! do nível mais baixo do modelo, quando u10/v10 não vêm do pool.
  ! ============================================================================
  subroutine wind_10m_fallback(n, atm_state)
    integer, intent(in) :: n
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    integer          :: k
    real(MPAS_RKIND) :: z_sfc
    real(MPAS_RKIND) :: scale_fac
    real(MPAS_RKIND), parameter :: Z10 = 10.0_MPAS_RKIND
    real(MPAS_RKIND), parameter :: Z0 = 0.001_MPAS_RKIND
    real(MPAS_RKIND), parameter :: Z_SFC_DEFAULT = 30.0_MPAS_RKIND
    integer :: nv

    ! ── fallback: calcular u10/v10 por perfil log. neutro ────
    ! Ativo quando u10/v10 nao estao no pool (bl_mynn_in/bl_ysu_in=F).
    ! atm_state%u10_buf/atm_state%v10_buf sao alocados em mpas_atm_init se atm_state%pool_uZonal disponivel.
    ! u10 = u_sfc × ln(10/z0) / ln(z_sfc/z0)
    ! z_sfc: altura do centro do nivel 1 obtida de zgrid(1,:) - zgrid(0,:)/2
    ! z0 = 0.001 m (rugosidade oceano aberto, neutro)
    if (allocated(atm_state%u10_buf) .and. allocated(atm_state%v10_buf) .and. &
        associated(atm_state%pool_uZonal) .and. associated(atm_state%pool_vMerid)) then
        nv = size(atm_state%pool_uZonal, 1)  ! número de níveis verticais
        do k = 1, n
          ! Altura do centro do nível 1 a partir de zgrid (se disponível)
          if (associated(atm_state%pool_zgrid) .and. size(atm_state%pool_zgrid,1) > 1) then
            ! zgrid(1,k) = base do nível 1; (1,k)+(2,k))/2 = centro
            z_sfc = 0.5_MPAS_RKIND * (atm_state%pool_zgrid(1,k) + atm_state%pool_zgrid(2,k))
          else
            z_sfc = Z_SFC_DEFAULT
          end if
          z_sfc = max(z_sfc, 2.0_MPAS_RKIND)  ! mínimo 2 m
          ! Fator de perfil logarítmico neutro
          scale_fac = log(Z10 / Z0) / log(z_sfc / Z0)
          ! u10 = u_sfc × fator (nível 1 do MPAS = índice nv — top-down storage)
          ! O MPAS armazena nVertLevels de cima para baixo: nível 1 = topo, nv = superfície
          atm_state%u10_buf(k) = atm_state%pool_uZonal(nv, k) * scale_fac
          atm_state%v10_buf(k) = atm_state%pool_vMerid(nv, k) * scale_fac
        end do
    end if

  end subroutine wind_10m_fallback

  ! ============================================================================
  !> @brief Tensão do vento na superfície a partir de ust e do vento a 10 m
  !! relativo à corrente oceânica.
  ! ============================================================================
  subroutine surface_stress(n, atm_public, atm_state, atm_bnd)
    integer, intent(in) :: n
    type(mpas_atm_public_type), intent(in) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(in) :: atm_bnd
    integer          :: k
    real(MPAS_RKIND) :: u_rel
    real(MPAS_RKIND) :: v_rel
    real(MPAS_RKIND) :: spd_rel
    logical :: have_currents

    ! ── Stress superficial: τ = ρ · ust² · V_rel / |V_rel| ─────────────
    !
    ! Antes: τx = ρ · ust² · u10 / |V10|  (vento absoluto)
    ! Agora: τx = ρ · ust² · u_rel / |V_rel|  (vento relativo ao oceano)
    !
    ! Vento relativo: V_rel = V_atm − V_ocn (Bryan et al. 2010, JC)
    ! Esta é a formulação fisicamente consistente: o oceano sente apenas
    ! o cisalhamento devido ao movimento relativo. Importante em correntes
    ! fortes (Kuroshio, Gulf Stream, Brasil, Agulhas, ACC, ENSO/MJO).
    !
    ! Sobre regiões continentais: atm_bnd%uocn/vocn=0 (mascara MED),
    ! recuperando exatamente a formulação original (V_rel = V_atm).
    !
    ! Direcao positiva: eastward (taux>0 quando V_rel vai para leste).
    ! Fórmula de Monin-Obukhov: CD = (ust/|V_rel|)²
    if (associated(atm_state%pool_ust) .and. &
        associated(atm_public%u10) .and. associated(atm_public%v10)) then
        have_currents = allocated(atm_bnd%uocn) .and. allocated(atm_bnd%vocn)
        do k = 1, n
          if (have_currents) then
            u_rel = atm_public%u10(k) - atm_bnd%uocn(k)
            v_rel = atm_public%v10(k) - atm_bnd%vocn(k)
          else
            u_rel = atm_public%u10(k)
            v_rel = atm_public%v10(k)
          end if
          spd_rel = sqrt(u_rel**2 + v_rel**2)
          spd_rel = max(spd_rel, VMIN)
          atm_state%taux_buf(k) = RHO_AIR_SFC * atm_state%pool_ust(k)**2 * u_rel / spd_rel
          atm_state%tauy_buf(k) = RHO_AIR_SFC * atm_state%pool_ust(k)**2 * v_rel / spd_rel
        end do
    end if

  end subroutine surface_stress

end module mpas_atm_fluxes_mod
