!> @file med_exchange.F90
!! @brief Trocas do mediador, por fase.
!!
!! O mediador troca campos com os componentes em fases fixas, na
!! inicialização e a cada passo (ver docs/arquitetura-acoplamento.md, seção
!! 3.7). Este módulo reúne as fases à medida que saem de MED_cap:
!!
!!   inicializar_dados
!!              InitializeDataComplete: rotas de inicialização (coluna
!!              criar='inicio' de ROTAS), espera da primeira SST do oceano e
!!              valores de t=0 no exportState (R-FASE11-17)
!!   ir_para_malha_de_fluxo
!!              antes da física: leva os campos do oceano e do gelo da
!!              grade do oceano para a malha de fluxo (R-FASE11-16)
!!   entregar   no fim do passo, depois da física: leva os campos da malha
!!              de fluxo para o exportState (export_to_components, em
!!              med_export) e carimba o tempo dos campos exportados
!!              (R-FASE11-15)
!!
!! O carimbo de tempo dos campos que o mediador entrega fica só aqui. Na
!! inicialização, cada campo do exportState recebe startTime
!! (idc_stamp_export). A cada passo, cada campo recebe stampTime (ver med_stamp_time, em MED_cap)
!! e, com use_med_to_mpas, o exportState inteiro recebe depois o tempo atual
!! do relógio, que prevalece. A ordem das duas marcações é a de antes da
!! R-FASE11-15, quando a segunda ficava em RouteOcnToAtm (med_cap_methods);
!! as mensagens do log continuam com esse nome, que as ferramentas de
!! pós-processamento procuram (tools/postproc/postproc_monan2_import.py).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_exchange_mod
  use ESMF
  use NUOPC,               only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet, NUOPC_IsAtTime
  use coupler_utils_mod,   only: ChkErr
  use cpl_map_mod,         only: ROTAS
  use med_cap_types_mod,   only: MED_InternalState
  use med_cap_methods_mod, only: cria_rota, RegridOrCopy
  use med_export_mod,      only: export_to_components
  use med_ocean_mod,       only: update_ocean_fields_on_atm_grid, &
                                 update_ice_fraction_from_docn, regrid_ocean_currents

  implicit none
  private

  public :: inicializar_dados
  public :: prepara_inicio        ! também para tests/completar
  public :: ir_para_malha_de_fluxo
  public :: entregar
  public :: stamp_export_fields

