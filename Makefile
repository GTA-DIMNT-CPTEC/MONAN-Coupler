# =============================================================================
# Makefile — MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1
# GT Acoplamento de Modelos / INPE / CGCT / DIMNT
#
# Compila o acoplador bin/esmApp a partir das camadas MPAS (atmosfera),
# MOM6+SIS2 (oceano), mediador e driver ESM.
#
# Uso rápido (após 'source run/setenv-gnu.bash'):
#   make              → compila bin/esmApp
#   make clean        → remove build/ bin/
#   make distclean    → clean + remove *.pbs e libs instaladas (lib/ mod/)
#   make rebuild      → clean + all
#   make check        → verifica se os fontes existem (pré-compilação)
#   make printenv     → mostra as variáveis de compilação
#   make diagnose     → inspeciona o estado do build
#   make version      → exibe a versão deste Makefile
#   make help         → lista todos os alvos
# =============================================================================

VERSION := 14.8

# O Cray XD 2000 exporta MAKEFLAGS=-e, fazendo o ambiente sobrepor as
# atribuições ':=' (mesmo com 'override'). Filtrar -e na 1ª linha executável
# garante que as definições abaixo sempre prevaleçam.
MAKEFLAGS := $(filter-out -e,$(MAKEFLAGS))

# =============================================================================
# Pré-condição: variáveis obrigatórias (verificadas ANTES do include)
# =============================================================================
ifndef ESMFMKFILE
  $(error ESMFMKFILE não definido. Execute: source run/setenv-gnu.bash)
endif
ifndef MPAS_DIR
  $(error MPAS_DIR não definido. Execute: source run/setenv-gnu.bash)
endif

# 'all' deve ser o 1º alvo e declarado ANTES do include esmf.mk, para ser o
# alvo padrão independentemente do que o esmf.mk defina como primeiro alvo.
.PHONY: all dirs clean distclean rebuild check printenv diagnose version help FORCE
all: dirs bin/esmApp
	@echo ""
	@echo "  OK: bin/esmApp gerado com sucesso."
	@echo ""

# esmf.mk fornece FC, F90FLAGS, LDFLAGS e caminhos de link do ESMF.
include $(ESMFMKFILE)

# =============================================================================
# Diretórios de código-fonte
#
# NÃO usar comentários inline: o espaço antes do '#' entra no valor da
# variável e fragmenta o caminho, gerando "No rule to make target".
# 'override' garante que estas atribuições prevaleçam sobre o esmf.mk e
# sobre argumentos passados na linha de comando.
# =============================================================================
override ATM_DIR      := src/caps/atmos
override OCN_DIR      := src/caps/ocean
override UPSTREAM_DIR := src/caps/ocean/upstream
override MEDIATOR_DIR := src/mediator
override DRIVER_DIR   := src/driver
override MAIN_DIR     := src/main
override SHARED_DIR   := src/shared
override BINDIR       := bin
override BUILDDIR     := build
override OBJDIR       := build/obj
override MODDIR       := build/mod

# Guarda de sanidade: aborta se um DIR essencial ficou vazio.
# Ocorre quando o ambiente sobrepõe a atribuição (ex.: MAKEFLAGS=-e).
ifeq ($(strip $(ATM_DIR)),)
  $(error FATAL: ATM_DIR vazio — verifique MAKEFLAGS=$$MAKEFLAGS)
endif
ifeq ($(strip $(OCN_DIR)),)
  $(error FATAL: OCN_DIR vazio — verifique MAKEFLAGS=$$MAKEFLAGS)
endif

# =============================================================================
# MONAN-A 2.0 (MPAS) — artefatos consolidados
#
# 1-install-monan.bash reúne os .mod em mod/monan2 e as .a em lib/monan2
# (irmãos de MONAN-Model). COUPLER_ROOT é o pai de MPAS_DIR.
# MONAN2_MODDIR/LIBDIR usam '?=' e aceitam sobreposição via ambiente.
# =============================================================================
_MPAS_DIR_NS  := $(patsubst %/,%,$(MPAS_DIR))
COUPLER_ROOT  := $(patsubst %/,%,$(dir $(_MPAS_DIR_NS)))
MONAN2_MODDIR ?= $(COUPLER_ROOT)/mod/monan2
MONAN2_LIBDIR ?= $(COUPLER_ROOT)/lib/monan2

