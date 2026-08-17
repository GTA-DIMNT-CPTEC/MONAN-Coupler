#!/usr/bin/env bash
# =============================================================================
# test-sequential-split.bash — Smoke test da combinação SEQUENTIAL + SPLIT do
#                        grupo &nuopc_petlayout, com submissão PBS no
#                        supercomputador Jaci (Cray XD2000), no mesmo padrão do
#                        run_esmApp.jaci e do test-concurrent.bash.
#
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos — v14.20
# Sistema acoplado MONAN-A 2.0 x MOM6+SIS2 / NUOPC-ESMF 8.9.1
#
# POR QUE ESTE TESTE EXISTE
#   Até a v14.19 o grupo &nuopc_petlayout colapsava dois eixos ortogonais num
#   único parâmetro: o split de comunicador só existia dentro do ramo
#   concurrent, e atm_pet_count/ocn_pet_count eram DESCARTADOS EM SILÊNCIO
#   quando coupling_mode='sequential'. Quem pedia 2048 PETs para o MPAS e 128
#   para o MOM6 em modo sequencial recebia os DOIS componentes em todos os
#   PETs, sem qualquer aviso, e o MOM6 abortava bem depois, no
#   mpp_define_domains, com uma mensagem que não mencionava PET algum.
#
#   A v14.20 separou os eixos (coupling_mode × pet_layout) e tornou
#   sequential+split uma configuração de primeira classe. Este teste é a
#   verificação de que ela realmente funciona.
#
# OBJETIVO
#   Verificar que, com coupling_mode='sequential' e pet_layout='split':
#     (1) os PETs são repartidos em blocos DISJUNTOS ATM | OCN;
#     (2) a RunSequence selecionada é a SEQUENCIAL (sem "CONCORRENTE");
#     (3) os três componentes (MPAS + MED + OCN) inicializam nesses
#         subconjuntos, com o MED em todos os PETs;
#     (4) o 1º passo de acoplamento AVANÇA sem travar nos MPI_Allreduce
#         coletivos, que agora rodam sobre comunicadores de componente
#         DIFERENTES do global;
#     (5) — a verificação que distingue este teste do test-concurrent.bash —
#         as janelas de execução de ATM e OCN NÃO SE SOBREPÕEM no tempo.
#
#   O item (5) é o que separa sequential+split de concurrent+split: os dois
#   produzem exatamente os mesmos conjuntos de PETs, e só os carimbos de tempo
#   dos logs distinguem um do outro. Sem essa checagem, um erro que fizesse o
#   driver montar a RunSequence concorrente passaria despercebido.
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
# COMO O TESTE MEDE A SOBREPOSIÇÃO ATM × OCN
#   Cada fase de componente deixa no log ESMF um par "intro."/"extro." com
#   carimbo de tempo. O teste reúne as janelas `Run` de todos os PETs do bloco
#   ATM e de todos os PETs do bloco OCN, une cada conjunto (as janelas de PETs
#   irmãos se sobrepõem entre si, e isso é esperado) e mede a interseção das
#   duas uniões. Em execução sequencial a interseção deve ser praticamente
#   nula; uma sobreposição relevante indica que a RunSequence concorrente foi
#   montada por engano. A tolerância é ajustável com --overlap-tol.
#   Requer python3 no nó de execução; sem ele, a verificação é PULADA com
#   aviso, e as demais seguem valendo.
#
# SEGURANÇA / ISOLAMENTO
#   NÃO altera o seu nuopc.input: gera uma cópia de teste injetada via a variável
#   NUOPC_INPUT (suportada por mpas_cap_config_mod). Logs e diagnósticos vão para
#   diretórios *-seqsplit-test isolados.
#
# ATENÇÃO À PARTIÇÃO METIS
#   Com pet_layout=split, o MPAS é decomposto em atm_pet_count partições, NÃO
#   em -n. Antes de rodar com --atm K, garanta que existe
#   x1.*.graph.info.part.K no diretório do experimento (gere com
#   `gen-metis.bash --parts K`). O teste avisa se o arquivo não estiver lá.
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
#   test-sequential-split.bash -n 8 --atm 6 --ocn 2      # via qsub
#   test-sequential-split.bash -n 8 --atm 6 --ocn 2 --local
#   test-sequential-split.bash -n 8 --dry-run            # mostra o .pbs, não submete
#
#   -n, --np N            Total de PETs                     (padrão: 8)
#       --atm K           PETs do ATM (MPAS)                (padrão: metade)
#       --ocn K           PETs do OCN (MOM6/DOCN)           (padrão: resto)
#   -w, --walltime HH:MM:SS  Walltime PBS                   (padrão: 00:30:00)
#       --queue NOME      Fila PBS (-q)                     (padrão: default do sistema)
#       --account NOME    Conta/projeto PBS (-A)            (padrão: nenhum)
#       --ncpus-node N    Núcleos por nó (p/ calcular select) (padrão: 128)
#       --select STR      Sobrescreve a linha select inteira
#       --jobname NOME    Nome do job PBS (-N)              (padrão: smoke-seqsplit)
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
#       --overlap-tol SEG Sobreposição ATM×OCN tolerada     (padrão: 1.0)
#       --local           Executa direto (sem qsub)
#       --baseline        Roda também um teste sequential+shared de sanidade antes
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
JOBNAME="smoke-seqsplit"
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
OVERLAP_TOL="1.0"       # segundos de sobreposição ATM×OCN tolerados
FORCE_LOCAL=0
DO_BASELINE=0
KEEP=0
DRY_RUN=0

