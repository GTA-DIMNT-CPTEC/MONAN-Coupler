# plan-layout.py: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/coupler/plan-layout.py`.

## 1. Para que serve

O `plan-layout.py` reproduz, fora do job, a mesma lógica de consolidação de nós que o `run_esmApp.jaci` aplica ao gerar a diretiva `select` do PBS. Serve para escolher quantos PETs dar a cada componente antes de editar o `nuopc.input`.

O que ele responde: com estas contagens, quantos nós serão alocados, quantos PETs por nó, qual a string `select` resultante, e a combinação estoura algum limite da fila?

O que ele não faz: não executa nada, não submete nada, não lê logs. É aritmética de topologia, feita antes de gastar fila.

O problema que ele evita é conhecido: o número de nós é avaliado depois do cálculo de topologia. Reduzir os PETs por nó pode multiplicar a contagem de nós e provocar recusa na fila mesmo com um NPES modesto. Descobrir isso na submissão custa uma ida e volta à fila; descobrir aqui não custa nada.

## 2. Como a consolidação funciona

Com `pet_layout = 'split'`, cada componente recebe um bloco próprio de nós. Os PETs por nó de um componente são o **maior divisor da sua contagem que caiba no teto**, com teto padrão de 256, que é o número de cores físicos de um nó da Jaci.

Escolher um divisor, e não simplesmente o teto, garante que cada bloco feche em nós inteiros e que nenhum nó fique misto, com dois componentes ao mesmo tempo. Isso melhora a localidade e o binding.

A mesma regra vale para dois ou três blocos: atmosfera e oceano sempre, mais o gelo quando `use_sis2_dynamic` está ligado.

A consequência prática é que contagens "redondas" produzem topologias limpas e contagens primas ou quase primas produzem topologias ruins. Por exemplo, 341 PETs de atmosfera se consolidam em 11 nós de 31 PETs cada, desperdiçando a maior parte de cada nó. É exatamente esse tipo de escolha que o planejador serve para pegar antes.

O hardware assumido é o nó de cálculo da Jaci: 256 cores físicos, dois sockets de 128 Zen5, com SMT ligado dando 512 CPUs lógicas, e cerca de 754 GB. O orçamento das filas é em cores físicos, então o `select` pede `ncpus` igual a `mpiprocs` com o valor de PETs por nó, e a posse do nó inteiro vem de `place=scatter:excl`.

## 3. Uso básico

Split com os três componentes, na topologia de produção:

```bash
python3 tools/coupler/plan-layout.py --atm 64 --ocn 4 --ice 4 --queue longtime
```

Saída:

```
==========================================================================
  Layout SPLIT — atm=64  ocn=4  ice=4  (NPES=72)
==========================================================================
  Bloco ATM   : 1 x 64 PET/nó
  Bloco OCN   : 1 x 4 PET/nó
  Bloco ICE   : 1 x 4 PET/nó
  Total       : 3 nó(s)   (ordem no select: atm-first, ICE por último)
  SELECT      : select=1:ncpus=64:mpiprocs=64+1:ncpus=4:mpiprocs=4+1:ncpus=4:mpiprocs=4
  place       : scatter:excl (1 chunk por nó, nó exclusivo)
  regime      : 1 rank por core fisico (SMT ocioso)
  fila        : longtime  (máx: 2048 PETs, 8 nós, 168:00:00)
  STATUS: layout limpo (cada componente cabe em nós inteiros).

  Para usar, na nuopc.input (&nuopc_petlayout):
    coupling_mode = 'concurrent'   ! 'sequential' também aceita split
    pet_layout    = 'split'        ! obrigatório para as contagens abaixo
    atm_pet_count = 64
    ocn_pet_count = 4
    use_sis2_dynamic = .true.
    ice_pet_count = 4
  e submeter:  bash run_esmApp.jaci -n 72
==========================================================================
```

Sem `--ice`, o planejador recai no caso de dois blocos, com o mesmo `select` de antes, e a sugestão de `nuopc.input` traz `use_sis2_dynamic = .false.` como lembrete de que o plano não previu bloco de gelo.

Layout compartilhado, em que todos os componentes ficam em todos os PETs:

```bash
python3 tools/coupler/plan-layout.py --shared --npes 512 --ppn 128
```

```
  Topologia : 4 nó(s) x 128 PET/nó
  SELECT    : select=4:ncpus=128:mpiprocs=128
  place     : scatter:excl
  regime    : 1 rank por core fisico (SMT ocioso)
```

## 4. Os três modos de consulta

### 4.1 Contagens dadas

`--atm K --ocn K [--ice K]`, como acima. É o modo mais direto: você já sabe o que quer e só precisa ver a topologia resultante.

Alternativamente, `--total N --ratio A:B` divide um total pela razão informada. A razão padrão é `2:1`.

Com gelo há duas formas de usar `--total`, e vale escolher pelo que você já sabe:

