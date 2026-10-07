#!/usr/bin/env bash
# =============================================================================
# compara-config.bash: a leitura do nuopc.input (config_read) em duas versões.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila coupler_config.F90 (e o que ele usa) da versão de um commit e da
# árvore de trabalho, liga a cada uma o programa tests/config/test_config.F90
# da árvore de trabalho e o roda com os mesmos arquivos de configuração. Para
# cada caso, a saída (mensagens de config_read, código de retorno e valor de
# todas as variáveis cfg_*) tem de ser idêntica nas duas versões. Confere
# também que o nuopc.input da raiz é lido, na versão de hoje, sem erro, sem
# chave obsoleta e sem grupo obrigatório ausente.
#
# Casos: o nuopc.input da raiz; arquivo vazio e arquivo ausente; chave
# desconhecida num grupo obrigatório e no &nuopc_regrid; chaves obsoletas;
# cada regra de erro fatal sozinha; os avisos (combinação não validada,
# multi_on_error, passos, grid_res_deg, sst_default e as três formas de
# seq_repro ser ignorado); valores em maiúsculas; substituições do
# &nuopc_regrid; as combinações com o DOCN e com o DATM; e duas leituras
# seguidas (a segunda parte dos valores da primeira; uma leitura com erro
# não muda nenhum valor).
#
# Chaves por modelo (desde a R-FASE13-29): um caso NOME pode ter um arquivo
# NOME.rev.input, lido pela versão de referência no lugar de NOME.input. É
# assim que um arquivo com as chaves novas (atm_model, ocn_model,
# ice_model, atm_boundary) é comparado com o mesmo arquivo escrito com as
# chaves antigas: a leitura tem de dar os mesmos valores. Os casos que só
# a versão atual sabe ler (valor fora da tabela, chave antiga que contradiz
# a nova) conferem o código de retorno e a mensagem esperada. As mensagens
# que mudaram de propósito estão em tests/config/mensagens-mudadas.sed e são
# traduzidas na saída da referência antes da comparação.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/config/compara-config.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase13-20-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/config)
#
# Variável: FC (padrão: mpif90).
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,28p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/config}" && cd "${2:-${RAIZ}/build-local/config}" && pwd)
FC=${FC:-mpif90}
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
PROG="${RAIZ}/tests/config/test_config.F90"

# compila VERSAO RAIZ_DA_VERSAO: os fontes de que test_config depende, na
# ordem dos 'use' da versão, e o programa
compila() {
  local versao=$1 src=$2 dir="${SAIDA}/$1" o f
  rm -rf "${dir}"; mkdir -p "${dir}"
  ( cd "${dir}" || exit 2
    for o in $(python3 "${RAIZ}/tools/dev/dependencias.py" objetos -s "${src}" "${PROG}"); do
      f=$(find "${src}/src" -name "${o%.o}.F90" | head -1)
      # shellcheck disable=SC2086
      ${FC} ${EINC} -cpp -ffree-line-length-none -O2 -ffp-contract=off -c "${f}" -o "${o}" || exit 2
    done
    # Saída na forma das chaves lógicas também na versão com chaves por modelo
    local def=""
    grep -q 'cfg_atm_model' "${src}/src/shared/coupler_config.F90" && def="-DCOM_CHAVES_POR_MODELO"
    # shellcheck disable=SC2086
    ${FC} ${EINC} -cpp ${def} -ffree-line-length-none -c "${PROG}" -o test_config.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_config test_config.o \
      $(python3 "${RAIZ}/tools/dev/dependencias.py" objetos -s "${src}" "${PROG}") ${ELIB}
  ) > "${SAIDA}/compila_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
}

rm -rf "${SAIDA}/fonte_rev"; mkdir -p "${SAIDA}/fonte_rev"
git -C "${RAIZ}" archive "${REV}" src | tar -x -C "${SAIDA}/fonte_rev" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }
compila rev "${SAIDA}/fonte_rev"
compila atual "${RAIZ}"

