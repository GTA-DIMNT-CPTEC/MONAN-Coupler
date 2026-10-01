!> @file regrid_base.F90
!! @brief Interface comum dos esquemas de interpolação (regrid) do acoplador.
!!
!! Todo esquema de interpolação é uma extensão do tipo abstrato regridder_t
!! e implementa três operações:
!!   setup    prepara a interpolação entre dois campos (pesos, route handle);
!!            depende só da geometria, é chamada uma vez;
!!   execute  interpola os valores do campo de origem para o de destino;
!!   release  libera os recursos.
!! Quem usa o esquema chama apply, que confere o setup e executa a
!! interpolação. As etapas seguintes da rota (preenchimento por vizinhança
!! dos pontos sem valor válido e troca de NaN) são de regrid_manager%apply.
!!
!! O comportamento de cada interpolação é descrito por um regrid_spec_t
!! (esquema, métodos em ordem de preferência, máscaras, preenchimento).
!! Novos esquemas são registrados em regrid_registry_mod.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_base_mod

  use ESMF

  implicit none
  private

  public :: regridder_t
  public :: regrid_spec_t
  public :: regrid_fill_t
  public :: neighbor_fill
  public :: MAX_METHODS, NAME_LEN

  integer, parameter :: MAX_METHODS = 4    !< tamanho máximo da cadeia de métodos
  integer, parameter :: NAME_LEN    = 32

  !> Preenchimento por vizinhança aplicado ao campo de destino depois da
  !! interpolação: pontos fora de [vmin, vmax] (ou NaN) recebem a média dos
  !! vizinhos válidos, em até max_iter passadas; o que sobrar recebe vfill.
  type :: regrid_fill_t
    logical            :: enabled  = .false.
    real(ESMF_KIND_R8) :: vmin     = 0.0_ESMF_KIND_R8
    real(ESMF_KIND_R8) :: vmax     = 0.0_ESMF_KIND_R8
    real(ESMF_KIND_R8) :: vfill    = 0.0_ESMF_KIND_R8
    integer            :: max_iter = 15
    !> Se a fração inicial de pontos inválidos passar deste limiar, a
    !! difusão é pulada e todos os inválidos recebem vfill (1.0 = nunca pula).
    real(ESMF_KIND_R8) :: skip_fraction = 0.25_ESMF_KIND_R8
    !> Valores acima de vmax recebem vfill antes da difusão.
    logical            :: overflow_to_fill = .false.
  end type regrid_fill_t

  !> Descrição completa de uma interpolação.
  type :: regrid_spec_t
    !> Esquema registrado em regrid_registry_mod ('esmf', 'weights_file', 'mpassit').
    character(len=NAME_LEN) :: scheme = 'esmf'
    !> Métodos em ordem de preferência; o primeiro que funcionar é usado.
    !! Valores: 'bilinear', 'conserve', 'conserve_2nd', 'patch',
    !! 'nearest_stod', 'nearest_dtos'.
    character(len=NAME_LEN) :: methods(MAX_METHODS) = ''
    !> Ignora na origem os pontos com máscara 0 (terra, no oceano).
    logical :: mask_src = .false.
    !> Zera todo o destino antes de interpolar (.true.) ou só os pontos
    !! alcançados pela interpolação (.false., preserva o valor anterior).
    logical :: zero_total = .true.
    !> Arquivo de pesos (esquema 'weights_file').
    character(len=256) :: weights_file = ''
    !> Classe do campo (esquema 'mpassit'): 'continuous', 'integer', 'accumulated'.
    character(len=NAME_LEN) :: field_class = 'continuous'
    !> Preenchimento por vizinhança (etapa completar), depois da
    !! interpolação. Aplicado por regrid_manager%apply. No esquema
    !! 'mpassit', fill%vfill é também o valor de ausência.
    type(regrid_fill_t) :: fill
    !> Troca NaN no destino por nan_value depois da interpolação e do
    !! preenchimento por vizinhança. Aplicado por regrid_manager%apply.
    logical :: nan_replace = .false.
    real(ESMF_KIND_R8) :: nan_value = 0.0_ESMF_KIND_R8
  end type regrid_spec_t

  !> Esquema de interpolação.
  type, abstract :: regridder_t
    character(len=NAME_LEN) :: label = ''     !< nome da rota, para o log
    type(regrid_spec_t)     :: spec
    character(len=NAME_LEN) :: method_used = ''
    logical                 :: ready = .false.
  contains
    procedure(setup_i),   deferred :: setup
    procedure(execute_i), deferred :: execute
    procedure(release_i), deferred :: release
    procedure, non_overridable     :: apply
  end type regridder_t

  abstract interface
    subroutine setup_i(this, src, dst, rc)
      import :: regridder_t, ESMF_Field
      class(regridder_t), intent(inout) :: this
      type(ESMF_Field),   intent(inout) :: src, dst
      integer,            intent(out)   :: rc
    end subroutine setup_i

    subroutine execute_i(this, src, dst, zero_total, rc)
      import :: regridder_t, ESMF_Field
      class(regridder_t), intent(inout) :: this
      type(ESMF_Field),   intent(inout) :: src, dst
      logical,            intent(in)    :: zero_total
      integer,            intent(out)   :: rc
    end subroutine execute_i

    subroutine release_i(this, rc)
      import :: regridder_t
      class(regridder_t), intent(inout) :: this
      integer,            intent(out)   :: rc
    end subroutine release_i
  end interface

