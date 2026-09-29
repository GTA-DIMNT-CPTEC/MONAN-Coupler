#!/usr/bin/env bash
# =============================================================================
# roda-unitarios.bash: testes com valor esperado (tests/unit).
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a árvore de trabalho (compila-local.bash), liga a ela cada
# programa tests/unit/test_*.F90 e o executa. Cada programa compara o
# resultado de rotinas do acoplador com valores esperados calculados à
# parte e imprime PASSOU/FALHOU por caso. Ao contrário dos testes de
# regressão (tests/bulk, tests/writers, tests/atmgrid), não compara duas
# versões: confere se o código calcula o que a fórmula diz.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/unit/roda-unitarios.bash [SAIDA]
#     SAIDA   diretório de trabalho (padrão: build-local/unit)
#
# Variáveis: FC (padrão: mpif90).
# Ambiente: ESMF, NetCDF-Fortran (nf-config); nenhuma biblioteca dos
# modelos (as interfaces mínimas de tests/interfaces bastam).
# Código de saída: 0 se todos passaram; 1 se algum falhou; 2 erro de preparo.
# =============================================================================
set -uo pipefail

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${1:-${RAIZ}/build-local/unit}" && cd "${1:-${RAIZ}/build-local/unit}" && pwd)
FC=${FC:-mpif90}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
# Objetos de que os testes dependem: med_bulk_ncar e mpas_cap_methods, com o
# que eles usam (mpas_stubs.o são as interfaces mínimas do MPAS).
OBJS="coupler_utils.o coupler_constants.o coupler_config.o diag_bitsum.o nc_writer.o
      regrid_base.o regrid_esmf.o regrid_weights.o regrid_mpassit.o regrid_registry.o regrid_manager.o
      med_cap_types.o med_bulk_ncar.o
      mpas_stubs.o mpi_allreduce_r8.o mpi_allreduce_i4.o mpi_allreduce_wrappers.o
      mpas_atm_types.o mpas_cap_netcdf.o mpas_import_diag.o mpas_cap_methods.o"

echo "--- compilando a árvore de trabalho"
bash "${RAIZ}/tools/dev/compila-local.bash" -o "${SAIDA}/obj" > "${SAIDA}/compila.txt" \
  || { cat "${SAIDA}/compila.txt"; echo "ERRO: compilação" >&2; exit 2; }

falhas=0
for fonte in "${RAIZ}"/tests/unit/test_*.F90; do
  nome=$(basename "${fonte}" .F90)
  echo "--- ${nome}"
  ( cd "${SAIDA}/obj" || exit 2
    # shellcheck disable=SC2086
    ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch \
      -O2 -ffp-contract=off -c "${fonte}" -o "${nome}.o" &&
    # shellcheck disable=SC2086
    ${FC} -o "${nome}" "${nome}.o" ${OBJS} ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${nome}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${nome}.txt"; echo "ERRO: ligação de ${nome}" >&2; exit 2; }
  if (cd "${SAIDA}" && "${SAIDA}/obj/${nome}"); then
    :
  else
    falhas=$((falhas + 1))
  fi
done

if [[ ${falhas} -eq 0 ]]; then
  echo "RESULTADO: todos os testes com valor esperado passaram"
  exit 0
fi
echo "RESULTADO: ${falhas} programa(s) de teste com falha"
exit 1
