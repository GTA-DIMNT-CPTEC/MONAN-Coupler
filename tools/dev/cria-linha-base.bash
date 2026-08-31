#!/usr/bin/env bash
# =============================================================================
# cria-linha-base.bash — congela uma rodada de referência do MONAN-Coupler
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Guarda, em baseline/<rótulo>/, tudo o que é preciso para reproduzir uma
# rodada e comparar rodadas futuras contra ela:
#
#   MANIFEST.txt   commits, ambiente, topologia, data e responsável
#   config/        nuopc.input e demais namelists usados
#   entrada/       lista de arquivos de entrada com soma de verificação
#   saida/         monan_export_*.nc, mom6_import_*.nc, mpas_import_*.nc
#   logs/          logs/PET0.esmApp.log e o log de execução
#   SHA256SUMS     soma de verificação de tudo o que foi guardado
#
# Este script NÃO executa o modelo: ele congela o resultado de uma execução
# que já terminou com sucesso no diretório atual. Rode-o logo após a rodada,
# de dentro do diretório de experimento.
#
# Uso:
#   cria-linha-base.bash -l L-01 -d "DATM + DOCN, sequential, shared, 4 PETs"
#   cria-linha-base.bash -l L-04 -d "..." -o /p/projetos/gta/.../baseline
#
# Convenção de rótulos: ver a seção "Linha de base" do documento de proposta.
# =============================================================================

set -euo pipefail

# ── Argumentos ───────────────────────────────────────────────────────────────
ROTULO=""
DESCRICAO=""
BASE_DIR="baseline"
COUPLER_ROOT="${COUPLER_ROOT:-}"

_uso() {
  cat << 'EOF'

cria-linha-base.bash — congela uma rodada de referência

  -l RÓTULO      obrigatório. Ex.: L-01, L-04
  -d "TEXTO"     descrição em uma linha (aparece no MANIFEST)
  -o DIRETÓRIO   raiz das linhas de base (padrão: ./baseline)
  -r DIRETÓRIO   raiz do MONAN-Coupler (padrão: $COUPLER_ROOT)
  -h             esta mensagem

Rode de dentro do diretório de experimento, logo após uma execução
concluída com sucesso.

EOF
}

while getopts ":l:d:o:r:h" opt; do
  case "${opt}" in
    l) ROTULO="${OPTARG}" ;;
    d) DESCRICAO="${OPTARG}" ;;
    o) BASE_DIR="${OPTARG}" ;;
    r) COUPLER_ROOT="${OPTARG}" ;;
    h) _uso; exit 0 ;;
    \?) echo "ERRO: opção inválida: -${OPTARG}" >&2; _uso; exit 2 ;;
    :)  echo "ERRO: a opção -${OPTARG} exige argumento" >&2; exit 2 ;;
  esac
done

[[ -z "${ROTULO}" ]] && { echo "ERRO: informe o rótulo com -l" >&2; _uso; exit 2; }

if [[ -z "${COUPLER_ROOT}" ]]; then
  echo "ERRO: COUPLER_ROOT não definido. Use -r ou exporte a variável." >&2
  exit 2
fi

DESTINO="${BASE_DIR}/${ROTULO}"

# ── Pré-condições ────────────────────────────────────────────────────────────
if [[ -e "${DESTINO}" ]]; then
  echo "ERRO: ${DESTINO} já existe." >&2
  echo "      Uma linha de base não é sobrescrita: arquive a antiga antes." >&2
  exit 1
fi

if [[ ! -f nuopc.input ]]; then
  echo "ERRO: nuopc.input não encontrado. Rode de dentro do diretório de experimento." >&2
  exit 1
fi

_n_export=$(ls diag_export/monan_export_????????_??????.nc 2>/dev/null | wc -l)
if [[ "${_n_export}" -eq 0 ]]; then
  echo "ERRO: nenhum arquivo em diag_export/. A rodada terminou com sucesso?" >&2
  exit 1
fi

# ── Estrutura ────────────────────────────────────────────────────────────────
mkdir -p "${DESTINO}"/{config,entrada,saida,logs}

# ── MANIFEST ─────────────────────────────────────────────────────────────────
MANIFEST="${DESTINO}/MANIFEST.txt"

