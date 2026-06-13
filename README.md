# MONAN-A 2.0 × MOM6+SIS2 — Sistema Acoplado NUOPC/ESMF

> **INPE / CGCT / DIMNT — GT Acoplamento de Modelos**
> v14.8 · ESMF/NUOPC 8.9.1 · MPAS-A 8.3.1 · MOM6+SIS2 · Junho 2026

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

Clone o repositório e a árvore MOM6-examples (com submódulos):

```bash
git clone https://github.com/GTA-DIMNT-CPTEC/MONAN-Coupler.git
cd MONAN-Coupler
git clone --recursive https://github.com/NOAA-GFDL/MOM6-examples.git
```

Pré-requisito adicional: ESMF 8.9.1 já instalado (com MOAB interno), localizado
por `run/setenv-gnu.bash`.

Instalação completa (orquestra as três etapas na ordem de dependência):

```bash
bash install/install-all.bash          # 1) MONAN-A  2) MOM6+SIS2  3) acoplador
```

Cada sessão de trabalho, antes de compilar/submeter:

```bash
source run/setenv-gnu.bash             # define ESMFMKFILE, MPAS_DIR, MOM6_ROOT…
make                                   # (re)compila bin/esmApp
bash run/run_esmApp.jaci -n 128        # submete via PBS (128 PETs)
```

---

## Instalação

Scripts em `install/` (funções comuns em `install-libs.bash`):

| Script                   | Etapa | Finalidade                               |
|:-------------------------|:-----:|:-----------------------------------------|
| `install-all.bash`       |   —   | Orquestra as etapas 1→2→3                |
| `1-install-monan.bash`   |   1   | MONAN-A 2.0 → `lib/monan2`, `mod/monan2` |
| `2-install-mom.bash`     |   2   | MOM6+SIS2+FMS → `lib/{fms,mom6,nuopc}`   |
| `3-install-coupler.bash` |   3   | Compila e linka `bin/esmApp`             |

Opções úteis: `install-all.bash --from N` (retoma na etapa N), `1-install-monan.bash --skip-init-atm`, `2-install-mom.bash --only-nuopc`.

**ESMF e MOAB.** O acoplador usa o ESMF 8.9.1 via `esmf.mk` (variáveis
`ESMF_ROOT`/`ESMFMKFILE`, definidas em `run/setenv-gnu.bash`). O MOAB é **interno
ao `libesmf`** — não há `-lMOAB` externo. Para um ESMF com MOAB externo, defina
`USE_EXTERNAL_MOAB=yes` e `MOAB_DIR` (mesma variável no Makefile e no `setenv`).

**Template mkmf.** O `2-install-mom.bash` usa
`install/templates/cray-gnu-monan.mk` (versionado no repositório, livre de
caminhos pessoais). Para apontar outro template: `export MKMF_TEMPLATE_SRC=…`.

---

## Estrutura de diretórios

```
MONAN-Coupler/
├── Makefile                    ← build do acoplador (bin/esmApp)
├── nuopc.input                 ← namelist de acoplamento
├── install/
│   ├── install-all.bash        ← orquestra as etapas 1→2→3
│   ├── install-libs.bash       ← funções comuns (log, timer, cópia)
│   ├── 1-install-monan.bash    ← etapa 1 — MONAN-A 2.0
│   ├── 2-install-mom.bash      ← etapa 2 — MOM6+SIS2+FMS
│   ├── 3-install-coupler.bash  ← etapa 3 — linka bin/esmApp
│   └── templates/
│       └── cray-gnu-monan.mk   ← template mkmf Cray/GNU
├── src/
│   ├── main/esmApp.F90         ← ponto de entrada
│   ├── driver/esm.F90          ← driver NUOPC
│   ├── mediator/               ← MED (bulk NCAR): MED_cap + 4 módulos
│   ├── caps/atmos/             ← cap MONAN-A (MPAS) + DATM
│   ├── caps/ocean/             ← cap MOM6+SIS2 + DOCN (+ upstream/)
│   └── shared/                 ← mpi_allreduce_*, time_utils
├── tools/
│   ├── postproc/               ← pós-processamento (Python)
│   └── animation/              ← animações (Python)
├── run/
│   ├── setenv-gnu.bash         ← ambiente de compilação (Jaci/GNU)
│   └── run_esmApp.jaci         ← submissão PBS
├── mod/                        ← módulos .mod (monan2, init_atmosphere)
├── lib/                        ← libs .a (monan2, fms, mom6, nuopc, …)
├── INPUT/                      ← grades e forçantes (mesh, OISST…)
├── diag_export/                ← monan_export_*.nc
├── diag_import/                ← *_import_*.nc, sst_ifrac_diag/
└── doc/README.md               ← este arquivo
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

```bash
bash run/run_esmApp.jaci                     # 4 PETs, fila pesqextra, 1 h
bash run/run_esmApp.jaci -n 128              # 128 PETs
bash run/run_esmApp.jaci -n 512 -w 02:00:00  # 512 PETs, 2 h
bash run/run_esmApp.jaci --compile -n 4      # make rebuild + qsub
bash run/run_esmApp.jaci --check             # valida pré-requisitos
```

O `run_esmApp.jaci` detecta o ambiente via `PBS_O_WORKDIR`: no login gera o
`.pbs` e faz `qsub`; dentro do job carrega módulos, faz `source setenv-gnu.bash`
e executa `mpirun`. Escalabilidade validada: 4 → 512 PETs.

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
