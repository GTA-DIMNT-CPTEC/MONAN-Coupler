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
# gravados, as mensagens de diagnóstico do log do ESMF e a linha de
# cobertura das células ("DIAG cell_binning coverage" no log do ESMF; até a
# R-FASE13-10, "[MPAS-DIAG]" na saída padrão) têm de ser idênticos, bit a
# bit, nas duas versões. As mensagens da versão anterior passam antes pelas
# traduções de texto de tests/log-traduzido.sed, e a severidade não entra
# na comparação.
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
# Objetos de que um programa de teste depende, tirados dos 'use' da árvore
# dada (a de trabalho ou a cópia de REV): objetos RAIZ_DA_VERSAO PROGRAMA.F90
objetos() { python3 "${RAIZ}/tools/dev/dependencias.py" objetos -s "$1" -i "${RAIZ}/tests/interfaces" "$2"; }

# Fontes da versão de referência, extraídos do git
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src Makefile tests/interfaces tests/atmgrid/test_mpas_export.F90 \
  tools/dev/compila-local.bash \
  | tar -x -C "${SAIDA}/fonte_antiga" \
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
      -O2 -ffp-contract=off -c "${src}/tests/atmgrid/test_mpas_export.F90" -o test_mpas_export.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_mpas_export test_mpas_export.o $(objetos "${src}" "${src}/tests/atmgrid/test_mpas_export.F90") ${ELIB} $(nf-config --flibs) -fopenmp
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
traduzido() { sed -Ef "${RAIZ}/tests/log-traduzido.sed" "$1"; }
mensagem() { sed -E 's/^[0-9]+ +[0-9.]+ +[A-Z]+ +//'; }
# Cobertura das células: na saída padrão ([MPAS-DIAG], versões até a
# R-FASE13-10) ou no log do ESMF, sem o PET
cobertura() {
  { grep -h 'MPAS-DIAG' "$1/run.log" \
      | sed -E 's/^\[MPAS-DIAG\] ([A-Za-z0-9_]+): n_local=/ATM: DIAG cell_binning coverage: campo=\1 n_local=/'
    cat "$1"/PET*.teste_grade_atm | grep -h 'DIAG cell_binning coverage' | mensagem | sed -E 's/^PET[0-9]+ //'
  }
}
if diff -q <(cobertura "${SAIDA}/antiga/run") <(cobertura "${SAIDA}/nova/run") > /dev/null; then
  echo "  saída igual    cobertura das células ($(cobertura "${SAIDA}/antiga/run" | wc -l) linhas)"
else
  echo "  saída DIFERE   cobertura das células"; difere=1
fi
# Mensagens de diagnóstico e de erro no log do ESMF, sem data, hora e severidade
padrao='DIAG cell_binning fill|ERROR|WARNING|state_set_field_1d|mpas_export'
for pet in "${SAIDA}"/antiga/run/PET*.teste_grade_atm; do
  nome=$(basename "${pet}")
  if diff -q <(traduzido "${pet}" | grep -E "${padrao}" | mensagem) \
             <(grep -E "${padrao}" "${SAIDA}/nova/run/${nome}" | mensagem) > /dev/null; then
    echo "  log igual      ${nome} ($(grep -cE "${padrao}" "${pet}") linhas)"
  else
    echo "  log DIFERE     ${nome}"; difere=1
  fi
done
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: grade do cap atmosférico idêntica"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