# Arquivos de configuração: caso NOME 'grupos'; os grupos ausentes valem o
# padrão. grupos 'grupo=chaves' ... escreve os oito grupos obrigatórios,
# vazios (valores padrão, sem aviso de grupo ausente) ou com as chaves dadas.
C="${SAIDA}/casos"; rm -rf "${C}"; mkdir -p "${C}"
grupos() {
  local g a chaves
  for g in driver atm netcdf atm_bnd docn ocn mode petlayout; do
    chaves=""
    for a in "$@"; do [[ "${a%%=*}" == "${g}" ]] && chaves="${a#*=}"; done
    printf '&nuopc_%s %s /\n' "${g}" "${chaves}"
  done
}
PROD=$(grupos | grep -v petlayout)
LAYOUT="&nuopc_petlayout coupling_mode='concurrent', atm_pet_count=8, ocn_pet_count=3, ice_pet_count=1 /"
caso() { printf '%s\n' "$2" > "${C}/$1.input"; }

cp "${RAIZ}/nuopc.input" "${C}/raiz.input"
caso vazio ""
caso sintaxe_driver "&nuopc_driver dt_couplin=600 /"
caso sintaxe_regrid "${PROD}
&nuopc_petlayout /
&nuopc_regrid regrid_rota(1)='atm2ocn' /"
caso obsoletas "&nuopc_driver write_fixdiag=.true. /
&nuopc_atm /
&nuopc_netcdf /
&nuopc_atm_bnd /
&nuopc_docn /
&nuopc_ocn use_mommesh=.true., restart_n=3 /
&nuopc_mode /
&nuopc_petlayout /"
for regra in "log_kind_invalido|&nuopc_driver log_kind='multiplo' /" \
             "log_level_invalido|&nuopc_driver log_level='verbose' /" \
             "dt_coupling_zero|&nuopc_driver dt_coupling=0 /" \
             "dt_atm_negativo|&nuopc_driver dt_atm=-60 /"; do
  caso "${regra%%|*}" "${regra#*|}
&nuopc_atm /
&nuopc_netcdf /
&nuopc_atm_bnd /
&nuopc_docn /
&nuopc_ocn /
&nuopc_mode /
&nuopc_petlayout /"
done
caso docn_mode_invalido "&nuopc_driver /
&nuopc_atm /
&nuopc_netcdf /
&nuopc_atm_bnd /
&nuopc_docn docn_mode='binario' /
&nuopc_ocn /
&nuopc_mode /
&nuopc_petlayout /"
for regra in "coupling_mode_invalido|&nuopc_petlayout coupling_mode='paralelo' /" \
             "pet_layout_invalido|&nuopc_petlayout pet_layout='misto' /" \
             "concurrent_shared|&nuopc_petlayout coupling_mode='concurrent', pet_layout='shared' /" \
             "contagem_negativa|&nuopc_petlayout pet_layout='split', ocn_pet_count=-1 /" \
             "shared_com_contagem|&nuopc_petlayout atm_pet_count=8 /" \
             "gelo_sem_sis2|&nuopc_petlayout pet_layout='split', ice_pet_count=2, use_sis2_dynamic=.false. /"; do
  caso "${regra%%|*}" "${PROD}
