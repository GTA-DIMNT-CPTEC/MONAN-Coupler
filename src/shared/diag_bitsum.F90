!> @file diag_bitsum.F90
!! @brief Soma de verificação exata, por PET, de campos reais (diagnóstico de
!! reprodutibilidade bit a bit).
!!
!! Por quê: os diagnósticos "DIAG ice_fraction source" e "destination"
!! (med_diag) escrevem 17 algarismos, precisão suficiente, mas só do PET 0.
!! Uma diferença de 1 ulp fora da fatia do PET 0 (como as que já apareceram
!! no Si_ifrac recebido pelo MPAS) não aparece neles; esta soma, gravada em
!! cada PET, a mostra.
!!
!! Como: cada valor é lido como inteiro de 64 bits (transfer), separado em
!! duas metades de 32 bits, e as metades são somadas em inteiro. Soma de
!! inteiros é exata e não depende da ordem: o resultado só muda se algum
!! bit de algum ponto mudar.
!!
!! Não há redução entre PETs: no MediatorAdvance, os PETs sem pedaço da
!! grade atmosférica retornam cedo (bloco localDeCount_med == 0), e uma
!! chamada coletiva depois desse ponto travaria o job. Cada PET grava a sua
!! parte no próprio log (logs/PETnn.esmApp.log), e o mede-taxa-repro.sh
!! junta as linhas de todos os PETs; a diferença aparece, assim, localizada
!! por PET, isto é, por região do domínio.
!!
!! Limites:
!!  - seguro até 2**31 pontos por pedaço (cada metade < 2**32);
!!  - não detecta dois pontos que TROCAM de valor entre si (entre execuções
!!    com a mesma decomposição, isso não ocorre na prática).
!!
!! Saída: uma linha de depuração (log_debug, só com log_level='debug') por
!! chamada, no log de cada PET que chega ao ponto:
!!   <comp>: DIAG <rótulo> n=<pontos> hi=<soma alta> lo=<soma baixa>
!! com " ERRO=<k>" no fim se algum pedaço local não pode ser lido. O chamador
!! dá a marca do componente (COMP_* de coupler_log_mod) e o rótulo.

module diag_bitsum_mod

  use, intrinsic :: iso_fortran_env, only: int64, real64
  use ESMF
  use coupler_log_mod, only: log_debug

  implicit none
  private

  public :: diag_bitsum_log

  interface diag_bitsum_log
    module procedure bitsum_log_1d
    module procedure bitsum_log_2d
    module procedure bitsum_log_field
  end interface diag_bitsum_log


