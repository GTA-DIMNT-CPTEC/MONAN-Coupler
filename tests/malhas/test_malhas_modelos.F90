!> @file test_malhas_modelos.F90
!! @brief Malhas dos caps do SIS2 e do MOM6 por cpl_grids, contra as de antes.
!!
!! Os caps do SIS2 e do MOM6 só rodam com as bibliotecas dos modelos, por
!! isso a comparação com a versão anterior é feita aqui, no mesmo programa,
!! contra cópias das construções que os caps faziam: a de
!! sis_cap_MONAN::create_ice_grid até a R-FASE11-09 (tag fase11-09-validada)
!! e a de mom_cap_MONAN::create_ocean_grid até a R-FASE11-10 (tag
!! fase11-10-validada):
!!
!!   blocos    cpl_blocos_de_limites contra a cópia sem mudança de
!!             ICE_DecompFromBlocks (ref_decomp, abaixo), em layouts
!!             válidos e inválidos: mesmo ok, mesma mensagem e, quando
!!             válido, os mesmos tamanhos e o mesmo mapa bloco -> PET
!!   malha     com os blocos de cada PET (layouts parecidos com os do SIS2
!!             na grade T de 10 x 7 do supergrid sintético), a grade de
!!             cpl_malha_tripolar(blocos=...) contra a grade criada como
!!             antes (ESMF_GridCreate1PeriDim com countsPerDEDim1/2 e
!!             petMap, centros lidos por mom6_supergrid_tcoords no DE 0):
!!             mesmos limites e coordenadas, bit a bit
!!   mom6      com blocos de cada PET (um layout que não é produto, com 4
!!             PETs, e layouts produto com o mapa de PETs invertido), a grade
!!             de cpl_malha_de_blocos contra a criada como antes
!!             (ESMF_DELayoutCreate, ESMF_DistGridCreate com deBlockList,
!!             ESMF_GridCreate sem halo, ESMF_GridAddCoord): mesmo número de
!!             DEs locais e mesmos limites dos vetores de coordenadas
!!
!! Roda com 4, 6 ou 8 processos (compara-malhas.bash). Saída: uma linha
!! PASSOU/FALHOU por caso no PET 0 e, no fim, "TODOS OS TESTES PASSARAM" ou
!! o número de falhas.
!> Cópia da decomposição de antes, num módulo (a rotina tem um procedimento
!! interno, o que um procedimento interno do programa não pode ter).
module ref_gelo_mod
  implicit none
  private
  public :: ref_decomp
contains
  ! Cópia sem mudança de ICE_DecompFromBlocks (sis_cap_MONAN.F90, tag
  ! fase11-09-validada), só com o nome trocado.
  subroutine ref_decomp(blocos, npet, nx, ny, cntx, cnty, pmap, msg, ok)
    integer,              intent(in)  :: blocos(:,:)
    integer,              intent(in)  :: npet, nx, ny
    integer, allocatable, intent(out) :: cntx(:), cnty(:), pmap(:,:,:)
    character(len=*),     intent(out) :: msg
    logical,              intent(out) :: ok

    integer, allocatable :: xs(:), xe(:), ys(:), ye(:)
    integer :: p, k, nbx, nby, ix, iy
    logical :: novo

    ok  = .false.
    msg = ''
    allocate(xs(npet), xe(npet), ys(npet), ye(npet))
    nbx = 0 ; nby = 0

    ! colunas e linhas distintas (pelo inicio), com o fim correspondente
    do p = 1, npet
      novo = .true.
      do k = 1, nbx
        if (xs(k) == blocos(1,p)) then
          novo = .false.
          if (xe(k) /= blocos(2,p)) then
            write(msg,'(a,i0,a)') 'colunas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (novo) then ; nbx = nbx + 1 ; xs(nbx) = blocos(1,p) ; xe(nbx) = blocos(2,p) ; end if
      novo = .true.
      do k = 1, nby
        if (ys(k) == blocos(3,p)) then
          novo = .false.
          if (ye(k) /= blocos(4,p)) then
            write(msg,'(a,i0,a)') 'linhas com mesmo inicio e fins diferentes (PET ', p-1, ')'
            return
          end if
        end if
      end do
      if (novo) then ; nby = nby + 1 ; ys(nby) = blocos(3,p) ; ye(nby) = blocos(4,p) ; end if
    end do

    if (nbx * nby /= npet) then
      write(msg,'(a,i0,a,i0,a,i0,a)') 'layout ', nbx, ' x ', nby, ' nao corresponde a ', npet, &
        ' PETs (blocos mascarados ou decomposicao nao retangular?)'
      return
    end if

    call ordena(xs(1:nbx), xe(1:nbx))
    call ordena(ys(1:nby), ye(1:nby))

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
      ix = findloc(xs(1:nbx), blocos(1,p), dim=1)
      iy = findloc(ys(1:nby), blocos(3,p), dim=1)
      if (pmap(ix, iy, 1) /= -1) then
        write(msg,'(a,i0,a,i0)') 'bloco atribuido a dois PETs: ', pmap(ix,iy,1), ' e ', p-1
        return
      end if
      pmap(ix, iy, 1) = p - 1
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

  end subroutine ref_decomp

