#!/bin/bash
# =============================================================================
# 2-install-mom.bash — Compila MOM6+SIS2 (+FMS) com mkmf no Cray/GNU e gera a
# biblioteca do cap NUOPC (libmom6_nuopc.a) usada pelo acoplador.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# USO:
#   bash install/2-install-mom.bash [--only-nuopc] [--help]
#     --only-nuopc   Compila apenas o cap NUOPC (FMS e MOM6 já compilados).
#
# PRÉ-REQUISITO: árvore MOM6-examples clonada com submódulos:
#   git clone --recursive https://github.com/NOAA-GFDL/MOM6-examples.git
#
# Artefatos (sob MOM6-examples/build/gnu/): shared/repro/libfms.a,
# ice_ocean_SIS2/repro/MOM6 e nuopc_cap/repro/libmom6_nuopc.a, copiados para
# <raiz>/{lib,mod}/{fms,mom6,nuopc}/. Os .o do MOM6 standalone são linkados
# diretamente pelo Makefile do acoplador (MOM6_OBJS). Compilador: wrapper 'ftn'.
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUPLER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/install-libs.bash"

# ── Opções ───────────────────────────────────────────────────────────────────
ONLY_NUOPC=false

_uso() {
  sed -n '2,/^# USO/p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'
  exit 0
}

for _arg in "$@"; do
  case "${_arg}" in
    --only-nuopc)   ONLY_NUOPC=true  ;;
    --help|-h)      _uso ;;
    *)
      log_error "Opção desconhecida: ${_arg}   (use --help para a lista de opções)"
      exit 1
      ;;
  esac
done
unset _arg

MOM6_EXAMPLES_DIR="${COUPLER_ROOT}/MOM6-examples"

if [[ ! -d "${MOM6_EXAMPLES_DIR}" ]]; then
  log_error "Árvore MOM6-examples não encontrada: ${MOM6_EXAMPLES_DIR}"
  log_info  "Clone com:"
  log_info  "  cd ${COUPLER_ROOT}"
  log_info  "  git clone --recursive https://github.com/NOAA-GFDL/MOM6-examples.git"
  exit 1
fi

# ── Configuração — revise ao migrar de usuário/máquina ───────────────────────
module purge
module load PrgEnv-gnu/8.6.0
module load cray-mpich/8.1.31
module load autoconf/2.72
module load libfabric/1.22.0
module load cray-pals/1.6.1
# NetCDF/HDF5 seriais: use cray-netcdf (não cray-parallel-netcdf, do MPAS).
# O 'ftn' injeta includes e libs automaticamente quando carregados.
module load cray-hdf5/1.14.3.3
module load cray-netcdf
log_info "Módulos carregados:"
module list 2>&1 | grep -E '^\s+[0-9]+\)' | sed 's/^/    /'

# ESMF 8.9.1 (Massaru). ESMF_ROOT/ESMFMKFILE são respeitados se já exportados
# (p.ex. via run/setenv-gnu.bash); senão, usam os defaults abaixo. Include/mod
# e libs de link são extraídos do esmf.mk no Passo 3.
ESMF_ROOT="${ESMF_ROOT:-/p/projetos/monan_adm/daniel.massaru/Acopladores/esmf-8.9.1}"
ESMFMKFILE="${ESMFMKFILE:-${ESMF_ROOT}/lib/libO/Linux.gfortran.64.mpich2.default/esmf.mk}"

if [[ ! -f "${ESMFMKFILE}" ]]; then
  log_error "esmf.mk não encontrado: ${ESMFMKFILE}"
  log_info  "Defina ESMF_ROOT/ESMFMKFILE ou 'source run/setenv-gnu.bash' antes."
  exit 1
fi

# Wrappers Cray — nunca gfortran/gcc direto
export FC=ftn
export CC=cc
export LD=ftn

# SIS2: true = oceano+gelo (ice_ocean_SIS2); false = só oceano (ocean_only)
BUILD_SIS2=true

# ── Ferramentas e template mkmf ──────────────────────────────────────────────
MKMF="${MOM6_EXAMPLES_DIR}/src/mkmf/bin/mkmf"
LIST_PATHS="${MOM6_EXAMPLES_DIR}/src/mkmf/bin/list_paths"

# Template Cray/GNU ('ftn'), versionado em install/templates/ (sobrevive a um
# clone novo do MOM6-examples). NetCDF/HDF5 vêm dos módulos cray-*; o ESMF entra
# via esmf.mk no Passo 3. Use MKMF_TEMPLATE_SRC para apontar outro template.
TEMPLATE_MK="${MKMF_TEMPLATE_SRC:-${SCRIPT_DIR}/templates/cray-gnu-monan.mk}"

for _tool in "${TEMPLATE_MK}" "${MKMF}" "${LIST_PATHS}"; do
  if [[ ! -e "${_tool}" ]]; then
    log_error "Arquivo de build não encontrado: ${_tool}"
    exit 1
  fi
done
unset _tool

