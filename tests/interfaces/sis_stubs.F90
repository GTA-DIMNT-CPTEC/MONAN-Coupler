! Interfaces minimas do SIS2 usadas por sis_cap_MONAN.F90, alem das do
! MOM6/FMS em mom_stubs.F90. Servem so para conferir a compilacao fora da
! Jaci (tipos, componentes, assinaturas e intent); nao executam nada. Usadas
! por tools/dev/compila-local.bash. Os componentes dos tipos sao so os que o
! cap usa, com a forma (ponteiro ou nao, posto) e o kind do SIS2 compilado
! com -fdefault-real-8. Ao alterar o cap, confira antes que a versao anterior
! compila com elas; se nao compilar, ajuste aqui seguindo o fonte real em
! models/ocean/MOM6-examples/src/SIS2/src (ice_model.F90, ice_type.F90,
! ice_boundary_types.F90, SIS_types.F90, SIS_hor_grid.F90).
module MOM_diag_manager_infra
  use MOM_time_manager, only : time_type
  implicit none
contains
  subroutine diag_manager_set_time_end_infra(time_end_in)
    type(time_type), optional, intent(in) :: time_end_in
  end subroutine
end module

module sis_stub_types
  use MOM_domains, only : MOM_domain_type, BGRID_NE
  implicit none

  type :: SIS_hor_grid_type
    type(MOM_domain_type), pointer :: Domain => null()
    integer :: isc = 1, iec = 1, jsc = 1, jec = 1
  end type

  type :: ice_state_type
    real(8), allocatable :: part_size(:,:,:)
  end type

  type :: SIS_slow_CS
    type(SIS_hor_grid_type), pointer :: G => null()
    type(ice_state_type),    pointer :: IST => null()
  end type

  type :: SIS_fast_CS
    type(ice_state_type), pointer :: IST => null()
  end type

  type :: ice_data_type
    logical :: pe = .false., slow_ice_pe = .false., fast_ice_pe = .false.
    integer, pointer :: slow_pelist(:) => null(), fast_pelist(:) => null()
    real(8), pointer :: part_size(:,:,:) => null()
    real(8), pointer :: albedo_vis_dir(:,:,:) => null(), albedo_vis_dif(:,:,:) => null()
    real(8), pointer :: albedo_nir_dir(:,:,:) => null(), albedo_nir_dif(:,:,:) => null()
    real(8), pointer :: t_surf(:,:,:) => null()
    type(SIS_slow_CS), pointer :: sCS => null()
    type(SIS_fast_CS), pointer :: fCS => null()
  end type

  type :: ocean_ice_boundary_type
    real(8), pointer :: u(:,:) => null(), v(:,:) => null(), t(:,:) => null()
    real(8), pointer :: s(:,:) => null(), frazil(:,:) => null(), sea_level(:,:) => null()
    real(8), pointer :: calving(:,:) => null(), calving_hflx(:,:) => null()
    integer :: stagger = BGRID_NE
  end type

  type :: atmos_ice_boundary_type
    real(8), pointer :: u_flux(:,:,:) => null(), v_flux(:,:,:) => null()
    real(8), pointer :: u_star(:,:,:) => null(), t_flux(:,:,:) => null()
    real(8), pointer :: q_flux(:,:,:) => null(), lw_flux(:,:,:) => null()
    real(8), pointer :: sw_flux_vis_dir(:,:,:) => null(), sw_flux_vis_dif(:,:,:) => null()
    real(8), pointer :: sw_flux_nir_dir(:,:,:) => null(), sw_flux_nir_dif(:,:,:) => null()
    real(8), pointer :: lprec(:,:,:) => null(), fprec(:,:,:) => null()
    real(8), pointer :: dhdt(:,:,:) => null(), dedt(:,:,:) => null(), drdt(:,:,:) => null()
    real(8), pointer :: coszen(:,:,:) => null(), p(:,:,:) => null()
  end type
end module

module ice_model_mod
  use MOM_time_manager, only : time_type
  use sis_stub_types, only : ice_data_type, ocean_ice_boundary_type, atmos_ice_boundary_type
  implicit none
  private
  public :: ice_data_type, ocean_ice_boundary_type, atmos_ice_boundary_type
  public :: ice_model_init, ice_model_end, share_ice_domains, ice_model_restart
  public :: update_ice_slow_thermo, update_ice_dynamics_trans
  public :: unpack_ocean_ice_boundary, update_ice_model_fast
  public :: exchange_slow_to_fast_ice, set_ice_surface_fields
contains
  subroutine ice_model_init(Ice, Time_Init, Time, Time_step_fast, Time_step_slow, &
                            Verona_coupler, Concurrent_ice)
    type(ice_data_type), intent(inout) :: Ice
    type(time_type),     intent(in)    :: Time_Init, Time, Time_step_fast, Time_step_slow
    logical, optional,   intent(in)    :: Verona_coupler, Concurrent_ice
  end subroutine
  subroutine ice_model_end(Ice)
    type(ice_data_type), intent(inout) :: Ice
  end subroutine
  subroutine share_ice_domains(Ice)
    type(ice_data_type), intent(inout) :: Ice
  end subroutine
  subroutine ice_model_restart(Ice, time_stamp)
    type(ice_data_type),        intent(inout) :: Ice
    character(len=*), optional, intent(in)    :: time_stamp
  end subroutine
  subroutine update_ice_slow_thermo(Ice)
    type(ice_data_type), intent(inout) :: Ice
  end subroutine
  subroutine update_ice_dynamics_trans(Ice, time_step, start_cycle, end_cycle, cycle_length)
    type(ice_data_type),       intent(inout) :: Ice
    type(time_type), optional, intent(in)    :: time_step
    logical, optional,         intent(in)    :: start_cycle, end_cycle
    real(8), optional,         intent(in)    :: cycle_length
  end subroutine
  subroutine unpack_ocean_ice_boundary(OIB, Ice)
    type(ocean_ice_boundary_type), intent(inout) :: OIB
    type(ice_data_type),           intent(inout) :: Ice
  end subroutine
  subroutine update_ice_model_fast(Atmos_boundary, Ice)
    type(atmos_ice_boundary_type), intent(inout) :: Atmos_boundary
    type(ice_data_type),           intent(inout) :: Ice
  end subroutine
  subroutine exchange_slow_to_fast_ice(Ice)
    type(ice_data_type), intent(inout) :: Ice
  end subroutine
  subroutine set_ice_surface_fields(Ice)
    type(ice_data_type), intent(inout) :: Ice
  end subroutine
end module
