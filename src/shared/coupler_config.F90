!> @file coupler_config.F90
!! @brief Leitura e validação da configuração do acoplador (arquivo nuopc.input).
!!
!! A configuração é lida uma única vez, por esmApp.F90, antes de
!! ESMF_Initialize. Por isso esta rotina não usa MPI nem ESMF: as mensagens
!! vão para a saída padrão. Depois da leitura, os demais módulos consultam
!! as variáveis cfg_* (somente leitura, atributo protected).
!!
!! Grupos do namelist e o que controlam:
!!   &nuopc_driver     datas, passo de acoplamento, diretório e tipo de log
!!   &nuopc_mode       quais componentes de dados (DATM/DOCN) substituem modelos
!!   &nuopc_atm        malha e diretório de configuração do MONAN-A
!!   &nuopc_netcdf     escrita dos NetCDF exportados pelo cap ATM
!!   &nuopc_atm_bnd    valores padrão de contorno da atmosfera
!!   &nuopc_docn       arquivos e grade do oceano de dados (OISST)
!!   &nuopc_ocn        arquivo de grade do MOM6
!!   &nuopc_petlayout  modo de acoplamento e divisão de PETs
!!   &nuopc_regrid     (opcional) esquema de interpolação por rota
!!
!! Os valores padrão formam a configuração de produção: MONAN-A, MOM6 e
!! SIS2, com o contorno da atmosfera pelo mediador. Que combinações de
!! componentes são aceitas está na tabela COUPLER_MODES, abaixo.
!!
!! Regras de leitura:
!!   - grupo ausente do arquivo: mantém os valores padrão, com aviso;
!!   - grupo presente mas com erro (chave desconhecida, valor inválido):
!!     erro fatal, para que um erro de digitação não passe despercebido.
!!
!! Códigos de retorno de config_read: 0 = sucesso; 1 = arquivo inexistente
!! (valores padrão); 2 = erro fatal.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module coupler_config_mod

  use coupler_utils_mod, only : str_lower

  implicit none
  private

  public :: config_read
  public :: config_parse_date

  character(len=*), parameter, public :: CONFIG_FILE_DEFAULT = 'nuopc.input'

  integer, parameter :: CFG_OK = 0, CFG_NO_FILE = 1, CFG_FATAL = 2
  character(len=*), parameter :: TAG = '[coupler_config] '

  ! &nuopc_driver
  character(len=10),  public, protected :: cfg_start_date   = '2026-03-29'
  character(len=10),  public, protected :: cfg_stop_date    = '2026-03-30'
  integer,            public, protected :: cfg_dt_coupling  = 1800        ! [s]
  integer,            public, protected :: cfg_dt_atm       = 60          ! [s]
  character(len=256), public, protected :: cfg_log_dir      = 'logs'
  character(len=16),  public, protected :: cfg_log_kind     = 'multi'     ! multi | multi_on_error
  logical,            public, protected :: cfg_write_fixdiag = .true.

  ! &nuopc_atm
  character(len=256), public, protected :: cfg_mesh_atm     = 'mpas_mesh.nc'
  character(len=256), public, protected :: cfg_config_dir   = './'
  logical,            public, protected :: cfg_write_diag   = .false.

  ! &nuopc_netcdf
  logical,            public, protected :: cfg_write_netcdf = .true.
  character(len=256), public, protected :: cfg_output_dir   = 'diag_export'
  real,               public, protected :: cfg_grid_res_deg = 1.0         ! [grau]

  ! &nuopc_atm_bnd
  real,               public, protected :: cfg_sst_default          = 298.0  ! [K]
  real,               public, protected :: cfg_ice_fraction_default = 0.0    ! [0-1]
  real,               public, protected :: cfg_zorl_default         = 0.01   ! [m]

  ! &nuopc_docn
  character(len=16),  public, protected :: cfg_docn_mode          = 'netcdf'
  integer,            public, protected :: cfg_docn_nx            = 1440
  integer,            public, protected :: cfg_docn_ny            = 720
  integer,            public, protected :: cfg_docn_dt_data       = 86400  ! [s]
  integer,            public, protected :: cfg_docn_epoch_year    = 1981
  integer,            public, protected :: cfg_docn_epoch_month   = 9
  integer,            public, protected :: cfg_docn_epoch_day     = 1
  character(len=256), public, protected :: cfg_docn_sst_file      = 'INPUT/OISST_sst.nc'
  character(len=256), public, protected :: cfg_docn_ice_file      = 'INPUT/OISST_ice.nc'
  character(len=256), public, protected :: cfg_docn_cur_file      = ''
  character(len=64),  public, protected :: cfg_docn_sst_varname   = 'sst'
  character(len=64),  public, protected :: cfg_docn_ice_varname   = 'icec'
  character(len=64),  public, protected :: cfg_docn_cur_u_varname = 'uo'
  character(len=64),  public, protected :: cfg_docn_cur_v_varname = 'vo'
  logical,            public, protected :: cfg_docn_ice_pct       = .false.
  logical,            public, protected :: cfg_write_import_diag  = .false.
  character(len=256), public, protected :: cfg_import_diag_dir    = 'diag_import'

  ! &nuopc_ocn
  character(len=256), public, protected :: cfg_mom6_mesh_ocn  = 'INPUT/ocean_hgrid.nc'

  ! &nuopc_petlayout
  character(len=16),  public, protected :: cfg_coupling_mode    = 'sequential'  ! sequential | concurrent
  character(len=16),  public, protected :: cfg_pet_layout       = 'shared'      ! shared | split
  integer,            public, protected :: cfg_atm_pet_count    = 0
  integer,            public, protected :: cfg_ocn_pet_count    = 0
  integer,            public, protected :: cfg_ice_pet_count    = 0
  logical,            public, protected :: cfg_use_sis2_dynamic = .true.
  logical,            public, protected :: cfg_seq_repro        = .false.

  ! &nuopc_mode
  logical,            public, protected :: cfg_use_datm           = .false.
  logical,            public, protected :: cfg_use_docn           = .false.
  logical,            public, protected :: cfg_use_med_to_mpas    = .true.
  logical,            public, protected :: cfg_use_docn_ice       = .false.
  logical,            public, protected :: cfg_docn_ice_init_only = .false.

  ! &nuopc_regrid (opcional): troca do esquema de interpolação por rota.
  ! Entradas vazias mantêm a configuração padrão da rota.
  integer, parameter, public :: MAX_REGRID_OVERRIDES = 16
  character(len=32),  public, protected :: cfg_regrid_route(MAX_REGRID_OVERRIDES)   = ''
  character(len=32),  public, protected :: cfg_regrid_scheme(MAX_REGRID_OVERRIDES)  = ''
  character(len=64),  public, protected :: cfg_regrid_methods(MAX_REGRID_OVERRIDES) = ''
  character(len=256), public, protected :: cfg_regrid_weights(MAX_REGRID_OVERRIDES) = ''
  character(len=32),  public, protected :: cfg_regrid_class(MAX_REGRID_OVERRIDES)   = ''
  character(len=128), public, protected :: cfg_regrid_options(MAX_REGRID_OVERRIDES) = ''

  !--------------------------------------------------------------------------
  ! Configurações de componentes
  !--------------------------------------------------------------------------
  ! As quatro chaves que escolhem os componentes (use_datm, use_docn e
  ! use_med_to_mpas, de &nuopc_mode, e use_sis2_dynamic, de
  ! &nuopc_petlayout) formam 16 combinações. Esta tabela diz o que acontece
  ! com cada uma, e é o único lugar onde essa regra está escrita: config_read
  ! a consulta para aceitar ou recusar a rodada, o mapa de acoplamento
  ! (cpl_config_is_valid) só considera as combinações aceitas, e
  ! tools/dev/mapa-acoplamento.py a lê para a documentação.
  !
  ! Situações:
  !   'suportada'     validada a cada etapa da refatoração (a de produção) ou
  !                   esperada sem diferença dela (a mesma sem o SIS2)
  !   'nao_validada'  aceita, com aviso no início da rodada; a nota diz o
  !                   problema conhecido (docs/estado-do-projeto.md, seção 6)
  !   'recusada'      a rodada para na leitura; a nota é a mensagem de erro e
  !                   diz o que mudar
  type, public :: coupler_mode_t
    logical            :: datm
    logical            :: docn
    logical            :: med_to_mpas
    logical            :: sis2
    character(len=16)  :: status
    character(len=128) :: note
  end type coupler_mode_t

  character(len=*), parameter :: NOTE_MOM6_DIRECT = &
    'use_docn=.false. (MOM6) exige use_med_to_mpas=.true.; o MOM6 nao exporta o contorno da atmosfera.'
  character(len=*), parameter :: NOTE_SIS2_DOCN = &
    'use_sis2_dynamic=.true. exige use_docn=.false. (SIS2 precisa do MOM6).'
  character(len=*), parameter :: NOTE_DATM = &
    'o driver nao registra o DATM; o componente ATM continua sendo o MONAN-A.'

  type(coupler_mode_t), parameter, public :: COUPLER_MODES(*) = [                                      &
    !              datm     docn     med_to_mpas sis2   situação        nota
    coupler_mode_t(.false., .false., .true.,  .true.,  'suportada',    'producao: MONAN-A, MOM6 e SIS2, ' // &
                                                                       'contorno pelo mediador'),           &
    coupler_mode_t(.false., .false., .true.,  .false., 'suportada',    'MONAN-A e MOM6 sem o SIS2, ' //     &
                                                                       'contorno pelo mediador'),           &
    coupler_mode_t(.false., .true.,  .false., .false., 'nao_validada', 'o DOCN nao exporta Sx_tsfc, ' //    &
                                                                       'Sf_albedo e Sx_omask, que o MONAN-A importa.'), &
    coupler_mode_t(.false., .true.,  .true.,  .false., 'nao_validada', 'DOCN com contorno pelo mediador ' // &
                                                                       'nunca foi executado.'),             &
    coupler_mode_t(.true.,  .false., .true.,  .true.,  'nao_validada', NOTE_DATM),                          &
    coupler_mode_t(.true.,  .false., .true.,  .false., 'nao_validada', NOTE_DATM),                          &
    coupler_mode_t(.true.,  .true.,  .false., .false., 'nao_validada', NOTE_DATM),                          &
    coupler_mode_t(.true.,  .true.,  .true.,  .false., 'nao_validada', NOTE_DATM),                          &
    coupler_mode_t(.false., .false., .false., .true.,  'recusada',     NOTE_MOM6_DIRECT),                   &
    coupler_mode_t(.false., .false., .false., .false., 'recusada',     NOTE_MOM6_DIRECT),                   &
    coupler_mode_t(.true.,  .false., .false., .true.,  'recusada',     NOTE_MOM6_DIRECT),                   &
    coupler_mode_t(.true.,  .false., .false., .false., 'recusada',     NOTE_MOM6_DIRECT),                   &
    coupler_mode_t(.false., .true.,  .false., .true.,  'recusada',     NOTE_SIS2_DOCN),                     &
    coupler_mode_t(.false., .true.,  .true.,  .true.,  'recusada',     NOTE_SIS2_DOCN),                     &
    coupler_mode_t(.true.,  .true.,  .false., .true.,  'recusada',     NOTE_SIS2_DOCN),                     &
    coupler_mode_t(.true.,  .true.,  .true.,  .true.,  'recusada',     NOTE_SIS2_DOCN) ]

  public :: coupler_mode_index

