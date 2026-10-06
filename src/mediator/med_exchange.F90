!> @file med_exchange.F90
!! @brief Trocas do mediador, por fase.
!!
!! O mediador troca campos com os componentes em fases fixas, na
!! inicialização e a cada passo (ver docs/arquitetura-acoplamento.md, seção
!! 2). Este módulo reúne essas fases:
!!
!!   initialize_data
!!              InitializeDataComplete: rotas de inicialização (coluna
!!              create='inicio' de ROUTES), espera da primeira SST do oceano e
!!              valores de t=0 no exportState
!!   go_to_flux_grid
!!              antes da física: leva os campos do oceano e do gelo da
!!              grade do oceano para a malha de fluxo
!!   compute_fluxes
!!              a física bulk (calc_bulk_ncar, em med_bulk_ncar) sobre os
!!              arrays da malha de fluxo (med_flux_t), associados aqui aos
!!              campos internos
!!   ice_fraction_without_sis2
!!              logo depois da física, sem o SIS2: a fração de gelo na malha
!!              de fluxo (OISST ou limiar de SST) para a exportação e para o
!!              passo seguinte
!!   deliver    no fim do passo, depois da física: leva os campos da malha
!!              de fluxo para o exportState (export_to_components, em
!!              med_export) e carimba o tempo dos campos exportados
!!
!! O carimbo de tempo dos campos que o mediador entrega fica só aqui. Na
!! inicialização, cada campo do exportState recebe startTime
!! (idc_stamp_export). A cada passo, cada campo recebe stampTime (ver med_stamp_time, em MED_cap)
!! e, com use_med_to_mpas, o exportState inteiro recebe depois o tempo atual
!! do relógio, que prevalece.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_exchange_mod
  use ESMF
  use NUOPC,               only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet, NUOPC_IsAtTime
  use coupler_utils_mod,   only: ChkErr
  use coupler_config_mod,  only: cfg_use_sis2_dynamic
  use coupler_log_mod,     only: COMP_MED, log_info, log_warning, log_debug, log_debug_enabled
  use cpl_map_mod,         only: ROUTES
  use med_cap_types_mod,   only: MED_InternalState, med_flux_t
  use med_bulk_ncar_mod,   only: calc_bulk_ncar
  use med_cap_methods_mod, only: create_route, RegridOrCopy, set_ocn_grid_mask
  use med_export_mod,      only: export_to_components
  use med_diag_mod,        only: log_ocean_mask
  use med_ocean_mod,       only: update_ocean_fields_on_atm_grid, &
                                 update_ice_fraction_from_docn, regrid_ocean_currents, &
                                 legacy_ice_fraction

  implicit none
  private

  public :: initialize_data
  public :: prepare_start         ! também para tests/completar
  public :: go_to_flux_grid
  public :: compute_fluxes
  public :: ice_fraction_without_sis2
  public :: deliver
  public :: stamp_export_fields

