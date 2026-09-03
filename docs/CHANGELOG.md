# Changelog — Coupler-Install

Histórico de versões do instalador do sistema acoplado
**MONAN-A 2.0 × MOM6+SIS2** (NUOPC-ESMF 8.9.1).
INPE / CGCT / DIMNT — GT Acoplamento de Modelos.

O formato segue, de modo simplificado, *Keep a Changelog*; as datas são
aproximadas (iterações de desenvolvimento, Jun a Jul 2026).

## [Não lançado]

- **Máscara de continentes nos diagnósticos de importação (`B-DIAGMASK-01`).** Os arquivos `mom6_import_*.nc` e `monan2_import_*.nc` passam a mascarar os continentes com a máscara **real** do MOM6 (`ocean_grid%mask2dT`), e não mais com substitutos.

  Até aqui, o continente saía do `mom6_import` como **zero** — os fluxos eram zerados pelo Sprint A.5.1 antes do export. Zero é um valor físico legítimo de fluxo: nem o GrADS nem o pós-processamento tinham como distinguir "fluxo nulo sobre oceano calmo" de "aqui não há oceano", e as células de terra entravam nas estatísticas. No `monan2_import` a situação era pior: só havia o filtro `ocean_frac_min` do binning Voronoi, que mede **cobertura de célula Voronoi por bin** e nada diz sobre terra ou oceano.

  A máscara já existia no mediador desde o `B-LANDMASK-01` (`is%f_omask_atm`, regridada de `So_omask`); o que faltava era levá-la aos dois escritores NetCDF. Ela é exportada sob o StandardName novo `Sx_omask` — prefixo `Sx_` porque o MED já *importa* `So_omask` do oceano, e repetir o nome no `exportState` criaria um par homônimo no mesmo componente; mesmo precedente do `Sx_tsfc`. O cap do MPAS a recebe pelo conector MED→MPAS em `atm_bnd%omask`.

  Célula de terra agora sai como `_FillValue`. A própria máscara é gravada na variável `Sx_omask` (1 = oceano, 0 = terra), para que os scripts não precisem readivinhá-la. O corte binário fica sempre no consumidor final — 0,5 no MED e no cap do MPAS, este depois do binning — e nunca no meio do caminho: binarizar entre dois regrids produz escadinha na linha de costa. No mediador o `MPI_Allreduce(MAX)` opera sobre 0/1, que é inequívoco, ao contrário do MAX sobre `FILL_IMP` usado nos campos.

  **A máscara age apenas nos buffers de escrita.** O `exportState` continua com os zeros do Sprint A.5.1: um `_FillValue` que vazasse para lá viraria forçante do MOM6.

  Corrigidos no mesmo passo dois defeitos encontrados durante o trabalho:
  - `mpas_cap_MONAN.F90::init_import_defaults` — `defaults` é dimensionado por `N_IMP` e o laço percorre `1..N_IMP`, mas `defaults(6)` (`Sf_albedo`, Fase 2.6) nunca foi atribuído: o campo era inicializado com o que houvesse na pilha. Agora vale 0,08, o mesmo default de água aberta usado em `mpas_cap_methods.F90` e `mpas_atm_model.F90`.
  - `postproc_monan2_import.py` — a FONTE 1 procurava apenas `mpas_import_step????.nc`, nome legado que o cap não escreve desde a v4.19. O efeito era silencioso: a FONTE 1 nunca encontrava nada e o script caía sempre na FONTE 2, que **infere** `Sf_zorl` por Charnock em vez de ler o valor real. Passa a aceitar `monan2_import_YYYYMMDD_HHMMSS.nc`, com o padrão antigo como retaguarda.

  Na FONTE 2 do mesmo script, a máscara real substitui o marcador de 271,35 K quando o arquivo a traz. Aquela heurística sempre foi frágil: água aberta genuína no ponto de congelamento — justamente a borda do gelo marinho — cai no mesmo valor e era apagada do mapa junto com o continente.

  **Quebra a linha de base por construção:** células de terra mudam de `0.0` para `-9,99e20` e o `nccmp -d` acusa diferença em todos os campos. Comparar somente as células de oceano contra a base congelada, exigir identidade exata ali, e só então recongelar com rótulo novo. Diferença em célula de oceano indica máscara deslocada — provavelmente convenção de longitude, já que o `mom6_import` usa 0 a 360 e o `monan2_import` usa −180 a +180.

  **Não compilado nem executado.** As modificações foram revisadas, não construídas: falta rodar `make` e conferir a fração de oceano registrada no log contra os ~69,2% que o `domain-mom6.bash` reporta para a grade atual.

- **Componente de gelo marinho (SIS2) integrado ao acoplador.** O SIS2 passa a existir como componente NUOPC próprio (`src/caps/ice/sis_cap_MONAN.F90`), com os conectores `MED -> ICE` e `ICE -> MED`, e não como subcomponente embutido no oceano via `combined_ice_ocean_driver`. Controlado por `use_sis2_dynamic` em `&nuopc_petlayout`; com a chave desligada (o padrão) nada é criado e o sistema é idêntico ao anterior.

  A lógica de partição de PETs foi **reescrita**, e não copiada da origem. Lá o gelo só existia dentro do ramo `if (is_concurrent)`, porque os eixos temporal e espacial ainda estavam colapsados em um só. Aqui ela vive sobre o eixo `pet_layout`, o que faz duas combinações passarem a funcionar: `shared` com gelo, e a sequência sequencial com gelo. Quando o gelo está desligado, `nIce` vale 0 e as contas recaem exatamente na divisão em dois blocos anterior, o que permite exigir saída NetCDF byte-idêntica ao baseline como teste de regressão.

  Regras acrescentadas, no mesmo princípio que motivou a correção do split: configuração lida e jogada fora sem aviso passa a ser erro. `ice_pet_count > 0` exige `use_sis2_dynamic`; `use_sis2_dynamic` exige `use_docn = .false.`; em `split` com gelo, `ice_pet_count` precisa ser explícito, porque o `select` do PBS é montado antes de o driver executar.

  **Pendência conhecida:** o caminho do `Si_ifrac` real do ICE até o MPAS não foi validado. O mediador copia `Si_ifrac_sis2` ponto a ponto, e a cópia só está correta se as grades coincidirem; falta um regrid dedicado, análogo ao `rh_ocn2atm` do `So_t`. Há guarda de formato que preserva o valor anterior e registra aviso quando as formas divergem. Tratar como recurso em avaliação.

- **Relógio compartilhado entre componentes (defeito grave).** `ESMF_Clock` é um tipo por referência. As rotinas que registram componentes passavam `driverClock` direto para `ESMF_GridCompSet`, o que fazia todos os componentes apontarem para o mesmo relógio físico. Como o NUOPC avança o relógio associado a cada componente depois do respectivo `Advance`, com três componentes Model o mesmo relógio recebia até três avanços por ciclo de `dt_coupling`. O sintoma observado foi a escrita de `monan2_import` passar de horária para a cada três horas: exatamente o fator 3 previsto.

  Cada componente e cada conector passa a receber uma cópia independente, criada com `ESMF_ClockCreate(driverClock, rc=rc)`. Ao acrescentar um componente ou conector novo, use `AddModelCompWithClock` ou `AddConnectorWithClock` em vez de chamar `NUOPC_DriverAddComp` diretamente: assim a cópia do relógio vem junto, sem depender de alguém lembrar de repetir o bloco.

