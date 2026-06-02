!> @file ocn_comp_NUOPC.F90
!! @brief Módulo ponte para o cap NUOPC do oceano (MOM6+SIS2).
!!
!! Este módulo re-exporta SetServices de MOM_cap_MONAN_mod sob o nome
!! genérico ocn_comp_NUOPC, permitindo que drivers externos ao repositório
!! se conectem ao oceano sem depender diretamente de MOM_cap_MONAN_mod.
!!
!! Uso em driver externo:
!!   use ocn_comp_NUOPC, only: OCN_SetServices => SetServices
!!   call NUOPC_DriverAddComp(driver, compLabel="OCN", &
!!        compSetServicesRoutine=OCN_SetServices, ...)
!!
!! Nota: este arquivo NÃO está listado em ALL_OBJS do Makefile principal.
!!   O driver esm.F90 usa MOM_cap_MONAN_mod diretamente.
!!
!! INPE / CGCT / DIMNT — GT Acoplamento de Modelos — Maio 2026.

module ocn_comp_NUOPC

  ! Fase 2: usar MOM_cap_MONAN_mod (wrapper com fases NUOPC completas)
  ! em vez de MOM_cap_mod (SetServices do Projeto B, sem modificação).
  use MOM_cap_MONAN_mod, only: SetServices

  implicit none
  private

  !> Ponto de entrada público do componente oceânico MOM6+SIS2.
  !! Registra todas as fases NUOPC (InitializeP0, AdvertiseFields,
  !! RealizeFields, DataInitialize, ModelAdvance, Finalize).
  !! Fase 2: acoplamento dinâmico real com MOM6+SIS2 via MOM_cap_MONAN_mod.
  public :: SetServices

end module ocn_comp_NUOPC
