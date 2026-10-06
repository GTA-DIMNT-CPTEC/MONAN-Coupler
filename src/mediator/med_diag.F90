!> @file med_diag.F90
!! @brief Diagnósticos do mediador e relatório dos pontos completados.
!!
!! Rotinas que só leem campos e escrevem no log; nenhuma altera um campo.
!! As fases do mediador as chamam com uma linha, no ponto do fluxo em que
!! fazem sentido.
!!
!! | Rotina                     | Linha no log                            | Nível     |
!! |----------------------------|-----------------------------------------|-----------|
!! | log_atm_forcing_summary    | DIAG atm_forcing summary                | depuração |
!! | log_ocean_mask             | DIAG ocean_mask                         | depuração |
!! | log_sst_raw                | DIAG sst raw                            | depuração |
!! | log_ice_source             | DIAG ice_fraction source, bitsum etapa1 | depuração |
!! | log_ice_destination        | DIAG ice_fraction destination, etapa2   | depuração |
!! | log_ice_raw                | DIAG ice_fraction raw                   | depuração |
!! | log_ice_extrapolated       | DIAG ice_fraction bitsum etapa3         | depuração |
!! | log_ice_export             | DIAG ice_fraction bitsum etapa4         | depuração |
!! | log_ice_stability          | DIAG ice_stability                      | depuração |
!! | check_ice_geography        | gelo em latitude implausível            | aviso     |
!! | report_fills               | CPL-REL: completar ...                  | relatório |
!!
!! As linhas "DIAG ice_fraction bitsum etapa<k>" são as somas de bits da
!! fração de gelo nas quatro etapas do caminho gelo para atmosfera, por PET
!! (diag_bitsum_mod); o tools/coupler/mede-taxa-repro.sh as compara entre
!! execuções, junto com "DIAG ocean_mask" e "DIAG ice_fraction raw". Os
!! diagnósticos de depuração só são chamados com log_level='debug'
!! (log_debug_enabled), para que nem sejam calculados fora desse nível.
!!
!! Também a contagem dos pontos completados por vizinhança (record_fill, a
!! cada preenchimento) e as linhas do relatório de acoplamento que a resumem
!! no último passo da rodada (report_fills).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_diag_mod
  use ESMF
  use coupler_constants_mod, only: ATM_NX, ATM_NY
  use coupler_log_mod, only: COMP_MED, log_debug, log_warning, log_report
  use diag_bitsum_mod, only: diag_bitsum_log
  use cpl_grids_mod, only: center_lon_east0, center_lat_east0
  use med_cap_types_mod, only: med_fill_count_t, N_FILL, FILL_NAMES

  implicit none
  private

  public :: log_atm_forcing_summary
  public :: log_ocean_mask, log_sst_raw
  public :: log_ice_source, log_ice_destination, log_ice_raw
  public :: log_ice_extrapolated, log_ice_export, log_ice_stability
  public :: check_ice_geography
  public :: record_fill, report_fills

  !> Início das linhas de depuração deste módulo
  character(len=*), parameter :: DIAG_ATM   = 'DIAG atm_forcing summary: '
  character(len=*), parameter :: DIAG_ICE   = 'DIAG ice_fraction '
  character(len=*), parameter :: BITSUM_ICE = 'ice_fraction bitsum '

