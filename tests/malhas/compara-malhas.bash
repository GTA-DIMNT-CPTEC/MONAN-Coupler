#!/usr/bin/env bash
# =============================================================================
# compara-malhas.bash: teste de regressão da construção das malhas regulares
# do lado atmosférico (malha de fluxo do mediador e grade do cap do MONAN-A).
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a versão de um commit e a da árvore de trabalho, liga a cada uma o
# programa tests/malhas/test_malhas.F90 da árvore de trabalho (ele só usa
# create_atm_grid e mpas_create_grid, cujas interfaces não mudam) e o
# executa com 1, 4, 6 e 8 processos MPI. Para cada PET e cada DE local, os
# limites computacionais e os vetores de coordenadas dos centros e dos
# cantos gravados (saida_<PET>.bin) têm de ser idênticos, bit a bit, e as
# mensagens das duas rotinas no log do ESMF também, sem data e hora.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/malhas/compara-malhas.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase11-07-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/malhas)
#
# Variáveis: MPIRUN (padrão: mpiexec), FC (padrão: mpif90), LISTA_NP
# (padrão: "1 4 6 8").
# Ambiente: ESMF, NetCDF-Fortran (nf-config) e MPI; nenhuma biblioteca dos
# modelos (as interfaces mínimas de tests/interfaces bastam).
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,24p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/malhas}" && cd "${2:-${RAIZ}/build-local/malhas}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
FC=${FC:-mpif90}
LISTA_NP=${LISTA_NP:-1 4 6 8}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
OBJS="coupler_utils.o coupler_constants.o coupler_config.o diag_bitsum.o mom6_supergrid.o
      nc_writer.o cap_common.o regrid_base.o regrid_esmf.o regrid_weights.o regrid_mpassit.o
      regrid_registry.o regrid_manager.o cpl_grids.o cpl_fields.o cpl_map.o mpas_stubs.o
      mpi_allreduce_r8.o mpi_allreduce_i4.o mpi_allreduce_wrappers.o
      mpas_atm_types.o mpas_cap_netcdf.o mpas_import_diag.o mpas_cell_binning.o mpas_cap_methods.o
      med_cap_types.o med_cap_netcdf.o med_cap_methods.o med_bulk_ncar.o med_diag.o
      med_ice.o med_ocean.o med_init.o"
# A versão de referência pode não ter algum objeto da lista (fonte criado
# depois dela): liga só os que existem no diretório de compilação.
objs_presentes() { local o; for o in ${OBJS}; do [[ -f ${o} ]] && printf '%s ' "${o}"; done; }

# Fontes da versão de referência, extraídos do git
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src tests/interfaces tools/dev/compila-local.bash \
  | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  ausente=""; [[ ${versao} == antiga ]] && ausente="-a"
  echo "--- versão ${versao}: compilando"
  # shellcheck disable=SC2086
  bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" ${ausente} > "${SAIDA}/compila_${versao}.txt" \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  ( cd "${dir}" || exit 2
    # shellcheck disable=SC2086
    ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch \
      -O2 -ffp-contract=off -c "${RAIZ}/tests/malhas/test_malhas.F90" -o test_malhas.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_malhas test_malhas.o $(objs_presentes) ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  for np in ${LISTA_NP}; do
    run="${dir}/run_${np}"
    rm -rf "${run}"; mkdir -p "${run}"
    # shellcheck disable=SC2086
    ( cd "${run}" && ${MPIRUN} -n "${np}" ../test_malhas > run.log 2>&1 ) \
      || { tail -20 "${run}/run.log"; echo "ERRO: execução da versão ${versao} com ${np} processos" >&2; exit 2; }
  done
done

difere=0
padrao='MED|mpas_create_grid|cpl_malha|ERROR|WARNING'
for np in ${LISTA_NP}; do
  n=0
  for f in $(cd "${SAIDA}/antiga/run_${np}" && ls saida_*.bin 2>/dev/null); do
    n=$((n + 1))
    if ! cmp -s "${SAIDA}/antiga/run_${np}/${f}" "${SAIDA}/nova/run_${np}/${f}"; then
      echo "  DIFERE         ${np} PETs: ${f}"; difere=1
    fi
  done
  [[ ${n} -eq ${np} ]] || { echo "ERRO: ${np} PETs: esperados ${np} arquivos, gravados ${n}" >&2; exit 2; }
  echo "  ${np} PET(s): ${n} arquivo(s) comparados"
  for pet in "${SAIDA}/antiga/run_${np}"/PET*.teste_malhas; do
    nome=$(basename "${pet}")
    if ! diff -q <(grep -E "${padrao}" "${pet}" | cut -d' ' -f3-) \
                 <(grep -E "${padrao}" "${SAIDA}/nova/run_${np}/${nome}" | cut -d' ' -f3-) > /dev/null; then
      echo "  log DIFERE     ${np} PETs: ${nome}"; difere=1
    fi
  done
done
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: malhas idênticas"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
