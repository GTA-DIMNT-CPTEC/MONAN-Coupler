# MONAN-Coupler

Sistema acoplado atmosfera, oceano e gelo marinho: **MONAN-A 2.0** (MPAS-A, malha Voronoi hexagonal) acoplado ao **MOM6 + SIS2** (grade tripolar) pelo framework **NUOPC/ESMF 8.9.1**. Um mediador próprio calcula os fluxos turbulentos ar-mar por fórmulas bulk NCAR (Large e Yeager, 2009).

INPE / CGCT / DIMNT, Grupo de Trabalho para Acoplamento de Modelos. Máquina de referência: supercomputador Jaci (Cray XD 2000, PrgEnv-gnu). Licença GPLv3.

Componentes: MPAS-A 8.3.1 · MOM6 + SIS2 · ESMF/NUOPC 8.9.1. Branch de desenvolvimento: `develop`.

## Arquitetura

Quatro componentes NUOPC orquestrados por um driver único sob um relógio ESMF global. O componente de gelo (ICE, cap do SIS2) é opcional e só é criado com `use_sis2_dynamic = .true.`.

```text
        esmApp.F90  (programa principal)
              |
        esm.F90  (driver NUOPC: relogio, PETs, componentes e conectores)
        |          |          |            |
      ATM        MED         OCN          ICE
   MONAN-A    bulk NCAR      MOM6         SIS2
    (MPAS)   (mediador)   (dinamico)   (opcional)
```

O mediador reside em todos os PETs, então os conectores de e para o mediador funcionam como barreiras de sincronização. A cada intervalo de acoplamento os componentes trocam campos pelo mediador: o oceano e o gelo enviam SST, correntes e fração de gelo; a atmosfera envia vento, temperatura, umidade, pressão, radiação e precipitação; o mediador calcula os fluxos e os devolve. O detalhamento das RunSequences está em [`docs/analise-sequential-split-sis2.md`](docs/analise-sequential-split-sis2.md).

## Início rápido

