#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mede_smt.py - Comparacao controlada do efeito do SMT no sistema acoplado
              MONAN-A 2.0 x MOM6+SIS2 (NUOPC/ESMF) no supercomputador Jaci.

INPE / CGCT / DIMNT - Grupo de Trabalho para Acoplamento de Modelos.

ALTERACOES (Set/2026)
---------------------
1. O reconhecimento do modo de acoplamento estava quebrado com binario atual.
   O padrao procurado era "ESM: modo SEQUENTIAL|CONCURRENT", formato ANTERIOR a
   v14.20. Desde a separacao dos dois eixos o driver grava
   "ESM: layout SPLIT (execucao SEQUENTIAL) - ...", que nao casava. Tres
   verificacoes eram puladas em silencio: consistencia de modo entre rodadas,
   igualdade de modo entre A e B, e o aviso de modo concorrente. Os dois
   formatos passaram a ser aceitos.
2. O componente de gelo (SIS2) entrou na ordem de exibicao. O leitor de logs
   sempre foi generico e ja' capturava o rotulo ICE, mas sem estar na lista ele
   caia no rabo alfabetico e vinha antes de MPAS e OCN.
3. Nova verificacao do CONJUNTO DE COMPONENTES entre A e B. Sem ela, uma
   configuracao com gelo comparada contra outra sem gelo passava sem sinal: as
   linhas de componente ausente eram puladas, e a linha TOTAL comparava somas
   de conjuntos diferentes. Num caso de teste com quatro componentes em A e
   tres em B, o custo de maquina saiu 0,977 em vez de 1,062, ou seja, o
   veredito anunciaria melhora de 2,3% onde havia degradacao de 6,2%.
4. Nova verificacao do EIXO ESPACIAL. O experimento exige layout SHARED; com
   split o 'select' e' heterogeneo, cada bloco fecha em nos inteiros e a
   configuracao B nao ocupa um no' so'.
5. A agregacao entre repeticoes passou a usar a intersecao das chaves, para
   que uma divergencia de componentes chegue a' mensagem de erro em vez de
   estourar antes com KeyError.

CONTEXTO
--------
O no de calculo da Jaci tem 256 cores fisicos (2 sockets x 128 Zen5) com SMT
ligado, o que expoe 512 CPUs logicas. O run_esmApp.jaci permite duas formas de
alocar o mesmo numero de PETs:

  A)  bash run_esmApp.jaci -n 512                        -> 2 nos x 256
      1 rank por core fisico; a segunda thread de cada core fica ociosa.

  B)  bash run_esmApp.jaci -n 512 --ppn 512 --allow-smt  -> 1 no x 512
      2 ranks por core fisico; o SMT passa a ser efetivamente usado.

Este script le os logs de PET das duas configuracoes e responde se B e mais
lento, igual ou mais rapido que A, e em qual componente a diferenca aparece.
Os componentes reconhecidos sao MED, MPAS, OCN e ICE; o de gelo aparece apenas
quando use_sis2_dynamic esta' ligado, e precisa estar ligado (ou desligado) nas
DUAS configuracoes.

METODOLOGIA
-----------
1. Cada chamada de um componente delimita-se pelo par de marcadores
   "<COMP>: Run intro." e "<COMP>: Run extro." no log do PET. A duracao e a
   diferenca entre os dois instantes.

2. Acumula-se a SOMA das duracoes dentro de cada passo de acoplamento, e nao a
   media por chamada. Componentes que subciclam internamente podem registrar
   mais de um par por passo, e a media por chamada compararia uma chamada longa
   com varias curtas, subestimando o custo de quem subcicla.

3. ATENCAO AO CONFUNDIMENTO. Com o mesmo numero de PETs, B usa METADE dos nos
   de A e, portanto, metade dos cores fisicos. O tempo de parede de B seria
   2,00x o de A mesmo que o SMT fosse perfeitamente neutro. O efeito atribuivel
   ao SMT e o EXCESSO sobre esse fator, e por isso o script normaliza pelo
   numero de nos e reporta o custo em NO x SEGUNDO por passo, que e a grandeza
   comparavel entre as duas configuracoes (e a que aparece na fatura de
   node-hours). Informe os nos com --nos-a e --nos-b.

4. O custo de um componente num passo e o MAIOR tempo entre os PETs, e nao a
   media, porque os PETs se sincronizam em barreiras coletivas: o grupo so
   avanca quando o ultimo termina, e o tempo ocioso dos PETs rapidos e
   desperdicio, nao economia.

