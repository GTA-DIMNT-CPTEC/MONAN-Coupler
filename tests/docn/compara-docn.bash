#!/usr/bin/env bash
# =============================================================================
# compara-docn.bash: teste de regressão do oceano de dados (DOCN).
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# A rodada da linha de base não usa o DOCN. Este teste o executa num driver
# NUOPC mínimo (tests/docn/test_docn.F90), com arquivos sintéticos de SST,
# gelo em porcentagem e correntes com pontos de preenchimento
# (tests/docn/gera-dados-docn.py), e compara a versão de um commit com a da
# árvore de trabalho.
#
# Casos (cada um em 4 processos MPI):
#   com_correntes  inicio    só a inicialização (valores iniciais e carimbo)
#   com_correntes  completo  4 passos de 9 h, com diagnóstico docn_import_*
#   sem_correntes  inicio    idem, sem arquivo de correntes
#   sem_correntes  completo
# Em cada caso têm de ser idênticos, bit a bit: os campos exportados pelo
# DOCN em cada PET, com os carimbos de tempo (saida_*.bin); os arquivos de
# diagnóstico; e as mensagens do DOCN no log do ESMF, sem data e hora.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/docn/compara-docn.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase9-07-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/docn)
#
# Variáveis: MPIRUN (padrão: mpiexec), NP (padrão: 4), FC (padrão: mpif90).
# Ambiente: ESMF, NetCDF-Fortran (nf-config), MPI, python3 e ncgen.
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,29p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/docn}" && cd "${2:-${RAIZ}/build-local/docn}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
NP=${NP:-4}
FC=${FC:-mpif90}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
OBJS="coupler_utils.o coupler_constants.o coupler_config.o nc_writer.o cap_common.o
      regrid_base.o cpl_fields.o cpl_map.o docn_cap_netcdf.o DOCN_cap.o"
objs_presentes() { local o; for o in ${OBJS}; do [[ -f ${o} ]] && printf '%s ' "${o}"; done; }

# Dados sintéticos, os mesmos para as duas versões
python3 "${RAIZ}/tests/docn/gera-dados-docn.py" "${SAIDA}/dados" \
  || { echo "ERRO: geração dos dados sintéticos" >&2; exit 2; }

# nuopc.input de cada cenário (só o grupo &nuopc_docn)
cenario() {   # cenario NOME COM_CORRENTES
  local arq="${SAIDA}/nuopc_$1.input"
  {
    echo "&nuopc_docn"
    echo "  docn_nx = 72, docn_ny = 36, docn_dt_data = 86400,"
    echo "  docn_epoch_year = 2026, docn_epoch_month = 3, docn_epoch_day = 25,"
    echo "  docn_sst_file = '${SAIDA}/dados/sst.nc', docn_sst_varname = 'sst',"
    echo "  docn_ice_file = '${SAIDA}/dados/ice.nc', docn_ice_varname = 'icec', docn_ice_pct = .true.,"
    [[ $2 == sim ]] && echo "  docn_cur_file = '${SAIDA}/dados/cur.nc',"
    echo "  write_import_diag = .true., import_diag_dir = 'diag_import'"
    echo "/"
  } > "${arq}"
}
cenario com_correntes sim
cenario sem_correntes nao

# Fontes da versão de referência, extraídos do git; o programa de teste é
# sempre o da árvore de trabalho (a interface do DOCN com o driver é o NUOPC)
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src tests/interfaces tools/dev/compila-local.bash \
  | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  ausente=""; [[ ${versao} == antiga ]] && ausente="-a"
  echo "--- versão ${versao}: compilando"
  # shellcheck disable=SC2086
  bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" ${ausente} > "${SAIDA}/compila_${versao}.txt" \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  # shellcheck disable=SC2086,SC2046
  ( cd "${dir}" || exit 2
    ${FC} ${EINC} -I. -ffree-line-length-none -fallow-argument-mismatch -fopenmp \
      -O2 -ffp-contract=off -c "${RAIZ}/tests/docn/test_docn.F90" -o test_docn.o &&
    ${FC} -o test_docn test_docn.o $(objs_presentes) ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  for c in com_correntes sem_correntes; do
    for modo in inicio completo; do
      run="${dir}/run_${c}_${modo}"
      rm -rf "${run}"; mkdir -p "${run}/diag_import"
      cp "${SAIDA}/nuopc_${c}.input" "${run}/nuopc.input"
      echo "--- versão ${versao}: ${c} ${modo}"
      arg=""; [[ ${modo} == inicio ]] && arg="inicio"
      # shellcheck disable=SC2086
      ( cd "${run}" && timeout 300 ${MPIRUN} -n "${NP}" ../test_docn ${arg} > run.log 2>&1 ) \
        || { tail -20 "${run}/run.log"; echo "ERRO: execução ${versao} ${c} ${modo}" >&2; exit 2; }
    done
  done
done

difere=0
for c in com_correntes sem_correntes; do
  for modo in inicio completo; do
    a="${SAIDA}/antiga/run_${c}_${modo}"; n="${SAIDA}/nova/run_${c}_${modo}"
    echo "== ${c} ${modo}"
    nbin=0
    for f in $(cd "${a}" && ls saida_*.bin diag_import/*.nc 2> /dev/null); do
      [[ ${f} == saida_* ]] && nbin=$((nbin + 1))
      if cmp -s "${a}/${f}" "${n}/${f}"; then echo "  igual (bytes)  ${f}"; else echo "  DIFERE         ${f}"; difere=1; fi
    done
    [[ ${nbin} -eq ${NP} ]] || { echo "ERRO: esperados ${NP} arquivos saida_*.bin em ${a}" >&2; exit 2; }
    if [[ ${modo} == completo ]]; then
      ndiag=$(find "${a}/diag_import" -type f | wc -l)
      [[ ${ndiag} -gt 0 ]] || { echo "ERRO: nenhum diagnóstico gravado em ${a}/diag_import" >&2; exit 2; }
      [[ $(find "${n}/diag_import" -type f | wc -l) -eq ${ndiag} ]] || { echo "  DIFERE         número de diagnósticos"; difere=1; }
    fi
    for pet in "${a}"/PET*.teste; do
      nome=$(basename "${pet}")
      if diff -q <(grep -E 'DOCN|ERROR|WARNING' "${pet}" | cut -d' ' -f3-) \
                 <(grep -E 'DOCN|ERROR|WARNING' "${n}/${nome}" | cut -d' ' -f3-) > /dev/null; then
        echo "  log igual      ${nome} ($(grep -cE 'DOCN|ERROR|WARNING' "${pet}") linhas)"
      else
        echo "  log DIFERE     ${nome}"; difere=1
      fi
    done
  done
done
if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: DOCN idêntico"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
