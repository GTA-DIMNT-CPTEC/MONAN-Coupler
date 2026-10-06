!> @file med_init.F90
!! @brief Grades, campos e rotas da inicialização do mediador.
!!
!! Criação das grades internas ATM e OCN (com a verificação dos cantos da
!! grade OCN), realização dos campos dos componentes e dos campos internos.
!! As rotas da inicialização são criadas pela fase initialize_data, em
!! med_exchange.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_init_mod
  use ESMF
  use coupler_utils_mod, only: ChkErr
  use coupler_log_mod, only: COMP_MED, log_info, log_warning
  use coupler_config_mod, only: cfg_use_docn, cfg_mom6_mesh_ocn, &
                                cfg_use_sis2_dynamic
  use NUOPC, only: NUOPC_Realize
  use med_cap_types_mod, only: MED_InternalState, MED_KEYS, MED_FIELDS, med_field_index
  use cpl_fields_mod, only: CPL_NAME_LEN
  use cpl_map_mod, only: cpl_arrivals, cpl_current_config, cpl_config_t
  use cpl_grids_mod, only: cpl_latlon_grid, cpl_tripolar_grid, ORIGIN_EAST0, &
                           ORIGIN_EAST0_CORNER
  use med_cap_methods_mod, only: CreateInternalField, FillInternalField

  implicit none
  private

  public :: create_atm_grid
  public :: create_ocn_grid
  public :: realize_component_fields
  public :: create_internal_fields