`--total N --ratio A:B:C` reparte os três pela razão, com a sobra do arredondamento indo para o gelo. Use quando quiser explorar proporções, por exemplo `--total 288 --ratio 16:1:1`.

`--total N --ice K --ratio A:B` reserva o bloco de gelo primeiro e reparte o restante entre atmosfera e oceano. Use quando a contagem do gelo já estiver decidida e só o resto estiver em aberto. Combinar `--ice` com uma razão de três termos é recusado, porque os dois estariam dizendo a mesma coisa.

### 4.2 Varredura

`--sweep MIN MAX` percorre uma faixa de NPES no passo dado por `--step` (padrão 128) e monta uma tabela. Útil quando a pergunta é "qual tamanho de rodada tem topologia limpa nesta faixa".

```bash
python3 tools/coupler/plan-layout.py --sweep 256 768 --step 256 --ratio 2:1
```

```
  NPES   atm   ocn | bloco ATM            bloco OCN            |  nós | status
------------------------------------------------------------------------------
   256   170    86 | 1x170                1x86                 |    2 | OK
   512   341   171 | 11x31                1x171                |   12 | quebrado
   768   512   256 | 2x256                1x256                |    3 | OK
```

Com uma razão de três termos, a tabela ganha as colunas do gelo:

```bash
python3 tools/coupler/plan-layout.py --sweep 288 1152 --step 288 --ratio 16:1:1 --queue longtime
```

```
  NPES   atm   ocn   ice | bloco ATM        bloco OCN        bloco ICE        |  nós | status
---------------------------------------------------------------------------------------------
   288   256    16    16 | 1x256            1x16             1x16             |    3 | OK
   576   512    32    32 | 2x256            1x32             1x32             |    4 | OK
   864   768    48    48 | 3x256            1x48             1x48             |    5 | OK
  1152  1024    64    64 | 4x256            1x64             1x64             |    6 | OK
```

A coluna `status` tem três valores. `OK` significa que cada componente cabe num nó ou é múltiplo do teto. `quebrado` significa que a contagem passou do teto sem ser múltiplo dele, e a consolidação produziu PETs por nó tortos, como os 11 nós de 31 PETs acima. `excede fila` significa que o NPES ou o número de nós passou do limite da fila consultada.

### 4.3 Sugestão

`--suggest`, junto de `--atm`, `--ocn` e, quando houver, `--ice`, mostra contagens limpas próximas das que você informou, e em seguida imprime o relatório completo.

```bash
python3 tools/coupler/plan-layout.py --suggest --atm 250 --ocn 130
```

## 5. Opções

| opção | padrão | significado |
| - | - | - |
| `--atm K` | - | `atm_pet_count`, PETs do MPAS |
| `--ocn K` | - | `ocn_pet_count`, PETs do MOM6 |
| `--ice K` | 0 | `ice_pet_count`, PETs do SIS2 dinâmico. Zero significa sem bloco de gelo |
| `--total N` | - | NPES total, dividido conforme `--ratio` |
| `--ratio A:B` ou `A:B:C` | `2:1` | razão entre os componentes, usada com `--total` e `--sweep` |
| `--sweep MIN MAX` | - | varre NPES na faixa e imprime tabela |
| `--step N` | 128 | passo da varredura |
| `--suggest` | - | mostra contagens limpas próximas das informadas |
| `--shared`, `--sequential` | - | planeja layout compartilhado em vez de split |
| `--npes N` | - | NPES para `--shared` |
| `--ppn N` | 0 (automático) | PETs por nó no `--shared` |
| `--ppn-atm N` | 256 | teto de PETs por nó da atmosfera |
| `--ppn-ocn N` | 256 | teto de PETs por nó do oceano |
| `--ppn-ice N` | 256 | teto de PETs por nó do gelo |
| `--mem-per-pet-atm N` | 0 | reserva opcional, em GB por PET da atmosfera |
| `--mem-per-pet N` | 0 | reserva opcional, em GB por PET do oceano, aplicada também ao gelo |
| `--pet-order` | `atm-first` | ordem dos dois primeiros blocos no `select`: `atm-first` ou `ocn-first`. O bloco de gelo vem sempre por último |
| `--ppn-max N` | 256 | cores físicos por nó |
| `--allow-smt` | - | libera tetos acima de 256, até 512, com dois ranks por core |
| `--node-mem N` | 754 | GB do nó padrão |
| `--queue NOME` | `pesqextra` | fila cujos limites serão conferidos |
| `-h` | - | ajuda |

`--sequential` é sinônimo histórico de `--shared` e continua funcionando.

### 5.1 Duas convenções do bloco de gelo

As duas vêm do `run_esmApp.jaci` e precisam continuar iguais aqui, sob pena de o planejador imprimir um `select` diferente do que o script vai gerar.

O SIS2 vive na grade do oceano, então o orçamento de memória por PET do gelo é o mesmo do oceano, informado por `--mem-per-pet`. Não há uma opção separada para o gelo.

