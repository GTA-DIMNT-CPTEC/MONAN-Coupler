!> @file cpl_check.F90
!! @brief O que o acoplamento registra no NUOPC e confere: dicionário de
!! campos, método dos conectores, conferência do mapa e relatório dos
!! conectores no log.
!!
!! cpl_nuopc_dictionary é chamada pelo driver (esm.F90) antes de criar os
!! componentes: registra no dicionário do NUOPC os nomes de FIELDS
!! (cpl_fields), com a unidade de cada um, e desliga o acréscimo automático;
!! um nome fora de FIELDS para a rodada no anúncio, com a mensagem do NUOPC
!! "<nome> is not a StandardName in the NUOPC_FieldDictionary!".
!!
!! As outras duas rotinas com o driver são chamadas pelo ModifyCplLists do
!! esm.F90, quando os componentes já anunciaram os campos e os conectores já
!! montaram as suas listas (CplList), e antes da realização dos campos:
!!
!!   cpl_write_methods      escreve em cada entrada da CplList a opção
!!                          remapmethod com o método da troca no mapa
!!                          (coluna method de EXCHANGES);
!!   cpl_check_coupling     escreve no log do PET 0, com o prefixo
!!                          CPL-REL:, duas coisas:
!!     relatório dos conectores  para cada conector do driver, os campos da
!!                               CplList e as opções de cada um;
!!     conferência do mapa       compara o mapa (cpl_map, na configuração
!!                               lida do nuopc.input) com o que o driver
!!                               montou: a CplList de cada conector contra as
!!                               trocas do mapa entre os dois componentes,
!!                               inclusive o método de cada campo; o
!!                               importState de cada componente contra as
!!                               trocas que chegam a ele; o exportState
!!                               contra as que partem dele.
!!
!! Cada diferença vira uma linha "CPL-REL: DIFERENCA: ..."; campos exportados
!! que nenhum componente consome viram "CPL-REL: AVISO: ...", porque são
!! normais (o MOM6 exporta So_s, por exemplo), e também as lacunas conhecidas
!! da tabela GAPS do mapa ("AVISO: lacuna conhecida: ..."). Havendo
!! diferença, cpl_check_coupling devolve erro em todos os PETs, depois de
!! escrever o relatório inteiro, e a inicialização para. Um erro do ESMF
!! durante a consulta só é registrado.
!!
!! As rotinas cpl_check_connector_fields, cpl_check_methods e cpl_check_state
!! não usam o ESMF e são testadas em tests/unit/test_cpl_check.F90; a rotina do driver é
!! exercitada por tests/cplcheck/.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module cpl_check_mod

  use ESMF
  use NUOPC,              only : NUOPC_CompAttributeGet, NUOPC_CompAttributeSet, &
                                 NUOPC_GetStateMemberLists
  use NUOPC_Driver,       only : NUOPC_DriverGetComp
  use coupler_utils_mod,  only : int_to_str, ChkErr
  use coupler_log_mod,    only : COMP_DRV, log_error, log_report
  use NUOPC,              only : NUOPC_FieldDictionaryHasEntry, NUOPC_FieldDictionaryAddEntry, &
                                 NUOPC_FieldDictionarySetAutoAdd
  use cpl_fields_mod,     only : cpl_field_index, FIELDS
  use cpl_map_mod,        only : EXCHANGES, cpl_config_t, cpl_exchange_applies, cpl_point_component, &
                                 cpl_connector_method, CPL_METHOD_LEN, &
                                 cpl_is_gap

  implicit none
  private

  public :: cpl_check_coupling, cpl_write_methods, cpl_nuopc_dictionary
  public :: cpl_check_connector_fields, cpl_check_methods, cpl_check_state
  public :: cpl_method_of_entry
  public :: CPL_MSG_LEN

  integer,          parameter :: CPL_MSG_LEN = 200

  !> Opção do conector NUOPC que escolhe o método de interpolação.
  character(len=*), parameter :: OPT_METHOD = 'remapmethod='

