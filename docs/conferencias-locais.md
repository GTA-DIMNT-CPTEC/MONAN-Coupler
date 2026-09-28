# Conferências locais antes de uma rodada na Jaci

Uma etapa de refatoração só é aprovada pela rodada completa na Jaci, comparada bit a bit com a linha de base (ver [`validacao-refatoracao.md`](validacao-refatoracao.md)). Cada rodada, porém, custa uma compilação e uma fila. Este guia descreve o que pode ser conferido antes, fora da Jaci, numa máquina com ESMF, NetCDF-Fortran e MPI instalados, sem as bibliotecas do MPAS, do MOM6 e do FMS. Essas conferências pegam a maior parte dos erros de compilação e de refatoração, mas não substituem a rodada.

## 1. O que é preciso

| Item | Observação |
| --- | --- |
| gfortran e MPI (MPICH ou Open MPI) | com `mpif90` no PATH; outro compilador pela variável `FC` |
| NetCDF-Fortran | com `nf-config` no PATH |
| ESMF 8.9.1 compilado | a variável `ESMFMKFILE` aponta para o `esmf.mk` da instalação |
| Python 3.6 ou mais novo, e git | para os scripts de conferência; os de `tools/dev/` rodam também com o `python3` do sistema na Jaci (3.6) |

Nenhuma biblioteca dos modelos é necessária. Os fontes que dependem delas são compilados contra as interfaces mínimas de `tests/interfaces/` (seção 3).

## 2. As ferramentas

| Ferramenta | Pergunta que responde |
| --- | --- |
| `tools/dev/confere-tudo.bash [REV]` | todas as conferências abaixo, de uma vez: alguma falhou? |
| `tools/dev/indicadores.py [REV ...]` | como estão os indicadores de código limpo (tamanho de arquivos e rotinas, estado de módulo, trechos repetidos)? |
| `tools/dev/compila-local.bash` | o código compila, com as opções de aviso e de ponto flutuante do Makefile? |
| `tools/dev/confere-literais.py REV` | alguma mensagem de log, nome de campo, atributo ou formato mudou desde o commit `REV`? |
| `tools/dev/confere-instrucoes.py REV arquivo` | numa etapa que só move código, alguma instrução foi alterada? |
| `tests/writers/compara-gravadores.bash REV` | os gravadores de diagnóstico gravam os mesmos arquivos que no commit `REV`? |
| `tests/bulk/compara-bulk.bash REV` | a física bulk do mediador calcula os mesmos valores, bit a bit, que no commit `REV`? |
| `tests/unit/roda-unitarios.bash` | as fórmulas do acoplador calculam o valor que a fórmula publicada dá? |
| `tests/atmgrid/compara-grade-atm.bash REV` | o cap atmosférico leva as células MPAS à grade regular 360 x 180 com os mesmos valores, bit a bit, que no commit `REV`? |

### 2.0 Todas as conferências de uma vez

```bash
export ESMFMKFILE=/caminho/para/esmf.mk
tools/dev/confere-tudo.bash HEAD
```

Executa, em sequência, as conferências das seções 2.1 a 2.6 e o teste do framework de interpolação (`tests/regrid`), e termina com um resumo e a tabela de indicadores (seção 2.7). Cada conferência tem o seu log em `build-local/confere/logs/`. A saída se parece com esta:

```
Resumo (referência: HEAD)
  compilacao   OK                              35 s
  avisos       OK                              33 s
  literais     OK                               0 s
  regrid       OK                              27 s
  gravadores   OK                              86 s
  bulk         OK                              82 s
  grade        OK                              83 s
  unitarios    OK                              31 s
```

O que cada linha confere:

| Conferência | Falha quando |
| --- | --- |
| `compilacao` | algum fonte não compila (seção 2.1) |
| `avisos` | algum fonte tem mais avisos do que na versão `REV`, compilada com as mesmas interfaces mínimas |
| `literais` | alguma constante de texto mudou (seção 2.2) |
| `instrucoes` | só com a opção `-i`: algum `.F90` alterado tem instrução diferente de `REV` (seção 2.3); use em etapas que só mudam comentários ou espaços |
| `regrid` | os testes de `tests/regrid` não imprimem `TODOS OS TESTES PASSARAM` |
| `gravadores`, `bulk`, `grade` | os testes de regressão das seções 2.4 a 2.6 acusam diferença |
| `unitarios` | algum teste com valor esperado (seção 2.8) falha |

A opção `-t` escolhe só algumas conferências (`-t compilacao,literais,bulk`), e `-o` troca o diretório de trabalho. As variáveis `MPIRUN`, `NP` e `FC` são repassadas aos testes. O comando leva cerca de seis minutos numa máquina de 4 núcleos e sai com código 0 se nenhuma conferência falhou. Depois do commit da etapa, a referência passa a ser `HEAD~1`.