end module ref_gelo_mod

program test_malhas_modelos
  use ESMF
  use mom6_supergrid_mod, only : mom6_supergrid_dims, mom6_supergrid_tcoords
  use cpl_grids_mod,      only : cpl_blocos_t, cpl_blocos_de_limites, cpl_malha_tripolar, &
                                 cpl_malha_de_blocos
  use ref_gelo_mod,       only : ref_decomp
  use, intrinsic :: iso_fortran_env, only : int64
  implicit none

  type(ESMF_VM) :: vm
  integer :: rc, localPet, petCount, nfalhas, nx, ny

  call ESMF_Initialize(defaultCalKind=ESMF_CALKIND_GREGORIAN, &
                       defaultLogFileName='teste_malhas_modelos', &
                       logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  if (rc /= ESMF_SUCCESS) error stop 'ESMF_Initialize'
  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, petCount=petCount, rc=rc)
  nfalhas = 0

  call confere_blocos()
  call mom6_supergrid_dims('hgrid.nc', nx, ny, rc)
  if (rc /= ESMF_SUCCESS) error stop 'mom6_supergrid_dims'
  call confere_malha('x mais rapido', .false.)
  call confere_malha('y mais rapido', .true.)
  call confere_mom6()

  if (localPet == 0) then
    if (nfalhas == 0) then
      write(*, '(A)') 'TODOS OS TESTES PASSARAM'
    else
      write(*, '(I0, A)') nfalhas, ' TESTE(S) FALHARAM'
    end if
  end if
  call ESMF_Finalize(rc=rc)
  if (nfalhas > 0) error stop 1