# Aborta se o template reintroduzir algum caminho pessoal/hardcoded
if grep -qE 'lib_gnucray|paulo\.kubota|/home/[^/]+/' "${TEMPLATE_MK}"; then
  log_error "Template contém caminho pessoal/hardcoded: ${TEMPLATE_MK}"
  grep -nE 'lib_gnucray|paulo\.kubota|/home/[^/]+/' "${TEMPLATE_MK}" | sed 's/^/    /' >&2
  log_info  "Use um template sem caminhos de home (ver install/templates/)."
  exit 1
fi
log_ok "Template mkmf auditado (sem caminhos pessoais): ${TEMPLATE_MK}"

MAKE_JOBS=8
timer_start

# ── Passo 1/3 — FMS (infraestrutura base) ────────────────────────────────────
if [[ "${ONLY_NUOPC}" == false ]]; then
  log_step 1 3 "FMS — infraestrutura base"

  rm -rf "${MOM6_EXAMPLES_DIR}/build"
  mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/shared/repro"
  cd "${MOM6_EXAMPLES_DIR}/build/gnu/shared/repro"

  rm -f path_names
  ${LIST_PATHS} -l ../../../../src/FMS
  ${MKMF} \
      -t "${TEMPLATE_MK}" \
      -p libfms.a \
      -c "-Duse_libMPI -Duse_netCDF -DSPMD" \
      path_names

  make NETCDF=3 REPRO=1 libfms.a -j "${MAKE_JOBS}" 2>&1 | tee make_fms.log

  timer_step "[1/3] FMS compilado"
else
  log_warn "Passo 1/3 (FMS) ignorado (--only-nuopc)."
fi

cd "${MOM6_EXAMPLES_DIR}"

# ── Passo 2/3 — MOM6 standalone (valida a compilação antes do cap) ───────────
if [[ "${ONLY_NUOPC}" == false ]]; then
  if [[ "${BUILD_SIS2}" == true ]]; then
    _mom6_target="ice_ocean_SIS2"
    log_step 2 3 "MOM6 + SIS2 standalone (ice_ocean_SIS2)"

    mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/ice_ocean_SIS2/repro"
    cd "${MOM6_EXAMPLES_DIR}/build/gnu/ice_ocean_SIS2/repro"

    rm -f path_names
    ${LIST_PATHS} -l              \
         ./ \
        ../../../../src/MOM6/config_src/{infra/FMS2,memory/dynamic_symmetric,drivers/FMS_cap,external} \
        ../../../../src/SIS2/config_src/dynamic_symmetric             \
        ../../../../src/MOM6/src/{*,*/*}/                             \
        ../../../../src/atmos_null                                    \
        ../../../../src/land_null                                     \
        ../../../../src/coupler                                       \
        ../../../../src/{ice_param,icebergs/src,SIS2,FMS/coupler,FMS/include}
    ${MKMF} \
        -t "${TEMPLATE_MK}" \
        -o "-I../../shared/repro  -I../../ice_ocean_SIS2/repro" \
        -p MOM6 \
        -l "-L../../shared/repro -lfms" \
        -c "-Duse_libMPI -Duse_netCDF -DSPMD -Duse_AM3_physics -D_USE_LEGACY_LAND_" \
        path_names

    make REPRO=1 MOM6 -j "${MAKE_JOBS}" 2>&1 | tee make_mom6_ice_ocean_SIS2.log
  else
    _mom6_target="ocean_only"
    log_step 2 3 "MOM6 standalone (ocean_only — sem gelo)"

    mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/ocean_only/repro"
    cd "${MOM6_EXAMPLES_DIR}/build/gnu/ocean_only/repro"

    rm -f path_names
    ${LIST_PATHS} -l \
        ../../../../src/MOM6/config_src/infra/FMS2 \
        ../../../../src/MOM6/config_src/memory/dynamic_symmetric \
        ../../../../src/MOM6/config_src/drivers/solo_driver \
        ../../../../src/MOM6/config_src/external \
        ../../../../src/MOM6/src/{*,*/*}
    ${MKMF} \
        -t "${TEMPLATE_MK}" \
        -o "-I../../shared/repro" \
        -p MOM6 \
        -l "-L../../shared/repro -lfms" \
        -c "-Duse_libMPI -Duse_netCDF -DSPMD" \
        path_names

    make REPRO=1 MOM6 -j "${MAKE_JOBS}" 2>&1 | tee make_mom6_ocean_only.log
  fi

  timer_step "[2/3] MOM6 standalone compilado (${_mom6_target})"
else
  log_warn "Passo 2/3 (MOM6 standalone) ignorado (--only-nuopc)."
  _mom6_target="ice_ocean_SIS2"   # assume para a verificação abaixo
fi

cd "${MOM6_EXAMPLES_DIR}"

# ── Passo 3/3 — Cap NUOPC (libmom6_nuopc.a) — etapa principal ────────────────
log_step 3 3 "Cap NUOPC (libmom6_nuopc.a)"

