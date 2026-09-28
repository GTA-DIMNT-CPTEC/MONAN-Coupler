!> @file mpas_cap_methods.F90
!! @brief Importacao/exportacao de campos ESMF <-> MPAS-A e criacao de malha.
!!
!! Importação e exportação entre os campos ESMF e o MPAS-A (mpas_import,
!! mpas_export), a grade ESMF do cap (mpas_create_grid) e a cópia de campos
!! entre o ESMF_State e os arranjos das células MPAS. O diagnóstico NetCDF
!! fica em mpas_cap_netcdf.F90.

module mpas_cap_methods_mod

  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY, RAD2DEG
  use mpi
  use mpas_atm_types_mod, only : mpas_atm_public_type,   &
                                  atm_ocean_boundary_type, &
                                  MPAS_RKIND
  use coupler_utils_mod, only : ChkErr
  ! cfg_zorl_default usado como fallback NaN-guard em mpas_import
  ! cfg_sst_default adicionado — usado como
  ! fallback no guard de SST agora aplicado (ver abaixo).
  use coupler_config_mod, only : cfg_zorl_default,          &
                                   cfg_sst_default,           &
                                   cfg_write_import_diag,     &
                                   cfg_import_diag_dir,       &
                                   cfg_grid_res_deg
  ! netcdf_push_raw_field captura dado MPAS ANTES de state_set_field_1d
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
  !! Importa os campos do mediador MED->MPAS (IMP_NAMES), entre eles:
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
  subroutine mpas_import(importState, atm_bnd, nCells, rc, lonCell, latCell)
    type(ESMF_State),              intent(in)    :: importState
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,                       intent(in)    :: nCells
    integer,                       intent(inout) :: rc
    real(MPAS_RKIND), optional,    intent(in)    :: lonCell(:)  !< lon celulas [rad, 0..2pi]
    real(MPAS_RKIND), optional,    intent(in)    :: latCell(:)  !< lat celulas [rad, -pi/2..pi/2]

    character(len=*), parameter :: subname = '(mpas_import)'
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
    ! (mpas_atm_model.F90). Qualquer celula da malha Voronoi que caia perto de
    ! uma regiao sem mapeamento valido no regrid grade-regular->Voronoi (ex.:
    ! extremos de latitude/polos) pode chegar aqui como NaN ou valor fisico
    ! absurdo, alimentando core_run sem protecao — candidato direto para o
    ! SIGSEGV recorrente em core_run observado nesta sessao. Clamp usa a mesma
    ! faixa fisica ja adotada no mediador (MED_cap.F90: T_MIN=270, T_MAX=310).
    ! fallback agora depende da latitude — usar
    ! cfg_sst_default (~298K, valor tropical) para QUALQUER celula invalida,
    ! inclusive polar, introduz um vies quente artificial de ~27K exatamente
    ! nas altas latitudes (>60°), onde a agua do mar real fica perto do ponto
    ! de congelamento (~271.35K = -1.8°C, T_FILL_POLAR abaixo — mesmo valor
    ! ja usado como T_FILL no mediador, MED_cap.F90).
    ! degrau abrupto em 60° trocado por
    ! interpolacao LINEAR continua em |latitude| (graus), de T_FILL_TROPICAL
    ! no equador (0°) ate T_FILL_POLAR no polo (90°). Mais realista que um
    ! degrau (o perfil zonal real de SST decai suavemente, nao em bloco) e
    ! evita uma descontinuidade artificial de temperatura logo em 60°N/S
    ! caso o fallback seja usado numa faixa continua de celulas ali.
    if (allocated(atm_bnd%sst)) then
      call fill_invalid_sst(nCells, atm_bnd, latCell)
    end if

    ! -- Fracao de gelo marinho [0-1] -------------------------------------
    ! agora importado do SIS2 via mediador (era cfg_ice_fraction_default
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
    ! config_sfc_albedo=.false. no namelist (ver mpas_atm_model.F90,
    ! para confirmacao empirica de que o NOAH LSM
    ! nao sobrescreve o valor apos core_run).
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

    call ESMF_LogWrite(subname//': importacao Fase 2 concluida ' // &
      '(Sx_tsfc + Si_ifrac + So_u + So_v + Sf_zorl + Sf_albedo + Sx_omask)', &
      ESMF_LOGMSG_INFO)

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
    ! usar nCells (argumento explicito da
    ! subrotina, mesma contagem ja usada para lonCell/latCell em todas as
    ! chamadas de state_get_field_1d acima) em vez de size(atm_bnd%sst).
    ! A versao anterior usava size(atm_bnd%sst) e causou 'Array bound
    ! mismatch' em runtime — atm_bnd%sst aparentemente NAO tem sempre o
    ! mesmo tamanho de latCell/lonCell (possivelmente por halo). Limitando
    ! tudo a (1:nCells), consistente com o resto desta subrotina.
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
  !!   mpas_atm_model.F90). Com eles, o MED_cap usa o fluxo consistente com o
  !!   balanco de energia do PBL do MONAN-A (apply_native_fluxes em
  !!   MED_cap.F90), em vez de recalcular sensivel/latente/momento pelo bulk
  !!   NCAR a partir de T/q/vento de 10 m.
  !!
  !! CONFIRMADO: convencao de sinal de 'hfx'/'lh' verificada com a
  !!   equipe de fisica do MONAN-A — POSITIVO PARA CIMA (superficie ->
  !!   atmosfera), convencao usual WRF/MPAS/GFS. O MED_cap.F90 ja inverte o
  !!   sinal ao consumir estes campos (ver comentario la), consistente com
  !!   esta confirmacao.
  !!
  !! Campos não associados (pool diag_physics inativo ou nome ausente no
  !! Registry.xml) são silenciosamente ignorados.
  subroutine mpas_export(atm_public, exportState, rc)
    type(mpas_atm_public_type), intent(in)    :: atm_public
    type(ESMF_State),           intent(inout) :: exportState
    integer,                    intent(inout) :: rc

    integer :: n
    type(ESMF_VM) :: vm
    character(len=*), parameter :: subname = '(mpas_export)'

    rc = ESMF_SUCCESS
    call ESMF_VMGetCurrent(vm, rc=rc); if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS

    ! usar nCellsSolve (células próprias, sem halos)
    n  = merge(atm_public%nCellsSolve, atm_public%nCells, atm_public%nCellsSolve > 0)

    ! netcdf_push_raw_field captura dado MPAS ANTES de state_set_field_1d.
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
    ! ── fluxos nativos do PBL (antes descartados, ver docstring) ──────
    if (associated(atm_public%shflx)) then
      call netcdf_push_raw_field('Faxa_sen_mpas', atm_public%shflx, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_sen_mpas', n, atm_public%shflx, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%lhflx)) then
      call netcdf_push_raw_field('Faxa_lat_mpas', atm_public%lhflx, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_lat_mpas', n, atm_public%lhflx, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%taux_sfc)) then
      call netcdf_push_raw_field('Faxa_taux_mpas', atm_public%taux_sfc, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_taux_mpas', n, atm_public%taux_sfc, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    if (associated(atm_public%tauy_sfc)) then
      call netcdf_push_raw_field('Faxa_tauy_mpas', atm_public%tauy_sfc, n, vm, rc)
      rc = ESMF_SUCCESS
      call state_set_field_1d(exportState, 'Faxa_tauy_mpas', n, atm_public%tauy_sfc, rc, &
           atm_public%lonCell, atm_public%latCell)
      if (ChkErr(rc, __LINE__, u_FILE_u)) return
    end if
    call ESMF_LogWrite(subname//': exportacao concluida', ESMF_LOGMSG_INFO)

  end subroutine mpas_export

  !> @brief Cria a ESMF_Grid regular 360x180 (1 grau) do cap MPAS.
  !!
  !! O cap usa ESMF_Grid, e nao ESMF_Mesh: com ESMF_MOAB habilitado (build
  !! do ESMF 8.9.1), as operacoes paralelas sobre ESMF_Mesh
  !! (ESMF_MeshAddNodes, ESMF_MeshAddElements, ESMF_FieldCreate) entravam em
  !! deadlock depois de mpas_atm_init; o SMIOL do MPAS-A deixa o comunicador
  !! MPI num estado incompativel com o MOAB. ESMF_Grid nao usa MOAB, e os
  !! conectores ficam Grid->Grid.
  !!
  !! Grade de 64800 celulas, periodica em longitude (ESMF_GridCreate1PeriDim),
  !! coordenadas lon/lat nos centros (ESMF_STAGGERLOC_CENTER) e um DE por PET
  !! (fatoracao exata de petCount, abaixo).
  subroutine mpas_create_grid(grid, rc)
    type(ESMF_Grid), intent(out) :: grid
    integer,         intent(out) :: rc

    real(ESMF_KIND_R8), parameter :: DLON = 1.0_ESMF_KIND_R8
    real(ESMF_KIND_R8), parameter :: DLAT = 1.0_ESMF_KIND_R8

    real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)
    integer  :: i, j, clbX(2), cubX(2), clbY(2), cubY(2)
    integer  :: petCount, regDecomp(2), localDeCount
    integer  :: nx_max, ny_tiles, lde
    integer  :: nx_tiles_target
    type(ESMF_VM) :: vm
    character(len=*), parameter :: subname = '(mpas_create_grid)'

    rc = ESMF_SUCCESS

    ! Decomposicao: fatorar petCount EXATAMENTE em colunas x linhas, um DE por
    ! PET, no par mais proximo de quadrado (linhas = maior divisor <= sqrt(N);
    ! colunas = cofator), com colunas <= NLON/2 e linhas <= NLAT. Com mais DEs
    ! que PETs, alguns PETs ficariam com dois DEs, e o ESMF_FieldGather
    ! reuniria no PET 0 so' um DE por PET: o resto do campo ficaria no valor
    ! de preenchimento, com buracos na forcante atmosferica (o MOM6 aborta com
    ! "extreme surface values"). Tiles quase quadradas tambem evitam faixas
    ! muito estreitas, que travavam o ESMF_FieldBundleRegridStore. Casos:
    !   N=16→(4,4)  N=32→(8,4)  N=64→(8,8)  N=128→(16,8)  N=512→(32,16)
    ! Um primo grande degenera para faixa (N=17→17x1), com cobertura total.
    ! -------------------------------------------------------------------------
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! Fatoração exata: maior divisor de petCount que seja <= sqrt(petCount) e
    ! caiba em NLAT dá o número de LINHAS (nrow); o cofator dá as COLUNAS (ncol).
    ! Atribui o maior fator a lon (grade 360x180 é 2:1), aproximando tiles
    ! quadradas. Sempre existe solução (nrow=1 no pior caso, para petCount primo).
    nx_tiles_target = max(1, int(sqrt(real(petCount))))
    ny_tiles = 1
    do j = nx_tiles_target, 1, -1
      if (mod(petCount, j) == 0) then
        if (j <= ATM_NY .and. (petCount / j) <= ATM_NX / 2) then
          ny_tiles = j            ! linhas (lat) = menor fator
          exit
        end if
      end if
    end do
    nx_max = petCount / ny_tiles  ! colunas (lon) = maior fator = cofator
    regDecomp(1) = nx_max         ! lon tiles
    regDecomp(2) = ny_tiles       ! lat tiles
    ! Invariante: regDecomp(1)*regDecomp(2) == petCount (1 DE por PET).

    ! Grade regular 1 grau, periódica em lon.
    ! Pré-condição: indexflag=ESMF_INDEX_GLOBAL garante que
    ! lbound(fptr2d,1) seja o índice global real do PET (e.g., 61 para o segundo
    ! PET de 60 colunas), não 1. Sem isso, state_set_field_1d não consegue calcular
    ! a longitude geográfica correta para o deslocamento buf_global→fptr2d.
    grid = ESMF_GridCreate1PeriDim( &
      minIndex   = (/1, 1/),           &
      maxIndex   = (/ATM_NX, ATM_NY/),     &
      regDecomp  = regDecomp,          &
      indexflag  = ESMF_INDEX_GLOBAL,  &
      coordSys   = ESMF_COORDSYS_SPH_DEG, &
      rc         = rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! ESMF_GridAddCoord é COLETIVA — todos os PETs devem chamá-la.
    call ESMF_GridAddCoord(grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! guard localDeCount>0 — com regDecomp 2D e DEs>petCount,
    ! todos os PETs têm ≥1 DE; guard mantido por segurança para N > nx_max*ny_tiles.
    call ESMF_GridGet(grid, localDeCount=localDeCount, rc=rc)
    if (ChkErr(rc, __LINE__, u_FILE_u)) return

    ! Laco explicito sobre cada DE local: ESMF_GridGetCoord sem localDE= falha
    ! ("must provide localDe argument for localDeCount > 1") se um PET tiver
    ! mais de um DE.
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
    character(len=*), parameter :: subname = '(state_diagnose)'
        real(ESMF_KIND_R8), pointer :: fp1d(:)
        real(ESMF_KIND_R8), pointer :: fp2d(:,:)
        real(ESMF_KIND_R8), allocatable :: vals(:)
        integer :: fdr

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
  !! (ESMF_VMBroadcast), porque a malha MPAS e a grade g_grid tem
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
    character(len=*), parameter  :: subname = '(state_get_field_1d)'
      integer :: localDeCount_sg
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

    call ESMF_StateGet(state, itemName=fldname, field=field, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' nao encontrado', ESMF_LOGMSG_INFO)
      rc = ESMF_SUCCESS
      return
    end if

    ! verificar localDeCount ANTES de farrayPtr (evita erro ESMF log).
      call ESMF_FieldGet(field, localDeCount=localDeCount_sg, rc=rc)
      if (rc /= ESMF_SUCCESS .or. localDeCount_sg == 0) then
        rc = ESMF_SUCCESS; return
      end if

    ! Consultar rank do campo ANTES de chamar farrayPtr (evita erro ESMF)
    call ESMF_FieldGet(field, dimCount=fld_rank, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' dimCount query falhou', ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS; return
    end if

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
      ! ── Campo rank-2: ESMF_Grid regular 360×180 (g_grid, INDEX_GLOBAL) ──
      !
      ! Por que reunir o campo inteiro
      ! ------------------------------------------------------------------
      ! Ler fptr2d(ig,jg) só quando o ponto de grade global (ig,jg) pertence ao
      ! tile LOCAL deste PET não basta: a malha MPAS (que CONSOME o dado) e a
      ! grade g_grid (que o PRODUZ) têm decomposições MPI INDEPENDENTES, e a
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
        buf2d = -9.99e+20_ESMF_KIND_R8
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
        if (present(lon_rad) .and. present(lat_rad) .and. &
            size(lon_rad) >= n .and. size(lat_rad) >= n) then
          do icell = 1, n
            lon_d = real(lon_rad(icell), ESMF_KIND_R8) * RAD2DEG
            lat_d = real(lat_rad(icell), ESMF_KIND_R8) * RAD2DEG
            ! Convenção de longitude da grade
            ! ------------------------------------------------------------
            ! A g_grid é criada em mpas_create_grid com longitudes de CENTRO
            ! coordX(ig) = -180 + (ig - 0.5)*DLON, ou seja ig=1 ↔ -179,5° e
            ! ig=360 ↔ +179,5° — convenção [-180, +180).
            ! Normalizar lon_d para [0, 360) e fazer ig = int(lon_d/DLON)+1
            ! deslocaria TODA a atribuição em 180° (dado do Atlântico no índice do
            ! Pacífico). Por isso lon é normalizada para [-180, +180) e indexada na
            ! mesma origem da grade.
            lon_d = lon_d - floor((lon_d + 180.0_ESMF_KIND_R8) / 360.0_ESMF_KIND_R8) &
                            * 360.0_ESMF_KIND_R8          ! → [-180, +180)
            ig = int((lon_d + 180.0_ESMF_KIND_R8) / DLON) + 1
            jg = int((lat_d +  90.0_ESMF_KIND_R8) / DLAT) + 1
            ig = max(1, min(ig, ATM_NX))
            jg = max(1, min(jg, ATM_NY))
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
      integer :: localDeCount_ss

    rc = ESMF_SUCCESS
    nullify(fptr1d, fptr2d)

    call ESMF_StateGet(state, itemName=fldname, field=field, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite(subname//': '//trim(fldname)//' nao encontrado', ESMF_LOGMSG_INFO)
      rc = ESMF_SUCCESS
      return
    end if

    ! verificar localDeCount ANTES de farrayPtr (evita erro ESMF log).
      call ESMF_FieldGet(field, localDeCount=localDeCount_ss, rc=rc)
      if (rc /= ESMF_SUCCESS .or. localDeCount_ss == 0) then
        rc = ESMF_SUCCESS; return
      end if

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

      ! Mapeamento geografico por MEDIA (map_cells_to_regular_grid): varias
      ! celulas Voronoi, de PETs diferentes, podem cair no mesmo ponto (ig,jg)
      ! da grade 1°x1°, sobretudo perto dos polos. Uma soma simples dobraria o
      ! valor (Sa_pslv chegou a 2017 hPa). Por isso somam-se valores e contagens
      ! de todos os PETs, e o ponto recebe a media:
      !   buf_global(ig,jg) = buf_sum(ig,jg) / max(buf_count(ig,jg), 1)
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
      lon_d = lon_d - floor(lon_d / 360.0_ESMF_KIND_R8) * 360.0_ESMF_KIND_R8
      ig = int(lon_d / DLON) + 1
      jg = int((lat_d + 90.0_ESMF_KIND_R8) / DLAT) + 1
      ig = max(1, min(ig, ATM_NX))
      jg = max(1, min(jg, ATM_NY))
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
            lon_ii_d   = -180.0_ESMF_KIND_R8 + &
                         (real(ii, ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * DLON
            lon_0360_d = lon_ii_d
            if (lon_0360_d < 0.0_ESMF_KIND_R8) lon_0360_d = lon_0360_d + 360.0_ESMF_KIND_R8
            ig_buf = int(lon_0360_d / DLON) + 1
            ig_buf = max(1, min(ig_buf, ATM_NX))
            fptr2d(ii, jj) = buf_global(ig_buf, jj)
        end if
      end do
    end do
  end subroutine copy_to_local_grid


end module mpas_cap_methods_mod
