# =============================================================================
# Makefile: MONAN-A 2.0 x MOM6+SIS2 / NUOPC-ESMF 8.9.1
# GT Acoplamento de Modelos / INPE / CGCT / DIMNT
#
# Compila o acoplador bin/esmApp. Os modelos (MONAN-A, MOM6+SIS2, FMS) já
# devem estar instalados; ver run/setenv-gnu.bash.
#
#   make            compila bin/esmApp
#   make clean      remove build/ e bin/
#   make distclean  clean + scripts PBS e bibliotecas instaladas (lib/ mod/)
#   make rebuild    clean + all
#   make check      verifica se os fontes existem
#   make test       compila e executa os testes de tests/regrid
#   make printenv   mostra as variáveis de compilação
#   make help       lista os alvos
#
# Para acrescentar um fonte: incluí-lo em OBJS e declarar, na seção
# "Dependências entre módulos", os módulos do projeto que ele usa.
# =============================================================================

VERSION := 16.2

# O Cray XD 2000 exporta MAKEFLAGS=-e (o ambiente sobreporia as atribuições).
MAKEFLAGS := $(filter-out -e,$(MAKEFLAGS))

ifndef ESMFMKFILE
  $(error ESMFMKFILE não definido. Execute: source run/setenv-gnu.bash)
endif
ifndef MPAS_DIR
  $(error MPAS_DIR não definido. Execute: source run/setenv-gnu.bash)
endif
ifndef MOM6_LIBDIR
  $(error MOM6_LIBDIR não definido. Execute: source run/setenv-gnu.bash)
endif

# 'all' antes do include, para continuar sendo o alvo padrão.
.PHONY: all dirs clean distclean rebuild check test printenv help
all: bin/esmApp
	@echo ""
	@echo "  OK: bin/esmApp gerado com sucesso."
	@echo ""

include $(ESMFMKFILE)

# -----------------------------------------------------------------------------
# Diretórios
# ('override' protege contra atribuições vindas do esmf.mk ou do ambiente;
#  não usar comentário na mesma linha, pois o espaço entraria no valor)
# -----------------------------------------------------------------------------
override SRCDIR  := src
override OBJDIR  := build/obj
override MODDIR  := build/mod
override BINDIR  := bin
SRC_SUBDIRS := shared regrid coupling caps/atmos caps/ocean caps/ocean/upstream caps/ice \
               mediator driver main
vpath %.F90 $(addprefix $(SRCDIR)/,$(SRC_SUBDIRS))

# -----------------------------------------------------------------------------
# Bibliotecas instaladas
# -----------------------------------------------------------------------------
# MONAN-A: 1-install-monan.bash reúne .mod e .a em mod/monan2 e lib/monan2,
# irmãos do diretório pai de MPAS_DIR.
COUPLER_ROOT  := $(patsubst %/,%,$(dir $(patsubst %/,%,$(MPAS_DIR))))
MONAN2_MODDIR ?= $(COUPLER_ROOT)/mod/monan2
MONAN2_LIBDIR ?= $(COUPLER_ROOT)/lib/monan2

# MOM6+SIS2, FMS e o cap NUOPC do MOM6 derivam de MOM6_LIBDIR.
MOM6_BASE    := $(patsubst %/lib/mom6,%,$(MOM6_LIBDIR))
MOM6_MODDIR  ?= $(MOM6_BASE)/mod/mom6
MOM6_INCDIR  ?= $(MOM6_BASE)/include/mom6
FMS_LIBDIR   ?= $(MOM6_BASE)/lib/fms
FMS_MODDIR   ?= $(MOM6_BASE)/mod/fms
FMS_INCDIR   ?= $(MOM6_BASE)/include/fms
NUOPC_LIBDIR ?= $(MOM6_BASE)/lib/nuopc
NUOPC_MODDIR ?= $(MOM6_BASE)/mod/nuopc
NUOPC_INCDIR ?= $(MOM6_BASE)/include/nuopc
PNETCDF_DIR  ?= /opt/cray/pe/parallel-netcdf/1.12.3.15/GNU/12.3

# MOAB: o ESMF padrão já o embute. USE_EXTERNAL_MOAB=yes (com MOAB_DIR) só se
# o ESMF foi compilado com ESMF_MOAB=external. Conferir com:
#   ldd "$$ESMF_LIBDIR/libesmf.so" | grep -i moab
USE_EXTERNAL_MOAB ?= no
ifeq ($(USE_EXTERNAL_MOAB),yes)
  ifndef MOAB_DIR
    $(error USE_EXTERNAL_MOAB=yes exige MOAB_DIR)
  endif
  MOAB_INC := -I$(MOAB_DIR)/include
  MOAB_LIB := -L$(MOAB_DIR)/lib -lMOAB
