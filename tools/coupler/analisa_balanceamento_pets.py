#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analisa_balanceamento_pets.py
==============================================================================
Extrai os tempos de parede por componente (MPAS/OCN/MED) a partir dos logs
ESMF (`logs/PET*.esmApp.log`) do sistema acoplado MONAN-A 2.0 x MOM6+SIS2, e
sugere uma partição de PETs balanceada para o modo concorrente
(`&nuopc_petlayout`, `atm_pet_count` / `ocn_pet_count`).

INPE / CGCT / DIMNT - GT Acoplamento de Modelos - v13.1

--------------------------------------------------------------------------
POR QUE "TEMPO TOTAL", E NÃO "TEMPO POR CHAMADA x NÚMERO DE PASSOS"
--------------------------------------------------------------------------
Cada linha de log ESMF marca o início/fim de uma fase com "intro."/"extro.".
A fase `Run` de um componente NÃO corresponde 1:1 a um passo de acoplamento:
o MOM6 subcicla internamente (na prática observamos ~301 pares Run
intro/extro do OCN para 24 passos de acoplamento), enquanto o MPAS costuma
ter uma correspondência mais próxima de 1 chamada por passo. Por isso este
script SEMPRE soma a duração de TODAS as chamadas Run de um componente
(métrica robusta, independente de quantas sub-chamadas internas existirem) e
só then divide pelo número de passos de acoplamento — que é lido do log de
execução (`esmApp_run.log`, campo "Passos (est.)") ou informado via
`--steps`. Nunca assume que "contagem de intro/extro = passos".

--------------------------------------------------------------------------
DETECÇÃO DA PARTIÇÃO DE PETs (dois caminhos, com fallback automático)
--------------------------------------------------------------------------
1) Leitura direta da linha que `esm.F90` grava no log (nível INFO):
     "ESM: modo CONCURRENT - ATM=PET[0..3] OCN=PET[4..7] MED=todos"
   Aceita tanto "-" quanto "—" antes de "ATM=PET".
2) Se essa linha não existir (por exemplo, com o log ESMF configurado como
   `ESMF_LOGKIND_Multi_On_Error`, que suprime mensagens de nível INFO — a
   configuração recomendada para produção), a partição é INFERIDA a partir
   de quais PETs efetivamente reportam atividade de MPAS e quais reportam
   atividade de OCN: conjuntos disjuntos => concorrente; conjuntos idênticos
   => sequencial.

--------------------------------------------------------------------------
FÓRMULA DE REBALANCEAMENTO
--------------------------------------------------------------------------
Assumindo escalonamento aproximadamente linear (tempo ~ trabalho / nº PETs),
o "trabalho" de cada componente é estimado como:

    W_atm = tempo_total_ATM  x  nº_PETs_ATM_atual
    W_ocn = tempo_total_OCN  x  nº_PETs_OCN_atual

e a nova partição, para um total de PETs `N`, que equilibra
t_ATM_novo == t_OCN_novo, é:

    atm_pet_count_novo = round(N x W_atm / (W_atm + W_ocn))
    ocn_pet_count_novo = N - atm_pet_count_novo

Isso é uma APROXIMAÇÃO de primeira ordem (equivale ao heurístico
`atm_pet_frac` citado na configuração do projeto) — o resultado deve ser
validado com uma nova execução concorrente real, não tomado como exato.

--------------------------------------------------------------------------
USO
--------------------------------------------------------------------------
    # Uso básico (a partir do diretório do experimento):
    python3 analisa_balanceamento_pets.py

    # Apontando explicitamente o diretório de logs e o total de passos:
    python3 analisa_balanceamento_pets.py --logdir logs --steps 24

    # Exportando o detalhe por passo (CSV) e um resumo (JSON) e gráfico:
    python3 analisa_balanceamento_pets.py --csv-out tempos.csv \
        --json-out resumo.json --plot-out balanceamento.png

    # Sugerindo partição para um total de PETs diferente do observado:
    python3 analisa_balanceamento_pets.py --target-pets 128

    # Comparando com uma calibração anterior (JSON salvo de uma rodada prévia):
    python3 analisa_balanceamento_pets.py --baseline-json calib_anterior.json

Ver `python3 analisa_balanceamento_pets.py --help` para todas as opções.
==============================================================================
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


