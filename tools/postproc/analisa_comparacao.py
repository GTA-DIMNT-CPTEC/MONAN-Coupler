#!/usr/bin/env python3
"""Lê comparacao_standalone_cap.csv e imprime resumo estatístico por campo.

Versão : 1.4 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

Histórico:
  v1.4 (13/05/2026):
    [N1] quality_badge — guarda contra sigma_cap negativo (improvável mas defensivo).
    [N2] load_csv — mensagem de erro aprimorada ao encontrar CSV vazio.
    [N3] build_table — variável 'sratio' renomeada para 'sflag' para evitar
         ambiguidade com o valor numérico da razão calculado em row_line.
    [N4] Versão do script alinhada com demais scripts de pós-processamento.
  v1.3 (25/04/2026):
    [N1] Caminho CSV atualizado: diag_export/postproc/ (era postproc_standalone/).
    [N2] argparse com --help, --csv, --no-interp.
    [N3] Tratamento explícito de FileNotFoundError e CSV malformado.
    [N4] encoding=utf-8 em open(); fallback latin-1 para CSVs antigos.
    [N5] Notas de interpretação atualizadas para Experimentos 4.2-5.x
         (DOCN modo netcdf, 9 OK 0 avisos — SST variável via OISST v2.1).
    [N6] Novos campos Sa_shum_mpas e Faxa_snow_mpas na tabela de thresholds.
    [N7] Coluna sigma_ratio com flag (≈ dentro 5%, ↑ SA maior, ↓ cap maior).
    [N8] Coluna Q (qualidade: ❶ excelente ❷ muito bom ❸ bom ❹ revisar).
  v1.2 (21/04/2026):
    [N1] SST corrigida de 298 K para 290 K (OCN stub mom_cap.F90 v1.0).
    [N2] Interpretação acswdnb atualizada para bias negativo correto.
    [N3] Classificação de qualidade por faixa de Corr.
    [N4] Razão sigma_SA/sigma_cap para diagnóstico de variabilidade espacial.

Uso:
    python3 analisa_comparacao.py
    python3 analisa_comparacao.py --csv diag_export/postproc/comparacao_standalone_cap.csv
    python3 analisa_comparacao.py --no-interp

Padrão: diag_export/postproc/comparacao_standalone_cap.csv
"""

import sys
import csv
import math
import argparse
import numpy as np
from collections import defaultdict
from pathlib import Path


def quality_badge(corr, rmse, sigma_cap):
    """Retorna ❶/❷/❸/❹ com base em Corr e RMSE/sigma."""
    if math.isnan(corr) or sigma_cap <= 0:   # <= 0 defensivo (sigma nunca negativo)
        return "?"
    pct = 100.0 * rmse / sigma_cap
    if corr >= 0.999 and pct <= 5:
        return "❶"
    if corr >= 0.990 and pct <= 20:
        return "❷"
    if corr >= 0.975:
        return "❸"
    return "❹"


def sigma_ratio_flag(s_sa, s_ca):
    """≈ dentro de 5%, ↑ SA maior, ↓ cap maior."""
    if s_ca == 0:
        return "?"
    r = s_sa / s_ca
    if abs(r - 1.0) < 0.05:
        return "≈"
    return "↑" if r > 1.0 else "↓"


