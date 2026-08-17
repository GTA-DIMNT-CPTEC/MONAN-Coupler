#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
# plan-layout.py — Planejador de topologia multi-nó / split de comunicador
# Sistema Acoplado MONAN-A 2.0 x MOM6+SIS2 / ESMF-NUOPC 8.9.1
# INPE / CGCT / DIMNT — GT Acoplamento de Modelos
#
# Reproduz, FORA do job, a mesma lógica de consolidação que o run_esmApp.jaci
# aplica ao gerar o 'select' do PBS. Serve para escolher o número de PETs de
# cada componente ANTES de editar a nuopc.input: mostra quantos nós, quantos
# PET/nó, a memória por nó e a string 'select' resultante, sinalizando as
# combinações que desperdiçam núcleos ou que só cabem nos nós de alta memória.
#
# Hardware da Jaci (Cray XD2000), confirmado via lscpu/pbsnodes/qstat:
#   • nó de cálculo cn-0001..cn-0104: 256 CORES FÍSICOS (2 sockets x 128 Zen5)
#     com SMT ligado (2 threads/core → 512 CPUs lógicos) e ~754 GB. O nó reporta
#     resources_available.ncpus = 512 (lógicos), MAS o orçamento das filas é em
#     CORES FÍSICOS (pesqextra: 7680 ncpus para 30 nós = 256 por nó). Por isso o
#     'select' pede ncpus = mpiprocs = PPN <= 256, e a posse do nó inteiro vem de
#     'place=scatter:excl'. PPN_PHYS = 256 é o teto de CORES FÍSICOS e o
#     padrão; PPN_HARD = 512 é o teto absoluto (CPUs lógicas), alcançável
#     apenas com --allow-smt, espelhando o run_esmApp.jaci.
#   • 10 nós auxiliares aux01..aux10: 256 ncpus e ~1,5 TB, fila 'aux'
#     (worktype=aux), para pré e pós-processamento, não para o acoplado.
#
# Regra de consolidação (idêntica ao run_esmApp.jaci com pet_layout='split'):
#   PET/nó do componente = MAIOR divisor do seu count que seja <= cap (padrão
#   256 para ambos: nó cheio, 1 rank por core físico). Assim cada bloco fecha
#   em nós inteiros e nenhum nó fica MISTO (ATM+OCN) — melhor localidade e
#   binding. NÃO há modelo de memória por PET: nada de 'mem' por padrão.
#
# Uso rápido:
#   python3 plan-layout.py --atm 256 --ocn 128
#   python3 plan-layout.py --total 384 --ratio 2:1
#   python3 plan-layout.py --sweep 256 1536 --ratio 2:1
#   python3 plan-layout.py --suggest --atm 250 --ocn 130
#   python3 plan-layout.py --shared --npes 512 --ppn 128
#
# NOTA (v14.20): o grupo &nuopc_petlayout tem dois eixos independentes. Este
# planejador trata do eixo ESPACIAL (pet_layout): '--atm/--ocn' planejam um
# layout 'split', e '--shared' um layout 'shared'. O eixo TEMPORAL
# (coupling_mode) não altera a topologia de nós — sequential+split e
# concurrent+split pedem exatamente o mesmo 'select' —, mas altera o
# desempenho: só em concurrent o tempo por passo cai para max(t_ATM, t_OCN).
# A opção histórica '--sequential' segue valendo como sinônimo de '--shared'.
#   python3 plan-layout.py -h
# =============================================================================

import argparse
import sys

# ── Padrões do sítio (Jaci) — espelham as constantes do run_esmApp.jaci ──────
PPN_PHYS_DEFAULT       = 256    # cores FÍSICOS por nó (2 sockets x 128)
PPN_HARD_DEFAULT       = 512    # CPUs LÓGICAS por nó (SMT, 2 threads/core)
NODE_MEM_STD_DEFAULT   = 754    # GB utilizáveis no nó de cálculo
CAP_ATM_DEFAULT        = 256    # teto de PET/nó do ATM (nó cheio)
CAP_OCN_DEFAULT        = 256    # teto de PET/nó do OCN (nó cheio)
MEM_PP_ATM_DEFAULT     = 0      # GB/PET do ATM (0 = sem reserva; opcional)
MEM_PP_OCN_DEFAULT     = 0      # GB/PET do OCN (0 = sem reserva; opcional)
PLACE_DEFAULT          = "scatter:excl"   # 1 chunk por nó + nó exclusivo
QUEUE_DEFAULT          = "pesqextra"

