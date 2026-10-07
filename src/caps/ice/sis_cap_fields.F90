!> @file sis_cap_fields.F90
!! @brief Troca de campos do cap do SIS2 com o mediador.
!!
!! Guarda o estado interno do componente de gelo (ice_internal_state_type)
!! e as rotinas que o ligam aos campos ESMF, a cada passo de acoplamento:
!!   import_forcing    importState → atmos_ice_boundary_type (forçante da
!!                     atmosfera, replicada por categoria de espessura) e
!!                     ocean_ice_boundary_type (SST e correntes);
!!   export_si_ifrac   fração de gelo (Si_ifrac_sis2);
!!   export_si_albedo  albedos por banda (Si_avsdr/avsdf/anidr/anidf_sis2);
!!   export_si_tskin   temperatura de pele (Si_t_sis2).
!! O ciclo NUOPC, a grade e o avanço do modelo ficam em sis_cap_MONAN.F90.
!!
!! Como o cap, é compilado com as opções do MOM6 (lista MOM6_SRCS do Makefile).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module sis_cap_fields_mod

  use ESMF
  use NUOPC_Model, only : NUOPC_ModelGet
  use coupler_constants_mod, only : TICE_FALLBACK => T_FREEZE_SEAWATER, T0_KELVIN, &
                                    T_ICE_MIN, ALBEDO_ICE_FALLBACK => ALB_ICE_DEFAULT
  use ice_model_mod, only : ice_data_type, ocean_ice_boundary_type, &
                             atmos_ice_boundary_type
  use coupler_utils_mod, only : ChkErr
  use coupler_log_mod, only : COMP_ICE, log_warning

  implicit none
  private

  public :: ice_internal_state_type
  public :: import_forcing
  public :: export_si_ifrac, export_si_albedo, export_si_tskin

  ! Estado interno do componente de gelo
  type :: ice_internal_state_type
    type(ice_data_type)             :: ice
    type(ocean_ice_boundary_type)   :: oib   !< SST/correntes vindas do OCN (via MED)
    type(atmos_ice_boundary_type)   :: aib   !< Forçante vinda do ATM (via MED)
    type(ESMF_Grid)                 :: ice_grid
    integer                         :: isc, iec, jsc, jec  !< domínio computacional local
    !> CheckImportTolerant já registrou no log que está ativo
    logical                         :: check_import_logged = .false.
  end type ice_internal_state_type