endif

# -I<dir> apenas se <dir> existir (evita -Wmissing-include-dirs)
inc_if_exists = $(if $(wildcard $(1)/.),-I$(1))

# -----------------------------------------------------------------------------
# Opções de compilação
# -----------------------------------------------------------------------------
FC := $(ESMF_F90COMPILER)

# Fusão de multiplicação e soma (FMA). Desligada por padrão: com ela o
# compilador decide onde usar 'a*b+c' com um único arredondamento conforme a
# organização do código, e uma refatoração sem nenhuma mudança de cálculo
# altera o último bit do resultado (medido na etapa R-FASE2A-01; sem FMA, o
# código refatorado reproduz o original bit a bit). Custo medido: nenhum
# (rodada de 1 dia, 152 PETs: 142,5 s sem FMA contra 144,4 s com FMA).
# Vale só para o código do acoplador; MPAS, MOM6 e SIS2 não são recompilados.
# Para ligar:  make FP_CONTRACT=fast   (exige linha de base própria)
FP_CONTRACT ?= off

F90FLAGS := $(ESMF_F90COMPILEOPTS) $(ESMF_F90COMPILEPATHS) $(ESMF_F90COMPILEFREENOCPP) \
            -I$(MONAN2_MODDIR) -I$(MODDIR) -J$(MODDIR)                              \
            -I$(MOM6_MODDIR) -I$(FMS_MODDIR) -I$(NUOPC_MODDIR)                      \
            $(call inc_if_exists,$(MOM6_INCDIR)) $(call inc_if_exists,$(FMS_INCDIR)) \
            $(call inc_if_exists,$(NUOPC_INCDIR)) $(MOAB_INC)                       \
            -I$(PNETCDF_DIR)/include $(MOM6_HDR_INC)                                \
            -ffree-form -ffree-line-length-none -fopenmp -fallow-argument-mismatch  \
            -ffpe-summary=none -O2 -ffp-contract=$(FP_CONTRACT) -g -fcheck=all -fbacktrace \
            -Wall -Wno-unused-dummy-argument

# Fontes ligados ao MOM6/FMS: a biblioteca usa real de 8 bytes e os caps do
# MOM6 declaram 'real' sem kind. Não aplicar aos demais (usam kind explícito).
MOM6_SRCS    := mom_surface_forcing_nuopc mom_ocean_model_nuopc mom_cap_methods \
                time_utils mom_si_ifrac mom_cap_MONAN sis_cap_fields sis_cap_MONAN
MOM6_FCFLAGS := $(F90FLAGS) -fdefault-real-8 -fdefault-double-8 -Wno-unused-function \
                -Wno-character-truncation -Wno-maybe-uninitialized -Wno-unused-variable

# -----------------------------------------------------------------------------
# Ligação
# -----------------------------------------------------------------------------
# As 6 bibliotecas do MONAN-A têm dependências circulares: --start/--end-group.
MPAS_LIBS := -L$(MONAN2_LIBDIR) -Wl,--start-group \
             -lframework -ldycore -lphys -lops -lsmiolf -lsmiol -Wl,--end-group

