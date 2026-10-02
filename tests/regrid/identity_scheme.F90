!> Esquemas mínimos usados no teste: copiam o campo de origem para o
!! destino (mesma grade). Mostram como um esquema externo se encaixa no
!! framework: identity_regridder_t estende regridder_t diretamente;
!! pesos_identidade_t estende a base de pesos (weights_regridder_t) e só
!! escreve calcula_pesos, com peso 1 de cada ponto para o de mesmo índice.
module identity_scheme_mod
  use ESMF
  use regrid_base_mod,         only : regridder_t
  use regrid_weights_base_mod, only : weights_regridder_t, regrid_pontos_t
  implicit none
  private
  public :: new_identity, new_pesos_identidade

  type, extends(regridder_t) :: identity_regridder_t
  contains
    procedure :: setup   => id_setup
    procedure :: execute => id_execute
    procedure :: release => id_release
  end type identity_regridder_t

  type, extends(weights_regridder_t) :: pesos_identidade_t
  contains
    procedure :: calcula_pesos => pi_calcula_pesos
  end type pesos_identidade_t

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

  subroutine new_pesos_identidade(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(pesos_identidade_t :: r)
  end subroutine new_pesos_identidade

  subroutine pi_calcula_pesos(this, origem, destino, fator, orig, dest, rc)
    class(pesos_identidade_t),       intent(inout) :: this
    type(regrid_pontos_t),           intent(in)    :: origem, destino
    real(ESMF_KIND_R8), allocatable, intent(out)   :: fator(:)
    integer,            allocatable, intent(out)   :: orig(:), dest(:)
    integer,                         intent(out)   :: rc
    allocate(fator(size(destino%indice)))
    fator = 1.0_ESMF_KIND_R8
    orig  = destino%indice
    dest  = destino%indice
    this%method_used = 'pesos_identidade'
    rc = ESMF_SUCCESS
    if (size(origem%indice) < maxval([0, dest])) rc = ESMF_FAILURE
  end subroutine pi_calcula_pesos
end module identity_scheme_mod
