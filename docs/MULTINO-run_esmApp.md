# Execução multinó do Sistema Acoplado MONAN-A 2.0 × MOM6+SIS2

> **INPE / CGCT / DIMNT · GT Acoplamento de Modelos**
> Jaci (Cray XD2000) · ESMF/NUOPC 8.9.1

Este guia cobre a execução em **mais de um nó** no `run_esmApp.jaci`, a
**consolidação por componente** no modo *concurrent* e o planejador
`plan-layout.py`.

---

## 1. O que mudou

Antes, o `.pbs` fixava `select=1:ncpus=NPES:mpiprocs=NPES`, ou seja, **um único
nó**, com o limite preso ao número de núcleos daquele nó. Agora a topologia é
**derivada de `-n`**.

O **modo PBS não muda**: o `mpiexec -n NPES` (Cray PALS) lê o `PBS_NODEFILE` e
distribui os *ranks* pelos nós alocados. O `run_esmApp.jaci` detecta o ambiente
por `PBS_O_WORKDIR`: no nó de login gera o `.pbs` e faz `qsub`; dentro do job
carrega os módulos, faz `source` do `setenv` e chama o `mpiexec`.

---

## 2. Hardware da Jaci

Os nós de cálculo `cn-0001` a `cn-0104` (104 nós) têm todos a mesma base:
**2 sockets AMD EPYC (Zen5) de 128 cores = 256 cores físicos**, com **SMT ligado**
(2 threads por core), o que expõe **512 CPUs lógicos**. O `pbsnodes` reporta
`resources_available.ncpus = 512`, contando os lógicos.

O limite das filas, porém, é dimensionado em **cores físicos**: a `pesqextra`
tem `resources_max.ncpus = 7680` para `resources_max.nodes = 30`, o que dá
exatamente 256 por nó, e os jobs em execução aparecem com `ncpus/nodect = 256`.
Por isso o `select` pede `ncpus=mpiprocs=PPN` com `PPN` em cores físicos, e a
posse do nó inteiro vem de `place=scatter:excl`. Pedir `ncpus=512` consumiria o
limite da fila em dobro, limitando o job a 15 nós em vez de 30.

| Recurso        | Valor                                     |
|:---------------|:------------------------------------------|
| Sockets        | 2 (AMD EPYC 9745/9755, Zen5)              |
| Cores físicos  | 256 (2 × 128)                             |
| SMT            | ligado, 2 threads/core → 512 CPUs lógicos |
| `ncpus` no PBS | 512 (conta CPUs lógicos, não cores)       |
| Memória        | ~754 GB (~2,95 GB por core físico)        |

Existe ainda um pool de 10 nós auxiliares (`aux01` a `aux10`) com
`ncpus = 256` e **~1,5 TB de RAM**, alcançados pela fila `aux`
(`default_chunk.worktype = aux`). São o destino natural da geração de malha e do
particionamento METIS, onde a memória pesa mais que o paralelismo, e não do
acoplado. Para inspecionar:
`pbsnodes -a | grep -E 'ncpus|mem' | sort -u` (contagem por classe) e `lscpu` de
dentro de um job (ou o `topo-nos-jaci.sh`) para a topologia real de cada nó.

> **Padrão: 256 PET/nó (nó físico cheio) e sem reserva de memória.** O script
> preenche o nó com **1 rank por core físico** (256) e **não** emite diretiva
> `mem`: o nó fornece a sua RAM, e a memória por PET é apenas RAM_do_nó ÷ PET/nó,
> não um requisito assumido. Não há um limite de memória conhecido do MOM6+SIS2.
> Em caso de encerramento por falta de memória (OOM, exit 137/143), reduza os
> PETs por nó com `--ppn` (espalha em mais nós, aumentando a RAM por PET) ou
> reserve memória com `--mem`.

> **SMT e binding.** Como `ncpus` conta threads, dimensione os PETs pelos **cores
> físicos** (limite de 256/nó); acima disso cai em SMT (2 ranks por core), o que
> prejudica MPAS/MOM6. Fixe 1 rank por core no lançador (o `mpiexec` do PALS
> aceita opções de bind); um job com `ncpus=256` enxerga os 512 lógicos
> (`Cpus_allowed_list: 0-511`), e o binding garante 1 rank por core físico.

