!> @file test_model_grids.F90
!! @brief Malhas dos caps do SIS2 e do MOM6 por cpl_grids, contra as de antes.
!!
!! Os caps do SIS2 e do MOM6 só rodam com as bibliotecas dos modelos, por
!! isso a comparação com a versão anterior é feita aqui, no mesmo programa,
!! contra cópias das construções que os caps faziam: a de
!! sis_cap_MONAN::create_ice_grid até a R-FASE11-09 (tag fase11-09-validada)
!! e a de mom_cap_MONAN::create_ocean_grid até a R-FASE11-10 (tag
!! fase11-10-validada):
!!
!!   blocos    cpl_blocks_from_bounds contra a cópia sem mudança de
!!             ICE_DecompFromBlocks (ref_decomp, abaixo), em layouts
!!             válidos e inválidos: mesmo ok, mesma mensagem e, quando
!!             válido, os mesmos tamanhos e o mesmo mapa bloco -> PET
!!   malha     com os blocos de cada PET (layouts parecidos com os do SIS2
!!             na grade T de 10 x 7 do supergrid sintético), a grade de
!!             cpl_tripolar_grid(blocos=...) contra a grade criada como
!!             antes (ESMF_GridCreate1PeriDim com countsPerDEDim1/2 e
!!             petMap, centros lidos por mom6_supergrid_tcoords no DE 0):
!!             mesmos limites e coordenadas, bit a bit
!!   mom6      com blocos de cada PET (um layout que não é produto, com 4
!!             PETs, e layouts produto com o mapa de PETs invertido), a grade
!!             de cpl_block_grid contra a criada como antes
!!             (ESMF_DELayoutCreate, ESMF_DistGridCreate com deBlockList,
!!             ESMF_GridCreate sem halo, ESMF_GridAddCoord): mesmo número de
!!             DEs locais e mesmos limites dos vetores de coordenadas
!!
!! Roda com 4, 6 ou 8 processos (compara-malhas.bash). Saída: uma linha
!! PASSOU/FALHOU por caso no PET 0 e, no fim, "TODOS OS TESTES PASSARAM" ou
!! o número de falhas.
!> Cópia da decomposição de antes, num módulo (a rotina tem um procedimento
!! interno, o que um procedimento interno do programa não pode ter).
module ref_ice_mod
  implicit none
  private
  public :: ref_decomp
contains
  ! Cópia sem mudança de ICE_DecompFromBlocks (sis_cap_MONAN.F90, tag
  ! fase11-09-validada), só com o nome trocado.
  subroutine ref_decomp(blocks, npet, nx, ny, cntx, cnty, pmap, msg, ok)
    integer,              intent(in)  :: blocks(:,:)
    integer,              intent(in)  :: npet, nx, ny
    integer, allocatable, intent(out) :: cntx(:), cnty(:), pmap(:,:,:)
    character(len=*),     intent(out) :: msg
    logical,              intent(out) :: ok

    integer, allocatable :: xs(:), xe(:), ys(:), ye(:)
    integer :: p, k, nbx, nby, ix, iy
    logical :: is_new

    ok  = .false.
    msg = ''
    allocate(xs(npet), xe(npet), ys(npet), ye(npet))
    nbx = 0 ; nby = 0

    ! colunas e linhas distintas (pelo inicio), com o fim correspondente
    do p = 1, npet
      is_new = .true.
      do k = 1, nbx
        if (xs(k) == blocks(1,p)) then
          is_new = .false.
          if (xe(k) /= blocks(2,p)) then
            write(msg,'(a,i0,a)') 'colunas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (is_new) then ; nbx = nbx + 1 ; xs(nbx) = blocks(1,p) ; xe(nbx) = blocks(2,p) ; end if
      is_new = .true.
      do k = 1, nby
        if (ys(k) == blocks(3,p)) then
          is_new = .false.
          if (ye(k) /= blocks(4,p)) then
            write(msg,'(a,i0,a)') 'linhas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (is_new) then ; nby = nby + 1 ; ys(nby) = blocks(3,p) ; ye(nby) = blocks(4,p) ; end if
    end do

    if (nbx * nby /= npet) then
      write(msg,'(a,i0,a,i0,a,i0,a)') 'layout ', nbx, ' x ', nby, ' nao corresponde a ', npet, &
        ' PETs (blocos mascarados ou decomposicao nao retangular?)'
      return
    end if

    call sort_pairs(xs(1:nbx), xe(1:nbx))
    call sort_pairs(ys(1:nby), ye(1:nby))

    ! cobertura contigua de 1..nx e 1..ny
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

    allocate(cntx(nbx), cnty(nby), pmap(nbx, nby, 1))
    cntx = xe(1:nbx) - xs(1:nbx) + 1
    cnty = ye(1:nby) - ys(1:nby) + 1
    pmap = -1
    do p = 1, npet
      ix = findloc(xs(1:nbx), blocks(1,p), dim=1)
      iy = findloc(ys(1:nby), blocks(3,p), dim=1)
      if (pmap(ix, iy, 1) /= -1) then
        write(msg,'(a,i0,a,i0)') 'bloco atribuido a dois PETs: ', pmap(ix,iy,1), ' e ', p-1
        return
      end if
      pmap(ix, iy, 1) = p - 1
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

  end subroutine ref_decomp

