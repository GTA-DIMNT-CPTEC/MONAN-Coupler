#!/usr/bin/env bash
#===============================================================================
# roda_repro_producao.sh
#
# Revalidacao de reprodutibilidade bit a bit do caso de PRODUCAO
# (MPAS + MOM6 + SIS2, concurrent + split, 72 PETs) com o binario pristine ja
# corrigido no startTimeStamp (len=StrKIND).
#
# Este script e um ORQUESTRADOR FINO: ele nao reimplementa a comparacao. Ele
# usa a maquina de linha de base que ja existe no repositorio:
#
#   tools/dev/cria-linha-base.bash    congela as saidas de uma rodada
#   tools/dev/compara-linha-base.bash compara a rodada atual contra a base,
#                                     com nccmp -d (compara DADOS, nao bytes;
#                                     trata o carimbo de tempo no cabecalho dos
#                                     NetCDF, que faria um diff/cmp falhar)
#   tools/dev/set-nccmp-jaci.bash     carrega os modulos do nccmp na jaci
#
# A unica coisa que essas ferramentas nao cobrem e o ocean.stats e o
# seaice.stats. Esses textos sao a checagem de estado mais robusta e
# independente de layout, entao o script acrescenta um diff exato deles.
#
# Fluxo:
#   1. Confere que a nuopc.input ativa e a de producao (nao a solo/DOCN).
#   2. Garante o nccmp no PATH (via set-nccmp-jaci.bash se preciso).
#   3. Roda A, congela A com cria-linha-base.bash, guarda os stats de A.
#   4. Limpa as saidas, roda B.
#   5. Compara B contra a base A com compara-linha-base.bash (veredito NetCDF)
#      e faz o diff dos stats de A x B.
#   6. Veredito combinado.
#
# Por que rodar A e B na sequencia funciona: o run_esmApp.jaci, chamado no no de
# login, faz qsub e BLOQUEIA fazendo polling do qstat ate o job terminar. Entao
# a rodada B so comeca depois de A terminar de verdade.
#
# ONDE FICA E DE ONDE RODAR:
#   Guardado no repositorio em tools/coupler/ (ao lado de test-concurrent.bash).
#   EXECUTADO de dentro do diretorio de experimento (onde estao nuopc.input,
#   INPUT/, run_esmApp.jaci). Ele se acha sozinho pela propria localizacao.
#
#   cd <diretorio_de_experimento>
#   bash <caminho_do_repo>/tools/coupler/roda_repro_producao.sh
#===============================================================================

set -uo pipefail

#------------------------------- CONFIG ----------------------------------------
NPES=72                                    # 64 atm + 4 ocn + 4 ice = 72
WALLTIME="01:00:00"                         # ajuste ao tempo real do caso
RUN_CMD_DEFAULT=(bash run_esmApp.jaci -n "${NPES}" -w "${WALLTIME}")

# Comando de lancamento. Se run_esmApp.jaci nao estiver no diretorio atual,
# tenta o do repositorio (run/). Pode ser sobrescrito exportando RUN_CMD.
RUNDIR="${PWD}"
NUOPC="${RUNDIR}/nuopc.input"

# Arquivos de estatistica (checagem exata, independente de layout).
STATS_FILES=(ocean.stats seaice.stats)

# Diretorios de SAIDA do acoplador, limpos antes da rodada A (pre-limpeza).
OUT_DIRS=(diag_import diag_export logs RESTART)
# Globs de saida do MPAS na raiz do diretorio, seguros de remover na pre-limpeza
# (sao saidas, nunca entradas): o stream 'diagnostics', os logs por tarefa e o
# .pbs gerado. A limpeza entre A e B nao depende desta lista (usa a foto do
# estado inicial), mas ela garante que a rodada A comece limpa.
OUT_GLOBS=('MONAN_DIAG_*.nc' 'log.atmosphere.*' 'esmApp-integrado.pbs')

# Rotulos com carimbo de tempo, para nao colidir com uma base ja existente.
# REPRO_LABEL_A pode ser exportado por um script chamador (ex.: o atalho do
# DATM+MOM6) para distinguir as bases de configuracoes diferentes.
STAMP="$(date +%Y%m%d-%H%M%S)"
LABEL_A="${REPRO_LABEL_A:-reproA-${STAMP}}"
# Onde guardo os stats de A (as ferramentas de base nao congelam stats).
STATS_A_DIR="${RUNDIR}/repro-stats-${LABEL_A}"

