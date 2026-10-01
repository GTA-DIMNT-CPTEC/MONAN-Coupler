!> @file regrid_manager.F90
!! @brief Rotas de interpolação de um componente (por exemplo, o mediador).
!!
!! Uma rota tem um nome ('ocn2atm_sst'), um esquema e os campos de origem e
!! destino. O componente cria cada rota uma vez (add) e a usa a cada passo
!! (apply). A configuração da rota pode ser trocada em nuopc.input, no grupo
!! &nuopc_regrid, sem recompilar:
!!
!!   &nuopc_regrid
!!     regrid_route(1)   = 'ocn2atm_sst'
!!     regrid_scheme(1)  = 'weights_file'
!!     regrid_weights(1) = 'INPUT/pesos_ocn2atm.nc'
!!   /
!!
!! Cada rota criada é registrada no log do PET 0, numa linha do relatório de
!! acoplamento (prefixo CPL-REL:, ver src/coupling/cpl_check.F90): esquema,
!! métodos pedidos, máscara na origem e método aceito, ou a reserva usada.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_manager_mod

  use ESMF
  use regrid_base_mod,     only : regridder_t, regrid_spec_t, NAME_LEN, MAX_METHODS
  use regrid_registry_mod, only : regrid_create
  use coupler_config_mod,  only : cfg_regrid_route, cfg_regrid_scheme, cfg_regrid_methods, &
                                  cfg_regrid_weights, cfg_regrid_class

  implicit none
  private

  public :: regrid_manager_t
  public :: regrid_spec

  integer, parameter :: MAX_ROUTES = 32

  !> Rota: um esquema próprio (r) ou, se o setup falhou e havia rota de
  !! reserva, um apelido (alias) para outra rota já criada.
  type :: route_t
    character(len=NAME_LEN)         :: name = ''
    class(regridder_t), allocatable :: r
    integer                         :: alias = 0
  end type route_t

  type :: regrid_manager_t
    type(route_t) :: routes(MAX_ROUTES)
    integer       :: n = 0
  contains
    procedure :: add
    procedure :: apply
    procedure :: has
    procedure :: method
    procedure :: destroy
  end type regrid_manager_t

