#!/usr/bin/env bash
#=============================================================================
# mede-taxa-repro.sh
#
# Mede a TAXA de não reprodutibilidade do acoplado, em vez de responder sim ou
# não a partir de uma única dupla rodada.
#
# POR QUE ISTO EXISTE
# Em 16/09/2026, duas duplas rodadas na MESMA configuração (atm_pet_count=32,
# 40 PETs, dt_coupling=3600) deram resultados opostos: a primeira reproduziu
# bit a bit nos 145 registros e nos sete campos, a segunda divergiu no registro
# 7 em cinco campos. A divergência é INTERMITENTE. Consequência prática: uma
# dupla rodada que reproduz não prova nada, e qualquer teste de configuração
# lido a partir de um único par pode ser sorte. Foi assim que o resultado de
# 32 PETs virou, por algumas horas, uma conclusão errada sobre dependência do
# número de blocos METIS.
#
# O QUE MUDA AQUI
# Com N execuções, comparam-se TODOS os N(N-1)/2 pares, não N/2. Quatro
# execuções dão seis comparações; seis execuções dão quinze. O custo em fila
# cresce linearmente e a informação cresce quadraticamente.
#
# Ressalva honesta: os pares NÃO são independentes entre si (se uma execução
# for a destoante, ela aparece em N-1 pares). A fração de pares divergentes é
# uma medida útil de ordem de grandeza, não uma estimativa com intervalo de
# confiança. Para isso o script também agrupa as execuções em CLASSES de
# resultado idêntico, que é a leitura mais informativa: ver a seção de
# interpretação no fim da saída.
#
# B-BITSUM-01 (22/09/2026): recolhe o checksum exato do Si_ifrac que o
# mediador grava por PET (FIX-DIAG-BITSUM-01, quatro etapas do caminho
# gelo -> atmosfera) em bitsum_r<k>.txt, e compara os pares por etapa.
#
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#=============================================================================
set -uo pipefail

RUNS="${RUNS:-4}"
RETOMAR="${RETOMAR:-0}"   # B-RETOMADA-SILENT-01
NPES="${NPES:-72}"
WALLTIME="${WALLTIME:-01:00:00}"
POLL="${POLL:-30}"
RUNNER="${RUNNER:-run/run_esmApp.jaci}"
ARQ="${ARQ:-reprodiag.nc}"
VAR="${VAR:-surface_pressure}"
PREFIXO="${PREFIXO:-reprodiag_r}"
PREFIXO_EXP="${PREFIXO_EXP:-export_t0_r}"   # B-EXPORT-T0-01
# B-OCN-DIAG-01: saidas NetCDF do MOM6 pelo diag_table, que tem cadencia
# PROPRIA e nao herda a do acoplamento como o ocean.stats. Padroes de nome, e
# nao nomes fixos, porque o FMS pode prefixar com data.
#
# O padrao e' SO o monan_tos, por duas razoes, e nao apenas por tamanho:
#   - ele vem de 'ocean_model', na grade NATIVA do MOM6. O tempsalt vem de
#     'ocean_model_z', ou seja, ja' passou pela remapagem para niveis z: uma
#     camada de interpolacao a mais entre o estado e o arquivo, que pode ter
#     dependencia de ordem propria e confundir a medicao.
#   - o campo e' o 'tos', a SST que de fato alimenta a atmosfera, e portanto o
#     campo causalmente relevante para a cadeia que se investiga.
#   - 2,5 MB contra 388 MB: quatro execucoes e seis comparacoes nccmp.
#
# Para incluir o tempsalt numa investigacao especifica:
#   export OCEAN_GLOBS='*monan_tos*.nc *tempsalt*.nc'
OCEAN_GLOBS="${OCEAN_GLOBS:-*monan_tos*.nc}"
# B-IMPORT-DIAG-01: o que o MPAS RECEBE do mediador, por instante. E' a
# bisseccao entre "o mediador entrega campo diferente" e "a atmosfera usa mal
# um campo identico": o monan2_import e' escrito depois da importacao, na
# grade regular de 1 grau, e existe um arquivo por troca de acoplamento.
IMPORT_GLOBS="${IMPORT_GLOBS:-diag_import/monan2_import_*.nc}"
# B-MEDDIAG-01: log do PET0, onde o mediador grava as linhas FIX-DIAG que
# separam as etapas do caminho do gelo (mascara -> regrid bruto -> extrapolacao).
PET_LOG="${PET_LOG:-logs/PET00.esmApp.log}"
# B-BITSUM-01: diretorio dos logs de todos os PETs.
LOG_DIR="$(dirname "${PET_LOG}")"
# B-RUNLOG-01: saida padrao do job. O #PBS -o aponta para este arquivo e o PBS
# o SOBRESCREVE a cada job, entao sem copia sobra apenas a ultima execucao.
# E' nele que caem os checksums do SIS2 (DEBUG_CHKSUMS/SLOW_ICE/FAST_ICE).
RUN_LOG="${RUN_LOG:-logs/esmApp_run.log}"
# Pontos de medicao do part_size que o SIS2 emite quando as chaves de debug
# estao ligadas. Sao as etapas do ciclo do gelo, na ordem em que ocorrem.
# Oito pontos, na ordem em que o SIS2 os emite. Os dois acrescentados em
# 19/09/2026 (Before slow_thermodynamics e Before set_ocean_top_fluxes) sao os
# que subdividem o passo lento, que e' onde a divergencia nasce: o estado entra
# nele identico (checksum 334285 nas quatro execucoes) e sai diferente
# (348735 vs 348744). Sem eles a granularidade parava em "o passo lento".
#
# O rotulo e' 'Before', nao 'Start': filtros que procuravam so' Start/End nao
# achavam esses dois pontos, que ja existiam no log.
# B-GELO-OSS-01 (21/09/2026): 'Start update_ice_slow_thermo' e' o PRIMEIRO
# ponto em que o SIS2 mede FIA%bmelt no ciclo. Em modo sequencial, com ou sem
# icebergs, o bmelt ja' diverge na troca 1, com estado de entrada identico e
# forcamento atmosferico nulo. Este ponto diz se ele ja' chega divergente ao
# passo lento ou se diverge entre este e o 'Before slow_thermodynamics'.
ETAPAS_GELO="${ETAPAS_GELO:-Start set_ice_surface_state|End set_ice_surface_state|Start do_update_ice_model_fast|End do_update_ice_model_fast|Start update_ice_slow_thermo|Before slow_thermodynamics|Start update_ice_model_slow|Before set_ocean_top_fluxes|End ice_state_cleanup}"
# B-GELO-CAMPOS-01: quais grandezas comparar em cada ponto.
#
# Ate 19/09/2026 so' o part_size era guardado, e isso levou a investigacao ate'
# "o trecho final do passo lento" e parou ali. Os pontos do SIS2 medem dezenas
# de campos; saber QUAL grandeza diverge primeiro aponta a rotina.
#
# Ficam de fora mH_snow, mH_pond, mH_pond_ice e enth_snow: medidos como zero em
# toda a integracao (nao ha neve nem pocas neste caso), entao nao discriminam
# nada e so' gastariam linhas.
# B-GELO-CAMPOS-02 (19/09/2026): acrescentados os fluxos que o gelo RECEBE
# sem calcular (radiativos, precipitacao, evaporacao). Eles sao o que
# discrimina entre as duas hipoteses restantes:
#   - radiativos e precipitacao IDENTICOS com os turbulentos divergentes
#     => o aib chegou igual, e o nao determinismo e' INTERNO ao
#        update_ice_model_fast (entrada igual, saida diferente);
#   - todos divergentes => a atmosfera entregou campo diferente, e o gelo e'
#     mensageiro.
# Os turbulentos (flux_sh_top, flux_lh_top) NAO discriminam: sao calculados
# dentro do passo rapido e divergem nas duas hipoteses.
# B-GELO-OSS-01: acrescentado o OSS (ocean surface state como o GELO o ve',
# desempacotado do oib que o mediador entrega). OSS%bheat e' o fluxo de calor
# do oceano para a base do gelo, de onde sai o bmelt. Leitura na troca 1:
#   OSS divergente             => o que o gelo RECEBE do oceano ja' difere:
#                                 caminho MED->ICE ou o proprio oceano;
#   OSS identico, bmelt nao    => o calculo do fluxo basal nao e' deterministico.
# OSS%s_surf, OSS%frazil e OSS%sea_lev vem de campos do oib que o cap NAO
# preenche a partir do mediador (salinidade fixa em 34,7, frazil e nivel do mar
# em zero: ver B-ICE-SALIN-FIXA-01) — devem sair identicos e servem de controle.
CAMPOS_GELO="${CAMPOS_GELO:-IST%part_size|IST%mH_ice|IST%enth_ice\(\(1\)|IST%enth_ice\(\(2\)|IST%sal_ice\(\(1\)|FIA%ice_cover|FIA%ice_free|FIA%bmelt|FIA%tmelt|FIA%flux_sh_top|FIA%flux_lh_top|FIA%flux_lw_top|FIA%flux_sw_dn|FIA%flux_sw_top\(1\)|FIA%lprec_top|FIA%fprec_top|FIA%evap_top|FIA%p_atm_surf|FIA%WindStr_x|OSS%SST_C|OSS%bheat|OSS%T_fr_ocn|OSS%s_surf|OSS%frazil|OSS%sea_lev}"