contains

  !> Layouts de teste: para cada caso, os limites (is, ie, js, je) de cada
  !! PET, na ordem dos PETs.
  subroutine confere_blocos()
    call caso_blocos('2 x 2', reshape([1,5,1,4, 6,10,1,4, 1,5,5,7, 6,10,5,7], [4,4]), 10, 7)
    call caso_blocos('3 x 2', reshape([1,4,1,3, 5,7,1,3, 8,10,1,3, 1,4,4,7, 5,7,4,7, &
                                       8,10,4,7], [4,6]), 10, 7)
    call caso_blocos('2 x 4, y mais rapido', reshape([1,5,1,2, 1,5,3,4, 1,5,5,6, 1,5,7,7, &
                                       6,10,1,2, 6,10,3,4, 6,10,5,6, 6,10,7,7], [4,8]), 10, 7)
    call caso_blocos('1 x 1', reshape([1,10,1,7], [4,1]), 10, 7)
    call caso_blocos('fins diferentes', reshape([1,5,1,4, 6,10,1,4, 1,4,5,7, 6,10,5,7], [4,4]), 10, 7)
    call caso_blocos('linhas com fins diferentes', reshape([1,5,1,4, 6,10,1,3, 1,5,5,7, &
                                       6,10,4,7], [4,4]), 10, 7)
    call caso_blocos('layout incompleto', reshape([1,5,1,4, 6,10,1,4, 1,5,5,7], [4,3]), 10, 7)
    call caso_blocos('sem cobrir', reshape([1,5,1,4, 6,9,1,4, 1,5,5,7, 6,9,5,7], [4,4]), 10, 7)
    call caso_blocos('buraco', reshape([1,4,1,4, 6,10,1,4, 1,4,5,7, 6,10,5,7], [4,4]), 10, 7)
    call caso_blocos('linhas com buraco', reshape([1,5,1,3, 6,10,1,3, 1,5,5,7, 6,10,5,7], [4,4]), 10, 7)
    call caso_blocos('bloco repetido', reshape([1,5,1,4, 6,10,1,4, 1,5,5,7, 1,5,5,7], [4,4]), 10, 7)
  end subroutine confere_blocos

  subroutine caso_blocos(nome, limites, nx, ny)
    character(len=*), intent(in) :: nome
    integer,          intent(in) :: limites(:,:), nx, ny
    type(cpl_blocos_t) :: b
    integer, allocatable :: cntx(:), cnty(:), pmap(:,:,:)
    character(len=256) :: msg_novo, msg_ref
    logical :: ok_novo, ok_ref, igual

    call cpl_blocos_de_limites(limites, size(limites, 2), nx, ny, b, msg_novo, ok_novo)
    call ref_decomp(limites, size(limites, 2), nx, ny, cntx, cnty, pmap, msg_ref, ok_ref)
    igual = (ok_novo .eqv. ok_ref) .and. msg_novo == msg_ref
    if (igual .and. ok_ref) then
      igual = size(b%cntx) == size(cntx) .and. size(b%cnty) == size(cnty)
      if (igual) igual = all(b%cntx == cntx) .and. all(b%cnty == cnty) .and. &
                         all(shape(b%pmap) == shape(pmap))
      if (igual) igual = all(b%pmap == pmap)
    end if
    call resultado('blocos: '//nome, igual)
  end subroutine caso_blocos

  !> Blocos de cada PET num layout de petCount PETs na grade nx x ny, em
  !! ordem x mais rápido (como o FMS) ou y mais rápido; grade nova contra a
  !! construída como antes.
  subroutine confere_malha(nome, y_rapido)
    character(len=*), intent(in) :: nome
    logical,          intent(in) :: y_rapido
    integer :: nbx, nby, ix, iy, loc4(4), rc
    integer, allocatable :: all4(:), cntx(:), cnty(:), pmap(:,:,:)
    type(cpl_blocos_t) :: b
    type(ESMF_Grid) :: g_novo, g_ref
    character(len=256) :: msg
    logical :: ok
    real(ESMF_KIND_R8), pointer :: xn(:,:), yn(:,:), xr(:,:), yr(:,:)
    logical :: igual

    select case (petCount)
    case (4); nbx = 2; nby = 2
    case (6); nbx = 3; nby = 2
    case (8); nbx = 2; nby = 4
    case default; nbx = petCount; nby = 1
    end select
    if (y_rapido) then
      ix = localPet / nby; iy = mod(localPet, nby)
    else
      ix = mod(localPet, nbx); iy = localPet / nbx
    end if
    loc4 = [faixa_ini(ix, nbx, nx), faixa_fim(ix, nbx, nx), faixa_ini(iy, nby, ny), faixa_fim(iy, nby, ny)]
    allocate(all4(4*petCount))
    call ESMF_VMAllGather(vm, sendData=loc4, recvData=all4, count=4, rc=rc)
    if (rc /= ESMF_SUCCESS) error stop 'ESMF_VMAllGather'

    ! nova
    call cpl_blocos_de_limites(reshape(all4, [4, petCount]), petCount, nx, ny, b, msg, ok)
    if (.not. ok) error stop 'cpl_blocos_de_limites'
    call cpl_malha_tripolar('ice_sis2', 'hgrid.nc', nx, ny, petCount, .false., g_novo, rc, &
                            blocos=b, tag='ICE(SIS2)')
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
    call mom6_supergrid_tcoords('hgrid.nc', xr, yr, rc, tag='ICE(SIS2)')
    if (rc /= ESMF_SUCCESS) error stop 'mom6_supergrid_tcoords'

    call ESMF_GridGetCoord(g_novo, coordDim=1, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=xn, rc=rc)
    call ESMF_GridGetCoord(g_novo, coordDim=2, localDE=0, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=yn, rc=rc)
    igual = all(lbound(xn) == lbound(xr)) .and. all(ubound(xn) == ubound(xr)) .and. &
            all(lbound(yn) == lbound(yr)) .and. all(ubound(yn) == ubound(yr))
    if (igual) igual = all(transfer(xn, 1_int64, size(xn)) == transfer(xr, 1_int64, size(xr))) .and. &
                       all(transfer(yn, 1_int64, size(yn)) == transfer(yr, 1_int64, size(yr)))
    igual = igual .and. lbound(xn,1) == loc4(1) .and. ubound(xn,1) == loc4(2) .and. &
            lbound(xn,2) == loc4(3) .and. ubound(xn,2) == loc4(4)
    call resultado_todos('malha, '//nome, igual)
  end subroutine confere_malha

  !> Malha do MOM6: blocos de cada PET e mapa de PETs; grade nova contra a
  !! criada como mom_cap_MONAN::create_ocean_grid criava.
  subroutine confere_mom6()
    integer, allocatable :: lim(:,:), pmap(:)
    integer :: nbx, nby, k, ix, iy

    allocate(lim(4, petCount), pmap(petCount))
    if (petCount == 4) then
      ! layout que não é produto: colunas de blocos com cortes em j diferentes
      lim = reshape([1,5,1,4, 6,10,1,2, 6,10,3,7, 1,5,5,7], [4,4])
      pmap = [0, 1, 2, 3]
      call caso_mom6('nao produto', lim, pmap)
    end if
    select case (petCount)
    case (4); nbx = 2; nby = 2
    case (6); nbx = 3; nby = 2
    case (8); nbx = 2; nby = 4
    case default; nbx = petCount; nby = 1
    end select
    do k = 1, petCount
      ix = mod(k - 1, nbx); iy = (k - 1) / nbx
      lim(:, k) = [faixa_ini(ix, nbx, 10), faixa_fim(ix, nbx, 10), &
                   faixa_ini(iy, nby, 7), faixa_fim(iy, nby, 7)]
      pmap(k) = petCount - k   ! mapa invertido
    end do
    call caso_mom6('produto, mapa invertido', lim, pmap)
  end subroutine confere_mom6

  subroutine caso_mom6(nome, lim, pmap)
    character(len=*), intent(in) :: nome
    integer,          intent(in) :: lim(:,:), pmap(:)
    type(ESMF_Grid) :: g_novo, g_ref
    type(ESMF_DistGrid) :: distGrid
    type(ESMF_DELayout) :: deLayout
    integer, allocatable :: deBlockList(:,:,:)
    integer :: n, rc, nde_n, nde_r, lde, dim, cl(2), cu(2), clr(2), cur(2)
    real(ESMF_KIND_R8), pointer :: cn(:,:), cr(:,:)
    logical :: igual

    call cpl_malha_de_blocos('ocn_mom6', 10, 7, lim, pmap, g_novo, rc)
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

    call ESMF_GridGet(g_novo, localDeCount=nde_n, rc=rc)
    call ESMF_GridGet(g_ref, localDeCount=nde_r, rc=rc)
    igual = nde_n == nde_r
    do lde = 0, min(nde_n, nde_r) - 1
      do dim = 1, 2
        call ESMF_GridGetCoord(g_novo, coordDim=dim, localDE=lde, staggerloc=ESMF_STAGGERLOC_CENTER, &
               computationalLBound=cl, computationalUBound=cu, farrayPtr=cn, rc=rc)
        call ESMF_GridGetCoord(g_ref, coordDim=dim, localDE=lde, staggerloc=ESMF_STAGGERLOC_CENTER, &
               computationalLBound=clr, computationalUBound=cur, farrayPtr=cr, rc=rc)
        igual = igual .and. all(cl == clr) .and. all(cu == cur) .and. &
                all(lbound(cn) == lbound(cr)) .and. all(ubound(cn) == ubound(cr))
      end do
    end do
    call resultado_todos('mom6, '//nome, igual)
  end subroutine caso_mom6

  !> Início e fim da faixa k (0..nb-1) de n pontos em nb faixas, com o
  !! resto nas primeiras (como o FMS distribui).
  integer function faixa_ini(k, nb, n)
    integer, intent(in) :: k, nb, n
    faixa_ini = k * (n / nb) + min(k, mod(n, nb)) + 1
  end function faixa_ini
  integer function faixa_fim(k, nb, n)
    integer, intent(in) :: k, nb, n
    faixa_fim = faixa_ini(k, nb, n) + n / nb - 1
    if (k < mod(n, nb)) faixa_fim = faixa_fim + 1
  end function faixa_fim

  !> Resultado conferido em todos os PETs (falha se algum falhar).
  subroutine resultado_todos(nome, ok)
    character(len=*), intent(in) :: nome
    logical,          intent(in) :: ok
    integer :: loc(1), tot(1), rc
    loc = merge(0, 1, ok)
    call ESMF_VMAllReduce(vm, sendData=loc, recvData=tot, count=1, &
                          reduceflag=ESMF_REDUCE_SUM, rc=rc)
    call resultado(nome, tot(1) == 0)
  end subroutine resultado_todos

  subroutine resultado(nome, ok)
    character(len=*), intent(in) :: nome
    logical,          intent(in) :: ok
    if (.not. ok) nfalhas = nfalhas + 1
    if (localPet /= 0) return
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', nome
    else
      write(*, '(2A)') 'FALHOU  ', nome
    end if
  end subroutine resultado

end program test_malhas_modelos
