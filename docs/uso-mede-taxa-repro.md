# mede-taxa-repro.sh: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/coupler/mede-taxa-repro.sh`, a ferramenta de baterias de reprodutibilidade binária.

## 1. Para que serve

O script executa o acoplado N vezes na mesma configuração, guarda as saídas de cada execução e compara **todos os pares** entre si. Ele responde à pergunta: nesta configuração, duas execuções idênticas produzem o mesmo resultado bit a bit?

**Por que uma bateria, e não uma dupla rodada.** Em 16/09/2026, duas duplas rodadas na mesma configuração deram resultados opostos: a primeira reproduziu nos 145 registros, a segunda divergiu no registro 7. A não reprodutibilidade era **intermitente**: às vezes duas execuções coincidiam por acaso. Uma dupla rodada que reproduz, portanto, não prova nada, e qualquer conclusão tirada de um único par pode ser sorte. Com N execuções comparam-se N(N−1)/2 pares: 4 execuções dão 6 comparações, 8 dão 28. O custo em fila cresce linearmente, e a informação, quadraticamente.

Foi com este script que a causa da não reprodutibilidade do acoplador foi localizada e a correção confirmada, em 22 e 23/09/2026 (seção 10).

## 2. Antes de começar

### 2.1 O stream `reprodiag` no `streams.atmosphere`

O script compara o arquivo `reprodiag.nc`, que o MPAS grava a cada 10 minutos simulados na raiz do experimento. O bloco precisa estar declarado no `streams.atmosphere`, antes de `</streams>`; o script verifica e aborta se não estiver:

```xml
<stream name="reprodiag"
        type="output"
        filename_template="reprodiag.nc"
        filename_interval="none"
        clobber_mode="overwrite"
        output_interval="00:10:00">

    <var name="xtime"/>
    <var name="surface_pressure"/>
    <var name="t2m"/>
    <var name="sst"/>
    <var name="xice"/>
    <var name="skintemp"/>
    <var name="znt"/>
    <var name="sfc_albedo"/>
</stream>
```

Para 24 horas simuladas, são 145 registros. O `output_interval` precisa ser múltiplo do `config_dt` do MPAS. Os cinco últimos campos são os que o acoplador injeta na atmosfera: se algum deles já diferir no registro 1 (t = 0), a divergência entra pela injeção, antes de qualquer integração.

Em produção o bloco deve ser retirado, para não gravar um arquivo a cada 10 minutos.

### 2.2 O `nccmp`

As comparações usam `nccmp -d`, que compara os **dados** dos NetCDF e ignora diferenças de cabeçalho (como o carimbo de data de criação), que fariam um `cmp` falhar sempre. Na jaci o `nccmp` vem de um módulo:

```bash
source $COUPLER_ROOT/tools/dev/set-nccmp-jaci.bash
```

O script confere que o `nccmp` está disponível antes de começar.

### 2.3 Instrumentos opcionais, mas recomendados

| Instrumento | Como ligar | O que acrescenta ao relatório |
| --- | --- | --- |
| checksums internos do SIS2 | `DEBUG_CHKSUMS = True`, `DEBUG_SLOW_ICE = True`, `DEBUG_FAST_ICE = True` no `SIS_override` | as etapas do ciclo do gelo em que a divergência aparece (`gelo_r<k>.txt`) |
| diagnósticos do mediador | `cfg_write_fixdiag` ligado (padrão nos binários de teste) | as linhas `FIX-DIAG` do PET 0 (`meddiag_r<k>.txt`) e o checksum exato do `Si_ifrac` por PET (`bitsum_r<k>.txt`, seção 6) |
| importações por instante | `IMPORT_GLOBS` (seção 3) | o que a atmosfera e o oceano receberam do mediador, troca a troca |

Os checksums do SIS2 acrescentam alguns segundos por troca e muitas linhas ao `esmApp_run.log`. Em produção, devem ser desligados.

### 2.4 Diretório de trabalho limpo

O script aborta se encontrar `reprodiag_r<k>.nc` de uma bateria anterior, para não recomparar em silêncio arquivos antigos. Arquive a bateria anterior antes (seção 8). Os logs de PET (`logs/PET*.esmApp.log`) são **cumulativos** entre jobs: é recomendável movê-los também, embora o script recorte por execução o que precisa deles.

## 3. Uso básico

Do diretório do experimento:

```bash
source $COUPLER_ROOT/tools/dev/set-nccmp-jaci.bash
export IMPORT_GLOBS='diag_import/monan2_import_*.nc diag_import/mom6_import_*.nc'
nohup bash $COUPLER_ROOT/tools/coupler/mede-taxa-repro.sh --runs 4 --npes 72 \
      --walltime 02:00:00 > saida-bateria.txt 2>&1 &
echo $! > bateria.pid
```

