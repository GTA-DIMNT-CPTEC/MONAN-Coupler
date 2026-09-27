#!/bin/bash
# valida_rodada.bash: prepara, submete e compara uma rodada de validação
# da refatoração contra uma linha de base, sem copiar e colar comandos.
#
# Uso (de qualquer pasta):
#   bash tools/dev/valida_rodada.bash prepara NOME   # confere ambiente e executável; cria exp/NOME
#   bash tools/dev/valida_rodada.bash submete NOME   # --check e submissão (152 PETs)
#   bash tools/dev/valida_rodada.bash compara NOME   # compara com a linha de base
#
# Variáveis (valores padrão entre parênteses):
#   REF      pasta com baseline/, exp/ e o experimento modelo
#            (a pasta que contém Coupler-Install/)
#   MODELO   experimento com as entradas ($REF/exp_monan2xmom6)
#   BASE     linha de base de referência (R-NOFMA-01)
#   NPES     número de processos (152)
# Os diretórios de rodada ficam em $REF/exp/NOME.
set -u
COUPLER_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REF=${REF:-$(cd "${COUPLER_ROOT}/../.." && pwd)}
MODELO=${MODELO:-${REF}/exp_monan2xmom6}
BASE=${BASE:-R-NOFMA-01}
BASEL=${REF}/baseline/${BASE}
NPES=${NPES:-152}
export COUPLER_ROOT

acao=${1:-}; nome=${2:-}
[[ -n "${acao}" && -n "${nome}" ]] || { sed -n '2,16p' "$0"; exit 2; }
DIR=${REF}/exp/${nome}

falha() { echo "ERRO: $*" >&2; exit 1; }

case "${acao}" in
prepara)
  [[ -e "${DIR}" ]] && falha "${DIR} já existe; escolha outro nome"
  [[ -x "${COUPLER_ROOT}/bin/esmApp" ]] || falha "bin/esmApp não existe; compile antes"
  # O executável não pode conter bibliotecas de outra instalação: com -g,
  # os caminhos dos fontes das bibliotecas ficam gravados no binário.
  minha=$(cd "${COUPLER_ROOT}/.." && pwd)
  outros=$(strings -a "${COUPLER_ROOT}/bin/esmApp" | grep -oE '/[^[:space:]"]*/Coupler-Install' \
           | sort -u | grep -vxF "${minha}")
  if [[ -n "${outros}" ]]; then
    echo "ERRO: bin/esmApp contém código de outra instalação:" >&2
    echo "${outros}" | sed 's/^/       /' >&2
    echo "       Recompile numa sessão nova, com COUPLER_ROOT definido antes do setenv:" >&2
    echo "       export COUPLER_ROOT=${COUPLER_ROOT}" >&2
    echo "       cd \$COUPLER_ROOT && source run/setenv-gnu.bash && make clean && make" >&2
    exit 1
  fi
  echo "Executável: ${COUPLER_ROOT}/bin/esmApp ($(date -r "${COUPLER_ROOT}/bin/esmApp" '+%Y-%m-%d %H:%M'))"
  echo "Revisão   : $(git -C "${COUPLER_ROOT}" log --oneline -1 | cat)"
  mkdir -p "${DIR}" || falha "não foi possível criar ${DIR}"
  rsync -a \
    --exclude='diag_export/' --exclude='diag_import/' --exclude='diag_import-original/' \
    --exclude='logs/' --exclude='logs-antigos/' --exclude='INPUT_OLD_OK/' --exclude='RESTART/*' \
    --exclude='reprodiag.nc' --exclude='MONAN_DIAG_*.nc' --exclude='log.atmosphere.*' \
    --exclude='logfile.*' --exclude='ocean.stats*' --exclude='seaice.stats' \
    --exclude='ocean_month.nc' --exclude='ice.nc' --exclude='sea_ice_geometry.nc' \
    --exclude='*available_diags*' --exclude='*_parameter_doc.*' --exclude='done' --exclude='*.pbs' \
    --exclude='MOM_input_*' --exclude='diag_table_orig' --exclude='streams.atmosphere.original' \
    --exclude='compara*.txt' \
    "${MODELO}/" "${DIR}/" || falha "rsync falhou"
  cp "${BASEL}/config/nuopc.input" "${DIR}/" || falha "cópia do nuopc.input falhou"
  echo "Diretório pronto: ${DIR}"
  echo "Próximo passo   : bash $0 submete ${nome}"
  ;;
submete)
  [[ -d "${DIR}" ]] || falha "${DIR} não existe; rode antes: bash $0 prepara ${nome}"
  cd "${DIR}" || exit 1
  bash "${COUPLER_ROOT}/run/run_esmApp.jaci" -n "${NPES}" --check || falha "--check falhou"
  bash "${COUPLER_ROOT}/run/run_esmApp.jaci" -n "${NPES}" -w 01:00:00
  echo "Próximo passo: bash $0 compara ${nome}"
  ;;
compara)
  cd "${DIR}" || falha "${DIR} não existe"
  grep -q 'SIMULACAO CONCLUIDA COM SUCESSO' logs/esmApp_run.log 2>/dev/null \
    || falha "a rodada em ${DIR} não terminou com sucesso"
  grep -m1 'Iniciando'  logs/esmApp_run.log
  grep -m1 'Executável' logs/esmApp_run.log
  grep -m1 -i 'revis'   logs/esmApp_run.log
  bash -c "source ${COUPLER_ROOT}/tools/dev/set-nccmp-jaci.bash >/dev/null 2>&1 && \
           bash ${COUPLER_ROOT}/tools/dev/compara-linha-base.bash -l ${BASE} -o ${REF}/baseline -e" \
    > compara.txt 2>&1
  grep -E 'Entradas|entradas diferentes' compara.txt
  grep -E '^ *iguais:' compara.txt
  n_meta=$(grep -c 'difere so nos METADADOS' compara.txt)
  if [[ ${n_meta} -gt 0 ]]; then
    echo " Arquivos só com metadados diferentes (dados iguais): ${n_meta}; por prefixo:"
    grep 'difere so nos METADADOS' compara.txt | awk '{print $1}' | sed -E 's/_[0-9]{8}_[0-9]{6}\.nc$//' \
      | sort | uniq -c | sed 's/^/   /'
  fi
  if grep -q ' PASS ' compara.txt; then
    grep ' PASS ' compara.txt
  else
    grep -E ' FAIL' compara.txt
    echo; echo "Primeiras diferenças:"; sed -n '/Integridade/,$p' compara.txt | head -30
  fi
  echo " Relatório completo: ${DIR}/compara.txt"
  ;;
*) sed -n '2,16p' "$0"; exit 2 ;;
esac
