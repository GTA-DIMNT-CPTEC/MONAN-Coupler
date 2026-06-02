!> @file mpas_cap_netcdf.F90
!! @brief Diagnóstico NetCDF do cap MPAS-A: exportação e importação MED→MPAS.
!!
!! Versão 3.0 (Mai/2026) — GT Acoplamento de Modelos / INPE/CGCT/DIMNT
!!
!! MUDANÇAS EM RELAÇÃO À v2.9:
!!   Migração de mpas_cap_methods.F90 (reorganização de responsabilidades):
!!     write_mpas_import_diag  — escrita diagnóstica dos campos importados do MED
!!     set_mpas_diag_clock     — injeta timestamp de simulação no diagnóstico
!!     voronoi_to_grid         — binning Voronoi → grade lat/lon (helper privado)
!!   Variáveis de estado do diagnóstico de importação (g_diag_*) movidas junto.
!!   mpas_cap_methods.F90 passa a chamar write_mpas_import_diag via use deste módulo.
!!
!! MUDANÇAS EM RELAÇÃO À v2.5:
!!
!!   Bug corrigido: timestamp duplo em export_write_netcdf (v2.6).
!!   Os parâmetros step e dt_s foram removidos da assinatura.
!!   O currTime passado por ModelRun (yr,mo,dy,hr,mn,sc via ESMF_ClockGet)
!!   é usado diretamente como timestamp do arquivo NetCDF.
!!   Resultado: arquivo monan_export_YYYYMMDD_HHMMSS.nc agora recebe o
!!   timestamp correto em vez de startTime + 2×step×dt_coupling.
!!
!! MUDANÇAS EM RELAÇÃO À v2.4:
!!
!!   Removida a lógica de conversão de campos acumulados (field_is_accumulated,
!!   acum_factor, ÷elapsed_s). Esta conversão foi movida para mpas_atm_model.F90
!!   (mpas_atm_run), que agora fornece campos já em unidades instantâneas:
!!
!!     Faxa_swdn = (acswdnb_N − acswdnb_{N−1}) / dt_coupling  [W/m²]
!!     Faxa_lwdn = (aclwdnb_N − aclwdnb_{N−1}) / dt_coupling  [W/m²]
!!     Faxa_prec = (rainnc_N + rainc_N − prev_N) / dt / 1000  [kg/m²/s]
!!     Faxa_taux = ρ_a · ust² · u10 / |V10|                   [N/m²]
!!     Faxa_tauy = ρ_a · ust² · v10 / |V10|                   [N/m²]
!!
!!   A divisão por elapsed_s (tempo total desde t=0) era incorreta para passos
!!   posteriores ao primeiro: produzia a média from t=0 em vez da média do
!!   intervalo de acoplamento corrente.
!!
!!   O limiar de outlier Faxa_taux/tauy foi reduzido de 1e4 para 10 N/m²
!!   (valor físico máximo realista de stress superficial). Com o cálculo
!!   correto via ust, não há mais lixo de memória nestes campos.
!!
!! ESTRUTURA DO ARQUIVO NetCDF GERADO (grade regular 1°×1°):
!!   dimensions  : lat(181), lon(360)
!!   variables   :
!!     double lat(lat)      [degrees_north, -90 a +90, passo 1°]
!!     double lon(lon)      [degrees_east, -180 a +179, passo 1°]
!!     double time          [escalar CF: seconds since start_time]
!!     double Sa_pslv(lat,lon)    [Pa,        instantâneo]
!!     double Sa_tbot(lat,lon)    [K,         instantâneo]
!!     double Sa_ubot(lat,lon)    [m s-1,     instantâneo]
!!     double Sa_vbot(lat,lon)    [m s-1,     instantâneo]
!!     double Faxa_swdn(lat,lon)  [W m-2,     média do intervalo de acoplamento]
!!     double Faxa_lwdn(lat,lon)  [W m-2,     média do intervalo de acoplamento]
!!     double Faxa_prec(lat,lon)  [kg m-2 s-1, média do intervalo de acoplamento]
!!     double Faxa_taux(lat,lon)  [N m-2,     ρ·ust²·u10/|V10|, outliers |v|>10 N/m² descartados]
!!     double Faxa_tauy(lat,lon)  [N m-2,     ρ·ust²·v10/|V10|, outliers |v|>10 N/m² descartados]
!!     double Faxa_lhflx(lat,lon) [W m-2,     instantâneo]
!!     double Faxa_shflx(lat,lon) [W m-2,     instantâneo]
!!
!! CONVENÇÃO DE DIMENSÕES (compatível com Python/netCDF4):
!!   Fortran: nf90_def_var([dimid_lon, dimid_lat]) → lon varia mais rápido
!!   Python:  nc.variables['Sa_tbot'][:] → shape (181, 360) = (nlat, nlon) ✓
!!
!! FLUXO MPI:
!!   Todos os PETs → MPI_Allgather (tamanhos locais)
!!               → MPI_Gatherv    (dados de campo → PET0)
!!   PET0        → voronoi_to_latlon (binning + conversão)
!!               → nf90_create / nf90_put_var / nf90_close

module mpas_cap_netcdf_mod

  use ESMF
  use mpi
  ! W1-FIX (v12.0): wrappers tipadas em módulo separado — mpi_allreduce_wrappers.F90.
  ! O ftn/gfortran cruza tipos de MPI_Allreduce entre chamadas no mesmo módulo
  ! (análise de fluxo sobre interface implícita 'use mpi'). Isolar em módulo
  ! próprio elimina o cruzamento de escopo sem alterar a semântica MPI.
  use mpi_allreduce_wrappers_mod, only : allreduce_r8, allreduce_i4
  use netcdf
  use mpas_cap_utils_mod,  only : ChkErr
  ! Tipos MPAS e configurações necessários para o diagnóstico de importação
  use mpas_atm_types_mod,  only : atm_ocean_boundary_type, MPAS_RKIND
  use mpas_cap_config_mod, only : cfg_import_diag_dir, cfg_grid_res_deg

  implicit none
  private

  ! ── Interface pública ──────────────────────────────────────────────────────
  public :: netcdf_init_coords      ! coleta coordenadas locais de todos os PETs
  public :: export_write_netcdf     ! interpola e escreve NetCDF com grade lat/lon
  public :: netcdf_config_set       ! configura grade e diretório a partir do namelist
  public :: netcdf_push_raw_field
  ! Diagnóstico de importação MED→MPAS (migrado de mpas_cap_methods.F90)
  public :: write_mpas_import_diag  ! escreve monan2_import_YYYYMMDD_HHMMSS.nc
  public :: set_mpas_diag_clock     ! injeta timestamp de simulação no diagnóstico

  ! ── Grade regular de saída ────────────────────────────────────────────────
  ! Inicializada com 1°×1° (padrão do namelist &nuopc_netcdf).
  ! Atualizada via netcdf_config_set() antes de export_write_netcdf.
  integer,            save :: NLON     = 360   !  -180° a +179°
  integer,            save :: NLAT     = 181   !   -90° a  +90°
  real,               save :: GRID_RES = 1.0   !  resolução [°]
  real(ESMF_KIND_R8), save :: DLON = 1.0_ESMF_KIND_R8  ! passo em lon
  real(ESMF_KIND_R8), save :: DLAT = 1.0_ESMF_KIND_R8  ! passo em lat

  ! Fill value para pontos da grade sem nenhuma célula Voronoi
  real(ESMF_KIND_R8), parameter :: FILL_VALUE = -9.99e+20_ESMF_KIND_R8

  ! ── Coordenadas globais (módulo save — preenchidas por netcdf_init_coords)
  real(ESMF_KIND_R8), allocatable, save :: g_lon_global(:)  ! (nGlobal) graus
  real(ESMF_KIND_R8), allocatable, save :: g_lat_global(:)  ! (nGlobal) graus
  logical,                          save :: g_coords_ready = .false.

  ! ── Decomposição MPI salva (BUG FIX v2.8 — Bug 3) ───────────────────────
  ! Garante que allCounts/displs em export_write_netcdf sejam idênticos
  ! aos usados em netcdf_init_coords, evitando mapeamento geográfico errado.
  integer,                          save :: g_nLocal_saved  = 0
  integer,                          save :: g_nGlobal_saved = 0
  integer, allocatable,             save :: g_allCounts_saved(:)
  integer, allocatable,             save :: g_displs_saved(:)

  character(len=256), save :: OUTPUT_DIR = 'diag_export'
  integer,            parameter :: MAX_RAW = 15
  integer,            save      :: g_n_raw   = 0
  character(len=64),  save      :: g_raw_names(MAX_RAW)
  real(ESMF_KIND_R8), allocatable, save :: g_raw_local(:,:)
  real(ESMF_KIND_R8), allocatable, save :: g_lon_local_saved(:)
  real(ESMF_KIND_R8), allocatable, save :: g_lat_local_saved(:)
  character(len=*), parameter :: u_FILE_u   = __FILE__

  ! ── Estado do diagnóstico de importação MED→MPAS (migrado de mpas_cap_methods) ──
  !
  ! g_diag_yr == 0 → clock ainda não configurado (bootstrap ou teste unitário):
  !   write_mpas_import_diag usa fallback por contador de passos.
  ! set_mpas_diag_clock deve ser chamada em ModelAdvance ANTES de mpas_import.
  integer, private, save :: g_diag_yr   = 0, g_diag_mo = 0, g_diag_dy = 0
  integer, private, save :: g_diag_hr   = 0, g_diag_mn = 0, g_diag_sc = 0
  integer, private, save :: g_diag_step = 0   ! contador incremental de chamadas

