# mede_smt.py: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/coupler/mede_smt.py`.

Para o resultado já obtido com esta ferramenta e a decisão que ele sustenta, ver `docs/SMT-Jaci.md`. Este documento trata de como operá-la.

## 1. Para que serve

O nó de cálculo da Jaci tem 256 cores físicos, em dois sockets de 128 Zen5, com SMT ligado, o que expõe 512 CPUs lógicas. Para um mesmo número de PETs existem duas formas de alocar:

```bash
# A: 512 PETs em 2 nós, 1 rank por core físico, segunda thread ociosa
bash run_esmApp.jaci -n 512 -w 01:00:00

# B: 512 PETs em 1 nó, 2 ranks por core físico, SMT em uso
bash run_esmApp.jaci -n 512 --ppn 512 --allow-smt -w 01:00:00
```

O `mede_smt.py` lê os logs de PET das duas configurações e responde se B é mais lento, igual ou mais rápido que A, e em qual componente a diferença aparece.

Os componentes reconhecidos são `MED`, `MPAS`, `OCN` e `ICE`. O de gelo aparece quando `use_sis2_dynamic` está ligado, e precisa estar no mesmo estado nas duas configurações; ver a seção 7.

Ele não executa nada. É pós-processamento de logs de execuções que você já rodou.

## 2. O confundimento que a ferramenta desfaz

Este é o ponto central, e ler os números sem entendê-lo leva à conclusão errada.

Com o mesmo número de PETs, B usa **metade dos nós** de A e, portanto, metade dos cores físicos. O tempo de parede de B seria duas vezes o de A mesmo que o SMT fosse perfeitamente neutro. A razão bruta B/A não isola o SMT: ela mistura o efeito do SMT com o simples fato de haver menos hardware.

O que isola o SMT é o **excesso sobre esse fator**. Por isso o script normaliza pelo número de nós e reporta o custo em nó vezes segundo por passo, que é a grandeza comparável entre as duas configurações e a que aparece na contagem de node-hours.

O relatório separa explicitamente as duas leituras:

```
  1) TEMPO DE PAREDE (time-to-solution)
     B/A = ... Como B usa 2/1 do hardware de A, o fator
     seria 2.00 mesmo com SMT neutro. Este numero NAO isola o SMT.

  2) CUSTO DE MAQUINA (no x segundo, efeito do SMT isolado)
     B/A = ...   (incerteza: +/- ...% linear, +/- ...% em quadratura)
```

Informe os nós de cada configuração com `--nos-a` e `--nos-b`. Quando o banner do job estiver presente nos logs, o valor lido dele prevalece sobre o informado, com aviso.

## 3. Outras decisões de metodologia

**Soma, não média por chamada.** O script acumula a soma das durações dentro de cada passo de acoplamento. Componentes que subciclam internamente registram mais de um par `intro`/`extro` por passo, e a média por chamada compararia uma chamada longa com várias curtas, subestimando o custo de quem subcicla.

**Máximo entre PETs, não média.** O custo de um componente num passo é o maior tempo entre os PETs. Os PETs se sincronizam em barreiras coletivas: o grupo só avança quando o último termina, e o tempo ocioso dos rápidos é desperdício, não economia.

**O primeiro passo é descartado.** Ele carrega alocação preguiçosa, primeiro toque de páginas de memória e o custo inicial dos conectores, e não representa o regime permanente. Ajustável com `--descartar`.

**Delimitação das chamadas.** O padrão exige o ponto final em `Run intro.` e `Run extro.`. As linhas de `StateLog` repetem `Run intro` seguido de outro texto e não delimitam chamada nenhuma; sem o ponto, elas entrariam na conta.

## 4. Preparar as rodadas

O experimento precisa de repetição, porque a diferença procurada é da ordem de poucos por cento e o ruído entre rodadas é comparável a ela. O padrão do script espera três repetições de cada configuração, em diretórios `logs.A1`, `logs.A2`, `logs.A3` e `logs.B1`, `logs.B2`, `logs.B3`.

Duas exigências que a autoverificação cobra, e que valem ter em mente ao montar as rodadas.

**Mesmo número de PETs em A e B.** É a premissa do teste controlado. Diferente, e a comparação é interrompida com erro.

**Modo sequencial.** Em `concurrent` o tempo por passo é o maior entre os avanços, e o balanceamento entre os blocos muda entre as configurações, confundindo o resultado. Além disso, em B os PETs de todos os componentes ocupariam um único nó e dividiriam os mesmos domínios NUMA. O script avisa quando detecta `concurrent`.

