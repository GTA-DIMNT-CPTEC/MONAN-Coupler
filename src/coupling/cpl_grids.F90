!> @file cpl_grids.F90
!! @brief Construção das malhas do acoplamento e fórmulas das grades regulares.
!!
!! As malhas descritas em GRIDS (cpl_map.F90) são construídas aqui:
!!
!!   atm_cap   grade do cap do MONAN-A (mpas_adapter::mpas_create_grid),
!!             regular, centros com longitude a partir de -180 graus, sem
!!             cantos (cpl_latlon_grid)
!!   atm_med   malha de fluxo do mediador (med_init::create_atm_grid),
!!             regular, centros com longitude a partir de 0 grau, com cantos
!!             (o método conservativo exige os cantos) (cpl_latlon_grid)
!!   ocn_med   oceano no mediador (med_init::create_ocn_grid): com o MOM6, a
!!             grade tripolar lida do supergrid, com cantos
!!             (cpl_tripolar_grid); com o DOCN, regular, com a longitude do
!!             centro no canto oeste da célula (cpl_latlon_grid,
!!             ORIGIN_EAST0_CORNER)
!!   ice_sis2  grade do cap do SIS2 (sis_cap_MONAN::create_ice_grid),
!!             tripolar, nos blocos do domínio do SIS2, sem cantos
!!             (cpl_tripolar_grid com cpl_blocks_t)
!!   ocn_mom6  grade do cap do MOM6 (mom_cap_MONAN::create_ocean_grid), nos
!!             blocos do domínio do MOM6, com as coordenadas que o cap copia
!!             do modelo (cpl_block_grid)
!!
!! As quatro primeiras são periódicas em longitude (periodicDim = 1, o
!! padrão do ESMF), com índices globais e coordenadas esféricas em graus,
!! sem polo declarado. Sem blocos, a decomposição é cpl_regdecomp, um DE por
!! PET; com blocos (cpl_blocks_t, montados por cpl_blocks_from_bounds), cada
!! bloco vai ao PET que o tem no modelo.
!!
!! A grade do cap do MOM6 é diferente, e continua como era: criada sobre um
!! DistGrid com a lista de blocos do MOM6 (deBlockList, que aceita
!! qualquer conjunto de blocos retangulares), sem periodicidade declarada e
!! com os índices locais de cada DE (o padrão do ESMF). Não pode ser feita
!! por cpl_tripolar_grid sem mudar resultados: a periodicidade muda os
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
!!   index_trunc        int(x/d) + 1        binning e cópia do cap, leitura
!!                                          da importação no cap, OISST e
!!                                          diagnóstico da importação
!!   index_round        nint(x/d) + 1       diagnóstico da exportação
!!   lon_0to360_floor   lon - floor(lon/360)*360          binning do cap
!!   lon_m180to180_floor lon - floor((lon+180)/360)*360    importação no cap
!!   lon_0to360_loop    soma ou subtrai 360 até [0, 360)  OISST no cap do MOM6
!!   lon_m180to180_loop soma ou subtrai 360 até [-180, 180)  diagnósticos
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

  public :: cpl_regdecomp, cpl_latlon_grid, cpl_tripolar_grid, cpl_blocks_from_bounds
  public :: cpl_block_grid
  public :: center_lon_east0, center_lat_east0, corner_lon_east0, corner_lat_east0
  public :: center_lon_west180, center_lat_west180
  public :: index_trunc, index_round
  public :: lon_0to360_floor, lon_m180to180_floor, lon_0to360_loop, lon_m180to180_loop
  public :: ORIGIN_EAST0, ORIGIN_WEST180, ORIGIN_EAST0_CORNER

  integer, parameter :: r8 = ESMF_KIND_R8

  !> Longitude da primeira coluna: a partir de 0 grau, para leste, ou a
  !! partir de -180 graus.
  character(len=*), parameter :: ORIGIN_EAST0    = 'leste0'
  character(len=*), parameter :: ORIGIN_WEST180 = 'oeste180'
  !> Como ORIGIN_EAST0, mas com a longitude do centro igual à do canto
  !! oeste da célula, (i-1)*360/nx, sem a meia célula: é como o mediador
  !! descreve a grade do DOCN (ocn_med com use_docn). A latitude do centro e
  !! os cantos são os de ORIGIN_EAST0.
  character(len=*), parameter :: ORIGIN_EAST0_CORNER = 'leste0_canto'

  !> Decomposição em blocos retangulares, um por PET: número de colunas de
  !! cada coluna de blocos (cntx), de linhas de cada linha de blocos (cnty)
  !! e o PET dono de cada bloco (pmap(ix, iy, 1)), na forma que
  !! ESMF_GridCreate1PeriDim recebe (countsPerDEDim1, countsPerDEDim2, petMap).
  type, public :: cpl_blocks_t
    integer, allocatable :: cntx(:), cnty(:), pmap(:,:,:)
  end type cpl_blocks_t

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
  !! cantos = .true., também as dos cantos (só nas origens ORIGIN_EAST0 e
  !! ORIGIN_EAST0_CORNER).
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
  !! @param[in]  nome        nome da malha em GRIDS, para as mensagens
  !! @param[in]  nx, ny      pontos em longitude e em latitude
  !! @param[in]  lon_origin  ORIGIN_EAST0, ORIGIN_EAST0_CORNER ou ORIGIN_WEST180
  !! @param[in]  cantos      cria também as coordenadas dos cantos
  !! @param[in]  petCount    PETs do componente
  !! @param[out] grade       a grade criada
  !! @param[out] rc          ESMF_SUCCESS, ou o código da falha
  subroutine cpl_latlon_grid(name, nx, ny, lon_origin, corners, petCount, grid, rc)
    character(len=*), intent(in)  :: name
    integer,          intent(in)  :: nx, ny
    character(len=*), intent(in)  :: lon_origin
    logical,          intent(in)  :: corners
    integer,          intent(in)  :: petCount
    type(ESMF_Grid),  intent(out) :: grid
    integer,          intent(out) :: rc

    real(r8), pointer :: coordX(:,:), coordY(:,:)
    integer :: localDeCount, lde, i, j
    logical :: east0, corner

    rc = ESMF_SUCCESS
    nullify(coordX, coordY)

    corner = lon_origin == ORIGIN_EAST0_CORNER
    east0 = lon_origin == ORIGIN_EAST0 .or. corner
    if (.not. east0 .and. lon_origin /= ORIGIN_WEST180) then
      call ESMF_LogSetError(ESMF_RC_ARG_VALUE, msg='cpl_malha_latlon: '//trim(name)// &
           ': origem de longitude desconhecida: '//trim(lon_origin), &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if
    if (corners .and. .not. east0) then
      call ESMF_LogSetError(ESMF_RC_ARG_VALUE, msg='cpl_malha_latlon: '//trim(name)// &
           ': cantos so com as origens '//ORIGIN_EAST0//' e '//ORIGIN_EAST0_CORNER, &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if

    call create_grid(grid, nx, ny, petCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call prepare_coordinates(grid, ESMF_STAGGERLOC_CENTER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call de_coordinates(grid, ESMF_STAGGERLOC_CENTER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          if (corner) then
            coordX(i,j) = corner_lon_east0(i, nx)
          else if (east0) then
            coordX(i,j) = center_lon_east0(i, nx)
          else
            coordX(i,j) = center_lon_west180(i, nx)
          end if
        end do
      end do
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          if (east0) then
            coordY(i,j) = center_lat_east0(j, ny)
          else
            coordY(i,j) = center_lat_west180(j, ny)
          end if
        end do
      end do
    end do

    if (.not. corners) return

    ! Cantos: a borda da célula, meia célula antes do centro, por conta
    ! direta (a grade é regular), sem ler arquivo.
    call prepare_coordinates(grid, ESMF_STAGGERLOC_CORNER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call de_coordinates(grid, ESMF_STAGGERLOC_CORNER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          coordX(i,j) = corner_lon_east0(i, nx)
        end do
      end do
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          coordY(i,j) = corner_lat_east0(j, ny)
        end do
      end do
    end do
  end subroutine cpl_latlon_grid


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
  !! @param[in]  nome          nome da malha em GRIDS, para as mensagens
  !! @param[in]  arquivo       supergrid do MOM6
  !! @param[in]  nx, ny        tamanho da grade T (sem blocos)
  !! @param[in]  petCount      PETs do componente (sem blocos)
  !! @param[in]  cantos        cria também as coordenadas dos cantos
  !! @param[out] grade         a grade criada
  !! @param[out] rc            ESMF_SUCCESS, ou o código da falha
  !! @param[in]  blocos        decomposição do modelo (opcional)
  !! @param[in]  comp          marca do componente nas mensagens da leitura
  !!                           do supergrid (padrão: OCN)
  subroutine cpl_tripolar_grid(name, file_name, nx, ny, petCount, corners, grid, rc, &
                                blocks, comp)
    character(len=*),   intent(in)  :: name
    character(len=*),   intent(in)  :: file_name
    integer,            intent(in)  :: nx, ny
    integer,            intent(in)  :: petCount
    logical,            intent(in)  :: corners
    type(ESMF_Grid),    intent(out) :: grid
    integer,            intent(out) :: rc
    type(cpl_blocks_t), intent(in), optional :: blocks
    character(len=*),   intent(in), optional :: comp

    real(r8), pointer :: coordX(:,:), coordY(:,:)
    integer :: localDeCount, lde

    rc = ESMF_SUCCESS
    nullify(coordX, coordY)

    call create_grid(grid, nx, ny, petCount, rc, blocks)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call prepare_coordinates(grid, ESMF_STAGGERLOC_CENTER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call de_coordinates(grid, ESMF_STAGGERLOC_CENTER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      call mom6_supergrid_tcoords(trim(file_name), coordX, coordY, rc, comp=comp)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_tripolar: '//trim(name)// &
          ': falha ao ler os centros de '//trim(file_name), line=__LINE__, file=u_FILE_u)) return
    end do

    if (.not. corners) return

    call prepare_coordinates(grid, ESMF_STAGGERLOC_CORNER, localDeCount, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call de_coordinates(grid, ESMF_STAGGERLOC_CORNER, lde, coordX, coordY, rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      call mom6_supergrid_corners(trim(file_name), coordX, coordY, rc, comp=comp)
      if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_tripolar: '//trim(name)// &
          ': falha ao ler os cantos de '//trim(file_name), line=__LINE__, file=u_FILE_u)) return
    end do
  end subroutine cpl_tripolar_grid

  !> Cria a grade do cap do MOM6 nos blocos do modelo: um DE por bloco,
  !! no PET dado, sobre um DistGrid [1..ni] x [1..nj] com a lista de blocos
  !! (deBlockList, que aceita qualquer conjunto de blocos retangulares, até
  !! um PET sem oceano), sem margem de halo (gridEdgeLWidth e gridEdgeUWidth
  !! nulos), sem periodicidade declarada e com os índices locais de cada DE;
  !! acrescenta o stagger dos centros, sem preencher: as coordenadas são as
  !! do modelo, e quem chama as copia.
  !!
  !! @param[in]  nome      nome da malha em GRIDS, para as mensagens
  !! @param[in]  ni, nj    tamanho global da grade
  !! @param[in]  limites   (is, ie, js, je) globais de cada bloco
  !! @param[in]  petMap    PET de cada bloco (base 0)
  !! @param[out] grade     a grade criada
  !! @param[out] rc        ESMF_SUCCESS, ou o código da falha
  subroutine cpl_block_grid(name, ni, nj, bounds, petMap, grid, rc)
    character(len=*), intent(in)  :: name
    integer,          intent(in)  :: ni, nj
    integer,          intent(in)  :: bounds(:,:)
    integer,          intent(in)  :: petMap(:)
    type(ESMF_Grid),  intent(out) :: grid
    integer,          intent(out) :: rc

    type(ESMF_DistGrid) :: distGrid
    type(ESMF_DELayout) :: deLayout
    integer, allocatable :: deBlockList(:,:,:)
    integer :: n

    ! deBlockList(dim, início/fim, bloco): dim 1 é i, dim 2 é j
    allocate(deBlockList(2, 2, size(bounds, 2)))
    do n = 1, size(bounds, 2)
      deBlockList(1, 1, n) = bounds(1, n)
      deBlockList(1, 2, n) = bounds(2, n)
      deBlockList(2, 1, n) = bounds(3, n)
      deBlockList(2, 2, n) = bounds(4, n)
    end do

    deLayout = ESMF_DELayoutCreate(petMap=petMap, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(name)// &
        ': falha DELayoutCreate', line=__LINE__, file=u_FILE_u)) return

    distGrid = ESMF_DistGridCreate(minIndex=(/1, 1/), maxIndex=(/ni, nj/), &
                 deBlockList=deBlockList, delayout=deLayout, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(name)// &
        ': falha DistGridCreate', line=__LINE__, file=u_FILE_u)) return

    grid = ESMF_GridCreate(distgrid=distGrid,                &
              coordSys=ESMF_COORDSYS_SPH_DEG,                &
              gridEdgeLWidth=(/0,0/), gridEdgeUWidth=(/0,0/),&
              rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(name)// &
        ': falha GridCreate', line=__LINE__, file=u_FILE_u)) return

    call ESMF_GridAddCoord(grid, staggerLoc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='cpl_malha_de_blocos: '//trim(name)// &
        ': falha GridAddCoord', line=__LINE__, file=u_FILE_u)) return
  end subroutine cpl_block_grid

  ! --------------------------------------------------------------------------
  ! Partes comuns aos construtores
  ! --------------------------------------------------------------------------

  !> Cria a grade periódica em longitude, com índices globais e coordenadas
  !! esféricas em graus: nos blocos dados ou, sem eles, na decomposição
  !! cpl_regdecomp de nx x ny em petCount PETs.
  subroutine create_grid(grid, nx, ny, petCount, rc, blocks)
    type(ESMF_Grid),    intent(out) :: grid
    integer,            intent(in)  :: nx, ny, petCount
    integer,            intent(out) :: rc
    type(cpl_blocks_t), intent(in), optional :: blocks
    integer :: regDecomp(2)

    if (present(blocks)) then
      grid = ESMF_GridCreate1PeriDim(countsPerDEDim1=blocks%cntx, &
        countsPerDEDim2=blocks%cnty, periodicDim=1, petMap=blocks%pmap, &
        indexflag=ESMF_INDEX_GLOBAL, coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    else
      regDecomp = cpl_regdecomp(petCount, nx, ny)
      grid = ESMF_GridCreate1PeriDim(minIndex=(/1,1/), maxIndex=(/nx, ny/), &
        regDecomp=regDecomp, periodicDim=1, indexflag=ESMF_INDEX_GLOBAL, &
        coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    end if
  end subroutine create_grid

  !> Acrescenta as coordenadas no stagger dado (chamada coletiva, todos os
  !! PETs) e devolve o número de DEs locais.
  subroutine prepare_coordinates(grid, stagger, localDeCount, rc)
    type(ESMF_Grid),       intent(inout) :: grid
    type(ESMF_StaggerLoc), intent(in)    :: stagger
    integer,               intent(out)   :: localDeCount
    integer,               intent(out)   :: rc

    localDeCount = 0
    call ESMF_GridAddCoord(grid, staggerloc=stagger, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_GridGet(grid, localDeCount=localDeCount, rc=rc)
  end subroutine prepare_coordinates

  !> Vetores das duas coordenadas do DE local lde, no stagger dado.
  !! ESMF_GridGetCoord é local e exige localDE= quando o PET tem mais de um
  !! DE.
  subroutine de_coordinates(grid, stagger, lde, coordX, coordY, rc)
    type(ESMF_Grid),       intent(in)  :: grid
    type(ESMF_StaggerLoc), intent(in)  :: stagger
    integer,               intent(in)  :: lde
    real(r8), pointer                  :: coordX(:,:), coordY(:,:)
    integer,               intent(out) :: rc

    call ESMF_GridGetCoord(grid, coordDim=1, localDE=lde, &
      staggerloc=stagger, farrayPtr=coordX, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_GridGetCoord(grid, coordDim=2, localDE=lde, &
      staggerloc=stagger, farrayPtr=coordY, rc=rc)
  end subroutine de_coordinates

  !> A partir dos blocos de todos os PETs (início e fim globais em i e em j,
  !! na ordem dos PETs), monta a decomposição retangular que o ESMF precisa:
  !! tamanho de cada coluna (cntx), de cada linha (cnty) e o PET dono de cada
  !! bloco (pmap). Confere que os blocos formam uma grade produto (layout
  !! nbx x nby), cobrem 1..nx e 1..ny sem buraco nem sobreposição, e que cada
  !! bloco pertence a exatamente um PET. limites(1:4, p) = (/ is, ie, js, je /)
  !! do PET p-1. Com ok = .false., msg diz o que não confere.
  subroutine cpl_blocks_from_bounds(bounds, npet, nx, ny, blocks, msg, ok)
    integer,            intent(in)  :: bounds(:,:)
    integer,            intent(in)  :: npet, nx, ny
    type(cpl_blocks_t), intent(out) :: blocks
    character(len=*),   intent(out) :: msg
    logical,            intent(out) :: ok

    integer, allocatable :: xs(:), xe(:), ys(:), ye(:)
    integer :: p, k, nbx, nby, ix, iy
    logical :: is_new

    ok  = .false.
    msg = ''
    allocate(xs(npet), xe(npet), ys(npet), ye(npet))
    nbx = 0 ; nby = 0

    ! colunas e linhas distintas (pelo início), com o fim correspondente
    do p = 1, npet
      is_new = .true.
      do k = 1, nbx
        if (xs(k) == bounds(1,p)) then
          is_new = .false.
          if (xe(k) /= bounds(2,p)) then
            write(msg,'(a,i0,a)') 'colunas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (is_new) then ; nbx = nbx + 1 ; xs(nbx) = bounds(1,p) ; xe(nbx) = bounds(2,p) ; end if
      is_new = .true.
      do k = 1, nby
        if (ys(k) == bounds(3,p)) then
          is_new = .false.
          if (ye(k) /= bounds(4,p)) then
            write(msg,'(a,i0,a)') 'linhas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (is_new) then ; nby = nby + 1 ; ys(nby) = bounds(3,p) ; ye(nby) = bounds(4,p) ; end if
    end do

    if (nbx * nby /= npet) then
      write(msg,'(a,i0,a,i0,a,i0,a)') 'layout ', nbx, ' x ', nby, ' nao corresponde a ', npet, &
        ' PETs (blocos mascarados ou decomposicao nao retangular?)'
      return
    end if

    call sort_pairs(xs(1:nbx), xe(1:nbx))
    call sort_pairs(ys(1:nby), ye(1:nby))

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

    allocate(blocks%cntx(nbx), blocks%cnty(nby), blocks%pmap(nbx, nby, 1))
    blocks%cntx = xe(1:nbx) - xs(1:nbx) + 1
    blocks%cnty = ye(1:nby) - ys(1:nby) + 1
    blocks%pmap = -1
    do p = 1, npet
      ix = findloc(xs(1:nbx), bounds(1,p), dim=1)
      iy = findloc(ys(1:nby), bounds(3,p), dim=1)
      if (blocks%pmap(ix, iy, 1) /= -1) then
        write(msg,'(a,i0,a,i0)') 'bloco atribuido a dois PETs: ', blocks%pmap(ix,iy,1), ' e ', p-1
        return
      end if
      blocks%pmap(ix, iy, 1) = p - 1
    end do
    ok = .true.

  contains

    pure subroutine sort_pairs(a, b)
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
    end subroutine sort_pairs

  end subroutine cpl_blocks_from_bounds

  ! --------------------------------------------------------------------------
  ! Fórmulas de centro e de canto. Cada uma é a expressão que a malha usava,
  ! sem mudança na ordem das operações.
  ! --------------------------------------------------------------------------

  !> Longitude do centro da coluna i, a partir de 0 grau (atm_med).
  elemental function center_lon_east0(i, nx) result(lon)
    integer, intent(in) :: i, nx
    real(r8) :: lon
    lon = (i-1) * (360.0_r8/nx) + (360.0_r8/nx) * 0.5_r8
  end function center_lon_east0

  !> Latitude do centro da linha j, a partir de -90 graus (atm_med).
  elemental function center_lat_east0(j, ny) result(lat)
    integer, intent(in) :: j, ny
    real(r8) :: lat
    lat = -90.0_r8 + (j-1)*(180.0_r8/ny) + (180.0_r8/ny)/2.0_r8
  end function center_lat_east0

  !> Longitude do canto oeste da coluna i, a partir de 0 grau (atm_med).
  elemental function corner_lon_east0(i, nx) result(lon)
    integer, intent(in) :: i, nx
    real(r8) :: lon
    lon = (i-1) * (360.0_r8/nx)
  end function corner_lon_east0

  !> Latitude do canto sul da linha j, a partir de -90 graus (atm_med).
  elemental function corner_lat_east0(j, ny) result(lat)
    integer, intent(in) :: j, ny
    real(r8) :: lat
    lat = -90.0_r8 + (j-1)*(180.0_r8/ny)
  end function corner_lat_east0

  !> Longitude do centro da coluna i, a partir de -180 graus (atm_cap).
  elemental function center_lon_west180(i, nx) result(lon)
    integer, intent(in) :: i, nx
    real(r8) :: lon
    lon = -180.0_r8 + (real(i,r8) - 0.5_r8)*(360.0_r8/nx)
  end function center_lon_west180

  !> Latitude do centro da linha j, a partir de -90 graus (atm_cap).
  elemental function center_lat_west180(j, ny) result(lat)
    integer, intent(in) :: j, ny
    real(r8) :: lat
    lat = -90.0_r8 + (real(j,r8) - 0.5_r8)*(180.0_r8/ny)
  end function center_lat_west180

  ! --------------------------------------------------------------------------
  ! Fórmulas de índice: a caixa de largura d que contém x, contada a partir
  ! de x = 0 (quem chama soma a origem: lat + 90, por exemplo), limitada a
  ! [1, n]. Cada uma é a expressão que as rotinas usavam, sem mudança.
  ! --------------------------------------------------------------------------

  !> Índice por truncamento: int(x/d) + 1, limitado a [1, n]. Igual, para
  !! todo x, a floor(x/d) + 1 limitado a [1, n] (ver o cabeçalho).
  elemental function index_trunc(x, d, n) result(k)
    real(r8), intent(in) :: x, d
    integer,  intent(in) :: n
    integer :: k
    k = int(x / d) + 1
    k = max(1, min(k, n))
  end function index_trunc

  !> Índice pelo inteiro mais próximo: nint(x/d) + 1, limitado a [1, n].
  elemental function index_round(x, d, n) result(k)
    real(r8), intent(in) :: x, d
    integer,  intent(in) :: n
    integer :: k
    k = nint(x / d) + 1
    k = min(max(k, 1), n)
  end function index_round

  ! --------------------------------------------------------------------------
  ! Longitude numa faixa de 360 graus
  ! --------------------------------------------------------------------------

  !> Longitude em [0, 360) pelo piso.
  elemental function lon_0to360_floor(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon - floor(lon / 360.0_r8) * 360.0_r8
  end function lon_0to360_floor

  !> Longitude em [-180, 180) pelo piso.
  elemental function lon_m180to180_floor(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon - floor((lon + 180.0_r8) / 360.0_r8) * 360.0_r8
  end function lon_m180to180_floor

  !> Longitude em [0, 360), somando ou subtraindo 360 quantas vezes for
  !! preciso (primeiro as somas).
  elemental function lon_0to360_loop(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon
    do while (l <   0.0_r8); l = l + 360.0_r8; end do
    do while (l >= 360.0_r8); l = l - 360.0_r8; end do
  end function lon_0to360_loop

  !> Longitude em [-180, 180), subtraindo ou somando 360 quantas vezes for
  !! preciso (primeiro as subtrações).
  elemental function lon_m180to180_loop(lon) result(l)
    real(r8), intent(in) :: lon
    real(r8) :: l
    l = lon
    do while (l >= 180.0_r8);  l = l - 360.0_r8; end do
    do while (l < -180.0_r8);  l = l + 360.0_r8; end do
  end function lon_m180to180_loop

end module cpl_grids_mod
