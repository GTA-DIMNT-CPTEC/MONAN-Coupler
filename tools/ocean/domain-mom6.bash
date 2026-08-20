#!/bin/bash
# =============================================================================
# domain-mom6.bash — Divisão de domínio (domain decomposition) do MOM6+SIS2.
# Calcula um LAYOUT (NIPROC × NJPROC) equilibrado e gera o mask_table do FMS,
# eliminando os blocos 100% terra (land tiles) — reduzindo os PETs efetivos
# que o componente oceânico exige no acoplador NUOPC/ESMF.
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# IMPLEMENTAÇÃO 100% SHELL (sem Python): a leitura do array de topografia é
# delegada ao 'ncdump' (do módulo cray-netcdf) e o mascaramento é feito em
# 'awk' (POSIX). Não há dependência de numpy/netCDF4.
#
# CONTEXTO
#   No MOM6 o domínio horizontal é fatiado em NIPROC×NJPROC blocos (LAYOUT).
#   Como boa parte da grade é continente, muitos blocos são totalmente terra
#   e não precisam de PE. O FMS lê um mask_table que lista esses blocos; assim
#   os PETs efetivos = NIPROC*NJPROC − (blocos mascarados). É esse número que
#   o componente MOM6+SIS2 exige em PETs.
#
#   O acoplador pode rodar em mais de uma arquitetura de PETs, escolhida por
#   pet_layout em &nuopc_petlayout (nuopc.input). Repare que o que decide é o
#   LAYOUT, não o coupling_mode: desde a v14.20 os dois eixos são independentes,
#   e sequential+split também dá ao OCN apenas a sua fatia.
#     - pet_layout='shared': os MESMOS PETs do run servem à atmosfera e ao
#       oceano; nesse caso, EFF deve igualar o TOTAL de PETs (-n) do run.
#     - pet_layout='split' (split de comunicador): o total de PETs é dividido
#       entre MONAN-A e MOM6+SIS2 (ex.: -n 256 = 128 PETs ATM + 128 PETs OCN);
#       nesse caso, EFF deve igualar apenas ocn_pet_count, a FATIA alocada ao
#       OCN, não o total do run.
#   Este script não sabe qual arquitetura está em uso — quem chama --target-eff
#   deve informar o N correspondente aos PETs que o OCN vai efetivamente
#   receber (o total do run, se shared; ocn_pet_count, se split).
#   Um LAYOUT/mask_table cujo EFF não bate com os PETs recebidos pelo OCN
#   produz o erro fatal do FMS:
#     "fms2_io(parse_mask_table_2d): mpp_npes() .NE. layout(1)*layout(2) - nmask"
#   O modo --target-eff (abaixo) automatiza a busca por um LAYOUT que evita
#   exatamente esse erro.
#
# USO (a partir de qualquer diretório):
#   bash domain-mom6.bash --topog ARQ.nc (--pes N | --layout NI,NJ | --target-eff N) [OPÇÕES]
#
# OPÇÕES:
#   --topog ARQ.nc      (obrigatório) ocean_topog.nc (ou ocean_mask.nc) com o
#                       campo de profundidade/máscara. As dimensões da grade
#                       (NI_G, NJ_G) são lidas deste arquivo.
#   --pes N             Nº de blocos (NIPROC*NJPROC) desejado. O script fatora N
#                       e sugere o LAYOUT mais equilibrado (blocos quadrados).
#   --layout NI,NJ      LAYOUT explícito (NIPROC,NJPROC). Tem prioridade sobre
#                       --pes; não combina com --target-eff.
#   --target-eff N      Busca automaticamente um LAYOUT cujo EFF (PETs efetivos,
#                       já descontada a máscara) seja EXATAMENTE N. Varre
#                       --pes N, N+1, N+2, ... (até --search-range tentativas),
#                       pois o nº de blocos mascarados depende da FORMA do
#                       LAYOUT, não só do produto NIPROC*NJPROC. Use N = PETs
#                       que o OCN vai efetivamente receber: o total do run
#                       (-n), se pet_layout='shared'; ou apenas ocn_pet_count,
#                       se pet_layout='split' (ex.: metade do total, ou outra
#                       proporção configurada).
#   --search-range R    Nº de valores de --pes tentados a partir de N em
#                       --target-eff (padrão: 40).
#   --no-mask           Não gera mask_table: escolhe o melhor LAYOUT cujo
#                       produto NIPROC*NJPROC seja exatamente o nº de PETs
#                       pedido. Os blocos 100% terra continuam existindo e
#                       recebem PET (custam pouco, pois não há oceano). É o
#                       ÚNICO modo suportado hoje pelo sistema acoplado — veja
#                       "LIMITAÇÃO DO ACOPLADO" abaixo.
#   --min-tile N        Tamanho mínimo do bloco em pontos, nas duas direções
#                       (padrão: 9). Vem de 2*NIHALO+1, o halo do domínio
#                       MOM_MOSAIC (supergrid): com blocos menores que o halo,
#                       o FMS lê fora do domínio do vizinho.
#   --max-aspect R      Razão de aspecto máxima do bloco (padrão: 4.0); evita
#                       blocos-fita, que maximizam a área de halo.
#   --min-depth D       Célula é OCEANO se profundidade > D (padrão: 0).
#                       Ignorado para variáveis de máscara (wet/mask: ocean = >0,5).
#   --depth-var NOME    Força o nome da variável (auto: depth, D, wet, mask).
#   --out ARQ           Caminho do mask_table de saída
#                       (padrão: mask_table.<Nmask>.<NI>x<NJ> no diretório atual).
#   --input-dir DIR     Copia o mask_table também para DIR (ex.: INPUT/); útil
#                       combinado com --mom-input/--sis-input.
#   --mom-input ARQ     Atualiza LAYOUT e MASKTABLE em ARQ (ex.: MOM_input) com
#                       o resultado desta execução. Cria backup ARQ.bak.<data>.
#   --sis-input ARQ     Idem, para o SIS_input.
#   --dry-run           Não copia para --input-dir nem atualiza --mom-input/
#                       --sis-input. O mask_table em si (resultado do cálculo)
#                       ainda é gravado normalmente — é a saída principal do
#                       comando, não um efeito colateral.
#   --help, -h          Esta mensagem.
#
# SAÍDA
#   Um arquivo mask_table no formato do FMS:
#       linha 1 : número de blocos mascarados
#       linha 2 : NIPROC,NJPROC
#       demais  : i,j (1-based) de cada bloco 100% terra
#   Um resumo com o que inserir no MOM_input / SIS_input (e, se --mom-input/
#   --sis-input forem usados, os próprios arquivos já atualizados).
#
# EXEMPLOS
#   bash domain-mom6.bash --topog INPUT/ocean_topog.nc --pes 128
#   bash domain-mom6.bash --topog INPUT/ocean_topog.nc --layout 16,8
#   # run -n 256 com pet_layout='split', 128 ATM + 128 OCN (acoplado):
#   bash domain-mom6.bash --topog INPUT/ocean_topog.nc --no-mask --pes 128 \
#        --mom-input MOM_input --sis-input SIS_input
#   # MOM6+SIS2 standalone, com mask_table para 128 PEs efetivos:
#   bash domain-mom6.bash --topog INPUT/ocean_topog.nc --target-eff 128 \
#        --input-dir INPUT --mom-input MOM_input --sis-input SIS_input
#
# LIMITAÇÃO DO ACOPLADO (incidente de 22/07/2026; ver docs/mascara-cap-nuopc.md)
#   O cap NUOPC do MOM6 (mom_cap_MONAN.F90) cria o ESMF_Grid a partir de um
#   deBlockList montado com mpp_get_compute_domains, ou seja, apenas com os
#   blocos que TÊM PET. Com mask_table, os blocos mascarados somem da lista e o
#   espaço de índices [1..NI_G] x [1..NJ_G] fica parcialmente sem dono. O
#   ESMF_DistGridCreate e o ESMF_GridCreate aceitam isso em silêncio; a falha só
#   aparece no conector OCN->MED, quando o ESMF_FieldRegridStore chama o
#   ESMF_GridToMesh:
#       ESMCI_Mesh.C, line:1786: Bad processor number!
#   seguido de SIGSEGV no PET vizinho ao buraco. Enquanto o cap não criar DEs
#   também para os blocos mascarados (o ESMF_DELayout aceita mais de um DE por
#   PET), use --no-mask no sistema acoplado. O mask_table permanece válido para
#   o MOM6+SIS2 standalone.
#
# POLÍTICA DA BUSCA (--target-eff)
#   A varredura NÃO aceita o primeiro LAYOUT cujo EFF bate. Para cada nº de
#   blocos são avaliados todos os pares de fatores que passam em --min-tile e
#   --max-aspect, e vence o de melhor forma em TODA a faixa. Sem isso, um
#   LAYOUT degenerado (ex.: 43x3, blocos de 4 pts com halo de 4 e de 9) pode
#   ser escolhido apenas por aparecer antes na varredura.
#
# REQUISITOS
#   ncdump (módulo cray-netcdf) e awk. Não usa Python.
#   Não depende do COUPLER_ROOT nem do ESMF — opera só sobre a topografia.
# =============================================================================
set -euo pipefail

