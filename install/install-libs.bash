#!/bin/bash
# =============================================================================
# install-libs.bash — Biblioteca de funções compartilhadas
# MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
# Versão 1.2 — Junho 2026
#
# Deve ser carregada via 'source', nunca executada diretamente.
# Fornece: log colorizado, cronômetro, cópia segura de globs,
#          clone idempotente de repositórios git e verificação de
#          variáveis de ambiente obrigatórias.
#
# Uso nos instaladores (SCRIPT_DIR já definido):
#   source "${SCRIPT_DIR}/install-libs.bash"
# =============================================================================

# ── Guarda contra execução direta ─────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Erro: carregue com 'source install-libs.bash', não diretamente." >&2
  exit 1
fi

# ── Colorização ───────────────────────────────────────────────────────────────
# Ativada somente quando stdout é um terminal que suporta cores; caso
# contrário todas as variáveis ficam vazias (saída limpa em logs/arquivos).
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1; then
  _C_VD=$(tput setaf 2)    # verde   — OK / sucesso
  _C_AM=$(tput setaf 3)    # amarelo — aviso
  _C_VM=$(tput setaf 1)    # vermelho — erro
  _C_AZ=$(tput setaf 6)    # ciano   — informação
  _C_BD=$(tput bold)       # negrito — título de etapa
  _C_RS=$(tput sgr0)       # reset de atributos
else
  _C_VD="" ; _C_AM="" ; _C_VM="" ; _C_AZ="" ; _C_BD="" ; _C_RS=""
fi

# ── Funções de log padronizado ────────────────────────────────────────────────
#
#   log_info  "msg"       — informação geral (ciano)
#   log_ok    "msg"       — operação concluída com sucesso (verde)
#   log_warn  "msg"       — aviso não-fatal (amarelo, para stderr)
#   log_error "msg"       — erro fatal, antes de 'exit 1' (vermelho, stderr)
#   log_step  N T "desc"  — cabeçalho de etapa "==> [N/T] desc" (negrito)
#   log_sep               — separador visual ─────────────────
#
log_info()  { printf "${_C_AZ}  INFO  ${_C_RS}%s\n"   "$*"; }
log_ok()    { printf "${_C_VD}  OK    ${_C_RS}%s\n"   "$*"; }
log_warn()  { printf "${_C_AM}  AVISO ${_C_RS}%s\n"   "$*" >&2; }
log_error() { printf "${_C_VM}  ERRO  ${_C_RS}%s\n"   "$*" >&2; }
log_step()  { printf "\n${_C_BD}==> [%s/%s] %s${_C_RS}\n" "$1" "$2" "$3"; }
log_sep()   { printf "${_C_AZ}%s${_C_RS}\n" \
                "$(printf '─%.0s' $(seq 1 70))"; }

# ── Cronômetro (precisão: segundos) ───────────────────────────────────────────
#
#   timer_start            — marca o instante inicial (etapa e total)
#   timer_step  ["label"]  — exibe tempo desde o último timer_start/_step_reset
#                            e reinicia o cronômetro de etapa
#   timer_total ["label"]  — exibe tempo total desde timer_start
#
_TIMER_START=0
_TIMER_STEP=0

timer_start() {
  _TIMER_START=${SECONDS}
  _TIMER_STEP=${SECONDS}
}

timer_step() {
  local label="${1:-Etapa}"
  local elapsed=$(( SECONDS - _TIMER_STEP ))
  local m=$(( elapsed / 60 )) s=$(( elapsed % 60 ))
  if (( m > 0 )); then
    log_ok "${label}: ${m}min ${s}s"
  else
    log_ok "${label}: ${s}s"
  fi
  _TIMER_STEP=${SECONDS}   # reinicia cronômetro de etapa
}

timer_total() {
  local label="${1:-Tempo total}"
  local elapsed=$(( SECONDS - _TIMER_START ))
  local m=$(( elapsed / 60 )) s=$(( elapsed % 60 ))
  if (( m > 0 )); then
    log_ok "${label}: ${m}min ${s}s"
  else
    log_ok "${label}: ${s}s"
  fi
}

# ── cp_glob — cópia segura com glob, tolerante a diretórios vazios ────────────
#
# Uso: cp_glob <PADRÃO_GLOB> <DESTINO>
#
# Expande PADRÃO (ex.: "./src/core_atm/*.mod") e copia para DESTINO.
#   - Se nenhum arquivo casar: emite log_warn e retorna 0 (não aborta).
#   - Se a cópia falhar: retorna o código de saída do 'cp'.
#
cp_glob() {
  local pattern="$1" dest="$2"
  local -a files=()

  # nullglob: o glob literal não é passado ao cp quando não há correspondência
  shopt -s nullglob
  files=( ${pattern} )
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    log_warn "cp_glob: nenhum arquivo encontrado em: ${pattern}"
    return 0
  fi
  cp "${files[@]}" "${dest}"
}

# ── clone_if_missing — clona um repositório git se ele estiver ausente ou vazio ─
#
# Uso: clone_if_missing <DIR> <URL> [REF] [--recursive]
#
#   DIR          Diretório de destino. Se já existir E contiver arquivos, nada é
#                feito (idempotente). Se não existir ou estiver vazio, baixa.
#   URL          URL do repositório git.
#   REF          (opcional) tag ou branch para checkout após o clone.
#   --recursive  (opcional) clona também os submódulos (--recursive).
#
# A ordem de REF e --recursive é livre. Retorna 0 se o diretório já estava
# populado ou se o clone teve sucesso; retorna 1 se o git não estiver
# disponível ou falhar.
#
clone_if_missing() {
  local dir="$1" url="$2"
  shift 2

  local recursive=false ref=""
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --recursive) recursive=true ;;
      *)           ref="${arg}"   ;;
    esac
  done

  # Idempotência: só considera "já baixado" um diretório que exista E contenha
  # algo. Um diretório vazio (p.ex. resíduo de clone interrompido ou placeholder
  # de submódulo) é tratado como ausente, permitindo o download.
  if [[ -d "${dir}" ]] && \
     [[ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log_info "Repositório já presente (download ignorado): ${dir}"
    return 0
  fi
  if [[ -d "${dir}" ]]; then
    log_warn "Diretório existe porém vazio — prosseguindo com o download: ${dir}"
  fi

  if ! command -v git &>/dev/null; then
    log_error "git não encontrado no PATH — necessário para baixar ${url}"
    return 1
  fi

  log_info "Baixando ${url}"
  log_info "  → ${dir}"
  if [[ "${recursive}" == true ]]; then
    git clone --recursive "${url}" "${dir}" || return 1
  else
    git clone "${url}" "${dir}" || return 1
  fi

  if [[ -n "${ref}" ]]; then
    log_info "Checkout da referência: ${ref}"
    git -C "${dir}" checkout "${ref}" || return 1
    [[ "${recursive}" == true ]] && \
      git -C "${dir}" submodule update --init --recursive || true
  fi

  log_ok "Download concluído: ${dir}"
}

# ── check_var — verifica variáveis de ambiente obrigatórias ───────────────────
#
# Uso: check_var NOME_VAR1 NOME_VAR2 ...
# Emite log_error para cada variável vazia e retorna 1 se alguma falhar.
#
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
