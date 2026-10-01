# Roteiro para um MONAN-Coupler com código limpo

Versão de 28/09/2026, escrita depois da fase 5 (tag `fase5-07-validada`). Este documento continua o trabalho das fases 1 a 5: diz o que ainda falta para o acoplador ter código limpo, em que ordem fazer e como saber que cada passo terminou. O estado de cada etapa fica em `docs/estado-do-projeto.md`.

## 1. O que chamamos de código limpo aqui

Código limpo é código que outra pessoa da equipe consegue ler, entender e alterar com segurança, sem depender de quem o escreveu (MARTIN, 2008; FOWLER, 2018). Para o MONAN-Coupler, isso se traduz em sete critérios verificáveis:

| Critério | O que significa na prática |
| --- | --- |
| Rotinas pequenas, com uma responsabilidade | a rotina cabe numa tela e o nome diz tudo o que ela faz |
| Módulos coesos | cada arquivo trata de um assunto (por exemplo, "gelo na grade da atmosfera"), não de um componente inteiro |
| Sem estado escondido | o que uma rotina lê e altera aparece nos argumentos ou no estado interno do componente, não em variáveis de módulo visíveis de qualquer lugar |
| Sem duplicação | uma regra (uma fórmula, um passo de inicialização) é escrita num lugar só |
| Sem remendos | não há configuração que o código aceita mas não executa, nem valor fixo que contorna um problema |
| Comentários que explicam o porquê | e que descrevem o comportamento atual; o histórico fica no CHANGELOG |
| Testes que dizem se está certo | não só "não mudou" (bit a bit), mas também "calcula o valor esperado" |

As fases 1 a 5 cumpriram boa parte do primeiro, do quarto e do sexto critério dentro das rotinas. O que falta está sobretudo na organização entre rotinas e arquivos, no estado compartilhado e nos testes.

## 2. Regras que continuam valendo

- **Nenhuma etapa de limpeza muda resultados.** Cada etapa é validada contra a linha de base R-NOFMA-02 (73 arquivos, bit a bit). O que puder mudar resultados fica na trilha de decisões (fase 10), com etapa e linha de base próprias.
- **Cada etapa é um patch com um único commit**, com CHANGELOG atualizado, conferências locais e rodada na Jaci.
- **O DTN-01 fica de lado por enquanto.** O levantamento de conformidade está em `docs/conformidade-dtn01.md` e será retomado depois deste roteiro.
- **A integração de `refactor/principal` ao `develop` fica para o fim da limpeza** (fim da fase 9).

## 3. Onde estamos: indicadores

Os indicadores abaixo foram medidos no código de `src/` (sem `upstream/`) da tag `fase5-07-validada`. A meta de cada fase está na seção 4; a etapa R-FASE6-01 transforma esta medição num script do repositório, para repetir a cada etapa.

| Indicador | Hoje | Meta ao fim do roteiro |
| --- | --- | --- |
| Arquivos com mais de 1 000 linhas | 7 (o maior, `MED_cap.F90`, com 3 379) | nenhum acima de 1 200 |
| Rotinas com mais de 100 linhas de código | 10 (`config_read` e nove entre 100 e 150) | só `config_read` |
| Variáveis de módulo públicas com estado de componente | `med_cap_types` (sem `private` padrão), ponteiros `g_*` do cap atmosférico, `NLON`/`NLAT`/`GRID_RES` do gravador atmosférico | nenhuma; estado no tipo interno de cada componente |
| Trechos repetidos de 6 linhas ou mais | 87 janelas (DATM/DOCN 29, oceano/gelo 14, dentro do `MED_cap` 11) | só a sequência de registro do NUOPC em `SetServices` |
| Testes com valor esperado | nenhum; os quatro testes comparam versão antiga com nova | as rotinas de cálculo puro com teste de valor esperado |
| Configurações aceitas mas não executadas | `use_datm = .true.`: o mediador passa a esperar o DATM, mas o driver não o registra | nenhuma |
| Comentários desatualizados conhecidos | grade "640×320" em `med_cap_types` (a grade é 360×180) | nenhum |

A repetição em `SetServices` é o idioma do NUOPC (cada componente registra as suas fases do mesmo jeito) e não precisa ser eliminada.

## 4. Roteiro