# ── Âncora determinística ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Biblioteca de log (reusa include.bash do instalador, se presente) ─────────
if [[ -f "${SCRIPT_DIR}/include.bash" ]]; then
  # shellcheck source=include.bash
  source "${SCRIPT_DIR}/include.bash"
else
  if [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    _C_VD=$(tput setaf 2); _C_AM=$(tput setaf 3); _C_VM=$(tput setaf 1)
    _C_AZ=$(tput setaf 6); _C_BD=$(tput bold);   _C_RS=$(tput sgr0)
  else
    _C_VD=""; _C_AM=""; _C_VM=""; _C_AZ=""; _C_BD=""; _C_RS=""
  fi
  log_info()  { printf "${_C_AZ}  INFO  ${_C_RS}%s\n" "$*"; }
  log_ok()    { printf "${_C_VD}  OK    ${_C_RS}%s\n" "$*"; }
  log_warn()  { printf "${_C_AM}  AVISO ${_C_RS}%s\n" "$*" >&2; }
  log_error() { printf "${_C_VM}  ERRO  ${_C_RS}%s\n" "$*" >&2; }
  log_step()  { printf "\n${_C_BD}==> [%s/%s] %s${_C_RS}\n" "$1" "$2" "$3"; }
  log_sep()   { printf "${_C_AZ}%s${_C_RS}\n" "$(printf '─%.0s' $(seq 1 70))"; }
fi

# ── Ajuda ─────────────────────────────────────────────────────────────────────
usage() {
  cat << 'EOF'
Uso: bash domain-mom6.bash --topog ARQ.nc (--pes N | --layout NI,NJ | --target-eff N) [OPÇÕES]

  Calcula um LAYOUT (NIPROC × NJPROC) equilibrado e gera o mask_table do FMS
  para o MOM6+SIS2, eliminando blocos 100% terra (reduz os PETs do oceano).
  Implementação 100% shell: ncdump (cray-netcdf) + awk, sem Python.

Opções:
  --topog ARQ.nc    (obrigatório) topografia/máscara (lê NI_G, NJ_G e o oceano).
  --pes N           Nº de blocos desejado; fatora N e sugere o LAYOUT.
  --layout NI,NJ    LAYOUT explícito (prioritário sobre --pes; não combina com --target-eff).
  --target-eff N    Busca um LAYOUT cujo EFF (PETs efetivos) seja EXATAMENTE N
                    (varre --pes N..N+search-range). Use N = PETs que o OCN vai
                    efetivamente receber (total do run se pet_layout='shared';
                    ocn_pet_count se pet_layout='split'): evita o erro
                    "mpp_npes() .NE. layout(1)*layout(2) - nmask". Exclusivo
                    (não combina com --pes/--layout).
  --search-range R  Tentativas de --target-eff a partir de N (padrão: 40).
  --no-mask         Não gera mask_table: LAYOUT com produto exato = PETs, todos
                    os blocos com PET. ÚNICO modo suportado pelo cap NUOPC do
                    MOM6 no sistema acoplado (ver AVISO abaixo).
  --min-tile N      Tamanho mínimo do bloco, em pontos, nas duas direções
                    (padrão: 9 = 2*NIHALO+1 do supergrid MOSAIC). Candidatos
                    abaixo disso são descartados.
  --max-aspect R    Razão de aspecto máxima do bloco (padrão: 4.0).
  --min-depth D     Oceano se profundidade > D (padrão: 0).
  --depth-var NOME  Força a variável (auto: depth, D, wet, mask).
  --out ARQ         Saída (padrão: mask_table.<Nmask>.<NI>x<NJ>).
  --input-dir DIR   Também copia o mask_table para DIR (ex.: INPUT/).
  --mom-input ARQ   Atualiza LAYOUT/MASKTABLE em ARQ (backup .bak.<data>).
  --sis-input ARQ   Idem, para o SIS_input.
  --dry-run         Não copia p/ --input-dir nem atualiza --mom-input/
                    --sis-input (o mask_table em si ainda é gravado).
  --help, -h        Esta mensagem.

AVISO (sistema acoplado): o cap NUOPC do MOM6 monta o ESMF_Grid com um
  deBlockList formado pelos domínios dos PETs vivos. Blocos mascarados não têm
  PET e deixam buracos no espaço de índices; o ESMF_GridToMesh, acionado pelo
  conector OCN->MED ao calcular os pesos de regrid, aborta com "Bad processor
  number!". Use --no-mask no acoplado; mask_table só no MOM6+SIS2 standalone.

Exemplos:
  bash domain-mom6.bash --topog INPUT/ocean_topog.nc --no-mask --pes 128
  bash domain-mom6.bash --topog INPUT/ocean_topog.nc --pes 128
  bash domain-mom6.bash --topog INPUT/ocean_topog.nc --layout 16,8
  # run -n 256 com pet_layout='split', 128 ATM + 128 OCN (acoplado):
  bash domain-mom6.bash --topog INPUT/ocean_topog.nc --no-mask --pes 128 \
       --mom-input MOM_input --sis-input SIS_input
  # MOM6+SIS2 standalone, com mask_table para 128 PEs efetivos:
  bash domain-mom6.bash --topog INPUT/ocean_topog.nc --target-eff 128 \
       --input-dir INPUT --mom-input MOM_input --sis-input SIS_input
EOF
  exit 0
}

# ── Análise de opções ─────────────────────────────────────────────────────────
TOPOG=""
PES=0
NI_IN=0
NJ_IN=0
TARGET_EFF=0
SEARCH_RANGE=40
MIN_TILE=9
MAX_ASPECT=4.0
NO_MASK=false
MIN_DEPTH=0
DEPTH_VAR=""
OUTFILE=""
INPUT_DIR=""
MOM_INPUT=""
SIS_INPUT=""
DRY_RUN=false
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topog)       TOPOG="${2:?--topog exige um arquivo}"; shift 2 ;;
    --pes)         PES="${2:?--pes exige um número}"; shift 2 ;;
    --layout)      _lay="${2:?--layout exige NI,NJ}"; shift 2
                   if [[ ! "${_lay}" =~ ^[0-9]+,[0-9]+$ ]]; then
                     log_error "--layout malformado: '${_lay}' (use NI,NJ, ex.: 16,8)"; exit 1
                   fi
                   NI_IN="${_lay%,*}"; NJ_IN="${_lay#*,}" ;;
    --target-eff)  TARGET_EFF="${2:?--target-eff exige um número}"; shift 2 ;;
    --search-range) SEARCH_RANGE="${2:?--search-range exige um número}"; shift 2 ;;
    --min-tile)    MIN_TILE="${2:?--min-tile exige um número}"; shift 2 ;;
    --max-aspect)  MAX_ASPECT="${2:?--max-aspect exige um valor}"; shift 2 ;;
    --no-mask)     NO_MASK=true; shift ;;
    --min-depth)   MIN_DEPTH="${2:?--min-depth exige um valor}"; shift 2 ;;
    --depth-var)   DEPTH_VAR="${2:?--depth-var exige um nome}"; shift 2 ;;
    --out)         OUTFILE="${2:?--out exige um caminho}"; shift 2 ;;
    --input-dir)   INPUT_DIR="${2:?--input-dir exige um diretório}"; shift 2 ;;
    --mom-input)   MOM_INPUT="${2:?--mom-input exige um caminho}"; shift 2 ;;
    --sis-input)   SIS_INPUT="${2:?--sis-input exige um caminho}"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --help|-h)     usage ;;
    *) log_error "Opção desconhecida: $1   (use --help para a lista de opções)"; exit 1 ;;
  esac
