#!/usr/bin/env bash
# =============================================================================
# anota-linha-base.bash: acrescenta uma observação ao MANIFEST.txt de uma
# linha de base já congelada e atualiza a soma dele no SHA256SUMS.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# A linha de base é protegida contra escrita (chmod a-w) e cada arquivo dela
# tem a soma registrada no SHA256SUMS. O compara-linha-base.bash confere essas
# somas antes de comparar e se recusa a continuar se algum arquivo mudou.
# Editar o MANIFEST à mão, portanto, trava a comparação. Este script faz a
# anotação e a atualização da soma juntas, e só mexe nesses dois arquivos: as
# saídas, a configuração e as entradas congeladas continuam intocadas.
#
# Uso:
#   anota-linha-base.bash -l R-NOFMA-02 -m "texto da observação"
#   anota-linha-base.bash -l R-NOFMA-02 -r    # registra uma edição já feita
#
# Opções:
#   -l RÓTULO      obrigatório
#   -o DIRETÓRIO   raiz das linhas de base (padrão: ./baseline)
#   -m TEXTO       observação a acrescentar no fim do MANIFEST.txt
#   -r             não acrescenta nada; registra no SHA256SUMS a soma do
#                  MANIFEST.txt que já foi editado à mão. Só é aceito se o
#                  MANIFEST.txt for o ÚNICO arquivo que não confere.
#   -h             esta mensagem
#
# Códigos de saída: 0 sucesso; 1 falha; 2 erro de uso ou pré-condição.
# =============================================================================

set -uo pipefail

ROTULO=""; BASE_DIR="baseline"; TEXTO=""; REGISTRA=0

_uso() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":l:o:m:rh" opt; do
  case "${opt}" in
    l) ROTULO="${OPTARG}" ;;
    o) BASE_DIR="${OPTARG}" ;;
    m) TEXTO="${OPTARG}" ;;
    r) REGISTRA=1 ;;
    h) _uso; exit 0 ;;
    \?) echo "ERRO: opção inválida: -${OPTARG}" >&2; exit 2 ;;
    :)  echo "ERRO: a opção -${OPTARG} exige argumento" >&2; exit 2 ;;
  esac
done

[[ -n "${ROTULO}" ]] || { echo "ERRO: informe o rótulo com -l" >&2; exit 2; }
if [[ -n "${TEXTO}" && ${REGISTRA} -eq 1 ]] || [[ -z "${TEXTO}" && ${REGISTRA} -eq 0 ]]; then
  echo "ERRO: use -m TEXTO ou -r (um dos dois)" >&2; exit 2
fi

RAIZ="${BASE_DIR}/${ROTULO}"
for f in MANIFEST.txt SHA256SUMS; do
  [[ -f "${RAIZ}/${f}" ]] || { echo "ERRO: ${RAIZ}/${f} não existe" >&2; exit 2; }
done
grep -q '  \./MANIFEST\.txt$' "${RAIZ}/SHA256SUMS" \
  || { echo "ERRO: o SHA256SUMS não tem a linha do ./MANIFEST.txt" >&2; exit 2; }

cd "${RAIZ}" || exit 2

# ── Estado antes: que arquivos não conferem? ────────────────────────────────
nao_conferem=$(sha256sum -c SHA256SUMS 2>/dev/null | grep -v ': OK$' | sed 's/: FAILED.*$//')

if [[ ${REGISTRA} -eq 0 && -n "${nao_conferem}" ]]; then
  echo "ERRO: a linha de base ${ROTULO} já não confere com o SHA256SUMS:" >&2
  echo "${nao_conferem}" | sed 's/^/         /' >&2
  echo "       Resolva isso antes de anotar (se foi só o MANIFEST.txt, use -r)." >&2
  exit 2
fi
if [[ ${REGISTRA} -eq 1 ]]; then
  if [[ -z "${nao_conferem}" ]]; then
    echo "Nada a registrar: o SHA256SUMS já confere."; exit 0
  fi
  if [[ "${nao_conferem}" != "./MANIFEST.txt" ]]; then
    echo "ERRO: além do MANIFEST.txt, estes arquivos não conferem:" >&2
    echo "${nao_conferem}" | grep -vx './MANIFEST.txt' | sed 's/^/         /' >&2
    echo "       Isso não é uma anotação: a linha de base foi alterada. Refaça-a." >&2
    exit 1
  fi
fi

# ── Liberar escrita só nos dois arquivos, e devolver a proteção no fim ──────
chmod u+w MANIFEST.txt SHA256SUMS || { echo "ERRO: chmod u+w falhou" >&2; exit 1; }
trap 'chmod a-w MANIFEST.txt SHA256SUMS' EXIT

soma_antes=$(awk '$2 == "./MANIFEST.txt" {print $1}' SHA256SUMS)

if [[ ${REGISTRA} -eq 0 ]]; then
  {
    echo ""
    echo "Observação ($(date '+%Y-%m-%d'), ${USER:-$(id -un)}): ${TEXTO}"
  } >> MANIFEST.txt || { echo "ERRO: não foi possível escrever no MANIFEST.txt" >&2; exit 1; }
fi

soma_nova=$(sha256sum ./MANIFEST.txt | cut -d' ' -f1)
# O diretório continua sem escrita: o novo conteúdo é montado em memória e
# gravado por cima do próprio SHA256SUMS, sem arquivo temporário ao lado.
novo=$(awk -v s="${soma_nova}" '$2 == "./MANIFEST.txt" {print s "  ./MANIFEST.txt"; next} {print}' SHA256SUMS)
printf '%s\n' "${novo}" > SHA256SUMS || { echo "ERRO: não foi possível gravar o SHA256SUMS" >&2; exit 1; }

if sha256sum --quiet -c SHA256SUMS >/dev/null 2>&1; then
  if [[ ${REGISTRA} -eq 1 ]]; then
    echo "Linha de base ${ROTULO}: soma do MANIFEST.txt editado registrada no SHA256SUMS."
  else
    echo "Linha de base ${ROTULO}: MANIFEST.txt anotado e SHA256SUMS atualizado."
  fi
  echo "  soma anterior do MANIFEST.txt: ${soma_antes}"
  echo "  soma nova                    : ${soma_nova}"
  echo "  conferência do SHA256SUMS    : OK"
  exit 0
fi
echo "ERRO: depois da atualização o SHA256SUMS ainda não confere." >&2
exit 1
