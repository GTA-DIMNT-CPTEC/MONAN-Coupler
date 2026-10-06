!> @file mpas_cell_binning.F90
!! @brief Média das células MPAS por caixa da grade regular de 1 grau.
!!
!! map_cells_to_regular_grid leva os valores das células MPAS de todos os
!! PETs à grade regular 360x180, pela média por caixa de 1 grau, em etapas:
!! bin_cells_local, mpas_mpi_comm, ordered_sum_bcast, fill_empty_bins,
!! diagnósticos no log e copy_to_local_grid. É o algoritmo da troca 'cap'
!! de ATM@mpas para ATM@atm_cap do mapa de acoplamento; quem o chama é o
!! adaptador do MPAS (mpas_adapter.F90, state_set_field_1d).
!! O acesso ao ESMF_State fica no adaptador, e aqui fica só o algoritmo.

module mpas_cell_binning_mod

  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY, RAD2DEG
  use mpi
  use mpas_atm_types_mod, only : MPAS_RKIND
  use coupler_utils_mod, only : ChkErr
  use coupler_log_mod, only : COMP_ATM, log_error, log_debug, log_debug_enabled
  use cpl_grids_mod, only : index_trunc, lon_0to360_floor, center_lon_west180
  implicit none
  private

  public :: map_cells_to_regular_grid
  ! Etapas de cálculo de map_cells_to_regular_grid, públicas para os testes
  ! com valor esperado (tests/unit).
  public :: bin_cells_local, fill_empty_bins

