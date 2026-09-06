# Smoke tests de modo de acoplamento: como usar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/coupler/test-concurrent.bash` e `tools/coupler/test-sequential-split.bash`.

## 1. O que estes testes fazem

Os dois verificam que uma combinação do grupo `&nuopc_petlayout` chega ao primeiro passo de acoplamento sem travar. Não verificam resultado numérico: para isso existem as linhas de base, descritas em `docs/uso-linha-base.md`.

O `test-concurrent.bash` cobre `coupling_mode = 'concurrent'` com `pet_layout = 'split'`. O ponto de atenção é o conjunto de `MPI_Allreduce` coletivos que passam a rodar sobre comunicadores de componente diferentes do global.

O `test-sequential-split.bash` cobre `coupling_mode = 'sequential'` com `pet_layout = 'split'`. Faz tudo o que o anterior faz e mais uma verificação, que é a razão de ele existir separadamente: mede se as janelas de execução dos componentes se sobrepõem no tempo.

Essa verificação extra importa porque as duas combinações produzem exatamente os mesmos conjuntos de PETs. Só os carimbos de tempo dos logs distinguem uma da outra. Sem medir sobreposição, um defeito que fizesse o driver montar a RunSequence concorrente quando se pediu sequencial passaria despercebido.

Nenhum dos dois altera o seu `nuopc.input`. Ambos geram uma cópia de teste e a injetam pela variável `NUOPC_INPUT`, e escrevem logs e diagnósticos em diretórios isolados, com sufixo `-concurrent-test` ou `-seqsplit-test`.

## 2. Antes de começar

### 2.1 COUPLER_ROOT precisa ser exportado

Os dois scripts deduzem `COUPLER_ROOT` supondo que residem em `<raiz>/run/`. Eles residem em `tools/coupler/`. A dedução automática, portanto, aponta para `<raiz>/tools`, e a partir daí tanto o executável quanto o `setenv` são procurados no lugar errado.

Exporte a variável antes de chamar:

```bash
export COUPLER_ROOT=/p/projetos/gta/daniel.massaru/coupling/MONAN-Coupler
```

Alternativamente, informe os dois caminhos explicitamente, com `--exe` e `--setenv`. Exportar a variável é mais simples e cobre os dois de uma vez.

### 2.2 A partição METIS acompanha atm_pet_count, não o total

Com `pet_layout = 'split'`, o MPAS é decomposto em `atm_pet_count` partições, e não em `-n`. Antes de rodar com `--atm K`, confirme que existe `x1.*.graph.info.part.K` no diretório de experimento. Gere com `gen-metis.bash --parts K` se não existir.

Para a configuração corrente do `nuopc.input`, com 64 PETs de atmosfera e 72 no total, o arquivo necessário é `.part.64`, e não `.part.72`. O teste avisa quando o arquivo não está lá.

### 2.3 python3 no nó de execução

Só o `test-sequential-split.bash` precisa, e só para a medição de sobreposição. Sem `python3`, essa verificação é pulada com aviso e as demais seguem valendo.

### 2.4 Onde executar

Do diretório de experimento, aquele que contém `nuopc.input`, os namelists e a malha.

## 3. Uso básico

Concorrente, submetendo à fila:

```bash
cd /p/projetos/gta/daniel.massaru/coupling/exp/<seu-experimento>
$COUPLER_ROOT/tools/coupler/test-concurrent.bash -n 8
```

Sequencial com os três componentes, na topologia de produção:

```bash
$COUPLER_ROOT/tools/coupler/test-sequential-split.bash \
  -n 72 --atm 64 --ocn 4 --ice 4
```

Antes de submeter qualquer coisa, vale rodar com `--dry-run`, que gera a configuração de teste e o script `.pbs`, imprime o comando e não submete nada. É a forma de conferir se o grupo `&nuopc_petlayout` injetado é o que você esperava.

```bash
$COUPLER_ROOT/tools/coupler/test-sequential-split.bash \
  -n 72 --atm 64 --ocn 4 --ice 4 --dry-run
```

Em sessão interativa, obtida com `qsub -I`, use `--local` para executar direto, sem passar pela fila de novo.

## 4. Como funcionam as duas fases

Os dois scripts seguem o mesmo padrão do `run_esmApp.jaci`, e decidem o que fazer pela presença de `PBS_O_WORKDIR`.