O roteiro tem quatro fases de limpeza (6 a 9), que não mudam resultados, e uma trilha de decisões (10), que pode mudar. A ordem importa: primeiro a rede de segurança, depois as mudanças de estrutura que ela protege.

### Fase 6: rede de segurança

As fases 7 e 8 movem código entre arquivos e mudam a forma como as rotinas recebem o estado. Antes delas, vale ter conferências mais fáceis de rodar e testes que digam se o cálculo está certo.

| Etapa | Conteúdo | Classe |
| --- | --- | --- |
| R-FASE6-01 | `tools/dev/confere-tudo.bash`: um comando que compila, confere as constantes de texto e roda os quatro testes de regressão, com resumo final OK/FALHOU. `tools/dev/indicadores.py`: mede os indicadores da seção 3 e grava uma tabela para o CHANGELOG. | só ferramentas |
| R-FASE6-02 | testes com valor esperado para as funções puras do mediador: `louis_stability`, `ice_temp_eff` e `ocean_direct_albedo`. Os valores esperados vêm das fórmulas publicadas, calculados à parte; um arnês de teste simples em Fortran, sem dependência externa. `sw_band` e os casos-limite de `calc_bulk_ncar` (vento nulo, estável e instável) leem e gravam campos ESMF do estado interno; ganham teste com valor esperado depois da fase 7, quando o cálculo puder receber arrays. | só testes (e três funções passam a públicas) |
| R-FASE6-03 | testes com valor esperado para as etapas de cálculo do mapeamento de células para a grade (`bin_cells_local` e `fill_empty_bins`, de `map_cells_to_regular_grid`): cada célula cai na caixa certa, caixas vazias recebem a média dos vizinhos, com longitude periódica e bordas. A soma entre processos e a cópia para a grade local usam MPI e continuam cobertas pelo teste de regressão `tests/atmgrid`. | só testes (e duas rotinas passam a públicas) |

**Pronto quando:** `confere-tudo.bash` roda em menos de dez minutos e cada teste novo foi conferido "ao contrário" (quebrar a fórmula de propósito faz o teste falhar).

### Fase 7: estado explícito

Hoje parte do estado dos componentes vive em variáveis de módulo que qualquer rotina pode ler ou alterar. Isso esconde dependências e impede testar uma rotina isolada. A fase leva esse estado para o tipo interno de cada componente, que já existe e é recebido pelas rotinas do NUOPC.

| Etapa | Conteúdo | Classe |
| --- | --- | --- |
| R-FASE7-01 | `med_cap_types`: `private` padrão; `med_mpi_comm`, `med_local_pet`, `med_pet_count` e as opções de diagnóstico vão para o `MED_InternalState`; comentário da grade corrigido para 360×180 | B |
| R-FASE7-02 | `MED_InternalState` agrupado em subtipos por assunto (campos da atmosfera, do gelo, albedos, rotas e máscaras), para que cada rotina receba só o que usa | B |
| R-FASE7-03 | gravador do cap atmosférico: `NLON`, `NLAT`, `GRID_RES`, `DLON`, `DLAT` e as coordenadas globais num tipo de configuração da grade de saída, criado uma vez e passado adiante | B |
| R-FASE7-04 | `mpas_atm_model`: os ponteiros `g_*` (domínio, comunicador, campos do MPAS) num tipo de estado do modelo atmosférico | B |
| R-FASE7-05 | cap atmosférico: estado interno ESMF próprio (hoje o cap guarda `g_atm_public`, `g_atm_state`, `g_atm_bnd`, `g_grid`, `g_diag_export` e `step_count` em variáveis de módulo), incluindo o relógio do diagnóstico de importação (`g_diag_*` de `mpas_cap_netcdf`). Etapa acrescentada na R-FASE7-03: o roteiro supunha que o cap já tinha estado interno | B |
| R-FASE7-06 | marcas de primeira vez e contadores com `save` (cinco locais e três de módulo, no mediador, no gravador do mediador, no modelo atmosférico e nos caps do oceano e do gelo) levados para o estado interno de cada componente, com os mesmos valores iniciais | B |

**Pronto quando:** nenhum módulo próprio exporta variável com estado de componente, e cada etapa reproduz a linha de base. As variáveis com `save` dentro de rotinas (seis, usadas para "primeira chamada" e contadores) passam para o estado interno nesta fase, cada uma com o cuidado de manter o mesmo momento de inicialização.

