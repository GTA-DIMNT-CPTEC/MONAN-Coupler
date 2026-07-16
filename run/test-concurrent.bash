#!/usr/bin/env bash
# =============================================================================
# test-concurrent.bash — Smoke test do modo de acoplamento CONCORRENTE, com
#                        submissão PBS no supercomputador Jaci (Cray XD2000),
#                        no mesmo padrão do run_esmApp.jaci.
#
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos — v13.0
# Sistema acoplado MONAN-A 2.0 x MOM6+SIS2 / NUOPC-ESMF 8.9.1
#
# OBJETIVO
#   Verificar rapidamente que o modo concurrent (&nuopc_petlayout):
#     (1) reparte os PETs em blocos disjuntos ATM | OCN;
#     (2) inicializa os três componentes (MPAS + MED + OCN) nesses subconjuntos;
#     (3) AVANÇA o 1º passo de acoplamento SEM TRAVAR nos MPI_Allreduce coletivos
#         (o cenário de deadlock que a blindagem v13.0 previne).
#
# DUAS FASES (igual ao run_esmApp.jaci — detecção por PBS_O_WORKDIR)
#   • No NÓ DE LOGIN (sem PBS_O_WORKDIR): gera um script .pbs e faz `qsub`.
#   • DENTRO DO JOB (PBS define PBS_O_WORKDIR) ou sessão interativa (qsub -I):
#       carrega módulos, faz `source` do setenv, e executa o smoke test
#       (lançador PALS `mpiexec` + watchdog de progresso/deadlock).
#   • --local força a execução direta (sem qsub), útil em sessão interativa.
#
# COMO O TESTE DETECTA DEADLOCK (sem depender do tempo total de simulação)
#   O mediador grava um NetCDF de diagnóstico (diag_import/mom6_import_*.nc) ao
#   FINAL de cada passo — logo após o seu MPI_Allreduce. O gather Voronoi do
#   MPAS (state_set_field_1d) ocorre ANTES, no mesmo passo. Logo:
#       primeiro mom6_import_*.nc gravado ⇒ coletivos do passo 1 passaram
#                                         ⇒ NÃO houve deadlock
#   O teste encerra assim que o(s) primeiro(s) arquivo(s) aparece(m). Se nada
#   surgir dentro das janelas de estagnação/tempo-limite (processo vivo, parado
#   num coletivo), o veredito é "provável DEADLOCK".
#
# SEGURANÇA / ISOLAMENTO
#   NÃO altera o seu nuopc.input: gera uma cópia de teste injetada via a variável
#   NUOPC_INPUT (suportada por mpas_cap_config_mod). Logs e diagnósticos vão para
#   diretórios *-concurrent-test isolados.
#
# CONVENÇÕES DE CAMINHO (idênticas ao run_esmApp.jaci)
#   COUPLER_ROOT  raiz do sistema acoplado — autodeduzida da localização deste
#                 script (que fica em <COUPLER_ROOT>/run/); sobrescrevível.
#   executável    <COUPLER_ROOT>/bin/esmApp  (sobrescrevível por ESMAPP_BIN).
#   experimento   diretório atual / PBS_O_WORKDIR (onde ficam nuopc.input,
#                 namelists, malha e as saídas).
#
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ AJUSTE AO SÍTIO — as diretivas PBS abaixo têm defaults genéricos de Cray   │
# │ PBS Pro. Verifique fila (--queue), conta (--account), cpus/nó              │
# │ (--ncpus-node) e, se necessário, o select completo (--select / PBS_SELECT) │
# │ com o seu run_esmApp.jaci / política da máquina.                           │
# └───────────────────────────────────────────────────────────────────────────┘
#
# USO
#   # A partir do diretório de experimento, com run/ no PATH:
#   test-concurrent.bash -n 8                      # 8 PETs (4 ATM / 4 OCN) via qsub
#   test-concurrent.bash -n 128 --atm 88 --ocn 40 -w 00:20:00
#   test-concurrent.bash -n 8 --local              # execução direta (sessão interativa)
#   test-concurrent.bash -n 8 --dry-run            # mostra o .pbs e o comando, não submete
#
#   -n, --np N            Total de PETs                     (padrão: 8)
#       --atm K           PETs do ATM (MPAS)                (padrão: metade)
#       --ocn K           PETs do OCN (MOM6/DOCN)           (padrão: resto)
#   -w, --walltime HH:MM:SS  Walltime PBS                   (padrão: 00:30:00)
#       --queue NOME      Fila PBS (-q)                     (padrão: default do sistema)
#       --account NOME    Conta/projeto PBS (-A)            (padrão: nenhum)
#       --ncpus-node N    Núcleos por nó (p/ calcular select) (padrão: 128)
#       --select STR      Sobrescreve a linha select inteira
#       --jobname NOME    Nome do job PBS (-N)              (padrão: smoke-concurrent)
#       --exe CAMINHO     Executável esmApp                 (padrão: $COUPLER_ROOT/bin/esmApp)
#       --rundir DIR      Diretório de experimento          (padrão: atual / PBS_O_WORKDIR)
#       --input ARQ       nuopc.input base                  (padrão: <rundir>/nuopc.input)
#       --setenv ARQ      setenv a "source" no job          (padrão: $COUPLER_ROOT/run/setenv-gnu.bash)
#       --launcher CMD    Lançador MPI (mpiexec|mpirun|srun) (padrão: auto — PALS mpiexec)
#       --launcher-args S Argumentos extras ao lançador
#       --dt SEG          Sobrescreve dt_coupling na config de teste
#       --steps K         Encerra após K passos completos   (padrão: 1)
#       --timeout SEG     Tempo-limite do teste (watchdog)  (padrão: 900)
#       --stall SEG       Sem-progresso ⇒ suspeita hang     (padrão: 180)
#       --interval SEG    Período de amostragem             (padrão: 5)
#       --local           Executa direto (sem qsub)
#       --baseline        Roda também um teste SEQUENCIAL de sanidade antes
#       --keep            Preserva config/logs de teste ao final
#       --dry-run         Só gera config + .pbs e imprime o comando (não submete/executa)
#   -h, --help            Esta ajuda
# =============================================================================

