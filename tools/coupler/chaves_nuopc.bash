# shellcheck shell=bash
# =============================================================================
# chaves_nuopc.bash: leitura, nos scripts, da escolha dos modelos no nuopc.input.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Para ser carregado com 'source' pelos scripts que precisam saber qual
# modelo ocupa cada posição (run/run_esmApp.jaci, tools/coupler/*,
# tools/dev/cria-linha-base.bash). A regra é a de config_read
# (src/shared/coupler_config.F90):
#   - a chave por modelo vale se estiver no arquivo: atm_model, ocn_model,
#     ice_model e atm_boundary (grupo &nuopc_mode);
#   - sem ela, vale a chave antiga correspondente, traduzida: use_datm,
#     use_docn, use_sis2_dynamic (grupo &nuopc_petlayout) e use_med_to_mpas;
#   - sem nenhuma das duas, vale o padrão de produção: mpas, mom6, sis2, med.
# config_read recusa um arquivo em que a chave antiga contradiz a nova; aqui
# vale a nova, e a rodada para na leitura.
#
# As funções sempre terminam com código 0, para que possam ser usadas sob
# 'set -euo pipefail' com uma chave ausente (uma chave ausente faz o grep
# devolver 1, o que pararia o script sem mensagem). Como os demais leitores
# dos scripts, leem uma chave por linha.
#
# Funções:
#   nuopc_valor ARQ CHAVE        valor da primeira atribuição da chave, sem
#                                comentário, aspas e vírgula, em minúsculas;
#                                vazio se ausente
#   nuopc_modelo ARQ POSICAO     modelo da posição ATM, OCN ou ICE, ou o
#                                contorno (posição BND: med ou ocn)
#   nuopc_usa ARQ POSICAO MODELO .true. se o modelo ocupa a posição, senão
#                                .false. (a forma das chaves antigas)
#   nuopc_chaves_antigas ARQ     chaves antigas presentes no arquivo, uma
#                                por linha (vazio se nenhuma)
#   nuopc_troca_modelo ENTRADA SAIDA POSICAO MODELO
#                                copia ENTRADA em SAIDA com o modelo da
#                                posição trocado: tira as linhas da chave
#                                nova e da antiga da posição e escreve a nova
#                                logo depois da linha &nuopc_mode (ou num
#                                grupo &nuopc_mode novo, no fim, se o arquivo
#                                não tem o grupo); como a leitura, supõe uma
#                                chave por linha
#
# Teste: tests/scripts/confere-chaves-nuopc.bash (conferência 'chaves').
# =============================================================================

nuopc_valor() {
  local arq=$1 chave=$2
  [[ -f "${arq}" ]] || return 0
  sed 's/!.*//' "${arq}" \
    | grep -iE "^[[:space:]]*${chave}[[:space:]]*=" \
    | head -1 \
    | sed -E "s/^[^=]*=[[:space:]]*//; s/['\",]//g; s/[[:space:]]*\$//" \
    | tr '[:upper:]' '[:lower:]' || true
}

# Nova chave, chave antiga, valor com a antiga .true., com .false. e padrão
_nuopc_regra() {
  case "$1" in
    ATM) echo "atm_model use_datm datm mpas mpas" ;;
    OCN) echo "ocn_model use_docn docn mom6 mom6" ;;
    ICE) echo "ice_model use_sis2_dynamic sis2 none sis2" ;;
    BND) echo "atm_boundary use_med_to_mpas med ocn med" ;;
    *)   echo "" ;;
  esac
}

nuopc_modelo() {
  local arq=$1 nova antiga sim nao padrao v
  read -r nova antiga sim nao padrao <<< "$(_nuopc_regra "$2")"
  [[ -n "${nova}" ]] || return 0
  v=$(nuopc_valor "${arq}" "${nova}")
  if [[ -n "${v}" ]]; then
    echo "${v}"
    return 0
  fi
  v=$(nuopc_valor "${arq}" "${antiga}")
  case "${v}" in
    .true.|true|t|.t.)     echo "${sim}" ;;
    .false.|false|f|.f.)   echo "${nao}" ;;
    *)                     echo "${padrao}" ;;
  esac
  return 0
}

nuopc_usa() {
  if [[ "$(nuopc_modelo "$1" "$2")" == "$3" ]]; then
    echo ".true."
  else
    echo ".false."
  fi
}

nuopc_troca_modelo() {
  local entrada=$1 saida=$2 nova antiga sim nao padrao
  read -r nova antiga sim nao padrao <<< "$(_nuopc_regra "$3")"
  [[ -n "${nova}" ]] || { echo "nuopc_troca_modelo: posição desconhecida: $3" >&2; return 1; }
  awk -v nova="${nova}" -v antiga="${antiga}" -v valor="$4" '
    BEGIN { feito = 0 }
    {
      linha = tolower($0); sub(/!.*/, "", linha)
      if (linha ~ "^[[:space:]]*(" nova "|" antiga ")[[:space:]]*=") next
      print
      if (!feito && linha ~ /^[[:space:]]*&nuopc_mode([[:space:]]|$)/) {
        printf "  %s = '\''%s'\''\n", nova, valor
        feito = 1
      }
    }
    END { if (!feito) printf "&nuopc_mode\n  %s = '\''%s'\''\n/\n", nova, valor }
  ' "${entrada}" > "${saida}"
}

nuopc_chaves_antigas() {
  local c
  for c in use_datm use_docn use_med_to_mpas use_sis2_dynamic; do
    [[ -n "$(nuopc_valor "$1" "${c}")" ]] && echo "${c}"
  done
  return 0
}
