!> @file mpas_import_diag.F90
!! @brief Diagnóstico dos campos importados do mediador pelo cap MPAS-A.
!!
!! Grava, a cada passo de acoplamento, o arquivo monan2_import_*.nc com os
!! sete membros de atm_ocean_boundary_type numa grade regular lat/lon, com
!! as células de terra mascaradas pela máscara do MOM6 (Sx_omask).
!!
!! Separado de mpas_cap_netcdf.F90 sem mudar instruções (R-FASE8-12); o
!! gravador da forçante exportada (monan_export_*.nc) continua lá.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module mpas_import_diag_mod

  use ESMF
  use coupler_constants_mod, only : FILL_VALUE_R8, PI
  use mpi
  use netcdf
  use nc_writer_mod,      only : nc_create, nc_global_header, nc_def_latlon, nc_def_field2d
  ! Tipos MPAS e configurações necessários para o diagnóstico de importação
  use mpas_atm_types_mod,  only : atm_ocean_boundary_type, MPAS_RKIND
  use coupler_config_mod, only : cfg_import_diag_dir, cfg_grid_res_deg

  implicit none
  private

  public :: write_mpas_import_diag  ! escreve monan2_import_YYYYMMDD_HHMMSS.nc
  public :: set_mpas_diag_clock     ! injeta timestamp de simulação no diagnóstico

  !> Relógio do diagnóstico de importação MED→MPAS (monan2_import_*.nc).
  !! O cap guarda um objeto deste tipo, o atualiza com set_mpas_diag_clock
  !! em ModelAdvance, ANTES de mpas_import, e o passa a
  !! write_mpas_import_diag. Com yr == 0 (relógio ainda não configurado,
  !! como num teste), o arquivo é nomeado pelo contador de chamadas.
  type, public :: mpas_import_diag_clock_t
    integer :: yr = 0, mo = 0, dy = 0
    integer :: hr = 0, mn = 0, sc = 0
    integer :: step = 0   !< contador de chamadas de write_mpas_import_diag
  end type mpas_import_diag_clock_t

  ! Colunas do buffer de campos reunidos em write_mpas_import_diag: uma por
  ! membro de atm_ocean_boundary_type, na ordem em que sao reunidos.
  integer, parameter :: IMP_SOT = 1, IMP_IFRAC = 2, IMP_ZORL = 3, IMP_OMASK = 4
  integer, parameter :: IMP_UOCN = 5, IMP_VOCN = 6, IMP_ALB = 7
  integer, parameter :: N_IMP_DIAG = 7

  ! Limiar de corte da mascara ja' binada. 0,5 e' o mesmo criterio usado
  ! no MED e o mesmo ocean_frac_min do binning dos campos: os tres
  ! precisam concordar, senao a linha de costa do diagnostico do MPAS nao
  ! bate com a do diagnostico do MED.
  real(ESMF_KIND_R8), parameter :: OMASK_MIN = 0.5_ESMF_KIND_R8