set -euo pipefail

# ── Raiz do projeto (estilo run_esmApp.jaci): script vive em <ROOT>/run/ ─────
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
: "${COUPLER_ROOT:=$(dirname "$SCRIPT_DIR")}"
export COUPLER_ROOT

# ── Padrões (a maioria sobrescrevível por env ou flag) ───────────────────────
NP=8; ATM=0; OCN=0
WALLTIME="00:30:00"
QUEUE="${PBS_QUEUE:-}"
ACCOUNT="${PBS_ACCOUNT:-}"
NCPUS_NODE="${JACI_NCPUS_PER_NODE:-128}"
PBS_SELECT_OVERRIDE="${PBS_SELECT:-}"
JOBNAME="smoke-concurrent"
EXE="${ESMAPP_BIN:-$COUPLER_ROOT/bin/esmApp}"
RUNDIR="${PBS_O_WORKDIR:-$(pwd)}"
BASE_INPUT=""
SETENV="${SETENV:-$COUPLER_ROOT/run/setenv-gnu.bash}"
LAUNCHER="${LAUNCHER:-}"
LAUNCHER_ARGS="${LAUNCHER_ARGS:-}"
DT_OVERRIDE=""
STEPS_TARGET=1
TIMEOUT=900
STALL=180
INTERVAL=5
FORCE_LOCAL=0
DO_BASELINE=0
KEEP=0
DRY_RUN=0

TAG="concurrent-test"
CFG=""; LOG_DIR=""; IMPORT_DIR=""; EXPORT_DIR=""; STDOUT_LOG=""

# ── Cores ────────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_DIM=""; C_0=""
fi
log()  { printf '%s[teste]%s %s\n'  "$C_DIM"  "$C_0" "$*"; }
ok()   { printf '%s  [PASS]%s %s\n' "$C_OK"   "$C_0" "$*"; }
bad()  { printf '%s  [FAIL]%s %s\n' "$C_ERR"  "$C_0" "$*"; }
warn() { printf '%s  [AVISO]%s %s\n' "$C_WARN" "$C_0" "$*"; }
die()  { printf '%s[ERRO]%s %s\n'   "$C_ERR"  "$C_0" "$*" >&2; exit 2; }
usage(){ sed -n '2,/^# ===/p' "$SELF" | sed 's/^# \{0,1\}//; s/^#//'; exit 0; }

