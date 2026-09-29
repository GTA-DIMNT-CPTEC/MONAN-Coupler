!> @file cap_common.F90
!! @brief Procedimentos comuns aos caps NUOPC do acoplador.
!!
!! Reúne o que os caps repetiam, cada um com a sua cópia:
!!
!!  - cap_initialize_p0: fase 0 da inicialização, que restringe as fases do
!!    componente ao protocolo IPDv03. O mediador e os caps do MOM6, do SIS2,
!!    do DATM e do DOCN a registram diretamente; o cap do MONAN-A a chama e
!!    acrescenta o registro da data inicial no log.
!!  - cap_realize_fields: cria, no centro das células de uma ESMF_Grid, um
!!    campo real(8) para cada nome da lista e o realiza no State.
!!  - cap_put_field: copia um arranjo 2D local para um campo do State.
!!
!! A obtenção do estado interno continua em cada cap: o tipo do invólucro é
!! próprio de cada componente, e ESMF_GridCompGetInternalState exige o tipo
!! concreto.
!!
!! Reunido dos caps sem mudar instruções (R-FASE9-01).

module cap_common_mod

  use ESMF, only: ESMF_GridComp, ESMF_State, ESMF_Clock, ESMF_Grid, &
                  ESMF_Field, ESMF_FieldCreate, ESMF_FieldGet,      &
                  ESMF_StateGet, ESMF_LogFoundError,                &
                  ESMF_METHOD_INITIALIZE, ESMF_STAGGERLOC_CENTER,   &
                  ESMF_TYPEKIND_R8, ESMF_KIND_R8, ESMF_SUCCESS
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Realize
  use coupler_utils_mod, only: ChkErr
  implicit none
  private

  public :: cap_initialize_p0
  public :: cap_realize_fields
  public :: cap_put_field

contains

  !> @brief Fase 0 da inicialização: aceita só as fases do protocolo IPDv03.
  !!
  !! Registrada como ponto de entrada (phase=0) de cada componente. Os
  !! argumentos seguem a interface de rotina de usuário do ESMF.
  subroutine cap_initialize_p0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS
    call NUOPC_CompFilterPhaseMap(gcomp, ESMF_METHOD_INITIALIZE, &
      acceptStringList=(/"IPDv03p"/), rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine cap_initialize_p0

  !> @brief Cria e realiza no State os campos names(1:n) sobre a grade.
  !!
  !! Cada campo é real(8), no centro das células (ESMF_STAGGERLOC_CENTER), com
  !! o nome sem espaços à direita. Para no primeiro erro.
  !!
  !! @param[inout] state  State de importação ou de exportação
  !! @param[in]    grid   grade ESMF do componente
  !! @param[in]    names  nomes dos campos
  !! @param[in]    n      quantos nomes da lista usar
  !! @param[out]   rc     ESMF_SUCCESS, ou o código da primeira falha
  subroutine cap_realize_fields(state, grid, names, n, rc)
    type(ESMF_State),  intent(inout) :: state
    type(ESMF_Grid),   intent(in)    :: grid
    character(len=*),  intent(in)    :: names(:)
    integer,           intent(in)    :: n
    integer,           intent(out)   :: rc

    type(ESMF_Field) :: field
    integer          :: i

    rc = ESMF_SUCCESS
    do i = 1, n
      field = ESMF_FieldCreate(grid=grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(names(i)), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(state, field=field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

  end subroutine cap_realize_fields

  !> @brief Copia o arranjo 2D local para o campo name do State.
  !!
  !! @param[inout] state  State de exportação
  !! @param[in]    name   nome do campo
  !! @param[in]    array  valores na porção local da grade
  !! @param[in]    tag    início da mensagem de erro quando o campo não existe
  !! @param[out]   rc     ESMF_SUCCESS, ou o código da falha
  subroutine cap_put_field(state, name, array, tag, rc)
    type(ESMF_State),    intent(inout) :: state
    character(len=*),    intent(in)    :: name
    real(ESMF_KIND_R8),  intent(in)    :: array(:,:)
    character(len=*),    intent(in)    :: tag
    integer,             intent(out)   :: rc

    type(ESMF_Field)            :: field
    real(ESMF_KIND_R8), pointer :: fptr(:,:)

    rc = ESMF_SUCCESS
    call ESMF_StateGet(state, itemName=trim(name), field=field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=tag//trim(name), &
      line=__LINE__, file=__FILE__)) return
    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fptr = array
    nullify(fptr)

  end subroutine cap_put_field

end module cap_common_mod
