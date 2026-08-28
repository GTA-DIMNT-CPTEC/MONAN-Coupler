# Integração do componente de gelo marinho (SIS2) ao MONAN-Coupler

Registro da junção entre o MONAN-Coupler-PK (que traz o componente de gelo) e o MONAN-Coupler atual (que traz as correções de split-sequencial e de execução em vários nós).

## 1. Situação de partida

Existiam duas versões do acoplador, cada uma com trabalho que a outra não tinha.

O MONAN-Coupler-PK acrescentou o componente de gelo marinho SIS2 como componente NUOPC próprio, com os conectores MED -> ICE e ICE -> MED, além de duas rotinas auxiliares que atribuem o relógio do driver explicitamente a cada componente e a cada conector no momento em que eles são registrados.

O MONAN-Coupler atual acrescentou a separação dos dois eixos de configuração (`coupling_mode` para a ordem de execução no tempo e `pet_layout` para a ocupação de PETs), o suporte a execução em vários nós, e três correções de cálculo: a guarda de pressão ao nível do mar na evaporação, a chamada de `ocean_model_init_sfc` para a exportação de SST em t=0, e o valor de albedo do oceano.

## 2. Comparação entre as duas árvores

Foram comparadas 47 fontes presentes nas duas versões, além de um arquivo que só existe no PK.

| Situação | Quantidade |
|---|---|
| Arquivos idênticos | 30 |
| Arquivos divergentes | 16 |
| Arquivo novo, só no PK (`sis_cap_MONAN.F90`) | 1 |

A comparação mostrou que o PK não é simplesmente "o projeto atual com gelo acrescentado". Ele é um ramo mais antigo, sobre o qual o gelo foi construído. Copiar arquivos do PK por cima do projeto atual apagaria correções já validadas.

## 3. Direção adotada

A base é o projeto atual, e o gelo entra por cima. A razão é o tipo de falha que cada conjunto de mudanças produz quando dá errado.

As correções de split e de vários nós falham em silêncio: foi exatamente isso que aconteceu quando `coupling_mode` descartava `atm_pet_count` sem avisar, e o MOM6 só abortava bem depois, no `mpp_define_domains`, com uma mensagem que não mencionava PET nenhum. Reaplicar esse tipo de correção sobre uma base menos conhecida seria procurar de novo o mesmo defeito.

O gelo, ao contrário, é aditivo: entra como componente novo e, quando quebra, quebra alto.

## 4. Mudanças rejeitadas

Cinco arquivos do PK foram descartados por reverterem trabalho já feito.

| Arquivo | O que voltaria atrás |
|---|---|
| `med_bulk_ncar.F90` | A guarda de `psl` na evaporação (BUG-CALC-06). Sem ela, o fluxo satura no limite superior em todo o globo no primeiro passo do modo sequencial, e esse fluxo saturado é entregue ao oceano |
| `mom_cap_MONAN.F90` | A chamada de `ocean_model_init_sfc` (B-SEQINIT-02). Sem ela, `So_t` volta a exportar zeros em t=0 |
| `med_cap_types.F90` | `albedo_ocn` voltaria de 0,26 para 0,06 |
| `mpas_atm_model.F90` | Versão anterior, sem `atm_add_stream_attributes` e sem a iteração sobre pools |
| `Makefile` (linha do compilador) | O PK compila com `-fbounds-check -fcheck=all -Wall -fbacktrace`, que é configuração de depuração, não de produção |

## 5. Mudanças aceitas

### 5.1 Arquivo novo

`src/caps/ice/sis_cap_MONAN.F90`, com 979 linhas, copiado sem alteração. É o cap NUOPC do SIS2. Depende apenas de `cfg_mom6_mesh_ocn`, que já existe no projeto atual, então não exigiu adaptação.

### 5.2 Rotinas auxiliares de relógio (`esm.F90`)