ok()    { printf '   OK      %s\n' "$*"; }
info()  { printf '   INFO    %s\n' "$*"; }
falha() { printf '   FALHOU  %s\n' "$*"; }
morre() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
Uso: bash mede-taxa-repro.sh [OPÇÕES]

  Lançar do diretório do experimento. Executa N vezes o acoplado na
  configuração ATUAL (não altera nuopc.input nem streams.atmosphere),
  preserva o reprodiag.nc de cada execução e compara TODOS os pares.

Opções:
  --runs N          número de execuções (default: 4 → 6 pares)
  --npes N          PETs (default: 72; deve casar com o nuopc.input)
  --walltime T      (default: 01:00:00)
  --var NOME        variável da comparação par a par (default: surface_pressure)
  --runner CAMINHO  script de submissão (default: run/run_esmApp.jaci)
  --retomar         reaproveita execucoes cujo reprodiag_r<k>.nc ja existe
                    (sem isto, arquivo existente ABORTA: evita recomparacao silenciosa)
  --help

  Retomada: só com --retomar. Sem ele, qualquer reprodiag_r<k>.nc existente
  aborta a bateria, para não recomparar em silêncio arquivos antigos.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)     RUNS="$2";     shift 2 ;;
    --npes)     NPES="$2";     shift 2 ;;
    --walltime) WALLTIME="$2"; shift 2 ;;
    --retomar)  RETOMAR=1;    shift   ;;
    --var)      VAR="$2";      shift 2 ;;
    --runner)   RUNNER="$2";   shift 2 ;;
    --help|-h)  usage ;;
    *) echo "ERRO: opção desconhecida: $1  (use --help)" >&2; exit 1 ;;
  esac
done

[[ "${RUNS}" -ge 2 ]] || morre "--runs precisa ser 2 ou mais"

echo
echo "== 0. Pre-condicoes =="

[[ -f nuopc.input ]]        || morre "nuopc.input nao encontrado. Rode do diretorio do experimento."
[[ -f streams.atmosphere ]] || morre "streams.atmosphere nao encontrado."
[[ -f "${RUNNER}" ]]        || morre "script de submissao nao encontrado: ${RUNNER}"

grep -qE '<stream[[:space:]]+name="reprodiag"' streams.atmosphere \
  || morre "o bloco <stream name=\"reprodiag\"> nao esta no streams.atmosphere"
ok "stream reprodiag declarado"

command -v nccmp > /dev/null 2>&1 || {
  NCCMP_ENV="${COUPLER_ROOT:-../Coupler-Install/MONAN-Coupler}/tools/dev/set-nccmp-jaci.bash"
  # shellcheck disable=SC1090
  [[ -r "${NCCMP_ENV}" ]] && source "${NCCMP_ENV}"
}
command -v nccmp > /dev/null 2>&1 || morre "nccmp indisponivel no PATH"
ok "nccmp disponivel"

# Configuração efetiva, registrada na saída: a taxa só tem sentido junto da
# configuração em que foi medida.
_atm="$(grep -E '^\s*atm_pet_count'  nuopc.input | head -1 | tr -s ' ')"
_dtc="$(grep -E '^\s*dt_coupling'    nuopc.input | head -1 | tr -s ' ')"
_cpl="$(grep -E '^\s*coupling_mode'  nuopc.input | head -1 | tr -s ' ')"
info "configuracao:${_atm}"
info "configuracao:${_dtc}"
info "configuracao:${_cpl}"
info "execucoes: ${RUNS}   pares a comparar: $(( RUNS * (RUNS - 1) / 2 ))"

espera_fila() {
  sleep 10
  while qstat -u "${USER}" 2>/dev/null | grep -qE '[[:space:]][QRHEBW][[:space:]]'; do
    printf '   [%s]  fila ocupada, aguardando\n' "$(date +%H:%M:%S)"
    sleep "${POLL}"
  done
}

