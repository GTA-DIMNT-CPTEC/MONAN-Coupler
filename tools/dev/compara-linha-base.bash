#!/usr/bin/env bash
# =============================================================================
# compara-linha-base.bash — compara a rodada atual com uma linha de base
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compara os NetCDF do diretório de experimento atual com os congelados em
# baseline/<rótulo>/saida/ e imprime um veredito PASS ou FAIL.
#
# Por que nao usar 'cmp' direto nos arquivos: os NetCDF gravados pelo acoplador
# carregam atributos globais com data e hora de criação. Duas execuções
# idênticas produzem arquivos com bytes diferentes no cabeçalho, embora com
# dados iguais. A comparação correta é sobre os DADOS, com nccmp -d.
#
# Uso:
#   compara-linha-base.bash -l L-01
#   compara-linha-base.bash -l L-01 -t 1e-12      # tolerância relativa
#   compara-linha-base.bash -l L-01 -o baseline_arquivada
#
# Códigos de saída:
#   0  PASS  — todos os arquivos batem
#   1  FAIL  — houve diferença de dados
#   2  erro de uso ou pré-condição
# =============================================================================

set -uo pipefail

ROTULO=""
BASE_DIR="baseline"
TOLERANCIA=""      # vazio = exigir identidade exata dos dados

_uso() {
  cat << 'EOF'

compara-linha-base.bash — compara a rodada atual com uma linha de base

  -l RÓTULO      obrigatório. Ex.: L-01
  -o DIRETÓRIO   raiz das linhas de base (padrão: ./baseline)
  -t VALOR       tolerância relativa (ex.: 1e-12). Sem -t, exige
                 identidade exata dos dados, que é o critério das
                 etapas de refatoração.
  -e             confere também as entradas pela soma registrada em
                 entrada/CHECKSUMS.txt (arquivos ausentes são ignorados;
                 pode levar alguns minutos com entradas grandes)
  -h             esta mensagem

EOF
}

CONFERE_ENTRADAS=0
while getopts ":l:o:t:eh" opt; do
  case "${opt}" in
    l) ROTULO="${OPTARG}" ;;
    o) BASE_DIR="${OPTARG}" ;;
    t) TOLERANCIA="${OPTARG}" ;;
    e) CONFERE_ENTRADAS=1 ;;
    h) _uso; exit 0 ;;
    \?) echo "ERRO: opção inválida: -${OPTARG}" >&2; _uso; exit 2 ;;
    :)  echo "ERRO: a opção -${OPTARG} exige argumento" >&2; exit 2 ;;
  esac
done

[[ -z "${ROTULO}" ]] && { echo "ERRO: informe o rótulo com -l" >&2; _uso; exit 2; }

REF="${BASE_DIR}/${ROTULO}/saida"
[[ -d "${REF}" ]] || { echo "ERRO: linha de base não encontrada: ${REF}" >&2; exit 2; }

command -v nccmp >/dev/null 2>&1 || {
  echo "ERRO: nccmp não está no PATH." >&2
  echo "      Carregue o módulo correspondente ou instale o pacote nccmp." >&2
  exit 2
}

# nccmp -d compara dados; -m compara metadados de variável; -f segue até o fim
# em vez de parar na primeira diferença, o que dá um relatório mais útil.
NCCMP_OPTS=(-d -m -f)
[[ -n "${TOLERANCIA}" ]] && NCCMP_OPTS+=(-T "${TOLERANCIA}")

echo "==============================================================="
echo " Comparação com a linha de base ${ROTULO}"
echo "==============================================================="
echo " Referência : ${REF}"
echo " Atual      : $(pwd)"
if [[ -n "${TOLERANCIA}" ]]; then
  echo " Critério   : diferença relativa até ${TOLERANCIA}"
  echo "              ATENÇÃO: as etapas de refatoração exigem identidade"
  echo "              exata. Tolerância só se aplica a etapas declaradas."
else
  echo " Critério   : identidade exata dos dados"
fi
echo "---------------------------------------------------------------"

