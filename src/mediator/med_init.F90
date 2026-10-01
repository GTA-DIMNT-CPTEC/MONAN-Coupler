!> @file med_init.F90
!! @brief Grades, campos e rotas da inicialização do mediador.
!!
!! Criação das grades internas ATM e OCN (com a verificação dos cantos da
!! grade OCN), realização dos campos dos componentes e dos campos internos,
!! e criação das rotas de interpolação em InitializeDataComplete.
!!
!! Separado de MED_cap.F90 sem mudar instruções (R-FASE8-01).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_init_mod
  use ESMF
  use regrid_manager_mod, only: regrid_spec
  use coupler_utils_mod, only: ChkErr
  use mom6_supergrid_mod, only: mom6_supergrid_tcoords, mom6_supergrid_corners
  use coupler_config_mod, only: cfg_use_docn, cfg_mom6_mesh_ocn, &
                                cfg_use_sis2_dynamic
  use NUOPC, only: NUOPC_Realize
  use med_cap_types_mod, only: MED_InternalState, MED_CHAVES, SST_BULK_FALLBACK
  use cpl_fields_mod, only: CPL_NOME_LEN
  use cpl_map_mod, only: cpl_chegadas, cpl_config_atual, cpl_config_t
  use cpl_grids_mod, only: cpl_malha_latlon, cpl_regdecomp, ORIGEM_LESTE0
  use med_cap_methods_mod, only: CreateInternalField, ZeroInternalField, &
                                 ZeroOcnFluxFields, FillInternalField
  use med_ocean_mod, only: regrid_ocean_currents
  use coupler_constants_mod, only: T_FREEZE_SEAWATER, ALB_OCEAN_DEFAULT, ALB_ICE_DEFAULT

  implicit none
  private

  public :: create_atm_grid
  public :: create_ocn_grid
  public :: realize_component_fields
  public :: create_internal_fields
  public :: idc_create_routes