end module ref_ice_mod

program test_model_grids
  use ESMF
  use mom6_supergrid_mod, only : mom6_supergrid_dims, mom6_supergrid_tcoords
  use cpl_grids_mod,      only : cpl_blocks_t, cpl_blocks_from_bounds, cpl_tripolar_grid, &
                                 cpl_block_grid
  use ref_ice_mod,        only : ref_decomp
  use, intrinsic :: iso_fortran_env, only : int64
  implicit none

  type(ESMF_VM) :: vm
  integer :: rc, localPet, petCount, nfailures, nx, ny

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, &
                       defaultLogFileName='teste_malhas_modelos', &
                       logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 'ESMF_Initialize'
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
  nfailures = 0

  call check_blocks()
  call mom6_supergrid_dims('hgrid.nc', nx, ny, rc)
  if (rc /= ESMF_SUCCESS) error stop 'mom6_supergrid_dims'
  call check_grid('x mais rapido', .false.)
  call check_grid('y mais rapido', .true.)
  call check_mom6()

  if (localPet == 0) then
    if (nfailures == 0) then
      write(*, '(A)') 'TODOS OS TESTES PASSARAM'
    else
      write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    end if
  end if
  call ESMF_Finalize(rc=rc)
  if (nfailures > 0) error stop 1

