!> @file docn_cap_netcdf.F90
!! @brief I/O NetCDF do componente de dados oceânicos DOCN.
!!
!! Rotinas de leitura e escrita NetCDF do oceano de dados (OISST):
!!   ReadGlobalField      lê um instante global de um arquivo NetCDF (PET 0)
!!   ReadOcnFieldInterp   interpola no tempo entre dois instantes e distribui
!!   WriteDOCNDiag        grava o diagnóstico docn_import_AAAAMMDD_HHMMSS.nc
!!
!! Usado por DOCN_cap.F90 e, para a fração de gelo lida de arquivo, por
!! mom_cap_MONAN.F90. INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module docn_cap_netcdf_mod

  use ESMF
  use ESMF, only: ESMF_GridComp
  use ESMF, only: ESMF_Clock, ESMF_ClockGet
  use ESMF, only: ESMF_Time, ESMF_TimeGet, ESMF_TimeSet
  use ESMF, only: ESMF_TimeInterval, ESMF_TimeIntervalSet, ESMF_TimeIntervalGet
  use ESMF, only: ESMF_KIND_R8, ESMF_KIND_I8
  use ESMF, only: ESMF_SUCCESS, ESMF_FAILURE, ESMF_LOGERR_PASSTHRU
  use ESMF, only: ESMF_LogFoundError
  use ESMF, only: ESMF_VM, ESMF_VMGetGlobal, ESMF_VMGetCurrent, ESMF_VMGet, ESMF_VMBroadcast, ESMF_GridCompGet
  use ESMF, only: ESMF_CALKIND_GREGORIAN

  use netcdf
  use nc_writer_mod, only : nc_create, nc_global_header, nc_def_latlon, nc_def_field2d
  use mpi
  use coupler_constants_mod, only: T0_KELVIN
  use coupler_utils_mod, only: ChkErr, int_to_str, real_to_str
  use coupler_log_mod, only: COMP_DOCN, log_error, log_warning, log_info, log_debug

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

  public :: ReadGlobalField     !< lê snapshot global NetCDF (somente PET0)
  public :: ReadOcnFieldInterp  !< interpola temporalmente e distribui via broadcast
  public :: WriteDOCNDiag       !< escrita diagnóstica docn_import_YYYYMMDD_HHMMSS.nc

