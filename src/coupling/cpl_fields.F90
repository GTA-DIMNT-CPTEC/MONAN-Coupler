!> @file cpl_fields.F90
!! @brief Dicionário dos campos trocados no acoplamento (FIELDS).
!!
!! Uma linha por nome de campo que aparece no mapa de acoplamento
!! (cpl_map.F90, em EXCHANGES ou em EXPORTS), com a unidade, a convenção
!! de sinal, quando houver, e uma descrição curta. É a referência de "o que
!! é" cada campo; "de onde vem e para onde vai" fica em EXCHANGES, no mapa.
!!
!! Fontes das unidades e descrições: os metadados que os gravadores de
!! diagnóstico já escrevem (med_cap_netcdf, mpas_cap_netcdf,
!! mpas_import_diag) e os comentários dos caps. A coluna de sinal só é
!! preenchida onde a convenção foi conferida no código:
!!   - Faxa_sen_mpas e Faxa_lat_mpas vêm do 'hfx' e do 'lh' do MONAN-A,
!!     positivos para cima (mpas_adapter); o mediador inverte o sinal
!!     ao usá-los (med_flux);
!!   - Foxx_sen e Fioi_sen são calculados em med_bulk_ncar como
!!     ρ cp Ch |V| (Tar - Tsup), positivos para a superfície; o cap do SIS2
!!     inverte o sinal de Fioi_sen ao entregá-lo ao modelo (sis_cap_fields).
!!
!! As descrições são texto sem acentos, como as mensagens do log, para que
!! o comprimento em bytes seja o comprimento em caracteres.
!!
!! Nome longo e nome CF (colunas long_name e cf_name): os atributos
!! long_name e standard_name que os gravadores de diagnóstico do mediador
!! (mom6_import_*.nc, med_cap_netcdf) e da exportação do MONAN-A
!! (monan_export_*.nc, mpas_cap_netcdf) escrevem, com a unidade da coluna
!! units; os dois os obtêm por cpl_field_attributes. Os textos são os que
!! esses gravadores sempre escreveram. Campo sem nome longo sai com os
!! atributos padrão (units '1', long_name igual ao nome, standard_name
!! 'unknown'), como antes. Dois gravadores têm textos próprios para os
!! campos que escrevem e não consultam o dicionário: o da importação do
!! MONAN-A (monan2_import_*.nc, mpas_import_diag) e o do DOCN
!! (docn_import_*.nc, docn_cap_netcdf); as diferenças em relação a esta
!! tabela estão registradas em docs/estado-do-projeto.md e ficam até uma
!! decisão do GT.
!!
!! Este módulo não decide o que é anunciado (isso sai do mapa):
!! cpl_nuopc_dictionary (cpl_check) registra estes nomes, com a unidade, no
!! dicionário do NUOPC, e um nome fora de FIELDS para a rodada no anúncio.
!! O conteúdo é conferido por tests/unit/test_cpl_map.F90 e publicado em
!! docs/acoplamento.md por tools/dev/mapa-acoplamento.py.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module cpl_fields_mod

  implicit none
  private

  public :: cpl_field_t
  public :: FIELDS
  public :: CPL_NAME_LEN
  public :: cpl_field_index
  public :: cpl_field_attributes

  integer, parameter :: CPL_NAME_LEN = 24   !< comprimento dos nomes de campo

  !> Um campo trocado no acoplamento.
  type :: cpl_field_t
    character(len=CPL_NAME_LEN) :: name      = ''  !< nome padrão (StandardName)
    character(len=12)           :: units     = ''  !< unidade (UDUNITS)
    character(len=48)           :: sign_conv = ''  !< convenção de sinal, quando houver
    character(len=64)           :: description = ''  !< descrição curta
    character(len=64)           :: long_name = ''  !< atributo long_name nos diagnósticos NetCDF
    character(len=48)           :: cf_name   = ''  !< atributo standard_name (CF) nos diagnósticos
  end type cpl_field_t

  !> Dicionário dos campos, agrupado pelo componente que produz o campo.
  type(cpl_field_t), parameter :: FIELDS(*) = [                                                          &
    ! Forçantes do MONAN-A (cap atmosférico), com o sufixo _mpas
    cpl_field_t('Sa_u10m_mpas',   'm s-1',      '', 'vento zonal a 10 m (MONAN-A)',                      &
                long_name='Vento zonal a 10 m',                                                          &
                cf_name='eastward_wind'),                                                                &
    cpl_field_t('Sa_v10m_mpas',   'm s-1',      '', 'vento meridional a 10 m (MONAN-A)',                 &
                long_name='Vento meridional a 10 m',                                                     &
                cf_name='northward_wind'),                                                               &
    cpl_field_t('Sa_tbot_mpas',   'K',          '', 'temperatura do ar a 2 m (MONAN-A)',                 &
                long_name='Temperatura do ar a 2 m',                                                     &
                cf_name='air_temperature'),                                                              &
    cpl_field_t('Sa_pslv_mpas',   'Pa',         '', 'pressao ao nivel do mar (MONAN-A)',                 &
                long_name='Pressao ao nivel do mar',                                                     &
                cf_name='air_pressure_at_mean_sea_level'),                                               &
    cpl_field_t('Faxa_swdn_mpas', 'W m-2',      '', 'onda curta descendente (MONAN-A)',                  &
                long_name='Radiacao SW descendente media no intervalo',                                  &
                cf_name='surface_downwelling_shortwave_flux_in_air'),                                    &
    cpl_field_t('Faxa_lwdn_mpas', 'W m-2',      '', 'onda longa descendente (MONAN-A)',                  &
                long_name='Radiacao LW descendente media no intervalo',                                  &
                cf_name='surface_downwelling_longwave_flux_in_air'),                                     &
    cpl_field_t('Faxa_rain_mpas', 'kg m-2 s-1', '', 'precipitacao liquida (MONAN-A)',                    &
                long_name='Precipitacao liquida media no intervalo',                                     &
                cf_name='rainfall_flux'),                                                                &
    cpl_field_t('Sa_shum_mpas',   'kg kg-1',    '', 'umidade especifica a 2 m (MONAN-A)',                &
                long_name='Umidade especifica a 2 m',                                                    &
                cf_name='specific_humidity'),                                                            &
    cpl_field_t('Faxa_snow_mpas', 'kg m-2 s-1', '', 'precipitacao solida (MONAN-A)',                     &
                long_name='Precipitacao solida (neve) media no intervalo',                               &
                cf_name='snowfall_flux'),                                                                &
    cpl_field_t('Faxa_sen_mpas',  'W m-2',      'positivo para cima; o mediador inverte',                &
                'calor sensivel do PBL do MONAN-A (hfx)'),                                               &
    cpl_field_t('Faxa_lat_mpas',  'W m-2',      'positivo para cima; o mediador inverte',                &
                'calor latente do PBL do MONAN-A (lh)'),                                                 &
    cpl_field_t('Faxa_taux_mpas', 'N m-2',      '', 'tensao zonal do MONAN-A (de ust)'),                 &
    cpl_field_t('Faxa_tauy_mpas', 'N m-2',      '', 'tensao meridional do MONAN-A (de ust)'),            &
    ! Forçantes do DATM (JRA55), sem sufixo
    cpl_field_t('Sa_u10m',        'm s-1',      '', 'vento zonal a 10 m (DATM)'),                        &
    cpl_field_t('Sa_v10m',        'm s-1',      '', 'vento meridional a 10 m (DATM)'),                   &
    cpl_field_t('Sa_tbot',        'K',          '', 'temperatura do ar (DATM)'),                         &
    cpl_field_t('Sa_shum',        'kg kg-1',    '', 'umidade especifica (DATM)'),                        &
    cpl_field_t('Sa_pslv',        'Pa',         '', 'pressao ao nivel do mar',                           &
                long_name='Pressao nivel do mar',                                                        &
                cf_name='air_pressure_at_mean_sea_level'),                                               &
    cpl_field_t('Faxa_swdn',      'W m-2',      '', 'onda curta descendente (DATM)'),                    &
    cpl_field_t('Faxa_lwdn',      'W m-2',      '', 'onda longa descendente (DATM)'),                    &
    cpl_field_t('Faxa_rain',      'kg m-2 s-1', '', 'precipitacao liquida',                              &
                long_name='Precipitacao liquida',                                                        &
                cf_name='rainfall_flux'),                                                                &
    cpl_field_t('Faxa_snow',      'kg m-2 s-1', '', 'precipitacao solida',                               &
                long_name='Precipitacao solida',                                                         &
                cf_name='snowfall_flux'),                                                                &
    ! Oceano (MOM6 ou DOCN)
    cpl_field_t('So_t',           'K',          '', 'temperatura da superficie do mar',                  &
                long_name='SST dinamica MOM6',                                                           &
                cf_name='sea_surface_temperature'),                                                      &
    cpl_field_t('So_u',           'm s-1',      '', 'corrente zonal superficial',                        &
                long_name='Corrente zonal superficial',                                                  &
                cf_name='surface_eastward_sea_water_velocity'),                                          &
    cpl_field_t('So_v',           'm s-1',      '', 'corrente meridional superficial',                   &
                long_name='Corrente meridional superficial',                                             &
                cf_name='surface_northward_sea_water_velocity'),                                         &
    cpl_field_t('So_omask',       '1',          '', 'mascara do MOM6 (1 oceano, 0 terra)'),              &
    cpl_field_t('So_s',           'psu',        '', 'salinidade da superficie do mar'),                  &
    cpl_field_t('Fioo_q',         'W m-2',      '', 'potencial de fusao ou congelamento (frazil)'),      &
    cpl_field_t('Si_ifrac',       '1',          '', 'fracao de gelo, entre 0 e 1',                       &
                long_name='Fracao de gelo marinho',                                                      &
                cf_name='sea_ice_area_fraction'),                                                        &
    cpl_field_t('Sf_zorl',        'm',          '', 'rugosidade da superficie',                          &
                long_name='Rugosidade superficial Charnock',                                             &
                cf_name='surface_roughness_length'),                                                     &
    ! Gelo (SIS2), com o sufixo _sis2
    cpl_field_t('Si_ifrac_sis2',  '1',          '', 'fracao de gelo do SIS2'),                           &
    cpl_field_t('Si_avsdr_sis2',  '1',          '', 'albedo do gelo, visivel direto'),                   &
    cpl_field_t('Si_avsdf_sis2',  '1',          '', 'albedo do gelo, visivel difuso'),                   &
    cpl_field_t('Si_anidr_sis2',  '1',          '', 'albedo do gelo, infravermelho proximo direto'),     &
    cpl_field_t('Si_anidf_sis2',  '1',          '', 'albedo do gelo, infravermelho proximo difuso'),     &
    cpl_field_t('Si_t_sis2',      'K',          '', 'temperatura de pele do gelo'),                      &
    ! Calculados pelo mediador: fluxos para o oceano
    cpl_field_t('Foxx_taux',      'Pa',         '', 'tensao zonal sobre o oceano',                       &
                long_name='Tensao cisalhamento zonal',                                                   &
                cf_name='surface_downward_eastward_stress'),                                             &
    cpl_field_t('Foxx_tauy',      'Pa',         '', 'tensao meridional sobre o oceano',                  &
                long_name='Tensao cisalhamento meridional',                                              &
                cf_name='surface_downward_northward_stress'),                                            &
    cpl_field_t('Foxx_sen',       'W m-2',      'positivo para a superficie',                            &
                'calor sensivel sobre o oceano',                                                         &
                long_name='Fluxo de calor sensivel',                                                     &
                cf_name='surface_upward_sensible_heat_flux'),                                            &
    cpl_field_t('Foxx_evap',      'kg m-2 s-1', '', 'evaporacao sobre o oceano',                         &
                long_name='Fluxo de evaporacao',                                                         &
                cf_name='water_evaporation_flux'),                                                       &
    cpl_field_t('Foxx_lwnet',     'W m-2',      '', 'onda longa liquida sobre o oceano',                 &
                long_name='Balanco onda longa',                                                          &
                cf_name='surface_net_downward_longwave_flux'),                                           &
    cpl_field_t('Foxx_swnet_vdr', 'W m-2',      '', 'onda curta liquida, visivel direto',                &
                long_name='Onda curta vis. direto',                                                      &
                cf_name='surface_net_downward_shortwave_flux'),                                          &
    cpl_field_t('Foxx_swnet_vdf', 'W m-2',      '', 'onda curta liquida, visivel difuso',                &
                long_name='Onda curta vis. difuso',                                                      &
                cf_name='surface_net_downward_shortwave_flux'),                                          &
    cpl_field_t('Foxx_swnet_idr', 'W m-2',      '', 'onda curta liquida, infravermelho direto',          &
                long_name='Onda curta IR direto',                                                        &
                cf_name='surface_net_downward_shortwave_flux'),                                          &
    cpl_field_t('Foxx_swnet_idf', 'W m-2',      '', 'onda curta liquida, infravermelho difuso',          &
                long_name='Onda curta IR difuso',                                                        &
                cf_name='surface_net_downward_shortwave_flux'),                                          &
    cpl_field_t('So_duu10n',      'm2 s-2',     '', 'quadrado do vento relativo ao oceano',              &
                long_name='Vento relativo ao oceano^2',                                                  &
                cf_name='square_of_air_velocity'),                                                       &
    ! Calculados pelo mediador: superfície para a atmosfera e para o gelo
    cpl_field_t('Sx_tsfc',        'K',          '', 'temperatura de pele composta agua e gelo',          &
                long_name='Temperatura de superficie (pele)',                                            &
                cf_name='surface_temperature'),                                                          &
    cpl_field_t('Sx_omask',       '1',          '', 'mascara do MOM6 na grade da atmosfera',             &
                long_name='Mascara oceano/terra do MOM6 (1=oceano, 0=terra)',                            &
                cf_name='sea_binary_mask'),                                                              &
    cpl_field_t('Sf_albedo',      '1',          '', 'albedo de banda larga (agua e gelo)',               &
                long_name='Albedo de banda larga efetivo (agua+gelo)',                                   &
                cf_name='surface_albedo'),                                                               &
    cpl_field_t('Faxa_coszen',    '1',          '', 'cosseno do angulo zenital solar',                   &
                long_name='Cosseno do angulo zenital solar',                                             &
                cf_name='cosine_of_solar_zenith_angle'),                                                 &
    ! Calculados pelo mediador: fluxos para o gelo
    cpl_field_t('Fioi_taux',      'Pa',         '', 'tensao zonal sobre o gelo',                         &
                long_name='Tensao cisalhamento zonal (gelo, T_gelo)',                                    &
                cf_name='surface_downward_eastward_stress'),                                             &
    cpl_field_t('Fioi_tauy',      'Pa',         '', 'tensao meridional sobre o gelo',                    &
                long_name='Tensao cisalhamento meridional (gelo, T_gelo)',                               &
                cf_name='surface_downward_northward_stress'),                                            &
    cpl_field_t('Fioi_sen',       'W m-2',      'positivo para a superficie; cap do SIS2 inverte',       &
                'calor sensivel sobre o gelo',                                                           &
                long_name='Fluxo de calor sensivel (gelo, T_gelo)',                                      &
                cf_name='surface_upward_sensible_heat_flux'),                                            &
    cpl_field_t('Fioi_evap',      'kg m-2 s-1', '', 'evaporacao sobre o gelo',                           &
                long_name='Fluxo de evaporacao (gelo, T_gelo)',                                          &
                cf_name='water_evaporation_flux'),                                                       &
    cpl_field_t('Fioi_lwnet',     'W m-2',      '', 'onda longa liquida sobre o gelo',                   &
                long_name='Balanco onda longa (gelo, T_gelo)',                                           &
                cf_name='surface_net_downward_longwave_flux'),                                           &
    cpl_field_t('Fioi_swnet_vdr', 'W m-2',      '', 'onda curta liquida no gelo, visivel direto',        &
                long_name='Onda curta vis. direto (gelo)',                                               &
                cf_name='surface_net_downward_shortwave_flux'),                                          &
    cpl_field_t('Fioi_swnet_vdf', 'W m-2',      '', 'onda curta liquida no gelo, visivel difuso',        &
                long_name='Onda curta vis. difuso (gelo)',                                               &
                cf_name='surface_net_downward_shortwave_flux'),                                          &
    cpl_field_t('Fioi_swnet_idr', 'W m-2',      '', 'onda curta liquida no gelo, infravermelho direto',  &
                long_name='Onda curta IR direto (gelo)',                                                 &
                cf_name='surface_net_downward_shortwave_flux'),                                          &
    cpl_field_t('Fioi_swnet_idf', 'W m-2',      '', 'onda curta liquida no gelo, infravermelho difuso',  &
                long_name='Onda curta IR difuso (gelo)',                                                 &
                cf_name='surface_net_downward_shortwave_flux') ]

