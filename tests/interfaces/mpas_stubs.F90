! Interfaces minimas do MPAS usadas por mpas_atm_types.F90 e
! mpas_atm_model.F90. Servem so para conferir a compilacao fora da Jaci
! (tipos, assinaturas e intent); nao executam nada. Usadas por
! tools/dev/compila-local.bash. Ao alterar um desses fontes, confira antes que
! a versao anterior compila com elas; se nao compilar, ajuste a interface aqui,
! seguindo a assinatura real do MPAS.
module mpas_kind_types
  implicit none
  integer, parameter :: RKIND = selected_real_kind(12)
  integer, parameter :: StrKIND = 512
end module mpas_kind_types

module mpas_derived_types
  use mpas_kind_types
  use iso_c_binding, only : c_int
  implicit none
  integer, parameter :: MPAS_LOG_CRIT = 4, MPAS_POOL_CONFIG = 1, MPAS_POOL_REAL = 2
  integer, parameter :: MPAS_POOL_INTEGER = 3, MPAS_POOL_CHARACTER = 4, MPAS_POOL_LOGICAL = 5
  type :: mpas_pool_type
    integer :: dummy
  end type
  type :: MPAS_Pool_iterator_type
    character(len=StrKIND) :: memberName
    integer :: memberType, dataType, nDims
  end type
  type :: field1DReal
    real(RKIND), pointer :: array(:) => null()
  end type
  type :: dm_info
    integer :: comm, nProcs
  end type
  type :: mpas_clock_type
    integer :: dummy
  end type
  type :: MPAS_streamManager_type
    integer :: dummy
  end type
  type :: mpas_log_type
    integer :: dummy
  end type
  type :: mpas_io_context_type
    integer :: dummy
  end type
  type :: mpas_decomp_list
    integer :: dummy
  end type
  type :: mpas_streaminfo_type
  contains
    procedure :: init => streaminfo_init
  end type
  type :: block_type
    type(mpas_pool_type), pointer :: structs => null(), allFields => null(), allStructs => null()
  end type
  type :: domain_type
    type(domain_type), pointer :: next => null()
    type(core_type), pointer :: core => null()
    type(dm_info), pointer :: dminfo => null()
    type(mpas_pool_type), pointer :: configs => null(), packages => null()
    type(mpas_clock_type), pointer :: clock => null()
    type(MPAS_streamManager_type), pointer :: streamManager => null()
    type(mpas_io_context_type), pointer :: ioContext => null()
    type(mpas_decomp_list), pointer :: decompositions => null()
    type(mpas_streaminfo_type), pointer :: streamInfo => null()
    type(mpas_log_type), pointer :: logInfo => null()
    type(block_type), pointer :: blocklist => null()
    character(len=StrKIND) :: namelist_filename, streams_filename
    character(len=StrKIND) :: parent_id, mesh_spec
    logical :: on_a_sphere, is_periodic
    real(RKIND) :: sphere_radius, x_period, y_period
  end type
  abstract interface
    function i_log(logInfo, domain) result(ierr)
      import :: mpas_log_type, domain_type
      type(mpas_log_type), pointer :: logInfo
      type(domain_type), pointer :: domain
      integer :: ierr
    end function
    function i_nml(configs, fname, dminfo) result(ierr)
      import :: mpas_pool_type, dm_info
      type(mpas_pool_type), pointer :: configs
      character(len=*) :: fname
      type(dm_info), pointer :: dminfo
      integer :: ierr
    end function
    function i_pk(packages) result(ierr)
      import :: mpas_pool_type
      type(mpas_pool_type), pointer :: packages
      integer :: ierr
    end function
    function i_spk(configs, streamInfo, packages, ioContext) result(ierr)
      import :: mpas_pool_type, mpas_streaminfo_type, mpas_io_context_type
      type(mpas_pool_type), pointer :: configs, packages
      type(mpas_streaminfo_type), pointer :: streamInfo
      type(mpas_io_context_type), pointer :: ioContext
      integer :: ierr
    end function
    function i_dec(d) result(ierr)
      import :: mpas_decomp_list
      type(mpas_decomp_list), pointer :: d
      integer :: ierr
    end function
    function i_clk(clock, configs) result(ierr)
      import :: mpas_clock_type, mpas_pool_type
      type(mpas_clock_type), pointer :: clock
      type(mpas_pool_type), pointer :: configs
      integer :: ierr
    end function
    function i_ims(mgr) result(ierr)
      import :: MPAS_streamManager_type
      type(MPAS_streamManager_type), pointer :: mgr
      integer :: ierr
    end function
    function i_init(domain, ts) result(ierr)
      import :: domain_type
      type(domain_type), intent(inout) :: domain
      character(len=*), intent(out) :: ts
      integer :: ierr
    end function
    function i_run(domain) result(ierr)
      import :: domain_type
      type(domain_type), intent(inout) :: domain
      integer :: ierr
    end function
  end interface
  type :: core_type
    type(core_type), pointer :: next => null()
    type(domain_type), pointer :: domainlist => null()
    character(len=StrKIND) :: coreName, modelName, modelVersion, source, Conventions, git_version
    procedure(i_log), pointer, nopass :: setup_log => null()
    procedure(i_nml), pointer, nopass :: setup_namelist => null()
    procedure(i_pk),  pointer, nopass :: define_packages => null()
    procedure(i_spk), pointer, nopass :: setup_packages => null()
    procedure(i_dec), pointer, nopass :: setup_decompositions => null()
    procedure(i_clk), pointer, nopass :: setup_clock => null()
    procedure(i_ims), pointer, nopass :: setup_immutable_streams => null()
    procedure(i_init), pointer, nopass :: core_init => null()
    procedure(i_run), pointer, nopass :: core_run => null()
    procedure(i_run), pointer, nopass :: core_finalize => null()
  end type
