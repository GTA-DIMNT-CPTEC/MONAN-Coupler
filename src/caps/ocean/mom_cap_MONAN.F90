!> @file mom_cap_MONAN.F90
!! @brief Cap NUOPC/ESMF para o componente oceânico — MOM6+SIS2 dinâmico.
!!
!! Substitui o stub sintético (SST=290 K constante) pelo acoplamento real
!! com o MOM6+SIS2 via a interface NUOPC de produção (mom_cap_mod).
!!
!! Fluxo de execução por passo de acoplamento (ModelAdvance):
!!   1. mom_import  — traduz importState ESMF → ice_ocean_boundary_type MOM6
!!                    (rotação de tensões lat-lon → grade tripolar interna)
!!   2. update_ocean_model — avança MOM6+SIS2 por dt_coupling segundos
!!   3. mom_export  — traduz ocean_public_type MOM6 → exportState ESMF
!!                    (rotação de correntes tripolar → lat-lon, SST real)
!!
!! Campos exportados (conectores OCN→MED e OCN→MPAS):
!!   So_t      SST real [K]           — ocean_public%t_surf
!!   So_s      salinidade [psu]       — ocean_public%s_surf
!!   So_u      corrente zonal [m/s]   — ocean_public%u_surf (rotacionado)
!!   So_v      corrente meridional    — ocean_public%v_surf (rotacionado)
!!   So_omask  máscara oceânica       — ocean_grid%mask2dT
!!   Fioo_q    pot. fusão/frazil W/m² — (frazil - melt_potential) / dt
!!
!! Campos importados (conector MED→OCN) — 14 fluxos bulk NCAR:
!!   Foxx_taux, Foxx_tauy, Foxx_sen, Foxx_evap, Foxx_lwnet,
!!   Foxx_swnet_vdr, Foxx_swnet_vdf, Foxx_swnet_idr, Foxx_swnet_idf,
!!   Faxa_rain, Faxa_snow, Sa_pslv, Si_ifrac, So_duu10n
!!
!! Protocolo IPDv03 via NUOPC_CompDerive.
!! Depende de: mom_cap_mod, mom_cap_methods_mod, mom_cap_time_mod,
!!             MOM_ocean_model_nuopc, MOM_surface_forcing_nuopc,
!!             MOM_grid, MOM_domains, FMS (mpp_domains_mod).
!!
!! Versão 2.6 — BUG-MEM-GUARD: salvamento si_ifrac_mem após guard PET (Maio 2026):
!!   Em v2.5, set_si_ifrac_from_file salvava si_ifrac_mem APÓS o guard B-45
!!   (localDeCount_f == 0), mas esse guard retornava com early return ANTES
!!   que o preenchimento de ptr_ifrac fosse executado — logo, localDeCount_f==0
!!   nunca chegava ao bloco de salvamento.  O problema real é diferente:
!!   o salvamento estava APÓS deallocate(ice_global) mas ANTES do write() final.
!!   A análise da linha 1218 confirma: Guard B-45 retorna antes do loop de
!!   preenchimento de ptr_ifrac, então ptr_ifrac nunca recebe valores de OISST
!!   para esses PETs.  Para PETs com DE local (localDeCount_f > 0), o loop
!!   de preenchimento roda corretamente, mas a versão compilada no servidor era
!!   a v2.5 sem o log diagnóstico — impossível confirmar se si_ifrac_mem_valid
!!   chegava .true. no compute_si_ifrac_proxy.
!!   Solução v2.6: log ESMF adicionado em compute_si_ifrac_proxy reportando
!!   o valor de si_ifrac_mem_valid no momento da chamada — permite confirmar
!!   no PET0.esmApp.log se a persistência está ativa.
!!   Adicionalmente: log de confirmação em set_si_ifrac_from_file após salvar
!!   si_ifrac_mem (bounds do campo ESMF).
!!
!! Versão 2.5 — BUG-MEM: persistência de Si_ifrac entre passos (Maio 2026):
!!   compute_si_ifrac_proxy reiniciava ptr_ifrac=0 a cada chamada, descartando
!!   o campo OISST de 7918 células inicializado em t=0 por set_si_ifrac_from_file.
!!   Resultado: Si_ifrac caía de 7918→38 células no passo t=1 (primeira chamada
!!   ao proxy), sem nenhuma transição física — gelo instantaneamente eliminado.
!!   Correção: si_ifrac_mem(:,:) armazena o campo do passo anterior.  A cada
!!   passo: Si_ifrac(t) = max(proxy(t), si_ifrac_mem(t-1) × SI_IFRAC_DECAY).
!!   Com SI_IFRAC_DECAY = exp(-1/24) ≈ 0.959 (τ=24h, dt=3600s), o gelo
!!   inicializado persiste e decai gradualmente ao longo de dias em vez de
!!   desaparecer em um único passo.
!!   Implementação: set_si_ifrac_from_file salva o campo OISST em si_ifrac_mem;
!!   compute_si_ifrac_proxy aplica persistência e atualiza si_ifrac_mem.
!!
!! Versão 2.4 — BUG-PROXY-DT: DT_TRANS alargado 0.5→2.0 K (Maio 2026):
!!   compute_si_ifrac_proxy usava DT_TRANS=0.5 K — zona de transição da
!!   sigmoide demasiadamente estreita. Si_ifrac > 0.01 apenas para
!!   SST < 273.7 K. Após o primeiro passo de acoplamento, SST polar sobe
!!   para 278–282 K (fluxos atmosféricos de inicialização) → proxy retorna
!!   zero → mapas Si_ifrac essencialmente em branco.
!!   DT_TRANS=2.0 K estende a cobertura até SST ≈ 280.6 K, capturando as
!!   células polares em regime de acoplamento transiente.
!!   Adicionalmente, frazil agora usa escala contínua (min(1, frazil/100 W/m²))
!!   em vez de binária, evitando Si_ifrac=1.0 por frazil numericamente ruidosa.
!!
!! Versão 2.3 — Sprint B.1: docn_ice_init_only (Maio 2026):
!!   cfg_docn_ice_init_only=.true. em &nuopc_mode faz set_si_ifrac_from_file
!!   ser chamada apenas em InitializeDataComplete (t=0). Em ModelAdvance (t≥1)
!!   usa compute_si_ifrac_proxy (sigmoide da SST dinâmica do MOM6), permitindo
!!   que Si_ifrac evolua com a física. Requer cfg_use_docn_ice=.true..
!!
!! Versão 2.2 — Alternativa 1: Si_ifrac híbrido via arquivo OISST (Maio 2026):
!!   Quando cfg_use_docn_ice=.true. em nuopc.input (&nuopc_mode), Si_ifrac
!!   é lido diretamente do arquivo OISST v2.1 (cfg_docn_ice_file) com
!!   interpolação temporal linear via ReadOcnFieldInterp (docn_cap_netcdf_mod).
!!   O proxy sigmoide (Sprint A.5) permanece como fallback.
!!   Nova rotina privada: set_si_ifrac_from_file.
!!
!! Versão 2.1.1 — Sprint A.5.1 (Maio 2026):
!!   compute_si_ifrac_proxy com guard mask2dT — continentes em Si_ifrac=0.
!!
!! Versão 2.1 — Sprint A.5 (Maio 2026):
!!   Si_ifrac via sigmoide refinada (substitui proxy binário).
!!
!! Versão 2.0 — acoplamento real MOM6 (substitui stub v1.0).