contains

  !> @brief Leva os valores das células MPAS à grade regular 360x180 (média).
  !!
  !! Etapas: bin_cells_local (soma e contagem locais por caixa de 1 grau),
  !! mpas_mpi_comm (comunicador do componente), ordered_sum_bcast (soma
  !! reprodutível entre PETs), média soma/contagem, fill_empty_bins
  !! (preenchimento das caixas sem célula), diagnósticos no log e
  !! copy_to_local_grid (porção local de fptr2d, na convenção [-180,180)).
  subroutine map_cells_to_regular_grid(n, lon_rad, lat_rad, data, fldname, fptr2d, rc)
    integer, parameter :: N_FILL_ITER = 12
    character(len=*), parameter :: subname = 'state_set_field_1d'
    integer, intent(in) :: n
    character(len=*), intent(in) :: fldname
    integer, intent(inout) :: rc
    real(MPAS_RKIND), intent(in) :: lon_rad(:)
    real(MPAS_RKIND), intent(in) :: lat_rad(:)
    real(MPAS_RKIND), intent(in) :: data(n)
    real(ESMF_KIND_R8), pointer :: fptr2d(:,:)
    real(ESMF_KIND_R8), allocatable :: buf_global(:,:)
    real(ESMF_KIND_R8), allocatable :: count_global(:,:)
    real(ESMF_KIND_R8), allocatable :: count_local(:,:)
    real(ESMF_KIND_R8), allocatable :: sum_global(:,:)
    real(ESMF_KIND_R8), allocatable :: sum_local(:,:)
    integer :: mpi_comm_use
    integer :: n_holes_post
    integer :: n_holes_pre
    type(ESMF_VM) :: vm_local

    allocate(sum_local(ATM_NX, ATM_NY),   sum_global(ATM_NX, ATM_NY))
    allocate(count_local(ATM_NX, ATM_NY), count_global(ATM_NX, ATM_NY))
    allocate(buf_global(ATM_NX, ATM_NY))

    ! 1. Acumular valor + contagem por célula regular (várias Voronoi → 1 célula)
    call bin_cells_local(n, lon_rad, lat_rad, data, sum_local, count_local)

    ! 2. Comunicador MPI do VM ESMF (mesmo do MPAS-A)
    call mpas_mpi_comm(subname, vm_local, mpi_comm_use, rc)
    if (rc /= ESMF_SUCCESS) return

    ! 3. Redução das somas e contagens (tiles Voronoi disjuntos por PET)
    call ordered_sum_bcast(sum_local, count_local, sum_global, count_global, &
                           mpi_comm_use)

    ! 4. Média: dividir soma por contagem (preserva 0 onde contagem=0)
    where (count_global > 0.5_ESMF_KIND_R8)
      buf_global = sum_global / count_global
    elsewhere
      buf_global = 0.0_ESMF_KIND_R8
    end where

    ! Preenchimento espacial das caixas sem célula Voronoi
    call fill_empty_bins(N_FILL_ITER, buf_global, count_global, &
                         n_holes_pre, n_holes_post)
    if (log_debug_enabled()) then
      call log_fill_marker(fldname, N_FILL_ITER, n_holes_pre, n_holes_post, rc)
      call log_dup_diag(vm_local, fldname, n, count_global, rc)
    end if

    ! 5. Copiar do buffer global para a porção LOCAL da fptr2d.
    call copy_to_local_grid(buf_global, fptr2d)

    deallocate(sum_local, sum_global, count_local, count_global, buf_global)

    ! Fim normal da etapa: rc volta a indicar sucesso (um rc de falha
    ! tolerado acima não interrompe quem chamou a etapa).
    rc = ESMF_SUCCESS
  end subroutine map_cells_to_regular_grid

  !> @brief Soma e contagem, por caixa de 1 grau da grade regular em [0°,360°),
  !! das células MPAS locais deste PET.
  subroutine bin_cells_local(n, lon_rad, lat_rad, data, sum_local, count_local)
    real(ESMF_KIND_R8), parameter :: DLON = 1.0_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: DLAT = 1.0_ESMF_KIND_R8
    integer, intent(in) :: n
    real(MPAS_RKIND), intent(in) :: lon_rad(:)
    real(MPAS_RKIND), intent(in) :: lat_rad(:)
    real(MPAS_RKIND), intent(in) :: data(n)
    real(ESMF_KIND_R8), intent(out) :: sum_local(ATM_NX, ATM_NY)
    real(ESMF_KIND_R8), intent(out) :: count_local(ATM_NX, ATM_NY)
    integer :: icell
    integer :: ig
    integer :: jg
    real(ESMF_KIND_R8) :: lat_d
    real(ESMF_KIND_R8) :: lon_d

    sum_local    = 0.0_ESMF_KIND_R8
    count_local  = 0.0_ESMF_KIND_R8
    do icell = 1, min(n, size(lon_rad))
      lon_d = real(lon_rad(icell), ESMF_KIND_R8) * RAD2DEG
      lat_d = real(lat_rad(icell), ESMF_KIND_R8) * RAD2DEG
      lon_d = lon_0to360_floor(lon_d)
      ig = index_trunc(lon_d, DLON, ATM_NX)
      jg = index_trunc(lat_d + 90.0_ESMF_KIND_R8, DLAT, ATM_NY)
      sum_local(ig, jg)   = sum_local(ig, jg) + real(data(icell), ESMF_KIND_R8)
      count_local(ig, jg) = count_local(ig, jg) + 1.0_ESMF_KIND_R8
    end do
  end subroutine bin_cells_local

  !> @brief Comunicador MPI do componente em execução (o do MPAS-A).
  !!
  !! Não cair para MPI_COMM_WORLD. No modo concurrent o MPAS roda em
  !! subconjunto próprio de PETs, e as coletivas de ordered_sum_bcast
  !! reúnem os tiles Voronoi disjuntos SOBRE esse subconjunto. Usar
  !! MPI_COMM_WORLD (todos os ranks, inclusive os PETs do OCN, que NÃO
  !! executam este código) travaria o coletivo: deadlock. Um erro de VM é
  !! excepcional; abortar limpo (rc de saída) é preferível a mascarar com um
  !! comunicador errado.
  subroutine mpas_mpi_comm(subname, vm_local, mpi_comm_use, rc)
    character(len=*), intent(in) :: subname
    type(ESMF_VM), intent(out) :: vm_local
    integer, intent(out) :: mpi_comm_use
    integer, intent(inout) :: rc

    call ESMF_VMGetCurrent(vm_local, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call log_error(COMP_ATM, subname//': falha ESMF_VMGetCurrent no gather Voronoi')
      return
    end if
    call ESMF_VMGet(vm_local, mpiCommunicator=mpi_comm_use, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call log_error(COMP_ATM, subname//': falha ESMF_VMGet mpiCommunicator no '// &
        'gather Voronoi')
      return
    end if
  end subroutine mpas_mpi_comm

  !> @brief Soma entre PETs, reprodutível, das somas e contagens locais.
  !!
  !! Gather em ordem de rank mais soma local, em lugar de
  !! MPI_Allreduce(MPI_SUM).
  !!
  !! Por quê: com avg_dup = 1,35 e max_dup = 2 (linha "DIAG cell_binning
  !! coverage" de log_dup_diag), é comum que duas células Voronoi caiam na
  !! mesma caixa de 1 grau da grade regular. Quando as duas estão em PETs
  !! diferentes, a soma daquela caixa é feita PELA coletiva. Soma de ponto
  !! flutuante não é associativa, e o padrão MPI não exige que a árvore de
  !! redução seja idêntica entre execuções: o MPICH pode escolher árvores
  !! diferentes conforme o momento, e o resultado varia no último bit de uma
  !! execução para outra. As variáveis do MPICH que desligam a soma parcial
  !! por nó (MPICH_ALLREDUCE_NO_SMP=1) e a coletiva em memória compartilhada
  !! (MPICH_SHARED_MEM_COLL_OPT=0) não garantem reprodutibilidade bit a bit,
  !! porque o padrão MPI não a exige.
  !!
  !! Como: MPI_Gather traz os arranjos locais de TODOS os PETs a um único
  !! PET, que soma em ordem CRESCENTE DE RANK, ordem fixa e independente de
  !! topologia e de tempo de chegada. O MPI_Bcast devolve o resultado, de
  !! modo que todos os PETs ficam com o MESMO valor, a mesma garantia do
  !! Allreduce. MPI_Reduce mais MPI_Bcast gastaria menos memória, mas o
  !! MPI_Reduce tem o mesmo problema: a ordem da soma fica a cargo da
  !! implementação.
  !!
  !! Custo: os arranjos são NX_G*NY_G = 64800 dobros, cerca de 520 kB cada.
  !! Com 64 PETs o buffer do gather chega a 33 MB por arranjo no PET raiz,
  !! alocado e liberado a cada chamada. A soma no raiz é O(nPets * 64800).
  !! Tudo isso acontece uma vez por campo por janela de acoplamento, não por
  !! passo de tempo do modelo.
  subroutine ordered_sum_bcast(sum_local, count_local, sum_global, count_global, &
                               mpi_comm_use)
    real(ESMF_KIND_R8), intent(in)  :: sum_local(ATM_NX, ATM_NY)
    real(ESMF_KIND_R8), intent(in)  :: count_local(ATM_NX, ATM_NY)
    real(ESMF_KIND_R8), intent(out) :: sum_global(ATM_NX, ATM_NY)
    real(ESMF_KIND_R8), intent(out) :: count_global(ATM_NX, ATM_NY)
    integer, intent(in) :: mpi_comm_use
    real(ESMF_KIND_R8), allocatable :: cnt_gath(:,:,:)
    real(ESMF_KIND_R8), allocatable :: sum_gath(:,:,:)
    integer :: ierr_red
    integer :: iPet_red
    integer :: myRank_red
    integer :: nPets_red

    call MPI_Comm_size(mpi_comm_use, nPets_red,  ierr_red)
    call MPI_Comm_rank(mpi_comm_use, myRank_red, ierr_red)

    if (myRank_red == 0) then
      allocate(sum_gath(ATM_NX, ATM_NY, nPets_red))
      allocate(cnt_gath(ATM_NX, ATM_NY, nPets_red))
    else
      ! Alocação mínima: o buffer de recepção só é lido no raiz, mas
      ! precisa existir como argumento válido em todos os ranks.
      allocate(sum_gath(1,1,1), cnt_gath(1,1,1))
    end if

    call MPI_Gather(sum_local,  ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    sum_gath,   ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    0, mpi_comm_use, ierr_red)
    call MPI_Gather(count_local, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    cnt_gath,    ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    0, mpi_comm_use, ierr_red)

    if (myRank_red == 0) then
      ! Soma em ordem crescente de rank: ordem fixa, reprodutível.
      sum_global   = 0.0_ESMF_KIND_R8
      count_global = 0.0_ESMF_KIND_R8
      do iPet_red = 1, nPets_red
        sum_global   = sum_global   + sum_gath(:,:,iPet_red)
        count_global = count_global + cnt_gath(:,:,iPet_red)
      end do
    end if

    call MPI_Bcast(sum_global,   ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                   0, mpi_comm_use, ierr_red)
    call MPI_Bcast(count_global, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                   0, mpi_comm_use, ierr_red)

    deallocate(sum_gath, cnt_gath)
  end subroutine ordered_sum_bcast

  !> @brief Preenche as caixas sem célula Voronoi (count_global < 0,5) com a média
  !! dos vizinhos preenchidos, em n_iter passadas.
  !!
  !! Quando a malha MPAS é mais esparsa que 1°×1°, alguns bins da grade
  !! regular ficam sem nenhum centro Voronoi → count_global=0 → buf=0, com
  !! listras verticais nos campos de fluxo. 12 iterações cobrem lacunas de
  !! até ~12° de largura (a faixa em i_nativo=172..177, no Pacífico, tem ~6°).
  !! A caixa preenchida recebe contagem 0,5 e passa a servir de vizinha na
  !! mesma passada (a ordem dos laços faz parte do resultado).
  subroutine fill_empty_bins(n_iter, buf_global, count_global, n_holes_pre, n_holes_post)
    integer, intent(in) :: n_iter
    real(ESMF_KIND_R8), intent(inout) :: buf_global(ATM_NX, ATM_NY)
    real(ESMF_KIND_R8), intent(inout) :: count_global(ATM_NX, ATM_NY)
    integer, intent(out) :: n_holes_pre
    integer, intent(out) :: n_holes_post
    integer :: di_f
    integer :: dj_f
    integer :: ia_f
    integer :: ii_f
    integer :: ja_f
    integer :: jj_f
    integer :: n_it
    integer :: n_nbr_f
    real(ESMF_KIND_R8) :: sum_nbr_f

    n_holes_pre = count(count_global < 0.5_ESMF_KIND_R8)

    do n_it = 1, n_iter
      do jj_f = 1, ATM_NY
        do ii_f = 1, ATM_NX
          if (count_global(ii_f, jj_f) < 0.5_ESMF_KIND_R8) then
            n_nbr_f   = 0
            sum_nbr_f = 0.0_ESMF_KIND_R8
            do dj_f = -1, 1
              do di_f = -1, 1
                if (di_f == 0 .and. dj_f == 0) cycle
                ia_f = mod(ii_f + di_f - 1 + ATM_NX, ATM_NX) + 1
                ja_f = max(1, min(jj_f + dj_f, ATM_NY))
                if (count_global(ia_f, ja_f) >= 0.5_ESMF_KIND_R8) then
                  sum_nbr_f = sum_nbr_f + buf_global(ia_f, ja_f)
                  n_nbr_f   = n_nbr_f + 1
                end if
              end do
            end do
            if (n_nbr_f > 0) then
              buf_global(ii_f, jj_f)   = sum_nbr_f / real(n_nbr_f, ESMF_KIND_R8)
              count_global(ii_f, jj_f) = 0.5_ESMF_KIND_R8
            end if
          end if
        end do
      end do
    end do

    n_holes_post = count(count_global < 0.5_ESMF_KIND_R8)
  end subroutine fill_empty_bins

  !> @brief Caixas vazias da grade regular antes e depois do preenchimento
  !! (PET 0, campo Sa_u10m_mpas), linha "DIAG cell_binning fill" de
  !! depuração.
  subroutine log_fill_marker(fldname, n_iter, n_holes_pre, n_holes_post, rc)
    character(len=*), intent(in) :: fldname
    integer, intent(in) :: n_iter
    integer, intent(in) :: n_holes_pre
    integer, intent(in) :: n_holes_post
    integer, intent(inout) :: rc
    integer :: my_pet
    type(ESMF_VM) :: vm_v
    character(len=240) :: vmsg

    call ESMF_VMGetCurrent(vm_v, rc=rc)
    if (rc == ESMF_SUCCESS) then
      call ESMF_VMGet(vm_v, localPet=my_pet, rc=rc)
      rc = ESMF_SUCCESS
      if (my_pet == 0 .and. trim(fldname) == 'Sa_u10m_mpas') then
          write(vmsg, '(A,A,A,I0,A,I0,A,I0,A)') &
            'DIAG cell_binning fill: campo=', &
            trim(fldname), ' buracos_pre_fill=', n_holes_pre, &
            ' buracos_pos_fill=', n_holes_post, &
            ' (N_FILL_ITER=', n_iter, ')'
          call log_debug(COMP_ATM, trim(vmsg))
      end if
    end if
    rc = ESMF_SUCCESS
  end subroutine log_fill_marker

  !> @brief Cobertura e duplicação das células na grade regular (PET 0, campo
  !! Sa_pslv_mpas), linha "DIAG cell_binning coverage" de depuração.
  !! Formato: A,A,A,I0 (3 strings + 1 int) — não A,I0 (Fortran é estrito).
  subroutine log_dup_diag(vm_local, fldname, n, count_global, rc)
    type(ESMF_VM), intent(in) :: vm_local
    character(len=*), intent(in) :: fldname
    integer, intent(in) :: n
    real(ESMF_KIND_R8), intent(in) :: count_global(ATM_NX, ATM_NY)
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8) :: avg_dup_val
    integer :: my_pet
    integer :: n_cov
    integer :: n_max_dup
    character(len=200) :: msg

    call ESMF_VMGet(vm_local, localPet=my_pet, rc=rc)
    if (my_pet == 0 .and. trim(fldname) == 'Sa_pslv_mpas') then
      n_cov     = int(sum(count_global))
      n_max_dup = int(maxval(count_global))
      avg_dup_val = sum(count_global) / &
        max(1.0_ESMF_KIND_R8, real(count(count_global > 0.5_ESMF_KIND_R8), ESMF_KIND_R8))
      write(msg,'(3A,I0,A,I0,A,I0,A,F8.4)') &
        'DIAG cell_binning coverage: campo=', trim(fldname), ' n_local=', n, &
        '  cells_cov=',  n_cov, &
        '  max_dup=',    n_max_dup, &
        '  avg_dup=',    avg_dup_val
      call log_debug(COMP_ATM, trim(msg))
    end if
  end subroutine log_dup_diag

  !> @brief Copia do buffer global (convenção [0°,360°)) para a porção LOCAL de
  !! fptr2d, cuja grade (mpas_create_grid) usa a convenção [-180°,180°):
  !! coordX(ii) = -180+(ii-0.5)°. No buffer, o bin ig corresponde à faixa
  !! [(ig-1)°, ig°), centro ≈ ig-0.5°. A cópia direta fptr2d(ii)=buf_global(ii)
  !! poria o dado do bin 0°-1° na posição -179.5°, um deslocamento de 180°.
  !!
  !! Para cada índice global ii da grade [-180,180), calcula-se a longitude
  !! geográfica correspondente, convertida para [0,360), e usa-se o bin
  !! correto de buf_global:
  !!   lon_ii  = -180 + (ii - 0.5) * DLON       [graus, pode ser negativo]
  !!   lon_0360 = lon_ii + 360  se lon_ii < 0   [graus, em [0,360)]
  !!   ig_buf   = int(lon_0360 / DLON) + 1       [índice em buf_global]
  !!
  !!   Exemplos:
  !!   ii=1   → lon=-179.5° → lon_0360=180.5° → ig_buf=181
  !!   ii=181 → lon=  0.5°  → lon_0360=  0.5° → ig_buf=  1
  !!   ii=360 → lon=179.5°  → lon_0360=179.5° → ig_buf=180
  subroutine copy_to_local_grid(buf_global, fptr2d)
    real(ESMF_KIND_R8), parameter :: DLON = 1.0_ESMF_KIND_R8
    real(ESMF_KIND_R8), intent(in) :: buf_global(ATM_NX, ATM_NY)
    real(ESMF_KIND_R8), pointer :: fptr2d(:,:)
    integer :: ig_buf
    integer :: ii
    integer :: jj
    real(ESMF_KIND_R8) :: lon_0360_d
    real(ESMF_KIND_R8) :: lon_ii_d

    fptr2d = 0.0_ESMF_KIND_R8
    do jj = lbound(fptr2d,2), ubound(fptr2d,2)
      do ii = lbound(fptr2d,1), ubound(fptr2d,1)
        if (ii >= 1 .and. ii <= ATM_NX .and. jj >= 1 .and. jj <= ATM_NY) then
            lon_ii_d   = center_lon_west180(ii, ATM_NX)
            lon_0360_d = lon_ii_d
            if (lon_0360_d < 0.0_ESMF_KIND_R8) lon_0360_d = lon_0360_d + 360.0_ESMF_KIND_R8
            ig_buf     = index_trunc(lon_0360_d, DLON, ATM_NX)
            fptr2d(ii, jj) = buf_global(ig_buf, jj)
        end if
      end do
    end do
  end subroutine copy_to_local_grid

end module mpas_cell_binning_mod