- **Origem errada da fração de gelo no cap do SIS2.** O cap lia `Ice%part_size`, campo de fachada do acoplador preenchido apenas no caminho de acoplamento rápido, que nesta configuração permanece zerado. O estado real vive em `Ice%sCS%IST%part_size`, que é o que o próprio SIS2 usa para calcular área e massa; esse tem halos e categorias com base 0, então o deslocamento de índices passou a ser derivado da grade do próprio SIS2. A fórmula também mudou: era `1 - part_size(:,:,1)`, tratando o índice 1 como água aberta, quando o índice 1 é categoria de gelo.

- **`SharePolicyField="share"` indevido na exportação do cap do gelo.** Era o único campo de exportação do sistema a usar essa política. O campo saía correto da origem e chegava zerado ao mediador. Removida na exportação, alinhando ao cap do oceano, que usa `share` apenas nas importações. Do lado do mediador a política foi mantida, porque ali todos os campos de importação a usam e funcionam.

- **Contagem de passos com calendário aproximado (`esmApp.F90`).** O número de passos era estimado com aritmética manual, usando 365 dias por ano e 30 dias por mês, e esse número servia de limite do laço de execução. Para o intervalo de 2026-03-29 a 2026-04-30 dava 31 dias em vez de 32, porque março tem 31 dias, e a simulação parava cerca de 24 h antes da data final configurada. Passou a ser derivado do próprio intervalo ESMF (`stopTime - startTime`), que já respeita o calendário Gregoriano.

- **BUG-NC-06: `So_u`, `So_v` e `Sf_zorl` gravados apenas com `_FillValue`.** Os três campos faziam parte de `export_names` e por isso ganhavam variável no `mom6_import_*.nc`, com dimensões e atributos, mas não constavam de nenhum dos dois `select case` de `med_cap_netcdf.F90`. Caíam no `case default` e eram pulados pelo `cycle` antes de qualquer escrita.

  O modo de falha é o que torna o caso instrutivo: o arquivo passava por `q file` parecendo saudável, com as 18 variáveis listadas, e só se revelava ao tentar plotar, quando o GrADS respondia *all undefined values*. Valor ausente e valor zerado são coisas diferentes, e confundir os dois levou a investigar o oceano e a rotação de grade sem necessidade. O único sinal disponível antes disso era o `long_name` genérico das três variáveis, herdado do mesmo `case default`.

  Corrigido nos dois `select case`, com os campos internos `is%f_uocn_atm`, `is%f_vocn_atm` e `is%f_zorl_atm`. O `case default` passou a registrar aviso no log em vez de pular em silêncio. Conferido por script que os 18 nomes de `export_names` têm mapeamento.

- **Terceiro bloco de nós no `run_esmApp.jaci`.** Com `pet_layout = 'split'` e gelo ativo, o script pedia ao PBS apenas `ATM + OCN` processos, enquanto o `mpiexec` era lançado com o total. Para `-n 8` com atm=4, ocn=2, ice=2 o pedido era de 6 slots para 8 PETs, e o trabalho falharia na largada com mensagem do PALS sem relação aparente com gelo. O bloco do ICE entra no `select` e a opção `--ppn-ice` foi acrescentada por simetria. A ordem dos blocos segue a das faixas de rank atribuídas em `esm.F90`.

- **Endurecimento: o mediador declarava `InitializeDataComplete` sem verificar
  o dado (B-SEQINIT-01, revisto).** O `MED_cap.F90` marcava
  `InitializeDataComplete = "true"` na primeira chamada, incondicionalmente, e
  `NUOPC_IsAtTime` não era invocado em lugar nenhum do projeto. O laço de
  resolução de dependência de dados do driver NUOPC encerrava então após uma
  única passagem, e a correção da inicialização passava a depender inteiramente
  de o oceano já ter escrito `So_t` naquele instante.

  `InitializeDataComplete` foi dividida em duas fases. A fase A (geometria: os
  dois `FieldRegridStore` e a zeragem do `exportState`) roda uma única vez,
  guardada por `is%rh_created`. Entre as duas há um gate: `NUOPC_IsAtTime(So_t,
  startTime)` e, desde a revisão abaixo, também contagem global de células com
  SST em [270,310] K. Enquanto o dado não chega, o mediador declara
  `InitializeDataProgress="true"` e `InitializeDataComplete="false"`, forçando
  nova passagem do laço. A fase B faz o regrid de `So_u`/`So_v`, o regrid de
  `So_t` para `f_sst_atm` e publica a SST de t=0 no `exportState`, de modo que o
  `MED -> MPAS` da mesma passagem entregue SST física em vez de zero.

  **Comportamento observado (2026-08-14, rodadas de 8 PETs em ambos os modos).**
  O gate fecha exatamente uma vez, e o faz igualmente em `sequential` e em
  `concurrent`. Nos dois casos o `DataInitialize` do mediador é chamado ~75 ms
  antes do `InitializeDataComplete` do oceano. A conclusão é que **o laço não
  percorre a `RunSequence`**: ele chama os componentes na ordem de registro, e
  em `SetModelServices` os `NUOPC_DriverAddComp` aparecem como MPAS, MED, OCN —
  o mediador antes do oceano, independentemente do `coupling_mode`.

  Isso corrige uma afirmação anterior desta entrada, que atribuía a espera à
  ordem dos elementos da `RunSequence` e sustentava que o modo concorrente
  funcionava "por acidente de ordenação". Era falso: os dois modos se comportam
  igual neste ponto.

  Registre-se também o escopo real do ganho. Não houve sintoma observado que
  este gate corrija: em ambos os modos o `So_t` do passo 1 já saía correto
  antes dele, porque o conector `OCN -> MED` no topo do passo entrega o campo
  que o `mom_export` do oceano escreveu na inicialização. O gate é defesa contra
  a janela t=0 — o `MED -> MPAS` emitido durante a própria inicialização — e
  contra futuras mudanças de ordem de registro. É prática NUOPC correta, não a
  correção de um defeito flagrado.

  Uma otimização possível, deliberadamente **não** aplicada: registrar o OCN
  antes do MED faria o gate abrir já na primeira passagem. O laço converge em
  duas passagens de qualquer modo, o custo é de microssegundos, e mexer na ordem
  de registro de um driver que funciona não se paga.

- **Endurecimento: o gate aceitava campo carimbado e vazio.** O `mom_cap` aplica
  `NUOPC_SetTimestamp` a todos os campos do `exportState` em laço cego sobre o
  `itemNameList`, sem verificar quais o `mom_export` preencheu; um `So_t` nulo
  passaria no `NUOPC_IsAtTime`. O `MED_cap.F90` passa a exigir também valor
  fisicamente plausível, contando globalmente (`ESMF_VMAllReduce` sobre a VM do
  mediador) as células em [270,310] K — global porque um DE pode legitimamente
  conter apenas terra e gelo. Após cinco iterações sem dado físico, emite aviso
  alto e prossegue. O aviso é deliberado, e não aborto: o comportamento do laço
  de dependência de dados só foi caracterizado empiricamente, e derrubar
  execuções que hoje funcionam com base em modelo incompleto seria imprudente.

