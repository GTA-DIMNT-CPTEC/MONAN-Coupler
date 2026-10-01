!> @file test_rotas.F90
!! @brief Configuração das rotas do mediador lida de ROTAS (spec_da_rota).
!!
!! Desde a R-FASE11-12, o mediador cria as rotas por cria_rota, que lê a
!! configuração na tabela ROTAS (cpl_map) por spec_da_rota. Até a
!! R-FASE11-11 (tag fase11-11-validada), cada chamada de criação passava a
!! configuração à mão, e até a R-FASE11-12 (tag fase11-12-validada) cada
!! chamada de interpolação passava zero_total, e RegridOrCopy trocava os NaN
!! do destino da rota atm2ocn por zero. A referência abaixo junta essas
!! três coisas, copiadas sem mudança: a configuração de cada criação, o
!! zero_total de todas as interpolações da rota (o mesmo em todas) e a
!! troca de NaN. O teste confere, para cada uma das seis rotas, que a
!! configuração lida da tabela é a mesma, campo a campo do regrid_spec_t
!! (esquema, métodos, máscara na origem, zero_total, arquivo de pesos,
!! classe do campo, preenchimento e troca de NaN), e que a rota de reserva é
!! a mesma. Confere também que uma rota fora de ROTAS é recusada.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_rotas
  use ESMF,                only : ESMF_KIND_R8
  use regrid_base_mod,     only : regrid_spec_t, regrid_fill_t
  use regrid_manager_mod,  only : regrid_spec
  use med_cap_methods_mod, only : spec_da_rota
  implicit none

  integer :: nfalhas
  type(regrid_spec_t) :: s
  character(len=32)   :: reserva
  logical :: ok

  nfalhas = 0

  ! Chamadas de antes (med_init, med_cap_methods, med_ocean, med_ice,
  ! med_export, med_bulk_ncar, MED_cap), com o zero_total das interpolações
  ! e a troca de NaN de RegridOrCopy
  call confere('atm2ocn',          regrid_spec('nearest_stod', zero_total=.true., &
                                               nan_value=0.0_ESMF_KIND_R8), '')
  call confere('ocn2atm',          regrid_spec('bilinear', zero_total=.true.), '')
  call confere('ocn2atm_sst',      regrid_spec('conserve,bilinear', mask_src=.true., &
                                               zero_total=.true.), 'ocn2atm')
  call confere('ocn2atm_ice',      regrid_spec('conserve,bilinear', mask_src=.true., &
                                               zero_total=.false.), 'ocn2atm')
  call confere('atm2ocn_ice',      regrid_spec('conserve,nearest_stod', zero_total=.false.), &
                                   'atm2ocn')
  call confere('ocn2atm_landmask', regrid_spec('nearest_stod', zero_total=.false.), '')

  call spec_da_rota('rota_inexistente', s, reserva, ok)
  call resultado('rota fora de ROTAS recusada', .not. ok)

  if (nfalhas == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfalhas, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  subroutine confere(nome, antes, reserva_antes)
    character(len=*),    intent(in) :: nome, reserva_antes
    type(regrid_spec_t), intent(in) :: antes
    type(regrid_spec_t) :: agora
    character(len=32)   :: reserva_agora
    logical :: achou

    call spec_da_rota(nome, agora, reserva_agora, achou)
    call resultado(trim(nome)//': configuracao igual a da chamada de antes', &
                   achou .and. igual(agora, antes) .and. reserva_agora == reserva_antes)
  end subroutine confere

  logical function igual(a, b)
    type(regrid_spec_t), intent(in) :: a, b
    igual = a%scheme == b%scheme .and. all(a%methods == b%methods) .and. &
            (a%mask_src .eqv. b%mask_src) .and. (a%zero_total .eqv. b%zero_total) .and. &
            a%weights_file == b%weights_file .and. a%field_class == b%field_class .and. &
            fill_igual(a%fill, b%fill) .and. (a%nan_replace .eqv. b%nan_replace) .and. &
            a%nan_value == b%nan_value
  end function igual

  logical function fill_igual(a, b)
    type(regrid_fill_t), intent(in) :: a, b
    fill_igual = (a%enabled .eqv. b%enabled) .and. a%vmin == b%vmin .and. a%vmax == b%vmax .and. &
                 a%vfill == b%vfill .and. a%max_iter == b%max_iter .and. &
                 a%skip_fraction == b%skip_fraction .and. &
                 (a%overflow_to_fill .eqv. b%overflow_to_fill)
  end function fill_igual

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

end program test_rotas
