# A máscara de terra no cap NUOPC do MOM6+SIS2

Por que o `mask_table` funciona no MOM6 isolado e derruba o sistema acoplado.

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Documentado a partir do incidente de 22/07/2026 (256 PETs, `coupling_mode =
'concurrent'` com `pet_layout = 'split'`).

---

## Em três frases

O `mask_table` remove da decomposição os blocos que são 100% terra, e o MOM6
lida com isso perfeitamente. O cap NUOPC, porém, descreve ao ESMF uma grade
retangular completa usando apenas os blocos que sobraram, o que deixa regiões
sem dono. O ESMF aceita a descrição sem conferir e só falha bem depois, dentro
do conector OCN para MED, com uma mensagem que não menciona máscara nenhuma.
O split de comunicador entre atmosfera e oceano não tem parte nisso, e a seção 2
explica por quê.

---

## 1. Cinco termos que aparecem no resto do texto

Vale fixar o vocabulário, porque a confusão entre esses conceitos é justamente
o que torna o erro difícil de ler.

| Termo | O que é |
|---|---|
| **PE** | *Processing Element*, na linguagem do FMS. Na prática, um rank MPI. |
| **PET** | *Persistent Execution Thread*, na linguagem do ESMF. É a mesma coisa que um PE. |
| **DE** | *Decomposition Element*. Um pedaço do domínio. É o que é executado. |
| **DELayout** | O mapa que diz qual PET cuida de qual DE. Um PET pode cuidar de vários DEs. |
| **DistGrid** | A descrição de como um espaço de índices, por exemplo `[1..180] x [1..158]`, está repartido em DEs. |
| **Grid x Mesh** | Duas geometrias do ESMF. A `Grid` é logicamente retangular (índices i, j). A `Mesh` é uma lista de células, sem exigência de forma. |

Há dois eixos distintos nessa lista, e confundi-los é meio caminho para não
entender o erro.

**PE e PET são sinônimos em vocabulários diferentes.** Um é a palavra do FMS, o
outro a do ESMF, e ambos designam um rank MPI. Neste documento, PE aparece
quando quem está falando é o FMS, e PET quando é o ESMF.

**DE é outra categoria.** PE e PET são *quem executa*; DE é *o que é executado*,
um pedaço do domínio. Não são dois nomes para a mesma coisa, e a relação entre
eles é o centro da história:

| | Bloco de domínio e processo |
|---|---|
| **FMS** | são a mesma coisa. Não existe objeto que represente um bloco sem PE: um bloco mascarado não é um bloco vazio, ele simplesmente não está lá |
| **ESMF** | são objetos distintos. O `DELayout` mapeia DEs em PETs com qualquer multiplicidade, inclusive vários DEs no mesmo PET |

Duas consequências, que voltam mais adiante. A primeira: o cap não consegue
descobrir os blocos mascarados interrogando o objeto de domínio do FMS, porque
lá eles não existem; é preciso voltar ao `LAYOUT` e recalcular as extensões. A
segunda: como o ESMF separa DE de PET, é possível criar DEs para os blocos
mascarados sem gastar processo algum, e é nisso que se apoia a Rota A da
seção 10.

---

## 2. O split de comunicador não está envolvido

Esta costuma ser a primeira dúvida de quem conhece o sistema: se atmosfera e
oceano rodam em blocos disjuntos de PETs, com decomposições independentes, por
que a decomposição do oceano quebraria o acoplamento?

As decomposições **são** independentes, inclusive no run que falhou. O MPAS
particiona sua malha Voronoi com METIS sobre 128 PETs; o MOM6 fatia a grade
lógica em `NIPROC x NJPROC` sobre outros 128 PETs. Nenhum dos dois conhece o
número de blocos do outro, e isso não mudou.

Uma nota de vocabulário, posterior a este incidente: o split de comunicador é
hoje controlado por `pet_layout = 'split'`, independente do `coupling_mode`
(v14.20). Tudo o que esta seção diz vale igualmente para `sequential + split`,
porque o argumento é sobre a geometria publicada ao ESMF, não sobre a ordem em
que os componentes avançam.

Um experimento mental fecha o ponto: troque o MPAS pelo DATM, ou retire a
atmosfera e deixe apenas MOM6 mais mediador. **A falha se repete igual.** Ela
nasce no conector OCN para MED, com a atmosfera parada em outro comunicador,
sem participar. O problema não atravessa a fronteira ATM/OCN em momento algum.

Por isso, dizer que "funciona standalone e falha acoplado" é impreciso. O mais
exato é: **o MOM6 funciona nos dois casos, e o que não funciona é o cap**, que
só existe na versão acoplada. O cap não é parte do MOM6 nem do acoplador, é o
adaptador entre os dois.

