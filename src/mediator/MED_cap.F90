!==============================================================================!
! MED_cap_MONAN.F90 — Orquestrador NUOPC do mediador ATM-OCN do MONAN         !
!==============================================================================!
!                                                                              !
! Versão 2.5 (Mai/2026) — BUG-MED-ZERO: is%f_ifrac_atm era zerado antes de
!   fill_ifrac_from_oisst em Sprint B.1.1, destruindo o campo OISST de t=0.
!   O campo retém agora os valores entre passos e decai com τ=24h.
! Versão 2.4 (Mai/2026) — Sprint B.1.1 (fill_ifrac t=0 com med_ifrac_init_done)!
! Versão 2.0 (Mai/2026) — GT Acoplamento MONAN / INPE/CGCT/DIMNT              !
!                                                                              !
! Reorganização de responsabilidades (Passos 1–5):                            !
!   Tipos e constantes  → med_cap_types.F90   (med_cap_types_mod)             !
!   Física bulk NCAR    → med_bulk_ncar.F90   (med_bulk_ncar_mod)             !
!   Utilitários ESMF    → med_cap_methods.F90 (med_cap_methods_mod)           !
!   Diagnóstico NetCDF  → med_cap_netcdf.F90  (med_cap_netcdf_mod)            !
!                                                                              !
! Este arquivo contém apenas o ciclo de vida NUOPC puro do mediador:         !
!   SetServices, Initialize* (P0/Advertise/Realize/DataComplete)              !
!   MediatorAdvance — orquestrador que chama os módulos especializados        !
!                                                                              !
! Ver também cabeçalho do arquivo original para histórico de correções.      !
!==============================================================================!

module MED_cap_MONAN_mod
  use ESMF
  use ESMF, only: ESMF_State, ESMF_StateGet
  use mpi
  use mpas_cap_config_mod, only: cfg_docn_nx, cfg_docn_ny,         &
                                  cfg_use_docn_ice,                 &
                                  cfg_docn_ice_init_only,           &
                                  cfg_docn_ice_file,                &
                                  cfg_docn_ice_varname,             &
                                  cfg_docn_ice_pct,                 &
                                  cfg_docn_dt_data,                 &
                                  cfg_docn_epoch_year,              &
                                  cfg_docn_epoch_month,             &
                                  cfg_docn_epoch_day  ! Alternativa 1 + Sprint B.1.1
  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Advertise, NUOPC_Realize
  use NUOPC, only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet
  use NUOPC, only: NUOPC_CompAttributeGet, NUOPC_CompAttributeAdd
  use NUOPC_Mediator, only: med_routine_SS          => SetServices
  use NUOPC_Mediator, only: med_label_DataInitialize => label_DataInitialize
  use NUOPC_Mediator, only: med_label_Advance        => label_Advance
  use NUOPC_Mediator, only: med_label_CheckImport    => label_CheckImport
  use NUOPC_Mediator, only: NUOPC_MediatorGet
  ! Módulos especializados do mediador (reorganização Mai/2026)
  use med_cap_types_mod,   only: MED_InternalState,            &
                                  MED_InternalStateWrapper,     &
                                  n_import_mpas, import_mpas_names, &
                                  n_import_datm, import_datm_names, &
                                  n_export,      export_names,  &
                                  rho_air, Cd_neut, Ch_neut, Ce_neut, &
                                  Cp_air, L_evap, T_freeze, eps_q,    &
                                  es_coef_a, es_coef_b, es_coef_c,    &
                                  sigma_sb, albedo_ocn,               &
                                  SST_BULK_FALLBACK, SHUM_OCEAN_DEFAULT, &
                                  f_vis_dir, f_vis_dif, f_nir_dir, f_nir_dif, &
                                  med_write_import_diag, med_import_diag_dir, &
                                  med_mpi_comm, med_local_pet, med_pet_count
  use med_bulk_ncar_mod,   only: calc_bulk_ncar
  use med_cap_methods_mod, only: CreateInternalField, ZeroInternalField,   &
                                  FillInternalField,                        &
                                  GetFieldPtr, GetFieldPtrOptional,         &
                                  RegridOrCopy, RouteOcnToAtm,              &
                                  RegridOptionalCurrent
  use med_cap_netcdf_mod,  only: med_read_import_config, med_write_import_fields

  implicit none
  private
  public :: SetServices

  ! ── Variáveis de estado de módulo — Sprint B.1.1 ───────────────────────────
  !
  ! med_ifrac_init_done : .true. após fill_ifrac_from_oisst ser chamado na
  !   primeira MediatorAdvance.  Com save, retém o valor entre chamadas.
  !   DEVE estar no escopo do módulo para ser acessível tanto de
  !   InitializeAdvertise quanto de MediatorAdvance.
  !
  ! SI_IFRAC_DECAY_MED  : fator de decaimento de Si_ifrac por passo de
  !   acoplamento (dt=3600 s, τ=86400 s):  exp(-dt/τ) = exp(-1/24) ≈ 0.9592.
  !   Sincronizado com SI_IFRAC_DECAY em mom_cap_MONAN.F90.
  logical,                         save :: med_ifrac_init_done = .false.
  real(ESMF_KIND_R8),  parameter        :: SI_IFRAC_DECAY_MED  = 0.95924_ESMF_KIND_R8