### Fase 8: módulos coesos

Com o estado explícito, dá para separar os arquivos grandes por assunto sem criar dependências cruzadas.

| Etapa | Conteúdo | Classe |
| --- | --- | --- |
| R-FASE8-01 | `MED_cap.F90` (3 379 linhas) dividido: o arquivo principal fica com os pontos de entrada NUOPC; saem `med_init` (grades, campos, rotas, verificação de cantos), `med_ice` (gelo na grade da atmosfera, 9 rotinas), `med_ocean` (SST, máscara, correntes, fração de gelo do OISST) e `med_diag` (resumos e diagnósticos do log). Na execução, saíram também `med_flux` (forçante atmosférica e fluxos nativos) e `med_export` (exportação para os componentes), para que o arquivo principal ficasse só com o ciclo NUOPC | B |
| R-FASE8-02 | `mpas_atm_model.F90` (1 619 linhas) dividido em inicialização, passo e fluxos instantâneos | B |
| R-FASE8-03 | as nove rotinas entre 100 e 150 linhas de código revistas; dividir apenas as que misturam responsabilidades (candidatas: `export_write_netcdf`, `mpas_atm_run`, `calc_bulk_ncar`, `compute_instantaneous_fluxes`, `get_atm_forcing`). Na execução, uma rotina por patch: a R-FASE8-03 tratou `export_write_netcdf` (e retirou o último `BLOCK`), a R-FASE8-04 `calc_bulk_ncar`, a R-FASE8-05 `write_mpas_import_diag`, a R-FASE8-06 `mpas_export`, a R-FASE8-07 `get_atm_forcing`, a R-FASE8-08 `fill_ifrac_from_oisst`, a R-FASE8-09 `mpas_atm_run`, a R-FASE8-10 `compute_instantaneous_fluxes`, a R-FASE8-11 o `ModelAdvance` do DOCN; revisões concluídas, só o `config_read` passa de 100 linhas | B |

Depois da R-FASE8-02, ainda passavam de 1 200 linhas quatro arquivos que o roteiro não dividia. Decidido em 29/09/2026: o limite de 1 200 linhas fica, desde que cada divisão faça sentido prático e funcional (um assunto por arquivo, sem separar o que é lido e alterado junto). As divisões previstas, uma por patch, depois das revisões de rotinas longas:

| Arquivo (linhas) | Assunto que sai | Arquivo novo | Tamanho aproximado depois |
| --- | --- | --- | --- |
| `mpas_cap_netcdf.F90` (1 478) | diagnóstico de importação `monan2_import_*.nc`: relógio do diagnóstico, reunião dos membros de `atm_bnd`, definição e gravação do arquivo, binagem com máscara (`voronoi_to_grid`) | `mpas_import_diag.F90` | feita na R-FASE8-12: 839 e 661 |
| `mom_cap_MONAN.F90` (1 404) | fração de gelo `Si_ifrac` para o oceano (`set_si_ifrac_from_file`, `compute_si_ifrac_proxy` e o tipo `si_ifrac_memory_t`) | `mom_si_ifrac.F90` | feita na R-FASE8-13: 1 038 e 406 |
| `sis_cap_MONAN.F90` (1 391) | troca de campos com o mediador: importação dos forçantes por categoria e exportação de `Si_ifrac`, albedos e temperatura de pele | `sis_cap_fields.F90` | feita na R-FASE8-14: 958 e 478 |
| `mpas_cap_methods.F90` (1 232) | média das células MPAS na grade regular 360x180 (`state_set_field_1d`, `map_cells_to_regular_grid` e as suas sete etapas) | `mpas_cell_binning.F90` | feita na R-FASE8-15: 769 e 490 |

Os dois arquivos novos do oceano e do gelo entram na lista `MOM6_SRCS` do `Makefile`, para serem compilados com as mesmas opções do MOM6 (`-fdefault-real-8`). Os testes que usam `mpas_cap_netcdf_mod` (`test_writers.F90`) passam a usar também o módulo novo.

**Pronto quando:** nenhum arquivo próprio passa de 1 200 linhas, e cada módulo novo tem um cabeçalho que diz de que assunto trata. O `config_read` fica como está, conforme decidido em 27/09/2026 (quase todo declaração de namelist).

