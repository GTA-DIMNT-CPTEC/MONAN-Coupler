!> @file mom6_supergrid.F90
!! @brief Grade T do MOM6 lida do supergrid FRE-NCtools (ocean_hgrid.nc).
!!
!! Usado pelo mediador e pelo cap do SIS2, que vivem na mesma grade tripolar
!! do MOM6; as mensagens de log levam a marca do componente dada em 'comp'
!! (coupler_log_mod).
!!
!! Por que ler o supergrid: com o MOM6, a grade do oceano no mediador tem de
!! ser a grade T real do modelo (tripolar, não uniforme, com NIGLOBAL x
!! NJGLOBAL do MOM_input), e não uma grade regular. Se os dois lados do
!! conector OCN->MED forem geometricamente diferentes, o NUOPC interpola
!! entre eles com as coordenadas erradas do mediador, e todos os campos
!! OCN->MED (So_t, So_u, So_v, So_omask) ficam deslocados, sobretudo na
!! costa. As rotinas daqui são chamadas em InitializeRealize, antes de
!! qualquer ESMF_FieldRegridStore, para que todos os campos OCN<->MED
!! herdem a geometria correta.
!!
!! Supergrid: dimensões nx, ny = 2 × grade T; centros T nos índices pares
!! (2i, 2j); cantos nos índices ímpares (2i-1, 2j-1).

module mom6_supergrid_mod

  use ESMF
  use netcdf
  use coupler_log_mod, only : COMP_OCN, log_error, log_warning, log_debug, log_debug_enabled

  implicit none
  private
  public :: mom6_supergrid_dims, mom6_supergrid_tcoords, mom6_supergrid_corners

