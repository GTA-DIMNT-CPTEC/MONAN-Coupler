!> @file mpas_adapter.F90
!! @brief Adaptador do MPAS: a tradução entre o MONAN-A e o ESMF.
!!
!! O dado passa entre o modelo e o ESMF em duas etapas, com as estruturas
!! atm_public (exportação) e atm_bnd (importação), de mpas_atm_types, no
!! meio:
!!   modelo <-> atm_public/atm_bnd   mpas_atm_setup, mpas_atm_fluxes e
!!                                   mpas_atm_model, sem ESMF;
!!   atm_public/atm_bnd <-> ESMF     este módulo, o único do cap atmosférico
!!                                   que lê ou escreve campos do ESMF com
!!                                   dados do modelo.
!!
!! Rotinas:
!!   mpas_create_grid    grade ESMF do cap (ATM@atm_cap), por cpl_grids;
!!   mpas_export         os 13 campos *_mpas, das células à grade do cap
!!                       (troca 'cap' de ATM@mpas para ATM@atm_cap no mapa
!!                       de acoplamento): state_set_field_1d, com a média por
!!                       caixa de map_cells_to_regular_grid
!!                       (mpas_cell_binning);
!!   mpas_import         os 7 campos do contorno oceânico, da grade do cap às
!!                       células (troca 'cap' de ATM@atm_cap para ATM@mpas):
!!                       state_get_field_1d, cada célula com o valor da caixa
!!                       que a contém (caixa do centro);
!!   state_diagnose      diagnóstico dos campos de um State no log;
!!   find_local_field    busca do campo no State e verificações antes de
!!                       acessar os dados.
!! Os nomes dos campos estão escritos aqui; tests/unit/test_cpl_map.F90
!! confere que as trocas 'cap' do mapa são as exportações e as importações
!! do MONAN-A. O diagnóstico NetCDF fica em mpas_cap_netcdf.F90.
!!
!! Até a R-FASE11-23 este arquivo era mpas_cap_methods.F90, e
!! find_local_field e state_set_field_1d estavam em mpas_cell_binning.F90;
!! a R-FASE11-24 reuniu aqui a tradução, sem mudar instruções.

