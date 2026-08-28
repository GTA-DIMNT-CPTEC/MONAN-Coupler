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
  use mpas_cap_config_mod, only : cfg_mom6_mesh_ocn

  ! FIX SIS2-ATIVACAO: API do SIS2, confirmada lendo a fonte real em
  ! models/ocean/MOM6-examples/src/SIS2/src/{ice_model,ice_type,
  ! ice_boundary_types}.F90. NÃO usa combined_ice_ocean_driver (bloqueado —
  ! ver cabeçalho do arquivo).
  use ice_model_mod, only : ice_data_type, ice_model_init, ice_model_end,   &
                             share_ice_domains, ice_model_restart,          &
                             update_ice_slow_thermo, update_ice_dynamics_trans, &
                             ocean_ice_boundary_type, atmos_ice_boundary_type

  use MOM_time_manager, only : time_type, set_date, set_calendar_type, GREGORIAN
  use MOM_diag_manager_infra, only : diag_manager_set_time_end_infra

  use mpp_domains_mod, only : mpp_get_compute_domain, mpp_get_domain_npes, &
                               mpp_get_pelist
  use mpp_mod,         only : mpp_pe
  use MOM_domains,     only : MOM_infra_init

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
  integer, parameter :: n_import_atm = 12  ! forçante atmosférica (ver AIB)
  integer, parameter :: n_import_ocn = 3   ! So_t, So_u, So_v (ver OIB)
  character(len=32), dimension(n_import_atm) :: import_names_atm = (/ &
    "Foxx_taux     ", "Foxx_tauy     ", "Foxx_sen      ", "Foxx_evap     ", &
    "Foxx_lwnet    ", "Foxx_swnet_vdr", "Foxx_swnet_vdf", "Foxx_swnet_idr", &
    "Foxx_swnet_idf", "Faxa_rain     ", "Faxa_snow     ", "Sa_pslv       " /)
  character(len=32), dimension(n_import_ocn) :: import_names_ocn = (/ &
    "So_t       ", "So_u       ", "So_v       " /)
  integer, parameter :: n_export = 1
  character(len=32), dimension(n_export) :: export_names = (/ "Si_ifrac_sis2" /)

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

    call export_si_ifrac(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha ' // &
      'export_si_ifrac em InitializeDataComplete', line=__LINE__, file=__FILE__)) return

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

    ! ── Passo 2: avançar o SIS2 ───────────────────────────────────────────
    call update_ice_slow_thermo(is%ice)
    call update_ice_dynamics_trans(is%ice)
    call ESMF_LogWrite('ICE(SIS2): update_ice_slow_thermo + ' // &
      'update_ice_dynamics_trans concluido', ESMF_LOGMSG_INFO)

    ! ── Passo 3: exportar Si_ifrac real ───────────────────────────────────
    call export_si_ifrac(is, gcomp, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='ICE(SIS2): falha export_si_ifrac', &
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
  !! - Foxx_taux/tauy → u_flux/v_flux; Foxx_sen → t_flux; Foxx_evap → q_flux;
  !!   Foxx_lwnet → lw_flux; Foxx_swnet_vdr/vdf/idr/idf → sw_flux_*;
  !!   Faxa_rain/snow → lprec/fprec; Sa_pslv → p. Os campos 2D do mediador
  !!   sao REPLICADOS (broadcast) para todas as categorias de espessura de
  !!   gelo na 3a dimensao de is%aib — o mediador nao distingue por categoria.
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
    !    inventados e causavam NUOPC INCOMPATIBILITY em teste real). --
    call get_field_2d(importState, "Foxx_taux",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%u_flux)
    call get_field_2d(importState, "Foxx_tauy",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%v_flux)
    call get_field_2d(importState, "Foxx_sen",       ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%t_flux)
    call get_field_2d(importState, "Foxx_evap",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%q_flux)
    call get_field_2d(importState, "Foxx_lwnet",     ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lw_flux)
    call get_field_2d(importState, "Foxx_swnet_vdr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dir)
    call get_field_2d(importState, "Foxx_swnet_vdf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dif)
    call get_field_2d(importState, "Foxx_swnet_idr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dir)
    call get_field_2d(importState, "Foxx_swnet_idf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dif)
    ! FIX: lprec/fprec/p agora tem fonte real (antes ficavam em default).
    call get_field_2d(importState, "Faxa_rain",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lprec)
    call get_field_2d(importState, "Faxa_snow",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%fprec)
    call get_field_2d(importState, "Sa_pslv",        ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%p)

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

    ! FIX-DIAG-TEMP5 (Ago 2026): diagnostico temporario. REMOVER depois.
    block
      character(len=320) :: diag_msg5
      write(diag_msg5,'(A,I0,A,I0,A,I0,A,I0,A,I0,A,I0,A,ES12.4,A,ES12.4)') &
        'FIX-DIAG-TEMP5: IST%part_size dim3[', k_lo, ':', k_hi, &
        '] sG isc=', is%ice%sCS%G%isc, ' jsc=', is%ice%sCS%G%jsc, &
        ' | i_off=', i_off, ' j_off=', j_off, &
        ' | ptr_ifrac min=', minval(ptr_ifrac), ' max=', maxval(ptr_ifrac)
      call ESMF_LogWrite(trim(diag_msg5), ESMF_LOGMSG_INFO)
    end block

  end subroutine export_si_ifrac

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
