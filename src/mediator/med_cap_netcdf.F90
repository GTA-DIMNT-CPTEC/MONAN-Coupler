!> @file med_cap_netcdf.F90
!! @brief Diagnóstico NetCDF do mediador MED; leitura de configuração e escrita de campos.
!!
!! Rotinas:
!!
!!   med_read_import_config:     lê mom6_output.nml → configura diagnóstico
!!   med_write_import_fields:    escreve mom6_import_YYYYMMDD_HHMMSS.nc
!!
!! Diagnóstico de saída, fora da lógica do mediador NUOPC.

module med_cap_netcdf_mod

  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY, FILL_VALUE_R8
  use netcdf
  use nc_writer_mod, only : nc_create, nc_global_header, nc_def_latlon, nc_def_field2d
  use mpi
  use ieee_arithmetic, only: ieee_is_finite   ! guard NaN/Inf antes de nf90_put_var

  use med_cap_types_mod, only: MED_InternalState, med_diag_config_t, med_field_index
  use coupler_log_mod, only: COMP_MED, log_info, log_warning, log_debug
  use cpl_fields_mod, only: cpl_field_attributes

  implicit none
  private

  public :: med_read_import_config    !< lê mom6_output.nml
  public :: med_write_import_fields   !< escreve campos importados em NetCDF


  ! Início das mensagens de med_write_import_fields e das suas etapas; com a
  ! marca do componente, contexto das mensagens de erro de nc_writer.
  character(len=*), parameter :: ROUTINE = 'med_write_import_fields'
  character(len=*), parameter :: subname = COMP_MED//':'//ROUTINE