contains

  ! Fase de inicialização

  !> @brief Fase de inicialização (InitializeDataComplete do mediador). Pode ser
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
  !!            valores iniciais do exportState (prepare_start). O
  !!            FieldRegridStore depende só da GEOMETRIA dos campos, nunca
  !!            dos valores; é caro e não deve repetir.
  !!   portão   So_t já chegou com valor físico (wait_first_sst)?
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
  subroutine initialize_data(gcomp, is, importState, exportState, clock, rc)
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
      call prepare_start(is, importState, exportState, exp_field, rc)
      if (rc /= ESMF_SUCCESS) return
    end if

    ! Portão: So_t já chegou com valor físico?
    call wait_first_sst(gcomp, is, importState, clock, ocn_field, startTime, &
                              sst_ready, rc)
    if (.not. sst_ready) return

    ! Fase B (So_t válido em mãos)
    call idc_publish_initial_sst(is, importState, exportState, ocn_field)
    call idc_stamp_export(exportState, startTime, rc)

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", value="true", rc=rc)
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", value="true", rc=rc)

    call log_info(COMP_MED, 'InitializeDataComplete SATISFIED (So_t em t=0)')
  end subroutine initialize_data

  !> @brief Cria, na ordem de ROUTES, as rotas com create='inicio', cada uma com o
  !! seu par de campos: atm2ocn de is%ocn_flx%taux (malha de fluxo) para
  !! exp_field (Foxx_taux, grade OCN), se ainda não existe; ocn2atm de So_t
  !! (grade OCN) para is%ocn%sst (malha de fluxo). Uma rota 'inicio' sem par
  !! de campos aqui é erro: a tabela e esta rotina andam juntas.
  !!
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação (So_t)
  !! @param[inout] exp_field    Foxx_taux no exportState
  !! @param[inout] rc           ESMF_SUCCESS ou o código do erro
  subroutine create_start_routes(is, importState, exp_field, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: exp_field
    integer, intent(inout) :: rc
    type(ESMF_Field) :: ocn_field
    integer :: k

    do k = 1, size(ROUTES)
      if (trim(ROUTES(k)%create) /= 'inicio') cycle
      select case (trim(ROUTES(k)%name))
      case ('atm2ocn')
        if (.not. is%regrid%has('atm2ocn')) then
          call create_route(is%regrid, 'atm2ocn', is%ocn_flx%taux, exp_field, rc)
          if (ChkErr(rc, __LINE__, __FILE__)) return
        end if
      case ('ocn2atm')
        ! So_t está na grade OCN (ver InitializeRealize)
        call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        call create_route(is%regrid, 'ocn2atm', ocn_field, is%ocn%sst, rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
      case default
        call ESMF_LogSetError(ESMF_RC_NOT_IMPL, &
          msg='MED: rota de inicio sem campos em cria_rotas_inicio: '//trim(ROUTES(k)%name), &
          line=__LINE__, file=__FILE__, rcToReturn=rc)
        return
      end select
    end do
  end subroutine create_start_routes

  !> @brief Fase A da inicialização: cria as rotas da coluna create='inicio' de
  !! ROUTES (create_start_routes), interpola as correntes e preenche o
  !! exportState com valores iniciais. Roda uma única vez (enquanto a rota
  !! 'ocn2atm' não existe).
  subroutine prepare_start(is, importState, exportState, exp_field, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: exp_field
    integer, intent(inout) :: rc

    call create_start_routes(is, importState, exp_field, rc)
    if (rc /= ESMF_SUCCESS) return

    ! Correntes So_u/So_v: mesma grade de So_t, mesma rota.
    call regrid_ocean_currents(is, importState, zero_on_error=.true.)

    call idc_init_export_fields(exportState)

    ! Si_ifrac_sis2 e os 4 albedos do gelo são realizados pelo MED em
    ! ocn_grid, a MESMA grade de So_t (ver InitializeRealize); a rota
    ! mascarada própria do gelo, 'ocn2atm_ice', é criada na primeira chamada
    ! de update_ice_fields_on_atm_grid.

    call log_info(COMP_MED, 'IDC fase A: rotas de interpolacao criadas')
  end subroutine prepare_start

  !> @brief Espera da primeira SST (portão de dados da inicialização): So_t já foi
  !! escrito pelo oceano?
  !!
  !! O mom_cap (e o DOCN) carimbam TODOS os campos exportados com startTime em
  !! seu InitializeDataComplete, e o conector NUOPC propaga o carimbo ao campo
  !! de destino. Portanto NUOPC_IsAtTime distingue exatamente os dois casos:
  !! So_t recém-chegado do oceano (carimbado) contra o campo ainda não escrito
  !! (sem carimbo). Carimbo, porém, não é dado: ver sst_has_physical_values.
  !!
  !! Enquanto o dado não chega, declaramos Progress=true (a fase A progrediu:
  !! os routehandles existem) e Complete=false (idc_wait_for_sst). Isso força
  !! o driver a percorrer a RunSequence outra vez; na segunda passagem o
  !! "OCN -> MED" já encontra o So_t escrito pelo "OCN" da passagem
  !! anterior, e o portão abre.
  !!
  !! @param[out] ocn_field  So_t no importState (grade OCN)
  !! @param[out] startTime  início da simulação, no relógio do mediador
  !! @param[out] ready      .true. se So_t chegou com valor físico; .false.
  !!                        se ainda não chegou ou se houve erro (rc)
  subroutine wait_first_sst(gcomp, is, importState, clock, ocn_field, startTime, &
                                  ready, rc)
    type(ESMF_GridComp)              :: gcomp
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout)  :: importState
    type(ESMF_Clock), intent(inout)  :: clock
    type(ESMF_Field), intent(out)    :: ocn_field
    type(ESMF_Time),  intent(out)    :: startTime
    logical,          intent(out)    :: ready
    integer,          intent(inout)  :: rc
    logical :: sst_ready

    ready = .false.
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

    ready = .true.
  end subroutine wait_first_sst

  !> @brief Confere que o campo de referência da grade ATM existe no importState:
  !! Sa_u10m_mpas no modo MPAS, Sa_u10m no modo DATM (is%use_mpas_atm, lido
  !! em InitializeRealize). rc de falha quando o campo não existe.
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

  !> @brief CARIMBO NÃO É DADO: com So_t carimbado (sst_ready), exige também VALOR
  !! fisicamente plausível, em [270,310] K, em alguma célula, contado
  !! GLOBALMENTE (um DE pode legitimamente conter só terra e gelo). Sem
  !! nenhuma, sst_ready passa a .false.
  !!
  !! O mom_cap aplica NUOPC_SetTimestamp a TODOS os campos do exportState em
  !! seu InitializeDataComplete, em laco cego sobre o itemNameList, sem
  !! verificar quais deles o mom_export realmente preencheu. Um So_t
  !! identicamente nulo passa no NUOPC_IsAtTime; sem esta conferência, a
  !! extrapolação levaria o campo inteiro a T_FILL=271.35 K e os fluxos
  !! sairiam como se o planeta fosse todo terra.
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
      call log_warning(COMP_MED, 'IDC: So_t carimbado mas sem valor fisico '// &
        '(nenhuma celula em [270,310] K no globo)')
    else
      write(msg_gate,'(A,I0,A)') 'IDC: So_t com ', n_phys_g(1), &
        ' celulas em [270,310] K'
      call log_info(COMP_MED, trim(msg_gate))
    end if
  end subroutine sst_has_physical_values

  !> @brief So_t ainda sem dado: pede ao driver mais uma iteração do laco de
  !! dependência de dados (Progress=true, Complete=false). Depois de
  !! MAX_GATE_TRIES tentativas, avisa e declara Complete=true.
  !!
  !! Avisa alto em vez de seguir em silêncio com SST nula, que produziria
  !! mapas de fluxo em branco no passo 1 sem indicar a causa.
  subroutine idc_wait_for_sst(gcomp, is, rc)
    type(ESMF_GridComp) :: gcomp
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    integer, parameter :: MAX_GATE_TRIES = 5

    is%run%n_gate_tries = is%run%n_gate_tries + 1
    if (is%run%n_gate_tries >= MAX_GATE_TRIES) then
      ! AVISO, não aborto. O modelo de como o driver NUOPC percorre a
      ! RunSequence durante a resolução de dependência de dados ainda não
      ! está plenamente verificado: o gate já foi observado fechando uma
      ! vez em coupling_mode='concurrent', onde a ordem dos elementos
      ! preveria abertura imediata. Enquanto essa discrepância não for
      ! entendida, abortar aqui arriscaria derrubar execuções que hoje
      ! funcionam. O aviso nomeia o que inspecionar, e a rodada segue.
      call log_warning(COMP_MED, 'So_t sem valores fisicos apos varias iteracoes '// &
        'do laco de dependencia de dados; prosseguindo. A SST em t=0 pode estar '// &
        'nula: com log_level=''debug'', inspecione "DIAG sst raw" no passo 1 '// &
        'antes de confiar nos fluxos.')
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
    call log_info(COMP_MED, 'IDC aguardando So_t do OCN: '// &
      'nova iteracao do laco de dependencia de dados')
  end subroutine idc_wait_for_sst

  !> @brief Fase B de InitializeDataComplete: correntes e SST de t=0 na grade ATM.
  !!
  !! Primeiro regrid de So_u e So_v para is%ocn%u/is%ocn%v, pela rota
  !! 'ocn2atm' (bilinear, criada na fase A): So_u/So_v compartilham a grade
  !! OCN de So_t. Depois, a SST de t=0: sem ela, is%ocn%sst ficaria no valor
  !! de bootstrap SST_BULK_FALLBACK até o primeiro MediatorAdvance, e o
  !! conector MED -> MPAS entregaria essa constante ao MPAS. A SST é
  !! publicada no exportState (zerado na fase A), para que o "MED -> MPAS"
  !! desta mesma passagem entregue SST física, e não zero.
  subroutine idc_publish_initial_sst(is, importState, exportState, ocn_field)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: ocn_field
    integer :: localrc

    call regrid_ocean_currents(is, importState, zero_on_error=.true.)

    call is%regrid%apply('ocn2atm', ocn_field, is%ocn%sst, localrc)
    if (localrc /= ESMF_SUCCESS) then
      call log_warning(COMP_MED, 'IDC: interpolacao de So_t para a ATM falhou; '// &
        'mantido SST_BULK_FALLBACK')
    else
      call RegridOrCopy(is%ocn%sst, exportState, "So_t", is, localrc)
      if (localrc /= ESMF_SUCCESS) &
        call log_warning(COMP_MED, 'IDC: RegridOrCopy So_t falhou')
    end if
  end subroutine idc_publish_initial_sst

  !> @brief Carimba os campos exportados com startTime: é o que permite ao MPAS
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

  !> @brief Inicializa o exportState com valores fisicamente razoáveis: Sa_pslv
  !! com 101325 Pa e os demais campos com zero. PETs sem DE local não tem o
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

  ! Fases de cada passo

  !> @brief Fase go_to_flux_grid: os campos do oceano e do gelo na malha de
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
  subroutine go_to_flux_grid(is, importState, clock, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Clock), intent(inout) :: clock
    integer,          intent(inout) :: rc
    type(ESMF_Field) :: field
    real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:) => null()

    call ensure_flux_grid_routes(is, importState)
    call update_ocean_fields_on_atm_grid(is, importState, field, is%run%raw_sst_diag_done, rc)
    call update_ice_fraction_from_docn(is, clock, ifrac_ptr, rc)
  end subroutine go_to_flux_grid

  !> @brief Rotas da ida para a malha de fluxo criadas durante o passo, conforme a
  !! coluna create de ROUTES, nesta ordem (a ordem das linhas "rota" no
  !! relatório de acoplamento):
  !!   ocn2atm_sst  'mascara_mista': set_ocean_mask_for_sst grava a máscara
  !!                do oceano na grade e só cria a rota quando ela tem terra
  !!                e mar; até lá, a SST usa a rota ocn2atm;
  !!   ocn2atm_ice  'primeiro_uso': com o SIS2, na primeira vez que
  !!                Si_ifrac_sis2 está no importState (add_ice_route).
  !! Nada é criado antes da rota ocn2atm (fase A da inicialização).
  !!
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação do mediador
  subroutine ensure_flux_grid_routes(is, importState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field) :: sst_ocn, f_ifrac_src
    integer :: rc_route

    if (.not. is%regrid%has('ocn2atm')) return

    call ESMF_StateGet(importState, itemName="So_t", field=sst_ocn, rc=rc_route)
    if (.not. is%regrid%has('ocn2atm_sst')) &
      call set_ocean_mask_for_sst(is, importState, sst_ocn, rc_route)

    if (cfg_use_sis2_dynamic) then
      call ESMF_StateGet(importState, itemName="Si_ifrac_sis2", &
        field=f_ifrac_src, rc=rc_route)
      if (.not. is%regrid%has('ocn2atm_ice') .and. rc_route == ESMF_SUCCESS) &
        call add_ice_route(is, importState, f_ifrac_src)
    end if
  end subroutine ensure_flux_grid_routes

  !> @brief Prepara e cria a rota 'ocn2atm_sst' (coluna create 'mascara_mista' de
  !! ROUTES): grava na grade do oceano a máscara de So_omask (ou, sem ela, a
  !! de um limiar de SST) e cria a rota no primeiro passo em que a máscara
  !! tem terra e mar no conjunto dos PETs.
  subroutine set_ocean_mask_for_sst(is, importState, sst_ocn, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: sst_ocn   !< So_t na grade do oceano
    integer, intent(inout) :: rc
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    integer :: lde_s, n_land, ldec_ocn, n_sea
    integer :: n_land_g(1), n_land_s(1), n_sea_g(1), n_sea_s(1)
    type(ESMF_VM) :: vm
    logical :: got_omask, found
    real(ESMF_KIND_R8), pointer :: sst_src(:,:)
    real(ESMF_KIND_R8), parameter :: LAND_FILL_MAX = 270.0_ESMF_KIND_R8

    call ESMF_VMGetCurrent(vm, rc=rc)

    ! Preferencial: máscara real do MOM6 (So_omask, 1=oceano/0=terra; a
    ! mesma convenção do GRIDITEM_MASK aqui: valores em srcMaskValues são
    ! EXCLUÍDOS da fonte do regrid, logo terra=0 é o valor a excluir).
    call set_ocn_grid_mask(is%ocn_grid, importState, n_land, n_sea, found, got_omask)
    if (.not. found) then
      call log_warning(COMP_MED, 'So_omask indisponivel no importState: ' // &
        'mascara pelo limiar de SST (menos confiavel na costa)')
    end if

    ! Sem So_omask (não deveria ocorrer com o campo anunciado e realizado):
    ! máscara pelo limiar de SST, em vez de parar a rodada.
    if (.not. got_omask) then
        n_land = 0; n_sea = 0
        call ESMF_GridGet(is%ocn_grid, localDeCount=ldec_ocn, rc=rc)
        if (rc == ESMF_SUCCESS) then
          do lde_s = 0, ldec_ocn - 1
            call ESMF_FieldGet(sst_ocn, localDe=lde_s, farrayPtr=sst_src, rc=rc)
            if (rc /= ESMF_SUCCESS .or. .not. associated(sst_src)) cycle
            call ESMF_GridGetItem(is%ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
              staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_s, &
              farrayPtr=maskptr, rc=rc)
            if (rc == ESMF_SUCCESS .and. associated(maskptr)) then
              where (sst_src < LAND_FILL_MAX)
                maskptr = 0
              elsewhere
                maskptr = 1
              end where
              n_land = n_land + count(maskptr == 0)
              n_sea  = n_sea  + count(maskptr == 1)
            end if
          end do
        end if
    end if

    n_land_s(1) = n_land; n_sea_s(1) = n_sea
    call ESMF_VMAllReduce(vm, n_land_s, n_land_g, 1, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) n_land_g(1) = n_land
    call ESMF_VMAllReduce(vm, n_sea_s,  n_sea_g,  1, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) n_sea_g(1) = n_sea
    if (n_land_g(1) == 0 .or. n_sea_g(1) == 0) then
      ! Máscara ainda uniforme (bootstrap): So_t usa a rota ocn2atm neste
      ! passo e a rota mascarada é tentada de novo no próximo.
      call log_info(COMP_MED, 'mascara oceanica uniforme, rota ocn2atm_sst adiada')
    else
      ! Conservativo contorna a deformação da costura tripolar; bilinear
      ! mascarado se a grade não tiver cantos; ocn2atm como último recurso.
      call create_route(is%regrid, 'ocn2atm_sst', sst_ocn, is%ocn%sst, rc)
    end if
  end subroutine set_ocean_mask_for_sst

  !> @brief Cria a rota 'ocn2atm_ice' (conservativa, com máscara na origem).
  !!
  !! Antes de criar a rota, copia So_omask (1 = oceano, 0 = terra) para a
  !! máscara de is%ocn_grid (set_ocn_grid_mask), de modo que a rota não
  !! dependa de a SST ter sido interpolada antes. A configuração vem de
  !! ROUTES: 'conserve', que conserva a área e é o adequado para uma fração,
  !! 'bilinear' em seguida e a rota 'ocn2atm' como reserva.
  !!
  !! Com log_level='debug', registra quantos pontos de terra e de oceano
  !! este PET viu na máscara (log_ocean_mask, em med_diag).
  subroutine add_ice_route(is, importState, f_ifrac_src)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    type(ESMF_Field),        intent(inout) :: f_ifrac_src
    integer :: rc_store
    integer :: n_land_ice
    integer :: n_sea_ice
    logical :: found, copied

    call set_ocn_grid_mask(is%ocn_grid, importState, n_land_ice, n_sea_ice, found, copied)
    if (log_debug_enabled()) call log_ocean_mask(found, n_land_ice, n_sea_ice)
    call create_route(is%regrid, 'ocn2atm_ice', f_ifrac_src, is%ice%ifrac, rc_store)
  end subroutine add_ice_route

  !> @brief Fase deliver: exportação dos campos da malha de fluxo e carimbo de
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
  subroutine deliver(is, importState, exportState, clock, stampTime, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Clock), intent(in)    :: clock
    type(ESMF_Time),  intent(inout) :: stampTime
    integer,          intent(inout) :: rc
    type(ESMF_Field) :: field

    call ensure_export_routes(is, importState, exportState)
    call export_to_components(is, importState, exportState, rc)
    call stamp_export_fields(exportState, field, stampTime, rc)

    ! Com use_med_to_mpas (nuopc_mode), o conector MED -> MPAS entrega ao
    ! MONAN-A os campos do exportState com o tempo atual do relógio.
    if (is%use_med_to_mpas) then
      call stamp_state_clock(exportState, clock, is, rc)
      if (rc /= ESMF_SUCCESS) then
        call log_warning(COMP_MED, 'carimbo do relogio no exportState falhou; continuando')
        rc = ESMF_SUCCESS
      end if
    end if
  end subroutine deliver

  !> @brief Fase da física bulk: associa os arrays de med_flux_t aos campos
  !! internos da malha de fluxo (associate_fluxes) e chama calc_bulk_ncar com
  !! eles e com os forçantes atmosféricos reunidos na grade global.
  !!
  !! @param[in]    is             estado interno do mediador
  !! @param[in]    uas..snow_g    forçantes atmosféricos na grade ATM global
  !! @param[in]    i1, i2, j1, j2 limites locais da DE na malha de fluxo
  !! @param[in]    clock          relógio do mediador (hora solar)
  !! @param[out]   rc             código de retorno de calc_bulk_ncar
  subroutine compute_fluxes(is, uas, vas, tas, psl, swdn, lwdn, rain, shum, snow_g, &
                            i1, i2, j1, j2, clock, rc)
    type(MED_InternalState), intent(in)  :: is
    real(ESMF_KIND_R8),      intent(in)  :: uas(:,:), vas(:,:), tas(:,:)
    real(ESMF_KIND_R8),      intent(in)  :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8),      intent(in)  :: rain(:,:), shum(:,:)
    real(ESMF_KIND_R8),      intent(in)  :: snow_g(:,:)
    integer,                 intent(in)  :: i1, i2, j1, j2
    type(ESMF_Clock),        intent(in)  :: clock
    integer,                 intent(out) :: rc
    type(med_flux_t) :: fluxes

    call associate_fluxes(is, fluxes)
    call calc_bulk_ncar(fluxes, uas, vas, tas, psl, swdn, lwdn, rain, shum, snow_g, &
                        i1, i2, j1, j2, clock, rc)
  end subroutine compute_fluxes

  !> @brief Associa cada array de med_flux_t aos valores do campo interno
  !! correspondente, no DE local; um campo que o ESMF não entrega deixa o
  !! array nulo, que a física trata como indisponível.
  !!
  !! @param[in]  is     estado interno do mediador
  !! @param[out] fluxes arrays da física
  subroutine associate_fluxes(is, fluxes)
    type(MED_InternalState), intent(in)  :: is
    type(med_flux_t),        intent(out) :: fluxes

    call point_to(is%ocn%sst,     fluxes%sst)
    call point_to(is%ocn%u,       fluxes%uocn)
    call point_to(is%ocn%v,       fluxes%vocn)
    call point_to(is%ocn%omask,   fluxes%omask)
    call point_to(is%ice%ifrac,   fluxes%ifrac)
    call point_to(is%ice%tice,    fluxes%tice)
    call point_to(is%ice%alb_vdr, fluxes%alb_vdr)
    call point_to(is%ice%alb_vdf, fluxes%alb_vdf)
    call point_to(is%ice%alb_idr, fluxes%alb_idr)
    call point_to(is%ice%alb_idf, fluxes%alb_idf)
    call point_to(is%ocn_flx%taux, fluxes%taux)
    call point_to(is%ocn_flx%tauy, fluxes%tauy)
    call point_to(is%ocn_flx%sen, fluxes%sen)
    call point_to(is%ocn_flx%evap, fluxes%evap)
    call point_to(is%ocn_flx%lwnet, fluxes%lwnet)
    call point_to(is%ocn_flx%swvdr, fluxes%swvdr)
    call point_to(is%ocn_flx%swvdf, fluxes%swvdf)
    call point_to(is%ocn_flx%swidr, fluxes%swidr)
    call point_to(is%ocn_flx%swidf, fluxes%swidf)
    call point_to(is%ocn_flx%rain, fluxes%rain)
    call point_to(is%ocn_flx%snow, fluxes%snow)
    call point_to(is%ocn_flx%pslv, fluxes%pslv)
    call point_to(is%ocn_flx%duu10n, fluxes%duu10n)
    call point_to(is%ice%taux,    fluxes%taux_ice)
    call point_to(is%ice%tauy,    fluxes%tauy_ice)
    call point_to(is%ice%sen,     fluxes%sen_ice)
    call point_to(is%ice%evap,    fluxes%evap_ice)
    call point_to(is%ice%lwnet,   fluxes%lwnet_ice)
    call point_to(is%ice%swvdr,   fluxes%swvdr_ice)
    call point_to(is%ice%swvdf,   fluxes%swvdf_ice)
    call point_to(is%ice%swidr,   fluxes%swidr_ice)
    call point_to(is%ice%swidf,   fluxes%swidf_ice)
    call point_to(is%sfc%zorl,    fluxes%zorl)
    call point_to(is%sfc%coszen,  fluxes%coszen)
    call point_to(is%sfc%albedo,  fluxes%albedo)

  contains

    !> Aponta p para os dados do campo; p fica nulo se o campo não tem dados locais.
    subroutine point_to(field, p)
      type(ESMF_Field),            intent(in)  :: field
      real(ESMF_KIND_R8), pointer, intent(out) :: p(:,:)
      integer :: rc_p
      nullify(p)
      call ESMF_FieldGet(field, farrayPtr=p, rc=rc_p)
      if (rc_p /= ESMF_SUCCESS) nullify(p)
    end subroutine point_to

  end subroutine associate_fluxes

  !> @brief Fase logo depois da física, sem o SIS2 dinâmico: recalcula a fração de
  !! gelo na malha de fluxo (legacy_ice_fraction, em med_ocean). A física
  !! deste passo já usou a fração que estava em is%ice%ifrac; a nova vai
  !! para a exportação (Si_ifrac) e para o passo seguinte.
  !!
  !! @param[inout] is           estado interno do mediador
  !! @param[inout] importState  estado de importação do mediador
  !! @param[in]    i1, i2, j1, j2  limites locais da DE na malha de fluxo
  subroutine ice_fraction_without_sis2(is, importState, i1, i2, j1, j2)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    integer,                 intent(in)    :: i1, i2, j1, j2
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    integer :: rc

    if (cfg_use_sis2_dynamic) return
    nullify(fptr, sst)
    call ESMF_FieldGet(is%ocn%sst, farrayPtr=sst, rc=rc)
    if (rc /= ESMF_SUCCESS) nullify(sst)
    call legacy_ice_fraction(is, importState, fptr, sst, j1, j2, i1, i2)
  end subroutine ice_fraction_without_sis2

  !> @brief Rotas da exportação criadas durante o passo, conforme a coluna create
  !! de ROUTES ('primeiro_uso'), nesta ordem (a ordem das linhas "rota" no
  !! relatório de acoplamento):
  !!   ocn2atm_landmask  na primeira exportação (is%ocn%omask_done ainda
  !!                     falso), se So_omask está no importState;
  !!                     regrid_land_mask (med_export) a aplica uma vez;
  !!   atm2ocn_ice       se Si_ifrac está no exportState e a rota de reserva
  !!                     atm2ocn já existe; export_ice_fraction a aplica.
  !!
  !! @param[in]    is           estado interno do mediador
  !! @param[inout] importState  estado de importação do mediador
  !! @param[inout] exportState  estado de exportação do mediador
  subroutine ensure_export_routes(is, importState, exportState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field) :: omask_src_field, f_ifrac_exp
    integer :: rc_route

    if (.not. is%ocn%omask_done) then
      call ESMF_StateGet(importState, itemName="So_omask", &
        field=omask_src_field, rc=rc_route)
      if (rc_route == ESMF_SUCCESS) &
        call create_route(is%regrid, 'ocn2atm_landmask', omask_src_field, is%ocn%omask, rc_route)
    end if

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_ifrac_exp, rc=rc_route)
    if (rc_route == ESMF_SUCCESS) then
      if (.not. is%regrid%has('atm2ocn_ice') .and. is%regrid%has('atm2ocn')) &
        call create_route(is%regrid, 'atm2ocn_ice', is%ice%ifrac, f_ifrac_exp, rc_route)
    end if
  end subroutine ensure_export_routes

  !> @brief Carimba stampTime em cada campo do exportState. field é só a variável
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

  !> @brief Carimba o exportState inteiro com o tempo atual do relógio. Só depois que a rota
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
      call log_warning(COMP_MED, 'carimbo do relogio: rota ocn2atm ainda nao criada; pulando')
      rc = ESMF_SUCCESS
      return
    end if

    ! Estampilar timestamp no exportState (MPAS usa para validação)
    call NUOPC_SetTimestamp(exportState, clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg='MED RouteOcnToAtm: falha NUOPC_SetTimestamp', &
      line=__LINE__, file=__FILE__)) return

    call log_debug(COMP_MED, 'exportState carimbado com o tempo do relogio')

  end subroutine stamp_state_clock

end module med_exchange_mod
