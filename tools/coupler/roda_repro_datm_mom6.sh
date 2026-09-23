#!/usr/bin/env bash
#===============================================================================
# roda_repro_datm_mom6.sh
#
# Atalho para o TESTE DECISIVO de reprodutibilidade: DATM + MOM6 + SIS2.
#
# Troca o MPAS por uma atmosfera de dados (DATM), mantendo oceano (MOM6), gelo
# (SIS2) e o mediador. Serve para separar duas hipoteses:
#   - se DATM+MOM6+SIS2 REPRODUZ bit a bit  -> a semente esta DENTRO do MPAS;
#   - se ainda DIVERGE                        -> a semente esta no oceano/gelo/FMS
#                                                ou no regrid do mediador.
#
# O que este atalho faz:
#   1. Confere que a nuopc.input atual e a de PRODUCAO (use_datm=.false.,
#      use_docn=.false., use_med_to_mpas=.true., use_sis2_dynamic=.true.).
#   2. Gera nuopc.input.datm_mom6 a partir dela, trocando SO use_datm p/ .true.
#      (a combinacao "DATM + MOM6" da tabela do proprio nuopc.input).
#   3. Faz backup da nuopc.input de producao e instala a datm_mom6 como ativa.
#   4. Roda o orquestrador roda_repro_producao.sh (duas rodadas + comparacao),
#      com rotulo de base proprio (datm-reproA-...), para nao confundir com a
#      base da producao.
#   5. RESTAURA a nuopc.input de producao no fim, mesmo se algo falhar (trap).
#
# Uso (de dentro do diretorio de experimento):
#   cd <diretorio_de_experimento>
#   bash <raiz_do_repo>/tools/coupler/roda_repro_datm_mom6.sh
#
# ATENCAO: o DATM aqui e o "JRA55 sintetico" do acoplador. Se a sua instalacao
# exigir um arquivo de dados de atmosfera ou um grupo &nuopc_datm que nao esteja
# presente, a rodada vai reclamar no log; nesse caso consulte a doc do acoplador
# sobre o modo DATM antes de repetir.
#===============================================================================

set -uo pipefail

RUNDIR="${PWD}"
NUOPC="${RUNDIR}/nuopc.input"
STAMP="$(date +%Y%m%d-%H%M%S)"
VARIANTE="${RUNDIR}/nuopc.input.datm_mom6"
BACKUP="${RUNDIR}/nuopc.input.prod.bak.${STAMP}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORQ="${SCRIPT_DIR}/roda_repro_producao.sh"

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }

[[ -f "${ORQ}" ]] || { echo "ERRO: nao encontrei o orquestrador em ${ORQ}." >&2; exit 2; }
[[ -r "${NUOPC}" ]] || { echo "ERRO: nao encontrei nuopc.input em ${RUNDIR}. Rode de dentro do diretorio de experimento." >&2; exit 2; }

# Le uma chave logica de um grupo namelist (ignora comentarios).
nml_val() { sed 's/!.*//' "${NUOPC}" | grep -iE "^[[:space:]]*$1[[:space:]]*=" \
            | head -1 | cut -d= -f2 | tr -d " '\"" ; }

log "1. Conferindo que a nuopc.input atual e a de PRODUCAO"
UD=$(nml_val use_datm); UO=$(nml_val use_docn)
UM=$(nml_val use_med_to_mpas); US=$(nml_val use_sis2_dynamic)
info "use_datm=${UD:-<ausente>}  use_docn=${UO:-<ausente>}  use_med_to_mpas=${UM:-<ausente>}  use_sis2_dynamic=${US:-<ausente>}"

shopt -s nocasematch
if [[ "${UD}" != *"false"* || "${UO}" != *"false"* || "${UM}" != *"true"* || "${US}" != *"true"* ]]; then
  shopt -u nocasematch
  echo "" >&2
  echo "ERRO: a nuopc.input atual nao e a de producao esperada." >&2
  echo "      Esperado: use_datm=.false., use_docn=.false., use_med_to_mpas=.true., use_sis2_dynamic=.true." >&2
  echo "      Instale a nuopc.input de producao antes de rodar este atalho." >&2
  exit 3
fi
shopt -u nocasematch
info "producao confirmada"

log "2. Gerando ${VARIANTE} (troca so use_datm -> .true.)"
# Troca APENAS a linha de atribuicao de use_datm (linhas de comentario comecam
# com '!' e nao casam a ancora ^[[:space:]]*use_datm=).
sed -E 's/^([[:space:]]*use_datm[[:space:]]*=[[:space:]]*)\.false\./\1.true./I' \
    "${NUOPC}" > "${VARIANTE}"

# Confere que a troca pegou e que o resto continua DATM+MOM6.
NUOPC_CHECK="${VARIANTE}" \
  && UD2=$(sed 's/!.*//' "${VARIANTE}" | grep -iE '^[[:space:]]*use_datm[[:space:]]*=' | head -1 | cut -d= -f2 | tr -d " '\"")
shopt -s nocasematch
if [[ "${UD2}" != *"true"* ]]; then
  shopt -u nocasematch
  echo "ERRO: nao consegui trocar use_datm para .true. em ${VARIANTE}." >&2
  echo "      Confira manualmente a linha use_datm no &nuopc_mode." >&2
  exit 4
fi
shopt -u nocasematch
info "gerado: use_datm=.true., use_docn=.false., use_med_to_mpas=.true., use_sis2_dynamic=.true."

log "3. Backup da producao e instalacao da variante DATM como ativa"
cp -p "${NUOPC}" "${BACKUP}"
info "backup: ${BACKUP}"

# Restaura a nuopc.input de producao ao sair, aconteca o que acontecer.
restaura() {
  if [[ -f "${BACKUP}" ]]; then
    cp -p "${BACKUP}" "${NUOPC}"
    info "nuopc.input de producao restaurada a partir de ${BACKUP}"
  fi
}
trap restaura EXIT

cp -p "${VARIANTE}" "${NUOPC}"
info "nuopc.input agora e a variante DATM+MOM6"

log "4. Rodando o orquestrador (duas rodadas + comparacao) no modo DATM+MOM6"
REPRO_LABEL_A="datm-reproA-${STAMP}" bash "${ORQ}"
RC=$?

log "5. Fim (a restauracao da nuopc.input de producao ocorre automaticamente)"
info "codigo do orquestrador: ${RC}"
info "a variante ficou salva em ${VARIANTE} (pode reaproveitar ou apagar)"
exit "${RC}"