No nó de login, sem essa variável, o script gera um `.pbs` e faz `qsub`. Dentro do job, ou em sessão interativa, ele carrega os módulos, faz `source` do `setenv` e executa o teste, com o lançador PALS `mpiexec` e um watchdog de progresso.

A opção `--local` força a segunda fase diretamente.

## 5. Opções

Comuns aos dois scripts:

| opção | padrão | significado |
| - | - | - |
| `-n`, `--np N` | 8 | total de PETs |
| `--atm K` | metade | PETs da atmosfera |
| `--ocn K` | resto | PETs do oceano |
| `-w`, `--walltime HH:MM:SS` | `00:30:00` | walltime PBS |
| `--queue NOME` | padrão do sistema | fila PBS |
| `--account NOME` | nenhum | conta ou projeto PBS |
| `--ncpus-node N` | 128 | núcleos por nó, para calcular o `select` |
| `--select STR` | calculado | sobrescreve a linha `select` inteira |
| `--jobname NOME` | `smoke-concurrent` ou `smoke-seqsplit` | nome do job |
| `--exe CAMINHO` | `$COUPLER_ROOT/bin/esmApp` | executável |
| `--rundir DIR` | atual | diretório de experimento |
| `--input ARQ` | `<rundir>/nuopc.input` | `nuopc.input` base |
| `--setenv ARQ` | `$COUPLER_ROOT/run/setenv-gnu.bash` | `setenv` a carregar no job |
| `--launcher CMD` | automático | `mpiexec`, `mpirun` ou `srun` |
| `--launcher-args S` | vazio | argumentos extras ao lançador |
| `--dt SEG` | do `nuopc.input` | sobrescreve `dt_coupling` na configuração de teste |
| `--steps K` | 1 | encerra após K passos completos |
| `--timeout SEG` | 900 | tempo-limite do watchdog |
| `--stall SEG` | 180 | tempo sem progresso que levanta suspeita de travamento |
| `--interval SEG` | 5 | período de amostragem do watchdog |
| `--local` | - | executa direto, sem `qsub` |
| `--baseline` | - | roda antes um teste de sanidade em layout compartilhado |
| `--keep` | - | preserva a configuração de teste, os logs e os diagnósticos |
| `--dry-run` | - | gera tudo e imprime o comando, sem submeter nem executar |
| `-h`, `--help` | - | ajuda |

Só no `test-sequential-split.bash`:

| opção | padrão | significado |
| - | - | - |
| `--ice K` | ver abaixo | PETs do gelo. Valor maior que zero liga `use_sis2_dynamic`. |
| `--no-ice` | - | força a execução sem gelo, mesmo com `use_sis2_dynamic` ligado na base |
| `--overlap-tol SEG` | 1.0 | sobreposição tolerada entre janelas de componentes |

Sem `--ice` nem `--no-ice`, o script herda `use_sis2_dynamic` e `ice_pet_count` do `nuopc.input` base. Se o gelo estiver ligado lá e nenhuma contagem for informada, ele reparte em três blocos com as mesmas regras de valor automático do `esm.F90`.

## 6. O que cada teste verifica

Verificações comuns aos dois:

O marcador de partição no log, com as faixas de PET exatamente como pedidas. A RunSequence anunciada pelo driver, que precisa ser a do modo solicitado. A conclusão da inicialização dos componentes. A ausência de marcadores de erro fatal: `MPI_Abort`, `forrtl: severe`, `SIGSEGV`, falha de segmentação, partição inválida. E o veredito do watchdog.

Só no `test-sequential-split.bash`, adicionalmente: o terceiro bloco de PET quando o gelo está ativo, o registro do componente ICE no driver, a seleção da RunSequence sequencial com gelo, e a medição de sobreposição descrita na seção 8.

## 7. Como o travamento é detectado

O teste não espera a simulação terminar. Ele observa o aparecimento do primeiro `diag_import/mom6_import_*.nc`.

O raciocínio é este: o mediador grava esse arquivo ao final de cada passo, logo depois do seu `MPI_Allreduce`. O gather Voronoi do MPAS acontece antes, no mesmo passo. Logo, o primeiro arquivo gravado significa que os coletivos do passo 1 passaram, e portanto não houve travamento.

Se nada aparecer dentro das janelas de `--stall` e `--timeout`, com o processo vivo e parado num coletivo, o veredito é travamento provável.

