!> @file regrid_mpassit.F90
!! @brief Esquema 'mpassit': interpolação da malha Voronoi do MPAS para uma
!! grade regular, com as regras do MPASSIT (MPAS Standard Interpolation Tool).
!!
!! O MPASSIT é um programa, não uma biblioteca: seu código guarda estado em
!! variáveis globais e não pode ser chamado de dentro do acoplador. Este
!! esquema reproduz o seu método, que é o que interessa ao acoplamento:
!!   1. a malha de origem é um ESMF_Mesh cujos elementos são as células de
!!      Voronoi do MPAS (vértices em verticesOnCell, coordenadas lonVertex e
!!      latVertex, centros lonCell e latCell), montado por mpas_mesh_create;
!!   2. o método depende da classe do campo: 'integer' usa vizinho mais
!!      próximo, 'accumulated' (neve, precipitação acumulada) usa
!!      conservativo e 'continuous' usa bilinear;
!!   3. pontos do destino não alcançados pela malha recebem um valor de
!!      ausência (spec%fill%vfill), como no fill_missing do MPASSIT.
!! Pesos gerados pelo próprio MPASSIT podem ser usados pelo esquema
!! 'weights_file'.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_mpassit_mod

  use ESMF
  use coupler_log_mod, only : COMP_REGRID, log_error, log_info
  use regrid_base_mod, only : regridder_t
  use regrid_esmf_mod, only : esmf_regridder_t, regrid_method_flag
  use coupler_constants_mod, only : RAD2DEG

  implicit none
  private

  public :: mpassit_regridder_t
  public :: mpas_mesh_create
  public :: mpassit_method
  public :: new_mpassit

  type, extends(esmf_regridder_t) :: mpassit_regridder_t
    !> Posições (i, j), contadas a partir de 1 no array local, dos pontos
    !! do destino não alcançados pela malha.
    integer, allocatable :: unmapped_i(:), unmapped_j(:)
  contains
    procedure :: setup   => mpassit_setup
    procedure :: execute => mpassit_execute
  end type mpassit_regridder_t

