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
!!                    a R-FASE11-25, lacunas conhecidas (tabela GAPS),
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
  use cpl_map_mod,       only : cpl_config_t, cpl_config_is_valid, cpl_driver_connectors, &
                                cpl_arrivals, cpl_exports, cpl_is_gap, GAPS, &
                                N_CONNECTORS, CONNECTOR_SRC, CONNECTOR_DST
  use cpl_fields_mod,    only : CPL_NAME_LEN
  use cpl_check_mod,     only : cpl_check_connector_fields, cpl_check_state, CPL_MSG_LEN, &
                                cpl_check_methods, cpl_method_of_entry
  implicit none

  include 'listas_mediador.inc'

  type(cpl_config_t), parameter :: PRODUCTION = cpl_config_t(datm=.false., docn=.false., &
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
  integer :: nfailures, ndif, nwarn, k

  nfailures = 0
  med_imp = [character(len=32) :: import_mpas_names, MED_IMP_OCN, ICE_EXP]

  ! --- produção: nenhuma diferença ------------------------------------------
  call reset_counts()
  call production_states(med_imp, export_names, OCN_IMP)
  call production_connectors(import_mpas_names)
  call outcome('producao: nenhuma diferenca', ndif == 0)
  call outcome('producao: tres avisos (So_s, Fioo_q e Si_ifrac do MOM6)', nwarn == 3)

  ! --- conector com um campo a menos e um a mais ------------------------------
  call reset_counts()
  call cpl_check_connector_fields(PRODUCTION, 'ATM', 'MED', import_mpas_names(2:), msgs, ndif)
  call outcome('conector: campo a menos', ndif == 1 .and. has_item('Sa_u10m_mpas'))
  call reset_counts()
  call cpl_check_connector_fields(PRODUCTION, 'OCN', 'MED', [character(len=24) :: MED_IMP_OCN, 'So_s'], &
                            msgs, ndif)
  call outcome('conector: campo a mais', ndif == 1 .and. has_item('So_s'))

  ! --- importação ---------------------------------------------------------------
  call reset_counts()
  call cpl_check_state(PRODUCTION, 'OCN', .true., [character(len=24) :: OCN_IMP, 'So_teste'], &
                          msgs, ndif, nwarn)
  call outcome('importacao: campo fora do mapa e do dicionario', ndif == 2 .and. has_item('So_teste'))
  call reset_counts()
  call cpl_check_state(PRODUCTION, 'MED', .true., med_imp(1:size(med_imp)-1), msgs, ndif, nwarn)
  call outcome('importacao: campo previsto e nao anunciado', ndif == 1 .and. has_item('Si_t_sis2'))

  ! --- exportação ---------------------------------------------------------------
  call reset_counts()
  call cpl_check_state(PRODUCTION, 'MED', .false., pack(export_names, export_names /= 'Faxa_coszen'), &
                          msgs, ndif, nwarn)
  call outcome('exportacao: campo previsto e nao exportado', ndif == 1 .and. has_item('Faxa_coszen'))

  ! --- MONAN-A com DOCN: lacuna conhecida ---------------------------------------
  call reset_counts()
  call cpl_check_state(MPAS_DOCN, 'ATM', .true., ATM_IMP, msgs, ndif, nwarn)
  call outcome('mpas_docn: Sx_tsfc, Sf_albedo e Sx_omask sao lacunas conhecidas (avisos)', &
                 ndif == 0 .and. nwarn == 3 .and. has_item('Sx_tsfc') .and. has_item('Sf_albedo') &
                 .and. has_item('Sx_omask'))

  ! --- as doze configurações válidas, como na rodada --------------------------
  call check_configurations()

  ! --- método de cada campo (remapmethod) ---------------------------------------
  call reset_counts()
  call cpl_check_methods('MED', 'ICE', ICE_IMP, [character(len=16) :: ('bilinear', k = 1, 16)], &
                           msgs, ndif)
  call outcome('metodo: MED -> ICE com bilinear em todos, nenhuma diferenca', ndif == 0)
  call reset_counts()
  call cpl_check_methods('OCN', 'MED', MED_IMP_OCN, &
                           [character(len=16) :: 'bilinear', '', 'bilinear', 'bilinear'], msgs, ndif)
  call outcome('metodo: campo sem remapmethod', ndif == 1 .and. has_item(trim(MED_IMP_OCN(2))))
  call reset_counts()
  call cpl_check_methods('OCN', 'MED', MED_IMP_OCN, &
                           [character(len=16) :: 'bilinear', 'bilinear', 'patch', 'bilinear'], msgs, ndif)
  call outcome('metodo: campo com outro metodo', ndif == 1 .and. has_item(trim(MED_IMP_OCN(3))))
  call reset_counts()
  call cpl_check_methods('OCN', 'MED', [character(len=24) :: 'So_s'], [character(len=16) :: ''], &
                           msgs, ndif)
  call outcome('metodo: campo sem troca no mapa nao e conferido aqui', ndif == 0)
  call outcome('metodo: leitura da opcao na entrada', &
    cpl_method_of_entry('So_t:termorder=srcseq:srcTermProcessing=0:remapmethod=bilinear') == 'bilinear' &
    .and. cpl_method_of_entry('So_t:remapmethod=patch:termorder=srcseq') == 'patch' &
    .and. len_trim(cpl_method_of_entry('So_t:termorder=srcseq')) == 0 &
    .and. len_trim(cpl_method_of_entry('So_t')) == 0)

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Em cada configuração válida, monta os estados como os caps os anunciam
  !! (pelo mapa, com as chaves de cada um) e a CplList de cada conector que o
  !! driver registra (os campos importados pelo destino que a origem
  !! exporta), e confere tudo com cpl_check_connector_fields e cpl_check_state.
  subroutine check_configurations()
    type(cpl_config_t) :: c
    character(len=3), parameter :: COMPS(4) = ['ATM', 'MED', 'OCN', 'ICE']
    character(len=CPL_NAME_LEN), allocatable :: imp(:,:), exp(:,:), list(:), nn(:)
    integer :: nimp(4), nexp(4), order(N_CONNECTORS), n, t_unlisted, ia, io, im, is, k, i, j, l, m
    integer :: ngaps, ngap_warnings
    logical :: ok_without_datm, ok_datm
    character(len=CPL_NAME_LEN) :: ocn

    ok_without_datm = .true.
    ok_datm     = .true.
    allocate(imp(4, 64), exp(4, 64))
    do ia = 0, 1
      do io = 0, 1
        do im = 0, 1
          do is = 0, 1
            c = cpl_config_t(ia == 1, io == 1, im == 1, is == 1)
            if (.not. cpl_config_is_valid(c)) cycle
            ocn = merge('OCN@docn    ', 'OCN@ocn_mom6', c%docn)
            nimp = 0; nexp = 0
            call cpl_arrivals('ATM@atm_cap', .true., c, '', nn);          call store_names(imp, nimp, 1, nn)
            call cpl_exports('ATM@atm_cap', c, '', nn);               call store_names(exp, nexp, 1, nn)
            call cpl_arrivals('MED', .true., c, 'datm,sis2', nn);          call store_names(imp, nimp, 2, nn)
            call cpl_arrivals('MED@ocn_med', .false., c, '', nn);         call store_names(exp, nexp, 2, nn)
            call cpl_arrivals(trim(ocn), .true., c, '', nn);              call store_names(imp, nimp, 3, nn)
            call cpl_exports(trim(ocn), c, '', nn);                   call store_names(exp, nexp, 3, nn)
            if (c%sis2) then
              call cpl_arrivals('ICE@ice_sis2', .true., c, '', nn);       call store_names(imp, nimp, 4, nn)
              call cpl_exports('ICE@ice_sis2', c, '', nn);            call store_names(exp, nexp, 4, nn)
            end if
            call reset_counts()
            call cpl_driver_connectors(c, order, n, t_unlisted)
            do k = 1, n
              i = findloc(COMPS, CONNECTOR_SRC(order(k)), 1)
              j = findloc(COMPS, CONNECTOR_DST(order(k)), 1)
              allocate(list(0))
              do l = 1, nimp(j)
                if (any(exp(i, 1:nexp(i)) == imp(j, l))) &
                  list = [character(len=CPL_NAME_LEN) :: list, imp(j, l)]
              end do
              call cpl_check_connector_fields(c, COMPS(i), COMPS(j), list, msgs, ndif)
              deallocate(list)
            end do
            do i = 1, 4
              if (i == 4 .and. .not. c%sis2) cycle
              call cpl_check_state(c, COMPS(i), .true.,     imp(i, 1:nimp(i)), msgs, ndif, nwarn)
              call cpl_check_state(c, COMPS(i), .false., exp(i, 1:nexp(i)), msgs, ndif, nwarn)
            end do
            ngaps = 0
            do l = 1, size(GAPS)
              if (cpl_is_gap(c, GAPS(l)%field, GAPS(l)%point)) ngaps = ngaps + 1
            end do
            ngap_warnings = 0
            do m = 1, size(msgs)
              if (index(msgs(m), 'AVISO: lacuna conhecida') > 0) ngap_warnings = ngap_warnings + 1
            end do
            if (c%datm) then
              ok_datm = ok_datm .and. ndif > 0
            else
              if (ndif /= 0 .or. ngap_warnings /= ngaps) then
                write(*, '(4(A,L1),2(A,I0))') '   datm=', c%datm, ' docn=', c%docn, &
                  ' med_to_mpas=', c%med_to_mpas, ' sis2=', c%sis2, ': diferencas ', ndif, &
                  ', lacunas avisadas ', ngap_warnings
              end if
              ok_without_datm = ok_without_datm .and. ndif == 0 .and. ngap_warnings == ngaps
            end if
          end do
        end do
      end do
    end do
    call reset_counts()
    call outcome('configuracoes sem o DATM: nenhuma diferenca; cada lacuna aparece como aviso', &
                   ok_without_datm)
    call outcome('configuracoes com o DATM (nao registrado pelo driver): ha diferencas', ok_datm)
  end subroutine check_configurations

  !> Guarda a lista nn na linha k de tab.
  subroutine store_names(tab, ntab, k, nn)
    character(len=*), intent(inout) :: tab(:,:)
    integer,          intent(inout) :: ntab(:)
    integer,          intent(in)    :: k
    character(len=*), intent(in)    :: nn(:)
    ntab(k) = size(nn)
    tab(k, 1:size(nn)) = nn
  end subroutine store_names

  !> Estados dos quatro componentes na produção.
  subroutine production_states(med_i, med_e, ocn_i)
    character(len=*), intent(in) :: med_i(:), med_e(:), ocn_i(:)

    call cpl_check_state(PRODUCTION, 'ATM', .true.,  ATM_IMP,           msgs, ndif, nwarn)
    call cpl_check_state(PRODUCTION, 'ATM', .false., import_mpas_names, msgs, ndif, nwarn)
    call cpl_check_state(PRODUCTION, 'MED', .true.,  med_i,             msgs, ndif, nwarn)
    call cpl_check_state(PRODUCTION, 'MED', .false., med_e,             msgs, ndif, nwarn)
    call cpl_check_state(PRODUCTION, 'OCN', .true.,  ocn_i,             msgs, ndif, nwarn)
    call cpl_check_state(PRODUCTION, 'OCN', .false., OCN_EXP,           msgs, ndif, nwarn)
    call cpl_check_state(PRODUCTION, 'ICE', .true.,  ICE_IMP,           msgs, ndif, nwarn)
    call cpl_check_state(PRODUCTION, 'ICE', .false., ICE_EXP,           msgs, ndif, nwarn)
  end subroutine production_states

  !> CplList de cada conector na produção: exportação da origem que a
  !! importação do destino anuncia.
  subroutine production_connectors(atm_e)
    character(len=*), intent(in) :: atm_e(:)

    call cpl_check_connector_fields(PRODUCTION, 'ATM', 'MED', atm_e,       msgs, ndif)
    call cpl_check_connector_fields(PRODUCTION, 'OCN', 'MED', MED_IMP_OCN, msgs, ndif)
    call cpl_check_connector_fields(PRODUCTION, 'ICE', 'MED', ICE_EXP,     msgs, ndif)
    call cpl_check_connector_fields(PRODUCTION, 'MED', 'OCN', OCN_IMP,     msgs, ndif)
    call cpl_check_connector_fields(PRODUCTION, 'MED', 'ICE', ICE_IMP,     msgs, ndif)
    call cpl_check_connector_fields(PRODUCTION, 'MED', 'ATM', ATM_IMP,     msgs, ndif)
  end subroutine production_connectors

  subroutine reset_counts()
    if (allocated(msgs)) deallocate(msgs)
    allocate(msgs(0))
    ndif = 0; nwarn = 0
  end subroutine reset_counts

  !> Alguma mensagem acumulada cita o nome.
  logical function has_item(name)
    character(len=*), intent(in) :: name
    integer :: i
    has_item = .false.
    do i = 1, size(msgs)
      if (index(msgs(i), ' '//name//',') > 0 .or. index(msgs(i), ' '//name//' ') > 0) has_item = .true.
    end do
  end function has_item

  subroutine outcome(name, ok)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: ok
    integer :: i
    if (ok) then
      write(*, '(2A)') 'PASSOU  ', name
    else
      write(*, '(2A)') 'FALHOU  ', name
      do i = 1, size(msgs)
        write(*, '(2A)') '        ', trim(msgs(i))
      end do
      nfailures = nfailures + 1
    end if
  end subroutine outcome

end program test_cpl_check
