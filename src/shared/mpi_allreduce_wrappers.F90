!> @file mpi_allreduce_wrappers.F90
!! @brief Wrappers fortemente tipadas para MPI_Allreduce (MPI_SUM).
!!
!! Motivação (W1-FIX v12.0):
!!   MPI_Allreduce tem interface implícita via 'use mpi' (declarações
!!   EXTERNAL do padrão MPI-2). O backend gfortran do Cray ftn compara
!!   os tipos de sendbuf/recvbuf entre TODAS as chamadas ao mesmo símbolo
!!   externo visíveis no arquivo de compilação. Ter allreduce_r8 (REAL(8))
!!   e allreduce_i4 (INTEGER(4)) no mesmo arquivo — ou no mesmo módulo —
!!   faz o compilador cruzar os tipos e emitir type-mismatch espúrio, mesmo
!!   que cada chamada individualmente esteja correta.
!!
!!   -Wno-argument-mismatch não suprime esse aviso: ele é gerado pela
!!   análise de consistência de interface, não pela verificação de argumentos.
!!
!!   Solução (v12.0): separar as duas subrotinas em MÓDULOS DISTINTOS,
!!   cada um em seu próprio arquivo de compilação (.F90). O compilador
!!   analisa cada arquivo em escopo fechado, sem visibilidade cruzada.
!!   A semântica MPI é idêntica à chamada direta original.
!!
!!   Este arquivo contém apenas o módulo de encaminhamento público que
!!   re-exporta allreduce_r8 e allreduce_i4 para compatibilidade com o
!!   código existente (sem alterar nenhum 'use mpi_allreduce_wrappers_mod').
!!
!! Uso (inalterado):
!!   use mpi_allreduce_wrappers_mod, only : allreduce_r8, allreduce_i4
!!   call allreduce_r8(sendbuf, recvbuf, n, comm, ierr)
!!   call allreduce_i4(sendbuf, recvbuf, n, comm, ierr)
!!
!! Módulos internos (cada um em seu arquivo):
!!   mpi_allreduce_r8_mod  →  mpi_allreduce_r8.F90
!!   mpi_allreduce_i4_mod  →  mpi_allreduce_i4.F90
!!
!! INPE / CGCT / DIMNT — GT Acoplamento de Modelos — v12.0 (Maio 2026)

module mpi_allreduce_wrappers_mod

  use mpi_allreduce_r8_mod, only : allreduce_r8
  use mpi_allreduce_i4_mod, only : allreduce_i4

  implicit none
  private

  public :: allreduce_r8, allreduce_i4

end module mpi_allreduce_wrappers_mod
