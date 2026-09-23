#!/usr/bin/env bash
#=============================================================================
# roda-repro-mpas-standalone.sh
#
# Dupla rodada do MONAN-A (MPAS-A) AUTÔNOMO, fora do acoplador, para responder
# se o modelo atmosférico é bit a bit reprodutível em 64 PETs por conta própria.
#
# Contexto: a bateria de reprodutibilidade do acoplado mostrou que o estado do
# MPAS diverge entre duas rodadas idênticas, e descartou memória não
# inicializada como causa (pilha, tipos derivados, caracteres e monte cobertos,
# sem alterar a assinatura da divergência). O isolamento via DOCN não é
# executável na develop atual (campos da Fase 1 incompatíveis com o cap, ver
# B-DOCN-FASE1-CAMPOS-01). Este teste tira o acoplador inteiro do circuito.
#
# LEITURA DO VEREDITO (assimétrica — vale reler antes de concluir):
#   DIFERE     conclusivo: o MPAS-A não é determinístico sozinho; o acoplamento
#              não tem parte nisso.
#   IDÊNTICO   indício, não prova: o binário deste teste é compilado sem
#              -DCOUPLER, então não exercita os caminhos de código do
#              acoplamento. Não absolve o binário acoplado.
#
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#=============================================================================
set -euo pipefail

#-----------------------------------------------------------------------------
# Parâmetros (sobrescrevíveis por ambiente ou por opção)
#-----------------------------------------------------------------------------
NPES="${NPES:-64}"                   # deve casar com o .graph.info.part.N
WALLTIME="${WALLTIME:-01:00:00}"
QUEUE="${QUEUE:-pesqextra}"
DURATION="${DURATION:-}"             # ex: '1_00:00:00'; vazio = usa o namelist
POLL="${POLL:-30}"
WORKDIR="${WORKDIR:-repro-standalone}"
MPIEXEC="${MPIEXEC:-/opt/cray/pals/1.6/bin/mpiexec}"

usage() {
  cat << 'EOF'
Uso: bash roda-repro-mpas-standalone.sh [OPÇÕES]

  Executa duas vezes o MPAS-A autônomo com a MESMA configuração e compara os
  MONAN_DIAG bit a bit. Deve ser lançado do diretório do experimento, onde
  estão namelist.atmosphere, streams.atmosphere, x1.*.init.nc e as tabelas.

Opções:
  --exe CAMINHO     atmosphere_model a usar (default: procura na árvore)
  --npes N          número de PETs (default: 64; exige .graph.info.part.N)
  --walltime HH:MM:SS
  --queue NOME
  --duration D      sobrescreve config_run_duration NAS CÓPIAS (ex: 1_00:00:00)
  --help
EOF
  exit 0
}

EXE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exe)      EXE="$2";      shift 2 ;;
    --npes)     NPES="$2";     shift 2 ;;
    --walltime) WALLTIME="$2"; shift 2 ;;
    --queue)    QUEUE="$2";    shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --help|-h)  usage ;;
    *) echo "ERRO: opção desconhecida: $1  (use --help)" >&2; exit 1 ;;
  esac
done

BASE="$(pwd)"
RUN_DIR="${BASE}/${WORKDIR}"

ok()    { printf '   OK      %s\n' "$*"; }
info()  { printf '   INFO    %s\n' "$*"; }
falha() { printf '   FALHOU  %s\n' "$*"; }
morre() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

echo
echo "== 0. Pre-condicoes =="

#-----------------------------------------------------------------------------
# Executável
#-----------------------------------------------------------------------------
if [[ -z "${EXE}" ]]; then
  for _c in \
      "${BASE}/atmosphere_model" \
      "${BASE}/../Coupler-Install/MONAN-Coupler/models/atmos/MONAN-Model/atmosphere_model" \
      "${COUPLER_ROOT:-/dev/null}/models/atmos/MONAN-Model/atmosphere_model"; do
    [[ -x "${_c}" ]] && { EXE="$(cd "$(dirname "${_c}")" && pwd)/$(basename "${_c}")"; break; }
  done