contains

  !> Malha de fluxo do mediador (atm_med): grade regular nx_atm x ny_atm,
  !! longitude a partir de 0 grau, com cantos para o método conservativo,
  !! construída por cpl_malha_latlon (cpl_grids).
  subroutine create_atm_grid(petCount, nx_atm, ny_atm, atm_grid, rc)
    integer, intent(in) :: petCount
    integer, intent(in) :: nx_atm
    integer, intent(in) :: ny_atm
    type(ESMF_Grid), intent(inout) :: atm_grid
    integer, intent(inout) :: rc

    call cpl_malha_latlon('atm_med', nx_atm, ny_atm, ORIGEM_LESTE0, .true., petCount, &
                          atm_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_LogWrite('MED B-CONSERVE-01: stagger CORNER da grade ATM ' // &
      'preenchido (sem erro ate aqui)', ESMF_LOGMSG_INFO)
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
    regDecomp = cpl_regdecomp(petCount, nx_ocn, ny_ocn)
    ! Invariante: regDecomp(1)*regDecomp(2) == petCount (1 DE por PET).
    ! ESMF_INDEX_GLOBAL: consistência com atm_grid para med_write_import_fields.
    ! Longitude periodica (periodicDim=1): o ESMF trata a coluna i=nx_ocn
    ! (longitude ~360) e a coluna i=1 (longitude ~0) como vizinhas. Sem isso,
    ! o regrid bilinear trata a borda leste/oeste como limite de dominio e
    ! deixa uma coluna de celulas "sem vizinho valido" na costura (no MOM6,
    ! uma faixa de valores indefinidos no Oceano Indico, ~60E, onde o
    ! intervalo nativo -300..60 do supergrid fecha).
    ! polekindflag fica no padrao do ESMF, como na grade ATM: a linha j=1
    ! (-78°, borda da Antartida) e a dobra norte NAO sao pontos geometricos
    ! unicos, e declara-las MONOPOLE e' fisicamente incorreto. Uma tentativa
    ! de faze-lo coincidiu com SIGSEGV em core_run do MPAS-A, atribuido a
    ! pesos de regrid corrompidos perto dos polos e da dobra.
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

    ! Stagger CORNER, necessario para
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

    ! Sanidade dos cantos lidos — confirma que os
    ! valores estao numa faixa fisica plausivel (lon em [0,360), lat em
    ! [-90,90]) e nao sao um bloco de zeros/garbage por leitura silenciosa
    ! mal-sucedida. Compara tambem com o CENTRO da mesma celula (i1,j1
    ! deste DE): o canto deve estar a uma fracao de celula de distancia do
    ! centro, nunca identico nem absurdamente distante.
    if (associated(coordX) .and. associated(coordY)) then
      call check_corner_coordinates(ocn_grid, localDeCount_ocn, coordX, coordY)
    end if

    ! Item de MÁSCARA na grade OCN (terra = SST fill ≈200 K do MOM6).
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

    ! Checagem especifica da(s)
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

  !> Realiza os campos anunciados em InitializeAdvertise, nas listas do mapa
  !! de acoplamento (cpl_chegadas, chaves MED_CHAVES) e na mesma ordem de
  !! antes: a importação da malha de fluxo na grade ATM; a importação da
  !! grade do oceano (So_t, So_u, So_v, So_omask e, com o SIS2, os campos
  !! *_sis2) na grade OCN, a grade nativa desses campos (o SIS2 usa a mesma
  !! ocean_hgrid.nc); a exportação na grade OCN. Todos real(8), no centro.
  subroutine realize_component_fields(is, importState, exportState, atm_grid, ocn_grid, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Grid), intent(in) :: atm_grid
    type(ESMF_Grid), intent(in) :: ocn_grid
    integer, intent(inout) :: rc
    character(len=CPL_NOME_LEN), allocatable :: nomes(:)
    type(cpl_config_t) :: cfg

    cfg = cpl_config_atual()
    call cpl_chegadas('MED@atm_med', .true., cfg, MED_CHAVES, nomes)
    call realize_on_grid(importState, atm_grid, nomes, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cpl_chegadas('MED@ocn_med', .true., cfg, MED_CHAVES, nomes)
    call realize_on_grid(importState, ocn_grid, nomes, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cpl_chegadas('MED@ocn_med', .false., cfg, '', nomes)
    call realize_on_grid(exportState, ocn_grid, nomes, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Fim normal da etapa: rc volta a indicar sucesso (um rc de falha
    ! tolerado acima não interrompe a inicialização).
    rc = ESMF_SUCCESS
  end subroutine realize_component_fields

  !> Cria e realiza no State os campos nomes, real(8) no centro da grade,
  !! na ordem da lista. Para no primeiro erro.
  subroutine realize_on_grid(state, grid, nomes, rc)
    type(ESMF_State), intent(inout) :: state
    type(ESMF_Grid),  intent(in)    :: grid
    character(len=*), intent(in)    :: nomes(:)
    integer,          intent(inout) :: rc
    integer :: n
    type(ESMF_Field) :: tmp_field

    do n = 1, size(nomes)
      tmp_field = ESMF_FieldCreate(grid=grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(nomes(n)), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(state, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
  end subroutine realize_on_grid

  subroutine create_internal_fields(is, atm_grid, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_Grid), intent(inout) :: atm_grid
    integer, intent(inout) :: rc
    call CreateInternalField(is%ocn_flx%taux,   atm_grid, "med_taux",   rc)
    call CreateInternalField(is%ocn_flx%tauy,   atm_grid, "med_tauy",   rc)
    call CreateInternalField(is%ocn_flx%sen,    atm_grid, "med_sen",    rc)
    call CreateInternalField(is%ocn_flx%evap,   atm_grid, "med_evap",   rc)
    call CreateInternalField(is%ocn_flx%lwnet,  atm_grid, "med_lwnet",  rc)
    call CreateInternalField(is%ocn_flx%swvdr,  atm_grid, "med_swvdr",  rc)
    call CreateInternalField(is%ocn_flx%swvdf,  atm_grid, "med_swvdf",  rc)
    call CreateInternalField(is%ocn_flx%swidr,  atm_grid, "med_swidr",  rc)
    call CreateInternalField(is%ocn_flx%swidf,  atm_grid, "med_swidf",  rc)
    call CreateInternalField(is%ocn_flx%rain,   atm_grid, "med_rain",   rc)
    call CreateInternalField(is%ocn_flx%snow,   atm_grid, "med_snow",   rc)
    call CreateInternalField(is%ocn_flx%pslv,   atm_grid, "med_pslv",   rc)
    call CreateInternalField(is%ice%ifrac,  atm_grid, "med_ifrac",  rc)
    ! mascara terra/oceano real na grade ATM (1=oceano,
    ! 0=terra). Default 1.0 (oceano) ate' o primeiro regrid de So_omask —
    ! seguro porque so' e' USADA para EXCLUIR terra, nao para validar
    ! oceano; ficar em "tudo oceano" ate' o regrid real e' menos arriscado
    ! do que ficar em "tudo terra" (zeraria fluxos legitimos ate' la').
    call CreateInternalField(is%ocn%omask,  atm_grid, "med_omask",  rc)
    call FillInternalField(is%ocn%omask, 1.0_ESMF_KIND_R8, rc)
    call CreateInternalField(is%ocn_flx%duu10n, atm_grid, "med_duu10n", rc)
    ! is%ocn%sst: campo de SST interpolado para a grade ATM (destino do OCN->ATM)
    call CreateInternalField(is%ocn%sst,    atm_grid, "med_sst",    rc)
    ! Correntes oceânicas interpoladas OCN → ATM.
    ! Usadas no cálculo de So_duu10n = |(V_atm − V_ocn)|² (protocolo CMEPS).
    call CreateInternalField(is%ocn%u,   atm_grid, "med_uocn",   rc)
    call CreateInternalField(is%ocn%v,   atm_grid, "med_vocn",   rc)
    ! rugosidade Charnock + Smith — calculada no MED e enviada ao MPAS.
    call CreateInternalField(is%sfc%zorl,   atm_grid, "med_zorl",   rc)
    ! albedo do gelo por banda, regridado do SIS2.
    call CreateInternalField(is%ice%alb_vdr, atm_grid, "med_albvdr_ice", rc)
    call CreateInternalField(is%ice%alb_vdf, atm_grid, "med_albvdf_ice", rc)
    call CreateInternalField(is%ice%alb_idr, atm_grid, "med_albidr_ice", rc)
    call CreateInternalField(is%ice%alb_idf, atm_grid, "med_albidf_ice", rc)
    call CreateInternalField(is%sfc%coszen,  atm_grid, "med_coszen",     rc)
    call CreateInternalField(is%sfc%albedo,  atm_grid, "med_albedo",     rc)
    ! Temperatura do gelo na grade ATM
    call CreateInternalField(is%ice%tice,    atm_grid, "med_tice",       rc)
    ! Temperatura composta (Sx_tsfc) e fluxos turbulentos e de onda longa do gelo
    call CreateInternalField(is%sfc%tsfc,    atm_grid, "med_tsfc_comp",  rc)
    call CreateInternalField(is%ice%taux,    atm_grid, "med_taux_ice",   rc)
    call CreateInternalField(is%ice%tauy,    atm_grid, "med_tauy_ice",   rc)
    call CreateInternalField(is%ice%sen,     atm_grid, "med_sen_ice",    rc)
    call CreateInternalField(is%ice%evap,    atm_grid, "med_evap_ice",   rc)
    call CreateInternalField(is%ice%lwnet,   atm_grid, "med_lwnet_ice",  rc)
    ! Onda curta liquida sobre o gelo, por banda
    call CreateInternalField(is%ice%swvdr,   atm_grid, "med_swvdr_ice",  rc)
    call CreateInternalField(is%ice%swvdf,   atm_grid, "med_swvdf_ice",  rc)
    call CreateInternalField(is%ice%swidr,   atm_grid, "med_swidr_ice",  rc)
    call CreateInternalField(is%ice%swidf,   atm_grid, "med_swidf_ice",  rc)

    ! Zerar campos internos
    call ZeroOcnFluxFields(is%ocn_flx, rc)
    call ZeroInternalField(is%ice%ifrac,  rc)
    call ZeroInternalField(is%ocn_flx%duu10n, rc)
    ! fallback nao-zero (ALB_ICE_DEFAULT, o mesmo valor que o cap do gelo usa
    ! como ALBEDO_ICE_FALLBACK) ate o primeiro regrid real do gelo — evita
    ! um albedo de gelo erroneamente zero (que superestimaria absorcao de
    ! SW) no bootstrap, mesma logica de SST_BULK_FALLBACK abaixo.
    call FillInternalField(is%ice%alb_vdr, ALB_ICE_DEFAULT, rc)
    call FillInternalField(is%ice%alb_vdf, ALB_ICE_DEFAULT, rc)
    call FillInternalField(is%ice%alb_idr, ALB_ICE_DEFAULT, rc)
    call FillInternalField(is%ice%alb_idf, ALB_ICE_DEFAULT, rc)
    call ZeroInternalField(is%sfc%coszen, rc)
    call FillInternalField(is%sfc%albedo, ALB_OCEAN_DEFAULT, rc)
    ! T_gelo default = ponto de congelamento da agua do mar; fluxos
    ! turbulentos do gelo comecam zerados ate o 1o calc_bulk_ncar real.
    call FillInternalField(is%ice%tice,   T_FREEZE_SEAWATER, rc)
    call FillInternalField(is%sfc%tsfc,   T_FREEZE_SEAWATER, rc)
    call ZeroInternalField(is%ice%taux,  rc)
    call ZeroInternalField(is%ice%tauy,  rc)
    call ZeroInternalField(is%ice%sen,   rc)
    call ZeroInternalField(is%ice%evap,  rc)
    call ZeroInternalField(is%ice%lwnet, rc)
    ! comeca zerado ate o 1o calc_bulk_ncar real,
    ! mesma logica de is%ice%sen/is%ice%lwnet acima.
    call ZeroInternalField(is%ice%swvdr, rc)
    call ZeroInternalField(is%ice%swvdf, rc)
    call ZeroInternalField(is%ice%swidr, rc)
    call ZeroInternalField(is%ice%swidf, rc)
    ! Inicializa SST com valor padrao (nao zero, para evitar bulk erratico no t=0)
    call FillInternalField(is%ocn%sst, SST_BULK_FALLBACK, rc)
    ! Valor de bootstrap: será substituído no primeiro passo pelo So_t do DOCN/MOM6.
    ! correntes oceânicas inicializadas a zero (oceano em repouso).
    ! Serão regridadas de So_u/So_v a partir do primeiro passo de acoplamento.
    call ZeroInternalField(is%ocn%u, rc)
    call ZeroInternalField(is%ocn%v, rc)
    ! rugosidade inicial = 0.01 m (mesmo cfg_zorl_default do cap MPAS).
    ! Substituida no primeiro passo pela parametrizacao Charnock no bulk NCAR.
    call FillInternalField(is%sfc%zorl, 0.01_ESMF_KIND_R8, rc)
  end subroutine create_internal_fields

  !> Fase A de InitializeDataComplete: cria as rotas 'atm2ocn' (de
  !! is%ocn_flx%taux para exp_field, na grade OCN) e 'ocn2atm', interpola as
  !! correntes e preenche o exportState com valores iniciais. Roda uma unica
  !! vez (enquanto a rota 'ocn2atm' nao existe).
  subroutine idc_create_routes(is, importState, exportState, exp_field, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_State), intent(inout) :: importState
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field), intent(inout) :: exp_field
    integer, intent(inout) :: rc
    type(ESMF_Field) :: ocn_field

    if (.not. is%regrid%has('atm2ocn')) then
      call is%regrid%add('atm2ocn', regrid_spec('nearest_stod'), is%ocn_flx%taux, exp_field, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if

    ! So_t está na grade OCN (ver InitializeRealize)
    call ESMF_StateGet(importState, itemName="So_t", field=ocn_field, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call is%regrid%add('ocn2atm', regrid_spec('bilinear'), ocn_field, is%ocn%sst, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Correntes So_u/So_v: mesma grade de So_t, mesma rota.
    call regrid_ocean_currents(is, importState, zero_on_error=.true.)

    call idc_init_export_fields(exportState)

    ! Si_ifrac_sis2 e os 4 albedos do gelo sao realizados pelo MED em
    ! ocn_grid, a MESMA grade de So_t (ver InitializeRealize); a rota
    ! mascarada propria do gelo, 'ocn2atm_ice', e' criada na primeira chamada
    ! de update_ice_fields_on_atm_grid.

    call ESMF_LogWrite('MED: IDC fase A: rotas de interpolacao criadas', ESMF_LOGMSG_INFO)
  end subroutine idc_create_routes

  !> Inicializa o exportState com valores fisicamente razoaveis: Sa_pslv
  !! com 101325 Pa e os demais campos com zero. PETs sem DE local nao tem o
  !! que inicializar (ESMF_FieldGet com farrayPtr falharia neles).
  subroutine idc_init_export_fields(exportState)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field) :: exp_field
    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    character(len=64), allocatable :: fieldNameList(:)
    integer :: fieldCount
    integer :: i
    integer :: localDeCount_exp
    integer :: localrc
    integer :: rc

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
  end subroutine idc_init_export_fields

end module med_init_mod
