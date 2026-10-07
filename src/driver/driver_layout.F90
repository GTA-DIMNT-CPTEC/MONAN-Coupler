!> @file driver_layout.F90
!! @brief Posições do acoplamento no driver e divisão dos PETs entre elas.
!!
!! Uma posição é um papel no acoplamento (atmosfera, mediador, oceano,
!! gelo), ocupado por um modelo escolhido pela configuração (esm.F90). A
!! tabela POSITIONS dá, na ordem em que o driver registra os componentes:
!!   name        nome da posição, o mesmo das linhas de layout do log
!!   own_block   no layout split, a posição tem um bloco próprio de PETs
!!               (o mediador fica em todos os PETs)
!!   rest_order  quem recebe o resto da divisão automática: entre as
!!               posições com contagem automática, a de menor número fica
!!               com o que sobra, e as demais com a parte inteira
!!
!! Divisão no layout split (split_blocks): cada posição ativa com bloco
!! próprio recebe a contagem pedida no nuopc.input (atm_pet_count,
!! ocn_pet_count, ice_pet_count); contagem zero é automática, e os PETs que
!! sobram são divididos entre as automáticas. Os blocos vêm em seguida, na
!! ordem de POSITIONS. A ordem de rest_order reproduz a regra anterior a
!! esta tabela: com o gelo automático, ele fica com o resto; sem ele, o ATM.
!!
!! As linhas de layout do log (layout_split_line, layout_shared_line,
!! idle_pets_line) são lidas por ferramentas de tools/coupler e tools/dev:
!! não alterar o texto sem ajustá-las.
!!
!! Este módulo não usa o ESMF: o teste tests/unit/test_driver_layout.F90 o
!! confere sem o driver.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module driver_layout_mod

  use coupler_utils_mod, only : int_to_str

  implicit none
  private

  public :: position_t, POSITIONS, N_POSITIONS, position_index
  public :: split_blocks, layout_split_line, layout_shared_line, idle_pets_line

  !> Posição do acoplamento no driver.
  type :: position_t
    character(len=4) :: name
    logical          :: own_block
    integer          :: rest_order
  end type position_t

  integer, parameter :: N_POSITIONS = 4
  type(position_t), parameter :: POSITIONS(N_POSITIONS) = [  &
    !           name   own_block  rest_order
    position_t('ATM',  .true.,    2),                        &
    position_t('MED',  .false.,   0),                        &
    position_t('OCN',  .true.,    3),                        &
    position_t('ICE',  .true.,    1) ]

