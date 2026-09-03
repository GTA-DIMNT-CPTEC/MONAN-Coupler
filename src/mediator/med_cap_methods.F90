!> @file med_cap_methods.F90
!! @brief Utilitários de manipulação de campos ESMF/NUOPC do mediador.
!!
!! Versão 1.0 (Mai/2026) — GT Acoplamento de Modelos / INPE/CGCT/DIMNT
!!
!! Contém as sub-rotinas de utilidade extraídas de MED_cap.F90
!! como parte da reorganização de responsabilidades (Passo 3):
!!
!!   CreateInternalField      — cria campo ESMF na grade interna
!!   ZeroInternalField        — zera campo com guard B-45
!!   FillInternalField        — preenche campo com valor constante
!!   GetFieldPtr              — obtém ponteiro de campo (falha se ausente)
!!   GetFieldPtrOptional      — obtém ponteiro sem erro de log para campos opcionais
!!   RegridOrCopy             — regrid ATM→OCN com fallback temporário
!!   RouteOcnToAtm            — exporta campos OCN→ATM via mediador (Fase 2)
!!   RegridOptionalCurrent    — regrid silencioso de correntes opcionais

module med_cap_methods_mod

  use ESMF
  use NUOPC, only: NUOPC_SetTimestamp

  use med_cap_types_mod, only: MED_InternalState
  use mpas_cap_config_mod, only: cfg_use_sis2_dynamic

  implicit none
  private

  public :: CreateInternalField
  public :: ZeroInternalField
  public :: FillInternalField
  public :: GetFieldPtr
  public :: GetFieldPtrOptional
  public :: RegridOrCopy
  public :: RouteOcnToAtm
  public :: RegridOptionalCurrent
  public :: NeighborFillExtrapolate