TAG="seqsplit-test"
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
    --overlap-tol)    OVERLAP_TOL="$2"; shift 2;;
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
  run_args+=( --overlap-tol "$OVERLAP_TOL" )
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
  echo "  Smoke test SEQUENTIAL + SPLIT — submissão PBS (Jaci)"
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

# Gera a config de teste preservando o namelist.
#   $1 = coupling_mode (sequential|concurrent)   $2 = arquivo de saída
#   $3 = pet_layout    (shared|split)            — padrão: split
#
# v14.20: o grupo &nuopc_petlayout tem DOIS eixos, e as contagens de PET só
# são aceitas com pet_layout=split. Emitir sequential + atm/ocn_pet_count sem
# pet_layout (como fazia o baseline até a v14.19) passou a ser ERRO de
# configuração, e não mais descarte silencioso — por isso o baseline abaixo
# zera as contagens explicitamente.
gen_config() {
  local mode="$1" out="$2" layout="${3:-split}"
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
    echo "!-- injetado por test-sequential-split.bash ($(date '+%Y-%m-%d %H:%M:%S')) --"
    echo "&nuopc_petlayout"
    echo "  coupling_mode = '$mode'"
    echo "  pet_layout    = '$layout'"
    if [[ "$layout" == "split" ]]; then
      echo "  atm_pet_count = $ATM"
      echo "  ocn_pet_count = $OCN"
    else
      echo "  atm_pet_count = 0"
      echo "  ocn_pet_count = 0"
    fi
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

  # Morte imediata (segundos) quase nunca e' deadlock: e' lancador recusado,
  # binario ausente ou ambiente incompleto. Mostrar o stdout de imediato evita
  # que o veredito "crash" apareca sem nenhuma pista do motivo.
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "o executável terminou em menos de 2 s — primeiras linhas do stdout:"
    head -20 "$STDOUT_LOG" 2>/dev/null | sed 's/^/        /'
  fi
  while true; do
    if ! kill -0 "$pid" 2>/dev/null; then
      # `set -e` aborta o script se um comando isolado retorna != 0, e `wait`
      # devolve o codigo de saida do processo. Escrito como `wait; ec=$?` o
      # script morria em silencio sempre que o executavel falhava — que e'
      # justamente o caso que este teste existe para diagnosticar. O `|| ec=$?`
      # coloca o wait num contexto testado, isentando-o do set -e.
      ec=0; wait "$pid" 2>/dev/null || ec=$?
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
# ── Sobreposição temporal ATM × OCN ──────────────────────────────────────────
# Devolve, no stdout, três campos: <overlap_s> <span_atm_s> <span_ocn_s>.
# Vazio quando não há python3 ou quando não há janelas suficientes nos logs.
#
# A união é necessária porque os PETs irmãos de um mesmo componente rodam ao
# mesmo tempo (isso é esperado e não é sobreposição ATM×OCN); o que interessa
# é a interseção entre a união do bloco ATM e a união do bloco OCN.
measure_overlap() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$RUNDIR/$LOG_DIR" "$ATM" <<'PYEOF' 2>/dev/null
import re, sys, glob, os
from datetime import datetime

logdir, n_atm = sys.argv[1], int(sys.argv[2])
RE_LINE = re.compile(
    r"^(?P<d>\d{8})\s+(?P<t>\d{6}\.\d+)\s+\S+\s+PET(?P<pet>\d+)\s+(?P<msg>.*)$")
RE_RUN = re.compile(r"^(?P<comp>MPAS|OCN):\s*Run\s+(?P<edge>intro|extro)\.?\s*$")

spans = {"MPAS": [], "OCN": []}
for f in sorted(glob.glob(os.path.join(logdir, "PET*.esmApp.log"))):
    pending = {}
    for raw in open(f, errors="replace"):
        m = RE_LINE.match(raw)
        if not m:
            continue
        rm = RE_RUN.match(m.group("msg"))
        if not rm:
            continue
        pet, comp = int(m.group("pet")), rm.group("comp")
        # Só conta janelas no bloco esperado: um PET do bloco OCN que
        # reportasse MPAS já seria, por si, falha de particionamento.
        if comp == "MPAS" and pet >= n_atm:
            continue
        if comp == "OCN" and pet < n_atm:
            continue
        ts = datetime.strptime(m.group("d") + " " + m.group("t"),
                               "%Y%m%d %H%M%S.%f").timestamp()
        if rm.group("edge") == "intro":
            pending[comp] = ts
        else:
            t0 = pending.pop(comp, None)
            if t0 is not None and ts >= t0:
                spans[comp].append((t0, ts))

def merge(iv):
    iv = sorted(iv)
    out = []
    for a, b in iv:
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out

atm, ocn = merge(spans["MPAS"]), merge(spans["OCN"])
if not atm or not ocn:
    sys.exit(1)

ov = 0.0
i = j = 0
while i < len(atm) and j < len(ocn):
    lo, hi = max(atm[i][0], ocn[j][0]), min(atm[i][1], ocn[j][1])
    if hi > lo:
        ov += hi - lo
    if atm[i][1] < ocn[j][1]:
        i += 1
    else:
        j += 1

print("%.3f %.3f %.3f" % (ov,
      sum(b - a for a, b in atm), sum(b - a for a, b in ocn)))
PYEOF
}