done
unset _lay 2>/dev/null || true

# ── Validações ────────────────────────────────────────────────────────────────
if [[ -z "${TOPOG}" ]]; then
  log_error "--topog é obrigatório (informe ocean_topog.nc ou ocean_mask.nc)."
  exit 1
fi
if [[ ! -f "${TOPOG}" ]]; then
  log_error "Arquivo de topografia não encontrado: ${TOPOG}"
  exit 1
fi

_n_modes=0
[[ "${NI_IN}" -gt 0 && "${NJ_IN}" -gt 0 ]] && _n_modes=$((_n_modes + 1))
[[ "${PES}" -gt 0 ]] && _n_modes=$((_n_modes + 1))
[[ "${TARGET_EFF}" -gt 0 ]] && _n_modes=$((_n_modes + 1))
if [[ "${_n_modes}" -eq 0 ]]; then
  log_error "Informe --pes N (sugere o LAYOUT), --layout NI,NJ (explícito) ou --target-eff N (busca por EFF exato)."
  exit 1
fi
# --target-eff é exclusivo (busca automática; não combina com um LAYOUT/nº de
# blocos já fixado). Entre --pes e --layout, preserva-se a precedência de
# sempre: --layout vence se ambos forem informados.
if [[ "${TARGET_EFF}" -gt 0 && "${_n_modes}" -gt 1 ]]; then
  log_error "--target-eff não pode ser combinado com --pes ou --layout."
  exit 1
fi
if [[ "${NI_IN}" -gt 0 && "${NJ_IN}" -gt 0 ]]; then
  MODE="layout"
elif [[ "${PES}" -gt 0 ]]; then
  MODE="pes"
else
  MODE="search"
fi
unset _n_modes

if [[ ! "${MIN_TILE}" =~ ^[0-9]+$ ]]; then
  log_error "--min-tile deve ser inteiro >= 1 (recebido: '${MIN_TILE}')."
  exit 1
fi
if [[ ! "${MAX_ASPECT}" =~ ^[0-9]+([.,][0-9]+)?$ ]]; then
  log_error "--max-aspect deve ser numérico (recebido: '${MAX_ASPECT}')."
  exit 1
fi
MAX_ASPECT="${MAX_ASPECT/,/.}"

# --no-mask: nenhum bloco é mascarado, logo EFF = NIPROC*NJPROC. Nesse caso
# --target-eff N é exatamente --pes N (o alvo vira o produto), e converter aqui
# evita uma varredura que só encontraria layouts com nmask=0.
if [[ "${NO_MASK}" == true && "${MODE}" == "search" ]]; then
  log_info "--no-mask com --target-eff ${TARGET_EFF}: equivale a --pes ${TARGET_EFF} (EFF = NIPROC*NJPROC)."
  MODE="pes"; PES="${TARGET_EFF}"; TARGET_EFF=0
