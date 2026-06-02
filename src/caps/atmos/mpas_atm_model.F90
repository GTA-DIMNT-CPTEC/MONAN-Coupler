!> @file mpas_atm_model.F90
!! @brief Interface com o modelo atmosférico MPAS-A 8.3 / MONAN-A 2.0.
!!
!! Versão 5.1 — Interface MONAN-A 2.0: init/run/final/resize + buffers de acoplamento.
!!   Com -DMPAS_EXTERNAL_ESMF_LIB, mpas_timekeeping.F usa 'use ESMF' (externo).
!!   mpas_advance_stop_time controla o relógio INTERNO do MONAN-A (g_domain%%clock),
!!   independente do relógio ESMF do driver. Ambos são necessários.
!!
!! Sequência de inicialização do MONAN-A (confirmada via probe no Jaci):
!!   phase1(external_comm) → atm_setup_core → atm_setup_domain → setup_log →
!!   setup_namelist → phase2 → streamInfo → define_packages → setup_packages →
!!   setup_decompositions → setup_clock → bootstrap_phase1 → stream_mgr_init →
!!   setup_immutable_streams → xml_stream_parser → bootstrap_phase2 → core_init →
!!   extração de ponteiros zero-copy.
!!
!! Assinaturas confirmadas (probe_block_type.bash, Jaci):
!!   core_init     : function(domain, startTimeStamp) result(ierr)  [integer]
!!   core_run      : function(domain) result(ierr)                   [integer]
!!   core_finalize : function(domain) result(ierr)                   [integer]

module mpas_atm_model_mod

  ! Tipos públicos em módulo isolado (sem dependência ESMF externa)
  use mpas_atm_types_mod, only : MPAS_RKIND,             &
                                  mpas_atm_public_type,   &
                                  mpas_atm_state_type,    &
                                  atm_ocean_boundary_type

  use mpas_kind_types,    only : RKIND
  use mpas_derived_types, only : domain_type, mpas_pool_type, MPAS_LOG_CRIT

  ! Duas fases confirmadas no probe (mpas_framework.F linhas 47/78/165)
  use mpas_timekeeping,   only : mpas_timekeeping_init,  &
                                  mpas_advance_stop_time
  use mpas_framework,     only : mpas_framework_init_phase1,  &
                                  mpas_framework_init_phase2,  &
                                  mpas_framework_finalize

  use mpas_domain_routines, only : mpas_allocate_domain

  use mpas_pool_routines, only : mpas_pool_get_array,    &
                                  mpas_pool_get_dimension, &
                                  mpas_pool_get_subpool,   &
                                  mpas_pool_get_config

  use mpas_bootstrapping, only : mpas_bootstrap_framework_phase1, &
                                  mpas_bootstrap_framework_phase2

  use mpas_stream_inquiry, only : MPAS_stream_inquiry_new_streaminfo

  use mpas_stream_manager, only : MPAS_stream_mgr_init,            &
                                   MPAS_stream_mgr_validate_streams
  use iso_c_binding,        only : c_loc, c_ptr, c_int, c_char

  use mpas_io,             only : MPAS_IO_PNETCDF

  ! mpas_log_write confirmado (probe mpas_log.F linha 480)
  use mpas_log,           only : mpas_log_write, mpas_log_info

  ! atm_setup_core: registra core_init/run/finalize em domain%core (seção 8 probe)
  use atm_core_interface, only : atm_setup_core, atm_setup_domain


  use mpas_cap_config_mod,  only : cfg_sst_default, &
                                    cfg_ice_fraction_default, &
                                    cfg_zorl_default

  implicit none
  private

  ! Ponteiros PRIVADOS de módulo
  type(domain_type), pointer, private, save :: g_domain   => null()
  integer,                    private, save :: g_mpi_comm = -1

  ! ── Ponteiros para arrays de pool (leitura em mpas_atm_run) ────────────────
  ! Necessários para computar incrementos de acumulados e stress superficial.
  ! São ponteiros para memória do MPAS pool — NÃO devem ser desalocados aqui.
  real(MPAS_RKIND), pointer, private, save :: g_pool_acswdnb(:) => null() ! J/m² acumulado
  real(MPAS_RKIND), pointer, private, save :: g_pool_aclwdnb(:) => null() ! J/m² acumulado
  real(MPAS_RKIND), pointer, private, save :: g_pool_rainnc(:)  => null() ! mm acumulado (estratiforme)
  real(MPAS_RKIND), pointer, private, save :: g_pool_rainc(:)   => null() ! mm acumulado (convectiva)
  real(MPAS_RKIND), pointer, private, save :: g_pool_ust(:)     => null() ! vel. atrito [m/s]
  real(MPAS_RKIND), pointer, private, save :: g_pool_snownc(:)  => null() ! mm acum. neve estrat.
  real(MPAS_RKIND), pointer, private, save :: g_pool_q2(:)      => null() ! hum. espec. 2m [kg/kg]

  ! ── Valores do passo anterior (para cálculo de incrementos) ────────────────
  real(MPAS_RKIND), allocatable, private, save :: g_prev_acswdnb(:) ! J/m²
  real(MPAS_RKIND), allocatable, private, save :: g_prev_aclwdnb(:) ! J/m²
  real(MPAS_RKIND), allocatable, private, save :: g_prev_precip(:)  ! mm (rainnc+rainc)

  ! ── Buffers de saída em unidades instantâneas (apontados por atm_public) ───
  ! atm_public%swdn_sfc, lwdn_sfc, prec_total, taux_sfc, tauy_sfc
  ! apontam para estes arrays após mpas_atm_init.
  ! OBRIGATÓRIO: atributo TARGET para que ptr => array seja válido em Fortran.
  real(MPAS_RKIND), allocatable, target, private, save :: g_swdn_inst(:)  ! W/m²
  real(MPAS_RKIND), allocatable, target, private, save :: g_lwdn_inst(:)  ! W/m²
  real(MPAS_RKIND), allocatable, target, private, save :: g_prec_inst(:)  ! kg/m²/s
  real(MPAS_RKIND), allocatable, target, private, save :: g_taux_buf(:)       ! N/m²
  real(MPAS_RKIND), allocatable, target, private, save :: g_tauy_buf(:)       ! N/m²
  real(MPAS_RKIND), allocatable, target, private, save :: g_q2m_buf(:)        ! kg/kg
  real(MPAS_RKIND), allocatable, target, private, save :: g_prec_rain_buf(:)  ! kg/m²/s
  real(MPAS_RKIND), allocatable, target, private, save :: g_prec_snow_buf(:)  ! kg/m²/s
  ! BUG-WIND-01 fix: buffers para u10/v10 calculados por fallback logarítmico
  ! Usados quando bl_mynn_in=F e bl_ysu_in=F (u10/v10 ausentes do pool 'diag').
  real(MPAS_RKIND), allocatable, target, private, save :: g_u10_buf(:)    ! m/s
  real(MPAS_RKIND), allocatable, target, private, save :: g_v10_buf(:)    ! m/s
  ! Ponteiros para uReconstructZonal/Meridional do pool 'diag' (campo 3D: nVertLevels x nCells)
  ! Nível 1 = camada mais próxima da superfície no MPAS-A (ordem bottom-up)
  real(MPAS_RKIND), pointer, private, save :: g_pool_uZonal(:,:) => null()  ! [m/s] 3D
  real(MPAS_RKIND), pointer, private, save :: g_pool_vMerid(:,:) => null()  ! [m/s] 3D
  real(MPAS_RKIND), pointer, private, save :: g_pool_zgrid(:,:)  => null()  ! [m] altura geopotencial
  real(MPAS_RKIND), allocatable,         private, save :: g_prev_snow(:)      ! mm acum.

  ! Densidade do ar à superfície: constante de referência para cálculo de stress.
  ! Fonte: NIST, condições padrão (1013 hPa, 15°C). Erro < 5% na prática.
  real(MPAS_RKIND), parameter, private :: RHO_AIR_SFC = 1.2_MPAS_RKIND  ! kg/m³

  ! Velocidade mínima para evitar divisão por zero no cálculo de stress
  real(MPAS_RKIND), parameter, private :: VMIN = 0.1_MPAS_RKIND   ! m/s

  public :: mpas_atm_init
  public :: mpas_atm_run
  public :: mpas_atm_final
  public :: mpas_atm_init_sfc
  public :: mpas_atm_resize