fi
[[ -n "${EXE}" && -x "${EXE}" ]] || morre "atmosphere_model nao encontrado. Use --exe CAMINHO."
ok "executavel  : ${EXE}"

# Duas checagens no binário, lidas das cadeias literais do open() compilado.
#
# (a) PRECISÃO. O Makefile do MPAS só aplica -fdefault-real-8 quando
#     PRECISION=double vem na linha de comando; o default e' precisao SIMPLES,
#     e nesse caso ele define -DSINGLE_PRECISION. Em precisao simples o RRTMG
#     abre 'RRTMG_SW_DATA' em vez de 'RRTMG_SW_DATA.DBL': o arquivo nao existe
#     no experimento, o open do gfortran cria um vazio, e a rodada morre em
#     "error reading RRTMG_SW_DATA on unit 101".
#
#     A decisao e' de tres vias de proposito. Abortar so' quando ha' EVIDENCIA
#     POSITIVA de precisao simples (nome curto presente e .DBL ausente); se
#     nenhuma das cadeias aparecer, apenas avisa, porque o compilador pode ter
#     fundido o literal e um falso negativo barraria um binario bom.
_has_dbl=0; _has_short=0
grep -aq 'RRTMG_SW_DATA\.DBL' "${EXE}" 2>/dev/null && _has_dbl=1
grep -aq 'RRTMG_SW_DATA'       "${EXE}" 2>/dev/null && _has_short=1

if [[ "${_has_dbl}" -eq 1 ]]; then
  ok "precisao     : dupla (RRTMG_SW_DATA.DBL no binario)"
elif [[ "${_has_short}" -eq 1 ]]; then
  falha "este binario parece compilado em precisao SIMPLES:"
  echo  "           encontrei 'RRTMG_SW_DATA' e NAO encontrei 'RRTMG_SW_DATA.DBL'."
  echo  "           O RRTMG vai procurar o arquivo sem .DBL, que nao existe no"
  echo  "           experimento, e a rodada aborta na inicializacao da fisica."
  echo  "           Recompile passando PRECISION=double:"
  echo  "             make clean CORE=atmosphere"
  echo  "             make gfortran-xd2000-standalone CORE=atmosphere PRECISION=double -j 8"
  morre "binario em precisao simples: incompativel com as entradas .DBL"
else
  info "precisao nao identificada no binario; confirme que compilou com"
  info "  PRECISION=double (sem isso a rodada aborta no RRTMG)"
fi
unset _has_dbl _has_short

# (b) ACOPLAMENTO. O build de producao define -DCOUPLER e -DMPAS_NO_ESMF_INIT;
#     com eles o MPAS nao chama ESMF_Initialize, e rodar fora do esmApp deixa o
#     gerenciador de tempo sem inicializacao.
if grep -aq 'gfortran-coupler-xd2000' "${EXE}" 2>/dev/null; then
  falha "este binario foi compilado com o alvo do ACOPLADOR (-DCOUPLER,"
  echo  "           -DMPAS_NO_ESMF_INIT). Rodar fora do esmApp e' invalido."
  morre "binario do acoplado: inadequado para o teste autonomo"
fi

#-----------------------------------------------------------------------------
# B-STANDALONE-LDD-01: as bibliotecas compartilhadas do binario resolvem?
#
# Em 20/09/2026 o alvo standalone-esmflib foi ligado com -lesmf mas sem rpath,
# e o job autonomo nao carrega o ambiente do acoplador. O carregador dinamico
# abortou com "libesmf.so: cannot open shared object file" ANTES do main: o
# MPAS nem iniciou, nao houve log.atmosphere.*, e tres jobs foram gastos para
# descobrir isso. Um 'ldd' no no' de login acusa o mesmo em um segundo.
#
# Se ESMF_LIBDIR estiver definido, ele entra no LD_LIBRARY_PATH antes da
# checagem e tambem no job (ver gera_pbs), que e' o que o alvo precisa.
#-----------------------------------------------------------------------------
if [[ -n "${ESMF_LIBDIR:-}" ]]; then
  export LD_LIBRARY_PATH="${ESMF_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  info "ESMF_LIBDIR no LD_LIBRARY_PATH: ${ESMF_LIBDIR}"