# ──────────────────────────────────────────────────────────────────────────
# Expressões regulares
# ──────────────────────────────────────────────────────────────────────────

# "20260705 175540.252 INFO             PET0 MPAS: Run intro."
_RE_LINE = re.compile(
    r"^(?P<date>\d{8})\s+(?P<time>\d{6}\.\d+)\s+\S+\s+PET(?P<pet>\d+)\s+(?P<msg>.*)$"
)

# "MPAS: Run intro."  /  "OCN: InitializeIPDvXp08 extro."
_RE_PHASE = re.compile(
    r"^(?P<comp>MPAS|OCN|MED):\s*(?P<phase>[A-Za-z0-9]+)\s+(?P<edge>intro|extro)\.?\s*$"
)

# "ESM: modo CONCURRENT - ATM=PET[0..3] OCN=PET[4..7] MED=todos"  (aceita - ou —)
_RE_MODE_CONCURRENT = re.compile(r"modo\s+CONCURRENT", re.IGNORECASE)
_RE_MODE_SEQUENTIAL = re.compile(r"modo\s+SEQUENTIAL", re.IGNORECASE)
_RE_PET_RANGE = re.compile(
    r"ATM=PET\[(\d+)\.\.(\d+)\]\s+OCN=PET\[(\d+)\.\.(\d+)\]"
)

# "24 passo(s) de acoplamento de 3600 s"  /  "Passos (est.)  =    24"
_RE_STEPS_A = re.compile(r"(\d+)\s+passo\(s\)\s+de\s+acoplamento", re.IGNORECASE)
_RE_STEPS_B = re.compile(r"Passos\s*\(est\.\)\s*=?\s*(\d+)", re.IGNORECASE)


def _parse_ts(date: str, time_: str) -> datetime:
    """Converte 'AAAAMMDD' + 'HHMMSS.mmm' em datetime (ordem cronológica)."""
    return datetime.strptime(f"{date} {time_}", "%Y%m%d %H%M%S.%f")


# ──────────────────────────────────────────────────────────────────────────
# Estruturas de dados
# ──────────────────────────────────────────────────────────────────────────

@dataclass
class ComponentTiming:
    """Durações (em segundos) de cada par intro/extro de um componente em um PET."""
    run_durations: List[float] = field(default_factory=list)
    init_total_s: float = 0.0

    @property
    def run_total_s(self) -> float:
        return sum(self.run_durations)

    @property
    def run_count(self) -> int:
        return len(self.run_durations)


@dataclass
class ParseResult:
    # timing[component][pet] = ComponentTiming
    timing: Dict[str, Dict[int, ComponentTiming]] = field(
        default_factory=lambda: defaultdict(dict)
    )
    mode_announced: Optional[str] = None          # "concurrent" | "sequential" | None
    atm_range: Optional[Tuple[int, int]] = None    # (primeiro, último) PET do ATM
    ocn_range: Optional[Tuple[int, int]] = None
    n_files: int = 0
    incomplete_pairs: int = 0                      # intro sem extro correspondente (log truncado)


# ──────────────────────────────────────────────────────────────────────────
# Parsing
# ──────────────────────────────────────────────────────────────────────────