# Foto do estado inicial do diretorio (nomes de topo = entradas a preservar).
# Fica fora do RUNDIR para nao aparecer nas listagens.
INICIAL_LIST="$(mktemp)"
trap 'rm -f "${INICIAL_LIST}"' EXIT
#-------------------------------------------------------------------------------

# Localiza este script e, a partir dele, a raiz do repositorio e os utilitarios.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tools/coupler/<este script>  ->  raiz = ../../
COUPLER_ROOT="${COUPLER_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
DEV_DIR="${SCRIPT_DIR}/../dev"
CRIA="${DEV_DIR}/cria-linha-base.bash"
COMPARA="${DEV_DIR}/compara-linha-base.bash"
SET_NCCMP="${DEV_DIR}/set-nccmp-jaci.bash"
RUN_ESMAPP_REPO="${COUPLER_ROOT}/run/run_esmApp.jaci"

# Monta o comando de lancamento.
if [[ -n "${RUN_CMD:-}" ]]; then
  # RUN_CMD exportado como string; converte em array.
  read -r -a RUN_CMD_ARR <<< "${RUN_CMD}"
elif [[ -f "${RUNDIR}/run_esmApp.jaci" ]]; then
  RUN_CMD_ARR=("${RUN_CMD_DEFAULT[@]}")
elif [[ -f "${RUN_ESMAPP_REPO}" ]]; then
  RUN_CMD_ARR=(bash "${RUN_ESMAPP_REPO}" -n "${NPES}" -w "${WALLTIME}")
else
  RUN_CMD_ARR=("${RUN_CMD_DEFAULT[@]}")
fi

