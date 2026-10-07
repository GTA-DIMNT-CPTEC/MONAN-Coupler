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
#   1. Confere que a nuopc.input atual e a de PRODUCAO (atm_model=mpas,
#      ocn_model=mom6, ice_model=sis2, atm_boundary=med, pelas chaves por
#      modelo ou pelas antigas).
#   2. Gera nuopc.input.datm_mom6 a partir dela, trocando SO o modelo da
#      atmosfera para o DATM (atm_model='datm')
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

# Modelos e contorno, pelas chaves por modelo ou pelas antigas
# shellcheck source=chaves_nuopc.bash
source "${SCRIPT_DIR}/chaves_nuopc.bash"
modelos() { echo "atm_model=$(nuopc_modelo "$1" ATM) ocn_model=$(nuopc_modelo "$1" OCN)" \
                 "ice_model=$(nuopc_modelo "$1" ICE) atm_boundary=$(nuopc_modelo "$1" BND)"; }

log "1. Conferindo que a nuopc.input atual e a de PRODUCAO"
ATUAL=$(modelos "${NUOPC}")
info "${ATUAL}"
if [[ "${ATUAL}" != "atm_model=mpas ocn_model=mom6 ice_model=sis2 atm_boundary=med" ]]; then
  echo "" >&2
  echo "ERRO: a nuopc.input atual nao e a de producao esperada." >&2
  echo "      Esperado: atm_model=mpas ocn_model=mom6 ice_model=sis2 atm_boundary=med" >&2
  echo "      Instale a nuopc.input de producao antes de rodar este atalho." >&2
  exit 3
fi
info "producao confirmada"

log "2. Gerando ${VARIANTE} (troca so o modelo da atmosfera para o DATM)"
# Tira as linhas de atm_model e use_datm e escreve atm_model='datm' logo
# depois de &nuopc_mode (nuopc_troca_modelo); o resto fica igual.
nuopc_troca_modelo "${NUOPC}" "${VARIANTE}" ATM datm

# Confere que a troca pegou e que o resto continua DATM+MOM6.
GERADO=$(modelos "${VARIANTE}")
if [[ "${GERADO}" != "atm_model=datm ocn_model=mom6 ice_model=sis2 atm_boundary=med" ]]; then
  echo "ERRO: nao consegui trocar o modelo da atmosfera em ${VARIANTE} (${GERADO})." >&2
  echo "      Confira manualmente o grupo &nuopc_mode." >&2
  exit 4
fi
info "gerado: ${GERADO}"

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
