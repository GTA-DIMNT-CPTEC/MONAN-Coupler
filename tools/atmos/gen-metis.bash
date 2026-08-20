#!/usr/bin/env bash
# =============================================================================
# gen-metis.bash — Gera as partições METIS do MPAS (x1.NNNNN.graph.info.part.N)
#                  necessárias para uma rodada, lendo malha e modo da nuopc.input.
#
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos — v13.0
# Sistema acoplado MONAN-A 2.0 x MOM6+SIS2 / NUOPC-ESMF 8.9.1
#
# POR QUE ISTO É NECESSÁRIO
#   O MPAS decompõe a malha por METIS e lê o arquivo x1.NNNNN.graph.info.part.N,
#   onde N é o número de tarefas MPI NO COMUNICADOR DO MPAS — não o total do job.
#
#     • Modo SEQUENTIAL (todos os PETs no MPAS): N = NPES (o -n do run).
#     • Modo CONCURRENT (ATM num subconjunto):   N = atm_pet_count.
#
#   Atenção à pegadinha do modo concorrente: o run_esmApp.jaci faz o pré-check
#   com base no -n (pede .part.<NPES>), mas o MPAS em concurrent usa
#   .part.<atm_pet_count>. Por isso, em concurrent, este script gera OS DOIS:
#   .part.<NPES> (satisfaz o pré-check) e .part.<atm_pet_count> (usado de fato).
#   (O MOM6 NÃO usa METIS — decompõe a própria grade lógica por layout.)
#
# USO
#   # no diretório de experimento (onde está x1.NNNNN.graph.info e nuopc.input):
#   gen-metis.bash -n 8                 # deriva o que falta da nuopc.input
#   gen-metis.bash -n 8 --input nuopc.input
#   gen-metis.bash --parts "8 4 16"     # gera exatamente esses N
#   gen-metis.bash -n 8 --dry-run       # mostra o que faria, sem gerar
#
#   -n, --np N        Total de PETs do job (NPES). Base para o pré-check/sequential.
#       --parts "L"   Lista explícita de N (sobrepõe a dedução da nuopc.input).
#       --input ARQ   nuopc.input a ler (padrão: ./nuopc.input).
#       --mesh x1.N   Malha (deriva o graph x1.N.graph.info).
#       --graph ARQ   Arquivo graph.info explícito (sobrepõe --mesh e a detecção).
#       --force       Regera mesmo se o .part.N já existir.
#       --dry-run     Só mostra o que seria gerado.
#   -h, --help        Esta ajuda.
# =============================================================================

set -euo pipefail

NPES=""
PARTS_OVERRIDE=""
INPUT="nuopc.input"
MESH=""
GRAPH=""
FORCE=0
DRY_RUN=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_DIM=""; C_0=""
fi
log()  { printf '%s[metis]%s %s\n'  "$C_DIM"  "$C_0" "$*"; }
ok()   { printf '%s  [OK]%s %s\n'   "$C_OK"   "$C_0" "$*"; }
bad()  { printf '%s  [FALHA]%s %s\n' "$C_ERR" "$C_0" "$*"; }
warn() { printf '%s  [AVISO]%s %s\n' "$C_WARN" "$C_0" "$*"; }
die()  { printf '%s[ERRO]%s %s\n'   "$C_ERR"  "$C_0" "$*" >&2; exit 2; }
usage(){ sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--np)   NPES="$2"; shift 2;;
    --parts)   PARTS_OVERRIDE="$2"; shift 2;;
    --input)   INPUT="$2"; shift 2;;
    --mesh)    MESH="$2"; shift 2;;
    --graph)   GRAPH="$2"; shift 2;;
    --force)   FORCE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage;;
    *) die "opção desconhecida: $1  (use --help)";;
  esac
done

# ── Leitura de valores ativos do namelist (ignora comentários '!') ───────────
nml_get_str() { sed 's/!.*//' "$1" | grep -iE "^[[:space:]]*$2[[:space:]]*=" | head -1 \
  | sed -E "s/.*=[[:space:]]*'?([A-Za-z0-9_]+)'?.*/\1/"; }
nml_get_int() { sed 's/!.*//' "$1" | grep -iE "^[[:space:]]*$2[[:space:]]*=" | head -1 \
  | grep -oE '[0-9]+' | head -1; }