contains

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
  !! @param[inout] clk  relógio do diagnóstico, guardado pelo cap
  !! @param[in] sc  Segundo (ESMF_TimeGet s)
  subroutine set_mpas_diag_clock(clk, yr, mo, dy, hr, mn, sc)
    type(mpas_import_diag_clock_t), intent(inout) :: clk
    integer, intent(in) :: yr, mo, dy, hr, mn, sc
    clk%yr = yr;  clk%mo = mo;  clk%dy = dy
    clk%hr = hr;  clk%mn = mn;  clk%sc = sc
  end subroutine set_mpas_diag_clock

  !> @brief Escreve diagnóstico dos campos importados do mediador MED→MPAS.
  !!
  !! Grava um arquivo NetCDF por passo de acoplamento em cfg_import_diag_dir,
  !! no mesmo formato dos arquivos monan_export_*.nc (grade lat/lon regular).
  !!
  !! Campos escritos — os 7 campos OCN→ATM do conector MED→MPAS, um por membro
  !! de atm_ocean_boundary_type:
  !!   So_t       — temp. de pele [K]        — atm_bnd%sst
  !!   Si_ifrac   — fração de gelo [0–1]     — atm_bnd%ice_fraction
  !!   So_u       — corrente zonal [m/s]     — atm_bnd%uocn
  !!   So_v       — corrente meridional      — atm_bnd%vocn
  !!   Sf_zorl    — rugosidade [m]           — atm_bnd%zorl
  !!   Sf_albedo  — albedo de superfície     — atm_bnd%alb
  !!   Sx_omask   — máscara oceano/terra     — atm_bnd%omask
  !!
  !! acrescentados So_u, So_v e
  !!   Sf_albedo. Até aqui a rotina gravava 4 dos 7 campos importados, e a
  !!   ausência era silenciosa: nada no código nem no arquivo indicava que
  !!   três campos ficavam de fora. A consequência prática foi grave. A
  !!   bateria de reprodutibilidade comparava monan2_import_*.nc para decidir
  !!   se o MPAS recebia entrada idêntica entre duas rodadas; como as
  !!   correntes e o albedo não estavam no arquivo, "entrada idêntica em t=0"
  !!   nunca cobriu esses três, e a conclusão de que o MPAS era a fonte da
  !!   não reprodutibilidade foi tirada de uma comparação cega em 3 de 7
  !!   campos. O MPAS-A autônomo, testado fora do acoplador, é bit a bit
  !!   reprodutível — logo a divergência entra por um campo importado.
  !!
  !! INVARIANTE A PRESERVAR: uma variável NetCDF por membro de
  !!   atm_ocean_boundary_type. Ao acrescentar um membro ao tipo (em
  !!   mpas_atm_types.F90) e ao mapa de acoplamento (ponto ATM@atm_cap),
  !!   acrescente aqui também. Não há verificação automática: a rotina
  !!   recebe atm_bnd, não o importState, e por isso não pode iterar sobre
  !!   os campos anunciados. A conferência é visual, contando membros.
  !!
  !! NOTA SOBRE O RÓTULO So_t (ver): a variável se chama
  !!   So_t por compatibilidade com o pós-processamento e as animações, mas o
  !!   campo importado é Sx_tsfc, a temperatura de pele composta (ver
  !!   o ponto ATM@atm_cap do mapa de acoplamento). O nome NÃO foi alterado aqui para
  !!   não quebrar postproc_monan2_import.py e anim_monan2_import.py; a
  !!   renomeação, se feita, tem de ser coordenada com essas ferramentas.
  !!
  !! continentes mascarados com a máscara REAL
  !!   do MOM6 (ocean_grid%mask2dT → So_omask → Sx_omask → atm_bnd%omask).
  !!   Antes havia apenas o filtro ocean_frac_min do binning, que mede
  !!   cobertura de célula Voronoi por bin e nada diz sobre terra/oceano.
  !!   A máscara é binada pela mesma rotina dos campos e gravada como
  !!   Sx_omask (1=oceano, 0=terra); célula de terra sai como _FillValue.
  !!
  !! Etapas: gather_boundary_member (um membro de atm_bnd por chamada, em
  !!   todos os PETs); no PET 0, define_import_diag_file e
  !!   write_import_diag_fields (bin_masked_field, binarize_ocean_mask,
  !!   log_mask_coverage).
  !!
  !! Ativado por: write_import_diag=.true. em &nuopc_docn do nuopc.input
  !!
  !! Requer que set_mpas_diag_clock seja chamada em ModelAdvance antes de
  !! mpas_import, e que netcdf_init_coords tenha sido chamado em InitializeRealize.
  !!
  !! @param[inout] clk  relógio do diagnóstico (data do arquivo e contador)
  subroutine write_mpas_import_diag(clk, atm_bnd, nCells, lonCell, latCell, rc)
    type(mpas_import_diag_clock_t), intent(inout) :: clk
    type(atm_ocean_boundary_type), intent(in)  :: atm_bnd
    integer,                       intent(in)  :: nCells
    real(MPAS_RKIND), optional,    intent(in)  :: lonCell(:)
    real(MPAS_RKIND), optional,    intent(in)  :: latCell(:)
    integer,                       intent(out) :: rc

    character(len=*), parameter :: subname = '(write_mpas_import_diag)'
    integer :: i, nRecv
    type(ESMF_VM) :: vm
    integer :: localPet, petCount, mpiComm, mpi_ierr
    integer, allocatable  :: allCounts(:), displs(:)
    ! Valores reunidos no PET 0, um campo por coluna (indices IMP_*)
    real(ESMF_KIND_R8), allocatable :: recvBuf(:,:)
    real(ESMF_KIND_R8), allocatable :: lon_global(:), lat_global(:)
    integer :: nGlobal, nLocal
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
      nRecv = nGlobal
    else
      nRecv = 1
    end if
    allocate(lon_global(nRecv), lat_global(nRecv))
    allocate(recvBuf(nRecv, N_IMP_DIAG))

    call gather_cell_coords(nLocal, allCounts, displs, mpiComm, lon_global, lat_global, &
                            lonCell, latCell)

    ! ── 2. Gather dos campos ──────────────────────────────────────────────
    ! Valor usado quando o membro de atm_bnd nao esta alocado:
    ! - mascara: 1,0 (tudo oceano), que nao mascara nada;
    ! - correntes: 0,0, o oceano parado que o MPAS assume sem o MOM6;
    ! - albedo: 0,0, que NAO e' um valor fisico plausivel (oceano aberto
    !   fica em torno de 0,06): e' um marcador deliberado. Um mapa de
    !   Sf_albedo todo em zero indica que o campo nao chegou ao atm_bnd.
    call gather_boundary_member(atm_bnd%sst,          0.0_ESMF_KIND_R8, nLocal, &
                                allCounts, displs, mpiComm, recvBuf(:, IMP_SOT))
    call gather_boundary_member(atm_bnd%ice_fraction, 0.0_ESMF_KIND_R8, nLocal, &
                                allCounts, displs, mpiComm, recvBuf(:, IMP_IFRAC))
    call gather_boundary_member(atm_bnd%zorl,         0.0_ESMF_KIND_R8, nLocal, &
                                allCounts, displs, mpiComm, recvBuf(:, IMP_ZORL))
    call gather_boundary_member(atm_bnd%omask,        1.0_ESMF_KIND_R8, nLocal, &
                                allCounts, displs, mpiComm, recvBuf(:, IMP_OMASK))
    call gather_boundary_member(atm_bnd%uocn,         0.0_ESMF_KIND_R8, nLocal, &
                                allCounts, displs, mpiComm, recvBuf(:, IMP_UOCN))
    call gather_boundary_member(atm_bnd%vocn,         0.0_ESMF_KIND_R8, nLocal, &
                                allCounts, displs, mpiComm, recvBuf(:, IMP_VOCN))
    call gather_boundary_member(atm_bnd%alb,          0.0_ESMF_KIND_R8, nLocal, &
                                allCounts, displs, mpiComm, recvBuf(:, IMP_ALB))

    deallocate(allCounts, displs)

    ! ── 3. Escrita NetCDF (somente PET 0) ─────────────────────────────────
    if (localPet /= 0) then
      deallocate(lon_global, lat_global, recvBuf)
      return
    end if

    call write_import_diag_file(clk, recvBuf, lon_global, lat_global, nGlobal, outdir, subname)

    deallocate(lon_global, lat_global, recvBuf)

  end subroutine write_mpas_import_diag

  !> Reúne no PET 0 as coordenadas (em graus) das células MPAS de todos os
  !! PETs, na ordem de allCounts/displs. Sem lonCell e latCell, nada é
  !! reunido e lon_global/lat_global ficam como estão. Coletiva quando as
  !! coordenadas estão presentes: todos os PETs chamam.
  subroutine gather_cell_coords(nLocal, allCounts, displs, mpiComm, lon_global, lat_global, &
                                lonCell, latCell)
    integer,                    intent(in)    :: nLocal
    integer,                    intent(in)    :: allCounts(:), displs(:)
    integer,                    intent(in)    :: mpiComm
    real(ESMF_KIND_R8), contiguous, intent(inout) :: lon_global(:), lat_global(:)
    real(MPAS_RKIND), optional, intent(in)    :: lonCell(:)
    real(MPAS_RKIND), optional, intent(in)    :: latCell(:)
    real(ESMF_KIND_R8), allocatable :: sendBuf(:)
    integer :: mpi_ierr

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
  end subroutine gather_cell_coords

  !> Grava, no PET 0, o arquivo monan2_import_*.nc do passo: nome pela data
  !! do relógio do diagnóstico (ou pelo contador, sem relógio), eixos da
  !! grade lat/lon centrada em células e campos já reunidos em recvBuf.
  !! Incrementa o contador clk%step.
  !!
  !! @param[in] subname  prefixo das mensagens (o de write_mpas_import_diag)
  subroutine write_import_diag_file(clk, recvBuf, lon_global, lat_global, nGlobal, outdir, subname)
    type(mpas_import_diag_clock_t), intent(inout) :: clk
    real(ESMF_KIND_R8), intent(in) :: recvBuf(:,:)
    real(ESMF_KIND_R8), intent(in) :: lon_global(:), lat_global(:)
    integer,            intent(in) :: nGlobal
    character(len=*),   intent(in) :: outdir
    character(len=*),   intent(in) :: subname

    character(len=256) :: fname
    integer :: ncid, ios
    logical :: ok
    integer :: varid_lat, varid_lon
    integer :: varids(N_IMP_DIAG)
    integer :: nlat, nlon, i
    real(ESMF_KIND_R8), allocatable :: lat_axis(:), lon_axis(:)
    real(ESMF_KIND_R8) :: res_deg, dlon, dlat

    res_deg = real(cfg_grid_res_deg, ESMF_KIND_R8)
    dlon    = res_deg
    dlat    = res_deg
    nlon    = nint(360.0_ESMF_KIND_R8 / dlon)
    ! A grade e' CENTRADA em celulas: lat_axis(i) = -90 + (i-0.5)*dlat.
    ! Para dlat=1 isso da' 180 celulas cobrindo -89,5..+89,5, exatamente
    ! como o lado do MOM6. O ponto em lat=+90 e' levado ao bin 180 (89,5)
    ! pelo min(...,nlat) em voronoi_to_grid, e as duas grades de
    ! diagnostico (MED->MPAS e MED->OCN) coincidem.
    nlat    = nint(180.0_ESMF_KIND_R8 / dlat)

    clk%step = clk%step + 1

    ! Nome do arquivo: monan2_import_YYYYMMDD_HHMMSS.nc
    !   Fallback por contador quando clk%yr == 0 (clock não configurado).
    call execute_command_line('mkdir -p '//trim(outdir), wait=.true.)
    if (clk%yr == 0) then
      write(fname,'(A,"/monan2_import_",I4.4,".nc")') trim(outdir), clk%step
    else
      write(fname,'(A,"/monan2_import_",I4.4,2I2.2,"_",3I2.2,".nc")') &
        trim(outdir), clk%yr, clk%mo, clk%dy, &
                      clk%hr, clk%mn, clk%sc
    end if

    ! Eixos da grade lat/lon do binning
    allocate(lat_axis(nlat), lon_axis(nlon))
    do i = 1, nlat
      lat_axis(i) = -90.0_ESMF_KIND_R8 + (i - 0.5_ESMF_KIND_R8) * dlat
    end do
    do i = 1, nlon
      lon_axis(i) = (i - 0.5_ESMF_KIND_R8) * dlon - 180.0_ESMF_KIND_R8
    end do

    call define_import_diag_file(fname, nlon, nlat, clk%step, ncid, varid_lon, varid_lat, varids, ok)
    if (ok) then
      ios = nf90_put_var(ncid, varid_lat, lat_axis)
      ios = nf90_put_var(ncid, varid_lon, lon_axis)
      call write_import_diag_fields(ncid, varids, recvBuf, lon_global, lat_global, nGlobal, &
                                    nlon, nlat, dlon, dlat)
      ios = nf90_close(ncid)
      call ESMF_LogWrite(subname//': escrito '//trim(fname), ESMF_LOGMSG_INFO)
    end if

    deallocate(lat_axis, lon_axis)
  end subroutine write_import_diag_file

  !> @brief Reúne no PET 0 um membro de atm_ocean_boundary_type.
  !!
  !! Converte os valores locais para ESMF_KIND_R8 e os reúne por
  !! MPI_Gatherv na ordem dos PETs. Quando o membro não está alocado, o PET
  !! envia o valor de reserva em todas as células.
  !!
  !! @param[in]    member     membro de atm_bnd (nCells locais)
  !! @param[in]    fallback   valor usado quando o membro não está alocado
  !! @param[in]    nLocal     número de células locais
  !! @param[in]    allCounts  número de células de cada PET
  !! @param[in]    displs     deslocamento de cada PET no vetor global
  !! @param[in]    mpiComm    comunicador MPI do componente
  !! @param[inout] recvBuf    vetor global (só é preenchido no PET 0)
  subroutine gather_boundary_member(member, fallback, nLocal, allCounts, displs, mpiComm, recvBuf)
    real(MPAS_RKIND), allocatable, intent(in) :: member(:)
    real(ESMF_KIND_R8), intent(in)    :: fallback
    integer,            intent(in)    :: nLocal
    integer,            intent(in)    :: allCounts(:), displs(:)
    integer,            intent(in)    :: mpiComm
    real(ESMF_KIND_R8), contiguous, intent(inout) :: recvBuf(:)

    real(ESMF_KIND_R8), allocatable :: sendBuf(:)
    integer :: mpi_ierr

    allocate(sendBuf(nLocal))
    if (allocated(member)) then
      sendBuf(1:nLocal) = real(member(1:nLocal), ESMF_KIND_R8)
    else
      sendBuf = fallback
    end if
    call MPI_Gatherv(sendBuf, nLocal, MPI_DOUBLE_PRECISION, &
                     recvBuf, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)
    deallocate(sendBuf)
  end subroutine gather_boundary_member

  !> @brief Cria o arquivo monan2_import e define eixos, variáveis e atributos.
  !!
  !! Uma variável por membro de atm_ocean_boundary_type (índices IMP_*).
  !! Devolve o arquivo fora do modo de definição, pronto para a gravação.
  !!
  !! @param[in]  fname      caminho do arquivo
  !! @param[in]  nlon       número de longitudes
  !! @param[in]  nlat       número de latitudes
  !! @param[in]  step       número da chamada (atributo global 'step')
  !! @param[out] ncid       identificador do arquivo
  !! @param[out] varid_lon  variável do eixo de longitude
  !! @param[out] varid_lat  variável do eixo de latitude
  !! @param[out] varids     variáveis dos campos, na ordem dos índices IMP_*
  !! @param[out] ok         .false. se a criação do arquivo ou dos eixos falhou
  subroutine define_import_diag_file(fname, nlon, nlat, step, ncid, varid_lon, varid_lat, varids, ok)
    character(len=*), intent(in)  :: fname
    integer,          intent(in)  :: nlon, nlat
    integer,          intent(in)  :: step
    integer,          intent(out) :: ncid, varid_lon, varid_lat
    integer,          intent(out) :: varids(N_IMP_DIAG)
    logical,          intent(out) :: ok

    integer :: dimid_lat, dimid_lon, ios
    logical :: okf

    ok = .false.
    if (.not. nc_create(fname, ncid, 'write_mpas_import_diag')) return
    if (.not. nc_def_latlon(ncid, nlon, nlat, dimid_lon, dimid_lat, varid_lon, varid_lat, &
                            'write_mpas_import_diag')) return

    okf = nc_def_field2d(ncid, 'So_t', dimid_lon, dimid_lat, varids(IMP_SOT), 'write_mpas_import_diag', &
           long_name='SST dinamica MOM6 importada pelo MPAS', &
           units='K', standard_name='sea_surface_temperature', fill_r8=FILL_VALUE_R8)

    okf = nc_def_field2d(ncid, 'Si_ifrac', dimid_lon, dimid_lat, varids(IMP_IFRAC), 'write_mpas_import_diag', &
           long_name='Fracao de gelo marinho importada pelo MPAS', &
           units='1', standard_name='sea_ice_area_fraction', fill_r8=FILL_VALUE_R8)

    okf = nc_def_field2d(ncid, 'Sf_zorl', dimid_lon, dimid_lat, varids(IMP_ZORL), 'write_mpas_import_diag', &
           long_name='Rugosidade superficial Charnock+Smith importada pelo MPAS', &
           units='m', standard_name='surface_roughness_length', fill_r8=FILL_VALUE_R8)

    okf = nc_def_field2d(ncid, 'So_u', dimid_lon, dimid_lat, varids(IMP_UOCN), 'write_mpas_import_diag', &
           long_name='Corrente oceanica zonal importada pelo MPAS', &
           units='m s-1', standard_name='eastward_sea_water_velocity', fill_r8=FILL_VALUE_R8)

    okf = nc_def_field2d(ncid, 'So_v', dimid_lon, dimid_lat, varids(IMP_VOCN), 'write_mpas_import_diag', &
           long_name='Corrente oceanica meridional importada pelo MPAS', &
           units='m s-1', standard_name='northward_sea_water_velocity', fill_r8=FILL_VALUE_R8)

    okf = nc_def_field2d(ncid, 'Sf_albedo', dimid_lon, dimid_lat, varids(IMP_ALB), 'write_mpas_import_diag', &
           long_name='Albedo de superficie importado pelo MPAS', &
           units='1', standard_name='surface_albedo', fill_r8=FILL_VALUE_R8)

    ! a propria mascara vira variavel do arquivo, para que o
    ! pos-processamento nao precise readivinha-la a partir de _FillValue.
    okf = nc_def_field2d(ncid, 'Sx_omask', dimid_lon, dimid_lat, varids(IMP_OMASK), 'write_mpas_import_diag', &
           long_name='Mascara oceano/terra do MOM6 (1=oceano, 0=terra)', &
           units='1', standard_name='sea_binary_mask', fill_r8=FILL_VALUE_R8)

    call nc_global_header(ncid, &
      title='MONAN-A 2.0 importState (= MED exportState MED->MPAS) — Campos OCN->ATM', &
      institution='INPE/CGCT/DIMNT', &
      source='mpas_cap_netcdf.F90::write_mpas_import_diag (So_t + Si_ifrac + So_u + '// &
             'So_v + Sf_zorl + Sf_albedo + Sx_omask)')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'code_version', &
      'v3.1-2026-09 (B-DIAG-IMPORT-INCOMPLETO-01: 7 de 7 campos importados; '// &
      'antes 4 de 7 — So_u, So_v e Sf_albedo ficavam de fora em silencio)')
    ! Rotulo explicito da cobertura, para que uma comparacao de
    ! reprodutibilidade feita sobre estes arquivos possa verificar, no proprio
    ! arquivo, se ela cobre todos os campos que o MPAS importa.
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'import_fields_written', 7)
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'import_fields_total',  7)
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'land_mask_source', &
      'MOM6 ocean_grid%mask2dT (So_omask -> Sx_omask, regridada MED->MPAS); '// &
      'celulas de terra gravadas como _FillValue; mascara na variavel Sx_omask')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'step',         step)
    ios = nf90_enddef(ncid)
    ok = .true.
  end subroutine define_import_diag_file

  !> @brief Faz o binning dos campos reunidos e grava as variáveis do arquivo.
  !!
  !! A máscara é binada PRIMEIRO, pela mesma rotina dos campos, para viver
  !! exatamente na mesma grade. ocean_frac_min=0.0 nela de propósito: a
  !! máscara não deve ser pré-filtrada, precisa cobrir todo bin que tenha ao
  !! menos uma célula Voronoi. Bin sem nenhuma célula sai em FILL_DIAG e é
  !! capturado pela comparação com OMASK_MIN (negativa para FILL_DIAG), ou
  !! seja, tratado como terra: correto, porque ali não há dado de oceano.
  !!
  !! Os demais campos usam ocean_frac_min=0.5 (elimina artefatos costeiros)
  !! e a mesma máscara, para que as sete variáveis vivam na mesma grade e
  !! sejam comparáveis entre si e com o diagnóstico do MED.
  !!
  !! @param[in] ncid        arquivo fora do modo de definição
  !! @param[in] varids      variáveis dos campos (índices IMP_*)
  !! @param[in] recvBuf     valores reunidos, um campo por coluna
  !! @param[in] lon_global  longitude das células [graus]
  !! @param[in] lat_global  latitude das células [graus]
  !! @param[in] nGlobal     número de células
  !! @param[in] nlon, nlat  tamanho da grade de saída
  !! @param[in] dlon, dlat  passo da grade de saída [graus]
  subroutine write_import_diag_fields(ncid, varids, recvBuf, lon_global, lat_global, nGlobal, &
                                      nlon, nlat, dlon, dlat)
    integer,            intent(in) :: ncid
    integer,            intent(in) :: varids(N_IMP_DIAG)
    real(ESMF_KIND_R8), intent(in) :: recvBuf(:,:)
    real(ESMF_KIND_R8), intent(in) :: lon_global(:), lat_global(:)
    integer,            intent(in) :: nGlobal, nlon, nlat
    real(ESMF_KIND_R8), intent(in) :: dlon, dlat

    real(ESMF_KIND_R8), allocatable :: mask_2d(:,:)
    integer :: ios

    allocate(mask_2d(nlon, nlat))
    call voronoi_to_grid(recvBuf(:, IMP_OMASK), lon_global, lat_global, nGlobal, &
                         mask_2d, nlon, nlat, dlon, dlat, &
                         vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, &
                         ocean_frac_min=0.0_ESMF_KIND_R8)

    call bin_masked_field(ncid, varids(IMP_SOT), recvBuf(:, IMP_SOT), lon_global, lat_global, &
                          nGlobal, mask_2d, nlon, nlat, dlon, dlat, &
                          270.0_ESMF_KIND_R8, 310.0_ESMF_KIND_R8)
    call bin_masked_field(ncid, varids(IMP_IFRAC), recvBuf(:, IMP_IFRAC), lon_global, lat_global, &
                          nGlobal, mask_2d, nlon, nlat, dlon, dlat, &
                          0.0_ESMF_KIND_R8, 1.0_ESMF_KIND_R8)
    call bin_masked_field(ncid, varids(IMP_ZORL), recvBuf(:, IMP_ZORL), lon_global, lat_global, &
                          nGlobal, mask_2d, nlon, nlat, dlon, dlat, &
                          1.0e-5_ESMF_KIND_R8, 0.1_ESMF_KIND_R8)
    ! Os limites [-5, +5] m/s nas correntes sao os MESMOS do clamp fisico
    ! aplicado na importacao (mpas_cap_methods.F90: |u|>5 -> 0). Se os dois
    ! divergirem, o diagnostico passa a descartar valor que a fisica aceitou,
    ! ou a aceitar valor que a fisica zerou. Mantenha-os iguais.
    call bin_masked_field(ncid, varids(IMP_UOCN), recvBuf(:, IMP_UOCN), lon_global, lat_global, &
                          nGlobal, mask_2d, nlon, nlat, dlon, dlat, &
                          -5.0_ESMF_KIND_R8, 5.0_ESMF_KIND_R8)
    call bin_masked_field(ncid, varids(IMP_VOCN), recvBuf(:, IMP_VOCN), lon_global, lat_global, &
                          nGlobal, mask_2d, nlon, nlat, dlon, dlat, &
                          -5.0_ESMF_KIND_R8, 5.0_ESMF_KIND_R8)
    ! Albedo em [0, 1]: faixa de definicao da grandeza, nao faixa esperada.
    ! Oceano aberto fica por volta de 0,06 e gelo novo passa de 0,8; apertar
    ! o intervalo aqui descartaria o contraste agua/gelo, que e' exatamente
    ! o que se quer ver neste campo.
    call bin_masked_field(ncid, varids(IMP_ALB), recvBuf(:, IMP_ALB), lon_global, lat_global, &
                          nGlobal, mask_2d, nlon, nlat, dlon, dlat, &
                          0.0_ESMF_KIND_R8, 1.0_ESMF_KIND_R8)

    call binarize_ocean_mask(mask_2d)
    ios = nf90_put_var(ncid, varids(IMP_OMASK), mask_2d)
    call log_mask_coverage(mask_2d)
    deallocate(mask_2d)
  end subroutine write_import_diag_fields

  !> @brief Binning de um campo, máscara de continentes e gravação da variável.
  !!
  !! @param[in] ncid        arquivo fora do modo de definição
  !! @param[in] varid       variável do campo
  !! @param[in] data_v      valores nas células
  !! @param[in] lon_global  longitude das células [graus]
  !! @param[in] lat_global  latitude das células [graus]
  !! @param[in] nGlobal     número de células
  !! @param[in] mask_2d     máscara já binada (fração de oceano por bin)
  !! @param[in] nlon, nlat  tamanho da grade de saída
  !! @param[in] dlon, dlat  passo da grade de saída [graus]
  !! @param[in] vmin, vmax  faixa de valores aceitos no binning
  subroutine bin_masked_field(ncid, varid, data_v, lon_global, lat_global, nGlobal, &
                              mask_2d, nlon, nlat, dlon, dlat, vmin, vmax)
    integer,            intent(in) :: ncid, varid
    real(ESMF_KIND_R8), intent(in) :: data_v(:), lon_global(:), lat_global(:)
    integer,            intent(in) :: nGlobal, nlon, nlat
    real(ESMF_KIND_R8), intent(in) :: mask_2d(nlon, nlat)
    real(ESMF_KIND_R8), intent(in) :: dlon, dlat, vmin, vmax

    real(ESMF_KIND_R8), allocatable :: grid_2d(:,:)
    integer :: ios

    allocate(grid_2d(nlon, nlat))
    call voronoi_to_grid(data_v, lon_global, lat_global, nGlobal, &
                         grid_2d, nlon, nlat, dlon, dlat, &
                         vmin=vmin, vmax=vmax, &
                         ocean_frac_min=0.5_ESMF_KIND_R8)
    where (mask_2d < OMASK_MIN) grid_2d = FILL_VALUE_R8
    ios = nf90_put_var(ncid, varid, grid_2d)
    deallocate(grid_2d)
  end subroutine bin_masked_field

  !> @brief Torna binária a máscara binada (1=oceano, 0=terra).
  !!
  !! A máscara vai binária e sem mascarar a si mesma: é ela que diz onde a
  !! terra fica. Bin sem célula Voronoi permanece FILL_DIAG.
  !! Feito com máscaras lógicas explícitas (e não com ELSEWHERE encadeado)
  !! porque aqui o array de controle é o próprio array atribuído: a ordem
  !! de avaliação passaria a importar para quem for reler isto.
  !!
  !! @param[inout] mask_2d  máscara binada, alterada no lugar
  subroutine binarize_ocean_mask(mask_2d)
    real(ESMF_KIND_R8), intent(inout) :: mask_2d(:,:)

    logical, allocatable :: is_ocean(:,:), is_land(:,:)

    allocate(is_ocean(size(mask_2d,1), size(mask_2d,2)))
    allocate(is_land (size(mask_2d,1), size(mask_2d,2)))
    is_ocean = (mask_2d >= OMASK_MIN)
    is_land  = (.not. is_ocean) .and. (mask_2d > 0.5_ESMF_KIND_R8 * FILL_VALUE_R8)
    where (is_ocean) mask_2d = 1.0_ESMF_KIND_R8
    where (is_land)  mask_2d = 0.0_ESMF_KIND_R8
    deallocate(is_ocean, is_land)
  end subroutine binarize_ocean_mask

  !> @brief Registra no log a fração de bins de oceano da máscara binária.
  !!
  !! @param[in] mask_2d  máscara binária (1=oceano, 0=terra)
  subroutine log_mask_coverage(mask_2d)
    real(ESMF_KIND_R8), intent(in) :: mask_2d(:,:)

    character(len=200) :: logmsg_mask
    integer :: n_ocn_b, nbins

    nbins   = size(mask_2d)
    n_ocn_b = count(mask_2d >= OMASK_MIN)
    write(logmsg_mask,'(A,F5.1,A,I0,A,I0,A)') &
      'B-DIAGMASK-01: monan2_import mascarado — oceano ', &
      100.0*real(n_ocn_b)/real(nbins), '% (', n_ocn_b, ' de ', &
      nbins, ' bins)'
    call ESMF_LogWrite(trim(logmsg_mask), ESMF_LOGMSG_INFO)
  end subroutine log_mask_coverage

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
      ! floor é o inverso exato do eixo centrado em bins.
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

    grid_out = FILL_VALUE_R8
    where (cnt > 0) grid_out = acc / real(cnt, ESMF_KIND_R8)

    if (ofrac_min > 0.0_ESMF_KIND_R8) then
      where (cnt_all > 0 .and. &
             real(cnt, ESMF_KIND_R8) / real(cnt_all, ESMF_KIND_R8) < ofrac_min)
        grid_out = FILL_VALUE_R8
      end where
    end if

    deallocate(acc, cnt, cnt_all)

  end subroutine voronoi_to_grid

end module mpas_import_diag_mod
