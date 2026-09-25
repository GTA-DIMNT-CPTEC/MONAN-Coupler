!> @file regrid_registry.F90
!! @brief Catálogo dos esquemas de interpolação disponíveis.
!!
!! Cada esquema é identificado por um nome e por uma rotina que cria uma
!! instância vazia dele. Para acrescentar um esquema novo:
!!   1. escrever um módulo com um tipo que estende regridder_t;
!!   2. registrá-lo: call regrid_register('meu_esquema', novo_meu_esquema, rc)
!!      (ou incluí-lo em register_builtins, se for de uso geral);
!!   3. selecioná-lo em nuopc.input (&nuopc_regrid) ou no regrid_spec_t.
!! Nenhum outro arquivo do acoplador precisa ser alterado.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_registry_mod

  use ESMF,               only : ESMF_SUCCESS, ESMF_FAILURE, ESMF_LogWrite, ESMF_LOGMSG_ERROR
  use regrid_base_mod,    only : regridder_t, NAME_LEN
  use regrid_esmf_mod,    only : esmf_regridder_t
  use regrid_weights_mod, only : weights_file_regridder_t
  use regrid_mpassit_mod, only : mpassit_regridder_t

  implicit none
  private

  public :: regridder_ctor
  public :: regrid_register
  public :: regrid_create
  public :: regrid_is_registered

  abstract interface
    !> Cria uma instância vazia de um esquema.
    subroutine regridder_ctor(r)
      import :: regridder_t
      class(regridder_t), allocatable, intent(out) :: r
    end subroutine regridder_ctor
  end interface

  type :: entry_t
    character(len=NAME_LEN) :: name = ''
    procedure(regridder_ctor), pointer, nopass :: ctor => null()
  end type entry_t

  integer, parameter :: MAX_SCHEMES = 16
  type(entry_t), save :: table(MAX_SCHEMES)
  integer,       save :: n_schemes = 0

contains

  !> Registra (ou substitui) um esquema.
  subroutine regrid_register(name, ctor, rc)
    character(len=*), intent(in)  :: name
    procedure(regridder_ctor)     :: ctor
    integer,          intent(out) :: rc

    integer :: k

    rc = ESMF_SUCCESS
    k = find(name)
    if (k == 0) then
      if (n_schemes == MAX_SCHEMES) then
        call ESMF_LogWrite('regrid: catalogo de esquemas cheio', ESMF_LOGMSG_ERROR)
        rc = ESMF_FAILURE
        return
      end if
      n_schemes = n_schemes + 1
      k = n_schemes
    end if
    table(k)%name = name
    table(k)%ctor => ctor
  end subroutine regrid_register

  logical function regrid_is_registered(name)
    character(len=*), intent(in) :: name
    call register_builtins()
    regrid_is_registered = (find(name) > 0)
  end function regrid_is_registered

  !> Cria uma instância do esquema pedido.
  subroutine regrid_create(scheme, r, rc)
    character(len=*),                intent(in)  :: scheme
    class(regridder_t), allocatable, intent(out) :: r
    integer,                         intent(out) :: rc

    integer :: k

    call register_builtins()
    k = find(scheme)
    if (k == 0) then
      call ESMF_LogWrite('regrid: esquema nao registrado: '//trim(scheme), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if
    call table(k)%ctor(r)
    rc = ESMF_SUCCESS
  end subroutine regrid_create

  integer function find(name)
    character(len=*), intent(in) :: name
    integer :: k
    find = 0
    do k = 1, n_schemes
      if (trim(table(k)%name) == trim(name)) then
        find = k
        return
      end if
    end do
  end function find

  !> Esquemas que acompanham o acoplador.
  subroutine register_builtins()
    logical, save :: done = .false.
    integer :: rc

    if (done) return
    done = .true.
    call regrid_register('esmf',         new_esmf,    rc)
    call regrid_register('weights_file', new_weights, rc)
    call regrid_register('mpassit',      new_mpassit, rc)
  end subroutine register_builtins

  subroutine new_esmf(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(esmf_regridder_t :: r)
  end subroutine new_esmf

  subroutine new_weights(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(weights_file_regridder_t :: r)
  end subroutine new_weights

  subroutine new_mpassit(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(mpassit_regridder_t :: r)
  end subroutine new_mpassit

end module regrid_registry_mod
