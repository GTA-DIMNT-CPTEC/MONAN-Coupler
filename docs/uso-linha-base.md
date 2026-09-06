# Linhas de base: como criar e como comparar

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos.
Sistema acoplado MONAN-A 2.0 (MPAS 8.3.1) com MOM6 e SIS2, NUOPC/ESMF 8.9.1.

Manual de uso de `tools/dev/cria-linha-base.bash` e `tools/dev/compara-linha-base.bash`.

## 1. Para que serve

Uma linha de base é uma execução de referência congelada: os arquivos de saída, a configuração que os produziu e o registro de qual código e qual ambiente estavam em uso. Ela responde a uma pergunta única e específica: a alteração que acabei de fazer no código mudou o resultado?

Isso importa porque a maior parte das alterações no acoplador não deveria mudar resultado nenhum. Reorganizar um módulo, extrair uma sub-rotina, trocar um `block` por uma variável local, renomear um campo interno: em todos esses casos o critério de aceitação é identidade exata da saída. Sem uma linha de base, esse critério não é verificável, e a única alternativa é inspeção visual de campos, que não detecta diferença pequena.

Os dois scripts se dividem assim. O `cria-linha-base.bash` congela; ele não executa o modelo. O `compara-linha-base.bash` compara a rodada corrente contra uma base congelada e devolve PASS ou FAIL.

## 2. Antes de começar

`COUPLER_ROOT` precisa apontar para a raiz do MONAN-Coupler. O script usa isso para ler os commits dos repositórios e do binário. Ou exporte a variável, ou passe `-r`.

```bash
export COUPLER_ROOT=/p/projetos/gta/daniel.massaru/coupling/MONAN-Coupler
```

O `nccmp` precisa estar no PATH para a comparação. O `cria-linha-base.bash` não precisa dele; o `compara-linha-base.bash` recusa executar sem ele, com código de saída 2.

Os dois scripts são executados de dentro do diretório de experimento, aquele que contém o `nuopc.input`, o `diag_export/` e o `diag_import/`. Não de dentro do repositório.

## 3. Criar uma linha de base

Rode o modelo até o fim. Só depois congele.

```bash
cd /p/projetos/gta/daniel.massaru/coupling/exp/<seu-experimento>
tools/dev/cria-linha-base.bash -l L-10 \
  -d "MPAS+MOM6+SIS2, concurrent, split, 64/4/4 PETs"
```

Opções:

| opção | significado |
| - | - |
| `-l RÓTULO` | obrigatório. Nome da linha de base. Ver a seção 4. |
| `-d "TEXTO"` | descrição em uma linha, gravada no MANIFEST. |
| `-o DIRETÓRIO` | raiz das linhas de base. Padrão `./baseline`. |
| `-r DIRETÓRIO` | raiz do MONAN-Coupler. Padrão: valor de `COUPLER_ROOT`. |
| `-h` | ajuda. |

O resultado é `baseline/<rótulo>/`, com esta estrutura:

| item | conteúdo |
| - | - |
| `MANIFEST.txt` | commits e branch dos três repositórios, se a árvore está limpa, compilador, módulos carregados, variáveis de ambiente da compilação, parâmetros da rodada, tamanho e sha256 do `esmApp`, inventário da saída. |
| `config/` | `nuopc.input` e os namelists que existirem: `namelist.atmosphere`, `streams.atmosphere`, `namelist.ocn`, `input.nml`, `MOM_input`, `MOM_override`, `SIS_input`, `SIS_override`, `diag_table`, `data_table`. |
| `entrada/CHECKSUMS.txt` | sha256 e tamanho dos arquivos de entrada. Os arquivos em si não são copiados, por tamanho. |
| `saida/` | `monan_export_*.nc`, `mom6_import_*.nc`, `monan2_import_*.nc` e, se existirem, os `mpas_import_*.nc` de nome legado. |
| `logs/` | o primeiro PET de **cada bloco** (ATM, OCN, ICE) e o `esmApp_run.log`. Com `pet_layout = 'shared'`, ou sem a linha de layout no log, apenas o `PET0`. |
| `SHA256SUMS` | soma de verificação de tudo o que foi guardado. |

Ao final o diretório recebe `chmod -R a-w`. Uma linha de base não deve ser editável por acidente.

O script recusa sobrescrever um rótulo existente. Se for mesmo o caso, arquive o antigo antes, por exemplo renomeando para `L-10.arquivada-2026-09-04`.

Ele também recusa executar se `nuopc.input` não estiver no diretório corrente, ou se `diag_export/` estiver vazio, situação em que a rodada provavelmente não terminou.

## 4. Convenção de rótulos