# =============================================================================
# MOM6+SIS2
#
# Todos os caminhos derivam de MOM6_LIBDIR quando disponível.
# Se MOM6_LIBDIR não estiver definido, o acoplador compila sem o cap OCN
# dinâmico (apenas DOCN, cap de dados sintéticos de oceano).
# =============================================================================
ifdef MOM6_LIBDIR
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
  HAS_MOM6     := yes
  # MOAB (backend do ESMF_Mesh) é tratado fora deste bloco — ver seção "MOAB".
else
  $(warning MOM6_LIBDIR não definido — compilando sem cap OCN MOM6+SIS2.)
  HAS_MOM6 :=
endif

# =============================================================================
# MOAB — backend de malha não estruturada do ESMF_Mesh
#
# O ESMF_Mesh (usado apenas pelo cap OCN MOM6) apoia-se no MOAB. O build PADRÃO
# do ESMF embute o MOAB DENTRO de libesmf; nesse caso o link do acoplador NÃO
# deve passar -lMOAB externo — o $(ESMF_F90LINK) já resolve os símbolos.
#
# Defina USE_EXTERNAL_MOAB=yes (e MOAB_DIR) APENAS se o ESMF tiver sido
# construído com MOAB externo (ESMF_MOAB=external). Verifique no Jaci com:
#   grep -i moab "$(ESMFMKFILE)"
#   ldd "$$ESMF_LIBDIR/libesmf.so" | grep -i moab   # vazio=interno; libMOAB=externo
#
# Nenhum fonte do acoplador faz #include de cabeçalhos MOAB; logo o -I.../include
# só é necessário no caso externo. Em caso externo, MOAB_DIR DEVE apontar para a
# MESMA instalação usada ao compilar o ESMF, evitando divergência de versão.
# =============================================================================
USE_EXTERNAL_MOAB ?= no

MOAB_INC :=
MOAB_LIB :=
ifeq ($(USE_EXTERNAL_MOAB),yes)
  ifndef MOAB_DIR
    $(error USE_EXTERNAL_MOAB=yes exige MOAB_DIR (mesma MOAB usada para compilar o ESMF))
  endif
  MOAB_INC := -I$(MOAB_DIR)/include
  MOAB_LIB := -L$(MOAB_DIR)/lib -lMOAB
endif

# =============================================================================
# Flags de compilação
# =============================================================================
FC := $(ESMF_F90COMPILER)

MPAS_INCLUDE := -I$(MONAN2_MODDIR)

# F90FLAGS — flags comuns a todos os módulos do acoplador
F90FLAGS := $(ESMF_F90COMPILEOPTS)      \
            $(ESMF_F90COMPILEPATHS)     \
            $(ESMF_F90COMPILEFREENOCPP) \
            $(MPAS_INCLUDE)             \
            -I$(MODDIR)                 \
            -J$(MODDIR)                 \
            -ffree-form                 \
            -ffree-line-length-none     \
            -fopenmp                    \
            -fallow-argument-mismatch   \
            -ffpe-summary=none          \
            -O2 -g                      \
            -Wall                       \
            -Wno-unused-dummy-argument  \
            -Wno-unused-variable

# Flags adicionais quando MOM6 está disponível: caminhos de módulos e cabeçalhos
ifdef HAS_MOM6
F90FLAGS += -I$(MOM6_MODDIR)         \
            -I$(MOM6_INCDIR)         \
            -I$(FMS_MODDIR)          \
            -I$(FMS_INCDIR)          \
            -I$(NUOPC_MODDIR)        \
            -I$(NUOPC_INCDIR)        \
            $(MOAB_INC)              \
            -I$(PNETCDF_DIR)/include \
            $(MOM6_HDR_INC)
# MOM6_HDR_INC fornece -I para MOM_memory.h e version_variable.h
# (cabeçalhos na árvore de fontes do MOM6). Exportado por setenv-gnu.bash.
# Se vazio, os caps upstream em UPSTREAM_DIR não compilarão.
endif

# Flags exclusivas dos caps upstream MOM6 (UPSTREAM_DIR)
# A lib MOM6+FMS é compilada com real de 8 bytes; os caps upstream usam
# 'real' sem kind. -fdefault-real-8/-double-8 garantem a mesma precisão
# exigida pelas interfaces genéricas.
# NÃO aplicar às camadas MPAS/MED (que usam ESMF_KIND_R8 explícito).
MOM6_REAL8   := -fdefault-real-8 -fdefault-double-8
MOM6_NOWARN  := -Wno-unused-function \
                -Wno-character-truncation \
                -Wno-maybe-uninitialized
