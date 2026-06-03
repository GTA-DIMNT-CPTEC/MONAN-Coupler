# =============================================================================
# Makefile — MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1 — Versão 14.6
# GT Acoplamento de Modelos / INPE / CGCT / DIMNT
#
# v14.3 — Correção do erro de link "undefined reference" em mom_cap_MONAN.o.
#   Os módulos de suporte ao cap oceânico (MOM_surface_forcing_nuopc,
#   MOM_ocean_model_nuopc, MOM_cap_methods e time_utils_mod) passam a ser
#   COMPILADOS localmente e adicionados a ALL_OBJS. Antes, mom_cap_MONAN.F90
#   compilava contra os .mod da biblioteca (-I NUOPC_MODDIR), mas os símbolos
#   correspondentes não eram fornecidos no link, resultando em ld: error.
#
# v14.4 — Os fontes upstream usam '#include <MOM_memory.h>' e
#   '#include "version_variable.h"' (cabeçalhos CPP da árvore de fontes do
#   MOM6). Acrescentado $(MOM6_HDR_INC) ao caminho de inclusão; a variável é
#   exportada por setenv-gnu.bash (busca dinâmica sob MOM6_SRC/MOM6_ROOT).
#
# v14.5 — A biblioteca MOM6+FMS foi compilada com real padrão de 8 bytes.
#   Os fontes upstream usam 'real' sem kind explícito; sem promoção, as
#   interfaces genéricas (field_chksum, get_param, data_override...) não
#   resolvem. Criado MOM6_FCFLAGS (= F90FLAGS + -fdefault-real-8
#   -fdefault-double-8), aplicado SOMENTE aos 5 objetos do cap oceânico.
#   As camadas MPAS/MED usam ESMF_KIND_R8 explícito e seguem em F90FLAGS.
#
# v14.6 — Build OK. Suprimidos 3 warnings benignos dos fontes upstream MOM6
#   (read-only), que surgiam apenas por causa do -Wall global:
#     -Wno-unused-function      surface_forcing_end definida e não usada
#     -Wno-character-truncation atribuição de string 200/240 (restart_dir)
#     -Wno-maybe-uninitialized  'lrank' (falso positivo: protegido por ChkErr)
#   Escopo restrito a MOM6_FCFLAGS; as camadas MPAS/MED mantêm -Wall pleno.
#
# NOTA: 'all' é declarado ANTES de 'include $(ESMFMKFILE)' para garantir
#       que seja o alvo padrão do GNU Make, independente do que o esmf.mk
#       defina como primeiro alvo.
#
# Uso rápido:
#   source setenv-gnu.bash
#   make              → compila bin/esmApp  (equivale a: make all)
#   make clean        → remove build/ bin/ logs/   (dados preservados)
#   make distclean    → clean + remove diag_export/ diag_import/ *.pbs
#   make rebuild      → clean + all em uma etapa
#   make help         → lista todos os alvos disponíveis
#   make printenv     → mostra variáveis de compilação
#   make diagnose     → inspeciona estado do build
# =============================================================================

VERSION := 14.6

# Remover -e do MAKEFLAGS antes de qualquer atribuição.
# O Cray XD 2000 exporta MAKEFLAGS=-e no ambiente de módulos; com -e ativo,
# variáveis de ambiente sobrepõem definições ':=' do Makefile mesmo com
# 'override'. Filtrar -e garante que as atribuições abaixo sempre prevaleçam.
MAKEFLAGS := $(filter-out -e,$(MAKEFLAGS))

# --- Verificar variáveis obrigatórias ANTES do include ----------------------
ifndef ESMFMKFILE
  $(error ESMFMKFILE não definido. Execute: source setenv-gnu.bash)
endif
ifndef MPAS_DIR
  $(error MPAS_DIR não definido. Execute: source setenv-gnu.bash)
endif

# --- Declarar 'all' como PRIMEIRO alvo ANTES do include ---------------------
.PHONY: all dirs clean distclean rebuild printenv diagnose help FORCE
all: dirs bin/esmApp
	@echo ""
	@echo "  OK: bin/esmApp gerado com sucesso."
	@echo ""

# --- Incluir esmf.mk (traz FC, F90FLAGS, LDFLAGS do ESMF) -------------------
include $(ESMFMKFILE)