# ── Parsing de argumentos ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--np)          NP="$2"; shift 2;;
    --atm)            ATM="$2"; shift 2;;
    --ocn)            OCN="$2"; shift 2;;
    -w|--walltime)    WALLTIME="$2"; shift 2;;
    --queue)          QUEUE="$2"; shift 2;;
    --account)        ACCOUNT="$2"; shift 2;;
    --ncpus-node)     NCPUS_NODE="$2"; shift 2;;
    --select)         PBS_SELECT_OVERRIDE="$2"; shift 2;;
    --jobname)        JOBNAME="$2"; shift 2;;
    --exe)            EXE="$2"; shift 2;;
    --rundir)         RUNDIR="$2"; shift 2;;
    --input)          BASE_INPUT="$2"; shift 2;;
    --setenv)         SETENV="$2"; shift 2;;
    --launcher)       LAUNCHER="$2"; shift 2;;
    --launcher-args)  LAUNCHER_ARGS="$2"; shift 2;;
    --dt)             DT_OVERRIDE="$2"; shift 2;;
    --steps)          STEPS_TARGET="$2"; shift 2;;
    --timeout)        TIMEOUT="$2"; shift 2;;
    --stall)          STALL="$2"; shift 2;;
    --interval)       INTERVAL="$2"; shift 2;;
    --local)          FORCE_LOCAL=1; shift;;
    --baseline)       DO_BASELINE=1; shift;;
    --keep)           KEEP=1; shift;;
    --dry-run)        DRY_RUN=1; shift;;
    -h|--help)        usage;;
    *) die "opção desconhecida: $1  (use --help)";;
  esac
done

# ── Resolução de caminhos e partição (regra idêntica a esm.F90: 0 => auto) ────
RUNDIR="$(cd "$RUNDIR" && pwd)" || die "rundir inválido"
[[ -z "$BASE_INPUT" ]] && BASE_INPUT="$RUNDIR/nuopc.input"
CFG="$RUNDIR/nuopc.input.$TAG"
LOG_DIR="logs-$TAG"                       # relativo ao RUNDIR (CWD de execução)
IMPORT_DIR="$RUNDIR/diag_import-$TAG"
EXPORT_DIR="$RUNDIR/diag_export-$TAG"
STDOUT_LOG="$RUNDIR/$LOG_DIR/stdout.log"

if   [[ "$ATM" -le 0 && "$OCN" -le 0 ]]; then ATM=$(( (NP + 1) / 2 )); OCN=$(( NP - ATM ))
elif [[ "$ATM" -le 0 ]]; then ATM=$(( NP - OCN ))
elif [[ "$OCN" -le 0 ]]; then OCN=$(( NP - ATM ))
fi
[[ "$NP" -ge 2 && "$ATM" -ge 1 && "$OCN" -ge 1 && $((ATM + OCN)) -eq "$NP" ]] \
  || die "partição inválida: atm=$ATM ocn=$OCN devem somar np=$NP (todos >=1)"

# ── Decisão de fase: submeter (login) vs executar (dentro do job/interativo) ──
#   PBS_O_WORKDIR definido ⇒ estamos dentro de um job PBS (batch ou interativo).
#   --local força execução direta. Caso contrário (login sem job) ⇒ submeter.
IN_JOB=0
if [[ -n "${PBS_O_WORKDIR:-}" || "$FORCE_LOCAL" -eq 1 ]]; then IN_JOB=1; fi