---

## 3. Topologia multinó (modo *sequential*)

No modo `sequential` (padrão), MPAS, MED e OCN ocupam todos os PETs. A diretiva de
recurso é derivada de `-n` e do número de PETs por nó (`PPN`):

```
NNODES = NPES / PPN, arredondado para cima
#PBS -l select=NNODES:ncpus=PPN:mpiprocs=PPN     (sem 'mem' por padrão)
#PBS -l place=scatter:excl     # 1 chunk por nó + nó exclusivo
```

> **Por que `:excl` é obrigatório aqui.** Pedimos `ncpus=256` num nó que anuncia
> 512 CPUs lógicos. Sem `:excl`, o PBS considera metade do nó livre e pode alocar
> outro job ali, gerando disputa por RAM e por largura de banda dentro do mesmo
> socket. Com `:excl`, o nó é seu por inteiro, e o SMT simplesmente fica ocioso.

Se `NPES` for múltiplo de `PPN`, a distribuição é uniforme; caso contrário, o
último nó recebe o resto. Exemplos (padrão `PPN=256`):

```text
-n 256  →  select=1:ncpus=256:mpiprocs=256                     (1 nó cheio)
-n 512  →  select=2:ncpus=256:mpiprocs=256                     (2 nós × 256)
-n 512 --ppn 128 → select=4:ncpus=128:mpiprocs=128             (4 nós; mais RAM/PET)
```

Constantes de sítio (topo do script): `PPN_MAX=256`, `PPN=256`,
`PLACE=scatter:excl`, `MEM_PER_PET_GB=0` (sem reserva), `NODE_MEM_STD_GB=754`.

> **Por que 256/nó por padrão?** É o nó físico cheio, com 1 rank por core físico
> (sem SMT), o que aproveita o hardware sem tomar decisões com base em um
> requisito de memória que não é conhecido. Se um experimento estourar a memória
> (OOM), reduza os PETs por nó, por exemplo `--ppn 128` (mais RAM por PET, à
> custa de mais nós), ou reserve memória com `--mem`.

---

## 4. Modo *concurrent*: consolidação por componente

Em `pet_layout = 'split'`, o **ATM (MPAS-A)** e o **OCN (MOM6)** ocupam blocos
disjuntos de PET (mais o **ICE (SIS2)**, quando `use_sis2_dynamic` está ligado). Se os blocos não coincidirem com as fronteiras de nó, um nó
fica **misto** (ATM+OCN), o que piora a localidade e o *binding*.

Com `atm_pet_count` e `ocn_pet_count` explícitos na `nuopc.input`, o script gera
um `select` **heterogêneo** que alinha cada componente a nós inteiros.

O nó misto só ocorre quando o *count* do ATM **não** é múltiplo do limite de
PET/nó. Com `atm=512`, por exemplo, a distribuição natural já sai alinhada
(512 = 2 × 256) e não há nada a consolidar. O caso instrutivo é `atm=384`:

```
  atm_pet_count = 384,  ocn_pet_count = 128

  SEM CONSOLIDAÇÃO (2 nós)          CONSOLIDADO (3 nós)
  ┌──────┬──────────────┐           ┌──────┬──────┬──────┐
  │ ATM  │ ATM  +  OCN  │           │ ATM  │ ATM  │ OCN  │
  │ 256  │ 128  !  128  │           │ 192  │ 192  │ 128  │
  └──────┴──────────────┘           └──────┴──────┴──────┘
       nó 2 é MISTO                  cada nó = 1 componente

  select=2:ncpus=192:mpiprocs=192 + 1:ncpus=128:mpiprocs=128
         └──── nós só ATM ────┘       └──── nó só OCN ────┘
```

Note o custo: a consolidação eliminou o nó misto, mas passou de dois nós para
três. Note também que 192 não é múltiplo de 128 e, portanto, atravessa a
fronteira NUMA. É por isso que o `plan-layout.py` marca `384` como
**quebrado** e o `--suggest` aponta os *counts* limpos: com múltiplos de 256 o
alinhamento sai de graça, sem nó extra e sem cruzar sockets.