contains

  !> @brief Resumo da forçante atmosférica reunida na grade ATM, no primeiro
  !! passo, só no PET 0: células com valor e faixa de cada campo.
  !!
  !! Espera-se uas com valor em mais de 30000 das 64800 células (cobertura
  !! global). Só com log_level='debug'.
  !!
  !! @param[in]    uas_g..lwdn_g     forçantes na grade ATM global
  !! @param[inout] first_call_diag   .true. até o PET 0 registrar o resumo
  !! @param[inout] rc                código de retorno da consulta à VM
  subroutine log_atm_forcing_summary(uas_g, tas_g, psl_g, swdn_g, vas_g, shum_g, rain_g, lwdn_g, &
                                     first_call_diag, rc)
    logical, intent(inout) :: first_call_diag
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: uas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: tas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: psl_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: swdn_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: vas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: shum_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: rain_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: lwdn_g(:,:)
    integer :: my_pet
    type(ESMF_VM) :: diag_vm
    character(len=160) :: msg

    call ESMF_VMGetCurrent(diag_vm, rc=rc)
    call ESMF_VMGet(diag_vm, localPet=my_pet, rc=rc)
    if (my_pet /= 0 .or. .not. first_call_diag) return
    first_call_diag = .false.

    write(msg,'(A,I0,A,I0,A,F9.4,A,F9.4)') 'uas nonzero=', &
      count(abs(uas_g) > 1.0e-10_ESMF_KIND_R8), '/', ATM_NX*ATM_NY, &
      ' min=', minval(uas_g), ' max=', maxval(uas_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
    write(msg,'(A,I0,A,F9.3,A,F9.3)') 'tas nonzero>100K=', &
      count(tas_g > 100.0_ESMF_KIND_R8), ' min=', minval(tas_g), ' max=', maxval(tas_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
    write(msg,'(A,I0,A,F11.3,A,F11.3)') 'psl nonzero>1Pa=', &
      count(psl_g > 1.0_ESMF_KIND_R8), ' min=', minval(psl_g), ' max=', maxval(psl_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
    write(msg,'(A,I0,A,F10.3,A,F10.3)') 'swdn nonzero=', &
      count(swdn_g > 1.0e-10_ESMF_KIND_R8), ' min=', minval(swdn_g), ' max=', maxval(swdn_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
    write(msg,'(A,F9.4,A,F9.4)') 'vas min=', minval(vas_g), ' max=', maxval(vas_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
    write(msg,'(A,F11.6,A,F11.6)') 'shum min=', minval(shum_g), ' max=', maxval(shum_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
    write(msg,'(A,F12.6,A,F12.6)') 'rain min=', minval(rain_g), ' max=', maxval(rain_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
    write(msg,'(A,F10.3,A,F10.3)') 'lwdn min=', minval(lwdn_g), ' max=', maxval(lwdn_g)
    call log_debug(COMP_MED, DIAG_ATM//trim(msg))
  end subroutine log_atm_forcing_summary

  !> @brief Máscara do oceano vista por este PET ao criar a rota do gelo:
  !! se So_omask foi encontrada e quantos pontos de terra e de oceano tem.
  !!
  !! Confirma que a máscara não está toda em terra ou toda em oceano por
  !! engano. É gravada uma vez por execução; o mede-taxa-repro.sh a usa como
  !! fronteira entre execuções no log do PET 0.
  !!
  !! @param[in] found   So_omask encontrada no importState
  !! @param[in] n_land  pontos de terra neste PET
  !! @param[in] n_sea   pontos de oceano neste PET
  subroutine log_ocean_mask(found, n_land, n_sea)
    logical, intent(in) :: found
    integer, intent(in) :: n_land, n_sea
    character(len=120) :: msg

    write(msg,'(A,L1,A,I0,A,I0)') 'DIAG ocean_mask: So_omask encontrada=', found, &
      ' n_land=', n_land, ' n_sea=', n_sea
    call log_debug(COMP_MED, trim(msg))
  end subroutine log_ocean_mask

  !> @brief So_t como chega do oceano, antes de qualquer interpolação ou
  !! máscara do mediador, no primeiro DE local: índices e quatro valores da
  !! primeira linha. Separa um problema da exportação do MOM6 de um problema
  !! da interpolação.
  !!
  !! @param[in]    field  So_t no importState
  !! @param[inout] done   .true. depois do primeiro registro neste PET
  subroutine log_sst_raw(field, done)
    type(ESMF_Field), intent(in)    :: field
    logical,          intent(inout) :: done
    real(ESMF_KIND_R8), pointer :: sst_raw(:,:)
    integer :: rc_diag, i1r, i2r, j1r, mid_r
    character(len=300) :: msg

    if (done) return
    call ESMF_FieldGet(field, localDe=0, farrayPtr=sst_raw, rc=rc_diag)
    if (rc_diag /= ESMF_SUCCESS .or. .not. associated(sst_raw)) return
    i1r = lbound(sst_raw,1); i2r = ubound(sst_raw,1)
    j1r = lbound(sst_raw,2)
    mid_r = (i1r + i2r) / 2
    write(msg,'(A,I0,A,I0,A,I0)') 'DIAG sst raw: DE local i=[', i1r, ',', i2r, '] j1=', j1r
    call log_debug(COMP_MED, trim(msg))
    write(msg,'(A,F9.3,A,F9.3,A,F9.3,A,F9.3)') &
      'DIAG sst raw: sst_raw(i1,j1)=', sst_raw(i1r,j1r), &
      ' sst_raw(mid,j1)=', sst_raw(mid_r,j1r), &
      ' sst_raw(i2,j1)=', sst_raw(i2r,j1r), &
      ' min_row=', minval(sst_raw(:,j1r))
    call log_debug(COMP_MED, trim(msg))
    done = .true.
  end subroutine log_sst_raw

  !> @brief Fração de gelo na grade do oceano, antes da interpolação (etapa 1
  !! de 4): mínimo, máximo e soma no DE local, com dezessete algarismos, e a
  !! soma de bits.
  !!
  !! Os valores são locais ao PET: compare sempre o mesmo PET entre
  !! execuções. Com "destination", diz se uma divergência entre execuções já
  !! vem do SIS2 ou nasce na interpolação.
  !!
  !! @param[in] f_ifrac_src  Si_ifrac_sis2 no importState
  subroutine log_ice_source(f_ifrac_src)
    type(ESMF_Field), intent(in) :: f_ifrac_src
    real(ESMF_KIND_R8), pointer :: p(:,:)
    character(len=300) :: msg
    integer :: rc_src, rc_bs

    call ESMF_FieldGet(f_ifrac_src, farrayPtr=p, rc=rc_src)
    if (rc_src == ESMF_SUCCESS .and. associated(p)) then
      write(msg,'(A,ES24.16,A,ES24.16,A,ES24.16,A,I0)') &
        DIAG_ICE//'source: Si_ifrac_sis2 min=', minval(p), ' max=', maxval(p), &
        ' soma=', sum(p), ' n_local=', size(p)
      call log_debug(COMP_MED, trim(msg))
    else
      call log_warning(COMP_MED, DIAG_ICE//'source: Si_ifrac_sis2 indisponivel; '// &
        'origem nao medida')
    end if
    call diag_bitsum_log(COMP_MED, BITSUM_ICE//'etapa1 origem', f_ifrac_src, rc_bs)
  end subroutine log_ice_source

  !> @brief Fração de gelo na grade ATM, logo depois da interpolação e antes
  !! da extrapolação (etapa 2 de 4): máximo e soma das células mapeadas, com
  !! dezessete algarismos, número de células com a sentinela -999 (não
  !! mapeadas) e a soma de bits.
  !!
  !! A sentinela domina o mínimo e a soma, por isso entra contada à parte.
  !!
  !! @param[in] ifrac  fração de gelo na grade ATM (is%ice%ifrac)
  subroutine log_ice_destination(ifrac)
    type(ESMF_Field), intent(in) :: ifrac
    real(ESMF_KIND_R8), pointer :: p(:,:)
    character(len=300) :: msg
    integer :: rc_dst, rc_bs

    call ESMF_FieldGet(ifrac, farrayPtr=p, rc=rc_dst)
    if (rc_dst == ESMF_SUCCESS .and. associated(p)) then
      write(msg,'(A,ES24.16,A,ES24.16,A,I0,A,I0)') &
        DIAG_ICE//'destination: max=', maxval(p), &
        ' soma_validos=', sum(p, mask=(p > -900.0_ESMF_KIND_R8)), &
        ' n_sentinela=', count(p < -900.0_ESMF_KIND_R8), ' n_local=', size(p)
      call log_debug(COMP_MED, trim(msg))
    end if
    call diag_bitsum_log(COMP_MED, BITSUM_ICE//'etapa2 pos-interpolacao', ifrac, rc_bs)
  end subroutine log_ice_destination

  !> @brief Fração de gelo interpolada, antes da extrapolação: mínimo, máximo
  !! e células exatamente iguais a zero. Muitas células em zero indicam
  !! problema na interpolação ou na máscara, e não na física do SIS2.
  !!
  !! @param[in] ifrac  fração de gelo na grade ATM (is%ice%ifrac)
  subroutine log_ice_raw(ifrac)
    type(ESMF_Field), intent(in) :: ifrac
    real(ESMF_KIND_R8), pointer :: p(:,:)
    character(len=250) :: msg
    integer :: rc_raw

    nullify(p)
    call ESMF_FieldGet(ifrac, farrayPtr=p, rc=rc_raw)
    if (.not. associated(p)) return
    write(msg,'(A,ES10.3,A,ES10.3,A,I0,A,I0)') &
      DIAG_ICE//'raw: min=', minval(p), ' max=', maxval(p), &
      ' n_exact_zero=', count(p == 0.0_ESMF_KIND_R8), ' n_total=', size(p)
    call log_debug(COMP_MED, trim(msg))
  end subroutine log_ice_raw

  !> @brief Soma de bits da fração de gelo depois da extrapolação (etapa 3 de 4).
  !! @param[in] ifrac  fração de gelo na grade ATM (is%ice%ifrac)
  subroutine log_ice_extrapolated(ifrac)
    type(ESMF_Field), intent(in) :: ifrac
    integer :: rc_bs
    call diag_bitsum_log(COMP_MED, BITSUM_ICE//'etapa3 pos-extrapolacao', ifrac, rc_bs)
  end subroutine log_ice_extrapolated

  !> @brief Soma de bits de Si_ifrac como sai do mediador (etapa 4 de 4): o
  !! que o conector entrega ao MONAN-A e o que aparece no monan2_import_*.nc.
  !!
  !! @param[inout] exportState  estado de exportação do mediador
  subroutine log_ice_export(exportState)
    type(ESMF_State), intent(inout) :: exportState
    type(ESMF_Field) :: f_bs
    integer :: rc_bs

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_bs, rc=rc_bs)
    if (rc_bs == ESMF_SUCCESS) then
      call diag_bitsum_log(COMP_MED, BITSUM_ICE//'etapa4 exportState', f_bs, rc_bs)
    else
      call log_warning(COMP_MED, 'DIAG '//BITSUM_ICE//'etapa4: Si_ifrac ausente do '// &
        'exportState; etapa nao medida')
    end if
  end subroutine log_ice_export

  !> @brief Células em que o calor sensível sobre o gelo passou de 490 W/m2
  !! antes do limite de +-500 W/m2, e os dados da primeira delas. Saturação
  !! frequente indica vento ou diferença de temperatura extremos.
  !!
  !! @param[in] n_sat         células saturadas neste PET
  !! @param[in] i_sat, j_sat  índices da primeira
  !! @param[in] v             da primeira: vento, tas, temperatura efetiva do
  !!                          gelo, diferença tas - gelo, Rib, fator de
  !!                          estabilidade e valor antes do limite
  subroutine log_ice_stability(n_sat, i_sat, j_sat, v)
    integer,            intent(in) :: n_sat, i_sat, j_sat
    real(ESMF_KIND_R8), intent(in) :: v(7)
    character(len=320) :: msg

    if (n_sat == 0) return
    write(msg,'(A,I0,A,I0,A,I0,A,ES10.3,A,ES10.3,A,ES10.3, &
      &A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3)') &
      'DIAG ice_stability: n_saturado=', n_sat, &
      ' primeira_celula(i,j)=(', i_sat, ',', j_sat, &
      ') wspd=', v(1), ' tas=', v(2), ' tice=', v(3), &
      ' deltaT=', v(4), ' Rib=', v(5), ' stab_fac=', v(6), &
      ' valor_bruto=', v(7)
    call log_debug(COMP_MED, trim(msg))
  end subroutine log_ice_stability

  !> @brief Aviso de gelo em latitude implausível: células com fração acima
  !! de 0,05 em |lat| < 55 graus, onde não existe gelo marinho em nenhuma
  !! época do ano. Registra o número e a primeira encontrada neste PET.
  !! Latitude e longitude vêm das fórmulas da malha atm_med (cpl_grids),
  !! sem depender de qual PET cuida de qual parte do domínio. Gravado em
  !! qualquer log_level.
  !!
  !! @param[in] p_ifrac_out  fração de gelo na grade ATM, depois da
  !!                         extrapolação
  subroutine check_ice_geography(p_ifrac_out)
    real(ESMF_KIND_R8), pointer, intent(in) :: p_ifrac_out(:,:)
    real(ESMF_KIND_R8), parameter :: LAT_MAX_ICE = 55.0_ESMF_KIND_R8
    integer :: ii_geo
    integer :: jj_geo
    integer :: n_bad_geo
    real(ESMF_KIND_R8) :: lat_bad
    real(ESMF_KIND_R8) :: lon_bad
    real(ESMF_KIND_R8) :: val_bad
    character(len=250) :: msg
    real(ESMF_KIND_R8) :: lat_here
    real(ESMF_KIND_R8) :: lon_here

    n_bad_geo = 0; lat_bad = -999.0_ESMF_KIND_R8
    lon_bad = -999.0_ESMF_KIND_R8; val_bad = -999.0_ESMF_KIND_R8
    do jj_geo = lbound(p_ifrac_out,2), ubound(p_ifrac_out,2)
      do ii_geo = lbound(p_ifrac_out,1), ubound(p_ifrac_out,1)
        if (p_ifrac_out(ii_geo,jj_geo) > 0.05_ESMF_KIND_R8) then
            lon_here = center_lon_east0(ii_geo, ATM_NX)
            lat_here = center_lat_east0(jj_geo, ATM_NY)
            if (abs(lat_here) < LAT_MAX_ICE) then
              n_bad_geo = n_bad_geo + 1
              if (lat_bad < -900.0_ESMF_KIND_R8) then
                lat_bad = lat_here; lon_bad = lon_here
                val_bad = p_ifrac_out(ii_geo,jj_geo)
              end if
            end if
        end if
      end do
    end do
    if (n_bad_geo > 0) then
      write(msg,'(A,I0,A,ES10.3,A,ES10.3,A,ES10.3)') &
        'gelo em latitude implausivel: ', n_bad_geo, &
        ' celula(s) com ifrac>0,05 em |lat|<55; primeira: lat=', lat_bad, &
        ' lon=', lon_bad, ' ifrac=', val_bad
      call log_warning(COMP_MED, trim(msg))
    end if
  end subroutine check_ice_geography

  !> @brief Soma um preenchimento por vizinhança à contagem do campo, neste PET.
  !!
  !! @param[inout] c          contagem do campo
  !! @param[in]    n_invalid  pontos fora da faixa válida antes do preenchimento
  !! @param[in]    n_left     pontos que ficaram com o valor fixo
  subroutine record_fill(c, n_invalid, n_left)
    type(med_fill_count_t), intent(inout) :: c
    integer,              intent(in)    :: n_invalid, n_left

    c%n_applied = c%n_applied + 1_ESMF_KIND_I8
    c%n_invalid_pts = c%n_invalid_pts + int(n_invalid, ESMF_KIND_I8)
    c%n_fixed_pts = c%n_fixed_pts + int(n_left,    ESMF_KIND_I8)
  end subroutine record_fill

  !> @brief Relatório dos pontos completados, no último passo: soma as contagens
  !! de todos os PETs do mediador e o PET 0 escreve uma linha CPL-REL: por
  !! campo que foi completado alguma vez. Coletiva: todos os PETs do
  !! mediador chamam.
  !!
  !! @param[in]  completa  contagens deste PET (índices COMPL_*)
  !! @param[out] rc        ESMF_SUCCESS, ou o código da redução que falhou
  subroutine report_fills(fill_counts, rc)
    type(med_fill_count_t), intent(in) :: fill_counts(N_FILL)
    integer,              intent(out) :: rc

    type(ESMF_VM) :: vm
    integer :: localPet, k
    integer(ESMF_KIND_I8) :: totals_loc(2*N_FILL), totals(2*N_FILL)
    integer(ESMF_KIND_I8) :: apl_loc(N_FILL), apl(N_FILL)
    character(len=24) :: b1, b2, b3

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    totals_loc(1:N_FILL)    = fill_counts%n_invalid_pts
    totals_loc(N_FILL+1:) = fill_counts%n_fixed_pts
    apl_loc = fill_counts%n_applied
    call ESMF_VMAllReduce(vm, totals_loc, totals, 2*N_FILL, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllReduce(vm, apl_loc, apl, N_FILL, ESMF_REDUCE_MAX, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localPet /= 0) return

    do k = 1, N_FILL
      if (apl(k) == 0) cycle
      write(b1, '(I0)') apl(k)
      write(b2, '(I0)') totals(k)
      write(b3, '(I0)') totals(N_FILL + k)
      call log_report('completar '//trim(FILL_NAMES(k))//': '//trim(b1)// &
        ' aplicacao(oes), '//trim(b2)//' ponto(s) fora da faixa, '//trim(b3)// &
        ' com valor fixo (soma dos PETs)')
    end do
  end subroutine report_fills

end module med_diag_mod
