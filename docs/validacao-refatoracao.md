# Validação de alterações de código na Jaci

Roteiro para confirmar que uma alteração de código (refatoração, reorganização, correção que não deve mexer em cálculos) reproduz bit a bit uma linha de base. Foi o procedimento usado em todas as etapas da refatoração, de R-FASE1-01 a R-FASE3-03, em setembro de 2026.

## Linhas de base existentes

| Rótulo | Código | Compilação | Uso |
| --- | --- | --- | --- |
| R-REF-00 | `ea10fb6` (develop) | com FMA (compilação anterior ao Makefile 16.1) | registro histórico |
| R-NOFMA-01 | `ea10fb6` (develop) | `-ffp-contract=off` | referência das fases 2A a 3 |
| **R-NOFMA-02** | tag `fase3-03-validada` | `-ffp-contract=off` | **referência atual**: dados idênticos aos da R-NOFMA-01; os 24 `monan2_import_*` têm os atributos CF novos nos eixos |

Todas usam a mesma configuração: `pet_layout = split`, 128 + 20 + 4 PETs (152), modo concorrente com SIS2 dinâmico, rodada de 1 dia (24 passos de 3600 s).

Antes de levar uma mudança à Jaci, faça as conferências locais de [`conferencias-locais.md`](conferencias-locais.md): compilação fora da Jaci, constantes de texto, instruções e, quando for o caso, o teste dos gravadores. Elas evitam rodadas perdidas, mas não substituem a comparação abaixo.

## 1. Compilar

Numa sessão nova, defina `COUPLER_ROOT` **antes** de carregar o ambiente. Sem isso o `setenv-gnu.bash` usa as bibliotecas de outra instalação, e o executável liga o MPAS e o MOM6 de lá (caso real: FAIL sem nenhuma mudança de cálculo).

```bash
export COUPLER_ROOT=/p/projetos/gta/daniel.massaru/refatorado/Coupler-Install/MONAN-Coupler
cd $COUPLER_ROOT
source run/setenv-gnu.bash        # MPAS_DIR, MONAN2_LIBDIR e MOM6_ROOT devem estar dentro de COUPLER_ROOT
git status --short                # arquivos rastreados: nada modificado
make clean && make 2>&1 | tee ../make.log
grep -c 'Error' ../make.log       # esperado: 0
```

## 2. Preparar, submeter e comparar

O `tools/dev/valida_rodada.bash` faz os passos na ordem, um comando por vez, sem blocos longos para copiar e colar:

```bash
bash $COUPLER_ROOT/tools/dev/valida_rodada.bash prepara teste_01
bash $COUPLER_ROOT/tools/dev/valida_rodada.bash submete teste_01
bash $COUPLER_ROOT/tools/dev/valida_rodada.bash compara teste_01
```

| Comando | O que faz |
| --- | --- |
| `prepara NOME` | confere que `bin/esmApp` existe e não contém código de outra instalação; mostra data e revisão; cria `$REF/exp/NOME` a partir do experimento modelo, sem as saídas antigas, com o `nuopc.input` da linha de base |
| `submete NOME` | roda o `--check` e submete com 152 PETs; espera o job terminar |
| `compara NOME` | confere que a rodada terminou, mostra executável e revisão usados; extrai o relatório de acoplamento (seção 2.1) e o compara com o da rodada aprovada mais recente; compara com a linha de base, conferindo também as entradas (`-e`); em caso de FAIL, mostra as primeiras diferenças; se a comparação nem começou (por exemplo, linha de base que não confere com o seu `SHA256SUMS`), diz isso e sai com código 2; sai com o código do `compara-linha-base.bash` (0 PASS, 1 FAIL, 2 comparação não feita) |

Variáveis opcionais: `REF` (padrão: a pasta que contém `Coupler-Install/`), `MODELO` (padrão: `$REF/exp_monan2xmom6`), `BASE` (padrão: `R-NOFMA-02`), `NPES` (padrão: 152) e `REL_REF` (rodada cujo relatório de acoplamento serve de referência; padrão: a aprovada mais recente). Para usar outro executável, `ESMAPP_BIN=<caminho>` antes do `submete`.

Não altere o repositório (`git switch`, `git am`, `make`) enquanto o job estiver na fila ou rodando.

### 2.1 Relatório de acoplamento

Desde a fase 11, a rodada escreve no log do PET 0 (`logs/PET000.esmApp.log`) linhas com o prefixo `CPL-REL:`, que descrevem o acoplamento como ele foi montado:

| Linhas | Quando | Desde |
| --- | --- | --- |
| `configuracao do mapa`, `conector A -> B: N campo(s)` e um campo por linha, com as opções | inicialização, no `ModifyCplLists` do driver | R-FASE11-03 |
| `DIFERENCA:`, `AVISO:` e `conferencia do mapa: N diferenca(s), M aviso(s)` | idem; a produção dá 0 diferenças e 3 avisos | R-FASE11-03 |
| `rota NOME: esquema, metodos, mascara, aceito METODO` (ou `usa a reserva`) | na criação de cada rota do mediador | R-FASE11-04 |
| `completar ROTA CAMPO: N aplicacao(oes), P ponto(s) fora da faixa, F com valor fixo` | fim da rodada, somando todos os PETs do mediador | R-FASE11-04 |

O `compara` grava essas linhas, sem data e hora, em `relatorio_acoplamento.txt` e as compara com as da rodada aprovada (PASS no `compara.txt`) mais recente, ou com as de `REL_REF`. Igual: o acoplamento foi montado da mesma forma. Diferente: as linhas que mudaram vão para `relatorio_acoplamento.diff` e as primeiras aparecem na tela; a rodada não é reprovada por isso, mas uma diferença não anunciada na etapa aponta o problema antes da comparação dos arquivos. Na primeira rodada de uma etapa que acrescenta linhas ao relatório, a diferença esperada são só as linhas novas.

## 3. Se der FAIL

1. **Repita a rodada** num diretório novo. Se as duas rodadas novas forem idênticas entre si e diferentes da base, a diferença é sistemática; se diferirem entre si, há algo que muda de uma execução para outra.
2. **Localize o primeiro instante.** No `reprodiag.nc` (a cada 10 minutos simulados), a primeira posição de tempo com diferença indica o passo de acoplamento: `nccmp -d -f $BASEL/saida/reprodiag.nc reprodiag.nc | head`.
3. **Localize a etapa.** Os logs dos PETs têm somas de verificação exatas de campos intermediários (`FIX-DIAG-BITSUM-01` e outros `FIX-DIAG-*`). Compare essas linhas entre a rodada da base e a atual (`PET000` para o mediador, primeiro PET do gelo para o SIS2); a primeira linha diferente aponta a etapa.
4. **Descarte a compilação.** Diferenças só no último bit, iguais em todas as rodadas, podem vir de opções de compilação. Compile o código de referência e o alterado com as mesmas opções e compare os dois entre si.