contains

  !============================================================================
  !> @brief Cria um campo ESMF na grade interna do mediador.
  !! @param[out] field  Campo a criar
  !! @param[in]  grid   Grade ESMF de destino
  !! @param[in]  name   Nome do campo
  !! @param[out] rc     Código de retorno ESMF
  !============================================================================
  subroutine CreateInternalField(field, grid, name, rc)
    type(ESMF_Field), intent(out) :: field
    type(ESMF_Grid),  intent(in)  :: grid
    character(len=*), intent(in)  :: name
    integer,          intent(out) :: rc

    field = ESMF_FieldCreate(grid=grid, typekind=ESMF_TYPEKIND_R8, &
      staggerloc=ESMF_STAGGERLOC_CENTER, name=trim(name), rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="MED CreateInternalField: "//trim(name), &
      line=__LINE__, file=__FILE__)) return
  end subroutine CreateInternalField

  !============================================================================
  !> @brief Zera um campo ESMF com guard B-45 para PETs sem DE local.
  !!
  !! B-45: ESMF_FieldGet(farrayPtr) falha com "localDe is out of range"
  !! em PETs sem DE local (localDeCount=0). Verificar antes de acessar.
  !============================================================================
  subroutine ZeroInternalField(field, rc)
    type(ESMF_Field), intent(inout) :: field
    integer,          intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: localDeCount_f
    rc = ESMF_SUCCESS

    call ESMF_FieldGet(field, localDeCount=localDeCount_f, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    if (localDeCount_f == 0) return   ! PET sem dados locais — nada a zerar

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    fptr = 0.0_ESMF_KIND_R8

  end subroutine ZeroInternalField

  !============================================================================
  !> @brief Preenche campo ESMF com valor constante.
  !! Guard B-45: PETs sem DE local não têm dados a preencher.
  !============================================================================
  subroutine FillInternalField(field, value, rc)
    type(ESMF_Field),   intent(inout) :: field
    real(ESMF_KIND_R8), intent(in)    :: value
    integer,            intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: localDeCount_f
    rc = ESMF_SUCCESS

    call ESMF_FieldGet(field, localDeCount=localDeCount_f, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    if (localDeCount_f == 0) return

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
      line=__LINE__, file=__FILE__)) return
    fptr = value

  end subroutine FillInternalField

  !============================================================================
  !> @brief Obtém ponteiro para campo (falha se o campo não existir no State).
  !============================================================================
  subroutine GetFieldPtr(state, name, ptr, rc)
    type(ESMF_State),            intent(in)    :: state
    character(len=*),            intent(in)    :: name
    real(ESMF_KIND_R8), pointer, intent(inout) :: ptr(:,:)
    integer,                     intent(out)   :: rc

    type(ESMF_Field) :: field
    integer :: localrc

    rc = ESMF_SUCCESS
    nullify(ptr)

    call ESMF_StateGet(state, trim(name), field, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    call ESMF_FieldGet(field, farrayPtr=ptr, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

  end subroutine GetFieldPtr

  !============================================================================
  !> @brief Obtém ponteiro para campo sem gerar log de erro quando ausente.
  !!
  !! Enumera os itens do State e verifica existência do nome ANTES de chamar
  !! ESMF_StateGet pelo nome. Impede mensagens "no ESMF_Field found named: X"
  !! no log para campos opcionais Fase 2 (Sa_shum_mpas, Faxa_snow_mpas).
  !============================================================================
  subroutine GetFieldPtrOptional(state, name, ptr, rc)
    type(ESMF_State),            intent(in)    :: state
    character(len=*),            intent(in)    :: name
    real(ESMF_KIND_R8), pointer, intent(inout) :: ptr(:,:)
    integer,                     intent(out)   :: rc

    type(ESMF_Field)               :: field
    integer                        :: itemCount, i, localrc
    character(len=64), allocatable :: itemNames(:)
    logical                        :: found

    rc = ESMF_SUCCESS
    nullify(ptr)

    call ESMF_StateGet(state, itemCount=itemCount, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    if (itemCount == 0) then
      rc = ESMF_FAILURE; return
    end if

    allocate(itemNames(itemCount))
    call ESMF_StateGet(state, itemNameList=itemNames, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      deallocate(itemNames); rc = ESMF_FAILURE; return
    end if

    found = .false.
    do i = 1, itemCount
      if (trim(itemNames(i)) == trim(name)) then
        found = .true.; exit
      end if
    end do
    deallocate(itemNames)

    if (.not. found) then
      rc = ESMF_FAILURE; return
    end if

    call ESMF_StateGet(state, trim(name), field, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    call ESMF_FieldGet(field, farrayPtr=ptr, rc=localrc)
    if (localrc /= ESMF_SUCCESS) then
      rc = ESMF_FAILURE; return
    end if

    rc = ESMF_SUCCESS

  end subroutine GetFieldPtrOptional

  !============================================================================
  !> @brief Regrid ATM→OCN com fallback quando routehandle ainda não foi criado.
  !!
  !! Correção 3: ramo else adicionado para rh_created = .false.
  !! Sem o else, campos exportados ao OCN ficavam zerados silenciosamente
  !! quando routehandles não estavam criados (1º passo ou erro na IDC).
  !! Com o else, faz regrid on-the-fly via ESMF_FieldRegridStore temporário.
  !============================================================================
  subroutine RegridOrCopy(src_field, dst_state, dst_name, is, rc)
    type(ESMF_Field),        intent(inout) :: src_field
    type(ESMF_State),        intent(inout) :: dst_state
    character(len=*),        intent(in)    :: dst_name
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    type(ESMF_Field) :: dst_field
    type(ESMF_RouteHandle) :: rh_tmp
    real(ESMF_KIND_R8), pointer :: dst_ptr(:,:)

    rc = ESMF_SUCCESS

    call ESMF_StateGet(dst_state, itemName=trim(dst_name), field=dst_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="RegridOrCopy: "//trim(dst_name), &
      line=__LINE__, file=__FILE__)) return

    if (is%rh_created) then
      call ESMF_FieldRegrid(src_field, dst_field, is%rh_atm2ocn, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="RegridOrCopy: falha no regrid de "//trim(dst_name), &
        line=__LINE__, file=__FILE__)) return
      ! Sanitizar NaNs
      call ESMF_FieldGet(dst_field, farrayPtr=dst_ptr, rc=rc)
      where (dst_ptr /= dst_ptr) dst_ptr = 0.0_ESMF_KIND_R8
    else
      ! Routehandle ainda não disponível: regrid temporário nearest-stod
      call ESMF_FieldRegridStore( &
        srcField       = src_field,    &
        dstField       = dst_field,    &
        routehandle    = rh_tmp,       &
        regridmethod   = ESMF_REGRIDMETHOD_NEAREST_STOD, &
        unmappedaction = ESMF_UNMAPPEDACTION_IGNORE, &
        rc             = rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="RegridOrCopy fallback: falha store "//trim(dst_name), &
        line=__LINE__, file=__FILE__)) return
      call ESMF_FieldRegrid(src_field, dst_field, rh_tmp, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
      if (ESMF_LogFoundError(rcToCheck=rc, &
        msg="RegridOrCopy fallback: falha regrid "//trim(dst_name), &
        line=__LINE__, file=__FILE__)) return
      call ESMF_RouteHandleDestroy(rh_tmp, nogarbage=.true., rc=rc)
      call ESMF_FieldGet(dst_field, farrayPtr=dst_ptr, rc=rc)
      where (dst_ptr /= dst_ptr) dst_ptr = 0.0_ESMF_KIND_R8
    end if

  end subroutine RegridOrCopy

  !============================================================================
  !> @brief Roteia campos oceânicos para a atmosfera (Fase 2 — MOM6 dinâmico).
  !!
  !! Fase 2 (MOM6 dinâmico — grade tripolar B-grid):
  !!   Chamada em MediatorAdvance quando use_med_to_mpas=.true. (nuopc.input).
  !!   O conector direto OCN→MPAS não existe neste modo; tudo passa pelo MED.
  !!
  !! Campos processados:
  !!   So_t (SST), Si_ifrac, So_u, So_v, Sf_zorl — ver MediatorAdvance para detalhes.
  !!   Sf_zorl: calculada pelo bulk NCAR via Charnock + Smith (1988).
  !!
  !! Sprint B (Mai/2026): So_u/So_v agora anunciados no exportState do MED.
  !!   Preenchimento via RegridOrCopy(is%f_uocn_atm/f_vocn_atm → So_u/So_v).
  !!   RegridOptionalCurrent desativado para So_u/So_v (Sprint B os anuncia).
  !============================================================================
  subroutine RouteOcnToAtm(importState, exportState, clock, is, rc)
    type(ESMF_State),        intent(inout) :: importState
    type(ESMF_State),        intent(inout) :: exportState
    type(ESMF_Clock),        intent(in)    :: clock
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    type(ESMF_Field) :: field_ocn, field_atm
    real(ESMF_KIND_R8), pointer :: ptr_atm(:,:)
    type(ESMF_StateItem_Flag)   :: itemType

    real(ESMF_KIND_R8), parameter :: SST_FILL_LAND = 271.35_ESMF_KIND_R8  ! [K]
    integer :: i, j

    rc = ESMF_SUCCESS
    nullify(ptr_atm)

    ! Guard: routehandles devem estar criados para Fase 2
    if (.not. is%rh_created) then
      call ESMF_LogWrite( &
        'MED RouteOcnToAtm: rh_ocn2atm nao criado — pulando Fase 2', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
      return
    end if

    ! So_t: tratado por RegridOrCopy no MediatorAdvance — sem ação adicional aqui.

    ! Si_ifrac: regrid OCN→ATM e exportação feitos no Sprint A.5.2
    !           dentro de MediatorAdvance — sem ação adicional aqui.

    ! So_u/So_v: Sprint B — preenchimento via RegridOrCopy no MediatorAdvance.
    !   RegridOptionalCurrent desativado para evitar conflito de grade
    !   (exportState.So_u/v vive na grade OCN após Sprint B).

    ! FIX B-ICEREGRID-03 (Set/2026): bloco DESATIVADO. Fazia copia DIRETA
    ! ponto-a-ponto de Si_ifrac_sis2 (grade tripolar do SIS2) para Si_ifrac
    ! (grade do ATM) sem regrid nenhum — so' protegido por uma checagem de
    ! FORMA (shape), que passava porque as duas grades coincidentemente tem
    ! as mesmas dimensoes (360x180) nesta configuracao, apesar de serem
    ! GEOMETRICAMENTE diferentes. Perto do fold tripolar (Artico) isso
    ! produzia valores sem relacao com a posicao real — exatamente a causa
    ! do sumico de gelo visto no monan2_import_*.nc mesmo depois do
    ! B-ICEREGRID-02 ja ter corrigido o regrid propriamente dito em
    ! is%f_ifrac_atm (medido por FIX-DIAG-SPRINTB2-01, que mostrava valores
    ! saudaveis) — esta rotina roda DEPOIS daquele regrid e sobrescrevia o
    ! resultado correto com a copia crua.
    !
    ! Redundante agora: o regrid mascarado + extrapolacao de vizinhanca
    ! (B-ICEREGRID-01/02, dentro de MediatorAdvance) ja preenche
    ! is%f_ifrac_atm corretamente e ja e' exportado para "Si_ifrac" via
    ! RegridOrCopy antes desta rotina ser chamada — nao ha mais nada a
    ! fazer aqui.
    !
    ! if (cfg_use_sis2_dynamic) then
    !   [bloco original removido — ver historico do arquivo/controle de
    !   versao para o codigo completo, caso seja necessario reativar como
    !   referencia]
    ! end if

    ! Estampilar timestamp no exportState (MPAS usa para validação)
    call NUOPC_SetTimestamp(exportState, clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg='MED RouteOcnToAtm: falha NUOPC_SetTimestamp', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('MED RouteOcnToAtm: regrid OCN->ATM concluido (Fase 2)', &
      ESMF_LOGMSG_INFO)

  end subroutine RouteOcnToAtm

  !============================================================================
  !> @brief Realiza regrid OCN→ATM silencioso para um campo opcional.
  !!
  !! Verifica existência do campo nos dois States via ESMF_StateGet(itemSearch=...)
  !! antes de obter os Fields, evitando mensagens de erro para campos opcionais.
  !!
  !! Desativado no Sprint B para So_u/So_v (que agora são anunciados).
  !============================================================================
  subroutine RegridOptionalCurrent(importState, exportState, fieldName, rh)
    type(ESMF_State),       intent(inout) :: importState
    type(ESMF_State),       intent(inout) :: exportState
    character(len=*),       intent(in)    :: fieldName
    type(ESMF_RouteHandle), intent(inout) :: rh

    integer          :: rc_loc
    integer          :: n_imp, n_exp
    type(ESMF_Field) :: f_ocn, f_atm

    rc_loc = ESMF_SUCCESS

    call ESMF_StateGet(importState, itemSearch=trim(fieldName), &
      itemCount=n_imp, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS .or. n_imp <= 0) return

    call ESMF_StateGet(exportState, itemSearch=trim(fieldName), &
      itemCount=n_exp, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS .or. n_exp <= 0) return

    call ESMF_StateGet(importState, trim(fieldName), f_ocn, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS) return

    call ESMF_StateGet(exportState, trim(fieldName), f_atm, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS) return

    call ESMF_FieldRegrid(f_ocn, f_atm, rh, &
      zeroregion=ESMF_REGION_TOTAL, rc=rc_loc)

    if (rc_loc == ESMF_SUCCESS) then
      call ESMF_LogWrite( &
        'MED RouteOcnToAtm: regrid OCN->ATM aplicado em ' // trim(fieldName), &
        ESMF_LOGMSG_INFO)
    end if

  end subroutine RegridOptionalCurrent

  !============================================================================
  !> @brief Extrapolação por vizinhança (3x3, media iterativa) para preencher
  !!   celulas invalidas apos regrid — generalização do algoritmo validado
  !!   para So_t (FIX B-OCNGRID-04/05, "costura do Indico desapareceu",
  !!   Ago/2026), parametrizado por faixa fisica valida em vez de fixo em
  !!   temperatura. Usado pelo FIX B-ICEREGRID-01 para os campos do gelo
  !!   (Si_ifrac_sis2, albedo, Si_t_sis2), que antes nao tinham NENHUM
  !!   tratamento de borda/costura apos o regrid bilinear.
  !!
  !! IMPORTANTE (mesma ressalva do algoritmo original): o loop e' LOCAL ao
  !! DE de cada PET — um buraco que atravessa a fronteira entre PETs pode
  !! nao fechar por vizinhanca aqui, mesmo com N_ITER grande. O fallback
  !! constante (vfill) ao final garante que nenhum ponto fique de fato
  !! indefinido.
  !!
  !! FIX B-NEIGHBORFILL-02 (Set/2026): revisao do FIX B-NEIGHBORFILL-01.
  !! Reduzir max_iter (40->5) resolvia o "vazamento" de valor real por
  !! longa distancia (ver FIX-DIAG-ICEGEO-01), mas criava o problema
  !! OPOSTO: buraco real e LOCAL (perto do fold tripolar) maior que 5
  !! celulas de largura deixa de fechar com vizinho de verdade e cai no
  !! vfill -- ou seja, gelo real passa a DESAPARECER onde antes (com
  !! max_iter=40) apenas "vazava" para o lugar errado. Os dois sao
  !! defeitos do MESMO mecanismo (difusao sem limite de escala), nao
  !! contraditorios entre si.
  !!
  !! Correcao: FRAC_INVALID_SKIP verifica ANTES de iterar se a fracao de
  !! celulas invalidas e' grande demais para ser um "buraco local" legitimo
  !! (deformacao de malha). Se for, pula a difusao inteira e cai direto no
  !! vfill -- um dominio com, digamos, mais de 25% invalido e' sinal de
  !! problema no regrid/mascara upstream, nao algo que extrapolacao deva
  !! tentar adivinhar. Para o caso restante (fracao pequena, buraco
  !! genuinamente local), max_iter volta a um valor generoso o bastante
  !! para fechar com dado real proximo, sem o risco de arrastar valor por
  !! dezenas de graus, porque o caso "dominio muito invalido" -- que era o
  !! que permitia esse arrasto de longo alcance -- ja foi filtrado acima.
  !!
  !! @param[inout] arr      Campo 2D a corrigir in-place
  !! @param[in]    vmin     Limite fisico inferior valido
  !! @param[in]    vmax     Limite fisico superior valido
  !! @param[in]    vfill    Valor de fallback final para celulas sem nenhum
  !!                         vizinho valido apos max_iter iteracoes OU
  !!                         quando a fracao invalida inicial e' grande
  !!                         demais para difusao local (ver FRAC_INVALID_SKIP)
  !! @param[out]   rc       Codigo de retorno (sempre ESMF_SUCCESS; a rotina
  !!                         nao falha, so' preenche o melhor que consegue)
  !! @param[in]    max_iter Opcional. Alcance maximo (em celulas) da difusao
  !!                         de vizinhanca, usado SO' quando a fracao
  !!                         invalida inicial esta' abaixo de FRAC_INVALID_SKIP.
  !!                         Default 15 -- fecha buracos locais razoaveis
  !!                         (varias celulas de largura) sem arrastar valor
  !!                         por dezenas de graus, ja que o caso de dominio
  !!                         amplamente invalido e' tratado separadamente.
  !============================================================================
  subroutine NeighborFillExtrapolate(arr, vmin, vmax, vfill, rc, max_iter)
    real(ESMF_KIND_R8), intent(inout) :: arr(:,:)
    real(ESMF_KIND_R8), intent(in)    :: vmin, vmax, vfill
    integer,             intent(out)   :: rc
    integer, optional,   intent(in)    :: max_iter

    real(ESMF_KIND_R8), parameter :: FRAC_INVALID_SKIP = 0.25_ESMF_KIND_R8
    integer :: N_ITER
    real(ESMF_KIND_R8), allocatable :: tmp(:,:)
    logical,            allocatable :: valid(:,:)
    integer :: i1,iN,j1,jN,i2,j2,ii2,jj2,it,nbr
    real(ESMF_KIND_R8) :: acc, frac_invalid_ini

    N_ITER = 15
    if (present(max_iter)) N_ITER = max_iter

    rc = ESMF_SUCCESS
    i1=lbound(arr,1); iN=ubound(arr,1); j1=lbound(arr,2); jN=ubound(arr,2)

    ! NaN/Inf tambem tratados como invalidos (empurrados para fora da faixa
    ! valida de proposito, para participar do loop de extrapolacao).
    where (arr /= arr) arr = vmin - 1.0_ESMF_KIND_R8

    allocate(valid(i1:iN,j1:jN), tmp(i1:iN,j1:jN))
    valid = (arr >= vmin .and. arr <= vmax)

    ! FIX B-NEIGHBORFILL-02: fracao invalida grande demais para ser um
    ! "buraco local" legitimo -- pula a difusao inteira, cai direto no
    ! vfill. Um dominio amplamente invalido e' sinal de problema no
    ! regrid/mascara upstream; tentar preencher por difusao aqui so' troca
    ! um sintoma por outro (buraco vira valor arrastado de longe).
    frac_invalid_ini = real(count(.not. valid), ESMF_KIND_R8) / &
                        real(size(valid), ESMF_KIND_R8)
    if (frac_invalid_ini > FRAC_INVALID_SKIP) then
      where (.not. valid) arr = vfill
      call ESMF_LogWrite('MED NeighborFillExtrapolate: fracao invalida ' // &
        'inicial acima do limiar -- difusao pulada, fallback direto ' // &
        '(ver FIX B-NEIGHBORFILL-02; investigar regrid/mascara upstream)', &
        ESMF_LOGMSG_WARNING)
      deallocate(valid, tmp)
      return
    end if

    do it = 1, N_ITER
      if (count(.not. valid) == 0) exit
      tmp = arr
      do j2 = j1, jN
        do i2 = i1, iN
          if (valid(i2,j2)) cycle
          acc = 0.0_ESMF_KIND_R8; nbr = 0
          do jj2 = max(j1,j2-1), min(jN,j2+1)
            do ii2 = max(i1,i2-1), min(iN,i2+1)
              if (valid(ii2,jj2)) then
                acc = acc + arr(ii2,jj2); nbr = nbr + 1
              end if
            end do
          end do
          if (nbr > 0) tmp(i2,j2) = acc / real(nbr, ESMF_KIND_R8)
        end do
      end do
      arr = tmp
      valid = (arr >= vmin .and. arr <= vmax)
    end do
    ! Fallback final: qualquer celula que sobrou sem NENHUM vizinho valido
    ! apos N_ITER (raro; tipicamente so' em buracos que atravessam fronteira
    ! de PET) cai no valor constante de seguranca.
    where (.not. valid) arr = vfill
    deallocate(valid, tmp)

  end subroutine NeighborFillExtrapolate

end module med_cap_methods_mod
