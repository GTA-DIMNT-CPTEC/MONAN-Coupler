!> @file MED_cap.F90
!! @brief Mediador NUOPC do acoplamento atmosfera-oceano-gelo do MONAN.
!!
!! Ciclo de vida NUOPC do mediador (SetServices, Initialize*, MediatorAdvance).
!! As partes especializadas ficam em módulos próprios:
!!   med_cap_types.F90    tipos, listas de campos e constantes
!!   med_bulk_ncar.F90    fluxos turbulentos por fórmulas bulk NCAR
!!   med_cap_methods.F90  utilitários ESMF (campos internos, regrid, roteamento)
!!   med_cap_netcdf.F90   diagnóstico NetCDF dos campos importados
!!
!! A fonte atmosférica (MPAS ou DATM) e a rota OCN -> ATM (pelo mediador ou
!! direta) vêm de nuopc.input (coupler_config_mod). O histórico de correções
!! está em docs/CHANGELOG.md.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module MED_cap_MONAN_mod
  use ESMF
  use coupler_constants_mod, only : ATM_NX, ATM_NY, SI_IFRAC_DECAY
  use ESMF, only: ESMF_State, ESMF_StateGet
  use mpi
  use diag_bitsum_mod, only: diag_bitsum_log
  use regrid_base_mod,     only: regrid_fill_t, neighbor_fill
  use regrid_manager_mod,  only: regrid_spec
  use coupler_utils_mod, only: ChkErr
  use netcdf
  use mom6_supergrid_mod, only : mom6_supergrid_dims, mom6_supergrid_tcoords, &
                                 mom6_supergrid_corners
  use coupler_config_mod, only: cfg_docn_nx, cfg_docn_ny,         &
                                  cfg_use_docn_ice,                 &
                                  cfg_write_fixdiag,                &
                                  cfg_docn_ice_init_only,           &
                                  cfg_docn_ice_file,                &
                                  cfg_docn_ice_varname,             &
                                  cfg_docn_ice_pct,                 &
                                  cfg_docn_dt_data,                 &
                                  cfg_docn_epoch_year,              &
                                  cfg_docn_epoch_month,             &
                                  cfg_docn_epoch_day,               &  ! Alternativa 1 +.1.1
                                  cfg_use_docn, cfg_mom6_mesh_ocn,  &
                                  cfg_use_datm, cfg_use_med_to_mpas, &
                                  cfg_use_sis2_dynamic,             & ! FIX SIS2-ATIVACAO
                                  cfg_coupling_mode,                &
                                  cfg_seq_repro                       ! seq_repro (reprodutibilidade)
  use NUOPC, only: NUOPC_CompDerive, NUOPC_CompSpecialize, NUOPC_CompSetEntryPoint
  use NUOPC, only: NUOPC_CompFilterPhaseMap, NUOPC_Advertise, NUOPC_Realize
  use NUOPC, only: NUOPC_SetTimestamp, NUOPC_CompAttributeSet
  use NUOPC, only: NUOPC_IsAtTime
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
                                  RegridOrCopy, RouteOcnToAtm
  use med_cap_netcdf_mod,  only: med_read_import_config, med_write_import_fields

  implicit none
  private
  public :: SetServices

  ! ── Variáveis de estado de módulo —.1.1 ───────────────────────────
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