fi

if [[ -n "${SIS_INPUT}" && -z "${MOM_INPUT}" ]]; then
  log_warn "--sis-input informado sem --mom-input; ambos costumam usar o mesmo LAYOUT/MASKTABLE."
fi
if [[ -n "${MOM_INPUT}" && ! -f "${MOM_INPUT}" ]]; then
  log_error "--mom-input não encontrado: ${MOM_INPUT}"
  exit 1
fi
if [[ -n "${SIS_INPUT}" && ! -f "${SIS_INPUT}" ]]; then
  log_error "--sis-input não encontrado: ${SIS_INPUT}"
  exit 1
fi

if ! command -v ncdump &>/dev/null; then
  log_error "ncdump não encontrado no PATH."
  log_info  "Na Jaci:  module load cray-netcdf"
  exit 1
fi

# ── Leitura do cabeçalho (ncdump -h): variável, dimensões e tamanhos ──────────
# Estratégia robusta a nomes de dimensão: localiza a declaração da variável
# escolhida e toma as DUAS ÚLTIMAS dimensões como (j, i) = (NJ_G, NI_G).
HDR="$(ncdump -h "${TOPOG}")"

VAR=""
for _v in ${DEPTH_VAR} depth D wet mask; do
  [[ -z "${_v}" ]] && continue
  if grep -qE "^[[:space:]]+[A-Za-z0-9_]+ ${_v}\(" <<< "${HDR}"; then
    VAR="${_v}"; break
  fi
done
if [[ -z "${VAR}" ]]; then
  log_error "Nenhuma variável de profundidade/máscara encontrada (depth, D, wet, mask)."
  log_info  "Variáveis no arquivo:"
  grep -E "^[[:space:]]+[A-Za-z0-9_]+ [A-Za-z0-9_]+\(" <<< "${HDR}" | sed 's/^/    /' >&2
  log_info  "Force com --depth-var NOME."
  exit 1
fi

