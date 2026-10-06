!> @file test_cpl_map.F90
!! @brief Consistência do mapa de acoplamento (cpl_fields e cpl_map).
!!
!! Confere, sem MPI e sem ESMF inicializado, que as tabelas FIELDS, GRIDS,
!! EXCHANGES e ROUTES formam uma descrição coerente do acoplamento de hoje:
!!
!!   estrutura   nomes únicos; todo campo de EXCHANGES e de EXPORTS está
!!               em FIELDS e todo campo de FIELDS é usado; pontos 'COMPONENTE@malha' com
!!               malha conhecida e componente certo; condições válidas;
!!               meio coerente com os componentes (conector entre dois
!!               componentes, cap dentro de um, rota dentro do mediador,
!!               entre as malhas da rota); rotas com reserva, máscara,
!!               no_value e criar válidos; toda rota usada
!!   origem      em cada configuração, cada campo importado por um
!!               componente tem uma única origem, e cada campo chega por
!!               rota ou cap a um ponto por um só caminho
!!   cadeia      em cada configuração, todo campo que parte de um ponto
!!               intermediário (grade do cap atmosférico, grade do oceano no
!!               mediador) chegou antes a ele; as exceções são as lacunas
!!               conhecidas, da tabela GAPS do mapa (desde a R-FASE11-25;
!!               antes, uma lista neste teste), e o teste exige que sejam
!!               exatamente essas
!!   contagens   campos de cada conector na configuração de produção iguais
!!               aos do Apêndice A de docs/historico/arquitetura-acoplamento-fase11.md
!!   mediador    campos que chegam ao mediador por conector iguais, na mesma
!!               ordem, a import_mpas_names e import_datm_names; campos que
!!               voltam da malha de fluxo para a do oceano iguais, na mesma
!!               ordem, a export_names (listas de listas_mediador.inc, as
!!               do med_cap_types até a R-FASE11-04-FIX01)
!!   listas      as listas que o mediador anuncia e realiza desde a
!!               R-FASE11-05, geradas por cpl_arrivals com as chaves do
!!               mediador (MED_KEYS), iguais nome a nome e na mesma ordem
!!               às de antes, em cada configuração: importação na malha de
!!               fluxo, importação na grade do oceano, exportação e a
!!               importação toda (a ordem do anúncio)
!!   exportacoes cada linha de EXPORTS com campo do dicionário, ponto de
!!               um modelo (não do mediador) e condição válida, sem
!!               repetição; todo campo que sai de um modelo por conector numa
!!               configuração é exportado por ele nessa configuração; as
!!               exportações de cada modelo iguais, nome a nome e na mesma
!!               ordem, às listas dos caps (listas_caps.inc)
!!   modos       a tabela COUPLER_MODES (coupler_config) tem as 16
!!               combinações das quatro chaves, uma vez cada, com situação
!!               conhecida e nota; as suportadas são exatamente as duas de
!!               produção; as configurações conferidas aqui são aceitas; e
!!               toda linha de EXCHANGES, EXPORTS e GAPS vale em alguma
!!               combinação aceita (desde a R-FASE13-01)
!!   caps        as listas que os caps dos modelos anunciam, geradas por
!!               cpl_arrivals e cpl_exports sem chaves (MOM6 e SIS2 desde
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
  use cpl_fields_mod,    only : FIELDS, cpl_field_index, cpl_field_attributes
  use cpl_map_mod,       only : GRIDS, EXCHANGES, ROUTES, cpl_config_t, cpl_exchange_applies, &
                                cpl_valid_conditions, cpl_route_index, cpl_grid_index, &
                                cpl_point_component, cpl_point_grid, cpl_exchange_t
  use cpl_map_mod,       only : cpl_arrivals, cpl_exports, EXPORTS, cpl_route_fields
  use cpl_map_mod,       only : CONNECTOR_METHODS, cpl_connector_method
  use cpl_map_mod,       only : GAPS, cpl_is_gap, cpl_config_is_valid
  use coupler_config_mod, only : COUPLER_MODES, coupler_mode_index, cpl_current_config
  use cpl_fields_mod,    only : CPL_NAME_LEN
  use med_cap_types_mod, only : MED_KEYS, MED_FIELDS
  implicit none

  include 'listas_mediador.inc'
  include 'listas_caps.inc'

  integer, parameter :: NCFG = 5
  character(len=16), parameter :: CFG_NAME(NCFG) = [character(len=16) :: &
    'producao', 'mom6_sem_sis2', 'mpas_docn', 'datm_mom6', 'datm_docn']
  type(cpl_config_t), parameter :: CFG(NCFG) = [                                       &
    cpl_config_t(datm=.false., docn=.false., med_to_mpas=.true.,  sis2=.true.),         &
    cpl_config_t(datm=.false., docn=.false., med_to_mpas=.true.,  sis2=.false.),        &
    cpl_config_t(datm=.false., docn=.true.,  med_to_mpas=.false., sis2=.false.),        &
    cpl_config_t(datm=.true.,  docn=.false., med_to_mpas=.true.,  sis2=.false.),        &
    cpl_config_t(datm=.true.,  docn=.true.,  med_to_mpas=.false., sis2=.false.) ]


  !> Malhas onde um modelo produz campos, e a malha de fluxo do mediador,
  !! onde ele os calcula: pontos de partida que não precisam de chegada.
  character(len=12), parameter :: PRODUCTION(*) = [character(len=12) :: &
    'mpas', 'datm', 'ocn_mom6', 'docn', 'ice_sis2', 'atm_med']

  integer :: nfailures, k

  nfailures = 0

  call check_fields()
  call check_field_attributes()
  call check_modes()
  call check_grids_and_routes()
  call check_exchanges()
  call check_methods()
  call check_cap_exchanges()
  do k = 1, NCFG
    call check_origins(k)
    call check_chain(k)
  end do
  call check_counts()
  call check_mediator()
  do k = 1, NCFG
    call check_mediator_lists(k)
  end do
  call check_exports()
  do k = 1, NCFG
    call check_export_connector(k)
  end do
  call check_cap_lists()
  do k = 1, NCFG
    call check_export_loop(k)
  end do

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Exportação do mediador pelo mapa, na configuração k: os campos da rota
  !! 'atm2ocn' (cpl_route_fields) são as chegadas a MED@ocn_med por rota
  !! menos as da rota 'atm2ocn_ice', na mesma ordem, e todos estão em
  !! MED_FIELDS, de onde o laço de med_export os tira.
  subroutine check_export_loop(k)
    integer, intent(in) :: k
    character(len=CPL_NAME_LEN), allocatable :: by_route(:), arrivals(:), expected(:)
    integer :: i, nmiss

    call cpl_route_fields('atm2ocn', 'MED@ocn_med', CFG(k), '', by_route)
    call cpl_arrivals('MED@ocn_med', .false., CFG(k), '', arrivals)
    allocate(expected(0))
    do i = 1, size(arrivals)
      if (any(EXCHANGES%field == arrivals(i) .and. EXCHANGES%via == 'atm2ocn' .and. &
              EXCHANGES%dst == 'MED@ocn_med')) &
        expected = [character(len=CPL_NAME_LEN) :: expected, arrivals(i)]
    end do
    nmiss = 0
    do i = 1, size(by_route)
      if (.not. any(MED_FIELDS%name == by_route(i))) then
        nmiss = nmiss + 1
        call fail_at('exportado pela rota atm2ocn e fora de MED_FIELDS: '//trim(by_route(i)))
      end if
    end do
    call outcome('exportacao pela rota atm2ocn ('//trim(CFG_NAME(k))//'): lista e ordem', &
                 size(by_route) == size(expected) .and. all(by_route == expected))
    call outcome('exportacao pela rota atm2ocn ('//trim(CFG_NAME(k))//'): campos em MED_FIELDS', &
                 nmiss == 0)
  end subroutine check_export_loop

  !> Nomes de FIELDS únicos e preenchidos; todo campo usado em EXCHANGES ou
  !! em EXPORTS.
  subroutine check_fields()
    integer :: i, j, nrep, nempty, nunused

    nrep = 0; nempty = 0; nunused = 0
    do i = 1, size(FIELDS)
      if (len_trim(FIELDS(i)%name) == 0 .or. len_trim(FIELDS(i)%units) == 0 .or. &
          len_trim(FIELDS(i)%description) == 0) then
        nempty = nempty + 1
        call fail_at('campo sem nome, unidade ou descricao: '//trim(FIELDS(i)%name))
      end if
      do j = i + 1, size(FIELDS)
        if (FIELDS(i)%name == FIELDS(j)%name) then
          nrep = nrep + 1
          call fail_at('campo repetido em CAMPOS: '//trim(FIELDS(i)%name))
        end if
      end do
      if (.not. any(EXCHANGES%field == FIELDS(i)%name) .and. &
          .not. any(EXPORTS%field == FIELDS(i)%name)) then
        nunused = nunused + 1
        call fail_at('campo sem troca nem exportacao: '//trim(FIELDS(i)%name))
      end if
    end do
    call outcome('CAMPOS: nomes unicos', nrep == 0)
    call outcome('CAMPOS: nome, unidade e descricao preenchidos', nempty == 0)
    call outcome('CAMPOS: todo campo aparece em TROCAS ou EXPORTACOES', nunused == 0)
  end subroutine check_fields

  !> Nome longo e nome CF: preenchidos juntos; cpl_field_attributes devolve
  !! os textos do dicionário para um campo com nome longo e os padrões ('1',
  !! o nome, 'unknown') para um campo sem nome longo e para um nome fora do
  !! dicionário.
  subroutine check_field_attributes()
    character(len=32) :: u
    character(len=96) :: l
    character(len=80) :: s
    integer :: i, nerr

    nerr = 0
    do i = 1, size(FIELDS)
      if ((len_trim(FIELDS(i)%long_name) == 0) .neqv. (len_trim(FIELDS(i)%cf_name) == 0)) then
        nerr = nerr + 1
        call fail_at('nome longo sem nome CF, ou o contrario: '//trim(FIELDS(i)%name))
      end if
    end do
    call outcome('CAMPOS: nome longo e nome CF preenchidos juntos', nerr == 0)

    call cpl_field_attributes('Foxx_taux', u, l, s)
    call outcome('atributos de Foxx_taux pelo dicionario',                       &
                 u == 'Pa' .and. l == 'Tensao cisalhamento zonal' .and.           &
                 s == 'surface_downward_eastward_stress')
    call cpl_field_attributes('Faxa_sen_mpas', u, l, s)
    call outcome('atributos padrao para campo sem nome longo (Faxa_sen_mpas)',   &
                 u == '1' .and. l == 'Faxa_sen_mpas' .and. s == 'unknown')
    call cpl_field_attributes('Sa_ubot', u, l, s)
    call outcome('atributos padrao para nome fora do dicionario (Sa_ubot)',      &
                 u == '1' .and. l == 'Sa_ubot' .and. s == 'unknown')
  end subroutine check_field_attributes

  !> COUPLER_MODES: as 16 combinações, uma vez cada, com situação e nota;
  !! as suportadas são as duas de produção (com e sem o SIS2); as
  !! configurações deste teste são aceitas; toda linha de EXCHANGES, EXPORTS
  !! e GAPS vale em alguma combinação aceita.
  subroutine check_modes()
    type(cpl_config_t) :: c
    integer :: i, j, k, nerr, nsupported
    logical :: used

    nerr = 0
    if (size(COUPLER_MODES) /= 16) then
      nerr = nerr + 1
      call fail_at('COUPLER_MODES nao tem 16 linhas')
    end if
    do k = 0, 15
      j = 0
      do i = 1, size(COUPLER_MODES)
        if ((COUPLER_MODES(i)%datm .eqv. btest(k, 0)) .and. (COUPLER_MODES(i)%docn .eqv. btest(k, 1)) &
            .and. (COUPLER_MODES(i)%med_to_mpas .eqv. btest(k, 2))                                  &
            .and. (COUPLER_MODES(i)%sis2 .eqv. btest(k, 3))) j = j + 1
      end do
      if (j /= 1) then
        nerr = nerr + 1
        write(*, '(A, I0, A, I0)') '        combinacao ', k, ' aparece vezes: ', j
      end if
    end do
    nsupported = 0
    do i = 1, size(COUPLER_MODES)
      select case (trim(COUPLER_MODES(i)%status))
      case ('suportada')
        nsupported = nsupported + 1
        if (COUPLER_MODES(i)%datm .or. COUPLER_MODES(i)%docn .or. &
            .not. COUPLER_MODES(i)%med_to_mpas) then
          nerr = nerr + 1
          call fail_at('suportada fora da producao: '//trim(COUPLER_MODES(i)%note))
        end if
      case ('nao_validada', 'recusada')
      case default
        nerr = nerr + 1
        call fail_at('situacao desconhecida: '//trim(COUPLER_MODES(i)%status))
      end select
      if (len_trim(COUPLER_MODES(i)%note) == 0) then
        nerr = nerr + 1
        call fail_at('combinacao sem nota')
      end if
    end do
    call outcome('MODOS: 16 combinacoes, situacao conhecida e nota', nerr == 0)
    call outcome('MODOS: suportadas = producao com e sem SIS2', nsupported == 2 .and. nerr == 0)

    nerr = 0
    do k = 1, NCFG
      if (.not. cpl_config_is_valid(CFG(k))) then
        nerr = nerr + 1
        call fail_at('configuracao do teste recusada: '//trim(CFG_NAME(k)))
      end if
    end do
    if (trim(COUPLER_MODES(coupler_mode_index(.false., .false., .true., .true.))%status) /= &
        'suportada') then
      nerr = nerr + 1
      call fail_at('producao nao suportada')
    end if
    call outcome('MODOS: configuracoes do teste aceitas; producao suportada', nerr == 0)

    nerr = 0
    do i = 1, size(EXCHANGES)
      used = .false.
      do k = 0, 15
        c = cpl_config_t(datm=btest(k, 0), docn=btest(k, 1), med_to_mpas=btest(k, 2), sis2=btest(k, 3))
        if (cpl_config_is_valid(c)) used = used .or. cpl_exchange_applies(EXCHANGES(i), c)
      end do
      if (.not. used) then
        nerr = nerr + 1
        call fail_at('troca sem combinacao aceita: '//describe(i))
      end if
    end do
    do i = 1, size(EXPORTS)
      used = .false.
      do k = 0, 15
        c = cpl_config_t(datm=btest(k, 0), docn=btest(k, 1), med_to_mpas=btest(k, 2), sis2=btest(k, 3))
        if (cpl_config_is_valid(c)) used = used .or. &
          cpl_exchange_applies(cpl_exchange_t(when=EXPORTS(i)%when), c)
      end do
      if (.not. used) then
        nerr = nerr + 1
        call fail_at('exportacao sem combinacao aceita: '//trim(EXPORTS(i)%field))
      end if
    end do
    do i = 1, size(GAPS)
      used = .false.
      do k = 0, 15
        c = cpl_config_t(datm=btest(k, 0), docn=btest(k, 1), med_to_mpas=btest(k, 2), sis2=btest(k, 3))
        if (cpl_config_is_valid(c)) used = used .or. &
          cpl_exchange_applies(cpl_exchange_t(when=GAPS(i)%when), c)
      end do
      if (.not. used) then
        nerr = nerr + 1
        call fail_at('lacuna sem combinacao aceita: '//trim(GAPS(i)%field))
      end if
    end do
    call outcome('MODOS: toda linha de TROCAS, EXPORTACOES e LACUNAS vale em combinacao aceita', &
                 nerr == 0)
  end subroutine check_modes

  !> GRIDS e ROUTES: nomes únicos; rotas entre malhas do mediador, com
  !! reserva, máscara, no_value e criar válidos; toda rota usada.
  subroutine check_grids_and_routes()
    integer :: i, j, kr, nerr

    nerr = 0
    do i = 1, size(GRIDS)
      do j = i + 1, size(GRIDS)
        if (GRIDS(i)%name == GRIDS(j)%name) then
          nerr = nerr + 1
          call fail_at('malha repetida: '//trim(GRIDS(i)%name))
        end if
      end do
    end do
    call outcome('MALHAS: nomes unicos', nerr == 0)

    nerr = 0
    do i = 1, size(ROUTES)
      do j = i + 1, size(ROUTES)
        if (ROUTES(i)%name == ROUTES(j)%name) then
          nerr = nerr + 1
          call fail_at('rota repetida: '//trim(ROUTES(i)%name))
        end if
      end do
      if (.not. mediator_grid(ROUTES(i)%src) .or. .not. mediator_grid(ROUTES(i)%dst)) then
        nerr = nerr + 1
        call fail_at('rota fora das malhas do mediador: '//trim(ROUTES(i)%name))
      end if
      if (ROUTES(i)%src == ROUTES(i)%dst) then
        nerr = nerr + 1
        call fail_at('rota com origem igual ao destino: '//trim(ROUTES(i)%name))
      end if
      if (len_trim(ROUTES(i)%methods) == 0) then
        nerr = nerr + 1
        call fail_at('rota sem metodo: '//trim(ROUTES(i)%name))
      end if
      if (len_trim(ROUTES(i)%fallback) > 0) then
        kr = cpl_route_index(ROUTES(i)%fallback)
        if (kr == 0 .or. kr >= i) then
          nerr = nerr + 1
          call fail_at('reserva inexistente ou criada depois: '//trim(ROUTES(i)%name))
        else if (ROUTES(kr)%src /= ROUTES(i)%src .or. ROUTES(kr)%dst /= ROUTES(i)%dst) then
          nerr = nerr + 1
          call fail_at('reserva entre outras malhas: '//trim(ROUTES(i)%name))
        end if
      end if
      if (len_trim(ROUTES(i)%mask) > 0 .and. cpl_field_index(ROUTES(i)%mask) == 0) then
        nerr = nerr + 1
        call fail_at('mascara fora de CAMPOS: '//trim(ROUTES(i)%name))
      end if
      if (.not. any(ROUTES(i)%no_value == [character(len=12) :: 'zerar', 'manter', 'sentinela'])) then
        nerr = nerr + 1
        call fail_at('sem_valor invalido: '//trim(ROUTES(i)%name))
      end if
      if (.not. any(ROUTES(i)%create == [character(len=16) :: 'inicio', 'primeiro_uso', 'mascara_mista'])) then
        nerr = nerr + 1
        call fail_at('criar invalido: '//trim(ROUTES(i)%name))
      end if
      if (ROUTES(i)%create == 'mascara_mista' .and. &
          (len_trim(ROUTES(i)%mask) == 0 .or. len_trim(ROUTES(i)%fallback) == 0)) then
        nerr = nerr + 1
        call fail_at('criar=mascara_mista sem mascara ou reserva: '//trim(ROUTES(i)%name))
      end if
      if (.not. any(EXCHANGES%via == ROUTES(i)%name)) then
        nerr = nerr + 1
        call fail_at('rota sem troca: '//trim(ROUTES(i)%name))
      end if
    end do
    call outcome('ROTAS: nomes, malhas, reservas, mascaras, sem_valor e criar', nerr == 0)
    ! A ordem de ROUTES é a ordem em que a reserva precisa existir.
    call outcome('ROTAS: seis rotas (Apendice A)', size(ROUTES) == 6)
  end subroutine check_grids_and_routes

  !> Cada linha de EXCHANGES: campo no dicionário, pontos válidos, condições
  !! válidas, meio coerente; nenhuma linha repetida.
  subroutine check_exchanges()
    integer :: i, j, kr, nerr
    character(len=16) :: comp_src_i, comp_dst_i, grid_src_i, grid_dst_i

    nerr = 0
    do i = 1, size(EXCHANGES)
      if (cpl_field_index(EXCHANGES(i)%field) == 0) then
        nerr = nerr + 1
        call fail_at('campo fora de CAMPOS: '//trim(EXCHANGES(i)%field))
      end if
      if (.not. valid_point(EXCHANGES(i)%src) .or. .not. valid_point(EXCHANGES(i)%dst)) then
        nerr = nerr + 1
        call fail_at('ponto invalido: '//describe(i))
      end if
      if (.not. cpl_valid_conditions(EXCHANGES(i)%when)) then
        nerr = nerr + 1
        call fail_at('condicao invalida: '//describe(i))
      end if
      comp_src_i = cpl_point_component(EXCHANGES(i)%src)
      comp_dst_i = cpl_point_component(EXCHANGES(i)%dst)
      grid_src_i = cpl_point_grid(EXCHANGES(i)%src)
      grid_dst_i = cpl_point_grid(EXCHANGES(i)%dst)
      select case (trim(EXCHANGES(i)%via))
      case ('conector')
        if (comp_src_i == comp_dst_i) then
          nerr = nerr + 1
          call fail_at('conector dentro de um componente: '//describe(i))
        end if
      case ('cap')
        if (comp_src_i /= comp_dst_i .or. grid_src_i == grid_dst_i .or. comp_src_i == 'MED') then
          nerr = nerr + 1
          call fail_at('cap fora de um componente com duas malhas: '//describe(i))
        end if
      case default
        kr = cpl_route_index(EXCHANGES(i)%via)
        if (kr == 0) then
          nerr = nerr + 1
          call fail_at('rota inexistente: '//describe(i))
        else if (comp_src_i /= 'MED' .or. comp_dst_i /= 'MED' .or. &
                 ROUTES(kr)%src /= grid_src_i .or. ROUTES(kr)%dst /= grid_dst_i) then
          nerr = nerr + 1
          call fail_at('rota entre malhas diferentes das da troca: '//describe(i))
        end if
      end select
      do j = i + 1, size(EXCHANGES)
        if (EXCHANGES(i)%field == EXCHANGES(j)%field .and. EXCHANGES(i)%src == EXCHANGES(j)%src .and. &
            EXCHANGES(i)%dst == EXCHANGES(j)%dst .and. EXCHANGES(i)%when == EXCHANGES(j)%when) then
          nerr = nerr + 1
          call fail_at('troca repetida: '//describe(i))
        end if
      end do
    end do
    call outcome('TROCAS: campos, pontos, condicoes e meios validos, sem repeticao', nerr == 0)
  end subroutine check_exchanges

  !> Coluna metodo (R-FASE11-22): preenchida, com um valor aceito pelo
  !! conector NUOPC, só nas trocas por conector; o mesmo método nas trocas
  !! do mesmo campo entre os mesmos dois componentes (cpl_connector_method não
  !! depende da configuração); hoje, bilinear em todas, o padrão que o
  !! conector usava antes de a opção ser escrita.
  subroutine check_methods()
    integer :: i, j, nerr, nbilinear, ncon
    character(len=16) :: comp_src_i, comp_dst_i

    nerr = 0; nbilinear = 0; ncon = 0
    do i = 1, size(EXCHANGES)
      if (trim(EXCHANGES(i)%via) /= 'conector') then
        if (len_trim(EXCHANGES(i)%method) > 0) then
          nerr = nerr + 1
          call fail_at('metodo fora de troca por conector: '//describe(i))
        end if
        cycle
      end if
      ncon = ncon + 1
      if (.not. any(CONNECTOR_METHODS == EXCHANGES(i)%method)) then
        nerr = nerr + 1
        call fail_at('metodo invalido: '//describe(i)//' '//trim(EXCHANGES(i)%method))
      end if
      if (EXCHANGES(i)%method == 'bilinear') nbilinear = nbilinear + 1
      comp_src_i = cpl_point_component(EXCHANGES(i)%src)
      comp_dst_i = cpl_point_component(EXCHANGES(i)%dst)
      do j = 1, size(EXCHANGES)
        if (trim(EXCHANGES(j)%via) /= 'conector' .or. EXCHANGES(j)%field /= EXCHANGES(i)%field) cycle
        if (cpl_point_component(EXCHANGES(j)%src) /= comp_src_i) cycle
        if (cpl_point_component(EXCHANGES(j)%dst) /= comp_dst_i) cycle
        if (EXCHANGES(j)%method /= EXCHANGES(i)%method) then
          nerr = nerr + 1
          call fail_at('metodos diferentes para o mesmo campo e conector: '//describe(i))
        end if
      end do
      if (cpl_connector_method(EXCHANGES(i)%field, comp_src_i, comp_dst_i) /= EXCHANGES(i)%method) then
        nerr = nerr + 1
        call fail_at('cpl_metodo_conector diferente da tabela: '//describe(i))
      end if
    end do
    call outcome('TROCAS: metodo valido so nas trocas por conector, um por campo e conector', &
                   nerr == 0)
    call outcome('TROCAS: todas as trocas por conector com bilinear (padrao do NUOPC)', &
                   nbilinear == ncon .and. ncon > 0)
    call outcome('cpl_metodo_conector: vazio sem troca por conector', &
                   len_trim(cpl_connector_method('So_t', 'MED', 'ATM')) == 0 .and. &
                   len_trim(cpl_connector_method('Foxx_taux', 'MED', 'MED')) == 0 .and. &
                   len_trim(cpl_connector_method('Sa_u10m_mpas', 'ATM', 'ATM')) == 0)
    call outcome('cpl_metodo_conector: So_t do OCN para o MED e do MED para o ICE', &
                   cpl_connector_method('So_t', 'OCN', 'MED') == 'bilinear' .and. &
                   cpl_connector_method('So_t', 'MED', 'ICE') == 'bilinear')
  end subroutine check_methods

  !> Trocas 'cap' do MONAN-A (R-FASE11-24), feitas pelo adaptador do MPAS
  !! (mpas_adapter): as de ATM@mpas para ATM@atm_cap são exatamente os
  !! campos que o MONAN-A exporta (cpl_exports, os de mpas_export), e as
  !! de ATM@atm_cap para ATM@mpas, na mesma ordem, os que ele importa
  !! (cpl_arrivals por conector, os de mpas_import). O cap consulta o mapa
  !! sem chaves (todas as configurações).
  subroutine check_cap_exchanges()
    character(len=CPL_NAME_LEN), allocatable :: exp(:), imp(:), outbound(:), inbound(:)
    logical :: ok_outbound, ok_inbound
    integer :: t

    allocate(outbound(0), inbound(0))
    do t = 1, size(EXCHANGES)
      if (trim(EXCHANGES(t)%via) /= 'cap') cycle
      if (EXCHANGES(t)%src == 'ATM@mpas' .and. EXCHANGES(t)%dst == 'ATM@atm_cap') &
        outbound = [character(len=CPL_NAME_LEN) :: outbound, EXCHANGES(t)%field]
      if (EXCHANGES(t)%src == 'ATM@atm_cap' .and. EXCHANGES(t)%dst == 'ATM@mpas') &
        inbound = [character(len=CPL_NAME_LEN) :: inbound, EXCHANGES(t)%field]
    end do
    call cpl_exports('ATM@atm_cap', CFG(1), '', exp)
    call cpl_arrivals('ATM@atm_cap', .true., CFG(1), '', imp)
    ok_outbound = size(outbound) == size(exp) .and. size(outbound) == 13
    if (ok_outbound) ok_outbound = all([(any(exp == outbound(t)), t = 1, size(outbound))])
    ok_inbound = size(inbound) == size(imp) .and. size(inbound) == 7
    if (ok_inbound) ok_inbound = all(inbound == imp)
    call outcome('trocas cap ATM@mpas -> ATM@atm_cap: as 13 exportacoes do MONAN-A', ok_outbound)
    call outcome('trocas cap ATM@atm_cap -> ATM@mpas: as 7 importacoes, na mesma ordem', ok_inbound)
    ok_outbound = .true.
    do t = 1, size(GAPS)
      ok_outbound = ok_outbound .and. cpl_field_index(GAPS(t)%field) > 0 .and. &
               valid_point(GAPS(t)%point) .and. cpl_valid_conditions(GAPS(t)%when)
    end do
    call outcome('LACUNAS: campos, pontos e condicoes validos', ok_outbound)
  end subroutine check_cap_exchanges

  !> Na configuração k: cada (campo, destino) recebe de uma só troca, entre
  !! as que chegam por conector (importação) e entre as demais.
  subroutine check_origins(k)
    integer, intent(in) :: k
    integer :: i, j, n, nerr
    logical :: connector_i

    nerr = 0
    do i = 1, size(EXCHANGES)
      if (.not. cpl_exchange_applies(EXCHANGES(i), CFG(k))) cycle
      connector_i = EXCHANGES(i)%via == 'conector'
      n = 0
      do j = 1, size(EXCHANGES)
        if (.not. cpl_exchange_applies(EXCHANGES(j), CFG(k))) cycle
        if (EXCHANGES(j)%field /= EXCHANGES(i)%field .or. EXCHANGES(j)%dst /= EXCHANGES(i)%dst) cycle
        if ((EXCHANGES(j)%via == 'conector') .neqv. connector_i) cycle
        n = n + 1
      end do
      if (n /= 1) then
        nerr = nerr + 1
        call fail_at(trim(CFG_NAME(k))//': mais de uma origem: '//describe(i))
      end if
    end do
    call outcome(trim(CFG_NAME(k))//': cada campo com uma unica origem', nerr == 0)
  end subroutine check_origins

  !> Na configuração k: quem parte de um ponto intermediário chegou a ele
  !! (por conector, se parte por rota ou cap; por rota ou cap, se parte por
  !! conector). As faltas têm de ser exatamente as lacunas conhecidas.
  subroutine check_chain(k)
    integer, intent(in) :: k
    integer :: i, j, l, nmissing, nexpected, nerr
    logical :: arrived, is_expected

    nmissing = 0; nerr = 0
    do i = 1, size(EXCHANGES)
      if (.not. cpl_exchange_applies(EXCHANGES(i), CFG(k))) cycle
      if (any(PRODUCTION == cpl_point_grid(EXCHANGES(i)%src))) cycle
      arrived = .false.
      do j = 1, size(EXCHANGES)
        if (.not. cpl_exchange_applies(EXCHANGES(j), CFG(k))) cycle
        if (EXCHANGES(j)%field /= EXCHANGES(i)%field .or. EXCHANGES(j)%dst /= EXCHANGES(i)%src) cycle
        if ((EXCHANGES(j)%via == 'conector') .eqv. (EXCHANGES(i)%via == 'conector')) cycle
        arrived = .true.
      end do
      if (arrived) cycle
      nmissing = nmissing + 1
      is_expected = cpl_is_gap(CFG(k), EXCHANGES(i)%field, EXCHANGES(i)%src)
      if (.not. is_expected) then
        nerr = nerr + 1
        call fail_at(trim(CFG_NAME(k))//': parte sem ter chegado: '//describe(i))
      end if
    end do
    nexpected = 0
    do l = 1, size(GAPS)
      if (cpl_is_gap(CFG(k), GAPS(l)%field, GAPS(l)%point)) nexpected = nexpected + 1
    end do
    if (nmissing /= nexpected .and. nerr == 0) &
      call fail_at(trim(CFG_NAME(k))//': lacuna conhecida que deixou de existir')
    call outcome(trim(CFG_NAME(k))//': cadeia completa, exceto as lacunas conhecidas', &
                   nerr == 0 .and. nmissing == nexpected)
  end subroutine check_chain

  !> Campos por conector na produção, como no Apêndice A.
  subroutine check_counts()
    call outcome('producao: ATM para MED, 13 campos', n_connector('ATM', 'MED') == 13)
    call outcome('producao: OCN para MED, 4 campos',  n_connector('OCN', 'MED') == 4)
    call outcome('producao: ICE para MED, 6 campos',  n_connector('ICE', 'MED') == 6)
    call outcome('producao: MED para OCN, 14 campos', n_connector('MED', 'OCN') == 14)
    call outcome('producao: MED para ICE, 16 campos', n_connector('MED', 'ICE') == 16)
    call outcome('producao: MED para ATM, 7 campos',  n_connector('MED', 'ATM') == 7)
    call outcome('producao: OCN para ATM, nenhum campo', n_connector('OCN', 'ATM') == 0)
  end subroutine check_counts

  !> Listas do mediador (med_cap_types) contra o mapa, nome a nome.
  subroutine check_mediator()
    call outcome('mediador: importacao do MONAN-A igual a import_mpas_names', &
      same_list(arrivals_by_connector('MED', CFG(1), 'ATM'), import_mpas_names))
    call outcome('mediador: importacao do DATM igual a import_datm_names', &
      same_list(arrivals_by_connector('MED', CFG(5), 'ATM'), import_datm_names))
    call outcome('mediador: atm_med para ocn_med igual a export_names', &
      same_list(atm_med_to_ocn_med(), export_names))
    call outcome('mediador: todo campo exportado sai por algum conector', &
      all_exported())
  end subroutine check_mediator

  !> Na configuração k, as listas geradas do mapa para o mediador são as que
  !! ele anunciava e realizava antes: forçantes do MONAN-A ou do DATM na
  !! malha de fluxo; So_t, So_u, So_v, So_omask e, com o SIS2, os *_sis2 na
  !! grade do oceano; as 31 exportações em todas as configurações.
  subroutine check_mediator_lists(k)
    integer, intent(in) :: k
    character(len=CPL_NAME_LEN), allocatable :: atm(:), ocn(:), all_names(:), exp(:)
    character(len=32), allocatable :: want_atm(:), want_ocn(:)

    if (CFG(k)%datm) then
      want_atm = import_datm_names
    else
      want_atm = import_mpas_names
    end if
    if (CFG(k)%sis2) then
      want_ocn = [character(len=32) :: MED_IMP_OCN, MED_IMP_SIS2]
    else
      want_ocn = MED_IMP_OCN
    end if
    call cpl_arrivals('MED@atm_med', .true., CFG(k), MED_KEYS, atm)
    call cpl_arrivals('MED@ocn_med', .true., CFG(k), MED_KEYS, ocn)
    call cpl_arrivals('MED', .true., CFG(k), MED_KEYS, all_names)
    call cpl_arrivals('MED@ocn_med', .false., CFG(k), '', exp)
    call outcome(trim(CFG_NAME(k))//': mediador, importacao na malha de fluxo', &
      same_list(atm, want_atm))
    call outcome(trim(CFG_NAME(k))//': mediador, importacao na grade do oceano', &
      same_list(ocn, want_ocn))
    call outcome(trim(CFG_NAME(k))//': mediador, importacao na ordem do anuncio', &
      same_list(all_names, [character(len=32) :: want_atm, want_ocn]))
    call outcome(trim(CFG_NAME(k))//': mediador, exportacao', same_list(exp, export_names))
  end subroutine check_mediator_lists

  !> Cada linha de EXPORTS: campo no dicionário, ponto de um modelo,
  !! condição válida, sem repetição; exportações de cada modelo iguais às
  !! listas dos caps.
  subroutine check_exports()
    integer :: i, j, nerr

    nerr = 0
    do i = 1, size(EXPORTS)
      if (cpl_field_index(EXPORTS(i)%field) == 0) then
        nerr = nerr + 1
        call fail_at('exportacao fora de CAMPOS: '//trim(EXPORTS(i)%field))
      end if
      if (.not. valid_point(EXPORTS(i)%point) .or. &
          cpl_point_component(EXPORTS(i)%point) == 'MED') then
        nerr = nerr + 1
        call fail_at('exportacao com ponto invalido: '//describe_exp(i))
      end if
      if (.not. cpl_valid_conditions(EXPORTS(i)%when)) then
        nerr = nerr + 1
        call fail_at('exportacao com condicao invalida: '//describe_exp(i))
      end if
      do j = i + 1, size(EXPORTS)
        if (EXPORTS(i)%field == EXPORTS(j)%field .and. &
            EXPORTS(i)%point == EXPORTS(j)%point) then
          nerr = nerr + 1
          call fail_at('exportacao repetida: '//describe_exp(i))
        end if
      end do
    end do
    call outcome('EXPORTACOES: campos, pontos e condicoes validos, sem repeticao', nerr == 0)

    call outcome('EXPORTACOES: MONAN-A igual a EXP_NAMES do mpas_cap_MONAN', &
      same_list(exported('ATM@atm_cap'), mpas_exp_names))
    call outcome('EXPORTACOES: DATM igual ao anuncio do DATM_cap', &
      same_list(exported('ATM@datm'), datm_exp_names))
    call outcome('EXPORTACOES: MOM6 igual a export_names do mom_cap_MONAN', &
      same_list(exported('OCN@ocn_mom6'), mom_export_names))
    call outcome('EXPORTACOES: DOCN igual a EXP_NAMES do DOCN_cap', &
      same_list(exported('OCN@docn'), docn_exp_names))
    call outcome('EXPORTACOES: SIS2 igual a export_names do sis_cap_MONAN', &
      same_list(exported('ICE@ice_sis2'), sis_export_names))
  end subroutine check_exports

  !> Na configuração k, todo campo que sai por conector do ponto de um
  !! modelo é exportado por esse ponto nessa configuração.
  subroutine check_export_connector(k)
    integer, intent(in) :: k
    integer :: i, j, nerr
    logical :: found

    nerr = 0
    do i = 1, size(EXCHANGES)
      if (EXCHANGES(i)%via /= 'conector' .or. .not. cpl_exchange_applies(EXCHANGES(i), CFG(k))) cycle
      if (cpl_point_component(EXCHANGES(i)%src) == 'MED') cycle
      found = .false.
      do j = 1, size(EXPORTS)
        if (EXPORTS(j)%field /= EXCHANGES(i)%field .or. EXPORTS(j)%point /= EXCHANGES(i)%src) cycle
        if (export_applies(j, CFG(k))) found = .true.
      end do
      if (.not. found) then
        nerr = nerr + 1
        call fail_at(trim(CFG_NAME(k))//': sai por conector sem ser exportado: '//describe(i))
      end if
    end do
    call outcome(trim(CFG_NAME(k))//': todo campo que sai de um modelo e exportado por ele', &
                   nerr == 0)
  end subroutine check_export_connector

  !> Listas geradas para os caps dos modelos (sem chaves: valem em qualquer
  !! configuração) iguais às que eles anunciavam antes; a configuração
  !! passada não pode mudar o resultado.
  subroutine check_cap_lists()
    character(len=CPL_NAME_LEN), allocatable :: names(:)
    logical :: ok_imp_mom, ok_exp_mom, ok_imp_sis, ok_exp_sis
    logical :: ok_imp_mpas, ok_exp_mpas, ok_exp_datm, ok_imp_docn, ok_exp_docn
    integer :: kc

    ok_imp_mom = .true.; ok_exp_mom = .true.; ok_imp_sis = .true.; ok_exp_sis = .true.
    ok_imp_mpas = .true.; ok_exp_mpas = .true.; ok_exp_datm = .true.
    ok_imp_docn = .true.; ok_exp_docn = .true.
    do kc = 1, NCFG
      call cpl_arrivals('ATM@atm_cap', .true., CFG(kc), '', names)
      ok_imp_mpas = ok_imp_mpas .and. same_list(names, mpas_imp_names)
      call cpl_exports('ATM@atm_cap', CFG(kc), '', names)
      ok_exp_mpas = ok_exp_mpas .and. same_list(names, mpas_exp_names)
      call cpl_exports('ATM@datm', CFG(kc), '', names)
      ok_exp_datm = ok_exp_datm .and. same_list(names, datm_exp_names)
      call cpl_arrivals('OCN@docn', .true., CFG(kc), '', names)
      ok_imp_docn = ok_imp_docn .and. same_list(names, docn_imp_names)
      call cpl_exports('OCN@docn', CFG(kc), '', names)
      ok_exp_docn = ok_exp_docn .and. same_list(names, docn_exp_names)
      call cpl_arrivals('OCN@ocn_mom6', .true., CFG(kc), '', names)
      ok_imp_mom = ok_imp_mom .and. same_list(names, mom_import_names)
      call cpl_exports('OCN@ocn_mom6', CFG(kc), '', names)
      ok_exp_mom = ok_exp_mom .and. same_list(names, mom_export_names)
      call cpl_arrivals('ICE@ice_sis2', .true., CFG(kc), '', names)
      ok_imp_sis = ok_imp_sis .and. &
        same_list(names, [character(len=32) :: sis_import_names_atm, sis_import_names_ocn])
      call cpl_exports('ICE@ice_sis2', CFG(kc), '', names)
      ok_exp_sis = ok_exp_sis .and. same_list(names, sis_export_names)
    end do
    call outcome('caps: importacao do MOM6 igual a de antes, em toda configuracao', ok_imp_mom)
    call outcome('caps: exportacao do MOM6 igual a de antes, em toda configuracao', ok_exp_mom)
    call outcome('caps: importacao do SIS2 igual a de antes, em toda configuracao', ok_imp_sis)
    call outcome('caps: exportacao do SIS2 igual a de antes, em toda configuracao', ok_exp_sis)
    call outcome('caps: importacao do MONAN-A igual a de antes, em toda configuracao', ok_imp_mpas)
    call outcome('caps: exportacao do MONAN-A igual a de antes, em toda configuracao', ok_exp_mpas)
    call outcome('caps: exportacao do DATM igual a de antes, em toda configuracao', ok_exp_datm)
    call outcome('caps: importacao do DOCN igual a de antes, em toda configuracao', ok_imp_docn)
    call outcome('caps: exportacao do DOCN igual a de antes, em toda configuracao', ok_exp_docn)
    call cpl_arrivals('ATM@datm', .true., CFG(4), '', names)
    call outcome('caps: o DATM nao importa nada', size(names) == 0)
    ! Sem nuopc.input, cpl_current_config dá a configuração padrão; o resultado
    ! sem chaves é o mesmo.
    call cpl_arrivals('OCN@ocn_mom6', .true., cpl_current_config(), '', names)
    call outcome('caps: importacao do MOM6 com cpl_config_atual', &
      same_list(names, mom_import_names))
  end subroutine check_cap_lists

  ! --------------------------------------------------------------------------
  ! Auxiliares
  ! --------------------------------------------------------------------------

  !> Número de campos do conector ORIGEM -> DESTINO na produção.
  integer function n_connector(origin, destination) result(n)
    character(len=*), intent(in) :: origin, destination
    integer :: i

    n = 0
    do i = 1, size(EXCHANGES)
      if (EXCHANGES(i)%via /= 'conector' .or. .not. cpl_exchange_applies(EXCHANGES(i), CFG(1))) cycle
      if (cpl_point_component(EXCHANGES(i)%src) == origin .and. &
          cpl_point_component(EXCHANGES(i)%dst) == destination) n = n + 1
    end do
  end function n_connector

  !> Campos que chegam por conector ao componente comp, vindos do componente
  !! origem, na configuração c, na ordem de EXCHANGES.
  function arrivals_by_connector(comp, c, origin) result(list)
    character(len=*),   intent(in) :: comp
    type(cpl_config_t), intent(in) :: c
    character(len=*),   intent(in) :: origin
    character(len=24), allocatable :: list(:)
    integer :: i

    allocate(list(0))
    do i = 1, size(EXCHANGES)
      if (EXCHANGES(i)%via /= 'conector' .or. .not. cpl_exchange_applies(EXCHANGES(i), c)) cycle
      if (cpl_point_component(EXCHANGES(i)%dst) /= comp) cycle
      if (cpl_point_component(EXCHANGES(i)%src) /= origin) cycle
      list = [character(len=24) :: list, EXCHANGES(i)%field]
    end do
  end function arrivals_by_connector

  !> Campos que passam de MED@atm_med a MED@ocn_med, na ordem de EXCHANGES.
  function atm_med_to_ocn_med() result(list)
    character(len=24), allocatable :: list(:)
    integer :: i

    allocate(list(0))
    do i = 1, size(EXCHANGES)
      if (EXCHANGES(i)%src == 'MED@atm_med' .and. EXCHANGES(i)%dst == 'MED@ocn_med') &
        list = [character(len=24) :: list, EXCHANGES(i)%field]
    end do
  end function atm_med_to_ocn_med

  !> Todo nome de export_names parte do mediador por conector em alguma
  !! configuração, e nenhum outro nome parte por conector.
  logical function all_exported() result(ok)
    integer :: i

    ok = .true.
    do i = 1, size(export_names)
      if (.not. any(EXCHANGES%field == export_names(i) .and. EXCHANGES%src == 'MED@ocn_med' .and. &
                    EXCHANGES%via == 'conector')) then
        ok = .false.
        call fail_at('exportado sem conector: '//trim(export_names(i)))
      end if
    end do
    do i = 1, size(EXCHANGES)
      if (EXCHANGES(i)%src /= 'MED@ocn_med' .or. EXCHANGES(i)%via /= 'conector') cycle
      if (.not. any(export_names == EXCHANGES(i)%field)) then
        ok = .false.
        call fail_at('conector do mediador com campo nao exportado: '//describe(i))
      end if
    end do
  end function all_exported

  !> Campos de EXPORTS no ponto, na ordem da tabela.
  function exported(point) result(list)
    character(len=*), intent(in) :: point
    character(len=24), allocatable :: list(:)
    integer :: i

    allocate(list(0))
    do i = 1, size(EXPORTS)
      if (EXPORTS(i)%point == point) list = [character(len=24) :: list, EXPORTS(i)%field]
    end do
  end function exported

  !> A linha j de EXPORTS vale na configuração c.
  logical function export_applies(j, c)
    integer,            intent(in) :: j
    type(cpl_config_t), intent(in) :: c
    type(cpl_exchange_t) :: t

    t%when = EXPORTS(j)%when
    export_applies = cpl_exchange_applies(t, c)
  end function export_applies

  function describe_exp(i) result(txt)
    integer, intent(in) :: i
    character(len=:), allocatable :: txt
    txt = trim(EXPORTS(i)%field)//' '//trim(EXPORTS(i)%point)// &
          ' ("'//trim(EXPORTS(i)%when)//'")'
  end function describe_exp

  logical function same_list(a, b) result(ok)
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
  end function same_list

  logical function valid_point(point)
    character(len=*), intent(in) :: point
    integer :: km

    km = cpl_grid_index(cpl_point_grid(point))
    valid_point = km > 0
    if (valid_point) valid_point = GRIDS(km)%component == cpl_point_component(point)
  end function valid_point

  logical function mediator_grid(name)
    character(len=*), intent(in) :: name
    integer :: km

    km = cpl_grid_index(name)
    mediator_grid = km > 0
    if (mediator_grid) mediator_grid = GRIDS(km)%component == 'MED'
  end function mediator_grid

  function describe(i) result(txt)
    integer, intent(in) :: i
    character(len=:), allocatable :: txt
    txt = trim(EXCHANGES(i)%field)//' '//trim(EXCHANGES(i)%src)//' -> '//trim(EXCHANGES(i)%dst)// &
          ' ('//trim(EXCHANGES(i)%via)//', "'//trim(EXCHANGES(i)%when)//'")'
  end function describe

  subroutine fail_at(msg)
    character(len=*), intent(in) :: msg
    write(*, '(2A)') '        ', msg
  end subroutine fail_at

  subroutine outcome(name, ok)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: ok
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', name
    else
      write(*, '(2A)') 'FALHOU  ', name
      nfailures = nfailures + 1
    end if
  end subroutine outcome

end program test_cpl_map
