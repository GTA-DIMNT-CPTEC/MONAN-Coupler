!> @file test_cpl_check.F90
!! @brief Conferência do mapa de acoplamento contra listas de campos (cpl_check).
!!
!! Confere, sem MPI e sem ESMF inicializado, as duas rotinas de conferência
!! de cpl_check_mod com as listas que os componentes anunciam hoje, escritas
!! aqui a partir dos caps (não do mapa), e com defeitos de propósito:
!!
!!   producao         listas de hoje na configuração de produção: nenhuma
!!                    diferença; três avisos (o MOM6 exporta So_s, Fioo_q e
!!                    Si_ifrac, que ninguém consome)
!!   conector         CplList sem um campo e com um campo a mais
!!   importacao       campo importado fora do mapa e do dicionário; campo
!!                    previsto pelo mapa que o componente não anuncia
!!   exportacao       campo previsto pelo mapa que o mediador não exporta
!!   mpas_docn        com o DOCN e o contorno direto do oceano, o MONAN-A
!!                    importa Sx_tsfc, Sf_albedo e Sx_omask sem origem: desde
!!                    a R-FASE11-25, lacunas conhecidas (tabela LACUNAS),
!!                    três avisos e nenhuma diferença
!!   configuracoes    nas doze configurações válidas, os estados e as CplList
!!                    que os caps e os conectores montam a partir do mapa (como
!!                    na rodada): sem o DATM, nenhuma diferença, e cada lacuna
!!                    da configuração aparece como aviso; com o DATM, que o
!!                    driver não registra, há diferenças, e a rodada para
!!   metodo           remapmethod de cada entrada da CplList contra o método
!!                    do mapa (R-FASE11-22): igual, ausente, outro método e
!!                    campo sem troca; leitura da opção numa entrada
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_cpl_check
  use cpl_map_mod,       only : cpl_config_t, cpl_config_valida, cpl_conectores_do_driver, &
                                cpl_chegadas, cpl_exportacoes, cpl_lacuna, LACUNAS, &
                                N_CONECTORES, CONECTOR_DE, CONECTOR_PARA
  use cpl_fields_mod,    only : CPL_NOME_LEN
  use cpl_check_mod,     only : cpl_confere_conector, cpl_confere_estado, CPL_MSG_LEN, &
                                cpl_confere_metodos, cpl_metodo_da_entrada
  implicit none

  include 'listas_mediador.inc'

  type(cpl_config_t), parameter :: PRODUCAO  = cpl_config_t(datm=.false., docn=.false., &
                                                            med_to_mpas=.true., sis2=.true.)
  type(cpl_config_t), parameter :: MPAS_DOCN = cpl_config_t(datm=.false., docn=.true.,  &
                                                            med_to_mpas=.false., sis2=.false.)

  ! Listas anunciadas pelos caps (mpas_cap_MONAN, mom_cap_MONAN, sis_cap_MONAN, MED_cap)
  character(len=24), parameter :: ATM_IMP(7) = [character(len=24) :: &
    'Sx_tsfc', 'Si_ifrac', 'So_u', 'So_v', 'Sf_zorl', 'Sf_albedo', 'Sx_omask']
  character(len=24), parameter :: OCN_IMP(14) = [character(len=24) :: &
    'Foxx_taux', 'Foxx_tauy', 'Foxx_sen', 'Foxx_evap', 'Foxx_lwnet', 'Foxx_swnet_vdr', &
    'Foxx_swnet_vdf', 'Foxx_swnet_idr', 'Foxx_swnet_idf', 'Faxa_rain', 'Faxa_snow', 'Sa_pslv', &
    'Si_ifrac', 'So_duu10n']
  character(len=24), parameter :: OCN_EXP(7) = [character(len=24) :: &
    'So_t', 'So_s', 'So_u', 'So_v', 'So_omask', 'Fioo_q', 'Si_ifrac']
  character(len=24), parameter :: ICE_IMP(16) = [character(len=24) :: &
    'Fioi_taux', 'Fioi_tauy', 'Fioi_sen', 'Fioi_evap', 'Fioi_lwnet', 'Fioi_swnet_vdr', &
    'Fioi_swnet_vdf', 'Fioi_swnet_idr', 'Fioi_swnet_idf', 'Faxa_rain', 'Faxa_snow', 'Sa_pslv', &
    'Faxa_coszen', 'So_t', 'So_u', 'So_v']
  character(len=24), parameter :: ICE_EXP(6) = [character(len=24) :: &
    'Si_ifrac_sis2', 'Si_avsdr_sis2', 'Si_avsdf_sis2', 'Si_anidr_sis2', 'Si_anidf_sis2', 'Si_t_sis2']

  character(len=CPL_MSG_LEN), allocatable :: msgs(:)
  character(len=32), allocatable :: med_imp(:)
  integer :: nfalhas, ndif, naviso, k

  nfalhas = 0
  med_imp = [character(len=32) :: import_mpas_names, MED_IMP_OCN, ICE_EXP]

  ! --- produção: nenhuma diferença ------------------------------------------
  call zera()
  call estados_producao(med_imp, export_names, OCN_IMP)
  call conectores_producao(import_mpas_names)
  call resultado('producao: nenhuma diferenca', ndif == 0)
  call resultado('producao: tres avisos (So_s, Fioo_q e Si_ifrac do MOM6)', naviso == 3)

  ! --- conector com um campo a menos e um a mais ------------------------------
  call zera()
  call cpl_confere_conector(PRODUCAO, 'ATM', 'MED', import_mpas_names(2:), msgs, ndif)
  call resultado('conector: campo a menos', ndif == 1 .and. contem('Sa_u10m_mpas'))
  call zera()
  call cpl_confere_conector(PRODUCAO, 'OCN', 'MED', [character(len=24) :: MED_IMP_OCN, 'So_s'], &
                            msgs, ndif)
  call resultado('conector: campo a mais', ndif == 1 .and. contem('So_s'))

  ! --- importação ---------------------------------------------------------------
  call zera()
  call cpl_confere_estado(PRODUCAO, 'OCN', .true., [character(len=24) :: OCN_IMP, 'So_teste'], &
                          msgs, ndif, naviso)
  call resultado('importacao: campo fora do mapa e do dicionario', ndif == 2 .and. contem('So_teste'))
  call zera()
  call cpl_confere_estado(PRODUCAO, 'MED', .true., med_imp(1:size(med_imp)-1), msgs, ndif, naviso)
  call resultado('importacao: campo previsto e nao anunciado', ndif == 1 .and. contem('Si_t_sis2'))

  ! --- exportação ---------------------------------------------------------------
  call zera()
  call cpl_confere_estado(PRODUCAO, 'MED', .false., pack(export_names, export_names /= 'Faxa_coszen'), &
                          msgs, ndif, naviso)
  call resultado('exportacao: campo previsto e nao exportado', ndif == 1 .and. contem('Faxa_coszen'))

  ! --- MONAN-A com DOCN: lacuna conhecida ---------------------------------------
  call zera()
  call cpl_confere_estado(MPAS_DOCN, 'ATM', .true., ATM_IMP, msgs, ndif, naviso)
  call resultado('mpas_docn: Sx_tsfc, Sf_albedo e Sx_omask sao lacunas conhecidas (avisos)', &
                 ndif == 0 .and. naviso == 3 .and. contem('Sx_tsfc') .and. contem('Sf_albedo') &
                 .and. contem('Sx_omask'))

  ! --- as doze configurações válidas, como na rodada --------------------------
  call confere_configuracoes()

  ! --- método de cada campo (remapmethod) ---------------------------------------
  call zera()
  call cpl_confere_metodos('MED', 'ICE', ICE_IMP, [character(len=16) :: ('bilinear', k = 1, 16)], &
                           msgs, ndif)
  call resultado('metodo: MED -> ICE com bilinear em todos, nenhuma diferenca', ndif == 0)
  call zera()
  call cpl_confere_metodos('OCN', 'MED', MED_IMP_OCN, &
                           [character(len=16) :: 'bilinear', '', 'bilinear', 'bilinear'], msgs, ndif)
  call resultado('metodo: campo sem remapmethod', ndif == 1 .and. contem(trim(MED_IMP_OCN(2))))
  call zera()
  call cpl_confere_metodos('OCN', 'MED', MED_IMP_OCN, &
                           [character(len=16) :: 'bilinear', 'bilinear', 'patch', 'bilinear'], msgs, ndif)
  call resultado('metodo: campo com outro metodo', ndif == 1 .and. contem(trim(MED_IMP_OCN(3))))
  call zera()
  call cpl_confere_metodos('OCN', 'MED', [character(len=24) :: 'So_s'], [character(len=16) :: ''], &
                           msgs, ndif)
  call resultado('metodo: campo sem troca no mapa nao e conferido aqui', ndif == 0)
  call resultado('metodo: leitura da opcao na entrada', &
    cpl_metodo_da_entrada('So_t:termorder=srcseq:srcTermProcessing=0:remapmethod=bilinear') == 'bilinear' &
    .and. cpl_metodo_da_entrada('So_t:remapmethod=patch:termorder=srcseq') == 'patch' &
    .and. len_trim(cpl_metodo_da_entrada('So_t:termorder=srcseq')) == 0 &
    .and. len_trim(cpl_metodo_da_entrada('So_t')) == 0)

  if (nfalhas == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfalhas, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Em cada configuração válida, monta os estados como os caps os anunciam
  !! (pelo mapa, com as chaves de cada um) e a CplList de cada conector que o
  !! driver registra (os campos importados pelo destino que a origem
  !! exporta), e confere tudo com cpl_confere_conector e cpl_confere_estado.
  subroutine confere_configuracoes()
    type(cpl_config_t) :: c
    character(len=3), parameter :: COMPS(4) = ['ATM', 'MED', 'OCN', 'ICE']
    character(len=CPL_NOME_LEN), allocatable :: imp(:,:), exp(:,:), lista(:), nn(:)
    integer :: nimp(4), nexp(4), ordem(N_CONECTORES), n, t_fora, ia, io, im, is, k, i, j, l, m
    integer :: nlac, nlac_aviso
    logical :: ok_sem_datm, ok_datm
    character(len=CPL_NOME_LEN) :: ocn

    ok_sem_datm = .true.
    ok_datm     = .true.
    allocate(imp(4, 64), exp(4, 64))
    do ia = 0, 1
      do io = 0, 1
        do im = 0, 1
          do is = 0, 1
            c = cpl_config_t(ia == 1, io == 1, im == 1, is == 1)
            if (.not. cpl_config_valida(c)) cycle
            ocn = merge('OCN@docn    ', 'OCN@ocn_mom6', c%docn)
            nimp = 0; nexp = 0
            call cpl_chegadas('ATM@atm_cap', .true., c, '', nn);          call guarda(imp, nimp, 1, nn)
            call cpl_exportacoes('ATM@atm_cap', c, '', nn);               call guarda(exp, nexp, 1, nn)
            call cpl_chegadas('MED', .true., c, 'datm,sis2', nn);          call guarda(imp, nimp, 2, nn)
            call cpl_chegadas('MED@ocn_med', .false., c, '', nn);         call guarda(exp, nexp, 2, nn)
            call cpl_chegadas(trim(ocn), .true., c, '', nn);              call guarda(imp, nimp, 3, nn)
            call cpl_exportacoes(trim(ocn), c, '', nn);                   call guarda(exp, nexp, 3, nn)
            if (c%sis2) then
              call cpl_chegadas('ICE@ice_sis2', .true., c, '', nn);       call guarda(imp, nimp, 4, nn)
              call cpl_exportacoes('ICE@ice_sis2', c, '', nn);            call guarda(exp, nexp, 4, nn)
            end if
            call zera()
            call cpl_conectores_do_driver(c, ordem, n, t_fora)
            do k = 1, n
              i = findloc(COMPS, CONECTOR_DE(ordem(k)), 1)
              j = findloc(COMPS, CONECTOR_PARA(ordem(k)), 1)
              allocate(lista(0))
              do l = 1, nimp(j)
                if (any(exp(i, 1:nexp(i)) == imp(j, l))) &
                  lista = [character(len=CPL_NOME_LEN) :: lista, imp(j, l)]
              end do
              call cpl_confere_conector(c, COMPS(i), COMPS(j), lista, msgs, ndif)
              deallocate(lista)
            end do
            do i = 1, 4
              if (i == 4 .and. .not. c%sis2) cycle
              call cpl_confere_estado(c, COMPS(i), .true.,  imp(i, 1:nimp(i)), msgs, ndif, naviso)
              call cpl_confere_estado(c, COMPS(i), .false., exp(i, 1:nexp(i)), msgs, ndif, naviso)
            end do
            nlac = 0
            do l = 1, size(LACUNAS)
              if (cpl_lacuna(c, LACUNAS(l)%campo, LACUNAS(l)%ponto)) nlac = nlac + 1
            end do
            nlac_aviso = 0
            do m = 1, size(msgs)
              if (index(msgs(m), 'AVISO: lacuna conhecida') > 0) nlac_aviso = nlac_aviso + 1
            end do
            if (c%datm) then
              ok_datm = ok_datm .and. ndif > 0
            else
              if (ndif /= 0 .or. nlac_aviso /= nlac) then
                write(*, '(4(A,L1),2(A,I0))') '   datm=', c%datm, ' docn=', c%docn, &
                  ' med_to_mpas=', c%med_to_mpas, ' sis2=', c%sis2, ': diferencas ', ndif, &
                  ', lacunas avisadas ', nlac_aviso
              end if
              ok_sem_datm = ok_sem_datm .and. ndif == 0 .and. nlac_aviso == nlac
            end if
          end do
        end do
      end do
    end do
    call zera()
    call resultado('configuracoes sem o DATM: nenhuma diferenca; cada lacuna aparece como aviso', &
                   ok_sem_datm)
    call resultado('configuracoes com o DATM (nao registrado pelo driver): ha diferencas', ok_datm)
  end subroutine confere_configuracoes

  !> Guarda a lista nn na linha k de tab.
  subroutine guarda(tab, ntab, k, nn)
    character(len=*), intent(inout) :: tab(:,:)
    integer,          intent(inout) :: ntab(:)
    integer,          intent(in)    :: k
    character(len=*), intent(in)    :: nn(:)
    ntab(k) = size(nn)
    tab(k, 1:size(nn)) = nn
  end subroutine guarda

  !> Estados dos quatro componentes na produção.
  subroutine estados_producao(med_i, med_e, ocn_i)
    character(len=*), intent(in) :: med_i(:), med_e(:), ocn_i(:)

    call cpl_confere_estado(PRODUCAO, 'ATM', .true.,  ATM_IMP,           msgs, ndif, naviso)
    call cpl_confere_estado(PRODUCAO, 'ATM', .false., import_mpas_names, msgs, ndif, naviso)
    call cpl_confere_estado(PRODUCAO, 'MED', .true.,  med_i,             msgs, ndif, naviso)
    call cpl_confere_estado(PRODUCAO, 'MED', .false., med_e,             msgs, ndif, naviso)
    call cpl_confere_estado(PRODUCAO, 'OCN', .true.,  ocn_i,             msgs, ndif, naviso)
    call cpl_confere_estado(PRODUCAO, 'OCN', .false., OCN_EXP,           msgs, ndif, naviso)
    call cpl_confere_estado(PRODUCAO, 'ICE', .true.,  ICE_IMP,           msgs, ndif, naviso)
    call cpl_confere_estado(PRODUCAO, 'ICE', .false., ICE_EXP,           msgs, ndif, naviso)
  end subroutine estados_producao

  !> CplList de cada conector na produção: exportação da origem que a
  !! importação do destino anuncia.
  subroutine conectores_producao(atm_e)
    character(len=*), intent(in) :: atm_e(:)

    call cpl_confere_conector(PRODUCAO, 'ATM', 'MED', atm_e,       msgs, ndif)
    call cpl_confere_conector(PRODUCAO, 'OCN', 'MED', MED_IMP_OCN, msgs, ndif)
    call cpl_confere_conector(PRODUCAO, 'ICE', 'MED', ICE_EXP,     msgs, ndif)
    call cpl_confere_conector(PRODUCAO, 'MED', 'OCN', OCN_IMP,     msgs, ndif)
    call cpl_confere_conector(PRODUCAO, 'MED', 'ICE', ICE_IMP,     msgs, ndif)
    call cpl_confere_conector(PRODUCAO, 'MED', 'ATM', ATM_IMP,     msgs, ndif)
  end subroutine conectores_producao

  subroutine zera()
    if (allocated(msgs)) deallocate(msgs)
    allocate(msgs(0))
    ndif = 0; naviso = 0
  end subroutine zera

  !> Alguma mensagem acumulada cita o nome.
  logical function contem(nome)
    character(len=*), intent(in) :: nome
    integer :: i
    contem = .false.
    do i = 1, size(msgs)
      if (index(msgs(i), ' '//nome//',') > 0 .or. index(msgs(i), ' '//nome//' ') > 0) contem = .true.
    end do
  end function contem

  subroutine resultado(nome, ok)
    character(len=*), intent(in) :: nome
    logical,          intent(in) :: ok
    integer :: i
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', nome
    else
      write(*, '(2A)') 'FALHOU  ', nome
      do i = 1, size(msgs)
        write(*, '(2A)') '        ', trim(msgs(i))
      end do
      nfalhas = nfalhas + 1
    end if
  end subroutine resultado

end program test_cpl_check
