#!/usr/bin/env bash
# =============================================================================
# confere-chaves-nuopc.bash: a leitura da escolha dos modelos pelos scripts.
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Os scripts que precisam saber qual modelo ocupa cada posição
# (run/run_esmApp.jaci, tools/coupler/*, tools/dev/cria-linha-base.bash)
# leem o nuopc.input por tools/coupler/chaves_nuopc.bash. Este teste
# confere, sem a Jaci:
#   1. a sintaxe dos scripts que carregam chaves_nuopc.bash (bash -n);
#   2. que nenhum script lê uma chave antiga diretamente (use_datm,
#      use_docn, use_med_to_mpas, use_sis2_dynamic): todos passam pelas
#      funções comuns;
#   3. nuopc_modelo, nuopc_usa e nuopc_chaves_antigas em modo estrito
#      (set -euo pipefail), com arquivos nas duas formas de chave, mistos,
#      vazio, ausente, em maiúsculas e com comentários: uma chave ausente
#      não pode parar o script (foi o que parou o --check da R-FASE13-29);
#   4. nuopc_troca_modelo, que os scripts usam para gerar variantes;
#   5. com TEST_CONFIG (o programa tests/config/test_config.F90 compilado,
#      que a conferência config deixa em build-local/confere/config/atual),
#      que os scripts e config_read escolhem os mesmos modelos em cada
#      arquivo.
#
# Uso (na raiz do repositório):
#   tests/scripts/confere-chaves-nuopc.bash [SAIDA]
#     SAIDA   diretório de trabalho (padrão: build-local/chaves)
# Variável: TEST_CONFIG (opcional), caminho do test_config compilado.
#
# Código de saída: 0 se tudo confere; 1 se algo falhou; 2 erro de preparo.
# =============================================================================
set -euo pipefail

RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${1:-${RAIZ}/build-local/chaves}" && cd "${1:-${RAIZ}/build-local/chaves}" && pwd)
AJUDA="${RAIZ}/tools/coupler/chaves_nuopc.bash"
[[ -f "${AJUDA}" ]] || { echo "ERRO: ${AJUDA} não existe" >&2; exit 2; }
# shellcheck source=../../tools/coupler/chaves_nuopc.bash
source "${AJUDA}"

nfalhas=0
resultado() {   # resultado NOME OK(0|1) [detalhe]
  if [[ "$2" -eq 0 ]]; then
    printf '  %-44s OK\n' "$1"
  else
    printf '  %-44s FALHOU %s\n' "$1" "${3:-}"
    nfalhas=$((nfalhas + 1))
  fi
}

# 1. Sintaxe dos scripts
SCRIPTS="run/run_esmApp.jaci tools/coupler/chaves_nuopc.bash tools/coupler/test-concurrent.bash
tools/coupler/test-sequential-split.bash tools/coupler/roda_repro_producao.sh
tools/coupler/roda_repro_datm_mom6.sh tools/dev/cria-linha-base.bash"
ok=0
for s in ${SCRIPTS}; do
  bash -n "${RAIZ}/${s}" || { echo "      erro de sintaxe: ${s}"; ok=1; }
done
resultado "sintaxe dos scripts (bash -n)" "${ok}"

# 2. Nenhuma leitura direta de chave antiga
diretas=$(grep -nE "(_nuopc_get|_nuopc_pet|_nuopc_get_in[[:space:]]+[a-z_]+|nml_val)[[:space:]]+use_(datm|docn|med_to_mpas|sis2_dynamic)\b|grep[^|]*use_(datm|docn|med_to_mpas|sis2_dynamic)[[:space:]]*\[" \
           $(for s in ${SCRIPTS}; do echo "${RAIZ}/${s}"; done) || true)
[[ -z "${diretas}" ]] && ok=0 || ok=1
resultado "nenhuma leitura direta de chave antiga" "${ok}" "${diretas}"