module mpas_adapter_mod

  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY, RAD2DEG, FILL_VALUE_R8
  use mpas_atm_types_mod, only : mpas_atm_public_type,   &
                                  atm_ocean_boundary_type, &
                                  MPAS_RKIND
  use coupler_utils_mod, only : ChkErr
  use coupler_log_mod, only : COMP_ATM, log_info, log_warning, log_debug
  use cpl_grids_mod, only : cpl_latlon_grid, ORIGIN_WEST180, index_trunc, lon_m180to180_floor
  ! cfg_zorl_default e cfg_sst_default: valores de reserva de mpas_import
  ! para rugosidade e SST invalidas (ver fill_invalid_sst).
  use coupler_config_mod, only : cfg_zorl_default,          &
                                   cfg_sst_default,           &
                                   cfg_write_import_diag,     &
                                   cfg_import_diag_dir,       &
                                   cfg_grid_res_deg
  ! netcdf_push_raw_field captura dado MPAS ANTES de state_set_field_1d
  use mpas_cap_netcdf_mod, only: netcdf_push_raw_field,     &
                                  mpas_diag_export_t
  use mpas_import_diag_mod, only: write_mpas_import_diag,   &
                                  mpas_import_diag_clock_t
  use mpas_cell_binning_mod, only: map_cells_to_regular_grid
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
  !! Importa os campos do mediador MED->MPAS (ponto ATM@atm_cap do mapa de
  !! acoplamento), entre eles:
  !!   Sx_tsfc   -> atm_bnd%sst           Temp. de pele composta [K]
  !!                (So_t, SST pura, e' consumida so' pelo SIS2, para o
  !!                fluxo de calor basal do gelo)
  !!   Si_ifrac  -> atm_bnd%ice_fraction  Fracao de gelo [0-1] do SIS2/proxy
  !!   So_u      -> atm_bnd%uocn          Corrente zonal [m/s] do MOM6 u_surf
  !!   So_v      -> atm_bnd%vocn          Corrente merid [m/s] do MOM6 v_surf
  !!   Sf_zorl   -> atm_bnd%zorl          Rugosidade [m]       Charnock+Smith MED
  !!
  !! Sf_zorl chega no importState MPAS em rank-1
  !! (malha Voronoi, via conector MED->MPAS). A decomposicao OCN local do PET
  !! (nCells_OCN) difere da decomposicao MPAS (nCells_MPAS). A copia posicional
  !! no ramo rank-1 de state_get_field_1d cobria apenas nCells_OCN celulas e
  !! zerava o restante, resultando em atm_bnd%zorl ~ 0 (clampado a 1e-5 m)
  !! nas celulas nao mapeadas. Por isso: pre-inicializar zorl com cfg_zorl_default
  !! e nao sobrescrever as celulas nao cobertas (preservar o default 0.01 m).
  !!
  !! Robustez: state_get_field_1d retorna rc=SUCCESS quando o campo nao
  !! esta presente (apenas registra info no log ESMF). Isso permite usar
  !! este cap tanto com o acoplamento completo quanto em modos de teste com
  !! subconjunto de campos.
  subroutine mpas_import(diag_clock, importState, atm_bnd, nCells, rc, lonCell, latCell)
    type(mpas_import_diag_clock_t), intent(inout) :: diag_clock !< relógio do diagnóstico de importação
    type(ESMF_State),              intent(in)    :: importState
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,                       intent(in)    :: nCells
    integer,                       intent(inout) :: rc
    real(MPAS_RKIND), optional,    intent(in)    :: lonCell(:)  !< lon celulas [rad, 0..2pi]
    real(MPAS_RKIND), optional,    intent(in)    :: latCell(:)  !< lat celulas [rad, -pi/2..pi/2]

    character(len=*), parameter :: subname = 'mpas_import'
          real(MPAS_RKIND), parameter :: ICE_POLAR = 0.5_MPAS_RKIND
          real(MPAS_RKIND), parameter :: RAD2DEG_2 = 180.0_MPAS_RKIND / 3.14159265358979_MPAS_RKIND
          real(MPAS_RKIND), allocatable :: ice_fallback(:)
          integer :: n_2

    rc = ESMF_SUCCESS

    ! -- Temperatura de pele composta [K] -----------------------------------
    ! passa coordenadas para mapeamento geografico correto
    ! 'Sx_tsfc' (composto por Si_ifrac com Si_t_sis2), NAO 'So_t' (SST pura,
    ! consumida so' pelo SIS2 para o fluxo de calor basal do gelo). Ver a
    ! documentacao acima.
    call state_get_field_1d(importState, 'Sx_tsfc', nCells, atm_bnd%sst, rc, &
                            lonCell, latCell)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    ! SST era o UNICO dos 4 campos importados
    ! aqui sem clamp fisico nem guarda de NaN — Si_ifrac, So_u, So_v e Sf_zorl
    ! ja tinham essa protecao (ver abaixo), mas Sx_tsfc/So_t nao, apesar de
    ! ser usado
    ! DIRETAMENTE em skintemp_field/sst_field logo antes de core_run
    ! (mpas_atm_model.F90::inject_ocean_cells). Qualquer celula da malha Voronoi que caia perto de
    ! uma regiao sem mapeamento valido no regrid grade-regular->Voronoi (ex.:
    ! extremos de latitude/polos) pode chegar aqui como NaN ou valor fisico
    ! absurdo, alimentando core_run sem protecao (candidato a causa de um
    ! SIGSEGV em core_run ja observado). O corte usa a mesma faixa fisica do
    ! mediador (med_ocean.F90, SST_FILL: 270 K a 310 K).
    ! O valor de reserva depende da latitude: usar cfg_sst_default (~298 K,
    ! valor tropical) em QUALQUER celula invalida, inclusive polar, criaria
    ! um vies quente artificial de ~27 K nas altas latitudes (>60°), onde a
    ! agua do mar fica perto do ponto de congelamento (~271.35 K = -1.8 °C,
    ! T_FILL_POLAR abaixo, o mesmo valor de preenchimento do mediador).
    ! Em vez de um degrau em 60°, usa-se
    ! interpolacao LINEAR continua em |latitude| (graus), de T_FILL_TROPICAL
    ! no equador (0°) ate T_FILL_POLAR no polo (90°). Mais realista que um
    ! degrau (o perfil zonal real de SST decai suavemente, nao em bloco) e
    ! evita uma descontinuidade artificial de temperatura logo em 60°N/S
    ! caso o fallback seja usado numa faixa continua de celulas ali.
    if (allocated(atm_bnd%sst)) then
      call fill_invalid_sst(nCells, atm_bnd, latCell)
    end if

    ! -- Fracao de gelo marinho [0-1] -------------------------------------
    ! importada do SIS2 via mediador. Clamp fisico [0,1] aplicado defensivamente -- regrid bilinear pode
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
      ! Fallback de NaN para a fração de gelo: cair sempre em 0.0 (sem gelo)
      ! tem o mesmo problema conceitual do fallback de SST. Nos trópicos "sem
      ! gelo" é o palpite certo, mas perto dos polos é um palpite ruim, porque
      ! ali gelo marinho é comum e esperado. Passa a interpolar linearmente de
      ! 0.0 no equador até ICE_POLAR no polo, mesma lógica já usada para a SST
      ! acima. Só o valor de preenchimento muda; o corte físico em [0,1] logo
      ! acima continua igual, e aquele já estava correto.
      if (present(latCell)) then
          n_2 = nCells
          allocate(ice_fallback(n_2))
          ice_fallback = ICE_POLAR * min(1.0_MPAS_RKIND, max(0.0_MPAS_RKIND, &
            (abs(latCell(1:n_2)) * RAD2DEG_2) / 90.0_MPAS_RKIND))
          where (atm_bnd%ice_fraction(1:n_2) /= atm_bnd%ice_fraction(1:n_2))  ! NaN guard
            atm_bnd%ice_fraction(1:n_2) = ice_fallback
          end where
          deallocate(ice_fallback)
        if (allocated(ice_fallback)) deallocate(ice_fallback)
      else
        where (atm_bnd%ice_fraction /= atm_bnd%ice_fraction) &     ! NaN guard
          atm_bnd%ice_fraction = 0.0_MPAS_RKIND
      end if
    end if

    ! -- Corrente oceanica zonal So_u [m/s] -------------------------------
    ! usado no esquema de superficie do MPAS para calcular tensao
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
    ! rugosidade via Charnock + Smith calculada no MED
    ! a partir de Foxx_taux/tauy (mesmas variaveis usadas para u* no bulk).
    ! Substitui o default fixo cfg_zorl_default = 0.01 m que vigorou ate o
    ! Habilita feedback dinamico vento <-> rugosidade essencial em
    ! tempestades (sob ventos fortes a rugosidade aumenta a ordens de 10x).
    !
    ! Clamp fisico [Z0_MIN, Z0_MAX] aplicado defensivamente:
    !   Z0_MIN = 1e-5 m  (rugosidade molecular minima do ar)
    !   Z0_MAX = 0.1 m   (limite superior — alem disso spray cat-5+)
    if (allocated(atm_bnd%zorl)) then
      ! pré-inicializar com cfg_zorl_default antes de
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

    ! -- Albedo de superfície Sf_albedo [0-1] -------------------------
    ! Vindo do mediador: media ponderada por banda entre albedo dinamico de
    ! agua aberta (Briegleb 1986, dependente do zenite solar) e albedo real
    ! do gelo (SIS2), ponderados por Si_ifrac. Substitui a climatologia
    ! mensal (albedo12m) do MONAN-A sobre agua/gelo — requer
    ! config_sfc_albedo=.false. no namelist (ver log_albedo_feedback em
    ! mpas_atm_model.F90, que confere se o NOAH LSM sobrescreve o valor
    ! depois de core_run).
    if (allocated(atm_bnd%alb)) then
      atm_bnd%alb = 0.08_MPAS_RKIND   ! default agua aberta, mesmo padrao de zorl acima
      call state_get_field_1d(importState, 'Sf_albedo', nCells, atm_bnd%alb, rc, &
                              lonCell, latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      ! Clamps fisicos [0,1] + NaN guard
      where (atm_bnd%alb < 0.0_MPAS_RKIND) atm_bnd%alb = 0.08_MPAS_RKIND
      where (atm_bnd%alb > 1.0_MPAS_RKIND) atm_bnd%alb = 1.0_MPAS_RKIND
      where (atm_bnd%alb /= atm_bnd%alb)   atm_bnd%alb = 0.08_MPAS_RKIND
    end if

    ! Mascara terra/oceano Sx_omask [0-1] ---------------
    ! Mascara REAL do MOM6 (ocean_grid%mask2dT), vinda do mediador. Chega
    ! fracionaria porque atravessou dois regrids (OCN->ATM no MED, ATM->
    ! Voronoi no conector); NAO e' binarizada aqui de proposito — o corte
    ! fica no consumidor final (write_mpas_import_diag), depois do binning
    ! para a grade regular. Binarizar no meio do caminho produz escadinha
    ! na linha de costa.
    !
    ! Este campo NAO alimenta a fisica do MONAN-A: o modelo tem a propria
    ! landmask, e sobrepor a do oceano seria mudar o modelo, nao diagnostica-lo.
    if (allocated(atm_bnd%omask)) then
      atm_bnd%omask = 1.0_MPAS_RKIND   ! default tudo oceano, mesmo padrao de zorl/alb
      call state_get_field_1d(importState, 'Sx_omask', nCells, atm_bnd%omask, rc, &
                              lonCell, latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
      ! Clamps [0,1] + NaN guard. Celula sem mapeamento geografico mantem
      ! 1,0 (oceano) — falha para o lado de NAO mascarar, preservando o
      ! comportamento anterior em vez de apagar dado bom.
      where (atm_bnd%omask < 0.0_MPAS_RKIND) atm_bnd%omask = 1.0_MPAS_RKIND
      where (atm_bnd%omask > 1.0_MPAS_RKIND) atm_bnd%omask = 1.0_MPAS_RKIND
      where (atm_bnd%omask /= atm_bnd%omask)  atm_bnd%omask = 1.0_MPAS_RKIND
    end if

    call log_debug(COMP_ATM, subname//': importacao concluida ' // &
      '(Sx_tsfc + Si_ifrac + So_u + So_v + Sf_zorl + Sf_albedo + Sx_omask)')

    ! ── Diagnóstico de importação MED→MPAS ──────────────────────────────
    ! Escrito quando write_import_diag=.true. em &nuopc_docn do nuopc.input
    ! (mesmo flag usado pelo MED). Ativa a escrita dos 3 campos OCN→ATM:
    !   So_t     (SST [K])            — atm_bnd%sst
    !   Si_ifrac (fração de gelo)     — atm_bnd%ice_fraction
    !   Sf_zorl  (rugosidade [m])     — atm_bnd%zorl
    ! Arquivo: <cfg_import_diag_dir>/monan2_import_YYYYMMDD_HHMMSS.nc
    if (cfg_write_import_diag) then
      call write_mpas_import_diag(diag_clock, atm_bnd, nCells, lonCell, latCell, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS   ! diagnóstico não-fatal
    end if
  end subroutine mpas_import

  subroutine fill_invalid_sst(nCells, atm_bnd, latCell)
    integer, intent(in) :: nCells
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    real(MPAS_RKIND), optional, intent(in) :: latCell(:)
    real(MPAS_RKIND), parameter :: T_FILL_POLAR    = 271.35_MPAS_RKIND
    real(MPAS_RKIND), parameter :: RAD2DEG = 180.0_MPAS_RKIND / &
    3.14159265358979_MPAS_RKIND
    logical,          allocatable :: invalid_sst(:)
    real(MPAS_RKIND), allocatable :: lat_deg(:), frac(:), t_fallback(:)
    real(MPAS_RKIND) :: t_fill_tropical
    integer :: n
    ! Usa nCells (a mesma contagem de lonCell/latCell nas chamadas de
    ! state_get_field_1d de mpas_import), e nao size(atm_bnd%sst): atm_bnd%sst
    ! pode ser maior que latCell/lonCell (celulas de halo), e usar o tamanho
    ! dele causa 'Array bound mismatch'.
    n = nCells
    t_fill_tropical = real(cfg_sst_default, MPAS_RKIND)
    allocate(invalid_sst(n), t_fallback(n))
    invalid_sst = (atm_bnd%sst(1:n) < 270.0_MPAS_RKIND .or. &
                    atm_bnd%sst(1:n) > 310.0_MPAS_RKIND .or. &
                    atm_bnd%sst(1:n) /= atm_bnd%sst(1:n))       ! NaN guard
    if (present(latCell)) then
      allocate(lat_deg(n), frac(n))
      lat_deg = abs(latCell(1:n)) * RAD2DEG                 ! 0..90
      frac    = min(1.0_MPAS_RKIND, max(0.0_MPAS_RKIND, lat_deg / 90.0_MPAS_RKIND))
      ! frac=0 no equador (usa t_fill_tropical), frac=1 no polo (usa T_FILL_POLAR)
      t_fallback = t_fill_tropical + (T_FILL_POLAR - t_fill_tropical) * frac
      deallocate(lat_deg, frac)
    else
      ! Sem coordenadas disponiveis: mantem o fallback tropical unico,
      ! por seguranca — nao deveria ocorrer em uso normal, ja que
      ! lonCell/latCell sao sempre passados por quem chama.
      t_fallback = t_fill_tropical
    end if
    where (invalid_sst) atm_bnd%sst(1:n) = t_fallback
    deallocate(invalid_sst, t_fallback)
  end subroutine fill_invalid_sst

  !> @brief Exporta campos de atm_public para o exportState ESMF.
  !!
  !! Campos exportados (nomes CMEPS com sufixo _mpas):
  !!   Sa_pslv_mpas, Sa_tbot_mpas, Sa_u10m_mpas, Sa_v10m_mpas, Sa_shum_mpas,
  !!   Faxa_swdn_mpas, Faxa_lwdn_mpas, Faxa_rain_mpas, Faxa_snow_mpas.
  !!
  !! Tambem Faxa_sen_mpas, Faxa_lat_mpas, Faxa_taux_mpas e Faxa_tauy_mpas:
  !!   fluxos JA calculados pelo esquema de camada limite do MONAN-A
  !!   (atm_public%shflx/lhflx vindos de 'hfx'/'lh' do pool
  !!   diag/diag_physics; taux_sfc/tauy_sfc derivados de 'ust' em
  !!   mpas_atm_fluxes.F90). Com eles, o mediador usa o fluxo consistente com o
  !!   balanco de energia do PBL do MONAN-A (apply_native_fluxes em
  !!   med_flux.F90), em vez de recalcular sensivel/latente/momento pelo bulk
  !!   NCAR a partir de T/q/vento de 10 m.
  !!
  !! CONFIRMADO: convencao de sinal de 'hfx'/'lh' verificada com a
  !!   equipe de fisica do MONAN-A — POSITIVO PARA CIMA (superficie ->
  !!   atmosfera), convencao usual WRF/MPAS/GFS. O mediador (med_flux.F90) inverte o
  !!   sinal ao consumir estes campos (ver comentario la), consistente com
  !!   esta confirmacao.
  !!
  !! Campos não associados (pool diag_physics inativo ou nome ausente no
  !! Registry.xml) são silenciosamente ignorados.
  !!
  !! @param[inout] diag  gravador monan_export_*.nc do cap: guarda os campos
  !!                     MPAS locais para export_write_netcdf
  subroutine mpas_export(diag, atm_public, exportState, rc)
    type(mpas_diag_export_t),   intent(inout) :: diag
    type(mpas_atm_public_type), intent(in)    :: atm_public
    type(ESMF_State),           intent(inout) :: exportState
    integer,                    intent(inout) :: rc

    integer :: n
    type(ESMF_VM) :: vm
    character(len=*), parameter :: subname = 'mpas_export'

    rc = ESMF_SUCCESS
    call ESMF_VMGetCurrent(vm, rc=rc); if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS

    ! usar nCellsSolve (células próprias, sem halos)
    n  = merge(atm_public%nCellsSolve, atm_public%nCells, atm_public%nCellsSolve > 0)

    ! Para cada campo: netcdf_push_raw_field guarda o dado MPAS ANTES de
    ! state_set_field_1d, o que garante a correspondência dado(k) ↔
    ! diag%lon_local(k) em voronoi_accum_local (export_mpas_member).
    call export_mpas_member(diag, exportState, 'Sa_pslv_mpas',   atm_public%pslv, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Sa_tbot_mpas',   atm_public%t2m, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Sa_u10m_mpas',   atm_public%u10, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Sa_v10m_mpas',   atm_public%v10, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Faxa_swdn_mpas', atm_public%swdn_sfc, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Faxa_lwdn_mpas', atm_public%lwdn_sfc, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Faxa_rain_mpas', atm_public%prec_rain, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Sa_shum_mpas',   atm_public%q2m, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Faxa_snow_mpas', atm_public%prec_snow, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    ! ── fluxos nativos do PBL (ver docstring) ──────────────────────────
    call export_mpas_member(diag, exportState, 'Faxa_sen_mpas',  atm_public%shflx, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Faxa_lat_mpas',  atm_public%lhflx, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Faxa_taux_mpas', atm_public%taux_sfc, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call export_mpas_member(diag, exportState, 'Faxa_tauy_mpas', atm_public%tauy_sfc, n, vm, atm_public, rc)
    if (rc /= ESMF_SUCCESS) return
    call log_debug(COMP_ATM, subname//': exportacao concluida')

  end subroutine mpas_export

  !> Exporta um membro de atm_public, se associado: guarda o dado MPAS local
  !! no gravador (netcdf_push_raw_field, cujo código de retorno é ignorado)
  !! e o leva ao campo fname do exportState (state_set_field_1d). Membro
  !! não associado é ignorado sem erro.
  !!
  !! @param[inout] rc  ESMF_SUCCESS, ou a falha de state_set_field_1d
  subroutine export_mpas_member(diag, exportState, fname, member, n, vm, atm_public, rc)
    type(mpas_diag_export_t),   intent(inout) :: diag
    type(ESMF_State),           intent(inout) :: exportState
    character(len=*),           intent(in)    :: fname
    real(MPAS_RKIND), pointer,  intent(in)    :: member(:)
    integer,                    intent(in)    :: n
    type(ESMF_VM),              intent(in)    :: vm
    type(mpas_atm_public_type), intent(in)    :: atm_public
    integer,                    intent(inout) :: rc

    if (associated(member)) then
      call netcdf_push_raw_field(diag, fname, member, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, fname, n, member, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
  end subroutine export_mpas_member

  !> @brief Cria a ESMF_Grid regular 360x180 (1 grau) do cap MPAS.
  !!
  !! O cap usa ESMF_Grid, e nao ESMF_Mesh: com ESMF_MOAB habilitado (build
  !! do ESMF 8.9.1), as operacoes paralelas sobre ESMF_Mesh
  !! (ESMF_MeshAddNodes, ESMF_MeshAddElements, ESMF_FieldCreate) entravam em
  !! deadlock depois de mpas_atm_init; o SMIOL do MPAS-A deixa o comunicador
  !! MPI num estado incompativel com o MOAB. ESMF_Grid nao usa MOAB, e os
  !! conectores ficam Grid->Grid.
  !!
  !! A grade e' a malha atm_cap do mapa de acoplamento, construida por
  !! cpl_latlon_grid (cpl_grids): 64800 celulas, periodica em longitude,
  !! centros de -179.5 a +179.5 graus em longitude e de -89.5 a +89.5 em
  !! latitude, um DE por PET, com a mesma decomposicao da malha de fluxo do
  !! mediador.
  subroutine mpas_create_grid(grid, rc)
    type(ESMF_Grid), intent(out) :: grid
    integer,         intent(out) :: rc

    integer  :: petCount
    type(ESMF_VM) :: vm
    character(len=*), parameter :: subname = 'mpas_create_grid'

    rc = ESMF_SUCCESS

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call cpl_latlon_grid('atm_cap', ATM_NX, ATM_NY, ORIGIN_WEST180, .false., petCount, &
                          grid, rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    call log_info(COMP_ATM, subname//': ESMF_Grid 360x180 criada')

  end subroutine mpas_create_grid

  !> @brief Escreve estatísticas dos campos do estado no log ESMF.
  !!
  !! Ativado por DumpFields='true' (atributo NUOPC).
  !! Para cada campo do estado escreve: nome, min, max, média.
  subroutine state_diagnose(state, state_tag, rc)
    type(ESMF_State), intent(in)  :: state
    character(len=*), intent(in)  :: state_tag
    integer,          intent(out) :: rc

    type(ESMF_Field)              :: field
    character(len=64), allocatable :: fldnames(:)
    integer :: itemCount, i, localrc
    character(len=160) :: msg
    character(len=*), parameter :: subname = 'state_diagnose'
        real(ESMF_KIND_R8), pointer :: fp1d(:)
        real(ESMF_KIND_R8), pointer :: fp2d(:,:)
        real(ESMF_KIND_R8), allocatable :: vals(:)
        integer :: fdr

    rc = ESMF_SUCCESS

    call ESMF_StateGet(state, itemCount=itemCount, rc=localrc)
    if (localrc /= ESMF_SUCCESS .or. itemCount == 0) then
      call log_info(COMP_ATM, subname//': '//trim(state_tag)//' vazio')
      return
    end if

    allocate(fldnames(itemCount))
    call ESMF_StateGet(state, itemNameList=fldnames, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      deallocate(fldnames); return
    end if

    write(msg,'(A,A)') subname//': ', trim(state_tag)
    call log_info(COMP_ATM, trim(msg))

    do i = 1, itemCount
      call ESMF_StateGet(state, itemName=trim(fldnames(i)), field=field, rc=localrc)
      if (localrc /= ESMF_SUCCESS) cycle
        nullify(fp1d, fp2d)
        call ESMF_FieldGet(field, dimCount=fdr, rc=localrc)
        if (localrc /= ESMF_SUCCESS) cycle
        if (fdr == 1) then
          call ESMF_FieldGet(field, farrayPtr=fp1d, rc=localrc)
          if (localrc /= ESMF_SUCCESS .or. .not. associated(fp1d)) cycle
          if (size(fp1d) == 0) cycle
          vals = fp1d
          nullify(fp1d)
        else
          call ESMF_FieldGet(field, farrayPtr=fp2d, rc=localrc)
          if (localrc /= ESMF_SUCCESS .or. .not. associated(fp2d)) cycle
          if (size(fp2d) == 0) cycle
          vals = pack(fp2d, .true.)
          nullify(fp2d)
        end if
        write(msg,'(A,A,3(A,ES11.4))') &
          '  ', trim(fldnames(i)), &
          '  min=', minval(vals), &
          '  max=', maxval(vals), &
          '  mean=', sum(vals) / real(size(vals), ESMF_KIND_R8)
        call log_info(COMP_ATM, trim(msg))
      if (allocated(vals)) deallocate(vals)
    end do

    deallocate(fldnames)

  end subroutine state_diagnose

  ! ── privado ─────────────────────────────────────────────────────────────


  !> @brief Copia campo do ESMF_State para array Fortran 1D (celulas MPAS).
  !!
  !! Campo rank-1: copia posicional das primeiras celulas, sem alterar o
  !! resto de data(). Campo rank-2 (ESMF_Grid 360x180): o campo completo e'
  !! reunido no PET 0 (ESMF_FieldGather) e difundido a todos os PETs
  !! (ESMF_VMBroadcast), porque a malha MPAS e a grade do cap tem
  !! decomposicoes independentes; com lon_rad/lat_rad presentes, cada celula
  !! MPAS recebe o ponto da grade que contem sua posicao geografica; sem as
  !! coordenadas, a copia segue a ordem global linear.
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
    character(len=*), parameter  :: subname = 'state_get_field_1d'
    logical :: found
        real(ESMF_KIND_R8), parameter :: DLON = 1.0_ESMF_KIND_R8
        real(ESMF_KIND_R8), parameter :: DLAT = 1.0_ESMF_KIND_R8
        real(ESMF_KIND_R8), parameter :: FILL_THR = 1.0e19_ESMF_KIND_R8
        real(ESMF_KIND_R8), allocatable :: buf2d(:,:)
        real(ESMF_KIND_R8), allocatable :: buf1d(:)
        type(ESMF_VM) :: vm_l
        integer :: localPet_l
        integer :: icell
        integer :: ig
        integer :: jg
        real(ESMF_KIND_R8) :: lon_d
        real(ESMF_KIND_R8) :: lat_d
        real(ESMF_KIND_R8) :: val

    rc = ESMF_SUCCESS
    nullify(fptr1d)

    call find_local_field(state, fldname, subname, field, fld_rank, found)
    if (.not. found) return

    if (fld_rank == 1) then
      ! Campo rank-1: ESMF_Mesh ou ESMF_Grid 1D
      ! o campo rank-1 pode ter decomposição diferente
      ! da malha MPAS local. Exemplo: Sf_zorl chega na malha Voronoi via
      ! conector MED→MPAS, mas o PET OCN tem nCells_OCN ≠ nCells_MPAS.
      ! Cópia posicional (i-ésimo OCN → i-ésima MPAS) é geograficamente
      ! incorreta e zeraria as células não cobertas, sobrepondo o default.
      ! Por isso: copiar apenas o mínimo necessário e NÃO alterar o restante
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
      ! ── Campo rank-2: ESMF_Grid regular 360×180 (INDEX_GLOBAL) ──
      !
      ! Por que reunir o campo inteiro
      ! ------------------------------------------------------------------
      ! Ler fptr2d(ig,jg) só quando o ponto de grade global (ig,jg) pertence ao
      ! tile LOCAL deste PET não basta: a malha MPAS (que CONSOME o dado) e a
      ! grade do cap (que o PRODUZ) têm decomposições MPI INDEPENDENTES, e a
      ! maioria das células MPAS precisa de um ponto de grade de OUTRO PET.
      ! Sem isso, essas células ficariam no valor padrão de data() (So_t ≈ 298 K
      ! e Sf_zorl ≈ 0,01 m em quase todo o globo).
      !
      ! Solução: reunir o campo COMPLETO no PET 0 (ESMF_FieldGather) e
      ! difundi-lo a todos os PETs (ESMF_VMBroadcast). Com a cópia global
      ! disponível localmente, cada PET mapeia QUALQUER célula MPAS para o
      ! ponto de grade correto. Custo: 1 gather + 1 broadcast de NLON·NLAT
      ! reais R8 (~0,5 MB) por campo/passo — desprezível frente ao MPAS.
      !
      ! Segurança coletiva: FieldGather/VMBroadcast são coletivas — todos os
      ! PETs devem alcançá-las. mpas_create_grid usa regDecomp que cobre
      ! petCount, garantindo ≥1 DE por PET; logo o guard (localDeCount==0)
      ! acima não dispara para estes campos e não há risco de deadlock.

        call ESMF_VMGetCurrent(vm_l, rc=rc)
        if (rc /= ESMF_SUCCESS) then; rc = ESMF_SUCCESS; return; end if
        call ESMF_VMGet(vm_l, localPet=localPet_l, rc=rc)
        if (rc /= ESMF_SUCCESS) then; rc = ESMF_SUCCESS; return; end if

        ! 1) Reunir o campo distribuído (ordem de índice global) no PET 0.
        allocate(buf2d(ATM_NX, ATM_NY))
        buf2d = FILL_VALUE_R8
        call ESMF_FieldGather(field, farray=buf2d, rootPet=0, rc=rc)
        if (rc /= ESMF_SUCCESS) then
          deallocate(buf2d); rc = ESMF_SUCCESS; return
        end if

        ! 2) Difundir a cópia global a todos os PETs (buffer contíguo 1-D).
        allocate(buf1d(ATM_NX*ATM_NY))
        if (localPet_l == 0) buf1d = reshape(buf2d, [ATM_NX*ATM_NY])
        call ESMF_VMBroadcast(vm_l, buf1d, ATM_NX*ATM_NY, 0, rc=rc)
        if (rc /= ESMF_SUCCESS) then
          deallocate(buf2d, buf1d); rc = ESMF_SUCCESS; return
        end if
        buf2d = reshape(buf1d, [ATM_NX, ATM_NY])

        ! 3) Mapeamento geográfico nearest-neighbor para TODAS as células MPAS.
        if (have_cell_coords(n, lon_rad, lat_rad)) then
          do icell = 1, n
            lon_d = real(lon_rad(icell), ESMF_KIND_R8) * RAD2DEG
            lat_d = real(lat_rad(icell), ESMF_KIND_R8) * RAD2DEG
            ! Convenção de longitude da grade
            ! ------------------------------------------------------------
            ! A grade do cap é criada em mpas_create_grid com longitudes de CENTRO
            ! coordX(ig) = -180 + (ig - 0.5)*DLON, ou seja ig=1 ↔ -179,5° e
            ! ig=360 ↔ +179,5° — convenção [-180, +180).
            ! Normalizar lon_d para [0, 360) e fazer ig = int(lon_d/DLON)+1
            ! deslocaria TODA a atribuição em 180° (dado do Atlântico no índice do
            ! Pacífico). Por isso lon é normalizada para [-180, +180) e indexada na
            ! mesma origem da grade.
            lon_d = lon_m180to180_floor(lon_d)        ! → [-180, +180)
            ig = index_trunc(lon_d + 180.0_ESMF_KIND_R8, DLON, ATM_NX)
            jg = index_trunc(lat_d +    90.0_ESMF_KIND_R8, DLAT, ATM_NY)
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
          n_esmf = min(ATM_NX*ATM_NY, n)
          data(1:n_esmf) = real(buf1d(1:n_esmf), MPAS_RKIND)
        end if

        deallocate(buf2d, buf1d)
      if (allocated(buf2d)) deallocate(buf2d)
      if (allocated(buf1d)) deallocate(buf1d)
    end if
    rc = ESMF_SUCCESS

  end subroutine state_get_field_1d


  ! -------------------------------------------------------------------------
  ! Acesso aos campos do ESMF_State (de mpas_cell_binning até a R-FASE11-23)
  ! -------------------------------------------------------------------------

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
      call log_info(COMP_ATM, subname//': '//trim(fldname)//' nao encontrado')
      return
    end if

    call ESMF_FieldGet(field, localDeCount=localDeCount, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localDeCount == 0) return

    call ESMF_FieldGet(field, dimCount=fld_rank, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call log_warning(COMP_ATM, subname//': '//trim(fldname)//' dimCount query falhou')
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
    character(len=*), parameter  :: subname = 'state_set_field_1d'
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
      if (have_cell_coords(n, lon_rad, lat_rad)) then

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

  !> Há coordenadas das células: lon_rad e lat_rad presentes, cada um com ao
  !! menos n elementos. Os testes ficam em if separados porque o Fortran não
  !! garante o curto-circuito do .and., e size de um argumento ausente não
  !! pode ser avaliado.
  pure logical function have_cell_coords(n, lon_rad, lat_rad) result(ok)
    integer,          intent(in)           :: n
    real(MPAS_RKIND), intent(in), optional :: lon_rad(:), lat_rad(:)

    ok = .false.
    if (present(lon_rad) .and. present(lat_rad)) ok = size(lon_rad) >= n .and. size(lat_rad) >= n
  end function have_cell_coords

end module mpas_adapter_mod
