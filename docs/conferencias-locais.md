# Conferências locais antes de uma rodada na Jaci

Uma etapa de refatoração só é aprovada pela rodada completa na Jaci, comparada bit a bit com a linha de base (ver [`validacao-refatoracao.md`](validacao-refatoracao.md)). Cada rodada, porém, custa uma compilação e uma fila. Este guia descreve o que pode ser conferido antes, fora da Jaci, numa máquina com ESMF, NetCDF-Fortran e MPI instalados, sem as bibliotecas do MPAS, do MOM6 e do FMS. Essas conferências pegam a maior parte dos erros de compilação e de refatoração, mas não substituem a rodada.

## 1. O que é preciso

| Item | Observação |
| --- | --- |
| gfortran e MPI (MPICH ou Open MPI) | com `mpif90` no PATH; outro compilador pela variável `FC` |
| NetCDF-Fortran | com `nf-config` no PATH |
| ESMF 8.9.1 compilado | a variável `ESMFMKFILE` aponta para o `esmf.mk` da instalação |
| Python 3.6 ou mais novo, e git | para os scripts de conferência; os de `tools/dev/` rodam também com o `python3` do sistema na Jaci (3.6) |
| `ncgen` (pacote netcdf-bin) | para os dados sintéticos dos testes do supergrid e do DOCN |

Nenhuma biblioteca dos modelos é necessária. Os fontes que dependem delas são compilados contra as interfaces mínimas de `tests/interfaces/` (seção 3).

## 2. As ferramentas

| Ferramenta | Pergunta que responde |
| --- | --- |
| `tools/dev/confere-tudo.bash [REV]` | todas as conferências abaixo, de uma vez: alguma falhou? |
| `tools/dev/indicadores.py [REV ...]` | como estão os indicadores de código limpo (tamanho de arquivos e rotinas, estado de módulo, trechos repetidos)? |
| `tools/dev/compila-local.bash` | o código compila, com as opções de aviso e de ponto flutuante do Makefile? |
| `tools/dev/confere-literais.py REV` | alguma mensagem de log, nome de campo, atributo ou formato mudou desde o commit `REV`? |
| `tools/dev/confere-instrucoes.py REV arquivo [...]` | numa etapa que só move código, alguma instrução foi alterada? |
| `tests/writers/compara-gravadores.bash REV` | os gravadores de diagnóstico gravam os mesmos arquivos que no commit `REV`? |
| `tests/bulk/compara-bulk.bash REV` | a física bulk do mediador calcula os mesmos valores, bit a bit, que no commit `REV`? |
| `tests/unit/roda-unitarios.bash` | as fórmulas do acoplador calculam o valor que a fórmula publicada dá? |
| `tests/atmgrid/compara-grade-atm.bash REV` | o cap atmosférico leva as células MPAS à grade regular 360 x 180 com os mesmos valores, bit a bit, que no commit `REV`? |
| `tests/malhas/compara-malhas.bash REV` | as malhas do mediador (fluxo e oceano, com o MOM6 e com o DOCN), a grade do cap atmosférico e a malha do SIS2 têm a mesma decomposição e as mesmas coordenadas, bit a bit, que no commit `REV` (a do SIS2, que a construção de antes), com vários números de processos? |
| `tests/supergrid/compara-supergrid.bash REV` | a leitura do supergrid do MOM6 (`ocean_hgrid.nc`) dá as mesmas dimensões, coordenadas e mensagens que no commit `REV`? |
| `tests/docn/compara-docn.bash REV` | o oceano de dados (DOCN) exporta os mesmos campos, com os mesmos carimbos de tempo, diagnósticos e mensagens, que no commit `REV`? |
| `tools/dev/mapa-acoplamento.py [-c]` | o `docs/acoplamento.md` está em dia com o mapa de acoplamento de `src/coupling/`? |
| `tests/cplcheck/confere-cplcheck.bash` | num driver NUOPC com as listas de campos de hoje, a conferência do mapa (`cpl_check`) dá 0 diferenças, e acusa os defeitos plantados? |

