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

  ! Componente ICE (SIS2 dinâmico), integrado a partir do MONAN-Coupler-PK.
  ! É um componente NUOPC separado, e não um subcomponente embutido no OCN via
  ! combined_ice_ocean_driver. Só é registrado quando cfg_use_sis2_dynamic
  ! está ligado.
  use sis_cap_MONAN_mod,   only : ICE_SetServices  => SetServices
  use mpas_cap_config_mod, only : cfg_use_datm, cfg_use_docn, &
                                   cfg_use_med_to_mpas, config_read, &
                                   cfg_coupling_mode, cfg_pet_layout, &
                                   cfg_atm_pet_count, cfg_ocn_pet_count, &
                                   cfg_ice_pet_count, cfg_use_sis2_dynamic

  implicit none
  private
  public :: SetServices

  ! ── Rótulos dos componentes ───────────────────────────────────────────────
  character(len=*), parameter :: MPAS_LABEL = "MPAS"
  character(len=*), parameter :: MED_LABEL  = "MED"
  character(len=*), parameter :: OCN_LABEL  = "OCN"
  character(len=*), parameter :: ICE_LABEL  = "ICE"

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
  !> @brief Registra um componente Model no driver e, no mesmo passo, atribui a
  !! ele o relógio do driver.
  !!
  !! Com três ou mais componentes em blocos disjuntos de PETs (ATM/OCN/ICE), o
  !! mecanismo automático do NUOPC não estava atribuindo relógio interno a
  !! alguns componentes, e a execução abortava com "Clock object is not
  !! present" (rastreado até NUOPC_ModelBase.F90/NUOPC_CompCheckSetClock).
  !! Atribuir o relógio explicitamente logo após o registro resolve.
  !!
  !! Ao acrescentar um componente Model novo (WAV, LND, o que for), use esta
  !! rotina em vez de chamar NUOPC_DriverAddComp direto: assim a atribuição do
  !! relógio vem junto, sem depender de alguém lembrar de repetir o bloco.
  subroutine AddModelCompWithClock(driver, compLabel, compSetServicesRoutine, &
      petList, driverClock, comp, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    character(len=*),    intent(in)    :: compLabel
    interface
      subroutine compSetServicesRoutine(gcomp, rc)
        use ESMF, only: ESMF_GridComp
        type(ESMF_GridComp)   :: gcomp
        integer, intent(out)  :: rc
      end subroutine
    end interface
    integer,              intent(in)    :: petList(:)
    type(ESMF_Clock),     intent(in)    :: driverClock
    type(ESMF_GridComp),  intent(out)   :: comp
    integer,              intent(out)   :: rc

    ! CORREÇÃO (bug real, encontrado em execução): o relógio entregue a cada
    ! componente precisa ser uma CÓPIA, não o objeto do driver.
    !
    ! ESMF_Clock é um tipo por referência. Passar driverClock direto para
    ! ESMF_GridCompSet fazia todos os componentes Model apontarem para o
    ! MESMO relógio físico. Como o NUOPC avança o relógio associado a cada
    ! componente depois do respectivo Advance, com três componentes Model
    ! (MPAS, OCN e ICE) o mesmo relógio recebia até três avanços por ciclo
    ! de dt_coupling, em vez de um. O sintoma observado foi a escrita de
    ! monan2_import passar de horária para a cada três horas: exatamente o
    ! fator 3 previsto.
    !
    ! ESMF_ClockCreate com um relógio como argumento é o construtor de cópia
    ! do ESMF, e resolve o problema.
    type(ESMF_Clock) :: compClock

    call NUOPC_DriverAddComp(driver,                          &
      compLabel              = compLabel,                     &
      compSetServicesRoutine = compSetServicesRoutine,        &
      petList                = petList,                       &
      comp                   = comp,                          &
      rc                     = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    compClock = ESMF_ClockCreate(driverClock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ESM: falha ao copiar ' // &
      'relogio para o componente ' // trim(compLabel), &
      line=__LINE__, file=__FILE__)) return

    call ESMF_GridCompSet(comp, clock=compClock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ESM: falha ao atribuir ' // &
      'relogio explicito ao componente ' // trim(compLabel), &
      line=__LINE__, file=__FILE__)) return

  end subroutine AddModelCompWithClock

  ! ============================================================================
  !> @brief Registra um Connector e atribui a ele uma CÓPIA independente do
  !! relógio do driver. Equivalente a AddModelCompWithClock, mas para
  !! ESMF_CplComp em vez de ESMF_GridComp.
  !!
  !! O mesmo problema de relógio ausente afeta os conectores; o NUOPC Compliance
  !! Checker acusava "MED-TO-ICE: The internal Clock is not present!". Use esta
  !! rotina ao acrescentar um conector novo.
  subroutine AddConnectorWithClock(driver, srcCompLabel, dstCompLabel, &
      compSetServicesRoutine, driverClock, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    character(len=*),    intent(in)    :: srcCompLabel, dstCompLabel
    interface
      subroutine compSetServicesRoutine(cplcomp, rc)
        use ESMF, only: ESMF_CplComp
        type(ESMF_CplComp)    :: cplcomp
        integer, intent(out)  :: rc
      end subroutine
    end interface
    type(ESMF_Clock),     intent(in)    :: driverClock
    integer,              intent(out)   :: rc

    type(ESMF_CplComp) :: cplComp
    ! Cópia independente do relógio, mesma razão explicada em
    ! AddModelCompWithClock acima.
    type(ESMF_Clock)   :: cplClock

    call NUOPC_DriverAddComp(driver,                          &
      srcCompLabel           = srcCompLabel,                  &
      dstCompLabel           = dstCompLabel,                  &
      compSetServicesRoutine = compSetServicesRoutine,        &
      comp                   = cplComp,                       &
      rc                     = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    cplClock = ESMF_ClockCreate(driverClock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ESM: falha ao copiar ' // &
      'relogio para o conector ' // trim(srcCompLabel) // '->' // &
      trim(dstCompLabel), line=__LINE__, file=__FILE__)) return

    call ESMF_CplCompSet(cplComp, clock=cplClock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ESM: falha ao atribuir ' // &
      'relogio explicito ao conector ' // trim(srcCompLabel) // '->' // &
      trim(dstCompLabel), line=__LINE__, file=__FILE__)) return

  end subroutine AddConnectorWithClock

  ! ============================================================================
  ! ============================================================================
  !> @brief Registra componentes (MPAS, MED, OCN) e conectores.
  subroutine SetModelServices(driver, rc)
    type(ESMF_GridComp)  :: driver
    integer, intent(out) :: rc

    type(ESMF_GridComp)  :: mpasComp, medComp, ocnComp, iceComp
    type(ESMF_Clock)        :: driverClock
    type(ESMF_TimeInterval) :: driverTimeStep
    integer(ESMF_KIND_I8)   :: dt_coupling_i8
    integer              :: petCount, i, nAtm, nOcn, nIce
    integer, allocatable :: atmPetList(:), ocnPetList(:), medPetList(:)
    integer, allocatable :: icePetList(:)
    logical              :: use_ice         ! componente ICE (SIS2) ativo?
    logical              :: is_concurrent   ! eixo TEMPORAL  (RunSequence)
    logical              :: is_split        ! eixo ESPACIAL  (petList)
    character(len=10)    :: exec_str        ! 'SEQUENTIAL' | 'CONCURRENT'
    integer              :: cfg_rc
    character(len=160)   :: msg
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

    !--------------------------------------------------------------------------
    ! Particionamento de PETs (lido de &nuopc_petlayout via config_read, que já
    ! foi chamado em esmApp.F90 antes de ESMF_Initialize).
    !
    ! São DOIS eixos ORTOGONAIS, e tratá-los como um só era o defeito corrigido
    ! na v14.20 (o split de comunicador só existia no ramo concurrent, de modo
    ! que atm_pet_count/ocn_pet_count eram descartados em silêncio no modo
    ! sequential):
    !
    !   cfg_pet_layout    — decidido AQUI, pelas petList dos componentes:
    !     'shared' : MPAS, MED e OCN em TODOS os PETs (sem split).
    !     'split'  : ATM e OCN em blocos DISJUNTOS de PETs (split de
    !                comunicador); MED permanece em todos os PETs.
    !
    !   cfg_coupling_mode — decidido em SetRunSequence, pela RunSequence:
    !     'sequential' : ATM e OCN avançam um depois do outro (sem lag).
    !     'concurrent' : ATM e OCN avançam ao mesmo tempo (lag de 1 passo).
    !
    ! sequential+split é uma configuração legal e útil: MPAS e MOM6 mantêm
    ! decomposições de tamanhos muito diferentes, cada um no seu comunicador,
    ! sem a defasagem de um passo do modo concorrente. O preço é tempo de
    ! parede (soma dos dois componentes, com PETs ociosos em cada fase).
    ! concurrent+shared é rejeitado em mpas_cap_config (config_read).
    !
    ! Os 4 conectores NÃO precisam de petList: NUOPC_DriverAddComp com
    ! src/dstCompLabel roda automaticamente na UNIÃO dos PETs de origem e
    ! destino — válido nos dois layouts e nos dois modos.
    !--------------------------------------------------------------------------
    is_concurrent = (trim(cfg_coupling_mode) == 'concurrent')
    is_split      = (trim(cfg_pet_layout)    == 'split')
    use_ice       = cfg_use_sis2_dynamic
    if (is_concurrent) then
      exec_str = 'CONCURRENT'
    else
      exec_str = 'SEQUENTIAL'
    end if

    ! O relógio do driver é buscado AQUI, antes de qualquer registro de
    ! componente, porque cada componente e cada conector recebem esse relógio
    ! explicitamente no momento em que são registrados (ver
    ! AddModelCompWithClock / AddConnectorWithClock).
    call ESMF_GridCompGet(driver, clock=driverClock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    allocate(medPetList(petCount))
    medPetList = [(i-1, i=1,petCount)]

    if (is_split) then
      ! Partição disjunta ATM | OCN [| ICE], cobrindo todos os PETs.
      !
      ! O gelo entra aqui como um terceiro bloco, e não como um caso à parte:
      ! quando use_ice está desligado, nIce=0 e as contas abaixo recaem
      ! exatamente na divisão em dois blocos que existia antes, o que mantém a
      ! partição byte a byte idêntica para quem não usa SIS2 dinâmico.
      nAtm = cfg_atm_pet_count
      nOcn = cfg_ocn_pet_count
      nIce = 0
      if (use_ice) nIce = cfg_ice_pet_count

      if (use_ice .and. nIce <= 0) then
        ! Automático: o que não foi fixado é dividido em partes ~iguais.
        if (nAtm <= 0 .and. nOcn <= 0) then
          nAtm = petCount / 3
          nOcn = petCount / 3
          nIce = petCount - nAtm - nOcn
        else if (nAtm <= 0) then
          nAtm = (petCount - nOcn) / 2
          nIce = petCount - nAtm - nOcn
        else if (nOcn <= 0) then
          nOcn = (petCount - nAtm) / 2
          nIce = petCount - nAtm - nOcn
        else
          nIce = petCount - nAtm - nOcn
        end if
      else if (nAtm <= 0 .and. nOcn <= 0) then
        nAtm = (petCount - nIce + 1) / 2   ! metade, arredondando p/ cima
        nOcn = petCount - nAtm - nIce
      else if (nAtm <= 0) then
        nAtm = petCount - nOcn - nIce
      else if (nOcn <= 0) then
        nOcn = petCount - nAtm - nIce
      end if

      if (nAtm < 1 .or. nOcn < 1 .or. (use_ice .and. nIce < 1) &
          .or. nAtm + nOcn + nIce /= petCount) then
        write(msg,'(A,I0,A,I0,A,I0,A,I0,A)') &
          'ESM: ERRO particao split invalida — nAtm=', nAtm, &
          ' nOcn=', nOcn, ' nIce=', nIce, &
          ' devem somar petCount=', petCount, '.'
        call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_ERROR)
        rc = ESMF_FAILURE; return
      end if

      allocate(atmPetList(nAtm)); atmPetList = [(i-1,      i=1,nAtm)]
      allocate(ocnPetList(nOcn)); ocnPetList = [(nAtm+i-1, i=1,nOcn)]

      if (use_ice) then
        allocate(icePetList(nIce))
        icePetList = [(nAtm+nOcn+i-1, i=1,nIce)]
        write(msg,'(A,A,A,I0,A,I0,A,I0,A,I0,A,I0,A)') &
          'ESM: layout SPLIT (execucao ', trim(exec_str), &
          ') — ATM=PET[0..', nAtm-1, '] OCN=PET[', &
          nAtm, '..', nAtm+nOcn-1, '] ICE=PET[', nAtm+nOcn, '..', &
          petCount-1, '] MED=todos'
      else
        allocate(icePetList(0))
        write(msg,'(A,A,A,I0,A,I0,A,I0,A)') &
          'ESM: layout SPLIT (execucao ', trim(exec_str), &
          ') — ATM=PET[0..', nAtm-1, '] OCN=PET[', &
          nAtm, '..', petCount-1, '] MED=todos (ICE desativado)'
      end if
      call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)
    else
      allocate(atmPetList(petCount)); atmPetList = medPetList
      allocate(ocnPetList(petCount)); ocnPetList = medPetList
      if (use_ice) then
        allocate(icePetList(petCount)); icePetList = medPetList
        call ESMF_LogWrite( &
          'ESM: layout SHARED (execucao '//trim(exec_str)// &
          ') — MPAS, MED, OCN e ICE em todos os PETs', ESMF_LOGMSG_INFO)
      else
        allocate(icePetList(0))
        call ESMF_LogWrite( &
          'ESM: layout SHARED (execucao '//trim(exec_str)// &
          ') — MPAS, MED e OCN em todos os PETs', ESMF_LOGMSG_INFO)
      end if
    end if

    !--------------------------------------------------------------------------
    ! Componente MPAS (MONAN-A 2.0)
    !--------------------------------------------------------------------------
    call AddModelCompWithClock(driver, MPAS_LABEL, MPAS_SetServices, &
      atmPetList, driverClock, mpasComp, rc)
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
    ! (driverClock já foi obtido no início desta rotina — sem nova busca.)
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
    call AddModelCompWithClock(driver, MED_LABEL, MED_SetServices, &
      medPetList, driverClock, medComp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompAttributeSet(medComp, name="Verbosity", value="high", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! ── Ler nuopc.input para obter cfg_use_datm / cfg_use_docn ─────────────
    ! O rc de config_read era descartado aqui (a chamada NUOPC seguinte o
    ! sobrescrevia), de modo que um erro de configuração — rc=2, por exemplo
    ! um pet_layout invalido — passava despercebido neste ponto. Usa-se uma
    ! variável própria para não colidir com o rc das chamadas ESMF/NUOPC.
    call config_read(rc=cfg_rc)
    if (cfg_rc == 2) then
      call ESMF_LogWrite('ESM: ERRO em config_read (nuopc.input invalida) — '// &
        'ver mensagens [mpas_cap_config] na saida padrao.', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE; return
    end if
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
      call AddModelCompWithClock(driver, OCN_LABEL, DOCN_SetServices, &
        ocnPetList, driverClock, ocnComp, rc)
      write(*,'(A)') '[ESM] OCN: DOCN OISST ativo (use_docn=T, nuopc_mode)'
    else
      call AddModelCompWithClock(driver, OCN_LABEL, OCN_SetServices, &
        ocnPetList, driverClock, ocnComp, rc)
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
    ! Componente ICE (SIS2 dinâmico)
    !
    ! Componente NUOPC próprio, não um subcomponente embutido no OCN. Só é
    ! registrado quando use_ice está ligado; caso contrário nada aqui executa e
    ! o sistema fica idêntico ao de antes desta integração.
    !--------------------------------------------------------------------------
    if (use_ice) then
      call AddModelCompWithClock(driver, ICE_LABEL, ICE_SetServices, &
        icePetList, driverClock, iceComp, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      call NUOPC_CompAttributeSet(iceComp, name="Verbosity", value="high", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      ! Mesma justificativa do OCN: o SIS2 também usa o gerenciador de tempo
      ! próprio do FMS internamente, e a validação de timestamp do NUOPC
      ! abortaria o sistema por divergências pequenas e esperadas.
      call NUOPC_CompAttributeSet(iceComp, name="timeStampValidation", &
        value="false", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      call ESMF_LogWrite('ESM: componente ICE (SIS2) registrado', &
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
    call AddConnectorWithClock(driver, MPAS_LABEL, MED_LABEL, &
      CPL_SetServices, driverClock, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! 2. OCN → MED : So_t → bulk formula do mediador
    !--------------------------------------------------------------------------
    call AddConnectorWithClock(driver, OCN_LABEL, MED_LABEL, &
      CPL_SetServices, driverClock, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! 3. MED → OCN : 14 campos de fluxo → MOM6
    !--------------------------------------------------------------------------
    call AddConnectorWithClock(driver, MED_LABEL, OCN_LABEL, &
      CPL_SetServices, driverClock, rc)
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
      call AddConnectorWithClock(driver, MED_LABEL, MPAS_LABEL, &
        CPL_SetServices, driverClock, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call ESMF_LogWrite( &
        'ESM: conector 4 = MED -> MPAS (MOM6 — regrid conservativo)', &
        ESMF_LOGMSG_INFO)
    else
      call AddConnectorWithClock(driver, OCN_LABEL, MPAS_LABEL, &
        CPL_SetServices, driverClock, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call ESMF_LogWrite( &
        'ESM: conector 4 = OCN -> MPAS (DOCN OISST — redistribuicao)', &
        ESMF_LOGMSG_INFO)
    end if

    !--------------------------------------------------------------------------
    ! 5. MED -> ICE : forçante atmosférica (Faxa_*) + SST/correntes (So_*)
    ! 6. ICE -> MED : Si_ifrac real, que substitui a fórmula aproximada do OCN
    !
    ! O mediador já está preparado para isso: MED_cap.F90 anuncia e realiza
    ! Si_ifrac_sis2 no importState, e med_cap_methods.F90 o sobrescreve em
    ! RouteOcnToAtm. Ver a ressalva sobre grades no comentário daquela rotina.
    !--------------------------------------------------------------------------
    if (use_ice) then
      call AddConnectorWithClock(driver, MED_LABEL, ICE_LABEL, &
        CPL_SetServices, driverClock, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      call AddConnectorWithClock(driver, ICE_LABEL, MED_LABEL, &
        CPL_SetServices, driverClock, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      call ESMF_LogWrite( &
        'ESM: conectores 5/6 = MED <-> ICE (SIS2) registrados', &
        ESMF_LOGMSG_INFO)
    end if

    deallocate(atmPetList, ocnPetList, medPetList, icePetList)

    call ESMF_LogWrite( &
      'ESM: componentes e conectores registrados', &
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
    logical                 :: is_concurrent

    rc = ESMF_SUCCESS

    ! Eixo TEMPORAL, independente do eixo espacial (cfg_pet_layout, tratado em
    ! SetModelServices). A RunSequence sequencial abaixo é válida tanto com
    ! pet_layout=shared quanto com pet_layout=split: o driver NUOPC executa
    ! cada componente apenas nos PETs de que ele é membro, e os conectores
    ! rodam na união dos PETs de origem e destino. Já a RunSequence
    ! concorrente EXIGE pet_layout=split, o que config_read garante.
    is_concurrent = (trim(cfg_coupling_mode) == 'concurrent')

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
    !
    ! Quatro variantes: {sequential, concurrent} × {Fase 1 DOCN, Fase 2 MOM6}.
    !
    ! No modo CONCORRENTE, as linhas "MPAS" e "OCN" aparecem CONSECUTIVAS e sem
    ! conector entre elas → o driver NUOPC as executa em paralelo (cada PET só
    ! roda o componente do qual é membro; ATM e OCN estão em PETs disjuntos).
    ! O mediador entrega no início do passo os campos calculados ao FINAL do
    ! passo anterior (lag de 1 dt_coupling — padrão em acoplamento concorrente,
    ! equivalente ao "ocean lag" do CESM/UFS; inicializado por DataInitialize).
    if (is_concurrent) then
      if (use_med_to_mpas .and. cfg_use_sis2_dynamic) then
        ! ── Fase 2 CONCORRENTE (MOM6 dinâmico) + ICE (SIS2) ─────────────────
        runSeqFF = NUOPC_FreeFormatCreate(stringList=(/ &
          line1,              &  ! "@<dt_coupling>    "
          "  MED -> MPAS     ", &  ! SST/gelo/correntes (t-1) -> ATM (regrid)
          "  MED -> OCN      ", &  ! 14 fluxos (t-1) -> MOM6
          "  MED -> ICE      ", &  ! forcante ATM + SST/correntes (t-1) -> SIS2
          "  MPAS            ", &  ! ATM avanca   ┐
          "  OCN             ", &  ! OCN avanca   ┤ concorrentes (PETs disjuntos)
          "  ICE             ", &  ! SIS2 avanca  ┘
          "  MPAS -> MED     ", &  ! 9 campos _mpas -> mediador
          "  OCN -> MED      ", &  ! So_t, So_u, So_v -> mediador
          "  ICE -> MED      ", &  ! Si_ifrac real (Si_ifrac_sis2) -> mediador
          "  MED             ", &  ! RouteOcnToAtm + bulk NCAR (p/ proximo passo)
          "@                 " /), rc=rc)
        call ESMF_LogWrite('ESM: RunSequence Fase 2 CONCORRENTE + ICE (SIS2)', &
          ESMF_LOGMSG_INFO)
      else if (use_med_to_mpas) then
        ! ── Fase 2 CONCORRENTE (MOM6 dinâmico) ──────────────────────────────
        runSeqFF = NUOPC_FreeFormatCreate(stringList=(/ &
          line1,              &  ! "@<dt_coupling>    "
          "  MED -> MPAS     ", &  ! SST/gelo/correntes (t-1) -> ATM (regrid)
          "  MED -> OCN      ", &  ! 14 fluxos (t-1) -> MOM6
          "  MPAS            ", &  ! ATM avanca   ┐ concorrentes (PETs disjuntos)
          "  OCN             ", &  ! OCN avanca   ┘
          "  MPAS -> MED     ", &  ! 9 campos _mpas -> mediador
          "  OCN -> MED      ", &  ! So_t, Si_ifrac, So_u, So_v -> mediador
          "  MED             ", &  ! RouteOcnToAtm + bulk NCAR (p/ proximo passo)
          "@                 " /), rc=rc)
        call ESMF_LogWrite('ESM: RunSequence Fase 2 CONCORRENTE (MED->MPAS)', &
          ESMF_LOGMSG_INFO)
      else
        ! ── Fase 1 CONCORRENTE (DOCN) ───────────────────────────────────────
        runSeqFF = NUOPC_FreeFormatCreate(stringList=(/ &
          line1,              &  ! "@<dt_coupling>    "
          "  OCN -> MPAS     ", &  ! SST (t-1) -> sfc_input MONAN-A (direto)
          "  MED -> OCN      ", &  ! 14 fluxos (t-1) -> OCN (DOCN ignora)
          "  MPAS            ", &  ! ATM avanca   ┐ concorrentes (PETs disjuntos)
          "  OCN             ", &  ! OCN avanca   ┘
          "  MPAS -> MED     ", &  ! 9 campos _mpas -> mediador
          "  OCN -> MED      ", &  ! So_t, Si_ifrac, So_u, So_v -> mediador
          "  MED             ", &  ! calcula fluxos bulk NCAR (p/ proximo passo)
          "@                 " /), rc=rc)
        call ESMF_LogWrite('ESM: RunSequence Fase 1 CONCORRENTE (OCN->MPAS)', &
          ESMF_LOGMSG_INFO)
      end if
    else
      if (use_med_to_mpas .and. cfg_use_sis2_dynamic) then
        ! ── Fase 2 SEQUENCIAL (MOM6 dinâmico) + ICE (SIS2) ──────────────────
        ! Equivalente sequencial da variante concorrente com gelo. Vale com
        ! QUALQUER pet_layout: em 'shared' os três componentes dividem todos os
        ! PETs; em 'split' cada um tem seu bloco disjunto e os demais ficam
        ! ociosos durante a fase alheia. O que 'sequential' determina é a ORDEM
        ! no tempo, não a ocupação de PETs; os dois eixos são independentes.
        !
        ! Sobre a posição de 'MED -> ICE': ela vem depois de 'OCN' porque essa é
        ! a ordenação já exercitada em execução. Note que a escolha NÃO muda o
        ! dado entregue ao gelo: o mediador executou uma única vez, na linha
        ! 'MED' acima, e não roda de novo entre 'OCN' e 'MED -> ICE'. Portanto o
        ! SIS2 recebe o estado oceânico que o mediador capturou ANTES de o OCN
        ! avançar, e não o do mesmo passo. Essa defasagem de meio passo é da
        ! mesma natureza das demais do acoplamento sequencial. Para o gelo ver o
        ! oceano já avançado seria preciso um segundo 'OCN -> MED' seguido de
        ! nova execução do 'MED', o que dobraria o custo do mediador.
        runSeqFF = NUOPC_FreeFormatCreate(stringList=(/ &
          line1,              &  ! "@<dt_coupling>    "
          "  OCN -> MED      ", &  ! So_t, So_u, So_v -> mediador
          "  ICE -> MED      ", &  ! Si_ifrac real (Si_ifrac_sis2) -> mediador
          "  MPAS -> MED     ", &  ! 9 campos _mpas -> mediador
          "  MED             ", &  ! RouteOcnToAtm + bulk NCAR
          "  MED -> MPAS     ", &  ! SST/gelo/correntes -> MPAS (regrid conserv.)
          "  MPAS            ", &  ! dinamica + fisica ATM com SST do MED
          "  MED -> OCN      ", &  ! 14 fluxos Foxx_*/Faxa_* -> MOM6
          "  OCN             ", &  ! avanca MOM6 dinamico
          "  MED -> ICE      ", &  ! forcante ATM + SST/correntes -> SIS2
          "  ICE             ", &  ! avanca SIS2
          "@                 " /), rc=rc)
        call ESMF_LogWrite('ESM: RunSequence Fase 2 SEQUENCIAL + ICE (SIS2)', &
          ESMF_LOGMSG_INFO)
      else if (use_med_to_mpas) then
        ! ── Fase 2: MOM6 dinâmico — OCN e ATM exportam ao MED primeiro ───────
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
        ! ── Fase 1: DOCN — conector direto OCN→MPAS com regrid bilinear ──────
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
    end if
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! As variantes de Fase 1 (DOCN) não incluem os passos do ICE, e isso é por
    ! construção: o DOCN é um oceano sintético, com SST lida de arquivo OISST e
    ! sem estado oceânico prognóstico a que o SIS2 possa se acoplar. Se o gelo
    ! for pedido junto com a Fase 1, o componente ICE chega a ser registrado no
    ! driver mas nunca é executado pela sequência, e ficaria inerte sem sinal
    ! claro no log. O aviso abaixo torna isso visível.
    !
    ! A Fase 2 (MOM6 dinâmico) inclui o ICE nos dois modos, concorrente e
    ! sequencial. Note que config_read já rejeita a combinação de gelo com
    ! use_docn; este aviso cobre o caso restante, em que use_docn é falso mas
    ! use_med_to_mpas também é, e o acoplamento vai direto de OCN para MPAS.
    if (cfg_use_sis2_dynamic .and. .not. use_med_to_mpas) then
      call ESMF_LogWrite('ESM: AVISO — use_sis2_dynamic=.true. mas a ' // &
        'RunSequence selecionada e Fase 1 (oceano sintetico), que NAO ' // &
        'inclui os passos do ICE. O SIS2 sera registrado porem nunca ' // &
        'executado. Use MOM6 dinamico (use_med_to_mpas) para ativar o gelo.', &
        ESMF_LOGMSG_WARNING)
    end if

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
