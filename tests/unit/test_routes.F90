!> @file test_routes.F90
!! @brief Configuração das rotas do mediador lida de ROUTES (route_spec).
!!
!! Desde a R-FASE11-12, o mediador cria as rotas por create_route, que lê a
!! configuração na tabela ROUTES (cpl_map) por route_spec. Até a
!! R-FASE11-11 (tag fase11-11-validada), cada chamada de criação passava a
!! configuração à mão, e até a R-FASE11-12 (tag fase11-12-validada) cada
!! chamada de interpolação passava zero_total, e RegridOrCopy trocava os NaN
!! do destino da rota atm2ocn por zero. Até a R-FASE11-13 (tag
!! fase11-13-validada), a SST (fill_sst_gaps, em med_ocean) e a fração de
!! gelo exportada (export_ice_fraction, em med_export) eram completadas por
!! vizinhança depois da interpolação, com as opções escritas ali. A
!! referência abaixo junta essas quatro coisas, copiadas sem mudança: a
!! configuração de cada criação, o zero_total de todas as interpolações da
!! rota (o mesmo em todas), a troca de NaN e o preenchimento por
!! vizinhança. O teste confere, para cada uma das seis rotas, que a
!! configuração lida da tabela é a mesma, campo a campo do regrid_spec_t
!! (esquema, métodos, máscara na origem, zero_total, arquivo de pesos,
!! classe do campo, preenchimento e troca de NaN), e que a rota de reserva é
!! a mesma. Confere também que uma rota fora de ROUTES é recusada e que
!! route_fill devolve o preenchimento da rota (o que a SST usa
!! enquanto a rota ocn2atm_sst não existe) ou nenhum, fora de ROUTES.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_routes
  use ESMF,                  only : ESMF_KIND_R8
  use coupler_constants_mod, only : T_FREEZE_SEAWATER
  use regrid_base_mod,       only : regrid_spec_t, regrid_fill_t
  use regrid_manager_mod,    only : regrid_spec
  use med_cap_methods_mod,   only : route_spec, route_fill
  implicit none

  integer :: nfailures
  type(regrid_spec_t) :: s
  character(len=32)   :: fallback
  logical :: ok
  ! Preenchimentos de antes: SST_FILL de fill_sst_gaps e o de export_ice_fraction
  type(regrid_fill_t), parameter :: SST_FILL = regrid_fill_t(enabled=.true.,     &
    vmin=270.0_ESMF_KIND_R8, vmax=310.0_ESMF_KIND_R8, vfill=T_FREEZE_SEAWATER, &
    max_iter=40, skip_fraction=1.0_ESMF_KIND_R8, overflow_to_fill=.true.)
  type(regrid_fill_t), parameter :: IFRAC_EXP_FILL = regrid_fill_t(enabled=.true., &
    vmin=0.0_ESMF_KIND_R8, vmax=1.0_ESMF_KIND_R8, vfill=0.0_ESMF_KIND_R8)

  nfailures = 0

  ! Chamadas de antes (med_init, med_cap_methods, med_ocean, med_ice,
  ! med_export, med_bulk_ncar, MED_cap), com o zero_total das interpolações,
  ! a troca de NaN de RegridOrCopy e os preenchimentos por vizinhança
  call check('atm2ocn',          regrid_spec('nearest_stod', zero_total=.true., &
                                               nan_value=0.0_ESMF_KIND_R8), '')
  call check('ocn2atm',          regrid_spec('bilinear', zero_total=.true.), '')
  call check('ocn2atm_sst',      with_fill(regrid_spec('conserve,bilinear', mask_src=.true., &
                                               zero_total=.true.), SST_FILL), 'ocn2atm')
  call check('ocn2atm_ice',      regrid_spec('conserve,bilinear', mask_src=.true., &
                                               zero_total=.false.), 'ocn2atm')
  call check('atm2ocn_ice',      with_fill(regrid_spec('conserve,nearest_stod', &
                                               zero_total=.false.), IFRAC_EXP_FILL), 'atm2ocn')
  call check('ocn2atm_landmask', regrid_spec('nearest_stod', zero_total=.false.), '')

  call route_spec('rota_inexistente', s, fallback, ok)
  call outcome('rota fora de ROTAS recusada', .not. ok)
  call outcome('completar_da_rota: SST igual ao preenchimento de antes', &
                 same_fill(route_fill('ocn2atm_sst'), SST_FILL))
  call outcome('completar_da_rota: rota fora de ROTAS sem preenchimento', &
                 same_fill(route_fill('rota_inexistente'), regrid_fill_t()))

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  function with_fill(spec, fill) result(r)
    type(regrid_spec_t), intent(in) :: spec
    type(regrid_fill_t), intent(in) :: fill
    type(regrid_spec_t) :: r
    r = spec
    r%fill = fill
  end function with_fill

  subroutine check(name, before, fallback_before)
    character(len=*),    intent(in) :: name, fallback_before
    type(regrid_spec_t), intent(in) :: before
    type(regrid_spec_t) :: now_time
    character(len=32)   :: fallback_now
    logical :: found

    call route_spec(name, now_time, fallback_now, found)
    call outcome(trim(name)//': configuracao igual a da chamada de antes', &
                   found .and. same(now_time, before) .and. fallback_now == fallback_before)
  end subroutine check

  logical function same(a, b)
    type(regrid_spec_t), intent(in) :: a, b
    same = a%scheme == b%scheme .and. all(a%methods == b%methods) .and. &
            (a%mask_src .eqv. b%mask_src) .and. (a%zero_total .eqv. b%zero_total) .and. &
            a%weights_file == b%weights_file .and. a%field_class == b%field_class .and. &
            same_fill(a%fill, b%fill) .and. (a%nan_replace .eqv. b%nan_replace) .and. &
            a%nan_value == b%nan_value
  end function same

  logical function same_fill(a, b)
    type(regrid_fill_t), intent(in) :: a, b
    same_fill = (a%enabled .eqv. b%enabled) .and. a%vmin == b%vmin .and. a%vmax == b%vmax .and. &
                 a%vfill == b%vfill .and. a%max_iter == b%max_iter .and. &
                 a%skip_fraction == b%skip_fraction .and. &
                 (a%overflow_to_fill .eqv. b%overflow_to_fill)
  end function same_fill

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

end program test_routes
