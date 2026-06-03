#!/bin/bash
# =============================================================================
# setenv-gnu.bash — Ambiente de compilação: MONAN-A 2.0 × MOM6+SIS2
# NUOPC-ESMF 8.9.1 | INPE / CGCT / DIMNT — GT Acoplamento de Modelos
# Versão 11.0 — Maio 2026
#
# USO  (deve ser sourced, não executado):
#   source setenv-gnu.bash   ou   . setenv-gnu.bash
#
# MODOS OCN — configuráveis em nuopc.input (&nuopc_mode):
#   use_datm=F  use_docn=F  →  MPAS real  + MOM6 dinâmico  (produção)
#   use_datm=F  use_docn=T  →  MPAS real  + DOCN SST dados  (Fase 1)
#   use_datm=T  use_docn=F  →  DATM JRA55 + MOM6 dinâmico  (teste MOM6)
#   use_datm=T  use_docn=T  →  DATM JRA55 + DOCN SST dados  (teste MED)
#
# COMPILAÇÃO E EXECUÇÃO:
#   make                          → compila bin/esmApp
#   make clean                    → remove build/ bin/ logs/
#   make distclean                → clean + remove diag_export/ diag_import/
#   make rebuild                  → make clean + make all
#   bash run/run_esmApp.jaci -n 128  → submete via PBS (128 PETs)
# =============================================================================

# Impede execução direta — o script precisa ser sourced para exportar variáveis.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERRO: execute com 'source setenv-gnu.bash', não diretamente."
  exit 1
fi

# =============================================================================
# Funções auxiliares de verificação (removidas ao final do script)
# =============================================================================
_OK=0
_MISS=0

_check_file() {
  if [[ -f "$1" ]]; then
    printf "  %-6s: %s\n" "OK"   "$1"; ((_OK++))
  else
    printf "  %-6s: %s  <-- FALTANDO\n" "MISS" "$1"; ((_MISS++))
  fi
}

_check_dir() {
  if [[ -d "$1" ]]; then
    printf "  %-6s: %s\n" "OK"   "$1"; ((_OK++))
  else
    printf "  %-6s: %s  <-- FALTANDO\n" "MISS" "$1"; ((_MISS++))
  fi
}

# =============================================================================
# ESMF 8.9.1
# esmf.mk define: ESMF_F90COMPILER, ESMF_F90COMPILEPATHS, ESMF_F90LINKPATHS,
#                 ESMF_F90ESMFLIBS, etc. — incluído automaticamente pelo Makefile.
# =============================================================================
export ESMF_ROOT=/p/projetos/monan_adm/daniel.massaru/Acopladores/esmf-8.9.1
export ESMF_MOD=${ESMF_ROOT}/mod/modO/Linux.gfortran.64.mpich2.default
export ESMF_LIBDIR=${ESMF_ROOT}/lib/libO/Linux.gfortran.64.mpich2.default
export ESMFMKFILE=${ESMF_LIBDIR}/esmf.mk

# =============================================================================
# MONAN-A 2.0 (MPAS-A 8.3)
# Compilado com gfortran-xd2000 + SMIOL + PIO externo.
# Nota: lib/ contém symlinks quebrados — as bibliotecas reais estão em src/.
# =============================================================================
export MPAS_DIR=/p/projetos/monan_adm/daniel.massaru/Acopladores/system_coupler/MONAN-Coupler/MONAN-Model

# Detecta automaticamente o diretório de módulos (.mod) do MONAN-A:
#   build Makefile → src/framework/         (alvo gfortran-xd2000)
#   build cmake    → build/src/framework/
_MODFILE=$(find "${MPAS_DIR}" -name "mpas_kind_types.mod" 2>/dev/null | head -1)
if [[ -n "${_MODFILE}" ]]; then
  export MPAS_MOD_DIR="$(dirname "${_MODFILE}")"
else
  export MPAS_MOD_DIR="${MPAS_DIR}/src/framework"   # fallback: build Makefile
fi
unset _MODFILE

# =============================================================================
# GFORTRAN_CONVERT_UNIT — leitura de RRTMG_SW_DATA.DBL (big-endian)
# O alvo gfortran-xd2000 compila com -fconvert=big-endian. Sem esta variável,
# o RRTMG aborta: "error reading RRTMG_SW_DATA on unit 101".
# =============================================================================
export GFORTRAN_CONVERT_UNIT='big_endian:101'

