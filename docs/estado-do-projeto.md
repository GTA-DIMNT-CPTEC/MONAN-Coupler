# Estado do projeto: refatoração do MONAN-Coupler

Documento de passagem, para retomar o trabalho em outra sessão ou com outra pessoa. Atualizado na R-FASE12-07 (02/10/2026). A versão longa anterior, com o andamento etapa por etapa, está em [`historico/estado-do-projeto-ate-fase12.md`](historico/estado-do-projeto-ate-fase12.md).

## 1. O projeto

O MONAN-Coupler acopla a atmosfera MONAN-A 2.0 (baseada no MPAS-A) ao oceano MOM6 e ao gelo marinho SIS2 por ESMF/NUOPC, com um mediador próprio para os fluxos ar-mar. A refatoração tem uma regra única: melhorar a estrutura sem mudar nenhum resultado, conferido bit a bit contra uma linha de base a cada etapa. A arquitetura atual está em [`arquitetura-acoplamento.md`](arquitetura-acoplamento.md).

## 2. Ambiente

| Item | Valor |
| --- | --- |
| Repositório | `GTA-DIMNT-CPTEC/MONAN-Coupler`, a partir do commit `ea10fb6` do `develop` |
| Ramo | `refactor/principal`; cada etapa validada tem a tag `faseN-NN-validada` |
| Instalação na Jaci | `/p/projetos/gta/daniel.massaru/refatorado/Coupler-Install/MONAN-Coupler` |
| Produção (não usar para validar) | `/p/projetos/gta/daniel.massaru/coupling/Coupler-Install/MONAN-Coupler` |
| Linhas de base | `/p/projetos/gta/daniel.massaru/refatorado/baseline/` |
| Rodadas de validação | `/p/projetos/gta/daniel.massaru/refatorado/exp/<nome>` |
| Compilador e bibliotecas | Cray PrgEnv-gnu (gfortran), MPICH, ESMF 8.9.1, NetCDF 4.9 |
| Configuração de validação | 128 + 20 + 4 PETs, concorrente, SIS2 dinâmico, 24 passos de 3600 s (29 a 30/03/2026) |

## 3. Fases

| Fase | Assunto | Etapas | Situação |
| --- | --- | --- | --- |
| 1 | código morto, duplicação e remendos; módulos comuns; driver reescrito | R-FASE1-01 e 2 correções | concluída |
| 2A, 2B | interpolação plugável (`src/regrid`), sem BLOCK, compilação sem FMA, procedimentos de módulo | 6 | concluída |
| 3 | calendário pelo `ESMF_Time`, `nc_writer`, comentários sem histórico, linha de base R-NOFMA-02 | 4 | concluída |
| 4, 5 | rotinas longas em etapas, ferramentas de conferência local, limpeza de comentários e scripts | 15 | concluída |
| 6 a 9 | código limpo: conferências num comando, testes com valor esperado, estado explícito, módulos coesos, duplicação | 31 | concluída (`fase9-07-validada`) |
| 10 | decisões que mudam resultados (seção 6) | uma etapa por decisão | aguardando decisões |
| 11 | arquitetura de acoplamento: mapa, catálogo de malhas, mediador por fases, conferência, esquemas de pesos | R-FASE11-01 a 26 | concluída (`fase11-26-validada`) |
| 12 | identificadores Fortran em inglês; tabelas em `tools/dev/nomes/`; documentação de trabalho mais curta | R-FASE12-01 a 07 | concluída (`fase12-07-validada`) |
| 13 | código de produção limpo e de fácil manutenção: defeitos C1 a C5, diagnósticos separados do cálculo, registro com níveis, comentários, mediador legível, estrutura | R-FASE13-01 a 24 (blocos 0 a C; bloco D depois da validação de DOCN e DATM), na NTC de análise da arquitetura, com a migração do registro dividida em duas etapas (11 e 12) | em execução; bloco 0 (01 a 05) validado; bloco A: 06 e 07 (P2) validadas (`fase13-07-validada`); 08 a 12 (P10: sondas encerradas retiradas e registro com níveis em todo o código) validadas (`fase13-12-validada`); 13 (P1: comentários do mediador) validada (`fase13-13-validada`); 14 (P1: comentários dos caps) validada (`fase13-14-validada`); 15 (P1: comentários de coupling, regrid, shared, driver e programa principal) validada (`fase13-15-validada`), bloco A concluído; bloco B: 16 (P7: dicionário com nome longo e nome CF, consultado pelos gravadores) validada (`fase13-16-validada`); 17 (P8: campos internos do mediador por nome) validada (`fase13-17-validada`); 18 (P8: exportação do mediador pelo mapa; fecha C5) validada (`fase13-18-validada`), bloco B concluído; bloco C: 19 (P3: leitor dos dados oceânicos em `src/shared`; `time_utils` com o `ChkErr` comum) validada (`fase13-19-validada`); 20 (P3: mapa e framework sem variáveis globais; conferência `camadas`; fecha D7) validada (`fase13-20-validada`, rodada R-FASE13-20b), P3 concluída; 21 (P11: configuração lida por grupo; conferência `config`) validada (`fase13-21-validada`); 22 (P5: sequência de execução como texto; chave `run_sequence_file`) validada (`fase13-22-validada`); 23 (P6: mapa por grupos de campos e passagens) validada (`fase13-23-validada`); 24 (P6: coluna `options` em `ROUTES`) validada (`fase13-24-validada`), bloco C concluído; blocos 0 a C concluídos (24 etapas); bloco D depois da validação do DOCN e do DATM; 25 (conferência `cabecalhos`, `submete` recusa logs antigos, `nuopc.input` da raiz conferido, aviso de `run_sequence_file`) validada (`fase13-25-validada`); 26 (resto da P5: registro dos modelos e divisão de PETs por blocos) validada (`fase13-26-validada`), P5 concluída; 27 (P9: anúncio comum, `cap_advertise`) em validação |