### Independência de decomposição não é sigilo de geometria

O que muda no acoplado não é a autonomia de cada componente, e sim a existência
de uma tarefa nova: interpolar campos de uma grade para outra. Pesos de
interpolação são objetos globais, que mapeiam célula de origem em célula de
destino atravessando PETs. Para montá-los, o ESMF percorre a grade de origem
inteira e, para cada célula, precisa saber quem é o dono e onde ficam os
vértices.

Cada componente publica, então, a descrição completa da **própria** geometria.
Independência significa "geometrias diferentes são permitidas", não "a geometria
fica escondida". O `mask_table` não interfere na autonomia do oceano; ele
interfere na completude da descrição que o oceano publica.

## 3. O que o `mask_table` faz

O MOM6 fatia a grade global em `NIPROC x NJPROC` blocos, um PE por bloco. Numa
grade global, boa parte desses blocos cai inteiramente sobre continente e não
tem oceano algum para integrar. O `mask_table` lista esses blocos e o FMS os
elimina da decomposição:

```
PETs efetivos = NIPROC * NJPROC - Nmask
```

O atrativo é direto: menos PEs para o mesmo trabalho útil. No exemplo real do
incidente, `LAYOUT = 15, 9` dá 135 blocos, dos quais 7 são secos, resultando em
128 PETs efetivos.

O ponto importante, e que costuma passar batido, é **o que acontece com a
região de grade** que pertencia àqueles blocos. Ela não some do modelo. As
células continuam existindo no espaço de índices `[1..180] x [1..158]`. O que
some é o PE que cuidava delas.

---

## 4. O MOM6 lida bem com isso

Do lado do FMS não há problema nenhum. O `mpp_define_domains` recebe a
`maskmap`, monta o domínio apenas sobre os blocos vivos e ajusta as trocas de
halo para não procurar vizinho onde não há. O log confirma:

```
NOTE from PE 0: MOM_domains_init: reading maskmap information from mask_table.7.15x9
parse_mask_table: Number of domain regions masked in MOM_in = 7
...
======== COMPLETED MOM INITIALIZATION ========
```

A inicialização do oceano termina limpa. Se o MOM6+SIS2 estivesse rodando
standalone, o run seguiria normalmente. É por isso que o `mask_table` continua
sendo uma ferramenta legítima: o defeito não está nele.

O motivo de fundo é a **direção em que a pergunta é feita**:

| Operação | Pergunta | Célula sem dono |
|---|---|---|
| Halo (FMS) | "quem é meu vizinho ao norte?" | "ninguém" é resposta legítima e tratada |
| Redução global (FMS) | "somar sobre os PEs vivos" | não participa |
| Escrita de saída (FMS) | "cada PE grava seu pedaço" | sai como valor ausente no arquivo |
| Regrid (ESMF) | "quem é o dono da célula (i,j)?" | **não há resposta válida** |

O FMS pergunta de dentro para fora, a partir de quem existe: eu, meus vizinhos.
Ausência é uma possibilidade prevista, e o `mask_table` funciona exatamente por
isso. O ESMF pergunta de fora para dentro, a partir do espaço declarado: para
cada célula deste retângulo, quem manda nela. Aí ausência não é resposta.

> **Nota lateral, independente deste problema.** O `mpp_compute_extent` do FMS
> distribui as sobras da divisão de forma simétrica (`Y-AXIS = 53 52 53` para 158
> pontos em 3 blocos), ao passo que o `domain-mom6.bash` as coloca nos primeiros
> blocos (`53 53 52`). Isso não tem relação com a falha descrita aqui, mas afeta
> quem gerar um `mask_table` para uso standalone: as fronteiras internas podem
> ficar deslocadas em um ponto e mascarar o bloco errado. Ver a ressalva da
> seção 5 de `domain-mom6.md`.

---

## 5. Como o cap descreve a grade ao ESMF

Depois que o `ocean_model_init` retorna, o cap precisa entregar ao ESMF uma
geometria sobre a qual os campos serão criados e interpolados. Ele faz assim
(`mom_cap_MONAN.F90`, rotina `InitializeRealize`):

```fortran
npes_ocn = mpp_get_domain_npes(is%ocean_public%domain)      ! quantos PEs vivos
call mpp_get_compute_domains(domain, xb, xe, yb, ye)        ! limites de cada um

do n = 1, npes_ocn
  deBlockList(1,1,n) = xb(n);  deBlockList(1,2,n) = xe(n)
  deBlockList(2,1,n) = yb(n);  deBlockList(2,2,n) = ye(n)
  petMap(n) = pe(n) - pe(1)
end do

distGrid = ESMF_DistGridCreate(minIndex=(/1,1/), maxIndex=(/ni,nj/), &
                               deBlockList=deBlockList, delayout=deLayout, rc=rc)
```