fi
_faltam="$(ldd "${EXE}" 2>/dev/null | grep 'not found' || true)"
if [[ -n "${_faltam}" ]]; then
  falha "bibliotecas compartilhadas nao encontradas pelo carregador:"
  printf '%s\n' "${_faltam}" | sed 's/^/           /'
  echo  "           O binario abortaria antes do main, sem log do MPAS."
  echo  "           Se for a libesmf.so, exporte o caminho e relance:"
  echo  "             export ESMF_LIBDIR=<.../esmf-8.9.1/lib/libO/Linux.gfortran.64.mpich2.default>"
  morre "dependencia dinamica ausente"
fi
ok "bibliotecas compartilhadas resolvem (ldd)"

#-----------------------------------------------------------------------------
# Entradas obrigatórias
#-----------------------------------------------------------------------------
REQ=( namelist.atmosphere streams.atmosphere
      RRTMG_SW_DATA.DBL RRTMG_LW_DATA.DBL
      CAM_ABS_DATA.DBL CAM_AEROPT_DATA.DBL
      LANDUSE.TBL VEGPARM.TBL SOILPARM.TBL GENPARM.TBL )

for _f in "${REQ[@]}"; do
  [[ -e "${BASE}/${_f}" ]] || morre "entrada obrigatoria ausente: ${_f}"
done
ok "namelist, streams e tabelas presentes"

INIT_NC="$(ls -1 "${BASE}"/x1.*.init.nc 2>/dev/null | head -1 || true)"
[[ -n "${INIT_NC}" ]] || morre "x1.*.init.nc nao encontrado"
ok "condicao inicial: $(basename "${INIT_NC}")"

PART="$(ls -1 "${BASE}"/x1.*.graph.info.part."${NPES}" 2>/dev/null | head -1 || true)"
[[ -n "${PART}" ]] || morre "particao METIS x1.*.graph.info.part.${NPES} ausente (npes=${NPES})"
ok "particao METIS: $(basename "${PART}")"

# stream_list.* sao opcionais, mas se existirem devem acompanhar
STREAM_LISTS=( $(ls -1 "${BASE}"/stream_list.atmosphere.* 2>/dev/null || true) )
info "stream_list.atmosphere.*: ${#STREAM_LISTS[@]} arquivo(s)"

#-----------------------------------------------------------------------------
# Janela de integração: reporta, nunca altera em silêncio
#-----------------------------------------------------------------------------
_start="$(grep -E '^\s*config_start_time'  "${BASE}/namelist.atmosphere" | head -1 || true)"
_dur="$(  grep -E '^\s*config_run_duration' "${BASE}/namelist.atmosphere" | head -1 || true)"
_stop="$( grep -E '^\s*config_stop_time'    "${BASE}/namelist.atmosphere" | head -1 || true)"
info "namelist:${_start:- (config_start_time ausente)}"
if [[ -n "${_dur}" ]]; then
  info "namelist:${_dur}"
elif [[ -n "${_stop}" ]]; then
  info "namelist:${_stop}"
else
  falha "nem config_run_duration nem config_stop_time no namelist.atmosphere."
  echo  "           No acoplado a parada vem da nuopc.input; no autonomo ela tem"
  echo  "           de estar no namelist. Use --duration '1_00:00:00'."
  morre "janela de integracao indefinida"
fi
[[ -n "${DURATION}" ]] && info "config_run_duration sera reescrito NAS COPIAS: ${DURATION}"

#-----------------------------------------------------------------------------
# Monta os diretórios das duas rodadas
#-----------------------------------------------------------------------------
[[ -e "${RUN_DIR}" ]] && morre "${WORKDIR}/ ja existe. Remova ou use WORKDIR=outro."
mkdir -p "${RUN_DIR}"

