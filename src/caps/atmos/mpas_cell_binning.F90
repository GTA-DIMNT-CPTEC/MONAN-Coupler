!> @file mpas_cell_binning.F90
!! @brief Copia das celulas MPAS para campos do ESMF_State (grade regular).
!!
!! state_set_field_1d leva um arranjo 1D das células MPAS a um campo do
!! ESMF_State. No campo rank-2 (grade regular 360x180), a média por caixa de
!! 1 grau é feita por map_cells_to_regular_grid e suas etapas (bin_cells_local,
!! mpas_mpi_comm, ordered_sum_bcast, fill_empty_bins, diagnósticos no log e
!! copy_to_local_grid).
!!
!! find_local_field faz a busca do campo no State e as verificações que
!! state_set_field_1d e state_get_field_1d (mpas_cap_methods) fazem antes de
!! acessar os dados.
!!
!! Separado de mpas_cap_methods.F90 sem mudar instruções (R-FASE8-15).

module mpas_cell_binning_mod

  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY, RAD2DEG
  use mpi
  use mpas_atm_types_mod, only : MPAS_RKIND
  use coupler_utils_mod, only : ChkErr
  use cpl_grids_mod, only : indice_trunca, lon_0a360_piso, centro_lon_oeste180
  implicit none
  private

  public :: state_set_field_1d, find_local_field
  ! Etapas de cálculo de map_cells_to_regular_grid, públicas para os testes
  ! com valor esperado (tests/unit).
  public :: bin_cells_local, fill_empty_bins