Regras:

- **PET/nó**: o maior divisor do *count* que caiba no limite (`--ppn-atm` e
  `--ppn-ocn`, ambos 256 por padrão = nó cheio). Cada componente ocupa nós
  próprios, sem nó misto.
- **Memória**: sem reserva por padrão. Se um componente estourar (em geral o
  OCN), reduza o seu limite, por exemplo `--ppn-ocn 128` (mais RAM por PET, à
  custa de mais nós), ou reserve com `--mem`.
- **Ordem** (`--pet-order`): `atm-first` (padrão) ou `ocn-first`; o PALS preenche
  o `PBS_NODEFILE` na ordem do `select`.
- **Componente ICE**: com `use_sis2_dynamic = .true.` o `select` ganha um
  terceiro bloco, sempre por último, com teto ajustável por `--ppn-ice`. A soma
  das três parcelas de `mpiprocs` precisa fechar com o `-n` do job.

```
  -n 8   atm=4  ocn=2  ice=2

  ┌──────┬──────┬──────┐
  │ ATM  │ OCN  │ ICE  │
  │  4   │  2   │  2   │
  └──────┴──────┴──────┘

  select=1:ncpus=4:mpiprocs=4 + 1:ncpus=2:mpiprocs=2 + 1:ncpus=2:mpiprocs=2
         └─── bloco ATM ────┘   └─── bloco OCN ────┘   └─── bloco ICE ────┘
```

A ordem dos blocos não é cosmética: o `esm.F90` atribui os PETs por faixas
contíguas de rank (ATM primeiro, depois OCN, depois ICE), e o PALS preenche o
`PBS_NODEFILE` na ordem do `select`. Se as duas ordens divergirem, um componente
executa em nós dimensionados para outro, e a falha não se anuncia como tal.

Em `split` com gelo, `ice_pet_count` precisa ser **explícito** na `nuopc.input`:
o `select` é montado antes de o driver executar, então o script não tem como
resolver o modo automático (`ice_pet_count = 0`). O pré-check aborta com
mensagem clara nesse caso.

> A partição METIS (`x1.*.graph.info.part.<atm_pet_count>`) é gerada no
> pré-check. O MOM6 não usa METIS.

---

## 5. Opções do `run_esmApp.jaci`

Todas em `run_esmApp.jaci -h`. As principais:

| Opção                            | Padrão               | Descrição                              |
|:---------------------------------|:--------------------:|:---------------------------------------|
| `-n, --npes N`                   | 4                    | total de PETs MPI                      |
| `-q, --queue` / `-w, --walltime` | pesqextra / 01:00:00 | fila / *walltime*                      |
| `-p, --ppn N`                    | 256                  | PET/nó (0 = automático, até 256)       |
| `--allow-smt`                    | (desligado)          | libera `--ppn` de 257 a 512 (2 ranks por core) |
| `--place MODO`                   | scatter:excl         | `scatter:excl` \| `scatter` \| `pack`  |
| `--mem TAM`                      | (sem)                | reserva fixa de memória por nó (ex.: 700gb) |
| `--mem-per-pet N`                | 0                    | reserva opcional por PET em GB (0 = desligada) |
| `--no-mem`                       | (padrão)             | garante sem reserva de memória         |
| `--ppn-atm` / `--ppn-ocn`        | 256 / 256            | limite de PET/nó por componente (*split*) |
| `--ppn-ice`                      | 256                  | limite de PET/nó do ICE (*split* + SIS2) |
| `--mem-per-pet-atm N`            | 0                    | reserva opcional por PET do ATM (*concurrent*) |
| `--pet-order ORDEM`              | atm-first            | ordem dos blocos (*concurrent*)        |
| `--check` / `--compile`          | (off)                | valida e mostra a topologia / `make rebuild` |

