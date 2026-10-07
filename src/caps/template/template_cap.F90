!> @file template_cap.F90
!! @brief Cap modelo: o ponto de partida para o cap NUOPC de um componente novo.
!!
!! Este cap não faz parte do executável (o Makefile não compila
!! src/caps/template/); ele é compilado pelas conferências locais
!! (compila-local.bash, conferência compilacao), para não envelhecer sem
!! que se perceba. Ele é um componente de dados mínimo: anuncia o que o mapa
!! de acoplamento manda, realiza os campos numa grade regular, exporta
!! valores constantes e só avança o carimbo de tempo a cada passo.
!!
!! Para escrever o cap de um componente novo:
!!   1. copie este arquivo para src/caps/<diretório>/<nome>_cap.F90 e troque
!!      template pelo nome do componente no módulo e no texto;
!!   2. no mapa (src/coupling/cpl_map.F90), acrescente a malha em GRIDS, as
!!      passagens que chegam e saem do componente em EXCHANGES e os campos
!!      que ele exporta em EXPORTS; troque POINT pelo ponto do componente
!!      ('COMPONENTE@malha');
!!   3. escolha as políticas de anúncio (passo 2, abaixo) pelo significado,
!!      não copiando outro cap: as três estão explicadas em cap_common;
!!   4. troque a grade do passo 3 pela do modelo (as funções de
!!      src/coupling/cpl_grids.F90 criam as grades usadas hoje);
!!   5. troque os valores iniciais do passo 4 e, no passo 5, chame o modelo
!!      e copie os campos dele para o exportState (cap_put_field);
!!   6. registre o modelo no driver (register_model, em esm.F90), com a
!!      posição, o rótulo e esta SetServices, e acrescente a posição à
!!      tabela POSITIONS (driver_layout.F90), se for nova;
!!   7. acrescente o diretório ao Makefile (SRC_SUBDIRS) e à tabela CAMADAS
!!      de tools/dev/confere-camadas.py, e gere as dependências
!!      (tools/dev/dependencias.py gera).
!! As fases seguem o protocolo IPDv03 do NUOPC, como os caps do acoplador.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module template_cap_mod

  use ESMF,  only : ESMF_GridComp, ESMF_GridCompGet, ESMF_GridCompSetEntryPoint, &
                    ESMF_State, ESMF_Grid, ESMF_Clock, ESMF_ClockGet,            &
                    ESMF_Time, ESMF_TimeInterval, ESMF_VM, ESMF_VMGet,           &
                    ESMF_METHOD_INITIALIZE, ESMF_KIND_R8, ESMF_SUCCESS,          &
                    operator(+)
  use NUOPC, only : NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC_Model, only : model_routine_SS           => SetServices,          &
                          model_label_DataInitialize => label_DataInitialize, &
                          model_label_Advance        => label_Advance
  use coupler_utils_mod,  only : ChkErr, int_to_str
  use coupler_log_mod,    only : log_info
  use coupler_config_mod, only : cpl_current_config
  use cap_common_mod,     only : cap_initialize_p0, cap_advertise, cap_realize_fields, &
                                 cap_fill_export_initial, cap_stamp_export,         &
                                 cap_set_data_complete,                             &
                                 ADVERTISE_DEFAULT
  use cpl_fields_mod,     only : CPL_NAME_LEN
  use cpl_map_mod,        only : cpl_arrivals, cpl_exports
  use cpl_grids_mod,      only : cpl_latlon_grid, ORIGIN_EAST0

  implicit none
  private

  public :: SetServices

  !> Ponto do componente no mapa de acoplamento ('COMPONENTE@malha'). Este
  !! ponto não está no mapa: as listas de campos vêm vazias até que as
  !! passagens do componente novo sejam acrescentadas (passo 2 acima).
  character(len=*), parameter :: POINT = 'TPL@template'

  !> Marca do componente nas mensagens do registro (coupler_log_mod).
  character(len=*), parameter :: COMP_TEMPLATE = 'TPL'

  !> Tamanho da grade regular do exemplo (1 grau).
  integer, parameter :: NX = 360, NY = 180

