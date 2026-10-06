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
!!     regrid_route(2)   = 'ocn2atm'
!!     regrid_scheme(2)  = 'idw'
!!     regrid_options(2) = 'vizinhos=4,expoente=2'
!!   /
!!
!! Cada rota criada é registrada no log do PET 0, numa linha do relatório de
!! acoplamento (prefixo CPL-REL:, ver src/coupling/cpl_check.F90): esquema,
!! métodos pedidos, máscara na origem, opções do esquema (só se houver) e
!! método aceito, ou a reserva usada.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_manager_mod

  use ESMF
  use coupler_log_mod, only : COMP_REGRID, log_error, log_info, log_warning, log_report
  use regrid_base_mod,     only : regridder_t, regrid_spec_t, regrid_fill_t, neighbor_fill, &
                                  NAME_LEN, MAX_METHODS
  use regrid_registry_mod, only : regrid_create
  use coupler_config_mod,  only : cfg_regrid_route, cfg_regrid_scheme, cfg_regrid_methods, &
                                  cfg_regrid_weights, cfg_regrid_class, cfg_regrid_options

  implicit none
  private

  public :: regrid_manager_t
  public :: regrid_spec

  integer, parameter :: MAX_ROUTES = 32

  !> Rota: um esquema próprio (r) ou, se o setup falhou e havia rota de
  !! reserva, um apelido (alias) para outra rota já criada. spec é a
  !! configuração pedida para a rota: mesmo quando ela usa a interpolação da
  !! reserva, o zero_total, a troca de NaN e o preenchimento por vizinhança
  !! são os dela, e não os da reserva.
  type :: route_t
    character(len=NAME_LEN)         :: name = ''
    class(regridder_t), allocatable :: r
    integer                         :: alias = 0
    type(regrid_spec_t)             :: spec
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

  !> @brief Monta um regrid_spec_t a partir de uma lista de métodos separados por
  !! vírgula ('conserve,bilinear').
  function regrid_spec(methods, scheme, mask_src, zero_total, nan_value, options) result(spec)
    character(len=*),   intent(in)           :: methods
    character(len=*),   intent(in), optional :: scheme, options
    logical,            intent(in), optional :: mask_src, zero_total
    real(ESMF_KIND_R8), intent(in), optional :: nan_value
    type(regrid_spec_t) :: spec

    call split_methods(methods, spec%methods)
    if (present(scheme))     spec%scheme     = scheme
    if (present(options))    spec%options    = options
    if (present(mask_src))   spec%mask_src   = mask_src
    if (present(zero_total)) spec%zero_total = zero_total
    if (present(nan_value)) then
      spec%nan_replace = .true.
      spec%nan_value   = nan_value
    end if
  end function regrid_spec

  !> @brief Cria a rota e calcula a interpolação (pesos ou route handle).
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
      call log_error(COMP_REGRID, 'rota repetida: '//trim(name))
      rc = ESMF_FAILURE
      return
    end if
    if (this%n == MAX_ROUTES) then
      call log_error(COMP_REGRID, 'numero maximo de rotas atingido')
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
      call log_warning(COMP_REGRID, 'rota '//trim(name)//' usara a rota de reserva '// &
        trim(fallback))
      rc = ESMF_SUCCESS
    end if
    this%routes(k)%name = name
    this%routes(k)%spec = final_spec
    this%n = k
    call report_route(this, k, final_spec)
  end subroutine add

  !> @brief Linha do relatório de acoplamento para a rota k, no log do PET 0.
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

    line = 'rota '//trim(this%routes(k)%name)//': esquema '//trim(spec%scheme)// &
           ', metodos '
    do m = 1, MAX_METHODS
      if (len_trim(spec%methods(m)) == 0) exit
      if (m > 1) line = line//','
      line = line//trim(spec%methods(m))
    end do
    if (len_trim(spec%methods(1)) == 0) line = line//'-'
    line = line//', mascara '//trim(merge('sim', 'nao', spec%mask_src))
    if (len_trim(spec%options) > 0) line = line//', opcoes '//trim(spec%options)
    if (this%routes(k)%alias > 0) then
      line = line//', nenhum metodo aceito, usa a reserva '// &
             trim(this%routes(this%routes(k)%alias)%name)
    else
      line = line//', aceito '//trim(this%routes(k)%r%method_used)
    end if
    call log_report(line)
  end subroutine report_route

  !> @brief Interpola pela rota, nesta ordem (a das etapas de ROUTES, em cpl_map):
  !! interpolação, preenchimento por vizinhança (spec%fill, etapa completar)
  !! e troca de NaN (spec%nan_replace). As três usam a configuração da rota
  !! pedida, mesmo quando ela usa a interpolação da reserva.
  !!
  !! @param[in]  zero_total  se presente, substitui o da rota
  !! @param[in]  fill        se presente, substitui o preenchimento da rota
  !!                         (para completar como outra rota quando ela
  !!                         ainda não existe)
  !! @param[out] n_invalid   pontos fora da faixa antes do preenchimento,
  !!                         somados nos DEs locais; -1 se não houve
  !!                         preenchimento (desligado, falha ou nenhum DE)
  !! @param[out] n_left      pontos que ficaram com o valor fixo; -1 idem
  subroutine apply(this, name, src, dst, rc, zero_total, fill, n_invalid, n_left)
    class(regrid_manager_t), intent(inout) :: this
    character(len=*),        intent(in)    :: name
    type(ESMF_Field),        intent(inout) :: src, dst
    integer,                 intent(out)   :: rc
    logical, optional,       intent(in)    :: zero_total
    type(regrid_fill_t), optional, intent(in)  :: fill
    integer,             optional, intent(out) :: n_invalid, n_left

    integer :: k, k_requested, ni, nl
    logical :: zt
    type(regrid_fill_t) :: fill_cfg

    if (present(n_invalid)) n_invalid = -1
    if (present(n_left))    n_left    = -1
    k_requested = find(this, name)
    k = resolve(this, name)
    if (k == 0) then
      call log_error(COMP_REGRID, 'rota inexistente: '//trim(name))
      rc = ESMF_FAILURE
      return
    end if
    zt = this%routes(k_requested)%spec%zero_total
    if (present(zero_total)) zt = zero_total
    call this%routes(k)%r%apply(src, dst, rc, zt)
    if (rc /= ESMF_SUCCESS) return

    fill_cfg = this%routes(k_requested)%spec%fill
    if (present(fill)) fill_cfg = fill
    if (fill_cfg%enabled) then
      call complete(dst, fill_cfg, ni, nl, rc)
      if (present(n_invalid)) n_invalid = ni
      if (present(n_left))    n_left    = nl
      if (rc /= ESMF_SUCCESS) return
    end if
    if (this%routes(k_requested)%spec%nan_replace) &
      call replace_nan(dst, this%routes(k_requested)%spec%nan_value, rc)
  end subroutine apply

  !> @brief Preenchimento por vizinhança do destino, em cada DE local (sem troca de
  !! halo), com as contagens somadas nos DEs; -1 nas duas se não há DE local.
  subroutine complete(dst, opt, n_invalid, n_left, rc)
    type(ESMF_Field),    intent(inout) :: dst
    type(regrid_fill_t), intent(in)    :: opt
    integer,             intent(out)   :: n_invalid, n_left
    integer,             intent(out)   :: rc
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: lde, ldec, ni, nl

    n_invalid = -1
    n_left    = -1
    call ESMF_FieldGet(dst, localDeCount=ldec, rc=rc)
    if (rc /= ESMF_SUCCESS .or. ldec == 0) return
    n_invalid = 0
    n_left    = 0
    do lde = 0, ldec - 1
      call ESMF_FieldGet(dst, localDe=lde, farrayPtr=p, rc=rc)
      if (rc /= ESMF_SUCCESS) return
      call neighbor_fill(p, opt, n_left=nl, n_invalid=ni)
      n_invalid = n_invalid + ni
      n_left    = n_left    + nl
    end do
  end subroutine complete

  !> @brief Troca os NaN do destino, em cada DE local, por val.
  subroutine replace_nan(dst, val, rc)
    type(ESMF_Field),   intent(inout) :: dst
    real(ESMF_KIND_R8), intent(in)    :: val
    integer,            intent(out)   :: rc
    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: lde, ldec

    call ESMF_FieldGet(dst, localDeCount=ldec, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    do lde = 0, ldec - 1
      call ESMF_FieldGet(dst, localDe=lde, farrayPtr=p, rc=rc)
      if (rc /= ESMF_SUCCESS) return
      where (p /= p) p = val
    end do
  end subroutine replace_nan

  !> @brief Verdadeiro se a rota name já foi criada.
  logical function has(this, name)
    class(regrid_manager_t), intent(in) :: this
    character(len=*),        intent(in) :: name
    has = (find(this, name) > 0)
  end function has

  !> @brief Método efetivamente usado pela rota ('' se a rota não existe).
  function method(this, name) result(m)
    class(regrid_manager_t), intent(in) :: this
    character(len=*),        intent(in) :: name
    character(len=NAME_LEN) :: m
    integer :: k
    m = ''
    k = resolve(this, name)
    if (k > 0) m = this%routes(k)%r%method_used
  end function method

  !> @brief Libera todas as rotas; rc fica com a última falha de release, se houver.
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
      this%routes(k)%spec  = regrid_spec_t()
    end do
    this%n = 0
  end subroutine destroy

  !> @brief Índice da rota name (0 se não existe), sem seguir o apelido.
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

  !> @brief Índice da rota que de fato interpola (segue o apelido, se houver).
  integer function resolve(this, name)
    class(regrid_manager_t), intent(in) :: this
    character(len=*),        intent(in) :: name
    resolve = find(this, name)
    if (resolve > 0) then
      if (this%routes(resolve)%alias > 0) resolve = this%routes(resolve)%alias
    end if
  end function resolve

  !> @brief Substitui a configuração padrão da rota pelo que estiver em &nuopc_regrid.
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
      if (len_trim(cfg_regrid_options(k)) > 0) spec%options      = cfg_regrid_options(k)
      call log_info(COMP_REGRID, 'rota '//trim(name)//' configurada por &nuopc_regrid')
      return
    end do
  end subroutine apply_config

  !> @brief Separa a lista 'm1,m2,...' em até MAX_METHODS nomes, sem espaços à esquerda.
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