```bash
bash run_esmApp.jaci -n 512 -w 02:00:00        # 2 nós × 256
bash run_esmApp.jaci -n 512 --ppn 128          # 4 nós × 128 (mais RAM/PET)
bash run_esmApp.jaci -n 256 --mem 700gb        # reserva fixa por nó
bash run_esmApp.jaci -n 512 --place scatter        # permite nó compartilhado
bash run_esmApp.jaci -n 384 --check            # concurrent: valida e mostra o select
bash run_esmApp.jaci -n 384 --pet-order ocn-first
```

> **Guardas.** Por padrão não há reserva de memória, então não há o que checar.
> Se você informar `--mem`/`--mem-per-pet` e a reserva por nó passar de ~754 GB,
> o script avisa que o job só cabe nos nós de alta memória (~1,5 TB). Em caso de
> encerramento por sinal (`exit 137/143`), o relatório sugere reduzir os PETs por
> nó (`--ppn`) ou reservar memória (`--mem`).

> **Limite de PET/nó em duas faixas.** `PPN_PHYS=256` é o limite recomendado, em
> cores físicos, e vale como padrão. `PPN_HARD=512` é o limite absoluto do
> hardware, em CPUs lógicas, e só é alcançável com `--allow-smt`, que coloca
> dois ranks por core. A opção existe para **medir** o efeito do SMT, não para
> produção. O modo automático (`--ppn 0`) nunca ultrapassa `PPN_PHYS`.

### Comparação controlada do SMT

Os dois jobs usam o mesmo número de PETs, a mesma partição METIS e a mesma
`nuopc.input`; a única variável que muda é o regime de ocupação do core:

```bash
# A — 512 PETs em 2 nós, 1 rank por core físico (padrão)
bash run_esmApp.jaci -n 512 -w 01:00:00

# B — 512 PETs em 1 nó, 2 ranks por core (SMT ativo)
bash run_esmApp.jaci -n 512 --ppn 512 --allow-smt -w 01:00:00
```

O resumo de topologia e o banner do job registram a linha `REGIME`, o que
permite identificar depois, no log, em que condição cada tempo foi medido.
Note que B usa metade dos nós e, portanto, metade da memória agregada: um
encerramento por falta de memória em B é resultado da medição, não erro de
configuração.

O pós-processamento é feito pelo `mede_smt.py`, que lê os logs de PET das
repetições e emite a tabela comparativa:

```bash
python3 tools/coupler/mede_smt.py --jobs 16
```

**Autoverificação.** O script não confia no nome do diretório: trocar `logs.A`
por `logs.B` inverteria a conclusão sem qualquer sinal. Ele extrai do conteúdo
o modo de acoplamento (linha `ESM: modo ...` do log de PET) e, do
`esmApp_run.log` gravado pela diretiva `#PBS -o`, as linhas `TOPO` e `REGIME`
do banner do job. Com isso aborta quando A e B têm números de PETs diferentes,
quando os modos divergem, quando as rodadas de uma configuração usam números de
nós distintos e, sobretudo, quando o `REGIME` declarado contradiz a
configuração. O número de nós lido do banner prevalece sobre `--nos-a` e
`--nos-b`, com aviso.

Para que isso funcione, o `esmApp_run.log` precisa acompanhar os `PET*.log` no
mesmo diretório. Como a diretiva `#PBS -o` já o grava em `logs/`, basta
renomear o diretório inteiro após cada rodada:

```bash
mv logs logs.A1     # e assim por diante
```

Quando o `REGIME` vem como `indeterminado`, o que ocorre se o `PBS_NODEFILE`
não estiver legível, a verificação correspondente é **pulada com aviso**, e
nunca substituída por suposição.

### Resultado medido (06/08/2026)

Três repetições de cada configuração, 512 PETs, 24 passos de acoplamento com o
primeiro descartado, malha `x1.40962`, modo `sequential`, fila `pesqextra`.

**Atenção ao confundimento.** Com o mesmo número de PETs, B usa metade dos nós
e, portanto, metade dos cores físicos. O *wall-clock time* de B seria 2,00 vezes
o de A ainda que o SMT fosse perfeitamente neutro. O efeito atribuível ao SMT é
o excesso sobre esse fator, e por isso a grandeza comparável é o custo em
**nó vezes segundo por passo**.

