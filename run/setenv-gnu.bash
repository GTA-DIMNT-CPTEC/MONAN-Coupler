#!/bin/bash
# =============================================================================
# setenv-gnu.bash — Ambiente de compilação do acoplador MONAN-A 2.0 × MOM6+SIS2
# (NUOPC/ESMF 8.9.1). INPE / CGCT / DIMNT — GT Acoplamento de Modelos.
#
# Deve ser SOURCED, não executado:
#   source run/setenv-gnu.bash
#
# Define e exporta os caminhos de ESMF, MONAN-A e MOM6+SIS2 e verifica o
# ambiente. Todos os caminhos têm padrão relocável (derivado da raiz do
# acoplador) e são sobrescrevíveis por variável de ambiente antes do source.
# =============================================================================

# Impede execução direta.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERRO: execute com 'source run/setenv-gnu.bash', não diretamente."
  exit 1
fi

# Colorização inline (este script é sourced, possivelmente antes dos
# instaladores, por isso não depende da install-libs.bash).
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1; then
  _CV_VD=$(tput setaf 2) ; _CV_AM=$(tput setaf 3) ; _CV_VM=$(tput setaf 1)
  _CV_AZ=$(tput setaf 6) ; _CV_BD=$(tput bold)    ; _CV_RS=$(tput sgr0)
else
  _CV_VD="" ; _CV_AM="" ; _CV_VM="" ; _CV_AZ="" ; _CV_BD="" ; _CV_RS=""
fi

# Verificadores de presença (removidos ao final via unset -f).
_OK=0 ; _MISS=0
_chk_file() {
  if [[ -f "$1" ]]; then printf "  ${_CV_VD}OK    ${_CV_RS}%s\n" "$1"; _OK=$(( _OK + 1 ))
  else                   printf "  ${_CV_AM}FALTA ${_CV_RS}%s\n" "$1"; _MISS=$(( _MISS + 1 ))
  fi
}
_chk_dir() {
  if [[ -d "$1" ]]; then printf "  ${_CV_VD}OK    ${_CV_RS}%s\n" "$1"; _OK=$(( _OK + 1 ))
  else                   printf "  ${_CV_AM}FALTA ${_CV_RS}%s\n" "$1"; _MISS=$(( _MISS + 1 ))
  fi
}

# Raiz do MONAN-Coupler (onde ficam install/, run/, lib/, mod/, src/). Por
# padrão é derivada da localização deste script (<raiz>/run/setenv-gnu.bash).
# Ao rodar de um diretório de experimento fora da árvore do projeto, exporte
# COUPLER_ROOT apontando para a raiz — todos os caminhos abaixo o seguem.
_COUPLER_ROOT="${COUPLER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Configuração de sítio (ESMF, módulos, alvos, lista de libs). Fonte única dos
# padrões específicos da máquina; sobrescrevível por ambiente ou via SITE_ENV.
SITE_ENV="${SITE_ENV:-${_COUPLER_ROOT}/install/site-jaci.bash}"
if [[ ! -f "${SITE_ENV}" ]]; then
  echo "ERRO: configuração de sítio não encontrada: ${SITE_ENV}" >&2
  echo "      Edite install/site-jaci.bash ou exporte SITE_ENV." >&2
  return 1
fi
source "${SITE_ENV}"

# [1] ESMF 8.9.1 — ESMFMKFILE vem do site-jaci.bash (ponto único). O esmf.mk é
# incluído pelo Makefile (fornece ESMF_F90COMPILER, *COMPILEPATHS, *LINK*).
# ESMF_LIBDIR é o diretório do esmf.mk.
export ESMF_LIBDIR="$(dirname "${ESMFMKFILE}")"

if [[ -f "${ESMFMKFILE}" ]]; then
  _esmf_ver=$(grep -m1 'ESMF_VERSION_STRING' "${ESMFMKFILE}" \
              | sed 's/.*= *//' | tr -d '[:space:]' 2>/dev/null || echo "?")
else
  _esmf_ver="(esmf.mk não encontrado)"
fi

# [2] MONAN-A 2.0 — o instalador 1 consolida os artefatos em mod/monan2 e
# lib/monan2 (irmãos de MONAN-Model). Sobrescreva MPAS_DIR, MONAN2_MODDIR ou
# MONAN2_LIBDIR antes do source para usar caminhos alternativos.
export MPAS_DIR="${MPAS_DIR:-${_COUPLER_ROOT}/MONAN-Model}"
export MONAN2_MODDIR="${MONAN2_MODDIR:-${_COUPLER_ROOT}/mod/monan2}"
export MONAN2_LIBDIR="${MONAN2_LIBDIR:-${_COUPLER_ROOT}/lib/monan2}"

# [3] GFORTRAN_CONVERT_UNIT — o alvo gfortran-xd2000 compila o MPAS com
# -fconvert=big-endian; sem isto o RRTMG aborta ao ler RRTMG_SW_DATA.DBL.
export GFORTRAN_CONVERT_UNIT='big_endian:101'