### Fase 9: duplicação e consistência

| Etapa | Conteúdo | Classe |
| --- | --- | --- |
| R-FASE9-01 | procedimentos comuns aos caps de dados e aos caps do oceano e do gelo (`RealizeField`, `PutField`, `InitializeP0`, obtenção do estado interno) num módulo compartilhado dos caps. Feita na R-FASE9-01: `cap_common.F90` com `cap_initialize_p0`, `cap_realize_fields` e `cap_put_field`; a obtenção do estado interno fica em cada cap, porque o tipo do invólucro é próprio de cada componente | B |
| R-FASE9-02 | números fixos no código que representam constantes físicas ou de configuração levados para `coupler_constants` ou para a configuração, somente quando o valor e o `kind` forem idênticos (senão, vai para a fase 10). Feita na R-FASE9-02: cinco constantes novas e 34 trocas; o π de 15 algarismos e as constantes em `MPAS_RKIND` ficam registrados como pendências | B |
| R-FASE9-03 | revisão final de nomes e comentários: nomes que não dizem o que a variável guarda, comentários que descrevem outra rotina ou um estado antigo, mensagens de log com prefixos inconsistentes (sem mudar as mensagens que os scripts procuram). Feita na R-FASE9-03, só nos comentários (zero diferenças de instruções); as mensagens de log e os nomes de variáveis ficaram como estão, porque mudá-los altera constantes de texto e instruções sem ganho de leitura que compense | A e B |

Situação depois da R-FASE9-03: todas as metas da seção 3 foram atingidas, menos duas. Os trechos repetidos estavam em 82 janelas (26 entre `DATM_cap` e `DOCN_cap`: a inicialização de dados, o carimbo de tempo e o registro em `SetServices`; 14 entre os caps do oceano e do gelo; 13 dentro de `mom6_supergrid`). A R-FASE9-04 levou a inicialização de dados e o carimbo de tempo dos caps de dados para `cap_common` e baixou o total para 67; a R-FASE9-05 juntou a leitura dos centros e dos cantos do supergrid do MOM6 e baixou para 54; a R-FASE9-06 juntou a zeragem dos fluxos do oceano no mediador e a busca de campos do cap atmosférico e baixou para 42. Das 42, 31 são a sequência de registro do NUOPC em `SetServices` (entre os caps do oceano e do gelo, entre os caps de dados e entre todos os caps), que a meta aceita; as outras 11 são trechos curtos de chamadas do ESMF seguidas da verificação do código de retorno (criação da grade e leitura do relógio nos caps de dados, obtenção do estado interno no `MED_cap`, entre outros). A configuração `use_datm` continua aceita sem que o driver registre o DATM, o que depende de decisão da fase 10.

**Pronto quando:** os indicadores da seção 3 estão nas metas. Nesse ponto, a limpeza termina: atualizar o relatório técnico (RPQ) e abrir o pedido de integração de `refactor/principal` ao `develop`.

**Fase 9 concluída em 29/09/2026** (R-FASE9-06 validada, tag `fase9-06-validada`; R-FASE9-07 só com documentação). Medição final, comparada com a de partida da seção 3:

| Indicador | Partida (`fase5-07-validada`) | Fim da fase 9 | Meta |
| --- | --- | --- | --- |
| Arquivos com mais de 1 000 linhas | 7 (o maior com 3 379) | 2 (o maior com 1 080) | nenhum acima de 1 200: atingida |
| Rotinas com mais de 100 linhas de código | 10 | 1 (`config_read`) | só `config_read`: atingida |
| Variáveis de módulo públicas / privadas | 5 / 65 | 0 / 2 (catálogo de interpolação) | nenhuma com estado de componente: atingida |
| Trechos repetidos | 87 | 42 (31 em `SetServices`) | só `SetServices`: atingida, com 11 trechos curtos de chamada ao ESMF e conferência do retorno |
| Testes com valor esperado | nenhum | 46 casos (física bulk e grade do cap atmosférico) | funções de cálculo puro: atingida |
| Configurações aceitas mas não executadas | `use_datm` | `use_datm` | depende da fase 10 |
| Comentários desatualizados conhecidos | grade "640×320" | nenhum | atingida |

