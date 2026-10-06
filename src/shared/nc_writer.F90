!> @file nc_writer.F90
!! @brief Rotinas comuns dos gravadores NetCDF do acoplador.
!!
!! Os gravadores de diagnóstico (exportação da atmosfera, importação da
!! atmosfera, importação do oceano no mediador e oceano de dados) seguem a
!! mesma sequência: criar o arquivo, gravar o cabeçalho CF, definir os eixos
!! de latitude e longitude e definir cada campo 2D com seus atributos. Este
!! módulo concentra essa sequência; cada gravador cuida só dos seus campos.
!!
!! As rotinas devolvem .true. em caso de sucesso. Uma falha do NetCDF é
!! registrada como aviso (coupler_log_mod) com a mensagem de nf90_strerror,
!! precedida do contexto dado por quem chama (a marca do componente e o nome
!! da rotina, por exemplo 'MED:med_write_import_fields'); quem chama decide
!! se a falha interrompe a gravação.
module nc_writer_mod

  use ESMF,   only : ESMF_KIND_R8, ESMF_KIND_R4
  use coupler_log_mod, only : log_warning
  use netcdf

  implicit none
  private

  public :: nc_ok, nc_create, nc_global_header, nc_def_latlon, nc_def_field2d

contains

  !> @brief .true. se status indica sucesso; senão registra a falha no log
  !! ('contexto: mensagem do NetCDF') e devolve .false.
  logical function nc_ok(status, context)
    integer,          intent(in) :: status
    character(len=*), intent(in) :: context
    nc_ok = (status == NF90_NOERR)
    if (.not. nc_ok) call log_warning(trim(context), trim(nf90_strerror(status)))
  end function nc_ok

  !> @brief Cria (ou sobrescreve) o arquivo fname e abre em modo de definição.
  logical function nc_create(fname, ncid, context)
    character(len=*), intent(in)  :: fname, context
    integer,          intent(out) :: ncid
    nc_create = nc_ok(nf90_create(trim(fname), NF90_CLOBBER, ncid), &
                      trim(context)//': nf90_create '//trim(fname))
  end function nc_create

  !> @brief Cabeçalho global CF: Conventions, title, institution e source.
  subroutine nc_global_header(ncid, title, institution, source)
    integer,          intent(in) :: ncid
    character(len=*), intent(in) :: title, institution, source
    integer :: s
    s = nf90_put_att(ncid, NF90_GLOBAL, 'Conventions', 'CF-1.8')
    s = nf90_put_att(ncid, NF90_GLOBAL, 'title',       title)
    s = nf90_put_att(ncid, NF90_GLOBAL, 'institution', institution)
    s = nf90_put_att(ncid, NF90_GLOBAL, 'source',      source)
  end subroutine nc_global_header

  !> @brief Dimensões e variáveis de coordenada 'lat' e 'lon' (NF90_DOUBLE), com
  !! long_name, units, standard_name e axis. Define 'lat' antes de 'lon'.
  logical function nc_def_latlon(ncid, nlon, nlat, dimid_lon, dimid_lat, &
                                 varid_lon, varid_lat, context)
    integer,          intent(in)  :: ncid, nlon, nlat
    integer,          intent(out) :: dimid_lon, dimid_lat, varid_lon, varid_lat
    character(len=*), intent(in)  :: context
    integer :: s

    nc_def_latlon = .false.
    if (.not. nc_ok(nf90_def_dim(ncid, 'lat', nlat, dimid_lat), trim(context)//': def_dim lat')) return
    if (.not. nc_ok(nf90_def_dim(ncid, 'lon', nlon, dimid_lon), trim(context)//': def_dim lon')) return

    if (.not. nc_ok(nf90_def_var(ncid, 'lat', NF90_DOUBLE, [dimid_lat], varid_lat), &
                    trim(context)//': def_var lat')) return
    s = nf90_put_att(ncid, varid_lat, 'long_name',     'latitude')
    s = nf90_put_att(ncid, varid_lat, 'units',         'degrees_north')
    s = nf90_put_att(ncid, varid_lat, 'standard_name', 'latitude')
    s = nf90_put_att(ncid, varid_lat, 'axis',          'Y')

    if (.not. nc_ok(nf90_def_var(ncid, 'lon', NF90_DOUBLE, [dimid_lon], varid_lon), &
                    trim(context)//': def_var lon')) return
    s = nf90_put_att(ncid, varid_lon, 'long_name',     'longitude')
    s = nf90_put_att(ncid, varid_lon, 'units',         'degrees_east')
    s = nf90_put_att(ncid, varid_lon, 'standard_name', 'longitude')
    s = nf90_put_att(ncid, varid_lon, 'axis',          'X')
    nc_def_latlon = .true.
  end function nc_def_latlon

  !> @brief Campo 2D (lon, lat) com os atributos presentes, nesta ordem: long_name,
  !! units, standard_name, _FillValue e, com missing=.true., missing_value
  !! igual ao _FillValue. O tipo segue o valor de preenchimento: fill_r8 dá
  !! NF90_DOUBLE, fill_r4 dá NF90_FLOAT (sem nenhum dos dois: NF90_DOUBLE).
  logical function nc_def_field2d(ncid, name, dimid_lon, dimid_lat, varid, context, &
                                  long_name, units, standard_name, fill_r8, fill_r4, missing)
    integer,            intent(in)  :: ncid, dimid_lon, dimid_lat
    character(len=*),   intent(in)  :: name, context
    integer,            intent(out) :: varid
    character(len=*),   intent(in), optional :: long_name, units, standard_name
    real(ESMF_KIND_R8), intent(in), optional :: fill_r8
    real(ESMF_KIND_R4), intent(in), optional :: fill_r4
    logical,            intent(in), optional :: missing
    integer :: s, xtype
    logical :: put_missing

    xtype = NF90_DOUBLE
    if (present(fill_r4)) xtype = NF90_FLOAT
    nc_def_field2d = nc_ok(nf90_def_var(ncid, trim(name), xtype, [dimid_lon, dimid_lat], varid), &
                           trim(context)//': def_var '//trim(name))
    if (.not. nc_def_field2d) return

    put_missing = .false.
    if (present(missing)) put_missing = missing
    if (present(long_name))     s = nf90_put_att(ncid, varid, 'long_name',     long_name)
    if (present(units))         s = nf90_put_att(ncid, varid, 'units',         units)
    if (present(standard_name)) s = nf90_put_att(ncid, varid, 'standard_name', standard_name)
    if (present(fill_r8)) then
      s = nf90_put_att(ncid, varid, '_FillValue', fill_r8)
      if (put_missing) s = nf90_put_att(ncid, varid, 'missing_value', fill_r8)
    else if (present(fill_r4)) then
      s = nf90_put_att(ncid, varid, '_FillValue', fill_r4)
      if (put_missing) s = nf90_put_att(ncid, varid, 'missing_value', fill_r4)
    end if
  end function nc_def_field2d

end module nc_writer_mod
