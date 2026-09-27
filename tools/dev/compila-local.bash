#!/usr/bin/env bash
# =============================================================================
# compila-local.bash: compila, fora da Jaci, os fontes do acoplador.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila os fontes na ordem do Makefile, com as mesmas opções de aviso e
# de ponto flutuante, contra um ESMF instalado localmente. Os fontes que
# dependem do MPAS, do MOM6 ou do FMS são compilados contra as interfaces
# mínimas de tests/interfaces/, que só garantem tipos e assinaturas; o
# sis_cap_MONAN.F90, o driver e o programa principal ficam de fora.
#
# Uso:
#   ESMFMKFILE=/caminho/esmf.mk tools/dev/compila-local.bash [-s RAIZ] [-o SAIDA]
#     -s RAIZ    raiz do repositório a compilar (padrão: a deste script)
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
    h) sed -n '2,22p' "$0"; exit 0 ;;
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

mkdir -p "${SAIDA}" && cd "${SAIDA}" || exit 2
# Mesmas opções do Makefile (sem as do MOM6), com pré-processador.
FL="${EINC} -I$(nf-config --includedir) -I. -J. -cpp -ffree-form -ffree-line-length-none"
FL+=" -fopenmp -fallow-argument-mismatch -ffpe-summary=none -O2 -ffp-contract=off -g"
FL+=" -fcheck=all -fbacktrace -Wall -Wno-unused-dummy-argument"

for s in mpas_stubs mom_stubs; do
  # shellcheck disable=SC2086
  ${FC} ${FL} -c "${INTERF}/${s}.F90" -o "${s}.o" > "${s}.log" 2>&1 \
    || { echo "ERRO: interfaces mínimas não compilam; ver ${SAIDA}/${s}.log" >&2; exit 2; }
done

falhas=0
for s in coupler_utils coupler_constants coupler_config diag_bitsum mom6_supergrid nc_writer \
         regrid_base regrid_esmf regrid_weights regrid_mpassit regrid_registry regrid_manager \
         mpi_allreduce_r8 mpi_allreduce_i4 mpi_allreduce_wrappers \
         mpas_atm_types mpas_atm_model mpas_cap_netcdf mpas_cap_methods mpas_cap_MONAN DATM_cap \
         docn_cap_netcdf DOCN_cap time_utils mom_cap_MONAN \
         med_cap_types med_cap_netcdf med_cap_methods med_bulk_ncar MED_cap; do
  f=$(find "${RAIZ}/src" -name "${s}.F90" -not -path '*/upstream/*' | head -1)
  [[ -n "${f}" ]] || { printf '%-24s %s\n' "${s}" "AUSENTE"; falhas=$((falhas + 1)); continue; }
  extra=""
  # Como no Makefile: os fontes ligados ao MOM6 usam real de 8 bytes.
  case "${s}" in mom_cap_MONAN|time_utils) extra="-fdefault-real-8" ;; esac
  # shellcheck disable=SC2086
  if ${FC} ${FL} ${extra} -c "${f}" -o "${s}.o" > "${s}.log" 2>&1; then r=OK; else r=FALHOU; falhas=$((falhas + 1)); fi
  printf '%-24s %-7s avisos=%s\n' "${s}" "${r}" "$(grep -c 'Warning' "${s}.log")"
done
[[ ${falhas} -eq 0 ]] || { echo "${falhas} fonte(s) com falha; logs em ${SAIDA}"; exit 1; }
