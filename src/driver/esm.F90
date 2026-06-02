!> @file esm.F90
!! @brief Driver ESMF/NUOPC do sistema acoplado MONAN-A 2.0 × MOM6+SIS2.
!!
!! Versão 8.0 — Fase 2 completa: acoplamento dinâmico real MPAS × MOM6+SIS2.
!!
!! Arquitetura:
!!   MPAS (ATM) ──→ MED ──→ OCN
!!                   ↑         │
!!             OCN ──┘         │ (Fase 2)
!!             MED ──────────→ MPAS
!!
!! Componentes:
!!   MPAS : modelo atmosférico MONAN-A 2.0 (MPAS 8.3.1), malha Voronoi
!!   MED  : mediador MED_cap_MONAN — bulk NCAR (Large & Yeager 2009)
!!   OCN  : MOM6+SIS2 dinâmico (MOM_cap_MONAN_mod — Fase 2)
!!
!! Conectores (4 no total):
!!   MPAS → MED  : 9 campos atmosféricos com sufixo _mpas
!!   OCN  → MED  : So_t, Si_ifrac, So_u, So_v → fórmula bulk
!!   MED  → OCN  : 14 campos de fluxo calculados (Foxx_*, Faxa_*, etc.)
!!   MED  → MPAS : So_t, Si_ifrac, So_u, So_v, Sf_zorl (Fase 2, regrid conserv.)
!!              OU OCN → MPAS direto (Fase 1, DOCN)
!!
!! RunSequence — Fase 2 (use_med_to_mpas=true, MOM6 dinâmico):
!!   1. OCN  → MED   So_t, Si_ifrac, So_u, So_v → mediador
!!   2. MPAS → MED   9 campos _mpas → mediador
!!   3. MED           RouteOcnToAtm (regrid conservativo) + bulk NCAR
!!   4. MED  → MPAS  SST, gelo, correntes → MONAN-A (regrid conservativo)
!!   5. MPAS          dinâmica + física atmosférica (N×dt_atm)
!!   6. MED  → OCN   14 fluxos Foxx_*/Faxa_* → MOM6+SIS2
!!   7. OCN           avança MOM6+SIS2 (sub-cicla barotrópico internamente)
!!
!! RunSequence — Fase 1 (use_med_to_mpas=false, DOCN):
!!   1. OCN  → MPAS  SST lag t-1 → sfc_input MONAN-A
!!   2. MPAS          dinâmica + física atmosférica (N×dt_atm)
!!   3. MPAS → MED   9 campos _mpas → mediador
!!   4. OCN  → MED   So_t, Si_ifrac, So_u, So_v → mediador
!!   5. MED           fórmula bulk NCAR → 14 fluxos
!!   6. MED  → OCN   14 fluxos Foxx_*/Faxa_*
!!   7. OCN           avança DOCN (OISST netcdf)
!!
!! NUOPC/ESMF 8.9.1 — INPE / CGCT / DIMNT — GT Acoplamento de Modelos
!! Cachoeira Paulista, SP — Maio 2026.

