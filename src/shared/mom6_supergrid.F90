!> @file mom6_supergrid.F90
!! @brief Grade T do MOM6 lida do supergrid FRE-NCtools (ocean_hgrid.nc).
!!
!! Usado pelo mediador e pelo cap do SIS2, que vivem na mesma grade tripolar do
!! MOM6. As duas cópias que existiam (MED_* em MED_cap.F90 e ICE_* em
!! sis_cap_MONAN.F90) tinham a mesma lógica; só as mensagens de log diferiam,
!! e passam a usar o prefixo dado em 'tag'.
!!
!! Supergrid: dimensões nx, ny = 2 × grade T; centros T nos índices pares
!! (2i, 2j); cantos nos índices ímpares (2i-1, 2j-1).
module mom6_supergrid_mod

  use ESMF
  use netcdf

  implicit none
  private
  public :: mom6_supergrid_dims, mom6_supergrid_tcoords, mom6_supergrid_corners

contains



  !============================================================================
  !
  ! CAUSA-RAIZ: a grade "ocn_grid" que o MEDIADOR usa internamente para o
  ! regrid OCN<->ATM era construida com as dimensoes do DOCN/OISST
  ! (cfg_docn_nx x cfg_docn_ny = 1440x720) e coordenadas lat/lon UNIFORMES,
  ! mesmo quando o componente OCN real e' o MOM6+SIS2 dinamico (grade
  ! tripolar, NAO uniforme). Em producao (cfg_use_docn=.false.) a grade T
  ! real do MOM6 (NIGLOBAL x NJGLOBAL no MOM_input) e' MUITO menor e
  ! geometricamente diferente (ex.: 180x155 medido em campo vs 1440x720
  ! assumido pelo mediador). Como os dois lados (OCN real, MED fabricado)
  ! sao objetos ESMF geometricamente distintos, o NUOPC monta um regrid
  ! AUTOMATICO entre eles usando as coordenadas erradas do MED ? isso
  ! contamina todos os campos OCN->MED (So_t, So_u, So_v, So_omask) com um
  ! deslocamento geografico sistematico, mais visivel exatamente na costa
  ! (onde pequenos erros de posicao cruzam a fronteira terra/mar).
  !
  ! FIX: quando cfg_use_docn=.false. (MOM6 ativo), a grade T real e' lida
  ! diretamente do supergrid FRE-NCtools (ocean_hgrid.nc, mesmo arquivo
  ! apontado por mesh_ocn em nuopc.input): dimensoes = nx/ny do arquivo / 2;
  ! coordenadas T = pontos pares do supergrid (indice 2*i, 2*j). Ambas as
  ! subrotinas abaixo sao chamadas a partir de InitializeRealize, ANTES de
  ! qualquer ESMF_FieldRegridStore, para que TODOS os campos OCN<->MED
  ! herdem a geometria correta (nao so' o SST mascarado).
  !============================================================================

  !----------------------------------------------------------------------------
  ! mom6_supergrid_dims ? le as dimensoes do supergrid (variaveis 'nx'/'ny'
  ! de ocean_hgrid.nc) e devolve a grade T real do MOM6 (NIGLOBAL x NJGLOBAL),
  ! que e' metade da resolucao do supergrid em cada eixo (convencao padrao
  ! FRE-NCtools/make_hgrid: supergrid inclui vertices + centros das celulas).
  !----------------------------------------------------------------------------


  !----------------------------------------------------------------------------
  ! mom6_supergrid_dims — le as dimensoes do supergrid (variaveis 'nx'/'ny'
  ! de ocean_hgrid.nc) e devolve a grade T real do MOM6 (NIGLOBAL x NJGLOBAL),
  ! que e' metade da resolucao do supergrid em cada eixo (convencao padrao
  ! FRE-NCtools/make_hgrid: supergrid inclui vertices + centros das celulas).
  !----------------------------------------------------------------------------
  subroutine mom6_supergrid_dims(filename, ni, nj, rc, tag)
    character(len=*), intent(in)  :: filename
    integer,           intent(out) :: ni, nj
    integer,           intent(out) :: rc
    character(len=*), intent(in), optional :: tag   !< prefixo das mensagens de log
    character(len=64) :: pfx
    integer :: ncid, dimid, nx_super, ny_super, ncstat

    pfx = 'MOM6 supergrid'; if (present(tag)) pfx = tag
    rc = ESMF_SUCCESS
    ni = 0; nj = 0

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao abrir ' // trim(filename) // &
        ' para ler dimensoes da grade T real do MOM6', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'nx', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=nx_super)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao ler dimensao "nx" de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'ny', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=ny_super)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao ler dimensao "ny" de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_close(ncid)

    if (mod(nx_super,2) /= 0 .or. mod(ny_super,2) /= 0) then
      call ESMF_LogWrite(trim(pfx)//': AVISO - nx/ny impar em ' // &
        trim(filename) // ' (formato inesperado; nao parece supergrid ' // &
        'FRE-NCtools padrao). Prosseguindo com divisao inteira por 2.', &
        ESMF_LOGMSG_WARNING)
    end if

    ni = nx_super / 2
    nj = ny_super / 2
  end subroutine mom6_supergrid_dims

  !----------------------------------------------------------------------------
  ! mom6_supergrid_tcoords - preenche coordX/coordY (bounds em indice GLOBAL,
  ! pois ocn_grid usa ESMF_INDEX_GLOBAL) com as coordenadas T REAIS lidas do
  ! supergrid ocean_hgrid.nc via hyperslab com stride=2 (pula os pontos de
  ! vertice/aresta do supergrid, mantendo so' os centros das celulas T).
  ! Convencao FRE-NCtools: celula T global (i,j), i=1..NIGLOBAL, j=1..NJGLOBAL,
  ! esta no indice de supergrid (2*i, 2*j), 1-based.
  !----------------------------------------------------------------------------
  subroutine mom6_supergrid_tcoords(filename, coordX, coordY, rc, tag)
    character(len=*),    intent(in)    :: filename
    real(ESMF_KIND_R8), pointer        :: coordX(:,:), coordY(:,:)
    integer,              intent(out)  :: rc
    character(len=*), intent(in), optional :: tag   !< prefixo das mensagens de log
    character(len=64) :: pfx
    integer :: ncid, varid_x, varid_y, ncstat
    integer :: i1, i2, j1, j2, ni_local, nj_local
    integer :: start2(2), count2(2), stride2(2)
    character(len=300) :: dbgmsg
    real(ESMF_KIND_R8) :: x_row_min
    real(ESMF_KIND_R8) :: x_row_max
    real(ESMF_KIND_R8) :: y_col_min
    real(ESMF_KIND_R8) :: y_col_max

    pfx = 'MOM6 supergrid'; if (present(tag)) pfx = tag
    rc = ESMF_SUCCESS
    if (.not. associated(coordX) .or. .not. associated(coordY)) return

    i1 = lbound(coordX,1); i2 = ubound(coordX,1)
    j1 = lbound(coordX,2); j2 = ubound(coordX,2)
    ni_local = i2 - i1 + 1
    nj_local = j2 - j1 + 1
    if (ni_local <= 0 .or. nj_local <= 0) return

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao abrir ' // trim(filename) // &
        ' para ler coordenadas T reais do MOM6', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_varid(ncid, 'x', varid_x)
    if (ncstat == NF90_NOERR) ncstat = nf90_inq_varid(ncid, 'y', varid_y)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': variaveis "x"/"y" nao encontradas em ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ! Ponto T (i,j) [global, 1-based] = vertice de supergrid (2*i, 2*j).
    ! stride=2 le direto os centros, sem carregar o supergrid inteiro (2x
    ! resolucao) na memoria de cada PET.
    start2  = (/ 2*i1, 2*j1 /)
    count2  = (/ ni_local, nj_local /)
    stride2 = (/ 2, 2 /)

    ncstat = nf90_get_var(ncid, varid_x, coordX, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao ler "x" (lon) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ! normaliza longitude bruta do supergrid (ex.: -300..60,
    ! convencao nativa do make_hgrid) para 0..360, mesma convencao da grade
    ! ATM (coordX = (i-1)*360/nx_atm). Sem isso, os dois lados do acoplamento
    ! descrevem a mesma posicao fisica com numeros de longitude diferentes.
    where (coordX < 0.0_ESMF_KIND_R8)
      coordX = coordX + 360.0_ESMF_KIND_R8
    end where
    where (coordX >= 360.0_ESMF_KIND_R8)
      coordX = coordX - 360.0_ESMF_KIND_R8
    end where

    ncstat = nf90_get_var(ncid, varid_y, coordY, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao ler "y" (lat) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ncstat = nf90_close(ncid)

    ! DIAGNOSTICO TEMPORARIO comprova o que foi lido de fato.
    ! coordX deve VARIAR com i (longitude) e ser ~constante ao longo de j
    ! (exceto perto do fold tripolar); coordY o oposto. Se coordX nao variar
    ! com i, a longitude "colapsou" e o regrid produz bandas puramente
    ! zonais (sem estrutura leste-oeste) ? exatamente o sintoma relatado.
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
        trim(pfx)//' DIAG: DE i=[',i1,',',i2,'] j=[',j1,',',j2, &
        '] coordX(i,j1) min=', x_row_min, ' max=', x_row_max, &
        ' | coordY(i1,j) min=', y_col_min, ' max=', y_col_max, &
        ' | coordX(i1,j1)=', coordX(i1,j1), ' coordX(i2,j1)=', coordX(i2,j1), &
        ' | coordY(i1,j1)=', coordY(i1,j1), ' coordY(i1,j2)=', coordY(i1,j2)
      call ESMF_LogWrite(trim(dbgmsg), ESMF_LOGMSG_INFO)
  end subroutine mom6_supergrid_tcoords

  !----------------------------------------------------------------------------
  ! mom6_supergrid_corners — le os
  ! VERTICES (cantos) das celulas T do MOM6, necessarios para regrid
  ! conservativo (ESMF_REGRIDMETHOD_CONSERVE), que calcula peso por
  ! sobreposicao de AREA entre celulas fonte e destino — exige os 4 cantos
  ! de cada celula, nao so' o centro.
  !
  ! Mesma logica de mom6_supergrid_tcoords (mesmo arquivo ocean_hgrid.nc,
  ! mesmo stride=2), com UM offset de indice diferente: celula T (i,j) esta
  ! no vertice de supergrid (2*i, 2*j); o canto inferior-esquerdo dessa
  ! MESMA celula esta em (2*i-1, 2*j-1). Como o canto (i,j) e' compartilhado
  ! pelas celulas T vizinhas, um array de cantos (ni+1)x(nj+1) cobre uma
  ! grade (ni)x(nj) de celulas por completo — o proprio ESMF ja' aloca o
  ! array de cantos com o tamanho certo (incluindo periodicidade) quando
  ! ESMF_GridAddCoord(staggerloc=CORNER) e' chamado; esta rotina so' preenche
  ! o que coordX/coordY (ja' alocados pelo ESMF) pedirem, usando lbound/ubound
  ! deles — nao supoe o tamanho a priori.
  !----------------------------------------------------------------------------
  subroutine mom6_supergrid_corners(filename, coordX, coordY, rc, tag)
    character(len=*),    intent(in)    :: filename
    real(ESMF_KIND_R8), pointer        :: coordX(:,:), coordY(:,:)
    integer,              intent(out)  :: rc
    character(len=*), intent(in), optional :: tag   !< prefixo das mensagens de log
    character(len=64) :: pfx
    integer :: ncid, varid_x, varid_y, ncstat
    integer :: i1, i2, j1, j2, ni_local, nj_local
    integer :: start2(2), count2(2), stride2(2)

    pfx = 'MOM6 supergrid'; if (present(tag)) pfx = tag
    rc = ESMF_SUCCESS
    if (.not. associated(coordX) .or. .not. associated(coordY)) return

    i1 = lbound(coordX,1); i2 = ubound(coordX,1)
    j1 = lbound(coordX,2); j2 = ubound(coordX,2)
    ni_local = i2 - i1 + 1
    nj_local = j2 - j1 + 1
    if (ni_local <= 0 .or. nj_local <= 0) return

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao abrir ' // trim(filename) // &
        ' para ler cantos (vertices) do MOM6', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_varid(ncid, 'x', varid_x)
    if (ncstat == NF90_NOERR) ncstat = nf90_inq_varid(ncid, 'y', varid_y)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': variaveis "x"/"y" nao encontradas em ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ! Canto (i,j) [global, 1-based, ate NI+1/NJ+1] = vertice de supergrid
    ! (2*i-1, 2*j-1). Unico offset em relacao ao centro (2*i, 2*j).
    start2  = (/ 2*i1 - 1, 2*j1 - 1 /)
    count2  = (/ ni_local, nj_local /)
    stride2 = (/ 2, 2 /)

    ncstat = nf90_get_var(ncid, varid_x, coordX, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao ler "x" (lon, canto) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ! Mesma normalizacao de longitude 0..360 usada para o centro.
    where (coordX < 0.0_ESMF_KIND_R8)
      coordX = coordX + 360.0_ESMF_KIND_R8
    end where
    where (coordX >= 360.0_ESMF_KIND_R8)
      coordX = coordX - 360.0_ESMF_KIND_R8
    end where

    ncstat = nf90_get_var(ncid, varid_y, coordY, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite(trim(pfx)//': falha ao ler "y" (lat, canto) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ncstat = nf90_close(ncid)

  end subroutine mom6_supergrid_corners

end module mom6_supergrid_mod
