!> @file mpas_cap_config.F90
!! @brief Leitura de namelists de configuração para o sistema de acoplamento
!!        NUOPC-MPAS-Integrado (MONAN-A 2.0 / ESMF 8.9.1).
!!
!! Módulo central de configuração: lê o arquivo nuopc.input e expõe
!! as variáveis de configuração via ponteiros e acessores públicos.
!!
!! Arquivo de entrada padrão: nuopc.input (no diretório de execução).
!! Caminho alternativo: variável de ambiente NUOPC_INPUT.
!!
!! Estrutura do arquivo nuopc.input:
!!
!!   &nuopc_driver
!!     start_date   = '2026-03-29'
!!     stop_date    = '2026-03-30'
!!     dt_coupling  = 1800
!!     dt_atm       = 60
!!     log_dir      = 'logs'
!!   /
!!
!!   &nuopc_atm
!!     mesh_atm     = 'mpas_mesh.nc'
!!     config_dir   = './'
!!     write_diag   = .false.
!!   /
!!
!!   &nuopc_netcdf
!!     write_netcdf = .true.
!!     output_dir   = 'diag_export'
!!     grid_res_deg = 1.0
!!   /
!!
!!   &nuopc_atm_bnd
!!     sst_default          = 298.0
!!     ice_fraction_default = 0.0
!!     zorl_default         = 0.01
!!   /
!!
!! Versão 1.1 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026.
!!
!! Alterações v1.2 (Sprint B.1 — docn_ice_init_only):
!!   cfg_docn_ice_init_only (.true.) — OISST apenas em InitializeDataComplete
!!     (t=0). Em ModelAdvance (t≥1) usa compute_si_ifrac_proxy (sigmoide da
!!     SST dinâmica do MOM6). Requer cfg_use_docn_ice=.true..
!!
!! Alterações v1.1 (Alternativa 1 — Si_ifrac híbrido):
!!   cfg_use_docn_ice  (.true.) — lê Si_ifrac de arquivo NetCDF OISST
!!     em vez de calcular o proxy sigmoide. Ativado em &nuopc_mode.
!!     Reutiliza cfg_docn_ice_file e cfg_docn_ice_varname já existentes.
!!     Compatível com use_docn=.false. (MOM6 dinâmico ativo).

