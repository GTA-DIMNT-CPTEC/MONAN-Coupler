!> @file coupler_utils.F90
!! @brief Utilitários de uso geral do acoplador MONAN-Coupler.
!!
!! Pequenas rotinas usadas em vários módulos:
!!   ChkErr      verificação de código de retorno ESMF (uma linha por chamada)
!!   int_to_str  inteiro para texto, sem espaços
!!   real_to_str real para texto no formato F8.4, sem espaços
!!   str_lower   conversão de texto para minúsculas (ASCII)
!!
!! Uso típico:
!!   call ESMF_FieldGet(field, farrayPtr=ptr, rc=rc)
!!   if (ChkErr(rc, __LINE__, __FILE__)) return
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module coupler_utils_mod

  use, intrinsic :: iso_fortran_env, only : real64
  use ESMF, only : ESMF_LogFoundError, ESMF_LOGERR_PASSTHRU

  implicit none
  private

  public :: ChkErr
  public :: int_to_str
  public :: real_to_str
  public :: str_lower

contains

  !> @brief Retorna .true. se rc indica erro. O erro é registrado no log do ESMF
  !! com a linha e o arquivo de origem, e o chamador deve apenas retornar.
  logical function ChkErr(rc, line, file)
    integer,          intent(in) :: rc
    integer,          intent(in) :: line
    character(len=*), intent(in) :: file

    ChkErr = ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
                                line=line, file=file)
  end function ChkErr

  !> @brief Converte um inteiro em texto sem espaços (ex.: 42 -> '42').
  pure function int_to_str(n) result(s)
    integer, intent(in)           :: n
    character(len=:), allocatable :: s
    character(len=24) :: buf

    write(buf, '(I0)') n
    s = trim(buf)
  end function int_to_str

  !> @brief Converte um real em texto no formato F8.4, sem espaços.
  pure function real_to_str(x) result(s)
    real(real64), intent(in)      :: x
    character(len=:), allocatable :: s
    character(len=24) :: buf

    write(buf, '(F8.4)') x
    s = trim(adjustl(buf))
  end function real_to_str

  !> @brief Converte o texto para minúsculas, no próprio argumento (ASCII).
  pure subroutine str_lower(s)
    character(len=*), intent(inout) :: s
    integer :: i, c

    do i = 1, len_trim(s)
      c = iachar(s(i:i))
      if (c >= iachar('A') .and. c <= iachar('Z')) s(i:i) = achar(c + 32)
    end do
  end subroutine str_lower

end module coupler_utils_mod