# ── Detecção do arquivo graph.info ───────────────────────────────────────────
if [[ -z "$GRAPH" ]]; then
  if [[ -n "$MESH" ]]; then
    GRAPH="${MESH}.graph.info"
  else
    # 1) um único x1.*.graph.info no diretório
    mapfile -t _g < <(ls x1.*.graph.info 2>/dev/null || true)
    if [[ "${#_g[@]}" -eq 1 ]]; then
      GRAPH="${_g[0]}"
    elif [[ "${#_g[@]}" -gt 1 ]]; then
      die "vários x1.*.graph.info encontrados — especifique com --graph ou --mesh: ${_g[*]}"
    else
      # 2) derivar o nome esperado a partir de x1.*.init.nc
      mapfile -t _i < <(ls x1.*.init.nc 2>/dev/null || true)
      if [[ "${#_i[@]}" -ge 1 ]]; then
        local_mesh="$(basename "${_i[0]}" .init.nc)"      # ex.: x1.40962
        GRAPH="${local_mesh}.graph.info"
        die "graph não encontrado — esperado '$GRAPH' (derivado de ${_i[0]}). \
Coloque-o no diretório ou informe --graph."
      fi
      die "não foi possível detectar a malha (sem x1.*.graph.info nem x1.*.init.nc). Use --graph ou --mesh."
    fi
  fi
fi
[[ -f "$GRAPH" ]] || die "graph.info não encontrado: $GRAPH"
log "graph = $GRAPH"

# ── Determinar o conjunto de partições N necessárias ─────────────────────────
declare -a WANT=()
if [[ -n "$PARTS_OVERRIDE" ]]; then
  read -ra WANT <<< "$PARTS_OVERRIDE"
  log "partições (explícitas): ${WANT[*]}"
else
  [[ -n "$NPES" ]] && WANT+=( "$NPES" )
  if [[ -f "$INPUT" ]]; then
    mode="$(nml_get_str "$INPUT" coupling_mode || true)"; mode="${mode:-sequential}"
    atm="$(nml_get_int "$INPUT" atm_pet_count || true)"
    log "nuopc.input: coupling_mode=$mode${atm:+  atm_pet_count=$atm}"
    if [[ "$mode" == "concurrent" ]]; then
      if [[ -z "$atm" || "$atm" -le 0 ]]; then
        [[ -n "$NPES" ]] && atm=$(( (NPES + 1) / 2 )) || atm=""
        [[ -n "$atm" ]] && warn "atm_pet_count=0/auto → assumindo metade: $atm (ajuste com --parts se preciso)"
      fi
      [[ -n "$atm" ]] && WANT+=( "$atm" )
    fi
  else
    warn "nuopc.input não encontrado ($INPUT) — usando apenas -n."
  fi
  [[ "${#WANT[@]}" -gt 0 ]] || die "nada a gerar: informe -n NPES e/ou --parts."
fi

# Dedup + descartar N<=1 (uma tarefa não precisa de partição METIS)
declare -A seen=(); declare -a PARTS=()
for N in "${WANT[@]}"; do
  [[ "$N" =~ ^[0-9]+$ ]] || { warn "ignorando N inválido: '$N'"; continue; }
  if [[ "$N" -le 1 ]]; then log "N=$N não requer partição (tarefa única) — pulando"; continue; fi
  [[ -n "${seen[$N]:-}" ]] && continue
  seen[$N]=1; PARTS+=( "$N" )
done
[[ "${#PARTS[@]}" -gt 0 ]] || die "nenhuma partição >1 a gerar."
log "gerar .part.N para N = ${PARTS[*]}"

# ── gpmetis disponível? (carrega o módulo METIS do sítio se preciso) ─────────
if ! command -v gpmetis >/dev/null 2>&1; then
  if command -v module >/dev/null 2>&1; then
    log "gpmetis ausente — tentando 'module load METIS/5.1.0'"
    module load METIS/5.1.0 2>/dev/null || true
  fi
fi
if [[ "$DRY_RUN" -eq 0 ]]; then
  command -v gpmetis >/dev/null 2>&1 || die "gpmetis não encontrado. Carregue o METIS: module load METIS/5.1.0"
fi

# ── Geração ──────────────────────────────────────────────────────────────────
echo ""
nfail=0; ngen=0; nskip=0
for N in "${PARTS[@]}"; do
  out="${GRAPH}.part.${N}"
  if [[ -f "$out" && "$FORCE" -eq 0 ]]; then
    ok "já existe: $out  (use --force para refazer)"; nskip=$((nskip+1)); continue
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "(dry-run) gpmetis $GRAPH $N  →  $out"; continue
  fi
  log "gpmetis $GRAPH $N"
  if gpmetis "$GRAPH" "$N" >/dev/null 2>&1 && [[ -f "$out" ]]; then
    ok "gerado: $out"; ngen=$((ngen+1))
  else
    bad "falha ao gerar $out"; nfail=$((nfail+1))
  fi
done

echo ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run concluído (nada gerado)."; exit 0
fi
log "resumo: $ngen gerado(s), $nskip já existente(s), $nfail falha(s)."
[[ "$nfail" -eq 0 ]] || exit 1
ok "partições METIS prontas — pode submeter o run."
