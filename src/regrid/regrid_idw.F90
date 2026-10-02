!> @file regrid_idw.F90
!! @brief Esquema 'idw' (inverso da distância), modelo de esquema de pesos.
!!
!! Este arquivo serve de modelo para escrever um esquema de interpolação
!! novo. Para criar o seu:
!!   1. copie este arquivo para src/regrid/regrid_<nome>.F90 e troque idw
!!      pelo nome do esquema no módulo, no tipo e no construtor;
!!   2. escreva calcula_pesos: só arrays do Fortran, sem ESMF (a base,
!!      weights_regridder_t, faz o resto: route handle, reprodutibilidade e
!!      liberação);
!!   3. leia as opções com regrid_option_real e regrid_option_int, e recuse
!!      as desconhecidas com regrid_options_check;
!!   4. acrescente uma linha na lista de regrid_schemes.F90, e o arquivo no
!!      Makefile (SRCS e dependências);
!!   5. confira com tests/regrid/compara-esquema.bash <nome> '<opções>'.
!! Depois, o esquema pode ser escolhido numa rota pela tabela ROTAS (coluna
!! esquema) ou só pelo nuopc.input (&nuopc_regrid: regrid_scheme e
!! regrid_options).
!!
!! O método. Cada ponto de destino recebe a média dos vizinhos de origem
!! válidos mais próximos, com peso 1/d^p, normalizada (os pesos somam 1):
!!   vizinhos = número de vizinhos (padrão 4)
!!   expoente = p (padrão 2)
!! A distância é a da corda entre os pontos na esfera de raio 1, que cresce
!! com a distância sobre a esfera e dá a mesma ordem dos vizinhos. Um ponto
!! de destino que coincide com um ponto de origem recebe só o valor dele.
!! Empates na distância ficam com o ponto de menor índice global, o que
!! torna os pesos independentes da decomposição em PETs.
!!
!! O cálculo é direto (todos os pontos de origem para cada ponto de
!! destino); serve para grades de teste e para malhas pequenas. Um esquema
!! para malhas grandes precisaria de uma busca por vizinhança (árvore k-d).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_idw_mod

  use ESMF,                    only : ESMF_KIND_R8, ESMF_SUCCESS, ESMF_FAILURE, &
                                      ESMF_LogWrite, ESMF_LOGMSG_ERROR
  use regrid_base_mod,         only : regridder_t, regrid_option_real, regrid_option_int, &
                                      regrid_options_check, NAME_LEN
  use regrid_weights_base_mod, only : weights_regridder_t, regrid_pontos_t
  use coupler_constants_mod,   only : DEG2RAD

  implicit none
  private

  public :: idw_regridder_t
  public :: new_idw

  !> Opções aceitas pelo esquema.
  character(len=NAME_LEN), parameter :: OPCOES_IDW(2) = &
    [character(len=NAME_LEN) :: 'vizinhos', 'expoente']

  type, extends(weights_regridder_t) :: idw_regridder_t
  contains
    procedure :: calcula_pesos => idw_calcula_pesos
  end type idw_regridder_t