${regra#*|}"
done
caso combinacao_recusada "$(grupos 'mode=use_med_to_mpas=.false.')"
caso gelo_docn_sem_arquivo "&nuopc_driver /
&nuopc_atm /
&nuopc_netcdf /
&nuopc_atm_bnd /
&nuopc_docn docn_ice_file='' /
&nuopc_ocn /
&nuopc_mode use_docn_ice=.true. /
&nuopc_petlayout /"
caso so_inicio_sem_gelo "$(grupos 'mode=docn_ice_init_only=.true.')"
caso avisos "&nuopc_driver log_kind='multi_on_error', dt_coupling=1000, dt_atm=1200 /
&nuopc_atm /
&nuopc_netcdf grid_res_deg=20.0 /
&nuopc_atm_bnd sst_default=100.0 /
&nuopc_docn /
&nuopc_ocn /
&nuopc_mode use_docn=.true., use_med_to_mpas=.false. /
&nuopc_petlayout use_sis2_dynamic=.false., seq_repro=.true. /"
caso seq_repro_shared "${PROD}
&nuopc_petlayout seq_repro=.true. /"
caso seq_repro_sem_sis2 "${PROD}
&nuopc_petlayout pet_layout='split', use_sis2_dynamic=.false., seq_repro=.true. /"
caso seq_repro_valido "${PROD}
&nuopc_petlayout pet_layout='split', atm_pet_count=8, ocn_pet_count=3, ice_pet_count=1, seq_repro=.true. /"
caso maiusculas "&nuopc_driver log_kind='MULTI', log_level='DEBUG' /
&nuopc_atm /
&nuopc_netcdf /
&nuopc_atm_bnd /
&nuopc_docn /
&nuopc_ocn /
&nuopc_mode /
&nuopc_petlayout coupling_mode='CONCURRENT' /"
caso regrid "${PROD}
${LAYOUT}
&nuopc_regrid regrid_route(1)='ocn2atm', regrid_scheme(1)='idw', regrid_options(1)='vizinhos=4',
  regrid_route(3)='atm2ocn', regrid_methods(3)='conserve,bilinear', regrid_weights(3)='pesos.nc',
  regrid_class(3)='fluxo' /"
caso docn_completo "&nuopc_driver start_date='2025-01-01', stop_date='2025-01-03', dt_coupling=1800, dt_atm=300 /
&nuopc_atm mesh_atm='malha.nc', config_dir='cfg/', write_diag=.true. /
&nuopc_netcdf write_netcdf=.false., output_dir='saida', grid_res_deg=0.5 /
&nuopc_atm_bnd sst_default=290.5, ice_fraction_default=0.25, zorl_default=0.002 /
&nuopc_docn docn_nx=360, docn_ny=180, docn_dt_data=21600, docn_epoch_year=2000,
  docn_epoch_month=2, docn_epoch_day=3, docn_sst_file='sst.nc', docn_ice_file='gelo.nc',
  docn_cur_file='cor.nc', docn_sst_varname='t', docn_ice_varname='c',
  docn_cur_u_varname='u', docn_cur_v_varname='v', docn_ice_pct=.true.,
  write_import_diag=.true., import_diag_dir='imp' /
&nuopc_ocn mesh_ocn='grade.nc' /
&nuopc_mode use_docn=.true., use_med_to_mpas=.false., use_docn_ice=.true., docn_ice_init_only=.true. /
&nuopc_petlayout use_sis2_dynamic=.false. /"

# Combinações com o DOCN e com o DATM, pelas chaves antigas
caso datm_mom6 "$(grupos 'mode=use_datm=.true.' 'petlayout=use_sis2_dynamic=.false.')"
caso datm_mom6_sis2 "$(grupos 'mode=use_datm=.true.')"
caso datm_docn "$(grupos 'mode=use_datm=.true., use_docn=.true., use_med_to_mpas=.false.' \
                         'petlayout=use_sis2_dynamic=.false.')"
caso docn_mediador "$(grupos 'mode=use_docn=.true.' 'petlayout=use_sis2_dynamic=.false.')"
caso sis2_docn "$(grupos 'mode=use_docn=.true.')"

# Chaves por modelo (NOME.input), comparadas com as antigas (NOME.rev.input)
par() { caso "$1" "$2"; caso "$1.rev" "$3"; }
par novas_producao "$(grupos "mode=atm_model='mpas', ocn_model='mom6', ice_model='sis2', atm_boundary='med'")" \
  "$(grupos)"
par novas_docn "$(grupos "mode=ocn_model='docn', ice_model='none', atm_boundary='ocn'")" \
  "$(grupos 'mode=use_docn=.true., use_med_to_mpas=.false.' 'petlayout=use_sis2_dynamic=.false.')"
par novas_datm_docn "$(grupos "mode=atm_model='datm', ocn_model='docn', ice_model='none'")" \
  "$(grupos 'mode=use_datm=.true., use_docn=.true.' 'petlayout=use_sis2_dynamic=.false.')"
par novas_sem_gelo "$(grupos "mode=ice_model='none'")" \
  "$(grupos 'petlayout=use_sis2_dynamic=.false.')"
par novas_maiusculas "$(grupos "mode=OCN_MODEL='DOCN', Ice_Model='None', ATM_BOUNDARY='OCN'")" \
  "$(grupos 'mode=use_docn=.true., use_med_to_mpas=.false.' 'petlayout=use_sis2_dynamic=.false.')"
par novas_recusada "$(grupos "mode=atm_boundary='ocn'")" \
  "$(grupos 'mode=use_med_to_mpas=.false.')"
par novas_sis2_docn "$(grupos "mode=ocn_model='docn'")" \
  "$(grupos 'mode=use_docn=.true.')"
par novas_gelo_sem_sis2 "$(grupos "mode=ice_model='none'" "petlayout=pet_layout='split', ice_pet_count=2")" \
  "$(grupos "petlayout=pet_layout='split', ice_pet_count=2, use_sis2_dynamic=.false.")"
par novas_seq_repro "$(grupos "mode=ice_model='none'" "petlayout=pet_layout='split', seq_repro=.true.")" \
  "$(grupos "petlayout=pet_layout='split', seq_repro=.true., use_sis2_dynamic=.false.")"
par ambas_iguais "$(grupos "mode=use_docn=.true., ocn_model='docn', use_med_to_mpas=.false., atm_boundary='ocn', ice_model='none'" \
                           'petlayout=use_sis2_dynamic=.false.')" \
  "$(grupos 'mode=use_docn=.true., use_med_to_mpas=.false.' 'petlayout=use_sis2_dynamic=.false.')"

# Casos: NOME = arquivos lidos em sequência
CASOS="raiz vazio ausente sintaxe_driver sintaxe_regrid obsoletas log_kind_invalido
log_level_invalido dt_coupling_zero dt_atm_negativo docn_mode_invalido coupling_mode_invalido
pet_layout_invalido concurrent_shared contagem_negativa shared_com_contagem gelo_sem_sis2
combinacao_recusada gelo_docn_sem_arquivo so_inicio_sem_gelo avisos seq_repro_shared
seq_repro_sem_sis2 seq_repro_valido maiusculas regrid docn_completo
datm_mom6 datm_mom6_sis2 datm_docn docn_mediador sis2_docn
novas_producao novas_docn novas_datm_docn novas_sem_gelo novas_maiusculas novas_recusada
novas_sis2_docn novas_gelo_sem_sis2 novas_seq_repro ambas_iguais
seguidas_ok seguidas_erro seguidas_novas"
# arquivos CASO VERSAO: os arquivos lidos; a referência lê NOME.rev.input
# quando ele existe
arquivos() {
  local f lista
  case "$1" in
    ausente)        lista="nao_existe" ;;
    seguidas_ok)    lista="docn_completo vazio" ;;
    seguidas_erro)  lista="regrid dt_coupling_zero vazio" ;;
    seguidas_novas) lista="novas_docn vazio" ;;
    *)              lista="$1" ;;
  esac
  for f in ${lista}; do
    if [[ "$2" == rev && -f "${C}/${f}.rev.input" ]]; then
      echo "${C}/${f}.rev.input"
    else
      echo "${C}/${f}.input"
    fi
  done
}
# Na saída da referência: o nome do arquivo .rev.input como o do caso, e as
# mensagens que mudaram de propósito com o texto novo
MUDADAS="${RAIZ}/tests/config/mensagens-mudadas.sed"

