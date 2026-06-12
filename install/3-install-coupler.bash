#!/bin/bash
# =============================================================================
# 3-install-coupler.bash — Compila e linka o acoplador MONAN-A 2.0 × MOM6+SIS2
# no executável final bin/esmApp (NUOPC/ESMF 8.9.1).
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# É a 3ª e última etapa de instalação. Pré-requisitos já compilados:
#   1-install-monan.bash → libs MONAN-A em lib/monan2/
#   2-install-mom.bash   → libs MOM6+SIS2 em lib/{fms,mom6,nuopc}/
#
# USO (a partir de qualquer diretório):
#   bash install/3-install-coupler.bash [OPÇÕES]
#
# OPÇÕES:
#   --no-clean   Pula o 'make clean'. Útil para recompilação incremental
#                quando somente fontes do acoplador mudaram.
#   --help       Exibe esta mensagem de ajuda e encerra.
#
# ATENÇÃO: sem --no-clean, o script executa 'make clean', que apaga build/ e
# bin/. NÃO usa 'make distclean': este removeria lib/ e mod/ — as bibliotecas
# instaladas pelas etapas 1 e 2, das quais o acoplador depende para linkar.
# =============================================================================
set -euo pipefail

# ── Âncora determinística ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUPLER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Carrega biblioteca de funções ─────────────────────────────────────────────
source "${SCRIPT_DIR}/install-libs.bash"

# ── Análise de opções ─────────────────────────────────────────────────────────
NO_CLEAN=false

_uso() {
  sed -n '2,/^# USO/p' "${BASH_SOURCE[0]}" | grep -E '^#' | sed 's/^# \{0,1\}//'
  exit 0
}

for _arg in "$@"; do
  case "${_arg}" in
    --no-clean)   NO_CLEAN=true  ;;
    --help|-h)    _uso ;;
    *)
      log_error "Opção desconhecida: ${_arg}   (use --help para a lista de opções)"
      exit 1
      ;;
  esac
done
unset _arg

# ── Carrega o ambiente de build (ESMF, MPAS, MOM6) ────────────────────────────
SETENV="${COUPLER_ROOT}/run/setenv-gnu.bash"

if [[ ! -f "${SETENV}" ]]; then
  log_error "Arquivo de ambiente não encontrado: ${SETENV}"
  exit 1
fi

# setenv-gnu.bash se ancora via BASH_SOURCE; o source independe do CWD.
source "${SETENV}"

# Verifica variáveis essenciais exportadas pelo setenv
if ! check_var ESMFMKFILE MPAS_DIR; then
  log_error "Ambiente incompleto após source de ${SETENV}"
  log_info  "ESMFMKFILE e MPAS_DIR precisam estar definidos."
  exit 1
fi

# ── Compilação ────────────────────────────────────────────────────────────────
cd "${COUPLER_ROOT}"
timer_start

if [[ "${NO_CLEAN}" == false ]]; then
  log_step 1 2 "Limpeza (make clean)"
  log_warn "build/ e bin/ serão removidos. Use --no-clean para pular."
  make clean
  log_ok "Limpeza concluída."
else
  log_warn "Limpeza ignorada (--no-clean). Build incremental."
fi

log_step 2 2 "Compilação do acoplador (make all)"
# Com 'set -o pipefail', o tee não mascara uma eventual falha do make.
make all 2>&1 | tee make-coupler.log

# ── Verificação e resumo ──────────────────────────────────────────────────────
log_sep
echo ""
if [[ -f "${COUPLER_ROOT}/bin/esmApp" ]]; then
  timer_total "Acoplador compilado em"
  echo ""
  _info=$(ls -lh "${COUPLER_ROOT}/bin/esmApp" | awk '{print $5, $6, $7, $8}')
  log_ok "bin/esmApp  [${_info}]"
  echo ""
  log_info "Próximo passo: bash run/run_esmApp.jaci -n 128"
else
  log_error "bin/esmApp não foi gerado — verifique make-coupler.log"
  exit 1
fi
log_sep
