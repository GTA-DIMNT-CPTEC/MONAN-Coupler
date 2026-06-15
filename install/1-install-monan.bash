#!/bin/bash
# =============================================================================
# 1-install-monan.bash — Compila o MONAN-A 2.0 (MPAS-A 8.3.1) e consolida
# módulos (.mod) e bibliotecas (.a) em mod/monan2 e lib/monan2.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# USO:
#   bash install/1-install-monan.bash [--skip-init-atm] [--help]
#     --skip-init-atm   Compila só o core 'atmosphere' (pula 'init_atmosphere').
#
# Layout resultante (irmãos de MONAN-Model):
#   mod/monan2, lib/monan2                  core 'atmosphere'
#   mod/init_atmosphere, lib/init_atmosphere  core 'init_atmosphere' (opcional)
#
# Os artefatos de 'init_atmosphere' ficam SEPARADOS: ambos os cores geram
# libdycore.a e .mod homônimos; misturá-los sobrescreveria o dycore que o
# acoplador linka. Como AUTOCLEAN=true apaga o core anterior ao trocar CORE=,
# a cópia do 'atmosphere' ocorre ANTES de compilar 'init_atmosphere'.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUPLER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/install-libs.bash"

# ── Opções ────────────────────────────────────────────────────────────────────
SKIP_INIT_ATM=false
_uso() { sed -n '2,/^# USO/p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'; exit 0; }

for _arg in "$@"; do
  case "${_arg}" in
    --skip-init-atm)  SKIP_INIT_ATM=true ;;
    --help|-h)        _uso ;;
    *) log_error "Opção desconhecida: ${_arg}   (use --help)"; exit 1 ;;
  esac
done
unset _arg

# ── Caminhos ──────────────────────────────────────────────────────────────────
MONAN_MODEL="${COUPLER_ROOT}/MONAN-Model"
MOD_ATM="${COUPLER_ROOT}/mod/monan2"
LIB_ATM="${COUPLER_ROOT}/lib/monan2"
MOD_INIT="${COUPLER_ROOT}/mod/init_atmosphere"
LIB_INIT="${COUPLER_ROOT}/lib/init_atmosphere"

if [[ ! -d "${MONAN_MODEL}" ]]; then
  log_error "Árvore de fontes não encontrada: ${MONAN_MODEL}"
  exit 1
fi

# ── Módulos Jaci (Cray XD 2000, PrgEnv-gnu) ───────────────────────────────────
log_sep
log_info "Carregando módulos do ambiente Jaci..."
module purge
module load PrgEnv-gnu
module load craype-x86-turin
module load cray-hdf5/1.14.3.3
module load cray-parallel-netcdf
module load xpmem/0.2.119-1.3_gef379be13330
module load grads/2.2.1.oga.1
module load cdo/2.4.2
module load METIS/5.1.0
module load cray-pals
module load cray-python
module load ncview
log_info "Módulos carregados:"
module list 2>&1 | grep -E '^\s+[0-9]+\)' | sed 's/^/    /'

# PNETCDF_DIR é injetado pelo módulo cray-parallel-netcdf
if [[ -z "${PNETCDF_DIR:-}" ]]; then
  log_error "PNETCDF_DIR não definido — módulo 'cray-parallel-netcdf' carregou?"
  exit 1
fi
export PNETCDF="${PNETCDF_DIR}"

cd "${MONAN_MODEL}"

MAKE_ARGS="OPENMP=true USE_PIO2=false PRECISION=double AUTOCLEAN=true"
MAKE_JOBS=8

# ── ETAPA 1 — Core 'atmosphere' (compila e copia ANTES do init_atmosphere) ────
log_step 1 2 "Core 'atmosphere' — compilação"
timer_start
make -j "${MAKE_JOBS}" gfortran-coupler-xd2000 CORE=atmosphere ${MAKE_ARGS} 2>&1 \
  | tee make-atmosphere.log
timer_step "Core 'atmosphere' compilado"

