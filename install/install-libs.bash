#!/bin/bash
# =============================================================================
# install-libs.bash — Funções compartilhadas dos instaladores
# MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1 — INPE / CGCT / DIMNT
#
# Carregue via 'source', nunca execute diretamente:
#   source "${SCRIPT_DIR}/install-libs.bash"
#
# Fornece: log colorizado, cronômetro, cópia segura de globs (cp_glob) e
# verificação de variáveis obrigatórias (check_var).
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Erro: carregue com 'source install-libs.bash', não diretamente." >&2
  exit 1
fi

# ── Cores (somente em terminal; vazias em log/arquivo) ────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1; then
  _C_VD=$(tput setaf 2) ; _C_AM=$(tput setaf 3) ; _C_VM=$(tput setaf 1)
  _C_AZ=$(tput setaf 6) ; _C_BD=$(tput bold)    ; _C_RS=$(tput sgr0)
else
  _C_VD="" ; _C_AM="" ; _C_VM="" ; _C_AZ="" ; _C_BD="" ; _C_RS=""
fi

# ── Log: info (ciano), ok (verde), warn/error (stderr), step, separador ───────
log_info()  { printf "${_C_AZ}  INFO  ${_C_RS}%s\n" "$*"; }
log_ok()    { printf "${_C_VD}  OK    ${_C_RS}%s\n" "$*"; }
log_warn()  { printf "${_C_AM}  AVISO ${_C_RS}%s\n" "$*" >&2; }
log_error() { printf "${_C_VM}  ERRO  ${_C_RS}%s\n" "$*" >&2; }
log_step()  { printf "\n${_C_BD}==> [%s/%s] %s${_C_RS}\n" "$1" "$2" "$3"; }
log_sep()   { printf "${_C_AZ}%s${_C_RS}\n" "$(printf '─%.0s' $(seq 1 70))"; }

# ── Cronômetro (segundos): timer_start, timer_step [label], timer_total [label]
_TIMER_START=0
_TIMER_STEP=0

_fmt_elapsed() {   # _fmt_elapsed SEGUNDOS LABEL — imprime "Nmin Ms" ou "Ms"
  local label="$2" m=$(( $1 / 60 )) s=$(( $1 % 60 ))
  (( m > 0 )) && log_ok "${label}: ${m}min ${s}s" || log_ok "${label}: ${s}s"
}

timer_start() { _TIMER_START=${SECONDS}; _TIMER_STEP=${SECONDS}; }
timer_step()  { _fmt_elapsed $(( SECONDS - _TIMER_STEP ))  "${1:-Etapa}"; _TIMER_STEP=${SECONDS}; }
timer_total() { _fmt_elapsed $(( SECONDS - _TIMER_START )) "${1:-Tempo total}"; }

# ── cp_glob PADRÃO DESTINO — copia o glob; warn e segue se não houver match ───
cp_glob() {
  local pattern="$1" dest="$2"
  local -a files=()
  shopt -s nullglob
  files=( ${pattern} )
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    log_warn "cp_glob: nenhum arquivo encontrado em: ${pattern}"
    return 0
  fi
  cp "${files[@]}" "${dest}"
}

# ── check_var VAR1 VAR2 ... — erro para cada variável vazia; retorna 1 se falhar
check_var() {
  local rc=0 v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      log_error "Variável obrigatória não definida: ${v}"
      rc=1
    fi
  done
  return ${rc}
}
