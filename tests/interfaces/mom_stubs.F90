! Interfaces minimas do MOM6 e do FMS usadas por mom_cap_MONAN.F90 e
! time_utils.F90. Servem so para conferir a compilacao fora da Jaci (tipos,
! assinaturas e intent); nao executam nada. Usadas por
! tools/dev/compila-local.bash. Ao alterar um desses fontes, confira antes que
! a versao anterior compila com elas; se nao compilar, ajuste a interface aqui,
! seguindo a assinatura real do MOM6/FMS.
module mpp_domains_mod
  implicit none
  type :: domain2D
    integer :: dummy
  end type
contains
  subroutine mpp_get_compute_domain(d, is, ie, js, je)
    type(domain2D), intent(in) :: d
    integer, intent(out) :: is, ie, js, je
    is=1; ie=0; js=1; je=0
  end subroutine
  subroutine mpp_get_global_domain(d, xsize, ysize)
    type(domain2D), intent(in) :: d
    integer, intent(out), optional :: xsize, ysize
  end subroutine
  subroutine mpp_get_compute_domains(d, xbegin, xend, ybegin, yend)
    type(domain2D), intent(in) :: d
    integer, intent(out), optional :: xbegin(:), xend(:), ybegin(:), yend(:)
  end subroutine
  integer function mpp_get_ntile_count(d)
    type(domain2D), intent(in) :: d
    mpp_get_ntile_count = 1
  end function
  integer function mpp_get_domain_npes(d)
    type(domain2D), intent(in) :: d
    mpp_get_domain_npes = 1
  end function
  subroutine mpp_get_pelist(d, pelist, pos)
    type(domain2D), intent(in) :: d
    integer, intent(out) :: pelist(:)
    integer, intent(out), optional :: pos
  end subroutine
end module

module mpp_mod
  implicit none
  interface mpp_max
    module procedure mpp_max_i
  end interface
contains
  subroutine mpp_max_i(a)
    integer, intent(inout) :: a
  end subroutine
end module

module MOM_time_manager
  implicit none
  integer, parameter :: GREGORIAN = 3
  type :: time_type
    integer :: s = 0
  end type
contains
  subroutine set_calendar_type(t)
    integer, intent(in) :: t
  end subroutine
  type(time_type) function set_date(y, m, d, h, mi, s)
    integer, intent(in) :: y, m, d, h, mi, s
    set_date%s = s
  end function
  type(time_type) function set_time(s, d)
    integer, intent(in) :: s
    integer, intent(in), optional :: d
    set_time%s = s
  end function
end module

module time_manager_mod
  use MOM_time_manager
end module

module MOM_domains
  use mpp_domains_mod
  implicit none
  type :: MOM_domain_type
    type(domain2D), pointer :: mpp_domain => null()
  end type
contains
  subroutine get_domain_extent(d, isc, iec, jsc, jec)
    type(MOM_domain_type), intent(in) :: d
    integer, intent(out) :: isc, iec, jsc, jec
  end subroutine
  subroutine MOM_infra_init(comm)
    integer, intent(in), optional :: comm
  end subroutine
  subroutine MOM_infra_end()
  end subroutine
  integer function pe_here()
    pe_here = 0
  end function
  subroutine pass_var(a, d)
    real(8), intent(inout) :: a(:,:)
    type(MOM_domain_type), intent(inout) :: d
  end subroutine
end module

module MOM_grid
  use MOM_domains
  implicit none
  type :: ocean_grid_type
    type(MOM_domain_type), pointer :: Domain => null()
    integer :: isc, iec, jsc, jec
    real(8), allocatable :: geoLonT(:,:), geoLatT(:,:), mask2dT(:,:), areaT(:,:)
  end type
contains
  subroutine get_global_grid_size(G, ni, nj)
    type(ocean_grid_type), intent(in) :: G
    integer, intent(out) :: ni, nj
  end subroutine
end module

module MOM_surface_forcing_nuopc
  implicit none
  type :: ice_ocean_boundary_type
    real, pointer, dimension(:,:) :: u_flux => null(), v_flux => null(), t_flux => null(), &
      q_flux => null(), salt_flux => null(), lw_flux => null(), sw_flux_vis_dir => null(), &
      sw_flux_vis_dif => null(), sw_flux_nir_dir => null(), sw_flux_nir_dif => null(), &
      lprec => null(), fprec => null(), seaice_melt_heat => null(), seaice_melt => null(), &
      mi => null(), ice_fraction => null(), u10_sqr => null(), p => null(), &
      lrunoff => null(), frunoff => null()
    integer :: ice_ncat = 0
  end type