contains

  !============================================================================
  ! SetServices
  !============================================================================
  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    rc = ESMF_SUCCESS

    call NUOPC_CompDerive(gcomp, med_routine_SS, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      userRoutine=InitializeP0, phase=0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv03p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_DataInitialize, &
      specRoutine=InitializeDataComplete, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_Advance, &
      specRoutine=MediatorAdvance, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=med_label_CheckImport, &
      specRoutine=CheckImportNoop, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

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
    if (ChkErr(rc, __LINE__, __FILE__)) return
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
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is

    rc = ESMF_SUCCESS

    allocate(iswrap%wrap)
    is => iswrap%wrap
    is%use_mpas_atm    = .not. cfg_use_datm
    is%use_med_to_mpas = cfg_use_med_to_mpas

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    if (is%use_mpas_atm) then
      call ESMF_LogWrite('MED: fonte atmosferica = MPAS', ESMF_LOGMSG_INFO)
    else
      call ESMF_LogWrite('MED: fonte atmosferica = DATM', ESMF_LOGMSG_INFO)
    end if
    if (is%use_med_to_mpas) &
      call ESMF_LogWrite('MED: use_med_to_mpas=true, RouteOcnToAtm ativo', ESMF_LOGMSG_INFO)

    ! Anuncia campos de import conforme a fonte atmosferica configurada.
    ! CRITICO: o NUOPC aborta em IPDv03p6 se um campo anunciado nao tiver
    ! conector ativo. Por isso MPAS e DATM sao anunciados exclusivamente.
    if (is%use_mpas_atm) then
      ! Modo MPAS: anuncia campos _mpas (fornecidos pelo MPAS_cap)
      do n = 1, n_import_mpas
        call NUOPC_Advertise(importState, StandardName=trim(import_mpas_names(n)), &
          TransferOfferGeomObject="cannot provide", &
          SharePolicyField="share", rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
      end do
    else
      ! Modo DATM: anuncia campos sem sufixo (fornecidos pelo DATM_cap)
      ! SharePolicyField="share" evita bondLevel ambiguo para Faxa_rain/snow
      ! que aparecem tanto no importState quanto no exportState do MED.
      do n = 1, n_import_datm
        call NUOPC_Advertise(importState, StandardName=trim(import_datm_names(n)), &
          TransferOfferGeomObject="cannot provide", &
          SharePolicyField="share", rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
      end do
    end if

    ! Advertise So_t (SST do OCN) - sempre presente (conector OCN->MED ativo nos dois modos)
    call NUOPC_Advertise(importState, StandardName="So_t", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! v13.0): anuncia So_u e So_v no importState do MED.
    ! O NUOPC só conecta campos mutuamente anunciados: o OCN exporta So_u/So_v
    ! mas o MED não os anunciava → o NUOPC descartava esses campos e o
    ! ESMF_StateGet subsequente gerava "ERROR: Not found" no log a cada passo.
    ! Com o anúncio, o conector OCN→MED cria RouteHandle para So_u e So_v,
    ! que chegam prontos ao MED para o cálculo de duu10n = |(V_atm − V_ocn)|².
    call NUOPC_Advertise(importState, StandardName="So_u", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call NUOPC_Advertise(importState, StandardName="So_v", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! anuncia So_omask no importState do MED.
    ! O OCN (mom_cap_methods.F90::mom_export) ja exporta 'So_omask' = nint(mask2dT)
    ! (1=oceano, 0=terra), mas o MED nunca anunciava esse campo -> o NUOPC
    ! descartava o conector e o MED era forcado a "adivinhar" a mascara terra/
    ! oceano a partir do proprio valor de SST (limiar SST<270K), o que e
    ! inconsistente com a mascara real do MOM6 e contamina a interpolacao
    ! bilinear da costa com valores de celulas de terra fisicamente irreais.
    call NUOPC_Advertise(importState, StandardName="So_omask", &
      TransferOfferGeomObject="cannot provide", &
      SharePolicyField="share", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

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
      if (ChkErr(rc, __LINE__, __FILE__)) return

      ! albedo do gelo por banda. Mesmo padrão
      ! de Si_ifrac_sis2 acima (nome próprio para não colidir com um
      ! eventual conector automático; mesma política de share).
      call NUOPC_Advertise(importState, StandardName="Si_avsdr_sis2", &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Advertise(importState, StandardName="Si_avsdf_sis2", &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Advertise(importState, StandardName="Si_anidr_sis2", &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Advertise(importState, StandardName="Si_anidf_sis2", &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      ! temperatura de pele real do gelo.
      call NUOPC_Advertise(importState, StandardName="Si_t_sis2", &
        TransferOfferGeomObject="cannot provide", &
        SharePolicyField="share", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if

    ! Advertise campos de export para o OCN
    do n = 1, n_export
      call NUOPC_Advertise(exportState, StandardName=trim(export_names(n)), &
        TransferOfferGeomObject="will provide", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
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
    type(ESMF_VM)    :: vm
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: nx_atm, ny_atm, nx_ocn, ny_ocn
    integer :: petCount
    character(len=256)  :: msg_tmp
      type(ESMF_VM) :: med_vm

    rc = ESMF_SUCCESS

    ! Recuperar estado interno
    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap


    ! obter petCount para calcular regDecomp de ambas as grades.
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
    nx_atm = ATM_NX
    ny_atm = ATM_NY
    ! cfg_docn_nx/ny (1440x720) sao a grade do
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
      call mom6_supergrid_dims(trim(cfg_mom6_mesh_ocn), nx_ocn, ny_ocn, rc, tag='MED B-OCNGRID-01')
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
    ! ): regDecomp 2D universal — sem DE de largura 1 e sem PETs vazios.
    ! ATM 640x320: nx_max=320, ny=ceil(N/320)
    !   N=128: ny=1 → regDecomp=(/128,1/) → 640/128=5 col ✓
    !   N=512: ny=2 → regDecomp=(/320,2/) → 640 DEs>512, 640/320=2 col, 320/2=160 lin ✓
    !
    ! -------------------------------------------------------------------------
    ! ): a fórmula gera totalDEs = nx_max*ny_tiles
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
    call create_atm_grid(petCount, nx_atm, ny_atm, atm_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    !--------------------------------------------------------------------------
    !--- Criar grade OCN com dimensões de nuopc.input (cfg_docn_nx x cfg_docn_ny) ---
    !--------------------------------------------------------------------------
    ! ): regDecomp 2D universal para grade OCN.
    ! largura 1 para qualquer petCount. Grade alinhada com DOCN_cap (OISST 0.25°)
    ! → conector DOCN→MED usa redistribuição (zero-copy) em vez de bilinear.
    !   N=512: ny=4 → regDecomp=(/128,4/) → 512 DEs=512 PETs, 2 col, 39 lin ✓
    !
    ! ): mesma fatoração exata da grade ATM. Garante
    ! totalDEs = petCount (1 DE por PET), evitando DEs órfãos. Respeita
    ! ncol<=nx_ocn/2 e nrow<=ny_ocn.
    call create_ocn_grid(petCount, nx_ocn, ny_ocn, ocn_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    !--------------------------------------------------------------------------
    ! Realizar campos de import conforme a fonte atmosferica configurada.
    ! Espelha exatamente o que foi anunciado em InitializeAdvertise.
    !--------------------------------------------------------------------------
    call realize_component_fields(is, importState, exportState, atm_grid, ocn_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    !--------------------------------------------------------------------------
    ! Atualizar estado interno com grades criadas nesta fase.
    ! NAO re-alocar iswrap%wrap: ja alocado em InitializeAdvertise.
    !--------------------------------------------------------------------------
    is%atm_grid   = atm_grid
    is%ocn_grid   = ocn_grid
    ! use_mpas_atm ja lido logo apos GetInternalState (ver acima).
    ! Nao sobrescrever com .false. aqui.


    ! Criar campos internos na grade ATM
    call create_internal_fields(is, atm_grid, rc)

    call ESMF_GridCompSetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! v4: ler config de diagnóstico de importação
    call med_read_import_config()

    ! salvar informação MPI do mediador para uso em med_write_import_fields
    !
    ! (modo concurrent, v13.0): NÃO cair para MPI_COMM_WORLD em
    ! caso de erro. med_mpi_comm alimenta os MPI_Allreduce coletivos de
    ! med_write_import_fields. No modo concurrent o MED tem seu próprio
    ! comunicador de componente; substituí-lo silenciosamente por
    ! MPI_COMM_WORLD (todos os ranks) num coletivo sobre o comunicador do
    ! componente causaria mismatch / deadlock. Falhar cedo é o correto —
    ! um erro de VM é excepcional e deve abortar, não ser mascarado.
      call ESMF_VMGetCurrent(med_vm, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='MED: falha ESMF_VMGetCurrent em InitializeRealize', &
        line=__LINE__, file=__FILE__)) return
      call ESMF_VMGet(med_vm, localPet=med_local_pet, petCount=med_pet_count, &
        mpiCommunicator=med_mpi_comm, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg='MED: falha ESMF_VMGet mpiCommunicator em InitializeRealize', &
        line=__LINE__, file=__FILE__)) return


    call ESMF_LogWrite('MED: InitializeRealize concluido', ESMF_LOGMSG_INFO)
  end subroutine InitializeRealize

  !> Decomposição regular (colunas x linhas) de uma grade nx x ny em petCount
  !! DEs, um por PET: linhas = o maior divisor de petCount que não passe de
  !! sqrt(petCount) nem de ny, com colunas <= nx/2 (cada DE com pelo menos 2
  !! colunas); colunas = petCount / linhas. Garante colunas x linhas = petCount.
  function grid_regdecomp(petCount, nx, ny) result(regDecomp)
    integer, intent(in) :: petCount, nx, ny
    integer :: regDecomp(2)
    integer :: nrows, n

    nrows = 1
    do n = max(1, int(sqrt(real(petCount)))), 1, -1
      if (mod(petCount, n) == 0 .and. n <= ny .and. (petCount / n) <= nx / 2) then
        nrows = n
        exit
      end if
    end do
    regDecomp(1) = petCount / nrows   ! colunas (lon)
    regDecomp(2) = nrows              ! linhas (lat)
  end function grid_regdecomp

  subroutine create_atm_grid(petCount, nx_atm, ny_atm, atm_grid, rc)
    integer, intent(in) :: petCount
    integer, intent(in) :: nx_atm
    integer, intent(in) :: ny_atm
    type(ESMF_Grid), intent(inout) :: atm_grid
    integer, intent(inout) :: rc
    integer :: regDecomp(2)
    real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)
    integer :: i
    integer :: j
    integer :: lde
    integer :: localDeCount_atm
    nullify(coordX, coordY)
    regDecomp = grid_regdecomp(petCount, nx_atm, ny_atm)
    ! Invariante: regDecomp(1)*regDecomp(2) == petCount (1 DE por PET).
    ! ESMF_INDEX_GLOBAL: necessário para mapeamento global em med_write_import_fields.
    ! Loops bulk usam lbound/ubound - agnósticos ao indexflag do MPAS.
    ! REVERT a tentativa de fixar polekindflag=MONOPOLE
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
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! verificar localDeCount antes de ESMF_GridGetCoord (chamada LOCAL)
    call ESMF_GridGet(atm_grid, localDeCount=localDeCount_atm, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha GridGet localDeCount ATM', &
      line=__LINE__, file=__FILE__)) return

    ! ): loop sobre DEs locais — com regDecomp 2D alguns PETs têm
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

    ! stagger CORNER na grade ATM, necessario
    ! para ESMF_REGRIDMETHOD_CONSERVE em conjunto com o CORNER do ocn_grid
    ! acima. Grade ATM e' regular lat-lon -> canto sai de conta direta
    ! (borda da celula, meia-celula ANTES do centro), sem ler arquivo.
    call ESMF_GridAddCoord(atm_grid, staggerloc=ESMF_STAGGERLOC_CORNER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED B-CONSERVE-01: falha ' // &
      'GridAddCoord CORNER na grade ATM', line=__LINE__, file=__FILE__)) return

    do lde = 0, localDeCount_atm - 1
      call ESMF_GridGetCoord(atm_grid, coordDim=1, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordX, rc=rc)
      do j = lbound(coordX,2), ubound(coordX,2)
        do i = lbound(coordX,1), ubound(coordX,1)
          coordX(i,j) = (i-1) * (360.0_ESMF_KIND_R8/nx_atm)
        end do
      end do
      call ESMF_GridGetCoord(atm_grid, coordDim=2, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordY, rc=rc)
      do j = lbound(coordY,2), ubound(coordY,2)
        do i = lbound(coordY,1), ubound(coordY,1)
          coordY(i,j) = -90.0_ESMF_KIND_R8 + (j-1)*(180.0_ESMF_KIND_R8/ny_atm)
        end do
      end do
    end do  ! lde ATM (CORNER)
    call ESMF_LogWrite('MED B-CONSERVE-01: stagger CORNER da grade ATM ' // &
      'preenchido (sem erro ate aqui)', ESMF_LOGMSG_INFO)

    ! Fim normal da etapa: rc volta a indicar sucesso (um rc de falha
    ! tolerado acima não interrompe a inicialização).
    rc = ESMF_SUCCESS
  end subroutine create_atm_grid

  subroutine create_ocn_grid(petCount, nx_ocn, ny_ocn, ocn_grid, rc)
    integer, intent(in) :: petCount
    integer, intent(in) :: nx_ocn
    integer, intent(in) :: ny_ocn
    type(ESMF_Grid), intent(inout) :: ocn_grid
    integer, intent(inout) :: rc
    integer :: regDecomp(2)
    real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)
    integer :: i
    integer :: j
    integer :: lde
    integer :: lde_m
    integer :: localDeCount_ocn
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    nullify(coordX, coordY)
    regDecomp = grid_regdecomp(petCount, nx_ocn, ny_ocn)
    ! Invariante: regDecomp(1)*regDecomp(2) == petCount (1 DE por PET).
    ! ESMF_INDEX_GLOBAL: consistência com atm_grid para med_write_import_fields.
    ! a grade OCN era criada SEM dimensao
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
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! verificar localDeCount antes de ESMF_GridGetCoord (chamada LOCAL)
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
        ! MOM6 tripolar real - le as coordenadas T verdadeiras
        ! do supergrid ocean_hgrid.nc (NAO uniformes; convergem no polo Norte).
        ! Sem isso, o conector NUOPC OCN->MED interpola usando posicoes erradas
        ! e a costa fica sistematicamente deslocada em todo o dominio.
        call mom6_supergrid_tcoords(trim(cfg_mom6_mesh_ocn), coordX, coordY, rc, tag='MED B-OCNGRID-01')
        if (ESMF_LogFoundError(rcToCheck=rc, &
          msg="MED: falha ao ler coordenadas T reais de ocean_hgrid.nc " // &
              "para o DE local - grade OCN do mediador ficara incorreta", &
          line=__LINE__, file=__FILE__)) return
      end if
    end do  ! lde OCN

    ! stagger CORNER, necessario para
    ! ESMF_REGRIDMETHOD_CONSERVE (calcula peso por sobreposicao de area,
    ! exige os 4 cantos de cada celula). Aditivo ao CENTER ja existente —
    ! nao afeta nenhum RouteHandle ja criado com staggerloc=CENTER (Cd_neut,
    ! rh_ocn2atm, rh_ocn2atm_sst, rh_ocn2atm_ice, rh_atm2ocn continuam
    ! lendo exatamente os mesmos dados de CENTER de sempre).
    call ESMF_GridAddCoord(ocn_grid, staggerloc=ESMF_STAGGERLOC_CORNER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED B-CONSERVE-01: falha ' // &
      'GridAddCoord CORNER na grade OCN', line=__LINE__, file=__FILE__)) return

    do lde = 0, localDeCount_ocn - 1
      call ESMF_GridGetCoord(ocn_grid, coordDim=1, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordX, rc=rc)
      call ESMF_GridGetCoord(ocn_grid, coordDim=2, localDE=lde, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordY, rc=rc)
      if (cfg_use_docn) then
        ! DOCN/OISST: canto = centro menos meia-celula (grade regular real).
        do j = lbound(coordX,2), ubound(coordX,2)
          do i = lbound(coordX,1), ubound(coordX,1)
            coordX(i,j) = (i-1) * (360.0_ESMF_KIND_R8/nx_ocn)
          end do
        end do
        do j = lbound(coordY,2), ubound(coordY,2)
          do i = lbound(coordY,1), ubound(coordY,1)
            coordY(i,j) = -90.0_ESMF_KIND_R8 + (j-1)*(180.0_ESMF_KIND_R8/ny_ocn)
          end do
        end do
      else
        ! MOM6 tripolar real: vertices verdadeiros do supergrid ocean_hgrid.nc.
        call mom6_supergrid_corners(trim(cfg_mom6_mesh_ocn), coordX, coordY, rc, tag='MED B-CONSERVE-01')
        if (ESMF_LogFoundError(rcToCheck=rc, &
          msg="MED B-CONSERVE-01: falha ao ler cantos de ocean_hgrid.nc " // &
              "para o DE local - regrid conservativo ficara indisponivel", &
          line=__LINE__, file=__FILE__)) return
      end if
    end do  ! lde OCN (CORNER)
    call ESMF_LogWrite('MED B-CONSERVE-01: stagger CORNER da grade OCN ' // &
      'preenchido (sem erro ate aqui)', ESMF_LOGMSG_INFO)

    ! sanidade dos cantos lidos — confirma que os
    ! valores estao numa faixa fisica plausivel (lon em [0,360), lat em
    ! [-90,90]) e nao sao um bloco de zeros/garbage por leitura silenciosa
    ! mal-sucedida. Compara tambem com o CENTRO da mesma celula (i1,j1
    ! deste DE): o canto deve estar a uma fracao de celula de distancia do
    ! centro, nunca identico nem absurdamente distante.
    if (associated(coordX) .and. associated(coordY)) then
      call check_corner_coordinates(ocn_grid, localDeCount_ocn, coordX, coordY)
    end if

    ! Opção 1: item de MÁSCARA na grade OCN (terra = SST fill ≈200 K do MOM6).
    call ESMF_GridAddItem(ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
      staggerloc=ESMF_STAGGERLOC_CENTER, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg='MED: falha GridAddItem MASK OCN', &
      line=__LINE__, file=__FILE__)) return
      do lde_m = 0, localDeCount_ocn - 1
        call ESMF_GridGetItem(ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
          staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_m, &
          farrayPtr=maskptr, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(maskptr)) maskptr = 0
      end do

    ! Fim normal da etapa: rc volta a indicar sucesso (um rc de falha
    ! tolerado acima não interrompe a inicialização).
    rc = ESMF_SUCCESS
  end subroutine create_ocn_grid

  subroutine realize_component_fields(is, importState, exportState, atm_grid, ocn_grid, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Grid), intent(in) :: atm_grid
    type(ESMF_Grid), intent(in) :: ocn_grid
    integer, intent(inout) :: rc
    integer :: n
    type(ESMF_Field) :: tmp_field
    if (is%use_mpas_atm) then
      do n = 1, n_import_mpas
        tmp_field = ESMF_FieldCreate(grid=atm_grid, typekind=ESMF_TYPEKIND_R8, &
          staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(import_mpas_names(n)), rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        call NUOPC_Realize(importState, field=tmp_field, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
      end do
    else
      do n = 1, n_import_datm
        tmp_field = ESMF_FieldCreate(grid=atm_grid, typekind=ESMF_TYPEKIND_R8, &
          staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(import_datm_names(n)), rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        call NUOPC_Realize(importState, field=tmp_field, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
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
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! v13.0): realizar So_u e So_v na grade OCN.
    ! Simétrico ao tratamento de So_t: correntes vêm do OCN, portanto
    ! devem ser realizadas em ocn_grid para que o rh_ocn2atm funcione.
    tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name="So_u", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name="So_v", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! realizar So_omask (mascara real mask2dT do MOM6)
    ! na grade OCN, simetrico a So_t/So_u/So_v.
    tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name="So_omask", rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call NUOPC_Realize(importState, field=tmp_field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! FIX SIS2-ATIVACAO (Ago 2026): realizar Si_ifrac_sis2 (gelo real do
    ! ICE) na MESMA grade ocn_grid — a grade do componente ICE (ver
    ! sis_cap_MONAN.F90) foi construída com a mesma geometria (mesma
    ! ocean_hgrid.nc, mesmas dimensões, mesma periodicidade), então é
    ! geometricamente equivalente a ocn_grid para fins de realização aqui.
    if (cfg_use_sis2_dynamic) then
      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name="Si_ifrac_sis2", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(importState, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      ! mesma ocn_grid, mesmo raciocinio.
      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name="Si_avsdr_sis2", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(importState, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name="Si_avsdf_sis2", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(importState, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name="Si_anidr_sis2", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(importState, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name="Si_anidf_sis2", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(importState, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      ! mesma ocn_grid.
      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name="Si_t_sis2", rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(importState, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if

    !--------------------------------------------------------------------------
    ! Realizar campos de export na grade OCN
    !--------------------------------------------------------------------------
    do n = 1, n_export
      tmp_field = ESMF_FieldCreate(grid=ocn_grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(export_names(n)), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(exportState, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do

    ! Fim normal da etapa: rc volta a indicar sucesso (um rc de falha
    ! tolerado acima não interrompe a inicialização).
    rc = ESMF_SUCCESS
  end subroutine realize_component_fields

  subroutine create_internal_fields(is, atm_grid, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_Grid), intent(inout) :: atm_grid
    integer, intent(inout) :: rc
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
    ! mascara terra/oceano real na grade ATM (1=oceano,
    ! 0=terra). Default 1.0 (oceano) ate' o primeiro regrid de So_omask —
    ! seguro porque so' e' USADA para EXCLUIR terra, nao para validar
    ! oceano; ficar em "tudo oceano" ate' o regrid real e' menos arriscado
    ! do que ficar em "tudo terra" (zeraria fluxos legitimos ate' la').
    call CreateInternalField(is%f_omask_atm,  atm_grid, "med_omask",  rc)
    call FillInternalField(is%f_omask_atm, 1.0_ESMF_KIND_R8, rc)
    call CreateInternalField(is%f_duu10n_atm, atm_grid, "med_duu10n", rc)
    ! f_sst_atm: campo de SST interpolado para a grade ATM (destino do OCN->ATM)
    call CreateInternalField(is%f_sst_atm,    atm_grid, "med_sst",    rc)
    ! v13.0): correntes oceânicas interpoladas OCN → ATM.
    ! Usadas no cálculo de So_duu10n = |(V_atm − V_ocn)|² (protocolo CMEPS).
    call CreateInternalField(is%f_uocn_atm,   atm_grid, "med_uocn",   rc)
    call CreateInternalField(is%f_vocn_atm,   atm_grid, "med_vocn",   rc)
    ! rugosidade Charnock + Smith — calculada no MED e enviada ao MPAS.
    call CreateInternalField(is%f_zorl_atm,   atm_grid, "med_zorl",   rc)
    ! albedo do gelo por banda, regridado do SIS2.
    call CreateInternalField(is%f_alb_vdr_ice, atm_grid, "med_albvdr_ice", rc)
    call CreateInternalField(is%f_alb_vdf_ice, atm_grid, "med_albvdf_ice", rc)
    call CreateInternalField(is%f_alb_idr_ice, atm_grid, "med_albidr_ice", rc)
    call CreateInternalField(is%f_alb_idf_ice, atm_grid, "med_albidf_ice", rc)
    call CreateInternalField(is%f_coszen_atm,  atm_grid, "med_coszen",     rc)
    call CreateInternalField(is%f_albedo_atm,  atm_grid, "med_albedo",     rc)
    ! Fase 3
    call CreateInternalField(is%f_tice_atm,    atm_grid, "med_tice",       rc)
    ! Fase 4b
    call CreateInternalField(is%f_tsfc_atm,    atm_grid, "med_tsfc_comp",  rc)
    call CreateInternalField(is%f_taux_ice,    atm_grid, "med_taux_ice",   rc)
    call CreateInternalField(is%f_tauy_ice,    atm_grid, "med_tauy_ice",   rc)
    call CreateInternalField(is%f_sen_ice,     atm_grid, "med_sen_ice",    rc)
    call CreateInternalField(is%f_evap_ice,    atm_grid, "med_evap_ice",   rc)
    call CreateInternalField(is%f_lwnet_ice,   atm_grid, "med_lwnet_ice",  rc)
    ! Fase 4
    call CreateInternalField(is%f_swvdr_ice,   atm_grid, "med_swvdr_ice",  rc)
    call CreateInternalField(is%f_swvdf_ice,   atm_grid, "med_swvdf_ice",  rc)
    call CreateInternalField(is%f_swidr_ice,   atm_grid, "med_swidr_ice",  rc)
    call CreateInternalField(is%f_swidf_ice,   atm_grid, "med_swidf_ice",  rc)

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
    ! fallback nao-zero (mesmo valor de ALBEDO_ICE_FALLBACK em
    ! sis_cap_MONAN.F90) ate o primeiro regrid real via rh_ice2atm — evita
    ! um albedo de gelo erroneamente zero (que superestimaria absorcao de
    ! SW) no bootstrap, mesma logica de SST_BULK_FALLBACK abaixo.
    call FillInternalField(is%f_alb_vdr_ice, 0.65_ESMF_KIND_R8, rc)
    call FillInternalField(is%f_alb_vdf_ice, 0.65_ESMF_KIND_R8, rc)
    call FillInternalField(is%f_alb_idr_ice, 0.65_ESMF_KIND_R8, rc)
    call FillInternalField(is%f_alb_idf_ice, 0.65_ESMF_KIND_R8, rc)
    call ZeroInternalField(is%f_coszen_atm, rc)
    call FillInternalField(is%f_albedo_atm, 0.08_ESMF_KIND_R8, rc)
    ! T_gelo default = ponto de congelamento da agua do mar; fluxos
    ! turbulentos do gelo comecam zerados ate o 1o calc_bulk_ncar real.
    call FillInternalField(is%f_tice_atm,   271.35_ESMF_KIND_R8, rc)
    call FillInternalField(is%f_tsfc_atm,   271.35_ESMF_KIND_R8, rc)
    call ZeroInternalField(is%f_taux_ice,  rc)
    call ZeroInternalField(is%f_tauy_ice,  rc)
    call ZeroInternalField(is%f_sen_ice,   rc)
    call ZeroInternalField(is%f_evap_ice,  rc)
    call ZeroInternalField(is%f_lwnet_ice, rc)
    ! comeca zerado ate o 1o calc_bulk_ncar real,
    ! mesma logica de f_sen_ice/f_lwnet_ice acima.
    call ZeroInternalField(is%f_swvdr_ice, rc)
    call ZeroInternalField(is%f_swvdf_ice, rc)
    call ZeroInternalField(is%f_swidr_ice, rc)
    call ZeroInternalField(is%f_swidf_ice, rc)
    ! Inicializa SST com valor padrao (nao zero, para evitar bulk erratico no t=0)
    call FillInternalField(is%f_sst_atm, SST_BULK_FALLBACK, rc)
    ! Valor de bootstrap: será substituído no primeiro passo pelo So_t do DOCN/MOM6.
    ! correntes oceânicas inicializadas a zero (oceano em repouso).
    ! Serão regridadas de So_u/So_v a partir do primeiro passo de acoplamento.
    call ZeroInternalField(is%f_uocn_atm, rc)
    call ZeroInternalField(is%f_vocn_atm, rc)
    ! rugosidade inicial = 0.01 m (mesmo cfg_zorl_default do cap MPAS).
    ! Substituida no primeiro passo pela parametrizacao Charnock no bulk NCAR.
    call FillInternalField(is%f_zorl_atm, 0.01_ESMF_KIND_R8, rc)
  end subroutine create_internal_fields

  subroutine check_corner_coordinates(ocn_grid, localDeCount_ocn, coordX, coordY)
    type(ESMF_Grid), intent(inout) :: ocn_grid
    integer, intent(inout) :: localDeCount_ocn
    real(ESMF_KIND_R8), pointer :: coordX(:,:)
    real(ESMF_KIND_R8), pointer :: coordY(:,:)
    character(len=250) :: diag_msg_corner
    real(ESMF_KIND_R8), pointer :: coordX_c(:,:), coordY_c(:,:)
    real(ESMF_KIND_R8) :: dlon_sample, dlat_sample
    integer :: rc_diag
    integer :: iN_c
    integer :: i_c
    integer :: jN_c
    real(ESMF_KIND_R8) :: dlon_step
    real(ESMF_KIND_R8) :: dlon_avg
    real(ESMF_KIND_R8) :: dlon_max_found
    real(ESMF_KIND_R8) :: dist_corner_min
    real(ESMF_KIND_R8) :: dist_here
    character(len=280) :: diag_msg_fold
    real(ESMF_KIND_R8) :: dlon_raw
    integer :: i_next
    dlon_sample = -999.0_ESMF_KIND_R8; dlat_sample = -999.0_ESMF_KIND_R8
    call ESMF_GridGetCoord(ocn_grid, coordDim=1, localDE=localDeCount_ocn-1, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordX_c, rc=rc_diag)
    call ESMF_GridGetCoord(ocn_grid, coordDim=2, localDE=localDeCount_ocn-1, &
      staggerloc=ESMF_STAGGERLOC_CENTER, farrayPtr=coordY_c, rc=rc_diag)
    if (rc_diag == ESMF_SUCCESS .and. associated(coordX_c) .and. associated(coordY_c)) then
      dlon_sample = coordX(lbound(coordX,1),lbound(coordX,2)) - &
                    coordX_c(lbound(coordX_c,1),lbound(coordX_c,2))
      dlat_sample = coordY(lbound(coordY,1),lbound(coordY,2)) - &
                    coordY_c(lbound(coordY_c,1),lbound(coordY_c,2))
    end if
    write(diag_msg_corner,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
      'FIX-DIAG-CONSERVE01-01: canto lon min=', minval(coordX), ' max=', maxval(coordX), &
      ' | canto lat min=', minval(coordY), ' max=', maxval(coordY), &
      ' | canto-centro (amostra) dlon=', dlon_sample, ' dlat=', dlat_sample
    call ESMF_LogWrite(trim(diag_msg_corner), ESMF_LOGMSG_INFO)

    ! checagem especifica da(s)
    ! ultima(s) linha(s) de j perto do polo (fold tripolar). So' roda
    ! neste DE se ele de fato alcancar perto do polo (maxval(coordY)
    ! > 80) -- a maioria dos PETs nao chega la' e nao tem o que checar.
    ! Dois sintomas procurados, ambos assinatura de fold mal capturado
    ! ou celula degenerada perto do polo:
    !   (a) celula quase degenerada: distancia entre cantos vizinhos
    !       (em i, na linha mais ao norte) proxima de zero -- area de
    !       celula colapsando, o que faz CONSERVE tratar aquela celula
    !       como praticamente inexistente (peso ~0), mesmo que fisicamente
    !       deva ter area finita.
    !   (b) salto de longitude entre celulas vizinhas em i, na mesma
    !       linha, muito maior que o espacamento medio do resto da
    !       grade -- indica descontinuidade de indice atraves da dobra
    !       (dado de um lado do polo aparecendo ao lado do dado do
    !       lado oposto sem a rotacao de 180 graus que o fold real exige).
    if (maxval(coordY) > 80.0_ESMF_KIND_R8) then
        iN_c = ubound(coordX,1); jN_c = ubound(coordX,2)
        dlon_avg = 0.0_ESMF_KIND_R8; dlon_max_found = 0.0_ESMF_KIND_R8
        dist_corner_min = huge(1.0_ESMF_KIND_R8)
        do i_c = lbound(coordX,1), iN_c
          ! Salto de longitude entre vizinhos em i, na linha mais ao
          ! norte (jN_c) -- usa a diferenca angular MINIMA (trata
          ! travessia de 0/360 corretamente, para nao confundir isso
          ! com um salto real de fold).
            i_next = merge(lbound(coordX,1), i_c+1, i_c == iN_c)
            dlon_raw = abs(coordX(i_next,jN_c) - coordX(i_c,jN_c))
            dlon_step = min(dlon_raw, 360.0_ESMF_KIND_R8 - dlon_raw)
            dlon_avg = dlon_avg + dlon_step
            dlon_max_found = max(dlon_max_found, dlon_step)
            ! Distancia (aprox., em graus, sem correcao de cos(lat) --
            ! suficiente para detectar colapso grosseiro de celula)
            dist_here = sqrt(dlon_step**2 + &
              (coordY(i_next,jN_c)-coordY(i_c,jN_c))**2)
            dist_corner_min = min(dist_corner_min, dist_here)
        end do
        dlon_avg = dlon_avg / real(iN_c - lbound(coordX,1) + 1, ESMF_KIND_R8)
        write(diag_msg_fold,'(A,ES10.3,A,ES10.3,A,ES10.3)') &
          'FIX-DIAG-CONSERVE02-01: linha mais ao norte deste DE -- ' // &
          'dlon medio entre vizinhos=', dlon_avg, ' dlon MAXIMO=', &
          dlon_max_found, ' | menor distancia canto-canto encontrada=', &
          dist_corner_min
        call ESMF_LogWrite(trim(diag_msg_fold), ESMF_LOGMSG_INFO)
        if (dist_corner_min < 1.0e-3_ESMF_KIND_R8) &
          call ESMF_LogWrite('FIX-DIAG-CONSERVE02-01: ALERTA -- ' // &
            'celula quase degenerada encontrada perto do polo ' // &
            '(distancia canto-canto < 1e-3 grau)', ESMF_LOGMSG_WARNING)
        if (dlon_max_found > 5.0_ESMF_KIND_R8 * max(dlon_avg, 1.0e-6_ESMF_KIND_R8)) &
          call ESMF_LogWrite('FIX-DIAG-CONSERVE02-01: ALERTA -- ' // &
            'salto de longitude muito maior que a media entre ' // &
            'vizinhos na linha mais ao norte (possivel fold mal ' // &
            'capturado ou descontinuidade de indice)', ESMF_LOGMSG_WARNING)
    end if
  end subroutine check_corner_coordinates


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
            integer :: localDeCount_exp

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap


    ! CORRECAO 2: NUOPC_MediatorGet e a API correta para mediadores
    call NUOPC_MediatorGet(gcomp, mediatorClock=clock, &
      importState=importState, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

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
  ! (v14.21): esta rotina foi dividida em duas fases porque
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
    if (.not. is%regrid%has('ocn2atm')) then

      if (.not. is%regrid%has('atm2ocn')) then
        call is%regrid%add('atm2ocn', regrid_spec('nearest_stod'), is%f_taux_atm, exp_field, rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
      end if

      ! So_t está na grade OCN (ver InitializeRealize)
      call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call is%regrid%add('ocn2atm', regrid_spec('bilinear'), ocn_field, is%f_sst_atm, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

      ! Correntes So_u/So_v: mesma grade de So_t, mesma rota.
      call regrid_ocean_currents(is, importState, zero_on_error=.true.)

      ! Inicializar exportState com valores fisicamente razoaveis
      ! ESMF_FieldGet(farrayPtr) falha em PETs sem DE local.
      ! Verificar localDeCount antes de acessar dados do campo.
      call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
      if (fieldCount > 0) then
        allocate(fieldNameList(fieldCount))
        call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
        do i = 1, fieldCount
          call ESMF_StateGet(exportState, itemName=trim(fieldNameList(i)), &
            field=exp_field, rc=rc)
            call ESMF_FieldGet(exp_field, localDeCount=localDeCount_exp, rc=localrc)
            if (localDeCount_exp == 0) cycle   ! PET sem DE local — nada a inicializar
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

      ! ──.2 (Set/2026): Si_ifrac_sis2 reutiliza rh_ocn2atm ──────────
      ! Correcao de curso: Si_ifrac_sis2 (e os 4 campos de albedo do gelo,
      ! Fase 2, mais abaixo) sao realizados pelo MED em ocn_grid — a MESMA
      ! grade de So_t (ver InitializeRealize) — logo NAO precisam de um
      ! RouteHandle proprio. rh_ocn2atm (ja criado acima) e reutilizado,
      ! exatamente como ja e feito para So_u/So_v alguns blocos acima.
      ! (Uma primeira versao desta correcao criava um "rh_ice2atm" separado,
      ! redundante — revertido ao perceber que a geometria ja e' a mesma.)

      call ESMF_LogWrite('MED: IDC fase A: rotas de interpolacao criadas', ESMF_LOGMSG_INFO)
    end if

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
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg="MED: falha So_t (gate)", &
      line=__LINE__, file=__FILE__)) return

    sst_ready = NUOPC_IsAtTime(ocn_field, startTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

  !--------------------------------------------------------------------------
  ! (v14.21): CARIMBO NAO E' DADO.
  !
  ! O mom_cap aplica NUOPC_SetTimestamp a TODOS os campos do exportState em
  ! seu InitializeDataComplete, em laco cego sobre o itemNameList, sem
  ! verificar quais deles o mom_export realmente preencheu. Um So_t
  ! identicamente nulo passa no NUOPC_IsAtTime — foi o que aconteceu enquanto
  ! ocean_model_init_sfc nao era chamado: o gate abria, o mediador seguia, e
  ! a extrapolacao da secao 3 convertia o campo inteiro em T_FILL=271.35 K,
  ! o que por sua vez fazia a mascara.5.1 classificar o planeta
  ! inteiro como terra e zerar os 11 campos de fluxo.
  !
  ! Exigir tambem VALOR fisicamente plausivel em alguma celula, contado
  ! GLOBALMENTE: um DE pode legitimamente conter so' terra e gelo.
  !--------------------------------------------------------------------------
    if (sst_ready) then
      call ESMF_VMGetCurrent(vm, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return

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
  ! v13.0): primeiro regrid de So_u e So_v para
  ! f_uocn_atm/f_vocn_atm. So_u e So_v sao anunciados e realizados no
  ! importState do MED (ocn_grid), portanto ESMF_StateGet e' seguro. O
  ! routehandle rh_ocn2atm (bilinear, ja' criado na fase A) e' reutilizado:
  ! So_u/So_v compartilham a mesma grade OCN que So_t → mapeamento identico.
  !==========================================================================
    call regrid_ocean_currents(is, importState, zero_on_error=.true.)

    ! SST de t=0 para a grade ATM. Sem isto, f_sst_atm permaneceria no valor de
    ! bootstrap SST_BULK_FALLBACK ate' o primeiro MediatorAdvance, e o
    ! conector MED -> MPAS entregaria essa constante ao MPAS na inicializacao.
    call is%regrid%apply('ocn2atm', ocn_field, is%f_sst_atm, localrc, &
          zero_total=.true.)
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
    ! instante que representa o CONTEUDO desta
    ! execucao do mediador. Ver a justificativa completa junto da atribuicao,
    ! logo apos o calculo de nextTime.
    type(ESMF_Time)          :: stampTime
    logical                  :: med_runs_before_advance
    type(ESMF_TimeInterval)  :: dt
    type(ESMF_Field)         :: field
    type(MED_InternalStateWrapper) :: iswrap
    type(MED_InternalState), pointer :: is
    integer :: localDeCount_med  ! guard para PETs sem DE local

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
    ! fluxos nativos do PBL do MONAN-A (opcionais — ausencia mantem
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
    ! v13.0): ponteiros para correntes oceânicas na grade ATM
    real(ESMF_KIND_R8), pointer :: uocn(:,:), vocn(:,:)

    real(ESMF_KIND_R8), pointer     :: shum_local(:,:) => null()
    real(ESMF_KIND_R8), pointer     :: snow_local(:,:) => null()
    integer :: i1_glob, i2_glob, j1_glob, j2_glob
    integer :: i1, i2, j1, j2
      real(ESMF_KIND_R8), allocatable, target :: uas_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: vas_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: tas_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: psl_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: swdn_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: lwdn_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: rain_g(:,:)
      real(ESMF_KIND_R8), allocatable, target :: shum_g(:,:)
      real(ESMF_KIND_R8), allocatable :: snow_g(:,:)
      real(ESMF_KIND_R8), allocatable :: tmp_local(:,:)
      integer :: gi
      integer :: gj
      integer :: mpi_ierr_g
        real(ESMF_KIND_R8), pointer :: fpt_probe(:,:)
        logical, save :: raw_sst_diag_done = .false.
        real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:) => null()
        type(ESMF_Field) :: f_bs
        integer :: rc_bs_2

    ! nullify após todas as declarações (instrução executável
    ! não pode preceder declarações — Fortran 2003 §12.4).
    nullify(uocn, vocn)

    rc = ESMF_SUCCESS

    call ESMF_GridCompGetInternalState(gcomp, iswrap, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    is => iswrap%wrap

    ! (GT Acoplamento MONAN/INPE — Maio 2026):
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
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_ClockGet(clock, currTime=currTime, timeStep=dt, rc=rc)
    nextTime = currTime + dt

    !--------------------------------------------------------------------------
    ! o instante que rotula o resultado do
    ! mediador depende de ONDE o elemento 'MED' esta na RunSequence.
    !
    ! O relogio do mediador marca currTime = t durante toda a execucao do passo,
    ! nos dois modos: o NUOPC so' avanca o relogio depois que o Advance retorna.
    ! O que muda e' o conteudo que chega ao importState:
    !
    !   concurrent : 'MED' e' o ULTIMO elemento do passo. Os conectores
    !                'MPAS -> MED', 'OCN -> MED' e 'ICE -> MED' ja' rodaram
    !                DEPOIS dos avancos, entao os campos importados descrevem o
    !                estado em t+dt. O rotulo correto e' nextTime.
    !
    !   sequential : 'MED' e' o QUARTO elemento, ANTES de 'MPAS', 'OCN' e 'ICE'.
    !                Os conectores que o alimentam rodaram no inicio do passo, e
    !                os campos importados descrevem o estado em t (o que cada
    !                componente escreveu no fim do passo anterior). O rotulo
    !                correto e' currTime.
    !
    ! Ate' esta correcao nextTime era usado nos dois modos. Consequencias no
    ! modo sequencial:
    !
    !   (a) Todo arquivo de diagnostico mom6_import_YYYYMMDD_HHMMSS.nc e
    !       monan2_import_YYYYMMDD_HHMMSS.nc saia com o nome e a variavel de
    !       tempo adiantados em um dt_coupling em relacao ao dado que continha.
    !       Comparar uma rodada sequential com uma concurrent mostrava as duas
    !       deslocadas de um passo, e as animacoes ficavam fora de fase.
    !   (b) O exportState era carimbado com t+dt e entregue a componentes cujo
    !       relogio marcava t. Os tres caps usam CheckImport tolerante (janela
    !       de +/- dt_coupling) ou no-op, entao isso nao abortava a execucao;
    !       passava sem sinal nenhum. Com currTime o carimbo passa a coincidir
    !       exatamente com o relogio do consumidor.
    !
    ! O modo concorrente nao muda: stampTime = nextTime, byte a byte como antes.
    !--------------------------------------------------------------------------
    ! seq_repro: na variante REPRODUTIVEL do sequential+split+SIS2 o elemento
    ! 'MED' roda no FIM do passo (mesma coreografia do concurrent), portanto os
    ! campos importados descrevem o estado em t+dt e o rotulo correto e'
    ! nextTime — nao currTime. Sem o '.and. .not. cfg_seq_repro' o carimbo
    ! sairia adiantado de um dt e quebraria a comparacao bit-a-bit contra o
    ! concurrent. O sequential classico (cfg_seq_repro=.false.) continua com
    ! 'MED' cedo -> currTime; o concurrent continua nextTime. Nenhum dos dois
    ! muda de comportamento.
    med_runs_before_advance = (trim(cfg_coupling_mode) == 'sequential' &
                               .and. .not. cfg_seq_repro)
    if (med_runs_before_advance) then
      stampTime = currTime
    else
      stampTime = nextTime
    end if

    ! com regDecomp(2)=min(petCount,ny_atm/2), PETs acima de ny_atm/2
    ! têm localDeCount=0 para o atm_grid interno do MED. Esses PETs não têm
    ! dados locais — nenhum campo interno pode ser acessado via farrayPtr.
    call ESMF_FieldGet(is%f_taux_atm, localDeCount=localDeCount_med, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (localDeCount_med == 0) then  ! (*) — ponto de retorno corrigido
      ! PET sem DE local: participar nas operações MPI coletivas dentro de
      ! med_write_import_fields antes de retornar (evita deadlock).
      ! Contribuição local = FILL_IMP (neutro no MPI_Reduce MAX).
      call med_write_import_fields(exportState, stampTime, is, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS
      return
    end if

    !==========================================================================
    ! zerar f_*_atm antes do bulk para evitar persistência de
    ! valores não inicializados em células fora do alcance de uas/vas
    ! (grade MPAS Voronoi parcialmente sobreposta à grade MED regular).
    ! O loop bulk só preenche (i1:i2, j1:j2) = lbound:ubound(uas); sem
    ! zerar antes, regiões sem dados MPAS aparecem como lixo nos plots.
    !==========================================================================
    call zero_med_fluxes(is, rc)

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
        ! com regDecomp(2)=min(petCount,NLAT/2), PETs acima de NLAT/2
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
    ! (CRÍTICO): SPREAD MPAS-A → todos PETs do mediador.
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

      allocate(uas_g(ATM_NX,ATM_NY),  vas_g(ATM_NX,ATM_NY),  tas_g(ATM_NX,ATM_NY))
      allocate(psl_g(ATM_NX,ATM_NY),  swdn_g(ATM_NX,ATM_NY), lwdn_g(ATM_NX,ATM_NY))
      allocate(rain_g(ATM_NX,ATM_NY), shum_g(ATM_NX,ATM_NY), snow_g(ATM_NX,ATM_NY))
      allocate(tmp_local(ATM_NX,ATM_NY))

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
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) then
          tmp_local(gi,gj) = uas(gi,gj)
        end if
      end do; end do
      call MPI_Allreduce(tmp_local, uas_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! VAS
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = vas(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, vas_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! TAS
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = tas(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, tas_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! PSL
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = psl(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, psl_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! SWDN
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = swdn(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, swdn_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! LWDN
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = lwdn(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, lwdn_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! RAIN
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = rain(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, rain_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! SHUM (com fallback)
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = shum(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, shum_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)
      ! Onde shum_g=0 (não preenchido) e shum tem fallback, usar SHUM_OCEAN_DEFAULT
      where (shum_g <= 0.0_ESMF_KIND_R8) shum_g = SHUM_OCEAN_DEFAULT

      ! SNOW (fase 2 opcional — zero default)
      tmp_local = 0.0_ESMF_KIND_R8
      do gj=j1,j2; do gi=i1,i2
        if (gi >= 1 .and. gi <= ATM_NX .and. gj >= 1 .and. gj <= ATM_NY) tmp_local(gi,gj) = snow(gi,gj)
      end do; end do
      call MPI_Allreduce(tmp_local, snow_g, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
        MPI_SUM, med_mpi_comm, mpi_ierr_g)

      ! DIAGNÓSTICO vai para stdout (= esmApp_run.log).
      ! Espera-se que após, n_nz_uas > 30000/64800 (cobertura global).
      call log_atm_forcing_summary(uas_g, tas_g, psl_g, swdn_g, vas_g, shum_g, rain_g, lwdn_g, rc)

      deallocate(tmp_local)

      ! 2: arrays globais (uas_g..snow_g) cobrem 1..NX_G,1..NY_G
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
        nullify(fpt_probe)
        call ESMF_FieldGet(is%f_taux_atm, farrayPtr=fpt_probe, rc=rc)
        if (rc == ESMF_SUCCESS .and. associated(fpt_probe)) then
          i1 = lbound(fpt_probe,1); i2 = ubound(fpt_probe,1)
          j1 = lbound(fpt_probe,2); j2 = ubound(fpt_probe,2)
          ! Clampar aos limites globais (1..NX_G, 1..NY_G) para evitar acesso
          ! a uas_g fora dos bounds alocados.
          i1 = max(1, i1); i2 = min(ATM_NX, i2)
          j1 = max(1, j1); j2 = min(ATM_NY, j2)
        else
          ! PET sem DE local — bounds vazios → loops não executam
          i1 = 1; i2 = 0
          j1 = 1; j2 = 0
        end if

      ! NOTA: uas_g..snow_g são allocatable LOCAIS dentro deste block.
      ! Para mantê-los vivos até o fim do MediatorAdvance, usamos pointer
      ! association: uas => uas_g é seguro porque uas é declarado pointer no
      ! escopo externo. O `block` precisa permanecer aberto até o fim do bulk.
      ! ATENÇÃO: este block deve englobar TODA a seção 4 (CALCULAR BULK NCAR)
      ! e seção 5 (REGRID E EXPORTA). Veja end block ao final.


    !==========================================================================
    ! 3. SST: regrid OCN -> ATM (So_t esta agora na grade OCN)
    !
    ! 5 (Maio 2026): aplica mascara terra/oceano apos o regrid.
    !
    ! CAUSA-RAIZ DETECTADA NO POSTPROC:
    ! O mom_cap_methods::state_setexport multiplica SST por ocean_grid%mask2dT
    ! antes do export (linha 1126 do mom_cap_methods.F90). Sobre terra,
    ! mask2dT=0 -> SST=0 K na grade OCN. Apos regrid bilinear OCN->ATM, celulas
    ! oceanicas proximas a costa ficam contaminadas pela mistura com zero,
    ! caindo abaixo de 270 K. Resultado: ~37% das celulas oceanicas mascaradas
    ! como "fill" pelo postproc (limiar fill_min_threshold=270 K).
    !
    ! a mascara terra/oceano usada no regrid
    ! bilinear OCN->ATM NAO deve ser adivinhada a partir do proprio campo de
    ! SST (limiar T<270K). Isso e' fragil e inconsistente com a mascara real
    ! do modelo oceanico: a mascara agora vem diretamente de So_omask =
    ! nint(mask2dT), exportada pelo MOM6 (mom_cap_methods.F90::mom_export).
    ! Assim o bilinear so' usa celulas OCEANICAS VALIDAS como fonte da
    ! interpolacao, nunca preenchimentos de terra (SST=0K sob mask2dT=0).
    ! Residual nao mapeado na costa (onde nenhum vizinho valido bilinear
    ! existe) e' tratado pela extrapolacao por vizinhanca logo abaixo.
    !==========================================================================
    call update_ocean_fields_on_atm_grid(is, importState, field, raw_sst_diag_done, rc)

    !==========================================================================
    ! 3b. Si_ifrac —.1.1: fill_ifrac_from_oisst apenas no 1º passo
    !
    ! Modos (nuopc.input &nuopc_mode):
    !   use_docn_ice=T  init_only=F  → Alternativa 1 original:
    !     fill_ifrac_from_oisst a cada passo (campo congelado em OISST).
    ! use_docn_ice=T init_only=T →.1.1:
    !     fill_ifrac_from_oisst apenas na 1ª MediatorAdvance (flag
    !     med_ifrac_init_done). is%f_ifrac_atm fica congelado no valor
    !     OISST de t=0 nas demais chamadas.
    !     NÃO tentar rh_ocn2atm para Si_ifrac: zera is%f_ifrac_atm antes
    ! de falhar (rh é específico para So_t)..2 criará rh dedicado.
    !   use_docn_ice=F              → regrid OCN sigmoid via importState.
    !==========================================================================
    ! SI_IFRAC_DECAY_MED declarado no escopo do módulo (acessível aqui via host association)
    call update_ice_fraction_from_docn(is, clock, ifrac_ptr, rc)
    ! init_only=F: field preenchido a cada passo via fill_ifrac_from_oisst
    ! use_docn_ice=F: is%f_ifrac_atm foi zerado acima; permanece zero

    !==========================================================================
    ! 4. CALCULAR BULK NCAR — delegado ao módulo med_bulk_ncar_mod
    !==========================================================================
    call calc_bulk_ncar(is, importState, &
                        uas_g, vas_g, tas_g, psl_g, swdn_g, lwdn_g, rain_g, shum_g, snow_g, &
                        i1, i2, j1, j2, clock, rc)
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
    ! CONFIRMADO (Set/2026): sinal de hfx/lh e' POSITIVO PARA CIMA (convencao
    !  usual WRF/MPAS/GFS), verificado com a equipe de fisica do MONAN-A —
    !  por isso invertido (-sen_g2, -lat_g2) abaixo, para bater com a
    !  convencao Foxx_sen/Foxx_evap (positivo = aquece o oceano). Este item
    !  NAO se aplica a Fioi_sen/Fioi_evap (fluxos do gelo, calculados a
    !  parte em med_bulk_ncar.F90 com T_gelo, nao com hfx/lh nativos) — ver
    ! em sis_cap_MONAN.F90 para o sinal desses.
    !  1) Sinal de hfx/lh: POSITIVO PARA CIMA (convencao
    !     usual WRF/MPAS/GFS), por isso invertido (-sen_g2, -lat_g2) para
    !     bater com a convencao Foxx_sen/Foxx_evap (positivo = aquece o
    !     oceano).
    !  2) taux_sfc/tauy_sfc (de mpas_atm_model.F90) usam a mesma forma
    !     rho*Cd*|V|*V do bulk NCAR — nao invertidos aqui, mas confirme
    !     que a rotacao de referencial (Terra vs. grade) ja e tratada
    !     antes de exportar (deve ser, pois MPAS ja roda em lat/lon).
    !  3) Faxa_lat_mpas vem em W/m^2 (energia); Foxx_evap e fluxo de MASSA
    !     (kg/m^2/s) — por isso a divisao por L_evap abaixo.
    !==========================================================================
    if (associated(sen_mpas) .and. associated(lat_mpas) .and. &
        associated(taux_mpas) .and. associated(tauy_mpas)) then
      call substitute_native_fluxes(is, sen_mpas, lat_mpas, taux_mpas, tauy_mpas, rc)
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
    ! 5.1 (Maio 2026): aplicacao de mascara terra/oceano nos fluxos
    ! antes do export, eliminando valores absurdos sobre continentes.
    !
    ! CONTEXTO:
    ! O bulk NCAR roda em TODAS as celulas da grade ATM (oceano + terra).
    ! Apos o.5, celulas terra recebem sst = 271.35 K (marcador).
    ! Combinado com T_2m, U_10m, P_slv reais (continentais), o bulk produz
    ! fluxos enormes sobre terra (Foxx_sen saturando em +-500 W/m^2;
    ! Foxx_lwnet em -300 W/m^2 sobre o Saara).
    !
    ! O MOM6 ja descarta essas celulas em state_setexport (mask2dT), mas o
    ! diagnostico NetCDF do MED captura ANTES dessa mascara, registrando
    ! os valores absurdos..5.1 zera os fluxos sobre terra no
    ! proprio MED, antes da escrita do NetCDF e antes do envio ao MOM6.
    !
    ! HEURISTICA: celulas terra tem sst exatamente = 271.35 K (marcador
    ! cravado pelo where do.5). Celulas marinhas polares reais
    ! tem sst variavel em torno de 270-272 K (raramente exato em 271.35).
    !==========================================================================
    ! cria/regrida is%f_omask_atm uma unica
    ! vez (So_omask, ocn_grid -> atm_grid, NEAREST_STOD -- so' precisa
    ! discriminar terra/oceano, nao precisao subcelular). Usado abaixo no
    ! 5.1 no lugar da heuristica SST~=271,35K, que colidia com
    ! agua aberta genuina no ponto de congelamento (borda do gelo).
    call export_to_components(is, importState, exportState, rc)
    if (allocated(uas_g)) deallocate(uas_g)
    if (allocated(vas_g)) deallocate(vas_g)
    if (allocated(tas_g)) deallocate(tas_g)
    if (allocated(psl_g)) deallocate(psl_g)
    if (allocated(swdn_g)) deallocate(swdn_g)
    if (allocated(lwdn_g)) deallocate(lwdn_g)
    if (allocated(rain_g)) deallocate(rain_g)
    if (allocated(shum_g)) deallocate(shum_g)
    if (allocated(snow_g)) deallocate(snow_g)
    if (allocated(tmp_local)) deallocate(tmp_local)

    ! Atualizar timestamps do exportState
    call stamp_export_fields(exportState, field, stampTime, rc)

    call ESMF_LogWrite('MED: MediatorAdvance concluido', ESMF_LOGMSG_INFO)

    ! ── v4: diagnóstico de importação inline ──────────────────
    ! Implementação direta em MED_cap_MONAN.F90 — sem dependência de
    ! MOM_cap_methods (lib pré-compilada) nem de coupler_config_mod.
    ! Lê mom6_output.nml com namelist local de 2 variáveis (sem ios/=0).
    ! Usa netcdf (já importado neste módulo) para escrever os campos.
    ! ─────────────────────────────────────────────────────────────────────────
    ! ── RouteOcnToAtm — exportar SST/gelo MOM6 dinâmico ao MPAS ────
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

    ! (etapa 4 de 4): Si_ifrac como sai do mediador,
    ! no exportState, depois do RouteOcnToAtm. E' o que o conector entrega
    ! ao MPAS e o que aparece no monan2_import_*.nc.
    if (cfg_write_fixdiag) then
        call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_bs, rc=rc_bs_2)
        if (rc_bs_2 == ESMF_SUCCESS) then
          call diag_bitsum_log('etapa4 Si_ifrac exportState para MPAS', f_bs, rc_bs_2)
        else
          call ESMF_LogWrite('FIX-DIAG-BITSUM-01: etapa4 Si_ifrac ausente do ' // &
            'exportState; etapa NAO medida', ESMF_LOGMSG_WARNING)
        end if
    end if

    call med_write_import_fields(exportState, stampTime, is, rc)
    if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS  ! nao-fatal
    ! Liberar arrays temporarios de defaults (se alocados)
    if (associated(shum_local)) then
      deallocate(shum_local); nullify(shum_local)
    end if
    if (associated(snow_local)) then
      deallocate(snow_local); nullify(snow_local)
    end if
  end subroutine MediatorAdvance

  subroutine stamp_export_fields(exportState, field, stampTime, rc)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: field
    type(ESMF_Time), intent(inout) :: stampTime
    integer, intent(inout) :: rc
    integer :: fieldCount
    character(len=64), allocatable :: fieldNameList(:)
    integer :: k
    call ESMF_StateGet(exportState, itemCount=fieldCount, rc=rc)
    allocate(fieldNameList(fieldCount))
    call ESMF_StateGet(exportState, itemNameList=fieldNameList, rc=rc)
    do k = 1, fieldCount
      call ESMF_StateGet(exportState, itemName=trim(fieldNameList(k)), &
        field=field, rc=rc)
      call NUOPC_SetTimestamp(field, stampTime, rc=rc)
    end do
    deallocate(fieldNameList)
  end subroutine stamp_export_fields

  subroutine export_to_components(is, importState, exportState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    integer, intent(inout) :: rc
    integer :: rc_sst
    real(ESMF_KIND_R8), pointer :: sst_diag(:,:)
    if (.not. is%landmask_done) then
      call regrid_land_mask(is, importState)
    end if
    ! (So_omask e' estatico no tempo -- uma vez regridada corretamente na
    ! 1a chamada, is%f_omask_atm permanece valida sem precisar refazer o
    ! regrid a cada passo.)

    call zero_fluxes_over_land(is, rc)

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
    ! Si_ifrac exportado SEM o RegridOrCopy
    ! generico. O /02 corrigiu so' a perna OCN(SIS2)->ATM
    ! (populando is%f_ifrac_atm corretamente). Mas o RegridOrCopy generico
    ! faz uma SEGUNDA perna, ATM->OCN (via rh_atm2ocn, NEAREST_STOD,
    ! zeroregion=TOTAL, sem mascara, sem extrapolacao), para preencher o
    ! campo "Si_ifrac" do exportState (realizado em ocn_grid, mesmo padrao
    ! generico de todo export_names) — essa perna nunca recebeu nenhuma das
    ! correcoes anteriores e sofre da MESMA classe de problema (celula nao
    ! mapeada -> zerada), agora na direcao oposta, perto do mesmo fold
    ! tripolar. Resultado observado: manchas isoladas em vez de calota
    ! continua, mesmo com is%f_ifrac_atm ja correto na entrada.
    call export_ice_fraction(is, exportState, rc)
    call RegridOrCopy(is%f_duu10n_atm, exportState, "So_duu10n",      is, rc)
    ! mascara terra/oceano REAL do MOM6 no
    ! exportState. is%f_omask_atm ja' esta' pronta neste ponto (regridada
    ! uma unica vez logo acima,). Aqui ela segue para o
    ! conector MED->MPAS, que a leva ate' o cap atmosferico; o diagnostico
    ! mom6_import_*.nc NAO passa por este caminho — le is%f_omask_atm
    ! diretamente na grade ATM (med_cap_netcdf.F90), evitando o ida-e-volta
    ! ATM->OCN->Voronoi. O corte binario fica sempre no consumidor final,
    ! nunca no meio do caminho, para nao criar escadinha na linha de costa.
    call RegridOrCopy(is%f_omask_atm,  exportState, "Sx_omask",       is, rc)
    call RegridOrCopy(is%f_coszen_atm, exportState, "Faxa_coszen",    is, rc)  ! Fase 2.5
    call RegridOrCopy(is%f_albedo_atm, exportState, "Sf_albedo",      is, rc)  ! Fase 2.6
    ! Fase 3
    call RegridOrCopy(is%f_taux_ice,   exportState, "Fioi_taux",      is, rc)
    call RegridOrCopy(is%f_tauy_ice,   exportState, "Fioi_tauy",      is, rc)
    call RegridOrCopy(is%f_sen_ice,    exportState, "Fioi_sen",       is, rc)
    call RegridOrCopy(is%f_evap_ice,   exportState, "Fioi_evap",      is, rc)
    call RegridOrCopy(is%f_lwnet_ice,  exportState, "Fioi_lwnet",     is, rc)
    ! Fase 4
    call RegridOrCopy(is%f_swvdr_ice,  exportState, "Fioi_swnet_vdr", is, rc)
    call RegridOrCopy(is%f_swvdf_ice,  exportState, "Fioi_swnet_vdf", is, rc)
    call RegridOrCopy(is%f_swidr_ice,  exportState, "Fioi_swnet_idr", is, rc)
    call RegridOrCopy(is%f_swidf_ice,  exportState, "Fioi_swnet_idf", is, rc)

    ! Fase 4b (, Set/2026): CORRECAO da Fase 4
    ! anterior. Aquela versao sobrescrevia
    ! is%f_sst_atm IN-PLACE com a mistura (1-ifrac)*SST + ifrac*Si_t_sis2,
    ! reaproveitando o export "So_t" ja existente. Problema descoberto em
    ! producao: sis_cap_MONAN.F90 TAMBEM importa "So_t" (linha ~914) para
    ! calcular o fluxo de calor da BASE do gelo (ICE_KMELT no SIS2, que
    ! precisa da SST REAL do oceano sob o gelo). Misturar Si_t_sis2 (a
    ! propria temperatura de pele do gelo, calculada pelo SIS2) de volta
    ! em "So_t" antes de devolve-la ao SIS2 e' circular: o gradiente
    ! T_oceano - T_congelamento que controla o derretimento/crescimento
    ! basal fica artificialmente reduzido em celulas com gelo, suprimindo
    ! o derretimento basal e contribuindo para crescimento excessivo de
    ! espessura (observado em producao apos a Fase 4b original + Fase 4
    ! SW-split, que ja reduziam o derretimento por si so').
    !
    ! Fix: is%f_sst_atm NUNCA mais e' sobrescrito — "So_t" (abaixo)
    ! permanece SST pura, como o SIS2 (e potencialmente outros
    ! consumidores futuros) esperam. O composto vai para um campo
    ! SEPARADO, is%f_tsfc_atm, exportado sob um StandardName NOVO,
    ! "Sx_tsfc", que so' o MPAS-A importa (ver mpas_cap_MONAN.F90 —
    ! IMP_NAMES trocado de "So_t" para "Sx_tsfc" para atm_bnd%sst).
    call export_surface_temperature(is)

    ! So_t: SST dinâmica MOM6 → exportState para escrita NetCDF e conector MED→MPAS
    ! Diagnóstico: imprimir min/max de is%f_sst_atm para confirmar que tem dados reais.
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
    call RegridOrCopy(is%f_sst_atm,    exportState, "So_t",           is, rc)
    if (rc /= ESMF_SUCCESS) then
      write(*,'(A,I0)') '[MED-DIAG] RegridOrCopy So_t FALHOU rc=', rc
      flush(6)
      rc = ESMF_SUCCESS  ! não fatal — para debug
    else
      write(*,'(A)') '[MED-DIAG] RegridOrCopy So_t OK'
      flush(6)
    end if

    ! Fase 4b: Sx_tsfc — composto (SST+Si_t_sis2 por
    ! Si_ifrac), exclusivo para o MPAS-A (atm_bnd%sst via IMP_NAMES em
    ! mpas_cap_MONAN.F90). So_t acima permanece SST pura para o SIS2.
    call RegridOrCopy(is%f_tsfc_atm,   exportState, "Sx_tsfc",        is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy Sx_tsfc FALHOU — exportState ' // &
        'mantem fallback (ver FillInternalField f_tsfc_atm)', ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

    ! ── ────────────────────────────────────────
    ! So_u, So_v: correntes superficiais MOM6 -> exportState para conector
    ! MED -> MPAS. Os campos f_uocn_atm/f_vocn_atm já contêm os valores
    ! regridados OCN -> ATM (preenchidos no bloco acima a partir
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

    ! ── ───────────────────────────────────────────────
    ! Sf_zorl: rugosidade superficial Charnock+Smith calculada no bulk NCAR
    ! a partir de Foxx_taux/tauy. Mesmo padrão arquitetural de So_t/So_u/So_v:
    ! f_zorl_atm (grade ATM interna) -> RegridOrCopy -> exportState.Sf_zorl
    ! (grade OCN) -> conector MED -> MPAS faz o regrid final para Voronoi.
    ! O cap MPAS atualiza atm_bnd%zorl com este valor a cada passo
    ! em vez de manter o default fixo de 0.01 m.
    call RegridOrCopy(is%f_zorl_atm, exportState, "Sf_zorl", is, rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('MED: RegridOrCopy Sf_zorl FALHOU — exportState mantem default 0.01 m', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS  ! não fatal — manter pipeline ativo
    end if

  end subroutine export_to_components

  subroutine update_ice_fraction_from_docn(is, clock, ifrac_ptr, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_Clock), intent(inout) :: clock
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: ifrac_ptr(:,:)
    integer :: ldec
    if (cfg_use_docn_ice .and. &
        (.not. cfg_docn_ice_init_only .or. .not. med_ifrac_init_done)) then
      call fill_ifrac_from_oisst(is, clock, rc)
      if (rc /= ESMF_SUCCESS) rc = ESMF_SUCCESS  ! não fatal
      med_ifrac_init_done = .true.               ! inicializado em t=0

    else if (cfg_use_docn_ice .and. cfg_docn_ice_init_only .and. &
             med_ifrac_init_done) then
      ! 1.1: decaimento exponencial do campo OISST retido em
      ! is%f_ifrac_atm. O campo NÃO foi zerado (fix acima).
      ! Multiplica cada célula por SI_IFRAC_DECAY_MED (≈ 0.9592/hora).
      ! Resulta em τ ≈ 24h: gelo antártico/ártico decai fisicamente em vez
      ! de desaparecer instantaneamente no passo seguinte ao t=0.
        call ESMF_FieldGet(is%f_ifrac_atm, localDeCount=ldec, rc=rc)
        if (rc == ESMF_SUCCESS .and. ldec > 0) then
          call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=ifrac_ptr, rc=rc)
          if (rc == ESMF_SUCCESS .and. associated(ifrac_ptr)) then
            ifrac_ptr = ifrac_ptr * SI_IFRAC_DECAY
            where (ifrac_ptr < 0.0_ESMF_KIND_R8) ifrac_ptr = 0.0_ESMF_KIND_R8
          end if
        end if
        rc = ESMF_SUCCESS
        call ESMF_LogWrite( &
          'MED(B.1.1): Si_ifrac decaimento aplicado (SI_IFRAC_DECAY_MED=0.9592)', &
          ESMF_LOGMSG_INFO)
    end if
  end subroutine update_ice_fraction_from_docn

  subroutine update_ocean_fields_on_atm_grid(is, importState, field, raw_sst_diag_done, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: field
    logical, intent(inout) :: raw_sst_diag_done
    integer, intent(inout) :: rc
    character(len=300) :: dbgmsg2
    character(len=220) :: diag_msgB2
    integer :: i1r
    integer :: i2r
    integer :: j1r
    integer :: mid_r
    real(ESMF_KIND_R8), pointer :: p_idr(:,:)
    real(ESMF_KIND_R8), pointer :: p_if(:,:)
    real(ESMF_KIND_R8), pointer :: p_vdr(:,:)
    integer :: rc_diag
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    real(ESMF_KIND_R8), pointer :: sst_raw(:,:)
    if (is%regrid%has('ocn2atm')) then
      call ESMF_StateGet(importState, itemName="So_t", field=field, rc=rc)

      ! DIAGNOSTICO TEMPORARIO valores BRUTOS de So_t (antes de
      ! qualquer regrid/mascara do MED), para isolar se a falta de estrutura
      ! leste-oeste vem da EXPORTACAO do MOM6 ou do regrid do mediador.
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


      ! ?? Opção 1 (v4.18, corrigido v5.0): regrid SST ciente da mascara real
      !    do oceano (So_omask) + extrapolação de vizinhança para a costa. ??
      if (.not. is%regrid%has('ocn2atm_sst')) call set_ocean_mask_for_sst(is, importState, field, rc)

      if (is%regrid%has('ocn2atm_sst')) then
        call is%regrid%apply('ocn2atm_sst', field, is%f_sst_atm, rc, zero_total=.true.)
      else
        call is%regrid%apply('ocn2atm', field, is%f_sst_atm, rc, zero_total=.true.)
      end if
      call ESMF_FieldGet(is%f_sst_atm, farrayPtr=sst, rc=rc)

      ! Extrapolação por vizinhança (preenche costa/costura); resíduo → T_FILL.
      if (associated(sst)) then
        call fill_sst_gaps(sst)
      end if

      ! v13.0): regrid de correntes oceânicas OCN → ATM.
      ! So_u e So_v agora anunciados e realizados no importState do MED (ocn_grid).
      ! ESMF_StateGet é seguro — sem risco de "Not found" no log.
      ! Fallback seguro: se regrid falhar, mantém zeros em f_uocn_atm/f_vocn_atm.
      call regrid_ocean_currents(is, importState, zero_on_error=.false.)

      ! ──.2 (Set/2026) + Si_ifrac_sis2 real +
      !    albedo + T_gelo, regridados via RouteHandle MASCARADO dedicado
      !    (rh_ocn2atm_ice), com extrapolacao por vizinhanca pos-regrid —
      !    mesmo tratamento ja validado para So_t (rh_ocn2atm_sst), agora
      !    estendido ao gelo. Antes usava rh_ocn2atm generico (sem mascara,
      !    sem extrapolacao), problematico justamente porque o gelo se
      !    concentra na regiao de deformacao da malha tripolar (alta
      !    latitude) — o mesmo tipo de artefato que ja exigiu tratamento
      !    especial para SST, so' que sem diluicao no resto do dominio.
      if (cfg_use_sis2_dynamic) then
        call update_ice_fields_on_atm_grid(is, importState)

        ! validacao. is%f_ifrac_atm deve agora
        ! refletir o Ice%part_size real (ver no cap do
        ! gelo) regridado para a grade ATM — nao mais zero nem OISST
        ! sintetico. Os 4 bandos de albedo devem estar entre o fallback
        ! (0,65) e valores de neve fria (~0,85-0,9) onde ha gelo espesso.
        if (cfg_write_fixdiag) then
            call ESMF_FieldGet(is%f_ifrac_atm,   farrayPtr=p_if,  rc=rc)
            call ESMF_FieldGet(is%f_alb_vdr_ice, farrayPtr=p_vdr, rc=rc)
            call ESMF_FieldGet(is%f_alb_idr_ice, farrayPtr=p_idr, rc=rc)
            rc = ESMF_SUCCESS
            if (associated(p_if) .and. associated(p_vdr) .and. associated(p_idr)) then
              write(diag_msgB2,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
                'FIX-DIAG-SPRINTB2-01: f_ifrac_atm min=', minval(p_if), &
                ' max=', maxval(p_if), &
                ' | f_alb_vdr_ice min=', minval(p_vdr), ' max=', maxval(p_vdr), &
                ' | f_alb_idr_ice min=', minval(p_idr), ' max=', maxval(p_idr)
              call ESMF_LogWrite(trim(diag_msgB2), ESMF_LOGMSG_INFO)
            end if
        end if
      end if
    else
      ! Routehandles nao criados: usa SST padrao (ja preenchido em InitializeRealize)
      call ESMF_FieldGet(is%f_sst_atm, farrayPtr=sst, rc=rc)
    end if
  end subroutine update_ocean_fields_on_atm_grid

  subroutine zero_med_fluxes(is, rc)
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
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
    ! (v2.5): NÃO zerar is%f_ifrac_atm incondicionalmente.
    ! Em.1.1 (use_docn_ice=T, init_only=T, med_ifrac_init_done=T),
    ! fill_ifrac_from_oisst é pulado após o primeiro passo, então zerando aqui
    ! MPAS receberia Si_ifrac=0 em todos os passos seguintes ao t=1.
    ! O campo é zerado apenas nos modos em que será repreenchido neste ciclo.
    ! No.1.1, o decaimento é aplicado no bloco 3b abaixo.
    if (.not. (cfg_use_docn_ice .and. &
               cfg_docn_ice_init_only .and. med_ifrac_init_done)) then
      call ZeroInternalField(is%f_ifrac_atm, rc)
    end if
    call ZeroInternalField(is%f_duu10n_atm, rc)
    ! v13.0): zerar correntes para evitar persistência
    call ZeroInternalField(is%f_uocn_atm,   rc)
    call ZeroInternalField(is%f_vocn_atm,   rc)
    rc = ESMF_SUCCESS  ! ZeroInternalField pode retornar !=SUCCESS para PETs sem DE
  end subroutine zero_med_fluxes

  subroutine export_surface_temperature(is)
    type(MED_InternalState), pointer :: is
    real(ESMF_KIND_R8), pointer :: p_sst_src(:,:), p_tice_comp(:,:), p_ifrac_comp(:,:)
    real(ESMF_KIND_R8), pointer :: p_tsfc_out(:,:)
    integer :: rc_tsfc
    real(ESMF_KIND_R8) :: ifrac_c
    integer :: ii_c, jj_c
    character(len=220) :: diag_msg_tsfc

    call ESMF_FieldGet(is%f_sst_atm,   farrayPtr=p_sst_src,   rc=rc_tsfc)
    call ESMF_FieldGet(is%f_tice_atm,  farrayPtr=p_tice_comp, rc=rc_tsfc)
    call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=p_ifrac_comp,rc=rc_tsfc)
    call ESMF_FieldGet(is%f_tsfc_atm,  farrayPtr=p_tsfc_out,  rc=rc_tsfc)
    if (associated(p_sst_src) .and. associated(p_tice_comp) .and. &
        associated(p_ifrac_comp) .and. associated(p_tsfc_out)) then
      do jj_c = lbound(p_sst_src,2), ubound(p_sst_src,2)
        do ii_c = lbound(p_sst_src,1), ubound(p_sst_src,1)
          ! Clamp defensivo local — nao confia cegamente nas extrapolacoes
          ! upstream, mesma filosofia dos guards de NaN/faixa fisica
          ! usados no resto do arquivo (ex. clamp de Sf_albedo, So_t).
          ifrac_c = p_ifrac_comp(ii_c,jj_c)
          if (ifrac_c /= ifrac_c) ifrac_c = 0.0_ESMF_KIND_R8   ! NaN guard
          ifrac_c = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ifrac_c))
          if (p_tice_comp(ii_c,jj_c) == p_tice_comp(ii_c,jj_c) .and. &
              p_tice_comp(ii_c,jj_c) > 180.0_ESMF_KIND_R8 .and. &
              p_tice_comp(ii_c,jj_c) < 280.0_ESMF_KIND_R8) then
            p_tsfc_out(ii_c,jj_c) = (1.0_ESMF_KIND_R8 - ifrac_c) * p_sst_src(ii_c,jj_c) &
                                     + ifrac_c * p_tice_comp(ii_c,jj_c)
          else
            ! Si_t_sis2 nao regridou/extrapolou para um valor fisico
            ! nesta celula — mantem SST pura em vez de contaminar com
            ! um valor suspeito, mesma logica defensiva do fallback de
            ! Sf_albedo.
            p_tsfc_out(ii_c,jj_c) = p_sst_src(ii_c,jj_c)
          end if
        end do
      end do
      if (cfg_write_fixdiag) then
          write(diag_msg_tsfc,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
            'FIX-DIAG-TSFCCOMP-01: Sx_tsfc(composto) min=', minval(p_tsfc_out), &
            ' max=', maxval(p_tsfc_out), ' | So_t(pura, INTOCADA) min=', &
            minval(p_sst_src), ' max=', maxval(p_sst_src)
          call ESMF_LogWrite(trim(diag_msg_tsfc), ESMF_LOGMSG_INFO)
      end if
    else
      ! Sem dado para compor — Sx_tsfc degrada para SST pura (mesmo
      ! comportamento que o MPAS-A teria antes de qualquer Fase 4b).
      if (associated(p_sst_src) .and. associated(p_tsfc_out)) &
        p_tsfc_out(:,:) = p_sst_src(:,:)
      call ESMF_LogWrite('MED(B-TSFC-DUALEXPORT-01): AVISO — ponteiros ' // &
        'de So_t/Si_t_sis2/Si_ifrac indisponiveis, Sx_tsfc degradado ' // &
        'para SST pura', ESMF_LOGMSG_WARNING)
    end if
  end subroutine export_surface_temperature

  subroutine export_ice_fraction(is, exportState, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: exportState
    integer, intent(inout) :: rc
    type(ESMF_Field) :: f_ifrac_exp
    integer :: rc_ifrac2
    real(ESMF_KIND_R8), pointer :: p_ifrac_exp(:,:)
    integer :: rc_store2
    character(len=200) :: diag_msg_ifrac2

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_ifrac_exp, rc=rc_ifrac2)
    if (rc_ifrac2 == ESMF_SUCCESS) then
      call FillInternalField(f_ifrac_exp, -999.0_ESMF_KIND_R8, rc_ifrac2)

      ! CONSERVE reativado aqui tambem —
      ! ver comentario completo em (bloco rh_ocn2atm_ice)
      ! sobre por que a reversao anterior tinha
      ! diagnostico errado (causa real era, nao o
      ! metodo de regrid).
      if (.not. is%regrid%has('atm2ocn_ice') .and. is%regrid%has('atm2ocn')) &
        call is%regrid%add('atm2ocn_ice', regrid_spec('conserve,nearest_stod'), &
          is%f_ifrac_atm, f_ifrac_exp, rc_store2, fallback='atm2ocn')

      if (is%regrid%has('atm2ocn_ice')) then
        call is%regrid%apply('atm2ocn_ice', is%f_ifrac_atm, f_ifrac_exp, rc_ifrac2, &
          zero_total=.false.)
      else
        call is%regrid%apply('atm2ocn', is%f_ifrac_atm, f_ifrac_exp, rc_ifrac2, &
          zero_total=.true.)
      end if
      call ESMF_FieldGet(f_ifrac_exp, farrayPtr=p_ifrac_exp, rc=rc_ifrac2)
      if (associated(p_ifrac_exp)) &
        call neighbor_fill(p_ifrac_exp, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.0_ESMF_KIND_R8))
      if (cfg_write_fixdiag .and. associated(p_ifrac_exp)) then
          write(diag_msg_ifrac2,'(A,ES10.3,A,ES10.3)') &
            'FIX-DIAG-ICEREGRID04-01: Si_ifrac(exportState, pos ATM->OCN+' // &
            'extrapolacao) min=', minval(p_ifrac_exp), ' max=', maxval(p_ifrac_exp)
          call ESMF_LogWrite(trim(diag_msg_ifrac2), ESMF_LOGMSG_INFO)
      end if
    else
      ! Fallback: exportState sem Si_ifrac realizado (nao deveria
      ! acontecer) -- mantem o comportamento antigo em vez de travar.
      call RegridOrCopy(is%f_ifrac_atm, exportState, "Si_ifrac", is, rc)
    end if
  end subroutine export_ice_fraction

  subroutine zero_fluxes_over_land(is, rc)
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    integer :: n_land_masked
    real(ESMF_KIND_R8), pointer :: p_taux(:,:), p_tauy(:,:), p_sen(:,:)
    real(ESMF_KIND_R8), pointer :: p_evap(:,:), p_lwnet(:,:)
    real(ESMF_KIND_R8), pointer :: p_swvdr(:,:), p_swvdf(:,:)
    real(ESMF_KIND_R8), pointer :: p_swidr(:,:), p_swidf(:,:)
    real(ESMF_KIND_R8), pointer :: p_rain(:,:),  p_snow(:,:)
    real(ESMF_KIND_R8), pointer :: p_omask(:,:)
    logical, allocatable :: land_mask(:,:)
    character(len=160) :: logmsg

    nullify(p_taux, p_tauy, p_sen, p_evap, p_lwnet)
    nullify(p_swvdr, p_swvdf, p_swidr, p_swidf, p_rain, p_snow, p_omask)

    call ESMF_FieldGet(is%f_omask_atm, farrayPtr=p_omask, rc=rc)
    if (associated(p_omask)) then
      ! mascara REAL (So_omask regridada), nao mais
      ! inferida por SST. p_omask < 0.5 = terra (limiar central entre
      ! 0=terra e 1=oceano; robusto a pequena mistura de borda do
      ! regrid NEAREST_STOD, que deveria ser quase sempre exatamente
      ! 0 ou 1 de qualquer forma).
      allocate(land_mask(lbound(p_omask,1):ubound(p_omask,1), &
                         lbound(p_omask,2):ubound(p_omask,2)))
      land_mask = (p_omask < 0.5_ESMF_KIND_R8)
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
        write(logmsg, '(A,I0,A)') &
          'MED Sprint A.5.1: fluxos zerados em ', n_land_masked, &
          ' celulas de terra (mascara real So_omask, ver B-LANDMASK-01)'
        call ESMF_LogWrite(trim(logmsg), ESMF_LOGMSG_INFO)

      deallocate(land_mask)
    end if
  end subroutine zero_fluxes_over_land

  subroutine regrid_land_mask(is, importState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field) :: omask_src_field
    integer :: rc_lm

    call ESMF_StateGet(importState, itemName="So_omask", &
      field=omask_src_field, rc=rc_lm)
    if (rc_lm == ESMF_SUCCESS) then
      call is%regrid%add('ocn2atm_landmask', regrid_spec('nearest_stod'), &
        omask_src_field, is%f_omask_atm, rc_lm)
      if (rc_lm == ESMF_SUCCESS) then
        call is%regrid%apply('ocn2atm_landmask', omask_src_field, is%f_omask_atm, rc_lm, &
          zero_total=.false.)
        call ESMF_LogWrite('MED: mascara terra/oceano real regridada para a grade ATM', &
          ESMF_LOGMSG_INFO)
      else
        ! is%f_omask_atm continua 1.0 (tudo oceano)
        call ESMF_LogWrite('MED: falha no regrid da mascara So_omask; ' // &
          'mantido tudo-oceano (1.0)', ESMF_LOGMSG_WARNING)
      end if
    else
      call ESMF_LogWrite('MED B-LANDMASK-01: So_omask indisponivel -- ' // &
        'mantendo fallback tudo-oceano (1.0)', ESMF_LOGMSG_WARNING)
    end if
    is%landmask_done = .true.
  end subroutine regrid_land_mask

  subroutine substitute_native_fluxes(is, sen_mpas, lat_mpas, taux_mpas, tauy_mpas, rc)
    type(MED_InternalState), pointer :: is
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: sen_mpas(:,:)
    real(ESMF_KIND_R8), pointer :: lat_mpas(:,:)
    real(ESMF_KIND_R8), pointer :: taux_mpas(:,:)
    real(ESMF_KIND_R8), pointer :: tauy_mpas(:,:)
    real(ESMF_KIND_R8), allocatable :: sen_g2(:,:), lat_g2(:,:)
    real(ESMF_KIND_R8), allocatable :: taux_g2(:,:), tauy_g2(:,:), tmp2(:,:)
    real(ESMF_KIND_R8), pointer     :: fptr_sen(:,:), fptr_evap(:,:)
    real(ESMF_KIND_R8), pointer     :: fptr_taux(:,:), fptr_tauy(:,:)
    integer :: gi2, gj2, ierr2, ii, jj

    nullify(fptr_sen, fptr_evap, fptr_taux, fptr_tauy)
    allocate(sen_g2(ATM_NX,ATM_NY), lat_g2(ATM_NX,ATM_NY))
    allocate(taux_g2(ATM_NX,ATM_NY), tauy_g2(ATM_NX,ATM_NY), tmp2(ATM_NX,ATM_NY))

    ! Gather global (mesmo padrao SUM com tiles disjuntos)
    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(sen_mpas,2), ubound(sen_mpas,2)
      do gi2 = lbound(sen_mpas,1), ubound(sen_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = sen_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, sen_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, med_mpi_comm, ierr2)

    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(lat_mpas,2), ubound(lat_mpas,2)
      do gi2 = lbound(lat_mpas,1), ubound(lat_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = lat_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, lat_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, med_mpi_comm, ierr2)

    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(taux_mpas,2), ubound(taux_mpas,2)
      do gi2 = lbound(taux_mpas,1), ubound(taux_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = taux_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, taux_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
      MPI_SUM, med_mpi_comm, ierr2)

    tmp2 = 0.0_ESMF_KIND_R8
    do gj2 = lbound(tauy_mpas,2), ubound(tauy_mpas,2)
      do gi2 = lbound(tauy_mpas,1), ubound(tauy_mpas,1)
        if (gi2 >= 1 .and. gi2 <= ATM_NX .and. gj2 >= 1 .and. gj2 <= ATM_NY) &
          tmp2(gi2,gj2) = tauy_mpas(gi2,gj2)
      end do
    end do
    call MPI_Allreduce(tmp2, tauy_g2, ATM_NX*ATM_NY, MPI_DOUBLE_PRECISION, &
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
          if (ii >= 1 .and. ii <= ATM_NX .and. jj >= 1 .and. jj <= ATM_NY) then
            ! so sobrescreve onde ha dado nativo real (fora do fill=0
            ! dos PETs sem tile MONAN-A local — mesmo criterio)
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
  end subroutine substitute_native_fluxes

  subroutine update_ice_fields_on_atm_grid(is, importState)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field) :: f_ifrac_src, f_avsdr_src, f_avsdf_src
    type(ESMF_Field) :: f_anidr_src, f_anidf_src, f_tice_src
    integer :: rc_ice
    real(ESMF_KIND_R8), pointer :: p_ifrac_out(:,:), p_vdr_out(:,:)
    real(ESMF_KIND_R8), pointer :: p_vdf_out(:,:), p_idr_out(:,:)
    real(ESMF_KIND_R8), pointer :: p_idf_out(:,:), p_tice_out(:,:)
    integer :: rc_nfe
    real(ESMF_KIND_R8), pointer :: omask_src(:,:)
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    type(ESMF_Field) :: omask_field
    integer :: lde_s
    integer :: ldec_ocn
    integer :: rc_omask
    integer :: rc_store
    integer :: n_land_ice
    integer :: n_sea_ice
    character(len=200) :: diag_msg_mask
    real(ESMF_KIND_R8), pointer :: p_ifrac_in(:,:)
    character(len=300) :: diag_msg_src
    integer :: rc_src
    integer :: rc_bs
    real(ESMF_KIND_R8), pointer :: p_ifrac_dst(:,:)
    character(len=300) :: diag_msg_dst
    integer :: rc_dst
    integer :: n_sent
    real(ESMF_KIND_R8), pointer :: p_ifrac_raw(:,:)
    character(len=250) :: diag_msg_raw
    integer :: n_exact_zero
    integer :: n_total
    real(ESMF_KIND_R8), parameter :: LAT_MAX_GELO = 55.0_ESMF_KIND_R8
    integer :: ii_geo
    integer :: jj_geo
    integer :: n_bad_geo
    real(ESMF_KIND_R8) :: lat_bad
    real(ESMF_KIND_R8) :: lon_bad
    real(ESMF_KIND_R8) :: val_bad
    character(len=250) :: diag_msg_geo
    real(ESMF_KIND_R8) :: lat_here
    real(ESMF_KIND_R8) :: lon_here

    call ESMF_StateGet(importState, itemName="Si_ifrac_sis2", &
      field=f_ifrac_src, rc=rc_ice)

    ! ── criar rh_ocn2atm_ice uma unica vez ────────
    ! Reusa a mascara de is%ocn_grid (So_omask, 1=oceano/0=terra) ja
    ! populada pelo bloco de So_t acima (rh_ocn2atm_sst) — idempotente
    ! se chamado de novo aqui, garantindo independencia de ordem.
    if (.not. is%regrid%has('ocn2atm_ice') .and. rc_ice == ESMF_SUCCESS) then
        n_land_ice = 0; n_sea_ice = 0
        call ESMF_StateGet(importState, itemName="So_omask", &
          field=omask_field, rc=rc_omask)
        if (rc_omask == ESMF_SUCCESS) then
          call ESMF_GridGet(is%ocn_grid, localDeCount=ldec_ocn, rc=rc_store)
          if (rc_store == ESMF_SUCCESS) then
            do lde_s = 0, ldec_ocn - 1
              call ESMF_FieldGet(omask_field, localDe=lde_s, &
                farrayPtr=omask_src, rc=rc_store)
              if (rc_store /= ESMF_SUCCESS .or. .not. associated(omask_src)) cycle
              call ESMF_GridGetItem(is%ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
                staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde_s, &
                farrayPtr=maskptr, rc=rc_store)
              if (rc_store == ESMF_SUCCESS .and. associated(maskptr)) then
                maskptr = nint(omask_src)
                ! conta terra/oceano vistos por
                ! ESTE PET, para confirmar que So_omask foi de fato
                ! encontrada e tem uma mistura sensata dos dois
                ! valores (nao tudo-terra nem tudo-oceano por engano).
                n_land_ice = n_land_ice + count(maskptr == 0)
                n_sea_ice  = n_sea_ice  + count(maskptr == 1)
              end if
            end do
          end if
        end if
        if (cfg_write_fixdiag) then
            write(diag_msg_mask,'(A,L1,A,I0,A,I0)') &
              'FIX-DIAG-ICEMASK-01: So_omask encontrada=', &
              (rc_omask == ESMF_SUCCESS), ' n_land=', n_land_ice, &
              ' n_sea=', n_sea_ice
            call ESMF_LogWrite(trim(diag_msg_mask), ESMF_LOGMSG_INFO)
        end if
        ! CONSERVE REATIVADO. O
        ! revertera para BILINEAR suspeitando de
        ! desalinhamento de indice canto<->centro por DE, mas ficou
        ! confirmado depois (usuario relatou e checamos) que a mesma
        ! mancha geografica implausivel JA' EXISTIA antes do CONSERVE
        ! entrar em cena -- ou seja, a causa nao era o metodo de
        ! regrid. A causa real era o alcance sem limite de
        ! NeighborFillExtrapolate (corrigido em),
        ! que "vazava" valor real de gelo por dezenas de graus de
        ! distancia atraves de qualquer regiao invalida grande —
        ! acontecia igual com BILINEAR ou CONSERVE por baixo, porque
        ! a extrapolacao roda DEPOIS do regrid, como pos-processamento
        ! independente do metodo. Com a causa raiz corrigida,
        ! reativa CONSERVE (fisica de conservacao de area, mais
        ! apropriado para fracao de gelo que bilinear pontual).
        call is%regrid%add('ocn2atm_ice', regrid_spec('conserve,bilinear', mask_src=.true.), &
          f_ifrac_src, is%f_ifrac_atm, rc_store, fallback='ocn2atm')
    end if

    ! ── sentinela fora da faixa valida + ─────────
    ! zeroregion=ESMF_REGION_SELECT em vez de ESMF_REGION_TOTAL.
    ! Causa raiz confirmada por com REGION_TOTAL,
    ! TODA celula nao-mapeada pelo regrid mascarado (bilinear perto do
    ! fold tripolar, onde o stencil de 4 vizinhos frequentemente nao
    ! fecha) virava 0,0 — um valor DENTRO da faixa valida [0,1], que a
    ! NeighborFillExtrapolate nunca detectava como invalido (~42-52%
    ! do dominio nos PETs polares, contra uma fisica real de SIS2
    ! saudavel confirmada por). REGION_SELECT so'
    ! escreve onde o regrid de fato mapeou algo, deixando o sentinela
    ! (fora de [0,1]) nas demais — agora sim detectavel e corrigivel
    ! pela extrapolacao de vizinhanca que ja existia.
    call FillInternalField(is%f_ifrac_atm,   -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%f_alb_vdr_ice,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%f_alb_vdf_ice,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%f_alb_idr_ice,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%f_alb_idf_ice,  -999.0_ESMF_KIND_R8, rc_ice)
    call FillInternalField(is%f_tice_atm,     -999.0_ESMF_KIND_R8, rc_ice)

    !--------------------------------------------------------------------
    ! o campo de ORIGEM, antes do regrid.
    !
    ! PARA QUE SERVE. A bateria de 18/09/2026 localizou a divergencia
    ! entre duas etapas: a mascara do regrid do gelo e' IDENTICA nas
    ! quatro execucoes (n_land=45 n_sea=355), e o ifrac de DESTINO, medido
    ! pelo logo apos o regrid e antes da
    ! extrapolacao, JA' diverge. Faltava saber de que lado da seta esta' a
    ! origem: se o Si_ifrac_sis2 que o SIS2 entrega ja' difere, o regrid
    ! e' mensageiro e o alvo e' o gelo; se ele e' identico e o destino
    ! difere, o alvo e' o regrid CONSERVE mascarado. Nao havia nenhum
    ! diagnostico do lado da origem: o, apesar do
    ! nome sugestivo, imprime f_ifrac_atm, que e' o DESTINO.
    !
    ! FORMATO. Quinze digitos significativos, e nao os quatro do
    ! ICEMASK-02. Com quatro digitos a divergencia so' apareceu na 12a
    ! troca de acoplamento, o que sugeria acumulo gradual; com quinze,
    ! sabe-se se ela comeca antes e estava apenas escondida pelo
    ! arredondamento da impressao. A SOMA global entra porque min e max
    ! nao detectam divergencia no meio da distribuicao.
    !
    ! ESCOPO. p_ifrac_in aponta para a fatia do DE local, entao os
    ! valores sao locais ao PET, nao globais. Divergencia aqui e'
    ! conclusiva; ausencia de divergencia neste PET nao exclui
    ! divergencia em outro, e os PETs polares sao os que importam para
    ! gelo. Comparar o mesmo PET entre execucoes, nunca PETs diferentes.
    !
    ! CUSTO. Tres reducoes locais sobre um campo 2D, uma vez por troca de
    ! acoplamento, atras de cfg_write_fixdiag. Nao altera comportamento.
    !--------------------------------------------------------------------
    if (cfg_write_fixdiag .and. rc_ice == ESMF_SUCCESS) then
        call ESMF_FieldGet(f_ifrac_src, farrayPtr=p_ifrac_in, rc=rc_src)
        if (rc_src == ESMF_SUCCESS .and. associated(p_ifrac_in)) then
          write(diag_msg_src,'(A,ES24.16,A,ES24.16,A,ES24.16,A,I0)') &
            'FIX-DIAG-ICESRC-01: Si_ifrac_sis2 (ORIGEM, pre-regrid)' // &
            ' min=', minval(p_ifrac_in), &
            ' max=', maxval(p_ifrac_in), &
            ' soma=', sum(p_ifrac_in),   &
            ' n_local=', size(p_ifrac_in)
          call ESMF_LogWrite(trim(diag_msg_src), ESMF_LOGMSG_INFO)
        else
          call ESMF_LogWrite('FIX-DIAG-ICESRC-01: farrayPtr de ' // &
            'Si_ifrac_sis2 indisponivel; origem NAO medida', &
            ESMF_LOGMSG_WARNING)
        end if
    end if

    ! (etapa 1 de 4): checksum exato, por PET, da
    ! ORIGEM (Si_ifrac_sis2 na grade do oceano), antes do regrid.
    if (cfg_write_fixdiag .and. rc_ice == ESMF_SUCCESS) then
        call diag_bitsum_log('etapa1 Si_ifrac_sis2 ORIGEM pre-regrid', &
                             f_ifrac_src, rc_bs)
    end if

    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_ifrac_src, is%f_ifrac_atm, rc_ice, &
        zero_total=.false.)

    !--------------------------------------------------------------------
    ! o campo de DESTINO com quinze digitos.
    !
    ! Par do ICESRC-01, medido no mesmo instante e no mesmo PET, logo
    ! apos o regrid e antes da extrapolacao. Existe porque o
    ! que mede o mesmo ponto, imprime quatro
    ! digitos e por isso nao permite comparar origem e destino na mesma
    ! precisao. Mantido separado do ICEMASK-02 para nao alterar o formato
    ! de um diagnostico que ja' tem historico de leitura.
    !--------------------------------------------------------------------
    if (cfg_write_fixdiag .and. rc_ice == ESMF_SUCCESS) then
        call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=p_ifrac_dst, rc=rc_dst)
        if (rc_dst == ESMF_SUCCESS .and. associated(p_ifrac_dst)) then
          ! A sentinela -999 marca celula nao mapeada pelo regrid; ela
          ! domina min e soma, entao entra contada a parte para que o
          ! numero de nao mapeadas seja comparavel entre execucoes.
          n_sent = count(p_ifrac_dst < -900.0_ESMF_KIND_R8)
          write(diag_msg_dst,'(A,ES24.16,A,ES24.16,A,I0,A,I0)') &
            'FIX-DIAG-ICESRC-02: f_ifrac_atm (DESTINO, pos-regrid)' // &
            ' max=', maxval(p_ifrac_dst), &
            ' soma_validos=', &
            sum(p_ifrac_dst, mask=(p_ifrac_dst > -900.0_ESMF_KIND_R8)), &
            ' n_sentinela=', n_sent, &
            ' n_local=', size(p_ifrac_dst)
          call ESMF_LogWrite(trim(diag_msg_dst), ESMF_LOGMSG_INFO)
        end if
    end if

    ! (etapa 2 de 4): f_ifrac_atm logo apos o regrid,
    ! antes da extrapolacao (celulas nao mapeadas ainda com -999).
    if (cfg_write_fixdiag .and. rc_ice == ESMF_SUCCESS) then
        call diag_bitsum_log('etapa2 f_ifrac_atm DESTINO pos-regrid', &
                             is%f_ifrac_atm, rc_bs)
    end if

    ! ifrac LOGO APOS o regrid bruto, ANTES da
    ! extrapolacao — conta celulas exatamente = 0.0 (candidato a
    ! "nao mapeado, zerado pelo zeroregion=TOTAL") separado de
    ! celulas com ifrac realmente pequeno mas nao-zero. Se
    ! n_exact_zero for uma fracao grande do total aqui, o problema
    ! esta' no regrid/mascara, nao na fisica do SIS2 (que ja' foi
    ! confirmada saudavel via).
    if (cfg_write_fixdiag) then
        call ESMF_FieldGet(is%f_ifrac_atm, farrayPtr=p_ifrac_raw, rc=rc_ice)
        if (associated(p_ifrac_raw)) then
          n_exact_zero = count(p_ifrac_raw == 0.0_ESMF_KIND_R8)
          n_total = size(p_ifrac_raw)
          write(diag_msg_raw,'(A,ES10.3,A,ES10.3,A,I0,A,I0)') &
            'FIX-DIAG-ICEMASK-02: ifrac (bruto, pre-extrapolacao) min=', &
            minval(p_ifrac_raw), ' max=', maxval(p_ifrac_raw), &
            ' | n_exact_zero=', n_exact_zero, ' de n_total=', n_total
          call ESMF_LogWrite(trim(diag_msg_raw), ESMF_LOGMSG_INFO)
        end if
        rc_ice = ESMF_SUCCESS
    end if

    call ESMF_StateGet(importState, itemName="Si_avsdr_sis2", &
      field=f_avsdr_src, rc=rc_ice)
    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_avsdr_src, is%f_alb_vdr_ice, rc_ice, &
        zero_total=.false.)

    call ESMF_StateGet(importState, itemName="Si_avsdf_sis2", &
      field=f_avsdf_src, rc=rc_ice)
    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_avsdf_src, is%f_alb_vdf_ice, rc_ice, &
        zero_total=.false.)

    call ESMF_StateGet(importState, itemName="Si_anidr_sis2", &
      field=f_anidr_src, rc=rc_ice)
    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_anidr_src, is%f_alb_idr_ice, rc_ice, &
        zero_total=.false.)

    call ESMF_StateGet(importState, itemName="Si_anidf_sis2", &
      field=f_anidf_src, rc=rc_ice)
    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_anidf_src, is%f_alb_idf_ice, rc_ice, &
        zero_total=.false.)

    ! Fase 3
    call ESMF_StateGet(importState, itemName="Si_t_sis2", &
      field=f_tice_src, rc=rc_ice)
    if (rc_ice == ESMF_SUCCESS) &
      call is%regrid%apply('ocn2atm_ice', f_tice_src, is%f_tice_atm, rc_ice, &
        zero_total=.false.)

    ! ── extrapolacao por vizinhanca pos-regrid ────
    ! Fecha buracos/costura na regiao de deformacao tripolar, mesmo
    ! algoritmo validado para So_t (NeighborFillExtrapolate), com
    ! faixa fisica valida e fallback proprios de cada campo.
    call ESMF_FieldGet(is%f_ifrac_atm,   farrayPtr=p_ifrac_out, rc=rc_nfe)
    if (associated(p_ifrac_out)) &
      call neighbor_fill(p_ifrac_out, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.0_ESMF_KIND_R8))

    ! (etapa 3 de 4): f_ifrac_atm depois da
    ! extrapolacao por vizinhanca.
    if (cfg_write_fixdiag) then
        call diag_bitsum_log('etapa3 f_ifrac_atm pos-extrapolacao', &
                             is%f_ifrac_atm, rc_bs)
    end if

    ! checagem de plausibilidade fisica
    ! independente de qual PET/componente e' dono de qual pedaco do
    ! dominio (a correspondencia PET<->geografia entre ICE/MED sob
    ! coupling_mode=concurrent + pet_layout=split se mostrou nao-trivial
    ! de inferir so' pelo numero do PET — ver conversa). Em vez de
    ! adivinhar, calcula lat/lon REAL (formula analitica da grade ATM
    ! 360x180, mesma usada em toda parte do arquivo) de qualquer
    ! celula com ifrac>0.05 fora da faixa |lat|<55 graus — limite
    ! generoso, pois gelo marinho real (Artico OU Antartico) nunca
    ! chega perto disso em nenhuma epoca do ano. Reporta a PRIMEIRA
    ! ocorrencia encontrada por PET, com a coordenada exata, para
    ! localizar o artefato sem depender de suposicao de PET.
    if (cfg_write_fixdiag .and. associated(p_ifrac_out)) then
        n_bad_geo = 0; lat_bad = -999.0_ESMF_KIND_R8
        lon_bad = -999.0_ESMF_KIND_R8; val_bad = -999.0_ESMF_KIND_R8
        do jj_geo = lbound(p_ifrac_out,2), ubound(p_ifrac_out,2)
          do ii_geo = lbound(p_ifrac_out,1), ubound(p_ifrac_out,1)
            if (p_ifrac_out(ii_geo,jj_geo) > 0.05_ESMF_KIND_R8) then
                lon_here = (real(ii_geo,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * &
                           (360.0_ESMF_KIND_R8/ATM_NX) + 0.5_ESMF_KIND_R8*(360.0_ESMF_KIND_R8/ATM_NX)
                lat_here = -90.0_ESMF_KIND_R8 + (real(jj_geo,ESMF_KIND_R8)-1.0_ESMF_KIND_R8) * &
                           (180.0_ESMF_KIND_R8/ATM_NY) + 0.5_ESMF_KIND_R8*(180.0_ESMF_KIND_R8/ATM_NY)
                if (abs(lat_here) < LAT_MAX_GELO) then
                  n_bad_geo = n_bad_geo + 1
                  if (lat_bad < -900.0_ESMF_KIND_R8) then
                    lat_bad = lat_here; lon_bad = lon_here
                    val_bad = p_ifrac_out(ii_geo,jj_geo)
                  end if
                end if
            end if
          end do
        end do
        if (n_bad_geo > 0) then
          write(diag_msg_geo,'(A,I0,A,ES10.3,A,ES10.3,A,ES10.3)') &
            'FIX-DIAG-ICEGEO-01: ALERTA -- ', n_bad_geo, &
            ' celula(s) com ifrac>0,05 em |lat|<55 (implausivel). ' // &
            'Primeira ocorrencia: lat=', lat_bad, ' lon=', lon_bad, &
            ' ifrac=', val_bad
          call ESMF_LogWrite(trim(diag_msg_geo), ESMF_LOGMSG_WARNING)
        end if
    end if

    call ESMF_FieldGet(is%f_alb_vdr_ice, farrayPtr=p_vdr_out, rc=rc_nfe)
    if (associated(p_vdr_out)) &
      call neighbor_fill(p_vdr_out, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.65_ESMF_KIND_R8))

    call ESMF_FieldGet(is%f_alb_vdf_ice, farrayPtr=p_vdf_out, rc=rc_nfe)
    if (associated(p_vdf_out)) &
      call neighbor_fill(p_vdf_out, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.65_ESMF_KIND_R8))

    call ESMF_FieldGet(is%f_alb_idr_ice, farrayPtr=p_idr_out, rc=rc_nfe)
    if (associated(p_idr_out)) &
      call neighbor_fill(p_idr_out, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.65_ESMF_KIND_R8))

    call ESMF_FieldGet(is%f_alb_idf_ice, farrayPtr=p_idf_out, rc=rc_nfe)
    if (associated(p_idf_out)) &
      call neighbor_fill(p_idf_out, regrid_fill_t(enabled=.true., &
        vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.65_ESMF_KIND_R8))

    call ESMF_FieldGet(is%f_tice_atm, farrayPtr=p_tice_out, rc=rc_nfe)
    if (associated(p_tice_out)) &
      call neighbor_fill(p_tice_out, regrid_fill_t(enabled=.true., &
        vmin=180.0_ESMF_KIND_R8, vmax=273.16_ESMF_KIND_R8, vfill=271.35_ESMF_KIND_R8))

    call ESMF_LogWrite('MED(B-ICEREGRID-01): Si_ifrac_sis2/Si_a*_sis2/' // &
      'Si_t_sis2 regridados via rh_ocn2atm_ice + extrapolacao de vizinhanca', &
      ESMF_LOGMSG_INFO)
  end subroutine update_ice_fields_on_atm_grid

  !> Preenche a SST na grade ATM onde a interpolação não trouxe valor
  !! válido (costa, costura tripolar): média dos vizinhos válidos, em até
  !! 40 passadas; o que sobrar recebe 271,35 K. Valores acima de 310 K
  !! recebem 271,35 K antes da difusão.
  subroutine fill_sst_gaps(sst)
    real(ESMF_KIND_R8), pointer :: sst(:,:)
    type(regrid_fill_t), parameter :: SST_FILL = regrid_fill_t(enabled=.true.,     &
    vmin=270.0_ESMF_KIND_R8, vmax=310.0_ESMF_KIND_R8, vfill=271.35_ESMF_KIND_R8, &
    max_iter=40, skip_fraction=1.0_ESMF_KIND_R8, overflow_to_fill=.true.)
    integer :: n_invalid, n_left
    character(len=120) :: msg

    n_invalid = count(.not. (sst >= SST_FILL%vmin .and. sst <= SST_FILL%vmax) &
                      .and. .not. (sst > SST_FILL%vmax))
    call neighbor_fill(sst, SST_FILL, n_left)
    if (n_invalid > 0) then
      write(msg,'(A,I0,A,I0,A)') 'MED: SST extrapolada em ', n_invalid, &
        ' celulas (', n_left, ' com valor fixo)'
      call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)
    end if
  end subroutine fill_sst_gaps

  subroutine set_ocean_mask_for_sst(is, importState, sst_ocn, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_Field), intent(inout) :: sst_ocn   !< So_t na grade do oceano
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer    :: omask_src(:,:)
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    type(ESMF_Field) :: omask_field
    integer :: lde_s, n_land, ldec_ocn, n_sea, rc_omask
    integer :: n_land_g(1), n_land_s(1), n_sea_g(1), n_sea_s(1)
    type(ESMF_VM) :: vm
    logical :: got_omask
    real(ESMF_KIND_R8), pointer :: sst_src(:,:)
    real(ESMF_KIND_R8), parameter :: LAND_FILL_MAX = 270.0_ESMF_KIND_R8

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
        n_land = 0; n_sea = 0
        call ESMF_GridGet(is%ocn_grid, localDeCount=ldec_ocn, rc=rc)
        if (rc == ESMF_SUCCESS) then
          do lde_s = 0, ldec_ocn - 1
            call ESMF_FieldGet(sst_ocn, localDe=lde_s, farrayPtr=sst_src, rc=rc)
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
    end if

    n_land_s(1) = n_land; n_sea_s(1) = n_sea
    call ESMF_VMAllReduce(vm, n_land_s, n_land_g, 1, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) n_land_g(1) = n_land
    call ESMF_VMAllReduce(vm, n_sea_s,  n_sea_g,  1, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) n_sea_g(1) = n_sea
    if (n_land_g(1) == 0 .or. n_sea_g(1) == 0) then
      ! Máscara ainda uniforme (bootstrap): So_t usa a rota ocn2atm neste
      ! passo e a rota mascarada é tentada de novo no próximo.
      call ESMF_LogWrite('MED: mascara oceanica uniforme, rota ocn2atm_sst adiada', &
        ESMF_LOGMSG_INFO)
    else
      ! Conservativo contorna a deformação da costura tripolar; bilinear
      ! mascarado se a grade não tiver cantos; ocn2atm como último recurso.
      call is%regrid%add('ocn2atm_sst', regrid_spec('conserve,bilinear', mask_src=.true.), &
        sst_ocn, is%f_sst_atm, rc, fallback='ocn2atm')
    end if
  end subroutine set_ocean_mask_for_sst

  subroutine log_atm_forcing_summary(uas_g, tas_g, psl_g, swdn_g, vas_g, shum_g, rain_g, lwdn_g, rc)
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: uas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: tas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: psl_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: swdn_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: vas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: shum_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: rain_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: lwdn_g(:,:)
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
        '   uas_g: nonzero=', n_nz_uas, '/', ATM_NX*ATM_NY, &
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
        '   NX_G=', ATM_NX, '  NY_G=', ATM_NY
      write(*,'(A)') '########################################'
      flush(6)
    end if
  end subroutine log_atm_forcing_summary


  !> Correntes oceânicas So_u/So_v para a grade ATM (rota ocn2atm).
  !! Com zero_on_error, a componente cuja interpolação falhar é zerada.
  subroutine regrid_ocean_currents(is, importState, zero_on_error)
    type(MED_InternalState), intent(inout) :: is
    type(ESMF_State),        intent(inout) :: importState
    logical,                 intent(in)    :: zero_on_error

    call regrid_one('So_u', is%f_uocn_atm)
    call regrid_one('So_v', is%f_vocn_atm)

  contains

    subroutine regrid_one(name, dst)
      character(len=*), intent(in)    :: name
      type(ESMF_Field), intent(inout) :: dst
      type(ESMF_Field) :: src
      integer :: rc_c

      call ESMF_StateGet(importState, itemName=name, field=src, rc=rc_c)
      if (rc_c /= ESMF_SUCCESS) return
      call is%regrid%apply('ocn2atm', src, dst, rc_c, zero_total=.true.)
      if (rc_c /= ESMF_SUCCESS .and. zero_on_error) call ZeroInternalField(dst, rc_c)
    end subroutine regrid_one

  end subroutine regrid_ocean_currents


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
    nx_a = ATM_NX;        ny_a = ATM_NY
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
    ! (v14.20): usar a VM do COMPONENTE, não a global — mesmo
    ! motivo já aplicado em DATM_cap.F90, DOCN_cap.F90 e docn_cap_netcdf.F90
    ! na v13.1. Este era o último ESMF_VMGetGlobal dentro de uma rotina de
    ! componente. Hoje o MED roda em todos os PETs nos dois layouts, então
    ! as duas VMs coincidem e o broadcast funciona; a chamada global passa a
    ! ser incorreta no instante em que o mediador ganhar uma petList própria,
    ! e falharia com deadlock, não com erro. ESMF_VMGetCurrent devolve a VM
    ! do componente em execução, tornando rootPet=0 local ao MED.
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

