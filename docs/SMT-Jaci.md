# Efeito do SMT no Sistema Acoplado MONAN-A 2.0 × MOM6+SIS2

> **INPE / CGCT / DIMNT · GT Acoplamento de Modelos**
> Supercomputador Jaci (Cray XD2000) · ESMF/NUOPC 8.9.1
> Medições de 05 e 06 de agosto de 2026

Esta nota documenta a caracterização do *Simultaneous Multithreading* (SMT) nos
nós de cálculo do Jaci e a medição do seu efeito sobre o sistema acoplado. O
objetivo prático era decidir, com evidência e não com argumento, quantos PETs o
`run_esmApp.jaci` deve alocar por nó.

**Conclusão.** O padrão de **256 PETs por nó**, um *rank* por core físico, está
correto. Usar as 512 CPUs lógicas torna a execução 2,22 vezes mais lenta em
*wall-clock time*, consumindo 11,2% mais tempo de máquina.

---

## 1. O que é SMT e por que a pergunta surgiu

O SMT faz um core físico apresentar-se ao sistema operacional como dois
processadores. Ele duplica o **estado de execução** (registradores, contador de
programa), mas **não** duplica as unidades de cálculo: a unidade de ponto
flutuante, as unidades vetoriais SIMD e os caches L1 e L2 continuam únicos e
passam a ser compartilhados pelas duas *threads*.

O ganho aparece quando uma *thread* fica frequentemente parada esperando
memória, deixando a unidade de cálculo ociosa para a outra ocupar. Não aparece
quando o código já mantém a unidade saturada.

A pergunta surgiu porque o nó de cálculo do Jaci **anuncia 512 CPUs**, e a
leitura natural seria alocar 512 PETs por nó. Verificar se isso é vantajoso
exigiu três etapas: caracterizar o hardware, entender a contabilidade das filas
e medir o desempenho.

---

## 2. Caracterização do hardware

### 2.1 Nó de login

```bash
lscpu | grep -E '^CPU\(s\)|Core\(s\) per socket|Socket\(s\)|Thread\(s\) per core'
```

Em `ian06`:

```text
CPU(s):                               256
Thread(s) per core:                   1
Core(s) per socket:                   128
Socket(s):                            2
```

SMT **desligado**: 2 × 128 = 256 cores físicos, e `CPU(s)` coincide com esse
total.

### 2.2 Classes de nó

```bash
pbsnodes -a | awk '
  /^[^ \t]/                   {n=$1; c=""; m=""}
  /resources_available.ncpus/ {c=$3}
  /resources_available.mem/   {m=$3}
  /^$/ && n  {printf "%-12s ncpus=%-4s mem=%s\n", n, c, m; n=""}'
```

| Classe | Nós | `ncpus` | Memória | Destino |
|:-------|----:|--------:|:--------|:--------|
| `cn-0001` a `cn-0104` | 104 | 512 | ~754 GB | sistema acoplado |
| `aux01` a `aux10` | 10 | 256 | ~1,5 TB | malha, METIS, pré e pós-processamento |

O **roteamento** entre as classes, isto é, a decisão de em quais nós um job pode
cair, é feito pelo recurso `worktype`, definido pela administração: os nós de
cálculo carregam `compute` e os auxiliares, `aux`, valores que cada fila
acrescenta automaticamente a cada *chunk* do `select`. O `Qlist`, mecanismo mais
usual para o mesmo fim, aparece vazio em todos os nós, o que sugeriria ausência
de roteamento; ele existe, apenas por outra via.

### 2.3 Nó de cálculo

O `pbsnodes` reporta 512 para os nós `cn-*`, o dobro do que o login apresenta.
Duas hipóteses eram compatíveis com esse número: 512 cores físicos, ou 256 cores
com SMT ligado. A distinção não sai do `pbsnodes` e exigiu inspeção de dentro de
um job:

```bash
qsub -I -l select=1:ncpus=512 -l walltime=00:05:00
lscpu | grep -E '^CPU\(s\)|Core\(s\) per socket|Socket\(s\)|Thread\(s\) per core'
```

Em `cn-0064`:

```text
CPU(s):                               512
Thread(s) per core:                   2
Core(s) per socket:                   128
Socket(s):                            2
```

**Confirmado o SMT.** O nó de cálculo é o mesmo hardware do login, 2 sockets
AMD EPYC Zen5 de 128 cores, com SMT habilitado: 256 cores físicos expostos como
512 CPUs lógicas.

> A leitura correta é sempre `Core(s) per socket × Socket(s)`. O campo `CPU(s)`
> só coincide com o número de cores quando `Thread(s) per core` é 1.

---

## 3. Contabilidade das filas

### 3.1 Evidência aritmética

```bash
qstat -Qf
```

| Fila | `resources_max.ncpus` | `resources_max.nodes` | Razão |
|:-----|----------------------:|----------------------:|------:|
| `pesqextra` | 7680 | 30 | **256** |
| `pesqhigh` | 5120 | 20 | **256** |
| `pesqmidi` | 1792 | 7 | **256** |
| `pesqmini` | 1792 | 7 | **256** |
| `longtime` | 2048 | 8 | **256** |

A razão é 256 em todas as filas de pesquisa, e não 512. Os jobs em execução no
momento da consulta apareciam com `resources_assigned.ncpus = 15872` para
`nodect = 62`, o que também dá 256 por nó.

A leitura é que o limite das filas é dimensionado em **cores físicos**, ainda
que o nó anuncie CPUs lógicas.

### 3.2 Verificação experimental

A leitura acima é uma inferência, e a premissa de que `resources_max.ncpus`
incide sobre a soma dos `ncpus` do `select` precisava ser testada. Foram
submetidos três jobs de um minuto executando `/bin/true`:

```bash
qsub -q pesqextra -l select=15:ncpus=512:mpiprocs=512 -l walltime=00:01:00 -- /bin/true
qsub -q pesqextra -l select=16:ncpus=512:mpiprocs=512 -l walltime=00:01:00 -- /bin/true
qsub -q pesqextra -l select=30:ncpus=256:mpiprocs=256 -l walltime=00:01:00 -- /bin/true
```

| `select` | Soma de `ncpus` | Nós | Resultado |
|:---------|----------------:|----:|:----------|
| `15:ncpus=512` | 7680 | 15 | aceito (job 322162) |
| `16:ncpus=512` | 8192 | 16 | **rejeitado**: *Job violates queue and/or server resource limits* |
| `30:ncpus=256` | 7680 | 30 | aceito (job 322161) |

Os dois aceitos param exatamente em 7680 e o rejeitado é o primeiro valor acima.
O caso de 16 nós está confortavelmente dentro do `resources_max.nodes = 30` e
ainda assim foi barrado, o que identifica `ncpus` como a restrição ativa.

**Consequência.** Pedir `ncpus=512` por nó esgota o limite da `pesqextra` em
15 nós, metade do que a mesma fila concede com `ncpus=256`. Os mesmos 7680 PETs
caberiam em metade do hardware, com metade da memória agregada e metade da
largura de banda.

Por isso o `select` do `run_esmApp.jaci` pede `ncpus = mpiprocs ≤ 256`, e a
posse do nó inteiro vem de `place=scatter:excl`, que reserva o nó sem consumir o
limite da fila em dobro.

---

## 4. Metodologia da medição de desempenho

### 4.1 Desenho do experimento

Duas configurações, com o **mesmo número de PETs**, variando apenas quantos
deles ocupam cada nó:

```bash
# A: 512 PETs em 2 nós, 1 rank por core físico (SMT ocioso)
bash run_esmApp.jaci -n 512 -w 01:00:00

# B: 512 PETs em 1 nó, 2 ranks por core (SMT em uso)
bash run_esmApp.jaci -n 512 --ppn 512 --allow-smt -w 01:00:00
```

Configuração comum às duas: malha `x1.40962`, modo `sequential`, partição METIS
`x1.40962.graph.info.part.512`, mesma `nuopc.input`, fila `pesqextra`, 24 passos
de acoplamento. Três repetições de cada configuração.