# Lista de dimensões da variável (conteúdo entre parênteses)
_decl="$(grep -E "^[[:space:]]+[A-Za-z0-9_]+ ${VAR}\(" <<< "${HDR}" | head -1)"
_dims="$(sed -E 's/.*\(([^)]*)\).*/\1/' <<< "${_decl}" | tr -d ' ')"   # ex.: ny,nx
_ndim="$(awk -F',' '{print NF}' <<< "${_dims}")"
if [[ "${_ndim}" -lt 2 ]]; then
  log_error "Variável '${VAR}' não é 2D (dims: ${_dims})."
  exit 1
fi
DIM_J="$(awk -F',' '{print $(NF-1)}' <<< "${_dims}")"   # penúltima = j (y)
DIM_I="$(awk -F',' '{print $(NF)}'   <<< "${_dims}")"   # última    = i (x)

_dim_size() {  # imprime o tamanho da dimensão $1 a partir do cabeçalho
  grep -E "^[[:space:]]*$1 = [0-9]+ ;" <<< "${HDR}" | sed -E 's/.*= *([0-9]+).*/\1/' | head -1
}
NJ_G="$(_dim_size "${DIM_J}")"
NI_G="$(_dim_size "${DIM_I}")"
if [[ -z "${NI_G}" || -z "${NJ_G}" ]]; then
  log_error "Falha ao obter dimensões da variável '${VAR}' (j=${DIM_J}, i=${DIM_I})."
  exit 1
fi

# Limiar de oceano: profundidade > MIN_DEPTH; máscara (wet/mask): > 0,5.
_vl="$(printf '%s' "${VAR}" | tr '[:upper:]' '[:lower:]')"
if [[ "${_vl}" == "wet" || "${_vl}" == "mask" ]]; then
  THRESH="0.5"
else
  THRESH="${MIN_DEPTH}"
fi

# Validação do LAYOUT explícito contra a grade
if [[ "${MODE}" == "layout" ]]; then
  if (( NI_IN > NI_G || NJ_IN > NJ_G )); then
    log_error "LAYOUT ${NI_IN}×${NJ_IN} excede a grade ${NI_G}×${NJ_G}."
    exit 1
  fi
fi

# ── Núcleo em awk: lê o array (ncdump -v), mascara e escreve o mask_table ──────
# Toda a aritmética de blocos usa uma soma de prefixos 2D (imagem integral) do
# oceano, calculada UMA vez; assim a avaliação de cada LAYOUT candidato é O(1)
# por bloco. O awk também grava o mask_table diretamente.
AWK_PROG="$(mktemp /tmp/domain-mom6.XXXXXX.awk)"

# Arquivos temporários criados ao longo da execução (varredura de --target-eff
# inclusive); tudo é limpo ao sair, sucesso ou erro.
_TMP_FILES=("${AWK_PROG}")
trap 'rm -f "${_TMP_FILES[@]}"' EXIT

cat > "${AWK_PROG}" << 'AWKEOF'
# Variáveis injetadas por -v: NI, NJ, THRESH, MODE, PES, NIP, NJP, OUTREQ, VAR
function maxv(a,b){ return a>b?a:b }
function minv(a,b){ return a<b?a:b }

# Fronteiras contíguas de 'n' pontos em 'parts' blocos (tamanhos diferem em <=1).
# ATENÇÃO: as sobras vão para os PRIMEIROS blocos, enquanto o mpp_compute_extent
# do FMS as distribui simetricamente (para 158 em 3: FMS = 53 52 53, aqui =
# 53 53 52). As fronteiras internas podem ficar deslocadas em um ponto e o
# conjunto de blocos secos divergir. Irrelevante em --no-mask (nenhum
# mask_table é lido); relevante no uso standalone, onde um bloco com oceano
# pode ser mascarado por engano. Ver docs/domain-mom6.md, seção 5.
function bounds(n, parts, S, E,   base, rem, k, s, sz) {
  base = int(n / parts); rem = n % parts; s = 0
  for (k = 1; k <= parts; k++) {
    sz = base + (k <= rem ? 1 : 0)
    S[k] = s; E[k] = s + sz; s += sz
  }
}

# Conta oceano num retângulo [i0,i1)×[j0,j1) via soma de prefixos PS.
function rectsum(i0, i1, j0, j1) {
  return PS[j1*W + i1] - PS[j0*W + i1] - PS[j1*W + i0] + PS[j0*W + i0]
}

# Nº de blocos 100% terra para o LAYOUT (nip,njp).
function nmasked(nip, njp,   IS, IE, JS, JE, ti, tj, m) {
  bounds(NI, nip, IS, IE); bounds(NJ, njp, JS, JE); m = 0
  for (tj = 1; tj <= njp; tj++)
    for (ti = 1; ti <= nip; ti++)
      if (rectsum(IS[ti], IE[ti], JS[tj], JE[tj]) == 0) m++
  return m
}

BEGIN { collect = 0; idx = 0 }

# Início do bloco de dados da nossa variável: " VAR = ..."
$0 ~ ("^[[:space:]]*" VAR "[[:space:]]*=") { collect = 1; sub(/^[^=]*=/, "", $0) }

collect {
  line = $0; fin = 0
  if (index(line, ";") > 0) { sub(/;.*/, "", line); fin = 1 }
  n = split(line, a, /[, \t]+/)
  for (k = 1; k <= n; k++) {
    tok = a[k]
    if (tok == "") continue
    ocean[idx] = (tok == "_") ? 0 : ((tok + 0) > THRESH ? 1 : 0)
    idx++
  }
  if (fin) collect = 0
}

END {
  total = NI * NJ
  if (idx != total)
    print "WARN Lidos " idx " valores, esperados " total " (verifique a variável/arquivo)."

  # Soma de prefixos 2D: PS[j*W + i], i em 0..NI, j em 0..NJ
  W = NI + 1
  for (i = 0; i <= NI; i++) PS[i] = 0
  for (j = 1; j <= NJ; j++) {
    PS[j*W + 0] = 0; rb = (j-1) * NI
    for (i = 1; i <= NI; i++) {
      o = ocean[rb + (i-1)] + 0
      PS[j*W + i] = o + PS[(j-1)*W + i] + PS[j*W + (i-1)] - PS[(j-1)*W + (i-1)]
    }
  }
  oc_total = PS[NJ*W + NI]
  print "DIMS VAR=" VAR " NI_G=" NI " NJ_G=" NJ " OCEAN=" oc_total " TOTAL=" total

  # ── Modo "scan" (usado por --target-eff) ────────────────────────────────
  # Lista TODOS os pares de fatores de PES que passam no filtro de forma, com
  # escore, nmask e EFF. Quem decide é o shell, comparando os candidatos de
  # toda a faixa de busca — e não apenas o melhor de cada nº de blocos.
  # Não grava mask_table: é uma sondagem.
  if (MODE == "scan") {
    P = PES
    for (a1 = 1; a1 <= P; a1++) {
      if (P % a1 != 0) continue
      b1 = P / a1
      if (a1 > NI || b1 > NJ) continue
      ti = NI / a1; tj = NJ / b1
      if (minv(ti, tj) < MINTILE) continue
      aspect = maxv(ti, tj) / (minv(ti, tj) + 1e-9)
      if (aspect > MAXASP) continue
      even = (NI % a1 == 0 && NJ % b1 == 0)
      nm = nmasked(a1, b1)
      printf "SCAN NI=%d NJ=%d SCORE=%.4f TIL=%.1fx%.1f NMASK=%d EFF=%d\n",
             a1, b1, aspect + (even ? 0 : 0.5), ti, tj, nm, a1*b1 - nm
    }
    exit 0
  }

  # Escolha do LAYOUT
  if (MODE == "pes") {
    P = PES; ncand = 0
    for (a1 = 1; a1*a1 <= P; a1++) {
      if (P % a1 != 0) continue
      b1 = P / a1
      ncand++; CA[ncand] = a1; CB[ncand] = b1
      if (a1 != b1) { ncand++; CA[ncand] = b1; CB[ncand] = a1 }
    }
    for (c = 1; c <= ncand; c++) {
      a1 = CA[c]; b1 = CB[c]
      ti = NI / a1; tj = NJ / b1
      even = (NI % a1 == 0 && NJ % b1 == 0)
      aspect = maxv(ti, tj) / (minv(ti, tj) + 1e-9)
      # Filtro de forma: bloco menor que MINTILE pontos (halo maior que o
      # próprio bloco) ou alongado demais recebe penalidade proibitiva —
      # continua listado, mas nunca é escolhido havendo alternativa válida.
      bad = (a1 > NI || b1 > NJ || minv(ti, tj) < MINTILE || aspect > MAXASP) ? 1 : 0
      SC[c] = aspect + (even ? 0 : 0.5) + bad * 1000
      EV[c] = even
      BD[c] = bad
    }
    used_lim = (ncand < 6) ? ncand : 6
    for (r = 1; r <= used_lim; r++) {
      bi = 0; bs = 1e18
      for (c = 1; c <= ncand; c++)
        if (!UD[c] && SC[c] < bs) { bs = SC[c]; bi = c }
      UD[bi] = 1
      a1 = CA[bi]; b1 = CB[bi]
      nm = nmasked(a1, b1)
      printf "CAND NI=%d NJ=%d TIL=%dx%d EVEN=%d BAD=%d NMASK=%d EFF=%d\n",
             a1, b1, int(NI/a1), int(NJ/b1), EV[bi], BD[bi], nm, a1*b1 - nm
      if (r == 1) { nip = a1; njp = b1; chosen_bad = BD[bi] }
    }
    if (chosen_bad)
      print "WARN Nenhum LAYOUT de " P " blocos satisfaz --min-tile/--max-aspect;" \
            " o escolhido viola o filtro de forma (tente outro nº de blocos)."
  } else {
    nip = NIP; njp = NJP
  }

  bounds(NI, nip, IS, IE); bounds(NJ, njp, JS, JE)
  nmask = 0
  for (tj = 1; tj <= njp; tj++)
    for (ti = 1; ti <= nip; ti++)
      if (rectsum(IS[ti], IE[ti], JS[tj], JE[tj]) == 0) {
        nmask++; MI[nmask] = ti; MJ[nmask] = tj
      }

  out = OUTREQ
  if (out == "") out = "mask_table." nmask "." nip "x" njp

  print nmask > out
  print nip "," njp > out
  for (m = 1; m <= nmask; m++) print MI[m] "," MJ[m] > out
  close(out)

  printf "CHOSEN NI=%d NJ=%d TIL_I=%.1f TIL_J=%.1f\n", nip, njp, NI/nip, NJ/njp
  printf "MASK NMASK=%d TOTAL=%d EFF=%d OUT=%s\n", nmask, nip*njp, nip*njp - nmask, out

  if (minv(NI/nip, NJ/njp) < MINTILE)
    printf "WARN Bloco de %.1f pts < --min-tile %d: halo (NIHALO e 2*NIHALO+1 no supergrid MOSAIC) pode exceder o bloco.\n",
           minv(NI/nip, NJ/njp), MINTILE
  if (NI % nip != 0 || NJ % njp != 0)
    print "WARN Divisão não exata: blocos de borda ficam com tamanho diferente."
  if (nmask == 0)
    print "WARN Nenhum bloco 100% terra: mask_table desnecessário (não defina MASKTABLE)."
}
AWKEOF

# Executa uma vez o núcleo (ncdump | awk) para (mode,pes,ni_in,nj_in) e grava a
# saída bruta do awk em ${1}. Reaproveitado tanto pelo fluxo único (--pes /
# --layout) quanto por cada tentativa da varredura de --target-eff.
run_core() {
  local raw_out="$1" mode="$2" pes="$3" ni_in="$4" nj_in="$5" out_req="$6"
  ncdump -v "${VAR}" "${TOPOG}" \
    | awk -v NI="${NI_G}" -v NJ="${NJ_G}" -v THRESH="${THRESH}" \
          -v MODE="${mode}" -v PES="${pes}" -v NIP="${ni_in}" -v NJP="${nj_in}" \
          -v OUTREQ="${out_req}" -v VAR="${VAR}" \
          -v MINTILE="${MIN_TILE}" -v MAXASP="${MAX_ASPECT}" \
          -f "${AWK_PROG}" > "${raw_out}"
}

# ── Execução ──────────────────────────────────────────────────────────────────
log_sep
log_info "Divisão de domínio MOM6+SIS2 — INPE / CGCT / DIMNT (100% shell)"
log_info "Topografia: ${TOPOG}"
case "${MODE}" in
  pes)    log_info "Modo: sugerir LAYOUT para ${PES} blocos" ;;
  layout) log_info "Modo: LAYOUT explícito ${NI_IN}×${NJ_IN}" ;;
  search) log_info "Modo: localizar LAYOUT com EFF = ${TARGET_EFF} PETs (varredura --pes ${TARGET_EFF}..$((TARGET_EFF + SEARCH_RANGE)))" ;;
