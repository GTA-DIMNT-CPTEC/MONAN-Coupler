# MONAN-A 2.0 × MOM6+SIS2 — Sistema Acoplado NUOPC/ESMF

> **INPE / CGCT / DIMNT — GT Acoplamento de Modelos**
> v14.16 · ESMF/NUOPC 8.9.1 · MPAS-A 8.3.1 · MOM6+SIS2 · Junho 2026

Acoplador atmosfera–oceano–gelo de produção: **MONAN-A 2.0** (MPAS-A, malha
Voronoi hexagonal) acoplado ao **MOM6+SIS2** (grade tripolar) via framework
**NUOPC/ESMF 8.9.1**, no supercomputador **Jaci** (Cray XD 2000, PrgEnv-gnu).
Um mediador próprio calcula fluxos turbulentos por fórmulas bulk NCAR.

---

## Arquitetura

```
  ┌─────────────────────────────────────────┐
  │     esmApp.F90 — programa principal     │
  └────────────────────┬────────────────────┘
  ┌────────────────────▼────────────────────┐
  │         esm.F90 — Driver NUOPC          │
  │    relógio · PETs · ATM / MED / OCN     │
  └─────┬──────────────┬──────────────┬─────┘
        │              │              │
  ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
  │   MPAS    │  │    MED    │  │   MOM6    │
  │  MONAN-A  │  │   bulk    │  │   +SIS2   │
  │    2.0    │  │   NCAR    │  │ dinâmico  │
  └───────────┘  └───────────┘  └───────────┘
        │              │              │
        └──────────────┴──────────────┘
               Conectores NUOPC
```

Fluxo de acoplamento por passo (Fase 2, MOM6 ativo):

| Passo | Conector  | Campos / ação                                        |
|------:|:----------|:-----------------------------------------------------|
|     1 | OCN → MED | `So_t`, `So_u`, `So_v`, `Si_ifrac`                   |
|     2 | ATM → MED | `u10m`, `v10m`, `tbot`, `qbot`, `pbot`, … (9 campos) |
|     3 | MED       | bulk NCAR (Large & Yeager 2009) → 14 fluxos          |
|     4 | MED → OCN | `Foxx_*` / `Faxa_*` → forçantes MOM6                 |
|     5 | OCN       | `step_MOM` — avança MOM6+SIS2 por `dt_coupling`      |
|     6 | MED → ATM | `So_t`, `Si_ifrac`, `So_u`, `So_v`, `Sf_zorl` → MPAS |
|     7 | ATM       | dinâmica + física (N × `dt_atm`)                     |

Na Fase 1 (DOCN), o OCN exporta direto para o ATM (`use_med_to_mpas=.false.`),
sem mediador.

---

## Início rápido

O sistema acoplado (este repositório) traz o **MONAN-Model** e o
**MOM6-examples** como **submódulos** (em `models/atmos/` e `models/ocean/`).
Os **scripts de instalação ficam em repositório separado**
(`Coupler-Install`), com um instalador único (`install.bash`): ele baixa o
sistema com `git` recursivo e instala — tudo em um comando.

**Caminho recomendado (um comando):**

```bash
git clone --branch develop https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash            # clona o sistema (recursivo, develop) e instala
```

O `install.bash` executa
`git clone --recursive --branch develop …/MONAN-Coupler.git` (trazendo os dois
modelos e os submódulos aninhados do MOM6-examples) e, em seguida, roda as três
etapas de instalação. Opções: `--coupler-root DIR`, `--branch BRANCH`,
`--no-install` (só baixa), `--from N`/`--only N` (repassadas ao instalador).

**Clone manual (equivalente), se preferir:**

```bash
git clone --recursive --branch develop \
    https://github.com/GTA-DIMNT-CPTEC/MONAN-Coupler.git
export COUPLER_ROOT="$PWD/MONAN-Coupler"
bash /caminho/Coupler-Install/build.bash
```

Pré-requisito adicional: ESMF 8.9.1 já instalado (com MOAB interno), localizado
por `run/setenv-gnu.bash`.

Cada sessão de trabalho, antes de compilar/submeter (a partir da raiz do
sistema acoplado):

```bash
source run/setenv-gnu.bash             # define ESMFMKFILE, MPAS_DIR, MOM6_ROOT…
make                                   # (re)compila bin/esmApp
bash run/run_esmApp.jaci -n 128        # submete via PBS (128 PETs)
```

---

## Instalação

Os scripts de instalação residem em **repositório próprio**
(`Coupler-Install`), separado do sistema acoplado. Funções comuns em
`include.bash`:

