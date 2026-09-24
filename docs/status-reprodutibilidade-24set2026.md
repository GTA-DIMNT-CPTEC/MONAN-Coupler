# Reprodutibilidade e desempenho do MONAN-Coupler: status em 24/09/2026

**O acoplador é reprodutível bit a bit na configuração de produção.** Depois da correção de 22/09, 32 execuções em cinco baterias saíram idênticas, dentro de cada configuração, em tudo que é medido, do estado da atmosfera aos cálculos internos do gelo: modo sequencial (12 execuções), modo concorrente (8), modo concorrente com o módulo de icebergs ligado (8) e, com o dobro de processadores, 144 PETs (4). Antes da correção, na mesma configuração, nenhum conjunto de quatro execuções chegava a um resultado estável.

**A causa não era física, e sim a forma de somar nos remapeamentos.** Para passar um campo de uma grade para outra, o ESMF soma, em cada ponto de destino, várias contribuições da grade de origem. Em ponto flutuante, a ordem da soma altera o último algarismo. O ESMF controla essa ordem em duas camadas: a soma final, no destino, e as somas parciais, na origem. A primeira já tinha sido fixada em setembro, na maior parte do código. A segunda nunca tinha sido: sem o parâmetro `srcTermProcessing`, o ESMF escolhe o agrupamento das somas parciais medindo o desempenho durante a execução, e a escolha pode mudar de uma execução para outra. Uma diferença no último algarismo, em poucos pontos, bastava para que atmosfera, oceano e gelo divergissem depois de algumas horas simuladas.

**Correção.** Duas mudanças no código do acoplador, sem tocar nos modelos: `B-SRCTERM-01` fixa as somas parciais (`srcTermProcessing=0`) nos 10 remapeamentos do mediador e nas 60 ligações entre componentes; `B-METHODS-TERMORDER-01` fixa a soma final em três remapeamentos de um arquivo auxiliar do mediador que tinham ficado fora da correção de setembro. É a mesma solução adotada em outros sistemas acoplados que usam ESMF.

**Um ganho de ferramenta.** A execução concorrente saiu idêntica, bit a bit, à execução sequencial reprodutível (`seq_repro`). Essa variante do modo sequencial foi desenhada para entregar a cada componente exatamente os mesmos dados que ele receberia no concorrente, só que um de cada vez, mas isso nunca tinha sido verificado. Agora está: qualquer problema futuro pode ser investigado no modo sequencial, onde causa e efeito aparecem em ordem, sabendo que a conclusão vale para o concorrente.

**Desempenho: 2,3 vezes mais rápido.** Um dia simulado levava 6 min 06 s com 72 processadores. Com o dobro de processadores (144), passou a 3 min 54 s. A medição do tempo de cada componente mostrou então que o gargalo era o oceano, e não a atmosfera, como se supunha: a atmosfera passava metade do tempo parada esperando o oceano. Redistribuindo os processadores a favor do oceano, o mesmo dia simulado caiu para 3 min 20 s com os mesmos 144 processadores, e para 2 min 38 s com 152.

| Processadores (atmosfera + oceano + gelo) | Um dia simulado |
| --- | --- |
| 72 (64 + 4 + 4) | 6 min 06 s |
| 144 (128 + 8 + 8) | 3 min 54 s |
| 144 (128 + 12 + 4) | 3 min 20 s |
| 152 (128 + 20 + 4) | 2 min 38 s |

**Um defeito corrigido no caminho (`B-ICE-DECOMP-01`).** A primeira tentativa com 144 processadores quebrou na inicialização do gelo. O domínio do gelo era dividido entre os processadores por duas regras diferentes, a do modelo de gelo e a do código de acoplamento, que só coincidiam por acaso com 4 processadores. A correção faz o acoplamento usar a divisão escolhida pelo próprio modelo de gelo, como já acontecia no oceano, e foi validada: onde a divisão antiga já estava certa, o resultado ficou idêntico bit a bit; onde ela quebrava, a execução foi até o fim.

**O que muda o resultado quando se muda o número de processadores.** A reprodutibilidade vale para uma configuração fixa de processadores; mudar a configuração pode mudar os números, e isso é normal num modelo paralelo. As medições de 23 e 24/09 mostraram exatamente quando:

