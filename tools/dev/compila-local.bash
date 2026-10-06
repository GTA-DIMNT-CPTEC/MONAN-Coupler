#!/usr/bin/env bash
# =============================================================================
# compila-local.bash: compila, fora da Jaci, os fontes do acoplador.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila todos os fontes de src/, menos os que só compilam na Jaci (os do
# MOM6 em caps/ocean/upstream/ e o programa principal, em main/), com as
# mesmas opções de aviso e de ponto flutuante do Makefile, contra um ESMF
# instalado localmente. A ordem vem dos 'use' (tools/dev/dependencias.py).
# Os fontes que dependem do MPAS, do MOM6 ou do FMS são compilados contra as
# interfaces mínimas de tests/interfaces/, que só garantem tipos e
# assinaturas. Os objetos ficam em SAIDA; os testes ligam os de que precisam
# (tools/dev/dependencias.py objetos).
#
# Uso:
#   ESMFMKFILE=/caminho/esmf.mk tools/dev/compila-local.bash [-s RAIZ] [-o SAIDA]
#     -s RAIZ    raiz do repositório a compilar (padrão: a deste script); pode
#                ser a cópia de um commit anterior
#     -o SAIDA   diretório dos objetos e logs (padrão: RAIZ/build-local)
#
# Saída: uma linha por fonte (OK ou FALHOU, e o número de avisos); o log de
# cada fonte fica em SAIDA/<fonte>.log. Código de saída 1 se algum falhou.
#
# Para comparar duas versões, compile cada uma num diretório e compare os
# avisos: a versão anterior deve compilar antes com as mesmas interfaces.
# =============================================================================
set -uo pipefail

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=""
while getopts ":s:o:h" opt; do
  case "${opt}" in
    s) RAIZ=$(cd "${OPTARG}" && pwd) ;;
    o) SAIDA="${OPTARG}" ;;
    h) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "ERRO: opção inválida" >&2; exit 2 ;;
  esac
done
SAIDA=${SAIDA:-${RAIZ}/build-local}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] \
  || { echo "ERRO: defina ESMFMKFILE com o esmf.mk do ESMF instalado" >&2; exit 2; }
command -v nf-config >/dev/null || { echo "ERRO: nf-config (NetCDF-Fortran) não encontrado" >&2; exit 2; }

FC=${FC:-mpif90}
EINC=$(grep '^ESMF_F90COMPILEPATHS=' "${ESMFMKFILE}" | cut -d= -f2-)
INTERF=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tests/interfaces" && pwd)
DEPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dependencias.py"

mkdir -p "${SAIDA}" && cd "${SAIDA}" || exit 2
# Objetos e módulos de uma compilação anterior saem: um fonte renomeado ou
# removido não pode deixar um objeto velho para os scripts que ligam os
# objetos presentes (desde a R-FASE11-24, que renomeou mpas_cap_methods).
rm -f -- *.o *.mod
# Mesmas opções do Makefile (sem as do MOM6), com pré-processador.
FL="${EINC} -I$(nf-config --includedir) -I. -J. -cpp -ffree-form -ffree-line-length-none"
FL+=" -fopenmp -fallow-argument-mismatch -ffpe-summary=none -O2 -ffp-contract=off -g"
FL+=" -fcheck=all -fbacktrace -Wall -Wno-unused-dummy-argument"

for s in mpas_stubs mom_stubs sis_stubs; do
  # shellcheck disable=SC2086
  ${FC} ${FL} -c "${INTERF}/${s}.F90" -o "${s}.o" > "${s}.log" 2>&1 \
    || { echo "ERRO: interfaces mínimas não compilam; ver ${SAIDA}/${s}.log" >&2; exit 2; }
done

# Fontes e ordem: todos os .F90 de src/ que não dependem das bibliotecas dos
# modelos (sem caps/ocean/upstream/ e main/), na ordem dada pelos 'use'
# (tools/dev/dependencias.py, aplicado à árvore RAIZ). Com real de 8 bytes,
# os de MOM6_SRCS do Makefile da mesma árvore, como na compilação da Jaci.
ORDEM=$(python3 "${DEPS}" ordem -s "${RAIZ}") \
  || { echo "ERRO: ordem de compilação (dependencias.py)" >&2; exit 2; }
REAL8=" $(awk '/^MOM6_SRCS[[:space:]]*:=/ {on=1; sub(/^[^=]*=/, "")}
               on {c = /\\[[:space:]]*$/; sub(/\\[[:space:]]*$/, ""); printf "%s ", $0; if (!c) exit}' \
         "${RAIZ}/Makefile") "
[[ -n "${REAL8// /}" ]] || { echo "ERRO: MOM6_SRCS não encontrado em ${RAIZ}/Makefile" >&2; exit 2; }

falhas=0
for s in ${ORDEM}; do
  f=$(find "${RAIZ}/src" -name "${s}.F90" -not -path '*/upstream/*' | head -1)
  extra=""
  case "${REAL8}" in *" ${s} "*) extra="-fdefault-real-8" ;; esac
  # shellcheck disable=SC2086
  if ${FC} ${FL} ${extra} -c "${f}" -o "${s}.o" > "${s}.log" 2>&1; then r=OK; else r=FALHOU; falhas=$((falhas + 1)); fi
  printf '%-24s %-7s avisos=%s\n' "${s}" "${r}" "$(grep -c 'Warning' "${s}.log")"
done
[[ ${falhas} -eq 0 ]] || { echo "${falhas} fonte(s) com falha; logs em ${SAIDA}"; exit 1; }