### 2.0 Todas as conferências de uma vez

```bash
export ESMFMKFILE=/caminho/para/esmf.mk
tools/dev/confere-tudo.bash HEAD
```

Executa, em sequência, as conferências das seções 2.1 a 2.6 e 2.8 a 2.13 e o teste do framework de interpolação (`tests/regrid`), e termina com um resumo e a tabela de indicadores (seção 2.7). Cada conferência tem o seu log em `build-local/confere/logs/`. A saída se parece com esta:

```
Resumo (referência: HEAD)
  compilacao   OK                              35 s
  avisos       OK                              33 s
  literais     OK                               0 s
  regrid       OK                              27 s
  gravadores   OK                              86 s
  bulk         OK                              82 s
  grade        OK                              83 s
  malhas       OK                              75 s
  unitarios    OK                              31 s
  mapa         OK                               0 s
  cplcheck     OK                              45 s
  supergrid    OK                               4 s
  docn         OK                             178 s
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
| `malhas` | o teste de regressão da seção 2.13 acusa diferença |
| `unitarios` | algum teste com valor esperado ou o teste de consistência do mapa de acoplamento (seção 2.8) falha |
| `mapa` | `docs/acoplamento.md` não é o que `tools/dev/mapa-acoplamento.py` gera do mapa (seção 2.11) |
| `cplcheck` | a conferência do mapa no driver de teste não dá o esperado (seção 2.12) |
| `supergrid`, `docn` | os testes de regressão das seções 2.9 e 2.10 acusam diferença |

A opção `-t` escolhe só algumas conferências (`-t compilacao,literais,bulk`), e `-o` troca o diretório de trabalho. As variáveis `MPIRUN`, `NP` e `FC` são repassadas aos testes. O comando leva cerca de nove minutos numa máquina de 4 núcleos, três deles no teste do DOCN, e sai com código 0 se nenhuma conferência falhou. Depois do commit da etapa, a referência passa a ser `HEAD~1`.

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

Compara os literais de texto (fora dos comentários) de cada fonte alterado desde `HEAD` com os da árvore de trabalho. Mensagens de log são lidas por ferramentas de `tools/` e comparadas entre rodadas, e nomes de campos e atributos acabam nos arquivos NetCDF: numa refatoração, não devem mudar. Toda diferença tem de ser explicada, e as esperadas (por exemplo, o formato de uma variável morta que foi removida) são anunciadas no CHANGELOG. Quando um trecho muda de arquivo (na divisão de um módulo, por exemplo), cada arquivo mostra só quantos literais saíram e entraram, e o que vale é a soma de todos os arquivos, que tem de continuar igual. Sai com código 1 se a soma tiver diferença.

### 2.3 Instruções

```bash
tools/dev/confere-instrucoes.py HEAD src/mediator/MED_cap.F90
tools/dev/confere-instrucoes.py HEAD src/mediator/*.F90
```

Junta as linhas de continuação, retira comentários, espaços e diferença de maiúsculas, e compara o conjunto de instruções do arquivo no commit e na árvore de trabalho. Com vários arquivos, compara a soma de todos (um arquivo novo conta como vazio no commit): é a forma de conferir um trecho que mudou de arquivo. Numa etapa que divide uma rotina em procedimentos, as únicas instruções acrescentadas devem ser as chamadas, as declarações, os cabeçalhos e os retornos das etapas novas; as removidas devem ser só as que viraram chamada e o código morto anunciado. A comparação ignora a ordem: a ordem das operações, em especial das coletivas do MPI, que precisam acontecer na mesma sequência em todos os processos, é conferida lendo o diff.

É a principal conferência dos fontes que só compilam de verdade na Jaci, como `mpas_atm_model.F90` (com `mpas_atm_setup.F90` e `mpas_atm_fluxes.F90`) e `mom_cap_MONAN.F90`.

### 2.4 Teste dos gravadores de diagnóstico

```bash
tests/writers/compara-gravadores.bash HEAD
```

Compila a versão do commit e a da árvore de trabalho, liga a cada uma o seu programa `tests/writers/test_writers.F90` (o do commit na versão antiga, com os `tests/unit/*.inc` do commit, que ele inclui; o da árvore de trabalho na nova, para que uma etapa possa mudar a interface dos gravadores) e o executa com 4 processos MPI e dados sintéticos. O programa chama `med_write_import_fields` (mediador) e `write_mpas_import_diag` (cap atmosférico) duas vezes cada, com valores inválidos, máscara de terra e, na segunda chamada, membros de `atm_bnd` ausentes. Chama também `WriteDOCNDiag` (oceano de dados) três vezes, cada uma com um arquivo `&nuopc_docn` lido por `config_read` e com arquivos NetCDF de SST, gelo e correntes que o próprio programa grava numa grade 36 x 18: sem correntes e com o gelo em fração; com correntes, gelo em porcentagem e nomes diferentes para a dimensão de tempo; e com o arquivo de SST ausente, que só gera um aviso no log. Esse teste é a única verificação do `WriteDOCNDiag`, porque a rodada da linha de base não usa o DOCN. O script compara byte a byte os arquivos NetCDF gravados e compara as mensagens dos gravadores no log do ESMF. Sai com código 0 se tudo for idêntico. Com a mudança ainda não gravada, compare com `HEAD`; depois do commit, com `HEAD~1`.

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

Uma segunda tabela traz os indicadores da fase 11 (arquitetura de acoplamento, [`arquitetura-acoplamento.md`](arquitetura-acoplamento.md), seção 4.4):

| Indicador | O que conta |
| --- | --- |
| arquivos com nomes de campos anunciados ou realizados à mão | arquivos fora de `src/coupling/` (onde fica o mapa de acoplamento) com uma instrução de 3 ou mais nomes de campos (`Sa_`, `So_`, `Si_`, `Faxa_`, `Foxx_` e semelhantes), com `NUOPC_Advertise` ou `NUOPC_Realize` de um nome escrito no código, ou com `ESMF_FieldCreate(name=...)` de um nome num arquivo que chama `NUOPC_Realize` |
| chamadas e arquivos com `ESMF_GridCreate*` fora de `src/coupling` | construções de malha fora do catálogo de malhas |
| rotas criadas (`regrid%add`) fora de `med_exchange` | pontos de criação de rota espalhados pelo mediador |
| chamadas de rota em módulos de física | `regrid%apply` em `med_bulk_ncar.F90` |
| arquivos que carimbam o tempo dos campos | arquivos que chamam `NUOPC_SetTimestamp` |

As contagens são feitas nas instruções, sem comentários nem o conteúdo das mensagens. A regra das fórmulas de índice de grade regular (9 rotinas) não se automatiza bem e é conferida à mão, com a lista do documento de arquitetura.

### 2.8 Testes com valor esperado

```bash
tests/unit/roda-unitarios.bash
```

Os testes de regressão das seções 2.4 a 2.6 comparam duas versões do código e respondem se o resultado mudou; não dizem se o resultado está certo. Os testes de `tests/unit/` respondem a essa outra pergunta: comparam o resultado de rotinas do acoplador com valores esperados calculados à parte, diretamente da fórmula publicada, em precisão de 40 algarismos (biblioteca mpmath do Python), com tolerância relativa de 1e-12. A tolerância existe porque a ordem das operações no código não é a do cálculo de referência; um erro de fórmula (sinal, constante, ramo, limite) muda o resultado muito além dela.

O script compila a árvore de trabalho, liga cada programa `tests/unit/test_*.F90` e o executa; cada programa imprime PASSOU ou FALHOU por caso. Não usam MPI. `test_formulas_bulk.F90` cobre três fórmulas da física bulk do mediador (`med_bulk_ncar`):

| Rotina | O que calcula | Casos |
| --- | --- | --- |
| `ice_temp_eff` | temperatura do gelo usada nos fluxos: `Si_t_sis2` na faixa (180 K; 273,16 K], senão 271,35 K | dentro, nos dois limites e fora da faixa |
| `louis_stability` | número de Richardson bulk e fator de estabilidade de Louis (1979) | estável, neutro, instável, e os dois casos extremos que batem no piso (0,05) e no teto (3) |
| `ocean_direct_albedo` | cosseno do zênite na célula da grade ATM e albedo da água para feixe direto (Briegleb et al., 1986) | sol a pino, noite, sol a 60° e a 78° de latitude, declinação diferente de zero; inclui os casos que batem no piso de 0,03 |

O teste foi conferido ao contrário, com cinco alterações de propósito no código, uma de cada vez: trocar `<=` por `<` no limite de 273,16 K, trocar um coeficiente do fator de Louis, trocar o expoente 1,7 do albedo, mudar o teto do fator e inverter o sinal da longitude no ângulo horário. Todas fizeram o teste falhar.

`test_grade_atm.F90` cobre as duas etapas de cálculo de `map_cells_to_regular_grid` (`mpas_cell_binning`), que leva as células MPAS à grade regular 360 x 180 do cap atmosférico:

| Rotina | O que confere | Casos |
| --- | --- | --- |
| `bin_cells_local` | cada célula cai na caixa de 1 grau certa, com soma e contagem por caixa | duas células na mesma caixa, longitude negativa (vai para a coluna 360), latitudes de 90° e -90° (linhas 180 e 1), célula além de `n` ignorada |
| `fill_empty_bins` | caixa sem célula recebe a média dos vizinhos preenchidos | vizinha ainda vazia não conta, caixa recém-preenchida serve de vizinha na mesma passada, longitude periódica, borda norte, zero passadas, grade toda vazia |

Os valores esperados do preenchimento foram calculados em aritmética exata (frações do Python) para o campo f(i, j) = i + 1000 j. Na borda norte, a linha 181 vira a própria linha 180, e dois vizinhos contam duas vezes; o teste registra esse comportamento atual, que só pode mudar numa etapa própria, com nova linha de base.

Conferido ao contrário: tirar a longitude periódica do preenchimento, tirar a volta da longitude para [0°, 360°), arredondar a latitude em vez de truncar, mudar a marca 0,5 das caixas preenchidas e ignorar o `n` fizeram o teste falhar (o último, pela verificação de limites de array, que aborta o programa).

`test_cpl_map.F90` não calcula nada: confere a consistência do mapa de acoplamento (`src/coupling/cpl_fields.F90` e `cpl_map.F90`) nas cinco configurações de `&nuopc_mode` que ele declara (produção; MOM6 sem SIS2; MONAN-A com DOCN; DATM com MOM6; DATM com DOCN):

| Grupo | O que confere |
| --- | --- |
| estrutura | nomes únicos; todo campo de `TROCAS` está em `CAMPOS` e todo campo de `CAMPOS` é usado; pontos `COMPONENTE@malha` com malha conhecida; condições válidas; conector entre dois componentes, `cap` dentro de um, rota dentro do mediador e entre as malhas da rota; rotas com reserva anterior, máscara, `sem_valor` e `criar` válidos; toda rota usada |
| origem | em cada configuração, cada campo importado por um componente tem uma única origem |
| cadeia | em cada configuração, todo campo que parte da grade do cap atmosférico ou da grade do oceano no mediador chegou antes a ela; as exceções têm de ser exatamente as lacunas conhecidas, registradas no teste (com o DOCN, `So_omask` não chega ao mediador; com o DOCN e o MONAN-A, `Sx_tsfc`, `Sf_albedo` e `Sx_omask` não chegam ao MONAN-A) |
| contagens | campos de cada conector na produção iguais aos do Apêndice A do documento de arquitetura |
| mediador | campos que chegam ao mediador iguais, nome a nome e na mesma ordem, a `import_mpas_names` e `import_datm_names`; campos que voltam da malha de fluxo para a do oceano iguais a `export_names` (`med_cap_types`) |

Conferido ao contrário: tirar a condição `docn` do `So_t` do DOCN (duas origens), trocar a ordem de duas linhas da volta para a grade do oceano, acrescentar um `So_omask` exportado pelo DOCN (lacuna que deixa de existir) e citar uma rota inexistente fizeram o teste falhar.

`test_completa.F90` confere a contagem dos pontos completados por vizinhança, que alimenta as linhas `completar` do relatório de acoplamento: as contagens de `neighbor_fill` (`n_invalid` e `n_left`) no caminho normal, com `overflow_to_fill` e com a difusão pulada pelo limiar; que os valores preenchidos saem iguais bit a bit com e sem as contagens; e a acumulação de `registra_completa`.

Desde a R-FASE11-05, `test_cpl_map.F90` confere também as listas que o mediador anuncia e realiza, geradas do mapa por `cpl_chegadas` com as chaves do mediador, contra as listas que ele usava antes (`tests/unit/listas_mediador.inc`, cópia sem mudança das de `med_cap_types` na tag `fase11-04-fix01`), nome a nome e na mesma ordem, nas cinco configurações.

Desde a R-FASE11-06, faz o mesmo com as listas dos caps do MOM6 e do SIS2 (e, desde a R-FASE11-07, com as do MONAN-A, do DATM e do DOCN), geradas por `cpl_chegadas` e `cpl_exportacoes`, contra as de antes (`tests/unit/listas_caps.inc`, cópia sem mudança das das tags `fase11-05-validada` e `fase11-06-validada`), e confere a tabela `EXPORTACOES`: campos do dicionário, pontos de modelos, condições válidas, nenhuma repetição, as exportações de cada um dos cinco modelos iguais às listas dos caps (as do MONAN-A, do DATM e do DOCN também estão em `listas_caps.inc`) e, em cada configuração, todo campo que sai de um modelo por conector exportado por ele.

`test_cpl_check.F90` confere as duas rotinas de conferência de `cpl_check` (`cpl_confere_conector` e `cpl_confere_estado`) com as listas de campos que os caps anunciam hoje, escritas no teste a partir dos caps e não do mapa: na produção, nenhuma diferença e três avisos (o MOM6 exporta `So_s`, `Fioo_q` e `Si_ifrac`, que ninguém consome); CplList com um campo a menos e com um a mais; importação fora do mapa e do dicionário; campo previsto e não anunciado na importação e na exportação; e a lacuna conhecida do MONAN-A com o DOCN, que aparece como três diferenças.

Para acrescentar um teste: escrever `tests/unit/test_<assunto>.F90` no mesmo formato (valores esperados calculados à parte e registrados no comentário do programa) e, se ele usar outros módulos, incluir os objetos na lista `OBJS` do script.

### 2.9 Teste da leitura do supergrid do MOM6

```bash
tests/supergrid/compara-supergrid.bash HEAD
```

A rodada da linha de base lê um único supergrid, sempre sem erro. Este teste compila `src/shared/mom6_supergrid.F90` do commit `REV` e o da árvore de trabalho, liga a cada um o programa `tests/supergrid/test_supergrid.F90` e o executa sobre três supergrids sintéticos gerados por `tests/supergrid/gera-supergrid.py`:

| Arquivo | Para que serve |
| --- | --- |
| `hgrid.nc` | supergrid de 21 x 15 pontos, com longitudes de -329,6° a 93,3° (exercita a passagem para [0°, 360°)) e linhas e colunas inclinadas, para que um erro de índice (par ou ímpar, i e j trocados) apareça nos valores |
| `impar.nc` | dimensões ímpares, que geram o aviso de `mom6_supergrid_dims` |
| `sem_xy.nc` | sem as variáveis `x` e `y`, o que faz a leitura falhar |

O programa chama as três rotinas públicas (`mom6_supergrid_dims`, `mom6_supergrid_tcoords` e `mom6_supergrid_corners`), com e sem prefixo de mensagem, também com um arquivo que não existe, e grava os códigos de retorno, as dimensões e as coordenadas lidas numa porção local (3:8, 2:6). Têm de ser idênticos, bit a bit, esse arquivo e as mensagens do módulo no log do ESMF, sem data e hora. Leva poucos segundos, porque compila um só fonte.

Conferido ao contrário: somar 1e-11 à correção de 360° da longitude faz o arquivo diferir, e mudar um espaço na mensagem de aviso faz o log diferir. O teste é a conferência das etapas que movem a construção da malha tripolar (fase 11, bloco C).

### 2.10 Teste do oceano de dados (DOCN)

```bash
tests/docn/compara-docn.bash HEAD
```

A rodada da linha de base não usa o DOCN. Este teste o executa num driver NUOPC mínimo, `tests/docn/test_docn.F90`, com o DOCN como componente OCN e um componente fonte (SRC) que exporta os 14 campos que o DOCN importa e importa os 6 que ele exporta, ligados por dois conectores. O relógio vai de 29/03/2026 06h a 30/03/2026 18h, em 4 passos de 9 h. Os dados vêm de `tests/docn/gera-dados-docn.py`, numa grade de 72 x 36 pontos com 10 instantes diários:

| Arquivo | O que exercita |
| --- | --- |
| `sst.nc` | interpolação no tempo da SST, com valores abaixo de 0 °C |
| `ice.nc` | fração de gelo em porcentagem, com valores abaixo de 0 e acima de 100 (conversão e limite a [0, 1]) |
| `cur.nc` | correntes com pontos de preenchimento (-999) e valores de 12 m/s, que o DOCN descarta |

São quatro casos, com e sem arquivo de correntes, e em cada um só a inicialização (argumento `inicio`) ou a rodada completa, sempre com 4 processos MPI. Cada processo grava os campos exportados pelo DOCN, com os limites e o carimbo de tempo; o DOCN grava os diagnósticos de importação. Têm de ser idênticos, bit a bit, esses arquivos e as mensagens do DOCN no log do ESMF, sem data e hora.

O script compila as duas versões inteiras (`compila-local.bash`) e leva cerca de três minutos. Conferido ao contrário: dividir a fração de gelo por 100,0000001 em vez de 100 faz os campos exportados diferirem. O teste é a conferência das etapas que mexem no DOCN (fase 11, blocos B e F).

### 2.11 Mapa de acoplamento em Markdown

```bash
tools/dev/mapa-acoplamento.py        # gera docs/acoplamento.md
tools/dev/mapa-acoplamento.py -c     # só confere se ele está em dia
```

O mapa de acoplamento é escrito em Fortran (`src/coupling/cpl_fields.F90` e `cpl_map.F90`), para que os componentes possam usá-lo nas etapas seguintes da fase 11. O script lê as tabelas desses dois fontes e gera `docs/acoplamento.md`, com o resumo dos conectores por configuração, as trocas de cada conector, as trocas dentro dos componentes, as rotas do mediador, as malhas e o dicionário de campos. Toda mudança no mapa é seguida da geração do Markdown; a conferência `mapa` acusa quando ele ficou para trás. O script também acusa um texto mais longo que o campo que o recebe, que o compilador só cortaria com aviso. Escrito para o Python 3.6 da Jaci.

### 2.12 Conferência do mapa num driver NUOPC

```bash
tests/cplcheck/confere-cplcheck.bash
```

Desde a R-FASE11-03, o driver chama `cpl_check_acoplamento` (`src/coupling/cpl_check.F90`) no fim do `ModifyCplLists`: o relatório dos conectores e a conferência do mapa saem no log do PET 0, em linhas com o prefixo `CPL-REL:`. Este teste exercita essa rotina num driver NUOPC mínimo, `tests/cplcheck/test_cplcheck_driver.F90`: quatro componentes de teste com os rótulos do driver real (`MPAS`, `MED`, `OCN`, `ICE`) anunciam as listas de campos de hoje e são ligados pelos seis conectores da produção, com um `nuopc.input` da produção (`use_med_to_mpas` e `use_sis2_dynamic`). São dois casos, em 4 processos MPI:

| Caso | O que tem de sair no log do PET 0 |
| --- | --- |
| `normal` | os seis conectores com 13, 7, 14, 16, 4 e 6 campos; `conferencia do mapa: 0 diferenca(s), 3 aviso(s)` |
| `defeito` | o OCN importa `So_teste` e o MED não anuncia `So_omask`: conector OCN para MED com 3 campos e 4 diferenças; a inicialização termina assim mesmo |
| `mediador` | o MED é o mediador real (`MED_cap`), que anuncia os campos a partir do mapa: os mesmos seis conectores, 0 diferenças e 3 avisos; a inicialização para de propósito logo depois da conferência, antes da realização, que precisaria das grades reais |

O teste confere também que só o PET 0 escreve. No caso `mediador`, todos os PETs esperam numa barreira até o PET 0 terminar o relatório, antes da parada de propósito; sem ela, o primeiro PET a sair com erro abortava o MPI e podia cortar o log do PET 0. Os relatórios ficam em `build-local/cplcheck/relatorio_<caso>.txt`. Leva menos de um minuto. Conferido ao contrário: sem a fase 0 dos componentes de teste, nenhum campo é anunciado, e a conferência acusa todas as trocas da produção.

### 2.13 Teste das malhas

```bash
tests/malhas/compara-malhas.bash HEAD
```

Desde a R-FASE11-08, a malha de fluxo do mediador (`atm_med`, criada por `create_atm_grid` em `med_init`) e a grade do cap atmosférico (`atm_cap`, criada por `mpas_create_grid` em `mpas_cap_methods`) são construídas por `cpl_malha_latlon` (`src/coupling/cpl_grids.F90`). Este teste compila a versão do commit `REV` e a da árvore de trabalho, liga a cada uma o programa `tests/malhas/test_malhas.F90`, que chama as duas rotinas (cujas interfaces não mudaram), e o executa com 1, 4, 6 e 8 processos MPI (variável `LISTA_NP`). Cada processo grava, para cada DE local, os limites computacionais e os vetores de coordenadas dos centros (as duas malhas) e dos cantos (só a do mediador), inteiros, com os seus limites. Têm de ser idênticos, bit a bit, esses arquivos e as mensagens das duas rotinas no log do ESMF, sem data e hora. Com 4 processos, os DEs do norte têm uma linha a mais de cantos (a borda em 90°), e ela entra na comparação.

A rodada da linha de base usa uma só contagem de processos para cada malha (128 no MONAN-A, 20 no mediador); o teste cobre outras decomposições, entre elas a de 1 processo e a de 6 (3 x 2). Leva pouco mais de um minuto, a maior parte compilando. Conferido ao contrário: somar 10^-13 à latitude dos cantos faz todos os arquivos diferirem.

Desde a R-FASE11-10, o programa também cria o oceano no mediador (`create_ocn_grid`) em duas configurações, gravadas por ele mesmo e lidas por `config_read`: com o MOM6, lendo o supergrid sintético `hgrid.nc` de `tests/supergrid/gera-supergrid.py` (grade T de 10 x 7, com longitudes de -329,6° a 93,3° e linhas inclinadas), com centros, cantos e a máscara; e com o DOCN, numa grade de 36 x 18. As mensagens comparadas incluem as da leitura do supergrid e as da conferência dos cantos (`FIX-DIAG-CONSERVE`). A malha do SIS2 não pode ser criada fora da Jaci pelo cap, que precisa do modelo; por isso o script roda depois, só na árvore de trabalho, `tests/malhas/test_malhas_modelos.F90` (até a R-FASE11-10, `test_malha_gelo.F90`), com 4, 6 e 8 processos, que compara no mesmo programa: `cpl_blocos_de_limites` com uma cópia sem mudança da rotina de antes (`ICE_DecompFromBlocks`, tag `fase11-09-validada`) em onze layouts, válidos e inválidos (mesma resposta, mesma mensagem, mesmos blocos); e a malha de `cpl_malha_tripolar` com blocos com a grade criada como o cap criava, com os blocos em ordem x mais rápido e y mais rápido, bit a bit. Desde a R-FASE11-11, compara também a grade do cap do MOM6 (`cpl_malha_de_blocos`) com a criada como `create_ocean_grid` criava (DELayout, DistGrid com `deBlockList`, grade sem halo), num layout que não é produto e em layouts produto com o mapa de PETs invertido: mesmo número de DEs locais e mesmos limites dos vetores de coordenadas. Conferido ao contrário: pôr a meia célula na longitude do centro da grade do DOCN faz os arquivos diferirem.

`tests/unit/test_cpl_grids.F90` confere as mesmas funções com valores esperados: a decomposição (`cpl_regdecomp`) nos casos do comentário da rotina e, de 1 a 600 processos, colunas x linhas = processos; os centros e os cantos nas bordas das duas malhas; e que as duas regras de centro dão os mesmos graus, a menos de 180 na longitude.

Desde a R-FASE11-09, o mesmo teste confere as fórmulas de índice e de longitude de `cpl_grids` contra as expressões que elas substituíram, escritas no teste como estavam nas rotinas: o resultado tem de ser igual, bit a bit, em cerca de 820 mil coordenadas (passos de 0,001 entre -400 e 400, os múltiplos de 0,25 entre -720 e 720 e os seus vizinhos imediatos, -0 e valores grandes), cinco passos de grade e quatro tamanhos. Uma comparação de código de máquina (`objdump`) não serviria aqui, porque a fórmula passa de expressão no lugar a chamada de função em outro módulo. Conferido ao contrário: trocar `nint` por `int` no índice por arredondamento faz o teste falhar. O teste mostrou também duas coisas que ficaram registradas em `cpl_grids`: com o limite a [1, n], o índice por piso (`floor`) e o por truncamento (`int`) são sempre iguais, e ficaram uma função só; e somar 360 uma vez não é o mesmo que somar até a longitude ficar em [0, 360) (com -1e-17, um dá 360 e o outro 0), por isso a cópia do cap atmosférico manteve a sua soma única.

## 3. Interfaces mínimas

Os arquivos `tests/interfaces/mpas_stubs.F90`, `tests/interfaces/mom_stubs.F90` e `tests/interfaces/sis_stubs.F90` declaram os módulos, tipos e rotinas do MPAS, do MOM6, do FMS e do SIS2 que o acoplador usa, só com as assinaturas e sem nenhum cálculo. Com eles, `mpas_atm_types.F90`, `mpas_atm_setup.F90`, `mpas_atm_fluxes.F90`, `mpas_atm_model.F90`, `time_utils.F90`, `mom_cap_MONAN.F90` e `sis_cap_MONAN.F90` compilam fora da Jaci, e o compilador confere tipos, argumentos e `intent`.

Uma interface mínima pode estar errada; por isso, antes de confiar nela para uma mudança, compile com ela a versão anterior do arquivo. Se a versão anterior não compilar, a interface é que precisa de ajuste, seguindo a assinatura real no código do modelo. Um erro de compilação só é atribuído à mudança se a versão anterior compilar com as mesmas interfaces.

## 4. Ordem sugerida antes de entregar uma etapa

1. `tools/dev/confere-tudo.bash HEAD` (com `-i` se a etapa só muda comentários ou espaços): resumo sem nenhuma conferência FALHOU; diferenças de literais só as anunciadas.
2. Em etapas que só movem código: ler a saída de `tools/dev/confere-instrucoes.py HEAD <arquivo>` em cada arquivo alterado. As instruções acrescentadas devem ser só chamadas, declarações e cabeçalhos das etapas novas; essa leitura não se automatiza.
3. Copiar para o CHANGELOG as linhas dos indicadores que mudaram.
4. Rodada na Jaci com `tools/dev/valida_rodada.bash`.
