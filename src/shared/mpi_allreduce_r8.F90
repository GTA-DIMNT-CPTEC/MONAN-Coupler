!> @file mpi_allreduce_r8.F90
!! @brief Wrapper MPI_Allreduce para REAL(8) — arquivo de compilação isolado.
!!
!! Isolado em arquivo próprio para que o compilador não cruze os tipos
!! de sendbuf/recvbuf com a variante INTEGER(4) (mpi_allreduce_i4.F90).
!! Ver mpi_allreduce_wrappers.F90 para a motivação completa.
!!
!! INPE / CGCT / DIMNT — GT Acoplamento de Modelos — v12.0 (Maio 2026)

module mpi_allreduce_r8_mod

  use mpi
  use ESMF, only : ESMF_KIND_R8

  implicit none
  private

  public :: allreduce_r8

contains

  !> Redução global MPI_SUM para arrays REAL(8) (double precision).
  !! @param[in]  sendbuf  Array de envio (REAL(8), qualquer rank linearizado)
  !! @param[out] recvbuf  Array de recepção (REAL(8))
  !! @param[in]  count    Número de elementos
  !! @param[in]  comm     Comunicador MPI
  !! @param[out] ierr     Código de retorno MPI
  subroutine allreduce_r8(sendbuf, recvbuf, count, comm, ierr)
    real(ESMF_KIND_R8), intent(in)  :: sendbuf(*)
    real(ESMF_KIND_R8), intent(out) :: recvbuf(*)
    integer,            intent(in)  :: count
    integer,            intent(in)  :: comm
    integer,            intent(out) :: ierr
    call MPI_Allreduce(sendbuf, recvbuf, count, &
                       MPI_DOUBLE_PRECISION, MPI_SUM, comm, ierr)
  end subroutine allreduce_r8

end module mpi_allreduce_r8_mod