O modo **sequential** é essencial. Em `concurrent`, o tempo por passo seria
`max(t_ATM, t_OCN)` e o balanceamento entre os blocos mudaria entre as
configurações, confundindo o resultado. Além disso, em B os 512 PETs ocupariam
um único nó, e atmosfera e oceano dividiriam os mesmos dois domínios NUMA.

O `--allow-smt` existe justamente para viabilizar esta medição. O limite padrão do
script é `PPN_PHYS = 256`; a opção libera até `PPN_HARD = 512` e é destinada a
medição, não a produção.

### 4.2 Extração dos tempos

O pós-processamento é feito pelo `mede_smt.py`:

```bash
python3 tools/coupler/mede_smt.py --jobs 16
```

O script lê os logs de PET e aplica três critérios:

**Duração de uma chamada.** Diferença entre os instantes do par
`<COMP>: Run intro.` e `<COMP>: Run extro.`. O ponto final da linha é
significativo: as linhas de `StateLog` repetem o texto `Run intro` seguido de
`{IS}:` e não delimitam a chamada. No `PET000` de uma rodada, o texto
`Run intro` aparece 44688 vezes, das quais apenas 24 são marcadores.

**Soma dentro do passo, e não média por chamada.** Componentes que subciclam
internamente registram mais de um par por passo, e a média por chamada
compararia uma chamada longa com várias curtas, subestimando quem subcicla.

**Máximo entre os PETs, e não média.** Os PETs sincronizam-se em barreiras
coletivas: o grupo só avança quando o último termina, e o tempo ocioso dos PETs
rápidos é desperdício, não economia.

**O primeiro passo é descartado**, porque carrega custos que ocorrem uma única
vez e não se repetem nos passos seguintes, o que o tornaria sistematicamente
mais lento que o regime permanente. Três mecanismos se somam nele. O sistema
operacional usa alocação por demanda (*lazy allocation*): a memória pedida pelo
programa é apenas reservada, e cada página física só é de fato mapeada no seu
primeiro acesso, o chamado primeiro toque (*first touch*), que numa máquina
NUMA como a Jaci também decide em qual dos dois sockets a página fica alojada.
Soma-se a isso a inicialização interna dos conectores do NUOPC, que calculam
pesos de interpolação e outras estruturas na primeira chamada e não repetem
esse trabalho depois. Descartado esse passo, restam 23 dos 24 passos de
acoplamento para a análise.

### 4.3 Tempo de máquina

Comparar A e B pelo relógio seria enganoso. Com o mesmo número de PETs, B usa
**metade dos nós** e, portanto, metade dos cores físicos: seria 2,00 vezes mais
lento ainda que o SMT fosse perfeitamente neutro. O efeito atribuível ao SMT é o
excesso sobre esse fator.

A grandeza que isola o efeito é o **tempo de máquina**: quantos nós reservados,
multiplicados pelos segundos em que ficam ocupados. É a mesma conta da cota de
horas de máquina.

```text
A:  2 nós × 1,257 s  =  2,514
B:  1 nó  × 2,795 s  =  2,795
```

---

## 5. Resultados

### 5.1 Wall-clock time

| Componente | A (s) | dp | B (s) | dp | B/A |
|:-----------|------:|---:|------:|---:|----:|
| MED | 0,159 | 0,001 | 0,309 | 0,003 | 1,94 |
| MPAS | 0,873 | 0,050 | 2,100 | 0,105 | 2,41 |
| OCN | 0,224 | 0,010 | 0,386 | 0,006 | 1,72 |
| **TOTAL** | **1,257** | 0,047 | **2,795** | 0,110 | **2,22** |

Rodadas individuais (tempo total por passo):

```text
A:  1,244   1,309   1,217
B:  2,679   2,808   2,898
```

### 5.2 Tempo de máquina

| Componente | A (nó·s) | B (nó·s) | B/A | Efeito do SMT |
|:-----------|---------:|---------:|----:|:--------------|
| MED | 0,318 | 0,309 | 0,97 | ganho de 3% |
| MPAS | 1,746 | 2,100 | 1,20 | **perda de 20%** |
| OCN | 0,448 | 0,386 | 0,86 | ganho de 14% |
| **TOTAL** | **2,514** | **2,795** | **1,11** | **perda de 11%** |