contains

  !============================================================================
  ! SetServices
  !============================================================================
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(gcomp, med_routine_SS, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=InitializeP0, phase=0, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_Advance, &
      specRoutine=MediatorAdvance, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_CheckImport, &
      specRoutine=CheckImportNoop, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

  end subroutine SetServices

  !============================================================================
  ! CheckImportNoop
  !============================================================================
  subroutine CheckImportNoop(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc
    rc = ESMF_SUCCESS
    call ESMF_LogWrite('MED: CheckImport desabilitado (no-op)', ESMF_LOGMSG_INFO)
  end subroutine CheckImportNoop

  !============================================================================
  ! InitializeP0
  !============================================================================
  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS
    call NUOPC_CompFilterPhaseMap(gcomp, ESMF_METHOD_INITIALIZE, &
      acceptStringList=(/"IPDv03p"/), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
  end subroutine InitializeP0

  !============================================================================
  ! InitializeAdvertise
  !============================================================================
  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    integer :: n
    logical                         :: isPresent, isSet
    character(len=8)                :: attr_val
    ! use_mpas_atm lido aqui apenas para log; o valor persistente fica no estado interno
    ! criado em InitializeRealize.
    logical, save :: use_mpas_atm_advertise = .false.
    ! med_ifrac_init_done declarado no escopo do módulo (acessível em MediatorAdvance)

    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is

    rc = ESMF_SUCCESS

    allocate(iswrap%wrap)
    is => iswrap%wrap

    ! Inicializar todos os campos l�gicos do InternalState
    is%use_mpas_atm = use_mpas_atm_advertise

    ! Ler use_med_to_mpas do atributo NUOPC (definido por esm.F90)
    call NUOPC_CompAttributeGet(gcomp, name="use_med_to_mpas", &
      value=attr_val, rc=rc)
    if (rc == ESMF_SUCCESS) then
      is%use_med_to_mpas = (trim(attr_val) == 'true')
    else
      is%use_med_to_mpas = .false.
      rc = ESMF_SUCCESS  ! atributo opcional
    end if
    if (is%use_med_to_mpas) then
      call ESMF_LogWrite('MED: use_med_to_mpas=true — RouteOcnToAtm ativo', &
        ESMF_LOGMSG_INFO)
    end if
    is%rh_created   = .false.

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return    !--- Le atributo use_mpas_atm definido pelo driver em esm.F90 ---
    ! Valores aceitos: "true" ou "false" (default: "false" = usa DATM)
    call NUOPC_CompAttributeGet(gcomp, name="use_mpas_atm", &
      value=attr_val, isPresent=isPresent, isSet=isSet, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    if (isPresent .and. isSet) then
      use_mpas_atm_advertise = (trim(attr_val) == "true")
    end if
    if (use_mpas_atm_advertise) then
      call ESMF_LogWrite('MED: use_mpas_atm=true (MPAS como fonte primaria)', &
        ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite('MED: use_mpas_atm=false (DATM como fonte)', &
        ESMF_LOGMSG_INFO)
    end if

    ! Anuncia campos de import conforme a fonte atmosferica configurada.
    ! CRITICO: o NUOPC aborta em IPDv03p6 se um campo anunciado nao tiver
    ! conector ativo. Por isso MPAS e DATM sao anunciados exclusivamente.
    if (use_mpas_atm_advertise) then
      ! Modo MPAS: anuncia campos _mpas (fornecidos pelo MPAS_cap)
      do n = 1, n_import_mpas
        call NUOPC_Advertise(importState, StandardName=trim(import_mpas_names(n)), &
          TransferOfferGeomObject="cannot provide", &
          SharePolicyField="share", rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do
    else
      ! Modo DATM: anuncia campos sem sufixo (fornecidos pelo DATM_cap)
      ! SharePolicyField="share" evita bondLevel ambiguo para Faxa_rain/snow
      ! que aparecem tanto no importState quanto no exportState do MED.
      do n = 1, n_import_datm
        call NUOPC_Advertise(importState, StandardName=trim(import_datm_names(n)), &
          TransferOfferGeomObject="cannot provide", &
          SharePolicyField="share", rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do
    end if

    ! Advertise So_t (SST do OCN) - sempre presente (conector OCN->MED ativo nos dois modos)
    call NUOPC_Advertise(importState, StandardName="So_t", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! BUG-CALC-DUU (fix v13.0): anuncia So_u e So_v no importState do MED.
    ! O NUOPC só conecta campos mutuamente anunciados: o OCN exporta So_u/So_v
    ! mas o MED não os anunciava → o NUOPC descartava esses campos e o
    ! ESMF_StateGet subsequente gerava "ERROR: Not found" no log a cada passo.
    ! Com o anúncio, o conector OCN→MED cria RouteHandle para So_u e So_v,
    ! que chegam prontos ao MED para o cálculo de duu10n = |(V_atm − V_ocn)|².
    call NUOPC_Advertise(importState, StandardName="So_u", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call NUOPC_Advertise(importState, StandardName="So_v", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Advertise campos de export para o OCN
    do n = 1, n_export
      call NUOPC_Advertise(exportState, StandardName=trim(export_names(n)), &
        TransferOfferGeomObject="will provide", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do

    call ESMF_LogWrite('MED: InitializeAdvertise concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeAdvertise

  !============================================================================
  ! InitializeRealize
  ! CORRECAO 1: So_t (SST) realizado na grade OCN, nao na ATM.
  !   O campo So_t vem do componente OCN (grade ocn_grid). Realiz�-lo na
  !   atm_grid fazia com que o routehandle OCN->ATM tivesse src e dst na
  !   mesma grade, tornando o regrid incorreto.
  !============================================================================
  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    type(ESMF_Grid)  :: atm_grid, ocn_grid
    type(ESMF_Field) :: tmp_field
    type(ESMF_VM)    :: vm
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: nx_atm, ny_atm, nx_ocn, ny_ocn, i, j, n
    integer :: petCount, regDecomp(2), localDeCount_atm, localDeCount_ocn
    integer :: nx_max, ny_tiles, lde
    integer :: nx_tiles_target  ! B-57
    real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)
    integer :: ncid, varid, dimid
    real(ESMF_KIND_R8), allocatable :: ocn_lon(:,:), ocn_lat(:,:)
    logical             :: isPresent, isSet
    character(len=8)    :: attr_val

    rc = ESMF_SUCCESS

    ! Recuperar estado interno
    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
    line=__LINE__, file=__FILE__)) return
    is => iswrap%wrap

    !---------------------------------------------------------------------------
    ! CORRECAO: re-ler use_mpas_atm antes do branch de realizacao de campos.
    ! Em InitializeAdvertise, ESMF_GridCompSetInternalState e chamado ANTES
    ! de NUOPC_CompAttributeGet, entao is%use_mpas_atm fica .false. mesmo
    ! quando o atributo e "true". Lemos novamente aqui para corrigir.
    !---------------------------------------------------------------------------
    is%use_mpas_atm = .false.
    call NUOPC_CompAttributeGet(gcomp, name="use_mpas_atm", &
      value=attr_val, isPresent=isPresent, isSet=isSet, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    if (isPresent .and. isSet) is%use_mpas_atm = (trim(attr_val) == "true")
    if (is%use_mpas_atm) then
      call ESMF_LogWrite("MED: InitializeRealize modo MPAS (use_mpas_atm=true)", &
        ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite("MED: InitializeRealize modo DATM (use_mpas_atm=false)", &
        ESMF_LOGMSG_INFO)
    end if

    ! B-44/B-45/B-46: obter petCount para calcular regDecomp de ambas as grades.
    ! Sem regDecomp explícito, com N>ny PETs o ESMF gera DEs vazias (localDeCount=0)
    ! ou DEs de 1 linha, ambas incompatíveis com o conector bilinear NUOPC automático.
    ! regDecomp(2) = min(petCount, ny/2) garante ≥2 linhas/DE para qualquer N.
    call ESMF_VMGetCurrent(vm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha VMGetCurrent', &
      line=__LINE__, file=__FILE__)) return
    call ESMF_VMGet(vm, petCount=petCount, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha VMGet petCount', &
      line=__LINE__, file=__FILE__)) return

    ! ---------------------------------------------------------------------------
    ! Dimensões das grades internas do mediador:
    !   ATM: 360x180 (1°) — alinhada com a grade de saída do MPAS cap.
    !        Garante cobertura global via redistribuição ESMF (zero-copy).
    !   OCN: cfg_docn_nx x cfg_docn_ny — lidos de nuopc.input &nuopc_docn.
    !        Alinhada com DOCN_cap (OISST) — redistribuição zero-copy.
    nx_atm = 360
    ny_atm = 180
    nx_ocn = cfg_docn_nx  ! Grade DOCN de nuopc.input (ex: OISST 0.25° = 1440)
    ny_ocn = cfg_docn_ny  ! Grade DOCN de nuopc.input (ex: OISST 0.25° =  720)

    !--------------------------------------------------------------------------
    ! Criar grade ATM regular 640x320
    !--------------------------------------------------------------------------
    ! B-52 (fix B-50): regDecomp 2D universal — sem DE de largura 1 e sem PETs vazios.
    ! ATM 640x320: nx_max=320, ny=ceil(N/320)
    !   N=128: ny=1 → regDecomp=(/128,1/) → 640/128=5 col ✓
    !   N=512: ny=2 → regDecomp=(/320,2/) → 640 DEs>512, 640/320=2 col, 320/2=160 lin ✓
    nx_tiles_target = max(1, nint(sqrt(real(petCount))))
    nx_max       = min(nx_tiles_target, nx_atm / 2)
    ny_tiles     = (petCount + nx_max - 1) / nx_max
    regDecomp(1) = min(nx_max, petCount)
    regDecomp(2) = max(1, ny_tiles)
    ! ESMF_INDEX_GLOBAL: necessário para mapeamento global em med_write_import_fields.
    ! Loops bulk usam lbound/ubound — agnósticos ao indexflag do MPAS.
    atm_grid = ESMF_GridCreate1PeriDim(minIndex=(/1,1/), maxIndex=(/nx_atm, ny_atm/), &
      regDecomp=regDecomp, indexflag=ESMF_INDEX_GLOBAL, &
      coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha ao criar grade ATM", &
      line=__LINE__, file=__FILE__)) return

    ! ESMF_GridAddCoord: COLETIVA — todos os PETs
    call ESMF_GridAddCoord(atm_grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! B-45: verificar localDeCount antes de ESMF_GridGetCoord (chamada LOCAL)
    call ESMF_GridGet(atm_grid, localDeCount=localDeCount_atm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha GridGet localDeCount ATM', &
      line=__LINE__, file=__FILE__)) return

    ! B-53 (fix B-52): loop sobre DEs locais — com regDecomp 2D alguns PETs têm
    ! localDeCount=2; ESMF_GridGetCoord exige localDE= quando localDeCount > 1.
    do lde = 0, localDeCount_atm - 1
      call ESMF_GridGetCoord(atm_grid, coordDim=1, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          coordX(i,j) = (i-1) * (360.0_ESMF_KIND_R8/nx_atm) + &
                        (360.0_ESMF_KIND_R8/nx_atm) * 0.5_ESMF_KIND_R8
        end do
      end do
      call ESMF_GridGetCoord(atm_grid, coordDim=2, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          coordY(i,j) = -90.0_ESMF_KIND_R8 + (j-1)*(180.0_ESMF_KIND_R8/ny_atm) + &
                        (180.0_ESMF_KIND_R8/ny_atm)/2.0_ESMF_KIND_R8
        end do
      end do
    end do  ! lde ATM

    !--------------------------------------------------------------------------
    !--- Criar grade OCN com dimensões de nuopc.input (cfg_docn_nx x cfg_docn_ny) ---
    !--------------------------------------------------------------------------
    ! B-52 (fix B-51+B-50): regDecomp 2D universal para grade OCN.
    ! largura 1 para qualquer petCount. Grade alinhada com DOCN_cap (OISST 0.25°)
    ! → conector DOCN→MED usa redistribuição (zero-copy) em vez de bilinear.
    !   N=512: ny=4 → regDecomp=(/128,4/) → 512 DEs=512 PETs, 2 col, 39 lin ✓
    nx_tiles_target = max(1, nint(sqrt(real(petCount))))
    nx_max       = min(nx_tiles_target, nx_ocn / 2)
    ny_tiles     = (petCount + nx_max - 1) / nx_max
    regDecomp(1) = min(nx_max, petCount)
    regDecomp(2) = max(1, ny_tiles)
    ! ESMF_INDEX_GLOBAL: consistência com atm_grid para med_write_import_fields.
    ocn_grid = ESMF_GridCreateNoPeriDim(minIndex=(/1,1/), maxIndex=(/nx_ocn, ny_ocn/), &
      regDecomp=regDecomp, indexflag=ESMF_INDEX_GLOBAL, &
      coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha ao criar grade OCN", &
      line=__LINE__, file=__FILE__)) return

    ! ESMF_GridAddCoord: COLETIVA — todos os PETs
    call ESMF_GridAddCoord(ocn_grid, staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! B-45: verificar localDeCount antes de ESMF_GridGetCoord (chamada LOCAL)
    call ESMF_GridGet(ocn_grid, localDeCount=localDeCount_ocn, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha GridGet localDeCount OCN', &
      line=__LINE__, file=__FILE__)) return

    do lde = 0, localDeCount_ocn - 1
      call ESMF_GridGetCoord(ocn_grid, coordDim=1, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX, rc=rc)
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          coordX(i,j) = (i-1) * (360.0_ESMF_KIND_R8/nx_ocn)
        end do
      end do
      call ESMF_GridGetCoord(ocn_grid, coordDim=2, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          coordY(i,j) = -90.0_ESMF_KIND_R8 + (j-1)*(180.0_ESMF_KIND_R8/ny_ocn) + &
                        (180.0_ESMF_KIND_R8/ny_ocn)/2.0_ESMF_KIND_R8
        end do
      end do
    end do  ! lde OCN

    ! Opção 1: item de MÁSCARA na grade OCN (terra = SST fill ≈200 K do MOM6).
    call ESMF_GridAddItem(ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
      staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha GridAddItem MASK OCN', &
      line=__LINE__, file=__FILE__)) return
    block
      integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
      integer :: lde_m
      do lde_m = 0, localDeCount_ocn - 1
        call ESMF_GridGetItem(ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
          staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_m, &
          farrayPtr=maskptr, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(maskptr)) maskptr = 0
      end do
    end block

    !--------------------------------------------------------------------------
    ! Realizar campos de import conforme a fonte atmosferica configurada.
    ! Espelha exatamente o que foi anunciado em InitializeAdvertise.
    !--------------------------------------------------------------------------
    if (is%use_mpas_atm) then
      do n = 1, n_import_mpas
        tmp_field = ESMF_FieldCreate(grid=atm_grid, typekind=ESMF_TYPEKIND_R8, &
          staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(import_mpas_names(n)), rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
        call NUOPC_Realize(importState, field=tmp_field, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do
    else
      do n = 1, n_import_datm
        tmp_field = ESMF_FieldCreate(grid=atm_grid, typekind=ESMF_TYPEKIND_R8, &
          staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(import_datm_names(n)), rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
        call NUOPC_Realize(importState, field=tmp_field, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
          line=__LINE__, file=__FILE__)) return
      end do
    end if

    !--------------------------------------------------------------------------
    ! Realizar So_t (SST) na grade ATM (placeholder)
    ! CORRECAO 1: So_t (SST) realizado na grade OCN (era atm_grid - bug critico)
    ! O campo So_t vem do oceano, portanto sua grade nativa e ocn_grid.
    ! Realiza-lo na atm_grid causava conflito ao criar o routehandle OCN->ATM.
    !--------------------------------------------------------------------------
    tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name="So_t", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! BUG-CALC-DUU (fix v13.0): realizar So_u e So_v na grade OCN.
    ! Simétrico ao tratamento de So_t: correntes vêm do OCN, portanto
    ! devem ser realizadas em ocn_grid para que o rh_ocn2atm funcione.
    tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name="So_u", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name="So_v", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    !--------------------------------------------------------------------------
    ! Realizar campos de export na grade OCN
    !--------------------------------------------------------------------------
    do n = 1, n_export
      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(export_names(n)), rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_Realize(exportState, field=tmp_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end do

    !--------------------------------------------------------------------------
    ! Atualizar estado interno com grades criadas nesta fase.
    ! NAO re-alocar iswrap%wrap: ja alocado em InitializeAdvertise.
    !--------------------------------------------------------------------------
    is%atm_grid   = atm_grid
    is%ocn_grid   = ocn_grid
    is%rh_created = .false.
    ! use_mpas_atm ja lido logo apos GetInternalState (ver acima).
    ! Nao sobrescrever com .false. aqui.


    ! Criar campos internos na grade ATM
    call CreateInternalField(is%f_taux_atm,   atm_grid, "med_taux",   rc)
    call CreateInternalField(is%f_tauy_atm,   atm_grid, "med_tauy",   rc)
    call CreateInternalField(is%f_sen_atm,    atm_grid, "med_sen",    rc)
    call CreateInternalField(is%f_evap_atm,   atm_grid, "med_evap",   rc)
    call CreateInternalField(is%f_lwnet_atm,  atm_grid, "med_lwnet",  rc)
    call CreateInternalField(is%f_swvdr_atm,  atm_grid, "med_swvdr",  rc)
    call CreateInternalField(is%f_swvdf_atm,  atm_grid, "med_swvdf",  rc)
    call CreateInternalField(is%f_swidr_atm,  atm_grid, "med_swidr",  rc)
    call CreateInternalField(is%f_swidf_atm,  atm_grid, "med_swidf",  rc)
    call CreateInternalField(is%f_rain_atm,   atm_grid, "med_rain",   rc)
    call CreateInternalField(is%f_snow_atm,   atm_grid, "med_snow",   rc)
    call CreateInternalField(is%f_pslv_atm,   atm_grid, "med_pslv",   rc)
    call CreateInternalField(is%f_ifrac_atm,  atm_grid, "med_ifrac",  rc)
    call CreateInternalField(is%f_duu10n_atm, atm_grid, "med_duu10n", rc)
    ! f_sst_atm: campo de SST interpolado para a grade ATM (destino do OCN->ATM)
    call CreateInternalField(is%f_sst_atm,    atm_grid, "med_sst",    rc)
    ! BUG-CALC-DUU (fix v13.0): correntes oceânicas interpoladas OCN → ATM.
    ! Usadas no cálculo de So_duu10n = |(V_atm − V_ocn)|² (protocolo CMEPS).
    call CreateInternalField(is%f_uocn_atm,   atm_grid, "med_uocn",   rc)
    call CreateInternalField(is%f_vocn_atm,   atm_grid, "med_vocn",   rc)
    ! Sprint C: rugosidade Charnock + Smith — calculada no MED e enviada ao MPAS.
    call CreateInternalField(is%f_zorl_atm,   atm_grid, "med_zorl",   rc)

    ! Zerar campos internos
    call ZeroInternalField(is%f_taux_atm,   rc)
    call ZeroInternalField(is%f_tauy_atm,   rc)
    call ZeroInternalField(is%f_sen_atm,    rc)
    call ZeroInternalField(is%f_evap_atm,   rc)
    call ZeroInternalField(is%f_lwnet_atm,  rc)
    call ZeroInternalField(is%f_swvdr_atm,  rc)
    call ZeroInternalField(is%f_swvdf_atm,  rc)
    call ZeroInternalField(is%f_swidr_atm,  rc)
    call ZeroInternalField(is%f_swidf_atm,  rc)
    call ZeroInternalField(is%f_rain_atm,   rc)
    call ZeroInternalField(is%f_snow_atm,   rc)
    call ZeroInternalField(is%f_pslv_atm,   rc)
    call ZeroInternalField(is%f_ifrac_atm,  rc)
    call ZeroInternalField(is%f_duu10n_atm, rc)
    ! Inicializa SST com valor padrao (nao zero, para evitar bulk erratico no t=0)
    call FillInternalField(is%f_sst_atm, SST_BULK_FALLBACK, rc)
    ! Valor de bootstrap: será substituído no primeiro passo pelo So_t do DOCN/MOM6.
    ! BUG-CALC-DUU: correntes oceânicas inicializadas a zero (oceano em repouso).
    ! Serão regridadas de So_u/So_v a partir do primeiro passo de acoplamento.
    call ZeroInternalField(is%f_uocn_atm, rc)
    call ZeroInternalField(is%f_vocn_atm, rc)
    ! Sprint C: rugosidade inicial = 0.01 m (mesmo cfg_zorl_default do cap MPAS).
    ! Substituida no primeiro passo pela parametrizacao Charnock no bulk NCAR.
    call FillInternalField(is%f_zorl_atm, 0.01_ESMF_KIND_R8, rc)

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! BUG-OUT-01 fix v4: ler config de diagnóstico de importação
    call med_read_import_config()

    ! FIX-IMP-01: salvar informação MPI do mediador para uso em med_write_import_fields
    block
      type(ESMF_VM) :: med_vm
      call ESMF_VMGetCurrent(med_vm, rc=rc)
      if (rc == ESMF_SUCCESS) then
        call ESMF_VMGet(med_vm, localPet=med_local_pet, petCount=med_pet_count, &
          mpiCommunicator=med_mpi_comm, rc=rc)
        if (rc /= ESMF_SUCCESS) med_mpi_comm = MPI_COMM_WORLD
      end if
    end block

    call ESMF_LogWrite('MED: InitializeRealize concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeRealize

  !============================================================================
  ! InitializeDataComplete - cria routehandles
  ! CORRECAO 2: usa NUOPC_MediatorGet em vez de ESMF_GridCompGet para obter
  !   importState/exportState, que e a API correta para mediadores NUOPC.
  ! CORRECAO 4: busca Sa_u10m_mpas (MPAS, grade ATM) para obter a grade ATM,
  !   em vez de Sa_u10m (DATM), que pode nao estar presente se o DATM nao
  !   tiver sido conectado ainda. Usa fallback para Sa_u10m caso necessario.
  !============================================================================
  subroutine InitializeDataComplete(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)         :: importState, exportState
    type(ESMF_Clock)         :: clock
    type(ESMF_Field)         :: atm_field, ocn_field, exp_field
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: fieldCount, i, localrc
    character(len=64), allocatable :: fieldNameList(:)
    real(ESMF_KIND_R8), pointer :: fptr(:,:)

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    is => iswrap%wrap


    ! CORRECAO 2: NUOPC_MediatorGet e a API correta para mediadores
    call NUOPC_MediatorGet(gcomp, mediatorClock=clock, &
      importState=importState, exportState=exportState, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Obtem campo de referencia para a grade ATM conforme o modo ativo.
    ! use_mpas_atm ja esta no estado interno (lido em InitializeRealize).
    if (is%use_mpas_atm) then
      call ESMF_StateGet(importState, itemName="Sa_u10m_mpas", &
        field=atm_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED IDC: Sa_u10m_mpas nao encontrado", &
        line=__LINE__, file=__FILE__)) return
    else
      call ESMF_StateGet(importState, itemName="Sa_u10m", &
        field=atm_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED IDC: Sa_u10m nao encontrado", &
        line=__LINE__, file=__FILE__)) return
    end if

    ! Obter campo de export para o OCN (Foxx_taux esta na grade OCN)
    call ESMF_StateGet(exportState, itemName="Foxx_taux", field=exp_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha Foxx_taux", &
      line=__LINE__, file=__FILE__)) return

    ! Criar routehandle ATM -> OCN
    call ESMF_FieldRegridStore( &
      srcField       = is%f_taux_atm,   &
      dstField       = exp_field,       &
      routehandle    = is%rh_atm2ocn,   &
      regridmethod   = ESMF_REGRIDMETHOD_NEAREST_STOD, &
      unmappedaction = ESMF_UNMAPPEDACTION_IGNORE, &
      rc             = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="MED: falha FieldRegridStore ATM->OCN", &
      line=__LINE__, file=__FILE__)) return

    ! Criar routehandle OCN -> ATM
    ! So_t esta agora corretamente na grade OCN (ver InitializeRealize)
    call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha So_t", &
      line=__LINE__, file=__FILE__)) return

    call ESMF_FieldRegridStore( &
      srcField       = ocn_field,       &
      dstField       = is%f_sst_atm,    &
      routehandle    = is%rh_ocn2atm,   &
      regridmethod   = ESMF_REGRIDMETHOD_BILINEAR, &
      unmappedaction = ESMF_UNMAPPEDACTION_IGNORE, &
      rc             = rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="MED: falha FieldRegridStore OCN->ATM", &
      line=__LINE__, file=__FILE__)) return

    ! BUG-CALC-DUU (fix v13.0): primeiro regrid de So_u e So_v para f_uocn_atm/f_vocn_atm.
    ! So_u e So_v agora anunciados e realizados no importState do MED (ocn_grid),
    ! portanto ESMF_StateGet é seguro — sem risco de "Not found" no log.
    ! O routehandle rh_ocn2atm (bilinear, já criado) é reutilizado: So_u/So_v
    ! compartilham a mesma grade OCN que So_t → mapeamento idêntico.
    block
      type(ESMF_Field) :: f_uocn_src, f_vocn_src
      integer :: rc_uv
      call ESMF_StateGet(importState, itemName="So_u", field=f_uocn_src, rc=rc_uv)
      if (rc_uv == ESMF_SUCCESS) then
        call ESMF_FieldRegrid(f_uocn_src, is%f_uocn_atm, is%rh_ocn2atm, &
          zeroregion=ESMF_REGION_TOTAL, rc=rc_uv)
        if (rc_uv /= ESMF_SUCCESS) call ZeroInternalField(is%f_uocn_atm, rc_uv)
      end if
      call ESMF_StateGet(importState, itemName="So_v", field=f_vocn_src, rc=rc_uv)
      if (rc_uv == ESMF_SUCCESS) then
        call ESMF_FieldRegrid(f_vocn_src, is%f_vocn_atm, is%rh_ocn2atm, &
          zeroregion=ESMF_REGION_TOTAL, rc=rc_uv)
        if (rc_uv /= ESMF_SUCCESS) call ZeroInternalField(is%f_vocn_atm, rc_uv)
      end if
    end block

    is%rh_created = .true.

    ! Inicializar exportState com valores fisicamente razoaveis
    ! B-45: ESMF_FieldGet(farrayPtr) falha em PETs sem DE local.
    ! Verificar localDeCount antes de acessar dados do campo.
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (fieldCount > 0) then
      allocate(fieldNameList(fieldCount))
      call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
      do i = 1, fieldCount
        call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
          field=exp_field, rc=rc)
        block
          integer :: localDeCount_exp
          call ESMF_FieldGet(exp_field, localDeCount=localDeCount_exp, rc=localrc)
          if (localDeCount_exp == 0) cycle   ! PET sem DE local — nada a inicializar
        end block
        call ESMF_FieldGet(exp_field, farrayPtr=fptr, rc=rc)
        select case(trim(fieldNameList(i)))
          case('Sa_pslv')
            fptr = 101325.0_ESMF_KIND_R8
          case default
            fptr = 0.0_ESMF_KIND_R8
        end select
      end do
      deallocate(fieldNameList)
    end if

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", value="true", rc=rc)
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", value="true", rc=rc)

    call ESMF_LogWrite('MED: InitializeDataComplete SATISFIED', ESMF_LOGMSG_INFO)
  end subroutine InitializeDataComplete

  !============================================================================
  ! MediatorAdvance - com fallback MPAS -> DATM
  !============================================================================
  subroutine MediatorAdvance(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    type(ESMF_State)         :: importState, exportState
    type(ESMF_Clock)         :: clock
    type(ESMF_Time)          :: currTime, nextTime
    type(ESMF_TimeInterval)  :: dt
    type(ESMF_Field)         :: field
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: localDeCount_med   ! B-45: guard para PETs sem DE local

    ! Campos do MPAS (primario)
    real(ESMF_KIND_R8), pointer :: uas_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: vas_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: tas_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: shum_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: psl_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: swdn_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: lwdn_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: rain_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: snow_mpas(:,:) => null()
    logical :: mpas_available

    ! Campos do DATM (fallback)
    real(ESMF_KIND_R8), pointer :: uas_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: vas_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: tas_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: shum_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: psl_datm(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: swdn_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: lwdn_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: rain_datm(:,:) => null()
    real(ESMF_KIND_R8), pointer :: snow_datm(:,:) => null()

    ! Campos finais (alias para MPAS ou DATM)
    real(ESMF_KIND_R8), pointer :: uas(:,:), vas(:,:), tas(:,:), shum(:,:)
    real(ESMF_KIND_R8), pointer :: psl(:,:), swdn(:,:), lwdn(:,:)
    real(ESMF_KIND_R8), pointer :: rain(:,:), snow(:,:)
    real(ESMF_KIND_R8), pointer :: sst(:,:), fptr(:,:)
    ! BUG-CALC-DUU (fix v13.0): ponteiros para correntes oceânicas na grade ATM
    real(ESMF_KIND_R8), pointer :: uocn(:,:), vocn(:,:)

    real(ESMF_KIND_R8), pointer     :: shum_local(:,:) => null()
    real(ESMF_KIND_R8), pointer     :: snow_local(:,:) => null()
    integer :: i1_glob, i2_glob, j1_glob, j2_glob
    real(ESMF_KIND_R8) :: wspd, qsat, sst_eff
    integer :: i, j, i1, i2, j1, j2
    integer :: fieldCount, k
    character(len=64), allocatable :: fieldNameList(:)
    character(len=256) :: msg

    ! BUG-CALC-DUU: nullify após todas as declarações (instrução executável
    ! não pode preceder declarações — Fortran 2003 §12.4).
    nullify(uocn, vocn)

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    is => iswrap%wrap

    ! BUG-NC-02 fix (GT Acoplamento MONAN/INPE — Maio 2026):
    ! NUOPC_MediatorGet e ESMF_ClockGet devem ser chamados ANTES da guarda
    ! localDeCount==0. A subrotina med_write_import_fields contém MPI_Allreduce
    ! e MPI_Reduce — operações MPI coletivas que exigem participação de TODOS os
    ! PETs. Na versão anterior, PETs sem DE local retornavam em (*)  sem chamar
    ! med_write_import_fields, enquanto PETs ativos bloqueavam no MPI_Allreduce
    ! aguardando os PETs ausentes → deadlock determinístico com petCount > 160.
    ! Solução: obter o estado antes do teste; PETs inativos chamam a função com
    ! contribuição vazia (grid_local = FILL_IMP) antes de retornar.
    call NUOPC_MediatorGet(gcomp, mediatorClock=clock, &
      importState=importState, exportState=exportState, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_ClockGet(clock, currTime=currTime, timeStep=dt, rc=rc)
    nextTime = currTime + dt

    ! B-45: com regDecomp(2)=min(petCount,ny_atm/2), PETs acima de ny_atm/2
    ! têm localDeCount=0 para o atm_grid interno do MED. Esses PETs não têm
    ! dados locais — nenhum campo interno pode ser acessado via farrayPtr.
    call ESMF_FieldGet(is%f_taux_atm, localDeCount=localDeCount_med, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    if (localDeCount_med == 0) then  ! (*) — ponto de retorno corrigido
      ! PET sem DE local: participar nas operações MPI coletivas dentro de
      ! med_write_import_fields antes de retornar (evita deadlock BUG-NC-02).
      ! Contribuição local = FILL_IMP (neutro no MPI_Reduce MAX).
      call med_write_import_fields(exportState, nextTime, is, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS
      return
    end if

    !==========================================================================
    ! BUG-CALC-01: zerar f_*_atm antes do bulk para evitar persistência de
    ! valores não inicializados em células fora do alcance de uas/vas
    ! (grade MPAS Voronoi parcialmente sobreposta à grade MED regular).
    ! O loop bulk só preenche (i1:i2, j1:j2) = lbound:ubound(uas); sem
    ! zerar antes, regiões sem dados MPAS aparecem como lixo nos plots.
    !==========================================================================
    call ZeroInternalField(is%f_taux_atm,   rc)
    call ZeroInternalField(is%f_tauy_atm,   rc)
    call ZeroInternalField(is%f_sen_atm,    rc)
    call ZeroInternalField(is%f_evap_atm,   rc)
    call ZeroInternalField(is%f_lwnet_atm,  rc)
    call ZeroInternalField(is%f_swvdr_atm,  rc)
    call ZeroInternalField(is%f_swvdf_atm,  rc)
    call ZeroInternalField(is%f_swidr_atm,  rc)
    call ZeroInternalField(is%f_swidf_atm,  rc)
    call ZeroInternalField(is%f_rain_atm,   rc)
    call ZeroInternalField(is%f_snow_atm,   rc)
    call ZeroInternalField(is%f_pslv_atm,   rc)
    ! BUG-MED-ZERO (v2.5): NÃO zerar is%f_ifrac_atm incondicionalmente.
    ! Em Sprint B.1.1 (use_docn_ice=T, init_only=T, med_ifrac_init_done=T),
    ! fill_ifrac_from_oisst é pulado após o primeiro passo, então zerando aqui
    ! MPAS receberia Si_ifrac=0 em todos os passos seguintes ao t=1.
    ! O campo é zerado apenas nos modos em que será repreenchido neste ciclo.
    ! No Sprint B.1.1, o decaimento é aplicado no bloco 3b abaixo.
    if (.not. (cfg_use_docn_ice .and. &
               cfg_docn_ice_init_only .and. med_ifrac_init_done)) then
      call ZeroInternalField(is%f_ifrac_atm, rc)
    end if
    call ZeroInternalField(is%f_duu10n_atm, rc)
    ! BUG-CALC-DUU (fix v13.0): zerar correntes para evitar persistência
    call ZeroInternalField(is%f_uocn_atm,   rc)
    call ZeroInternalField(is%f_vocn_atm,   rc)
    rc = ESMF_SUCCESS  ! ZeroInternalField pode retornar !=SUCCESS para PETs sem DE

    !==========================================================================
    ! 1. TENTAR OBTER CAMPOS DO MPAS (PRIMARIO)
    !==========================================================================
    ! use_mpas_atm vem do atributo NUOPC definido em esm.F90.
    ! Se false, pula a tentativa e vai direto ao DATM.
    mpas_available = is%use_mpas_atm

    !--------------------------------------------------------------------------
    ! 1a. CAMPOS OBRIGATORIOS DO MPAS (7 campos do EXP_NAMES v7)
    !--------------------------------------------------------------------------
    i1_glob = 1; i2_glob = 1; j1_glob = 1; j2_glob = 1  ! defaults
    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Sa_u10m_mpas", uas_mpas, rc)
      if (rc /= ESMF_SUCCESS) then
        mpas_available = .false.
      else
        i1_glob = lbound(uas_mpas,1); i2_glob = ubound(uas_mpas,1)
        j1_glob = lbound(uas_mpas,2); j2_glob = ubound(uas_mpas,2)
      end if
    end if

    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Sa_v10m_mpas",   vas_mpas,  rc)
      call GetFieldPtrOptional(importState, "Sa_tbot_mpas",   tas_mpas,  rc)
      call GetFieldPtrOptional(importState, "Sa_pslv_mpas",   psl_mpas,  rc)
      call GetFieldPtrOptional(importState, "Faxa_swdn_mpas", swdn_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_lwdn_mpas", lwdn_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_rain_mpas", rain_mpas, rc)

      ! Verificar apenas os 7 campos obrigatorios
      if (.not. (associated(uas_mpas)  .and. associated(vas_mpas)  .and. &
                 associated(tas_mpas)  .and. associated(psl_mpas)  .and. &
                 associated(swdn_mpas) .and. associated(lwdn_mpas) .and. &
                 associated(rain_mpas))) then
        mpas_available = .false.
      end if
    end if

    !--------------------------------------------------------------------------
    ! 1b. CAMPOS FASE 2 OPCIONAIS (Sa_shum_mpas, Faxa_snow_mpas)
    !     Ausentes em mpas_cap v7 — usar defaults fisicos quando null.
    !--------------------------------------------------------------------------
    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Sa_shum_mpas",   shum_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_snow_mpas", snow_mpas, rc)
      ! rc pode ser ESMF_FAILURE se campos Fase 2 ausentes — nao e erro
    end if

    !==========================================================================
    ! 2. SE MPAS NAO DISPONIVEL E use_mpas_atm=false: USAR DATM (FALLBACK)
    !    SE use_mpas_atm=true mas campos obrigatorios ausentes: verificar se
    !    é PET sem DE local na grade MPAS (normal com 512 PETs) ou erro real.
    !==========================================================================
    if (.not. mpas_available) then
      if (is%use_mpas_atm) then
        ! B-45: com regDecomp(2)=min(petCount,NLAT/2), PETs acima de NLAT/2
        ! (ex: PETs 90-159 com 512 PETs e NLAT=180) têm localDeCount=0 na
        ! grade MPAS (360×180) mas localDeCount>0 na grade MED (640×320).
        ! GetFieldPtrOptional retorna mpas_available=false para esses PETs
        ! porque os campos MPAS não têm dados locais — comportamento normal.
        ! Retorno silencioso (rc=SUCCESS): o cálculo bulk é local, os PETs
        ! sem dados MPAS simplesmente não contribuem para os campos internos.
        call ESMF_LogWrite('MED: PET sem dados MPAS locais — skip bulk (B-45)', &
          ESMF_LOGMSG_INFO)
        rc = ESMF_SUCCESS; return
      end if
      ! DATM fallback (apenas quando use_mpas_atm=false)
      call GetFieldPtr(importState, "Sa_u10m",   uas_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_v10m",   vas_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_tbot",   tas_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_shum",   shum_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Sa_pslv",   psl_datm,  rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_swdn", swdn_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_lwdn", lwdn_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_rain", rain_datm, rc); if (rc/=ESMF_SUCCESS) return
      call GetFieldPtr(importState, "Faxa_snow", snow_datm, rc); if (rc/=ESMF_SUCCESS) return

      uas  => uas_datm;  vas  => vas_datm;  tas  => tas_datm
      shum => shum_datm; psl  => psl_datm;  swdn => swdn_datm
      lwdn => lwdn_datm; rain => rain_datm; snow => snow_datm

      call ESMF_LogWrite('MED: Usando DATM (JRA55) como fonte atmosferica (fallback)', &
        ESMF_LOGMSG_INFO)
    else
      uas  => uas_mpas;  vas  => vas_mpas;  tas  => tas_mpas
      psl  => psl_mpas;  swdn => swdn_mpas; lwdn => lwdn_mpas
      rain => rain_mpas

      ! shum: Fase 2 opcional — usar SHUM_OCEAN_DEFAULT quando ausente
      if (associated(shum_mpas)) then
        shum => shum_mpas
      else
        allocate(shum_local(i1_glob:i2_glob, j1_glob:j2_glob))
        shum_local = SHUM_OCEAN_DEFAULT
        shum => shum_local
        call ESMF_LogWrite('MED: Sa_shum_mpas ausente (Fase 2) ' &
          //'-- usando SHUM_DEFAULT=0.010 kg/kg', ESMF_LOGMSG_INFO)
      end if

      ! snow: Fase 2 opcional — zero quando ausente
      if (associated(snow_mpas)) then
        snow => snow_mpas
      else
        allocate(snow_local(i1_glob:i2_glob, j1_glob:j2_glob))
        snow_local = 0.0_ESMF_KIND_R8
        snow => snow_local
        call ESMF_LogWrite('MED: Faxa_snow_mpas ausente (Fase 2) ' &
          //'-- precipitacao solida = 0.0', ESMF_LOGMSG_INFO)
      end if

      call ESMF_LogWrite('MED: Usando MPAS como fonte atmosferica primaria', &
        ESMF_LOGMSG_INFO)
    end if

    i1 = lbound(uas,1); i2 = ubound(uas,1)
    j1 = lbound(uas,2); j2 = ubound(uas,2)

    !==========================================================================
    ! BUG-CALC-08 (CRÍTICO): SPREAD MPAS-A → todos PETs do mediador.
    !
    ! Causa raiz definitiva (confirmada pela análise de 8 rodadas):
    !   O MPAS-A roda apenas num subconjunto dos PETs do MED. Em PETs onde
    !   MPAS não roda, os campos uas, vas, tas, psl, swdn, lwdn, rain, shum,
    !   snow têm fptr=0.0 (do mpas_cap_methods:state_set_field_1d que zera o
    !   domínio local antes de preencher apenas células Voronoi locais).
    !   Logo, do globo (360x180=64800 células), apenas a fração coberta por
    !   PETs com tile MPAS+MED recebe dado real; o resto fica zero.
    !
    ! Solução: para cada campo MPAS, criar um array GLOBAL (1:nx_atm,1:ny_atm)
    ! e gather via MPI_Allreduce(MAX) — assumindo fill=0 nas células sem dado,
    ! o MAX vence sobre zero e retorna o dado real onde quer que esteja.
    ! Trocar bounds do loop bulk para 1..nx_atm, 1..ny_atm.
    !==========================================================================
    block
      real(ESMF_KIND_R8), allocatable, target :: uas_g(:,:), vas_g(:,:), tas_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: psl_g(:,:), swdn_g(:,:), lwdn_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: rain_g(:,:), shum_g(:,:)
      real(ESMF_KIND_R8), allocatable          :: snow_g(:,:)  ! sem target: acesso direto
      real(ESMF_KIND_R8), allocatable          :: tmp_local(:,:)
      integer :: gi, gj, mpi_ierr_g
      integer, parameter :: NX_G = 360, NY_G = 180

      allocate(uas_g(NX_G,NY_G),  vas_g(NX_G,NY_G),  tas_g(NX_G,NY_G))
      allocate(psl_g(NX_G,NY_G),  swdn_g(NX_G,NY_G), lwdn_g(NX_G,NY_G))
      allocate(rain_g(NX_G,NY_G), shum_g(NX_G,NY_G), snow_g(NX_G,NY_G))
      allocate(tmp_local(NX_G,NY_G))

      ! Gather global por MPI_Allreduce(MAX) — campos com 'fill=0' fora do tile
      ! local. MAX combina contribuições de todos os PETs corretamente.
      !
      ! uas: campo que pode ser negativo. Para MAX não corromper sinal negativo,
      ! cada PET escreve seu tile e usa OUTROS valores como -infinito virtual.
      ! Como mpas_cap zera o domínio local fora das células Voronoi locais,
      ! usamos um truque: replicar via SUM e cada PET zera fora do seu tile.
      ! MPI_Allreduce(SUM) com tiles disjuntos == gather global.

      ! Helper macro: monta tmp_local com o tile, faz Allreduce(SUM) → array_g
      ! UAS
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) then
          tmp_local(gi,gj) = uas(gi,gj)
        end if
      end do; end do
      call MPI_Allreduce(tmp_local, uas_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! VAS
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = vas(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, vas_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! TAS
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = tas(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, tas_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! PSL
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = psl(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, psl_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! SWDN
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = swdn(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, swdn_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! LWDN
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = lwdn(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, lwdn_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! RAIN
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = rain(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, rain_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! SHUM (com fallback)
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = shum(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, shum_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)
      ! Onde shum_g=0 (não preenchido) e shum tem fallback, usar SHUM_OCEAN_DEFAULT
      where (shum_g <= 0.0_ESMF_KIND_R8) shum_g = SHUM_OCEAN_DEFAULT

      ! SNOW (fase 2 opcional — zero default)
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= NX_G .and. gj >= 1 .and. gj <= NY_G) tmp_local(gi,gj) = snow(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, snow_g, NX_G*NY_G, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! DIAGNÓSTICO BUG-CALC-08 + BUG-MPAS-01: vai para stdout (= esmApp_run.log).
      ! Espera-se que após BUG-MPAS-01, n_nz_uas > 30000/64800 (cobertura global).
      block
        integer :: my_pet, n_nz_uas, n_nz_psl, n_nz_swdn, n_nz_tas
        type(ESMF_VM) :: diag_vm
        logical, save :: first_call_diag = .true.
        call ESMF_VMGetCurrent(diag_vm, rc=rc)
        call ESMF_VMGet(diag_vm, localPet=my_pet, rc=rc)
        if (my_pet == 0 .and. first_call_diag) then
          first_call_diag = .false.
          n_nz_uas  = count(abs(uas_g)  > 1.0e-10_ESMF_KIND_R8)
          n_nz_tas  = count(tas_g       > 100.0_ESMF_KIND_R8)
          n_nz_psl  = count(psl_g       > 1.0_ESMF_KIND_R8)
          n_nz_swdn = count(swdn_g      > 1.0e-10_ESMF_KIND_R8)
          write(*,'(A)') '######## [MED BUG-CALC-08 + BUG-MPAS-01 DIAG] ########'
          write(*,'(A,I0,A,I0,A,F9.4,A,F9.4)') &
            '   uas_g: nonzero=', n_nz_uas, '/', NX_G*NY_G, &
            '  min=', minval(uas_g), '  max=', maxval(uas_g)
          write(*,'(A,I0,A,F9.3,A,F9.3)') &
            '   tas_g: nonzero>100K=', n_nz_tas, &
            '  min=', minval(tas_g), '  max=', maxval(tas_g)
          write(*,'(A,I0,A,F11.3,A,F11.3)') &
            '   psl_g: nonzero>1Pa=', n_nz_psl, &
            '  min=', minval(psl_g), '  max=', maxval(psl_g)
          write(*,'(A,I0,A,F10.3,A,F10.3)') &
            '  swdn_g: nonzero=', n_nz_swdn, &
            '  min=', minval(swdn_g), '  max=', maxval(swdn_g)
          write(*,'(A,F9.4,A,F9.4)') &
            '   vas_g min=', minval(vas_g), '  max=', maxval(vas_g)
          write(*,'(A,F11.6,A,F11.6)') &
            '  shum_g min=', minval(shum_g), '  max=', maxval(shum_g)
          write(*,'(A,F12.6,A,F12.6)') &
            '  rain_g min=', minval(rain_g), '  max=', maxval(rain_g)
          write(*,'(A,F10.3,A,F10.3)') &
            '  lwdn_g min=', minval(lwdn_g), '  max=', maxval(lwdn_g)
          write(*,'(A,I0,A,I0)') &
            '   NX_G=', NX_G, '  NY_G=', NY_G
          write(*,'(A)') '########################################'
          flush(6)
        end if
      end block

      deallocate(tmp_local)

      ! BUG-CALC-08 fix-2: arrays globais (uas_g..snow_g) cobrem 1..NX_G,1..NY_G
      ! Mas fptr (de is%f_*_atm) tem bounds LOCAIS à DE do PET → loop deve usar
      ! os bounds locais (i1_loc..i2_loc da DE). Como uas_g é global, acessá-lo
      ! com índices (i,j) locais à DE acessa as mesmas coordenadas geográficas
      ! que fptr(i,j) — preservando o resultado correto sem buffer overrun.
      uas  => uas_g
      vas  => vas_g
      tas  => tas_g
      psl  => psl_g
      swdn => swdn_g
      lwdn => lwdn_g
      rain => rain_g
      shum => shum_g
      ! snow_g sem target — usar snow_g diretamente nos loops bulk
      ! (snow pointer não pode apontar para allocatable sem target)

      ! Obter bounds locais da DE do f_taux_atm (mesma decomposição p/ todos)
      block
        real(ESMF_KIND_R8), pointer :: fpt_probe(:,:)
        nullify(fpt_probe)
        call ESMF_FieldGet(is%f_taux_atm, farrayPtr=fpt_probe, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(fpt_probe)) then
          i1 = lbound(fpt_probe,1); i2 = ubound(fpt_probe,1)
          j1 = lbound(fpt_probe,2); j2 = ubound(fpt_probe,2)
          ! Clampar aos limites globais (1..NX_G, 1..NY_G) para evitar acesso
          ! a uas_g fora dos bounds alocados.
          i1 = max(1, i1); i2 = min(NX_G, i2)
          j1 = max(1, j1); j2 = min(NY_G, j2)
        else
          ! PET sem DE local — bounds vazios → loops não executam
          i1 = 1; i2 = 0
          j1 = 1; j2 = 0
        end if
      end block

      ! NOTA: uas_g..snow_g são allocatable LOCAIS dentro deste block.
      ! Para mantê-los vivos até o fim do MediatorAdvance, usamos pointer
      ! association: uas => uas_g é seguro porque uas é declarado pointer no
      ! escopo externo. O `block` precisa permanecer aberto até o fim do bulk.
      ! ATENÇÃO: este block deve englobar TODA a seção 4 (CALCULAR BULK NCAR)
      ! e seção 5 (REGRID E EXPORTA). Veja end block ao final.


    !==========================================================================
    ! 3. SST: regrid OCN -> ATM (So_t esta agora na grade OCN)
    !
    ! Sprint A.5 (Maio 2026): aplica mascara terra/oceano apos o regrid.
    !
    ! CAUSA-RAIZ DETECTADA NO POSTPROC:
    ! O mom_cap_methods::state_setexport multiplica SST por ocean_grid%mask2dT
    ! antes do export (linha 1126 do mom_cap_methods.F90). Sobre terra,
    ! mask2dT=0 -> SST=0 K na grade OCN. Apos regrid bilinear OCN->ATM, celulas
    ! oceanicas proximas a costa ficam contaminadas pela mistura com zero,
    ! caindo abaixo de 270 K. Resultado: ~37% das celulas oceanicas mascaradas
    ! como "fill" pelo postproc (limiar fill_min_threshold=270 K).
    !
    ! FIX: apos o regrid, substituir valores fisicamente impossiveis (T < T_min
    ! ou T > T_max) por SST_FILL_LAND = 271.35 K (ponto de congelamento da agua
    ! do mar). Isto:
    !   (a) elimina a contaminacao do regrid com zeros do MOM6 mascarados,
    !   (b) mantem celulas terra com valor fisicamente plausivel (gelo polar),
    !   (c) preserva valores reais de SST sobre oceano (T entre 271-310 K).
    !==========================================================================
    if (is%rh_created) then
      call ESMF_StateGet(importState, itemName="So_t", field=field, rc=rc)

      ! ── Opção 1 (v4.18): regrid SST ciente de máscara + extrap. vizinhança ─
      if (.not. is%rh_sst_masked) then
        block
          real(ESMF_KIND_R8), pointer    :: sst_src(:,:)
          integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
          integer :: lde_s, n_land, ldec_ocn, n_sea
          integer :: n_land_g(1), n_land_s(1), n_sea_g(1), n_sea_s(1)
          type(ESMF_VM) :: vm
          real(ESMF_KIND_R8), parameter  :: LAND_FILL_MAX = 270.0_ESMF_KIND_R8
          call ESMF_VMGetCurrent(vm, rc=rc)
          n_land = 0; n_sea = 0
          call ESMF_GridGet(is%ocn_grid, localDeCount=ldec_ocn, rc=rc)
          if (rc == ESMF_SUCCESS) then
            do lde_s = 0, ldec_ocn - 1
              call ESMF_FieldGet(field, localDe=lde_s, farrayPtr=sst_src, rc=rc)
              if (rc /= ESMF_SUCCESS .or. .not. associated(sst_src)) cycle
              call ESMF_GridGetItem(is%ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
                staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_s, &
                farrayPtr=maskptr, rc=rc)
              if (rc == ESMF_SUCCESS .and. associated(maskptr)) then
                where (sst_src < LAND_FILL_MAX)
                  maskptr = 1
                elsewhere
                  maskptr = 0
                end where
                n_land = n_land + count(maskptr == 1)
                n_sea  = n_sea  + count(maskptr == 0)
              end if
            end do
          end if
          n_land_s(1) = n_land; n_sea_s(1) = n_sea
          call ESMF_VMAllReduce(vm, n_land_s, n_land_g, 1, ESMF_REDUCE_SUM, rc=rc)
          if (rc /= ESMF_SUCCESS) n_land_g(1) = n_land
          call ESMF_VMAllReduce(vm, n_sea_s,  n_sea_g,  1, ESMF_REDUCE_SUM, rc=rc)
          if (rc /= ESMF_SUCCESS) n_sea_g(1) = n_sea
          if (n_land_g(1) == 0 .or. n_sea_g(1) == 0) then
            call ESMF_LogWrite('MED Opção1: SST uniforme/bootstrap — adiado', &
              ESMF_LOGMSG_INFO)
            is%rh_ocn2atm_sst = is%rh_ocn2atm
          else
            call ESMF_FieldRegridStore( &
              srcField        = field,              &
              dstField        = is%f_sst_atm,       &
              routehandle     = is%rh_ocn2atm_sst,  &
              regridmethod    = ESMF_REGRIDMETHOD_BILINEAR, &
              srcMaskValues   = (/ 1_ESMF_KIND_I4 /), &
              unmappedaction  = ESMF_UNMAPPEDACTION_IGNORE, &
              rc              = rc)
            if (ESMF_LogFoundError(rcToCheck=rc, &
              msg="MED Opção1: falha FieldRegridStore SST mascarado", &
              line=__LINE__, file=__FILE__)) then
              is%rh_ocn2atm_sst = is%rh_ocn2atm
            else
              call ESMF_LogWrite('MED Opção1: rh_ocn2atm_sst criado', &
                ESMF_LOGMSG_INFO)
            end if
            is%rh_sst_masked = .true.
          end if
        end block
      end if

      call ESMF_FieldRegrid(field, is%f_sst_atm, is%rh_ocn2atm_sst, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
      call ESMF_FieldGet(is%f_sst_atm, farrayPtr=sst, rc=rc)

      ! Extrapolação por vizinhança (preenche costa/costura); resíduo → T_FILL.
      if (associated(sst)) then
        block
          real(ESMF_KIND_R8), parameter :: T_MIN  = 270.0_ESMF_KIND_R8
          real(ESMF_KIND_R8), parameter :: T_MAX  = 310.0_ESMF_KIND_R8
          real(ESMF_KIND_R8), parameter :: T_FILL = 271.35_ESMF_KIND_R8
          integer,            parameter :: N_ITER = 8
          real(ESMF_KIND_R8), allocatable :: tmp(:,:)
          logical,            allocatable :: valid(:,:)
          integer :: i2,j2,ii2,jj2,it,i1,iN,j1,jN,nbr,n0,n_left
          real(ESMF_KIND_R8) :: acc
          i1=lbound(sst,1); iN=ubound(sst,1); j1=lbound(sst,2); jN=ubound(sst,2)
          where (sst > T_MAX) sst = T_FILL
          where (sst /= sst)  sst = T_MIN - 1.0_ESMF_KIND_R8
          allocate(valid(i1:iN,j1:jN), tmp(i1:iN,j1:jN))
          valid = (sst >= T_MIN .and. sst <= T_MAX)
          n0 = count(.not. valid)
          do it = 1, N_ITER
            if (count(.not. valid) == 0) exit
            tmp = sst
            do j2 = j1, jN
              do i2 = i1, iN
                if (valid(i2,j2)) cycle
                acc = 0.0_ESMF_KIND_R8; nbr = 0
                do jj2 = max(j1,j2-1), min(jN,j2+1)
                  do ii2 = max(i1,i2-1), min(iN,i2+1)
                    if (valid(ii2,jj2)) then
                      acc = acc + sst(ii2,jj2); nbr = nbr + 1
                    end if
                  end do
                end do
                if (nbr > 0) tmp(i2,j2) = acc / real(nbr, ESMF_KIND_R8)
              end do
            end do
            sst = tmp
            valid = (sst >= T_MIN .and. sst <= T_MAX)
          end do
          n_left = count(.not. valid)
          where (.not. valid) sst = T_FILL
          deallocate(valid, tmp)
          if (n0 > 0) then
            block
              character(len=200) :: logmsg
              write(logmsg,'(A,I0,A,I0,A)') &
                'MED Opção1: SST extrapolada — ', n0, ' células (', &
                n_left, ' resíduo→T_FILL)'
              call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)
            end block
          end if
        end block
      end if

      ! BUG-CALC-DUU (fix v13.0): regrid de correntes oceânicas OCN → ATM.
      ! So_u e So_v agora anunciados e realizados no importState do MED (ocn_grid).
      ! ESMF_StateGet é seguro — sem risco de "Not found" no log.
      ! Fallback seguro: se regrid falhar, mantém zeros em f_uocn_atm/f_vocn_atm.
      block
        type(ESMF_Field) :: f_uocn_src, f_vocn_src
        integer :: rc_uv
        call ESMF_StateGet(importState, itemName="So_u", field=f_uocn_src, rc=rc_uv)
        if (rc_uv == ESMF_SUCCESS) &
          call ESMF_FieldRegrid(f_uocn_src, is%f_uocn_atm, is%rh_ocn2atm, &
            zeroregion=ESMF_REGION_TOTAL, rc=rc_uv)
        call ESMF_StateGet(importState, itemName="So_v", field=f_vocn_src, rc=rc_uv)
        if (rc_uv == ESMF_SUCCESS) &
          call ESMF_FieldRegrid(f_vocn_src, is%f_vocn_atm, is%rh_ocn2atm, &
            zeroregion=ESMF_REGION_TOTAL, rc=rc_uv)
      end block
    else
      ! Routehandles nao criados: usa SST padrao (ja preenchido em InitializeRealize)
      call ESMF_FieldGet(is%f_sst_atm, farrayPtr=sst, rc=rc)
    end if

    !==========================================================================
    ! 3b. Si_ifrac — Sprint B.1.1: fill_ifrac_from_oisst apenas no 1º passo
    !
    ! Modos (nuopc.input &nuopc_mode):
    !   use_docn_ice=T  init_only=F  → Alternativa 1 original:
    !     fill_ifrac_from_oisst a cada passo (campo congelado em OISST).
    !   use_docn_ice=T  init_only=T  → Sprint B.1.1:
    !     fill_ifrac_from_oisst apenas na 1ª MediatorAdvance (flag
    !     med_ifrac_init_done). is%f_ifrac_atm fica congelado no valor
    !     OISST de t=0 nas demais chamadas.
    !     NÃO tentar rh_ocn2atm para Si_ifrac: zera is%f_ifrac_atm antes
    !     de falhar (rh é específico para So_t). Sprint B.2 criará rh dedicado.
    !   use_docn_ice=F              → regrid OCN sigmoid via importState.
    !==========================================================================
    ! SI_IFRAC_DECAY_MED declarado no escopo do módulo (acessível aqui via host association)
    if (cfg_use_docn_ice .and. &
        (.not. cfg_docn_ice_init_only .or. .not. med_ifrac_init_done)) then
      call fill_ifrac_from_oisst(is, clock, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS  ! não fatal
      med_ifrac_init_done = .true.               ! inicializado em t=0

    else if (cfg_use_docn_ice .and. cfg_docn_ice_init_only .and. &
             med_ifrac_init_done) then
      ! Sprint B.1.1: decaimento exponencial do campo OISST retido em
      ! is%f_ifrac_atm.  O campo NÃO foi zerado (fix BUG-MED-ZERO acima).
      ! Multiplica cada célula por SI_IFRAC_DECAY_MED (≈ 0.9592/hora).
      ! Resulta em τ ≈ 24h: gelo antártico/ártico decai fisicamente em vez
      ! de desaparecer instantaneamente no passo seguinte ao t=0.
      block
        real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:) => null()
        integer :: ldec
        call ESMF_FieldGet(is%f_ifrac_atm, localDeCount=ldec, rc=rc)
        if (rc == ESMF_SUCCESS .and. ldec > 0) then
          call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=ifrac_ptr, rc=rc)
          if (rc == ESMF_SUCCESS .and. associated(ifrac_ptr)) then
            ifrac_ptr = ifrac_ptr * SI_IFRAC_DECAY_MED
            where (ifrac_ptr < 0.0_ESMF_KIND_R8) ifrac_ptr = 0.0_ESMF_KIND_R8
          end if
        end if
        rc = ESMF_SUCCESS
        call ESMF_LogWrite( &
          'MED(B.1.1): Si_ifrac decaimento aplicado (SI_IFRAC_DECAY_MED=0.9592)', &
          ESMF_LOGMSG_INFO)
      end block
    end if
    ! init_only=F: field preenchido a cada passo via fill_ifrac_from_oisst
    ! use_docn_ice=F: is%f_ifrac_atm foi zerado acima; permanece zero

    !==========================================================================
    ! 4. CALCULAR BULK NCAR — delegado ao módulo med_bulk_ncar_mod
    !==========================================================================
    call calc_bulk_ncar(is, importState, &
                        uas_g, vas_g, tas_g, psl_g, swdn_g, lwdn_g, rain_g, shum_g, snow_g, &
                        i1, i2, j1, j2, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: calc_bulk_ncar falhou', &
      line=__LINE__, file=__FILE__)) return


    !==========================================================================
    ! 5. REGRID E EXPORTA PARA O OCEANO
    ! CORRECAO 3: RegridOrCopy agora tem ramo else explicito: se routehandles
    !   nao estiverem criados, copia direto da grade ATM interna para a grade
    !   OCN do exportState via ESMF_FieldSMM (ou copia simples). Isso evita
    !   que os campos exportados permane�am zerados silenciosamente.
    !
    ! Sprint A.5.1 (Maio 2026): aplicacao de mascara terra/oceano nos fluxos
    ! antes do export, eliminando valores absurdos sobre continentes.
    !
    ! CONTEXTO:
    ! O bulk NCAR roda em TODAS as celulas da grade ATM (oceano + terra).
    ! Apos o Sprint A.5, celulas terra recebem sst = 271.35 K (marcador).
    ! Combinado com T_2m, U_10m, P_slv reais (continentais), o bulk produz
    ! fluxos enormes sobre terra (Foxx_sen saturando em +-500 W/m^2;
    ! Foxx_lwnet em -300 W/m^2 sobre o Saara).
    !
    ! O MOM6 ja descarta essas celulas em state_setexport (mask2dT), mas o
    ! diagnostico NetCDF do MED captura ANTES dessa mascara, registrando
    ! os valores absurdos. Sprint A.5.1 zera os fluxos sobre terra no
    ! proprio MED, antes da escrita do NetCDF e antes do envio ao MOM6.
    !
    ! HEURISTICA: celulas terra tem sst exatamente = 271.35 K (marcador
    ! cravado pelo where do Sprint A.5). Celulas marinhas polares reais
    ! tem sst variavel em torno de 270-272 K (raramente exato em 271.35).
    !==========================================================================
    block
      real(ESMF_KIND_R8), parameter :: T_FILL_LAND = 271.35_ESMF_KIND_R8
      real(ESMF_KIND_R8), parameter :: TOL         = 1.0e-6_ESMF_KIND_R8
      integer :: n_land_masked
      real(ESMF_KIND_R8), pointer :: p_taux(:,:), p_tauy(:,:), p_sen(:,:)
      real(ESMF_KIND_R8), pointer :: p_evap(:,:), p_lwnet(:,:)
      real(ESMF_KIND_R8), pointer :: p_swvdr(:,:), p_swvdf(:,:)
      real(ESMF_KIND_R8), pointer :: p_swidr(:,:), p_swidf(:,:)
      real(ESMF_KIND_R8), pointer :: p_rain(:,:),  p_snow(:,:)
      logical, allocatable :: land_mask(:,:)

      nullify(p_taux, p_tauy, p_sen, p_evap, p_lwnet)
      nullify(p_swvdr, p_swvdf, p_swidr, p_swidf, p_rain, p_snow)

      if (associated(sst)) then
        ! Construir mascara de terra com base em f_sst_atm marcado pelo Sprint A.5
        allocate(land_mask(lbound(sst,1):ubound(sst,1), &
                           lbound(sst,2):ubound(sst,2)))
        land_mask = abs(sst - T_FILL_LAND) < TOL
        n_land_masked = count(land_mask)

        ! Helper macro: aplicar mascara em cada fluxo
        call ESMF_FieldGet(is%f_taux_atm,  farrayPtr=p_taux,  rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_taux))  &
          where (land_mask) p_taux  = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_tauy_atm,  farrayPtr=p_tauy,  rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_tauy))  &
          where (land_mask) p_tauy  = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_sen_atm,   farrayPtr=p_sen,   rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_sen))   &
          where (land_mask) p_sen   = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_evap_atm,  farrayPtr=p_evap,  rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_evap))  &
          where (land_mask) p_evap  = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_lwnet_atm, farrayPtr=p_lwnet, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_lwnet)) &
          where (land_mask) p_lwnet = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_swvdr_atm, farrayPtr=p_swvdr, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_swvdr)) &
          where (land_mask) p_swvdr = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_swvdf_atm, farrayPtr=p_swvdf, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_swvdf)) &
          where (land_mask) p_swvdf = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_swidr_atm, farrayPtr=p_swidr, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_swidr)) &
          where (land_mask) p_swidr = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_swidf_atm, farrayPtr=p_swidf, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_swidf)) &
          where (land_mask) p_swidf = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_rain_atm,  farrayPtr=p_rain,  rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_rain))  &
          where (land_mask) p_rain  = 0.0_ESMF_KIND_R8
        call ESMF_FieldGet(is%f_snow_atm,  farrayPtr=p_snow,  rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(p_snow))  &
          where (land_mask) p_snow  = 0.0_ESMF_KIND_R8
        rc = ESMF_SUCCESS

        ! Log diagnostico
        block
          character(len=160) :: logmsg
          write(logmsg, '(A,I0,A)') &
            'MED Sprint A.5.1: fluxos zerados em ', n_land_masked, &
            ' celulas de terra (mascara via T_FILL_LAND=271.35K)'
          call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)
        end block

        deallocate(land_mask)
      end if
    end block

    call RegridOrCopy(is%f_taux_atm,   exportState, "Foxx_taux",      is, rc)
    call RegridOrCopy(is%f_tauy_atm,   exportState, "Foxx_tauy",      is, rc)
    call RegridOrCopy(is%f_sen_atm,    exportState, "Foxx_sen",       is, rc)
    call RegridOrCopy(is%f_evap_atm,   exportState, "Foxx_evap",      is, rc)
    call RegridOrCopy(is%f_lwnet_atm,  exportState, "Foxx_lwnet",     is, rc)
    call RegridOrCopy(is%f_swvdr_atm,  exportState, "Foxx_swnet_vdr", is, rc)
    call RegridOrCopy(is%f_swvdf_atm,  exportState, "Foxx_swnet_vdf", is, rc)
    call RegridOrCopy(is%f_swidr_atm,  exportState, "Foxx_swnet_idr", is, rc)
    call RegridOrCopy(is%f_swidf_atm,  exportState, "Foxx_swnet_idf", is, rc)
    call RegridOrCopy(is%f_rain_atm,   exportState, "Faxa_rain",      is, rc)
    call RegridOrCopy(is%f_snow_atm,   exportState, "Faxa_snow",      is, rc)
    call RegridOrCopy(is%f_pslv_atm,   exportState, "Sa_pslv",        is, rc)
    call RegridOrCopy(is%f_ifrac_atm,  exportState, "Si_ifrac",       is, rc)
    call RegridOrCopy(is%f_duu10n_atm, exportState, "So_duu10n",      is, rc)

    ! So_t: SST dinâmica MOM6 → exportState para escrita NetCDF e conector MED→MPAS
    ! Diagnóstico: imprimir min/max de is%f_sst_atm para confirmar que tem dados reais.
    block
      real(ESMF_KIND_R8), pointer :: sst_diag(:,:)
      integer :: rc_sst
      call ESMF_FieldGet(is%f_sst_atm, farrayPtr=sst_diag, rc=rc_sst)
      if (rc_sst == ESMF_SUCCESS .and. associated(sst_diag)) then
        write(*,'(A,F10.3,A,F10.3,A,I0)') &
          '[MED-DIAG] f_sst_atm antes RegridOrCopy: min=', minval(sst_diag), &
          '  max=', maxval(sst_diag), '  size=', size(sst_diag)
        flush(6)
      else
        write(*,'(A,I0)') '[MED-DIAG] f_sst_atm: FieldGet falhou rc=', rc_sst
        flush(6)
      end if
    end block
    call RegridOrCopy(is%f_sst_atm,    exportState, "So_t",           is, rc)
    if (rc /= ESMF_SUCCESS) then
      write(*,'(A,I0)') '[MED-DIAG] RegridOrCopy So_t FALHOU rc=', rc
      flush(6)
      rc = ESMF_SUCCESS  ! não fatal — para debug
    else
      write(*,'(A)') '[MED-DIAG] RegridOrCopy So_t OK'
      flush(6)
    end if

    ! ── Sprint B Fase 2 (Maio 2026) ────────────────────────────────────────
    ! So_u, So_v: correntes superficiais MOM6 -> exportState para conector
    ! MED -> MPAS. Os campos f_uocn_atm/f_vocn_atm já contêm os valores
    ! regridados OCN -> ATM (preenchidos no bloco BUG-CALC-DUU acima a partir
    ! do importState.So_u/So_v). RegridOrCopy faz ATM -> OCN para o exportState;
    ! depois o conector MED -> MPAS fará OCN -> ATM. Mesmo round-trip que So_t —
    ! mantém consistência arquitetural até a refatoração para grade unificada.
    !
    ! Sobre regiões continentais e PETs sem dados: ZeroInternalField em
    ! InitializeRealize e os clamps em RegridOrCopy garantem zeros físicos.
    ! O cap MPAS (mpas_import) também clampa |V_ocn| <= 5 m/s defensivamente.
    call RegridOrCopy(is%f_uocn_atm, exportState, "So_u", is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy So_u FALHOU — exportState mantem zeros', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

    call RegridOrCopy(is%f_vocn_atm, exportState, "So_v", is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy So_v FALHOU — exportState mantem zeros', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

    ! ── Sprint C (Maio 2026) ───────────────────────────────────────────────
    ! Sf_zorl: rugosidade superficial Charnock+Smith calculada no bulk NCAR
    ! a partir de Foxx_taux/tauy. Mesmo padrão arquitetural de So_t/So_u/So_v:
    ! f_zorl_atm (grade ATM interna) -> RegridOrCopy -> exportState.Sf_zorl
    ! (grade OCN) -> conector MED -> MPAS faz o regrid final para Voronoi.
    ! O cap MPAS (Sprint C) atualiza atm_bnd%zorl com este valor a cada passo
    ! em vez de manter o default fixo de 0.01 m.
    call RegridOrCopy(is%f_zorl_atm, exportState, "Sf_zorl", is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy Sf_zorl FALHOU — exportState mantem default 0.01 m', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

    end block  ! BUG-CALC-08: fecha block de arrays globais

    ! Atualizar timestamps do exportState
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fieldNameList(k)), &
        field=field, rc=rc)
      call NUOPC_SetTimestamp(field, nextTime, rc=rc)
    end do
    deallocate(fieldNameList)

    call ESMF_LogWrite('MED: MediatorAdvance concluido', ESMF_LOGMSG_INFO)

    ! ── BUG-OUT-01 fix v4: diagnóstico de importação inline ──────────────────
    ! Implementação direta em MED_cap_MONAN.F90 — sem dependência de
    ! MOM_cap_methods (lib pré-compilada) nem de mpas_cap_config_mod.
    ! Lê mom6_output.nml com namelist local de 2 variáveis (sem ios/=0).
    ! Usa netcdf (já importado neste módulo) para escrever os campos.
    ! ─────────────────────────────────────────────────────────────────────────
    ! ── Fase 2: RouteOcnToAtm — exportar SST/gelo MOM6 dinâmico ao MPAS ────
    ! Chamado quando use_med_to_mpas=.true. (nuopc_mode).
    ! Preenche os campos So_t, Si_ifrac, So_u, So_v no exportState do MED
    ! para que o conector MED→MPAS entregue a SST dinâmica ao MPAS.
    ! Sem esta chamada, o MPAS recebe exportState vazio (campos zerados).
    if (is%use_med_to_mpas) then
      call RouteOcnToAtm(importState, exportState, clock, is, rc)
      if (rc /= ESMF_SUCCESS) then
        call ESMF_LogWrite('MED: RouteOcnToAtm retornou erro — continuando', &
          ESMF_LOGMSG_WARNING)
        rc = ESMF_SUCCESS
      end if
    end if

    call med_write_import_fields(exportState, nextTime, is, rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS  ! nao-fatal
    ! Liberar arrays temporarios de defaults Fase 2 (se alocados)
    if (associated(shum_local)) then
      deallocate(shum_local); nullify(shum_local)
    end if
    if (associated(snow_local)) then
      deallocate(snow_local); nullify(snow_local)
    end if

  end subroutine MediatorAdvance


  !============================================================================
  !> @brief Alternativa 1 (MED) — preenche is%f_ifrac_atm com dados OISST.
  !!
  !! Lê arquivo NetCDF OISST diretamente via netcdf + ESMF_VMBroadcast.
  !! Chamada em MediatorAdvance ANTES de calc_bulk_ncar quando
  !! cfg_use_docn_ice=.true. (nuopc.input &nuopc_mode).
  !!
  !! Algoritmo:
  !!   1. PET0 abre o NetCDF, lê snapshots [tidx0, tidx1], interpola
  !!      linearmente e broadcast via ESMF_VMBroadcast.
  !!   2. Nearest-neighbor: converte coordenadas da grade ATM interna
  !!      (360×180, centros em lon=(i-0.5)*dx, lat=(j-0.5)*dy-90)
  !!      em índices OISST.
  !!   3. Copia para ptr(:,:) de is%f_ifrac_atm.
  subroutine fill_ifrac_from_oisst(is, clock, rc)
    use netcdf  ! deve preceder todas as declarações

    type(MED_InternalState), intent(inout) :: is
    type(ESMF_Clock),        intent(in)    :: clock
    integer,                 intent(out)   :: rc

    type(ESMF_Time)             :: currTime
    type(ESMF_VM)               :: vm
    type(ESMF_TimeInterval)     :: dt_epoch
    type(ESMF_Time)             :: epochTime
    real(ESMF_KIND_R8), pointer :: fptr(:,:) => null()
    real(ESMF_KIND_R8), allocatable :: buf(:)    ! buffer MPI broadcast
    real(ESMF_KIND_R8), allocatable :: f0(:,:), f1(:,:)
    integer :: buf_n(1)       ! wrapper para broadcast de ntime (inteiro escalar)
    integer :: nx_o, ny_o, nx_a, ny_a
    integer :: i, j, i_o, j_o
    integer :: tidx0, tidx1, ntime, localDeCount_f, localPet
    integer :: ncid, varid, dimid, nc_rc
    integer(ESMF_KIND_I8) :: sec_epoch, dt_data_i8
    real(ESMF_KIND_R8) :: alpha, dx_o, dy_o, dx_a, dy_a, lon_a, lat_a
    character(len=256) :: logmsg

    rc = ESMF_SUCCESS

    call ESMF_ClockGet(clock, currTime=currTime, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    ! Dimensões das grades
    nx_o = cfg_docn_nx;   ny_o = cfg_docn_ny
    nx_a = 360;           ny_a = 180
    dx_o = 360.0_ESMF_KIND_R8 / real(nx_o, ESMF_KIND_R8)
    dy_o = 180.0_ESMF_KIND_R8 / real(ny_o, ESMF_KIND_R8)
    dx_a = 360.0_ESMF_KIND_R8 / real(nx_a, ESMF_KIND_R8)
    dy_a = 180.0_ESMF_KIND_R8 / real(ny_a, ESMF_KIND_R8)

    ! Calcular índice temporal: tidx = floor((t - epoch) / dt_data) mod ntime
    call ESMF_TimeSet(epochTime,                   &
      yy   = cfg_docn_epoch_year,                  &
      mm   = cfg_docn_epoch_month,                 &
      dd   = cfg_docn_epoch_day,                   &
      calkindflag = ESMF_CALKIND_GREGORIAN, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_epoch   = currTime - epochTime
    call ESMF_TimeIntervalGet(dt_epoch, s_i8=sec_epoch, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    dt_data_i8 = int(cfg_docn_dt_data, ESMF_KIND_I8)

    allocate(f0(nx_o, ny_o), f1(nx_o, ny_o), buf(nx_o * ny_o))
    f0 = 0.0_ESMF_KIND_R8;  f1 = 0.0_ESMF_KIND_R8;  buf = 0.0_ESMF_KIND_R8

    ! PET0 lê o arquivo; todos os outros PETs aguardam o broadcast
    call ESMF_VMGetGlobal(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      deallocate(f0, f1, buf); return
    end if
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)

    ntime = 365  ! default seguro

    if (localPet == 0) then
      ! Descobrir ntime no arquivo
      nc_rc = nf90_open(trim(cfg_docn_ice_file), NF90_NOWRITE, ncid)
      if (nc_rc == NF90_NOERR) then
        nc_rc = nf90_inq_dimid(ncid, 'time', dimid)
        if (nc_rc /= NF90_NOERR) nc_rc = nf90_inq_dimid(ncid, 'Time', dimid)
        if (nc_rc == NF90_NOERR) then
          nc_rc = nf90_inquire_dimension(ncid, dimid, len=ntime)
        end if
        nc_rc = nf90_close(ncid)
      end if
    end if

    ! Broadcast ntime para todos os PETs.
    ! ESMF_VMBroadcast(integer array): usar buf_n(1) como wrapper do escalar.
    buf_n(1) = ntime
    call ESMF_VMBroadcast(vm, bcstData=buf_n, count=1, rootPet=0, rc=rc)
    if (rc /= ESMF_SUCCESS) buf_n(1) = 365
    ntime = buf_n(1)

    ! Calcular índices de interpolação
    tidx0 = mod(int(sec_epoch / real(dt_data_i8, ESMF_KIND_R8)), ntime) + 1
    tidx1 = mod(tidx0, ntime) + 1
    alpha = real(mod(sec_epoch, dt_data_i8), ESMF_KIND_R8) / real(dt_data_i8, ESMF_KIND_R8)
    alpha = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, alpha))

    if (localPet == 0) then
      nc_rc = nf90_open(trim(cfg_docn_ice_file), NF90_NOWRITE, ncid)
      if (nc_rc == NF90_NOERR) then
        nc_rc = nf90_inq_varid(ncid, trim(cfg_docn_ice_varname), varid)
        if (nc_rc == NF90_NOERR) then
          nc_rc = nf90_get_var(ncid, varid, f0, &
            start=[1, 1, tidx0], count=[nx_o, ny_o, 1])
          nc_rc = nf90_get_var(ncid, varid, f1, &
            start=[1, 1, tidx1], count=[nx_o, ny_o, 1])
          ! Interpolação temporal linear
          f0 = f0 + alpha * (f1 - f0)
          if (cfg_docn_ice_pct) f0 = f0 / 100.0_ESMF_KIND_R8
          f0 = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, f0))
        end if
        nc_rc = nf90_close(ncid)
      end if
      buf = reshape(f0, [nx_o * ny_o])
    end if

    ! Distribuir campo OISST para todos os PETs.
    ! ESMF_VMBroadcast tem sobrecarga para real(ESMF_KIND_R8) array — uso direto.
    call ESMF_VMBroadcast(vm, bcstData=buf, count=nx_o*ny_o, rootPet=0, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      deallocate(f0, f1, buf); return
    end if
    f0 = reshape(buf, [nx_o, ny_o])
    deallocate(f1, buf)

    ! Copiar para is%f_ifrac_atm (grade ATM interna 360×180)
    call ESMF_FieldGet(is%f_ifrac_atm, localDeCount=localDeCount_f, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localDeCount_f == 0) then
      rc = ESMF_SUCCESS; deallocate(f0); return
    end if
    call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=fptr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(fptr)) then
      deallocate(f0); return
    end if

    ! Nearest-neighbor: grade ATM interna (lon centrado em (i-0.5)*dx)
    do j = lbound(fptr,2), ubound(fptr,2)
      lat_a = -90.0_ESMF_KIND_R8 + (real(j,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * dy_a
      j_o   = int((lat_a + 90.0_ESMF_KIND_R8) / dy_o) + 1
      j_o   = max(1, min(ny_o, j_o))
      do i = lbound(fptr,1), ubound(fptr,1)
        lon_a = (real(i,ESMF_KIND_R8) - 0.5_ESMF_KIND_R8) * dx_a
        i_o   = int(lon_a / dx_o) + 1
        i_o   = max(1, min(nx_o, i_o))
        fptr(i,j) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, f0(i_o, j_o)))
      end do
    end do

    deallocate(f0)

    write(logmsg,'(A,A,A,F5.3)') &
      'MED(Alt1): f_ifrac_atm preenchido de ', trim(cfg_docn_ice_file), &
      '  alpha=', alpha
    call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)
    rc = ESMF_SUCCESS

  end subroutine fill_ifrac_from_oisst

end module MED_cap_MONAN_mod