Os vereditos possíveis do watchdog são: simulação concluída integralmente; primeiro passo completou os coletivos; travamento provável, com processo vivo e sem progresso; parada antes de concluir a inicialização; e aborto do executável antes de completar o primeiro passo. Nos três últimos casos o script imprime as últimas linhas do `PET0` e do último PET do bloco oceânico, para ajudar a localizar onde parou.

## 8. Como a sobreposição é medida

Vale só para o `test-sequential-split.bash`.

Cada fase de componente deixa no log ESMF um par de mensagens `intro.` e `extro.`, com carimbo de tempo. O teste reúne as janelas de execução de todos os PETs de cada bloco, une cada conjunto (as janelas de PETs irmãos se sobrepõem entre si, e isso é esperado) e mede a interseção entre as uniões.

Com os três componentes ativos, são medidos três pares: atmosfera com oceano, atmosfera com gelo e oceano com gelo. Em execução sequencial os três devem ter interseção praticamente nula, dentro de `--overlap-tol`.

Sobreposição em qualquer um dos pares significa que um ponto de encontro saiu do lugar na RunSequence. Convém ler, junto, o comentário em `esm.F90::SetRunSequence` sobre o que sincroniza a lista: uma linha de componente não sincroniza ninguém, e quem separa uma fase da outra é sempre uma linha de conector de ou para o mediador.

A medição precisa de `python3` no nó de execução. Sem ele, essa verificação é pulada com aviso.

## 9. Códigos de saída

| código | significado |
| - | - |
| 0 | PASSOU. Todas as verificações em ordem. |
| 1 | FALHOU. Uma ou mais verificações com problema. O script imprime quantas. |
| 2 | Erro de uso ou de pré-condição: opção inválida, executável não encontrado, partição inválida. |

## 10. Sequência recomendada

Comece pequeno e local, para descartar erro de caminho e de ambiente antes de gastar fila.

```bash
export COUPLER_ROOT=/p/projetos/gta/daniel.massaru/coupling/MONAN-Coupler
cd <diretório de experimento>

# 1. Conferir a configuração injetada, sem submeter nada
$COUPLER_ROOT/tools/coupler/test-sequential-split.bash \
  -n 72 --atm 64 --ocn 4 --ice 4 --dry-run

# 2. Rodar de fato, guardando os artefatos para inspeção
$COUPLER_ROOT/tools/coupler/test-sequential-split.bash \
  -n 72 --atm 64 --ocn 4 --ice 4 --keep

# 3. Repetir no modo concorrente
$COUPLER_ROOT/tools/coupler/test-concurrent.bash \
  -n 72 --atm 64 --ocn 4
```

Use `--keep` sempre que o resultado for FALHOU. Sem ele, o script apaga a configuração de teste, os logs e os diagnósticos ao final, e não sobra o que investigar.

## 11. Problemas comuns

**Executável não encontrado, ou `setenv` não encontrado.** Quase sempre é `COUPLER_ROOT` não exportado. Ver a seção 2.1.

**MOM6 aborta em `mpp_define_domains`.** A contagem de PETs do oceano não é compatível com a decomposição pedida no `MOM_input`. Não é defeito do acoplador.

**Marcador de partição ausente no log.** O binário é anterior à v14.20, quando os dois eixos foram separados, ou a configuração de teste não chegou ao driver. Confira com `--dry-run` o que foi injetado.

**Sobreposição não medida, com aviso.** Falta `python3` no nó de execução, ou os logs não têm janelas `Run`. As demais verificações continuam válidas, mas a que distingue sequencial de concorrente não foi feita.

**FALHOU com sobreposição entre oceano e gelo.** Ver a seção 8 e o comentário em `esm.F90::SetRunSequence`.

## 12. Limitação conhecida

O `test-concurrent.bash` não conhece o componente de gelo. Ele aceita apenas `--atm` e `--ocn`, e a função que gera a configuração de teste remove o grupo `&nuopc_petlayout` da base e reinjeta um grupo próprio sem `use_sis2_dynamic`. O efeito é que uma `nuopc.input` com gelo ligado é testada sem gelo, e o veredito sai como PASSOU.

O `test-sequential-split.bash` tinha o mesmo problema, corrigido em setembro de 2026 sob a marca `BUG-SEQ-TEST-ICE-01`. O mesmo tratamento ainda não foi aplicado ao teste concorrente.

Até que seja, para verificar o modo concorrente com os três componentes, o caminho é executar o `run_esmApp.jaci` com um `stop_date` curto e inspecionar os logs manualmente.