log_step 1 2 "Core 'atmosphere' — cópia dos artefatos"
mkdir -p "${MOD_ATM}" "${LIB_ATM}"

# Módulos (.mod) → mod/monan2
cp_glob "./src/core_atmosphere/*.mod"                                     "${MOD_ATM}"
cp_glob "./src/core_atmosphere/diagnostics/*.mod"                         "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/*.mod"                             "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noahmp/drivers/mpas/*.mod" "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noahmp/utility/*.mod"      "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noahmp/src/*.mod"          "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_mmm/*.mod"                 "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_wrf/*.mod"                 "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_noaa/UGWP/*.mod"           "${MOD_ATM}"
cp_glob "./src/core_atmosphere/physics/physics_monan/*.mod"               "${MOD_ATM}"
cp_glob "./src/core_atmosphere/utils/*.mod"                               "${MOD_ATM}"
cp_glob "./src/core_atmosphere/dynamics/*.mod"                            "${MOD_ATM}"
cp_glob "./src/driver/*.mod"                                              "${MOD_ATM}"
cp_glob "./src/external/esmf_time_f90/*.mod"                              "${MOD_ATM}"
cp_glob "./src/external/SMIOL/*.mod"                                      "${MOD_ATM}"
cp_glob "./src/framework/*.mod"                                           "${MOD_ATM}"
cp_glob "./src/operators/*.mod"                                           "${MOD_ATM}"

# Bibliotecas (.a) → lib/monan2
cp_glob "./src/operators/*.a"               "${LIB_ATM}"
cp_glob "./src/core_atmosphere/*.a"         "${LIB_ATM}"
cp_glob "./src/core_atmosphere/physics/*.a" "${LIB_ATM}"
cp_glob "./src/external/esmf_time_f90/*.a"  "${LIB_ATM}"
cp_glob "./src/external/SMIOL/*.a"          "${LIB_ATM}"
cp_glob "./src/framework/*.a"               "${LIB_ATM}"
log_ok "Artefatos do 'atmosphere' copiados."

# ── ETAPA 2 — Core 'init_atmosphere' (condições iniciais; opcional) ───────────
if [[ "${SKIP_INIT_ATM}" == false ]]; then
  log_step 2 2 "Core 'init_atmosphere' — compilação"
  make -j "${MAKE_JOBS}" gfortran-coupler-xd2000 CORE=init_atmosphere ${MAKE_ARGS} 2>&1 \
    | tee make-init_atmosphere.log
  timer_step "Core 'init_atmosphere' compilado"

  mkdir -p "${MOD_INIT}" "${LIB_INIT}"
  cp_glob "./src/core_init_atmosphere/*.mod" "${MOD_INIT}"
  cp_glob "./src/core_init_atmosphere/*.a"   "${LIB_INIT}"
  log_ok "Artefatos do 'init_atmosphere' copiados."
else
  log_warn "init_atmosphere ignorado (--skip-init-atm)."
fi

# ── Verificação: 6 bibliotecas exigidas pelo Makefile do acoplador ────────────
log_sep
echo ""
log_info "Verificação: 6 bibliotecas do core 'atmosphere' em lib/monan2"
echo ""
_miss=0
for _lib in libframework.a libdycore.a libphys.a libops.a libsmiolf.a libsmiol.a; do
  if [[ -f "${LIB_ATM}/${_lib}" ]]; then log_ok "${_lib}"
  else log_warn "${_lib}  <-- AUSENTE"; _miss=$(( _miss + 1 )); fi
done
echo ""

if [[ ${_miss} -eq 0 ]]; then
  timer_total "Instalação do MONAN-A concluída em"
  echo ""
  log_ok "Módulos  : ${MOD_ATM}"
  log_ok "Libs     : ${LIB_ATM}"
  echo ""
  log_info "Próximo passo: bash install/2-install-mom.bash"
else
  log_error "${_miss} biblioteca(s) ausente(s) — verifique make-atmosphere.log"
  exit 1
fi