contains

  !> Construtor usado pela lista de esquemas (regrid_schemes.F90).
  subroutine new_mpassit(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(mpassit_regridder_t :: r)
  end subroutine new_mpassit

  !> Método do MPASSIT para cada classe de campo.
  pure function mpassit_method(field_class) result(method)
    character(len=*), intent(in) :: field_class
    character(len=16) :: method

    select case (trim(field_class))
    case ('integer');     method = 'nearest_stod'
    case ('accumulated'); method = 'conserve'
    case default;         method = 'bilinear'
    end select
  end function mpassit_method

  subroutine mpassit_setup(this, src, dst, rc)
    class(mpassit_regridder_t), intent(inout) :: this
    type(ESMF_Field),           intent(inout) :: src, dst
    integer,                    intent(out)   :: rc

    type(ESMF_RegridMethod_Flag) :: flag
    integer(ESMF_KIND_I4), pointer :: unmapped(:)
    integer :: srcTermProcessing

    this%method_used = mpassit_method(this%spec%field_class)
    call regrid_method_flag(this%method_used, flag, rc)
    if (rc /= ESMF_SUCCESS) return

    nullify(unmapped)
    srcTermProcessing = 0
    call ESMF_FieldRegridStore(srcField=src, dstField=dst, routehandle=this%rh, &
      regridmethod=flag, unmappedaction=ESMF_UNMAPPEDACTION_IGNORE,             &
      unmappedDstList=unmapped, extrapMethod=ESMF_EXTRAPMETHOD_NONE,            &
      srcTermProcessing=srcTermProcessing, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call local_positions(dst, unmapped, this%unmapped_i, this%unmapped_j, rc)
    if (associated(unmapped)) deallocate(unmapped)
    if (rc /= ESMF_SUCCESS) return

    this%ready = .true.
    call log_info(COMP_REGRID, 'rota '//trim(this%label)//' pronta, esquema mpassit, metodo '// &
      trim(this%method_used))
  end subroutine mpassit_setup

  subroutine mpassit_execute(this, src, dst, zero_total, rc)
    class(mpassit_regridder_t), intent(inout) :: this
    type(ESMF_Field),           intent(inout) :: src, dst
    logical,                    intent(in)    :: zero_total
    integer,                    intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: p(:,:)
    integer :: k

    call this%esmf_regridder_t%execute(src, dst, zero_total, rc)
    if (rc /= ESMF_SUCCESS .or. size(this%unmapped_i) == 0) return

    call ESMF_FieldGet(dst, farrayPtr=p, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    do k = 1, size(this%unmapped_i)
      p(lbound(p,1) + this%unmapped_i(k) - 1, lbound(p,2) + this%unmapped_j(k) - 1) = &
        this%spec%fill%vfill
    end do
  end subroutine mpassit_execute

  !> Converte índices sequenciais globais do destino (grade 2D) em posições
  !! do array local deste PET. Índices de outros PETs são descartados.
  subroutine local_positions(dst, seq, pos_i, pos_j, rc)
    type(ESMF_Field),               intent(in)  :: dst
    integer(ESMF_KIND_I4), pointer, intent(in)  :: seq(:)
    integer, allocatable,           intent(out) :: pos_i(:), pos_j(:)
    integer,                        intent(out) :: rc

    type(ESMF_Grid) :: grid
    integer :: lb(2), ub(2), maxIndex(2), localDeCount, k, n, ig, jg
    integer, allocatable :: ti(:), tj(:)

    allocate(pos_i(0), pos_j(0))
    rc = ESMF_SUCCESS
    if (.not. associated(seq)) return
    if (size(seq) == 0) return

    call ESMF_FieldGet(dst, grid=grid, localDeCount=localDeCount, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localDeCount == 0) return
    call ESMF_GridGet(grid, tile=1, staggerloc=ESMF_STAGGERLOC_CENTER, &
      maxIndex=maxIndex, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGetBounds(dst, exclusiveLBound=lb, exclusiveUBound=ub, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    allocate(ti(size(seq)), tj(size(seq)))
    n = 0
    do k = 1, size(seq)
      jg = (seq(k) - 1) / maxIndex(1) + 1
      ig = seq(k) - (jg - 1) * maxIndex(1)
      if (ig < lb(1) .or. ig > ub(1) .or. jg < lb(2) .or. jg > ub(2)) cycle
      n = n + 1
      ti(n) = ig - lb(1) + 1
      tj(n) = jg - lb(2) + 1
    end do
    pos_i = ti(1:n)
    pos_j = tj(1:n)
  end subroutine local_positions

  !> Monta o ESMF_Mesh das células de Voronoi locais do MPAS.
  !!
  !! Cada PET informa as suas células e os vértices que elas usam, com
  !! identificadores globais. Um vértice compartilhado por células de PETs
  !! diferentes aparece nos dois PETs com o mesmo identificador; o ESMF
  !! decide o dono. Coordenadas em radianos, como no MPAS.
  !!
  !! @param cellIDs         identificador global de cada célula local
  !! @param nEdgesOnCell    número de vértices de cada célula
  !! @param verticesOnCell  (maxEdges, nCells) identificador global dos vértices
  !! @param lonCell,latCell centro de cada célula [rad]
  !! @param vertexIDs       identificadores globais dos vértices disponíveis
  !! @param lonVertex,latVertex coordenadas desses vértices [rad]
  subroutine mpas_mesh_create(cellIDs, nEdgesOnCell, verticesOnCell, lonCell, latCell, &
                              vertexIDs, lonVertex, latVertex, mesh, rc)
    integer,            intent(in)  :: cellIDs(:), nEdgesOnCell(:), verticesOnCell(:,:)
    real(ESMF_KIND_R8), intent(in)  :: lonCell(:), latCell(:)
    integer,            intent(in)  :: vertexIDs(:)
    real(ESMF_KIND_R8), intent(in)  :: lonVertex(:), latVertex(:)
    type(ESMF_Mesh),    intent(out) :: mesh
    integer,            intent(out) :: rc

    integer, allocatable :: nodeIDs(:), elemConn(:), vtx_pos(:), node_pos(:)
    logical, allocatable :: is_used(:)
    real(ESMF_KIND_R8), allocatable :: nodeCoords(:), elemCoords(:)
    integer :: nCells, nNodes, c, k, v, pos, id, minID, maxID

    rc = ESMF_SUCCESS
    nCells = size(cellIDs)
    minID = minval(vertexIDs); maxID = maxval(vertexIDs)

    ! Posição de cada ID global no vetor de vértices recebido
    allocate(vtx_pos(minID:maxID)); vtx_pos = 0
    do k = 1, size(vertexIDs)
      vtx_pos(vertexIDs(k)) = k
    end do

    ! Vértices usados pelas células locais (cada um uma vez, em ordem de ID)
    allocate(is_used(minID:maxID)); is_used = .false.
    do c = 1, nCells
      do k = 1, nEdgesOnCell(c)
        v = verticesOnCell(k, c)
        if (v < minID .or. v > maxID) then
          rc = ESMF_FAILURE
        else if (vtx_pos(v) == 0) then
          rc = ESMF_FAILURE
        else
          is_used(v) = .true.
        end if
      end do
    end do
    if (rc /= ESMF_SUCCESS) then
      call log_error(COMP_REGRID, 'mpas_mesh_create: celula com vertice sem coordenada')
      return
    end if
    nodeIDs = pack([(id, id = minID, maxID)], is_used)
    nNodes  = size(nodeIDs)

    allocate(node_pos(minID:maxID), nodeCoords(2*nNodes)); node_pos = 0
    do k = 1, nNodes
      node_pos(nodeIDs(k)) = k
      pos = vtx_pos(nodeIDs(k))
      nodeCoords(2*k-1) = to_lon180(lonVertex(pos) * RAD2DEG)
      nodeCoords(2*k)   = latVertex(pos) * RAD2DEG
    end do

    ! Conectividade: posição (1-based) de cada vértice na lista de nós
    allocate(elemConn(sum(nEdgesOnCell)), elemCoords(2*nCells))
    pos = 0
    do c = 1, nCells
      do k = 1, nEdgesOnCell(c)
        pos = pos + 1
        elemConn(pos) = node_pos(verticesOnCell(k, c))
      end do
      elemCoords(2*c-1) = to_lon180(lonCell(c) * RAD2DEG)
      elemCoords(2*c)   = latCell(c) * RAD2DEG
    end do

    mesh = ESMF_MeshCreate(parametricDim=2, spatialDim=2,                     &
      nodeIds=nodeIDs, nodeCoords=nodeCoords,                                 &
      elementIds=cellIDs, elementTypes=nEdgesOnCell, elementConn=elemConn,    &
      elementCoords=elemCoords, coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
  end subroutine mpas_mesh_create

  elemental function to_lon180(lon) result(x)
    real(ESMF_KIND_R8), intent(in) :: lon
    real(ESMF_KIND_R8) :: x
    x = lon
    if (x > 180.0_ESMF_KIND_R8) x = x - 360.0_ESMF_KIND_R8
  end function to_lon180


end module regrid_mpassit_mod
