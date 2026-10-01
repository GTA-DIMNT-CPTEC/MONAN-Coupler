!> @file med_cap_methods.F90
!! @brief Utilitários de manipulação de campos ESMF/NUOPC do mediador.
!!
!! Utilitários do mediador separados de MED_cap.F90:
!!
!!   CreateInternalField        cria campo ESMF na grade interna
!!   ZeroInternalField          zera campo com guard
!!   ZeroOcnFluxFields          zera os fluxos enviados ao oceano
!!   FillInternalField          preenche campo com valor constante
!!   GetFieldPtr                obtém ponteiro de campo (falha se ausente)
!!   GetFieldPtrOptional        obtém ponteiro sem erro de log para campos opcionais
!!   RegridOrCopy               regrid ATM→OCN com fallback temporário
!!   RouteOcnToAtm              exporta campos OCN→ATM via mediador
!!   spec_da_rota               configuração de uma rota na tabela ROTAS
!!   completar_da_rota          preenchimento por vizinhança de uma rota de ROTAS
!!   cria_rota                  cria uma rota com a configuração de ROTAS
!!   set_ocn_grid_mask          copia So_omask para a máscara da grade OCN

module med_cap_methods_mod

  use ESMF
  use regrid_manager_mod, only : regrid_spec, regrid_manager_t
  use regrid_base_mod,    only : regrid_spec_t, regrid_fill_t
  use cpl_map_mod,        only : ROTAS, cpl_rota_indice, CPL_AUSENTE
  use NUOPC, only: NUOPC_SetTimestamp

  use med_cap_types_mod, only: MED_InternalState, med_ocn_flux_fields_t
  use coupler_config_mod, only: cfg_use_sis2_dynamic

  use coupler_utils_mod, only : ChkErr

  implicit none
  private

  public :: CreateInternalField
  public :: ZeroInternalField
  public :: ZeroOcnFluxFields
  public :: FillInternalField
  public :: GetFieldPtr
  public :: GetFieldPtrOptional
  public :: RegridOrCopy
  public :: RouteOcnToAtm
  public :: spec_da_rota
  public :: completar_da_rota
  public :: cria_rota
  public :: set_ocn_grid_mask



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
  ! > @brief Zera um campo ESMF com guard para PETs sem DE local.
  !!
  !! ESMF_FieldGet(farrayPtr) falha com "localDe is out of range"
  !! em PETs sem DE local (localDeCount=0). Verificar antes de acessar.
  !============================================================================
  subroutine ZeroInternalField(field, rc)
    type(ESMF_Field), intent(inout) :: field
    integer,          intent(out)   :: rc

    call FillInternalField(field, 0.0_ESMF_KIND_R8, rc)

  end subroutine ZeroInternalField

  !============================================================================
  !> @brief Zera os doze fluxos enviados ao oceano, sempre na mesma ordem.
  !!
  !! Usada na criação dos campos internos (med_init) e no início de cada
  !! passo (med_flux). O rc final é o do último campo, como antes.
  !! @param[inout] flx  fluxos do mediador para o oceano
  !! @param[out]   rc   código de retorno ESMF
  !============================================================================
  subroutine ZeroOcnFluxFields(flx, rc)
    type(med_ocn_flux_fields_t), intent(inout) :: flx
    integer,                     intent(out)   :: rc

    call ZeroInternalField(flx%taux,   rc)
    call ZeroInternalField(flx%tauy,   rc)
    call ZeroInternalField(flx%sen,    rc)
    call ZeroInternalField(flx%evap,   rc)
    call ZeroInternalField(flx%lwnet,  rc)
    call ZeroInternalField(flx%swvdr,  rc)
    call ZeroInternalField(flx%swvdf,  rc)
    call ZeroInternalField(flx%swidr,  rc)
    call ZeroInternalField(flx%swidf,  rc)
    call ZeroInternalField(flx%rain,   rc)
    call ZeroInternalField(flx%snow,   rc)
    call ZeroInternalField(flx%pslv,   rc)

  end subroutine ZeroOcnFluxFields

  !============================================================================
  !> @brief Preenche campo ESMF com valor constante.
  !! Guard PETs sem DE local não têm dados a preencher.
  !============================================================================
  subroutine FillInternalField(field, value, rc)
    type(ESMF_Field),   intent(inout) :: field
    real(ESMF_KIND_R8), intent(in)    :: value
    integer,            intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: fptr(:,:)
    integer :: localDeCount_f
    rc = ESMF_SUCCESS

    call ESMF_FieldGet(field, localDeCount=localDeCount_f, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (localDeCount_f == 0) return

    call ESMF_FieldGet(field, farrayPtr=fptr, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
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
  !! no log para campos opcionais (Sa_shum_mpas, Faxa_snow_mpas).
  !============================================================================
  subroutine GetFieldPtrOptional(state, name, ptr, rc)
    type(ESMF_State),            intent(in)    :: state
    character(len=*),            intent(in)    :: name
    real(ESMF_KIND_R8), pointer, intent(inout) :: ptr(:,:)
    integer,                     intent(out)   :: rc

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

    call GetFieldPtr(state, name, ptr, rc)

  end subroutine GetFieldPtrOptional

  !============================================================================
  !> @brief Regrid ATM→OCN com fallback quando routehandle ainda não foi criado.
  !!
  !! Quando as rotas ainda não foram criadas (1º passo ou erro na IDC), faz
  !! o regrid com um ESMF_FieldRegridStore temporário, em vez de deixar
  !! zerados os campos exportados ao OCN.
  !============================================================================
  subroutine RegridOrCopy(src_field, dst_state, dst_name, is, rc)
    type(ESMF_Field),        intent(inout) :: src_field
    type(ESMF_State),        intent(inout) :: dst_state
    character(len=*),        intent(in)    :: dst_name
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    type(ESMF_Field) :: dst_field

    rc = ESMF_SUCCESS

    call ESMF_StateGet(dst_state, itemName=trim(dst_name), field=dst_field, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="RegridOrCopy: "//trim(dst_name), &
      line=__LINE__, file=__FILE__)) return

    ! A rota atm2ocn serve a qualquer par (grade ATM, grade OCN); se ainda
    ! não existe, é criada com este par.
    if (.not. is%regrid%has('atm2ocn')) then
      call cria_rota(is%regrid, 'atm2ocn', src_field, dst_field, rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end if
    ! A rota zera o destino antes e troca os NaN por zero (ROTAS: sem_valor
    ! 'zerar', nan_para 0).
    call is%regrid%apply('atm2ocn', src_field, dst_field, rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg="RegridOrCopy: falha no regrid de "//trim(dst_name), &
      line=__LINE__, file=__FILE__)) return

  end subroutine RegridOrCopy

  !============================================================================
  !> @brief Roteia campos oceânicos para a atmosfera (MOM6 dinâmico).
  !!
  !! MOM6 dinâmico (grade tripolar B-grid):
  !!   Chamada em MediatorAdvance quando use_med_to_mpas=.true. (nuopc.input).
  !!   O conector direto OCN→MPAS não existe neste modo; tudo passa pelo MED.
  !!
  !! Campos processados:
  !!   So_t (SST), Si_ifrac, So_u, So_v, Sf_zorl — ver MediatorAdvance para detalhes.
  !!   Sf_zorl: calculada pelo bulk NCAR via Charnock + Smith (1988).
  !!
  !============================================================================
  subroutine RouteOcnToAtm(importState, exportState, clock, is, rc)
    type(ESMF_State),        intent(inout) :: importState
    type(ESMF_State),        intent(inout) :: exportState
    type(ESMF_Clock),        intent(in)    :: clock
    type(MED_InternalState), intent(inout) :: is
    integer,                 intent(out)   :: rc

    real(ESMF_KIND_R8), pointer :: ptr_atm(:,:)


    rc = ESMF_SUCCESS
    nullify(ptr_atm)

    ! Guard: routehandles devem estar criados
    if (.not. is%regrid%has('ocn2atm')) then
      call ESMF_LogWrite( &
        'MED RouteOcnToAtm: rota ocn2atm ainda nao criada; pulando', &
        ESMF_LOGMSG_WARNING)
      rc = ESMF_SUCCESS
      return
    end if

    ! So_t, Si_ifrac, So_u e So_v ja foram regridados e exportados por
    ! RegridOrCopy em MediatorAdvance; aqui resta apenas o carimbo de tempo.

    ! Estampilar timestamp no exportState (MPAS usa para validação)
    call NUOPC_SetTimestamp(exportState, clock, rc=rc)
    if (ESMF_LogFoundError(rcToCheck=rc, &
      msg='MED RouteOcnToAtm: falha NUOPC_SetTimestamp', &
      line=__LINE__, file=__FILE__)) return

    call ESMF_LogWrite('MED RouteOcnToAtm: regrid OCN->ATM concluido (Fase 2)', &
      ESMF_LOGMSG_INFO)

  end subroutine RouteOcnToAtm



  !============================================================================
  !> @brief Configuração da rota nome na tabela ROTAS (cpl_map): métodos em
  !! ordem de preferência, esquema, máscara na origem (se a rota tem
  !! mascara), o que fazer com os pontos do destino que a interpolação não
  !! alcança (sem_valor: 'zerar' zera o destino inteiro antes, zero_total;
  !! 'manter' e 'sentinela' preservam o valor anterior), a troca de NaN no
  !! destino (nan_para), o preenchimento por vizinhança depois da
  !! interpolação (completar) e a rota de reserva ('' se não tem). ok = .false.
  !! se a rota não está em ROTAS. O grupo &nuopc_regrid do nuopc.input
  !! continua podendo trocar o esquema e os métodos (regrid_manager,
  !! apply_config).
  !!
  !! 'sentinela' só diz que o destino não é zerado: quem usa a rota
  !! preenche o destino com a sentinela antes (o gelo, em med_ice e
  !! med_export), porque o preenchimento vale mesmo quando a rota não é
  !! aplicada.
  !============================================================================
  subroutine spec_da_rota(nome, spec, reserva, ok)
    character(len=*),    intent(in)  :: nome
    type(regrid_spec_t), intent(out) :: spec
    character(len=*),    intent(out) :: reserva
    logical,             intent(out) :: ok
    integer :: k

    reserva = ''
    k = cpl_rota_indice(nome)
    ok = k > 0
    if (.not. ok) return
    spec = regrid_spec(trim(ROTAS(k)%metodos), scheme=trim(ROTAS(k)%esquema), &
                       mask_src=len_trim(ROTAS(k)%mascara) > 0, &
                       zero_total=ROTAS(k)%sem_valor == 'zerar')
    if (ROTAS(k)%nan_para /= CPL_AUSENTE) then
      spec%nan_replace = .true.
      spec%nan_value   = ROTAS(k)%nan_para
    end if
    spec%fill = ROTAS(k)%completar
    reserva = ROTAS(k)%reserva
  end subroutine spec_da_rota

  !============================================================================
  !> @brief Preenchimento por vizinhança (coluna completar de ROTAS) da rota
  !! nome; desligado se a rota não está em ROTAS. Serve para completar como
  !! a rota quando ela ainda não existe e outra interpola no lugar dela (a
  !! SST pela rota ocn2atm enquanto a máscara do oceano é uniforme).
  !============================================================================
  function completar_da_rota(nome) result(fill)
    character(len=*), intent(in) :: nome
    type(regrid_fill_t) :: fill
    integer :: k

    fill = regrid_fill_t()
    k = cpl_rota_indice(nome)
    if (k > 0) fill = ROTAS(k)%completar
  end function completar_da_rota

  !============================================================================
  !> @brief Cria a rota nome em regrid com a configuração de ROTAS, e com a
  !! rota de reserva da tabela, quando houver.
  !============================================================================
  subroutine cria_rota(regrid, nome, src, dst, rc)
    type(regrid_manager_t), intent(inout) :: regrid
    character(len=*),       intent(in)    :: nome
    type(ESMF_Field),       intent(inout) :: src, dst
    integer,                intent(out)   :: rc
    type(regrid_spec_t) :: spec
    character(len=32)   :: reserva
    logical :: ok

    call spec_da_rota(nome, spec, reserva, ok)
    if (.not. ok) then
      call ESMF_LogSetError(ESMF_RC_ARG_VALUE, msg='MED: rota fora de ROTAS: '//trim(nome), &
        line=__LINE__, file=__FILE__, rcToReturn=rc)
      return
    end if
    if (len_trim(reserva) > 0) then
      call regrid%add(nome, spec, src, dst, rc, fallback=trim(reserva))
    else
      call regrid%add(nome, spec, src, dst, rc)
    end if
  end subroutine cria_rota

  !============================================================================
  !> @brief Copia So_omask (1 = oceano, 0 = terra) do importState para o item
  !! de máscara de ocn_grid, DE a DE, e conta os pontos de terra e de
  !! oceano deste PET. É a máscara que as rotas com mascara em ROTAS usam
  !! na origem (valores excluídos: terra = 0).
  !!
  !! achou: So_omask está no importState; copiou: algum DE recebeu a
  !! máscara.
  !============================================================================
  subroutine set_ocn_grid_mask(ocn_grid, importState, n_terra, n_mar, achou, copiou)
    type(ESMF_Grid),  intent(inout) :: ocn_grid
    type(ESMF_State), intent(inout) :: importState
    integer,          intent(out)   :: n_terra, n_mar
    logical,          intent(out)   :: achou, copiou
    real(ESMF_KIND_R8), pointer    :: omask_src(:,:)
    integer(ESMF_KIND_I4), pointer :: maskptr(:,:)
    type(ESMF_Field) :: omask_field
    integer :: lde, ldec, rc

    n_terra = 0; n_mar = 0; copiou = .false.
    call ESMF_StateGet(importState, itemName="So_omask", field=omask_field, rc=rc)
    achou = rc == ESMF_SUCCESS
    if (.not. achou) return
    call ESMF_GridGet(ocn_grid, localDeCount=ldec, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    do lde = 0, ldec - 1
      call ESMF_FieldGet(omask_field, localDe=lde, farrayPtr=omask_src, rc=rc)
      if (rc /= ESMF_SUCCESS .or. .not. associated(omask_src)) cycle
      call ESMF_GridGetItem(ocn_grid, itemflag=ESMF_GRIDITEM_MASK, &
        staggerloc=ESMF_STAGGERLOC_CENTER, localDE=lde, &
        farrayPtr=maskptr, rc=rc)
      if (rc == ESMF_SUCCESS .and. associated(maskptr)) then
        maskptr = nint(omask_src)
        n_terra = n_terra + count(maskptr == 0)
        n_mar   = n_mar   + count(maskptr == 1)
        copiou  = .true.
      end if
    end do
  end subroutine set_ocn_grid_mask

end module med_cap_methods_mod
