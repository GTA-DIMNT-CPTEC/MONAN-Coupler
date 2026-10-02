!> @file regrid_weights_base.F90
!! @brief Base para esquemas de interpolação escritos só com pesos.
!!
!! Um esquema de pesos estende weights_regridder_t e escreve uma única
!! rotina, calcula_pesos, com arrays comuns do Fortran: recebe os pontos de
!! origem e de destino (coordenadas em graus, máscara e índice global) e
!! devolve a lista de pesos, um por par (ponto de origem, ponto de destino):
!!
!!   valor(destino(k)) = soma em k de fator(k) * valor(origem(k))
!!
!! A base cuida do resto, como os outros esquemas do acoplador:
!!   setup    monta os pontos a partir dos campos, chama calcula_pesos e
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
!! Os pesos calculados ficam guardados (fator, origem_k, destino_k), para
!! diagnóstico e para quem quiser gravá-los.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_weights_base_mod

  use ESMF
  use regrid_base_mod, only : regridder_t

  implicit none
  private

  public :: weights_regridder_t
  public :: regrid_pontos_t

  !> Pontos de uma grade, como arrays comuns do Fortran.
  type :: regrid_pontos_t
    real(ESMF_KIND_R8), allocatable :: lon(:)    !< longitude [graus]
    real(ESMF_KIND_R8), allocatable :: lat(:)    !< latitude [graus]
    logical,            allocatable :: valido(:) !< .false.: ponto mascarado (ou ausente)
    integer,            allocatable :: indice(:) !< índice global (sequencial do ESMF)
  end type regrid_pontos_t

  !> Esquema de pesos: o esquema concreto escreve só calcula_pesos.
  type, abstract, extends(regridder_t) :: weights_regridder_t
    type(ESMF_RouteHandle) :: rh
    !> Pesos calculados neste PET (destinos locais), em índices globais.
    real(ESMF_KIND_R8), allocatable :: fator(:)
    integer,            allocatable :: origem_k(:), destino_k(:)
  contains
    procedure :: setup   => wb_setup
    procedure :: execute => wb_execute
    procedure :: release => wb_release
    procedure(calcula_pesos_i), deferred :: calcula_pesos
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
    subroutine calcula_pesos_i(this, origem, destino, fator, orig, dest, rc)
      import :: weights_regridder_t, regrid_pontos_t, ESMF_KIND_R8
      class(weights_regridder_t),      intent(inout) :: this
      type(regrid_pontos_t),           intent(in)    :: origem, destino
      real(ESMF_KIND_R8), allocatable, intent(out)   :: fator(:)
      integer,            allocatable, intent(out)   :: orig(:), dest(:)
      integer,                         intent(out)   :: rc
    end subroutine calcula_pesos_i
  end interface

