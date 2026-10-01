!> @file cpl_grids.F90
!! @brief Construção das malhas do acoplamento e fórmulas das grades regulares.
!!
!! As malhas descritas em MALHAS (cpl_map.F90) são construídas aqui:
!!
!!   atm_cap   grade do cap do MONAN-A (mpas_cap_methods::mpas_create_grid),
!!             regular, centros com longitude a partir de -180 graus, sem
!!             cantos (cpl_malha_latlon)
!!   atm_med   malha de fluxo do mediador (med_init::create_atm_grid),
!!             regular, centros com longitude a partir de 0 grau, com cantos
!!             (o método conservativo exige os cantos) (cpl_malha_latlon)
!!   ocn_med   oceano no mediador (med_init::create_ocn_grid): com o MOM6, a
!!             grade tripolar lida do supergrid, com cantos
!!             (cpl_malha_tripolar); com o DOCN, regular, com a longitude do
!!             centro no canto oeste da célula (cpl_malha_latlon,
!!             ORIGEM_LESTE0_CANTO)
!!   ice_sis2  grade do cap do SIS2 (sis_cap_MONAN::create_ice_grid),
!!             tripolar, nos blocos do domínio do SIS2, sem cantos
!!             (cpl_malha_tripolar com cpl_blocos_t)
!!   ocn_mom6  grade do cap do MOM6 (mom_cap_MONAN::create_ocean_grid), nos
!!             blocos do domínio do MOM6, com as coordenadas que o cap copia
!!             do modelo (cpl_malha_de_blocos)
!!
!! As quatro primeiras são periódicas em longitude (periodicDim = 1, o
!! padrão do ESMF), com índices globais e coordenadas esféricas em graus,
!! sem polo declarado. Sem blocos, a decomposição é cpl_regdecomp, um DE por
!! PET; com blocos (cpl_blocos_t, montados por cpl_blocos_de_limites), cada
!! bloco vai ao PET que o tem no modelo.
!!
!! A grade do cap do MOM6 é diferente, e continua como era: criada sobre um
!! DistGrid com a lista de blocos do MOM6 (deBlockList, que aceita
!! qualquer conjunto de blocos retangulares), sem periodicidade declarada e
!! com os índices locais de cada DE (o padrão do ESMF). Não pode ser feita
!! por cpl_malha_tripolar sem mudar resultados: a periodicidade muda os
!! pesos que o conector OCN para MED calcula, e as coordenadas do MOM6
!! (geoLonT, geoLatT) não estão na faixa [0, 360) das lidas do supergrid.
!!
!! As fórmulas de centro e de canto ficam em funções, uma por regra: as
!! malhas regulares calculam o centro com expressões diferentes, e cada
!! função reproduz a sua expressão sem mudança, para que nenhum bit mude.
!!
!! Também ficam aqui as fórmulas que levam uma coordenada à coluna ou à linha
!! de uma grade regular (índice), usadas pelo cap atmosférico, pelos
!! gravadores de diagnóstico do MONAN-A, pelo mediador e pelo cap do MOM6, e
!! as que trazem a longitude para uma faixa de 360 graus. Cada regra é uma
!! função, com o nome da regra, e reproduz a expressão de onde saiu:
!!
!!   indice_trunca      int(x/d) + 1        binning e cópia do cap, leitura
!!                                          da importação no cap, OISST e
!!                                          diagnóstico da importação
!!   indice_arredonda   nint(x/d) + 1       diagnóstico da exportação
!!   lon_0a360_piso     lon - floor(lon/360)*360          binning do cap
!!   lon_m180a180_piso  lon - floor((lon+180)/360)*360    importação no cap
!!   lon_0a360_laco     soma ou subtrai 360 até [0, 360)  OISST no cap do MOM6
!!   lon_m180a180_laco  soma ou subtrai 360 até [-180, 180)  diagnósticos
!!
!! O diagnóstico da importação usava floor(x/d) + 1. Para x >= 0, floor e
!! int dão o mesmo valor; para x < 0, os dois dão 0 ou menos, e o índice,
!! limitado a [1, n], vira 1 nos dois casos. Com o limite, as duas
!! expressões dão sempre o mesmo índice, e ficou uma função só
!! (tests/unit/test_cpl_grids.F90 confere isso). nint arredonda para o mais
!! próximo e não é trocável pelas outras. Na longitude, as regras também não
!! são trocáveis: para um valor negativo muito pequeno, -1e-17
!! por exemplo, somar 360 dá exatamente 360, e o laço ainda subtrai 360 e
!! chega a 0, enquanto uma soma só para em 360 (a cópia do cap, que soma uma
!! vez só, continua com a sua expressão).
!!
!! Na grade do cap, o tamanho da célula era a constante 1 grau; aqui ele é
!! 360/nx e 180/ny, que com a grade 360 x 180 dão exatamente 1, e a
!! multiplicação por 1 é exata: as coordenadas são as mesmas, bit a bit.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module cpl_grids_mod

  use ESMF
  use coupler_utils_mod, only : ChkErr
  use mom6_supergrid_mod, only : mom6_supergrid_tcoords, mom6_supergrid_corners

  implicit none
  private

  public :: cpl_regdecomp, cpl_malha_latlon, cpl_malha_tripolar, cpl_blocos_de_limites
  public :: cpl_malha_de_blocos
  public :: centro_lon_leste0, centro_lat_leste0, canto_lon_leste0, canto_lat_leste0
  public :: centro_lon_oeste180, centro_lat_oeste180
  public :: indice_trunca, indice_arredonda
  public :: lon_0a360_piso, lon_m180a180_piso, lon_0a360_laco, lon_m180a180_laco
  public :: ORIGEM_LESTE0, ORIGEM_OESTE180, ORIGEM_LESTE0_CANTO

  integer, parameter :: r8 = ESMF_KIND_R8

  !> Longitude da primeira coluna: a partir de 0 grau, para leste, ou a
  !! partir de -180 graus.
  character(len=*), parameter :: ORIGEM_LESTE0   = 'leste0'
  character(len=*), parameter :: ORIGEM_OESTE180 = 'oeste180'
  !> Como ORIGEM_LESTE0, mas com a longitude do centro igual à do canto
  !! oeste da célula, (i-1)*360/nx, sem a meia célula: é como o mediador
  !! descreve a grade do DOCN (ocn_med com use_docn). A latitude do centro e
  !! os cantos são os de ORIGEM_LESTE0.
  character(len=*), parameter :: ORIGEM_LESTE0_CANTO = 'leste0_canto'

  !> Decomposição em blocos retangulares, um por PET: número de colunas de
  !! cada coluna de blocos (cntx), de linhas de cada linha de blocos (cnty)
  !! e o PET dono de cada bloco (pmap(ix, iy, 1)), na forma que
  !! ESMF_GridCreate1PeriDim recebe (countsPerDEDim1, countsPerDEDim2, petMap).
  type, public :: cpl_blocos_t
    integer, allocatable :: cntx(:), cnty(:), pmap(:,:,:)
  end type cpl_blocos_t

  character(len=*), parameter :: u_FILE_u = __FILE__

