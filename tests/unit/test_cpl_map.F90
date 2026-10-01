!> @file test_cpl_map.F90
!! @brief Consistência do mapa de acoplamento (cpl_fields e cpl_map).
!!
!! Confere, sem MPI e sem ESMF inicializado, que as tabelas CAMPOS, MALHAS,
!! TROCAS e ROTAS formam uma descrição coerente do acoplamento de hoje:
!!
!!   estrutura   nomes únicos; todo campo de TROCAS e de EXPORTACOES está
!!               em CAMPOS e todo campo de CAMPOS é usado; pontos 'COMPONENTE@malha' com
!!               malha conhecida e componente certo; condições válidas;
!!               meio coerente com os componentes (conector entre dois
!!               componentes, cap dentro de um, rota dentro do mediador,
!!               entre as malhas da rota); rotas com reserva, máscara,
!!               sem_valor e criar válidos; toda rota usada
!!   origem      em cada configuração, cada campo importado por um
!!               componente tem uma única origem, e cada campo chega por
!!               rota ou cap a um ponto por um só caminho
!!   cadeia      em cada configuração, todo campo que parte de um ponto
!!               intermediário (grade do cap atmosférico, grade do oceano no
!!               mediador) chegou antes a ele; as exceções são as lacunas
!!               conhecidas, registradas abaixo, e o teste exige que sejam
!!               exatamente essas
!!   contagens   campos de cada conector na configuração de produção iguais
!!               aos do Apêndice A de docs/arquitetura-acoplamento.md
!!   mediador    campos que chegam ao mediador por conector iguais, na mesma
!!               ordem, a import_mpas_names e import_datm_names; campos que
!!               voltam da malha de fluxo para a do oceano iguais, na mesma
!!               ordem, a export_names (listas de listas_mediador.inc, as
!!               do med_cap_types até a R-FASE11-04-FIX01)
!!   listas      as listas que o mediador anuncia e realiza desde a
!!               R-FASE11-05, geradas por cpl_chegadas com as chaves do
!!               mediador (MED_CHAVES), iguais nome a nome e na mesma ordem
!!               às de antes, em cada configuração: importação na malha de
!!               fluxo, importação na grade do oceano, exportação e a
!!               importação toda (a ordem do anúncio)
!!   exportacoes cada linha de EXPORTACOES com campo do dicionário, ponto de
!!               um modelo (não do mediador) e condição válida, sem
!!               repetição; todo campo que sai de um modelo por conector numa
!!               configuração é exportado por ele nessa configuração; as
!!               exportações de cada modelo iguais, nome a nome e na mesma
!!               ordem, às listas dos caps (listas_caps.inc)
!!   caps        as listas que os caps dos modelos anunciam, geradas por
!!               cpl_chegadas e cpl_exportacoes sem chaves (MOM6 e SIS2 desde
!!               a R-FASE11-06; MONAN-A, DATM e DOCN desde a R-FASE11-07),
!!               iguais nome a nome e na mesma ordem às de antes, em toda
!!               configuração
!!
!! Configurações conferidas (chaves de &nuopc_mode):
!!   producao       MONAN-A, MOM6, SIS2, contorno pelo mediador
!!   mom6_sem_sis2  idem, sem o SIS2
!!   mpas_docn      MONAN-A e DOCN, contorno direto do oceano
!!   datm_mom6      DATM e MOM6, sem o SIS2
!!   datm_docn      DATM e DOCN, contorno direto do oceano
!!
!! Lacunas conhecidas (campos que partem de um ponto aonde não chegaram):
!!   mpas_docn  MED@ocn_med So_omask: o DOCN não exporta a máscara
!!              ATM@atm_cap Sx_tsfc, Sf_albedo e Sx_omask: sem o mediador,
!!              ninguém os exporta; o cap atmosférico interrompe a rodada
!!   datm_docn  MED@ocn_med So_omask
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_cpl_map
  use cpl_fields_mod,    only : CAMPOS, cpl_campo_indice
  use cpl_map_mod,       only : MALHAS, TROCAS, ROTAS, cpl_config_t, cpl_troca_vale, &
                                cpl_condicoes_validas, cpl_rota_indice, cpl_malha_indice, &
                                cpl_ponto_componente, cpl_ponto_malha, cpl_troca_t
  use cpl_map_mod,       only : cpl_chegadas, cpl_exportacoes, EXPORTACOES, cpl_config_atual
  use cpl_fields_mod,    only : CPL_NOME_LEN
  use med_cap_types_mod, only : MED_CHAVES
  implicit none

  include 'listas_mediador.inc'
  include 'listas_caps.inc'

  integer, parameter :: NCFG = 5
  character(len=16), parameter :: NOME_CFG(NCFG) = [character(len=16) :: &
    'producao', 'mom6_sem_sis2', 'mpas_docn', 'datm_mom6', 'datm_docn']
  type(cpl_config_t), parameter :: CFG(NCFG) = [                                       &
    cpl_config_t(datm=.false., docn=.false., med_to_mpas=.true.,  sis2=.true.),         &
    cpl_config_t(datm=.false., docn=.false., med_to_mpas=.true.,  sis2=.false.),        &
    cpl_config_t(datm=.false., docn=.true.,  med_to_mpas=.false., sis2=.false.),        &
    cpl_config_t(datm=.true.,  docn=.false., med_to_mpas=.true.,  sis2=.false.),        &
    cpl_config_t(datm=.true.,  docn=.true.,  med_to_mpas=.false., sis2=.false.) ]

  !> Lacunas conhecidas: configuração, ponto e campo.
  integer, parameter :: NLAC = 5
  character(len=16), parameter :: LAC_CFG(NLAC) = [character(len=16) :: &
    'mpas_docn', 'mpas_docn', 'mpas_docn', 'mpas_docn', 'datm_docn']
  character(len=16), parameter :: LAC_PONTO(NLAC) = [character(len=16) :: &
    'MED@ocn_med', 'ATM@atm_cap', 'ATM@atm_cap', 'ATM@atm_cap', 'MED@ocn_med']
  character(len=24), parameter :: LAC_CAMPO(NLAC) = [character(len=24) :: &
    'So_omask', 'Sx_tsfc', 'Sf_albedo', 'Sx_omask', 'So_omask']

  !> Malhas onde um modelo produz campos, e a malha de fluxo do mediador,
  !! onde ele os calcula: pontos de partida que não precisam de chegada.
  character(len=12), parameter :: PRODUCAO(*) = [character(len=12) :: &
    'mpas', 'datm', 'ocn_mom6', 'docn', 'ice_sis2', 'atm_med']

  integer :: nfalhas, k

  nfalhas = 0

  call confere_campos()
  call confere_malhas_e_rotas()
  call confere_trocas()
  do k = 1, NCFG
    call confere_origens(k)
    call confere_cadeia(k)
  end do
  call confere_contagens()
  call confere_mediador()
  do k = 1, NCFG
    call confere_listas_mediador(k)
  end do
  call confere_exportacoes()
  do k = 1, NCFG
    call confere_exporta_conector(k)
  end do
  call confere_listas_caps()

  if (nfalhas == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfalhas, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Nomes de CAMPOS únicos e preenchidos; todo campo usado em TROCAS ou
  !! em EXPORTACOES.
  subroutine confere_campos()
    integer :: i, j, nrep, nvazio, nsem_uso

    nrep = 0; nvazio = 0; nsem_uso = 0
    do i = 1, size(CAMPOS)
      if (len_trim(CAMPOS(i)%nome) == 0 .or. len_trim(CAMPOS(i)%unidade) == 0 .or. &
          len_trim(CAMPOS(i)%descricao) == 0) then
        nvazio = nvazio + 1
        call falha('campo sem nome, unidade ou descricao: '//trim(CAMPOS(i)%nome))
      end if
      do j = i + 1, size(CAMPOS)
        if (CAMPOS(i)%nome == CAMPOS(j)%nome) then
          nrep = nrep + 1
          call falha('campo repetido em CAMPOS: '//trim(CAMPOS(i)%nome))
        end if
      end do
      if (.not. any(TROCAS%campo == CAMPOS(i)%nome) .and. &
          .not. any(EXPORTACOES%campo == CAMPOS(i)%nome)) then
        nsem_uso = nsem_uso + 1
        call falha('campo sem troca nem exportacao: '//trim(CAMPOS(i)%nome))
      end if
    end do
    call resultado('CAMPOS: nomes unicos', nrep == 0)
    call resultado('CAMPOS: nome, unidade e descricao preenchidos', nvazio == 0)
    call resultado('CAMPOS: todo campo aparece em TROCAS ou EXPORTACOES', nsem_uso == 0)
  end subroutine confere_campos

  !> MALHAS e ROTAS: nomes únicos; rotas entre malhas do mediador, com
  !! reserva, máscara, sem_valor e criar válidos; toda rota usada.
  subroutine confere_malhas_e_rotas()
    integer :: i, j, kr, nerr

    nerr = 0
    do i = 1, size(MALHAS)
      do j = i + 1, size(MALHAS)
        if (MALHAS(i)%nome == MALHAS(j)%nome) then
          nerr = nerr + 1
          call falha('malha repetida: '//trim(MALHAS(i)%nome))
        end if
      end do
    end do
    call resultado('MALHAS: nomes unicos', nerr == 0)

    nerr = 0
    do i = 1, size(ROTAS)
      do j = i + 1, size(ROTAS)
        if (ROTAS(i)%nome == ROTAS(j)%nome) then
          nerr = nerr + 1
          call falha('rota repetida: '//trim(ROTAS(i)%nome))
        end if
      end do
      if (.not. malha_do_mediador(ROTAS(i)%de) .or. .not. malha_do_mediador(ROTAS(i)%para)) then
        nerr = nerr + 1
        call falha('rota fora das malhas do mediador: '//trim(ROTAS(i)%nome))
      end if
      if (ROTAS(i)%de == ROTAS(i)%para) then
        nerr = nerr + 1
        call falha('rota com origem igual ao destino: '//trim(ROTAS(i)%nome))
      end if
      if (len_trim(ROTAS(i)%metodos) == 0) then
        nerr = nerr + 1
        call falha('rota sem metodo: '//trim(ROTAS(i)%nome))
      end if
      if (len_trim(ROTAS(i)%reserva) > 0) then
        kr = cpl_rota_indice(ROTAS(i)%reserva)
        if (kr == 0 .or. kr >= i) then
          nerr = nerr + 1
          call falha('reserva inexistente ou criada depois: '//trim(ROTAS(i)%nome))
        else if (ROTAS(kr)%de /= ROTAS(i)%de .or. ROTAS(kr)%para /= ROTAS(i)%para) then
          nerr = nerr + 1
          call falha('reserva entre outras malhas: '//trim(ROTAS(i)%nome))
        end if
      end if
      if (len_trim(ROTAS(i)%mascara) > 0 .and. cpl_campo_indice(ROTAS(i)%mascara) == 0) then
        nerr = nerr + 1
        call falha('mascara fora de CAMPOS: '//trim(ROTAS(i)%nome))
      end if
      if (.not. any(ROTAS(i)%sem_valor == [character(len=12) :: 'zerar', 'manter', 'sentinela'])) then
        nerr = nerr + 1
        call falha('sem_valor invalido: '//trim(ROTAS(i)%nome))
      end if
      if (.not. any(ROTAS(i)%criar == [character(len=16) :: 'inicio', 'primeiro_uso', 'mascara_mista'])) then
        nerr = nerr + 1
        call falha('criar invalido: '//trim(ROTAS(i)%nome))
      end if
      if (ROTAS(i)%criar == 'mascara_mista' .and. &
          (len_trim(ROTAS(i)%mascara) == 0 .or. len_trim(ROTAS(i)%reserva) == 0)) then
        nerr = nerr + 1
        call falha('criar=mascara_mista sem mascara ou reserva: '//trim(ROTAS(i)%nome))
      end if
      if (.not. any(TROCAS%meio == ROTAS(i)%nome)) then
        nerr = nerr + 1
        call falha('rota sem troca: '//trim(ROTAS(i)%nome))
      end if
    end do
    call resultado('ROTAS: nomes, malhas, reservas, mascaras, sem_valor e criar', nerr == 0)
    ! A ordem de ROTAS é a ordem em que a reserva precisa existir.
    call resultado('ROTAS: seis rotas (Apendice A)', size(ROTAS) == 6)
  end subroutine confere_malhas_e_rotas

  !> Cada linha de TROCAS: campo no dicionário, pontos válidos, condições
  !! válidas, meio coerente; nenhuma linha repetida.
  subroutine confere_trocas()
    integer :: i, j, kr, nerr
    character(len=16) :: cde, cpara, mde, mpara

    nerr = 0
    do i = 1, size(TROCAS)
      if (cpl_campo_indice(TROCAS(i)%campo) == 0) then
        nerr = nerr + 1
        call falha('campo fora de CAMPOS: '//trim(TROCAS(i)%campo))
      end if
      if (.not. ponto_valido(TROCAS(i)%de) .or. .not. ponto_valido(TROCAS(i)%para)) then
        nerr = nerr + 1
        call falha('ponto invalido: '//descreve(i))
      end if
      if (.not. cpl_condicoes_validas(TROCAS(i)%quando)) then
        nerr = nerr + 1
        call falha('condicao invalida: '//descreve(i))
      end if
      cde   = cpl_ponto_componente(TROCAS(i)%de)
      cpara = cpl_ponto_componente(TROCAS(i)%para)
      mde   = cpl_ponto_malha(TROCAS(i)%de)
      mpara = cpl_ponto_malha(TROCAS(i)%para)
      select case (trim(TROCAS(i)%meio))
      case ('conector')
        if (cde == cpara) then
          nerr = nerr + 1
          call falha('conector dentro de um componente: '//descreve(i))
        end if
      case ('cap')
        if (cde /= cpara .or. mde == mpara .or. cde == 'MED') then
          nerr = nerr + 1
          call falha('cap fora de um componente com duas malhas: '//descreve(i))
        end if
      case default
        kr = cpl_rota_indice(TROCAS(i)%meio)
        if (kr == 0) then
          nerr = nerr + 1
          call falha('rota inexistente: '//descreve(i))
        else if (cde /= 'MED' .or. cpara /= 'MED' .or. &
                 ROTAS(kr)%de /= mde .or. ROTAS(kr)%para /= mpara) then
          nerr = nerr + 1
          call falha('rota entre malhas diferentes das da troca: '//descreve(i))
        end if
      end select
      do j = i + 1, size(TROCAS)
        if (TROCAS(i)%campo == TROCAS(j)%campo .and. TROCAS(i)%de == TROCAS(j)%de .and. &
            TROCAS(i)%para == TROCAS(j)%para .and. TROCAS(i)%quando == TROCAS(j)%quando) then
          nerr = nerr + 1
          call falha('troca repetida: '//descreve(i))
        end if
      end do
    end do
    call resultado('TROCAS: campos, pontos, condicoes e meios validos, sem repeticao', nerr == 0)
  end subroutine confere_trocas

  !> Na configuração k: cada (campo, destino) recebe de uma só troca, entre
  !! as que chegam por conector (importação) e entre as demais.
  subroutine confere_origens(k)
    integer, intent(in) :: k
    integer :: i, j, n, nerr
    logical :: conector_i

    nerr = 0
    do i = 1, size(TROCAS)
      if (.not. cpl_troca_vale(TROCAS(i), CFG(k))) cycle
      conector_i = TROCAS(i)%meio == 'conector'
      n = 0
      do j = 1, size(TROCAS)
        if (.not. cpl_troca_vale(TROCAS(j), CFG(k))) cycle
        if (TROCAS(j)%campo /= TROCAS(i)%campo .or. TROCAS(j)%para /= TROCAS(i)%para) cycle
        if ((TROCAS(j)%meio == 'conector') .neqv. conector_i) cycle
        n = n + 1
      end do
      if (n /= 1) then
        nerr = nerr + 1
        call falha(trim(NOME_CFG(k))//': mais de uma origem: '//descreve(i))
      end if
    end do
    call resultado(trim(NOME_CFG(k))//': cada campo com uma unica origem', nerr == 0)
  end subroutine confere_origens

  !> Na configuração k: quem parte de um ponto intermediário chegou a ele
  !! (por conector, se parte por rota ou cap; por rota ou cap, se parte por
  !! conector). As faltas têm de ser exatamente as lacunas conhecidas.
  subroutine confere_cadeia(k)
    integer, intent(in) :: k
    integer :: i, j, l, nfaltas, nesperadas, nerr
    logical :: chegou, esperada

    nfaltas = 0; nerr = 0
    do i = 1, size(TROCAS)
      if (.not. cpl_troca_vale(TROCAS(i), CFG(k))) cycle
      if (any(PRODUCAO == cpl_ponto_malha(TROCAS(i)%de))) cycle
      chegou = .false.
      do j = 1, size(TROCAS)
        if (.not. cpl_troca_vale(TROCAS(j), CFG(k))) cycle
        if (TROCAS(j)%campo /= TROCAS(i)%campo .or. TROCAS(j)%para /= TROCAS(i)%de) cycle
        if ((TROCAS(j)%meio == 'conector') .eqv. (TROCAS(i)%meio == 'conector')) cycle
        chegou = .true.
      end do
      if (chegou) cycle
      nfaltas = nfaltas + 1
      esperada = .false.
      do l = 1, NLAC
        if (LAC_CFG(l) == NOME_CFG(k) .and. LAC_PONTO(l) == TROCAS(i)%de .and. &
            LAC_CAMPO(l) == TROCAS(i)%campo) esperada = .true.
      end do
      if (.not. esperada) then
        nerr = nerr + 1
        call falha(trim(NOME_CFG(k))//': parte sem ter chegado: '//descreve(i))
      end if
    end do
    nesperadas = count(LAC_CFG == NOME_CFG(k))
    if (nfaltas /= nesperadas .and. nerr == 0) &
      call falha(trim(NOME_CFG(k))//': lacuna conhecida que deixou de existir')
    call resultado(trim(NOME_CFG(k))//': cadeia completa, exceto as lacunas conhecidas', &
                   nerr == 0 .and. nfaltas == nesperadas)
  end subroutine confere_cadeia

  !> Campos por conector na produção, como no Apêndice A.
  subroutine confere_contagens()
    call resultado('producao: ATM para MED, 13 campos', n_conector('ATM', 'MED') == 13)
    call resultado('producao: OCN para MED, 4 campos',  n_conector('OCN', 'MED') == 4)
    call resultado('producao: ICE para MED, 6 campos',  n_conector('ICE', 'MED') == 6)
    call resultado('producao: MED para OCN, 14 campos', n_conector('MED', 'OCN') == 14)
    call resultado('producao: MED para ICE, 16 campos', n_conector('MED', 'ICE') == 16)
    call resultado('producao: MED para ATM, 7 campos',  n_conector('MED', 'ATM') == 7)
    call resultado('producao: OCN para ATM, nenhum campo', n_conector('OCN', 'ATM') == 0)
  end subroutine confere_contagens

  !> Listas do mediador (med_cap_types) contra o mapa, nome a nome.
  subroutine confere_mediador()
    call resultado('mediador: importacao do MONAN-A igual a import_mpas_names', &
      lista_igual(chegadas_por_conector('MED', CFG(1), 'ATM'), import_mpas_names))
    call resultado('mediador: importacao do DATM igual a import_datm_names', &
      lista_igual(chegadas_por_conector('MED', CFG(5), 'ATM'), import_datm_names))
    call resultado('mediador: atm_med para ocn_med igual a export_names', &
      lista_igual(atm_med_para_ocn_med(), export_names))
    call resultado('mediador: todo campo exportado sai por algum conector', &
      todos_exportados())
  end subroutine confere_mediador

  !> Na configuração k, as listas geradas do mapa para o mediador são as que
  !! ele anunciava e realizava antes: forçantes do MONAN-A ou do DATM na
  !! malha de fluxo; So_t, So_u, So_v, So_omask e, com o SIS2, os *_sis2 na
  !! grade do oceano; as 31 exportações em todas as configurações.
  subroutine confere_listas_mediador(k)
    integer, intent(in) :: k
    character(len=CPL_NOME_LEN), allocatable :: atm(:), ocn(:), tudo(:), exp(:)
    character(len=32), allocatable :: esp_atm(:), esp_ocn(:)

    if (CFG(k)%datm) then
      esp_atm = import_datm_names
    else
      esp_atm = import_mpas_names
    end if
    if (CFG(k)%sis2) then
      esp_ocn = [character(len=32) :: MED_IMP_OCN, MED_IMP_SIS2]
    else
      esp_ocn = MED_IMP_OCN
    end if
    call cpl_chegadas('MED@atm_med', .true., CFG(k), MED_CHAVES, atm)
    call cpl_chegadas('MED@ocn_med', .true., CFG(k), MED_CHAVES, ocn)
    call cpl_chegadas('MED', .true., CFG(k), MED_CHAVES, tudo)
    call cpl_chegadas('MED@ocn_med', .false., CFG(k), '', exp)
    call resultado(trim(NOME_CFG(k))//': mediador, importacao na malha de fluxo', &
      lista_igual(atm, esp_atm))
    call resultado(trim(NOME_CFG(k))//': mediador, importacao na grade do oceano', &
      lista_igual(ocn, esp_ocn))
    call resultado(trim(NOME_CFG(k))//': mediador, importacao na ordem do anuncio', &
      lista_igual(tudo, [character(len=32) :: esp_atm, esp_ocn]))
    call resultado(trim(NOME_CFG(k))//': mediador, exportacao', lista_igual(exp, export_names))
  end subroutine confere_listas_mediador

  !> Cada linha de EXPORTACOES: campo no dicionário, ponto de um modelo,
  !! condição válida, sem repetição; exportações de cada modelo iguais às
  !! listas dos caps.
  subroutine confere_exportacoes()
    integer :: i, j, nerr

    nerr = 0
    do i = 1, size(EXPORTACOES)
      if (cpl_campo_indice(EXPORTACOES(i)%campo) == 0) then
        nerr = nerr + 1
        call falha('exportacao fora de CAMPOS: '//trim(EXPORTACOES(i)%campo))
      end if
      if (.not. ponto_valido(EXPORTACOES(i)%ponto) .or. &
          cpl_ponto_componente(EXPORTACOES(i)%ponto) == 'MED') then
        nerr = nerr + 1
        call falha('exportacao com ponto invalido: '//descreve_exp(i))
      end if
      if (.not. cpl_condicoes_validas(EXPORTACOES(i)%quando)) then
        nerr = nerr + 1
        call falha('exportacao com condicao invalida: '//descreve_exp(i))
      end if
      do j = i + 1, size(EXPORTACOES)
        if (EXPORTACOES(i)%campo == EXPORTACOES(j)%campo .and. &
            EXPORTACOES(i)%ponto == EXPORTACOES(j)%ponto) then
          nerr = nerr + 1
          call falha('exportacao repetida: '//descreve_exp(i))
        end if
      end do
    end do
    call resultado('EXPORTACOES: campos, pontos e condicoes validos, sem repeticao', nerr == 0)

    call resultado('EXPORTACOES: MONAN-A igual a EXP_NAMES do mpas_cap_MONAN', &
      lista_igual(exportadas('ATM@atm_cap'), mpas_exp_names))
    call resultado('EXPORTACOES: DATM igual ao anuncio do DATM_cap', &
      lista_igual(exportadas('ATM@datm'), datm_exp_names))
    call resultado('EXPORTACOES: MOM6 igual a export_names do mom_cap_MONAN', &
      lista_igual(exportadas('OCN@ocn_mom6'), mom_export_names))
    call resultado('EXPORTACOES: DOCN igual a EXP_NAMES do DOCN_cap', &
      lista_igual(exportadas('OCN@docn'), docn_exp_names))
    call resultado('EXPORTACOES: SIS2 igual a export_names do sis_cap_MONAN', &
      lista_igual(exportadas('ICE@ice_sis2'), sis_export_names))
  end subroutine confere_exportacoes

  !> Na configuração k, todo campo que sai por conector do ponto de um
  !! modelo é exportado por esse ponto nessa configuração.
  subroutine confere_exporta_conector(k)
    integer, intent(in) :: k
    integer :: i, j, nerr
    logical :: achou

    nerr = 0
    do i = 1, size(TROCAS)
      if (TROCAS(i)%meio /= 'conector' .or. .not. cpl_troca_vale(TROCAS(i), CFG(k))) cycle
      if (cpl_ponto_componente(TROCAS(i)%de) == 'MED') cycle
      achou = .false.
      do j = 1, size(EXPORTACOES)
        if (EXPORTACOES(j)%campo /= TROCAS(i)%campo .or. EXPORTACOES(j)%ponto /= TROCAS(i)%de) cycle
        if (exporta_vale(j, CFG(k))) achou = .true.
      end do
      if (.not. achou) then
        nerr = nerr + 1
        call falha(trim(NOME_CFG(k))//': sai por conector sem ser exportado: '//descreve(i))
      end if
    end do
    call resultado(trim(NOME_CFG(k))//': todo campo que sai de um modelo e exportado por ele', &
                   nerr == 0)
  end subroutine confere_exporta_conector

  !> Listas geradas para os caps dos modelos (sem chaves: valem em qualquer
  !! configuração) iguais às que eles anunciavam antes; a configuração
  !! passada não pode mudar o resultado.
  subroutine confere_listas_caps()
    character(len=CPL_NOME_LEN), allocatable :: nomes(:)
    logical :: ok_imp_mom, ok_exp_mom, ok_imp_sis, ok_exp_sis
    logical :: ok_imp_mpas, ok_exp_mpas, ok_exp_datm, ok_imp_docn, ok_exp_docn
    integer :: kc

    ok_imp_mom = .true.; ok_exp_mom = .true.; ok_imp_sis = .true.; ok_exp_sis = .true.
    ok_imp_mpas = .true.; ok_exp_mpas = .true.; ok_exp_datm = .true.
    ok_imp_docn = .true.; ok_exp_docn = .true.
    do kc = 1, NCFG
      call cpl_chegadas('ATM@atm_cap', .true., CFG(kc), '', nomes)
      ok_imp_mpas = ok_imp_mpas .and. lista_igual(nomes, mpas_imp_names)
      call cpl_exportacoes('ATM@atm_cap', CFG(kc), '', nomes)
      ok_exp_mpas = ok_exp_mpas .and. lista_igual(nomes, mpas_exp_names)
      call cpl_exportacoes('ATM@datm', CFG(kc), '', nomes)
      ok_exp_datm = ok_exp_datm .and. lista_igual(nomes, datm_exp_names)
      call cpl_chegadas('OCN@docn', .true., CFG(kc), '', nomes)
      ok_imp_docn = ok_imp_docn .and. lista_igual(nomes, docn_imp_names)
      call cpl_exportacoes('OCN@docn', CFG(kc), '', nomes)
      ok_exp_docn = ok_exp_docn .and. lista_igual(nomes, docn_exp_names)
      call cpl_chegadas('OCN@ocn_mom6', .true., CFG(kc), '', nomes)
      ok_imp_mom = ok_imp_mom .and. lista_igual(nomes, mom_import_names)
      call cpl_exportacoes('OCN@ocn_mom6', CFG(kc), '', nomes)
      ok_exp_mom = ok_exp_mom .and. lista_igual(nomes, mom_export_names)
      call cpl_chegadas('ICE@ice_sis2', .true., CFG(kc), '', nomes)
      ok_imp_sis = ok_imp_sis .and. &
        lista_igual(nomes, [character(len=32) :: sis_import_names_atm, sis_import_names_ocn])
      call cpl_exportacoes('ICE@ice_sis2', CFG(kc), '', nomes)
      ok_exp_sis = ok_exp_sis .and. lista_igual(nomes, sis_export_names)
    end do
    call resultado('caps: importacao do MOM6 igual a de antes, em toda configuracao', ok_imp_mom)
    call resultado('caps: exportacao do MOM6 igual a de antes, em toda configuracao', ok_exp_mom)
    call resultado('caps: importacao do SIS2 igual a de antes, em toda configuracao', ok_imp_sis)
    call resultado('caps: exportacao do SIS2 igual a de antes, em toda configuracao', ok_exp_sis)
    call resultado('caps: importacao do MONAN-A igual a de antes, em toda configuracao', ok_imp_mpas)
    call resultado('caps: exportacao do MONAN-A igual a de antes, em toda configuracao', ok_exp_mpas)
    call resultado('caps: exportacao do DATM igual a de antes, em toda configuracao', ok_exp_datm)
    call resultado('caps: importacao do DOCN igual a de antes, em toda configuracao', ok_imp_docn)
    call resultado('caps: exportacao do DOCN igual a de antes, em toda configuracao', ok_exp_docn)
    call cpl_chegadas('ATM@datm', .true., CFG(4), '', nomes)
    call resultado('caps: o DATM nao importa nada', size(nomes) == 0)
    ! Sem nuopc.input, cpl_config_atual dá a configuração padrão; o resultado
    ! sem chaves é o mesmo.
    call cpl_chegadas('OCN@ocn_mom6', .true., cpl_config_atual(), '', nomes)
    call resultado('caps: importacao do MOM6 com cpl_config_atual', &
      lista_igual(nomes, mom_import_names))
  end subroutine confere_listas_caps

  ! --------------------------------------------------------------------------
  ! Auxiliares
  ! --------------------------------------------------------------------------

  !> Número de campos do conector ORIGEM -> DESTINO na produção.
  integer function n_conector(origem, destino) result(n)
    character(len=*), intent(in) :: origem, destino
    integer :: i

    n = 0
    do i = 1, size(TROCAS)
      if (TROCAS(i)%meio /= 'conector' .or. .not. cpl_troca_vale(TROCAS(i), CFG(1))) cycle
      if (cpl_ponto_componente(TROCAS(i)%de) == origem .and. &
          cpl_ponto_componente(TROCAS(i)%para) == destino) n = n + 1
    end do
  end function n_conector

  !> Campos que chegam por conector ao componente comp, vindos do componente
  !! origem, na configuração c, na ordem de TROCAS.
  function chegadas_por_conector(comp, c, origem) result(lista)
    character(len=*),   intent(in) :: comp
    type(cpl_config_t), intent(in) :: c
    character(len=*),   intent(in) :: origem
    character(len=24), allocatable :: lista(:)
    integer :: i

    allocate(lista(0))
    do i = 1, size(TROCAS)
      if (TROCAS(i)%meio /= 'conector' .or. .not. cpl_troca_vale(TROCAS(i), c)) cycle
      if (cpl_ponto_componente(TROCAS(i)%para) /= comp) cycle
      if (cpl_ponto_componente(TROCAS(i)%de) /= origem) cycle
      lista = [character(len=24) :: lista, TROCAS(i)%campo]
    end do
  end function chegadas_por_conector

  !> Campos que passam de MED@atm_med a MED@ocn_med, na ordem de TROCAS.
  function atm_med_para_ocn_med() result(lista)
    character(len=24), allocatable :: lista(:)
    integer :: i

    allocate(lista(0))
    do i = 1, size(TROCAS)
      if (TROCAS(i)%de == 'MED@atm_med' .and. TROCAS(i)%para == 'MED@ocn_med') &
        lista = [character(len=24) :: lista, TROCAS(i)%campo]
    end do
  end function atm_med_para_ocn_med

  !> Todo nome de export_names parte do mediador por conector em alguma
  !! configuração, e nenhum outro nome parte por conector.
  logical function todos_exportados() result(ok)
    integer :: i

    ok = .true.
    do i = 1, size(export_names)
      if (.not. any(TROCAS%campo == export_names(i) .and. TROCAS%de == 'MED@ocn_med' .and. &
                    TROCAS%meio == 'conector')) then
        ok = .false.
        call falha('exportado sem conector: '//trim(export_names(i)))
      end if
    end do
    do i = 1, size(TROCAS)
      if (TROCAS(i)%de /= 'MED@ocn_med' .or. TROCAS(i)%meio /= 'conector') cycle
      if (.not. any(export_names == TROCAS(i)%campo)) then
        ok = .false.
        call falha('conector do mediador com campo nao exportado: '//descreve(i))
      end if
    end do
  end function todos_exportados

  !> Campos de EXPORTACOES no ponto, na ordem da tabela.
  function exportadas(ponto) result(lista)
    character(len=*), intent(in) :: ponto
    character(len=24), allocatable :: lista(:)
    integer :: i

    allocate(lista(0))
    do i = 1, size(EXPORTACOES)
      if (EXPORTACOES(i)%ponto == ponto) lista = [character(len=24) :: lista, EXPORTACOES(i)%campo]
    end do
  end function exportadas

  !> A linha j de EXPORTACOES vale na configuração c.
  logical function exporta_vale(j, c)
    integer,            intent(in) :: j
    type(cpl_config_t), intent(in) :: c
    type(cpl_troca_t) :: t

    t%quando = EXPORTACOES(j)%quando
    exporta_vale = cpl_troca_vale(t, c)
  end function exporta_vale

  function descreve_exp(i) result(txt)
    integer, intent(in) :: i
    character(len=:), allocatable :: txt
    txt = trim(EXPORTACOES(i)%campo)//' '//trim(EXPORTACOES(i)%ponto)// &
          ' ("'//trim(EXPORTACOES(i)%quando)//'")'
  end function descreve_exp

  logical function lista_igual(a, b) result(ok)
    character(len=*), intent(in) :: a(:), b(:)
    integer :: i

    ok = size(a) == size(b)
    if (.not. ok) then
      write(*, '(A, I0, A, I0)') '        tamanhos: mapa ', size(a), ', lista ', size(b)
      return
    end if
    do i = 1, size(a)
      if (trim(a(i)) /= trim(b(i))) then
        ok = .false.
        write(*, '(A, I0, 4A)') '        posicao ', i, ': mapa ', trim(a(i)), ', lista ', trim(b(i))
      end if
    end do
  end function lista_igual

  logical function ponto_valido(ponto)
    character(len=*), intent(in) :: ponto
    integer :: km

    km = cpl_malha_indice(cpl_ponto_malha(ponto))
    ponto_valido = km > 0
    if (ponto_valido) ponto_valido = MALHAS(km)%componente == cpl_ponto_componente(ponto)
  end function ponto_valido

  logical function malha_do_mediador(nome)
    character(len=*), intent(in) :: nome
    integer :: km

    km = cpl_malha_indice(nome)
    malha_do_mediador = km > 0
    if (malha_do_mediador) malha_do_mediador = MALHAS(km)%componente == 'MED'
  end function malha_do_mediador

  function descreve(i) result(txt)
    integer, intent(in) :: i
    character(len=:), allocatable :: txt
    txt = trim(TROCAS(i)%campo)//' '//trim(TROCAS(i)%de)//' -> '//trim(TROCAS(i)%para)// &
          ' ('//trim(TROCAS(i)%meio)//', "'//trim(TROCAS(i)%quando)//'")'
  end function descreve

  subroutine falha(msg)
    character(len=*), intent(in) :: msg
    write(*, '(2A)') '        ', msg
  end subroutine falha

  subroutine resultado(nome, ok)
    character(len=*), intent(in) :: nome
    logical,          intent(in) :: ok
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', nome
    else
      write(*, '(2A)') 'FALHOU  ', nome
      nfalhas = nfalhas + 1
    end if
  end subroutine resultado

end program test_cpl_map
