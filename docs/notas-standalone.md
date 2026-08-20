# Instalador standalone — Coupler-Install

**Projeto:** MONAN-Coupler (MONAN-A 2.0 × MOM6+SIS2 / NUOPC-ESMF 8.9.1)
**INPE / CGCT / DIMNT — GT Acoplamento de Modelos**
**Data:** Jun 2026

## Objetivo

Tornar os scripts de instalação **autônomos (standalone)**, em **repositório
GitHub próprio**, separado do sistema acoplado — que passa a ser baixado de forma
**recursiva** (submódulos) a partir da branch `develop`.

## Arquitetura: dois repositórios

| Repositório            | Conteúdo                                                        |
|:-----------------------|:---------------------------------------------------------------|
| `MONAN-Coupler`        | Sistema acoplado + modelos como **submódulos** (`models/atmos/MONAN-Model`, `models/ocean/MOM6-examples`) declarados no `.gitmodules`. |
| `Coupler-Install`| Scripts de instalação (este repositório).                      |

**Uso (um comando):**

```bash
git clone https://github.com/GTA-DIMNT-CPTEC/Coupler-Install.git
cd Coupler-Install
bash install.bash          # clona o sistema (recursivo, develop) E instala
```

## Modificações nos scripts (o que viabiliza o standalone)

- **`COUPLER_ROOT` desacoplado da localização do script.** Antes derivado de
  `SCRIPT_DIR/..` (exigia os scripts dentro do acoplador). Agora vem do ambiente
  (definido pelo `install.bash`) ou assume `./MONAN-Coupler`, via
  `resolve_coupler_root` (valida e exporta).
- **Download recursivo + submódulos.** `clone_recursive_if_missing`
  (`git clone --recursive --branch develop`, idempotente) e `ensure_model_tree`
  (inicializa submódulo se faltar; *fallback* de clone direto no modo legado).
- **Resolvedores tolerantes a layout.** `resolve_site_env` e
  `resolve_mkmf_template` (sobre `find_first_path`) procuram `site-jaci.bash` e
  `cray-gnu-monan.mk` em vários locais (`$VAR` → `sites/`/`templates/` → raiz →
  `install/` → cópia no acoplador), com mensagens de erro que listam onde
  procuraram.
- **Preflight no `install.bash`.** Confere sítio e template **antes** do clone
  demorado, reunindo todos os problemas de uma vez.
- **Config de sítio para sessões futuras.** O `install.bash` copia
  `site-jaci.bash` para `<COUPLER_ROOT>/install/`, de modo que o
  `source run/setenv-gnu.bash` do acoplador funcione sem o instalador presente.

## Organização do diretório

```
Coupler-Install/
├── install.bash            ← ★ entrada: baixa (git recursivo) E instala
├── build.bash              ← só as 3 etapas (sistema já baixado)
├── include.bash            ← biblioteca de funções (sourced)
├── 1-monan.bash            ← etapa 1 — MONAN-A 2.0
├── 2-mom.bash              ← etapa 2 — MOM6+SIS2+FMS
├── 3-coupler.bash          ← etapa 3 — linka bin/esmApp
├── sites/site-jaci.bash    ← configuração por máquina
├── templates/cray-gnu-monan.mk
├── README.md
└── .gitignore              ← ignora o MONAN-Coupler clonado pelo install.bash
```

## Renomeações (clareza de propósito)

| Antigo              | Novo           | Motivo                                            |
|:--------------------|:---------------|:--------------------------------------------------|
| `install-libs.bash` | `include.bash` | É *sourced*, não executado.                       |
| `bootstrap.bash`    | `install.bash` | Baixa **e** instala (entrada do usuário).         |
| `install-all.bash`  | `build.bash`   | Só compila as 3 etapas (sistema já baixado).      |

## Arquivos novos / propostos

- `install.bash` — ponto de entrada (download recursivo + preflight + instalação).
- `include.bash` — funções comuns + resolvedores de caminho.
- `sites/`, `templates/`, `README.md`, `.gitignore`.
- `.gitmodules` **proposto** para o repositório `MONAN-Coupler` (registra os dois
  modelos como submódulos, habilitando o clone recursivo).

## Verificação

- `bash -n` aprovado em todos os scripts.
- Resolvedores (`COUPLER_ROOT`, sítio, template) e fluxo de submódulos testados
  com repositórios git locais (clone recursivo, init de submódulo, idempotência).
