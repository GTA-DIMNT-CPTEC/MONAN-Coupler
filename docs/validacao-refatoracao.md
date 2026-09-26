# Validação de alterações de código na Jaci

Roteiro para confirmar que uma alteração de código (refatoração, reorganização, correção que não deve mexer em cálculos) reproduz bit a bit uma linha de base. Foi o procedimento usado nas etapas R-FASE1-01 e R-FASE2A-01, em setembro de 2026.

## Linhas de base existentes

| Rótulo | Código | Compilação | Uso |
| --- | --- | --- | --- |
| R-REF-00 | `ea10fb6` (develop) | com FMA (compilação anterior ao Makefile 16.1) | registro histórico |
| **R-NOFMA-01** | `ea10fb6` (develop) | `-ffp-contract=off` | **referência atual** |

As duas usam a mesma configuração: `pet_layout = split`, 128 + 20 + 4 PETs (152), modo concorrente com SIS2 dinâmico, rodada de 1 dia (24 passos de 3600 s).

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
| `compara NOME` | confere que a rodada terminou, mostra executável e revisão usados e compara com a linha de base, conferindo também as entradas (`-e`); em caso de FAIL, mostra as primeiras diferenças |

Variáveis opcionais: `REF` (padrão: a pasta que contém `Coupler-Install/`), `MODELO` (padrão: `$REF/exp_monan2xmom6`), `BASE` (padrão: `R-NOFMA-01`) e `NPES` (padrão: 152). Para usar outro executável, `ESMAPP_BIN=<caminho>` antes do `submete`.

Não altere o repositório (`git switch`, `git am`, `make`) enquanto o job estiver na fila ou rodando.

## 3. Se der FAIL

1. **Repita a rodada** num diretório novo. Se as duas rodadas novas forem idênticas entre si e diferentes da base, a diferença é sistemática; se diferirem entre si, há algo que muda de uma execução para outra.
2. **Localize o primeiro instante.** No `reprodiag.nc` (a cada 10 minutos simulados), a primeira posição de tempo com diferença indica o passo de acoplamento: `nccmp -d -f $BASEL/saida/reprodiag.nc reprodiag.nc | head`.
3. **Localize a etapa.** Os logs dos PETs têm somas de verificação exatas de campos intermediários (`FIX-DIAG-BITSUM-01` e outros `FIX-DIAG-*`). Compare essas linhas entre a rodada da base e a atual (`PET000` para o mediador, primeiro PET do gelo para o SIS2); a primeira linha diferente aponta a etapa.
4. **Descarte a compilação.** Diferenças só no último bit, iguais em todas as rodadas, podem vir de opções de compilação. Compile o código de referência e o alterado com as mesmas opções e compare os dois entre si.