esac
log_sep

# ── Modo --target-eff: varre e escolhe o MELHOR LAYOUT com EFF == TARGET_EFF ──
# O nº de blocos mascarados depende da FORMA do LAYOUT, não só do produto
# NIPROC*NJPROC; por isso a varredura chama o núcleo uma vez por nº de blocos.
#
# Política (desde a correção do incidente do LAYOUT 43x3): NÃO se aceita o
# primeiro EFF que bate. Para cada nº de blocos o awk devolve TODOS os pares de
# fatores que passam no filtro de forma (--min-tile / --max-aspect), e o
# vencedor é o de menor escore em TODA a faixa de busca. Assim um layout
# degenerado (bloco de 4 pts, halo maior que o bloco) deixa de ser escolhido
# só porque apareceu antes.
if [[ "${MODE}" == "search" ]]; then
  log_step 1 2 "Varredura (--pes ${TARGET_EFF}..$((TARGET_EFF + SEARCH_RANGE)), min-tile=${MIN_TILE}, max-aspect=${MAX_ASPECT})"
  printf "       %-8s %-10s %-14s %-8s %-8s\n" "PES" "LAYOUT" "BLOCO(pts)" "NMASK" "ESCORE"

  _best_score=""; _best_ni=""; _best_nj=""; _best_nm=""; _best_p=""
  for (( _p = TARGET_EFF; _p <= TARGET_EFF + SEARCH_RANGE; _p++ )); do
    _scan_out="$(mktemp /tmp/domain-mom6.scan.XXXXXX)"
    _TMP_FILES+=("${_scan_out}")
    if ! run_core "${_scan_out}" "scan" "${_p}" 0 0 ""; then
      log_error "Falha ao ler/processar a topografia (ncdump/awk) em --pes ${_p}."
      exit 1
    fi

    while IFS= read -r _ln; do
      [[ -z "${_ln}" ]] && continue
      _s_ef="$(sed -n 's/.*EFF=\([0-9]*\).*/\1/p' <<< "${_ln}")"
      [[ "${_s_ef}" != "${TARGET_EFF}" ]] && continue
      _s_ni="$(sed -n 's/.*NI=\([0-9]*\).*/\1/p'          <<< "${_ln}")"
      _s_nj="$(sed -n 's/.*NJ=\([0-9]*\).*/\1/p'          <<< "${_ln}")"
      _s_sc="$(sed -n 's/.*SCORE=\([0-9.]*\).*/\1/p'      <<< "${_ln}")"
      _s_ti="$(sed -n 's/.*TIL=\([0-9.x]*\).*/\1/p'       <<< "${_ln}")"
      _s_nm="$(sed -n 's/.*NMASK=\([0-9]*\).*/\1/p'       <<< "${_ln}")"
      printf "       %-8s %-10s %-14s %-8s %-8s\n" \
             "${_p}" "${_s_ni}x${_s_nj}" "${_s_ti}" "${_s_nm}" "${_s_sc}"
      if [[ -z "${_best_score}" ]] || \
         awk -v a="${_s_sc}" -v b="${_best_score}" 'BEGIN{exit !(a<b)}'; then
        _best_score="${_s_sc}"; _best_ni="${_s_ni}"; _best_nj="${_s_nj}"
        _best_nm="${_s_nm}";    _best_p="${_p}"
      fi
    done < <(grep '^SCAN' "${_scan_out}" || true)
  done

  if [[ -z "${_best_score}" ]]; then
    log_sep
    log_error "Nenhum LAYOUT com EFF exatamente ${TARGET_EFF} passou no filtro de forma."
    log_info  "Opções:"
    log_info  "  a) ampliar a busca      : --search-range $((SEARCH_RANGE * 2))"
    log_info  "  b) relaxar a forma      : --min-tile $((MIN_TILE > 4 ? MIN_TILE - 2 : 4))  ou  --max-aspect 6"
    log_info  "  c) dispensar a máscara  : --no-mask --pes ${TARGET_EFF}  (LAYOUT com produto exato,"
    log_info  "     sem mask_table — única forma suportada hoje pelo cap NUOPC do MOM6)"
    exit 1
  fi

  log_ok "Melhor da faixa: LAYOUT ${_best_ni}x${_best_nj} em --pes ${_best_p}  (nmask=${_best_nm}, EFF=${TARGET_EFF}, escore=${_best_score})"
  # Segue no fluxo de LAYOUT explícito: o vencedor não é necessariamente o
  # melhor candidato do seu próprio nº de blocos, então reentrar em modo "pes"
  # poderia devolver outro par de fatores.
  MODE="layout"
  NI_IN="${_best_ni}"
  NJ_IN="${_best_nj}"