def parse_args():
    p = argparse.ArgumentParser(
        description="Resumo estatístico: comparação standalone vs cap NUOPC.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemplos:
  python3 analisa_comparacao.py
  python3 analisa_comparacao.py --csv diag_export/postproc/comparacao_standalone_cap.csv
  python3 analisa_comparacao.py --no-interp
        """)
    p.add_argument(
        "--csv", metavar="ARQUIVO",
        default="diag_export/postproc/comparacao_standalone_cap.csv",
        help="Arquivo CSV de comparação (padrão: diag_export/postproc/comparacao_standalone_cap.csv)")
    p.add_argument(
        "--no-interp", action="store_true",
        help="Omitir seção de interpretação física (apenas tabela)")
    return p.parse_args()


def load_csv(csvfile):
    if not Path(csvfile).exists():
        print(f"\nERRO: arquivo não encontrado: {csvfile}")
        print("  Gerar com: python3 postproc_monan2_standalone.py --compare")
        sys.exit(1)

    required = {"campo_standalone", "campo_cap", "bias_global",
                "rmse_global", "corr_global", "std_standalone",
                "std_cap", "n_bins_validos"}

    rows = defaultdict(list)
    encodings = ["utf-8", "latin-1"]
    warned_enc = False

    for enc in encodings:
        try:
            with open(csvfile, encoding=enc, newline="") as fh:
                reader = csv.DictReader(fh)
                missing_cols = required - set(reader.fieldnames or [])
                if missing_cols:
                    print(f"\nERRO: colunas ausentes no CSV: {missing_cols}")
                    print("  Verificar versão do postproc_monan2_standalone.py (requer >= v1.3)")
                    sys.exit(1)
                for r in reader:
                    key = (r["campo_standalone"], r["campo_cap"])
                    try:
                        corr_raw = r["corr_global"]
                        rows[key].append((
                            float(r["bias_global"]),
                            float(r["rmse_global"]),
                            float(corr_raw) if corr_raw not in ("nan", "", "NaN") else float("nan"),
                            float(r["std_standalone"]),
                            float(r["std_cap"]),
                            int(r["n_bins_validos"]),
                        ))
                    except (ValueError, KeyError) as e:
                        print(f"  AVISO: linha ignorada ({e}): {dict(r)}")
            if enc == "latin-1" and not warned_enc:
                print("  AVISO: CSV lido com encoding latin-1; regenerar com postproc v1.3+")
            break
        except UnicodeDecodeError:
            continue

    if not rows:
        print(f"\nERRO: CSV vazio ou sem linhas válidas: {csvfile}")
        sys.exit(1)

    return rows


def build_table(rows):
    max_sa  = max((len(k[0]) for k in rows), default=8)
    max_cap = max((len(k[1]) for k in rows), default=9)
    C = dict(sa=max(max_sa, 8), cap=max(max_cap, 9),
             bias=10, rmse=10, corr=6, sga=9, sgc=9,
             ratio=8, bins=6, n=2)

    def hdr():
        return (f" {'Campo SA':>{C['sa']}} | {'Campo cap':>{C['cap']}} | {'Bias':>{C['bias']}}"
                f" | {'RMSE':>{C['rmse']}} | {'Corr':>{C['corr']}} | {'sigma SA':>{C['sga']}}"
                f" | {'sigma cap':>{C['sgc']}} | {'sig.ratio':>{C['ratio']}} | {'Bins':>{C['bins']}}"
                f" | {'N':>{C['n']}} | Q ")

    def row_line(f_sa, f_cap, bias, rmse, corr, s_sa, s_ca, bins, nstep, badge, sflag):
        cs = f"{corr:{C['corr']}.3f}" if not math.isnan(corr) else f"{'nan':>{C['corr']}}"
        ratio_val = f"{s_sa/s_ca:.3f}{sflag}" if s_ca != 0 else "   —  "
        return (f" {f_sa:>{C['sa']}} | {f_cap:>{C['cap']}} | {bias:>+{C['bias']}.4f}"
                f" | {rmse:>{C['rmse']}.4f} | {cs} | {s_sa:>{C['sga']}.4f}"
                f" | {s_ca:>{C['sgc']}.4f} | {ratio_val:>{C['ratio']}} | {bins:>{C['bins']}}"
                f" | {nstep:>{C['n']}} | {badge} ")

    W = len(hdr()) + 2
    title = " COMPARAÇÃO STANDALONE vs CAP NUOPC — resumo por campo (médias sobre passos) "
    sep_t = "╔" + "═" * (W-2) + "╗"
    sep_m = "╠" + "═" * (W-2) + "╣"
    sep_h = "╠" + "─" * (W-2) + "╣"
    sep_r = "╟" + "─" * (W-2) + "╢"
    sep_b = "╚" + "═" * (W-2) + "╝"

    out = ["", sep_t, "║" + title.center(W-2) + "║", sep_m,
           "║" + hdr() + "║", sep_h]

    items = sorted(rows.items())
    for idx, ((f_sa, f_cap), vals) in enumerate(items):
        bias  = float(np.nanmean([v[0] for v in vals]))
        rmse  = float(np.nanmean([v[1] for v in vals]))
        corr  = float(np.nanmean([v[2] for v in vals]))
        s_sa  = float(np.nanmean([v[3] for v in vals]))
        s_ca  = float(np.nanmean([v[4] for v in vals]))
        bins  = int(np.mean([v[5] for v in vals]))
        nstep = len(vals)
        badge  = quality_badge(corr, rmse, s_ca)
        sflag  = sigma_ratio_flag(s_sa, s_ca)
        out.append("║" + row_line(f_sa, f_cap, bias, rmse, corr,
                                   s_sa, s_ca, bins, nstep, badge, sflag) + "║")
        if idx < len(items) - 1:
            out.append(sep_r)

    out.append(sep_b)
    return "\n".join(out)


INTERP = """
  Legenda:
  · N          = passos usados na média temporal
  · Bins       = pontos válidos na grade lat/lon 1°x1°
  · sig.ratio  = sigma_SA / sigma_cap
                 ≈ dentro de 5%  |  ↑ SA mais variável  |  ↓ cap mais variável
  · Q (qualidade):
      ❶ excelente  (Corr >= 0,999  e  RMSE/sigma < 5%)
      ❷ muito bom  (Corr >= 0,990  e  RMSE/sigma < 20%)
      ❸ bom        (Corr >= 0,975)
      ❹ revisar    (abaixo dos thresholds)

  Nota sobre SST (evolução das fases):
  · Fase 1 stub   : SST = 290,0 K constante (mom_cap.F90 v1.0)
  · Fase 1 netcdf : SST = OISST v2.1 diario (271-305 K, interp. temporal)
  · Fase 2 MOM6   : SST calculada dinamicamente pelo modelo oceanico

  Com OCN stub (290 K): delta_SST > 0 nos tropicos -> bias positivo em T2m e
    bias negativo em Faxa_swdn (SST fria -> menos nuvens -> mais SW no cap).
  Com OISST netcdf: delta_SST aprox 0 -> Corr esperado proximo de 1,000.

  Interpretacao por campo (referencia: Experimentos 4.2-5.x, 2026-03-29, 128 PETs):

  Sa_pslv_mpas (❶ esperado  Corr >= 0,999  RMSE/sigma < 1%):
    Pressao ao nivel do mar nao responde a SST em escala de horas.
    Valida que Sa_pslv_mpas e zero-copy fiel ao pool MPAS-A.

  Sa_tbot_mpas (❷ esperado  Corr >= 0,998  RMSE/sigma < 5%):
    Com SST=290 K: bias +0,05 K; sensibilidade dT2m/dSST aprox 0,12 K/K.
    Com OISST: bias < 0,01 K esperado (delta_SST pequeno).

  Sa_u10m_mpas / Sa_v10m_mpas (❷ esperado  Corr >= 0,995  RMSE/sigma < 10%):
    Sensiveis ao posicionamento de sistemas de pressao.
    RMSE pontual maior que T2m mesmo com Corr alto. Bias < 0,015 m/s.

  Faxa_swdn_mpas (❸ esperado  Corr >= 0,975  RMSE/sigma < 40%):
    Com SST fria: menos nuvens no cap -> sigma_cap > sigma_SA (↓), bias negativo.
    Com OISST: bias reduzido; sig.ratio mais proximo de 1.

  Faxa_rain_mpas (❷/❸ esperado  Corr >= 0,985):
    Alta variabilidade natural; RMSE/sigma alto e esperado.
    Verificar que Delta(rainnc+rainc)/dt e calculado no intervalo de acoplamento.

  Sa_shum_mpas (❷ esperado -- Fase 2, quando use_med_to_mpas=true):
    Umidade especifica 2m de q2 (pool diag_physics).
    Requer bl_mynn_in ou bl_ysu_in em namelist.atmosphere.
    Fallback Tetens x RH=0,80 ativo se q2 nao disponivel.

  Faxa_snow_mpas (❸ esperado -- Fase 2):
    Precipitacao solida = Delta_snownc/dt. Requer mp_thompson_in ou mp_wsm6_in.
    RMSE alto esperado por distribuicao esparsa e sensibilidade a temperatura.
    sig.ratio pode ser baixo se microfisica nao estiver ativa (campo = 0).
"""


def main():
    args = parse_args()
    rows = load_csv(args.csv)
    print(build_table(rows))
    if not args.no_interp:
        print(INTERP)


if __name__ == "__main__":
    main()
