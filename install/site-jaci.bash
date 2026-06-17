#!/bin/bash
# =============================================================================
# site-jaci.bash — Configuração de sítio do acoplador MONAN-A 2.0 × MOM6+SIS2
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# ESTE É O ÚNICO ARQUIVO A EDITAR ao trocar de usuário, máquina ou versões de
# módulo. Centraliza tudo que é específico do ambiente (Jaci/Cray XD2000):
# caminho do ESMF, módulos a carregar, alvo de CPU, paralelismo e wrappers.
# Os scripts de instalação e o run/setenv-gnu.bash carregam este arquivo
# automaticamente — não é preciso chamá-lo à mão.
#
# COMO USAR
#   - Uso normal na Jaci: nada a fazer. Os padrões abaixo já estão corretos.
#   - Mudar um valor pontualmente, sem editar o arquivo: exporte a variável
#     antes de rodar o instalador. Ex.:
#         export MAKE_JOBS=16
#         export ESMF_ROOT=/meu/caminho/esmf-8.9.1
#         bash install/install-all.bash
#   - Outra máquina: copie este arquivo para install/site-<host>.bash, ajuste
#     os valores e aponte os scripts para ele:
#         export SITE_ENV=install/site-meuhost.bash
#         bash install/install-all.bash
#
# MECANISMO: cada parâmetro usa ':= valor' — o valor só é aplicado se a
# variável ainda não estiver definida. Assim, qualquer 'export VAR=...' feito
# antes do source tem prioridade sobre o padrão do sítio.
# =============================================================================

# ── ESMF 8.9.1 ───────────────────────────────────────────────────────────────
# Raiz da instalação do ESMF e o esmf.mk dela derivado. O esmf.mk é o ponto de
# verdade do ESMF (compilador, flags de compile/link); o Makefile o inclui.
# O subcaminho codifica a configuração de build do ESMF
# (gfortran / mpich2 / otimizado). Para outra instalação, basta trocar ESMF_ROOT;
# se o layout interno do ESMF for diferente, ajuste também ESMFMKFILE.
#
# Atenção: o sítio (módulos /p/app) oferece apenas esmf/8.8.0. Este projeto usa,
# de propósito, o build LOCAL 8.9.1 apontado abaixo — portanto NÃO faça
# 'module load esmf', para não misturar versões/ABI.
: "${ESMF_ROOT:=/p/projetos/monan_adm/daniel.massaru/Acopladores/esmf-8.9.1}"
: "${ESMFMKFILE:=${ESMF_ROOT}/lib/libO/Linux.gfortran.64.mpich2.default/esmf.mk}"
export ESMF_ROOT ESMFMKFILE

# ── Paralelismo de compilação ────────────────────────────────────────────────
# Jobs do 'make -j'. Padrão conservador (8) por etiqueta de nó de login
# compartilhado. Para usar todos os núcleos: export MAKE_JOBS=$(nproc).
: "${MAKE_JOBS:=8}"

# ── Alvo de CPU e alvo de build do MONAN-A ───────────────────────────────────
# CPU_TARGET: módulo de targeting do Cray. 'turin' = AMD Zen5 (nós XD2000).
#   Em outra arquitetura, ajuste (ex.: craype-x86-milan). É referenciado nas
#   listas de módulos abaixo, então muda em um só lugar.
# MONAN_TARGET: alvo do Makefile do MONAN-Model para este host/toolchain.
: "${CPU_TARGET:=craype-x86-turin}"
: "${MONAN_TARGET:=gfortran-coupler-xd2000}"

# ── Wrappers do compilador (Cray) ────────────────────────────────────────────
# Na Jaci, sempre os wrappers 'ftn'/'cc' (nunca gfortran/gcc direto).
: "${FC:=ftn}"
: "${CC:=cc}"
: "${LD:=ftn}"

# ── Bibliotecas estáticas do core 'atmosphere' do MONAN-A ────────────────────
# Conjunto verificado pelo instalador 1 e pelo setenv (fonte única — antes
# estava duplicado nos dois arquivos).
MONAN2_LIBS=(libframework.a libdycore.a libphys.a libops.a libsmiolf.a libsmiol.a)

# ── Módulos para compilar o MONAN-A (instalador 1) ───────────────────────────
# Lista MÍNIMA de compilação. O MPAS/MONAN-A usa DOIS NetCDFs:
#   • cray-parallel-netcdf (PNETCDF) → I/O paralelo do modelo (via SMIOL);
#   • cray-netcdf (NetCDF SERIAL)    → o link do MPAS referencia -lnetcdf
#     -lnetcdff em utilitários (ex.: build_tables) e no executável. SEM ele:
#     "ld: cannot find -lnetcdf". O cray-netcdf exige o cray-hdf5 (NetCDF-4
#     é construído sobre HDF5), por isso ambos entram aqui.
# O PrgEnv-gnu já traz, nos defaults corretos, o toolchain GNU, o
# cray-mpich/8.1.31, o xpmem e a pilha de rede (libfabric); listá-los seria
# redundante.
#
# Removidos desta lista (não são necessários para COMPILAR):
#   • grads, cdo, ncview, cray-python → pós-processamento. As listas de módulos
#     só são usadas pelos instaladores; a execução (run_esmApp.jaci) e os
#     scripts Python de pós-proc carregam o que precisam por conta própria.
#   • cray-pals → lançador de jobs (PALS), usado só em tempo de execução.
MODULES_MONAN=(
  "${CPU_TARGET}"
  PrgEnv-gnu/8.6.0
  cray-hdf5/1.14.3.3
  cray-netcdf/4.9.0.15
  cray-parallel-netcdf/1.12.3.15
  METIS/5.1.0
)

# ── Módulos para compilar o MOM6+SIS2+FMS (instalador 2) ─────────────────────
# MOM6/FMS usa NetCDF SERIAL (cray-netcdf), que é construído sobre HDF5 —
# por isso cray-hdf5 É necessário aqui. NÃO usar o parallel-netcdf neste build.
# O PrgEnv-gnu já fornece o cray-mpich/8.1.31 e a pilha de rede (libfabric) nos
# defaults corretos; listá-los seria redundante.
#
# Removidos desta lista (não são necessários para COMPILAR):
#   • autoconf → o build usa mkmf (Perl, embutido no MOM6-examples), não autotools.
#   • cray-pals → lançador de jobs (PALS), usado só em tempo de execução.
MODULES_MOM6=(
  "${CPU_TARGET}"
  PrgEnv-gnu/8.6.0
  cray-hdf5/1.14.3.3
  cray-netcdf/4.9.0.15
)
