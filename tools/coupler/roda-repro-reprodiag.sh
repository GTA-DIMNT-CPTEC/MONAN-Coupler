#!/usr/bin/env bash
#=============================================================================
# roda-repro-reprodiag.sh
#
# Dupla rodada do acoplado voltada a UMA pergunta: em qual PASSO DE TEMPO o
# estado do MPAS começa a divergir entre duas execuções idênticas?
#
# POR QUE UM SCRIPT SEPARADO
# O roda_repro_producao.sh compara os 72 NetCDF de diag_export/ e diag_import/,
# que saem a cada hora de acoplamento. Isso dá resolução de 1 hora, e a
# divergência já está presente na primeira. O stream reprodiag grava a cada
# passo de tempo do modelo, num único arquivo na RAIZ do experimento, e é esse
# arquivo que este script preserva das duas rodadas e compara.
#
# (O cria-linha-base.bash também passou a congelar NetCDF da raiz — ver
#  B-BASE-RAIZ-NC-01. Este script continua útil porque não depende de linha de
#  base, roda mais rápido e responde diretamente com o índice do registro.)
#
# O QUE O RESULTADO SIGNIFICA
#   primeiro registro divergente = 1  -> o estado do MPAS já difere no PRIMEIRO
#       passo de física, com importação idêntica em t=0. A semente está dentro
#       do MPAS sob acoplamento, e os suspeitos passam a ser as diferenças em
#       relação ao MPAS autônomo (que reproduz 9 de 9 em 24 h): os caminhos
#       ativados por -DCOUPLER, o comunicador MPI ser um subconjunto de 72
#       PETs, e o gerenciador de tempo ESMF externo.
#   primeiro registro divergente > 1  -> há N passos determinísticos antes da
#       separação. O número de passos é informação de localização: diz quanta
#       física roda antes de a divergência aparecer.
#   nenhum registro divergente        -> o estado do MPAS na malha nativa
#       reproduz, e a divergência dos diagnósticos vem da escrita ou do
#       binning, não da integração. Resultado surpreendente; verificar antes
#       de acreditar.
#
# PRÉ-REQUISITO
# O bloco <stream name="reprodiag"> tem de estar no streams.atmosphere. Ver
# stream-reprodiag.xml. O script verifica e aborta se não estiver.
#
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#=============================================================================
set -euo pipefail

NPES="${NPES:-72}"
WALLTIME="${WALLTIME:-01:00:00}"
POLL="${POLL:-30}"
RUNNER="${RUNNER:-/p/projetos/gta/daniel.massaru/coupling/Coupler-Install/MONAN-Coupler/run/run_esmApp.jaci}"
ARQ="${ARQ:-reprodiag.nc}"
VAR="${VAR:-surface_pressure}"

ok()    { printf '   OK      %s\n' "$*"; }
info()  { printf '   INFO    %s\n' "$*"; }
falha() { printf '   FALHOU  %s\n' "$*"; }
morre() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
Uso: bash roda-repro-reprodiag.sh [OPÇÕES]

  Lançar do diretório do experimento. Executa duas vezes o acoplado na
  configuração ATUAL (não altera nuopc.input nem streams.atmosphere),
  preserva o reprodiag.nc de cada rodada e informa o PRIMEIRO registro
  que difere.

Opções:
  --npes N          PETs (default: 72)
  --walltime T      (default: 01:00:00)
  --runner CAMINHO  script de submissão (default: run/run_esmApp.jaci)
  --var NOME        variável usada na comparação (default: surface_pressure)
  --help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --npes)     NPES="$2";     shift 2 ;;
    --walltime) WALLTIME="$2"; shift 2 ;;
    --runner)   RUNNER="$2";   shift 2 ;;
    --var)      VAR="$2";      shift 2 ;;
    --help|-h)  usage ;;
    *) echo "ERRO: opção desconhecida: $1  (use --help)" >&2; exit 1 ;;
  esac
done

echo
echo "== 0. Pre-condicoes =="

[[ -f nuopc.input ]]        || morre "nuopc.input nao encontrado. Rode do diretorio do experimento."
[[ -f streams.atmosphere ]] || morre "streams.atmosphere nao encontrado."
[[ -x "${RUNNER}" || -f "${RUNNER}" ]] || morre "script de submissao nao encontrado: ${RUNNER}"
ok "diretorio do experimento e script de submissao"