_git_ref() {
  # $1 = caminho do repositório; imprime "<hash> (<branch>)" ou "-"
  local dir="$1" hash branch
  if [[ -d "${dir}/.git" || -f "${dir}/.git" ]]; then
    hash=$(git -C "${dir}" rev-parse HEAD 2>/dev/null || echo '-')
    branch=$(git -C "${dir}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')
    printf '%s (%s)' "${hash}" "${branch}"
  else
    printf '%s' '-'
  fi
}

_sujo() {
  local dir="$1"
  if [[ -d "${dir}/.git" || -f "${dir}/.git" ]]; then
    if [[ -n "$(git -C "${dir}" status --porcelain 2>/dev/null)" ]]; then
      printf 'SIM — árvore de trabalho com alterações não gravadas'
    else
      printf 'não'
    fi
  else
    printf '-'
  fi
}

_nuopc_get() {
  # Lê um parâmetro do nuopc.input, ignorando comentários.
  sed 's/!.*//' nuopc.input \
    | grep -iE "^[[:space:]]*$1[[:space:]]*=" \
    | head -1 | cut -d= -f2 | tr -d " '\"" || true
}

{
  echo "==============================================================="
  echo " LINHA DE BASE — MONAN-Coupler"
  echo "==============================================================="
  echo "Rótulo       : ${ROTULO}"
  echo "Descrição    : ${DESCRICAO:-(não informada)}"
  echo "Criada em    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Responsável  : ${USER:-$(id -un)}@$(hostname)"
  echo "Experimento  : $(pwd)"
  echo ""
  echo "--- Versões do código -----------------------------------------"
  echo "MONAN-Coupler   : $(_git_ref "${COUPLER_ROOT}")"
  echo "  árvore suja   : $(_sujo "${COUPLER_ROOT}")"
  echo "MONAN-Model     : $(_git_ref "${COUPLER_ROOT}/models/atmos/MONAN-Model")"
  echo "MOM6-examples   : $(_git_ref "${COUPLER_ROOT}/models/ocean/MOM6-examples")"
  echo ""
  echo "--- Ambiente --------------------------------------------------"
  echo "Compilador      : $( (ftn --version 2>/dev/null || gfortran --version 2>/dev/null) | head -1)"
  echo "ESMFMKFILE      : ${ESMFMKFILE:-(não definido)}"
  echo "MPAS_DIR        : ${MPAS_DIR:-(não definido)}"
  echo "MOM6_LIBDIR     : ${MOM6_LIBDIR:-(não definido)}"
  echo ""
  echo "Módulos carregados:"
  if command -v module >/dev/null 2>&1; then
    module list 2>&1 | sed 's/^/  /'
  else
    echo "  (comando module indisponível neste shell)"
  fi
  echo ""
  echo "--- Configuração da rodada ------------------------------------"
  echo "start_date      : $(_nuopc_get start_date)"
  echo "stop_date       : $(_nuopc_get stop_date)"
  echo "dt_coupling     : $(_nuopc_get dt_coupling)"
  echo "dt_atm          : $(_nuopc_get dt_atm)"
  echo "use_datm        : $(_nuopc_get use_datm)"
  echo "use_docn        : $(_nuopc_get use_docn)"
  echo "coupling_mode   : $(_nuopc_get coupling_mode)"
  echo "pet_layout      : $(_nuopc_get pet_layout)"
  echo "atm_pet_count   : $(_nuopc_get atm_pet_count)"
  echo "ocn_pet_count   : $(_nuopc_get ocn_pet_count)"
  echo ""
  echo "--- Binário ---------------------------------------------------"
  if [[ -f "${COUPLER_ROOT}/bin/esmApp" ]]; then
    echo "esmApp          : $(ls -l --time-style=long-iso "${COUPLER_ROOT}/bin/esmApp" | awk '{print $5" bytes  "$6" "$7}')"
    echo "sha256          : $(sha256sum "${COUPLER_ROOT}/bin/esmApp" | cut -d' ' -f1)"
  else
    echo "esmApp          : não encontrado em ${COUPLER_ROOT}/bin/"
  fi
  echo ""
  echo "--- Saída congelada -------------------------------------------"
  echo "monan_export_*.nc : ${_n_export} arquivo(s)"
  echo "mom6_import_*.nc  : $(ls diag_import/mom6_import_*.nc 2>/dev/null | wc -l) arquivo(s)"
  echo "mpas_import_*.nc  : $(ls diag_import/mpas_import_*.nc 2>/dev/null | wc -l) arquivo(s)"
  echo "==============================================================="
} > "${MANIFEST}"

# ── Configuração ─────────────────────────────────────────────────────────────
cp -p nuopc.input "${DESTINO}/config/"
for f in namelist.atmosphere streams.atmosphere namelist.ocn input.nml MOM_input SIS_input; do
  [[ -f "${f}" ]] && cp -p "${f}" "${DESTINO}/config/"
done

# ── Entradas: soma de verificação, sem copiar (arquivos grandes) ─────────────
{
  echo "# Arquivos de entrada da rodada ${ROTULO}"
  echo "# Não copiados por tamanho; verificar por soma antes de reproduzir."
  echo ""
  for f in *.nc INPUT/*.nc; do
    [[ -f "${f}" ]] || continue
    printf '%s  %12s  %s\n' \
      "$(sha256sum "${f}" | cut -d' ' -f1)" "$(stat -c%s "${f}")" "${f}"
  done
} > "${DESTINO}/entrada/CHECKSUMS.txt" 2>/dev/null || true

# ── Saída ────────────────────────────────────────────────────────────────────
cp -p diag_export/monan_export_????????_??????.nc "${DESTINO}/saida/" 2>/dev/null || true
cp -p diag_import/mom6_import_????????_??????.nc  "${DESTINO}/saida/" 2>/dev/null || true
cp -p diag_import/mpas_import_????????_??????.nc  "${DESTINO}/saida/" 2>/dev/null || true

# ── Logs ─────────────────────────────────────────────────────────────────────
[[ -f logs/PET0.esmApp.log ]] && cp -p logs/PET0.esmApp.log "${DESTINO}/logs/"
[[ -f logs/esmApp_run.log  ]] && cp -p logs/esmApp_run.log  "${DESTINO}/logs/"

# ── Soma de verificação do conjunto ──────────────────────────────────────────
( cd "${DESTINO}" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )

# ── Proteção contra alteração acidental ──────────────────────────────────────
chmod -R a-w "${DESTINO}"

echo ""
echo "==============================================================="
echo " Linha de base ${ROTULO} criada em ${DESTINO}"
echo "==============================================================="
echo " Arquivos de saída : $(ls "${DESTINO}/saida" | wc -l)"
echo " Tamanho total     : $(du -sh "${DESTINO}" | cut -f1)"
echo " Somente leitura   : sim (chmod a-w aplicado)"
echo ""
echo " Confira o MANIFEST antes de aceitar a linha de base:"
echo "   cat ${MANIFEST}"
echo ""
echo " Em especial, o campo 'árvore suja'. Uma linha de base criada a"
echo " partir de uma árvore com alterações não gravadas não é reprodutível."
echo "==============================================================="