**Layout compartilhado.** Com `pet_layout = 'split'` o `run_esmApp.jaci` monta um `select` heterogêneo, com um chunk por componente, e cada bloco fecha em nós inteiros. A configuração B então não cai num nó só: ela usa pelo menos um nó por bloco, e a razão de nós entre A e B deixa de ser a que o teste supõe. O script lê o número de nós do banner e corrige a conta, mas o experimento já não é o que se queria, porque A e B passariam a diferir também na topologia dos blocos. O script avisa quando detecta `split`.

**Mesmo conjunto de componentes.** Se uma configuração rodar com gelo e a outra sem, a comparação é interrompida com erro. A razão está na seção 7.

Tudo o mais deve ser igual entre A e B: mesma malha, mesma partição METIS, mesma `nuopc.input`, mesma fila, mesmo número de passos.

## 5. Uso

Com a estrutura de diretórios padrão:

```bash
python3 tools/coupler/mede_smt.py --jobs 16
```

Apontando os diretórios explicitamente:

```bash
python3 tools/coupler/mede_smt.py \
  --a logs.A1 logs.A2 logs.A3 \
  --b logs.B1 logs.B2 logs.B3
```

Com exportação:

```bash
python3 tools/coupler/mede_smt.py --descartar 2 \
  --csv resultado.csv --grafico smt.png
```

Outra razão de nós, por exemplo 4 contra 2:

```bash
python3 tools/coupler/mede_smt.py --nos-a 4 --nos-b 2
```

## 6. Opções

| opção | padrão | significado |
| - | - | - |
| `--a DIR [DIR ...]` | `logs.A1 logs.A2 logs.A3` | diretórios da configuração A |
| `--b DIR [DIR ...]` | `logs.B1 logs.B2 logs.B3` | diretórios da configuração B |
| `--nos-a N` | 2 | nós usados por A |
| `--nos-b N` | 1 | nós usados por B |
| `--descartar N` | 1 | passos iniciais descartados |
| `--padrao GLOB` | automático | glob dos logs, quando o nome fugir do usual |
| `--jobs N` | 1 | processos paralelos na leitura dos logs |
| `--csv ARQ` | - | grava os resultados em CSV |
| `--grafico ARQ.png` | - | grava um gráfico de barras comparativo |
| `-h` | - | ajuda |

Sem `--padrao`, o script reconhece nomes no formato `PET<numero>.<algo>.log`, com o número obrigatório. Isso descarta o `esmApp_run.log`, que convive no mesmo diretório e não pertence a PET nenhum.

`--grafico` exige `matplotlib`. Sem ele, o script avisa e segue sem gerar o gráfico.

`--jobs` acelera bastante a leitura quando há centenas de logs de PET por rodada. Vale usar.

## 7. A autoverificação

Antes de comparar, o script confere a partir do **conteúdo** dos logs que A e B são o que se supõe. A razão é direta: trocar os diretórios `logs.A` por `logs.B` inverteria a conclusão sem nenhum sinal, e o resultado passaria a sustentar uma decisão de projeto.

São seis verificações.

O número de PETs precisa ser igual entre A e B. Diferente é erro, e a comparação para.

O conjunto de componentes precisa ser igual entre A e B, e entre as repetições de cada configuração. Diferente é erro. Esta verificação foi acrescentada em setembro de 2026 e vale explicar por quê. As linhas da tabela só saem quando o componente existe nas duas configurações, então um gelo presente apenas em A simplesmente sumiria; e a linha `TOTAL`, que soma os componentes, compararia somas de conjuntos diferentes. Num caso de teste com quatro componentes em A e três em B, o custo de máquina saiu 0,977 em vez de 1,062: o veredito anunciaria melhora de 2,3% onde havia degradação de 6,2%, sem nenhum sinal de que algo estava errado.

O modo de acoplamento precisa ser o mesmo nas duas, e as rodadas de uma mesma configuração não podem misturar modos. Modo `concurrent` nas duas gera aviso, pelo motivo da seção 4.

O layout precisa ser o mesmo nas duas. Layout `split` em qualquer uma gera aviso, também pelo motivo da seção 4.

O regime de ocupação do core, lido do banner do job quando presente, precisa ser compatível: A sem SMT, B com SMT. Incompatibilidade é erro, com a mensagem sugerindo que os diretórios podem estar trocados.

O número de nós lido do banner prevalece sobre `--nos-a` e `--nos-b`, com aviso quando divergir do informado.

Erros interrompem a comparação e o script sai com código 1. Avisos seguem para o `stderr` e a comparação continua.

## 8. Como ler o veredito