- **`mom_cap_MONAN.F90`: chamada de `ocean_model_init_sfc` antes do
  `mom_export` de t=0.** Acrescentada por precaução, **não** por defeito
  observado. A leitura estática sugeria que `ocean_public%t_surf` nunca era
  preenchido, já que a chamada de `convert_state_to_ocean_type` dentro de
  `ocean_model_init` está guardada por `if (present(gas_fields_ocn))` e o cap
  invoca `ocean_model_init` sem esse argumento. A medição desmentiu: o `So_t`
  bruto chega ao mediador com até 303,8 K, ou seja `t_surf` é preenchido por
  alguma via não identificada. A chamada é idempotente e inofensiva; quem
  preferir árvore mínima pode omiti-la sem consequência.

- **Correção: evaporação saturada quando `psl` é nula (BUG-CALC-06).** Em
  `med_bulk_ncar.F90`, o denominador de `qsat` era `max(psl(i,j), 1.0)` — uma
  proteção contra divisão por zero que produz resultado absurdo em vez de pular
  a célula: com `psl = 0` o divisor vira 1 Pa em lugar de ~101325 Pa, `qsat` sai
  cinco ordens de grandeza alto e `Foxx_evap` satura no clamp de +1e-4 kg/m²/s
  no globo inteiro. O fluxo saturado não ficava no diagnóstico: em
  `coupling_mode='sequential'` o `MED -> OCN` o entregava ao MOM6 antes do
  avanço do oceano. Acrescentada a guarda `if (psl(i,j) < 5.0e4) cycle`,
  simétrica às de `lwdn` (BUG-CALC-03) e `tas` (BUG-CALC-04); pressão ao nível
  do mar nunca desce de ~870 hPa, então 500 hPa é limiar seguro para ausência de
  dado. Confirmado nas figuras de 2026-08-14: `Foxx_evap` zerado no passo 1 e
  fisicamente correto (±8 mm/d, máximos subtropicais) no passo 2.

- **Documentado: o primeiro passo de acoplamento é incompleto nos dois modos.**
  Em `sequential` o mediador é o 3º elemento da `RunSequence` e calcula os
  fluxos antes do primeiro avanço do MPAS; radiação, precipitação e pressão saem
  nulas no passo 1, enquanto momento e calor sensível já são válidos. Em
  `concurrent` o mediador é o último e o arquivo do passo 1 sai completo, mas a
  forçante que o oceano de fato consumiu naquela hora é o `exportState` zerado da
  inicialização, que não aparece em figura alguma. As duas situações são
  simétricas; nenhum dos modos entrega forçante completa na primeira hora. A
  partir do passo 2 tudo está completo, e uma hora de radiação nula é desprezível
  frente à inércia térmica da camada de mistura — daí a opção por documentar em
  vez de chamar radiação na inicialização do MPAS.

- **`postproc_mom6_import.py` v8.3: rodapé de consumo por modo.** A mesma figura
  "passo N" significa coisas diferentes — em `sequential` mostra os fluxos que o
  MOM6 consome naquele passo; em `concurrent`, os do passo seguinte. Comparar
  passo 1 com passo 1 entre modos é erro, e custou uma investigação inteira. O
  script passa a ler `coupling_mode` da `nuopc.input` e anotar o pareamento
  correto (sequencial N+1 × concorrente N) no rodapé de cada figura.

- **Correção (`test-*.bash`): aborto silencioso do `wait` sob `set -e`.** A
  detecção de fim de processo era `wait "$pid" 2>/dev/null; ec=$?`. Como comando
  isolado, um retorno diferente de zero dispara o `set -e` e encerra o script
  antes de `ec` ser avaliado — sem veredito, sem análise, sem mensagem. O único
  caso que os testes existem para diagnosticar era o único que não conseguiam
  relatar. Reescrito como `ec=0; wait "$pid" 2>/dev/null || ec=$?`, e acrescentado
  aviso aos 2 s com as primeiras linhas do stdout, já que morte instantânea é
  lançador recusado ou ambiente incompleto, nunca deadlock.

- **Correção (`test-sequential-split.bash`): faltava a guarda de `LAYOUT` do
  MOM6.** O pré-check validava a partição METIS do MPAS mas não o requisito
  simétrico do oceano. Com `pet_layout='split'` o MOM6 recebe exatamente
  `ocn_pet_count` PETs, e o `mpp_define_domains` aborta se `LAYOUT(1)*LAYOUT(2)`
  não bater — o job morria em ~1 s num rank do bloco OCN, com mensagem que não
  mencionava PET nem LAYOUT, e as verificações seguintes produziam diagnósticos
  enganosos. O script agora lê `LAYOUT` do `MOM_input` e aborta no nó de login,
  sugerindo `--ocn` e `-n` coerentes. Acrescentadas também as formas curtas
  `-q`/`-A`, alinhadas ao `qsub`.

- **Correção (`run_esmApp.jaci`): partição METIS e `select` heterogêneo presos
  ao modo, não ao layout.** Duas decisões consultavam `coupling_mode` quando o
  que importava era `pet_layout`: o dimensionamento da partição METIS do MPAS
  (`atm_pet_count` em split, `-n` em shared) e a guarda `CONC_PER_COMP`, que
  emite o `select` com blocos de nós só-ATM e só-OCN. Com `sequential + split`
  as duas erravam. A guarda `atm_pet_count + ocn_pet_count == -n`, antes restrita
  a `concurrent`, passa a valer para qualquer split. Acrescentada validação de
  `pet_layout` desconhecido e da combinação `concurrent + shared`, ambas com
  aborto ainda no nó de login, e uma linha `ACOPL` ao banner de dentro do job:
  sem ela, um tempo de parede anotado hoje seria ambíguo depois, já que 2176
  PETs podem significar quatro configurações com custos bem diferentes.

- **Correção (`MED_cap.F90`): último `ESMF_VMGetGlobal` dentro de rotina de
  componente.** Em `fill_ifrac_from_oisst`, o `ESMF_VMBroadcast` do arquivo
  OISST era coletivo sobre a VM **global**. Hoje isso funciona por coincidência,
  porque o mediador roda em todos os PETs nos dois layouts, mas era o único
  ponto que não recebera a correção aplicada em `DATM_cap.F90`, `DOCN_cap.F90` e
  `docn_cap_netcdf.F90` na v13.1. Trocado por `ESMF_VMGetCurrent`, que devolve a
  VM do componente e torna `rootPet=0` local ao MED. O modo de falha evitado é
  deadlock, não erro: se o mediador algum dia ganhar uma `petList` própria, os
  PETs de fora nunca entrariam no broadcast e os de dentro ficariam bloqueados.

- **Correção (`esm.F90`): `rc` de `config_read` descartado.** A chamada em
  `SetModelServices` gravava o retorno em `rc`, que a chamada NUOPC seguinte
  sobrescrevia antes de qualquer teste. Um `rc = 2` — configuração inválida —
  passava despercebido nesse ponto. Passa a usar variável própria (`cfg_rc`) e a
  abortar com mensagem no log ESMF.

