!> @file docn_cap_netcdf.F90
!! @brief I/O NetCDF do componente de dados oceânicos DOCN.
!!
!! Versão 1.0 (Mai/2026) — GT Acoplamento de Modelos / INPE/CGCT/DIMNT
!!
!! Contém as sub-rotinas de leitura e escrita NetCDF extraídas de DOCN_cap.F90
!! como parte da reorganização de responsabilidades (Passo 7):
!!
!!   ReadGlobalField      — lê um snapshot global de um arquivo NetCDF (PET0)
!!   ReadOcnFieldInterp   — interpolação temporal linear entre snapshots (PET0+bcast)
!!   WriteDOCNDiag        — escrita diagnóstica dos campos OCN por passo de acoplamento
!!
!! Dependências: ESMF, NetCDF, MPI, mpas_cap_config_mod.
!! DOCN_cap.F90 passa a importar as três rotinas via use deste módulo.

module docn_cap_netcdf_mod

  use ESMF
  use ESMF, only: ESMF_GridComp
  use ESMF, only: ESMF_Clock, ESMF_ClockGet
  use ESMF, only: ESMF_Time, ESMF_TimeGet, ESMF_TimeSet
  use ESMF, only: ESMF_TimeInterval, ESMF_TimeIntervalSet, ESMF_TimeIntervalGet
  use ESMF, only: ESMF_KIND_R8, ESMF_KIND_I8
  use ESMF, only: ESMF_SUCCESS, ESMF_FAILURE, ESMF_LOGERR_PASSTHRU
  use ESMF, only: ESMF_LogFoundError, ESMF_LogWrite, ESMF_LOGMSG_INFO, ESMF_LOGMSG_WARNING, ESMF_LOGMSG_ERROR
  use ESMF, only: ESMF_VM, ESMF_VMGetGlobal, ESMF_VMGetCurrent, ESMF_VMGet, ESMF_VMBroadcast
  use ESMF, only: ESMF_CALKIND_GREGORIAN

  use netcdf
  use mpi

  use mpas_cap_config_mod, only: cfg_docn_mode,           &
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

  !=============================================================================
  !> @brief Lê um snapshot NetCDF global (chamado apenas em PET0).
  !!
  !! Abre o arquivo, localiza a variável e lê um único snapshot (tidx).
  !! Verifica B-59: compatibilidade da ordem de eixos (lon, lat, time).
  !!
  !! @param[in]  filename  Caminho do arquivo NetCDF
  !! @param[in]  varname   Nome da variável a ler
  !! @param[in]  tidx      Índice de tempo (1-based)
  !! @param[in]  nx, ny    Dimensões horizontais esperadas
  !! @param[out] array     Array de saída (nx, ny)
  !! @param[out] rc        Código de retorno ESMF
  !=============================================================================
  subroutine ReadGlobalField(filename, varname, tidx, nx, ny, array, rc)
    character(len=*),    intent(in)  :: filename
    character(len=*),    intent(in)  :: varname
    integer,             intent(in)  :: tidx
    integer,             intent(in)  :: nx, ny
    real(ESMF_KIND_R8),  intent(out) :: array(nx,ny)
    integer,             intent(out) :: rc

    integer :: ncid, varid, start(3), count_arr(3), nc_rc

    rc    = ESMF_SUCCESS
    nc_rc = nf90_open(filename, NF90_NOWRITE, ncid)
    if (nc_rc /= NF90_NOERR) then
      call ESMF_LogWrite("ReadGlobalField DOCN: falha ao abrir " &
        //trim(filename)//": "//trim(nf90_strerror(nc_rc)), ESMF_LOGMSG_INFO)
      rc = ESMF_FAILURE; return
    end if

    nc_rc = nf90_inq_varid(ncid, varname, varid)
    if (nc_rc /= NF90_NOERR) then
      call ESMF_LogWrite("ReadGlobalField DOCN: variavel nao encontrada: " &
        //trim(varname), ESMF_LOGMSG_INFO)
      rc = ESMF_FAILURE; nc_rc = nf90_close(ncid); return
    end if

    ! B-59: verificar ordem dos eixos do arquivo NetCDF.
    ! DOCN espera (lon, lat, time) em ordem Fortran = (time, lat, lon) em C/NetCDF.
    ! Se dim1_size /= nx, os eixos estão incompatíveis — abortar com mensagem clara.
    block
      integer :: ndims_var, dimids(4), dim1_size, nc_rc_dim
      character(len=64) :: dim1_name
      nc_rc_dim = nf90_inquire_variable(ncid, varid, ndims=ndims_var, dimids=dimids)
      if (nc_rc_dim == NF90_NOERR .and. ndims_var >= 2) then
        nc_rc_dim = nf90_inquire_dimension(ncid, dimids(1), name=dim1_name, len=dim1_size)
        if (nc_rc_dim == NF90_NOERR .and. dim1_size /= nx) then
          call ESMF_LogWrite( &
            "ReadGlobalField DOCN: ERRO B-59 — ordem de eixos incompativel! "// &
            "Arquivo "//trim(filename)//" tem dim1='"//trim(dim1_name)// &
            "' com tamanho "//trim(adjustl(int2str_rg(dim1_size)))// &
            " mas DOCN espera nx="//trim(adjustl(int2str_rg(nx)))//". "// &
            "Execute prepare_cur_file.sh para transpor: "// &
            "ncpdq -a time,latitude,longitude arquivo.nc arquivo_corrigido.nc", &
            ESMF_LOGMSG_ERROR)
          rc = ESMF_FAILURE
          nc_rc = nf90_close(ncid)
          return
        end if
      end if
    end block

    start     = [1, 1, tidx]
    count_arr = [nx, ny, 1]
    nc_rc     = nf90_get_var(ncid, varid, array, start=start, count=count_arr)
    if (nc_rc /= NF90_NOERR) then
      call ESMF_LogWrite("ReadGlobalField DOCN: falha ao ler " &
        //trim(varname)//": "//trim(nf90_strerror(nc_rc)), ESMF_LOGMSG_INFO)
      rc = ESMF_FAILURE; nc_rc = nf90_close(ncid); return
    end if

    nc_rc = nf90_close(ncid)

  contains
    function int2str_rg(n) result(s)
      integer, intent(in) :: n
      character(len=12) :: s
      write(s,'(I12)') n
    end function int2str_rg

  end subroutine ReadGlobalField

  !=============================================================================
  !> @brief Interpolação temporal linear entre snapshots diários.
  !!
  !! Idêntica em estrutura a ReadJRAFieldInterp do DATM_cap.F90.
  !! Estratégia paralela: PET0 lê campo global via ReadGlobalField e distribui
  !! via ESMF_VMBroadcast. Cada PET copia o seu subdomínio local.
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
  !=============================================================================
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
    character(len=256) :: msg

    rc      = ESMF_SUCCESS
    dt_data_i8 = int(cfg_docn_dt_data, ESMF_KIND_I8)

    allocate(buf_global(nx*ny))

    call ESMF_VMGetGlobal(vm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    f0_data = 0.0_ESMF_KIND_R8
    f1_data = 0.0_ESMF_KIND_R8

    ! Calcular índices de tempo e fator de interpolação
    call ESMF_TimeSet(epochTime, yy=cfg_docn_epoch_year, &
      mm=cfg_docn_epoch_month, dd=cfg_docn_epoch_day, &
      calkindflag=ESMF_CALKIND_GREGORIAN, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    dt_since_epoch = currTime - epochTime
    call ESMF_TimeIntervalGet(dt_since_epoch, s_i8=sec_since_epoch, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! B-54/B-55: ler ntime do arquivo para clampar índice (evita out-of-bounds)
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
    if (localPet == 0) then
      call ReadGlobalField(filename, varname, tidx0, nx, ny, f0_data, rc)
      if (rc /= ESMF_SUCCESS) return
      call ReadGlobalField(filename, varname, tidx1, nx, ny, f1_data, rc)
      if (rc /= ESMF_SUCCESS) return

      ! Interpolação temporal linear in-place
      f0_data = f0_data + alpha * (f1_data - f0_data)
      buf_global = reshape(f0_data, [nx*ny])
    end if

    ! Broadcast do campo global interpolado para todos os PETs
    call ESMF_VMBroadcast(vm, bcstData=buf_global, count=nx*ny, rootPet=0, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Cada PET copia o seu subdomínio local
    i1 = lbound(array,1); i2 = ubound(array,1)
    j1 = lbound(array,2); j2 = ubound(array,2)
    do j = j1, j2
      do i = i1, i2
        array(i,j) = buf_global((j-1)*nx + i)
      end do
    end do

    deallocate(buf_global)

    ! B-55b: formato corrigido — 5 strings antes do primeiro I5
    write(msg,'(A,A,A,A,A,I5,A,I5,A,F6.4)') &
      'DOCN: interp ', trim(varname), ' [', trim(filename), &
      '] tidx0=', tidx0, ' tidx1=', tidx1, ' alpha=', alpha
    call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)

  end subroutine ReadOcnFieldInterp

  !=============================================================================
  !> @brief Escrita diagnóstica dos campos oceânicos por passo de acoplamento.
  !!
  !! Gera docn_import_YYYYMMDD_HHMMSS.nc com SST, gelo e correntes interpolados,
  !! na grade nativa do DOCN (sem reprojeção). Somente PET0 escreve; demais
  !! executam MPI_Barrier e retornam. Validação de SST/gelo vs fonte de dados.
  !!
  !! Ativada por write_import_diag=.true. em &nuopc_docn do nuopc.input.
  !! Lida por: postproc_mom6_import.py
  !!
  !! @param[in]  gcomp     Componente ESMF (para VM e clock)
  !! @param[in]  currTime  Tempo corrente da simulação
  !! @param[in]  nx, ny    Dimensões da grade DOCN
  !! @param[out] rc        Código de retorno ESMF
  !=============================================================================
  subroutine WriteDOCNDiag(gcomp, currTime, nx, ny, rc)
    type(ESMF_GridComp),  intent(in)  :: gcomp
    type(ESMF_Time),      intent(in)  :: currTime
    integer,              intent(in)  :: nx, ny
    integer,              intent(out) :: rc

    type(ESMF_VM)  :: vm
    type(ESMF_Time):: epochTime
    type(ESMF_TimeInterval) :: dt_since_epoch
    integer(ESMF_KIND_I8)   :: sec_since_epoch, dt_data_i8
    integer :: localPet, mpiComm, mpiErr
    integer :: yy, mm, dd, hh, mn, ss
    character(len=256) :: fname, dname
    character(len=19)  :: tstamp
    integer :: ncid_r, ncid_w
    integer :: varid_src, ncstat
    integer :: varid_sst, varid_ice, varid_u, varid_v
    integer :: varid_lat, varid_lon, dimid_lon, dimid_lat
    integer :: ntime, dimid_nt, tidx0, tidx1
    integer :: ntime_i, dimid_nt_i, tidx0_i, tidx1_i
    integer :: ntime_cur, dimid_nt_cur, tidx0_cur, tidx1_cur
    real(ESMF_KIND_R8) :: alpha, alpha_i, fill_val
    integer :: nlon_diag, nlat_diag, i, j
    real(ESMF_KIND_R8), allocatable :: lon_ax(:), lat_ax(:)
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
    write(tstamp,'(I4.4,I2.2,I2.2,A,I2.2,I2.2,I2.2)') yy,mm,dd,'_',hh,mn,ss

    ! ── Calcular tidx0, tidx1, alpha (mesmo algoritmo de ReadOcnFieldInterp) ──
    call ESMF_TimeSet(epochTime, yy=cfg_docn_epoch_year, &
      mm=cfg_docn_epoch_month, dd=cfg_docn_epoch_day, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_since_epoch = currTime - epochTime
    call ESMF_TimeIntervalGet(dt_since_epoch, s_i8=sec_since_epoch, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_data_i8 = int(cfg_docn_dt_data, ESMF_KIND_I8)

    ! ntime da SST
    ncstat = nf90_open(trim(cfg_docn_sst_file), NF90_NOWRITE, ncid_r)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('WriteDOCNDiag: falha ao abrir '// &
        trim(cfg_docn_sst_file)//': '//trim(nf90_strerror(ncstat)), &
        ESMF_LOGMSG_WARNING)
      return
    end if
    ncstat = nf90_inq_dimid(ncid_r, 'time', dimid_nt)
    if (ncstat /= NF90_NOERR) ncstat = nf90_inq_dimid(ncid_r, 'Time', dimid_nt)
    if (ncstat /= NF90_NOERR) ncstat = nf90_inq_dimid(ncid_r, 'TIME', dimid_nt)
    if (ncstat == NF90_NOERR) then
      ncstat = nf90_inquire_dimension(ncid_r, dimid_nt, len=ntime)
    else
      ntime = huge(ntime)
    end if
    tidx0 = mod(int(sec_since_epoch / real(dt_data_i8, ESMF_KIND_R8)), ntime) + 1
    tidx1 = mod(tidx0, ntime) + 1
    alpha = real(mod(sec_since_epoch, dt_data_i8), ESMF_KIND_R8) / real(dt_data_i8, ESMF_KIND_R8)
    alpha = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, alpha))

    ! Ler dois snapshots SST e interpolar
    allocate(f0(nx,ny), f1(nx,ny), fout(nx,ny))
    allocate(uout(nx,ny), vout(nx,ny))
    uout = 0.0_ESMF_KIND_R8; vout = 0.0_ESMF_KIND_R8
    ncstat = nf90_inq_varid(ncid_r, trim(cfg_docn_sst_varname), varid_src)
    if (ncstat == NF90_NOERR) then
      ncstat = nf90_get_var(ncid_r, varid_src, f0, start=[1,1,tidx0], count=[nx,ny,1])
      ncstat = nf90_get_var(ncid_r, varid_src, f1, start=[1,1,tidx1], count=[nx,ny,1])
      fout = (1.0_ESMF_KIND_R8 - alpha)*f0 + alpha*f1
      fout = fout + 273.15_ESMF_KIND_R8   ! conversão °C → K
      where (abs(f0) > 1.0e10_ESMF_KIND_R8 .or. abs(f1) > 1.0e10_ESMF_KIND_R8) &
        fout = fill_val
    else
      fout = fill_val
    end if
    ncstat = nf90_close(ncid_r)

    ! ntime do gelo
    ncstat = nf90_open(trim(cfg_docn_ice_file), NF90_NOWRITE, ncid_r)
    allocate(ice0(nx,ny), ice1(nx,ny), iceout(nx,ny))
    iceout = fill_val
    if (ncstat == NF90_NOERR) then
      ncstat = nf90_inq_dimid(ncid_r, 'time', dimid_nt_i)
      if (ncstat /= NF90_NOERR) ncstat = nf90_inq_dimid(ncid_r, 'Time', dimid_nt_i)
      if (ncstat == NF90_NOERR) then
        ncstat = nf90_inquire_dimension(ncid_r, dimid_nt_i, len=ntime_i)
      else
        ntime_i = ntime
      end if
      tidx0_i = mod(int(sec_since_epoch / real(dt_data_i8, ESMF_KIND_R8)), ntime_i) + 1
      tidx1_i = mod(tidx0_i, ntime_i) + 1
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

    ! ── Correntes superficiais (opcional) ─────────────────────────────────────
    ! B-59b: usar tidx calculado para o cur_file (ntime independente do SST)
    if (len_trim(cfg_docn_cur_file) > 0) then
      ncstat = nf90_open(trim(cfg_docn_cur_file), NF90_NOWRITE, ncid_r)
      if (ncstat == NF90_NOERR) then
        ncstat = nf90_inq_dimid(ncid_r, 'time', dimid_nt_cur)
        if (ncstat /= NF90_NOERR) ncstat = nf90_inq_dimid(ncid_r, 'Time', dimid_nt_cur)
        if (ncstat == NF90_NOERR) then
          ncstat = nf90_inquire_dimension(ncid_r, dimid_nt_cur, len=ntime_cur)
        else
          ntime_cur = 1
        end if
        tidx0_cur = mod(int(sec_since_epoch / real(dt_data_i8, ESMF_KIND_R8)), ntime_cur) + 1
        tidx1_cur = mod(tidx0_cur, ntime_cur) + 1

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

    ! ── Escrever NetCDF de diagnóstico (grade nativa DOCN) ────────────────────
    nlon_diag = nx
    nlat_diag = ny
    dname = trim(cfg_import_diag_dir)
    call execute_command_line('mkdir -p '//trim(dname), wait=.true.)
    fname = trim(dname)//'/docn_import_'//trim(tstamp)//'.nc'

    allocate(lon_ax(nlon_diag), lat_ax(nlat_diag))
    ! Eixo lon nativo OISST: 0° → 359.75°. O postproc_mom6_import.py aplica roll.
    do i = 1, nlon_diag
      lon_ax(i) = real(i-1, ESMF_KIND_R8) * (360.0_ESMF_KIND_R8 / nlon_diag)
    end do
    do j = 1, nlat_diag
      lat_ax(j) = -90.0_ESMF_KIND_R8 + real(j-1, ESMF_KIND_R8) * (180.0_ESMF_KIND_R8 / (nlat_diag-1))
    end do

    ncstat = nf90_create(trim(fname), NF90_CLOBBER, ncid_w)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('WriteDOCNDiag: nf90_create falhou: '// &
        trim(nf90_strerror(ncstat)), ESMF_LOGMSG_WARNING)
      goto 99
    end if

    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'Conventions',  'CF-1.8')
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'title', &
      'DOCN importState — SST/gelo interpolados por passo (campo global)')
    ncstat = nf90_put_att(ncid_w, NF90_GLOBAL, 'institution', 'INPE/CGCT/DIMNT — GT Acoplamento de Modelos')
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

    ncstat = nf90_def_dim(ncid_w, 'lon', nlon_diag, dimid_lon)
    ncstat = nf90_def_dim(ncid_w, 'lat', nlat_diag, dimid_lat)

    ncstat = nf90_def_var(ncid_w, 'lon',  NF90_DOUBLE, [dimid_lon], varid_lon)
    ncstat = nf90_put_att(ncid_w, varid_lon, 'units', 'degrees_east')
    ncstat = nf90_def_var(ncid_w, 'lat',  NF90_DOUBLE, [dimid_lat], varid_lat)
    ncstat = nf90_put_att(ncid_w, varid_lat, 'units', 'degrees_north')

    ncstat = nf90_def_var(ncid_w, 'So_t',     NF90_DOUBLE, [dimid_lon,dimid_lat], varid_sst)
    ncstat = nf90_put_att(ncid_w, varid_sst, 'long_name', 'SST interpolada (OISST→NUOPC)')
    ncstat = nf90_put_att(ncid_w, varid_sst, 'units',     'K')
    ncstat = nf90_put_att(ncid_w, varid_sst, 'valid_min', 250.0_ESMF_KIND_R8)
    ncstat = nf90_put_att(ncid_w, varid_sst, 'valid_max', 315.0_ESMF_KIND_R8)
    ncstat = nf90_put_att(ncid_w, varid_sst, '_FillValue', fill_val)

    ncstat = nf90_def_var(ncid_w, 'Si_ifrac', NF90_DOUBLE, [dimid_lon,dimid_lat], varid_ice)
    ncstat = nf90_put_att(ncid_w, varid_ice, 'long_name', 'Fracao de gelo marinho')
    ncstat = nf90_put_att(ncid_w, varid_ice, 'units',     '1')
    ncstat = nf90_put_att(ncid_w, varid_ice, 'valid_min', 0.0_ESMF_KIND_R8)
    ncstat = nf90_put_att(ncid_w, varid_ice, 'valid_max', 1.0_ESMF_KIND_R8)
    ncstat = nf90_put_att(ncid_w, varid_ice, '_FillValue', fill_val)

    ncstat = nf90_def_var(ncid_w, 'So_u', NF90_DOUBLE, [dimid_lon,dimid_lat], varid_u)
    ncstat = nf90_put_att(ncid_w, varid_u, 'long_name', 'Corrente zonal (zero se cur_file vazio)')
    ncstat = nf90_put_att(ncid_w, varid_u, 'units',     'm/s')
    ncstat = nf90_put_att(ncid_w, varid_u, '_FillValue', fill_val)

    ncstat = nf90_def_var(ncid_w, 'So_v', NF90_DOUBLE, [dimid_lon,dimid_lat], varid_v)
    ncstat = nf90_put_att(ncid_w, varid_v, 'long_name', 'Corrente meridional')
    ncstat = nf90_put_att(ncid_w, varid_v, 'units',     'm/s')
    ncstat = nf90_put_att(ncid_w, varid_v, '_FillValue', fill_val)

    ncstat = nf90_enddef(ncid_w)
    ncstat = nf90_put_var(ncid_w, varid_lon, lon_ax)
    ncstat = nf90_put_var(ncid_w, varid_lat, lat_ax)
    ncstat = nf90_put_var(ncid_w, varid_sst, fout)
    ncstat = nf90_put_var(ncid_w, varid_ice, iceout)
    ncstat = nf90_put_var(ncid_w, varid_u,   uout)
    ncstat = nf90_put_var(ncid_w, varid_v,   vout)
    ncstat = nf90_close(ncid_w)
    call ESMF_LogWrite('WriteDOCNDiag: '//trim(fname)//' (tidx0='// &
      trim(adjustl(int2str(tidx0)))//' alpha='// &
      trim(adjustl(real2str(real(alpha,4))))//') [B-58v2]', ESMF_LOGMSG_INFO)

    99 continue
    if (allocated(f0))    deallocate(f0, f1, fout)
    if (allocated(ice0))  deallocate(ice0, ice1, iceout)
    if (allocated(uout))  deallocate(uout, vout)
    if (allocated(lon_ax)) deallocate(lon_ax, lat_ax)

  contains
    function int2str(n) result(s)
      integer, intent(in) :: n
      character(len=12) :: s
      write(s,'(I12)') n
    end function int2str
    function real2str(x) result(s)
      real, intent(in) :: x
      character(len=12) :: s
      write(s,'(F8.4)') x
    end function real2str

  end subroutine WriteDOCNDiag

end module docn_cap_netcdf_mod