Foram trazidas `AddModelCompWithClock` e `AddConnectorWithClock`. Com três ou mais componentes em blocos disjuntos de PETs, o mecanismo automático do NUOPC não estava atribuindo relógio interno a alguns componentes, e a execução abortava com "Clock object is not present". As duas rotinas registram o componente e atribuem o relógio no mesmo passo.

Todos os registros existentes foram convertidos para elas: 4 componentes e 5 conectores. As duas chamadas diretas a `NUOPC_DriverAddComp` que restam estão dentro das próprias rotinas auxiliares.

Ao acrescentar um componente ou conector novo no futuro (WAV, LND, o que for), use essas rotinas em vez de chamar `NUOPC_DriverAddComp` diretamente: a atribuição do relógio vem junto, sem depender de alguém lembrar de repetir o bloco.

### 5.3 Fallback de fração de gelo por latitude (`mpas_cap_methods.F90`)

Quando a fração de gelo vem NaN, o valor de preenchimento deixa de ser sempre 0,0 e passa a interpolar linearmente de 0,0 no equador até 0,5 no polo, mesma lógica já usada para a SST. Nos trópicos "sem gelo" é o palpite certo; perto dos polos não é. O corte físico em [0,1] continua igual.

### 5.4 Caminho do Si_ifrac real (`MED_cap.F90`, `med_cap_methods.F90`)

O gelo real chega ao mediador com o nome `Si_ifrac_sis2`, deliberadamente diferente de `Si_ifrac`. Se os dois conectores automáticos (OCN -> MED e ICE -> MED) apontassem para o mesmo nome de campo, o resultado dependeria da ordem de execução.

Foram acrescentados o `NUOPC_Advertise` e o `NUOPC_Realize` desse campo no mediador, ambos condicionados a `cfg_use_sis2_dynamic`. Sem o advertise, o conector ICE -> MED não tem o que casar do lado do mediador, o campo aparece como não conectado no Compliance Checker, e a leitura falha sem alarde.

## 6. O que precisou ser reescrito, e não copiado

Esta é a parte que exigiu mais decisão.

No PK, o componente de gelo só existia dentro do ramo `if (is_concurrent)`, porque naquela versão os dois eixos ainda estavam colapsados em um só. Copiar aquele código traria de volta a amarração que o projeto atual desfez.

A lógica foi reescrita sobre o eixo `pet_layout`:

| Configuração | Antes (PK) | Agora |
|---|---|---|
| `split` com gelo | Existia (chamava-se `concurrent`) | Três blocos disjuntos: ATM \| OCN \| ICE |
| `shared` com gelo | Não existia | ICE em todos os PETs, junto com os demais |
| RunSequence concorrente com gelo | Existia | Mantida |
| RunSequence sequencial com gelo | Não existia | Escrita agora |

Quando o gelo está desligado, `nIce` vale 0 e as contas recaem exatamente na divisão em dois blocos que existia antes. Essa é a propriedade que permite a verificação da seção 8.

O próprio código do PK registrava, em comentário, que só a variante concorrente havia sido atualizada e que as demais precisariam de trabalho. Esse trabalho está feito.

## 7. Regras de configuração acrescentadas

O mesmo princípio que motivou a correção do split foi aplicado ao gelo: configuração lida e jogada fora sem aviso passa a ser erro.

| Regra | Onde é verificada |
|---|---|
| `ice_pet_count > 0` exige `use_sis2_dynamic = .true.` | `config_read` e `run_esmApp.jaci` |
| `use_sis2_dynamic = .true.` exige `use_docn = .false.` | `config_read` |
| Em `pet_layout = 'shared'`, as três contagens devem ser zero | `config_read` e `run_esmApp.jaci` |
| Em `pet_layout = 'split'`, `atm + ocn + ice` deve somar o total de PETs | `config_read` e `run_esmApp.jaci` |

