!> @file mpi_allreduce_i4.F90
!! @brief Wrapper MPI_Allreduce para INTEGER(4) — arquivo de compilação isolado.
!!
!! Isolado em arquivo próprio para que o compilador não cruze os tipos
!! de sendbuf/recvbuf com a variante REAL(8) (mpi_allreduce_r8.F90).
!! Ver mpi_allreduce_wrappers.F90 para a motivação completa.
!!
!! INPE / CGCT / DIMNT — GT Acoplamento de Modelos — v12.0 (Maio 2026)

module mpi_allreduce_i4_mod

  use mpi

  implicit none
  private

  public :: allreduce_i4

contains

  !> Redução global MPI_SUM para arrays INTEGER(4).
  !! @param[in]  sendbuf  Array de envio (INTEGER(4), qualquer rank linearizado)
  !! @param[out] recvbuf  Array de recepção (INTEGER(4))
  !! @param[in]  count    Número de elementos
  !! @param[in]  comm     Comunicador MPI
  !! @param[out] ierr     Código de retorno MPI
  subroutine allreduce_i4(sendbuf, recvbuf, count, comm, ierr)
    integer, intent(in)  :: sendbuf(*)
    integer, intent(out) :: recvbuf(*)
    integer, intent(in)  :: count
    integer, intent(in)  :: comm
    integer, intent(out) :: ierr
    call MPI_Allreduce(sendbuf, recvbuf, count, &
                       MPI_INTEGER, MPI_SUM, comm, ierr)
  end subroutine allreduce_i4

end module mpi_allreduce_i4_mod