# Acumulador de falhas (0 = tudo reprodutivel).
FALHAS=0

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   \033[32mPASSOU\033[0m  %s\n' "$*"; }
bad()  { printf '   \033[31mFALHOU\033[0m  %s\n' "$*"; FALHAS=$((FALHAS+1)); }

#------------------------------------------------------------------------------
# 0) Pre-condicoes: utilitarios do repositorio existem.
#------------------------------------------------------------------------------
log "0. Pre-condicoes"
for u in "${CRIA}" "${COMPARA}"; do
  if [[ ! -f "${u}" ]]; then
    echo "ERRO: nao encontrei ${u}." >&2
    echo "      Este script espera estar em tools/coupler/ do repositorio, com" >&2
    echo "      tools/dev/ ao lado. Ajuste DEV_DIR se a arvore for diferente." >&2
    exit 2
  fi
done
info "cria-linha-base.bash    : ${CRIA}"
info "compara-linha-base.bash : ${COMPARA}"
info "COUPLER_ROOT            : ${COUPLER_ROOT}"
info "comando de rodada       : ${RUN_CMD_ARR[*]}"

# nccmp e' exigido pelo compara-linha-base.bash, mas SO' na hora de comparar.
# IMPORTANTE: NAO carregamos os modulos do nccmp aqui. O set-nccmp-jaci.bash faz
# 'module purge' e recarrega netcdf/hdf5, o que POLUI o shell que submete a
# rodada e quebra o ambiente que o run_esmApp.jaci monta no PBS (exit=127 no
# boot). O nccmp e' carregado mais adiante, DENTRO de um subshell, apenas para a
# comparacao, depois que as duas rodadas ja terminaram. Aqui so avisamos.
if command -v nccmp >/dev/null 2>&1; then
  info "nccmp: ja disponivel no PATH"
elif [[ -f "${SET_NCCMP}" ]]; then
  info "nccmp: sera carregado na etapa de comparacao (via ${SET_NCCMP}, em subshell)"
else
  info "nccmp: ausente e sem set-nccmp-jaci.bash; a comparacao de NetCDF pode falhar"
fi

#------------------------------------------------------------------------------
# 1) Guarda de configuracao: so faz sentido revalidar o caso certo.
#------------------------------------------------------------------------------
log "1. Conferindo a nuopc.input (${NUOPC})"
if [[ ! -r "${NUOPC}" ]]; then
  echo "ERRO: nao encontrei nuopc.input em ${RUNDIR}." >&2
  echo "      Rode este script de dentro do diretorio de experimento." >&2
  exit 2
fi

nml_val() { sed 's/!.*//' "${NUOPC}" | grep -iE "^[[:space:]]*$1[[:space:]]*=" \
            | head -1 | cut -d= -f2 | tr -d " '\"" ; }

USE_DOCN=$(nml_val use_docn)
USE_MED=$(nml_val use_med_to_mpas)
USE_SIS2=$(nml_val use_sis2_dynamic)
CMODE=$(nml_val coupling_mode)
PLAYOUT=$(nml_val pet_layout)

info "use_docn         = ${USE_DOCN:-<ausente>}   (esperado .false.)"
info "use_med_to_mpas  = ${USE_MED:-<ausente>}   (esperado .true.)"
info "use_sis2_dynamic = ${USE_SIS2:-<ausente>}   (esperado .true.)"
info "coupling_mode    = ${CMODE:-<ausente>}   (esperado concurrent)"
info "pet_layout       = ${PLAYOUT:-<ausente>}   (esperado split)"

shopt -s nocasematch
if [[ "${USE_DOCN}" != *"false"* || "${USE_MED}" != *"true"* || "${USE_SIS2}" != *"true"* ]]; then
  shopt -u nocasematch
  echo "" >&2
  echo "ERRO: a nuopc.input ativa NAO e a de producao (MPAS+MOM6+SIS2)." >&2
  echo "      Isto parece a config solo/DOCN, que trava no passo 2." >&2
  echo "      Copie a nuopc.input de producao por cima da ativa e rode de novo." >&2
  exit 3
fi
shopt -u nocasematch
ok "configuracao de producao confirmada"

#------------------------------------------------------------------------------
# Funcoes auxiliares.
#------------------------------------------------------------------------------
# Pre-limpeza (antes da rodada A): remove saidas conhecidas do acoplador e do
# MPAS por nome/glob. So padroes que sao inequivocamente SAIDA.
pre_limpa() {
  local d f g
  for d in "${OUT_DIRS[@]}"; do
    [[ -e "${RUNDIR}/${d}" ]] && rm -rf "${RUNDIR:?}/${d}"
  done
  for f in "${STATS_FILES[@]}"; do
    [[ -f "${RUNDIR}/${f}" ]] && rm -f "${RUNDIR}/${f}"
  done
  for g in "${OUT_GLOBS[@]}"; do
    # nullglob local para o glob sumir se nao casar nada
    ( shopt -s nullglob; for f in "${RUNDIR}"/${g}; do rm -rf "${f}"; done )
  done
}

# Fotografa os nomes de topo presentes agora (as ENTRADAS a preservar).
snapshot_inicial() {
  ( cd "${RUNDIR}" && ls -1A ) | sort > "${INICIAL_LIST}"
}

# Limpeza entre A e B: remove TUDO que a rodada A criou, ou seja, qualquer nome
# de topo que nao estava na foto inicial, exceto a nossa contabilidade
# (baseline*, repro-stats-*). Assim a rodada B comeca igual a A, sem depender de
# conhecer os nomes de saida do MPAS. Entradas (na foto) nunca sao tocadas.
limpa_para_B() {
  local nome
  while IFS= read -r nome; do
    [[ -z "${nome}" ]] && continue
    grep -qxF "${nome}" "${INICIAL_LIST}" && continue   # estava no inicio: entrada
    case "${nome}" in
      baseline*|repro-stats-*) continue ;;              # nossa contabilidade
    esac
    rm -rf "${RUNDIR:?}/${nome}"
  done < <( cd "${RUNDIR}" && ls -1A | sort )
}

guarda_stats() {  # $1 = diretorio destino
  local dest="$1" f
  mkdir -p "${dest}"
  for f in "${STATS_FILES[@]}"; do
    [[ -f "${RUNDIR}/${f}" ]] && cp -p "${RUNDIR}/${f}" "${dest}/"
  done
  # Guarda tambem os MONAN_DIAG (estado atmosferico do MPAS na malha nativa),
  # para comparar A x B: se divergirem, o estado do MPAS diverge no acoplado.
  mkdir -p "${dest}/MONAN_DIAG"
  ( shopt -s nullglob; for f in "${RUNDIR}"/MONAN_DIAG_*.nc; do cp -p "${f}" "${dest}/MONAN_DIAG/"; done )
}

conta_export() {  # numero de NetCDF de exportacao (sinal de rodada bem-sucedida)
  find "${RUNDIR}/diag_export" -maxdepth 1 -type f \
       -name 'monan_export_????????_??????.nc' 2>/dev/null | wc -l
}

#------------------------------------------------------------------------------
# 2) Rodada A + congelamento da linha de base.
#------------------------------------------------------------------------------
log "2. Rodada A (limpando saidas antigas antes)"
pre_limpa
snapshot_inicial
info "estado inicial fotografado ($(wc -l < "${INICIAL_LIST}") entradas de topo a preservar)"
info "lancando: ${RUN_CMD_ARR[*]}"
"${RUN_CMD_ARR[@]}"
RC_A=$?
info "run_esmApp.jaci (A) retornou codigo ${RC_A}"

# Aborto barato: se A nao gerou diag_export/, nao adianta congelar nem rodar B.
if [[ "$(conta_export)" -eq 0 ]]; then
  echo "" >&2
  echo "ERRO: a rodada A nao gerou diag_export/monan_export_*.nc (codigo ${RC_A})." >&2
  echo "      A rodada nao chegou ao fim. NAO vou submeter a B nem comparar." >&2
  echo "      Verifique o motivo em: logs/esmApp_run.log e logs/PET*.esmApp.log" >&2
  echo "      Se aparecer exit=127 no boot, e problema de modulos/ambiente:" >&2
  echo "      rode o run_esmApp.jaci de um shell LIMPO (sem module purge antes)." >&2
  exit 4
fi

log "2b. Congelando a linha de base ${LABEL_A}"
bash "${CRIA}" -l "${LABEL_A}" -r "${COUPLER_ROOT}" \
     -d "Revalidacao repro producao (MPAS+MOM6+SIS2, concurrent+split, ${NPES} PETs), binario com startTimeStamp corrigido - rodada A"
RC_CRIA=$?
if [[ "${RC_CRIA}" -ne 0 ]]; then
  bad "cria-linha-base.bash falhou (codigo ${RC_CRIA}); a rodada A nao terminou bem?"
fi
guarda_stats "${STATS_A_DIR}"
info "stats de A guardados em ${STATS_A_DIR}"

#------------------------------------------------------------------------------
# 3) Rodada B (identica), na sequencia.
#------------------------------------------------------------------------------
log "3. Rodada B (removendo tudo que A criou; A ja esta congelada)"
limpa_para_B
info "diretorio restaurado ao estado inicial (entradas + baseline/ + repro-stats-*)"
info "lancando: ${RUN_CMD_ARR[*]}"
"${RUN_CMD_ARR[@]}"
RC_B=$?
info "run_esmApp.jaci (B) retornou codigo ${RC_B}"

# Aborto barato: se B nao gerou diag_export/, nao ha o que comparar.
if [[ "$(conta_export)" -eq 0 ]]; then
  echo "" >&2
  echo "ERRO: a rodada B nao gerou diag_export/monan_export_*.nc (codigo ${RC_B})." >&2
  echo "      Nao ha o que comparar. Verifique logs/esmApp_run.log." >&2
  echo "      A linha de base da rodada A ficou em baseline/${LABEL_A}." >&2
  exit 4
fi

if [[ "${RC_A}" -ne 0 || "${RC_B}" -ne 0 ]]; then
  echo "" >&2
  echo "AVISO: ao menos uma rodada nao retornou 0, mas ambas geraram saida." >&2
  echo "       A comparacao segue; confira logs/esmApp_run.log se estranhar algo." >&2
fi

#------------------------------------------------------------------------------
# 4) Comparacoes A x B.
#------------------------------------------------------------------------------
log "4a. NetCDF (diag_export + diag_import) via compara-linha-base.bash"
# compara-linha-base compara o diretorio ATUAL (rodada B) contra a base A.
# Exige identidade exata dos dados (sem -t). Sai 0=PASS, 1=FAIL, 2=erro.
#
# nccmp e' carregado AQUI, dentro de um subshell, para nao poluir o ambiente do
# script (as rodadas ja terminaram). O 'module purge' do set-nccmp-jaci.bash
# fica confinado ao subshell e some ao fechar o parentese.
(
  if ! command -v nccmp >/dev/null 2>&1 && [[ -f "${SET_NCCMP}" ]]; then
    # shellcheck disable=SC1090
    source "${SET_NCCMP}" >/dev/null 2>&1 || true
  fi
  bash "${COMPARA}" -l "${LABEL_A}"
)
RC_CMP=$?
case "${RC_CMP}" in
  0) ok "NetCDF: B reproduz a linha de base A (nccmp -d)" ;;
  1) bad "NetCDF: B NAO reproduz a linha de base A (veja o relatorio acima)" ;;
  *) bad "NetCDF: compara-linha-base.bash retornou erro ${RC_CMP} (nccmp/base?)" ;;