O RPQ foi atualizado (sexta versão) e a integração ao `develop` foi autorizada; o procedimento está na seção 8 de `docs/estado-do-projeto.md`. Seguem a fase 10 e, depois dela, o DTN-01.

### Fase 10: trilha de decisões (pode mudar resultados)

Estes itens não são limpeza no sentido estrito: removem remendos ou corrigem escolhas que afetam o que o modelo calcula. Cada um precisa de decisão registrada no estado do projeto, etapa exclusiva e, quando mudar resultados, uma nova linha de base. Podem ser tratados em paralelo com as fases 6 a 9, desde que nunca na mesma etapa.

| Item | Situação | Decisão necessária |
| --- | --- | --- |
| DATM | `use_datm = .true.` é aceito e muda o comportamento do mediador e do cap atmosférico, mas o driver não registra o DATM; o `nuopc.input` anuncia modos que não rodam | registrar o DATM no driver ou retirá-lo (código, chave de configuração e scripts) |
| Época do JRA55 no DATM | o código usa 01:30; comentários antigos diziam 00:00 | depende da decisão anterior |
| `u_star` sobre o gelo | o cap do SIS2 recebe zero, porque o mediador não o envia | calcular no mediador ou manter zero documentado |
| Precisão dos valores padrão da configuração | `cfg_sst_default`, `cfg_zorl_default` e outros são `real` de precisão simples (0.01 vira 0.0099999998) | passar para `real(r8)` com nova linha de base |
| `-fdefault-real-8` em fontes próprios | `mom_cap_MONAN`, `sis_cap_MONAN` e `time_utils` dependem da opção | declarar `kind` explícito; pode dar bit a bit, a conferir |
| Variáveis usadas antes de definidas | não levantado | rodada de teste com `-finit-real=snan -ffpe-trap=invalid`; cada caso achado é um defeito |
| Esquema `mpassit` | alternativa ao algoritmo atual do cap atmosférico | decisão científica do GT |

### Fase 11: arquitetura de acoplamento

A limpeza das fases 1 a 9 deixou cada arquivo com um assunto, mas a descrição do acoplamento (que campos vão de onde para onde, em que malha e por qual interpolação) continua espalhada por mais de dez arquivos. A fase 11 reúne essa descrição em três conceitos (malha, campo e troca) e em três arquivos de `src/coupling/` (`cpl_grids.F90`, `cpl_fields.F90` e `cpl_map.F90`), com a execução das trocas do mediador em `med_exchange.F90`. As regras são as mesmas das fases anteriores: nenhuma etapa muda resultados, um patch por etapa e validação bit a bit na Jaci.

O plano completo, com as 25 etapas (R-FASE11-01 a R-FASE11-25, em seis blocos), as conferências por tipo de mudança, os indicadores e as metas, está em [`arquitetura-acoplamento.md`](arquitetura-acoplamento.md), seção 4. Este roteiro não o repete; registra só o andamento.