- **Novo: `test-sequential-split.bash`.** Smoke test da combinação
  `sequential + split`, ao lado do `test-concurrent.bash` e no mesmo padrão de
  duas fases (submissão no nó de login, execução dentro do job). Além das
  verificações herdadas — partição aplicada, inicialização dos três componentes,
  primeiro passo sem deadlock nos coletivos —, inclui a que distingue os dois
  modos: as janelas `Run` de ATM e OCN não podem se sobrepor no tempo. A
  necessidade é direta: `sequential + split` e `concurrent + split` produzem
  exatamente os mesmos conjuntos de PETs, e só os carimbos de tempo dos logs
  separam um do outro; sem essa checagem, um erro que montasse a *RunSequence*
  concorrente passaria como sucesso. A medição une as janelas de cada bloco de
  PETs (as de PETs irmãos se sobrepõem entre si, e isso é esperado) e mede a
  interseção das duas uniões, com tolerância ajustável por `--overlap-tol`.
  Requer `python3` no nó de execução; sem ele a verificação é pulada com aviso,
  e as demais seguem valendo. O teste também avisa quando falta o
  `x1.*.graph.info.part.<atm>`, cuja ausência apareceria como `initfail` sem
  indicar a causa.

- **Correção (`test-concurrent.bash`): baseline quebrado pela nova validação.**
  O `--baseline` gerava uma config `sequential` **com** `atm_pet_count` e
  `ocn_pet_count`, que passou a ser erro. O `gen_config` ganhou um terceiro
  argumento (`layout`) e zera as contagens em `shared`. Os marcadores de log
  procurados foram atualizados para o formato novo (`layout SPLIT (execucao
  CONCURRENT)`), mantendo o antigo por alternativa, para que o mesmo teste sirva
  na comparação com binários anteriores.

- **Correção (`analisa_balanceamento_pets.py`): detecção de modo cega ao novo
  formato de log.** As expressões procuravam `modo CONCURRENT` / `modo
  SEQUENTIAL`, que deixaram de existir. Passa a ler os dois eixos separadamente,
  aceitando também o formato antigo. Duas mudanças de conteúdo, e não só de
  sintaxe: a ressalva de extrapolação da partição sugerida passou a depender do
  *layout* (é `shared` que mede cada componente com todos os PETs, e portanto
  extrapola; `sequential + split` já fornece medidas de uma partição real); e a
  execução deixou de ser inferida quando não anunciada, porque conjuntos
  disjuntos de PETs não distinguem sequencial de concorrente, e assumir
  concorrente faria o relatório anunciar um ganho de tempo de parede
  possivelmente inexistente.

- **Documentação: `nuopc.input`, README e demais documentos sincronizados.** O
  Grupo 7 da `nuopc.input` foi reescrito com a tabela das quatro combinações e
  as duas regras (soma igual a `-n` em split; contagens zeradas em shared), e o
  bloco ativo ganhou `pet_layout = 'split'`, que é o que torna coerentes o
  `atm_pet_count = 2048` e o `ocn_pet_count = 128` que já estavam ali. A §6.2 do
  README do `MONAN-Coupler` foi reescrita em
  `README-secao-6.2-atualizada.md` (o arquivo alvo pertence à outra árvore).
  Ajustadas ainda as menções a "modo concurrent" em `domain-mom6.md`,
  `domain-mom6.bash` e `mascara-cap-nuopc.md`, onde o que se descrevia era, na
  verdade, o efeito do *layout*.

- **Documentação: seções de Conclusão em `SMT-Jaci.md` e
  `MULTINO-run_esmApp.md`.** Os dois documentos terminavam direto no glossário,
  sem fechar a narrativa antes do material de referência. Acrescentada, em cada
  um, uma seção **Conclusão** entre o corpo técnico e o glossário, com as
  seções seguintes renumeradas (`SMT-Jaci.md`: Glossário passa a ser a seção
  11 e Referências internas a 12; `MULTINO-run_esmApp.md`: Glossário passa a
  ser a seção 10). Nenhuma referência cruzada de seção, em nenhum documento,
  apontava para os números antigos, então a renumeração não quebrou nada.
- **Correção de tradução: `alocação preguiçosa` → `alocação por demanda`.**
  A tradução literal de *lazy allocation* soava informal e não é o termo
  consagrado na literatura de sistemas operacionais em português. Corrigido em
  `SMT-Jaci.md` e neste changelog, mantendo `(*lazy allocation*)` como
  referência entre parênteses nos dois casos.
- **Documentação: `README.md` sincronizado com `docs/`.** A árvore de estrutura
  ainda listava apenas `CHANGELOG.md` e `notas-standalone.md` em `docs/`, quando
  o diretório já reúne seis documentos. Acrescentada a seção **Documentação**,
  com uma tabela do assunto de cada arquivo e um roteiro de "por onde começar"
  por tarefa, além da ressalva de que os scripts descritos em
  `MULTINO-run_esmApp.md` e `SMT-Jaci.md` pertencem à árvore do `MONAN-Coupler`,
  e não a este repositório. Nova seção **Depois de instalar**, que encaminha do
  `bin/esmApp` recém-construído até a primeira submissão, com os três pontos que
  costumam surpreender: a contabilidade de `ncpus` em cores físicos, a partição
  METIS dimensionada por `atm_pet_count` no modo concurrent e a incompatibilidade
  do `mask_table` com o cap NUOPC. Travessões removidos, conforme o padrão do
  projeto.
- **Documentação: nova nota técnica `SMT-Jaci.md`.** Registra a caracterização
  do SMT nos nós de cálculo do Jaci e a medição do seu efeito sobre o sistema
  acoplado, em onze seções: o mecanismo do SMT, a caracterização do hardware com
  os comandos e as saídas obtidas, a contabilidade das filas com a verificação
  experimental por `qsub`, a metodologia da medição, os resultados em tempo de
  parede e em tempo de máquina, a interpretação por componente, as limitações de
  escopo, as decisões decorrentes, o procedimento de reprodução, um glossário e
  as referências internas. Toda a aritmética das tabelas foi conferida.
- **Novo (`run_esmApp.jaci`): `TOPO` e `REGIME` no banner de dentro do job.** As
  duas linhas existiam apenas no resumo impresso no nó de login, que não é
  capturado pela diretiva `#PBS -o` e, portanto, não chegava ao
  `esmApp_run.log`. Sem elas, a autoverificação do `mede_smt.py` ficava inerte
  justamente nas duas checagens mais fortes. O banner do job passa a imprimir a
  topologia derivada do `PBS_NODEFILE` e o regime de ocupação do core. Quando o
  `PBS_NODEFILE` não é legível, o regime é declarado `indeterminado`, e o
  `mede_smt.py` pula a verificação com aviso em vez de acusar troca de
  diretórios. As expressões do `mede_smt.py` passam a aceitar tanto `TOPO:`
  quanto `TOPO =`, cobrindo os dois formatos.
