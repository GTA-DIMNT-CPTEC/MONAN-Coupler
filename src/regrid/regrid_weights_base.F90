!> @file regrid_weights_base.F90
!! @brief Base para esquemas de interpolação escritos só com pesos.
!!
!! Um esquema de pesos estende weights_regridder_t e escreve uma única
!! rotina, compute_weights, com arrays comuns do Fortran: recebe os pontos de
!! origem e de destino (coordenadas em graus, máscara e índice global) e
!! devolve a lista de pesos, um por par (ponto de origem, ponto de destino):
!!
!!   valor(destino(k)) = soma em k de fator(k) * valor(origem(k))
!!
!! A base cuida do resto, como os outros esquemas do acoplador:
!!   setup    monta os pontos a partir dos campos, chama compute_weights e
!!            guarda os pesos no ESMF (ESMF_FieldSMMStore), com toda a soma
!!            feita no destino (srcTermProcessing = 0);
!!   execute  aplica os pesos (ESMF_FieldSMM) na ordem do índice de origem
!!            (termorder = srcseq), o que torna o resultado igual, bit a bit,
!!            com qualquer número de PETs;
!!   release  libera o route handle.
!!
!! Pontos. A origem chega inteira a cada PET, ordenada pelo índice global
!! (origem%lon(n) é o ponto de índice n), porque um ponto de destino pode
!! precisar de pontos de origem de outros PETs. O destino chega só com os
!! pontos locais, cada um com o seu índice global. Os índices são os
!! sequenciais do ESMF (os da DistGrid), os mesmos dos arquivos de pesos
!! do esquema weights_file: os pesos de um esquema de pesos podem ser
!! gravados e lidos depois pelo weights_file.
!!
!! Limites desta versão: campos em ESMF_Grid de um tile, com coordenadas no
!! centro das células e um DE por PET; campo em ESMF_Mesh é recusado com
!! mensagem no log. A máscara de origem (spec%mask_src) é a da grade
!! (ESMF_GRIDITEM_MASK, 0 = ignorar), a mesma do esquema esmf.
!!
!! Os pesos calculados ficam guardados (fator, src_index, dst_index), para
!! diagnóstico e para quem quiser gravá-los.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_weights_base_mod

  use ESMF
  use coupler_log_mod, only : COMP_REGRID, log_error, log_info
  use regrid_base_mod, only : regridder_t

  implicit none
  private

  public :: weights_regridder_t
  public :: regrid_points_t

  !> Pontos de uma grade, como arrays comuns do Fortran.
  type :: regrid_points_t
    real(ESMF_KIND_R8), allocatable :: lon(:)    !< longitude [graus]
    real(ESMF_KIND_R8), allocatable :: lat(:)    !< latitude [graus]
    logical,            allocatable :: valid(:) !< .false.: ponto mascarado (ou ausente)
    integer,            allocatable :: global_index(:) !< índice global (sequencial do ESMF)
  end type regrid_points_t

  !> Esquema de pesos: o esquema concreto escreve só compute_weights.
  type, abstract, extends(regridder_t) :: weights_regridder_t
    type(ESMF_RouteHandle) :: rh
    !> Pesos calculados neste PET (destinos locais), em índices globais.
    real(ESMF_KIND_R8), allocatable :: factors(:)
    integer,            allocatable :: src_index(:), dst_index(:)
  contains
    procedure :: setup   => wb_setup
    procedure :: execute => wb_execute
    procedure :: release => wb_release
    procedure(compute_weights_iface), deferred :: compute_weights
  end type weights_regridder_t

  abstract interface
    !> Calcula os pesos dos pontos de destino locais.
    !!
    !! @param[inout] this     o esquema (this%spec%options tem as opções)
    !! @param[in]    origem   todos os pontos de origem; origem%indice(n) = n
    !! @param[in]    destino  os pontos de destino locais
    !! @param[out]   fator    pesos
    !! @param[out]   orig     índice global de origem de cada peso
    !! @param[out]   dest     índice global de destino de cada peso
    !! @param[out]   rc       ESMF_SUCCESS ou ESMF_FAILURE (com mensagem)
    subroutine compute_weights_iface(this, src_points, dst_points, factors, orig, dest, rc)
      import :: weights_regridder_t, regrid_points_t, ESMF_KIND_R8
      class(weights_regridder_t),      intent(inout) :: this
      type(regrid_points_t),           intent(in)    :: src_points, dst_points
      real(ESMF_KIND_R8), allocatable, intent(out)   :: factors(:)
      integer,            allocatable, intent(out)   :: orig(:), dest(:)
      integer,                         intent(out)   :: rc
    end subroutine compute_weights_iface
  end interface