contains

  !> @brief Malha de fluxo do mediador (atm_med): grade regular nx_atm x ny_atm,
  !! longitude a partir de 0 grau, com cantos para o método conservativo,
  !! construída por cpl_latlon_grid (cpl_grids).
  subroutine create_atm_grid(petCount, nx_atm, ny_atm, atm_grid, rc)
    integer, intent(in) :: petCount
    integer, intent(in) :: nx_atm
    integer, intent(in) :: ny_atm
    type(ESMF_Grid), intent(inout) :: atm_grid
    integer, intent(inout) :: rc

    call cpl_latlon_grid('atm_med', nx_atm, ny_atm, ORIGIN_EAST0, .true., petCount, &
                          atm_grid, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call log_info(COMP_MED, 'stagger CORNER da grade ATM preenchido')
  end subroutine create_atm_grid

  !> @brief Oceano no mediador (ocn_med), construído por cpl_grids: com o MOM6, a
  !! grade tripolar lida do supergrid (cfg_mom6_mesh_ocn), com centros e
  !! cantos reais (cpl_tripolar_grid); com o DOCN, a grade regular do OISST
  !! (cpl_latlon_grid, ORIGIN_EAST0_CORNER). Os dois com a decomposição
  !! cpl_regdecomp, um DE por PET, como a malha de fluxo. Os cantos são
  !! necessários ao método conservativo (peso por sobreposição de área, com
  !! os quatro cantos de cada célula); o stagger CENTER continua o de
  !! sempre para as rotas que o usam. Depois da construção, confere os
  !! cantos (check_corner_coordinates) e acrescenta o item de máscara,
  !! zerado (terra = SST de preenchimento, perto de 200 K, do MOM6).
  subroutine create_ocn_grid(petCount, nx_ocn, ny_ocn, ocn_grid, rc)
    integer, intent(in) :: petCount
    integer, intent(in) :: nx_ocn
    integer, intent(in) :: ny_ocn
    type(ESMF_Grid), intent(inout) :: ocn_grid
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), pointer :: coordX(:,:), coordY(:,:)
    integer :: lde_m
    integer :: localDeCount_ocn
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    nullify(coordX, coordY)

    if (cfg_use_docn) then
      ! DOCN/OISST: grade lat/lon regular de verdade; fórmula uniforme exata.
      call cpl_latlon_grid('ocn_med', nx_ocn, ny_ocn, ORIGIN_EAST0_CORNER, .true., &
                            petCount, ocn_grid, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    else
      ! MOM6 tripolar real: coordenadas T e vértices verdadeiros do supergrid
      ! ocean_hgrid.nc (não uniformes; convergem no polo Norte). Sem isso, o
      ! conector NUOPC OCN->MED interpola usando posições erradas e a costa
      ! fica sistematicamente deslocada em todo o domínio.
      call cpl_tripolar_grid('ocn_med', cfg_mom6_mesh_ocn, nx_ocn, ny_ocn, petCount, .true., &
                              ocn_grid, rc, comp=COMP_MED)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if
    call log_info(COMP_MED, 'stagger CORNER da grade OCN preenchido')

    ! Sanidade dos cantos lidos no último DE local: valores numa faixa física
    ! plausível (lon em [0,360), lat em [-90,90]), e não um bloco de zeros
    ! por leitura silenciosa malsucedida; o canto deve estar a uma fração de
    ! célula do centro da mesma célula, nunca idêntico nem muito distante.
    call ESMF_GridGet(ocn_grid, localDeCount=localDeCount_ocn, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (localDeCount_ocn > 0) then
      call ESMF_GridGetCoord(ocn_grid, coordDim=1, localDE=localDeCount_ocn-1, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordX, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call ESMF_GridGetCoord(ocn_grid, coordDim=2, localDE=localDeCount_ocn-1, &
        staggerloc=ESMF_STAGGERLOC_CORNER, farrayPtr=coordY, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if
    if (associated(coordX) .and. associated(coordY)) then
      call check_corner_coordinates(coordX, coordY)
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

  !> @brief Confere os cantos da grade OCN perto do polo (dobra tripolar):
  !! avisa se há célula quase degenerada ou salto de longitude muito maior
  !! que a média entre vizinhos.
  !! @param[in] coordX, coordY  cantos do DE local [graus]
  subroutine check_corner_coordinates(coordX, coordY)
    real(ESMF_KIND_R8), pointer :: coordX(:,:)
    real(ESMF_KIND_R8), pointer :: coordY(:,:)
    integer :: iN_c
    integer :: i_c
    integer :: jN_c
    real(ESMF_KIND_R8) :: dlon_step
    real(ESMF_KIND_R8) :: dlon_avg
    real(ESMF_KIND_R8) :: dlon_max_found
    real(ESMF_KIND_R8) :: dist_corner_min
    real(ESMF_KIND_R8) :: dist_here
    real(ESMF_KIND_R8) :: dlon_raw
    integer :: i_next
    ! Checagem específica da(s)
    ! última(s) linha(s) de j perto do polo (dobra tripolar). Só roda
    ! neste DE se ele de fato alcançar perto do polo (maxval(coordY)
    ! > 80) -- a maioria dos PETs não chega lá e não tem o que checar.
    ! Dois sintomas procurados, ambos assinatura de fold mal capturado
    ! ou célula degenerada perto do polo:
    !   (a) célula quase degenerada: distância entre cantos vizinhos
    !       (em i, na linha mais ao norte) próxima de zero -- área de
    !       célula colapsando, o que faz CONSERVE tratar aquela célula
    !       como praticamente inexistente (peso ~0), mesmo que fisicamente
    !       deva ter área finita.
    !   (b) salto de longitude entre células vizinhas em i, na mesma
    !       linha, muito maior que o espaçamento médio do resto da
    !       grade -- indica descontinuidade de índice através da dobra
    !       (dado de um lado do polo aparecendo ao lado do dado do
    !       lado oposto sem a rotação de 180 graus que o fold real exige).
    if (maxval(coordY) > 80.0_ESMF_KIND_R8) then
        iN_c = ubound(coordX,1); jN_c = ubound(coordX,2)
        dlon_avg = 0.0_ESMF_KIND_R8; dlon_max_found = 0.0_ESMF_KIND_R8
        dist_corner_min = huge(1.0_ESMF_KIND_R8)
        do i_c = lbound(coordX,1), iN_c
          ! Salto de longitude entre vizinhos em i, na linha mais ao
          ! norte (jN_c) -- usa a diferença angular MÍNIMA (trata
          ! travessia de 0/360 corretamente, para não confundir isso
          ! com um salto real de fold).
            i_next = merge(lbound(coordX,1), i_c+1, i_c == iN_c)
            dlon_raw = abs(coordX(i_next,jN_c) - coordX(i_c,jN_c))
            dlon_step = min(dlon_raw, 360.0_ESMF_KIND_R8 - dlon_raw)
            dlon_avg = dlon_avg + dlon_step
            dlon_max_found = max(dlon_max_found, dlon_step)
            ! Distância (aprox., em graus, sem correção de cos(lat) --
            ! suficiente para detectar colapso grosseiro de célula)
            dist_here = sqrt(dlon_step**2 + &
              (coordY(i_next,jN_c)-coordY(i_c,jN_c))**2)
            dist_corner_min = min(dist_corner_min, dist_here)
        end do
        dlon_avg = dlon_avg / real(iN_c - lbound(coordX,1) + 1, ESMF_KIND_R8)
        if (dist_corner_min < 1.0e-3_ESMF_KIND_R8) &
          call log_warning(COMP_MED, 'grade OCN: celula quase degenerada perto ' // &
            'do polo (distancia canto-canto < 1e-3 grau)')
        if (dlon_max_found > 5.0_ESMF_KIND_R8 * max(dlon_avg, 1.0e-6_ESMF_KIND_R8)) &
          call log_warning(COMP_MED, 'grade OCN: salto de longitude muito maior ' // &
            'que a media entre vizinhos na linha mais ao norte (dobra mal ' // &
            'capturada ou descontinuidade de indice)')
    end if
  end subroutine check_corner_coordinates

  !> @brief Realiza os campos anunciados em InitializeAdvertise, nas listas do mapa
  !! de acoplamento (cpl_arrivals, chaves MED_KEYS) e na mesma ordem de
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
    character(len=CPL_NAME_LEN), allocatable :: names(:)
    type(cpl_config_t) :: cfg

    cfg = cpl_current_config()
    call cpl_arrivals('MED@atm_med', .true., cfg, MED_KEYS, names)
    call realize_on_grid(importState, atm_grid, names, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cpl_arrivals('MED@ocn_med', .true., cfg, MED_KEYS, names)
    call realize_on_grid(importState, ocn_grid, names, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call cpl_arrivals('MED@ocn_med', .false., cfg, '', names)
    call realize_on_grid(exportState, ocn_grid, names, rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Fim normal da etapa: rc volta a indicar sucesso (um rc de falha
    ! tolerado acima não interrompe a inicialização).
    rc = ESMF_SUCCESS
  end subroutine realize_component_fields

  !> @brief Cria e realiza no State os campos nomes, real(8) no centro da grade,
  !! na ordem da lista. Para no primeiro erro.
  subroutine realize_on_grid(state, grid, names, rc)
    type(ESMF_State), intent(inout) :: state
    type(ESMF_Grid),  intent(in)    :: grid
    character(len=*), intent(in)    :: names(:)
    integer,          intent(inout) :: rc
    integer :: n
    type(ESMF_Field) :: tmp_field

    do n = 1, size(names)
      tmp_field = ESMF_FieldCreate(grid=grid, typekind=ESMF_TYPEKIND_R8, &
        staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(names(n)), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      call NUOPC_Realize(state, field=tmp_field, rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
  end subroutine realize_on_grid

  !> @brief Cria os campos internos do mediador na malha de fluxo, na ordem de
  !! MED_FIELDS, guarda-os no registro is%fields, liga os componentes do
  !! estado interno às entradas e os preenche com os valores iniciais.
  !!
  !! Os valores iniciais (tabela MED_FIELDS, em med_cap_types) valem até o
  !! primeiro passo: zero para os fluxos e as correntes (oceano em repouso);
  !! 1 na máscara do oceano (usada só para excluir terra, e "tudo oceano"
  !! até o primeiro regrid de So_omask não zera fluxos legítimos); a SST de
  !! reserva SST_BULK_FALLBACK (não zero, para o bulk não sair errático em
  !! t=0); o albedo do gelo ALB_ICE_DEFAULT, o mesmo de reserva do cap do
  !! gelo, e o de água aberta ALB_OCEAN_DEFAULT; o ponto de congelamento da
  !! água do mar nas temperaturas do gelo e composta; e a rugosidade 0,01 m,
  !! o mesmo cfg_zorl_default do cap do MPAS.
  !! @param[in]    is        estado interno do mediador
  !! @param[inout] atm_grid  grade ATM do mediador
  !! @param[inout] rc        código de retorno
  subroutine create_internal_fields(is, atm_grid, rc)
    type(MED_InternalState), pointer :: is
    type(ESMF_Grid), intent(inout) :: atm_grid
    integer, intent(inout) :: rc
    integer :: k

    do k = 1, size(MED_FIELDS)
      is%fields(k)%name = MED_FIELDS(k)%name
      call CreateInternalField(is%fields(k)%field, atm_grid, MED_FIELDS(k)%esmf_name, rc)
    end do
    call bind_internal_fields(is)
    do k = 1, size(MED_FIELDS)
      call FillInternalField(is%fields(k)%field, MED_FIELDS(k)%initial, rc)
    end do
  end subroutine create_internal_fields

  !> @brief Liga cada componente de is%ocn_flx, is%ocn, is%ice e is%sfc ao campo
  !! de mesmo nome de acoplamento no registro is%fields. O ESMF_Field é uma
  !! referência: componente e entrada do registro são o mesmo campo.
  !! @param[in] is  estado interno do mediador, com o registro preenchido
  subroutine bind_internal_fields(is)
    type(MED_InternalState), pointer :: is

    call bind(is%ocn_flx%taux,    'Foxx_taux')
    call bind(is%ocn_flx%tauy,    'Foxx_tauy')
    call bind(is%ocn_flx%sen,     'Foxx_sen')
    call bind(is%ocn_flx%evap,    'Foxx_evap')
    call bind(is%ocn_flx%lwnet,   'Foxx_lwnet')
    call bind(is%ocn_flx%swvdr,   'Foxx_swnet_vdr')
    call bind(is%ocn_flx%swvdf,   'Foxx_swnet_vdf')
    call bind(is%ocn_flx%swidr,   'Foxx_swnet_idr')
    call bind(is%ocn_flx%swidf,   'Foxx_swnet_idf')
    call bind(is%ocn_flx%rain,    'Faxa_rain')
    call bind(is%ocn_flx%snow,    'Faxa_snow')
    call bind(is%ocn_flx%pslv,    'Sa_pslv')
    call bind(is%ocn_flx%duu10n,  'So_duu10n')
    call bind(is%ocn%sst,         'So_t')
    call bind(is%ocn%u,           'So_u')
    call bind(is%ocn%v,           'So_v')
    call bind(is%ocn%omask,       'Sx_omask')
    call bind(is%ice%ifrac,       'Si_ifrac')
    call bind(is%ice%tice,        'Si_t_sis2')
    call bind(is%ice%alb_vdr,     'Si_avsdr_sis2')
    call bind(is%ice%alb_vdf,     'Si_avsdf_sis2')
    call bind(is%ice%alb_idr,     'Si_anidr_sis2')
    call bind(is%ice%alb_idf,     'Si_anidf_sis2')
    call bind(is%ice%taux,        'Fioi_taux')
    call bind(is%ice%tauy,        'Fioi_tauy')
    call bind(is%ice%sen,         'Fioi_sen')
    call bind(is%ice%evap,        'Fioi_evap')
    call bind(is%ice%lwnet,       'Fioi_lwnet')
    call bind(is%ice%swvdr,       'Fioi_swnet_vdr')
    call bind(is%ice%swvdf,       'Fioi_swnet_vdf')
    call bind(is%ice%swidr,       'Fioi_swnet_idr')
    call bind(is%ice%swidf,       'Fioi_swnet_idf')
    call bind(is%sfc%zorl,        'Sf_zorl')
    call bind(is%sfc%coszen,      'Faxa_coszen')
    call bind(is%sfc%albedo,      'Sf_albedo')
    call bind(is%sfc%tsfc,        'Sx_tsfc')

  contains

    !> Atribui ao componente o campo do registro com o nome dado; um nome
    !! fora do registro é erro de programação e para a execução.
    subroutine bind(field, name)
      type(ESMF_Field), intent(out) :: field
      character(len=*), intent(in)  :: name
      integer :: k

      k = med_field_index(is, name)
      if (k == 0) error stop 'bind_internal_fields: campo fora de MED_FIELDS'
      field = is%fields(k)%field
    end subroutine bind

  end subroutine bind_internal_fields

end module med_init_mod