def parse_logs(logdir: Path, pattern: str) -> ParseResult:
    """Varre todos os arquivos PET*.esmApp.log e extrai tempos por componente."""
    result = ParseResult()
    files = sorted(logdir.glob(pattern))
    if not files:
        raise FileNotFoundError(
            f"Nenhum arquivo casando com '{pattern}' em {logdir!s}"
        )
    result.n_files = len(files)

    for fpath in files:
        # Estado local: timestamp pendente de 'intro' por (componente, fase)
        pending: Dict[Tuple[str, str], datetime] = {}
        pet_id: Optional[int] = None

        with fpath.open("r", errors="replace") as fh:
            for raw in fh:
                m = _RE_LINE.match(raw)
                if not m:
                    continue
                pet_id = int(m.group("pet"))
                msg = m.group("msg")

                # Detecta anúncio explícito de modo/partição (nível INFO)
                if result.mode_announced is None:
                    if _RE_MODE_CONCURRENT.search(msg):
                        result.mode_announced = "concurrent"
                        rng = _RE_PET_RANGE.search(msg)
                        if rng:
                            a0, a1, o0, o1 = (int(x) for x in rng.groups())
                            result.atm_range = (a0, a1)
                            result.ocn_range = (o0, o1)
                    elif _RE_MODE_SEQUENTIAL.search(msg):
                        result.mode_announced = "sequential"

                pm = _RE_PHASE.match(msg)
                if not pm:
                    continue
                comp, phase, edge = pm.group("comp"), pm.group("phase"), pm.group("edge")
                ts = _parse_ts(m.group("date"), m.group("time"))
                key = (comp, phase)

                if edge == "intro":
                    if key in pending:
                        # 'intro' repetido sem 'extro' anterior: log truncado/erro.
                        result.incomplete_pairs += 1
                    pending[key] = ts
                else:  # extro
                    t0 = pending.pop(key, None)
                    if t0 is None:
                        # 'extro' órfão (log começou no meio de uma fase) - ignora.
                        continue
                    dt = (ts - t0).total_seconds()
                    if dt < 0:
                        # Relógio não-monotônico (não deveria ocorrer) - ignora.
                        continue
                    ct = result.timing[comp].setdefault(pet_id, ComponentTiming())
                    if phase.lower().startswith("initialize"):
                        ct.init_total_s += dt
                    elif phase == "Run":
                        ct.run_durations.append(dt)

        # 'intro' sem 'extro' remanescente ao fim do arquivo = passo incompleto
        # (ex.: log de uma execução que travou/foi cancelada por tempo).
        result.incomplete_pairs += len(pending)

    return result


def detect_pet_groups(
    result: ParseResult,
) -> Tuple[str, Set[int], Set[int]]:
    """
    Determina o modo (concurrent/sequential) e os conjuntos de PETs de
    ATM e OCN, priorizando o anúncio explícito do log e caindo para
    inferência (a partir de quais PETs reportam MPAS/OCN) quando ausente.
    """
    atm_pets_observed = set(result.timing.get("MPAS", {}).keys())
    ocn_pets_observed = set(result.timing.get("OCN", {}).keys())

    if result.mode_announced == "concurrent" and result.atm_range and result.ocn_range:
        a0, a1 = result.atm_range
        o0, o1 = result.ocn_range
        return "concurrent", set(range(a0, a1 + 1)), set(range(o0, o1 + 1))

    if result.mode_announced == "sequential":
        all_pets = atm_pets_observed | ocn_pets_observed
        return "sequential", set(all_pets), set(all_pets)

    # Fallback: inferência pura a partir da atividade observada.
    if atm_pets_observed and ocn_pets_observed:
        if atm_pets_observed.isdisjoint(ocn_pets_observed):
            return "concurrent (inferido)", atm_pets_observed, ocn_pets_observed
        if atm_pets_observed == ocn_pets_observed:
            return "sequential (inferido)", atm_pets_observed, ocn_pets_observed
        # Sobreposição parcial: situação atípica, reporta como observado.
        return "indeterminado (sobreposição parcial)", atm_pets_observed, ocn_pets_observed

    return "indeterminado (dados insuficientes)", atm_pets_observed, ocn_pets_observed


def detect_step_count(run_log: Optional[Path]) -> Optional[int]:
    """Tenta obter o número de passos de acoplamento do log de execução."""
    if run_log is None or not run_log.is_file():
        return None
    text = run_log.read_text(errors="replace")
    for rx in (_RE_STEPS_A, _RE_STEPS_B):
        m = rx.search(text)
        if m:
            return int(m.group(1))
    return None


def find_run_log(logdir: Path) -> Optional[Path]:
    """Procura esmApp_run.log em locais usuais (mesmo dir, ou dir pai)."""
    candidates = [
        logdir / "esmApp_run.log",
        logdir.parent / "esmApp_run.log",
        logdir.parent / "logs" / "esmApp_run.log",
    ]
    for c in candidates:
        if c.is_file():
            return c
    return None


# ──────────────────────────────────────────────────────────────────────────
# Métricas e sugestão de partição
# ──────────────────────────────────────────────────────────────────────────

@dataclass
class ComponentSummary:
    n_pets: int
    total_s: float          # tempo total (bottleneck = max entre os PETs do grupo)
    per_step_s: Optional[float]
    per_pet_totals: Dict[int, float]
    run_calls_per_pet: Dict[int, int]
    init_s_max: float


