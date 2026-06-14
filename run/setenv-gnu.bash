#!/bin/bash
# =============================================================================
# setenv-gnu.bash — Ambiente de compilação: MONAN-A 2.0 × MOM6+SIS2
# NUOPC/ESMF 8.9.1 | INPE / CGCT / DIMNT — GT Acoplamento de Modelos
# Versão 14.0 — Junho 2026
#
# v14.0 — Remoção de hardcodes e robustez:
#   - ESMF: ESMFMKFILE como ponto único (sobrescrevível); ESMF_LIBDIR
#     derivado do esmf.mk; ESMF_ROOT sobrescrevível; ESMF_MOD removido
#     (não consumido pelo build).
#   - MOM6_ROOT passa a derivar da raiz do acoplador (onde o instalador
#     deposita lib/{mom6,fms,nuopc}), eliminando o caminho fixo.
#   - MOAB: toggle USE_EXTERNAL_MOAB (padrão 'no', pois o MOAB é interno
#     ao libesmf.so); caminho pessoal do Kubota removido.
#   - pNetCDF: prefixo detectado do módulo Cray, com fallback sobrescrevível.
#   - Robustez sob 'set -euo pipefail': 'find | head' protegidos com
#     '|| true' (evita abort silencioso quando sourced pelos instaladores);
#     verificações tolerantes a variáveis ausentes (set -u).
# v13.0 — Colorização da saída de verificação (verde/amarelo/vermelho);
#   exibição da versão do ESMF extraída de esmf.mk; MOM6_HDR_INC com
#   quoting seguro nos paths (suporta caminhos com espaços); limpeza
#   de variáveis auxiliares ao final; melhorias de legibilidade geral.
# v12.1 — MPAS_DIR, MONAN2_MODDIR e MONAN2_LIBDIR derivados da localização
#   do próprio script (run/ → ..), eliminando o caminho fixo e tornando
#   a árvore relocável.
# v12.0 — Layout consolidado do instalador 1-install-monan.bash:
#   .mod em mod/monan2; libs .a em lib/monan2.
#
# USO (deve ser sourced, não executado):
#   source run/setenv-gnu.bash   ou   . run/setenv-gnu.bash
#
# MODOS OCN — configuráveis em nuopc.input (&nuopc_mode):
#   use_datm=F  use_docn=F  →  MPAS real  + MOM6 dinâmico  (produção)
#   use_datm=F  use_docn=T  →  MPAS real  + DOCN SST dados  (Fase 1)
#   use_datm=T  use_docn=F  →  DATM JRA55 + MOM6 dinâmico  (teste MOM6)
#   use_datm=T  use_docn=T  →  DATM JRA55 + DOCN SST dados  (teste MED)
#
# COMPILAÇÃO E EXECUÇÃO:
#   make                             → compila bin/esmApp
#   make clean                       → remove build/ bin/
#   make distclean                   → clean + remove *.pbs
#   make rebuild                     → make clean + make all
#   bash run/run_esmApp.jaci -n 128  → submete via PBS (128 PETs)
# =============================================================================

# --- Guarda: impede execução direta ------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERRO: execute com 'source run/setenv-gnu.bash', não diretamente."
  exit 1
fi

# =============================================================================
# Colorização inline (independente da _lib_install.bash, pois este script
# é sourced e pode ser chamado antes dos instaladores)
# =============================================================================
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1; then
  _CV_VD=$(tput setaf 2)    # verde   — OK
  _CV_AM=$(tput setaf 3)    # amarelo — ausente / aviso
  _CV_VM=$(tput setaf 1)    # vermelho — erro
  _CV_AZ=$(tput setaf 6)    # ciano   — informação
  _CV_BD=$(tput bold)       # negrito
  _CV_RS=$(tput sgr0)       # reset
else
  _CV_VD="" ; _CV_AM="" ; _CV_VM="" ; _CV_AZ="" ; _CV_BD="" ; _CV_RS=""
fi

# =============================================================================
# Funções de verificação (removidas ao final do script via unset -f)
# =============================================================================
_OK=0 ; _MISS=0

_chk_file() {
  if [[ -f "$1" ]]; then
    printf "  ${_CV_VD}OK    ${_CV_RS}%s\n" "$1"
    _OK=$(( _OK + 1 ))
  else
    printf "  ${_CV_AM}FALTA ${_CV_RS}%s\n" "$1"
    _MISS=$(( _MISS + 1 ))
  fi
}

_chk_dir() {
  if [[ -d "$1" ]]; then
    printf "  ${_CV_VD}OK    ${_CV_RS}%s\n" "$1"
    _OK=$(( _OK + 1 ))
  else
    printf "  ${_CV_AM}FALTA ${_CV_RS}%s\n" "$1"
    _MISS=$(( _MISS + 1 ))
  fi
}

