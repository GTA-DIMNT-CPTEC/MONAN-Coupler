# Ferramentas do MONAN-Coupler: catálogo

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Este documento lista as ferramentas usadas para compilar, executar, dimensionar, verificar e testar a reprodutibilidade do sistema de acoplamento, com a pergunta que cada uma responde e o guia de uso. Estado em 24/09/2026.

## 1. Visão geral

| Etapa | Ferramentas | Pergunta |
| --- | --- | --- |
| ambiente e execução | `run/setenv-site.bash`, `run/setenv-gnu.bash`, `run/run_esmApp.jaci` | como compilar e submeter uma execução? |
| planejamento | `plan-layout.py`, `gen-metis.bash`, `domain-mom6.bash` | como distribuir PETs e nós, e o que cada componente precisa para essa distribuição? |
| desempenho | `analisa_balanceamento_pets.py`, `mede_smt.py` | quanto tempo cada componente gasta, e quem limita a velocidade? |
| funcionamento | `test-concurrent.bash`, `test-sequential-split.bash` | a configuração escolhida chega ao primeiro passo sem travar, e os componentes se sobrepõem? |
| reprodutibilidade | `mede-taxa-repro.sh`, `roda-repro-reprodiag.sh`, `roda_repro_producao.sh`, `roda_repro_datm_mom6.sh`, `roda-repro-mpas-standalone.sh`, `set-nccmp-jaci.bash` | duas execuções idênticas dão o mesmo resultado bit a bit? Se não, onde nasce a diferença? |
| regressão | `cria-linha-base.bash`, `compara-linha-base.bash` | uma alteração de código mudou o resultado? |
| pós-processamento | `tools/postproc/`, `tools/animation/` | como ficaram os campos trocados entre os componentes? |

## 2. Ambiente e execução

| Ferramenta | O que faz | Guia |
| --- | --- | --- |
| `run/setenv-site.bash` | único arquivo a editar ao trocar de usuário, máquina ou versões de módulo: caminho do ESMF, módulos, alvo de CPU, paralelismo | comentários do próprio arquivo |
| `run/setenv-gnu.bash` | ambiente de compilação com GNU; deve ser carregado com `source` | comentários do próprio arquivo |
| `run/run_esmApp.jaci` | confere pré-requisitos, gera o `.pbs` com a topologia de nós (um bloco por componente com `split`), submete e acompanha o job até o fim, com diagnóstico em caso de erro | `docs/MULTINO-run_esmApp.md` |

Três comportamentos do `run_esmApp.jaci` que afetam as outras ferramentas:

| Comportamento | Consequência |
| --- | --- |
| chamado do nó de login, espera o job terminar | os scripts de teste podem encadear execuções sem sobreposição |
| a saída do job vai para `logs/esmApp_run.log`, sobrescrito a cada job; os `logs/PET*.esmApp.log` são cumulativos | arquivar ou mover os logs entre execuções que serão comparadas |
| acima de 99 PETs, os logs de PET têm três algarismos (`PET000.esmApp.log`) | ferramentas que leem o log do PET 0 precisam do nome novo (no `mede-taxa-repro.sh`, `PET_LOG`) |

Quando um componente quebra, os outros esperam por ele e o job fica parado até o fim do tempo pedido, terminando com SIGTERM (exit 143). A dica automática de falta de memória que o script mostra nesse caso pode ser enganosa: procure o erro no `esmApp_run.log` e dê `qdel` no job.

## 3. Planejamento

| Ferramenta | O que faz | Guia |
| --- | --- | --- |
| `tools/coupler/plan-layout.py` | planeja a topologia multi-nó e o split de comunicador (PETs por componente, nós, limites de fila), antes de rodar | `docs/uso-plan-layout.md` |
| `tools/atmos/gen-metis.bash` | gera as partições METIS da malha do MPAS para o número de PETs da atmosfera | `docs/uso-gen-metis.md` |
| `tools/ocean/domain-mom6.bash` | calcula um `LAYOUT` equilibrado para o MOM6 e o SIS2 e gera a `mask_table` do FMS | `docs/domain-mom6.md` |

**O layout do gelo.** Desde a correção `B-ICE-DECOMP-01` (commit `a9e6935`, 24/09/2026), o cap do SIS2 constrói a grade ESMF do gelo a partir da decomposição que o próprio SIS2 escolheu, como o cap do oceano já fazia. Qualquer `ice_pet_count` e qualquer `LAYOUT` funcionam, inclusive o automático (`LAYOUT = 0, 0`), e a divisão do gelo não altera o resultado. O primeiro PET do gelo confirma no log: `ICE(SIS2): B-ICE-DECOMP-01 - grade ESMF segue a decomposicao do SIS2: <a> x <b> blocos`. Em binários anteriores a esse commit, o cap usava uma regra própria, que só coincidia com a do SIS2 em alguns casos (4 PETs, por exemplo); com outras contagens a inicialização quebrava com índice fora do intervalo em `sis_cap_MONAN.F90`, e o contorno era fixar o layout no `SIS_override` (com 8 PETs, `#override LAYOUT = 4, 2`).