def summarize_component(
    result: ParseResult, comp: str, pets: Set[int], n_steps: Optional[int]
) -> ComponentSummary:
    per_pet_totals: Dict[int, float] = {}
    run_calls: Dict[int, int] = {}
    init_vals: List[float] = []
    comp_data = result.timing.get(comp, {})
    for pet in sorted(pets):
        ct = comp_data.get(pet)
        if ct is None:
            per_pet_totals[pet] = 0.0
            run_calls[pet] = 0
            continue
        per_pet_totals[pet] = ct.run_total_s
        run_calls[pet] = ct.run_count
        init_vals.append(ct.init_total_s)

    # O tempo de parede do GRUPO é limitado pelo PET mais lento (bottleneck).
    total_s = max(per_pet_totals.values()) if per_pet_totals else 0.0
    per_step = (total_s / n_steps) if (n_steps and n_steps > 0) else None
    init_max = max(init_vals) if init_vals else 0.0

    return ComponentSummary(
        n_pets=len(pets),
        total_s=total_s,
        per_step_s=per_step,
        per_pet_totals=per_pet_totals,
        run_calls_per_pet=run_calls,
        init_s_max=init_max,
    )


def suggest_partition(
    atm: ComponentSummary, ocn: ComponentSummary, target_pets: int
) -> Tuple[int, int]:
    """
    Sugere (atm_pet_count, ocn_pet_count) que tende a igualar t_ATM e t_OCN,
    assumindo escalonamento aproximadamente linear com o nº de PETs.
    """
    w_atm = atm.total_s * max(atm.n_pets, 1)
    w_ocn = ocn.total_s * max(ocn.n_pets, 1)
    if (w_atm + w_ocn) <= 0:
        # Sem dado de tempo utilizável: divide ao meio.
        n_atm = (target_pets + 1) // 2
    else:
        n_atm = round(target_pets * w_atm / (w_atm + w_ocn))
    n_atm = max(1, min(target_pets - 1, n_atm))
    n_ocn = target_pets - n_atm
    return n_atm, n_ocn


# ──────────────────────────────────────────────────────────────────────────
# Saída (console, CSV, JSON, gráfico)
# ──────────────────────────────────────────────────────────────────────────

def fmt_s(x: Optional[float]) -> str:
    if x is None:
        return "N/D"
    return f"{x:8.3f} s"


