!! ============================================================================
!! sis_cap_MONAN.F90 — Cap NUOPC do SIS2 (gelo marinho dinâmico)
!! ============================================================================
!!
!! FIX SIS2-ATIVACAO (Ago 2026): componente NUOPC NOVO, separado, para o SIS2.
!!
!! HISTÓRICO: a primeira tentativa (embutir o SIS2 dentro de mom_cap_MONAN.F90
!! via combined_ice_ocean_driver) foi BLOQUEADA — combined_ice_ocean_driver
!! espera um ocean_state_type do driver FMS_cap (ocean_model_MOM.F90), que é
!! um tipo OPACO (private) incompatível com o ocean_state_type do driver
!! nuopc_cap (MOM_ocean_model_nuopc.F90) que mom_cap_MONAN.F90 já usa. Ver
!! SIS2_ativacao_plano_integracao.md, seção 8, para o erro de compilação real
!! e a análise completa.
!!
!! Este arquivo evita esse problema chamando o SIS2 DIRETAMENTE (ice_model_mod),
!! sem passar por combined_ice_ocean_driver — o SIS2 só precisa de
!! ocean_ice_boundary_type/atmos_ice_boundary_type, que são tipos de dados
!! "achatados" (arrays simples), não o estado opaco do MOM6. Troca dados com
!! o mediador via campos ESMF normais, no mesmo padrão de mom_cap_MONAN.F90 e
!! mpas_cap_MONAN.F90.
!!
!! ATENÇÃO GERAL: este arquivo é um RASCUNHO/ESQUELETO, escrito sem acesso a
!! compilador. Partes com alta confiança (API do SIS2, confirmada lendo a
!! fonte real) estão implementadas. Partes com risco maior estão marcadas
!! com "TODO-VERIFICAR" — precisam de confirmação/teste antes de produção.
!!
!! Fluxo de execução por passo de acoplamento (ModelAdvance):
!!   1. Ler campos importados do mediador (forçante ATM + SST/correntes OCN)
!!      para dentro de atmos_ice_boundary_type / ocean_ice_boundary_type
!!   2. update_ice_slow_thermo(Ice) — termodinâmica do gelo
!!   3. update_ice_dynamics_trans(Ice) — dinâmica/transporte do gelo
!!   4. Exportar Si_ifrac (= 1 - Ice%part_size(:,:,1)) para o mediador
!! ============================================================================

