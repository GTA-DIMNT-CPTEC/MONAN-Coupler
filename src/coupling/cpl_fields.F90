!> @file cpl_fields.F90
!! @brief Dicionário dos campos trocados no acoplamento (CAMPOS).
!!
!! Uma linha por nome de campo que aparece no mapa de acoplamento
!! (cpl_map.F90, em TROCAS ou em EXPORTACOES), com a unidade, a convenção
!! de sinal, quando houver, e uma descrição curta. É a referência de "o que
!! é" cada campo; "de onde vem e para onde vai" fica em TROCAS, no mapa.
!!
!! Fontes das unidades e descrições: os metadados que os gravadores de
!! diagnóstico já escrevem (med_cap_netcdf, mpas_cap_netcdf,
!! mpas_import_diag) e os comentários dos caps. A coluna de sinal só é
!! preenchida onde a convenção foi conferida no código:
!!   - Faxa_sen_mpas e Faxa_lat_mpas vêm do 'hfx' e do 'lh' do MONAN-A,
!!     positivos para cima (mpas_cap_methods); o mediador inverte o sinal
!!     ao usá-los (med_flux);
!!   - Foxx_sen e Fioi_sen são calculados em med_bulk_ncar como
!!     ρ cp Ch |V| (Tar - Tsup), positivos para a superfície; o cap do SIS2
!!     inverte o sinal de Fioi_sen ao entregá-lo ao modelo (sis_cap_fields).
!!
!! As descrições são texto sem acentos, como as mensagens do log, para que
!! o comprimento em bytes seja o comprimento em caracteres.
!!
!! Este módulo só descreve: nenhum componente o usa para anunciar ou
!! realizar campos (isso começa na R-FASE11-05). O conteúdo é conferido por
!! tests/unit/test_cpl_map.F90 e publicado em docs/acoplamento.md por
!! tools/dev/mapa-acoplamento.py.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module cpl_fields_mod

  implicit none
  private

  public :: cpl_campo_t
  public :: CAMPOS
  public :: CPL_NOME_LEN
  public :: cpl_campo_indice

  integer, parameter :: CPL_NOME_LEN = 24   !< comprimento dos nomes de campo

  !> Um campo trocado no acoplamento.
  type :: cpl_campo_t
    character(len=CPL_NOME_LEN) :: nome      = ''  !< nome padrão (StandardName)
    character(len=12)           :: unidade   = ''  !< unidade (UDUNITS)
    character(len=48)           :: sinal     = ''  !< convenção de sinal, quando houver
    character(len=64)           :: descricao = ''  !< descrição curta
  end type cpl_campo_t

  !> Dicionário dos campos, agrupado pelo componente que produz o campo.
  type(cpl_campo_t), parameter :: CAMPOS(*) = [                                                          &
    ! Forçantes do MONAN-A (cap atmosférico), com o sufixo _mpas
    cpl_campo_t('Sa_u10m_mpas',   'm s-1',      '', 'vento zonal a 10 m (MONAN-A)'),                          &
    cpl_campo_t('Sa_v10m_mpas',   'm s-1',      '', 'vento meridional a 10 m (MONAN-A)'),                     &
    cpl_campo_t('Sa_tbot_mpas',   'K',          '', 'temperatura do ar a 2 m (MONAN-A)'),                     &
    cpl_campo_t('Sa_pslv_mpas',   'Pa',         '', 'pressao ao nivel do mar (MONAN-A)'),                     &
    cpl_campo_t('Faxa_swdn_mpas', 'W m-2',      '', 'onda curta descendente (MONAN-A)'),                      &
    cpl_campo_t('Faxa_lwdn_mpas', 'W m-2',      '', 'onda longa descendente (MONAN-A)'),                      &
    cpl_campo_t('Faxa_rain_mpas', 'kg m-2 s-1', '', 'precipitacao liquida (MONAN-A)'),                        &
    cpl_campo_t('Sa_shum_mpas',   'kg kg-1',    '', 'umidade especifica a 2 m (MONAN-A)'),                    &
    cpl_campo_t('Faxa_snow_mpas', 'kg m-2 s-1', '', 'precipitacao solida (MONAN-A)'),                         &
    cpl_campo_t('Faxa_sen_mpas',  'W m-2',      'positivo para cima; o mediador inverte',                     &
                'calor sensivel do PBL do MONAN-A (hfx)'),                                                   &
    cpl_campo_t('Faxa_lat_mpas',  'W m-2',      'positivo para cima; o mediador inverte',                     &
                'calor latente do PBL do MONAN-A (lh)'),                                                     &
    cpl_campo_t('Faxa_taux_mpas', 'N m-2',      '', 'tensao zonal do MONAN-A (de ust)'),                      &
    cpl_campo_t('Faxa_tauy_mpas', 'N m-2',      '', 'tensao meridional do MONAN-A (de ust)'),                 &
    ! Forçantes do DATM (JRA55), sem sufixo
    cpl_campo_t('Sa_u10m',        'm s-1',      '', 'vento zonal a 10 m (DATM)'),                             &
    cpl_campo_t('Sa_v10m',        'm s-1',      '', 'vento meridional a 10 m (DATM)'),                        &
    cpl_campo_t('Sa_tbot',        'K',          '', 'temperatura do ar (DATM)'),                              &
    cpl_campo_t('Sa_shum',        'kg kg-1',    '', 'umidade especifica (DATM)'),                             &
    cpl_campo_t('Sa_pslv',        'Pa',         '', 'pressao ao nivel do mar'),                               &
    cpl_campo_t('Faxa_swdn',      'W m-2',      '', 'onda curta descendente (DATM)'),                         &
    cpl_campo_t('Faxa_lwdn',      'W m-2',      '', 'onda longa descendente (DATM)'),                         &
    cpl_campo_t('Faxa_rain',      'kg m-2 s-1', '', 'precipitacao liquida'),                                  &
    cpl_campo_t('Faxa_snow',      'kg m-2 s-1', '', 'precipitacao solida'),                                   &
    ! Oceano (MOM6 ou DOCN)
    cpl_campo_t('So_t',           'K',          '', 'temperatura da superficie do mar'),                      &
    cpl_campo_t('So_u',           'm s-1',      '', 'corrente zonal superficial'),                            &
    cpl_campo_t('So_v',           'm s-1',      '', 'corrente meridional superficial'),                       &
    cpl_campo_t('So_omask',       '1',          '', 'mascara do MOM6 (1 oceano, 0 terra)'),                   &
    cpl_campo_t('So_s',           'psu',        '', 'salinidade da superficie do mar'),                       &
    cpl_campo_t('Fioo_q',         'W m-2',      '', 'potencial de fusao ou congelamento (frazil)'),           &
    cpl_campo_t('Si_ifrac',       '1',          '', 'fracao de gelo, entre 0 e 1'),                           &
    cpl_campo_t('Sf_zorl',        'm',          '', 'rugosidade da superficie'),                              &
    ! Gelo (SIS2), com o sufixo _sis2
    cpl_campo_t('Si_ifrac_sis2',  '1',          '', 'fracao de gelo do SIS2'),                                &
    cpl_campo_t('Si_avsdr_sis2',  '1',          '', 'albedo do gelo, visivel direto'),                        &
    cpl_campo_t('Si_avsdf_sis2',  '1',          '', 'albedo do gelo, visivel difuso'),                        &
    cpl_campo_t('Si_anidr_sis2',  '1',          '', 'albedo do gelo, infravermelho proximo direto'),          &
    cpl_campo_t('Si_anidf_sis2',  '1',          '', 'albedo do gelo, infravermelho proximo difuso'),          &
    cpl_campo_t('Si_t_sis2',      'K',          '', 'temperatura de pele do gelo'),                           &
    ! Calculados pelo mediador: fluxos para o oceano
    cpl_campo_t('Foxx_taux',      'Pa',         '', 'tensao zonal sobre o oceano'),                           &
    cpl_campo_t('Foxx_tauy',      'Pa',         '', 'tensao meridional sobre o oceano'),                      &
    cpl_campo_t('Foxx_sen',       'W m-2',      'positivo para a superficie',                                 &
                'calor sensivel sobre o oceano'),                                                            &
    cpl_campo_t('Foxx_evap',      'kg m-2 s-1', '', 'evaporacao sobre o oceano'),                             &
    cpl_campo_t('Foxx_lwnet',     'W m-2',      '', 'onda longa liquida sobre o oceano'),                     &
    cpl_campo_t('Foxx_swnet_vdr', 'W m-2',      '', 'onda curta liquida, visivel direto'),                    &
    cpl_campo_t('Foxx_swnet_vdf', 'W m-2',      '', 'onda curta liquida, visivel difuso'),                    &
    cpl_campo_t('Foxx_swnet_idr', 'W m-2',      '', 'onda curta liquida, infravermelho direto'),              &
    cpl_campo_t('Foxx_swnet_idf', 'W m-2',      '', 'onda curta liquida, infravermelho difuso'),              &
    cpl_campo_t('So_duu10n',      'm2 s-2',     '', 'quadrado do vento relativo ao oceano'),                  &
    ! Calculados pelo mediador: superfície para a atmosfera e para o gelo
    cpl_campo_t('Sx_tsfc',        'K',          '', 'temperatura de pele composta agua e gelo'),              &
    cpl_campo_t('Sx_omask',       '1',          '', 'mascara do MOM6 na grade da atmosfera'),                 &
    cpl_campo_t('Sf_albedo',      '1',          '', 'albedo de banda larga (agua e gelo)'),                   &
    cpl_campo_t('Faxa_coszen',    '1',          '', 'cosseno do angulo zenital solar'),                       &
    ! Calculados pelo mediador: fluxos para o gelo
    cpl_campo_t('Fioi_taux',      'Pa',         '', 'tensao zonal sobre o gelo'),                             &
    cpl_campo_t('Fioi_tauy',      'Pa',         '', 'tensao meridional sobre o gelo'),                        &
    cpl_campo_t('Fioi_sen',       'W m-2',      'positivo para a superficie; cap do SIS2 inverte',            &
                'calor sensivel sobre o gelo'),                                                              &
    cpl_campo_t('Fioi_evap',      'kg m-2 s-1', '', 'evaporacao sobre o gelo'),                               &
    cpl_campo_t('Fioi_lwnet',     'W m-2',      '', 'onda longa liquida sobre o gelo'),                       &
    cpl_campo_t('Fioi_swnet_vdr', 'W m-2',      '', 'onda curta liquida no gelo, visivel direto'),            &
    cpl_campo_t('Fioi_swnet_vdf', 'W m-2',      '', 'onda curta liquida no gelo, visivel difuso'),            &
    cpl_campo_t('Fioi_swnet_idr', 'W m-2',      '', 'onda curta liquida no gelo, infravermelho direto'),      &
    cpl_campo_t('Fioi_swnet_idf', 'W m-2',      '', 'onda curta liquida no gelo, infravermelho difuso') ]

contains

  !> Posição do campo nome em CAMPOS, ou 0 se ele não estiver no dicionário.
  pure integer function cpl_campo_indice(nome) result(k)
    character(len=*), intent(in) :: nome
    integer :: i

    k = 0
    do i = 1, size(CAMPOS)
      if (trim(CAMPOS(i)%nome) == trim(nome)) then
        k = i
        return
      end if
    end do
  end function cpl_campo_indice

end module cpl_fields_mod