contains

  !> @brief Posição do campo name em FIELDS, ou 0 se ele não estiver no dicionário.
  pure integer function cpl_field_index(name) result(k)
    character(len=*), intent(in) :: name
    integer :: i

    k = 0
    do i = 1, size(FIELDS)
      if (trim(FIELDS(i)%name) == trim(name)) then
        k = i
        return
      end if
    end do
  end function cpl_field_index

  !> @brief Atributos NetCDF de um campo nos diagnósticos: units, long_name e
  !! standard_name.
  !!
  !! Com nome longo no dicionário, os três vêm de FIELDS (units, long_name e
  !! cf_name); senão, são os padrões: '1', o próprio nome e 'unknown'. Os
  !! textos são atribuídos às variáveis de quem chama, com o comprimento
  !! delas.
  !! @param[in]  name           nome do campo
  !! @param[out] units          atributo units
  !! @param[out] long_name      atributo long_name
  !! @param[out] standard_name  atributo standard_name
  pure subroutine cpl_field_attributes(name, units, long_name, standard_name)
    character(len=*), intent(in)  :: name
    character(len=*), intent(out) :: units, long_name, standard_name
    integer :: k

    k = cpl_field_index(name)
    if (k > 0) then
      if (len_trim(FIELDS(k)%long_name) > 0) then
        units         = FIELDS(k)%units
        long_name     = FIELDS(k)%long_name
        standard_name = FIELDS(k)%cf_name
        return
      end if
    end if
    units         = '1'
    long_name     = trim(name)
    standard_name = 'unknown'
  end subroutine cpl_field_attributes

end module cpl_fields_mod