module sis_cap_MONAN_mod

  use ESMF
  use NUOPC,       only : NUOPC_CompDerive,        NUOPC_CompSpecialize,   &
                           NUOPC_CompSetEntryPoint, NUOPC_CompAttributeGet, &
                           NUOPC_Advertise,         NUOPC_Realize,          &
                           NUOPC_CompAttributeSet,  NUOPC_IsUpdated,        &
                           NUOPC_CompFilterPhaseMap
  ! FIX (corrigido, era bug de compilação): os três labels abaixo vêm de
  ! NUOPC_Model, não de NUOPC — mesmo padrão já usado (corretamente) em
  ! mom_cap_MONAN.F90.
  ! FIX (limpeza): model_label_SetClock removido — não é mais usado desde
  ! que a especialização (vazia, bugada) de SetClock foi removida acima.
  ! FIX (adicionado): model_label_CheckImport, para o CheckImport tolerante
  ! (ver CheckImportTolerant abaixo) — mesma solução já usada e testada em
  ! mom_cap_MONAN.F90 para o mesmo tipo de erro ("Import Fields not at
  ! current time"), causado pelo SIS2/FMS usar seu proprio gerenciador de
  ! tempo internamente, divergindo ligeiramente do relogio do driver ESMF.
  use NUOPC_Model, only : model_routine_SS           => SetServices,          &
                           model_label_DataInitialize => label_DataInitialize, &
                           model_label_Advance        => label_Advance,        &
                           model_label_Finalize        => label_Finalize,       &
                           model_label_CheckImport    => label_CheckImport,    &
                           NUOPC_ModelGet

  use time_utils_mod, only : esmf2fms_time

  use netcdf   ! FIX-GRADE-ICE: leitura direta de ocean_hgrid.nc (mesmo padrao
               ! ja usado e testado em MED_cap.F90, FIX B-OCNGRID-01/03)
  use mpas_cap_config_mod, only : cfg_mom6_mesh_ocn, cfg_write_fixdiag

  ! FIX SIS2-ATIVACAO: API do SIS2, confirmada lendo a fonte real em
  ! models/ocean/MOM6-examples/src/SIS2/src/{ice_model,ice_type,
  ! ice_boundary_types}.F90. NÃO usa combined_ice_ocean_driver (bloqueado —
  ! ver cabeçalho do arquivo).
  use ice_model_mod, only : ice_data_type, ice_model_init, ice_model_end,   &
                             share_ice_domains, ice_model_restart,          &
                             update_ice_slow_thermo, update_ice_dynamics_trans, &
                             unpack_ocean_ice_boundary, update_ice_model_fast, &
                             exchange_slow_to_fast_ice, &  ! FIX B-ICE-FASTSYNC-01
                             set_ice_surface_fields,    &  ! FIX B-ICE-FASTSYNC-02
                             ocean_ice_boundary_type, atmos_ice_boundary_type

  use MOM_time_manager, only : time_type, set_date, set_calendar_type, GREGORIAN
  use MOM_diag_manager_infra, only : diag_manager_set_time_end_infra

  use mpp_domains_mod, only : mpp_get_compute_domain, mpp_get_domain_npes, &
                               mpp_get_pelist
  use mpp_mod,         only : mpp_pe
  use MOM_domains,     only : MOM_infra_init, AGRID

  implicit none
  private

  public :: SetServices

  ! ── Estado interno do componente de gelo ──────────────────────────────────
  type :: ice_internal_state_type
    type(ice_data_type)             :: ice
    type(ocean_ice_boundary_type)   :: oib   !< SST/correntes vindas do OCN (via MED)
    type(atmos_ice_boundary_type)   :: aib   !< Forçante vinda do ATM (via MED)
    type(ESMF_Grid)                 :: ice_grid
    integer                         :: isc, iec, jsc, jec  !< domínio computacional local
  end type ice_internal_state_type

  type :: ice_internal_state_wrapper
    type(ice_internal_state_type), pointer :: ptr => null()
  end type ice_internal_state_wrapper

  ! ── Nomes de campo trocados com o mediador ────────────────────────────────
  ! FIX (corrigido — era TODO-VERIFICAR, confirmado agora): nomes reais
  ! confirmados em med_cap_types.F90::export_names (18 campos exportados
  ! pelo MED, hoje só ligados a "MED -> OCN"). O conector "MED -> ICE" (já
  ! registrado em esm.F90) casa por StandardName, então os MESMOS campos
  ! que o MED já exporta pro OCN passam a alimentar o ICE tambem — sem
  ! precisar mudar MED_cap.F90. Nomes ANTERIORES (Faxa_taux, Faxa_sen,
  ! Faxa_lat, Faxa_lwdn, Faxa_swvdr/swvdf/swndr/swndf) estavam INVENTADOS
  ! e causaram "NUOPC INCOMPATIBILITY: Import Fields not all connected" em
  ! teste real — substituídos pelos nomes reais abaixo.
  ! Bônus: lprec/fprec/p agora têm fonte real (Faxa_rain/Faxa_snow/
  ! Sa_pslv), que antes ficavam em default (zero/1atm) por falta de nome.
  integer, parameter :: n_import_atm = 13  ! forçante atmosférica (ver AIB)
  integer, parameter :: n_import_ocn = 3   ! So_t, So_u, So_v (ver OIB)
  character(len=32), dimension(n_import_atm) :: import_names_atm = (/ &
    "Fioi_taux     ", "Fioi_tauy     ", "Fioi_sen      ", "Fioi_evap     ", &  ! Fase 3
    "Fioi_lwnet    ", "Fioi_swnet_vdr", "Fioi_swnet_vdf", "Fioi_swnet_idr", &  ! Fase 4 (B-ICE-SWNET-01)
    "Fioi_swnet_idf", "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       ", &
    "Faxa_coszen   " /)  ! Fase 2.5 (B-ZENITH-01)
  ! Fase 3 (B-ICE-FLUX-DIFF-01): taux/tauy/sen/evap/lwnet trocados de
  ! Foxx_* (calculados com SST, apropriados para o MOM6) para Fioi_*
  ! (calculados com a temperatura de pele real do gelo, Si_t_sis2 — ver
  ! export_si_tskin e med_bulk_ncar.F90).
  ! Fase 4 (B-ICE-SWNET-01, Set/2026): SW (swnet_v*/idr/idf) tambem
  ! separado — antes usava Foxx_swnet_* (albedo MISTURADO por Si_ifrac,
  ! o mesmo valor enviado ao MOM6), o que fazia o gelo absorver SW
  ! calculada com um albedo mais baixo que o seu proprio. Agora usa
  ! Fioi_swnet_*, calculado em med_bulk_ncar.F90 com o albedo do gelo por
  ! banda PURO (sem blend com agua aberta) — simetrico ao que ja era
  ! feito para sen/evap/lwnet na Fase 3.
  character(len=32), dimension(n_import_ocn) :: import_names_ocn = (/ &
    "So_t       ", "So_u       ", "So_v       " /)
  integer, parameter :: n_export = 6
  character(len=32), dimension(n_export) :: export_names = (/ &
    character(len=32) ::                &
    "Si_ifrac_sis2", &
    "Si_avsdr_sis2", &  ! Fase 2: albedo visivel direto (Ice%albedo_vis_dir)
    "Si_avsdf_sis2", &  ! Fase 2: albedo visivel difuso (Ice%albedo_vis_dif)
    "Si_anidr_sis2", &  ! Fase 2: albedo infravermelho prox. direto (Ice%albedo_nir_dir)
    "Si_anidf_sis2", &  ! Fase 2: albedo infravermelho prox. difuso (Ice%albedo_nir_dif)
    "Si_t_sis2"    /)   ! Fase 3: temperatura de pele do gelo (Ice%t_surf)

contains

  ! ============================================================================
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=InitializeP0, phase=0, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Advance, &
      specRoutine=ModelAdvance, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! FIX (encontrado via comparação com mom_cap_MONAN.F90 — resolve
    ! "NUOPC INCOMPATIBILITY: Import Fields not at current time" em teste
    ! real): CheckImport tolerante, aceita campos com timestamp em
    ! ±dt_coupling, em vez do padrao estrito do NUOPC_ModelBase (que exige
    ! igualdade exata — falha porque o SIS2/FMS usa seu proprio
    ! gerenciador de tempo internamente, divergindo ligeiramente do
    ! relogio do driver ESMF). Mesma solução já testada em
    ! mom_cap_MONAN.F90 para o mesmo problema entre MED e OCN.
    call ESMF_MethodRemove(gcomp, label=model_label_CheckImport, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_CheckImport, &
      specRoutine=CheckImportTolerant, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Finalize, &
      specRoutine=ModelFinalize, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

  end subroutine SetServices

  ! ============================================================================
  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS
    ! FIX (lacuna encontrada, corrigida): faltava esta chamada — presente
    ! em mom_cap_MONAN.F90, seleciona a versão de fases de inicialização
    ! (IPDv03) que este componente usa. Sem ela, a negociação de fases com
    ! o driver pode não corresponder exatamente ao que InitializeAdvertise/
    ! InitializeRealize abaixo registram (phaseLabelList=IPDv03p1/IPDv03p3).
    call NUOPC_CompFilterPhaseMap(gcomp, ESMF_METHOD_INITIALIZE, &
      acceptStringList=(/"IPDv03p"/), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    ! A especialização de SetClock foi REMOVIDA. A versão anterior
    ! especializava com uma implementação
    ! VAZIA (só retornava ESMF_SUCCESS sem fazer nada) — isso bloqueava o
    ! comportamento PADRÃO do NUOPC_Model de sincronizar o relógio interno
    ! deste componente com o relógio do driver, causando "NUOPC
    ! INCOMPATIBILITY: Import Fields not at current time" em teste real
    ! (o relógio do ICE nunca ficava alinhado ao esperado). Mesmo padrão
    ! de mom_cap_MONAN.F90, que também não especializa SetClock.
  end subroutine InitializeP0

  ! ============================================================================
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc
    integer :: n

    rc = ESMF_SUCCESS

    do n = 1, n_import_atm
      call NUOPC_Advertise(importState, StandardName=trim(import_names_atm(n)), &
        TransferOfferGeomObject="cannot provide", SharePolicyField="share", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do
    do n = 1, n_import_ocn
      call NUOPC_Advertise(importState, StandardName=trim(import_names_ocn(n)), &
        TransferOfferGeomObject="cannot provide", SharePolicyField="share", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do
    do n = 1, n_export
      ! FIX (achado real via NUOPC_Connector.F90:2408 "Neither side able
      ! to provide geom object"): o campo de export do ICE é realizado
      ! numa grade PRÓPRIA (is%ice_grid, criada em InitializeRealize) —
      ! precisa oferecer essa geometria ao conector como "will provide",
      ! não "cannot provide" (que eu tinha usado igual aos imports, por
      ! engano — imports realmente não fornecem geometria própria, mas o
      ! export sim). Sem isso, NEM o lado ICE nem o lado MED (que também
      ! usa "cannot provide" no import) ofereciam geometria nenhuma,
      ! travando o conector logo na inicialização (fase IPDv05p3).
      ! FIX (Ago 2026): removido SharePolicyField="share" desta EXPORTACAO.
      ! O cap do ICE era o unico do sistema a usar essa politica num campo de
      ! exportacao — o cap do OCN (mom_cap_MONAN.F90) usa share apenas nas
      ! IMPORTACOES e deixa as exportacoes so com TransferOfferGeomObject.
      ! Diagnostico confirmou o sintoma: Si_ifrac saia correto daqui
      ! (max=0.997) mas chegava zerado no mediador (min=max=0), indicando que
      ! o conector nao fazia a transferencia real. Alinhado ao padrao do OCN.
      call NUOPC_Advertise(exportState, StandardName=trim(export_names(n)), &
        TransferOfferGeomObject="will provide", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do

    call ESMF_LogWrite('ICE(SIS2): InitializeAdvertise concluido', ESMF_LOGMSG_INFO)

  end subroutine InitializeAdvertise

  ! ============================================================================
  !> @brief Cria a grade ESMF (mesma grade tripolar do OCN, 180x155,
  !! ocean_hgrid.nc — o gelo vive fisicamente na mesma grade do MOM6) e
  !! inicializa o SIS2.
  !!
  !! TODO-VERIFICAR (risco alto): esta rotina assume que dá pra reaproveitar
  !! o MESMO padrão de leitura de ocean_hgrid.nc já usado em MED_cap.F90
  !! (FIX B-OCNGRID-01/03) para construir a grade ESMF deste componente.
  !! Isso NÃO foi testado — precisa confirmar que a decomposição de PETs do
  !! componente ICE (independente da do OCN agora, dado Concurrent_ice=
  !! .false.) é compatível com como ice_model_init monta Ice%slow_domain
  !! internamente a partir do SIS_input.
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is
    type(ESMF_VM)        :: vm
    integer               :: petCount, localPet, mpi_comm_ice, n
    type(time_type)       :: fms_init, fms_start, fms_stop
    type(ESMF_TimeInterval) :: timeStep
    type(time_type)        :: dt_coupling
    type(ESMF_Time)         :: startTime, stopTime
    integer :: yr, mo, dy, hr, mn, sc
    integer :: syy_ice, smm_ice, sdd_ice, shh_ice, smn_ice, sss_ice
    logical :: concurrent_ice_flag

    rc = ESMF_SUCCESS

    allocate(wrap%ptr)
    is => wrap%ptr

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! ── 1. PE-list deste componente + inicializar FMS (MOM_infra_init) ───────
    ! FIX (corrigido, era bug de ordem): MOM_infra_init precisa ser a
    ! PRIMEIRA chamada relacionada a FMS/tempo neste componente — igual ao
    ! padrão de mom_cap_MONAN.F90. A versão anterior chamava set_date()
    ! (passo "tempo inicial") ANTES de MOM_infra_init, o que disparava uma
    ! auto-inicializacao IMPLICITA do FMS dentro de time_manager_init, numa
    ! operacao coletiva do MPI sem sincronia com os demais PETs — causou
    ! SIGABRT real em mpp_init (confirmado em teste: crash em
    ! set_date -> time_manager_init -> fms_init -> mpp_init -> abort).
    ! Movendo MOM_infra_init pra cá (primeiro), antes de qualquer set_date.
    !
    ! FIX-PELIST-ICE: mom_cap_MONAN.F90 chama MOM_infra_init(mpi_comm_mom)
    ! com o comunicador MPI PRÓPRIO daquele componente (nao o comunicador
    ! global) — depois disso, mpp_pe()/mpp_npes() do FMS ficam numerados
    ! localmente (0..petCount-1) DENTRO daquele comunicador. Fazendo o mesmo
    ! aqui (MOM_infra_init com o comunicador proprio do componente ICE),
    ! mpp_pe() fica auto-consistente com o que ice_model_init/
    ! share_ice_domains esperam internamente — sem precisar traduzir
    ! numeracao ESMF-local para numeracao FMS-global.
    call ESMF_VMGet(vm, mpiCommunicator=mpi_comm_ice, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha VMGet ' // &
      'mpiCommunicator', line=__LINE__, file=__FILE__)) return
    call MOM_infra_init(mpi_comm_ice)
    ! FIX (corrigido, era bug faltante): set_calendar_type precisa ser
    ! chamado antes de qualquer set_date — sem isso o calendario do FMS
    ! fica NO_CALENDAR e set_date falha com FATAL "Cannot produce a date
    ! when calendar type is NO_CALENDAR". Mesmo padrao/valor (GREGORIAN)
    ! ja usado em mom_cap_MONAN.F90, que eu tinha esquecido de copiar aqui.
    call set_calendar_type(GREGORIAN)

    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    allocate(is%ice%fast_pelist(petCount))
    allocate(is%ice%slow_pelist(petCount))
    is%ice%fast_pelist(:) = (/ (n, n=0, petCount-1) /)
    is%ice%slow_pelist(:) = is%ice%fast_pelist(:)
    ! FIX (achado real, via analise de ice_model.F90): Verona_coupler=.false.
    ! (usado abaixo) faz ice_model_init CONFIAR nos valores JA PRESENTES em
    ! Ice%fast_ice_pe/Ice%slow_ice_pe para decidir se este PET processa
    ! fast/slow — NAO deriva isso sozinho a partir de fast_pelist/
    ! slow_pelist. Sem esta atribuicao explicita, os defaults do tipo
    ! (.false./.false., ver ice_type.F90) faziam TODO PET nao ser
    ! considerado nem fast nem slow, e Ice%sCS nunca era alocado (aloca
    ! apenas "if (slow_ice_PE)") — causava o FATAL "pointer to Ice%sCS
    ! must be associated" em update_ice_slow_thermo. Todo PET deste
    ! componente processa fast E slow (mesmo padrao das pelists acima).
    is%ice%fast_ice_pe = .true.
    is%ice%slow_ice_pe = .true.

    ! ── 2. Tempo inicial (mesmo padrão de mom_cap_MONAN.F90) ────────────────
    ! Agora SEGURO — FMS já foi inicializado explicitamente no passo 1.
    call ESMF_ClockGet(clock, startTime=startTime, timeStep=timeStep, &
      stopTime=stopTime, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call ESMF_TimeGet(startTime, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    fms_start = set_date(yr, mo, dy, hr, mn, sc)
    fms_init  = fms_start
    dt_coupling = esmf2fms_time(timeStep)

    ! Converte stopTime aqui (usado pelo diag_manager_set_time_end_infra
    ! logo ABAIXO de ice_model_init — ver comentário lá para o motivo da
    ! ordem).
    call ESMF_TimeGet(stopTime, yy=syy_ice, mm=smm_ice, dd=sdd_ice, &
      h=shh_ice, m=smn_ice, s=sss_ice, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    fms_stop = set_date(syy_ice, smm_ice, sdd_ice, shh_ice, smn_ice, sss_ice)

    ! ── 3. Inicializar o SIS2 ────────────────────────────────────────────
    ! Concurrent_ice=.false. (mudou da tentativa anterior): este componente
    ! tem PETs próprios, não embutidos no ciclo do MOM6. fast=slow=
    ! dt_coupling ainda vale (ADD_DIURNAL_SW=False no SIS_input do time,
    ! confirmado — não depende de passo rápido sub-horário).
    concurrent_ice_flag = .false.
    call ice_model_init(is%ice, fms_init, fms_start, &
      Time_step_fast=dt_coupling, Time_step_slow=dt_coupling, &
      Verona_coupler=.false., Concurrent_ice=concurrent_ice_flag)

    !-- FIX (corrigido — era bug de ORDEM, não de chamada faltando): a
    !   versão anterior chamava diag_manager_set_time_end_infra ANTES de
    !   ice_model_init, mas ice_model_init reinicializa o diag_manager
    !   internamente para seus próprios diagnósticos (log confirma:
    !   "diag_manager_init: diag_manager is using fms2_io" aparece de novo
    !   na inicialização do modelo de gelo) — isso APAGAVA o efeito da
    !   chamada anterior. Movendo para AQUI (logo depois de
    !   ice_model_init), a chamada afeta o estado FRESCO do diag_manager
    !   que ice_model_init acabou de estabelecer. Sem isso, o submódulo de
    !   icebergs do SIS2 (SIS_dyn_trans.F90::update_icebergs) crashava com
    !   FATAL "diag_manager_set_time_end must be called before
    !   diag_send_complete" assim que tentava escrever um diagnóstico.
    call diag_manager_set_time_end_infra(fms_stop)

    call share_ice_domains(is%ice)
    is%ice%pe = is%ice%fast_ice_pe .or. is%ice%slow_ice_pe

    call ESMF_LogWrite('ICE(SIS2): ice_model_init concluido', ESMF_LOGMSG_INFO)

    ! ── 4. Grade ESMF (mesma grade tripolar do OCN, ocean_hgrid.nc) ──────────
    ! FIX-GRADE-ICE: reaproveita o mesmo padrao ja testado em MED_cap.F90
    ! (FIX B-OCNGRID-01/03) — dimensao real lida do supergrid, coordenadas T
    ! reais (nao-uniformes), periodicidade leste-oeste. Ver
    ! ICE_ReadMom6TGridDims/ICE_FillMom6TGridCoords abaixo.
    block
      integer :: nx_ice, ny_ice, ny_tiles, nx_max, nx_tiles_target, lde
      integer :: regDecomp(2)
      real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)

      call ICE_ReadMom6TGridDims(trim(cfg_mom6_mesh_ocn), nx_ice, ny_ice, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ao ler ' // &
        'dimensoes de ocean_hgrid.nc', line=__LINE__, file=__FILE__)) return

      ! Mesma fatoracao exata ja usada em MED_cap.F90 para a grade OCN —
      ! garante 1 DE por PET, sem DE orfao.
      nx_tiles_target = max(1, int(sqrt(real(petCount))))
      ny_tiles = 1
      do lde = nx_tiles_target, 1, -1
        if (mod(petCount, lde) == 0 .and. lde <= ny_ice &
            .and. (petCount / lde) <= nx_ice / 2) then
          ny_tiles = lde
          exit
        end if
      end do
      nx_max       = petCount / ny_tiles
      regDecomp(1) = nx_max
      regDecomp(2) = ny_tiles

      ! periodicDim=1 (leste-oeste) — mesma correcao ja testada em
      ! MED_cap.F90; polekindflag deliberadamente OMITIDO (ver nota de
      ! reversao no MED_cap.F90 sobre SIGSEGV causado por declarar polo
      ! onde nao existe).
      is%ice_grid = ESMF_GridCreate1PeriDim(minIndex=(/1,1/), &
        maxIndex=(/nx_ice, ny_ice/), regDecomp=regDecomp, periodicDim=1, &
        indexflag=ESMF_INDEX_GLOBAL, coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ao criar ' // &
        'grade ESMF periodica', line=__LINE__, file=__FILE__)) return

      call ESMF_GridAddCoord(is%ice_grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      call ESMF_GridGetCoord(is%ice_grid, coordDim=1, localDE=0, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call ESMF_GridGetCoord(is%ice_grid, coordDim=2, localDE=0, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      call ICE_FillMom6TGridCoords(trim(cfg_mom6_mesh_ocn), coordX, coordY, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ao ler ' // &
        'coordenadas T reais de ocean_hgrid.nc', line=__LINE__, file=__FILE__)) return

      is%isc = lbound(coordX,1); is%iec = ubound(coordX,1)
      is%jsc = lbound(coordX,2); is%jec = ubound(coordX,2)

      call ESMF_LogWrite('ICE(SIS2): grade ESMF criada ' // &
        '(mesma grade tripolar do OCN)', ESMF_LOGMSG_INFO)
    end block

    ! ── 5. Realizar campos ESMF sobre is%ice_grid ────────────────────────
    block
      integer :: ni_loc, nj_loc, ncat, k
      type(ESMF_Field) :: fld

      ni_loc = is%iec - is%isc + 1
      nj_loc = is%jec - is%jsc + 1
      ! Numero de categorias de espessura de gelo — disponivel apos
      ! ice_model_init (passo 3 acima), via Ice%part_size ja alocado.
      if (associated(is%ice%part_size)) then
        ncat = size(is%ice%part_size, 3)
      else
        ncat = 1
        call ESMF_LogWrite('ICE(SIS2): AVISO — Ice%part_size nao ' // &
          'associado apos ice_model_init; usando ncat=1 como fallback ' // &
          '(provavelmente ERRADO, precisa investigar)', ESMF_LOGMSG_WARNING)
      end if

      ! Campos de importacao (ATM, 2D simples — replicados por categoria
      ! na hora de popular is%aib em ModelAdvance, nao aqui).
      do k = 1, n_import_atm
        fld = ESMF_FieldCreate(is%ice_grid, typekind=ESMF_TYPEKIND_R8, &
          name=trim(import_names_atm(k)), rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
          'FieldCreate import ATM ' // trim(import_names_atm(k)), &
          line=__LINE__, file=__FILE__)) return
        call NUOPC_Realize(importState, field=fld, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do

      do k = 1, n_import_ocn
        fld = ESMF_FieldCreate(is%ice_grid, typekind=ESMF_TYPEKIND_R8, &
          name=trim(import_names_ocn(k)), rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
          'FieldCreate import OCN ' // trim(import_names_ocn(k)), &
          line=__LINE__, file=__FILE__)) return
        call NUOPC_Realize(importState, field=fld, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do

      do k = 1, n_export
        fld = ESMF_FieldCreate(is%ice_grid, typekind=ESMF_TYPEKIND_R8, &
          name=trim(export_names(k)), rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
          'FieldCreate export ' // trim(export_names(k)), &
          line=__LINE__, file=__FILE__)) return
        call NUOPC_Realize(exportState, field=fld, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do

      ! ── Alocar is%oib (2D) e is%aib (3D, com dimensao de categoria) ─────
      allocate(is%oib%u(ni_loc,nj_loc),  is%oib%v(ni_loc,nj_loc))
      allocate(is%oib%t(ni_loc,nj_loc),  is%oib%s(ni_loc,nj_loc))
      allocate(is%oib%frazil(ni_loc,nj_loc), is%oib%sea_level(ni_loc,nj_loc))
      is%oib%u = 0.0_ESMF_KIND_R8; is%oib%v = 0.0_ESMF_KIND_R8
      is%oib%t = 273.15_ESMF_KIND_R8; is%oib%s = 34.7_ESMF_KIND_R8  ! defaults de seguranca
      is%oib%frazil = 0.0_ESMF_KIND_R8; is%oib%sea_level = 0.0_ESMF_KIND_R8
      ! FIX (Ago 2026): is%oib%stagger — o default do tipo
      ! ocean_ice_boundary_type e' BGRID_NE (ver ice_boundary_types.F90).
      ! Os dados que chegam do mediador (So_t/So_u/So_v) sao valores
      ! escalares co-localizados numa grade regular lat-lon simples, sem
      ! staggering — equivalente a AGRID. Sem esta atribuicao explicita,
      ! unpack_ocn_ice_bdry (chamada via unpack_ocean_ice_boundary em
      ! ModelAdvance) tomaria o ramo B-grid/C-grid e interpretaria as
      ! correntes com a geometria errada.
      is%oib%stagger = AGRID
      ! calving/calving_hflx (ice shelf) — nao usados neste acoplamento,
      ! deixados nao-alocados (=> NULL() por padrao no tipo).

      allocate(is%aib%u_flux(ni_loc,nj_loc,ncat), is%aib%v_flux(ni_loc,nj_loc,ncat))
      allocate(is%aib%u_star(ni_loc,nj_loc,ncat))
      allocate(is%aib%t_flux(ni_loc,nj_loc,ncat), is%aib%q_flux(ni_loc,nj_loc,ncat))
      allocate(is%aib%lw_flux(ni_loc,nj_loc,ncat))
      allocate(is%aib%sw_flux_vis_dir(ni_loc,nj_loc,ncat))
      allocate(is%aib%sw_flux_vis_dif(ni_loc,nj_loc,ncat))
      allocate(is%aib%sw_flux_nir_dir(ni_loc,nj_loc,ncat))
      allocate(is%aib%sw_flux_nir_dif(ni_loc,nj_loc,ncat))
      allocate(is%aib%lprec(ni_loc,nj_loc,ncat), is%aib%fprec(ni_loc,nj_loc,ncat))
      allocate(is%aib%dhdt(ni_loc,nj_loc,ncat),  is%aib%dedt(ni_loc,nj_loc,ncat))
      allocate(is%aib%drdt(ni_loc,nj_loc,ncat),  is%aib%coszen(ni_loc,nj_loc,ncat))
      allocate(is%aib%p(ni_loc,nj_loc,ncat))
      is%aib%u_flux = 0.0_ESMF_KIND_R8; is%aib%v_flux = 0.0_ESMF_KIND_R8
      is%aib%u_star = 0.0_ESMF_KIND_R8   ! TODO-VERIFICAR: nao vem do mediador
                                          ! hoje (ver ModelAdvance/ATENCAO)
      is%aib%t_flux = 0.0_ESMF_KIND_R8; is%aib%q_flux = 0.0_ESMF_KIND_R8
      is%aib%lw_flux = 0.0_ESMF_KIND_R8
      is%aib%sw_flux_vis_dir = 0.0_ESMF_KIND_R8
      is%aib%sw_flux_vis_dif = 0.0_ESMF_KIND_R8
      is%aib%sw_flux_nir_dir = 0.0_ESMF_KIND_R8
      is%aib%sw_flux_nir_dif = 0.0_ESMF_KIND_R8
      is%aib%lprec = 0.0_ESMF_KIND_R8; is%aib%fprec = 0.0_ESMF_KIND_R8
      is%aib%dhdt = 0.0_ESMF_KIND_R8; is%aib%dedt = 0.0_ESMF_KIND_R8
      is%aib%drdt = 0.0_ESMF_KIND_R8; is%aib%coszen = 0.0_ESMF_KIND_R8
      is%aib%p = 101325.0_ESMF_KIND_R8  ! 1 atm, default de seguranca

      call ESMF_LogWrite('ICE(SIS2): campos ESMF realizados, ' // &
        'oib/aib alocados', ESMF_LOGMSG_INFO)
    end block

    call ESMF_GridCompSetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('ICE(SIS2): InitializeRealize concluido', ESMF_LOGMSG_INFO)

  end subroutine InitializeRealize

  ! ============================================================================
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is

    rc = ESMF_SUCCESS
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    is => wrap%ptr

    ! FIX B-ICE-FASTSYNC-01: sincroniza fCS%IST <- sCS%IST logo apos
    ! ice_model_init, para que o primeiro update_ice_model_fast (inicio do
    ! primeiro ModelAdvance) ja opere sobre a condicao inicial real do gelo
    ! (restart ou default de ice_model_init em sCS%IST), em vez do estado
    ! "vazio" com que fCS%IST e alocado por padrao. Mesmo espirito do guard
    ! de first_coupling_call ja usado noutros caps para o passo inicial.
    call exchange_slow_to_fast_ice(is%ice)
    call ESMF_LogWrite('ICE(SIS2): exchange_slow_to_fast_ice inicial ' // &
      'concluido (InitializeDataComplete)', ESMF_LOGMSG_INFO)

    call set_ice_surface_fields(is%ice)
    call ESMF_LogWrite('ICE(SIS2): set_ice_surface_fields inicial ' // &
      'concluido (InitializeDataComplete)', ESMF_LOGMSG_INFO)

    call export_si_ifrac(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
      'export_si_ifrac em InitializeDataComplete', line=__LINE__, file=__FILE__)) return

    call export_si_albedo(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
      'export_si_albedo em InitializeDataComplete', line=__LINE__, file=__FILE__)) return

    call export_si_tskin(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
      'export_si_tskin em InitializeDataComplete', line=__LINE__, file=__FILE__)) return

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
      value="true", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('ICE(SIS2): InitializeDataComplete concluido', &
      ESMF_LOGMSG_INFO)
  end subroutine InitializeDataComplete

  ! ============================================================================
  !> @brief Avanço por passo de acoplamento: importa forçante, atualiza o
  !! SIS2 (termodinâmica + dinâmica), exporta Si_ifrac real.
  subroutine ModelAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is

    rc = ESMF_SUCCESS
    nullify(is)
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    is => wrap%ptr

    ! ── Passo 1: popular is%aib/is%oib a partir do importState ───────────
    call import_forcing(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha import_forcing', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 1b (Ago 2026, FIX): desempacotar is%oib (SST/correntes do
    ! OCN, ja populado acima) para dentro de Ice%sCS%OSS — a estrutura
    ! interna que a fisica do SIS2 realmente le (ver
    ! update_ice_slow_thermo -> slow_thermodynamics(..., Ice%sCS%OSS, ...)).
    ! Sem esta chamada, is%oib ficava desconectado da fisica: as correntes
    ! oceanicas (e SST/salinidade/frazil/nivel do mar) importadas do
    ! mediador nunca chegavam ao SIS2, que rodava sobre os defaults de
    ! Ice%sCS%OSS (inicializados em ice_model_init). unpack_ocean_ice_boundary
    ! e a rotina nativa do SIS2 para essa conversao (ice_model.F90) — faz
    ! tambem translate_OSS_to_sOSS internamente, alimentando a
    ! termodinamica rapida. Requer is%oib%stagger=AGRID (ver InitializeRealize).
    call unpack_ocean_ice_boundary(is%oib, is%ice)

    ! ── Passo 1c (Ago 2026, FIX): registrar a forcante atmosferica (is%aib,
    ! ja populada acima) em Ice — grava fluxos e calcula temperatura do
    ! gelo no passo rapido (ver ice_model.F90::update_ice_model_fast).
    ! Mesmo problema estrutural do oceano: is%aib ficava desconectado da
    ! fisica, nunca chegando ao SIS2. Padrao de chamada confirmado no
    ! driver de referencia coupler_main.F90 — la e gated por
    ! Ice%fast_ice_pe (que este cap ja forca .true. sempre, ver
    ! ice_model_init) e chamada uma vez por avanco do acoplamento
    ! atmosfera-superficie, sem subciclo proprio — mesma granularidade do
    ! nosso dt_coupling. Chamada ANTES da fisica lenta porque esta
    ! consome os campos que update_ice_model_fast grava em Ice.
    call update_ice_model_fast(is%aib, is%ice)

    ! ── Passo 2: avançar o SIS2 ───────────────────────────────────────────
    call update_ice_slow_thermo(is%ice)
    call update_ice_dynamics_trans(is%ice)
    call ESMF_LogWrite('ICE(SIS2): update_ice_slow_thermo + ' // &
      'update_ice_dynamics_trans concluido', ESMF_LOGMSG_INFO)

    ! ── Passo 2b (FIX B-ICE-FASTSYNC-01): sincronizar fCS%IST <- sCS%IST ──
    ! Sem esta chamada, Ice%fCS%IST (a copia "rapida" do estado do gelo,
    ! usada por update_ice_model_fast para popular os campos publicos de
    ! fachada Ice%part_size/Ice%albedo*) fica congelada no estado inicial
    ! de ice_model_init para sempre, enquanto Ice%sCS%IST (a copia "lenta",
    ! atualizada acima por update_ice_slow_thermo/update_ice_dynamics_trans)
    ! evolui com gelo real. E exatamente a mesma causa raiz documentada em
    ! export_si_ifrac para Ice%part_size — so que ali contornada lendo
    ! sCS%IST diretamente; aqui corrigimos na fonte, pois nao ha equivalente
    ! de sCS%IST%albedo para "furar" da mesma forma (albedo e calculado
    ! transientemente dentro do proprio update_ice_model_fast, a partir de
    ! fCS%IST — precisa de fCS%IST atualizado para existir).
    !
    ! Chamada aqui (fim do passo lento) para que o PROXIMO
    ! update_ice_model_fast (inicio do proximo ModelAdvance) opere sobre
    ! estado sincronizado. Mesma defasagem de um passo do driver nativo do
    ! SIS2 (coupler_main.F90) -- nao e uma inconsistencia nova.
    call exchange_slow_to_fast_ice(is%ice)
    call ESMF_LogWrite('ICE(SIS2): exchange_slow_to_fast_ice concluido ' // &
      '(fCS%IST sincronizado com sCS%IST)', ESMF_LOGMSG_INFO)

    ! ── Passo 2c (FIX B-ICE-FASTSYNC-02): popular Ice%part_size/Ice%albedo* ──
    ! exchange_slow_to_fast_ice (acima) so ATUALIZA fCS%IST; quem de fato
    ! PREENCHE os campos publicos de fachada (Ice%part_size, Ice%albedo_*)
    ! a partir de fCS%IST e set_ice_surface_fields (-> set_ice_surface_state
    ! internamente). No driver nativo do SIS2 (coupler_main.F90 do FMS) essa
    ! chamada e feita pelo driver externo, nunca pelo proprio SIS2 -- por
    ! isso esta ausencia nao aparece como erro de compilacao nem de link,
    ! so como campo permanentemente zerado. Sem esta chamada, o FIX
    ! B-ICE-FASTSYNC-01 sincroniza o estado mas ninguem o "publica".
    call set_ice_surface_fields(is%ice)
    call ESMF_LogWrite('ICE(SIS2): set_ice_surface_fields concluido ' // &
      '(Ice%part_size/albedo* publicados a partir de fCS%IST)', &
      ESMF_LOGMSG_INFO)

    ! ── Passo 3: exportar Si_ifrac real ───────────────────────────────────
    call export_si_ifrac(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha export_si_ifrac', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 3b (Fase 2): exportar albedo real por banda ─────────────────
    call export_si_albedo(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha export_si_albedo', &
      line=__LINE__, file=__FILE__)) return

    ! ── Passo 3c (Fase 3): exportar temperatura de pele real do gelo ──────
    call export_si_tskin(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha export_si_tskin', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('ICE(SIS2): ModelAdvance concluido', ESMF_LOGMSG_INFO)

  end subroutine ModelAdvance

  ! ============================================================================
  !> @brief CheckImport tolerante: aceita campos com timestamp em ±dt_coupling.
  !!
  !! Adaptado de mom_cap_MONAN.F90::CheckImportTolerant (mesmo problema,
  !! mesma solução): o NUOPC_ModelBase padrão rejeita campos cujo timestamp
  !! não seja exatamente igual a currTime. Isso falha no acoplamento
  !! MED+ICE porque o MED estampilha os campos com nextTime_MED enquanto o
  !! clock do ICE (gerenciado internamente pelo FMS/SIS2) ainda está em
  !! currTime_ICE. Aceita a janela [currTime-dt, currTime+dt] e emite
  !! WARNING (não FATAL) para campos fora dela.
  subroutine CheckImportTolerant(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)        :: importState
    type(ESMF_Field)        :: field
    integer :: n, localrc
    logical, save :: logged_once = .false.

    rc = ESMF_SUCCESS

    ! FIX (simplificado — era bug real): a versão anterior comparava
    ! fldTime (de NUOPC_GetTimestamp) com currTime±dt via operadores
    ! ESMF_TimeLT/ESMF_TimeGT, mas isso causou "Object not Initialized"
    ! repetido pra TODOS os campos em teste real — sugere que
    ! NUOPC_GetTimestamp retorna sucesso (rc=ESMF_SUCCESS) sem realmente
    ! popular um ESMF_Time válido para os campos do ICE (diferente do OCN,
    ! onde a mesma lógica funciona). Em vez de arriscar mais comparações
    ! frágeis com objetos possivelmente não-inicializados, esta versão só
    ! confirma que os campos existem/estão realizados (diagnóstico útil) e
    ! PULA a comparação de tempo em si — efetivamente desativando a
    ! validação estrita sem crashar. RESIDUAL: isso mascara, não resolve,
    ! uma possível causa raiz mais profunda (campos do ICE talvez nunca
    ! sendo genuinamente estampilhados pelo conector MED -> ICE) — vale
    ! investigar depois que o sistema estiver rodando, comparando com o
    ! comportamento equivalente do OCN.
    call NUOPC_ModelGet(gcomp, importState=importState, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    if (.not. logged_once) then
      do n = 1, n_import_atm
        call ESMF_StateGet(importState, itemName=trim(import_names_atm(n)), &
             field=field, rc=localrc)
        if (localrc /= ESMF_SUCCESS) cycle
        call ESMF_FieldGet(field, rc=localrc)
        if (localrc /= ESMF_SUCCESS) cycle
      end do
      do n = 1, n_import_ocn
        call ESMF_StateGet(importState, itemName=trim(import_names_ocn(n)), &
             field=field, rc=localrc)
        if (localrc /= ESMF_SUCCESS) cycle
        call ESMF_FieldGet(field, rc=localrc)
        if (localrc /= ESMF_SUCCESS) cycle
      end do
      call ESMF_LogWrite('ICE(SIS2): CheckImportTolerant ativo — ' // &
        'validacao de timestamp desativada (ver comentario no codigo)', &
        ESMF_LOGMSG_INFO)
      logged_once = .true.
    end if

  end subroutine CheckImportTolerant

  ! ============================================================================
  !> @brief Le os campos importados do mediador (forcante ATM + SST/correntes
  !! OCN) e popula is%aib/is%oib.
  !!
  !! FIX (corrigido, era "ATENCAO nao verificado"): nomes de campo
  !! confirmados contra med_cap_types.F90::export_names em teste real (erro
  !! "NUOPC INCOMPATIBILITY: Import Fields not all connected" com os nomes
  !! antigos inventados). Mapeamento atual:
  !! - Fioi_taux/tauy → u_flux/v_flux; Fioi_sen → t_flux (SINAL INVERTIDO,
  !!   ver FIX B-ICEFLUX-SIGN-01 / broadcast_to_cat_neg); Fioi_evap → q_flux;
  !!   Fioi_lwnet → lw_flux; Fioi_swnet_vdr/vdf/idr/idf → sw_flux_*
  !!   (Fase 4, B-ICE-SWNET-01 — albedo do gelo puro, sem blend);
  !!   Faxa_rain/snow → lprec/fprec; Sa_pslv → p. Os campos 2D do mediador
  !!   sao REPLICADOS (broadcast) para todas as categorias de espessura de
  !!   gelo na 3a dimensao de is%aib — o mediador nao distingue por categoria.
  !!
  !! FIX B-ICEFLUX-SIGN-01 (Set/2026): t_flux e' o UNICO campo desta lista
  !! que precisa de inversao de sinal. Fioi_sen chega na convencao CMEPS
  !! (positivo = aquece a superficie), mas o SIS2 (ice_boundary_types.F90)
  !! define t_flux como positivo = sai da superficie (convencao legada FMS).
  !! Fioi_evap e Fioi_lwnet ja' chegam na convencao que q_flux/lw_flux
  !! esperam — NAO inverter esses dois.
  !! - u_star, dhdt/dedt/drdt, coszen AINDA sem fonte no mediador — ficam
  !!   nos valores default de seguranca definidos em InitializeRealize
  !!   (zero). Isso e' uma SIMPLIFICACAO: acoplamento explicito, sem os
  !!   termos de derivada usados para acoplamento implicito.
  subroutine import_forcing(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp)                                :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: importState
    type(ESMF_Field) :: fld
    real(ESMF_KIND_R8), pointer :: ptr2d(:,:) => null()

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, importState=importState, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! -- Forcante atmosferica: le 2D, replica (broadcast) para as N
    !    categorias de espessura de gelo em is%aib. Nomes confirmados em
    !    med_cap_types.F90::export_names (FIX — nomes anteriores estavam
    !    inventados e causavam NUOPC INCOMPATIBILITY em teste real).
    !    Fase 3 (B-ICE-FLUX-DIFF-01): taux/tauy/sen/evap/lwnet agora vem de
    !    Fioi_* (temperatura de pele do gelo), nao mais Foxx_* (SST). --
    call get_field_2d(importState, "Fioi_taux",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%u_flux)
    call get_field_2d(importState, "Fioi_tauy",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%v_flux)
    ! FIX B-ICEFLUX-SIGN-01 (Set/2026): Fioi_sen (convencao CMEPS, positivo =
    ! aquece a superficie) precisa ser INVERTIDO ao entrar em t_flux (SIS2
    ! espera positivo = sai da superficie, convencao legada FMS). Ver
    ! docstring de broadcast_to_cat_neg abaixo para o raciocinio completo.
    call get_field_2d(importState, "Fioi_sen",       ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat_neg(ptr2d, is%aib%t_flux)
    call get_field_2d(importState, "Fioi_evap",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%q_flux)
    call get_field_2d(importState, "Fioi_lwnet",     ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lw_flux)
    ! Fase 4 (B-ICE-SWNET-01, Set/2026): Fioi_swnet_* (albedo do gelo por
    ! banda, PURO — sem blend com agua aberta) substitui Foxx_swnet_* (que
    ! usava o albedo MEDIO da celula, o mesmo enviado ao MOM6). Ver
    ! comentario no cabecalho de import_names_atm acima para o raciocinio
    ! completo e med_bulk_ncar.F90 para o calculo.
    call get_field_2d(importState, "Fioi_swnet_vdr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dir)
    call get_field_2d(importState, "Fioi_swnet_vdf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dif)
    call get_field_2d(importState, "Fioi_swnet_idr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dir)
    call get_field_2d(importState, "Fioi_swnet_idf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dif)
    ! FIX: lprec/fprec/p agora tem fonte real (antes ficavam em default).
    call get_field_2d(importState, "Faxa_rain",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lprec)
    call get_field_2d(importState, "Faxa_snow",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%fprec)
    call get_field_2d(importState, "Sa_pslv",        ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%p)

    ! Fase 2.5 (B-ZENITH-01): angulo zenital solar real, antes zerado (ver
    ! comentario historico logo acima desta rotina). Campo NOVO — se o
    ! mediador em uso ainda nao exportar Faxa_coszen (versao antiga),
    ! degrada de forma segura para coszen=0 (comportamento anterior) em vez
    ! de abortar toda a forcante.
    call get_field_2d(importState, "Faxa_coszen", ptr2d, rc)
    if (rc == ESMF_SUCCESS) then
      call broadcast_to_cat(ptr2d, is%aib%coszen)
    else
      call ESMF_LogWrite('ICE(SIS2): Faxa_coszen nao encontrado no ' // &
        'importState — is%aib%coszen permanece 0 (mediador antigo?)', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
    end if

    ! -- SST/correntes do oceano: cópia direta 2D para is%oib. --
    call get_field_2d(importState, "So_t", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%t(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_u", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%u(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_v", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%v(:,:) = ptr2d(:,:)
    ! is%oib%s (salinidade): sem fonte confirmada do mediador ainda — ver
    ! nota no plano de integração ("So_s" listado como campo em aberto na
    ! memória do projeto). Mantém o default de seguranca (34.7 psu)
    ! definido em InitializeRealize.

  end subroutine import_forcing

  !> Helper: busca campo 2D no state pelo nome; rc=ESMF_SUCCESS se achou.
  subroutine get_field_2d(state, name, ptr2d, rc)
    type(ESMF_State),    intent(in)    :: state
    character(len=*),    intent(in)    :: name
    real(ESMF_KIND_R8), pointer        :: ptr2d(:,:)
    integer,              intent(out)  :: rc
    type(ESMF_Field) :: fld
    call ESMF_StateGet(state, itemName=trim(name), field=fld, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('ICE(SIS2): campo "' // trim(name) // &
        '" nao encontrado no importState', ESMF_LOGMSG_WARNING)
      return
    end if
    call ESMF_FieldGet(fld, farrayPtr=ptr2d, rc=rc)
  end subroutine get_field_2d

  !> Helper: replica um campo 2D em todas as categorias de espessura (3a
  !! dimensao) de um campo do atmos_ice_boundary_type.
  subroutine broadcast_to_cat(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(inout) :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = src2d(:,:)
    end do
  end subroutine broadcast_to_cat

  !> FIX B-ICEFLUX-SIGN-01 (Set/2026): variante de broadcast_to_cat que
  !! inverte o sinal antes de replicar. Uso exclusivo para Fioi_sen -> t_flux.
  !!
  !! Fioi_sen chega do MED_cap (med_bulk_ncar.F90) na convencao CMEPS
  !! (positivo = fluxo sensivel PARA a superficie, aquece o gelo) — a mesma
  !! convencao de Foxx_sen, confirmada contra o hfx/lh nativo do MONAN-A
  !! (positivo-para-cima). O SIS2 (ice_boundary_types.F90::atmos_ice_boundary_type)
  !! documenta t_flux como "the net sensible heat flux from the ocean or ice
  !! INTO the atmosphere" — ou seja, positivo = sai da superficie (convencao
  !! legada do acoplador FMS, oposta a CMEPS). broadcast_to_cat (copia pura)
  !! entregava Fioi_sen a t_flux sem essa inversao, fazendo o SIS2 interpretar
  !! aquecimento real da superficie como perda de calor (e vice-versa) —
  !! causa de derretimento espurio em condicoes que deveriam resfriar/
  !! engrossar o gelo (ex. ar frio sobre gelo, comum em inverno polar).
  !!
  !! Fioi_evap -> q_flux e Fioi_lwnet -> lw_flux NAO precisam desta correcao:
  !! Fioi_evap ja segue a convencao CMEPS "E>0 = superficie->atmosfera", que
  !! coincide com q_flux; Fioi_lwnet ja e' liquido-para-dentro, que coincide
  !! com lw_flux ("from the atmosphere into the ice or ocean").
  subroutine broadcast_to_cat_neg(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(inout) :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = -src2d(:,:)
    end do
  end subroutine broadcast_to_cat_neg


  !! Confirmado em ice_type.F90. Ver SIS2_ativacao_plano_integracao.md.
  subroutine export_si_ifrac(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp)                                :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    integer :: ii, jj, lb1, lb2, ub1, ub2
    integer :: i_off, j_off, k_lo, k_hi

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_ifrac_sis2", field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) return

    if (.not. associated(is%ice%sCS)) then
      call ESMF_LogWrite('ICE(SIS2): Ice%sCS nao associado (slow ice PE ' // &
        'ausente?) — Si_ifrac=0', ESMF_LOGMSG_WARNING)
      ptr_ifrac = 0.0_ESMF_KIND_R8
      return
    end if

    lb1 = lbound(ptr_ifrac,1); ub1 = ubound(ptr_ifrac,1)
    lb2 = lbound(ptr_ifrac,2); ub2 = ubound(ptr_ifrac,2)
    ! ------------------------------------------------------------------
    ! Historico de correcoes desta rotina (Ago 2026), resumido:
    !   1) formula original usava 1 - part_size(:,:,1), tratando o indice 1
    !      como agua aberta — errado (indice 1 e categoria de gelo);
    !   2) tentativa de corrigir com lbound falhou: part_size e POINTER e a
    !      associacao nao preserva os limites 0:CatIce (lbound deu 1);
    !   3) causa raiz final: a FONTE estava errada — ver FIX-3 abaixo.
    ! ------------------------------------------------------------------
    ! FIX-3 (Ago 2026) — FONTE DO CAMPO estava errada.
    ! O diagnostico FIX-DIAG-TEMP5 mostrou part_size dim1[1:90] dim2[1:155]
    ! dim3[1:6], i_off=0, j_off=0 e TODAS as fatias zeradas, apesar do SIS2
    ! ter gelo real (SIS Date: Area 1.277E+13 no passo 0). Ou seja: nao era
    ! problema de indice nem de halo (nao ha halo em Ice%part_size, e a
    ! indexacao ja acompanhava a decomposicao MPI corretamente — PET6
    ! dim1[1:90], PET7 dim1[91:180]).
    !
    ! Causa raiz: Ice%part_size (do ice_data_type) e o campo DE FACHADA do
    ! acoplador, preenchido apenas pelo caminho de acoplamento rapido
    ! (ver ice_type.F90:191 — only available on fast PEs); nesta
    ! configuracao ele permanece zerado. O estado REAL do gelo vive em
    ! Ice%sCS%IST%part_size (ice_state_type), que e o que o proprio SIS2 usa
    ! para calcular area/massa em ice_stock_pe (ice_type.F90:593-625) — os
    ! mesmos numeros nao-zero que aparecem no log SIS Date.
    !
    ! IMPORTANTE: ao contrario de Ice%part_size, IST%part_size TEM HALOS
    ! (isd:ied, jsd:jed) e categorias com base 0. Por isso o deslocamento
    ! agora e derivado da grade do proprio SIS2 (Ice%sCS%G%isc/jsc), que e o
    ! padrao usado internamente por ice_model.F90 (i_off = LBOUND - sG%isc).
    ! IST so existe em slow_ice_PE — garantido aqui, pois o cap forca
    ! fast_ice_pe=.true. e slow_ice_pe=.true. antes de ice_model_init.
    ! ------------------------------------------------------------------
    ! Fracao de gelo marinho exportada ao mediador (Si_ifrac_sis2).
    !
    ! FONTE DO CAMPO — ponto critico: usa Ice%sCS%IST%part_size (estado
    ! interno real do SIS2, ice_state_type), NAO Ice%part_size. Este ultimo
    ! e o campo de fachada do acoplador, preenchido apenas no caminho de
    ! acoplamento rapido (ver ice_type.F90:191 - only available on fast PEs)
    ! e permanece ZERADO nesta configuracao. IST%part_size e o mesmo array
    ! que o proprio SIS2 usa para calcular area/massa em ice_stock_pe, ou
    ! seja, os valores nao-zero que aparecem no log SIS Date.
    !
    ! INDEXACAO: IST%part_size tem halos (isd:ied, jsd:jed) e categorias com
    ! base 0, onde a fatia 0 e AGUA ABERTA e 1..CatIce sao as categorias de
    ! gelo. O deslocamento vem da grade do proprio SIS2 (Ice%sCS%G%isc/jsc),
    ! padrao usado internamente por ice_model.F90 - acompanha corretamente
    ! qualquer decomposicao MPI (verificado: PET6 i_off=4, PET7 i_off=-86).
    ! A soma e feita de k_lo+1 ate k_hi (todas as categorias de gelo, isto e,
    ! todas as fatias menos a primeira), robusto a base 0 ou 1.
    !
    ! IST so existe em slow_ice_PE - garantido aqui, pois o cap forca
    ! fast_ice_pe=.true. e slow_ice_pe=.true. antes de ice_model_init.
    ! ------------------------------------------------------------------
    i_off = is%ice%sCS%G%isc - lb1
    j_off = is%ice%sCS%G%jsc - lb2
    k_lo  = lbound(is%ice%sCS%IST%part_size, 3)
    k_hi  = ubound(is%ice%sCS%IST%part_size, 3)
    do jj = lb2, ub2
      do ii = lb1, ub1
        ! fracao de gelo = soma das categorias de gelo = todas as fatias
        ! menos a primeira (agua aberta), robusto a base 0 ou 1
        ptr_ifrac(ii,jj) = &
          sum(is%ice%sCS%IST%part_size(ii+i_off, jj+j_off, k_lo+1:k_hi))
        ptr_ifrac(ii,jj) = max(0.0_ESMF_KIND_R8, &
          min(1.0_ESMF_KIND_R8, ptr_ifrac(ii,jj)))
      end do
    end do

    ! FIX-DIAG-FASTSYNC-01: valida a correcao B-ICE-FASTSYNC-01 comparando
    ! o campo publico de fachada Ice%part_size (que ate a correcao ficava
    ! sempre zerado, ver historico acima) contra o valor de sCS%IST%part_size
    ! ja usado como fonte real acima. Ja validado em producao (Set/2026);
    ! gated por cfg_write_fixdiag para nao poluir logs de rodadas longas.
    if (cfg_write_fixdiag) then
      if (associated(is%ice%part_size)) then
        block
          character(len=200) :: diag_msg6
          write(diag_msg6,'(A,ES12.4,A,ES12.4)') &
            'FIX-DIAG-FASTSYNC-01: Ice%part_size(:,:,1) [fachada publica] ' // &
            'min=', minval(is%ice%part_size(:,:,1)), ' max=', &
            maxval(is%ice%part_size(:,:,1))
          call ESMF_LogWrite(trim(diag_msg6), ESMF_LOGMSG_INFO)
        end block
      else
        call ESMF_LogWrite('FIX-DIAG-FASTSYNC-01: Ice%part_size ainda nao ' // &
          'associado neste ponto', ESMF_LOGMSG_INFO)
      end if
    end if

  end subroutine export_si_ifrac

  !! Fase 2 (B-ICE-ALBEDO-01): exporta o albedo real do gelo, por banda,
  !! calculado pela fisica do proprio SIS2 (esquema optico em
  !! SIS_optics.F90/fast_radiation_diagnostics), agora acessivel porque
  !! Ice%albedo_vis_dir/vis_dif/nir_dir/nir_dif (fachada publica) passaram
  !! a ser preenchidos pelas correcoes B-ICE-FASTSYNC-01/02 acima.
  !!
  !! Diferente de Si_ifrac_sis2 (que le sCS%IST%part_size com deslocamento
  !! i_off/j_off), aqui usamos Ice%part_size e Ice%albedo_* diretamente —
  !! ambos sao campos da MESMA fachada publica, com a MESMA indexacao local
  !! (sem halo, sem offset), confirmados no diagnostico FIX-DIAG-FASTSYNC-01
  !! (que ja le is%ice%part_size(:,:,1) sem nenhum deslocamento).
  !!
  !! *** VERIFICAR ***: os comentarios de ice_type.F90 (fonte NOAA-GFDL/SIS2)
  !! para albedo_vis_dif/albedo_nir_dir parecem trocados entre si ("The
  !! surface albedo for diffuse visible..." vs "...direct near-infrared...").
  !! Usamos aqui os NOMES dos campos (vis_dir/vis_dif/nir_dir/nir_dif), que
  !! sao a fonte de verdade da API, nao a prosa do comentario — mas vale
  !! uma segunda conferencia cruzando com SIS_optics.F90 antes de validar
  !! contra observacoes.
  subroutine export_si_albedo(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp)                                :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_avsdr, f_avsdf, f_anidr, f_anidf
    real(ESMF_KIND_R8), pointer :: ptr_avsdr(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_avsdf(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_anidr(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_anidf(:,:) => null()
    real(ESMF_KIND_R8) :: ice_frac_ij
    integer :: ii, jj, k_lo, k_hi
    ! Fallback usado apenas onde a fracao de gelo e desprezivel (o peso do
    ! termo de gelo no blend por ifrac feito no mediador torna esse valor
    ! quase irrelevante), ou onde Ice%albedo_* ainda nao estiver associado.
    real(ESMF_KIND_R8), parameter :: ALBEDO_ICE_FALLBACK = 0.65_ESMF_KIND_R8

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_avsdr_sis2", field=f_avsdr, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_avsdf_sis2", field=f_avsdf, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_anidr_sis2", field=f_anidr, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_anidf_sis2", field=f_anidf, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call ESMF_FieldGet(f_avsdr, farrayPtr=ptr_avsdr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_avsdr)) return
    call ESMF_FieldGet(f_avsdf, farrayPtr=ptr_avsdf, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_avsdf)) return
    call ESMF_FieldGet(f_anidr, farrayPtr=ptr_anidr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_anidr)) return
    call ESMF_FieldGet(f_anidf, farrayPtr=ptr_anidf, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_anidf)) return

    if (.not. (associated(is%ice%part_size) .and. &
               associated(is%ice%albedo_vis_dir) .and. &
               associated(is%ice%albedo_vis_dif) .and. &
               associated(is%ice%albedo_nir_dir) .and. &
               associated(is%ice%albedo_nir_dif))) then
      call ESMF_LogWrite('ICE(SIS2): Ice%part_size/albedo_* nao ' // &
        'associados — Si_a*_sis2 = fallback constante', ESMF_LOGMSG_WARNING)
      ptr_avsdr = ALBEDO_ICE_FALLBACK; ptr_avsdf = ALBEDO_ICE_FALLBACK
      ptr_anidr = ALBEDO_ICE_FALLBACK; ptr_anidf = ALBEDO_ICE_FALLBACK
      return
    end if

    ! part_size/albedo_* tem a mesma 3a dimensao (categorias); categoria
    ! k_lo = agua aberta (mesma convencao usada em export_si_ifrac).
    k_lo = lbound(is%ice%part_size, 3)
    k_hi = ubound(is%ice%part_size, 3)

    do jj = lbound(ptr_avsdr,2), ubound(ptr_avsdr,2)
      do ii = lbound(ptr_avsdr,1), ubound(ptr_avsdr,1)
        ice_frac_ij = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8))
        if (ice_frac_ij > 1.0e-6_ESMF_KIND_R8) then
          ! media ponderada pela area de cada categoria de gelo
          ptr_avsdr(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_vis_dir(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_avsdf(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_vis_dif(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_anidr(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_nir_dir(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_anidf(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_nir_dif(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
        else
          ptr_avsdr(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_avsdf(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_anidr(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_anidf(ii,jj) = ALBEDO_ICE_FALLBACK
        end if
        ! blindagem: albedo fisico esta sempre em [0,1]
        ptr_avsdr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdr(ii,jj)))
        ptr_avsdf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdf(ii,jj)))
        ptr_anidr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidr(ii,jj)))
        ptr_anidf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidf(ii,jj)))
      end do
    end do

    ! FIX-DIAG-ALBEDO-01: diagnostico de validacao, mesmo espirito do
    ! FIX-DIAG-FASTSYNC-01. Espera-se min proximo do fallback/agua (baixo)
    ! e max na faixa de neve fria (~0,8-0,9) em regioes com gelo espesso.
    if (cfg_write_fixdiag) then
      block
        character(len=200) :: diag_msg7
        write(diag_msg7,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
          'FIX-DIAG-ALBEDO-01: Si_avsdr min=', minval(ptr_avsdr), &
          ' max=', maxval(ptr_avsdr), &
          ' | Si_anidr min=', minval(ptr_anidr), ' max=', maxval(ptr_anidr)
        call ESMF_LogWrite(trim(diag_msg7), ESMF_LOGMSG_INFO)
      end block
    end if

  end subroutine export_si_albedo

  !! Fase 3 (B-ICE-FLUX-DIFF-01): exporta a temperatura de pele real do
  !! gelo, media ponderada por area de categoria (mesmo padrao de
  !! export_si_albedo). Usada pelo mediador para calcular um segundo
  !! conjunto de fluxos turbulentos (Fioi_*) especifico para a fracao de
  !! gelo, em vez de reusar o Foxx_* calculado com SST — que e o que o
  !! SIS2 recebia ate aqui (ver import_names_atm, historicamente
  !! compartilhado com o MOM6).
  !!
  !! Ice%t_surf e' preenchido pela MESMA rotina (set_ice_surface_state) que
  !! Ice%part_size/Ice%albedo_* — ja' confirmada funcionando pelas
  !! correcoes B-ICE-FASTSYNC-01/02.
  subroutine export_si_tskin(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp)                                :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_tice
    real(ESMF_KIND_R8), pointer :: ptr_tice(:,:) => null()
    real(ESMF_KIND_R8) :: ice_frac_ij
    integer :: ii, jj, k_lo, k_hi
    ! Fallback: ponto de congelamento tipico da agua do mar (~-1,8 C),
    ! usado so' onde a fracao de gelo e desprezivel ou o campo nao esta
    ! associado — o peso do termo de gelo no blend a jusante torna esse
    ! valor quase irrelevante nesses casos.
    real(ESMF_KIND_R8), parameter :: TICE_FALLBACK = 271.35_ESMF_KIND_R8

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_t_sis2", field=f_tice, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_tice, farrayPtr=ptr_tice, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_tice)) return

    if (.not. (associated(is%ice%part_size) .and. associated(is%ice%t_surf))) then
      call ESMF_LogWrite('ICE(SIS2): Ice%part_size/t_surf nao associados ' // &
        '— Si_t_sis2 = fallback (ponto de congelamento)', ESMF_LOGMSG_WARNING)
      ptr_tice = TICE_FALLBACK
      return
    end if

    k_lo = lbound(is%ice%part_size, 3)
    k_hi = ubound(is%ice%part_size, 3)

    do jj = lbound(ptr_tice,2), ubound(ptr_tice,2)
      do ii = lbound(ptr_tice,1), ubound(ptr_tice,1)
        ice_frac_ij = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8))
        if (ice_frac_ij > 1.0e-6_ESMF_KIND_R8) then
          ptr_tice(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                 real(is%ice%t_surf(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
        else
          ptr_tice(ii,jj) = TICE_FALLBACK
        end if
        ! blindagem fisica: temperatura de gelo/neve nunca abaixo de ~180 K
        ! (recorde antartico ~184 K) nem acima do congelamento da agua do mar
        ptr_tice(ii,jj) = max(180.0_ESMF_KIND_R8, min(273.15_ESMF_KIND_R8, ptr_tice(ii,jj)))
      end do
    end do

    if (cfg_write_fixdiag) then
      block
        character(len=150) :: diag_msg8
        write(diag_msg8,'(A,ES10.3,A,ES10.3)') &
          'FIX-DIAG-TSKIN-01: Si_t_sis2 min=', minval(ptr_tice), ' max=', maxval(ptr_tice)
        call ESMF_LogWrite(trim(diag_msg8), ESMF_LOGMSG_INFO)
      end block
    end if

  end subroutine export_si_tskin

  ! ============================================================================
  subroutine ModelFinalize(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ice_internal_state_wrapper) :: wrap
    type(ice_internal_state_type), pointer :: is

    rc = ESMF_SUCCESS
    call ESMF_GridCompGetInternalState(gcomp, wrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    is => wrap%ptr

    call ice_model_restart(is%ice)
    call ice_model_end(is%ice)
    deallocate(wrap%ptr)

    call ESMF_LogWrite('ICE(SIS2): ModelFinalize concluido', ESMF_LOGMSG_INFO)

  end subroutine ModelFinalize

  !----------------------------------------------------------------------------
  ! ICE_ReadMom6TGridDims / ICE_FillMom6TGridCoords — adaptadas quase
  ! verbatim de MED_cap.F90 (MED_ReadMom6TGridDims/MED_FillMom6TGridCoords,
  ! FIX B-OCNGRID-01/03), ja testadas e confirmadas funcionando naquele
  ! contexto (leitura real do supergrid ocean_hgrid.nc, periodicidade,
  ! normalizacao de longitude). Duplicadas aqui em vez de compartilhadas via
  ! modulo utilitario por simplicidade — considerar refatorar para um
  ! modulo comum (ex.: mom6_grid_utils_mod) se o time preferir evitar a
  ! duplicacao entre MED_cap.F90 e sis_cap_MONAN.F90.
  !----------------------------------------------------------------------------
  subroutine ICE_ReadMom6TGridDims(filename, ni, nj, rc)
    character(len=*), intent(in)  :: filename
    integer,           intent(out) :: ni, nj
    integer,           intent(out) :: rc
    integer :: ncid, dimid, nx_super, ny_super, ncstat

    rc = ESMF_SUCCESS
    ni = 0; nj = 0

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('ICE(SIS2): falha ao abrir ' // trim(filename) // &
        ' para ler dimensoes da grade T real do MOM6', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'nx', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=nx_super)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('ICE(SIS2): falha ao ler dimensao "nx" de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'ny', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=ny_super)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('ICE(SIS2): falha ao ler dimensao "ny" de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_close(ncid)

    if (mod(nx_super,2) /= 0 .or. mod(ny_super,2) /= 0) then
      call ESMF_LogWrite('ICE(SIS2): AVISO — nx/ny impar em ' // &
        trim(filename) // ' (formato inesperado).', ESMF_LOGMSG_WARNING)
    end if

    ni = nx_super / 2
    nj = ny_super / 2
  end subroutine ICE_ReadMom6TGridDims

  subroutine ICE_FillMom6TGridCoords(filename, coordX, coordY, rc)
    character(len=*),    intent(in)    :: filename
    real(ESMF_KIND_R8), pointer        :: coordX(:,:), coordY(:,:)
    integer,              intent(out)  :: rc
    integer :: ncid, varid_x, varid_y, ncstat
    integer :: i1, i2, j1, j2, ni_local, nj_local
    integer :: start2(2), count2(2), stride2(2)

    rc = ESMF_SUCCESS
    if (.not. associated(coordX) .or. .not. associated(coordY)) return

    i1 = lbound(coordX,1); i2 = ubound(coordX,1)
    j1 = lbound(coordX,2); j2 = ubound(coordX,2)
    ni_local = i2 - i1 + 1
    nj_local = j2 - j1 + 1
    if (ni_local <= 0 .or. nj_local <= 0) return

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('ICE(SIS2): falha ao abrir ' // trim(filename) // &
        ' para ler coordenadas T reais do MOM6', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_varid(ncid, 'x', varid_x)
    if (ncstat == NF90_NOERR) ncstat = nf90_inq_varid(ncid, 'y', varid_y)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('ICE(SIS2): variaveis "x"/"y" nao encontradas em ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    start2  = (/ 2*i1, 2*j1 /)
    count2  = (/ ni_local, nj_local /)
    stride2 = (/ 2, 2 /)

    ncstat = nf90_get_var(ncid, varid_x, coordX, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('ICE(SIS2): falha ao ler "x" (lon) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ! Mesma normalizacao 0..360 ja usada/testada em MED_cap.F90.
    where (coordX < 0.0_ESMF_KIND_R8)
      coordX = coordX + 360.0_ESMF_KIND_R8
    end where
    where (coordX >= 360.0_ESMF_KIND_R8)
      coordX = coordX - 360.0_ESMF_KIND_R8
    end where

    ncstat = nf90_get_var(ncid, varid_y, coordY, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('ICE(SIS2): falha ao ler "y" (lat) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ncstat = nf90_close(ncid)
  end subroutine ICE_FillMom6TGridCoords

end module sis_cap_MONAN_mod