contains

  !> Construtor usado pela lista de esquemas (regrid_schemes.F90).
  subroutine new_idw(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(idw_regridder_t :: r)
  end subroutine new_idw

  subroutine idw_calcula_pesos(this, origem, destino, fator, orig, dest, rc)
    class(idw_regridder_t),          intent(inout) :: this
    type(regrid_pontos_t),           intent(in)    :: origem, destino
    real(ESMF_KIND_R8), allocatable, intent(out)   :: fator(:)
    integer,            allocatable, intent(out)   :: orig(:), dest(:)
    integer,                         intent(out)   :: rc

    real(ESMF_KIND_R8), allocatable :: xo(:), yo(:), zo(:), dmelhor(:), w(:)
    integer,            allocatable :: kmelhor(:)
    real(ESMF_KIND_R8) :: expoente, xd, yd, zd, d2
    integer :: vizinhos, nvalidos, i, n, k, m, nk

    ! 1. opções
    call regrid_options_check(this%spec%options, OPCOES_IDW, rc)
    if (rc /= ESMF_SUCCESS) return
    call regrid_option_int(this%spec%options, 'vizinhos', 4, vizinhos, rc)
    if (rc /= ESMF_SUCCESS) return
    call regrid_option_real(this%spec%options, 'expoente', 2.0_ESMF_KIND_R8, expoente, rc)
    if (rc /= ESMF_SUCCESS) return
    nvalidos = count(origem%valido)
    if (vizinhos < 1 .or. expoente < 0.0_ESMF_KIND_R8 .or. nvalidos == 0) then
      call ESMF_LogWrite('regrid: idw: vizinhos < 1, expoente < 0 ou origem sem pontos validos', &
        ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if
    vizinhos = min(vizinhos, nvalidos)
    this%method_used = 'idw'

    ! 2. pontos de origem na esfera de raio 1
    call na_esfera(origem%lon, origem%lat, xo, yo, zo)

    ! 3. para cada destino, os vizinhos mais próximos e os pesos
    n = size(destino%indice)
    allocate(fator(n*vizinhos), orig(n*vizinhos), dest(n*vizinhos))
    allocate(dmelhor(vizinhos), kmelhor(vizinhos), w(vizinhos))
    m = 0
    do i = 1, n
      xd = cos(destino%lat(i)*DEG2RAD) * cos(destino%lon(i)*DEG2RAD)
      yd = cos(destino%lat(i)*DEG2RAD) * sin(destino%lon(i)*DEG2RAD)
      zd = sin(destino%lat(i)*DEG2RAD)
      dmelhor = huge(1.0_ESMF_KIND_R8)
      kmelhor = 0
      do k = 1, size(origem%indice)
        if (.not. origem%valido(k)) cycle
        d2 = (xo(k) - xd)**2 + (yo(k) - yd)**2 + (zo(k) - zd)**2
        if (d2 < dmelhor(vizinhos)) call insere(d2, k, dmelhor, kmelhor)
      end do
      if (dmelhor(1) == 0.0_ESMF_KIND_R8) then
        nk = 1
        w(1) = 1.0_ESMF_KIND_R8
      else
        nk = vizinhos
        w(1:nk) = 1.0_ESMF_KIND_R8 / sqrt(dmelhor(1:nk))**expoente
        w(1:nk) = w(1:nk) / sum(w(1:nk))
      end if
      do k = 1, nk
        m = m + 1
        fator(m) = w(k)
        orig(m)  = origem%indice(kmelhor(k))
        dest(m)  = destino%indice(i)
      end do
    end do
    fator = fator(1:m)
    orig  = orig(1:m)
    dest  = dest(1:m)
    rc = ESMF_SUCCESS
  end subroutine idw_calcula_pesos

  !> Coordenadas cartesianas na esfera de raio 1.
  subroutine na_esfera(lon, lat, x, y, z)
    real(ESMF_KIND_R8),              intent(in)  :: lon(:), lat(:)
    real(ESMF_KIND_R8), allocatable, intent(out) :: x(:), y(:), z(:)
    x = cos(lat*DEG2RAD) * cos(lon*DEG2RAD)
    y = cos(lat*DEG2RAD) * sin(lon*DEG2RAD)
    z = sin(lat*DEG2RAD)
  end subroutine na_esfera

  !> Insere (d, k) na lista dos melhores, ordenada pela distância; com
  !! distância igual, o que já estava (de menor índice) fica na frente.
  subroutine insere(d, k, dmelhor, kmelhor)
    real(ESMF_KIND_R8), intent(in)    :: d
    integer,            intent(in)    :: k
    real(ESMF_KIND_R8), intent(inout) :: dmelhor(:)
    integer,            intent(inout) :: kmelhor(:)
    integer :: j

    j = size(dmelhor)
    do while (j > 1)
      if (dmelhor(j-1) <= d) exit
      dmelhor(j) = dmelhor(j-1)
      kmelhor(j) = kmelhor(j-1)
      j = j - 1
    end do
    dmelhor(j) = d
    kmelhor(j) = k
  end subroutine insere

end module regrid_idw_mod