contains

  !> @brief Lê configuração de diagnóstico de importação de mom6_output.nml.
  !!
  !! Usa namelist &mom6_output com apenas 2 variáveis: write_import_diag e
  !! import_diag_dir. Sem essa restrição, o read(nml=...) reportaria ios/=0
  !! ao encontrar outras variáveis do namelist original.
  !! Arquivo lido: mom6_output.nml no diretório de execução.
  !!
  !! @param[inout] diag  configuração do diagnóstico de importação do
  !!                     estado interno (is%diag); sem o arquivo, ficam os
  !!                     padrões
  subroutine med_read_import_config(diag)
    type(med_diag_config_t), intent(inout) :: diag

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
      call log_info(COMP_MED, 'mom6_output.nml nao encontrado: diag import desabilitado')
      return
    end if

    open(newunit=unitn, file='mom6_output.nml', status='old', &
         action='read', iostat=ios)
    if (ios /= 0) return

    read(unitn, nml=mom6_output, iostat=ios)
    close(unitn)
    if (ios /= 0) return

    ! Guarda no estado interno do mediador
    diag%write_import = write_import_diag
    diag%import_dir   = trim(import_diag_dir)

    call log_info(COMP_MED, 'mom6_output.nml lido: diag import = ' // &
      merge('T', 'F', diag%write_import))

  end subroutine med_read_import_config

  !> @brief Escreve os campos do exportState MED→OCN em arquivo NetCDF CF-1.8.
  !!
  !! Lê dos campos ATM internos (grade 360×180 global), faz MPI_Allreduce(MAX)
  !! para montar o campo global completo, e PET0 cria o NetCDF.
  !!
  !! Características do arquivo:
  !! MPI gather global (Allreduce MAX); campo completo no NetCDF.
  !! Coordenadas lat/lon variáveis CF com eixo centrado em células.
  !! Variável 'time' CF com units="hours since...".
  !! Centros de célula: lon_k = (k-0.5)*dx, dx=360/NX.
  !! standard_name para reconhecimento CF/ncview.
  !! valid_time em ISO 8601.
  !! Atributos globais revisados para clareza semântica.
  !!
  !! continentes mascarados com a máscara REAL
  !!   do MOM6 (ocean_grid%mask2dT → So_omask → is%ocn%omask). Célula de
  !!   terra passa a sair como _FillValue em vez de zero, e a própria máscara
  !!   é gravada na variável Sx_omask (1=oceano, 0=terra).
  !!
  !! Saída: <is%diag%import_dir>/mom6_import_YYYYMMDD_HHMMSS.nc
  !!   Dimensões: lat(180), lon(360)  [grade MED interna ATM]
  !!   Variáveis: lat, lon, time + campos Foxx_*/Faxa_*/Sa_*/So_*/Fioi_*/Sx_*
  !!
  !! Etapas: local_field_shape (confere que o PET tem dados locais),
  !! define_import_file (PET 0), gather_ocean_mask, e, para cada campo,
  !! internal_field_ptr e gather_field_global.
  !!
  !! @param[inout] state     exportState MED→OCN
  !! @param[in]   currTime  Tempo corrente (para nome do arquivo e atributo time)
  !! @param[inout] is       Estado interno do mediador (campos ATM internos)
  !! @param[out]  rc        Código de retorno ESMF
  subroutine med_write_import_fields(state, currTime, is, rc)
    type(ESMF_State),        intent(inout) :: state
    type(ESMF_Time),         intent(in)    :: currTime
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    real(ESMF_KIND_R8), pointer     :: fptr2d(:,:)
    real(ESMF_KIND_R8), allocatable :: grid_local(:,:), grid_global(:,:)
    ! máscara terra/oceano do MOM6 na grade de saída.
    real(ESMF_KIND_R8), allocatable :: mask_global(:,:)
    logical :: mask_ok, ok
    integer :: fieldCount, n, ncid, varid, ios
    integer :: nx_local, ny_local, nx_global, ny_global
    integer :: yy, mm, dd, hh, mn, ss
    character(len=256)  :: fname, dpath
    character(len=20)   :: tstamp
    character(len=64),  allocatable :: fieldNameList(:)

    rc = ESMF_SUCCESS
    if (.not. is%diag%write_import) return
    if (is%par%comm == -1) then
      call log_warning(COMP_MED, ROUTINE//': MPI comm nao inicializado')
      return
    end if

    ! Montar timestamp
    call ESMF_TimeGet(currTime, yy=yy, mm=mm, dd=dd, h=hh, m=mn, s=ss, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    write(tstamp,'(I4.4,I2.2,I2.2,A1,I2.2,I2.2,I2.2)') yy,mm,dd,'_',hh,mn,ss

    dpath = trim(is%diag%import_dir)
    call execute_command_line('mkdir -p '//trim(dpath), wait=.true.)
    fname = trim(dpath)//'/mom6_import_'//trim(tstamp)//'.nc'

    ! Enumerar campos
    call ESMF_StateGet(state, itemCount=fieldCount, rc=rc)
    if (rc /= ESMF_SUCCESS .or. fieldCount == 0) return
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(state, itemNameList=fieldNameList, rc=rc)
    if (rc /= ESMF_SUCCESS) then; deallocate(fieldNameList); return; end if

    call local_field_shape(state, fieldNameList, nx_local, ny_local)
    rc = ESMF_SUCCESS

    if (nx_local == 0 .or. ny_local == 0) then
      call log_warning(COMP_MED, ROUTINE//': dimensoes locais indeterminaveis')
      deallocate(fieldNameList); return
    end if

    ! grade MED regular e conhecida a priori: 360×180
    nx_global = ATM_NX
    ny_global = ATM_NY

    ! PET0: criar arquivo NetCDF, definir variáveis e gravar os eixos
    if (is%par%local_pet == 0) then
      if (.not. nc_create(fname, ncid, subname)) then
        deallocate(fieldNameList); return
      end if
      call define_import_file(ncid, fieldNameList, tstamp, yy, mm, dd, hh, mn, ss, &
                              nx_global, ny_global, is%par%pet_count, ok)
      if (.not. ok) then
        ios = nf90_close(ncid)
        deallocate(fieldNameList)
        call log_warning(COMP_MED, ROUTINE//': erro NetCDF '//trim(fname))
        rc = ESMF_SUCCESS
        return
      end if
    end if

    ! Para cada campo: preencher grid_local, MPI_Allreduce(MAX), PET0 escreve
    allocate(grid_local(nx_global, ny_global))
    allocate(grid_global(nx_global, ny_global))
    allocate(mask_global(nx_global, ny_global))

    call gather_ocean_mask(is, nx_global, ny_global, mask_global, mask_ok)
    rc = ESMF_SUCCESS

    do n = 1, fieldCount
      ! ler dos campos ATM internos (grade 360×180 global)
      call internal_field_ptr(is, fieldNameList(n), fptr2d, rc)
      if (rc /= ESMF_SUCCESS .or. .not. associated(fptr2d)) then
        rc = ESMF_SUCCESS; cycle
      end if

      call gather_field_global(fptr2d, nx_global, ny_global, is%par%comm, &
                               grid_local, grid_global)

      ! guardar NaN/Inf antes de escrever como NF90_FLOAT
      where (.not. ieee_is_finite(grid_global))
        grid_global = FILL_VALUE_R8
      end where

      ! continentes saem como _FillValue. A própria
      ! máscara é a exceção óbvia; máscara-la apagaria a informação de
      ! onde a terra fica, que é o único conteúdo dela.
      if (mask_ok .and. trim(fieldNameList(n)) /= 'Sx_omask') then
        where (mask_global < 0.5_ESMF_KIND_R8) grid_global = FILL_VALUE_R8
      end if

      if (is%par%local_pet == 0) then
        ios = nf90_inq_varid(ncid, trim(fieldNameList(n)), varid)
        if (ios == NF90_NOERR) ios = nf90_put_var(ncid, varid, real(grid_global, 4))
      end if
      rc = ESMF_SUCCESS
    end do  ! campos

    deallocate(grid_local, grid_global, fieldNameList)
    deallocate(mask_global)

    if (is%par%local_pet == 0) then
      ios = nf90_close(ncid)
      call log_info(COMP_MED, ROUTINE//': escrito '//trim(fname))
    end if
  end subroutine med_write_import_fields

  !> @brief Dimensões locais do primeiro campo 2D do estado.
  !!
  !! Percorre os itens do estado e para no primeiro campo de posto 2 cujo
  !! ponteiro de dados este PET consegue obter. Devolve 0 nas duas dimensões
  !! quando nenhum campo serve (por exemplo, PET sem DE local).
  !!
  !! @param[inout] state          estado a percorrer
  !! @param[in]    fieldNameList  nomes dos itens do estado
  !! @param[out]   nx_local       tamanho local na primeira dimensão
  !! @param[out]   ny_local       tamanho local na segunda dimensão
  subroutine local_field_shape(state, fieldNameList, nx_local, ny_local)
    type(ESMF_State),  intent(inout) :: state
    character(len=64), intent(in)    :: fieldNameList(:)
    integer,           intent(out)   :: nx_local, ny_local

    type(ESMF_Field)            :: field
    type(ESMF_StateItem_Flag)   :: itemType
    real(ESMF_KIND_R8), pointer :: fptr2d(:,:)
    integer :: n, fld_rank, rc

    nx_local = 0; ny_local = 0
    nullify(fptr2d)

    do n = 1, size(fieldNameList)
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
      exit
    end do
  end subroutine local_field_shape

  !> @brief Define o arquivo mom6_import (PET 0) e grava os eixos e o tempo.
  !!
  !! Cabeçalho global, eixos lat/lon centrados em células, variável 'time'
  !! e uma variável NF90_FLOAT por campo do estado, com seus metadados.
  !! Sai do modo de definição e grava lat, lon e time.
  !!
  !! @param[in]  ncid           arquivo recém-criado, em modo de definição
  !! @param[in]  fieldNameList  nomes dos campos (uma variável por nome)
  !! @param[in]  tstamp         instante no formato AAAAMMDD_hhmmss
  !! @param[in]  yy,mm,dd,hh,mn,ss  instante corrente
  !! @param[in]  nx_global      número de longitudes
  !! @param[in]  ny_global      número de latitudes
  !! @param[in]  pet_count      número de PETs do mediador (atributo petCount)
  !! @param[out] ok             .false. se a definição dos eixos ou o enddef falhou
  subroutine define_import_file(ncid, fieldNameList, tstamp, yy, mm, dd, hh, mn, ss, &
                                nx_global, ny_global, pet_count, ok)
    integer,           intent(in)  :: ncid
    character(len=64), allocatable, intent(in) :: fieldNameList(:)
    character(len=*),  intent(in)  :: tstamp
    integer,           intent(in)  :: yy, mm, dd, hh, mn, ss
    integer,           intent(in)  :: nx_global, ny_global
    integer,           intent(in)  :: pet_count
    logical,           intent(out) :: ok

    ! _FillValue NC_FLOAT deve ser real(4); tipo deve bater com NF90_FLOAT.
    real(4), parameter :: FILL_IMP4 = -9.99e+20_4
    real(ESMF_KIND_R8), allocatable :: lat_global(:), lon_global(:)
    character(len=19) :: iso_time
    integer :: n, ios, varid
    integer :: dimid_lat, dimid_lon
    integer :: varid_lat, varid_lon, varid_t

    ok = .false.

    call nc_global_header(ncid, &
      title='MED exportState (= MOM6 importState) — Fluxos MONAN-A x MOM6', &
      institution='INPE/CGCT/DIMNT', &
      source='med_cap_netcdf.F90::med_write_import_fields v1.0 (migrado de MED_cap_MONAN)')
    write(iso_time,'(I4.4,A,I2.2,A,I2.2,A,I2.2,A,I2.2,A,I2.2)') &
      yy,'-',mm,'-',dd,'T',hh,':',mn,':',ss
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'valid_time', trim(iso_time))
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'land_mask_source', &
      'MOM6 ocean_grid%mask2dT (So_omask, regridada para a grade ATM); '// &
      'celulas de terra gravadas como _FillValue; a mascara vai na '// &
      'variavel Sx_omask (1=oceano, 0=terra)')
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'nx_global', nx_global)
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'ny_global', ny_global)
    ios = nf90_put_att(ncid, NF90_GLOBAL, 'petCount',  pet_count)

    if (.not. nc_def_latlon(ncid, nx_global, ny_global, dimid_lon, dimid_lat, &
                            varid_lon, varid_lat, subname)) return

    ios = nf90_def_var(ncid, 'time', NF90_DOUBLE, varid_t)
    ios = nf90_put_att(ncid, varid_t, 'units', &
      'hours since '//tstamp(1:4)//'-'//tstamp(5:6)//'-'//tstamp(7:8)//' 00:00:00')
    ios = nf90_put_att(ncid, varid_t, 'calendar', 'gregorian')

    do n = 1, size(fieldNameList)
      ! NF90_FLOAT em vez de NF90_DOUBLE
      if (nc_def_field2d(ncid, fieldNameList(n), dimid_lon, dimid_lat, varid, subname, &
                         fill_r4=FILL_IMP4, missing=.true.)) &
        call put_field_metadata(fieldNameList, n, ios, ncid, varid)
    end do

    ios = nf90_enddef(ncid)
    if (ios /= NF90_NOERR) return

    ! Coordenadas uniformes: centros de célula
    ! lat(k) = (k-0.5)*dy - 90, dy=180/ny_global
    allocate(lat_global(ny_global), lon_global(nx_global))
    do n = 1, ny_global
      lat_global(n) = -90.0_ESMF_KIND_R8 + (n - 0.5_ESMF_KIND_R8) * &
                      180.0_ESMF_KIND_R8 / real(ny_global, ESMF_KIND_R8)
    end do
    ! lon_k = (k-0.5)*dx, dx=360/nx_global
    do n = 1, nx_global
      lon_global(n) = (n - 0.5_ESMF_KIND_R8) * 360.0_ESMF_KIND_R8 / real(nx_global, ESMF_KIND_R8)
    end do
    ios = nf90_put_var(ncid, varid_lat, lat_global)
    ios = nf90_put_var(ncid, varid_lon, lon_global)
    ios = nf90_put_var(ncid, varid_t, real(hh,ESMF_KIND_R8) + real(mn,ESMF_KIND_R8)/60.0_ESMF_KIND_R8)
    deallocate(lat_global, lon_global)
    ok = .true.
  end subroutine define_import_file

  !> @brief Monta em todos os PETs a máscara terra/oceano global do MOM6.
  !!
  !! A máscara real do MOM6 é montada uma vez por arquivo, pelo mesmo caminho
  !! de reunião usado nos campos.
  !!
  !! Sem ela o continente sairia do diagnóstico como zero (os fluxos são
  !! zerados sobre terra antes da exportação). Zero é um valor físico
  !! legítimo de fluxo: o GrADS e o pós-processamento não teriam como
  !! distinguir "fluxo nulo sobre oceano calmo" de "aqui não há oceano".
  !! Com a máscara, a célula de terra sai como _FillValue, que é exatamente
  !! o que o mask2dT do MOM6 afirma sobre ela.
  !!
  !! MPI_MAX sobre 0/1 é inequívoco (ao contrário do MAX sobre FILL_IMP
  !! usado nos campos): PET que não possui a célula contribui com 0, o PET
  !! dono contribui com o valor real. Terra continua 0, oceano vira 1.
  !!
  !! IMPORTANTE: a máscara é aplicada no buffer LOCAL do escritor. O
  !! exportState permanece com os zeros sobre terra; se -9,99e20 vazasse
  !! para lá, viraria forçante do MOM6.
  !!
  !! @param[in]  is           estado interno do mediador (campo is%ocn%omask)
  !! @param[in]  nx_global    número de longitudes da grade de saída
  !! @param[in]  ny_global    número de latitudes da grade de saída
  !! @param[out] mask_global  máscara global (1=oceano, 0=terra)
  !! @param[out] mask_ok      .true. se a máscara tem ao menos uma célula de oceano
  subroutine gather_ocean_mask(is, nx_global, ny_global, mask_global, mask_ok)
    type(MED_InternalState), intent(in)  :: is
    integer,                 intent(in)  :: nx_global, ny_global
    real(ESMF_KIND_R8),      intent(out) :: mask_global(nx_global, ny_global)
    logical,                 intent(out) :: mask_ok

    real(ESMF_KIND_R8), allocatable :: mask_local(:,:)
    real(ESMF_KIND_R8), pointer     :: pmask2d(:,:)
    integer :: ldec_mask, rc_mask, mpi_ierr
    integer :: i1m, i2m, j1m, j2m, n_ocn_g
    character(len=160) :: logmsg_mask

    allocate(mask_local(nx_global, ny_global))
    mask_local = 0.0_ESMF_KIND_R8
    mask_ok    = .false.
    nullify(pmask2d)
    ! ESMF_FieldGet(farrayPtr) falha em PET sem DE local. Verificar
    ! antes de acessar, como já é feito no resto do mediador; senão o
    ! ERROR do ESMF poluiria o log a cada passo nesses PETs.
    ldec_mask = 0
    call ESMF_FieldGet(is%ocn%omask, localDeCount=ldec_mask, rc=rc_mask)
    if (rc_mask == ESMF_SUCCESS .and. ldec_mask > 0) then
      call ESMF_FieldGet(is%ocn%omask, farrayPtr=pmask2d, rc=rc_mask)
      if (rc_mask /= ESMF_SUCCESS) nullify(pmask2d)
    end if
    if (associated(pmask2d)) then
      i1m = max(1, lbound(pmask2d,1));  i2m = min(nx_global, ubound(pmask2d,1))
      j1m = max(1, lbound(pmask2d,2));  j2m = min(ny_global, ubound(pmask2d,2))
      if (i2m >= i1m .and. j2m >= j1m) &
        mask_local(i1m:i2m, j1m:j2m) = pmask2d(i1m:i2m, j1m:j2m)
    end if

    call MPI_Allreduce(mask_local, mask_global, nx_global*ny_global, &
                       MPI_DOUBLE_PRECISION, MPI_MAX, is%par%comm, mpi_ierr)
    deallocate(mask_local)

    ! mask_ok é decidido DEPOIS do gather, e não por PET: um PET sem DE
    ! local não ve máscara nenhuma, mas isso não significa que ela faltou.
    ! Máscara toda zerada = não chegou de lugar nenhum -> não mascarar:
    ! na dúvida, não apagar dado.
    mask_ok = any(mask_global >= 0.5_ESMF_KIND_R8)

    if (is%par%local_pet == 0) then
      if (mask_ok) then
        n_ocn_g = count(mask_global >= 0.5_ESMF_KIND_R8)
        write(logmsg_mask,'(A,F5.1,A,I0,A,I0,A)') &
          'mascara do diagnostico: oceano ', &
          100.0*real(n_ocn_g)/real(nx_global*ny_global), '% (', n_ocn_g, &
          ' de ', nx_global*ny_global, ' celulas)'
        call log_debug(COMP_MED, trim(logmsg_mask))
      else
        call log_warning(COMP_MED, ROUTINE//': mascara So_omask vazia ou '// &
          'indisponivel; continentes nao serao mascarados neste arquivo')
      end if
    end if
  end subroutine gather_ocean_mask

  !> @brief Ponteiro para o campo interno (grade ATM 360×180) de um nome do estado,
  !! procurado no registro de campos internos (is%fields).
  !!
  !! Um campo do exportState fora do registro viraria variável vazia no
  !! arquivo, sem nenhum sinal; por isso esse caso registra um aviso, para
  !! que a próxima lacuna apareça no log em vez de só aparecer no GrADS.
  !!
  !! @param[in]  is      estado interno do mediador
  !! @param[in]  name    nome do campo no exportState
  !! @param[out] fptr2d  ponteiro para os dados locais; nulo se fora do registro
  !! @param[out] rc      código de retorno do ESMF_FieldGet
  subroutine internal_field_ptr(is, name, fptr2d, rc)
    type(MED_InternalState),     intent(in)  :: is
    character(len=*),            intent(in)  :: name
    real(ESMF_KIND_R8), pointer, intent(out) :: fptr2d(:,:)
    integer,                     intent(out) :: rc
    integer :: k

    nullify(fptr2d)
    k = med_field_index(is, name)
    if (k > 0) then
      call ESMF_FieldGet(is%fields(k)%field, farrayPtr=fptr2d, rc=rc)
    else
      call log_warning(COMP_MED, ROUTINE//': campo "'// &
        trim(name)//'" fora dos campos internos do mediador (MED_FIELDS); '// &
        'a variavel sera gravada apenas com _FillValue')
      nullify(fptr2d)
      rc = ESMF_SUCCESS
    end if
  end subroutine internal_field_ptr

  !> @brief Reúne em todos os PETs um campo da grade ATM 360×180.
  !!
  !! Cada PET copia a sua fatia para um buffer global preenchido com
  !! FILL_VALUE_R8 (a grade ATM é a própria grade de saída: mapeamento 1:1),
  !! e o MPI_Allreduce(MAX) combina os subdomínios, descartando o valor de
  !! preenchimento (−9,99e20).
  !!
  !! @param[in]  fptr2d       dados locais do campo
  !! @param[in]  nx_global    número de longitudes
  !! @param[in]  ny_global    número de latitudes
  !! @param[in]  comm         comunicador MPI do mediador
  !! @param[out] grid_local   buffer de trabalho (fatia local + preenchimento)
  !! @param[out] grid_global  campo global combinado
  subroutine gather_field_global(fptr2d, nx_global, ny_global, comm, grid_local, grid_global)
    real(ESMF_KIND_R8), pointer, intent(in) :: fptr2d(:,:)
    integer,            intent(in)  :: nx_global, ny_global
    integer,            intent(in)  :: comm
    real(ESMF_KIND_R8), intent(out) :: grid_local(nx_global, ny_global)
    real(ESMF_KIND_R8), intent(out) :: grid_global(nx_global, ny_global)

    integer :: i1a, i2a, j1a, j2a, mpi_ierr

    grid_local = FILL_VALUE_R8

    ! Scatter direto: grade ATM 360×180 = grade de saída → mapeamento 1:1
    i1a = max(1, lbound(fptr2d,1));  i2a = min(nx_global, ubound(fptr2d,1))
    j1a = max(1, lbound(fptr2d,2));  j2a = min(ny_global, ubound(fptr2d,2))
    if (i2a >= i1a .and. j2a >= j1a) &
      grid_local(i1a:i2a, j1a:j2a) = fptr2d(i1a:i2a, j1a:j2a)

    ! MPI_Allreduce(MAX): combina subdomínios; descarta fill_val (−9.99e20)
    call MPI_Allreduce(grid_local, grid_global, nx_global*ny_global, &
                       MPI_DOUBLE_PRECISION, MPI_MAX, comm, mpi_ierr)
  end subroutine gather_field_global

  !> @brief Grava os atributos units, long_name e standard_name da variável
  !! de um campo, pelo dicionário de campos (cpl_field_attributes).
  !! @param[in]    fieldNameList  nomes dos campos
  !! @param[in]    n              índice do campo
  !! @param[inout] ios            código da última chamada do NetCDF
  !! @param[in]    ncid           arquivo aberto
  !! @param[in]    varid          variável do campo
  subroutine put_field_metadata(fieldNameList, n, ios, ncid, varid)
    integer, intent(in) :: n
    integer, intent(inout) :: ios
    integer, intent(in) :: ncid
    integer, intent(in) :: varid
    character(len=64), allocatable, intent(in) :: fieldNameList(:)
    character(len=32) :: f_units
    character(len=80) :: f_long, f_std
    call cpl_field_attributes(fieldNameList(n), f_units, f_long, f_std)
    ios = nf90_put_att(ncid, varid, 'units',         trim(f_units))
    ios = nf90_put_att(ncid, varid, 'long_name',     trim(f_long))
    ios = nf90_put_att(ncid, varid, 'standard_name', trim(f_std))
  end subroutine put_field_metadata

end module med_cap_netcdf_mod
