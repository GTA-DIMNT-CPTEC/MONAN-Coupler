#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analisa_balanceamento_pets.py
==============================================================================
Extrai os tempos de parede por componente (MPAS/OCN/ICE/MED) a partir dos logs
ESMF (`logs/PET*.esmApp.log`) do sistema acoplado MONAN-A 2.0 x MOM6+SIS2, e
sugere uma partição de PETs balanceada para o layout com split de comunicador
(`&nuopc_petlayout`: `atm_pet_count` / `ocn_pet_count` / `ice_pet_count`).

INPE / CGCT / DIMNT - Grupo de Trabalho para Acoplamento de Modelos - v14.21

--------------------------------------------------------------------------
ALTERAÇÕES (Set/2026) - COMPONENTE DE GELO
--------------------------------------------------------------------------
Até a v14.20 o script conhecia apenas MPAS, OCN e MED. Com `use_sis2_dynamic`
ligado, o SIS2 recebe um terceiro bloco de PETs, e o tempo dele não entrava na
tabela, nem no desbalanceamento, nem na divisão sugerida; os PETs do gelo
apenas não apareciam. Passaram a ser tratados:

  - a faixa `ICE=PET[a..b]`, que o `esm.F90` acrescenta na MESMA linha de
    layout depois do bloco de oceano, quando o gelo está ativo;
  - o rótulo `ICE` nos pares `Run intro.`/`Run extro.`;
  - a inclusão do componente na tabela, no cálculo do mais lento e do mais
    rápido, no ganho contra a soma serial, no CSV, no JSON e no gráfico;
  - a divisão de PETs entre TRÊS componentes.

Um componente sem PETs atribuídos é tratado como AUSENTE, e não como presente
com tempo zero: some da tabela e da divisão. A distinção importa porque tempo
zero num componente presente é sintoma de log truncado, e merece aparecer.

A divisão de PETs passou a usar o método do maior resto sobre a quota cheia,
com piso de 1 PET por componente ativo. Com dois componentes o resultado é
idêntico ao da fórmula anterior; verificado contra o caso de referência.

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
O `&nuopc_petlayout` tem DOIS eixos ortogonais, e este script reporta os
dois separadamente:
  - `pet_layout`    (shared|split)          => os conjuntos de PETs de ATM,
                                               OCN e ICE são iguais ou
                                               disjuntos;
  - `coupling_mode` (sequential|concurrent) => os tempos de ATM e OCN podem
                                               ou não se sobrepor.

1) Leitura direta da linha que `esm.F90` grava no log (nível INFO), formato
   a partir da v14.20:
     "ESM: layout SPLIT (execucao SEQUENTIAL) - ATM=PET[0..5] OCN=PET[6..7] MED=todos"
     "ESM: layout SPLIT (execucao SEQUENTIAL) - ATM=PET[0..63] OCN=PET[64..67] ICE=PET[68..71] MED=todos"
     "ESM: layout SHARED (execucao CONCURRENT) - MPAS, MED e OCN em todos os PETs"
   O formato anterior (<= v14.19), em que os dois eixos eram um só, continua
   reconhecido para logs arquivados:
     "ESM: modo CONCURRENT - ATM=PET[0..3] OCN=PET[4..7] MED=todos"
   Aceita tanto "-" quanto "—" antes de "ATM=PET".
2) Se essa linha não existir (por exemplo, com o log ESMF configurado como
   `ESMF_LOGKIND_Multi_On_Error`, que suprime mensagens de nível INFO — a
   configuração recomendada para produção), o LAYOUT é INFERIDO a partir de
   quais PETs efetivamente reportam atividade de MPAS e quais reportam
   atividade de OCN: conjuntos disjuntos => split; conjuntos idênticos =>
   shared. A EXECUÇÃO não é inferida, porque sequential+split e
   concurrent+split produzem exatamente os mesmos conjuntos de PETs;
   ela é reportada como indeterminada, e o relatório omite a linha de ganho
   de wall-clock em vez de anunciar um ganho que talvez não exista.