contains

  !> @brief Lê um snapshot NetCDF global (chamado apenas em PET0).
  !!
  !! Abre o arquivo, localiza a variável e lê um único snapshot (tidx).
  !! Verifica compatibilidade da ordem de eixos (lon, lat, time).
  !!
  !! @param[in]  filename  Caminho do arquivo NetCDF
  !! @param[in]  varname   Nome da variável a ler
  !! @param[in]  tidx      Índice de tempo (1-based)
  !! @param[in]  nx, ny    Dimensões horizontais esperadas
  !! @param[out] array     Array de saída (nx, ny)
  !! @param[out] rc        Código de retorno ESMF
  subroutine ReadGlobalField(filename, varname, tidx, nx, ny, array, rc)
    character(len=*),    intent(in)  :: filename
    character(len=*),    intent(in)  :: varname
    integer,             intent(in)  :: tidx
    integer,             intent(in)  :: nx, ny
    real(ESMF_KIND_R8),  intent(out) :: array(nx,ny)
    integer,             intent(out) :: rc

    integer :: ncid, varid, start(3), count_arr(3), nc_rc
      integer :: ndims_var
      integer :: dimids(4)
      integer :: dim1_size
      integer :: nc_rc_dim
      character(len=64) :: dim1_name

    rc    = ESMF_SUCCESS
    nc_rc = nf90_open(filename, NF90_NOWRITE, ncid)
    if (nc_rc /= NF90_NOERR) then
      call log_error(COMP_DOCN, "ReadGlobalField: falha ao abrir " &
        //trim(filename)//": "//trim(nf90_strerror(nc_rc)))
      rc = ESMF_FAILURE; return
    end if

    nc_rc = nf90_inq_varid(ncid, varname, varid)
    if (nc_rc /= NF90_NOERR) then
      call log_error(COMP_DOCN, "ReadGlobalField: variavel nao encontrada: " &
        //trim(varname))
      rc = ESMF_FAILURE; nc_rc = nf90_close(ncid); return
    end if

    ! verificar ordem dos eixos do arquivo NetCDF.
    ! DOCN espera (lon, lat, time) em ordem Fortran = (time, lat, lon) em C/NetCDF.
    ! Se dim1_size /= nx, os eixos estão incompatíveis — abortar com mensagem clara.
      nc_rc_dim = nf90_inquire_variable(ncid, varid, ndims=ndims_var, dimids=dimids)
      if (nc_rc_dim == NF90_NOERR .and. ndims_var >= 2) then
        nc_rc_dim = nf90_inquire_dimension(ncid, dimids(1), name=dim1_name, len=dim1_size)
        if (nc_rc_dim == NF90_NOERR .and. dim1_size /= nx) then
          call log_error(COMP_DOCN, &
            "ReadGlobalField: ordem de eixos incompativel. "// &
            "Arquivo "//trim(filename)//" tem dim1='"//trim(dim1_name)// &
            "' com tamanho "//int_to_str(dim1_size)// &
            " mas DOCN espera nx="//int_to_str(nx)//". "// &
            "Execute prepare_cur_file.sh para transpor: "// &
            "ncpdq -a time,latitude,longitude arquivo.nc arquivo_corrigido.nc")
          rc = ESMF_FAILURE
          nc_rc = nf90_close(ncid)
          return
        end if
      end if

    start     = [1, 1, tidx]
    count_arr = [nx, ny, 1]
    nc_rc     = nf90_get_var(ncid, varid, array, start=start, count=count_arr)
    if (nc_rc /= NF90_NOERR) then
      call log_error(COMP_DOCN, "ReadGlobalField: falha ao ler " &
        //trim(varname)//": "//trim(nf90_strerror(nc_rc)))
      rc = ESMF_FAILURE; nc_rc = nf90_close(ncid); return
    end if

    nc_rc = nf90_close(ncid)


  end subroutine ReadGlobalField

  !> @brief Interpolação temporal linear entre snapshots diários.
  !!
  !! Idêntica em estrutura a ReadJRAFieldInterp do DATM_cap.F90.
  !! Estratégia paralela: PET0 lê campo global via ReadGlobalField e distribui
  !! via ESMF_VMBroadcast. Cada PET copia o seu subdomínio local. Antes dos
  !! dados, o PET 0 distribui a situação da leitura: se ela falhou, todos os
  !! PETs retornam com rc = ESMF_FAILURE.
  !!
  !! Parâmetros de epoch e dt_data configurados em &nuopc_docn:
  !!   docn_epoch_year, docn_epoch_month, docn_epoch_day
  !!   docn_dt_data  (segundos entre snapshots; 86400 para diário)
  !!
  !! @param[in]  gcomp     Componente ESMF (para obter VM)
  !! @param[in]  filename  Arquivo NetCDF de entrada
  !! @param[in]  varname   Nome da variável
  !! @param[in]  currTime  Tempo corrente da simulação
  !! @param[in]  nx, ny    Dimensões da grade global
  !! @param[out] array     Campo interpolado no subdomínio local (pointer)
  !! @param[out] rc        Código de retorno ESMF
  subroutine ReadOcnFieldInterp(gcomp, filename, varname, currTime, &
                                 nx, ny, array, rc)
    type(ESMF_GridComp),  intent(in)    :: gcomp
    character(len=*),     intent(in)    :: filename
    character(len=*),     intent(in)    :: varname
    type(ESMF_Time),      intent(in)    :: currTime
    integer,              intent(in)    :: nx, ny
    real(ESMF_KIND_R8),   pointer       :: array(:,:)
    integer,              intent(out)   :: rc

    type(ESMF_VM)           :: vm
    type(ESMF_Time)         :: epochTime
    type(ESMF_TimeInterval) :: dt_since_epoch
    integer(ESMF_KIND_I8)   :: sec_since_epoch
    integer                 :: tidx0, tidx1
    integer                 :: ntime, ncid_nt, dimid_nt, nc_rc_nt
    real(ESMF_KIND_R8)      :: alpha
    integer(ESMF_KIND_I8)   :: dt_data_i8
    real(ESMF_KIND_R8)      :: f0_data(nx,ny), f1_data(nx,ny)
    real(ESMF_KIND_R8), allocatable :: buf_global(:)
    integer :: i1, i2, j1, j2, i, j, localPet
    integer :: read_status(1)          ! 0: o PET 0 leu os dois instantes
    character(len=256) :: msg

    rc      = ESMF_SUCCESS
    dt_data_i8 = int(cfg_docn_dt_data, ESMF_KIND_I8)

    allocate(buf_global(nx*ny))

    ! Usa a VM do COMPONENTE, não a global. ESMF_VMGetGlobal retornaria
    ! todos os PETs, e o ESMF_VMBroadcast abaixo é coletivo sobre a VM com
    ! rootPet=0. Em concurrent o OCN roda só nos seus PETs: apenas eles
    ! chamariam o broadcast, enquanto os PETs do ATM (incluindo o PET0
    ! global, a raiz) nunca entram nesta rotina → deadlock.
    ! ESMF_GridCompGet(gcomp,vm) dá a VM do componente (localPet e rootPet=0
    ! locais ao componente). Em sequential a VM do componente tem todos os
    ! PETs, e o comportamento é o mesmo da VM global.
    call ESMF_GridCompGet(gcomp, vm=vm, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    f0_data = 0.0_ESMF_KIND_R8
    f1_data = 0.0_ESMF_KIND_R8

    ! Calcular índices de tempo e fator de interpolação
    call ESMF_TimeSet(epochTime, yy=cfg_docn_epoch_year, &
      mm=cfg_docn_epoch_month, dd=cfg_docn_epoch_day, &
      calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    dt_since_epoch = currTime - epochTime
    call ESMF_TimeIntervalGet(dt_since_epoch, s_i8=sec_since_epoch, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (sec_since_epoch < 0_ESMF_KIND_I8) then
      if (localPet == 0) call log_error(COMP_DOCN, 'ReadOcnFieldInterp: data ' // &
        'corrente anterior ao epoch do arquivo oceanico (docn_epoch_*)')
      rc = ESMF_FAILURE
      return
    end if

    ! ler ntime do arquivo para clampar índice (evita out-of-bounds)
    ntime = huge(ntime)
    nc_rc_nt = nf90_open(filename, NF90_NOWRITE, ncid_nt)
    if (nc_rc_nt == NF90_NOERR) then
      nc_rc_nt = nf90_inq_dimid(ncid_nt, 'time', dimid_nt)
      if (nc_rc_nt /= NF90_NOERR) &
        nc_rc_nt = nf90_inq_dimid(ncid_nt, 'Time', dimid_nt)
      if (nc_rc_nt /= NF90_NOERR) &
        nc_rc_nt = nf90_inq_dimid(ncid_nt, 'TIME', dimid_nt)
      if (nc_rc_nt == NF90_NOERR) then
        nc_rc_nt = nf90_inquire_dimension(ncid_nt, dimid_nt, len=ntime)
      else
        ntime = huge(ntime)   ! dim não encontrada: sem clamping
      end if
      nc_rc_nt = nf90_close(ncid_nt)
    else
      ntime = huge(ntime)     ! arquivo não abriu: ReadGlobalField reportará
    end if
    tidx0 = mod(int(sec_since_epoch / real(dt_data_i8, ESMF_KIND_R8)), ntime) + 1
    tidx1 = mod(tidx0, ntime) + 1   ! ciclo: último registro volta ao 1
    alpha = real(mod(sec_since_epoch, dt_data_i8), ESMF_KIND_R8) / &
            real(dt_data_i8, ESMF_KIND_R8)
    alpha = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, alpha))

    ! PET0 lê os dois snapshots e interpola
    read_status = 0
    if (localPet == 0) then
      call ReadGlobalField(filename, varname, tidx0, nx, ny, f0_data, rc)
      if (rc == ESMF_SUCCESS) call ReadGlobalField(filename, varname, tidx1, nx, ny, f1_data, rc)
      if (rc == ESMF_SUCCESS) then
        ! Interpolação temporal linear in-place
        f0_data = f0_data + alpha * (f1_data - f0_data)
        buf_global = reshape(f0_data, [nx*ny])
      else
        read_status = 1
      end if
    end if

    ! O PET 0 distribui primeiro a situação da leitura. Se ela falhou, todos
    ! os PETs retornam com erro; sem isso, os demais esperariam no broadcast
    ! dos dados, que o PET 0 nunca faria, até o fim do tempo da fila.
    call ESMF_VMBroadcast(vm, bcstData=read_status, count=1, rootPet=0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (read_status(1) /= 0) then
      call log_warning(COMP_DOCN, 'ReadOcnFieldInterp: o PET 0 nao conseguiu ler ' // &
        trim(varname) // ' de ' // trim(filename))
      rc = ESMF_FAILURE
      return
    end if

    ! Broadcast do campo global interpolado para todos os PETs
    call ESMF_VMBroadcast(vm, bcstData=buf_global, count=nx*ny, rootPet=0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Cada PET copia o seu subdomínio local
    i1 = lbound(array,1); i2 = ubound(array,1)
    j1 = lbound(array,2); j2 = ubound(array,2)
    do j = j1, j2
      do i = i1, i2
        array(i,j) = buf_global((j-1)*nx + i)
      end do
    end do

    deallocate(buf_global)

    ! Formato: 5 strings antes do primeiro I5.
    write(msg,'(A,A,A,A,A,I5,A,I5,A,F6.4)') &
      'interp ', trim(varname), ' [', trim(filename), &
      '] tidx0=', tidx0, ' tidx1=', tidx1, ' alpha=', alpha
    call log_debug(COMP_DOCN, trim(msg))

  end subroutine ReadOcnFieldInterp

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

    ! Sincronizar — todos os PETs chegam aqui antes da escrita do PET0
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