O que cada etapa mudou está no [`CHANGELOG.md`](CHANGELOG.md) (resumo) e em [`historico/CHANGELOG-ate-fase12.md`](historico/CHANGELOG-ate-fase12.md) (texto completo).

## 4. Linhas de base

| Rótulo | Código | FMA | Uso |
| --- | --- | --- | --- |
| R-REF-00 | `ea10fb6` | ligada | registro histórico |
| R-NOFMA-01 | `ea10fb6` | desligada | referência das fases 2A a 3 |
| **R-NOFMA-02** | `fase3-03-validada` | desligada | **referência atual** (73 arquivos) |

O MANIFEST da R-NOFMA-02 só se altera com `tools/dev/anota-linha-base.bash`. Detalhes em [`validacao-refatoracao.md`](validacao-refatoracao.md) e [`uso-linha-base.md`](uso-linha-base.md).

## 5. Como validar e entregar uma etapa

1. Conferências locais: `tools/dev/confere-tudo.bash HEAD` antes do commit (`HEAD~1` depois; `-i` quando só mudam comentários). Ver [`conferencias-locais.md`](conferencias-locais.md).
2. Um commit, autor Daniel Massaru <dmassaru@gmail.com>, sem linhas de coautoria nem marcas de ferramentas; `git format-patch -1 --stdout > R-FASEnn-NN.patch`, com `head -1` e `md5sum` informados.
3. Na Jaci, um comando por vez:

```bash
export COUPLER_ROOT=/p/projetos/gta/daniel.massaru/refatorado/Coupler-Install/MONAN-Coupler
cd $COUPLER_ROOT
git am ../R-FASEnn-NN.patch
source run/setenv-gnu.bash > /tmp/setenv.txt 2>&1
make
bash tools/dev/valida_rodada.bash prepara <nome>
bash tools/dev/valida_rodada.bash submete <nome>
bash tools/dev/valida_rodada.bash compara <nome>
```

4. Esperado: PASS, 73 iguais e o relatório de acoplamento igual ao da rodada anterior. Com PASS: `git tag fasenn-NN-validada` e envio do ramo e da tag ao GitHub.
5. Atualizar este documento e o CHANGELOG; o README e a arquitetura quando a etapa os afeta.

| Armadilha | Como evitar |
| --- | --- |
| `COUPLER_ROOT` definido depois do `setenv` (liga as bibliotecas da produção) | defini-lo antes; o `prepara` acusa |
| `git am` sem `make` (a rodada valida o binário anterior) | `make` depois do `git am`; o `prepara` recusa executável mais antigo que o último commit em `src/` ou no `Makefile`, e fontes com mudanças fora de commit |
| `source setenv ... \| grep` (`ESMFMKFILE` indefinido) | redirecionar a saída para arquivo |
| blocos longos colados no terminal | um comando por vez |
| FMA ligada (diferença no último bit) | `FP_CONTRACT=off`, o padrão |
| Python 3.6 da Jaci | scripts de `tools/dev/` sem recursos do 3.7 e com UTF-8 explícito |
| atributos NetCDF mudados ("só metadados") | não reprova; conferir com `ncdump -h` |

## 6. Decisões em aberto e defeitos conhecidos

**Foco atual (decisão do GT, out/2026).** O esforço se concentra nos componentes de produção: MONAN-A (ATM), MOM6 com SIS2 (OCN) e SIS2 dinâmico (ICE). Os modos DOCN e DATM são mantidos (não serão removidos) e serão validados em momento oportuno; até lá, continuam compilados e conferidos pelos testes locais. Problemas conhecidos desses modos: o DOCN com o contorno direto para na inicialização (o MONAN-A importa `Sx_tsfc`, `Sf_albedo` e `Sx_omask`, que o DOCN não exporta); a combinação DOCN com contorno pelo mediador nunca foi executada; o DATM está no mapa, mas o driver não o registra. Desde a R-FASE13-01, essas combinações são aceitas com aviso no início da rodada, e as que nunca funcionam (MOM6 com contorno direto, SIS2 com DOCN) são recusadas na leitura; a regra está só na tabela `COUPLER_MODES` (`src/shared/coupler_config.F90`).

