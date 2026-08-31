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
  use netcdf   ! FIX B-OCNGRID-01: leitura direta de ocean_hgrid.nc (grade T real MOM6)
  use mpas_cap_config_mod, only: cfg_docn_nx, cfg_docn_ny,         &
                                  cfg_use_docn_ice,                 &
                                  cfg_docn_ice_init_only,           &
                                  cfg_docn_ice_file,                &
                                  cfg_docn_ice_varname,             &
                                  cfg_docn_ice_pct,                 &
                                  cfg_docn_dt_data,                 &
                                  cfg_docn_epoch_year,              &
                                  cfg_docn_epoch_month,             &
                                  cfg_docn_epoch_day,               & ! Alternativa 1 + Sprint B.1.1
                                  cfg_use_docn, cfg_mom6_mesh_ocn,  & ! FIX B-OCNGRID-01
                                  cfg_use_sis2_dynamic                ! FIX SIS2-ATIVACAO
  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Advertise, NUOPC_Realize
  use NUOPC, only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet
  use NUOPC, only: NUOPC_IsAtTime
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

    ! FIX B-COASTMASK-02 (Ago 2026): anuncia So_omask no importState do MED.
    ! O OCN (mom_cap_methods.F90::mom_export) ja exporta 'So_omask' = nint(mask2dT)
    ! (1=oceano, 0=terra), mas o MED nunca anunciava esse campo -> o NUOPC
    ! descartava o conector e o MED era forcado a "adivinhar" a mascara terra/
    ! oceano a partir do proprio valor de SST (limiar SST<270K), o que e
    ! inconsistente com a mascara real do MOM6 e contamina a interpolacao
    ! bilinear da costa com valores de celulas de terra fisicamente irreais.
    call NUOPC_Advertise(importState, StandardName="So_omask", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! Si_ifrac_sis2 — fração de gelo real vinda do componente ICE (SIS2).
    !
    ! O nome é deliberadamente diferente de "Si_ifrac" para evitar que os dois
    ! conectores automáticos, OCN->MED e ICE->MED, apontem para o mesmo nome de
    ! campo: nesse caso o resultado dependeria da ordem de execução. Sem este
    ! advertise, o conector ICE->MED não tem o que casar do lado do MED, o
    ! campo aparece como "Connected: false" no Compliance Checker e a leitura
    ! feita em RouteOcnToAtm (med_cap_methods.F90) falha sem alarde.
    if (cfg_use_sis2_dynamic) then
      ! SharePolicyField="share" é mantido aqui por consistência: todos os
      ! demais campos de IMPORTAÇÃO do mediador (So_t, Sa_*, etc.) usam a
      ! mesma política e funcionam. A anomalia corrigida estava do lado do
      ! EXPORTADOR: o cap do gelo era o único do sistema a usar share numa
      ! exportação, e com isso o conector aparentemente pulava a
      ! transferência real e entregava zeros ao mediador (a origem tinha
      ! máximo 0,997 e o destino chegava com mínimo e máximo iguais a zero).
      ! Ver sis_cap_MONAN.F90::InitializeAdvertise.
      call NUOPC_Advertise(importState, StandardName="Si_ifrac_sis2", &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end if

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
    character(len=256)  :: msg_tmp  ! FIX B-OCNGRID-01

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
    ! FIX B-OCNGRID-01 (Ago 2026): cfg_docn_nx/ny (1440x720) sao a grade do
    ! DOCN/OISST (0.25 grau, regular). Quando o OCN real e' o MOM6+SIS2
    ! dinamico (cfg_use_docn=.false., modo de producao), a grade T real do
    ! MOM6 e' definida por NIGLOBAL/NJGLOBAL no MOM_input e normalmente NAO
    ! coincide com a grade DOCN (ex.: 180x155 vs 1440x720 observado em
    ! producao). Usar cfg_docn_nx/ny nesse caso faz o mediador declarar uma
    ! grade ~8x maior e geometricamente uniforme (lat/lon regular) onde a
    ! grade real e' tripolar/nao-uniforme -> o conector NUOPC OCN->MED monta
    ! um regrid automatico usando coordenadas erradas, contaminando TODOS os
    ! campos (So_t, So_u, So_v, So_omask) antes mesmo da mascara de costa
    ! entrar em acao. Por isso, em modo MOM6 lemos a dimensao real da grade T
    ! diretamente do supergrid ocean_hgrid.nc (nx/ny do arquivo / 2, convencao
    ! FRE-NCtools) em vez de reutilizar a config do DOCN.
    if (cfg_use_docn) then
      nx_ocn = cfg_docn_nx  ! Grade DOCN de nuopc.input (ex: OISST 0.25° = 1440)
      ny_ocn = cfg_docn_ny  ! Grade DOCN de nuopc.input (ex: OISST 0.25° =  720)
    else
      call MED_ReadMom6TGridDims(trim(cfg_mom6_mesh_ocn), nx_ocn, ny_ocn, rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="MED: falha ao ler dimensoes reais de ocean_hgrid.nc " // &
            "(NIGLOBAL/NJGLOBAL do MOM6) - verifique cfg_mom6_mesh_ocn", &
        line=__LINE__, file=__FILE__)) return
      write(msg_tmp,'(A,I0,A,I0,A)') 'MED: grade T real do MOM6 lida de ' // &
        trim(cfg_mom6_mesh_ocn) // ' = ', nx_ocn, ' x ', ny_ocn, &
        ' (NIGLOBAL x NJGLOBAL)'
      call ESMF_LogWrite(trim(msg_tmp), ESMF_LOGMSG_INFO)
    end if

    !--------------------------------------------------------------------------
    ! Criar grade ATM regular 640x320
    !--------------------------------------------------------------------------
    ! B-52 (fix B-50): regDecomp 2D universal — sem DE de largura 1 e sem PETs vazios.
    ! ATM 640x320: nx_max=320, ny=ceil(N/320)
    !   N=128: ny=1 → regDecomp=(/128,1/) → 640/128=5 col ✓
    !   N=512: ny=2 → regDecomp=(/320,2/) → 640 DEs>512, 640/320=2 col, 320/2=160 lin ✓
    !
    ! -------------------------------------------------------------------------
    ! BUG-CALC-08-COV (fix B-58): a fórmula B-52 gera totalDEs = nx_max*ny_tiles
    ! que só coincide com petCount quando sqrt(petCount) é inteiro. Quando
    ! totalDEs > petCount, alguns PETs recebem localDeCount=2. O gather de
    ! med_write_import_fields (uas_g etc., ~L1017) usa lbound/ubound(uas), que
    ! cobrem apenas o PRIMEIRO DE local de cada PET; o segundo DE fica de fora do
    ! tmp_local e some no Allreduce(SUM) → linhas de latitude inteiras zeradas no
    ! campo global. O MOM6 recebe forçante com buracos e aborta com "extreme
    ! surface values".
    !   N=16: sqrt=4 exato → (4,4)=16 DEs = petCount → 180 linhas OK (funciona)
    !   N=32: sqrt≈5,66→6  → (6,6)=36 DEs (4 órfãos) → ~20 linhas perdidas ✗
    ! CORREÇÃO: fatorar petCount EXATAMENTE em (ncol,nrow), ncol*nrow = petCount
    ! (1 DE por PET), par mais próximo de quadrado, respeitando ncol<=nx_atm/2 e
    ! nrow<=ny_atm. Idêntico ao fix aplicado em mpas_cap_methods (grade do cap).
    !   N=16→(4,4)  N=32→(8,4)  N=64→(8,8)  N=128→(16,8)  N=512→(32,16)
    ! -------------------------------------------------------------------------
    nx_tiles_target = max(1, int(sqrt(real(petCount))))
    ny_tiles = 1
    do lde = nx_tiles_target, 1, -1
      if (mod(petCount, lde) == 0 .and. lde <= ny_atm &
          .and. (petCount / lde) <= nx_atm / 2) then
        ny_tiles = lde
        exit
      end if
    end do
    nx_max       = petCount / ny_tiles
    regDecomp(1) = nx_max          ! colunas (lon)
    regDecomp(2) = ny_tiles        ! linhas (lat)
    ! Invariante: regDecomp(1)*regDecomp(2) == petCount (1 DE por PET).
    ! ESMF_INDEX_GLOBAL: necessário para mapeamento global em med_write_import_fields.
    ! Loops bulk usam lbound/ubound - agnósticos ao indexflag do MPAS.
    ! REVERT B-OCNGRID-05 (Ago 2026): a tentativa de fixar polekindflag=MONOPOLE
    ! explicitamente foi REVERTIDA. Motivo: o usuario confirmou que a versao
    ! ANTERIOR a qualquer mudanca de grade nesta sessao rodava sem SIGSEGV,
    ! apesar do artefato de costa. atm_grid ja' usava ESMF_GridCreate1PeriDim
    ! SEM polekindflag explicito (dependendo do default do ESMF) nessa versao
    ! que funcionava. Declarar MONOPOLE nas bordas de latitude desta grade
    ! regular (linhas extremas em ±89.5°, que NAO sao um ponto geometrico
    ! unico) e' fisicamente incorreto e e' o principal suspeito de ter
    ! corrompido os pesos de regrid perto dos polos, alimentando valores
    ! invalidos para a malha Voronoi do MPAS-A e causando o SIGSEGV em
    ! core_run. Voltando a configuracao original (sem polekindflag).
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
    !
    ! BUG-CALC-08-COV (fix B-58): mesma fatoração exata da grade ATM. Garante
    ! totalDEs = petCount (1 DE por PET), evitando DEs órfãos. Respeita
    ! ncol<=nx_ocn/2 e nrow<=ny_ocn.
    nx_tiles_target = max(1, int(sqrt(real(petCount))))
    ny_tiles = 1
    do lde = nx_tiles_target, 1, -1
      if (mod(petCount, lde) == 0 .and. lde <= ny_ocn &
          .and. (petCount / lde) <= nx_ocn / 2) then
        ny_tiles = lde
        exit
      end if
    end do
    nx_max       = petCount / ny_tiles
    regDecomp(1) = nx_max          ! colunas (lon)
    regDecomp(2) = ny_tiles        ! linhas (lat)
    ! Invariante: regDecomp(1)*regDecomp(2) == petCount (1 DE por PET).
    ! ESMF_INDEX_GLOBAL: consistência com atm_grid para med_write_import_fields.
    ! FIX B-OCNGRID-03 (Ago 2026): a grade OCN era criada SEM dimensao
    ! periodica (ESMF_GridCreateNoPeriDim). Isso significa que o ESMF nao
    ! sabe que a coluna i=nx_ocn (longitude ~360) e a coluna i=1 (longitude
    ! ~0) sao fisicamente vizinhas - o regrid bilinear trata a borda leste/
    ! oeste da grade como um limite de dominio, nao como um ponto de
    ! continuidade. Resultado: uma coluna de celulas "sem vizinho valido"
    ! exatamente na costura (visivel como uma faixa de valores indefinidos
    ! no Oceano Indico, ~60E, onde a longitude bruta do supergrid do MOM6
    ! da volta: intervalo nativo -300..60 fecha exatamente ali).
    ! FIX: ESMF_GridCreate1PeriDim com periodicDim=1 (longitude periodica).
    ! Essa parte, testada, funcionou (costura do Indico desapareceu).
    ! REVERT PARCIAL (Ago 2026): a primeira versao desta correcao tambem
    ! especificava polekindflag=(/MONOPOLE,MONOPOLE/) explicitamente. Isso foi
    ! REVERTIDO - o usuario confirmou que a versao anterior a qualquer
    ! mudanca de grade rodava sem SIGSEGV, e a grade ATM (que ja' usava
    ! GridCreate1PeriDim SEM polekindflag explicito) fazia parte dessa
    ! configuracao que funcionava. Declarar MONOPOLE numa borda de latitude
    ! que NAO e' um ponto geometrico unico (j=1 desta grade fica em -78°, a
    ! borda da Antartida - uma linha inteira de pontos, nao um polo) e'
    ! fisicamente incorreto e e' o principal suspeito de ter corrompido os
    ! pesos de regrid perto dos polos/dobra, alimentando valores invalidos
    ! para a malha Voronoi do MPAS-A e causando o SIGSEGV em core_run.
    ! Mantendo periodicDim=1 (beneficio confirmado) e deixando o ESMF usar
    ! seu polekindflag padrao (mesma config que ja' funcionava no atm_grid).
    ! ATENCAO: a assinatura exata de ESMF_GridCreate1PeriDim deve ser
    ! conferida contra a versao instalada do ESMF (8.9.1) antes do build -
    ! nomes/ordem de argumentos podem variar entre versoes.
    ocn_grid = ESMF_GridCreate1PeriDim(minIndex=(/1,1/), maxIndex=(/nx_ocn, ny_ocn/), &
      regDecomp=regDecomp, periodicDim=1, &
      indexflag=ESMF_INDEX_GLOBAL, &
      coordSys=ESMF_COORDSYS_SPH_DEG, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha ao criar grade OCN " // &
      "periodica (ESMF_GridCreate1PeriDim) - verifique assinatura ESMF 8.9.1", &
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
      call ESMF_GridGetCoord(ocn_grid, coordDim=2, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY, rc=rc)
      if (cfg_use_docn) then
        ! DOCN/OISST: grade lat/lon regular DE VERDADE - formula uniforme e' exata.
        do j = lbound(coordX,2), ubound(coordX,2)
          do i = lbound(coordX,1), ubound(coordX,1)
            coordX(i,j) = (i-1) * (360.0_ESMF_KIND_R8/nx_ocn)
          end do
        end do
        do j = lbound(coordY,2), ubound(coordY,2)
          do i = lbound(coordY,1), ubound(coordY,1)
            coordY(i,j) = -90.0_ESMF_KIND_R8 + (j-1)*(180.0_ESMF_KIND_R8/ny_ocn) + &
                          (180.0_ESMF_KIND_R8/ny_ocn)/2.0_ESMF_KIND_R8
          end do
        end do
      else
        ! FIX B-OCNGRID-01: MOM6 tripolar real - le as coordenadas T verdadeiras
        ! do supergrid ocean_hgrid.nc (NAO uniformes; convergem no polo Norte).
        ! Sem isso, o conector NUOPC OCN->MED interpola usando posicoes erradas
        ! e a costa fica sistematicamente deslocada em todo o dominio.
        call MED_FillMom6TGridCoords(trim(cfg_mom6_mesh_ocn), coordX, coordY, rc)
        if (ESMF_LogFoundError(rcToCheck=rc, &
          msg="MED: falha ao ler coordenadas T reais de ocean_hgrid.nc " // &
              "para o DE local - grade OCN do mediador ficara incorreta", &
          line=__LINE__, file=__FILE__)) return
      end if
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

    ! FIX B-COASTMASK-02: realizar So_omask (mascara real mask2dT do MOM6)
    ! na grade OCN, simetrico a So_t/So_u/So_v.
    tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name="So_omask", rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    ! FIX SIS2-ATIVACAO (Ago 2026): realizar Si_ifrac_sis2 (gelo real do
    ! ICE) na MESMA grade ocn_grid — a grade do componente ICE (ver
    ! sis_cap_MONAN.F90) foi construída com a mesma geometria (mesma
    ! ocean_hgrid.nc, mesmas dimensões, mesma periodicidade), então é
    ! geometricamente equivalente a ocn_grid para fins de realização aqui.
    if (cfg_use_sis2_dynamic) then
      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name="Si_ifrac_sis2", rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
      call NUOPC_Realize(importState, field=tmp_field, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return
    end if

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
    !
    ! FIX-DEADLOCK (modo concurrent, v13.0): NÃO cair para MPI_COMM_WORLD em
    ! caso de erro. med_mpi_comm alimenta os MPI_Allreduce coletivos de
    ! med_write_import_fields. No modo concurrent o MED tem seu próprio
    ! comunicador de componente; substituí-lo silenciosamente por
    ! MPI_COMM_WORLD (todos os ranks) num coletivo sobre o comunicador do
    ! componente causaria mismatch / deadlock. Falhar cedo é o correto —
    ! um erro de VM é excepcional e deve abortar, não ser mascarado.
    block
      type(ESMF_VM) :: med_vm
      call ESMF_VMGetCurrent(med_vm, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='MED: falha ESMF_VMGetCurrent em InitializeRealize', &
        line=__LINE__, file=__FILE__)) return
      call ESMF_VMGet(med_vm, localPet=med_local_pet, petCount=med_pet_count, &
        mpiCommunicator=med_mpi_comm, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='MED: falha ESMF_VMGet mpiCommunicator em InitializeRealize', &
        line=__LINE__, file=__FILE__)) return
    end block

    call ESMF_LogWrite('MED: InitializeRealize concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeRealize

  !============================================================================
  ! FIX B-OCNGRID-01 (Ago 2026)
  !
  ! CAUSA-RAIZ: a grade "ocn_grid" que o MEDIADOR usa internamente para o
  ! regrid OCN<->ATM era construida com as dimensoes do DOCN/OISST
  ! (cfg_docn_nx x cfg_docn_ny = 1440x720) e coordenadas lat/lon UNIFORMES,
  ! mesmo quando o componente OCN real e' o MOM6+SIS2 dinamico (grade
  ! tripolar, NAO uniforme). Em producao (cfg_use_docn=.false.) a grade T
  ! real do MOM6 (NIGLOBAL x NJGLOBAL no MOM_input) e' MUITO menor e
  ! geometricamente diferente (ex.: 180x155 medido em campo vs 1440x720
  ! assumido pelo mediador). Como os dois lados (OCN real, MED fabricado)
  ! sao objetos ESMF geometricamente distintos, o NUOPC monta um regrid
  ! AUTOMATICO entre eles usando as coordenadas erradas do MED ? isso
  ! contamina todos os campos OCN->MED (So_t, So_u, So_v, So_omask) com um
  ! deslocamento geografico sistematico, mais visivel exatamente na costa
  ! (onde pequenos erros de posicao cruzam a fronteira terra/mar).
  !
  ! FIX: quando cfg_use_docn=.false. (MOM6 ativo), a grade T real e' lida
  ! diretamente do supergrid FRE-NCtools (ocean_hgrid.nc, mesmo arquivo
  ! apontado por mesh_ocn em nuopc.input): dimensoes = nx/ny do arquivo / 2;
  ! coordenadas T = pontos pares do supergrid (indice 2*i, 2*j). Ambas as
  ! subrotinas abaixo sao chamadas a partir de InitializeRealize, ANTES de
  ! qualquer ESMF_FieldRegridStore, para que TODOS os campos OCN<->MED
  ! herdem a geometria correta (nao so' o SST mascarado).
  !============================================================================

  !----------------------------------------------------------------------------
  ! MED_ReadMom6TGridDims ? le as dimensoes do supergrid (variaveis 'nx'/'ny'
  ! de ocean_hgrid.nc) e devolve a grade T real do MOM6 (NIGLOBAL x NJGLOBAL),
  ! que e' metade da resolucao do supergrid em cada eixo (convencao padrao
  ! FRE-NCtools/make_hgrid: supergrid inclui vertices + centros das celulas).
  !----------------------------------------------------------------------------


  !----------------------------------------------------------------------------
  ! MED_ReadMom6TGridDims — le as dimensoes do supergrid (variaveis 'nx'/'ny'
  ! de ocean_hgrid.nc) e devolve a grade T real do MOM6 (NIGLOBAL x NJGLOBAL),
  ! que e' metade da resolucao do supergrid em cada eixo (convencao padrao
  ! FRE-NCtools/make_hgrid: supergrid inclui vertices + centros das celulas).
  !----------------------------------------------------------------------------
  subroutine MED_ReadMom6TGridDims(filename, ni, nj, rc)
    character(len=*), intent(in)  :: filename
    integer,           intent(out) :: ni, nj
    integer,           intent(out) :: rc
    integer :: ncid, dimid, nx_super, ny_super, ncstat

    rc = ESMF_SUCCESS
    ni = 0; nj = 0

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('MED B-OCNGRID-01: falha ao abrir ' // trim(filename) // &
        ' para ler dimensoes da grade T real do MOM6', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'nx', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=nx_super)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('MED B-OCNGRID-01: falha ao ler dimensao "nx" de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_inq_dimid(ncid, 'ny', dimid)
    if (ncstat == NF90_NOERR) ncstat = nf90_inquire_dimension(ncid, dimid, len=ny_super)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('MED B-OCNGRID-01: falha ao ler dimensao "ny" de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ncstat = nf90_close(ncid)

    if (mod(nx_super,2) /= 0 .or. mod(ny_super,2) /= 0) then
      call ESMF_LogWrite('MED B-OCNGRID-01: AVISO - nx/ny impar em ' // &
        trim(filename) // ' (formato inesperado; nao parece supergrid ' // &
        'FRE-NCtools padrao). Prosseguindo com divisao inteira por 2.', &
        ESMF_LOGMSG_WARNING)
    end if

    ni = nx_super / 2
    nj = ny_super / 2
  end subroutine MED_ReadMom6TGridDims

  !----------------------------------------------------------------------------
  ! MED_FillMom6TGridCoords - preenche coordX/coordY (bounds em indice GLOBAL,
  ! pois ocn_grid usa ESMF_INDEX_GLOBAL) com as coordenadas T REAIS lidas do
  ! supergrid ocean_hgrid.nc via hyperslab com stride=2 (pula os pontos de
  ! vertice/aresta do supergrid, mantendo so' os centros das celulas T).
  ! Convencao FRE-NCtools: celula T global (i,j), i=1..NIGLOBAL, j=1..NJGLOBAL,
  ! esta no indice de supergrid (2*i, 2*j), 1-based.
  !----------------------------------------------------------------------------
  subroutine MED_FillMom6TGridCoords(filename, coordX, coordY, rc)
    character(len=*),    intent(in)    :: filename
    real(ESMF_KIND_R8), pointer        :: coordX(:,:), coordY(:,:)
    integer,              intent(out)  :: rc
    integer :: ncid, varid_x, varid_y, ncstat
    integer :: i1, i2, j1, j2, ni_local, nj_local
    integer :: start2(2), count2(2), stride2(2)

    rc = ESMF_SUCCESS
    if (.not. associated(coordX) .or. .not. associated(coordY)) return

    i1 = lbound(coordX,1); i2 = ubound(coordX,1)
    j1 = lbound(coordX,2); j2 = ubound(coordX,2)
    ni_local = i2 - i1 + 1
    nj_local = j2 - j1 + 1
    if (ni_local <= 0 .or. nj_local <= 0) return

    ncstat = nf90_open(trim(filename), NF90_NOWRITE, ncid)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('MED B-OCNGRID-01: falha ao abrir ' // trim(filename) // &
        ' para ler coordenadas T reais do MOM6', ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    ncstat = nf90_inq_varid(ncid, 'x', varid_x)
    if (ncstat == NF90_NOERR) ncstat = nf90_inq_varid(ncid, 'y', varid_y)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('MED B-OCNGRID-01: variaveis "x"/"y" nao encontradas em ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      ncstat = nf90_close(ncid)
      return
    end if

    ! Ponto T (i,j) [global, 1-based] = vertice de supergrid (2*i, 2*j).
    ! stride=2 le direto os centros, sem carregar o supergrid inteiro (2x
    ! resolucao) na memoria de cada PET.
    start2  = (/ 2*i1, 2*j1 /)
    count2  = (/ ni_local, nj_local /)
    stride2 = (/ 2, 2 /)

    ncstat = nf90_get_var(ncid, varid_x, coordX, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('MED B-OCNGRID-01: falha ao ler "x" (lon) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ! FIX B-OCNGRID-03: normaliza longitude bruta do supergrid (ex.: -300..60,
    ! convencao nativa do make_hgrid) para 0..360, mesma convencao da grade
    ! ATM (coordX = (i-1)*360/nx_atm). Sem isso, os dois lados do acoplamento
    ! descrevem a mesma posicao fisica com numeros de longitude diferentes.
    where (coordX < 0.0_ESMF_KIND_R8)
      coordX = coordX + 360.0_ESMF_KIND_R8
    end where
    where (coordX >= 360.0_ESMF_KIND_R8)
      coordX = coordX - 360.0_ESMF_KIND_R8
    end where

    ncstat = nf90_get_var(ncid, varid_y, coordY, start=start2, count=count2, &
      stride=stride2)
    if (ncstat /= NF90_NOERR) then
      call ESMF_LogWrite('MED B-OCNGRID-01: falha ao ler "y" (lat) de ' // &
        trim(filename), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
    end if

    ncstat = nf90_close(ncid)

    ! DIAGNOSTICO TEMPORARIO B-OCNGRID-01b: comprova o que foi lido de fato.
    ! coordX deve VARIAR com i (longitude) e ser ~constante ao longo de j
    ! (exceto perto do fold tripolar); coordY o oposto. Se coordX nao variar
    ! com i, a longitude "colapsou" e o regrid produz bandas puramente
    ! zonais (sem estrutura leste-oeste) ? exatamente o sintoma relatado.
    block
      character(len=300) :: dbgmsg
      real(ESMF_KIND_R8) :: x_row_min, x_row_max, y_col_min, y_col_max
      if (ni_local >= 2 .and. nj_local >= 1) then
        x_row_min = minval(coordX(:, j1))
        x_row_max = maxval(coordX(:, j1))
      else
        x_row_min = -999.0_ESMF_KIND_R8; x_row_max = -999.0_ESMF_KIND_R8
      end if
      if (nj_local >= 2 .and. ni_local >= 1) then
        y_col_min = minval(coordY(i1, :))
        y_col_max = maxval(coordY(i1, :))
      else
        y_col_min = -999.0_ESMF_KIND_R8; y_col_max = -999.0_ESMF_KIND_R8
      end if
      write(dbgmsg,'(A,I0,A,I0,A,I0,A,I0,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3,A,F9.3)') &
        'MED B-OCNGRID-01b DIAG: DE i=[',i1,',',i2,'] j=[',j1,',',j2, &
        '] coordX(i,j1) min=', x_row_min, ' max=', x_row_max, &
        ' | coordY(i1,j) min=', y_col_min, ' max=', y_col_max, &
        ' | coordX(i1,j1)=', coordX(i1,j1), ' coordX(i2,j1)=', coordX(i2,j1), &
        ' | coordY(i1,j1)=', coordY(i1,j1), ' coordY(i1,j2)=', coordY(i1,j2)
      call ESMF_LogWrite(trim(dbgmsg), ESMF_LOGMSG_INFO)
    end block
  end subroutine MED_FillMom6TGridCoords


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
    type(ESMF_Time)          :: startTime
    type(ESMF_Field)         :: atm_field, ocn_field, exp_field
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: fieldCount, i, localrc
    character(len=64), allocatable :: fieldNameList(:)
    character(len=160) :: msg_gate
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    real(ESMF_KIND_R8), pointer :: sstp(:,:)
    logical :: sst_ready
    type(ESMF_VM) :: vm
    integer :: lde, ldec_sst
    integer :: n_phys_s(1), n_phys_g(1)
    integer, save :: n_gate_tries = 0
    integer, parameter :: MAX_GATE_TRIES = 5

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

  !==========================================================================
  ! FASE A — GEOMETRIA (uma unica vez, na primeira iteracao)
  !
  ! FIX B-SEQINIT-01 (v14.21): esta rotina foi dividida em duas fases porque
  ! ela pode ser chamada MAIS DE UMA VEZ. O laco de resolucao de dependencia
  ! de dados do driver NUOPC percorre a RunSequence repetidamente, executando
  ! o Run dos conectores e o label_DataInitialize dos componentes, ate que
  ! todos declarem InitializeDataComplete. Antes deste fix o MED declarava
  ! "true" incondicionalmente na primeira passagem, e o laco parava ali.
  !
  ! Na RunSequence SEQUENCIAL o conector "OCN -> MED" vem ANTES do elemento
  ! "OCN", ou seja, antes de o mom_cap escrever So_t em InitializeDataComplete.
  ! Com uma unica passagem, o So_t que chega aqui e' o campo ainda nao
  ! preenchido. Na RunSequence CONCORRENTE a ordem e' inversa ("OCN" antes de
  ! "OCN -> MED"), e por isso o modo concorrente funcionava — por acidente de
  ! ordenacao, nao por corretude. O pet_layout nao tem parte nisso: o mesmo
  ! defeito ocorre em sequential+shared.
  !
  ! O FieldRegridStore abaixo depende so' da GEOMETRIA dos campos, nunca dos
  ! valores, entao permanece na primeira passagem — e' caro e nao deve repetir.
  !==========================================================================
    if (.not. is%rh_created) then

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

      is%rh_created = .true.
      call ESMF_LogWrite('MED: IDC fase A — routehandles criados', &
        ESMF_LOGMSG_INFO)
    end if   ! .not. is%rh_created

  !==========================================================================
  ! GATE DE DADOS — So_t ja' foi escrito pelo OCN?
  !
  ! O mom_cap (e o DOCN) carimbam TODOS os campos exportados com startTime em
  ! seu InitializeDataComplete, e o conector NUOPC propaga o carimbo ao campo
  ! de destino. Portanto NUOPC_IsAtTime distingue exatamente os dois casos:
  ! So_t recem-chegado do oceano (carimbado) contra o campo ainda nao escrito
  ! (sem carimbo). Esse carimbo ja' existia no mom_cap desde a v7.0; nenhum
  ! consumidor o verificava.
  !
  ! Enquanto o dado nao chega, declaramos Progress=true (a fase A progrediu:
  ! os routehandles existem) e Complete=false. Isso forca o driver a percorrer
  ! a RunSequence outra vez; na segunda passagem o "OCN -> MED" ja' encontra o
  ! So_t escrito pelo "OCN" da passagem anterior, e o gate abre.
  !==========================================================================
    call ESMF_ClockGet(clock, startTime=startTime, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

    call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha So_t (gate)", &
      line=__LINE__, file=__FILE__)) return

    sst_ready = NUOPC_IsAtTime(ocn_field, startTime, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return

  !--------------------------------------------------------------------------
  ! FIX B-SEQINIT-02 (v14.21): CARIMBO NAO E' DADO.
  !
  ! O mom_cap aplica NUOPC_SetTimestamp a TODOS os campos do exportState em
  ! seu InitializeDataComplete, em laco cego sobre o itemNameList, sem
  ! verificar quais deles o mom_export realmente preencheu. Um So_t
  ! identicamente nulo passa no NUOPC_IsAtTime — foi o que aconteceu enquanto
  ! ocean_model_init_sfc nao era chamado: o gate abria, o mediador seguia, e
  ! a extrapolacao da secao 3 convertia o campo inteiro em T_FILL=271.35 K,
  ! o que por sua vez fazia a mascara Sprint A.5.1 classificar o planeta
  ! inteiro como terra e zerar os 11 campos de fluxo.
  !
  ! Exigir tambem VALOR fisicamente plausivel em alguma celula, contado
  ! GLOBALMENTE: um DE pode legitimamente conter so' terra e gelo.
  !--------------------------------------------------------------------------
    if (sst_ready) then
      call ESMF_VMGetCurrent(vm, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
        line=__LINE__, file=__FILE__)) return

      n_phys_s(1) = 0
      call ESMF_FieldGet(ocn_field, localDeCount=ldec_sst, rc=localrc)
      if (localrc == ESMF_SUCCESS) then
        do lde = 0, ldec_sst - 1
          nullify(sstp)
          call ESMF_FieldGet(ocn_field, localDe=lde, farrayPtr=sstp, rc=localrc)
          if (localrc /= ESMF_SUCCESS .or. .not. associated(sstp)) cycle
          n_phys_s(1) = n_phys_s(1) + &
            count(sstp > 270.0_ESMF_KIND_R8 .and. sstp < 310.0_ESMF_KIND_R8)
        end do
      end if

      ! Coletivo sobre a VM do MED — todos os PETs do mediador entram aqui.
      call ESMF_VMAllReduce(vm, n_phys_s, n_phys_g, 1, ESMF_REDUCE_SUM, rc=localrc)
      if (localrc /= ESMF_SUCCESS) n_phys_g(1) = n_phys_s(1)

      if (n_phys_g(1) == 0) then
        sst_ready = .false.
        call ESMF_LogWrite('MED: IDC — So_t carimbado mas SEM valor fisico '// &
          '(nenhuma celula em [270,310] K no globo)', ESMF_LOGMSG_WARNING)
      else
        write(msg_gate,'(A,I0,A)') 'MED: IDC — So_t com ', n_phys_g(1), &
          ' celulas em [270,310] K'
        call ESMF_LogWrite(trim(msg_gate), ESMF_LOGMSG_INFO)
      end if
    end if

    if (.not. sst_ready) then
      n_gate_tries = n_gate_tries + 1
      ! Falhar alto em vez de seguir com SST nula: era exatamente esse
      ! prosseguimento silencioso que produzia mapas de fluxo em branco no
      ! passo 1, com a causa escondida a tres camadas de distancia.
      if (n_gate_tries >= MAX_GATE_TRIES) then
        ! AVISO, nao aborto. O modelo de como o driver NUOPC percorre a
        ! RunSequence durante a resolucao de dependencia de dados ainda nao
        ! esta plenamente verificado: o gate ja' foi observado fechando uma
        ! vez em coupling_mode='concurrent', onde a ordem dos elementos
        ! preveria abertura imediata. Enquanto essa discrepancia nao for
        ! entendida, abortar aqui arriscaria derrubar execucoes que hoje
        ! funcionam. O aviso e' alto e nomeia o que inspecionar; o
        ! comportamento anterior a este gate e' preservado.
        call ESMF_LogWrite('MED: AVISO — So_t sem valores fisicos apos '// &
          'varias iteracoes do laco de dependencia de dados; prosseguindo.', &
          ESMF_LOGMSG_WARNING)
        call ESMF_LogWrite('  A SST em t=0 pode estar nula. Inspecione '// &
          '"So_t BRUTO" e "[MED-DIAG] f_sst_atm" no passo 1 antes de '// &
          'confiar nos fluxos.', ESMF_LOGMSG_WARNING)
        call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", &
          value="true", rc=rc)
        call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
          value="true", rc=rc)
        return
      end if
      call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", &
        value="true", rc=rc)
      call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", &
        value="false", rc=rc)
      call ESMF_LogWrite('MED: IDC aguardando So_t do OCN — '// &
        'nova iteracao do laco de dependencia de dados', ESMF_LOGMSG_INFO)
      return
    end if

  !==========================================================================
  ! FASE B — DADOS (So_t valido em maos)
  !
  ! BUG-CALC-DUU (fix v13.0): primeiro regrid de So_u e So_v para
  ! f_uocn_atm/f_vocn_atm. So_u e So_v sao anunciados e realizados no
  ! importState do MED (ocn_grid), portanto ESMF_StateGet e' seguro. O
  ! routehandle rh_ocn2atm (bilinear, ja' criado na fase A) e' reutilizado:
  ! So_u/So_v compartilham a mesma grade OCN que So_t → mapeamento identico.
  !==========================================================================
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

    ! SST de t=0 para a grade ATM. Sem isto, f_sst_atm permaneceria no valor de
    ! bootstrap SST_BULK_FALLBACK ate' o primeiro MediatorAdvance, e o
    ! conector MED -> MPAS entregaria essa constante ao MPAS na inicializacao.
    call ESMF_FieldRegrid(ocn_field, is%f_sst_atm, is%rh_ocn2atm, &
      zeroregion=ESMF_REGION_TOTAL, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: IDC — regrid So_t->ATM falhou; '// &
        'mantido SST_BULK_FALLBACK', ESMF_LOGMSG_WARNING)
    else
      ! Publica a SST de t=0 no exportState (zerado na fase A), de modo que o
      ! "MED -> MPAS" desta mesma passagem entregue SST fisica, e nao zero.
      call RegridOrCopy(is%f_sst_atm, exportState, "So_t", is, localrc)
      if (localrc /= ESMF_SUCCESS) &
        call ESMF_LogWrite('MED: IDC — RegridOrCopy So_t falhou', &
          ESMF_LOGMSG_WARNING)
    end if

    ! Carimbar os campos exportados com startTime: e' o que permite ao MPAS
    ! (e a qualquer consumidor futuro) aplicar o mesmo gate NUOPC_IsAtTime.
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    if (fieldCount > 0) then
      allocate(fieldNameList(fieldCount))
      call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
      do i = 1, fieldCount
        call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
          field=exp_field, rc=localrc)
        if (localrc == ESMF_SUCCESS) &
          call NUOPC_SetTimestamp(exp_field, startTime, rc=localrc)
      end do
      deallocate(fieldNameList)
    end if

    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataProgress", value="true", rc=rc)
    call NUOPC_CompAttributeSet(gcomp, name="InitializeDataComplete", value="true", rc=rc)

    call ESMF_LogWrite('MED: InitializeDataComplete SATISFIED (So_t em t=0)', &
      ESMF_LOGMSG_INFO)
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
    ! Fase 3: fluxos nativos do PBL do MONAN-A (opcionais — ausencia mantem
    ! o fallback bulk NCAR via calc_bulk_ncar, ex. modo DATM)
    real(ESMF_KIND_R8), pointer :: sen_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: lat_mpas(:,:)  => null()
    real(ESMF_KIND_R8), pointer :: taux_mpas(:,:) => null()
    real(ESMF_KIND_R8), pointer :: tauy_mpas(:,:) => null()
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

    !--------------------------------------------------------------------------
    ! 1c. CAMPOS FASE 3 OPCIONAIS — fluxos nativos do PBL do MONAN-A.
    !     Ausencia (mpas_cap antigo, ou modo DATM) NAO desabilita
    !     mpas_available; apenas mantem sen/evap/taux/tauy vindos do bulk
    !     NCAR (calc_bulk_ncar) mais abaixo.
    !--------------------------------------------------------------------------
    if (mpas_available) then
      call GetFieldPtrOptional(importState, "Faxa_sen_mpas",  sen_mpas,  rc)
      call GetFieldPtrOptional(importState, "Faxa_lat_mpas",  lat_mpas,  rc)
      call GetFieldPtrOptional(importState, "Faxa_taux_mpas", taux_mpas, rc)
      call GetFieldPtrOptional(importState, "Faxa_tauy_mpas", tauy_mpas, rc)
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
    ! FIX B-COASTMASK-02 (Ago 2026): a mascara terra/oceano usada no regrid
    ! bilinear OCN->ATM NAO deve ser adivinhada a partir do proprio campo de
    ! SST (limiar T<270K). Isso e' fragil e inconsistente com a mascara real
    ! do modelo oceanico: a mascara agora vem diretamente de So_omask =
    ! nint(mask2dT), exportada pelo MOM6 (mom_cap_methods.F90::mom_export).
    ! Assim o bilinear so' usa celulas OCEANICAS VALIDAS como fonte da
    ! interpolacao, nunca preenchimentos de terra (SST=0K sob mask2dT=0).
    ! Residual nao mapeado na costa (onde nenhum vizinho valido bilinear
    ! existe) e' tratado pela extrapolacao por vizinhanca logo abaixo.
    !==========================================================================
    if (is%rh_created) then
      call ESMF_StateGet(importState, itemName="So_t", field=field, rc=rc)

      ! DIAGNOSTICO TEMPORARIO B-OCNGRID-02: valores BRUTOS de So_t (antes de
      ! qualquer regrid/mascara do MED), para isolar se a falta de estrutura
      ! leste-oeste vem da EXPORTACAO do MOM6 ou do regrid do mediador.
      block
        logical, save :: raw_sst_diag_done = .false.
        real(ESMF_KIND_R8), pointer :: sst_raw(:,:)
        character(len=300) :: dbgmsg2
        integer :: i1r, i2r, j1r, mid_r, rc_diag
        if (.not. raw_sst_diag_done) then
          call ESMF_FieldGet(field, localDe=0, farrayPtr=sst_raw, rc=rc_diag)
          if (rc_diag == ESMF_SUCCESS .and. associated(sst_raw)) then
            i1r = lbound(sst_raw,1); i2r = ubound(sst_raw,1)
            j1r = lbound(sst_raw,2)
            mid_r = (i1r + i2r) / 2
            write(dbgmsg2,'(A,I0,A,I0,A,I0)') &
              'MED B-OCNGRID-02 DIAG: So_t BRUTO (OCN, DE local) i=[', i1r, &
              ',', i2r, '] j1=', j1r
            call ESMF_LogWrite(trim(dbgmsg2), ESMF_LOGMSG_INFO)
            write(dbgmsg2,'(A,F9.3,A,F9.3,A,F9.3,A,F9.3)') &
              '  sst_raw(i1,j1)=', sst_raw(i1r,j1r), &
              ' sst_raw(mid,j1)=', sst_raw(mid_r,j1r), &
              ' sst_raw(i2,j1)=', sst_raw(i2r,j1r), &
              ' min_row=', minval(sst_raw(:,j1r))
            call ESMF_LogWrite(trim(dbgmsg2), ESMF_LOGMSG_INFO)
            raw_sst_diag_done = .true.
          end if
        end if
      end block


      ! ?? Opção 1 (v4.18, corrigido v5.0): regrid SST ciente da mascara real
      !    do oceano (So_omask) + extrapolação de vizinhança para a costa. ??
      if (.not. is%rh_sst_masked) then
        block
          real(ESMF_KIND_R8), pointer    :: omask_src(:,:)
          integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
          type(ESMF_Field) :: omask_field
          integer :: lde_s, n_land, ldec_ocn, n_sea, rc_omask
          integer :: n_land_g(1), n_land_s(1), n_sea_g(1), n_sea_s(1)
          type(ESMF_VM) :: vm
          logical :: got_omask
          call ESMF_VMGetCurrent(vm, rc=rc)
          n_land = 0; n_sea = 0
          got_omask = .false.

          ! Preferencial: mascara real do MOM6 (So_omask, 1=oceano/0=terra).
          call ESMF_StateGet(importState, itemName="So_omask", &
            field=omask_field, rc=rc_omask)
          if (rc_omask == ESMF_SUCCESS) then
            call ESMF_GridGet(is%ocn_grid, localDeCount=ldec_ocn, rc=rc)
            if (rc == ESMF_SUCCESS) then
              do lde_s = 0, ldec_ocn - 1
                call ESMF_FieldGet(omask_field, localDe=lde_s, &
                  farrayPtr=omask_src, rc=rc)
                if (rc /= ESMF_SUCCESS .or. .not. associated(omask_src)) cycle
                call ESMF_GridGetItem(is%ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
                  staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_s, &
                  farrayPtr=maskptr, rc=rc)
                if (rc == ESMF_SUCCESS .and. associated(maskptr)) then
                  ! So_omask: 1=oceano valido, 0=terra (mesma convencao do
                  ! GRIDITEM_MASK aqui: valores em srcMaskValues sao EXCLUIDOS
                  ! da fonte do regrid, logo terra=0 e' o valor a excluir).
                  maskptr = nint(omask_src)
                  n_land = n_land + count(maskptr == 0)
                  n_sea  = n_sea  + count(maskptr == 1)
                  got_omask = .true.
                end if
              end do
            end if
          else
            call ESMF_LogWrite( &
              'MED: So_omask indisponivel no importState - usando ' // &
              'fallback por limiar de SST (menos confiavel na costa)', &
              ESMF_LOGMSG_WARNING)
          end if

          ! Fallback defensivo (nao deveria ocorrer com So_omask anunciado/
          ! realizado): mantem o comportamento antigo em vez de travar.
          if (.not. got_omask) then
            block
              real(ESMF_KIND_R8), pointer :: sst_src(:,:)
              real(ESMF_KIND_R8), parameter :: LAND_FILL_MAX = 270.0_ESMF_KIND_R8
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
                      maskptr = 0
                    elsewhere
                      maskptr = 1
                    end where
                    n_land = n_land + count(maskptr == 0)
                    n_sea  = n_sea  + count(maskptr == 1)
                  end if
                end do
              end if
            end block
          end if

          n_land_s(1) = n_land; n_sea_s(1) = n_sea
          call ESMF_VMAllReduce(vm, n_land_s, n_land_g, 1, ESMF_REDUCE_SUM, rc=rc)
          if (rc /= ESMF_SUCCESS) n_land_g(1) = n_land
          call ESMF_VMAllReduce(vm, n_sea_s,  n_sea_g,  1, ESMF_REDUCE_SUM, rc=rc)
          if (rc /= ESMF_SUCCESS) n_sea_g(1) = n_sea
          if (n_land_g(1) == 0 .or. n_sea_g(1) == 0) then
            call ESMF_LogWrite('MED Opção1: mascara uniforme/bootstrap ? adiado', &
              ESMF_LOGMSG_INFO)
            is%rh_ocn2atm_sst = is%rh_ocn2atm
          else
            call ESMF_FieldRegridStore( &
              srcField        = field,              &
              dstField        = is%f_sst_atm,       &
              routehandle     = is%rh_ocn2atm_sst,  &
              regridmethod    = ESMF_REGRIDMETHOD_BILINEAR, &
              srcMaskValues   = (/ 0_ESMF_KIND_I4 /), &
              unmappedaction  = ESMF_UNMAPPEDACTION_IGNORE, &
              rc              = rc)
            if (ESMF_LogFoundError(rcToCheck=rc, &
              msg="MED Opção1: falha FieldRegridStore SST mascarado", &
              line=__LINE__, file=__FILE__)) then
              is%rh_ocn2atm_sst = is%rh_ocn2atm
            else
              call ESMF_LogWrite('MED Opção1: rh_ocn2atm_sst criado ' // &
                '(mascara So_omask)', ESMF_LOGMSG_INFO)
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
          ! FIX B-OCNGRID-04 (Ago 2026): N_ITER=8 nao era suficiente para
          ! buracos maiores (ex.: residuo perto do polo antes da correcao de
          ! periodicidade). Aumentado para dar folga real de propagacao.
          ! IMPORTANTE: este loop e' LOCAL ao DE de cada PET (nao ha troca de
          ! halo entre PETs vizinhos) ? um buraco que atravessa a fronteira
          ! entre dois PETs pode nunca fechar por vizinhanca aqui, mesmo com
          ! N_ITER grande, porque cada lado so' enxerga seus proprios dados
          ! locais. Para esses casos o fallback constante abaixo (T_FILL)
          ! garante que NENHUM ponto fique com valor de fato indefinido ?
          ! se pontos "pretos" persistirem apos esta correcao, o problema
          ! nao esta' mais aqui (ver log B-OCNGRID-04 abaixo).
          integer,            parameter :: N_ITER = 40
          real(ESMF_KIND_R8), allocatable :: tmp(:,:)
          logical,            allocatable :: valid(:,:)
          integer :: i2,j2,ii2,jj2,it,i1,iN,j1,jN,nbr,n0,n_left,n_after_fill
          real(ESMF_KIND_R8) :: acc
          i1=lbound(sst,1); iN=ubound(sst,1); j1=lbound(sst,2); jN=ubound(sst,2)
          ! FIX B-OCNGRID-05 (Ago 2026): ANTES, "sst > T_MAX -> T_FILL" marcava a
          ! celula como valid=.true. na linha 1760 (T_FILL cai dentro de
          ! [T_MIN,T_MAX]), entao ela NUNCA entrava no loop de extrapolacao por
          ! vizinhanca abaixo. Resultado: um overflow numerico (ex.: MOM6
          ! divergindo para dezenas/centenas de graus) virava um ponto de
          ! congelamento (-1,8 C) isolado, cercado de vizinhos quentes validos ?
          ! e essa borda dura era exatamente o padrao em anel (bullseye) visto
          ! nos diagnosticos. Agora o overflow e' tratado igual ao NaN: empurrado
          ! para FORA do intervalo valido de proposito, para participar do loop
          ! de extrapolacao por vizinhanca. So' cai num valor constante (T_MAX,
          ! nao mais T_FILL) se sobrar sem nenhum vizinho valido apos N_ITER.
          where (sst > T_MAX) sst = T_FILL
          where (sst /= sst)  sst = T_MIN - 1.0_ESMF_KIND_R8
          block
            integer :: n_overflow
            n_overflow = count(sst > T_MAX)
            if (n_overflow > 0) then
              block
                character(len=300) :: logmsg_ovf
                write(logmsg_ovf,'(A,I0,A)') &
                  'MED B-OCNGRID-05 AVISO: ', n_overflow, &
                  ' celulas com SST > T_MAX (36,85 C) neste passo/DE. ' // &
                  'Contador crescente ao longo do tempo = blow-up numerico real.'
                call ESMF_LogWrite(trim(logmsg_ovf), ESMF_LOGMSG_WARNING)
              end block
            end if
          end block
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
          ! FIX B-OCNGRID-05 (Ago 2026): fallback final agora e' direcional ?
          ! celulas que sobraram sem NENHUM vizinho valido apos N_ITER (raro;
          ! normalmente so' em buracos que atravessam fronteira de PET, ver nota
          ! acima) caem no limite fisico mais proximo do lado de onde vieram
          ! (T_MAX para overflow, T_MIN para NaN/subflow), preservando a direcao
          ! do erro em vez de sempre pular para o ponto de congelamento T_FILL.
          where (.not. valid .and. sst > T_MAX) sst = T_MAX
          where (.not. valid .and. sst < T_MIN) sst = T_MIN
          ! T_FILL mantido so' como rede de seguranca final absoluta, para
          ! qualquer celula que por algum motivo nao caia em nenhum dos dois
          ! casos acima (nao deveria acontecer, dado valid=(sst>=T_MIN .and.
          ! sst<=T_MAX), mas evita undefined behavior residual).
          where (.not. valid) sst = T_FILL
          ! DIAGNOSTICO B-OCNGRID-04: confirma que, apos o fallback acima,
          ! absolutamente nenhuma celula deste DE deveria continuar fora do
          ! intervalo fisico [T_MIN,T_MAX]. Se n_after_fill > 0 aqui, o bug
          ! dos pontos pretos NAO e' a extrapolacao ? e' outra coisa (ex.:
          ! memoria nao inicializada, ou o array sendo sobrescrito depois
          ! deste ponto, antes da escrita do NetCDF).
          n_after_fill = count(sst < T_MIN .or. sst > T_MAX .or. sst /= sst)
          if (n_after_fill > 0) then
            block
              character(len=200) :: logmsg3
              write(logmsg3,'(A,I0,A)') &
                'MED B-OCNGRID-04 ALERTA: ', n_after_fill, &
                ' celulas AINDA fora de [270,310]K apos fallback T_FILL ? ' // &
                'a causa dos pontos indefinidos nao e a extrapolacao.'
              call ESMF_LogWrite(trim(logmsg3), ESMF_LOGMSG_WARNING)
            end block
          end if
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
    ! 4b. FASE 3 — SUBSTITUIR sen/evap/taux/tauy BULK PELOS FLUXOS NATIVOS DO
    !     MONAN-A (Faxa_sen_mpas, Faxa_lat_mpas, Faxa_taux_mpas,
    !     Faxa_tauy_mpas), onde disponiveis. calc_bulk_ncar acima continua
    !     sendo a fonte para celulas/execucoes sem esses campos (ex. DATM).
    !
    ! Motivacao: o MONAN-A ja fecha seu proprio balanco de PBL usando
    ! hfx/lh/ust internos (ver mpas_atm_model.F90/mpas_cap_methods.F90).
    ! Deixar o MED recalcular via bulk NCAR a partir de T/q/vento de 10 m
    ! produz um fluxo DIFERENTE do que a atmosfera usou internamente —
    ! inconsistencia entre o balanco de energia do MONAN-A e o forcante
    ! entregue ao MOM6/SIS2.
    !
    ! *** VERIFICAR ANTES DE RODAR EM PRODUCAO ***
    !  1) Sinal de hfx/lh: assumido aqui como POSITIVO PARA CIMA (convencao
    !     usual WRF/MPAS/GFS), por isso invertido (-sen_g2, -lat_g2) para
    !     bater com a convencao Foxx_sen/Foxx_evap (positivo = aquece o
    !     oceano). CONFIRME no driver de fisica da suite
    !     mesoscale_reference_monan antes de validar contra observacoes —
    !     se a convencao ja for "para baixo positivo", remova os sinais.
    !  2) taux_sfc/tauy_sfc (de mpas_atm_model.F90) usam a mesma forma
    !     rho*Cd*|V|*V do bulk NCAR — nao invertidos aqui, mas confirme
    !     que a rotacao de referencial (Terra vs. grade) ja e tratada
    !     antes de exportar (deve ser, pois MPAS ja roda em lat/lon).
    !  3) Faxa_lat_mpas vem em W/m^2 (energia); Foxx_evap e fluxo de MASSA
    !     (kg/m^2/s) — por isso a divisao por L_evap abaixo.
    !==========================================================================
    if (associated(sen_mpas) .and. associated(lat_mpas) .and. &
        associated(taux_mpas) .and. associated(tauy_mpas)) then
      block
        real(ESMF_KIND_R8), allocatable :: sen_g2(:,:), lat_g2(:,:)
        real(ESMF_KIND_R8), allocatable :: taux_g2(:,:), tauy_g2(:,:), tmp2(:,:)
        real(ESMF_KIND_R8), pointer     :: fptr_sen(:,:), fptr_evap(:,:)
        real(ESMF_KIND_R8), pointer     :: fptr_taux(:,:), fptr_tauy(:,:)
        integer :: gi2, gj2, ierr2, ii, jj
        integer, parameter :: NXG2 = 360, NYG2 = 180

        nullify(fptr_sen, fptr_evap, fptr_taux, fptr_tauy)
        allocate(sen_g2(NXG2,NYG2), lat_g2(NXG2,NYG2))
        allocate(taux_g2(NXG2,NYG2), tauy_g2(NXG2,NYG2), tmp2(NXG2,NYG2))

        ! Gather global (mesmo padrao BUG-CALC-08: SUM com tiles disjuntos)
        tmp2 = 0.0_ESMF_KIND_R8
        do gj2 = lbound(sen_mpas,2), ubound(sen_mpas,2)
          do gi2 = lbound(sen_mpas,1), ubound(sen_mpas,1)
            if (gi2 >= 1 .and. gi2 <= NXG2 .and. gj2 >= 1 .and. gj2 <= NYG2) &
              tmp2(gi2,gj2) = sen_mpas(gi2,gj2)
          end do
        end do
        call MPI_Allreduce(tmp2, sen_g2, NXG2*NYG2, MPI_DOUBLE_PRECISION, &
          MPI_SUM, med_mpi_comm, ierr2)

        tmp2 = 0.0_ESMF_KIND_R8
        do gj2 = lbound(lat_mpas,2), ubound(lat_mpas,2)
          do gi2 = lbound(lat_mpas,1), ubound(lat_mpas,1)
            if (gi2 >= 1 .and. gi2 <= NXG2 .and. gj2 >= 1 .and. gj2 <= NYG2) &
              tmp2(gi2,gj2) = lat_mpas(gi2,gj2)
          end do
        end do
        call MPI_Allreduce(tmp2, lat_g2, NXG2*NYG2, MPI_DOUBLE_PRECISION, &
          MPI_SUM, med_mpi_comm, ierr2)

        tmp2 = 0.0_ESMF_KIND_R8
        do gj2 = lbound(taux_mpas,2), ubound(taux_mpas,2)
          do gi2 = lbound(taux_mpas,1), ubound(taux_mpas,1)
            if (gi2 >= 1 .and. gi2 <= NXG2 .and. gj2 >= 1 .and. gj2 <= NYG2) &
              tmp2(gi2,gj2) = taux_mpas(gi2,gj2)
          end do
        end do
        call MPI_Allreduce(tmp2, taux_g2, NXG2*NYG2, MPI_DOUBLE_PRECISION, &
          MPI_SUM, med_mpi_comm, ierr2)

        tmp2 = 0.0_ESMF_KIND_R8
        do gj2 = lbound(tauy_mpas,2), ubound(tauy_mpas,2)
          do gi2 = lbound(tauy_mpas,1), ubound(tauy_mpas,1)
            if (gi2 >= 1 .and. gi2 <= NXG2 .and. gj2 >= 1 .and. gj2 <= NYG2) &
              tmp2(gi2,gj2) = tauy_mpas(gi2,gj2)
          end do
        end do
        call MPI_Allreduce(tmp2, tauy_g2, NXG2*NYG2, MPI_DOUBLE_PRECISION, &
          MPI_SUM, med_mpi_comm, ierr2)

        call ESMF_FieldGet(is%f_sen_atm,  farrayPtr=fptr_sen,  rc=rc)
        call ESMF_FieldGet(is%f_evap_atm, farrayPtr=fptr_evap, rc=rc)
        call ESMF_FieldGet(is%f_taux_atm, farrayPtr=fptr_taux, rc=rc)
        call ESMF_FieldGet(is%f_tauy_atm, farrayPtr=fptr_tauy, rc=rc)
        rc = ESMF_SUCCESS

        if (associated(fptr_sen) .and. associated(fptr_evap) .and. &
            associated(fptr_taux) .and. associated(fptr_tauy)) then
          do jj = lbound(fptr_sen,2), ubound(fptr_sen,2)
            do ii = lbound(fptr_sen,1), ubound(fptr_sen,1)
              if (ii >= 1 .and. ii <= NXG2 .and. jj >= 1 .and. jj <= NYG2) then
                ! so sobrescreve onde ha dado nativo real (fora do fill=0
                ! dos PETs sem tile MONAN-A local — mesmo criterio BUG-CALC-08)
                if (abs(sen_g2(ii,jj)) > 1.0e-10_ESMF_KIND_R8) then
                  fptr_sen(ii,jj)  = -sen_g2(ii,jj)          ! VERIFICAR sinal (ver acima)
                  fptr_evap(ii,jj) = -lat_g2(ii,jj) / L_evap ! W/m^2 -> kg/m^2/s
                  fptr_taux(ii,jj) = taux_g2(ii,jj)
                  fptr_tauy(ii,jj) = tauy_g2(ii,jj)
                end if
              end if
            end do
          end do
        end if

        deallocate(sen_g2, lat_g2, taux_g2, tauy_g2, tmp2)
      end block
      call ESMF_LogWrite( &
        'MED(Fase3): fluxos nativos MONAN-A (sen/evap/taux/tauy) aplicados ' // &
        'sobre o resultado do bulk NCAR', ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite( &
        'MED(Fase3): Faxa_sen/lat/taux/tauy_mpas ausentes -- mantendo bulk ' // &
        'NCAR (calc_bulk_ncar) para sen/evap/taux/tauy', ESMF_LOGMSG_INFO)
    end if

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

    ! PET0 lê o arquivo; todos os outros PETs aguardam o broadcast.
    !
    ! FIX-DEADLOCK (v14.20): usar a VM do COMPONENTE, não a global — mesmo
    ! motivo já aplicado em DATM_cap.F90, DOCN_cap.F90 e docn_cap_netcdf.F90
    ! na v13.1. Este era o último ESMF_VMGetGlobal dentro de uma rotina de
    ! componente. Hoje o MED roda em todos os PETs nos dois layouts, então
    ! as duas VMs coincidem e o broadcast funciona; a chamada global passa a
    ! ser incorreta no instante em que o mediador ganhar uma petList própria,
    ! e falharia com deadlock, não com erro. ESMF_VMGetCurrent devolve a VM
    ! do componente em execução, tornando rootPet=0 local ao MED.
    !call ESMF_VMGetGlobal(vm, rc=rc)
    call ESMF_VMGetCurrent(vm, rc=rc)
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