contains

  !> @brief Dimensões da grade T do MOM6 (NIGLOBAL x NJGLOBAL), metade das do
  !! supergrid (variáveis 'nx'/'ny' de ocean_hgrid.nc) em cada eixo, pela
  !! convenção do FRE-NCtools/make_hgrid (o supergrid inclui vértices e
  !! centros das células).
  subroutine mom6_supergrid_dims(filename, ni, nj, rc, comp)
    character(len=*), intent(in)  :: filename
    integer,           intent(out) :: ni, nj
    integer,           intent(out) :: rc
    character(len=*), intent(in), optional :: comp  !< marca do componente nas mensagens (padrão: OCN)
    character(len=64) :: pfx
    integer :: ncid, dimid, nx_super, ny_super, ncstat

    pfx = COMP_OCN; if (present(comp)) pfx = comp
    rc = ESMF_SUCCESS
    ni = 0; nj = 0

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call log_error(trim(pfx), 'falha ao abrir ' // trim(filename) // &
        ' para ler dimensoes da grade T real do MOM6')
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'nx', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=nx_super)
    if (ncstat /= NF90_NOERR) then
      call log_error(trim(pfx), 'falha ao ler dimensao "nx" de ' // trim(filename))
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'ny', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=ny_super)
    if (ncstat /= NF90_NOERR) then
      call log_error(trim(pfx), 'falha ao ler dimensao "ny" de ' // trim(filename))
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_close(ncid)

    if (mod(nx_super,2) /= 0 .or. mod(ny_super,2) /= 0) then
      call log_warning(trim(pfx), 'nx/ny impar em ' // &
        trim(filename) // ' (formato inesperado; nao parece supergrid ' // &
        'FRE-NCtools padrao). Prosseguindo com divisao inteira por 2.')
    end if

    ni = nx_super / 2
    nj = ny_super / 2
  end subroutine mom6_supergrid_dims

  !> @brief Preenche coordX/coordY (bounds em índice GLOBAL, pois a grade usa
  !! ESMF_INDEX_GLOBAL) com as coordenadas T do supergrid, lidas com
  !! stride=2 (só os centros das células T). Convenção FRE-NCtools: a célula
  !! T global (i,j), i=1..NIGLOBAL, j=1..NJGLOBAL, está no índice de
  !! supergrid (2*i, 2*j), base 1.
  subroutine mom6_supergrid_tcoords(filename, coordX, coordY, rc, comp)
    character(len=*),    intent(in)    :: filename
    real(ESMF_KIND_R8), pointer        :: coordX(:,:), coordY(:,:)
    integer,              intent(out)  :: rc
    character(len=*), intent(in), optional :: comp  !< marca do componente nas mensagens (padrão: OCN)
    character(len=64) :: pfx
    logical :: was_read
    integer :: i1, i2, j1, j2, ni_local, nj_local
    character(len=300) :: dbgmsg
    real(ESMF_KIND_R8) :: x_row_min
    real(ESMF_KIND_R8) :: x_row_max
    real(ESMF_KIND_R8) :: y_col_min
    real(ESMF_KIND_R8) :: y_col_max

    pfx = COMP_OCN; if (present(comp)) pfx = comp
    ! Ponto T (i,j) [global, 1-based] = vértice de supergrid (2*i, 2*j).
    call read_supergrid_points(filename, 0, ' para ler coordenadas T reais do MOM6', &
      '"x" (lon)', '"y" (lat)', pfx, coordX, coordY, was_read, rc)
    if (.not. was_read) return

    i1 = lbound(coordX,1); i2 = ubound(coordX,1)
    j1 = lbound(coordX,2); j2 = ubound(coordX,2)
    ni_local = i2 - i1 + 1
    nj_local = j2 - j1 + 1

    ! Diagnóstico de depuração ("DIAG supergrid tcoords"): comprova o que foi
    ! lido de fato. Fora do nível de depuração, nem é calculado.
    if (.not. log_debug_enabled()) return
    ! coordX deve VARIAR com i (longitude) e ser ~constante ao longo de j
    ! (exceto perto da dobra tripolar); coordY o oposto. Se coordX não
    ! variar com i, a longitude "colapsou", e o regrid produz bandas
    ! puramente zonais (sem estrutura leste-oeste).
      if (ni_local >= 2 .and. nj_local >= 1) then
        x_row_min = minval(coordX(:, j1))
        x_row_max = maxval(coordX(:, j1))
      else
        x_row_min = -999.0_ESMF_KIND_R8; x_row_max = -999.0_ESMF_KIND_R8
      end if
      if (nj_local >= 2 .and. ni_local >= 1) then
        y_col_min = minval(coordY(i1, :))
        y_col_max = maxval(coordY(i1, :))
      else
        y_col_min = -999.0_ESMF_KIND_R8; y_col_max = -999.0_ESMF_KIND_R8
      end if
      write(dbgmsg,'(A,I0,A,I0,A,I0,A,I0,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3)') &
        'DIAG supergrid tcoords: DE i=[',i1,',',i2,'] j=[',j1,',',j2, &
        '] coordX(i,j1) min=', x_row_min, ' max=', x_row_max, &
        ' | coordY(i1,j) min=', y_col_min, ' max=', y_col_max, &
        ' | coordX(i1,j1)=', coordX(i1,j1), ' coordX(i2,j1)=', coordX(i2,j1), &
        ' | coordY(i1,j1)=', coordY(i1,j1), ' coordY(i1,j2)=', coordY(i1,j2)
      call log_debug(trim(pfx), trim(dbgmsg))
  end subroutine mom6_supergrid_tcoords

  !> @brief Preenche coordX/coordY com os VÉRTICES (cantos) das células T do
  !! MOM6, necessários ao regrid conservativo (ESMF_REGRIDMETHOD_CONSERVE),
  !! que pesa pela sobreposição de ÁREA e exige os 4 cantos de cada célula.
  !!
  !! Mesma leitura de mom6_supergrid_tcoords (mesmo arquivo, stride=2), com
  !! outro deslocamento: o canto inferior-esquerdo da célula T (i,j) está em
  !! (2*i-1, 2*j-1). Como cada canto é compartilhado pelas células vizinhas,
  !! um array de cantos (ni+1)x(nj+1) cobre a grade inteira; o ESMF já o
  !! aloca no tamanho certo (incluindo a periodicidade) em
  !! ESMF_GridAddCoord(staggerloc=CORNER), e esta rotina só preenche o que
  !! coordX/coordY pedem, pelos seus lbound/ubound.
  subroutine mom6_supergrid_corners(filename, coordX, coordY, rc, comp)
    character(len=*),    intent(in)    :: filename
    real(ESMF_KIND_R8), pointer        :: coordX(:,:), coordY(:,:)
    integer,              intent(out)  :: rc
    character(len=*), intent(in), optional :: comp  !< marca do componente nas mensagens (padrão: OCN)
    character(len=64) :: pfx
    logical :: was_read

    pfx = COMP_OCN; if (present(comp)) pfx = comp
    ! Canto (i,j) [global, 1-based, até NI+1/NJ+1] = vértice de supergrid
    ! (2*i-1, 2*j-1). Único offset em relação ao centro (2*i, 2*j).
    call read_supergrid_points(filename, 1, ' para ler cantos (vertices) do MOM6', &
      '"x" (lon, canto)', '"y" (lat, canto)', pfx, coordX, coordY, was_read, rc)

  end subroutine mom6_supergrid_corners

  !> @brief Lê do supergrid os pontos (2*i-off, 2*j-off) da porção local de
  !! coordX/coordY (bounds em índice GLOBAL), com stride=2: off=0 dá os centros
  !! T e off=1 os cantos. A longitude é normalizada para [0,360).
  !!
  !! was_read fica .false. quando não há o que ler (ponteiros não associados
  !! ou porção local vazia, com rc=ESMF_SUCCESS) ou quando o arquivo não abre
  !! ou não tem as variáveis "x"/"y" (rc=ESMF_FAILURE). Falha na leitura de
  !! "x" ou "y" põe rc=ESMF_FAILURE, mas was_read fica .true.
  !!
  !! @param[in]  filename  supergrid ocean_hgrid.nc
  !! @param[in]  off       0 para centros T, 1 para cantos
  !! @param[in]  txt_open  complemento da mensagem de falha ao abrir
  !! @param[in]  txt_x     nome de "x" nas mensagens de falha de leitura
  !! @param[in]  txt_y     nome de "y" nas mensagens de falha de leitura
  !! @param[in]  pfx       marca do componente nas mensagens de log
  !! @param[out] was_read  se o arquivo foi aberto e lido
  !! @param[out] rc        ESMF_SUCCESS ou ESMF_FAILURE
  subroutine read_supergrid_points(filename, off, txt_open, txt_x, txt_y, pfx, &
                                   coordX, coordY, was_read, rc)
    character(len=*),   intent(in)  :: filename
    integer,            intent(in)  :: off
    character(len=*),   intent(in)  :: txt_open, txt_x, txt_y, pfx
    real(ESMF_KIND_R8), pointer     :: coordX(:,:), coordY(:,:)
    logical,            intent(out) :: was_read
    integer,            intent(out) :: rc
    integer :: ncid, varid_x, varid_y, ncstat
    integer :: i1, i2, j1, j2, ni_local, nj_local
    integer :: start2(2), count2(2), stride2(2)

    was_read = .false.
    rc = ESMF_SUCCESS
    if (.not. associated(coordX) .or. .not. associated(coordY)) return

    i1 = lbound(coordX,1); i2 = ubound(coordX,1)
    j1 = lbound(coordX,2); j2 = ubound(coordX,2)
    ni_local = i2 - i1 + 1
    nj_local = j2 - j1 + 1
    if (ni_local <= 0 .or. nj_local <= 0) return

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call log_error(trim(pfx), 'falha ao abrir ' // trim(filename) // txt_open)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_varid(ncid, 'x', varid_x)
    if (ncstat == NF90_NOERR) ncstat = nf90_inq_varid(ncid, 'y', varid_y)
    if (ncstat /= NF90_NOERR) then
      call log_error(trim(pfx), 'variaveis "x"/"y" nao encontradas em ' // trim(filename))
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if
    was_read = .true.

    ! stride=2 lê direto os pontos pedidos, sem carregar o supergrid inteiro
    ! (2x resolução) na memória de cada PET.
    start2  = (/ 2*i1 - off, 2*j1 - off /)
    count2  = (/ ni_local, nj_local /)
    stride2 = (/ 2, 2 /)

    ncstat = nf90_get_var(ncid, varid_x, coordX, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call log_error(trim(pfx), 'falha ao ler ' // txt_x // ' de ' // trim(filename))
      rc = ESMF_FAILURE
    end if

    ! normaliza longitude bruta do supergrid (ex.: -300..60,
    ! convenção nativa do make_hgrid) para 0..360, mesma convenção da grade
    ! ATM (coordX = (i-1)*360/nx_atm). Sem isso, os dois lados do acoplamento
    ! descrevem a mesma posição física com números de longitude diferentes.
    where (coordX < 0.0_ESMF_KIND_R8)
      coordX = coordX + 360.0_ESMF_KIND_R8
    end where
    where (coordX >= 360.0_ESMF_KIND_R8)
      coordX = coordX - 360.0_ESMF_KIND_R8
    end where

    ncstat = nf90_get_var(ncid, varid_y, coordY, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call log_error(trim(pfx), 'falha ao ler ' // txt_y // ' de ' // trim(filename))
      rc = ESMF_FAILURE
    end if

    ncstat = nf90_close(ncid)

  end subroutine read_supergrid_points

end module mom6_supergrid_mod
