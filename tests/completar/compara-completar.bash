#!/usr/bin/env bash
# =============================================================================
# compara-completar.bash: teste de regressão dos campos que o mediador
# completa por vizinhança depois da interpolação (a SST na malha de fluxo e
# a fração de gelo exportada ao oceano).
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a versão de um commit e a da árvore de trabalho, liga a cada uma o
# programa tests/completar/test_completar.F90 da árvore de trabalho (ele só
# usa interfaces que existem desde a fase11-12-validada; as fases de
# med_exchange que a versão tiver entram com -DCOM_ENTREGAR e -DCOM_IR_PARA) e o
# executa com 1, 4, 6 e 8 processos MPI, com um supergrid sintético
# (tests/supergrid/gera-supergrid.py). Para cada PET, os valores gravados
# (saida_<PET>.bin: a SST na malha de fluxo e todos os campos exportados ao
# oceano, com os carimbos de tempo, em três passos, e as contagens de pontos
# completados) têm de ser idênticos, bit a bit, e as mensagens do mediador
# e do framework de interpolação no log do ESMF também, sem data e hora,
# incluindo as linhas do relatório de acoplamento (CPL-REL:).
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/completar/compara-completar.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase11-13-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/completar)
#
# Variáveis: MPIRUN (padrão: mpiexec), FC (padrão: mpif90), LISTA_NP
# (padrão: "1 4 6 8").
# Ambiente: ESMF, NetCDF-Fortran (nf-config), MPI, python3 e ncgen; nenhuma
# biblioteca dos modelos (as interfaces mínimas de tests/interfaces bastam).
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,28p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/completar}" && cd "${2:-${RAIZ}/build-local/completar}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
FC=${FC:-mpif90}
LISTA_NP=${LISTA_NP:-1 4 6 8}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
OBJS="coupler_utils.o coupler_constants.o coupler_config.o diag_bitsum.o mom6_supergrid.o
      nc_writer.o cap_common.o regrid_base.o regrid_esmf.o regrid_weights.o regrid_mpassit.o
      regrid_registry.o regrid_manager.o cpl_grids.o cpl_fields.o cpl_map.o mpas_stubs.o
      mpi_allreduce_r8.o mpi_allreduce_i4.o mpi_allreduce_wrappers.o
      med_cap_types.o med_cap_netcdf.o med_cap_methods.o med_bulk_ncar.o med_diag.o
      med_ice.o med_ocean.o med_init.o med_export.o med_exchange.o"
objs_presentes() { local o; for o in ${OBJS}; do [[ -f ${o} ]] && printf '%s ' "${o}"; done; }

python3 "${RAIZ}/tests/supergrid/gera-supergrid.py" "${SAIDA}/dados" > /dev/null \
  || { echo "ERRO: geração do supergrid sintético" >&2; exit 2; }

# Fontes da versão de referência, extraídos do git
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src tests/interfaces tools/dev/compila-local.bash \
  | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  echo "--- versão ${versao}: compilando"
  bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" -a > "${SAIDA}/compila_${versao}.txt" \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  ( cd "${dir}" || exit 2
    # Fases de med_exchange presentes na versão: entregar (desde a
    # R-FASE11-15) e ir_para_malha_de_fluxo (desde a R-FASE11-16)
    defs=""; mx="${src}/src/mediator/med_exchange.F90"
    grep -qi 'subroutine entregar' "${mx}" 2>/dev/null && defs+=" -DCOM_ENTREGAR"
    grep -qi 'subroutine ir_para_malha_de_fluxo' "${mx}" 2>/dev/null && defs+=" -DCOM_IR_PARA"
    # shellcheck disable=SC2086
    ${FC} ${EINC} -I. -cpp ${defs} -ffree-line-length-none -fallow-argument-mismatch \
      -O2 -ffp-contract=off -c "${RAIZ}/tests/completar/test_completar.F90" -o test_completar.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_completar test_completar.o $(objs_presentes) ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  for np in ${LISTA_NP}; do
    run="${dir}/run_${np}"
    rm -rf "${run}"; mkdir -p "${run}"; cp "${SAIDA}/dados/hgrid.nc" "${run}/"
    # shellcheck disable=SC2086
    ( cd "${run}" && ${MPIRUN} -n "${np}" ../test_completar > run.log 2>&1 ) \
      || { tail -20 "${run}/run.log"; echo "ERRO: execução da versão ${versao} com ${np} processos" >&2; exit 2; }
  done
done

difere=0
padrao='MED|CPL-REL|regrid|ERROR|WARNING'
for np in ${LISTA_NP}; do
  n=0
  for f in $(cd "${SAIDA}/antiga/run_${np}" && ls saida_*.bin 2>/dev/null); do
    n=$((n + 1))
    if ! cmp -s "${SAIDA}/antiga/run_${np}/${f}" "${SAIDA}/nova/run_${np}/${f}"; then
      echo "  DIFERE         ${np} PETs: ${f}"; difere=1
    fi
  done
  [[ ${n} -eq ${np} ]] || { echo "ERRO: ${np} PETs: esperados ${np} arquivos, gravados ${n}" >&2; exit 2; }
  linhas=$(grep -h 'CPL-REL: completar' "${SAIDA}/nova/run_${np}"/PET*.teste_completar | wc -l)
  echo "  ${np} PET(s): ${n} arquivo(s) comparados, ${linhas} linha(s) 'completar' no relatório"
  for pet in "${SAIDA}/antiga/run_${np}"/PET*.teste_completar; do
    nome=$(basename "${pet}")
    if ! diff -q <(grep -E "${padrao}" "${pet}" | cut -d' ' -f3-) \
                 <(grep -E "${padrao}" "${SAIDA}/nova/run_${np}/${nome}" | cut -d' ' -f3-) > /dev/null; then
      echo "  log DIFERE     ${np} PETs: ${nome}"; difere=1
    fi
  done
done

if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: campos completados idênticos"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