def print_report(
    mode: str,
    atm_pets: Set[int],
    ocn_pets: Set[int],
    atm: ComponentSummary,
    ocn: ComponentSummary,
    med_total_s: float,
    n_steps: Optional[int],
    target_pets: int,
    n_atm_new: int,
    n_ocn_new: int,
    incomplete_pairs: int,
    baseline: Optional[dict],
) -> None:
    bar = "=" * 70
    print(bar)
    print("  Análise de balanceamento de PETs - MONAN-A x MOM6+SIS2")
    print(bar)
    print(f"  Modo detectado       : {mode}")
    print(f"  PETs do ATM (MPAS)   : {sorted(atm_pets)}")
    print(f"  PETs do OCN (MOM6)   : {sorted(ocn_pets)}")
    print(f"  Passos de acoplamento: {n_steps if n_steps else 'N/D (use --steps)'}")
    if incomplete_pairs:
        print(
            f"  AVISO: {incomplete_pairs} par(es) intro/extro incompleto(s) "
            f"encontrados (log truncado/execução cancelada) - ignorados."
        )
    print("-" * 70)
    print(f"  {'Componente':<12}{'PETs':>6}{'Tempo total':>16}{'Tempo/passo':>16}{'Chamadas Run':>16}")
    print(
        f"  {'MPAS (ATM)':<12}{atm.n_pets:>6}{fmt_s(atm.total_s):>16}"
        f"{fmt_s(atm.per_step_s):>16}{sum(atm.run_calls_per_pet.values()):>16}"
    )
    print(
        f"  {'OCN (MOM6)':<12}{ocn.n_pets:>6}{fmt_s(ocn.total_s):>16}"
        f"{fmt_s(ocn.per_step_s):>16}{sum(ocn.run_calls_per_pet.values()):>16}"
    )
    print(f"  {'MED':<12}{'todos':>6}{fmt_s(med_total_s):>16}{'':>16}{'':>16}")
    print("-" * 70)

    if atm.total_s > 0 and ocn.total_s > 0:
        slower = "MPAS (ATM)" if atm.total_s >= ocn.total_s else "OCN (MOM6)"
        ratio = max(atm.total_s, ocn.total_s) / min(atm.total_s, ocn.total_s)
        imbalance_pct = (ratio - 1.0) * 100.0
        print(f"  Componente mais lento : {slower}  (razão {ratio:.2f}x)")
        print(f"  Desbalanceamento      : {imbalance_pct:5.1f}% de tempo ocioso no mais rápido")
        if "concurrent" in mode:
            wallclock_concurrent = max(atm.total_s, ocn.total_s)
            wallclock_serial_equiv = atm.total_s + ocn.total_s
            ganho_pct = (1 - wallclock_concurrent / wallclock_serial_equiv) * 100.0
            print(
                f"  Ganho vs. soma serial : {ganho_pct:5.1f}%  "
                f"(max({atm.total_s:.1f}, {ocn.total_s:.1f}) vs. soma {wallclock_serial_equiv:.1f} s)"
            )
    print("-" * 70)
    print(f"  Sugestão de partição para {target_pets} PETs totais:")
    print(f"    atm_pet_count = {n_atm_new}")
    print(f"    ocn_pet_count = {n_ocn_new}")
    if "sequential" in mode:
        print(
            "  (base: custos medidos em modo sequencial, extrapolados linearmente\n"
            "   para a nova partição - validar com uma execução concorrente real.)"
        )
    else:
        n_atm_cur, n_ocn_cur = atm.n_pets, ocn.n_pets
        if (n_atm_cur, n_ocn_cur) == (n_atm_new, n_ocn_new):
            print("  (a partição atual já está aproximadamente balanceada.)")
        else:
            print(f"  (partição atual: atm={n_atm_cur} ocn={n_ocn_cur} - ajuste sugerido acima.)")

    if baseline:
        print("-" * 70)
        print("  Comparação com baseline salvo:")
        b_atm = baseline.get("atm_total_s")
        b_ocn = baseline.get("ocn_total_s")
        if b_atm is not None:
            delta = atm.total_s - b_atm
            print(f"    MPAS: {b_atm:.3f} s -> {atm.total_s:.3f} s  (Δ {delta:+.3f} s)")
        if b_ocn is not None:
            delta = ocn.total_s - b_ocn
            print(f"    OCN : {b_ocn:.3f} s -> {ocn.total_s:.3f} s  (Δ {delta:+.3f} s)")
    print(bar)


def write_csv(path: Path, result: ParseResult, atm_pets: Set[int], ocn_pets: Set[int]) -> None:
    """Exporta o detalhe de cada chamada Run (passo interno) por PET/componente."""
    import csv

    with path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["componente", "pet", "grupo", "indice_chamada", "duracao_s"])
        for comp in ("MPAS", "OCN", "MED"):
            for pet, ct in sorted(result.timing.get(comp, {}).items()):
                grupo = (
                    "ATM" if pet in atm_pets and comp != "OCN" else
                    "OCN" if pet in ocn_pets and comp != "MPAS" else
                    "MED"
                )
                for i, dur in enumerate(ct.run_durations):
                    w.writerow([comp, pet, grupo, i, f"{dur:.6f}"])


def write_json(
    path: Path,
    mode: str,
    atm: ComponentSummary,
    ocn: ComponentSummary,
    med_total_s: float,
    n_steps: Optional[int],
    n_atm_new: int,
    n_ocn_new: int,
) -> None:
    payload = {
        "mode": mode,
        "n_steps": n_steps,
        "atm_n_pets": atm.n_pets,
        "atm_total_s": atm.total_s,
        "atm_per_step_s": atm.per_step_s,
        "ocn_n_pets": ocn.n_pets,
        "ocn_total_s": ocn.total_s,
        "ocn_per_step_s": ocn.per_step_s,
        "med_total_s": med_total_s,
        "suggested_atm_pet_count": n_atm_new,
        "suggested_ocn_pet_count": n_ocn_new,
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False))