# Limites das filas (qstat -Qf, 2026-08): nome -> (ncpus_max, nodes_max, walltime).
# nodes_max = 0 significa sem limite declarado de nós.
QUEUE_LIMITS = {
    "pesqextra": (7680, 30, "08:00:00"),
    "pesqhigh":  (5120, 20, "06:00:00"),
    "pesqmidi":  (1792,  7, "02:00:00"),
    "pesqmini":  (1792,  7, "00:30:00"),
    "longtime":  (2048,  8, "168:00:00"),
    "aux":       ( 256,  1, "24:00:00"),
    "oper":      (10240, 0, "08:00:00"),
    "preoper":   (10240, 0, "08:00:00"),
}


def queue_warns(npes, nodes, queue):
    """Avisos de estouro dos limites da fila. Espelha _queue_guard do script."""
    lim = QUEUE_LIMITS.get(queue)
    if lim is None:
        return ["fila '{}' fora da tabela deste planejador; "
                "confira com 'qstat -Qf {}'.".format(queue, queue)]
    ncpus_max, nodes_max, _wt = lim
    out = []
    if npes > ncpus_max:
        out.append("NPES={} excede resources_max.ncpus={} da fila '{}'."
                   .format(npes, ncpus_max, queue))
    if nodes_max and nodes > nodes_max:
        out.append("{} nós excedem resources_max.nodes={} da fila '{}'."
                   .format(nodes, nodes_max, queue))
    return out


# ── Núcleo da lógica (igual ao bash _largest_div_le) ─────────────────────────
def largest_div_le(n: int, cap: int) -> int:
    """Maior divisor de n que seja <= cap (garante blocos em nós inteiros)."""
    cap = min(cap, n)
    if cap < 1:
        cap = 1
    for d in range(cap, 0, -1):
        if n % d == 0:
            return d
    return 1


def mem_suffix(mpiprocs: int, gb_per_pet: int) -> str:
    """Sufixo ':mem=XXgb' de um chunk (vazio se gb_per_pet == 0)."""
    if gb_per_pet and gb_per_pet > 0:
        return ":mem={}gb".format(mpiprocs * gb_per_pet)
    return ""


def plan_component(count: int, cap: int, gb_per_pet: int):
    """Retorna (ppn, nnodes, mem_por_no_GB) de um componente."""
    ppn = largest_div_le(count, cap)
    nnodes = count // ppn
    mem_node = ppn * gb_per_pet
    return ppn, nnodes, mem_node


