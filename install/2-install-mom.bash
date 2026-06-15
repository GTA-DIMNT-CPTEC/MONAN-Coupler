#!/bin/bash
# =============================================================================
# 2-install-mom.bash — Compila MOM6+SIS2 (+FMS) com mkmf no Cray/GNU e gera o
# cap NUOPC (libmom6_nuopc.a) usado pelo acoplador.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# USO:
#   bash install/2-install-mom.bash [--only-nuopc] [--help]
#     --only-nuopc   Pula FMS e MOM6 standalone; compila apenas o cap NUOPC.
#
# Pré-requisito: árvore MOM6-examples clonada com submódulos:
#   cd <raiz_acoplador>
#   git clone --recursive https://github.com/NOAA-GFDL/MOM6-examples.git
#
# Artefatos (sob MOM6-examples/build/gnu/) → copiados para lib/{fms,mom6,nuopc}
# e mod/{fms,mom6,nuopc}:
#   shared/repro/libfms.a              infraestrutura FMS
#   ice_ocean_SIS2/repro/MOM6          executável standalone (validação)
#   nuopc_cap/repro/libmom6_nuopc.a    cap NUOPC
#
# Os .o de ice_ocean_SIS2 vão para lib/mom6/ e são linkados diretamente pelo
# Makefile (MOM6_OBJS), evitando símbolos duplicados com libmom6_nuopc.a.
# O compilador é sempre o wrapper Cray 'ftn' (nunca gfortran direto).
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUPLER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/install-libs.bash"

# ── Opções ────────────────────────────────────────────────────────────────────
ONLY_NUOPC=false
_uso() { sed -n '2,/^# USO/p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'; exit 0; }

for _arg in "$@"; do
  case "${_arg}" in
    --only-nuopc) ONLY_NUOPC=true ;;
    --help|-h)    _uso ;;
    *) log_error "Opção desconhecida: ${_arg}   (use --help)"; exit 1 ;;
  esac
done
unset _arg

# ── Pré-condição ──────────────────────────────────────────────────────────────
MOM6_EXAMPLES_DIR="${COUPLER_ROOT}/MOM6-examples"
if [[ ! -d "${MOM6_EXAMPLES_DIR}" ]]; then
  log_error "Árvore MOM6-examples não encontrada: ${MOM6_EXAMPLES_DIR}"
  log_info  "Clone com: cd ${COUPLER_ROOT} && git clone --recursive https://github.com/NOAA-GFDL/MOM6-examples.git"
  exit 1
fi

# =============================================================================
# Configuração — revise ao migrar de usuário ou máquina
# =============================================================================
# Módulos Cray XD 2000 (PrgEnv-gnu). cray-netcdf (serial), não o parallel
# (que é do MPAS); o 'ftn' injeta includes/libs do NetCDF automaticamente.
module purge
module load cray-pe-x86-turin
module load PrgEnv-gnu/8.6.0
module load cray-mpich/8.1.31
module load autoconf/2.72
module load libfabric/1.22.0
module load cray-pals/1.6.1
module load cray-hdf5/1.14.3.3
module load cray-netcdf
log_info "Módulos carregados:"
module list 2>&1 | grep -E '^\s+[0-9]+\)' | sed 's/^/    /'

# ESMF 8.9.1 — ponto único via esmf.mk; sobrescreva com ESMFMKFILE no ambiente.
ESMFMKFILE="${ESMFMKFILE:-/p/projetos/monan_adm/daniel.massaru/Acopladores/esmf-8.9.1/lib/libO/Linux.gfortran.64.mpich2.default/esmf.mk}"
if [[ ! -f "${ESMFMKFILE}" ]]; then
  log_error "esmf.mk não encontrado: ${ESMFMKFILE}"
  exit 1
fi

# Extrai uma variável já expandida do esmf.mk. Uso: _esmf_mk ESMF_LIBDIR
_esmf_mk() {
  printf 'include %s\n_v:\n\t@echo $(%s)\n' "${ESMFMKFILE}" "$1" | make -s -f - _v 2>/dev/null
}

export PATH="$(_esmf_mk ESMF_APPSDIR):${PATH}"
export LD_LIBRARY_PATH="$(_esmf_mk ESMF_LIBDIR):${LD_LIBRARY_PATH:-}"
log_ok "ESMF via ${ESMFMKFILE}"

# Wrappers Cray — nunca usar gfortran/gcc direto.
export FC=ftn
export CC=cc
export LD=ftn

# true: MOM6 com gelo marinho SIS2. false: oceano sem gelo (ocean_only).
BUILD_SIS2=true
# =============================================================================

MKMF="${MOM6_EXAMPLES_DIR}/src/mkmf/bin/mkmf"
LIST_PATHS="${MOM6_EXAMPLES_DIR}/src/mkmf/bin/list_paths"

# Template mkmf do projeto (Cray/GNU, sem NetCDF custom). Sobrescreva a origem
# com MKMF_TEMPLATE_SRC se necessário.
TEMPLATE_MK="${MKMF_TEMPLATE_SRC:-${SCRIPT_DIR}/templates/cray-gnu-monan.mk}"

for _tool in "${TEMPLATE_MK}" "${MKMF}" "${LIST_PATHS}"; do
  if [[ ! -e "${_tool}" ]]; then
    log_error "Arquivo de build não encontrado: ${_tool}"
    exit 1
  fi