O `nohup` mantém a bateria viva se a sessão cair; a bateria submete uma execução por vez e espera cada uma terminar (o `run_esmApp.jaci` faz o `qsub` e acompanha o `qstat`). Com 72 PETs e 24 horas simuladas, cada execução leva de 6 a 10 minutos, mais a fila.

**Com mais de 99 PETs**, o log do PET 0 passa a se chamar `logs/PET000.esmApp.log`. Exporte o nome antes de disparar, senão o `meddiag` sai vazio (o `bitsum` não é afetado):

```bash
export PET_LOG=logs/PET000.esmApp.log
```

**O script de submissão** é procurado por padrão em `run/run_esmApp.jaci`, relativo ao diretório do experimento. Se ele não existir ali, informe `--runner $COUPLER_ROOT/run/run_esmApp.jaci`.

**Depois da primeira execução**, vale conferir que tudo está sendo gravado:

```bash
grep -E "^   OK +execucao 1:" saida-bateria.txt
grep -h "B-CPL-TERMORDER-01" logs/PET00*.esmApp.log | tail -1        # ... sem espaco: 0
wc -l bitsum_r1.txt gelo_r1.txt
```

## 4. Opções e variáveis de ambiente

| Opção | Padrão | Significado |
| --- | --- | --- |
| `--runs N` | 4 | número de execuções (N(N−1)/2 pares) |
| `--npes N` | 72 | PETs de cada execução; deve casar com o `nuopc.input` |
| `--walltime T` | 01:00:00 | tempo pedido ao PBS por execução |
| `--var NOME` | `surface_pressure` | variável do `reprodiag` usada na comparação par a par |
| `--runner CAMINHO` | `run/run_esmApp.jaci` | script de submissão |
| `--retomar` | desligado | reaproveita execuções cujo `reprodiag_r<k>.nc` já existe (bateria interrompida) |
| `--help` | | ajuda |

| Variável | Padrão | Significado |
| --- | --- | --- |
| `IMPORT_GLOBS` | `diag_import/monan2_import_*.nc` | arquivos de importação preservados e comparados por instante |
| `OCEAN_GLOBS` | `*monan_tos*.nc` | saídas do MOM6 pelo `diag_table` comparadas (o `tos` na grade nativa, que é a SST que alimenta a atmosfera) |
| `PET_LOG` | `logs/PET00.esmApp.log` | log do PET 0, de onde saem as linhas `FIX-DIAG` do mediador; seu diretório é também onde o `bitsum` procura os logs de todos os PETs |
| `RUN_LOG` | `logs/esmApp_run.log` | saída padrão do job, onde caem os checksums do SIS2 |
| `ARQ` | `reprodiag.nc` | arquivo do stream comparado |
| `POLL` | 30 | intervalo de consulta ao `qstat`, em segundos |

## 5. O que o script faz em cada execução

| Etapa | Detalhe |
| --- | --- |
| antes | move os `MONAN_DIAG_*.nc` da execução anterior para `monan_diag-pre-r<k>/` (o stream `diagnostics` do MPAS usa `clobber_mode = 'never_modify'` e não os sobrescreveria); anota o tamanho de cada log de PET |
| submissão | chama o `run_esmApp.jaci` e espera o fim do job |
| depois | recorta dos logs de todos os PETs só o que esta execução escreveu, e preserva as saídas |

**Arquivos gerados, por execução `k`:**

| Arquivo | Conteúdo |
| --- | --- |
| `reprodiag_r<k>.nc` | o estado do MPAS a cada 10 minutos (seção 2.1) |
| `export_t0_r<k>.nc` | o primeiro `monan_export`: o que a atmosfera exporta antes de qualquer troca |
| `ocean_r<k>.stats`, `seaice_r<k>.stats` | balanços globais do MOM6 e do SIS2 |
| `ocn_r<k>/` | saídas do oceano pelo `diag_table` (`OCEAN_GLOBS`) |
| `imp_r<k>/` | importações por instante (`IMPORT_GLOBS`) |
| `meddiag_r<k>.txt` | linhas `FIX-DIAG` do mediador no PET 0 |
| `bitsum_r<k>.txt` | checksum exato do `Si_ifrac`, por troca, etapa e PET (seção 6) |
| `gelo_r<k>.txt` | checksums inteiros (`c=`) das etapas do ciclo do SIS2 |

Ao final, o relatório compara tudo, par a par.

## 6. O checksum exato por PET (`FIX-DIAG-BITSUM-01`)

É o instrumento que localizou a causa da não reprodutibilidade, e o mais fino do relatório.

