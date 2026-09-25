!> Esquema mínimo usado no teste: copia o campo de origem para o destino
!! (mesma grade). Mostra como um esquema externo se encaixa no framework.
module identity_scheme_mod
  use ESMF
  use regrid_base_mod, only : regridder_t
  implicit none
  private
  public :: new_identity

  type, extends(regridder_t) :: identity_regridder_t
  contains
    procedure :: setup   => id_setup
    procedure :: execute => id_execute
    procedure :: release => id_release
  end type identity_regridder_t

contains

  subroutine new_identity(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(identity_regridder_t :: r)
  end subroutine new_identity

  subroutine id_setup(this, src, dst, rc)
    class(identity_regridder_t), intent(inout) :: this
    type(ESMF_Field),            intent(inout) :: src, dst
    integer,                     intent(out)   :: rc
    this%method_used = 'identidade'
    this%ready = .true.
    rc = ESMF_SUCCESS
  end subroutine id_setup

  subroutine id_execute(this, src, dst, zero_total, rc)
    class(identity_regridder_t), intent(inout) :: this
    type(ESMF_Field),            intent(inout) :: src, dst
    logical,                     intent(in)    :: zero_total
    integer,                     intent(out)   :: rc
    real(ESMF_KIND_R8), pointer :: a(:,:), b(:,:)
    call ESMF_FieldGet(src, farrayPtr=a, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(dst, farrayPtr=b, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    b = a
  end subroutine id_execute

  subroutine id_release(this, rc)
    class(identity_regridder_t), intent(inout) :: this
    integer,                     intent(out)   :: rc
    this%ready = .false.
    rc = ESMF_SUCCESS
  end subroutine id_release
end module identity_scheme_mod
