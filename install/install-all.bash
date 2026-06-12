#!/bin/bash
# =============================================================================
# install-all.bash — Orquestra a instalação completa do acoplador
# MONAN-A 2.0 × MOM6+SIS2 (NUOPC/ESMF 8.9.1) executando as três etapas
# na ordem correta de dependência.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# USO (a partir de qualquer diretório):
#   bash install/install-all.bash [OPÇÕES]
#
# OPÇÕES:
#   --from N     Inicia a partir da etapa N (1-3). Útil para retomar após
#                uma falha parcial, assumindo que as etapas anteriores já
#                foram concluídas com sucesso.
#   --only N     Executa somente a etapa N (1, 2 ou 3).
#   --help       Exibe esta mensagem de ajuda e encerra.
#
# ETAPAS:
#   1  1-install-monan.bash    → libs MONAN-A   (lib/monan2/)
#   2  2-install-mom.bash      → libs MOM6+SIS2 (lib/{fms,mom6,nuopc}/)
#   3  3-install-coupler.bash  → linka bin/esmApp
#
# EXEMPLOS:
#   bash install/install-all.bash              → instalação completa (1-2-3)
#   bash install/install-all.bash --from 2     → pula MONAN-A; compila MOM6+acoplador
#   bash install/install-all.bash --only 3     → (re)linka somente bin/esmApp
# =============================================================================
set -euo pipefail

# ── Âncora determinística ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Carrega biblioteca de funções ─────────────────────────────────────────────
source "${SCRIPT_DIR}/install-libs.bash"

# ── Análise de opções ─────────────────────────────────────────────────────────
FROM_STEP=1
ONLY_STEP=0   # 0 = executar todas a partir de FROM_STEP

_uso() {
  sed -n '2,/^# USO/p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ $# -lt 2 ]] && { log_error "--from exige um número (1-3)"; exit 1; }
      FROM_STEP="$2"; shift 2
      ;;
    --only)
      [[ $# -lt 2 ]] && { log_error "--only exige um número (1-3)"; exit 1; }
      ONLY_STEP="$2"; FROM_STEP="$2"; shift 2
      ;;
    --help|-h)
      _uso
      ;;
    *)
      log_error "Opção desconhecida: $1   (use --help para a lista de opções)"
      exit 1
      ;;
  esac
done

# Validações
if ! [[ "${FROM_STEP}" =~ ^[1-3]$ ]]; then
  log_error "--from: valor inválido '${FROM_STEP}' (use 1, 2 ou 3)"
  exit 1
fi
if [[ "${ONLY_STEP}" != 0 ]] && ! [[ "${ONLY_STEP}" =~ ^[1-3]$ ]]; then
  log_error "--only: valor inválido '${ONLY_STEP}' (use 1, 2 ou 3)"
  exit 1
fi

# ── Definição das etapas ──────────────────────────────────────────────────────
declare -a STEP_SCRIPTS=(
  ""                          # índice 0 (não usado)
  "1-install-monan.bash"
  "2-install-mom.bash"
  "3-install-coupler.bash"
)
declare -a STEP_LABELS=(
  ""
  "MONAN-A 2.0 (MPAS-A 8.3.1)"
  "MOM6+SIS2 + FMS + cap NUOPC"
  "Acoplador (bin/esmApp)"
)

TOTAL_STEPS=3

# ── Pré-checagem: todos os scripts existem antes de iniciar ───────────────────
for i in 1 2 3; do
  s="${SCRIPT_DIR}/${STEP_SCRIPTS[$i]}"
  if [[ ! -f "${s}" ]]; then
    log_error "Script de etapa não encontrado: ${s}"
    exit 1
  fi
done

# ── Execução sequencial ───────────────────────────────────────────────────────
log_sep
log_info "Instalação do acoplador MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1"
log_info "INPE / CGCT / DIMNT — GT Acoplamento de Modelos"
log_sep

if [[ "${ONLY_STEP}" != 0 ]]; then
  log_info "Modo: somente etapa ${ONLY_STEP} (${STEP_LABELS[$ONLY_STEP]})"
elif [[ "${FROM_STEP}" -gt 1 ]]; then
  log_info "Modo: a partir da etapa ${FROM_STEP} (${STEP_LABELS[$FROM_STEP]})"
else
  log_info "Modo: instalação completa (etapas 1 → ${TOTAL_STEPS})"
fi

timer_start

declare -a STEP_TIMES=()   # tempos por etapa (para o resumo)

for i in 1 2 3; do
  # Determina se esta etapa deve ser executada
  if [[ "${ONLY_STEP}" != 0 ]] && [[ "${i}" != "${ONLY_STEP}" ]]; then
    continue
  fi
  if [[ "${i}" -lt "${FROM_STEP}" ]]; then
    continue
  fi

  _t_start=${SECONDS}
  log_step "${i}" "${TOTAL_STEPS}" "${STEP_LABELS[$i]}"
  bash "${SCRIPT_DIR}/${STEP_SCRIPTS[$i]}"
  _t_elapsed=$(( SECONDS - _t_start ))
  STEP_TIMES[$i]=${_t_elapsed}
done

# ── Resumo final ──────────────────────────────────────────────────────────────
log_sep
echo ""
timer_total "Instalação concluída em"
echo ""

for i in 1 2 3; do
  if [[ -n "${STEP_TIMES[$i]:-}" ]]; then
    _m=$(( STEP_TIMES[$i] / 60 )) _s=$(( STEP_TIMES[$i] % 60 ))
    (( _m > 0 )) \
      && log_ok "Etapa ${i} — ${STEP_LABELS[$i]}: ${_m}min ${_s}s" \
      || log_ok "Etapa ${i} — ${STEP_LABELS[$i]}: ${_s}s"
  fi
done

echo ""
log_info "Próximo passo: bash run/run_esmApp.jaci -n 128"
log_sep