#-----------------------------------------------------------------------------
# Execuções
#-----------------------------------------------------------------------------
for k in $(seq 1 "${RUNS}"); do
  alvo="${PREFIXO}${k}.nc"
  if [[ -s "${alvo}" ]]; then
    # B-RETOMADA-SILENT-01 (20/09/2026): reaproveitar execucoes existentes so'
    # com --retomar explicito. Sem isso, uma bateria NOVA lancada com arquivos
    # da anterior no diretorio virava recomparacao silenciosa dos arquivos
    # velhos, anunciada por quatro linhas INFO faceis de perder — foi o que
    # aconteceu com a bateria sequencial + checksums do SIS2.
    if [[ "${RETOMAR}" -ne 1 ]]; then
      morre "${alvo} ja existe. Guarde a bateria anterior (mkdir repro-X; mv reprodiag_r?.nc ... repro-X/) ou, se for retomada de uma bateria interrompida, use --retomar"
    fi
    info "execucao ${k}: ${alvo} ja existe, pulando (--retomar)"
    continue
  fi
  echo
  echo "== Execucao ${k} de ${RUNS} =="
  rm -f "${ARQ}"
  # B-MONANDIAG-CLOBBER-01 (21/09/2026): o stream 'diagnostics' do MPAS grava
  # MONAN_DIAG_*.nc na raiz com clobber_mode='never_modify'. Se os arquivos da
  # execucao anterior estiverem la', o MPAS registra ERROR em
  # log.atmosphere.*.err e SEGUE SEM GRAVAR: os MONAN_DIAG da raiz ficam sendo
  # os de uma execucao antiga. Este script nao os compara, mas qualquer outra
  # ferramenta que os leia (camada 4c do roda_repro_producao.sh) compararia
  # arquivos velhos. Mover, nao apagar: podem ser a unica copia de algo.
  if compgen -G "MONAN_DIAG_*.nc" > /dev/null; then
    mkdir -p "monan_diag-pre-r${k}"
    mv MONAN_DIAG_*.nc "monan_diag-pre-r${k}/"
    info "execucao ${k}: MONAN_DIAG antigos movidos para monan_diag-pre-r${k}/"
  fi
  # B-BITSUM-01: os logs de PET sao cumulativos entre jobs. Guardar o numero
  # de linhas de cada um ANTES da execucao permite recortar depois so' o que
  # esta execucao escreveu, em todos os PETs, sem depender de marcador.
  unset _BS_PRE; declare -A _BS_PRE=()
  for _f in "${LOG_DIR}"/PET*.esmApp.log; do
    [[ -f "${_f}" ]] && _BS_PRE["${_f}"]="$(wc -l < "${_f}")"
  done
  bash "${RUNNER}" -n "${NPES}" -w "${WALLTIME}" || morre "submissao da execucao ${k} falhou"
  espera_fila
  [[ -s "${ARQ}" ]] || morre "execucao ${k} nao gerou ${ARQ} (ver logs/esmApp_run.log)"
  mv "${ARQ}" "${alvo}"
  ok "execucao ${k}: ${alvo}"

  # B-EXPORT-T0-01: preservar tambem o PRIMEIRO monan_export.
  #
  # Ele e' o primeiro artefato que o cap produz, antes de qualquer resposta do
  # oceano, e passa pelo mapeamento malha Voronoi -> grade regular 360x180 do
  # state_set_field_1d. Se ele divergir entre execucoes, a semente esta na
  # exportacao e nao na integracao, e essa distincao nao se recupera depois:
  # as execucoes seguintes sobrescrevem diag_export/. Foi exatamente o que
  # aconteceu em 17/09/2026, quando a pergunta ficou sem resposta porque o
  # script guardava apenas o reprodiag.nc.
  _exp0="$(ls -1 diag_export/monan_export_*.nc 2>/dev/null | head -1 || true)"
  if [[ -n "${_exp0}" ]]; then
    cp -p "${_exp0}" "${PREFIXO_EXP}${k}.nc"
    ok "execucao ${k}: $(basename "${_exp0}") preservado como ${PREFIXO_EXP}${k}.nc"
  else
    info "execucao ${k}: nenhum monan_export em diag_export/; export nao sera comparado"
  fi

  # B-STATS-PRESERVA-01: ocean.stats e seaice.stats sao reescritos a cada
  # execucao no mesmo caminho, entao sem copia so' sobra o da ultima. Eles sao
  # a camada que diz se o OCEANO diverge antes da injecao, e sao pequenos.
  for _st in ocean.stats seaice.stats; do
    if [[ -s "${_st}" ]]; then
      cp -p "${_st}" "${_st%.stats}_r${k}.stats"
    fi
  done

  # B-OCN-DIAG-01: preserva as saidas do diag_table numa pasta por execucao.
  #
  # O ocean.stats so' e' escrito quando update_ocean_model retorna, logo ele
  # herda a cadencia do acoplamento: com dt_coupling grande sobram dois ou tres
  # registros, amostragem grossa demais para dizer QUANDO o oceano se separa.
  # O diag_manager do FMS tem cadencia propria (output_freq no diag_table), e
  # com 1 hora da' 24 amostras por rodada.
  # B-IMPORT-DIAG-01: preserva o que a atmosfera recebeu, por instante.
  _n_imp=0
  mkdir -p "imp_r${k}"
  # shellcheck disable=SC2086
  for _f in ${IMPORT_GLOBS}; do
    [[ -s "${_f}" ]] || continue
    cp -p "${_f}" "imp_r${k}/" && _n_imp=$(( _n_imp + 1 ))
  done
  if [[ "${_n_imp}" -gt 0 ]]; then
    ok "execucao ${k}: ${_n_imp} arquivo(s) de importacao em imp_r${k}/"
  else
    info "execucao ${k}: nenhuma importacao casando com '${IMPORT_GLOBS}'"
    rmdir "imp_r${k}" 2>/dev/null || true
  fi

  # B-MEDDIAG-01: preserva as linhas de diagnostico do mediador.
  #
  # Sao elas que dizem em QUAL etapa do caminho do gelo a divergencia entra:
  #   ICEMASK-01  mascara de origem, gravada uma vez no RegridStore
  #   ICEMASK-02  ifrac bruto, POS-regrid e PRE-extrapolacao, por troca
  # A pasta logs/ e' reescrita a cada execucao, entao sem esta copia as
  # quatro rodadas se perdem.
  if [[ -s "${PET_LOG}" ]]; then
    # B-MEDDIAG-02: recorta SO o ciclo desta execucao.
    #
    # O logs/PET00.esmApp.log NAO e' truncado entre rodadas: cada execucao
    # acrescenta o seu ciclo ao que ja' estava la'. Extrair o arquivo inteiro
    # faz a execucao k capturar tambem os ciclos de 1..k-1, e os arquivos saem
    # com tamanhos crescentes (225, 250, 275, 300 linhas na bateria de
    # 18/09/2026). Comparados com cmp, isso aparece como divergencia quando na
    # verdade e' so' acumulo, e foi o que produziu o falso veredito "a mascara
    # de origem varia".
    #
    # A fronteira do ciclo e' a ULTIMA ocorrencia de ICEMASK-01, que o
    # mediador emite uma vez por execucao, no RegridStore do gelo.
    grep -E "FIX-DIAG-ICEMASK-0[12]" "${PET_LOG}" \
      | sed -E 's/^[0-9]+ +[0-9.]+ +INFO +PET[0-9]+ +//' \
      | awk '/ICEMASK-01/{n=NR} {l[NR]=$0} END{for(i=n;i<=NR;i++) print l[i]}' \
      > "meddiag_r${k}.txt" || true
    if [[ -s "meddiag_r${k}.txt" ]]; then
      ok "execucao ${k}: $(wc -l < "meddiag_r${k}.txt") linha(s) FIX-DIAG em meddiag_r${k}.txt"
    else
      info "execucao ${k}: nenhuma linha FIX-DIAG-ICEMASK em ${PET_LOG}"
      rm -f "meddiag_r${k}.txt"
    fi
  else
    info "execucao ${k}: ${PET_LOG} ausente; diagnostico do mediador nao preservado"
  fi

  # B-BITSUM-01: checksum exato do Si_ifrac, por PET e por etapa.
  #
  # O mediador (FIX-DIAG-BITSUM-01) grava uma linha por PET em cada etapa:
  #   etapa1 origem (Si_ifrac_sis2, grade do oceano)   etapa2 pos-regrid
  #   etapa3 pos-extrapolacao                           etapa4 exportState
  # Cada linha vira "t=<troca> <etapa> <PET> n=.. hi=.. lo=..", ordenada por
  # troca, etapa e PET, para que diff entre execucoes aponte a primeira
  # troca, a primeira etapa e o PET onde a diferenca aparece.
  for _f in "${LOG_DIR}"/PET*.esmApp.log; do
    [[ -f "${_f}" ]] || continue
    _p="${_BS_PRE[${_f}]:-0}"
    _t="$(wc -l < "${_f}")"
    (( _t < _p )) && _p=0   # log truncado ou movido durante a execucao
    tail -n +"$(( _p + 1 ))" "${_f}" | grep -E "FIX-DIAG-BITSUM-01" \
      | sed -E 's/^.*(PET[0-9]+) +FIX-DIAG-BITSUM-01: +/\1 /'
  done | awk '
      { pet = $1; et = $2; t = ++cnt[pet " " et]
        if (match($0, / n=[0-9]+ hi=[0-9]+ lo=[0-9]+( ERRO=[0-9]+)?/))
          v = substr($0, RSTART + 1, RLENGTH - 1)
        else
          v = "AUSENTE"
        printf "t=%04d %s %s %s\n", t, et, pet, v }' \
    | sort -k1,1 -k2,2 -k3,3 > "bitsum_r${k}.txt"
  if [[ -s "bitsum_r${k}.txt" ]]; then
    ok "execucao ${k}: $(wc -l < "bitsum_r${k}.txt") checksum(s) FIX-DIAG-BITSUM em bitsum_r${k}.txt"
  else
    info "execucao ${k}: nenhuma linha FIX-DIAG-BITSUM nos logs de PET (binario sem o diagnostico?)"
    rm -f "bitsum_r${k}.txt"
  fi

  # B-RUNLOG-01: preserva as linhas de checksum do SIS2 desta execucao.
  #
  # O checksum inteiro (campo 'c=') e' imune a arredondamento de impressao, ao
  # contrario do mean/min/max da linha anterior, e por isso e' o que se compara.
  if [[ -s "${RUN_LOG}" ]]; then
    # A ancora no fim do padrao separa IST%part_size de IST%part_size(0),
    # que e' a categoria de agua aberta e tem valores proprios.
    grep -E "c= .*(${ETAPAS_GELO}) (${CAMPOS_GELO})\$" "${RUN_LOG}" \
      > "gelo_r${k}.txt" || true
    if [[ -s "gelo_r${k}.txt" ]]; then
      ok "execucao ${k}: $(wc -l < "gelo_r${k}.txt") checksum(s) de part_size em gelo_r${k}.txt"
    else
      info "execucao ${k}: nenhum checksum de part_size em ${RUN_LOG}"
      info "  (chaves DEBUG_CHKSUMS/DEBUG_SLOW_ICE/DEBUG_FAST_ICE ligadas no SIS_override?)"
      rm -f "gelo_r${k}.txt"
    fi
  fi

  _n_ocn=0
  mkdir -p "ocn_r${k}"
  # shellcheck disable=SC2086
  for _f in ${OCEAN_GLOBS}; do
    [[ -s "${_f}" ]] || continue
    cp -p "${_f}" "ocn_r${k}/" && _n_ocn=$(( _n_ocn + 1 ))
  done
  if [[ "${_n_ocn}" -gt 0 ]]; then
    ok "execucao ${k}: ${_n_ocn} saida(s) do oceano em ocn_r${k}/"
  else
    info "execucao ${k}: nenhuma saida casando com '${OCEAN_GLOBS}'"
    info "  (diag_table vazio? nome com prefixo? ajuste OCEAN_GLOBS)"
    rmdir "ocn_r${k}" 2>/dev/null || true
  fi