**Como funciona.** O mediador soma, em cada PET, a representação binária de cada valor da fração de gelo (cada número de 64 bits lido como inteiro, partido em duas metades de 32 bits). Soma de inteiros é exata e não depende da ordem: o resultado só muda se algum bit de algum ponto mudar. Cada PET grava a sua soma no próprio log; o script junta os logs de todos os PETs em `bitsum_r<k>.txt`, uma linha por troca, etapa e PET:

```
t=0001 etapa1 PET063 n=400 hi=... lo=...
```

**As quatro etapas** seguem o caminho do `Si_ifrac` dentro do mediador:

| Etapa | Campo | Grade |
| --- | --- | --- |
| 1 | `Si_ifrac_sis2`, como chega do gelo, antes do remapeamento | oceano |
| 2 | `f_ifrac_atm`, depois do remapeamento oceano → atmosfera | atmosfera intermediária 360 × 180 |
| 3 | `f_ifrac_atm`, depois da extrapolação de vizinhança | idem |
| 4 | `Si_ifrac` no `exportState`, como sai do mediador | oceano |

**Como ler.** Em cada par, a etapa com a menor troca divergente é onde o último bit muda primeiro. Para ver o tamanho da diferença, compare as somas diretamente:

```bash
cmpbs(){ paste -d' ' bitsum_r$1.txt bitsum_r$2.txt | awk -v tmax="$3" '
  { if ($1 != $7 || $2 != $8 || $3 != $9) { print "DESALINHADO: " $0; exit }
    t = substr($1, 3) + 0; if (t > tmax) next
    split($5, a, "="); split($11, b, "="); split($6, c, "="); split($12, d, "=")
    if (a[2] != b[2] || c[2] != d[2])
      printf "%s %s %s  dhi=%.0f dlo=%.0f\n", $1, $2, $3, a[2]-b[2], c[2]-d[2] }'; }
cmpbs 1 2 3          # par r1 x r2, trocas 1 a 3
```

`dhi = 0` com `dlo` de poucas unidades significa diferença no último bit de poucos pontos, a assinatura de soma feita em outra ordem. `dhi` grande significa valores realmente diferentes (divergência já amplificada, ou lixo de memória).

## 7. Como ler o relatório

| Seção | O que compara | Observação |
| --- | --- | --- |
| Sanidade do instrumento | registros por execução e presença da variável | se falhar, o resto não vale |
| Comparação par a par (`surface_pressure`) | o `reprodiag` de cada par e o primeiro registro divergente | o resultado principal |
| Primeiro `monan_export` | a exportação da atmosfera antes de qualquer troca | se divergir, a semente está na inicialização |
| `ocean.stats` e `seaice.stats` | balanços globais | checagem robusta e independente de layout |
| Etapas do ciclo do gelo | checksums `c=` do SIS2 em nove pontos do ciclo | a leitura automática "primeira etapa divergente" usa o `part_size` e é só indicativa |
| Diagnóstico do mediador (`ICEMASK`) | máscara e fração de gelo bruta no PET 0 | o `max` é impresso com 4 algarismos: "idêntico" aqui não exclui diferença de último bit, e a "LEITURA" automática desta seção é heurística antiga |
| Checksum exato do `Si_ifrac` | as quatro etapas, por PET | a seção mais precisa (seção 6) |
| Importações | cada `monan2_import` e `mom6_import`, por instante | o que cada componente recebeu |
| Saídas do oceano | `monan_tos` do `diag_table` | |
| Resumo | taxa de divergência entre pares e primeiro registro divergente de cada par | |

**Sobre a taxa.** Os pares não são independentes: se uma execução destoa, ela aparece em N−1 pares. A taxa é uma medida de ordem de grandeza. A leitura mais informativa é agrupar as execuções em classes de resultado idêntico (por exemplo, "r2 = r3, r1 e r4 distintas").

**Sobre zero divergências.** "Nenhum par divergiu" limita a taxa, não a zera. Uma regra prática: se N execuções saem todas idênticas, a chance de uma execução destoar é, com 95% de confiança, menor que cerca de 1 − 0,05^(1/(N−1)): cerca de 2 em 3 com 4 execuções, cerca de 1 em 3 com 8, cerca de 1 em 4 com 12. O limite é modesto em termos absolutos; o que dá peso ao resultado é o contraste com o comportamento anterior e a confirmação em baterias separadas.

## 8. Comparações entre baterias e arquivamento

**Comparar uma execução com a de outra bateria** (por exemplo, para confirmar que duas configurações que deveriam ser equivalentes são):