A segunda regra existe porque, com o DOCN, o oceano é um arquivo OISST lido do disco e a fração de gelo vem do próprio arquivo: não há a quem o SIS2 se acoplar. Sem essa guarda o sistema subiria com um componente cujo resultado seria descartado.

O `run_esmApp.jaci` verifica o que consegue antes de submeter, ainda no nó de login, para não gastar fila descobrindo erro de configuração.

## 8. Verificação sugerida

A ordem importa: cada passo separa uma causa possível da seguinte.

**Passo 1: o gelo desligado não mudou nada.** Rodar o caso de referência com `use_sis2_dynamic = .false.` e exigir saída NetCDF byte-idêntica ao baseline atual. Isso separa "o gelo entrou" de "o gelo mexeu no que já estava certo". Se este passo falhar, o problema está na reescrita da partição, não no gelo.

**Passo 2: as correções que o PK não tinha continuam de pé.** Rodar os casos de split-sequencial e de vários nós, ainda com o gelo desligado. São justamente o que a versão de origem não tinha, e portanto o que a junção poderia ter desfeito sem avisar.

**Passo 3: o gelo sobe.** Ativar `use_sis2_dynamic = .true.` em `split` e verificar no log a linha de registro do componente ICE e a dos conectores 5 e 6. Conferir a partição de PETs anunciada.

**Passo 4: o gelo em `shared`.** Combinação que não existia no PK, então não tem histórico. Vale rodar mesmo que não seja a configuração de produção, porque é o teste mais barato da reescrita do eixo espacial.

**Passo 5: o relógio avança uma vez por passo.** Conferir no log que a escrita de `monan2_import` mantém a frequência configurada, e que a simulação termina exatamente na `stop_date`. Os dois defeitos da seção 9.1 e da seção 9.4 se manifestavam aqui, e por caminhos diferentes: um acelerava o relógio, o outro encurtava o laço.

**Passo 6: o valor do gelo chega ao MPAS.** Ver a seção 10 antes.

## 9. Correções trazidas pelo PK2

Uma segunda entrega do projeto de origem trouxe correções encontradas em execução. Todas foram transferidas.

### 9.1 Relógio compartilhado entre componentes (defeito grave)

Este é o achado mais sério, e afetava o código que eu já havia mesclado.

`ESMF_Clock` é um tipo por referência. As rotinas auxiliares passavam `driverClock` diretamente para `ESMF_GridCompSet`, o que fazia todos os componentes apontarem para o mesmo relógio físico, e não para cópias. Como o NUOPC avança o relógio associado a cada componente depois do respectivo Advance, com três componentes Model (MPAS, OCN e ICE) o mesmo relógio recebia até três avanços por ciclo de `dt_coupling`, em vez de um.

O sintoma observado foi a escrita de `monan2_import` passar de horária para a cada três horas: exatamente o fator 3 previsto pelo raciocínio acima.

A correção é criar uma cópia independente com `ESMF_ClockCreate(driverClock, rc=rc)`, o construtor de cópia do ESMF, para cada componente e para cada conector.

Vale registrar que esse defeito veio junto com as rotinas auxiliares que eu havia adotado na primeira junção, e não foi detectado por nenhuma das verificações de compilação: o código estava sintaticamente correto e o erro era de semântica de referência.

### 9.2 Origem errada da fração de gelo

O cap do gelo lia `Ice%part_size`, que é o campo de fachada do acoplador, preenchido apenas no caminho de acoplamento rápido. Nesta configuração ele permanece zerado, e o diagnóstico mostrou todas as fatias em zero apesar de o SIS2 registrar área de gelo real no log.

O estado real do gelo vive em `Ice%sCS%IST%part_size`, que é o que o próprio SIS2 usa para calcular área e massa. Ao contrário do campo de fachada, esse tem halos e categorias com base 0, então o deslocamento de índices passou a ser derivado da grade do próprio SIS2 (`Ice%sCS%G%isc` e `jsc`).

