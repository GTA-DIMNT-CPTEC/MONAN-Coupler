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
  -h             esta mensagem

EOF
}

while getopts ":l:o:t:h" opt; do
  case "${opt}" in
    l) ROTULO="${OPTARG}" ;;
    o) BASE_DIR="${OPTARG}" ;;
    t) TOLERANCIA="${OPTARG}" ;;
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
# B-CMP-INTEG-01 (Set/2026): conferir a integridade da linha de base ANTES de
# comparar.
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
# B-CMP-CFG-01 (Set/2026): conferir a configuracao automaticamente.
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


n_ok=0; n_dif=0; n_faltando=0; n_extra=0; n_meta=0

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

  saida=$(nccmp "${NCCMP_OPTS[@]}" "${ref_file}" "${atual}" 2>&1)
  rc_cmp=$?
  if [[ ${rc_cmp} -eq 0 && -z "${saida}" ]]; then
    printf '  %-42s  %s\n' "${nome}" "igual"
    n_ok=$(( n_ok + 1 ))
  else
    # B-CMP-META-01 (Set/2026): separar diferenca de DADOS de diferenca so de
    # METADADOS. O NCCMP_OPTS inclui -m, que compara atributos de variavel, e
    # uma mudanca de long_name ou standard_name faz o arquivo inteiro aparecer
    # como DIFERE mesmo com os dados identicos.
    #
    # Isso deixou de ser hipotetico: a correcao B-DIAG-SOT-ROTULO-01 alterou o
    # long_name e o standard_name da variavel So_t nos monan2_import_*.nc, sem
    # tocar em nenhum valor. Comparado contra uma linha de base anterior a ela,
    # TODO monan2_import sai como DIFERE, e sem esta distincao a leitura
    # natural seria "o codigo mudou o resultado", que e' falsa.
    #
    # A segunda passada roda so' com -d -f, ou seja, apenas dados. Se ela
    # passar, a diferenca esta' confinada aos metadados.
    dados_opts=(-d -f)
    [[ -n "${TOLERANCIA}" ]] && dados_opts+=(-T "${TOLERANCIA}")
    saida_dados=$(nccmp "${dados_opts[@]}" "${ref_file}" "${atual}" 2>&1)
    if [[ $? -eq 0 && -z "${saida_dados}" ]]; then
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

# B-CMP-META-01: diferenca so' de metadados NAO reprova. O criterio das etapas
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
# B-CMP-RENAME-01 (Set/2026): a assinatura de RENOMEACAO em massa.
#
# Muitos AUSENTE e muitos EXTRA com ZERO diferencas de dados nao significa que
# o resultado mudou: significa que os NOMES dos arquivos mudaram. Sem esta
# nota, a leitura natural e' que a rodada divergiu, e a investigacao comeca no
# lugar errado.
#
# Caso concreto: a correcao BUG-SEQ-STAMP-01 acertou o carimbo de tempo dos
# diagnosticos em coupling_mode='sequential', que antes saiam adiantados em um
# dt_coupling. Toda linha de base sequencial anterior a essa correcao e'
# incomparavel por construcao, e precisa ser refeita.
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