# 3. Leitura em modo estrito
C="${SAIDA}/casos"; rm -rf "${C}"; mkdir -p "${C}"
cp "${RAIZ}/nuopc.input" "${C}/raiz.input"
printf '&nuopc_mode\n  use_datm = .false.\n  use_docn = .false.\n  use_med_to_mpas = .true.\n/\n&nuopc_petlayout\n  use_sis2_dynamic = .true.\n/\n' > "${C}/antigas_producao.input"
printf '&nuopc_mode\n  use_docn        = .true.   ! .true. = DOCN\n  use_med_to_mpas = .false.\n/\n&nuopc_petlayout\n  use_sis2_dynamic = .false.\n/\n' > "${C}/antigas_docn.input"
printf "&nuopc_mode\n  ocn_model = 'docn'   ! oceano = dados\n  ice_model = 'none'\n  atm_boundary = 'ocn'\n/\n" > "${C}/novas_docn.input"
printf "&nuopc_mode\n  ATM_MODEL = 'DATM'\n  Ice_Model = \"None\",\n/\n" > "${C}/novas_maiusculas.input"
printf "&nuopc_mode\n  use_docn = .true.\n  ocn_model = 'docn'\n/\n&nuopc_petlayout\n  use_sis2_dynamic = .false.\n/\n" > "${C}/mistas.input"
printf '&nuopc_driver /\n' > "${C}/vazio.input"
# arquivo  esperado (ATM OCN ICE BND | antigas)
CASOS="raiz:mpas mom6 sis2 med|
antigas_producao:mpas mom6 sis2 med|use_datm use_docn use_med_to_mpas use_sis2_dynamic
antigas_docn:mpas docn none ocn|use_docn use_med_to_mpas use_sis2_dynamic
novas_docn:mpas docn none ocn|
novas_maiusculas:datm mom6 none med|
mistas:mpas docn none med|use_docn use_sis2_dynamic
vazio:mpas mom6 sis2 med|
nao_existe:mpas mom6 sis2 med|"
while IFS= read -r linha; do
  nome=${linha%%:*}; resto=${linha#*:}
  esperado=${resto%%|*}; antigas=${resto#*|}
  arq="${C}/${nome}.input"
  # cada leitura numa subshell estrita: uma parada por set -e aparece como falha
  obtido=$(bash -c 'set -euo pipefail; source "$1"; echo "$(nuopc_modelo "$2" ATM) $(nuopc_modelo "$2" OCN)" \
                    "$(nuopc_modelo "$2" ICE) $(nuopc_modelo "$2" BND)|$(nuopc_chaves_antigas "$2" | paste -sd" " -)"' \
           _ "${AJUDA}" "${arq}" 2>&1) || obtido="(parou: código $?) ${obtido}"
  [[ "${obtido}" == "${esperado}|${antigas}" ]] && ok=0 || ok=1
  resultado "modelos: ${nome}" "${ok}" "esperado '${esperado}|${antigas}', obtido '${obtido}'"
done <<< "${CASOS}"
usa=$(bash -c 'set -euo pipefail; source "$1"; echo "$(nuopc_usa "$2" OCN docn) $(nuopc_usa "$2" ICE sis2) $(nuopc_usa "$3" ICE sis2)"' \
      _ "${AJUDA}" "${C}/novas_docn.input" "${C}/nao_existe.input" 2>&1) || usa="(parou)"
[[ "${usa}" == ".true. .false. .true." ]] && ok=0 || ok=1
resultado "nuopc_usa" "${ok}" "obtido '${usa}'"

# 4. Troca de modelo
nuopc_troca_modelo "${C}/raiz.input" "${C}/troca_datm.input" ATM datm
nuopc_troca_modelo "${C}/antigas_producao.input" "${C}/troca_gelo.input" ICE none
nuopc_troca_modelo "${C}/vazio.input" "${C}/troca_vazio.input" ATM datm
obtido="$(nuopc_modelo "${C}/troca_datm.input" ATM) $(nuopc_modelo "${C}/troca_datm.input" OCN)"
obtido+=" $(nuopc_modelo "${C}/troca_gelo.input" ICE) $(nuopc_chaves_antigas "${C}/troca_gelo.input" | paste -sd' ' -)"
obtido+=" $(nuopc_modelo "${C}/troca_vazio.input" ATM)"
[[ "${obtido}" == "datm mom6 none use_datm use_docn use_med_to_mpas datm" ]] && ok=0 || ok=1
resultado "nuopc_troca_modelo" "${ok}" "obtido '${obtido}'"
linhas=$(( $(wc -l < "${C}/raiz.input") - $(wc -l < "${C}/troca_datm.input") ))
[[ ${linhas} -eq 0 ]] && ok=0 || ok=1
resultado "nuopc_troca_modelo troca uma linha por outra" "${ok}" "diferença de ${linhas} linha(s)"

# 5. Os mesmos modelos que config_read
if [[ -n "${TEST_CONFIG:-}" && -x "${TEST_CONFIG}" ]]; then
  for nome in raiz antigas_producao antigas_docn novas_docn novas_maiusculas mistas \
              troca_datm troca_gelo troca_vazio; do
    arq="${C}/${nome}.input"
    saida=$(cd "${C}" && env -u PALS_RANKID -u PMI_RANK -u PMIX_RANK -u OMPI_COMM_WORLD_RANK \
              "${TEST_CONFIG}" "${arq}" 2>&1 || true)
    if ! grep -q '^rc = [01]$' <<< "${saida}"; then
      resultado "config_read aceita: ${nome}" 1 "$(grep 'ERRO' <<< "${saida}" | head -1)"
      continue
    fi
    v() { grep "^$1 = " <<< "${saida}" | cut -d' ' -f3; }
    fortran="$( [[ $(v use_datm) == T ]] && echo datm || echo mpas) $( [[ $(v use_docn) == T ]] && echo docn || echo mom6)"
    fortran+=" $( [[ $(v use_sis2_dynamic) == T ]] && echo sis2 || echo none) $( [[ $(v use_med_to_mpas) == T ]] && echo med || echo ocn)"
    script="$(nuopc_modelo "${arq}" ATM) $(nuopc_modelo "${arq}" OCN) $(nuopc_modelo "${arq}" ICE) $(nuopc_modelo "${arq}" BND)"
    [[ "${fortran}" == "${script}" ]] && ok=0 || ok=1
    resultado "scripts e config_read: ${nome}" "${ok}" "config_read '${fortran}', scripts '${script}'"
  done
else
  echo "  (sem TEST_CONFIG: a comparação com config_read fica de fora)"
fi

if [[ ${nfalhas} -gt 0 ]]; then
  echo "FALHOU: ${nfalhas} conferência(s)"
  exit 1
fi
echo "OK: os scripts leem a escolha dos modelos como config_read"