# =============================================================================
# Diretórios — código-fonte
#
# ATENÇÃO: NÃO use comentários inline nesta seção.
# Em GNU Make, espaços antes do '#' em atribuições de variáveis são incluídos
# no valor (ex.: 'VAR := path     # comentário' → VAR = 'path     ').
# Espaços embebidos no valor fazem o Make tratar o path como múltiplos
# pré-requisitos separados, causando "No rule to make target '/arquivo.F90'".
#
# 'override' garante que as atribuições abaixo prevaleçam sobre esmf.mk e
# argumentos de linha de comando. O MAKEFLAGS filter acima trata o -e do Cray.
# =============================================================================
# caps MONAN-A (MPAS) e DATM
override ATM_DIR      := src/caps/atmos
# caps MOM6+SIS2 e DOCN
override OCN_DIR      := src/caps/ocean
# fontes upstream MOM6 (caps NUOPC adaptados — compilados localmente)
override UPSTREAM_DIR := src/caps/ocean/upstream
# cap do mediador ATM-OCN
override MEDIATOR_DIR := src/mediator
# driver ESM
override DRIVER_DIR   := src/driver
# ponto de entrada (esmApp.F90)
override MAIN_DIR     := src/main
# utilitários MPI compartilhados
override SHARED_DIR   := src/shared
override BINDIR       := bin
override BUILDDIR     := build
override OBJDIR       := build/obj
override MODDIR       := build/mod
DATAOUTDIR            := diag_export
LOGSDIR               := logs

# Guarda de sanidade: aborta imediatamente se algum DIR ainda estiver vazio.
ifeq ($(strip $(ATM_DIR)),)
  $(error FATAL: ATM_DIR vazio. \
    Verifique: env | grep -E 'ATM_DIR|MAKEFLAGS'; echo MAKEFLAGS=$$MAKEFLAGS)
endif
ifeq ($(strip $(OCN_DIR)),)
  $(error FATAL: OCN_DIR vazio. Verifique o ambiente.)
endif

# =============================================================================
# Bloco MOM6+SIS2
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
  MOAB_DIR     ?= /p/projetos/monan_adm/paulo.kubota/home/lib/lib_gnucray/libmoab
  PNETCDF_DIR  ?= /opt/cray/pe/parallel-netcdf/1.12.3.15/GNU/12.3
  HAS_MOM6     := yes
else
  $(warning MOM6_LIBDIR não definido — compilando sem caps OCN MOM6+SIS2.)
  HAS_MOM6 :=
endif

# =============================================================================
# Flags de compilação
# =============================================================================
FC := $(ESMF_F90COMPILER)

MPAS_INCLUDE := \
  -I$(MPAS_DIR)/src/framework         \
  -I$(MPAS_DIR)/src/core_atmosphere   \
  -I$(MPAS_DIR)/src/operators         \
  -I$(MPAS_DIR)/src/external/SMIOL

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

ifdef HAS_MOM6
F90FLAGS += -I$(MOM6_MODDIR)      \
            -I$(MOM6_INCDIR)      \
            -I$(FMS_MODDIR)       \
            -I$(FMS_INCDIR)       \
            -I$(NUOPC_MODDIR)     \
            -I$(NUOPC_INCDIR)     \
            -I$(MOAB_DIR)/include \
            -I$(PNETCDF_DIR)/include \
            $(MOM6_HDR_INC)
# MOM6_HDR_INC traz -I para MOM_memory.h e version_variable.h (fontes MOM6).
# Exportada por setenv-gnu.bash. Vazia => caps upstream não compilam.
endif

# Flags exclusivas dos caps upstream MOM6/FMS.
# A biblioteca foi compilada com real padrão de 8 bytes; estes fontes usam
# 'real' sem kind. -fdefault-double-8 impede que 'double precision' vire
# real(16). NÃO usar nas camadas MPAS/MED (que usam ESMF_KIND_R8 explícito).
MOM6_REAL8   := -fdefault-real-8 -fdefault-double-8
# Supressão de warnings benignos dos fontes upstream MOM6 (não editáveis).
# Cada flag corresponde a um warning específico já diagnosticado; aplicada
# só aqui para não mascarar warnings nas camadas próprias (MPAS/MED).
MOM6_NOWARN  := -Wno-unused-function -Wno-character-truncation -Wno-maybe-uninitialized
MOM6_FCFLAGS := $(F90FLAGS) $(MOM6_REAL8) $(MOM6_NOWARN)