contains

  !> @brief Dicionário do NUOPC com os campos de FIELDS, e sem acréscimo automático.
  !!
  !! Cada nome entra com a unidade da coluna units de FIELDS ('1' se
  !! vazia); um nome que o dicionário já tenha não é registrado de novo. O
  !! NUOPC grava a unidade no atributo Units de cada campo anunciado.
  !!
  !! @param[out] rc  código de retorno do ESMF
  subroutine cpl_nuopc_dictionary(rc)
    integer, intent(out) :: rc

    integer :: k
    logical :: exists

    rc = ESMF_SUCCESS
    do k = 1, size(FIELDS)
      exists = NUOPC_FieldDictionaryHasEntry(trim(FIELDS(k)%name), rc=rc)
      if (ChkErr(rc, __LINE__, __FILE__)) return
      if (exists) cycle
      if (len_trim(FIELDS(k)%units) > 0) then
        call NUOPC_FieldDictionaryAddEntry(standardName=trim(FIELDS(k)%name), &
          canonicalUnits=trim(FIELDS(k)%units), rc=rc)
      else
        call NUOPC_FieldDictionaryAddEntry(standardName=trim(FIELDS(k)%name), &
          canonicalUnits='1', rc=rc)
      end if
      if (ChkErr(rc, __LINE__, __FILE__)) return
    end do
    call NUOPC_FieldDictionarySetAutoAdd(.false., rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
  end subroutine cpl_nuopc_dictionary

  !> @brief Escreve em cada entrada da CplList dos conectores a opção remapmethod
  !! com o método da troca no mapa (cpl_connector_method).
  !!
  !! Entradas que já tragam remapmethod não são alteradas, nem as de campos
  !! sem troca por conector no mapa (a conferência do mapa, depois, acusa as
  !! duas situações se o método não for o do mapa). Os conectores são
  !! procurados pelos pares de rótulos, como na conferência.
  !!
  !! @param[inout] driver       driver NUOPC, depois da montagem das CplList
  !! @param[in]    labels       rótulos dos componentes no driver ('MPAS', ...)
  !! @param[in]    components   componente do mapa de cada rótulo ('ATM', ...)
  !! @param[out]   n_method     entradas que receberam a opção
  !! @param[out]   n_full       entradas sem espaço para a opção (o chamador
  !!                            trata como erro)
  !! @param[out]   rc           código de retorno do ESMF
  subroutine cpl_write_methods(driver, labels, components, n_method, n_full, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    character(len=*),    intent(in)    :: labels(:)
    character(len=*),    intent(in)    :: components(:)
    integer,             intent(out)   :: n_method, n_full
    integer,             intent(out)   :: rc

    type(ESMF_CplComp) :: connector
    character(len=512), allocatable :: list(:)
    character(len=CPL_METHOD_LEN) :: method
    character(len=:), allocatable :: option
    integer :: i, j, k, n, p

    rc = ESMF_SUCCESS
    n_method = 0
    n_full   = 0
    do i = 1, size(labels)
      do j = 1, size(labels)
        if (i == j) cycle
        call NUOPC_DriverGetComp(driver, srcCompLabel=trim(labels(i)), &
                                 dstCompLabel=trim(labels(j)), comp=connector, &
                                 relaxedflag=.true., rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        if (.not. ESMF_CplCompIsCreated(connector)) cycle
        call NUOPC_CompAttributeGet(connector, name='CplList', itemCount=n, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        if (n == 0) cycle

        allocate(list(n))
        call NUOPC_CompAttributeGet(connector, name='CplList', valueList=list, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        do k = 1, n
          if (index(list(k), OPT_METHOD) > 0) cycle
          p = index(list(k), ':')
          if (p == 0) p = len_trim(list(k)) + 1
          method = cpl_connector_method(list(k)(1:p-1), components(i), components(j))
          if (len_trim(method) == 0) cycle
          option = ':'//OPT_METHOD//trim(method)
          if (len_trim(list(k)) + len(option) > len(list(k))) then
            n_full = n_full + 1
            cycle
          end if
          list(k) = trim(list(k))//option
          n_method = n_method + 1
        end do
        call NUOPC_CompAttributeSet(connector, name='CplList', valueList=list, rc=rc)
        if (ChkErr(rc, __LINE__, __FILE__)) return
        deallocate(list)
      end do
    end do
  end subroutine cpl_write_methods

  !> @brief Relatório dos conectores e conferência do mapa, no log do PET 0; erro
  !! em todos os PETs se a conferência acha diferença.
  !!
  !! O PET 0 faz a conferência e escreve o relatório; o número de diferenças
  !! é distribuído a todos os PETs (ESMF_VMBroadcast), que devolvem
  !! ESMF_FAILURE juntos, com uma mensagem de erro no log de cada um.
  !!
  !! @param[inout] driver       driver NUOPC, depois da montagem das CplList
  !! @param[in]    cfg          configuração do mapa (a da rodada: cpl_current_config)
  !! @param[in]    labels       rótulos dos componentes no driver ('MPAS', ...)
  !! @param[in]    components   componente do mapa de cada rótulo ('ATM', ...)
  !! @param[out]   rc           ESMF_FAILURE se houve diferença
  subroutine cpl_check_coupling(driver, cfg, labels, components, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    type(cpl_config_t),  intent(in)    :: cfg
    character(len=*),    intent(in)    :: labels(:)
    character(len=*),    intent(in)    :: components(:)
    integer,             intent(out)   :: rc

    type(ESMF_VM) :: vm
    integer :: localPet, lrc
    integer :: ndif(1)

    rc = ESMF_SUCCESS
    call ESMF_VMGetCurrent(vm, rc=lrc)
    if (lrc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, rc=lrc)
    if (lrc /= ESMF_SUCCESS) return

    ndif = 0
    if (localPet == 0) then
      call check_on_pet0(driver, cfg, labels, components, ndif(1))
      ! o relatório vai para o arquivo antes que um PET possa abortar a rodada
      if (ndif(1) > 0) call ESMF_LogFlush(rc=lrc)
    end if
    call ESMF_VMBroadcast(vm, ndif, 1, 0, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    if (ndif(1) > 0) then
      if (localPet == 0) call log_error(COMP_DRV, 'cpl_check: conferencia do mapa com '// &
        int_to_str(ndif(1))//' diferenca(s) (linhas DIFERENCA do relatorio no log do '// &
        'PET 0); inicializacao interrompida')
      call ESMF_LogFlush(rc=lrc)
      rc = ESMF_FAILURE
    end if
  end subroutine cpl_check_coupling

  !> @brief A conferência e o relatório, no PET 0 (ver cpl_check_coupling).
  subroutine check_on_pet0(driver, cfg, labels, components, ndif)
    type(ESMF_GridComp), intent(inout) :: driver
    type(cpl_config_t),  intent(in)    :: cfg
    character(len=*),    intent(in)    :: labels(:)
    character(len=*),    intent(in)    :: components(:)
    integer,             intent(out)   :: ndif

    character(len=CPL_MSG_LEN), allocatable :: msgs(:)
    integer :: nwarn, i, j

    call write_line('configuracao do mapa: '//describe_config(cfg))
    allocate(msgs(0))
    ndif = 0; nwarn = 0

    do i = 1, size(labels)
      do j = 1, size(labels)
        if (i == j) cycle
        call check_connector(driver, cfg, labels(i), labels(j), components(i), &
                                 components(j), msgs, ndif)
      end do
    end do
    do i = 1, size(labels)
      call check_component(driver, cfg, labels(i), components(i), msgs, ndif, nwarn)
    end do

    do i = 1, size(msgs)
      call write_line(msgs(i))
    end do
    call write_line('conferencia do mapa: '//int_to_str(ndif)//' diferenca(s), '// &
                 int_to_str(nwarn)//' aviso(s)')
  end subroutine check_on_pet0

  !> @brief Relatório da CplList do conector origem -> destino e conferência dela
  !! contra o mapa. Conector ausente só é diferença se o mapa prevê trocas.
  subroutine check_connector(driver, cfg, label_src, label_dst, comp_src, comp_dst, msgs, ndif)
    type(ESMF_GridComp),                     intent(inout) :: driver
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: label_src, label_dst
    character(len=*),                        intent(in)    :: comp_src, comp_dst
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif

    type(ESMF_CplComp) :: connector
    character(len=512), allocatable :: list(:)
    character(len=512), allocatable :: names(:)
    character(len=CPL_METHOD_LEN), allocatable :: methods(:)
    integer :: n, k, p, lrc, nprev
    character(len=:), allocatable :: title

    title = trim(label_src)//' -> '//trim(label_dst)
    call NUOPC_DriverGetComp(driver, srcCompLabel=label_src, dstCompLabel=label_dst, &
                             comp=connector, relaxedflag=.true., rc=lrc)
    if (lrc /= ESMF_SUCCESS) then
      call write_line('AVISO: conector '//title//' nao consultado (erro do ESMF)')
      return
    end if
    if (.not. ESMF_CplCompIsCreated(connector)) then
      nprev = expected_count(cfg, comp_src, comp_dst)
      if (nprev > 0) call append_msg(msgs, ndif, 'DIFERENCA: o mapa preve '//int_to_str(nprev)// &
        ' campo(s) de '//trim(comp_src)//' para '//trim(comp_dst)// &
        ', mas o driver nao registrou o conector '//title)
      return
    end if

    call NUOPC_CompAttributeGet(connector, name='CplList', itemCount=n, rc=lrc)
    if (lrc /= ESMF_SUCCESS) then
      call write_line('AVISO: CplList do conector '//title//' nao consultada (erro do ESMF)')
      return
    end if
    allocate(list(n), names(n), methods(n))
    if (n > 0) then
      call NUOPC_CompAttributeGet(connector, name='CplList', valueList=list, rc=lrc)
      if (lrc /= ESMF_SUCCESS) then
        call write_line('AVISO: CplList do conector '//title//' nao consultada (erro do ESMF)')
        return
      end if
    end if

    call write_line('conector '//title//': '//int_to_str(n)//' campo(s)')
    do k = 1, n
      p = index(list(k), ':')
      if (p == 0) then
        names(k) = trim(list(k))
        call write_line('  '//trim(names(k))//'  (sem opcoes)')
      else
        names(k) = list(k)(1:p-1)
        call write_line('  '//trim(names(k))//'  '//trim(list(k)(p+1:)))
      end if
      methods(k) = cpl_method_of_entry(list(k))
    end do

    call cpl_check_connector_fields(cfg, comp_src, comp_dst, names, msgs, ndif)
    call cpl_check_methods(comp_src, comp_dst, names, methods, msgs, ndif)
  end subroutine check_connector

  !> @brief Conferência do importState e do exportState de um componente.
  subroutine check_component(driver, cfg, label, comp, msgs, ndif, nwarn)
    type(ESMF_GridComp),                     intent(inout) :: driver
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: label, comp
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif, nwarn

    type(ESMF_GridComp) :: gcomp
    type(ESMF_State)    :: imp, exp
    character(len=ESMF_MAXSTR), allocatable :: imp_names(:), exp_names(:)
    integer :: lrc, nprev

    call NUOPC_DriverGetComp(driver, compLabel=label, comp=gcomp, relaxedflag=.true., rc=lrc)
    if (lrc /= ESMF_SUCCESS) then
      call write_line('AVISO: componente '//trim(label)//' nao consultado (erro do ESMF)')
      return
    end if
    if (.not. ESMF_GridCompIsCreated(gcomp)) then
      nprev = expected_count(cfg, comp, '') + expected_count(cfg, '', comp)
      if (nprev > 0) call append_msg(msgs, ndif, 'DIFERENCA: o mapa preve '//int_to_str(nprev)// &
        ' troca(s) por conector com '//trim(comp)//', mas o driver nao registrou '//trim(label))
      return
    end if

    call ESMF_GridCompGet(gcomp, importState=imp, exportState=exp, rc=lrc)
    if (lrc == ESMF_SUCCESS) call state_names(imp, imp_names, lrc)
    if (lrc == ESMF_SUCCESS) call state_names(exp, exp_names, lrc)
    if (lrc /= ESMF_SUCCESS) then
      call write_line('AVISO: estados de '//trim(label)//' nao consultados (erro do ESMF)')
      return
    end if

    call cpl_check_state(cfg, comp, .true.,     imp_names, msgs, ndif, nwarn)
    call cpl_check_state(cfg, comp, .false., exp_names, msgs, ndif, nwarn)
  end subroutine check_component

  !> @brief Nomes padrão (StandardName) dos campos anunciados num State.
  subroutine state_names(state, names, rc)
    type(ESMF_State),                        intent(in)  :: state
    character(len=ESMF_MAXSTR), allocatable, intent(out) :: names(:)
    integer,                                 intent(out) :: rc

    character(len=ESMF_MAXSTR), pointer :: list(:)

    nullify(list)
    call NUOPC_GetStateMemberLists(state, StandardNameList=list, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    if (associated(list)) then
      names = list
      deallocate(list)
    else
      allocate(names(0))
    end if
  end subroutine state_names

  !> @brief Confere a lista de campos de um conector com as trocas do mapa.
  !!
  !! Diferença: campo na lista sem troca ativa por conector de comp_src para
  !! comp_dst; troca ativa do mapa cujo campo não está na lista.
  !!
  !! @param[in]    cfg        configuração (chaves de &nuopc_mode)
  !! @param[in]    comp_src   componente de origem no mapa ('ATM', 'OCN', ...)
  !! @param[in]    comp_dst   componente de destino no mapa
  !! @param[in]    names      campos da CplList, sem as opções
  !! @param[inout] msgs       mensagens acumuladas
  !! @param[inout] ndif       número de diferenças acumulado
  subroutine cpl_check_connector_fields(cfg, comp_src, comp_dst, names, msgs, ndif)
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: comp_src, comp_dst
    character(len=*),                        intent(in)    :: names(:)
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif

    integer :: k, t
    character(len=:), allocatable :: par

    par = trim(comp_src)//' -> '//trim(comp_dst)
    do k = 1, size(names)
      if (count_exchanges(cfg, names(k), comp_src, comp_dst) == 0) &
        call append_msg(msgs, ndif, 'DIFERENCA: o conector '//par//' leva '//trim(names(k))// &
          ', que nao tem troca no mapa')
    end do
    do t = 1, size(EXCHANGES)
      if (.not. exchange_via_connector(t, cfg, comp_src, comp_dst)) cycle
      if (.not. any(names == EXCHANGES(t)%field)) &
        call append_msg(msgs, ndif, 'DIFERENCA: o mapa preve '//trim(EXCHANGES(t)%field)// &
          ' no conector '//par//', que nao o leva')
    end do
  end subroutine cpl_check_connector_fields

  !> @brief Confere o método de cada campo da lista de um conector com o do mapa.
  !!
  !! Diferença: campo com troca por conector no mapa cuja entrada não traz
  !! remapmethod (o conector usaria o seu padrão) ou traz outro método.
  !! Campos sem troca no mapa já são diferença em cpl_check_connector_fields.
  !!
  !! @param[in]    comp_src   componente de origem no mapa
  !! @param[in]    comp_dst   componente de destino no mapa
  !! @param[in]    names      campos da CplList, sem as opções
  !! @param[in]    methods    remapmethod de cada entrada ('' se não tem)
  !! @param[inout] msgs       mensagens acumuladas
  !! @param[inout] ndif       número de diferenças acumulado
  subroutine cpl_check_methods(comp_src, comp_dst, names, methods, msgs, ndif)
    character(len=*),                        intent(in)    :: comp_src, comp_dst
    character(len=*),                        intent(in)    :: names(:), methods(:)
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif

    character(len=CPL_METHOD_LEN) :: expected
    character(len=:), allocatable :: par
    integer :: k

    par = trim(comp_src)//' -> '//trim(comp_dst)
    do k = 1, size(names)
      expected = cpl_connector_method(names(k), comp_src, comp_dst)
      if (len_trim(expected) == 0) cycle
      if (len_trim(methods(k)) == 0) then
        call append_msg(msgs, ndif, 'DIFERENCA: o conector '//par//' leva '//trim(names(k))// &
          ' sem remapmethod, e o mapa preve '//trim(expected))
      else if (methods(k) /= expected) then
        call append_msg(msgs, ndif, 'DIFERENCA: o conector '//par//' leva '//trim(names(k))// &
          ' com remapmethod='//trim(methods(k))//', e o mapa preve '//trim(expected))
      end if
    end do
  end subroutine cpl_check_methods

  !> @brief Valor da opção remapmethod de uma entrada da CplList ('' se não tem).
  pure function cpl_method_of_entry(entry) result(method)
    character(len=*), intent(in) :: entry
    character(len=CPL_METHOD_LEN) :: method
    integer :: p, q

    method = ''
    p = index(entry, ':'//OPT_METHOD)
    if (p == 0) return
    p = p + 1 + len(OPT_METHOD)
    q = index(entry(p:), ':')
    if (q == 0) then
      method = entry(p:)
    else
      method = entry(p:p+q-2)
    end if
  end function cpl_method_of_entry

  !> @brief Confere os campos anunciados num State de um componente com o mapa.
  !!
  !! Importação: cada campo anunciado tem de estar em FIELDS e ter uma única
  !! troca ativa por conector chegando ao componente; cada troca ativa que
  !! chega ao componente tem de estar anunciada. Exportação: cada troca ativa
  !! que parte do componente tem de estar anunciada; campo anunciado sem
  !! troca é aviso (exportado sem consumidor), não diferença. Campo
  !! importado sem origem que é lacuna conhecida (GAPS, em cpl_map) também
  !! é aviso, e não diferença.
  !!
  !! @param[in]    cfg         configuração (chaves de &nuopc_mode)
  !! @param[in]    comp        componente no mapa
  !! @param[in]    is_import   .true. para o importState, .false. para o exportState
  !! @param[in]    names       StandardName dos campos anunciados
  !! @param[inout] msgs        mensagens acumuladas
  !! @param[inout] ndif        número de diferenças acumulado
  !! @param[inout] nwarn       número de avisos acumulado
  subroutine cpl_check_state(cfg, comp, is_import, names, msgs, ndif, nwarn)
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: comp
    logical,                                 intent(in)    :: is_import
    character(len=*),                        intent(in)    :: names(:)
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif, nwarn

    integer :: k, t, n

    if (is_import) then
      do k = 1, size(names)
        if (cpl_field_index(names(k)) == 0) &
          call append_msg(msgs, ndif, 'DIFERENCA: '//trim(comp)//' importa '//trim(names(k))// &
            ', que nao esta no dicionario de campos')
        n = count_exchanges(cfg, names(k), '', comp)
        if (n == 0 .and. cpl_is_gap(cfg, names(k), comp)) then
          call append_msg(msgs, nwarn, 'AVISO: lacuna conhecida: '//trim(comp)//' importa '// &
            trim(names(k))//', que nao tem origem nesta configuracao')
        else if (n == 0) then
          call append_msg(msgs, ndif, 'DIFERENCA: '//trim(comp)//' importa '//trim(names(k))// &
            ', que nao tem origem no mapa')
        else if (n > 1) then
          call append_msg(msgs, ndif, 'DIFERENCA: '//trim(comp)//' importa '//trim(names(k))// &
            ', que tem '//int_to_str(n)//' origens no mapa')
        end if
      end do
      do t = 1, size(EXCHANGES)
        if (.not. exchange_via_connector(t, cfg, '', comp)) cycle
        if (.not. any(names == EXCHANGES(t)%field)) &
          call append_msg(msgs, ndif, 'DIFERENCA: o mapa preve '//trim(EXCHANGES(t)%field)// &
            ' chegando a '//trim(comp)//', que nao o anuncia na importacao')
      end do
    else
      do t = 1, size(EXCHANGES)
        if (.not. exchange_via_connector(t, cfg, comp, '')) cycle
        if (.not. any(names == EXCHANGES(t)%field)) &
          call append_msg(msgs, ndif, 'DIFERENCA: o mapa preve '//trim(EXCHANGES(t)%field)// &
            ' partindo de '//trim(comp)//', que nao o anuncia na exportacao')
      end do
      do k = 1, size(names)
        if (count_exchanges(cfg, names(k), comp, '') == 0) &
          call append_msg(msgs, nwarn, 'AVISO: '//trim(comp)//' exporta '//trim(names(k))// &
            ', que nenhum componente consome nesta configuracao')
      end do
    end if
  end subroutine cpl_check_state

  !> @brief Trocas ativas por conector do campo, de comp_src para comp_dst ('' vale
  !! qualquer componente).
  integer function count_exchanges(cfg, field, comp_src, comp_dst) result(n)
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: field, comp_src, comp_dst
    integer :: t

    n = 0
    do t = 1, size(EXCHANGES)
      if (EXCHANGES(t)%field /= field) cycle
      if (exchange_via_connector(t, cfg, comp_src, comp_dst)) n = n + 1
    end do
  end function count_exchanges

  !> @brief Trocas ativas por conector de comp_src para comp_dst ('' vale qualquer).
  integer function expected_count(cfg, comp_src, comp_dst) result(n)
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: comp_src, comp_dst
    integer :: t

    n = 0
    do t = 1, size(EXCHANGES)
      if (exchange_via_connector(t, cfg, comp_src, comp_dst)) n = n + 1
    end do
  end function expected_count

  !> @brief A troca t é por conector, vale em cfg e liga comp_src a comp_dst
  !! ('' vale qualquer componente).
  logical function exchange_via_connector(t, cfg, comp_src, comp_dst) result(ok)
    integer,            intent(in) :: t
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: comp_src, comp_dst

    ok = EXCHANGES(t)%via == 'conector'
    if (ok) ok = cpl_exchange_applies(EXCHANGES(t), cfg)
    if (ok .and. len_trim(comp_src) > 0) ok = cpl_point_component(EXCHANGES(t)%src) == comp_src
    if (ok .and. len_trim(comp_dst) > 0) ok = cpl_point_component(EXCHANGES(t)%dst) == comp_dst
  end function exchange_via_connector

  !> @brief Acrescenta uma mensagem à lista e soma um ao contador.
  subroutine append_msg(msgs, counter, msg)
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: counter
    character(len=*),                        intent(in)    :: msg

    msgs = [character(len=CPL_MSG_LEN) :: msgs, msg]
    counter = counter + 1
  end subroutine append_msg

  !> @brief As condições do mapa que valem na configuração, para o log.
  function describe_config(cfg) result(txt)
    type(cpl_config_t), intent(in) :: cfg
    character(len=:), allocatable :: txt

    txt = merge('datm', 'mpas', cfg%datm)//', '//merge('docn', 'mom6', cfg%docn)//', '// &
          trim(merge('med_to_mpas', 'ocn_to_mpas', cfg%med_to_mpas))
    if (cfg%sis2) txt = txt//', sis2'
  end function describe_config

  !> @brief Grava uma linha do relatório no log (log_report, prefixo CPL-REL:).
  subroutine write_line(msg)
    character(len=*), intent(in) :: msg
    call log_report(trim(msg))
  end subroutine write_line

end module cpl_check_mod