| Script                   | Etapa | Finalidade                                       |
|:-------------------------|:-----:|:-------------------------------------------------|
| `install.bash`           |   0   | Baixa o sistema (git recursivo) **e** instala    |
| `build.bash`             |   —   | Só as 3 etapas (assume o sistema já baixado)     |
| `1-monan.bash`           |   1   | MONAN-A 2.0 → `lib/monan2`, `mod/monan2`         |
| `2-mom.bash`             |   2   | MOM6+SIS2+FMS → `lib/{fms,mom6,nuopc}`           |
| `3-coupler.bash`         |   3   | Compila e linka `bin/esmApp`                     |

Como os scripts vivem fora da árvore do acoplador, a raiz do sistema é informada
por **`COUPLER_ROOT`** (o `install.bash` a define e exporta automaticamente;
ao rodar um instalador isolado, exporte-a ou use `--coupler-root`).

Opções úteis: `install.bash --no-install` (só baixa), `build.bash --from N` (retoma na etapa N), `1-monan.bash --skip-init-atm`, `2-mom.bash --only-nuopc`.

Atalhos via `make` (no `Coupler-Install`): `make` (= baixa + instala), `make download`, `make build FROM=N`, `make check`, `make help`.

**Configuração de sítio (`sites/site-jaci.bash`, no repositório `Coupler-Install`).**
Este é o **único arquivo a editar** ao trocar de usuário, máquina ou versões de
módulo. Centraliza tudo que é específico do ambiente: caminho do ESMF, listas de
módulos, alvo de CPU, paralelismo (`MAKE_JOBS`) e wrappers do compilador. Os
instaladores o carregam automaticamente; o `install.bash` também deixa uma
cópia em `<COUPLER_ROOT>/run/setenv-site.bash`, para que as sessões de build
(`source run/setenv-gnu.bash`) a encontrem sem o instalador presente. Três
formas de uso, da mais simples à mais flexível:

- **Jaci (padrão):** nada a fazer — os valores já estão corretos.
- **Ajuste pontual**, sem editar o arquivo: exporte a variável antes de instalar
  (qualquer valor já exportado tem prioridade sobre o padrão do sítio).
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

**Download das fontes (submódulos).** Os modelos chegam como **submódulos** no
clone recursivo feito pelo `install.bash`: **MONAN-Model** em `models/atmos/`
e **MOM6-examples** (com seus próprios submódulos) em `models/ocean/`. As etapas
1 e 2 apenas confirmam a presença das árvores e, se algum submódulo não tiver
sido inicializado, executam `git submodule update --init --recursive`. Para usar
um fork como origem, ajuste a URL no `.gitmodules` do sistema acoplado (ou, no
modo legado sem submódulos, exporte `MONAN_MODEL_URL`/`MOM6_EXAMPLES_URL`).

**ESMF e MOAB.** O acoplador usa o ESMF 8.9.1 via `esmf.mk` (variáveis
`ESMF_ROOT`/`ESMFMKFILE`, definidas em `run/setenv-site.bash`). O MOAB é
**interno ao `libesmf`** — não há `-lMOAB` externo. Para um ESMF com MOAB externo,
defina `USE_EXTERNAL_MOAB=yes` e `MOAB_DIR` (mesma variável no Makefile e no `setenv`).

**Template mkmf.** O `2-mom.bash` usa `templates/cray-gnu-monan.mk`
(versionado no `Coupler-Install`, livre de caminhos pessoais). É procurado em
vários locais (`templates/`, raiz, …); para apontar outro:
`export MKMF_TEMPLATE_SRC=…`.

---

## Estrutura de diretórios