contains

  !> Interpola src -> dst. zero_total, se presente, substitui
  !! spec%zero_total nesta chamada. O preenchimento por vizinhança
  !! (spec%fill) é feito por regrid_manager%apply, com as opções da rota
  !! pedida, mesmo quando ela usa a interpolação da reserva.
  subroutine apply(this, src, dst, rc, zero_total)
    class(regridder_t), intent(inout) :: this
    type(ESMF_Field),   intent(inout) :: src, dst
    integer,            intent(out)   :: rc
    logical, optional,  intent(in)    :: zero_total

    if (.not. this%ready) then
      call ESMF_LogWrite('regrid: rota '//trim(this%label)//' usada antes do setup', &
        ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    if (present(zero_total)) then
      call this%execute(src, dst, zero_total, rc)
    else
      call this%execute(src, dst, this%spec%zero_total, rc)
    end if
  end subroutine apply

  !> Preenchimento por vizinhança de um campo 2D local (sem troca de halo:
  !! cada PET enxerga apenas os seus pontos).
  !! n_left (opcional) devolve quantos pontos receberam o valor fixo vfill;
  !! n_invalid (opcional), quantos estavam fora da faixa válida antes do
  !! preenchimento (depois de NaN e, com overflow_to_fill, valores acima de
  !! vmax tratados). Os dois só contam: não mudam o preenchimento.
  subroutine neighbor_fill(arr, opt, n_left, n_invalid)
    real(ESMF_KIND_R8),  intent(inout) :: arr(:,:)
    type(regrid_fill_t), intent(in)    :: opt
    integer, optional,   intent(out)   :: n_left
    integer, optional,   intent(out)   :: n_invalid

    real(ESMF_KIND_R8), allocatable :: tmp(:,:)
    logical,            allocatable :: valid(:,:)
    real(ESMF_KIND_R8) :: acc
    integer :: ni, nj, i, j, ii, jj, it, nbr

    if (present(n_left)) n_left = 0
    if (present(n_invalid)) n_invalid = 0
    ni = size(arr, 1); nj = size(arr, 2)
    if (ni * nj == 0) return

    if (opt%overflow_to_fill) where (arr > opt%vmax) arr = opt%vfill
    where (arr /= arr) arr = opt%vmin - 1.0_ESMF_KIND_R8   ! NaN -> inválido

    allocate(valid(ni, nj))
    valid = (arr >= opt%vmin .and. arr <= opt%vmax)
    if (present(n_invalid)) n_invalid = count(.not. valid)

    if (real(count(.not. valid), ESMF_KIND_R8) / real(ni*nj, ESMF_KIND_R8) > &
        opt%skip_fraction) then
      if (present(n_left)) n_left = count(.not. valid)
      where (.not. valid) arr = opt%vfill
      call ESMF_LogWrite('regrid: fracao de pontos invalidos acima do limiar; ' // &
        'difusao pulada, valor de preenchimento aplicado', ESMF_LOGMSG_WARNING)
      return
    end if

    allocate(tmp(ni, nj))
    do it = 1, opt%max_iter
      if (all(valid)) exit
      tmp = arr
      do j = 1, nj
        do i = 1, ni
          if (valid(i,j)) cycle
          acc = 0.0_ESMF_KIND_R8; nbr = 0
          do jj = max(1, j-1), min(nj, j+1)
            do ii = max(1, i-1), min(ni, i+1)
              if (valid(ii,jj)) then
                acc = acc + arr(ii,jj); nbr = nbr + 1
              end if
            end do
          end do
          if (nbr > 0) tmp(i,j) = acc / real(nbr, ESMF_KIND_R8)
        end do
      end do
      arr = tmp
      valid = (arr >= opt%vmin .and. arr <= opt%vmax)
    end do
    if (present(n_left)) n_left = count(.not. valid)
    where (.not. valid) arr = opt%vfill
  end subroutine neighbor_fill

end module regrid_base_mod