contains

  ! ---------------------------------------------------------------------------
  ! Fase de inicialização
  ! ---------------------------------------------------------------------------

  !> Fase de inicialização (InitializeDataComplete do mediador). Pode ser
  !! chamada MAIS DE UMA VEZ: o laço de resolução de dependência de dados do
  !! driver NUOPC percorre a RunSequence repetidamente, executando o Run dos
  !! conectores e o label_DataInitialize dos componentes, até que todos
  !! declarem InitializeDataComplete. Se o MED declarasse "true"
  !! incondicionalmente na primeira passagem, o laço pararia ali.
  !!
  !! Na RunSequence SEQUENCIAL o conector "OCN -> MED" vem ANTES do elemento
  !! "OCN", ou seja, antes de o mom_cap escrever So_t em InitializeDataComplete.
  !! Com uma única passagem, o So_t que chega aqui é o campo ainda não
  !! preenchido. Na RunSequence CONCORRENTE a ordem é inversa ("OCN" antes de
  !! "OCN -> MED"), e uma única passagem bastaria, mas só por acidente de
  !! ordenação. O pet_layout não tem parte nisso: o mesmo problema ocorreria
  !! em sequential+shared.
  !!
  !! Três partes:
  !!   fase A   (só na primeira passagem) rotas de inicialização, correntes e
  !!            valores iniciais do exportState (prepara_inicio). O
  !!            FieldRegridStore depende só da GEOMETRIA dos campos, nunca
  !!            dos valores; é caro e não deve repetir.
  !!   portão   So_t já chegou com valor físico (aguarda_primeira_sst)?
  !!            Se não, pede outra passagem e retorna.
  !!   fase B   SST de t=0 publicada, carimbo de startTime nos campos
  !!            exportados e InitializeDataComplete declarado.
  !!
  !! @param[inout] gcomp        o mediador (atributos de inicialização)
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação do mediador
  !! @param[inout] exportState  estado de exportação do mediador
  !! @param[inout] clock        relógio do mediador
  !! @param[inout] rc           ESMF_SUCCESS ou o código do erro
  subroutine inicializar_dados(gcomp, is, importState, exportState, clock, rc)
    type(ESMF_GridComp)              :: gcomp
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout)  :: importState
    type(ESMF_State), intent(inout)  :: exportState
    type(ESMF_Clock), intent(inout)  :: clock
    integer,          intent(inout)  :: rc
    type(ESMF_Time)  :: startTime
    type(ESMF_Field) :: ocn_field, exp_field
    logical :: sst_ready

    call idc_check_atm_field(is, importState, rc)
    if (rc /= ESMF_SUCCESS) return

    ! Obter campo de export para o OCN (Foxx_taux esta na grade OCN)
    call ESMF_StateGet(exportState, itemName="Foxx_taux", field=exp_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha Foxx_taux", &
      line=__LINE__, file=__FILE__)) return

    ! Fase A (só na primeira passagem)
    if (.not. is%regrid%has('ocn2atm')) then
      call prepara_inicio(is, importState, exportState, exp_field, rc)
      if (rc /= ESMF_SUCCESS) return
    end if

    ! Portão: So_t já chegou com valor físico?
    call aguarda_primeira_sst(gcomp, is, importState, clock, ocn_field, startTime, &
                              sst_ready, rc)
    if (.not. sst_ready) return

    ! Fase B (So_t válido em mãos)
    call idc_publish_initial_sst(is, importState, exportState, ocn_field)
    call idc_stamp_export(exportState, startTime, rc)

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", value="true", rc=rc)
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", value="true", rc=rc)

    call ESMF_LogWrite('MED: InitializeDataComplete SATISFIED (So_t em t=0)', &
      ESMF_LOGMSG_INFO)
  end subroutine inicializar_dados

  !> Cria, na ordem de ROTAS, as rotas com criar='inicio', cada uma com o
  !! seu par de campos: atm2ocn de is%ocn_flx%taux (malha de fluxo) para
  !! exp_field (Foxx_taux, grade OCN), se ainda não existe; ocn2atm de So_t
  !! (grade OCN) para is%ocn%sst (malha de fluxo). Uma rota 'inicio' sem par
  !! de campos aqui é erro: a tabela e esta rotina andam juntas.
  !!
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação (So_t)
  !! @param[inout] exp_field    Foxx_taux no exportState
  !! @param[inout] rc           ESMF_SUCCESS ou o código do erro
  subroutine cria_rotas_inicio(is, importState, exp_field, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: exp_field
    integer, intent(inout) :: rc
    type(ESMF_Field) :: ocn_field
    integer :: k

    do k = 1, size(ROTAS)
      if (trim(ROTAS(k)%criar) /= 'inicio') cycle
      select case (trim(ROTAS(k)%nome))
      case ('atm2ocn')
        if (.not. is%regrid%has('atm2ocn')) then
          call cria_rota(is%regrid, 'atm2ocn', is%ocn_flx%taux, exp_field, rc)
          if (ChkErr(rc, __LINE__, __FILE__)) return
        end if
      case ('ocn2atm')
        ! So_t está na grade OCN (ver InitializeRealize)
        call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        call cria_rota(is%regrid, 'ocn2atm', ocn_field, is%ocn%sst, rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
      case default
        call ESMF_LogSetError(ESMF_RC_NOT_IMPL, &
          msg='MED: rota de inicio sem campos em cria_rotas_inicio: '//trim(ROTAS(k)%nome), &
          line=__LINE__, file=__FILE__, rcToReturn=rc)
        return
      end select
    end do
  end subroutine cria_rotas_inicio

  !> Fase A da inicialização: cria as rotas da coluna criar='inicio' de
  !! ROTAS (cria_rotas_inicio), interpola as correntes e preenche o
  !! exportState com valores iniciais. Roda uma unica vez (enquanto a rota
  !! 'ocn2atm' nao existe).
  subroutine prepara_inicio(is, importState, exportState, exp_field, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: exp_field
    integer, intent(inout) :: rc

    call cria_rotas_inicio(is, importState, exp_field, rc)
    if (rc /= ESMF_SUCCESS) return

    ! Correntes So_u/So_v: mesma grade de So_t, mesma rota.
    call regrid_ocean_currents(is, importState, zero_on_error=.true.)

    call idc_init_export_fields(exportState)

    ! Si_ifrac_sis2 e os 4 albedos do gelo sao realizados pelo MED em
    ! ocn_grid, a MESMA grade de So_t (ver InitializeRealize); a rota
    ! mascarada propria do gelo, 'ocn2atm_ice', e' criada na primeira chamada
    ! de update_ice_fields_on_atm_grid.

    call ESMF_LogWrite('MED: IDC fase A: rotas de interpolacao criadas', ESMF_LOGMSG_INFO)
  end subroutine prepara_inicio

  !> Espera da primeira SST (portão de dados da inicialização): So_t já foi
  !! escrito pelo oceano?
  !!
  !! O mom_cap (e o DOCN) carimbam TODOS os campos exportados com startTime em
  !! seu InitializeDataComplete, e o conector NUOPC propaga o carimbo ao campo
  !! de destino. Portanto NUOPC_IsAtTime distingue exatamente os dois casos:
  !! So_t recem-chegado do oceano (carimbado) contra o campo ainda nao escrito
  !! (sem carimbo). Carimbo, porem, nao e' dado: ver sst_has_physical_values.
  !!
  !! Enquanto o dado nao chega, declaramos Progress=true (a fase A progrediu:
  !! os routehandles existem) e Complete=false (idc_wait_for_sst). Isso forca
  !! o driver a percorrer a RunSequence outra vez; na segunda passagem o
  !! "OCN -> MED" ja' encontra o So_t escrito pelo "OCN" da passagem
  !! anterior, e o portão abre.
  !!
  !! @param[out] ocn_field  So_t no importState (grade OCN)
  !! @param[out] startTime  início da simulação, no relógio do mediador
  !! @param[out] pronta     .true. se So_t chegou com valor físico; .false.
  !!                        se ainda não chegou ou se houve erro (rc)
  subroutine aguarda_primeira_sst(gcomp, is, importState, clock, ocn_field, startTime, &
                                  pronta, rc)
    type(ESMF_GridComp)              :: gcomp
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout)  :: importState
    type(ESMF_Clock), intent(inout)  :: clock
    type(ESMF_Field), intent(out)    :: ocn_field
    type(ESMF_Time),  intent(out)    :: startTime
    logical,          intent(out)    :: pronta
    integer,          intent(inout)  :: rc
    logical :: sst_ready

    pronta = .false.
    call ESMF_ClockGet(clock, startTime=startTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha So_t (gate)", &
      line=__LINE__, file=__FILE__)) return

    sst_ready = NUOPC_IsAtTime(ocn_field, startTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (sst_ready) then
      call sst_has_physical_values(ocn_field, sst_ready, rc)
      if (rc /= ESMF_SUCCESS) return
    end if

    if (.not. sst_ready) then
      call idc_wait_for_sst(gcomp, is, rc)
      return
    end if

    pronta = .true.
  end subroutine aguarda_primeira_sst

  !> Confere que o campo de referencia da grade ATM existe no importState:
  !! Sa_u10m_mpas no modo MPAS, Sa_u10m no modo DATM (is%use_mpas_atm, lido
  !! em InitializeRealize). rc de falha quando o campo nao existe.
  subroutine idc_check_atm_field(is, importState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    integer, intent(inout) :: rc
    type(ESMF_Field) :: atm_field

    if (is%use_mpas_atm) then
      call ESMF_StateGet(importState, itemName="Sa_u10m_mpas", &
        field=atm_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED IDC: Sa_u10m_mpas nao encontrado", &
        line=__LINE__, file=__FILE__)) return
    else
      call ESMF_StateGet(importState, itemName="Sa_u10m", &
        field=atm_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED IDC: Sa_u10m nao encontrado", &
        line=__LINE__, file=__FILE__)) return
    end if
  end subroutine idc_check_atm_field

  !> CARIMBO NAO E' DADO: com So_t carimbado (sst_ready), exige tambem VALOR
  !! fisicamente plausivel, em [270,310] K, em alguma celula, contado
  !! GLOBALMENTE (um DE pode legitimamente conter so' terra e gelo). Sem
  !! nenhuma, sst_ready passa a .false.
  !!
  !! O mom_cap aplica NUOPC_SetTimestamp a TODOS os campos do exportState em
  !! seu InitializeDataComplete, em laco cego sobre o itemNameList, sem
  !! verificar quais deles o mom_export realmente preencheu. Um So_t
  !! identicamente nulo passa no NUOPC_IsAtTime. Foi o que aconteceu quando
  !! ocean_model_init_sfc nao era chamado: o gate abria, o mediador seguia, e
  !! a extrapolacao da secao 3 convertia o campo inteiro em T_FILL=271.35 K,
  !! o que levava a mascara de terra, entao baseada na SST, a classificar o
  !! planeta inteiro como terra e zerar os 11 campos de fluxo.
  !!
  !! Coletivo sobre a VM do MED (ESMF_VMAllReduce): todos os PETs do
  !! mediador entram aqui.
  subroutine sst_has_physical_values(ocn_field, sst_ready, rc)
    type(ESMF_Field), intent(in) :: ocn_field
    logical, intent(inout) :: sst_ready
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: sstp(:,:)
    type(ESMF_VM) :: vm
    character(len=160) :: msg_gate
    integer :: lde, ldec_sst, localrc
    integer :: n_phys_s(1), n_phys_g(1)

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    n_phys_s(1) = 0
    call ESMF_FieldGet(ocn_field, localDeCount=ldec_sst, rc=localrc)
    if (localrc == ESMF_SUCCESS) then
      do lde = 0, ldec_sst - 1
        nullify(sstp)
        call ESMF_FieldGet(ocn_field, localDe=lde, farrayPtr=sstp, rc=localrc)
        if (localrc /= ESMF_SUCCESS .or. .not. associated(sstp)) cycle
        n_phys_s(1) = n_phys_s(1) + &
          count(sstp > 270.0_ESMF_KIND_R8 .and. sstp < 310.0_ESMF_KIND_R8)
      end do
    end if

    call ESMF_VMAllReduce(vm, n_phys_s, n_phys_g, 1, ESMF_REDUCE_SUM, rc=localrc)
    if (localrc /= ESMF_SUCCESS) n_phys_g(1) = n_phys_s(1)

    if (n_phys_g(1) == 0) then
      sst_ready = .false.
      call ESMF_LogWrite('MED: IDC — So_t carimbado mas SEM valor fisico '// &
        '(nenhuma celula em [270,310] K no globo)', ESMF_LOGMSG_WARNING)
    else
      write(msg_gate,'(A,I0,A)') 'MED: IDC — So_t com ', n_phys_g(1), &
        ' celulas em [270,310] K'
      call ESMF_LogWrite(trim(msg_gate), ESMF_LOGMSG_INFO)
    end if
  end subroutine sst_has_physical_values

  !> So_t ainda sem dado: pede ao driver mais uma iteracao do laco de
  !! dependencia de dados (Progress=true, Complete=false). Depois de
  !! MAX_GATE_TRIES tentativas, avisa e declara Complete=true.
  !!
  !! Falhar alto em vez de seguir com SST nula: era exatamente esse
  !! prosseguimento silencioso que produzia mapas de fluxo em branco no
  !! passo 1, com a causa escondida a tres camadas de distancia.
  subroutine idc_wait_for_sst(gcomp, is, rc)
    type(ESMF_GridComp) :: gcomp
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    integer, parameter :: MAX_GATE_TRIES = 5

    is%run%n_gate_tries = is%run%n_gate_tries + 1
    if (is%run%n_gate_tries >= MAX_GATE_TRIES) then
      ! AVISO, nao aborto. O modelo de como o driver NUOPC percorre a
      ! RunSequence durante a resolucao de dependencia de dados ainda nao
      ! esta plenamente verificado: o gate ja' foi observado fechando uma
      ! vez em coupling_mode='concurrent', onde a ordem dos elementos
      ! preveria abertura imediata. Enquanto essa discrepancia nao for
      ! entendida, abortar aqui arriscaria derrubar execucoes que hoje
      ! funcionam. O aviso e' alto e nomeia o que inspecionar; o
      ! comportamento anterior a este gate e' preservado.
      call ESMF_LogWrite('MED: AVISO — So_t sem valores fisicos apos '// &
        'varias iteracoes do laco de dependencia de dados; prosseguindo.', &
        ESMF_LOGMSG_WARNING)
      call ESMF_LogWrite('  A SST em t=0 pode estar nula. Inspecione '// &
        '"So_t BRUTO" e "[MED-DIAG] f_sst_atm" no passo 1 antes de '// &
        'confiar nos fluxos.', ESMF_LOGMSG_WARNING)
      call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", &
        value="true", rc=rc)
      call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
        value="true", rc=rc)
      return
    end if
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", &
      value="true", rc=rc)
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
      value="false", rc=rc)
    call ESMF_LogWrite('MED: IDC aguardando So_t do OCN — '// &
      'nova iteracao do laco de dependencia de dados', ESMF_LOGMSG_INFO)
  end subroutine idc_wait_for_sst

  !> Fase B de InitializeDataComplete: correntes e SST de t=0 na grade ATM.
  !!
  !! Primeiro regrid de So_u e So_v para is%ocn%u/is%ocn%v, pela rota
  !! 'ocn2atm' (bilinear, criada na fase A): So_u/So_v compartilham a grade
  !! OCN de So_t. Depois, a SST de t=0: sem ela, is%ocn%sst ficaria no valor
  !! de bootstrap SST_BULK_FALLBACK ate' o primeiro MediatorAdvance, e o
  !! conector MED -> MPAS entregaria essa constante ao MPAS. A SST e'
  !! publicada no exportState (zerado na fase A), para que o "MED -> MPAS"
  !! desta mesma passagem entregue SST fisica, e nao zero.
  subroutine idc_publish_initial_sst(is, importState, exportState, ocn_field)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: ocn_field
    integer :: localrc

    call regrid_ocean_currents(is, importState, zero_on_error=.true.)

    call is%regrid%apply('ocn2atm', ocn_field, is%ocn%sst, localrc)
    if (localrc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: IDC — regrid So_t->ATM falhou; '// &
        'mantido SST_BULK_FALLBACK', ESMF_LOGMSG_WARNING)
    else
      call RegridOrCopy(is%ocn%sst, exportState, "So_t", is, localrc)
      if (localrc /= ESMF_SUCCESS) &
        call ESMF_LogWrite('MED: IDC — RegridOrCopy So_t falhou', &
          ESMF_LOGMSG_WARNING)
    end if
  end subroutine idc_publish_initial_sst

  !> Carimba os campos exportados com startTime: e' o que permite ao MPAS
  !! (e a qualquer consumidor futuro) aplicar o mesmo gate NUOPC_IsAtTime.
  subroutine idc_stamp_export(exportState, startTime, rc)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Time), intent(in) :: startTime
    integer, intent(inout) :: rc
    type(ESMF_Field) :: exp_field
    character(len=64), allocatable :: fieldNameList(:)
    integer :: fieldCount
    integer :: i
    integer :: localrc

    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (fieldCount > 0) then
      allocate(fieldNameList(fieldCount))
      call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
      do i = 1, fieldCount
        call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
          field=exp_field, rc=localrc)
        if (localrc == ESMF_SUCCESS) &
          call NUOPC_SetTimestamp(exp_field, startTime, rc=localrc)
      end do
      deallocate(fieldNameList)
    end if
  end subroutine idc_stamp_export

  !> Inicializa o exportState com valores fisicamente razoaveis: Sa_pslv
  !! com 101325 Pa e os demais campos com zero. PETs sem DE local nao tem o
  !! que inicializar (ESMF_FieldGet com farrayPtr falharia neles).
  subroutine idc_init_export_fields(exportState)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field) :: exp_field
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    character(len=64), allocatable :: fieldNameList(:)
    integer :: fieldCount
    integer :: i
    integer :: localDeCount_exp
    integer :: localrc
    integer :: rc

    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (fieldCount > 0) then
      allocate(fieldNameList(fieldCount))
      call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
      do i = 1, fieldCount
        call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
          field=exp_field, rc=rc)
        call ESMF_FieldGet(exp_field, localDeCount=localDeCount_exp, rc=localrc)
        if (localDeCount_exp == 0) cycle   ! PET sem DE local — nada a inicializar
        call ESMF_FieldGet(exp_field, farrayPtr=fptr, rc=rc)
        select case(trim(fieldNameList(i)))
          case('Sa_pslv')
            fptr = 101325.0_ESMF_KIND_R8
          case default
            fptr = 0.0_ESMF_KIND_R8
        end select
      end do
      deallocate(fieldNameList)
    end if
  end subroutine idc_init_export_fields

  ! ---------------------------------------------------------------------------
  ! Fases de cada passo
  ! ---------------------------------------------------------------------------

  !> Fase ir_para_malha_de_fluxo: os campos do oceano e do gelo na malha de
  !! fluxo, antes da física, nesta ordem:
  !!
  !!   1. SST, correntes e, com o SIS2, a fração, os albedos e a temperatura
  !!      do gelo (update_ocean_fields_on_atm_grid, em med_ocean, que usa
  !!      med_ice para o gelo).
  !!      Máscara terra/oceano: o mom_cap_methods::state_setexport multiplica
  !!      a SST por ocean_grid%mask2dT antes do export; sobre terra, SST=0 K
  !!      na grade OCN. Um regrid bilinear sem máscara misturaria esses zeros
  !!      nas células oceânicas próximas à costa, que cairiam abaixo de
  !!      270 K. A máscara não é adivinhada pelo próprio valor da SST: vem de
  !!      So_omask = nint(mask2dT), exportada pelo MOM6
  !!      (mom_cap_methods.F90::mom_export). Assim a interpolação só usa
  !!      células oceânicas válidas como fonte. O resíduo não mapeado na costa
  !!      (sem vizinho válido) é completado por vizinhança pela rota.
  !!   2. Si_ifrac do OISST, com use_docn_ice (update_ice_fraction_from_docn,
  !!      em med_ocean). Modos (nuopc.input, &nuopc_mode):
  !!        use_docn_ice=T, init_only=F: fill_ifrac_from_oisst a cada passo
  !!          (campo congelado no OISST);
  !!        use_docn_ice=T, init_only=T: fill_ifrac_from_oisst só no primeiro
  !!          passo (is%run%ifrac_init_done); nos demais, o campo decai
  !!          exponencialmente (SI_IFRAC_DECAY, de coupler_constants);
  !!        use_docn_ice=F: nada; com o SIS2 dinâmico, Si_ifrac já veio do
  !!          gelo no item 1.
  !!
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação do mediador
  !! @param[inout] clock        relógio do mediador
  !! @param[inout] rc           código de retorno (o da última operação)
  subroutine ir_para_malha_de_fluxo(is, importState, clock, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Clock), intent(inout) :: clock
    integer,          intent(inout) :: rc
    type(ESMF_Field) :: field
    real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:) => null()

    call update_ocean_fields_on_atm_grid(is, importState, field, is%run%raw_sst_diag_done, rc)
    call update_ice_fraction_from_docn(is, clock, ifrac_ptr, rc)
  end subroutine ir_para_malha_de_fluxo

  !> Fase entregar: exportação dos campos da malha de fluxo e carimbo de
  !! tempo, nesta ordem:
  !!   1. export_to_components (med_export);
  !!   2. stampTime em cada campo do exportState (stamp_export_fields);
  !!   3. com use_med_to_mpas, o tempo atual do relógio no exportState
  !!      (stamp_state_clock); uma falha aqui só vai para o log.
  !!
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação do mediador
  !! @param[inout] exportState  estado de exportação do mediador
  !! @param[in]    clock        relógio do mediador
  !! @param[inout] stampTime    instante que rotula o resultado do passo
  !! @param[inout] rc           código de retorno (o da última operação)
  subroutine entregar(is, importState, exportState, clock, stampTime, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Clock), intent(in)    :: clock
    type(ESMF_Time),  intent(inout) :: stampTime
    integer,          intent(inout) :: rc
    type(ESMF_Field) :: field

    call export_to_components(is, importState, exportState, rc)
    call stamp_export_fields(exportState, field, stampTime, rc)

    ! Com use_med_to_mpas (nuopc_mode), o conector MED -> MPAS entrega ao
    ! MONAN-A os campos do exportState com o tempo atual do relógio.
    if (is%use_med_to_mpas) then
      call stamp_state_clock(exportState, clock, is, rc)
      if (rc /= ESMF_SUCCESS) then
        call ESMF_LogWrite('MED: RouteOcnToAtm retornou erro — continuando', &
          ESMF_LOGMSG_WARNING)
        rc = ESMF_SUCCESS
      end if
    end if
  end subroutine entregar

  !> Carimba stampTime em cada campo do exportState. field é só a variável
  !! de trabalho do laço.
  subroutine stamp_export_fields(exportState, field, stampTime, rc)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: field
    type(ESMF_Time), intent(inout) :: stampTime
    integer, intent(inout) :: rc
    integer :: fieldCount
    character(len=64), allocatable :: fieldNameList(:)
    integer :: k
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fieldNameList(k)), &
        field=field, rc=rc)
      call NUOPC_SetTimestamp(field, stampTime, rc=rc)
    end do
    deallocate(fieldNameList)
  end subroutine stamp_export_fields

  !> Carimba o exportState inteiro com o tempo atual do relógio (até a
  !! R-FASE11-15, RouteOcnToAtm, em med_cap_methods). Só depois que a rota
  !! ocn2atm existe; antes disso, avisa no log e não carimba.
  !!
  !! @param[inout] exportState  estado de exportação do mediador
  !! @param[in]    clock        relógio do mediador
  !! @param[in]    is           estado interno do mediador
  !! @param[out]   rc           ESMF_SUCCESS ou o código de NUOPC_SetTimestamp
  subroutine stamp_state_clock(exportState, clock, is, rc)
    type(ESMF_State),        intent(inout) :: exportState
    type(ESMF_Clock),        intent(in)    :: clock
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    rc = ESMF_SUCCESS

    ! Guard: routehandles devem estar criados
    if (.not. is%regrid%has('ocn2atm')) then
      call ESMF_LogWrite( &
        'MED RouteOcnToAtm: rota ocn2atm ainda nao criada; pulando', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
      return
    end if

    ! Estampilar timestamp no exportState (MPAS usa para validação)
    call NUOPC_SetTimestamp(exportState, clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg='MED RouteOcnToAtm: falha NUOPC_SetTimestamp', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('MED RouteOcnToAtm: regrid OCN->ATM concluido (Fase 2)', &
      ESMF_LOGMSG_INFO)

  end subroutine stamp_state_clock

end module med_exchange_mod