# =============================================================================
#  FASE 1 — SUBMISSÃO (nó de login): gera .pbs e faz qsub
# =============================================================================
submit_phase() {
  if [[ "$DRY_RUN" -eq 0 ]]; then
    command -v qsub >/dev/null 2>&1 || die "qsub não encontrado (não é um nó de login PBS?). Use --local para rodar direto."
  fi
  [[ -f "$BASE_INPUT" ]] || die "nuopc.input base não encontrado: $BASE_INPUT"

  # Recursos PBS: NÓS = ceil(NP/ncpus_node); PPN = ceil(NP/NÓS)
  local nodes ppn select_line
  nodes=$(( (NP + NCPUS_NODE - 1) / NCPUS_NODE ))
  ppn=$(( (NP + nodes - 1) / nodes ))
  if [[ -n "$PBS_SELECT_OVERRIDE" ]]; then
    select_line="$PBS_SELECT_OVERRIDE"
  else
    select_line="${nodes}:ncpus=${NCPUS_NODE}:mpiprocs=${ppn}"
  fi

  local stamp pbs joblog
  stamp="$(date +%Y%m%d_%H%M%S)"
  pbs="$RUNDIR/${JOBNAME}.${stamp}.pbs"
  joblog="$RUNDIR/${JOBNAME}.${stamp}.log"

  # Argumentos repassados ao job (reexecuta este script em --local dentro dele)
  local run_args=( -n "$NP" --atm "$ATM" --ocn "$OCN"
                   --steps "$STEPS_TARGET" --timeout "$TIMEOUT"
                   --stall "$STALL" --interval "$INTERVAL"
                   --rundir "$RUNDIR" --input "$BASE_INPUT"
                   --exe "$EXE" --setenv "$SETENV" --keep )
  [[ -n "$DT_OVERRIDE"    ]] && run_args+=( --dt "$DT_OVERRIDE" )
  [[ -n "$LAUNCHER"       ]] && run_args+=( --launcher "$LAUNCHER" )
  [[ -n "$LAUNCHER_ARGS"  ]] && run_args+=( --launcher-args "$LAUNCHER_ARGS" )
  [[ "$DO_BASELINE" -eq 1 ]] && run_args+=( --baseline )

  {
    echo "#!/usr/bin/env bash"
    echo "#PBS -N ${JOBNAME}"
    echo "#PBS -l select=${select_line}"
    echo "#PBS -l walltime=${WALLTIME}"
    [[ -n "$QUEUE"   ]] && echo "#PBS -q ${QUEUE}"
    [[ -n "$ACCOUNT" ]] && echo "#PBS -A ${ACCOUNT}"
    echo "#PBS -j oe"
    echo "#PBS -o ${joblog}"
    echo ""
    echo "set -euo pipefail"
    echo "cd \"\${PBS_O_WORKDIR}\""
    echo "export COUPLER_ROOT=\"${COUPLER_ROOT}\""
    echo ""
    echo "# Reexecuta ESTE script em modo direto (--local) dentro do job."
    printf 'exec bash %q --local' "$SELF"
    for a in "${run_args[@]}"; do printf ' %q' "$a"; done
    echo ""
  } > "$pbs"

  echo "============================================================="
  echo "  Smoke test CONCORRENTE — submissão PBS (Jaci)"
  echo "============================================================="
  log "COUPLER_ROOT = $COUPLER_ROOT"
  log "experimento  = $RUNDIR"
  log "executável   = $EXE"
  log "PETs         = $NP (ATM=$ATM | OCN=$OCN)"
  log "recursos     = select=${select_line}  walltime=${WALLTIME}${QUEUE:+  fila=$QUEUE}${ACCOUNT:+  conta=$ACCOUNT}"
  log "script PBS   = $pbs"
  log "saída do job = $joblog"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""; log "--dry-run: script .pbs gerado (não submetido). Conteúdo:"
    echo "-------------------------------------------------------------"
    cat "$pbs"
    echo "-------------------------------------------------------------"
    log "para submeter: qsub $pbs"
    exit 0
  fi

  [[ -x "$EXE" ]] || warn "executável ainda não existe: $EXE  (compile com 'make' antes de o job rodar)"
  echo ""; log "submetendo: qsub $pbs"
  local jobid; jobid="$(qsub "$pbs")"
  ok "job submetido: $jobid"
  echo ""
  log "acompanhe:  qstat -x $jobid    |    tail -f $joblog"
  log "o veredito PASS/FAIL sairá em: $joblog"
  exit 0
}