| Componente | A (nó·s) | B (nó·s) | B/A | Efeito do SMT |
|:-----------|---------:|---------:|----:|:--------------|
| MED        | 0,318    | 0,309    | 0,97 | ganho de 3% (dentro do ruído) |
| MPAS       | 1,747    | 2,100    | 1,20 | **perda de 20%** |
| OCN        | 0,448    | 0,386    | 0,86 | ganho de 14% |
| **TOTAL**  | **2,514** | **2,795** | **1,11** | **perda de 11%** |

Incerteza da razão, por propagação do desvio-padrão entre as repetições:
7,7% em soma linear e 5,4% em quadratura. O efeito total de 11,2% supera ambos
os critérios.

Em *wall-clock time*, A é **2,22 vezes mais rápido** que B.

**Interpretação.** O resultado por componente tem sinais opostos e é coerente
com o mecanismo do SMT. O mediador faz interpolação com acesso irregular à
memória e o MOM6 tem trabalho mais limitado por memória; ambos deixam a unidade
de cálculo ociosa com frequência, e a segunda thread preenche essas lacunas. O
MPAS é o oposto: código vetorizado e denso em ponto flutuante, que já satura a
FPU e ainda sofre com a divisão do cache L2 entre duas threads. Como o MPAS
responde por cerca de 69% do passo em A, o saldo líquido é negativo.

**Conclusão.** O padrão de `PPN_PHYS = 256` está confirmado por medição, tanto
para tempo de solução quanto para custo de máquina. O `--allow-smt` permanece
como instrumento de medição, não como opção de produção.

> **Ressalvas.** Os ganhos de MED (3%) e OCN (14%) são medidos com margem menor
> e mereceriam mais repetições antes de serem citados isoladamente. As três
> rodadas de B foram monotonicamente crescentes (2,679 s, 2,808 s e 2,898 s):
> três pontos não estabelecem tendência, mas se ela persistir pode indicar
> limitação térmica, já que ocupar as duas threads de todos os cores eleva o
> consumo e pode reduzir a frequência de turbo.

#### Escopo do resultado

Os 11,2% valem para **este ponto de operação**: 512 PETs, malha `x1.40962`,
modo `sequential`, na fila `pesqextra`. Não é uma propriedade do sistema
acoplado, e sim uma medida em uma configuração.

A razão é o mecanismo. A penalidade do SMT vem em boa parte da disputa pelo
cache L2, que não dobra quando duas threads ocupam o mesmo core. Quanto maior o
subdomínio por *rank*, mais os dois conjuntos de trabalho competem pelo mesmo
espaço. Com 2176 PETs na mesma malha, cada subdomínio fica cerca de quatro vezes
menor e pode passar a caber no L2, o que reduziria a penalidade e poderia até
inverter o sinal. Na direção oposta, a malha `x1.163842` multiplica por quatro o
número de células e, a PETs constantes, agrava a disputa.

Antes de transportar o número para outra configuração, refaça a medição:

```bash
python3 tools/coupler/mede_smt.py --jobs 16
```

Fica também em aberto o modo `concurrent`. O resultado por componente sugere que
`--ppn-atm 256` com `--ppn-ocn 512` poderia render, já que o OCN se beneficia do
SMT enquanto o ATM é penalizado, mas a diferença esperada é de poucos por cento
do total, provavelmente abaixo do ruído atual. É observação, não recomendação.

---

## 5.1 Filas e limites (`qstat -Qf`, 2026-08)

O `run_esmApp.jaci` confere NPES, número de nós e *walltime* contra os limites da
fila **antes** de submeter, e aborta com mensagem explícita se algum estourar.