Leia com atenção a chamada final. Ela contém duas afirmações:

1. `minIndex` e `maxIndex` declaram que o espaço de índices vai de `(1,1)` a
   `(180,158)`, ou seja, a grade inteira.
2. `deBlockList` afirma que a lista de blocos fornecida reparte esse espaço.

Sem `mask_table`, as duas afirmações são verdadeiras: há um bloco por PE e a
união deles é exatamente a grade. Com `mask_table`, a primeira continua
verdadeira e a segunda deixa de ser, porque os blocos secos não estão em
`mpp_get_compute_domains`. Ninguém está mentindo de propósito: o cap está
usando a única fonte de informação que consultou, e essa fonte, corretamente,
só conhece os blocos que têm PE.

Vale reler a primeira linha do trecho com o glossário em mente:

```fortran
npes_ocn = mpp_get_domain_npes(...)   ! isto conta PEs
...
deBlockList(:,:,n), n = 1, npes_ocn   ! e é usado para contar DEs
```

O cap importou para o ESMF a identidade "um bloco é um PE", que vale no FMS e
não vale no ESMF. Onde o FMS tem 128 blocos porque tem 128 PEs, o ESMF
precisaria de 135 DEs distribuídos sobre 128 PETs.

### Uma representação densa para um objeto esparso

Vale sublinhar que **a máscara é perfeitamente representável no ESMF**. O que
não é representável é a máscara *na forma que o cap escolheu*.

A forma acima, `minIndex`/`maxIndex` mais `deBlockList`, é **densa**, no mesmo
sentido de uma matriz densa: toda posição do espaço declarado precisa existir.
Não há sintaxe para dizer "esta parte não está aqui".

O ESMF oferece também a forma **esparsa**, o `arbSeqIndexList`, em que cada PET
entrega apenas a lista dos índices globais que possui. Nada é prometido sobre
cobertura, porque nenhum retângulo é declarado. Um domínio mascarado é, por
natureza, esparso, e o cap o está guardando numa estrutura densa:

```
FMS diz:      "tenho 128 blocos, aqui estão eles"            (esparso, correto)
cap traduz:   "o retângulo 180x158 é repartido nestes 128"    (denso, falso)
GridToMesh:   "então quem é o dono de (3,150)?"               (sem resposta)
```

O mesmo `mask_table`, publicado como `arbSeqIndexList` ou como `Mesh`,
atravessaria o conector sem incidente. É essa observação que orienta as duas
rotas de correção da seção 10.

---

## 6. O buraco

Convém, antes, separar mais um par de espaços de índices que costuma se
confundir:

- **coordenada de bloco**, de `(1,1)` a `(NIPROC, NJPROC)`. É o que o
  `mask_table` lista: a linha `1,3` significa coluna 1, linha 3 de blocos.
- **índice de célula**, de `(1,1)` a `(NI_G, NJ_G)`. É o que o `DistGrid`
  declara em `minIndex` e `maxIndex`.

Com `LAYOUT = 43, 3`, o bloco `(1,3)` mascarado ocupa as células `i = 1..5`,
`j = 106..158`:

```
   coordenada de bloco                    índice de célula (j)
                                          .
   bloco  (1,3)   (2,3)  (3,3)  ...       |
        +-------+------+------+---        |  j = 106..158   <- 5 x 53 células
        | ????? |  DE  |  DE  |  ...      |                    sem dono
        +-------+------+------+---        |
   bloco  (1,2)   (2,2)  (3,2)  ...       |
        +-------+------+------+---        |
        |  DE   |  DE  |  DE  |  ...      |  j =  54..105   <- PET 171 mora aqui
        +-------+------+------+---        |
   bloco  (1,1)   (2,1)  (3,1)  ...       |
        +-------+------+------+---        |
        |  DE   |  DE  |  DE  |  ...      |  j =   1..53
        +-------+------+------+---        |
                                          .
          i=1..5  i=6..10 i=11..15 ...    (índice de célula, eixo i)
```

As células de `i = 1..5`, `j = 106..158` existem no espaço de índices declarado
e não pertencem a DE algum. Do ponto de vista do ESMF, elas estão num limbo:
foram prometidas, não foram entregues.

Os números conferem com o log do PET 171, que reporta o próprio domínio como
`isc,iec,jsc,jec = 1 5 54 105`, e com o `Y-AXIS = 53 52 53` impresso pelo FMS na
inicialização.