# =============================================================================
#  FASE 2 — EXECUÇÃO (dentro do job ou --local): módulos + setenv + watchdog
# =============================================================================
load_environment() {
  # Mesmo ambiente do run_esmApp.jaci: setenv (que carrega módulos) + PALS.
  if [[ -f "$SETENV" ]]; then
    log "carregando ambiente: $SETENV"
    # shellcheck disable=SC1090
    source "$SETENV" || warn "falha ao carregar $SETENV (seguindo mesmo assim)"
  else
    warn "setenv não encontrado ($SETENV) — presumindo ambiente já carregado"
  fi
  if command -v module >/dev/null 2>&1; then
    module load cray-pals 2>/dev/null || true   # lançador PALS (mpiexec)
  fi
}

detect_launcher() {
  if [[ -z "$LAUNCHER" ]]; then
    for cand in mpiexec mpirun srun aprun; do
      command -v "$cand" >/dev/null 2>&1 && { LAUNCHER="$cand"; break; }
    done
  fi
  if [[ -z "$LAUNCHER" ]]; then
    [[ "$DRY_RUN" -eq 1 ]] && LAUNCHER="mpiexec" || die "nenhum lançador MPI encontrado (use --launcher)"
  fi
  if ! command -v "$LAUNCHER" >/dev/null 2>&1; then
    [[ "$DRY_RUN" -eq 1 ]] && warn "lançador '$LAUNCHER' não está no PATH (ok em --dry-run)" \
      || die "lançador '$LAUNCHER' não está no PATH"
  fi
}

# Gera a config de teste (concurrent|sequential) preservando o namelist
gen_config() {
  local mode="$1" out="$2"
  awk '
    BEGIN{skip=0}
    /^[[:space:]]*&nuopc_petlayout/ {skip=1; next}
    skip && /^[[:space:]]*\// {skip=0; next}
    skip {next}
    {print}
  ' "$BASE_INPUT" > "$out"
  sed -i -E "s|^([[:space:]]*log_dir[[:space:]]*=[[:space:]]*).*|\1'$LOG_DIR'|" "$out"
  sed -i -E "s|^([[:space:]]*write_import_diag[[:space:]]*=[[:space:]]*)\.[a-zA-Z]+\.|\1.true.|" "$out"
  sed -i -E "s|^([[:space:]]*import_diag_dir[[:space:]]*=[[:space:]]*).*|\1'diag_import-$TAG'|" "$out"
  sed -i -E "s|^([[:space:]]*output_dir[[:space:]]*=[[:space:]]*).*|\1'diag_export-$TAG'|" "$out"
  [[ -n "$DT_OVERRIDE" ]] && \
    sed -i -E "s|^([[:space:]]*dt_coupling[[:space:]]*=[[:space:]]*)[0-9]+|\1$DT_OVERRIDE|" "$out"
  {
    echo ""
    echo "!-- injetado por test-concurrent.bash ($(date '+%Y-%m-%d %H:%M:%S')) --"
    echo "&nuopc_petlayout"
    echo "  coupling_mode = '$mode'"
    echo "  atm_pet_count = $ATM"
    echo "  ocn_pet_count = $OCN"
    echo "/"
  } >> "$out"
}

kill_tree() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true; sleep 2
  kill -KILL "$pid" 2>/dev/null || true
  pkill -KILL -P "$pid" 2>/dev/null || true
}