done
unset _tool

# Guarda: com cray-netcdf carregado, o template não pode reintroduzir o NetCDF
# custom (duplicaria headers e arriscaria divergência de versão).
if grep -q 'lib_gnucray/netcdf' "${TEMPLATE_MK}"; then
  log_error "Template contém NetCDF custom (lib_gnucray/netcdf): ${TEMPLATE_MK}"
  exit 1
fi
log_ok "Template mkmf: ${TEMPLATE_MK}"

MAKE_JOBS=8
timer_start

# ── PASSO 1/3 — FMS (infraestrutura base; precede tudo) ───────────────────────
# Usar src/FMS2 (FMS 2022.02, com fms2_io), NÃO src/FMS (FMS1, só mpp_io):
# o MOM6 deste repo usa config_src/infra/FMS2 nos passos 2 e 3.
if [[ "${ONLY_NUOPC}" == false ]]; then
  log_step 1 3 "FMS — infraestrutura base"
  rm -rf "${MOM6_EXAMPLES_DIR}/build"
  mkdir -p "${MOM6_EXAMPLES_DIR}/build/gnu/shared/repro"
  cd "${MOM6_EXAMPLES_DIR}/build/gnu/shared/repro"

  rm -f path_names
  ${LIST_PATHS} -l ../../../../src/FMS2
  ${MKMF} \
      -t "${TEMPLATE_MK}" \
      -p libfms.a \
      -c "-Duse_libMPI -Duse_netCDF -DSPMD" \
      path_names

  # NETCDF=4: fms2_io exige a API NetCDF-4/HDF5 (fornecida por cray-netcdf).
  make NETCDF=4 REPRO=1 libfms.a -j "${MAKE_JOBS}" 2>&1 | tee make_fms.log
  timer_step "[1/3] FMS compilado"
else
  log_warn "Passo 1/3 (FMS) ignorado (--only-nuopc)."
fi

cd "${MOM6_EXAMPLES_DIR}"

# ── PASSO 2/3 — MOM6 standalone (validação antes do cap NUOPC) ────────────────
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

# ── PASSO 3/3 — Cap NUOPC (libmom6_nuopc.a) — etapa principal ─────────────────
log_step 3 3 "Cap NUOPC (libmom6_nuopc.a)"

ESMF_COMPILEPATHS="$(_esmf_mk ESMF_F90COMPILEPATHS)"
ESMF_LINKLINE="$(_esmf_mk ESMF_F90LINKPATHS) $(_esmf_mk ESMF_F90LINKRPATHS) $(_esmf_mk ESMF_F90ESMFLINKLIBS)"
if [[ -z "${ESMF_COMPILEPATHS}" || -z "${ESMF_LINKLINE// /}" ]]; then
  log_error "Falha ao extrair flags do esmf.mk: ${ESMFMKFILE}"
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
    -o "-I../../shared/repro ${ESMF_COMPILEPATHS} -I${MOM6_EXAMPLES_DIR}/src/MOM6/src/framework" \
    -p libmom6_nuopc.a \
    -l "-L../../shared/repro -lfms ${ESMF_LINKLINE}" \
    -c "-Duse_libMPI -Duse_netCDF -DSPMD -DUSE_ESMF_NUOPC -fcheck=all" \
    path_names

make REPRO=1 libmom6_nuopc.a -j "${MAKE_JOBS}" 2>&1 | tee make_mom6_nuopc.log
timer_step "[3/3] Cap NUOPC compilado"

cd "${MOM6_EXAMPLES_DIR}"

# ── Verificação dos artefatos ─────────────────────────────────────────────────
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
  if [[ -s "${MOM6_EXAMPLES_DIR}/${_f}" ]]; then log_ok "${_f}"
  else log_warn "${_f}  <-- AUSENTE ou VAZIO"; _miss=$(( _miss + 1 )); fi
done
unset _artefatos

if [[ ${_miss} -ne 0 ]]; then
  log_error "${_miss} artefato(s) ausente(s) — verifique make_*.log"
  exit 1
fi

# ── Instalação na árvore do acoplador ─────────────────────────────────────────
log_info "Instalando em ${COUPLER_ROOT}/{lib,mod}/{fms,mom6,nuopc}/..."
echo ""
mkdir -p "${COUPLER_ROOT}"/lib/{fms,mom6,nuopc}
mkdir -p "${COUPLER_ROOT}"/mod/{fms,mom6,nuopc}

cp_glob "build/gnu/nuopc_cap/repro/*.a"   "${COUPLER_ROOT}/lib/nuopc/"
cp_glob "build/gnu/nuopc_cap/repro/*.mod" "${COUPLER_ROOT}/mod/nuopc/"

# .o do MOM6 standalone: linkados diretamente pelo Makefile (MOM6_OBJS).
cp_glob "build/gnu/${_mom6_target}/repro/*.o"   "${COUPLER_ROOT}/lib/mom6/"
cp_glob "build/gnu/${_mom6_target}/repro/*.mod" "${COUPLER_ROOT}/mod/mom6/"

cp "build/gnu/shared/repro/libfms.a"   "${COUPLER_ROOT}/lib/fms/"
cp_glob "build/gnu/shared/repro/*.mod" "${COUPLER_ROOT}/mod/fms/"

# ── Resumo ────────────────────────────────────────────────────────────────────
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