contains

  !> @brief Lê os campos importados do mediador (forçante ATM + SST/correntes
  !! OCN) e popula is%aib/is%oib.
  !!
  !! Nomes de campo iguais aos da exportação do mediador (mapa de
  !! acoplamento, src/coupling/cpl_map.F90). Mapeamento:
  !! - Fioi_taux/tauy → u_flux/v_flux; Fioi_sen → t_flux (SINAL INVERTIDO,
  !!   ver broadcast_to_cat_neg); Fioi_evap → q_flux;
  !!   Fioi_lwnet → lw_flux; Fioi_swnet_vdr/vdf/idr/idf → sw_flux_*
  !!   (albedo do gelo puro, sem blend);
  !!   Faxa_rain/snow → lprec/fprec; Sa_pslv → p; Faxa_coszen → coszen.
  !!   Os campos 2D do mediador são REPLICADOS (broadcast) para todas as
  !!   categorias de espessura de gelo na 3a dimensão de is%aib; o mediador
  !!   não distingue por categoria.
  !!
  !! t_flux é o ÚNICO campo desta lista que precisa de inversão de sinal.
  !! Fioi_sen chega na convenção CMEPS (positivo = aquece a superfície), mas
  !! o SIS2 (ice_boundary_types.F90) define t_flux como positivo = sai da
  !! superfície (convenção do acoplador FMS). Fioi_evap e Fioi_lwnet já
  !! chegam na convenção que q_flux/lw_flux esperam: NÃO inverter esses dois.
  !! - u_star e dhdt/dedt/drdt não têm fonte no mediador e ficam nos valores
  !!   de segurança definidos em InitializeRealize (zero). É uma
  !!   SIMPLIFICAÇÃO: acoplamento explícito, sem os termos de derivada usados
  !!   no acoplamento implícito.
  !! @param[in]    is     estado interno do componente de gelo
  !! @param[in]    gcomp  componente do gelo
  !! @param[out]   rc     código de retorno
  subroutine import_forcing(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: importState
    real(ESMF_KIND_R8), pointer :: ptr2d(:,:) => null()

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, importState=importState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! Forçante atmosférica: lê 2D, replica (broadcast) para as N
    ! categorias de espessura de gelo em is%aib. taux/tauy/sen/evap/lwnet
    ! vêm de Fioi_* (temperatura de pele do gelo), não de Foxx_* (SST).
    call get_field_2d(importState, "Fioi_taux",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%u_flux)
    call get_field_2d(importState, "Fioi_tauy",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%v_flux)
    ! Fioi_sen (convenção CMEPS, positivo = aquece a superfície) precisa
    ! ser INVERTIDO ao entrar em t_flux (o SIS2 espera positivo = sai da
    ! superfície, convenção do acoplador FMS). Ver o cabeçalho de
    ! broadcast_to_cat_neg abaixo.
    call get_field_2d(importState, "Fioi_sen",       ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat_neg(ptr2d, is%aib%t_flux)
    call get_field_2d(importState, "Fioi_evap",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%q_flux)
    call get_field_2d(importState, "Fioi_lwnet",     ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lw_flux)
    ! Fioi_swnet_* (albedo do gelo por banda, PURO, sem blend com água
    ! aberta), e não Foxx_swnet_* (albedo MÉDIO da célula, o enviado ao
    ! MOM6). Ver o comentário de POINT_ICE em sis_cap_MONAN.F90 e med_bulk_ncar.F90
    ! para o cálculo.
    call get_field_2d(importState, "Fioi_swnet_vdr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dir)
    call get_field_2d(importState, "Fioi_swnet_vdf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dif)
    call get_field_2d(importState, "Fioi_swnet_idr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dir)
    call get_field_2d(importState, "Fioi_swnet_idf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dif)
    ! lprec/fprec/p: chuva, neve e pressão ao nível do mar do mediador.
    call get_field_2d(importState, "Faxa_rain",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lprec)
    call get_field_2d(importState, "Faxa_snow",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%fprec)
    call get_field_2d(importState, "Sa_pslv",        ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%p)

    ! Ângulo zenital solar real. Se o mediador não exportar Faxa_coszen,
    ! degrada de forma segura para coszen=0 em vez de abortar toda a
    ! forçante.
    call get_field_2d(importState, "Faxa_coszen", ptr2d, rc)
    if (rc == ESMF_SUCCESS) then
      call broadcast_to_cat(ptr2d, is%aib%coszen)
    else
      call log_warning(COMP_ICE, 'Faxa_coszen nao encontrado no importState: ' // &
        'is%aib%coszen permanece 0')
      rc = ESMF_SUCCESS
    end if

    ! SST/correntes do oceano: cópia direta 2D para is%oib.
    call get_field_2d(importState, "So_t", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%t(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_u", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%u(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_v", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%v(:,:) = ptr2d(:,:)
    ! is%oib%s (salinidade): o mediador não envia salinidade (So_s é campo
    ! em aberto). Fica o valor de segurança (34.7 psu) definido em
    ! InitializeRealize.

  end subroutine import_forcing

  !> @brief Busca um campo 2D no State pelo nome; rc=ESMF_SUCCESS se achou.
  subroutine get_field_2d(state, name, ptr2d, rc)
    type(ESMF_State),    intent(in)    :: state
    character(len=*),    intent(in)    :: name
    real(ESMF_KIND_R8), pointer        :: ptr2d(:,:)
    integer,              intent(out)  :: rc
    type(ESMF_Field) :: fld
    call ESMF_StateGet(state, itemName=trim(name), field=fld, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call log_warning(COMP_ICE, 'campo "' // trim(name) // &
        '" nao encontrado no importState')
      return
    end if
    call ESMF_FieldGet(fld, farrayPtr=ptr2d, rc=rc)
  end subroutine get_field_2d

  !> @brief Replica um campo 2D em todas as categorias de espessura (3a
  !! dimensão) de um campo do atmos_ice_boundary_type.
  subroutine broadcast_to_cat(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(out)   :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = src2d(:,:)
    end do
  end subroutine broadcast_to_cat

  !> @brief Variante de broadcast_to_cat que inverte o sinal antes de
  !! replicar. Uso exclusivo para Fioi_sen -> t_flux.
  !!
  !! Fioi_sen chega do MED_cap (med_bulk_ncar.F90) na convenção CMEPS
  !! (positivo = fluxo sensível PARA a superfície, aquece o gelo), a mesma
  !! de Foxx_sen. O SIS2 (ice_boundary_types.F90::atmos_ice_boundary_type)
  !! documenta t_flux como "the net sensible heat flux from the ocean or ice
  !! INTO the atmosphere", ou seja, positivo = sai da superfície (convenção
  !! do acoplador FMS, oposta à do CMEPS). Uma cópia pura (broadcast_to_cat)
  !! faria o SIS2 interpretar aquecimento real da superfície como perda de
  !! calor, e vice-versa, com derretimento espúrio onde o gelo deveria
  !! resfriar e engrossar (por exemplo, ar frio sobre gelo no inverno
  !! polar).
  !!
  !! Fioi_evap -> q_flux e Fioi_lwnet -> lw_flux NÃO precisam desta inversão:
  !! Fioi_evap já segue a convenção CMEPS "E>0 = superfície->atmosfera", que
  !! coincide com q_flux; Fioi_lwnet já é líquido-para-dentro, que coincide
  !! com lw_flux ("from the atmosphere into the ice or ocean").
  subroutine broadcast_to_cat_neg(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(out)   :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = -src2d(:,:)
    end do
  end subroutine broadcast_to_cat_neg

  !> @brief Exporta a fração de gelo Si_ifrac_sis2, soma das categorias de
  !! gelo do estado interno do SIS2 (Ice%sCS%IST%part_size).
  !! @param[in]    is     estado interno do componente de gelo
  !! @param[in]    gcomp  componente do gelo
  !! @param[out]   rc     código de retorno
  subroutine export_si_ifrac(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    integer :: ii, jj, lb1, lb2, ub1, ub2
    integer :: i_off, j_off, k_lo, k_hi

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_ifrac_sis2", field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) return

    if (.not. associated(is%ice%sCS)) then
      call log_warning(COMP_ICE, 'Ice%sCS nao associado (slow ice PE ' // &
        'ausente?): Si_ifrac=0')
      ptr_ifrac = 0.0_ESMF_KIND_R8
      return
    end if

    lb1 = lbound(ptr_ifrac,1); ub1 = ubound(ptr_ifrac,1)
    lb2 = lbound(ptr_ifrac,2); ub2 = ubound(ptr_ifrac,2)
    ! Fração de gelo marinho exportada ao mediador (Si_ifrac_sis2).
    !
    ! FONTE DO CAMPO, ponto crítico: usa Ice%sCS%IST%part_size (estado
    ! interno real do SIS2, ice_state_type), e NÃO Ice%part_size. Este último
    ! é o campo de fachada do acoplador, preenchido apenas no caminho de
    ! acoplamento rápido (ver ice_type.F90:191, "only available on fast
    ! PEs"), e permanece ZERADO nesta configuração. IST%part_size é o mesmo
    ! array que o próprio SIS2 usa para calcular área e massa em
    ! ice_stock_pe, ou seja, os valores não nulos que aparecem no log "SIS
    ! Date".
    !
    ! INDEXAÇÃO: IST%part_size tem halos (isd:ied, jsd:jed) e categorias com
    ! base 0, onde a fatia 0 é ÁGUA ABERTA e 1..CatIce são as categorias de
    ! gelo. O deslocamento vem da grade do próprio SIS2 (Ice%sCS%G%isc/jsc),
    ! padrão usado internamente por ice_model.F90, e acompanha qualquer
    ! decomposição MPI (por exemplo, i_off=4 no PET 6 e i_off=-86 no PET 7).
    ! A soma vai de k_lo+1 até k_hi (todas as categorias de gelo, isto é,
    ! todas as fatias menos a primeira), robusta a base 0 ou 1.
    !
    ! IST só existe em slow_ice_PE - garantido aqui, pois o cap força
    ! fast_ice_pe=.true. e slow_ice_pe=.true. antes de ice_model_init.
    i_off = is%ice%sCS%G%isc - lb1
    j_off = is%ice%sCS%G%jsc - lb2
    k_lo  = lbound(is%ice%sCS%IST%part_size, 3)
    k_hi  = ubound(is%ice%sCS%IST%part_size, 3)
    do jj = lb2, ub2
      do ii = lb1, ub1
        ! fração de gelo = soma das categorias de gelo = todas as fatias
        ! menos a primeira (água aberta), robusto a base 0 ou 1
        ptr_ifrac(ii,jj) = &
          sum(is%ice%sCS%IST%part_size(ii+i_off, jj+j_off, k_lo+1:k_hi))
        ptr_ifrac(ii,jj) = max(0.0_ESMF_KIND_R8, &
          min(1.0_ESMF_KIND_R8, ptr_ifrac(ii,jj)))
      end do
    end do

  end subroutine export_si_ifrac

  !> @brief Exporta o albedo real do gelo, por banda (Si_avsdr/avsdf/anidr/anidf_sis2).
  !!
  !! O albedo é calculado pela física do próprio SIS2 (esquema óptico em
  !! SIS_optics.F90/fast_radiation_diagnostics) e fica acessível porque
  !! Ice%albedo_vis_dir/vis_dif/nir_dir/nir_dif (fachada pública) são
  !! preenchidos por set_ice_surface_state (ver sis_cap_MONAN.F90).
  !!
  !! Diferente de Si_ifrac_sis2 (que lê sCS%IST%part_size com deslocamento
  !! i_off/j_off), aqui se usam Ice%part_size e Ice%albedo_* diretamente:
  !! ambos são campos da MESMA fachada pública, com a MESMA indexação local
  !! (sem halo, sem deslocamento).
  !!
  !! A VERIFICAR: os comentários de ice_type.F90 (fonte NOAA-GFDL/SIS2)
  !! para albedo_vis_dif/albedo_nir_dir parecem trocados entre si ("The
  !! surface albedo for diffuse visible..." vs "...direct near-infrared...").
  !! Valem aqui os NOMES dos campos (vis_dir/vis_dif/nir_dir/nir_dif), que
  !! são a fonte de verdade da API, e não a prosa do comentário; convém
  !! conferir com SIS_optics.F90 antes de validar contra observações.
  !! @param[in]    is     estado interno do componente de gelo
  !! @param[in]    gcomp  componente do gelo
  !! @param[out]   rc     código de retorno
  subroutine export_si_albedo(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_avsdr, f_avsdf, f_anidr, f_anidf
    real(ESMF_KIND_R8), pointer :: ptr_avsdr(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_avsdf(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_anidr(:,:) => null()
    real(ESMF_KIND_R8), pointer :: ptr_anidf(:,:) => null()
    real(ESMF_KIND_R8) :: ice_frac_ij
    integer :: ii, jj, k_lo, k_hi
    ! Fallback usado apenas onde a fração de gelo é desprezível (o peso do
    ! termo de gelo no blend por ifrac feito no mediador torna esse valor
    ! quase irrelevante), ou onde Ice%albedo_* ainda não estiver associado:
    ! ALBEDO_ICE_FALLBACK (ALB_ICE_DEFAULT de coupler_constants).

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_avsdr_sis2", field=f_avsdr, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_avsdf_sis2", field=f_avsdf, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_anidr_sis2", field=f_anidr, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_StateGet(exportState, itemName="Si_anidf_sis2", field=f_anidf, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call ESMF_FieldGet(f_avsdr, farrayPtr=ptr_avsdr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_avsdr)) return
    call ESMF_FieldGet(f_avsdf, farrayPtr=ptr_avsdf, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_avsdf)) return
    call ESMF_FieldGet(f_anidr, farrayPtr=ptr_anidr, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_anidr)) return
    call ESMF_FieldGet(f_anidf, farrayPtr=ptr_anidf, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_anidf)) return

    if (.not. (associated(is%ice%part_size) .and. &
               associated(is%ice%albedo_vis_dir) .and. &
               associated(is%ice%albedo_vis_dif) .and. &
               associated(is%ice%albedo_nir_dir) .and. &
               associated(is%ice%albedo_nir_dif))) then
      call log_warning(COMP_ICE, 'Ice%part_size/albedo_* nao associados: ' // &
        'Si_a*_sis2 constantes')
      ptr_avsdr = ALBEDO_ICE_FALLBACK; ptr_avsdf = ALBEDO_ICE_FALLBACK
      ptr_anidr = ALBEDO_ICE_FALLBACK; ptr_anidf = ALBEDO_ICE_FALLBACK
      return
    end if

    ! part_size/albedo_* têm a mesma 3a dimensão (categorias); categoria
    ! k_lo = água aberta (mesma convenção usada em export_si_ifrac).
    k_lo = lbound(is%ice%part_size, 3)
    k_hi = ubound(is%ice%part_size, 3)

    do jj = lbound(ptr_avsdr,2), ubound(ptr_avsdr,2)
      do ii = lbound(ptr_avsdr,1), ubound(ptr_avsdr,1)
        ice_frac_ij = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8))
        if (ice_frac_ij > 1.0e-6_ESMF_KIND_R8) then
          ! média ponderada pela área de cada categoria de gelo
          ptr_avsdr(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_vis_dir(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_avsdf(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_vis_dif(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_anidr(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_nir_dir(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
          ptr_anidf(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                  real(is%ice%albedo_nir_dif(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
        else
          ptr_avsdr(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_avsdf(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_anidr(ii,jj) = ALBEDO_ICE_FALLBACK
          ptr_anidf(ii,jj) = ALBEDO_ICE_FALLBACK
        end if
        ! blindagem: albedo físico está sempre em [0,1]
        ptr_avsdr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdr(ii,jj)))
        ptr_avsdf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdf(ii,jj)))
        ptr_anidr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidr(ii,jj)))
        ptr_anidf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidf(ii,jj)))
      end do
    end do

  end subroutine export_si_albedo

  !> @brief Exporta a temperatura de pele real do gelo (Si_t_sis2).
  !!
  !! Média ponderada pela área de cada categoria (mesmo padrão de
  !! export_si_albedo). O mediador a usa para calcular um segundo conjunto
  !! de fluxos turbulentos (Fioi_*), próprio da fração de gelo, em vez de
  !! reusar os Foxx_* calculados com a SST (ver POINT_ICE em
  !! sis_cap_MONAN.F90).
  !!
  !! Ice%t_surf é preenchido pela MESMA rotina (set_ice_surface_state) que
  !! Ice%part_size/Ice%albedo_*.
  !! @param[in]    is     estado interno do componente de gelo
  !! @param[in]    gcomp  componente do gelo
  !! @param[out]   rc     código de retorno
  subroutine export_si_tskin(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_tice
    real(ESMF_KIND_R8), pointer :: ptr_tice(:,:) => null()
    real(ESMF_KIND_R8) :: ice_frac_ij
    integer :: ii, jj, k_lo, k_hi
    ! Fallback: ponto de congelamento típico da água do mar (~-1,8 C),
    ! usado só onde a fração de gelo é desprezível ou o campo não está
    ! associado: o peso do termo de gelo no blend a jusante torna esse
    ! valor quase irrelevante nesses casos.

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_t_sis2", field=f_tice, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_tice, farrayPtr=ptr_tice, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_tice)) return

    if (.not. (associated(is%ice%part_size) .and. associated(is%ice%t_surf))) then
      call log_warning(COMP_ICE, 'Ice%part_size/t_surf nao associados: ' // &
        'Si_t_sis2 no ponto de congelamento')
      ptr_tice = TICE_FALLBACK
      return
    end if

    k_lo = lbound(is%ice%part_size, 3)
    k_hi = ubound(is%ice%part_size, 3)

    do jj = lbound(ptr_tice,2), ubound(ptr_tice,2)
      do ii = lbound(ptr_tice,1), ubound(ptr_tice,1)
        ice_frac_ij = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8))
        if (ice_frac_ij > 1.0e-6_ESMF_KIND_R8) then
          ptr_tice(ii,jj) = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8) * &
                                 real(is%ice%t_surf(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8)) / ice_frac_ij
        else
          ptr_tice(ii,jj) = TICE_FALLBACK
        end if
        ! blindagem física: temperatura de gelo/neve nunca abaixo de ~180 K
        ! (recorde antártico ~184 K) nem acima de 0 °C
        ptr_tice(ii,jj) = max(T_ICE_MIN, min(T0_KELVIN, ptr_tice(ii,jj)))
      end do
    end do

  end subroutine export_si_tskin

end module sis_cap_fields_mod
