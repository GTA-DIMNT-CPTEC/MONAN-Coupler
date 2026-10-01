!> @file med_exchange.F90
!! @brief Trocas do mediador, por fase.
!!
!! O mediador troca campos com os componentes em fases fixas a cada passo
!! (ver docs/arquitetura-acoplamento.md, seção 3.7). Este módulo reúne as
!! fases à medida que saem do MediatorAdvance:
!!
!!   ir_para_malha_de_fluxo
!!              antes da física: leva os campos do oceano e do gelo da
!!              grade do oceano para a malha de fluxo (R-FASE11-16)
!!   entregar   no fim do passo, depois da física: leva os campos da malha
!!              de fluxo para o exportState (export_to_components, em
!!              med_export) e carimba o tempo dos campos exportados
!!              (R-FASE11-15)
!!
!! O carimbo de tempo dos campos que o mediador entrega fica só aqui: cada
!! campo do exportState recebe stampTime (ver med_stamp_time, em MED_cap)
!! e, com use_med_to_mpas, o exportState inteiro recebe depois o tempo atual
!! do relógio, que prevalece. A ordem das duas marcações é a de antes da
!! R-FASE11-15, quando a segunda ficava em RouteOcnToAtm (med_cap_methods);
!! as mensagens do log continuam com esse nome, que as ferramentas de
!! pós-processamento procuram (tools/postproc/postproc_monan2_import.py).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_exchange_mod
  use ESMF
  use NUOPC,             only: NUOPC_SetTimestamp
  use med_cap_types_mod, only: MED_InternalState
  use med_export_mod,    only: export_to_components
  use med_ocean_mod,     only: update_ocean_fields_on_atm_grid, &
                               update_ice_fraction_from_docn

  implicit none
  private

  public :: ir_para_malha_de_fluxo
  public :: entregar
  public :: stamp_export_fields

contains

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
