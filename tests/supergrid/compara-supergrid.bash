#!/usr/bin/env bash
# =============================================================================
# compara-supergrid.bash: teste de regressão da leitura do supergrid do MOM6.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# A rodada da linha de base lê um único supergrid, sempre sem erro. Este teste
# compila src/shared/mom6_supergrid.F90 de um commit e o da árvore de
# trabalho, liga a cada um o programa tests/supergrid/test_supergrid.F90 da
# árvore de trabalho e o executa sobre supergrids sintéticos
# (tests/supergrid/gera-supergrid.py), inclusive com dimensões ímpares, sem as
# variáveis x e y e com arquivo inexistente. Têm de ser idênticos, bit a bit:
# os códigos de retorno, as dimensões e as coordenadas gravados (saida.bin) e
# as mensagens do log do ESMF, sem data e hora.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/supergrid/compara-supergrid.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase9-07-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/supergrid)
#
# Variáveis: FC (padrão: mpif90).
# Ambiente: ESMF, NetCDF-Fortran (nf-config), MPI, python3 e ncgen.
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,23p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/supergrid}" && cd "${2:-${RAIZ}/build-local/supergrid}" && pwd)
FC=${FC:-mpif90}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
FL="-O2 -ffp-contract=off -ffree-line-length-none -fallow-argument-mismatch"

python3 "${RAIZ}/tests/supergrid/gera-supergrid.py" "${SAIDA}/dados" \
  || { echo "ERRO: geração dos supergrids sintéticos" >&2; exit 2; }

rm -rf "${SAIDA}/antiga" "${SAIDA}/nova"; mkdir -p "${SAIDA}/antiga" "${SAIDA}/nova"
git -C "${RAIZ}" show "${REV}:src/shared/mom6_supergrid.F90" > "${SAIDA}/antiga/mom6_supergrid.F90" \
  || { echo "ERRO: não foi possível extrair mom6_supergrid.F90 de ${REV}" >&2; exit 2; }
cp "${RAIZ}/src/shared/mom6_supergrid.F90" "${SAIDA}/nova/"

for versao in antiga nova; do
  dir="${SAIDA}/${versao}"
  echo "--- versão ${versao}: compilando e executando"
  # shellcheck disable=SC2086,SC2046
  ( cd "${dir}" || exit 2
    ${FC} ${EINC} $(nf-config --fflags) ${FL} -c mom6_supergrid.F90 -o mom6_supergrid.o &&
    ${FC} ${EINC} -I. ${FL} -c "${RAIZ}/tests/supergrid/test_supergrid.F90" -o test_supergrid.o &&
    ${FC} -o test_supergrid test_supergrid.o mom6_supergrid.o ${ELIB} $(nf-config --flibs)
  ) > "${SAIDA}/compila_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  mkdir -p "${dir}/run"
  cp "${SAIDA}"/dados/*.nc "${dir}/run/"
  ( cd "${dir}/run" && timeout 120 ../test_supergrid > run.log 2>&1 ) \
    || { tail -20 "${dir}/run/run.log"; echo "ERRO: execução da versão ${versao}" >&2; exit 2; }
done

a="${SAIDA}/antiga/run"; n="${SAIDA}/nova/run"
difere=0
if cmp -s "${a}/saida.bin" "${n}/saida.bin"; then
  echo "  igual (bytes)  saida.bin ($(stat -c %s "${a}/saida.bin") bytes)"
else
  echo "  DIFERE         saida.bin"; difere=1
fi
# mensagens do módulo: sem data e hora, e sem as linhas de abertura do ESMF
filtra() { cut -d' ' -f3- "$1" | grep -E 'supergrid|DIAG|AVISO|variaveis|falha'; }
nlin=$(filtra "${a}/log.txt" | wc -l)
[[ ${nlin} -gt 0 ]] || { echo "ERRO: nenhuma mensagem do módulo em ${a}/log.txt" >&2; exit 2; }
if diff -q <(filtra "${a}/log.txt") <(filtra "${n}/log.txt") > /dev/null; then
  echo "  log igual      log.txt (${nlin} linhas)"
else
  echo "  log DIFERE     log.txt"; difere=1
  diff <(filtra "${a}/log.txt") <(filtra "${n}/log.txt") | head -20
fi
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: supergrid idêntico"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