contains

  subroutine wb_setup(this, src, dst, rc)
    class(weights_regridder_t), intent(inout) :: this
    type(ESMF_Field),           intent(inout) :: src, dst
    integer,                    intent(out)   :: rc

    type(regrid_pontos_t) :: locais, origem, destino
    integer(ESMF_KIND_I4), allocatable :: indices(:,:)
    integer :: srcTermProcessing

    call pontos_locais(src, this%spec%mask_src, locais, rc)
    if (rc /= ESMF_SUCCESS) return
    call reune_origem(locais, origem, rc)
    if (rc /= ESMF_SUCCESS) return
    call pontos_locais(dst, .false., destino, rc)
    if (rc /= ESMF_SUCCESS) return

    call this%calcula_pesos(origem, destino, this%fator, this%origem_k, this%destino_k, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('regrid: rota '//trim(this%label)//': calculo dos pesos falhou', &
        ESMF_LOGMSG_ERROR)
      return
    end if
    if (size(this%origem_k) /= size(this%fator) .or. size(this%destino_k) /= size(this%fator)) then
      call ESMF_LogWrite('regrid: rota '//trim(this%label)//': listas de pesos de tamanhos '// &
        'diferentes', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    allocate(indices(2, size(this%fator)))
    indices(1,:) = int(this%origem_k, ESMF_KIND_I4)
    indices(2,:) = int(this%destino_k, ESMF_KIND_I4)
    srcTermProcessing = 0
    call ESMF_FieldSMMStore(src, dst, this%rh, this%fator, indices, &
      srcTermProcessing=srcTermProcessing, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    if (len_trim(this%method_used) == 0) this%method_used = this%spec%scheme
    this%ready = .true.
    call ESMF_LogWrite('regrid: rota '//trim(this%label)//' pronta, esquema de pesos '// &
      trim(this%spec%scheme), ESMF_LOGMSG_INFO)
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
    if (allocated(this%fator))     deallocate(this%fator)
    if (allocated(this%origem_k))  deallocate(this%origem_k)
    if (allocated(this%destino_k)) deallocate(this%destino_k)
  end subroutine wb_release

  !> Pontos locais de um campo em ESMF_Grid: coordenadas do centro, máscara
  !! (se pedida) e índice global de cada ponto, na ordem do array local.
  subroutine pontos_locais(campo, com_mascara, p, rc)
    type(ESMF_Field),      intent(in)  :: campo
    logical,               intent(in)  :: com_mascara
    type(regrid_pontos_t), intent(out) :: p
    integer,               intent(out) :: rc

    type(ESMF_GeomType_Flag) :: geomtype
    type(ESMF_Grid)          :: grid
    type(ESMF_DistGrid)      :: distgrid
    real(ESMF_KIND_R8),    pointer :: x(:,:), y(:,:)
    integer(ESMF_KIND_I4), pointer :: m(:,:)
    integer, allocatable :: seq(:)
    integer :: localDeCount, n, elementCount
    logical :: tem_mascara

    call ESMF_FieldGet(campo, geomtype=geomtype, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    if (.not. (geomtype == ESMF_GEOMTYPE_GRID)) then
      call ESMF_LogWrite('regrid: esquema de pesos aceita so campos em ESMF_Grid', &
        ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if
    call ESMF_FieldGet(campo, grid=grid, localDeCount=localDeCount, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    if (localDeCount > 1) then
      call ESMF_LogWrite('regrid: esquema de pesos aceita no maximo um DE por PET', &
        ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if
    allocate(p%lon(0), p%lat(0), p%valido(0), p%indice(0))
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
      call ESMF_LogWrite('regrid: esquema de pesos: coordenadas e DistGrid com tamanhos '// &
        'diferentes', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if
    allocate(seq(n))
    call ESMF_DistGridGet(distgrid, localDe=0, seqIndexList=seq, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    p%lon    = reshape(x, [n])
    p%lat    = reshape(y, [n])
    p%indice = seq
    deallocate(p%valido)
    allocate(p%valido(n))
    p%valido = .true.
    if (com_mascara) then
      call ESMF_GridGetItem(grid, ESMF_GRIDITEM_MASK, staggerloc=ESMF_STAGGERLOC_CENTER, &
        isPresent=tem_mascara, rc=rc)
      if (rc /= ESMF_SUCCESS) return
      if (tem_mascara) then
        call ESMF_GridGetItem(grid, ESMF_GRIDITEM_MASK, staggerloc=ESMF_STAGGERLOC_CENTER, &
          farrayPtr=m, rc=rc)
        if (rc /= ESMF_SUCCESS) return
        p%valido = reshape(m /= 0, [n])
      end if
    end if
  end subroutine pontos_locais

  !> Reúne em todos os PETs os pontos de origem, ordenados pelo índice
  !! global: o ponto de índice n vai para a posição n. Posições sem ponto
  !! (não deveria haver numa grade de um tile) ficam inválidas.
  subroutine reune_origem(locais, origem, rc)
    type(regrid_pontos_t), intent(in)  :: locais
    type(regrid_pontos_t), intent(out) :: origem
    integer,               intent(out) :: rc

    type(ESMF_VM) :: vm
    integer :: petCount, nloc, ntot, nmax, k
    integer, allocatable :: contagens(:), deslocamentos(:), idx(:), val_loc(:), val(:)
    real(ESMF_KIND_R8), allocatable :: lon(:), lat(:)

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    nloc = size(locais%indice)
    allocate(contagens(petCount), deslocamentos(petCount))
    call ESMF_VMAllGather(vm, [nloc], contagens, 1, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    deslocamentos(1) = 0
    do k = 2, petCount
      deslocamentos(k) = deslocamentos(k-1) + contagens(k-1)
    end do
    ntot = sum(contagens)

    allocate(idx(ntot), val(ntot), lon(ntot), lat(ntot))
    val_loc = merge(1, 0, locais%valido)
    call ESMF_VMAllGatherV(vm, locais%indice, nloc, idx, contagens, deslocamentos, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllGatherV(vm, val_loc, nloc, val, contagens, deslocamentos, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllGatherV(vm, locais%lon, nloc, lon, contagens, deslocamentos, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllGatherV(vm, locais%lat, nloc, lat, contagens, deslocamentos, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    nmax = 0
    if (ntot > 0) nmax = maxval(idx)
    allocate(origem%lon(nmax), origem%lat(nmax), origem%valido(nmax), origem%indice(nmax))
    origem%lon    = 0.0_ESMF_KIND_R8
    origem%lat    = 0.0_ESMF_KIND_R8
    origem%valido = .false.
    origem%indice = [(k, k = 1, nmax)]
    do k = 1, ntot
      origem%lon(idx(k))    = lon(k)
      origem%lat(idx(k))    = lat(k)
      origem%valido(idx(k)) = val(k) /= 0
    end do
  end subroutine reune_origem

end module regrid_weights_base_mod
