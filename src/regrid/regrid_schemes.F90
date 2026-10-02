!> @file regrid_schemes.F90
!! @brief Lista dos esquemas de interpolação do acoplador.
!!
!! Uma linha por esquema: o nome (o que se escreve na coluna esquema de
!! ROUTES, em src/coupling/cpl_map.F90, ou em regrid_scheme no grupo
!! &nuopc_regrid do nuopc.input) e o construtor, exportado pelo módulo do
!! esquema. Para acrescentar um esquema: um arquivo em src/regrid/ (o modelo
!! é regrid_idw.F90) e uma linha aqui. O registro (regrid_registry.F90) lê
!! esta lista na primeira consulta; um programa pode ainda registrar
!! esquemas próprios com regrid_register, como os testes de tests/regrid.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_schemes_mod

  use regrid_base_mod,    only : regridder_ctor
  use regrid_esmf_mod,    only : new_esmf
  use regrid_weights_mod, only : new_weights
  use regrid_mpassit_mod, only : new_mpassit
  use regrid_idw_mod,     only : new_idw

  implicit none
  private

  public :: regrid_coupler_schemes

  abstract interface
    !> Registra um esquema (regrid_register, de regrid_registry).
    subroutine register_iface(name, ctor, rc)
      import :: regridder_ctor
      character(len=*), intent(in)  :: name
      procedure(regridder_ctor)     :: ctor
      integer,          intent(out) :: rc
    end subroutine register_iface
  end interface

contains

  !> Entrega cada esquema da lista a registra, na ordem da lista; para no
  !! primeiro que falhar (rc dele).
  subroutine regrid_coupler_schemes(register, rc)
    procedure(register_iface) :: register
    integer, intent(out)  :: rc

    call register('esmf',         new_esmf,    rc)
    if (rc /= 0) return
    call register('weights_file', new_weights, rc)
    if (rc /= 0) return
    call register('mpassit',      new_mpassit, rc)
    if (rc /= 0) return
    call register('idw',          new_idw,     rc)
  end subroutine regrid_coupler_schemes

end module regrid_schemes_mod
