!> @file med_flux.F90
!! @brief Forçante atmosférica e fluxos do mediador.
!!
!! Leitura dos campos da atmosfera (MPAS ou DATM), recolhimento na grade ATM
!! interna, substituição pelos fluxos nativos do MONAN-A e zeragem dos
!! fluxos do mediador.
!!
!! Separado de MED_cap.F90 sem mudar instruções (R-FASE8-01).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_flux_mod
  use ESMF
  use mpi
  use coupler_constants_mod, only: ATM_NX, ATM_NY
  use coupler_config_mod, only: cfg_use_docn_ice, cfg_docn_ice_init_only
  use med_cap_types_mod, only: MED_InternalState, L_evap, SHUM_OCEAN_DEFAULT
  use med_cap_methods_mod, only: ZeroInternalField, GetFieldPtr, GetFieldPtrOptional
  use med_diag_mod, only: log_atm_forcing_summary

  implicit none
  private

  public :: get_atm_forcing
  public :: gather_atm_forcing
  public :: local_atm_bounds
  public :: apply_native_fluxes
  public :: zero_med_fluxes

contains

  !============================================================================
  !> @brief Ponteiros dos forcantes atmosfericos: MPAS (primario) ou DATM.
  !!
  !! Obtem do importState os campos do MPAS (7 obrigatorios, umidade e neve opcionais e 4
  !! fluxos nativos opcionais). Sem os obrigatorios, e com use_mpas_atm
  !! falso, usa os campos do DATM. Os ponteiros de saida apontam para os
  !! dados do importState ou, para shum e snow ausentes, para shum_local e
  !! snow_local, alocados aqui com os valores padrao.
  !!
  !! @param[in]    is          estado interno (use_mpas_atm)
  !! @param[in]    importState estado de importacao do mediador
  !! @param[inout] uas..snow   forcantes na grade ATM local
  !! @param[inout] shum_local, snow_local  valores padrao, se alocados
  !! @param[inout] sen_mpas, lat_mpas, taux_mpas, tauy_mpas  fluxos nativos
  !! @param[out]   proceed     .false. quando MediatorAdvance deve retornar
  !! @param[inout] rc          codigo de retorno ESMF
  !============================================================================
  subroutine get_atm_forcing(is, importState, uas, vas, tas, shum, psl, swdn, lwdn, &
                             rain, snow, shum_local, snow_local,                     &
                             sen_mpas, lat_mpas, taux_mpas, tauy_mpas, proceed, rc)
    type(MED_InternalState),     intent(in)    :: is
    type(ESMF_State),            intent(in)    :: importState
    real(ESMF_KIND_R8), pointer, intent(inout) :: uas(:,:), vas(:,:), tas(:,:), shum(:,:)
    real(ESMF_KIND_R8), pointer, intent(inout) :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8), pointer, intent(inout) :: rain(:,:), snow(:,:)
    real(ESMF_KIND_R8), pointer, intent(inout) :: shum_local(:,:), snow_local(:,:)
    real(ESMF_KIND_R8), pointer, intent(inout) :: sen_mpas(:,:), lat_mpas(:,:)
    real(ESMF_KIND_R8), pointer, intent(inout) :: taux_mpas(:,:), tauy_mpas(:,:)
    logical,                     intent(out)   :: proceed
    integer,                     intent(inout) :: rc

    ! Campos do MPAS (primario)
    real(ESMF_KIND_R8), pointer :: uas_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: vas_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: tas_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: shum_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: psl_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: swdn_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: lwdn_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: rain_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: snow_mpas(:,:) => null()
    logical :: mpas_available
    integer :: i1_glob, i2_glob, j1_glob, j2_glob   ! limites de Sa_u10m_mpas

    ! Campos do DATM (fallback)
    real(ESMF_KIND_R8), pointer :: uas_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: vas_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: tas_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: shum_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: psl_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: swdn_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: lwdn_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: rain_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: snow_datm(:,:) => null()

    proceed = .false.

    !==========================================================================
    ! 1. TENTAR OBTER CAMPOS DO MPAS (PRIMARIO)
    !==========================================================================
    ! use_mpas_atm vem do atributo NUOPC definido em esm.F90.
    ! Se false, pula a tentativa e vai direto ao DATM.
    mpas_available = is%use_mpas_atm

    !--------------------------------------------------------------------------
    ! 1a. CAMPOS OBRIGATORIOS DO MPAS (7 campos do EXP_NAMES do cap MPAS)
    !--------------------------------------------------------------------------
    i1_glob = 1; i2_glob = 1; j1_glob = 1; j2_glob = 1  ! defaults
    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Sa_u10m_mpas", uas_mpas, rc)
      if (rc /= ESMF_SUCCESS) then
        mpas_available = .false.
      else
        i1_glob = lbound(uas_mpas,1); i2_glob = ubound(uas_mpas,1)
        j1_glob = lbound(uas_mpas,2); j2_glob = ubound(uas_mpas,2)
      end if
    end if

    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Sa_v10m_mpas",   vas_mpas,  rc)
      call GetFieldPtrOptional(importState, "Sa_tbot_mpas",   tas_mpas,  rc)
      call GetFieldPtrOptional(importState, "Sa_pslv_mpas",   psl_mpas,  rc)
      call GetFieldPtrOptional(importState, "Faxa_swdn_mpas", swdn_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_lwdn_mpas", lwdn_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_rain_mpas", rain_mpas, rc)

      ! Verificar apenas os 7 campos obrigatorios
      if (.not. (associated(uas_mpas)  .and. associated(vas_mpas)  .and. &
                 associated(tas_mpas)  .and. associated(psl_mpas)  .and. &
                 associated(swdn_mpas) .and. associated(lwdn_mpas) .and. &
                 associated(rain_mpas))) then
        mpas_available = .false.
      end if
    end if

    !--------------------------------------------------------------------------
    ! 1b. CAMPOS OPCIONAIS DE UMIDADE E NEVE (Sa_shum_mpas, Faxa_snow_mpas)
    !     Na ausencia, usar valores padrao fisicos.
    !--------------------------------------------------------------------------
    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Sa_shum_mpas",   shum_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_snow_mpas", snow_mpas, rc)
      ! rc pode ser ESMF_FAILURE se os campos opcionais estiverem ausentes — nao e erro
    end if

    !--------------------------------------------------------------------------
    ! 1c. CAMPOS OPCIONAIS — fluxos nativos do PBL do MONAN-A.
    !     Ausencia (modo DATM, ou cap MPAS sem esses campos) NAO desabilita
    !     mpas_available; apenas mantem sen/evap/taux/tauy vindos do bulk
    !     NCAR (calc_bulk_ncar) mais abaixo.
    !--------------------------------------------------------------------------
    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Faxa_sen_mpas",  sen_mpas,  rc)
      call GetFieldPtrOptional(importState, "Faxa_lat_mpas",  lat_mpas,  rc)
      call GetFieldPtrOptional(importState, "Faxa_taux_mpas", taux_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_tauy_mpas", tauy_mpas, rc)
    end if

    !==========================================================================
    ! 2. SE MPAS NAO DISPONIVEL E use_mpas_atm=false: USAR DATM (FALLBACK)
    !    SE use_mpas_atm=true mas campos obrigatorios ausentes: verificar se
    !    é PET sem DE local na grade MPAS (caso normal) ou erro real.
    !==========================================================================
    if (.not. mpas_available) then
      if (is%use_mpas_atm) then
        ! PETs sem DE local na grade MPAS nao tem dados locais dos campos MPAS, e
        ! GetFieldPtrOptional devolve mpas_available=false para eles, o que e'
        ! normal. Retorno silencioso (rc=SUCCESS): o calculo bulk e' local, e
        ! esses PETs simplesmente nao contribuem para os campos internos.
        call ESMF_LogWrite('MED: PET sem dados MPAS locais — skip bulk (B-45)', &
          ESMF_LOGMSG_INFO)
        rc = ESMF_SUCCESS; return
      end if
      ! DATM fallback (apenas quando use_mpas_atm=false)
      call GetFieldPtr(importState, "Sa_u10m",   uas_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_v10m",   vas_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_tbot",   tas_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_shum",   shum_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_pslv",   psl_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_swdn", swdn_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_lwdn", lwdn_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_rain", rain_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_snow", snow_datm, rc); if (rc/=ESMF_SUCCESS) return

      uas  => uas_datm;  vas  => vas_datm;  tas  => tas_datm
      shum => shum_datm; psl  => psl_datm;  swdn => swdn_datm
      lwdn => lwdn_datm; rain => rain_datm; snow => snow_datm

      call ESMF_LogWrite('MED: Usando DATM (JRA55) como fonte atmosferica (fallback)', &
        ESMF_LOGMSG_INFO)
    else
      uas  => uas_mpas;  vas  => vas_mpas;  tas  => tas_mpas
      psl  => psl_mpas;  swdn => swdn_mpas; lwdn => lwdn_mpas
      rain => rain_mpas

      ! shum opcional — usar SHUM_OCEAN_DEFAULT quando ausente
      if (associated(shum_mpas)) then
        shum => shum_mpas
      else
        allocate(shum_local(i1_glob:i2_glob, j1_glob:j2_glob))
        shum_local = SHUM_OCEAN_DEFAULT
        shum => shum_local
        call ESMF_LogWrite('MED: Sa_shum_mpas ausente (Fase 2) ' &
          //'-- usando SHUM_DEFAULT=0.010 kg/kg', ESMF_LOGMSG_INFO)
      end if

      ! snow opcional — zero quando ausente
      if (associated(snow_mpas)) then
        snow => snow_mpas
      else
        allocate(snow_local(i1_glob:i2_glob, j1_glob:j2_glob))
        snow_local = 0.0_ESMF_KIND_R8
        snow => snow_local
        call ESMF_LogWrite('MED: Faxa_snow_mpas ausente (Fase 2) ' &
          //'-- precipitacao solida = 0.0', ESMF_LOGMSG_INFO)
      end if

      call ESMF_LogWrite('MED: Usando MPAS como fonte atmosferica primaria', &
        ESMF_LOGMSG_INFO)
    end if
    proceed = .true.
  end subroutine get_atm_forcing

  !============================================================================
  !> @brief Reune os forcantes atmosfericos na grade ATM global, em todos os PETs.
  !!
  !! O MPAS-A roda apenas num subconjunto dos PETs do MED. Em PETs onde
  !! MPAS não roda, os campos uas, vas, tas, psl, swdn, lwdn, rain, shum,
  !! snow têm fptr=0.0 (do mpas_cap_methods:state_set_field_1d que zera o
  !! domínio local antes de preencher apenas células Voronoi locais).
  !! Logo, do globo (360x180=64800 células), apenas a fração coberta por
  !! PETs com tile MPAS+MED recebe dado real; o resto fica zero.
  !!
  !! Por isso cada campo e montado num array GLOBAL (1:ATM_NX, 1:ATM_NY),
  !! reunido por MPI_Allreduce(SUM) sobre tiles disjuntos (ver
  !! allreduce_atm_tile), na ordem uas, vas, tas, psl, swdn, lwdn, rain, shum,
  !! snow. Onde shum_g ficou sem dado (<= 0), vale SHUM_OCEAN_DEFAULT.
  !!
  !! @param[in]  uas..snow        forcantes na grade ATM local
  !! @param[in]  i1, i2, j1, j2   limites locais dos forcantes
  !! @param[in]  comm             comunicador MPI do mediador
  !! @param[out] uas_g..snow_g    forcantes na grade ATM global
  !! @param[inout] first_summary  .true. até o resumo dos forçantes ser registrado
  !! @param[inout] rc             codigo de retorno (log_atm_forcing_summary)
  !============================================================================
  subroutine gather_atm_forcing(uas, vas, tas, psl, swdn, lwdn, rain, shum, snow, &
                                i1, i2, j1, j2, comm,                              &
                                uas_g, vas_g, tas_g, psl_g, swdn_g, lwdn_g,        &
                                rain_g, shum_g, snow_g, first_summary, rc)
    real(ESMF_KIND_R8), pointer, intent(in) :: uas(:,:), vas(:,:), tas(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: rain(:,:), shum(:,:), snow(:,:)
    integer,            intent(in)  :: i1, i2, j1, j2
    integer,            intent(in)  :: comm
    real(ESMF_KIND_R8), allocatable, intent(out) :: uas_g(:,:), vas_g(:,:), tas_g(:,:)
    real(ESMF_KIND_R8), allocatable, intent(out) :: psl_g(:,:), swdn_g(:,:), lwdn_g(:,:)
    real(ESMF_KIND_R8), allocatable, intent(out) :: rain_g(:,:), shum_g(:,:), snow_g(:,:)
    logical,            intent(inout) :: first_summary
    integer,            intent(inout) :: rc

    real(ESMF_KIND_R8), allocatable :: tmp_local(:,:)

    allocate(uas_g(ATM_NX,ATM_NY),  vas_g(ATM_NX,ATM_NY),  tas_g(ATM_NX,ATM_NY))
    allocate(psl_g(ATM_NX,ATM_NY),  swdn_g(ATM_NX,ATM_NY), lwdn_g(ATM_NX,ATM_NY))
    allocate(rain_g(ATM_NX,ATM_NY), shum_g(ATM_NX,ATM_NY), snow_g(ATM_NX,ATM_NY))
    allocate(tmp_local(ATM_NX,ATM_NY))

    call allreduce_atm_tile(uas,  i1, i2, j1, j2, comm, tmp_local, uas_g)
    call allreduce_atm_tile(vas,  i1, i2, j1, j2, comm, tmp_local, vas_g)
    call allreduce_atm_tile(tas,  i1, i2, j1, j2, comm, tmp_local, tas_g)
    call allreduce_atm_tile(psl,  i1, i2, j1, j2, comm, tmp_local, psl_g)
    call allreduce_atm_tile(swdn, i1, i2, j1, j2, comm, tmp_local, swdn_g)
    call allreduce_atm_tile(lwdn, i1, i2, j1, j2, comm, tmp_local, lwdn_g)
    call allreduce_atm_tile(rain, i1, i2, j1, j2, comm, tmp_local, rain_g)
    call allreduce_atm_tile(shum, i1, i2, j1, j2, comm, tmp_local, shum_g)
    ! Onde shum_g=0 (não preenchido) e shum tem fallback, usar SHUM_OCEAN_DEFAULT
    where (shum_g <= 0.0_ESMF_KIND_R8) shum_g = SHUM_OCEAN_DEFAULT
    call allreduce_atm_tile(snow, i1, i2, j1, j2, comm, tmp_local, snow_g)

    ! DIAGNÓSTICO vai para stdout (= esmApp_run.log).
    ! Espera-se n_nz_uas > 30000 de 64800 celulas (cobertura global).
    call log_atm_forcing_summary(uas_g, tas_g, psl_g, swdn_g, vas_g, shum_g, rain_g, lwdn_g, &
                                 first_summary, rc)

    deallocate(tmp_local)
  end subroutine gather_atm_forcing

  !============================================================================
  !> @brief Reune um campo da grade ATM por MPI_Allreduce(SUM) sobre tiles disjuntos.
  !!
  !! uas e outros campos podem ser negativos, entao MAX nao serve. Cada PET
  !! escreve seu tile num buffer global zerado; com tiles disjuntos, a soma
  !! entre PETs e o proprio campo global.
  !!
  !! @param[in]  src        campo na grade ATM local (limites preservados)
  !! @param[in]  i1, i2, j1, j2  limites locais do tile
  !! @param[in]  comm       comunicador MPI do mediador
  !! @param[out] tmp_local  buffer de trabalho (1:ATM_NX, 1:ATM_NY)
  !! @param[out] dst        campo global (1:ATM_NX, 1:ATM_NY)
  !============================================================================
  subroutine allreduce_atm_tile(src, i1, i2, j1, j2, comm, tmp_local, dst)
    real(ESMF_KIND_R8), pointer, intent(in) :: src(:,:)
    integer,            intent(in)  :: i1, i2, j1, j2
    integer,            intent(in)  :: comm
    real(ESMF_KIND_R8), intent(out) :: tmp_local(ATM_NX, ATM_NY)
    real(ESMF_KIND_R8), intent(out) :: dst(ATM_NX, ATM_NY)

    integer :: gi, gj, mpi_ierr_g

    tmp_local = 0.0_ESMF_KIND_R8
    do gj=j1,j2; do gi=i1,i2
      if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = src(gi,gj)
    end do; end do
    call MPI_Allreduce(tmp_local, dst, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, comm, mpi_ierr_g)
  end subroutine allreduce_atm_tile

  !============================================================================
  !> @brief Limites locais da DE dos campos internos, restritos a grade ATM global.
  !!
  !! Obtidos de is%ocn_flx%taux (mesma decomposicao para todos os campos
  !! internos). Em PET sem DE local, limites vazios: os laces nao executam.
  !!
  !! @param[in]    is              estado interno do mediador
  !! @param[out]   i1, i2, j1, j2  limites locais
  !! @param[inout] rc              codigo de retorno do ESMF_FieldGet
  !============================================================================
  subroutine local_atm_bounds(is, i1, i2, j1, j2, rc)
    type(MED_InternalState), intent(in)    :: is
    integer,                 intent(out)   :: i1, i2, j1, j2
    integer,                 intent(inout) :: rc

    real(ESMF_KIND_R8), pointer :: fpt_probe(:,:)

    nullify(fpt_probe)
    call ESMF_FieldGet(is%ocn_flx%taux, farrayPtr=fpt_probe, rc=rc)
    if (rc == ESMF_SUCCESS .and. associated(fpt_probe)) then
      i1 = lbound(fpt_probe,1); i2 = ubound(fpt_probe,1)
      j1 = lbound(fpt_probe,2); j2 = ubound(fpt_probe,2)
      ! Clampar aos limites globais (1..NX_G, 1..NY_G) para evitar acesso
      ! a uas_g fora dos bounds alocados.
      i1 = max(1, i1); i2 = min(ATM_NX, i2)
      j1 = max(1, j1); j2 = min(ATM_NY, j2)
    else
      ! PET sem DE local — bounds vazios → loops não executam
      i1 = 1; i2 = 0
      j1 = 1; j2 = 0
    end if
  end subroutine local_atm_bounds

  !============================================================================
  !> @brief Fluxos nativos do MONAN-A no lugar dos do bulk NCAR.
  !!
  !! 4b. SUBSTITUIR sen/evap/taux/tauy BULK PELOS FLUXOS NATIVOS DO
  !!     MONAN-A (Faxa_sen_mpas, Faxa_lat_mpas, Faxa_taux_mpas,
  !!     Faxa_tauy_mpas), onde disponiveis. calc_bulk_ncar acima continua
  !!     sendo a fonte para celulas/execucoes sem esses campos (ex. DATM).
  !!
  !! Motivacao: o MONAN-A ja fecha seu proprio balanco de PBL usando
  !! hfx/lh/ust internos (ver mpas_atm_model.F90/mpas_cap_methods.F90).
  !! Deixar o MED recalcular via bulk NCAR a partir de T/q/vento de 10 m
  !! produz um fluxo DIFERENTE do que a atmosfera usou internamente —
  !! inconsistencia entre o balanco de energia do MONAN-A e o forcante
  !! entregue ao MOM6/SIS2.
  !!
  !! CONFIRMADO: sinal de hfx/lh e' POSITIVO PARA CIMA (convencao
  !!  usual WRF/MPAS/GFS), verificado com a equipe de fisica do MONAN-A —
  !!  por isso invertido (-sen_g2, -lat_g2) abaixo, para bater com a
  !!  convencao Foxx_sen/Foxx_evap (positivo = aquece o oceano). Este item
  !!  NAO se aplica a Fioi_sen/Fioi_evap (fluxos do gelo, calculados a
  !!  parte em med_bulk_ncar.F90 com T_gelo, nao com hfx/lh nativos) — ver
  !!  sis_cap_MONAN.F90 para o sinal desses.
  !!  1) Sinal de hfx/lh: POSITIVO PARA CIMA (convencao
  !!     usual WRF/MPAS/GFS), por isso invertido (-sen_g2, -lat_g2) para
  !!     bater com a convencao Foxx_sen/Foxx_evap (positivo = aquece o
  !!     oceano).
  !!  2) taux_sfc/tauy_sfc (de mpas_atm_model.F90) usam a mesma forma
  !!     rho*Cd*|V|*V do bulk NCAR — nao invertidos aqui, mas confirme
  !!     que a rotacao de referencial (Terra vs. grade) ja e tratada
  !!     antes de exportar (deve ser, pois MPAS ja roda em lat/lon).
  !!  3) Faxa_lat_mpas vem em W/m^2 (energia); Foxx_evap e fluxo de MASSA
  !!     (kg/m^2/s) — por isso a divisao por L_evap abaixo.
  !!
  !! @param[in]    is          estado interno do mediador
  !! @param[in]    sen_mpas, lat_mpas, taux_mpas, tauy_mpas  fluxos nativos
  !! @param[inout] rc          codigo de retorno
  !============================================================================
  subroutine apply_native_fluxes(is, sen_mpas, lat_mpas, taux_mpas, tauy_mpas, rc)
    type(MED_InternalState), pointer, intent(in) :: is
    real(ESMF_KIND_R8), pointer, intent(in) :: sen_mpas(:,:), lat_mpas(:,:)
    real(ESMF_KIND_R8), pointer, intent(in) :: taux_mpas(:,:), tauy_mpas(:,:)
    integer,                 intent(inout) :: rc

    if (associated(sen_mpas) .and. associated(lat_mpas) .and. &
        associated(taux_mpas) .and. associated(tauy_mpas)) then
      call substitute_native_fluxes(is, sen_mpas, lat_mpas, taux_mpas, tauy_mpas, rc)
      call ESMF_LogWrite( &
        'MED(Fase3): fluxos nativos MONAN-A (sen/evap/taux/tauy) aplicados ' // &
        'sobre o resultado do bulk NCAR', ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite( &
        'MED(Fase3): Faxa_sen/lat/taux/tauy_mpas ausentes -- mantendo bulk ' // &
        'NCAR (calc_bulk_ncar) para sen/evap/taux/tauy', ESMF_LOGMSG_INFO)
    end if
  end subroutine apply_native_fluxes

  subroutine substitute_native_fluxes(is, sen_mpas, lat_mpas, taux_mpas, tauy_mpas, rc)
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: sen_mpas(:,:)
    real(ESMF_KIND_R8), pointer :: lat_mpas(:,:)
    real(ESMF_KIND_R8), pointer :: taux_mpas(:,:)
    real(ESMF_KIND_R8), pointer :: tauy_mpas(:,:)
    real(ESMF_KIND_R8), allocatable :: sen_g2(:,:), lat_g2(:,:)
    real(ESMF_KIND_R8), allocatable :: taux_g2(:,:), tauy_g2(:,:), tmp2(:,:)
    real(ESMF_KIND_R8), pointer     :: fptr_sen(:,:), fptr_evap(:,:)
    real(ESMF_KIND_R8), pointer     :: fptr_taux(:,:), fptr_tauy(:,:)
    integer :: gi2, gj2, ierr2, ii, jj

    nullify(fptr_sen, fptr_evap, fptr_taux, fptr_tauy)
    allocate(sen_g2(ATM_NX,ATM_NY), lat_g2(ATM_NX,ATM_NY))
    allocate(taux_g2(ATM_NX,ATM_NY), tauy_g2(ATM_NX,ATM_NY), tmp2(ATM_NX,ATM_NY))

    ! Gather global (mesmo padrao SUM com tiles disjuntos)
    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(sen_mpas,2), ubound(sen_mpas,2)
      do gi2 = lbound(sen_mpas,1), ubound(sen_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = sen_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, sen_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, is%par%comm, ierr2)

    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(lat_mpas,2), ubound(lat_mpas,2)
      do gi2 = lbound(lat_mpas,1), ubound(lat_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = lat_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, lat_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, is%par%comm, ierr2)

    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(taux_mpas,2), ubound(taux_mpas,2)
      do gi2 = lbound(taux_mpas,1), ubound(taux_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = taux_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, taux_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, is%par%comm, ierr2)

    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(tauy_mpas,2), ubound(tauy_mpas,2)
      do gi2 = lbound(tauy_mpas,1), ubound(tauy_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = tauy_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, tauy_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, is%par%comm, ierr2)

    call ESMF_FieldGet(is%ocn_flx%sen,  farrayPtr=fptr_sen,  rc=rc)
    call ESMF_FieldGet(is%ocn_flx%evap, farrayPtr=fptr_evap, rc=rc)
    call ESMF_FieldGet(is%ocn_flx%taux, farrayPtr=fptr_taux, rc=rc)
    call ESMF_FieldGet(is%ocn_flx%tauy, farrayPtr=fptr_tauy, rc=rc)
    rc = ESMF_SUCCESS

    if (associated(fptr_sen) .and. associated(fptr_evap) .and. &
        associated(fptr_taux) .and. associated(fptr_tauy)) then
      do jj = lbound(fptr_sen,2), ubound(fptr_sen,2)
        do ii = lbound(fptr_sen,1), ubound(fptr_sen,1)
          if (ii >= 1 .and. ii <= ATM_NX .and. jj >= 1 .and. jj <= ATM_NY) then
            ! so sobrescreve onde ha dado nativo real (fora do fill=0
            ! dos PETs sem tile MONAN-A local — mesmo criterio)
            if (abs(sen_g2(ii,jj)) > 1.0e-10_ESMF_KIND_R8) then
              fptr_sen(ii,jj)  = -sen_g2(ii,jj)          ! VERIFICAR sinal (ver acima)
              fptr_evap(ii,jj) = -lat_g2(ii,jj) / L_evap ! W/m^2 -> kg/m^2/s
              fptr_taux(ii,jj) = taux_g2(ii,jj)
              fptr_tauy(ii,jj) = tauy_g2(ii,jj)
            end if
          end if
        end do
      end do
    end if

    deallocate(sen_g2, lat_g2, taux_g2, tauy_g2, tmp2)
  end subroutine substitute_native_fluxes

  subroutine zero_med_fluxes(is, rc)
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    call ZeroInternalField(is%ocn_flx%taux,   rc)
    call ZeroInternalField(is%ocn_flx%tauy,   rc)
    call ZeroInternalField(is%ocn_flx%sen,    rc)
    call ZeroInternalField(is%ocn_flx%evap,   rc)
    call ZeroInternalField(is%ocn_flx%lwnet,  rc)
    call ZeroInternalField(is%ocn_flx%swvdr,  rc)
    call ZeroInternalField(is%ocn_flx%swvdf,  rc)
    call ZeroInternalField(is%ocn_flx%swidr,  rc)
    call ZeroInternalField(is%ocn_flx%swidf,  rc)
    call ZeroInternalField(is%ocn_flx%rain,   rc)
    call ZeroInternalField(is%ocn_flx%snow,   rc)
    call ZeroInternalField(is%ocn_flx%pslv,   rc)
    ! NÃO zerar is%ice%ifrac incondicionalmente.
    ! Com use_docn_ice=T, init_only=T e is%run%ifrac_init_done=T,
    ! fill_ifrac_from_oisst é pulado após o primeiro passo; zerando aqui, o
    ! MPAS receberia Si_ifrac=0 em todos os passos seguintes ao t=1.
    ! O campo é zerado apenas nos modos em que será repreenchido neste ciclo.
    ! No modo init_only, o decaimento é aplicado no bloco 3b.
    if (.not. (cfg_use_docn_ice .and. &
               cfg_docn_ice_init_only .and. is%run%ifrac_init_done)) then
      call ZeroInternalField(is%ice%ifrac, rc)
    end if
    call ZeroInternalField(is%ocn_flx%duu10n, rc)
    ! Zerar correntes para evitar persistência
    call ZeroInternalField(is%ocn%u,   rc)
    call ZeroInternalField(is%ocn%v,   rc)
    rc = ESMF_SUCCESS  ! ZeroInternalField pode retornar !=SUCCESS para PETs sem DE
  end subroutine zero_med_fluxes

end module med_flux_mod
