!> @file mom_si_ifrac.F90
!! @brief Fração de gelo Si_ifrac exportada pelo cap do oceano (MOM6).
!!
!! ocean_public_type não expõe a fração de gelo, então o cap a obtém de
!! uma de duas formas, conforme nuopc.input (&nuopc_mode):
!!   set_si_ifrac_from_file  lê o arquivo OISST (use_docn_ice), com
!!                           interpolação temporal e vizinho mais próximo;
!!   compute_si_ifrac_proxy  deriva da SST e do frazil do MOM6 (sigmoide),
!!                           com persistência do valor anterior.
!! A memória entre passos (si_ifrac_memory_t) fica no estado interno do cap.
!!
!! Como o cap, é compilado com as opções do MOM6 (lista MOM6_SRCS do Makefile).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module mom_si_ifrac_mod

  use ESMF
  use coupler_constants_mod, only : SI_IFRAC_DECAY, T_FREEZE => T_FREEZE_SEAWATER
  use coupler_log_mod, only : COMP_OCN, log_warning, log_info, log_debug
  use MOM_cap_methods,       only : ChkErr
  ! Leitura de Si_ifrac do arquivo OISST (use_docn_ice)
  use docn_cap_netcdf_mod,   only : ReadOcnFieldInterp
  use cpl_grids_mod,         only : index_trunc, lon_0to360_loop
  use coupler_config_mod,    only : cfg_docn_ice_file,       &
                                     cfg_docn_ice_varname,    &
                                     cfg_docn_ice_pct,        &
                                     cfg_docn_nx, cfg_docn_ny
  use MOM_ocean_model_nuopc, only : ocean_public_type
  use MOM_grid,              only : ocean_grid_type
  use mpp_domains_mod,       only : mpp_get_compute_domain

  implicit none
  private

  public :: si_ifrac_memory_t
  public :: set_si_ifrac_from_file
  public :: compute_si_ifrac_proxy

  ! Persistência de Si_ifrac entre passos de acoplamento
  !
  ! compute_si_ifrac_proxy calcula Si_ifrac do zero a cada passo; sem
  ! memória, o gelo lido do OISST em t=0 sumiria no passo seguinte. Por
  ! isso a memória de Si_ifrac (ifrac_mem%field) guarda o campo do passo
  ! anterior, e o novo Si_ifrac é
  !   Si_ifrac(t) = max(proxy(t), ifrac_mem%field(t-1) × SI_IFRAC_DECAY)
  ! de modo que o gelo inicial persista e decaia gradualmente.
  !
  ! SI_IFRAC_DECAY = exp(-dt_coupling / tau_melt)
  !   com tau_melt = 86400 s (1 dia) e dt_coupling = 3600 s (1 h):
  !   decay = exp(-1/24) ≈ 0.9592 por passo de 1 hora.
  !   Após 24 h: ≈ 37% do valor inicial; após 48 h: ≈ 14%; após 7 dias: < 1%.
  !
  ! SI_IFRAC_DECAY vem de coupler_constants_mod (≈ exp(-1/24)).

  !> Memória de Si_ifrac entre passos de acoplamento, guardada no estado
  !! interno do componente (ocn_internal_state_type%ifrac_mem).
  type :: si_ifrac_memory_t
    !> campo Si_ifrac do passo anterior (grade local do ESMF)
    real(ESMF_KIND_R8), allocatable :: field(:,:)
    !> .true. depois que field foi preenchido
    logical :: valid = .false.
  end type si_ifrac_memory_t

