#!/usr/bin/env bash
# =============================================================================
# compara-gravadores.bash: teste de regressão dos gravadores de diagnóstico.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a versão de um commit e a da árvore de trabalho, liga a cada uma o
# seu programa test_writers.F90 (o de REV na versão antiga, o da árvore de
# trabalho na nova, para que uma etapa possa mudar a interface dos
# gravadores) e o executa com 4 processos MPI e dados sintéticos. O
# programa chama med_write_import_fields e write_mpas_import_diag duas vezes
# cada (com e sem membros de atm_bnd, com valores inválidos e máscara de
# terra), export_write_netcdf duas vezes (campos guardados e caminho de
# reserva, grade de 2°) e WriteDOCNDiag três vezes
# (sem e com correntes, gelo em fração e em %, arquivo de SST ausente),
# com configurações e arquivos de dados próprios. Os arquivos NetCDF gravados e
# as mensagens de log dos gravadores têm de ser idênticos nas duas versões.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/writers/compara-gravadores.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase4-03-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/gravadores)
#
# Variáveis: MPIRUN (padrão: mpiexec), NP (padrão: 4; tem de ser par).
# Ambiente: ESMF, NetCDF-Fortran (nf-config) e MPI; nenhuma biblioteca dos
# modelos (as interfaces mínimas de tests/interfaces bastam).
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,20p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/gravadores}" && cd "${2:-${RAIZ}/build-local/gravadores}" && pwd)
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

# Fontes da versão de referência e o seu test_writers.F90, extraídos do git,
# com os arquivos incluídos de tests/unit (*.inc), quando REV os tem
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src Makefile tests/writers/test_writers.F90 | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }
mapfile -t incs < <(git -C "${RAIZ}" ls-tree --name-only "${REV}" tests/unit/ | grep '\.inc$')
if [[ ${#incs[@]} -gt 0 ]]; then
  git -C "${RAIZ}" archive "${REV}" "${incs[@]}" | tar -x -C "${SAIDA}/fonte_antiga" \
    || { echo "ERRO: não foi possível extrair os .inc de ${REV}" >&2; exit 2; }
fi

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
    ${FC} ${EINC} -I. -I"$(nf-config --includedir)" -ffree-line-length-none -fallow-argument-mismatch \
      -O2 -ffp-contract=off -c "${src}/tests/writers/test_writers.F90" -o test_writers.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_writers test_writers.o $(objetos "${src}" "${src}/tests/writers/test_writers.F90") ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  echo "--- versão ${versao}: executando com ${NP} processos"
  rm -rf "${dir}/run"; mkdir -p "${dir}/run"
  ( cd "${dir}/run" && ${MPIRUN} -n "${NP}" ../test_writers > run.log 2>&1 ) \
    || { tail -20 "${dir}/run/run.log"; echo "ERRO: execução da versão ${versao}" >&2; exit 2; }
done

difere=0
n=0
for f in $(cd "${SAIDA}/antiga/run" && find out_med diag_import out_docn out_mpas_export -name '*.nc' 2> /dev/null | sort); do
  n=$((n + 1))
  if cmp -s "${SAIDA}/antiga/run/${f}" "${SAIDA}/nova/run/${f}"; then
    echo "  igual (bytes)  ${f}"
  else
    echo "  DIFERE         ${f}"; difere=1
  fi
done
[[ ${n} -gt 0 ]] || { echo "ERRO: nenhum arquivo gravado; ver ${SAIDA}/antiga/run/run.log" >&2; exit 2; }
# Mensagens dos gravadores no log do ESMF, sem data e hora
padrao='FIX-DIAG-NCWRITE|AVISO|B-DIAGMASK|escrito|ERRO NetCDF|WriteDOCNDiag'
for pet in "${SAIDA}"/antiga/run/PET*.ESMF_LogFile; do
  nome=$(basename "${pet}")
  if diff -q <(grep -E "${padrao}" "${pet}" | cut -d' ' -f3-) \
             <(grep -E "${padrao}" "${SAIDA}/nova/run/${nome}" | cut -d' ' -f3-) > /dev/null; then
    echo "  log igual      ${nome}"
  else
    echo "  log DIFERE     ${nome}"; difere=1
  fi
done
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: gravadores idênticos"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