end module

module MOM_ocean_model_nuopc
  use mpp_domains_mod
  use MOM_grid
  use MOM_time_manager
  use MOM_surface_forcing_nuopc
  implicit none
  type :: surface
    integer :: dummy
  end type
  type :: ocean_public_type
    type(domain2D) :: domain
    real(8), pointer, dimension(:,:) :: t_surf => null(), s_surf => null(), &
      u_surf => null(), v_surf => null(), frazil => null()
    logical :: is_ocean_pe = .false.
  end type
  type :: ocean_state_type
    type(surface) :: sfc_state
  end type
contains
  subroutine ocean_model_init(Ocean_sfc, OS, Time_init, Time_in)
    type(ocean_public_type), target, intent(inout) :: Ocean_sfc
    type(ocean_state_type), pointer :: OS
    type(time_type), intent(in) :: Time_init, Time_in
  end subroutine
  subroutine update_ocean_model(Ice_ocean_boundary, OS, Ocean_sfc, Time_start_update, &
                                Ocean_coupling_time_step, cesm_coupled)
    type(ice_ocean_boundary_type), intent(in) :: Ice_ocean_boundary
    type(ocean_state_type), pointer :: OS
    type(ocean_public_type), intent(inout) :: Ocean_sfc
    type(time_type), intent(in) :: Time_start_update, Ocean_coupling_time_step
    logical, intent(in), optional :: cesm_coupled
  end subroutine
  subroutine ocean_model_end(Ocean_sfc, Ocean_state, Time, write_restart)
    type(ocean_public_type), intent(inout) :: Ocean_sfc
    type(ocean_state_type), pointer :: Ocean_state
    type(time_type), intent(in) :: Time
    logical, intent(in), optional :: write_restart
  end subroutine
  subroutine ocean_model_restart(OS)
    type(ocean_state_type), pointer :: OS
  end subroutine
  subroutine ocean_model_init_sfc(OS, Ocean_sfc)
    type(ocean_state_type), pointer :: OS
    type(ocean_public_type), intent(inout) :: Ocean_sfc
  end subroutine
  subroutine ocean_model_flux_init(OS)
    type(ocean_state_type), pointer :: OS
  end subroutine
  subroutine get_ocean_grid(OS, Gridp)
    type(ocean_state_type) :: OS
    type(ocean_grid_type), pointer :: Gridp
  end subroutine
  real function get_eps_omesh(OS)
    type(ocean_state_type) :: OS
    get_eps_omesh = 0.
  end function
end module

module MOM_cap_methods
  use ESMF
  use MOM_ocean_model_nuopc
  implicit none
contains
  subroutine mom_import(ocean_public, ocean_grid, importState, ice_ocean_boundary, rc)
    type(ocean_public_type), intent(in) :: ocean_public
    type(ocean_grid_type), intent(in) :: ocean_grid
    type(ESMF_State), intent(inout) :: importState
    type(ice_ocean_boundary_type), intent(inout) :: ice_ocean_boundary
    integer, intent(inout) :: rc
  end subroutine
  subroutine mom_export(ocean_public, ocean_grid, ocean_state, exportState, clock, rc)
    type(ocean_public_type), intent(in) :: ocean_public
    type(ocean_grid_type), intent(in) :: ocean_grid
    type(ocean_state_type), intent(inout) :: ocean_state
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Clock), intent(in) :: clock
    integer, intent(inout) :: rc
  end subroutine
  subroutine mom_set_geomtype(g)
    type(ESMF_GeomType_Flag), intent(in) :: g
  end subroutine
  subroutine state_diagnose(state, string, rc)
    type(ESMF_State), intent(in) :: state
    character(len=*), intent(in) :: string
    integer, intent(out) :: rc
  end subroutine
  logical function ChkErr(rc, line, file)
    integer, intent(in) :: rc, line
    character(len=*), intent(in) :: file
    ChkErr = rc /= ESMF_SUCCESS
  end function
  subroutine mod2med_areacor()
  end subroutine
  subroutine med2mod_areacor()
  end subroutine
end module

module MOM_get_input
  implicit none
  type :: directories
    character(len=240) :: input_filename = ''
  end type
contains
  subroutine get_MOM_input()
  end subroutine
end module

module MOM_file_parser
  implicit none
  type :: param_file_type
    integer :: dummy
  end type
contains
  subroutine get_param()
  end subroutine
  subroutine close_param_file(pf)
    type(param_file_type), intent(inout) :: pf
  end subroutine
end module