- **Novo (`run_esmApp.jaci`): procedência do build no banner do job.** Um tempo
  de parede anotado hoje não era reproduzível depois, por não haver registro de
  qual revisão do código nem de qual ESMF o produziram. O banner passa a
  imprimir a revisão (`git describe --tags --always --dirty` do
  `COUPLER_ROOT`), a versão do ESMF (lida de `ESMF_VERSION_STRING` no
  `ESMFMKFILE`) e a data de compilação do executável. Tudo tolerante a
  ausência: fora de um clone git, sem `git` no `PATH` ou sem `esmf.mk`, o campo
  vira `?` em vez de interromper o job.
- **Correção (documentação): diagrama impossível na seção 4 do
  `MULTINO-run_esmApp.md`.** O exemplo do nó misto usava `atm=512, ocn=128`,
  mas 512 é múltiplo de 256 e a distribuição natural já sai alinhada, de modo
  que o nó misto ilustrado não pode ocorrer. Substituído por `atm=384,
  ocn=128`, em que a mistura de fato acontece, e acrescentada a observação de
  que a consolidação custa um nó a mais (de dois para três) e de que os blocos
  de 192 ainda atravessam a fronteira NUMA de 128 cores, que é a razão de o
  `plan-layout.py` marcar 384 como quebrado.
- **Documentação: escopo do resultado do SMT.** Acrescentada a subseção
  explicitando que os 11,2% valem para 512 PETs, malha `x1.40962` e modo
  `sequential`, e não são propriedade do sistema. Como o mecanismo é disputa
  pelo cache L2, subdomínios menores (por exemplo com 2176 PETs) podem reduzir
  ou inverter a penalidade, enquanto a malha `x1.163842` a agravaria. Registrada
  também a hipótese não testada de `--ppn-atm 256` com `--ppn-ocn 512` no modo
  concurrent. Novo slide "O que ainda não sabemos" na apresentação, com as
  quatro ressalvas.
- **Novo (`plan-layout.py`): alinhamento com os dois patamares de limite do
  `run_esmApp.jaci`.** O planejador mantinha um único `--ppn-max`, enquanto o
  script já separava `PPN_PHYS` de `PPN_HARD`, e por isso podia imprimir um
  `select` que o script recusaria. Como a razão de existir do planejador é que
  o `select` impresso seja idêntico ao submetido, a divergência atacava a
  premissa da ferramenta. Passa a ter `PPN_PHYS_DEFAULT = 256` e
  `PPN_HARD_DEFAULT = 512`, com `--allow-smt` e a mesma guarda aplicada a
  `--ppn-max`, `--ppn-atm` e `--ppn-ocn`, além da linha `regime` na saída, nos
  modos concurrent e sequential. Corrigido também o texto de ajuda de
  `--ppn-ocn`, que anunciava padrão 128 quando o valor é 256.
- **Novo (`mede_smt.py`): autoverificação a partir do conteúdo dos logs.** O
  script confiava apenas no nome do diretório: trocar `logs.A` por `logs.B`
  inverteria a conclusão sem qualquer sinal, num resultado que passou a
  sustentar uma decisão de projeto. Passa a extrair o modo de acoplamento da
  linha `ESM: modo ...` do log de PET e, quando o banner do job estiver
  presente no diretório, a topologia e o regime de ocupação do core. Com isso
  aborta quando A e B têm números de PETs diferentes, quando os modos divergem,
  quando as rodadas de uma configuração usam números de nós distintos e,
  sobretudo, quando o `REGIME` declarado contradiz a configuração, indicando
  diretórios trocados. Avisa quando as rodadas estão em `CONCURRENT`, modo em
  que o teste do SMT é confundido pelo balanceamento entre os blocos. O número
  de nós lido do banner prevalece sobre `--nos-a` e `--nos-b`, com aviso.
  Verificações ausentes são puladas, nunca inventadas.
- **Novo utilitário (`mede_smt.py`): comparação controlada do efeito do SMT.**
  Lê os logs de PET das rodadas com e sem uso do SMT (padrão `logs.A1..A3` e
  `logs.B1..B3`) e emite a tabela comparativa por componente, com a razão B/A,
  além de CSV (`--csv`) e gráfico de barras (`--grafico`). Segue o critério já
  adotado nas notas técnicas do grupo: **soma** das durações dos pares
  `Run intro` / `Run extro` dentro de cada passo, e não média por chamada, para
  não subestimar componentes que subciclam; e **máximo entre os PETs**, e não
  média, porque o grupo é limitado pelo processo mais lento na barreira
  coletiva. O primeiro passo é descartado por padrão (`--descartar`), por conter
  alocação por demanda e o custo inicial dos conectores. O casamento dos
  marcadores exige o ponto final da linha, o que descarta as linhas de
  `StateLog`, que repetem o texto `Run intro` seguido de `{IS}:` e não delimitam
  a chamada. Avisa sobre marcadores órfãos e sobre divergência no número de
  pares entre PETs, truncando no mínimo comum. O veredito é declarado
  inconclusivo quando a diferença não supera a dispersão das repetições.
  **Normalização pelo número de nós.** Na primeira versão o script comparava
  apenas *wall-clock time*, o que embute um confundimento sério: com o mesmo
  número de PETs, B usa metade dos nós de A e, portanto, metade dos cores
  físicos, de modo que B seria 2,00 vezes mais lento mesmo com SMT
  perfeitamente neutro. O efeito atribuível ao SMT é o excesso sobre esse
  fator. O script passa a reportar também o custo em **nó vezes segundo por
  passo** (opções `--nos-a` e `--nos-b`), que é a grandeza comparável entre as
  duas configurações, e o veredito separa *wall-clock time* de custo de máquina.
  **Propagação de erro corrigida.** A incerteza da razão era calculada como
  `(dp_A + dp_B) / media_A`, dividindo o desvio de B pela média de A. Como B e A
  têm magnitudes diferentes por construção (B é cerca de duas vezes maior), isso
  inflava o ruído: os 12,5% relatados eram, de fato, 7,7% em soma linear ou 5,4%
  em quadratura. O cálculo passa a dividir cada desvio pela sua própria média, e
  o veredito ganhou o estado intermediário `MARGINAL`, para efeitos que superam
  o critério em quadratura mas não a soma linear.
  Na medição de 06/08/2026 (512 PETs, três repetições), o *wall-clock time* deu
  B/A = 2,22, mas o custo de máquina deu 1,11, com sinais opostos por
  componente: MED 0,97 e OCN 0,86, que se beneficiam do SMT por terem mais
  espera de memória, contra MPAS 1,20, penalizado por já saturar a FPU. Como o
  MPAS responde por cerca de 69% do passo, o saldo é negativo, e o efeito de
  11,2% supera a incerteza de 7,7%.
  O reconhecimento dos logs aceita tanto `PET000.esmApp.log`, que é o nome
  gerado pelo ESMF no Jaci, quanto `PET000_esmApp.log`, variante que aparece
  após transferências, e exige o número do PET no nome, o que descarta o
  `esmApp_run.log` presente no mesmo diretório. A ordenação é numérica, e não
  lexicográfica. A opção `--padrao` permite informar outro glob, e a mensagem de
  erro passa a distinguir diretório inexistente de diretório sem logs
  reconhecidos, listando o que encontrou.
