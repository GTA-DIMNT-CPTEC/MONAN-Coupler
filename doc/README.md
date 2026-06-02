# MONAN-A 2.0 × MOM6+SIS2 — Sistema Acoplado NUOPC/ESMF

> **INPE / CGCT / DIMNT — GT Acoplamento de Modelos**
> Versão 14.2 · ESMF/NUOPC 8.9.1 · MPAS-A 8.3.1 · Maio 2026

---

## Sumário

1. [Arquitetura](#1-arquitetura)
2. [Módulos Fortran](#2-módulos-fortran)
3. [Scripts de Apoio](#3-scripts-de-apoio)
4. [Estrutura de Diretórios](#4-estrutura-de-diretórios)
5. [Dependências](#5-dependências)
6. [Ambiente de Compilação](#6-ambiente-de-compilação)
7. [Compilação](#7-compilação)
8. [Configuração — nuopc.input](#8-configuração--nuopcinput)
9. [Execução](#9-execução)
10. [Saídas e Diagnósticos](#10-saídas-e-diagnósticos)
11. [Pós-processamento](#11-pós-processamento)
12. [Modos de Operação](#12-modos-de-operação)
13. [Histórico de Versões](#13-histórico-de-versões)
14. [Referências](#14-referências)

---

## 1. Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│             esmApp.F90  (programa principal)                │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│               esm.F90  (Driver NUOPC)                       │
│       relógio global · PETs · sequência ATM/MED/OCN         │
└────────┬──────────────────┬──────────────────┬──────────────┘
         │                  │                  │
    ┌────▼─────┐      ┌─────▼────┐      ┌─────▼────┐
    │   MPAS   │      │   MED    │      │   MOM6   │
    │ MONAN-A  │      │  bulk    │      │  +SIS2   │
    │   2.0    │      │  NCAR    │      │ dinâmico │
    └────┬─────┘      └─────┬────┘      └─────┬────┘
         └──────────────────┼─────────────────┘
                    Conectores NUOPC (4)
```

### Fluxo de acoplamento por passo (Fase 2 — MOM6 ativo)

| Passo | Conector  | Campos                                                |
|------:|-----------|-------------------------------------------------------|
| 1     | OCN → MED | `So_t`, `So_u`, `So_v`, `Si_ifrac`                    |
| 2     | ATM → MED | `u10m`, `v10m`, `tbot`, `qbot`, `pbot`, … (9 campos)  |
| 3     | MED       | bulk NCAR (Large & Yeager 2009) → 14 fluxos           |
| 4     | MED → OCN | `Foxx_*` / `Faxa_*` → forçantes MOM6                 |
| 5     | OCN       | `step_MOM` — avança MOM6+SIS2 por `dt_coupling`       |
| 6     | MED → ATM | `So_t`, `Si_ifrac`, `So_u`, `So_v`, `Sf_zorl` → MPAS |
| 7     | ATM       | dinâmica + física (N × `dt_atm`)                      |

> **Fase 1 (DOCN):** OCN exporta campos diretamente para ATM
> (`use_med_to_mpas=.false.`), sem passar pelo mediador.

---

## 2. Módulos Fortran

> Módulos seguem o padrão `<stem>_mod`
> (ex.: `mpas_cap_MONAN.F90` → `mpas_cap_MONAN_mod`),
> exceto `esmApp.F90` (programa principal) e `MOM_cap_mod` (convenção MOM6).
>
> Os arquivos em `src/caps/ocean/upstream/` são fontes da **biblioteca MOM6**,
> compiladas separadamente em `$(MOM6_LIBDIR)`. Estão no repositório apenas
> como referência — **não são compilados por este Makefile**.

### 2.1 Driver e Aplicação

| Arquivo        | Módulo              | Descrição                              |
|----------------|---------------------|----------------------------------------|
| `esmApp.F90`   | *(prog. principal)* | Ponto de entrada; relógio ESMF global  |
| `esm.F90`      | `ESM_MONAN`         | Driver NUOPC; sequência de execução    |

### 2.2 Cap Atmosférico (ATM) — `src/caps/atmos/`

| Arquivo                 | Módulo                  | Descrição                               |
|-------------------------|-------------------------|-----------------------------------------|
| `mpas_cap_MONAN.F90`    | `mpas_cap_MONAN_mod`    | Cap NUOPC para MONAN-A 2.0 / MPAS 8.3  |
| `mpas_cap_methods.F90`  | `mpas_cap_methods_mod`  | Importa/exporta campos ESMF ↔ MPAS      |
| `mpas_cap_netcdf.F90`   | `mpas_cap_netcdf_mod`   | Diagnósticos NetCDF de export e import  |
| `mpas_cap_config.F90`   | `mpas_cap_config_mod`   | Leitura do namelist `nuopc.input`       |
| `mpas_cap_utils.F90`    | `mpas_cap_utils_mod`    | `ChkErr`, log ESMF, utilitários         |
| `mpas_atm_types.F90`    | `mpas_atm_types_mod`    | Tipos derivados do estado atmosférico   |
| `mpas_atm_model.F90`    | `mpas_atm_model_mod`    | Wrapper: inicializa e avança MONAN-A    |
| `mpas_atm_wrappers.F90` | *(sem módulo)*          | Interface com internos do MPAS          |
| `DATM_cap.F90`          | `DATM_cap_mod`          | Cap ATM por dados (JRA55 sintético)     |

> `mpas_cap_netcdf_mod` inclui as rotinas de diagnóstico de importação
> `write_mpas_import_diag`, `set_mpas_diag_clock` e `voronoi_to_grid`,
> migradas de `mpas_cap_methods_mod` na v14.0.

### 2.3 Utilitários Compartilhados — `src/shared/`

Módulos de infraestrutura sem vínculo com nenhum componente específico.
Usados transversalmente pelos caps ATM, OCN e MED.

| Arquivo                       | Módulo                         | Descrição                                  |
|-------------------------------|--------------------------------|--------------------------------------------|
| `mpi_allreduce_r8.F90`        | `mpi_allreduce_r8_mod`         | `MPI_Allreduce` para `real(8)` — isolado   |
| `mpi_allreduce_i4.F90`        | `mpi_allreduce_i4_mod`         | `MPI_Allreduce` para `integer(4)` — isolado|
| `mpi_allreduce_wrappers.F90`  | `mpi_allreduce_wrappers_mod`   | Re-exporta as duas variantes tipadas       |
| `time_utils.F90`              | `time_utils_mod`               | Conversão de tempo FMS ↔ ESMF              |

> **Por que módulos separados para `MPI_Allreduce`?**
> O compilador gfortran/ftn analisa todos os tipos de `sendbuf`/`recvbuf`
> visíveis no mesmo arquivo de compilação. Ter `real(8)` e `integer(4)` no
> mesmo arquivo emite aviso espúrio de incompatibilidade de argumentos — não
> suprimível por `-Wno-argument-mismatch`. A separação em módulos distintos
> fecha o escopo de análise de cada variante (correção W1-FIX, v12.0).

### 2.4 Mediador (MED) — `src/mediator/`

O mediador foi reorganizado na v14.0 em cinco módulos especializados.

| Arquivo               | Módulo                | Descrição                                        |
|-----------------------|-----------------------|--------------------------------------------------|
| `MED_cap.F90`         | `MED_cap_mod`         | Orquestrador NUOPC puro — ciclo de vida          |
| `med_cap_types.F90`   | `med_cap_types_mod`   | Tipos, constantes físicas, listas de campos      |
| `med_bulk_ncar.F90`   | `med_bulk_ncar_mod`   | Física bulk NCAR + rugosidade Charnock/Smith     |
| `med_cap_methods.F90` | `med_cap_methods_mod` | Utilitários ESMF: regrid, campos, `RouteOcnToAtm`|
| `med_cap_netcdf.F90`  | `med_cap_netcdf_mod`  | Diagnóstico NetCDF MED→OCN (`mom6_import_*.nc`)  |

**Responsabilidades por módulo:**

- `med_cap_types_mod` — `MED_InternalState`, `MED_InternalStateWrapper`, constantes
  físicas (Large & Yeager 2009), listas `import_mpas_names`, `export_names` e variáveis
  `save` do diagnóstico (`med_mpi_comm`, `med_write_import_diag`, etc.).
- `med_bulk_ncar_mod` — sub-rotina `calc_bulk_ncar`: calcula os 14 fluxos `Foxx_*`/`Faxa_*`,
  `duu10n`, `Si_ifrac` e a rugosidade `Sf_zorl` via Charnock + Smith (1988).
- `med_cap_methods_mod` — `CreateInternalField`, `ZeroInternalField`, `FillInternalField`,
  `GetFieldPtr`, `GetFieldPtrOptional`, `RegridOrCopy`, `RouteOcnToAtm`,
  `RegridOptionalCurrent`.
- `med_cap_netcdf_mod` — `med_read_import_config` (lê `mom6_output.nml`) e
  `med_write_import_fields` (gera `mom6_import_YYYYMMDD_HHMMSS.nc`).
- `MED_cap_mod` — `SetServices`, `Initialize*` (P0/Advertise/Realize/DataComplete),
  `MediatorAdvance` (orquestrador que chama os módulos acima).

### 2.5 Cap Oceânico (OCN) — `src/caps/ocean/`

| Arquivo               | Módulo                | Descrição                                      |
|-----------------------|-----------------------|------------------------------------------------|
| `mom_cap_MONAN.F90`   | `MOM_cap_MONAN_mod`   | Cap NUOPC para MOM6+SIS2 dinâmico              |
| `ocn_comp_NUOPC.F90`  | `ocn_comp_NUOPC`      | Módulo ponte — re-exporta `SetServices` do OCN |
| `DOCN_cap.F90`        | `DOCN_cap_mod`        | Cap OCN por dados OISST (Fase 1)               |
| `docn_cap_netcdf.F90` | `docn_cap_netcdf_mod` | I/O NetCDF do DOCN (`ReadGlobal`, `Interp`, `Diag`) |

> `ocn_comp_NUOPC.F90` não é compilado por este Makefile. Ele existe para
> permitir que drivers externos se conectem ao componente OCN sem depender
> diretamente de `MOM_cap_MONAN_mod`. O driver `esm.F90` usa
> `MOM_cap_MONAN_mod` diretamente.
>
> `docn_cap_netcdf_mod` contém `ReadGlobalField`, `ReadOcnFieldInterp` e
> `WriteDOCNDiag`, extraídas de `DOCN_cap.F90` na v14.0.

---

## 3. Scripts de Apoio

### Ambiente e execução — `run/`

| Arquivo             | Finalidade                              |
|---------------------|-----------------------------------------|
| `setenv-gnu.bash`   | Ambiente de compilação (Jaci/GNU)       |
| `run_esmApp.jaci`   | Submissão PBS; modos interativo e job   |

### Pós-processamento — `tools/postproc/`

| Arquivo                          | Finalidade                                                     |
|----------------------------------|----------------------------------------------------------------|
| `postproc_monan2_export.py`      | Campos ATM exportados (`diag_export/`)                         |
| `postproc_monan2_import.py`      | Fluxos bulk MED→OCN (`diag_import/`)                           |
| `postproc_monan2_standalone.py`  | Pós-processamento standalone do MONAN-A                        |
| `postproc_mom6_import.py`        | Diagnóstico dos campos importados pelo MOM6                    |
| `analisa_comparacao.py`          | Comparação estatística entre experimentos                      |
| `analisa_sst_ifrac.py`           | Evolução temporal de SST e Si_ifrac: série temporal, anomalia, diferença consecutiva e métricas integradas |

### Animações — `tools/animation/`

| Arquivo                  | Finalidade                                      |
|--------------------------|-------------------------------------------------|
| `anim_monan2_import.py`  | Animação dos campos importados pelo MPAS        |
| `anim_mom6_import.py`    | Animação dos campos importados pelo MOM6        |

---

## 4. Estrutura de Diretórios

```
gta-coupler/
├── Makefile                           ← build principal (v14.2)
├── nuopc.input                        ← namelist de acoplamento
│
├── src/
│   ├── main/                          ← ponto de entrada do aplicativo
│   │   └── esmApp.F90
│   ├── driver/                        ← driver NUOPC
│   │   └── esm.F90
│   ├── mediator/                      ← cap do mediador ATM-OCN
│   │   ├── MED_cap.F90                ← orquestrador reduzido (v14.0)
│   │   ├── med_cap_types.F90          ← tipos e constantes (v14.0)
│   │   ├── med_cap_methods.F90        ← utilitários ESMF (v14.0)
│   │   ├── med_cap_netcdf.F90         ← diagnóstico NetCDF (v14.0)
│   │   └── med_bulk_ncar.F90          ← física bulk NCAR (v14.0)
│   ├── caps/
│   │   ├── atmos/                     ← cap MONAN-A (MPAS) + DATM
│   │   │   ├── mpas_cap_MONAN.F90
│   │   │   ├── mpas_cap_methods.F90
│   │   │   ├── mpas_cap_netcdf.F90    ← diagnóstico import (v14.0)
│   │   │   ├── mpas_cap_config.F90
│   │   │   ├── mpas_cap_utils.F90
│   │   │   ├── mpas_atm_types.F90
│   │   │   ├── mpas_atm_model.F90
│   │   │   ├── mpas_atm_wrappers.F90
│   │   │   └── DATM_cap.F90
│   │   └── ocean/                     ← cap MOM6+SIS2 + DOCN
│   │       ├── mom_cap_MONAN.F90
│   │       ├── ocn_comp_NUOPC.F90     ← módulo ponte (não compilado)
│   │       ├── DOCN_cap.F90
│   │       ├── docn_cap_netcdf.F90    ← I/O NetCDF do DOCN (v14.0)
│   │       └── upstream/              ← fontes upstream MOM6 (não editar)
│   │           ├── README.upstream.md
│   │           ├── mom_cap.F90
│   │           ├── mom_cap_methods.F90
│   │           ├── mom_cap_time.F90
│   │           ├── mom_ocean_model_nuopc.F90
│   │           └── mom_surface_forcing_nuopc.F90
│   └── shared/                        ← utilitários MPI e FMS/ESMF (v14.1)
│       ├── mpi_allreduce_r8.F90       ← real(8) — módulo isolado (W1-FIX)
│       ├── mpi_allreduce_i4.F90       ← integer(4) — módulo isolado (W1-FIX)
│       ├── mpi_allreduce_wrappers.F90
│       └── time_utils.F90             ← conversão FMS ↔ ESMF
│
├── tools/                             ← scripts Python (fora da build)
│   ├── postproc/
│   │   ├── postproc_monan2_export.py
│   │   ├── postproc_monan2_import.py
│   │   ├── postproc_monan2_standalone.py
│   │   ├── postproc_mom6_import.py
│   │   ├── analisa_comparacao.py
│   │   └── analisa_sst_ifrac.py       ← evolução SST/Si_ifrac (v14.2)
│   └── animation/
│       ├── anim_monan2_import.py
│       └── anim_mom6_import.py
│
├── run/                               ← ambiente e submissão de jobs
│   ├── setenv-gnu.bash
│   └── run_esmApp.jaci
│
├── doc/                               ← documentação técnica
│   └── README.md                      ← este arquivo
│
├── build/                             ← artefatos de compilação (gerado pelo make)
│   ├── obj/                           ← arquivos .o
│   └── mod/                           ← arquivos .mod
├── bin/
│   └── esmApp                         ← executável final
├── INPUT/
│   ├── mpas_mesh.nc                   ← grade Voronoi do MONAN-A
│   ├── ocean_hgrid.nc                 ← supergrid MOM6 (FRE-NCtools)
│   ├── OISST_sst.nc                   ← SST OISST v2.1 (modo DOCN)
│   ├── OISST_ice.nc                   ← gelo OISST v2.1 (modo DOCN)
│   └── OISST_cur.nc                   ← correntes OSCAR NRT v2.0 (opcional)
├── diag_export/                       ← monan_export_YYYYMMDD_HHMMSS.nc
├── diag_import/                       ← mom6_import_*.nc · monan2_import_*.nc
│                                         docn_import_*.nc · sst_ifrac_diag/
└── logs/                              ← PET*.esmApp.log + stdout mpirun
```

---

## 5. Dependências

| Biblioteca          | Versão      | Função                           |
|---------------------|-------------|----------------------------------|
| **ESMF**            | 8.9.1       | Framework de acoplamento NUOPC   |
| **MPAS-A**          | 8.3.1       | Dinâmica e física atmosférica    |
| **MOM6+SIS2**       | tag NUOPC   | Oceano e gelo marinho dinâmicos  |
| **FMS**             | 2024.01+    | Framework GFDL (dep. do MOM6)    |
| **MOAB**            | 5.x         | Malhas não-estruturadas ESMF     |
| **Parallel-NetCDF** | 1.12.3+     | I/O paralelo MOM6                |
| **gfortran**        | 12.3+       | Compilador Fortran (PrgEnv-gnu)  |
| **MPI**             | Cray MPICH  | Comunicação paralela             |
| **Python**          | 3.9+        | Scripts de pós-processamento     |
| **netCDF4**         | —           | I/O NetCDF nos scripts Python    |
| **matplotlib**      | —           | Geração de figuras               |
| **cartopy**         | —           | Mapas geográficos (opcional)     |

> Versões exatas instaladas no Jaci verificadas por
> `run/setenv-gnu.bash` na seção `[4/4] MOM6+SIS2`.

---

## 6. Ambiente de Compilação

Executar **uma vez por sessão** antes de compilar ou submeter:

```bash
source run/setenv-gnu.bash
```

O script executa 4 etapas:

1. Carrega módulos Jaci (ESMF, NetCDF, MPI, PrgEnv-gnu).
2. Define `ESMFMKFILE`, `MPAS_DIR`, `MOM6_ROOT` e derivadas
   (`FMS_LIBDIR`, `MOM6_LIBDIR`, `MOM6_MODDIR`).
3. Configura `GFORTRAN_CONVERT_UNIT=big_endian:101` (RRTMG)
   e estende `LD_LIBRARY_PATH` com MOM6/FMS/MOAB.
4. Verifica presença de arquivos e diretórios essenciais
   (4 seções; resumo `N OK / M faltando`).

**Verificação rápida:**

```bash
echo "ESMFMKFILE : $ESMFMKFILE"
echo "MPAS_DIR   : $MPAS_DIR"
echo "MOM6_ROOT  : $MOM6_ROOT"
```

---

## 7. Compilação

```bash
make           # compila bin/esmApp  (= make all)
make clean     # remove build/ bin/ logs/  (dados preservados)
make distclean # clean + remove diag_export/ diag_import/
make rebuild   # make clean + make all
make printenv  # exibe variáveis de compilação e flags
make diagnose  # inspeciona estado do build e objetos
make help      # lista todos os alvos disponíveis
```

### Camadas de compilação

| Camada  | Módulos                                                                              | Obs.         |
|---------|--------------------------------------------------------------------------------------|--------------|
| **L0**  | `mpas_atm_types`, `mpas_cap_utils`                                                   |              |
|         | `mpi_allreduce_r8`, `mpi_allreduce_i4`, `mpi_allreduce_wrappers` (`src/shared/`)    |              |
| **L1**  | `mpas_cap_config`, `mpas_atm_model`, `mpas_cap_netcdf`                               |              |
| **L2**  | `mpas_atm_wrappers`, `mpas_cap_methods`                                              |              |
| **L3**  | `mpas_cap_MONAN`                                                                     | `[FORCE]`    |
| **L2-MED** | `med_cap_types`, `med_cap_netcdf`, `med_cap_methods`, `med_bulk_ncar`             | base de tipos primeiro |
| **L3-MED** | `MED_cap_MONAN`, `DATM_cap`, `DOCN_cap`, `docn_cap_netcdf`, `mom_cap_MONAN`      | `[FORCE]`    |
| **L4**  | `esm_MONAN`                                                                          |              |
| **L5**  | `esmApp_MONAN` → `bin/esmApp`                                                        |              |

> `mpas_cap_MONAN` e `MED_cap_MONAN` são recompilados incondicionalmente
> (alvo `FORCE`) para manter os `.mod` sincronizados em qualquer estado do build.
>
> `med_cap_types` não depende de nenhum módulo interno — apenas de ESMF.
> Os demais módulos MED dependem de `med_cap_types`; `MED_cap_MONAN` depende dos quatro.
>
> Variáveis de diretório disponíveis em `make printenv`:
> `ATM_DIR`, `OCN_DIR`, `MEDIATOR_DIR`, `DRIVER_DIR`, `MAIN_DIR`, `SHARED_DIR`, `UPSTREAM_DIR`.

---

## 8. Configuração — nuopc.input

Namelist Fortran padrão. Grupos lidos por `mpas_cap_config_mod`.
Grupos omitidos assumem defaults do módulo.

### Grupos do namelist

| Grupo             | Parâmetros principais                                  |
|-------------------|--------------------------------------------------------|
| `&nuopc_driver`   | `start_date`, `stop_date`, `dt_coupling`, `dt_atm`     |
| `&nuopc_mode`     | `use_datm`, `use_docn`, `use_med_to_mpas`              |
| `&nuopc_atm`      | `mesh_atm`, `config_dir`, `write_diag`                 |
| `&nuopc_netcdf`   | `write_netcdf`, `output_dir`, `grid_res_deg`           |
| `&nuopc_atm_bnd`  | `sst_default`, `ice_fraction_default`, `zorl_default`  |
| `&nuopc_docn`     | `docn_mode`, SST/gelo/correntes, `write_import_diag`   |
| `&nuopc_ocn`      | `mesh_ocn`, `use_mommesh`, `restart_n`                 |

> `&nuopc_docn` é lido **incondicionalmente** pelo Fortran, independente de
> `use_docn`. O parâmetro `write_import_diag` controla a escrita de
> diagnóstico nos dois modos OCN.

> `stop_ymd` / `stop_tod` do MOM6 **não** são declarados aqui: calculados
> automaticamente por `esm.F90` a partir do `stopTime` ESMF e passados via
> `NUOPC_CompAttributeSet`.

### Exemplo — 24 h com MOM6 dinâmico (Fase 2)

```fortran
&nuopc_driver
  start_date  = '2026-03-29'
  stop_date   = '2026-03-30'
  dt_coupling = 3600          ! [s] — múltiplo de dt_atm
  dt_atm      = 60            ! [s] — config_dt em namelist.atmosphere
  log_dir     = 'logs'
/

&nuopc_mode
  use_datm        = .false.   ! .true. → DATM JRA55
  use_docn        = .false.   ! .true. → DOCN OISST
  use_med_to_mpas = .true.    ! obrigatório quando use_docn=.false.
/
```

---

## 9. Execução

```bash
bash run/run_esmApp.jaci                        # 4 PETs, pesqextra, 1 h
bash run/run_esmApp.jaci -n 128                 # 128 PETs
bash run/run_esmApp.jaci -n 512 -w 02:00:00    # 512 PETs, 2 h
bash run/run_esmApp.jaci --compile -n 4         # make rebuild + qsub
bash run/run_esmApp.jaci --check                # valida pré-requisitos
bash run/run_esmApp.jaci -q pesqmini -w 00:30:00
```

O script detecta o ambiente via `PBS_O_WORKDIR`:

- **Login node:** gera `esmApp-integrado.pbs` e executa `qsub`.
- **Dentro do job PBS:** carrega módulos, faz `source run/setenv-gnu.bash`
  e executa `mpirun`.

### Escalabilidade validada (Jaci — Cray XD 2000)

| PETs | Nós           | Experimento |
|-----:|---------------|-------------|
|    4 | login serial  | 4.2         |
|   64 | Turin         | 4.3         |
|  128 | Turin         | 4.4         |
|  512 | multi-nó      | 4.5         |

---

## 10. Saídas e Diagnósticos

| Arquivo / Diretório               | Conteúdo                                              |
|-----------------------------------|-------------------------------------------------------|
| `bin/esmApp`                      | Executável                                            |
| `logs/esmApp_run.log`             | Stdout/stderr do mpirun                               |
| `logs/PET*.esmApp.log`            | Logs ESMF por PET (nível INFO)                        |
| `log.atmosphere.0000.d0001.out`   | Log interno do MONAN-A                                |
| `diag_export/monan_export_*.nc`   | Campos ATM exportados (1/`dt_coupling`)               |
| `diag_import/mom6_import_*.nc`    | Fluxos bulk MED→OCN (`write_import_diag=.true.`)      |
| `diag_import/monan2_import_*.nc`  | Campos OCN→ATM importados pelo MPAS                   |
| `diag_import/docn_import_*.nc`    | SST/gelo interpolados pelo DOCN (modo Fase 1)         |
| `diag_import/sst_ifrac_diag/`     | Diagnósticos de evolução de SST e Si_ifrac (v14.2)    |

### Controle do diagnóstico de importação

O diagnóstico é controlado por dois arquivos:

**`nuopc.input`** — parâmetro `write_import_diag` em `&nuopc_docn`:
ativa `mom6_import_*.nc`, `monan2_import_*.nc` e `docn_import_*.nc`.

**`mom6_output.nml`** — opcional, no diretório de execução:

```fortran
&mom6_output
  write_import_diag = .true.
  import_diag_dir   = 'diag_import'
/
```

> `write_import_diag=.true.` gera ~1,7 MB/passo para grade OISST 1440×720
> (≈ 41 MB/dia com `dt_coupling=3600 s`).
> Desativar em produção longa após validação.

---

## 11. Pós-processamento

```bash
# Campos exportados pelo MPAS (diag_export/)
python3 tools/postproc/postproc_monan2_export.py
python3 tools/postproc/postproc_monan2_export.py --stats --plot

# Fluxos bulk MED→OCN (diag_import/mom6_import_*.nc)
python3 tools/postproc/postproc_monan2_import.py
python3 tools/postproc/postproc_monan2_import.py --stats --check --plot

# Campos importados pelo MOM6 (diag_import/docn_import_*.nc)
python3 tools/postproc/postproc_mom6_import.py

# Sem dependência de servidor (standalone)
python3 tools/postproc/postproc_monan2_standalone.py

# Comparação estatística entre experimentos
python3 tools/postproc/analisa_comparacao.py

# Evolução temporal de SST e fração de gelo
python3 tools/postproc/analisa_sst_ifrac.py                          # todas as análises
python3 tools/postproc/analisa_sst_ifrac.py --timeseries --metrics   # rápido, sem mapas
python3 tools/postproc/analisa_sst_ifrac.py --anomaly --diff         # mapas de variação

# Animações dos campos de import
python3 tools/animation/anim_monan2_import.py
python3 tools/animation/anim_mom6_import.py
```

### Diagnóstico de evolução de SST e Si_ifrac — `analisa_sst_ifrac.py`

SST e fração de gelo variam pouco em relação à magnitude absoluta dos campos
(ΔT_tempo ≈ 0,1–2 K contra ΔT_espaço ≈ 32 K), tornando animações de mapa
praticamente estáticas. O script aplica quatro estratégias complementares que
amplificam o sinal temporal:

| Modo                  | Opção CLI        | O que detecta                                              |
|-----------------------|------------------|------------------------------------------------------------|
| Série temporal        | `--timeseries`   | Drift, aquecimento/resfriamento global; envelope min–max   |
| Anomalia Δ(t)         | `--anomaly`      | Onde o campo mudou em relação ao instante inicial (t₀)     |
| Diferença consecutiva | `--diff`         | Pulsos locais, frentes de gelo, instabilidades numéricas   |
| Métricas integradas   | `--metrics`      | Área de gelo (km²), SST pesada por área, congelamento/fusão|

**Saídas geradas** em `diag_import/sst_ifrac_diag/`:

| Arquivo                           | Conteúdo                                     |
|-----------------------------------|----------------------------------------------|
| `sst_ifrac_timeseries.png`        | Série temporal: min/média/max + desvio-padrão|
| `sst_ifrac_metricas.png`          | Área de gelo (km²), SST pesada, novo/fusão   |
| `anomalia_YYYYMMDD_HHMMSS.png`    | Δ(t) = campo(t) − campo(t₀) por passo        |
| `diff_consec_YYYYMMDD_HHMMSS.png` | δ(t) = campo(t) − campo(t−1) por passo       |

O script lê automaticamente **FONTE 1** (`monan2_import_*.nc`) ou, na sua
ausência, **FONTE 2** (`mom6_import_*.nc`) — mesma lógica dos demais scripts
de pós-processamento.

---

## 12. Modos de Operação

Seleção via `&nuopc_mode` em `nuopc.input`:

| `use_datm`  | `use_docn`  | `use_med_to_mpas` | Modo                     |
|:-----------:|:-----------:|:-----------------:|--------------------------|
| `.false.`   | `.false.`   | `.true.`          | MPAS + MOM6 (produção)   |
| `.false.`   | `.true.`    | `.false.`         | MPAS + DOCN (Fase 1)     |
| `.true.`    | `.false.`   | `.true.`          | DATM + MOM6 (teste OCN)  |
| `.true.`    | `.true.`    | `.false.`         | DATM + DOCN (teste MED)  |

> **Atenção:** `use_med_to_mpas=.true.` é **obrigatório** quando
> `use_docn=.false.`. Omitir causa acoplamento incorreto: o MPAS espera
> SST/gelo pelo caminho MED→ATM, mas o MOM6 não expõe esses campos pelo
> caminho direto OCN→ATM (Fase 1).

### Método de interpolação por conector

| Conector            | Método ESMF             | Condição                   |
|---------------------|-------------------------|----------------------------|
| OCN → ATM (Fase 1)  | Bilinear                | `use_med_to_mpas=.false.`  |
| MED → ATM (Fase 2)  | Conservativo + máscara  | `use_med_to_mpas=.true.`   |

---

## 13. Histórico de Versões

| Versão    | Data      | Mudanças                                                              |
|-----------|-----------|-----------------------------------------------------------------------|
| **14.2**  | Mai 2026  | Script `analisa_sst_ifrac.py` — diagnóstico de evolução temporal de SST e Si_ifrac: |
|           |           | · série temporal min/média/max/std                                    |
|           |           | · anomalia Δ(t) = campo(t) − campo(t₀) com escala divergente         |
|           |           | · diferença consecutiva δ(t) = campo(t) − campo(t−1)                 |
|           |           | · métricas integradas: área de gelo (km²), SST pesada, fusão/novo    |
|           |           | · README.md revisado: diagramação, seções 3, 4, 10, 11 e histórico   |
| **14.1**  | Mai 2026  | Reorganização da estrutura de diretórios:                             |
|           |           | · `src/shared/` criado para `mpi_allreduce_*.F90` e `time_utils.F90` |
|           |           | · `src/caps/ocean/upstream/` para fontes upstream MOM6 (só leitura)  |
|           |           | · `DATM_cap.F90` corrigido para `ATM_DIR` (era `OCN_DIR`)            |
|           |           | · `DOCN_cap.F90`, `docn_cap_netcdf.F90`, `mom_cap_MONAN.F90`         |
|           |           |   corrigidos para `OCN_DIR` (eram `ATM_DIR`)                         |
|           |           | · Scripts Python movidos para `tools/postproc/` e `tools/animation/` |
|           |           | · Scripts de ambiente e execução movidos para `run/`                  |
|           |           | · Documentação consolidada em `doc/`                                  |
| **14.0**  | Mai 2026  | Reorganização de responsabilidades nos fontes (Passos 1–7):           |
|           |           | · `MED_cap.F90` dividido em 5 módulos especializados                  |
|           |           | · `med_cap_types.F90` — tipos, constantes, listas de campos           |
|           |           | · `med_bulk_ncar.F90` — física bulk NCAR + Charnock/Smith             |
|           |           | · `med_cap_methods.F90` — utilitários ESMF/regrid do mediador         |
|           |           | · `med_cap_netcdf.F90` — diagnóstico NetCDF MED→OCN                   |
|           |           | · `mpas_cap_netcdf.F90` recebeu rotinas de diagnóstico import         |
|           |           | · `docn_cap_netcdf.F90` extraído de `DOCN_cap.F90`                    |
|           |           | · `MED_cap.F90` reduzido de 2.872 → 1.651 linhas (−42%)              |
| **13.0**  | Mai 2026  | `mom_cap_MONAN.o` em `ALL_OBJS`; fix linker MOM6                      |
| **12.0**  | Mai 2026  | `mpi_allreduce_wrappers` em módulo isolado (fix W1 gfortran)          |
| **11.0**  | Mai 2026  | `mom_cap_MONAN.F90` movido para `src/caps/atmos/`                     |
| **9.3**   | Mai 2026  | Makefile reestruturado; `DOCN_cap` movido para `src/caps/atmos/`      |
| **9.0**   | Abr 2026  | OCN DOCN → MOM6+SIS2 dinâmico; `stop_ymd` automático                 |
| **7.2**   | Abr 2026  | Fix double-free `ownedElemCoords` ESMF 8.9.1                          |
| **7.1**   | Abr 2026  | `mpas_atm_resize` eliminado; decomposições ESMF ≠ MPAS                |
| **7.0**   | Abr 2026  | `stop_ymd`/`stop_tod` via `NUOPC_CompAttributeSet`                    |
| **6.0**   | Mar 2026  | Mediador bulk NCAR; Large & Yeager (2009)                             |

---

## 14. Referências

- **ESMF/NUOPC** — <https://earthsystemmodeling.org>
- **MPAS-A** — Skamarock et al. (2021). *NCAR Tech. Note NCAR/TN-556+STR*.
- **MOM6** — Adcroft et al. (2019). *JAMES*, 11(10), 3167–3211.
  <https://doi.org/10.1029/2019MS001726>
- **Bulk NCAR** — Large & Yeager (2009). *Clim. Dyn.*, 33(2–3), 341–364.
- **Rugosidade Charnock/Smith** — Smith (1988). *J. Geophys. Res.*, 93(C12).
- **OISST v2.1** — Huang et al. (2021). *J. Climate*, 34(8), 2923–2939.
- **Projeto MONAN** — <https://monanadmin.github.io/monan-cc-docs/>

---

**GT Acoplamento de Modelos — INPE/CGCT/DIMNT**
Rodovia Presidente Dutra, Km 40 — Cachoeira Paulista, SP