# [4] MOM6+SIS2 — MOM6_ROOT é a raiz do acoplador (onde o instalador 2 deposita
# lib/{mom6,fms,nuopc} e mod/{...}). Redefina MOM6_ROOT para uma instalação
# separada; os demais caminhos se ajustam.
export MOM6_ROOT="${MOM6_ROOT:-${_COUPLER_ROOT}}"
export MOM6_LIBDIR="${MOM6_LIBDIR:-${MOM6_ROOT}/lib/mom6}"
export MOM6_MODDIR="${MOM6_MODDIR:-${MOM6_ROOT}/mod/mom6}"
export FMS_LIBDIR="${FMS_LIBDIR:-${MOM6_ROOT}/lib/fms}"
export FMS_MODDIR="${FMS_MODDIR:-${MOM6_ROOT}/mod/fms}"
export NUOPC_LIBDIR="${NUOPC_LIBDIR:-${MOM6_ROOT}/lib/nuopc}"
export NUOPC_MODDIR="${NUOPC_MODDIR:-${MOM6_ROOT}/mod/nuopc}"

# MOAB interno ao libesmf.so nesta instalação. USE_EXTERNAL_MOAB=yes exige
# MOAB_DIR apontando para o MOAB externo (export antes do source).
export USE_EXTERNAL_MOAB="${USE_EXTERNAL_MOAB:-no}"

# pNetCDF — prefixo do módulo Cray, com fallback sobrescrevível via PNETCDF_DIR.
export PNETCDF_DIR="${PNETCDF_DIR:-${CRAY_PARALLEL_NETCDF_PREFIX:-${CRAY_PARALLEL_NETCDF_DIR:-/opt/cray/pe/parallel-netcdf/1.12.3.15/GNU/12.3}}}"

# [5] MOM6_HDR_INC — cabeçalhos exigidos ao recompilar os caps upstream:
# MOM_memory.h (dynamic_symmetric) e version_variable.h (FMS), que ficam na
# árvore de fontes (MOM6_SRC), não em include/mom6.
export MOM6_SRC="${MOM6_SRC:-${MOM6_ROOT}/src}"

if [[ -z "${MOM6_HDR_INC:-}" ]]; then
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

# [6] LD_LIBRARY_PATH — idioma "${NOVO}${VAR:+:${VAR}}" evita o trailing colon
# (que incluiria '.' na busca). Ordem de prioridade: NUOPC→MOM6→FMS→MOAB→ESMF.
# As libs do MONAN-A são estáticas; lib/monan2 entra só por coerência.
export LD_LIBRARY_PATH=\
${MONAN2_LIBDIR}:\
${ESMF_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}

if [[ "${USE_EXTERNAL_MOAB}" == "yes" && -n "${MOAB_DIR:-}" && -d "${MOAB_DIR}/lib" ]]; then
  export LD_LIBRARY_PATH="${MOAB_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
[[ -d "${FMS_LIBDIR}"   ]] && export LD_LIBRARY_PATH="${FMS_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -d "${MOM6_LIBDIR}"  ]] && export LD_LIBRARY_PATH="${MOM6_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -d "${NUOPC_LIBDIR}" ]] && export LD_LIBRARY_PATH="${NUOPC_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# =============================================================================
# Verificação do ambiente
# =============================================================================
echo ""
printf "${_CV_BD}%s${_CV_RS}\n" \
  "======================================================================"
printf "${_CV_BD}  Ambiente: MONAN-A 2.0 × MOM6+SIS2 / ESMF 8.9.1${_CV_RS}\n"
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

echo "  [1/5] ESMF:"
_chk_file "${ESMFMKFILE}"
_chk_file "${ESMF_LIBDIR}/libesmf.so"
echo ""

echo "  [2/5] MONAN-A 2.0 (6 libs em lib/monan2):"
for _lib in "${MONAN2_LIBS[@]}"; do
  _chk_file "${MONAN2_LIBDIR}/${_lib}"
done
unset _lib
_chk_dir "${MONAN2_MODDIR}"
echo ""

echo "  [3/5] Caps de dados sintéticos (DATM/DOCN):"
_chk_file "${_COUPLER_ROOT}/src/caps/ocean/DOCN_cap.F90"
_chk_file "${_COUPLER_ROOT}/src/caps/atmos/DATM_cap.F90"
echo ""

echo "  [4/5] MOM6+SIS2 (diretórios de libs e módulos):"
_chk_dir "${MOM6_LIBDIR}"
_chk_dir "${MOM6_MODDIR}"
_chk_dir "${FMS_LIBDIR}"
_chk_dir "${FMS_MODDIR}"
_chk_dir "${NUOPC_LIBDIR}"
_chk_dir "${NUOPC_MODDIR}"
echo ""

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

unset _OK _MISS _esmf_ver _COUPLER_ROOT
unset _CV_VD _CV_AM _CV_VM _CV_AZ _CV_BD _CV_RS
unset SITE_ENV MONAN2_LIBS MODULES_MONAN MODULES_MOM6 CPU_TARGET MONAN_TARGET
unset -f _chk_file _chk_dir
