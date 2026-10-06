#!/usr/bin/env bash
# =============================================================================
# compara-config.bash: a leitura do nuopc.input (config_read) em duas versões.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila coupler_config.F90 (e o que ele usa) da versão de um commit e da
# árvore de trabalho, liga a cada uma o programa tests/config/test_config.F90
# da árvore de trabalho e o roda com os mesmos arquivos de configuração. Para
# cada caso, a saída (mensagens de config_read, código de retorno e valor de
# todas as variáveis cfg_*) tem de ser idêntica nas duas versões.
#
# Casos: o nuopc.input da raiz; arquivo vazio e arquivo ausente; chave
# desconhecida num grupo obrigatório e no &nuopc_regrid; chaves obsoletas;
# cada regra de erro fatal sozinha; os avisos (combinação não validada,
# multi_on_error, passos, grid_res_deg, sst_default e as três formas de
# seq_repro ser ignorado); valores em maiúsculas; substituições do
# &nuopc_regrid; e duas leituras seguidas (a segunda parte dos valores da
# primeira; uma leitura com erro não muda nenhum valor).
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
[[ -n "${REV}" ]] || { sed -n '2,26p' "$0"; exit 2; }
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
    # shellcheck disable=SC2086
    ${FC} ${EINC} -ffree-line-length-none -c "${PROG}" -o test_config.o &&
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

# Casos: NOME = arquivos lidos em sequência
CASOS="raiz vazio ausente sintaxe_driver sintaxe_regrid obsoletas log_kind_invalido
log_level_invalido dt_coupling_zero dt_atm_negativo docn_mode_invalido coupling_mode_invalido
pet_layout_invalido concurrent_shared contagem_negativa shared_com_contagem gelo_sem_sis2
combinacao_recusada gelo_docn_sem_arquivo so_inicio_sem_gelo avisos seq_repro_shared
seq_repro_sem_sis2 seq_repro_valido maiusculas regrid docn_completo
seguidas_ok seguidas_erro"
arquivos() {
  case "$1" in
    ausente)       echo "${C}/nao_existe.input" ;;
    seguidas_ok)   echo "${C}/docn_completo.input ${C}/vazio.input" ;;
    seguidas_erro) echo "${C}/regrid.input ${C}/dt_coupling_zero.input ${C}/vazio.input" ;;
    *)             echo "${C}/$1.input" ;;
  esac
}

ndif=0
for caso in ${CASOS}; do
  for versao in rev atual; do
    # shellcheck disable=SC2046
    ( cd "${C}" && env -u PALS_RANKID -u PMI_RANK -u PMIX_RANK -u OMPI_COMM_WORLD_RANK \
        "${SAIDA}/${versao}/test_config" $(arquivos "${caso}") ) \
      | sed "s|${C}/||g" > "${SAIDA}/${caso}_${versao}.txt" 2>&1
  done
  if cmp -s "${SAIDA}/${caso}_rev.txt" "${SAIDA}/${caso}_atual.txt"; then
    printf '  %-24s iguais (rc %s)\n' "${caso}" "$(grep '^rc = ' "${SAIDA}/${caso}_atual.txt" | cut -d' ' -f3 | paste -sd,)"
  else
    printf '  %-24s DIFEREM\n' "${caso}"
    diff "${SAIDA}/${caso}_rev.txt" "${SAIDA}/${caso}_atual.txt" | head -10 | sed 's/^/      /'
    ndif=$((ndif + 1))
  fi
done
if [[ ${ndif} -gt 0 ]]; then
  echo "FALHOU: ${ndif} caso(s) diferem de ${REV}"
  exit 1
fi
echo "OK: a leitura da configuração é a mesma de ${REV} nos $(echo ${CASOS} | wc -w) casos"
