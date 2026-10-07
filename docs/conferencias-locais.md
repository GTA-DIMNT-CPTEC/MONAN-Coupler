# Conferências locais antes de uma rodada na Jaci

Uma etapa só é aprovada pela rodada completa na Jaci, comparada bit a bit com a linha de base ([`validacao-refatoracao.md`](validacao-refatoracao.md)). Antes dela, estas conferências, feitas fora da Jaci e sem as bibliotecas do MPAS, do MOM6 e do FMS, pegam a maior parte dos erros de compilação e de refatoração. A versão longa, com cada teste explicado em detalhe, está em [`historico/conferencias-locais-ate-fase12.md`](historico/conferencias-locais-ate-fase12.md).

## 1. O que é preciso

gfortran e MPI (`mpif90` no PATH), NetCDF-Fortran (`nf-config`), ESMF 8.9.1 compilado (`ESMFMKFILE` apontando para o `esmf.mk`), Python 3.6 ou mais novo, git e `ncgen`. Os fontes que dependem dos modelos compilam contra as interfaces mínimas de `tests/interfaces/` (seção 4). A instalação passo a passo está em [`estado-do-projeto.md`](estado-do-projeto.md), seção 8.

## 2. Tudo de uma vez

```bash
export ESMFMKFILE=/caminho/para/esmf.mk
export MPIRUN="mpirun.openmpi --allow-run-as-root --oversubscribe"   # Open MPI como root
tools/dev/confere-tudo.bash HEAD          # antes do commit; depois dele, HEAD~1
```

Leva cerca de onze minutos e termina com um resumo (OK, FALHOU ou PULADO por conferência) e as tabelas de indicadores. Logs em `build-local/confere/logs/`. Opções: `-i` exige instruções idênticas (etapas que só mudam comentários); `-t lista` roda só algumas conferências (ex.: `-t compilacao,literais`); `-o dir` troca o diretório de trabalho. `MPIRUN`, `NP` e `FC` são repassadas aos testes.