contains

  !> @brief Preenche Si_ifrac a partir do arquivo OISST (use_docn_ice).
  !!
  !! O campo Si_ifrac usa ESMF_GEOMTYPE_GRID (2D), definido pela chamada
  !! a mom_set_geomtype(ESMF_GEOMTYPE_GRID) em InitializeRealize.
  !! Portanto ESMF_FieldGet com farrayPtr 2D é válido.
  !!
  !! Algoritmo:
  !!   1. PET0 lê o arquivo OISST via ReadOcnFieldInterp (broadcast global).
  !!   2. Para cada célula MOM6, converte coordenadas geográficas (geolonT,
  !!      geolatT) em índices OISST por nearest-neighbor.
  !!   3. Copia diretamente para ptr_ifrac(:,:) do campo Si_ifrac no exportState.
  !!   4. Aplica máscara terra (mask2dT == 0 → 0) e clamping [0,1].
  !!   5. Guarda o campo em ifrac_mem%field, para a persistência nos passos
  !!      seguintes (compute_si_ifrac_proxy).
  !!
  !! @param[in]    gcomp        Componente ESMF OCN
  !! @param[in]    ocean_grid   Grade MOM6 (mask2dT, geolonT, geolatT)
  !! @param[inout] exportState  Campo Si_ifrac (2D, GRID) a preencher
  !! @param[inout] ifrac_mem    memória de Si_ifrac do estado interno
  !! @param[out]   rc           Código de retorno ESMF
  subroutine set_si_ifrac_from_file(gcomp, ocean_grid, exportState, ifrac_mem, rc)
    type(ESMF_GridComp),            intent(in)    :: gcomp
    type(ocean_grid_type), pointer, intent(in)    :: ocean_grid
    type(ESMF_State),               intent(inout) :: exportState
    type(si_ifrac_memory_t),        intent(inout) :: ifrac_mem
    integer,                        intent(out)   :: rc

    type(ESMF_Clock)            :: clock
    type(ESMF_Time)             :: currTime
    type(ESMF_Field)            :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ice_global(:,:) => null()
    integer :: nx, ny
    integer :: isc, iec, jsc, jec
    integer :: i, j, ig, jg
    integer :: i_oisst, j_oisst
    integer :: localDeCount_f
    real(ESMF_KIND_R8) :: dx, dy
    real(ESMF_KIND_R8) :: lon_c, lat_c
    integer :: lb1, ub1, lb2, ub2
    character(len=256) :: logmsg

    rc = ESMF_SUCCESS

    ! 1. Relógio corrente
    call ESMF_GridCompGet(gcomp, clock=clock, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    call ESMF_ClockGet(clock, currTime=currTime, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! 2. Ler OISST globalmente via ReadOcnFieldInterp
    nx = cfg_docn_nx
    ny = cfg_docn_ny
    dx = 360.0_ESMF_KIND_R8 / real(nx, ESMF_KIND_R8)
    dy = 180.0_ESMF_KIND_R8 / real(ny, ESMF_KIND_R8)

    ! ReadOcnFieldInterp exige pointer — alocar com bounds globais (1:nx, 1:ny).
    ! PET0 lê e interpola; ESMF_VMBroadcast distribui ice_global para todos.
    allocate(ice_global(nx, ny))
    ice_global = 0.0_ESMF_KIND_R8

    call ReadOcnFieldInterp(gcomp, trim(cfg_docn_ice_file),  &
                            trim(cfg_docn_ice_varname),      &
                            currTime, nx, ny, ice_global, rc)
    if (rc /= ESMF_SUCCESS) then
      call log_warning(COMP_OCN, 'set_si_ifrac_from_file: ReadOcnFieldInterp falhou')
      deallocate(ice_global); return
    end if

    if (cfg_docn_ice_pct) ice_global = ice_global / 100.0_ESMF_KIND_R8
    ice_global = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ice_global))

    ! 3. Verificar grade MOM6
    if (.not. associated(ocean_grid)) then
      deallocate(ice_global); return
    end if

    ! 4. Obter ponteiro do campo Si_ifrac (2D, GRID)
    call ESMF_StateGet(exportState, itemName='Si_ifrac', field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      deallocate(ice_global); return
    end if

    ! Guard PETs sem DE local não acessam farrayPtr
    call ESMF_FieldGet(f_ifrac, localDeCount=localDeCount_f, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localDeCount_f == 0) then
      deallocate(ice_global)
      rc = ESMF_SUCCESS; return
    end if

    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) then
      deallocate(ice_global); return
    end if

    ! Inicializar com zero (terra e oceano sem cobertura)
    ptr_ifrac = 0.0_ESMF_KIND_R8

    ! 5. Domínio computacional MOM6 e bounds do campo ESMF
    call mpp_get_compute_domain(ocean_grid%Domain%mpp_domain, &
                                isc, iec, jsc, jec)
    lb1 = lbound(ptr_ifrac, 1);  ub1 = ubound(ptr_ifrac, 1)
    lb2 = lbound(ptr_ifrac, 2);  ub2 = ubound(ptr_ifrac, 2)

    ! 6. Mapeamento nearest-neighbor MOM6 → OISST
    ! Usa ocean_grid%geolonT e ocean_grid%geolatT (graus, já definidos no MOM6).
    ! Grade OISST regular: lon ∈ [0°,360°), lat ∈ [-90°,+90°].
    do j = jsc, jec
      jg = j + ocean_grid%jsc - jsc
      do i = isc, iec
        ig = i + ocean_grid%isc - isc
        ! Pular terra
        if (ocean_grid%mask2dT(ig, jg) <= 0.0_ESMF_KIND_R8) cycle

        ! Coordenadas geográficas do centro da célula [°]
        lon_c = ocean_grid%geolonT(ig, jg)
        lat_c = ocean_grid%geolatT(ig, jg)

        ! Normalizar longitude para [0°, 360°)
        lon_c = lon_0to360_loop(lon_c)

        ! Índice OISST nearest-neighbor (base 1)
        i_oisst = index_trunc(lon_c, dx, nx)
        j_oisst = index_trunc(lat_c + 90.0_ESMF_KIND_R8, dy, ny)

        ! Copiar para campo ESMF (índice local lb1+i-isc, lb2+j-jsc)
        ptr_ifrac(lb1 + i - isc, lb2 + j - jsc) = &
          max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ice_global(i_oisst, j_oisst)))
      end do
    end do

    deallocate(ice_global)

    ! Salvar o campo OISST em ifrac_mem%field (persistência)
    ! O salvamento fica APÓS o preenchimento do campo e fora de qualquer
    ! guarda de PET: todos os PETs com DE local chegam aqui.
    if (.not. allocated(ifrac_mem%field)) then
      allocate(ifrac_mem%field(lb1:ub1, lb2:ub2))
      ifrac_mem%field = 0.0_ESMF_KIND_R8
    end if
    ifrac_mem%field = ptr_ifrac
    ifrac_mem%valid = .true.

    write(logmsg,'(A,I0,A,I0,A,I0,A,I0,A)') &
      'si_ifrac_mem salvo: bounds=[', lb1, ':', ub1, ',', lb2, ':', ub2, ']'
    call log_info(COMP_OCN, trim(logmsg))
    call log_info(COMP_OCN, 'Si_ifrac lido de '//trim(cfg_docn_ice_file))

  end subroutine set_si_ifrac_from_file

  !> @brief Fração de gelo derivada da SST e do frazil do MOM6 (sigmoide).
  !!
  !! ocean_public_type NÃO expõe fração de gelo, então o cap a deriva de
  !! variáveis disponíveis em ocean_public, como aproximação termodinâmica
  !! (a fração real do SIS2 vem do cap do gelo, como Si_ifrac_sis2).
  !!
  !! FORMULAÇÃO, nas células de oceano (mask2dT > 0):
  !!   Si_ifrac = clamp( max(F_frazil, F_temp), 0, 1 )
  !!   F_frazil = min(1, frazil / FRAZIL_SCALE), FRAZIL_SCALE = 100 W/m²
  !!   F_temp   = 1 / (1 + exp((T_surf - T_c) / DT_TRANS))
  !!     com T_c = 271.35 K (congelamento da água do mar) e DT_TRANS = 2.0 K.
  !! Em seguida, a persistência: max(Si_ifrac, ifrac_mem%field × SI_IFRAC_DECAY).
  !!
  !! AMOSTRAS DE F_temp:
  !!   T_surf = 270.0 K  → 0.66
  !!   T_surf = 271.35 K → 0.50
  !!   T_surf = 273.15 K → 0.29
  !!   T_surf = 275.0 K  → 0.14
  !!   T_surf = 280.6 K  → 0.01
  !!
  !! A transição contínua na zona marginal de gelo evita artefatos de
  !! "tudo ou nada" no regrid OCN→ATM e captura gelo estável onde frazil = 0.
  subroutine compute_si_ifrac_proxy(ocean_public, ocean_grid, exportState, ifrac_mem, rc)
    type(ocean_public_type),       intent(in)    :: ocean_public
    type(ocean_grid_type), pointer, intent(in)   :: ocean_grid
    type(ESMF_State),              intent(inout) :: exportState
    type(si_ifrac_memory_t),       intent(inout) :: ifrac_mem
    integer,                       intent(out)   :: rc

    type(ESMF_Field)            :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    integer :: ii, jj, ii_mom, jj_mom, ig, jg
    integer :: lb1, lb2, ub1, ub2
    integer :: isc_loc, iec_loc, jsc_loc, jec_loc
    real(ESMF_KIND_R8) :: mask_val

    ! Parâmetros da formulação sigmoide
    !
    ! T_FREEZE : ponto de congelamento da água do mar (S≈35 psu) [K]
    ! DT_TRANS : largura da zona de transição da sigmoide [K]
    !
    ! DT_TRANS = 2.0 K: Si_ifrac > 0.01 para SST < 271.35 + 2.0·ln(99) ≈ 280.6 K.
    ! Com 0.5 K, Si_ifrac > 0.01 só para SST < 273.7 K, e a SST polar, que
    ! sobe para 278–282 K logo após o primeiro passo de acoplamento, zeraria
    ! o proxy em quase todo o oceano polar. A sigmoide continua monotônica e
    ! contínua.
    !
    ! EXP_CLAMP : limite para o argumento do exponencial (evita overflow)
    real(ESMF_KIND_R8), parameter :: DT_TRANS  = 2.0_ESMF_KIND_R8  ! [K]
    real(ESMF_KIND_R8), parameter :: EXP_CLAMP = 50.0_ESMF_KIND_R8    ! evita overflow

    ! Parâmetros da contribuição de frazil
    ! FRAZIL_SCALE mapeia frazil [W/m²] para Si_ifrac em [0,1]:
    !   Si_ifrac = min(1, frazil / FRAZIL_SCALE)
    ! Valor típico: 100 W/m² → Si_ifrac = 1.0.
    ! A escala contínua evita cobertura total por frazil mínima
    ! (numericamente ruidosa), como faria um critério binário frazil > 0.
    real(ESMF_KIND_R8), parameter :: FRAZIL_SCALE = 100.0_ESMF_KIND_R8 ! [W/m²]

    real(ESMF_KIND_R8) :: t_surf_val, frazil_val, f_temp, f_frazil, x_exp

    rc = ESMF_SUCCESS

    ! Obter limites do domínio computacional local do MOM6
    call mpp_get_compute_domain(ocean_public%domain, &
         isc_loc, iec_loc, jsc_loc, jec_loc)

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) return

    ! Inicializa com zeros (oceano sem gelo / pontos terra após máscara MOM6)
    ptr_ifrac = 0.0_ESMF_KIND_R8

    ! PETs land-only: nada a calcular
    if (.not. ocean_public%is_ocean_pe) return

    ! ocean_grid é necessário para acessar mask2dT.
    ! Se não foi passado, retorna zeros — comportamento seguro.
    if (.not. associated(ocean_grid)) then
      call log_warning(COMP_OCN, 'Si_ifrac sem ocean_grid: zeros')
      return
    end if

    lb1 = lbound(ptr_ifrac, 1); ub1 = ubound(ptr_ifrac, 1)
    lb2 = lbound(ptr_ifrac, 2); ub2 = ubound(ptr_ifrac, 2)

    ! Loop sobre o domínio ESMF, mapeando para índices MOM6 via offset.
    !
    ! Aplicação da máscara terra/oceano via ocean_grid%mask2dT.
    !   mask2dT > 0 → célula oceânica → calcular sigmoide + frazil
    !   mask2dT = 0 → célula terra    → Si_ifrac = 0 (já inicializado)
    !
    ! Padrão de indexação idêntico ao mom_cap_methods::state_setexport.
    do jj = lb2, ub2
      jj_mom = jj + jsc_loc - lb2
      jg     = jj_mom + ocean_grid%jsc - jsc_loc
      do ii = lb1, ub1
        ii_mom = ii + isc_loc - lb1
        ig     = ii_mom + ocean_grid%isc - isc_loc
        if (ii_mom < isc_loc .or. ii_mom > iec_loc) cycle
        if (jj_mom < jsc_loc .or. jj_mom > jec_loc) cycle

        ! Pular células terra (mask2dT == 0)
        mask_val = ocean_grid%mask2dT(ig, jg)
        if (mask_val <= 0.0_ESMF_KIND_R8) cycle

        ! Contribuição termodinâmica: sigmoide na SST
        ! f_temp = 1 / (1 + exp((SST - T_FREEZE) / DT_TRANS))
        ! Clampa o expoente para evitar overflow em SST tropical.
        f_temp = 0.0_ESMF_KIND_R8
        if (associated(ocean_public%t_surf)) then
          t_surf_val = ocean_public%t_surf(ii_mom, jj_mom)
          x_exp = (t_surf_val - T_FREEZE) / DT_TRANS
          if (x_exp >  EXP_CLAMP) then
            f_temp = 0.0_ESMF_KIND_R8
          else if (x_exp < -EXP_CLAMP) then
            f_temp = 1.0_ESMF_KIND_R8
          else
            f_temp = 1.0_ESMF_KIND_R8 / (1.0_ESMF_KIND_R8 + exp(x_exp))
          end if
        end if

        ! Contribuição dinâmica: frazil
        ! Escala contínua: f_frazil = min(1, frazil / FRAZIL_SCALE).
        ! A escala contínua respeita a magnitude do fluxo de formação de gelo.
        f_frazil = 0.0_ESMF_KIND_R8
        if (associated(ocean_public%frazil)) then
          frazil_val = ocean_public%frazil(ii_mom, jj_mom)
          if (frazil_val > 0.0_ESMF_KIND_R8) then
            f_frazil = min(1.0_ESMF_KIND_R8, frazil_val / FRAZIL_SCALE)
          end if
        end if

        ! Combinação: máximo das duas contribuições
        ptr_ifrac(ii, jj) = max(f_frazil, f_temp)
      end do
    end do

    ! Clamp final defensivo [0,1]
    where (ptr_ifrac < 0.0_ESMF_KIND_R8) ptr_ifrac = 0.0_ESMF_KIND_R8
    where (ptr_ifrac > 1.0_ESMF_KIND_R8) ptr_ifrac = 1.0_ESMF_KIND_R8

    ! Persistência: combinar proxy com o estado anterior
    !
    ! O log ESMF registra (depuração) se ifrac_mem%valid chegou .true.
    ! neste PET: 'si_ifrac_mem_valid=T' (persistência ativa) ou, como aviso,
    ! 'si_ifrac_mem_valid=F' (sem campo anterior salvo).
    if (ifrac_mem%valid) then
      call log_debug(COMP_OCN, 'si_ifrac_mem_valid=T: aplicando persistencia')
      do jj = lb2, ub2
        do ii = lb1, ub1
          ptr_ifrac(ii, jj) = max(ptr_ifrac(ii, jj), &
                                   ifrac_mem%field(ii, jj) * SI_IFRAC_DECAY)
        end do
      end do
      ! Clamp pós-persistência
      where (ptr_ifrac > 1.0_ESMF_KIND_R8) ptr_ifrac = 1.0_ESMF_KIND_R8
    else
      call log_warning(COMP_OCN, 'si_ifrac_mem_valid=F: sem persistencia (passo inicial?)')
    end if

    ! Salvar estado atual para o próximo passo de acoplamento
    if (.not. allocated(ifrac_mem%field)) then
      allocate(ifrac_mem%field(lb1:ub1, lb2:ub2))
      ifrac_mem%field = 0.0_ESMF_KIND_R8
    end if
    ifrac_mem%field = ptr_ifrac
    ifrac_mem%valid = .true.

    call log_debug(COMP_OCN, 'Si_ifrac pela sigmoide DT_TRANS=2K + frazil continuo')

  end subroutine compute_si_ifrac_proxy

end module mom_si_ifrac_mod
