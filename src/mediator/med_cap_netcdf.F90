!> @file med_cap_netcdf.F90
!! @brief Diagnóstico NetCDF do mediador MED — leitura de configuração e escrita de campos.
!!
!! Versão 1.0 (Mai/2026) — GT Acoplamento de Modelos / INPE/CGCT/DIMNT
!!
!! Contém as sub-rotinas de I/O NetCDF extraídas de MED_cap.F90
!! como parte da reorganização de responsabilidades (Passo 2):
!!
!!   med_read_import_config    — lê mom6_output.nml → configura diagnóstico
!!   med_write_import_fields   — escreve mom6_import_YYYYMMDD_HHMMSS.nc
!!
!! Estas rotinas não pertencem à lógica de um mediador NUOPC. Separadas aqui
!! para reduzir MED_cap.F90 e concentrar I/O NetCDF neste módulo.

module med_cap_netcdf_mod

  use ESMF
  use netcdf
  use mpi
  use ieee_arithmetic, only: ieee_is_finite   ! guard NaN/Inf antes de nf90_put_var

  use med_cap_types_mod, only: MED_InternalState,      &
                                med_write_import_diag,  &
                                med_import_diag_dir,    &
                                med_mpi_comm,           &
                                med_local_pet,          &
                                med_pet_count

  implicit none
  private

  public :: med_read_import_config    !< lê mom6_output.nml
  public :: med_write_import_fields   !< escreve campos importados em NetCDF