contains

  !> Layouts de teste: para cada caso, os limites (is, ie, js, je) de cada
  !! PET, na ordem dos PETs.
  subroutine check_blocks()
    call block_case('2 x 2', reshape([1,5,1,4, 6,10,1,4, 1,5,5,7, 6,10,5,7], [4,4]), 10, 7)
    call block_case('3 x 2', reshape([1,4,1,3, 5,7,1,3, 8,10,1,3, 1,4,4,7, 5,7,4,7, &
                                       8,10,4,7], [4,6]), 10, 7)
    call block_case('2 x 4, y mais rapido', reshape([1,5,1,2, 1,5,3,4, 1,5,5,6, 1,5,7,7, &
                                       6,10,1,2, 6,10,3,4, 6,10,5,6, 6,10,7,7], [4,8]), 10, 7)
    call block_case('1 x 1', reshape([1,10,1,7], [4,1]), 10, 7)
    call block_case('fins diferentes', reshape([1,5,1,4, 6,10,1,4, 1,4,5,7, 6,10,5,7], [4,4]), 10, 7)
    call block_case('linhas com fins diferentes', reshape([1,5,1,4, 6,10,1,3, 1,5,5,7, &
                                       6,10,4,7], [4,4]), 10, 7)
    call block_case('layout incompleto', reshape([1,5,1,4, 6,10,1,4, 1,5,5,7], [4,3]), 10, 7)
    call block_case('sem cobrir', reshape([1,5,1,4, 6,9,1,4, 1,5,5,7, 6,9,5,7], [4,4]), 10, 7)
    call block_case('buraco', reshape([1,4,1,4, 6,10,1,4, 1,4,5,7, 6,10,5,7], [4,4]), 10, 7)
    call block_case('linhas com buraco', reshape([1,5,1,3, 6,10,1,3, 1,5,5,7, 6,10,5,7], [4,4]), 10, 7)
    call block_case('bloco repetido', reshape([1,5,1,4, 6,10,1,4, 1,5,5,7, 1,5,5,7], [4,4]), 10, 7)
  end subroutine check_blocks

  subroutine block_case(name, bounds, nx, ny)
    character(len=*), intent(in) :: name
    integer,          intent(in) :: bounds(:,:), nx, ny
    type(cpl_blocks_t) :: b
    integer, allocatable :: cntx(:), cnty(:), pmap(:,:,:)
    character(len=256) :: msg_new, msg_ref
    logical :: ok_new, ok_ref, same

    call cpl_blocks_from_bounds(bounds, size(bounds, 2), nx, ny, b, msg_new, ok_new)
    call ref_decomp(bounds, size(bounds, 2), nx, ny, cntx, cnty, pmap, msg_ref, ok_ref)
    same = (ok_new .eqv. ok_ref) .and. msg_new == msg_ref
    if (same .and. ok_ref) then
      same = size(b%cntx) == size(cntx) .and. size(b%cnty) == size(cnty)
      if (same) same = all(b%cntx == cntx) .and. all(b%cnty == cnty) .and. &
                         all(shape(b%pmap) == shape(pmap))
      if (same) same = all(b%pmap == pmap)
    end if
    call outcome('blocos: '//name, same)
  end subroutine block_case

  !> Blocos de cada PET num layout de petCount PETs na grade nx x ny, em
  !! ordem x mais rápido (como o FMS) ou y mais rápido; grade nova contra a
  !! construída como antes.
  subroutine check_grid(name, y_fast)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: y_fast
    integer :: nbx, nby, ix, iy, loc4(4), rc
    integer, allocatable :: all4(:), cntx(:), cnty(:), pmap(:,:,:)
    type(cpl_blocks_t) :: b
    type(ESMF_Grid) :: g_new, g_ref
    character(len=256) :: msg
    logical :: ok
    real(ESMF_KIND_R8), pointer :: xn(:,:), yn(:,:), xr(:,:), yr(:,:)
    logical :: same

    select case (petCount)
    case (4); nbx = 2; nby = 2
    case (6); nbx = 3; nby = 2
    case (8); nbx = 2; nby = 4
    case default; nbx = petCount; nby = 1
    end select
    if (y_fast) then
      ix = localPet / nby; iy = mod(localPet, nby)
    else
      ix = mod(localPet, nbx); iy = localPet / nbx
    end if
    loc4 = [range_start(ix, nbx, nx), range_end(ix, nbx, nx), range_start(iy, nby, ny), range_end(iy, nby, ny)]
    allocate(all4(4*petCount))
    call ESMF_VMAllGather(vm, sendData=loc4, recvData=all4, count=4, rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'ESMF_VMAllGather'

    ! nova
    call cpl_blocks_from_bounds(reshape(all4, [4, petCount]), petCount, nx, ny, b, msg, ok)
    if (.not. ok) error stop 'cpl_blocos_de_limites'
    call cpl_tripolar_grid('ice_sis2', 'hgrid.nc', nx, ny, petCount, .false., g_new, rc, &
                            blocks=b, comp='ICE')
    if (rc /= ESMF_SUCCESS) error stop 'cpl_malha_tripolar'

    ! como antes (sis_cap_MONAN::create_ice_grid, tag fase11-09-validada)
    call ref_decomp(reshape(all4, [4, petCount]), petCount, nx, ny, cntx, cnty, pmap, msg, ok)
    if (.not. ok) error stop 'ref_decomp'
    g_ref = ESMF_GridCreate1PeriDim(countsPerDEDim1=cntx, &
      countsPerDEDim2=cnty, periodicDim=1, petMap=pmap, &
      indexflag=ESMF_INDEX_GLOBAL, coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'ESMF_GridCreate1PeriDim'
    call ESMF_GridAddCoord(g_ref, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    call ESMF_GridGetCoord(g_ref, coordDim=1, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=xr, rc=rc)
    call ESMF_GridGetCoord(g_ref, coordDim=2, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=yr, rc=rc)
    call mom6_supergrid_tcoords('hgrid.nc', xr, yr, rc, comp='ICE')
    if (rc /= ESMF_SUCCESS) error stop 'mom6_supergrid_tcoords'

    call ESMF_GridGetCoord(g_new, coordDim=1, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=xn, rc=rc)
    call ESMF_GridGetCoord(g_new, coordDim=2, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=yn, rc=rc)
    same = all(lbound(xn) == lbound(xr)) .and. all(ubound(xn) == ubound(xr)) .and. &
            all(lbound(yn) == lbound(yr)) .and. all(ubound(yn) == ubound(yr))
    if (same) same = all(transfer(xn, 1_int64, size(xn)) == transfer(xr, 1_int64, size(xr))) .and. &
                       all(transfer(yn, 1_int64, size(yn)) == transfer(yr, 1_int64, size(yr)))
    same = same .and. lbound(xn,1) == loc4(1) .and. ubound(xn,1) == loc4(2) .and. &
            lbound(xn,2) == loc4(3) .and. ubound(xn,2) == loc4(4)
    call all_outcomes('malha, '//name, same)
  end subroutine check_grid

  !> Malha do MOM6: blocos de cada PET e mapa de PETs; grade nova contra a
  !! criada como mom_cap_MONAN::create_ocean_grid criava.
  subroutine check_mom6()
    integer, allocatable :: lim(:,:), pmap(:)
    integer :: nbx, nby, k, ix, iy

    allocate(lim(4, petCount), pmap(petCount))
    if (petCount == 4) then
      ! layout que não é produto: colunas de blocos com cortes em j diferentes
      lim = reshape([1,5,1,4, 6,10,1,2, 6,10,3,7, 1,5,5,7], [4,4])
      pmap = [0, 1, 2, 3]
      call mom6_case('nao produto', lim, pmap)
    end if
    select case (petCount)
    case (4); nbx = 2; nby = 2
    case (6); nbx = 3; nby = 2
    case (8); nbx = 2; nby = 4
    case default; nbx = petCount; nby = 1
    end select
    do k = 1, petCount
      ix = mod(k - 1, nbx); iy = (k - 1) / nbx
      lim(:, k) = [range_start(ix, nbx, 10), range_end(ix, nbx, 10), &
                   range_start(iy, nby, 7), range_end(iy, nby, 7)]
      pmap(k) = petCount - k   ! mapa invertido
    end do
    call mom6_case('produto, mapa invertido', lim, pmap)
  end subroutine check_mom6

  subroutine mom6_case(name, lim, pmap)
    character(len=*), intent(in) :: name
    integer,          intent(in) :: lim(:,:), pmap(:)
    type(ESMF_Grid) :: g_new, g_ref
    type(ESMF_DistGrid) :: distGrid
    type(ESMF_DELayout) :: deLayout
    integer, allocatable :: deBlockList(:,:,:)
    integer :: n, rc, nde_n, nde_r, lde, dim, cl(2), cu(2), clr(2), cur(2)
    real(ESMF_KIND_R8), pointer :: cn(:,:), cr(:,:)
    logical :: same

    call cpl_block_grid('ocn_mom6', 10, 7, lim, pmap, g_new, rc)
    if (rc /= ESMF_SUCCESS) error stop 'cpl_malha_de_blocos'

    ! como antes (mom_cap_MONAN::create_ocean_grid, tag fase11-10-validada)
    allocate(deBlockList(2, 2, size(lim, 2)))
    do n = 1, size(lim, 2)
      deBlockList(1, 1, n) = lim(1, n)
      deBlockList(1, 2, n) = lim(2, n)
      deBlockList(2, 1, n) = lim(3, n)
      deBlockList(2, 2, n) = lim(4, n)
    end do
    deLayout = ESMF_DELayoutCreate(petMap=pmap, rc=rc)
    distGrid = ESMF_DistGridCreate(minIndex=(/1, 1/), maxIndex=(/10, 7/), &
                 deBlockList=deBlockList, delayout=deLayout, rc=rc)
    g_ref = ESMF_GridCreate(distgrid=distGrid,               &
              coordSys=ESMF_COORDSYS_SPH_DEG,                &
              gridEdgeLWidth=(/0,0/), gridEdgeUWidth=(/0,0/),&
              rc=rc)
    call ESMF_GridAddCoord(g_ref, staggerLoc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'grade de referencia do MOM6'

    call ESMF_GridGet(g_new, localDeCount=nde_n, rc=rc)
    call ESMF_GridGet(g_ref, localDeCount=nde_r, rc=rc)
    same = nde_n == nde_r
    do lde = 0, min(nde_n, nde_r) - 1
      do dim = 1, 2
        call ESMF_GridGetCoord(g_new, coordDim=dim, localDE=lde, staggerloc=ESMF_STAGGERLOC_CENTER, &
               computationalLBound=cl, computationalUBound=cu, farrayPtr=cn, rc=rc)
        call ESMF_GridGetCoord(g_ref, coordDim=dim, localDE=lde, staggerloc=ESMF_STAGGERLOC_CENTER, &
               computationalLBound=clr, computationalUBound=cur, farrayPtr=cr, rc=rc)
        same = same .and. all(cl == clr) .and. all(cu == cur) .and. &
                all(lbound(cn) == lbound(cr)) .and. all(ubound(cn) == ubound(cr))
      end do
    end do
    call all_outcomes('mom6, '//name, same)
  end subroutine mom6_case

  !> Início e fim da faixa k (0..nb-1) de n pontos em nb faixas, com o
  !! resto nas primeiras (como o FMS distribui).
  integer function range_start(k, nb, n)
    integer, intent(in) :: k, nb, n
    range_start = k * (n / nb) + min(k, mod(n, nb)) + 1
  end function range_start
  integer function range_end(k, nb, n)
    integer, intent(in) :: k, nb, n
    range_end = range_start(k, nb, n) + n / nb - 1
    if (k < mod(n, nb)) range_end = range_end + 1
  end function range_end

  !> Resultado conferido em todos os PETs (falha se algum falhar).
  subroutine all_outcomes(name, ok)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: ok
    integer :: loc(1), tot(1), rc
    loc = merge(0, 1, ok)
    call ESMF_VMAllReduce(vm, sendData=loc, recvData=tot, count=1, &
                          reduceflag=ESMF_REDUCE_SUM, rc=rc)
    call outcome(name, tot(1) == 0)
  end subroutine all_outcomes

  subroutine outcome(name, ok)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: ok
    if (.not. ok) nfailures = nfailures + 1
    if (localPet /= 0) return
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', name
    else
      write(*, '(2A)') 'FALHOU  ', name
    end if
  end subroutine outcome

end program test_model_grids
