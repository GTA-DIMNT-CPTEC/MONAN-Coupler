#!/usr/bin/env bash
# =============================================================================
# compara-completar.bash: teste de regressão dos campos que o mediador
# completa por vizinhança depois da interpolação (a SST na malha de fluxo e
# a fração de gelo exportada ao oceano).
# INPE / CGCT / DIMNT, GT para Acoplamento de Modelos
#
# Compila a versão de um commit e a da árvore de trabalho, liga a cada uma o
# programa tests/completar/test_fill.F90 da árvore de trabalho (ele só
# usa interfaces que existem desde a fase11-12-validada; as fases de
# med_exchange que a versão tiver entram com -DCOM_ENTREGAR, -DCOM_IR_PARA
# e -DCOM_INICIO) e o
# executa com 1, 4, 6 e 8 processos MPI e, com 4, no caso "mista4" (máscara
# do oceano com terra desde o passo 1), com um supergrid sintético
# (tests/supergrid/gera-supergrid.py). Para cada PET, os valores gravados
# (saida_<PET>.bin: a SST na malha de fluxo e todos os campos exportados ao
# oceano, com os carimbos de tempo, em três passos, e as contagens de pontos
# completados) têm de ser idênticos, bit a bit; as linhas do relatório de
# acoplamento (CPL-REL:) no log do ESMF, sem data e hora, também, na mesma
# ordem; e as demais mensagens do mediador e do framework de interpolação,
# as mesmas, em qualquer ordem.
#
# Uso (na raiz do repositório):
#   ESMFMKFILE=/caminho/esmf.mk tests/completar/compara-completar.bash REV [SAIDA]
#     REV     commit de referência (ex.: HEAD, fase11-13-validada)
#     SAIDA   diretório de trabalho (padrão: build-local/completar)
#
# Variáveis: MPIRUN (padrão: mpiexec), FC (padrão: mpif90), LISTA_NP
# (padrão: "1 4 6 8").
# Ambiente: ESMF, NetCDF-Fortran (nf-config), MPI, python3 e ncgen; nenhuma
# biblioteca dos modelos (as interfaces mínimas de tests/interfaces bastam).
# Código de saída: 0 se tudo idêntico; 1 se algo difere; 2 erro de preparo.
# =============================================================================
set -uo pipefail

REV=${1:-}
[[ -n "${REV}" ]] || { sed -n '2,32p' "$0"; exit 2; }
RAIZ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAIDA=$(mkdir -p "${2:-${RAIZ}/build-local/completar}" && cd "${2:-${RAIZ}/build-local/completar}" && pwd)
MPIRUN=${MPIRUN:-mpiexec}
FC=${FC:-mpif90}
LISTA_NP=${LISTA_NP:-1 4 6 8}
# Casos: um por número de processos e, com 4 processos, o caso "mista4", em
# que a máscara do oceano já tem terra no passo 1 (todas as rotas do passo
# criadas no mesmo passo, para conferir a ordem entre elas).
CASOS="${LISTA_NP} mista4"
np_do_caso() { if [[ $1 == mista4 ]]; then echo 4; else echo "$1"; fi; }
arg_do_caso() { if [[ $1 == mista4 ]]; then echo mista; fi; }
[[ -n "${ESMFMKFILE:-}" && -f "${ESMFMKFILE}" ]] || { echo "ERRO: defina ESMFMKFILE" >&2; exit 2; }

mk() { grep "^$1=" "${ESMFMKFILE}" | cut -d= -f2-; }
EINC=$(mk ESMF_F90COMPILEPATHS)
ELIB="$(mk ESMF_F90LINKPATHS) $(mk ESMF_F90LINKRPATHS) $(mk ESMF_F90ESMFLINKLIBS)"
# Objetos de que um programa de teste depende, tirados dos 'use' da árvore
# dada (a de trabalho ou a cópia de REV): objetos RAIZ_DA_VERSAO PROGRAMA.F90
objetos() { python3 "${RAIZ}/tools/dev/dependencias.py" objetos -s "$1" -i "${RAIZ}/tests/interfaces" "$2"; }

python3 "${RAIZ}/tests/supergrid/gera-supergrid.py" "${SAIDA}/dados" > /dev/null \
  || { echo "ERRO: geração do supergrid sintético" >&2; exit 2; }

# Fontes da versão de referência, extraídos do git
rm -rf "${SAIDA}/fonte_antiga"; mkdir -p "${SAIDA}/fonte_antiga"
git -C "${RAIZ}" archive "${REV}" src Makefile tests/interfaces tools/dev/compila-local.bash \
  | tar -x -C "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: não foi possível extrair ${REV}" >&2; exit 2; }
# Com nomes trocados desde REV (fase 12), a cópia de REV recebe os nomes de
# hoje, para compilar com o programa de teste da árvore de trabalho
"${RAIZ}/tools/dev/renomeia-identificadores.py" traduz "${REV}" "${SAIDA}/fonte_antiga" \
  || { echo "ERRO: tradução dos nomes de ${REV}" >&2; exit 2; }

