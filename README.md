# MONAN-A 2.0 × MOM6+SIS2 — Sistema Acoplado NUOPC/ESMF

> **INPE / CGCT / DIMNT — GT Acoplamento de Modelos**
> v14.21 · ESMF/NUOPC 8.9.1 · MPAS-A 8.3.1 · MOM6+SIS2 · Agosto 2026

Acoplador atmosfera–oceano–gelo de **produção**: o **MONAN-A 2.0** (MPAS-A, malha
Voronoi hexagonal) acoplado ao **MOM6+SIS2** (grade tripolar) pelo framework
**NUOPC/ESMF 8.9.1**, no supercomputador **Jaci** (Cray XD 2000, PrgEnv-gnu). Um
mediador próprio calcula os fluxos turbulentos ar–mar por fórmulas *bulk* NCAR.

---

## Sumário

1. [Arquitetura](#1-arquitetura)
2. [Início rápido](#2-início-rápido)
3. [Instalação](#3-instalação)
4. [Estrutura de diretórios](#4-estrutura-de-diretórios)
5. [Dependências](#5-dependências)
6. [Configuração do acoplamento](#6-configuração-do-acoplamento)
7. [Compilação e execução](#7-compilação-e-execução)
8. [Multi-nó e particionamento MPI](#8-multi-nó-e-particionamento-mpi)
9. [Saídas e pós-processamento](#9-saídas-e-pós-processamento)
10. [Módulos Fortran](#10-módulos-fortran)
11. [Réplica da inicialização do MPAS](#11-réplica-da-inicialização-do-mpas)
12. [Histórico de versões](#12-histórico-de-versões)
13. [Referências](#13-referências)

---

## 1. Arquitetura

Três componentes NUOPC — atmosfera (ATM), mediador (MED) e oceano (OCN) — são
orquestrados por um driver único, sob um relógio ESMF global:

```
        ┌────────────────────────────────────┐
        │   esmApp.F90 — programa principal   │
        └─────────────────┬──────────────────┘
        ┌─────────────────▼──────────────────┐
        │        esm.F90 — Driver NUOPC       │
        │     relógio · PETs · ATM/MED/OCN    │
        └────┬───────────────┬───────────────┬┘
             │               │               │
      ┌──────▼─────┐  ┌───────▼─────┐  ┌──────▼─────┐
      │    ATM     │  │     MED     │  │    OCN     │
      │  MONAN-A   │  │  bulk NCAR  │  │  MOM6+SIS2 │
      │   (MPAS)   │  │ (mediador)  │  │ (dinâmico) │
      └──────┬─────┘  └──────┬──────┘  └──────┬─────┘
             └───────────────┴───────────────┘
                     Conectores NUOPC
```

**Fluxo de acoplamento por passo** (Fase 2, MOM6 ativo):

| Passo | Conector  | Campos / ação                                        |
|------:|:----------|:-----------------------------------------------------|
|     1 | OCN → MED | `So_t`, `So_u`, `So_v`, `Si_ifrac`                   |
|     2 | ATM → MED | `u10m`, `v10m`, `tbot`, `qbot`, `pbot`, … (9 campos) |
|     3 | MED       | *bulk* NCAR (Large & Yeager 2009) → 14 fluxos        |
|     4 | MED → OCN | `Foxx_*` / `Faxa_*` → forçantes do MOM6              |
|     5 | OCN       | `step_MOM` — avança MOM6+SIS2 por `dt_coupling`      |
|     6 | MED → ATM | `So_t`, `Si_ifrac`, `So_u`, `So_v`, `Sf_zorl` → MPAS |
|     7 | ATM       | dinâmica + física (N × `dt_atm`)                     |

> **Prefixos dos campos.** `So_*` estado do oceano · `Si_*` gelo marinho ·
> `Sf_*` estado de superfície · `Foxx_*` / `Faxa_*` fluxos. Na **Fase 1** (DOCN)
> o OCN exporta diretamente para o ATM (`use_med_to_mpas=.false.`), sem mediador.

---

## 2. Início rápido

Este repositório (`MONAN-Coupler`) traz o **MONAN-Model** e o **MOM6-examples**
como **submódulos** (em `models/atmos/` e `models/ocean/`). Os **scripts de
instalação vivem em repositório separado** (`Coupler-Install`), com um instalador
único (`install.bash`) que baixa o sistema com `git` recursivo e compila tudo em
um só comando.

**Caminho recomendado (um comando):**

```bash
git clone --branch develop https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash            # clona o sistema (recursivo, develop) e instala
```

O `install.bash` executa `git clone --recursive --branch develop
…/MONAN-Coupler.git` (trazendo os dois modelos e os submódulos aninhados do
MOM6-examples) e, em seguida, roda as três etapas de instalação. Opções:
`--coupler-root DIR`, `--branch BRANCH`, `--no-install` (só baixa),
`--from N` / `--only N` (repassadas ao instalador).

**Clone manual (equivalente), se preferir:**

```bash
git clone --recursive --branch develop \
    https://github.com/GTA-DIMNT-CPTEC/MONAN-Coupler.git
export COUPLER_ROOT="$PWD/MONAN-Coupler"
bash /caminho/Coupler-Install/build.bash
```

> **Pré-requisito adicional:** ESMF 8.9.1 já instalado (com MOAB interno),
> localizado por `run/setenv-gnu.bash`.

**Rotina de cada sessão de trabalho** (na raiz do sistema acoplado):

```bash
source run/setenv-gnu.bash             # define ESMFMKFILE, MPAS_DIR, MOM6_ROOT…
make                                   # (re)compila bin/esmApp
bash run/run_esmApp.jaci -n 128        # submete via PBS (128 PETs)
```

---

## 3. Instalação

Os scripts de instalação residem em **repositório próprio** (`Coupler-Install`),
separado do sistema acoplado; as funções comuns ficam em `include.bash`.

| Script            | Etapa | Finalidade                                    |
|:------------------|:-----:|:----------------------------------------------|
| `install.bash`    |   0   | Baixa o sistema (git recursivo) **e** instala |
| `build.bash`      |   —   | Só as 3 etapas (assume o sistema já baixado)  |
| `1-monan.bash`    |   1   | MONAN-A 2.0 → `lib/monan2`, `mod/monan2`      |
| `2-mom.bash`      |   2   | MOM6+SIS2+FMS → `lib/{fms,mom6,nuopc}`        |
| `3-coupler.bash`  |   3   | Compila e linka `bin/esmApp`                  |

Como os scripts vivem fora da árvore do acoplador, a raiz do sistema é informada
por **`COUPLER_ROOT`** (o `install.bash` a define e exporta automaticamente; ao
rodar um instalador isolado, exporte-a ou use `--coupler-root`).

Opções úteis: `install.bash --no-install` (só baixa), `build.bash --from N`
(retoma na etapa N), `1-monan.bash --skip-init-atm`, `2-mom.bash --only-nuopc`.
Atalhos via `make` (no `Coupler-Install`): `make` (= baixa + instala),
`make download`, `make build FROM=N`, `make check`, `make help`.

### Configuração de sítio (`sites/site-jaci.bash`)

Este é o **único arquivo a editar** ao trocar de usuário, máquina ou versões de
módulo. Centraliza tudo que é específico do ambiente: caminho do ESMF, listas de
módulos, alvo de CPU, paralelismo (`MAKE_JOBS`) e wrappers do compilador. Os
instaladores o carregam automaticamente, e o `install.bash` deixa uma cópia em
`<COUPLER_ROOT>/run/setenv-site.bash` — assim as sessões de build
(`source run/setenv-gnu.bash`) a encontram sem o instalador presente.

Três formas de uso, da mais simples à mais flexível:

- **Jaci (padrão):** nada a fazer — os valores já estão corretos.
- **Ajuste pontual**, sem editar o arquivo: exporte a variável antes de instalar
  (qualquer valor exportado tem prioridade sobre o padrão do sítio).
  ```bash
  export MAKE_JOBS=16
  export ESMF_ROOT=/meu/caminho/esmf-8.9.1
  bash install.bash
  ```
- **Outra máquina:** copie o arquivo, ajuste os valores e aponte `SITE_ENV`:
  ```bash
  cp sites/site-jaci.bash sites/site-meuhost.bash   # edite os valores
  export SITE_ENV="$PWD/sites/site-meuhost.bash"
  bash install.bash
  ```

### Notas de instalação

- **Fontes (submódulos).** Os modelos chegam como submódulos no clone recursivo:
  **MONAN-Model** em `models/atmos/` e **MOM6-examples** (com seus próprios
  submódulos) em `models/ocean/`. As etapas 1 e 2 confirmam a presença das
  árvores e, se algum submódulo faltar, executam
  `git submodule update --init --recursive`. Para usar um *fork* como origem,
  ajuste a URL no `.gitmodules` (ou exporte `MONAN_MODEL_URL` / `MOM6_EXAMPLES_URL`
  no modo legado sem submódulos).
- **ESMF e MOAB.** O acoplador usa o ESMF 8.9.1 via `esmf.mk`
  (`ESMF_ROOT` / `ESMFMKFILE`, definidas em `run/setenv-site.bash`). O MOAB é
  **interno ao `libesmf`** — não há `-lMOAB` externo. Para um ESMF com MOAB
  externo, defina `USE_EXTERNAL_MOAB=yes` e `MOAB_DIR`.
- **Template mkmf.** O `2-mom.bash` usa `templates/cray-gnu-monan.mk` (versionado
  no `Coupler-Install`, livre de caminhos pessoais). Para apontar outro:
  `export MKMF_TEMPLATE_SRC=…`.

---

## 4. Estrutura de diretórios

São **dois repositórios distintos**. O **sistema acoplado** (com os modelos como
submódulos):

```
MONAN-Coupler/                ← repositório do sistema acoplado (branch develop)
├── README.md                 ← este arquivo
├── .gitmodules               ← submódulos models/atmos e models/ocean
├── Makefile                  ← build do acoplador (bin/esmApp)
├── nuopc.input               ← namelist de acoplamento
├── src/
│   ├── main/esmApp.F90       ← ponto de entrada
│   ├── driver/esm.F90        ← driver NUOPC
│   ├── mediator/             ← MED (bulk NCAR): MED_cap + 4 módulos
│   ├── caps/atmos/           ← cap MONAN-A (MPAS) + DATM
│   ├── caps/ocean/           ← cap MOM6+SIS2 + DOCN (+ upstream/)
│   └── shared/               ← mpi_allreduce_*, time_utils
├── models/                   ← submódulos das fontes dos modelos
│   ├── atmos/MONAN-Model/    ← MONAN-A 2.0 (MPAS-A 8.3.1)
│   └── ocean/MOM6-examples/  ← MOM6+SIS2+FMS (com submódulos)
├── tools/
│   ├── postproc/             ← pós-processamento (Python)
│   ├── animation/            ← animações (Python)
│   └── coupler/              ← plan-layout.py (planejador de topologia)
├── run/
│   ├── setenv-gnu.bash       ← ambiente de compilação (Jaci/GNU)
│   ├── setenv-site.bash      ← config de sítio (cópia do install.bash)
│   ├── run_esmApp.jaci       ← submissão PBS multi-nó (pré-check ciente do layout)
│   └── gen-metis.bash        ← gera partições METIS do MPAS por modo
├── mod/                      ← módulos .mod (gerados na instalação)
├── lib/                      ← libs .a (gerados na instalação)
├── diag_export/              ← monan_export_*.nc
└── diag_import/              ← *_import_*.nc, sst_ifrac_diag/
```

E o **repositório do instalador** (separado):

```
Coupler-Install/    ← repositório dos scripts de instalação
├── Makefile        ← atalhos (make / make build / make check)
├── install.bash    ← ★ baixa (git recursivo) e instala
├── build.bash      ← só as 3 etapas (já baixado)
├── include.bash    ← funções comuns (sourced)
├── 1-monan.bash    ← etapa 1 — MONAN-A 2.0
├── 2-mom.bash      ← etapa 2 — MOM6+SIS2+FMS
├── 3-coupler.bash  ← etapa 3 — linka bin/esmApp
├── sites/          ← config por máquina (+ site-template.bash)
├── templates/      ← cray-gnu-monan.mk (mkmf)
└── docs/           ← CHANGELOG.md, notas de design
```

---

## 5. Dependências

| Biblioteca            | Versão     | Função                                  |
|:----------------------|:-----------|:----------------------------------------|
| ESMF / NUOPC          | 8.9.1      | Framework de acoplamento (MOAB interno) |
| MPAS-A                | 8.3.1      | Dinâmica e física atmosférica           |
| MOM6+SIS2             | tag NUOPC  | Oceano e gelo marinho dinâmicos         |
| FMS                   | 2024.01+   | Infraestrutura GFDL (dep. do MOM6)      |
| Parallel-NetCDF       | 1.12.3+    | I/O paralelo do MOM6                    |
| gfortran (PrgEnv-gnu) | 12.3+      | Compilador (wrapper Cray `ftn`)         |
| MPI                   | Cray MPICH | Comunicação paralela                    |
| Python                | 3.9+       | Pós-processamento (netCDF4, matplotlib) |

O `run/setenv-gnu.bash` verifica as versões instaladas no Jaci e a presença das
6 bibliotecas do MONAN-A em `lib/monan2`.

---

## 6. Configuração do acoplamento

Toda a configuração de tempo de execução fica no namelist Fortran `nuopc.input`,
lido por `mpas_cap_config_mod`; grupos omitidos usam *defaults*.

### 6.1 Modos de operação (`&nuopc_mode`)

| `use_datm` | `use_docn` | `use_med_to_mpas` | Modo                    |
|:----------:|:----------:|:-----------------:|:------------------------|
| `.false.`  | `.false.`  |     `.true.`      | MPAS + MOM6 (produção)  |
| `.false.`  |  `.true.`  |     `.false.`     | MPAS + DOCN (Fase 1)    |
|  `.true.`  | `.false.`  |     `.true.`      | DATM + MOM6 (teste OCN) |
|  `.true.`  |  `.true.`  |     `.false.`     | DATM + DOCN (teste MED) |

> `use_med_to_mpas=.true.` é **obrigatório** quando `use_docn=.false.`: sem ele o
> MPAS não recebe SST/gelo, pois o MOM6 não expõe esses campos pelo caminho
> direto OCN→ATM da Fase 1.

**Exemplo — 24 h com MOM6 dinâmico (Fase 2):**

```fortran
&nuopc_driver
  start_date = '2026-03-29'  stop_date = '2026-03-30'
  dt_coupling = 3600         dt_atm = 60          ! [s]
/

&nuopc_mode
  use_datm = .false.  use_docn = .false.  use_med_to_mpas = .true.
/
```
### 6.2 Particionamento MPI dos componentes (`&nuopc_petlayout`)

Grupo introduzido na v14.17; reorganizado na v14.20. Controla a distribuição de
*ranks* MPI entre os componentes e a ordem em que eles avançam, em tempo de
execução, sem recompilar:

```fortran
&nuopc_petlayout
  coupling_mode = 'sequential'  ! 'sequential' (padrão) | 'concurrent'
  pet_layout    = 'shared'      ! 'shared' (padrão) | 'split'
  atm_pet_count = 0             ! só com 'split': PETs do MPAS (0 = auto: ceil(N/2))
  ocn_pet_count = 0             ! só com 'split': PETs do MOM6 (0 = auto: N - atm)
/
```

São **dois eixos ortogonais**. Até a v14.19 eles estavam colapsados em
`coupling_mode`, o que fazia `atm_pet_count`/`ocn_pet_count` serem descartados
em silêncio no modo `sequential`.

| Eixo | Chave | Pergunta que responde | Onde age |
|:-----|:------|:----------------------|:---------|
| Temporal | `coupling_mode` | ATM e OCN avançam em série ou ao mesmo tempo? | `SetRunSequence` (a *RunSequence*) |
| Espacial | `pet_layout` | ATM e OCN ocupam os mesmos PETs ou blocos disjuntos? | `SetModelServices` (as `petList`) |

#### Eixo temporal — `coupling_mode`

| Valor | Comportamento |
|:------|:--------------|
| `sequential` (padrão) | ATM e OCN avançam um depois do outro. O mediador entrega os campos do **mesmo** passo, sem defasagem. Tempo por passo ≈ `t_ATM + t_OCN`. |
| `concurrent` | ATM e OCN avançam ao mesmo tempo. Cada um recebe os campos calculados no passo **anterior** (`t − dt_coupling`). Tempo por passo ≈ `max(t_ATM, t_OCN)`. |

#### Eixo espacial — `pet_layout`

| Valor | Comportamento |
|:------|:--------------|
| `shared` (padrão) | MPAS, MED e OCN compartilham **todos** os PETs. Sem split de comunicador. `atm_pet_count` e `ocn_pet_count` devem ser `0`. |
| `split` | MPAS e MOM6 em blocos **disjuntos** de PETs, cada um no seu comunicador; o MED permanece em todos os PETs. |

#### As quatro combinações

| `coupling_mode` | `pet_layout` | Quando usar |
|:----------------|:-------------|:------------|
| `sequential` | `shared` | Baseline, testes de *correctness*, execuções menores. Comportamento histórico e padrão. |
| `sequential` | `split` | MPAS e MOM6 com decomposições de tamanhos muito diferentes (ex.: MPAS em 2048 PETs, MOM6 em 128 PEs), **sem** o lag de um passo. |
| `concurrent` | `split` | Produção em escala, com custo calibrado. |
| `concurrent` | `shared` | **Rejeitado.** PETs disjuntos são a própria definição de execução concorrente; `config_read` aborta com mensagem explícita. |

Omitir `pet_layout` é seguro: ele é derivado do `coupling_mode`
(`concurrent`→`split`, `sequential`→`shared`), de modo que uma `nuopc.input`
anterior à v14.20 mantém exatamente o comportamento que tinha.

Em `split`, `atm_pet_count + ocn_pet_count` deve ser igual ao `-n` do job. O
`run_esmApp.jaci` valida ainda no nó de login, e o driver valida de novo antes
de inicializar os componentes, abortando com mensagem clara em caso de
divergência. Com `0` em ambos, a divisão é automática.

**Exemplo — produção concorrente, 128 PETs com divisão 88:40:**

```fortran
&nuopc_petlayout
  coupling_mode = 'concurrent'
  pet_layout    = 'split'
  atm_pet_count = 88     ! MPAS  → PET 0..87
  ocn_pet_count = 40     ! MOM6  → PET 88..127
/
```

**Exemplo — sequencial com split, 2176 PETs (MOM6 restrito a 128 PEs):**

```fortran
&nuopc_petlayout
  coupling_mode = 'sequential'
  pet_layout    = 'split'
  atm_pet_count = 2048   ! MPAS  → PET 0..2047
  ocn_pet_count = 128    ! MOM6  → PET 2048..2175
/
```

> **`sequential + split` não acelera nada.** ATM e OCN não se sobrepõem no
> tempo, então os PETs do outro componente ficam ociosos em cada fase e o tempo
> de parede continua sendo a soma. O que essa combinação resolve é outra coisa:
> permitir que o `LAYOUT` do `MOM_input` fique dimensionado para poucos PEs
> enquanto o MPAS usa milhares, sem pagar a defasagem de um passo do modo
> concorrente. Escolha-a por restrição de decomposição ou de memória, nunca por
> desempenho.

> **Acoplamento defasado.** Em modo concorrente o MPAS e o MOM6 avançam ao mesmo
> tempo; cada um recebe os campos que o mediador calculou no passo **anterior**
> (`t − dt_coupling`). Essa defasagem de um passo é intencional (estratégia do
> CESM / *ocean lag*) e negligenciável para `dt_coupling ≤ 3600 s`.

> **Partição METIS.** Com `pet_layout = 'split'`, o MPAS é decomposto em
> `atm_pet_count` partições, **não** em `-n`. Gere o
> `x1.*.graph.info.part.<atm_pet_count>` antes de submeter; o
> `run_esmApp.jaci` faz isso automaticamente no pré-check e informa de onde saiu
> o número.

> **Razão ATM:OCN.** O MPAS-A costuma dominar o custo por passo; uma razão
> inicial de 2:1 a 3:1 é um bom ponto de partida antes da primeira calibração.
> O `tools/coupler/analisa_balanceamento_pets.py` mede o custo de cada
> componente nos `logs/PET*.esmApp.log` e sugere a partição equilibrada.

> **Consolidação por nó (v14.19).** Ao rodar em vários nós, prefira
> `atm_pet_count` múltiplo de 256 e `ocn_pet_count` múltiplo de 128, para que
> cada componente ocupe nós inteiros (ver §8). O `tools/coupler/plan-layout.py`
> ajuda a escolher esses números. Desde a v14.20 o `select` heterogêneo é
> emitido para qualquer `pet_layout = 'split'`, e não só no modo concorrente.

#### Verificação

Dois *smoke tests* cobrem as combinações com split, ambos em `run/`:

```bash
bash run/test-concurrent.bash       -n 8 --atm 4 --ocn 4   # concurrent + split
bash run/test-sequential-split.bash -n 8 --atm 6 --ocn 2   # sequential + split
```

O segundo inclui a verificação que distingue os dois modos: as janelas `Run` de
ATM e OCN não podem se sobrepor no tempo. Como `sequential + split` e
`concurrent + split` produzem exatamente os mesmos conjuntos de PETs, só os
carimbos de tempo dos logs separam um do outro.


### 6.3 Nível de log ESMF (`log_kind` em `&nuopc_driver`)

Parâmetro introduzido na v14.17. Controla o detalhe dos arquivos
`logs/PET*.esmApp.log` sem recompilar:

```fortran
&nuopc_driver
  start_date = '2026-03-29'  stop_date = '2026-03-30'
  dt_coupling = 3600         dt_atm = 60
  log_kind    = 'multi'      ! 'multi' (padrão) | 'multi_on_error'
/
```

| `log_kind`       | Comportamento | Quando usar |
|:-----------------|:--------------|:------------|
| `multi` (padrão) | Grava todas as mensagens, inclusive INFO | Desenvolvimento e testes |
| `multi_on_error` | Log materializado só em caso de erro; arquivos menores, execução mais rápida | Produção já calibrada |

> **Atenção com `multi_on_error`.** Em execuções bem-sucedidas,
> `logs/PET*.esmApp.log` pode ficar incompleto ou ausente — o ESMF abre o arquivo
> apenas no momento do erro, quando o `chdir` de volta ao diretório do
> experimento já ocorreu.

---

## 7. Compilação e execução

**Alvos do `make`:**

```bash
make            # compila bin/esmApp (= make all)
make clean      # remove build/ bin/ e saídas soltas (*.stdout, log.atmosphere.*)
make distclean  # clean + remove *.pbs
make rebuild    # clean + all
make printenv   # variáveis e flags de compilação
make diagnose   # estado do build e objetos
make check      # confere a presença dos fontes
```

**Execução.** Rode o `run_esmApp.jaci` a partir da própria árvore do projeto — o
diretório de experimento é apenas o diretório atual (onde ficam `nuopc.input`,
namelists, malha e as saídas). Coloque `run/` no `PATH` uma vez e invoque de
qualquer experimento, sem copiar scripts nem o binário:

```bash
export PATH="$PATH:/…/MONAN-Coupler/run"     # uma vez (ex.: no ~/.bashrc)

cd /…/exp1                                    # entradas do run
run_esmApp.jaci -n 128                        # 128 PETs = 1 nó (½ dos cores)
run_esmApp.jaci -n 256                        # 256 PETs = 1 nó cheio
run_esmApp.jaci -n 512 -w 02:00:00            # 512 PETs = 2 nós × 256, 2 h
run_esmApp.jaci --compile -n 4                # make rebuild + qsub
run_esmApp.jaci --check                       # valida pré-requisitos
```

Como o `run_esmApp.jaci` funciona:

- **Detecção de ambiente** via `PBS_O_WORKDIR`: no login, gera o `.pbs` e faz
  `qsub`; dentro do job, carrega os módulos, faz `source` do `setenv` e lança o
  `mpiexec`.
- **Lançador:** o `mpiexec` do **Cray PALS**, resolvido por caminho explícito
  (`/opt/cray/pals/*`) para não depender da ordem do `PATH`.
- **Raiz do projeto:** `COUPLER_ROOT` é autodeduzido da localização do script e
  propagado ao job pelo `.pbs`; ao rodar de fora da árvore, sobrescreva com
  `export COUPLER_ROOT=…`.
- **Executável:** `${COUPLER_ROOT}/bin/esmApp` (sobrescrevível por `ESMAPP_BIN`);
  o diretório de experimento guarda apenas entradas e saídas.

A topologia de nós é derivada automaticamente de `-n` (ver §8). **Escalabilidade
validada:** 4 → 512 PETs (1 a 4 nós).

---

## 8. Multi-nó e particionamento MPI

### 8.1 Topologia multi-nó (v14.19)

A partir da v14.19 o `run_esmApp.jaci` gera a diretiva de recurso do PBS para
**um ou mais nós**, derivando a topologia de `-n` (antes fixava `select=1`, o que
limitava a execução a um único nó). O **modo PBS não muda**: o `mpiexec -n NPES`
do Cray PALS lê o `PBS_NODEFILE` (todos os nós do `select`) e distribui os
*ranks* pelos nós alocados.

**Hardware da Jaci** (confirmado por `lscpu`/`pbsnodes`): os nós de cálculo têm
**256 cores físicos** (2 sockets AMD EPYC Zen5 × 128) com **SMT ligado** (2
threads/core), expondo **512 CPUs lógicos**. O `pbsnodes` reporta
`resources_available.ncpus = 512`, contando os lógicos, mas o limite das filas
é dimensionado em **cores físicos** (`pesqextra`: 7680 `ncpus` para 30 nós, ou
seja 256 por nó). Por isso o `select` pede `ncpus = mpiprocs = PPN ≤ 256` e a
posse do nó inteiro vem de `place=scatter:excl`.

| Recurso        | Nó de cálculo                              |
|:---------------|:-------------------------------------------|
| Cores físicos  | 256 (2 sockets × 128, AMD EPYC Zen5)       |
| SMT            | ligado (2 threads/core) → 512 CPUs lógicos |
| `ncpus` do nó  | 512 (lógicos); limite das filas em 256 (físicos) |
| Memória        | ~754 GB (~2,95 GB por core físico)         |

Há ainda 10 nós auxiliares (`aux01`-`aux10`) com `ncpus = 256` e **~1,5 TB**,
na fila `aux` (`worktype=aux`), destinados a pré e pós-processamento, não ao
acoplado. **Atenção:** como o nó anuncia threads, dimensione os
PETs pelos **cores físicos** (limite de 256/nó) e fixe 1 rank por core no lançador
(o `mpiexec` do PALS aceita opções de *bind*); acima de 256 PET/nó cai em SMT
(2 ranks por core), o que prejudica MPAS/MOM6.

A diretiva de recurso é montada assim:

```
NNODES = NPES / PPN, arredondado para cima
#PBS -l select=NNODES:ncpus=PPN:mpiprocs=PPN     (sem 'mem' por padrão)
#PBS -l place=scatter:excl
```

O **padrão é 256 PET/nó**, ou seja, o **nó físico cheio** (1 rank por core
físico, sem SMT). O script **não** reserva memória por padrão: o nó fornece a sua
RAM, e a memória por PET é apenas RAM_do_nó ÷ PET/nó, não um requisito assumido
(não há um limite de memória conhecido do MOM6+SIS2). Em caso de OOM
(`exit 137/143`), reduza os PETs por nó com `--ppn` (mais RAM/PET, à custa de
mais nós) ou reserve memória com `--mem`.

**Opções de topologia** (além de `-n`, `-q`, `-w`, `--compile`, `--check`):

| Opção               | Padrão    | Efeito                                    |
|:--------------------|:---------:|:------------------------------------------|
| `-p, --ppn N`       | 256       | PET/nó (`0` = auto, preenche até 256)     |
| `--place MODO`      | scatter:excl | `scatter:excl` \| `scatter` \| `pack`  |
| `--mem TAM`         | (sem)     | reserva FIXA de memória por nó (ex.: `700gb`) |
| `--mem-per-pet N`   | 0         | reserva OPCIONAL por PET (0 = desligada)  |
| `--no-mem`          | (padrão)  | garante sem reserva de memória            |
| `--ppn-atm N`       | 0 (→256)  | limite de PET/nó do ATM (concurrent)        |
| `--ppn-ocn N`       | 0 (→256)  | limite de PET/nó do OCN (concurrent)        |
| `--mem-per-pet-atm` | 0         | reserva opcional por PET do ATM (concurrent) |
| `--pet-order`       | atm-first | ordem dos blocos ATM/OCN (concurrent)     |

```bash
run_esmApp.jaci -n 512                        # 2 nós × 256 (sequential)
run_esmApp.jaci -n 512 --ppn 128              # 4 nós × 128 (mais RAM/PET)
run_esmApp.jaci -n 512 --place scatter        # permite nó compartilhado
run_esmApp.jaci -n 256 --mem 700gb            # reserva fixa por nó
```

### 8.2 Modo concorrente — consolidação por componente (v14.19)

Desde a v14.17 o `run_esmApp.jaci` é **ciente do layout**: em `concurrent` valida
`atm_pet_count + ocn_pet_count == -n`, gera a partição METIS correta
(`.part.<atm_pet_count>`) e aborta com mensagem clara se a soma não bater.

A v14.19 acrescenta a **consolidação por componente**: quando `atm_pet_count` e
`ocn_pet_count` estão explícitos, o `.pbs` recebe um `select` **heterogêneo** que
aloca **nós separados** para cada componente — nenhum nó fica "misto" (ATM+OCN),
o que melhora a localidade e o *binding*. Por padrão, ambos os componentes ocupam
nós cheios (256); se o OCN estourar a memória, reduza o seu limite com `--ppn-ocn`.
A ordem dos blocos segue `--pet-order` (padrão `atm-first`), pois o PALS preenche
o `PBS_NODEFILE` na ordem do `select`.

```
             nó misto (ruim)              consolidado por componente (bom)
             ┌──────────┐ ┌──────────┐    ┌──────────┐ ┌──────────┐ ┌──────────┐
  concurrent │ ATM +    │ │ ATM +    │    │ 256 ATM  │ │ 256 ATM  │ │ 128 OCN  │
  atm=512    │  OCN mix │ │  OCN mix │    │(nó cheio)│ │(nó cheio)│ │          │
  ocn=128    └──────────┘ └──────────┘    └──────────┘ └──────────┘ └──────────┘

  select = 2:ncpus=256:mpiprocs=256  +  1:ncpus=128:mpiprocs=128
           └──────── bloco ATM ─────┘     └──── bloco OCN ─────┘
```

```bash
run_esmApp.jaci -n 384 --check                # mostra a topologia e o select
run_esmApp.jaci -n 384                         # valida, gera METIS e faz qsub
run_esmApp.jaci -n 384 --pet-order ocn-first   # inverte a ordem dos blocos
```

O PET/nó de cada componente é o **maior divisor** do respectivo *count* que caiba
no limite (`--ppn-atm` e `--ppn-ocn`, ambos 256 por padrão). Por isso convém que
cada *count* caiba em um nó (≤ 256) ou seja múltiplo de 256; *counts* maiores que
256 e não múltiplos forçam blocos tortos (ex.: `2×192`).

### 8.3 Planejador de topologia — `plan-layout.py` (v14.19)

Reproduz, **fora do job**, a mesma lógica de consolidação do `run_esmApp.jaci`,
para escolher os *counts* **antes** de editar a `nuopc.input`. Imprime nós,
PET/nó, memória por nó e o `select` resultante (idêntico ao do job), sinalizando
combinações que desperdiçam núcleos (`quebrado`) ou que só cabem nos nós de alta
memória, ~1,5 TB (`mem>nó padrão`).

**Limites por fila** (`qstat -Qf`, 2026-08), conferidos pelo script antes do
`qsub`: `pesqextra` 7680 PETs / 30 nós / 08:00:00 (padrão); `pesqhigh` 5120 / 20 /
06:00:00; `pesqmidi` 1792 / 7 / 02:00:00; `pesqmini` 1792 / 7 / 00:30:00;
`longtime` 2048 / 8 / 168:00:00; `aux` 256 / 1 / 24:00:00. As constantes
`QUEUE_LIMITS_*` ficam no topo do `run_esmApp.jaci`.

```bash
python3 tools/coupler/plan-layout.py --atm 256 --ocn 128      # layout de um par ATM/OCN
python3 tools/coupler/plan-layout.py --total 384 --ratio 2:1  # divide um total por razão
python3 tools/coupler/plan-layout.py --sweep 384 1536 --step 384 --ratio 2:1   # tabela
python3 tools/coupler/plan-layout.py --suggest --atm 250 --ocn 130  # counts "limpos"
python3 tools/coupler/plan-layout.py --sequential --npes 512 --ppn 128
```

Exemplo de saída (`--sweep`):

```text
  NPES   atm   ocn | bloco ATM            bloco OCN            |  nós | status
   384   256   128 | 1x256                1x128                |    2 | OK
   768   512   256 | 2x256                1x256                |    3 | OK
  1152   768   384 | 3x256                2x192                |    5 | quebrado
  1536  1024   512 | 4x256                2x256                |    6 | OK
```

> **Fluxo recomendado:** **planejar** (`plan-layout.py`) → **configurar**
> (`atm_pet_count` / `ocn_pet_count` na `nuopc.input`) → **verificar**
> (`run_esmApp.jaci -n … --check`) → **submeter**.

### 8.4 Partições METIS do MPAS (`gen-metis.bash`)

O MPAS decompõe a malha pelo METIS e lê `x1.NNNNN.graph.info.part.N`, onde **N é
o número de tarefas MPI no comunicador do MPAS** — não o total do job.

| Modo         | Arquivo de partição necessário             |
|:-------------|:-------------------------------------------|
| `sequential` | `x1.NNNNN.graph.info.part.<NPES>`          |
| `concurrent` | `x1.NNNNN.graph.info.part.<atm_pet_count>` |

O `run/gen-metis.bash` gera as partições lendo malha e modo diretamente da
`nuopc.input`; o `run_esmApp.jaci` o chama automaticamente quando a partição
necessária não existe.

```bash
cd /…/exp1
gen-metis.bash -n 128                  # gera a partição para o -n informado
gen-metis.bash --parts "128 88 64"     # gera exatamente esses valores de N
gen-metis.bash -n 128 --dry-run        # mostra o que faria, sem executar
```

### 8.5 Decomposição de domínio do MOM6/SIS2

`LAYOUT = NIPROC, NJPROC` em `MOM_input` e `SIS_input` deve satisfazer
`NIPROC × NJPROC == ocn_pet_count` — o número de PETs do **componente OCN**, não
o total do job. O FMS aceita silenciosamente um `LAYOUT` inconsistente com o
comunicador, mas o erro estoura quando `MASKTABLE` está ativo:

```
FATAL: MPP_DEFINE_DOMAINS2D: incorrect number of PEs assigned
       for this layout and maskmap.
```

Referência rápida:

| `ocn_pet_count` | `LAYOUT` em `MOM_input` e `SIS_input` |
|:---------------:|:--------------------------------------|
| 4               | `LAYOUT = 2, 2`                       |
| 16              | `LAYOUT = 4, 4`                       |
| 32              | `LAYOUT = 4, 8`                       |
| 64              | `LAYOUT = 8, 8`                       |
| 128             | `LAYOUT = 8, 16`                      |

> **Atenção ao `MOM_override` / `SIS_override`** no diretório do experimento (fora
> deste repositório): se contiverem `MASKTABLE` apontando para um arquivo de outro
> layout, o erro acima ocorrerá. Comente o `MASKTABLE` nesses arquivos toda vez
> que `ocn_pet_count` mudar.

---

## 9. Saídas e pós-processamento

| Diretório / arquivo              | Conteúdo                                 |
|:---------------------------------|:-----------------------------------------|
| `bin/esmApp`                     | Executável                               |
| `logs/PET*.esmApp.log`           | Logs ESMF por PET                        |
| `diag_export/monan_export_*.nc`  | Campos ATM exportados                    |
| `diag_import/mom6_import_*.nc`   | Fluxos bulk MED→OCN                      |
| `diag_import/monan2_import_*.nc` | Campos OCN→ATM importados pelo MPAS      |
| `diag_import/docn_import_*.nc`   | SST/gelo interpolados pelo DOCN (Fase 1) |
| `diag_import/sst_ifrac_diag/`    | Evolução temporal de SST e Si_ifrac      |

Scripts Python em `tools/` (rode com `--help` para as opções):

```bash
python3 tools/postproc/postproc_monan2_export.py     # campos ATM exportados
python3 tools/postproc/postproc_monan2_import.py     # fluxos bulk MED→OCN
python3 tools/postproc/postproc_mom6_import.py       # campos importados pelo MOM6
python3 tools/postproc/analisa_comparacao.py         # comparação entre experimentos
python3 tools/postproc/analisa_sst_ifrac.py          # evolução de SST/Si_ifrac
python3 tools/animation/anim_monan2_import.py        # animações
```

> O `write_import_diag=.true.` gera ~1,7 MB/passo (grade OISST 1440×720,
> ≈ 41 MB/dia com `dt_coupling=3600 s`). Desative em produção longa.

---

## 10. Módulos Fortran

Padrão de nomeação `<stem>_mod` (ex.: `mpas_cap_MONAN.F90` →
`mpas_cap_MONAN_mod`), exceto `esmApp.F90` (programa) e `MOM_cap_mod` (convenção
do MOM6). Os fontes em `src/caps/ocean/upstream/` pertencem à biblioteca MOM6 e
**não** são compilados por este Makefile.

<details>
<summary><strong>Tabela completa de módulos</strong> (clique para expandir)</summary>

**Driver e aplicação**

| Arquivo      | Módulo       | Descrição                    |
|:-------------|:-------------|:-----------------------------|
| `esmApp.F90` | *(programa)* | Entrada; relógio ESMF global |
| `esm.F90`    | `ESM_MONAN`  | Driver NUOPC; sequência de execução; particionamento de PETs por componente |

**Cap atmosférico — `src/caps/atmos/`**

| Arquivo                 | Descrição                           |
|:------------------------|:------------------------------------|
| `mpas_cap_MONAN.F90`    | Cap NUOPC para MONAN-A 2.0 / MPAS   |
| `mpas_cap_methods.F90`  | Importa/exporta campos ESMF ↔ MPAS  |
| `mpas_cap_netcdf.F90`   | Diagnósticos NetCDF export/import   |
| `mpas_cap_config.F90`   | Leitura do `nuopc.input` (`&nuopc_driver`, `&nuopc_petlayout`, `&nuopc_mode` e demais grupos) |
| `mpas_cap_utils.F90`    | `ChkErr`, log ESMF, utilitários     |
| `mpas_atm_types.F90`    | Tipos do estado atmosférico         |
| `mpas_atm_model.F90`    | Inicializa e avança o MONAN-A; replica a sequência de `mpas_subdriver.F` (ver §11) |
| `mpas_atm_wrappers.F90` | Interface com internos do MPAS      |
| `DATM_cap.F90`          | Cap ATM por dados (JRA55 sintético) |

**Mediador — `src/mediator/`**

| Arquivo               | Descrição                                   |
|:----------------------|:--------------------------------------------|
| `MED_cap.F90`         | Orquestrador NUOPC (ciclo de vida)          |
| `med_cap_types.F90`   | Tipos, constantes físicas, listas de campos |
| `med_bulk_ncar.F90`   | Bulk NCAR + rugosidade Charnock/Smith       |
| `med_cap_methods.F90` | Regrid, campos, `RouteOcnToAtm`             |
| `med_cap_netcdf.F90`  | Diagnóstico NetCDF MED→OCN                  |

**Cap oceânico — `src/caps/ocean/`**

| Arquivo               | Descrição                         |
|:----------------------|:----------------------------------|
| `mom_cap_MONAN.F90`   | Cap NUOPC para MOM6+SIS2 dinâmico |
| `ocn_comp_NUOPC.F90`  | Módulo ponte (não compilado)      |
| `DOCN_cap.F90`        | Cap OCN por dados OISST (Fase 1)  |
| `docn_cap_netcdf.F90` | I/O NetCDF do DOCN                |

**Compartilhados — `src/shared/`**

| Arquivo                      | Descrição                                   |
|:-----------------------------|:--------------------------------------------|
| `mpi_allreduce_r8.F90`       | `MPI_Allreduce` `real(8)` — isolado (W1)    |
| `mpi_allreduce_i4.F90`       | `MPI_Allreduce` `integer(4)` — isolado (W1) |
| `mpi_allreduce_wrappers.F90` | Re-exporta as variantes tipadas             |
| `time_utils.F90`             | Conversão de tempo FMS ↔ ESMF               |

`real(8)` e `integer(4)` ficam em arquivos separados porque o gfortran/`ftn`
emite aviso espúrio de incompatibilidade quando ambos os tipos do mesmo símbolo
externo aparecem no mesmo arquivo (não suprimível por `-Wno-argument-mismatch`).

</details>

---

## 11. Réplica da inicialização do MPAS

O cap atmosférico **não** usa o `mpas_init` de
`models/atmos/MONAN-Model/src/driver/mpas_subdriver.F`. Aquela rotina é
monolítica — inicializa, roda até o fim e finaliza —, o que é incompatível com o
ciclo de vida NUOPC, em que o driver controla o avanço passo a passo. Por isso o
`mpas_atm_model.F90` **replica à mão** a sequência de inicialização:

```
phase1 → atm_setup_core → atm_setup_domain → setup_log → setup_namelist →
phase2 → streamInfo → define_packages → setup_packages → setup_decompositions →
setup_clock → bootstrap_phase1 → stream_mgr_init → add_stream_attributes →
setup_immutable_streams → xml_stream_parser → bootstrap_phase2 → core_init →
extração de ponteiros zero-copy
```

> **Dívida técnica.** Se o `mpas_subdriver.F` mudar em uma versão futura do
> MONAN-Model, a réplica não acompanha e **nada avisa** — não há erro de
> compilação nem de execução, apenas divergência silenciosa em relação ao
> *standalone*.

Isso já aconteceu uma vez: a chamada `add_stream_attributes` estava ausente da
réplica, e as saídas do acoplado (`diag`, `history`, `restart`) eram gravadas com
um único atributo global, `file_id` — sem `sphere_radius`, `on_a_sphere` ou
qualquer `config_*`. Nada falhava; o sintoma só apareceu no pós-processamento. A
correção (v14.18) é a rotina local `atm_add_stream_attributes` (cópia fiel do
*upstream*, com bloco de manutenção no cabeçalho).

### 11.1 Ao atualizar o submódulo `models/atmos/MONAN-Model`

Confira o diff do driver antes de compilar:

```bash
cd models/atmos/MONAN-Model
git diff <tag-anterior>..<tag-nova> -- src/driver/mpas_subdriver.F
```

Se houver mudança na sequência de `mpas_init` ou no corpo de
`add_stream_attributes`, replique-a em `src/caps/atmos/mpas_atm_model.F90`.

### 11.2 Teste de regressão dos atributos globais

Compare uma saída do acoplado com uma do MONAN-A *standalone* rodado com o mesmo
namelist e a mesma malha:

```bash
ATTR() { ncdump -h "$1" | sed -n '/^\/\/ global attributes/,$p' \
         | sed 's/^[[:space:]]*//' | sort; }

diff <(ATTR <saida-standalone>/MONAN_DIAG_*.nc) \
     <(ATTR <saida-acoplado>/MONAN_DIAG_*.nc)
```

Diferenças legítimas, e **apenas** estas:

| Atributo    | Por que difere                                                   |
|:------------|:-----------------------------------------------------------------|
| `file_id`   | identificador aleatório gerado por arquivo em `mpas_io_streams.F` |
| `history`   | no acoplado reporta `domain%dminfo%nProcs` (os PETs do componente ATM, não o total do job) |
| `parent_id` | encadeamento do pré-processamento                                |
| `config_*`  | apenas os efetivamente alterados no namelist do acoplado         |

Qualquer outra diferença indica divergência em relação ao *upstream*. Verificação
rápida da contagem: `ncdump -h … | sed -n '/global attributes/,$p' | wc -l` deve
ficar em torno de 170, não em 3.

---

## 12. Histórico de versões

| Versão | Data     | Mudanças                                                   |
|:-------|:---------|:-----------------------------------------------------------|
| 14.21  | Ago 2026 | **Efeito do SMT medido.** Novo `--allow-smt` no `run_esmApp.jaci`, que separa `PPN_PHYS=256` (cores físicos, limite recomendado e padrão) de `PPN_HARD=512` (CPUs lógicas, limite do hardware), e nova linha `REGIME` no resumo de topologia. Novo `mede_smt.py`, que compara as duas configurações a partir dos logs de PET, normalizando pelo número de nós. Medição de 06/08/2026 com 512 PETs e três repetições: em *wall-clock time* A é **2,22x mais rápido**; em custo de máquina o SMT **degrada 11,2%** (incerteza de 7,7%), com sinais opostos por componente, MED 0,97 e OCN 0,86 contra MPAS 1,20. O padrão de 256 PET/nó fica confirmado por medição |
| 14.20  | Ago 2026 | Contabilidade de `ncpus` confirmada por `qstat -Qf`: o limite das filas é em **cores físicos** (`pesqextra` 7680/30 = 256 por nó), então o `select` mantém `ncpus = mpiprocs ≤ 256` e a posse do nó inteiro passa a vir de **`place=scatter:excl`, agora o padrão**. Nova **guarda de fila** (`QUEUE_LIMITS_*` + `_queue_guard`): NPES, nós e *walltime* são conferidos contra `resources_max` antes do `qsub`. Nós `aux01`-`aux10` (256 `ncpus`, ~1,5 TB, fila `aux`) documentados como destino de pré e pós-processamento |
| 14.19  | Jul 2026 | Execução **multi-nó** no `run_esmApp.jaci`: `select` derivado de `-n` (`NNODES × PPN`, `place=scatter`), padrão 256 PET/nó (nó físico cheio, 1 rank/core) e **sem reserva de memória** por padrão (`--mem`/`--mem-per-pet` são opt-in). Modo concurrent com **consolidação por componente** (`select` heterogêneo: um componente por nó; `--ppn-atm`, `--ppn-ocn`, `--pet-order`). Novo `tools/coupler/plan-layout.py` (planejador de topologia) |
| 14.18  | Jul 2026 | Correção: atributos globais ausentes nas saídas do MONAN-A acoplado (`diag`/`history`/`restart` saíam só com `file_id`). `mpas_atm_model.F90` v5.2 acrescenta `atm_add_stream_attributes`, réplica de `add_stream_attributes` de `mpas_subdriver.F`, chamada entre `stream_mgr_init` e `setup_immutable_streams` |
| 14.17  | Jul 2026 | Particionamento MPI sequencial/concorrente: `&nuopc_petlayout` (`coupling_mode`, `atm_pet_count`, `ocn_pet_count`); `log_kind` em `&nuopc_driver`; `run/gen-metis.bash` (partições METIS por modo); `run_esmApp.jaci` ciente do layout (valida soma, gera `.part.<atm_pet_count>`) |
| 14.16  | Jun 2026 | `Coupler-Install`: passos renomeados (`1-monan`/`2-mom`/`3-coupler`); `docs/`, `sites/site-template.bash`, `Makefile` de atalhos |
| 14.15  | Jun 2026 | Instalador renomeado para `Coupler-Install`; config de sítio em `run/setenv-site.bash` (remove `install/` do acoplador) |
| 14.14  | Jun 2026 | Instalador: `bootstrap`→`install.bash`, `install-all`→`build.bash`; layout `sites/`+`templates/` |
| 14.13  | Jun 2026 | Instalador em repo próprio; modelos como submódulos; `install.bash` (clone recursivo + install) |
| 14.12  | Jun 2026 | Layout multi-modelo: fontes em `models/atmos` e `models/ocean` |
| 14.11  | Jun 2026 | Execução relocável: `COUPLER_ROOT`, run via `PATH`, sem cópias |
| 14.10  | Jun 2026 | Configuração de sítio centralizada em `site-jaci.bash`     |
| 14.9   | Jun 2026 | Download automático de MONAN-Model e MOM6-examples         |
| 14.8   | Jun 2026 | Pipeline `install-all`; ESMF via `esmf.mk`; MOAB interno   |
| 14.7   | Jun 2026 | Layout do MONAN-A em `mod/monan2` e `lib/monan2`           |
| 14.2   | Mai 2026 | `analisa_sst_ifrac.py`: série, anomalia e métricas         |
| 14.1   | Mai 2026 | Reorganização de diretórios (`src/shared`, `tools`, `run`) |
| 14.0   | Mai 2026 | `MED_cap.F90` dividido em 5 módulos (−42%)                 |

<details>
<summary><strong>Versões anteriores</strong> (clique para expandir)</summary>

| Versão | Data     | Mudanças                                             |
|:-------|:---------|:-----------------------------------------------------|
| 13.0   | Mai 2026 | `mom_cap_MONAN.o` em `ALL_OBJS`; fix linker MOM6     |
| 12.0   | Mai 2026 | `mpi_allreduce_wrappers` isolado (fix W1 gfortran)   |
| 11.0   | Mai 2026 | `mom_cap_MONAN.F90` movido para `src/caps/atmos/`    |
| 9.3    | Mai 2026 | Makefile reestruturado; `DOCN_cap` realocado         |
| 9.0    | Abr 2026 | OCN DOCN → MOM6+SIS2 dinâmico; `stop_ymd` automático |
| 7.2    | Abr 2026 | Fix double-free `ownedElemCoords` (ESMF 8.9.1)       |
| 7.0    | Abr 2026 | `stop_ymd`/`stop_tod` via `NUOPC_CompAttributeSet`   |
| 6.0    | Mar 2026 | Mediador bulk NCAR; Large & Yeager (2009)            |

</details>

---

## 13. Referências

- **ESMF/NUOPC** — <https://earthsystemmodeling.org>
- **MPAS-A** — Skamarock et al. (2021), *NCAR/TN-556+STR*.
- **MOM6** — Adcroft et al. (2019), *JAMES* 11(10), 3167–3211. <https://doi.org/10.1029/2019MS001726>
- **Bulk NCAR** — Large & Yeager (2009), *Clim. Dyn.* 33(2–3), 341–364.
- **Rugosidade** — Smith (1988), *J. Geophys. Res.* 93(C12).
- **OISST v2.1** — Huang et al. (2021), *J. Climate* 34(8), 2923–2939.
- **Projeto MONAN** — <https://monanadmin.github.io/monan-cc-docs/>

---

**GT Acoplamento de Modelos — INPE/CGCT/DIMNT**
Rodovia Presidente Dutra, Km 40 — Cachoeira Paulista, SP
