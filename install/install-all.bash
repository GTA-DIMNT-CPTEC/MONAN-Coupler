#!/bin/bash
# =============================================================================
# install-all.bash — Orquestra as três etapas de instalação na ordem de
# dependência. INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# USO:
#   bash install/install-all.bash [--from N] [--only N] [--help]
#     --from N   Inicia a partir da etapa N (1-3), assumindo as anteriores OK.
#     --only N   Executa somente a etapa N.
#
# Etapas: 1 MONAN-A → 2 MOM6+SIS2+cap NUOPC → 3 acoplador (bin/esmApp)
#
# Exemplos:
#   bash install/install-all.bash            # completa (1-2-3)
#   bash install/install-all.bash --from 2   # pula MONAN-A
#   bash install/install-all.bash --only 3   # (re)linka bin/esmApp
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/install-libs.bash"

# ── Opções ────────────────────────────────────────────────────────────────────
FROM_STEP=1
ONLY_STEP=0   # 0 = todas a partir de FROM_STEP
_uso() { sed -n '2,/^# USO/p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -lt 2 ]] && { log_error "--from exige um número (1-3)"; exit 1; }
            FROM_STEP="$2"; shift 2 ;;
    --only) [[ $# -lt 2 ]] && { log_error "--only exige um número (1-3)"; exit 1; }
            ONLY_STEP="$2"; FROM_STEP="$2"; shift 2 ;;
    --help|-h) _uso ;;
    *) log_error "Opção desconhecida: $1   (use --help)"; exit 1 ;;
  esac
done

if ! [[ "${FROM_STEP}" =~ ^[1-3]$ ]]; then
  log_error "--from: valor inválido '${FROM_STEP}' (use 1, 2 ou 3)"; exit 1
fi
if [[ "${ONLY_STEP}" != 0 ]] && ! [[ "${ONLY_STEP}" =~ ^[1-3]$ ]]; then
  log_error "--only: valor inválido '${ONLY_STEP}' (use 1, 2 ou 3)"; exit 1
fi

# ── Etapas ────────────────────────────────────────────────────────────────────
declare -a STEP_SCRIPTS=( "" "1-install-monan.bash" "2-install-mom.bash" "3-install-coupler.bash" )
declare -a STEP_LABELS=( "" "MONAN-A 2.0 (MPAS-A 8.3.1)" "MOM6+SIS2 + FMS + cap NUOPC" "Acoplador (bin/esmApp)" )
TOTAL_STEPS=3

for i in 1 2 3; do
  s="${SCRIPT_DIR}/${STEP_SCRIPTS[$i]}"
  if [[ ! -f "${s}" ]]; then
    log_error "Script de etapa não encontrado: ${s}"; exit 1
  fi
done

# ── Execução ──────────────────────────────────────────────────────────────────
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
declare -a STEP_TIMES=()

for i in 1 2 3; do
  [[ "${ONLY_STEP}" != 0 && "${i}" != "${ONLY_STEP}" ]] && continue
  [[ "${i}" -lt "${FROM_STEP}" ]] && continue

  _t_start=${SECONDS}
  log_step "${i}" "${TOTAL_STEPS}" "${STEP_LABELS[$i]}"
  bash "${SCRIPT_DIR}/${STEP_SCRIPTS[$i]}"
  STEP_TIMES[$i]=$(( SECONDS - _t_start ))
done

# ── Resumo ────────────────────────────────────────────────────────────────────
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
