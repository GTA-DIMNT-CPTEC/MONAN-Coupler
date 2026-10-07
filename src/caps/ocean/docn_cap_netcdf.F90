!> @file docn_cap_netcdf.F90
!! @brief Diagnóstico NetCDF do componente de dados oceânicos DOCN.
!!
!! WriteDOCNDiag grava o diagnóstico docn_import_AAAAMMDD_HHMMSS.nc com SST,
!! gelo e correntes interpolados na grade do DOCN. A leitura dos arquivos
!! de dados fica em src/shared/ocn_data_reader.F90, que o cap do MOM6
!! também usa.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module docn_cap_netcdf_mod

  use ESMF
  use ESMF, only: ESMF_GridComp
  use ESMF, only: ESMF_Time, ESMF_TimeGet, ESMF_TimeSet
  use ESMF, only: ESMF_TimeInterval, ESMF_TimeIntervalGet
  use ESMF, only: ESMF_KIND_R8, ESMF_KIND_I8
  use ESMF, only: ESMF_SUCCESS
  use ESMF, only: ESMF_VM, ESMF_VMGetCurrent, ESMF_VMGet

  use netcdf
  use nc_writer_mod, only : nc_create, nc_global_header, nc_def_latlon, nc_def_field2d
  use mpi
  use coupler_constants_mod, only: T0_KELVIN
  use coupler_utils_mod, only: int_to_str, real_to_str
  use coupler_log_mod, only: COMP_DOCN, log_warning, log_info

  use coupler_config_mod, only: cfg_docn_mode,           &
                                  cfg_docn_sst_file,       &
                                  cfg_docn_ice_file,       &
                                  cfg_docn_cur_file,       &
                                  cfg_docn_dt_data,        &
                                  cfg_docn_epoch_year,     &
                                  cfg_docn_epoch_month,    &
                                  cfg_docn_epoch_day,      &
                                  cfg_docn_sst_varname,    &
                                  cfg_docn_ice_varname,    &
                                  cfg_docn_cur_u_varname,  &
                                  cfg_docn_cur_v_varname,  &
                                  cfg_docn_ice_pct,        &
                                  cfg_import_diag_dir

  implicit none
  private

  public :: WriteDOCNDiag       !< escrita diagnóstica docn_import_YYYYMMDD_HHMMSS.nc

