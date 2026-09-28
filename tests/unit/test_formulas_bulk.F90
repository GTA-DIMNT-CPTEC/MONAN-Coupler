!> @file test_formulas_bulk.F90
!! @brief Testes com valor esperado das fórmulas da física bulk do mediador.
!!
!! Os testes de regressão de tests/bulk comparam duas versões do código e
!! respondem "o resultado mudou?". Estes respondem outra pergunta: "o código
!! calcula o que a fórmula publicada diz?". Cada caso compara o resultado de
!! uma função de med_bulk_ncar_mod com um valor esperado calculado à parte,
!! em precisão de 40 algarismos (mpmath), diretamente da fórmula publicada:
!!
!!   ice_temp_eff         temperatura do gelo usada nos fluxos: Si_t_sis2
!!                        na faixa (180 K; 273,16 K], senão 271,35 K
!!   louis_stability      número de Richardson bulk
!!                        Ri = g z (Ta - Ts) / (max(Ta, 100) |V|^2)
!!                        e fator de estabilidade de Louis (1979), com
!!                        b = c = 5, piso 0,05 e teto 3
!!   ocean_direct_albedo  cosseno do zênite na célula (i, j) da grade ATM
!!                        360 x 180 e albedo da água para feixe direto,
!!                        Briegleb et al. (1986):
!!                        a = 0,026 / (mu^1,7 + 0,065)
!!                            + 0,15 (mu - 0,1)(mu - 0,5)(mu - 1),
!!                        com mu >= 0,02 e a limitado a [0,03; 0,99]
!!
!! A tolerância relativa é 1e-12: a ordem das operações de ponto flutuante
!! no código não é a mesma do cálculo de referência, e o PI do código tem 15
!! algarismos. Um erro de fórmula (troca de sinal, de constante ou de ramo)
!! muda o resultado muito além disso.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_formulas_bulk
  use ESMF, only: ESMF_KIND_R8
  use med_bulk_ncar_mod, only: ice_temp_eff, louis_stability, ocean_direct_albedo
  implicit none

  integer, parameter :: R8 = ESMF_KIND_R8
  real(R8), parameter :: TOL = 1.0e-12_R8
  integer :: nfalhas
  real(R8) :: rib, fator, coszen, albedo

  nfalhas = 0

  ! --- ice_temp_eff -------------------------------------------------------
  call confere('ice_temp_eff: 250 K fica', ice_temp_eff(250.0_R8), 250.0_R8)
  call confere('ice_temp_eff: 180 K (fora) vira 271,35 K', ice_temp_eff(180.0_R8), 271.35_R8)
  call confere('ice_temp_eff: 180,0001 K fica', ice_temp_eff(180.0001_R8), 180.0001_R8)
  call confere('ice_temp_eff: 273,16 K (limite) fica', ice_temp_eff(273.16_R8), 273.16_R8)
  call confere('ice_temp_eff: 273,17 K (fora) vira 271,35 K', ice_temp_eff(273.17_R8), 271.35_R8)
  call confere('ice_temp_eff: 300 K (fora) vira 271,35 K', ice_temp_eff(300.0_R8), 271.35_R8)

  ! --- louis_stability ----------------------------------------------------
  call louis_stability(260.0_R8, 250.0_R8, 5.0_R8, rib, fator)
  call confere('louis: estável, Ri', rib, 0.15092307692307692308_R8)
  call confere('louis: estável, fator', fator, 0.46742738170511006766_R8)
  call louis_stability(260.0_R8, 260.0_R8, 5.0_R8, rib, fator)
  call confere('louis: neutro, Ri', rib, 0.0_R8)
  call confere('louis: neutro, fator', fator, 1.0_R8)
  call louis_stability(250.0_R8, 260.0_R8, 5.0_R8, rib, fator)
  call confere('louis: instável, Ri', rib, -0.15696_R8)
  call confere('louis: instável, fator', fator, 1.0511043414502999871_R8)
  call louis_stability(270.0_R8, 240.0_R8, 0.5_R8, rib, fator)
  call confere('louis: muito estável, Ri', rib, 43.6_R8)
  call confere('louis: muito estável, fator no piso 0,05', fator, 0.05_R8)
  call louis_stability(240.0_R8, 270.0_R8, 0.1_R8, rib, fator)
  call confere('louis: muito instável, Ri', rib, -1226.25_R8)
  call confere('louis: muito instável, fator no teto 3', fator, 3.0_R8)

  ! --- ocean_direct_albedo ------------------------------------------------
  ! célula (1, 91): lon 0,5°, lat 0,5°; ao meio-dia UTC, sol quase a pino
  call ocean_direct_albedo(1, 91, 12.0_R8, 0.0_R8, coszen, albedo)
  call confere('albedo: sol a pino, coszen', coszen, 0.99992384757819561958_R8)
  call confere('albedo: sol a pino, albedo no piso 0,03', albedo, 0.03_R8)
  ! mesma célula à meia-noite UTC: noite, coszen = 0 e mu = 0,02
  call ocean_direct_albedo(1, 91, 0.0_R8, 0.0_R8, coszen, albedo)
  call confere('albedo: noite, coszen', coszen, 0.0_R8)
  call confere('albedo: noite, albedo com mu = 0,02', albedo, 0.38655078532643025242_R8)
  ! célula (1, 151): lat 60,5°, ao meio-dia UTC
  call ocean_direct_albedo(1, 151, 12.0_R8, 0.0_R8, coszen, albedo)
  call confere('albedo: lat 60,5°, coszen', coszen, 0.49240481012316851454_R8)
  call confere('albedo: lat 60,5°, albedo', albedo, 0.071483176158612699358_R8)
  ! célula (1, 169): lat 78,5°, sol baixo
  call ocean_direct_albedo(1, 169, 12.0_R8, 0.0_R8, coszen, albedo)
  call confere('albedo: lat 78,5°, coszen', coszen, 0.19936034309715207475_R8)
  call confere('albedo: lat 78,5°, albedo', albedo, 0.20439968470969041866_R8)
  ! célula (91, 91): lon 90,5°, às 6 h UTC, declinação 0,4 rad
  call ocean_direct_albedo(91, 91, 6.0_R8, 0.4_R8, coszen, albedo)
  call confere('albedo: declinação 0,4 rad, coszen', coszen, 0.92438912596543658411_R8)
  call confere('albedo: declinação 0,4 rad, albedo no piso', albedo, 0.03_R8)

  if (nfalhas == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfalhas, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Compara obtido com esperado, com tolerância relativa TOL (absoluta
  !! quando o esperado é zero), e imprime PASSOU ou FALHOU.
  subroutine confere(nome, obtido, esperado)
    character(len=*), intent(in) :: nome
    real(R8),         intent(in) :: obtido
    real(R8),         intent(in) :: esperado
    logical :: ok

    ok = abs(obtido - esperado) <= TOL * max(abs(esperado), 1.0_R8)
    if (ok) then
      write(*, '(A, A)') 'PASSOU  ', nome
    else
      write(*, '(A, A, A, ES24.16, A, ES24.16)') 'FALHOU  ', nome, ': obtido ', obtido, &
        ', esperado ', esperado
      nfalhas = nfalhas + 1
    end if
  end subroutine confere

end program test_formulas_bulk