contains

  !> @brief Passo 1: registra as fases do componente no NUOPC.
  !!
  !! NUOPC_CompDerive herda o comportamento padrão de um modelo NUOPC; as
  !! demais chamadas ligam as rotinas deste cap às fases: a fase 0 aceita só
  !! o protocolo IPDv03 (cap_initialize_p0), IPDv03p1 anuncia os campos,
  !! IPDv03p3 os realiza, DataInitialize preenche os valores iniciais e
  !! Advance avança um passo de acoplamento.
  !!
  !! @param[inout] gcomp  componente
  !! @param[out]   rc     ESMF_SUCCESS ou o código do erro
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS
    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=cap_initialize_p0, phase=0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_DataInitialize, &
      specRoutine=InitializeData, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Advance, &
      specRoutine=ModelAdvance, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine SetServices

  !> @brief Passo 2 (IPDv03p1): anuncia os campos que o componente importa e exporta.
  !!
  !! As listas vêm do mapa: cpl_arrivals dá o que chega ao ponto por
  !! conector, cpl_exports o que o componente exporta. A política de anúncio
  !! (cap_common) é escolhida pelo significado: ADVERTISE_DEFAULT quando o
  !! componente realiza os campos na própria grade nas duas direções;
  !! ADVERTISE_SHARED e ADVERTISE_PROVIDES_GRID quando importa dividindo o
  !! campo com o conector e oferece a grade na exportação.
  !!
  !! @param[inout] gcomp        componente
  !! @param[inout] importState  State de importação
  !! @param[inout] exportState  State de exportação
  !! @param[in]    clock        relógio do componente
  !! @param[out]   rc           ESMF_SUCCESS ou o código do erro
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS
    call cpl_arrivals(POINT, .true., cpl_current_config(), '', names)
    call cap_advertise(importState, names, ADVERTISE_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call cpl_exports(POINT, cpl_current_config(), '', names)
    call cap_advertise(exportState, names, ADVERTISE_DEFAULT, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call log_info(COMP_TEMPLATE, 'InitializeAdvertise concluido ('// &
      int_to_str(size(names))//' exp)')
  end subroutine InitializeAdvertise

  !> @brief Passo 3 (IPDv03p3): cria a grade e realiza os campos anunciados.
  !!
  !! A grade do exemplo é regular, de 1 grau, decomposta entre os PETs do
  !! componente (cpl_latlon_grid). Os campos são criados no centro das
  !! células e realizados no State (cap_realize_fields), com os mesmos nomes
  !! e na mesma ordem do anúncio.
  !!
  !! @param[inout] gcomp        componente
  !! @param[inout] importState  State de importação
  !! @param[inout] exportState  State de exportação
  !! @param[in]    clock        relógio do componente
  !! @param[out]   rc           ESMF_SUCCESS ou o código do erro
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc
    type(ESMF_VM)   :: vm
    type(ESMF_Grid) :: grid
    integer         :: petCount
    character(len=CPL_NAME_LEN), allocatable :: names(:)

    rc = ESMF_SUCCESS
    call ESMF_GridCompGet(gcomp, vm=vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call cpl_latlon_grid('template', NX, NY, ORIGIN_EAST0, .false., petCount, grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cpl_arrivals(POINT, .true., cpl_current_config(), '', names)
    call cap_realize_fields(importState, grid, names, size(names), rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call cpl_exports(POINT, cpl_current_config(), '', names)
    call cap_realize_fields(exportState, grid, names, size(names), rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine InitializeRealize

  !> @brief Passo 4 (DataInitialize): valores iniciais dos campos exportados.
  !!
  !! Preenche os campos exportados (aqui, com zero), carimba-os com o
  !! instante inicial, que o NUOPC confere nos componentes que os importam,
  !! e avisa que a inicialização de dados está completa.
  !!
  !! @param[inout] gcomp  componente
  !! @param[out]   rc     ESMF_SUCCESS ou o código do erro
  subroutine InitializeData(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc
    type(ESMF_State) :: exportState
    type(ESMF_Clock) :: clock
    type(ESMF_Time)  :: startTime
    character(len=CPL_NAME_LEN), allocatable :: names(:)
    real(ESMF_KIND_R8), allocatable :: values(:)

    rc = ESMF_SUCCESS
    call ESMF_GridCompGet(gcomp, exportState=exportState, clock=clock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call cpl_exports(POINT, cpl_current_config(), '', names)
    allocate(values(size(names)))
    values = 0.0_ESMF_KIND_R8
    call cap_fill_export_initial(exportState, names, values, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_ClockGet(clock, startTime=startTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call cap_stamp_export(exportState, startTime, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call cap_set_data_complete(gcomp, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine InitializeData

  !> @brief Passo 5 (Advance): avança um passo de acoplamento.
  !!
  !! Num componente de verdade, aqui o cap lê os campos importados, chama o
  !! modelo até o fim do passo e copia os resultados para os campos
  !! exportados (cap_put_field). O exemplo mantém os valores e só carimba os
  !! campos exportados com o instante do fim do passo, como os caps de dados.
  !!
  !! @param[inout] gcomp  componente
  !! @param[out]   rc     ESMF_SUCCESS ou o código do erro
  subroutine ModelAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc
    type(ESMF_State)        :: exportState
    type(ESMF_Clock)        :: clock
    type(ESMF_Time)         :: currTime
    type(ESMF_TimeInterval) :: timeStep

    rc = ESMF_SUCCESS
    call ESMF_GridCompGet(gcomp, exportState=exportState, clock=clock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_ClockGet(clock, currTime=currTime, timeStep=timeStep, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call cap_stamp_export(exportState, currTime + timeStep, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine ModelAdvance

end module template_cap_mod
