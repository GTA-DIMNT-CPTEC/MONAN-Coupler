!> @file mpas_cap_methods.F90
!! @brief Importacao/exportacao de campos ESMF <-> MPAS-A e criacao de malha.
!!
!! Versao 4.20 (Mai/2026) -- GT Acoplamento de Modelos / INPE/CGCT/DIMNT
!!
!! MUDANCAS EM RELACAO a v4.19:
!!   Reorganizacao de responsabilidades (Passo 6 da reestruturacao):
!!   write_mpas_import_diag, set_mpas_diag_clock e voronoi_to_grid migrados
!!   para mpas_cap_netcdf.F90 -- modulo responsavel por todo I/O NetCDF do cap ATM.
!!   Variaveis de estado g_diag_* migradas junto.
!!   mpas_import continua chamando write_mpas_import_diag via use mpas_cap_netcdf_mod.

module mpas_cap_methods_mod

  use ESMF
  use mpi
  use mpas_atm_types_mod, only : mpas_atm_public_type,   &
                                  atm_ocean_boundary_type, &
                                  MPAS_RKIND
  use mpas_cap_utils_mod, only : ChkErr
  ! Sprint C: cfg_zorl_default usado como fallback NaN-guard em mpas_import
  use mpas_cap_config_mod, only : cfg_zorl_default,          &
                                   cfg_write_import_diag,     &
                                   cfg_import_diag_dir,       &
                                   cfg_grid_res_deg
  ! FIX-EXP: netcdf_push_raw_field captura dado MPAS ANTES de state_set_field_1d
  use mpas_cap_netcdf_mod, only: netcdf_push_raw_field,     &
                                  netcdf_config_set,         &
                                  netcdf_init_coords,        &
                                  export_write_netcdf,       &
                                  write_mpas_import_diag,    &  ! migrado de mpas_cap_methods
                                  set_mpas_diag_clock           ! migrado de mpas_cap_methods
  implicit none
  private

  public :: mpas_import
  public :: mpas_export
  public :: mpas_create_grid
  public :: state_diagnose

  character(len=*), parameter :: u_FILE_u = __FILE__

