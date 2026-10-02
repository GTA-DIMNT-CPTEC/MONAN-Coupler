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
!!                    importa Sx_tsfc, Sf_albedo e Sx_omask sem origem (a
!!                    lacuna conhecida aparece como três diferenças)
!!   metodo           remapmethod de cada entrada da CplList contra o método
!!                    do mapa (R-FASE11-22): igual, ausente, outro método e
!!                    campo sem troca; leitura da opção numa entrada
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_cpl_check
  use cpl_map_mod,       only : cpl_config_t
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
  call resultado('mpas_docn: Sx_tsfc, Sf_albedo e Sx_omask sem origem', &
                 ndif == 3 .and. contem('Sx_tsfc') .and. contem('Sf_albedo') .and. contem('Sx_omask'))

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