O formato é `L-NN`, com dois dígitos, atribuídos em ordem crescente. A descrição em `-d` é o que distingue uma da outra na leitura, então vale a pena escrevê-la sempre com os mesmos quatro elementos, nesta ordem: componentes ativos, `coupling_mode`, `pet_layout`, distribuição de PETs.

```
-d "DATM + DOCN, sequential, shared, 4 PETs"
-d "MPAS+MOM6, concurrent, split, 64/4 PETs"
-d "MPAS+MOM6+SIS2, concurrent, split, 64/4/4 PETs"
```

A lista de rótulos já atribuídos está na seção "Linha de base" do documento de proposta. Consulte antes de escolher um número, para não colidir com o de outra pessoa.

## 5. Conferir a base antes de aceitá-la

Uma linha de base ruim é pior que nenhuma, porque dá confiança falsa. Leia o MANIFEST antes de considerá-la válida.

```bash
cat baseline/L-10/MANIFEST.txt
```

O campo decisivo é `árvore suja`. Se estiver `SIM`, havia alterações não gravadas na árvore de trabalho no momento da execução, e ninguém consegue dizer depois qual código produziu aqueles arquivos. Uma base assim não é reproduzível e deve ser descartada. Grave as alterações e execute de novo.

Confira que os logs de PET esperados estão lá. Com `split` e gelo devem ser três, um por bloco:

```bash
ls baseline/L-10/logs/
```

Confira também que `atm_pet_count`, `ocn_pet_count`, `ice_pet_count`, `coupling_mode`, `pet_layout`, `use_sis2_dynamic` e `use_med_to_mpas` são de fato o cenário que você queria congelar, e que o inventário da saída não está vazio do lado da importação. Se `mom6_import` e `monan2_import` estiverem ambos em zero, o MANIFEST traz um aviso: a causa provável é `write_import_diag` desligado, e a base cobrirá apenas o lado de exportação.

## 6. Comparar contra a linha de base

Depois de alterar o código, recompilar e executar de novo, no mesmo diretório de experimento:

```bash
tools/dev/compara-linha-base.bash -l L-10
```

Opções:

| opção | significado |
| - | - |
| `-l RÓTULO` | obrigatório. |
| `-o DIRETÓRIO` | raiz das linhas de base. Padrão `./baseline`. |
| `-t VALOR` | tolerância relativa, por exemplo `1e-12`. Ver a seção 7. |
| `-h` | ajuda. |

Antes de comparar qualquer arquivo, o script faz duas verificações de pré-condição.

**Integridade da base.** Confere o `SHA256SUMS` gravado no congelamento. O `chmod -R a-w` protege contra alteração acidental, mas nada impede que alguém desfaça a proteção, ou que uma cópia entre máquinas corrompa algo. Comparar contra uma base adulterada produz um veredito que parece autoritativo e não é. Se a soma não conferir, o script lista os arquivos alterados e sai com código 2. Bases congeladas antes desta verificação não têm `SHA256SUMS` e são aceitas com nota.

**Configuração.** Compara o `nuopc.input` atual com o congelado, e avisa **antes** da comparação de dados, não na triagem de FAIL. Saber que a configuração mudou muda a leitura de tudo o que vem a seguir.

A comparação dos dados é feita com `nccmp -d -m -f`, ou seja, sobre os dados e os metadados de variável, seguindo até o fim em vez de parar na primeira diferença. Comparar os arquivos byte a byte não funcionaria: os NetCDF gravados pelo acoplador trazem data e hora de criação nos atributos globais, então duas execuções idênticas produzem cabeçalhos diferentes com dados iguais.

Para cada arquivo da base, o script procura o correspondente em `diag_export/`, depois em `diag_import/`, depois no diretório corrente, e classifica em `igual`, `difere so nos METADADOS`, `DIFERE` ou `AUSENTE`. Ao final varre `diag_export/` e `diag_import/` em busca de arquivos que a base não tem, classificados como `EXTRA`.

A categoria `difere so nos METADADOS` existe porque o `nccmp -m` compara atributos de variável, e uma alteração de `long_name` ou `standard_name` no writer faz o arquivo inteiro aparecer como diferente mesmo com os dados idênticos. Quando isso acontece, o script faz uma segunda passada só com `-d -f`, apenas dados; se ela passar, a diferença está confinada aos metadados e **o veredito é PASS**, com uma nota explicando a causa. O critério das etapas de refatoração é identidade dos dados, e renomear um rótulo não muda resultado.

O caso já ocorreu: a correção `B-DIAG-SOT-ROTULO-01` alterou o `long_name` e o `standard_name` da variável `So_t` nos `monan2_import_*.nc`, sem tocar em nenhum valor. Sem essa distinção, toda comparação contra base anterior a ela apontaria divergência onde não há.