--------------------------------------------------------------------------
FÓRMULA DE REBALANCEAMENTO
--------------------------------------------------------------------------
Assumindo escalonamento aproximadamente linear (tempo ~ trabalho / nº PETs),
o "trabalho" de cada componente ativo é estimado como:

    W_c = tempo_total_c  x  nº_PETs_c_atual        c em {ATM, OCN, ICE}

e a nova partição, para um total de PETs `N`, que tende a igualar os tempos
dos componentes ativos, é a quota proporcional

    quota_c = N x W_c / soma(W)

arredondada pelo método do maior resto, de modo que as contagens somem
exatamente `N`, com piso de 1 PET por componente. O piso existe porque o
arredondamento pode zerar um componente muito rápido, e o driver rejeita
contagem zero (ver a validação em mpas_cap_config.F90).

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

    # Com o gelo ativo, a saída traz uma terceira linha, ice_pet_count.
    # Nada precisa ser informado: o componente é detectado a partir dos logs.

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
    r"^(?P<comp>MPAS|OCN|ICE|MED):\s*(?P<phase>[A-Za-z0-9]+)\s+(?P<edge>intro|extro)\.?\s*$"
)

# A partir da v14.20 o driver anuncia os DOIS eixos separadamente:
#   "ESM: layout SPLIT (execucao SEQUENTIAL) - ATM=PET[0..5] OCN=PET[6..7] MED=todos"
#   "ESM: layout SHARED (execucao CONCURRENT) - MPAS, MED e OCN em todos os PETs"
# Formato anterior (<= v14.19), ainda reconhecido para logs arquivados:
#   "ESM: modo CONCURRENT - ATM=PET[0..3] OCN=PET[4..7] MED=todos"
# Nos logs antigos os dois eixos eram um só, então 'modo CONCURRENT' implica
# layout split e 'modo SEQUENTIAL' implica layout shared.
_RE_LAYOUT_SPLIT  = re.compile(r"layout\s+SPLIT",  re.IGNORECASE)
_RE_LAYOUT_SHARED = re.compile(r"layout\s+SHARED", re.IGNORECASE)
_RE_EXEC_MODE = re.compile(r"execucao\s+(CONCURRENT|SEQUENTIAL)", re.IGNORECASE)
_RE_MODE_CONCURRENT = re.compile(r"modo\s+CONCURRENT", re.IGNORECASE)
_RE_MODE_SEQUENTIAL = re.compile(r"modo\s+SEQUENTIAL", re.IGNORECASE)
_RE_PET_RANGE = re.compile(
    r"ATM=PET\[(\d+)\.\.(\d+)\]\s+OCN=PET\[(\d+)\.\.(\d+)\]"
)
# Com use_sis2_dynamic ligado, o esm.F90 acrescenta um terceiro bloco na MESMA
# linha, depois do de oceano:
#   "... ATM=PET[0..63] OCN=PET[64..67] ICE=PET[68..71] MED=todos"
# Sem gelo, a linha termina com "MED=todos (ICE desativado)" e este padrão
# simplesmente não casa, deixando ice_range em None.
_RE_ICE_RANGE = re.compile(r"ICE=PET\[(\d+)\.\.(\d+)\]")

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
    # Eixo ESPACIAL: "split" | "shared" | None. É o que determina se os
    # conjuntos de PETs de ATM e OCN são disjuntos.
    layout_announced: Optional[str] = None
    # Eixo TEMPORAL: "concurrent" | "sequential" | None. É o que determina se
    # os intervalos de execução de ATM e OCN podem se sobrepor no tempo.
    mode_announced: Optional[str] = None
    atm_range: Optional[Tuple[int, int]] = None    # (primeiro, último) PET do ATM
    ocn_range: Optional[Tuple[int, int]] = None
    # Terceiro bloco, presente apenas com use_sis2_dynamic = .true. Fica em
    # None quando o gelo está desativado, e essa distinção é usada adiante para
    # decidir se o componente entra ou não no relatório.
    ice_range: Optional[Tuple[int, int]] = None
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

                # Detecta anúncio explícito de layout/modo/partição (INFO).
                # Formato v14.20+: "layout SPLIT (execucao SEQUENTIAL) - ..."
                if result.layout_announced is None:
                    if _RE_LAYOUT_SPLIT.search(msg):
                        result.layout_announced = "split"
                    elif _RE_LAYOUT_SHARED.search(msg):
                        result.layout_announced = "shared"
                    if result.layout_announced is not None:
                        me = _RE_EXEC_MODE.search(msg)
                        if me:
                            result.mode_announced = me.group(1).lower()

                # Formato <= v14.19: um eixo só. 'modo CONCURRENT' implicava
                # PETs disjuntos; 'modo SEQUENTIAL' implicava PETs compartilhados.
                if result.mode_announced is None:
                    if _RE_MODE_CONCURRENT.search(msg):
                        result.mode_announced = "concurrent"
                        if result.layout_announced is None:
                            result.layout_announced = "split"
                    elif _RE_MODE_SEQUENTIAL.search(msg):
                        result.mode_announced = "sequential"
                        if result.layout_announced is None:
                            result.layout_announced = "shared"

                # A faixa de PETs aparece na mesma linha, nos dois formatos.
                if result.atm_range is None and result.layout_announced == "split":
                    rng = _RE_PET_RANGE.search(msg)
                    if rng:
                        a0, a1, o0, o1 = (int(x) for x in rng.groups())
                        result.atm_range = (a0, a1)
                        result.ocn_range = (o0, o1)
                        ice = _RE_ICE_RANGE.search(msg)
                        if ice:
                            result.ice_range = (int(ice.group(1)),
                                                int(ice.group(2)))

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
) -> Tuple[str, Set[int], Set[int], Set[int]]:
    """
    Determina o rótulo de configuração e os conjuntos de PETs de ATM, OCN e ICE.

    O rótulo devolvido combina os DOIS eixos anunciados pelo driver, na forma
    "<execucao> + <layout>" (ex.: "sequential + split"). Isso importa porque
    quem decide se os conjuntos de PETs são disjuntos é o LAYOUT, enquanto
    quem decide se os tempos dos componentes podem se sobrepor é a EXECUÇÃO, e
    o relatório usa as duas informações para coisas diferentes.

    A prioridade é o anúncio explícito do log; na ausência dele, cai para
    inferência a partir de quais PETs reportam MPAS, OCN e ICE. A inferência
    recupera o layout (conjuntos disjuntos = split), mas NÃO a execução:
    sequential+split e concurrent+split produzem exatamente os mesmos
    conjuntos de PETs. Nesse caso a execução é reportada como indeterminada,
    em vez de assumida; assumir 'concurrent' faria o relatório anunciar um
    ganho de tempo de parede que talvez não exista.

    O conjunto do ICE volta VAZIO quando o gelo está desativado. Todo o resto
    do programa usa esse vazio como sinal de ausência do componente, e não
    como "componente presente com tempo zero": um componente ausente é omitido
    do relatório e da divisão de PETs, enquanto um componente presente com
    tempo zero indicaria log truncado e merece aparecer.
    """
    atm_pets_observed = set(result.timing.get("MPAS", {}).keys())
    ocn_pets_observed = set(result.timing.get("OCN", {}).keys())
    ice_pets_observed = set(result.timing.get("ICE", {}).keys())

    exec_mode = result.mode_announced or "execucao indeterminada"

    if result.layout_announced == "split" and result.atm_range and result.ocn_range:
        a0, a1 = result.atm_range
        o0, o1 = result.ocn_range
        if result.ice_range:
            i0, i1 = result.ice_range
            ice = set(range(i0, i1 + 1))
        else:
            ice = set()
        return (f"{exec_mode} + split",
                set(range(a0, a1 + 1)), set(range(o0, o1 + 1)), ice)

    if result.layout_announced == "shared":
        # Em layout compartilhado todos os componentes ativos ocupam todos os
        # PETs. O gelo só entra se houver atividade dele nos logs: sem isso,
        # não há como distinguir "gelo em todos os PETs" de "gelo desligado".
        all_pets = atm_pets_observed | ocn_pets_observed | ice_pets_observed
        ice = set(all_pets) if ice_pets_observed else set()
        return f"{exec_mode} + shared", set(all_pets), set(all_pets), ice

    # Fallback: inferência pura a partir da atividade observada.
    if atm_pets_observed and ocn_pets_observed:
        if atm_pets_observed.isdisjoint(ocn_pets_observed):
            # Com três blocos disjuntos a inferência continua valendo; o ICE
            # entra com os PETs em que houve atividade dele.
            return (f"{exec_mode} + split (inferido)",
                    atm_pets_observed, ocn_pets_observed, ice_pets_observed)
        if atm_pets_observed == ocn_pets_observed:
            return (f"{exec_mode} + shared (inferido)",
                    atm_pets_observed, ocn_pets_observed, ice_pets_observed)
        # Sobreposição parcial: situação atípica, reporta como observado.
        return ("indeterminado (sobreposição parcial)",
                atm_pets_observed, ocn_pets_observed, ice_pets_observed)

    return ("indeterminado (dados insuficientes)",
            atm_pets_observed, ocn_pets_observed, ice_pets_observed)


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
    resumos: List[Tuple[str, ComponentSummary]], target_pets: int
) -> Dict[str, int]:
    """
    Sugere a contagem de PETs de cada componente que tende a igualar os tempos,
    assumindo escalonamento aproximadamente linear com o número de PETs.

    Recebe a lista de (rótulo, resumo) na ordem em que deve aparecer no
    relatório, e devolve um dicionário rótulo -> contagem. Componentes com
    n_pets igual a zero são tratados como AUSENTES e ficam de fora da divisão:
    é assim que uma execução sem gelo continua produzindo a mesma sugestão de
    duas contagens que produzia antes desta revisão.

    A divisão usa o método do maior resto, com piso de 1 PET por componente
    ativo. O piso importa porque o arredondamento proporcional pode zerar um
    componente muito rápido, e o driver rejeita contagem zero.
    """
    ativos = [(nome, r) for nome, r in resumos if r.n_pets > 0]
    if not ativos:
        return {}

    k = len(ativos)
    if target_pets < k:
        # Menos PETs do que componentes: devolve 1 para cada, e quem chamou
        # decide o que fazer. Não há divisão possível que satisfaça o piso.
        return {nome: 1 for nome, _ in ativos}

    pesos = {nome: r.total_s * max(r.n_pets, 1) for nome, r in ativos}
    total_w = sum(pesos.values())

    if total_w <= 0:
        # Sem dado de tempo utilizável: reparte por igual.
        quotas = {nome: target_pets / k for nome, _ in ativos}
    else:
        quotas = {nome: target_pets * pesos[nome] / total_w for nome, _ in ativos}

    # Método do maior resto sobre a quota CHEIA. Reservar antes um piso de 1
    # por componente e repartir só o excedente pareceria equivalente, mas não
    # é: o piso sai proporcionalmente mais do componente pesado, e a divisão
    # resultante difere da que este script produzia com dois componentes.
    inteiros = {nome: int(q) for nome, q in quotas.items()}
    sobra = target_pets - sum(inteiros.values())
    for nome in sorted(quotas, key=lambda n: quotas[n] - inteiros[n],
                       reverse=True)[:sobra]:
        inteiros[nome] += 1

    # Piso de 1 PET por componente ativo: o driver rejeita contagem zero, e o
    # arredondamento proporcional pode zerar um componente muito rápido. Cada
    # unidade concedida sai de quem tem mais no momento.
    for nome in inteiros:
        if inteiros[nome] >= 1:
            continue
        doador = max(inteiros, key=lambda n: inteiros[n])
        if inteiros[doador] <= 1:
            break
        inteiros[doador] -= 1
        inteiros[nome] = 1

    return inteiros