contains

  !> @brief Obtém o nome do arquivo de malha do namelist.
  function mesh_filename_for_bootstrap(domain) result(fname)
    use mpas_derived_types, only : domain_type
    use mpas_pool_routines, only : mpas_pool_get_config
    use mpas_kind_types,    only : StrKIND
    type(domain_type), pointer, intent(in) :: domain
    character(len=256) :: fname
    character(len=StrKIND), pointer :: config_input_name => null()
    call mpas_pool_get_config(domain%configs, 'config_input_name', config_input_name)
    if (associated(config_input_name)) then
      fname = trim(config_input_name)
    else
      fname = 'x1.40962.init.nc'  ! fallback
    end if
  end function mesh_filename_for_bootstrap

  ! ============================================================================
  !> @brief Inicializa o MONAN-A 2.0.
  !!
  !! Sequência baseada no probe e em mpas_subdriver.F linhas 202/257:
  !!
  !!   1. mpas_framework_init_phase1(dminfo, external_comm=mpi_comm)
  !!      Inicializa dmpar (MPI wrapper) com o comunicador da VM ESMF.
  !!
  !!   2. atm_setup_core(domain%core)
  !!      Registra os procedure pointers core_init/core_run/core_finalize.
  !!      (Deve ser chamado entre phase1 e phase2 — confirmado pelo probe seção 8)
  !!
  !!   3. mpas_framework_init_phase2(domain, calendar=...)
  !!      Lê namelist.atmosphere, decompõe malha, aloca blocklist e pools,
  !!      inicializa clock MPAS-A com config_start_time do namelist.
  !!
  !!   4. Obtém startTimeStamp do clock via mpas_get_clock_time
  !!
  !!   5. ierr = core_init(domain, startTimeStamp)
  !!      Lê init.nc, configura física e integrador. Retorna inteiro.
  !!
  !!   6. Extrai nCells do subpool 'mesh' via blocklist%structs
  !!
  !!   7. Liga ponteiros zero-copy via subpools structs%mesh, structs%diag
  !!
  !! @param mpi_comm  Comunicador MPI inteiro (extraído pelo cap da VM ESMF).
  ! ============================================================================
  subroutine mpas_atm_init(atm_public, atm_state, atm_bnd, &
                            dt_seconds, config_dir, mpi_comm, rc)

    type(mpas_atm_public_type),    intent(inout) :: atm_public
    type(mpas_atm_state_type),     intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,          intent(in)  :: dt_seconds
    character(len=*), intent(in)  :: config_dir
    integer,          intent(in)  :: mpi_comm
    integer,          intent(out) :: rc

    type(mpas_pool_type), pointer :: meshPool     => null()
    type(mpas_pool_type), pointer :: diagPool     => null()
    type(mpas_pool_type), pointer :: diagPhysPool => null()

    integer, pointer :: nCells_ptr      => null()
    integer, pointer :: nCellsSolve_ptr => null()   ! B-32: células próprias (sem halos)
    integer, pointer :: nVertLev_ptr    => null()
    integer          :: n, nSolve, ierr
    character(len=64) :: startTimeStamp
    character(len=256) :: msg

    rc = 0
    g_mpi_comm           = mpi_comm
    atm_state%mpi_comm   = mpi_comm
    atm_state%dt_seconds = dt_seconds
    atm_state%config_dir = trim(config_dir)

    ! ------------------------------------------------------------------
    ! Sequência replicada de mpas_subdriver.F (confirmada pelo probe):
    !
    ! Aqui: g_domain ≡ domain_ptr; g_domain%core ≡ corelist.
    ! ------------------------------------------------------------------
    allocate(g_domain)
    nullify(g_domain%next)       ! linked-list: sem próximo domain

    allocate(g_domain%core)
    nullify(g_domain%core%next)  ! linked-list: sem próximo core

    ! Back-link: core%domainlist aponta para o domain
    g_domain%core%domainlist => g_domain

    ! ------------------------------------------------------------------
    ! 1. mpas_allocate_domain: aloca configs, packages, clock,
    !    streamManager, ioContext e faz nullify(blocklist).
    !    Também faz allocate(dom%dminfo) — mas phase1 vai re-alocar.
    ! ------------------------------------------------------------------
    call mpas_allocate_domain(g_domain)

    ! ------------------------------------------------------------------
    ! 2. Inicializa timekeeping do MONAN-A com calendário gregoriano.
    !    mpas_timekeeping_init cria os calendários ESMF via ESMF_CalendarCreate.
    !    Com -DMPAS_EXTERNAL_ESMF_LIB, usa ESMF real (esmf_base%%this).
    ! ------------------------------------------------------------------
    call mpas_timekeeping_init('gregorian')

    ! ------------------------------------------------------------------
    ! 3. Phase 1: inicializa MPI com o comunicador da VM ESMF.
    ! ------------------------------------------------------------------
    nullify(g_domain%dminfo)
    call mpas_framework_init_phase1(g_domain%dminfo, external_comm=g_mpi_comm)

    ! ------------------------------------------------------------------
    ! 3. Registra procedure pointers do núcleo (APÓS phase1, conforme
    !    mpas_subdriver.F). atm_setup_core recebe g_domain%core que é
    !    do tipo core_type — já alocado acima.
    ! ------------------------------------------------------------------
    call atm_setup_core(g_domain%core)

    ! ------------------------------------------------------------------
    ! 4. atm_setup_domain: registra campos adicionais no domain_type
    !    (nomes de variáveis, streams, etc.) — chamado por mpas_subdriver
    !    após atm_setup_core e antes de phase2.
    ! ------------------------------------------------------------------
    call atm_setup_domain(g_domain)

    ! ------------------------------------------------------------------
    ! 5. setup_log: inicializa o gerenciador de log do MPAS-A.
    !    DEVE ser chamado após atm_setup_core (que registra o procedure
    !    pointer setup_log em g_domain%core) e após phase1 (dminfo pronto).
    !    Qualquer mpas_log_write ANTES deste ponto → g_domain%logInfo
    !    não inicializado → SIGSEGV.
    !
    !    B-35 (fix): removida chamada prematura a mpas_log_write que existia
    !    logo após atm_setup_domain — era a causa raiz do SIGSEGV observado
    !    em todos os 128 ranks (backtrace: mpas_atm_model.F90:251).
    !    Mensagens de progresso anteriores a este ponto devem usar write(*,…).
    !
    !    Sequência de mpas_subdriver.F:
    !      ierr = domain_ptr%core%setup_log(domain_ptr%logInfo, domain_ptr)
    ! ------------------------------------------------------------------
    ierr = g_domain%core%setup_log(g_domain%logInfo, g_domain)
    if (ierr /= 0) then
      write(*,'(A)') 'ERRO mpas_atm_init: setup_log falhou'
      rc = ierr; return
    end if

    ! ------------------------------------------------------------------
    ! 6. setup_namelist: lê namelist.atmosphere para domain%configs.
    !    CRÍTICO: phase2 lê config_pio_num_iotasks e config_pio_stride
    !    de domain%configs. Sem setup_namelist, configs está vazio →
    !    mpas_pool_get_config retorna null pointer → SIGSEGV em phase2.
    !    mpas_subdriver.F:
    !      ierr = domain_ptr%core%setup_namelist(domain_ptr%configs,
    !               domain_ptr%namelist_filename, domain_ptr%dminfo)
    ! ------------------------------------------------------------------
    g_domain%namelist_filename = trim(atm_state%config_dir) // 'namelist.atmosphere'
    g_domain%streams_filename  = trim(atm_state%config_dir) // 'streams.atmosphere'

    ierr = g_domain%core%setup_namelist(g_domain%configs,         &
                                         g_domain%namelist_filename, &
                                         g_domain%dminfo)
    if (ierr /= 0) then
      call mpas_log_write('ERRO mpas_atm_init: setup_namelist falhou', &
                          messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if
    call mpas_log_write('mpas_atm_init: setup_log + setup_namelist concluidos')

    ! ------------------------------------------------------------------
    ! 7. Phase 2: decompõe malha, aloca blocklist e pools,
    !    configura clock com config_start_time do namelist.
    !    Chamada sem calendar= pois setup_namelist já leu config_calendar_type
    !    para domain%configs; phase2 o lê de lá quando calendar não é passado.
    ! ------------------------------------------------------------------
    call mpas_framework_init_phase2(g_domain)
    call mpas_log_write('mpas_atm_init: phase2 concluida (I/O init, timekeeping)')

    ! ------------------------------------------------------------------
    ! 8. streamInfo: informações sobre streams (lido do XML).
    ! ------------------------------------------------------------------
    g_domain%streamInfo => MPAS_stream_inquiry_new_streaminfo()
    if (.not. associated(g_domain%streamInfo)) then
      call mpas_log_write('ERRO: streamInfo falhou', messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if
    if (g_domain%streamInfo%init(g_domain%dminfo%comm, g_domain%streams_filename) /= 0) then
      call mpas_log_write('ERRO: streamInfo%init falhou', messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if

    ! ------------------------------------------------------------------
    ! 9. define_packages / setup_packages / setup_decompositions / setup_clock
    ! ------------------------------------------------------------------
    ierr = g_domain%core%define_packages(g_domain%packages)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: define_packages falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if

    ierr = g_domain%core%setup_packages(g_domain%configs, g_domain%streamInfo, &
                                         g_domain%packages, g_domain%ioContext)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: setup_packages falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if

    ierr = g_domain%core%setup_decompositions(g_domain%decompositions)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: setup_decompositions falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if

    ierr = g_domain%core%setup_clock(g_domain%clock, g_domain%configs)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: setup_clock falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if
    call mpas_log_write('mpas_atm_init: packages + decomp + clock configurados')

    ! ------------------------------------------------------------------
    ! 10. mpas_bootstrap_framework_phase1: lê malha, cria blocos,
    !     distribui domínio. Após esta chamada, blocklist está alocado.
    !     O filename do mesh é lido de config_input_name no namelist.
    ! ------------------------------------------------------------------
    call mpas_bootstrap_framework_phase1(g_domain, &
         trim(mesh_filename_for_bootstrap(g_domain)), MPAS_IO_PNETCDF)

    if (.not. associated(g_domain%blocklist)) then
      call mpas_log_write('ERRO: blocklist nulo apos bootstrap_phase1', &
                          messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if
    call mpas_log_write('mpas_atm_init: bootstrap_phase1 concluido (blocklist alocado)')

    ! ------------------------------------------------------------------
    ! 11. Configura stream manager e streams imutáveis.
    ! ------------------------------------------------------------------
    call MPAS_stream_mgr_init(g_domain%streamManager, g_domain%ioContext, &
                              g_domain%clock, g_domain%blocklist%allFields, &
                              g_domain%packages, g_domain%blocklist%allStructs)

    ierr = g_domain%core%setup_immutable_streams(g_domain%streamManager)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: setup_immutable_streams falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if

    ! ------------------------------------------------------------------
    ! 11b. xml_stream_parser: parseia streams.atmosphere e registra todas
    !      as streams dinâmicas no stream manager.
    !      CRÍTICO: sem esta chamada, as streams do namelist não são
    !      registradas → reads retornam garbage → crash na física.
    !      Interface C definida localmente (igual ao mpas_subdriver.F).
    ! ------------------------------------------------------------------
    block
      use iso_c_binding, only : c_loc, c_ptr, c_int, c_char
      interface
        subroutine xml_stream_parser(xmlname, mgr_p, comm, ierr) bind(c)
          use iso_c_binding, only : c_char, c_ptr, c_int
          character(kind=c_char), dimension(*), intent(in)    :: xmlname
          type(c_ptr),                          intent(inout) :: mgr_p
          integer(kind=c_int),                  intent(inout) :: comm
          integer(kind=c_int),                  intent(out)   :: ierr
        end subroutine xml_stream_parser
      end interface
      type(c_ptr)                            :: mgr_p
      integer(kind=c_int)                    :: c_comm, c_ierr
      character(kind=c_char,len=1), dimension(512) :: c_filename
      integer :: k, slen

      ! Converter streams_filename para C string
      slen = len_trim(g_domain%streams_filename)
      do k = 1, slen
        c_filename(k) = g_domain%streams_filename(k:k)
      end do
      c_filename(slen+1) = achar(0)  ! null terminator (C string)

#ifdef MPAS_USE_MPI_F08
      c_comm = g_domain%dminfo%comm%mpi_val
#else
      c_comm = g_domain%dminfo%comm
#endif
      mgr_p = c_loc(g_domain%streamManager)
      call xml_stream_parser(c_filename, mgr_p, c_comm, c_ierr)
      if (c_ierr /= 0) then
        call mpas_log_write('ERRO: xml_stream_parser falhou para streams.atmosphere', &
                            messageType=MPAS_LOG_CRIT)
        rc = 1; return
      end if
    end block

    call mpas_log_write('mpas_atm_init: xml_stream_parser concluido')

    ! Valida streams após configuração
    call MPAS_stream_mgr_validate_streams(g_domain%streamManager, ierr=ierr)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: stream manager validation falhou', messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if
    call mpas_log_write('mpas_atm_init: streams validadas')

    ! ------------------------------------------------------------------
    ! 12. mpas_bootstrap_framework_phase2: finaliza alocação de campos e halos.
    ! ------------------------------------------------------------------
    call mpas_bootstrap_framework_phase2(g_domain)
    call mpas_log_write('mpas_atm_init: bootstrap_phase2 concluido')

    ! ------------------------------------------------------------------
    ! 13. Inicializa o núcleo atmosférico (core_init).
    ! ------------------------------------------------------------------
    startTimeStamp = ''
    ierr = g_domain%core%core_init(g_domain, startTimeStamp)
    if (ierr /= 0) then
      write(msg,'(A,I0)') 'ERRO mpas_atm_init: core_init retornou ierr=', ierr
      call mpas_log_write(trim(msg), messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if
    call mpas_log_write('mpas_atm_init: core_init concluido')

    ! ------------------------------------------------------------------
    ! 6. Extrai nCells do subpool 'mesh'
    !    Probe seção 7, mpas_atm_core.F linha 167:
    !    O campo do bloco é 'structs' (confirmado pelo probe).
    ! ------------------------------------------------------------------
    call mpas_pool_get_subpool(g_domain%blocklist%structs, 'mesh', meshPool)

    if (.not. associated(meshPool)) then
      write(*,'(A)') 'ERRO mpas_atm_init: subpool mesh nao encontrado em blocklist%structs'
      rc = 1; return
    end if

    call mpas_pool_get_dimension(meshPool, 'nCells',      nCells_ptr)
    call mpas_pool_get_dimension(meshPool, 'nCellsSolve', nCellsSolve_ptr)  ! B-32
    call mpas_pool_get_dimension(meshPool, 'nVertLevels', nVertLev_ptr)

    if (.not. associated(nCells_ptr)) then
      write(*,'(A)') 'ERRO mpas_atm_init: nCells nao encontrado no subpool mesh'
      rc = 1; return
    end if

    n = nCells_ptr

    ! B-33: merge() avalia AMBOS os argumentos (tsource e fsource) antes de
    ! aplicar a máscara — comportamento mandatório do padrão Fortran (7.1.5.2).
    ! Se nCellsSolve_ptr for null(), a referência implícita ao ponteiro em tsource
    ! gera SIGSEGV independentemente do valor de mask=associated(...).
    ! Correção: usar if/else para evitar qualquer dereference quando null.
    if (associated(nCellsSolve_ptr)) then
      nSolve = nCellsSolve_ptr
    else
      nSolve = n
      write(*,'(A)') 'AVISO mpas_atm_init: nCellsSolve ausente no pool mesh — usando nCells'
    end if

    ! B-34: nVertLev_ptr pode ser null() se 'nVertLevels' não existir no pool
    ! (e.g., nome divergente no Registry.xml de alguma versão). Desreferenciar
    ! um ponteiro null gera SIGSEGV. Guardar com associated() antes de usar.
    if (associated(nVertLev_ptr)) then
      atm_state%nVertLevels  = nVertLev_ptr
      atm_public%nVertLevels = nVertLev_ptr
    else
      write(*,'(A)') 'AVISO mpas_atm_init: nVertLevels ausente no pool mesh — usando default 55'
      atm_state%nVertLevels  = 55   ! default da física MONAN-A 2.0
      atm_public%nVertLevels = 55
    end if

    atm_state%nCells       = n
    atm_public%nCells      = n
    atm_public%nCellsSolve = nSolve   ! B-32: expõe para netcdf_init_coords

    ! ------------------------------------------------------------------
    ! 7a. Ponteiros zero-copy: geometria (subpool 'mesh')
    !     Confirmado: mpas_atm_core.F linha 437 usa 'areaCell' de mesh.
    ! ------------------------------------------------------------------
    call mpas_pool_get_array(meshPool, 'latCell',  atm_public%latCell)
    call mpas_pool_get_array(meshPool, 'lonCell',  atm_public%lonCell)
    call mpas_pool_get_array(meshPool, 'areaCell', atm_public%areaCell)

    if (.not. associated(atm_public%latCell)) then
      write(*,'(A)') 'ERRO mpas_atm_init: latCell nao encontrado no subpool mesh'
      rc = 1; return
    end if

    ! ------------------------------------------------------------------
    ! 7b. Ponteiros zero-copy: diagnósticos
    !
    !  No MONAN-A 2.0 os campos estão distribuídos em dois subpools:
    !
    !  subpool 'diag'         — variáveis termodinâmicas e de radiação:
    !    mslp, acswdnb, aclwdnb, rainnc, u10, v10
    !
    !  subpool 'diag_physics' — saídas de pacotes de CLP/superfície
    !    (ativo com bl_mynn_in=T ou bl_ysu_in=T):
    !    t2m, lh, hfx
    !
    !  Estratégia: busca em 'diag' primeiro; para qualquer campo ainda
    !  nulo, tenta 'diag_physics'. Cobre reorganizações do Registry.xml
    !  entre versões sem exigir probe externo.
    !
    !  Confirmado nos logs: mslp encontrado em 'diag'; t2m, acswdnb,
    !  rainnc e lh retornavam nulo em 'diag' com mesoscale_reference_monan.
    ! ------------------------------------------------------------------

    ! Passa 1: subpool 'diag'
    call mpas_pool_get_subpool(g_domain%blocklist%structs, 'diag', diagPool)

    if (associated(diagPool)) then
      call mpas_pool_get_array(diagPool, 'mslp',    atm_public%pslv)     ! PSLV [Pa]
      call mpas_pool_get_array(diagPool, 'u10',     atm_public%u10)      ! U 10m [m/s]
      call mpas_pool_get_array(diagPool, 'v10',     atm_public%v10)      ! V 10m [m/s]
      ! Ponteiros privados para pools acumulados — não expostos diretamente
      call mpas_pool_get_array(diagPool, 'acswdnb', g_pool_acswdnb)      ! J/m² acum.
      call mpas_pool_get_array(diagPool, 'aclwdnb', g_pool_aclwdnb)      ! J/m² acum.
      call mpas_pool_get_array(diagPool, 'rainnc',  g_pool_rainnc)       ! mm acum. (estrat.)
      call mpas_pool_get_array(diagPool, 'rainc',   g_pool_rainc)        ! mm acum. (conv.)
      call mpas_pool_get_array(diagPool, 'snownc',  g_pool_snownc)       ! mm acum. neve estrat.
      ! t2m, lh, hfx: tentativa em 'diag'
      call mpas_pool_get_array(diagPool, 't2m',     atm_public%t2m)
      call mpas_pool_get_array(diagPool, 'lh',      atm_public%lhflx)
      call mpas_pool_get_array(diagPool, 'hfx',     atm_public%shflx)
    else
      write(*,'(A)') 'AVISO mpas_atm_init: subpool diag nao encontrado em structs'
    end if

    ! Passa 2: subpool 'diag_physics' — fallback para campos de CLP/superfície
    ! No MONAN-A 2.0 com suíte mesoscale_reference_monan, t2m/lh/hfx/ust estão aqui.
    call mpas_pool_get_subpool(g_domain%blocklist%structs, 'diag_physics', diagPhysPool)

    if (associated(diagPhysPool)) then
      ! Sobrescreve apenas ponteiros ainda nulos após a busca em 'diag'
      if (.not. associated(atm_public%t2m))    &
        call mpas_pool_get_array(diagPhysPool, 't2m',     atm_public%t2m)
      if (.not. associated(atm_public%u10))    &
        call mpas_pool_get_array(diagPhysPool, 'u10',     atm_public%u10)
      if (.not. associated(atm_public%v10))    &
        call mpas_pool_get_array(diagPhysPool, 'v10',     atm_public%v10)
      if (.not. associated(g_pool_acswdnb))    &
        call mpas_pool_get_array(diagPhysPool, 'acswdnb', g_pool_acswdnb)
      if (.not. associated(g_pool_aclwdnb))    &
        call mpas_pool_get_array(diagPhysPool, 'aclwdnb', g_pool_aclwdnb)
      if (.not. associated(g_pool_rainnc))     &
        call mpas_pool_get_array(diagPhysPool, 'rainnc',  g_pool_rainnc)
      if (.not. associated(g_pool_rainc))      &
        call mpas_pool_get_array(diagPhysPool, 'rainc',   g_pool_rainc)
      if (.not. associated(g_pool_snownc))     &
        call mpas_pool_get_array(diagPhysPool, 'snownc',  g_pool_snownc)
      if (.not. associated(g_pool_q2))         &
        call mpas_pool_get_array(diagPhysPool, 'q2',      g_pool_q2)
      if (.not. associated(atm_public%lhflx))  &
        call mpas_pool_get_array(diagPhysPool, 'lh',      atm_public%lhflx)
      if (.not. associated(atm_public%shflx))  &
        call mpas_pool_get_array(diagPhysPool, 'hfx',     atm_public%shflx)
      ! Velocidade de atrito — necessária para calcular stress superficial
      call mpas_pool_get_array(diagPhysPool, 'ust', g_pool_ust)
    end if

    call warn_if_null(atm_public%t2m,      't2m')
    call warn_if_null(atm_public%pslv,     'mslp')
    call warn_if_null(g_pool_acswdnb,      'acswdnb')
    call warn_if_null(g_pool_rainnc,       'rainnc')
    call warn_if_null(atm_public%lhflx,    'lh')
    if (.not. associated(g_pool_ust)) &
      write(*,'(A)') 'AVISO mpas_atm_init: ust nulo — taux/tauy serao zero'

    ! ── BUG-WIND-01 fix: fallback para u10/v10 quando CLP nao esta ativa ──────
    ! Com config_physics_suite='mesoscale_reference_monan' sem bl_mynn_in ou
    ! bl_ysu_in, os campos u10/v10 nao sao alocados no pool 'diag' (Registry.xml:
    ! packages="bl_mynn_in;bl_ysu_in"). atm_public%u10 e %v10 permanecem null()
    ! e mpas_export silenciosamente exporta zeros para Sa_u10m_mpas/Sa_v10m_mpas.
    !
    ! Solucao: se u10/v10 sao null, buscar uReconstructZonal/Meridional do pool
    ! 'diag' (campo 3D disponivel em QUALQUER suite MPAS) e aplicar perfil
    ! logaritmico neutro para extrapolar da altura do nivel 1 para 10 m:
    !
    !   u10 = u_sfc * ln(10/z0) / ln(z_sfc/z0)
    !
    ! onde z_sfc e a altura media do centro do nivel 1 (~50-100 m) e z0=0.001 m
    ! (mar aberto, Charnock neutral). Erro tipico: <15% vs. u10 do MYNN.
    ! ─────────────────────────────────────────────────────────────────────────────
    if (.not. associated(atm_public%u10) .or. .not. associated(atm_public%v10)) then
      write(*,'(A)') 'BUG-WIND-01: u10/v10 ausentes do pool (bl_mynn_in/bl_ysu_in inativos).'
      write(*,'(A)') '  Ativando fallback por perfil logaritmico de uReconstructZonal/Meridional.'

      ! Buscar uReconstructZonal e uReconstructMeridional (3D: nVertLevels x nCells)
      block
        type(mpas_pool_type), pointer :: diagPool2 => null()
        call mpas_pool_get_subpool(g_domain%blocklist%structs, 'diag', diagPool2)
        if (associated(diagPool2)) then
          call mpas_pool_get_array(diagPool2, 'uReconstructZonal',     g_pool_uZonal)
          call mpas_pool_get_array(diagPool2, 'uReconstructMeridional', g_pool_vMerid)
          ! zgrid: altura geopotencial nos centros de camada [m] (3D: nVertLevels x nCells)
          call mpas_pool_get_array(diagPool2, 'zgrid',                  g_pool_zgrid)
        end if
      end block

      if (associated(g_pool_uZonal) .and. associated(g_pool_vMerid)) then
        allocate(g_u10_buf(n), g_v10_buf(n))
        g_u10_buf = 0.0_MPAS_RKIND
        g_v10_buf = 0.0_MPAS_RKIND
        atm_public%u10 => g_u10_buf
        atm_public%v10 => g_v10_buf
        write(*,'(A)') '  BUG-WIND-01: buffers g_u10_buf/g_v10_buf alocados — OK.'
      else
        write(*,'(A)') '  BUG-WIND-01: uReconstructZonal nao encontrado no pool diag.'
        write(*,'(A)') '  SOLUCAO ALTERNATIVA: ativar bl_mynn_in no namelist.atmosphere:'
        write(*,'(A)') '    config_bl_pbl_physics  = 5'
        write(*,'(A)') '    config_sf_sfclay_physics = 5'
      end if
    end if

    ! ------------------------------------------------------------------
    ! 7c. Alocar buffers de saída em unidades instantâneas e apontar
    !     atm_public para eles.
    !
    !  Os campos acumulados do MPAS (acswdnb, aclwdnb, rainnc, rainc)
    !  NÃO podem ser expostos diretamente como Faxa_swdn/lwdn/prec porque:
    !    1. São acumulados desde t=0 — não representam o intervalo de acoplamento.
    !    2. Dividir pelo tempo total (÷ elapsed_s) dá a média desde t=0, não
    !       a média do último intervalo — divergência crescente ao longo do dia.
    !
    !  Solução: em cada mpas_atm_run, computar:
    !    swdn_inst = (acswdnb_N − acswdnb_{N-1}) / dt_coupling  [W/m²]
    !    lwdn_inst = (aclwdnb_N − aclwdnb_{N-1}) / dt_coupling  [W/m²]
    !    prec_inst = (rainnc_N + rainc_N − prev_N) / dt / 1000  [kg/m²/s]
    !
    !  Analogamente, taux/tauy nunca foram populados em nenhuma passada pelos
    !  pools — permanecem nulos → Faxa_taux/tauy nunca são exportados. Fix:
    !    taux = ρ · ust² · u10 / max(|V10|, VMIN)  [N/m²]
    !    tauy = ρ · ust² · v10 / max(|V10|, VMIN)  [N/m²]
    ! ------------------------------------------------------------------
    allocate(g_prev_acswdnb(n), g_prev_aclwdnb(n), g_prev_precip(n))
    allocate(g_swdn_inst(n), g_lwdn_inst(n), g_prec_inst(n))
    allocate(g_taux_buf(n), g_tauy_buf(n))
    allocate(g_q2m_buf(n), g_prec_rain_buf(n), g_prec_snow_buf(n))
    allocate(g_prev_snow(n))

    ! Inicializar valores do passo anterior com estado t=0 (após core_init)
    if (associated(g_pool_acswdnb)) then
      g_prev_acswdnb = g_pool_acswdnb(1:n)
    else
      g_prev_acswdnb = 0.0_MPAS_RKIND
    end if
    if (associated(g_pool_aclwdnb)) then
      g_prev_aclwdnb = g_pool_aclwdnb(1:n)
    else
      g_prev_aclwdnb = 0.0_MPAS_RKIND
    end if
    ! Precip total t=0: rainnc + rainc (podem ser não-zero após hot-start)
    if (associated(g_pool_rainnc) .and. associated(g_pool_rainc)) then
      g_prev_precip = g_pool_rainnc(1:n) + g_pool_rainc(1:n)
    else if (associated(g_pool_rainnc)) then
      g_prev_precip = g_pool_rainnc(1:n)
    else
      g_prev_precip = 0.0_MPAS_RKIND
    end if
    ! Neve acumulada t=0
    if (associated(g_pool_snownc)) then
      g_prev_snow = g_pool_snownc(1:n)
    else
      g_prev_snow = 0.0_MPAS_RKIND
    end if

    ! Buffers inicializados a zero (serão preenchidos no primeiro core_run)
    g_swdn_inst     = 0.0_MPAS_RKIND
    g_lwdn_inst     = 0.0_MPAS_RKIND
    g_prec_inst     = 0.0_MPAS_RKIND
    g_taux_buf      = 0.0_MPAS_RKIND
    g_tauy_buf      = 0.0_MPAS_RKIND
    g_q2m_buf       = 0.0_MPAS_RKIND
    g_prec_rain_buf = 0.0_MPAS_RKIND
    g_prec_snow_buf = 0.0_MPAS_RKIND

    ! Redirecionar atm_public para buffers computados (em vez de pool diretamente)
    atm_public%swdn_sfc   => g_swdn_inst
    atm_public%lwdn_sfc   => g_lwdn_inst
    atm_public%prec_total => g_prec_inst
    atm_public%taux_sfc   => g_taux_buf
    atm_public%tauy_sfc   => g_tauy_buf
    atm_public%q2m        => g_q2m_buf
    atm_public%prec_rain  => g_prec_rain_buf
    atm_public%prec_snow  => g_prec_snow_buf

    ! ------------------------------------------------------------------
    ! 8. Aloca arrays de propriedade deste módulo
    !
    ! Sprint A Fase 2 (Maio 2026): atm_bnd estendido com uocn/vocn
    ! (correntes superficiais do MOM6+SIS2). Inicializados a zero (oceano
    ! em repouso); preenchidos pelo mediador em mpas_import a cada passo.
    ! ------------------------------------------------------------------
    allocate(atm_bnd%sst         (n), &
             atm_bnd%ice_fraction(n), &
             atm_bnd%uocn        (n), &
             atm_bnd%vocn        (n), &
             atm_bnd%zorl        (n))
    atm_bnd%sst          = real(cfg_sst_default,          MPAS_RKIND)
    atm_bnd%ice_fraction = real(cfg_ice_fraction_default, MPAS_RKIND)
    atm_bnd%uocn         = 0.0_MPAS_RKIND   ! Sprint A: corrente zonal
    atm_bnd%vocn         = 0.0_MPAS_RKIND   ! Sprint A: corrente meridional
    atm_bnd%zorl         = real(cfg_zorl_default,         MPAS_RKIND)

    atm_state%initialized = .true.
    ! B-32: nSolve = células próprias (sem halos); n = nCells total (com halos).
    ! netcdf_init_coords deve usar nSolve → soma global = 40962.
    write(msg,'(A,I0,A,I0,A)') &
      'mpas_atm_init: OK (', nSolve, ' celulas proprias / ', n, ' com halos — SMIOL ativo)'
    call mpas_log_write(trim(msg))

  end subroutine mpas_atm_init

  ! ============================================================================
  subroutine mpas_atm_init_sfc(atm_public, atm_state, rc)
    type(mpas_atm_public_type), intent(inout) :: atm_public
    type(mpas_atm_state_type),  intent(inout) :: atm_state
    integer,                    intent(out)   :: rc
    rc = 0
    if (.not. atm_state%initialized) then
      write(*,'(A)') 'ERRO mpas_atm_init_sfc: modelo nao inicializado'
      rc = 1; return
    end if
    ! core_init já preencheu o subpool diag com dados do init.nc via SMIOL.
    ! Os ponteiros zero-copy em atm_public já contêm dados válidos.
    call mpas_log_write('mpas_atm_init_sfc: campos t=0 prontos (zero-copy)')
  end subroutine mpas_atm_init_sfc

  ! ============================================================================
  !> @brief Avança o MONAN-A por um intervalo de acoplamento.
  !!
  !! Probe seção 4 / mpas_atm_core.F linha 605:
  !!   function atm_core_run(domain) result(ierr)
  !! core_run é INTEGER FUNCTION — retorna código de erro MPAS.
  !!
  !! I/O (history/restart) via SMIOL/smiolf ocorre automaticamente
  !! conforme alarmes definidos em streams.atmosphere.
  ! ============================================================================
  subroutine mpas_atm_run(atm_public, atm_state, atm_bnd, dt_coupling, rc)

    type(mpas_atm_public_type),    intent(inout) :: atm_public
    type(mpas_atm_state_type),     intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(in)    :: atm_bnd
    integer,                       intent(in)    :: dt_coupling
    integer,                       intent(out)   :: rc

    type(mpas_pool_type), pointer   :: sfcInputPool => null()
    real(MPAS_RKIND), dimension(:), pointer :: sst_field  => null()
    real(MPAS_RKIND), dimension(:), pointer :: ice_field  => null()
    real(MPAS_RKIND), dimension(:), pointer :: zorl_field => null()
    integer :: n, ierr
    character(len=256) :: msg

    rc = 0
    n  = atm_state%nCells

    if (.not. atm_state%initialized .or. .not. associated(g_domain)) then
      write(*,'(A)') 'ERRO mpas_atm_run: modelo nao inicializado'
      rc = 1; return
    end if

    ! ------------------------------------------------------------------
    ! Injeta condições de fronteira no subpool 'sfc_input'
    ! Probe seção 7 / mpas_atm_core.F linha 553:
    ! Nomes Registry.xml: sst, iceAreaCell, znt
    ! ------------------------------------------------------------------
    call mpas_pool_get_subpool(g_domain%blocklist%structs, 'sfc_input', sfcInputPool)

    if (associated(sfcInputPool)) then
      call mpas_pool_get_array(sfcInputPool, 'sst',         sst_field)
      call mpas_pool_get_array(sfcInputPool, 'iceAreaCell', ice_field)
      call mpas_pool_get_array(sfcInputPool, 'znt',         zorl_field)

      if (associated(sst_field)  .and. allocated(atm_bnd%sst)) &
           sst_field(1:n)  = atm_bnd%sst(1:n)
      if (associated(ice_field)  .and. allocated(atm_bnd%ice_fraction)) &
           ice_field(1:n)  = atm_bnd%ice_fraction(1:n)
      if (associated(zorl_field) .and. allocated(atm_bnd%zorl)) &
           zorl_field(1:n) = atm_bnd%zorl(1:n)
    else
      write(*,'(A)') 'AVISO mpas_atm_run: subpool sfc_input nao encontrado em structs'
    end if

    call mpas_log_write('mpas_atm_run: sfc_input injetado')

    ! mpas_advance_stop_time: avança o stop time do relógio MPAS interno
    ! por exatamente dt_coupling antes de core_run.
    ! Avança o stop time do relógio interno do MONAN-A (g_domain%clock),
    ! independente do relógio ESMF do driver. Controla quantos passos
    ! internos (dt_atm) core_run integra por chamada a mpas_atm_run.
    call mpas_advance_stop_time(g_domain%clock, dt_coupling)

    ! ------------------------------------------------------------------
    ! Ativa mpas_log_info → domain%logInfo antes de core_run.
    ! mpas_subdriver.F linha 414:
    ! Sem isso, mpas_log_write dentro de core_run derreferencia null → SIGSEGV.
    ! ------------------------------------------------------------------
    if (associated(g_domain%logInfo)) mpas_log_info => g_domain%logInfo

    ! ------------------------------------------------------------------
    ! Avança o núcleo: integra passos internos de dt_atm, escreve I/O
    ! via SMIOL conforme streams.atmosphere.
    ! core_run é INTEGER FUNCTION.
    ! ------------------------------------------------------------------
    ierr = g_domain%core%core_run(g_domain)
    if (ierr /= 0) then
      write(msg,'(A,I0)') 'ERRO mpas_atm_run: core_run retornou ierr=', ierr
      write(*,'(A)') trim(msg)
      call mpas_log_write(trim(msg))
      rc = ierr; return
    end if

    call mpas_log_write('mpas_atm_run: core_run concluido')

    ! ------------------------------------------------------------------
    ! Pós-processamento dos campos acumulados e stress superficial.
    !
    ! Os arrays do pool (g_pool_*) foram atualizados por core_run.
    ! Agora computamos os valores instantâneos para o intervalo de
    ! acoplamento e armazenamos nos buffers g_*_inst / g_taux_buf / g_tauy_buf
    ! que são apontados por atm_public%swdn_sfc, lwdn_sfc, prec_total,
    ! taux_sfc, tauy_sfc (configurado em mpas_atm_init).
    !
    ! IMPORTANTE: usar real(dt_coupling, MPAS_RKIND) para evitar perda de
    ! precisão quando MPAS_RKIND = kind(1.0) (single precision).
    ! ------------------------------------------------------------------
    block
      real(MPAS_RKIND) :: dt_r, precip_now   ! Sprint A: spd removido (usado agora no bloco have_currents)
      integer          :: k
      dt_r = real(dt_coupling, MPAS_RKIND)

      ! ── SW e LW descendentes: incremento ÷ dt → W/m² ─────────────
      if (associated(g_pool_acswdnb)) then
        do k = 1, n
          g_swdn_inst(k) = max((g_pool_acswdnb(k) - g_prev_acswdnb(k)) / dt_r, &
                               0.0_MPAS_RKIND)
        end do
        g_prev_acswdnb(1:n) = g_pool_acswdnb(1:n)
      end if

      if (associated(g_pool_aclwdnb)) then
        do k = 1, n
          g_lwdn_inst(k) = max((g_pool_aclwdnb(k) - g_prev_aclwdnb(k)) / dt_r, &
                               0.0_MPAS_RKIND)
        end do
        g_prev_aclwdnb(1:n) = g_pool_aclwdnb(1:n)
      end if

      ! ── Precipitação total: (rainnc + rainc) incremento ÷ dt ──────
      ! rainnc [mm] = precipitação estratiforme acumulada
      ! rainc  [mm] = precipitação convectiva acumulada (esquema GF/KF)
      ! 1 mm = 1 kg/m² → taxa = Δmm / dt [kg/m²/s]
      do k = 1, n
        precip_now = 0.0_MPAS_RKIND
        if (associated(g_pool_rainnc)) precip_now = precip_now + g_pool_rainnc(k)
        if (associated(g_pool_rainc))  precip_now = precip_now + g_pool_rainc(k)
        g_prec_inst(k) = max((precip_now - g_prev_precip(k)) / dt_r, &
                              0.0_MPAS_RKIND)
      end do
      ! Atualizar acumulado anterior
      do k = 1, n
        g_prev_precip(k) = 0.0_MPAS_RKIND
        if (associated(g_pool_rainnc)) g_prev_precip(k) = g_prev_precip(k) + g_pool_rainnc(k)
        if (associated(g_pool_rainc))  g_prev_precip(k) = g_prev_precip(k) + g_pool_rainc(k)
      end do

      ! ── Precipitação sólida (neve): snownc incremento ÷ dt ────────
      ! snownc [mm] = neve estratiforme acumulada (subconjunto de rainnc)
      ! Se snownc não estiver disponível, usa partição por temperatura:
      !   T < T_FREEZE → tudo neve; caso contrário → tudo chuva
      block
        real(MPAS_RKIND), parameter :: T_FREEZE = 273.15_MPAS_RKIND
        real(MPAS_RKIND) :: snow_now, delta_snow, delta_total
        do k = 1, n
          delta_total = g_prec_inst(k)
          if (associated(g_pool_snownc)) then
            snow_now = g_pool_snownc(k)
            delta_snow = max((snow_now - g_prev_snow(k)) / dt_r, 0.0_MPAS_RKIND)
            g_prec_snow_buf(k) = min(delta_snow, delta_total)
            g_prec_rain_buf(k) = max(delta_total - g_prec_snow_buf(k), 0.0_MPAS_RKIND)
          else if (associated(atm_public%t2m)) then
            ! Fallback: partição por temperatura
            if (atm_public%t2m(k) < T_FREEZE) then
              g_prec_snow_buf(k) = delta_total
              g_prec_rain_buf(k) = 0.0_MPAS_RKIND
            else
              g_prec_snow_buf(k) = 0.0_MPAS_RKIND
              g_prec_rain_buf(k) = delta_total
            end if
          else
            g_prec_rain_buf(k) = delta_total
            g_prec_snow_buf(k) = 0.0_MPAS_RKIND
          end if
        end do
        ! Atualizar acumulado anterior de neve
        if (associated(g_pool_snownc)) then
          g_prev_snow(1:n) = g_pool_snownc(1:n)
        end if
      end block

      ! ── Umidade específica a 2m: q2 [kg/kg] ───────────────────────
      ! g_pool_q2 é ponteiro direto para o pool — sem buffer de incremento.
      ! Valor instantâneo → válido para o instante corrente.
      if (associated(g_pool_q2)) then
        g_q2m_buf(1:n) = g_pool_q2(1:n)
      else if (associated(atm_public%t2m)) then
        ! Fallback: umidade de saturação em T2m (Tetens) × RH=0.8
        block
          real(MPAS_RKIND) :: es, qs
          real(MPAS_RKIND), parameter :: es0 = 611.2_MPAS_RKIND
          real(MPAS_RKIND), parameter :: a   = 17.67_MPAS_RKIND
          real(MPAS_RKIND), parameter :: b   = 243.5_MPAS_RKIND
          real(MPAS_RKIND), parameter :: eps = 0.622_MPAS_RKIND
          real(MPAS_RKIND), parameter :: p0  = 101325.0_MPAS_RKIND
          do k = 1, n
            es = es0 * exp(a*(atm_public%t2m(k)-273.15_MPAS_RKIND) / &
                           (b + atm_public%t2m(k)-273.15_MPAS_RKIND))
            qs = eps * es / (p0 - es)
            g_q2m_buf(k) = 0.8_MPAS_RKIND * qs   ! RH=80% como fallback
          end do
        end block
      end if

      ! ── BUG-WIND-01 fallback: calcular u10/v10 por perfil log. neutro ────
      ! Ativo quando u10/v10 nao estao no pool (bl_mynn_in/bl_ysu_in=F).
      ! g_u10_buf/g_v10_buf sao alocados em mpas_atm_init se g_pool_uZonal disponivel.
      ! u10 = u_sfc × ln(10/z0) / ln(z_sfc/z0)
      ! z_sfc: altura do centro do nivel 1 obtida de zgrid(1,:) - zgrid(0,:)/2
      ! z0 = 0.001 m (rugosidade oceano aberto, neutro)
      if (allocated(g_u10_buf) .and. allocated(g_v10_buf) .and. &
          associated(g_pool_uZonal) .and. associated(g_pool_vMerid)) then
        block
          real(MPAS_RKIND) :: z_sfc, scale_fac
          real(MPAS_RKIND), parameter :: Z10   = 10.0_MPAS_RKIND   ! altura alvo [m]
          real(MPAS_RKIND), parameter :: Z0    = 0.001_MPAS_RKIND  ! rugosidade [m]
          real(MPAS_RKIND), parameter :: Z_SFC_DEFAULT = 30.0_MPAS_RKIND  ! fallback [m]
          integer :: nv
          nv = size(g_pool_uZonal, 1)  ! número de níveis verticais
          do k = 1, n
            ! Altura do centro do nível 1 a partir de zgrid (se disponível)
            if (associated(g_pool_zgrid) .and. size(g_pool_zgrid,1) > 1) then
              ! zgrid(1,k) = base do nível 1; (1,k)+(2,k))/2 = centro
              z_sfc = 0.5_MPAS_RKIND * (g_pool_zgrid(1,k) + g_pool_zgrid(2,k))
            else
              z_sfc = Z_SFC_DEFAULT
            end if
            z_sfc = max(z_sfc, 2.0_MPAS_RKIND)  ! mínimo 2 m
            ! Fator de perfil logarítmico neutro
            scale_fac = log(Z10 / Z0) / log(z_sfc / Z0)
            ! u10 = u_sfc × fator (nível 1 do MPAS = índice nv — top-down storage)
            ! O MPAS armazena nVertLevels de cima para baixo: nível 1 = topo, nv = superfície
            g_u10_buf(k) = g_pool_uZonal(nv, k) * scale_fac
            g_v10_buf(k) = g_pool_vMerid(nv, k) * scale_fac
          end do
        end block
      end if

      ! ── Stress superficial: τ = ρ · ust² · V_rel / |V_rel| ─────────────
      !
      ! Sprint A Fase 2 (Maio 2026):
      ! Antes: τx = ρ · ust² · u10 / |V10|  (vento absoluto)
      ! Agora: τx = ρ · ust² · u_rel / |V_rel|  (vento relativo ao oceano)
      !
      ! Vento relativo: V_rel = V_atm − V_ocn (Bryan et al. 2010, JC)
      ! Esta é a formulação fisicamente consistente: o oceano sente apenas
      ! o cisalhamento devido ao movimento relativo. Importante em correntes
      ! fortes (Kuroshio, Gulf Stream, Brasil, Agulhas, ACC, ENSO/MJO).
      !
      ! Sobre regiões continentais: atm_bnd%uocn/vocn=0 (mascara MED),
      ! recuperando exatamente a formulação original (V_rel = V_atm).
      !
      ! Direcao positiva: eastward (taux>0 quando V_rel vai para leste).
      ! Fórmula de Monin-Obukhov: CD = (ust/|V_rel|)²
      if (associated(g_pool_ust) .and. &
          associated(atm_public%u10) .and. associated(atm_public%v10)) then
        block
          real(MPAS_RKIND) :: u_rel, v_rel, spd_rel
          logical :: have_currents
          have_currents = allocated(atm_bnd%uocn) .and. allocated(atm_bnd%vocn)
          do k = 1, n
            if (have_currents) then
              u_rel = atm_public%u10(k) - atm_bnd%uocn(k)
              v_rel = atm_public%v10(k) - atm_bnd%vocn(k)
            else
              u_rel = atm_public%u10(k)
              v_rel = atm_public%v10(k)
            end if
            spd_rel = sqrt(u_rel**2 + v_rel**2)
            spd_rel = max(spd_rel, VMIN)
            g_taux_buf(k) = RHO_AIR_SFC * g_pool_ust(k)**2 * u_rel / spd_rel
            g_tauy_buf(k) = RHO_AIR_SFC * g_pool_ust(k)**2 * v_rel / spd_rel
          end do
        end block
      end if

    end block

    atm_state%running = .true.

    nullify(sfcInputPool, sst_field, ice_field, zorl_field)

  end subroutine mpas_atm_run

  ! ============================================================================
  !> @brief Finaliza o MONAN-A.
  !!
  !! Probe seção 5 / mpas_atm_core.F linha 1027:
  !!   function atm_core_finalize(domain) result(ierr)
  !! Probe mpas_framework.F linha 165:
  !!   subroutine mpas_framework_finalize(dminfo, domain, io_system)
  !!   io_system é OPCIONAL (mpas_subdriver linha 474 omite).
  !!
  !! Sequência obrigatória com SMIOL:
  !!   nullify(ponteiros zero-copy) → core_finalize → mpas_framework_finalize
  !!   → deallocate(domain)
  ! ============================================================================
  subroutine mpas_atm_final(atm_public, atm_state, atm_bnd, rc)

    type(mpas_atm_public_type),    intent(inout) :: atm_public
    type(mpas_atm_state_type),     intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,                       intent(out)   :: rc

    integer :: ierr

    rc = 0

    if (.not. atm_state%initialized) then
      call mpas_log_write('mpas_atm_final: nada a finalizar')
      return
    end if

    if (associated(g_domain)) then

      ! IMPORTANTE: core_finalize e mpas_framework_finalize sao OMITIDAS.
      !
      ! core_finalize do MPAS-A (compilado com -DMPAS_EXTERNAL_ESMF_LIB) destroi
      ! internamente objetos ESMF_Time e ESMF_Calendar que o framework NUOPC
      ! ainda precisa para cleanup dos conectores (RouteHandles) apos ModelFinalize.
      ! Chamar core_finalize dentro de ESMF_GridCompFinalize -> SIGSEGV.
      !
      ! Os streams SMIOL ja foram fechados automaticamente no ultimo core_run
      ! (streams.atmosphere define alarm de output/restart). O restart final
      ! pode ser obtido configurando output_alarm no streams.atmosphere.
      !
      ! mpas_framework_finalize tambem omitida pelos mesmos motivos.
      ! A memoria e liberada pelo SO no termino do processo MPI.
      !
      ! Apenas nulifica ponteiros para evitar dangling references:
      nullify(atm_public%latCell,    atm_public%lonCell,  atm_public%areaCell)
      nullify(atm_public%t2m,        atm_public%u10,      atm_public%v10)
      nullify(atm_public%pslv)
      nullify(atm_public%lhflx,      atm_public%shflx)
      nullify(atm_public%swdn_sfc,   atm_public%lwdn_sfc, atm_public%prec_total)
      nullify(atm_public%taux_sfc,   atm_public%tauy_sfc)
      nullify(atm_public%q2m,        atm_public%prec_rain, atm_public%prec_snow)
      nullify(g_pool_acswdnb, g_pool_aclwdnb, g_pool_rainnc, g_pool_rainc)
      nullify(g_pool_snownc,  g_pool_q2,       g_pool_ust)
      g_domain => null()

      write(*,'(A)') 'mpas_atm_final: ponteiros nulificados (ESMF preservado)'
    end if

    ! 4. Desaloca apenas arrays de propriedade deste módulo
    if (allocated(atm_bnd%sst))           deallocate(atm_bnd%sst)
    if (allocated(atm_bnd%ice_fraction))  deallocate(atm_bnd%ice_fraction)
    if (allocated(atm_bnd%uocn))          deallocate(atm_bnd%uocn)   ! Sprint A
    if (allocated(atm_bnd%vocn))          deallocate(atm_bnd%vocn)   ! Sprint A
    if (allocated(atm_bnd%zorl))          deallocate(atm_bnd%zorl)
    ! Buffers de saída computados (propriedade deste módulo)
    if (allocated(g_prev_acswdnb)) deallocate(g_prev_acswdnb)
    if (allocated(g_prev_aclwdnb)) deallocate(g_prev_aclwdnb)
    if (allocated(g_prev_precip))  deallocate(g_prev_precip)
    if (allocated(g_prev_snow))    deallocate(g_prev_snow)
    if (allocated(g_swdn_inst))    deallocate(g_swdn_inst)
    if (allocated(g_lwdn_inst))    deallocate(g_lwdn_inst)
    if (allocated(g_prec_inst))    deallocate(g_prec_inst)
    if (allocated(g_taux_buf))     deallocate(g_taux_buf)
    if (allocated(g_tauy_buf))     deallocate(g_tauy_buf)
    if (allocated(g_q2m_buf))      deallocate(g_q2m_buf)
    if (allocated(g_prec_rain_buf))deallocate(g_prec_rain_buf)
    if (allocated(g_prec_snow_buf))deallocate(g_prec_snow_buf)
    ! BUG-WIND-01: deallocate buffers de fallback de vento (se alocados)
    if (allocated(g_u10_buf))      deallocate(g_u10_buf)
    if (allocated(g_v10_buf))      deallocate(g_v10_buf)
    nullify(g_pool_uZonal, g_pool_vMerid, g_pool_zgrid)

    atm_state%initialized = .false.
    atm_state%running     = .false.

  end subroutine mpas_atm_final

  ! ============================================================================

  ! ============================================================================
  subroutine mpas_atm_resize(atm_public, atm_state, atm_bnd, nCells_new)
    type(mpas_atm_public_type),    intent(inout) :: atm_public
    type(mpas_atm_state_type),     intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,                       intent(in)    :: nCells_new
    character(len=256) :: msg

    if (nCells_new == atm_public%nCells) then
      write(msg,'(A,I0,A)') 'mpas_atm_resize: nCells=', nCells_new, ' consistente'
      call mpas_log_write(trim(msg))
      return
    end if

    write(msg,'(A,I0,A,I0)') 'mpas_atm_resize: AVISO ESMF nCells=', nCells_new, &
         ' difere de MPAS nCells=', atm_public%nCells
    call mpas_log_write(trim(msg))
    write(*,'(A)') trim(msg)

    ! ── Atualiza contadores de células em atm_public e atm_state ─────────
    atm_public%nCells = nCells_new
    atm_state%nCells  = nCells_new

    ! ── Redimensiona atm_bnd ──────────────────────────────────────────────
    ! Sprint A Fase 2: redimensiona também uocn/vocn (correntes do MOM6).
    if (allocated(atm_bnd%sst))          deallocate(atm_bnd%sst)
    if (allocated(atm_bnd%ice_fraction)) deallocate(atm_bnd%ice_fraction)
    if (allocated(atm_bnd%uocn))         deallocate(atm_bnd%uocn)
    if (allocated(atm_bnd%vocn))         deallocate(atm_bnd%vocn)
    if (allocated(atm_bnd%zorl))         deallocate(atm_bnd%zorl)

    allocate(atm_bnd%sst         (nCells_new))
    allocate(atm_bnd%ice_fraction(nCells_new))
    allocate(atm_bnd%uocn        (nCells_new))     ! Sprint A
    allocate(atm_bnd%vocn        (nCells_new))     ! Sprint A
    allocate(atm_bnd%zorl        (nCells_new))
    atm_bnd%sst          = real(cfg_sst_default,          MPAS_RKIND)
    atm_bnd%ice_fraction = real(cfg_ice_fraction_default, MPAS_RKIND)
    atm_bnd%uocn         = 0.0_MPAS_RKIND
    atm_bnd%vocn         = 0.0_MPAS_RKIND
    atm_bnd%zorl         = real(cfg_zorl_default,         MPAS_RKIND)

    ! ── Redimensiona buffers de módulo (acumulados e stress) ─────────────
    ! Estes arrays são alocados em mpas_atm_init com tamanho = MPAS nCells.
    ! Se o número de células mudou (particionamento ESMF diferente do MPAS),
    ! os buffers devem ser realocados para evitar acesso fora dos limites em
    ! mpas_atm_run (loop 1..n onde n = atm_state%nCells).
    if (allocated(g_prev_acswdnb)) then
      deallocate(g_prev_acswdnb, g_prev_aclwdnb, g_prev_precip)
      deallocate(g_prev_snow)
      deallocate(g_swdn_inst, g_lwdn_inst, g_prec_inst)
      deallocate(g_taux_buf, g_tauy_buf)
      deallocate(g_q2m_buf, g_prec_rain_buf, g_prec_snow_buf)

      allocate(g_prev_acswdnb(nCells_new), g_prev_aclwdnb(nCells_new), &
               g_prev_precip(nCells_new))
      allocate(g_prev_snow(nCells_new))
      allocate(g_swdn_inst(nCells_new), g_lwdn_inst(nCells_new), &
               g_prec_inst(nCells_new))
      allocate(g_taux_buf(nCells_new), g_tauy_buf(nCells_new))
      allocate(g_q2m_buf(nCells_new), g_prec_rain_buf(nCells_new), &
               g_prec_snow_buf(nCells_new))

      ! Reinicializar com estado atual dos pools (se disponíveis)
      if (associated(g_pool_acswdnb)) then
        g_prev_acswdnb(1:nCells_new) = g_pool_acswdnb(1:nCells_new)
      else
        g_prev_acswdnb = 0.0_MPAS_RKIND
      end if
      if (associated(g_pool_aclwdnb)) then
        g_prev_aclwdnb(1:nCells_new) = g_pool_aclwdnb(1:nCells_new)
      else
        g_prev_aclwdnb = 0.0_MPAS_RKIND
      end if
      if (associated(g_pool_rainnc) .and. associated(g_pool_rainc)) then
        g_prev_precip(1:nCells_new) = g_pool_rainnc(1:nCells_new) &
                                     + g_pool_rainc(1:nCells_new)
      else if (associated(g_pool_rainnc)) then
        g_prev_precip(1:nCells_new) = g_pool_rainnc(1:nCells_new)
      else
        g_prev_precip = 0.0_MPAS_RKIND
      end if
      g_swdn_inst     = 0.0_MPAS_RKIND
      g_lwdn_inst     = 0.0_MPAS_RKIND
      g_prec_inst     = 0.0_MPAS_RKIND
      g_taux_buf      = 0.0_MPAS_RKIND
      g_tauy_buf      = 0.0_MPAS_RKIND
      g_q2m_buf       = 0.0_MPAS_RKIND
      g_prec_rain_buf = 0.0_MPAS_RKIND
      g_prec_snow_buf = 0.0_MPAS_RKIND

      ! Redirecionar ponteiros de atm_public para os novos buffers
      atm_public%swdn_sfc   => g_swdn_inst
      atm_public%lwdn_sfc   => g_lwdn_inst
      atm_public%prec_total => g_prec_inst
      atm_public%taux_sfc   => g_taux_buf
      atm_public%tauy_sfc   => g_tauy_buf
      atm_public%q2m        => g_q2m_buf
      atm_public%prec_rain  => g_prec_rain_buf
      atm_public%prec_snow  => g_prec_snow_buf
    end if

    write(msg,'(A,I0,A)') 'mpas_atm_resize: buffers realocados para ', &
         nCells_new, ' celulas'
    call mpas_log_write(trim(msg))

  end subroutine mpas_atm_resize

  ! ─── auxiliares privados ───────────────────────────────────────────────────

  subroutine warn_if_null(ptr, name)
    real(MPAS_RKIND), pointer, intent(in) :: ptr(:)
    character(len=*),          intent(in) :: name
    character(len=256) :: msg
    if (.not. associated(ptr)) then
      write(msg,'(A,A,A)') 'AVISO: ponteiro nulo "', trim(name), &
           '" — verificar Registry.xml e namelist'
      call mpas_log_write(trim(msg))
      write(*,'(A)') trim(msg)
    end if
  end subroutine warn_if_null

end module mpas_atm_model_mod