A fórmula também mudou: era `1 - part_size(:,:,1)`, tratando o índice 1 como água aberta, o que estava errado porque o índice 1 é categoria de gelo. Passou a somar todas as categorias a partir da segunda fatia, o que funciona tanto com base 0 quanto com base 1.

### 9.3 Política de compartilhamento na exportação do gelo

O cap do gelo era o único do sistema a usar `SharePolicyField="share"` num campo de exportação. O diagnóstico mostrou o campo saindo correto da origem (máximo 0,997) e chegando zerado ao mediador. Removida a política na exportação, alinhando ao padrão do cap do oceano, que usa `share` apenas nas importações.

Do lado do mediador a política foi mantida, porque ali todos os campos de importação a usam e funcionam.

### 9.4 Contagem de passos com calendário aproximado

O `esmApp.F90` estimava o número de passos com aritmética manual, usando 365 dias por ano e 30 dias por mês. Para o intervalo de 2026-03-29 a 2026-04-30 isso dava 31 dias, quando o intervalo real é de 32 dias, porque março tem 31 dias. E esse número era usado como limite do laço de execução, então a simulação parava cerca de 24 horas antes da data final configurada.

Passou a ser calculado a partir do próprio intervalo ESMF (`stopTime - startTime`), que já respeita o calendário Gregoriano.

### 9.5 Ordenação da sequência sequencial com gelo

Na primeira junção eu escrevi a variante sequencial com gelo, que não existia no projeto de origem. O PK2 escreveu a sua, com uma diferença de ordenação: o `MED -> ICE` vem depois do avanço do OCN, e não antes.

Adotei a ordenação do PK2, porque é a que foi exercitada em execução. O conteúdo entregue ao gelo é o mesmo nos dois casos, já que o mediador calculou antes das duas; a diferença é só de ordem de execução.

### 9.6 Aviso para gelo com oceano sintético

Acrescentado aviso em tempo de execução quando o gelo é pedido junto de uma sequência de Fase 1, em que o componente ICE seria registrado mas nunca executado.

Esse aviso complementa, e não substitui, a regra da seção 7 que rejeita gelo com `use_docn`. As duas condições não são a mesma: existe o caso em que `use_docn` é falso mas `use_med_to_mpas` também é, e aí o erro não dispara mas o gelo ficaria inerte.

### 9.7 Terceiro bloco de nós no script de execução (defeito meu)

Ao integrar o gelo eu acrescentei a leitura de `ice_pet_count` e as validações ao `run_esmApp.jaci`, mas não acrescentei o terceiro bloco ao `select` do PBS.

A consequência: com `pet_layout='split'` e gelo ativo, o script pedia ao PBS apenas `ATM + OCN` processos, enquanto o `mpiexec` era lançado com o total. Para `-n 8` com atm=4, ocn=2, ice=2, o pedido era de 6 slots para 8 PETs. O trabalho falharia na largada, por falta de slots, com mensagem do PALS sem relação aparente com gelo.

Corrigido: o bloco do ICE entra no `select`, e a opção `--ppn-ice` foi acrescentada por simetria com `--ppn-atm` e `--ppn-ocn`.

A ordem dos blocos importa e está documentada no código: o PALS preenche o `PBS_NODEFILE` na ordem do `select`, e o `esm.F90` atribui PETs por faixas contíguas de rank (ATM primeiro, depois OCN, depois ICE). Os blocos precisam seguir essa mesma ordem, senão um componente executa em nós dimensionados para outro.

Também foi acrescentada uma regra: em `split` com gelo, `ice_pet_count` precisa ser explícito. O `select` é montado antes de o driver executar, então o modo automático (`ice_pet_count = 0`) não tem como ser resolvido pelo script.

## 10. Pendência que permanece

O `Si_ifrac_sis2` continua sendo copiado ponto a ponto do componente ICE para o `Si_ifrac` do exportState do mediador. O PK2 não mexeu nisso.