contains

  !> @brief Acumula contagem e as duas somas de 32 bits de um trecho contíguo.
  pure subroutine accumulate(x, n, s_hi, s_lo)
    real(real64),   intent(in)    :: x(:)
    integer(int64), intent(inout) :: n, s_hi, s_lo

    integer(int64), parameter :: MASK32 = int(z'FFFFFFFF', int64)
    integer(int64) :: b
    integer        :: i

    do i = 1, size(x)
      b    = transfer(x(i), b)
      s_lo = s_lo + iand(b, MASK32)
      s_hi = s_hi + iand(shiftr(b, 32), MASK32)
    end do
    n = n + size(x, kind=int64)
  end subroutine accumulate

  !> @brief Acumula contagem e somas de um arranjo 2D, coluna a coluna.
  pure subroutine accumulate_2d(x, n, s_hi, s_lo)
    real(real64),   intent(in)    :: x(:,:)
    integer(int64), intent(inout) :: n, s_hi, s_lo
    integer :: j
    do j = 1, size(x, 2)
      call accumulate(x(:, j), n, s_hi, s_lo)
    end do
  end subroutine accumulate_2d

  !> @brief Grava a linha no log deste PET.
  subroutine write_sum(comp, label, n, s_hi, s_lo, n_err)
    character(len=*), intent(in) :: comp
    character(len=*), intent(in) :: label
    integer(int64),   intent(in) :: n, s_hi, s_lo
    integer,          intent(in) :: n_err

    character(len=512) :: msg

    if (n_err == 0) then
      write(msg, '("DIAG ",a," n=",i0," hi=",i0," lo=",i0)') &
            trim(label), n, s_hi, s_lo
    else
      write(msg, '("DIAG ",a," n=",i0," hi=",i0," lo=",i0," ERRO=",i0)') &
            trim(label), n, s_hi, s_lo, n_err
    end if
    call log_debug(comp, trim(msg))
  end subroutine write_sum

  !> @brief Grava a soma de um vetor real(8).
  subroutine bitsum_log_1d(comp, label, x, rc)
    character(len=*), intent(in)  :: comp
    character(len=*), intent(in)  :: label
    real(real64),     intent(in)  :: x(:)
    integer,          intent(out) :: rc
    integer(int64) :: n, s_hi, s_lo
    n = 0 ; s_hi = 0 ; s_lo = 0
    call accumulate(x, n, s_hi, s_lo)
    call write_sum(comp, label, n, s_hi, s_lo, 0)
    rc = ESMF_SUCCESS
  end subroutine bitsum_log_1d

  !> @brief Grava a soma de um arranjo 2D real(8).
  subroutine bitsum_log_2d(comp, label, x, rc)
    character(len=*), intent(in)  :: comp
    character(len=*), intent(in)  :: label
    real(real64),     intent(in)  :: x(:,:)
    integer,          intent(out) :: rc
    integer(int64) :: n, s_hi, s_lo
    n = 0 ; s_hi = 0 ; s_lo = 0
    call accumulate_2d(x, n, s_hi, s_lo)
    call write_sum(comp, label, n, s_hi, s_lo, 0)
    rc = ESMF_SUCCESS
  end subroutine bitsum_log_2d

  !> @brief ESMF_Field real(8) de posto 1 ou 2, com qualquer número de pedaços
  !! locais (localDeCount pode ser 0, 1 ou mais). Soma a região exclusiva.
  subroutine bitsum_log_field(comp, label, field, rc)
    character(len=*), intent(in)  :: comp
    character(len=*), intent(in)  :: label
    type(ESMF_Field), intent(in)  :: field
    integer,          intent(out) :: rc

    integer                  :: rank, ldec, lde, rc_loc, n_err
    type(ESMF_TypeKind_Flag) :: tk
    real(real64), pointer    :: p1(:), p2(:,:)
    integer(int64)           :: n, s_hi, s_lo

    n = 0 ; s_hi = 0 ; s_lo = 0 ; n_err = 0
    rank = 0 ; ldec = 0

    call ESMF_FieldGet(field, rank=rank, typekind=tk, localDeCount=ldec, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS) then
      n_err = n_err + 1
      ldec  = 0
    else if (tk /= ESMF_TYPEKIND_R8 .or. (rank /= 1 .and. rank /= 2)) then
      n_err = n_err + 1
      ldec  = 0
    end if

    do lde = 0, ldec - 1
      if (rank == 1) then
        nullify(p1)
        call ESMF_FieldGet(field, localDe=lde, farrayPtr=p1, rc=rc_loc)
        if (rc_loc == ESMF_SUCCESS .and. associated(p1)) then
          call accumulate(p1, n, s_hi, s_lo)
        else
          n_err = n_err + 1
        end if
      else
        nullify(p2)
        call ESMF_FieldGet(field, localDe=lde, farrayPtr=p2, rc=rc_loc)
        if (rc_loc == ESMF_SUCCESS .and. associated(p2)) then
          call accumulate_2d(p2, n, s_hi, s_lo)
        else
          n_err = n_err + 1
        end if
      end if
    end do

    call write_sum(comp, label, n, s_hi, s_lo, n_err)
    rc = ESMF_SUCCESS
  end subroutine bitsum_log_field

end module diag_bitsum_mod