### 5.3 Incerteza

A incerteza da razão vem da propagação do desvio relativo de cada configuração:

```text
A:  0,047 / 1,257  =  3,7%
B:  0,110 / 2,795  =  3,9%

soma linear (conservadora)  =  7,7%
em quadratura               =  5,4%
```

O efeito total de 11,2% supera ambos os critérios.

---

## 6. Interpretação

O resultado por componente tem **sinais opostos**, e é coerente com o mecanismo
do SMT.

O **mediador** faz interpolação com acesso irregular à memória e o **MOM6** tem
trabalho mais limitado por memória. Ambos deixam a unidade de cálculo ociosa com
frequência, e a segunda *thread* preenche essas lacunas. É exatamente o cenário
para o qual o SMT foi projetado, e os dois passaram a consumir menos tempo de máquina.

O **MPAS** é o oposto: código vetorizado e denso em ponto flutuante, que percorre
arranjos contíguos com padrão de acesso previsível. A unidade de ponto flutuante
já está saturada, não há lacuna a preencher, e as duas *threads* passam a
disputar a mesma unidade vetorial. Soma-se a isso a divisão do cache L2, que não
dobra: dois conjuntos de trabalho passam a competir pelo mesmo espaço, e o SMT
acaba **criando** as esperas que deveria preencher.

Como o MPAS responde por cerca de 69% do passo na configuração A, o saldo
líquido é negativo.

Há ainda um efeito de segunda ordem em MPI puro: dobrar as *threads* significa
dobrar os *ranks*, o que dobra o número de subdomínios, aumenta a área de halo
em relação ao volume de cálculo e eleva o custo de comunicação.

---

## 7. Limitações

**O número vale para um ponto de operação.** Os 11,2% foram medidos com 512
PETs, malha `x1.40962` e modo `sequential`. Como o mecanismo é disputa pelo
cache L2, o tamanho do subdomínio por *rank* importa: com 2176 PETs na mesma
malha, cada subdomínio fica cerca de quatro vezes menor e pode passar a caber no
cache, o que reduziria a penalidade e poderia inverter o sinal. Na direção
oposta, a malha `x1.163842` multiplica por quatro o número de células e, a PETs
constantes, agrava a disputa.

**O modo concurrent não foi testado.** A decomposição por componente sugere que
`--ppn-atm 256` com `--ppn-ocn 512` poderia render, já que o oceano se beneficia
do SMT enquanto a atmosfera é penalizada. A diferença esperada, porém, é de
poucos por cento do total, provavelmente abaixo do ruído atual.

**Os ganhos por componente são frágeis.** O de MED, 3%, está dentro do ruído e
não sustenta afirmação isolada. O de OCN, 14%, é mais firme, mas mereceria mais
repetições. O total de 11,2% é o número defensável.

**Possível efeito térmico.** As três rodadas de B foram monotonicamente
crescentes (2,679 s, 2,808 s e 2,898 s). Três pontos não estabelecem tendência,
mas, se ela persistir, pode indicar limitação térmica: ocupar as duas *threads*
de todos os cores eleva o consumo e pode reduzir a frequência de turbo.

---

## 8. Decisões decorrentes

1. **`PPN_PHYS = 256` permanece como padrão** do `run_esmApp.jaci`, confirmado
   por medição nos dois critérios. O modo automático (`--ppn 0`) nunca
   ultrapassa esse limite.
2. **`--allow-smt` é instrumento de medição**, não opção de produção. Sem ele, o
   script recusa `--ppn` acima de 256 com mensagem explicativa.
3. **`place=scatter:excl` é o padrão.** Reservando 256 em um nó que anuncia 512,
   o `scatter` puro deixaria metade do nó aparentemente livre e autorizaria o
   PBS a alocar outro job ali, com disputa de memória e de banda no mesmo
   socket.
4. **A linha `REGIME` passou a constar do banner do job**, de modo que um tempo
   de parede registrado hoje continue interpretável depois.

---