---

## 7. Por que o erro aparece tão longe da causa

Esta é a parte que mais custa tempo de depuração. A sequência real:

```
ocean_model_init            OK   (o FMS está satisfeito)
ESMF_DistGridCreate         OK   (nao valida a cobertura)
ESMF_GridCreate             OK
ESMF_GridAddCoord           OK
InitializeRealize concluido OK
   ...
conector OCN-TO-MED
  ESMF_FieldRegridStore
    ESMF_GridToMesh         FALHA
```

O `ESMF_DistGridCreate` **não verifica** se o `deBlockList` cobre o espaço
declarado. É uma escolha de desempenho compreensível: essa checagem custaria
uma varredura global a cada criação de objeto. O resultado é que o objeto
inconsistente circula por várias camadas antes de alguém realmente precisar da
informação que falta.

Quem precisa dela é o cálculo dos pesos de interpolação. Para gerar os pesos, o
ESMF converte a `Grid` numa `Mesh`, e para montar cada elemento da malha ele
pergunta qual PET é o dono daquela célula. Nas células do buraco, a resposta é
lixo:

```
ERROR  PET171  ESMCI_GridToMesh.C:882 GridToMesh() Internal error: Bad condition
               ESMCI_Mesh.C, line:1786: Bad processor number!
ERROR  PET171  ESMF_FieldRegridStore ... OCN-TO-MED  Phase 'IPDv05p6b'
```

Logo depois vem o SIGSEGV, no PET vizinho ao buraco. No `esmApp_run.log`, o que
se vê é apenas isto:

```
======== COMPLETED MOM INITIALIZATION ========
Program received signal SIGSEGV
rank 171 died from signal 11
```

Nada nessa saída aponta para máscara, para `mask_table` ou para o `LAYOUT`. A
mensagem útil está no log por PET, que só existe se `log_kind = 'multi'`.

---

## 8. Como reconhecer o sintoma

Três sinais que, juntos, fecham o diagnóstico:

1. O SIGSEGV ocorre **imediatamente após** `COMPLETED MOM INITIALIZATION`, sem
   nenhum passo de acoplamento concluído.
2. No backtrace, todos os quadros abaixo do `esmapp` estão em endereços altos e
   sem símbolo, o que indica biblioteca compartilhada, ou seja, `libesmf.so`. O
   MOM6 e o FMS são bibliotecas estáticas e apareceriam com linha de fonte.
3. O `logs/PET<rank>.esmApp.log` do rank que morreu termina em `GridToMesh` com
   `Bad processor number!`.

Um teste de um minuto, sem recompilar nada: comente a linha `MASKTABLE` no
`MOM_input` e no `SIS_input`, ajuste o `LAYOUT` para um produto igual ao número
de PETs do oceano e submeta de novo. Se o run passa, era isso.

Não confundir com um outro conjunto de mensagens `ERROR`, inofensivo, que
aparece no primeiro passo de acoplamento (`ESMF_TimeLT` e `ESMF_TimeGT` com
"Object Set or SetDefault method not called", dois por campo importado). Essas
vêm dos campos de importação ainda sem `TimeStamp` no instante inicial e não
interrompem a execução.

---

## 9. O que fazer hoje

Usar um `LAYOUT` cujo produto `NIPROC * NJPROC` já seja o número de PETs do
oceano, sem `mask_table`:

```bash
module load cray-netcdf
bash domain-mom6.bash --topog INPUT/ocean_topog.nc --no-mask --pes 128 \
     --mom-input MOM_input --sis-input SIS_input
```

Na grade 180 x 158 com 128 PETs isso resulta em `LAYOUT = 16, 8`. Os 7 blocos
que são só terra continuam existindo e recebem PET, e o custo disso é pequeno,
justamente por não haver oceano neles para integrar. Foi essa a configuração
que completou os 24 passos de acoplamento.

O `--target-eff`, que busca um número de PETs efetivos descontando a máscara,
permanece disponível e continua correto, mas serve ao MOM6+SIS2 standalone. No
acoplado ele produz exatamente a configuração que não funciona.

---

## 10. Como corrigir de verdade

Duas rotas, com custos bem diferentes.

### Rota A: completar o `deBlockList` com DEs fantasma

Manter a `Grid` e incluir os blocos mascarados na lista, atribuindo cada um a um
PET que já existe. O `ESMF_DELayout` aceita mais de um DE por PET, então o
número de DEs volta a ser `NIPROC * NJPROC` enquanto o de PETs continua sendo o
dos blocos vivos.

O que precisa ser feito:

- reconstruir os limites de **todos** os blocos com `mpp_get_layout` mais
  `mpp_get_domain_extents`, que são calculados antes da aplicação da máscara;
- distribuir os fantasmas entre os PETs, de preferência em round-robin;
- iterar sobre `localDe` no `ESMF_GridGetCoord`, já que agora há PETs com mais
  de um DE, e preencher as coordenadas dos fantasmas lendo o `ocean_hgrid.nc`,
  pois numa grade tripolar elas não podem ser calculadas analiticamente;
- marcar essas células como terra no `ESMF_GRIDITEM_MASK` e usar
  `srcMaskValues` no `ESMF_FieldRegridStore`;
- adaptar `mom_import`, `mom_export` e o mediador, que hoje assumem um DE por
  PET.

Resolve a máscara e deixa como herança a complicação permanente de múltiplos
DEs por PET em todo o caminho de dados.

Um alento: "mais de um DE por PET" não é território desconhecido nesta base de
código. O cap do MPAS já passa por isso, por outro motivo, e o comentário
`B-53` do `mpas_cap_methods.F90` registra a solução: com `regDecomp` 2D o número
de DEs supera o de PETs, o `ESMF_GridGetCoord` falha com "must provide localDe
argument for localDeCount > 1", e o código faz o laço explícito sobre cada DE
local. O padrão já está funcionando do lado atmosférico.

### Rota B: `Mesh` com `DistGrid` arbitrário

Trocar a geometria do oceano de `Grid` para `Mesh`, com um `DistGrid` construído
a partir da lista de índices globais das células locais de cada PET:

```fortran
distGrid = ESMF_DistGridCreate(arbSeqIndexList=meus_indices_globais, rc=rc)
mesh     = ESMF_MeshCreate(..., elementDistgrid=distGrid, rc=rc)
```

Aqui não existe promessa de cobertura retangular a ser quebrada: o `DistGrid`
arbitrário foi feito para decomposições irregulares. As células dos blocos
mascarados simplesmente não entram na lista de ninguém, e o problema deixa de
existir por construção. É o que o UFS/CMEPS faz com o MOM6.

O `mom_cap_methods.F90` já traz os dois ramos, `ESMF_GEOMTYPE_MESH` e
`ESMF_GEOMTYPE_GRID`, herdados do cap oficial, incluindo o `State_GetFldPtr_1d`
para campos rank-1 por elemento. O trabalho concentra-se em construir a malha e
fazer o mediador consumir campos 1D do lado do oceano.

---

## 11. Quanto isso vale

Fração de blocos 100% terra na grade atual (180 x 158, 69,2% de oceano):

| Blocos | LAYOUT | Bloco (pts) | Secos | PETs poupados |
|---:|:---|:---|---:|---:|
| 64 | 8x8 | 22,5 x 19,8 | 2 | 3,1% |
| 128 | 16x8 | 11,2 x 19,8 | 7 | 5,5% |
| 256 | 16x16 | 11,2 x 9,9 | 23 | 9,0% |
| 512 | 32x16 | 5,6 x 9,9 | 58 | 11,3% |

O ganho cresce com o número de PETs, porque blocos menores acompanham melhor a
linha de costa, e tende assintoticamente à fração de terra da grade, 30,8%.

A leitura prática: com 2 graus e 128 PETs, são 7 PETs, e não compensa mexer no
caminho de dados do acoplador. Na migração para 0,25 grau, com centenas ou
milhares de PETs, passa a compensar, e a Rota B é a que converge com o upstream,
reduzindo a dívida de manutenção do cap.

---

## 12. Validação, quando chegar a hora

O caso de teste já existe: `mask_table.7.15x9` com `LAYOUT = 15, 9` produz 128
PETs efetivos, os mesmos do run que funcionou. O critério é rodar 24 passos com
e sem máscara e exigir saída **bit a bit idêntica** nas células de oceano,
comparando com o `analisa_comparacao.py`. Qualquer diferença indica que uma
célula mascarada está participando do regrid.

---

## Resumo

| | Sem `mask_table` | Com `mask_table` |
|---|---|---|
| MOM6 + FMS | funciona | funciona |
| `DistGrid` do cap | cobertura completa | cobertura com buracos |
| `GridToMesh` no conector | funciona | `Bad processor number!` |
| PETs ociosos | os blocos secos consomem PET | nenhum |
| Situação no acoplado | **usar hoje** | aguardando correção do cap |

A linha de fundo: o `mask_table` é uma boa ferramenta, o MOM6 a usa
corretamente, o split de comunicador não tem relação com o problema, e o ESMF
tem como representar um domínio mascarado. Falta apenas o cap escolher a
representação adequada.