Foi conferido ao contrário: uma variável sem uso acrescentada a `nc_writer.F90` faz falhar `avisos` e, com `-i`, `instrucoes`.

### 2.1 Compilação

```bash
export ESMFMKFILE=/caminho/para/esmf.mk
tools/dev/compila-local.bash
```

Compila os fontes na ordem do Makefile, em `build-local/`, e mostra uma linha por fonte com o resultado e o número de avisos. Ficam de fora o driver e o programa principal. O log de cada fonte fica em `build-local/<fonte>.log`.

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

Compila a versão do commit e a da árvore de trabalho, liga a cada uma o programa `tests/writers/test_writers.F90` e o executa com 4 processos MPI e dados sintéticos. O programa chama `med_write_import_fields` (mediador) e `write_mpas_import_diag` (cap atmosférico) duas vezes cada, com valores inválidos, máscara de terra e, na segunda chamada, membros de `atm_bnd` ausentes. Chama também `WriteDOCNDiag` (oceano de dados) três vezes, cada uma com um arquivo `&nuopc_docn` lido por `config_read` e com arquivos NetCDF de SST, gelo e correntes que o próprio programa grava numa grade 36 x 18: sem correntes e com o gelo em fração; com correntes, gelo em porcentagem e nomes diferentes para a dimensão de tempo; e com o arquivo de SST ausente, que só gera um aviso no log. Esse teste é a única verificação do `WriteDOCNDiag`, porque a rodada da linha de base não usa o DOCN. O script compara byte a byte os arquivos NetCDF gravados e compara as mensagens dos gravadores no log do ESMF. Sai com código 0 se tudo for idêntico. Com a mudança ainda não gravada, compare com `HEAD`; depois do commit, com `HEAD~1`.

O lançador do MPI pode ser trocado pela variável `MPIRUN` (padrão: `mpiexec`). O número de processos (`NP`, padrão 4) tem de ser par, porque a grade do teste é dividida em 2 x NP/2 blocos.

### 2.5 Teste da física bulk do mediador

```bash
tests/bulk/compara-bulk.bash HEAD
```

Funciona como o teste dos gravadores. O programa `tests/bulk/test_bulk_ncar.F90` cria, na grade ATM 360 x 180, todos os campos do estado interno do mediador que `calc_bulk_ncar` lê ou escreve, preenche as entradas com dados sintéticos e chama `calc_bulk_ncar` três vezes, em instantes diferentes. Depois de cada chamada, grava todos esses campos. O script compara os arquivos das duas versões byte a byte e compara as mensagens da física bulk no log do ESMF.

Os dados cobrem os casos que mudam o caminho do cálculo: vento nulo, ar mais quente e mais frio que a superfície (os dois ramos do fator de estabilidade), temperatura do gelo fora da faixa física, fração de gelo abaixo do limiar dos fluxos sobre o gelo, máscara de terra e forçantes ausentes. Como compara bit a bit, o teste confirma que mudar código de lugar, por exemplo para uma função, não alterou nenhuma operação de ponto flutuante. O teste foi conferido ao contrário também: alterar um parâmetro do fator de estabilidade faz o resultado diferir.

Ficam de fora o caminho do DOCN e o caminho com `cfg_use_sis2_dynamic = .true.`, porque o teste usa os valores padrão da configuração. Com o padrão, `calc_bulk_ncar` também calcula a fração de gelo pelo limiar de SST (`legacy_ice_fraction`), que fica coberta.

### 2.6 Teste da grade do cap atmosférico

```bash
tests/atmgrid/compara-grade-atm.bash HEAD
```

Funciona como os dois anteriores. O programa `tests/atmgrid/test_mpas_export.F90` cria a grade 360 x 180 do cap atmosférico (`mpas_create_grid`) e três campos de exportação, monta em cada processo células MPAS sintéticas e chama `mpas_export` duas vezes. Cada chamada passa por `state_set_field_1d` e `map_cells_to_regular_grid`: soma e contagem por caixa de 1 grau, soma entre processos em ordem de rank, média, preenchimento das caixas vazias e cópia para a porção local da grade. Os campos são reunidos no processo 0 e gravados; o script compara os arquivos byte a byte, a linha `MPAS-DIAG` da saída padrão e as mensagens do log do ESMF (entre elas a marca `BUG-SPARSE-02`, com o número de caixas vazias antes e depois do preenchimento).

As células seguem uma sequência quase aleatória (razão áurea) própria de cada processo, em faixas de longitude que se sobrepõem: há caixas com células de até três processos, e a ordem da soma entre eles muda o último bit. O teste foi conferido ao contrário: inverter a ordem da soma entre processos ou a ordem das linhas no preenchimento faz o resultado diferir.

### 2.7 Indicadores de código limpo