contains
  integer function streaminfo_init(this, comm, fname) result(ierr)
    class(mpas_streaminfo_type) :: this
    integer, intent(in) :: comm
    character(len=*), intent(in) :: fname
    ierr = 0
  end function
end module mpas_derived_types

module mpas_dmpar
  use mpas_derived_types
contains
  subroutine mpas_dmpar_exch_halo_field(f)
    type(field1DReal), pointer :: f
  end subroutine
end module

module mpas_timekeeping
  use mpas_derived_types
contains
  subroutine mpas_timekeeping_init(cal)
    character(len=*), intent(in) :: cal
  end subroutine
  subroutine mpas_advance_stop_time(clock, dt)
    type(mpas_clock_type), pointer :: clock
    integer, intent(in) :: dt
  end subroutine
end module

module mpas_framework
  use mpas_derived_types
contains
  subroutine mpas_framework_init_phase1(dminfo, external_comm)
    type(dm_info), pointer :: dminfo
    integer, intent(in), optional :: external_comm
  end subroutine
  subroutine mpas_framework_init_phase2(domain)
    type(domain_type), pointer :: domain
  end subroutine
  subroutine mpas_framework_finalize(dminfo, domain)
    type(dm_info), pointer :: dminfo
    type(domain_type), pointer :: domain
  end subroutine
end module

module mpas_domain_routines
  use mpas_derived_types
contains
  subroutine mpas_allocate_domain(dom)
    type(domain_type), pointer :: dom
  end subroutine
end module

module mpas_pool_routines
  use mpas_derived_types
  interface mpas_pool_get_array
    module procedure ga1, ga2
  end interface
  interface mpas_pool_get_config
    module procedure gcl, gcc, gcr, gci
  end interface