Há uma dúvida concreta aqui que vale investigar no Jaci. O campo `Si_ifrac_sis2` é realizado na grade do oceano, enquanto o `Si_ifrac` do exportState é alimentado a partir de `is%f_ifrac_atm`, que é criado na grade da atmosfera. Se as duas grades tiverem formatos diferentes, a cópia é pulada e sai aviso no log; se tiverem o mesmo formato por coincidência da configuração, a cópia acontece mas mistura grades diferentes.

O PK2 afirma que a mensagem de sobrescrita apareceu em execução, o que sugere que os formatos coincidiram naquele caso. Isso não prova que a cópia esteja correta: prova que a guarda de formato não a impediu.

Os diagnósticos temporários FIX-DIAG-TEMP5 e FIX-DIAG-TEMP6 foram mantidos justamente para esclarecer esse ponto. Eles imprimem os extremos e o formato do campo na saída do cap do gelo e na chegada ao mediador. Comparando os dois logs sabe-se onde o valor se perde. Remover depois de concluída a investigação.

## 11. Verificações feitas

| Verificação | Resultado |
|---|---|
| `mpas_cap_config.F90` compilado com gfortran (módulo autocontido) | Passou |
| `esm.F90` compilado contra stubs de ESMF, NUOPC e NUOPC_Driver | Passou |
| `esm.F90` original compilado contra os mesmos stubs, como controle | Passou |
| `run_esmApp.jaci` verificado com `bash -n` | Passou |
| Balanceamento de blocos nos fontes alterados | Passou |
| Balanceamento nos mesmos arquivos do PK2, como controle | Passou |
| Contagem de chamadas convertidas: 4 componentes, 5 conectores, 2 internas | Confere |
| Duas chamadas a `ESMF_ClockCreate`, uma por rotina auxiliar | Confere |

O controle da terceira e da sexta linhas é o que dá valor aos testes: sem ele, um stub incompleto ou um verificador defeituoso poderiam estar aceitando código quebrado.

Dois defeitos reais foram encontrados por mim durante o trabalho, ambos registrados aqui por serem instrutivos. O primeiro: uma substituição por padrão de texto transformou o corpo de `AddModelCompWithClock` numa chamada recursiva a si mesma, porque o padrão casou também com a definição, e não só com as chamadas. O segundo: uma inserção de bloco partiu um comentário ao meio, deixando um cabeçalho órfão.

O que não foi verificado: a compilação real contra ESMF 8.9.1, MPAS e MOM6, e qualquer execução. Isso só é possível no Jaci.

## 12. Arquivos entregues

Árvore `MONAN-Coupler-merged/`, com os arquivos já mesclados:

| Caminho | Linhas acrescentadas |
|---|---|
| `src/caps/ice/sis_cap_MONAN.F90` | 1031 (arquivo novo, versão PK2) |
| `src/driver/esm.F90` | 333 |
| `src/mediator/med_cap_methods.F90` | 70 |
| `src/main/esmApp.F90` | 60 |
| `src/caps/atmos/mpas_cap_config.F90` | 59 |
| `src/mediator/MED_cap.F90` | 39 |
| `nuopc.input` | 39 |
| `run/run_esmApp.jaci` | 38 |
| `src/caps/atmos/mpas_cap_methods.F90` | 27 |
| `Makefile` | 18 |

Diretório `patches/`, com os mesmos nove arquivos em formato de diff unificado, para aplicação e revisão com git.

## 13. Observação sobre o procedimento

Se as duas versões compartilharem histórico git, vale conferir o resultado desta junção contra um `git merge` de três vias a partir do ancestral comum. O git resolve sozinho tudo que for independente e entrega só os conflitos reais; esta análise foi feita por comparação de conteúdo, sem esse histórico disponível.

O ponto da seção 6, no entanto, não é conflito de texto e nenhuma ferramenta de merge o resolveria: a lógica do gelo precisava mudar de eixo, e isso é decisão de projeto, não de junção automática.