# =============================================================================
# MOM6+SIS2
# Todas as variáveis derivam de MOM6_ROOT — para mover a instalação, basta
# redefinir MOM6_ROOT antes de executar o source.
# =============================================================================
export MOM6_ROOT="${MOM6_ROOT:-/p/projetos/monan_adm/daniel.massaru/Acopladores/mom6+sis2}"

export MOM6_LIBDIR="${MOM6_LIBDIR:-${MOM6_ROOT}/lib/mom6}"
export MOM6_MODDIR="${MOM6_MODDIR:-${MOM6_ROOT}/mod/mom6}"

export FMS_LIBDIR="${FMS_LIBDIR:-${MOM6_ROOT}/lib/fms}"     # Flexible Modeling System
export FMS_MODDIR="${FMS_MODDIR:-${MOM6_ROOT}/mod/fms}"

export NUOPC_LIBDIR="${NUOPC_LIBDIR:-${MOM6_ROOT}/lib/nuopc}"
export NUOPC_MODDIR="${NUOPC_MODDIR:-${MOM6_ROOT}/mod/nuopc}"

export MOAB_DIR="${MOAB_DIR:-/p/projetos/monan_adm/paulo.kubota/home/lib/lib_gnucray/libmoab}"
export PNETCDF_DIR="${PNETCDF_DIR:-/opt/cray/pe/parallel-netcdf/1.12.3.15/GNU/12.3}"

# -----------------------------------------------------------------------------
# Cabeçalhos C-preprocessor exigidos pela RECOMPILAÇÃO dos caps upstream MOM6
# (src/caps/ocean/upstream/). Os fontes fazem:
#     #include <MOM_memory.h>        -> macros de memória (dynamic_symmetric)
#     #include "version_variable.h"  -> string de versão (FMS)
# Esses .h NÃO estão em include/mom6; ficam na árvore de FONTES do MOM6.
# MOM6_SRC aponta para essa raiz (padrão: ${MOM6_ROOT}/src). Redefina antes
# do source se a árvore estiver em outro local.
# -----------------------------------------------------------------------------
export MOM6_SRC="${MOM6_SRC:-${MOM6_ROOT}/src}"

if [[ -z "${MOM6_HDR_INC:-}" ]]; then
  _roots="${MOM6_SRC} ${MOM6_ROOT}"
  _mommem=$(find ${_roots} -name MOM_memory.h 2>/dev/null | grep -m1 dynamic_symmetric)
  [[ -z "${_mommem}" ]] && _mommem=$(find ${_roots} -name MOM_memory.h 2>/dev/null | head -1)
  _vervar=$(find ${_roots} -name version_variable.h 2>/dev/null | head -1)
  MOM6_HDR_INC=""
  [[ -n "${_mommem}" ]] && MOM6_HDR_INC="-I$(dirname "${_mommem}")"
  [[ -n "${_vervar}" ]] && MOM6_HDR_INC="${MOM6_HDR_INC} -I$(dirname "${_vervar}")"
  export MOM6_HDR_INC
  unset _roots _mommem _vervar
fi

if [[ -z "${MOM6_HDR_INC}" ]]; then
  echo "  AVISO: MOM_memory.h / version_variable.h NAO encontrados."
  echo "         Defina MOM6_SRC (raiz dos fontes MOM6) e refaca o source,"
  echo "         ou exporte manualmente: MOM6_HDR_INC=\"-I<dir1> -I<dir2>\""
else
  echo "  MOM6_HDR_INC = ${MOM6_HDR_INC}"
fi