Códigos de saída:

| código | significado |
| - | - |
| 0 | PASS. Todos os arquivos batem, e havia pelo menos um para comparar. |
| 1 | FAIL. Houve diferença de dados, arquivo ausente ou arquivo extra. |
| 2 | Erro de uso ou de pré-condição: rótulo não informado, base inexistente, `nccmp` fora do PATH, ou base que não confere com o próprio `SHA256SUMS`. |

Isso permite encadear em script:

```bash
if tools/dev/compara-linha-base.bash -l L-10; then
  echo "etapa aceita"
else
  echo "etapa reprovada"
fi
```

## 7. Sobre a tolerância

Sem `-t`, o critério é identidade exata dos dados. É esse o critério das etapas de refatoração, e não deve ser afrouxado para fazer um teste passar.

`-t` existe para as etapas em que a alteração muda a ordem das operações de ponto flutuante de forma declarada e deliberada, por exemplo ao trocar um laço por uma operação vetorizada ou ao mudar a ordem de uma redução MPI. Nesses casos a diferença é de arredondamento, e o valor da tolerância faz parte da justificativa da etapa, escrita antes de rodar o teste.

Usar `-t` para acomodar uma diferença que apareceu sem explicação inverte o propósito da ferramenta: transforma a linha de base num carimbo em vez de num teste.

## 8. Quando dá FAIL

O script já imprime a triagem, e vale segui-la na ordem antes de suspeitar do código.

Primeiro, o número de PETs é o mesmo do MANIFEST? Mudar a decomposição muda o resultado por reordenação de soma, e isso não é defeito.

Segundo, o `nuopc.input` é o mesmo. O script já compara isso sozinho e avisa no cabeçalho, mas o diff completo é útil:

```bash
diff nuopc.input baseline/L-10/config/nuopc.input
```

Terceiro, os arquivos de entrada têm a mesma soma de verificação, conforme `baseline/L-10/entrada/CHECKSUMS.txt`.

Quarto, os módulos carregados são os mesmos do MANIFEST. Trocar de versão de compilador ou de MPI muda resultado.

Só depois de descartar os quatro a diferença é atribuível à alteração de código.

Um caso particular vale registrar, e o script agora o detecta sozinho. Se o resultado vier com muitos `AUSENTE` e muitos `EXTRA`, e **nenhum** `DIFERE`, o que mudou foram os nomes dos arquivos, não os dados. Foi o que a correção `BUG-SEQ-STAMP-01` fez no modo sequencial, ao acertar o carimbo de tempo dos diagnósticos, que antes saíam adiantados em um `dt_coupling`. Nesse caso a base anterior à correção é incomparável por construção, e precisa ser refeita.

Quando essa assinatura aparece, o comparador imprime um aviso próprio antes da triagem genérica, para que a investigação não comece no lugar errado.

## 9. Recomendações práticas

Congele a base em modo concorrente quando o objetivo for validar alteração de código que não é específica do modo sequencial. O modo concorrente não foi afetado pela correção de carimbo de tempo, o que isola regressão de renomeação.

Congele antes de começar a mexer, não depois. Uma base criada depois da alteração não serve para nada.

Use a base mais curta que ainda seja sensível ao que você mudou. Duas ou três horas de integração já detectam a maior parte das regressões, ocupam pouco espaço e permitem repetir o teste várias vezes ao dia.

Para remover uma base, desfaça primeiro a proteção de escrita:

```bash
chmod -R u+w baseline/L-10 && rm -rf baseline/L-10
```

## 10. Limitações conhecidas

Os arquivos de entrada não são copiados, apenas registrados por soma de verificação. Se eles forem apagados ou alterados no sistema de arquivos, a base deixa de ser reproduzível, embora continue servindo para comparação enquanto os arquivos existirem.

Os logs congelados são o primeiro PET de cada bloco e o `esmApp_run.log`, não todos os `PET*.esmApp.log`. Isso basta para reabrir uma investigação, porque os diagnósticos de cada componente saem no seu próprio bloco, mas **não** basta para análise de sobreposição temporal, que precisa de todos os PETs; para isso existem o `test-sequential-split.bash` e o `test-concurrent.bash`.

Até setembro de 2026 só o `PET0` era congelado. Com `pet_layout = 'split'` o PET0 pertence ao bloco da atmosfera, então os diagnósticos do oceano e do gelo ficavam de fora. A investigação registrada em `docs/investigacao-oscilacao-si-t-sis2.md` dependeu inteiramente do `PET68`, e teria sido irreproduzível a partir de uma base congelada com a versão anterior.

A comparação cobre os NetCDF de diagnóstico. Não cobre os arquivos de reinício nem a saída própria de cada componente.
