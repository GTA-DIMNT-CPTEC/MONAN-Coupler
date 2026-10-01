!> @file cpl_check.F90
!! @brief Conferência do mapa de acoplamento e relatório dos conectores no log.
!!
!! Chamada pelo driver (esm.F90) no fim de ModifyCplLists, quando os
!! componentes já anunciaram os campos e os conectores já montaram as suas
!! listas (CplList), e antes da realização dos campos. Faz duas coisas, só
!! escrevendo no log do PET 0, com o prefixo CPL-REL:
!!
!!   relatório dos conectores  para cada conector do driver, os campos da
!!                             CplList e as opções de cada um;
!!   conferência do mapa       compara o mapa (cpl_map, na configuração lida
!!                             do nuopc.input) com o que o driver montou:
!!                             a CplList de cada conector contra as trocas do
!!                             mapa entre os dois componentes; o importState
!!                             de cada componente contra as trocas que chegam
!!                             a ele; o exportState contra as que partem dele.
!!
!! Cada diferença vira uma linha "CPL-REL: DIFERENCA: ..."; campos exportados
!! que nenhum componente consome viram "CPL-REL: AVISO: ...", porque são
!! normais (o MOM6 exporta So_s, por exemplo). A conferência nunca interrompe
!! a rodada: até a R-FASE11-25 ela só registra. Um erro do ESMF durante a
!! consulta também só é registrado, e a rodada segue.
!!
!! As rotinas cpl_confere_conector e cpl_confere_estado não usam o ESMF e
!! são testadas em tests/unit/test_cpl_check.F90; a rotina do driver é
!! exercitada por tests/cplcheck/.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module cpl_check_mod

  use ESMF
  use NUOPC,              only : NUOPC_CompAttributeGet, NUOPC_GetStateMemberLists
  use NUOPC_Driver,       only : NUOPC_DriverGetComp
  use coupler_utils_mod,  only : int_to_str
  use cpl_fields_mod,     only : cpl_campo_indice
  use cpl_map_mod,        only : TROCAS, cpl_config_t, cpl_troca_vale, cpl_ponto_componente, &
                                 cpl_config_atual

  implicit none
  private

  public :: cpl_check_acoplamento
  public :: cpl_confere_conector, cpl_confere_estado
  public :: CPL_PREFIXO, CPL_MSG_LEN

  character(len=*), parameter :: CPL_PREFIXO = 'CPL-REL: '
  integer,          parameter :: CPL_MSG_LEN = 200

