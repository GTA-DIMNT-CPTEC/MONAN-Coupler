!> @file med_diag.F90
!! @brief Resumos e diagnósticos do log do mediador.
!!
!! Rotinas de MED_cap.F90 que só escrevem no log do ESMF: o resumo da forçante
!! atmosférica recolhida na grade ATM e as somas de bits da fração de gelo
!! exportada. Não alteram campos.
!!
!! Também a contagem dos pontos completados por vizinhança
!! (registra_completa, a cada preenchimento) e as linhas do relatório de
!! acoplamento que a resumem no último passo da rodada (relata_completas,
!! prefixo CPL-REL:, ver src/coupling/cpl_check.F90).
!!
!! Separado de MED_cap.F90 sem mudar instruções (R-FASE8-01).
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module med_diag_mod
  use ESMF
  use coupler_constants_mod, only: ATM_NX, ATM_NY
  use diag_bitsum_mod, only: diag_bitsum_log
  use med_cap_types_mod, only: med_completa_t, N_COMPLETA, COMPLETA_NOMES

  implicit none
  private

  public :: log_atm_forcing_summary
  public :: log_ifrac_export_bitsum
  public :: registra_completa, relata_completas

contains

  subroutine log_atm_forcing_summary(uas_g, tas_g, psl_g, swdn_g, vas_g, shum_g, rain_g, lwdn_g, &
                                     first_call_diag, rc)
    logical, intent(inout) :: first_call_diag   !< .true. até o PET 0 registrar o resumo
    integer, intent(inout) :: rc
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: uas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: tas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: psl_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: swdn_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: vas_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: shum_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: rain_g(:,:)
    real(ESMF_KIND_R8), allocatable, target, intent(in) :: lwdn_g(:,:)
    integer :: my_pet, n_nz_uas, n_nz_psl, n_nz_swdn, n_nz_tas
    type(ESMF_VM) :: diag_vm

    call ESMF_VMGetCurrent(diag_vm, rc=rc)
    call ESMF_VMGet(diag_vm, localPet=my_pet, rc=rc)
    if (my_pet == 0 .and. first_call_diag) then
      first_call_diag = .false.
      n_nz_uas  = count(abs(uas_g)  > 1.0e-10_ESMF_KIND_R8)
      n_nz_tas  = count(tas_g       > 100.0_ESMF_KIND_R8)
      n_nz_psl  = count(psl_g       > 1.0_ESMF_KIND_R8)
      n_nz_swdn = count(swdn_g      > 1.0e-10_ESMF_KIND_R8)
      write(*,'(A)') '######## [MED BUG-CALC-08 + BUG-MPAS-01 DIAG] ########'
      write(*,'(A,I0,A,I0,A,F9.4,A,F9.4)') &
        '   uas_g: nonzero=', n_nz_uas, '/', ATM_NX*ATM_NY, &
        '  min=', minval(uas_g), '  max=', maxval(uas_g)
      write(*,'(A,I0,A,F9.3,A,F9.3)') &
        '   tas_g: nonzero>100K=', n_nz_tas, &
        '  min=', minval(tas_g), '  max=', maxval(tas_g)
      write(*,'(A,I0,A,F11.3,A,F11.3)') &
        '   psl_g: nonzero>1Pa=', n_nz_psl, &
        '  min=', minval(psl_g), '  max=', maxval(psl_g)
      write(*,'(A,I0,A,F10.3,A,F10.3)') &
        '  swdn_g: nonzero=', n_nz_swdn, &
        '  min=', minval(swdn_g), '  max=', maxval(swdn_g)
      write(*,'(A,F9.4,A,F9.4)') &
        '   vas_g min=', minval(vas_g), '  max=', maxval(vas_g)
      write(*,'(A,F11.6,A,F11.6)') &
        '  shum_g min=', minval(shum_g), '  max=', maxval(shum_g)
      write(*,'(A,F12.6,A,F12.6)') &
        '  rain_g min=', minval(rain_g), '  max=', maxval(rain_g)
      write(*,'(A,F10.3,A,F10.3)') &
        '  lwdn_g min=', minval(lwdn_g), '  max=', maxval(lwdn_g)
      write(*,'(A,I0,A,I0)') &
        '   NX_G=', ATM_NX, '  NY_G=', ATM_NY
      write(*,'(A)') '########################################'
      flush(6)
    end if
  end subroutine log_atm_forcing_summary

  !============================================================================
  !> @brief Soma de bits de Si_ifrac como sai do mediador (FIX-DIAG-BITSUM-01).
  !!
  !! Etapa 4 de 4: Si_ifrac no exportState, depois do RouteOcnToAtm. E o que
  !! o conector entrega ao MPAS e o que aparece no monan2_import_*.nc.
  !!
  !! @param[inout] exportState  estado de exportacao do mediador
  !============================================================================
  subroutine log_ifrac_export_bitsum(exportState)
    type(ESMF_State), intent(inout) :: exportState

    type(ESMF_Field) :: f_bs
    integer :: rc_bs_2

    call ESMF_StateGet(exportState, itemName="Si_ifrac", field=f_bs, rc=rc_bs_2)
    if (rc_bs_2 == ESMF_SUCCESS) then
      call diag_bitsum_log('etapa4 Si_ifrac exportState para MPAS', f_bs, rc_bs_2)
    else
      call ESMF_LogWrite('FIX-DIAG-BITSUM-01: etapa4 Si_ifrac ausente do ' // &
        'exportState; etapa NAO medida', ESMF_LOGMSG_WARNING)
    end if
  end subroutine log_ifrac_export_bitsum

  !> Soma um preenchimento por vizinhança à contagem do campo, neste PET.
  !!
  !! @param[inout] c          contagem do campo
  !! @param[in]    n_invalid  pontos fora da faixa válida antes do preenchimento
  !! @param[in]    n_left     pontos que ficaram com o valor fixo
  subroutine registra_completa(c, n_invalid, n_left)
    type(med_completa_t), intent(inout) :: c
    integer,              intent(in)    :: n_invalid, n_left

    c%aplicacoes = c%aplicacoes + 1_ESMF_KIND_I8
    c%invalidos  = c%invalidos  + int(n_invalid, ESMF_KIND_I8)
    c%fixos      = c%fixos      + int(n_left,    ESMF_KIND_I8)
  end subroutine registra_completa

  !> Relatório dos pontos completados, no último passo: soma as contagens
  !! de todos os PETs do mediador e o PET 0 escreve uma linha CPL-REL: por
  !! campo que foi completado alguma vez. Coletiva: todos os PETs do
  !! mediador chamam.
  !!
  !! @param[in]  completa  contagens deste PET (índices COMPL_*)
  !! @param[out] rc        ESMF_SUCCESS, ou o código da redução que falhou
  subroutine relata_completas(completa, rc)
    type(med_completa_t), intent(in)  :: completa(N_COMPLETA)
    integer,              intent(out) :: rc

    type(ESMF_VM) :: vm
    integer :: localPet, k
    integer(ESMF_KIND_I8) :: soma_loc(2*N_COMPLETA), soma(2*N_COMPLETA)
    integer(ESMF_KIND_I8) :: apl_loc(N_COMPLETA), apl(N_COMPLETA)
    character(len=24) :: b1, b2, b3

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMGet(vm, localPet=localPet, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    soma_loc(1:N_COMPLETA)  = completa%invalidos
    soma_loc(N_COMPLETA+1:) = completa%fixos
    apl_loc = completa%aplicacoes
    call ESMF_VMAllReduce(vm, soma_loc, soma, 2*N_COMPLETA, ESMF_REDUCE_SUM, rc=rc)
    if (rc /= ESMF_SUCCESS) return
    call ESMF_VMAllReduce(vm, apl_loc, apl, N_COMPLETA, ESMF_REDUCE_MAX, rc=rc)
    if (rc /= ESMF_SUCCESS .or. localPet /= 0) return

    do k = 1, N_COMPLETA
      if (apl(k) == 0) cycle
      write(b1, '(I0)') apl(k)
      write(b2, '(I0)') soma(k)
      write(b3, '(I0)') soma(N_COMPLETA + k)
      call ESMF_LogWrite('CPL-REL: completar '//trim(COMPLETA_NOMES(k))//': '//trim(b1)// &
        ' aplicacao(oes), '//trim(b2)//' ponto(s) fora da faixa, '//trim(b3)// &
        ' com valor fixo (soma dos PETs)', ESMF_LOGMSG_INFO)
    end do
  end subroutine relata_completas

end module med_diag_mod