done

#-----------------------------------------------------------------------------
# Sanidade: a variável precisa VARIAR dentro de uma execução.
#
# Sem esta conferência, um stream mal configurado que grave o mesmo estado em
# todos os registros faria todas as comparações darem "identico", e o script
# relataria reprodutibilidade perfeita a partir de um arquivo inútil. É o
# mesmo modo de falha que já apareceu nesta investigação com diagnósticos
# incompletos: o número sai bonito e não mede o que se pensa.
#-----------------------------------------------------------------------------
echo
echo "== Sanidade do instrumento =="
_nrec="$(ncdump -h "${PREFIXO}1.nc" | grep -oE 'Time = UNLIMITED ; // \([0-9]+' \
         | grep -oE '[0-9]+$' || echo 0)"
[[ "${_nrec}" -ge 2 ]] || morre "${PREFIXO}1.nc tem ${_nrec} registro(s): nada a comparar no tempo"
ok "${_nrec} registros por execucao"

ncdump -v "${VAR}" "${PREFIXO}1.nc" > /tmp/_san_$$.txt 2>&1
if [[ ! -s /tmp/_san_$$.txt ]]; then
  morre "variavel ${VAR} ausente de ${PREFIXO}1.nc"
fi
ok "variavel ${VAR} presente"
rm -f /tmp/_san_$$.txt