5. O EXPERIMENTO EXIGE MODO SEQUENTIAL E LAYOUT SHARED. Em concurrent o tempo
   por passo e o MAIOR dos avancos, e o balanceamento entre os blocos muda
   entre as configuracoes. Em layout split o 'select' e' heterogeneo, com um
   chunk por componente, e a configuracao B nao cai num no' so': a razao de nos
   deixa de ser a que o teste supoe. A autoverificacao avisa nos dois casos.

6. O primeiro passo e descartado por padrao (--descartar). Ele carrega alocacao
   preguicosa, primeiro toque de paginas de memoria e o custo inicial dos
   conectores, e nao e representativo do regime permanente.

USO
---
  python3 mede_smt.py
  python3 mede_smt.py --a logs.A1 logs.A2 logs.A3 --b logs.B1 logs.B2 logs.B3
  python3 mede_smt.py --descartar 2 --csv resultado.csv --grafico smt.png
  python3 mede_smt.py --padrao 'PET*.esmApp.log'         # nome fora do usual
  python3 mede_smt.py --nos-a 4 --nos-b 2                # outra razao de nos
  python3 mede_smt.py --jobs 16          # paralelismo na leitura dos logs

Saida: tabela comparativa por componente e por passo, com a razao B/A.
"""

import argparse
import glob
import os
import re
import statistics
import sys
from datetime import datetime

# Marcador limpo do ESMF/NUOPC. O sufixo "." no fim e essencial: as linhas de
# StateLog repetem "Run intro" seguido de "{IS}:" e nao delimitam a chamada.
PADRAO = re.compile(
    rb"^(\d{8}) (\d{6}\.\d{3})\s+\w+\s+PET(\d+)\s+(\w+):\s+Run (intro|extro)\.\s*$",
    re.MULTILINE,
)

# Ordem de exibicao. O leitor de logs e generico (o padrao casa qualquer
# rotulo de componente), entao o ICE ja aparecia; sem estar nesta lista, porem,
# caia no rabo alfabetico e vinha antes de MPAS e OCN, sugerindo uma
# importancia que nao tem.
ORDEM_PADRAO = ["MED", "MPAS", "OCN", "ICE"]

# ── Autoverificacao ─────────────────────────────────────────────────────────
# O script nao pode confiar apenas no NOME do diretorio: trocar logs.A por
# logs.B inverteria a conclusao sem qualquer sinal. Estes padroes extraem do
# proprio conteudo o modo de acoplamento (log de PET) e a topologia com o
# regime de ocupacao do core (banner do job), permitindo conferir que cada
# configuracao e o que se supoe que seja.
# ATENCAO AO FORMATO DA LINHA (corrigido em Set/2026). Ate' esta revisao o
# padrao era apenas "ESM: modo SEQUENTIAL|CONCURRENT", que e' o formato ANTERIOR
# a' v14.20. Desde a separacao dos dois eixos o driver grava
#   "ESM: layout SPLIT (execucao SEQUENTIAL) - ATM=PET[...] ..."
# que nao casava. O efeito era que o conjunto de modos ficava vazio com binario
# atual e TRES verificacoes eram puladas em silencio: a de consistencia entre
# rodadas, a de igualdade entre A e B, e o aviso de modo concorrente. Justamente
# as que protegem contra o erro mais grave do experimento, medir no modo errado.
MODO_RE   = re.compile(
    rb"ESM:\s*(?:modo\s+(?P<antigo>SEQUENTIAL|CONCURRENT)"
    rb"|layout\s+\w+\s*\(\s*execucao\s+(?P<novo>SEQUENTIAL|CONCURRENT)\s*\))",
    re.I)
# Eixo espacial, disponivel apenas no formato v14.20+. O teste de SMT precisa
# rodar em layout SHARED; ver a checagem em autoverifica().
LAYOUT_RE = re.compile(rb"ESM:\s*layout\s+(SPLIT|SHARED)", re.I)
TOPO_RE   = re.compile(r"TOPO\s*[:=]\s*(\d+)\s*n[oó]", re.I)
REGIME_RE = re.compile(r"REGIME\s*[:=]\s*(.+)")
BANNERS   = ("esmApp_run.log", "*.pbs", "*.o[0-9]*")

# Nome do arquivo de log de um PET. O ESMF grava "PET000.esmApp.log" no Jaci,
# mas variantes com sublinhado aparecem quando os arquivos sao transferidos ou
# renomeados. O numero e obrigatorio, o que descarta o "esmApp_run.log" que
# convive no mesmo diretorio e nao pertence a nenhum PET.
NOME_PET = re.compile(r"^PET(\d+)[._].*\.log$")


def lista_pets(diretorio, padrao=None):
    """Devolve os logs de PET de um diretorio, ordenados pelo numero do PET.

    Com --padrao, usa o glob informado sem filtragem adicional.
    """
    if padrao:
        return sorted(glob.glob(os.path.join(diretorio, padrao)))
    achados = []
    for caminho in glob.glob(os.path.join(diretorio, "PET*")):
        m = NOME_PET.match(os.path.basename(caminho))
        if m:
            achados.append((int(m.group(1)), caminho))
    return [c for _, c in sorted(achados)]


# ───────────────────────────── leitura dos logs ────────────────────────────
def _instante(data: bytes, hora: bytes) -> float:
    """Converte 'YYYYMMDD' + 'HHMMSS.mmm' em segundos absolutos (epoch)."""
    t = datetime.strptime(data.decode() + hora.decode()[:6], "%Y%m%d%H%M%S")
    return t.timestamp() + float(hora[6:].decode() or 0)


def le_pet(caminho):
    """Le um log de PET e devolve {componente: [duracao_do_par, ...]}.

    Os pares saem na ordem de ocorrencia, que corresponde a ordem dos passos de
    acoplamento. Pares orfaos (intro sem extro, ou o inverso) sao ignorados e
    contabilizados como inconsistencia.
    """
    with open(caminho, "rb") as fh:
        bruto = fh.read()

    abertos, duracoes, orfaos = {}, {}, 0
    for m in PADRAO.finditer(bruto):
        data, hora, _pet, comp, tipo = m.groups()
        comp = comp.decode()
        t = _instante(data, hora)
        if tipo == b"intro":
            if comp in abertos:
                orfaos += 1          # intro repetido sem extro
            abertos[comp] = t
        else:
            if comp not in abertos:
                orfaos += 1          # extro sem intro
                continue
            duracoes.setdefault(comp, []).append(t - abertos.pop(comp))
    orfaos += len(abertos)           # intro no fim do arquivo, sem extro
    return duracoes, orfaos


def le_meta(diretorio, arquivos):
    """Extrai do conteudo dos logs o modo de acoplamento e, quando o banner do
    job estiver presente, o numero de nos e o regime de ocupacao do core.

    Devolve um dicionario com as chaves 'modo', 'nos' e 'regime'; valores
    ausentes vem como None, e nesse caso a checagem correspondente e apenas
    pulada, nunca inventada.
    """
    meta = {"modo": None, "layout": None, "nos": None, "regime": None}

    if arquivos:
        with open(arquivos[0], "rb") as fh:
            bruto = fh.read()
        m = MODO_RE.search(bruto)
        if m:
            achado = m.group("antigo") or m.group("novo")
            meta["modo"] = achado.decode().upper()
        ml = LAYOUT_RE.search(bruto)
        if ml:
            meta["layout"] = ml.group(1).decode().upper()
        elif meta["modo"] and not ml:
            # Formato <= v14.19: os dois eixos eram um so'. 'CONCURRENT'
            # implicava PETs disjuntos, 'SEQUENTIAL' implicava compartilhados.
            meta["layout"] = ("SPLIT" if meta["modo"] == "CONCURRENT"
                              else "SHARED")

    for alvo in BANNERS:
        for caminho in sorted(glob.glob(os.path.join(diretorio, alvo))):
            try:
                with open(caminho, "r", encoding="utf-8",
                          errors="replace") as fh:
                    texto = fh.read(200000)
            except OSError:
                continue
            mt, mr = TOPO_RE.search(texto), REGIME_RE.search(texto)
            if mt:
                meta["nos"] = int(mt.group(1))
            if mr:
                meta["regime"] = mr.group(1).strip()
            if meta["nos"] or meta["regime"]:
                return meta
    return meta


def _tarefa(caminho):
    """Envolucro para o multiprocessing (precisa ser funcao de topo)."""
    try:
        d, o = le_pet(caminho)
        return caminho, d, o, None
    except Exception as exc:                                   # noqa: BLE001
        return caminho, {}, 0, str(exc)


def le_rodada(diretorio, jobs=1, padrao=None):
    """Le todos os PETs de um diretorio.

    Devolve (custos, n_pets, avisos), onde custos[componente] e uma lista com
    um valor por passo: o MAIOR tempo observado entre os PETs naquele passo.
    """
    arquivos = lista_pets(diretorio, padrao)
    if not arquivos:
        if not os.path.isdir(diretorio):
            raise FileNotFoundError(f"diretorio '{diretorio}' nao existe")
        amostra = sorted(os.listdir(diretorio))[:4]
        raise FileNotFoundError(
            f"nenhum log de PET reconhecido em '{diretorio}'. "
            f"Esperado algo como PET000.esmApp.log ou PET000_esmApp.log. "
            f"Encontrado: {', '.join(amostra) if amostra else '(vazio)'}"
            + (" ..." if len(os.listdir(diretorio)) > 4 else "")
            + ". Use --padrao para informar outro glob.")

    avisos = []
    if jobs > 1:
        from multiprocessing import Pool
        with Pool(jobs) as pool:
            bruto = pool.map(_tarefa, arquivos, chunksize=8)
    else:
        bruto = [_tarefa(a) for a in arquivos]

    # por_comp[comp] = lista de listas: uma lista de duracoes por PET
    por_comp, orfaos_total = {}, 0
    for caminho, duracoes, orfaos, erro in bruto:
        if erro:
            avisos.append(f"{os.path.basename(caminho)}: {erro}")
            continue
        orfaos_total += orfaos
        for comp, vals in duracoes.items():
            por_comp.setdefault(comp, []).append(vals)
    if orfaos_total:
        avisos.append(f"{orfaos_total} marcador(es) sem par, ignorado(s)")
    meta = le_meta(diretorio, arquivos)

    custos = {}
    for comp, listas in por_comp.items():
        n = {len(v) for v in listas}
        if len(n) > 1:
            avisos.append(
                f"{comp}: numero de pares difere entre PETs "
                f"({min(n)} a {max(n)}); truncado em {min(n)}")
        npassos = min(n)
        # Custo do passo = maximo entre PETs (limitado pela barreira coletiva).
        custos[comp] = [max(v[i] for v in listas) for i in range(npassos)]
    return custos, len(arquivos), avisos, meta


# ───────────────────────────── agregacao ───────────────────────────────────
def resume_rodada(custos, descartar):
    """Media por passo, por componente e do passo completo, apos o descarte."""
    comps = [c for c in ORDEM_PADRAO if c in custos]
    comps += [c for c in sorted(custos) if c not in comps]

    npassos = min(len(custos[c]) for c in comps)
    if npassos <= descartar:
        raise ValueError(
            f"apenas {npassos} passo(s); nada resta apos descartar {descartar}")

    fatia = {c: custos[c][descartar:npassos] for c in comps}
    total = [sum(fatia[c][i] for c in comps) for i in range(npassos - descartar)]
    medias = {c: statistics.fmean(fatia[c]) for c in comps}
    medias["PASSO"] = statistics.fmean(total)
    return medias, total, npassos - descartar, comps


def agrega(rodadas):
    """Media e desvio-padrao amostral entre as repeticoes de uma configuracao.

    Usa a INTERSECAO das chaves das repeticoes. Antes usava as chaves da
    primeira, o que estourava com KeyError caso uma repeticao tivesse um
    componente a mais (por exemplo, uma das tres rodadas feita com o gelo
    ligado). A divergencia em si e' apanhada pela autoverificacao, que
    interrompe a comparacao; a intersecao aqui evita que o erro apareca como
    excecao antes de a mensagem util ser impressa.
    """
    chaves = set(rodadas[0])
    for r in rodadas[1:]:
        chaves &= set(r)
    saida = {}
    for k in chaves:
        vals = [r[k] for r in rodadas]
        dp = statistics.stdev(vals) if len(vals) > 1 else 0.0
        saida[k] = (statistics.fmean(vals), dp, vals)
    return saida


# ───────────────────────────── apresentacao ────────────────────────────────
def barra(titulo, largura=78):
    print("\n" + "=" * largura)
    print(titulo)
    print("=" * largura)


def imprime(cfgA, cfgB, comps, meta, descartar, nos_a=2, nos_b=1):
    barra("MEDICAO DO EFEITO DO SMT - MONAN-A 2.0 x MOM6+SIS2")
    print(f"  A = 1 rank por core fisico   ({meta['A']})")
    print(f"  B = 2 ranks por core (SMT)   ({meta['B']})")
    print(f"  Passos considerados por rodada: {meta['npassos']} "
          f"(primeiro{'s' if descartar > 1 else ''} {descartar} descartado"
          f"{'s' if descartar > 1 else ''})")

    barra("TEMPO MEDIO POR PASSO DE ACOPLAMENTO (segundos)")
    cab = f"  {'Componente':<12}{'A (media)':>12}{'A (dp)':>9}" \
          f"{'B (media)':>12}{'B (dp)':>9}{'B/A':>9}{'Delta':>10}"
    print(cab)
    print("  " + "-" * (len(cab) - 2))
    for c in comps + ["PASSO"]:
        if c not in cfgA or c not in cfgB:
            continue
        ma, da, _ = cfgA[c]
        mb, db, _ = cfgB[c]
        razao = mb / ma if ma else float("nan")
        if c == "PASSO":
            print("  " + "-" * (len(cab) - 2))
        rot = "TOTAL" if c == "PASSO" else c
        print(f"  {rot:<12}{ma:>12.3f}{da:>9.3f}{mb:>12.3f}{db:>9.3f}"
              f"{razao:>9.3f}{(razao - 1) * 100:>9.1f}%")

    barra(f"CUSTO DE MAQUINA (no x segundo por passo)  -  A em {nos_a} no(s), "
          f"B em {nos_b} no(s)")
    print("  Normaliza pela quantidade de hardware: e a grandeza que isola o")
    print("  efeito do SMT do simples fato de B usar menos nos.")
    print()
    cab2 = f"  {'Componente':<12}{'A (no.s)':>12}{'B (no.s)':>12}{'B/A':>9}{'Delta':>10}"
    print(cab2)
    print("  " + "-" * (len(cab2) - 2))
    for c in comps + ["PASSO"]:
        if c not in cfgA or c not in cfgB:
            continue
        na = cfgA[c][0] * nos_a
        nb = cfgB[c][0] * nos_b
        r = nb / na if na else float("nan")
        if c == "PASSO":
            print("  " + "-" * (len(cab2) - 2))
        rot = "TOTAL" if c == "PASSO" else c
        print(f"  {rot:<12}{na:>12.3f}{nb:>12.3f}{r:>9.3f}{(r - 1) * 100:>9.1f}%")

    barra("RODADAS INDIVIDUAIS (tempo total por passo, em segundos)")
    for nome, cfg in (("A", cfgA), ("B", cfgB)):
        vals = cfg["PASSO"][2]
        detalhe = "   ".join(f"#{i+1} {v:.3f}" for i, v in enumerate(vals))
        print(f"  {nome}:  {detalhe}")

    # ── veredito ────────────────────────────────────────────────────────────
    ma, da, _ = cfgA["PASSO"]
    mb, db, _ = cfgB["PASSO"]
    razao = mb / ma
    # Incerteza da RAZAO: propagacao de erro relativo, cada desvio dividido pela
    # SUA propria media. Dividir o desvio de B pela media de A inflaria o ruido
    # sempre que B e A tiverem magnitudes diferentes, que e exatamente o caso.
    rel_a = da / ma if ma else 0.0
    rel_b = db / mb if mb else 0.0
    ruido = rel_a + rel_b                      # soma linear (conservadora)
    ruido_q = (rel_a ** 2 + rel_b ** 2) ** 0.5  # em quadratura (independentes)

    esperado = nos_a / nos_b if nos_b else float("nan")
    custo = (mb * nos_b) / (ma * nos_a) if ma else float("nan")

    barra("VEREDITO")
    print("  1) TEMPO DE PAREDE (time-to-solution)")
    print(f"     B/A = {razao:.3f}. Como B usa {nos_a}/{nos_b} do hardware de A, "
          f"o fator")
    print(f"     seria {esperado:.2f} mesmo com SMT neutro. Este numero NAO isola o SMT.")
    print()
    print("  2) CUSTO DE MAQUINA (no x segundo, efeito do SMT isolado)")
    print(f"     B/A = {custo:.3f}   "
          f"(incerteza: +/- {ruido * 100:.1f}% linear, "
          f"+/- {ruido_q * 100:.1f}% em quadratura)")
    print()
    efeito = abs(custo - 1)
    if efeito <= max(ruido_q, 0.02):
        print("     INCONCLUSIVO: a diferenca nao supera nem o criterio mais")
        print("     permissivo. Aumente o numero de rodadas.")
    elif efeito <= max(ruido, 0.02):
        sinal = "DEGRADA" if custo > 1 else "MELHORA"
        print(f"     MARGINAL: o SMT {sinal} em {efeito * 100:.1f}% o custo de")
        print("     maquina, acima do criterio em quadratura mas dentro da soma")
        print("     linear. Repita com mais rodadas antes de citar o valor.")
    elif custo > 1:
        print(f"     O SMT DEGRADA em {(custo - 1) * 100:.1f}% o custo de maquina.")
    else:
        print(f"     O SMT MELHORA em {(1 - custo) * 100:.1f}% o custo de maquina.")
    print()
    print("  3) DECISAO SOBRE O PADRAO")
    if razao > 1.02:
        print(f"     A e {razao:.2f}x mais rapido em tempo de parede. Para tempo")
        print("     de solucao, o padrao de 256 PET/no (PPN_PHYS) esta correto.")
    else:
        print("     B iguala ou supera A em tempo de parede; reveja o padrao.")
    if custo < 0.98:
        print("     Porem o SMT reduz o custo de maquina: se o gargalo for cota")
        print("     de node-hours, e nao prazo, --allow-smt pode compensar.")
    print()
    print("  Lembre-se de que B usa metade dos nos e, portanto, metade da")
    print("  memoria agregada. Um encerramento por falta de memoria (exit 137)")
    print("  em B e resultado da medicao, nao erro de configuracao.")


def grava_csv(caminho, cfgA, cfgB, comps):
    import csv
    with open(caminho, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["componente", "config", "media_s", "desvio_s", "rodadas_s"])
        for c in comps + ["PASSO"]:
            for nome, cfg in (("A", cfgA), ("B", cfgB)):
                if c in cfg:
                    m, d, vals = cfg[c]
                    w.writerow([c, nome, f"{m:.6f}", f"{d:.6f}",
                                ";".join(f"{v:.6f}" for v in vals)])
    print(f"\n  CSV gravado em: {caminho}")


def grava_grafico(caminho, cfgA, cfgB, comps):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("\n  AVISO: matplotlib indisponivel; grafico nao gerado.")
        return

    rotulos = [c for c in comps if c in cfgA and c in cfgB] + ["TOTAL"]
    chaves = [c for c in comps if c in cfgA and c in cfgB] + ["PASSO"]
    a = [cfgA[k][0] for k in chaves]
    b = [cfgB[k][0] for k in chaves]
    ea = [cfgA[k][1] for k in chaves]
    eb = [cfgB[k][1] for k in chaves]

    x = range(len(rotulos))
    larg = 0.38
    fig, ax = plt.subplots(figsize=(8.2, 4.4), dpi=160)
    ax.bar([i - larg / 2 for i in x], a, larg, yerr=ea, capsize=4,
           label="A: 1 rank por core fisico", color="#1C7293")
    ax.bar([i + larg / 2 for i in x], b, larg, yerr=eb, capsize=4,
           label="B: 2 ranks por core (SMT)", color="#B35C00")
    for i, (va, vb) in enumerate(zip(a, b)):
        if va:
            ax.text(i, max(va, vb) * 1.04, f"{vb / va:.2f}x",
                    ha="center", fontsize=9, color="#21295C")
    ax.set_xticks(list(x))
    ax.set_xticklabels(rotulos)
    ax.set_ylabel("tempo medio por passo de acoplamento (s)")
    ax.set_title("Efeito do SMT no sistema acoplado MONAN-A 2.0 x MOM6+SIS2")
    ax.legend(frameon=False)
    ax.spines[["top", "right"]].set_visible(False)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(caminho)
    print(f"  Grafico gravado em: {caminho}")


# ───────────────────────────── autoverificacao ─────────────────────────────
def autoverifica(metas, petcount, args, comps_por_cfg=None):
    """Confere, a partir do CONTEUDO dos logs, que A e B sao o que se supoe.

    Sem isso, trocar os diretorios logs.A por logs.B inverteria a conclusao sem
    qualquer sinal, num resultado que passou a sustentar uma decisao de
    projeto. Devolve True quando encontra erro que impede a comparacao.
    """
    erros, avisos = [], []

    # 1) Mesmo numero de PETs. E a premissa do teste controlado.
    if petcount["A"] != petcount["B"]:
        erros.append(
            f"A tem {petcount['A']} PETs e B tem {petcount['B']}. A comparacao "
            f"exige o mesmo numero de PETs nas duas configuracoes.")

    # 1b) Mesmo CONJUNTO DE COMPONENTES em A e B, e entre as repeticoes de cada
    # configuracao. Sem isso, uma rodada com use_sis2_dynamic ligado e outra
    # sem seriam comparadas assim mesmo: o ICE simplesmente nao apareceria na
    # tabela (as linhas so' saem quando o componente existe nas duas), e a
    # linha TOTAL, que soma os componentes, compararia somas de conjuntos
    # diferentes. O numero sairia menor em quem tem menos componentes, e a
    # conclusao seria atribuida ao SMT.
    if comps_por_cfg:
        for n in "AB":
            conjuntos = [frozenset(c) for c in comps_por_cfg.get(n, [])]
            if len(set(conjuntos)) > 1:
                erros.append(
                    f"as repeticoes de {n} nao tem os mesmos componentes: "
                    + " vs ".join(sorted("/".join(sorted(c)) for c in set(conjuntos))))
        cA = comps_por_cfg.get("A") or [[]]
        cB = comps_por_cfg.get("B") or [[]]
        sA, sB = frozenset(cA[0]), frozenset(cB[0])
        if sA and sB and sA != sB:
            falta_b = sorted(sA - sB)
            falta_a = sorted(sB - sA)
            detalhe = []
            if falta_b:
                detalhe.append("presente(s) so' em A: " + ", ".join(falta_b))
            if falta_a:
                detalhe.append("presente(s) so' em B: " + ", ".join(falta_a))
            erros.append("A e B nao tem os mesmos componentes ("
                         + "; ".join(detalhe)
                         + "). A comparacao exige a mesma configuracao.")

    # 2) Mesmo modo de acoplamento, e de preferencia sequential.
    modos = {n: {m["modo"] for _d, m in metas[n] if m["modo"]} for n in "AB"}
    for n in "AB":
        if len(modos[n]) > 1:
            erros.append(f"as rodadas de {n} misturam modos: {sorted(modos[n])}")
    if modos["A"] and modos["B"] and modos["A"] != modos["B"]:
        erros.append(f"A roda em {modos['A'].pop()} e B em {modos['B'].pop()}. "
                     f"O modo precisa ser o mesmo nas duas configuracoes.")
    todos = modos["A"] | modos["B"]
    if todos == {"CONCURRENT"}:
        avisos.append(
            "as rodadas estao em modo CONCURRENT. O teste do SMT deve ser feito "
            "em SEQUENTIAL: em concurrent o tempo por passo e max(t_ATM, t_OCN) "
            "e o balanceamento entre os blocos muda entre as configuracoes, "
            "confundindo o resultado.")

    # 2b) Eixo espacial. O experimento de SMT exige layout SHARED.
    #
    # Com pet_layout='split' o run_esmApp.jaci monta um 'select' HETEROGENEO,
    # com um chunk por componente, e cada bloco fecha em nos inteiros. A
    # configuracao B nao cai num no' so': ela usa pelo menos um no' por bloco,
    # e a razao de nos entre A e B deixa de ser a que o teste supoe. O numero
    # lido do banner corrige a conta (item 4 abaixo), mas o experimento ja' nao
    # e' o que se queria: A e B passam a diferir tambem na topologia dos
    # blocos, e nao apenas na ocupacao do core.
    layouts = {n: {m["layout"] for _d, m in metas[n] if m["layout"]}
               for n in "AB"}
    todos_lay = layouts["A"] | layouts["B"]
    if "SPLIT" in todos_lay:
        avisos.append(
            "ha' rodada(s) em layout SPLIT. O teste do SMT deve ser feito em "
            "SHARED: com split o 'select' e' heterogeneo, cada bloco fecha em "
            "nos inteiros, e a configuracao B nao ocupa um no' so'. Confira o "
            "numero de nos no banner antes de citar qualquer razao.")
    if layouts["A"] and layouts["B"] and layouts["A"] != layouts["B"]:
        erros.append(
            f"A roda em layout {'/'.join(sorted(layouts['A']))} e B em "
            f"{'/'.join(sorted(layouts['B']))}. O layout precisa ser o mesmo.")

    # 3) Regime de ocupacao do core, quando o banner do job estiver presente.
    for n, esperado, rotulo in (("A", False, "1 rank por core fisico"),
                                ("B", True, "SMT ativo")):
        for d, m in metas[n]:
            if not m["regime"]:
                continue
            if "INDETERMINAD" in m["regime"].upper():
                avisos.append(f"'{d}' declara REGIME indeterminado; a "
                              f"verificacao de regime foi pulada.")
                continue
            tem_smt = "SMT ATIVO" in m["regime"].upper()
            if tem_smt != esperado:
                erros.append(
                    f"'{d}' declara REGIME '{m['regime']}', incompativel com "
                    f"a configuracao {n} ({rotulo}). Os diretorios de A e B "
                    f"podem estar trocados.")

    # 4) Numero de nos lido do banner prevalece sobre --nos-a / --nos-b.
    for n, attr in (("A", "nos_a"), ("B", "nos_b")):
        lidos = {m["nos"] for _d, m in metas[n] if m["nos"]}
        if not lidos:
            continue
        if len(lidos) > 1:
            erros.append(f"as rodadas de {n} usam numeros de nos diferentes: "
                         f"{sorted(lidos)}")
            continue
        lido = lidos.pop()
        if lido != getattr(args, attr):
            avisos.append(f"banner de {n} indica {lido} no(s); o valor "
                          f"informado era {getattr(args, attr)}. Usando o do "
                          f"banner.")
            setattr(args, attr, lido)

    for a in avisos:
        print(f"  AVISO: {a}", file=sys.stderr)
    for e in erros:
        print(f"  ERRO: {e}", file=sys.stderr)
    if erros:
        print("  Comparacao interrompida: a autoverificacao dos logs falhou.",
              file=sys.stderr)
    return bool(erros)


# ───────────────────────────── principal ───────────────────────────────────
def main():
    ap = argparse.ArgumentParser(
        description="Compara o tempo por passo de acoplamento com e sem uso "
                    "do SMT, a partir dos logs de PET do ESMF.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a", nargs="+", default=["logs.A1", "logs.A2", "logs.A3"],
                    metavar="DIR", help="diretorios da configuracao A "
                                        "(padrao: logs.A1 logs.A2 logs.A3)")
    ap.add_argument("--b", nargs="+", default=["logs.B1", "logs.B2", "logs.B3"],
                    metavar="DIR", help="diretorios da configuracao B "
                                        "(padrao: logs.B1 logs.B2 logs.B3)")
    ap.add_argument("--nos-a", type=int, default=2, metavar="N",
                    dest="nos_a", help="nos usados pela configuracao A "
                                       "(padrao: 2)")
    ap.add_argument("--nos-b", type=int, default=1, metavar="N",
                    dest="nos_b", help="nos usados pela configuracao B "
                                       "(padrao: 1)")
    ap.add_argument("--descartar", type=int, default=1, metavar="N",
                    help="passos iniciais a descartar (padrao: 1)")
    ap.add_argument("--padrao", metavar="GLOB",
                    help="glob dos logs de PET, quando o nome fugir do usual "
                         "(ex.: 'PET*.esmApp.log')")
    ap.add_argument("--jobs", type=int, default=1, metavar="N",
                    help="processos paralelos na leitura dos logs (padrao: 1)")
    ap.add_argument("--csv", metavar="ARQ", help="grava os resultados em CSV")
    ap.add_argument("--grafico", metavar="ARQ.png",
                    help="grava um grafico de barras comparativo")
    args = ap.parse_args()

    if args.descartar < 0:
        ap.error("--descartar nao pode ser negativo")

    resultados, comps_ref, meta = {}, None, {}
    metas = {"A": [], "B": []}
    comps_por_cfg = {"A": [], "B": []}
    petcount = {}
    for nome, dirs in (("A", args.a), ("B", args.b)):
        rodadas, npassos, npets = [], [], []
        for d in dirs:
            try:
                custos, n, avisos, meta_dir = le_rodada(
                    d, args.jobs, args.padrao)
                medias, _tot, np_, comps = resume_rodada(custos, args.descartar)
            except (FileNotFoundError, ValueError) as exc:
                print(f"ERRO em '{d}': {exc}", file=sys.stderr)
                return 1
            for w in avisos:
                print(f"  AVISO [{d}]: {w}", file=sys.stderr)
            rodadas.append(medias)
            npassos.append(np_)
            npets.append(n)
            metas[nome].append((d, meta_dir))
            comps_por_cfg[nome].append(list(comps))
            # Uniao ordenada, e nao "a primeira que aparecer": um componente
            # presente so' em B (ou so' na segunda repeticao) precisa constar
            # da lista para que a autoverificacao possa reclamar dele.
            if comps_ref is None:
                comps_ref = list(comps)
            else:
                comps_ref += [c for c in comps if c not in comps_ref]
        if len(set(npets)) > 1:
            print(f"  AVISO: numero de PETs difere entre as rodadas de {nome}: "
                  f"{npets}", file=sys.stderr)
        if len(set(npassos)) > 1:
            print(f"  AVISO: numero de passos difere entre as rodadas de "
                  f"{nome}: {npassos}", file=sys.stderr)
        resultados[nome] = agrega(rodadas)
        meta[nome] = f"{npets[0]} PETs, {len(dirs)} rodada(s)"
        meta["npassos"] = min(npassos)
        petcount[nome] = npets[0]

    # Reordena a uniao pela ordem de exibicao, para que MED/MPAS/OCN/ICE saiam
    # sempre na mesma sequencia, independentemente de onde cada um apareceu.
    comps_ref = ([c for c in ORDEM_PADRAO if c in comps_ref]
                 + sorted(c for c in comps_ref if c not in ORDEM_PADRAO))

    if autoverifica(metas, petcount, args, comps_por_cfg):
        return 1

    cfgA, cfgB = resultados["A"], resultados["B"]
    imprime(cfgA, cfgB, comps_ref, meta, args.descartar,
            args.nos_a, args.nos_b)
    if args.csv:
        grava_csv(args.csv, cfgA, cfgB, comps_ref)
    if args.grafico:
        grava_grafico(args.grafico, cfgA, cfgB, comps_ref)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