contains

  !> Decomposição regular (colunas x linhas) de uma grade nx x ny em petCount
  !! DEs, um por PET: linhas = o maior divisor de petCount que não passe de
  !! sqrt(petCount) nem de ny, com colunas <= nx/2 (cada DE com pelo menos 2
  !! colunas); colunas = petCount / linhas. Garante colunas x linhas =
  !! petCount, no par mais próximo de quadrado; um primo grande degenera para
  !! uma faixa (17 PETs: 17 x 1), com cobertura total.
  !!
  !! Um DE por PET é necessário: com mais DEs que PETs, alguns PETs ficariam
  !! com dois DEs, e os gathers (ESMF_FieldGather e o de
  !! med_write_import_fields) reuniriam só um DE por PET, deixando buracos no
  !! campo global (o MOM6 aborta com "extreme surface values"). Tiles quase
  !! quadradas também evitam faixas estreitas, que travavam o
  !! ESMF_FieldBundleRegridStore. Na grade 360 x 180:
  !!   N=16→(4,4)  N=32→(8,4)  N=64→(8,8)  N=128→(16,8)  N=512→(32,16)
  pure function cpl_regdecomp(petCount, nx, ny) result(regDecomp)
    integer, intent(in) :: petCount, nx, ny
    integer :: regDecomp(2)
    integer :: nrows, n

    nrows = 1
    do n = max(1, int(sqrt(real(petCount)))), 1, -1
      if (mod(petCount, n) == 0 .and. n <= ny .and. (petCount / n) <= nx / 2) then
        nrows = n
        exit
      end if
    end do
    regDecomp(1) = petCount / nrows   ! colunas (lon)
    regDecomp(2) = nrows              ! linhas (lat)
  end function cpl_regdecomp

  !> Cria uma malha regular nx x ny, periódica em longitude, com um DE por
  !! PET (cpl_regdecomp), índices globais e coordenadas dos centros; com
  !! cantos = .true., também as dos cantos (só nas origens ORIGEM_LESTE0 e
  !! ORIGEM_LESTE0_CANTO).
  !!
  !! ESMF_INDEX_GLOBAL: o limite inferior dos vetores de cada PET é o índice
  !! global (61 no segundo PET de 60 colunas, por exemplo), do que dependem
  !! os gathers dos diagnósticos e a cópia para a grade local no cap
  !! atmosférico. polekindflag fica no padrão do ESMF: as linhas extremas
  !! (±89,5 graus) não são um ponto geométrico único, e declará-las MONOPOLE
  !! coincidiu com SIGSEGV em core_run do MONAN-A, atribuído a pesos de
  !! interpolação corrompidos perto dos polos.
  !!
  !! ESMF_GridAddCoord é coletiva (todos os PETs); ESMF_GridGetCoord é local
  !! e exige localDE= quando o PET tem mais de um DE, por isso o laço sobre
  !! os DEs locais.
  !!
  !! @param[in]  nome        nome da malha em MALHAS, para as mensagens
  !! @param[in]  nx, ny      pontos em longitude e em latitude
  !! @param[in]  origem_lon  ORIGEM_LESTE0, ORIGEM_LESTE0_CANTO ou ORIGEM_OESTE180
  !! @param[in]  cantos      cria também as coordenadas dos cantos
  !! @param[in]  petCount    PETs do componente
  !! @param[out] grade       a grade criada
  !! @param[out] rc          ESMF_SUCCESS, ou o código da falha
  subroutine cpl_malha_latlon(nome, nx, ny, origem_lon, cantos, petCount, grade, rc)
    character(len=*), intent(in)  :: nome
    integer,          intent(in)  :: nx, ny
    character(len=*), intent(in)  :: origem_lon
    logical,          intent(in)  :: cantos
    integer,          intent(in)  :: petCount
    type(ESMF_Grid),  intent(out) :: grade
    integer,          intent(out) :: rc

    real(r8), pointer :: coordX(:,:), coordY(:,:)
    integer :: localDeCount, lde, i, j
    logical :: leste0, canto

    rc = ESMF_SUCCESS
    nullify(coordX, coordY)

    canto  = origem_lon == ORIGEM_LESTE0_CANTO
    leste0 = origem_lon == ORIGEM_LESTE0 .or. canto
    if (.not. leste0 .and. origem_lon /= ORIGEM_OESTE180) then
      call ESMF_LogSetError(ESMF_RC_ARG_VALUE, msg='cpl_malha_latlon: '//trim(nome)// &
           ': origem de longitude desconhecida: '//trim(origem_lon), &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if
    if (cantos .and. .not. leste0) then
      call ESMF_LogSetError(ESMF_RC_ARG_VALUE, msg='cpl_malha_latlon: '//trim(nome)// &
           ': cantos so com as origens '//ORIGEM_LESTE0//' e '//ORIGEM_LESTE0_CANTO, &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if

    call cria_grade(grade, nx, ny, petCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call prepara_coordenadas(grade, ESMF_STAGGERLOC_CENTER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call coordenadas_do_de(grade, ESMF_STAGGERLOC_CENTER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          if (canto) then
            coordX(i,j) = canto_lon_leste0(i, nx)
          else if (leste0) then
            coordX(i,j) = centro_lon_leste0(i, nx)
          else
            coordX(i,j) = centro_lon_oeste180(i, nx)
          end if
        end do
      end do
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          if (leste0) then
            coordY(i,j) = centro_lat_leste0(j, ny)
          else
            coordY(i,j) = centro_lat_oeste180(j, ny)
          end if
        end do
      end do
    end do

    if (.not. cantos) return

    ! Cantos: a borda da célula, meia célula antes do centro, por conta
    ! direta (a grade é regular), sem ler arquivo.
    call prepara_coordenadas(grade, ESMF_STAGGERLOC_CORNER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call coordenadas_do_de(grade, ESMF_STAGGERLOC_CORNER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          coordX(i,j) = canto_lon_leste0(i, nx)
        end do
      end do
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          coordY(i,j) = canto_lat_leste0(j, ny)
        end do
      end do
    end do
  end subroutine cpl_malha_latlon


  !> Cria a grade tripolar do MOM6 com as coordenadas lidas do supergrid
  !! (ocean_hgrid.nc): os centros das células T (mom6_supergrid_tcoords) e,
  !! com cantos = .true., os vértices (mom6_supergrid_corners), na porção de
  !! cada DE local. Periódica em longitude, índices globais, sem polo
  !! declarado: a linha j = 1 (borda da Antártida) e a dobra norte não são
  !! pontos geométricos únicos, e declará-las MONOPOLE coincidiu com SIGSEGV
  !! em core_run do MONAN-A, atribuído a pesos de interpolação corrompidos
  !! perto dos polos e da dobra. Sem a periodicidade, a interpolação bilinear
  !! trataria a costura leste-oeste como borda do domínio e deixaria uma
  !! coluna sem vizinho válido (no MOM6, perto de 60 graus E, onde o
  !! intervalo nativo -300..60 do supergrid fecha).
  !!
  !! A decomposição é a de blocos, quando dada (cada bloco no PET que o tem
  !! no modelo; nx e ny não são usados), ou cpl_regdecomp.
  !!
  !! @param[in]  nome          nome da malha em MALHAS, para as mensagens
  !! @param[in]  arquivo       supergrid do MOM6
  !! @param[in]  nx, ny        tamanho da grade T (sem blocos)
  !! @param[in]  petCount      PETs do componente (sem blocos)
  !! @param[in]  cantos        cria também as coordenadas dos cantos
  !! @param[out] grade         a grade criada
  !! @param[out] rc            ESMF_SUCCESS, ou o código da falha
  !! @param[in]  blocos        decomposição do modelo (opcional)
  !! @param[in]  tag           prefixo das mensagens da leitura dos centros
  !! @param[in]  tag_cantos    prefixo das mensagens da leitura dos cantos
  subroutine cpl_malha_tripolar(nome, arquivo, nx, ny, petCount, cantos, grade, rc, &
                                blocos, tag, tag_cantos)
    character(len=*),   intent(in)  :: nome
    character(len=*),   intent(in)  :: arquivo
    integer,            intent(in)  :: nx, ny
    integer,            intent(in)  :: petCount
    logical,            intent(in)  :: cantos
    type(ESMF_Grid),    intent(out) :: grade
    integer,            intent(out) :: rc
    type(cpl_blocos_t), intent(in), optional :: blocos
    character(len=*),   intent(in), optional :: tag, tag_cantos

    real(r8), pointer :: coordX(:,:), coordY(:,:)
    integer :: localDeCount, lde

    rc = ESMF_SUCCESS
    nullify(coordX, coordY)

    call cria_grade(grade, nx, ny, petCount, rc, blocos)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call prepara_coordenadas(grade, ESMF_STAGGERLOC_CENTER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call coordenadas_do_de(grade, ESMF_STAGGERLOC_CENTER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      call mom6_supergrid_tcoords(trim(arquivo), coordX, coordY, rc, tag=tag)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_tripolar: '//trim(nome)// &
          ': falha ao ler os centros de '//trim(arquivo), line=__LINE__, file=u_FILE_u)) return
    end do

    if (.not. cantos) return

    call prepara_coordenadas(grade, ESMF_STAGGERLOC_CORNER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call coordenadas_do_de(grade, ESMF_STAGGERLOC_CORNER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      call mom6_supergrid_corners(trim(arquivo), coordX, coordY, rc, tag=tag_cantos)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_tripolar: '//trim(nome)// &
          ': falha ao ler os cantos de '//trim(arquivo), line=__LINE__, file=u_FILE_u)) return
    end do
  end subroutine cpl_malha_tripolar

  !> Cria a grade do cap do MOM6 nos blocos do modelo: um DE por bloco,
  !! no PET dado, sobre um DistGrid [1..ni] x [1..nj] com a lista de blocos
  !! (deBlockList, que aceita qualquer conjunto de blocos retangulares, até
  !! um PET sem oceano), sem margem de halo (gridEdgeLWidth e gridEdgeUWidth
  !! nulos), sem periodicidade declarada e com os índices locais de cada DE;
  !! acrescenta o stagger dos centros, sem preencher: as coordenadas são as
  !! do modelo, e quem chama as copia.
  !!
  !! @param[in]  nome      nome da malha em MALHAS, para as mensagens
  !! @param[in]  ni, nj    tamanho global da grade
  !! @param[in]  limites   (is, ie, js, je) globais de cada bloco
  !! @param[in]  petMap    PET de cada bloco (base 0)
  !! @param[out] grade     a grade criada
  !! @param[out] rc        ESMF_SUCCESS, ou o código da falha
  subroutine cpl_malha_de_blocos(nome, ni, nj, limites, petMap, grade, rc)
    character(len=*), intent(in)  :: nome
    integer,          intent(in)  :: ni, nj
    integer,          intent(in)  :: limites(:,:)
    integer,          intent(in)  :: petMap(:)
    type(ESMF_Grid),  intent(out) :: grade
    integer,          intent(out) :: rc

    type(ESMF_DistGrid) :: distGrid
    type(ESMF_DELayout) :: deLayout
    integer, allocatable :: deBlockList(:,:,:)
    integer :: n

    ! deBlockList(dim, início/fim, bloco): dim 1 é i, dim 2 é j
    allocate(deBlockList(2, 2, size(limites, 2)))
    do n = 1, size(limites, 2)
      deBlockList(1, 1, n) = limites(1, n)
      deBlockList(1, 2, n) = limites(2, n)
      deBlockList(2, 1, n) = limites(3, n)
      deBlockList(2, 2, n) = limites(4, n)
    end do

    deLayout = ESMF_DELayoutCreate(petMap=petMap, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(nome)// &
        ': falha DELayoutCreate', line=__LINE__, file=u_FILE_u)) return

    distGrid = ESMF_DistGridCreate(minIndex=(/1, 1/), maxIndex=(/ni, nj/), &
                 deBlockList=deBlockList, delayout=deLayout, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(nome)// &
        ': falha DistGridCreate', line=__LINE__, file=u_FILE_u)) return

    grade = ESMF_GridCreate(distgrid=distGrid,               &
              coordSys=ESMF_COORDSYS_SPH_DEG,                &
              gridEdgeLWidth=(/0,0/), gridEdgeUWidth=(/0,0/),&
              rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(nome)// &
        ': falha GridCreate', line=__LINE__, file=u_FILE_u)) return

    call ESMF_GridAddCoord(grade, staggerLoc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(nome)// &
        ': falha GridAddCoord', line=__LINE__, file=u_FILE_u)) return
  end subroutine cpl_malha_de_blocos

  ! --------------------------------------------------------------------------
  ! Partes comuns aos construtores
  ! --------------------------------------------------------------------------

  !> Cria a grade periódica em longitude, com índices globais e coordenadas
  !! esféricas em graus: nos blocos dados ou, sem eles, na decomposição
  !! cpl_regdecomp de nx x ny em petCount PETs.
  subroutine cria_grade(grade, nx, ny, petCount, rc, blocos)
    type(ESMF_Grid),    intent(out) :: grade
    integer,            intent(in)  :: nx, ny, petCount
    integer,            intent(out) :: rc
    type(cpl_blocos_t), intent(in), optional :: blocos
    integer :: regDecomp(2)

    if (present(blocos)) then
      grade = ESMF_GridCreate1PeriDim(countsPerDEDim1=blocos%cntx, &
        countsPerDEDim2=blocos%cnty, periodicDim=1, petMap=blocos%pmap, &
        indexflag=ESMF_INDEX_GLOBAL, coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    else
      regDecomp = cpl_regdecomp(petCount, nx, ny)
      grade = ESMF_GridCreate1PeriDim(minIndex=(/1,1/), maxIndex=(/nx, ny/), &
        regDecomp=regDecomp, periodicDim=1, indexflag=ESMF_INDEX_GLOBAL, &
        coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    end if
  end subroutine cria_grade

  !> Acrescenta as coordenadas no stagger dado (chamada coletiva, todos os
  !! PETs) e devolve o número de DEs locais.
  subroutine prepara_coordenadas(grade, stagger, localDeCount, rc)
    type(ESMF_Grid),       intent(inout) :: grade
    type(ESMF_StaggerLoc), intent(in)    :: stagger
    integer,               intent(out)   :: localDeCount
    integer,               intent(out)   :: rc

    localDeCount = 0
    call ESMF_GridAddCoord(grade, staggerloc=stagger, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_GridGet(grade, localDeCount=localDeCount, rc=rc)
  end subroutine prepara_coordenadas

  !> Vetores das duas coordenadas do DE local lde, no stagger dado.
  !! ESMF_GridGetCoord é local e exige localDE= quando o PET tem mais de um
  !! DE.
  subroutine coordenadas_do_de(grade, stagger, lde, coordX, coordY, rc)
    type(ESMF_Grid),       intent(in)  :: grade
    type(ESMF_StaggerLoc), intent(in)  :: stagger
    integer,               intent(in)  :: lde
    real(r8), pointer                  :: coordX(:,:), coordY(:,:)
    integer,               intent(out) :: rc

    call ESMF_GridGetCoord(grade, coordDim=1, localDE=lde, &
      staggerloc=stagger, farrayPtr=coordX, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_GridGetCoord(grade, coordDim=2, localDE=lde, &
      staggerloc=stagger, farrayPtr=coordY, rc=rc)
  end subroutine coordenadas_do_de

  !> A partir dos blocos de todos os PETs (início e fim globais em i e em j,
  !! na ordem dos PETs), monta a decomposição retangular que o ESMF precisa:
  !! tamanho de cada coluna (cntx), de cada linha (cnty) e o PET dono de cada
  !! bloco (pmap). Confere que os blocos formam uma grade produto (layout
  !! nbx x nby), cobrem 1..nx e 1..ny sem buraco nem sobreposição, e que cada
  !! bloco pertence a exatamente um PET. limites(1:4, p) = (/ is, ie, js, je /)
  !! do PET p-1. Com ok = .false., msg diz o que não confere.
  subroutine cpl_blocos_de_limites(limites, npet, nx, ny, blocos, msg, ok)
    integer,            intent(in)  :: limites(:,:)
    integer,            intent(in)  :: npet, nx, ny
    type(cpl_blocos_t), intent(out) :: blocos
    character(len=*),   intent(out) :: msg
    logical,            intent(out) :: ok

    integer, allocatable :: xs(:), xe(:), ys(:), ye(:)
    integer :: p, k, nbx, nby, ix, iy
    logical :: novo

    ok  = .false.
    msg = ''
    allocate(xs(npet), xe(npet), ys(npet), ye(npet))
    nbx = 0 ; nby = 0

    ! colunas e linhas distintas (pelo início), com o fim correspondente
    do p = 1, npet
      novo = .true.
      do k = 1, nbx
        if (xs(k) == limites(1,p)) then
          novo = .false.
          if (xe(k) /= limites(2,p)) then
            write(msg,'(a,i0,a)') 'colunas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (novo) then ; nbx = nbx + 1 ; xs(nbx) = limites(1,p) ; xe(nbx) = limites(2,p) ; end if
      novo = .true.
      do k = 1, nby
        if (ys(k) == limites(3,p)) then
          novo = .false.
          if (ye(k) /= limites(4,p)) then
            write(msg,'(a,i0,a)') 'linhas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (novo) then ; nby = nby + 1 ; ys(nby) = limites(3,p) ; ye(nby) = limites(4,p) ; end if
    end do

    if (nbx * nby /= npet) then
      write(msg,'(a,i0,a,i0,a,i0,a)') 'layout ', nbx, ' x ', nby, ' nao corresponde a ', npet, &
        ' PETs (blocos mascarados ou decomposicao nao retangular?)'
      return
    end if

    call ordena(xs(1:nbx), xe(1:nbx))
    call ordena(ys(1:nby), ye(1:nby))

    ! cobertura contígua de 1..nx e 1..ny
    if (xs(1) /= 1 .or. xe(nbx) /= nx .or. ys(1) /= 1 .or. ye(nby) /= ny) then
      write(msg,'(a,4(i0,a))') 'blocos nao cobrem a grade: i ', xs(1), '..', xe(nbx), &
        ', j ', ys(1), '..', ye(nby)
      return
    end if
    do k = 1, nbx - 1
      if (xs(k+1) /= xe(k) + 1) then ; msg = 'colunas com buraco ou sobreposicao' ; return ; end if
    end do
    do k = 1, nby - 1
      if (ys(k+1) /= ye(k) + 1) then ; msg = 'linhas com buraco ou sobreposicao' ; return ; end if
    end do

    allocate(blocos%cntx(nbx), blocos%cnty(nby), blocos%pmap(nbx, nby, 1))
    blocos%cntx = xe(1:nbx) - xs(1:nbx) + 1
    blocos%cnty = ye(1:nby) - ys(1:nby) + 1
    blocos%pmap = -1
    do p = 1, npet
      ix = findloc(xs(1:nbx), limites(1,p), dim=1)
      iy = findloc(ys(1:nby), limites(3,p), dim=1)
      if (blocos%pmap(ix, iy, 1) /= -1) then
        write(msg,'(a,i0,a,i0)') 'bloco atribuido a dois PETs: ', blocos%pmap(ix,iy,1), ' e ', p-1
        return
      end if
      blocos%pmap(ix, iy, 1) = p - 1
    end do
    ok = .true.

  contains

    pure subroutine ordena(a, b)
      integer, intent(inout) :: a(:), b(:)
      integer :: i, j, ta, tb
      do i = 2, size(a)
        ta = a(i) ; tb = b(i) ; j = i - 1
        do while (j >= 1)
          if (a(j) <= ta) exit
          a(j+1) = a(j) ; b(j+1) = b(j) ; j = j - 1
        end do
        a(j+1) = ta ; b(j+1) = tb
      end do
    end subroutine ordena

  end subroutine cpl_blocos_de_limites

  ! --------------------------------------------------------------------------
  ! Fórmulas de centro e de canto. Cada uma é a expressão que a malha usava,
  ! sem mudança na ordem das operações.
  ! --------------------------------------------------------------------------

  !> Longitude do centro da coluna i, a partir de 0 grau (atm_med).
  elemental function centro_lon_leste0(i, nx) result(lon)
    integer, intent(in) :: i, nx
    real(r8) :: lon
    lon = (i-1) * (360.0_r8/nx) + (360.0_r8/nx) * 0.5_r8
  end function centro_lon_leste0

  !> Latitude do centro da linha j, a partir de -90 graus (atm_med).
  elemental function centro_lat_leste0(j, ny) result(lat)
    integer, intent(in) :: j, ny
    real(r8) :: lat
    lat = -90.0_r8 + (j-1)*(180.0_r8/ny) + (180.0_r8/ny)/2.0_r8
  end function centro_lat_leste0

  !> Longitude do canto oeste da coluna i, a partir de 0 grau (atm_med).
  elemental function canto_lon_leste0(i, nx) result(lon)
    integer, intent(in) :: i, nx
    real(r8) :: lon
    lon = (i-1) * (360.0_r8/nx)
  end function canto_lon_leste0

  !> Latitude do canto sul da linha j, a partir de -90 graus (atm_med).
  elemental function canto_lat_leste0(j, ny) result(lat)
    integer, intent(in) :: j, ny
    real(r8) :: lat
    lat = -90.0_r8 + (j-1)*(180.0_r8/ny)
  end function canto_lat_leste0

  !> Longitude do centro da coluna i, a partir de -180 graus (atm_cap).
  elemental function centro_lon_oeste180(i, nx) result(lon)
    integer, intent(in) :: i, nx
    real(r8) :: lon
    lon = -180.0_r8 + (real(i,r8) - 0.5_r8)*(360.0_r8/nx)
  end function centro_lon_oeste180

  !> Latitude do centro da linha j, a partir de -90 graus (atm_cap).
  elemental function centro_lat_oeste180(j, ny) result(lat)
    integer, intent(in) :: j, ny
    real(r8) :: lat
    lat = -90.0_r8 + (real(j,r8) - 0.5_r8)*(180.0_r8/ny)
  end function centro_lat_oeste180

  ! --------------------------------------------------------------------------
  ! Fórmulas de índice: a caixa de largura d que contém x, contada a partir
  ! de x = 0 (quem chama soma a origem: lat + 90, por exemplo), limitada a
  ! [1, n]. Cada uma é a expressão que as rotinas usavam, sem mudança.
  ! --------------------------------------------------------------------------

  !> Índice por truncamento: int(x/d) + 1, limitado a [1, n]. Igual, para
  !! todo x, a floor(x/d) + 1 limitado a [1, n] (ver o cabeçalho).
  elemental function indice_trunca(x, d, n) result(k)
    real(r8), intent(in) :: x, d
    integer,  intent(in) :: n
    integer :: k
    k = int(x / d) + 1
    k = max(1, min(k, n))
  end function indice_trunca

  !> Índice pelo inteiro mais próximo: nint(x/d) + 1, limitado a [1, n].
  elemental function indice_arredonda(x, d, n) result(k)
    real(r8), intent(in) :: x, d
    integer,  intent(in) :: n
    integer :: k
    k = nint(x / d) + 1
    k = min(max(k, 1), n)
  end function indice_arredonda

  ! --------------------------------------------------------------------------
  ! Longitude numa faixa de 360 graus
  ! --------------------------------------------------------------------------

  !> Longitude em [0, 360) pelo piso.
  elemental function lon_0a360_piso(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon - floor(lon / 360.0_r8) * 360.0_r8
  end function lon_0a360_piso

  !> Longitude em [-180, 180) pelo piso.
  elemental function lon_m180a180_piso(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon - floor((lon + 180.0_r8) / 360.0_r8) * 360.0_r8
  end function lon_m180a180_piso

  !> Longitude em [0, 360), somando ou subtraindo 360 quantas vezes for
  !! preciso (primeiro as somas).
  elemental function lon_0a360_laco(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon
    do while (l <   0.0_r8); l = l + 360.0_r8; end do
    do while (l >= 360.0_r8); l = l - 360.0_r8; end do
  end function lon_0a360_laco

  !> Longitude em [-180, 180), subtraindo ou somando 360 quantas vezes for
  !! preciso (primeiro as subtrações).
  elemental function lon_m180a180_laco(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon
    do while (l >= 180.0_r8);  l = l - 360.0_r8; end do
    do while (l < -180.0_r8);  l = l + 360.0_r8; end do
  end function lon_m180a180_laco

end module cpl_grids_mod