esac

log "4b. ocean.stats e seaice.stats (checagem exata, independente de layout)"
for f in "${STATS_FILES[@]}"; do
  fa="${STATS_A_DIR}/${f}"; fb="${RUNDIR}/${f}"
  if [[ -f "${fa}" && -f "${fb}" ]]; then
    if diff -q "${fa}" "${fb}" >/dev/null; then
      ok "${f} identico bit a bit"
    else
      bad "${f} difere. Primeiras linhas divergentes:"
      diff "${fa}" "${fb}" | head -20 | sed 's/^/      /'
    fi
  else
    info "${f} ausente em A ou em B (pulado)"
  fi
done

log "4c. MONAN_DIAG (estado atmosferico do MPAS) A x B via nccmp -d"
# Sinaliza se o proprio MPAS diverge dentro do acoplado. Nao e isolamento puro
# (a partir da 1a hora o MPAS recebe realimentacao do oceano), mas se ja o
# primeiro MONAN_DIAG pos-inicial diferir, o estado do MPAS diverge cedo.
(
  if ! command -v nccmp >/dev/null 2>&1 && [[ -f "${SET_NCCMP}" ]]; then
    # shellcheck disable=SC1090
    source "${SET_NCCMP}" >/dev/null 2>&1 || true
  fi
  command -v nccmp >/dev/null 2>&1 || { echo "SEM_NCCMP"; exit 0; }
  n=0; difs=0
  for fa in "${STATS_A_DIR}"/MONAN_DIAG/MONAN_DIAG_*.nc; do
    [[ -e "${fa}" ]] || continue
    base=$(basename "${fa}"); fb="${RUNDIR}/${base}"; n=$((n+1))
    [[ -f "${fb}" ]] || { echo "SO_EM_A ${base}"; difs=$((difs+1)); continue; }
    nccmp -d -f -q "${fa}" "${fb}" >/dev/null 2>&1 || { echo "DIFERE ${base}"; difs=$((difs+1)); }
  done
  echo "RESUMO ${n} ${difs}"
) | tee /tmp/_repro_diag_cmp.$$ | grep -vE '^RESUMO' | sed 's/^/   /'
_dlin=$(grep '^RESUMO' /tmp/_repro_diag_cmp.$$ | tail -1)
if grep -q '^SEM_NCCMP' /tmp/_repro_diag_cmp.$$; then
  info "MONAN_DIAG: nccmp indisponivel; comparacao pulada"
