!> @file mpas_cap_netcdf.F90
!! @brief Diagnóstico NetCDF do cap MPAS-A: forçante exportada pelo MONAN-A.
!!
!! Grava a forçante exportada pelo MONAN-A (monan_export_*.nc) numa grade
!! regular lat/lon. O diagnóstico dos campos importados do mediador
!! (monan2_import_*.nc) fica em mpas_import_diag.F90. Os campos já chegam
!! de mpas_atm_model.F90 em unidades instantâneas (médias do intervalo de
!! acoplamento para os acumulados).
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
!!   Coordenadas: MPI_Allgather + MPI_Gatherv, uma vez (netcdf_init_coords).
!!   Campos: cada PET acumula suas células Voronoi na grade lat/lon
!!           (voronoi_accum_local) → MPI_Allreduce(SUM) de somas e contagens
!!   PET0  → média por ponto e nf90_put_var.

module mpas_cap_netcdf_mod

  use ESMF
  use coupler_constants_mod, only : FILL_VALUE_R8, PI
  use mpi
  ! Wrappers tipadas em módulo separado (mpi_allreduce_wrappers.F90):
  ! O ftn/gfortran cruza tipos de MPI_Allreduce entre chamadas no mesmo módulo
  ! (análise de fluxo sobre interface implícita 'use mpi'). Isolar em módulo
  ! próprio elimina o cruzamento de escopo sem alterar a semântica MPI.
  use mpi_allreduce_wrappers_mod, only : allreduce_r8, allreduce_i4
  use netcdf
  use coupler_utils_mod,  only : ChkErr, int_to_str
  use coupler_log_mod,    only : COMP_ATM, log_error, log_warning, log_info
  use nc_writer_mod,      only : nc_create, nc_global_header, nc_def_latlon, nc_def_field2d
  use cpl_grids_mod,      only : index_round, lon_m180to180_loop
  use cpl_fields_mod,     only : cpl_field_attributes

  implicit none
  private

  ! Interface pública
  public :: netcdf_init_coords      ! coleta coordenadas locais de todos os PETs
  public :: export_write_netcdf     ! interpola e escreve NetCDF com grade lat/lon
  public :: netcdf_config_set       ! configura grade e diretório a partir do namelist
  public :: netcdf_push_raw_field

  ! Grade de saída, coordenadas e campos guardados do gravador
  integer, parameter :: MAX_RAW = 15   !< máximo de campos MPAS guardados

  !> Estado do gravador monan_export_*.nc. O cap cria um objeto deste tipo,
  !! configura a grade (netcdf_config_set), reúne as coordenadas uma vez
  !! (netcdf_init_coords) e o passa a netcdf_push_raw_field e a
  !! export_write_netcdf a cada passo.
  type, public :: mpas_diag_export_t
    ! Grade regular de saída. Padrão 1°×1° (namelist &nuopc_netcdf);
    ! atualizada por netcdf_config_set.
    integer            :: nlon     = 360   !< -180° a +179°
    integer            :: nlat     = 181   !<  -90° a  +90°
    real               :: grid_res = 1.0   !< resolução [°]
    real(ESMF_KIND_R8) :: dlon = 1.0_ESMF_KIND_R8   !< passo em lon
    real(ESMF_KIND_R8) :: dlat = 1.0_ESMF_KIND_R8   !< passo em lat
    character(len=256) :: output_dir = 'diag_export'
    ! Coordenadas globais, reunidas no PET 0 por netcdf_init_coords
    real(ESMF_KIND_R8), allocatable :: lon_global(:)   !< (nglobal) graus
    real(ESMF_KIND_R8), allocatable :: lat_global(:)   !< (nglobal) graus
    logical :: coords_ready = .false.
    ! Decomposição MPI de netcdf_init_coords, reusada em export_write_netcdf
    ! para que allCounts/displs sejam os mesmos e o mapeamento geográfico
    ! não saia errado.
    integer :: nlocal  = 0
    integer :: nglobal = 0
    integer, allocatable :: all_counts(:)
    integer, allocatable :: displs(:)
    real(ESMF_KIND_R8), allocatable :: lon_local(:)   !< coordenadas locais [°]
    real(ESMF_KIND_R8), allocatable :: lat_local(:)
    ! Campos MPAS locais guardados por netcdf_push_raw_field
    integer            :: n_raw = 0
    character(len=64)  :: raw_names(MAX_RAW)
    real(ESMF_KIND_R8), allocatable :: raw_local(:,:)   !< (nlocal, MAX_RAW)
  end type mpas_diag_export_t

  character(len=*), parameter :: u_FILE_u   = __FILE__