contains

  !> @brief Configura os parâmetros de grade e diretório de saída a partir do namelist.
  !!
  !! Deve ser chamada em InitializeRealize antes de netcdf_init_coords.
  !! @param[in] res_deg   Resolução da grade em graus (ex: 1.0, 0.5, 0.25)
  !! @param[in] out_dir   Diretório de saída para os arquivos NetCDF
  !! @param[in] localPet  PET local do ESMF — suprime impressão em PETs > 0 (B-30)
  subroutine netcdf_config_set(res_deg, out_dir, localPet)
    real,             intent(in) :: res_deg
    character(len=*), intent(in) :: out_dir
    integer,          intent(in) :: localPet   ! B-30: guarda de rank

    GRID_RES   = res_deg
    DLON       = real(res_deg, ESMF_KIND_R8)
    DLAT       = real(res_deg, ESMF_KIND_R8)
    NLON       = nint(360.0 / res_deg)
    NLAT       = nint(180.0 / res_deg) + 1
    OUTPUT_DIR = trim(out_dir)

    ! B-30: sem guarda, N PETs × N chamadas = N² mensagens em stdout.
    ! Só PET 0 imprime; demais passam silenciosamente.
    if (localPet == 0) &
      write(*,'(A,F5.2,A,I0,A,I0,A,A)') &
        '[NetCDF] grade configurada: ', res_deg, '° -> NLON=', NLON, &
        ' NLAT=', NLAT, ' output_dir=', trim(OUTPUT_DIR)
  end subroutine netcdf_config_set

  ! ============================================================================
  !> Coleta coordenadas locais de todos os PETs via MPI_Gatherv e armazena no PET0.
  !!
  !! Deve ser chamada UMA VEZ em InitializeRealize do cap, após a malha ESMF
  !! estar disponível e ANTES da primeira chamada a export_write_netcdf.
  !!
  !! A decomposição MPI_Gatherv usada aqui é idêntica à de export_write_netcdf
  !! para os campos, garantindo que lon_global(i)/lat_global(i) corresponde
  !! exatamente ao dado(i) em recvBuf — eliminando o padrão de xadrez.
  !!
  !! Chamada idempotente (retorna imediatamente se já executada).
  !!
  !! Uso em mpas_cap.F90 (InitializeRealize), após ESMF_MeshGet:
  !!   call netcdf_init_coords(lon_local, lat_local, nLocalElem, vm, rc)
  subroutine netcdf_init_coords(lon_local, lat_local, nLocal, vm, rc)
    real(ESMF_KIND_R8), intent(in)    :: lon_local(:)   ! longitudes do PET (graus)
    real(ESMF_KIND_R8), intent(in)    :: lat_local(:)   ! latitudes  do PET (graus)
    integer,            intent(in)    :: nLocal          ! número de células locais
    type(ESMF_VM),      intent(in)    :: vm
    integer,            intent(inout) :: rc

    integer :: localPet, petCount, mpiComm, mpi_ierr, i, nGlobal
    integer, allocatable :: allCounts(:), displs(:)
    character(len=*), parameter :: subname = '(netcdf_init_coords)'

    rc = ESMF_SUCCESS
    if (g_coords_ready) return   ! idempotente

    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, &
                    mpiCommunicator=mpiComm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! ── Reunir tamanhos locais de cada PET ────────────────────────────────
    allocate(allCounts(petCount))
    call MPI_Allgather(nLocal, 1, MPI_INTEGER, &
                       allCounts, 1, MPI_INTEGER, mpiComm, mpi_ierr)
    if (mpi_ierr /= MPI_SUCCESS) then
      call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': MPI_Allgather falhou', &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if
    nGlobal = sum(allCounts)

    allocate(displs(petCount))
    displs(1) = 0
    do i = 2, petCount
      displs(i) = displs(i-1) + allCounts(i-1)
    end do

    ! ── Alocar buffers (PETs >0 recebem array mínimo — argumento inativo) ─
    if (localPet == 0) then
      allocate(g_lon_global(nGlobal))
      allocate(g_lat_global(nGlobal))
    else
      allocate(g_lon_global(1))
      allocate(g_lat_global(1))
    end if

    ! ── Gather de lon e lat ────────────────────────────────────────────────
    call MPI_Gatherv(lon_local, nLocal, MPI_DOUBLE_PRECISION, &
                     g_lon_global, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)
    if (mpi_ierr /= MPI_SUCCESS .and. localPet == 0) &
      write(*,'(A)') '[NetCDF] AVISO: MPI_Gatherv de lon_local falhou'

    call MPI_Gatherv(lat_local, nLocal, MPI_DOUBLE_PRECISION, &
                     g_lat_global, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)
    if (mpi_ierr /= MPI_SUCCESS .and. localPet == 0) &
      write(*,'(A)') '[NetCDF] AVISO: MPI_Gatherv de lat_local falhou'

    ! BUG FIX v2.8: salvar decomposicao MPI para reuso em export_write_netcdf.
    ! Garante que recvBuf(i) corresponde a g_lon/lat_global(i) — sem desfase.
    g_nLocal_saved  = nLocal
    g_nGlobal_saved = nGlobal
    allocate(g_allCounts_saved(petCount))
    allocate(g_displs_saved(petCount))
    g_allCounts_saved = allCounts
    g_displs_saved    = displs
    if (allocated(g_lon_local_saved)) deallocate(g_lon_local_saved)
    if (allocated(g_lat_local_saved)) deallocate(g_lat_local_saved)
    allocate(g_lon_local_saved(nLocal))
    allocate(g_lat_local_saved(nLocal))
    g_lon_local_saved = lon_local(1:nLocal)
    g_lat_local_saved = lat_local(1:nLocal)

    ! CORREÇÃO 1: alocar g_raw_local AQUI onde g_nLocal_saved > 0 é garantido.
    ! Se alocado em push_raw_field, g_nLocal_saved pode ser 0 → size=1 → OOB/skip.
    if (allocated(g_raw_local)) deallocate(g_raw_local)
    allocate(g_raw_local(nLocal, MAX_RAW))
    g_raw_local = 0.0_ESMF_KIND_R8
    g_n_raw = 0  ! resetar contagem de campos (nova execução)

    deallocate(allCounts, displs)
    g_coords_ready = .true.

    if (localPet == 0) then
      write(*,'(A,I0,A)') &
        '[NetCDF] Coordenadas prontas: ', nGlobal, ' células (grade 1° pronta)'
      call ESMF_LogWrite(subname//': '//trim(int_to_str(nGlobal))// &
                         ' células — interpolação lat/lon ativa', ESMF_LOGMSG_INFO)
    end if

  end subroutine netcdf_init_coords

  ! ============================================================================
  !> Reúne campos do exportState, interpola para grade lat/lon e escreve NetCDF.
  !!
  !! Fluxo por campo (todos os PETs participam nas chamadas MPI coletivas):
  !!   1. MPI_Gatherv → recvBuf(nGlobal) no PET0
  !!   2. voronoi_to_latlon (PET0): nearest-neighbor binning + filtro de outliers
  !!   3. nf90_put_var: escreve grid(NLON,NLAT) → Python lê como (nlat,nlon)
  !!
  !! Todos os campos chegam já em unidades instantâneas de mpas_atm_model.F90
  !! (sem conversão de acumulados aqui).
  !> FIX-EXP v2: salva dado MPAS LOCAL deste PET — sem MPI aqui.
  !! Todos os PETs têm g_raw_local(nLocal, MAX_RAW) com seus próprios dados.
  subroutine netcdf_push_raw_field(fname, data1d, nLocal, vm, rc)
    character(len=*),   intent(in)    :: fname
    real(ESMF_KIND_R8), intent(in)    :: data1d(:)
    integer,            intent(in)    :: nLocal
    type(ESMF_VM),      intent(in)    :: vm
    integer,            intent(inout) :: rc
    integer :: idx, k, localPet, petCount
    rc = ESMF_SUCCESS
    if (.not. g_coords_ready .or. nLocal <= 0) return
    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
    if (rc /= ESMF_SUCCESS) then; rc = ESMF_SUCCESS; return; end if
    do idx = 1, g_n_raw
      if (trim(g_raw_names(idx)) == trim(fname)) then
        if (allocated(g_raw_local) .and. size(g_raw_local,1) >= nLocal) &
          g_raw_local(1:nLocal, idx) = data1d(1:nLocal)
        return
      end if
    end do
    if (g_n_raw >= MAX_RAW) return
    g_n_raw = g_n_raw + 1
    g_raw_names(g_n_raw) = trim(fname)
    ! g_raw_local já alocado em netcdf_init_coords com tamanho nLocal correto
    if (allocated(g_raw_local) .and. size(g_raw_local,1) >= nLocal) then
      g_raw_local(1:nLocal, g_n_raw) = data1d(1:nLocal)
    end if
  end subroutine netcdf_push_raw_field

  subroutine export_write_netcdf(exportState,               &
                                  elapsed_s,                &
                                  s_yr, s_mo, s_dy,         &
                                  s_hr, s_mn, s_sc,         &
                                  vm, rc)
    type(ESMF_State), intent(in)    :: exportState
    integer,          intent(in)    :: elapsed_s
    integer,          intent(in)    :: s_yr, s_mo, s_dy, s_hr, s_mn, s_sc
    type(ESMF_VM),    intent(in)    :: vm
    integer,          intent(inout) :: rc

    ! Locais
    integer :: localPet, petCount, mpiComm, mpi_ierr
    integer :: i, itemCount, nLocal, nGlobal
    integer :: ncid, varid, ncstat
    integer :: dimid_lat, dimid_lon, dimid_t
    integer :: varid_lat, varid_lon, varid_t
    integer :: c_yr, c_mo, c_dy, c_hr, c_mn, c_sc
    integer :: st_yr, st_mo, st_dy, st_hr, st_mn, st_sc

    character(len=64),  allocatable :: fldnames(:)
    integer,            allocatable :: allCounts(:), displs(:)
    real(ESMF_KIND_R8), allocatable :: sendBuf(:), recvBuf(:)

    real(ESMF_KIND_R8), allocatable :: grid_2d(:,:)
    real(ESMF_KIND_R8) :: lat_axis(NLAT), lon_axis(NLON)
    real(ESMF_KIND_R8) :: time_val, othr

    type(ESMF_Field) :: field
    character(len=36) :: fname_base
    character(len=64) :: fname
    character(len=19) :: valid_time_iso, time_units_str
    integer :: cmd_stat
    character(len=*), parameter :: subname = '(export_write_netcdf)'

    rc = ESMF_SUCCESS

    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, &
                    mpiCommunicator=mpiComm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! Coordenadas requeridas — preenchidas por netcdf_init_coords em InitializeRealize
    if (.not. g_coords_ready) then
      if (localPet == 0) write(*,'(A)') &
        '[NetCDF] ERRO: netcdf_init_coords nao foi chamado em InitializeRealize.'
      rc = ESMF_FAILURE
      return
    end if

    ! ── 0. Data/hora do passo ─────────────────────────────────────────────
    ! s_yr..s_sc = currTime (ESMF_ClockGet em ModelRun) → nome do arquivo.
    ! elapsed_s  = step_count * dt_coupling_s (calculado pelo chamador)
    !            → variável CF time: "elapsed_s seconds since startTime".
    c_yr = s_yr; c_mo = s_mo; c_dy = s_dy
    c_hr = s_hr; c_mn = s_mn; c_sc = s_sc

    ! ── 1. Inventário do exportState ──────────────────────────────────────
    call ESMF_StateGet(exportState, itemCount=itemCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    if (itemCount == 0) return

    allocate(fldnames(itemCount))
    call ESMF_StateGet(exportState, itemNameList=fldnames, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! ── 2-3. Decomposição MPI reutilizada de netcdf_init_coords (BUG FIX v2.8)
    ! Antes: nLocal = size(fptr) [localCells_ESMF] podia diferir do nLocal
    ! usado em netcdf_init_coords [min(localCells_ESMF, nCells_MPAS)],
    ! gerando allCounts distintos e mapeamento geográfico errado no NetCDF.
    ! Agora: reutilizar exatamente os mesmos allCounts/displs do init_coords
    ! garante que recvBuf(i) corresponde a g_lon/lat_global(i).
    nLocal  = g_nLocal_saved
    nGlobal = g_nGlobal_saved
    allocate(allCounts(petCount), displs(petCount))
    allCounts = g_allCounts_saved
    displs    = g_displs_saved
    rc = ESMF_SUCCESS

    ! ── 4. Buffers ────────────────────────────────────────────────────────
    allocate(sendBuf(max(nLocal, 1)))
    if (localPet == 0) then
      allocate(recvBuf(max(nGlobal, 1)))
    else
      allocate(recvBuf(1))
    end if

    ! ── 5. PET0: criar e definir estrutura do arquivo NetCDF ──────────────
    if (localPet == 0) then
      fname_base     = datetime_to_fname(c_yr,c_mo,c_dy,c_hr,c_mn,c_sc)
      fname          = trim(OUTPUT_DIR)//'/'//trim(fname_base)
      valid_time_iso = datetime_to_iso(c_yr,c_mo,c_dy,c_hr,c_mn,c_sc)
      ! startTime = currTime - elapsed_s (para CF time_units "seconds since startTime")
      call datetime_add_seconds(s_yr,s_mo,s_dy,s_hr,s_mn,s_sc, -elapsed_s, &
                                 st_yr,st_mo,st_dy,st_hr,st_mn,st_sc)
      time_units_str = datetime_to_cf_base(st_yr,st_mo,st_dy,st_hr,st_mn,st_sc)
      time_val       = real(elapsed_s, ESMF_KIND_R8)

      call execute_command_line('mkdir -p '//trim(OUTPUT_DIR), exitstat=cmd_stat)

      allocate(grid_2d(NLON, NLAT))

      ncstat = nf90_create(trim(fname), NF90_CLOBBER, ncid)
      if (ncstat /= NF90_NOERR) then
        write(*,'(3A)') '[NetCDF] ERRO ao criar ', trim(fname), &
          ': '//trim(nf90_strerror(ncstat))
        call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': nf90_create falhou', &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc)
        return
      end if

      ! ── Atributos globais CF-1.8 ────────────────────────────────────────
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'Conventions',    'CF-1.8')
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'title',          &
               'MPAS-A exportState — grade regular 1° lat/lon — NUOPC/CMEPS')
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'source',         &
               'NUOPC-MPAS-Integrado v5.2 (mpas_cap_netcdf_mod v2.7)')
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'institution',    &
               'INPE / CGCT / DIMNT')
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'valid_time',     &
               trim(valid_time_iso))
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'start_time',     &
               datetime_to_iso(s_yr,s_mo,s_dy,s_hr,s_mn,s_sc))
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'elapsed_time_s', elapsed_s)
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'ncells_global',  nGlobal)
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'petCount',       petCount)
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'grid_resolution','1.0 degree')
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'interp_method',  &
               'Nearest-neighbor binning, Voronoi x1.40962 (~120 km) -> 1 deg')
      ncstat = nf90_put_att(ncid, NF90_GLOBAL, 'processing_note', &
               'Faxa_swdn/lwdn/prec: media do intervalo de acoplamento (incremento/dt). ' // &
               'Faxa_taux/tauy: rho*ust^2*(u,v)/|V10|, outliers |v|>10 N/m2 descartados. ' // &
               'time: seconds since startTime (CF-1.8).')

      ! ── Dimensões ────────────────────────────────────────────────────────
      ! lat e lon — sem dimensão time (1 arquivo por passo)
      ncstat = nf90_def_dim(ncid, 'lat', NLAT, dimid_lat)
      if (ncstat /= NF90_NOERR) then
        write(*,'(A)') '[NetCDF] ERRO nf90_def_dim(lat): '//trim(nf90_strerror(ncstat))
        ncstat = nf90_close(ncid)
        call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': nf90_def_dim falhou', &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc); return
      end if
      ncstat = nf90_def_dim(ncid, 'lon', NLON, dimid_lon)

      ! ── Variáveis de coordenada ──────────────────────────────────────────
      ncstat = nf90_def_var(ncid, 'lat', NF90_DOUBLE, [dimid_lat], varid_lat)
      ncstat = nf90_put_att(ncid, varid_lat, 'long_name',     'latitude')
      ncstat = nf90_put_att(ncid, varid_lat, 'units',         'degrees_north')
      ncstat = nf90_put_att(ncid, varid_lat, 'standard_name', 'latitude')
      ncstat = nf90_put_att(ncid, varid_lat, 'axis',          'Y')

      ncstat = nf90_def_var(ncid, 'lon', NF90_DOUBLE, [dimid_lon], varid_lon)
      ncstat = nf90_put_att(ncid, varid_lon, 'long_name',     'longitude')
      ncstat = nf90_put_att(ncid, varid_lon, 'units',         'degrees_east')
      ncstat = nf90_put_att(ncid, varid_lon, 'standard_name', 'longitude')
      ncstat = nf90_put_att(ncid, varid_lon, 'axis',          'X')

      ncstat = nf90_def_dim(ncid, 'time', NF90_UNLIMITED, dimid_t)
      ncstat = nf90_def_var(ncid, 'time', NF90_DOUBLE, [dimid_t], varid_t)
      ncstat = nf90_put_att(ncid, varid_t, 'long_name', &
               'tempo da simulacao ao final do passo de acoplamento')
      ncstat = nf90_put_att(ncid, varid_t, 'units',     &
               'seconds since '//trim(time_units_str))
      ncstat = nf90_put_att(ncid, varid_t, 'calendar',  'gregorian')
      ncstat = nf90_put_att(ncid, varid_t, 'valid_time',trim(valid_time_iso))

      ! ── Variáveis dos campos (lon, lat) em Fortran column-major ──────────
      ! Python: nc['campo'][:] → shape (NLAT, NLON) = (181, 360)  ✓
      do i = 1, itemCount
        ncstat = nf90_def_var(ncid, trim(fldnames(i)), NF90_DOUBLE, &
                              [dimid_lon, dimid_lat], varid)
        if (ncstat /= NF90_NOERR) then
          write(*,'(3A)') '[NetCDF] AVISO nf90_def_var: ', &
            trim(fldnames(i)), ' — '//trim(nf90_strerror(ncstat))
          cycle
        end if
        ncstat = nf90_put_att(ncid, varid, 'long_name',     &
                 field_long_name(fldnames(i)))
        ncstat = nf90_put_att(ncid, varid, 'units',         &
                 field_units(fldnames(i)))
        ncstat = nf90_put_att(ncid, varid, 'standard_name', &
                 field_stdname(fldnames(i)))
        ncstat = nf90_put_att(ncid, varid, 'CMEPS_name',    trim(fldnames(i)))
        ncstat = nf90_put_att(ncid, varid, '_FillValue',    FILL_VALUE)
        ncstat = nf90_put_att(ncid, varid, 'missing_value', FILL_VALUE)
      end do

      ncstat = nf90_enddef(ncid)
      if (ncstat /= NF90_NOERR) then
        write(*,'(A)') '[NetCDF] ERRO nf90_enddef: '//trim(nf90_strerror(ncstat))
        call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': nf90_enddef falhou', &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc)
        if (allocated(grid_2d)) deallocate(grid_2d)
        ncstat = nf90_close(ncid); return
      end if

      ! ── Escrever eixos e time ────────────────────────────────────────────
      do i = 1, NLAT
        lat_axis(i) = -90.0_ESMF_KIND_R8 + real(i-1, ESMF_KIND_R8) * DLAT
      end do
      do i = 1, NLON
        lon_axis(i) = -180.0_ESMF_KIND_R8 + real(i-1, ESMF_KIND_R8) * DLON
      end do
      ncstat = nf90_put_var(ncid, varid_lat, lat_axis)
      ncstat = nf90_put_var(ncid, varid_lon, lon_axis)
      ncstat = nf90_put_var(ncid, varid_t,   time_val)

    end if   ! localPet == 0

    ! ── 6. Loop por campo: per-PET voronoi + MPI_Allreduce (FIX-EXP v2) ──────
    block
      real(ESMF_KIND_R8) :: acc_local(NLON,NLAT), acc_global(NLON,NLAT)
      integer            :: cnt_local(NLON,NLAT), cnt_global(NLON,NLAT)
      integer :: raw_idx, jr

      do i = 1, itemCount
        raw_idx = 0
        do jr = 1, g_n_raw
          if (trim(g_raw_names(jr)) == trim(fldnames(i))) then; raw_idx = jr; exit; end if
        end do

        othr = field_outlier_threshold(fldnames(i))
        acc_local = 0.0_ESMF_KIND_R8; cnt_local = 0

        if (raw_idx > 0 .and. allocated(g_raw_local) .and. g_nLocal_saved > 0 .and. &
            allocated(g_lon_local_saved)) then
          ! FIX-EXP v2: g_raw_local(1:nLocal, idx) — dados LOCAIS deste PET em MPAS ordering
          ! g_lon_local_saved — coordenadas LOCAL em MPAS ordering → sem OOB, sem mismatch
          call voronoi_accum_local( &
            g_raw_local(1:g_nLocal_saved, raw_idx), &
            g_lon_local_saved(1:g_nLocal_saved),    &
            g_lat_local_saved(1:g_nLocal_saved),    &
            g_nLocal_saved, acc_local, cnt_local, othr)
        else
          ! Fallback ESMF field — cobertura parcial
          sendBuf(1:max(nLocal,1)) = 0.0_ESMF_KIND_R8
          call ESMF_StateGet(exportState, itemName=trim(fldnames(i)), field=field, rc=rc)
          if (rc == ESMF_SUCCESS) then
            block
              real(ESMF_KIND_R8), pointer :: fp1(:), fp2(:,:); integer :: rk
              nullify(fp1,fp2)
              call ESMF_FieldGet(field, dimCount=rk, rc=rc)
              if (rc==ESMF_SUCCESS) then
                if (rk==1) then
                  call ESMF_FieldGet(field, farrayPtr=fp1, rc=rc)
                  if (rc==ESMF_SUCCESS .and. associated(fp1) .and. size(fp1)>=nLocal) &
                    sendBuf(1:nLocal)=fp1(1:nLocal)
                  if (associated(fp1)) nullify(fp1)
                else
                  call ESMF_FieldGet(field, farrayPtr=fp2, rc=rc)
                  if (rc==ESMF_SUCCESS .and. associated(fp2)) then
                    block; real(ESMF_KIND_R8), allocatable :: flat(:)
                    flat=pack(fp2,.true.)
                    if (size(flat)>=nLocal) sendBuf(1:nLocal)=flat(1:nLocal); end block
                  end if
                  if (associated(fp2)) nullify(fp2)
                end if
              end if
            end block
          end if
          rc = ESMF_SUCCESS
          if (allocated(g_lon_local_saved) .and. nLocal>0) &
            call voronoi_accum_local(sendBuf(1:nLocal), g_lon_local_saved(1:nLocal), &
              g_lat_local_saved(1:nLocal), nLocal, acc_local, cnt_local, othr)
        end if

        ! W1-FIX (v12.0): wrappers isoladas em módulo separado (mpi_allreduce_wrappers_mod).
        call allreduce_r8(acc_local, acc_global, NLON*NLAT, mpiComm, mpi_ierr)
        call allreduce_i4(cnt_local, cnt_global, NLON*NLAT, mpiComm, mpi_ierr)

        if (localPet == 0) then
          grid_2d = FILL_VALUE
          where (cnt_global > 0) grid_2d = acc_global / real(cnt_global, ESMF_KIND_R8)
          ncstat = nf90_inq_varid(ncid, trim(fldnames(i)), varid)
          if (ncstat == NF90_NOERR) then
            ncstat = nf90_put_var(ncid, varid, grid_2d)
            if (ncstat /= NF90_NOERR) &
              write(*,'(3A)') '[NetCDF] AVISO nf90_put_var: ', &
                trim(fldnames(i)), ' '//trim(nf90_strerror(ncstat))
          end if
        end if
      end do ! campos
    end block

        ! ── 7. PET0: fechar arquivo ───────────────────────────────────────────
    if (localPet == 0) then
      if (allocated(grid_2d)) deallocate(grid_2d)
      ncstat = nf90_close(ncid)
      if (ncstat == NF90_NOERR) then
        write(*,'(A,4A)') '[NetCDF] Escrito (', trim(valid_time_iso), ') → ', trim(fname), ''
        call ESMF_LogWrite(subname//': '//trim(fname)//' escrito', &
                           ESMF_LOGMSG_INFO)
      else
        write(*,'(A)') '[NetCDF] AVISO nf90_close: '//trim(nf90_strerror(ncstat))
      end if
    end if

    deallocate(fldnames, allCounts, displs, sendBuf, recvBuf)

  end subroutine export_write_netcdf

  ! ============================================================================
  !> Nearest-neighbor binning: mapeia células Voronoi para grade regular NLON×NLAT.
  !!
  !! Para cada célula k:
  !!   1. Descartar se |data_in(k)| > outlier_thr (fill value ou lixo de memória)
  !!   2. Normalizar longitude para [-180, 180)
  !!   3. Calcular índice Fortran (ilon, ilat) do ponto de grade mais próximo:
  !!        ilon = nint((lon + 180) / DLON) + 1   [1..NLON]
  !!        ilat = nint((lat +  90) / DLAT) + 1   [1..NLAT]
  !!   4. Acumular soma e contagem
  !!
  !! Após o loop:
  !!   grid_out(ilon,ilat) = soma / contagem   onde cnt > 0
  !!   grid_out(ilon,ilat) = FILL_VALUE        onde cnt = 0
  !!
  !! Spray adaptativo em longitude (ver detalhes nos comentários inline).
  !! Todos os campos chegam já em unidades corretas — sem conversão aqui.
  !> Acumulação per-PET — não normaliza. Usar com MPI_Allreduce(SUM).
  subroutine voronoi_accum_local(data_in, lon_v, lat_v, n, acc, cnt, outlier_thr)
    real(ESMF_KIND_R8), intent(in)    :: data_in(n), lon_v(n), lat_v(n)
    integer,            intent(in)    :: n
    real(ESMF_KIND_R8), intent(inout) :: acc(NLON, NLAT)
    integer,            intent(inout) :: cnt(NLON, NLAT)
    real(ESMF_KIND_R8), intent(in)    :: outlier_thr
    integer,   parameter :: NSPAN_LAT = 1
    real(ESMF_KIND_R8), parameter :: CELL_HALF = 0.60_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: PI = 3.14159265358979323846_ESMF_KIND_R8
    real(ESMF_KIND_R8) :: val, lon_n, cos_lat
    integer :: k, ic, jc, i2, j2, di, dj, ns
    do k = 1, n
      val = data_in(k)
      if (abs(val) > outlier_thr .or. val /= val) cycle
      lon_n = lon_v(k)
      do while (lon_n >= 180.0_ESMF_KIND_R8); lon_n = lon_n - 360.0_ESMF_KIND_R8; end do
      do while (lon_n < -180.0_ESMF_KIND_R8); lon_n = lon_n + 360.0_ESMF_KIND_R8; end do
      ic = nint((lon_n + 180.0_ESMF_KIND_R8) / DLON) + 1
      jc = nint((lat_v(k) + 90.0_ESMF_KIND_R8) / DLAT) + 1
      ic = min(max(ic,1),NLON); jc = min(max(jc,1),NLAT)
      cos_lat = max(cos(lat_v(k)*PI/180.0_ESMF_KIND_R8), 0.009_ESMF_KIND_R8)
      ns = min(max(int(CELL_HALF/(cos_lat*DLON))+1, NSPAN_LAT), NLON/4)
      do dj = -NSPAN_LAT, NSPAN_LAT
        j2 = min(max(jc+dj,1),NLAT)
        do di = -ns, ns
          i2 = ic+di
          if (i2 < 1)    i2 = i2 + NLON
          if (i2 > NLON) i2 = i2 - NLON
          acc(i2,j2) = acc(i2,j2) + val
          cnt(i2,j2) = cnt(i2,j2) + 1
        end do
      end do
    end do
  end subroutine voronoi_accum_local

  ! W2-FIX (v12.0): subroutine voronoi_to_latlon removida — dead code.
  ! Supersedida pela arquitetura distribuída voronoi_accum_local + MPI_Allreduce
  ! introduzida na versão FIX-EXP v2. A lógica de spray por célula Voronoi foi
  ! preservada e incorporada em voronoi_accum_local (operação per-PET local).

  ! ============================================================================
  ! Funções auxiliares de metadados de campo
  ! ============================================================================

  !> Limiar de outlier por campo.
  !! Faxa_taux/tauy: máximo físico realista de stress superficial ≈ 3–5 N/m²
  !!   (furacão Cat.5: ~3 N/m²); limiar = 10 N/m² com margem.
  !!   Com cálculo correto via ust, não há mais lixo de memória — apenas
  !!   células com wind-shear extremo podem ultrapassar 5 N/m².
  !! Demais campos: 1e30 (captura apenas fill value -9.99e33).
  !> Limiar de outlier por campo (filtra lixo de memória e fill values).
  !!
  !! Faxa_taux/tauy: stress superficial máximo físico ≈ 3–5 N/m² (furacão Cat.5);
  !!   limiar = 10 N/m² com margem de segurança.
  !!
  !! Sa_u10m_mpas / Sa_v10m_mpas: vento 10 m. Valores > 10 m/s são NORMAIS
  !!   (jatos de baixos níveis, alísios fortes, ciclones extratropicais);
  !!   usar 10 m/s cortava 2.6% dos bins — justamente os de vento forte —
  !!   reduzindo σ_cap em 7% vs σ_standalone (Bug B-28).
  !!   Limiar correto: 150 m/s (fisicamente impossível → só filtra garbage).
  !!
  !! Demais campos: 1e30 (captura apenas fill value -9.99e33).
  pure real(ESMF_KIND_R8) function field_outlier_threshold(fname)
    character(len=*), intent(in) :: fname
    select case (trim(fname))
      case ('Faxa_taux', 'Faxa_tauy')
        ! Stress superficial: max Cat.5 ≈ 3 N/m²; limiar = 10 N/m²
        field_outlier_threshold = 10.0_ESMF_KIND_R8
      case ('Sa_u10m_mpas', 'Sa_v10m_mpas')
        ! Vento 10m: fisicamente impossível acima de 150 m/s
        field_outlier_threshold = 150.0_ESMF_KIND_R8
      case ('Sa_tbot_mpas', 'Sa_tbot')
        ! Temperatura 2m: 150-400 K é o range físico; acima = lixo
        field_outlier_threshold = 400.0_ESMF_KIND_R8
      case ('Sa_pslv_mpas', 'Sa_pslv')
        ! Pressão NMM: 50000-110000 Pa; acima = lixo de memória
        field_outlier_threshold = 115000.0_ESMF_KIND_R8
      case ('Sa_shum_mpas', 'Sa_shum')
        ! Umidade específica: máx físico ~0.04 kg/kg (40 g/kg); limiar = 0.1
        field_outlier_threshold = 0.1_ESMF_KIND_R8
      case ('Faxa_swdn_mpas', 'Faxa_swdn')
        ! SW descendente: máx TOA = 1361 W/m²; limiar generoso = 1500
        field_outlier_threshold = 1500.0_ESMF_KIND_R8
      case ('Faxa_lwdn_mpas', 'Faxa_lwdn')
        ! LW descendente: máx ~600 W/m² (tropical convectivo); limiar = 700
        field_outlier_threshold = 700.0_ESMF_KIND_R8
      case ('Faxa_rain_mpas', 'Faxa_rain')
        ! Precipitação líquida: máx físico ~0.05 kg/m²/s = 180 mm/h (tufão)
        ! Limiar = 0.1 kg/m²/s para incluir extremos; acima = bug rainnc/dt
        field_outlier_threshold = 0.1_ESMF_KIND_R8
      case ('Faxa_snow_mpas', 'Faxa_snow')
        ! Precipitação sólida: máx físico ~0.01 kg/m²/s; limiar = 0.05
        field_outlier_threshold = 0.05_ESMF_KIND_R8
      case default
        ! Filtra apenas fill value (-9.99e20/e33) e lixo de memória óbvio
        field_outlier_threshold = 1.0e20_ESMF_KIND_R8
    end select
  end function field_outlier_threshold

  !> Unidades dos campos após conversão (corrige metadados do MPAS).
  function field_units(fname) result(units)
    character(len=*), intent(in) :: fname
    character(len=32) :: units
    select case (trim(fname))
      ! Nomes _mpas (cap NUOPC v3+, sufixo identifica fonte MPAS vs DATM)
      case ('Sa_pslv_mpas')                          ; units = 'Pa'
      case ('Sa_tbot_mpas')                          ; units = 'K'
      case ('Sa_u10m_mpas', 'Sa_v10m_mpas')          ; units = 'm s-1'
      case ('Sa_shum_mpas')                          ; units = 'kg kg-1'
      case ('Faxa_swdn_mpas', 'Faxa_lwdn_mpas')      ; units = 'W m-2'
      case ('Faxa_rain_mpas', 'Faxa_snow_mpas')      ; units = 'kg m-2 s-1'
      ! Nomes legado (sem _mpas) para compatibilidade retroativa
      case ('Sa_pslv')                               ; units = 'Pa'
      case ('Sa_tbot')                               ; units = 'K'
      case ('Sa_ubot', 'Sa_vbot')                    ; units = 'm s-1'
      case ('Faxa_swdn', 'Faxa_lwdn')                ; units = 'W m-2'
      case ('Faxa_prec')                             ; units = 'kg m-2 s-1'
      case ('Faxa_taux', 'Faxa_tauy')                ; units = 'N m-2'
      case ('Faxa_lhflx', 'Faxa_shflx')             ; units = 'W m-2'
      case default                                   ; units = '1'
    end select
  end function field_units

  !> Long name descritivo para cada campo CMEPS.
  function field_long_name(fname) result(lname)
    character(len=*), intent(in) :: fname
    character(len=96) :: lname
    select case (trim(fname))
      ! Nomes _mpas
      case ('Sa_pslv_mpas')    ; lname = 'Pressao ao nivel do mar'
      case ('Sa_tbot_mpas')    ; lname = 'Temperatura do ar a 2 m'
      case ('Sa_u10m_mpas')    ; lname = 'Vento zonal a 10 m'
      case ('Sa_v10m_mpas')    ; lname = 'Vento meridional a 10 m'
      case ('Sa_shum_mpas')    ; lname = 'Umidade especifica a 2 m'
      case ('Faxa_swdn_mpas')  ; lname = 'Radiacao SW descendente media no intervalo'
      case ('Faxa_lwdn_mpas')  ; lname = 'Radiacao LW descendente media no intervalo'
      case ('Faxa_rain_mpas')  ; lname = 'Precipitacao liquida media no intervalo'
      case ('Faxa_snow_mpas')  ; lname = 'Precipitacao solida (neve) media no intervalo'
      ! Nomes legado
      case ('Sa_pslv')    ; lname = 'Pressao ao nivel do mar'
      case ('Sa_tbot')    ; lname = 'Temperatura do ar a 2 m'
      case ('Sa_ubot')    ; lname = 'Vento zonal a 10 m'
      case ('Sa_vbot')    ; lname = 'Vento meridional a 10 m'
      case ('Faxa_swdn')  ; lname = 'Radiacao SW descendente media no intervalo de acoplamento'
      case ('Faxa_lwdn')  ; lname = 'Radiacao LW descendente media no intervalo de acoplamento'
      case ('Faxa_prec')  ; lname = 'Taxa de precipitacao total media no intervalo de acoplamento'
      case ('Faxa_taux')  ; lname = 'Tensao de cisalhamento zonal na superficie'
      case ('Faxa_tauy')  ; lname = 'Tensao de cisalhamento meridional na superficie'
      case ('Faxa_lhflx') ; lname = 'Fluxo de calor latente na superficie'
      case ('Faxa_shflx') ; lname = 'Fluxo de calor sensivel na superficie'
      case default        ; lname = trim(fname)
    end select
  end function field_long_name

  !> CF standard_name para campos CMEPS.
  function field_stdname(fname) result(sname)
    character(len=*), intent(in) :: fname
    character(len=80) :: sname
    select case (trim(fname))
      ! Nomes _mpas
      case ('Sa_pslv_mpas')    ; sname = 'air_pressure_at_mean_sea_level'
      case ('Sa_tbot_mpas')    ; sname = 'air_temperature'
      case ('Sa_u10m_mpas')    ; sname = 'eastward_wind'
      case ('Sa_v10m_mpas')    ; sname = 'northward_wind'
      case ('Sa_shum_mpas')    ; sname = 'specific_humidity'
      case ('Faxa_swdn_mpas')  ; sname = 'surface_downwelling_shortwave_flux_in_air'
      case ('Faxa_lwdn_mpas')  ; sname = 'surface_downwelling_longwave_flux_in_air'
      case ('Faxa_rain_mpas')  ; sname = 'rainfall_flux'
      case ('Faxa_snow_mpas')  ; sname = 'snowfall_flux'
      ! Nomes legado
      case ('Sa_pslv')    ; sname = 'air_pressure_at_mean_sea_level'
      case ('Sa_tbot')    ; sname = 'air_temperature'
      case ('Sa_ubot')    ; sname = 'eastward_wind'
      case ('Sa_vbot')    ; sname = 'northward_wind'
      case ('Faxa_swdn')  ; sname = 'surface_downwelling_shortwave_flux_in_air'
      case ('Faxa_lwdn')  ; sname = 'surface_downwelling_longwave_flux_in_air'
      case ('Faxa_prec')  ; sname = 'precipitation_flux'
      case ('Faxa_taux')  ; sname = 'surface_downward_eastward_stress'
      case ('Faxa_tauy')  ; sname = 'surface_downward_northward_stress'
      case ('Faxa_lhflx') ; sname = 'surface_upward_latent_heat_flux'
      case ('Faxa_shflx') ; sname = 'surface_upward_sensible_heat_flux'
      case default        ; sname = 'unknown'
    end select
  end function field_stdname

  ! ── Utilitários de conversão ──────────────────────────────────────────────

  function int_to_str(n) result(s)
    integer, intent(in) :: n; character(len=16) :: s
    write(s,'(I0)') n
  end function int_to_str

  ! ── Aritmética de calendário gregoriano proléptico ────────────────────────

  pure logical function is_leap_year(yr)
    integer, intent(in) :: yr
    is_leap_year = (mod(yr,4)==0 .and. mod(yr,100)/=0) .or. mod(yr,400)==0
  end function is_leap_year

  subroutine datetime_add_seconds(yr,mo,dy,hr,mn,sc, nadd, &
                                   yr_o,mo_o,dy_o,hr_o,mn_o,sc_o)
    integer, intent(in)  :: yr,mo,dy,hr,mn,sc, nadd
    integer, intent(out) :: yr_o,mo_o,dy_o,hr_o,mn_o,sc_o
    integer :: dim(12), tot, extra, dsec
    tot   = hr*3600 + mn*60 + sc + nadd
    extra = tot / 86400
    dsec  = mod(tot, 86400)
    if (dsec < 0) then; extra = extra - 1; dsec = dsec + 86400; end if
    sc_o = mod(dsec, 60); mn_o = mod(dsec/60, 60); hr_o = dsec/3600
    yr_o = yr; mo_o = mo; dy_o = dy + extra
    dim  = [31,28,31,30,31,30,31,31,30,31,30,31]
    if (is_leap_year(yr_o)) dim(2) = 29
    do while (dy_o > dim(mo_o))
      dy_o = dy_o - dim(mo_o); mo_o = mo_o + 1
      if (mo_o > 12) then
        mo_o = 1; yr_o = yr_o + 1
        dim = [31,28,31,30,31,30,31,31,30,31,30,31]
        if (is_leap_year(yr_o)) dim(2) = 29
      end if
    end do
  end subroutine datetime_add_seconds

  ! ── Formatadores de data/hora ─────────────────────────────────────────────

  function datetime_to_fname(yr,mo,dy,hr,mn,sc) result(s)
    integer, intent(in) :: yr,mo,dy,hr,mn,sc; character(len=36) :: s
    write(s,'(A,I4.4,2I2.2,A,3I2.2,A)') 'monan_export_',yr,mo,dy,'_',hr,mn,sc,'.nc'
  end function datetime_to_fname

  function datetime_to_iso(yr,mo,dy,hr,mn,sc) result(s)
    integer, intent(in) :: yr,mo,dy,hr,mn,sc; character(len=19) :: s
    write(s,'(I4.4,A,I2.2,A,I2.2,A,I2.2,A,I2.2,A,I2.2)') &
      yr,'-',mo,'-',dy,'T',hr,':',mn,':',sc
  end function datetime_to_iso

  function datetime_to_cf_base(yr,mo,dy,hr,mn,sc) result(s)
    integer, intent(in) :: yr,mo,dy,hr,mn,sc; character(len=19) :: s
    write(s,'(I4.4,A,I2.2,A,I2.2,A,I2.2,A,I2.2,A,I2.2)') &
      yr,'-',mo,'-',dy,' ',hr,':',mn,':',sc
  end function datetime_to_cf_base

  ! ============================================================================
  ! Diagnóstico de importação MED→MPAS (migrado de mpas_cap_methods.F90 v3.0)
  ! ============================================================================

  !> @brief Configura o timestamp do diagnóstico de importação MPAS.
  !!
  !! Deve ser chamada em ModelAdvance ANTES de mpas_import, para que
  !! write_mpas_import_diag nomeie o arquivo com o carimbo de tempo correto:
  !!   monan2_import_YYYYMMDD_HHMMSS.nc
  !!
  !! @param[in] yr  Ano   (ESMF_TimeGet yy)
  !! @param[in] mo  Mês   (ESMF_TimeGet mm)
  !! @param[in] dy  Dia   (ESMF_TimeGet dd)
  !! @param[in] hr  Hora  (ESMF_TimeGet h)
  !! @param[in] mn  Minuto (ESMF_TimeGet m)
  !! @param[in] sc  Segundo (ESMF_TimeGet s)
  subroutine set_mpas_diag_clock(yr, mo, dy, hr, mn, sc)
    integer, intent(in) :: yr, mo, dy, hr, mn, sc
    g_diag_yr = yr;  g_diag_mo = mo;  g_diag_dy = dy
    g_diag_hr = hr;  g_diag_mn = mn;  g_diag_sc = sc
  end subroutine set_mpas_diag_clock

  !> @brief Escreve diagnóstico dos campos importados do mediador MED→MPAS.
  !!
  !! Grava um arquivo NetCDF por passo de acoplamento em cfg_import_diag_dir,
  !! no mesmo formato dos arquivos monan_export_*.nc (grade lat/lon regular).
  !!
  !! Campos escritos (os 3 campos OCN→ATM que chegam via conector MED→MPAS):
  !!   So_t     — SST [K]           — atm_bnd%sst
  !!   Si_ifrac — fração de gelo    — atm_bnd%ice_fraction
  !!   Sf_zorl  — rugosidade [m]    — atm_bnd%zorl
  !!
  !! Ativado por: write_import_diag=.true. em &nuopc_docn do nuopc.input
  !!
  !! Requer que set_mpas_diag_clock seja chamada em ModelAdvance antes de
  !! mpas_import, e que netcdf_init_coords tenha sido chamado em InitializeRealize.
  subroutine write_mpas_import_diag(atm_bnd, nCells, lonCell, latCell, rc)
    type(atm_ocean_boundary_type), intent(in)  :: atm_bnd
    integer,                       intent(in)  :: nCells
    real(MPAS_RKIND), optional,    intent(in)  :: lonCell(:)
    real(MPAS_RKIND), optional,    intent(in)  :: latCell(:)
    integer,                       intent(out) :: rc

    character(len=*), parameter :: subname = '(write_mpas_import_diag)'
    character(len=256) :: fname
    integer :: ncid, ios
    integer :: dimid_lat, dimid_lon
    integer :: varid_lat, varid_lon
    integer :: varid_sot, varid_ifrac, varid_zorl
    integer :: nlat, nlon, i, j
    real(ESMF_KIND_R8), allocatable :: grid_2d(:,:)
    real(ESMF_KIND_R8), allocatable :: lat_axis(:), lon_axis(:)
    type(ESMF_VM) :: vm
    integer :: localPet, petCount, mpiComm, mpi_ierr
    integer, allocatable  :: allCounts(:), displs(:)
    real(ESMF_KIND_R8), allocatable :: sendBuf(:), recvBuf_sot(:)
    real(ESMF_KIND_R8), allocatable :: recvBuf_ifrac(:), recvBuf_zorl(:)
    real(ESMF_KIND_R8), allocatable :: lon_global(:), lat_global(:)
    integer :: nGlobal, nLocal
    real(ESMF_KIND_R8) :: res_deg, dlon, dlat
    character(len=19) :: ts_str
    character(len=256) :: outdir

    rc = ESMF_SUCCESS
    outdir = trim(cfg_import_diag_dir)

    ! Obter VM e decomposição MPI
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, &
                    mpiCommunicator=mpiComm, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    nLocal = nCells

    ! ── 1. Gather das coordenadas ─────────────────────────────────────────
    allocate(allCounts(petCount), displs(petCount))
    call MPI_Allgather(nLocal, 1, MPI_INTEGER, &
                       allCounts, 1, MPI_INTEGER, mpiComm, mpi_ierr)
    nGlobal = sum(allCounts)
    displs(1) = 0
    do i = 2, petCount
      displs(i) = displs(i-1) + allCounts(i-1)
    end do

    if (localPet == 0) then
      allocate(lon_global(nGlobal), lat_global(nGlobal))
      allocate(recvBuf_sot(nGlobal), recvBuf_ifrac(nGlobal), recvBuf_zorl(nGlobal))
    else
      allocate(lon_global(1), lat_global(1))
      allocate(recvBuf_sot(1), recvBuf_ifrac(1), recvBuf_zorl(1))
    end if

    if (present(lonCell) .and. present(latCell)) then
      allocate(sendBuf(nLocal))
      sendBuf(1:nLocal) = real(lonCell(1:nLocal) * 180.0_MPAS_RKIND / acos(-1.0_MPAS_RKIND), ESMF_KIND_R8)
      call MPI_Gatherv(sendBuf, nLocal, MPI_DOUBLE_PRECISION, &
                       lon_global, allCounts, displs, MPI_DOUBLE_PRECISION, &
                       0, mpiComm, mpi_ierr)
      sendBuf(1:nLocal) = real(latCell(1:nLocal) * 180.0_MPAS_RKIND / acos(-1.0_MPAS_RKIND), ESMF_KIND_R8)
      call MPI_Gatherv(sendBuf, nLocal, MPI_DOUBLE_PRECISION, &
                       lat_global, allCounts, displs, MPI_DOUBLE_PRECISION, &
                       0, mpiComm, mpi_ierr)
      deallocate(sendBuf)
    end if

    ! ── 2. Gather dos campos ──────────────────────────────────────────────
    allocate(sendBuf(nLocal))

    if (allocated(atm_bnd%sst)) then
      sendBuf(1:nLocal) = real(atm_bnd%sst(1:nLocal), ESMF_KIND_R8)
    else
      sendBuf = 0.0_ESMF_KIND_R8
    end if
    call MPI_Gatherv(sendBuf, nLocal, MPI_DOUBLE_PRECISION, &
                     recvBuf_sot, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)

    if (allocated(atm_bnd%ice_fraction)) then
      sendBuf(1:nLocal) = real(atm_bnd%ice_fraction(1:nLocal), ESMF_KIND_R8)
    else
      sendBuf = 0.0_ESMF_KIND_R8
    end if
    call MPI_Gatherv(sendBuf, nLocal, MPI_DOUBLE_PRECISION, &
                     recvBuf_ifrac, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)

    if (allocated(atm_bnd%zorl)) then
      sendBuf(1:nLocal) = real(atm_bnd%zorl(1:nLocal), ESMF_KIND_R8)
    else
      sendBuf = 0.0_ESMF_KIND_R8
    end if
    call MPI_Gatherv(sendBuf, nLocal, MPI_DOUBLE_PRECISION, &
                     recvBuf_zorl, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)
    deallocate(sendBuf, allCounts, displs)

    ! ── 3. Escrita NetCDF (somente PET 0) ─────────────────────────────────
    if (localPet /= 0) then
      deallocate(lon_global, lat_global)
      deallocate(recvBuf_sot, recvBuf_ifrac, recvBuf_zorl)
      return
    end if

    res_deg = real(cfg_grid_res_deg, ESMF_KIND_R8)
    dlon    = res_deg
    dlat    = res_deg
    nlon    = nint(360.0_ESMF_KIND_R8 / dlon)
    nlat    = nint(180.0_ESMF_KIND_R8 / dlat) + 1

    g_diag_step = g_diag_step + 1

    ! Nome do arquivo: monan2_import_YYYYMMDD_HHMMSS.nc
    !   Fallback por contador quando g_diag_yr == 0 (clock não configurado).
    call execute_command_line('mkdir -p '//trim(outdir), wait=.true.)
    if (g_diag_yr == 0) then
      write(fname,'(A,"/monan2_import_",I4.4,".nc")') trim(outdir), g_diag_step
    else
      write(fname,'(A,"/monan2_import_",I4.4,2I2.2,"_",3I2.2,".nc")') &
        trim(outdir), g_diag_yr, g_diag_mo, g_diag_dy, &
                      g_diag_hr, g_diag_mn, g_diag_sc
    end if

    write(ts_str, '(I4.4,I2.2,I2.2,"_",I2.2,I2.2,I2.2)') &
      g_diag_yr, g_diag_mo, g_diag_dy, g_diag_hr, g_diag_mn, g_diag_sc

    ! Binning Voronoi → grade lat/lon
    allocate(grid_2d(nlon, nlat))
    allocate(lat_axis(nlat), lon_axis(nlon))
    do i = 1, nlat
      lat_axis(i) = -90.0_ESMF_KIND_R8 + (i - 0.5_ESMF_KIND_R8) * dlat
    end do
    do i = 1, nlon
      lon_axis(i) = (i - 0.5_ESMF_KIND_R8) * dlon - 180.0_ESMF_KIND_R8
    end do

    ios = nf90_create(trim(fname), NF90_CLOBBER, ncid)
    if (ios /= NF90_NOERR) goto 999

    ios = nf90_def_dim(ncid, 'lat', nlat, dimid_lat)
    ios = nf90_def_dim(ncid, 'lon', nlon, dimid_lon)
    ios = nf90_def_var(ncid, 'lat', NF90_DOUBLE, [dimid_lat], varid_lat)
    ios = nf90_def_var(ncid, 'lon', NF90_DOUBLE, [dimid_lon], varid_lon)
    ios = nf90_put_att(ncid, varid_lat, 'units', 'degrees_north')
    ios = nf90_put_att(ncid, varid_lon, 'units', 'degrees_east')

    ios = nf90_def_var(ncid, 'So_t',    NF90_DOUBLE, [dimid_lon, dimid_lat], varid_sot)
    ios = nf90_put_att(ncid, varid_sot,   'units',         'K')
    ios = nf90_put_att(ncid, varid_sot,   'long_name',     'SST dinamica MOM6 importada pelo MPAS')
    ios = nf90_put_att(ncid, varid_sot,   'standard_name', 'sea_surface_temperature')
    ios = nf90_put_att(ncid, varid_sot,   '_FillValue',    -9.99e+20_ESMF_KIND_R8)

    ios = nf90_def_var(ncid, 'Si_ifrac', NF90_DOUBLE, [dimid_lon, dimid_lat], varid_ifrac)
    ios = nf90_put_att(ncid, varid_ifrac, 'units',         '1')
    ios = nf90_put_att(ncid, varid_ifrac, 'long_name',     'Fracao de gelo marinho importada pelo MPAS')
    ios = nf90_put_att(ncid, varid_ifrac, 'standard_name', 'sea_ice_area_fraction')
    ios = nf90_put_att(ncid, varid_ifrac, '_FillValue',    -9.99e+20_ESMF_KIND_R8)

    ios = nf90_def_var(ncid, 'Sf_zorl',  NF90_DOUBLE, [dimid_lon, dimid_lat], varid_zorl)
    ios = nf90_put_att(ncid, varid_zorl,  'units',         'm')
    ios = nf90_put_att(ncid, varid_zorl,  'long_name',     'Rugosidade superficial Charnock+Smith importada pelo MPAS')
    ios = nf90_put_att(ncid, varid_zorl,  'standard_name', 'surface_roughness_length')
    ios = nf90_put_att(ncid, varid_zorl,  '_FillValue',    -9.99e+20_ESMF_KIND_R8)

    ios = nf90_put_att(ncid, NF90_GLOBAL, 'Conventions',  'CF-1.8')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'title', &
      'MONAN-A 2.0 importState (= MED exportState MED->MPAS) — Campos OCN->ATM')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'institution',  'INPE/CGCT/DIMNT')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'source', &
      'mpas_cap_netcdf.F90::write_mpas_import_diag (So_t + Si_ifrac + Sf_zorl)')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'code_version', &
      'v3.0-2026-05 (migrado de mpas_cap_methods para mpas_cap_netcdf)')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'step',         g_diag_step)
    ios = nf90_enddef(ncid)

    ios = nf90_put_var(ncid, varid_lat, lat_axis)
    ios = nf90_put_var(ncid, varid_lon, lon_axis)

    ! Binning Voronoi → lat/lon (ocean_frac_min=0.5: elimina artefatos costeiros)
    call voronoi_to_grid(recvBuf_sot,   lon_global, lat_global, nGlobal, &
                         grid_2d, nlon, nlat, dlon, dlat, &
                         vmin=270.0_ESMF_KIND_R8, vmax=310.0_ESMF_KIND_R8, &
                         ocean_frac_min=0.5_ESMF_KIND_R8)
    ios = nf90_put_var(ncid, varid_sot, grid_2d)

    call voronoi_to_grid(recvBuf_ifrac, lon_global, lat_global, nGlobal, &
                         grid_2d, nlon, nlat, dlon, dlat, &
                         vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, &
                         ocean_frac_min=0.5_ESMF_KIND_R8)
    ios = nf90_put_var(ncid, varid_ifrac, grid_2d)

    call voronoi_to_grid(recvBuf_zorl,  lon_global, lat_global, nGlobal, &
                         grid_2d, nlon, nlat, dlon, dlat, &
                         vmin=1.0e-5_ESMF_KIND_R8, vmax=0.1_ESMF_KIND_R8, &
                         ocean_frac_min=0.5_ESMF_KIND_R8)
    ios = nf90_put_var(ncid, varid_zorl, grid_2d)

    ios = nf90_close(ncid)
    deallocate(grid_2d, lat_axis, lon_axis)

    call ESMF_LogWrite(subname//': escrito '//trim(fname), ESMF_LOGMSG_INFO)

999 deallocate(lon_global, lat_global)
    deallocate(recvBuf_sot, recvBuf_ifrac, recvBuf_zorl)

  end subroutine write_mpas_import_diag

  !> @brief Binning Voronoi → grade lat/lon para diagnóstico de importação.
  !!
  !! Algoritmo nearest-neighbor com spray ±1° em lat e adaptativo em lon.
  !! Fill value -9.99e+20 para células sem contribuição.
  !!
  !! Parâmetro opcional ocean_frac_min: fração mínima de células válidas
  !! (oceano) por bin. Recomendado 0.5 — elimina artefatos de arquipélagos.
  subroutine voronoi_to_grid(data_v, lon_v, lat_v, npts, &
                              grid_out, nlon, nlat, dlon, dlat, &
                              vmin, vmax, ocean_frac_min)
    real(ESMF_KIND_R8), intent(in)  :: data_v(:), lon_v(:), lat_v(:)
    integer,            intent(in)  :: npts, nlon, nlat
    real(ESMF_KIND_R8), intent(in)  :: dlon, dlat, vmin, vmax
    real(ESMF_KIND_R8), intent(out) :: grid_out(nlon, nlat)
    real(ESMF_KIND_R8), optional, intent(in) :: ocean_frac_min

    real(ESMF_KIND_R8), allocatable :: acc(:,:)
    integer,            allocatable :: cnt(:,:), cnt_all(:,:)
    real(ESMF_KIND_R8) :: lon_n, cos_lat, val, ofrac_min
    logical :: is_valid
    integer :: k, ic, jc, di, dj, i2, j2, ns
    real(ESMF_KIND_R8), parameter :: PI        = acos(-1.0_ESMF_KIND_R8)
    real(ESMF_KIND_R8), parameter :: CELL_HALF = 0.60_ESMF_KIND_R8
    integer,            parameter :: NSPAN_LAT = 1

    ofrac_min = 0.0_ESMF_KIND_R8
    if (present(ocean_frac_min)) ofrac_min = max(0.0_ESMF_KIND_R8, &
                                                  min(1.0_ESMF_KIND_R8, ocean_frac_min))

    allocate(acc(nlon, nlat), cnt(nlon, nlat), cnt_all(nlon, nlat))
    acc     = 0.0_ESMF_KIND_R8
    cnt     = 0
    cnt_all = 0

    do k = 1, npts
      lon_n = lon_v(k)
      do while (lon_n >= 180.0_ESMF_KIND_R8);  lon_n = lon_n - 360.0_ESMF_KIND_R8; end do
      do while (lon_n < -180.0_ESMF_KIND_R8);  lon_n = lon_n + 360.0_ESMF_KIND_R8; end do
      ! BUG-BIN-OFFSET (Mai/2026): floor é o inverso exato do eixo centrado em bins.
      ic = floor((lon_n    + 180.0_ESMF_KIND_R8) / dlon) + 1
      jc = floor((lat_v(k) +  90.0_ESMF_KIND_R8) / dlat) + 1
      ic = min(max(ic, 1), nlon)
      jc = min(max(jc, 1), nlat)
      cos_lat = max(cos(lat_v(k) * PI / 180.0_ESMF_KIND_R8), 0.009_ESMF_KIND_R8)
      ns = min(max(int(CELL_HALF / (cos_lat * dlon)) + 1, NSPAN_LAT), nlon/4)

      val = data_v(k)
      is_valid = .not. (val < vmin .or. val > vmax .or. val /= val)

      do dj = -NSPAN_LAT, NSPAN_LAT
        j2 = min(max(jc + dj, 1), nlat)
        do di = -ns, ns
          i2 = ic + di
          if (i2 < 1)    i2 = i2 + nlon
          if (i2 > nlon) i2 = i2 - nlon
          cnt_all(i2, j2) = cnt_all(i2, j2) + 1
          if (is_valid) then
            acc(i2, j2) = acc(i2, j2) + val
            cnt(i2, j2) = cnt(i2, j2) + 1
          end if
        end do
      end do
    end do

    grid_out = -9.99e+20_ESMF_KIND_R8
    where (cnt > 0) grid_out = acc / real(cnt, ESMF_KIND_R8)

    if (ofrac_min > 0.0_ESMF_KIND_R8) then
      where (cnt_all > 0 .and. &
             real(cnt, ESMF_KIND_R8) / real(cnt_all, ESMF_KIND_R8) < ofrac_min)
        grid_out = -9.99e+20_ESMF_KIND_R8
      end where
    end if

    deallocate(acc, cnt, cnt_all)

  end subroutine voronoi_to_grid

end module mpas_cap_netcdf_mod
