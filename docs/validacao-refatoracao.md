# Validação de alterações de código na Jaci

Roteiro para confirmar que uma alteração de código (refatoração, reorganização, correção que não deve mexer em cálculos) reproduz bit a bit uma linha de base. Foi o procedimento usado nas etapas R-FASE1-01 e R-FASE2A-01, em setembro de 2026.

## Linhas de base existentes

| Rótulo | Código | Compilação | Uso |
| --- | --- | --- | --- |
| R-REF-00 | `ea10fb6` (develop) | com FMA (compilação anterior ao Makefile 16.1) | registro histórico |
| **R-NOFMA-01** | `ea10fb6` (develop) | `-ffp-contract=off` | **referência atual** |

As duas usam a mesma configuração: `pet_layout = split`, 128 + 20 + 4 PETs (152), modo concorrente com SIS2 dinâmico, rodada de 1 dia (24 passos de 3600 s).

## 1. Ambiente

```bash
export COUPLER_ROOT=/p/projetos/gta/daniel.massaru/refatorado/Coupler-Install/MONAN-Coupler
export REF=/p/projetos/gta/daniel.massaru/refatorado
export MODELO=$REF/exp_monan2xmom6          # experimento com as entradas
export BASEL=$REF/baseline/R-NOFMA-01
```

## 2. Compilar

```bash
cd $COUPLER_ROOT
git status --short                          # arquivos rastreados: nada modificado
source run/setenv-gnu.bash
make clean && make 2>&1 | tee ../make.log
grep -c 'Error' ../make.log                 # esperado: 0
make printenv | grep FP_CONTRACT            # esperado: off
```

## 3. Preparar um diretório novo

Nunca reaproveite o diretório de uma rodada anterior. A cópia exclui as saídas que ficam no modelo de experimento:

```bash
d=teste_$(date +%Y%m%d_%H%M)
mkdir -p $REF/exp/$d
rsync -a \
  --exclude='diag_export/' --exclude='diag_import/' --exclude='diag_import-original/' \
  --exclude='logs/' --exclude='logs-antigos/' --exclude='INPUT_OLD_OK/' --exclude='RESTART/*' \
  --exclude='reprodiag.nc' --exclude='MONAN_DIAG_*.nc' --exclude='log.atmosphere.*' \
  --exclude='logfile.*' --exclude='ocean.stats*' --exclude='seaice.stats' \
  --exclude='ocean_month.nc' --exclude='ice.nc' --exclude='sea_ice_geometry.nc' \
  --exclude='*available_diags*' --exclude='*_parameter_doc.*' --exclude='done' --exclude='*.pbs' \
  --exclude='MOM_input_*' --exclude='diag_table_orig' --exclude='streams.atmosphere.original' \
  $MODELO/ $REF/exp/$d/
cp $BASEL/config/nuopc.input $REF/exp/$d/
```

## 4. Submeter

```bash
cd $REF/exp/$d
bash $COUPLER_ROOT/run/run_esmApp.jaci -n 152 --check && \
bash $COUPLER_ROOT/run/run_esmApp.jaci -n 152 -w 01:00:00
```

Para usar outro executável, defina `ESMAPP_BIN=<caminho>` antes das duas chamadas. Não altere o repositório (`git switch`, `git am`, `make`) enquanto o job estiver na fila ou rodando, a menos que use `ESMAPP_BIN` com um executável fora de `bin/`.

## 5. Conferir e comparar

```bash
cd $REF/exp/$d
grep -m1 'Iniciando'  logs/esmApp_run.log            # executável de fato usado
grep -m1 'Executável' logs/esmApp_run.log            # caminho e data de compilação
grep -c 'SIMULACAO CONCLUIDA COM SUCESSO' logs/esmApp_run.log
bash -c "source $COUPLER_ROOT/tools/dev/set-nccmp-jaci.bash && \
         bash $COUPLER_ROOT/tools/dev/compara-linha-base.bash -l R-NOFMA-01 -o $REF/baseline -e" \
  > compara.txt 2>&1
tail -6 compara.txt
```

## 6. Se der FAIL

1. **Repita a rodada** num diretório novo. Se as duas rodadas novas forem idênticas entre si e diferentes da base, a diferença é sistemática; se diferirem entre si, há algo que muda de uma execução para outra.
2. **Localize o primeiro instante.** No `reprodiag.nc` (a cada 10 minutos simulados), a primeira posição de tempo com diferença indica o passo de acoplamento: `nccmp -d -f $BASEL/saida/reprodiag.nc reprodiag.nc | head`.
3. **Localize a etapa.** Os logs dos PETs têm somas de verificação exatas de campos intermediários (`FIX-DIAG-BITSUM-01` e outros `FIX-DIAG-*`). Compare essas linhas entre a rodada da base e a atual (`PET000` para o mediador, primeiro PET do gelo para o SIS2); a primeira linha diferente aponta a etapa.
4. **Descarte a compilação.** Diferenças só no último bit, iguais em todas as rodadas, podem vir de opções de compilação. Compile o código de referência e o alterado com as mesmas opções e compare os dois entre si.