module mpas_cap_config_mod

  implicit none
  private

  ! ── Constantes ────────────────────────────────────────────────────────────
  character(len=*), parameter, public :: CONFIG_FILE_DEFAULT = 'nuopc.input'
  integer, parameter :: UNITN = 42   ! unidade Fortran para leitura de namelist

  ! ══════════════════════════════════════════════════════════════════════════
  ! Grupo &nuopc_driver — parâmetros do driver NUOPC
  ! ══════════════════════════════════════════════════════════════════════════
  character(len=10), public, protected :: cfg_start_date   = '2026-03-29'
  character(len=10), public, protected :: cfg_stop_date    = '2026-03-30'
  integer,           public, protected :: cfg_dt_coupling  = 1800   ! [s]
  integer,           public, protected :: cfg_dt_atm       = 60     ! [s]
  character(len=256),public, protected :: cfg_log_dir      = 'logs'

  ! ══════════════════════════════════════════════════════════════════════════
  ! Grupo &nuopc_atm — parâmetros do cap atmosférico
  ! ══════════════════════════════════════════════════════════════════════════
  character(len=256),public, protected :: cfg_mesh_atm     = 'mpas_mesh.nc'
  character(len=256),public, protected :: cfg_config_dir   = './'
  logical,           public, protected :: cfg_write_diag   = .false.

  ! ══════════════════════════════════════════════════════════════════════════
  ! Grupo &nuopc_netcdf — parâmetros de saída NetCDF
  ! ══════════════════════════════════════════════════════════════════════════
  logical,           public, protected :: cfg_write_netcdf = .true.  ! ativa escrita NetCDF por passo
  character(len=256),public, protected :: cfg_output_dir   = 'diag_export'
  real,              public, protected :: cfg_grid_res_deg = 1.0    ! [°]

  ! ══════════════════════════════════════════════════════════════════════════
  ! Grupo &nuopc_atm_bnd — defaults de condição de contorno
  ! ══════════════════════════════════════════════════════════════════════════
  real,              public, protected :: cfg_sst_default          = 298.0  ! [K]
  real,              public, protected :: cfg_ice_fraction_default = 0.0    ! [0-1]
  real,              public, protected :: cfg_zorl_default         = 0.01   ! [m]

  ! === &nuopc_docn ===================================================
  ! docn_mode: único modo suportado em produção — 'netcdf'.
  !   Lê SST/gelo/correntes de arquivos NetCDF com interpolação temporal linear.
  character(len=16), public, protected :: cfg_docn_mode        = "netcdf"
  integer,           public, protected :: cfg_docn_nx          = 1440
  integer,           public, protected :: cfg_docn_ny          = 720
  integer,           public, protected :: cfg_docn_dt_data     = 86400
  integer,           public, protected :: cfg_docn_epoch_year  = 1981
  integer,           public, protected :: cfg_docn_epoch_month = 9
  integer,           public, protected :: cfg_docn_epoch_day   = 1
  character(len=256),public, protected :: cfg_docn_sst_file    = "INPUT/OISST_sst.nc"
  character(len=256),public, protected :: cfg_docn_ice_file    = "INPUT/OISST_ice.nc"
  character(len=256),public, protected :: cfg_docn_cur_file    = ""
  ! B-56: nomes das variáveis nos arquivos NetCDF (dependem do produto).
  !   OISST v2.1: sst_varname='sst'  ice_varname='icec'  cur='uo'/'vo'
  !   ERSSTv5   : sst_varname='sst'  ice_varname='sic'
  character(len=64), public, protected :: cfg_docn_sst_varname  = "sst"
  character(len=64), public, protected :: cfg_docn_ice_varname  = "icec"
  character(len=64), public, protected :: cfg_docn_cur_u_varname= "uo"
  character(len=64), public, protected :: cfg_docn_cur_v_varname= "vo"
  ! Unidade do campo de gelo: .false. → fração [0,1] (padrão seguro).
  !   .true. → arquivo em % (0-100), divide por 100.
  !   Verificar: ncdump -h ice_file.nc | grep "units\|scale_factor"
  logical,           public, protected :: cfg_docn_ice_pct      = .false.
  ! Diagnóstico de importação: escreve NetCDF por passo (postproc_mom6_import.py)
  logical,           public, protected :: cfg_write_import_diag   = .false.
  character(len=256),public, protected :: cfg_import_diag_dir     = "diag_import"

  ! ── Grupo &nuopc_ocn — parâmetros do cap MOM6+SIS2 (Migração v7.0) ────────
  character(len=256),public, protected :: cfg_mom6_mesh_ocn    = "INPUT/ocean_hgrid.nc"
  logical,           public, protected :: cfg_mom6_use_mommesh = .false.
  integer,           public, protected :: cfg_mom6_restart_n   = 0

  ! ── Grupo &nuopc_mode — seleção de componentes ────────────────────────────
  !   cfg_use_datm  .true.  → usa DATM (JRA55) como ATM
  !                 .false. → usa MPAS-A real (padrão de produção)
  !   cfg_use_docn  .true.  → usa DOCN (SST/gelo por dados OISST) como OCN
  !                 .false. → usa MOM6+SIS2 dinâmico (padrão de produção)
  logical, public, protected :: cfg_use_datm         = .false.
  logical, public, protected :: cfg_use_docn         = .false.
  !   cfg_use_med_to_mpas .true. → Fase 2 MOM6 dinâmico: MED→MPAS
  !                        .false.→ Fase 1: OCN→MPAS direto (DOCN OISST)
  logical, public, protected :: cfg_use_med_to_mpas  = .false.
  !   cfg_use_docn_ice .true. → Alternativa 1: Si_ifrac lido de arquivo
  !                             NetCDF OISST (cfg_docn_ice_file) mesmo
  !                             com MOM6 dinâmico ativo (use_docn=.false.).
  !              .false.→ proxy sigmoide (Sprint A.5, padrão atual).
  logical, public, protected :: cfg_use_docn_ice      = .false.
  !   cfg_docn_ice_init_only
  !     .true. → Sprint B.1: OISST apenas em InitializeDataComplete (t=0).
  !              ModelAdvance (t≥1) usa compute_si_ifrac_proxy (sigmoide).
  !              Requer cfg_use_docn_ice=.true..
  !     .false.→ comportamento atual: OISST em todos os passos.
  logical, public, protected :: cfg_docn_ice_init_only = .false.

  ! ── API pública ───────────────────────────────────────────────────────────
  public :: config_read
  public :: config_print
  public :: config_parse_date