module ESM_MONAN

  use ESMF
  use NUOPC, only : NUOPC_FreeFormatCreate, NUOPC_FreeFormat, &
                    NUOPC_FreeFormatDestroy, NUOPC_CompAttributeSet, &
                    NUOPC_CompAttributeAdd, NUOPC_CompAttributeGet, &
                    NUOPC_FieldDictionarySetAutoAdd, &
                    NUOPC_CompDerive, NUOPC_CompSpecialize
  use NUOPC_Driver, &
    driver_routine_SS             => SetServices,            &
    driver_label_SetModelServices => label_SetModelServices, &
    driver_label_SetRunSequence   => label_SetRunSequence

  ! Conector NUOPC padrão
  use NUOPC_Connector, only : CPL_SetServices => SetServices

  ! Caps dos componentes
  ! Correcao B-60: modulos MONAN usam sufixo _MONAN no nome interno.
  ! Diagnostico build/mod/ confirmou: mpas_cap_monan_mod.mod e med_cap_monan_mod.mod
  use mpas_cap_MONAN_mod,  only : MPAS_SetServices => SetServices
  use MED_cap_MONAN_mod,   only : MED_SetServices  => SetServices
  ! Fase 2: OCN usa MOM_cap_MONAN_mod (wrapper sobre MOM_cap_mod com
  ! InitializeRealize, ModelAdvance e Finalize reais do MOM6+SIS2).
  ! Quando use_docn=.true. (Fase 1), DOCN_SetServices é usado no lugar.
  use MOM_cap_MONAN_mod,   only : OCN_SetServices  => SetServices
  use DOCN_cap_mod,        only : DOCN_SetServices => SetServices
  use mpas_cap_config_mod, only : cfg_use_datm, cfg_use_docn, &
                                   cfg_use_med_to_mpas, config_read

  implicit none
  private
  public :: SetServices

  ! ── Rótulos dos componentes ───────────────────────────────────────────────
  character(len=*), parameter :: MPAS_LABEL = "MPAS"
  character(len=*), parameter :: MED_LABEL  = "MED"
  character(len=*), parameter :: OCN_LABEL  = "OCN"

  !----------------------------------------------------------------------------
  ! dt_coupling_s: intervalo de acoplamento em segundos.
  !   3h = 10800 s — padrão para experimentos MONAN-A 2.0 × MOM6.
  !   Editar aqui ou sobrescrever via atributo NUOPC "dt_coupling".
  !----------------------------------------------------------------------------
  ! dt_coupling_s lido dinamicamente do clock do driver em SetRunSequence
  ! (era: integer, parameter :: dt_coupling_s = 10800 — bug: hardcoded)

