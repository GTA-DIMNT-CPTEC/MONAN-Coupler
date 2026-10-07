# Testes do framework de interpolação (src/regrid). Requer ESMFMKFILE.
#   make            compila ./test_regrid
#   make run NP=2   executa com NP processos MPI (num nó de cálculo;
#                   na Jaci, carregar antes o módulo cray-pals)
#   make test_scheme   compila o programa de compara-esquema.bash
include $(ESMFMKFILE)

SRC  := ../../src
FC   := $(ESMF_F90COMPILER)
FLAGS := $(ESMF_F90COMPILEOPTS) $(ESMF_F90COMPILEPATHS) -I. -J. \
         -ffree-line-length-none -fallow-argument-mismatch -O0 -g -fcheck=all \
         -Wall -Wno-unused-dummy-argument
LIBS := $(ESMF_F90LINKOPTS) $(ESMF_F90LINKPATHS) $(ESMF_F90LINKRPATHS) $(ESMF_F90ESMFLINKLIBS)
NP ?= 1

# Objetos de que cada programa depende, tirados dos 'use' (dependencias.py)
OBJETOS = $(shell python3 ../../tools/dev/dependencias.py objetos -s ../.. -i tests/regrid $(1))
vpath %.F90 $(SRC)/shared $(SRC)/regrid .

test_regrid: $(call OBJETOS,test_regrid.F90) test_regrid.o
	$(FC) -o $@ $^ $(LIBS)

test_scheme: $(call OBJETOS,test_scheme.F90) test_scheme.o
	$(FC) -o $@ $^ $(LIBS)

%.o: %.F90
	$(FC) $(FLAGS) -c $<

# dependências entre módulos: as do acoplador vêm de src/dependencies.mk
# (gerado por tools/dev/dependencias.py); as dos programas de teste, abaixo
OBJDIR := .
include $(SRC)/dependencies.mk
identity_scheme.o: regrid_weights_base.o
test_regrid.o: regrid_manager.o identity_scheme.o regrid_idw.o
test_scheme.o: regrid_manager.o

# Lançador MPI: na Jaci, dentro de um job, o 'mpiexec' do PBS (/opt/pbs/bin)
# aparece antes do Cray PALS no PATH e não funciona com o cray-mpich. Usa o do
# PALS quando existir (módulo cray-pals); senão, mpiexec ou mpirun do sistema.
MPIEXEC ?= $(or $(shell which -a mpiexec 2>/dev/null | grep /pals/ | head -1),\
                $(shell command -v mpiexec 2>/dev/null),mpirun)

run: test_regrid
	$(MPIEXEC) -n $(NP) ./test_regrid

clean:
	rm -f *.o *.mod test_regrid test_scheme PET*.log pesos_teste.nc pesos_idw.nc

.PHONY: run clean