contains

  !> @brief Escrita diagnóstica dos campos oceânicos por passo de acoplamento.
  !!
  !! Gera docn_import_YYYYMMDD_HHMMSS.nc com SST, gelo e correntes interpolados,
  !! na grade nativa do DOCN (sem reprojeção). Somente PET0 escreve; demais
  !! executam MPI_Barrier e retornam. Validação de SST/gelo vs fonte de dados.
  !!
  !! Etapas: posição no tempo dos dados (docn_epoch_seconds), SST
  !! (interp_docn_sst), fração de gelo (interp_docn_ice), correntes
  !! (interp_docn_currents) e gravação do arquivo (write_docn_diag_file).
  !! Os instantes vizinhos e o peso da interpolação seguem o mesmo algoritmo
  !! de ReadOcnFieldInterp.
  !!
  !! Ativada por write_import_diag=.true. em &nuopc_docn do nuopc.input.
  !! Lida por: postproc_mom6_import.py
  !!
  !! @param[in]  gcomp     Componente ESMF (para VM e clock)
  !! @param[in]  currTime  Tempo corrente da simulação
  !! @param[in]  nx, ny    Dimensões da grade DOCN
  !! @param[out] rc        Código de retorno ESMF
  subroutine WriteDOCNDiag(gcomp, currTime, nx, ny, rc)
    type(ESMF_GridComp),  intent(in)  :: gcomp
    type(ESMF_Time),      intent(in)  :: currTime
    integer,              intent(in)  :: nx, ny
    integer,              intent(out) :: rc

    type(ESMF_VM)  :: vm
    integer(ESMF_KIND_I8)   :: sec_since_epoch, dt_data_i8
    integer :: localPet, mpiComm, mpiErr
    integer :: yy, mm, dd, hh, mn, ss
    integer :: ntime, tidx0, tidx1
    logical :: opened
    real(ESMF_KIND_R8) :: alpha, fill_val
    real(ESMF_KIND_R8), allocatable :: f0(:,:), f1(:,:), fout(:,:)
    real(ESMF_KIND_R8), allocatable :: ice0(:,:), ice1(:,:), iceout(:,:)
    real(ESMF_KIND_R8), allocatable :: uout(:,:), vout(:,:)

    rc = ESMF_SUCCESS
    fill_val = -9999.0_ESMF_KIND_R8

    call ESMF_VMGetCurrent(vm, rc=rc); if (rc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, mpiCommunicator=mpiComm, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    ! Sincronizar: todos os PETs chegam aqui antes da escrita do PET0
    call MPI_Barrier(mpiComm, mpiErr)
    if (localPet /= 0) return   ! apenas PET0 executa o restante

    call ESMF_TimeGet(currTime, yy=yy, mm=mm, dd=dd, h=hh, m=mn, s=ss, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call docn_epoch_seconds(currTime, sec_since_epoch, dt_data_i8, rc)
    if (rc /= ESMF_SUCCESS) return
    alpha = real(mod(sec_since_epoch, dt_data_i8), ESMF_KIND_R8) / real(dt_data_i8, ESMF_KIND_R8)
    alpha = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, alpha))

    allocate(f0(nx,ny), f1(nx,ny), fout(nx,ny))
    allocate(uout(nx,ny), vout(nx,ny))
    uout = 0.0_ESMF_KIND_R8; vout = 0.0_ESMF_KIND_R8
    call interp_docn_sst(nx, ny, sec_since_epoch, dt_data_i8, alpha, fill_val, &
                         f0, f1, fout, ntime, tidx0, tidx1, opened)
    if (.not. opened) return

    allocate(ice0(nx,ny), ice1(nx,ny), iceout(nx,ny))
    call interp_docn_ice(nx, ny, sec_since_epoch, dt_data_i8, alpha, fill_val, ntime, &
                         ice0, ice1, iceout)

    call interp_docn_currents(nx, ny, sec_since_epoch, dt_data_i8, alpha, fill_val, &
                              f0, f1, uout, vout)

    call write_docn_diag_file(nx, ny, yy, mm, dd, hh, mn, ss, tidx0, tidx1, alpha, &
                              fill_val, fout, iceout, uout, vout)
  end subroutine WriteDOCNDiag

  !> @brief Segundos desde a época dos dados e intervalo entre instantes (s).
  subroutine docn_epoch_seconds(currTime, sec_since_epoch, dt_data_i8, rc)
    type(ESMF_Time),       intent(in)  :: currTime
    integer(ESMF_KIND_I8), intent(out) :: sec_since_epoch, dt_data_i8
    integer,               intent(out) :: rc
    type(ESMF_Time) :: epochTime
    type(ESMF_TimeInterval) :: dt_since_epoch

    call ESMF_TimeSet(epochTime, yy=cfg_docn_epoch_year, &
      mm=cfg_docn_epoch_month, dd=cfg_docn_epoch_day, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_since_epoch = currTime - epochTime
    call ESMF_TimeIntervalGet(dt_since_epoch, s_i8=sec_since_epoch, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_data_i8 = int(cfg_docn_dt_data, ESMF_KIND_I8)
  end subroutine docn_epoch_seconds

  !> @brief Tamanho da dimensão de tempo de um arquivo aberto.
  !!
  !! Procura a dimensão pelos nomes 'time' e 'Time' e, se all_caps, também
  !! 'TIME'. Sem a dimensão, devolve n_default.
  integer function docn_time_len(ncid_r, n_default, all_caps) result(ntime)
    integer, intent(in) :: ncid_r, n_default
    logical, intent(in) :: all_caps
    integer :: dimid_nt, ncstat

    ncstat = nf90_inq_dimid(ncid_r, 'time', dimid_nt)
    if (ncstat /= NF90_NOERR) ncstat = nf90_inq_dimid(ncid_r, 'Time', dimid_nt)
    if (all_caps .and. ncstat /= NF90_NOERR) ncstat = nf90_inq_dimid(ncid_r, 'TIME', dimid_nt)
    if (ncstat == NF90_NOERR) then
      ncstat = nf90_inquire_dimension(ncid_r, dimid_nt, len=ntime)
    else
      ntime = n_default
    end if
  end function docn_time_len

  !> @brief Instantes dos dados antes (tidx0) e depois (tidx1) do tempo atual.
  !!
  !! Os dados se repetem em ciclo de ntime instantes: depois do último vem o
  !! primeiro.
  pure subroutine docn_time_indices(sec_since_epoch, dt_data_i8, ntime, tidx0, tidx1)
    integer(ESMF_KIND_I8), intent(in)  :: sec_since_epoch, dt_data_i8
    integer,               intent(in)  :: ntime
    integer,               intent(out) :: tidx0, tidx1

    tidx0 = mod(int(sec_since_epoch / real(dt_data_i8, ESMF_KIND_R8)), ntime) + 1
    tidx1 = mod(tidx0, ntime) + 1
  end subroutine docn_time_indices

  !> @brief SST interpolada no tempo, em K, do arquivo cfg_docn_sst_file.
  !!
  !! Pontos com valor ausente (|valor| > 1e10) em algum dos dois instantes
  !! recebem fill_val; sem a variável, o campo inteiro recebe fill_val. Se o
  !! arquivo não abre, registra um aviso e devolve opened = .false.
  !! ntime (número de instantes do arquivo) serve de padrão para o gelo.
  subroutine interp_docn_sst(nx, ny, sec_since_epoch, dt_data_i8, alpha, fill_val, &
                             f0, f1, fout, ntime, tidx0, tidx1, opened)
    integer,               intent(in)    :: nx, ny
    integer(ESMF_KIND_I8), intent(in)    :: sec_since_epoch, dt_data_i8
    real(ESMF_KIND_R8),    intent(in)    :: alpha, fill_val
    real(ESMF_KIND_R8),    intent(inout) :: f0(:,:), f1(:,:)
    real(ESMF_KIND_R8),    intent(out)   :: fout(:,:)
    integer,               intent(out)   :: ntime, tidx0, tidx1
    logical,               intent(out)   :: opened
    integer :: ncid_r, varid_src, ncstat

    opened = .false.
    ncstat = nf90_open(trim(cfg_docn_sst_file), NF90_NOWRITE, ncid_r)
    if (ncstat /= NF90_NOERR) then
      call log_warning(COMP_DOCN, 'WriteDOCNDiag: falha ao abrir '// &
        trim(cfg_docn_sst_file)//': '//trim(nf90_strerror(ncstat)))
      return
    end if
    opened = .true.
    ntime = docn_time_len(ncid_r, huge(ntime), .true.)
    call docn_time_indices(sec_since_epoch, dt_data_i8, ntime, tidx0, tidx1)

    ncstat = nf90_inq_varid(ncid_r, trim(cfg_docn_sst_varname), varid_src)
    if (ncstat == NF90_NOERR) then
      ncstat = nf90_get_var(ncid_r, varid_src, f0, start=[1,1,tidx0], count=[nx,ny,1])
      ncstat = nf90_get_var(ncid_r, varid_src, f1, start=[1,1,tidx1], count=[nx,ny,1])
      fout = (1.0_ESMF_KIND_R8 - alpha)*f0 + alpha*f1
      fout = fout + T0_KELVIN   ! conversão °C → K
      where (abs(f0) > 1.0e10_ESMF_KIND_R8 .or. abs(f1) > 1.0e10_ESMF_KIND_R8) &
        fout = fill_val
    else
      fout = fill_val
    end if
    ncstat = nf90_close(ncid_r)
  end subroutine interp_docn_sst

  !> @brief Fração de gelo interpolada no tempo, do arquivo cfg_docn_ice_file.
  !!
  !! Com cfg_docn_ice_pct, os dados estão em % e são divididos por 100. O
  !! resultado é limitado a [0,1]; valores ausentes recebem fill_val. Sem o
  !! arquivo ou sem a variável, o campo inteiro recebe fill_val. Sem a
  !! dimensão de tempo, usa o número de instantes da SST (ntime_sst).
  subroutine interp_docn_ice(nx, ny, sec_since_epoch, dt_data_i8, alpha, fill_val, &
                             ntime_sst, ice0, ice1, iceout)
    integer,               intent(in)    :: nx, ny
    integer(ESMF_KIND_I8), intent(in)    :: sec_since_epoch, dt_data_i8
    real(ESMF_KIND_R8),    intent(in)    :: alpha, fill_val
    integer,               intent(in)    :: ntime_sst
    real(ESMF_KIND_R8),    intent(inout) :: ice0(:,:), ice1(:,:)
    real(ESMF_KIND_R8),    intent(out)   :: iceout(:,:)
    integer :: ncid_r, varid_src, ncstat
    integer :: ntime_i, tidx0_i, tidx1_i
    real(ESMF_KIND_R8) :: alpha_i

    ncstat = nf90_open(trim(cfg_docn_ice_file), NF90_NOWRITE, ncid_r)
    iceout = fill_val
    if (ncstat == NF90_NOERR) then
      ntime_i = docn_time_len(ncid_r, ntime_sst, .false.)
      call docn_time_indices(sec_since_epoch, dt_data_i8, ntime_i, tidx0_i, tidx1_i)
      alpha_i  = alpha
      ncstat = nf90_inq_varid(ncid_r, trim(cfg_docn_ice_varname), varid_src)
      if (ncstat == NF90_NOERR) then
        ncstat = nf90_get_var(ncid_r, varid_src, ice0, start=[1,1,tidx0_i], count=[nx,ny,1])
        ncstat = nf90_get_var(ncid_r, varid_src, ice1, start=[1,1,tidx1_i], count=[nx,ny,1])
        iceout = (1.0_ESMF_KIND_R8 - alpha_i)*ice0 + alpha_i*ice1
        if (cfg_docn_ice_pct) iceout = iceout / 100.0_ESMF_KIND_R8
        iceout = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, iceout))
        where (abs(ice0) > 1.0e10_ESMF_KIND_R8 .or. abs(ice1) > 1.0e10_ESMF_KIND_R8) &
          iceout = fill_val
      end if
      ncstat = nf90_close(ncid_r)
    end if
  end subroutine interp_docn_ice

  !> @brief Correntes superficiais interpoladas no tempo (opcional).
  !!
  !! Lidas de cfg_docn_cur_file, com os mesmos pesos da SST e com os
  !! instantes calculados pelo número de instantes do próprio arquivo (1 se
  !! não houver dimensão de tempo). Valores com módulo >= 10 m/s, no
  !! resultado ou em algum dos instantes, recebem fill_val. Sem o arquivo
  !! ou sem a variável, a componente é zero. f0 e f1 são áreas de trabalho.
  subroutine interp_docn_currents(nx, ny, sec_since_epoch, dt_data_i8, alpha, fill_val, &
                                  f0, f1, uout, vout)
    integer,               intent(in)    :: nx, ny
    integer(ESMF_KIND_I8), intent(in)    :: sec_since_epoch, dt_data_i8
    real(ESMF_KIND_R8),    intent(in)    :: alpha, fill_val
    real(ESMF_KIND_R8),    intent(inout) :: f0(:,:), f1(:,:)
    real(ESMF_KIND_R8),    intent(inout) :: uout(:,:), vout(:,:)
    integer :: ncid_r, varid_src, ncstat
    integer :: ntime_cur, tidx0_cur, tidx1_cur

    if (len_trim(cfg_docn_cur_file) > 0) then
      ncstat = nf90_open(trim(cfg_docn_cur_file), NF90_NOWRITE, ncid_r)
      if (ncstat == NF90_NOERR) then
        ntime_cur = docn_time_len(ncid_r, 1, .false.)
        call docn_time_indices(sec_since_epoch, dt_data_i8, ntime_cur, tidx0_cur, tidx1_cur)

        ncstat = nf90_inq_varid(ncid_r, trim(cfg_docn_cur_u_varname), varid_src)
        if (ncstat == NF90_NOERR) then
          ncstat = nf90_get_var(ncid_r, varid_src, f0, start=[1,1,tidx0_cur], count=[nx,ny,1])
          ncstat = nf90_get_var(ncid_r, varid_src, f1, start=[1,1,tidx1_cur], count=[nx,ny,1])
          uout = (1.0_ESMF_KIND_R8 - alpha)*f0 + alpha*f1
          where (abs(uout) >= 10.0_ESMF_KIND_R8 .or. &
                 abs(f0)   >= 10.0_ESMF_KIND_R8 .or. &
                 abs(f1)   >= 10.0_ESMF_KIND_R8) uout = fill_val
        else
          uout = 0.0_ESMF_KIND_R8
        end if

        ncstat = nf90_inq_varid(ncid_r, trim(cfg_docn_cur_v_varname), varid_src)
        if (ncstat == NF90_NOERR) then
          ncstat = nf90_get_var(ncid_r, varid_src, f0, start=[1,1,tidx0_cur], count=[nx,ny,1])
          ncstat = nf90_get_var(ncid_r, varid_src, f1, start=[1,1,tidx1_cur], count=[nx,ny,1])
          vout = (1.0_ESMF_KIND_R8 - alpha)*f0 + alpha*f1
          where (abs(vout) >= 10.0_ESMF_KIND_R8 .or. &
                 abs(f0)   >= 10.0_ESMF_KIND_R8 .or. &
                 abs(f1)   >= 10.0_ESMF_KIND_R8) vout = fill_val
        else
          vout = 0.0_ESMF_KIND_R8
        end if
        ncstat = nf90_close(ncid_r)
      else
        uout = 0.0_ESMF_KIND_R8; vout = 0.0_ESMF_KIND_R8
      end if
    else
      uout = 0.0_ESMF_KIND_R8; vout = 0.0_ESMF_KIND_R8
    end if
  end subroutine interp_docn_currents

  !> @brief Grava o arquivo docn_import_AAAAMMDD_HHMMSS.nc em cfg_import_diag_dir.
  !!
  !! Eixos na grade nativa do DOCN: longitude de 0 a 360 - 360/nx graus
  !! (o postproc_mom6_import.py faz o deslocamento) e latitude de -90 a 90.
  subroutine write_docn_diag_file(nx, ny, yy, mm, dd, hh, mn, ss, tidx0, tidx1, alpha, &
                                  fill_val, fout, iceout, uout, vout)
    integer,            intent(in) :: nx, ny, yy, mm, dd, hh, mn, ss, tidx0, tidx1
    real(ESMF_KIND_R8), intent(in) :: alpha, fill_val
    real(ESMF_KIND_R8), intent(in) :: fout(:,:), iceout(:,:), uout(:,:), vout(:,:)
    character(len=256) :: fname, dname
    character(len=19)  :: tstamp
    integer :: ncid_w, ncstat, i, j
    integer :: varid_sst, varid_ice, varid_u, varid_v
    integer :: varid_lat, varid_lon, dimid_lon, dimid_lat
    logical :: ok
    real(ESMF_KIND_R8), allocatable :: lon_ax(:), lat_ax(:)

    write(tstamp,'(I4.4,I2.2,I2.2,A,I2.2,I2.2,I2.2)') yy,mm,dd,'_',hh,mn,ss
    dname = trim(cfg_import_diag_dir)
    call execute_command_line('mkdir -p '//trim(dname), wait=.true.)
    fname = trim(dname)//'/docn_import_'//trim(tstamp)//'.nc'

    allocate(lon_ax(nx), lat_ax(ny))
    do i = 1, nx
      lon_ax(i) = real(i-1, ESMF_KIND_R8) * (360.0_ESMF_KIND_R8 / nx)
    end do
    do j = 1, ny
      lat_ax(j) = -90.0_ESMF_KIND_R8 + real(j-1, ESMF_KIND_R8) * (180.0_ESMF_KIND_R8 / (ny-1))
    end do

    if (.not. nc_create(fname, ncid_w, 'WriteDOCNDiag')) return

    call nc_global_header(ncid_w, &
      title='DOCN importState — SST/gelo interpolados por passo (campo global)', &
      institution='INPE/CGCT/DIMNT — GT Acoplamento de Modelos', &
      source='docn_cap_netcdf.F90::WriteDOCNDiag')
    write(tstamp,'(I4.4,A,I2.2,A,I2.2,A,I2.2,A,I2.2,A,I2.2)') &
      yy,'-',mm,'-',dd,'T',hh,':',mn,':',ss
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'valid_time',   trim(tstamp))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'docn_mode',    trim(cfg_docn_mode))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'sst_source',   trim(cfg_docn_sst_file))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'ice_source',   trim(cfg_docn_ice_file))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'sst_varname',  trim(cfg_docn_sst_varname))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'ice_varname',  trim(cfg_docn_ice_varname))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'ice_pct',      merge('true ', 'false', cfg_docn_ice_pct))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'tidx0',        tidx0)
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'tidx1',        tidx1)
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'alpha',        real(alpha,4))
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'method', &
      'PET0 direct re-read (B-58v2) — grid='//trim(merge('1440x720','360x180 ', &
       trim(cfg_docn_mode)=='netcdf')))

    if (.not. nc_def_latlon(ncid_w, nx, ny, dimid_lon, dimid_lat, &
                            varid_lon, varid_lat, 'WriteDOCNDiag')) then
      ncstat = nf90_close(ncid_w); return
    end if

    ok = nc_def_field2d(ncid_w, 'So_t', dimid_lon, dimid_lat, varid_sst, 'WriteDOCNDiag', &
           long_name='SST interpolada (OISST→NUOPC)', units='K', fill_r8=fill_val)
    ncstat = nf90_put_att(ncid_w, varid_sst, 'valid_min', 250.0_ESMF_KIND_R8)
    ncstat = nf90_put_att(ncid_w, varid_sst, 'valid_max', 315.0_ESMF_KIND_R8)

    ok = nc_def_field2d(ncid_w, 'Si_ifrac', dimid_lon, dimid_lat, varid_ice, 'WriteDOCNDiag', &
           long_name='Fracao de gelo marinho', units='1', fill_r8=fill_val)
    ncstat = nf90_put_att(ncid_w, varid_ice, 'valid_min', 0.0_ESMF_KIND_R8)
    ncstat = nf90_put_att(ncid_w, varid_ice, 'valid_max', 1.0_ESMF_KIND_R8)

    ok = nc_def_field2d(ncid_w, 'So_u', dimid_lon, dimid_lat, varid_u, 'WriteDOCNDiag', &
           long_name='Corrente zonal (zero se cur_file vazio)', units='m/s', fill_r8=fill_val)

    ok = nc_def_field2d(ncid_w, 'So_v', dimid_lon, dimid_lat, varid_v, 'WriteDOCNDiag', &
           long_name='Corrente meridional', units='m/s', fill_r8=fill_val)

    ncstat = nf90_enddef(ncid_w)
    ncstat = nf90_put_var(ncid_w, varid_lon, lon_ax)
    ncstat = nf90_put_var(ncid_w, varid_lat, lat_ax)
    ncstat = nf90_put_var(ncid_w, varid_sst, fout)
    ncstat = nf90_put_var(ncid_w, varid_ice, iceout)
    ncstat = nf90_put_var(ncid_w, varid_u,   uout)
    ncstat = nf90_put_var(ncid_w, varid_v,   vout)
    ncstat = nf90_close(ncid_w)
    call log_info(COMP_DOCN, 'WriteDOCNDiag: '//trim(fname)//' (tidx0='// &
      int_to_str(tidx0)//' alpha='// &
      real_to_str(alpha)//')')
  end subroutine write_docn_diag_file

end module docn_cap_netcdf_mod
