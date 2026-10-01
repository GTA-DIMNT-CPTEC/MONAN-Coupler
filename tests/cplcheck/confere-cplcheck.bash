#!/usr/bin/env bash
# =============================================================================
# confere-cplcheck.bash: conferência do mapa de acoplamento num driver NUOPC.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a árvore de trabalho (compila-local.bash) e o driver de teste
# tests/cplcheck/test_cplcheck_driver.F90, em que quatro componentes com os
# rótulos do driver real (MPAS, MED, OCN, ICE) anunciam as listas de campos
# de hoje e são ligados pelos seis conectores da produção. A especialização
# ModifyCplLists chama cpl_check_acoplamento, como o esm.F90. Dois casos,
# cada um em NP processos MPI:
#   normal   listas de hoje: o relatório tem os seis conectores com 13, 7,
#            14, 16, 4 e 6 campos, e a conferência dá 0 diferenças e 3
#            avisos (So_s, Fioo_q e Si_ifrac do MOM6, sem consumidor)
#   defeito  o OCN importa So_teste e o MED não anuncia So_omask: o
#            conector OCN -> MED leva 3 campos, a conferência dá 4
#            diferenças, e a inicialização termina assim mesmo
#   mediador o MED é o mediador real (MED_cap), que desde a R-FASE11-05
#            anuncia os campos a partir do mapa: o relatório tem de dar os
#            mesmos conectores, 0 diferenças e 3 avisos; a inicialização
#            para de propósito logo depois da conferência
# Em ambos, só o PET 0 escreve as linhas CPL-REL:. O relatório de cada caso
# fica em SAIDA/relatorio_<caso>.txt, sem data e hora.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/cplcheck/confere-cplcheck.bash [SAIDA]
#     SAIDA   diretório de trabalho (padrão: build-local/cplcheck)
#
# Variáveis: MPIRUN (padrão: mpiexec), NP (padrão: 4), FC (padrão: mpif90).
# Código de saída: 0 se os dois casos dão o esperado; 1 caso contrário;
# 2 erro de preparo.
# =============================================================================
set -uo pipefail

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${1:-${RAIZ}/build-local/cplcheck}" && cd "${1:-${RAIZ}/build-local/cplcheck}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
NP=${NP:-4}
FC=${FC:-mpif90}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
OBJS="coupler_utils.o coupler_constants.o coupler_config.o diag_bitsum.o mom6_supergrid.o
      nc_writer.o cap_common.o regrid_base.o regrid_esmf.o regrid_weights.o regrid_mpassit.o
      regrid_registry.o regrid_manager.o cpl_grids.o cpl_fields.o cpl_map.o cpl_check.o
      med_cap_types.o med_cap_netcdf.o med_cap_methods.o med_bulk_ncar.o med_diag.o
      med_ice.o med_ocean.o med_init.o med_flux.o med_export.o MED_cap.o"

echo "--- compilando a árvore de trabalho"
bash "${RAIZ}/tools/dev/compila-local.bash" -o "${SAIDA}/obj" > "${SAIDA}/compila.txt" \
  || { cat "${SAIDA}/compila.txt"; echo "ERRO: compilação" >&2; exit 2; }
( cd "${SAIDA}/obj" || exit 2
  # shellcheck disable=SC2086
  ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch -O2 -g -fcheck=all \
    -c "${RAIZ}/tests/cplcheck/test_cplcheck_driver.F90" -o test_cplcheck_driver.o &&
  # shellcheck disable=SC2086
  ${FC} -o test_cplcheck_driver test_cplcheck_driver.o ${OBJS} ${ELIB} $(nf-config --flibs) -fopenmp
) > "${SAIDA}/liga.txt" 2>&1 || { cat "${SAIDA}/liga.txt"; echo "ERRO: ligação" >&2; exit 2; }

# Configuração de produção: MONAN-A, MOM6, SIS2, contorno pelo mediador
cat > "${SAIDA}/nuopc.input" << 'EOF'
&nuopc_mode
  use_med_to_mpas = .true.
/
&nuopc_petlayout
  use_sis2_dynamic = .true.
/
EOF

falhas=0
confere() {   # confere CASO DIFERENCAS CAMPOS_OCN_MED
  local caso=$1 esperadas=$2 n_ocn_med=$3 dir="${SAIDA}/$1" rel
  rm -rf "${dir}" && mkdir -p "${dir}" && cp "${SAIDA}/nuopc.input" "${dir}/"
  echo "--- caso ${caso}"
  # shellcheck disable=SC2086
  if (cd "${dir}" && ${MPIRUN} -np "${NP}" "${SAIDA}/obj/test_cplcheck_driver" "${caso}" \
        > execucao.txt 2>&1); then
    if [[ ${caso} == mediador ]]; then
      echo "FALHOU  ${caso}: a inicialização devia parar depois da conferência"
      falhas=$((falhas + 1)); return
    fi
  elif [[ ${caso} != mediador ]] || ! grep -q 'TESTE: parada depois da conferencia' "${dir}"/PET0.teste; then
    echo "FALHOU  ${caso}: a execução terminou com erro (ver ${dir}/execucao.txt)"
    falhas=$((falhas + 1)); return
  fi
  rel="${SAIDA}/relatorio_${caso}.txt"
  grep -h 'CPL-REL:' "${dir}"/PET0.teste | sed 's/^.*CPL-REL:/CPL-REL:/' > "${rel}"
  local outros
  outros=$(cat "${dir}"/PET*.teste | grep -c 'CPL-REL:')
  if [[ ${outros} -ne $(wc -l < "${rel}") ]]; then
    echo "FALHOU  ${caso}: outros PETs também escreveram o relatório"
    falhas=$((falhas + 1))
  fi
  for par in 'MPAS -> MED: 13' 'MED -> MPAS: 7' 'MED -> OCN: 14' 'MED -> ICE: 16' \
             "OCN -> MED: ${n_ocn_med}" 'ICE -> MED: 6'; do
    if ! grep -q "conector ${par} campo(s)" "${rel}"; then
      echo "FALHOU  ${caso}: relatório sem 'conector ${par} campo(s)'"
      falhas=$((falhas + 1))
    fi
  done
  if grep -q "conferencia do mapa: ${esperadas} diferenca(s), 3 aviso(s)" "${rel}"; then
    echo "PASSOU  ${caso}: ${esperadas} diferença(s) e 3 avisos"
  else
    echo "FALHOU  ${caso}: esperado ${esperadas} diferença(s) e 3 avisos:"
    grep 'DIFERENCA\|conferencia' "${rel}"
    falhas=$((falhas + 1))
  fi
}

confere normal 0 4
confere defeito 4 3
confere mediador 0 4
if [[ ${falhas} -eq 0 ]]; then
  grep -q 'OCN importa So_teste, que nao tem origem' "${SAIDA}/relatorio_defeito.txt" \
    && grep -q 'So_omask chegando a MED' "${SAIDA}/relatorio_defeito.txt" \
    || { echo "FALHOU  defeito: diferenças diferentes das plantadas"; falhas=1; }
fi

if [[ ${falhas} -eq 0 ]]; then
  echo "RESULTADO: conferência do mapa no driver como esperado"
  exit 0
fi
echo "RESULTADO: ${falhas} falha(s); relatórios em ${SAIDA}"
exit 1
