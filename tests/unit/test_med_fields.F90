!> @file test_med_fields.F90
!! @brief Campos internos do mediador: a tabela MED_FIELDS e as constantes F_*.
!!
!! A física do mediador acessa cada campo interno pela posição dele em
!! MED_FIELDS (fluxes%p(F_TAUX)%a). Este teste confere, sem MPI:
!!
!!   constantes   cada constante F_* é a posição, em MED_FIELDS, do campo
!!                que ela nomeia, e há uma constante por linha da tabela
!!   nomes        nomes de acoplamento e de ESMF_Field sem repetição
!!   zeragem      os campos zerados no início de cada passo
!!                (zero_med_fluxes) são os doze fluxos para o oceano,
!!                So_duu10n e as correntes, os mesmos que a zeragem
!!                escrita campo a campo zerava
!!
!! Para incluir um campo: a linha em MED_FIELDS, a constante F_* e, aqui,
!! uma chamada a check com a constante e o nome.
!!
!! Saída: uma linha PASSOU/FALHOU por caso e, no fim, "TODOS OS TESTES
!! PASSARAM" ou o número de falhas; termina com código 1 se algum falhar.
program test_med_fields
  use med_cap_types_mod, only : MED_FIELDS,  &
                                F_TAUX, F_TAUY, F_SEN, F_EVAP, F_LWNET, F_SWVDR,  &
                                F_SWVDF, F_SWIDR, F_SWIDF, F_RAIN, F_SNOW, F_PSLV,  &
                                F_IFRAC, F_OMASK, F_DUU10N, F_SST, F_UOCN, F_VOCN,  &
                                F_ZORL, F_ALB_VDR, F_ALB_VDF, F_ALB_IDR, F_ALB_IDF, F_COSZEN,  &
                                F_ALBEDO, F_TICE, F_TSFC, F_TAUX_ICE, F_TAUY_ICE, F_SEN_ICE,  &
                                F_EVAP_ICE, F_LWNET_ICE, F_SWVDR_ICE, F_SWVDF_ICE, F_SWIDR_ICE, F_SWIDF_ICE
  implicit none

  character(len=*), parameter :: ZEROED(*) = [character(len=16) :: &
    'Foxx_taux', 'Foxx_tauy', 'Foxx_sen', 'Foxx_evap', 'Foxx_lwnet',  &
    'Foxx_swnet_vdr', 'Foxx_swnet_vdf', 'Foxx_swnet_idr', 'Foxx_swnet_idf', 'Faxa_rain',  &
    'Faxa_snow', 'Sa_pslv', 'So_duu10n', 'So_u', 'So_v']
  integer :: nfailures, nchecked, k, m
  logical :: ok

  nfailures = 0
  nchecked = 0

  call check(F_TAUX,      'Foxx_taux')
  call check(F_TAUY,      'Foxx_tauy')
  call check(F_SEN,       'Foxx_sen')
  call check(F_EVAP,      'Foxx_evap')
  call check(F_LWNET,     'Foxx_lwnet')
  call check(F_SWVDR,     'Foxx_swnet_vdr')
  call check(F_SWVDF,     'Foxx_swnet_vdf')
  call check(F_SWIDR,     'Foxx_swnet_idr')
  call check(F_SWIDF,     'Foxx_swnet_idf')
  call check(F_RAIN,      'Faxa_rain')
  call check(F_SNOW,      'Faxa_snow')
  call check(F_PSLV,      'Sa_pslv')
  call check(F_IFRAC,     'Si_ifrac')
  call check(F_OMASK,     'Sx_omask')
  call check(F_DUU10N,    'So_duu10n')
  call check(F_SST,       'So_t')
  call check(F_UOCN,      'So_u')
  call check(F_VOCN,      'So_v')
  call check(F_ZORL,      'Sf_zorl')
  call check(F_ALB_VDR,   'Si_avsdr_sis2')
  call check(F_ALB_VDF,   'Si_avsdf_sis2')
  call check(F_ALB_IDR,   'Si_anidr_sis2')
  call check(F_ALB_IDF,   'Si_anidf_sis2')
  call check(F_COSZEN,    'Faxa_coszen')
  call check(F_ALBEDO,    'Sf_albedo')
  call check(F_TICE,      'Si_t_sis2')
  call check(F_TSFC,      'Sx_tsfc')
  call check(F_TAUX_ICE,  'Fioi_taux')
  call check(F_TAUY_ICE,  'Fioi_tauy')
  call check(F_SEN_ICE,   'Fioi_sen')
  call check(F_EVAP_ICE,  'Fioi_evap')
  call check(F_LWNET_ICE, 'Fioi_lwnet')
  call check(F_SWVDR_ICE, 'Fioi_swnet_vdr')
  call check(F_SWVDF_ICE, 'Fioi_swnet_vdf')
  call check(F_SWIDR_ICE, 'Fioi_swnet_idr')
  call check(F_SWIDF_ICE, 'Fioi_swnet_idf')
  call outcome('uma constante F_* por linha de MED_FIELDS', nchecked == size(MED_FIELDS))

  ok = .true.
  do k = 1, size(MED_FIELDS)
    do m = k + 1, size(MED_FIELDS)
      if (MED_FIELDS(k)%name == MED_FIELDS(m)%name) ok = .false.
      if (MED_FIELDS(k)%esmf_name == MED_FIELDS(m)%esmf_name) ok = .false.
    end do
  end do
  call outcome('nomes sem repeticao em MED_FIELDS', ok)

  ok = count(MED_FIELDS%zero_each_step) == size(ZEROED)
  do k = 1, size(ZEROED)
    m = findloc(MED_FIELDS%name, ZEROED(k), dim=1)
    if (m == 0) then
      ok = .false.
    else if (.not. MED_FIELDS(m)%zero_each_step) then
      ok = .false.
    end if
  end do
  call outcome('campos zerados a cada passo', ok)

  if (nfailures == 0) then
    write(*, '(A)') 'TODOS OS TESTES PASSARAM'
  else
    write(*, '(I0, A)') nfailures, ' TESTE(S) FALHARAM'
    error stop 1
  end if

contains

  !> Confere que a constante k é a posição do campo name em MED_FIELDS.
  subroutine check(k, name)
    integer,          intent(in) :: k
    character(len=*), intent(in) :: name
    logical :: in_range
    nchecked = nchecked + 1
    in_range = k >= 1 .and. k <= size(MED_FIELDS)
    if (in_range) then
      call outcome('F_* de ' // name, MED_FIELDS(k)%name == name)
    else
      call outcome('F_* de ' // name // ' dentro da tabela', .false.)
    end if
  end subroutine check

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

end program test_med_fields
