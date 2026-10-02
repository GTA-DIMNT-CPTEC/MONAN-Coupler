!> Esquemas mínimos usados no teste: copiam o campo de origem para o
!! destino (mesma grade). Mostram como um esquema externo se encaixa no
!! framework: identity_regridder_t estende regridder_t diretamente;
!! identity_weights_t estende a base de pesos (weights_regridder_t) e só
!! escreve compute_weights, com peso 1 de cada ponto para o de mesmo índice.
module identity_scheme_mod
  use ESMF
  use regrid_base_mod,         only : regridder_t
  use regrid_weights_base_mod, only : weights_regridder_t, regrid_points_t
  implicit none
  private
  public :: new_identity, new_identity_weights

  type, extends(regridder_t) :: identity_regridder_t
  contains
    procedure :: setup   => id_setup
    procedure :: execute => id_execute
    procedure :: release => id_release
  end type identity_regridder_t

  type, extends(weights_regridder_t) :: identity_weights_t
  contains
    procedure :: compute_weights => iw_compute_weights
  end type identity_weights_t

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

  subroutine new_identity_weights(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(identity_weights_t :: r)
  end subroutine new_identity_weights

  subroutine iw_compute_weights(this, src_points, dst_points, factors, orig, dest, rc)
    class(identity_weights_t),       intent(inout) :: this
    type(regrid_points_t),           intent(in)    :: src_points, dst_points
    real(ESMF_KIND_R8), allocatable, intent(out)   :: factors(:)
    integer,            allocatable, intent(out)   :: orig(:), dest(:)
    integer,                         intent(out)   :: rc
    allocate(factors(size(dst_points%global_index)))
    factors = 1.0_ESMF_KIND_R8
    orig  = dst_points%global_index
    dest  = dst_points%global_index
    this%method_used = 'pesos_identidade'
    rc = ESMF_SUCCESS
    if (size(src_points%global_index) < maxval([0, dest])) rc = ESMF_FAILURE
  end subroutine iw_compute_weights
end module identity_scheme_mod