O chunk do gelo vem sempre por último, mesmo com `--pet-order ocn-first`. Isso reflete a atribuição de PETs feita pelo `esm.F90`, que reparte por faixas contíguas de rank: a atmosfera fica com `[0..nAtm-1]`, o oceano com o intervalo seguinte, e o gelo com o resto. Se os chunks não seguissem essa ordem, um componente executaria em nós dimensionados para outro.

## 6. Os dois eixos, e o que este planejador vê

O grupo `&nuopc_petlayout` tem dois eixos independentes.

O eixo espacial, `pet_layout`, decide se os componentes ficam em blocos disjuntos ou compartilham todos os PETs. É esse que o planejador trata: `--atm` com `--ocn` planeja um `split`, e `--shared` planeja um `shared`.

O eixo temporal, `coupling_mode`, decide se os componentes avançam ao mesmo tempo ou um de cada vez. Ele **não altera a topologia de nós**: `sequential+split` e `concurrent+split` pedem exatamente o mesmo `select`. O que ele altera é o tempo por passo, que só cai para o maior dos avanços no modo concorrente.

Por isso o cabeçalho do relatório diz "Layout CONCURRENT" mesmo quando você vai rodar em modo sequencial. A linha impressa na sugestão de `nuopc.input` deixa isso explícito: `sequential` também aceita `split`.

## 7. Sobre o SMT

O padrão é um rank por core físico, com o SMT ocioso. Pedir teto acima de 256 é recusado:

```
ERRO: --ppn-atm 512 excede 256 cores fisicos por no. Acima disso cada core
recebe 2 ranks (SMT), o que degrada MPAS/MOM6. Para planejar esse caso
deliberadamente, acrescente --allow-smt.
```

Essa guarda espelha a do `run_esmApp.jaci`, e existe para que o planejador nunca imprima um `select` que o script de submissão recusaria. Ela vale para `--ppn-max`, `--ppn-atm`, `--ppn-ocn` e `--ppn-ice`. `--allow-smt` destina-se a medição, não a produção.

## 8. Limites de fila conhecidos

O planejador traz uma tabela dos limites, consultada por `--queue`:

| fila | NPES máximo | nós | walltime |
| - | - | - | - |
| `pesqextra` | 7680 | 30 | 08:00:00 |
| `pesqhigh` | 5120 | 20 | 06:00:00 |
| `pesqmidi` | 1792 | 7 | 02:00:00 |
| `pesqmini` | 1792 | 7 | 00:30:00 |
| `longtime` | 2048 | 8 | 168:00:00 |
| `aux` | 256 | 1 | 24:00:00 |
| `oper`, `preoper` | 10240 | sem limite declarado | 08:00:00 |

Para uma fila fora da tabela, o planejador avisa e recomenda `qstat -Qf <fila>`. A tabela é de agosto de 2026; se houver dúvida, confira contra o `qstat` antes de submeter uma rodada longa.

A fila `aux`, nos nós auxiliares de 1,5 TB, é para pré e pós-processamento, não para o acoplado.

## 9. Notas sobre o bloco de gelo

O gelo tende a ser o bloco mais pequeno, e é onde as escolhas ficam menos óbvias.

Um bloco de gelo pequeno ocupa um nó inteiro assim mesmo, por causa do `place=scatter:excl`: quatro PETs de SIS2 tomam um nó de 256 cores. Isso é intencional, para não misturar componentes num nó, mas significa que cada bloco a mais custa pelo menos um nó no consumo de fila, medido em nós vezes walltime. Vale conferir se o terceiro nó cabe no limite da fila escolhida.

Antes de decidir a contagem do gelo, vale medir. O `analisa_balanceamento_pets.py` lê os logs de uma execução e sugere as três contagens a partir do tempo medido, em vez da razão arbitrária usada aqui. Ver `docs/uso-analisa-balanceamento.md`.

A sugestão daquele script pode dar uma contagem bem pequena para o gelo, porque o SIS2 costuma ser o componente mais barato e a quota proporcional o empurra para poucos PETs, região em que o custo fixo de comunicação pesa proporcionalmente mais. Trazer a contagem para cá e conferir a topologia é justamente o passo que fecha o ciclo.

## 10. Fluxo recomendado

Planeje antes de editar o `nuopc.input`. Depois de escolher as contagens, gere a partição METIS correspondente ao `atm_pet_count`, e não ao total:

```bash
python3 tools/coupler/plan-layout.py --atm 64 --ocn 4 --ice 4 --queue longtime
gen-metis.bash --parts 64
```

A partição METIS acompanha `atm_pet_count`, e não o total: com 64, 4 e 4, o arquivo necessário é `.part.64`, e não `.part.72`.

Depois de uma primeira execução, o `analisa_balanceamento_pets.py` lê os logs e sugere uma repartição baseada no tempo medido, em vez de na razão arbitrária usada aqui. Ver `docs/uso-analisa-balanceamento.md`. O ciclo natural é: planejar a topologia com este script, rodar, medir com o outro, replanejar.