contains

  !> @brief Lê o arquivo nuopc.input e popula as variáveis de configuração.
  !!
  !! Sequência de busca do arquivo:
  !!   1. Argumento opcional file_path
  !!   2. Variável de ambiente NUOPC_INPUT
  !!   3. nuopc.input no diretório de execução (CONFIG_FILE_DEFAULT)
  !!
  !! @param[out] rc   0 = sucesso; 1 = arquivo não encontrado; 2 = erro de leitura.
  !! @param[in]  file_path  Caminho alternativo (opcional).
  subroutine config_read(rc, file_path)
    ! Nota B-29: esta subrotina é chamada ANTES de ESMF_Initialize (que faz MPI_Init).
    ! NÃO usar MPI aqui. O print de confirmação foi relocado para esmApp.F90.
    integer,          intent(out)          :: rc
    character(len=*), intent(in), optional :: file_path

    ! ── Declarações locais (TODAS antes de qualquer namelist) ─────────────────────
    character(len=10)  :: start_date,   stop_date
    integer            :: dt_coupling,  dt_atm
    character(len=256) :: log_dir
    character(len=256) :: mesh_atm,     config_dir
    logical            :: write_netcdf, write_diag
    character(len=256) :: output_dir
    real               :: grid_res_deg
    real               :: sst_default, ice_fraction_default, zorl_default
    character(len=16)  :: docn_mode
    integer            :: docn_nx, docn_ny, docn_dt_data
    integer            :: docn_epoch_year, docn_epoch_month, docn_epoch_day
    character(len=256) :: docn_sst_file, docn_ice_file, docn_cur_file
    character(len=64)  :: docn_sst_varname, docn_ice_varname
    character(len=64)  :: docn_cur_u_varname, docn_cur_v_varname
    logical            :: docn_ice_pct
    logical            :: write_import_diag
    character(len=256) :: import_diag_dir

    ! ── Migração v7.0: namelist para MOM6+SIS2 ────────────────────────────────
    ! [FIX-NAMELIST] Nomes das variáveis locais alinhados aos rótulos do
    ! arquivo nuopc.input (mesh_ocn, use_mommesh, restart_n — sem prefixo
    ! mom6_). O bug anterior fazia o namelist /nuopc_ocn/ ser invisível ao
    ! parser Fortran (rótulos não-correspondentes → ios /= 0 → defaults
    ! aplicados silenciosamente), gerando o aviso recorrente
    ! "&nuopc_ocn ausente" mesmo com o grupo presente.
    character(len=256) :: mesh_ocn    = "INPUT/ocean_hgrid.nc"
    logical            :: use_mommesh = .false.
    integer            :: restart_n   = 0

    character(len=512) :: fpath
    logical :: file_exists
    integer :: ios



    namelist /nuopc_docn/ docn_mode, docn_nx, docn_ny, docn_dt_data, &
                             docn_epoch_year, docn_epoch_month, docn_epoch_day, &
                             docn_sst_file, docn_ice_file, docn_cur_file, &
                             docn_sst_varname, docn_ice_varname, &
                             docn_cur_u_varname, docn_cur_v_varname, &
                             docn_ice_pct, write_import_diag, import_diag_dir
    namelist /nuopc_driver/ start_date, stop_date, dt_coupling, dt_atm, log_dir
    namelist /nuopc_atm/    mesh_atm, config_dir, write_diag
    namelist /nuopc_netcdf/ write_netcdf, output_dir, grid_res_deg
    namelist /nuopc_atm_bnd/sst_default, ice_fraction_default, zorl_default
    namelist /nuopc_ocn/    mesh_ocn, use_mommesh, restart_n

    ! &nuopc_mode — declarações locais para ativação de dados sintéticos
    logical :: use_datm         = .false.
    logical :: use_docn         = .false.
    logical :: use_med_to_mpas  = .false.
    logical :: use_docn_ice         = .false.  ! Alternativa 1
    logical :: docn_ice_init_only   = .false.  ! Sprint B.1
    namelist /nuopc_mode/ use_datm, use_docn, use_med_to_mpas, &
                          use_docn_ice, docn_ice_init_only

    rc = 0

    ! ── 1. Inicializar locais com os defaults do módulo ───────────────────
    start_date          = cfg_start_date
    stop_date           = cfg_stop_date
    dt_coupling         = cfg_dt_coupling
    dt_atm              = cfg_dt_atm
    log_dir             = cfg_log_dir
    mesh_atm            = cfg_mesh_atm
    config_dir          = cfg_config_dir
    write_netcdf        = cfg_write_netcdf
    write_diag          = cfg_write_diag
    output_dir          = cfg_output_dir
    grid_res_deg        = cfg_grid_res_deg
    sst_default         = cfg_sst_default
    ice_fraction_default= cfg_ice_fraction_default
    zorl_default        = cfg_zorl_default
    docn_mode        = cfg_docn_mode
    docn_nx          = cfg_docn_nx
    docn_ny          = cfg_docn_ny
    docn_dt_data     = cfg_docn_dt_data
    docn_epoch_year  = cfg_docn_epoch_year
    docn_epoch_month = cfg_docn_epoch_month
    docn_epoch_day   = cfg_docn_epoch_day
    docn_sst_file    = cfg_docn_sst_file
    docn_ice_file    = cfg_docn_ice_file
    docn_cur_file    = cfg_docn_cur_file
    docn_sst_varname   = cfg_docn_sst_varname
    docn_ice_varname   = cfg_docn_ice_varname
    docn_cur_u_varname = cfg_docn_cur_u_varname
    docn_cur_v_varname = cfg_docn_cur_v_varname
    docn_ice_pct       = cfg_docn_ice_pct
    write_import_diag    = cfg_write_import_diag
    import_diag_dir      = cfg_import_diag_dir

    ! ── 2. Determinar caminho do arquivo ─────────────────────────────────
    if (present(file_path) .and. len_trim(file_path) > 0) then
      fpath = trim(file_path)
    else
      call get_environment_variable('NUOPC_INPUT', fpath, status=ios)
      if (ios /= 0 .or. len_trim(fpath) == 0) fpath = CONFIG_FILE_DEFAULT
    end if

    inquire(file=trim(fpath), exist=file_exists)
    if (.not. file_exists) then
      write(*,'(A,A,A)') '[mpas_cap_config] AVISO: arquivo "', &
        trim(fpath), '" nao encontrado — usando defaults.'
      rc = 1
      return
    end if

    ! ── 3. Abrir e ler cada grupo ─────────────────────────────────────────
    open(unit=UNITN, file=trim(fpath), status='old', action='read', &
         form='formatted', iostat=ios)
    if (ios /= 0) then
      write(*,'(A,A)') '[mpas_cap_config] ERRO: nao foi possivel abrir ', trim(fpath)
      rc = 2; return
    end if

    ! &nuopc_driver
    rewind(UNITN)
    read(UNITN, nml=nuopc_driver, iostat=ios)
    if (ios /= 0) write(*,'(A)') &
      '[mpas_cap_config] AVISO: grupo &nuopc_driver ausente ou com erro — usando defaults.'

    ! &nuopc_atm
    rewind(UNITN)
    read(UNITN, nml=nuopc_atm, iostat=ios)
    if (ios /= 0) write(*,'(A)') &
      '[mpas_cap_config] AVISO: grupo &nuopc_atm ausente ou com erro — usando defaults.'

    ! &nuopc_netcdf
    rewind(UNITN)
    read(UNITN, nml=nuopc_netcdf, iostat=ios)
    if (ios /= 0) write(*,'(A)') &
      '[mpas_cap_config] AVISO: grupo &nuopc_netcdf ausente ou com erro — usando defaults.'

    ! &nuopc_atm_bnd
    rewind(UNITN)
    read(UNITN, nml=nuopc_atm_bnd, iostat=ios)
    if (ios /= 0) write(*,'(A)') &
      '[mpas_cap_config] AVISO: grupo &nuopc_atm_bnd ausente ou com erro — usando defaults.'

    ! ── &nuopc_docn -- ANTES do close para evitar fort.42
    rewind(UNITN)
    read(UNITN, nml=nuopc_docn, iostat=ios)
    if (ios /= 0) write(*,'(A)') &
      '[mpas_cap_config] AVISO: &nuopc_docn ausente -- usando defaults ' // &
      '(docn_mode=netcdf, OISST 1440x720, epoch=1981-09-01).'
    cfg_docn_mode        = trim(docn_mode)
    cfg_docn_nx          = docn_nx
    cfg_docn_ny          = docn_ny
    cfg_docn_dt_data     = docn_dt_data
    cfg_docn_epoch_year  = docn_epoch_year
    cfg_docn_epoch_month = docn_epoch_month
    cfg_docn_epoch_day   = docn_epoch_day
    cfg_docn_sst_file    = trim(docn_sst_file)
    cfg_docn_ice_file    = trim(docn_ice_file)
    cfg_docn_cur_file    = trim(docn_cur_file)
    cfg_docn_sst_varname   = trim(docn_sst_varname)
    cfg_docn_ice_varname   = trim(docn_ice_varname)
    cfg_docn_cur_u_varname = trim(docn_cur_u_varname)
    cfg_docn_cur_v_varname = trim(docn_cur_v_varname)
    cfg_docn_ice_pct       = docn_ice_pct
    cfg_write_import_diag    = write_import_diag
    cfg_import_diag_dir      = trim(import_diag_dir)

    ! ── Validação do docn_mode: somente 'netcdf' é suportado em produção ─────
    if (trim(cfg_docn_mode) /= 'netcdf') then
      write(*,'(A,A,A)') '[mpas_cap_config] ERRO: docn_mode="', &
        trim(cfg_docn_mode), '" invalido — somente ''netcdf'' e suportado.'
      rc = 2; return
    end if

    ! ── &nuopc_mode — ativação de dados sintéticos DATM / DOCN ────────────
    rewind(UNITN)
    read(UNITN, nml=nuopc_mode, iostat=ios)
    if (ios /= 0) then
      write(*,'(A)') &
        '[mpas_cap_config] INFO: &nuopc_mode ausente — use_datm=F, use_docn=F (MPAS+MOM6).'
    else
      cfg_use_datm            = use_datm
      cfg_use_docn            = use_docn
      cfg_use_med_to_mpas     = use_med_to_mpas
      cfg_use_docn_ice        = use_docn_ice
      cfg_docn_ice_init_only  = docn_ice_init_only
    end if

    ! ── Migração v7.0: leitura do grupo &nuopc_ocn (MOM6+SIS2) ──────────────
    ! Pré-carrega defaults do módulo para que a leitura preserve valores
    ! existentes caso o arquivo só sobrescreva um subconjunto dos campos.
    mesh_ocn    = cfg_mom6_mesh_ocn
    use_mommesh = cfg_mom6_use_mommesh
    restart_n   = cfg_mom6_restart_n

    rewind(UNITN)
    read(UNITN, nml=nuopc_ocn, iostat=ios)
    if (ios /= 0) write(*,'(A)') &
      '[mpas_cap_config] AVISO: &nuopc_ocn ausente — defaults MOM6 ativos' // &
      ' (mesh_ocn=INPUT/ocean_hgrid.nc, use_mommesh=F, restart_n=0).'

    cfg_mom6_mesh_ocn    = trim(mesh_ocn)
    cfg_mom6_use_mommesh = use_mommesh
    cfg_mom6_restart_n   = restart_n

    ! ── Validação: Alternativa 1 — Si_ifrac via arquivo OISST ────────────
    ! cfg_use_docn_ice=.true. exige cfg_docn_ice_file configurado.
    ! O arquivo é lido por ReadOcnFieldInterp em mom_cap.F90.
    if (cfg_use_docn_ice .and. len_trim(cfg_docn_ice_file) == 0) then
      write(*,'(A)') '[mpas_cap_config] ERRO: use_docn_ice=T mas ' // &
        'docn_ice_file nao configurado em &nuopc_docn.'
      rc = 2; return
    end if
    ! Sprint B.1: docn_ice_init_only requer use_docn_ice=.true.
    if (cfg_docn_ice_init_only .and. .not. cfg_use_docn_ice) then
      write(*,'(A)') '[mpas_cap_config] ERRO: docn_ice_init_only=T ' // &
        'requer use_docn_ice=T em &nuopc_mode.'
      rc = 2; return
    end if
    ! ── Fim Migração v7.0 ──────────────────────────────────────────────────────

    close(UNITN)

    ! ── 4. Validação básica ───────────────────────────────────────────────
    if (dt_coupling <= 0) then
      write(*,'(A,I0)') '[mpas_cap_config] ERRO: dt_coupling invalido: ', dt_coupling
      rc = 2; return
    end if
    if (dt_atm <= 0 .or. dt_atm > dt_coupling) then
      write(*,'(A,I0,A,I0)') '[mpas_cap_config] AVISO: dt_atm=', dt_atm, &
        ' deve ser <= dt_coupling=', dt_coupling
    end if
    if (mod(dt_coupling, dt_atm) /= 0) then
      write(*,'(A)') '[mpas_cap_config] AVISO: dt_coupling nao e multiplo de dt_atm.'
    end if
    if (grid_res_deg <= 0.0 .or. grid_res_deg > 10.0) then
      write(*,'(A)') '[mpas_cap_config] AVISO: grid_res_deg fora do intervalo (0,10]. Usando 1.0.'
      grid_res_deg = 1.0
    end if
    if (sst_default < 150.0 .or. sst_default > 350.0) then
      write(*,'(A,F7.2)') '[mpas_cap_config] AVISO: sst_default fora do intervalo fisico: ', &
        sst_default
    end if

    ! ── 5. Copiar para variáveis de módulo ────────────────────────────────
    cfg_start_date           = start_date
    cfg_stop_date            = stop_date
    cfg_dt_coupling          = dt_coupling
    cfg_dt_atm               = dt_atm
    cfg_log_dir              = trim(log_dir)
    cfg_mesh_atm             = trim(mesh_atm)
    cfg_config_dir           = trim(config_dir)
    cfg_write_diag           = write_diag
    cfg_write_netcdf         = write_netcdf
    cfg_output_dir           = trim(output_dir)
    cfg_grid_res_deg         = grid_res_deg
    cfg_sst_default          = sst_default
    cfg_ice_fraction_default = ice_fraction_default
    cfg_zorl_default         = zorl_default

    ! B-29: config_read() é chamado ANTES de ESMF_Initialize() (que faz MPI_Init),
    ! portanto MPI_Comm_rank aqui causaria "MPI not initialized" em todos os ranks.
    ! O print foi movido para esmApp.F90 após ESMF_VMGet, onde localPet já está
    ! disponível — somente PET 0 imprime.
    ! Não há write(*) aqui: silencioso em todos os ranks.

  end subroutine config_read

  !> @brief Imprime o resumo da configuração ativa no stdout.
  subroutine config_print()
    write(*,'(/,A)') '=============================================='
    write(*,'(A)')   ' Configuracao NUOPC-MPAS-Integrado (nuopc.input)'
    write(*,'(A)')   '=============================================='
    write(*,'(A,A)') '  [nuopc_driver]'
    write(*,'(2X,A,A)')  '  start_date        = ', trim(cfg_start_date)
    write(*,'(2X,A,A)')  '  stop_date         = ', trim(cfg_stop_date)
    write(*,'(2X,A,I0)') '  dt_coupling       = ', cfg_dt_coupling
    write(*,'(2X,A,I0)') '  dt_atm            = ', cfg_dt_atm
    write(*,'(2X,A,A)')  '  log_dir           = ', trim(cfg_log_dir)
    write(*,'(A)') ''
    write(*,'(A,A)') '  [nuopc_atm]'
    write(*,'(2X,A,A)')  '  mesh_atm          = ', trim(cfg_mesh_atm)
    write(*,'(2X,A,A)')  '  config_dir        = ', trim(cfg_config_dir)
    write(*,'(2X,A,L1)') '  write_diag        = ', cfg_write_diag
    write(*,'(A)') ''
    write(*,'(A,A)') '  [nuopc_netcdf]'
    write(*,'(2X,A,L1)') '  write_netcdf      = ', cfg_write_netcdf
    write(*,'(2X,A,A)')    '  output_dir        = ', trim(cfg_output_dir)
    write(*,'(2X,A,F5.2)') '  grid_res_deg      = ', cfg_grid_res_deg
    write(*,'(A)') ''
    write(*,'(A,A)') '  [nuopc_atm_bnd]'
    write(*,'(2X,A,F7.2)') '  sst_default       = ', cfg_sst_default
    write(*,'(2X,A,F5.3)') '  ice_frac_default  = ', cfg_ice_fraction_default
    write(*,'(2X,A,F6.4)') '  zorl_default      = ', cfg_zorl_default
    write(*,'(A,/)') '=============================================='

    write(*,'(A)') '  [nuopc_docn]'
    write(*,'(2X,A,A)')  '  docn_mode       = ', trim(cfg_docn_mode)
    write(*,'(2X,A,I5,A,I5)') '  grid nx x ny  = ',cfg_docn_nx,' x ',cfg_docn_ny
    write(*,'(2X,A,A)')  '  sst_file          = ', trim(cfg_docn_sst_file)
    write(*,'(2X,A,A)')  '  sst_varname       = ', trim(cfg_docn_sst_varname)
    write(*,'(2X,A,A)')  '  ice_file          = ', trim(cfg_docn_ice_file)
    write(*,'(2X,A,A)')  '  ice_varname       = ', trim(cfg_docn_ice_varname)
    write(*,'(2X,A,L1)') '  ice_pct           = ', cfg_docn_ice_pct
    write(*,'(2X,A,A)')  '  cur_file          = ', trim(cfg_docn_cur_file)
    write(*,'(2X,A,L1)') '  write_import_diag = ', cfg_write_import_diag
    write(*,'(2X,A,A)')  '  import_diag_dir   = ', trim(cfg_import_diag_dir)
    ! ── Migração v7.0: impressão do grupo &nuopc_ocn ─────────────────────────
    write(*,'(A)') '&nuopc_ocn'
    write(*,'(2X,A,A)')  '  mesh_ocn      = ', trim(cfg_mom6_mesh_ocn)
    write(*,'(2X,A,L1)') '  use_mommesh   = ', cfg_mom6_use_mommesh
    write(*,'(2X,A,I0)') '  restart_n     = ', cfg_mom6_restart_n
    write(*,'(A)') '  --- Componentes ativos ---'
    write(*,'(2X,A,L1)') 'cfg_use_datm         = ', cfg_use_datm
    write(*,'(2X,A,L1)') 'cfg_use_docn         = ', cfg_use_docn
    write(*,'(2X,A,L1)') 'cfg_use_med_to_mpas  = ', cfg_use_med_to_mpas
    write(*,'(2X,A,L1)') 'cfg_use_docn_ice     = ', cfg_use_docn_ice
    write(*,'(2X,A,L1)') 'cfg_docn_ice_init_only= ', cfg_docn_ice_init_only
  end subroutine config_print

  !> @brief Converte string 'YYYY-MM-DD' para componentes inteiros.
  !!
  !! @param[in]  date_str  String no formato 'YYYY-MM-DD'
  !! @param[out] yy, mm, dd Componentes extraídos
  !! @param[out] rc  0 = sucesso; 1 = formato inválido
  subroutine config_parse_date(date_str, yy, mm, dd, rc)
    character(len=*), intent(in)  :: date_str
    integer,          intent(out) :: yy, mm, dd, rc
    integer :: ios

    rc = 0
    if (len_trim(date_str) < 10) then
      rc = 1; return
    end if

    read(date_str(1:4),  '(I4)', iostat=ios) yy
    if (ios /= 0) then; rc = 1; return; end if
    read(date_str(6:7),  '(I2)', iostat=ios) mm
    if (ios /= 0) then; rc = 1; return; end if
    read(date_str(9:10), '(I2)', iostat=ios) dd
    if (ios /= 0) then; rc = 1; return; end if

    if (mm < 1 .or. mm > 12 .or. dd < 1 .or. dd > 31) rc = 1
  end subroutine config_parse_date

end module mpas_cap_config_mod