contains

  !> @brief Procura o campo fldname no State e informa se há dados locais.
  !!
  !! found fica .false., e nada mais é feito, quando o campo não existe (nota
  !! INFO no log), quando este PET não tem DE do campo ou quando a consulta do
  !! rank falha (aviso no log). Essas verificações vêm antes de farrayPtr para
  !! não gerar erro no log do ESMF.
  !!
  !! @param[in]  state     State onde procurar
  !! @param[in]  fldname   nome do campo
  !! @param[in]  subname   nome da rotina chamadora, usado nas mensagens
  !! @param[out] field     o campo, quando encontrado
  !! @param[out] fld_rank  número de dimensões do campo
  !! @param[out] found     .true. quando o campo pode ser acessado
  subroutine find_local_field(state, fldname, subname, field, fld_rank, found)
    type(ESMF_State), intent(in)  :: state
    character(len=*), intent(in)  :: fldname
    character(len=*), intent(in)  :: subname
    type(ESMF_Field), intent(out) :: field
    integer,          intent(out) :: fld_rank
    logical,          intent(out) :: found

    integer :: localDeCount, rc

    found    = .false.
    fld_rank = 0

    call ESMF_StateGet(state, itemName=fldname, field=field, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' nao encontrado', ESMF_LOGMSG_INFO)
      return
    end if

    call ESMF_FieldGet(field, localDeCount=localDeCount, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localDeCount == 0) return

    call ESMF_FieldGet(field, dimCount=fld_rank, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' dimCount query falhou', ESMF_LOGMSG_WARNING)
      return
    end if

    found = .true.
  end subroutine find_local_field

  !> @brief Copia array Fortran 1D (celulas MPAS) para campo do ESMF_State.
  !!
  !! Campo rank-1: copia posicional. Campo rank-2 (ESMF_Grid 360x180): com
  !! lon_rad/lat_rad presentes, cada celula MPAS e' escrita no ponto da grade
  !! que contem sua posicao geografica, pela media entre PETs de
  !! map_cells_to_regular_grid; sem as coordenadas, copia na ordem
  !! column-major.
  subroutine state_set_field_1d(state, fldname, n, data, rc, lon_rad, lat_rad)
    type(ESMF_State),  intent(inout) :: state
    character(len=*),  intent(in)    :: fldname
    integer,           intent(in)    :: n
    real(MPAS_RKIND),  intent(in)    :: data(n)
    integer,           intent(out)   :: rc
    real(MPAS_RKIND),  intent(in), optional :: lon_rad(:)  !< lon células MPAS [rad, 0..2π]
    real(MPAS_RKIND),  intent(in), optional :: lat_rad(:)  !< lat células MPAS [rad, -π/2..π/2]

    type(ESMF_Field)             :: field
    real(ESMF_KIND_R8), pointer  :: fptr1d(:)
    real(ESMF_KIND_R8), pointer  :: fptr2d(:,:)
    integer :: n_esmf, fld_rank, i, j, idx
    character(len=*), parameter  :: subname = '(state_set_field_1d)'
    logical :: found

    rc = ESMF_SUCCESS
    nullify(fptr1d, fptr2d)

    call find_local_field(state, fldname, subname, field, fld_rank, found)
    if (.not. found) return

    if (fld_rank == 1) then
      ! Campo rank-1: ESMF_Mesh ou ESMF_Grid 1D
      call ESMF_FieldGet(field, farrayPtr=fptr1d, rc=rc)
      if (rc /= ESMF_SUCCESS .or. .not. associated(fptr1d)) then
        rc = ESMF_SUCCESS; return
      end if
      n_esmf = min(size(fptr1d), n)
      fptr1d(1:n_esmf) = real(data(1:n_esmf), ESMF_KIND_R8)
      nullify(fptr1d)
    else
      ! Campo rank-2: ESMF_Grid regular (NLON x NLAT_local)
      ! Percorrer column-major: elemento (i,j) = posicao (j-1)*dim1 + i
      call ESMF_FieldGet(field, farrayPtr=fptr2d, rc=rc)
      if (rc /= ESMF_SUCCESS .or. .not. associated(fptr2d)) then
        rc = ESMF_SUCCESS; return
      end if
      n_esmf = min(size(fptr2d), n)

      ! Mapeamento geografico por MEDIA (map_cells_to_regular_grid): varias
      ! celulas Voronoi, de PETs diferentes, podem cair no mesmo ponto (ig,jg)
      ! da grade 1°x1°, sobretudo perto dos polos. Uma soma simples dobraria o
      ! valor (Sa_pslv chegou a 2017 hPa). Por isso somam-se valores e contagens
      ! de todos os PETs, e o ponto recebe a media (zero onde nao ha celula):
      !   buf_global(ig,jg) = sum_global(ig,jg) / count_global(ig,jg)
      if (present(lon_rad) .and. present(lat_rad) .and. &
          size(lon_rad) >= n .and. size(lat_rad) >= n) then

          call map_cells_to_regular_grid(n, lon_rad, lat_rad, data, fldname, fptr2d, rc)
          if (ChkErr(rc, __LINE__, __FILE__)) return
      else
        ! Fallback legado: mapeamento column-major (sem garantia geográfica)
        idx = 0
        outer: do j = lbound(fptr2d,2), ubound(fptr2d,2)
          do i = lbound(fptr2d,1), ubound(fptr2d,1)
            idx = idx + 1
            if (idx > n_esmf) exit outer
            fptr2d(i,j) = real(data(idx), ESMF_KIND_R8)
          end do
        end do outer
      end if
      nullify(fptr2d)
    end if
    rc = ESMF_SUCCESS
  end subroutine state_set_field_1d

  !> @brief Leva os valores das células MPAS à grade regular 360x180 (média).
  !!
  !! Etapas: bin_cells_local (soma e contagem locais por caixa de 1 grau),
  !! mpas_mpi_comm (comunicador do componente), ordered_sum_bcast (soma
  !! reprodutível entre PETs), média soma/contagem, fill_empty_bins
  !! (preenchimento das caixas sem célula), diagnósticos no log e
  !! copy_to_local_grid (porção local de fptr2d, na convenção [-180,180)).
  subroutine map_cells_to_regular_grid(n, lon_rad, lat_rad, data, fldname, fptr2d, rc)
    integer, parameter :: N_FILL_ITER = 12
    character(len=*), parameter :: subname = '(state_set_field_1d)'
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

    ! 3. Reducao das somas e contagens (tiles Voronoi disjuntos por PET)
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
    call log_fill_marker(fldname, N_FILL_ITER, n_holes_pre, n_holes_post, rc)
    call log_dup_diag(vm_local, fldname, n, count_global, rc)

    ! 5. Copiar do buffer global para a porção LOCAL da fptr2d.
    call copy_to_local_grid(buf_global, fptr2d)

    deallocate(sum_local, sum_global, count_local, count_global, buf_global)

    ! Fim normal da etapa: rc volta a indicar sucesso (um rc de falha
    ! tolerado acima não interrompe quem chamou a etapa).
    rc = ESMF_SUCCESS
  end subroutine map_cells_to_regular_grid

  !> Soma e contagem, por caixa de 1 grau da grade regular em [0°,360°),
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
      lon_d = lon_0a360_piso(lon_d)
      ig = indice_trunca(lon_d, DLON, ATM_NX)
      jg = indice_trunca(lat_d + 90.0_ESMF_KIND_R8, DLAT, ATM_NY)
      sum_local(ig, jg)   = sum_local(ig, jg) + real(data(icell), ESMF_KIND_R8)
      count_local(ig, jg) = count_local(ig, jg) + 1.0_ESMF_KIND_R8
    end do
  end subroutine bin_cells_local

  !> Comunicador MPI do componente em execução (o do MPAS-A).
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
      call ESMF_LogWrite(subname//': falha ESMF_VMGetCurrent no gather '// &
        'Voronoi (state_set_field_1d)', ESMF_LOGMSG_ERROR)
      return
    end if
    call ESMF_VMGet(vm_local, mpiCommunicator=mpi_comm_use, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': falha ESMF_VMGet mpiCommunicator no '// &
        'gather Voronoi (state_set_field_1d)', ESMF_LOGMSG_ERROR)
      return
    end if
  end subroutine mpas_mpi_comm

  !> Soma entre PETs, reprodutível, das somas e contagens locais.
  !!
  !! Gather em ordem de rank mais soma local, em lugar de
  !! MPI_Allreduce(MPI_SUM).
  !!
  !! O PROBLEMA. Com avg_dup = 1,35 e max_dup = 2 (ver o diagnostico
  !! MPAS-DIAG em log_dup_diag), e' comum que duas celulas Voronoi caiam na
  !! mesma caixa de 1 grau da grade regular. Quando as duas estao em PETs
  !! diferentes, a soma daquela caixa e' feita PELA coletiva. Soma de ponto
  !! flutuante nao e' associativa, e o padrao MPI nao exige que a arvore de
  !! reducao seja identica entre execucoes: o MPICH pode escolher arvores
  !! diferentes conforme o momento. O resultado varia no ultimo bit de uma
  !! execucao para outra.
  !!
  !! POR QUE O REPRO_MPI NAO RESOLVEU. MPICH_ALLREDUCE_NO_SMP=1 desliga a
  !! soma parcial por no, e MPICH_SHARED_MEM_COLL_OPT=0 desliga a coletiva
  !! otimizada em memoria compartilhada, mas nenhuma das duas promete
  !! reprodutibilidade bit a bit entre execucoes, porque o padrao MPI nao a
  !! exige. O teste com REPRO_MPI=1 foi executado e verificado (despejo do
  !! MPICH_ENV_DISPLAY em logs/esmApp_run.log) e a divergencia persistiu:
  !! isso e' consistente com este mecanismo, nao contra ele.
  !!
  !! A SOLUCAO. MPI_Gather traz os arranjos locais de TODOS os PETs a um
  !! unico PET, que soma em ordem CRESCENTE DE RANK, ordem fixa e
  !! independente de topologia e de tempo de chegada. O MPI_Bcast devolve o
  !! resultado, de modo que todos os PETs ficam com o MESMO valor, a mesma
  !! garantia do Allreduce.
  !!
  !! CUSTO. Os arranjos sao NX_G*NY_G = 64800 dobros, cerca de 520 kB cada.
  !! Com 64 PETs o buffer do gather chega a 33 MB por arranjo no PET raiz,
  !! alocado e liberado a cada chamada. A soma no raiz e' O(nPets * 64800).
  !! Tudo isso acontece uma vez por campo por janela de acoplamento, nao por
  !! passo de tempo do modelo.
  !!
  !! ALTERNATIVA DESCARTADA. MPI_Reduce mais MPI_Bcast seria mais economico
  !! em memoria, mas o MPI_Reduce tem exatamente o mesmo problema: a ordem
  !! da soma fica a cargo da implementacao.
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
      ! Alocacao minima: o buffer de recepcao so' e' lido no raiz, mas
      ! precisa existir como argumento valido em todos os ranks.
      allocate(sum_gath(1,1,1), cnt_gath(1,1,1))
    end if

    call MPI_Gather(sum_local,  ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    sum_gath,   ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    0, mpi_comm_use, ierr_red)
    call MPI_Gather(count_local, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    cnt_gath,    ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
                    0, mpi_comm_use, ierr_red)

    if (myRank_red == 0) then
      ! Soma em ordem crescente de rank: ordem fixa, reprodutivel.
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

  !> Preenche as caixas sem célula Voronoi (count_global < 0,5) com a média
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

  !> Marca de verificação do build no log (PET 0, campo Sa_u10m_mpas), com
  !! o número de caixas vazias antes e depois do preenchimento. O texto
  !! '##### BUG-SPARSE-02 v7.6 ATIVO #####' é constante e fica como está.
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
            '##### BUG-SPARSE-02 v7.6 ATIVO ##### campo=', &
            trim(fldname), ' buracos_pre_fill=', n_holes_pre, &
            ' buracos_pos_fill=', n_holes_post, &
            ' (N_FILL_ITER=', n_iter, ')'
          call ESMF_LogWrite(trim(vmsg), ESMF_LOGMSG_INFO)
      end if
    end if
    rc = ESMF_SUCCESS
  end subroutine log_fill_marker

  !> Diagnóstico de cobertura e duplicação (PET 0, campo Sa_pslv_mpas).
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

    call ESMF_VMGet(vm_local, localPet=my_pet, rc=rc)
    if (my_pet == 0 .and. trim(fldname) == 'Sa_pslv_mpas') then
      n_cov     = int(sum(count_global))
      n_max_dup = int(maxval(count_global))
      avg_dup_val = sum(count_global) / &
        max(1.0_ESMF_KIND_R8, real(count(count_global > 0.5_ESMF_KIND_R8), ESMF_KIND_R8))
      write(*,'(3A,I0,A,I0,A,I0,A,F8.4)') &
        '[MPAS-DIAG] ', trim(fldname), ': n_local=', n, &
        '  cells_cov=',  n_cov, &
        '  max_dup=',    n_max_dup, &
        '  avg_dup=',    avg_dup_val
      flush(6)
    end if
  end subroutine log_dup_diag

  !> Copia do buffer global (convenção [0°,360°)) para a porção LOCAL de
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
            lon_ii_d   = centro_lon_oeste180(ii, ATM_NX)
            lon_0360_d = lon_ii_d
            if (lon_0360_d < 0.0_ESMF_KIND_R8) lon_0360_d = lon_0360_d + 360.0_ESMF_KIND_R8
            ig_buf     = indice_trunca(lon_0360_d, DLON, ATM_NX)
            fptr2d(ii, jj) = buf_global(ig_buf, jj)
        end if
      end do
    end do
  end subroutine copy_to_local_grid

end module mpas_cell_binning_mod
