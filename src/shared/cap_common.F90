!> @file cap_common.F90
!! @brief Procedimentos comuns aos caps NUOPC do acoplador.
!!
!! Reúne o que é comum aos caps:
!!
!!  - cap_initialize_p0: fase 0 da inicialização, que restringe as fases do
!!    componente ao protocolo IPDv03. O mediador e os caps do MOM6, do SIS2,
!!    do DATM e do DOCN a registram diretamente; o cap do MONAN-A a chama e
!!    acrescenta o registro da data inicial no log.
!!  - cap_realize_fields: cria, no centro das células de uma ESMF_Grid, um
!!    campo real(8) para cada nome da lista e o realiza no State.
!!  - cap_put_field: copia um arranjo 2D local para um campo do State.
!!  - cap_fill_export_initial: valores iniciais dos campos exportados, por
!!    nome, na inicialização de dados dos caps de dados (DATM e DOCN).
!!  - cap_set_data_complete: marca a inicialização de dados como concluída.
!!  - cap_stamp_export: carimba todos os campos exportados com um instante.
!!
!! A obtenção do estado interno continua em cada cap: o tipo do invólucro é
!! próprio de cada componente, e ESMF_GridCompGetInternalState exige o tipo
!! concreto.

module cap_common_mod

  use ESMF, only: ESMF_GridComp, ESMF_State, ESMF_Clock, ESMF_Grid, &
                  ESMF_Time,                                        &
                  ESMF_Field, ESMF_FieldCreate, ESMF_FieldGet,      &
                  ESMF_StateGet, ESMF_LogFoundError,                &
                  ESMF_METHOD_INITIALIZE, ESMF_STAGGERLOC_CENTER,   &
                  ESMF_TYPEKIND_R8, ESMF_KIND_R8, ESMF_SUCCESS
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Realize, &
                   NUOPC_CompAttributeSet, NUOPC_SetTimestamp
  use coupler_utils_mod, only: ChkErr
  implicit none
  private

  public :: cap_initialize_p0
  public :: cap_realize_fields
  public :: cap_put_field
  public :: cap_fill_export_initial
  public :: cap_set_data_complete
  public :: cap_stamp_export

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

  !> @brief Preenche cada campo do State com o valor inicial do seu nome.
  !!
  !! Percorre os campos na ordem do State. O campo cujo nome está em
  !! names(k) recebe values(k); os demais recebem zero.
  !!
  !! @param[inout] exportState  State de exportação
  !! @param[in]    names        nomes com valor inicial próprio
  !! @param[in]    values       valor inicial de cada nome
  !! @param[out]   rc           ESMF_SUCCESS, ou o código da falha
  subroutine cap_fill_export_initial(exportState, names, values, rc)
    type(ESMF_State),   intent(inout) :: exportState
    character(len=*),   intent(in)    :: names(:)
    real(ESMF_KIND_R8), intent(in)    :: values(:)
    integer,            intent(out)   :: rc

    type(ESMF_Field)               :: field
    integer                        :: fieldCount, i, k
    character(len=64), allocatable :: fieldNameList(:)
    real(ESMF_KIND_R8), pointer    :: fptr(:,:)
    real(ESMF_KIND_R8)             :: val

    rc = ESMF_SUCCESS

    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (fieldCount > 0) then
      allocate(fieldNameList(fieldCount))
      call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      do i = 1, fieldCount
        call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
          field=field, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return

        call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return

        val = 0.0_ESMF_KIND_R8
        do k = 1, size(names)
          if (trim(fieldNameList(i)) == trim(names(k))) then
            val = values(k)
            exit
          end if
        end do
        fptr = val
        nullify(fptr)
      end do
      deallocate(fieldNameList)
    end if

  end subroutine cap_fill_export_initial

  !> @brief Marca a inicialização de dados do componente como concluída.
  !!
  !! @param[in]  gcomp  componente
  !! @param[out] rc     ESMF_SUCCESS, ou o código da falha
  subroutine cap_set_data_complete(gcomp, rc)
    type(ESMF_GridComp), intent(in)  :: gcomp
    integer,             intent(out) :: rc

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", value="true", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete",  value="true", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

  end subroutine cap_set_data_complete

  !> @brief Carimba todos os campos do State com o instante dado.
  !!
  !! @param[inout] exportState  State de exportação
  !! @param[in]    stampTime    instante (NUOPC_SetTimestamp)
  !! @param[out]   rc           ESMF_SUCCESS, ou o código da falha
  subroutine cap_stamp_export(exportState, stampTime, rc)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Time),  intent(in)    :: stampTime
    integer,          intent(out)   :: rc

    type(ESMF_Field)               :: field
    integer                        :: fieldCount, k
    character(len=64), allocatable :: fieldNameList(:)

    rc = ESMF_SUCCESS

    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fieldNameList(k)), &
        field=field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_SetTimestamp(field, stampTime, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
    deallocate(fieldNameList)

  end subroutine cap_stamp_export

end module cap_common_mod
