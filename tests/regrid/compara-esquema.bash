#!/usr/bin/env bash
# =============================================================================
# compara-esquema.bash: confere um esquema de interpolação de src/regrid.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Para quem escreve um esquema novo (modelo: src/regrid/regrid_idw.F90).
# Compila tests/regrid/test_scheme.F90 e interpola o campo analítico
# f = 2 + cos(lat) cos(lon) de uma grade global de 4 graus para uma de 1
# grau, com o esquema pedido e com uma referência (um método do esquema
# esmf), em 1 e em NP processos MPI. Mostra o erro máximo e médio de cada
# um contra a função (onde |lat| < 85 graus) e a diferença máxima entre os
# dois, e confere que o esquema dá o mesmo campo, bit a bit, com 1 e com
# NP processos (os esquemas de pesos somam na ordem do índice de origem).
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/regrid/compara-esquema.bash ESQUEMA [OPCOES] [REFERENCIA] [SAIDA]
#     ESQUEMA     nome na lista de src/regrid/regrid_schemes.F90 (ex.: idw)
#     OPCOES      opções do esquema, 'chave=valor,...' (padrão: nenhuma)
#     REFERENCIA  método do esquema esmf (padrão: bilinear)
#     SAIDA       diretório de trabalho (padrão: build-local/esquema)
#   Ex.: tests/regrid/compara-esquema.bash idw 'vizinhos=4,expoente=2'
#
# Variáveis: MPIRUN (padrão: mpiexec), NP (padrão: 4).
# Código de saída: 0 se as duas rodadas terminam e o campo é igual com 1 e
# NP processos; 1 caso contrário; 2 erro de uso ou de compilação.
# =============================================================================
set -uo pipefail

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ $# -ge 1 ]] || { sed -n '3,26p' "${BASH_SOURCE[0]}"; exit 2; }
ESQUEMA=$1
OPCOES=${2:--}
REFERENCIA=${3:-bilinear}
SAIDA=$(mkdir -p "${4:-${RAIZ}/build-local/esquema}" && cd "${4:-${RAIZ}/build-local/esquema}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
NP=${NP:-4}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }
[[ -z "${OPCOES}" ]] && OPCOES=-

echo "--- compilando tests/regrid/test_scheme"
make -C "${RAIZ}/tests/regrid" test_scheme > "${SAIDA}/compila.txt" 2>&1 \
  || { cat "${SAIDA}/compila.txt"; echo "ERRO: compilação" >&2; exit 2; }

falhas=0
for n in 1 "${NP}"; do
  dir="${SAIDA}/np${n}"
  rm -rf "${dir}" && mkdir -p "${dir}"
  echo "--- ${ESQUEMA} (opções: ${OPCOES}) contra esmf ${REFERENCIA}, ${n} processo(s)"
  # shellcheck disable=SC2086
  if (cd "${dir}" && ${MPIRUN} -np "${n}" "${RAIZ}/tests/regrid/test_scheme" \
        "${ESQUEMA}" "${OPCOES}" "${REFERENCIA}" campo.bin > execucao.txt 2>&1); then
    sed -n 's/^\(METODO\|ERRO_\|DIF_\)/   &/p' "${dir}/execucao.txt"
  else
    echo "FALHOU  a execução com ${n} processo(s) terminou com erro (ver ${dir})"
    grep -h 'ERROR' "${dir}"/PET*.test_esquema.log 2>/dev/null | sed 's/^.*ERROR *PET[0-9]* /   /' | head -5
    falhas=$((falhas + 1))
  fi
done

if [[ ${falhas} -eq 0 ]]; then
  if cmp -s "${SAIDA}/np1/campo.bin" "${SAIDA}/np${NP}/campo.bin"; then
    echo "PASSOU  campo do esquema igual, bit a bit, com 1 e ${NP} processos"
  else
    echo "FALHOU  campo do esquema diferente com 1 e ${NP} processos"
    falhas=$((falhas + 1))
  fi
fi

if [[ ${falhas} -eq 0 ]]; then
  echo "RESULTADO: esquema ${ESQUEMA} conferido"
  exit 0
fi
echo "RESULTADO: ${falhas} falha(s); saída em ${SAIDA}"
exit 1