```bash
tools/dev/indicadores.py fase5-07-validada .
tools/dev/indicadores.py -l .
```

Mede, nos fontes próprios de `src/` (sem `upstream/`), os indicadores do roteiro de código limpo (`docs/roteiro-codigo-limpo.md`): arquivos com mais de 1 000 linhas, rotinas com mais de 100 e de 150 linhas de código, variáveis de módulo (públicas, protegidas e privadas), variáveis locais que conservam o valor entre chamadas (`save` explícito, ou implícito por valor na declaração), trechos de 6 linhas repetidos e comentários com marcas de histórico. Cada versão pedida vira uma coluna (`.` é a árvore de trabalho); com `-l`, lista os itens da última versão. A tabela sai em Markdown, pronta para o CHANGELOG. Os indicadores acompanham a evolução do código; não decidem se uma etapa está certa.

### 2.8 Testes com valor esperado

```bash
tests/unit/roda-unitarios.bash
```

Os testes de regressão das seções 2.4 a 2.6 comparam duas versões do código e respondem se o resultado mudou; não dizem se o resultado está certo. Os testes de `tests/unit/` respondem a essa outra pergunta: comparam o resultado de rotinas do acoplador com valores esperados calculados à parte, diretamente da fórmula publicada, em precisão de 40 algarismos (biblioteca mpmath do Python), com tolerância relativa de 1e-12. A tolerância existe porque a ordem das operações no código não é a do cálculo de referência; um erro de fórmula (sinal, constante, ramo, limite) muda o resultado muito além dela.

O script compila a árvore de trabalho, liga cada programa `tests/unit/test_*.F90` e o executa; cada programa imprime PASSOU ou FALHOU por caso. O primeiro, `test_formulas_bulk.F90`, cobre três fórmulas da física bulk do mediador (`med_bulk_ncar`):

| Rotina | O que calcula | Casos |
| --- | --- | --- |
| `ice_temp_eff` | temperatura do gelo usada nos fluxos: `Si_t_sis2` na faixa (180 K; 273,16 K], senão 271,35 K | dentro, nos dois limites e fora da faixa |
| `louis_stability` | número de Richardson bulk e fator de estabilidade de Louis (1979) | estável, neutro, instável, e os dois casos extremos que batem no piso (0,05) e no teto (3) |
| `ocean_direct_albedo` | cosseno do zênite na célula da grade ATM e albedo da água para feixe direto (Briegleb et al., 1986) | sol a pino, noite, sol a 60° e a 78° de latitude, declinação diferente de zero; inclui os casos que batem no piso de 0,03 |

O teste foi conferido ao contrário, com cinco alterações de propósito no código, uma de cada vez: trocar `<=` por `<` no limite de 273,16 K, trocar um coeficiente do fator de Louis, trocar o expoente 1,7 do albedo, mudar o teto do fator e inverter o sinal da longitude no ângulo horário. Todas fizeram o teste falhar.

Para acrescentar um teste: escrever `tests/unit/test_<assunto>.F90` no mesmo formato (valores esperados calculados à parte e registrados no comentário do programa) e, se ele usar outros módulos, incluir os objetos na lista `OBJS` do script.

## 3. Interfaces mínimas

Os arquivos `tests/interfaces/mpas_stubs.F90`, `tests/interfaces/mom_stubs.F90` e `tests/interfaces/sis_stubs.F90` declaram os módulos, tipos e rotinas do MPAS, do MOM6, do FMS e do SIS2 que o acoplador usa, só com as assinaturas e sem nenhum cálculo. Com eles, `mpas_atm_types.F90`, `mpas_atm_model.F90`, `time_utils.F90`, `mom_cap_MONAN.F90` e `sis_cap_MONAN.F90` compilam fora da Jaci, e o compilador confere tipos, argumentos e `intent`.

Uma interface mínima pode estar errada; por isso, antes de confiar nela para uma mudança, compile com ela a versão anterior do arquivo. Se a versão anterior não compilar, a interface é que precisa de ajuste, seguindo a assinatura real no código do modelo. Um erro de compilação só é atribuído à mudança se a versão anterior compilar com as mesmas interfaces.

## 4. Ordem sugerida antes de entregar uma etapa

1. `tools/dev/confere-tudo.bash HEAD` (com `-i` se a etapa só muda comentários ou espaços): resumo sem nenhuma conferência FALHOU; diferenças de literais só as anunciadas.
2. Em etapas que só movem código: ler a saída de `tools/dev/confere-instrucoes.py HEAD <arquivo>` em cada arquivo alterado. As instruções acrescentadas devem ser só chamadas, declarações e cabeçalhos das etapas novas; essa leitura não se automatiza.
3. Copiar para o CHANGELOG as linhas dos indicadores que mudaram.
4. Rodada na Jaci com `tools/dev/valida_rodada.bash`.