else
  _dn=$(echo "${_dlin}" | awk '{print $2}'); _dd=$(echo "${_dlin}" | awk '{print $3}')
  if [[ "${_dn:-0}" -eq 0 ]]; then
    info "MONAN_DIAG: nenhum arquivo guardado de A (a rodada gravou MONAN_DIAG?)"
  elif [[ "${_dd:-0}" -eq 0 ]]; then
    ok "MONAN_DIAG: ${_dn} arquivo(s) identicos (estado do MPAS reproduz no acoplado)"
  else
    bad "MONAN_DIAG: ${_dd}/${_dn} diferem (estado atmosferico do MPAS diverge no acoplado)"
  fi
fi
rm -f /tmp/_repro_diag_cmp.$$

#------------------------------------------------------------------------------
# 5) Veredito combinado.
#------------------------------------------------------------------------------
log "5. Veredito"
if [[ "${FALHAS}" -eq 0 ]]; then
  printf '   \033[32mREPRODUTIVEL\033[0m: nenhuma camada acusou diferenca entre A e B.\n'
  info "Linha de base A : ${COUPLER_ROOT:+}baseline/${LABEL_A}  (relativo ao diretorio de experimento)"
  info "Stats de A      : ${STATS_A_DIR}"
  exit 0
else
  printf '   \033[31mNAO REPRODUTIVEL\033[0m: %d camada(s) acusaram diferenca.\n' "${FALHAS}"
  info "Leitura: se os stats (ocean.stats/seaice.stats) baterem e so o NetCDF de"
  info "diagnostico por passo diferir, o ESTADO e identico e o nao determinismo"
  info "esta no escritor de diagnostico (gather/regrid), nao no acoplamento."
  info "Se os proprios stats divergirem, a raiz sobrevive ao conserto do"
  info "startTimeStamp: volte ao make_exchange_reproduce=.true. e ao isolamento"
  info "DATM+MOM6 (ver roteiro-reprodutibilidade.md)."
  info "Linha de base A : baseline/${LABEL_A}   Stats de A: ${STATS_A_DIR}"
  exit 1
fi
