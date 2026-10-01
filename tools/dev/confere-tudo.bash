#!/usr/bin/env bash
# =============================================================================
# confere-tudo.bash: todas as conferências locais antes de uma rodada na Jaci.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Reúne num comando só as conferências de docs/conferencias-locais.md:
#   compilacao  compila a árvore de trabalho (compila-local.bash); falha se
#               algum fonte não compilar
#   avisos      compila também a versão REV, com as mesmas interfaces
#               mínimas, e falha se algum fonte tiver mais avisos que antes
#   literais    constantes de texto iguais às de REV (confere-literais.py)
#   instrucoes  só com -i: instruções idênticas às de REV na soma dos .F90
#               alterados (etapas que só mudam comentários ou espaços)
#   regrid      testes do framework de interpolação (tests/regrid)
#   gravadores  tests/writers/compara-gravadores.bash REV
#   bulk        tests/bulk/compara-bulk.bash REV
#   grade       tests/atmgrid/compara-grade-atm.bash REV
#   malhas      tests/malhas/compara-malhas.bash REV (malha de fluxo do
#               mediador e grade do cap atmosférico, com 1, 4, 6 e 8 PETs)
#   completar   tests/completar/compara-completar.bash REV (SST e fração de
#               gelo exportada, completadas pela rota, com 1, 4, 6 e 8 PETs)
#   unitarios   testes com valor esperado (tests/unit/roda-unitarios.bash),
#               entre eles o da consistência do mapa de acoplamento
#   mapa        docs/acoplamento.md em dia com o mapa de acoplamento
#               (tools/dev/mapa-acoplamento.py -c)
#   cplcheck    conferência do mapa num driver NUOPC com as listas de campos
#               de hoje (tests/cplcheck/confere-cplcheck.bash)
#   supergrid   tests/supergrid/compara-supergrid.bash REV
#   docn        tests/docn/compara-docn.bash REV (o mais demorado: compila
#               as duas versões e roda o DOCN num driver NUOPC)
# No fim, mostra um resumo (OK, FALHOU ou PULADO) e os indicadores de
# código limpo de REV e da árvore de trabalho (indicadores.py).
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tools/dev/confere-tudo.bash [-i] [-t LISTA] [-o SAIDA] [REV]
#     REV       commit de referência (padrão: HEAD; depois do commit da
#               etapa, use HEAD~1)
#     -i        exige instruções idênticas (acrescenta "instrucoes")
#     -t LISTA  só as conferências da lista, separadas por vírgula
#               (ex.: -t compilacao,literais,bulk)
#     -o SAIDA  diretório de trabalho e logs (padrão: build-local/confere)
#
# Variáveis: MPIRUN (padrão: mpiexec), NP (padrão: 4), FC (padrão: mpif90),
# repassadas aos testes.
# Código de saída: 0 se nenhuma conferência falhou; 1 caso contrário;
# 2 erro de uso ou de preparo.
# =============================================================================
set -uo pipefail

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TODAS="compilacao avisos literais regrid gravadores bulk grade malhas completar unitarios mapa cplcheck supergrid docn"
LISTA=""
EXIGE_INSTR=0
SAIDA=""

uso() { sed -n '2,47p' "$0"; exit 2; }

while getopts "it:o:h" opt; do
  case "${opt}" in
    i) EXIGE_INSTR=1 ;;
    t) LISTA=${OPTARG//,/ } ;;
    o) SAIDA=${OPTARG} ;;
    *) uso ;;
  esac
done
shift $((OPTIND - 1))
REV=${1:-HEAD}

cd "${RAIZ}" || exit 2
git rev-parse --verify --quiet "${REV}^{commit}" > /dev/null \
  || { echo "ERRO: commit '${REV}' não encontrado" >&2; exit 2; }
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] \
  || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

[[ -n "${LISTA}" ]] || LISTA=${TODAS}
[[ ${EXIGE_INSTR} -eq 1 ]] && LISTA="${LISTA} instrucoes"
for c in ${LISTA}; do
  case " ${TODAS} instrucoes " in *" ${c} "*) ;; *) echo "ERRO: conferência '${c}' desconhecida" >&2; exit 2 ;; esac
done

SAIDA=$(mkdir -p "${SAIDA:-${RAIZ}/build-local/confere}" && cd "${SAIDA:-${RAIZ}/build-local/confere}" && pwd)
LOGS="${SAIDA}/logs"
mkdir -p "${LOGS}"

declare -A RESULTADO TEMPO
ORDEM=""