Os scripts de instalação vivem em repositório separado, [`Coupler-Install`](https://github.com/GTA-DIMNT-CPTEC/Coupler-Install), com um instalador único que baixa o sistema (clone recursivo, com os modelos como submódulos) e compila tudo:

```bash
git clone --branch develop https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash
```

Pré-requisito: ESMF 8.9.1 já instalado, localizado por `run/setenv-gnu.bash`.

Em cada sessão de trabalho, na raiz do sistema acoplado:

```bash
source run/setenv-gnu.bash     # define ESMFMKFILE, MPAS_DIR, MOM6_ROOT, etc.
make                           # (re)compila bin/esmApp
bash run/run_esmApp.jaci       # submete via PBS (Cray PALS)
```

## Configuração do acoplamento

O modo de execução é escolhido no grupo `&nuopc_petlayout` do `nuopc.input`:

| Chave | Valores | Função |
| --- | --- | --- |
| `coupling_mode` | `sequential`, `concurrent` | ordem temporal de execução dos componentes |
| `pet_layout` | `split`, `shared` | ocupação espacial de PETs (blocos próprios ou compartilhados) |
| `use_sis2_dynamic` | `.true.`, `.false.` | ativa o componente de gelo SIS2 |
| `atm_pet_count`, `ocn_pet_count`, `ice_pet_count` | inteiros | número de PETs por componente no `split` (0 = automático) |
| `seq_repro` | `.true.`, `.false.` | variante reprodutível do `sequential+split+SIS2` (ver abaixo) |

Modos de execução. O eixo espacial `split` dá a cada componente um bloco próprio de PETs, e o `shared` faz todos ocuparem todos os PETs. O eixo temporal `sequential` roda os componentes um após o outro, e o `concurrent` os avança ao mesmo tempo em blocos disjuntos. O `concurrent+split` é o modo de produção; o `sequential+split` serve de referência e de recuo. A combinação `concurrent+shared` é proibida e barrada na leitura da configuração.

A chave `seq_repro = .true.` só tem efeito com `coupling_mode = 'sequential'`, `use_sis2_dynamic = .true.` e `pet_layout = 'split'`. Ela faz a RunSequence sequencial emitir o mesmo fluxo de dados do concorrente, tornando as duas rodadas comparáveis, sem alterar o modo concorrente. Fora desse contexto é ignorada, com aviso. O default `.false.` preserva o sequencial recomendado.

## Estrutura de diretórios

```text
MONAN-Coupler/
├── src/
│   ├── main/        esmApp.F90 (programa principal)
│   ├── driver/      esm.F90 (driver NUOPC, RunSequences, partição de PETs)
│   ├── mediator/    MED_cap.F90, med_bulk_ncar.F90, escritores de diagnóstico
│   ├── caps/        caps dos componentes: atmos (MPAS), ocean (MOM6), ice (SIS2)
│   └── shared/      utilitários (allreduce, tempo)
├── models/          submódulos: atmos/MONAN-Model, ocean/MOM6-examples
├── run/             run_esmApp.jaci, setenv-gnu.bash, setenv-site.bash
├── tools/           apoio: coupler, postproc, animation, atmos, ocean, dev
├── docs/            documentação técnica
├── nuopc.input      configuração da rodada
├── Makefile         compilação de bin/esmApp
└── README.md
```

## Compilação

O `Makefile` monta apenas o acoplador (`bin/esmApp`), assumindo os componentes já compilados pela instalação. Alvos úteis:

```bash
make            # compila bin/esmApp
make check      # verifica o ambiente e as dependências
make clean      # remove objetos; distclean remove tudo
make help       # lista os alvos
```

## Saídas e pós-processamento

Com o diagnóstico ativo, a rodada grava campos exportados em `diag_export/` e campos importados em `diag_import/` (`monan2_import_*.nc` no lado atmosférico e `mom6_import_*.nc` no lado oceânico), além dos logs do ESMF em `logs/`. Os scripts em `tools/` apoiam a análise: `tools/postproc/` para pós-processamento dos NetCDF, `tools/animation/` para animações, `tools/coupler/` para balanceamento de PETs, testes de modo e baterias de reprodutibilidade binária, `tools/atmos/` para as partições METIS e o teste do MPAS autônomo, `tools/ocean/` para a divisão de domínio do MOM6, e `tools/dev/` para linhas de base de comparação e o ambiente do `nccmp`. O catálogo completo, com a pergunta que cada ferramenta responde, está em [`docs/ferramentas.md`](docs/ferramentas.md).

## Reprodutibilidade binária

Desde 22/09/2026, o acoplador é reprodutível bit a bit: execuções idênticas, na mesma configuração de PETs, produzem o mesmo resultado nos modos sequencial e concorrente, com o SIS2 dinâmico e com o módulo de icebergs ligado (na configuração atual não há icebergs na simulação, então o código de icebergs em si ainda não foi exercitado). A causa da não reprodutibilidade anterior estava na ordem das somas dos remapeamentos do ESMF, e a correção fixa as duas camadas dessa ordem em todos os remapeamentos e ligações entre componentes (`B-SRCTERM-01`, `B-METHODS-TERMORDER-01`). A regra vale para qualquer remapeamento novo: ver [`docs/ferramentas.md`](docs/ferramentas.md), seção 6. A reprodutibilidade de uma configuração se verifica com o [`mede-taxa-repro.sh`](docs/uso-mede-taxa-repro.md).

## Documentação

A pasta [`docs/`](docs/) reúne a documentação técnica, entre ela a análise das RunSequences sequencial e concorrente, a integração do componente de gelo, a execução multi-nó e o CHANGELOG do projeto.

Guias de uso das ferramentas:

| Guia | Ferramentas |
| --- | --- |
| [`ferramentas.md`](docs/ferramentas.md) | catálogo de todas as ferramentas, com sequências típicas de uso |
| [`MULTINO-run_esmApp.md`](docs/MULTINO-run_esmApp.md) | `run_esmApp.jaci` |
| [`uso-plan-layout.md`](docs/uso-plan-layout.md) | `plan-layout.py` |
| [`uso-gen-metis.md`](docs/uso-gen-metis.md) | `gen-metis.bash` |
| [`domain-mom6.md`](docs/domain-mom6.md) | `domain-mom6.bash` |
| [`uso-analisa-balanceamento.md`](docs/uso-analisa-balanceamento.md) | `analisa_balanceamento_pets.py` |
| [`uso-mede-smt.md`](docs/uso-mede-smt.md) | `mede_smt.py` |
| [`uso-smoke-tests.md`](docs/uso-smoke-tests.md) | `test-concurrent.bash`, `test-sequential-split.bash` |
| [`uso-mede-taxa-repro.md`](docs/uso-mede-taxa-repro.md) | `mede-taxa-repro.sh` |
| [`uso-duplas-rodadas-repro.md`](docs/uso-duplas-rodadas-repro.md) | `roda-repro-reprodiag.sh`, `roda_repro_producao.sh`, `roda_repro_datm_mom6.sh`, `roda-repro-mpas-standalone.sh`, `set-nccmp-jaci.bash` |
| [`uso-linha-base.md`](docs/uso-linha-base.md) | `cria-linha-base.bash`, `compara-linha-base.bash` |

## Créditos

Desenvolvido pelo Grupo de Trabalho para Acoplamento de Modelos (INPE/CGCT/DIMNT). Distribuído sob a licença GNU GPL v3 (ver [`LICENSE`](LICENSE)).
