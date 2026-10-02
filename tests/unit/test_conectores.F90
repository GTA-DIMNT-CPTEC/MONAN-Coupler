!> @file test_conectores.F90
!! @brief Conectores que o driver registra, escolhidos pelo mapa de acoplamento.
!!
!! Desde a R-FASE11-21, o driver (esm.F90) registra os conectores que o mapa
!! tem na configuração atual (cpl_conectores_do_driver, em cpl_map), na
!! ordem de CONECTOR_DE/CONECTOR_PARA. Até a R-FASE11-20 (tag
!! fase11-20-validada), a escolha era feita por condições sobre as chaves
!! de configuração, copiadas sem mudança em conectores_de_antes, abaixo:
!!
!!   sempre:          MPAS->MED, OCN->MED, MED->OCN
!!   use_med_to_mpas: MED->MPAS; senão, OCN->MPAS
!!   SIS2:            MED->ICE, ICE->MED
!!
!! O teste confere, em todas as configurações válidas do mapa (com o DATM
!! ou o MONAN-A, o DOCN ou o MOM6, com ou sem o contorno pelo mediador e o
!! SIS2), que a escolha pelo mapa dá os mesmos conectores, na mesma ordem,
!! e que nenhum conector do mapa fica sem lugar na lista do driver.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_conectores
  use cpl_map_mod, only : cpl_config_t, cpl_config_valida, cpl_conectores_do_driver, &
                          N_CONECTORES, CONECTOR_DE, CONECTOR_PARA
  implicit none

  type(cpl_config_t) :: cfg
  integer :: nfalhas, ia, io, im, is, n, t_fora, n_antes, k, ncasos
  integer :: ordem(N_CONECTORES), antes(N_CONECTORES)
  character(len=80) :: nome
  logical :: ok

  nfalhas = 0
  ncasos  = 0
  do ia = 0, 1
    do io = 0, 1
      do im = 0, 1
        do is = 0, 1
          cfg%datm        = ia == 1
          cfg%docn        = io == 1
          cfg%med_to_mpas = im == 1
          cfg%sis2        = is == 1
          if (.not. cpl_config_valida(cfg)) cycle
          ncasos = ncasos + 1
          call cpl_conectores_do_driver(cfg, ordem, n, t_fora)
          call conectores_de_antes(cfg, antes, n_antes)
          ok = n == n_antes .and. t_fora == 0
          if (ok) ok = all(ordem(1:n) == antes(1:n))
          write(nome, '(4(A,L1))') 'datm=', cfg%datm, ' docn=', cfg%docn, &
            ' med_to_mpas=', cfg%med_to_mpas, ' sis2=', cfg%sis2
          call resultado(trim(nome)//': conectores iguais aos de antes', ok)
          if (.not. ok) then
            write(*, '(A,7(1X,A))') '   pelo mapa:', &
              (CONECTOR_DE(ordem(k))//'->'//CONECTOR_PARA(ordem(k)), k = 1, n)
            write(*, '(A,7(1X,A))') '   antes:    ', &
              (CONECTOR_DE(antes(k))//'->'//CONECTOR_PARA(antes(k)), k = 1, n_antes)
          end if
        end do
      end do
    end do
  end do
  call resultado('todas as configuracoes validas conferidas (12)', ncasos == 12)

  if (nfalhas == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfalhas, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> A escolha de antes (esm.F90 até a tag fase11-20-validada), em índices
  !! de CONECTOR_DE/CONECTOR_PARA.
  subroutine conectores_de_antes(cfg, lista, n)
    type(cpl_config_t), intent(in)  :: cfg
    integer,            intent(out) :: lista(N_CONECTORES), n

    lista = 0
    n = 0
    call poe('ATM', 'MED', lista, n)
    call poe('OCN', 'MED', lista, n)
    call poe('MED', 'OCN', lista, n)
    if (cfg%med_to_mpas) then
      call poe('MED', 'ATM', lista, n)
    else
      call poe('OCN', 'ATM', lista, n)
    end if
    if (cfg%sis2) then
      call poe('MED', 'ICE', lista, n)
      call poe('ICE', 'MED', lista, n)
    end if
  end subroutine conectores_de_antes

  !> Acrescenta à lista o índice do par (de, para) em CONECTOR_DE/PARA, ou
  !! -1 se o par não está na lista do driver (a comparação então falha).
  subroutine poe(de, para, lista, n)
    character(len=*), intent(in)    :: de, para
    integer,          intent(inout) :: lista(N_CONECTORES), n
    integer :: k
    n = n + 1
    lista(n) = -1
    do k = 1, N_CONECTORES
      if (CONECTOR_DE(k) == de .and. CONECTOR_PARA(k) == para) then
        lista(n) = k
        return
      end if
    end do
  end subroutine poe

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

end program test_conectores