| Fila | Prioridade | PETs (`ncpus`) | Nós | *Walltime* | Observação |
|:-----|:----------:|---------------:|----:|:-----------|:-----------|
| `pesqextra` | 10 | 7680 | 30 | 08:00:00 | **padrão do script** |
| `pesqhigh`  | 15 | 5120 | 20 | 06:00:00 | |
| `pesqmidi`  | 20 | 1792 |  7 | 02:00:00 | |
| `pesqmini`  | 30 | 1792 |  7 | 00:30:00 | testes rápidos |
| `longtime`  | 25 | 2048 |  8 | 168:00:00 | integrações longas |
| `aux`       | -- |  256 |  1 | 24:00:00 | nós `aux*` (~1,5 TB), pré e pós-processamento |
| `oper` / `preoper` | 100 / 90 | 10240 | -- | 08:00:00 | restritas por ACL |

A `workq` e a `COIDS-SysAdmin` estão desabilitadas (`enabled = False`).

### Roteamento entre as classes de nó

Ao submeter, alguém precisa decidir em quais nós o job pode cair: não faria
sentido um job de 30 nós ser alocado nos `aux*`, que são apenas dez. Esse
casamento entre fila e grupo de nós é o **roteamento**.

Na Jaci ele é feito pelo recurso **`worktype`**, definido pela administração e
não nativo do PBS. Ele funciona como um rótulo: os nós de cálculo carregam
`worktype = compute` e os auxiliares, `worktype = aux`. Do lado das filas, o
`qstat -Qf` mostra o valor que será acrescentado automaticamente a cada *chunk*
do `select`:

```text
Queue: pesqextra                      Queue: aux
    default_chunk.worktype = compute      default_chunk.worktype = aux
```

Como o escalonador só aloca um *chunk* em nó cujos recursos satisfaçam o pedido,
um job na `pesqextra` só cai em nó com `worktype = compute`.

> **Por que o `Qlist` aparece vazio.** O `Qlist` é o mecanismo alternativo, e
> mais comum, para o mesmo fim: uma lista de filas atribuída a cada nó. No
> `pbsnodes` da Jaci ele vem vazio em todos os nós, o que sugeriria ausência de
> roteamento. Não é o caso: o roteamento existe, apenas foi implementado pelo
> `worktype`.

Na prática, basta escolher a fila. O `run_esmApp.jaci` **não sobrescreve** o
`worktype`, para que o padrão da fila prevaleça; informá-lo manualmente no
`select` pode quebrar o roteamento sem sinal aparente.

> **Limite prático do acoplado.** Na `pesqextra`, 30 nós × 256 PET/nó = **7680 PETs**,
> que é exatamente o `resources_max.ncpus` da fila. As duas restrições coincidem
> justamente porque o limite é contado em cores físicos.

### Verificação do limite (submissões de 06/08/2026)

A leitura de que `resources_max.ncpus` incide sobre a **soma dos `ncpus` do
`select`**, e não sobre os cores físicos que o job de fato ocupa, foi
confirmada por submissão direta. Os jobs pedem `walltime` de um minuto e
executam `/bin/true`, de modo que o custo é desprezível:

```bash
qsub -q pesqextra -l select=15:ncpus=512:mpiprocs=512 -l walltime=00:01:00 -- /bin/true
qsub -q pesqextra -l select=16:ncpus=512:mpiprocs=512 -l walltime=00:01:00 -- /bin/true
qsub -q pesqextra -l select=30:ncpus=256:mpiprocs=256 -l walltime=00:01:00 -- /bin/true
```

| `select` | Soma de `ncpus` | Nós pedidos | Resultado |
|:---------|----------------:|------------:|:----------|
| `15:ncpus=512` | 7680 | 15 | aceito |
| `16:ncpus=512` | 8192 | 16 | **rejeitado**: *Job violates queue and/or server resource limits* |
| `30:ncpus=256` | 7680 | 30 | aceito |

Os dois casos aceitos param exatamente em 7680, e o rejeitado é o primeiro
valor acima. Note que o caso de 16 nós está confortavelmente dentro do
`resources_max.nodes = 30` e ainda assim foi barrado: a restrição ativa é a de
`ncpus`, não a de nós. Fica assim demonstrado que pedir `ncpus=512` por nó
esgota o limite da fila em **15 nós**, metade do que a mesma fila concede com
`ncpus=256`.

Lembre-se de encerrar os jobs de teste com `qdel` após a verificação.