# ──────────────────────────────────────────────────────────────────────────
# Saída (console, CSV, JSON, gráfico)
# ──────────────────────────────────────────────────────────────────────────

def fmt_s(x: Optional[float]) -> str:
    if x is None:
        return "N/D"
    return f"{x:8.3f} s"


# Rótulos de exibição e a chave usada no JSON e na sugestão, na ordem em que
# aparecem no relatório. O rótulo do componente no log ESMF é a primeira
# entrada de cada tupla, e é o que casa com _RE_PHASE.
COMPONENTES = (
    ("MPAS", "MPAS (ATM)", "atm", "atm_pet_count"),
    ("OCN",  "OCN (MOM6)", "ocn", "ocn_pet_count"),
    ("ICE",  "ICE (SIS2)", "ice", "ice_pet_count"),
)


def print_report(
    mode: str,
    pets: Dict[str, Set[int]],
    resumos: Dict[str, ComponentSummary],
    med_total_s: float,
    n_steps: Optional[int],
    target_pets: int,
    sugestao: Dict[str, int],
    incomplete_pairs: int,
    baseline: Optional[dict],
) -> None:
    bar = "=" * 70
    print(bar)
    print("  Análise de balanceamento de PETs - MONAN-A x MOM6+SIS2")
    print(bar)
    print(f"  Configuração         : {mode}")
    print(f"  PETs do ATM (MPAS)   : {sorted(pets['MPAS'])}")
    print(f"  PETs do OCN (MOM6)   : {sorted(pets['OCN'])}")
    if pets["ICE"]:
        print(f"  PETs do ICE (SIS2)   : {sorted(pets['ICE'])}")
    else:
        print( "  PETs do ICE (SIS2)   : (componente desativado)")
    print(f"  Passos de acoplamento: {n_steps if n_steps else 'N/D (use --steps)'}")
    if incomplete_pairs:
        print(
            f"  AVISO: {incomplete_pairs} par(es) intro/extro incompleto(s) "
            f"encontrados (log truncado/execução cancelada) - ignorados."
        )

    # Componentes ATIVOS: os que têm PETs atribuídos. Um componente desativado
    # some da tabela, em vez de aparecer com zeros, que se confundiriam com o
    # sintoma de log truncado.
    ativos = [(comp, rot) for comp, rot, _c, _k in COMPONENTES if pets[comp]]

    print("-" * 70)
    print(f"  {'Componente':<12}{'PETs':>6}{'Tempo total':>16}"
          f"{'Tempo/passo':>16}{'Chamadas Run':>16}")
    for comp, rot in ativos:
        r = resumos[comp]
        print(
            f"  {rot:<12}{r.n_pets:>6}{fmt_s(r.total_s):>16}"
            f"{fmt_s(r.per_step_s):>16}{sum(r.run_calls_per_pet.values()):>16}"
        )
    print(f"  {'MED':<12}{'todos':>6}{fmt_s(med_total_s):>16}{'':>16}{'':>16}")
    print("-" * 70)

    medidos = [(comp, rot) for comp, rot in ativos if resumos[comp].total_s > 0]
    if len(medidos) >= 2:
        tempos = {comp: resumos[comp].total_s for comp, _r in medidos}
        rotulos = dict(medidos)
        lento = max(tempos, key=tempos.get)
        rapido = min(tempos, key=tempos.get)
        ratio = tempos[lento] / tempos[rapido]
        print(f"  Componente mais lento : {rotulos[lento]}  (razão {ratio:.2f}x)")
        print(f"  Componente mais rápido: {rotulos[rapido]}")
        print(f"  Desbalanceamento      : {(ratio - 1.0) * 100:5.1f}% "
              f"de tempo ocioso no mais rápido")
        if "concurrent" in mode:
            # Com três componentes o tempo por passo continua sendo o MAIOR
            # dos avanços, não a soma: em concurrent os três blocos avançam ao
            # mesmo tempo. O ganho é medido contra a soma, que é o que custaria
            # executá-los um de cada vez.
            paralelo = max(tempos.values())
            serial = sum(tempos.values())
            ganho_pct = (1 - paralelo / serial) * 100.0
            detalhe = ", ".join(f"{t:.1f}" for t in tempos.values())
            print(f"  Ganho vs. soma serial : {ganho_pct:5.1f}%  "
                  f"(max({detalhe}) vs. soma {serial:.1f} s)")
    print("-" * 70)

    print(f"  Sugestão de partição para {target_pets} PETs totais:")
    for comp, _rot, _c, chave in COMPONENTES:
        if comp in sugestao:
            print(f"    {chave} = {sugestao[comp]}")
    if "ICE" not in sugestao:
        print("    use_sis2_dynamic = .false.   ! gelo ausente nesta medição")

    if "shared" in mode:
        # Com layout shared, cada componente foi medido usando TODOS os PETs;
        # a sugestão é uma extrapolação para uma partição que nunca existiu.
        # O critério aqui é o layout, não a execução: sequential+split já
        # fornece medidas por partição real, e cai no ramo de baixo.
        print(
            "  (base: custos medidos com todos os PETs em cada componente,\n"
            "   extrapolados linearmente para a nova partição - validar com\n"
            "   uma execução em pet_layout=split real.)"
        )
    else:
        atual = {comp: resumos[comp].n_pets for comp, _r in ativos}
        if atual == sugestao:
            print("  (a partição atual já está aproximadamente balanceada.)")
        else:
            # Usa a chave curta ('atm', e não 'mpas'), que é a mesma dos
            # parâmetros do &nuopc_petlayout logo acima.
            curta = {comp: chave for comp, _rot, chave, _k in COMPONENTES}
            detalhe = " ".join(f"{curta[c]}={n}" for c, n in atual.items())
            print(f"  (partição atual: {detalhe} - ajuste sugerido acima.)")

    if baseline:
        print("-" * 70)
        print("  Comparação com baseline salvo:")
        for comp, rot, chave, _k in COMPONENTES:
            b = baseline.get(f"{chave}_total_s")
            if b is None:
                continue
            if not pets[comp]:
                print(f"    {rot:<11}: {b:.3f} s -> componente ausente nesta medição")
                continue
            atual_s = resumos[comp].total_s
            print(f"    {rot:<11}: {b:.3f} s -> {atual_s:.3f} s  "
                  f"(Δ {atual_s - b:+.3f} s)")
        # Um componente que existe agora e não existia na referência é uma
        # mudança de configuração, não de desempenho, e precisa ser dita.
        for comp, rot, chave, _k in COMPONENTES:
            if pets[comp] and baseline.get(f"{chave}_total_s") is None:
                print(f"    {rot:<11}: ausente na referência -> "
                      f"{resumos[comp].total_s:.3f} s (novo componente)")
    print(bar)