contains

  !============================================================================
  !> @brief Lê configuração de diagnóstico de importação de mom6_output.nml.
  !!
  !! Usa namelist &mom6_output com apenas 2 variáveis: write_import_diag e
  !! import_diag_dir. Sem essa restrição, o read(nml=...) reportaria ios/=0
  !! ao encontrar outras variáveis do namelist original.
  !! Arquivo lido: mom6_output.nml no diretório de execução.
  !============================================================================
  subroutine med_read_import_config()

    logical            :: write_import_diag
    character(len=256) :: import_diag_dir
    integer            :: ios, unitn
    logical            :: exists

    namelist /mom6_output/ write_import_diag, import_diag_dir

    ! Defaults
    write_import_diag = .false.
    import_diag_dir   = 'diag_import'

    inquire(file='mom6_output.nml', exist=exists)
    if (.not. exists) then
      call ESMF_LogWrite( &
        'MED: mom6_output.nml nao encontrado — diag import desabilitado', &
        ESMF_LOGMSG_INFO)
      return
    end if

    open(newunit=unitn, file='mom6_output.nml', status='old', &
         action='read', iostat=ios)
    if (ios /= 0) return

    read(unitn, nml=mom6_output, iostat=ios)
    close(unitn)
    if (ios /= 0) return

    ! Escreve nas variáveis de módulo de med_cap_types_mod (save, persistentes)
    med_write_import_diag = write_import_diag
    med_import_diag_dir   = trim(import_diag_dir)

    call ESMF_LogWrite( &
      'MED: mom6_output.nml lido — diag import = ' // &
      merge('T', 'F', med_write_import_diag), ESMF_LOGMSG_INFO)

  end subroutine med_read_import_config

  !============================================================================
  !> @brief Escreve os campos do exportState MED→OCN em arquivo NetCDF CF-1.8.
  !!
  !! Lê dos campos ATM internos (grade 360×180 global), faz MPI_Allreduce(MAX)
  !! para montar o campo global completo, e PET0 cria o NetCDF.
  !!
  !! FIX-IMP (GT Acoplamento de Modelos/INPE — Mai/2026):
  !!   FIX-IMP-01: MPI gather global (Allreduce MAX) — campo completo no NetCDF.
  !!   FIX-IMP-02: Coordenadas lat/lon variáveis CF com eixo centrado em células.
  !!   FIX-IMP-03: Variável 'time' CF com units="hours since...".
  !!   FIX-IMP-04: Centros de célula: lon_k = (k-0.5)*dx, dx=360/NX.
  !!   FIX-IMP-05: standard_name para reconhecimento CF/ncview.
  !!   FIX-IMP-06: valid_time em ISO 8601.
  !!   FIX-IMP-07: Atributos globais revisados para clareza semântica.
  !!
  !! Saída: <med_import_diag_dir>/mom6_import_YYYYMMDD_HHMMSS.nc
  !!   Dimensões: lat(180), lon(360)  [grade MED interna ATM]
  !!   Variáveis: lat, lon, time + 14 campos Foxx_*/Faxa_*/Sa_*/So_*
  !!
  !! @param[inout] state     exportState MED→OCN
  !! @param[in]   currTime  Tempo corrente (para nome do arquivo e atributo time)
  !! @param[inout] is       Estado interno do mediador (campos ATM internos)
  !! @param[out]  rc        Código de retorno ESMF
  !============================================================================
  subroutine med_write_import_fields(state, currTime, is, rc)
    type(ESMF_State),        intent(inout) :: state
    type(ESMF_Time),         intent(in)    :: currTime
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    type(ESMF_Field)                :: field
    type(ESMF_Grid)                 :: the_grid
    type(ESMF_StateItem_Flag)       :: itemType
    real(ESMF_KIND_R8), pointer     :: fptr2d(:,:)
    real(ESMF_KIND_R8), pointer     :: xcoord(:,:), ycoord(:,:)
    real(ESMF_KIND_R8), allocatable :: grid_local(:,:), grid_global(:,:)
    integer :: fieldCount, n, ncid, varid, ios, mpi_ierr
    integer :: dimid_lat, dimid_lon
    integer :: varid_lat, varid_lon, varid_t
    integer :: nx_local, ny_local, nx_global, ny_global
    integer :: ix, iy, ig, jg, fld_rank
    integer :: nx_max_local, ny_max_local
    integer :: yy, mm, dd, hh, mn, ss
    character(len=256)  :: fname, dpath
    character(len=20)   :: tstamp
    character(len=64),  allocatable :: fieldNameList(:)
    real(ESMF_KIND_R8), allocatable :: lat_global(:), lon_global(:)
    real(ESMF_KIND_R8), parameter :: FILL_IMP  = -9.99e+20_ESMF_KIND_R8
    ! BUG-NC-03: _FillValue NC_FLOAT deve ser real(4) — tipo deve bater com NF90_FLOAT.
    real(4), parameter :: FILL_IMP4 = -9.99e+20_4
    ! Grade MED interna — alinhada com InitializeRealize (360×180 ATM)
    real(ESMF_KIND_R8), parameter :: NX_MED_ATM = 360.0_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: NY_MED_ATM = 180.0_ESMF_KIND_R8
    character(len=*), parameter :: subname = 'MED:med_write_import_fields'

    rc = ESMF_SUCCESS
    if (.not. med_write_import_diag) return
    if (med_mpi_comm == -1) then
      call ESMF_LogWrite(subname//': MPI comm nao inicializado', ESMF_LOGMSG_WARNING)
      return
    end if

    ! Montar timestamp
    call ESMF_TimeGet(currTime, yy=yy, mm=mm, dd=dd, h=hh, m=mn, s=ss, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    write(tstamp,'(I4.4,I2.2,I2.2,A1,I2.2,I2.2,I2.2)') yy,mm,dd,'_',hh,mn,ss

    dpath = trim(med_import_diag_dir)
    call execute_command_line('mkdir -p '//trim(dpath), wait=.true.)
    fname = trim(dpath)//'/mom6_import_'//trim(tstamp)//'.nc'

    ! Enumerar campos
    call ESMF_StateGet(state, itemCount=fieldCount, rc=rc)
    if (rc /= ESMF_SUCCESS .or. fieldCount == 0) return
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(state, itemNameList=fieldNameList, rc=rc)
    if (rc /= ESMF_SUCCESS) then; deallocate(fieldNameList); return; end if

    ! FIX-IMP: usar ESMF_GridGetCoord para coordenadas reais
    nx_local = 0; ny_local = 0
    nullify(xcoord, ycoord, fptr2d)

    do n = 1, fieldCount
      call ESMF_StateGet(state, itemName=trim(fieldNameList(n)), itemType=itemType, rc=rc)
      if (rc /= ESMF_SUCCESS) cycle
      if (itemType /= ESMF_STATEITEM_FIELD) cycle
      call ESMF_StateGet(state, itemName=trim(fieldNameList(n)), field=field, rc=rc)
      if (rc /= ESMF_SUCCESS) cycle
      call ESMF_FieldGet(field, dimCount=fld_rank, rc=rc)
      if (rc /= ESMF_SUCCESS .or. fld_rank /= 2) cycle
      nullify(fptr2d)
      call ESMF_FieldGet(field, farrayPtr=fptr2d, rc=rc)
      if (rc /= ESMF_SUCCESS .or. .not. associated(fptr2d)) cycle
      nx_local = size(fptr2d, 1)
      ny_local = size(fptr2d, 2)
      call ESMF_FieldGet(field, grid=the_grid, rc=rc)
      if (rc == ESMF_SUCCESS) then
        call ESMF_GridGetCoord(the_grid, coordDim=1, localDE=0, &
          staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=xcoord, rc=rc)
        if (rc /= ESMF_SUCCESS) nullify(xcoord)
        call ESMF_GridGetCoord(the_grid, coordDim=2, localDE=0, &
          staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=ycoord, rc=rc)
        if (rc /= ESMF_SUCCESS) nullify(ycoord)
      end if
      exit
    end do
    rc = ESMF_SUCCESS

    if (nx_local == 0 .or. ny_local == 0) then
      call ESMF_LogWrite(subname//': dimensoes locais indeterminaveis', ESMF_LOGMSG_WARNING)
      deallocate(fieldNameList); return
    end if

    ! BUG-IMP-02: grade MED regular e conhecida a priori: 360×180
    nx_global = int(NX_MED_ATM)
    ny_global = int(NY_MED_ATM)

    ! PET0: criar arquivo NetCDF
    if (med_local_pet == 0) then
      ios = nf90_create(trim(fname), NF90_CLOBBER, ncid)
      if (ios /= NF90_NOERR) then
        call ESMF_LogWrite(subname//': falha nf90_create: '//trim(fname), ESMF_LOGMSG_WARNING)
        deallocate(fieldNameList); return
      end if

      ios = nf90_put_att(ncid, NF90_GLOBAL, 'Conventions', 'CF-1.8')
      ios = nf90_put_att(ncid, NF90_GLOBAL, 'title', &
        'MED exportState (= MOM6 importState) — Fluxos MONAN-A x MOM6')
      ios = nf90_put_att(ncid, NF90_GLOBAL, 'institution', 'INPE/CGCT/DIMNT')
      ios = nf90_put_att(ncid, NF90_GLOBAL, 'source', &
        'med_cap_netcdf.F90::med_write_import_fields v1.0 (migrado de MED_cap_MONAN)')
      block
        character(len=19) :: iso_time
        write(iso_time,'(I4.4,A,I2.2,A,I2.2,A,I2.2,A,I2.2,A,I2.2)') &
          yy,'-',mm,'-',dd,'T',hh,':',mn,':',ss
        ios = nf90_put_att(ncid, NF90_GLOBAL, 'valid_time', trim(iso_time))
      end block
      ios = nf90_put_att(ncid, NF90_GLOBAL, 'nx_global', nx_global)
      ios = nf90_put_att(ncid, NF90_GLOBAL, 'ny_global', ny_global)
      ios = nf90_put_att(ncid, NF90_GLOBAL, 'petCount',  med_pet_count)

      ios = nf90_def_dim(ncid, 'lat', ny_global, dimid_lat); if (ios/=NF90_NOERR) goto 999
      ios = nf90_def_dim(ncid, 'lon', nx_global, dimid_lon); if (ios/=NF90_NOERR) goto 999

      ios = nf90_def_var(ncid, 'lat', NF90_DOUBLE, [dimid_lat], varid_lat)
      ios = nf90_put_att(ncid, varid_lat, 'long_name',     'latitude')
      ios = nf90_put_att(ncid, varid_lat, 'units',         'degrees_north')
      ios = nf90_put_att(ncid, varid_lat, 'standard_name', 'latitude')
      ios = nf90_put_att(ncid, varid_lat, 'axis',          'Y')

      ios = nf90_def_var(ncid, 'lon', NF90_DOUBLE, [dimid_lon], varid_lon)
      ios = nf90_put_att(ncid, varid_lon, 'long_name',     'longitude')
      ios = nf90_put_att(ncid, varid_lon, 'units',         'degrees_east')
      ios = nf90_put_att(ncid, varid_lon, 'standard_name', 'longitude')
      ios = nf90_put_att(ncid, varid_lon, 'axis',          'X')

      ios = nf90_def_var(ncid, 'time', NF90_DOUBLE, varid_t)
      ios = nf90_put_att(ncid, varid_t, 'units', &
        'hours since '//tstamp(1:4)//'-'//tstamp(5:6)//'-'//tstamp(7:8)//' 00:00:00')
      ios = nf90_put_att(ncid, varid_t, 'calendar', 'gregorian')

      do n = 1, fieldCount
        ! BUG-NC-03: NF90_FLOAT em vez de NF90_DOUBLE
        ios = nf90_def_var(ncid, trim(fieldNameList(n)), NF90_FLOAT, &
          [dimid_lon, dimid_lat], varid)
        if (ios == NF90_NOERR) then
          ios = nf90_put_att(ncid, varid, '_FillValue',    FILL_IMP4)
          ios = nf90_put_att(ncid, varid, 'missing_value', FILL_IMP4)
          block
            character(len=32) :: f_units
            character(len=80) :: f_long, f_std
            select case (trim(fieldNameList(n)))
              case ('Foxx_taux');      f_units='Pa';         f_long='Tensao cisalhamento zonal';     f_std='surface_downward_eastward_stress'
              case ('Foxx_tauy');      f_units='Pa';         f_long='Tensao cisalhamento meridional'; f_std='surface_downward_northward_stress'
              case ('Foxx_sen');       f_units='W m-2';      f_long='Fluxo de calor sensivel';       f_std='surface_upward_sensible_heat_flux'
              case ('Foxx_evap');      f_units='kg m-2 s-1'; f_long='Fluxo de evaporacao';           f_std='water_evaporation_flux'
              case ('Foxx_lwnet');     f_units='W m-2';      f_long='Balanco onda longa';            f_std='surface_net_downward_longwave_flux'
              case ('Foxx_swnet_vdr'); f_units='W m-2';      f_long='Onda curta vis. direto';        f_std='surface_net_downward_shortwave_flux'
              case ('Foxx_swnet_vdf'); f_units='W m-2';      f_long='Onda curta vis. difuso';        f_std='surface_net_downward_shortwave_flux'
              case ('Foxx_swnet_idr'); f_units='W m-2';      f_long='Onda curta IR direto';          f_std='surface_net_downward_shortwave_flux'
              case ('Foxx_swnet_idf'); f_units='W m-2';      f_long='Onda curta IR difuso';          f_std='surface_net_downward_shortwave_flux'
              case ('Faxa_rain');      f_units='kg m-2 s-1'; f_long='Precipitacao liquida';          f_std='rainfall_flux'
              case ('Faxa_snow');      f_units='kg m-2 s-1'; f_long='Precipitacao solida';           f_std='snowfall_flux'
              case ('Sa_pslv');        f_units='Pa';          f_long='Pressao nivel do mar';          f_std='air_pressure_at_mean_sea_level'
              case ('Si_ifrac');       f_units='1';           f_long='Fracao de gelo marinho';        f_std='sea_ice_area_fraction'
              case ('So_duu10n');      f_units='m2 s-2';      f_long='Vento relativo ao oceano^2';    f_std='square_of_air_velocity'
              case ('So_t');           f_units='K';            f_long='SST dinamica MOM6';             f_std='sea_surface_temperature'
              case default;            f_units='1';           f_long=trim(fieldNameList(n));           f_std='unknown'
            end select
            ios = nf90_put_att(ncid, varid, 'units',         trim(f_units))
            ios = nf90_put_att(ncid, varid, 'long_name',     trim(f_long))
            ios = nf90_put_att(ncid, varid, 'standard_name', trim(f_std))
          end block
        end if
      end do

      ios = nf90_enddef(ncid)
      if (ios /= NF90_NOERR) goto 999

      ! Coordenadas uniformes — centros de célula
      ! BUG-NC-05: lat(k) = (k-0.5)*dy - 90, dy=180/ny_global
      allocate(lat_global(ny_global), lon_global(nx_global))
      do n = 1, ny_global
        lat_global(n) = -90.0_ESMF_KIND_R8 + (n - 0.5_ESMF_KIND_R8) * &
                        180.0_ESMF_KIND_R8 / real(ny_global, ESMF_KIND_R8)
      end do
      ! BUG-IMP-04: lon_k = (k-0.5)*dx, dx=360/nx_global
      do n = 1, nx_global
        lon_global(n) = (n - 0.5_ESMF_KIND_R8) * 360.0_ESMF_KIND_R8 / real(nx_global, ESMF_KIND_R8)
      end do
      ios = nf90_put_var(ncid, varid_lat, lat_global)
      ios = nf90_put_var(ncid, varid_lon, lon_global)
      ios = nf90_put_var(ncid, varid_t, real(hh,ESMF_KIND_R8) + real(mn,ESMF_KIND_R8)/60.0_ESMF_KIND_R8)
      deallocate(lat_global, lon_global)
    end if  ! localPet==0

    ! Para cada campo: preencher grid_local, MPI_Allreduce(MAX), PET0 escreve
    allocate(grid_local(nx_global, ny_global))
    allocate(grid_global(nx_global, ny_global))

    do n = 1, fieldCount
      ! BUG-WRITE-OCN: ler dos campos ATM internos (grade 360×180 global)
      nullify(fptr2d)
      select case (trim(fieldNameList(n)))
        case ('Foxx_taux');      call ESMF_FieldGet(is%f_taux_atm,   farrayPtr=fptr2d, rc=rc)
        case ('Foxx_tauy');      call ESMF_FieldGet(is%f_tauy_atm,   farrayPtr=fptr2d, rc=rc)
        case ('Foxx_sen');       call ESMF_FieldGet(is%f_sen_atm,    farrayPtr=fptr2d, rc=rc)
        case ('Foxx_evap');      call ESMF_FieldGet(is%f_evap_atm,   farrayPtr=fptr2d, rc=rc)
        case ('Foxx_lwnet');     call ESMF_FieldGet(is%f_lwnet_atm,  farrayPtr=fptr2d, rc=rc)
        case ('Foxx_swnet_vdr'); call ESMF_FieldGet(is%f_swvdr_atm,  farrayPtr=fptr2d, rc=rc)
        case ('Foxx_swnet_vdf'); call ESMF_FieldGet(is%f_swvdf_atm,  farrayPtr=fptr2d, rc=rc)
        case ('Foxx_swnet_idr'); call ESMF_FieldGet(is%f_swidr_atm,  farrayPtr=fptr2d, rc=rc)
        case ('Foxx_swnet_idf'); call ESMF_FieldGet(is%f_swidf_atm,  farrayPtr=fptr2d, rc=rc)
        case ('Faxa_rain');      call ESMF_FieldGet(is%f_rain_atm,   farrayPtr=fptr2d, rc=rc)
        case ('Faxa_snow');      call ESMF_FieldGet(is%f_snow_atm,   farrayPtr=fptr2d, rc=rc)
        case ('Sa_pslv');        call ESMF_FieldGet(is%f_pslv_atm,   farrayPtr=fptr2d, rc=rc)
        case ('Si_ifrac');       call ESMF_FieldGet(is%f_ifrac_atm,  farrayPtr=fptr2d, rc=rc)
        case ('So_duu10n');      call ESMF_FieldGet(is%f_duu10n_atm, farrayPtr=fptr2d, rc=rc)
        case ('So_t');           call ESMF_FieldGet(is%f_sst_atm,    farrayPtr=fptr2d, rc=rc)
        case default; rc = ESMF_SUCCESS; cycle
      end select
      if (rc /= ESMF_SUCCESS .or. .not. associated(fptr2d)) then
        rc = ESMF_SUCCESS; cycle
      end if

      grid_local = FILL_IMP

      ! Scatter direto: grade ATM 360×180 = grade de saída → mapeamento 1:1
      block
        integer :: i1a, i2a, j1a, j2a
        i1a = max(1, lbound(fptr2d,1));  i2a = min(nx_global, ubound(fptr2d,1))
        j1a = max(1, lbound(fptr2d,2));  j2a = min(ny_global, ubound(fptr2d,2))
        if (i2a >= i1a .and. j2a >= j1a) &
          grid_local(i1a:i2a, j1a:j2a) = fptr2d(i1a:i2a, j1a:j2a)
      end block

      ! MPI_Allreduce(MAX): combina subdomínios; descarta fill_val (−9.99e20)
      call MPI_Allreduce(grid_local, grid_global, nx_global*ny_global, &
                         MPI_DOUBLE_PRECISION, MPI_MAX, med_mpi_comm, mpi_ierr)

      ! BUG-NC-03: guardar NaN/Inf antes de escrever como NF90_FLOAT
      where (.not. ieee_is_finite(grid_global))
        grid_global = FILL_IMP
      end where

      if (med_local_pet == 0) then
        ios = nf90_inq_varid(ncid, trim(fieldNameList(n)), varid)
        if (ios == NF90_NOERR) ios = nf90_put_var(ncid, varid, real(grid_global, 4))
      end if
      rc = ESMF_SUCCESS
    end do  ! campos

    deallocate(grid_local, grid_global, fieldNameList)

    if (med_local_pet == 0) then
      ios = nf90_close(ncid)
      call ESMF_LogWrite(subname//': escrito '//trim(fname), ESMF_LOGMSG_INFO)
    end if
    return

999 continue
    if (med_local_pet == 0) ios = nf90_close(ncid)
    if (allocated(grid_local))    deallocate(grid_local)
    if (allocated(grid_global))   deallocate(grid_global)
    if (allocated(fieldNameList)) deallocate(fieldNameList)
    call ESMF_LogWrite(subname//': ERRO NetCDF '//trim(fname), ESMF_LOGMSG_WARNING)
    rc = ESMF_SUCCESS

  end subroutine med_write_import_fields

end module med_cap_netcdf_mod
