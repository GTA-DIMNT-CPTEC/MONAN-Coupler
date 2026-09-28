!> @file mpas_atm_setup.F90
!! @brief Etapas da inicialização do MONAN-A chamadas por mpas_atm_init.
!!
!! Domínio e framework MPAS, streams (com os atributos globais das saídas),
!! ligação dos ponteiros para os campos da malha e do diagnóstico, vento de
!! reserva, buffers de fluxos instantâneos e vetores de contorno.
!!
!! Separado de mpas_atm_model.F90 sem mudar instruções (R-FASE8-02).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module mpas_atm_setup_mod

  use mpas_atm_types_mod, only : MPAS_RKIND, mpas_atm_public_type, &
                                 mpas_atm_state_type, atm_ocean_boundary_type
  use mpas_kind_types, only : RKIND, StrKIND
  use mpas_derived_types, only : domain_type, mpas_pool_type, MPAS_LOG_CRIT, &
                                 MPAS_Pool_iterator_type, MPAS_POOL_CONFIG, &
                                 MPAS_POOL_REAL, MPAS_POOL_INTEGER, &
                                 MPAS_POOL_CHARACTER, MPAS_POOL_LOGICAL
  use mpas_timekeeping, only : mpas_timekeeping_init
  use mpas_framework, only : mpas_framework_init_phase1, mpas_framework_init_phase2
  use mpas_domain_routines, only : mpas_allocate_domain
  use mpas_pool_routines, only : mpas_pool_get_array, mpas_pool_get_dimension, &
                                 mpas_pool_get_subpool, mpas_pool_get_config, &
                                 mpas_pool_begin_iteration, &
                                 mpas_pool_get_next_member
  use mpas_bootstrapping, only : mpas_bootstrap_framework_phase1, &
                                 mpas_bootstrap_framework_phase2
  use mpas_stream_inquiry, only : MPAS_stream_inquiry_new_streaminfo
  use mpas_stream_manager, only : MPAS_stream_mgr_init, &
                                  MPAS_stream_mgr_validate_streams, &
                                  MPAS_stream_mgr_add_att
  use iso_c_binding, only : c_loc, c_ptr, c_int, c_char
  use mpas_io, only : MPAS_IO_PNETCDF
  use mpas_log, only : mpas_log_write
  use atm_core_interface, only : atm_setup_core, atm_setup_domain
  use coupler_config_mod, only : cfg_sst_default, cfg_ice_fraction_default, &
                                 cfg_zorl_default

  implicit none
  private

  public :: setup_mpas_domain
  public :: setup_mpas_streams
  public :: bind_mesh_fields
  public :: bind_diag_fields
  public :: setup_wind_fallback
  public :: init_flux_buffers
  public :: init_boundary_arrays

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

  !> Passos 1 a 9 de mpas_atm_init: aloca o dominio, inicializa o
  !! framework (fases 1 e 2) com o comunicador do componente, registra o
  !! nucleo, le o namelist e configura pacotes, decomposicoes e relogio.
  !! @param[in]  atm_state  estado do cap (diretorio de configuracao)
  !! @param[out] rc         0 em caso de sucesso
  subroutine setup_mpas_domain(atm_state, rc)
    type(mpas_atm_state_type), intent(inout) :: atm_state
    integer,                   intent(out) :: rc

    integer :: ierr

    rc = 0

    ! ------------------------------------------------------------------
    ! Sequência replicada de mpas_subdriver.F (confirmada pelo probe):
    !
    ! Aqui: atm_state%domain ≡ domain_ptr; atm_state%domain%core ≡ corelist.
    ! ------------------------------------------------------------------
    allocate(atm_state%domain)
    nullify(atm_state%domain%next)       ! linked-list: sem próximo domain

    allocate(atm_state%domain%core)
    nullify(atm_state%domain%core%next)  ! linked-list: sem próximo core

    ! Back-link: core%domainlist aponta para o domain
    atm_state%domain%core%domainlist => atm_state%domain

    ! ------------------------------------------------------------------
    ! 1. mpas_allocate_domain: aloca configs, packages, clock,
    !    streamManager, ioContext e faz nullify(blocklist).
    !    Também faz allocate(dom%dminfo) — mas phase1 vai re-alocar.
    ! ------------------------------------------------------------------
    call mpas_allocate_domain(atm_state%domain)

    ! ------------------------------------------------------------------
    ! 2. Inicializa timekeeping do MONAN-A com calendário gregoriano.
    !    mpas_timekeeping_init cria os calendários ESMF via ESMF_CalendarCreate.
    !    Com -DMPAS_EXTERNAL_ESMF_LIB, usa ESMF real (esmf_base%%this).
    ! ------------------------------------------------------------------
    call mpas_timekeeping_init('gregorian')

    ! ------------------------------------------------------------------
    ! 3. Phase 1: inicializa MPI com o comunicador da VM ESMF.
    ! ------------------------------------------------------------------
    nullify(atm_state%domain%dminfo)
    call mpas_framework_init_phase1(atm_state%domain%dminfo, external_comm=atm_state%mpi_comm)

    ! ------------------------------------------------------------------
    ! 3. Registra procedure pointers do núcleo (APÓS phase1, conforme
    !    mpas_subdriver.F). atm_setup_core recebe atm_state%domain%core que é
    !    do tipo core_type — já alocado acima.
    ! ------------------------------------------------------------------
    call atm_setup_core(atm_state%domain%core)

    ! ------------------------------------------------------------------
    ! 4. atm_setup_domain: registra campos adicionais no domain_type
    !    (nomes de variáveis, streams, etc.) — chamado por mpas_subdriver
    !    após atm_setup_core e antes de phase2.
    ! ------------------------------------------------------------------
    call atm_setup_domain(atm_state%domain)

    ! ------------------------------------------------------------------
    ! 5. setup_log: inicializa o gerenciador de log do MPAS-A.
    !    DEVE ser chamado após atm_setup_core (que registra o procedure
    !    pointer setup_log em atm_state%domain%core) e após phase1 (dminfo pronto).
    !    Qualquer mpas_log_write ANTES deste ponto → atm_state%domain%logInfo
    !    não inicializado → SIGSEGV.
    !
    ! removida chamada prematura a mpas_log_write que existia
    !    logo após atm_setup_domain — era a causa raiz do SIGSEGV observado
    !    em todos os 128 ranks (backtrace: mpas_atm_model.F90:251).
    !    Mensagens de progresso anteriores a este ponto devem usar write(*,…).
    !
    !    Sequência de mpas_subdriver.F:
    !      ierr = domain_ptr%core%setup_log(domain_ptr%logInfo, domain_ptr)
    ! ------------------------------------------------------------------
    ierr = atm_state%domain%core%setup_log(atm_state%domain%logInfo, atm_state%domain)
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
    atm_state%domain%namelist_filename = trim(atm_state%config_dir) // 'namelist.atmosphere'
    atm_state%domain%streams_filename  = trim(atm_state%config_dir) // 'streams.atmosphere'

    ierr = atm_state%domain%core%setup_namelist(atm_state%domain%configs,         &
                                         atm_state%domain%namelist_filename, &
                                         atm_state%domain%dminfo)
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
    call mpas_framework_init_phase2(atm_state%domain)
    call mpas_log_write('mpas_atm_init: phase2 concluida (I/O init, timekeeping)')

    ! ------------------------------------------------------------------
    ! 8. streamInfo: informações sobre streams (lido do XML).
    ! ------------------------------------------------------------------
    atm_state%domain%streamInfo => MPAS_stream_inquiry_new_streaminfo()
    if (.not. associated(atm_state%domain%streamInfo)) then
      call mpas_log_write('ERRO: streamInfo falhou', messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if
    if (atm_state%domain%streamInfo%init(atm_state%domain%dminfo%comm, atm_state%domain%streams_filename) /= 0) then
      call mpas_log_write('ERRO: streamInfo%init falhou', messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if

    ! ------------------------------------------------------------------
    ! 9. define_packages / setup_packages / setup_decompositions / setup_clock
    ! ------------------------------------------------------------------
    ierr = atm_state%domain%core%define_packages(atm_state%domain%packages)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: define_packages falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if

    ierr = atm_state%domain%core%setup_packages(atm_state%domain%configs, atm_state%domain%streamInfo, &
                                         atm_state%domain%packages, atm_state%domain%ioContext)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: setup_packages falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if

    ierr = atm_state%domain%core%setup_decompositions(atm_state%domain%decompositions)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: setup_decompositions falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if

    ierr = atm_state%domain%core%setup_clock(atm_state%domain%clock, atm_state%domain%configs)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: setup_clock falhou', messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if
    call mpas_log_write('mpas_atm_init: packages + decomp + clock configurados')
  end subroutine setup_mpas_domain

  !> Passos 10 a 12 de mpas_atm_init: le a malha (bootstrap fase 1),
  !! inicializa o stream manager, registra atributos globais e streams, e
  !! conclui a alocacao de campos e halos (bootstrap fase 2).
  !! @param[inout] atm_state  estado do modelo (domínio MPAS)
  !! @param[out]   rc         0 em caso de sucesso
  subroutine setup_mpas_streams(atm_state, rc)
    type(mpas_atm_state_type), intent(inout) :: atm_state
    integer, intent(out) :: rc

    integer :: ierr

    rc = 0


    ! ------------------------------------------------------------------
    ! 10. mpas_bootstrap_framework_phase1: lê malha, cria blocos,
    !     distribui domínio. Após esta chamada, blocklist está alocado.
    !     O filename do mesh é lido de config_input_name no namelist.
    ! ------------------------------------------------------------------
    call mpas_bootstrap_framework_phase1(atm_state%domain, &
         trim(mesh_filename_for_bootstrap(atm_state%domain)), MPAS_IO_PNETCDF)

    if (.not. associated(atm_state%domain%blocklist)) then
      call mpas_log_write('ERRO: blocklist nulo apos bootstrap_phase1', &
                          messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if
    call mpas_log_write('mpas_atm_init: bootstrap_phase1 concluido (blocklist alocado)')

    ! ------------------------------------------------------------------
    ! 11. Configura stream manager e streams imutáveis.
    ! ------------------------------------------------------------------
    call MPAS_stream_mgr_init(atm_state%domain%streamManager, atm_state%domain%ioContext, &
                              atm_state%domain%clock, atm_state%domain%blocklist%allFields, &
                              atm_state%domain%packages, atm_state%domain%blocklist%allStructs)

    ! ------------------------------------------------------------------
    ! 11a. Registra os atributos globais no stream manager.
    !      Equivale a add_stream_attributes(domain_ptr) de mpas_subdriver.F
    !      (linha 364), passo que estava ausente nesta reimplementacao da
    !      sequencia de inicializacao.
    !
    !      Sem esta chamada, as saidas do modelo (diag, history, restart)
    !      saem apenas com file_id, gerado internamente por mpas_io_streams
    !      e que nao passa pelo stream manager. Todos os demais atributos
    !      sao perdidos em silencio: model_name, core_name, version,
    !      source, Conventions, git_version, on_a_sphere, sphere_radius,
    !      is_periodic, x_period, y_period, history, parent_id, mesh_spec
    !      e a lista completa de config_* do namelist.
    !
    !      Pre-requisitos ja satisfeitos neste ponto:
    !        domain%on_a_sphere, %sphere_radius, %is_periodic, %x_period,
    !        %y_period, %parent_id e %mesh_spec sao preenchidos pelo
    !        mpas_bootstrap_framework_phase1 (passo 10);
    !        domain%streamManager e inicializado logo acima.
    ! ------------------------------------------------------------------
    call atm_add_stream_attributes(atm_state%domain)
    call mpas_log_write('mpas_atm_init: atributos globais registrados')

    ierr = atm_state%domain%core%setup_immutable_streams(atm_state%domain%streamManager)
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
    call parse_streams_xml(atm_state, rc)
    if (rc /= 0) return

    call mpas_log_write('mpas_atm_init: xml_stream_parser concluido')

    ! Valida streams após configuração
    call MPAS_stream_mgr_validate_streams(atm_state%domain%streamManager, ierr=ierr)
    if (ierr /= 0) then
      call mpas_log_write('ERRO: stream manager validation falhou', messageType=MPAS_LOG_CRIT)
      rc = 1; return
    end if
    call mpas_log_write('mpas_atm_init: streams validadas')

    ! ------------------------------------------------------------------
    ! 12. mpas_bootstrap_framework_phase2: finaliza alocação de campos e halos.
    ! ------------------------------------------------------------------
    call mpas_bootstrap_framework_phase2(atm_state%domain)
    call mpas_log_write('mpas_atm_init: bootstrap_phase2 concluido')
  end subroutine setup_mpas_streams

  !> Le as dimensoes do subpool 'mesh' e liga os ponteiros de geometria.
  !! @param[inout] atm_public  recebe nCells, nCellsSolve, nVertLevels e
  !!                           os ponteiros latCell, lonCell e areaCell
  !! @param[inout] atm_state   recebe nCells e nVertLevels
  !! @param[out]   n           numero de celulas locais, com halos
  !! @param[out]   nSolve      numero de celulas proprias, sem halos
  !! @param[out]   rc          0 em caso de sucesso
  subroutine bind_mesh_fields(atm_public, atm_state, n, nSolve, rc)
    type(mpas_atm_public_type), intent(inout) :: atm_public
    type(mpas_atm_state_type),  intent(inout) :: atm_state
    integer,                    intent(out)   :: n, nSolve
    integer,                    intent(out)   :: rc

    type(mpas_pool_type), pointer :: meshPool     => null()
    integer, pointer :: nCells_ptr      => null()
    integer, pointer :: nCellsSolve_ptr => null()  ! células próprias (sem halos)
    integer, pointer :: nVertLev_ptr    => null()

    rc = 0
    n = 0
    nSolve = 0

    ! ------------------------------------------------------------------
    ! 6. Extrai nCells do subpool 'mesh'
    !    Probe seção 7, mpas_atm_core.F linha 167:
    !    O campo do bloco é 'structs' (confirmado pelo probe).
    ! ------------------------------------------------------------------
    call mpas_pool_get_subpool(atm_state%domain%blocklist%structs, 'mesh', meshPool)

    if (.not. associated(meshPool)) then
      write(*,'(A)') 'ERRO mpas_atm_init: subpool mesh nao encontrado em blocklist%structs'
      rc = 1; return
    end if

    call mpas_pool_get_dimension(meshPool, 'nCells',      nCells_ptr)
    call mpas_pool_get_dimension(meshPool, 'nCellsSolve', nCellsSolve_ptr)
    call mpas_pool_get_dimension(meshPool, 'nVertLevels', nVertLev_ptr)

    if (.not. associated(nCells_ptr)) then
      write(*,'(A)') 'ERRO mpas_atm_init: nCells nao encontrado no subpool mesh'
      rc = 1; return
    end if

    n = nCells_ptr

    ! merge avalia AMBOS os argumentos (tsource e fsource) antes de
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

    ! nVertLev_ptr pode ser null se 'nVertLevels' não existir no pool
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
    atm_public%nCellsSolve = nSolve  ! expõe para netcdf_init_coords

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
  end subroutine bind_mesh_fields

  !> Liga os ponteiros dos campos de diagnostico (passo 7b de mpas_atm_init).
  !! @param[inout] atm_public  recebe os ponteiros pslv, u10, v10, t2m,
  !!                           lhflx e shflx
  !! @param[inout] atm_state   recebe os ponteiros para os acumulados do pool
  subroutine bind_diag_fields(atm_public, atm_state)
    type(mpas_atm_public_type), intent(inout) :: atm_public
    type(mpas_atm_state_type),  intent(inout) :: atm_state

    type(mpas_pool_type), pointer :: diagPool     => null()
    type(mpas_pool_type), pointer :: diagPhysPool => null()

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
    call mpas_pool_get_subpool(atm_state%domain%blocklist%structs, 'diag', diagPool)

    if (associated(diagPool)) then
      call mpas_pool_get_array(diagPool, 'mslp',    atm_public%pslv)     ! PSLV [Pa]
      call mpas_pool_get_array(diagPool, 'u10',     atm_public%u10)      ! U 10m [m/s]
      call mpas_pool_get_array(diagPool, 'v10',     atm_public%v10)      ! V 10m [m/s]
      ! Ponteiros privados para pools acumulados — não expostos diretamente
      call mpas_pool_get_array(diagPool, 'acswdnb', atm_state%pool_acswdnb)      ! J/m² acum.
      call mpas_pool_get_array(diagPool, 'aclwdnb', atm_state%pool_aclwdnb)      ! J/m² acum.
      call mpas_pool_get_array(diagPool, 'rainnc',  atm_state%pool_rainnc)       ! mm acum. (estrat.)
      call mpas_pool_get_array(diagPool, 'rainc',   atm_state%pool_rainc)        ! mm acum. (conv.)
      call mpas_pool_get_array(diagPool, 'snownc',  atm_state%pool_snownc)       ! mm acum. neve estrat.
      ! t2m, lh, hfx: tentativa em 'diag'
      call mpas_pool_get_array(diagPool, 't2m',     atm_public%t2m)
      call mpas_pool_get_array(diagPool, 'lh',      atm_public%lhflx)
      call mpas_pool_get_array(diagPool, 'hfx',     atm_public%shflx)
    else
      write(*,'(A)') 'AVISO mpas_atm_init: subpool diag nao encontrado em structs'
    end if

    ! Passa 2: subpool 'diag_physics' — fallback para campos de CLP/superfície
    ! No MONAN-A 2.0 com suíte mesoscale_reference_monan, t2m/lh/hfx/ust estão aqui.
    call mpas_pool_get_subpool(atm_state%domain%blocklist%structs, 'diag_physics', diagPhysPool)

    if (associated(diagPhysPool)) then
      ! Sobrescreve apenas ponteiros ainda nulos após a busca em 'diag'
      if (.not. associated(atm_public%t2m))    &
        call mpas_pool_get_array(diagPhysPool, 't2m',     atm_public%t2m)
      if (.not. associated(atm_public%u10))    &
        call mpas_pool_get_array(diagPhysPool, 'u10',     atm_public%u10)
      if (.not. associated(atm_public%v10))    &
        call mpas_pool_get_array(diagPhysPool, 'v10',     atm_public%v10)
      if (.not. associated(atm_state%pool_acswdnb))    &
        call mpas_pool_get_array(diagPhysPool, 'acswdnb', atm_state%pool_acswdnb)
      if (.not. associated(atm_state%pool_aclwdnb))    &
        call mpas_pool_get_array(diagPhysPool, 'aclwdnb', atm_state%pool_aclwdnb)
      if (.not. associated(atm_state%pool_rainnc))     &
        call mpas_pool_get_array(diagPhysPool, 'rainnc',  atm_state%pool_rainnc)
      if (.not. associated(atm_state%pool_rainc))      &
        call mpas_pool_get_array(diagPhysPool, 'rainc',   atm_state%pool_rainc)
      if (.not. associated(atm_state%pool_snownc))     &
        call mpas_pool_get_array(diagPhysPool, 'snownc',  atm_state%pool_snownc)
      if (.not. associated(atm_state%pool_q2))         &
        call mpas_pool_get_array(diagPhysPool, 'q2',      atm_state%pool_q2)
      if (.not. associated(atm_public%lhflx))  &
        call mpas_pool_get_array(diagPhysPool, 'lh',      atm_public%lhflx)
      if (.not. associated(atm_public%shflx))  &
        call mpas_pool_get_array(diagPhysPool, 'hfx',     atm_public%shflx)
      ! Velocidade de atrito — necessária para calcular stress superficial
      call mpas_pool_get_array(diagPhysPool, 'ust', atm_state%pool_ust)
    end if

    call warn_if_null(atm_public%t2m,      't2m')
    call warn_if_null(atm_public%pslv,     'mslp')
    call warn_if_null(atm_state%pool_acswdnb,      'acswdnb')
    call warn_if_null(atm_state%pool_rainnc,       'rainnc')
    call warn_if_null(atm_public%lhflx,    'lh')
    if (.not. associated(atm_state%pool_ust)) &
      write(*,'(A)') 'AVISO mpas_atm_init: ust nulo — taux/tauy serao zero'
  end subroutine bind_diag_fields

  !> Prepara o calculo de u10/v10 por perfil logaritmico quando os campos
  !! nao existem no pool.
  !! @param[inout] atm_public  u10 e v10 passam a apontar para os buffers
  !! @param[inout] atm_state   guarda os ponteiros do pool e os buffers
  !! @param[in]    n           numero de celulas locais, com halos
  subroutine setup_wind_fallback(atm_public, atm_state, n)
    type(mpas_atm_public_type), intent(inout) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    integer,                    intent(in)    :: n

    type(mpas_pool_type), pointer :: diagPool2 => null()

    ! ── fallback para u10/v10 quando CLP nao esta ativa ──────
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
      call mpas_pool_get_subpool(atm_state%domain%blocklist%structs, 'diag', diagPool2)
      if (associated(diagPool2)) then
        call mpas_pool_get_array(diagPool2, 'uReconstructZonal',     atm_state%pool_uZonal)
        call mpas_pool_get_array(diagPool2, 'uReconstructMeridional', atm_state%pool_vMerid)
        ! zgrid: altura geopotencial nos centros de camada [m] (3D: nVertLevels x nCells)
        call mpas_pool_get_array(diagPool2, 'zgrid',                  atm_state%pool_zgrid)
      end if

      if (associated(atm_state%pool_uZonal) .and. associated(atm_state%pool_vMerid)) then
        allocate(atm_state%u10_buf(n), atm_state%v10_buf(n))
        atm_state%u10_buf = 0.0_MPAS_RKIND
        atm_state%v10_buf = 0.0_MPAS_RKIND
        atm_public%u10 => atm_state%u10_buf
        atm_public%v10 => atm_state%v10_buf
        write(*,'(A)') '  BUG-WIND-01: buffers g_u10_buf/g_v10_buf alocados — OK.'
      else
        write(*,'(A)') '  BUG-WIND-01: uReconstructZonal nao encontrado no pool diag.'
        write(*,'(A)') '  SOLUCAO ALTERNATIVA: ativar bl_mynn_in no namelist.atmosphere:'
        write(*,'(A)') '    config_bl_pbl_physics  = 5'
        write(*,'(A)') '    config_sf_sfclay_physics = 5'
      end if
    end if
  end subroutine setup_wind_fallback

  !> Aloca os buffers de fluxos em unidades instantaneas e o estado do passo
  !! anterior (passo 7c de mpas_atm_init), e aponta atm_public para eles.
  !! @param[inout] atm_public  recebe os ponteiros dos fluxos
  !! @param[inout] atm_state   guarda os buffers e o estado do passo anterior
  !! @param[in]    n           numero de celulas locais, com halos
  subroutine init_flux_buffers(atm_public, atm_state, n)
    type(mpas_atm_public_type), intent(inout) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    integer,                    intent(in)    :: n

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
    allocate(atm_state%prev_acswdnb(n), atm_state%prev_aclwdnb(n), atm_state%prev_precip(n))
    allocate(atm_state%swdn_inst(n), atm_state%lwdn_inst(n), atm_state%prec_inst(n))
    allocate(atm_state%taux_buf(n), atm_state%tauy_buf(n))
    allocate(atm_state%q2m_buf(n), atm_state%prec_rain_buf(n), atm_state%prec_snow_buf(n))
    allocate(atm_state%prev_snow(n))

    ! Inicializar valores do passo anterior com estado t=0 (após core_init)
    if (associated(atm_state%pool_acswdnb)) then
      atm_state%prev_acswdnb = atm_state%pool_acswdnb(1:n)
    else
      atm_state%prev_acswdnb = 0.0_MPAS_RKIND
    end if
    if (associated(atm_state%pool_aclwdnb)) then
      atm_state%prev_aclwdnb = atm_state%pool_aclwdnb(1:n)
    else
      atm_state%prev_aclwdnb = 0.0_MPAS_RKIND
    end if
    ! Precip total t=0: rainnc + rainc (podem ser não-zero após hot-start)
    if (associated(atm_state%pool_rainnc) .and. associated(atm_state%pool_rainc)) then
      atm_state%prev_precip = atm_state%pool_rainnc(1:n) + atm_state%pool_rainc(1:n)
    else if (associated(atm_state%pool_rainnc)) then
      atm_state%prev_precip = atm_state%pool_rainnc(1:n)
    else
      atm_state%prev_precip = 0.0_MPAS_RKIND
    end if
    ! Neve acumulada t=0
    if (associated(atm_state%pool_snownc)) then
      atm_state%prev_snow = atm_state%pool_snownc(1:n)
    else
      atm_state%prev_snow = 0.0_MPAS_RKIND
    end if

    ! Buffers inicializados a zero (serão preenchidos no primeiro core_run)
    atm_state%swdn_inst     = 0.0_MPAS_RKIND
    atm_state%lwdn_inst     = 0.0_MPAS_RKIND
    atm_state%prec_inst     = 0.0_MPAS_RKIND
    atm_state%taux_buf      = 0.0_MPAS_RKIND
    atm_state%tauy_buf      = 0.0_MPAS_RKIND
    atm_state%q2m_buf       = 0.0_MPAS_RKIND
    atm_state%prec_rain_buf = 0.0_MPAS_RKIND
    atm_state%prec_snow_buf = 0.0_MPAS_RKIND

    ! Redirecionar atm_public para buffers computados (em vez de pool diretamente)
    atm_public%swdn_sfc   => atm_state%swdn_inst
    atm_public%lwdn_sfc   => atm_state%lwdn_inst
    atm_public%prec_total => atm_state%prec_inst
    atm_public%taux_sfc   => atm_state%taux_buf
    atm_public%tauy_sfc   => atm_state%tauy_buf
    atm_public%q2m        => atm_state%q2m_buf
    atm_public%prec_rain  => atm_state%prec_rain_buf
    atm_public%prec_snow  => atm_state%prec_snow_buf
  end subroutine init_flux_buffers

  !> Aloca os campos de contorno recebidos do oceano e atribui os valores
  !! usados ate a primeira troca com o mediador.
  !! @param[inout] atm_bnd  campos de contorno oceano-atmosfera
  !! @param[in]    n        numero de celulas locais, com halos
  subroutine init_boundary_arrays(atm_bnd, n)
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,                       intent(in)    :: n

    ! ------------------------------------------------------------------
    ! 8. Aloca arrays de propriedade deste módulo
    !
    ! atm_bnd estendido com uocn/vocn
    ! (correntes superficiais do MOM6+SIS2). Inicializados a zero (oceano
    ! em repouso); preenchidos pelo mediador em mpas_import a cada passo.
    ! ------------------------------------------------------------------
    allocate(atm_bnd%sst         (n), &
             atm_bnd%ice_fraction(n), &
             atm_bnd%uocn        (n), &
             atm_bnd%vocn        (n), &
             atm_bnd%zorl        (n), &
             atm_bnd%alb         (n), &
             atm_bnd%omask       (n))
    atm_bnd%sst          = real(cfg_sst_default,          MPAS_RKIND)
    atm_bnd%ice_fraction = real(cfg_ice_fraction_default, MPAS_RKIND)
    atm_bnd%uocn         = 0.0_MPAS_RKIND  ! corrente zonal
    atm_bnd%vocn         = 0.0_MPAS_RKIND  ! corrente meridional
    atm_bnd%zorl         = real(cfg_zorl_default,         MPAS_RKIND)
    ! default fisico de agua aberta (~0,08) ate a 1a troca real
    ! do mediador. Sem config dedicado (cfg_alb_default) para nao adicionar
    ! mais uma dependencia de namelist so' para um valor de bootstrap.
    atm_bnd%alb          = 0.08_MPAS_RKIND
    ! default 1,0 (tudo oceano) ate a 1a troca real com o
    ! mediador. Mesmo criterio do fallback de is%ocn%omask no MED: se a
    ! mascara nao chegar, o diagnostico sai como saia antes (sem mascarar),
    ! em vez de apagar o globo inteiro.
    atm_bnd%omask        = 1.0_MPAS_RKIND
  end subroutine init_boundary_arrays

  !> Lê streams.atmosphere e registra as streams no stream manager do MPAS,
  !! como faz o mpas_subdriver.F. Sem esta chamada as streams do namelist
  !! não são registradas e as leituras retornam lixo.
  subroutine parse_streams_xml(atm_state, rc)
    use iso_c_binding, only : c_loc, c_ptr, c_int, c_char
    type(mpas_atm_state_type), intent(inout) :: atm_state
    integer, intent(out) :: rc

    interface
      subroutine xml_stream_parser(xmlname, mgr_p, comm, ierr) bind(c)
        use iso_c_binding, only : c_char, c_ptr, c_int
        character(kind=c_char), dimension(*), intent(in)    :: xmlname
        type(c_ptr),                          intent(inout) :: mgr_p
        integer(kind=c_int),                  intent(inout) :: comm
        integer(kind=c_int),                  intent(out)   :: ierr
      end subroutine xml_stream_parser
    end interface

    type(c_ptr)                                  :: mgr_p
    integer(kind=c_int)                          :: c_comm, c_ierr
    character(kind=c_char,len=1), dimension(512) :: c_filename
    integer :: k, slen

    rc = 0

    ! streams_filename como texto C (terminado em caractere nulo)
    slen = len_trim(atm_state%domain%streams_filename)
    do k = 1, slen
      c_filename(k) = atm_state%domain%streams_filename(k:k)
    end do
    c_filename(slen+1) = achar(0)

#ifdef MPAS_USE_MPI_F08
    c_comm = atm_state%domain%dminfo%comm%mpi_val
#else
    c_comm = atm_state%domain%dminfo%comm
#endif
    mgr_p = c_loc(atm_state%domain%streamManager)
    call xml_stream_parser(c_filename, mgr_p, c_comm, c_ierr)
    if (c_ierr /= 0) then
      call mpas_log_write('ERRO: xml_stream_parser falhou para streams.atmosphere', &
                          messageType=MPAS_LOG_CRIT)
      rc = 1
    end if
  end subroutine parse_streams_xml

  !> @brief Registra os atributos globais das saidas no stream manager.
  !!
  !! Copia fiel de add_stream_attributes (mpas_subdriver.F, linha 482) da
  !! arvore MONAN-Model 8.3.1. E chamada por mpas_atm_init no passo 11a, entre
  !! MPAS_stream_mgr_init e setup_immutable_streams, reproduzindo a ordem do
  !! mpas_subdriver.F.
  !!
  !! Registra tres grupos de atributos:
  !!   1. Metadados do nucleo  : model_name, core_name, version, source,
  !!                             Conventions, git_version
  !!   2. Herdados da malha    : on_a_sphere, sphere_radius, is_periodic,
  !!                             x_period, y_period, parent_id, mesh_spec
  !!   3. Opcoes de namelist   : todos os config_*, por iteracao sobre o pool
  !!                             domain%configs, com conversao por tipo
  !!
  !! MANUTENCAO: esta rotina duplica codigo do upstream. Ressincronizar a cada
  !! atualizacao da versao base do MONAN-Model. A divergencia nao produz erro
  !! de compilacao nem de execucao, apenas metadados incompletos nas saidas.
  !!
  !! DIFERENCA INTENCIONAL EM RELACAO AO UPSTREAM: o atributo history usa o
  !! descritor I0 em vez da cadeia de if/else sobre nProcs. O resultado e
  !! identico e o codigo dispensa o limite superior de seis digitos.
  !!
  !! NOTA SOBRE O ACOPLADO: domain%dminfo%nProcs reflete o numero de PETs do
  !! componente ATM, nao o total do job. Em modo concorrente, o atributo
  !! history reportara apenas a particao atmosferica.
  !!
  !! @param[inout] domain  Dominio MPAS, ja com blocklist e streamManager
  !!                       inicializados
  subroutine atm_add_stream_attributes(domain)
    type(domain_type), intent(inout) :: domain

    type(MPAS_Pool_iterator_type)    :: itr
    integer,                 pointer :: intAtt
    logical,                 pointer :: logAtt
    character(len=StrKIND),  pointer :: charAtt
    real(kind=RKIND),        pointer :: realAtt
    character(len=StrKIND)           :: histAtt
    integer                          :: local_ierr

    write(histAtt, '(A,I0,A,A,A)') 'mpirun -n ', domain%dminfo%nProcs, &
         ' ./', trim(domain%core%coreName), '_model'

    ! ── Grupo 1: metadados do nucleo ─────────────────────────────────────────
    call MPAS_stream_mgr_add_att(domain%streamManager, 'model_name',    domain%core%modelName)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'core_name',     domain%core%coreName)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'version',       domain%core%modelVersion)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'source',        domain%core%source)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'Conventions',   domain%core%Conventions)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'git_version',   domain%core%git_version)

    ! ── Grupo 2: atributos herdados da malha ─────────────────────────────────
    call MPAS_stream_mgr_add_att(domain%streamManager, 'on_a_sphere',   domain%on_a_sphere)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'sphere_radius', domain%sphere_radius)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'is_periodic',   domain%is_periodic)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'x_period',      domain%x_period)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'y_period',      domain%y_period)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'history',       histAtt)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'parent_id',     domain%parent_id)
    call MPAS_stream_mgr_add_att(domain%streamManager, 'mesh_spec',     domain%mesh_spec)

    ! ── Grupo 3: opcoes de namelist (config_*) ───────────────────────────────
    call mpas_pool_begin_iteration(domain%configs)

    do while (mpas_pool_get_next_member(domain%configs, itr))

      if (itr%memberType /= MPAS_POOL_CONFIG) cycle

      if (itr%dataType == MPAS_POOL_REAL) then
        call mpas_pool_get_config(domain%configs, itr%memberName, realAtt)
        call MPAS_stream_mgr_add_att(domain%streamManager, itr%memberName, &
             realAtt, ierr=local_ierr)

      else if (itr%dataType == MPAS_POOL_INTEGER) then
        call mpas_pool_get_config(domain%configs, itr%memberName, intAtt)
        call MPAS_stream_mgr_add_att(domain%streamManager, itr%memberName, &
             intAtt, ierr=local_ierr)

      else if (itr%dataType == MPAS_POOL_CHARACTER) then
        call mpas_pool_get_config(domain%configs, itr%memberName, charAtt)
        call MPAS_stream_mgr_add_att(domain%streamManager, itr%memberName, &
             charAtt, ierr=local_ierr)

      else if (itr%dataType == MPAS_POOL_LOGICAL) then
        call mpas_pool_get_config(domain%configs, itr%memberName, logAtt)
        if (logAtt) then
          call MPAS_stream_mgr_add_att(domain%streamManager, itr%memberName, &
               'YES', ierr=local_ierr)
        else
          call MPAS_stream_mgr_add_att(domain%streamManager, itr%memberName, &
               'NO',  ierr=local_ierr)
        end if
      end if

    end do

  end subroutine atm_add_stream_attributes

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

end module mpas_atm_setup_mod
