!> @file test_config.F90
!! @brief Lê um ou mais nuopc.input com config_read e escreve o resultado.
!!
!! Uso: test_config ARQUIVO [ARQUIVO ...]
!!
!! Para cada arquivo, na ordem: chama config_read e escreve, na saída
!! padrão, o código de retorno e o valor de todas as variáveis cfg_*. As
!! mensagens de config_read saem na mesma saída, antes dos valores. Com mais
!! de um arquivo, cada leitura parte dos valores deixados pela anterior,
!! como em config_read. compara-config.bash roda este programa com a versão
!! de um commit e com a da árvore de trabalho e compara as saídas.
program test_config

  use coupler_config_mod

  implicit none

  character(len=512) :: path
  integer :: k, rc

  do k = 1, command_argument_count()
    call get_command_argument(k, path)
    write(*,'(2A)') '== leitura de ', trim(path)
    call config_read(rc, trim(path))
    write(*,'(A,I0)') 'rc = ', rc
    call dump()
  end do

contains

  !> @brief Escreve todas as variáveis cfg_*, uma por linha.
  subroutine dump()
    integer :: i

    call put_s('start_date', cfg_start_date)
    call put_s('stop_date', cfg_stop_date)
    call put_i('dt_coupling', cfg_dt_coupling)
    call put_i('dt_atm', cfg_dt_atm)
    call put_s('log_dir', cfg_log_dir)
    call put_s('log_kind', cfg_log_kind)
    call put_s('log_level', cfg_log_level)
    call put_s('mesh_atm', cfg_mesh_atm)
    call put_s('config_dir', cfg_config_dir)
    call put_l('write_diag', cfg_write_diag)
    call put_l('write_netcdf', cfg_write_netcdf)
    call put_s('output_dir', cfg_output_dir)
    call put_r('grid_res_deg', cfg_grid_res_deg)
    call put_r('sst_default', cfg_sst_default)
    call put_r('ice_fraction_default', cfg_ice_fraction_default)
    call put_r('zorl_default', cfg_zorl_default)
    call put_s('docn_mode', cfg_docn_mode)
    call put_i('docn_nx', cfg_docn_nx)
    call put_i('docn_ny', cfg_docn_ny)
    call put_i('docn_dt_data', cfg_docn_dt_data)
    call put_i('docn_epoch_year', cfg_docn_epoch_year)
    call put_i('docn_epoch_month', cfg_docn_epoch_month)
    call put_i('docn_epoch_day', cfg_docn_epoch_day)
    call put_s('docn_sst_file', cfg_docn_sst_file)
    call put_s('docn_ice_file', cfg_docn_ice_file)
    call put_s('docn_cur_file', cfg_docn_cur_file)
    call put_s('docn_sst_varname', cfg_docn_sst_varname)
    call put_s('docn_ice_varname', cfg_docn_ice_varname)
    call put_s('docn_cur_u_varname', cfg_docn_cur_u_varname)
    call put_s('docn_cur_v_varname', cfg_docn_cur_v_varname)
    call put_l('docn_ice_pct', cfg_docn_ice_pct)
    call put_l('write_import_diag', cfg_write_import_diag)
    call put_s('import_diag_dir', cfg_import_diag_dir)
    call put_s('mom6_mesh_ocn', cfg_mom6_mesh_ocn)
    call put_s('coupling_mode', cfg_coupling_mode)
    call put_s('pet_layout', cfg_pet_layout)
    call put_i('atm_pet_count', cfg_atm_pet_count)
    call put_i('ocn_pet_count', cfg_ocn_pet_count)
    call put_i('ice_pet_count', cfg_ice_pet_count)
    call put_l('use_sis2_dynamic', cfg_use_sis2_dynamic)
    call put_l('seq_repro', cfg_seq_repro)
    call put_l('use_datm', cfg_use_datm)
    call put_l('use_docn', cfg_use_docn)
    call put_l('use_med_to_mpas', cfg_use_med_to_mpas)
    call put_l('use_docn_ice', cfg_use_docn_ice)
    call put_l('docn_ice_init_only', cfg_docn_ice_init_only)
    do i = 1, MAX_REGRID_OVERRIDES
      if (len_trim(cfg_regrid_route(i)) == 0 .and. len_trim(cfg_regrid_scheme(i)) == 0 .and. &
          len_trim(cfg_regrid_methods(i)) == 0 .and. len_trim(cfg_regrid_weights(i)) == 0 .and. &
          len_trim(cfg_regrid_class(i)) == 0 .and. len_trim(cfg_regrid_options(i)) == 0) cycle
      write(*,'(A,I0,13A)') 'regrid(', i, ') = "', trim(cfg_regrid_route(i)), '" "', &
        trim(cfg_regrid_scheme(i)), '" "', trim(cfg_regrid_methods(i)), '" "', &
        trim(cfg_regrid_weights(i)), '" "', trim(cfg_regrid_class(i)), '" "', &
        trim(cfg_regrid_options(i)), '"'
    end do
  end subroutine dump

  !> @brief Escreve uma variável de texto, com o comprimento sem brancos à direita.
  subroutine put_s(name, val)
    character(len=*), intent(in) :: name, val
    write(*,'(4A)') name, ' = "', trim(val), '"'
  end subroutine put_s

  !> @brief Escreve uma variável inteira.
  subroutine put_i(name, val)
    character(len=*), intent(in) :: name
    integer,          intent(in) :: val
    write(*,'(2A,I0)') name, ' = ', val
  end subroutine put_i

  !> @brief Escreve uma variável real pelos seus bits, em hexadecimal, para comparar sem arredondar.
  subroutine put_r(name, val)
    character(len=*), intent(in) :: name
    real,             intent(in) :: val
    write(*,'(2A,Z8.8)') name, ' = ', transfer(val, 0)
  end subroutine put_r

  !> @brief Escreve uma variável lógica.
  subroutine put_l(name, val)
    character(len=*), intent(in) :: name
    logical,          intent(in) :: val
    write(*,'(2A,L1)') name, ' = ', val
  end subroutine put_l

end program test_config