contains

  !> @brief Configura os parâmetros de grade e diretório de saída a partir do namelist.
  !!
  !! Deve ser chamada em InitializeRealize antes de netcdf_init_coords.
  !! @param[in] res_deg   Resolução da grade em graus (ex: 1.0, 0.5, 0.25)
  !! @param[in] out_dir   Diretório de saída para os arquivos NetCDF
  !! @param[in] localPet PET local do ESMF; suprime impressão em PETs > 0
  subroutine netcdf_config_set(diag, res_deg, out_dir, localPet)
    type(mpas_diag_export_t), intent(inout) :: diag
    real,             intent(in) :: res_deg
    character(len=*), intent(in) :: out_dir
    integer,          intent(in) :: localPet  ! guarda de rank
    character(len=200) :: msg

    diag%grid_res   = res_deg
    diag%dlon       = real(res_deg, ESMF_KIND_R8)
    diag%dlat       = real(res_deg, ESMF_KIND_R8)
    diag%nlon       = nint(360.0 / res_deg)
    diag%nlat       = nint(180.0 / res_deg) + 1
    diag%output_dir = trim(out_dir)

    ! Só o PET 0 registra a configuração, que é a mesma em todos.
    if (localPet == 0) then
      write(msg,'(A,F5.2,A,I0,A,I0,A,A)') &
        'netcdf_config_set: grade ', res_deg, ' graus, NLON=', diag%nlon, &
        ' NLAT=', diag%nlat, ' output_dir=', trim(diag%output_dir)
      call log_info(COMP_ATM, trim(msg))
    end if
  end subroutine netcdf_config_set

  !> @brief Coleta coordenadas locais de todos os PETs via MPI_Gatherv e armazena no PET0.
  !!
  !! Deve ser chamada UMA VEZ em InitializeRealize do cap, após a malha ESMF
  !! estar disponível e ANTES da primeira chamada a export_write_netcdf.
  !!
  !! A decomposição MPI_Gatherv usada aqui é idêntica à de export_write_netcdf
  !! para os campos, garantindo que lon_global(i)/lat_global(i) corresponde
  !! exatamente ao dado(i) em recvBuf (sem isso, o mapa sairia em xadrez).
  !!
  !! Chamada idempotente (retorna imediatamente se já executada).
  !!
  !! Uso em mpas_cap_MONAN.F90 (InitializeRealize):
  !!   call netcdf_init_coords(lon_local, lat_local, nLocalElem, vm, rc)
  subroutine netcdf_init_coords(diag, lon_local, lat_local, nLocal, vm, rc)
    type(mpas_diag_export_t), intent(inout) :: diag
    real(ESMF_KIND_R8), intent(in)    :: lon_local(:)   ! longitudes do PET (graus)
    real(ESMF_KIND_R8), intent(in)    :: lat_local(:)   ! latitudes  do PET (graus)
    integer,            intent(in)    :: nLocal          ! número de células locais
    type(ESMF_VM),      intent(in)    :: vm
    integer,            intent(inout) :: rc

    integer :: localPet, petCount, mpiComm, mpi_ierr, i, nGlobal
    integer, allocatable :: allCounts(:), displs(:)
    character(len=*), parameter :: subname = 'netcdf_init_coords'

    rc = ESMF_SUCCESS
    if (diag%coords_ready) return   ! idempotente

    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, &
                    mpiCommunicator=mpiComm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! Reunir tamanhos locais de cada PET
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

    ! Alocar buffers (PETs >0 recebem array mínimo; argumento inativo)
    if (localPet == 0) then
      allocate(diag%lon_global(nGlobal))
      allocate(diag%lat_global(nGlobal))
    else
      allocate(diag%lon_global(1))
      allocate(diag%lat_global(1))
    end if

    ! Gather de lon e lat
    call MPI_Gatherv(lon_local, nLocal, MPI_DOUBLE_PRECISION, &
                     diag%lon_global, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)
    if (mpi_ierr /= MPI_SUCCESS .and. localPet == 0) &
      call log_warning(COMP_ATM, subname//': MPI_Gatherv de lon_local falhou')

    call MPI_Gatherv(lat_local, nLocal, MPI_DOUBLE_PRECISION, &
                     diag%lat_global, allCounts, displs, MPI_DOUBLE_PRECISION, &
                     0, mpiComm, mpi_ierr)
    if (mpi_ierr /= MPI_SUCCESS .and. localPet == 0) &
      call log_warning(COMP_ATM, subname//': MPI_Gatherv de lat_local falhou')

    ! Salvar a decomposição MPI para reuso em export_write_netcdf.
    ! Garante que recvBuf(i) corresponde a lon_global/lat_global(i).
    diag%nlocal  = nLocal
    diag%nglobal = nGlobal
    allocate(diag%all_counts(petCount))
    allocate(diag%displs(petCount))
    diag%all_counts = allCounts
    diag%displs    = displs
    if (allocated(diag%lon_local)) deallocate(diag%lon_local)
    if (allocated(diag%lat_local)) deallocate(diag%lat_local)
    allocate(diag%lon_local(nLocal))
    allocate(diag%lat_local(nLocal))
    diag%lon_local = lon_local(1:nLocal)
    diag%lat_local = lat_local(1:nLocal)

    ! diag%raw_local é alocado aqui, onde diag%nlocal já é conhecido; em
    ! netcdf_push_raw_field, diag%nlocal ainda poderia ser 0.
    if (allocated(diag%raw_local)) deallocate(diag%raw_local)
    allocate(diag%raw_local(nLocal, MAX_RAW))
    diag%raw_local = 0.0_ESMF_KIND_R8
    diag%n_raw = 0  ! resetar contagem de campos (nova execução)

    deallocate(allCounts, displs)
    diag%coords_ready = .true.

    if (localPet == 0) &
      call log_info(COMP_ATM, subname//': '//int_to_str(nGlobal)// &
                    ' celulas; interpolacao lat/lon ativa')

  end subroutine netcdf_init_coords

  !> @brief Guarda o dado MPAS LOCAL deste PET, sem MPI.
  !! Todos os PETs têm diag%raw_local(nLocal, MAX_RAW) com seus próprios dados.
  subroutine netcdf_push_raw_field(diag, fname, data1d, nLocal, vm, rc)
    type(mpas_diag_export_t), intent(inout) :: diag
    character(len=*),   intent(in)    :: fname
    real(ESMF_KIND_R8), intent(in)    :: data1d(:)
    integer,            intent(in)    :: nLocal
    type(ESMF_VM),      intent(in)    :: vm
    integer,            intent(inout) :: rc
    integer :: idx, localPet, petCount
    rc = ESMF_SUCCESS
    if (.not. diag%coords_ready .or. nLocal <= 0) return
    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
    if (rc /= ESMF_SUCCESS) then; rc = ESMF_SUCCESS; return; end if
    do idx = 1, diag%n_raw
      if (trim(diag%raw_names(idx)) == trim(fname)) then
        if (allocated(diag%raw_local)) then
          if (size(diag%raw_local,1) >= nLocal) diag%raw_local(1:nLocal, idx) = data1d(1:nLocal)
        end if
        return
      end if
    end do
    if (diag%n_raw >= MAX_RAW) return
    diag%n_raw = diag%n_raw + 1
    diag%raw_names(diag%n_raw) = trim(fname)
    ! diag%raw_local já alocado em netcdf_init_coords com tamanho nLocal correto
    if (allocated(diag%raw_local)) then
      if (size(diag%raw_local,1) >= nLocal) diag%raw_local(1:nLocal, diag%n_raw) = data1d(1:nLocal)
    end if
  end subroutine netcdf_push_raw_field

  !> @brief Escreve no NetCDF os campos do exportState na grade lat/lon.
  !!
  !! Todos os PETs participam das chamadas MPI coletivas; os campos chegam
  !! em unidades instantâneas de mpas_atm_model.F90 (sem conversão aqui).
  !!
  !! Etapas: inventário do exportState; no PET 0, criação e definição do
  !! arquivo (define_export_file); interpolação e escrita de cada campo, com
  !! todos os PETs (write_export_fields); no PET 0, fechamento do arquivo.
  subroutine export_write_netcdf(diag, exportState,         &
                                  elapsed_s,                &
                                  s_yr, s_mo, s_dy,         &
                                  s_hr, s_mn, s_sc,         &
                                  vm, rc)
    type(mpas_diag_export_t), intent(in) :: diag
    type(ESMF_State), intent(in)    :: exportState
    integer,          intent(in)    :: elapsed_s
    integer,          intent(in)    :: s_yr, s_mo, s_dy, s_hr, s_mn, s_sc
    type(ESMF_VM),    intent(in)    :: vm
    integer,          intent(inout) :: rc

    ! Locais
    integer :: localPet, petCount, mpiComm
    integer :: itemCount, nLocal, nGlobal
    integer :: ncid, ncstat
    integer :: c_yr, c_mo, c_dy, c_hr, c_mn, c_sc

    character(len=64),  allocatable :: fldnames(:)

    character(len=64) :: fname
    character(len=19) :: valid_time_iso
    character(len=*), parameter :: subname = 'export_write_netcdf'

    rc = ESMF_SUCCESS

    call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, &
                    mpiCommunicator=mpiComm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! Coordenadas requeridas: preenchidas por netcdf_init_coords em InitializeRealize
    if (.not. diag%coords_ready) then
      if (localPet == 0) call log_error(COMP_ATM, subname// &
        ': netcdf_init_coords nao foi chamado em InitializeRealize')
      rc = ESMF_FAILURE
      return
    end if

    ! 0. Data/hora do passo
    ! s_yr..s_sc = currTime (ESMF_ClockGet em ModelRun) → nome do arquivo.
    ! elapsed_s  = step_count * dt_coupling_s (calculado pelo chamador)
    !            → variável CF time: "elapsed_s seconds since startTime".
    c_yr = s_yr; c_mo = s_mo; c_dy = s_dy
    c_hr = s_hr; c_mn = s_mn; c_sc = s_sc

    ! 1. Inventário do exportState
    call ESMF_StateGet(exportState, itemCount=itemCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    if (itemCount == 0) return

    allocate(fldnames(itemCount))
    call ESMF_StateGet(exportState, itemNameList=fldnames, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! 2. Decomposição MPI reutilizada de netcdf_init_coords
    ! nLocal = size(fptr) [localCells_ESMF] pode diferir do nLocal usado em
    ! netcdf_init_coords [min(localCells_ESMF, nCells_MPAS)]; com contagens
    ! distintas, o mapeamento geográfico no NetCDF sairia errado. Usar o
    ! nLocal guardado por netcdf_init_coords garante que cada valor local
    ! corresponde às coordenadas diag%lon_local/diag%lat_local.
    nLocal  = diag%nlocal
    nGlobal = diag%nglobal

    ! 3. PET0: criar e definir estrutura do arquivo NetCDF
    if (localPet == 0) then
      call define_export_file(diag, itemCount, fldnames, elapsed_s,      &
                              s_yr, s_mo, s_dy, s_hr, s_mn, s_sc,        &
                              c_yr, c_mo, c_dy, c_hr, c_mn, c_sc,        &
                              nGlobal, petCount, subname,                &
                              fname, valid_time_iso, ncid, rc)
      if (rc /= ESMF_SUCCESS) return
    end if   ! localPet == 0

    ! 4. Loop por campo: per-PET voronoi + MPI_Allreduce
    call write_export_fields(diag, exportState, itemCount, fldnames, nLocal, mpiComm, localPet, &
        ncid, rc)

    ! 5. PET0: fechar arquivo
    if (localPet == 0) then
      ncstat = nf90_close(ncid)
      if (ncstat == NF90_NOERR) then
        call log_info(COMP_ATM, subname//': '//trim(fname)//' escrito')
      else
        call log_warning(COMP_ATM, subname//': nf90_close: '//trim(nf90_strerror(ncstat)))
      end if
    end if

    deallocate(fldnames)
  end subroutine export_write_netcdf

  !> @brief Cria o arquivo monan_export_*.nc do passo e define a sua estrutura
  !! (atributos globais CF-1.8, lat, lon, time e uma variável por campo do
  !! exportState), escrevendo os eixos e o tempo. Só o PET 0 chama.
  !!
  !! @param[in]  s_yr..s_sc  instante corrente (atributo start_time e base do
  !!                         tempo CF, junto com elapsed_s)
  !! @param[in]  c_yr..c_sc  instante do nome do arquivo e de valid_time
  !! @param[in]  subname     prefixo das mensagens (o de export_write_netcdf)
  !! @param[out] fname, valid_time_iso  nome do arquivo e instante, para o log
  !! @param[out] ncid        arquivo aberto, fora do modo de definição
  !! @param[inout] rc        ESMF_SUCCESS, ou falha já registrada no log
  subroutine define_export_file(diag, itemCount, fldnames, elapsed_s,      &
                                s_yr, s_mo, s_dy, s_hr, s_mn, s_sc,        &
                                c_yr, c_mo, c_dy, c_hr, c_mn, c_sc,        &
                                nGlobal, petCount, subname,                &
                                fname, valid_time_iso, ncid, rc)
    type(mpas_diag_export_t), intent(in) :: diag
    integer,           intent(in)    :: itemCount
    character(len=64), intent(in)    :: fldnames(:)
    integer,           intent(in)    :: elapsed_s
    integer,           intent(in)    :: s_yr, s_mo, s_dy, s_hr, s_mn, s_sc
    integer,           intent(in)    :: c_yr, c_mo, c_dy, c_hr, c_mn, c_sc
    integer,           intent(in)    :: nGlobal, petCount
    character(len=*),  intent(in)    :: subname
    character(len=64), intent(out)   :: fname
    character(len=19), intent(out)   :: valid_time_iso
    integer,           intent(out)   :: ncid
    integer,           intent(inout) :: rc

    integer :: i, varid, ncstat
    integer :: dimid_lat, dimid_lon, dimid_t
    integer :: varid_lat, varid_lon, varid_t
    integer :: st_yr, st_mo, st_dy, st_hr, st_mn, st_sc
    integer :: cmd_stat
    real(ESMF_KIND_R8) :: lat_axis(diag%nlat), lon_axis(diag%nlon)
    real(ESMF_KIND_R8) :: time_val
    character(len=36) :: fname_base
    character(len=19) :: time_units_str
    ! Atributos de cada campo, gravados com o comprimento destas variáveis
    ! (brancos à direita incluídos), como sempre foram.
    character(len=32) :: f_units
    character(len=96) :: f_long
    character(len=80) :: f_std

      fname_base     = datetime_to_fname(c_yr,c_mo,c_dy,c_hr,c_mn,c_sc)
      fname          = trim(diag%output_dir)//'/'//trim(fname_base)
      valid_time_iso = datetime_to_iso(c_yr,c_mo,c_dy,c_hr,c_mn,c_sc)
      ! startTime = currTime - elapsed_s (para CF time_units "seconds since startTime")
      call start_time_from_elapsed(s_yr,s_mo,s_dy,s_hr,s_mn,s_sc, elapsed_s, &
                                   st_yr,st_mo,st_dy,st_hr,st_mn,st_sc, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      time_units_str = datetime_to_cf_base(st_yr,st_mo,st_dy,st_hr,st_mn,st_sc)
      time_val       = real(elapsed_s, ESMF_KIND_R8)

      call execute_command_line('mkdir -p '//trim(diag%output_dir), exitstat=cmd_stat)

      ! Atributos globais CF-1.8
      if (.not. nc_create(fname, ncid, subname)) then
        call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': nf90_create falhou', &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc)
        return
      end if

      call nc_global_header(ncid, &
        title='MPAS-A exportState — grade regular 1° lat/lon — NUOPC/CMEPS', &
        institution='INPE / CGCT / DIMNT', &
        source='NUOPC-MPAS-Integrado v5.2 (mpas_cap_netcdf_mod v2.7)')
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

      ! Dimensões
      ! lat e lon: sem dimensão time (1 arquivo por passo)
      ! Variáveis de coordenada
      if (.not. nc_def_latlon(ncid, diag%nlon, diag%nlat, dimid_lon, dimid_lat, &
                              varid_lon, varid_lat, subname)) then
        ncstat = nf90_close(ncid)
        call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': definicao de lat/lon falhou', &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc); return
      end if

      ncstat = nf90_def_dim(ncid, 'time', NF90_UNLIMITED, dimid_t)
      ncstat = nf90_def_var(ncid, 'time', NF90_DOUBLE, [dimid_t], varid_t)
      ncstat = nf90_put_att(ncid, varid_t, 'long_name', &
               'tempo da simulacao ao final do passo de acoplamento')
      ncstat = nf90_put_att(ncid, varid_t, 'units',     &
               'seconds since '//trim(time_units_str))
      ncstat = nf90_put_att(ncid, varid_t, 'calendar',  'gregorian')
      ncstat = nf90_put_att(ncid, varid_t, 'valid_time',trim(valid_time_iso))

      ! Variáveis dos campos (lon, lat) em Fortran column-major
      ! Python: nc['campo'][:] → shape (diag%nlat, diag%nlon) = (181, 360)  ✓
      do i = 1, itemCount
        call cpl_field_attributes(fldnames(i), f_units, f_long, f_std)
        if (.not. nc_def_field2d(ncid, fldnames(i), dimid_lon, dimid_lat, varid, subname, &
                                 long_name=f_long, units=f_units, standard_name=f_std, &
                                 fill_r8=FILL_VALUE_R8, missing=.true.)) cycle
        ncstat = nf90_put_att(ncid, varid, 'CMEPS_name', trim(fldnames(i)))
      end do

      ncstat = nf90_enddef(ncid)
      if (ncstat /= NF90_NOERR) then
        call log_error(COMP_ATM, subname//': nf90_enddef: '//trim(nf90_strerror(ncstat)))
        call ESMF_LogSetError(ESMF_FAILURE, msg=subname//': nf90_enddef falhou', &
             line=__LINE__, file=u_FILE_u, rcToReturn=rc)
        ncstat = nf90_close(ncid); return
      end if

      ! Escrever eixos e time
      do i = 1, diag%nlat
        lat_axis(i) = -90.0_ESMF_KIND_R8 + real(i-1, ESMF_KIND_R8) * diag%dlat
      end do
      do i = 1, diag%nlon
        lon_axis(i) = -180.0_ESMF_KIND_R8 + real(i-1, ESMF_KIND_R8) * diag%dlon
      end do
      ncstat = nf90_put_var(ncid, varid_lat, lat_axis)
      ncstat = nf90_put_var(ncid, varid_lon, lon_axis)
      ncstat = nf90_put_var(ncid, varid_t,   time_val)

  end subroutine define_export_file

  !> @brief Interpola cada campo do exportState para a grade lat/lon e, no PET 0,
  !! grava-o no arquivo aberto por define_export_file. Todos os PETs chamam
  !! (duas reduções MPI por campo).
  !!
  !! A fonte de cada campo é o dado MPAS guardado por netcdf_push_raw_field,
  !! quando existe; senão, o próprio campo do exportState
  !! (read_export_field_local), com cobertura parcial.
  subroutine write_export_fields(diag, exportState, itemCount, fldnames, nLocal, mpiComm, &
      localPet, ncid, rc)
    type(mpas_diag_export_t), intent(in) :: diag
    type(ESMF_State), intent(in) :: exportState
    integer, intent(in) :: itemCount
    character(len=64), intent(in) :: fldnames(:)
    integer, intent(in) :: nLocal
    integer, intent(in) :: mpiComm
    integer, intent(in) :: localPet
    integer, intent(in) :: ncid
    integer, intent(inout) :: rc
    integer :: i
    integer :: mpi_ierr
    integer :: ncstat, varid
    real(ESMF_KIND_R8) :: othr
    real(ESMF_KIND_R8) :: acc_local(diag%nlon,diag%nlat), acc_global(diag%nlon,diag%nlat)
    integer            :: cnt_local(diag%nlon,diag%nlat), cnt_global(diag%nlon,diag%nlat)
    integer :: raw_idx, jr
    real(ESMF_KIND_R8), allocatable :: sendBuf(:)
    real(ESMF_KIND_R8), allocatable :: grid_2d(:,:)

    allocate(sendBuf(max(nLocal, 1)))
    if (localPet == 0) allocate(grid_2d(diag%nlon, diag%nlat))

    do i = 1, itemCount
      raw_idx = 0
      do jr = 1, diag%n_raw
        if (trim(diag%raw_names(jr)) == trim(fldnames(i))) then; raw_idx = jr; exit; end if
      end do

      othr = field_outlier_threshold(fldnames(i))
      acc_local = 0.0_ESMF_KIND_R8; cnt_local = 0

      if (raw_idx > 0 .and. allocated(diag%raw_local) .and. diag%nlocal > 0 .and. &
          allocated(diag%lon_local)) then
        ! diag%raw_local(1:nLocal, idx): dados LOCAIS deste PET, na ordem do
        ! MPAS, como diag%lon_local, sem acesso fora dos limites.
        call voronoi_accum_local(diag, &
          diag%raw_local(1:diag%nlocal, raw_idx), &
          diag%lon_local(1:diag%nlocal),    &
          diag%lat_local(1:diag%nlocal),    &
          diag%nlocal, acc_local, cnt_local, othr)
      else
        ! Fallback ESMF field: cobertura parcial
        call read_export_field_local(exportState, fldnames(i), nLocal, sendBuf, rc)
        if (allocated(diag%lon_local) .and. nLocal>0) &
          call voronoi_accum_local(diag, sendBuf(1:nLocal), diag%lon_local(1:nLocal), &
            diag%lat_local(1:nLocal), nLocal, acc_local, cnt_local, othr)
      end if

      ! Wrappers isoladas em módulo separado (mpi_allreduce_wrappers_mod).
      call allreduce_r8(acc_local, acc_global, diag%nlon*diag%nlat, mpiComm, mpi_ierr)
      call allreduce_i4(cnt_local, cnt_global, diag%nlon*diag%nlat, mpiComm, mpi_ierr)

      if (localPet == 0) then
        grid_2d = FILL_VALUE_R8
        where (cnt_global > 0) grid_2d = acc_global / real(cnt_global, ESMF_KIND_R8)
        ncstat = nf90_inq_varid(ncid, trim(fldnames(i)), varid)
        if (ncstat == NF90_NOERR) then
          ncstat = nf90_put_var(ncid, varid, grid_2d)
          if (ncstat /= NF90_NOERR) &
            call log_warning(COMP_ATM, 'write_export_fields: nf90_put_var '// &
              trim(fldnames(i))//': '//trim(nf90_strerror(ncstat)))
        end if
      end if
    end do ! campos
    deallocate(sendBuf)
  end subroutine write_export_fields

  !> @brief Copia para sendBuf(1:nLocal) os valores locais de um campo do
  !! exportState (de posto 1 ou 2, este lido em ordem de coluna); sem campo,
  !! ou com menos de nLocal valores, sendBuf fica com zeros. Falhas de
  !! leitura não interrompem a escrita: rc volta sempre com ESMF_SUCCESS.
  subroutine read_export_field_local(exportState, fldname, nLocal, sendBuf, rc)
    type(ESMF_State),   intent(in)    :: exportState
    character(len=*),   intent(in)    :: fldname
    integer,            intent(in)    :: nLocal
    real(ESMF_KIND_R8), intent(inout) :: sendBuf(:)
    integer,            intent(inout) :: rc
    type(ESMF_Field) :: field
    real(ESMF_KIND_R8), pointer :: fp1(:)
    real(ESMF_KIND_R8), pointer :: fp2(:,:); integer :: rk
    real(ESMF_KIND_R8), allocatable :: flat(:)

        sendBuf(1:max(nLocal,1)) = 0.0_ESMF_KIND_R8
        call ESMF_StateGet(exportState, itemName=trim(fldname), field=field, rc=rc)
        if (rc == ESMF_SUCCESS) then
            nullify(fp1,fp2)
            call ESMF_FieldGet(field, dimCount=rk, rc=rc)
            if (rc==ESMF_SUCCESS) then
              if (rk==1) then
                call ESMF_FieldGet(field, farrayPtr=fp1, rc=rc)
                if (rc==ESMF_SUCCESS .and. associated(fp1)) then
                  if (size(fp1)>=nLocal) sendBuf(1:nLocal)=fp1(1:nLocal)
                end if
                if (associated(fp1)) nullify(fp1)
              else
                call ESMF_FieldGet(field, farrayPtr=fp2, rc=rc)
                if (rc==ESMF_SUCCESS .and. associated(fp2)) then
                  flat=pack(fp2,.true.)
                  if (size(flat)>=nLocal) sendBuf(1:nLocal)=flat(1:nLocal)
                end if
                if (associated(fp2)) nullify(fp2)
              end if
            end if
        end if
        rc = ESMF_SUCCESS
  end subroutine read_export_field_local

  !> @brief Acumulação per-PET, por vizinho mais próximo, das células Voronoi na
  !! grade regular diag%nlon×diag%nlat. Não normaliza: usar com MPI_Allreduce(SUM) e
  !! dividir a soma pela contagem.
  !!
  !! Para cada célula k: descarta |data_in(k)| > outlier_thr (fill value ou
  !! lixo de memória), normaliza a longitude para [-180, 180), acha o ponto
  !! de grade mais próximo e acumula soma e contagem, com espalhamento
  !! adaptativo em longitude (ver comentários no código).
  subroutine voronoi_accum_local(diag, data_in, lon_v, lat_v, n, acc, cnt, outlier_thr)
    type(mpas_diag_export_t), intent(in) :: diag
    real(ESMF_KIND_R8), intent(in)    :: data_in(n), lon_v(n), lat_v(n)
    integer,            intent(in)    :: n
    real(ESMF_KIND_R8), intent(inout) :: acc(diag%nlon, diag%nlat)
    integer,            intent(inout) :: cnt(diag%nlon, diag%nlat)
    real(ESMF_KIND_R8), intent(in)    :: outlier_thr
    integer,   parameter :: NSPAN_LAT = 1
    real(ESMF_KIND_R8), parameter :: CELL_HALF = 0.60_ESMF_KIND_R8
    real(ESMF_KIND_R8) :: val, lon_n, cos_lat
    integer :: k, ic, jc, i2, j2, di, dj, ns
    do k = 1, n
      val = data_in(k)
      if (abs(val) > outlier_thr .or. val /= val) cycle
      lon_n = lon_m180to180_loop(lon_v(k))
      ic = index_round(lon_n + 180.0_ESMF_KIND_R8, diag%dlon, diag%nlon)
      jc = index_round(lat_v(k) + 90.0_ESMF_KIND_R8, diag%dlat, diag%nlat)
      cos_lat = max(cos(lat_v(k)*PI/180.0_ESMF_KIND_R8), 0.009_ESMF_KIND_R8)
      ns = min(max(int(CELL_HALF/(cos_lat*diag%dlon))+1, NSPAN_LAT), diag%nlon/4)
      do dj = -NSPAN_LAT, NSPAN_LAT
        j2 = min(max(jc+dj,1),diag%nlat)
        do di = -ns, ns
          i2 = ic+di
          if (i2 < 1)    i2 = i2 + diag%nlon
          if (i2 > diag%nlon) i2 = i2 - diag%nlon
          acc(i2,j2) = acc(i2,j2) + val
          cnt(i2,j2) = cnt(i2,j2) + 1
        end do
      end do
    end do
  end subroutine voronoi_accum_local

  ! Limiar de outlier de cada campo (os atributos vêm de cpl_field_attributes)

  !> @brief Limiar de outlier por campo (filtra lixo de memória e fill values).
  !!
  !! Faxa_taux/tauy: stress superficial máximo físico ≈ 3 a 5 N/m² (furacão Cat.5);
  !!   limiar = 10 N/m² com margem de segurança.
  !!
  !! Sa_u10m_mpas / Sa_v10m_mpas: vento 10 m. Valores > 10 m/s são NORMAIS
  !!   (jatos de baixos níveis, alísios fortes, ciclones extratropicais), e um
  !!   limiar de 10 m/s cortaria 2.6% das caixas, justamente as de vento
  !!   forte, reduzindo o desvio-padrão do campo em 7%. O limiar é 150 m/s
  !!   (fisicamente impossível; só filtra lixo).
  !!
  !! Demais campos: ver os limiares abaixo; o padrão (1e20) só filtra fill
  !! values (-9.99e20/e33).
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
        ! Limiar = 0.1 kg/m²/s para incluir extremos; acima = erro em rainnc/dt
        field_outlier_threshold = 0.1_ESMF_KIND_R8
      case ('Faxa_snow_mpas', 'Faxa_snow')
        ! Precipitação sólida: máx físico ~0.01 kg/m²/s; limiar = 0.05
        field_outlier_threshold = 0.05_ESMF_KIND_R8
      case default
        ! Filtra apenas fill value (-9.99e20/e33) e lixo de memória óbvio
        field_outlier_threshold = 1.0e20_ESMF_KIND_R8
    end select
  end function field_outlier_threshold

  !> @brief Instante inicial = instante atual menos 'elapsed' segundos, pelo
  !! calendário gregoriano do ESMF, que trata o recuo para o mês anterior
  !! quando o intervalo cruza o início do mês.
  subroutine start_time_from_elapsed(yr, mo, dy, hr, mn, sc, elapsed, &
                                     yr_o, mo_o, dy_o, hr_o, mn_o, sc_o, rc)
    integer, intent(in)  :: yr, mo, dy, hr, mn, sc, elapsed
    integer, intent(out) :: yr_o, mo_o, dy_o, hr_o, mn_o, sc_o
    integer, intent(out) :: rc
    type(ESMF_Time)         :: t_now, t_start
    type(ESMF_TimeInterval) :: dt

    call ESMF_TimeSet(t_now, yy=yr, mm=mo, dd=dy, h=hr, m=mn, s=sc, &
                      calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_TimeIntervalSet(dt, s=elapsed, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    t_start = t_now - dt
    call ESMF_TimeGet(t_start, yy=yr_o, mm=mo_o, dd=dy_o, h=hr_o, m=mn_o, s=sc_o, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
  end subroutine start_time_from_elapsed

  ! Formatadores de data/hora

  !> @brief Nome do arquivo do passo: monan_export_AAAAMMDD_hhmmss.nc.
  function datetime_to_fname(yr,mo,dy,hr,mn,sc) result(s)
    integer, intent(in) :: yr,mo,dy,hr,mn,sc; character(len=36) :: s
    write(s,'(A,I4.4,2I2.2,A,3I2.2,A)') 'monan_export_',yr,mo,dy,'_',hr,mn,sc,'.nc'
  end function datetime_to_fname

  !> @brief Instante no formato ISO 8601 (AAAA-MM-DDThh:mm:ss).
  function datetime_to_iso(yr,mo,dy,hr,mn,sc) result(s)
    integer, intent(in) :: yr,mo,dy,hr,mn,sc; character(len=19) :: s
    write(s,'(I4.4,A,I2.2,A,I2.2,A,I2.2,A,I2.2,A,I2.2)') &
      yr,'-',mo,'-',dy,'T',hr,':',mn,':',sc
  end function datetime_to_iso

  !> @brief Instante no formato da unidade de tempo CF (AAAA-MM-DD hh:mm:ss).
  function datetime_to_cf_base(yr,mo,dy,hr,mn,sc) result(s)
    integer, intent(in) :: yr,mo,dy,hr,mn,sc; character(len=19) :: s
    write(s,'(I4.4,A,I2.2,A,I2.2,A,I2.2,A,I2.2,A,I2.2)') &
      yr,'-',mo,'-',dy,' ',hr,':',mn,':',sc
  end function datetime_to_cf_base

end module mpas_cap_netcdf_mod
