!> @file cpl_grids.F90
!! @brief Construção das malhas regulares (latitude e longitude) do acoplamento.
!!
!! As malhas descritas em MALHAS (cpl_map.F90) são construídas aqui. Por
!! enquanto, as duas grades regulares do lado atmosférico:
!!
!!   atm_cap   grade do cap do MONAN-A (mpas_cap_methods::mpas_create_grid),
!!             centros com longitude a partir de -180 graus, sem cantos
!!   atm_med   malha de fluxo do mediador (med_init::create_atm_grid),
!!             centros com longitude a partir de 0 grau, com cantos (o
!!             método conservativo exige os cantos)
!!
!! As duas usam a mesma decomposição (cpl_regdecomp), a mesma chamada
!! ESMF_GridCreate1PeriDim (periódica em longitude, índices globais,
!! coordenadas esféricas em graus) e o mesmo laço sobre os DEs locais. As
!! fórmulas de centro e de canto ficam em funções, uma por regra: as duas
!! malhas calculam o centro com expressões diferentes, e cada função
!! reproduz a sua expressão sem mudança, para que nenhum bit mude.
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

  implicit none
  private

  public :: cpl_regdecomp, cpl_malha_latlon
  public :: centro_lon_leste0, centro_lat_leste0, canto_lon_leste0, canto_lat_leste0
  public :: centro_lon_oeste180, centro_lat_oeste180
  public :: indice_trunca, indice_arredonda
  public :: lon_0a360_piso, lon_m180a180_piso, lon_0a360_laco, lon_m180a180_laco
  public :: ORIGEM_LESTE0, ORIGEM_OESTE180

  integer, parameter :: r8 = ESMF_KIND_R8

  !> Longitude da primeira coluna: a partir de 0 grau, para leste, ou a
  !! partir de -180 graus.
  character(len=*), parameter :: ORIGEM_LESTE0   = 'leste0'
  character(len=*), parameter :: ORIGEM_OESTE180 = 'oeste180'

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
  !! cantos = .true., também as dos cantos (só na origem ORIGEM_LESTE0).
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
  !! @param[in]  origem_lon  ORIGEM_LESTE0 ou ORIGEM_OESTE180
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
    integer :: regDecomp(2), localDeCount, lde, i, j
    logical :: leste0

    rc = ESMF_SUCCESS
    nullify(coordX, coordY)

    leste0 = origem_lon == ORIGEM_LESTE0
    if (.not. leste0 .and. origem_lon /= ORIGEM_OESTE180) then
      call ESMF_LogSetError(ESMF_RC_ARG_VALUE, msg='cpl_malha_latlon: '//trim(nome)// &
           ': origem de longitude desconhecida: '//trim(origem_lon), &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if
    if (cantos .and. .not. leste0) then
      call ESMF_LogSetError(ESMF_RC_ARG_VALUE, msg='cpl_malha_latlon: '//trim(nome)// &
           ': cantos so com a origem '//ORIGEM_LESTE0, &
           line=__LINE__, file=u_FILE_u, rcToReturn=rc)
      return
    end if

    regDecomp = cpl_regdecomp(petCount, nx, ny)
    grade = ESMF_GridCreate1PeriDim(minIndex=(/1,1/), maxIndex=(/nx, ny/), &
      regDecomp=regDecomp, indexflag=ESMF_INDEX_GLOBAL, &
      coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call ESMF_GridAddCoord(grade, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_GridGet(grade, localDeCount=localDeCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    do lde = 0, localDeCount - 1
      call ESMF_GridGetCoord(grade, coordDim=1, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          if (leste0) then
            coordX(i,j) = centro_lon_leste0(i, nx)
          else
            coordX(i,j) = centro_lon_oeste180(i, nx)
          end if
        end do
      end do
      call ESMF_GridGetCoord(grade, coordDim=2, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
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
    call ESMF_GridAddCoord(grade, staggerloc=ESMF_STAGGERLOC_CORNER, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    do lde = 0, localDeCount - 1
      call ESMF_GridGetCoord(grade, coordDim=1, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordX, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          coordX(i,j) = canto_lon_leste0(i, nx)
        end do
      end do
      call ESMF_GridGetCoord(grade, coordDim=2, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordY, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          coordY(i,j) = canto_lat_leste0(j, ny)
        end do
      end do
    end do
  end subroutine cpl_malha_latlon

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