analyze() {
  echo ""; log "análise dos logs em $RUNDIR/$LOG_DIR/"

  # (1) Split de comunicador aplicado, com as faixas de PET esperadas.
  if   grep_any "layout SPLIT.*ATM=PET\[0\.\.$((ATM-1))\] OCN=PET\[$ATM\.\."; then
    ok "partição split aplicada (ATM=$ATM | OCN=$OCN)"
  elif grep_any "layout SPLIT"; then
    warn "layout split anunciado, mas com faixas de PET diferentes das pedidas"
    grep -hoE "layout SPLIT.*" "$RUNDIR/$LOG_DIR"/PET*.esmApp.log 2>/dev/null \
      | head -1 | sed 's/^/        /'
    NFAIL=$((NFAIL+1))
  elif grep_any "layout SHARED"; then
    bad "driver aplicou layout SHARED — pet_layout=split foi ignorado"
    bad "  (este é exatamente o defeito que a v14.20 corrigiu; binário antigo?)"
    NFAIL=$((NFAIL+1))
  else
    bad "marcador de layout ausente nos logs"; NFAIL=$((NFAIL+1))
  fi

  # (2) Execução sequencial: a RunSequence NÃO pode ser a concorrente.
  if grep_any "layout SPLIT \(execucao SEQUENTIAL\)"; then
    ok "execução sequencial anunciada pelo driver"
  else bad "driver não anunciou execução sequencial"; NFAIL=$((NFAIL+1)); fi

  if grep_any "RunSequence.*CONCORRENTE"; then
    bad "RunSequence CONCORRENTE selecionada — esperada a sequencial"
    NFAIL=$((NFAIL+1))
  elif grep_any "RunSequence Fase [12] \("; then
    ok "RunSequence sequencial selecionada"
  else bad "RunSequence não registrada nos logs"; NFAIL=$((NFAIL+1)); fi

  if grep -q "\[OK\] Inicializacao concluida" "$STDOUT_LOG" 2>/dev/null; then
    ok "inicialização concluída (MPAS + MED + OCN)"
  else bad "inicialização NÃO concluída"; NFAIL=$((NFAIL+1)); fi

  # (3c) Valor físico de So_t (fix B-SEQINIT-02, v14.21). O carimbo de tempo
  #      não prova conteúdo: o mom_cap carimba todos os campos exportados em
  #      laço cego. Sem ocean_model_init_sfc, So_t chega zerado E carimbado.
  if grep_any "ocean_model_init_sfc — t_surf de t=0"; then
    ok "OCN extraiu t_surf antes do mom_export de t=0"
  else
    bad "OCN não chamou ocean_model_init_sfc — So_t exportado como zeros em t=0"
    NFAIL=$((NFAIL+1))
  fi
  if grep_any "So_t carimbado mas SEM valor fisico"; then
    bad "So_t chegou ao mediador carimbado e nulo (t_surf não preenchido)"
    NFAIL=$((NFAIL+1))
  elif grep_any "So_t com [0-9]+ celulas em \\[270,310\\] K"; then
    ok "So_t com valores físicos no mediador em t=0"
  fi

  # (3b) Resolução da dependência de dados de So_t (fix B-SEQINIT-01, v14.21).
  #      Na RunSequence sequencial o conector "OCN -> MED" vem ANTES do
  #      elemento "OCN", então o mediador PRECISA pedir uma segunda iteração
  #      do laço de dependência de dados do driver. Se ele declarar
  #      InitializeDataComplete de primeira, So_t chega zerado a t=0.
  if grep_any "MED: IDC aguardando So_t do OCN"; then
    if grep_any "MED: InitializeDataComplete SATISFIED \(So_t em t=0\)"; then
      ok "So_t resolvido no laço de dependência de dados (2ª iteração)"
    else
      bad "MED pediu nova iteração mas nunca recebeu So_t — laço não convergiu"
      NFAIL=$((NFAIL+1))
    fi
  elif grep_any "MED: InitializeDataComplete SATISFIED \(So_t em t=0\)"; then
    warn "MED concluiu em 1 iteração — ordem da RunSequence mudou?"
  else
    bad "MED declarou InitializeDataComplete sem verificar So_t (binário anterior à v14.21)"
    bad "  So_t chega ZERADO ao mediador em t=0 neste modo"
    NFAIL=$((NFAIL+1))
  fi

  if grep_any "MPI_Abort|forrtl: severe|SIGSEGV|Segmentation fault|particao (split|concurrent) invalida"; then
    bad "marcadores de erro fatal encontrados:"; NFAIL=$((NFAIL+1))
    grep -nE "MPI_Abort|forrtl: severe|SIGSEGV|Segmentation fault|particao (split|concurrent) invalida" \
      "$STDOUT_LOG" "$RUNDIR/$LOG_DIR"/PET*.esmApp.log 2>/dev/null | head -5 | sed 's/^/        /'
  else ok "nenhum marcador de erro fatal / abort MPI"; fi

  case "$VERDICT" in
    completed) ok "simulação concluída integralmente — coletivos por componente OK";;
    progress)  ok "1º passo de acoplamento completou os coletivos — SEM deadlock";;
    hang)      bad "PROVÁVEL DEADLOCK: processo vivo, sem progresso nos coletivos"; NFAIL=$((NFAIL+1)); _diag_tail;;
    initfail)  bad "parada ANTES de concluir a inicialização (não chegou ao passo 1)"; NFAIL=$((NFAIL+1)); _diag_tail;;
    crash)     bad "o executável ABORTOU antes de completar o 1º passo"; NFAIL=$((NFAIL+1))
               echo "        --- últimas linhas do stdout ---"; tail -8 "$STDOUT_LOG" 2>/dev/null | sed 's/^/        /';;
  esac

  # (5) A verificação que distingue sequential+split de concurrent+split.
  #     Só faz sentido se a execução chegou a avançar; num crash ou initfail
  #     não há janelas Run suficientes, e o resultado seria ruído.
  case "$VERDICT" in
    completed|progress)
      local ovline ov span_atm span_ocn
      if ! ovline="$(measure_overlap)" || [[ -z "$ovline" ]]; then
        warn "sobreposição ATM×OCN não medida (python3 ausente ou sem janelas Run nos logs)"
      else
        read -r ov span_atm span_ocn <<< "$ovline"
        log "janelas Run: ATM=${span_atm}s  OCN=${span_ocn}s  sobreposição=${ov}s"
        if awk -v o="$ov" -v t="$OVERLAP_TOL" 'BEGIN{exit !(o<=t)}'; then
          ok "ATM e OCN não se sobrepõem no tempo (${ov}s <= tolerância ${OVERLAP_TOL}s)"
        else
          bad "ATM e OCN SE SOBREPÕEM por ${ov}s (tolerância ${OVERLAP_TOL}s)"
          bad "  execução concorrente onde se esperava sequencial — conferir SetRunSequence"
          NFAIL=$((NFAIL+1))
        fi
      fi
      ;;
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
  echo "  Smoke test — SEQUENTIAL + SPLIT (&nuopc_petlayout, v14.20)"
  echo "============================================================="
  log "COUPLER_ROOT = $COUPLER_ROOT"
  log "experimento  = $RUNDIR"
  log "executável   = $EXE"
  log "PETs         = $NP  (ATM=$ATM | OCN=$OCN)"
  log "configuração = coupling_mode=sequential  pet_layout=split"
  log "encerra em   = $STEPS_TARGET passo(s) | timeout=${TIMEOUT}s | stall=${STALL}s"
  log "tolerância de sobreposição ATM×OCN = ${OVERLAP_TOL}s"
  echo ""

  load_environment
  detect_launcher
  log "lançador     = $LAUNCHER $LAUNCHER_ARGS"

  [[ -f "$BASE_INPUT" ]] || die "nuopc.input base não encontrado: $BASE_INPUT"
  gen_config sequential "$CFG" split
  log "config de teste: $CFG"

  # Com pet_layout=split o MPAS é decomposto em ATM partições, não em NP.
  # Sem o .part.$ATM correspondente o MPAS aborta na leitura da malha, e o
  # veredito sairia como "initfail" sem indicar a causa real.
  if ! compgen -G "$RUNDIR/x1.*.graph.info.part.$ATM" > /dev/null 2>&1; then
    warn "x1.*.graph.info.part.$ATM ausente em $RUNDIR"
    warn "  em split a partição METIS é dimensionada por --atm ($ATM), não por -n ($NP)"
    warn "  gere com: gen-metis.bash --parts $ATM"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""; log "--dry-run: comando que seria executado:"
    echo "    ( cd $RUNDIR && NUOPC_INPUT=$CFG $LAUNCHER $LAUNCHER_ARGS -n $NP $EXE )"
    echo ""; echo "--- grupo injetado em $CFG ---"; tail -7 "$CFG"
    KEEP=1; exit 0
  fi

  [[ -x "$EXE" ]] || die "executável não encontrado ou sem permissão: $EXE"

  if [[ "$DO_BASELINE" -eq 1 ]]; then
    echo ""; log "baseline sequential+shared (sanidade do binário)…"
    local seq_cfg="$RUNDIR/nuopc.input.sequential-$TAG"
    gen_config sequential "$seq_cfg" shared
    run_and_watch "$seq_cfg"
    case "$VERDICT" in
      completed|progress) ok "baseline sequential+shared avançou (binário funcional)";;
      *) warn "baseline sequential+shared não avançou (veredito=$VERDICT) — problema pode não ser do modo concurrent";;
    esac
    [[ "$KEEP" -eq 1 ]] || rm -f "$seq_cfg"
  fi

  echo ""; log "executando teste SEQUENTIAL + SPLIT…"
  run_and_watch "$CFG"
  analyze

  echo ""; echo "============================================================="
  if [[ "$NFAIL" -eq 0 ]]; then
    printf '%s  RESULTADO: PASSOU%s — sequential+split aplicado, sem deadlock e sem sobreposição\n' "$C_OK" "$C_0"
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
