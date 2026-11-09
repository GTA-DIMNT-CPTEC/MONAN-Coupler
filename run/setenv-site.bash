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
#         export ESMFMKFILE=/meu/caminho/esmf-8.9.1/lib/libO/<config>/esmf.mk
#         bash build.bash
#   - Outra máquina: copie este arquivo para install/site-<host>.bash, ajuste
#     os valores e aponte os scripts para ele:
#         export SITE_ENV=install/site-meuhost.bash
#         bash build.bash
#
# MECANISMO: cada parâmetro usa ':= valor' — o valor só é aplicado se a
# variável ainda não estiver definida. Assim, qualquer 'export VAR=...' feito
# antes do source tem prioridade sobre o padrão do sítio.
# =============================================================================

# ── ESMF 8.9.1 ───────────────────────────────────────────────────────────────
# Na Jaci, o ESMF vem do módulo do sítio esmf/8.9.1-gcc13, carregado junto com
# as listas MODULES_MONAN e MODULES_MOM6 abaixo. O esmf.mk é o ponto de verdade
# do ESMF (compilador, flags de compile/link); o Makefile o inclui. O subcaminho
# codifica a configuração de build (Unicos / gfortran / MPI do Cray / otimizado).
#
# Os caminhos são definidos aqui também, e não apenas pelo módulo, porque este
# arquivo é lido ANTES do 'module load' e deriva ESMF_MOD/ESMF_LIBDIR logo adiante.
#
# Para usar outra instalação (ex.: um build local), exporte ESMFMKFILE antes de
# rodar o instalador. O módulo é então deixado de fora automaticamente: ao ser
# carregado, ele redefiniria ESMFMKFILE e misturaria duas instalações do ESMF.
# Para não carregar o módulo em caso algum: export ESMF_MODULE=
_esmf_mod_root="/p/app/esmf/8.9.1/gcc13"
_esmf_mod_mk="${_esmf_mod_root}/lib/libO/Unicos.gfortran.64.mpi.default/esmf.mk"
_esmf_module="${ESMF_MODULE-esmf/8.9.1-gcc13}"

: "${ESMF_ROOT:=${_esmf_mod_root}}"
: "${ESMFMKFILE:=${ESMF_ROOT}/lib/libO/Unicos.gfortran.64.mpi.default/esmf.mk}"
export ESMF_ROOT ESMFMKFILE

if [[ -n "${_esmf_module}" && "${ESMFMKFILE}" != "${_esmf_mod_mk}" ]]; then
  echo "AVISO: ESMFMKFILE definido fora do módulo ${_esmf_module}; o módulo NÃO será carregado." >&2
  echo "       ESMFMKFILE=${ESMFMKFILE}" >&2
  echo "       Se isso não foi intencional, abra uma sessão nova ou faça: unset ESMF_ROOT ESMFMKFILE ESMF_MOD ESMF_LIBDIR" >&2
  _esmf_module=""
fi

# ── ESMF: diretórios de módulos e bibliotecas (derivados do esmf.mk) ──────────
# ESMFMKFILE é a fonte única de verdade do ESMF. Os builds do acoplador — em
# especial o MONAN-A com -DMPAS_EXTERNAL_ESMF_LIB — precisam de ESMF_MOD (dir do
# esmf.mod) e ESMF_LIBDIR (dir da libesmf.a) no ambiente: o Makefile do
# MONAN-Model injeta -I$(ESMF_MOD) (à frente do stub src/external/esmf_time_f90)
# e -L$(ESMF_LIBDIR) -lesmf a partir delas. Derivamos aqui, na config de sítio,
# para que tanto os instaladores quanto as sessões de build
# (source run/setenv-gnu.bash) herdem sem recalcular. Respeita override: só
# deriva o que ainda não estiver definido. Bloco auto-contido (não depende de
# include.bash), pois o setenv do acoplador faz source desta config diretamente.
if [[ -f "${ESMFMKFILE}" ]]; then
  _esmf_mk_get() {
    printf 'include %s\n_v:\n\t@echo $(%s)\n' "${ESMFMKFILE}" "$1" \
      | make -s -f - _v 2>/dev/null
  }
  # ESMF_MOD — diretório do esmf.mod (entre os -I de ESMF_F90COMPILEPATHS).
  if [[ -z "${ESMF_MOD:-}" ]]; then
    for _p in $(_esmf_mk_get ESMF_F90COMPILEPATHS); do
      _p="${_p#-I}"
      if [[ -f "${_p}/esmf.mod" ]]; then ESMF_MOD="${_p}"; break; fi
    done
  fi
  # ESMF_LIBDIR — diretório da libesmf. NÃO usamos a variável ESMF_LIBDIR do
  # esmf.mk: ela não existe em todas as versões/builds do ESMF. Derivamos pelo
  # -L canônico (ESMF_F90LINKPATHS, onde -lesmf resolve) e, como rede de
  # segurança, pelo diretório do próprio esmf.mk — onde o ESMF instala as libs.
  if [[ -z "${ESMF_LIBDIR:-}" ]]; then
    for _p in $(_esmf_mk_get ESMF_F90LINKPATHS); do
      _p="${_p#-L}"
      if [[ -e "${_p}/libesmf.a" || -e "${_p}/libesmf.so" ]]; then ESMF_LIBDIR="${_p}"; break; fi
    done
    [[ -z "${ESMF_LIBDIR:-}" ]] && ESMF_LIBDIR="$(cd "$(dirname "${ESMFMKFILE}")" && pwd)"
  fi
  unset _p
  unset -f _esmf_mk_get
  export ESMF_LIBDIR ESMF_MOD