Dois repositórios distintos. O **sistema acoplado** (com os modelos como
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
│   └── animation/            ← animações (Python)
├── run/
│   ├── setenv-gnu.bash       ← ambiente de compilação (Jaci/GNU)
│   ├── setenv-site.bash      ← config de sítio (cópia do install.bash)
│   └── run_esmApp.jaci       ← submissão PBS
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

## Dependências

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

`run/setenv-gnu.bash` verifica as versões instaladas no Jaci e a presença das
6 bibliotecas do MONAN-A em `lib/monan2`.

---

## Configuração — `nuopc.input`

Namelist Fortran lido por `mpas_cap_config_mod`; grupos omitidos usam defaults.
Modos de operação (grupo `&nuopc_mode`):

| `use_datm` | `use_docn` | `use_med_to_mpas` | Modo                    |
|:----------:|:----------:|:-----------------:|:------------------------|
| `.false.`  | `.false.`  |     `.true.`      | MPAS + MOM6 (produção)  |
| `.false.`  |  `.true.`  |     `.false.`     | MPAS + DOCN (Fase 1)    |
|  `.true.`  | `.false.`  |     `.true.`      | DATM + MOM6 (teste OCN) |
|  `.true.`  |  `.true.`  |     `.false.`     | DATM + DOCN (teste MED) |

> `use_med_to_mpas=.true.` é **obrigatório** quando `use_docn=.false.`: sem ele,
> o MPAS não recebe SST/gelo, pois o MOM6 não expõe esses campos pelo caminho
> direto OCN→ATM da Fase 1.

Exemplo — 24 h com MOM6 dinâmico (Fase 2):

```fortran
&nuopc_driver
  start_date = '2026-03-29'  stop_date = '2026-03-30'
  dt_coupling = 3600         dt_atm = 60          ! [s]
/
&nuopc_mode
  use_datm = .false.  use_docn = .false.  use_med_to_mpas = .true.
/
```

---

## Compilação e execução

```bash
make            # compila bin/esmApp (= make all)
make clean      # remove build/ bin/ e saídas soltas (*.stdout, log.atmosphere.*)
make distclean  # clean + remove *.pbs
make rebuild    # clean + all
make printenv   # variáveis e flags de compilação
make diagnose   # estado do build e objetos
make check      # confere a presença dos fontes
```

Rode o `run_esmApp.jaci` a partir da própria árvore do projeto — o diretório de
experimento é apenas o diretório atual (onde ficam `nuopc.input`, namelists,
malha e as saídas). Coloque `run/` no `PATH` uma vez e invoque de qualquer
experimento, sem copiar scripts nem o binário:

```bash
export PATH="$PATH:/…/MONAN-Coupler/run"     # uma vez (ex.: no ~/.bashrc)

cd /…/exp1                                    # entradas do run
run_esmApp.jaci -n 128                         # 128 PETs
run_esmApp.jaci -n 512 -w 02:00:00             # 512 PETs, 2 h
run_esmApp.jaci --compile -n 4                 # make rebuild + qsub
run_esmApp.jaci --check                        # valida pré-requisitos
```

O `run_esmApp.jaci` detecta o ambiente via `PBS_O_WORKDIR`: no login gera o
`.pbs` e faz `qsub`; dentro do job carrega módulos, faz `source` do `setenv` e
executa `mpirun`. A raiz do projeto vem de `COUPLER_ROOT`, autodeduzida da
localização do script e propagada ao job pelo `.pbs`; ao rodar de fora da árvore,
sobrescreva com `export COUPLER_ROOT=…`. O `setenv` e o executável
(`${COUPLER_ROOT}/bin/esmApp`, sobrescrevível por `ESMAPP_BIN`) são resolvidos na
árvore do projeto — o diretório de experimento guarda só as entradas e saídas.
Escalabilidade validada: 4 → 512 PETs.

---

## Saídas e pós-processamento

| Diretório / arquivo              | Conteúdo                                 |
|:---------------------------------|:-----------------------------------------|
| `bin/esmApp`                     | Executável                               |
| `logs/PET*.esmApp.log`           | Logs ESMF por PET                        |
| `diag_export/monan_export_*.nc`  | Campos ATM exportados                    |
| `diag_import/mom6_import_*.nc`   | Fluxos bulk MED→OCN                      |
| `diag_import/monan2_import_*.nc` | Campos OCN→ATM importados pelo MPAS      |
| `diag_import/docn_import_*.nc`   | SST/gelo interpolados pelo DOCN (Fase 1) |
| `diag_import/sst_ifrac_diag/`    | Evolução temporal de SST e Si_ifrac      |

Scripts Python em `tools/` (rodar com `--help` para opções):

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

## Módulos Fortran

Padrão `<stem>_mod` (ex.: `mpas_cap_MONAN.F90` → `mpas_cap_MONAN_mod`), exceto
`esmApp.F90` (programa) e `MOM_cap_mod` (convenção MOM6). Os fontes em
`src/caps/ocean/upstream/` pertencem à biblioteca MOM6 e **não** são compilados
por este Makefile.

<details>
<summary>Tabela completa de módulos</summary>

**Driver e aplicação**

| Arquivo      | Módulo       | Descrição                    |
|:-------------|:-------------|:-----------------------------|
| `esmApp.F90` | *(programa)* | Entrada; relógio ESMF global |
| `esm.F90`    | `ESM_MONAN`  | Driver NUOPC; sequência      |

**Cap atmosférico — `src/caps/atmos/`**

| Arquivo                 | Descrição                           |
|:------------------------|:------------------------------------|
| `mpas_cap_MONAN.F90`    | Cap NUOPC para MONAN-A 2.0 / MPAS   |
| `mpas_cap_methods.F90`  | Importa/exporta campos ESMF ↔ MPAS  |
| `mpas_cap_netcdf.F90`   | Diagnósticos NetCDF export/import   |
| `mpas_cap_config.F90`   | Leitura do namelist `nuopc.input`   |
| `mpas_cap_utils.F90`    | `ChkErr`, log ESMF, utilitários     |
| `mpas_atm_types.F90`    | Tipos do estado atmosférico         |
| `mpas_atm_model.F90`    | Inicializa e avança o MONAN-A       |
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

## Histórico de versões

| Versão | Data     | Mudanças                                                   |
|:-------|:---------|:-----------------------------------------------------------|
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
<summary>Versões anteriores</summary>

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

## Referências

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