quer() { case " ${LISTA} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# executa NOME COMANDO...; guarda OK/FALHOU e o tempo; saída em logs/NOME.log
executa() {
  local nome=$1; shift
  local t0=${SECONDS}
  echo "== ${nome}: $*"
  if "$@" > "${LOGS}/${nome}.log" 2>&1; then
    RESULTADO[${nome}]=OK
  else
    RESULTADO[${nome}]=FALHOU
  fi
  TEMPO[${nome}]=$((SECONDS - t0))
  ORDEM="${ORDEM} ${nome}"
  echo "   ${RESULTADO[${nome}]} ($((SECONDS - t0)) s; log em ${LOGS}/${nome}.log)"
}

pula() {
  RESULTADO[$1]="PULADO ($2)"
  TEMPO[$1]=0
  ORDEM="${ORDEM} $1"
}

# ---------------------------------------------------------------------------
# Compilação da árvore de trabalho e da versão REV
# ---------------------------------------------------------------------------
if quer compilacao || quer avisos; then
  executa compilacao tools/dev/compila-local.bash -o "${SAIDA}/atual"
fi

compara_avisos() {
  # extrai REV, compila com as interfaces mínimas da árvore de trabalho e
  # compara o número de avisos por fonte
  local ref="${SAIDA}/rev"
  rm -rf "${ref}" && mkdir -p "${ref}/fonte" || return 2
  git archive "${REV}" src | tar -x -C "${ref}/fonte" || return 2
  tools/dev/compila-local.bash -a -s "${ref}/fonte" -o "${ref}/build" > "${ref}/compilacao.txt" 2>&1
  local piorou=0 nome res avisos antes
  while read -r nome res avisos; do
    [[ "${res}" == OK ]] || continue
    avisos=${avisos#avisos=}
    antes=$(awk -v n="${nome}" '$1 == n && $2 == "OK" { sub("avisos=", "", $3); print $3 }' "${ref}/compilacao.txt")
    if [[ -z "${antes}" ]]; then
      echo "${nome}: novo ou sem compilação em ${REV} (${avisos} avisos)"
    elif (( avisos > antes )); then
      echo "${nome}: ${antes} -> ${avisos} avisos (PIOROU)"
      piorou=1
    else
      echo "${nome}: ${antes} -> ${avisos} avisos"
    fi
  done < <(grep -E ' (OK|FALHOU) ' "${LOGS}/compilacao.log")
  return ${piorou}
}

if quer avisos; then
  if [[ ${RESULTADO[compilacao]} == OK ]]; then
    executa avisos compara_avisos
  else
    pula avisos "compilação falhou"
  fi
fi

# ---------------------------------------------------------------------------
# Constantes de texto e instruções
# ---------------------------------------------------------------------------
quer literais && executa literais tools/dev/confere-literais.py "${REV}"

confere_instrucoes() {
  local n saida
  mapfile -t arquivos < <(git diff --name-only "${REV}" -- '*.F90')
  if [[ ${#arquivos[@]} -eq 0 ]]; then
    echo "nenhum .F90 alterado desde ${REV}"
    return 0
  fi
  # Soma de todos os arquivos alterados: um trecho que mudou de arquivo
  # conta como a mesma instrução.
  saida=$(tools/dev/confere-instrucoes.py "${REV}" "${arquivos[@]}")
  n=$(grep -c '^   (' <<< "${saida}")
  if [[ ${n} -eq 0 ]]; then
    echo "${#arquivos[@]} arquivo(s) alterado(s): instruções idênticas"
    return 0
  fi
  echo "${#arquivos[@]} arquivo(s) alterado(s): ${n} instrução(ões) diferente(s)"
  echo "${saida}"
  return 1
}
quer instrucoes && executa instrucoes confere_instrucoes

# ---------------------------------------------------------------------------
# Testes
# ---------------------------------------------------------------------------
teste_regrid() {
  local saida
  make -C tests/regrid clean > /dev/null && make -C tests/regrid || return 1
  saida=$(make -C tests/regrid run NP="${NP:-4}" MPIEXEC="${MPIRUN:-mpiexec}" 2>&1)
  echo "${saida}"
  grep -q 'TODOS OS TESTES PASSARAM' <<< "${saida}"
}
quer regrid     && executa regrid teste_regrid
quer gravadores && executa gravadores tests/writers/compara-gravadores.bash "${REV}" "${SAIDA}/writers"
quer bulk       && executa bulk tests/bulk/compara-bulk.bash "${REV}" "${SAIDA}/bulk"
quer grade      && executa grade tests/atmgrid/compara-grade-atm.bash "${REV}" "${SAIDA}/atmgrid"
quer malhas     && executa malhas tests/malhas/compara-malhas.bash "${REV}" "${SAIDA}/malhas"
quer completar  && executa completar tests/completar/compara-completar.bash "${REV}" "${SAIDA}/completar"
quer unitarios  && executa unitarios tests/unit/roda-unitarios.bash "${SAIDA}/unit"
quer mapa       && executa mapa python3 tools/dev/mapa-acoplamento.py -c
quer cplcheck   && executa cplcheck tests/cplcheck/confere-cplcheck.bash "${SAIDA}/cplcheck"
quer supergrid  && executa supergrid tests/supergrid/compara-supergrid.bash "${REV}" "${SAIDA}/supergrid"
quer docn       && executa docn tests/docn/compara-docn.bash "${REV}" "${SAIDA}/docn"

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
echo
echo "Resumo (referência: ${REV})"
falhas=0
for nome in ${ORDEM}; do
  printf '  %-12s %-28s %5s s\n' "${nome}" "${RESULTADO[${nome}]}" "${TEMPO[${nome}]}"
  [[ ${RESULTADO[${nome}]} == FALHOU ]] && falhas=$((falhas + 1))
done
echo
echo "Indicadores de código limpo:"
python3 tools/dev/indicadores.py "${REV}" . | tee "${LOGS}/indicadores.md"
echo
if [[ ${falhas} -eq 0 ]]; then
  echo "TUDO OK: nenhuma conferência falhou. Logs em ${LOGS}"
  exit 0
fi
echo "${falhas} conferência(s) falharam. Logs em ${LOGS}"
exit 1
