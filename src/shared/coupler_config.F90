!> @file coupler_config.F90
!! @brief Leitura e validação da configuração do acoplador (arquivo nuopc.input).
!!
!! A configuração é lida uma única vez, por esmApp.F90, antes de
!! ESMF_Initialize. Por isso esta rotina não usa MPI nem ESMF: as mensagens
!! vão para a saída padrão. Depois da leitura, os demais módulos consultam
!! as variáveis cfg_* (somente leitura, atributo protected).
!!
!! Grupos do namelist e o que controlam:
!!   &nuopc_driver     datas, passo de acoplamento, diretório, tipo e nível de log
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
!!     erro fatal, para que um erro de digitação não passe despercebido;
!!   - um arquivo com erro não muda nenhuma variável cfg_*.
!!
!! Cada grupo tem um tipo com os seus valores durante a leitura
!! (<grupo>_group_t) e as suas rotinas: read_<grupo>_group (leitura),
!! <grupo>_group_valid (regras do grupo), avisos e publish_<grupo>_group
!! (cópia para as variáveis cfg_*). config_read as chama em ordem e confere
!! as regras que envolvem mais de um grupo.
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
  character(len=16),  public, protected :: cfg_log_level    = 'info'      ! warning | info | debug

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

  ! Configurações de componentes
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

  !> Chaves de &nuopc_mode que escolhem as trocas do mapa de acoplamento
  !! (cpl_map). O mapa recebe a configuração como argumento em todas as
  !! consultas; cpl_current_config dá a lida do nuopc.input.
  type, public :: cpl_config_t
    logical :: datm        = .false.
    logical :: docn        = .false.
    logical :: med_to_mpas = .true.
    logical :: sis2        = .true.
  end type cpl_config_t

  public :: cpl_current_config

  ! Valores de cada grupo durante a leitura, com os nomes das chaves. A
  ! leitura preenche estes registros e só os copia para as variáveis cfg_*
  ! no fim, se nada estiver errado: um arquivo com erro não muda nenhum valor.

  !> Valores de &nuopc_driver durante a leitura.
  type :: driver_group_t
    character(len=10)  :: start_date, stop_date
    integer            :: dt_coupling, dt_atm
    character(len=256) :: log_dir
    character(len=16)  :: log_kind, log_level
    logical            :: write_fixdiag             !< chave obsoleta, sem efeito
  end type driver_group_t

  !> Valores de &nuopc_atm durante a leitura.
  type :: atm_group_t
    character(len=256) :: mesh_atm, config_dir
    logical            :: write_diag
  end type atm_group_t

  !> Valores de &nuopc_netcdf durante a leitura.
  type :: netcdf_group_t
    logical            :: write_netcdf
    character(len=256) :: output_dir
    real               :: grid_res_deg
  end type netcdf_group_t

  !> Valores de &nuopc_atm_bnd durante a leitura.
  type :: atm_bnd_group_t
    real :: sst_default, ice_fraction_default, zorl_default
  end type atm_bnd_group_t

  !> Valores de &nuopc_docn durante a leitura.
  type :: docn_group_t
    character(len=16)  :: docn_mode
    integer            :: docn_nx, docn_ny, docn_dt_data
    integer            :: docn_epoch_year, docn_epoch_month, docn_epoch_day
    character(len=256) :: docn_sst_file, docn_ice_file, docn_cur_file
    character(len=64)  :: docn_sst_varname, docn_ice_varname
    character(len=64)  :: docn_cur_u_varname, docn_cur_v_varname
    logical            :: docn_ice_pct, write_import_diag
    character(len=256) :: import_diag_dir
  end type docn_group_t

  !> Valores de &nuopc_ocn durante a leitura.
  type :: ocn_group_t
    character(len=256) :: mesh_ocn
    logical            :: use_mommesh               !< chave obsoleta, sem efeito
    integer            :: restart_n                 !< chave obsoleta, sem efeito
  end type ocn_group_t

  !> Valores de &nuopc_mode durante a leitura.
  type :: mode_group_t
    logical :: use_datm, use_docn, use_med_to_mpas
    logical :: use_docn_ice, docn_ice_init_only
  end type mode_group_t

  !> Valores de &nuopc_petlayout durante a leitura.
  type :: petlayout_group_t
    character(len=16) :: coupling_mode, pet_layout
    integer           :: atm_pet_count, ocn_pet_count, ice_pet_count
    logical           :: use_sis2_dynamic, seq_repro
  end type petlayout_group_t

  !> Valores de &nuopc_regrid durante a leitura.
  type :: regrid_group_t
    character(len=32)  :: regrid_route(MAX_REGRID_OVERRIDES), regrid_scheme(MAX_REGRID_OVERRIDES)
    character(len=64)  :: regrid_methods(MAX_REGRID_OVERRIDES)
    character(len=256) :: regrid_weights(MAX_REGRID_OVERRIDES)
    character(len=32)  :: regrid_class(MAX_REGRID_OVERRIDES)
    character(len=128) :: regrid_options(MAX_REGRID_OVERRIDES)
  end type regrid_group_t