# =============================================================================
# LD_LIBRARY_PATH
# Idioma "${NOVO}${VAR:+:${VAR}}": insere ':paths_anteriores' apenas se VAR
# não está vazio, evitando trailing colon (que inclui '.' no search path).
#
# Ordem de resolução resultante (primeiro → último):
#   NUOPC → MOM6 → FMS → MOAB → MPAS (src/) → ESMF
# =============================================================================
export LD_LIBRARY_PATH=\
${MPAS_DIR}/src/framework:\
${MPAS_DIR}/src/core_atmosphere:\
${MPAS_DIR}/src/core_atmosphere/physics:\
${MPAS_DIR}/src/operators:\
${MPAS_DIR}/src/external/SMIOL:\
${ESMF_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

[[ -d "${MOAB_DIR}/lib"  ]] && export LD_LIBRARY_PATH="${MOAB_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -d "${FMS_LIBDIR}"    ]] && export LD_LIBRARY_PATH="${FMS_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -d "${MOM6_LIBDIR}"   ]] && export LD_LIBRARY_PATH="${MOM6_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -d "${NUOPC_LIBDIR}"  ]] && export LD_LIBRARY_PATH="${NUOPC_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# =============================================================================
# Verificação do ambiente (4 seções)
# =============================================================================
echo ""
echo "======================================================================"
echo "  Ambiente: MONAN-A 2.0 × MOM6+SIS2 / ESMF 8.9.1  |  setenv v11.0"
echo "  INPE / CGCT / DIMNT — GT Acoplamento de Modelos"
echo "======================================================================"
echo ""
echo "  ESMFMKFILE            : ${ESMFMKFILE}"
echo "  MPAS_DIR              : ${MPAS_DIR}"
echo "  MPAS_MOD_DIR          : ${MPAS_MOD_DIR}"
echo "  ESMF_LIBDIR           : ${ESMF_LIBDIR}"
echo "  GFORTRAN_CONVERT_UNIT : ${GFORTRAN_CONVERT_UNIT}"
echo "  MOM6_ROOT             : ${MOM6_ROOT}"
echo ""

# ── [1/4] ESMF ───────────────────────────────────────────────────────────────
echo "  [1/4] ESMF:"
_check_file "${ESMFMKFILE}"
_check_file "${ESMF_LIBDIR}/libesmf.so"
echo ""

# ── [2/4] MONAN-A 2.0 — 6 bibliotecas estáticas ──────────────────────────────
echo "  [2/4] MONAN-A 2.0 (6 libs):"
for _lib in \
  src/framework/libframework.a          \
  src/core_atmosphere/libdycore.a       \
  src/core_atmosphere/physics/libphys.a \
  src/operators/libops.a                \
  src/external/SMIOL/libsmiolf.a        \
  src/external/SMIOL/libsmiol.a; do
  _check_file "${MPAS_DIR}/${_lib}"
done
unset _lib
echo ""

# ── [3/4] Caps de dados sintéticos ───────────────────────────────────────────
# _WORKDIR sobe um nível a partir do diretório do script (run/ → raiz do projeto)
echo "  [3/4] Caps de dados sintéticos:"
_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_check_file "${_WORKDIR}/src/caps/ocean/DOCN_cap.F90"
_check_file "${_WORKDIR}/src/caps/atmos/DATM_cap.F90"
unset _WORKDIR
echo ""

# ── [4/4] MOM6+SIS2 — diretórios de bibliotecas e módulos ────────────────────
echo "  [4/4] MOM6+SIS2 (diretórios):"
_check_dir "${MOM6_LIBDIR}"
_check_dir "${MOM6_MODDIR}"
_check_dir "${FMS_LIBDIR}"
_check_dir "${FMS_MODDIR}"
_check_dir "${NUOPC_LIBDIR}"
_check_dir "${NUOPC_MODDIR}"
_check_dir "${MOAB_DIR}/lib"
_check_dir "${PNETCDF_DIR}/include"
echo ""

# ── Resumo global ─────────────────────────────────────────────────────────────
echo "----------------------------------------------------------------------"
if [[ "${_MISS}" -eq 0 ]]; then
  echo "  Tudo OK (${_OK} itens verificados). Ambiente pronto para 'make'."
else
  echo "  AVISO: ${_MISS} item(ns) faltando (${_OK} OK). Corrija antes de compilar."
fi
echo ""
echo "  LD_LIBRARY_PATH (primeiros 4 paths):"
printf '%s\n' "${LD_LIBRARY_PATH}" | tr ':' '\n' | head -4 | sed 's/^/    /'
echo "    [...]"
echo "======================================================================"
echo ""

unset _OK _MISS
unset -f _check_file _check_dir