# Include/flags do ESMF a partir do esmf.mk. O produto é uma lib estática
# (sem link aqui); ESMF_FLAGS serve ao link final do acoplador.
_esmf_mk() { grep -E "^${1}[[:space:]]*=" "${ESMFMKFILE}" | head -1 | sed 's/^[^=]*=[[:space:]]*//'; }

ESMF_INC="$(_esmf_mk ESMF_F90COMPILEPATHS)"
ESMF_FLAGS="$(_esmf_mk ESMF_F90LINKPATHS) $(_esmf_mk ESMF_F90LINKRPATHS) $(_esmf_mk ESMF_F90ESMFLIBS) $(_esmf_mk ESMF_F90LINKLIBS)"

if [[ -z "${ESMF_INC}" ]]; then
  log_error "Falha ao extrair ESMF_F90COMPILEPATHS de ${ESMFMKFILE}"
  log_info  "Confira o conteúdo de ${ESMFMKFILE}."
  exit 1
fi

mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/nuopc_cap/repro"
cd "${MOM6_EXAMPLES_DIR}/build/gnu/nuopc_cap/repro"

rm -f path_names
${LIST_PATHS} -l \
    ../../../../src/MOM6/config_src/infra/FMS2 \
    ../../../../src/MOM6/config_src/memory/dynamic_symmetric \
    ../../../../src/MOM6/config_src/external \
    ../../../../../../../caps/atmos/mpas_cap_config.F90 \
    ../../../../../../../caps/ocean/*.F90               \
    ../../../../src/MOM6/src/{*,*/*}
${MKMF} \
    -t "${TEMPLATE_MK}" \
    -o "-I../../shared/repro ${ESMF_INC} -I${MOM6_EXAMPLES_DIR}/src/MOM6/src/framework" \
    -p libmom6_nuopc.a \
    -l "-L../../shared/repro -lfms ${ESMF_FLAGS}" \
    -c "-Duse_libMPI -Duse_netCDF -DSPMD -DUSE_ESMF_NUOPC -fcheck=all" \
    path_names

make REPRO=1 libmom6_nuopc.a -j "${MAKE_JOBS}" 2>&1 | tee make_mom6_nuopc.log

timer_step "[3/3] Cap NUOPC compilado"

cd "${MOM6_EXAMPLES_DIR}"

# ── Verificação dos artefatos ────────────────────────────────────────────────
log_sep
log_info "Verificando artefatos gerados..."
echo ""

_miss=0
_artefatos=(
  "build/gnu/shared/repro/libfms.a"
  "build/gnu/${_mom6_target}/repro/MOM6"
  "build/gnu/nuopc_cap/repro/libmom6_nuopc.a"
)

for _f in "${_artefatos[@]}"; do
  if [[ -s "${MOM6_EXAMPLES_DIR}/${_f}" ]]; then
    log_ok "${_f}"
  else
    log_warn "${_f}  <-- AUSENTE ou VAZIO"
    _miss=$(( _miss + 1 ))
  fi
done
unset _artefatos

if [[ ${_miss} -ne 0 ]]; then
  log_error "${_miss} artefato(s) ausente(s) — verifique make_*.log"
  exit 1
fi

# ── Instalação em <raiz>/{lib,mod}/{fms,mom6,nuopc}/ ─────────────────────────
log_info "Instalando artefatos em ${COUPLER_ROOT}/{lib,mod}/{fms,mom6,nuopc}/..."
echo ""

mkdir -p "${COUPLER_ROOT}"/lib/{fms,mom6,nuopc}
mkdir -p "${COUPLER_ROOT}"/mod/{fms,mom6,nuopc}

cp_glob "build/gnu/nuopc_cap/repro/*.a"     "${COUPLER_ROOT}/lib/nuopc/"
cp_glob "build/gnu/nuopc_cap/repro/*.mod"   "${COUPLER_ROOT}/mod/nuopc/"

cp_glob "build/gnu/${_mom6_target}/repro/*.o"   "${COUPLER_ROOT}/lib/mom6/"
cp_glob "build/gnu/${_mom6_target}/repro/*.mod" "${COUPLER_ROOT}/mod/mom6/"

cp "build/gnu/shared/repro/libfms.a"      "${COUPLER_ROOT}/lib/fms/"
cp_glob "build/gnu/shared/repro/*.mod"    "${COUPLER_ROOT}/mod/fms/"

# ── Resumo final ─────────────────────────────────────────────────────────────
log_sep
echo ""
timer_total "Build MOM6 completo em"
echo ""
log_ok "FMS    : build/gnu/shared/repro/libfms.a"
log_ok "MOM6   : build/gnu/${_mom6_target}/repro/MOM6"
log_ok "NUOPC  : build/gnu/nuopc_cap/repro/libmom6_nuopc.a"
echo ""
log_ok "Instalados em ${COUPLER_ROOT}/{lib,mod}/{fms,mom6,nuopc}/"
echo ""
log_info "Próximo passo: bash install/3-install-coupler.bash"
log_sep