prepara_rodada() {                       # $1 = A|B
  local d="${RUN_DIR}/$1"
  mkdir -p "${d}"
  # entradas grandes por link simbolico; configuracao por copia (fica congelada)
  ln -s "${INIT_NC}" "${d}/"
  ln -s "${PART}"    "${d}/"
  local _g
  for _g in "${BASE}"/*.DBL "${BASE}"/*.TBL; do [[ -e "${_g}" ]] && ln -s "${_g}" "${d}/"; done
  [[ -e "${BASE}/mpas_mesh.nc" ]] && ln -s "${BASE}/mpas_mesh.nc" "${d}/"
  local _s
  for _s in "${STREAM_LISTS[@]:-}"; do [[ -n "${_s}" ]] && cp "${_s}" "${d}/"; done
  cp "${BASE}/namelist.atmosphere" "${BASE}/streams.atmosphere" "${d}/"
  if [[ -n "${DURATION}" ]]; then
    sed -i -E "s|^(\s*config_run_duration\s*=\s*).*|\1'${DURATION}'|" "${d}/namelist.atmosphere"
  fi
}

gera_pbs() {                             # $1 = A|B
  local d="${RUN_DIR}/$1"
  cat > "${d}/mpas-standalone.pbs" << PBSEOF
#!/bin/bash
#PBS -N mpas-repro-$1
#PBS -q ${QUEUE}
#PBS -l select=1:ncpus=${NPES}:mpiprocs=${NPES}
#PBS -l walltime=${WALLTIME}
#PBS -l place=scatter:excl
#PBS -j oe
#PBS -o ${d}/mpas-standalone.log

cd ${d} || exit 1

# Os arquivos de radiacao (RRTMG_*.DBL, CAM_*.DBL) sao big-endian na unidade 101.
export GFORTRAN_CONVERT_UNIT=big_endian:101

# B-STANDALONE-LDD-01: o job autonomo nao carrega o setenv do acoplador, entao
# o caminho do ESMF externo precisa vir explicito. Vazio para os alvos que nao
# dependem de libesmf.so.
export LD_LIBRARY_PATH="${ESMF_LIBDIR:-}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

# Rodada de controle: nenhuma variavel de perturbacao de memoria ativa.
unset MALLOC_PERTURB_

echo "=== inicio: \$(date) ==="
${MPIEXEC} -n ${NPES} ${EXE}
_rc=\$?
echo "=== fim: \$(date)  rc=\${_rc} ==="
exit \${_rc}
PBSEOF
}

submete_e_espera() {                     # $1 = A|B  -> ecoa jobid
  local d="${RUN_DIR}/$1" jid st
  jid="$(qsub "${d}/mpas-standalone.pbs")" || morre "qsub falhou na rodada $1"
  printf '   rodada %s: job %s\n' "$1" "${jid}" >&2
  while true; do
    st="$(qstat -f "${jid}" 2>/dev/null | awk -F'= ' '/job_state/{print $2}' | tr -d ' ' || true)"
    [[ -z "${st}" ]] && break
    [[ "${st}" == "F" ]] && break
    printf '   [%s]  estado: %s\n' "$(date +%H:%M:%S)" "${st}" >&2
    sleep "${POLL}"
  done
  echo "${jid}"
}

verifica_saida() {                       # $1 = A|B
  local d="${RUN_DIR}/$1" n
  # B-STANDALONE-SILENT-01: 'find' em vez de 'ls | wc -l'. Com set -euo
  # pipefail, 'ls' sobre um glob sem correspondencia falha, o pipefail propaga
  # a falha e o set -e encerra o script EM SILENCIO, antes desta mensagem.
  # Foi o que aconteceu em 20/09/2026 com o alvo standalone-esmflib: o modelo
  # abortou na inicializacao e o script sumiu sem dizer nada, seguindo o laco
  # for para a proxima iteracao. 'find' devolve zero linhas sem falhar.
  n="$(find "${d}" -maxdepth 1 -name 'MONAN_DIAG_*.nc' 2>/dev/null | wc -l)"
  if [[ "${n}" -eq 0 ]]; then
    falha "rodada $1 nao gerou MONAN_DIAG_*.nc — o modelo nao chegou ao fim"
    echo  "           Causa provavel, em ordem de probabilidade:"
    echo  "             ${d}/log.atmosphere.0000.err   (mensagem do MPAS)"
    echo  "             ${d}/mpas-standalone.log       (mpiexec, backtrace)"
    echo  "             ${d}/log.atmosphere.0000.out   (ultimas linhas)"
    if [[ -s "${d}/log.atmosphere.0000.err" ]]; then
      echo  "           --- ultimas linhas de log.atmosphere.0000.err ---"
      tail -8 "${d}/log.atmosphere.0000.err" | sed 's/^/           /'
    fi
    morre "rodada $1 abortou; B nao sera submetida"
  fi
  ok "rodada $1: ${n} arquivo(s) MONAN_DIAG"
}

for R in A B; do
  echo
  echo "== Rodada ${R} =="
  prepara_rodada "${R}"
  gera_pbs "${R}"
  submete_e_espera "${R}" > /dev/null
  verifica_saida "${R}"
done

#-----------------------------------------------------------------------------
# Comparação
#-----------------------------------------------------------------------------
echo
echo "== Comparacao A x B (nccmp -d, identidade exata) =="

# nccmp vem de um modulo proprio no Jaci; carrega em subshell para nao
# contaminar o ambiente desta sessao.
NCCMP_ENV="${COUPLER_ROOT:-${BASE}/../Coupler-Install/MONAN-Coupler}/tools/dev/set-nccmp-jaci.bash"
if [[ -r "${NCCMP_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${NCCMP_ENV}"
  ok "ambiente do nccmp carregado de ${NCCMP_ENV}"
else
  info "set-nccmp-jaci.bash nao encontrado; usando o nccmp do PATH"
fi
command -v nccmp > /dev/null || morre "nccmp indisponivel"

_iguais=0; _difere=0; _ausentes=0
while IFS= read -r fa; do
  f="$(basename "${fa}")"
  fb="${RUN_DIR}/B/${f}"
  if [[ ! -e "${fb}" ]]; then
    printf '   AUSENTE em B  %s\n' "${f}"; _ausentes=$(( _ausentes + 1 )); continue
  fi
  if nccmp -d "${fa}" "${fb}" > /dev/null 2>&1; then
    printf '   igual         %s\n' "${f}"; _iguais=$(( _iguais + 1 ))
  else
    printf '   DIFERE        %s\n' "${f}"
    nccmp -d "${fa}" "${fb}" 2>&1 | head -4 | sed 's/^/        /'
    _difere=$(( _difere + 1 ))
  fi
done < <(ls -1 "${RUN_DIR}"/A/MONAN_DIAG_*.nc)

echo
echo "== Veredito =="
printf '   iguais: %d   diferentes: %d   ausentes em B: %d\n' \
       "${_iguais}" "${_difere}" "${_ausentes}"
echo

if (( _difere == 0 && _ausentes == 0 )); then
  echo "   REPRODUTIVEL: o MPAS-A autonomo e' bit a bit identico em ${NPES} PETs."
  echo "   ATENCAO na leitura: este script NAO sabe com qual alvo o binario foi"
  echo "   compilado (standalone, standalone-coupler ou standalone-esmflib) —"
  echo "   anote-o a' mao. Nenhum binario autonomo exercita a interacao com o"
  echo "   ESMF em tempo de execucao dentro do acoplador, entao este resultado"
  echo "   NAO absolve o binario acoplado."
  exit 0
else
  echo "   NAO REPRODUTIVEL: o MPAS-A diverge entre duas rodadas identicas"
  echo "   SEM o acoplador no circuito. Conclusivo: a semente esta dentro do"
  echo "   MPAS-A, e o acoplamento nao tem parte nisso."
  echo
  echo "   Proximo passo para localizar: aumentar a frequencia do stream"
  echo "   'diagnostics' para o passo de tempo do modelo e integrar 1 hora, para"
  echo "   saber o PRIMEIRO passo e a PRIMEIRA variavel que divergem na malha"
  echo "   nativa. Dai a busca passa a ser por rotina, nao por componente."
  exit 1
fi
