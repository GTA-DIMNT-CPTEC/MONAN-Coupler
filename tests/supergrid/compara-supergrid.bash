#!/usr/bin/env bash
# =============================================================================
# compara-supergrid.bash: teste de regressão da leitura do supergrid do MOM6.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# A rodada da linha de base lê um único supergrid, sempre sem erro. Este teste
# compila a versão de um commit e a da árvore de trabalho (compila-local.bash),
# liga a cada uma o programa tests/supergrid/test_supergrid.F90 da árvore de
# trabalho, com os objetos de que ele depende (mom6_supergrid e, desde a
# R-FASE13-12, o registro do acoplador), e o executa sobre supergrids sintéticos
# (tests/supergrid/gera-supergrid.py), inclusive com dimensões ímpares, sem as
# variáveis x e y e com arquivo inexistente. Têm de ser idênticos, bit a bit:
# os códigos de retorno, as dimensões e as coordenadas gravados (saida.bin) e
# as mensagens do log do ESMF, sem data, hora e severidade (as da versão
# anterior passam antes pelas traduções de tests/log-traduzido.sed).
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
# Objetos de que o programa depende, tirados dos 'use' da árvore dada
objetos() { python3 "${RAIZ}/tools/dev/dependencias.py" objetos -s "$1" -i "${RAIZ}/tests/interfaces" "$2"; }

python3 "${RAIZ}/tests/supergrid/gera-supergrid.py" "${SAIDA}/dados" \
  || { echo "ERRO: geração dos supergrids sintéticos" >&2; exit 2; }

rm -rf "${SAIDA}/antiga" "${SAIDA}/nova" "${SAIDA}/fonte_antiga"
mkdir -p "${SAIDA}/antiga" "${SAIDA}/nova" "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src Makefile | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  echo "--- versão ${versao}: compilando e executando"
  # shellcheck disable=SC2086,SC2046
  ( bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" &&
    cd "${dir}" &&
    ${FC} ${EINC} -I. ${FL} -c "${RAIZ}/tests/supergrid/test_supergrid.F90" -o test_supergrid.o &&
    ${FC} -o test_supergrid test_supergrid.o $(objetos "${src}" "${RAIZ}/tests/supergrid/test_supergrid.F90") \
      ${ELIB} $(nf-config --flibs) -fopenmp
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
# mensagens do módulo: sem data, hora e severidade, e sem as linhas de
# abertura do ESMF; as da versão anterior passam pelas traduções de texto
filtra() { sed -E 's/^[0-9]+ +[0-9.]+ +[A-Z]+ +//' | grep -E 'supergrid|DIAG|AVISO|variaveis|falha'; }
nlin=$(sed -Ef "${RAIZ}/tests/log-traduzido.sed" "${a}/log.txt" | filtra | wc -l)
[[ ${nlin} -gt 0 ]] || { echo "ERRO: nenhuma mensagem do módulo em ${a}/log.txt" >&2; exit 2; }
if diff -q <(sed -Ef "${RAIZ}/tests/log-traduzido.sed" "${a}/log.txt" | filtra) \
           <(filtra < "${n}/log.txt") > /dev/null; then
  echo "  log igual      log.txt (${nlin} linhas)"
else
  echo "  log DIFERE     log.txt"; difere=1
  diff <(sed -Ef "${RAIZ}/tests/log-traduzido.sed" "${a}/log.txt" | filtra) <(filtra < "${n}/log.txt") | head -20
fi
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: supergrid idêntico"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