#-----------------------------------------------------------------------------
# Comparação de todos os pares
#-----------------------------------------------------------------------------
echo
echo "== Comparacao par a par  (${VAR}) =="
echo

n_par=0; n_dif=0
declare -A PRIMEIRO      # "i,j" -> primeiro registro divergente
declare -A IGUAL_A       # i -> lista de execucoes identicas a i

for i in $(seq 1 "${RUNS}"); do
  for j in $(seq $(( i + 1 )) "${RUNS}"); do
    n_par=$(( n_par + 1 ))
    out="/tmp/_cmp_${i}_${j}_$$.txt"
    nccmp -d -f -v "${VAR}" "${PREFIXO}${i}.nc" "${PREFIXO}${j}.nc" > "${out}" 2>&1
    if [[ -s "${out}" ]]; then
      r="$(grep -oE '\[[0-9]+,' "${out}" | tr -d '[,' | sort -n | head -1)"
      ncel="$(grep -c "POSITION : \[${r}," "${out}" 2>/dev/null || echo 0)"
      if [[ -n "${r}" ]]; then
        n_dif=$(( n_dif + 1 ))
        PRIMEIRO["${i},${j}"]="${r}"
        printf '   r%-2s x r%-2s   DIFERE a partir do registro %-4s (%s celula(s) nele)\n' \
               "${i}" "${j}" "${r}" "${ncel}"
      else
        printf '   r%-2s x r%-2s   saida inesperada do nccmp: %s\n' \
               "${i}" "${j}" "$(head -1 "${out}")"
      fi
    else
      IGUAL_A["${i}"]="${IGUAL_A[${i}]:-} ${j}"
      printf '   r%-2s x r%-2s   identico\n' "${i}" "${j}"
    fi
    rm -f "${out}"
  done
done

#-----------------------------------------------------------------------------
# Comparação do primeiro monan_export (B-EXPORT-T0-01)
#
# Camada separada de propósito. O reprodiag mede o ESTADO do MPAS; este mede o
# que o cap ENTREGA ao mediador. Divergirem juntos ou separados distingue duas
# causas diferentes, e a leitura está no fim desta saída.
#-----------------------------------------------------------------------------
n_par_exp=0; n_dif_exp=0; tem_exp=0
if ls "${PREFIXO_EXP}"*.nc > /dev/null 2>&1; then
  tem_exp=1
  echo
  echo "== Comparacao par a par do primeiro monan_export =="
  echo
  for i in $(seq 1 "${RUNS}"); do
    for j in $(seq $(( i + 1 )) "${RUNS}"); do
      fa="${PREFIXO_EXP}${i}.nc"; fb="${PREFIXO_EXP}${j}.nc"
      [[ -s "${fa}" && -s "${fb}" ]] || continue
      n_par_exp=$(( n_par_exp + 1 ))
      oute="/tmp/_cmpexp_${i}_${j}_$$.txt"
      nccmp -d -f "${fa}" "${fb}" > "${oute}" 2>&1
      if [[ -s "${oute}" ]] && grep -q "DIFFER" "${oute}"; then
        n_dif_exp=$(( n_dif_exp + 1 ))
        printf '   r%-2s x r%-2s   DIFERE  (%s)\n' "${i}" "${j}" \
               "$(grep -oE 'VARIABLE : [A-Za-z_0-9]+' "${oute}" \
                  | sed 's/VARIABLE : //' | sort -u | tr '\n' ' ')"
      elif [[ -s "${oute}" ]]; then
        printf '   r%-2s x r%-2s   saida inesperada: %s\n' "${i}" "${j}" "$(head -1 "${oute}")"
      else
        printf '   r%-2s x r%-2s   identico\n' "${i}" "${j}"
      fi
      rm -f "${oute}"
    done
  done
fi


echo
echo "== Comparacao de ocean.stats e seaice.stats =="
echo
#-----------------------------------------------------------------------------
# Comparação de ocean.stats e seaice.stats (B-STATS-PRESERVA-01)
#
# Texto, comparado com cmp. Sao diagnosticos do estado interno do oceano e do
# gelo, independentes do caminho de acoplamento, e por isso dizem se esses
# componentes divergem POR CONTA PROPRIA ou apenas respondem ao que recebem.
#-----------------------------------------------------------------------------
for _st in ocean seaice; do
  _achou=0
  for k in $(seq 1 "${RUNS}"); do [[ -s "${_st}_r${k}.stats" ]] && _achou=1; done
  [[ "${_achou}" -eq 1 ]] || continue
  _np=0; _nd=0
  for i in $(seq 1 "${RUNS}"); do
    for j in $(seq $(( i + 1 )) "${RUNS}"); do
      _fa="${_st}_r${i}.stats"; _fb="${_st}_r${j}.stats"
      [[ -s "${_fa}" && -s "${_fb}" ]] || continue
      _np=$(( _np + 1 ))
      cmp -s "${_fa}" "${_fb}" || _nd=$(( _nd + 1 ))
    done
  done
  printf '   %-14s %d de %d pares divergem\n' "${_st}.stats" "${_nd}" "${_np}"
done

#-----------------------------------------------------------------------------
# Etapas do ciclo do gelo (B-RUNLOG-01)
#
# Localiza a divergência DENTRO do SIS2. As etapas estão na ordem em que
# ocorrem no ModelAdvance; a primeira que divergir é onde a semente entra, e as
# seguintes são propagação. Start e End da mesma rotina distinguem "entrou
# dentro da etapa" de "entrou entre etapas".
#-----------------------------------------------------------------------------
if [[ -s "gelo_r1.txt" ]]; then
  echo
  echo "== Etapas do ciclo do gelo (checksum de part_size) =="
  echo
  _primeira_etapa=''
  # shellcheck disable=SC2086
  IFS='|' read -ra _ETAPAS <<< "${ETAPAS_GELO}"
  for _et in "${_ETAPAS[@]}"; do
    _np=0; _nd=0; _ncmp=''
    for i in $(seq 1 "${RUNS}"); do
      for j in $(seq $(( i + 1 )) "${RUNS}"); do
        [[ -s "gelo_r${i}.txt" && -s "gelo_r${j}.txt" ]] || continue
        grep -E "${_et} (${CAMPOS_GELO})\$" "gelo_r${i}.txt" \
          | sed -E 's/.*c= *([0-9-]+) +(.*)/\2 \1/' > /tmp/_g1_$$.txt
        grep -E "${_et} (${CAMPOS_GELO})\$" "gelo_r${j}.txt" \
          | sed -E 's/.*c= *([0-9-]+) +(.*)/\2 \1/' > /tmp/_g2_$$.txt
        _n1="$(wc -l < /tmp/_g1_$$.txt)"; _n2="$(wc -l < /tmp/_g2_$$.txt)"
        if [[ "${_n1}" -eq 0 || "${_n2}" -eq 0 ]]; then
          rm -f /tmp/_g1_$$.txt /tmp/_g2_$$.txt; continue
        fi
        _ncmp="${_n1}"
        if [[ "${_n1}" -ne "${_n2}" ]]; then
          printf '   AVISO %s: r%s tem %s, r%s tem %s emissoes\n' \
                 "${_et}" "${i}" "${_n1}" "${j}" "${_n2}"
        fi
        _np=$(( _np + 1 ))
        cmp -s /tmp/_g1_$$.txt /tmp/_g2_$$.txt || _nd=$(( _nd + 1 ))
        rm -f /tmp/_g1_$$.txt /tmp/_g2_$$.txt
      done
    done
    [[ "${_np}" -eq 0 ]] && continue
    printf '   %-34s %d de %d pares divergem  (%s emissoes)\n' \
           "${_et}" "${_nd}" "${_np}" "${_ncmp}"
    if [[ "${_nd}" -gt 0 && -z "${_primeira_etapa}" ]]; then
      _primeira_etapa="${_et}"
    fi
  done
  echo
  if [[ -n "${_primeira_etapa}" ]]; then
    echo "   Primeira etapa divergente: ${_primeira_etapa}"
    echo
    echo "   Campos desse ponto, primeira emissao, r1 contra r2:"
    IFS='|' read -ra _CPS <<< "${CAMPOS_GELO}"
    for _cp in "${_CPS[@]}"; do
      _cpl="$(printf '%s' "${_cp}" | sed 's/\\//g')"
      _v1="$(grep -F "${_primeira_etapa} ${_cpl}" gelo_r1.txt \
             | sed -E 's/.*c= *([0-9-]+).*/\1/' | head -1)"
      _v2="$(grep -F "${_primeira_etapa} ${_cpl}" gelo_r2.txt \
             | sed -E 's/.*c= *([0-9-]+).*/\1/' | head -1)"
      [[ -z "${_v1}" && -z "${_v2}" ]] && continue
      if [[ "${_v1}" == "${_v2}" ]]; then
        printf '     %-22s igual    %s\n' "${_cpl}" "${_v1}"
      else
        printf '     %-22s DIFERE   %s vs %s\n' "${_cpl}" "${_v1}" "${_v2}"
      fi
    done
    echo
    echo "   As etapas posteriores a esta divergem por propagacao, nao por"
    echo "   causa propria. Se a primeira for um 'Start', a semente vem de"
    echo "   ANTES dela no ciclo; se for um 'End', ela entra DENTRO da rotina."
  else
    echo "   Nenhuma etapa do gelo divergiu nos checksums."
    echo "   Se a origem (FIX-DIAG-ICESRC-01) divergir mesmo assim, a semente"
    echo "   esta entre a ultima etapa medida e a montagem do campo exportado."
  fi
fi

#-----------------------------------------------------------------------------
# Diagnóstico do mediador: em QUAL etapa a divergência entra (B-MEDDIAG-01)
#
# Separa a cadeia do gelo em três pontos. A leitura está impressa junto.
#-----------------------------------------------------------------------------
if [[ -s "meddiag_r1.txt" ]]; then
  echo
  echo "== Diagnostico do mediador: etapas do caminho do gelo =="
  echo
  _nd_mask=0; _nd_raw=0; _np_md=0
  for i in $(seq 1 "${RUNS}"); do
    for j in $(seq $(( i + 1 )) "${RUNS}"); do
      [[ -s "meddiag_r${i}.txt" && -s "meddiag_r${j}.txt" ]] || continue
      _np_md=$(( _np_md + 1 ))
      # B-MEDDIAG-02: conta apenas linhas ALTERADAS, nao acrescentadas.
      #
      # cmp e diff simples tratam "um arquivo tem mais linhas" como diferenca.
      # Aqui o que interessa e' valor divergente na MESMA posicao, entao a
      # comparacao e' linha a linha ate' o menor dos dois, e a diferenca de
      # comprimento e' reportada a parte, como aviso, nao como divergencia.
      for _et in 01 02; do
        grep -h "ICEMASK-${_et}" "meddiag_r${i}.txt" > /tmp/_a_$$.txt
        grep -h "ICEMASK-${_et}" "meddiag_r${j}.txt" > /tmp/_b_$$.txt
        _na="$(wc -l < /tmp/_a_$$.txt)"; _nb="$(wc -l < /tmp/_b_$$.txt)"
        _nmin=$(( _na < _nb ? _na : _nb ))
        if [[ "${_nmin}" -gt 0 ]]; then
          head -n "${_nmin}" /tmp/_a_$$.txt > /tmp/_at_$$.txt
          head -n "${_nmin}" /tmp/_b_$$.txt > /tmp/_bt_$$.txt
          if ! cmp -s /tmp/_at_$$.txt /tmp/_bt_$$.txt; then
            [[ "${_et}" == "01" ]] && _nd_mask=$(( _nd_mask + 1 )) \
                                   || _nd_raw=$(( _nd_raw + 1 ))
          fi
          rm -f /tmp/_at_$$.txt /tmp/_bt_$$.txt
        fi
        if [[ "${_na}" -ne "${_nb}" ]]; then
          printf '   AVISO ICEMASK-%s: r%s tem %s linha(s), r%s tem %s.\n' \
                 "${_et}" "${i}" "${_na}" "${j}" "${_nb}"
          printf '         Numero de ciclos diferente, nao valor diferente:\n'
          printf '         o log de PET pode nao ter sido truncado entre rodadas.\n'
        fi
        rm -f /tmp/_a_$$.txt /tmp/_b_$$.txt
      done
    done
  done
  printf '   mascara de origem (ICEMASK-01)      %d de %d pares divergem\n' \
         "${_nd_mask}" "${_np_md}"
  printf '   ifrac bruto pos-regrid (ICEMASK-02) %d de %d pares divergem\n' \
         "${_nd_raw}" "${_np_md}"
  echo
  if (( _nd_mask > 0 )); then
    echo "   LEITURA: a mascara de origem varia entre execucoes. Como ela entra"
    echo "   no ESMF_FieldRegridStore, os PESOS variam com ela, e nenhuma ordem"
    echo "   de soma na execucao conserta isso. Alvo: a construcao da mascara."
  elif (( _nd_raw > 0 )); then
    echo "   LEITURA: mascara identica, ifrac bruto divergente. A divergencia"
    echo "   entra no regrid CONSERVE mascarado (geracao de pesos ou execucao),"
    echo "   ANTES da extrapolacao de vizinhanca. Alvo: rh_ocn2atm_ice."
  else
    echo "   LEITURA: mascara e ifrac bruto identicos ate' os digitos impressos."
    echo "   Se o Si_ifrac entregue divergir, o alvo e' a etapa seguinte, a"
    echo "   NeighborFillExtrapolate. Ressalva: o max e' impresso com 4 digitos,"
    echo "   entao 'identico' aqui nao exclui diferenca de ultimo bit."
  fi
fi

#-----------------------------------------------------------------------------
# Checksum exato do Si_ifrac no mediador (B-BITSUM-01)
#
# Quatro etapas do caminho gelo -> atmosfera, somadas bit a bit em cada PET.
# A primeira (troca, etapa) que difere entre duas execucoes localiza a rotina
# onde o ultimo bit muda. As linhas estao ordenadas por troca e por etapa, entao
# a primeira linha diferente do diff e' exatamente essa.
#-----------------------------------------------------------------------------
if [[ -s "bitsum_r1.txt" ]]; then
  echo
  echo "== Checksum exato do Si_ifrac no mediador (FIX-DIAG-BITSUM-01) =="
  echo
  echo "   Cobertura na troca 1 da execucao 1 (PETs que gravaram e pontos somados):"
  for _e in etapa1 etapa2 etapa3 etapa4; do
    awk -v e="${_e}" '
      $1 == "t=0001" && $2 == e {
        if ($4 ~ /^n=/) { x = $4; sub(/^n=/, "", x); s += x; np++ } else na++
        if ($0 ~ /ERRO=/) ne++ }
      END { printf "     %-7s %3d PET(s), %9d ponto(s)", e, np, s
            if (na) printf ", %d PET(s) sem medida", na
            if (ne) printf ", %d PET(s) com ERRO", ne
            printf "\n" }' bitsum_r1.txt
  done
  echo
  echo "   Primeira troca divergente, por etapa (t=0001 e' a primeira troca):"
  printf '     %-9s %-10s %-10s %-10s %-10s %s\n' "par" "etapa1" "etapa2" "etapa3" "etapa4" "primeira diferenca (troca etapa PET)"
  for i in $(seq 1 "${RUNS}"); do
    for j in $(seq $(( i + 1 )) "${RUNS}"); do
      [[ -s "bitsum_r${i}.txt" && -s "bitsum_r${j}.txt" ]] || continue
      _linha="$(printf '     r%s x r%s   ' "${i}" "${j}")"
      for _e in etapa1 etapa2 etapa3 etapa4; do
        _pd="$(diff <(awk -v e="${_e}" '$2 == e' "bitsum_r${i}.txt") \
                    <(awk -v e="${_e}" '$2 == e' "bitsum_r${j}.txt") \
               | grep -m1 '^<' | awk '{print $2}')"
        _linha+="$(printf '%-10s ' "${_pd:-igual}")"
      done
      _pr="$(diff "bitsum_r${i}.txt" "bitsum_r${j}.txt" | grep -m1 '^<' \
             | awk '{print $2, $3, $4}')"
      _linha+="${_pr:-identico}"
      echo "${_linha}"
      _ni="$(wc -l < "bitsum_r${i}.txt")"; _nj="$(wc -l < "bitsum_r${j}.txt")"
      if [[ "${_ni}" -ne "${_nj}" ]]; then
        printf '       AVISO: r%s tem %s linha(s), r%s tem %s; comparacao desalinhada.\n' \
               "${i}" "${_ni}" "${j}" "${_nj}"
      fi
    done
  done
  echo
  echo "   LEITURA: em cada par, a etapa com a MENOR troca divergente e' onde o"
  echo "   ultimo bit muda primeiro. Se as quatro divergem na mesma troca, vale a"
  echo "   ordem etapa1 -> etapa4: a primeira da lista e' a origem."
  echo "     etapa1 difere           : o Si_ifrac ja' chega diferente do gelo (cap do SIS2)"
  echo "     etapa1 igual, 2 difere  : o regrid CONSERVE mascarado (rh_ocn2atm_ice)"
  echo "     etapa2 igual, 3 difere  : a extrapolacao (NeighborFillExtrapolate)"
  echo "     etapa3 igual, 4 difere  : o RouteOcnToAtm ou a copia para o exportState"
  echo "     as quatro iguais        : a diferenca entra depois do mediador"
  echo "                               (conector MED->MPAS ou importacao do MPAS)"
fi

#-----------------------------------------------------------------------------
# Comparação do que a atmosfera RECEBE (B-IMPORT-DIAG-01)
#
# Bissecção do último trecho da cadeia. Se o monan2_import de um instante já
# difere entre execuções, o mediador entregou campo diferente e a atmosfera é
# mensageira. Se ele é idêntico e o estado do MPAS diverge no mesmo instante,
# a semente está no que a atmosfera FAZ com um campo idêntico.
#-----------------------------------------------------------------------------
if [[ -d "imp_r1" ]]; then
  echo
  echo "== Comparacao do que a atmosfera recebe (monan2_import) =="
  echo
  _prim_imp=''
  for _b in $(cd imp_r1 && ls -1 *.nc 2>/dev/null | sort); do
    _np=0; _nd=0
    for i in $(seq 1 "${RUNS}"); do
      for j in $(seq $(( i + 1 )) "${RUNS}"); do
        _fa="imp_r${i}/${_b}"; _fb="imp_r${j}/${_b}"
        [[ -s "${_fa}" && -s "${_fb}" ]] || continue
        _np=$(( _np + 1 ))
        _o="/tmp/_imp_${i}_${j}_$$.txt"
        nccmp -d -f "${_fa}" "${_fb}" > "${_o}" 2>&1
        if [[ -s "${_o}" ]] && grep -q "DIFFER" "${_o}"; then
          _nd=$(( _nd + 1 ))
        fi
        rm -f "${_o}"
      done
    done
    if [[ "${_nd}" -gt 0 && -z "${_prim_imp}" ]]; then _prim_imp="${_b}"; fi
    printf '   %-44s %d de %d pares divergem\n' "${_b}" "${_nd}" "${_np}"
  done
  if [[ -n "${_prim_imp}" ]]; then
    echo
    echo "   Primeiro instante de importacao divergente: ${_prim_imp}"
  else
    echo
    echo "   Nenhum arquivo de importacao divergiu: a atmosfera recebeu"
    echo "   exatamente os mesmos campos em todas as execucoes."
  fi
fi

#-----------------------------------------------------------------------------
# Comparação das saídas do oceano (B-OCN-DIAG-01)
#
# Camada com resolução temporal própria. Responde "em que hora o MOM6 se
# separa", que o ocean.stats não consegue quando há poucas janelas.
#-----------------------------------------------------------------------------
if [[ -d "ocn_r1" ]]; then
  echo
  echo "== Comparacao das saidas do oceano (diag_table) =="
  echo
  for _b in $(cd ocn_r1 && ls -1 *.nc 2>/dev/null); do
    _np=0; _nd=0; _prim=''
    for i in $(seq 1 "${RUNS}"); do
      for j in $(seq $(( i + 1 )) "${RUNS}"); do
        _fa="ocn_r${i}/${_b}"; _fb="ocn_r${j}/${_b}"
        [[ -s "${_fa}" && -s "${_fb}" ]] || continue
        _np=$(( _np + 1 ))
        _o="/tmp/_ocn_${i}_${j}_$$.txt"
        nccmp -d -f "${_fa}" "${_fb}" > "${_o}" 2>&1
        if [[ -s "${_o}" ]] && grep -q "DIFFER" "${_o}"; then
          _nd=$(( _nd + 1 ))
          _r="$(grep -oE '\[[0-9]+,' "${_o}" | tr -d '[,' | sort -n | head -1)"
          if [[ -z "${_prim}" || ( -n "${_r}" && "${_r}" -lt "${_prim}" ) ]]; then
            _prim="${_r}"
          fi
        fi
        rm -f "${_o}"
      done
    done
    if [[ "${_nd}" -eq 0 ]]; then
      printf '   %-28s %d de %d pares divergem\n' "${_b}" "${_nd}" "${_np}"
    else
      printf '   %-28s %d de %d pares divergem, 1o registro: %s\n' \
             "${_b}" "${_nd}" "${_np}" "${_prim:-?}"
    fi
  done
fi

#-----------------------------------------------------------------------------
# Classes de equivalência: execuções idênticas entre si formam um grupo.
# Duas execuções iguais e uma terceira diferente é um quadro muito diferente
# de três execuções todas diferentes entre si, e a fração de pares sozinha
# não distingue os dois.
#-----------------------------------------------------------------------------
echo
echo "== Resumo =="
printf '   pares comparados : %d\n' "${n_par}"
printf '   pares divergentes: %d\n' "${n_dif}"
printf '   pares identicos  : %d\n' "$(( n_par - n_dif ))"
if [[ "${n_par}" -gt 0 ]]; then
  printf '   taxa de divergencia entre pares: %d%%\n' \
         "$(( 100 * n_dif / n_par ))"
fi

echo
if [[ "${n_dif}" -eq 0 ]]; then
  echo "   NENHUM par divergiu em ${RUNS} execucoes."
  echo "   Isso NAO prova reprodutibilidade: com divergencia intermitente, a"
  echo "   ausencia em ${n_par} pares apenas limita a taxa por cima. Quanto"
  echo "   maior --runs, mais apertado o limite."
elif [[ "${n_dif}" -eq "${n_par}" ]]; then
  echo "   TODOS os pares divergiram: cada execucao produz um resultado proprio."
  echo "   Nao ha dois resultados estaveis, ha ruido por execucao."
else
  echo "   Divergencia INTERMITENTE confirmada nesta configuracao: alguns pares"
  echo "   batem e outros nao. Qualquer teste de configuracao lido a partir de"
  echo "   UMA dupla rodada e' indistinguivel de sorte; dimensione o numero de"
  echo "   pares pela taxa acima antes de concluir qualquer coisa."
fi

echo
echo "   Primeiro registro divergente por par:"
for k in "${!PRIMEIRO[@]}"; do
  printf '     %-10s registro %s\n' "${k}" "${PRIMEIRO[$k]}"
done | sort

if [[ "${tem_exp}" -eq 1 ]]; then
  echo
  echo "== Resumo do primeiro monan_export =="
  printf '   pares comparados : %d\n' "${n_par_exp}"
  printf '   pares divergentes: %d\n' "${n_dif_exp}"
  echo
  echo "   Leitura cruzada com o reprodiag:"
  if (( n_dif_exp > 0 && n_dif == 0 )); then
    echo "     export diverge, estado nao: a semente esta na EXPORTACAO"
    echo "     (mapeamento Voronoi -> grade regular em state_set_field_1d), e o"
    echo "     estado do MPAS e' determinístico."
  elif (( n_dif_exp > 0 && n_dif > 0 )); then
    echo "     os dois divergem: consistente com a exportacao ser a semente e o"
    echo "     estado ser contaminado depois, via mediador e injecao. Para"
    echo "     confirmar a ordem, verifique se o export do PRIMEIRO instante"
    echo "     diverge antes de o estado divergir."
  elif (( n_dif_exp == 0 && n_dif > 0 )); then
    echo "     estado diverge, export nao: a semente NAO esta na exportacao."
    echo "     Procure no caminho de importacao e injecao."
  else
    echo "     nenhum dos dois divergiu nestes pares."
  fi
fi

echo
echo "   Arquivos preservados: ${PREFIXO}1.nc .. ${PREFIXO}${RUNS}.nc"
echo "                         ${PREFIXO_EXP}1.nc .. ${PREFIXO_EXP}${RUNS}.nc"
echo "                         ocean_r*.stats  seaice_r*.stats"
echo "                         ocn_r*/ (saidas do diag_table)"
echo "                         imp_r*/ (monan2_import por instante)"
echo "                         meddiag_r*.txt (FIX-DIAG do mediador)"
echo "                         bitsum_r*.txt (checksum exato do Si_ifrac, por PET)"
echo "                         gelo_r*.txt (checksums de part_size do SIS2)"
echo "   Outras variaveis:     --var t2m, --var skintemp, --var xice"
echo
echo "   LEMBRETE: a taxa vale para a configuracao registrada no topo desta"
echo "   saida. Trocar atm_pet_count, dt_coupling ou o modo de acoplamento"
echo "   exige medir de novo; taxas de configuracoes diferentes nao se comparam"
echo "   sem levar em conta quantos pares sustentam cada uma."

[[ "${n_dif}" -eq 0 ]] && exit 0 || exit 1