fi

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
#   • cray-parallel-netcdf (PNETCDF)   → I/O paralelo do modelo (via SMIOL);
#   • cray-netcdf-hdf5parallel (NetCDF) → o link do MPAS referencia -lnetcdf
#     -lnetcdff em utilitários (ex.: build_tables) e no executável. SEM ele:
#     "ld: cannot find -lnetcdf". Ele exige o cray-hdf5-parallel (NetCDF-4 é
#     construído sobre HDF5), por isso ambos entram aqui.
#
# A variante PARALELA é obrigatória com o módulo esmf/8.9.1-gcc13: a libesmf.so
# foi ligada a ela, e o próprio módulo tenta carregá-la. Com cray-netcdf e
# cray-hdf5 seriais, o módulo acusa conflito e o bin/esmApp acaba carregando
# duas HDF5 no mesmo processo. Não volte às variantes seriais sem trocar o ESMF.
# O PrgEnv-gnu já traz, nos defaults corretos, o toolchain GNU, o
# cray-mpich/8.1.31, o xpmem e a pilha de rede (libfabric); listá-los seria
# redundante. O módulo do ESMF entra por último, depois do PrgEnv-gnu.
#
# Removidos desta lista (não são necessários para COMPILAR):
#   • grads, cdo, ncview, cray-python → pós-processamento. As listas de módulos
#     só são usadas pelos instaladores; a execução (run_esmApp.jaci) e os
#     scripts Python de pós-proc carregam o que precisam por conta própria.
#   • cray-pals → lançador de jobs (PALS), usado só em tempo de execução.
MODULES_MONAN=(
  "${CPU_TARGET}"
  PrgEnv-gnu/8.6.0
  cray-hdf5-parallel/1.14.3.3
  cray-netcdf-hdf5parallel/4.9.0.15
  cray-parallel-netcdf/1.12.3.15
  METIS/5.1.0
  ${_esmf_module:+"${_esmf_module}"}
)

# ── Módulos para compilar o MOM6+SIS2+FMS (instalador 2) ─────────────────────
# MOM6/FMS usa o NetCDF da variante paralela (cray-netcdf-hdf5parallel), a mesma
# do ESMF (ver a nota nos módulos do MONAN-A). Ele é construído sobre HDF5, por
# isso cray-hdf5-parallel É necessário aqui. O cray-parallel-netcdf não é listado,
# mas chega pelo módulo do ESMF; o FMS não o utiliza.
# O PrgEnv-gnu já fornece o cray-mpich/8.1.31 e a pilha de rede (libfabric) nos
# defaults corretos; listá-los seria redundante.
#
# Removidos desta lista (não são necessários para COMPILAR):
#   • autoconf → o build usa mkmf (Perl, embutido no MOM6-examples), não autotools.
#   • cray-pals → lançador de jobs (PALS), usado só em tempo de execução.
MODULES_MOM6=(
  "${CPU_TARGET}"
  PrgEnv-gnu/8.6.0
  cray-hdf5-parallel/1.14.3.3
  cray-netcdf-hdf5parallel/4.9.0.15
  ${_esmf_module:+"${_esmf_module}"}
)

unset _esmf_mod_root _esmf_mod_mk _esmf_module