> **Atualize a tabela** se a administração mudar os limites: as constantes
> `QUEUE_LIMITS_*` ficam no topo do `run_esmApp.jaci` e saem de
> `qstat -Qf | grep -E '^Queue|resources_max'`.

---

## 6. `plan-layout.py`: planejador de topologia

Reproduz, **fora do job**, a lógica de consolidação do `run_esmApp.jaci`, para
escolher os *counts* **antes** de editar a `nuopc.input`. O `select` impresso é
**idêntico** ao do job. Todas as opções estão em `--help`.

```bash
python3 plan-layout.py --atm 256 --ocn 128        # layout de um par ATM/OCN
python3 plan-layout.py --total 384 --ratio 2:1    # divide um total por razão
python3 plan-layout.py --sweep 384 1536 --step 384 --ratio 2:1   # tabela
python3 plan-layout.py --suggest --atm 250 --ocn 130   # counts "limpos"
python3 plan-layout.py --sequential --npes 512 --ppn 128
```

Saída da varredura (`--sweep`):

```text
  NPES   atm   ocn | bloco ATM      bloco OCN      | nós | status
   384   256   128 | 1x256          1x128          |  2  | OK
   768   512   256 | 2x256          1x256          |  3  | OK
  1152   768   384 | 3x256          2x192          |  5  | quebrado
  1536  1024   512 | 4x256          2x256          |  6  | OK
```

(sem coluna de GB porque não há reserva de memória por padrão; com
`--mem-per-pet N` aparece a memória por nó.)

Significado do *status*: **`OK`** (cada componente cabe num nó ou é múltiplo do
limite); **`quebrado`** (count maior que o limite e não múltiplo, gerando PET/nó
torto como `2×192`; revise com `--suggest`); **`mem>nó padrão`** (só quando você
reserva memória e ela passa de ~754 GB, indo p/ os nós de ~1,5 TB).

---

## 7. Fluxo recomendado

```
1. PLANEJAR    python3 plan-layout.py --atm 256 --ocn 128   (use --suggest se "quebrado")
2. CONFIGURAR  nuopc.input: coupling_mode=concurrent, atm_pet_count=256, ocn_pet_count=128
3. VERIFICAR   bash run_esmApp.jaci -n 384 --check           (pré-requisitos, METIS, select)
4. SUBMETER    bash run_esmApp.jaci -n 384
```

---

## 8. Boas práticas

- **Use counts que fechem em nós inteiros:** múltiplos de 256, ou valores até
  256 (que cabem em um nó). Contagens maiores que 256 e não múltiplas (por
  exemplo, 384) geram blocos tortos como `2×192`.
- **Reaja ao OOM, não o antecipe:** o padrão não reserva memória. Se um job
  estourar (`exit 137/143`), reduza os PETs por nó (`--ppn 128`, mais RAM/PET) ou
  reserve com `--mem`; no concurrent, reduza o limite do OCN (`--ppn-ocn 128`).
- **Não remova o `:excl` sem motivo:** com `ncpus=256` num nó de 512 lógicos, o
  `place=scatter` puro autoriza o PBS a colocar outro job na outra metade.
- **Alinhe a partição concorrente aos sockets:** cada nó tem 2 domínios NUMA de
  128 cores. Cortes de `atm_pet_count`/`ocn_pet_count` em múltiplos de 128 mantêm
  cada componente dentro de sockets inteiros.
- **Rode `--check` antes de submeter:** ele mostra a topologia e o `select`, e
  gera a partição METIS que faltar.

---

## 9. Conclusão

A adaptação resolveu um problema pontual, a diretiva `select=1`, mas exigiu
descobrir como a Jaci de fato funciona: a contabilidade de `ncpus` em cores
físicos, a exclusividade do nó e os limites reais de cada fila, todos
confirmados por submissão, não por leitura de documentação. O resultado é um
sistema que escala de 256 PETs presos a um nó até 7680 PETs em 30 nós, o
limite da própria fila, sem exigir nenhuma mudança de quem já usava a opção
`-n`.