#-----------------------------------------------------------------------------
# Conferir a integridade da linha de base ANTES de comparar.
#
# O cria-linha-base.bash grava um SHA256SUMS e aplica chmod -R a-w, mas nada
# impede que alguem desfaca a protecao e altere um arquivo, ou que uma copia
# entre maquinas corrompa algo. Comparar contra uma base adulterada produz um
# veredito que parece autoritativo e nao e'. A verificacao custa segundos e
# elimina a duvida.
#-----------------------------------------------------------------------------
BASE_RAIZ="${BASE_DIR}/${ROTULO}"
if [[ -f "${BASE_RAIZ}/SHA256SUMS" ]]; then
  if ( cd "${BASE_RAIZ}" && sha256sum --quiet -c SHA256SUMS ) >/dev/null 2>&1; then
    echo " Integridade: SHA256SUMS confere"
  else
    echo ""
    echo " ERRO: a linha de base ${ROTULO} NAO confere com o seu SHA256SUMS." >&2
    echo "       Arquivos alterados apos o congelamento:" >&2
    ( cd "${BASE_RAIZ}" && sha256sum --quiet -c SHA256SUMS 2>&1 \
        | grep -v ': OK$' | head -10 | sed 's/^/         /' ) >&2
    echo "" >&2
    echo "       Uma base adulterada produz veredito sem valor. Refaca a base" >&2
    echo "       ou use outra." >&2
    exit 2
  fi
else
  echo " Integridade: SHA256SUMS ausente (base anterior a essa verificacao)"
fi

#-----------------------------------------------------------------------------
# Conferir a configuracao automaticamente.
#
# A triagem de FAIL sempre mandou o usuario comparar o nuopc.input a mao. O
# arquivo esta' ali, entao o script faz isso sozinho e AVISA ANTES da
# comparacao, nao depois: saber que a configuracao mudou muda a leitura de
# tudo o que vem a seguir.
#-----------------------------------------------------------------------------
if [[ -f "${BASE_RAIZ}/config/nuopc.input" && -f nuopc.input ]]; then
  if diff -q "${BASE_RAIZ}/config/nuopc.input" nuopc.input >/dev/null 2>&1; then
    echo " Configuração: nuopc.input identico ao da base"
  else
    echo ""
    echo " ATENCAO: o nuopc.input ATUAL difere do congelado na base."
    echo "          Qualquer diferenca de resultado pode vir dai, e nao do codigo."
    diff "${BASE_RAIZ}/config/nuopc.input" nuopc.input \
      | grep -E '^[<>]' | grep -vE '^[<>][[:space:]]*!' | head -12 \
      | sed 's/^/          /'
    echo ""
  fi
fi


#-----------------------------------------------------------------------------
# Conferência das entradas (opção -e).
# O CHECKSUMS.txt tem três colunas (soma, tamanho, arquivo); o sha256sum -c
# espera duas. Entradas que não existem aqui são ignoradas: a lista de bases
# antigas pode incluir saídas de rodadas anteriores gravadas na raiz.
#-----------------------------------------------------------------------------
if [[ ${CONFERE_ENTRADAS} -eq 1 && -f "${BASE_RAIZ}/entrada/CHECKSUMS.txt" ]]; then
  # Saídas que a própria rodada grava na raiz. Linhas de base antigas (ver
  # B-BASE-ENTRADA-01 no CHANGELOG) as registravam como entradas; aqui são
  # ignoradas.
  # Manter igual à lista _PADROES_SAIDA_MODELOS do cria-linha-base.bash.
  _SAIDAS_RAIZ=( 'MONAN_DIAG_*.nc' 'ice.nc' 'ocean_month.nc' 'sea_ice_geometry.nc' \
                 'ocean.stats.nc' 'reprodiag.nc' 'reprodiag_*.nc' )
  # shellcheck disable=SC2206
  [[ -n "${BASE_SAIDA_RAIZ_EXTRA:-}" ]] && _SAIDAS_RAIZ+=( ${BASE_SAIDA_RAIZ_EXTRA} )
  _n_ent=0; _n_ent_dif=0
  while read -r _soma _tam _arq; do
    [[ "${_soma}" =~ ^[0-9a-f]{64}$ && -f "${_arq}" ]] || continue
    _eh_saida=0
    for _pat in "${_SAIDAS_RAIZ[@]}"; do
      # shellcheck disable=SC2053
      [[ "${_arq}" == ${_pat} ]] && { _eh_saida=1; break; }
    done
    [[ ${_eh_saida} -eq 1 ]] && continue
    _n_ent=$((_n_ent + 1))
    if [[ "$(sha256sum "${_arq}" | cut -d' ' -f1)" != "${_soma}" ]]; then
      [[ ${_n_ent_dif} -eq 0 ]] && echo " ATENCAO: entradas diferentes das usadas na base:"
      echo "          ${_arq}"
      _n_ent_dif=$((_n_ent_dif + 1))
    fi
  done < "${BASE_RAIZ}/entrada/CHECKSUMS.txt"
  if [[ ${_n_ent_dif} -eq 0 ]]; then
    echo " Entradas: ${_n_ent} arquivo(s) conferem com a base"
  else
    echo "          Qualquer diferenca de resultado pode vir dai, e nao do codigo."
  fi