ndif=0
for caso in ${CASOS}; do
  for versao in rev atual; do
    # shellcheck disable=SC2046
    ( cd "${C}" && env -u PALS_RANKID -u PMI_RANK -u PMIX_RANK -u OMPI_COMM_WORLD_RANK \
        "${SAIDA}/${versao}/test_config" $(arquivos "${caso}" "${versao}") ) \
      | sed "s|${C}/||g" > "${SAIDA}/${caso}_${versao}.txt" 2>&1
  done
  sed -i -e 's|\.rev\.input|.input|g' -f "${MUDADAS}" "${SAIDA}/${caso}_rev.txt"
  if cmp -s "${SAIDA}/${caso}_rev.txt" "${SAIDA}/${caso}_atual.txt"; then
    printf '  %-24s iguais (rc %s)\n' "${caso}" "$(grep '^rc = ' "${SAIDA}/${caso}_atual.txt" | cut -d' ' -f3 | paste -sd,)"
  else
    printf '  %-24s DIFEREM\n' "${caso}"
    diff "${SAIDA}/${caso}_rev.txt" "${SAIDA}/${caso}_atual.txt" | head -10 | sed 's/^/      /'
    ndif=$((ndif + 1))
  fi
done
# Casos que só a versão atual sabe ler: erro fatal com a mensagem esperada
espera() {   # espera NOME MENSAGEM GRUPOS...
  local nome=$1 msg=$2 saida; shift 2
  caso "${nome}" "$(grupos "$@")"
  saida="${SAIDA}/${nome}_atual.txt"
  ( cd "${C}" && env -u PALS_RANKID -u PMI_RANK -u PMIX_RANK -u OMPI_COMM_WORLD_RANK \
      "${SAIDA}/atual/test_config" "${C}/${nome}.input" ) > "${saida}" 2>&1
  if grep -q '^rc = 2$' "${saida}" && grep -qF "[coupler_config] ERRO: ${msg}" "${saida}"; then
    printf '  %-24s erro esperado (rc 2)\n' "${nome}"
  else
    printf '  %-24s SEM O ERRO ESPERADO: %s\n' "${nome}" "${msg}"
    grep -v ' = \|^==' "${saida}" | sed 's/^/      /'
    ndif=$((ndif + 1))
  fi
}
espera modelo_invalido 'ocn_model="hycom" invalido; use mom6|docn.' "mode=ocn_model='hycom'"
espera gelo_invalido 'ice_model="cice" invalido; use sis2|none.' "mode=ice_model='cice'"
espera contorno_invalido 'atm_boundary="mediador" invalido; use med|ocn.' "mode=atm_boundary='mediador'"
espera contradiz 'ocn_model="mom6" contradiz a chave antiga use_docn=.true.; use so ocn_model.' \
  "mode=use_docn=.true., ocn_model='mom6'"