contains

  !> @brief Importa campos do importState ESMF para atm_bnd.
  !!
  !! Importa 5 campos do mediador MED->MPAS (Sprint C Fase 2):
  !!   So_t      -> atm_bnd%sst           SST [K]              do MOM6 t_surf
  !!   Si_ifrac  -> atm_bnd%ice_fraction  Fracao de gelo [0-1] do SIS2/proxy
  !!   So_u      -> atm_bnd%uocn          Corrente zonal [m/s] do MOM6 u_surf
  !!   So_v      -> atm_bnd%vocn          Corrente merid [m/s] do MOM6 v_surf
  !!   Sf_zorl   -> atm_bnd%zorl          Rugosidade [m]       Charnock+Smith MED
  !!
  !! BUG-ZORL-01 (Maio 2026): Sf_zorl chega no importState MPAS em rank-1
  !! (malha Voronoi, via conector MED->MPAS). A decomposicao OCN local do PET
  !! (nCells_OCN) difere da decomposicao MPAS (nCells_MPAS). A copia posicional
  !! no ramo rank-1 de state_get_field_1d cobria apenas nCells_OCN celulas e
  !! zerava o restante, resultando em atm_bnd%zorl ~ 0 (clampado a 1e-5 m)
  !! nas celulas nao mapeadas. Fix: pre-inicializar zorl com cfg_zorl_default
  !! e nao sobrescrever as celulas nao cobertas (preservar o default 0.01 m).
  !!
  !! Robustez: state_get_field_1d retorna rc=SUCCESS quando o campo nao
  !! esta presente (apenas registra info no log ESMF). Isso permite usar
  !! este cap tanto na Fase 2 completa quanto em modos de teste com
  !! subconjunto de campos.
  subroutine mpas_import(importState, atm_bnd, nCells, rc, lonCell, latCell)
    type(ESMF_State),              intent(in)    :: importState
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,                       intent(in)    :: nCells
    integer,                       intent(inout) :: rc
    real(MPAS_RKIND), optional,    intent(in)    :: lonCell(:)  !< lon celulas [rad, 0..2pi]
    real(MPAS_RKIND), optional,    intent(in)    :: latCell(:)  !< lat celulas [rad, -pi/2..pi/2]

    character(len=*), parameter :: subname = '(mpas_import)'

    rc = ESMF_SUCCESS

    ! -- SST [K] -----------------------------------------------------------
    ! BUG-FIX-03: passa coordenadas para mapeamento geografico correto
    call state_get_field_1d(importState, 'So_t', nCells, atm_bnd%sst, rc, &
                            lonCell, latCell)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! -- Fracao de gelo marinho [0-1] -------------------------------------
    ! Sprint A: agora importado do SIS2 via mediador (era cfg_ice_fraction_default
    ! fixo). Clamp fisico [0,1] aplicado defensivamente -- regrid bilinear pode
    ! extrapolar levemente fora do intervalo (tipico +/- 0.02 em fronteiras
    ! gelo/agua).
    call state_get_field_1d(importState, 'Si_ifrac', nCells, &
                            atm_bnd%ice_fraction, rc, lonCell, latCell)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    if (allocated(atm_bnd%ice_fraction)) then
      where (atm_bnd%ice_fraction < 0.0_MPAS_RKIND) &
        atm_bnd%ice_fraction = 0.0_MPAS_RKIND
      where (atm_bnd%ice_fraction > 1.0_MPAS_RKIND) &
        atm_bnd%ice_fraction = 1.0_MPAS_RKIND
      where (atm_bnd%ice_fraction /= atm_bnd%ice_fraction) &       ! NaN guard
        atm_bnd%ice_fraction = 0.0_MPAS_RKIND
    end if

    ! -- Corrente oceanica zonal So_u [m/s] -------------------------------
    ! Sprint A: usado no esquema de superficie do MPAS para calcular tensao
    ! de cisalhamento relativa ao oceano (vento aparente = V_atm - V_ocn).
    ! Erro tipico se ignorado: < 1% em oceano calmo, ate 15% em correntes
    ! fortes (Kuroshio, Brasil, Agulhas, ACC).
    if (allocated(atm_bnd%uocn)) then
      call state_get_field_1d(importState, 'So_u', nCells, atm_bnd%uocn, rc, &
                              lonCell, latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      ! Clamp fisico: correntes superficiais oceanicas raramente > 3 m/s
      ! (recorde mundial Gulf Stream ~2.5 m/s; ACC ~1.5 m/s).
      where (abs(atm_bnd%uocn) > 5.0_MPAS_RKIND) atm_bnd%uocn = 0.0_MPAS_RKIND
      where (atm_bnd%uocn /= atm_bnd%uocn)       atm_bnd%uocn = 0.0_MPAS_RKIND
    end if

    ! -- Corrente oceanica meridional So_v [m/s] --------------------------
    if (allocated(atm_bnd%vocn)) then
      call state_get_field_1d(importState, 'So_v', nCells, atm_bnd%vocn, rc, &
                              lonCell, latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      where (abs(atm_bnd%vocn) > 5.0_MPAS_RKIND) atm_bnd%vocn = 0.0_MPAS_RKIND
      where (atm_bnd%vocn /= atm_bnd%vocn)       atm_bnd%vocn = 0.0_MPAS_RKIND
    end if

    ! -- Rugosidade superficial Sf_zorl [m] -------------------------------
    ! Sprint C (Maio 2026): rugosidade via Charnock + Smith calculada no MED
    ! a partir de Foxx_taux/tauy (mesmas variaveis usadas para u* no bulk).
    ! Substitui o default fixo cfg_zorl_default = 0.01 m que vigorou ate o
    ! Sprint B. Habilita feedback dinamico vento <-> rugosidade essencial em
    ! tempestades (sob ventos fortes a rugosidade aumenta a ordens de 10x).
    !
    ! Clamp fisico [Z0_MIN, Z0_MAX] aplicado defensivamente:
    !   Z0_MIN = 1e-5 m  (rugosidade molecular minima do ar)
    !   Z0_MAX = 0.1 m   (limite superior — alem disso spray cat-5+)
    if (allocated(atm_bnd%zorl)) then
      ! BUG-ZORL-01 (fix): pré-inicializar com cfg_zorl_default antes de
      ! state_get_field_1d. O ramo rank-1 de state_get_field_1d preserva
      ! o valor inicial em data() para células sem mapeamento geográfico
      ! (quando nCells_OCN < nCells_MPAS no PET). Sem isso, células não
      ! mapeadas herdavam lixo de memória ou zero (clampado para 1e-5 m).
      atm_bnd%zorl = real(cfg_zorl_default, MPAS_RKIND)
      call state_get_field_1d(importState, 'Sf_zorl', nCells, atm_bnd%zorl, rc, &
                              lonCell, latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      ! Clamps fisicos [Z0_MIN, Z0_MAX]
      where (atm_bnd%zorl < 1.0e-5_MPAS_RKIND) atm_bnd%zorl = 1.0e-5_MPAS_RKIND
      where (atm_bnd%zorl > 0.1_MPAS_RKIND)    atm_bnd%zorl = 0.1_MPAS_RKIND
      where (atm_bnd%zorl /= atm_bnd%zorl)     &                ! NaN guard
        atm_bnd%zorl = real(cfg_zorl_default, MPAS_RKIND)
    end if

    call ESMF_LogWrite(subname//': importacao Fase 2 concluida ' // &
      '(So_t + Si_ifrac + So_u + So_v + Sf_zorl)', ESMF_LOGMSG_INFO)

    ! ── Diagnóstico de importação MED→MPAS ──────────────────────────────
    ! Escrito quando write_import_diag=.true. em &nuopc_docn do nuopc.input
    ! (mesmo flag usado pelo MED). Ativa a escrita dos 3 campos OCN→ATM:
    !   So_t     (SST [K])            — atm_bnd%sst
    !   Si_ifrac (fração de gelo)     — atm_bnd%ice_fraction
    !   Sf_zorl  (rugosidade [m])     — atm_bnd%zorl
    ! Arquivo: <cfg_import_diag_dir>/monan2_import_YYYYMMDD_HHMMSS.nc
    if (cfg_write_import_diag) then
      call write_mpas_import_diag(atm_bnd, nCells, lonCell, latCell, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS   ! diagnóstico não-fatal
    end if

  end subroutine mpas_import

  !> @brief Exporta campos de atm_public para o exportState ESMF.
  !!
  !! Campos exportados (nomes CMEPS com sufixo _mpas):
  !!   Sa_pslv_mpas, Sa_tbot_mpas, Sa_u10m_mpas, Sa_v10m_mpas, Sa_shum_mpas,
  !!   Faxa_swdn_mpas, Faxa_lwdn_mpas, Faxa_rain_mpas, Faxa_snow_mpas.
  !! Faxa_taux/tauy e Faxa_lhflx/shflx sao calculados pelo MED_cap (bulk NCAR)
  !! e nao pertencem ao exportState do MPAS cap.
  !!
  !! Campos nÃÂÃÂ£o-associados (pool diag_physics inativo ou nome ausente no
  !! Registry.xml) sÃÂÃÂ£o silenciosamente ignorados.
  subroutine mpas_export(atm_public, exportState, rc)
    type(mpas_atm_public_type), intent(in)    :: atm_public
    type(ESMF_State),           intent(inout) :: exportState
    integer,                    intent(inout) :: rc

    integer :: n
    type(ESMF_VM) :: vm
    character(len=*), parameter :: subname = '(mpas_export)'

    rc = ESMF_SUCCESS
    call ESMF_VMGetCurrent(vm, rc=rc); if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS

    ! BUG-FIX-01: usar nCellsSolve (células próprias, sem halos)
    n  = merge(atm_public%nCellsSolve, atm_public%nCells, atm_public%nCellsSolve > 0)

    ! FIX-EXP: netcdf_push_raw_field captura dado MPAS ANTES de state_set_field_1d.
    ! Garante correspondência dado(k) ↔ g_lon_global(k) em voronoi_to_latlon.
    if (associated(atm_public%pslv)) then
      call netcdf_push_raw_field('Sa_pslv_mpas', atm_public%pslv, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Sa_pslv_mpas',   n, atm_public%pslv, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%t2m)) then
      call netcdf_push_raw_field('Sa_tbot_mpas', atm_public%t2m, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Sa_tbot_mpas',   n, atm_public%t2m,  rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%u10)) then
      call netcdf_push_raw_field('Sa_u10m_mpas', atm_public%u10, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Sa_u10m_mpas',   n, atm_public%u10,  rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%v10)) then
      call netcdf_push_raw_field('Sa_v10m_mpas', atm_public%v10, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Sa_v10m_mpas',   n, atm_public%v10,  rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%swdn_sfc)) then
      call netcdf_push_raw_field('Faxa_swdn_mpas', atm_public%swdn_sfc, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_swdn_mpas', n, atm_public%swdn_sfc, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%lwdn_sfc)) then
      call netcdf_push_raw_field('Faxa_lwdn_mpas', atm_public%lwdn_sfc, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_lwdn_mpas', n, atm_public%lwdn_sfc, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%prec_rain)) then
      call netcdf_push_raw_field('Faxa_rain_mpas', atm_public%prec_rain, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_rain_mpas', n, atm_public%prec_rain, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%q2m)) then
      call netcdf_push_raw_field('Sa_shum_mpas', atm_public%q2m, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Sa_shum_mpas', n, atm_public%q2m, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%prec_snow)) then
      call netcdf_push_raw_field('Faxa_snow_mpas', atm_public%prec_snow, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_snow_mpas', n, atm_public%prec_snow, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    call ESMF_LogWrite(subname//': exportacao concluida', ESMF_LOGMSG_INFO)

  end subroutine mpas_export

  !> @brief Cria ESMF_Grid sintetica 360x180 para o cap MPAS.
  !!
  !! SOLUCAO DEFINITIVA v5.0: substituicao de ESMF_Mesh por ESMF_Grid.
  !!
  !! CAUSA RAIZ de todos os travamentos anteriores:
  !!   O ESMF_Mesh usa internamente ESMF_MOAB para gestao paralela da malha.
  !!   Com ESMF_MOAB=enabled (build ESMF 8.9.1), as operacoes de
  !!   ESMF_MeshAddNodes, ESMF_MeshAddElements e ESMF_FieldCreate sobre
  !!   ESMF_Mesh executam chamadas MPI internas (para redistribuicao de nos
  !!   e sincronizacao de campo) que entram em deadlock apos mpas_atm_init.
  !!   O SMIOL (Simple Model I/O Library) do MPAS-A deixa o communicator MPI
  !!   em estado incompativel com as operacoes nao-convencionais do MOAB.
  !!
  !! SOLUCAO:
  !!   Substituir ESMF_Mesh por ESMF_Grid (grade regular lat/lon 360x180).
  !!   ESMF_Grid nao usa MOAB: todas as operacoes paralelas usam MPI padrao.
  !!   Todos os conectores passam a ser Grid->Grid (MED usa Grid 640x320,
  !!   DOCN usa Grid 1440x720): regridding padrao, sem deadlock.
  !!
  !! Grade sintetica 360x180 (1 grau, 64800 celulas):
  !!   - ESMF_GridCreate1PeriDim: distribuicao automatica balanceada
  !!   - numOwnedElements > 0 em TODOS os PETs garantido pelo ESMF
  !!   - Coordenadas lon/lat explicitamente definidas (ESMF_STAGGERLOC_CENTER)
  !!   - Compativel com MED atm_grid (640x320) e DOCN grid (1440x720)
  subroutine mpas_create_grid(grid, rc)
    type(ESMF_Grid), intent(out) :: grid
    integer,         intent(out) :: rc

    integer, parameter            :: NLON = 360
    integer, parameter            :: NLAT = 180
    real(ESMF_KIND_R8), parameter :: DLON = 1.0_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: DLAT = 1.0_ESMF_KIND_R8

    real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)
    integer  :: i, j, clbX(2), cubX(2), clbY(2), cubY(2)
    integer  :: petCount, regDecomp(2), localDeCount
    integer  :: nx_max, ny_tiles, lde
    integer  :: nx_tiles_target  ! B-57
    type(ESMF_VM) :: vm
    character(len=*), parameter :: subname = '(mpas_create_grid)'

    rc = ESMF_SUCCESS

    ! B-57 (fix B-52): regDecomp 2D com tiles quadradas — evita strips extremos.
    !
    ! PROBLEMA com B-52 (nx_max = NLON/2):
    !   Grids grandes + muitos PETs geram strips ultra-estreitas.
    !   Ex: grade netcdf 1440×720 a 512 PETs → regDecomp=(/512,1/) →
    !   2-3 cols × 720 rows → aspecto 256:1. MOAB trava em ESMF_FieldBundleRegridStore
    !   (IPDvXp08 extro aparece mas o regrid store nunca retorna).
    !
    ! SOLUCAO B-57: tiles quadradas via sqrt(petCount).
    !   nx_tiles_target = nint(sqrt(N)) → aspect ratio ≈ 1.
    !   nx_max = min(target, NLON/2)   → garante col ≥ 2 (bilinear OK).
    !   ny_tiles = ceil(N/nx_max)       → cobre todos os PETs.
    !
    !   N=4:   sqrt=2  → nx_max=min(2,180)=2   regDecomp=(/2,2/)=4DEs   asp 0.5:1 ✓
    !   N=128: sqrt=11 → nx_max=min(11,180)=11 regDecomp=(/11,12/)=132  asp 0.5:1 ✓
    !   N=512: sqrt=23 → nx_max=min(23,180)=23 regDecomp=(/23,23/)=529  asp 0.5:1 ✓
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    nx_tiles_target = max(1, nint(sqrt(real(petCount))))
    nx_max      = min(nx_tiles_target, NLON / 2)
    ny_tiles    = (petCount + nx_max - 1) / nx_max
    regDecomp(1) = min(nx_max, petCount)
    regDecomp(2) = max(1, ny_tiles)

    ! Grade regular 1 grau, periódica em lon.
    ! BUG-MPAS-LON-SHIFT (pré-condição): indexflag=ESMF_INDEX_GLOBAL garante que
    ! lbound(fptr2d,1) seja o índice global real do PET (e.g., 61 para o segundo
    ! PET de 60 colunas), não 1. Sem isso, state_set_field_1d não consegue calcular
    ! a longitude geográfica correta para o deslocamento buf_global→fptr2d.
    grid = ESMF_GridCreate1PeriDim( &
      minIndex   = (/1, 1/),           &
      maxIndex   = (/NLON, NLAT/),     &
      regDecomp  = regDecomp,          &
      indexflag  = ESMF_INDEX_GLOBAL,  &
      coordSys   = ESMF_COORDSYS_SPH_DEG, &
      rc         = rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! ESMF_GridAddCoord é COLETIVA — todos os PETs devem chamá-la.
    call ESMF_GridAddCoord(grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! B-52: guard localDeCount>0 — com regDecomp 2D e DEs>petCount,
    ! todos os PETs têm ≥1 DE; guard mantido por segurança para N > nx_max*ny_tiles.
    call ESMF_GridGet(grid, localDeCount=localDeCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! B-53 (fix B-52): com regDecomp 2D, DEs totais > petCount → alguns PETs têm
    ! localDeCount=2. ESMF_GridGetCoord sem localDE= falha com "must provide localDe
    ! argument for localDeCount > 1". Solução: loop explícito sobre cada DE local.
    do lde = 0, localDeCount - 1

      ! Coordenada X (longitude): centros de células (-179.5° a +179.5°)
      nullify(coordX)
      call ESMF_GridGetCoord(grid, coordDim=1, localDE=lde, &
                             staggerloc=ESMF_STAGGERLOC_CENTER, &
                             computationalLBound=clbX, computationalUBound=cubX, &
                             farrayPtr=coordX, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = clbX(2), cubX(2)
        do i = clbX(1), cubX(1)
          coordX(i,j) = -180.0_ESMF_KIND_R8 + (real(i,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8)*DLON
        end do
      end do

      ! Coordenada Y (latitude): centros de células (-89.5° a +89.5°)
      nullify(coordY)
      call ESMF_GridGetCoord(grid, coordDim=2, localDE=lde, &
                             staggerloc=ESMF_STAGGERLOC_CENTER, &
                             computationalLBound=clbY, computationalUBound=cubY, &
                             farrayPtr=coordY, rc=rc)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      do j = clbY(2), cubY(2)
        do i = clbY(1), cubY(1)
          coordY(i,j) = -90.0_ESMF_KIND_R8 + (real(j,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8)*DLAT
        end do
      end do

    end do  ! lde = 0, localDeCount-1

    call ESMF_LogWrite(subname//': ESMF_Grid 360x180 criada (sem MOAB)', ESMF_LOGMSG_INFO)

  end subroutine mpas_create_grid

  !> @brief Escreve estatÃÂÃÂ­sticas dos campos do estado no log ESMF.
  !!
  !! Ativado por DumpFields='true' (atributo NUOPC).
  !! Para cada campo do estado escreve: nome, min, max, mÃÂÃÂ©dia.
  subroutine state_diagnose(state, state_tag, rc)
    type(ESMF_State), intent(in)  :: state
    character(len=*), intent(in)  :: state_tag
    integer,          intent(out) :: rc

    type(ESMF_Field)              :: field
    character(len=64), allocatable :: fldnames(:)
    integer :: itemCount, i, localrc
    character(len=160) :: msg
    character(len=*), parameter :: subname = '(state_diagnose)'

    rc = ESMF_SUCCESS

    call ESMF_StateGet(state, itemCount=itemCount, rc=localrc)
    if (localrc /= ESMF_SUCCESS .or. itemCount == 0) then
      call ESMF_LogWrite(subname//': '//trim(state_tag)//' vazio', ESMF_LOGMSG_INFO)
      return
    end if

    allocate(fldnames(itemCount))
    call ESMF_StateGet(state, itemNameList=fldnames, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      deallocate(fldnames); return
    end if

    write(msg,'(A,A)') subname//': ', trim(state_tag)
    call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)

    do i = 1, itemCount
      call ESMF_StateGet(state, itemName=trim(fldnames(i)), field=field, rc=localrc)
      if (localrc /= ESMF_SUCCESS) cycle
      block
        real(ESMF_KIND_R8), pointer :: fp1d(:)
        real(ESMF_KIND_R8), pointer :: fp2d(:,:)
        real(ESMF_KIND_R8), allocatable :: vals(:)
        integer :: fdr
        nullify(fp1d, fp2d)
        call ESMF_FieldGet(field, dimCount=fdr, rc=localrc)
        if (localrc /= ESMF_SUCCESS) cycle
        if (fdr == 1) then
          call ESMF_FieldGet(field, farrayPtr=fp1d, rc=localrc)
          if (localrc /= ESMF_SUCCESS .or. .not. associated(fp1d) .or. size(fp1d)==0) cycle
          vals = fp1d
          nullify(fp1d)
        else
          call ESMF_FieldGet(field, farrayPtr=fp2d, rc=localrc)
          if (localrc /= ESMF_SUCCESS .or. .not. associated(fp2d) .or. size(fp2d)==0) cycle
          vals = pack(fp2d, .true.)
          nullify(fp2d)
        end if
        write(msg,'(A,A,3(A,ES11.4))') &
          '  ', trim(fldnames(i)), &
          '  min=', minval(vals), &
          '  max=', maxval(vals), &
          '  mean=', sum(vals) / real(size(vals), ESMF_KIND_R8)
        call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)
      end block
    end do

    deallocate(fldnames)

  end subroutine state_diagnose

  ! ÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂ privado ÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂÃÂ¢ÃÂÃÂ


  !> @brief Copia campo 1D do ESMF_State para array Fortran.
  !> @brief Copia campo do ESMF_State para array Fortran 1D.
  !!
  !! FIX v5.2: suporte a campos 2D (ESMF_Grid) via pack() — Fortran 95, portavel.
  !! pack(fptr2d,.true.) serializa o array 2D column-major para 1D sem restricoes
  !! de tipo de ponteiro nem necessidade de iso_c_binding.
  !> @brief Copia campo do ESMF_State para array Fortran 1D.
  !!
  !! BUG-FIX-03: quando lon_rad/lat_rad presentes, usa posição geográfica da célula
  !! MPAS para selecionar o ponto correto na grade 2D (360×180, DLON=DLAT=1°).
  !! Sem esta correção, o mapeamento column-major coloca a SST de (lon=0°,lat=-90°)
  !! na célula MPAS #1, independentemente da localização real dessa célula.
  !!
  !! Células cuja posição geográfica não pertence ao domínio local deste PET recebem
  !! o valor padrão informado pelo campo (zero ou o valor já inicializado no array).
  !! Isso é inevitável sem um AllGather global — veja comentário NOTA-ALLGATHER abaixo.
  !!
  !! NOTA-ALLGATHER (trabalho futuro): Para garantir que TODAS as células MPAS
  !! recebam o valor correto independentemente da decomposição de domínio, é necessário
  !! um ESMF_VMAllGatherV do campo 2D completo antes do mapeamento. Isso custaria
  !! ~64800 × 8 B = 518 kB por campo por passo de acoplamento — aceitável, mas requer
  !! refatoração do uso de ESMF_VM aqui.
  subroutine state_get_field_1d(state, fldname, n, data, rc, lon_rad, lat_rad)
    type(ESMF_State),  intent(in)    :: state
    character(len=*),  intent(in)    :: fldname
    integer,           intent(in)    :: n
    real(MPAS_RKIND),  intent(inout) :: data(n)
    integer,           intent(out)   :: rc
    real(MPAS_RKIND),  intent(in), optional :: lon_rad(:)  !< lon células MPAS [rad, 0..2π]
    real(MPAS_RKIND),  intent(in), optional :: lat_rad(:)  !< lat células MPAS [rad, -π/2..π/2]

    type(ESMF_Field)             :: field
    real(ESMF_KIND_R8), pointer  :: fptr1d(:)
    integer :: n_esmf, fld_rank
    character(len=*), parameter  :: subname = '(state_get_field_1d)'

    rc = ESMF_SUCCESS
    nullify(fptr1d)

    call ESMF_StateGet(state, itemName=fldname, field=field, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' nao encontrado', ESMF_LOGMSG_INFO)
      rc = ESMF_SUCCESS
      return
    end if

    ! B-45: verificar localDeCount ANTES de farrayPtr (evita erro ESMF log).
    block
      integer :: localDeCount_sg
      call ESMF_FieldGet(field, localDeCount=localDeCount_sg, rc=rc)
      if (rc /= ESMF_SUCCESS .or. localDeCount_sg == 0) then
        rc = ESMF_SUCCESS; return
      end if
    end block

    ! Consultar rank do campo ANTES de chamar farrayPtr (evita erro ESMF)
    call ESMF_FieldGet(field, dimCount=fld_rank, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' dimCount query falhou', ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS; return
    end if

    if (fld_rank == 1) then
      ! Campo rank-1: ESMF_Mesh ou ESMF_Grid 1D
      ! BUG-ZORL-01 (fix): o campo rank-1 pode ter decomposição diferente
      ! da malha MPAS local. Exemplo: Sf_zorl chega na malha Voronoi via
      ! conector MED→MPAS, mas o PET OCN tem nCells_OCN ≠ nCells_MPAS.
      ! Cópia posicional (i-ésimo OCN → i-ésima MPAS) é geograficamente
      ! incorreta e zeraria as células não cobertas, sobrepondo o default.
      ! Fix: copiar apenas o mínimo necessário e NÃO alterar o restante
      ! de data() — mantém cfg_zorl_default (ou valor já inicializado)
      ! nas células sem mapeamento. O padrão 0.01 m é preferível a 0.0 m
      ! (que seria clampeado para 1e-5 m, valor fisicamente irreal).
      call ESMF_FieldGet(field, farrayPtr=fptr1d, rc=rc)
      if (rc /= ESMF_SUCCESS .or. .not. associated(fptr1d)) then
        rc = ESMF_SUCCESS; return
      end if
      n_esmf = min(size(fptr1d), n)
      data(1:n_esmf) = real(fptr1d(1:n_esmf), MPAS_RKIND)
      ! data(n_esmf+1:n) mantido inalterado — preserva valor inicial
      nullify(fptr1d)
    else
      ! ── Campo rank-2: ESMF_Grid regular 360×180 (g_grid, INDEX_GLOBAL) ──
      !
      ! BUG-COBERTURA-PARCIAL — correção Maio 2026
      ! ------------------------------------------------------------------
      ! A versão anterior (BUG-FIX-03) lia fptr2d(ig,jg) APENAS quando o ponto
      ! de grade global (ig,jg) pertencia ao tile LOCAL deste PET. Como a malha
      ! MPAS (que CONSOME o dado) e a grade g_grid (que o PRODUZ) têm
      ! decomposições MPI INDEPENDENTES, a maioria das células MPAS precisava
      ! de um ponto de grade pertencente a OUTRO PET — e nunca o recebia,
      ! permanecendo no valor default pré-inicializado em data().
      !   Sintoma: So_t ≈ 298 K (cfg_sst_default) e Sf_zorl ≈ 0,01 m
      !   (cfg_zorl_default) em quase todo o globo, com dado dinâmico real
      !   apenas na faixa onde as duas decomposições coincidiam geograficamente.
      !
      ! CORREÇÃO: reunir o campo COMPLETO no PET 0 (ESMF_FieldGather) e
      ! difundi-lo a todos os PETs (ESMF_VMBroadcast). Com a cópia global
      ! disponível localmente, cada PET mapeia QUALQUER célula MPAS para o
      ! ponto de grade correto. Custo: 1 gather + 1 broadcast de NLON·NLAT
      ! reais R8 (~0,5 MB) por campo/passo — desprezível frente ao MPAS.
      !
      ! Segurança coletiva: FieldGather/VMBroadcast são coletivas — todos os
      ! PETs devem alcançá-las. mpas_create_grid usa regDecomp que cobre
      ! petCount, garantindo ≥1 DE por PET; logo o guard B-45 (localDeCount==0)
      ! acima não dispara para estes campos e não há risco de deadlock.
      block
        integer,            parameter :: NLON = 360, NLAT = 180
        real(ESMF_KIND_R8), parameter :: DLON = 1.0_ESMF_KIND_R8
        real(ESMF_KIND_R8), parameter :: DLAT = 1.0_ESMF_KIND_R8
        real(ESMF_KIND_R8), parameter :: RAD2DEG  = 57.29577951308232_ESMF_KIND_R8
        real(ESMF_KIND_R8), parameter :: FILL_THR = 1.0e19_ESMF_KIND_R8
        real(ESMF_KIND_R8), allocatable :: buf2d(:,:), buf1d(:)
        type(ESMF_VM)      :: vm_l
        integer            :: localPet_l, icell, ig, jg
        real(ESMF_KIND_R8) :: lon_d, lat_d, val

        call ESMF_VMGetCurrent(vm_l, rc=rc)
        if (rc /= ESMF_SUCCESS) then; rc = ESMF_SUCCESS; return; end if
        call ESMF_VMGet(vm_l, localPet=localPet_l, rc=rc)
        if (rc /= ESMF_SUCCESS) then; rc = ESMF_SUCCESS; return; end if

        ! 1) Reunir o campo distribuído (ordem de índice global) no PET 0.
        allocate(buf2d(NLON, NLAT))
        buf2d = -9.99e+20_ESMF_KIND_R8
        call ESMF_FieldGather(field, farray=buf2d, rootPet=0, rc=rc)
        if (rc /= ESMF_SUCCESS) then
          deallocate(buf2d); rc = ESMF_SUCCESS; return
        end if

        ! 2) Difundir a cópia global a todos os PETs (buffer contíguo 1-D).
        allocate(buf1d(NLON*NLAT))
        if (localPet_l == 0) buf1d = reshape(buf2d, [NLON*NLAT])
        call ESMF_VMBroadcast(vm_l, buf1d, NLON*NLAT, 0, rc=rc)
        if (rc /= ESMF_SUCCESS) then
          deallocate(buf2d, buf1d); rc = ESMF_SUCCESS; return
        end if
        buf2d = reshape(buf1d, [NLON, NLAT])

        ! 3) Mapeamento geográfico nearest-neighbor para TODAS as células MPAS.
        if (present(lon_rad) .and. present(lat_rad) .and. &
            size(lon_rad) >= n .and. size(lat_rad) >= n) then
          do icell = 1, n
            lon_d = real(lon_rad(icell), ESMF_KIND_R8) * RAD2DEG
            lat_d = real(lat_rad(icell), ESMF_KIND_R8) * RAD2DEG
            ! BUG-LON-ORIGIN — correção Maio 2026
            ! ------------------------------------------------------------
            ! A g_grid é criada em mpas_create_grid com longitudes de CENTRO
            ! coordX(ig) = -180 + (ig - 0.5)*DLON, ou seja ig=1 ↔ -179,5° e
            ! ig=360 ↔ +179,5° — convenção [-180, +180).
            ! A versão anterior normalizava lon_d para [0, 360) e fazia
            ! ig = int(lon_d/DLON)+1, deslocando TODA a atribuição em 180°
            ! (dado do Atlântico ia para índice do Pacífico). Sintoma: padrão
            ! global trocado em longitude + listra vertical na descontinuidade.
            ! Correção: normalizar lon para [-180, +180) e indexar na mesma
            ! origem da grade.
            lon_d = lon_d - floor((lon_d + 180.0_ESMF_KIND_R8) / 360.0_ESMF_KIND_R8) &
                            * 360.0_ESMF_KIND_R8          ! → [-180, +180)
            ig = int((lon_d + 180.0_ESMF_KIND_R8) / DLON) + 1
            jg = int((lat_d +  90.0_ESMF_KIND_R8) / DLAT) + 1
            ig = max(1, min(ig, NLON))
            jg = max(1, min(jg, NLAT))
            val = buf2d(ig, jg)
            ! Só sobrescreve com valor VÁLIDO (oceano). Pontos de fill (terra,
            ! ou sem cobertura do regrid MED) preservam o default já em data() —
            ! fallback seguro consumido pela física do MPAS sobre o oceano.
            if (abs(val) < FILL_THR .and. val == val) then
              data(icell) = real(val, MPAS_RKIND)
            end if
          end do
        else
          ! Fallback sem coordenadas: ordem global linear (válido só sem halos).
          ! Não zera o restante — preserva o default (evita clamp irreal).
          n_esmf = min(NLON*NLAT, n)
          data(1:n_esmf) = real(buf1d(1:n_esmf), MPAS_RKIND)
        end if

        deallocate(buf2d, buf1d)
      end block
    end if
    rc = ESMF_SUCCESS

  end subroutine state_get_field_1d

  !> @brief Copia array Fortran 1D para campo do ESMF_State.
  !!
  !! FIX v5.2: suporte a campos 2D (ESMF_Grid) via loop indexado — Fortran 95, portavel.
  !! Percorre fptr2d em ordem column-major, preenchendo com os primeiros n_esmf
  !! valores do array data (celulas MPAS locais).
  !> @brief Copia array Fortran 1D para campo do ESMF_State.
  !!
  !! BUG-FIX-03: quando lon_rad/lat_rad presentes, usa posição geográfica de cada
  !! célula MPAS para escrevê-la na posição correta da grade 2D (360×180, 1°×1°).
  !! Sem esta correção, o mapeamento column-major colocava, por exemplo, o vento da
  !! célula MPAS #1 (possivelmente Oceano Austral) na posição (1,1) da grade regular
  !! (lon=0.5°, lat=-89.5°), sem relação com a localização real da célula.
  !!
  !! Células cujas coordenadas geográficas caem fora do domínio local deste PET são
  !! silenciosamente ignoradas (posição zero na grade local). Veja NOTA-ALLGATHER
  !! em state_get_field_1d para a solução completa com MPI_AllGather.
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

    rc = ESMF_SUCCESS
    nullify(fptr1d, fptr2d)

    call ESMF_StateGet(state, itemName=fldname, field=field, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' nao encontrado', ESMF_LOGMSG_INFO)
      rc = ESMF_SUCCESS
      return
    end if

    ! B-45: verificar localDeCount ANTES de farrayPtr (evita erro ESMF log).
    block
      integer :: localDeCount_ss
      call ESMF_FieldGet(field, localDeCount=localDeCount_ss, rc=rc)
      if (rc /= ESMF_SUCCESS .or. localDeCount_ss == 0) then
        rc = ESMF_SUCCESS; return
      end if
    end block

    ! Consultar rank do campo ANTES de chamar farrayPtr (evita erro ESMF)
    call ESMF_FieldGet(field, dimCount=fld_rank, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' dimCount query falhou', ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS; return
    end if

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

      ! BUG-FIX-03 v3 (BUG-MPAS-02): mapeamento geográfico via MEDIA MPI.
      ! 
      ! Causa raiz do bug remanescente (Sa_pslv max=2017 hPa, dobrou):
      !   MPI_Allreduce(SUM) SOMA valores quando múltiplas células Voronoi de
      !   PETs diferentes mapeiam para o mesmo (ig,jg) da grade regular 360×180.
      !   Especialmente nos polos (convergência meridianos) e onde várias
      !   células Voronoi pequenas caem na mesma célula 1°×1° → valor dobra.
      !
      ! Solução: MÉDIA via dois Allreduce(SUM):
      !   buf_sum(ig,jg)   = sum_PET(valor)
      !   buf_count(ig,jg) = sum_PET(contagem 0/1)
      !   buf_global(ig,jg) = buf_sum(ig,jg) / max(buf_count(ig,jg), 1)
      if (present(lon_rad) .and. present(lat_rad) .and. &
          size(lon_rad) >= n .and. size(lat_rad) >= n) then
        block
          integer           :: icell, ig, jg, ierr_mpi, mpi_comm_use
          integer           :: ii, jj
          real(ESMF_KIND_R8), parameter :: RAD2DEG = 57.29577951308232_ESMF_KIND_R8
          real(ESMF_KIND_R8), parameter :: DLON    = 1.0_ESMF_KIND_R8
          real(ESMF_KIND_R8), parameter :: DLAT    = 1.0_ESMF_KIND_R8
          integer,            parameter :: NX_G = 360, NY_G = 180
          real(ESMF_KIND_R8) :: lon_d, lat_d
          real(ESMF_KIND_R8), allocatable :: sum_local(:,:),   sum_global(:,:)
          real(ESMF_KIND_R8), allocatable :: count_local(:,:), count_global(:,:)
          real(ESMF_KIND_R8), allocatable :: buf_global(:,:)
          type(ESMF_VM) :: vm_local

          allocate(sum_local(NX_G, NY_G),   sum_global(NX_G, NY_G))
          allocate(count_local(NX_G, NY_G), count_global(NX_G, NY_G))
          allocate(buf_global(NX_G, NY_G))
          sum_local    = 0.0_ESMF_KIND_R8
          count_local  = 0.0_ESMF_KIND_R8

          ! 1. Acumular valor + contagem por célula regular (várias Voronoi → 1 célula)
          do icell = 1, min(n, size(lon_rad))
            lon_d = real(lon_rad(icell), ESMF_KIND_R8) * RAD2DEG
            lat_d = real(lat_rad(icell), ESMF_KIND_R8) * RAD2DEG
            lon_d = lon_d - floor(lon_d / 360.0_ESMF_KIND_R8) * 360.0_ESMF_KIND_R8
            ig = int(lon_d / DLON) + 1
            jg = int((lat_d + 90.0_ESMF_KIND_R8) / DLAT) + 1
            ig = max(1, min(ig, NX_G))
            jg = max(1, min(jg, NY_G))
            sum_local(ig, jg)   = sum_local(ig, jg) + real(data(icell), ESMF_KIND_R8)
            count_local(ig, jg) = count_local(ig, jg) + 1.0_ESMF_KIND_R8
          end do

          ! 2. Obter comunicador MPI do VM ESMF (mesmo do MPAS-A)
          call ESMF_VMGetCurrent(vm_local, rc=rc)
          if (rc == ESMF_SUCCESS) then
            call ESMF_VMGet(vm_local, mpiCommunicator=mpi_comm_use, rc=rc)
            if (rc /= ESMF_SUCCESS) mpi_comm_use = MPI_COMM_WORLD
          else
            mpi_comm_use = MPI_COMM_WORLD
          end if

          ! 3. Allreduce SUM dos valores e contagens (tiles Voronoi disjuntos por PET)
          call MPI_Allreduce(sum_local,   sum_global,   NX_G*NY_G, &
            MPI_DOUBLE_PRECISION, MPI_SUM, mpi_comm_use, ierr_mpi)
          call MPI_Allreduce(count_local, count_global, NX_G*NY_G, &
            MPI_DOUBLE_PRECISION, MPI_SUM, mpi_comm_use, ierr_mpi)

          ! 4. Média: dividir soma por contagem (preserva 0 onde contagem=0)
          where (count_global > 0.5_ESMF_KIND_R8)
            buf_global = sum_global / count_global
          elsewhere
            buf_global = 0.0_ESMF_KIND_R8
          end where

          ! BUG-SPARSE (fix v7.6): preenchimento espacial para células com count=0.
          ! Quando a malha MPAS é mais esparsa que 1°×1°, alguns bins da grade
          ! regular ficam sem nenhum centro Voronoi → count_global=0 → buf=0.
          ! Resultado: listras verticais nos campos de fluxo (visualizadas nos
          ! mapas diagnósticos).
          !
          ! v7.6: iterações aumentadas de 3 → 12, cobrindo lacunas até ~12°
          ! de largura. A faixa observada em i_nativo=172..177 (Pacífico,
          ! ~6° largura) era cortada pelo fill original (3 iter = 3 células).
          !
          ! BUG-SPARSE-02 VERIFICAÇÃO BUILD: ao ser executado para Sa_u10m_mpas
          ! no PET 0, escreve marca '##### BUG-SPARSE-02 v7.6 ATIVO #####' no log.
          ! Se você NÃO vê essa linha em logs/PET0.esmApp.log, o binário não
          ! tem este patch compilado.
          block
            integer            :: ii_f, jj_f, di_f, dj_f, ia_f, ja_f, n_nbr_f, n_it
            real(ESMF_KIND_R8) :: sum_nbr_f
            integer, parameter :: N_FILL_ITER = 12   ! v7.6: era 3
            integer            :: n_holes_pre, n_holes_post

            ! Diagnóstico pré-fill
            n_holes_pre = count(count_global < 0.5_ESMF_KIND_R8)

            do n_it = 1, N_FILL_ITER
              do jj_f = 1, NY_G
                do ii_f = 1, NX_G
                  if (count_global(ii_f, jj_f) < 0.5_ESMF_KIND_R8) then
                    n_nbr_f   = 0
                    sum_nbr_f = 0.0_ESMF_KIND_R8
                    do dj_f = -1, 1
                      do di_f = -1, 1
                        if (di_f == 0 .and. dj_f == 0) cycle
                        ia_f = mod(ii_f + di_f - 1 + NX_G, NX_G) + 1
                        ja_f = max(1, min(jj_f + dj_f, NY_G))
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

            ! VERIFICAÇÃO DE BUILD + DIAGNÓSTICO (PET 0, campo de referência)
            block
              integer :: my_pet
              type(ESMF_VM) :: vm_v
              call ESMF_VMGetCurrent(vm_v, rc=rc)
              if (rc == ESMF_SUCCESS) then
                call ESMF_VMGet(vm_v, localPet=my_pet, rc=rc)
                rc = ESMF_SUCCESS
                if (my_pet == 0 .and. trim(fldname) == 'Sa_u10m_mpas') then
                  block
                    character(len=240) :: vmsg
                    write(vmsg, '(A,A,A,I0,A,I0,A,I0,A)') &
                      '##### BUG-SPARSE-02 v7.6 ATIVO ##### campo=', &
                      trim(fldname), ' buracos_pre_fill=', n_holes_pre, &
                      ' buracos_pos_fill=', n_holes_post, &
                      ' (N_FILL_ITER=', N_FILL_ITER, ')'
                    call ESMF_LogWrite(trim(vmsg), ESMF_LOGMSG_INFO)
                  end block
                end if
              end if
              rc = ESMF_SUCCESS
            end block
          end block

          ! Diagnóstico (apenas para Sa_pslv_mpas, no PET 0)
          ! Formato: A,A,A,I0 (3 strings + 1 int) — não A,I0 ! (Fortran é estrito).
          block
            integer :: my_pet, n_cov, n_max_dup
            real(ESMF_KIND_R8) :: avg_dup_val
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
          end block

          ! 5. Copiar do buffer global para a porção LOCAL da fptr2d.
          !
          ! BUG-MPAS-LON-SHIFT (fix): a grade MPAS (mpas_create_grid) usa a
          ! convenção [-180°,180°] para longitude: coordX(ii) = -180+(ii-0.5)°.
          ! O buf_global usa a convenção [0°,360°): bin ig corresponde à faixa
          ! [(ig-1)°, ig°), centro ≈ ig-0.5°. A cópia direta fptr2d(ii)=buf_global(ii)
          ! coloca dados do bin 0°-1° na posição geográfica -179.5° — deslocamento de
          ! 180°, gerando caixa retangular e padrões geograficamente errados.
          !
          ! Correção: para cada índice global ii da grade [-180,180], calcular
          ! a longitude geográfica correspondente, converter para [0,360) e usar
          ! o bin correto de buf_global.
          !   lon_ii  = -180 + (ii - 0.5) * DLON       [graus, pode ser negativo]
          !   lon_0360 = lon_ii + 360  se lon_ii < 0   [graus, em [0,360)]
          !   ig_buf   = int(lon_0360 / DLON) + 1       [índice em buf_global]
          !
          !   Exemplos:
          !   ii=1   → lon=-179.5° → lon_0360=180.5° → ig_buf=181 ✓
          !   ii=181 → lon=  0.5°  → lon_0360=  0.5° → ig_buf=  1 ✓
          !   ii=360 → lon=179.5°  → lon_0360=179.5° → ig_buf=180 ✓
          fptr2d = 0.0_ESMF_KIND_R8
          do jj = lbound(fptr2d,2), ubound(fptr2d,2)
            do ii = lbound(fptr2d,1), ubound(fptr2d,1)
              if (ii >= 1 .and. ii <= NX_G .and. jj >= 1 .and. jj <= NY_G) then
                block
                  real(ESMF_KIND_R8) :: lon_ii_d, lon_0360_d
                  integer            :: ig_buf
                  lon_ii_d   = -180.0_ESMF_KIND_R8 + &
                               (real(ii, ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * DLON
                  lon_0360_d = lon_ii_d
                  if (lon_0360_d < 0.0_ESMF_KIND_R8) lon_0360_d = lon_0360_d + 360.0_ESMF_KIND_R8
                  ig_buf = int(lon_0360_d / DLON) + 1
                  ig_buf = max(1, min(ig_buf, NX_G))
                  fptr2d(ii, jj) = buf_global(ig_buf, jj)
                end block
              end if
            end do
          end do

          deallocate(sum_local, sum_global, count_local, count_global, buf_global)
        end block
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


end module mpas_cap_methods_mod
