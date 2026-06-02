!> @file med_cap_methods.F90
!! @brief Utilitários de manipulação de campos ESMF/NUOPC do mediador.
!!
!! Versão 1.0 (Mai/2026) — GT Acoplamento de Modelos / INPE/CGCT/DIMNT
!!
!! Contém as sub-rotinas de utilidade extraídas de MED_cap.F90
!! como parte da reorganização de responsabilidades (Passo 3):
!!
!!   CreateInternalField      — cria campo ESMF na grade interna
!!   ZeroInternalField        — zera campo com guard B-45
!!   FillInternalField        — preenche campo com valor constante
!!   GetFieldPtr              — obtém ponteiro de campo (falha se ausente)
!!   GetFieldPtrOptional      — obtém ponteiro sem erro de log para campos opcionais
!!   RegridOrCopy             — regrid ATM→OCN com fallback temporário
!!   RouteOcnToAtm            — exporta campos OCN→ATM via mediador (Fase 2)
!!   RegridOptionalCurrent    — regrid silencioso de correntes opcionais

module med_cap_methods_mod

  use ESMF
  use NUOPC, only: NUOPC_SetTimestamp

  use med_cap_types_mod, only: MED_InternalState

  implicit none
  private

  public :: CreateInternalField
  public :: ZeroInternalField
  public :: FillInternalField
  public :: GetFieldPtr
  public :: GetFieldPtrOptional
  public :: RegridOrCopy
  public :: RouteOcnToAtm
  public :: RegridOptionalCurrent