MOM6_FCFLAGS := $(F90FLAGS) $(MOM6_REAL8) $(MOM6_NOWARN)

# =============================================================================
# Bibliotecas
# =============================================================================

# Bibliotecas MONAN-A: --start-group/--end-group resolve dependências circulares
# entre as 6 libs (os símbolos cruzam fronteiras de arquivo .a).
MPAS_LIBS := \
  -L$(MONAN2_LIBDIR)                                   \
  -Wl,--start-group                                     \
    -lframework -ldycore -lphys -lops -lsmiolf -lsmiol  \
  -Wl,--end-group

# Bibliotecas do sistema
SYS_LIBS := -lz -ldl -lm
OMP_LIBS := -lgomp

ifdef HAS_MOM6
  # MOM6_OBJS: objetos do MOM6 standalone linkados diretamente.
  # Os drivers standalone (MOM_main, coupler_main, MOM_driver) são excluídos:
  # o acoplador usa seus próprios pontos de entrada via NUOPC.
  MOM6_OBJS := $(filter-out                   \
    $(MOM6_LIBDIR)/MOM_main.o                 \
    $(MOM6_LIBDIR)/coupler_main.o             \
    $(MOM6_LIBDIR)/MOM_driver.o,              \
    $(wildcard $(MOM6_LIBDIR)/*.o))

  MOM6_EXTRA_LIBS := $(MOM6_OBJS)            \
    -L$(NUOPC_LIBDIR) -lmom6_nuopc           \
    -L$(FMS_LIBDIR)   -lfms                  \
    $(MOAB_LIB)                              \
    -L$(PNETCDF_DIR)/lib -lpnetcdf
else
  MOM6_EXTRA_LIBS :=
endif

# Monta o conjunto completo de flags de link, compatível com ou sem ESMF_F90LINK
ifdef ESMF_F90LINK
  LDFLAGS_ALL := $(MPAS_LIBS) $(ESMF_F90LINK) $(MOM6_EXTRA_LIBS) $(SYS_LIBS) $(OMP_LIBS)
else
  LDFLAGS_ALL := $(MPAS_LIBS)            \
                 $(ESMF_F90LINKOPTS)     \
                 $(ESMF_F90LINKPATHS)    \
                 $(ESMF_F90LINKRPATHS)   \
                 $(ESMF_F90ESMFLINKLIBS) \
                 $(MOM6_EXTRA_LIBS)      \
                 $(SYS_LIBS)             \
                 $(OMP_LIBS)
endif

# =============================================================================
# Lista de objetos — ordem de linkagem (camadas L0 → L5)
# =============================================================================
ALL_OBJS := \
  $(OBJDIR)/mpas_atm_types.o            \
  $(OBJDIR)/mpas_cap_utils.o            \
  $(OBJDIR)/mpi_allreduce_r8.o          \
  $(OBJDIR)/mpi_allreduce_i4.o          \
  $(OBJDIR)/mpi_allreduce_wrappers.o    \
  $(OBJDIR)/mpas_cap_config.o           \
  $(OBJDIR)/mpas_atm_model.o            \
  $(OBJDIR)/mpas_cap_netcdf.o           \
  $(OBJDIR)/mpas_atm_wrappers.o         \
  $(OBJDIR)/mpas_cap_methods.o          \
  $(OBJDIR)/mpas_cap_MONAN.o            \
  $(OBJDIR)/med_cap_types.o             \
  $(OBJDIR)/med_cap_netcdf.o            \
  $(OBJDIR)/med_cap_methods.o           \
  $(OBJDIR)/med_bulk_ncar.o             \
  $(OBJDIR)/MED_cap.o                   \
  $(OBJDIR)/DATM_cap.o                  \
  $(OBJDIR)/docn_cap_netcdf.o           \
  $(OBJDIR)/DOCN_cap.o                  \
  $(OBJDIR)/mom_surface_forcing_nuopc.o \
  $(OBJDIR)/mom_ocean_model_nuopc.o     \
  $(OBJDIR)/mom_cap_methods.o           \
  $(OBJDIR)/time_utils.o                \
  $(OBJDIR)/mom_cap_MONAN.o             \
  $(OBJDIR)/esm.o                       \
  $(OBJDIR)/esmApp.o

# mpas_cap_MONAN e MED_cap são recompilados sempre (FORCE incondicional)
# para garantir que os .mod sejam regenerados em qualquer estado do build/.
_FORCE_CAP := FORCE
_FORCE_MED := FORCE

# =============================================================================
# Alvos de infraestrutura
# =============================================================================
dirs:
	@mkdir -p $(OBJDIR) $(MODDIR) $(BINDIR)

bin/esmApp: $(ALL_OBJS) | dirs
	$(FC) -o $@ $(ALL_OBJS) $(LDFLAGS_ALL)

FORCE:
	@true

# =============================================================================
# Regras de compilação por camada (L0 → L5)
# =============================================================================

# L0 — tipos base e utilitários (sem dependências internas ao projeto)
# mpi_allreduce_r8/i4 ficam em arquivos separados: isolar cada tipo evita
# o type-mismatch espúrio que o gfortran/Cray gera ao ver chamadas r8 e i4
# ao mesmo símbolo externo dentro de um único arquivo de módulo.
$(OBJDIR)/mpi_allreduce_r8.o: $(SHARED_DIR)/mpi_allreduce_r8.F90 | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpi_allreduce_i4.o: $(SHARED_DIR)/mpi_allreduce_i4.F90 | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpi_allreduce_wrappers.o: $(SHARED_DIR)/mpi_allreduce_wrappers.F90 \
                                    $(OBJDIR)/mpi_allreduce_r8.o              \
                                    $(OBJDIR)/mpi_allreduce_i4.o | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_atm_types.o: $(ATM_DIR)/mpas_atm_types.F90 | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_cap_utils.o: $(ATM_DIR)/mpas_cap_utils.F90 | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L1 — configuração e modelo atmosférico (dependem de L0)
$(OBJDIR)/mpas_cap_config.o: $(ATM_DIR)/mpas_cap_config.F90 \
                              $(OBJDIR)/mpas_cap_utils.o | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_atm_model.o: $(ATM_DIR)/mpas_atm_model.F90 \
                             $(OBJDIR)/mpas_atm_types.o    \
                             $(OBJDIR)/mpas_cap_config.o   \
                             $(OBJDIR)/mpas_cap_utils.o    | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_cap_netcdf.o: $(ATM_DIR)/mpas_cap_netcdf.F90     \
                              $(OBJDIR)/mpi_allreduce_wrappers.o \
                              $(OBJDIR)/mpas_atm_types.o         \
                              $(OBJDIR)/mpas_cap_config.o        \
                              $(OBJDIR)/mpas_cap_utils.o         | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L2 — wrappers e métodos atmosféricos (dependem de L1)
$(OBJDIR)/mpas_atm_wrappers.o: $(ATM_DIR)/mpas_atm_wrappers.F90 \
                                $(OBJDIR)/mpas_atm_model.o | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_cap_methods.o: $(ATM_DIR)/mpas_cap_methods.F90 \
                               $(OBJDIR)/mpas_atm_types.o      \
                               $(OBJDIR)/mpas_atm_model.o      \
                               $(OBJDIR)/mpas_cap_utils.o      | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L3 — caps principais (ATM, MED, DATM/DOCN)
# mpas_cap_MONAN e MED_cap são forçados via _FORCE para garantir .mod.
$(OBJDIR)/mpas_cap_MONAN.o: $(ATM_DIR)/mpas_cap_MONAN.F90  \
                             $(OBJDIR)/mpas_cap_config.o    \
                             $(OBJDIR)/mpas_atm_types.o     \
                             $(OBJDIR)/mpas_atm_model.o     \
                             $(OBJDIR)/mpas_atm_wrappers.o  \
                             $(OBJDIR)/mpas_cap_methods.o   \
                             $(OBJDIR)/mpas_cap_netcdf.o    \
                             $(OBJDIR)/mpas_cap_utils.o     \
                             $(_FORCE_CAP) | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L2-MED — módulos do mediador (camada independente das caps ATM/OCN)
$(OBJDIR)/med_cap_types.o: $(MEDIATOR_DIR)/med_cap_types.F90 | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/med_cap_netcdf.o: $(MEDIATOR_DIR)/med_cap_netcdf.F90 \
                             $(OBJDIR)/med_cap_types.o          \
                             $(OBJDIR)/mpas_cap_config.o        | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/med_cap_methods.o: $(MEDIATOR_DIR)/med_cap_methods.F90 \
                              $(OBJDIR)/med_cap_types.o           | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/med_bulk_ncar.o: $(MEDIATOR_DIR)/med_bulk_ncar.F90 \
                            $(OBJDIR)/med_cap_types.o         | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/MED_cap.o: $(MEDIATOR_DIR)/MED_cap.F90     \
                     $(OBJDIR)/med_cap_types.o        \
                     $(OBJDIR)/med_cap_netcdf.o       \
                     $(OBJDIR)/med_cap_methods.o      \
                     $(OBJDIR)/med_bulk_ncar.o        \
                     $(OBJDIR)/mpas_cap_config.o      \
                     $(OBJDIR)/mpas_cap_utils.o       \
                     $(_FORCE_MED) | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/DATM_cap.o: $(ATM_DIR)/DATM_cap.F90    \
                      $(OBJDIR)/mpas_cap_config.o \
                      $(OBJDIR)/mpas_cap_utils.o  | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/docn_cap_netcdf.o: $(OCN_DIR)/docn_cap_netcdf.F90 \
                              $(OBJDIR)/mpas_cap_config.o    \
                              $(OBJDIR)/mpas_cap_utils.o     | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/DOCN_cap.o: $(OCN_DIR)/DOCN_cap.F90    \
                      $(OBJDIR)/docn_cap_netcdf.o \
                      $(OBJDIR)/mpas_cap_config.o \
                      $(OBJDIR)/mpas_cap_utils.o  | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L3-OCN — caps upstream MOM6 (fontes compilados localmente com MOM6_FCFLAGS)
# Fornecem os símbolos usados por mom_cap_MONAN.F90:
#   mom_import/export, ocean_model_*, esmf2fms_time.
# Ordem de dependência obrigatória:
#   surface_forcing → ocean_model_nuopc → cap_methods → time_utils → mom_cap
$(OBJDIR)/mom_surface_forcing_nuopc.o: $(UPSTREAM_DIR)/mom_surface_forcing_nuopc.F90 | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

$(OBJDIR)/mom_ocean_model_nuopc.o: $(UPSTREAM_DIR)/mom_ocean_model_nuopc.F90 \
                                   $(OBJDIR)/mom_surface_forcing_nuopc.o     | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

$(OBJDIR)/mom_cap_methods.o: $(UPSTREAM_DIR)/mom_cap_methods.F90   \
                             $(OBJDIR)/mom_ocean_model_nuopc.o     \
                             $(OBJDIR)/mom_surface_forcing_nuopc.o | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

$(OBJDIR)/time_utils.o: $(SHARED_DIR)/time_utils.F90 \
                        $(OBJDIR)/mom_cap_methods.o  | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

# Cap NUOPC/ESMF do componente oceânico MOM6+SIS2 (acoplamento dinâmico)
$(OBJDIR)/mom_cap_MONAN.o: $(OCN_DIR)/mom_cap_MONAN.F90          \
                           $(OBJDIR)/mom_surface_forcing_nuopc.o \
                           $(OBJDIR)/mom_ocean_model_nuopc.o     \
                           $(OBJDIR)/mom_cap_methods.o           \
                           $(OBJDIR)/time_utils.o                | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

# L4 — driver ESM
# esm.o usa: 'use MOM_cap_MONAN_mod, only: OCN_SetServices => SetServices'
$(OBJDIR)/esm.o: $(DRIVER_DIR)/esm.F90      \
                 $(OBJDIR)/mpas_cap_MONAN.o \
                 $(OBJDIR)/MED_cap.o        \
                 $(OBJDIR)/DATM_cap.o       \
                 $(OBJDIR)/DOCN_cap.o       \
                 $(OBJDIR)/mom_cap_MONAN.o  \
                 $(OBJDIR)/mpas_cap_utils.o | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L5 — ponto de entrada do aplicativo
$(OBJDIR)/esmApp.o: $(MAIN_DIR)/esmApp.F90      \
                    $(OBJDIR)/esm.o              \
                    $(OBJDIR)/mpas_cap_config.o  \
                    $(OBJDIR)/mpas_cap_utils.o   | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# =============================================================================
# Alvos auxiliares
# =============================================================================

help:
	@echo ""
	@echo "  Makefile v$(VERSION) — MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1"
	@echo "  INPE / CGCT / DIMNT — GT Acoplamento de Modelos"
	@echo ""
	@echo "  Alvos disponíveis:"
	@echo "    make           → compila bin/esmApp  (padrão: make all)"
	@echo "    make clean     → remove build/ bin/"
	@echo "    make distclean → clean + remove *.pbs e libs instaladas (lib/ mod/)"
	@echo "    make rebuild   → clean + all em uma etapa"
	@echo "    make check     → verifica se os fontes existem (pré-compilação)"
	@echo "    make printenv  → exibe variáveis de compilação"
	@echo "    make diagnose  → inspeciona o estado atual do build"
	@echo "    make version   → exibe a versão deste Makefile"
	@echo "    make help      → esta mensagem"
	@echo ""
	@echo "  Pré-requisito: source run/setenv-gnu.bash"
	@echo ""

version:
	@echo "  Makefile v$(VERSION)"

# check — verifica a existência dos fontes antes de tentar compilar.
# Falha com mensagem clara se algum arquivo estiver ausente.
check:
	@echo ""
	@echo "=== Verificação de fontes (Makefile v$(VERSION)) ==="
	@echo ""
	@_miss=0; \
	for f in \
	  $(SHARED_DIR)/mpi_allreduce_r8.F90      \
	  $(SHARED_DIR)/mpi_allreduce_i4.F90      \
	  $(SHARED_DIR)/mpi_allreduce_wrappers.F90 \
	  $(SHARED_DIR)/time_utils.F90            \
	  $(ATM_DIR)/mpas_atm_types.F90           \
	  $(ATM_DIR)/mpas_cap_utils.F90           \
	  $(ATM_DIR)/mpas_cap_config.F90          \
	  $(ATM_DIR)/mpas_atm_model.F90           \
	  $(ATM_DIR)/mpas_cap_netcdf.F90          \
	  $(ATM_DIR)/mpas_atm_wrappers.F90        \
	  $(ATM_DIR)/mpas_cap_methods.F90         \
	  $(ATM_DIR)/mpas_cap_MONAN.F90           \
	  $(ATM_DIR)/DATM_cap.F90                 \
	  $(MEDIATOR_DIR)/med_cap_types.F90       \
	  $(MEDIATOR_DIR)/med_cap_netcdf.F90      \
	  $(MEDIATOR_DIR)/med_cap_methods.F90     \
	  $(MEDIATOR_DIR)/med_bulk_ncar.F90       \
	  $(MEDIATOR_DIR)/MED_cap.F90             \
	  $(OCN_DIR)/docn_cap_netcdf.F90          \
	  $(OCN_DIR)/DOCN_cap.F90                 \
	  $(OCN_DIR)/mom_cap_MONAN.F90            \
	  $(UPSTREAM_DIR)/mom_surface_forcing_nuopc.F90 \
	  $(UPSTREAM_DIR)/mom_ocean_model_nuopc.F90     \
	  $(UPSTREAM_DIR)/mom_cap_methods.F90     \
	  $(DRIVER_DIR)/esm.F90                   \
	  $(MAIN_DIR)/esmApp.F90; do              \
	  if [ -f "$$f" ]; then \
	    printf "  OK    %s\n" "$$f"; \
	  else \
	    printf "  FALTA %s\n" "$$f"; \
	    _miss=$$(( _miss + 1 )); \
	  fi; \
	done; \
	echo ""; \
	if [ "$$_miss" -eq 0 ]; then \
	  echo "  Todos os fontes encontrados. Pronto para 'make'."; \
	else \
	  echo "  ERRO: $$_miss fonte(s) ausente(s)."; \
	  exit 1; \
	fi
	@echo ""

# clean — remove artefatos de build e saídas soltas no diretório de trabalho
clean:
	@echo "  Limpando build/ e bin/..."
	rm -rf $(BUILDDIR) $(BINDIR)
	rm -f *.stdout log.atmosphere.*.out *.log

# distclean — clean + remove scripts PBS e as bibliotecas instaladas (lib/ mod/).
# ATENÇÃO: apaga os artefatos de 1-install-monan.bash e 2-install-mom.bash;
# será necessário reinstalá-los antes do próximo build do acoplador.
distclean: clean
	@echo "  Removendo scripts PBS gerados (*.pbs)..."
	rm -f *.pbs
	@echo "  Removendo bibliotecas instaladas (lib/ mod/)..."
	rm -rf lib mod

rebuild: clean all

printenv:
	@echo ""
	@echo "======================================================================"
	@echo "  Makefile v$(VERSION) — variáveis de build"
	@echo "======================================================================"
	@echo ""
	@echo "  Compilador"
	@echo "    FC            = $(FC)"
	@echo ""
	@echo "  Diretórios de código-fonte"
	@echo "    ATM_DIR       = $(ATM_DIR)"
	@echo "    OCN_DIR       = $(OCN_DIR)"
	@echo "    UPSTREAM_DIR  = $(UPSTREAM_DIR)"
	@echo "    MEDIATOR_DIR  = $(MEDIATOR_DIR)"
	@echo "    SHARED_DIR    = $(SHARED_DIR)"
	@echo "    DRIVER_DIR    = $(DRIVER_DIR)"
	@echo "    MAIN_DIR      = $(MAIN_DIR)"
	@echo ""
	@echo "  ESMF / MPAS"
	@echo "    ESMFMKFILE    = $(ESMFMKFILE)"
	@echo "    MPAS_DIR      = $(MPAS_DIR)"
	@echo "    MONAN2_MODDIR = $(MONAN2_MODDIR)"
	@echo "    MONAN2_LIBDIR = $(MONAN2_LIBDIR)"
	@echo ""
	@echo "  MOM6+SIS2"
	@echo "    HAS_MOM6      = $(if $(HAS_MOM6),sim ($(MOM6_LIBDIR)),não — modo stub OCN)"
	@echo "    MOAB externo  = $(USE_EXTERNAL_MOAB)$(if $(filter yes,$(USE_EXTERNAL_MOAB)), ($(MOAB_DIR)), — resolvido pelo ESMF)"
	@echo ""
	@echo "  Build"
	@echo "    OBJDIR        = $(OBJDIR)"
	@echo "    MODDIR        = $(MODDIR)"
	@echo "    BINDIR        = $(BINDIR)"
	@echo ""
	@echo "  F90FLAGS (um flag por linha):"
	@echo "$(F90FLAGS)" | tr ' ' '\n' | grep -v '^$$' | sed 's/^/    /'
	@echo ""
	@echo "  MOM6_REAL8   = $(MOM6_REAL8)"
	@echo "  MOM6_NOWARN  = $(MOM6_NOWARN)"
	@echo "======================================================================"
	@echo ""

diagnose:
	@echo ""
	@echo "=== Makefile v$(VERSION) — diagnóstico do build ==="
	@echo ""
	@echo "--- Binário ---"
	@if [ -f $(BINDIR)/esmApp ]; then \
	  echo "  $(BINDIR)/esmApp  [OK] — $$(ls -lh $(BINDIR)/esmApp | awk '{print $$5, $$6, $$7, $$8}')"; \
	else \
	  echo "  $(BINDIR)/esmApp  [AUSENTE] — execute 'make'"; \
	fi
	@echo ""
	@echo "--- MOM6+SIS2 ---"
	@echo "  HAS_MOM6     = $(if $(HAS_MOM6),sim,não)"
	@echo "  MOM6_LIBDIR  = $(MOM6_LIBDIR)"
	@echo "  HAS_MOM6_HDR = $(if $(MOM6_HDR_INC),sim,não)"
	@echo ""
	@echo "--- FORCE targets ---"
	@echo "  _FORCE_CAP   = $(_FORCE_CAP)"
	@echo "  _FORCE_MED   = $(_FORCE_MED)"
	@echo ""
	@echo "--- Objetos compilados ($(OBJDIR)/) ---"
	@ls $(OBJDIR)/*.o 2>/dev/null | wc -l | \
	  xargs -I{} echo "  {} de $(words $(ALL_OBJS)) objetos esperados"
	@echo ""
	@echo "--- Módulos gerados ($(MODDIR)/) ---"
	@ls $(MODDIR)/*.mod 2>/dev/null | wc -l | \
	  xargs -I{} echo "  {} módulos .mod"
	@ls $(MODDIR)/*.mod 2>/dev/null | sed 's|.*/||' | \
	  column -c 78 | sed 's/^/    /' || echo "    (vazio)"
	@echo ""