espera contradiz_gelo 'ice_model="sis2" contradiz a chave antiga use_sis2_dynamic=.false.; use so ice_model.' \
  "mode=ice_model='sis2'" 'petlayout=use_sis2_dynamic=.false.'
NESPERA=5

# O nuopc.input da raiz, na versão de hoje: lido sem erro, sem chave
# obsoleta e com todos os grupos obrigatórios (outros avisos, como o de
# seq_repro ignorado no modo concorrente, são permitidos)
raiz="${SAIDA}/raiz_atual.txt"
if grep -q '^rc = 0$' "${raiz}" && ! grep -q 'ERRO' "${raiz}" \
   && ! grep -q 'obsoleta' "${raiz}" && ! grep -q 'ausente, usando valores padrao' "${raiz}"; then
  echo "  nuopc.input da raiz: lido sem erro, sem chave obsoleta e sem grupo ausente"
else
  echo "  nuopc.input da raiz: ERRO, chave obsoleta ou grupo ausente na leitura:"
  grep -v ' = \|^==' "${raiz}" | sed 's/^/      /'
  ndif=$((ndif + 1))
fi
if [[ ${ndif} -gt 0 ]]; then
  echo "FALHOU: ${ndif} caso(s) diferem de ${REV} ou o nuopc.input da raiz tem problema"
  exit 1
fi
echo "OK: a leitura da configuração é a mesma de ${REV} nos $(echo ${CASOS} | wc -w) casos," \
  "e os ${NESPERA} erros só da versão atual saem como esperado"