contains

  !============================================================================
  !> @brief Cria um campo ESMF na grade interna do mediador.
  !! @param[out] field  Campo a criar
  !! @param[in]  grid   Grade ESMF de destino
  !! @param[in]  name   Nome do campo
  !! @param[out] rc     Código de retorno ESMF
  !============================================================================
  subroutine CreateInternalField(field, grid, name, rc)
    type(ESMF_Field), intent(out) :: field
    type(ESMF_Grid),  intent(in)  :: grid
    character(len=*), intent(in)  :: name
    integer,          intent(out) :: rc

    field = ESMF_FieldCreate(grid=grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(name), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="MED CreateInternalField: "//trim(name), &
      line=__LINE__, file=__FILE__)) return
  end subroutine CreateInternalField

  !============================================================================
  !> @brief Zera um campo ESMF com guard B-45 para PETs sem DE local.
  !!
  !! B-45: ESMF_FieldGet(farrayPtr) falha com "localDe is out of range"
  !! em PETs sem DE local (localDeCount=0). Verificar antes de acessar.
  !============================================================================
  subroutine ZeroInternalField(field, rc)
    type(ESMF_Field), intent(inout) :: field
    integer,          intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: localDeCount_f
    rc = ESMF_SUCCESS

    call ESMF_FieldGet(field, localDeCount=localDeCount_f, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    if (localDeCount_f == 0) return   ! PET sem dados locais — nada a zerar

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    fptr = 0.0_ESMF_KIND_R8

  end subroutine ZeroInternalField

  !============================================================================
  !> @brief Preenche campo ESMF com valor constante.
  !! Guard B-45: PETs sem DE local não têm dados a preencher.
  !============================================================================
  subroutine FillInternalField(field, value, rc)
    type(ESMF_Field),   intent(inout) :: field
    real(ESMF_KIND_R8), intent(in)    :: value
    integer,            intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: localDeCount_f
    rc = ESMF_SUCCESS

    call ESMF_FieldGet(field, localDeCount=localDeCount_f, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    if (localDeCount_f == 0) return

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    fptr = value

  end subroutine FillInternalField

  !============================================================================
  !> @brief Obtém ponteiro para campo (falha se o campo não existir no State).
  !============================================================================
  subroutine GetFieldPtr(state, name, ptr, rc)
    type(ESMF_State),            intent(in)    :: state
    character(len=*),            intent(in)    :: name
    real(ESMF_KIND_R8), pointer, intent(inout) :: ptr(:,:)
    integer,                     intent(out)   :: rc

    type(ESMF_Field) :: field
    integer :: localrc

    rc = ESMF_SUCCESS
    nullify(ptr)

    call ESMF_StateGet(state, trim(name), field, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    call ESMF_FieldGet(field, farrayPtr=ptr, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

  end subroutine GetFieldPtr

  !============================================================================
  !> @brief Obtém ponteiro para campo sem gerar log de erro quando ausente.
  !!
  !! Enumera os itens do State e verifica existência do nome ANTES de chamar
  !! ESMF_StateGet pelo nome. Impede mensagens "no ESMF_Field found named: X"
  !! no log para campos opcionais Fase 2 (Sa_shum_mpas, Faxa_snow_mpas).
  !============================================================================
  subroutine GetFieldPtrOptional(state, name, ptr, rc)
    type(ESMF_State),            intent(in)    :: state
    character(len=*),            intent(in)    :: name
    real(ESMF_KIND_R8), pointer, intent(inout) :: ptr(:,:)
    integer,                     intent(out)   :: rc

    type(ESMF_Field)               :: field
    integer                        :: itemCount, i, localrc
    character(len=64), allocatable :: itemNames(:)
    logical                        :: found

    rc = ESMF_SUCCESS
    nullify(ptr)

    call ESMF_StateGet(state, itemCount=itemCount, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    if (itemCount == 0) then
      rc = ESMF_FAILURE; return
    end if

    allocate(itemNames(itemCount))
    call ESMF_StateGet(state, itemNameList=itemNames, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      deallocate(itemNames); rc = ESMF_FAILURE; return
    end if

    found = .false.
    do i = 1, itemCount
      if (trim(itemNames(i)) == trim(name)) then
        found = .true.; exit
      end if
    end do
    deallocate(itemNames)

    if (.not. found) then
      rc = ESMF_FAILURE; return
    end if

    call ESMF_StateGet(state, trim(name), field, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    call ESMF_FieldGet(field, farrayPtr=ptr, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    rc = ESMF_SUCCESS

  end subroutine GetFieldPtrOptional

  !============================================================================
  !> @brief Regrid ATM→OCN com fallback quando routehandle ainda não foi criado.
  !!
  !! Correção 3: ramo else adicionado para rh_created = .false.
  !! Sem o else, campos exportados ao OCN ficavam zerados silenciosamente
  !! quando routehandles não estavam criados (1º passo ou erro na IDC).
  !! Com o else, faz regrid on-the-fly via ESMF_FieldRegridStore temporário.
  !============================================================================
  subroutine RegridOrCopy(src_field, dst_state, dst_name, is, rc)
    type(ESMF_Field),        intent(inout) :: src_field
    type(ESMF_State),        intent(inout) :: dst_state
    character(len=*),        intent(in)    :: dst_name
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    type(ESMF_Field) :: dst_field
    type(ESMF_RouteHandle) :: rh_tmp
    real(ESMF_KIND_R8), pointer :: dst_ptr(:,:)

    rc = ESMF_SUCCESS

    call ESMF_StateGet(dst_state, itemName=trim(dst_name), field=dst_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="RegridOrCopy: "//trim(dst_name), &
      line=__LINE__, file=__FILE__)) return

    if (is%rh_created) then
      call ESMF_FieldRegrid(src_field, dst_field, is%rh_atm2ocn, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="RegridOrCopy: falha no regrid de "//trim(dst_name), &
        line=__LINE__, file=__FILE__)) return
      ! Sanitizar NaNs
      call ESMF_FieldGet(dst_field, farrayPtr=dst_ptr, rc=rc)
      where (dst_ptr /= dst_ptr) dst_ptr = 0.0_ESMF_KIND_R8
    else
      ! Routehandle ainda não disponível: regrid temporário nearest-stod
      call ESMF_FieldRegridStore( &
        srcField       = src_field,    &
        dstField       = dst_field,    &
        routehandle    = rh_tmp,       &
        regridmethod   = ESMF_REGRIDMETHOD_NEAREST_STOD, &
        unmappedaction = ESMF_UNMAPPEDACTION_IGNORE, &
        rc             = rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="RegridOrCopy fallback: falha store "//trim(dst_name), &
        line=__LINE__, file=__FILE__)) return
      call ESMF_FieldRegrid(src_field, dst_field, rh_tmp, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="RegridOrCopy fallback: falha regrid "//trim(dst_name), &
        line=__LINE__, file=__FILE__)) return
      call ESMF_RouteHandleDestroy(rh_tmp, nogarbage=.true., rc=rc)
      call ESMF_FieldGet(dst_field, farrayPtr=dst_ptr, rc=rc)
      where (dst_ptr /= dst_ptr) dst_ptr = 0.0_ESMF_KIND_R8
    end if

  end subroutine RegridOrCopy

  !============================================================================
  !> @brief Roteia campos oceânicos para a atmosfera (Fase 2 — MOM6 dinâmico).
  !!
  !! Fase 2 (MOM6 dinâmico — grade tripolar B-grid):
  !!   Chamada em MediatorAdvance quando use_med_to_mpas=.true. (nuopc.input).
  !!   O conector direto OCN→MPAS não existe neste modo; tudo passa pelo MED.
  !!
  !! Campos processados:
  !!   So_t (SST), Si_ifrac, So_u, So_v, Sf_zorl — ver MediatorAdvance para detalhes.
  !!   Sf_zorl: calculada pelo bulk NCAR via Charnock + Smith (1988).
  !!
  !! Sprint B (Mai/2026): So_u/So_v agora anunciados no exportState do MED.
  !!   Preenchimento via RegridOrCopy(is%f_uocn_atm/f_vocn_atm → So_u/So_v).
  !!   RegridOptionalCurrent desativado para So_u/So_v (Sprint B os anuncia).
  !============================================================================
  subroutine RouteOcnToAtm(importState, exportState, clock, is, rc)
    type(ESMF_State),        intent(inout) :: importState
    type(ESMF_State),        intent(inout) :: exportState
    type(ESMF_Clock),        intent(in)    :: clock
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    type(ESMF_Field) :: field_ocn, field_atm
    real(ESMF_KIND_R8), pointer :: ptr_atm(:,:)
    type(ESMF_StateItem_Flag)   :: itemType

    real(ESMF_KIND_R8), parameter :: SST_FILL_LAND = 271.35_ESMF_KIND_R8  ! [K]
    integer :: i, j

    rc = ESMF_SUCCESS
    nullify(ptr_atm)

    ! Guard: routehandles devem estar criados para Fase 2
    if (.not. is%rh_created) then
      call ESMF_LogWrite( &
        'MED RouteOcnToAtm: rh_ocn2atm nao criado — pulando Fase 2', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
      return
    end if

    ! So_t: tratado por RegridOrCopy no MediatorAdvance — sem ação adicional aqui.

    ! Si_ifrac: regrid OCN→ATM e exportação feitos no Sprint A.5.2
    !           dentro de MediatorAdvance — sem ação adicional aqui.

    ! So_u/So_v: Sprint B — preenchimento via RegridOrCopy no MediatorAdvance.
    !   RegridOptionalCurrent desativado para evitar conflito de grade
    !   (exportState.So_u/v vive na grade OCN após Sprint B).

    ! Estampilar timestamp no exportState (MPAS usa para validação)
    call NUOPC_SetTimestamp(exportState, clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg='MED RouteOcnToAtm: falha NUOPC_SetTimestamp', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('MED RouteOcnToAtm: regrid OCN->ATM concluido (Fase 2)', &
      ESMF_LOGMSG_INFO)

  end subroutine RouteOcnToAtm

  !============================================================================
  !> @brief Realiza regrid OCN→ATM silencioso para um campo opcional.
  !!
  !! Verifica existência do campo nos dois States via ESMF_StateGet(itemSearch=...)
  !! antes de obter os Fields, evitando mensagens de erro para campos opcionais.
  !!
  !! Desativado no Sprint B para So_u/So_v (que agora são anunciados).
  !============================================================================
  subroutine RegridOptionalCurrent(importState, exportState, fieldName, rh)
    type(ESMF_State),       intent(inout) :: importState
    type(ESMF_State),       intent(inout) :: exportState
    character(len=*),       intent(in)    :: fieldName
    type(ESMF_RouteHandle), intent(inout) :: rh

    integer          :: rc_loc
    integer          :: n_imp, n_exp
    type(ESMF_Field) :: f_ocn, f_atm

    rc_loc = ESMF_SUCCESS

    call ESMF_StateGet(importState, itemSearch=trim(fieldName), &
      itemCount=n_imp, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS .or. n_imp <= 0) return

    call ESMF_StateGet(exportState, itemSearch=trim(fieldName), &
      itemCount=n_exp, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS .or. n_exp <= 0) return

    call ESMF_StateGet(importState, trim(fieldName), f_ocn, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS) return

    call ESMF_StateGet(exportState, trim(fieldName), f_atm, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS) return

    call ESMF_FieldRegrid(f_ocn, f_atm, rh, &
      zeroregion=ESMF_REGION_TOTAL, rc=rc_loc)

    if (rc_loc == ESMF_SUCCESS) then
      call ESMF_LogWrite( &
        'MED RouteOcnToAtm: regrid OCN->ATM aplicado em ' // trim(fieldName), &
        ESMF_LOGMSG_INFO)
    end if

  end subroutine RegridOptionalCurrent

end module med_cap_methods_mod