- **Novo (`run_esmApp.jaci`): `--allow-smt` e limite de PET/nó parametrizado.**
  A constante única `PPN_MAX=256` colapsava dois conceitos distintos, o que o
  hardware aceita e o que se recomenda, e por isso impedia qualquer medição do
  efeito do SMT. Passam a existir `PPN_PHYS=256` (cores físicos, limite
  recomendado e padrão) e `PPN_HARD=512` (CPUs lógicas, limite absoluto do
  hardware). Valores de `--ppn` entre 257 e 512 exigem `--allow-smt` e, sem a
  opção, o script aborta explicando que acima de 256 cada core passa a receber
  dois ranks. Acima de 512 o erro é o limite do hardware, com ou sem a opção. O
  modo automático (`--ppn 0`) nunca ultrapassa `PPN_PHYS`, de modo que o padrão
  jamais entra em SMT por acidente. O resumo de topologia ganhou a linha
  `REGIME`, que registra se o job rodou com um rank por core ou com SMT ativo:
  sem ela, um *wall-clock time* anotado hoje seria ambíguo depois, já que 512 PETs
  podem significar dois nós ou um nó com SMT. A guarda de fila não precisou de
  ajuste, pois compara `NPES` com `resources_max.ncpus` e a aritmética fecha nos
  dois regimes.
- **Correção (`run_esmApp.jaci`): partição METIS dimensionada pelo número
  errado em modo concurrent.** Com `-n 2176` e `atm_pet_count = 2048` o
  pré-check exigia `x1.*.graph.info.part.2176` em vez de `.part.2048`, que
  estava presente no diretório do experimento. A lógica de escolha estava
  correta (sequential usa `-n`, concurrent usa `atm_pet_count`); o defeito era
  a leitura da `nuopc.input`, que caía silenciosamente para `sequential` em
  três situações:
  - **Caixa do valor.** `_nuopc_get` usava `grep -i` para a chave mas comparava
    o valor com `== "concurrent"`, sensível a maiúsculas. `'CONCURRENT'` ou
    `'Concurrent'`, ambos válidos em namelist Fortran, viravam sequential. O
    valor passa a ser normalizado para minúsculas.
  - **Ausência de escopo de grupo.** A busca era global no arquivo, com
    `head -1`, então uma ocorrência de `coupling_mode` anterior ao
    `&nuopc_petlayout` (grupo antigo, bloco de exemplo) vencia a definição
    real. Novo `_nuopc_get_in`, que lê a chave **dentro** do grupo indicado,
    insensível a caixa, ignorando comentários `!` e aceitando os terminadores
    `/` e `&end`, com recuo para a busca global em `nuopc.input` legados sem o
    grupo.
  - **Recuo silencioso.** Um `coupling_mode` com erro de digitação virava
    sequential sem qualquer sinal. Agora é erro explícito, listando os valores
    aceitos.
  Acrescentadas duas linhas `INFO` informando de onde saiu o número de
  partições (`atm_pet_count` em concurrent, `-n` em sequential), e a mensagem
  de partição faltante passa a listar as partições presentes no diretório,
  distinguindo "falta gerar" de "dimensionado pelo número errado".
- **Execução multinó no `run_esmApp.jaci`: contabilidade de `ncpus` e posse do
  nó.** O gerador do `.pbs` deriva a topologia de `-n` (`NNODES x PPN`,
  `place=...`), substituindo o antigo `select=1`, que prendia qualquer job a um
  único nó. O levantamento do sítio (`lscpu`, `pbsnodes -a`, `qstat -Qf`,
  05/08/2026) fixou os parâmetros: o nó de cálculo `cn-0001..cn-0104` tem
  **256 cores físicos** (2 sockets x 128 Zen5) com SMT ligado, expondo 512 CPUs
  lógicos e ~754 GB, e o `pbsnodes` reporta `resources_available.ncpus = 512`.
  O limite das filas, porém, é contado em **cores físicos**: a `pesqextra`
  declara `resources_max.ncpus = 7680` para `resources_max.nodes = 30`, isto é
  256 por nó, e os jobs em execução aparecem com `ncpus/nodect = 256`. Logo o
  `select` mantém `ncpus = mpiprocs = PPN <= 256`; pedir `ncpus = 512` gastaria
  o limite da fila em dobro e limitaria o job a 15 nós em vez de 30.
  - **`place=scatter:excl` passa a ser o padrão** (antes `scatter`). Reservando
    256 num nó que anuncia 512 lógicos, o `scatter` puro deixa metade do nó
    aparentemente livre e autoriza o PBS a alocar outro job ali, com disputa de
    memória e de largura de banda no mesmo socket. Com `:excl` o nó é exclusivo
    e o SMT fica ocioso, que é o desejado para MPAS/MOM6.
  - **Guarda de fila.** Constantes `QUEUE_LIMITS_*` e a rotina `_queue_guard`
    conferem NPES, número de nós e *walltime* contra o `resources_max` da fila
    antes do `qsub`, abortando com mensagem explícita. Fila desconhecida gera
    aviso e prossegue. Limite prático do acoplado na `pesqextra`:
    30 nós x 256 PET/nó = 7680 PETs, coincidindo com o `resources_max.ncpus`.
  - **Padrão de 256 PET/nó** (nó físico cheio, 1 rank por core, sem SMT) e
    **sem reserva de memória**: `--mem` e `--mem-per-pet` são opcionais, e a
    resposta a OOM (`exit 137/143`) é reduzir `--ppn` ou reservar `--mem`.
    Novas opções `--ppn`, `--place`, `--mem`, `--mem-per-pet`.
  - **Modo concurrent com consolidação por componente:** `select` heterogêneo
    alinhado a fronteiras de nó, de modo que nenhum nó fique misto (ATM+OCN);
    opções `--ppn-atm`, `--ppn-ocn` e `--pet-order`.
  - **Nós auxiliares documentados:** `aux01..aux10`, com `ncpus = 256` e
    ~1,5 TB, alcançados pela fila `aux` (`worktype = aux`). Destinam-se a pré e
    pós-processamento (geração de malha, particionamento METIS), não ao
    acoplado. O roteamento entre classes de nó é feito pelo recurso `worktype`,
    o que explica o `Qlist` vazio no `pbsnodes`.
- **Novo utilitário (`plan-layout.py`): planejador de topologia.** Reproduz,
  fora do job, a lógica de consolidação do `run_esmApp.jaci`, imprimindo o
  mesmo `select`, para escolher `atm_pet_count` e `ocn_pet_count` antes de
  editar a `nuopc.input`. Modos `--atm/--ocn`, `--total` com `--ratio`,
  `--sweep`, `--suggest` e `--sequential`. Acompanha a mesma tabela de limites
  de fila (opção `--queue`, padrão `pesqextra`), com o status `excede fila` na
  varredura. Corrigido o padrão de `--ppn-ocn 0`, que resolvia para metade do
  nó em vez de nó cheio, divergindo do `run_esmApp.jaci`.
- **Documentação.** Novo `docs/MULTINO-run_esmApp.md` (hardware do sítio,
  contabilidade de `ncpus`, topologia sequential e concurrent, tabela de filas
  e limites, planejador, boas práticas e glossário) e as subseções
  correspondentes no `README-MONAN-Coupler.md`. Acrescentado o critério de
  alinhamento NUMA: com 2 domínios de 128 cores por nó, cortes de
  `atm_pet_count`/`ocn_pet_count` em múltiplos de 128 mantêm cada componente
  dentro de sockets inteiros.