# O stream tem de estar declarado, senao as duas rodadas sao gastas para nada.
if grep -qE '<stream[[:space:]]+name="reprodiag"' streams.atmosphere; then
  _oi="$(grep -A6 'name="reprodiag"' streams.atmosphere \
         | grep -oE 'output_interval="[^"]*"' | head -1)"
  ok "stream reprodiag declarado  (${_oi:-output_interval nao encontrado})"
else
  falha "o bloco <stream name=\"reprodiag\"> NAO esta no streams.atmosphere."
  echo  "           Sem ele nenhum ${ARQ} e' gravado e as duas rodadas seriam"
  echo  "           gastas sem produzir resposta. Cole o bloco de"
  echo  "           stream-reprodiag.xml antes de </streams>."
  morre "stream ausente"
fi

# config_dt: o output_interval do stream tem de ser multiplo dele. Um intervalo
# menor que o passo faz o MPAS gravar o mesmo estado repetido, e o indice do
# registro deixa de corresponder a um passo de tempo.
_dt="$(grep -E '^\s*config_dt' namelist.atmosphere 2>/dev/null | head -1 || true)"
info "namelist:${_dt:- config_dt nao encontrado — confira manualmente}"

command -v nccmp > /dev/null 2>&1 || {
  NCCMP_ENV="${COUPLER_ROOT:-../Coupler-Install/MONAN-Coupler}/tools/dev/set-nccmp-jaci.bash"
  # shellcheck disable=SC1090
  [[ -r "${NCCMP_ENV}" ]] && source "${NCCMP_ENV}"
}
command -v nccmp > /dev/null 2>&1 || morre "nccmp indisponivel no PATH"
ok "nccmp disponivel"

for R in A B; do
  [[ -e "reprodiag_${R}.nc" ]] && morre "reprodiag_${R}.nc ja existe. Remova antes de repetir."
done

#-----------------------------------------------------------------------------
# Espera: o script de submissao imprime o jobid em formato proprio, e analisar
# essa saida seria frágil. Espera-se, em vez disso, a fila do usuario drenar.
# Consequencia a conhecer: se houver OUTRO job seu na fila, a espera fica mais
# longa do que o necessario, mas nunca mais curta — nao ha risco de comparar
# arquivo incompleto.
#-----------------------------------------------------------------------------
espera_fila() {
  sleep 10   # deixa o job aparecer na fila antes da primeira consulta
  while qstat -u "${USER}" 2>/dev/null | grep -qE '[[:space:]][QRHEBW][[:space:]]'; do
    printf '   [%s]  fila ocupada, aguardando\n' "$(date +%H:%M:%S)"
    sleep "${POLL}"
  done
}

for R in A B; do
  echo
  echo "== Rodada ${R} =="
  rm -f "${ARQ}"
  bash "${RUNNER}" -n "${NPES}" -w "${WALLTIME}" || morre "submissao da rodada ${R} falhou"
  espera_fila
  [[ -s "${ARQ}" ]] || {
    falha "rodada ${R} nao gerou ${ARQ}"
    echo  "           Verifique esmApp_run.log e log.atmosphere.0000.out: ou a"
    echo  "           rodada abortou, ou o stream nao gravou (nomes de variavel"
    echo  "           inexistentes no Registry fazem o MPAS falhar na abertura)."
    morre "sem ${ARQ} na rodada ${R}"
  }
  mv "${ARQ}" "reprodiag_${R}.nc"
  _nrec="$(ncdump -h "reprodiag_${R}.nc" | grep -oE 'Time = UNLIMITED ; // \([0-9]+' \
           | grep -oE '[0-9]+$' || echo '?')"
  ok "rodada ${R}: reprodiag_${R}.nc  (${_nrec} registro(s))"
done

echo
echo "== Comparacao A x B =="

saida="$(nccmp -d -f -v "${VAR}" reprodiag_A.nc reprodiag_B.nc 2>&1 || true)"

if [[ -z "${saida}" ]]; then
  echo
  echo "   ${VAR}: IDENTICO em todos os registros."
  echo
  echo "   O estado do MPAS na malha nativa reproduz bit a bit, enquanto os"
  echo "   diagnosticos horarios divergem. Isso apontaria para a escrita ou o"
  echo "   binning dos diagnosticos, e nao para a integracao — resultado"
  echo "   surpreendente o suficiente para conferir antes de aceitar:"
  echo "     1. ${ARQ} tem mais de um registro? (ver contagem acima)"
  echo "     2. a variavel ${VAR} varia no tempo? compare dois registros"
  echo "        dela dentro de uma MESMA rodada antes de concluir."
  echo "   Repita com --var t2m para uma segunda opiniao."
  exit 0
fi

# Primeiro registro divergente: menor primeiro indice entre as POSITION.
# A primeira dimensao de reprodiag e' Time, logo esse indice E' o registro.
primeiro="$(printf '%s\n' "${saida}" \
            | grep -oE 'POSITION[^[]*\[[0-9]+' \
            | grep -oE '[0-9]+$' | sort -n | head -1 || true)"

printf '   %s: DIFERE\n' "${VAR}"
printf '%s\n' "${saida}" | head -8 | sed 's/^/        /'
echo

if [[ -n "${primeiro}" ]]; then
  printf '   Primeiro registro divergente: %s  (indice como o nccmp reporta)\n' "${primeiro}"
  _xt="$(ncdump -v xtime reprodiag_A.nc 2>/dev/null \
         | sed -n '/xtime *=/,$p' | tr ',' '\n' | grep -oE '"[^"]+"' \
         | sed -n "${primeiro}p" || true)"
  [[ -n "${_xt}" ]] && printf '   xtime desse registro:         %s\n' "${_xt}"
  echo
  if [[ "${primeiro}" -le 1 ]]; then
    echo "   LEITURA: divergencia JA no primeiro registro. Com a importacao"
    echo "   identica em t=0, o estado do MPAS se separa no primeiro passo de"
    echo "   fisica. A semente esta dentro do MPAS sob acoplamento."
    echo "   Suspeitos, que sao a diferenca em relacao ao MPAS autonomo:"
    echo "     - caminhos de codigo ativados por -DCOUPLER"
    echo "     - comunicador MPI do MPAS como subconjunto de ${NPES} PETs"
    echo "     - gerenciador de tempo ESMF externo (-DMPAS_EXTERNAL_ESMF_LIB)"
  else
    echo "   LEITURA: houve $(( primeiro - 1 )) registro(s) identico(s) antes da"
    echo "   separacao. Esse numero e' informacao de localizacao: diz quanta"
    echo "   fisica roda de forma deterministica antes da divergencia aparecer."
  fi
else
  info "nao foi possivel extrair o indice do registro da saida do nccmp;"
  info "  leia as linhas POSITION acima manualmente."
fi

echo
echo "   Arquivos preservados: reprodiag_A.nc  reprodiag_B.nc"
echo "   Outras variaveis:     nccmp -d -f -v t2m reprodiag_A.nc reprodiag_B.nc"
exit 1
