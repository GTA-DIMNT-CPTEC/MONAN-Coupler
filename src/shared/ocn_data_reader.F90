!> @file ocn_data_reader.F90
!! @brief Leitura de campos oceânicos de arquivos NetCDF (OISST e equivalentes).
!!
!! Serviço usado pelo oceano de dados (DOCN_cap.F90) e pelo cap do MOM6
!! (mom_si_ifrac.F90, fração de gelo do OISST): o PET 0 lê o campo global
!! em dois instantes, interpola no tempo e o distribui; cada PET copia o
!! seu subdomínio.
!!   ReadGlobalField     lê um instante global de um arquivo NetCDF (PET 0)
!!   ReadOcnFieldInterp  interpola no tempo entre dois instantes e distribui
!! A época e o passo dos dados vêm do grupo &nuopc_docn do nuopc.input. As
!! mensagens levam a marca DOCN, quem quer que seja o chamador.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module ocn_data_reader_mod

  use ESMF
  use netcdf
  use coupler_utils_mod, only: ChkErr, int_to_str
  use coupler_log_mod, only: COMP_DOCN, log_error, log_warning, log_debug
  use coupler_config_mod, only: cfg_docn_dt_data, cfg_docn_epoch_year, &
                                cfg_docn_epoch_month, cfg_docn_epoch_day

  implicit none
  private

  public :: ReadGlobalField     !< lê snapshot global NetCDF (somente PET0)
  public :: ReadOcnFieldInterp  !< interpola temporalmente e distribui via broadcast

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

end module ocn_data_reader_mod