| Etapa | Situação |
| --- | --- |
| R-FASE11-01 | documento de arquitetura no repositório; fase 11 no roteiro e no estado do projeto; indicadores da fase em `indicadores.py`; testes do supergrid do MOM6 e do DOCN levados para o repositório e para `confere-tudo.bash` |
| R-FASE11-02 | mapa de acoplamento em `src/coupling/` (`cpl_fields.F90`: 57 campos; `cpl_map.F90`: 8 malhas, 154 trocas e 6 rotas), compilado e ligado, sem uso; teste `test_cpl_map` em `tests/unit`; `tools/dev/mapa-acoplamento.py` gera `docs/acoplamento.md` (conferência `mapa`); trocas sem linha no mapa: 0 |
| R-FASE11-03 | `cpl_check.F90`: relatório dos conectores e conferência do mapa no log (`CPL-REL:`), chamados pelo driver em `ModifyCplLists`, só registro; testes `test_cpl_check` e `tests/cplcheck` (conferência `cplcheck`); driver em `compila-local.bash` |
| R-FASE11-04 | relatório das rotas do mediador e dos pontos completados por vizinhança (`CPL-REL:`); `valida_rodada.bash compara` grava e compara o relatório de acoplamento; teste `test_completa`; fim do bloco A |
| R-FASE11-04-FIX01 | linhas dos pontos completados no último passo do mediador (a finalização dos componentes não é chamada) |
| R-FASE11-05 | o mediador anuncia e realiza os campos a partir do mapa; arquivos com nomes de campos escritos à mão de 8 para 5 (só os caps) |
| R-FASE11-06 | os caps do MOM6 e do SIS2 anunciam e realizam os campos a partir do mapa (tabela nova `EXPORTACOES`); arquivos com nomes de campos escritos à mão de 5 para 3 |
| R-FASE11-07 | os caps do MONAN-A, do DOCN e do DATM anunciam e realizam os campos a partir do mapa; arquivos com nomes de campos escritos à mão de 3 para 0 (meta do bloco B) |
| R-FASE11-08 | `cpl_grids`: malha de fluxo do mediador e grade do cap atmosférico por um só construtor, decomposição escrita uma vez; chamadas `ESMF_GridCreate*` fora de `src/coupling` de 7 para 5 |
| R-FASE11-09 | fórmulas de índice e de longitude das grades regulares em `cpl_grids` (oito rotinas, uma função por regra) |
| R-FASE11-10 | `cpl_malha_tripolar` e `cpl_blocos_t`: oceano no mediador e malha do SIS2 construídos por `cpl_grids`; chamadas `ESMF_GridCreate*` fora de `src/coupling` de 5 para 3 |
| R-FASE11-11 | grade do cap do MOM6 por `cpl_malha_de_blocos`, com as chamadas do ESMF de hoje; fim do bloco C; chamadas `ESMF_GridCreate*` fora de `src/coupling` de 3 para 2 (DOCN e DATM) |

Indicadores da fase 11 na partida (`fase9-07-validada`), medidos pela segunda tabela de `indicadores.py`:

| Indicador | Partida | Meta |
| --- | --- | --- |
| arquivos com nomes de campos anunciados ou realizados à mão | 8 | 0 |
| chamadas `ESMF_GridCreate*` fora de `src/coupling` | 7, em 6 arquivos | só as do DOCN e do DATM, se não migradas |
| rotas criadas (`regrid%add`) fora de `med_exchange` | 7, em 5 arquivos | 0 |
| chamadas de rota em módulos de física | 1 (`med_bulk_ncar`) | 0 |
| arquivos que carimbam o tempo dos campos | 5 | `cap_common` e `med_exchange` |

Desde a R-FASE11-02, o primeiro indicador não conta os arquivos de `src/coupling/`, que é onde os nomes devem ficar; os valores de partida não mudam.

A fase 10 continua reservada às decisões que mudam resultados e pode ser tratada em paralelo, nunca na mesma etapa.

## 5. Definição de "pronto" para cada etapa

Uma etapa só é entregue quando:

1. compila aqui (fontes sem dependência de MPAS, MOM6 e FMS, e os demais contra as interfaces mínimas), sem avisos novos;
2. `confere-literais.py` não acusa constante de texto alterada (salvo objetivo declarado);
3. os testes de regressão e, a partir da fase 6, os testes de valor esperado passam;
4. o CHANGELOG descreve o que mudou e os indicadores antes e depois;
5. a rodada na Jaci reproduz a linha de base R-NOFMA-02 (PASS, 73 iguais) e recebe a tag `faseN-NN-validada`.

## 6. Riscos e cuidados

- **Mover estado muda o tempo de vida das variáveis.** Uma variável com `save`, ou um ponteiro inicializado na declaração, conserva o valor entre chamadas. Ao levá-la para o estado interno, a inicialização precisa acontecer no mesmo momento de antes, ou o resultado muda.
- **Dividir arquivos muda a ordem de compilação.** O Makefile, `compila-local.bash` e as interfaces mínimas precisam acompanhar cada novo módulo.
- **O teste bit a bit não cobre tudo.** A linha de base não roda DOCN nem DATM e lê um único supergrid, sempre sem erro; mudanças nesses caminhos dependem dos testes locais (gravadores, supergrid e DOCN).
- **Etapas pequenas.** Uma etapa que toca muitos arquivos é difícil de revisar e, se falhar na Jaci, difícil de diagnosticar. Na dúvida, dividir.

## Referências

FOWLER, M. **Refactoring: improving the design of existing code**. 2. ed. Boston: Addison-Wesley, 2018.

MARTIN, R. C. **Clean code: a handbook of agile software craftsmanship**. Upper Saddle River: Prentice Hall, 2008.