for versao in antiga nova; do
  if [[ ${versao} == antiga ]]; then src="${SAIDA}/fonte_antiga"; else src="${RAIZ}"; fi
  dir="${SAIDA}/${versao}"
  echo "--- versão ${versao}: compilando"
  bash "${RAIZ}/tools/dev/compila-local.bash" -s "${src}" -o "${dir}" > "${SAIDA}/compila_${versao}.txt" \
    || { cat "${SAIDA}/compila_${versao}.txt"; echo "ERRO: compilação da versão ${versao}" >&2; exit 2; }
  ( cd "${dir}" || exit 2
    # Fases de med_exchange presentes na versão: deliver (desde a
    # R-FASE11-15), go_to_flux_grid (desde a R-FASE11-16) e a fase A
    # da inicialização, prepare_start (desde a R-FASE11-17)
    defs=""; mx="${src}/src/mediator/med_exchange.F90"
    grep -qi 'subroutine deliver' "${mx}" 2>/dev/null && defs+=" -DCOM_ENTREGAR"
    grep -qi 'subroutine go_to_flux_grid' "${mx}" 2>/dev/null && defs+=" -DCOM_IR_PARA"
    grep -qi 'subroutine prepare_start' "${mx}" 2>/dev/null && defs+=" -DCOM_INICIO"
    # shellcheck disable=SC2086
    ${FC} ${EINC} -I. -cpp ${defs} -ffree-line-length-none -fallow-argument-mismatch \
      -O2 -ffp-contract=off -c "${RAIZ}/tests/completar/test_fill.F90" -o test_fill.o &&
    # shellcheck disable=SC2086
    ${FC} -o test_fill test_fill.o $(objetos "${src}" "${RAIZ}/tests/completar/test_fill.F90") ${ELIB} $(nf-config --flibs) -fopenmp
  ) > "${SAIDA}/liga_${versao}.txt" 2>&1 \
    || { cat "${SAIDA}/liga_${versao}.txt"; echo "ERRO: ligação da versão ${versao}" >&2; exit 2; }
  for caso in ${CASOS}; do
    np=$(np_do_caso "${caso}")
    run="${dir}/run_${caso}"
    rm -rf "${run}"; mkdir -p "${run}"; cp "${SAIDA}/dados/hgrid.nc" "${run}/"
    # shellcheck disable=SC2086
    ( cd "${run}" && ${MPIRUN} -n "${np}" ../test_fill $(arg_do_caso "${caso}") > run.log 2>&1 ) \
      || { tail -20 "${run}/run.log"; echo "ERRO: execução da versão ${versao}, caso ${caso}" >&2; exit 2; }
  done
done

difere=0
# Linhas de log retiradas de propósito (tests/log-retirado.txt) ficam fora
# da comparação com REV, que ainda as grava
retirado() { grep -vEf "${RAIZ}/tests/log-retirado.txt"; }
padrao='MED|CPL-REL|regrid|ERROR|WARNING'
for caso in ${CASOS}; do
  np=$(np_do_caso "${caso}")
  n=0
  for f in $(cd "${SAIDA}/antiga/run_${caso}" && ls saida_*.bin 2>/dev/null); do
    n=$((n + 1))
    if ! cmp -s "${SAIDA}/antiga/run_${caso}/${f}" "${SAIDA}/nova/run_${caso}/${f}"; then
      echo "  DIFERE         caso ${caso}: ${f}"; difere=1
    fi
  done
  [[ ${n} -eq ${np} ]] || { echo "ERRO: caso ${caso}: esperados ${np} arquivos, gravados ${n}" >&2; exit 2; }
  linhas=$(grep -h 'CPL-REL: completar' "${SAIDA}/nova/run_${caso}"/PET*.teste_completar | wc -l)
  rotas=$(grep -h 'CPL-REL: rota' "${SAIDA}/nova/run_${caso}"/PET0.teste_completar | wc -l)
  echo "  caso ${caso} (${np} PETs): ${n} arquivo(s) comparados, ${rotas} rota(s) e ${linhas} linha(s) 'completar' no relatório"
  for pet in "${SAIDA}/antiga/run_${caso}"/PET*.teste_completar; do
    nome=$(basename "${pet}")
    novo="${SAIDA}/nova/run_${caso}/${nome}"
    # Relatório de acoplamento: as mesmas linhas, na mesma ordem
    if ! diff -q <(grep 'CPL-REL:' "${pet}" | cut -d' ' -f3-) \
                 <(grep 'CPL-REL:' "${novo}" | cut -d' ' -f3-) > /dev/null; then
      echo "  relatório DIFERE caso ${caso}: ${nome}"; difere=1
    fi
    # Demais mensagens: as mesmas linhas, com as mesmas repetições, em
    # qualquer ordem (a R-FASE11-18 antecipou a criação de rotas dentro do
    # passo, e com ela algumas mensagens informativas)
    if ! diff -q <(grep -E "${padrao}" "${pet}" | retirado | cut -d' ' -f3- | sort) \
                 <(grep -E "${padrao}" "${novo}" | retirado | cut -d' ' -f3- | sort) > /dev/null; then
      echo "  log DIFERE     caso ${caso}: ${nome}"; difere=1
    fi
  done
done

if [[ ${difere} -eq 0 ]]; then echo "RESULTADO: campos completados idênticos"; else echo "RESULTADO: há diferenças"; fi
exit ${difere}