# =============================================================================
# [1] ESMF 8.9.1 — ponto único de configuração: ESMFMKFILE
#
# O esmf.mk é incluído diretamente pelo Makefile do acoplador (fornece
# ESMF_F90COMPILER, ESMF_F90COMPILEPATHS, ESMF_F90LINK*, etc.). Aqui basta
# o próprio esmf.mk e o diretório de libs (para LD_LIBRARY_PATH e verificação).
#
# Sobrescreva antes do source para usar outra instalação:
#   export ESMFMKFILE=/caminho/para/esmf.mk      (tem prioridade)
#   export ESMF_ROOT=/raiz/da/instalacao/esmf    (layout padrão lib/libO/...)
# =============================================================================
export ESMF_ROOT="${ESMF_ROOT:-/p/projetos/monan_adm/daniel.massaru/Acopladores/esmf-8.9.1}"
export ESMFMKFILE="${ESMFMKFILE:-${ESMF_ROOT}/lib/libO/Linux.gfortran.64.mpich2.default/esmf.mk}"
# ESMF_LIBDIR é sempre o diretório do esmf.mk — robusto a override de ESMFMKFILE.
export ESMF_LIBDIR="$(dirname "${ESMFMKFILE}")"

# Versão do ESMF, extraída do próprio esmf.mk (apenas informativo).
if [[ -f "${ESMFMKFILE}" ]]; then
  _esmf_ver=$(grep -m1 'ESMF_VERSION_STRING' "${ESMFMKFILE}" \
              | sed 's/.*= *//' | tr -d '[:space:]' 2>/dev/null || echo "?")
else
  _esmf_ver="(esmf.mk não encontrado)"
fi

# =============================================================================
# [2] MONAN-A 2.0 (MPAS-A 8.3.1)
#
# O instalador 1-install-monan.bash consolida TODOS os artefatos em dois
# diretórios únicos, irmãos de MONAN-Model:
#   <raiz>/mod/monan2   → módulos (.mod)
#   <raiz>/lib/monan2   → bibliotecas estáticas (.a)
#
# A raiz é derivada da localização deste script (run/ → ..), tornando a
# árvore relocável. Para usar um caminho alternativo, defina as variáveis
# abaixo ANTES de executar o source:
#   export MPAS_DIR=/outro/caminho/MONAN-Model
#   export MONAN2_MODDIR=/outro/caminho/mod/monan2
#   export MONAN2_LIBDIR=/outro/caminho/lib/monan2
# =============================================================================
_COUPLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MPAS_DIR="${MPAS_DIR:-${_COUPLER_ROOT}/MONAN-Model}"
export MONAN2_MODDIR="${MONAN2_MODDIR:-${_COUPLER_ROOT}/mod/monan2}"
export MONAN2_LIBDIR="${MONAN2_LIBDIR:-${_COUPLER_ROOT}/lib/monan2}"

# MPAS_MOD_DIR: alias para compatibilidade com scripts legados
export MPAS_MOD_DIR="${MONAN2_MODDIR}"

# =============================================================================
# [3] GFORTRAN_CONVERT_UNIT — leitura de RRTMG_SW_DATA.DBL (big-endian)
#
# O alvo gfortran-xd2000 compila o MPAS com -fconvert=big-endian. Sem esta
# variável, o RRTMG aborta: "error reading RRTMG_SW_DATA on unit 101".
# =============================================================================
export GFORTRAN_CONVERT_UNIT='big_endian:101'

# =============================================================================
# [4] MOM6+SIS2
#
# Por padrão, MOM6_ROOT é a própria raiz do acoplador — é onde o instalador
# 2-install-mom.bash deposita lib/{mom6,fms,nuopc} e mod/{...}. Para usar uma
# instalação MOM6 separada, redefina MOM6_ROOT antes do source; os demais
# caminhos se ajustam automaticamente.
# =============================================================================
export MOM6_ROOT="${MOM6_ROOT:-${_COUPLER_ROOT}}"

export MOM6_LIBDIR="${MOM6_LIBDIR:-${MOM6_ROOT}/lib/mom6}"
export MOM6_MODDIR="${MOM6_MODDIR:-${MOM6_ROOT}/mod/mom6}"

export FMS_LIBDIR="${FMS_LIBDIR:-${MOM6_ROOT}/lib/fms}"      # Flexible Modeling System
export FMS_MODDIR="${FMS_MODDIR:-${MOM6_ROOT}/mod/fms}"

export NUOPC_LIBDIR="${NUOPC_LIBDIR:-${MOM6_ROOT}/lib/nuopc}"
export NUOPC_MODDIR="${NUOPC_MODDIR:-${MOM6_ROOT}/mod/nuopc}"

