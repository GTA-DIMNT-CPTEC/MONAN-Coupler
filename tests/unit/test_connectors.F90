!> @file test_connectors.F90
!! @brief Conectores que o driver registra, escolhidos pelo mapa de acoplamento.
!!
!! Desde a R-FASE11-21, o driver (esm.F90) registra os conectores que o mapa
!! tem na configuração atual (cpl_driver_connectors, em cpl_map), na
!! ordem de CONNECTOR_SRC/CONNECTOR_DST. Até a R-FASE11-20 (tag
!! fase11-20-validada), a escolha era feita por condições sobre as chaves
!! de configuração, copiadas sem mudança em connectors_before, abaixo:
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
program test_connectors
  use cpl_map_mod, only : cpl_config_t, cpl_config_is_valid, cpl_driver_connectors, &
                          N_CONNECTORS, CONNECTOR_SRC, CONNECTOR_DST
  implicit none

  type(cpl_config_t) :: cfg
  integer :: nfailures, ia, io, im, is, n, t_unlisted, n_before, k, ncases
  integer :: order(N_CONNECTORS), before(N_CONNECTORS)
  character(len=80) :: name
  logical :: ok

  nfailures = 0
  ncases  = 0
  do ia = 0, 1
    do io = 0, 1
      do im = 0, 1
        do is = 0, 1
          cfg%datm        = ia == 1
          cfg%docn        = io == 1
          cfg%med_to_mpas = im == 1
          cfg%sis2        = is == 1
          if (.not. cpl_config_is_valid(cfg)) cycle
          ncases = ncases + 1
          call cpl_driver_connectors(cfg, order, n, t_unlisted)
          call connectors_before(cfg, before, n_before)
          ok = n == n_before .and. t_unlisted == 0
          if (ok) ok = all(order(1:n) == before(1:n))
          write(name, '(4(A,L1))') 'datm=', cfg%datm, ' docn=', cfg%docn, &
            ' med_to_mpas=', cfg%med_to_mpas, ' sis2=', cfg%sis2
          call outcome(trim(name)//': conectores iguais aos de antes', ok)
          if (.not. ok) then
            write(*, '(A,7(1X,A))') '   pelo mapa:', &
              (CONNECTOR_SRC(order(k))//'->'//CONNECTOR_DST(order(k)), k = 1, n)
            write(*, '(A,7(1X,A))') '   antes:    ', &
              (CONNECTOR_SRC(before(k))//'->'//CONNECTOR_DST(before(k)), k = 1, n_before)
          end if
        end do
      end do
    end do
  end do
  call outcome('todas as configuracoes validas conferidas (12)', ncases == 12)

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> A escolha de antes (esm.F90 até a tag fase11-20-validada), em índices
  !! de CONNECTOR_SRC/CONNECTOR_DST.
  subroutine connectors_before(cfg, list, n)
    type(cpl_config_t), intent(in)  :: cfg
    integer,            intent(out) :: list(N_CONNECTORS), n

    list = 0
    n = 0
    call put_connector('ATM', 'MED', list, n)
    call put_connector('OCN', 'MED', list, n)
    call put_connector('MED', 'OCN', list, n)
    if (cfg%med_to_mpas) then
      call put_connector('MED', 'ATM', list, n)
    else
      call put_connector('OCN', 'ATM', list, n)
    end if
    if (cfg%sis2) then
      call put_connector('MED', 'ICE', list, n)
      call put_connector('ICE', 'MED', list, n)
    end if
  end subroutine connectors_before

  !> Acrescenta à lista o índice do par (de, para) em CONNECTOR_SRC/PARA, ou
  !! -1 se o par não está na lista do driver (a comparação então falha).
  subroutine put_connector(src, dst, list, n)
    character(len=*), intent(in)    :: src, dst
    integer,          intent(inout) :: list(N_CONNECTORS), n
    integer :: k
    n = n + 1
    list(n) = -1
    do k = 1, N_CONNECTORS
      if (CONNECTOR_SRC(k) == src .and. CONNECTOR_DST(k) == dst) then
        list(n) = k
        return
      end if
    end do
  end subroutine put_connector

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

end program test_connectors