def write_csv(path: Path, result: ParseResult, pets: Dict[str, Set[int]]) -> None:
    """Exporta o detalhe de cada chamada Run (passo interno) por PET/componente."""
    import csv

    # Mapa PET -> bloco, montado uma vez. A versão anterior deduzia o bloco
    # dentro do laço com uma cadeia de condicionais que não tinha como
    # representar um terceiro bloco.
    bloco: Dict[int, str] = {}
    for comp, rotulo in (("MPAS", "ATM"), ("OCN", "OCN"), ("ICE", "ICE")):
        for pet in pets.get(comp, set()):
            bloco[pet] = rotulo

    with path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["componente", "pet", "grupo", "indice_chamada", "duracao_s"])
        for comp in ("MPAS", "OCN", "ICE", "MED"):
            for pet, ct in sorted(result.timing.get(comp, {}).items()):
                # O MED roda em todos os PETs, então o bloco dele é o do PET,
                # e não um bloco próprio. Um PET sem bloco conhecido aparece
                # como "?" em vez de ser silenciosamente atribuído a algum.
                grupo = "MED" if comp == "MED" else bloco.get(pet, "?")
                for i, dur in enumerate(ct.run_durations):
                    w.writerow([comp, pet, grupo, i, f"{dur:.6f}"])


