#!/usr/bin/env bash
# =============================================================================
# compara-bulk.bash: teste de regressão da física bulk do mediador.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a versão de um commit e a da árvore de trabalho, liga a cada uma o
# seu programa test_bulk_ncar.F90 (o de REV na versão antiga, o da árvore de
# trabalho na nova, para que uma etapa possa mudar o estado interno do
# mediador) e o executa com 4 processos MPI e dados sintéticos. O programa
# chama calc_bulk_ncar (fluxos sobre a água aberta e sobre o gelo, albedo,
# rugosidade) três vezes e grava todos os campos do
# estado interno que ela usa. Os arquivos gravados e as mensagens da física
# bulk no log do ESMF têm de ser idênticos, bit a bit, nas duas versões.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/bulk/compara-bulk.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase4-04-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/bulk)
#
# Variáveis: MPIRUN (padrão: mpiexec), NP (padrão: 4; tem de ser par).
# Ambiente: ESMF, NetCDF-Fortran (nf-config) e MPI; nenhuma biblioteca dos
# modelos (as interfaces mínimas de tests/interfaces bastam).
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,21p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/bulk}" && cd "${2:-${RAIZ}/build-local/bulk}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
NP=${NP:-4}
FC=${FC:-mpif90}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }
[[ $((NP % 2)) -eq 0 ]] || { echo "ERRO: NP tem de ser par" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
# Objetos de que um programa de teste depende, tirados dos 'use' da árvore
# dada (a de trabalho ou a cópia de REV): objetos RAIZ_DA_VERSAO PROGRAMA.F90
objetos() { python3 "${RAIZ}/tools/dev/dependencias.py" objetos -s "$1" -i "${RAIZ}/tests/interfaces" "$2"; }

# Fontes da versão de referência e o seu test_bulk_ncar.F90, extraídos do git
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src Makefile tests/bulk/test_bulk_ncar.F90 | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  # A versão de referência pode não ter todos os fontes da lista atual.
  echo "--- versão ${versao}: compilando"
  # shellcheck disable=SC2086
  bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" > "${SAIDA}/compila_${versao}.txt" \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  ( cd "${dir}" || exit 2
    # shellcheck disable=SC2086
    ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch \
      -O2 -ffp-contract=off -c "${src}/tests/bulk/test_bulk_ncar.F90" -o test_bulk_ncar.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_bulk_ncar test_bulk_ncar.o $(objetos "${src}" "${src}/tests/bulk/test_bulk_ncar.F90") ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  echo "--- versão ${versao}: executando com ${NP} processos"
  rm -rf "${dir}/run"; mkdir -p "${dir}/run"
  ( cd "${dir}/run" && ${MPIRUN} -n "${NP}" ../test_bulk_ncar > run.log 2>&1 ) \
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
[[ ${n} -eq ${NP} ]] || { echo "ERRO: esperados ${NP} arquivos, gravados ${n}; ver ${SAIDA}/antiga/run/run.log" >&2; exit 2; }
# Mensagens da física bulk no log do ESMF, sem data e hora
# Linhas de log retiradas de propósito (tests/log-retirado.txt) ficam fora
# da comparação com REV, que ainda as grava
retirado() { grep -vEf "${RAIZ}/tests/log-retirado.txt"; }
padrao='FIX-DIAG|MED|AVISO'
for pet in "${SAIDA}"/antiga/run/PET*.teste_bulk; do
  nome=$(basename "${pet}")
  if diff -q <(grep -E "${padrao}" "${pet}" | retirado | cut -d' ' -f3-) \
             <(grep -E "${padrao}" "${SAIDA}/nova/run/${nome}" | retirado | cut -d' ' -f3-) > /dev/null; then
    echo "  log igual      ${nome}"
  else
    echo "  log DIFERE     ${nome}"; difere=1
  fi
done
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: física bulk idêntica"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