fi

# ── Fluxo único (pes/layout, incluindo o LAYOUT resolvido por --target-eff) ──
PY_OUT="$(mktemp /tmp/domain-mom6.out.XXXXXX)"
_TMP_FILES+=("${PY_OUT}")

# --no-mask: o awk ainda identifica os blocos secos (é a mesma contagem), mas o
# arquivo vai para um temporário e é descartado — nenhum bloco é eliminado e
# todos os NIPROC*NJPROC blocos recebem PET.
if [[ "${NO_MASK}" == true ]]; then
  OUTFILE="$(mktemp /tmp/domain-mom6.nomask.XXXXXX)"
  _TMP_FILES+=("${OUTFILE}")
fi

if ! run_core "${PY_OUT}" "${MODE}" "${PES}" "${NI_IN}" "${NJ_IN}" "${OUTFILE}"; then
  log_error "Falha ao ler/processar a topografia (ncdump/awk)."
  exit 1
fi

# ── Parse e apresentação ──────────────────────────────────────────────────────
NI=""; NJ=""; NMASK=""; TOTAL=""; EFF=""; OUT=""; OCEAN_FRAC=""
_cand_header=false

while IFS= read -r line; do
  case "${line}" in
    WARN*)  log_warn "${line#WARN }" ;;
    DIMS*)
      _ni_g="$(sed -n 's/.*NI_G=\([0-9]*\).*/\1/p' <<< "${line}")"
      _nj_g="$(sed -n 's/.*NJ_G=\([0-9]*\).*/\1/p' <<< "${line}")"
      _var="$(sed -n 's/.*VAR=\([^ ]*\).*/\1/p'    <<< "${line}")"
      _ocean="$(sed -n 's/.*OCEAN=\([0-9]*\).*/\1/p' <<< "${line}")"
      _tot="$(sed -n 's/.*TOTAL=\([0-9]*\).*/\1/p'   <<< "${line}")"
      OCEAN_FRAC="$(awk "BEGIN{printf \"%.1f\", 100*${_ocean}/${_tot}}")"
      log_ok "Grade: ${_ni_g} × ${_nj_g}  (variável '${_var}', oceano ${OCEAN_FRAC}%)"
      ;;
    CAND*)
      if [[ "${_cand_header}" == false ]]; then
        log_step 1 2 "Candidatos de LAYOUT (ordenados; 1º = escolhido)"
        # Em --no-mask nenhum bloco é eliminado: a contagem de blocos secos é
        # apenas informativa e os PETs são o produto NIPROC*NJPROC.
        if [[ "${NO_MASK}" == true ]]; then
          _col5="SECOS"      # blocos 100% terra, mantidos
        else
          _col5="MASCAR."    # blocos 100% terra, eliminados pelo mask_table
        fi
        printf "       %-10s %-12s %-6s %-11s %-8s %-8s\n" "LAYOUT" "BLOCO(pts)" "EXATO" "FILTRO" "${_col5}" "PETs"
        _cand_header=true
      fi
      _a="$(sed -n 's/.*NI=\([0-9]*\).*/\1/p'    <<< "${line}")"
      _b="$(sed -n 's/.*NJ=\([0-9]*\).*/\1/p'    <<< "${line}")"
      _til="$(sed -n 's/.*TIL=\([0-9x]*\).*/\1/p' <<< "${line}")"
      _evn="$(sed -n 's/.*EVEN=\([0-9]*\).*/\1/p' <<< "${line}")"
      _bad="$(sed -n 's/.*BAD=\([0-9]*\).*/\1/p'  <<< "${line}")"
      _nm="$(sed -n 's/.*NMASK=\([0-9]*\).*/\1/p' <<< "${line}")"
      _ef="$(sed -n 's/.*EFF=\([0-9]*\).*/\1/p'   <<< "${line}")"
      [[ "${_evn}" == "1" ]] && _ev="sim" || _ev="não"
      [[ "${_bad}" == "1" ]] && _vd="reprovado" || _vd="ok"
      # Sem mask_table, os blocos secos continuam recebendo PET: o nº de PETs
      # é o produto, não o produto menos os secos.
      [[ "${NO_MASK}" == true ]] && _ef=$(( _a * _b ))
      printf "       %-10s %-12s %-6s %-11s %-8s %-8s\n" "${_a}x${_b}" "${_til}" "${_ev}" "${_vd}" "${_nm}" "${_ef}"
      ;;
    CHOSEN*)
      NI="$(sed -n 's/.*NI=\([0-9]*\).*/\1/p' <<< "${line}")"
      NJ="$(sed -n 's/.*NJ=\([0-9]*\).*/\1/p' <<< "${line}")"
      ;;
    MASK*)
      NMASK="$(sed -n 's/.*NMASK=\([0-9]*\).*/\1/p' <<< "${line}")"
      TOTAL="$(sed -n 's/.*TOTAL=\([0-9]*\).*/\1/p' <<< "${line}")"
      EFF="$(sed -n 's/.*EFF=\([0-9]*\).*/\1/p'     <<< "${line}")"
      OUT="$(sed -n 's/.*OUT=\([^ ]*\).*/\1/p'      <<< "${line}")"
      ;;
  esac
done < "${PY_OUT}"

if [[ "${_cand_header}" == true && "${NO_MASK}" == true ]]; then
  log_info "SECOS é informativo (--no-mask): esses blocos são mantidos e PETs = NIPROC * NJPROC."
fi

# ── Resumo ────────────────────────────────────────────────────────────────────
echo ""
log_step 2 2 "Resultado"
log_ok "LAYOUT escolhido      : ${NI} x ${NJ}   (NIPROC * NJPROC = ${TOTAL} blocos)"

if [[ "${NO_MASK}" == true ]]; then
  # Sem máscara: nada é eliminado, os blocos secos apenas trabalham pouco.
  [[ -n "${NMASK}" && "${NMASK}" -gt 0 ]] && \
    log_info "Blocos 100% terra     : ${NMASK}  (mantidos: --no-mask, cada um recebe um PET)"
  EFF="${TOTAL}"
  OUT=""
  log_ok "PETs efetivos (oceano): ${EFF}   (= NIPROC * NJPROC, sem mask_table)"