contains

  !> @brief Configuração do mapa correspondente às chaves de &nuopc_mode lidas do
  !! nuopc.input.
  function cpl_current_config() result(cfg)
    type(cpl_config_t) :: cfg

    cfg%datm        = cfg_use_datm
    cfg%docn        = cfg_use_docn
    cfg%med_to_mpas = cfg_use_med_to_mpas
    cfg%sis2        = cfg_use_sis2_dynamic
  end function cpl_current_config

  !> @brief Posição em COUPLER_MODES da combinação das quatro chaves. A tabela tem
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

  !> @brief Lê o arquivo de configuração e preenche as variáveis cfg_*.
  !!
  !! Cada grupo do arquivo tem as suas rotinas: read_<grupo>_group lê o
  !! grupo, partindo dos valores atuais do módulo (os padrões, na primeira
  !! leitura), e <grupo>_group_valid confere as regras do grupo. Esta rotina
  !! localiza o arquivo, chama as dos grupos em ordem, confere as regras que
  !! envolvem mais de um grupo (a tabela COUPLER_MODES, o gelo do DOCN e
  !! seq_repro) e, se nada estiver errado, publica os valores nas variáveis
  !! cfg_* (publish_<grupo>_group).
  !!
  !! @param[out] rc         0 sucesso, 1 arquivo ausente, 2 erro fatal
  !! @param[in]  file_path  caminho opcional; senão usa a variável de
  !!                        ambiente NUOPC_INPUT ou 'nuopc.input'
  subroutine config_read(rc, file_path)
    integer,          intent(out)          :: rc
    character(len=*), intent(in), optional :: file_path

    type(driver_group_t)    :: driver
    type(atm_group_t)       :: atm
    type(netcdf_group_t)    :: netcdf
    type(atm_bnd_group_t)   :: atm_bnd
    type(docn_group_t)      :: docn
    type(ocn_group_t)       :: ocn
    type(mode_group_t)      :: mode_keys
    type(petlayout_group_t) :: petlayout
    type(regrid_group_t)    :: regrid

    character(len=512) :: fpath
    logical :: exists, is_root
    integer :: unit, ios
    integer :: mode               ! posição da combinação em COUPLER_MODES

    rc = CFG_OK
    is_root = launcher_rank() == 0

    ! 1. Localizar o arquivo
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

    ! 2. Ler cada grupo; para no primeiro grupo com erro de sintaxe.
    call read_groups(unit)
    close(unit)
    if (rc == CFG_FATAL) return

    ! 3. Chaves obsoletas (aviso)
    call warn_obsolete_ocn_keys(ocn, is_root)
    call warn_obsolete_driver_keys(driver, is_root)

    ! 4. Validar (erro fatal): primeiro as regras de cada grupo, depois as que
    !    envolvem mais de um
    mode = coupler_mode_index(mode_keys%use_datm, mode_keys%use_docn, &
                              mode_keys%use_med_to_mpas, petlayout%use_sis2_dynamic)
    if (.not. valid_config()) then
      rc = CFG_FATAL
      return
    end if

    ! 5. Avisos (a rodada continua)
    if (is_root .and. COUPLER_MODES(mode)%status == 'nao_validada') write(*,'(A)') TAG// &
      'AVISO: combinacao de componentes nao validada: '//trim(COUPLER_MODES(mode)%note)// &
      ' Ver docs/estado-do-projeto.md, secao 6.'
    call warn_driver_group(driver, is_root)
    call adjust_netcdf_group(netcdf, is_root)
    call warn_atm_bnd_group(atm_bnd, is_root)
    if (petlayout%seq_repro) call neutralize_seq_repro()

    ! 6. Publicar nas variáveis do módulo
    call publish_driver_group(driver)
    call publish_atm_group(atm)
    call publish_netcdf_group(netcdf)
    call publish_atm_bnd_group(atm_bnd)
    call publish_docn_group(docn)
    call publish_ocn_group(ocn)
    call publish_mode_group(mode_keys)
    call publish_petlayout_group(petlayout)
    call publish_regrid_group(regrid)

  contains

    !> Lê os grupos do namelist em ordem; para no primeiro com erro de sintaxe.
    subroutine read_groups(unit)
      integer, intent(in) :: unit
      integer :: ios

      call read_driver_group(unit, driver, ios)
      if (.not. group_ok(ios, 'nuopc_driver')) return
      call read_atm_group(unit, atm, ios)
      if (.not. group_ok(ios, 'nuopc_atm')) return
      call read_netcdf_group(unit, netcdf, ios)
      if (.not. group_ok(ios, 'nuopc_netcdf')) return
      call read_atm_bnd_group(unit, atm_bnd, ios)
      if (.not. group_ok(ios, 'nuopc_atm_bnd')) return
      call read_docn_group(unit, docn, ios)
      if (.not. group_ok(ios, 'nuopc_docn')) return
      call read_ocn_group(unit, ocn, ios)
      if (.not. group_ok(ios, 'nuopc_ocn')) return
      call read_mode_group(unit, mode_keys, ios)
      if (.not. group_ok(ios, 'nuopc_mode')) return
      call read_petlayout_group(unit, petlayout, ios)
      if (.not. group_ok(ios, 'nuopc_petlayout')) return
      call read_regrid_group(unit, regrid, ios)
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

    !> Regras que, se violadas, impedem a execução: as de cada grupo e as
    !! que envolvem mais de um. Só a primeira violada é informada.
    logical function valid_config()
      valid_config = .false.

      if (.not. driver_group_valid(driver, is_root)) return
      if (.not. docn_group_valid(docn, is_root)) return
      if (.not. petlayout_group_valid(petlayout, is_root)) return
      if (COUPLER_MODES(mode)%status == 'recusada') then
        call config_error(is_root, trim(COUPLER_MODES(mode)%note))
      else if (mode_keys%use_docn_ice .and. len_trim(docn%docn_ice_file) == 0) then
        call config_error(is_root, 'use_docn_ice=.true. exige docn_ice_file em &nuopc_docn.')
      else if (mode_group_valid(mode_keys, is_root)) then
        valid_config = .true.
      end if
    end function valid_config

    !> seq_repro só vale no sequential + split + MOM6 dinâmico com SIS2.
    !! Fora disso a chave é desligada, com aviso.
    subroutine neutralize_seq_repro()
      character(len=:), allocatable :: reason

      if (trim(petlayout%coupling_mode) /= 'sequential') then
        reason = 'coupling_mode=sequential'
      else if (.not. (mode_keys%use_med_to_mpas .and. petlayout%use_sis2_dynamic)) then
        reason = 'use_med_to_mpas=.true. e use_sis2_dynamic=.true.'
      else if (trim(petlayout%pet_layout) /= 'split') then
        reason = 'pet_layout=split'
      else
        return
      end if
      if (is_root) write(*,'(3A)') TAG//'AVISO: seq_repro=.true. exige ', reason, '; ignorado.'
      petlayout%seq_repro = .false.
    end subroutine neutralize_seq_repro

  end subroutine config_read

  !> @brief Escreve a mensagem de erro fatal da leitura na saída padrão (só o processo 0).
  !!
  !! @param[in] is_root  verdadeiro no processo 0
  !! @param[in] msg      mensagem, sem o prefixo
  subroutine config_error(is_root, msg)
    logical,          intent(in) :: is_root
    character(len=*), intent(in) :: msg
    if (is_root) write(*,'(A)') TAG//'ERRO: '//msg
  end subroutine config_error

  ! &nuopc_driver

  !> @brief Lê &nuopc_driver, a partir dos valores atuais do módulo, e passa
  !! log_kind e log_level a minúsculas.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_driver_group(unit, g, ios)
    integer,              intent(in)  :: unit
    type(driver_group_t), intent(out) :: g
    integer,              intent(out) :: ios

    character(len=10)  :: start_date, stop_date
    integer            :: dt_coupling, dt_atm
    character(len=256) :: log_dir
    character(len=16)  :: log_kind, log_level
    logical            :: write_fixdiag
    namelist /nuopc_driver/ start_date, stop_date, dt_coupling, dt_atm, &
                            log_dir, log_kind, log_level, write_fixdiag

    start_date = cfg_start_date;  stop_date = cfg_stop_date
    dt_coupling = cfg_dt_coupling; dt_atm = cfg_dt_atm
    log_dir = cfg_log_dir;  log_kind = cfg_log_kind;  log_level = cfg_log_level
    write_fixdiag = .false.

    rewind(unit); read(unit, nml=nuopc_driver, iostat=ios)

    call str_lower(log_kind)
    call str_lower(log_level)
    g = driver_group_t(start_date, stop_date, dt_coupling, dt_atm, log_dir, &
                       log_kind, log_level, write_fixdiag)
  end subroutine read_driver_group

  !> @brief Aviso para a chave obsoleta write_fixdiag.
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  subroutine warn_obsolete_driver_keys(g, is_root)
    type(driver_group_t), intent(in) :: g
    logical,              intent(in) :: is_root
    if (is_root .and. g%write_fixdiag) write(*,'(A)') TAG//'AVISO: write_fixdiag (&nuopc_driver) ' // &
      'e obsoleta e nao tem efeito; os diagnosticos saem com log_level=''debug''.'
  end subroutine warn_obsolete_driver_keys

  !> @brief Regras de &nuopc_driver; escreve a primeira violada.
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  logical function driver_group_valid(g, is_root) result(ok)
    type(driver_group_t), intent(in) :: g
    logical,              intent(in) :: is_root

    ok = .false.
    if (trim(g%log_kind) /= 'multi' .and. trim(g%log_kind) /= 'multi_on_error') then
      call config_error(is_root, 'log_kind="'//trim(g%log_kind)//'" invalido; use multi|multi_on_error.')
    else if (trim(g%log_level) /= 'warning' .and. trim(g%log_level) /= 'info' .and. &
             trim(g%log_level) /= 'debug') then
      call config_error(is_root, 'log_level="'//trim(g%log_level)//'" invalido; use warning|info|debug.')
    else if (g%dt_coupling <= 0) then
      call config_error(is_root, 'dt_coupling deve ser positivo.')
    else if (g%dt_atm <= 0) then
      call config_error(is_root, 'dt_atm deve ser positivo.')
    else
      ok = .true.
    end if
  end function driver_group_valid

  !> @brief Avisos de &nuopc_driver (a rodada continua).
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  subroutine warn_driver_group(g, is_root)
    type(driver_group_t), intent(in) :: g
    logical,              intent(in) :: is_root

    if (is_root .and. trim(g%log_kind) == 'multi_on_error') write(*,'(A)') TAG//'AVISO: ' // &
      'log_kind=multi_on_error pode deixar logs/PET*.esmApp.log incompletos em ' // &
      'rodadas bem-sucedidas; as ferramentas de balanceamento dependem deles.'
    if (is_root .and. g%dt_atm > g%dt_coupling) write(*,'(2(A,I0))') TAG//'AVISO: dt_atm=', g%dt_atm, &
      ' deve ser <= dt_coupling=', g%dt_coupling
    if (is_root .and. mod(g%dt_coupling, g%dt_atm) /= 0) &
      write(*,'(A)') TAG//'AVISO: dt_coupling nao e multiplo de dt_atm.'
  end subroutine warn_driver_group

  !> @brief Copia os valores de &nuopc_driver para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_driver_group(g)
    type(driver_group_t), intent(in) :: g
    cfg_start_date = g%start_date;  cfg_stop_date = g%stop_date
    cfg_dt_coupling = g%dt_coupling;  cfg_dt_atm = g%dt_atm
    cfg_log_dir = g%log_dir;  cfg_log_kind = g%log_kind;  cfg_log_level = g%log_level
  end subroutine publish_driver_group

  ! &nuopc_atm

  !> @brief Lê &nuopc_atm, a partir dos valores atuais do módulo.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_atm_group(unit, g, ios)
    integer,           intent(in)  :: unit
    type(atm_group_t), intent(out) :: g
    integer,           intent(out) :: ios

    character(len=256) :: mesh_atm, config_dir
    logical            :: write_diag
    namelist /nuopc_atm/ mesh_atm, config_dir, write_diag

    mesh_atm = cfg_mesh_atm;  config_dir = cfg_config_dir;  write_diag = cfg_write_diag
    rewind(unit); read(unit, nml=nuopc_atm, iostat=ios)
    g = atm_group_t(mesh_atm, config_dir, write_diag)
  end subroutine read_atm_group

  !> @brief Copia os valores de &nuopc_atm para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_atm_group(g)
    type(atm_group_t), intent(in) :: g
    cfg_mesh_atm = g%mesh_atm;  cfg_config_dir = g%config_dir;  cfg_write_diag = g%write_diag
  end subroutine publish_atm_group

  ! &nuopc_netcdf

  !> @brief Lê &nuopc_netcdf, a partir dos valores atuais do módulo.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_netcdf_group(unit, g, ios)
    integer,              intent(in)  :: unit
    type(netcdf_group_t), intent(out) :: g
    integer,              intent(out) :: ios

    logical            :: write_netcdf
    character(len=256) :: output_dir
    real               :: grid_res_deg
    namelist /nuopc_netcdf/ write_netcdf, output_dir, grid_res_deg

    write_netcdf = cfg_write_netcdf;  output_dir = cfg_output_dir
    grid_res_deg = cfg_grid_res_deg
    rewind(unit); read(unit, nml=nuopc_netcdf, iostat=ios)
    g = netcdf_group_t(write_netcdf, output_dir, grid_res_deg)
  end subroutine read_netcdf_group

  !> @brief grid_res_deg fora de (0, 10] passa a 1.0, com aviso.
  !!
  !! @param[inout] g        valores do grupo
  !! @param[in]    is_root  verdadeiro no processo 0
  subroutine adjust_netcdf_group(g, is_root)
    type(netcdf_group_t), intent(inout) :: g
    logical,              intent(in)    :: is_root
    if (g%grid_res_deg <= 0.0 .or. g%grid_res_deg > 10.0) then
      if (is_root) write(*,'(A)') TAG//'AVISO: grid_res_deg fora de (0,10]; usando 1.0.'
      g%grid_res_deg = 1.0
    end if
  end subroutine adjust_netcdf_group

  !> @brief Copia os valores de &nuopc_netcdf para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_netcdf_group(g)
    type(netcdf_group_t), intent(in) :: g
    cfg_write_netcdf = g%write_netcdf;  cfg_output_dir = g%output_dir
    cfg_grid_res_deg = g%grid_res_deg
  end subroutine publish_netcdf_group

  ! &nuopc_atm_bnd

  !> @brief Lê &nuopc_atm_bnd, a partir dos valores atuais do módulo.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_atm_bnd_group(unit, g, ios)
    integer,               intent(in)  :: unit
    type(atm_bnd_group_t), intent(out) :: g
    integer,               intent(out) :: ios

    real :: sst_default, ice_fraction_default, zorl_default
    namelist /nuopc_atm_bnd/ sst_default, ice_fraction_default, zorl_default

    sst_default = cfg_sst_default;  ice_fraction_default = cfg_ice_fraction_default
    zorl_default = cfg_zorl_default
    rewind(unit); read(unit, nml=nuopc_atm_bnd, iostat=ios)
    g = atm_bnd_group_t(sst_default, ice_fraction_default, zorl_default)
  end subroutine read_atm_bnd_group

  !> @brief Aviso para sst_default fora do intervalo físico (a rodada continua).
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  subroutine warn_atm_bnd_group(g, is_root)
    type(atm_bnd_group_t), intent(in) :: g
    logical,               intent(in) :: is_root
    if (is_root .and. (g%sst_default < 150.0 .or. g%sst_default > 350.0)) &
      write(*,'(A,F7.2)') TAG//'AVISO: sst_default fora do intervalo fisico: ', g%sst_default
  end subroutine warn_atm_bnd_group

  !> @brief Copia os valores de &nuopc_atm_bnd para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_atm_bnd_group(g)
    type(atm_bnd_group_t), intent(in) :: g
    cfg_sst_default = g%sst_default;  cfg_ice_fraction_default = g%ice_fraction_default
    cfg_zorl_default = g%zorl_default
  end subroutine publish_atm_bnd_group

  ! &nuopc_docn

  !> @brief Lê &nuopc_docn, a partir dos valores atuais do módulo.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_docn_group(unit, g, ios)
    integer,            intent(in)  :: unit
    type(docn_group_t), intent(out) :: g
    integer,            intent(out) :: ios

    character(len=16)  :: docn_mode
    integer            :: docn_nx, docn_ny, docn_dt_data
    integer            :: docn_epoch_year, docn_epoch_month, docn_epoch_day
    character(len=256) :: docn_sst_file, docn_ice_file, docn_cur_file
    character(len=64)  :: docn_sst_varname, docn_ice_varname
    character(len=64)  :: docn_cur_u_varname, docn_cur_v_varname
    logical            :: docn_ice_pct, write_import_diag
    character(len=256) :: import_diag_dir
    namelist /nuopc_docn/ docn_mode, docn_nx, docn_ny, docn_dt_data,       &
                          docn_epoch_year, docn_epoch_month, docn_epoch_day, &
                          docn_sst_file, docn_ice_file, docn_cur_file,     &
                          docn_sst_varname, docn_ice_varname,              &
                          docn_cur_u_varname, docn_cur_v_varname,          &
                          docn_ice_pct, write_import_diag, import_diag_dir

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

    rewind(unit); read(unit, nml=nuopc_docn, iostat=ios)

    g = docn_group_t(docn_mode, docn_nx, docn_ny, docn_dt_data,                   &
                     docn_epoch_year, docn_epoch_month, docn_epoch_day,          &
                     docn_sst_file, docn_ice_file, docn_cur_file,                &
                     docn_sst_varname, docn_ice_varname,                         &
                     docn_cur_u_varname, docn_cur_v_varname,                     &
                     docn_ice_pct, write_import_diag, import_diag_dir)
  end subroutine read_docn_group

  !> @brief Regras de &nuopc_docn; escreve a primeira violada.
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  logical function docn_group_valid(g, is_root) result(ok)
    type(docn_group_t), intent(in) :: g
    logical,            intent(in) :: is_root

    ok = trim(g%docn_mode) == 'netcdf'
    if (.not. ok) call config_error(is_root, 'docn_mode="'//trim(g%docn_mode)//'" invalido; somente netcdf.')
  end function docn_group_valid

  !> @brief Copia os valores de &nuopc_docn para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_docn_group(g)
    type(docn_group_t), intent(in) :: g
    cfg_docn_mode = g%docn_mode;  cfg_docn_nx = g%docn_nx;  cfg_docn_ny = g%docn_ny
    cfg_docn_dt_data = g%docn_dt_data
    cfg_docn_epoch_year = g%docn_epoch_year;  cfg_docn_epoch_month = g%docn_epoch_month
    cfg_docn_epoch_day = g%docn_epoch_day
    cfg_docn_sst_file = g%docn_sst_file;  cfg_docn_ice_file = g%docn_ice_file
    cfg_docn_cur_file = g%docn_cur_file
    cfg_docn_sst_varname = g%docn_sst_varname;  cfg_docn_ice_varname = g%docn_ice_varname
    cfg_docn_cur_u_varname = g%docn_cur_u_varname
    cfg_docn_cur_v_varname = g%docn_cur_v_varname
    cfg_docn_ice_pct = g%docn_ice_pct
    cfg_write_import_diag = g%write_import_diag;  cfg_import_diag_dir = g%import_diag_dir
  end subroutine publish_docn_group

  ! &nuopc_ocn

  !> @brief Lê &nuopc_ocn, a partir dos valores atuais do módulo.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_ocn_group(unit, g, ios)
    integer,           intent(in)  :: unit
    type(ocn_group_t), intent(out) :: g
    integer,           intent(out) :: ios

    character(len=256) :: mesh_ocn
    logical            :: use_mommesh
    integer            :: restart_n
    namelist /nuopc_ocn/ mesh_ocn, use_mommesh, restart_n

    mesh_ocn = cfg_mom6_mesh_ocn
    restart_n = 0;  use_mommesh = .false.
    rewind(unit); read(unit, nml=nuopc_ocn, iostat=ios)
    g = ocn_group_t(mesh_ocn, use_mommesh, restart_n)
  end subroutine read_ocn_group

  !> @brief Aviso para as chaves obsoletas use_mommesh e restart_n.
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  subroutine warn_obsolete_ocn_keys(g, is_root)
    type(ocn_group_t), intent(in) :: g
    logical,           intent(in) :: is_root
    if (is_root .and. (g%use_mommesh .or. g%restart_n /= 0)) write(*,'(A)') TAG//'AVISO: use_mommesh e ' // &
      'restart_n (&nuopc_ocn) sao obsoletas e nao tem efeito; remova-as do nuopc.input.'
  end subroutine warn_obsolete_ocn_keys

  !> @brief Copia os valores de &nuopc_ocn para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_ocn_group(g)
    type(ocn_group_t), intent(in) :: g
    cfg_mom6_mesh_ocn = g%mesh_ocn
  end subroutine publish_ocn_group

  ! &nuopc_mode

  !> @brief Lê &nuopc_mode, a partir dos valores atuais do módulo.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_mode_group(unit, g, ios)
    integer,            intent(in)  :: unit
    type(mode_group_t), intent(out) :: g
    integer,            intent(out) :: ios

    logical :: use_datm, use_docn, use_med_to_mpas
    logical :: use_docn_ice, docn_ice_init_only
    namelist /nuopc_mode/ use_datm, use_docn, use_med_to_mpas, &
                          use_docn_ice, docn_ice_init_only

    use_datm = cfg_use_datm;  use_docn = cfg_use_docn
    use_med_to_mpas = cfg_use_med_to_mpas
    use_docn_ice = cfg_use_docn_ice;  docn_ice_init_only = cfg_docn_ice_init_only
    rewind(unit); read(unit, nml=nuopc_mode, iostat=ios)
    g = mode_group_t(use_datm, use_docn, use_med_to_mpas, use_docn_ice, docn_ice_init_only)
  end subroutine read_mode_group

  !> @brief Regras de &nuopc_mode; escreve a primeira violada. As combinações
  !! de componentes, que envolvem também use_sis2_dynamic, ficam em
  !! config_read (COUPLER_MODES).
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  logical function mode_group_valid(g, is_root) result(ok)
    type(mode_group_t), intent(in) :: g
    logical,            intent(in) :: is_root

    ok = .not. (g%docn_ice_init_only .and. .not. g%use_docn_ice)
    if (.not. ok) call config_error(is_root, 'docn_ice_init_only=.true. exige use_docn_ice=.true.')
  end function mode_group_valid

  !> @brief Copia os valores de &nuopc_mode para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_mode_group(g)
    type(mode_group_t), intent(in) :: g
    cfg_use_datm = g%use_datm;  cfg_use_docn = g%use_docn
    cfg_use_med_to_mpas = g%use_med_to_mpas
    cfg_use_docn_ice = g%use_docn_ice;  cfg_docn_ice_init_only = g%docn_ice_init_only
  end subroutine publish_mode_group

  ! &nuopc_petlayout

  !> @brief Lê &nuopc_petlayout, a partir dos valores atuais do módulo; passa
  !! coupling_mode e pet_layout a minúsculas e, sem pet_layout, o deduz de
  !! coupling_mode (concurrent: split; sequential: shared).
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_petlayout_group(unit, g, ios)
    integer,                 intent(in)  :: unit
    type(petlayout_group_t), intent(out) :: g
    integer,                 intent(out) :: ios

    character(len=16) :: coupling_mode, pet_layout
    integer           :: atm_pet_count, ocn_pet_count, ice_pet_count
    logical           :: use_sis2_dynamic, seq_repro
    namelist /nuopc_petlayout/ coupling_mode, pet_layout, atm_pet_count, &
                               ocn_pet_count, ice_pet_count, use_sis2_dynamic, &
                               seq_repro

    coupling_mode = cfg_coupling_mode
    pet_layout = ''            ! vazio = chave ausente; derivado de coupling_mode
    atm_pet_count = cfg_atm_pet_count;  ocn_pet_count = cfg_ocn_pet_count
    ice_pet_count = cfg_ice_pet_count
    use_sis2_dynamic = cfg_use_sis2_dynamic;  seq_repro = cfg_seq_repro

    rewind(unit); read(unit, nml=nuopc_petlayout, iostat=ios)

    call str_lower(coupling_mode)
    call str_lower(pet_layout)
    if (len_trim(pet_layout) == 0) then
      if (trim(coupling_mode) == 'concurrent') then
        pet_layout = 'split'
      else
        pet_layout = 'shared'
      end if
    end if
    g = petlayout_group_t(coupling_mode, pet_layout, atm_pet_count, ocn_pet_count, &
                          ice_pet_count, use_sis2_dynamic, seq_repro)
  end subroutine read_petlayout_group

  !> @brief Regras de &nuopc_petlayout; escreve a primeira violada.
  !!
  !! @param[in] g        valores do grupo
  !! @param[in] is_root  verdadeiro no processo 0
  logical function petlayout_group_valid(g, is_root) result(ok)
    type(petlayout_group_t), intent(in) :: g
    logical,                 intent(in) :: is_root

    ok = .false.
    if (trim(g%coupling_mode) /= 'sequential' .and. &
        trim(g%coupling_mode) /= 'concurrent') then
      call config_error(is_root, 'coupling_mode="'//trim(g%coupling_mode)// &
                        '" invalido; use sequential|concurrent.')
    else if (trim(g%pet_layout) /= 'shared' .and. trim(g%pet_layout) /= 'split') then
      call config_error(is_root, 'pet_layout="'//trim(g%pet_layout)//'" invalido; use shared|split.')
    else if (trim(g%coupling_mode) == 'concurrent' .and. trim(g%pet_layout) /= 'split') then
      call config_error(is_root, 'coupling_mode=concurrent exige pet_layout=split.')
    else if (min(g%atm_pet_count, g%ocn_pet_count, g%ice_pet_count) < 0) then
      call config_error(is_root, 'atm_pet_count, ocn_pet_count e ice_pet_count nao podem ser negativos.')
    else if (trim(g%pet_layout) == 'shared' .and. &
             max(g%atm_pet_count, g%ocn_pet_count, g%ice_pet_count) > 0) then
      call config_error(is_root, 'pet_layout=shared nao aceita contagens de PET; ' // &
                        'use pet_layout=split ou zere as contagens.')
    else if (.not. g%use_sis2_dynamic .and. g%ice_pet_count > 0) then
      call config_error(is_root, 'ice_pet_count > 0 exige use_sis2_dynamic=.true.')
    else
      ok = .true.
    end if
  end function petlayout_group_valid

  !> @brief Copia os valores de &nuopc_petlayout para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_petlayout_group(g)
    type(petlayout_group_t), intent(in) :: g
    cfg_coupling_mode = g%coupling_mode;  cfg_pet_layout = g%pet_layout
    cfg_atm_pet_count = g%atm_pet_count;  cfg_ocn_pet_count = g%ocn_pet_count
    cfg_ice_pet_count = g%ice_pet_count
    cfg_use_sis2_dynamic = g%use_sis2_dynamic;  cfg_seq_repro = g%seq_repro
  end subroutine publish_petlayout_group

  ! &nuopc_regrid

  !> @brief Lê &nuopc_regrid (opcional), a partir dos valores atuais do módulo.
  !!
  !! @param[in]  unit  unidade do arquivo aberto
  !! @param[out] g     valores do grupo
  !! @param[out] ios   iostat da leitura (negativo: grupo ausente)
  subroutine read_regrid_group(unit, g, ios)
    integer,              intent(in)  :: unit
    type(regrid_group_t), intent(out) :: g
    integer,              intent(out) :: ios

    character(len=32)  :: regrid_route(MAX_REGRID_OVERRIDES), regrid_scheme(MAX_REGRID_OVERRIDES)
    character(len=64)  :: regrid_methods(MAX_REGRID_OVERRIDES)
    character(len=256) :: regrid_weights(MAX_REGRID_OVERRIDES)
    character(len=32)  :: regrid_class(MAX_REGRID_OVERRIDES)
    character(len=128) :: regrid_options(MAX_REGRID_OVERRIDES)
    namelist /nuopc_regrid/ regrid_route, regrid_scheme, regrid_methods, &
                            regrid_weights, regrid_class, regrid_options

    regrid_route = cfg_regrid_route;  regrid_scheme = cfg_regrid_scheme
    regrid_methods = cfg_regrid_methods;  regrid_weights = cfg_regrid_weights
    regrid_class = cfg_regrid_class
    regrid_options = cfg_regrid_options
    rewind(unit); read(unit, nml=nuopc_regrid, iostat=ios)
    g = regrid_group_t(regrid_route, regrid_scheme, regrid_methods, regrid_weights, &
                       regrid_class, regrid_options)
  end subroutine read_regrid_group

  !> @brief Copia os valores de &nuopc_regrid para as variáveis do módulo.
  !!
  !! @param[in] g  valores do grupo
  subroutine publish_regrid_group(g)
    type(regrid_group_t), intent(in) :: g
    cfg_regrid_route = g%regrid_route;  cfg_regrid_scheme = g%regrid_scheme
    cfg_regrid_methods = g%regrid_methods;  cfg_regrid_weights = g%regrid_weights
    cfg_regrid_class = g%regrid_class
    cfg_regrid_options = g%regrid_options
  end subroutine publish_regrid_group

  !> @brief Posto MPI do processo, lido das variáveis que os lançadores definem
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

  !> @brief Converte 'AAAA-MM-DD' em ano, mês e dia. rc = 0 sucesso, 1 formato inválido.
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