| Conferência | Ferramenta | Falha quando |
| --- | --- | --- |
| `compilacao` | `tools/dev/compila-local.bash` | algum fonte não compila (inclusive o cap modelo, `src/caps/template/template_cap.F90`, que não entra no executável e é compilado só aqui) |
| `avisos` | compila também `REV` | algum fonte tem mais avisos que em `REV` |
| `literais` | `tools/dev/confere-literais.py REV` | alguma constante de texto (mensagem, nome de campo, atributo, formato) mudou; um trecho que só mudou de arquivo conta pela soma |
| `nomes` | `tools/dev/renomeia-identificadores.py confere REV` | há tabela nova em `tools/dev/nomes/` e a árvore não é `REV` com essas trocas de nome, ou uma troca colide com um nome visível |
| `instrucoes` | `tools/dev/confere-instrucoes.py REV` | só com `-i`: algum `.F90` alterado tem instrução diferente |
| `regrid` | `make -C tests/regrid run` | os testes do framework de interpolação falham |
| `esquemas` | `tests/regrid/compara-esquema.bash idw` | o esquema modelo não roda ou dá campos diferentes com 1 e 4 processos |
| `gravadores` | `tests/writers/compara-gravadores.bash REV` | os gravadores de diagnóstico gravam arquivos diferentes |
| `bulk` | `tests/bulk/compara-bulk.bash REV` | a física bulk dá valores diferentes, bit a bit |
| `grade` | `tests/atmgrid/compara-grade-atm.bash REV` | a passagem das células MPAS para a grade do cap muda |
| `malhas` | `tests/malhas/compara-malhas.bash REV` | as malhas do mediador, do cap atmosférico ou do SIS2 mudam, com 1, 4, 6 e 8 processos |
| `completar` | `tests/completar/compara-completar.bash REV` | a SST, os campos exportados ou as contagens dos pontos completados mudam |
| `unitarios` | `tests/unit/roda-unitarios.bash` | um teste com valor esperado ou o teste de consistência do mapa falha |
| `mapa` | `tools/dev/mapa-acoplamento.py -c` | `docs/acoplamento.md` está desatualizado |
| `cabecalhos` | `tools/dev/confere-cabecalhos.py` | uma rotina de módulo de `src/` sem cabeçalho começando por `!> @brief`, uma rotina interna sem linha `!>`, ou um nome depois de `@param` que não é argumento da rotina (modelo do README, convenção "Comentários") |
| `curtocircuito` | `tools/dev/confere-curto-circuito.py` | uma instrução de `src/` usa, na mesma expressão, um nome que ela testa com `associated`, `allocated` ou `present` (o Fortran não garante o curto-circuito do `.and.`; separar em `if` aninhados) |
| `exportacao` | `tools/dev/confere-exportacao.py` | um campo que sai do mediador por conector no mapa não chega a `MED@ocn_med` pela rota `atm2ocn` com nome em `MED_FIELDS` (o laço de `med_export`) nem é preenchido pelo nome em `src/mediator/` (`RegridOrCopy(..., exportState, "<nome>", ...)` ou `ESMF_StateGet(exportState, itemName="<nome>", ...)`); um campo coberto assim não sai do mediador por conector; ou um campo da rota `atm2ocn` não está em `MED_FIELDS` |
| `dependencias` | `tools/dev/dependencias.py gera -c` | `src/dependencies.mk`, incluído pelo `Makefile` e pelo `tests/regrid/Makefile`, não corresponde aos `use` dos fontes; gerar de novo com `tools/dev/dependencias.py gera` |
| `camadas` | `tools/dev/confere-camadas.py` | um fonte de `src/` usa módulo de camada de cima (ordem: `src/shared`, `src/regrid`, `src/coupling`, componentes, `src/driver`, `src/main`) ou de outro componente (mediador, MONAN-A, DATM, MOM6, DOCN, SIS2), um fonte de `src/regrid` ou `src/coupling` lê variável `cfg_*` de `coupler_config`, ou um fonte não está na tabela `CAMADAS` do script |
| `cplcheck` | `tests/cplcheck/confere-cplcheck.bash` | a conferência do mapa num driver NUOPC de teste não dá o esperado |
| `config` | `tests/config/compara-config.bash REV` | a leitura do `nuopc.input` (`config_read`) dá mensagens, código de retorno ou valores diferentes dos de `REV` num dos 29 casos (o arquivo da raiz, arquivo vazio e ausente, chave desconhecida, chaves obsoletas, cada erro fatal, os avisos, maiúsculas, `&nuopc_regrid` e duas leituras seguidas) |
| `supergrid` | `tests/supergrid/compara-supergrid.bash REV` | a leitura do supergrid do MOM6 muda |
| `docn` | `tests/docn/compara-docn.bash REV` | o oceano de dados exporta campos, carimbos ou mensagens diferentes, ou, com o arquivo de SST ausente, a falha não chega a todos os PETs |

Os testes que compilam `REV` com o programa de teste de hoje (`malhas`, `completar`, `docn`) traduzem antes a cópia de `REV` para os nomes atuais (`renomeia-identificadores.py traduz`), aplicando as tabelas de `tools/dev/nomes/` que `REV` ainda não tinha.

## 3. Outras ferramentas

| Ferramenta | Para quê |
| --- | --- |
| `tools/dev/indicadores.py [REV ...]` | indicadores de código limpo e da arquitetura de acoplamento, em tabelas prontas para o CHANGELOG |
| `tests/regrid/compara-esquema.bash <nome> '<opções>'` | conferir um esquema de interpolação novo contra uma referência do ESMF |
| `tools/dev/renomeia-identificadores.py aplica <tabela>` | trocar nomes de identificadores por uma tabela (e trazer um ramo antigo para os nomes atuais) |

## 4. Interfaces mínimas

`tests/interfaces/mpas_stubs.F90`, `mom_stubs.F90` e `sis_stubs.F90` declaram, só com as assinaturas, o que o acoplador usa do MPAS, do MOM6, do FMS e do SIS2. Com elas, os caps e `mpas_atm_*` compilam fora da Jaci e o compilador confere tipos, argumentos e `intent`. Uma interface pode estar errada: um erro de compilação só é atribuído à mudança se a versão anterior compilar com as mesmas interfaces.

## 5. Antes de entregar

1. `confere-tudo.bash` sem nenhuma FALHOU; diferenças de literais, só as anunciadas no CHANGELOG.
2. Em etapas que só movem código, ler a saída de `confere-instrucoes.py HEAD <arquivo>`: as instruções acrescentadas devem ser só chamadas, declarações e cabeçalhos.
3. Indicadores que mudaram, no CHANGELOG.
4. Rodada na Jaci com `tools/dev/valida_rodada.bash` ([`estado-do-projeto.md`](estado-do-projeto.md), seção 5).