# Define VERDICT: completed | progress | crash | hang | initfail
run_and_watch() {
  local cfg="$1"
  export NUOPC_INPUT="$cfg"
  mkdir -p "$RUNDIR/$LOG_DIR" "$IMPORT_DIR" "$EXPORT_DIR"
  rm -f "${IMPORT_DIR:?}"/*.nc "${EXPORT_DIR:?}"/*.nc "${RUNDIR:?}/${LOG_DIR:?}"/*.log 2>/dev/null || true

  local cmd=( "$LAUNCHER" )
  if [[ -n "$LAUNCHER_ARGS" ]]; then read -ra _la <<< "$LAUNCHER_ARGS"; cmd+=( "${_la[@]}" ); fi
  cmd+=( -n "$NP" "$EXE" )

  log "comando: NUOPC_INPUT=$cfg  ${cmd[*]}"
  ( cd "$RUNDIR" && "${cmd[@]}" ) >"$STDOUT_LOG" 2>&1 &
  local pid=$!

  local start now count last_count=-1 last_prog ec
  start=$(date +%s); last_prog=$start; VERDICT="hang"
  while true; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null; ec=$?
      if   grep -q "SIMULACAO CONCLUIDA COM SUCESSO" "$STDOUT_LOG" 2>/dev/null; then VERDICT="completed"
      elif [[ "$ec" -ne 0 ]]; then VERDICT="crash"
      else
        count=$(find "$IMPORT_DIR" -maxdepth 1 -name '*.nc' 2>/dev/null | wc -l)
        [[ "$count" -ge 1 ]] && VERDICT="progress" || VERDICT="crash"
      fi
      break
    fi
    sleep "$INTERVAL"; now=$(date +%s)
    count=$(find "$IMPORT_DIR" -maxdepth 1 -name '*.nc' 2>/dev/null | wc -l)
    if grep -q "SIMULACAO CONCLUIDA COM SUCESSO" "$STDOUT_LOG" 2>/dev/null; then
      VERDICT="completed"; kill_tree "$pid"; break; fi
    if [[ "$count" -ge "$STEPS_TARGET" ]]; then
      VERDICT="progress"; kill_tree "$pid"; break; fi          # 1º passo OK ⇒ sem deadlock
    [[ "$count" -gt "$last_count" ]] && { last_count="$count"; last_prog="$now"; }
    if [[ $((now - last_prog)) -ge "$STALL" && "$count" -eq 0 ]]; then
      if grep -q "\[OK\] Inicializacao concluida" "$STDOUT_LOG" 2>/dev/null; then VERDICT="hang"
      else VERDICT="initfail"; fi
      kill_tree "$pid"; break
    fi
    if [[ $((now - start)) -ge "$TIMEOUT" ]]; then
      [[ "$count" -ge 1 ]] && VERDICT="progress" || VERDICT="hang"; kill_tree "$pid"; break; fi
  done
}

NFAIL=0
grep_any() { grep -qE "$1" "$STDOUT_LOG" "$RUNDIR/$LOG_DIR"/PET*.esmApp.log 2>/dev/null; }
_diag_tail() {
  echo "        --- últimas linhas de PET0 ---"
  tail -6 "$RUNDIR/$LOG_DIR"/PET0.esmApp.log 2>/dev/null | sed 's/^/        /'
  local lastpet="$RUNDIR/$LOG_DIR/PET$((NP-1)).esmApp.log"
  if [[ -f "$lastpet" ]]; then
    echo "        --- últimas linhas de PET$((NP-1)) (bloco OCN) ---"
    tail -6 "$lastpet" | sed 's/^/        /'
  fi
}
analyze() {
  echo ""; log "análise dos logs em $RUNDIR/$LOG_DIR/"
  if   grep_any "modo CONCURRENT — ATM=PET\[0\.\.$((ATM-1))\] OCN=PET\[$ATM\.\."; then
    ok "partição concorrente aplicada (ATM=$ATM | OCN=$OCN)"
  elif grep_any "modo CONCURRENT"; then ok "partição concorrente aplicada"
  else bad "marcador de partição concorrente ausente"; NFAIL=$((NFAIL+1)); fi

  if grep_any "RunSequence.*CONCORRENTE"; then ok "RunSequence concorrente selecionada"
  else bad "RunSequence concorrente não registrada"; NFAIL=$((NFAIL+1)); fi

  if grep -q "\[OK\] Inicializacao concluida" "$STDOUT_LOG" 2>/dev/null; then
    ok "inicialização concluída (MPAS + MED + OCN)"
  else bad "inicialização NÃO concluída"; NFAIL=$((NFAIL+1)); fi

  if grep_any "MPI_Abort|forrtl: severe|SIGSEGV|Segmentation fault|particao concurrent invalida"; then
    bad "marcadores de erro fatal encontrados:"; NFAIL=$((NFAIL+1))
    grep -nE "MPI_Abort|forrtl: severe|SIGSEGV|Segmentation fault|particao concurrent invalida" \
      "$STDOUT_LOG" "$RUNDIR/$LOG_DIR"/PET*.esmApp.log 2>/dev/null | head -5 | sed 's/^/        /'
  else ok "nenhum marcador de erro fatal / abort MPI"; fi

  case "$VERDICT" in
    completed) ok "simulação concluída integralmente — coletivos concorrentes OK";;
    progress)  ok "1º passo de acoplamento completou os coletivos — SEM deadlock";;
    hang)      bad "PROVÁVEL DEADLOCK: processo vivo, sem progresso nos coletivos"; NFAIL=$((NFAIL+1)); _diag_tail;;
    initfail)  bad "parada ANTES de concluir a inicialização (não chegou ao passo 1)"; NFAIL=$((NFAIL+1)); _diag_tail;;
    crash)     bad "o executável ABORTOU antes de completar o 1º passo"; NFAIL=$((NFAIL+1))
               echo "        --- últimas linhas do stdout ---"; tail -8 "$STDOUT_LOG" 2>/dev/null | sed 's/^/        /';;
  esac
}

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    log "artefatos preservados (--keep): $CFG, $RUNDIR/$LOG_DIR/, $IMPORT_DIR/"
  else
    rm -f "$CFG" 2>/dev/null || true
    rm -rf "${RUNDIR:?}/${LOG_DIR:?}" "${IMPORT_DIR:?}" "${EXPORT_DIR:?}" 2>/dev/null || true
  fi
}

run_phase() {
  trap cleanup EXIT
  echo "============================================================="
  echo "  Smoke test — modo CONCORRENTE (deadlock em coletivos MPI)"
  echo "============================================================="
  log "COUPLER_ROOT = $COUPLER_ROOT"
  log "experimento  = $RUNDIR"
  log "executável   = $EXE"
  log "PETs         = $NP  (ATM=$ATM | OCN=$OCN)"
  log "encerra em   = $STEPS_TARGET passo(s) | timeout=${TIMEOUT}s | stall=${STALL}s"
  echo ""

  load_environment
  detect_launcher
  log "lançador     = $LAUNCHER $LAUNCHER_ARGS"

  [[ -f "$BASE_INPUT" ]] || die "nuopc.input base não encontrado: $BASE_INPUT"
  gen_config concurrent "$CFG"
  log "config de teste: $CFG"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""; log "--dry-run: comando que seria executado:"
    echo "    ( cd $RUNDIR && NUOPC_INPUT=$CFG $LAUNCHER $LAUNCHER_ARGS -n $NP $EXE )"
    echo ""; echo "--- grupo injetado em $CFG ---"; tail -7 "$CFG"
    KEEP=1; exit 0
  fi

  [[ -x "$EXE" ]] || die "executável não encontrado ou sem permissão: $EXE"

  if [[ "$DO_BASELINE" -eq 1 ]]; then
    echo ""; log "baseline SEQUENCIAL (sanidade do binário)…"
    local seq_cfg="$RUNDIR/nuopc.input.sequential-$TAG"
    gen_config sequential "$seq_cfg"
    run_and_watch "$seq_cfg"
    case "$VERDICT" in
      completed|progress) ok "baseline sequencial avançou (binário funcional)";;
      *) warn "baseline sequencial não avançou (veredito=$VERDICT) — problema pode não ser do modo concurrent";;
    esac
    [[ "$KEEP" -eq 1 ]] || rm -f "$seq_cfg"
  fi

  echo ""; log "executando teste CONCORRENTE…"
  run_and_watch "$CFG"
  analyze

  echo ""; echo "============================================================="
  if [[ "$NFAIL" -eq 0 ]]; then
    printf '%s  RESULTADO: PASSOU%s — modo concorrente sem deadlock\n' "$C_OK" "$C_0"
    echo "============================================================="; exit 0
  else
    printf '%s  RESULTADO: FALHOU%s — %d verificação(ões) com problema\n' "$C_ERR" "$C_0" "$NFAIL"
    echo "  (inspecione $RUNDIR/$LOG_DIR/PET*.esmApp.log)"
    echo "============================================================="; exit 1
  fi
}

# ── Despacho de fase ─────────────────────────────────────────────────────────
if [[ "$IN_JOB" -eq 1 ]]; then
  run_phase
else
  submit_phase
fi