O padrão de 256 PET por nó, com `place=scatter:excl`, está estabelecido tanto
por engenharia quanto por medição (ver `SMT-Jaci.md`): aproveita os cores
físicos sem disputa de vizinho e sem o custo do SMT. O `plan-layout.py`
estende essa mesma lógica ao planejamento prévio da topologia, e a guarda de
fila recusa pedidos inválidos em segundos, no nó de login.

Fica em aberto validar este comportamento em outros pontos de operação,
sobretudo no modo `concurrent` e em malhas maiores, e repetir a medição do SMT
sempre que a máquina ou o código mudarem.

---

## 10. Glossário

**Paralelismo e PETs**

| Termo        | Significado |
|:-------------|:------------|
| PET          | *Persistent Execution Thread* do ESMF. Na prática, um processo MPI (um *rank*). |
| *rank*       | Identificador de um processo MPI dentro do comunicador. |
| NPES (`-n`)  | Número total de PETs do job. |
| PPN          | PETs por nó (o `mpiprocs` de cada *chunk*). |

**Recursos do PBS Pro**

| Termo         | Significado |
|:--------------|:------------|
| `select`      | Diretiva que descreve os recursos pedidos, em *chunks* (`select=NNODES:ncpus=…:mpiprocs=…:mem=…`). |
| *chunk*       | Unidade de alocação do `select`; cada *chunk* é atendido por um nó. |
| `ncpus`       | CPUs reservadas por *chunk*. Na Jaci o limite das filas é em cores físicos, então pedimos `ncpus = mpiprocs ≤ 256`, ainda que o nó anuncie 512 lógicos. |
| `mpiprocs`    | Processos MPI por *chunk* (com `OMP_NUM_THREADS=1`, igual a `ncpus`). |
| `mem`         | Memória reservada por *chunk* (por nó). |
| `place=scatter` | Coloca cada *chunk* em um nó distinto (usado pelo acoplador). |
| `place=pack`  | Empacota os *chunks* no menor número de nós. |
| `:excl`       | Torna o nó exclusivo do job, sem compartilhar com outros. |
| `walltime`    | Tempo máximo permitido para a execução do job, definido na submissão (`-w HH:MM:SS`). |
| `PBS_NODEFILE` | Arquivo que lista os nós e *slots* alocados; o `mpiexec` o lê para distribuir os *ranks*. |

**Códigos de saída (sinais)**

| Termo      | Significado |
|:-----------|:------------|
| OOM        | *Out Of Memory*. O *OOM killer* do Linux mata o processo por falta de memória. |
| `exit 137` | Término pelo sinal `SIGKILL` (9), pois `128 + 9 = 137`. Sintoma típico de OOM. |
| `exit 143` | Término pelo sinal `SIGTERM` (15), pois `128 + 15 = 143`. Em geral o PBS encerrando o job (*walltime* ou memória). |

**Ferramentas e modelos**

| Termo        | Significado |
|:-------------|:------------|
| PALS         | *Parallel Application Launch Service* da Cray; fornece o `mpiexec` usado no lançamento. |
| METIS        | Biblioteca de particionamento de grafos; decompõe a malha do MPAS em N partes (`x1.*.graph.info.part.N`). |
| `sequential` | Modo em que MPAS, MED e OCN usam todos os PETs, em série. |
| `concurrent` | Modo em que ATM e OCN ocupam blocos disjuntos de PET e avançam em paralelo (MED em todos). |
| ATM/OCN/MED  | Componentes: atmosfera (MPAS-A), oceano (MOM6+SIS2) e mediador (fluxos *bulk*). |

**Hardware da Jaci**

| Termo             | Significado |
|:------------------|:------------|
| Nó de cálculo     | 256 cores físicos (2 sockets × 128), SMT on → 512 CPUs lógicos, ~754 GB. |
| CPU lógico × físico | Com SMT on, `ncpus` do PBS conta threads (512); os cores físicos são 256. |
| Nó auxiliar (`aux*`) | 10 nós com `ncpus = 256` e ~1,5 TB, na fila `aux`; usados para pré e pós-processamento. |
| *socket* / NUMA   | Cada nó tem 2 *sockets* AMD EPYC (Zen5) de 128 cores. |