## 4. Desempenho

| Ferramenta | O que faz | Guia |
| --- | --- | --- |
| `tools/coupler/analisa_balanceamento_pets.py` | lê os logs de uma execução concluída, mede o tempo de cada componente, mostra quanto cada um fica parado esperando o mais lento, e sugere uma divisão de PETs, com avaliação de viabilidade e ajuste prático (v14.22) | `docs/uso-analisa-balanceamento.md` |
| `tools/coupler/mede_smt.py` | comparação controlada do efeito do SMT (dois fios por núcleo) no sistema acoplado | `docs/uso-mede-smt.md`, `docs/SMT-Jaci.md` |

Referência medida em 23 e 24/09/2026 (concorrente, icebergs ligados, 24 horas simuladas; atmosfera + oceano + gelo):

| Configuração | Total | Duração do job | Gargalo |
| --- | --- | --- | --- |
| 64 + 4 + 4 | 72 | 366 s | |
| 128 + 8 + 8 | 144 | 234 s | oceano, 201 s (atmosfera 97 s) |
| 128 + 12 + 4 | 144 | 200 s | oceano, 162 s |
| 128 + 20 + 4 | 152 | 158 s | oceano, 117 s (atmosfera 93 s) |

Nesta grade, o oceano é o componente que limita a velocidade, e o gelo precisa de poucos PETs (4 bastam). Detalhes em `docs/uso-analisa-balanceamento.md`, seção 9.

## 5. Funcionamento

| Ferramenta | O que faz | Guia |
| --- | --- | --- |
| `tools/coupler/test-concurrent.bash` | smoke test do modo concorrente: a configuração chega ao primeiro passo sem travar? | `docs/uso-smoke-tests.md` |
| `tools/coupler/test-sequential-split.bash` | smoke test da combinação sequencial com split; mede a sobreposição real das janelas de execução dos componentes | `docs/uso-smoke-tests.md`, `docs/analise-sequential-split-sis2.md` |

## 6. Reprodutibilidade

| Ferramenta | O que faz | Guia |
| --- | --- | --- |
| `tools/coupler/mede-taxa-repro.sh` | bateria de N execuções com comparação de todos os pares; relatório com o estado da atmosfera, balanços, checksums do gelo, checksum exato do `Si_ifrac` por PET, importações e saídas do oceano | `docs/uso-mede-taxa-repro.md` |
| `tools/coupler/roda-repro-reprodiag.sh` | dupla rodada; primeiro passo de tempo em que o estado do MPAS diverge | `docs/uso-duplas-rodadas-repro.md` |
| `tools/coupler/roda_repro_producao.sh` | dupla rodada do caso de produção, em todas as saídas, usando a maquinaria de linha de base | `docs/uso-duplas-rodadas-repro.md` |
| `tools/coupler/roda_repro_datm_mom6.sh` | dupla rodada com atmosfera de dados no lugar do MPAS, para separar a origem entre atmosfera e oceano/gelo | `docs/uso-duplas-rodadas-repro.md` |
| `tools/atmos/roda-repro-mpas-standalone.sh` | dupla rodada do MPAS autônomo, fora do acoplador | `docs/uso-duplas-rodadas-repro.md` |
| `tools/dev/set-nccmp-jaci.bash` | carrega os módulos do `nccmp` na jaci (com `source`); começa com `module purge`, que descarrega também o Python usado pelas ferramentas `.py` | `docs/uso-duplas-rodadas-repro.md`, seção 2 |

**Instrumentos no código e na configuração**, usados por essas ferramentas:

| Instrumento | Onde | Para que serve |
| --- | --- | --- |
| stream `reprodiag` | bloco no `streams.atmosphere` | estado do MPAS a cada 10 minutos simulados em `reprodiag.nc`; retirar em produção |
| `FIX-DIAG-BITSUM-01` | `src/mediator/MED_cap.F90`, atrás de `cfg_write_fixdiag` | checksum exato (soma inteira dos bits) do `Si_ifrac` em quatro etapas do mediador, gravado por PET; foi o instrumento que localizou a causa da não reprodutibilidade |
| `FIX-DIAG-ICESRC-01/-02`, `FIX-DIAG-ICEMASK-01/-02` | `src/mediator/MED_cap.F90` | valores do `Si_ifrac` e da máscara no PET 0, com 17 e 4 algarismos |
| `DEBUG_CHKSUMS`, `DEBUG_SLOW_ICE`, `DEBUG_FAST_ICE` | `SIS_override` | checksums internos do SIS2 no `esmApp_run.log`; desligar em produção |
| linha `B-CPL-TERMORDER-01` / `B-SRCTERM-01` no log do PET 0 | `src/driver/esm.F90` | confirma, a cada execução, que as 60 ligações entre componentes receberam as opções de reprodutibilidade (`sem espaco: 0`) |