def write_json(
    path: Path,
    mode: str,
    resumos: Dict[str, ComponentSummary],
    pets: Dict[str, Set[int]],
    med_total_s: float,
    n_steps: Optional[int],
    sugestao: Dict[str, int],
) -> None:
    payload = {
        "mode": mode,
        "n_steps": n_steps,
        "med_total_s": med_total_s,
    }
    for comp, _rot, chave, _k in COMPONENTES:
        if not pets[comp]:
            # Componente ausente não entra no JSON. Assim uma referência
            # gravada sem gelo e outra com gelo continuam comparáveis nos
            # campos que as duas têm, e a diferença fica explícita.
            continue
        r = resumos[comp]
        payload[f"{chave}_n_pets"] = r.n_pets
        payload[f"{chave}_total_s"] = r.total_s
        payload[f"{chave}_per_step_s"] = r.per_step_s
        payload[f"suggested_{chave}_pet_count"] = sugestao.get(comp)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False))


def write_plot(path: Path, resumos: Dict[str, ComponentSummary],
               pets: Dict[str, Set[int]]) -> None:
    """Gera um gráfico de barras comparando o tempo total por PET."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cores = {"MPAS": "#1F9E77", "OCN": "#2E7BC4", "ICE": "#B07AA1"}
    prefixo = {"MPAS": "ATM", "OCN": "OCN", "ICE": "ICE"}

    fig, ax = plt.subplots(figsize=(8, 4))
    presentes = []
    for comp, rot, _c, _k in COMPONENTES:
        if not pets[comp]:
            continue
        r = resumos[comp]
        ordem = sorted(r.per_pet_totals)
        if not ordem:
            continue
        ax.bar(
            [f"{prefixo[comp]}\nPET{p}" for p in ordem],
            [r.per_pet_totals[p] for p in ordem],
            color=cores[comp],
            label=rot,
        )
        presentes.append(rot)

    ax.set_ylabel("Tempo total em Run (s)")
    ax.set_title("Tempo de parede por PET - " + " x ".join(presentes))
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

    mode, atm_pets, ocn_pets, ice_pets = detect_pet_groups(result)
    pets = {"MPAS": atm_pets, "OCN": ocn_pets, "ICE": ice_pets}

    n_steps = args.steps
    if n_steps is None:
        run_log = args.run_log or find_run_log(args.logdir)
        n_steps = detect_step_count(run_log)

    resumos = {
        comp: summarize_component(result, comp, pets[comp], n_steps)
        for comp, _rot, _c, _k in COMPONENTES
    }
    med_pets = set(result.timing.get("MED", {}).keys())
    med = summarize_component(result, "MED", med_pets, n_steps)

    # Aviso de coerência: atividade de ICE nos logs sem que o gelo tenha sido
    # atribuído a bloco nenhum indica que a linha de layout não foi lida (log
    # em Multi_On_Error) e que a inferência também não pegou. Sem este aviso o
    # componente sumiria do relatório sem explicação.
    ice_observado = set(result.timing.get("ICE", {}).keys())
    if ice_observado and not ice_pets:
        print(f"AVISO: há atividade de ICE em {len(ice_observado)} PET(s), mas o "
              f"componente não pôde ser atribuído a um bloco; será omitido do "
              f"relatório. Confira a linha 'ESM: layout ...' nos logs.",
              file=sys.stderr)

    todos_pets = atm_pets | ocn_pets | ice_pets
    ativos = [c for c, _r, _cc, _k in COMPONENTES if pets[c]]
    target_pets = args.target_pets or (
        len(todos_pets) or sum(resumos[c].n_pets for c in ativos)
    )
    if target_pets < max(len(ativos), 2):
        print("AVISO: total de PETs insuficiente para sugerir uma partição.",
              file=sys.stderr)
        target_pets = max(target_pets, len(ativos), 2)

    sugestao = suggest_partition(
        [(comp, resumos[comp]) for comp in ativos], target_pets)

    baseline = None
    if args.baseline_json and args.baseline_json.is_file():
        baseline = json.loads(args.baseline_json.read_text())

    print_report(
        mode=mode,
        pets=pets,
        resumos=resumos,
        med_total_s=med.total_s,
        n_steps=n_steps,
        target_pets=target_pets,
        sugestao=sugestao,
        incomplete_pairs=result.incomplete_pairs,
        baseline=baseline,
    )

    if args.csv_out:
        write_csv(args.csv_out, result, pets)
        print(f"[csv]  detalhe por chamada salvo em: {args.csv_out}")
    if args.json_out:
        write_json(args.json_out, mode, resumos, pets, med.total_s,
                   n_steps, sugestao)
        print(f"[json] resumo salvo em: {args.json_out}")
    if args.plot_out:
        write_plot(args.plot_out, resumos, pets)
        print(f"[plot] gráfico salvo em: {args.plot_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
