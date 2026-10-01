#!/bin/bash
# valida_rodada.bash: prepara, submete e compara uma rodada de validação
# da refatoração contra uma linha de base, sem copiar e colar comandos.
#
# Uso (de qualquer pasta):
#   bash tools/dev/valida_rodada.bash prepara NOME   # confere ambiente e executável; cria exp/NOME
#   bash tools/dev/valida_rodada.bash submete NOME   # --check e submissão (152 PETs)
#   bash tools/dev/valida_rodada.bash compara NOME   # compara com a linha de base
#
# O compara também extrai do log do PET 0 o relatório de acoplamento (linhas
# CPL-REL:, sem data e hora) para exp/NOME/relatorio_acoplamento.txt e o
# compara com o da rodada aprovada (PASS) mais recente, ou com o de REL_REF.
# Uma diferença no relatório não reprova a rodada, mas aponta o que mudou no
# acoplamento antes da comparação dos arquivos.
#
# Variáveis (valores padrão entre parênteses):
#   REF      pasta com baseline/, exp/ e o experimento modelo
#            (a pasta que contém Coupler-Install/)
#   MODELO   experimento com as entradas ($REF/exp_monan2xmom6)
#   BASE     linha de base de referência (R-NOFMA-02)
#   NPES     número de processos (152)
#   REL_REF  rodada cujo relatório de acoplamento serve de referência
#            (a aprovada mais recente)
# Os diretórios de rodada ficam em $REF/exp/NOME.
set -u
COUPLER_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REF=${REF:-$(cd "${COUPLER_ROOT}/../.." && pwd)}
MODELO=${MODELO:-${REF}/exp_monan2xmom6}
BASE=${BASE:-R-NOFMA-02}
BASEL=${REF}/baseline/${BASE}
NPES=${NPES:-152}
export COUPLER_ROOT

acao=${1:-}; nome=${2:-}
[[ -n "${acao}" && -n "${nome}" ]] || { sed -n '2,24p' "$0"; exit 2; }
DIR=${REF}/exp/${nome}

falha() { echo "ERRO: $*" >&2; exit 1; }

# relatorio DIR: extrai as linhas CPL-REL: dos logs do ESMF de uma rodada
# para DIR/relatorio_acoplamento.txt (sem data, hora e PET). Falha se a
# rodada não tem logs.
relatorio() {
  local d=$1
  compgen -G "${d}/logs/PET*.esmApp.log" > /dev/null || return 1
  grep -h 'CPL-REL:' "${d}"/logs/PET*.esmApp.log | sed 's/^.*CPL-REL: //' \
    > "${d}/relatorio_acoplamento.txt"
}

# referencia_relatorio: diretório da rodada de referência do relatório, ou
# vazio. REL_REF, se definida; senão a rodada aprovada (PASS no compara.txt)
# mais recente, fora a atual, que tenha relatório não vazio.
referencia_relatorio() {
  local c d
  if [[ -n "${REL_REF:-}" ]]; then
    d=${REF}/exp/${REL_REF}
    [[ -s "${d}/relatorio_acoplamento.txt" ]] || relatorio "${d}"
    [[ -s "${d}/relatorio_acoplamento.txt" ]] && echo "${d}"
    return
  fi
  for c in $(ls -t "${REF}"/exp/*/compara.txt 2>/dev/null); do
    d=$(dirname "${c}")
    [[ "${d}" == "${DIR}" ]] && continue
    grep -q ' PASS ' "${c}" || continue
    [[ -s "${d}/relatorio_acoplamento.txt" ]] || relatorio "${d}"
    if [[ -s "${d}/relatorio_acoplamento.txt" ]]; then echo "${d}"; return; fi
  done
}

# compara_relatorio: relatório desta rodada contra o da referência; só informa.
compara_relatorio() {
  local ref n
  if ! relatorio "${DIR}"; then
    echo " Relatório de acoplamento: rodada sem logs/PET*.esmApp.log"
    return
  fi
  n=$(wc -l < "${DIR}/relatorio_acoplamento.txt")
  echo " Relatório de acoplamento: ${n} linha(s) em relatorio_acoplamento.txt"
  ref=$(referencia_relatorio)
  if [[ -z "${ref}" ]]; then
    echo "   sem rodada aprovada com relatório para comparar"
    return
  fi
  if diff -q "${ref}/relatorio_acoplamento.txt" "${DIR}/relatorio_acoplamento.txt" > /dev/null; then
    echo "   igual ao da rodada $(basename "${ref}")"
    rm -f "${DIR}/relatorio_acoplamento.diff"
  else
    diff "${ref}/relatorio_acoplamento.txt" "${DIR}/relatorio_acoplamento.txt" \
      > "${DIR}/relatorio_acoplamento.diff"
    echo "   DIFERE do da rodada $(basename "${ref}"): $(grep -c '^<' "${DIR}/relatorio_acoplamento.diff")" \
         "linha(s) só lá, $(grep -c '^>' "${DIR}/relatorio_acoplamento.diff") só aqui" \
         "(relatorio_acoplamento.diff); primeiras diferenças:"
    grep '^[<>]' "${DIR}/relatorio_acoplamento.diff" | head -10 | sed 's/^/     /'
  fi
}

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
  compara_relatorio
  bash -c "source ${COUPLER_ROOT}/tools/dev/set-nccmp-jaci.bash >/dev/null 2>&1 && \
           bash ${COUPLER_ROOT}/tools/dev/compara-linha-base.bash -l ${BASE} -o ${REF}/baseline -e" \
    > compara.txt 2>&1
  rc_cmp=$?
  # Código 2: a comparação nem começou (linha de base que não confere com o
  # SHA256SUMS, nccmp ausente, base inexistente). Não é FAIL do código.
  if [[ ${rc_cmp} -eq 2 ]]; then
    echo
    echo " COMPARAÇÃO NÃO FEITA: o compara-linha-base.bash parou antes de comparar."
    echo " O resultado desta rodada ainda não foi avaliado; não é FAIL do código."
    sed -n '/ERRO/,$p' compara.txt | sed 's/^/ /'
    if grep -q 'MANIFEST.txt: FAILED' compara.txt \
       && [[ $(grep -c ': FAILED' compara.txt) -eq 1 ]]; then
      echo
      echo " Só o MANIFEST.txt da linha de base mudou. Se foi uma anotação feita à mão,"
      echo " registre a soma nova e compare de novo:"
      echo "   bash ${COUPLER_ROOT}/tools/dev/anota-linha-base.bash -o ${REF}/baseline -l ${BASE} -r"
      echo "   bash ${COUPLER_ROOT}/tools/dev/valida_rodada.bash compara ${nome}"
    fi
    echo " Relatório completo: ${DIR}/compara.txt"
    exit 2
  fi
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
  exit "${rc_cmp}"
  ;;
*) sed -n '2,24p' "$0"; exit 2 ;;
esac