contains

  !> Posição em COUPLER_MODES da combinação das quatro chaves. A tabela tem
  !! as 16 combinações (conferido por tests/unit/test_cpl_map.F90), então o
  !! resultado nunca é 0.
  pure integer function coupler_mode_index(datm, docn, med_to_mpas, sis2) result(k)
    logical, intent(in) :: datm, docn, med_to_mpas, sis2
    integer :: i

    k = 0
    do i = 1, size(COUPLER_MODES)
      if ((COUPLER_MODES(i)%datm .eqv. datm) .and. (COUPLER_MODES(i)%docn .eqv. docn) .and. &
          (COUPLER_MODES(i)%med_to_mpas .eqv. med_to_mpas) .and.                            &
          (COUPLER_MODES(i)%sis2 .eqv. sis2)) then
        k = i
        return
      end if
    end do
  end function coupler_mode_index

  !> Lê o arquivo de configuração e preenche as variáveis cfg_*.
  !!
  !! @param[out] rc         0 sucesso, 1 arquivo ausente, 2 erro fatal
  !! @param[in]  file_path  caminho opcional; senão usa a variável de
  !!                        ambiente NUOPC_INPUT ou 'nuopc.input'
  subroutine config_read(rc, file_path)
    integer,          intent(out)          :: rc
    character(len=*), intent(in), optional :: file_path

    ! Variáveis locais com os mesmos nomes das chaves do arquivo
    character(len=10)  :: start_date, stop_date
    integer            :: dt_coupling, dt_atm
    character(len=256) :: log_dir
    character(len=16)  :: log_kind
    logical            :: write_fixdiag
    character(len=256) :: mesh_atm, config_dir
    logical            :: write_diag, write_netcdf
    character(len=256) :: output_dir
    real               :: grid_res_deg
    real               :: sst_default, ice_fraction_default, zorl_default
    character(len=16)  :: docn_mode
    integer            :: docn_nx, docn_ny, docn_dt_data
    integer            :: docn_epoch_year, docn_epoch_month, docn_epoch_day
    character(len=256) :: docn_sst_file, docn_ice_file, docn_cur_file
    character(len=64)  :: docn_sst_varname, docn_ice_varname
    character(len=64)  :: docn_cur_u_varname, docn_cur_v_varname
    logical            :: docn_ice_pct, write_import_diag
    character(len=256) :: import_diag_dir
    character(len=256) :: mesh_ocn
    integer            :: restart_n                  ! chave obsoleta, sem efeito
    logical            :: use_mommesh                ! chave obsoleta, sem efeito
    logical            :: use_datm, use_docn, use_med_to_mpas
    logical            :: use_docn_ice, docn_ice_init_only
    character(len=16)  :: coupling_mode, pet_layout
    integer            :: atm_pet_count, ocn_pet_count, ice_pet_count
    logical            :: use_sis2_dynamic, seq_repro
    character(len=32)  :: regrid_route(MAX_REGRID_OVERRIDES), regrid_scheme(MAX_REGRID_OVERRIDES)
    character(len=64)  :: regrid_methods(MAX_REGRID_OVERRIDES)
    character(len=256) :: regrid_weights(MAX_REGRID_OVERRIDES)
    character(len=32)  :: regrid_class(MAX_REGRID_OVERRIDES)
    character(len=128) :: regrid_options(MAX_REGRID_OVERRIDES)

    namelist /nuopc_driver/    start_date, stop_date, dt_coupling, dt_atm, &
                               log_dir, log_kind, write_fixdiag
    namelist /nuopc_atm/       mesh_atm, config_dir, write_diag
    namelist /nuopc_netcdf/    write_netcdf, output_dir, grid_res_deg
    namelist /nuopc_atm_bnd/   sst_default, ice_fraction_default, zorl_default
    namelist /nuopc_docn/      docn_mode, docn_nx, docn_ny, docn_dt_data,       &
                               docn_epoch_year, docn_epoch_month, docn_epoch_day, &
                               docn_sst_file, docn_ice_file, docn_cur_file,     &
                               docn_sst_varname, docn_ice_varname,              &
                               docn_cur_u_varname, docn_cur_v_varname,          &
                               docn_ice_pct, write_import_diag, import_diag_dir
    namelist /nuopc_ocn/       mesh_ocn, use_mommesh, restart_n
    namelist /nuopc_mode/      use_datm, use_docn, use_med_to_mpas, &
                               use_docn_ice, docn_ice_init_only
    namelist /nuopc_petlayout/ coupling_mode, pet_layout, atm_pet_count, &
                               ocn_pet_count, ice_pet_count, use_sis2_dynamic, &
                               seq_repro
    namelist /nuopc_regrid/    regrid_route, regrid_scheme, regrid_methods, &
                               regrid_weights, regrid_class, regrid_options

    character(len=512) :: fpath
    logical :: exists, is_root
    integer :: unit, ios
    integer :: mode               ! posição da combinação em COUPLER_MODES

    rc = CFG_OK
    is_root = launcher_rank() == 0

    ! 1. Valores iniciais = valores atuais do módulo (padrões na 1a leitura)
    start_date = cfg_start_date;  stop_date = cfg_stop_date
    dt_coupling = cfg_dt_coupling; dt_atm = cfg_dt_atm
    log_dir = cfg_log_dir;  log_kind = cfg_log_kind;  write_fixdiag = cfg_write_fixdiag
    mesh_atm = cfg_mesh_atm;  config_dir = cfg_config_dir;  write_diag = cfg_write_diag
    write_netcdf = cfg_write_netcdf;  output_dir = cfg_output_dir
    grid_res_deg = cfg_grid_res_deg
    sst_default = cfg_sst_default;  ice_fraction_default = cfg_ice_fraction_default
    zorl_default = cfg_zorl_default
    docn_mode = cfg_docn_mode;  docn_nx = cfg_docn_nx;  docn_ny = cfg_docn_ny
    docn_dt_data = cfg_docn_dt_data
    docn_epoch_year = cfg_docn_epoch_year;  docn_epoch_month = cfg_docn_epoch_month
    docn_epoch_day = cfg_docn_epoch_day
    docn_sst_file = cfg_docn_sst_file;  docn_ice_file = cfg_docn_ice_file
    docn_cur_file = cfg_docn_cur_file
    docn_sst_varname = cfg_docn_sst_varname;  docn_ice_varname = cfg_docn_ice_varname
    docn_cur_u_varname = cfg_docn_cur_u_varname
    docn_cur_v_varname = cfg_docn_cur_v_varname
    docn_ice_pct = cfg_docn_ice_pct
    write_import_diag = cfg_write_import_diag;  import_diag_dir = cfg_import_diag_dir
    mesh_ocn = cfg_mom6_mesh_ocn
    restart_n = 0;  use_mommesh = .false.
    use_datm = cfg_use_datm;  use_docn = cfg_use_docn
    use_med_to_mpas = cfg_use_med_to_mpas
    use_docn_ice = cfg_use_docn_ice;  docn_ice_init_only = cfg_docn_ice_init_only
    coupling_mode = cfg_coupling_mode
    pet_layout = ''            ! vazio = chave ausente; derivado de coupling_mode
    atm_pet_count = cfg_atm_pet_count;  ocn_pet_count = cfg_ocn_pet_count
    ice_pet_count = cfg_ice_pet_count
    use_sis2_dynamic = cfg_use_sis2_dynamic;  seq_repro = cfg_seq_repro
    regrid_route = cfg_regrid_route;  regrid_scheme = cfg_regrid_scheme
    regrid_methods = cfg_regrid_methods;  regrid_weights = cfg_regrid_weights
    regrid_class = cfg_regrid_class
    regrid_options = cfg_regrid_options

    ! 2. Localizar o arquivo
    if (present(file_path)) then
      fpath = file_path
    else
      fpath = ''
    end if
    if (len_trim(fpath) == 0) then
      call get_environment_variable('NUOPC_INPUT', fpath, status=ios)
      if (ios /= 0 .or. len_trim(fpath) == 0) fpath = CONFIG_FILE_DEFAULT
    end if

    inquire(file=trim(fpath), exist=exists)
    if (.not. exists) then
      if (is_root) write(*,'(3A)') TAG//'AVISO: arquivo "', trim(fpath), &
                      '" nao encontrado, usando valores padrao.'
      rc = CFG_NO_FILE
      return
    end if

    open(newunit=unit, file=trim(fpath), status='old', action='read', iostat=ios)
    if (ios /= 0) then
      if (is_root) write(*,'(2A)') TAG//'ERRO: nao foi possivel abrir ', trim(fpath)
      rc = CFG_FATAL
      return
    end if

    ! 3. Ler cada grupo; para no primeiro grupo com erro de sintaxe.
    call read_groups(unit)
    close(unit)
    if (rc == CFG_FATAL) return

    ! 4. Normalizar e completar valores
    call str_lower(log_kind)
    call str_lower(coupling_mode)
    call str_lower(pet_layout)
    if (len_trim(pet_layout) == 0) then
      if (trim(coupling_mode) == 'concurrent') then
        pet_layout = 'split'
      else
        pet_layout = 'shared'
      end if
    end if
    if (is_root .and. (use_mommesh .or. restart_n /= 0)) write(*,'(A)') TAG//'AVISO: use_mommesh e ' // &
      'restart_n (&nuopc_ocn) sao obsoletas e nao tem efeito; remova-as do nuopc.input.'

    ! 5. Validar (erro fatal)
    mode = coupler_mode_index(use_datm, use_docn, use_med_to_mpas, use_sis2_dynamic)
    if (.not. valid_config()) then
      rc = CFG_FATAL
      return
    end if

    ! 6. Avisos (a rodada continua)
    if (is_root .and. COUPLER_MODES(mode)%status == 'nao_validada') write(*,'(A)') TAG// &
      'AVISO: combinacao de componentes nao validada: '//trim(COUPLER_MODES(mode)%note)// &
      ' Ver docs/estado-do-projeto.md, secao 6.'
    if (is_root .and. trim(log_kind) == 'multi_on_error') write(*,'(A)') TAG//'AVISO: ' // &
      'log_kind=multi_on_error pode deixar logs/PET*.esmApp.log incompletos em ' // &
      'rodadas bem-sucedidas; as ferramentas de balanceamento dependem deles.'
    if (is_root .and. dt_atm > dt_coupling) write(*,'(2(A,I0))') TAG//'AVISO: dt_atm=', dt_atm, &
      ' deve ser <= dt_coupling=', dt_coupling
    if (is_root .and. mod(dt_coupling, dt_atm) /= 0) &
      write(*,'(A)') TAG//'AVISO: dt_coupling nao e multiplo de dt_atm.'
    if (grid_res_deg <= 0.0 .or. grid_res_deg > 10.0) then
      if (is_root) write(*,'(A)') TAG//'AVISO: grid_res_deg fora de (0,10]; usando 1.0.'
      grid_res_deg = 1.0
    end if
    if (is_root .and. (sst_default < 150.0 .or. sst_default > 350.0)) &
      write(*,'(A,F7.2)') TAG//'AVISO: sst_default fora do intervalo fisico: ', sst_default
    if (seq_repro) call neutralize_seq_repro()

    ! 7. Publicar nas variáveis do módulo
    cfg_start_date = start_date;  cfg_stop_date = stop_date
    cfg_dt_coupling = dt_coupling;  cfg_dt_atm = dt_atm
    cfg_log_dir = log_dir;  cfg_log_kind = log_kind;  cfg_write_fixdiag = write_fixdiag
    cfg_mesh_atm = mesh_atm;  cfg_config_dir = config_dir;  cfg_write_diag = write_diag
    cfg_write_netcdf = write_netcdf;  cfg_output_dir = output_dir
    cfg_grid_res_deg = grid_res_deg
    cfg_sst_default = sst_default;  cfg_ice_fraction_default = ice_fraction_default
    cfg_zorl_default = zorl_default
    cfg_docn_mode = docn_mode;  cfg_docn_nx = docn_nx;  cfg_docn_ny = docn_ny
    cfg_docn_dt_data = docn_dt_data
    cfg_docn_epoch_year = docn_epoch_year;  cfg_docn_epoch_month = docn_epoch_month
    cfg_docn_epoch_day = docn_epoch_day
    cfg_docn_sst_file = docn_sst_file;  cfg_docn_ice_file = docn_ice_file
    cfg_docn_cur_file = docn_cur_file
    cfg_docn_sst_varname = docn_sst_varname;  cfg_docn_ice_varname = docn_ice_varname
    cfg_docn_cur_u_varname = docn_cur_u_varname
    cfg_docn_cur_v_varname = docn_cur_v_varname
    cfg_docn_ice_pct = docn_ice_pct
    cfg_write_import_diag = write_import_diag;  cfg_import_diag_dir = import_diag_dir
    cfg_mom6_mesh_ocn = mesh_ocn
    cfg_use_datm = use_datm;  cfg_use_docn = use_docn
    cfg_use_med_to_mpas = use_med_to_mpas
    cfg_use_docn_ice = use_docn_ice;  cfg_docn_ice_init_only = docn_ice_init_only
    cfg_coupling_mode = coupling_mode;  cfg_pet_layout = pet_layout
    cfg_atm_pet_count = atm_pet_count;  cfg_ocn_pet_count = ocn_pet_count
    cfg_ice_pet_count = ice_pet_count
    cfg_use_sis2_dynamic = use_sis2_dynamic;  cfg_seq_repro = seq_repro
    cfg_regrid_route = regrid_route;  cfg_regrid_scheme = regrid_scheme
    cfg_regrid_methods = regrid_methods;  cfg_regrid_weights = regrid_weights
    cfg_regrid_class = regrid_class
    cfg_regrid_options = regrid_options

  contains

    subroutine read_groups(unit)
      integer, intent(in) :: unit
      integer :: ios

      rewind(unit); read(unit, nml=nuopc_driver, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_driver')) return
      rewind(unit); read(unit, nml=nuopc_atm, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_atm')) return
      rewind(unit); read(unit, nml=nuopc_netcdf, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_netcdf')) return
      rewind(unit); read(unit, nml=nuopc_atm_bnd, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_atm_bnd')) return
      rewind(unit); read(unit, nml=nuopc_docn, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_docn')) return
      rewind(unit); read(unit, nml=nuopc_ocn, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_ocn')) return
      rewind(unit); read(unit, nml=nuopc_mode, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_mode')) return
      rewind(unit); read(unit, nml=nuopc_petlayout, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_petlayout')) return
      rewind(unit); read(unit, nml=nuopc_regrid, iostat=ios)
      if (.not. group_ok(ios, 'nuopc_regrid', optional_group=.true.)) return
    end subroutine read_groups

    !> Interpreta o iostat de uma leitura de namelist.
    !! Negativo: grupo ausente (aviso). Positivo: erro de sintaxe (fatal).
    logical function group_ok(ios, group, optional_group)
      integer,          intent(in)           :: ios
      character(len=*), intent(in)           :: group
      logical,          intent(in), optional :: optional_group

      group_ok = (ios <= 0)
      if (ios < 0 .and. present(optional_group)) then
        continue   ! grupo opcional ausente: sem aviso
      else if (ios < 0) then
        if (is_root) write(*,'(3A)') TAG//'AVISO: grupo &', group, ' ausente, usando valores padrao.'
      else if (ios > 0) then
        if (is_root) write(*,'(3A)') TAG//'ERRO: grupo &', group, &
          ' com erro de sintaxe ou chave desconhecida.'
        rc = CFG_FATAL
      end if
    end function group_ok

    !> Regras que, se violadas, impedem a execução.
    logical function valid_config()
      valid_config = .false.

      if (trim(log_kind) /= 'multi' .and. trim(log_kind) /= 'multi_on_error') then
        call fatal('log_kind="'//trim(log_kind)//'" invalido; use multi|multi_on_error.')
      else if (dt_coupling <= 0) then
        call fatal('dt_coupling deve ser positivo.')
      else if (dt_atm <= 0) then
        call fatal('dt_atm deve ser positivo.')
      else if (trim(docn_mode) /= 'netcdf') then
        call fatal('docn_mode="'//trim(docn_mode)//'" invalido; somente netcdf.')
      else if (trim(coupling_mode) /= 'sequential' .and. &
               trim(coupling_mode) /= 'concurrent') then
        call fatal('coupling_mode="'//trim(coupling_mode)// &
                   '" invalido; use sequential|concurrent.')
      else if (trim(pet_layout) /= 'shared' .and. trim(pet_layout) /= 'split') then
        call fatal('pet_layout="'//trim(pet_layout)//'" invalido; use shared|split.')
      else if (trim(coupling_mode) == 'concurrent' .and. trim(pet_layout) /= 'split') then
        call fatal('coupling_mode=concurrent exige pet_layout=split.')
      else if (min(atm_pet_count, ocn_pet_count, ice_pet_count) < 0) then
        call fatal('atm_pet_count, ocn_pet_count e ice_pet_count nao podem ser negativos.')
      else if (trim(pet_layout) == 'shared' .and. &
               max(atm_pet_count, ocn_pet_count, ice_pet_count) > 0) then
        call fatal('pet_layout=shared nao aceita contagens de PET; ' // &
                   'use pet_layout=split ou zere as contagens.')
      else if (COUPLER_MODES(mode)%status == 'recusada') then
        call fatal(trim(COUPLER_MODES(mode)%note))
      else if (.not. use_sis2_dynamic .and. ice_pet_count > 0) then
        call fatal('ice_pet_count > 0 exige use_sis2_dynamic=.true.')
      else if (use_docn_ice .and. len_trim(docn_ice_file) == 0) then
        call fatal('use_docn_ice=.true. exige docn_ice_file em &nuopc_docn.')
      else if (docn_ice_init_only .and. .not. use_docn_ice) then
        call fatal('docn_ice_init_only=.true. exige use_docn_ice=.true.')
      else
        valid_config = .true.
      end if
    end function valid_config

    !> seq_repro só vale no sequential + split + MOM6 dinâmico com SIS2.
    !! Fora disso a chave é desligada, com aviso.
    subroutine neutralize_seq_repro()
      character(len=:), allocatable :: reason

      if (trim(coupling_mode) /= 'sequential') then
        reason = 'coupling_mode=sequential'
      else if (.not. (use_med_to_mpas .and. use_sis2_dynamic)) then
        reason = 'use_med_to_mpas=.true. e use_sis2_dynamic=.true.'
      else if (trim(pet_layout) /= 'split') then
        reason = 'pet_layout=split'
      else
        return
      end if
      if (is_root) write(*,'(3A)') TAG//'AVISO: seq_repro=.true. exige ', reason, '; ignorado.'
      seq_repro = .false.
    end subroutine neutralize_seq_repro

    subroutine fatal(msg)
      character(len=*), intent(in) :: msg
      if (is_root) write(*,'(A)') TAG//'ERRO: '//msg
    end subroutine fatal

  end subroutine config_read

  !> Posto MPI do processo, lido das variáveis que os lançadores definem
  !! (PALS, PMI/Hydra, PMIx, Open MPI). A leitura da configuração acontece
  !! antes do MPI; com isto só o processo 0 escreve as mensagens. Devolve 0
  !! se nenhuma variável existir (execução sem lançador).
  integer function launcher_rank()
    character(len=*), parameter :: VARS(4) = [character(len=21) :: &
      'PALS_RANKID', 'PMI_RANK', 'PMIX_RANK', 'OMPI_COMM_WORLD_RANK']
    character(len=16) :: val
    integer :: k, st, ios

    launcher_rank = 0
    do k = 1, size(VARS)
      call get_environment_variable(trim(VARS(k)), val, status=st)
      if (st /= 0) cycle
      read(val, *, iostat=ios) launcher_rank
      if (ios /= 0) launcher_rank = 0
      return
    end do
  end function launcher_rank

  !> Converte 'AAAA-MM-DD' em ano, mês e dia. rc = 0 sucesso, 1 formato inválido.
  subroutine config_parse_date(date_str, yy, mm, dd, rc)
    character(len=*), intent(in)  :: date_str
    integer,          intent(out) :: yy, mm, dd, rc
    integer :: ios

    yy = 0; mm = 0; dd = 0
    rc = 1
    if (len_trim(date_str) < 10) return
    if (date_str(5:5) /= '-' .or. date_str(8:8) /= '-') return
    read(date_str, '(I4,1X,I2,1X,I2)', iostat=ios) yy, mm, dd
    if (ios /= 0) return
    if (mm < 1 .or. mm > 12 .or. dd < 1 .or. dd > 31) return
    rc = 0
  end subroutine config_parse_date

end module coupler_config_mod