contains

  !> Monta um regrid_spec_t a partir de uma lista de métodos separados por
  !! vírgula ('conserve,bilinear').
  function regrid_spec(methods, scheme, mask_src, zero_total) result(spec)
    character(len=*), intent(in)           :: methods
    character(len=*), intent(in), optional :: scheme
    logical,          intent(in), optional :: mask_src, zero_total
    type(regrid_spec_t) :: spec

    call split_methods(methods, spec%methods)
    if (present(scheme))     spec%scheme     = scheme
    if (present(mask_src))   spec%mask_src   = mask_src
    if (present(zero_total)) spec%zero_total = zero_total
  end function regrid_spec

  !> Cria a rota e calcula a interpolação (pesos ou route handle).
  !! Se nenhum método funcionar e 'fallback' for dado, a rota passa a usar a
  !! rota 'fallback' (que precisa já existir).
  subroutine add(this, name, spec, src, dst, rc, fallback)
    class(regrid_manager_t), intent(inout) :: this
    character(len=*),        intent(in)    :: name
    type(regrid_spec_t),     intent(in)    :: spec
    type(ESMF_Field),        intent(inout) :: src, dst
    integer,                 intent(out)   :: rc
    character(len=*),        intent(in), optional :: fallback

    type(regrid_spec_t) :: final_spec
    integer :: k

    if (this%has(name)) then
      call ESMF_LogWrite('regrid: rota repetida: '//trim(name), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if
    if (this%n == MAX_ROUTES) then
      call ESMF_LogWrite('regrid: numero maximo de rotas atingido', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    final_spec = spec
    call apply_config(name, final_spec)

    k = this%n + 1
    call regrid_create(final_spec%scheme, this%routes(k)%r, rc)
    if (rc /= ESMF_SUCCESS) return
    this%routes(k)%r%label = name
    this%routes(k)%r%spec  = final_spec
    call this%routes(k)%r%setup(src, dst, rc)
    if (rc /= ESMF_SUCCESS) then
      deallocate(this%routes(k)%r)
      if (.not. present(fallback)) return
      this%routes(k)%alias = find(this, fallback)
      if (this%routes(k)%alias == 0) return
      call ESMF_LogWrite('regrid: rota '//trim(name)//' usara a rota de reserva '// &
        trim(fallback), ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
    end if
    this%routes(k)%name = name
    this%n = k
    call report_route(this, k, final_spec)
  end subroutine add

  !> Linha do relatório de acoplamento para a rota k, no log do PET 0.
  subroutine report_route(this, k, spec)
    class(regrid_manager_t), intent(in) :: this
    integer,                 intent(in) :: k
    type(regrid_spec_t),     intent(in) :: spec

    type(ESMF_VM) :: vm
    integer :: localPet, rc, m
    character(len=:), allocatable :: line

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localPet /= 0) return

    line = 'CPL-REL: rota '//trim(this%routes(k)%name)//': esquema '//trim(spec%scheme)// &
           ', metodos '
    do m = 1, MAX_METHODS
      if (len_trim(spec%methods(m)) == 0) exit
      if (m > 1) line = line//','
      line = line//trim(spec%methods(m))
    end do
    if (len_trim(spec%methods(1)) == 0) line = line//'-'
    line = line//', mascara '//trim(merge('sim', 'nao', spec%mask_src))
    if (this%routes(k)%alias > 0) then
      line = line//', nenhum metodo aceito, usa a reserva '// &
             trim(this%routes(this%routes(k)%alias)%name)
    else
      line = line//', aceito '//trim(this%routes(k)%r%method_used)
    end if
    call ESMF_LogWrite(line, ESMF_LOGMSG_INFO)
  end subroutine report_route

  !> Interpola pela rota. zero_total, se presente, substitui o da rota.
  subroutine apply(this, name, src, dst, rc, zero_total)
    class(regrid_manager_t), intent(inout) :: this
    character(len=*),        intent(in)    :: name
    type(ESMF_Field),        intent(inout) :: src, dst
    integer,                 intent(out)   :: rc
    logical, optional,       intent(in)    :: zero_total

    integer :: k

    k = resolve(this, name)
    if (k == 0) then
      call ESMF_LogWrite('regrid: rota inexistente: '//trim(name), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if
    call this%routes(k)%r%apply(src, dst, rc, zero_total)
  end subroutine apply

  logical function has(this, name)
    class(regrid_manager_t), intent(in) :: this
    character(len=*),        intent(in) :: name
    has = (find(this, name) > 0)
  end function has

  !> Método efetivamente usado pela rota ('' se a rota não existe).
  function method(this, name) result(m)
    class(regrid_manager_t), intent(in) :: this
    character(len=*),        intent(in) :: name
    character(len=NAME_LEN) :: m
    integer :: k
    m = ''
    k = resolve(this, name)
    if (k > 0) m = this%routes(k)%r%method_used
  end function method

  subroutine destroy(this, rc)
    class(regrid_manager_t), intent(inout) :: this
    integer,                 intent(out)   :: rc
    integer :: k, rc_k

    rc = ESMF_SUCCESS
    do k = 1, this%n
      if (allocated(this%routes(k)%r)) then
        call this%routes(k)%r%release(rc_k)
        if (rc_k /= ESMF_SUCCESS) rc = rc_k
        deallocate(this%routes(k)%r)
      end if
      this%routes(k)%name  = ''
      this%routes(k)%alias = 0
    end do
    this%n = 0
  end subroutine destroy

  integer function find(this, name)
    class(regrid_manager_t), intent(in) :: this
    character(len=*),        intent(in) :: name
    integer :: k
    find = 0
    do k = 1, this%n
      if (trim(this%routes(k)%name) == trim(name)) then
        find = k
        return
      end if
    end do
  end function find

  !> Índice da rota que de fato interpola (segue o apelido, se houver).
  integer function resolve(this, name)
    class(regrid_manager_t), intent(in) :: this
    character(len=*),        intent(in) :: name
    resolve = find(this, name)
    if (resolve > 0) then
      if (this%routes(resolve)%alias > 0) resolve = this%routes(resolve)%alias
    end if
  end function resolve

  !> Substitui a configuração padrão da rota pelo que estiver em &nuopc_regrid.
  subroutine apply_config(name, spec)
    character(len=*),    intent(in)    :: name
    type(regrid_spec_t), intent(inout) :: spec
    integer :: k

    do k = 1, size(cfg_regrid_route)
      if (trim(cfg_regrid_route(k)) /= trim(name)) cycle
      if (len_trim(cfg_regrid_scheme(k))  > 0) spec%scheme       = cfg_regrid_scheme(k)
      if (len_trim(cfg_regrid_methods(k)) > 0) call split_methods(cfg_regrid_methods(k), spec%methods)
      if (len_trim(cfg_regrid_weights(k)) > 0) spec%weights_file = cfg_regrid_weights(k)
      if (len_trim(cfg_regrid_class(k))   > 0) spec%field_class  = cfg_regrid_class(k)
      call ESMF_LogWrite('regrid: rota '//trim(name)//' configurada por &nuopc_regrid', &
        ESMF_LOGMSG_INFO)
      return
    end do
  end subroutine apply_config

  subroutine split_methods(list, methods)
    character(len=*),        intent(in)  :: list
    character(len=NAME_LEN), intent(out) :: methods(MAX_METHODS)
    integer :: k, p, start

    methods = ''
    start = 1
    do k = 1, MAX_METHODS
      p = index(list(start:), ',')
      if (p == 0) then
        methods(k) = adjustl(list(start:))
        return
      end if
      methods(k) = adjustl(list(start:start+p-2))
      start = start + p
    end do
  end subroutine split_methods

end module regrid_manager_mod