# MOAB — interno ao libesmf.so nesta instalação (sem libMOAB.so externo).
#   USE_EXTERNAL_MOAB=no  (padrão): não injeta MOAB externo no build.
#   USE_EXTERNAL_MOAB=yes          : exige MOAB_DIR apontando para o MOAB externo
#                                    (export MOAB_DIR=... antes do source).
export USE_EXTERNAL_MOAB="${USE_EXTERNAL_MOAB:-no}"

# pNetCDF — prefixo detectado do módulo Cray (cray-parallel-netcdf), com
# fallback sobrescrevível via PNETCDF_DIR.
export PNETCDF_DIR="${PNETCDF_DIR:-${CRAY_PARALLEL_NETCDF_PREFIX:-${CRAY_PARALLEL_NETCDF_DIR:-/opt/cray/pe/parallel-netcdf/1.12.3.15/GNU/12.3}}}"

# =============================================================================
# [5] MOM6_HDR_INC — cabeçalhos para recompilação dos caps upstream MOM6
#
# Os fontes em src/caps/ocean/upstream/ incluem:
#   #include <MOM_memory.h>       → macros de memória (dynamic_symmetric)
#   #include "version_variable.h" → string de versão (FMS)
#
# Esses .h NÃO estão em include/mom6; ficam na árvore de fontes do MOM6.
# MOM6_SRC aponta para a raiz dos fontes. Redefina antes do source se a
# árvore de fontes estiver em local diferente de ${MOM6_ROOT}/src.
# =============================================================================
export MOM6_SRC="${MOM6_SRC:-${MOM6_ROOT}/src}"

if [[ -z "${MOM6_HDR_INC:-}" ]]; then
  # Busca com quoting correto nos caminhos (suporta espaços)
  _mommem=$(find "${MOM6_SRC}" "${MOM6_ROOT}" -name MOM_memory.h 2>/dev/null \
            | grep -m1 dynamic_symmetric || true)
  [[ -z "${_mommem}" ]] && \
    _mommem=$(find "${MOM6_SRC}" "${MOM6_ROOT}" -name MOM_memory.h 2>/dev/null \
              | head -1 || true)
  _vervar=$(find "${MOM6_SRC}" "${MOM6_ROOT}" -name version_variable.h 2>/dev/null \
            | head -1 || true)
  MOM6_HDR_INC=""
  [[ -n "${_mommem}" ]] && MOM6_HDR_INC="-I$(dirname "${_mommem}")"
  [[ -n "${_vervar}" ]] && MOM6_HDR_INC="${MOM6_HDR_INC} -I$(dirname "${_vervar}")"
  export MOM6_HDR_INC
  unset _mommem _vervar
fi

# =============================================================================
# [6] LD_LIBRARY_PATH
#
# Idioma "${NOVO}${VAR:+:${VAR}}": insere ':paths_anteriores' somente se
# VAR não está vazio, evitando trailing colon (que inclui '.' no search).
#
# As libs do MONAN-A são estáticas (.a) — lib/monan2 é incluído por
# coerência, mas não é exigido em tempo de execução. Ordem (→ prioridade):
#   NUOPC → MOM6 → FMS → MOAB → MONAN-A → ESMF
# =============================================================================
export LD_LIBRARY_PATH=\
${MONAN2_LIBDIR}:\
${ESMF_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

if [[ "${USE_EXTERNAL_MOAB}" == "yes" && -n "${MOAB_DIR:-}" && -d "${MOAB_DIR}/lib" ]]; then
  export LD_LIBRARY_PATH="${MOAB_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
[[ -d "${FMS_LIBDIR}"    ]] && export LD_LIBRARY_PATH="${FMS_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -d "${MOM6_LIBDIR}"   ]] && export LD_LIBRARY_PATH="${MOM6_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -d "${NUOPC_LIBDIR}"  ]] && export LD_LIBRARY_PATH="${NUOPC_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# =============================================================================
# Verificação do ambiente (5 seções)
# =============================================================================
echo ""
printf "${_CV_BD}%s${_CV_RS}\n" \
  "======================================================================"
printf "${_CV_BD}  Ambiente: MONAN-A 2.0 × MOM6+SIS2 / ESMF 8.9.1  |  setenv v14.0${_CV_RS}\n"
printf "${_CV_BD}  INPE / CGCT / DIMNT — GT Acoplamento de Modelos${_CV_RS}\n"
printf "${_CV_BD}%s${_CV_RS}\n" \
  "======================================================================"
echo ""