contains
  subroutine ga1(p, n, a, t)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    real(RKIND), pointer :: a(:)
    integer, intent(in), optional :: t
  end subroutine
  subroutine ga2(p, n, a, t)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    real(RKIND), pointer :: a(:,:)
    integer, intent(in), optional :: t
  end subroutine
  subroutine gcl(p, n, v)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    logical, pointer :: v
  end subroutine
  subroutine gcc(p, n, v)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    character(len=*), pointer :: v
  end subroutine
  subroutine gcr(p, n, v)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    real(RKIND), pointer :: v
  end subroutine
  subroutine gci(p, n, v)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    integer, pointer :: v
  end subroutine
  subroutine mpas_pool_get_dimension(p, n, v)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    integer, pointer :: v
  end subroutine
  subroutine mpas_pool_get_subpool(p, n, s)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    type(mpas_pool_type), pointer :: s
  end subroutine
  subroutine mpas_pool_begin_iteration(p)
    type(mpas_pool_type), intent(inout) :: p
  end subroutine
  logical function mpas_pool_get_next_member(p, itr)
    type(mpas_pool_type), intent(inout) :: p
    type(MPAS_Pool_iterator_type), intent(inout) :: itr
    mpas_pool_get_next_member = .false.
  end function
  subroutine mpas_pool_get_field(p, n, f, t)
    type(mpas_pool_type), intent(in) :: p
    character(len=*), intent(in) :: n
    type(field1DReal), pointer :: f
    integer, intent(in), optional :: t
  end subroutine
end module

module mpas_bootstrapping
  use mpas_derived_types
contains
  subroutine mpas_bootstrap_framework_phase1(domain, fname, iotype)
    type(domain_type), pointer :: domain
    character(len=*), intent(in) :: fname
    integer, intent(in) :: iotype
  end subroutine
  subroutine mpas_bootstrap_framework_phase2(domain)
    type(domain_type), pointer :: domain
  end subroutine
end module

module mpas_stream_inquiry
  use mpas_derived_types
contains
  function MPAS_stream_inquiry_new_streaminfo() result(p)
    type(mpas_streaminfo_type), pointer :: p
    p => null()
  end function
end module

module mpas_stream_manager
  use mpas_derived_types
  interface MPAS_stream_mgr_add_att
    module procedure aai, aac, aar, aal
  end interface
contains
  subroutine MPAS_stream_mgr_init(mgr, io, clock, f, p, s)
    type(MPAS_streamManager_type), pointer :: mgr
    type(mpas_io_context_type), pointer :: io
    type(mpas_clock_type), pointer :: clock
    type(mpas_pool_type), pointer :: f, p, s
  end subroutine
  subroutine MPAS_stream_mgr_validate_streams(mgr, ierr)
    type(MPAS_streamManager_type), pointer :: mgr
    integer, intent(out), optional :: ierr
  end subroutine
  subroutine aai(mgr, n, v, ierr)
    type(MPAS_streamManager_type), pointer :: mgr
    character(len=*), intent(in) :: n
    integer, intent(in) :: v
    integer, intent(out), optional :: ierr
  end subroutine
  subroutine aac(mgr, n, v, ierr)
    type(MPAS_streamManager_type), pointer :: mgr
    character(len=*), intent(in) :: n, v
    integer, intent(out), optional :: ierr
  end subroutine
  subroutine aar(mgr, n, v, ierr)
    type(MPAS_streamManager_type), pointer :: mgr
    character(len=*), intent(in) :: n
    real(RKIND), intent(in) :: v
    integer, intent(out), optional :: ierr
  end subroutine
  subroutine aal(mgr, n, v, ierr)
    type(MPAS_streamManager_type), pointer :: mgr
    character(len=*), intent(in) :: n
    logical, intent(in) :: v
    integer, intent(out), optional :: ierr
  end subroutine
end module

module mpas_io
  integer, parameter :: MPAS_IO_PNETCDF = 1
end module

module mpas_log
  use mpas_derived_types
  type(mpas_log_type), pointer :: mpas_log_info => null()
contains
  subroutine mpas_log_write(msg, messageType, intArgs, realArgs, logicArgs, masterOnly, flushNow, err)
    character(len=*), intent(in) :: msg
    integer, intent(in), optional :: messageType
    integer, intent(in), optional :: intArgs(:)
    real(RKIND), intent(in), optional :: realArgs(:)
    logical, intent(in), optional :: logicArgs(:)
    logical, intent(in), optional :: masterOnly, flushNow
    integer, intent(out), optional :: err
  end subroutine
end module

module atm_core_interface
  use mpas_derived_types
contains
  subroutine atm_setup_core(core)
    type(core_type), pointer :: core
  end subroutine
  subroutine atm_setup_domain(domain)
    type(domain_type), pointer :: domain
  end subroutine
end module
