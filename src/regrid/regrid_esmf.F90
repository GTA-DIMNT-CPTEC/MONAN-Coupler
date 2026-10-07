!> @file regrid_esmf.F90
!! @brief Esquema 'esmf': interpolação calculada pelo ESMF durante a execução.
!!
!! Tenta os métodos de spec%methods em ordem e usa o primeiro cujo
!! ESMF_FieldRegridStore funcionar (por exemplo, 'conserve' e, se a grade
!! não tiver cantos, 'bilinear'). Para que o resultado seja reprodutível bit
!! a bit, toda a soma é feita no destino (srcTermProcessing = 0) e na ordem
!! do índice de origem (termorder = srcseq).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_esmf_mod

  use ESMF
  use coupler_log_mod, only : COMP_REGRID, log_error, log_info, log_warning
  use regrid_base_mod, only : regridder_t, MAX_METHODS

  implicit none
  private

  public :: esmf_regridder_t
  public :: regrid_method_flag
  public :: new_esmf

  type, extends(regridder_t) :: esmf_regridder_t
    type(ESMF_RouteHandle) :: rh
  contains
    procedure :: setup   => esmf_setup
    procedure :: execute => esmf_execute
    procedure :: release => esmf_release
    procedure :: store   => esmf_store
  end type esmf_regridder_t

contains

  !> @brief Construtor usado pela lista de esquemas (regrid_schemes.F90).
  subroutine new_esmf(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(esmf_regridder_t :: r)
  end subroutine new_esmf

  !> @brief setup do esquema 'esmf': tenta os métodos de spec%methods em ordem e
  !! fica com o primeiro cujo ESMF_FieldRegridStore funciona.
  subroutine esmf_setup(this, src, dst, rc)
    class(esmf_regridder_t), intent(inout) :: this
    type(ESMF_Field),        intent(inout) :: src, dst
    integer,                 intent(out)   :: rc

    integer :: k

    rc = ESMF_FAILURE
    do k = 1, MAX_METHODS
      if (len_trim(this%spec%methods(k)) == 0) exit
      call this%store(src, dst, this%spec%methods(k), rc)
      if (rc == ESMF_SUCCESS) then
        this%method_used = this%spec%methods(k)
        this%ready = .true.
        call log_info(COMP_REGRID, 'rota '//trim(this%label)//' pronta, esquema esmf, metodo '// &
          trim(this%method_used))
        return
      end if
      call log_warning(COMP_REGRID, 'rota '//trim(this%label)//' metodo '// &
        trim(this%spec%methods(k))//' falhou; tentando o proximo')
    end do
    call log_error(COMP_REGRID, 'rota '//trim(this%label)//' sem metodo utilizavel')
  end subroutine esmf_setup

  !> @brief Calcula o route handle para um método (usado também pelas extensões).
  subroutine esmf_store(this, src, dst, method, rc)
    class(esmf_regridder_t), intent(inout) :: this
    type(ESMF_Field),        intent(inout) :: src, dst
    character(len=*),        intent(in)    :: method
    integer,                 intent(out)   :: rc

    type(ESMF_RegridMethod_Flag) :: flag
    integer :: srcTermProcessing

    call regrid_method_flag(method, flag, rc)
    if (rc /= ESMF_SUCCESS) return

    srcTermProcessing = 0
    if (this%spec%mask_src) then
      call ESMF_FieldRegridStore(srcField=src, dstField=dst, routehandle=this%rh, &
        regridmethod=flag, srcMaskValues=[0_ESMF_KIND_I4],                        &
        unmappedaction=ESMF_UNMAPPEDACTION_IGNORE,                                &
        srcTermProcessing=srcTermProcessing, rc=rc)
    else
      call ESMF_FieldRegridStore(srcField=src, dstField=dst, routehandle=this%rh, &
        regridmethod=flag, unmappedaction=ESMF_UNMAPPEDACTION_IGNORE,             &
        srcTermProcessing=srcTermProcessing, rc=rc)
    end if
  end subroutine esmf_store

  !> @brief execute do esquema 'esmf': ESMF_FieldRegrid na ordem do índice de
  !! origem (termorder = srcseq).
  subroutine esmf_execute(this, src, dst, zero_total, rc)
    class(esmf_regridder_t), intent(inout) :: this
    type(ESMF_Field),        intent(inout) :: src, dst
    logical,                 intent(in)    :: zero_total
    integer,                 intent(out)   :: rc

    if (zero_total) then
      call ESMF_FieldRegrid(src, dst, this%rh, termorderflag=ESMF_TERMORDER_SRCSEQ, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
    else
      call ESMF_FieldRegrid(src, dst, this%rh, termorderflag=ESMF_TERMORDER_SRCSEQ, &
        zeroregion=ESMF_REGION_SELECT, rc=rc)
    end if
  end subroutine esmf_execute

  !> @brief release do esquema 'esmf': libera o route handle, se criado.
  subroutine esmf_release(this, rc)
    class(esmf_regridder_t), intent(inout) :: this
    integer,                 intent(out)   :: rc

    rc = ESMF_SUCCESS
    if (this%ready) call ESMF_FieldRegridRelease(this%rh, rc=rc)
    this%ready = .false.
  end subroutine esmf_release

  !> @brief Converte o nome do método no identificador do ESMF.
  subroutine regrid_method_flag(method, flag, rc)
    character(len=*),             intent(in)  :: method
    type(ESMF_RegridMethod_Flag), intent(out) :: flag
    integer,                      intent(out) :: rc

    rc = ESMF_SUCCESS
    select case (trim(method))
    case ('bilinear');     flag = ESMF_REGRIDMETHOD_BILINEAR
    case ('patch');        flag = ESMF_REGRIDMETHOD_PATCH
    case ('conserve');     flag = ESMF_REGRIDMETHOD_CONSERVE
    case ('conserve_2nd'); flag = ESMF_REGRIDMETHOD_CONSERVE_2ND
    case ('nearest_stod'); flag = ESMF_REGRIDMETHOD_NEAREST_STOD
    case ('nearest_dtos'); flag = ESMF_REGRIDMETHOD_NEAREST_DTOS
    case default
      call log_error(COMP_REGRID, 'metodo desconhecido: '//trim(method))
      rc = ESMF_FAILURE
    end select
  end subroutine regrid_method_flag

end module regrid_esmf_mod