# =============================================================================
# Bibliotecas
# =============================================================================
MPAS_LIBS := \
  -L$(MPAS_DIR)/src/framework                           \
  -L$(MPAS_DIR)/src/core_atmosphere                     \
  -L$(MPAS_DIR)/src/core_atmosphere/physics             \
  -L$(MPAS_DIR)/src/operators                           \
  -L$(MPAS_DIR)/src/external/SMIOL                      \
  -Wl,--start-group                                     \
    -lframework -ldycore -lphys -lops -lsmiolf -lsmiol  \
  -Wl,--end-group

SYS_LIBS := -lz -ldl -lm
OMP_LIBS := -lgomp

ifdef HAS_MOM6
  MOM6_OBJS := $(filter-out                   \
    $(MOM6_LIBDIR)/MOM_main.o                 \
    $(MOM6_LIBDIR)/coupler_main.o             \
    $(MOM6_LIBDIR)/MOM_driver.o,              \
    $(wildcard $(MOM6_LIBDIR)/*.o))
  MOM6_EXTRA_LIBS := $(MOM6_OBJS)            \
    -L$(NUOPC_LIBDIR) -lmom6_nuopc           \
    -L$(FMS_LIBDIR)   -lfms                  \
    -L$(MOAB_DIR)/lib -lMOAB                 \
    -L$(PNETCDF_DIR)/lib -lpnetcdf
else
  MOM6_EXTRA_LIBS :=
endif

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
# Objetos — ordem de linkagem (L0 → L5)
# =============================================================================
ALL_OBJS := \
  $(OBJDIR)/mpas_atm_types.o          \
  $(OBJDIR)/mpas_cap_utils.o          \
  $(OBJDIR)/mpi_allreduce_r8.o        \
  $(OBJDIR)/mpi_allreduce_i4.o        \
  $(OBJDIR)/mpi_allreduce_wrappers.o  \
  $(OBJDIR)/mpas_cap_config.o         \
  $(OBJDIR)/mpas_atm_model.o          \
  $(OBJDIR)/mpas_cap_netcdf.o         \
  $(OBJDIR)/mpas_atm_wrappers.o       \
  $(OBJDIR)/mpas_cap_methods.o        \
  $(OBJDIR)/mpas_cap_MONAN.o          \
  $(OBJDIR)/med_cap_types.o           \
  $(OBJDIR)/med_cap_netcdf.o          \
  $(OBJDIR)/med_cap_methods.o         \
  $(OBJDIR)/med_bulk_ncar.o           \
  $(OBJDIR)/MED_cap.o                 \
  $(OBJDIR)/DATM_cap.o                \
  $(OBJDIR)/docn_cap_netcdf.o         \
  $(OBJDIR)/DOCN_cap.o                \
  $(OBJDIR)/mom_surface_forcing_nuopc.o \
  $(OBJDIR)/mom_ocean_model_nuopc.o   \
  $(OBJDIR)/mom_cap_methods.o         \
  $(OBJDIR)/time_utils.o              \
  $(OBJDIR)/mom_cap_MONAN.o           \
  $(OBJDIR)/esm.o                     \
  $(OBJDIR)/esmApp.o

# mpas_cap_MONAN e MED_cap são recompilados sempre (FORCE incondicional)
# para garantir que o .mod seja gerado em qualquer estado do build/.
_FORCE_CAP := FORCE
_FORCE_MED := FORCE

# =============================================================================
# Alvos de build
# =============================================================================
dirs:
	@mkdir -p $(OBJDIR) $(MODDIR) $(BINDIR) $(DATAOUTDIR) $(LOGSDIR) \
	          diag_import diag_import/postproc $(DATAOUTDIR)/postproc

bin/esmApp: $(ALL_OBJS) | dirs
	$(FC) -o $@ $(ALL_OBJS) $(LDFLAGS_ALL)

FORCE:
	@true

# =============================================================================
# Regras de compilação — 6 camadas (L0 → L5)
# =============================================================================

# L0 — tipos base e utilitários (sem dependências entre si)
#
# mpi_allreduce_r8 e mpi_allreduce_i4 ficam em arquivos separados.
# O backend gfortran/Cray cruza tipos de sendbuf/recvbuf entre chamadas ao
# mesmo símbolo externo visíveis no arquivo — arquivos isolados fecham o
# escopo de análise e eliminam type-mismatch espúrio.
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

# L1
$(OBJDIR)/mpas_cap_config.o: $(ATM_DIR)/mpas_cap_config.F90 \
                              $(OBJDIR)/mpas_cap_utils.o | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_atm_model.o: $(ATM_DIR)/mpas_atm_model.F90 \
                             $(OBJDIR)/mpas_atm_types.o    \
                             $(OBJDIR)/mpas_cap_config.o   \
                             $(OBJDIR)/mpas_cap_utils.o    | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_cap_netcdf.o: $(ATM_DIR)/mpas_cap_netcdf.F90       \
                              $(OBJDIR)/mpi_allreduce_wrappers.o   \
                              $(OBJDIR)/mpas_atm_types.o           \
                              $(OBJDIR)/mpas_cap_config.o          \
                              $(OBJDIR)/mpas_cap_utils.o           | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L2
$(OBJDIR)/mpas_atm_wrappers.o: $(ATM_DIR)/mpas_atm_wrappers.F90 \
                                $(OBJDIR)/mpas_atm_model.o | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

$(OBJDIR)/mpas_cap_methods.o: $(ATM_DIR)/mpas_cap_methods.F90 \
                               $(OBJDIR)/mpas_atm_types.o      \
                               $(OBJDIR)/mpas_atm_model.o      \
                               $(OBJDIR)/mpas_cap_utils.o      | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L3 — caps principais (recompilados sempre via _FORCE para garantir .mod)
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

# L2-MED — módulos do mediador
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

# --- Módulos de suporte ao cap oceânico (fontes upstream MOM6) --------------
# Definem os símbolos referenciados por mom_cap_MONAN.F90:
#   mom_import / mom_export / mom_set_geomtype          (MOM_cap_methods)
#   ocean_model_init/end / update / get_ocean_grid      (MOM_ocean_model_nuopc)
#   esmf2fms_time(step)                                  (time_utils_mod)
# Ordem de dependência (obrigatória):
#   surface_forcing -> ocean_model_nuopc -> cap_methods -> time_utils
$(OBJDIR)/mom_surface_forcing_nuopc.o: $(UPSTREAM_DIR)/mom_surface_forcing_nuopc.F90 | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

$(OBJDIR)/mom_ocean_model_nuopc.o: $(UPSTREAM_DIR)/mom_ocean_model_nuopc.F90 \
                                   $(OBJDIR)/mom_surface_forcing_nuopc.o     | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

$(OBJDIR)/mom_cap_methods.o: $(UPSTREAM_DIR)/mom_cap_methods.F90    \
                             $(OBJDIR)/mom_ocean_model_nuopc.o      \
                             $(OBJDIR)/mom_surface_forcing_nuopc.o  | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

$(OBJDIR)/time_utils.o: $(SHARED_DIR)/time_utils.F90 \
                        $(OBJDIR)/mom_cap_methods.o  | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

# Cap NUOPC/ESMF do componente oceânico MOM6+SIS2 (acoplamento dinâmico).
$(OBJDIR)/mom_cap_MONAN.o: $(OCN_DIR)/mom_cap_MONAN.F90           \
                           $(OBJDIR)/mom_surface_forcing_nuopc.o  \
                           $(OBJDIR)/mom_ocean_model_nuopc.o      \
                           $(OBJDIR)/mom_cap_methods.o            \
                           $(OBJDIR)/time_utils.o                 | dirs
	$(FC) $(MOM6_FCFLAGS) -c -o $@ $<

# L4 — driver ESM
# esm.o depende de mom_cap_MONAN.o porque usa:
#   'use MOM_cap_MONAN_mod, only: OCN_SetServices => SetServices'
$(OBJDIR)/esm.o: $(DRIVER_DIR)/esm.F90        \
                 $(OBJDIR)/mpas_cap_MONAN.o   \
                 $(OBJDIR)/MED_cap.o          \
                 $(OBJDIR)/DATM_cap.o         \
                 $(OBJDIR)/DOCN_cap.o         \
                 $(OBJDIR)/mom_cap_MONAN.o    \
                 $(OBJDIR)/mpas_cap_utils.o   | dirs
	$(FC) $(F90FLAGS) -c -o $@ $<

# L5 — ponto de entrada
$(OBJDIR)/esmApp.o: $(MAIN_DIR)/esmApp.F90    \
                    $(OBJDIR)/esm.o            \
                    $(OBJDIR)/mpas_cap_config.o \
                    $(OBJDIR)/mpas_cap_utils.o  | dirs
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
	@echo "    make              → compila bin/esmApp  (padrão: make all)"
	@echo "    make clean        → remove build/ bin/ logs/  [dados preservados]"
	@echo "    make distclean    → clean + remove diag_export/ diag_import/ *.pbs"
	@echo "    make rebuild      → make clean + make all em uma etapa"
	@echo "    make printenv     → exibe variáveis de compilação"
	@echo "    make diagnose     → inspeciona estado do build"
	@echo "    make help         → esta mensagem"
	@echo ""
	@echo "  Pré-requisito: source setenv-gnu.bash"
	@echo ""

# clean — remove APENAS artefatos de build. Dados em diag_export/ e
# diag_import/ são preservados. Use 'distclean' para removê-los também.
clean:
	@echo "  Limpando artefatos de build (build/, bin/, logs/)..."
	rm -rf $(BUILDDIR) $(BINDIR) $(LOGSDIR)
	rm -f *.stdout log.atmosphere.*.out
	@echo "  Dados em $(DATAOUTDIR)/ e diag_import/ preservados."

# distclean — clean + dados diagnósticos. ATENÇÃO: remove todos os NetCDF
# e CSV de experimentos anteriores. Faça backup antes de executar.
distclean: clean
	@echo "  Removendo dados diagnósticos ($(DATAOUTDIR)/, diag_import/)..."
	rm -rf $(DATAOUTDIR) diag_import
	rm -f *.pbs

rebuild: clean all

printenv:
	@echo ""
	@echo "======================================================================"
	@echo "  Makefile v$(VERSION) — variáveis de build"
	@echo "======================================================================"
	@echo "  Compilador"
	@echo "    FC           = $(FC)"
	@echo ""
	@echo "  Diretórios de código-fonte"
	@echo "    ATM_DIR      = $(ATM_DIR)"
	@echo "    OCN_DIR      = $(OCN_DIR)"
	@echo "    MEDIATOR_DIR = $(MEDIATOR_DIR)"
	@echo "    SHARED_DIR   = $(SHARED_DIR)"
	@echo ""
	@echo "  Ambientes ESMF / MPAS"
	@echo "    ESMFMKFILE   = $(ESMFMKFILE)"
	@echo "    MPAS_DIR     = $(MPAS_DIR)"
	@echo ""
	@echo "  MOM6+SIS2"
	@echo "    HAS_MOM6     = $(if $(HAS_MOM6),sim ($(MOM6_LIBDIR)),não — stub OCN)"
	@echo ""
	@echo "  Diretórios de build"
	@echo "    MODDIR       = $(MODDIR)"
	@echo "    OBJDIR       = $(OBJDIR)"
	@echo "    BINDIR       = $(BINDIR)"
	@echo ""
	@echo "  F90FLAGS (resumo)"
	@echo "    $(F90FLAGS)" | tr ' ' '\n' | sed 's/^/    /'
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
	  echo "  $(BINDIR)/esmApp  [AUSENTE] — executar make"; \
	fi
	@echo ""
	@echo "--- MOM6+SIS2 ---"
	@echo "  HAS_MOM6     = $(if $(HAS_MOM6),sim,não)"
	@echo "  MOM6_LIBDIR  = $(MOM6_LIBDIR)"
	@echo ""
	@echo "--- FORCE targets ---"
	@echo "  _FORCE_CAP = $(_FORCE_CAP)"
	@echo "  _FORCE_MED = $(_FORCE_MED)"
	@echo ""
	@echo "--- Módulos compilados (build/mod/) ---"
	@ls $(MODDIR)/*.mod 2>/dev/null | wc -l | xargs -I{} echo "  {} módulos .mod"
	@ls $(MODDIR)/*.mod 2>/dev/null | sed 's|.*/||' | column -c 78 | sed 's/^/    /' || echo "  (vazio)"
	@echo ""
	@echo "--- Objetos compilados (build/obj/) ---"
	@ls $(OBJDIR)/*.o 2>/dev/null | wc -l | xargs -I{} echo "  {} objetos .o de $(words $(ALL_OBJS)) esperados"
	@echo ""
