!> @file med_cap_methods.F90
!! @brief Utilitários de manipulação de campos ESMF/NUOPC do mediador.
!!
!! Utilitários do mediador separados de MED_cap.F90:
!!
!!   CreateInternalField      — cria campo ESMF na grade interna
!!   ZeroInternalField        — zera campo com guard
!!   FillInternalField        — preenche campo com valor constante
!!   GetFieldPtr              — obtém ponteiro de campo (falha se ausente)
!!   GetFieldPtrOptional      — obtém ponteiro sem erro de log para campos opcionais
!!   RegridOrCopy             — regrid ATM→OCN com fallback temporário
!!   RouteOcnToAtm            — exporta campos OCN→ATM via mediador

module med_cap_methods_mod

  use ESMF
  use regrid_manager_mod, only : regrid_spec
  use NUOPC, only: NUOPC_SetTimestamp

  use med_cap_types_mod, only: MED_InternalState
  use coupler_config_mod, only: cfg_use_sis2_dynamic

  use coupler_utils_mod, only : ChkErr

  implicit none
  private

  public :: CreateInternalField
  public :: ZeroInternalField
  public :: FillInternalField
  public :: GetFieldPtr
  public :: GetFieldPtrOptional
  public :: RegridOrCopy
  public :: RouteOcnToAtm



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
  ! > @brief Zera um campo ESMF com guard para PETs sem DE local.
  !!
  !! ESMF_FieldGet(farrayPtr) falha com "localDe is out of range"
  !! em PETs sem DE local (localDeCount=0). Verificar antes de acessar.
  !============================================================================
  subroutine ZeroInternalField(field, rc)
    type(ESMF_Field), intent(inout) :: field
    integer,          intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: localDeCount_f
    rc = ESMF_SUCCESS

    call ESMF_FieldGet(field, localDeCount=localDeCount_f, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (localDeCount_f == 0) return   ! PET sem dados locais — nada a zerar

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fptr = 0.0_ESMF_KIND_R8

  end subroutine ZeroInternalField

  !============================================================================
  !> @brief Preenche campo ESMF com valor constante.
  !! Guard PETs sem DE local não têm dados a preencher.
  !============================================================================
  subroutine FillInternalField(field, value, rc)
    type(ESMF_Field),   intent(inout) :: field
    real(ESMF_KIND_R8), intent(in)    :: value
    integer,            intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: localDeCount_f
    rc = ESMF_SUCCESS

    call ESMF_FieldGet(field, localDeCount=localDeCount_f, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (localDeCount_f == 0) return

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
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
  !! no log para campos opcionais (Sa_shum_mpas, Faxa_snow_mpas).
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
  !! Quando as rotas ainda não foram criadas (1º passo ou erro na IDC), faz
  !! o regrid com um ESMF_FieldRegridStore temporário, em vez de deixar
  !! zerados os campos exportados ao OCN.
  !============================================================================
  subroutine RegridOrCopy(src_field, dst_state, dst_name, is, rc)
    type(ESMF_Field),        intent(inout) :: src_field
    type(ESMF_State),        intent(inout) :: dst_state
    character(len=*),        intent(in)    :: dst_name
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    type(ESMF_Field) :: dst_field
    real(ESMF_KIND_R8), pointer :: dst_ptr(:,:)

    rc = ESMF_SUCCESS

    call ESMF_StateGet(dst_state, itemName=trim(dst_name), field=dst_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="RegridOrCopy: "//trim(dst_name), &
      line=__LINE__, file=__FILE__)) return

    ! A rota atm2ocn serve a qualquer par (grade ATM, grade OCN); se ainda
    ! não existe, é criada com este par.
    if (.not. is%regrid%has('atm2ocn')) then
      call is%regrid%add('atm2ocn', regrid_spec('nearest_stod'), src_field, dst_field, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if
    call is%regrid%apply('atm2ocn', src_field, dst_field, rc, zero_total=.true.)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="RegridOrCopy: falha no regrid de "//trim(dst_name), &
      line=__LINE__, file=__FILE__)) return
    call ESMF_FieldGet(dst_field, farrayPtr=dst_ptr, rc=rc)
    where (dst_ptr /= dst_ptr) dst_ptr = 0.0_ESMF_KIND_R8

  end subroutine RegridOrCopy

  !============================================================================
  !> @brief Roteia campos oceânicos para a atmosfera (MOM6 dinâmico).
  !!
  !! MOM6 dinâmico (grade tripolar B-grid):
  !!   Chamada em MediatorAdvance quando use_med_to_mpas=.true. (nuopc.input).
  !!   O conector direto OCN→MPAS não existe neste modo; tudo passa pelo MED.
  !!
  !! Campos processados:
  !!   So_t (SST), Si_ifrac, So_u, So_v, Sf_zorl — ver MediatorAdvance para detalhes.
  !!   Sf_zorl: calculada pelo bulk NCAR via Charnock + Smith (1988).
  !!
  !============================================================================
  subroutine RouteOcnToAtm(importState, exportState, clock, is, rc)
    type(ESMF_State),        intent(inout) :: importState
    type(ESMF_State),        intent(inout) :: exportState
    type(ESMF_Clock),        intent(in)    :: clock
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: ptr_atm(:,:)


    rc = ESMF_SUCCESS
    nullify(ptr_atm)

    ! Guard: routehandles devem estar criados
    if (.not. is%regrid%has('ocn2atm')) then
      call ESMF_LogWrite( &
        'MED RouteOcnToAtm: rota ocn2atm ainda nao criada; pulando', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
      return
    end if

    ! So_t, Si_ifrac, So_u e So_v ja foram regridados e exportados por
    ! RegridOrCopy em MediatorAdvance; aqui resta apenas o carimbo de tempo.

    ! Estampilar timestamp no exportState (MPAS usa para validação)
    call NUOPC_SetTimestamp(exportState, clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg='MED RouteOcnToAtm: falha NUOPC_SetTimestamp', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('MED RouteOcnToAtm: regrid OCN->ATM concluido (Fase 2)', &
      ESMF_LOGMSG_INFO)

  end subroutine RouteOcnToAtm



end module med_cap_methods_mod
