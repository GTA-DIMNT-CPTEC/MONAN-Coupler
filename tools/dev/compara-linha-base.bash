#!/usr/bin/env bash
# =============================================================================
# compara-linha-base.bash — compara a rodada atual com uma linha de base
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compara os NetCDF do diretório de experimento atual com os congelados em
# baseline/<rótulo>/saida/ e imprime um veredito PASS ou FAIL.
#
# Por que nao usar 'cmp' direto nos arquivos: os NetCDF gravados pelo acoplador
# carregam atributos globais com data e hora de criação. Duas execuções
# idênticas produzem arquivos com bytes diferentes no cabeçalho, embora com
# dados iguais. A comparação correta é sobre os DADOS, com nccmp -d.
#
# Uso:
#   compara-linha-base.bash -l L-01
#   compara-linha-base.bash -l L-01 -t 1e-12      # tolerância relativa
#   compara-linha-base.bash -l L-01 -o baseline_arquivada
#
# Códigos de saída:
#   0  PASS  — todos os arquivos batem
#   1  FAIL  — houve diferença de dados
#   2  erro de uso ou pré-condição
# =============================================================================

set -uo pipefail

ROTULO=""
BASE_DIR="baseline"
TOLERANCIA=""      # vazio = exigir identidade exata dos dados

_uso() {
  cat << 'EOF'

compara-linha-base.bash — compara a rodada atual com uma linha de base

  -l RÓTULO      obrigatório. Ex.: L-01
  -o DIRETÓRIO   raiz das linhas de base (padrão: ./baseline)
  -t VALOR       tolerância relativa (ex.: 1e-12). Sem -t, exige
                 identidade exata dos dados, que é o critério das
                 etapas de refatoração.
  -h             esta mensagem

EOF
}

while getopts ":l:o:t:h" opt; do
  case "${opt}" in
    l) ROTULO="${OPTARG}" ;;
    o) BASE_DIR="${OPTARG}" ;;
    t) TOLERANCIA="${OPTARG}" ;;
    h) _uso; exit 0 ;;
    \?) echo "ERRO: opção inválida: -${OPTARG}" >&2; _uso; exit 2 ;;
    :)  echo "ERRO: a opção -${OPTARG} exige argumento" >&2; exit 2 ;;
  esac
done

[[ -z "${ROTULO}" ]] && { echo "ERRO: informe o rótulo com -l" >&2; _uso; exit 2; }

REF="${BASE_DIR}/${ROTULO}/saida"
[[ -d "${REF}" ]] || { echo "ERRO: linha de base não encontrada: ${REF}" >&2; exit 2; }

command -v nccmp >/dev/null 2>&1 || {
  echo "ERRO: nccmp não está no PATH." >&2
  echo "      Carregue o módulo correspondente ou instale o pacote nccmp." >&2
  exit 2
}

# nccmp -d compara dados; -m compara metadados de variável; -f segue até o fim
# em vez de parar na primeira diferença, o que dá um relatório mais útil.
NCCMP_OPTS=(-d -m -f)
[[ -n "${TOLERANCIA}" ]] && NCCMP_OPTS+=(-T "${TOLERANCIA}")

echo "==============================================================="
echo " Comparação com a linha de base ${ROTULO}"
echo "==============================================================="
echo " Referência : ${REF}"
echo " Atual      : $(pwd)"
if [[ -n "${TOLERANCIA}" ]]; then
  echo " Critério   : diferença relativa até ${TOLERANCIA}"
  echo "              ATENÇÃO: as etapas de refatoração exigem identidade"
  echo "              exata. Tolerância só se aplica a etapas declaradas."
else
  echo " Critério   : identidade exata dos dados"
fi
echo "---------------------------------------------------------------"

n_ok=0; n_dif=0; n_faltando=0; n_extra=0

# ── Compara cada arquivo da referência com o correspondente atual ────────────
for ref_file in "${REF}"/*.nc; do
  [[ -e "${ref_file}" ]] || continue
  nome=$(basename "${ref_file}")

  # Localiza o arquivo correspondente no experimento atual.
  atual=""
  for cand in "diag_export/${nome}" "diag_import/${nome}" "${nome}"; do
    [[ -f "${cand}" ]] && { atual="${cand}"; break; }
  done

  if [[ -z "${atual}" ]]; then
    printf '  %-42s  %s\n' "${nome}" "AUSENTE na rodada atual"
    n_faltando=$(( n_faltando + 1 ))
    continue
  fi

  saida=$(nccmp "${NCCMP_OPTS[@]}" "${ref_file}" "${atual}" 2>&1)
  if [[ $? -eq 0 && -z "${saida}" ]]; then
    printf '  %-42s  %s\n' "${nome}" "igual"
    n_ok=$(( n_ok + 1 ))
  else
    printf '  %-42s  %s\n' "${nome}" "DIFERE"
    echo "${saida}" | head -8 | sed 's/^/        /'
    n_dif=$(( n_dif + 1 ))
  fi
done

# ── Arquivos novos, que a linha de base não tem ──────────────────────────────
for atual in diag_export/*.nc diag_import/*.nc; do
  [[ -e "${atual}" ]] || continue
  nome=$(basename "${atual}")
  [[ -f "${REF}/${nome}" ]] && continue
  printf '  %-42s  %s\n' "${nome}" "EXTRA (não existe na linha de base)"
  n_extra=$(( n_extra + 1 ))
done

# ── Veredito ─────────────────────────────────────────────────────────────────
echo "---------------------------------------------------------------"
printf ' iguais: %d   diferentes: %d   ausentes: %d   extras: %d\n' \
  "${n_ok}" "${n_dif}" "${n_faltando}" "${n_extra}"
echo "==============================================================="

if [[ "${n_dif}" -eq 0 && "${n_faltando}" -eq 0 && "${n_extra}" -eq 0 && "${n_ok}" -gt 0 ]]; then
  echo " PASS — a rodada atual reproduz a linha de base ${ROTULO}"
  echo "==============================================================="
  exit 0
fi

echo " FAIL — a rodada atual NÃO reproduz a linha de base ${ROTULO}"
echo ""
echo " Antes de investigar o código, descarte as causas triviais:"
echo "   1. O número de PETs é o mesmo do MANIFEST?"
echo "   2. O nuopc.input é o mesmo de baseline/${ROTULO}/config/?"
echo "      diff nuopc.input ${BASE_DIR}/${ROTULO}/config/nuopc.input"
echo "   3. Os arquivos de entrada têm a mesma soma de verificação?"
echo "      ver ${BASE_DIR}/${ROTULO}/entrada/CHECKSUMS.txt"
echo "   4. Os módulos carregados são os mesmos do MANIFEST?"
echo ""
echo " Só depois disso a diferença é atribuível à alteração de código."
echo "==============================================================="
exit 1
