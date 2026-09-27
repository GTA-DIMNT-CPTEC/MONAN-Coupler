# Conferências locais antes de uma rodada na Jaci

Uma etapa de refatoração só é aprovada pela rodada completa na Jaci, comparada bit a bit com a linha de base (ver [`validacao-refatoracao.md`](validacao-refatoracao.md)). Cada rodada, porém, custa uma compilação e uma fila. Este guia descreve o que pode ser conferido antes, fora da Jaci, numa máquina com ESMF, NetCDF-Fortran e MPI instalados, sem as bibliotecas do MPAS, do MOM6 e do FMS. Essas conferências pegam a maior parte dos erros de compilação e de refatoração, mas não substituem a rodada.

## 1. O que é preciso

| Item | Observação |
| --- | --- |
| gfortran e MPI (MPICH ou Open MPI) | com `mpif90` no PATH; outro compilador pela variável `FC` |
| NetCDF-Fortran | com `nf-config` no PATH |
| ESMF 8.9.1 compilado | a variável `ESMFMKFILE` aponta para o `esmf.mk` da instalação |
| Python 3 e git | para os scripts de conferência |

Nenhuma biblioteca dos modelos é necessária. Os fontes que dependem delas são compilados contra as interfaces mínimas de `tests/interfaces/` (seção 3).

## 2. As ferramentas

| Ferramenta | Pergunta que responde |
| --- | --- |
| `tools/dev/compila-local.bash` | o código compila, com as opções de aviso e de ponto flutuante do Makefile? |
| `tools/dev/confere-literais.py REV` | alguma mensagem de log, nome de campo, atributo ou formato mudou desde o commit `REV`? |
| `tools/dev/confere-instrucoes.py REV arquivo` | numa etapa que só move código, alguma instrução foi alterada? |
| `tests/writers/compara-gravadores.bash REV` | os gravadores de diagnóstico gravam os mesmos arquivos que no commit `REV`? |
| `tests/bulk/compara-bulk.bash REV` | a física bulk do mediador calcula os mesmos valores, bit a bit, que no commit `REV`? |

### 2.1 Compilação

```bash
export ESMFMKFILE=/caminho/para/esmf.mk
tools/dev/compila-local.bash
```

Compila os fontes na ordem do Makefile, em `build-local/`, e mostra uma linha por fonte com o resultado e o número de avisos. Ficam de fora o `sis_cap_MONAN.F90` (ainda sem interfaces mínimas do SIS2), o driver e o programa principal. O log de cada fonte fica em `build-local/<fonte>.log`.

Para saber se uma mudança criou avisos, compile também a versão anterior (extraída com `git archive`, por exemplo) em outro diretório, com `-s` e `-o`, e compare.

### 2.2 Constantes de texto

```bash
tools/dev/confere-literais.py HEAD
```

Compara os literais de texto (fora dos comentários) de cada fonte alterado desde `HEAD` com os da árvore de trabalho. Mensagens de log são lidas por ferramentas de `tools/` e comparadas entre rodadas, e nomes de campos e atributos acabam nos arquivos NetCDF: numa refatoração, não devem mudar. Toda diferença tem de ser explicada, e as esperadas (por exemplo, o formato de uma variável morta que foi removida) são anunciadas no CHANGELOG. Sai com código 1 se houver diferença.

### 2.3 Instruções

```bash
tools/dev/confere-instrucoes.py HEAD src/mediator/MED_cap.F90
```

Junta as linhas de continuação, retira comentários, espaços e diferença de maiúsculas, e compara o conjunto de instruções do arquivo no commit e na árvore de trabalho. Numa etapa que divide uma rotina em procedimentos, as únicas instruções acrescentadas devem ser as chamadas, as declarações, os cabeçalhos e os retornos das etapas novas; as removidas devem ser só as que viraram chamada e o código morto anunciado. A comparação ignora a ordem: a ordem das operações, em especial das coletivas do MPI, que precisam acontecer na mesma sequência em todos os processos, é conferida lendo o diff.

É a principal conferência dos fontes que só compilam de verdade na Jaci, como `mpas_atm_model.F90` e `mom_cap_MONAN.F90`.