Nenhum foi corrigido porque todos mudariam resultados ou comportamento; cada um, se decidido, vira uma etapa própria da fase 10.

| Item | Situação |
| --- | --- |
| escolhas da arquitetura (exportar na malha de fluxo, `redist` nos conectores, `mpassit` no cap atmosférico, OISST por rota, regra única de índice) | [`arquitetura-acoplamento.md`](arquitetura-acoplamento.md), seção 7 |
| DATM | está no mapa, mas o driver não o registra; com `use_datm` a conferência para a rodada. Registrar ou retirar. A época do arquivo JRA55 (01:30 ou 00:00) também está em aberto |
| `u_star` sobre o gelo | o mediador não envia; `is%aib%u_star` é sempre zero no cap do SIS2 |
| fração de gelo sem o SIS2 | o mediador procura `Si_ifrac` que não anuncia; a fração sai do OISST ou do limiar de SST (`med_ocean`) |
| `Foxx_sen` e `Fioi_sen` | `standard_name` diz "para cima", mas o cálculo é positivo para a superfície (só metadados) |
| grade do OISST no mediador | centro da célula sem a meia célula em longitude (`ORIGIN_EAST0_CORNER`); suaviza o campo do DOCN |
| `ReadJRAFieldInterp` (DATM) | mesma falha que a R-FASE13-03 corrigiu no DOCN: só o PET 0 sabe que a leitura falhou; corrigir quando o DATM for validado |
| `mpi_f08` | opcional; sem ganho de desempenho, fora da sequência |
| atributos dos diagnósticos NetCDF | o mediador e a exportação do MONAN-A usam o dicionário (`FIELDS`, R-FASE13-16); a importação do MONAN-A (`monan2_import_*.nc`) e o DOCN (`docn_import_*.nc`) têm textos próprios. Diferenças: `long_name` de `So_t`, `Si_ifrac`, `Sf_zorl`, `So_u`, `So_v` e `Sf_albedo` ("importada pelo MPAS"; no DOCN, "SST interpolada (OISST→NUOPC)" e as correntes); `standard_name` de `So_u` e `So_v` sem o prefixo `surface_` na importação do MONAN-A e ausente no DOCN; unidade das correntes `m/s` no DOCN (`m s-1` no dicionário). Unificar muda só metadados; decisão do GT |

## 7. Integração ao `develop`

Adiada por decisão do Daniel. Quando for feita, na Jaci, um comando por vez, a partir da última tag validada:

| Passo | Comando | O que conferir |
| --- | --- | --- |
| 1 | `git status` | árvore limpa em `refactor/principal` |
| 2 | `git fetch origin` | |
| 3 | `git merge-base --is-ancestor origin/develop refactor/principal && echo SEM-NOVIDADES` | `SEM-NOVIDADES` |
| 4 | `git checkout develop` | |
| 5 | `git merge --ff-only origin/develop` | |
| 6 | `git merge --no-ff refactor/principal -m "Integra a refatoracao (fases 1 a 12) ao develop"` | sem conflitos |
| 7 | `git diff refactor/principal develop --stat` | vazio |
| 8 | `git tag refatoracao-integrada` | |
| 9 | `git push origin develop` | |
| 10 | `git push origin refatoracao-integrada` | |

Se o passo 3 não imprimir `SEM-NOVIDADES`, o `develop` mudou desde `ea10fb6`: resolver os conflitos, compilar e validar antes do passo 8.

## 8. Para retomar

Basta o ramo `refactor/principal` e a descrição do que fazer. Documentos: este, [`arquitetura-acoplamento.md`](arquitetura-acoplamento.md), [`CHANGELOG.md`](CHANGELOG.md), [`conferencias-locais.md`](conferencias-locais.md) e [`roteiro-codigo-limpo.md`](roteiro-codigo-limpo.md). O RPQ e as notas técnicas ficam fora do repositório, em PDF e LaTeX.

Ambiente local (Ubuntu 24.04, sem as bibliotecas dos modelos; o ESMF leva cerca de 40 minutos para compilar):

```bash
apt-get install -y gfortran g++ make git python3 openmpi-bin libopenmpi-dev libnetcdff-dev netcdf-bin
git clone --depth 1 --branch v8.9.1 https://github.com/esmf-org/esmf.git $HOME/esmf
export ESMF_DIR=$HOME/esmf ESMF_COMPILER=gfortran ESMF_COMM=mpich ESMF_NETCDF=nc-config ESMF_BOPT=O ESMF_PIO=OFF ESMF_INSTALL_PREFIX=$HOME/esmf-install
cd $HOME/esmf && make -j2 lib && make install
export ESMFMKFILE=$HOME/esmf-install/lib/libO/Linux.gfortran.64.mpich.default/esmf.mk
export MPIRUN="mpirun.openmpi --allow-run-as-root --oversubscribe"
git clone --branch refactor/principal https://github.com/GTA-DIMNT-CPTEC/MONAN-Coupler.git
cd MONAN-Coupler && tools/dev/confere-tudo.bash HEAD
```