## 9. Reprodução

```bash
# 1. Planejar e verificar
bash run_esmApp.jaci -n 512 --check
bash run_esmApp.jaci -n 512 --ppn 512 --allow-smt --check

# 2. Rodar, alternando as configurações
bash run_esmApp.jaci -n 512 -q pesqmini -w 00:30:00
bash run_esmApp.jaci -n 512 --ppn 512 --allow-smt -q pesqmini -w 00:30:00

# 3. Preservar os logs de cada rodada (o esmApp_run.log acompanha os PET*.log)
mv logs logs.A1     # e assim por diante, até logs.A3 e logs.B3

# 4. Comparar
python3 tools/coupler/mede_smt.py --jobs 16
```

O `mede_smt.py` faz autoverificação a partir do conteúdo dos logs: confere que
A e B têm o mesmo número de PETs, que o modo de acoplamento é o mesmo e que o
`REGIME` declarado no banner corresponde à configuração, abortando quando os
diretórios parecem trocados. O número de nós lido do banner prevalece sobre
`--nos-a` e `--nos-b`.

---

## 10. Conclusão

O nó de cálculo da Jaci tem 256 cores físicos, não 512, e a contabilidade das
filas confirma essa contagem de forma independente. Usar as 512 CPUs lógicas
via SMT não amplia o paralelismo real: divide o mesmo core entre dois *ranks*,
e custa 2,22× mais em *wall-clock time* e 11,2% mais em tempo de máquina,
mesmo descontado o fato de essa configuração usar metade dos nós.

O achado mais útil não estava na pergunta original: por componente, os sinais
se invertem. MED e OCN ganham com o SMT, por terem acesso irregular à memória;
o MPAS perde, por já saturar a unidade de ponto flutuante. Como o MPAS domina
o passo, o saldo é negativo, mas vale para este ponto de operação, e deve ser
remedido a cada mudança relevante de malha, modo ou contagem de PETs.

O padrão `PPN_PHYS = 256` está estabelecido por medição reproduzível, não por
argumento, com metodologia pronta para ser repetida.

---

## 11. Glossário

| Termo | Significado |
|:------|:------------|
| SMT | *Simultaneous Multithreading*. Um core físico apresenta-se como dois processadores lógicos, duplicando o estado de execução mas não as unidades de cálculo. |
| Core físico | Unidade real de execução, com a sua unidade de ponto flutuante e o seu cache. |
| CPU lógica | O que o sistema operacional enumera. Com SMT ligado, são duas por core físico. |
| PET | *Persistent Execution Thread* do ESMF. Na prática, um processo MPI. |
| `ncpus` | CPUs reservadas por *chunk* do `select`. No Jaci, o limite das filas é contado em cores físicos. |
| `mpiprocs` | Processos MPI por *chunk*. Com `OMP_NUM_THREADS=1`, igual a `ncpus`. |
| `place=scatter:excl` | Um *chunk* por nó, com o nó exclusivo do job. |
| *Wall-clock time* | Tempo do relógio comum, do início ao fim da execução. |
| Tempo de máquina | Nós reservados multiplicados pelos segundos em que ficam ocupados. |
| FPU / SIMD | Unidades de ponto flutuante e vetoriais, compartilhadas entre as *threads* de um core. |
| NUMA | *Non-Uniform Memory Access*. Cada nó tem dois domínios de 128 cores, um por socket. |
| `exit 137` | Término por `SIGKILL` (128 + 9). Sintoma típico de falta de memória. |

---

## 12. Referências internas

| Artefato | Conteúdo |
|:---------|:---------|
| `run_esmApp.jaci` | Submissão multinó, `--allow-smt`, banner com `REGIME` e procedência do build |
| `plan-layout.py` | Planejador de topologia, com os mesmos tetos e a mesma guarda |
| `mede_smt.py` | Extração dos tempos, normalização por nós e autoverificação |
| `MULTINO-run_esmApp.md` | Guia de execução multinó, hardware do sítio e tabela de filas |
| `CHANGELOG.md` | Histórico das alterações, com o raciocínio da contabilidade de `ncpus` |