```bash
source $COUPLER_ROOT/tools/dev/set-nccmp-jaci.bash > /dev/null 2>&1
nccmp -d reprodiag_r1.nc repro-X/reprodiag_r1.nc > /dev/null 2>&1; echo "codigo $?"
cmp -s bitsum_r1.txt repro-X/bitsum_r1.txt && echo "bitsum: identico" || echo "bitsum: DIFERE"
cmp -s gelo_r1.txt   repro-X/gelo_r1.txt   && echo "gelo:   identico" || echo "gelo:   DIFERE"
```

O código do `nccmp` é 0 para idêntico e 1 para diferente. Qualquer outro valor significa que o comando não rodou (por exemplo, 127 se o módulo não foi carregado); numa redireção para `/dev/null`, conferir sempre o código.

Uma comparação cruzada também serve como **conferência de efeito**: ao ligar um componente ou mudar a decomposição da atmosfera, o resultado deve mudar. Se sair idêntico, o componente não está atuando (foi o caso dos icebergs em 23/09/2026: ligados, mas sem nenhum iceberg na simulação).

**Arquivar uma bateria** antes da seguinte:

```bash
B=repro-<nome>
mkdir -p $B/logs $B/diag_import
mv reprodiag_r?.nc export_t0_r?.nc ocean_r?.stats seaice_r?.stats meddiag_r?.txt \
   gelo_r?.txt bitsum_r?.txt saida-bateria.txt bateria.pid nohup.out $B/ 2>/dev/null
mv ocn_r? imp_r? monan_diag-pre-r? $B/ 2>/dev/null
mv logs/PET*.esmApp.log logs/esmApp_run.log $B/logs/ 2>/dev/null
mv diag_import/*.nc MONAN_DIAG_*.nc $B/ 2>/dev/null
cp -p nuopc.input SIS_override $B/
ls reprodiag_r?.nc 2>/dev/null || echo "limpo"
```

Com mais de 9 execuções, troque `r?` por `r*`. Copiar o `nuopc.input` e o `SIS_override` registra a configuração que a bateria mediu, e a taxa só vale para ela.

## 9. Armadilhas conhecidas

**O `esmApp_run.log` é sobrescrito a cada job.** Os checksums do SIS2 que ele contém são copiados para `gelo_r<k>.txt` pelo script; ao final da bateria, o arquivo da raiz é o da última execução.

**No modo concorrente, o `esmApp_run.log` intercala a saída do oceano e do gelo em ordem variável.** Um `diff` linha a linha acusa diferença com os valores idênticos. Compare o conjunto ordenado (`sort`) ou filtre as etapas exclusivas do gelo, como faz o `gelo_r<k>.txt`.

**O checksum `c=` do SIS2 é soma de contagem de bits, não hash.** É muito sensível, mas coincidências são possíveis em princípio. As linhas `mean=/min=/max=` (17 algarismos) e o `bitsum` são mais firmes.

**Quando um componente quebra, o job fica parado até o fim do tempo pedido**, porque os outros esperam por ele, e termina com SIGTERM (exit 143). A dica automática de falta de memória do `run_esmApp.jaci` é enganosa nesse caso: procure o erro no `esmApp_run.log` e dê `qdel` no job.

**A taxa vale só para a configuração medida.** Mudar `atm_pet_count`, o total de PETs, `dt_coupling`, o modo de acoplamento ou um componente exige nova bateria.

## 10. Resultados de referência

Baterias de 22 e 23/09/2026 que estabeleceram a reprodutibilidade do acoplador depois das correções `B-SRCTERM-01` e `B-METHODS-TERMORDER-01` (fixação das somas parciais e da ordem de soma nos remapeamentos do ESMF):

| Configuração | Execuções | Pares divergentes |
| --- | --- | --- |
| antes da correção, sequencial, 72 PETs | 4 | 5 ou 6 de 6 |
| sequencial reprodutível (`seq_repro`), 72 PETs | 4 + 8 | 0 de 6 e 0 de 28; idênticas entre as baterias |
| concorrente, 72 PETs | 8 | 0 de 28; idênticas às sequenciais |
| concorrente com icebergs ligados, 72 PETs | 8 | 0 de 28 |
| concorrente, 144 PETs (128 + 8 + 8) | 4 | 0 de 6 |

A explicação didática da causa e da correção, com os trechos de código, está no relatório de investigação do GT (`explicacao-reprodutibilidade.md`, fora deste repositório).

## 11. Documentos relacionados

`docs/uso-duplas-rodadas-repro.md`, para os scripts de dupla rodada (mais rápidos, com perguntas mais específicas).

`docs/uso-linha-base.md`, para comparar uma execução contra uma referência congelada depois de uma alteração de código.

`docs/uso-analisa-balanceamento.md`, para o custo de cada componente, e a relação entre mudar o número de PETs e o resultado.

`docs/ferramentas.md`, catálogo de todas as ferramentas.