def write_plot(path: Path, atm: ComponentSummary, ocn: ComponentSummary) -> None:
    """Gera um gráfico de barras comparando o tempo total ATM x OCN por PET."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(7, 4))
    pets_atm = sorted(atm.per_pet_totals)
    pets_ocn = sorted(ocn.per_pet_totals)
    ax.bar(
        [f"ATM\nPET{p}" for p in pets_atm],
        [atm.per_pet_totals[p] for p in pets_atm],
        color="#1F9E77",
        label="MPAS (ATM)",
    )
    ax.bar(
        [f"OCN\nPET{p}" for p in pets_ocn],
        [ocn.per_pet_totals[p] for p in pets_ocn],
        color="#2E7BC4",
        label="OCN (MOM6)",
    )
    ax.set_ylabel("Tempo total em Run (s)")
    ax.set_title("Tempo de parede por PET - MPAS x MOM6")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    plt.xticks(rotation=90, fontsize=7)
    plt.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


# ──────────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────────

def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Extrai tempos por componente/passo dos logs ESMF do sistema "
            "acoplado MONAN-A x MOM6+SIS2 e sugere uma partição de PETs "
            "balanceada para o modo concorrente."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--logdir", type=Path, default=Path("logs"),
                    help="Diretório com os PET*.esmApp.log (padrão: ./logs)")
    p.add_argument("--pattern", default="PET*.esmApp.log",
                    help="Padrão glob dos arquivos de log (padrão: PET*.esmApp.log)")
    p.add_argument("--steps", type=int, default=None,
                    help="Número de passos de acoplamento (se omitido, tenta "
                         "detectar automaticamente em esmApp_run.log)")
    p.add_argument("--run-log", type=Path, default=None,
                    help="Caminho explícito do esmApp_run.log (para detectar --steps)")
    p.add_argument("--target-pets", type=int, default=None,
                    help="Total de PETs para a partição sugerida "
                         "(padrão: total de PETs observado nos logs)")
    p.add_argument("--csv-out", type=Path, default=None,
                    help="Exporta o detalhe de cada chamada Run para CSV")
    p.add_argument("--json-out", type=Path, default=None,
                    help="Exporta o resumo em JSON (útil como baseline futuro)")
    p.add_argument("--plot-out", type=Path, default=None,
                    help="Gera um gráfico PNG comparando o tempo por PET")
    p.add_argument("--baseline-json", type=Path, default=None,
                    help="Compara com um resumo JSON de uma calibração anterior")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)

    if not args.logdir.is_dir():
        print(f"ERRO: diretório de logs não encontrado: {args.logdir}", file=sys.stderr)
        return 2

    try:
        result = parse_logs(args.logdir, args.pattern)
    except FileNotFoundError as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 2

    mode, atm_pets, ocn_pets = detect_pet_groups(result)

    n_steps = args.steps
    if n_steps is None:
        run_log = args.run_log or find_run_log(args.logdir)
        n_steps = detect_step_count(run_log)

    atm = summarize_component(result, "MPAS", atm_pets, n_steps)
    ocn = summarize_component(result, "OCN", ocn_pets, n_steps)
    med_pets = set(result.timing.get("MED", {}).keys())
    med = summarize_component(result, "MED", med_pets, n_steps)

    target_pets = args.target_pets or (len(atm_pets | ocn_pets) or (atm.n_pets + ocn.n_pets))
    if target_pets < 2:
        print("AVISO: total de PETs insuficiente para sugerir partição concorrente.", file=sys.stderr)
        target_pets = max(target_pets, 2)

    n_atm_new, n_ocn_new = suggest_partition(atm, ocn, target_pets)

    baseline = None
    if args.baseline_json and args.baseline_json.is_file():
        baseline = json.loads(args.baseline_json.read_text())

    print_report(
        mode=mode,
        atm_pets=atm_pets,
        ocn_pets=ocn_pets,
        atm=atm,
        ocn=ocn,
        med_total_s=med.total_s,
        n_steps=n_steps,
        target_pets=target_pets,
        n_atm_new=n_atm_new,
        n_ocn_new=n_ocn_new,
        incomplete_pairs=result.incomplete_pairs,
        baseline=baseline,
    )

    if args.csv_out:
        write_csv(args.csv_out, result, atm_pets, ocn_pets)
        print(f"[csv]  detalhe por chamada salvo em: {args.csv_out}")
    if args.json_out:
        write_json(args.json_out, mode, atm, ocn, med.total_s, n_steps, n_atm_new, n_ocn_new)
        print(f"[json] resumo salvo em: {args.json_out}")
    if args.plot_out:
        write_plot(args.plot_out, atm, ocn)
        print(f"[plot] gráfico salvo em: {args.plot_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