# Objetos do MOM6 standalone, sem os programas principais.
MOM6_LIB_OBJS := $(filter-out $(addprefix $(MOM6_LIBDIR)/,MOM_main.o coupler_main.o MOM_driver.o), \
                 $(wildcard $(MOM6_LIBDIR)/*.o))
MOM6_LIBS := $(MOM6_LIB_OBJS) -L$(NUOPC_LIBDIR) -lmom6_nuopc -L$(FMS_LIBDIR) -lfms \
             $(MOAB_LIB) -L$(PNETCDF_DIR)/lib -lpnetcdf

ifdef ESMF_F90LINK
  ESMF_LIBS := $(ESMF_F90LINK)
else
  ESMF_LIBS := $(ESMF_F90LINKOPTS) $(ESMF_F90LINKPATHS) $(ESMF_F90LINKRPATHS) \
               $(ESMF_F90ESMFLINKLIBS)
endif
LDLIBS := $(MPAS_LIBS) $(ESMF_LIBS) $(MOM6_LIBS) -lz -ldl -lm -lgomp

# -----------------------------------------------------------------------------
# Objetos (a ordem de compilação vem das dependências abaixo)
# -----------------------------------------------------------------------------
SRCS := coupler_utils coupler_constants coupler_config diag_bitsum        \
        mom6_supergrid nc_writer cap_common                               \
        regrid_base regrid_esmf regrid_weights regrid_mpassit             \
        regrid_registry regrid_manager                                    \
        cpl_grids cpl_fields cpl_map cpl_check                            \
        mpi_allreduce_r8 mpi_allreduce_i4 mpi_allreduce_wrappers          \
        mpas_atm_types mpas_atm_setup mpas_atm_fluxes mpas_atm_model      \
        mpas_cap_netcdf mpas_import_diag mpas_cell_binning mpas_cap_methods \
        mpas_cap_MONAN DATM_cap                                           \
        docn_cap_netcdf DOCN_cap                                          \
        mom_surface_forcing_nuopc mom_ocean_model_nuopc mom_cap_methods   \
        time_utils mom_si_ifrac mom_cap_MONAN sis_cap_fields sis_cap_MONAN \
        med_cap_types med_cap_netcdf med_cap_methods                      \
        med_bulk_ncar med_diag med_ice med_ocean med_init med_flux        \
        med_export MED_cap                                                \
        esm esmApp
OBJS := $(SRCS:%=$(OBJDIR)/%.o)

dirs:
	@mkdir -p $(OBJDIR) $(MODDIR) $(BINDIR)

bin/esmApp: $(OBJS) | dirs
	$(FC) -o $@ $(OBJS) $(LDLIBS)

$(OBJDIR)/%.o: %.F90 | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# Fontes ligados ao MOM6: regra própria. Não usar variável por alvo
# ('alvo: F90FLAGS := ...'): o make a repassa às dependências construídas a
# partir desse alvo, e com 'make -j' um fonte da atmosfera ou do mediador
# poderia ser compilado com -fdefault-real-8.
$(MOM6_SRCS:%=$(OBJDIR)/%.o): $(OBJDIR)/%.o: %.F90 | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

# -----------------------------------------------------------------------------
# Dependências entre módulos (quem usa quem, dentro do projeto)
# -----------------------------------------------------------------------------
$(OBJDIR)/cap_common.o: $(OBJDIR)/coupler_utils.o
$(OBJDIR)/coupler_config.o: $(OBJDIR)/coupler_utils.o
$(OBJDIR)/cpl_check.o: $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o
$(OBJDIR)/cpl_grids.o: $(OBJDIR)/coupler_utils.o $(OBJDIR)/mom6_supergrid.o
$(OBJDIR)/cpl_map.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/regrid_base.o
$(OBJDIR)/DATM_cap.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o
$(OBJDIR)/DOCN_cap.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o $(OBJDIR)/docn_cap_netcdf.o
$(OBJDIR)/docn_cap_netcdf.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/esm.o: $(OBJDIR)/DOCN_cap.o $(OBJDIR)/MED_cap.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_check.o $(OBJDIR)/mom_cap_MONAN.o $(OBJDIR)/mpas_cap_MONAN.o $(OBJDIR)/sis_cap_MONAN.o
$(OBJDIR)/esmApp.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/esm.o
$(OBJDIR)/med_bulk_ncar.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_types.o
$(OBJDIR)/MED_cap.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o $(OBJDIR)/med_bulk_ncar.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_netcdf.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o $(OBJDIR)/med_export.o $(OBJDIR)/med_flux.o $(OBJDIR)/med_init.o $(OBJDIR)/med_ocean.o $(OBJDIR)/mom6_supergrid.o
$(OBJDIR)/med_cap_methods.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_cap_netcdf.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/med_cap_types.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_diag.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/diag_bitsum.o $(OBJDIR)/med_cap_types.o
$(OBJDIR)/med_export.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_flux.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o
$(OBJDIR)/med_ice.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/diag_bitsum.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_init.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/cpl_map.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_ocean.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/med_ocean.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/med_cap_methods.o $(OBJDIR)/med_cap_types.o $(OBJDIR)/med_diag.o $(OBJDIR)/med_ice.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_manager.o
$(OBJDIR)/mom_cap_methods.o: $(OBJDIR)/mom_ocean_model_nuopc.o $(OBJDIR)/mom_surface_forcing_nuopc.o
$(OBJDIR)/mom_cap_MONAN.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o $(OBJDIR)/mom_cap_methods.o $(OBJDIR)/mom_ocean_model_nuopc.o $(OBJDIR)/mom_si_ifrac.o $(OBJDIR)/mom_surface_forcing_nuopc.o $(OBJDIR)/time_utils.o
$(OBJDIR)/mom_si_ifrac.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/docn_cap_netcdf.o $(OBJDIR)/mom_cap_methods.o $(OBJDIR)/mom_ocean_model_nuopc.o
$(OBJDIR)/mom_ocean_model_nuopc.o: $(OBJDIR)/mom_surface_forcing_nuopc.o
$(OBJDIR)/mpas_atm_fluxes.o: $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_atm_model.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/mpas_atm_fluxes.o $(OBJDIR)/mpas_atm_setup.o $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_atm_setup.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_cap_methods.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpas_atm_types.o $(OBJDIR)/mpas_cap_netcdf.o $(OBJDIR)/mpas_cell_binning.o $(OBJDIR)/mpas_import_diag.o
$(OBJDIR)/mpas_cap_MONAN.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_map.o $(OBJDIR)/mpas_atm_model.o $(OBJDIR)/mpas_atm_types.o $(OBJDIR)/mpas_cap_methods.o $(OBJDIR)/mpas_cap_netcdf.o $(OBJDIR)/mpas_import_diag.o
$(OBJDIR)/mpas_cap_netcdf.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpi_allreduce_wrappers.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/mpas_cell_binning.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpas_atm_types.o
$(OBJDIR)/mpas_import_diag.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/mpas_atm_types.o $(OBJDIR)/nc_writer.o
$(OBJDIR)/mpi_allreduce_wrappers.o: $(OBJDIR)/mpi_allreduce_i4.o $(OBJDIR)/mpi_allreduce_r8.o
$(OBJDIR)/regrid_esmf.o: $(OBJDIR)/regrid_base.o
$(OBJDIR)/regrid_manager.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_registry.o
$(OBJDIR)/regrid_mpassit.o: $(OBJDIR)/coupler_constants.o $(OBJDIR)/regrid_esmf.o
$(OBJDIR)/regrid_registry.o: $(OBJDIR)/regrid_base.o $(OBJDIR)/regrid_esmf.o $(OBJDIR)/regrid_mpassit.o $(OBJDIR)/regrid_weights.o
$(OBJDIR)/regrid_weights.o: $(OBJDIR)/regrid_base.o
$(OBJDIR)/sis_cap_MONAN.o: $(OBJDIR)/cap_common.o $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o $(OBJDIR)/cpl_fields.o $(OBJDIR)/cpl_grids.o $(OBJDIR)/cpl_map.o $(OBJDIR)/mom6_supergrid.o $(OBJDIR)/sis_cap_fields.o $(OBJDIR)/time_utils.o
$(OBJDIR)/sis_cap_fields.o: $(OBJDIR)/coupler_config.o $(OBJDIR)/coupler_constants.o $(OBJDIR)/coupler_utils.o
$(OBJDIR)/time_utils.o: $(OBJDIR)/mom_cap_methods.o

# -----------------------------------------------------------------------------
# Alvos auxiliares
# -----------------------------------------------------------------------------
help:
	@echo "  Makefile v$(VERSION): make | clean | distclean | rebuild | check | printenv | help"
	@echo "  Pré-requisito: source run/setenv-gnu.bash"

test:
	$(MAKE) -C tests/regrid run NP=$${NP:-2}

check:
	@miss=0; for s in $(SRCS); do \
	  f=$$(find $(SRCDIR) -name "$$s.F90" | head -1); \
	  if [ -n "$$f" ]; then echo "  OK    $$f"; else echo "  FALTA $$s.F90"; miss=$$((miss+1)); fi; \
	done; [ $$miss -eq 0 ] || { echo "  ERRO: $$miss fonte(s) ausente(s)"; exit 1; }

clean:
	rm -rf build $(BINDIR)
	rm -f *.stdout log.atmosphere.*.out *.log

# ATENÇÃO: distclean apaga lib/ e mod/ (artefatos de 1-install-monan.bash e
# 2-install-mom.bash); será preciso reinstalá-los.
distclean: clean
	rm -rf *.pbs lib mod

rebuild: clean
	$(MAKE) all

printenv:
	@echo "  FC            = $(FC)"
	@echo "  ESMFMKFILE    = $(ESMFMKFILE)"
	@echo "  MONAN2_MODDIR = $(MONAN2_MODDIR)"
	@echo "  MONAN2_LIBDIR = $(MONAN2_LIBDIR)"
	@echo "  MOM6_LIBDIR   = $(MOM6_LIBDIR)"
	@echo "  MOAB externo  = $(USE_EXTERNAL_MOAB)"
	@echo "  FP_CONTRACT   = $(FP_CONTRACT)"
	@echo "  F90FLAGS      ="; echo "$(F90FLAGS)" | tr ' ' '\n' | grep -v '^$$' | sed 's/^/    /'
