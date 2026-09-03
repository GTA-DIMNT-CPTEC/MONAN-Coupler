# MONAN-A 2.0 × MOM6+SIS2 — Sistema Acoplado NUOPC/ESMF

> **INPE / CGCT / DIMNT — GT Acoplamento de Modelos**
> v14.22 · ESMF/NUOPC 8.9.1 · MPAS-A 8.3.1 · MOM6+SIS2 · Agosto 2026
>
> Instalação: [`Coupler-Install`](https://github.com/GTA-DIMNT-CPTEC/Coupler-Install) · Documentação: [`docs/`](docs/)

Acoplador atmosfera–oceano–gelo de **produção**: o **MONAN-A 2.0** (MPAS-A, malha
Voronoi hexagonal) acoplado ao **MOM6+SIS2** (grade tripolar) pelo framework
**NUOPC/ESMF 8.9.1**, no supercomputador **Jaci** (Cray XD 2000, PrgEnv-gnu). Um
mediador próprio calcula os fluxos turbulentos ar–mar por fórmulas *bulk* NCAR
(Large & Yeager, 2009).

O detalhamento de cada tópico está em [`docs/`](docs/); este README cobre a
arquitetura, a instalação e o uso do dia a dia.

---

## Sumário

1. [Arquitetura](#1-arquitetura)
2. [Início rápido](#2-início-rápido)
3. [Instalação](#3-instalação)
4. [Estrutura do repositório](#4-estrutura-do-repositório)
5. [Dependências](#5-dependências)
6. [Configuração do acoplamento](#6-configuração-do-acoplamento)
7. [Compilação e execução](#7-compilação-e-execução)
8. [Saídas e pós-processamento](#8-saídas-e-pós-processamento)
9. [Documentação](#9-documentação)
10. [Histórico de versões](#10-histórico-de-versões)
11. [Referências e contato](#11-referências-e-contato)

---

## 1. Arquitetura

Quatro componentes NUOPC — atmosfera (ATM), mediador (MED), oceano (OCN) e gelo
marinho (ICE) — são orquestrados por um driver único, sob um relógio ESMF global.
O componente de gelo é **opcional**: só é criado com `use_sis2_dynamic = .true.`;
sem ele, o sistema opera com três componentes e a fração de gelo vem da fórmula
aproximada do oceano.

```text
        ┌────────────────────────────────────┐
        │   esmApp.F90 — programa principal   │
        └─────────────────┬──────────────────┘
        ┌─────────────────▼──────────────────┐
        │        esm.F90 — Driver NUOPC       │
        │     relógio · PETs · ATM/MED/OCN    │
        └───┬────────────┬────────────┬────────────┬┘
            │            │            │            │
     ┌──────▼────┐ ┌─────▼─────┐ ┌────▼─────┐ ┌────▼─────┐
     │    ATM    │ │    MED    │ │   OCN    │ │   ICE    │
     │  MONAN-A  │ │ bulk NCAR │ │   MOM6   │ │   SIS2   │
     │   (MPAS)  │ │(mediador) │ │(dinâmico)│ │(opcional)│
     └──────┬────┘ └─────┬─────┘ └────┬─────┘ └────┬─────┘
            └────────────┴────────────┴────────────┘
                     Conectores NUOPC
```

**Fluxo de acoplamento por passo** (MOM6 dinâmico ativo):

| Passo | Conector  | Campos / ação                                        |
|------:|:----------|:-----------------------------------------------------|
|     1 | OCN → MED | `So_t`, `So_u`, `So_v`, `Si_ifrac`                   |
|     2 | ATM → MED | `u10m`, `v10m`, `tbot`, `qbot`, `pbot`, … (9 campos) |
|     3 | MED       | *bulk* NCAR → 14 fluxos                              |
|     4 | MED → OCN | forçantes do MOM6 (`Foxx_*` / `Faxa_*`)             |
|     5 | OCN       | `step_MOM`: avança o MOM6 por `dt_coupling`          |
|     6 | MED → ATM | `So_t`, `Si_ifrac`, `So_u`, `So_v`, `Sf_zorl` → MPAS |
|     7 | ATM       | dinâmica + física (N × `dt_atm`)                     |

Com `use_sis2_dynamic = .true.`, a sequência ganha dois conectores e um avanço,
todos condicionados ao gelo estar ativo (em ordem de execução):

| Conector  | Campos / ação                                                       |
|:----------|:--------------------------------------------------------------------|
| MED → ICE | forçante atmosférica processada + SST e correntes do oceano         |
| ICE       | avança o SIS2 por `dt_coupling`                                      |
| ICE → MED | `Si_ifrac_sis2`: fração de gelo real, que substitui a estimativa do oceano |

> **Prefixos dos campos.** `So_*` oceano · `Si_*` gelo marinho · `Sf_*`
> superfície · `Foxx_*` / `Faxa_*` fluxos.

Cada componente e conector recebe uma **cópia** do relógio do driver (via
`ESMF_ClockCreate`), não o objeto compartilhado — detalhe cuja ausência fazia o
NUOPC avançar o mesmo relógio uma vez por componente.

---

## 2. Início rápido

Este repositório (`MONAN-Coupler`) traz o **MONAN-Model** e o **MOM6-examples**
como submódulos (em `models/atmos/` e `models/ocean/`). Os scripts de instalação
vivem em repositório separado, o [`Coupler-Install`](https://github.com/GTA-DIMNT-CPTEC/Coupler-Install),
que baixa e compila tudo em um comando.

**Pré-requisito:** ESMF 8.9.1 já instalado (com MOAB interno), localizado por
`run/setenv-gnu.bash`.

**Instalação (um comando):**

```bash
git clone --branch develop https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash            # clona o sistema (recursivo, develop) e instala
```

**Rotina de cada sessão de trabalho** (na raiz do sistema acoplado):

```bash
source run/setenv-gnu.bash             # define ESMFMKFILE, MPAS_DIR, MOM6_ROOT…
make                                   # (re)compila bin/esmApp
bash run/run_esmApp.jaci -n 128        # submete via PBS (128 PETs)
```

---

## 3. Instalação

Os scripts de instalação residem no `Coupler-Install`, separado do sistema
acoplado. A raiz do sistema é informada pela variável **`COUPLER_ROOT`** (definida
e exportada pelo `install.bash`; ao rodar um instalador isolado, exporte-a ou use
`--coupler-root DIR`).

| Script            | Etapa | Finalidade                                    |
|:------------------|:-----:|:----------------------------------------------|
| `install.bash`    |   0   | Baixa o sistema (git recursivo) **e** instala |
| `build.bash`      |   —   | Só as 3 etapas (assume o sistema já baixado)  |
| `1-monan.bash`    |   1   | MONAN-A 2.0 → `lib/monan2`, `mod/monan2`      |
| `2-mom.bash`      |   2   | MOM6+SIS2+FMS → `lib/{fms,mom6,nuopc}`        |
| `3-coupler.bash`  |   3   | Compila e linka `bin/esmApp`                  |

**Opções úteis:** `install.bash --no-install` (só baixa), `build.bash --from N`
(retoma na etapa N). Atalhos via `make` no `Coupler-Install`: `make`,
`make download`, `make build FROM=N`, `make check`, `make help`.

### Configuração de sítio (`sites/site-jaci.bash`)

É o **único arquivo a editar** ao trocar de usuário, máquina ou versões de módulo.
Centraliza caminho do ESMF, listas de módulos, alvo de CPU, paralelismo
(`MAKE_JOBS`) e wrappers do compilador. Três formas de uso:

- **Jaci (padrão):** nada a fazer — os valores já estão corretos.
- **Ajuste pontual:** exporte a variável antes de instalar (tem prioridade sobre
  o padrão do sítio), p.ex. `export MAKE_JOBS=16`.
- **Outra máquina:** copie `sites/site-jaci.bash`, ajuste os valores e aponte
  `export SITE_ENV="$PWD/sites/site-meuhost.bash"` antes de `bash install.bash`.

> **ESMF e MOAB.** O MOAB é interno ao `libesmf` (sem `-lMOAB` externo). Para um
> ESMF com MOAB externo, defina `USE_EXTERNAL_MOAB=yes` e `MOAB_DIR`.

---

## 4. Estrutura do repositório

```text
MONAN-Coupler/                ← sistema acoplado (branch develop)
├── Makefile                  ← build do acoplador (bin/esmApp)
├── nuopc.input               ← namelist de acoplamento
├── src/
│   ├── main/esmApp.F90       ← ponto de entrada
│   ├── driver/esm.F90        ← driver NUOPC
│   ├── mediator/             ← MED (bulk NCAR)
│   ├── caps/atmos/           ← cap MONAN-A (MPAS) + DATM
│   ├── caps/ocean/           ← cap MOM6 + DOCN
│   ├── caps/ice/             ← cap SIS2 (opcional)
│   └── shared/               ← utilitários (MPI, tempo)
├── models/                   ← submódulos das fontes dos modelos
│   ├── atmos/MONAN-Model/    ← MONAN-A 2.0 (MPAS-A 8.3.1)
│   └── ocean/MOM6-examples/  ← MOM6+SIS2+FMS
├── docs/                     ← documentação do sistema acoplado
├── tools/
│   ├── atmos/                ← gen-metis.bash (partições METIS)
│   ├── ocean/                ← domain-mom6.bash (LAYOUT + mask_table)
│   ├── coupler/              ← plan-layout.py, smoke tests, balanceamento
│   ├── postproc/             ← pós-processamento (Python)
│   └── animation/            ← animações (Python)
├── run/
│   ├── setenv-gnu.bash       ← ambiente de compilação (Jaci/GNU)
│   ├── setenv-site.bash      ← config de sítio (cópia do install.bash)
│   └── run_esmApp.jaci       ← submissão PBS multinó
├── mod/  lib/                ← módulos .mod e libs .a (gerados na instalação)
└── diag_export/  diag_import/ ← saídas de diagnóstico NetCDF
```

O repositório do instalador (`Coupler-Install`) contém apenas os scripts de
instalação, a configuração por sítio (`sites/`) e os templates de build
(`templates/`).

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
bibliotecas do MONAN-A em `lib/monan2`.

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

> `use_med_to_mpas=.true.` é obrigatório quando `use_docn=.false.`: sem ele o
> MPAS não recebe SST/gelo.

**Exemplo — 24 h com MOM6 dinâmico:**

```fortran
&nuopc_driver
  start_date = '2026-03-29'  stop_date = '2026-03-30'
  dt_coupling = 3600         dt_atm = 60          ! [s]
/
&nuopc_mode
  use_datm = .false.  use_docn = .false.  use_med_to_mpas = .true.
/
```

### 6.2 Particionamento MPI (`&nuopc_petlayout`)

Controla, em tempo de execução, como os *ranks* MPI se distribuem entre os
componentes e a ordem em que avançam — sem recompilar. São **dois eixos
ortogonais**:

| Eixo | Chave | Valores | O que decide |
|:-----|:------|:--------|:-------------|
| Temporal | `coupling_mode` | `sequential` (padrão) \| `concurrent` | ATM e OCN avançam em série ou ao mesmo tempo |
| Espacial | `pet_layout` | `shared` (padrão) \| `split` | ATM e OCN nos mesmos PETs ou em blocos disjuntos |

Combinações válidas: `sequential+shared` (baseline e testes), `sequential+split`
(decomposições muito diferentes, sem defasagem), `concurrent+split` (produção em
escala). A combinação `concurrent+shared` é **rejeitada** pelo driver.

Opções do grupo (as contagens de PET só valem com `pet_layout = 'split'`):

| Chave              | Padrão       | Descrição                                                        |
|:-------------------|:-------------|:-----------------------------------------------------------------|
| `coupling_mode`    | `sequential` | Eixo temporal: `sequential` \| `concurrent`                      |
| `pet_layout`       | `shared`     | Eixo espacial: `shared` \| `split`                               |
| `atm_pet_count`    | `0`          | PETs do MPAS (`0` = auto: `ceil(N/2)`)                           |
| `ocn_pet_count`    | `0`          | PETs do MOM6 (`0` = auto: `N − atm`)                             |
| `use_sis2_dynamic` | `.false.`    | Ativa o componente de gelo (SIS2); exige `use_docn = .false.`     |
| `ice_pet_count`    | `0`          | PETs do SIS2; em `split` com gelo precisa ser **explícito**       |

Em `split`, a soma das contagens de PET deve igualar o `-n` do job:
`atm_pet_count + ocn_pet_count` (sem gelo) ou `+ ice_pet_count` (com gelo). O gelo
dinâmico segue os **mesmos dois eixos**: em `split` são três blocos disjuntos
(ATM | OCN | ICE); em `shared` o ICE ocupa todos os PETs junto com ATM, OCN e MED.
Definir `ice_pet_count > 0` sem `use_sis2_dynamic` é **erro**, não descarte
silencioso.

**Exemplo — produção concorrente, 128 PETs (ATM 88 / OCN 40):**

```fortran
&nuopc_petlayout
  coupling_mode = 'concurrent'
  pet_layout    = 'split'
  atm_pet_count = 88     ! MPAS  → PET 0..87
  ocn_pet_count = 40     ! MOM6  → PET 88..127
/
```

**Exemplo — concorrente com gelo, 8 PETs (ATM 4 / OCN 2 / ICE 2):**

```fortran
&nuopc_petlayout
  coupling_mode    = 'concurrent'
  pet_layout       = 'split'
  atm_pet_count    = 4        ! MPAS → PET 0..3
  ocn_pet_count    = 2        ! MOM6 → PET 4..5
  use_sis2_dynamic = .true.
  ice_pet_count    = 2        ! SIS2 → PET 6..7
/
```

Dois *smoke tests* cobrem as combinações com split:

```bash
bash tools/coupler/test-concurrent.bash       -n 8 --atm 4 --ocn 4
bash tools/coupler/test-sequential-split.bash -n 8 --atm 6 --ocn 2
```

> O detalhamento completo — topologia multinó, `select` do PBS, consolidação por
> componente, partições METIS e decomposição do MOM6 — está em
> [`docs/MULTINO-run_esmApp.md`](docs/MULTINO-run_esmApp.md),
> [`docs/domain-mom6.md`](docs/domain-mom6.md) e
> [`docs/mascara-cap-nuopc.md`](docs/mascara-cap-nuopc.md).

---

## 7. Compilação e execução

**Alvos do `make`:**

```bash
make            # compila bin/esmApp
make clean      # remove build/, bin/ e saídas soltas
make rebuild    # clean + all
make printenv   # variáveis e flags de compilação
make check      # confere a presença dos fontes
```

**Execução.** O `run_esmApp.jaci` roda a partir da própria árvore do projeto; o
diretório de experimento é o diretório atual (onde ficam `nuopc.input`,
namelists, malha e saídas). Coloque `run/` no `PATH` uma vez e invoque de qualquer
experimento:

```bash
export PATH="$PATH:/…/MONAN-Coupler/run"     # uma vez (ex.: no ~/.bashrc)

cd /…/exp1                                    # entradas do run
run_esmApp.jaci -n 128                        # 128 PETs = ½ nó
run_esmApp.jaci -n 256                        # 256 PETs = 1 nó cheio
run_esmApp.jaci -n 512 -w 02:00:00            # 512 PETs = 2 nós, 2 h
run_esmApp.jaci --compile -n 4                # make rebuild + qsub
run_esmApp.jaci --check                       # valida pré-requisitos
```

O script detecta o ambiente por `PBS_O_WORKDIR` (no login gera o `.pbs` e faz
`qsub`; dentro do job carrega módulos e lança o `mpiexec` do Cray PALS), deduz a
`COUPLER_ROOT` da sua localização e deriva a topologia de nós a partir de `-n`.
O padrão é **256 PET/nó** (nó físico cheio da Jaci, 1 rank por core), sem reserva
de memória. **Escalabilidade validada:** 4 → 512 PETs (1 a 4 nós).

### 7.1 Split de comunicador e consolidação por componente

Com `pet_layout = 'split'` e as contagens de PET explícitas, o `run_esmApp.jaci`
emite um `select` **heterogêneo**: cada componente recebe **nós separados**,
evitando nós "mistos" (ATM+OCN) e melhorando localidade e *binding*. Cada bloco
ocupa nós cheios (256 PET/nó) por padrão; o teto por componente é ajustável:

| Opção         | Padrão    | Efeito                                        |
|:--------------|:---------:|:----------------------------------------------|
| `--ppn-atm N` | 0 (→256)  | teto de PET/nó do bloco ATM                    |
| `--ppn-ocn N` | 0 (→256)  | teto de PET/nó do bloco OCN                    |
| `--ppn-ice N` | 0 (→256)  | teto de PET/nó do bloco ICE (com gelo dinâmico) |
| `--pet-order` | atm-first | ordem dos blocos ATM/OCN no `select`           |

Sem gelo, o `select` tem dois blocos; com `use_sis2_dynamic = .true.` ganha um
**terceiro bloco** para o ICE. A soma de `mpiprocs` dos blocos precisa fechar com
o `-n` do job:

```text
  -n 8   atm=4  ocn=2  ice=2
  select = 1:ncpus=4:mpiprocs=4 + 1:ncpus=2:mpiprocs=2 + 1:ncpus=2:mpiprocs=2
           └──── bloco ATM ────┘   └──── bloco OCN ───┘   └──── bloco ICE ───┘
```

> **A ordem dos blocos importa.** O PALS preenche o `PBS_NODEFILE` na ordem do
> `select`, e o `esm.F90` atribui PETs por faixas contíguas de rank: ATM, depois
> OCN, depois ICE. Os blocos seguem essa mesma ordem — `--pet-order` troca ATM e
> OCN de posição, mas o bloco do ICE vem **sempre por último**.

Para escolher as contagens **antes** de submeter, o `tools/coupler/plan-layout.py`
reproduz fora do job a mesma lógica de consolidação e imprime nós, PET/nó, memória
e o `select` resultante. Opções e topologia multinó completas em
[`docs/MULTINO-run_esmApp.md`](docs/MULTINO-run_esmApp.md).

---

## 8. Saídas e pós-processamento

| Diretório / arquivo              | Conteúdo                                 |
|:---------------------------------|:-----------------------------------------|
| `logs/PET*.esmApp.log`           | Logs ESMF por PET                        |
| `diag_export/monan_export_*.nc`  | Campos ATM exportados                    |
| `diag_import/mom6_import_*.nc`   | `exportState` do MED (14 fluxos + estado do oceano) |
| `diag_import/monan2_import_*.nc` | Campos OCN→ATM importados pelo MPAS      |
| `diag_import/docn_import_*.nc`   | SST/gelo interpolados pelo DOCN (Fase 1) |
| `diag_import/sst_ifrac_diag/`    | Evolução temporal de SST e `Si_ifrac`    |

Scripts Python em `tools/` (rode com `--help` para as opções):

```bash
python3 tools/postproc/postproc_monan2_export.py     # campos ATM exportados
python3 tools/postproc/postproc_monan2_import.py     # fluxos bulk MED→OCN
python3 tools/postproc/postproc_mom6_import.py       # campos importados pelo MOM6
python3 tools/postproc/analisa_comparacao.py         # comparação entre experimentos
python3 tools/postproc/analisa_sst_ifrac.py          # evolução de SST/Si_ifrac
python3 tools/animation/anim_monan2_import.py        # animações
```

> `mom6_import_*.nc` e `monan2_import_*.nc` gravam `_FillValue` real sobre terra
> (máscara nativa de cada modelo) e a variável `ocn_frac`; veja
> [`docs/mascara-continentes.md`](docs/mascara-continentes.md). O diagnóstico
> `write_import_diag=.true.` gera ~41 MB/dia (`dt_coupling=3600 s`) — desative em
> produção longa.

---

## 9. Documentação

A documentação detalhada vive em [`docs/`](docs/), junto dos fontes que descreve.

| Documento | Assunto |
|:----------|:--------|
| [`CHANGELOG.md`](docs/CHANGELOG.md) | Histórico de versões e o raciocínio por trás de decisões contraintuitivas. |
| [`notas-standalone.md`](docs/notas-standalone.md) | Separação entre instalador e sistema acoplado: resolução de caminhos e contrato entre os repositórios. |
| [`domain-mom6.md`](docs/domain-mom6.md) | Escolha do `LAYOUT` do MOM6+SIS2, formato do `mask_table` e armadilhas. |
| [`mascara-cap-nuopc.md`](docs/mascara-cap-nuopc.md) | Por que um `mask_table` com `nmask > 0` é incompatível com o cap NUOPC do MOM6. |
| [`mascara-continentes.md`](docs/mascara-continentes.md) | `_FillValue` sobre terra nos arquivos `*_import_*.nc` e a variável `ocn_frac`. |
| [`MULTINO-run_esmApp.md`](docs/MULTINO-run_esmApp.md) | Execução multinó na Jaci: `ncpus`, topologia por `coupling_mode` × `pet_layout`, filas e limites. |
| [`SMT-Jaci.md`](docs/SMT-Jaci.md) | Efeito do SMT sobre o acoplado: metodologia, resultados e reprodução. |

> A convenção de nomes dos módulos Fortran é `<stem>_mod` (ex.:
> `mpas_cap_MONAN.F90` → `mpas_cap_MONAN_mod`), com exceção de `esmApp.F90`
> (programa) e `MOM_cap_mod` (convenção do MOM6). O cap atmosférico replica à mão
> a sequência de inicialização do MPAS (`mpas_subdriver.F`) para se adequar ao
> ciclo de vida NUOPC — ao atualizar o submódulo `MONAN-Model`, confira o diff do
> driver antes de compilar.

---

## 10. Histórico de versões

Registro completo em [`docs/CHANGELOG.md`](docs/CHANGELOG.md). Marcos recentes:

| Versão | Data     | Mudanças                                                   |
|:-------|:---------|:-----------------------------------------------------------|
| 14.22  | Ago 2026 | Componente de gelo marinho (SIS2) integrado como componente NUOPC próprio, com conectores `MED ↔ ICE` e opção `--ppn-ice`. Correção do relógio compartilhado, da origem da fração de gelo e da contagem de passos. |
| 14.21  | Ago 2026 | Efeito do SMT medido: `--allow-smt` e `mede_smt.py`; padrão de 256 PET/nó confirmado. |
| 14.20  | Ago 2026 | Contabilidade de `ncpus` em cores físicos; `place=scatter:excl` como padrão; guarda de fila. |
| 14.19  | Jul 2026 | Execução multinó no `run_esmApp.jaci`; consolidação por componente; `plan-layout.py`. |
| 14.18  | Jul 2026 | Correção dos atributos globais ausentes nas saídas do MONAN-A acoplado. |
| 14.17  | Jul 2026 | Particionamento MPI (`&nuopc_petlayout`), `log_kind` e `gen-metis.bash`. |
| 14.0   | Mai 2026 | `MED_cap.F90` dividido em 5 módulos. |
| 6.0    | Mar 2026 | Mediador *bulk* NCAR (Large & Yeager, 2009). |

---

## 11. Referências e contato

- **ESMF/NUOPC** — <https://earthsystemmodeling.org>
- **MPAS-A** — Skamarock et al. (2021), *NCAR/TN-556+STR*.
- **MOM6** — Adcroft et al. (2019), *JAMES* 11(10), 3167–3211. <https://doi.org/10.1029/2019MS001726>
- **Bulk NCAR** — Large & Yeager (2009), *Clim. Dyn.* 33(2–3), 341–364.
- **Rugosidade** — Smith (1988), *J. Geophys. Res.* 93(C12).
- **OISST v2.1** — Huang et al. (2021), *J. Climate* 34(8), 2923–2939.
- **Projeto MONAN** — <https://monanadmin.github.io/monan-cc-docs/>

---

**GT Acoplamento de Modelos — INPE / CGCT / DIMNT**
Rodovia Presidente Dutra, Km 40 — Cachoeira Paulista, SP