contains

  !> @brief Índice da posição em POSITIONS (0 se não existe).
  !!
  !! @param[in] name  nome da posição ('ATM', 'MED', 'OCN', 'ICE')
  pure integer function position_index(name) result(k)
    character(len=*), intent(in) :: name
    do k = 1, N_POSITIONS
      if (trim(POSITIONS(k)%name) == trim(name)) return
    end do
    k = 0
  end function position_index

  !> @brief Tamanho do bloco de PETs de cada posição no layout split.
  !!
  !! @param[in]  petCount   PETs do driver
  !! @param[in]  requested  contagem pedida por posição (0 = automática)
  !! @param[in]  active     posição ativa nesta configuração
  !! @param[out] counts     PETs de cada posição; 0 para as sem bloco
  !!                        próprio ou inativas
  !! @param[out] ok         divisão válida: toda posição ativa com bloco tem
  !!                        ao menos um PET, e os blocos somam petCount
  pure subroutine split_blocks(petCount, requested, active, counts, ok)
    integer, intent(in)  :: petCount
    integer, intent(in)  :: requested(N_POSITIONS)
    logical, intent(in)  :: active(N_POSITIONS)
    integer, intent(out) :: counts(N_POSITIONS)
    logical, intent(out) :: ok
    logical :: block(N_POSITIONS), auto(N_POSITIONS)
    integer :: k, n_auto, rest, last, share

    block = POSITIONS%own_block .and. active
    counts = 0
    where (block) counts = requested
    auto = block .and. counts <= 0
    n_auto = count(auto)
    if (n_auto > 0) then
      rest = petCount - sum(counts, mask=block .and. .not. auto)
      share = rest / n_auto
      last = 0
      do k = 1, N_POSITIONS
        if (.not. auto(k)) cycle
        counts(k) = share
        if (last == 0) then
          last = k
        else if (POSITIONS(k)%rest_order < POSITIONS(last)%rest_order) then
          last = k
        end if
      end do
      counts(last) = rest - share * (n_auto - 1)
    end if
    ok = all(counts >= 1 .or. .not. block) .and. sum(counts) == petCount
  end subroutine split_blocks

  !> @brief Linha do log do layout split, com a faixa de PETs de cada bloco.
  !!
  !! @param[in] exec    'CONCURRENT' ou 'SEQUENTIAL'
  !! @param[in] counts  PETs de cada posição (split_blocks)
  !! @param[in] active  posição ativa nesta configuração
  pure function layout_split_line(exec, counts, active) result(msg)
    character(len=*), intent(in) :: exec
    integer,          intent(in) :: counts(N_POSITIONS)
    logical,          intent(in) :: active(N_POSITIONS)
    character(len=:), allocatable :: msg
    integer :: k, first

    msg = 'layout SPLIT (execucao '//exec//'):'
    first = 0
    do k = 1, N_POSITIONS
      if (.not. (POSITIONS(k)%own_block .and. active(k))) cycle
      msg = msg//' '//trim(POSITIONS(k)%name)//'=PET['//int_to_str(first)//'..'// &
            int_to_str(first + counts(k) - 1)//']'
      first = first + counts(k)
    end do
    msg = msg//' MED=todos'
    do k = 1, N_POSITIONS
      if (POSITIONS(k)%own_block .and. .not. active(k)) &
        msg = msg//' ('//trim(POSITIONS(k)%name)//' desativado)'
    end do
  end function layout_split_line

  !> @brief Linha do log do layout shared: os rótulos dos componentes, todos em
  !! todos os PETs.
  !!
  !! @param[in] exec    'CONCURRENT' ou 'SEQUENTIAL'
  !! @param[in] labels  rótulos dos componentes registrados, na ordem
  pure function layout_shared_line(exec, labels) result(msg)
    character(len=*), intent(in) :: exec
    character(len=*), intent(in) :: labels(:)
    character(len=:), allocatable :: msg
    integer :: k, n

    n = size(labels)
    msg = trim(labels(1))
    do k = 2, n
      if (k == n) then
        msg = msg//' e '//trim(labels(k))
      else
        msg = msg//', '//trim(labels(k))
      end if
    end do
    msg = 'layout SHARED (execucao '//exec//'): '//msg//' em todos os PETs'
  end function layout_shared_line

  !> @brief Linha do log com os PETs parados em cada fase do sequential+split.
  !!
  !! @param[in] petCount  PETs do driver
  !! @param[in] counts    PETs de cada posição (split_blocks)
  !! @param[in] active    posição ativa nesta configuração
  pure function idle_pets_line(petCount, counts, active) result(msg)
    integer, intent(in) :: petCount
    integer, intent(in) :: counts(N_POSITIONS)
    logical, intent(in) :: active(N_POSITIONS)
    character(len=:), allocatable :: msg
    character(len=:), allocatable :: sep
    integer :: k

    msg = 'sequential+split: PETs parados:'
    sep = ' '
    do k = 1, N_POSITIONS
      if (.not. (POSITIONS(k)%own_block .and. active(k))) cycle
      msg = msg//sep//int_to_str(petCount - counts(k))//' durante o '//trim(POSITIONS(k)%name)
      sep = ', '
    end do
    msg = msg//' (de '//int_to_str(petCount)//').'
  end function idle_pets_line

end module driver_layout_mod