O bloco final tem três partes.

A primeira é o tempo de parede, com o lembrete de que ele não isola o SMT.

A segunda é o custo de máquina, com a incerteza calculada de duas formas: soma linear dos erros relativos, que é conservadora, e soma em quadratura, que assume independência entre as rodadas. O script classifica o resultado em quatro faixas:

| faixa | leitura |
| - | - |
| efeito dentro do critério em quadratura, ou abaixo de 2% | INCONCLUSIVO. Aumente o número de rodadas. |
| entre o critério em quadratura e a soma linear | MARGINAL. Repita com mais rodadas antes de citar o valor. |
| acima, com custo maior que 1 | o SMT degrada o custo de máquina. |
| acima, com custo menor que 1 | o SMT melhora o custo de máquina. |

Trate INCONCLUSIVO e MARGINAL como o que são: o experimento não decidiu. Citar um número dessas faixas como se fosse resultado é o modo mais fácil de transformar ruído em conclusão.

A terceira parte é a decisão sobre o padrão de PETs por nó. Ela pode divergir das anteriores, e isso não é contradição: se A for mais rápido em tempo de parede mas o SMT reduzir o custo de máquina, a escolha depende de qual é o recurso escasso, prazo ou cota de node-hours.

O relatório fecha lembrando que B usa metade dos nós e, portanto, metade da memória agregada. Um encerramento por falta de memória em B, com código 137, é resultado da medição, não erro de configuração.

## 9. O que mudou em setembro de 2026

Vale saber, porque muda a confiança que se pode ter em resultados anteriores.

**A verificação do modo de acoplamento estava quebrada com binário atual.** O padrão procurado era `ESM: modo SEQUENTIAL` ou `ESM: modo CONCURRENT`, formato anterior à v14.20. Desde a separação dos dois eixos o driver grava `ESM: layout SPLIT (execucao SEQUENTIAL)`, que não casava. O conjunto de modos ficava vazio e três verificações eram puladas em silêncio: consistência entre repetições, igualdade entre A e B, e o aviso de `concurrent`. Justamente as que protegem contra o erro mais grave do experimento, que é medir no modo errado. Os dois formatos passaram a ser aceitos.

Consequência prática: qualquer medição feita com binário v14.20 ou posterior rodou sem essas três checagens. Se houver resultado dessa época que ainda sustente uma decisão, vale reprocessar os logs com esta versão antes de citá-lo.

**O gelo entrou na ordem de exibição.** O leitor de logs sempre foi genérico e já capturava o rótulo `ICE`, mas sem estar na lista de ordem ele caía no rabo alfabético e aparecia antes de `MPAS` e `OCN`, sugerindo uma importância que não tem.

**Nova verificação do conjunto de componentes**, descrita na seção 7.

**Nova verificação do eixo espacial**, descrita nas seções 4 e 7.

**A agregação entre repetições passou a usar a interseção das chaves.** Antes usava as chaves da primeira repetição, e uma divergência de componentes entre repetições estourava com `KeyError` antes de a mensagem útil ser impressa.

## 10. Limitações conhecidas

**As mensagens do log ESMF precisam estar em nível INFO.** Com `ESMF_LOGKIND_Multi_On_Error`, que é a configuração recomendada para produção, os pares `Run intro.` e `Run extro.` não são gravados e não há o que medir. As rodadas de medição precisam do log completo.

**A verificação de regime depende do banner do job.** Sem `esmApp_run.log` ou o arquivo de saída do PBS no diretório, o script não tem como conferir que A e B são o que se supõe quanto à ocupação do core, e a checagem é pulada. Preserve o banner junto dos logs.

**O número de nós lido do banner prevalece sobre `--nos-a` e `--nos-b`.** Isso é proteção, não limitação, mas convém saber: se o valor informado divergir, o script avisa e usa o do banner. Uma divergência normalmente indica que o experimento não foi o que se pensava.

## 11. Documentos relacionados

`docs/SMT-Jaci.md`, com a caracterização do hardware, a contabilidade das filas e os resultados já obtidos.

`docs/uso-plan-layout.md`, para planejar a topologia. O `plan-layout.py` tem a mesma guarda de `--allow-smt` e recusa planejar acima de 256 PETs por nó sem ela, agora também para `--ppn-ice`. Lembre que o experimento de SMT roda em layout compartilhado, então o modo do planejador que corresponde a ele é `--shared --npes N --ppn K`, e não o de blocos.

`docs/uso-analisa-balanceamento.md`, para a outra pergunta de desempenho: a repartição entre atmosfera e oceano está equilibrada?
