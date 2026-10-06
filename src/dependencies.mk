# src/dependencies.mk: dependências entre os fontes do acoplador.
# Gerado por tools/dev/dependencias.py a partir dos 'use' de cada fonte;
# não editar à mão. Depois de mudar um 'use', gerar de novo com
#   tools/dev/dependencias.py gera
# A conferência 'dependencias' do tools/dev/confere-tudo.bash acusa um
# arquivo desatualizado.
$(OBJDIR)/cap_common.o: $(OBJDIR)/coupler_utils.o
$(OBJDIR)/coupler_config.o: $(OBJDIR)/coupler_utils.o
$(OBJDIR)/cpl_check.o: $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o
$(OBJDIR)/cpl_grids.o: $(OBJDIR)/coupler_utils.o $(OBJDIR)/mom6_supergrid.o
$(OBJDIR)/cpl_map.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/regrid_base.o
$(OBJDIR)/DATM_cap.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o
$(OBJDIR)/DOCN_cap.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o $(OBJDIR)/docn_cap_netcdf.o
$(OBJDIR)/docn_cap_netcdf.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/esm.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_check.o $(OBJDIR)/cpl_map.o $(OBJDIR)/DOCN_cap.o $(OBJDIR)/MED_cap.o $(OBJDIR)/mom_cap_MONAN.o $(OBJDIR)/mpas_cap_MONAN.o $(OBJDIR)/sis_cap_MONAN.o
$(OBJDIR)/esmApp.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/esm.o
$(OBJDIR)/med_bulk_ncar.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_types.o
$(OBJDIR)/MED_cap.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o $(OBJDIR)/med_cap_netcdf.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o $(OBJDIR)/med_exchange.o $(OBJDIR)/med_flux.o $(OBJDIR)/med_init.o $(OBJDIR)/mom6_supergrid.o
$(OBJDIR)/med_cap_methods.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_map.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_cap_netcdf.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/med_cap_types.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_diag.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/diag_bitsum.o $(OBJDIR)/med_cap_types.o
$(OBJDIR)/med_exchange.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_map.o $(OBJDIR)/med_bulk_ncar.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_export.o $(OBJDIR)/med_ocean.o
$(OBJDIR)/med_export.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o
$(OBJDIR)/med_flux.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o
$(OBJDIR)/med_ice.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/diag_bitsum.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_init.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/cpl_map.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o
$(OBJDIR)/med_ocean.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o $(OBJDIR)/med_ice.o
$(OBJDIR)/mom_cap_methods.o: $(OBJDIR)/mom_ocean_model_nuopc.o $(OBJDIR)/mom_surface_forcing_nuopc.o
$(OBJDIR)/mom_cap_MONAN.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/cpl_map.o $(OBJDIR)/mom_cap_methods.o $(OBJDIR)/mom_ocean_model_nuopc.o $(OBJDIR)/mom_si_ifrac.o $(OBJDIR)/mom_surface_forcing_nuopc.o $(OBJDIR)/time_utils.o
$(OBJDIR)/mom_ocean_model_nuopc.o: $(OBJDIR)/mom_surface_forcing_nuopc.o
$(OBJDIR)/mom_si_ifrac.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/docn_cap_netcdf.o $(OBJDIR)/mom_cap_methods.o $(OBJDIR)/mom_ocean_model_nuopc.o
$(OBJDIR)/mpas_adapter.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpas_atm_types.o $(OBJDIR)/mpas_cap_netcdf.o $(OBJDIR)/mpas_cell_binning.o $(OBJDIR)/mpas_import_diag.o
$(OBJDIR)/mpas_atm_fluxes.o: $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_atm_model.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/mpas_atm_fluxes.o $(OBJDIR)/mpas_atm_setup.o $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_atm_setup.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_cap_MONAN.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o $(OBJDIR)/mpas_adapter.o $(OBJDIR)/mpas_atm_model.o $(OBJDIR)/mpas_atm_types.o $(OBJDIR)/mpas_cap_netcdf.o $(OBJDIR)/mpas_import_diag.o
$(OBJDIR)/mpas_cap_netcdf.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpi_allreduce_wrappers.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/mpas_cell_binning.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_import_diag.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpas_atm_types.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/mpi_allreduce_wrappers.o: $(OBJDIR)/mpi_allreduce_i4.o $(OBJDIR)/mpi_allreduce_r8.o
$(OBJDIR)/regrid_esmf.o: $(OBJDIR)/regrid_base.o
$(OBJDIR)/regrid_idw.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_weights_base.o
$(OBJDIR)/regrid_manager.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_registry.o
$(OBJDIR)/regrid_mpassit.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_esmf.o
$(OBJDIR)/regrid_registry.o: $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_schemes.o
$(OBJDIR)/regrid_schemes.o: $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_esmf.o $(OBJDIR)/regrid_idw.o $(OBJDIR)/regrid_mpassit.o $(OBJDIR)/regrid_weights.o
$(OBJDIR)/regrid_weights.o: $(OBJDIR)/regrid_base.o
$(OBJDIR)/regrid_weights_base.o: $(OBJDIR)/regrid_base.o
$(OBJDIR)/sis_cap_fields.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o
$(OBJDIR)/sis_cap_MONAN.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/cpl_map.o $(OBJDIR)/mom6_supergrid.o $(OBJDIR)/sis_cap_fields.o $(OBJDIR)/time_utils.o
$(OBJDIR)/time_utils.o: $(OBJDIR)/mom_cap_methods.o