### 2.4 Teste dos gravadores de diagnóstico

```bash
tests/writers/compara-gravadores.bash HEAD
```

Compila a versão do commit e a da árvore de trabalho, liga a cada uma o programa `tests/writers/test_writers.F90` e o executa com 4 processos MPI e dados sintéticos. O programa chama `med_write_import_fields` (mediador) e `write_mpas_import_diag` (cap atmosférico) duas vezes cada, com valores inválidos, máscara de terra e, na segunda chamada, membros de `atm_bnd` ausentes. O script compara byte a byte os arquivos NetCDF gravados e compara as mensagens dos gravadores no log do ESMF. Sai com código 0 se tudo for idêntico. Com a mudança ainda não gravada, compare com `HEAD`; depois do commit, com `HEAD~1`.

O lançador do MPI pode ser trocado pela variável `MPIRUN` (padrão: `mpiexec`). O número de processos (`NP`, padrão 4) tem de ser par, porque a grade do teste é dividida em 2 x NP/2 blocos.

### 2.5 Teste da física bulk do mediador

```bash
tests/bulk/compara-bulk.bash HEAD
```

Funciona como o teste dos gravadores. O programa `tests/bulk/test_bulk_ncar.F90` cria, na grade ATM 360 x 180, todos os campos do estado interno do mediador que `calc_bulk_ncar` lê ou escreve, preenche as entradas com dados sintéticos e chama `calc_bulk_ncar` três vezes, em instantes diferentes. Depois de cada chamada, grava todos esses campos. O script compara os arquivos das duas versões byte a byte e compara as mensagens da física bulk no log do ESMF.

Os dados cobrem os casos que mudam o caminho do cálculo: vento nulo, ar mais quente e mais frio que a superfície (os dois ramos do fator de estabilidade), temperatura do gelo fora da faixa física, fração de gelo abaixo do limiar dos fluxos sobre o gelo, máscara de terra e forçantes ausentes. Como compara bit a bit, o teste confirma que mudar código de lugar, por exemplo para uma função, não alterou nenhuma operação de ponto flutuante. O teste foi conferido ao contrário também: alterar um parâmetro do fator de estabilidade faz o resultado diferir.

Ficam de fora o caminho do DOCN e o caminho com `cfg_use_sis2_dynamic = .true.`, porque o teste usa os valores padrão da configuração. Com o padrão, `calc_bulk_ncar` também calcula a fração de gelo pelo limiar de SST (`legacy_ice_fraction`), que fica coberta.

## 3. Interfaces mínimas

Os arquivos `tests/interfaces/mpas_stubs.F90` e `tests/interfaces/mom_stubs.F90` declaram os módulos, tipos e rotinas do MPAS, do MOM6 e do FMS que o acoplador usa, só com as assinaturas e sem nenhum cálculo. Com eles, `mpas_atm_types.F90`, `mpas_atm_model.F90`, `time_utils.F90` e `mom_cap_MONAN.F90` compilam fora da Jaci, e o compilador confere tipos, argumentos e `intent`.

Uma interface mínima pode estar errada; por isso, antes de confiar nela para uma mudança, compile com ela a versão anterior do arquivo. Se a versão anterior não compilar, a interface é que precisa de ajuste, seguindo a assinatura real no código do modelo. Um erro de compilação só é atribuído à mudança se a versão anterior compilar com as mesmas interfaces.

## 4. Ordem sugerida antes de entregar uma etapa

1. `tools/dev/compila-local.bash`: nenhum fonte com falha e nenhum aviso novo.
2. `tools/dev/confere-literais.py HEAD`: nenhuma diferença, ou só as anunciadas.
3. Em etapas que só movem código: `tools/dev/confere-instrucoes.py HEAD <arquivo>` em cada arquivo alterado.
4. Se a etapa mexe em `med_cap_netcdf.F90` ou `mpas_cap_netcdf.F90`: `tests/writers/compara-gravadores.bash HEAD`.
5. Se a etapa mexe em `med_bulk_ncar.F90`: `tests/bulk/compara-bulk.bash HEAD`.
6. Rodada na Jaci com `tools/dev/valida_rodada.bash`.