**A regra que tornou o acoplador reprodutível.** Todo remapeamento precisa fixar as duas camadas de ordem de soma do ESMF: `srcTermProcessing = 0` na criação (`ESMF_FieldRegridStore`, com uma variável, porque o argumento é `intent(inout)`) e `termorderflag = ESMF_TERMORDER_SRCSEQ` na execução (`ESMF_FieldRegrid`); nas ligações entre componentes, `:termorder=srcseq:srcTermProcessing=0` em cada entrada de `CplList`. Qualquer remapeamento novo deve nascer assim, senão a reprodutibilidade pode voltar a se perder, e de forma intermitente.

## 7. Regressão

| Ferramenta | O que faz | Guia |
| --- | --- | --- |
| `tools/dev/cria-linha-base.bash` | congela uma execução de referência: saídas, configuração, código e ambiente | `docs/uso-linha-base.md` |
| `tools/dev/compara-linha-base.bash` | compara a execução atual com uma linha de base, com `nccmp -d` | `docs/uso-linha-base.md` |

A linha de base responde se uma alteração de código mudou o resultado; a bateria do `mede-taxa-repro.sh` responde se a configuração é reprodutível. São perguntas diferentes: uma alteração pode ser reprodutível e ainda assim mudar o resultado.

## 8. Pós-processamento e animação

| Ferramenta | O que faz |
| --- | --- |
| `tools/postproc/postproc_monan2_export.py` | pós-processamento dos campos exportados pelo cap do MPAS |
| `tools/postproc/postproc_monan2_import.py` | diagnóstico dos campos importados pelo MPAS (`So_t`, `Si_ifrac`, `Sf_zorl`) |
| `tools/postproc/postproc_mom6_import.py` | validação dos fluxos que o MOM6 e o SIS2 recebem do mediador |
| `tools/postproc/postproc_monan2_standalone.py` | pós-processamento do MPAS autônomo (`MONAN_DIAG_*.nc`) |
| `tools/postproc/analisa_comparacao.py` | resumo estatístico por campo da comparação entre MPAS autônomo e acoplado |
| `tools/postproc/analisa_sst_ifrac.py` | evolução temporal da SST e da fração de gelo |
| `tools/animation/anim_mom6_import.py`, `anim_monan2_import.py`, `anima_sst_ifrac.py` | animações a partir das figuras dos scripts de pós-processamento |

Os comandos sugeridos ao fim de cada job pelo `run_esmApp.jaci` usam estes scripts. O uso detalhado está no cabeçalho de cada um (`python3 <script> --help`).

## 9. Ferramentas fora do repositório

| Ferramenta | Situação |
| --- | --- |
| `coleta-contexto-jaci.sh` | usada no diretório de experimento para empacotar configurações, `*_parameter_doc`, saídas e baterias `repro-*` num `contexto-jaci-<data-hora>.tar.gz`, que registra o estado de um experimento para continuidade. Ainda não está no repositório; vale incorporá-la a `tools/dev/` |
| `stream-reprodiag.xml` | citado pelo `roda-repro-reprodiag.sh` como fonte do bloco do stream; não está no repositório. O bloco está transcrito em `docs/uso-mede-taxa-repro.md`, seção 2.1 |

## 10. Sequências típicas

**Uma configuração nova de PETs.**

1. `plan-layout.py`, para a topologia.
2. `gen-metis.bash`, para a partição da atmosfera.
3. Uma execução com `run_esmApp.jaci`, e `analisa_balanceamento_pets.py` sobre os logs dela.
4. Se o balanço pedir, ajustar as contagens e repetir o passo 3. Redistribuir PETs entre oceano e gelo, mantendo a atmosfera e o total, não altera o resultado; mudar a atmosfera ou o total altera. Por isso, escolha primeiro o total final pelo desempenho.
5. `mede-taxa-repro.sh` com 4 execuções e, se sair limpo, com 8, para confirmar a reprodutibilidade da configuração final. Redistribuições posteriores entre oceano e gelo, com o mesmo total e a mesma atmosfera, herdam essa validação.

**Uma alteração de código que não deveria mudar o resultado.**

1. Antes da alteração, `cria-linha-base.bash`.
2. Depois, uma execução e `compara-linha-base.bash`.

**Uma alteração que deveria mudar o resultado (correção física, novo campo).**

1. `mede-taxa-repro.sh` com a alteração, para confirmar que continua reprodutível.
2. `cria-linha-base.bash` com rótulo novo, para servir de referência às próximas alterações.

**Uma perda de reprodutibilidade.**

1. `mede-taxa-repro.sh`, para medir a taxa e classificar as execuções.
2. Com os instrumentos ligados (checksums do SIS2, `FIX-DIAG-BITSUM-01`), a primeira troca e a primeira etapa em que as execuções diferem.
3. As duplas rodadas para isolar a origem: `roda-repro-mpas-standalone.sh` (a atmosfera sozinha), `roda_repro_datm_mom6.sh` (sem a atmosfera).
4. Investigar no modo sequencial reprodutível (`seq_repro = .true.`), que é equivalente ao concorrente bit a bit e deixa causa e efeito em ordem.
