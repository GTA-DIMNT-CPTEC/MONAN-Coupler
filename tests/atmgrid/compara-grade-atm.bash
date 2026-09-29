#!/usr/bin/env bash
# =============================================================================
# compara-grade-atm.bash: teste de regressão da passagem das células MPAS
# para a grade regular 360x180 do cap atmosférico.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a versão de um commit e a da árvore de trabalho, liga a cada uma o
# seu programa test_mpas_export.F90 (o de REV na versão antiga, o da árvore
# de trabalho na nova, para que uma etapa possa mudar a interface do cap) e
# o executa com processos MPI e células
# sintéticas. O programa chama mpas_export duas vezes, o que exercita
# state_set_field_1d e map_cells_to_regular_grid (soma e contagem por caixa,
# soma reprodutível entre PETs, média, preenchimento de caixas vazias e cópia
# para a grade local), e grava os campos reunidos no PET 0. Os arquivos
# gravados, as mensagens de diagnóstico do log do ESMF e a linha MPAS-DIAG
# da saída padrão têm de ser idênticos, bit a bit, nas duas versões.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/atmgrid/compara-grade-atm.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase5-04-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/grade-atm)
#
# Variáveis: MPIRUN (padrão: mpiexec), NP (padrão: 4).
# Ambiente: ESMF, NetCDF-Fortran (nf-config) e MPI; nenhuma biblioteca dos
# modelos (as interfaces mínimas de tests/interfaces bastam).
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,24p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/grade-atm}" && cd "${2:-${RAIZ}/build-local/grade-atm}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
NP=${NP:-4}
FC=${FC:-mpif90}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
OBJS="coupler_utils.o coupler_constants.o coupler_config.o nc_writer.o mpas_stubs.o
      mpi_allreduce_r8.o mpi_allreduce_i4.o mpi_allreduce_wrappers.o
      mpas_atm_types.o mpas_cap_netcdf.o mpas_import_diag.o mpas_cap_methods.o"
# A versão de referência pode não ter algum objeto da lista (fonte criado
# depois dela): liga só os que existem no diretório de compilação.
objs_presentes() { local o; for o in ${OBJS}; do [[ -f ${o} ]] && printf '%s ' "${o}"; done; }

# Fontes da versão de referência, extraídos do git
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src tests/interfaces tests/atmgrid/test_mpas_export.F90 \
  tools/dev/compila-local.bash \
  | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  # A versão de referência pode não ter todos os fontes da lista atual.
  ausente=""; [[ ${versao} == antiga ]] && ausente="-a"
  echo "--- versão ${versao}: compilando"
  # shellcheck disable=SC2086
  bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" ${ausente} > "${SAIDA}/compila_${versao}.txt" \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  ( cd "${dir}" || exit 2
    # shellcheck disable=SC2086
    ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch \
      -O2 -ffp-contract=off -c "${src}/tests/atmgrid/test_mpas_export.F90" -o test_mpas_export.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_mpas_export test_mpas_export.o $(objs_presentes) ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  echo "--- versão ${versao}: executando com ${NP} processos"
  rm -rf "${dir}/run"; mkdir -p "${dir}/run"
  ( cd "${dir}/run" && ${MPIRUN} -n "${NP}" ../test_mpas_export > run.log 2>&1 ) \
    || { tail -20 "${dir}/run/run.log"; echo "ERRO: execução da versão ${versao}" >&2; exit 2; }
done

difere=0
n=0
for f in $(cd "${SAIDA}/antiga/run" && ls saida_*.bin 2>/dev/null); do
  n=$((n + 1))
  if cmp -s "${SAIDA}/antiga/run/${f}" "${SAIDA}/nova/run/${f}"; then
    echo "  igual (bytes)  ${f}"
  else
    echo "  DIFERE         ${f}"; difere=1
  fi
done
[[ ${n} -eq 6 ]] || { echo "ERRO: esperados 6 arquivos, gravados ${n}; ver ${SAIDA}/antiga/run/run.log" >&2; exit 2; }
if diff -q <(grep 'MPAS-DIAG' "${SAIDA}/antiga/run/run.log") \
           <(grep 'MPAS-DIAG' "${SAIDA}/nova/run/run.log") > /dev/null; then
  echo "  saída igual    MPAS-DIAG ($(grep -c 'MPAS-DIAG' "${SAIDA}/antiga/run/run.log") linhas)"
else
  echo "  saída DIFERE   MPAS-DIAG"; difere=1
fi
# Mensagens de diagnóstico e de erro no log do ESMF, sem data e hora
padrao='BUG-SPARSE|ERROR|WARNING|state_set_field_1d|mpas_export'
for pet in "${SAIDA}"/antiga/run/PET*.teste_grade_atm; do
  nome=$(basename "${pet}")
  if diff -q <(grep -E "${padrao}" "${pet}" | cut -d' ' -f3-) \
             <(grep -E "${padrao}" "${SAIDA}/nova/run/${nome}" | cut -d' ' -f3-) > /dev/null; then
    echo "  log igual      ${nome} ($(grep -cE "${padrao}" "${pet}") linhas)"
  else
    echo "  log DIFERE     ${nome}"; difere=1
  fi
done
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: grade do cap atmosférico idêntica"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