contains

  !> Relatório dos conectores e conferência do mapa, no log do PET 0.
  !!
  !! @param[inout] driver       driver NUOPC, depois da montagem das CplList
  !! @param[in]    rotulos      rótulos dos componentes no driver ('MPAS', ...)
  !! @param[in]    componentes  componente do mapa de cada rótulo ('ATM', ...)
  !! @param[out]   rc           sempre ESMF_SUCCESS: a conferência só registra
  subroutine cpl_check_acoplamento(driver, rotulos, componentes, rc)
    type(ESMF_GridComp), intent(inout) :: driver
    character(len=*),    intent(in)    :: rotulos(:)
    character(len=*),    intent(in)    :: componentes(:)
    integer,             intent(out)   :: rc

    type(cpl_config_t) :: cfg
    type(ESMF_VM)      :: vm
    character(len=CPL_MSG_LEN), allocatable :: msgs(:)
    integer :: localPet, ndif, naviso, i, j, lrc

    rc = ESMF_SUCCESS
    call ESMF_VMGetCurrent(vm, rc=lrc)
    if (lrc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, rc=lrc)
    if (lrc /= ESMF_SUCCESS .or. localPet /= 0) return

    cfg = cpl_config_atual()
    call escreve('configuracao do mapa: '//descreve_config(cfg))
    allocate(msgs(0))
    ndif = 0; naviso = 0

    do i = 1, size(rotulos)
      do j = 1, size(rotulos)
        if (i == j) cycle
        call confere_um_conector(driver, cfg, rotulos(i), rotulos(j), componentes(i), &
                                 componentes(j), msgs, ndif)
      end do
    end do
    do i = 1, size(rotulos)
      call confere_um_componente(driver, cfg, rotulos(i), componentes(i), msgs, ndif, naviso)
    end do

    do i = 1, size(msgs)
      call escreve(msgs(i))
    end do
    call escreve('conferencia do mapa: '//int_to_str(ndif)//' diferenca(s), '// &
                 int_to_str(naviso)//' aviso(s)')
  end subroutine cpl_check_acoplamento

  !> Relatório da CplList do conector origem -> destino e conferência dela
  !! contra o mapa. Conector ausente só é diferença se o mapa prevê trocas.
  subroutine confere_um_conector(driver, cfg, rot_de, rot_para, comp_de, comp_para, msgs, ndif)
    type(ESMF_GridComp),                     intent(inout) :: driver
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: rot_de, rot_para
    character(len=*),                        intent(in)    :: comp_de, comp_para
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif

    type(ESMF_CplComp) :: conector
    character(len=512), allocatable :: lista(:)
    character(len=512), allocatable :: nomes(:)
    integer :: n, k, p, lrc, nprev
    character(len=:), allocatable :: titulo

    titulo = trim(rot_de)//' -> '//trim(rot_para)
    call NUOPC_DriverGetComp(driver, srcCompLabel=rot_de, dstCompLabel=rot_para, &
                             comp=conector, relaxedflag=.true., rc=lrc)
    if (lrc /= ESMF_SUCCESS) then
      call escreve('AVISO: conector '//titulo//' nao consultado (erro do ESMF)')
      return
    end if
    if (.not. ESMF_CplCompIsCreated(conector)) then
      nprev = previstas(cfg, comp_de, comp_para)
      if (nprev > 0) call acrescenta(msgs, ndif, 'DIFERENCA: o mapa preve '//int_to_str(nprev)// &
        ' campo(s) de '//trim(comp_de)//' para '//trim(comp_para)// &
        ', mas o driver nao registrou o conector '//titulo)
      return
    end if

    call NUOPC_CompAttributeGet(conector, name='CplList', itemCount=n, rc=lrc)
    if (lrc /= ESMF_SUCCESS) then
      call escreve('AVISO: CplList do conector '//titulo//' nao consultada (erro do ESMF)')
      return
    end if
    allocate(lista(n), nomes(n))
    if (n > 0) then
      call NUOPC_CompAttributeGet(conector, name='CplList', valueList=lista, rc=lrc)
      if (lrc /= ESMF_SUCCESS) then
        call escreve('AVISO: CplList do conector '//titulo//' nao consultada (erro do ESMF)')
        return
      end if
    end if

    call escreve('conector '//titulo//': '//int_to_str(n)//' campo(s)')
    do k = 1, n
      p = index(lista(k), ':')
      if (p == 0) then
        nomes(k) = trim(lista(k))
        call escreve('  '//trim(nomes(k))//'  (sem opcoes)')
      else
        nomes(k) = lista(k)(1:p-1)
        call escreve('  '//trim(nomes(k))//'  '//trim(lista(k)(p+1:)))
      end if
    end do
    if (n > 0) then
      if (index(lista(1), 'remapmethod=') == 0 .and. index(lista(1), 'REMAPMETHOD=') == 0) &
        call escreve('  metodo: padrao do conector (sem remapmethod na CplList)')
    end if

    call cpl_confere_conector(cfg, comp_de, comp_para, nomes, msgs, ndif)
  end subroutine confere_um_conector

  !> Conferência do importState e do exportState de um componente.
  subroutine confere_um_componente(driver, cfg, rotulo, comp, msgs, ndif, naviso)
    type(ESMF_GridComp),                     intent(inout) :: driver
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: rotulo, comp
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif, naviso

    type(ESMF_GridComp) :: gcomp
    type(ESMF_State)    :: imp, exp
    character(len=ESMF_MAXSTR), allocatable :: nomes_imp(:), nomes_exp(:)
    integer :: lrc, nprev

    call NUOPC_DriverGetComp(driver, compLabel=rotulo, comp=gcomp, relaxedflag=.true., rc=lrc)
    if (lrc /= ESMF_SUCCESS) then
      call escreve('AVISO: componente '//trim(rotulo)//' nao consultado (erro do ESMF)')
      return
    end if
    if (.not. ESMF_GridCompIsCreated(gcomp)) then
      nprev = previstas(cfg, comp, '') + previstas(cfg, '', comp)
      if (nprev > 0) call acrescenta(msgs, ndif, 'DIFERENCA: o mapa preve '//int_to_str(nprev)// &
        ' troca(s) por conector com '//trim(comp)//', mas o driver nao registrou '//trim(rotulo))
      return
    end if

    call ESMF_GridCompGet(gcomp, importState=imp, exportState=exp, rc=lrc)
    if (lrc == ESMF_SUCCESS) call nomes_do_estado(imp, nomes_imp, lrc)
    if (lrc == ESMF_SUCCESS) call nomes_do_estado(exp, nomes_exp, lrc)
    if (lrc /= ESMF_SUCCESS) then
      call escreve('AVISO: estados de '//trim(rotulo)//' nao consultados (erro do ESMF)')
      return
    end if

    call cpl_confere_estado(cfg, comp, .true.,  nomes_imp, msgs, ndif, naviso)
    call cpl_confere_estado(cfg, comp, .false., nomes_exp, msgs, ndif, naviso)
  end subroutine confere_um_componente

  !> Nomes padrão (StandardName) dos campos anunciados num State.
  subroutine nomes_do_estado(estado, nomes, rc)
    type(ESMF_State),                        intent(in)  :: estado
    character(len=ESMF_MAXSTR), allocatable, intent(out) :: nomes(:)
    integer,                                 intent(out) :: rc

    character(len=ESMF_MAXSTR), pointer :: lista(:)

    nullify(lista)
    call NUOPC_GetStateMemberLists(estado, StandardNameList=lista, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    if (associated(lista)) then
      nomes = lista
      deallocate(lista)
    else
      allocate(nomes(0))
    end if
  end subroutine nomes_do_estado

  !> Confere a lista de campos de um conector com as trocas do mapa.
  !!
  !! Diferença: campo na lista sem troca ativa por conector de comp_de para
  !! comp_para; troca ativa do mapa cujo campo não está na lista.
  !!
  !! @param[in]    cfg        configuração (chaves de &nuopc_mode)
  !! @param[in]    comp_de    componente de origem no mapa ('ATM', 'OCN', ...)
  !! @param[in]    comp_para  componente de destino no mapa
  !! @param[in]    nomes      campos da CplList, sem as opções
  !! @param[inout] msgs       mensagens acumuladas
  !! @param[inout] ndif       número de diferenças acumulado
  subroutine cpl_confere_conector(cfg, comp_de, comp_para, nomes, msgs, ndif)
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: comp_de, comp_para
    character(len=*),                        intent(in)    :: nomes(:)
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif

    integer :: k, t
    character(len=:), allocatable :: par

    par = trim(comp_de)//' -> '//trim(comp_para)
    do k = 1, size(nomes)
      if (conta_trocas(cfg, nomes(k), comp_de, comp_para) == 0) &
        call acrescenta(msgs, ndif, 'DIFERENCA: o conector '//par//' leva '//trim(nomes(k))// &
          ', que nao tem troca no mapa')
    end do
    do t = 1, size(TROCAS)
      if (.not. troca_por_conector(t, cfg, comp_de, comp_para)) cycle
      if (.not. any(nomes == TROCAS(t)%campo)) &
        call acrescenta(msgs, ndif, 'DIFERENCA: o mapa preve '//trim(TROCAS(t)%campo)// &
          ' no conector '//par//', que nao o leva')
    end do
  end subroutine cpl_confere_conector

  !> Confere os campos anunciados num State de um componente com o mapa.
  !!
  !! Importação: cada campo anunciado tem de estar em CAMPOS e ter uma única
  !! troca ativa por conector chegando ao componente; cada troca ativa que
  !! chega ao componente tem de estar anunciada. Exportação: cada troca ativa
  !! que parte do componente tem de estar anunciada; campo anunciado sem
  !! troca é aviso (exportado sem consumidor), não diferença.
  !!
  !! @param[in]    cfg         configuração (chaves de &nuopc_mode)
  !! @param[in]    comp        componente no mapa
  !! @param[in]    importacao  .true. para o importState, .false. para o exportState
  !! @param[in]    nomes       StandardName dos campos anunciados
  !! @param[inout] msgs        mensagens acumuladas
  !! @param[inout] ndif        número de diferenças acumulado
  !! @param[inout] naviso      número de avisos acumulado
  subroutine cpl_confere_estado(cfg, comp, importacao, nomes, msgs, ndif, naviso)
    type(cpl_config_t),                      intent(in)    :: cfg
    character(len=*),                        intent(in)    :: comp
    logical,                                 intent(in)    :: importacao
    character(len=*),                        intent(in)    :: nomes(:)
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: ndif, naviso

    integer :: k, t, n

    if (importacao) then
      do k = 1, size(nomes)
        if (cpl_campo_indice(nomes(k)) == 0) &
          call acrescenta(msgs, ndif, 'DIFERENCA: '//trim(comp)//' importa '//trim(nomes(k))// &
            ', que nao esta no dicionario de campos')
        n = conta_trocas(cfg, nomes(k), '', comp)
        if (n == 0) then
          call acrescenta(msgs, ndif, 'DIFERENCA: '//trim(comp)//' importa '//trim(nomes(k))// &
            ', que nao tem origem no mapa')
        else if (n > 1) then
          call acrescenta(msgs, ndif, 'DIFERENCA: '//trim(comp)//' importa '//trim(nomes(k))// &
            ', que tem '//int_to_str(n)//' origens no mapa')
        end if
      end do
      do t = 1, size(TROCAS)
        if (.not. troca_por_conector(t, cfg, '', comp)) cycle
        if (.not. any(nomes == TROCAS(t)%campo)) &
          call acrescenta(msgs, ndif, 'DIFERENCA: o mapa preve '//trim(TROCAS(t)%campo)// &
            ' chegando a '//trim(comp)//', que nao o anuncia na importacao')
      end do
    else
      do t = 1, size(TROCAS)
        if (.not. troca_por_conector(t, cfg, comp, '')) cycle
        if (.not. any(nomes == TROCAS(t)%campo)) &
          call acrescenta(msgs, ndif, 'DIFERENCA: o mapa preve '//trim(TROCAS(t)%campo)// &
            ' partindo de '//trim(comp)//', que nao o anuncia na exportacao')
      end do
      do k = 1, size(nomes)
        if (conta_trocas(cfg, nomes(k), comp, '') == 0) &
          call acrescenta(msgs, naviso, 'AVISO: '//trim(comp)//' exporta '//trim(nomes(k))// &
            ', que nenhum componente consome nesta configuracao')
      end do
    end if
  end subroutine cpl_confere_estado

  !> Trocas ativas por conector do campo, de comp_de para comp_para ('' vale
  !! qualquer componente).
  integer function conta_trocas(cfg, campo, comp_de, comp_para) result(n)
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: campo, comp_de, comp_para
    integer :: t

    n = 0
    do t = 1, size(TROCAS)
      if (TROCAS(t)%campo /= campo) cycle
      if (troca_por_conector(t, cfg, comp_de, comp_para)) n = n + 1
    end do
  end function conta_trocas

  !> Trocas ativas por conector de comp_de para comp_para ('' vale qualquer).
  integer function previstas(cfg, comp_de, comp_para) result(n)
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: comp_de, comp_para
    integer :: t

    n = 0
    do t = 1, size(TROCAS)
      if (troca_por_conector(t, cfg, comp_de, comp_para)) n = n + 1
    end do
  end function previstas

  !> A troca t é por conector, vale em cfg e liga comp_de a comp_para
  !! ('' vale qualquer componente).
  logical function troca_por_conector(t, cfg, comp_de, comp_para) result(ok)
    integer,            intent(in) :: t
    type(cpl_config_t), intent(in) :: cfg
    character(len=*),   intent(in) :: comp_de, comp_para

    ok = TROCAS(t)%meio == 'conector'
    if (ok) ok = cpl_troca_vale(TROCAS(t), cfg)
    if (ok .and. len_trim(comp_de) > 0) ok = cpl_ponto_componente(TROCAS(t)%de) == comp_de
    if (ok .and. len_trim(comp_para) > 0) ok = cpl_ponto_componente(TROCAS(t)%para) == comp_para
  end function troca_por_conector

  !> Acrescenta uma mensagem à lista e soma um ao contador.
  subroutine acrescenta(msgs, contador, msg)
    character(len=CPL_MSG_LEN), allocatable, intent(inout) :: msgs(:)
    integer,                                 intent(inout) :: contador
    character(len=*),                        intent(in)    :: msg

    msgs = [character(len=CPL_MSG_LEN) :: msgs, msg]
    contador = contador + 1
  end subroutine acrescenta

  !> As condições do mapa que valem na configuração, para o log.
  function descreve_config(cfg) result(txt)
    type(cpl_config_t), intent(in) :: cfg
    character(len=:), allocatable :: txt

    txt = merge('datm', 'mpas', cfg%datm)//', '//merge('docn', 'mom6', cfg%docn)//', '// &
          trim(merge('med_to_mpas', 'ocn_to_mpas', cfg%med_to_mpas))
    if (cfg%sis2) txt = txt//', sis2'
  end function descreve_config

  subroutine escreve(msg)
    character(len=*), intent(in) :: msg
    call ESMF_LogWrite(CPL_PREFIXO//trim(msg), ESMF_LOGMSG_INFO)
  end subroutine escreve

end module cpl_check_mod