else
  if [[ -n "${NMASK}" && "${NMASK}" -gt 0 ]]; then
    _save="$(awk "BEGIN{printf \"%.1f\", 100*${NMASK}/${TOTAL}}")"
    log_ok "Blocos 100% terra     : ${NMASK}  (economia de ${_save}% dos PETs)"
  fi
  log_ok "PETs efetivos (oceano): ${EFF}"
  log_ok "mask_table gerado     : ${OUT}"
fi

# ── Guarda do sistema acoplado ───────────────────────────────────────────────
# O cap NUOPC do MOM6 monta o ESMF_Grid com um deBlockList vindo dos domínios
# de computação dos PETs vivos. Blocos mascarados não têm PET, deixam buracos
# no espaço de índices [1..NI_G] x [1..NJ_G] e o ESMF_GridToMesh (chamado pelo
# conector OCN->MED ao gerar os pesos de regrid) aborta com "Bad processor
# number!". Enquanto o cap não criar DEs para os blocos mascarados, mask_table
# só é utilizável no MOM6+SIS2 rodando standalone.
if [[ "${NO_MASK}" != true && -n "${NMASK}" && "${NMASK}" -gt 0 ]]; then
  echo ""
  log_warn "mask_table NÃO é suportado pelo cap NUOPC atual do MOM6 (sistema acoplado)."
  log_warn "  Blocos mascarados deixam buracos no ESMF_Grid e o conector OCN->MED falha em"
  log_warn "  ESMF_GridToMesh com 'Bad processor number!' (segue SIGSEGV no PET vizinho)."
  log_warn "  Para o acoplado, gere um LAYOUT sem máscara:"
  log_warn "      bash ${0##*/} --topog ${TOPOG} --no-mask --pes <PETs do OCN>"
  log_warn "  Este mask_table serve para o MOM6+SIS2 standalone."
fi

# ── --dry-run: o mask_table acima já foi escrito pelo awk (é o próprio cálculo);
# em modo --dry-run não copiamos para --input-dir nem tocamos MOM_input/SIS_input.
if [[ -n "${INPUT_DIR}" && -n "${OUT}" ]]; then
  if [[ "${DRY_RUN}" == true ]]; then
    log_info "[dry-run] copiaria '${OUT}' para '${INPUT_DIR%/}/$(basename "${OUT}")'"
  else
    mkdir -p "${INPUT_DIR}"
    cp "${OUT}" "${INPUT_DIR%/}/$(basename "${OUT}")"
    log_ok "Copiado também para: ${INPUT_DIR%/}/$(basename "${OUT}")"
  fi
fi

echo ""
log_sep
log_info "Como usar no MOM_input (e, se houver, no SIS_input):"
echo ""
printf "    LAYOUT = %s, %s\n" "${NI}" "${NJ}"
if [[ -n "${OUT}" ]]; then
  printf "    MASKTABLE = \"%s\"\n" "$(basename "${OUT}")"
fi
echo ""
if [[ -n "${OUT}" ]]; then
  log_info "Coloque o '${OUT##*/}' no diretório onde o FMS lê os inputs (ex.: INPUT/)."
else
  log_info "Nenhum mask_table: remova (ou comente com '!') a diretiva MASKTABLE dos arquivos de entrada."
fi
if [[ -n "${EFF}" ]]; then
  log_info "O componente MOM6+SIS2 deve receber exatamente ${EFF} PETs (o total do run -n, se pet_layout='shared'; ou ocn_pet_count, se pet_layout='split' — em qualquer coupling_mode)."
fi
log_sep

# ── Atualização automática de MOM_input / SIS_input (--mom-input/--sis-input) ─
update_input_file() {
  local f="$1" ts backup

  if [[ "${DRY_RUN}" == true ]]; then
    log_info "[dry-run] atualizaria ${f}:"
    log_info "    LAYOUT = ${NI}, ${NJ}"
    if [[ -n "${OUT}" ]]; then
      log_info "    MASKTABLE = \"$(basename "${OUT}")\""
    elif grep -qE '^MASKTABLE[[:space:]]*=' "${f}" 2>/dev/null; then
      log_info "    (MASKTABLE existente seria comentado com '!')"
    else
      log_info "    (sem mask_table: MASKTABLE não seria definido/tocado)"
    fi
    return 0
  fi

  if ! grep -qE '^LAYOUT[[:space:]]*=' "${f}"; then
    log_error "Não encontrei uma linha 'LAYOUT =' em ${f}; atualize manualmente."
    return 1
  fi

  ts="$(date +%Y%m%d%H%M%S)"
  backup="${f}.bak.${ts}"
  cp "${f}" "${backup}"

  sed -i -E "s|^LAYOUT[[:space:]]*=.*|LAYOUT = ${NI}, ${NJ}|" "${f}"
  if [[ -n "${OUT}" ]]; then
    if grep -qE '^MASKTABLE[[:space:]]*=' "${f}"; then
      sed -i -E "s|^MASKTABLE[[:space:]]*=.*|MASKTABLE = \"$(basename "${OUT}")\"|" "${f}"
    else
      sed -i -E "/^LAYOUT[[:space:]]*=.*/a MASKTABLE = \"$(basename "${OUT}")\"" "${f}"
    fi
  else
    # Sem mask_table (--no-mask ou nmask=0): uma diretiva MASKTABLE remanescente
    # apontaria para um arquivo incompatível com o novo LAYOUT e derrubaria o
    # FMS já na inicialização. Comenta-se com '!' (comentário do MOM_input).
    if grep -qE '^MASKTABLE[[:space:]]*=' "${f}"; then
      sed -i -E "s|^MASKTABLE[[:space:]]*=|!MASKTABLE =|" "${f}"
      log_ok "MASKTABLE comentado em ${f} (não há mask_table para este LAYOUT)."
    fi
  fi
  log_ok "Atualizado: ${f}  (backup em ${backup})"
}

if [[ -n "${MOM_INPUT}" || -n "${SIS_INPUT}" ]]; then
  echo ""
  log_step 2 2 "Atualizando arquivos de configuração"
  [[ -n "${MOM_INPUT}" ]] && update_input_file "${MOM_INPUT}"
  [[ -n "${SIS_INPUT}" ]] && update_input_file "${SIS_INPUT}"
  log_sep
fi