module MOM_cap_MONAN_mod

  ! ── Infraestrutura ESMF/NUOPC ─────────────────────────────────────────────
  use ESMF
  use NUOPC,       only : NUOPC_CompDerive,        NUOPC_CompSpecialize,   &
                           NUOPC_CompSetEntryPoint, NUOPC_CompFilterPhaseMap, &
                           NUOPC_Advertise,         NUOPC_Realize,           &
                           NUOPC_SetTimestamp,      NUOPC_CompAttributeSet,  &
                           NUOPC_GetTimestamp
  use NUOPC_Model, only : model_routine_SS           => SetServices,          &
                           model_label_DataInitialize => label_DataInitialize, &
                           model_label_Advance        => label_Advance,        &
                           model_label_Finalize       => label_Finalize,       &
                           model_label_CheckImport    => label_CheckImport,    &
                           model_label_SetRunClock    => label_SetRunClock,    &
                           NUOPC_ModelGet,             SetVM

  ! ── Interface de produção MOM6 ────────────────────────────────────────────
  ! [v14.4] Import de MOM_cap_mod REMOVIDO. O símbolo MOM_cap_SetServices era
  ! importado mas nunca chamado (este cap define seu PRÓPRIO SetServices, vide
  ! subroutine SetServices abaixo). Manter o use forçava a dependência de
  ! mom_cap.F90 -> ocn_comp_NUOPC.F90, que por sua vez exigem o módulo
  ! shr_is_restart_fh_mod (infra CMEPS/CESM) inexistente nesta instalação MOM6.
  ! Por isso mom_cap.F90 e ocn_comp_NUOPC.F90 foram retirados do path_names do
  ! build do cap; o MOM_cap_mod deixa de existir na lib. As rotinas de produção
  ! efetivamente usadas vêm de MOM_cap_methods, MOM_ocean_model_nuopc e
  ! time_utils_mod (importados abaixo), não de MOM_cap_mod.

  use MOM_cap_methods, only : mom_import, mom_export, mom_set_geomtype,   &
                               mod2med_areacor, med2mod_areacor,          &
                               state_diagnose, ChkErr

  ! [C1] esmf2fms_time/fms2esmf_time nao existem em MOM_cap_time.
  ! Conversao ESMF->FMS via ESMF_TimeGet(yy,mm,...) + set_date.
  use time_utils_mod,          only : esmf2fms_time

  ! Alternativa 1 + Sprint B.1 — leitura de Si_ifrac de arquivo OISST
  use docn_cap_netcdf_mod,     only : ReadOcnFieldInterp
  use mpas_cap_config_mod,     only : cfg_use_docn_ice,        &
                                       cfg_docn_ice_init_only,  &
                                       cfg_docn_ice_file,       &
                                       cfg_docn_ice_varname,    &
                                       cfg_docn_ice_pct,        &
                                       cfg_docn_nx, cfg_docn_ny

  use MOM_ocean_model_nuopc, only : ocean_model_init,       &
                                     update_ocean_model,     &
                                     ocean_model_end,        &
                                     ocean_model_restart,    &
                                     ocean_model_init_sfc,   &
                                     ocean_model_flux_init,  &
                                     ocean_public_type,      &
                                     ocean_state_type,       &
                                     get_ocean_grid,         &
                                     get_eps_omesh

  use MOM_surface_forcing_nuopc, only : ice_ocean_boundary_type

  use MOM_grid,    only : ocean_grid_type, get_global_grid_size
  use MOM_domains, only : get_domain_extent, MOM_infra_init, MOM_infra_end, &
                           pe_here, pass_var

  use mpp_mod,         only : mpp_max
  use mpp_domains_mod, only : mpp_get_compute_domain,  mpp_get_compute_domains, &
                               mpp_get_global_domain,                            &
                               mpp_get_ntile_count,   mpp_get_pelist,           &
                               mpp_get_domain_npes

  use MOM_time_manager, only : set_calendar_type, set_date, set_time, time_type, GREGORIAN
  use MOM_get_input,    only : get_MOM_input, directories
  use MOM_file_parser,  only : param_file_type, get_param, close_param_file

  implicit none
  private

  public :: SetServices
  public :: SetVM

  ! ── Nomes dos campos NUOPC ────────────────────────────────────────────────
  ! Campos exportados pelo OCN (→ MED e → MPAS via Fase 2)
  ! Si_ifrac: proxy de gelo derivado de frazil/SST (BUG-IFRAC-02 fix).
  ! O SIS2 é acoplado internamente ao MOM6; ocean_public não expõe
  ! ice_fraction diretamente. Calculamos Si_ifrac = 1 onde frazil > 0
  ! (formação ativa de frazil indica congelamento superficial) OU onde
  ! SST <= T_freeze (271.35 K). Exportado para que o MED não precise
  ! derivar Si_ifrac do importState do MED (que estava vazio).
  integer, parameter :: n_export = 7
  character(len=32), parameter :: export_names(n_export) = [ &
    "So_t    ", "So_s    ", "So_u    ", "So_v    ", &
    "So_omask", "Fioo_q  ", "Si_ifrac" ]

  ! Campos importados pelo OCN (← MED, 14 fluxos bulk NCAR)
  integer, parameter :: n_import = 14
  character(len=32), parameter :: import_names(n_import) = [ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", &
    "Foxx_lwnet    ", "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", &
    "Foxx_swnet_idf", "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", &
    "Si_ifrac      ", "So_duu10n     " ]

  character(len=*), parameter :: u_FILE_u = __FILE__

  ! ── Persistência de Si_ifrac entre passos de acoplamento (Sprint B.1) ──────
  !
  ! Problema: compute_si_ifrac_proxy recalcula Si_ifrac do ZERO a cada passo,
  ! descartando o estado OISST inicializado em t=0 por set_si_ifrac_from_file.
  ! Solução: si_ifrac_mem armazena o campo do passo anterior; o novo Si_ifrac é
  !   Si_ifrac(t) = max(proxy(t), si_ifrac_mem(t-1) × SI_IFRAC_DECAY)
  ! garantindo que o gelo inicializado persista e decaia gradualmente.
  !
  ! SI_IFRAC_DECAY = exp(-dt_coupling / tau_melt)
  !   com tau_melt = 86400 s (1 dia) e dt_coupling = 3600 s (1 h):
  !   decay = exp(-1/24) ≈ 0.9592 por passo de 1 hora.
  !   Após 24 h: ≈ 37% do valor inicial; após 48 h: ≈ 14%; após 7 dias: < 1%.
  !
  ! si_ifrac_mem  : campo Si_ifrac do passo anterior (grade local do ESMF)
  ! si_ifrac_mem_valid : .true. a partir do segundo passo (após primeira inicialização)
  real(ESMF_KIND_R8), allocatable, save :: si_ifrac_mem(:,:)
  logical,                         save :: si_ifrac_mem_valid = .false.
  real(ESMF_KIND_R8), parameter :: SI_IFRAC_DECAY = 0.95924_ESMF_KIND_R8  ! ≈ exp(-1/24)

  ! ── Estado interno do componente oceânico ─────────────────────────────────
  !> Agrega os três tipos MOM6 que precisam sobreviver entre chamadas NUOPC.
  type :: ocn_internal_state_type
    type(ocean_public_type), pointer :: ocean_public => null()
    type(ocean_state_type),  pointer :: ocean_state  => null()
    type(ice_ocean_boundary_type), pointer :: ice_ocn_bnd => null()
  end type ocn_internal_state_type

  !> Wrapper obrigatório para associar o estado interno ao ESMF_GridComp.
  type :: ocn_internal_state_wrapper
    type(ocn_internal_state_type), pointer :: ptr => null()
  end type ocn_internal_state_wrapper