- **Correção (`mom_cap_MONAN.F90`): campos de importação sem estampilha de
  tempo.** No primeiro passo de acoplamento, o `CheckImportTolerant` comparava
  o `TimeStamp` de cada campo importado sem que ele tivesse sido definido: na
  RunSequence o OCN roda antes do conector MED para OCN, e o
  `NUOPC_GetTimestamp` do NUOPC 8.9.1 retorna `ESMF_SUCCESS` sem preencher o
  `ESMF_Time` (não existe o argumento `isValid=`). O resultado eram dois
  `ERROR` por campo (`ESMF_TimeLT` e `ESMF_TimeGT`, "Object Set or SetDefault
  method not called"), 28 linhas por execução com 14 campos importados. Sem
  efeito numérico, mas poluindo o log e mascarando erros reais. A
  `InitializeDataComplete` passa a estampilhar os campos de importação com
  `startTime`, como já fazia com os de exportação.
- **Correção (`domain-mom6.bash`): saída incoerente em `--no-mask`.** A coluna
  `PETs` da tabela de candidatos era sempre calculada como
  `NIPROC * NJPROC - Nmask`, mesmo em `--no-mask`, exibindo 121 para o `16x8`
  quando o resultado efetivo, informado três linhas abaixo, era 128. Agora a
  coluna respeita o modo, o rótulo da coluna de blocos secos alterna entre
  `MASCAR.` (eliminados) e `SECOS` (mantidos), e uma nota sob a tabela explicita
  que em `--no-mask` a contagem é informativa. Corrigido também o exemplo do
  `--help` e do cabeçalho, que apresentava `--target-eff` como receita para um
  run concorrente, justamente a configuração incompatível com o cap; o exemplo
  do acoplado passa a usar `--no-mask --pes N`, e o do `--target-eff` fica
  identificado como standalone. Colunas documentadas em `docs/domain-mom6.md`,
  seção 7.2.
- **Ressalva em aberto (`domain-mom6.bash`): convenção de fronteiras difere da
  do FMS.** O script distribui as sobras da divisão nos primeiros blocos; o
  `mpp_compute_extent` as distribui simetricamente (`Y-AXIS = 53 52 53` para
  158 pontos em 3 blocos, contra `53 53 52` do script). As fronteiras internas
  ficam deslocadas em um ponto e o conjunto de blocos secos pode divergir: em
  `15x9` o script marca `(8,8)` onde o FMS teria `(9,7)`. **No acoplado com
  `--no-mask` o efeito é nulo** (nenhum `mask_table` é lido); no uso standalone,
  porém, um bloco com oceano pode ser mascarado por engano. A distribuição
  simétrica está comprovada pelo log, mas o algoritmo exato ainda não foi
  conferido contra o fonte do `mpp_domains_mod`. Documentado em
  `docs/domain-mom6.md`, seção 5.
- **Documentação.** Novo `docs/mascara-cap-nuopc.md`, explicação didática e
  autocontida do problema da máscara: glossário PE/PET/DE, por que o split de
  comunicador não está envolvido, a diferença entre representação densa e
  esparsa no ESMF, como reconhecer o sintoma e as duas rotas de correção do
  cap, com a estimativa de ganho por número de PETs. A seção 2 do
  `docs/domain-mom6.md` foi reduzida a um resumo com ponteiro para ele.
- **Correção (incidente do LAYOUT 43x3, 22/07/2026).** Run de 256 PETs em modo
  concorrente (128 ATM + 128 OCN) abortava com SIGSEGV no PET 171 logo após
  `COMPLETED MOM INITIALIZATION`. Causa: o `mask_table` gerado para
  `LAYOUT = 43, 3` remove o bloco `(1,3)` da decomposição, e o cap NUOPC do
  MOM6 monta o `deBlockList` do `ESMF_Grid` apenas com os domínios dos PETs
  vivos. O espaço de índices `[1..180] x [1..158]` fica com um buraco de
  5 x 53 células; `ESMF_DistGridCreate` e `ESMF_GridCreate` aceitam em
  silêncio, e a falha só emerge no conector `OCN-TO-MED`, em
  `ESMF_GridToMesh`: `ESMCI_Mesh.C, line:1786: Bad processor number!`.
  - Configuração corrigida: `LAYOUT = 16, 8` (produto exato = 128 PETs do OCN)
    com `MASKTABLE` comentado em `MOM_input` e `SIS_input`.
  - `domain-mom6.bash`: **filtro de forma** com `--min-tile` (padrão 9, que é
    `2*NIHALO+1`, o halo do domínio `MOM_MOSAIC`) e `--max-aspect` (padrão
    4,0). O `43x3` tinha blocos de 4,2 pontos, menores que o próprio halo, e
    passava sem qualquer alerta.
  - `domain-mom6.bash`: a varredura do `--target-eff` deixa de aceitar o
    primeiro `EFF` que bate. O novo modo `scan` do awk devolve todos os pares
    de fatores aprovados no filtro para cada nº de blocos, e vence o de melhor
    forma em **toda** a faixa. Na grade 180 x 158, o alvo 128 passa a resolver
    para `15x9` (blocos de 12,0 x 17,6; nmask = 7) em vez de `43x3`.
  - `domain-mom6.bash`: novo `--no-mask`, que escolhe o melhor `LAYOUT` com
    produto exatamente igual aos PETs do oceano e não gera `mask_table`,
    comentando com `!` uma diretiva `MASKTABLE` remanescente nos arquivos de
    entrada. É o único modo compatível com o cap NUOPC atual.
  - `domain-mom6.bash`: aviso explícito sempre que um `mask_table` com
    `nmask > 0` é produzido, indicando que ele serve ao MOM6+SIS2 standalone,
    não ao acoplado.
  - Pendência em `mom_cap_MONAN.F90`: para suportar `mask_table`, o
    `deBlockList` precisa cobrir todo o espaço de índices, com DEs adicionais
    para os blocos mascarados mapeados a PETs existentes via `petMap`
    (o `ESMF_DELayout` aceita mais de um DE por PET).
- **Novo utilitário (`domain-mom6.bash`): decomposição de domínio do MOM6+SIS2.**
  Calcula um `LAYOUT` (NIPROC, NJPROC) equilibrado e gera o `mask_table` do FMS,
  eliminando os blocos 100% terra. Os PETs efetivos passam a ser
  `EFF = NIPROC * NJPROC - Nmask`, valor que deve casar com os PETs que o
  oceano realmente recebe (o total do run em `sequential`; apenas
  `ocn_pet_count` em `concurrent`), evitando o erro fatal
  `fms2_io(parse_mask_table_2d): mpp_npes() .NE. layout(1)*layout(2) - nmask`.
  - Três modos: `--pes N` (fatora N e ordena os candidatos por razão de aspecto,
    divisão exata e tamanho mínimo de bloco), `--layout NI,NJ` (explícito) e
    `--target-eff N` (varre `--pes N..N+search-range` até obter `EFF` exato,
    já que o nº de blocos mascarados depende da **forma** do `LAYOUT`, não só
    do produto).
  - Implementação **100% shell**: `ncdump` (módulo `cray-netcdf`) e `awk`
    (POSIX), sem dependência de Python, numpy ou netCDF4. Não depende do
    `COUPLER_ROOT` nem do ESMF: opera apenas sobre a topografia.
  - Núcleo: **soma de prefixos 2D** (imagem integral) do campo binário de
    oceano, construída uma única vez; a contagem de oceano em cada bloco
    candidato custa O(1), o que viabiliza a varredura do `--target-eff`.
  - Detecção automática da variável (`depth`, `D`, `wet`, `mask`, ou
    `--depth-var`) e das dimensões pelas duas últimas da declaração (robusto a
    `ny,nx` / `lat,lon` / `grid_y,grid_x`). Limiar de oceano por `--min-depth`
    para profundidade e 0,5 para máscara.
  - Integração opcional com o experimento: `--input-dir` copia o `mask_table`
    para `INPUT/`; `--mom-input`/`--sis-input` reescrevem `LAYOUT` e
    `MASKTABLE` com backup `.bak.<timestamp>`; `--dry-run` suprime cópia e
    edição (o `mask_table`, sendo o próprio resultado do cálculo, ainda é
    gravado). Avisos para blocos pequenos, divisão inexata e `Nmask = 0`.
  - Reaproveita o `include.bash` do instalador para o log padronizado, com
    *fallback* próprio quando ausente.
- **Documentação.** Novo `docs/domain-mom6.md` (algoritmo detalhado: soma de
  prefixos, escore dos candidatos, formato do `mask_table`, custo e armadilhas)
  e `README.md` com a subseção "Decomposição de domínio do MOM6+SIS2", logo
  após as partições METIS do MPAS, mais as entradas correspondentes na árvore
  de estrutura e na tabela "Onde mexer".

- **Correção (ESMF externo no MONAN-A).** A etapa 1 falhava ao compilar
  `mpas_timekeeping.F` (`timeStringISOFrac`/`h=` não reconhecidos) porque o
  `-DMPAS_EXTERNAL_ESMF_LIB` resolvia `use ESMF` para o *stub* interno do MPAS
  (`src/external/esmf_time_f90`) em vez do ESMF 8.9.1 real. O Makefile do
  MONAN-Model só injeta o ESMF real quando `ESMF_MOD` e `ESMF_LIBDIR` estão no
  ambiente — e os scripts não as exportavam.
  - `sites/site-jaci.bash` e `sites/site-template.bash`: passam a **derivar e
    exportar** `ESMF_MOD` (dir do `esmf.mod`, via `ESMF_F90COMPILEPATHS`) e
    `ESMF_LIBDIR` (dir da `libesmf`, via `-L` de `ESMF_F90LINKPATHS`, com
    *fallback* no diretório do próprio `esmf.mk`) — fonte única, em bloco
    auto-contido (vale também para `source run/setenv-gnu.bash`). Não se usa a
    variável `ESMF_LIBDIR` do `esmf.mk`: ela não existe em todo build do ESMF.
  - `1-monan.bash`: deixa de recalcular; apenas **verifica** as variáveis
    (`check_var`) e aborta com mensagem clara se faltarem.
  - `2-mom.bash`: **consome** o `ESMF_LIBDIR` do sítio para o `LD_LIBRARY_PATH`;
    `ESMF_APPSDIR` passa a ser tolerante a vazio (apenas avisa). O helper
    `_esmf_mk` é mantido para as flags canônicas do cap NUOPC (Passo 3).
- **Correção (toolchain GNU na etapa 3 e no rebuild manual).** O `make all` do
  acoplador falhava com o `ftn` acionando o compilador Cray (CCE) e rejeitando
  os flags GNU do Makefile (`-mcmodel=small`, `-ffree-line-length-none`,
  `-fallow-argument-mismatch`, …). Causa: o `run/setenv-gnu.bash` só definia
  caminhos (não carregava módulos) e fazia `unset MODULES_MONAN`; como cada
  etapa roda em subprocesso, o `PrgEnv-gnu` das etapas 1-2 não persistia.
  - `run/setenv-gnu.bash` (repo `MONAN-Coupler`): passa a **carregar os módulos**
    (`module purge` + `MODULES_MONAN` do sítio — PrgEnv-gnu + hdf5 + netcdf +
    parallel-netcdf + METIS) logo após o *source* da config, antes do
    `PNETCDF_DIR`. Como é *sourced*, os módulos persistem na sessão — isso conserta
    também o **rebuild manual** do README (`source run/setenv-gnu.bash && make`).
    Opt-out: `export SETENV_NO_MODULES=1`. (Entregue como `setenv-gnu.patch`.)
  - `3-coupler.bash`: **delega** os módulos ao setenv (sem `load_modules`
    redundante) e adiciona uma **guarda de toolchain** — confere `PE_ENV=GNU`
    (var padrão do Cray PE) após o *source* e aborta cedo, com mensagem clara, se
    o `PrgEnv-gnu` não estiver ativo (ex.: setenv-gnu.bash desatualizado).
- Organização: `docs/` (changelog + notas), `sites/site-template.bash`
  (esqueleto para nova máquina) e `Makefile` fino (atalhos: `make`,
  `make download`, `make build`, `make check`, `make help`).
- Passos renomeados (nomes mais curtos, sem "install" redundante):
  `1-install-monan.bash`→`1-monan.bash`, `2-install-mom.bash`→`2-mom.bash`,
  `3-install-coupler.bash`→`3-coupler.bash`.

## v14.15 — Jun 2026

- Repositório do instalador renomeado de `MONAN-Coupler-install` para
  **`Coupler-Install`**.
- Configuração de sítio de sessão movida para `<COUPLER_ROOT>/run/setenv-site.bash`
  (remove a necessidade de um diretório `install/` na árvore do acoplador).
- `setenv-gnu.bash` endurecido: refaz a busca da config quando `SITE_ENV`
  aponta para arquivo inexistente (evita herdar valor obsoleto de um `source`
  anterior que falhou).

## v14.14 — Jun 2026

- Renomeação dos pontos de entrada: `bootstrap.bash`→**`install.bash`**
  (baixa + instala) e `install-all.bash`→**`build.bash`** (só as 3 etapas).
- Biblioteca de funções `install-libs.bash`→**`include.bash`** (é *sourced*).
- Layout organizado: `sites/` (configs por máquina) e `templates/` (mkmf).

## v14.13 — Jun 2026

- Instalador separado em repositório próprio, independente do sistema acoplado.
- `MONAN-Model` e `MOM6-examples` passam a ser **submódulos** do `MONAN-Coupler`
  (clone recursivo na branch `develop`).
- `install.bash` faz o download recursivo do sistema e dispara a instalação.
- Resolvedores tolerantes a layout (`resolve_coupler_root`, `resolve_site_env`,
  `resolve_mkmf_template`) e busca de submódulos (`ensure_model_tree`).

## Anterior — Jun 2026

- Reestruturação de caminhos para o layout multi-modelo
  (`models/atmos/MONAN-Model`, `models/ocean/MOM6-examples`).
- Pipeline de instalação em três etapas (MONAN-A, MOM6+SIS2, acoplador).