printf "  %-26s: %s\n" "ESMFMKFILE"            "${ESMFMKFILE}"
printf "  %-26s: %s\n" "ESMF versão"           "${_esmf_ver}"
printf "  %-26s: %s\n" "MPAS_DIR"              "${MPAS_DIR}"
printf "  %-26s: %s\n" "MONAN2_MODDIR"         "${MONAN2_MODDIR}"
printf "  %-26s: %s\n" "MONAN2_LIBDIR"         "${MONAN2_LIBDIR}"
printf "  %-26s: %s\n" "GFORTRAN_CONVERT_UNIT" "${GFORTRAN_CONVERT_UNIT}"
printf "  %-26s: %s\n" "MOM6_ROOT"             "${MOM6_ROOT}"
printf "  %-26s: %s\n" "USE_EXTERNAL_MOAB"     "${USE_EXTERNAL_MOAB}"

if [[ -z "${MOM6_HDR_INC:-}" ]]; then
  printf "  %-26s: ${_CV_AM}%s${_CV_RS}\n" "MOM6_HDR_INC" \
    "NÃO ENCONTRADO — caps upstream não compilarão"
else
  printf "  %-26s: %s\n" "MOM6_HDR_INC" "${MOM6_HDR_INC}"
fi
echo ""

# ── [1/5] ESMF ───────────────────────────────────────────────────────────────
echo "  [1/5] ESMF:"
_chk_file "${ESMFMKFILE}"
_chk_file "${ESMF_LIBDIR}/libesmf.so"
echo ""

# ── [2/5] MONAN-A 2.0 — 6 bibliotecas estáticas (lib/monan2) ─────────────────
echo "  [2/5] MONAN-A 2.0 (6 libs em lib/monan2):"
for _lib in libframework.a libdycore.a libphys.a libops.a libsmiolf.a libsmiol.a; do
  _chk_file "${MONAN2_LIBDIR}/${_lib}"
done
unset _lib
_chk_dir "${MONAN2_MODDIR}"
echo ""

# ── [3/5] Caps de dados sintéticos ───────────────────────────────────────────
echo "  [3/5] Caps de dados sintéticos (DATM/DOCN):"
_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_chk_file "${_WORKDIR}/src/caps/ocean/DOCN_cap.F90"
_chk_file "${_WORKDIR}/src/caps/atmos/DATM_cap.F90"
unset _WORKDIR
echo ""

# ── [4/5] MOM6+SIS2 — diretórios de bibliotecas e módulos ────────────────────
echo "  [4/5] MOM6+SIS2 (diretórios de libs e módulos):"
_chk_dir "${MOM6_LIBDIR}"
_chk_dir "${MOM6_MODDIR}"
_chk_dir "${FMS_LIBDIR}"
_chk_dir "${FMS_MODDIR}"
_chk_dir "${NUOPC_LIBDIR}"
_chk_dir "${NUOPC_MODDIR}"
echo ""

# ── [5/5] Dependências externas ───────────────────────────────────────────────
echo "  [5/5] Dependências externas (MOAB, pNetCDF):"
if [[ "${USE_EXTERNAL_MOAB}" == "yes" ]]; then
  if [[ -n "${MOAB_DIR:-}" ]]; then
    _chk_dir "${MOAB_DIR}/lib"
  else
    printf "  ${_CV_VM}FALTA ${_CV_RS}%s\n" "USE_EXTERNAL_MOAB=yes mas MOAB_DIR não definido"
    _MISS=$(( _MISS + 1 ))
  fi
else
  printf "  ${_CV_AZ}—     ${_CV_RS}%s\n" "MOAB externo desabilitado (interno ao libesmf.so)"
fi
_chk_dir "${PNETCDF_DIR}/include"
echo ""

# ── Resumo global ─────────────────────────────────────────────────────────────
printf "%s\n" "----------------------------------------------------------------------"
if [[ "${_MISS}" -eq 0 ]]; then
  printf "  ${_CV_VD}Tudo OK${_CV_RS} (${_OK} itens verificados). Ambiente pronto para 'make'.\n"
else
  printf "  ${_CV_VM}AVISO${_CV_RS}: ${_MISS} item(ns) faltando (${_OK} OK). Corrija antes de compilar.\n"
fi
echo ""
echo "  LD_LIBRARY_PATH (primeiros 4 caminhos):"
printf '%s\n' "${LD_LIBRARY_PATH}" | tr ':' '\n' | head -4 | sed 's/^/    /'
echo "    [...]"
echo "======================================================================"
echo ""

# --- Limpeza de variáveis e funções auxiliares --------------------------------
unset _OK _MISS _esmf_ver _COUPLER_ROOT
unset _CV_VD _CV_AM _CV_VM _CV_AZ _CV_BD _CV_RS
unset -f _chk_file _chk_dir
