#!/usr/bin/env bash
# =============================================================================
# compara-malhas.bash: teste de regressão da construção das malhas do
# mediador (malha de fluxo e oceano, com o MOM6 e com o DOCN) e da grade do
# cap do MONAN-A.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a versão de um commit e a da árvore de trabalho, liga a cada uma o
# programa tests/malhas/test_grids.F90 da árvore de trabalho (ele só usa
# create_atm_grid, create_ocn_grid e mpas_create_grid, cujas interfaces não
# mudam) e o executa com 1, 4, 6 e 8 processos MPI, com um supergrid
# sintético (tests/supergrid/gera-supergrid.py). Para cada PET e cada DE
# local, os limites computacionais e os vetores de coordenadas dos centros e
# dos cantos e a máscara gravados (saida_<PET>.bin) têm de ser idênticos,
# bit a bit, e as mensagens das rotinas no log do ESMF também, sem data e
# hora. Depois, só na árvore de trabalho, tests/malhas/test_model_grids.F90
# confere as malhas dos caps do SIS2 e do MOM6 (ver o cabeçalho do
# programa) com 4, 6 e 8 processos.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/malhas/compara-malhas.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase11-07-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/malhas)
#
# Variáveis: MPIRUN (padrão: mpiexec), FC (padrão: mpif90), LISTA_NP
# (padrão: "1 4 6 8").
# Ambiente: ESMF, NetCDF-Fortran (nf-config), MPI, python3 e ncgen; nenhuma
# biblioteca dos modelos (as interfaces mínimas de tests/interfaces bastam).
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
# Objetos de que um programa de teste depende, tirados dos 'use' da árvore
# dada (a de trabalho ou a cópia de REV): objetos RAIZ_DA_VERSAO PROGRAMA.F90
objetos() { python3 "${RAIZ}/tools/dev/dependencias.py" objetos -s "$1" -i "${RAIZ}/tests/interfaces" "$2"; }

python3 "${RAIZ}/tests/supergrid/gera-supergrid.py" "${SAIDA}/dados" > /dev/null \
  || { echo "ERRO: geração do supergrid sintético" >&2; exit 2; }

# Fontes da versão de referência, extraídos do git
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src Makefile tests/interfaces tools/dev/compila-local.bash \
  | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }
# Com nomes trocados desde REV (fase 12), a cópia de REV recebe os nomes de
# hoje, para compilar com o programa de teste da árvore de trabalho
"${RAIZ}/tools/dev/renomeia-identificadores.py" traduz "${REV}" "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: tradução dos nomes de ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  echo "--- versão ${versao}: compilando"
  # shellcheck disable=SC2086
  bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" > "${SAIDA}/compila_${versao}.txt" \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  defs=""
  [[ -f "${src}/src/caps/atmos/mpas_adapter.F90" ]] && defs="-DCOM_ADAPTADOR"
  ( cd "${dir}" || exit 2
    # shellcheck disable=SC2086
    ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch ${defs} \
      -O2 -ffp-contract=off -c "${RAIZ}/tests/malhas/test_grids.F90" -o test_grids.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_grids test_grids.o $(objetos "${src}" "${RAIZ}/tests/malhas/test_grids.F90") ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  for np in ${LISTA_NP}; do
    run="${dir}/run_${np}"
    rm -rf "${run}"; mkdir -p "${run}"; cp "${SAIDA}/dados/hgrid.nc" "${run}/"
    # shellcheck disable=SC2086
    ( cd "${run}" && ${MPIRUN} -n "${np}" ../test_grids > run.log 2>&1 ) \
      || { tail -20 "${run}/run.log"; echo "ERRO: execução da versão ${versao} com ${np} processos" >&2; exit 2; }
  done
done

difere=0
# Linhas de log retiradas de propósito (tests/log-retirado.txt) ficam fora
# da comparação com REV, que ainda as grava
retirado() { grep -vEf "${RAIZ}/tests/log-retirado.txt"; }
padrao='MED|FIX-DIAG|mpas_create_grid|cpl_malha|ERROR|WARNING'
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
    if ! diff -q <(grep -E "${padrao}" "${pet}" | retirado | cut -d' ' -f3-) \
                 <(grep -E "${padrao}" "${SAIDA}/nova/run_${np}/${nome}" | retirado | cut -d' ' -f3-) > /dev/null; then
      echo "  log DIFERE     ${np} PETs: ${nome}"; difere=1
    fi
  done
done

# Malhas dos caps do SIS2 e do MOM6: só na árvore de trabalho, contra as de antes
dir="${SAIDA}/nova"
( cd "${dir}" || exit 2
  # shellcheck disable=SC2086
  ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch \
    -O2 -ffp-contract=off -c "${RAIZ}/tests/malhas/test_model_grids.F90" -o test_model_grids.o &&
  # shellcheck disable=SC2086
  ${FC} -o test_model_grids test_model_grids.o $(objetos "${RAIZ}" "${RAIZ}/tests/malhas/test_model_grids.F90") ${ELIB} $(nf-config --flibs) -fopenmp
) > "${SAIDA}/liga_caps.txt" 2>&1 \
  || { cat "${SAIDA}/liga_caps.txt"; echo "ERRO: ligação de test_model_grids" >&2; exit 2; }
for np in 4 6 8; do
  run="${dir}/caps_${np}"
  rm -rf "${run}"; mkdir -p "${run}"; cp "${SAIDA}/dados/hgrid.nc" "${run}/"
  # shellcheck disable=SC2086
  if ( cd "${run}" && ${MPIRUN} -n "${np}" ../test_model_grids > run.log 2>&1 ) \
     && grep -q 'TODOS OS TESTES PASSARAM' "${run}/run.log"; then
    echo "  caps, ${np} PETs: $(grep -c PASSOU "${run}/run.log") caso(s) iguais"
  else
    grep 'FALHOU' "${run}/run.log"; tail -5 "${run}/run.log"
    echo "  caps DIFERE    ${np} PETs"; difere=1
  fi
done

if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: malhas idênticas"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