contains

  ! ============================================================================
  subroutine SetServices(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(driver, driver_routine_SS, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(driver, &
      specLabel=driver_label_SetModelServices, &
      specRoutine=SetModelServices, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(driver, &
      specLabel=driver_label_SetRunSequence, &
      specRoutine=SetRunSequence, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

  end subroutine SetServices

  ! ============================================================================
  !> @brief Registra componentes (MPAS, MED, OCN) e conectores.
  subroutine SetModelServices(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    type(ESMF_GridComp)  :: mpasComp, medComp, ocnComp
    type(ESMF_Clock)        :: driverClock
    type(ESMF_TimeInterval) :: driverTimeStep
    integer(ESMF_KIND_I8)   :: dt_coupling_i8
    integer              :: petCount, i
    integer, allocatable :: petList(:)
    character(len=16)    :: dt_str
    character(len=8)     :: val_med_to_mpas
    logical              :: use_med_to_mpas
    logical              :: use_datm_local, use_docn_local
    character(len=8)     :: str_use_datm, str_use_docn
    ! ── Mudança ② (v7.0): variáveis para atributos obrigatórios do MOM6 ──────
    ! O FMS (Flexible Modeling System) precisa de stop_ymd/stop_tod para
    ! gerenciar alarmes de restart e parada do MOM6 internamente.
    type(ESMF_Time)      :: stop_t
    integer              :: syy, smm, sdd, sh, sm_int, ss_int
    character(len=8)     :: stop_ymd_str   ! YYYYMMDD
    character(len=6)     :: stop_tod_str   ! segundos desde meia-noite

    rc = ESMF_SUCCESS

    ! AutoAdd necessário para nomes customizados (_mpas, So_t, Foxx_*, etc.)
    call NUOPC_FieldDictionarySetAutoAdd(.true., rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_GridCompGet(driver, petCount=petCount, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    allocate(petList(petCount))
    petList = [(i-1, i=1,petCount)]

    !--------------------------------------------------------------------------
    ! Componente MPAS (MONAN-A 2.0)
    !--------------------------------------------------------------------------
    call NUOPC_DriverAddComp(driver,                          &
      compLabel              = MPAS_LABEL,                    &
      compSetServicesRoutine = MPAS_SetServices,              &
      petList                = petList,                       &
      comp                   = mpasComp,                      &
      rc                     = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompAttributeSet(mpasComp, name="Verbosity",  value="high",  rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_CompAttributeSet(mpasComp, name="DumpFields", value="false", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Passa dt_coupling ao MPAS cap (para AlarmInit)
    ! Lê do clock do driver (= dt_coupling de nuopc.input) em vez de hardcoded.
    call ESMF_GridCompGet(driver, clock=driverClock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call ESMF_ClockGet(driverClock, timeStep=driverTimeStep, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call ESMF_TimeIntervalGet(driverTimeStep, s_i8=dt_coupling_i8, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    write(dt_str,'(I0)') dt_coupling_i8
    call NUOPC_CompAttributeAdd(mpasComp,  attrList=(/"dt_coupling"/), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_CompAttributeSet(mpasComp,  name="dt_coupling", value=trim(dt_str), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! Componente MED (mediador NCAR bulk)
    !--------------------------------------------------------------------------
    call NUOPC_DriverAddComp(driver,                          &
      compLabel              = MED_LABEL,                     &
      compSetServicesRoutine = MED_SetServices,               &
      petList                = petList,                       &
      comp                   = medComp,                       &
      rc                     = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompAttributeSet(medComp, name="Verbosity", value="high", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! ── Ler nuopc.input para obter cfg_use_datm / cfg_use_docn ─────────────
    call config_read(rc=rc)
    use_datm_local = cfg_use_datm
    use_docn_local = cfg_use_docn
    str_use_datm = merge('true    ', 'false   ', use_datm_local)
    str_use_docn = merge('true    ', 'false   ', use_docn_local)
    write(*,'(A,L1,A,L1)') '[ESM] nuopc_mode: use_datm=', use_datm_local, &
      '  use_docn=', use_docn_local

    ! Informa ao mediador: use_mpas_atm = NOT(use_datm)
    ! Se use_datm=true → o mediador usa DATM como fallback (use_mpas_atm=false).
    ! Se use_datm=false → mediador usa MPAS real (padrão de produção).
    call NUOPC_CompAttributeAdd(medComp, attrList=(/"use_mpas_atm"/), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_CompAttributeSet(medComp, name="use_mpas_atm", &
      value=merge('false   ', 'true    ', use_datm_local), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! Componente OCN — seleção dinâmica via use_docn (nuopc_mode):
    !   use_docn = .false. (padrão) → MOM6+SIS2 dinâmico (NUOPC cap)
    !   use_docn = .true.           → DOCN (OISST v2.1 netcdf — SST/gelo por dados)
    !
    ! Ambos expõem o mesmo conjunto de campos NUOPC (So_t, So_u, So_v,
    ! Si_ifrac, Sf_zorl) para o mediador, portanto o runsequence é idêntico.
    !--------------------------------------------------------------------------
    if (use_docn_local) then
      call NUOPC_DriverAddComp(driver,                            &
        compLabel              = OCN_LABEL,                       &
        compSetServicesRoutine = DOCN_SetServices,                &
        petList                = petList,                         &
        comp                   = ocnComp,                         &
        rc                     = rc)
      write(*,'(A)') '[ESM] OCN: DOCN OISST ativo (use_docn=T, nuopc_mode)'
    else
      call NUOPC_DriverAddComp(driver,                            &
        compLabel              = OCN_LABEL,                       &
        compSetServicesRoutine = OCN_SetServices,                 &
        petList                = petList,                         &
        comp                   = ocnComp,                         &
        rc                     = rc)
      write(*,'(A)') '[ESM] OCN: MOM6+SIS2 dinâmico ativo (use_docn=F)'
    end if
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompAttributeSet(ocnComp, name="Verbosity", value="high", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! Mudança ② (v7.0): atributos obrigatórios para MOM6+SIS2
    !
    ! 1. timeStampValidation=false
    !    Sem este atributo, o NUOPC verifica se o timestamp do campo exportado
    !    pelo OCN coincide com o relógio do driver. O FMS usa seu próprio
    !    gerenciador de tempo internamente, podendo gerar pequenas divergências
    !    de timestamp que aborteriam o sistema com INCOMPATIBILITY (IPDv03p7).
    !--------------------------------------------------------------------------
    call NUOPC_CompAttributeSet(ocnComp, name="timeStampValidation", &
      value="false", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! 2. restart_n=0 — sem restart periódico durante a simulação.
    !    O mom_cap.F90 usa este atributo para decidir a frequência de escrita
    !    de restarts intermediários. 0 = sem restart intermediário.
    !    O restart final ao término da simulação é sempre escrito por
    !    ocean_model_end() na fase ModelFinalize.
    !--------------------------------------------------------------------------
    call NUOPC_CompAttributeSet(ocnComp, name="restart_n", &
      value="0", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! 3. stop_ymd e stop_tod — data/hora de parada para o FMS time manager
    !    O FMS precisa saber quando a simulação termina para programar alarmes
    !    de restart e shutdown. Calculados a partir do stopTime do clock do driver.
    !    Formato: stop_ymd = YYYYMMDD (ex: "20260502")
    !             stop_tod = segundos desde meia-noite (ex: "0")
    !--------------------------------------------------------------------------
    call ESMF_ClockGet(driverClock, stopTime=stop_t, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_TimeGet(stop_t, yy=syy, mm=smm, dd=sdd, &
                      h=sh, m=sm_int, s=ss_int, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    write(stop_ymd_str, '(i4.4,i2.2,i2.2)') syy, smm, sdd
    write(stop_tod_str, '(i6)') sh*3600 + sm_int*60 + ss_int

    call NUOPC_CompAttributeSet(ocnComp, name="stop_ymd", &
      value=trim(adjustl(stop_ymd_str)), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompAttributeSet(ocnComp, name="stop_tod", &
      value=trim(adjustl(stop_tod_str)), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite( &
      'ESM: atributos MOM6 definidos — stop_ymd='//trim(stop_ymd_str)// &
      '  stop_tod='//trim(adjustl(stop_tod_str)), ESMF_LOGMSG_INFO)
    ! ── Fim Mudança ② ─────────────────────────────────────────────────────────

    !--------------------------------------------------------------------------
    ! Modo de roteamento OCN→ATM:
    !   use_med_to_mpas = false (padrão, DOCN):
    !     Conector direto OCN → MPAS. A grade DOCN (1440×720, lat/lon regular)
    !     usa redistribuição zero-copy ao MPAS via regrid bilinear ESMF.
    !
    !   use_med_to_mpas = true (Fase 2, MOM6 dinâmico):
    !     OCN exporta apenas ao MED; MED roteia para MPAS via RouteOcnToAtm
    !     com regrid conservativo (tripolar B-grid → malha Voronoi).
    !     Ativar em nuopc.input: use_med_to_mpas = '.true.'
    !     Requer: MOM_cap.F90 v2.0 + pesos ESMF pré-computados.
    !--------------------------------------------------------------------------
    ! Ler use_med_to_mpas do nuopc.input via mpas_cap_config_mod
    ! (cfg_use_med_to_mpas lido em config_read() chamado acima).
    use_med_to_mpas = cfg_use_med_to_mpas
    val_med_to_mpas = merge('true    ', 'false   ', use_med_to_mpas)
    call NUOPC_CompAttributeAdd(driver, attrList=(/'use_med_to_mpas'/), rc=rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS
    call NUOPC_CompAttributeSet(driver, name='use_med_to_mpas', &
      value=trim(val_med_to_mpas), rc=rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS

    if (use_med_to_mpas) then
      call ESMF_LogWrite( &
        'ESM: use_med_to_mpas=true — conector MED->MPAS ativo (Fase 2)', &
        ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite( &
        'ESM: use_med_to_mpas=false — conector OCN->MPAS direto (DOCN OISST)', &
        ESMF_LOGMSG_INFO)
    end if

    !--------------------------------------------------------------------------
    ! Também passar o flag ao mediador (usado em RouteOcnToAtm)
    !--------------------------------------------------------------------------
    call NUOPC_CompAttributeAdd(medComp, attrList=(/'use_med_to_mpas'/), rc=rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS
    call NUOPC_CompAttributeSet(medComp, name='use_med_to_mpas', &
      value=trim(val_med_to_mpas), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    !
    ! 1. MPAS → MED : 9 campos _mpas → mediador
    !--------------------------------------------------------------------------
    call NUOPC_DriverAddComp(driver,                          &
      srcCompLabel           = MPAS_LABEL,                    &
      dstCompLabel           = MED_LABEL,                     &
      compSetServicesRoutine = CPL_SetServices,               &
      rc                     = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! 2. OCN → MED : So_t → bulk formula do mediador
    !--------------------------------------------------------------------------
    call NUOPC_DriverAddComp(driver,                          &
      srcCompLabel           = OCN_LABEL,                     &
      dstCompLabel           = MED_LABEL,                     &
      compSetServicesRoutine = CPL_SetServices,               &
      rc                     = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! 3. MED → OCN : 14 campos de fluxo → MOM6
    !--------------------------------------------------------------------------
    call NUOPC_DriverAddComp(driver,                          &
      srcCompLabel           = MED_LABEL,                     &
      dstCompLabel           = OCN_LABEL,                     &
      compSetServicesRoutine = CPL_SetServices,               &
      rc                     = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! 4. OCN → MPAS (DOCN OISST) OU MED → MPAS (MOM6 dinâmico)
    !
    !   DOCN — OCN → MPAS direto (use_med_to_mpas=false, padrão):
    !     So_t, Si_ifrac, So_u, So_v, Sf_zorl → sfc_input MONAN-A via
    !     redistribuição ESMF (grade DOCN 1440×720 lat/lon regular).
    !
    !   MOM6 dinâmico — MED → MPAS (use_med_to_mpas=true em nuopc.input):
    !     MED_cap.RouteOcnToAtm aplica regrid conservativo (tripolar →
    !     malha Voronoi) com máscara terra/oceano. Requer MOM_cap.F90 v2.0.
    !--------------------------------------------------------------------------
    if (use_med_to_mpas) then
      call NUOPC_DriverAddComp(driver,                        &
        srcCompLabel           = MED_LABEL,                   &
        dstCompLabel           = MPAS_LABEL,                  &
        compSetServicesRoutine = CPL_SetServices,             &
        rc                     = rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call ESMF_LogWrite( &
        'ESM: conector 4 = MED -> MPAS (MOM6 — regrid conservativo)', &
        ESMF_LOGMSG_INFO)
    else
      call NUOPC_DriverAddComp(driver,                        &
        srcCompLabel           = OCN_LABEL,                   &
        dstCompLabel           = MPAS_LABEL,                  &
        compSetServicesRoutine = CPL_SetServices,             &
        rc                     = rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call ESMF_LogWrite( &
        'ESM: conector 4 = OCN -> MPAS (DOCN OISST — redistribuicao)', &
        ESMF_LOGMSG_INFO)
    end if

    deallocate(petList)

    call ESMF_LogWrite( &
      'ESM: componentes e conectores registrados (MPAS+MED+OCN, 4 conectores)', &
      ESMF_LOGMSG_INFO)

  end subroutine SetModelServices

  ! ============================================================================
  !> @brief Define a sequência de execução por passo de acoplamento.
  !!
  !! Fase 1 (use_med_to_mpas=false, padrão — DOCN):
  !!   1. OCN → MPAS  : SST lag t-1 → sfc_input MONAN-A
  !!   2. MPAS        : dinâmica + física atmosférica (30×60 s)
  !!   3. MPAS → MED  : 9 campos _mpas → mediador
  !!   4. OCN → MED   : So_t, Si_ifrac, So_u, So_v → mediador
  !!   5. MED         : fórmula bulk NCAR (Large & Yeager 2009)
  !!   6. MED → OCN   : 14 fluxos Foxx_*/Faxa_*
  !!   7. OCN         : avança DOCN (OISST netcdf)
  !!
  !! Fase 2 (use_med_to_mpas=true — MOM6 dinâmico):
  !!   1. OCN → MED   : So_t, Si_ifrac, So_u, So_v → mediador
  !!   2. MPAS → MED  : 9 campos _mpas → mediador
  !!   3. MED         : RouteOcnToAtm (regrid conservativo) + bulk NCAR
  !!   4. MED → MPAS  : SST, gelo, correntes (regrid conservativo)
  !!   5. MPAS        : dinâmica + física atmosférica (30×60 s)
  !!   6. MED → OCN   : 14 fluxos Foxx_*/Faxa_*
  !!   7. OCN         : avança MOM6 dinâmico
  subroutine SetRunSequence(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    type(NUOPC_FreeFormat)  :: runSeqFF
    type(ESMF_Clock)        :: driverClock
    type(ESMF_TimeInterval) :: driverTimeStep
    character(len=18)       :: line1
    integer(ESMF_KIND_I8)   :: dt_s
    character(len=64)       :: msg
    character(len=8)        :: val_seq
    logical                 :: use_med_to_mpas

    rc = ESMF_SUCCESS

    !-- Obter o timestep do clock do driver (= dt_coupling de nuopc.input) ----
    call ESMF_GridCompGet(driver, clock=driverClock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg='ESM: falha ao obter clock do driver em SetRunSequence', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_ClockGet(driverClock, timeStep=driverTimeStep, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_TimeIntervalGet(driverTimeStep, s_i8=dt_s, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !-- Formatar "@<dt_s>" como character(len=18) com pad de espaços ----------
    ! write() em character(len=18) preenche o restante com espaços
    ! automaticamente: "@1800" → "@1800             " (18 chars).
    write(line1, '("@",I0)') dt_s

    write(msg, '(A,I0,A)') 'ESM: RunSequence dt=', dt_s, 's — periodo=driver clock'
    call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)

    ! Ler flag use_med_to_mpas para selecionar sequência correta
    val_seq = 'false'
    call NUOPC_CompAttributeGet(driver, name='use_med_to_mpas', &
      value=val_seq, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      val_seq = 'false'
      rc = ESMF_SUCCESS
    end if
    use_med_to_mpas = (trim(val_seq) == '.true.' .or. trim(val_seq) == 'true')

    ! CRÍTICO: todas as strings têm exatamente 18 chars (character(len=18)).
    ! write() em character(len=18) preenche o restante com espaços.
    if (use_med_to_mpas) then
      ! ── Fase 2: MOM6 dinâmico — OCN e ATM exportam ao MED primeiro ─────────
      ! O MED aplica RouteOcnToAtm (regrid conservativo) e entrega ao MPAS.
      ! Não há conector OCN→MPAS — tudo roteia pelo mediador.
      runSeqFF = NUOPC_FreeFormatCreate(stringList=(/ &
        line1,              &  ! "@<dt_coupling>    "
        "  OCN -> MED      ", &  ! So_t, Si_ifrac, So_u, So_v -> mediador
        "  MPAS -> MED     ", &  ! 9 campos _mpas -> mediador
        "  MED             ", &  ! RouteOcnToAtm + bulk NCAR
        "  MED -> MPAS     ", &  ! SST/gelo/correntes -> MPAS (regrid conserv.)
        "  MPAS            ", &  ! dinamica + fisica ATM com SST do MED
        "  MED -> OCN      ", &  ! 14 fluxos Foxx_*/Faxa_* -> MOM6
        "  OCN             ", &  ! avanca MOM6 dinamico
        "@                 " /), rc=rc)
      call ESMF_LogWrite('ESM: RunSequence Fase 2 (MED->MPAS)', ESMF_LOGMSG_INFO)
    else
      ! ── Fase 1: DOCN — conector direto OCN→MPAS com regrid bilinear ─────────
      ! SST com lag de 1 passo: garante que o MPAS usa So_t do passo anterior
      ! (equivalente ao "ocean lag" do CESM — comportamento padrão em modelos
      ! acoplados AOGCMs). Sem lag, MPAS e OCN processariam So_t simultaneamente
      ! gerando inconsistência no first-call do sfc_input.
      runSeqFF = NUOPC_FreeFormatCreate(stringList=(/ &
        line1,              &  ! "@<dt_coupling>    "
        "  OCN -> MPAS     ", &  ! SST lag t-1 -> sfc_input MONAN-A
        "  MPAS            ", &  ! dinamica + fisica ATM
        "  MPAS -> MED     ", &  ! 9 campos _mpas -> mediador
        "  OCN -> MED      ", &  ! So_t, Si_ifrac, So_u, So_v -> mediador
        "  MED             ", &  ! calcula fluxos bulk NCAR
        "  MED -> OCN      ", &  ! 14 fluxos -> OCN (DOCN ignora)
        "  OCN             ", &  ! avanca DOCN (OISST netcdf)
        "@                 " /), rc=rc)
      call ESMF_LogWrite('ESM: RunSequence Fase 1 (OCN->MPAS direto)', ESMF_LOGMSG_INFO)
    end if
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_DriverIngestRunSequence(driver, runSeqFF, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_FreeFormatDestroy(runSeqFF, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    write(msg, '(A,I0,A)') &
      'ESM: RunSequence MPAS+MED+OCN configurada (dt=', dt_s, 's)'
    call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)

  end subroutine SetRunSequence

end module ESM_MONAN