def suggest_clean(count: int, cap: int):
    """Múltiplos de cap imediatamente abaixo e acima de count (bracket)."""
    lo = (count // cap) * cap
    hi = lo + cap if lo < count else lo
    if lo == 0:
        lo = cap
    return lo, hi


def clean_hint(count: int, cap: int) -> str:
    """Texto de sugestão de count 'limpo', sem repetir valores iguais."""
    lo, hi = suggest_clean(count, cap)
    if lo == hi:
        return "use {} (múltiplo de {})".format(lo, cap)
    return "use {} ou {} (múltiplos de {})".format(lo, hi, cap)


# ── Layout concurrent (ATM + OCN) ────────────────────────────────────────────
def concurrent_layout(atm, ocn, cfg):
    ppnA, nA, memA = plan_component(atm, cfg["cap_atm"], cfg["mem_pp_atm"])
    ppnO, nO, memO = plan_component(ocn, cfg["cap_ocn"], cfg["mem_pp_ocn"])

    chunkA = "{n}:ncpus={p}:mpiprocs={p}{m}".format(
        n=nA, p=ppnA, m=mem_suffix(ppnA, cfg["mem_pp_atm"]))
    chunkO = "{n}:ncpus={p}:mpiprocs={p}{m}".format(
        n=nO, p=ppnO, m=mem_suffix(ppnO, cfg["mem_pp_ocn"]))

    if cfg["pet_order"] == "ocn-first":
        select = "select=" + chunkO + "+" + chunkA
    else:
        select = "select=" + chunkA + "+" + chunkO

    warns = []
    if memA > cfg["node_mem"]:
        warns.append("mem/nó do ATM ({} GB) excede o nó padrão (~{} GB) "
                     "→ só nós de ~1,5 TB".format(memA, cfg["node_mem"]))
    if memO > cfg["node_mem"]:
        warns.append("mem/nó do OCN ({} GB) excede o nó padrão (~{} GB) "
                     "→ só nós de ~1,5 TB".format(memO, cfg["node_mem"]))
    # "quebrado" = o count EXCEDE o teto e não é múltiplo dele (gera blocos
    # tortos, ex.: 2x192). Um count <= teto vira um único nó (bloco limpo).
    bad_atm = atm > cfg["cap_atm"] and atm % cfg["cap_atm"] != 0
    bad_ocn = ocn > cfg["cap_ocn"] and ocn % cfg["cap_ocn"] != 0
    if bad_atm:
        warns.append("atm_pet_count={} > {} e não múltiplo → bloco ATM {}x{} "
                     "({})".format(atm, cfg["cap_atm"], nA, ppnA,
                                   clean_hint(atm, cfg["cap_atm"])))
    if bad_ocn:
        warns.append("ocn_pet_count={} > {} e não múltiplo → bloco OCN {}x{} "
                     "({})".format(ocn, cfg["cap_ocn"], nO, ppnO,
                                   clean_hint(ocn, cfg["cap_ocn"])))

    return {
        "atm": atm, "ocn": ocn, "npes": atm + ocn,
        "ppnA": ppnA, "nA": nA, "memA": memA,
        "ppnO": ppnO, "nO": nO, "memO": memO,
        "nodes": nA + nO, "select": select, "warns": warns,
        "clean": (not bad_atm and not bad_ocn
                  and not any("excede" in w for w in warns)),
    }


# ── Layout sequential (uniforme, NNODES x PPN) ───────────────────────────────
def sequential_layout(npes, ppn, cfg):
    if ppn <= 0:
        nnodes = -(-npes // cfg["ppn_max"])          # teto
        ppn = npes // nnodes if npes % nnodes == 0 else cfg["ppn_max"]
    else:
        ppn = min(ppn, npes)
        nnodes = -(-npes // ppn)

    mem = cfg["mem_pp_ocn"]                            # razão base (= --mem-per-pet)
    if npes % ppn == 0:
        select = "select={n}:ncpus={p}:mpiprocs={p}{m}".format(
            n=nnodes, p=ppn, m=mem_suffix(ppn, mem))
        last = ppn
    else:
        full = npes // ppn
        rem = npes - full * ppn
        select = ("select={f}:ncpus={p}:mpiprocs={p}{m}"
                  "+1:ncpus={r}:mpiprocs={r}{mr}").format(
                      f=full, p=ppn, m=mem_suffix(ppn, mem),
                      r=rem, mr=mem_suffix(rem, mem))
        nnodes = full + 1
        last = rem

    warns = []
    if mem * ppn > cfg["node_mem"]:
        warns.append("mem/nó ({} GB) excede o nó padrão (~{} GB) "
                     "→ só nós de ~1,5 TB".format(mem * ppn, cfg["node_mem"]))
    return {"npes": npes, "ppn": ppn, "nodes": nnodes, "last": last,
            "select": select, "warns": warns}


# ── Impressão ────────────────────────────────────────────────────────────────
def print_single(r, cfg):
    print("=" * 74)
    print("  Layout CONCURRENT — atm={}  ocn={}  (NPES={})".format(
        r["atm"], r["ocn"], r["npes"]))
    print("=" * 74)
    order = cfg["pet_order"]
    memA = "  ({} GB/nó, {} GB/PET)".format(r["memA"], cfg["mem_pp_atm"]) if cfg["mem_pp_atm"] else ""
    memO = "  ({} GB/nó, {} GB/PET)".format(r["memO"], cfg["mem_pp_ocn"]) if cfg["mem_pp_ocn"] else ""
    print("  {:<12}: {} x {} PET/nó{}".format("Bloco ATM", r["nA"], r["ppnA"], memA))
    print("  {:<12}: {} x {} PET/nó{}".format("Bloco OCN", r["nO"], r["ppnO"], memO))
    print("  {:<12}: {} nó(s)   (ordem no select: {})".format(
        "Total", r["nodes"], order))
    print("  {:<12}: {}".format("SELECT", r["select"]))
    print("  {:<12}: {}".format(
        "place", PLACE_DEFAULT + " (1 chunk por nó, nó exclusivo)"))
    smt = max(r["ppnA"], r["ppnO"]) > PPN_PHYS_DEFAULT
    print("  {:<12}: {}".format(
        "regime", "SMT ATIVO - 2 ranks por core fisico" if smt
        else "1 rank por core fisico (SMT ocioso)"))
    qmax = QUEUE_LIMITS.get(cfg["queue"])
    if qmax:
        print("  {:<12}: {}  (máx: {} PETs, {} nós, {})".format(
            "fila", cfg["queue"], qmax[0],
            qmax[1] if qmax[1] else "-", qmax[2]))
    for w in queue_warns(r["npes"], r["nodes"], cfg["queue"]):
        r["warns"].append(w)
    if r["warns"]:
        print("  " + "-" * 70)
        for w in r["warns"]:
            print("  AVISO: " + w)
    else:
        print("  STATUS: layout limpo (cada componente cabe em nós inteiros).")
    print()
    print("  Para usar, na nuopc.input (&nuopc_petlayout):")
    print("    coupling_mode = 'concurrent'   ! 'sequential' também aceita split")
    print("    pet_layout    = 'split'        ! obrigatório para as contagens abaixo")
    print("    atm_pet_count = {}".format(r["atm"]))
    print("    ocn_pet_count = {}".format(r["ocn"]))
    print("  e submeter:  bash run_esmApp.jaci -n {}{}".format(
        r["npes"], "" if order == "atm-first" else " --pet-order ocn-first"))
    print("=" * 74)


def print_table(rows):
    hdr = "{:>6} {:>5} {:>5} | {:<20} {:<20} | {:>4} | {}".format(
        "NPES", "atm", "ocn", "bloco ATM", "bloco OCN", "nós", "status")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        atm_s = "{}x{}{}".format(r["nA"], r["ppnA"], " ({}GB)".format(r["memA"]) if r["memA"] else "")
        ocn_s = "{}x{}{}".format(r["nO"], r["ppnO"], " ({}GB)".format(r["memO"]) if r["memO"] else "")
        if r["clean"]:
            st = "OK"
        elif any("fila" in w or "resources_max" in w for w in r["warns"]):
            st = "excede fila"
        elif any("excede" in w for w in r["warns"]):
            st = "mem>nó padrão"
        else:
            st = "quebrado"
        print("{:>6} {:>5} {:>5} | {:<20} {:<20} | {:>4} | {}".format(
            r["npes"], r["atm"], r["ocn"], atm_s, ocn_s, r["nodes"], st))


def split_ratio(total, ratio):
    try:
        a, b = (int(x) for x in ratio.split(":"))
    except Exception:
        sys.exit("ERRO: --ratio deve ser A:B (ex.: 2:1).")
    if a <= 0 or b <= 0:
        sys.exit("ERRO: --ratio com valores > 0 (ex.: 2:1).")
    atm = total * a // (a + b)
    ocn = total - atm
    return atm, ocn


# ── CLI ──────────────────────────────────────────────────────────────────────
def build_parser():
    p = argparse.ArgumentParser(
        description="Planejador de topologia multi-nó/split do "
                    "run_esmApp.jaci (MONAN-A 2.0 x MOM6+SIS2).",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--atm", type=int, help="atm_pet_count (PETs do MPAS-A)")
    p.add_argument("--ocn", type=int, help="ocn_pet_count (PETs do MOM6+SIS2)")
    p.add_argument("--total", type=int,
                   help="NPES total; divide por --ratio em atm/ocn")
    p.add_argument("--ratio", default="2:1",
                   help="razão ATM:OCN para --total/--sweep (padrão 2:1)")
    p.add_argument("--sweep", nargs=2, type=int, metavar=("MIN", "MAX"),
                   help="varre NPES de MIN a MAX (passo --step) e tabela")
    p.add_argument("--step", type=int, default=128,
                   help="passo da varredura (padrão 128)")
    p.add_argument("--suggest", action="store_true",
                   help="mostra counts 'limpos' próximos de --atm/--ocn")
    p.add_argument("--sequential", "--shared", dest="sequential",
                   action="store_true",
                   help="planeja o layout shared (uniforme, um só bloco de nós) "
                        "em vez do split ATM|OCN")
    p.add_argument("--npes", type=int, help="NPES para --sequential/--shared")
    p.add_argument("--ppn", type=int, default=0,
                   help="PET/nó no --sequential/--shared (0 = auto, padrão)")
    # Caps e memória (espelham as opções do run_esmApp.jaci).
    p.add_argument("--ppn-atm", type=int, default=CAP_ATM_DEFAULT,
                   dest="cap_atm", help="teto de PET/nó do ATM (padrão 256)")
    p.add_argument("--ppn-ocn", type=int, default=CAP_OCN_DEFAULT,
                   dest="cap_ocn", help="teto de PET/nó do OCN (padrão 256)")
    p.add_argument("--mem-per-pet-atm", type=int, default=MEM_PP_ATM_DEFAULT,
                   dest="mem_pp_atm", help="reserva opcional GB/PET do ATM (padrão 0)")
    p.add_argument("--mem-per-pet", type=int, default=MEM_PP_OCN_DEFAULT,
                   dest="mem_pp_ocn", help="reserva opcional GB/PET do OCN (padrão 0)")
    p.add_argument("--pet-order", choices=("atm-first", "ocn-first"),
                   default="atm-first", help="ordem dos blocos no select")
    p.add_argument("--ppn-max", type=int, default=PPN_PHYS_DEFAULT,
                   dest="ppn_max", help="cores físicos por nó (padrão 256)")
    p.add_argument("--allow-smt", action="store_true", dest="allow_smt",
                   help="permite tetos acima de %d PET/nó (ate %d), colocando 2 "
                        "ranks por core fisico. Espelha o --allow-smt do "
                        "run_esmApp.jaci; destinado a MEDICAO, nao a producao"
                        % (PPN_PHYS_DEFAULT, PPN_HARD_DEFAULT))
    p.add_argument("--node-mem", type=int, default=NODE_MEM_STD_DEFAULT,
                   dest="node_mem", help="GB do nó padrão (padrão 754)")
    p.add_argument("--queue", default=QUEUE_DEFAULT,
                   help="fila PBS para conferir os limites (padrão: pesqextra)")
    return p


def valida_tetos(args):
    """Espelha a guarda do run_esmApp.jaci: tetos acima dos cores fisicos so
    com --allow-smt, e nunca acima das CPUs logicas. Sem isso o planejador
    imprimiria um select que o script recusaria, quebrando a garantia de que
    os dois produzem a mesma diretiva."""
    limite = PPN_HARD_DEFAULT if args.allow_smt else PPN_PHYS_DEFAULT
    erros = []
    for rotulo, valor in (("--ppn-max", args.ppn_max),
                          ("--ppn-atm", args.cap_atm),
                          ("--ppn-ocn", args.cap_ocn)):
        if valor <= limite:
            continue
        if valor <= PPN_HARD_DEFAULT and not args.allow_smt:
            erros.append(
                "{} {} excede {} cores fisicos por no. Acima disso cada core "
                "recebe 2 ranks (SMT), o que degrada MPAS/MOM6. Para planejar "
                "esse caso deliberadamente, acrescente --allow-smt."
                .format(rotulo, valor, PPN_PHYS_DEFAULT))
        else:
            erros.append("{} {} excede {} CPUs logicas por no (limite do "
                         "hardware).".format(rotulo, valor, PPN_HARD_DEFAULT))
    return erros


def main(argv=None):
    args = build_parser().parse_args(argv)
    erros = valida_tetos(args)
    if erros:
        for e in erros:
            print("ERRO: " + e, file=sys.stderr)
        return 1
    cfg = {
        "cap_atm": args.cap_atm if args.cap_atm > 0 else args.ppn_max,
        "cap_ocn": args.cap_ocn if args.cap_ocn > 0 else args.ppn_max,
        "mem_pp_atm": args.mem_pp_atm, "mem_pp_ocn": args.mem_pp_ocn,
        "pet_order": args.pet_order, "ppn_max": args.ppn_max,
        "node_mem": args.node_mem, "queue": args.queue,
    }

    # 1) Sequential
    if args.sequential:
        if not args.npes:
            sys.exit("ERRO: --sequential/--shared exige --npes N.")
        r = sequential_layout(args.npes, args.ppn, cfg)
        print("=" * 74)
        print("  Layout SHARED (uniforme) — NPES={}".format(r["npes"]))
        print("=" * 74)
        tail = "" if r["last"] == r["ppn"] else "  (último nó: {} PET)".format(r["last"])
        print("  {:<10}: {} nó(s) x {} PET/nó{}".format(
            "Topologia", r["nodes"], r["ppn"], tail))
        print("  {:<10}: {}".format("SELECT", r["select"]))
        print("  {:<10}: {}".format("place", PLACE_DEFAULT))
        print("  {:<10}: {}".format(
            "regime", "SMT ATIVO - 2 ranks por core fisico"
            if r["ppn"] > PPN_PHYS_DEFAULT
            else "1 rank por core fisico (SMT ocioso)"))
        r["warns"].extend(queue_warns(r["npes"], r["nodes"], args.queue))
        for w in r["warns"]:
            print("  AVISO: " + w)
        print("=" * 74)
        return 0

    # 2) Varredura → tabela
    if args.sweep:
        lo, hi = args.sweep
        rows = []
        for total in range(lo, hi + 1, args.step):
            atm, ocn = split_ratio(total, args.ratio)
            if atm > 0 and ocn > 0:
                row = concurrent_layout(atm, ocn, cfg)
                row["warns"].extend(
                    queue_warns(row["npes"], row["nodes"], args.queue))
                if row["warns"]:
                    row["clean"] = False
                rows.append(row)
        print("Varredura NPES {}..{} (passo {}), razão ATM:OCN = {}, "
              "caps ATM<= {} / OCN<= {}\n".format(
                  lo, hi, args.step, args.ratio, cfg["cap_atm"], cfg["cap_ocn"]))
        print_table(rows)
        print("\n  OK = cada componente cabe num nó ou é múltiplo do teto.")
        print("  'quebrado' = count > teto e não múltiplo → PET/nó torto (revise).")
        print("  'excede fila' = NPES ou nº de nós acima do resources_max "
              "da fila '{}'.".format(args.queue))
        return 0

    # 3) atm/ocn diretos ou via --total
    if args.total:
        atm, ocn = split_ratio(args.total, args.ratio)
    else:
        atm, ocn = args.atm, args.ocn
    if not atm or not ocn:
        sys.exit("ERRO: informe --atm e --ocn, ou --total (com --ratio).\n"
                 "      Ex.: plan-layout.py --atm 256 --ocn 128")

    if args.suggest:
        for label, count, cap in (("ATM", atm, cfg["cap_atm"]),
                                  ("OCN", ocn, cfg["cap_ocn"])):
            # limpo se cabe em um nó (<= cap) ou é múltiplo do teto
            flag = "(já é limpo)" if (count <= cap or count % cap == 0) else \
                   "→ " + clean_hint(count, cap)
            print("  {}: {} {}".format(label, count, flag))
        print()

    print_single(concurrent_layout(atm, ocn, cfg), cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
