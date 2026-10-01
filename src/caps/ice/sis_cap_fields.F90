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
!! Separado de sis_cap_MONAN.F90 sem mudar instruções (R-FASE8-14); como
!! o cap, é compilado com as opções do MOM6 (lista MOM6_SRCS do Makefile).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module sis_cap_fields_mod

  use ESMF
  use NUOPC_Model, only : NUOPC_ModelGet
  use coupler_constants_mod, only : TICE_FALLBACK => T_FREEZE_SEAWATER, T0_KELVIN, &
                                    T_ICE_MIN, ALBEDO_ICE_FALLBACK => ALB_ICE_DEFAULT
  use coupler_config_mod, only : cfg_write_fixdiag
  use ice_model_mod, only : ice_data_type, ocean_ice_boundary_type, &
                             atmos_ice_boundary_type
  use coupler_utils_mod, only : ChkErr

  implicit none
  private

  public :: ice_internal_state_type
  public :: import_forcing
  public :: export_si_ifrac, export_si_albedo, export_si_tskin

  ! ── Estado interno do componente de gelo ──────────────────────────────────
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

  ! ============================================================================
  !> @brief Le os campos importados do mediador (forcante ATM + SST/correntes
  !! OCN) e popula is%aib/is%oib.
  !!
  !! Nomes de campo iguais aos da exportação do mediador (mapa de
  !! acoplamento, src/coupling/cpl_map.F90). Mapeamento:
  !! - Fioi_taux/tauy → u_flux/v_flux; Fioi_sen → t_flux (SINAL INVERTIDO,
  !!   ver broadcast_to_cat_neg); Fioi_evap → q_flux;
  !!   Fioi_lwnet → lw_flux; Fioi_swnet_vdr/vdf/idr/idf → sw_flux_*
  !!   (albedo do gelo puro, sem blend);
  !!   Faxa_rain/snow → lprec/fprec; Sa_pslv → p; Faxa_coszen → coszen.
  !!   Os campos 2D do mediador sao REPLICADOS (broadcast) para todas as
  !!   categorias de espessura de gelo na 3a dimensao de is%aib — o mediador
  !!   nao distingue por categoria.
  !!
  !! t_flux e' o UNICO campo desta lista
  !! que precisa de inversao de sinal. Fioi_sen chega na convencao CMEPS
  !! (positivo = aquece a superficie), mas o SIS2 (ice_boundary_types.F90)
  !! define t_flux como positivo = sai da superficie (convencao legada FMS).
  !! Fioi_evap e Fioi_lwnet ja' chegam na convencao que q_flux/lw_flux
  !! esperam — NAO inverter esses dois.
  !! - u_star e dhdt/dedt/drdt sem fonte no mediador — ficam nos valores de
  !!   seguranca definidos em InitializeRealize (zero). Isso e' uma
  !!   SIMPLIFICACAO: acoplamento explicito, sem os termos de derivada usados
  !!   para acoplamento implicito.
  subroutine import_forcing(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: importState
    real(ESMF_KIND_R8), pointer :: ptr2d(:,:) => null()

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, importState=importState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    ! -- Forcante atmosferica: le 2D, replica (broadcast) para as N
    !    categorias de espessura de gelo em is%aib. taux/tauy/sen/evap/lwnet
    !    vem de Fioi_* (temperatura de pele do gelo), nao de Foxx_* (SST). --
    call get_field_2d(importState, "Fioi_taux",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%u_flux)
    call get_field_2d(importState, "Fioi_tauy",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%v_flux)
    ! Fioi_sen (convencao CMEPS, positivo =
    ! aquece a superficie) precisa ser INVERTIDO ao entrar em t_flux (SIS2
    ! espera positivo = sai da superficie, convencao legada FMS). Ver
    ! docstring de broadcast_to_cat_neg abaixo para o raciocinio completo.
    call get_field_2d(importState, "Fioi_sen",       ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat_neg(ptr2d, is%aib%t_flux)
    call get_field_2d(importState, "Fioi_evap",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%q_flux)
    call get_field_2d(importState, "Fioi_lwnet",     ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lw_flux)
    ! Fioi_swnet_* (albedo do gelo por banda, PURO, sem blend com agua
    ! aberta), e nao Foxx_swnet_* (albedo MEDIO da celula, o enviado ao
    ! MOM6). Ver o comentario de PONTO_ICE em sis_cap_MONAN.F90 e med_bulk_ncar.F90
    ! para o calculo.
    call get_field_2d(importState, "Fioi_swnet_vdr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dir)
    call get_field_2d(importState, "Fioi_swnet_vdf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_vis_dif)
    call get_field_2d(importState, "Fioi_swnet_idr", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dir)
    call get_field_2d(importState, "Fioi_swnet_idf", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%sw_flux_nir_dif)
    ! lprec/fprec/p: chuva, neve e pressao ao nivel do mar do mediador.
    call get_field_2d(importState, "Faxa_rain",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%lprec)
    call get_field_2d(importState, "Faxa_snow",      ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%fprec)
    call get_field_2d(importState, "Sa_pslv",        ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    call broadcast_to_cat(ptr2d, is%aib%p)

    ! Angulo zenital solar real. Se o mediador nao exportar Faxa_coszen,
    ! degrada de forma segura para coszen=0 em vez de abortar toda a
    ! forcante.
    call get_field_2d(importState, "Faxa_coszen", ptr2d, rc)
    if (rc == ESMF_SUCCESS) then
      call broadcast_to_cat(ptr2d, is%aib%coszen)
    else
      call ESMF_LogWrite('ICE(SIS2): Faxa_coszen nao encontrado no ' // &
        'importState — is%aib%coszen permanece 0 (mediador antigo?)', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
    end if

    ! -- SST/correntes do oceano: cópia direta 2D para is%oib. --
    call get_field_2d(importState, "So_t", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%t(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_u", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%u(:,:) = ptr2d(:,:)
    call get_field_2d(importState, "So_v", ptr2d, rc); if (rc/=ESMF_SUCCESS) return
    is%oib%v(:,:) = ptr2d(:,:)
    ! is%oib%s (salinidade): sem fonte confirmada do mediador ainda — ver
    ! nota no plano de integração ("So_s" listado como campo em aberto na
    ! memória do projeto). Mantém o default de seguranca (34.7 psu)
    ! definido em InitializeRealize.

  end subroutine import_forcing

  !> Helper: busca campo 2D no state pelo nome; rc=ESMF_SUCCESS se achou.
  subroutine get_field_2d(state, name, ptr2d, rc)
    type(ESMF_State),    intent(in)    :: state
    character(len=*),    intent(in)    :: name
    real(ESMF_KIND_R8), pointer        :: ptr2d(:,:)
    integer,              intent(out)  :: rc
    type(ESMF_Field) :: fld
    call ESMF_StateGet(state, itemName=trim(name), field=fld, rc=rc)
    if (rc /= ESMF_SUCCESS) then
      call ESMF_LogWrite('ICE(SIS2): campo "' // trim(name) // &
        '" nao encontrado no importState', ESMF_LOGMSG_WARNING)
      return
    end if
    call ESMF_FieldGet(fld, farrayPtr=ptr2d, rc=rc)
  end subroutine get_field_2d

  !> Helper: replica um campo 2D em todas as categorias de espessura (3a
  !! dimensao) de um campo do atmos_ice_boundary_type.
  subroutine broadcast_to_cat(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(out)   :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = src2d(:,:)
    end do
  end subroutine broadcast_to_cat

  ! > variante de broadcast_to_cat que
  !! inverte o sinal antes de replicar. Uso exclusivo para Fioi_sen -> t_flux.
  !!
  !! Fioi_sen chega do MED_cap (med_bulk_ncar.F90) na convencao CMEPS
  !! (positivo = fluxo sensivel PARA a superficie, aquece o gelo) — a mesma
  !! convencao de Foxx_sen, confirmada contra o hfx/lh nativo do MONAN-A
  !! (positivo-para-cima). O SIS2 (ice_boundary_types.F90::atmos_ice_boundary_type)
  !! documenta t_flux como "the net sensible heat flux from the ocean or ice
  !! INTO the atmosphere" — ou seja, positivo = sai da superficie (convencao
  !! legada do acoplador FMS, oposta a CMEPS). broadcast_to_cat (copia pura)
  !! entregava Fioi_sen a t_flux sem essa inversao, fazendo o SIS2 interpretar
  !! aquecimento real da superficie como perda de calor (e vice-versa) —
  !! causa de derretimento espurio em condicoes que deveriam resfriar/
  !! engrossar o gelo (ex. ar frio sobre gelo, comum em inverno polar).
  !!
  !! Fioi_evap -> q_flux e Fioi_lwnet -> lw_flux NAO precisam desta correcao:
  !! Fioi_evap ja segue a convencao CMEPS "E>0 = superficie->atmosfera", que
  !! coincide com q_flux; Fioi_lwnet ja e' liquido-para-dentro, que coincide
  !! com lw_flux ("from the atmosphere into the ice or ocean").
  subroutine broadcast_to_cat_neg(src2d, dst3d)
    real(ESMF_KIND_R8), pointer, intent(in)    :: src2d(:,:)
    real(ESMF_KIND_R8),          intent(out)   :: dst3d(:,:,:)
    integer :: k
    do k = 1, size(dst3d, 3)
      dst3d(:,:,k) = -src2d(:,:)
    end do
  end subroutine broadcast_to_cat_neg


  !! Confirmado em ice_type.F90. Ver SIS2_ativacao_plano_integracao.md.
  subroutine export_si_ifrac(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_ifrac
    real(ESMF_KIND_R8), pointer :: ptr_ifrac(:,:) => null()
    integer :: ii, jj, lb1, lb2, ub1, ub2
    integer :: i_off, j_off, k_lo, k_hi
          character(len=200) :: diag_msg6

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_ifrac_sis2", field=f_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_ifrac, farrayPtr=ptr_ifrac, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_ifrac)) return

    if (.not. associated(is%ice%sCS)) then
      call ESMF_LogWrite('ICE(SIS2): Ice%sCS nao associado (slow ice PE ' // &
        'ausente?) — Si_ifrac=0', ESMF_LOGMSG_WARNING)
      ptr_ifrac = 0.0_ESMF_KIND_R8
      return
    end if

    lb1 = lbound(ptr_ifrac,1); ub1 = ubound(ptr_ifrac,1)
    lb2 = lbound(ptr_ifrac,2); ub2 = ubound(ptr_ifrac,2)
    ! ------------------------------------------------------------------
    ! Fracao de gelo marinho exportada ao mediador (Si_ifrac_sis2).
    !
    ! FONTE DO CAMPO — ponto critico: usa Ice%sCS%IST%part_size (estado
    ! interno real do SIS2, ice_state_type), NAO Ice%part_size. Este ultimo
    ! e o campo de fachada do acoplador, preenchido apenas no caminho de
    ! acoplamento rapido (ver ice_type.F90:191 - only available on fast PEs)
    ! e permanece ZERADO nesta configuracao. IST%part_size e o mesmo array
    ! que o proprio SIS2 usa para calcular area/massa em ice_stock_pe, ou
    ! seja, os valores nao-zero que aparecem no log SIS Date.
    !
    ! INDEXACAO: IST%part_size tem halos (isd:ied, jsd:jed) e categorias com
    ! base 0, onde a fatia 0 e AGUA ABERTA e 1..CatIce sao as categorias de
    ! gelo. O deslocamento vem da grade do proprio SIS2 (Ice%sCS%G%isc/jsc),
    ! padrao usado internamente por ice_model.F90 - acompanha corretamente
    ! qualquer decomposicao MPI (verificado: PET6 i_off=4, PET7 i_off=-86).
    ! A soma e feita de k_lo+1 ate k_hi (todas as categorias de gelo, isto e,
    ! todas as fatias menos a primeira), robusto a base 0 ou 1.
    !
    ! IST so existe em slow_ice_PE - garantido aqui, pois o cap forca
    ! fast_ice_pe=.true. e slow_ice_pe=.true. antes de ice_model_init.
    ! ------------------------------------------------------------------
    i_off = is%ice%sCS%G%isc - lb1
    j_off = is%ice%sCS%G%jsc - lb2
    k_lo  = lbound(is%ice%sCS%IST%part_size, 3)
    k_hi  = ubound(is%ice%sCS%IST%part_size, 3)
    do jj = lb2, ub2
      do ii = lb1, ub1
        ! fracao de gelo = soma das categorias de gelo = todas as fatias
        ! menos a primeira (agua aberta), robusto a base 0 ou 1
        ptr_ifrac(ii,jj) = &
          sum(is%ice%sCS%IST%part_size(ii+i_off, jj+j_off, k_lo+1:k_hi))
        ptr_ifrac(ii,jj) = max(0.0_ESMF_KIND_R8, &
          min(1.0_ESMF_KIND_R8, ptr_ifrac(ii,jj)))
      end do
    end do

    ! Diagnostico: compara o campo publico de fachada Ice%part_size (zerado
    ! nesta configuracao, ver acima) com sCS%IST%part_size, a fonte real
    ! usada acima. Condicionado a cfg_write_fixdiag para nao poluir os logs
    ! de rodadas longas.
    if (cfg_write_fixdiag) then
      if (associated(is%ice%part_size)) then
          write(diag_msg6,'(A,ES12.4,A,ES12.4)') &
            'FIX-DIAG-FASTSYNC-01: Ice%part_size(:,:,1) [fachada publica] ' // &
            'min=', minval(is%ice%part_size(:,:,1)), ' max=', &
            maxval(is%ice%part_size(:,:,1))
          call ESMF_LogWrite(trim(diag_msg6), ESMF_LOGMSG_INFO)
      else
        call ESMF_LogWrite('FIX-DIAG-FASTSYNC-01: Ice%part_size ainda nao ' // &
          'associado neste ponto', ESMF_LOGMSG_INFO)
      end if
    end if

  end subroutine export_si_ifrac

  !! exporta o albedo real do gelo, por banda,
  !! calculado pela fisica do proprio SIS2 (esquema optico em
  !! SIS_optics.F90/fast_radiation_diagnostics), acessivel porque
  !! Ice%albedo_vis_dir/vis_dif/nir_dir/nir_dif (fachada publica) sao
  !! preenchidos por set_ice_surface_state (ver sis_cap_MONAN.F90).
  !!
  !! Diferente de Si_ifrac_sis2 (que le sCS%IST%part_size com deslocamento
  !! i_off/j_off), aqui usamos Ice%part_size e Ice%albedo_* diretamente —
  !! ambos sao campos da MESMA fachada publica, com a MESMA indexacao local
  !! (sem halo, sem offset), confirmados no diagnostico
  !! (que ja le is%ice%part_size(:,:,1) sem nenhum deslocamento).
  !!
  !! *** VERIFICAR ***: os comentarios de ice_type.F90 (fonte NOAA-GFDL/SIS2)
  !! para albedo_vis_dif/albedo_nir_dir parecem trocados entre si ("The
  !! surface albedo for diffuse visible..." vs "...direct near-infrared...").
  !! Usamos aqui os NOMES dos campos (vis_dir/vis_dif/nir_dir/nir_dif), que
  !! sao a fonte de verdade da API, nao a prosa do comentario — mas vale
  !! uma segunda conferencia cruzando com SIS_optics.F90 antes de validar
  !! contra observacoes.
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
    ! Fallback usado apenas onde a fracao de gelo e desprezivel (o peso do
    ! termo de gelo no blend por ifrac feito no mediador torna esse valor
    ! quase irrelevante), ou onde Ice%albedo_* ainda nao estiver associado:
    ! ALBEDO_ICE_FALLBACK (ALB_ICE_DEFAULT de coupler_constants).
        character(len=200) :: diag_msg7

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
      call ESMF_LogWrite('ICE(SIS2): Ice%part_size/albedo_* nao ' // &
        'associados — Si_a*_sis2 = fallback constante', ESMF_LOGMSG_WARNING)
      ptr_avsdr = ALBEDO_ICE_FALLBACK; ptr_avsdf = ALBEDO_ICE_FALLBACK
      ptr_anidr = ALBEDO_ICE_FALLBACK; ptr_anidf = ALBEDO_ICE_FALLBACK
      return
    end if

    ! part_size/albedo_* tem a mesma 3a dimensao (categorias); categoria
    ! k_lo = agua aberta (mesma convencao usada em export_si_ifrac).
    k_lo = lbound(is%ice%part_size, 3)
    k_hi = ubound(is%ice%part_size, 3)

    do jj = lbound(ptr_avsdr,2), ubound(ptr_avsdr,2)
      do ii = lbound(ptr_avsdr,1), ubound(ptr_avsdr,1)
        ice_frac_ij = sum(real(is%ice%part_size(ii,jj,k_lo+1:k_hi), ESMF_KIND_R8))
        if (ice_frac_ij > 1.0e-6_ESMF_KIND_R8) then
          ! media ponderada pela area de cada categoria de gelo
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
        ! blindagem: albedo fisico esta sempre em [0,1]
        ptr_avsdr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdr(ii,jj)))
        ptr_avsdf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_avsdf(ii,jj)))
        ptr_anidr(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidr(ii,jj)))
        ptr_anidf(ii,jj) = max(0.0_ESMF_KIND_R8, min(1.0_ESMF_KIND_R8, ptr_anidf(ii,jj)))
      end do
    end do

    ! diagnostico de validacao, mesmo espirito do
    ! Espera-se min proximo do fallback/agua (baixo)
    ! e max na faixa de neve fria (~0,8-0,9) em regioes com gelo espesso.
    if (cfg_write_fixdiag) then
        write(diag_msg7,'(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
          'FIX-DIAG-ALBEDO-01: Si_avsdr min=', minval(ptr_avsdr), &
          ' max=', maxval(ptr_avsdr), &
          ' | Si_anidr min=', minval(ptr_anidr), ' max=', maxval(ptr_anidr)
        call ESMF_LogWrite(trim(diag_msg7), ESMF_LOGMSG_INFO)
    end if

  end subroutine export_si_albedo

  !! exporta a temperatura de pele real do
  !! gelo, media ponderada por area de categoria (mesmo padrao de
  !! export_si_albedo). Usada pelo mediador para calcular um segundo
  !! conjunto de fluxos turbulentos (Fioi_*) especifico para a fracao de
  !! gelo, em vez de reusar o Foxx_* calculado com SST (ver
  !! PONTO_ICE em sis_cap_MONAN.F90).
  !!
  !! Ice%t_surf e' preenchido pela MESMA rotina (set_ice_surface_state) que
  !! Ice%part_size/Ice%albedo_*.
  subroutine export_si_tskin(is, gcomp, rc)
    type(ice_internal_state_type), pointer, intent(in) :: is
    type(ESMF_GridComp),                   intent(in) :: gcomp
    integer, intent(out)                                :: rc

    type(ESMF_State) :: exportState
    type(ESMF_Field) :: f_tice
    real(ESMF_KIND_R8), pointer :: ptr_tice(:,:) => null()
    real(ESMF_KIND_R8) :: ice_frac_ij
    integer :: ii, jj, k_lo, k_hi
    ! Fallback: ponto de congelamento tipico da agua do mar (~-1,8 C),
    ! usado so' onde a fracao de gelo e desprezivel ou o campo nao esta
    ! associado — o peso do termo de gelo no blend a jusante torna esse
    ! valor quase irrelevante nesses casos.
        character(len=150) :: diag_msg8

    rc = ESMF_SUCCESS
    call NUOPC_ModelGet(gcomp, exportState=exportState, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return

    call ESMF_StateGet(exportState, itemName="Si_t_sis2", field=f_tice, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_FieldGet(f_tice, farrayPtr=ptr_tice, rc=rc)
    if (rc /= ESMF_SUCCESS .or. .not. associated(ptr_tice)) return

    if (.not. (associated(is%ice%part_size) .and. associated(is%ice%t_surf))) then
      call ESMF_LogWrite('ICE(SIS2): Ice%part_size/t_surf nao associados ' // &
        '— Si_t_sis2 = fallback (ponto de congelamento)', ESMF_LOGMSG_WARNING)
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
        ! blindagem fisica: temperatura de gelo/neve nunca abaixo de ~180 K
        ! (recorde antartico ~184 K) nem acima de 0 °C
        ptr_tice(ii,jj) = max(T_ICE_MIN, min(T0_KELVIN, ptr_tice(ii,jj)))
      end do
    end do

    if (cfg_write_fixdiag) then
        write(diag_msg8,'(A,ES10.3,A,ES10.3)') &
          'FIX-DIAG-TSKIN-01: Si_t_sis2 min=', minval(ptr_tice), ' max=', maxval(ptr_tice)
        call ESMF_LogWrite(trim(diag_msg8), ESMF_LOGMSG_INFO)
    end if

  end subroutine export_si_tskin

end module sis_cap_fields_mod