fi

n_ok=0; n_dif=0; n_faltando=0; n_extra=0; n_meta=0
TMP_CMP=$(mktemp)
trap 'rm -f "${TMP_CMP}"' EXIT

# ── Compara cada arquivo da referência com o correspondente atual ────────────
for ref_file in "${REF}"/*.nc; do
  [[ -e "${ref_file}" ]] || continue
  nome=$(basename "${ref_file}")

  # Localiza o arquivo correspondente no experimento atual.
  atual=""
  for cand in "diag_export/${nome}" "diag_import/${nome}" "${nome}"; do
    [[ -f "${cand}" ]] && { atual="${cand}"; break; }
  done

  if [[ -z "${atual}" ]]; then
    printf '  %-42s  %s\n' "${nome}" "AUSENTE na rodada atual"
    n_faltando=$(( n_faltando + 1 ))
    continue
  fi

  # A saida do nccmp -f pode ter milhoes de linhas quando o
  # arquivo inteiro difere; guardada numa variavel, estourava a memoria do
  # bash (xrealloc). Vai para um arquivo temporario e so' o inicio e' lido.
  nccmp "${NCCMP_OPTS[@]}" "${ref_file}" "${atual}" > "${TMP_CMP}" 2>&1
  rc_cmp=$?
  saida=$(head -n 12 "${TMP_CMP}")
  if [[ ${rc_cmp} -eq 0 && ! -s "${TMP_CMP}" ]]; then
    printf '  %-42s  %s\n' "${nome}" "igual"
    n_ok=$(( n_ok + 1 ))
  else
    # Separar diferenca de DADOS de diferenca so de METADADOS. O NCCMP_OPTS
    # inclui -m, que compara atributos de variavel, e uma mudanca de long_name
    # ou standard_name faz o arquivo inteiro aparecer como DIFERE mesmo com os
    # dados identicos.
    #
    # Exemplo (docs/uso-linha-base.md): a correcao B-DIAG-SOT-ROTULO-01 alterou o
    # long_name e o standard_name da variavel So_t nos monan2_import_*.nc, sem
    # tocar em nenhum valor. Comparado contra uma linha de base anterior a ela,
    # TODO monan2_import sai como DIFERE, e sem esta distincao a leitura
    # natural seria "o codigo mudou o resultado", que e' falsa.
    #
    # A segunda passada roda so' com -d -f, ou seja, apenas dados. Se ela
    # passar, a diferenca esta' confinada aos metadados.
    dados_opts=(-d -f)
    [[ -n "${TOLERANCIA}" ]] && dados_opts+=(-T "${TOLERANCIA}")
    nccmp "${dados_opts[@]}" "${ref_file}" "${atual}" > "${TMP_CMP}" 2>&1
    rc_dados=$?
    saida_dados=$(head -n 12 "${TMP_CMP}")
    if [[ ${rc_dados} -eq 0 && ! -s "${TMP_CMP}" ]]; then
      printf '  %-42s  %s\n' "${nome}" "difere so nos METADADOS (dados iguais)"
      echo "${saida}" | head -4 | sed 's/^/        /'
      n_meta=$(( n_meta + 1 ))
    else
      printf '  %-42s  %s\n' "${nome}" "DIFERE"
      echo "${saida_dados}" | head -8 | sed 's/^/        /'
      n_dif=$(( n_dif + 1 ))
    fi
  fi
done

# ── Arquivos novos, que a linha de base não tem ──────────────────────────────
for atual in diag_export/*.nc diag_import/*.nc; do
  [[ -e "${atual}" ]] || continue
  nome=$(basename "${atual}")
  [[ -f "${REF}/${nome}" ]] && continue
  printf '  %-42s  %s\n' "${nome}" "EXTRA (não existe na linha de base)"
  n_extra=$(( n_extra + 1 ))
done

# ── Veredito ─────────────────────────────────────────────────────────────────
echo "---------------------------------------------------------------"
printf ' iguais: %d   so metadados: %d   diferentes: %d   ausentes: %d   extras: %d\n' \
  "${n_ok}" "${n_meta}" "${n_dif}" "${n_faltando}" "${n_extra}"
echo "==============================================================="

# Diferenca so' de metadados NAO reprova. O criterio das etapas
# de refatoracao e' identidade dos DADOS; renomear um long_name nao muda
# resultado. Mas e' anunciada, porque tambem nao deve passar despercebida.
if [[ "${n_dif}" -eq 0 && "${n_faltando}" -eq 0 && "${n_extra}" -eq 0 && "${n_ok}" -gt 0 ]] \
   || [[ "${n_dif}" -eq 0 && "${n_faltando}" -eq 0 && "${n_extra}" -eq 0 && "${n_meta}" -gt 0 ]]; then
  echo " PASS — a rodada atual reproduz a linha de base ${ROTULO}"
  if [[ "${n_meta}" -gt 0 ]]; then
    echo ""
    echo " NOTA: ${n_meta} arquivo(s) diferem apenas nos METADADOS de variavel."
    echo "       Os dados sao identicos. Causa tipica: alteracao de long_name ou"
    echo "       standard_name no writer, como a correcao B-DIAG-SOT-ROTULO-01"
    echo "       fez na variavel So_t dos monan2_import_*.nc."
  fi
  echo "==============================================================="
  exit 0
fi

echo " FAIL — a rodada atual NÃO reproduz a linha de base ${ROTULO}"
echo ""
# A assinatura de RENOMEACAO em massa.
#
# Muitos AUSENTE e muitos EXTRA com ZERO diferencas de dados nao significa que
# o resultado mudou: significa que os NOMES dos arquivos mudaram. Sem esta
# nota, a leitura natural e' que a rodada divergiu, e a investigacao comeca no
# lugar errado.
#
# Caso concreto (docs/uso-linha-base.md): a correcao BUG-SEQ-STAMP-01 acertou o
# carimbo de tempo dos diagnosticos em coupling_mode='sequential', que antes
# saiam adiantados em um dt_coupling. Toda linha de base sequencial anterior a
# essa correcao e' incomparavel por construcao, e precisa ser refeita.
if [[ "${n_dif}" -eq 0 && "${n_faltando}" -gt 0 && "${n_extra}" -gt 0 ]]; then
  echo " ATENCAO: ${n_faltando} ausente(s) e ${n_extra} extra(s), com ZERO"
  echo "          diferenca de dados. Essa e' a assinatura de RENOMEACAO dos"
  echo "          arquivos, nao de mudanca de resultado."
  echo ""
  echo "          Confira se a linha de base e' anterior a BUG-SEQ-STAMP-01 e"
  echo "          se a rodada e' sequential: nesse caso a base precisa ser"
  echo "          refeita, e a comparacao nao diz nada sobre o codigo."
  echo "          Ver docs/uso-linha-base.md, secao 8."
  echo ""
fi

echo " Antes de investigar o código, descarte as causas triviais:"
echo "   1. O número de PETs é o mesmo do MANIFEST?"
echo "   2. O nuopc.input é o mesmo de baseline/${ROTULO}/config/?"
echo "      diff nuopc.input ${BASE_DIR}/${ROTULO}/config/nuopc.input"
echo "   3. Os arquivos de entrada têm a mesma soma de verificação?"
echo "      ver ${BASE_DIR}/${ROTULO}/entrada/CHECKSUMS.txt"
echo "   4. Os módulos carregados são os mesmos do MANIFEST?"
echo ""
echo " Só depois disso a diferença é atribuível à alteração de código."
echo "==============================================================="
exit 1