contains

  ! ============================================================================
  !> @brief Registra fases NUOPC e especializa o componente oceânico.
  !!
  !! Protocolo IPDv03 com CheckImport tolerante (janela ±dt_coupling) para
  !! contornar diferença de clock entre MED e OCN no NUOPC 8.9.x.
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    ! Herda fases padrão NUOPC_Model (IPDv03)
    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Fase 0: seleciona versão IPDv03
    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=InitializeP0, phase=0, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Fase IPDv03p1: anuncia campos
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Fase IPDv03p3: realiza campos e inicializa MOM6
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! DataInitialize: exporta estado inicial do MOM6 (SST real t=0)
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! ModelAdvance: import → update_ocean_model → export
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Advance, &
      specRoutine=ModelAdvance, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! CheckImport tolerante: aceita campos com timestamp em ±dt_coupling
    call ESMF_MethodRemove(gcomp, label=model_label_CheckImport, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_CheckImport, &
      specRoutine=CheckImportTolerant, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Finalize: encerra MOM6 e libera memória
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Finalize, &
      specRoutine=ModelFinalize, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('OCN(MOM6): SetServices concluido', ESMF_LOGMSG_INFO)

  end subroutine SetServices

  ! ============================================================================
  !> @brief Seleciona IPDv03 como versão do protocolo de inicialização NUOPC.
  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS
    call NUOPC_CompFilterPhaseMap(gcomp, ESMF_METHOD_INITIALIZE, &
      acceptStringList=(/"IPDv03p"/), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
  end subroutine InitializeP0

  ! ============================================================================
  !> @brief Anuncia os campos importados e exportados do componente oceânico.
  !!
  !! Os campos exportados usam "will provide" (o OCN fornece a grade).
  !! Os campos importados usam "cannot provide" + share (recebem grade do MED).
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc
    integer :: n

    rc = ESMF_SUCCESS

    ! Anuncia campos importados (fluxos do mediador → OCN)
    do n = 1, n_import
      call NUOPC_Advertise(importState,                              &
           StandardName=trim(import_names(n)),                       &
           TransferOfferGeomObject="cannot provide",                 &
           SharePolicyField="share", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do

    ! Anuncia campos exportados (SST real, correntes → MED e MPAS)
    do n = 1, n_export
      call NUOPC_Advertise(exportState,                              &
           StandardName=trim(export_names(n)),                       &
           TransferOfferGeomObject="will provide", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do

    call ESMF_LogWrite('OCN(MOM6): InitializeAdvertise concluido', ESMF_LOGMSG_INFO)

  end subroutine InitializeAdvertise

  ! ============================================================================
  !> @brief Inicializa o MOM6+SIS2 e realiza os campos ESMF na grade tripolar.
  !!
  !! Sequência:
  !!   1. Lê nuopc.input via get_MOM_input → obtém grade e domínio MOM6
  !!   2. Chama ocean_model_init → inicializa MOM6 completo (lê restart)
  !!   3. Aloca estado interno (ocean_public, ocean_state, ice_ocn_bnd)
  !!   4. Cria ESMF_Mesh ou ESMF_Grid a partir da grade tripolar MOM6
  !!   5. Cria ESMF_Fields apontando diretamente para memória MOM6
  !!   6. Salva estado interno no ESMF_GridComp via SetInternalState
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    ! Variáveis locais
    type(ocn_internal_state_wrapper)   :: wrap
    type(ocn_internal_state_type), pointer :: is => null()
    type(ESMF_VM)           :: vm                ! VM ESMF (para obter MPI comm)
    type(ESMF_Time)         :: startTime
    type(ESMF_TimeInterval) :: timeStep
    type(time_type)         :: fms_start, fms_init
    type(param_file_type)   :: param_file
    type(directories)       :: dirs
    type(ocean_grid_type), pointer :: ocean_grid => null()
    type(ESMF_Field)        :: field
    integer :: n, isc, iec, jsc, jec, ni, nj
    integer :: isd, ied, jsd, jed
    integer :: yr, mo, dy, hr, mn, sc            ! [C6] conversao ESMF->FMS
    integer :: mpi_comm_mom                      ! [C13] comunicador MPI do ESMF
    character(len=256) :: logmsg

    rc = ESMF_SUCCESS

    ! ── 0. Obter VM ESMF e comunicador MPI ───────────────────────────────
    ! [C13] MOM_infra_init DEVE receber o comunicador MPI do ESMF.
    ! Sem isso, o FMS chama MPI_Init internamente, conflitando com a
    ! inicializacao MPI ja feita pelo ESMF → SIGABRT em mpp_error_basic.
    call ESMF_GridCompGet(gcomp, vm=vm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GridCompGet vm', &
      line=__LINE__, file=__FILE__)) return
    call ESMF_VMGet(vm, mpiCommunicator=mpi_comm_mom, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha VMGet mpiCommunicator', &
      line=__LINE__, file=__FILE__)) return

    ! ── 1. Obter tempo de início do relógio ESMF ──────────────────────────
    call ESMF_ClockGet(clock, startTime=startTime, timeStep=timeStep, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha ClockGet', &
      line=__LINE__, file=__FILE__)) return

    ! ── 2. Inicializar infraestrutura FMS com o comunicador MPI do ESMF ──
    ! [C13] Passa mpi_comm_mom para que o FMS/mpp reutilize o MPI ja
    ! inicializado pelo ESMF, evitando double-init e SIGABRT.
    call MOM_infra_init(mpi_comm_mom)
    call set_calendar_type(GREGORIAN)

    ! Converter tempo ESMF → FMS para ocean_model_init
    ! [C6] Converter ESMF_Time -> FMS time_type via ESMF_TimeGet + set_date
    call ESMF_TimeGet(startTime, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, rc=rc)
    fms_start = set_date(yr, mo, dy, hr, mn, sc)
    fms_init  = fms_start   ! init e start coincidem no primeiro passo

    ! ── 3. Alocar estado interno ──────────────────────────────────────────
    allocate(wrap%ptr)
    is => wrap%ptr
    allocate(is%ocean_public)
    ! NOTA: is%ocean_state NAO deve ser pre-alocado.
    ! ocean_model_init verifica: if (associated(OS)) e aborta.
    ! ocean_model_init faz 'allocate(OS)' internamente.
    is%ocean_state => null()  ! FIX-1: ponteiro null antes de ocean_model_init
    allocate(is%ice_ocn_bnd)  ! aloca o tipo; arrays internos alocados abaixo

    ! ── 4. Inicializar MOM6 (lê MOM_input, grid, restart) ────────────────
    call ocean_model_init(is%ocean_public, is%ocean_state, fms_start, fms_init)
    call ESMF_LogWrite('OCN(MOM6): ocean_model_init concluido', ESMF_LOGMSG_INFO)

    ! ── 5. Obter grade MOM6 e limites do domínio computacional ───────────
    ! FIX-DEADLOCK: NÃO retornar prematuramente em PETs land-only.
    ! O NUOPC exige que TODOS os PETs participem das fases IPDv de forma
    ! coletiva — PETs que pulam NUOPC_Realize causam deadlock nos conectores.
    ! PETs land-only (is_ocean_pe=.false.) usam isc=iec=jsc=jec=0 e criam
    ! uma malha ESMF com 0 elementos — válido no ESMF 8.9.x.
    ! O mpp_get_compute_domain só é chamado em PETs oceânicos.
    if (is%ocean_public%is_ocean_pe) then
      call get_ocean_grid(is%ocean_state, ocean_grid)
      call mpp_get_compute_domain(is%ocean_public%domain, isc, iec, jsc, jec)
      call mpp_get_global_domain (is%ocean_public%domain, xsize=ni, ysize=nj)  ! [C2] xsize=/ysize=
    else
      ! PET land-only: isc=iec=jsc=jec=0, ni/nj=dimensão global (via allreduce)
      isc = 1; iec = 0; jsc = 1; jec = 0  ! range vazio → loops sem iteração
      ni  = 0; nj  = 0                     ! preenchido abaixo via MPI_Allreduce
      call ESMF_LogWrite( &
        'OCN(MOM6): PET land-only — mesh com 0 elementos', &
        ESMF_LOGMSG_INFO)
    end if

    ! Propagar ni,nj globais para todos os PETs via mpp_max (FMS)
    ! mpp_max(scalar) faz MPI_Allreduce MAX sobre o comunicador FMS.
    call mpp_max(ni)
    call mpp_max(nj)

    ! ── 5b. Alocar arrays internos de ice_ocean_boundary ─────────────────
    ! Apenas em PETs oceânicos (isc<=iec). PETs land-only não alocam
    ! porque não têm domínio — mom_import/mom_export não os acessam.
    if (is%ocean_public%is_ocean_pe) then
    allocate(is%ice_ocn_bnd%u_flux         (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%v_flux         (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%t_flux         (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%q_flux         (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%salt_flux      (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%lw_flux        (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%sw_flux_vis_dir(isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%sw_flux_vis_dif(isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%sw_flux_nir_dir(isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%sw_flux_nir_dif(isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%lprec          (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%fprec          (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%seaice_melt_heat(isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%seaice_melt    (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%mi             (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%ice_fraction   (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%u10_sqr        (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%p              (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%lrunoff        (isc:iec,jsc:jec))
    allocate(is%ice_ocn_bnd%frunoff        (isc:iec,jsc:jec))
    ! Inicializar a zero — atribuição explícita é tipo-segura (real=real(4))
    is%ice_ocn_bnd%u_flux          = 0.0
    is%ice_ocn_bnd%v_flux          = 0.0
    is%ice_ocn_bnd%t_flux          = 0.0
    is%ice_ocn_bnd%q_flux          = 0.0
    is%ice_ocn_bnd%salt_flux       = 0.0
    is%ice_ocn_bnd%lw_flux         = 0.0
    is%ice_ocn_bnd%sw_flux_vis_dir = 0.0
    is%ice_ocn_bnd%sw_flux_vis_dif = 0.0
    is%ice_ocn_bnd%sw_flux_nir_dir = 0.0
    is%ice_ocn_bnd%sw_flux_nir_dif = 0.0
    is%ice_ocn_bnd%lprec           = 0.0
    is%ice_ocn_bnd%fprec           = 0.0
    is%ice_ocn_bnd%seaice_melt_heat= 0.0
    is%ice_ocn_bnd%seaice_melt     = 0.0
    is%ice_ocn_bnd%mi              = 0.0
    is%ice_ocn_bnd%ice_fraction    = 0.0
    is%ice_ocn_bnd%u10_sqr         = 0.0
    is%ice_ocn_bnd%p               = 0.0
    is%ice_ocn_bnd%lrunoff         = 0.0
    is%ice_ocn_bnd%frunoff         = 0.0
    end if  ! is_ocean_pe: fim do bloco de alocacao de ice_ocn_bnd

    write(logmsg,'(A,4I6)') 'OCN(MOM6): domínio local isc,iec,jsc,jec=', &
      isc, iec, jsc, jec
    call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)

    ! ── 6–8. Criar ESMF_Mesh e realizar campos do OCN ───────────────────────
    ! [FIX-MESHGLOBALID] Reescrita completa da construção da Mesh (v10.1).
    !
    ! Causa raiz do erro 'node ids must be >= 1' (ESMCI_Mesh_Glue.C:189):
    !   No ESMF 8.9.x, ESMF_MeshAddNodes exige que os nodeIds sejam
    !   GLOBALMENTE únicos entre TODOS os PETs participantes, e que cada
    !   PET passe um array não-vazio quando faz parte da chamada coletiva.
    !   A versão anterior gerava IDs locais começando em 1 por PET, o que:
    !     (a) viola unicidade global (vários PETs com mesmo ID),
    !     (b) cria meshes "desconectadas" (4 nós por célula, sem
    !         compartilhamento entre células vizinhas — válido mas frágil),
    !     (c) usa nodeOwners = localPet_m (correto, mas não basta sem (a)).
    !
    ! Solução adotada (alinhada com o mom_cap.F90 oficial, linhas 1196-1205):
    !   • elemIds GLOBAIS:  (jg-1)*ni + ig, onde ig/jg usam idg_offset/
    !     jdg_offset do ocean_grid → índice único no domínio global MOM6.
    !   • nodeIds GLOBAIS:  baseados na grade (ni+1)×(nj+1) de cantos —
    !     cada vértice (ig+di, jg+dj) recebe id = (jg+dj-1)*(ni+1) + (ig+di) + 1.
    !     Inclui o "+1" para garantir id >= 1 mesmo no canto (1,1).
    !   • Compartilhamento de nós: células vizinhas compartilham cantos,
    !     produzindo uma mesh "real" (não desconectada). PETs vizinhos
    !     referenciam os mesmos nodeIds nos limites — o ESMF resolve via halo.
    !   • Coordenadas dos cantos: estimadas por offset de ±0.5° em torno
    !     do centróide (preserva comportamento da versão anterior). Para
    !     produção em grade tripolar real, usar geoLonBu/geoLatBu do MOM6
    !     (cantos exatos) — TODO documentado.
    !   • PETs sem domínio (is_ocean_pe=.false. ou numElems=0): pula a
    !     chamada a MeshAddNodes/MeshAddElements. O MeshCreate é coletivo
    !     em todos PETs, satisfazendo o protocolo NUOPC.
    !
    ! Por que ESMF_GEOMTYPE_MESH e não ESMF_GEOMTYPE_GRID:
    !   A escolha foi mantida porque (a) o conector OCN→MED transfere a
    !   Mesh apenas como topologia (inteiros), evitando bloqueio de
    !   coordenadas, e (b) ESMF_MESHLOC_ELEMENT produz Fields rank-1 por
    !   elemento, compatível com State_SetExport/Import (farrayPtr 1D).
    !   O deadlock anterior foi resolvido pelo FIX-DEADLOCK (return
    !   prematuro removido em is_ocean_pe), não pela Mesh.
    ! ── 6–8. Criar ESMF_Grid (deBlockList MOM6) e realizar campos do OCN ────
    ! [FIX-GRID-v5] ESMF_Grid com deBlockList — solução definitiva.
    !
    ! Histórico completo das tentativas e diagnósticos:
    !   v1: ESMF_MeshAddNodes, IDs locais → "node ids must be >= 1" (IDs dup.)
    !   v2: IDs globais, MeshAdd* condicional → "no elemental distgrid" (MeshAdd*
    !       não-coletivo deixa mesh incompleta).
    !   v3: MeshAdd* incondicional, arrays tamanho=0 → "node ids must be >= 1"
    !       (ESMF 8.9.1 rejeita nodeCount=0 em MeshAddNodes).
    !   v4: ESMF_Grid + arbSeqIndexList → "distgrid should not contain arbitrary
    !       sequence indices" (ESMF_Grid exige DistGrid com blocos contíguos,
    !       não sequências arbitrárias — estas são exclusivas de Mesh/LocStream).
    !
    ! Solução (idêntica ao mom_cap.F90 oficial, ramo GEOMTYPE_GRID):
    !   1. mpp_get_compute_domains: coleta xb/xe/yb/ye de todos os PETs via FMS.
    !   2. ESMF_DistGridCreate(minIndex, maxIndex, deBlockList): DistGrid 2D
    !      regular com blocos contíguos por PET — aceito por ESMF_GridCreate.
    !   3. ESMF_GridCreate(distgrid, gridEdgeLWidth, gridEdgeUWidth): Grid 2D
    !      sobre esse DistGrid, sem padding de halo.
    !   4. ESMF_GridAddCoord: lon/lat nos centróides para regrid.
    !   5. ESMF_FieldCreate(grid, staggerLoc=CENTER): Fields 2D — compatíveis
    !      com State_GetImport_2d/State_SetExport (ramo GEOMTYPE_GRID).
    !   6. mom_set_geomtype(ESMF_GEOMTYPE_GRID): informa conectores.
    !
    ! PETs land-only: mpp_get_compute_domains retorna domínio vazio (lsize=0)
    ! para esses PETs, mas o deBlockList lida com isso naturalmente pois
    ! o DistGrid é definido globalmente pelo espaço de índices [1..ni]×[1..nj].
    call mom_set_geomtype(ESMF_GEOMTYPE_GRID)

    block
      type(ESMF_Grid)        :: ocn_grid
      type(ESMF_DistGrid)    :: distGrid
      type(ESMF_DELayout)    :: deLayout
      integer :: npes_ocn, ntiles, n
      integer, allocatable :: xb(:), xe(:), yb(:), ye(:), pe(:)
      integer, allocatable :: deBlockList(:,:,:)
      integer, allocatable :: petMap(:)
      real(ESMF_KIND_R8), pointer :: lon_ptr(:,:) => null()
      real(ESMF_KIND_R8), pointer :: lat_ptr(:,:) => null()
      integer :: i, j, ig, jg

      ! ── 1. Verificar que temos exatamente 1 tile por PET ─────────────────
      ntiles = mpp_get_ntile_count(is%ocean_public%domain)
      if (ntiles /= 1) then
        call ESMF_LogWrite( &
          'OCN: ERRO — ntiles /= 1 não suportado em ESMF_Grid', &
          ESMF_LOGMSG_ERROR)
        rc = ESMF_FAILURE
        return
      end if

      ! ── 2. Obter limites de domínio de TODOS os PETs oceânicos ───────────
      ! mpp_get_domain_npes: número de PETs no comunicador MOM6.
      ! mpp_get_compute_domains (plural): preenche xb/xe/yb/ye para todos.
      ! mpp_get_pelist: mapeia PETs MOM6 → PETs ESMF.
      npes_ocn = mpp_get_domain_npes(is%ocean_public%domain)
      allocate(xb(npes_ocn), xe(npes_ocn), yb(npes_ocn), ye(npes_ocn))
      allocate(pe(npes_ocn))
      call mpp_get_compute_domains(is%ocean_public%domain, &
           xbegin=xb, xend=xe, ybegin=yb, yend=ye)
      call mpp_get_pelist(is%ocean_public%domain, pe)

      write(logmsg,'(A,I4,A,4I6)') &
        'OCN(MOM6): npes_ocn=', npes_ocn, '  global ni,nj,isc,jsc=', &
        ni, nj, isc, jsc
      call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)

      ! ── 3. Construir deBlockList e petMap ────────────────────────────────
      ! deBlockList(dim, start/end, npes): limites de cada bloco por PET.
      !   dim=1 → índice x (i);  dim=2 → índice y (j)
      !   start/end=1 → início do bloco;  start/end=2 → fim do bloco
      ! petMap: para cada DE (bloco), qual PET ESMF é responsável.
      allocate(deBlockList(2, 2, npes_ocn))
      allocate(petMap(npes_ocn))
      do n = 1, npes_ocn
        deBlockList(1, 1, n) = xb(n)
        deBlockList(1, 2, n) = xe(n)
        deBlockList(2, 1, n) = yb(n)
        deBlockList(2, 2, n) = ye(n)
        petMap(n) = pe(n) - pe(1)    ! PET ESMF (zero-based, relativo ao pe(1))
      end do
      deallocate(xb, xe, yb, ye, pe)

      ! ── 4. DELayout e DistGrid 2D ─────────────────────────────────────────
      ! ESMF_DELayoutCreate com petMap associa cada DE ao PET correto.
      ! ESMF_DistGridCreate com minIndex/maxIndex/deBlockList cria um DistGrid
      ! logicamente retangular [1..ni] × [1..nj] com blocos definidos pelo
      ! deBlockList — aceito por ESMF_GridCreate (sem arbSeqIndexList).
      deLayout = ESMF_DELayoutCreate(petMap=petMap, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha DELayoutCreate', &
        line=__LINE__, file=__FILE__)) return
      deallocate(petMap)

      distGrid = ESMF_DistGridCreate(minIndex=(/1, 1/), maxIndex=(/ni, nj/), &
                   deBlockList=deBlockList, delayout=deLayout, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha DistGridCreate', &
        line=__LINE__, file=__FILE__)) return
      deallocate(deBlockList)

      ! ── 5. Grid 2D sobre o DistGrid ──────────────────────────────────────
      ! gridEdgeLWidth/gridEdgeUWidth=(/0,0/) → sem padding de halo em x ou y.
      ocn_grid = ESMF_GridCreate(distgrid=distGrid,               &
                   coordSys=ESMF_COORDSYS_SPH_DEG,                &
                   gridEdgeLWidth=(/0,0/), gridEdgeUWidth=(/0,0/),&
                   rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GridCreate', &
        line=__LINE__, file=__FILE__)) return

      ! ── 6. Coordenadas lon/lat nos centróides ─────────────────────────────
      call ESMF_GridAddCoord(ocn_grid, &
           staggerLoc=ESMF_STAGGERLOC_CENTER, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GridAddCoord', &
        line=__LINE__, file=__FILE__)) return

      ! farrayPtr 2D: o ESMF aloca o ponteiro com bounds locais próprios —
      ! não necessariamente coincidentes com (isc..iec, jsc..jec).
      ! Usar lbound() para calcular o offset correto, exatamente como faz
      ! o mom_cap.F90 oficial (linhas 1500-1531): i1 = i + lbnd1 - isc.
      call ESMF_GridGetCoord(ocn_grid, coordDim=1, &
           staggerLoc=ESMF_STAGGERLOC_CENTER, farrayPtr=lon_ptr, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GridGetCoord lon', &
        line=__LINE__, file=__FILE__)) return

      call ESMF_GridGetCoord(ocn_grid, coordDim=2, &
           staggerLoc=ESMF_STAGGERLOC_CENTER, farrayPtr=lat_ptr, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GridGetCoord lat', &
        line=__LINE__, file=__FILE__)) return

      if (is%ocean_public%is_ocean_pe .and.  &
          associated(lon_ptr) .and. associated(lat_ptr)) then
        ! lbnd_i/lbnd_j: índice inicial do farrayPtr retornado pelo ESMF.
        ! i1 = i + lbnd_i - isc  remapeia i global → índice local do ponteiro.
        block
          integer :: lbnd_i, lbnd_j, i1, j1
          lbnd_i = lbound(lon_ptr, 1)
          lbnd_j = lbound(lon_ptr, 2)
          do j = jsc, jec
            j1 = j + lbnd_j - jsc
            jg = j + ocean_grid%jsc - jsc
            do i = isc, iec
              i1 = i + lbnd_i - isc
              ig = i + ocean_grid%isc - isc
              lon_ptr(i1, j1) = ocean_grid%geoLonT(ig, jg)
              lat_ptr(i1, j1) = ocean_grid%geoLatT(ig, jg)
            end do
          end do
        end block
      end if
      nullify(lon_ptr, lat_ptr)

      ! ── 7. Máscara oceânica ───────────────────────────────────────────────
      call ESMF_GridAddItem(ocn_grid, itemFlag=ESMF_GRIDITEM_MASK,     &
           itemTypeKind=ESMF_TYPEKIND_I4,                               &
           staggerLoc=ESMF_STAGGERLOC_CENTER, rc=rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS   ! não-fatal

      ! ── 8. Realizar campos de importação e exportação ─────────────────────
      do n = 1, n_import
        field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
                staggerLoc=ESMF_STAGGERLOC_CENTER,                          &
                name=trim(import_names(n)), rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
        call NUOPC_Realize(importState, field=field, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do
      do n = 1, n_export
        field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
                staggerLoc=ESMF_STAGGERLOC_CENTER,                          &
                name=trim(export_names(n)), rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
        call NUOPC_Realize(exportState, field=field, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do
      call ESMF_LogWrite('OCN(MOM6): Grid+Fields realizados', ESMF_LOGMSG_INFO)
    end block

    ! ── 9. Persistir estado interno no componente ESMF ────────────────────
    call ESMF_GridCompSetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha SetInternalState', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('OCN(MOM6): InitializeRealize concluido', ESMF_LOGMSG_INFO)

  end subroutine InitializeRealize

  ! ============================================================================
  !> @brief Exporta o estado oceânico inicial (t=0) após ocean_model_init.
  !!
  !! Esta fase é chamada pelo NUOPC após InitializeRealize. Ela garante que
  !! o exportState já contenha a SST e as correntes reais do restart MOM6,
  !! evitando que o mediador receba campos zerados no primeiro passo.
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ocn_internal_state_wrapper) :: wrap
    type(ocn_internal_state_type), pointer :: is => null()
    type(ESMF_State)        :: exportState
    type(ESMF_Clock)        :: clock
    type(ESMF_Time)         :: startTime
    type(ocean_grid_type), pointer :: ocean_grid => null()
    integer :: fieldCount, k
    character(len=64), allocatable :: fldNames(:)
    type(ESMF_Field) :: field

    rc = ESMF_SUCCESS

    ! Recupera estado interno
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GetInternalState IDC', &
      line=__LINE__, file=__FILE__)) return
    is => wrap%ptr

    call NUOPC_ModelGet(gcomp, exportState=exportState, modelClock=clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_ClockGet(clock, startTime=startTime, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Obtém grade para mom_export
    call get_ocean_grid(is%ocean_state, ocean_grid)

    ! Exporta SST real (t=0) do ocean_public → exportState
    ! [C5] mom_export: ocean_state ANTES de exportState
    call mom_export(is%ocean_public, ocean_grid, is%ocean_state, &
                    exportState, clock, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha mom_export IDC', &
      line=__LINE__, file=__FILE__)) return

    ! Exporta Si_ifrac(t=0):
    ! Alternativa 1 (cfg_use_docn_ice=.true.): arquivo OISST — dado observacional
    !   desde t=0, eliminando o bootstrap zero no primeiro passo de acoplamento.
    ! Fallback (cfg_use_docn_ice=.false.): proxy sigmoide Sprint A.5/A.5.1.
    if (cfg_use_docn_ice) then
      call set_si_ifrac_from_file(gcomp, ocean_grid, exportState, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='OCN: falha set_si_ifrac_from_file IDC', &
        line=__LINE__, file=__FILE__)) return
    else
      call compute_si_ifrac_proxy(is%ocean_public, ocean_grid, exportState, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='OCN: falha compute_si_ifrac_proxy IDC', &
        line=__LINE__, file=__FILE__)) return
    end if

    ! Estampilha todos os campos exportados com startTime
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    allocate(fldNames(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fldNames, rc=rc)
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fldNames(k)), &
           field=field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_SetTimestamp(field, startTime, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do
    deallocate(fldNames)

    ! Sinaliza NUOPC que a inicialização de dados está completa
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", &
      value="true", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
      value="true", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('OCN(MOM6): IDC — SST + Si_ifrac exportados (t=0)', &
      ESMF_LOGMSG_INFO)

  end subroutine InitializeDataComplete

  ! ============================================================================
  !> @brief Avança o MOM6+SIS2 por um intervalo de acoplamento.
  !!
  !! Sequência dentro de cada passo de acoplamento:
  !!   1. Recupera estado interno (ocean_public, ocean_state, ice_ocn_bnd)
  !!   2. mom_import: importState ESMF → ice_ocean_boundary_type
  !!      (inclui rotação tensões lat-lon → tripolar)
  !!   3. update_ocean_model: integra MOM6+SIS2 por dt_coupling [s]
  !!      - sub-cicla barotrópico e baroclínico internamente
  !!      - escreve diagnósticos e restart conforme configuração MOM6
  !!   4. mom_export: ocean_public_type → exportState ESMF
  !!      (inclui rotação correntes tripolar → lat-lon)
  !!   5. Atualiza timestamps NUOPC de todos os campos exportados
  subroutine ModelAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ocn_internal_state_wrapper)   :: wrap
    type(ocn_internal_state_type), pointer :: is => null()
    type(ESMF_State)        :: importState, exportState
    type(ESMF_Clock)        :: clock
    type(ESMF_Time)         :: currTime, nextTime
    type(ESMF_TimeInterval) :: timeStep
    type(time_type)         :: fms_curr, fms_dt
    type(ocean_grid_type), pointer :: ocean_grid => null()
    integer :: fieldCount, k
    character(len=64), allocatable :: fldNames(:)
    type(ESMF_Field) :: field
    integer :: yr, mo, dy, hr, mn, sc            ! [C6] conversão ESMF→FMS
    character(len=64)  :: timestr                ! [C9] log de tempo
    character(len=256) :: logmsg

    rc = ESMF_SUCCESS

    ! ── Recuperar contexto NUOPC e estado interno ─────────────────────────
    call NUOPC_ModelGet(gcomp, importState=importState, &
         exportState=exportState, modelClock=clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GetInternalState Advance', &
      line=__LINE__, file=__FILE__)) return
    is => wrap%ptr

    ! ── Obter instante atual e passo de tempo ─────────────────────────────
    call ESMF_ClockGet(clock, currTime=currTime, timeStep=timeStep, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    nextTime = currTime + timeStep

    ! Converter ESMF → FMS para update_ocean_model
    ! [C6] Converter ESMF_Time -> FMS via ESMF_TimeGet + set_date
    call ESMF_TimeGet(currTime, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, rc=rc)
    fms_curr = set_date(yr, mo, dy, hr, mn, sc)
    ! [C6] fms_dt via esmf2fms_time(timeStep) — sem operador '-' de time_type
    fms_dt = esmf2fms_time(timeStep)

    ! [C9] Log de tempo via ESMF_TimeGet(timestring=)
    call ESMF_TimeGet(currTime, timestring=timestr, rc=rc)
    write(logmsg,'(A,A)') 'OCN(MOM6): ModelAdvance currTime=', trim(timestr)
    call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)

    ! ── Obter grade MOM6 para mom_import e mom_export ─────────────────────
    ! FIX-2: PETs nao oceanicas nao executam o advance
    if (.not. is%ocean_public%is_ocean_pe) return

    call get_ocean_grid(is%ocean_state, ocean_grid)

    ! ── Passo 1: Importar fluxos do mediador → ice_ocean_boundary ─────────
    ! mom_import também aplica a rotação de vetores (taux,tauy) de lat-lon
    ! para a grade tripolar interna do MOM6.
    call mom_import(is%ocean_public, ocean_grid, importState, &
                    is%ice_ocn_bnd, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha mom_import', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 2: Avançar MOM6+SIS2 por dt_coupling ────────────────────────
    ! update_ocean_model é o ponto de entrada principal do MOM6.
    ! Internamente sub-cicla a dinâmica barotrópica e baroclínica conforme
    ! DT_BAROCLINIC e DTBT_RESET_PERIOD definidos em MOM_input.
    call update_ocean_model(is%ice_ocn_bnd, is%ocean_state, &
                            is%ocean_public, fms_curr, fms_dt, &
                            cesm_coupled=.false.)  ! [C3]
    call ESMF_LogWrite('OCN(MOM6): update_ocean_model concluido', &
      ESMF_LOGMSG_INFO)

    ! ── Passo 3: Exportar estado oceânico real → exportState ──────────────
    ! mom_export lê ocean_public%t_surf (SST), u_surf, v_surf (correntes),
    ! s_surf (salinidade), frazil, melt_potential e preenche o exportState.
    ! As correntes são rotacionadas de tripolar → lat-lon.
    ! [C5] mom_export: ocean_state ANTES de exportState
    call mom_export(is%ocean_public, ocean_grid, is%ocean_state, &
                    exportState, clock, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha mom_export', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 3b: Si_ifrac — despacho por cfg_use_docn_ice / Sprint B.1 ───
    !
    ! Tabela de modos (nuopc.input &nuopc_mode):
    !   use_docn_ice=T  init_only=F  → Alternativa 1 original:
    !     lê OISST a cada passo (campo congelado dentro do dia).
    !   use_docn_ice=T  init_only=T  → Sprint B.1:
    !     OISST já foi aplicado em InitializeDataComplete (t=0).
    !     Aqui usa sigmoide da SST dinâmica — Si_ifrac evolui.
    !   use_docn_ice=F              → proxy sigmoide puro (Sprint A.5).
    !
    if (cfg_use_docn_ice .and. .not. cfg_docn_ice_init_only) then
      ! Alternativa 1 original: OISST prescrito a cada passo de acoplamento
      call set_si_ifrac_from_file(gcomp, ocean_grid, exportState, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='OCN: falha set_si_ifrac_from_file', &
        line=__LINE__, file=__FILE__)) return
    else
      ! Sprint B.1 (init_only=T) ou sigmoide pura (use_docn_ice=F):
      ! Si_ifrac derivado da SST dinâmica do MOM6 — campo evolui.
      call compute_si_ifrac_proxy(is%ocean_public, ocean_grid, exportState, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='OCN: falha compute_si_ifrac_proxy', &
        line=__LINE__, file=__FILE__)) return
    end if

    ! ── Passo 4: Atualizar timestamps NUOPC de todos os campos exportados ──
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    allocate(fldNames(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fldNames, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fldNames(k)), &
           field=field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_SetTimestamp(field, nextTime, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do
    deallocate(fldNames)

    call ESMF_LogWrite('OCN(MOM6): ModelAdvance concluido', ESMF_LOGMSG_INFO)

  end subroutine ModelAdvance

  ! ============================================================================
  !> @brief Encerra o MOM6+SIS2 e libera toda a memória alocada.
  !!
  !! Chama ocean_model_end (escreve restart final MOM6 se configurado),
  !! desaloca os ponteiros do estado interno e finaliza a infraestrutura FMS.
  subroutine ModelFinalize(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ocn_internal_state_wrapper)   :: wrap
    type(ocn_internal_state_type), pointer :: is => null()
    type(ESMF_Time) :: stopTime
    type(ESMF_Clock) :: clock
    type(time_type)  :: fms_stop
    integer :: yr, mo, dy, hr, mn, sc            ! [C6] conversão ESMF→FMS

    rc = ESMF_SUCCESS

    ! Recupera estado interno
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='OCN: falha GetInternalState Finalize', &
      line=__LINE__, file=__FILE__)) return
    is => wrap%ptr

    ! Obtém stopTime para ocean_model_end
    call NUOPC_ModelGet(gcomp, modelClock=clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call ESMF_ClockGet(clock, stopTime=stopTime, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    ! [C6] Converter ESMF_Time -> FMS via ESMF_TimeGet + set_date
    call ESMF_TimeGet(stopTime, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, rc=rc)
    fms_stop = set_date(yr, mo, dy, hr, mn, sc)

    ! Encerra MOM6 (restart final, fechamento de arquivos netcdf, etc.)
    call ocean_model_end(is%ocean_public, is%ocean_state, fms_stop, &
                         write_restart=.true.)  ! [C4]
    call ESMF_LogWrite('OCN(MOM6): ocean_model_end concluido', ESMF_LOGMSG_INFO)

    ! Libera memória alocada em InitializeRealize
    if (associated(is%ice_ocn_bnd)) deallocate(is%ice_ocn_bnd)
    if (associated(is%ocean_public)) deallocate(is%ocean_public)
    if (associated(is%ocean_state))  deallocate(is%ocean_state)
    deallocate(wrap%ptr)

    ! Finaliza infraestrutura FMS
    call MOM_infra_end()

    call ESMF_LogWrite('OCN(MOM6): ModelFinalize concluido', ESMF_LOGMSG_INFO)

  end subroutine ModelFinalize

  ! ============================================================================
  !> @brief CheckImport tolerante: aceita campos com timestamp em ±dt_coupling.
  !!
  !! O NUOPC_ModelBase padrão rejeita campos cujo timestamp não seja
  !! exatamente igual a currTime. Isso falha no acoplamento MPAS+MOM6 porque
  !! o MED estampilha os campos com nextTime_MED enquanto o clock do OCN ainda
  !! está em currTime_OCN. Esta rotina aceita a janela [currTime-dt, currTime+dt]
  !! e emite WARNING (não FATAL) para campos fora dela.
  subroutine CheckImportTolerant(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)        :: importState
    type(ESMF_Clock)        :: clock
    type(ESMF_Time)         :: currTime, fldTime
    type(ESMF_TimeInterval) :: dt
    type(ESMF_Field)        :: field
    integer :: n, localrc
    character(len=256) :: msg

    rc = ESMF_SUCCESS

    call NUOPC_ModelGet(gcomp, importState=importState, modelClock=clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_ClockGet(clock, currTime=currTime, timeStep=dt, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    do n = 1, n_import
      call ESMF_StateGet(importState, itemName=trim(import_names(n)), &
           field=field, rc=localrc)
      if (localrc /= ESMF_SUCCESS) cycle   ! campo opcional: ignorar

      ! [C7] ESMF_FieldGet sem status= (invalido em ESMF 8.9.1)
      call ESMF_FieldGet(field, rc=localrc)
      if (localrc /= ESMF_SUCCESS) cycle   ! campo não realizado: ignorar

      ! [C8] NUOPC_GetTimestamp sem isValid= (nao existe em NUOPC 8.9.1)
      call NUOPC_GetTimestamp(field, time=fldTime, rc=localrc)
      if (localrc /= ESMF_SUCCESS) cycle

      ! Verifica janela de tolerância ±dt
      if (fldTime < currTime - dt .or. fldTime > currTime + dt) then
        write(msg,'(3A)') 'OCN(MOM6): CheckImport WARNING — timestamp fora ', &
          'da janela ±dt para campo ', trim(import_names(n))
        call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_WARNING)
      end if
    end do

  end subroutine CheckImportTolerant

  ! ============================================================================
  !> @brief Cria ESMF_Mesh a partir da grade tripolar interna do MOM6.
  !!
  !! Constrói uma malha ESMF não estruturada (ESMF_Mesh) com elementos
  !! quadrilaterais correspondentes às células T do MOM6 no domínio
  !! computacional local. Coordenadas extraídas de ocean_grid%geoLonT e
  !! ocean_grid%geoLatT (graus). Áreas de ocean_grid%areaT (m²).
  !!
  !! @param ocean_public  Tipo público MOM6 (contém domain e sfc fields)
  !! @param ocean_state   Tipo de estado MOM6 (contém ponteiro para grid)
  !! @param ocean_grid    Grade MOM6 com coordenadas e métricas
  !! @param isc,iec,jsc,jec  Limites do domínio computacional local
  !! @param ni,nj         Tamanho global da grade
  !! @param ocn_mesh      ESMF_Mesh resultante (saída)
  !! @param rc            Código de retorno ESMF
  ! ============================================================================
  !> @brief Cria ESMF_Grid lat-lon regular para o componente oceânico.
  !!
  !! Substitui a criação manual de ESMF_Mesh tripolar, que causava
  !! "mesh element coordinates unavailable" em ESMF_FieldRegridStore
  !! por não ter coordenadas de centróide de elementos.
  !!
  !! A grade criada aqui é idêntica à ocn_grid do MED (cfg_docn_nx x cfg_docn_ny),
  !! garantindo compatibilidade de tipos ESMF no conector MED→OCN.
  !! O ESMF calcula automaticamente o regrid bilinear/conservativo entre
  !! a grade interna MOM6 e esta grade ESMF.
  ! ============================================================================
  !> @brief Cria ESMF_Mesh com elementCoords para o componente OCN.
  !!
  !! A malha é construída sobre o domínio computacional local do MOM6
  !! (isc:iec × jsc:jec) como elementos quadrilaterais.
  !!
  !! elementCoords são fornecidos explicitamente (centróide = geoLonT, geoLatT)
  !! para evitar o erro "mesh element coordinates unavailable" no ESMF_FieldRegridStore.
  !! Sem elementCoords, o ESMF não consegue criar a PointList para regrid.
  !!
  !! O geomtype ESMF_GEOMTYPE_MESH garante que State_SetExport (mom_cap_methods)
  !! use o ramo 1D (dataPtr1d), que mapeia sequencialmente os elementos do
  !! domínio MOM6 para o Field — compatível com a distribuição real do MOM6.




  ! ============================================================================
  !> @brief Calcula a fracao de gelo marinho via funcao sigmoide refinada.
  !!
  !! Sprint A.5 (Maio 2026): substitui o proxy binario por uma derivacao
  !! continua que captura pack ice consolidado, nao apenas gelo recem-formado.
  !!
  !! CONTEXTO:
  !! Este executavel acopla MOM6+SIS2 como modulo monolitico, com o SIS2
  !! integrado internamente ao MOM6. O ocean_public_type NAO expoe fracao de
  !! gelo diretamente (ice_fraction nao existe na estrutura), entao o cap
  !! NUOPC precisa derivar Si_ifrac de variaveis disponiveis em ocean_public.
  !!
  !! FORMULACAO:
  !! f_ice(T) = clamp( max(F_frazil, F_temp), 0, 1 )
  !! onde:
  !!   F_frazil = 1.0 se frazil > 0 (J/m^2), 0.0 caso contrario
  !!     - frazil > 0 indica formacao ativa de cristais de gelo na superficie.
  !!
  !!   F_temp = sigmoid((T_c - T_surf) / DT)
  !!          = 1 / (1 + exp((T_surf - T_c) / DT))
  !!     com T_c = 271.35 K (ponto de congelamento agua do mar a S~34 psu)
  !!     e DT = 0.5 K (escala de transicao).
  !!
  !! AMOSTRAS DA SIGMOIDE F_temp:
  !!   T_surf = 270.0 K → F_temp = 0.94  (pack ice consolidado)
  !!   T_surf = 271.0 K → F_temp = 0.67  (gelo predominante)
  !!   T_surf = 271.35 K → F_temp = 0.50 (zona de transicao)
  !!   T_surf = 271.85 K → F_temp = 0.27 (mar com gelo disperso)
  !!   T_surf = 273.15 K → F_temp = 0.027 (mar aberto, virtualmente sem gelo)
  !!   T_surf = 285.0 K → F_temp ~ 0 (oceano tropical/subtropical)
  !!
  !! VANTAGENS sobre o proxy binario anterior:
  !!   - Captura pack ice estavel onde frazil = 0 (gelo nao esta crescendo,
  !!     apenas mantendo-se), tipico do Artico/Antartico no inverno.
  !!   - Transicao continua na zona marginal de gelo (MIZ) — mais realista
  !!     fisicamente e melhor para regrid bilinear.
  !!   - Reduz artefatos de "tudo-ou-nada" em regrid OCN→ATM.
  !!
  !! LIMITACAO:
  !!   Aproximacao baseada em variaveis termodinamicas, nao na dinamica real
  !!   do SIS2. A solucao definitiva exige refatoracao para expor SIS2 como
  !!   componente NUOPC separado (cap ICE) — fora do escopo do Sprint A.5.
  ! ============================================================================
  !> @brief Alternativa 1 — preenche Si_ifrac a partir de arquivo OISST (v2.5).
  !!
  !! Versão 2.5 — elimina dependência de State_SetExport (privada).
  !!
  !! O campo Si_ifrac usa ESMF_GEOMTYPE_GRID (2D), confirmado pela chamada
  !! a mom_set_geomtype(ESMF_GEOMTYPE_GRID) em InitializeRealize.
  !! Portanto ESMF_FieldGet com farrayPtr 2D é válido.
  !!
  !! Algoritmo:
  !!   1. PET0 lê o arquivo OISST via ReadOcnFieldInterp (broadcast global).
  !!   2. Para cada célula MOM6, converte coordenadas geográficas (geolonT,
  !!      geolatT) em índices OISST por nearest-neighbor.
  !!   3. Copia diretamente para ptr_ifrac(:,:) do campo Si_ifrac no exportState.
  !!   4. Aplica máscara terra (mask2dT == 0 → 0) e clamping [0,1].
  !!
  !! @param[in]    gcomp        Componente ESMF OCN
  !! @param[in]    ocean_grid   Grade MOM6 (mask2dT, geolonT, geolatT)
  !! @param[inout] exportState  Campo Si_ifrac (2D, GRID) a preencher
  !! @param[out]   rc           Código de retorno ESMF
  subroutine set_si_ifrac_from_file(gcomp, ocean_grid, exportState, rc)
    type(ESMF_GridComp),            intent(in)    :: gcomp
    type(ocean_grid_type), pointer, intent(in)    :: ocean_grid
    type(ESMF_State),               intent(inout) :: exportState
    integer,                        intent(out)   :: rc

    type(ESMF_Clock)            :: clock
    type(ESMF_Time)             :: currTime
    type(ESMF_Field)            :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ice_global(:,:) => null()
    integer :: nx, ny
    integer :: isc, iec, jsc, jec
    integer :: i, j, ig, jg
    integer :: i_oisst, j_oisst
    integer :: localDeCount_f
    real(ESMF_KIND_R8) :: dx, dy
    real(ESMF_KIND_R8) :: lon_c, lat_c
    integer :: lb1, ub1, lb2, ub2
    character(len=256) :: logmsg

    rc = ESMF_SUCCESS

    ! ── 1. Relógio corrente ─────────────────────────────────────────────────
    call ESMF_GridCompGet(gcomp, clock=clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call ESMF_ClockGet(clock, currTime=currTime, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! ── 2. Ler OISST globalmente via ReadOcnFieldInterp ─────────────────────
    nx = cfg_docn_nx
    ny = cfg_docn_ny
    dx = 360.0_ESMF_KIND_R8 / real(nx, ESMF_KIND_R8)
    dy = 180.0_ESMF_KIND_R8 / real(ny, ESMF_KIND_R8)

    ! ReadOcnFieldInterp exige pointer — alocar com bounds globais (1:nx, 1:ny).
    ! PET0 lê e interpola; ESMF_VMBroadcast distribui ice_global para todos.
    allocate(ice_global(nx, ny))
    ice_global = 0.0_ESMF_KIND_R8

    call ReadOcnFieldInterp(gcomp, trim(cfg_docn_ice_file),  &
                            trim(cfg_docn_ice_varname),      &
                            currTime, nx, ny, ice_global, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('OCN(Alt1): ERRO ReadOcnFieldInterp', ESMF_LOGMSG_ERROR)
      deallocate(ice_global); return
    end if

    if (cfg_docn_ice_pct) ice_global = ice_global / 100.0_ESMF_KIND_R8
    ice_global = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ice_global))

    ! ── 3. Verificar grade MOM6 ─────────────────────────────────────────────
    if (.not. associated(ocean_grid)) then
      deallocate(ice_global); return
    end if

    ! ── 4. Obter ponteiro do campo Si_ifrac (2D, GRID) ──────────────────────
    call ESMF_StateGet(exportState, itemName='Si_ifrac', field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      deallocate(ice_global); return
    end if

    ! Guard B-45: PETs sem DE local não acessam farrayPtr
    call ESMF_FieldGet(f_ifrac, localDeCount=localDeCount_f, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localDeCount_f == 0) then
      deallocate(ice_global)
      rc = ESMF_SUCCESS; return
    end if

    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) then
      deallocate(ice_global); return
    end if

    ! Inicializar com zero (terra e oceano sem cobertura)
    ptr_ifrac = 0.0_ESMF_KIND_R8

    ! ── 5. Domínio computacional MOM6 e bounds do campo ESMF ────────────────
    call mpp_get_compute_domain(ocean_grid%Domain%mpp_domain, &
                                isc, iec, jsc, jec)
    lb1 = lbound(ptr_ifrac, 1);  ub1 = ubound(ptr_ifrac, 1)
    lb2 = lbound(ptr_ifrac, 2);  ub2 = ubound(ptr_ifrac, 2)

    ! ── 6. Mapeamento nearest-neighbor MOM6 → OISST ─────────────────────────
    ! Usa ocean_grid%geolonT e ocean_grid%geolatT (graus, já definidos no MOM6).
    ! Grade OISST regular: lon ∈ [0°,360°), lat ∈ [-90°,+90°].
    do j = jsc, jec
      jg = j + ocean_grid%jsc - jsc
      do i = isc, iec
        ig = i + ocean_grid%isc - isc
        ! Pular terra
        if (ocean_grid%mask2dT(ig, jg) <= 0.0_ESMF_KIND_R8) cycle

        ! Coordenadas geográficas do centro da célula [°]
        lon_c = ocean_grid%geolonT(ig, jg)
        lat_c = ocean_grid%geolatT(ig, jg)

        ! Normalizar longitude para [0°, 360°)
        do while (lon_c <   0.0_ESMF_KIND_R8); lon_c = lon_c + 360.0_ESMF_KIND_R8; end do
        do while (lon_c >= 360.0_ESMF_KIND_R8); lon_c = lon_c - 360.0_ESMF_KIND_R8; end do

        ! Índice OISST nearest-neighbor (base 1)
        i_oisst = int(lon_c / dx) + 1
        j_oisst = int((lat_c + 90.0_ESMF_KIND_R8) / dy) + 1
        i_oisst = max(1, min(nx, i_oisst))
        j_oisst = max(1, min(ny, j_oisst))

        ! Copiar para campo ESMF (índice local lb1+i-isc, lb2+j-jsc)
        ptr_ifrac(lb1 + i - isc, lb2 + j - jsc) = &
          max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ice_global(i_oisst, j_oisst)))
      end do
    end do

    deallocate(ice_global)

    ! ── Salvar campo OISST em si_ifrac_mem para persistência Sprint B.1 ──────
    ! BUG-MEM-GUARD (v2.6): o salvamento deve ocorrer APÓS o preenchimento do
    ! campo e fora de qualquer guard de PET — todos os PETs com DE local chegam
    ! aqui. O guard Guard B-45 (localDeCount == 0) retornava ANTES do
    ! salvamento, mantendo si_ifrac_mem_valid = .false. em todos os PETs.
    if (.not. allocated(si_ifrac_mem)) then
      allocate(si_ifrac_mem(lb1:ub1, lb2:ub2))
      si_ifrac_mem = 0.0_ESMF_KIND_R8
    end if
    si_ifrac_mem = ptr_ifrac
    si_ifrac_mem_valid = .true.

    write(logmsg,'(A,I0,A,I0,A,I0,A,I0,A)') &
      'OCN(Alt1): si_ifrac_mem salvo — bounds=[', lb1, ':', ub1, ',', lb2, ':', ub2, ']'
    call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)

    write(logmsg,'(A,A)') 'OCN(Alt1): Si_ifrac lido de ', trim(cfg_docn_ice_file)
    call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)

  end subroutine set_si_ifrac_from_file

  subroutine compute_si_ifrac_proxy(ocean_public, ocean_grid, exportState, rc)
    type(ocean_public_type),       intent(in)    :: ocean_public
    type(ocean_grid_type), pointer, intent(in)   :: ocean_grid  ! Sprint A.5.1
    type(ESMF_State),              intent(inout) :: exportState
    integer,                       intent(out)   :: rc

    type(ESMF_Field)            :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    integer :: ii, jj, ii_mom, jj_mom, ig, jg
    integer :: lb1, lb2, ub1, ub2
    integer :: isc_loc, iec_loc, jsc_loc, jec_loc
    real(ESMF_KIND_R8) :: mask_val

    ! Parâmetros da formulação sigmoide
    !
    ! T_FREEZE : ponto de congelamento da água do mar (S≈35 psu) [K]
    ! DT_TRANS : largura da zona de transição da sigmoide [K]
    !
    ! HISTÓRICO DA LARGURA DT_TRANS:
    !   v2.1 (Sprint A.5) — DT_TRANS = 0.5 K (original)
    !     Demasiadamente estreito: Si_ifrac > 0.01 apenas para SST < 273.7 K.
    !     Após o primeiro passo de acoplamento, a SST polar sobe para 278–282 K
    !     (fluxos atmosféricos de inicialização mais quentes do que o estado
    !     de restart do gelo) → proxy retorna zero em praticamente todo o oceano
    !     polar → mapas Si_ifrac essencialmente em branco (BUG-PROXY-DT).
    !
    !   v2.3 (atual) — DT_TRANS = 2.0 K (corrigido)
    !     Si_ifrac > 0.01 para SST < 271.35 + 2.0·ln(99) ≈ 280.6 K.
    !     Captura células polares com SST até ~280 K, produzindo uma
    !     distribuição de gelo plausível mesmo após a transiente inicial
    !     do acoplamento.  A sigmoide ainda é monotônica e contínua.
    !
    ! EXP_CLAMP : limite para o argumento do exponencial (evita overflow)
    real(ESMF_KIND_R8), parameter :: T_FREEZE  = 271.35_ESMF_KIND_R8  ! [K]
    real(ESMF_KIND_R8), parameter :: DT_TRANS  = 2.0_ESMF_KIND_R8     ! [K]  BUG-PROXY-DT fix
    real(ESMF_KIND_R8), parameter :: EXP_CLAMP = 50.0_ESMF_KIND_R8    ! evita overflow

    ! Parâmetros da contribuição de frazil
    ! FRAZIL_SCALE mapeia frazil [W/m²] para Si_ifrac em [0,1]:
    !   Si_ifrac = min(1, frazil / FRAZIL_SCALE)
    ! Valor típico: 100 W/m² → Si_ifrac = 1.0.
    ! Antes (v2.1): binário (frazil > 0 → f_frazil = 1.0), que atribuía
    ! cobertura total mesmo para frazil mínima (numericamente ruidosa).
    real(ESMF_KIND_R8), parameter :: FRAZIL_SCALE = 100.0_ESMF_KIND_R8 ! [W/m²]

    real(ESMF_KIND_R8) :: t_surf_val, frazil_val, f_temp, f_frazil, x_exp

    rc = ESMF_SUCCESS

    ! Obter limites do domínio computacional local do MOM6
    call mpp_get_compute_domain(ocean_public%domain, &
         isc_loc, iec_loc, jsc_loc, jec_loc)

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) return

    ! Inicializa com zeros (oceano sem gelo / pontos terra após máscara MOM6)
    ptr_ifrac = 0.0_ESMF_KIND_R8

    ! PETs land-only: nada a calcular
    if (.not. ocean_public%is_ocean_pe) return

    ! Sprint A.5.1: ocean_grid é necessário para acessar mask2dT.
    ! Se não foi passado, retorna zeros — comportamento seguro.
    if (.not. associated(ocean_grid)) then
      call ESMF_LogWrite( &
        'OCN(MOM6): Si_ifrac sem ocean_grid — retornando zeros', &
        ESMF_LOGMSG_WARNING)
      return
    end if

    lb1 = lbound(ptr_ifrac, 1); ub1 = ubound(ptr_ifrac, 1)
    lb2 = lbound(ptr_ifrac, 2); ub2 = ubound(ptr_ifrac, 2)

    ! Loop sobre o domínio ESMF, mapeando para índices MOM6 via offset.
    !
    ! Sprint A.5.1: aplicação da máscara terra/oceano via ocean_grid%mask2dT.
    !   mask2dT > 0 → célula oceânica → calcular sigmoide + frazil
    !   mask2dT = 0 → célula terra    → Si_ifrac = 0 (já inicializado)
    !
    ! Padrão de indexação idêntico ao mom_cap_methods::state_setexport.
    do jj = lb2, ub2
      jj_mom = jj + jsc_loc - lb2
      jg     = jj_mom + ocean_grid%jsc - jsc_loc
      do ii = lb1, ub1
        ii_mom = ii + isc_loc - lb1
        ig     = ii_mom + ocean_grid%isc - isc_loc
        if (ii_mom < isc_loc .or. ii_mom > iec_loc) cycle
        if (jj_mom < jsc_loc .or. jj_mom > jec_loc) cycle

        ! Sprint A.5.1: pular células terra (mask2dT == 0)
        mask_val = ocean_grid%mask2dT(ig, jg)
        if (mask_val <= 0.0_ESMF_KIND_R8) cycle

        ! ── Contribuição termodinâmica: sigmoide na SST ──────────────────
        ! f_temp = 1 / (1 + exp((SST - T_FREEZE) / DT_TRANS))
        ! Clampa o expoente para evitar overflow em SST tropical.
        f_temp = 0.0_ESMF_KIND_R8
        if (associated(ocean_public%t_surf)) then
          t_surf_val = ocean_public%t_surf(ii_mom, jj_mom)
          x_exp = (t_surf_val - T_FREEZE) / DT_TRANS
          if (x_exp >  EXP_CLAMP) then
            f_temp = 0.0_ESMF_KIND_R8
          else if (x_exp < -EXP_CLAMP) then
            f_temp = 1.0_ESMF_KIND_R8
          else
            f_temp = 1.0_ESMF_KIND_R8 / (1.0_ESMF_KIND_R8 + exp(x_exp))
          end if
        end if

        ! ── Contribuição dinâmica: frazil ────────────────────────────────
        ! Escala contínua: f_frazil = min(1, frazil / FRAZIL_SCALE).
        ! Antes (v2.1): binário (frazil > 0 → 1.0) atribuía cobertura
        ! total para frazil numericamente ruidosa. A escala contínua
        ! respeita a magnitude do fluxo de formação de gelo.
        f_frazil = 0.0_ESMF_KIND_R8
        if (associated(ocean_public%frazil)) then
          frazil_val = ocean_public%frazil(ii_mom, jj_mom)
          if (frazil_val > 0.0_ESMF_KIND_R8) then
            f_frazil = min(1.0_ESMF_KIND_R8, frazil_val / FRAZIL_SCALE)
          end if
        end if

        ! Combinação: máximo das duas contribuições
        ptr_ifrac(ii, jj) = max(f_frazil, f_temp)
      end do
    end do

    ! Clamp final defensivo [0,1]
    where (ptr_ifrac < 0.0_ESMF_KIND_R8) ptr_ifrac = 0.0_ESMF_KIND_R8
    where (ptr_ifrac > 1.0_ESMF_KIND_R8) ptr_ifrac = 1.0_ESMF_KIND_R8

    ! ── Persistência Sprint B.1: combinar proxy com estado anterior ──────────
    !
    ! BUG-MEM-GUARD (v2.6): diagnostico confirma se si_ifrac_mem_valid chegou
    ! .true. neste PET.  Procurar no log ESMF:
    !   'OCN(proxy): si_ifrac_mem_valid=T' → persistência ativa ✓
    !   'OCN(proxy): si_ifrac_mem_valid=F' → salvamento não ocorreu → bug ativo
    if (si_ifrac_mem_valid) then
      call ESMF_LogWrite('OCN(proxy): si_ifrac_mem_valid=T — aplicando persistencia', &
                         ESMF_LOGMSG_INFO)
      do jj = lb2, ub2
        do ii = lb1, ub1
          ptr_ifrac(ii, jj) = max(ptr_ifrac(ii, jj), &
                                   si_ifrac_mem(ii, jj) * SI_IFRAC_DECAY)
        end do
      end do
      ! Clamp pós-persistência
      where (ptr_ifrac > 1.0_ESMF_KIND_R8) ptr_ifrac = 1.0_ESMF_KIND_R8
    else
      call ESMF_LogWrite('OCN(proxy): si_ifrac_mem_valid=F — sem persistencia (passo inicial?)', &
                         ESMF_LOGMSG_WARNING)
    end if

    ! Salvar estado atual para o próximo passo de acoplamento
    if (.not. allocated(si_ifrac_mem)) then
      allocate(si_ifrac_mem(lb1:ub1, lb2:ub2))
      si_ifrac_mem = 0.0_ESMF_KIND_R8
    end if
    si_ifrac_mem = ptr_ifrac
    si_ifrac_mem_valid = .true.

    call ESMF_LogWrite( &
      'OCN(MOM6): Si_ifrac via sigmoide DT_TRANS=2K + frazil contínuo (v2.3)', &
      ESMF_LOGMSG_INFO)

  end subroutine compute_si_ifrac_proxy

end module MOM_cap_MONAN_mod