contains

  subroutine wb_setup(this, src, dst, rc)
    class(weights_regridder_t), intent(inout) :: this
    type(ESMF_Field),           intent(inout) :: src, dst
    integer,                    intent(out)   :: rc

    type(regrid_points_t) :: local_points, src_points, dst_points
    integer(ESMF_KIND_I4), allocatable :: indices(:,:)
    integer :: srcTermProcessing

    call get_local_points(src, this%spec%mask_src, local_points, rc)
    if (rc /= ESMF_SUCCESS) return
    call gather_source(local_points, src_points, rc)
    if (rc /= ESMF_SUCCESS) return
    call get_local_points(dst, .false., dst_points, rc)
    if (rc /= ESMF_SUCCESS) return

    call this%compute_weights(src_points, dst_points, this%factors, this%src_index, this%dst_index, rc)
    if (rc /= ESMF_SUCCESS) then
      call log_error(COMP_REGRID, 'rota '//trim(this%label)//': calculo dos pesos falhou')
      return
    end if
    if (size(this%src_index) /= size(this%factors) .or. size(this%dst_index) /= size(this%factors)) then
      call log_error(COMP_REGRID, 'rota '//trim(this%label)//': listas de pesos de tamanhos '// &
        'diferentes')
      rc = ESMF_FAILURE
      return
    end if

    allocate(indices(2, size(this%factors)))
    indices(1,:) = int(this%src_index, ESMF_KIND_I4)
    indices(2,:) = int(this%dst_index, ESMF_KIND_I4)
    srcTermProcessing = 0
    call ESMF_FieldSMMStore(src, dst, this%rh, this%factors, indices, &
      srcTermProcessing=srcTermProcessing, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    if (len_trim(this%method_used) == 0) this%method_used = this%spec%scheme
    this%ready = .true.
    call log_info(COMP_REGRID, 'rota '//trim(this%label)//' pronta, esquema de pesos '// &
      trim(this%spec%scheme))
  end subroutine wb_setup

  subroutine wb_execute(this, src, dst, zero_total, rc)
    class(weights_regridder_t), intent(inout) :: this
    type(ESMF_Field),           intent(inout) :: src, dst
    logical,                    intent(in)    :: zero_total
    integer,                    intent(out)   :: rc

    if (zero_total) then
      call ESMF_FieldSMM(src, dst, this%rh, termorderflag=ESMF_TERMORDER_SRCSEQ, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
    else
      call ESMF_FieldSMM(src, dst, this%rh, termorderflag=ESMF_TERMORDER_SRCSEQ, &
        zeroregion=ESMF_REGION_SELECT, rc=rc)
    end if
  end subroutine wb_execute

  subroutine wb_release(this, rc)
    class(weights_regridder_t), intent(inout) :: this
    integer,                    intent(out)   :: rc

    rc = ESMF_SUCCESS
    if (this%ready) call ESMF_FieldSMMRelease(this%rh, rc=rc)
    this%ready = .false.
    if (allocated(this%factors))     deallocate(this%factors)
    if (allocated(this%src_index))  deallocate(this%src_index)
    if (allocated(this%dst_index)) deallocate(this%dst_index)
  end subroutine wb_release

  !> Pontos locais de um campo em ESMF_Grid: coordenadas do centro, máscara
  !! (se pedida) e índice global de cada ponto, na ordem do array local.
  subroutine get_local_points(field, use_mask, p, rc)
    type(ESMF_Field),      intent(in)  :: field
    logical,               intent(in)  :: use_mask
    type(regrid_points_t), intent(out) :: p
    integer,               intent(out) :: rc

    type(ESMF_GeomType_Flag) :: geomtype
    type(ESMF_Grid)          :: grid
    type(ESMF_DistGrid)      :: distgrid
    real(ESMF_KIND_R8),    pointer :: x(:,:), y(:,:)
    integer(ESMF_KIND_I4), pointer :: m(:,:)
    integer, allocatable :: seq(:)
    integer :: localDeCount, n, elementCount
    logical :: has_mask

    call ESMF_FieldGet(field, geomtype=geomtype, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    if (.not. (geomtype == ESMF_GEOMTYPE_GRID)) then
      call log_error(COMP_REGRID, 'esquema de pesos aceita so campos em ESMF_Grid')
      rc = ESMF_FAILURE
      return
    end if
    call ESMF_FieldGet(field, grid=grid, localDeCount=localDeCount, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    if (localDeCount > 1) then
      call log_error(COMP_REGRID, 'esquema de pesos aceita no maximo um DE por PET')
      rc = ESMF_FAILURE
      return
    end if
    allocate(p%lon(0), p%lat(0), p%valid(0), p%global_index(0))
    if (localDeCount == 0) return

    call ESMF_GridGetCoord(grid, 1, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=x, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_GridGetCoord(grid, 2, staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=y, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_GridGet(grid, staggerloc=ESMF_STAGGERLOC_CENTER, distgrid=distgrid, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_DistGridGet(distgrid, localDe=0, elementCount=elementCount, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    n = size(x)
    if (elementCount /= n) then
      call log_error(COMP_REGRID, 'esquema de pesos: coordenadas e DistGrid com tamanhos '// &
        'diferentes')
      rc = ESMF_FAILURE
      return
    end if
    allocate(seq(n))
    call ESMF_DistGridGet(distgrid, localDe=0, seqIndexList=seq, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    p%lon    = reshape(x, [n])
    p%lat    = reshape(y, [n])
    p%global_index = seq
    deallocate(p%valid)
    allocate(p%valid(n))
    p%valid = .true.
    if (use_mask) then
      call ESMF_GridGetItem(grid, ESMF_GRIDITEM_MASK, staggerloc=ESMF_STAGGERLOC_CENTER, &
        isPresent=has_mask, rc=rc)
      if (rc /= ESMF_SUCCESS) return
      if (has_mask) then
        call ESMF_GridGetItem(grid, ESMF_GRIDITEM_MASK, staggerloc=ESMF_STAGGERLOC_CENTER, &
          farrayPtr=m, rc=rc)
        if (rc /= ESMF_SUCCESS) return
        p%valid = reshape(m /= 0, [n])
      end if
    end if
  end subroutine get_local_points

  !> Reúne em todos os PETs os pontos de origem, ordenados pelo índice
  !! global: o ponto de índice n vai para a posição n. Posições sem ponto
  !! (não deveria haver numa grade de um tile) ficam inválidas.
  subroutine gather_source(local_points, src_points, rc)
    type(regrid_points_t), intent(in)  :: local_points
    type(regrid_points_t), intent(out) :: src_points
    integer,               intent(out) :: rc

    type(ESMF_VM) :: vm
    integer :: petCount, nloc, ntot, nmax, k
    integer, allocatable :: counts(:), offsets(:), idx(:), val_loc(:), val(:)
    real(ESMF_KIND_R8), allocatable :: lon(:), lat(:)

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    nloc = size(local_points%global_index)
    allocate(counts(petCount), offsets(petCount))
    call ESMF_VMAllGather(vm, [nloc], counts, 1, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    offsets(1) = 0
    do k = 2, petCount
      offsets(k) = offsets(k-1) + counts(k-1)
    end do
    ntot = sum(counts)

    allocate(idx(ntot), val(ntot), lon(ntot), lat(ntot))
    val_loc = merge(1, 0, local_points%valid)
    call ESMF_VMAllGatherV(vm, local_points%global_index, nloc, idx, counts, offsets, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllGatherV(vm, val_loc, nloc, val, counts, offsets, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllGatherV(vm, local_points%lon, nloc, lon, counts, offsets, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllGatherV(vm, local_points%lat, nloc, lat, counts, offsets, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    nmax = 0
    if (ntot > 0) nmax = maxval(idx)
    allocate(src_points%lon(nmax), src_points%lat(nmax), src_points%valid(nmax), src_points%global_index(nmax))
    src_points%lon    = 0.0_ESMF_KIND_R8
    src_points%lat    = 0.0_ESMF_KIND_R8
    src_points%valid = .false.
    src_points%global_index = [(k, k = 1, nmax)]
    do k = 1, ntot
      src_points%lon(idx(k))    = lon(k)
      src_points%lat(idx(k))    = lat(k)
      src_points%valid(idx(k)) = val(k) /= 0
    end do
  end subroutine gather_source

end module regrid_weights_base_mod