| Mudança | Resultado |
| --- | --- |
| dividir o domínio do gelo de outra forma | não muda |
| redistribuir processadores entre oceano e gelo, mantendo o total e a atmosfera | não muda |
| mudar o total de processadores, mesmo com a atmosfera igual | muda |
| mudar o número de processadores da atmosfera | muda |

Na prática: cada total de processadores precisa de uma verificação própria de reprodutibilidade (uma bateria de quatro execuções, hoje cerca de dez minutos de máquina), e, dentro de um total já verificado, oceano e gelo podem ser ajustados livremente para desempenho.

**Os icebergs estão ligados, mas inertes.** A bateria com icebergs saiu idêntica à sem icebergs, e o motivo está no log: não existe nenhum iceberg na simulação. Não há arquivo inicial de icebergs, e o desprendimento (calving), que viria do componente de terra, é nulo. O módulo roda a cada passo sobre uma lista vazia. Para a produção atual isso não afeta a reprodutibilidade, mas significa que o código de icebergs ainda não foi testado.

**Conclusões revertidas.** "A fonte está no gelo" e "o derretimento basal diverge primeiro" (21/09): a divergência do gelo era efeito do ruído que chegava por um remapeamento. Também foi revertida a eliminação do remapeamento do gelo (20/09), que se baseou em um diagnóstico que só enxergava a região de um processador. Padrão comum a todas as conclusões revertidas ao longo da investigação: instrumento com cobertura ou resolução insuficiente.

**Defeitos físicos encontrados no caminho, independentes da reprodutibilidade:**

| Defeito | Efeito | Situação |
| --- | --- | --- |
| `B-ICE-SST-ZEROK-01` | na primeira troca, parte dos pontos de oceano com gelo recebe temperatura do mar de 0 K; o gelo sofre uma hora de congelamento basal equivalente a cerca de 65 kW/m² | correção simples no acoplador, a fazer |
| `B-ICE-FORCING-T0-01` | na primeira troca, o gelo recebe forçamento atmosférico nulo; a partir da segunda, o forçamento chega normalmente (confirmado em 23/09) | registrado |
| `B-ICE-FLUXDERIV-01` | as derivadas dos fluxos em relação à temperatura nunca chegam ao gelo; a temperatura da superfície é resolvida sem realimentação da atmosfera | baixa prioridade |

**Correções acumuladas, todas mantidas:** `B-ICE-DECOMP-01` (23/09), `B-SRCTERM-01` e `B-METHODS-TERMORDER-01` (22/09), mais as oito de setembro (`B-REGRID-TERMORDER-01`, `B-CPL-TERMORDER-01`, `B-EXPORT-ALLREDUCE-01`, `B-INJECT-HALO-01`, `B-STARTSTAMP-LEN-01`, `B-DIAG-IMPORT-INCOMPLETO-01`, `B-IMPORT-DESCONECTADO-01`, `B-BASE-RAIZ-NC-01`). Todas as correções de 22 e 23/09, a instrumentação de teste, as ferramentas e a documentação estão na `develop` do GitHub desde 24/09.

**Decisões para o GTA:**

| Decisão | Opções | Base |
| --- | --- | --- |
| as duas opções do ESMF em produção | manter ligadas, ou ligar só em testes | depende do custo medido (fixar as somas parciais desliga uma otimização de comunicação); o custo isolado ainda não foi medido, mas com elas ligadas a configuração de 152 processadores já roda 2,3 vezes mais rápido que a de 72 |
| número de processadores em produção | 152 (128 + 20 + 4, medido: 2 min 38 s por dia simulado) ou 156 (128 + 24 + 4, estimado em cerca de 2 min 20 s) | a partir de cerca de 156, mais processadores para o oceano já não aceleram, porque a atmosfera passa a ser o gargalo; a configuração escolhida precisa de uma bateria de reprodutibilidade |
| icebergs | fornecer uma fonte (arquivo inicial ou calving) e testar a reprodutibilidade com icebergs de fato ativos, ou desligar o módulo, que hoje só consome tempo | seção 2.9 da passagem de contexto |
| ferramentas de medição | já incorporadas ao repositório em 24/09, com documentação | decisão tomada |
