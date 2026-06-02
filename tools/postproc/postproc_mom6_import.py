#!/usr/bin/env python3
"""
postproc_mom6_import.py  —  Validação dos campos importados pelo MOM6+SIS2
                              (14 fluxos ATM→OCN calculados pelo mediador NCAR
                               bulk em MED_cap.F90)

Versão 8.2 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

HISTÓRICO DE CORREÇÕES
  v8.2 — BUG-PY-15 (Maio 2026):
    • BUG-PY-15 (A/C): cfeature.LAND ausente em plot_maps.
                 A função adicionava apenas COASTLINE e BORDERS, sem preencher
                 o interior dos continentes.  Isso gerava dois artefatos visuais:
                 1. Patches brancos (NaN transparente sobre fundo branco da figura)
                    em campos oceânicos — Foxx_lwnet, onda curta e precipitação —
                    onde a grade não calcula fluxos sobre terra.
                 2. So_duu10n e outros campos atmosféricos exibiam dados de vento
                    calculados sobre terra sem nenhuma máscara geográfica, tornando
                    o mapa difícil de interpretar.
                 Correção: cfeature.LAND desenhada em zorder=5 (acima do
                 pcolormesh em zorder=1); COASTLINE e BORDERS elevados para
                 zorder=6, mantendo-se visíveis sobre a máscara de terra.
    • BUG-PY-15 (B): fill_min_threshold de So_t elevado de 270.0 K para 271.4 K.
                 O marcador-stub do Sprint A.5 coloca pontos de terra/gelo em
                 271.35 K — acima do limiar antigo (270 K) e por isso não
                 mascarado.  Isso gerava patches azuis retangulares em áreas
                 oceânicas no mapa de SST.
                 271.4 K captura 271.35 K sem mascarar SST oceânica real,
                 cujo mínimo observado é ≈ 271.8 K.
                 vmin_phys atualizado consistentemente para 271.4 K.

  v8.1 — Renomeação de arquivos de saída (Maio 2026):
    • Mapas por passo : import_YYYYMMDD_HHMMSS.png  → mom6_import_YYYYMMDD_HHMMSS.png
    • Série temporal  : import_timeseries.png        → mom6_import_timeseries.png
    Padrão agora consistente com o prefixo dos arquivos NetCDF de entrada
    (mom6_import_*.nc) e com o script de animação anim_mom6_import.py.
  v8.0 — BUG-PY-14 (Maio 2026):
    • BUG-PY-14 (A): Si_ifrac — escala adaptativa em plot_maps.
                 O campo Si_ifrac é binário (0 ou 1). Com vmax=1.0 (padrão),
                 as células polares com gelo (~0.05% da área) são visualmente
                 invisíveis numa projeção global. Detecta automaticamente
                 campos binários (max=1, p95=0) e aplica:
                   vmax_efetivo = max(mean * 30, 0.005)
                 tornando o gelo visível com colorbar interpretável.
                 Paleta alterada para 'Blues' (intensidade de gelo) e
                 annotation com área de gelo estimada.
    • BUG-PY-14 (B): Si_ifrac — série temporal com eixo Y adaptativo.
                 Com escala linear [0, 1], a curva de Si_ifrac (mean ~0.0005)
                 aparece como linha reta no zero. Aplica escala simétrica-log
                 (symlog com linthresh=1e-4) quando o sinal está abaixo de
                 0.1, tornando o crescimento de gelo legível.
    • BUG-PY-14 (C): So_t passo all-NaN — subplot informativo em vez de vazio.
                 Quando So_t é 100% NaN num passo (passo 1: campo indisponível
                 antes do primeiro avanço do MOM6), o subplot era pulado com
                 'continue', deixando espaço em branco desorientador.
                 Agora exibe painel cinza com texto "Campo indisponível /
                 aguardando primeiro passo MOM6" para clareza diagnóstica.
    • BUG-PY-14 (D): So_t — mascaramento do seam tripolar.
                 A grade MOM6 (tripolar) tem uma descontinuidade de longitude
                 que aparece como linha branca vertical no mapa após o roll
                 de 0→360° para -180→180°. Aplica máscara automática de
                 descontinuidade: células onde |Δlon_vizinho| > 90° são
                 mascaradas como NaN antes do pcolormesh, eliminando o artefato
                 sem alterar os dados físicos.
    • BUG-PY-13 (C) rev.2: So_duu10n — vmax_phys calibrado de 900 para 1600 m²/s².
                 Experimentos reais mostram máximos de 967–1459 m²/s² (|ΔV| ≈ 31–38 m/s)
                 em ciclones extratropicais e furacões presentes no campo MPAS — valores
                 fisicamente legítimos que disparavam falsos positivos com 900 m²/s².
                 1600 m²/s² ≡ |ΔV| ≤ 40 m/s: teto físico real para vento em superfície
                 oceânica; acima disso configura artefato numérico.
                 check_msg atualizado para informar o limite e a ação sugerida.

  v7.0 — BUG-PY-13 (Maio 2026):
    • BUG-PY-13 (A): Foxx_lwnet — vmax_phys elevado de 100 W/m² para 150 W/m².
    • BUG-PY-13 (B): So_t — vmin_phys reduzido de 271.0 K para 270.0 K.
    • BUG-PY-13 (C): So_duu10n — vmax_phys inicial de 400 → 900 m²/s² (v7.0),
                 corrigido para 1600 m²/s² em v7.1 após calibração experimental.

  v6.0 — BUG-PY-12 (Maio 2026):
    • BUG-PY-12 (A): fill_min_threshold de So_t elevado de 200 K para 270 K.
                 O stub OCN coloca cells de terra/gelo em ~200.0049 K — logo
                 ACIMA do limiar antigo (200.0 K), provocando os warnings:
                   "⚠ So_t: min=200.0049 < 271.0 [K]" a cada execução.
                 Com 270 K, todos os pontos terra/fill viram NaN antes da
                 estatística e o aviso só aparece se houver SST de fato
                 anômala (a abaixo do ponto de congelamento da água do mar).
    • BUG-PY-12 (B): check_physics suprime aviso redundante de SST em °C.
                 Antes, a falha em K e a derivada em °C geravam DOIS avisos:
                   "⚠ So_t: min=200.0 < 271.0 [K]"
                   "⚠ So_t − 273.15 = [-73.15, 31.19] °C — ..."
                 sobre o MESMO problema. Agora a verificação em °C só roda
                 (e só reporta confirmação ✓) quando a verificação em K já
                 passou.
    • BUG-PY-12 (C): plot_maps silencia RuntimeWarning de slice 100% NaN.
                 np.nanpercentile sobre passo com todos NaN gerava warning
                 "All-NaN slice encountered" mesmo já havendo fallback para
                 limites físicos. Bloco encapsulado em warnings.catch_warnings.
    • BUG-PY-12 (D): plot_timeseries idem — RuntimeWarning de nanmean e
                 nanpercentile sobre slices 100% NaN são intencionais (geram
                 gap natural no matplotlib) e foram silenciados.
    • BUG-PY-12 (E): print_stats agora exibe coluna "Cobert." (percentual
                 de pontos válidos por passo). Permite identificar passos
                 com baixa cobertura de dados — útil para entender quando
                 (sem dados) ou min/max suspeitamente pequenos aparecem.

  v5.0 — BUG-PY-11 / CLEANUP (Maio 2026):
    • BUG-PY-11 (A): imports não utilizados removidos.
                 'timedelta' e 'date' importados mas nunca referenciados.
                 Removidos para clareza e conformidade com PEP 8.
    • BUG-PY-11 (B): código morto em compute_expected_interp.
                 Ternário 'x if hasattr(ts, "date") else y' tinha ramo else
                 inalcançável (ts é sempre datetime → possui .date()).
                 Simplificado para chamada direta: (ts.date() - epoch_date).
    • BUG-PY-11 (C): comentário mal-indentado em plot_maps.
                 Linha '# BUG-PY-07: scale aplicado...' estava dentro do bloco
                 'if flat.size == 0: continue' (código morto). Movido para
                 fora do bloco condicional.

  v4.0 — BUG-PY-08 (Maio 2026):
    • BUG-PY-08 (A/B/C/D/E): scale não aplicado em nenhuma função de saída.
                 print_stats, plot_maps, plot_timeseries e export_csv exibiam
                 dados em unidades SI (kg/m²/s, Pa) com labels de scale_units
                 (mm/d, hPa). Colorbars mostravam 1e-8 em vez de W/m².
                 Corrigido: layer *= scale antes de calcular vmin/vmax/plot.
                 Limites físicos de Faxa_rain/Faxa_snow corrigidos para mm/d.

  v3.0 — BUG-PY-06 (Maio 2026):
    • BUG-PY-06: Referências semânticas ao DOCN corrigidas em todo o script.
                 Os campos dos arquivos mom6_import_*.nc são fluxos ATM→OCN
                 calculados pelo mediador MED_cap.F90 (bulk NCAR), NÃO
                 campos exportados pelo DOCN_cap (So_t, Si_ifrac, So_u, So_v).
                 Corrigido: nome CSV, título de plot, comentários, docstrings.

  v2.0 — BUG-PY-01/02/03 (Maio 2026):
    • BUG-PY-01: padrão de busca corrigido de docn_import_*.nc → mom6_import_*.nc
    • BUG-PY-02: remoção de prefixo corrigida (docn_import_ → mom6_import_)
    • BUG-PY-03: FIELD_META e FIELDS atualizados dos campos DOCN (So_t, Si_ifrac,
                 So_u, So_v) para os 14 campos do exportState MED→OCN:
                 Foxx_taux/tauy, Foxx_sen, Foxx_evap, Foxx_lwnet,
                 Foxx_swnet_vdr/vdf/idr/idf, Faxa_rain/snow,
                 Sa_pslv, Si_ifrac, So_duu10n.

═══════════════════════════════════════════════════════════════════════════════
Cenário de uso
═══════════════════════════════════════════════════════════════════════════════
O MED_cap.F90 calcula os fluxos ATM→OCN via bulk NCAR a cada passo de
acoplamento e os escreve no exportState (= importState do MOM6+SIS2).
Ativar write_import_diag=.true. em mom6_output.nml faz o mediador escrever um
arquivo NetCDF de diagnóstico por passo em diag_import/mom6_import_YYYYMMDD_HHMMSS.nc.

Este script valida esses arquivos de três formas:
  1. ESTATÍSTICAS — min/max/média/σ por campo e passo
  2. FÍSICA       — verifica limites físicos e consistência
  3. SÉRIES TEMPORAIS — evolução das médias globais ao longo do experimento

═══════════════════════════════════════════════════════════════════════════════
Estrutura do arquivo de diagnóstico (diag_import/mom6_import_*.nc)
═══════════════════════════════════════════════════════════════════════════════
  Conventions: CF-1.8
  dimensions: lat(320), lon(640)  [grade MED interna 640×320]
  variables:
    lon(lon)            [degrees_east]
    lat(lat)            [degrees_north]
    time                [hours since YYYY-MM-DD 00:00:00] — escalar CF
    Foxx_taux(lat,lon)  [Pa]       — tensão zonal
    Foxx_tauy(lat,lon)  [Pa]       — tensão meridional
    Foxx_sen(lat,lon)   [W m-2]    — calor sensível
    Foxx_evap(lat,lon)  [kg m-2 s-1] — evaporação
    Foxx_lwnet(lat,lon) [W m-2]    — balanço onda longa
    Foxx_swnet_vdr(lat,lon) [W m-2] — OC vis. direta
    Foxx_swnet_vdf(lat,lon) [W m-2] — OC vis. difusa
    Foxx_swnet_idr(lat,lon) [W m-2] — OC IR direta
    Foxx_swnet_idf(lat,lon) [W m-2] — OC IR difusa
    Faxa_rain(lat,lon)  [kg m-2 s-1] — chuva
    Faxa_snow(lat,lon)  [kg m-2 s-1] — neve
    Sa_pslv(lat,lon)    [Pa]       — pressão nível do mar
    Si_ifrac(lat,lon)   [1]        — fração de gelo
    So_duu10n(lat,lon)  [m2 s-2]   — |V10|² neutro

═══════════════════════════════════════════════════════════════════════════════
Modos
═══════════════════════════════════════════════════════════════════════════════
  --stats       estatísticas globais por campo e passo
  --check       verificação de limites físicos
  --csv         exporta séries temporais em CSV
  --plot        mapas pcolormesh + série temporal
  --all         todos os modos [padrão]

Exemplos:
  python3 postproc_mom6_import.py
  python3 postproc_mom6_import.py --stats --check
  python3 postproc_mom6_import.py --diagdir diag_import --outdir diag_import/figs --plot

Dependências obrigatórias : numpy, netCDF4
Dependências opcionais    : matplotlib, cartopy  (para --plot)
"""

import sys
import os
import glob
import argparse
import csv
import warnings
from datetime import datetime

import numpy as np

try:
    from netCDF4 import Dataset
except ImportError:
    sys.exit("ERRO: netCDF4 não encontrado.  pip install --user netCDF4")

# ─── Metadados de exibição ─────────────────────────────────────────────────────
# BUG-PY-03 fix (GT Acoplamento de Modelos/INPE — Maio 2026):
# Os arquivos mom6_import_*.nc contêm os 14 campos do exportState MED→OCN,
# calculados pelo mediador MED_cap.F90 via parametrização bulk NCAR
# (Large & Yeager 2009). A fonte ATM é o MPAS-A (ou DATM como fallback);
# a SST provém do MOM6+SIS2 (ou do stub sintético 290 K).
# NÃO são campos do DOCN_cap (So_t, Si_ifrac, So_u, So_v): o DOCN fornece
# condições de contorno oceânicas ao mediador, não os fluxos ATM→OCN.
# (A versão v1.0 do script cometia esse erro conceitual.)
FIELD_META = {
    # ── Fluxos turbulentos ────────────────────────────────────────────────────
    'Foxx_taux': {
        'long_name': 'Tensão cisalhamento zonal (Foxx_taux)',
        'units': 'Pa', 'scale': 1.0, 'scale_units': 'Pa',
        'cmap': 'RdBu_r', 'vperc': [2, 98], 'symmetric': True,
        'vmin_phys': -5.0, 'vmax_phys': 5.0,
        'check_msg': 'Tensão zonal fora de [-5, 5] Pa — se > 10 Pa: artefato de MPI_MAX+NaN (pré-BUG-NC-03)',
    },
    'Foxx_tauy': {
        'long_name': 'Tensão cisalhamento meridional (Foxx_tauy)',
        'units': 'Pa', 'scale': 1.0, 'scale_units': 'Pa',
        'cmap': 'RdBu_r', 'vperc': [2, 98], 'symmetric': True,
        'vmin_phys': -5.0, 'vmax_phys': 5.0,
        'check_msg': 'Tensão meridional fora de [-5, 5] Pa',
    },
    'Foxx_sen': {
        'long_name': 'Fluxo de calor sensível (Foxx_sen)',
        'units': 'W m-2', 'scale': 1.0, 'scale_units': 'W m⁻²',
        'cmap': 'RdBu_r', 'vperc': [2, 98], 'symmetric': True,
        'vmin_phys': -500.0, 'vmax_phys': 500.0,
        'check_msg': 'Fluxo sensível fora de [-500, 500] W m⁻²',
    },
    'Foxx_evap': {
        'long_name': 'Fluxo de evaporação (Foxx_evap)',
        'units': 'kg m-2 s-1', 'scale': 86400.0, 'scale_units': 'mm d⁻¹',
        'cmap': 'RdBu_r', 'vperc': [2, 98], 'symmetric': True,
        # BUG-PY-09: limites em mm/d
        'vmin_phys': -15.0, 'vmax_phys': 200.0,
        'check_msg': 'Evaporação fora de [-15, 200] mm/d',
    },
    # ── Radiação ──────────────────────────────────────────────────────────────
    'Foxx_lwnet': {
        'long_name': 'Balanço de onda longa (Foxx_lwnet)',
        'units': 'W m-2', 'scale': 1.0, 'scale_units': 'W m⁻²',
        'cmap': 'RdBu_r', 'vperc': [2, 98], 'symmetric': True,
        'vmin_phys': -300.0, 'vmax_phys': 150.0,
        'check_msg': 'Onda longa fora de [-300, 150] W m⁻²',
    },
    'Foxx_swnet_vdr': {
        'long_name': 'Onda curta vis. direta (Foxx_swnet_vdr)',
        'units': 'W m-2', 'scale': 1.0, 'scale_units': 'W m⁻²',
        'cmap': 'YlOrRd', 'vperc': [0, 98], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 500.0,
        'check_msg': 'SW vis-dir fora de [0, 500] W m⁻²',
    },
    'Foxx_swnet_vdf': {
        'long_name': 'Onda curta vis. difusa (Foxx_swnet_vdf)',
        'units': 'W m-2', 'scale': 1.0, 'scale_units': 'W m⁻²',
        'cmap': 'YlOrRd', 'vperc': [0, 98], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 500.0,
        'check_msg': 'SW vis-dif fora de [0, 500] W m⁻²',
    },
    'Foxx_swnet_idr': {
        'long_name': 'Onda curta IR direta (Foxx_swnet_idr)',
        'units': 'W m-2', 'scale': 1.0, 'scale_units': 'W m⁻²',
        'cmap': 'YlOrRd', 'vperc': [0, 98], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 400.0,
        'check_msg': 'SW IR-dir fora de [0, 400] W m⁻²',
    },
    'Foxx_swnet_idf': {
        'long_name': 'Onda curta IR difusa (Foxx_swnet_idf)',
        'units': 'W m-2', 'scale': 1.0, 'scale_units': 'W m⁻²',
        'cmap': 'YlOrRd', 'vperc': [0, 98], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 400.0,
        'check_msg': 'SW IR-dif fora de [0, 400] W m⁻²',
    },
    # ── Precipitação ──────────────────────────────────────────────────────────
    'Faxa_rain': {
        'long_name': 'Precipitação líquida (Faxa_rain)',
        'units': 'kg m-2 s-1', 'scale': 86400.0, 'scale_units': 'mm d⁻¹',
        'cmap': 'Blues', 'vperc': [0, 99], 'symmetric': False,
        # BUG-PY-08-B: limites em mm/d (scale_units), não em kg/m²/s.
        # check_physics aplica scale antes de comparar: 2e-4 kg/m²/s × 86400 = 17.28 mm/d → vmax=600 mm/d.
        'vmin_phys': 0.0, 'vmax_phys': 600.0,
        'check_msg': 'Precipitação líquida > 600 mm/d (improvável exceto artefato NaN)',
    },
    'Faxa_snow': {
        'long_name': 'Precipitação sólida (Faxa_snow)',
        'units': 'kg m-2 s-1', 'scale': 86400.0, 'scale_units': 'mm d⁻¹',
        'cmap': 'Blues', 'vperc': [0, 99], 'symmetric': False,
        # BUG-PY-08-B: limites em mm/d: 5e-5 kg/m²/s × 86400 = 4.32 mm/d → vmax=150 mm/d.
        'vmin_phys': 0.0, 'vmax_phys': 150.0,
        'check_msg': 'Neve > 150 mm/d (improvável exceto artefato NaN)',
    },
    # ── Campos de estado ──────────────────────────────────────────────────────
    'Sa_pslv': {
        'long_name': 'Pressão ao nível do mar (Sa_pslv)',
        'units': 'Pa', 'scale': 1.0e-2, 'scale_units': 'hPa',
        'cmap': 'RdYlBu_r', 'vperc': [2, 98], 'symmetric': False,
        # BUG-PY-05-C: limites em unidades de scale_units (hPa), não em Pa.
        # check_physics agora aplica 'scale' antes de comparar.
        'vmin_phys': 870.0, 'vmax_phys': 1080.0,
        'check_msg': 'Pressão fora de [870, 1080] hPa',
        # BUG-PY-05-D: fill_threshold exclui células oceânicas sem dado (pslv=0 Pa).
        # Pontualmente o stub OCN deixa cells sem pressão → pslv=0.
        # Aplicar antes do scaling: 0 Pa × 0.01 = 0 hPa → abaixo de 870 hPa.
        'fill_min_threshold': 1000.0,  # Pa — mascara pslv < 1000 Pa (stub/terra com pslv=0)
    },
    'Si_ifrac': {
        'long_name': 'Fração de gelo marinho (Si_ifrac)',
        'units': '1', 'scale': 1.0, 'scale_units': '[0–1]',
        'cmap': 'Blues', 'vperc': [0, 99], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 1.0,
        # BUG-PY-14 (A): campo binário (0 ou 1) — escala adaptativa em plot_maps.
        # vmax_efetivo = max(mean * 30, 0.005) para tornar o gelo polar visível.
        'binary_field': True,   # flag: habilita escala adaptativa por passo
        'check_msg': 'Fração de gelo fora de [0, 1]',
    },
    'So_t': {
        'long_name': 'SST dinâmica MOM6 (So_t)',
        'units': 'K', 'scale': 1.0, 'scale_units': 'K',
        'cmap': 'RdYlBu_r', 'vperc': [2, 98], 'symmetric': False,
        'vmin_phys': 271.4, 'vmax_phys': 310.0,
        # BUG-PY-12 fix: threshold elevado de 200 K para 270 K.
        # BUG-PY-15 fix: threshold elevado de 270 K para 271.4 K.
        #   O marcador-stub do Sprint A.5 coloca pontos de terra/gelo
        #   em 271.35 K — valor ACIMA do limiar anterior (270 K) e
        #   portanto não mascarado, gerando patches azuis retangulares
        #   em áreas oceânicas.
        #   271.4 K captura 271.35 K (stub) como NaN sem mascarar SST
        #   oceânica real, cujo mínimo observado é ≈ 271.8 K.
        'fill_min_threshold': 271.4,  # SST < 271.4 K → stub/fill (NaN)
        'check_msg': 'SST fora de [271.4, 310] K',
    },
    'So_duu10n': {
        'long_name': 'Vento relativo ao oceano² (So_duu10n)',
        'units': 'm2 s-2', 'scale': 1.0, 'scale_units': 'm² s⁻²',
        'cmap': 'plasma', 'vperc': [0, 98], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 1600.0,
        'check_msg': 'So_duu10n fora de [0, 1600] m²/s² (|ΔV|>40 m/s — verificar artefato)',
    },
}

FIELDS = list(FIELD_META.keys())
SST_CELSIUS_OFFSET = 273.15   # offset de conversão °C → K (não usado nos campos MOM6, mantido por compatibilidade)


# ─── Carregamento ─────────────────────────────────────────────────────────────

def find_diag_files(diag_dir):
    # BUG-PY-01 fix: padrão correto é mom6_import_*.nc (gerado por
    # MED_cap.F90::med_write_import_fields), não docn_import_*.nc.
    pattern = os.path.join(diag_dir, 'mom6_import_*.nc')
    files = sorted(glob.glob(pattern))
    if not files:
        sys.exit(f"ERRO: nenhum arquivo mom6_import_*.nc em '{diag_dir}'.\n"
                 f"  Ative write_import_diag=.true. em mom6_output.nml e rode o acoplador.")
    return files


def parse_timestamp_from_filename(fname):
    """Extrai datetime de mom6_import_YYYYMMDD_HHMMSS.nc."""
    # BUG-PY-02 fix: prefixo correto é mom6_import_ (era docn_import_)
    base = os.path.basename(fname).replace('mom6_import_', '').replace('.nc', '')
    try:
        return datetime.strptime(base, '%Y%m%d_%H%M%S')
    except ValueError:
        return None


def load_diag_files(files, field_names):
    """
    Carrega todos os arquivos de diagnóstico.
    Retorna: timestamps, fields{name: (nsteps, nlat, nlon)}, lat, lon, attrs
    """
    timestamps = []
    all_data   = {f: [] for f in field_names}
    lat = lon  = None
    attrs_sample = {}

    print(f"  Carregando {len(files)} arquivos de diagnóstico...")

    for fpath in files:
        ts = parse_timestamp_from_filename(fpath)
        if ts is None:
            print(f"  AVISO: timestamp não reconhecido em {fpath}, ignorado.")
            continue

        with Dataset(fpath, 'r') as ds:
            if lat is None:
                lat = ds.variables.get('lat', ds.variables.get('latitude', None))
                lon = ds.variables.get('lon', ds.variables.get('longitude', None))
                lat = np.array(lat[:]) if lat is not None else None
                lon = np.array(lon[:]) if lon is not None else None
                # Salvar atributos globais do primeiro arquivo
                for attr in ds.ncattrs():
                    attrs_sample[attr] = getattr(ds, attr)

            timestamps.append(ts)
            for fname in field_names:
                if fname in ds.variables:
                    var = ds.variables[fname]
                    arr = np.array(var[:], dtype=np.float64)

                    # Máscara 1: _FillValue declarado no atributo
                    # BUG-PY-05-A: tolerância relativa (1e-3) em vez de absoluta 1.0.
                    # abs(arr - (-9.99e20)) < 1.0 é sempre False para qualquer valor
                    # finito, pois a diferença é sempre ~1e20. Tolerância relativa
                    # funciona para qualquer magnitude de fill value.
                    fill = getattr(var, '_FillValue', None)
                    if fill is not None:
                        arr = np.where(
                            np.isclose(arr, float(fill), rtol=1e-3, atol=0),
                            np.nan, arr)

                    # Máscara 2: qualquer fill value grande (≥ 1×10¹⁰) — captura fills nativos do NetCDF
                    arr = np.where(np.abs(arr) > 1.0e10, np.nan, arr)

                    # Máscara 3: limiar por valor absoluto grande (ex: correntes OSCAR fill=-999)
                    thresh = FIELD_META.get(fname, {}).get('fill_threshold', None)
                    if thresh is not None:
                        arr = np.where(np.abs(arr) > thresh, np.nan, arr)
                    # Máscara 4: limiar mínimo — exclui fill=0 em campos positivos
                    # BUG-PY-05-D: Sa_pslv tem 0 Pa em pontos terra (stub sem pressão).
                    fill_min = FIELD_META.get(fname, {}).get('fill_min_threshold', None)
                    if fill_min is not None:
                        arr = np.where(arr < fill_min, np.nan, arr)

                    all_data[fname].append(arr)
                else:
                    # Preenche com NaN se campo ausente neste passo
                    all_data[fname].append(None)

    # Converter para arrays (nsteps, nlat, nlon)
    # NetCDF escrito como (lon, lat) em Fortran → dimensão 0 = lon, dimensão 1 = lat
    # Python lê na mesma ordem → precisa transpor para (lat, lon) se shape[0] = nlon
    fields = {}
    for fname in field_names:
        layers = all_data[fname]
        valid  = [l for l in layers if l is not None]
        if not valid:
            continue
        shape = valid[0].shape
        stack = []
        for l in layers:
            if l is None:
                stack.append(np.full(shape, np.nan))
            else:
                stack.append(l)
        arr_3d = np.stack(stack, axis=0)   # (nsteps, dim0, dim1)
        # Detectar se precisa transpor: lon é o eixo mais rápido no Fortran,
        # portanto shape[1] = nlat < shape[2] = nlon para grade global (nlat < nlon).
        # Para grade 1440×720: dim0=1440 (lon), dim1=720 (lat) → transpor.
        # Para grade 360×181:  dim0=360  (lon), dim1=181 (lat) → transpor.
        if arr_3d.ndim == 3 and arr_3d.shape[1] > arr_3d.shape[2]:
            # shape = (nsteps, nlon, nlat) → (nsteps, nlat, nlon)
            arr_3d = np.transpose(arr_3d, (0, 2, 1))
        fields[fname] = arr_3d

    print(f"  {len(timestamps)} passos carregados.")
    return timestamps, fields, lat, lon, attrs_sample


# ─── Estatísticas ─────────────────────────────────────────────────────────────

def print_stats(timestamps, fields, field_names):
    """Imprime min/máx/média/desvpad por campo e passo, em unidades de exibição.

    BUG-PY-12-E: agora também mostra a fração de pontos válidos (não-NaN) por
    passo, útil para detectar passos com pouca cobertura (típico no início do
    experimento, quando a radiação SW ainda não foi escrita).
    """
    hdr = "══" * 50
    print(f"\n{hdr}")
    print("  ESTATÍSTICAS — MED exportState → MOM6 importState (fluxos ATM→OCN)")
    print(f"{hdr}\n")

    for fname in field_names:
        if fname not in fields:
            continue
        meta = FIELD_META.get(fname, {'long_name': fname, 'scale_units': '?'})
        data = fields[fname]                         # (nsteps, nlat, nlon)
        print(f"  ┌─ {fname}  —  {meta['long_name']}  [{meta['scale_units']}]")
        print(f"  │  {'Passo':6s}  {'Data/hora':22s}  {'Mínimo':>12s}  {'Máximo':>12s}"
              f"  {'Média':>12s}  {'DesvPad':>10s}  {'Cobert.':>8s}")
        print(f"  │  {'─'*94}")
        sc = meta.get('scale', 1.0)  # BUG-PY-08-A: aplicar scale antes de exibir
        for k, (ts, layer) in enumerate(zip(timestamps, data)):
            mask_ok = ~np.isnan(layer)
            n_ok    = int(mask_ok.sum())
            n_total = int(layer.size)
            cov     = (n_ok / n_total * 100.0) if n_total > 0 else 0.0
            flat    = layer[mask_ok] * sc
            if flat.size == 0:
                print(f"  │  {k+1:6d}  {ts.strftime('%Y-%m-%d %H:%M'):22s}"
                      f"  {'(sem dados)':>50s}  {cov:>7.1f}%")
                continue
            print(f"  │  {k+1:6d}  {ts.strftime('%Y-%m-%d %H:%M'):22s}"
                  f"  {flat.min():12.4f}  {flat.max():12.4f}"
                  f"  {flat.mean():12.4f}  {flat.std():10.4f}  {cov:>7.1f}%")
        all_flat = data[~np.isnan(data)] * sc
        if all_flat.size > 0:
            print(f"  │  {'─'*94}")
            print(f"  │  {'SÉRIE':6s}  {'(todos os passos)':22s}"
                  f"  {all_flat.min():12.4f}  {all_flat.max():12.4f}"
                  f"  {all_flat.mean():12.4f}  {all_flat.std():10.4f}")
        print(f"  └{'─'*96}\n")


# ─── Verificação de limites físicos ───────────────────────────────────────────

def check_physics(timestamps, fields, field_names):
    print("\n  ┌─ VERIFICAÇÃO FÍSICA ─────────────────────────────────────────────────")
    ok_count = 0
    warn_count = 0

    for fname in field_names:
        meta = FIELD_META.get(fname, {})
        optional = meta.get('optional', False)

        if fname not in fields:
            if optional:
                print(f"  │  ℹ {fname}: campo opcional não presente "
                      f"(requer use_med_to_mpas=true)")
            continue

        vmin   = meta.get('vmin_phys')
        vmax   = meta.get('vmax_phys')
        scale  = meta.get('scale', 1.0)
        sunits = meta.get('scale_units', meta.get('units', ''))
        data   = fields[fname]
        flat   = data[~np.isnan(data)]
        if flat.size == 0:
            continue
        # BUG-PY-05-B: comparar em unidades de exibição (após 'scale').
        # vmin_phys/vmax_phys devem estar nas mesmas unidades de scale_units.
        fmin_s = flat.min() * scale
        fmax_s = flat.max() * scale
        if vmin is not None and fmin_s < vmin:
            print(f"  │  ⚠ {fname}: min={fmin_s:.4f} < {vmin}  [{sunits}] — {meta.get('check_msg','')}")
            warn_count += 1
        elif vmax is not None and fmax_s > vmax:
            print(f"  │  ⚠ {fname}: max={fmax_s:.4f} > {vmax}  [{sunits}] — {meta.get('check_msg','')}")
            warn_count += 1
        else:
            print(f"  │  ✓ {fname}: [{fmin_s:.4f}, {fmax_s:.4f}] [{sunits}] dentro de [{vmin}, {vmax}]")
            ok_count += 1

    # Verificação especial: SST − 273.15 deve ser SST em °C ([-2.5, 42])
    # BUG-PY-12-B: só relata aqui se a verificação principal em K passou OK.
    # Caso contrário, geraríamos DOIS avisos sobre o mesmo problema:
    #   ⚠ So_t: min=200.0 < 271.0 [K]            (verificação em K)
    #   ⚠ So_t − 273.15 = [-73.15, 31.19] °C ...  (mesmo problema em °C)
    # Mantém-se apenas a confirmação positiva em °C quando tudo está bem.
    if 'So_t' in fields:
        meta_st = FIELD_META.get('So_t', {})
        sst_k   = fields['So_t']
        flat_k  = sst_k[~np.isnan(sst_k)]
        sst_ok_in_K = (flat_k.size > 0
                       and flat_k.min() >= meta_st.get('vmin_phys', 271.0)
                       and flat_k.max() <= meta_st.get('vmax_phys', 310.0))
        sst_c  = sst_k - SST_CELSIUS_OFFSET
        flat_c = sst_c[~np.isnan(sst_c)]
        if flat_c.size > 0 and sst_ok_in_K:
            if flat_c.min() >= -2.5 and flat_c.max() <= 42.0:
                print(f"  │  ✓ So_t em °C (={flat_c.mean():.2f}±{flat_c.std():.2f}) — "
                      f"conversão °C→K consistente (offset≈273.15)")
                ok_count += 1

    # Verificação do gelo: não deve haver valores > 1 (clamping deve ter atuado)
    if 'Si_ifrac' in fields:
        ice = fields['Si_ifrac']
        flat_ice = ice[~np.isnan(ice)]
        n_over = np.sum(ice > 1.001)
        n_neg  = np.sum(ice < -0.001)
        if n_over == 0 and n_neg == 0:
            print(f"  │  ✓ Si_ifrac: clamping [0,1] verificado — sem valores fora do intervalo")
            ok_count += 1
        else:
            print(f"  │  ⚠ Si_ifrac: {n_over} valores > 1 e {n_neg} < 0 — clamping incompleto")
            warn_count += 1
        # Verificação de plausibilidade — baseada em max, não em mean.
        # OISST armazena oceano livre de gelo como fill value (não 0.0).
        # Stats são calculadas APENAS sobre células com gelo (max ≈ 0.99).
        # Usar max para detectar problemas de escala:
        #   max < 0.05 → dupla divisão por 100 (datocn_ice_pct=.true. errado)
        #   max > 1.05 → falta de divisão (dados em %, datocn_ice_pct=.false. errado)
        if flat_ice.size > 0:
            ice_max  = float(flat_ice.max())
            ice_mean = float(flat_ice.mean())
            n_total  = flat_ice.size
            if ice_max < 0.05:
                print(f"  │  ⚠ Si_ifrac: max={ice_max:.4f} < 0.05 — DUPLA divisão por 100.")
                print(f"  │     Definir datocn_ice_pct=.false. em nuopc.input")
                print(f"  │     (verificar: ncdump -h ice_file.nc | grep 'units|scale_factor')")
                warn_count += 1
            elif ice_max > 1.05:
                print(f"  │  ⚠ Si_ifrac: max={ice_max:.4f} > 1.05 — dados em % sem /100.")
                print(f"  │     Definir datocn_ice_pct=.true. em nuopc.input")
                warn_count += 1
            else:
                print(f"  │  ✓ Si_ifrac: max={ice_max:.4f} — escala [0,1] correta"
                      f"  (média sobre células c/ gelo: {ice_mean:.4f})")
                ok_count += 1

    # Verificação de So_u e So_v: esses campos não fazem parte do exportState
    # MED→OCN — o MOM6 importState contém fluxos calculados, não correntes OCN.
    # Bloco preservado para compatibilidade com futuros experimentos DATM+DOCN.
    for cur_field in ['So_u', 'So_v']:
        if cur_field in fields:
            cur_flat = fields[cur_field][~np.isnan(fields[cur_field])]
            if cur_flat.size > 0 and np.all(cur_flat == 0.0):
                print(f"  │  ℹ {cur_field}: todos zeros — corrente não configurada"
                      f"  (datocn_cur_file='' em nuopc.input)")
                ok_count += 1

    # Verificação de eixos OSCAR: So_u ≡ So_v indica (time,lon,lat) em vez de
    # (time,lat,lon) — artefato de transposição em arquivos de correntes OSCAR.
    if 'So_u' in fields and 'So_v' in fields:
        u_flat = fields['So_u'][~np.isnan(fields['So_u'])]
        v_flat = fields['So_v'][~np.isnan(fields['So_v'])]
        if u_flat.size > 100 and v_flat.size > 100:
            corr_uv = float(np.corrcoef(u_flat[:10000], v_flat[:10000])[0, 1]) \
                      if len(u_flat) > 10000 else float(np.corrcoef(u_flat, v_flat)[0, 1])
            if corr_uv > 0.9999:
                print(f"  │  ⚠ So_u ≡ So_v: correlação={corr_uv:.6f} ≈ 1.0 — EIXOS TROCADOS!")
                print(f"  │     Arquivo OSCAR: ncpdq -a time,latitude,longitude para corrigir a ordem.")
                print(f"  │     Corrigir: ncpdq -a time,latitude,longitude oscar.nc oscar_fixado.nc")
                print(f"  │              cdo remapbil,r1440x720 oscar_fixado.nc INPUT/OISST_cur.nc")
                warn_count += 1
            elif not np.all(u_flat == 0.0):
                print(f"  │  ✓ So_u ≠ So_v: correlação={corr_uv:.4f} — eixos corretos")
                ok_count += 1

    print(f"  └─ {ok_count} OK, {warn_count} avisos\n")
    return warn_count == 0


# ─── Comparação com arquivo fonte ─────────────────────────────────────────────

def compute_expected_interp(timestamps, sst_file, varname, epoch_date,
                             dt_data_s, ice_file=None, ice_varname=None):
    """
    Recalcula independentemente a interpolação temporal do arquivo SST de referência.
    Útil para validar So_t em configurações DOCN (stub/netcdf) — não aplicável
    ao exportState MED→OCN (Foxx_* etc.) que são calculados pelo mediador.
    Retorna: sst_expected(nsteps, nlat_src, nlon_src), ice_expected ou None
    """
    with Dataset(sst_file, 'r') as ds:
        var = ds.variables[varname]
        nt  = var.shape[0]
        src_data = var[:]    # (nt, ny, nx) — OISST armazena (time, lat, lon)
        if hasattr(src_data, 'mask'):
            src_data = src_data.filled(np.nan)
        src_data = np.array(src_data, dtype=np.float64)

    sst_exp = np.full((len(timestamps),) + src_data.shape[1:], np.nan)

    for k, ts in enumerate(timestamps):
        dt_since = (ts.date() - epoch_date).total_seconds()
        tidx0 = int(dt_since / dt_data_s) % nt
        tidx1 = (tidx0 + 1) % nt
        alpha = (dt_since % dt_data_s) / dt_data_s
        alpha = max(0.0, min(1.0, alpha))
        sst_exp[k] = (1.0 - alpha) * src_data[tidx0] + alpha * src_data[tidx1]
        sst_exp[k] += SST_CELSIUS_OFFSET   # conversão °C→K

    ice_exp = None
    if ice_file and ice_varname:
        with Dataset(ice_file, 'r') as ds:
            var = ds.variables[ice_varname]
            nt_i = var.shape[0]
            ice_data = np.array(var[:], dtype=np.float64)
        ice_exp = np.full((len(timestamps),) + ice_data.shape[1:], np.nan)
        for k, ts in enumerate(timestamps):
            dt_since = (ts.date() - epoch_date).total_seconds()
            tidx0 = int(dt_since / dt_data_s) % nt_i
            tidx1 = (tidx0 + 1) % nt_i
            alpha = (dt_since % dt_data_s) / dt_data_s
            alpha = max(0.0, min(1.0, alpha))
            ice_exp[k] = np.clip(
                (1.0 - alpha) * ice_data[tidx0] + alpha * ice_data[tidx1], 0.0, 1.0)

    return sst_exp, ice_exp


def compare_with_reference(timestamps, fields, sst_file, varname,
                            epoch_date, dt_data_s,
                            ice_file=None, ice_varname=None):
    """Compara So_t / Si_ifrac (modo DOCN) contra interpolação calculada.
    Não aplicável ao exportState MED→OCN (sem campo So_t). Preservado para
    compatibilidade com experimentos DOCN stub/netcdf."""
    print("\n  ┌─ COMPARAÇÃO COM ARQUIVO FONTE (interpolação independente) ────────────")
    print(f"  │  SST fonte : {sst_file}  [{varname}]")
    if ice_file:
        print(f"  │  Gelo fonte: {ice_file}  [{ice_varname}]")
    print(f"  │  Epoch     : {epoch_date}  |  dt_data : {dt_data_s} s")

    sst_exp, ice_exp = compute_expected_interp(
        timestamps, sst_file, varname, epoch_date, dt_data_s,
        ice_file, ice_varname)

    if 'So_t' in fields and sst_exp is not None:
        sst_obs = fields['So_t']
        # O arquivo diagnóstico está em 360×181 (1°) enquanto o OISST pode ser
        # 1440×720 — fazemos o comparativo no espaço de saída (1°)
        # sst_exp vem na grade original do OISST; fazer binning 1°
        # Por simplicidade: calcular Δ nos bins 1° apenas
        # Se grades forem iguais:
        if sst_obs.shape[1:] == sst_exp.shape[1:]:
            delta = sst_obs - sst_exp
        else:
            # Binning do sst_exp para 1° se necessário (simplificado: reshape)
            print(f"  │  NOTA: grade fonte {sst_exp.shape[1:]} ≠ grade diag {sst_obs.shape[1:]}"
                  f" — comparação por estatísticas globais")
            delta = None

        print(f"  │")
        print(f"  │  {'Passo':6s}  {'Data/hora':22s}  {'RMSE_SST':>10s}  "
              f"{'Bias_SST':>10s}  {'MaxΔ':>10s}")
        print(f"  │  {'─'*70}")
        total_rmse = []
        for k, ts in enumerate(timestamps):
            if delta is not None:
                d = delta[k][~np.isnan(delta[k])]
                rmse = np.sqrt(np.mean(d**2)) if d.size > 0 else np.nan
                bias = np.mean(d) if d.size > 0 else np.nan
                maxd = np.max(np.abs(d)) if d.size > 0 else np.nan
                total_rmse.append(rmse)
                flag = '⚠' if rmse > 0.1 else '✓'
                print(f"  │  {k+1:6d}  {ts.strftime('%Y-%m-%d %H:%M'):22s}"
                      f"  {rmse:10.4f}  {bias:+10.4f}  {maxd:10.4f}  {flag}")
            else:
                # Grade diferente: comparar estatísticas globais
                e_mean = np.nanmean(sst_exp[k])
                o_mean = np.nanmean(sst_obs[k]) if k < len(timestamps) else np.nan
                print(f"  │  {k+1:6d}  {ts.strftime('%Y-%m-%d %H:%M'):22s}"
                      f"  fonte μ={e_mean:.2f} K  diag μ={o_mean:.2f} K  "
                      f"Δμ={o_mean-e_mean:+.4f} K")
        if total_rmse:
            mean_rmse = np.nanmean(total_rmse)
            status = '✓ EXCELENTE' if mean_rmse < 0.001 else \
                     '✓ BOM'      if mean_rmse < 0.05  else \
                     '⚠ VERIFICAR'
            print(f"  │  {'─'*70}")
            print(f"  │  RMSE médio (SST): {mean_rmse:.6f} K — {status}")
            print(f"  │  Nota: RMSE > 0 esperado pelo não-determinismo FP das reduções MPI")

    if 'Si_ifrac' in fields and ice_exp is not None:
        ice_obs = fields['Si_ifrac']
        if ice_obs.shape[1:] == ice_exp.shape[1:]:
            delta_ice = ice_obs - ice_exp
            rmse_ice = np.sqrt(np.nanmean(delta_ice**2))
            bias_ice = np.nanmean(delta_ice)
            print(f"  │")
            print(f"  │  Si_ifrac: RMSE={rmse_ice:.6f}  Bias={bias_ice:+.6f}  "
                  f"{'✓' if rmse_ice < 0.001 else '⚠'}")

    print(f"  └{'─'*72}\n")


# ─── Exportação CSV ───────────────────────────────────────────────────────────

def export_csv(timestamps, fields, field_names, outdir):
    os.makedirs(outdir, exist_ok=True)

    # CSV consolidado de estatísticas
    consolidated = os.path.join(outdir, 'mom6_import_stats.csv')
    rows = []
    for k, ts in enumerate(timestamps):
        row = {'timestamp': ts.strftime('%Y-%m-%dT%H:%M:%S')}
        for fname in field_names:
            if fname not in fields:
                continue
            sc    = FIELD_META.get(fname, {}).get('scale', 1.0)  # BUG-PY-08-E
            layer = fields[fname][k]
            flat  = layer[~np.isnan(layer)] * sc
            row[f'{fname}_min']  = f'{flat.min():.6f}' if flat.size > 0 else 'NaN'
            row[f'{fname}_p05']  = f'{np.percentile(flat, 5):.6f}' if flat.size > 0 else 'NaN'
            row[f'{fname}_p95']  = f'{np.percentile(flat, 95):.6f}' if flat.size > 0 else 'NaN'
            row[f'{fname}_max']  = f'{flat.max():.6f}' if flat.size > 0 else 'NaN'
            row[f'{fname}_mean'] = f'{flat.mean():.6f}' if flat.size > 0 else 'NaN'
            row[f'{fname}_std']  = f'{flat.std():.6f}' if flat.size > 0 else 'NaN'
        rows.append(row)

    if rows:
        with open(consolidated, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)
        print(f"  CSV consolidado : {consolidated}")


# ─── Plotagem ─────────────────────────────────────────────────────────────────

def plot_maps(timestamps, fields, field_names, lat, lon, step_indices, outdir):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        from matplotlib.colors import Normalize
    except ImportError:
        print("  matplotlib não disponível — mapas ignorados.")
        return

    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature
        USE_CARTOPY = True
    except ImportError:
        USE_CARTOPY = False

    os.makedirs(outdir, exist_ok=True)

    if lon is None or lat is None:
        print("  AVISO: coordenadas ausentes — mapas ignorados.")
        return

    # Converter grade 0→360 para -180→180 para alinhamento com Cartopy/Natural Earth.
    # O arquivo NetCDF tem lon nativo OISST (0°→359.75°). Sem essa conversão,
    # os contornos de costa ficam deslocados ~180° em relação ao preenchimento.
    lon_plot = np.array(lon, dtype=float)
    roll_n = 0
    if lon_plot[0] >= 0 and lon_plot[-1] > 180:
        # encontrar o índice onde lon cruza 180° → ali o roll começa
        roll_n = int(np.searchsorted(lon_plot, 180))
        lon_plot = np.where(lon_plot >= 180, lon_plot - 360, lon_plot)
        # reordenar: [180→360 → -180→0] ++ [0→180]
        idx_sorted = np.argsort(lon_plot)
        lon_plot   = lon_plot[idx_sorted]
    else:
        idx_sorted = np.arange(len(lon_plot))

    LON2D, LAT2D = np.meshgrid(lon_plot, lat)

    for k in step_indices:
        if k >= len(timestamps):
            continue
        ts = timestamps[k]
        ts_str = ts.strftime('%Y%m%d_%H%M%S')

        n_fields = sum(1 for f in field_names if f in fields)
        if n_fields == 0:
            continue
        ncols = 2
        nrows = (n_fields + 1) // 2

        if USE_CARTOPY:
            fig, axes = plt.subplots(nrows, ncols,
                                      figsize=(14, 4 * nrows),
                                      subplot_kw={'projection': ccrs.PlateCarree()},
                                      constrained_layout=True)
        else:
            fig, axes = plt.subplots(nrows, ncols,
                                      figsize=(14, 4 * nrows),
                                      constrained_layout=True)

        axes = np.array(axes).flatten()
        ax_i = 0

        for fname in field_names:
            if fname not in fields:
                continue
            meta  = FIELD_META.get(fname, {'long_name': fname, 'scale_units': '?',
                                           'cmap': 'viridis', 'vperc': [2, 98],
                                           'symmetric': False})
            layer = fields[fname][k]
            # Reordenar colunas (lon) para -180→180 — mesmo índice do lon_plot
            if layer.ndim == 2 and layer.shape[1] == len(idx_sorted):
                layer = layer[:, idx_sorted]
            sc_f  = FIELD_META.get(fname, {}).get('scale', 1.0)
            flat  = layer[~np.isnan(layer)] * sc_f  # BUG-PY-07
            ax    = axes[ax_i]

            if flat.size == 0:
                # BUG-PY-14 (C): painel informativo em vez de espaço em branco.
                # Quando So_t (ou qualquer campo) é 100% NaN num passo
                # (ex.: passo 1 antes do primeiro avanço do MOM6), exibe
                # mensagem diagnóstica clara em vez de subplot vazio.
                ax.set_facecolor('#e8e8e8')
                ax.text(0.5, 0.5,
                        f"Campo indisponível neste passo\n"
                        f"(aguardando primeiro avanço MOM6)",
                        ha='center', va='center', transform=ax.transAxes,
                        fontsize=9, color='#555555',
                        bbox=dict(boxstyle='round,pad=0.4', fc='white',
                                  ec='#aaaaaa', alpha=0.85))
                ax.set_title(f"{fname} — {meta['long_name']}\n"
                             f"{ts.strftime('%Y-%m-%d %H:%M')}  (passo {k+1})",
                             fontsize=9)
                if USE_CARTOPY:
                    ax.add_feature(cfeature.LAND,      facecolor='lightgray', zorder=5)
                    ax.add_feature(cfeature.COASTLINE, linewidth=0.5,
                                                       edgecolor='black', zorder=6)
                    ax.set_extent([-180, 180, -90, 90], ccrs.PlateCarree())
                ax_i += 1
                continue

            # BUG-PY-07: scale aplicado → unidades corretas na colorbar
            sc_plot   = meta.get('scale', 1.0)
            layer_plt = layer * sc_plot
            phys_min  = meta.get('vmin_phys')
            phys_max  = meta.get('vmax_phys')

            # BUG-PY-14 (D) FIX v2: mascaramento + interpolação do seam.
            # A grade MED é regular 360x180 em (0–360°, -90–90°) e não tem seam
            # tripolar próprio. Porém o campo So_t (e fluxos calculados em
            # função de SST) carregam o seam da grade nativa MOM6 (tripolar),
            # propagado pelo regrid OCN→ATM. Após o roll para -180→180°, esse
            # seam aparece como linha branca vertical próximo a 180°.
            #
            # Estratégia: detectar a coluna onde mais de 80% das linhas têm
            # NaN ou valores idênticos à coluna anterior — substituir por
            # interpolação linear das duas colunas vizinhas (apenas na cópia
            # de plot; dados originais permanecem intactos).
            if meta.get('mask_tripole_seam', True) and lon is not None:
                lon_arr = np.array(lon_plot)   # já reordenado para -180→180
                dlon = np.abs(np.diff(lon_arr))
                seam_cols = np.where(dlon > 90)[0]
                # Caso 1: salto de longitude > 90° (seam de roll)
                if seam_cols.size > 0:
                    layer_plt = layer_plt.copy()
                    for col in seam_cols:
                        layer_plt[:, col]   = np.nan
                        layer_plt[:, col+1] = np.nan
                else:
                    # Caso 2: detectar coluna anômala próximo a lon=180° por
                    # alta fração de NaN ou valores idênticos à vizinha.
                    # Janela de busca: ±2 colunas do índice central.
                    n_cols = layer_plt.shape[1]
                    center = n_cols // 2
                    for col in range(max(1, center - 3), min(n_cols - 1, center + 3)):
                        col_data = layer_plt[:, col]
                        # fração de NaN ou de valores que coincidem com a coluna
                        # vizinha à esquerda (indicador de coluna degenerada)
                        nan_frac = np.mean(~np.isfinite(col_data))
                        if nan_frac > 0.5:
                            # Substituir por interpolação linear vizinhos válidos
                            layer_plt = layer_plt.copy()
                            left  = layer_plt[:, col - 1]
                            right = layer_plt[:, col + 1] if (col + 1) < n_cols \
                                                          else layer_plt[:, 0]
                            interp = 0.5 * (left + right)
                            mask_nan_int = ~np.isfinite(interp)
                            interp[mask_nan_int] = np.nanmean(layer_plt)
                            layer_plt[:, col] = interp
                            break

            # BUG-PY-10-A: máscara para percentil — zeros em campos simétricos
            # provavelmente são fill; em campos não-simétricos são física legítima.
            if meta.get('symmetric', False):
                arr_for_perc = np.where(layer_plt == 0.0, np.nan, layer_plt)
            else:
                arr_for_perc = layer_plt

            # BUG-PY-14 (A): escala adaptativa para campos binários (0 ou 1).
            # Si_ifrac tem p95=0 e max=1: células de gelo são ~0.05% da área.
            # Com vmax=1, o sinal polar é invisível na paleta global.
            # Estratégia: se max > 0.9 e p95 ≈ 0 → campo quase-binário;
            #   vmax_efetivo = max(mean_não_zero * 30, 0.005, vperc98 * 2)
            # Isso estica a colorbar para tornar o gelo visível mantendo
            # a interpretação física da escala [0–1].
            is_binary = meta.get('binary_field', False)
            ice_area_info = ''
            if is_binary and flat.max() > 0.9:
                # Detecta se o campo é predominantemente zero com pico em 1
                perc95 = float(np.nanpercentile(flat, 95))
                mean_f = float(np.nanmean(flat))
                if perc95 < 0.01 and mean_f > 0:
                    # Escala adaptativa: estica suficientemente para ver o gelo
                    perc98 = float(np.nanpercentile(flat, 98))
                    vmax_ada = max(mean_f * 30, 0.005, perc98 * 2.0, 0.002)
                    vmax_ada = min(vmax_ada, 1.0)  # nunca ultrapassa 1
                    vmin = 0.0
                    vmax = vmax_ada
                    # Estimar fração de área com gelo (em % do oceano)
                    n_ice   = int(np.sum(flat >= 0.5))
                    n_total = flat.size
                    ice_area_info = (f" | ~{n_ice} cél. ({100*n_ice/max(n_total,1):.3f}%)")
                else:
                    # Campo binário mas com gelo suficiente para escala normal
                    vmin, vmax = 0.0, 1.0
            else:
                # Caminho normal: percentis robustos
                try:
                    with warnings.catch_warnings():
                        warnings.simplefilter("ignore", RuntimeWarning)
                        vmin = float(np.nanpercentile(arr_for_perc, meta['vperc'][0]))
                        vmax = float(np.nanpercentile(arr_for_perc, meta['vperc'][1]))
                    if not (np.isfinite(vmin) and np.isfinite(vmax)):
                        raise ValueError
                except (ValueError, RuntimeWarning):
                    vmin = phys_min if phys_min is not None else -1.0
                    vmax = phys_max if phys_max is not None else  1.0

                if meta.get('symmetric', False):
                    v = max(abs(vmin), abs(vmax))
                    if phys_max is not None:
                        v = min(v, phys_max)
                    if v < 1e-12:
                        v = phys_max if phys_max is not None else 1.0
                    vmin, vmax = -v, v
                else:
                    if phys_min is not None: vmin = max(vmin, phys_min)
                    if phys_max is not None: vmax = min(vmax, phys_max)
                    if abs(vmax - vmin) < 1e-12:
                        if phys_max is not None and phys_max > vmin:
                            vmax = phys_max
                        else:
                            vmax = vmin + max(abs(vmin)*0.01, 1e-6)

            if USE_CARTOPY:
                im = ax.pcolormesh(LON2D, LAT2D, layer_plt,
                                   cmap=meta['cmap'], vmin=vmin, vmax=vmax,
                                   transform=ccrs.PlateCarree(),
                                   zorder=1)
                # BUG-PY-15 (A/C): adicionar LAND com zorder 5 garante que:
                #   • áreas de terra com NaN (campos oceânicos — Foxx_lwnet,
                #     onda curta, precipitação) aparecem cinza em vez de
                #     branco transparente;
                #   • So_duu10n e outros campos atmosféricos que possuem
                #     dados sobre terra (vento calculado em toda a grade)
                #     ficam visualmente mascarados nos continentes, evitando
                #     a exibição de informação fisicamente sem sentido.
                # COASTLINE e BORDERS em zorder 6 ficam visíveis acima
                # da máscara de terra.
                ax.add_feature(cfeature.LAND,      facecolor='lightgray',
                                                   zorder=5)
                ax.add_feature(cfeature.COASTLINE, linewidth=0.5,
                                                   edgecolor='black', zorder=6)
                ax.add_feature(cfeature.BORDERS,   linewidth=0.3, linestyle=':',
                                                   edgecolor='gray',  zorder=6)
                ax.set_extent([-180, 180, -90, 90], ccrs.PlateCarree())
            else:
                im = ax.pcolormesh(LON2D, LAT2D, layer_plt,
                                   cmap=meta['cmap'], vmin=vmin, vmax=vmax)
            plt.colorbar(im, ax=ax, orientation='vertical',
                         label=meta['scale_units'], fraction=0.025, pad=0.02)
            title_suffix = ice_area_info  # extra info para Si_ifrac
            ax.set_title(f"{fname} — {meta['long_name']}\n"
                         f"{ts.strftime('%Y-%m-%d %H:%M')}  (passo {k+1})"
                         f"{title_suffix}",
                         fontsize=9)
            ax_i += 1

        for ax in axes[ax_i:]:
            ax.set_visible(False)

        fig.suptitle(
            f"MED exportState → MOM6 importState — Fluxos ATM→OCN\n"
            f"Passo {k+1}  |  {ts.strftime('%Y-%m-%d %H:%M')}  |  "
            f"MONAN-A 2.0 / INPE/CGCT/DIMNT",
            fontsize=11)

        outfile = os.path.join(outdir, f'mom6_import_{ts_str}.png')
        fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
        plt.close(fig)
        print(f"  Figura: {outfile}")


def plot_timeseries(timestamps, fields, field_names, outdir):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
    except ImportError:
        return

    os.makedirs(outdir, exist_ok=True)
    available = [f for f in field_names if f in fields]
    if not available:
        return

    n = len(available)
    ncols = 2
    nrows = (n + 1) // 2
    fig, axes = plt.subplots(nrows, ncols, figsize=(14, 3.5 * nrows),
                              sharex=True, constrained_layout=True)
    axes = np.array(axes).flatten()

    for ax, fname in zip(axes, available):
        meta  = FIELD_META.get(fname, {'long_name': fname, 'scale': 1.0,
                                        'scale_units': '?'})
        sc    = meta.get('scale', 1.0)  # BUG-PY-08-D: scale para unidades de exibição
        data  = fields[fname] * sc
        flat  = data.reshape(len(timestamps), -1)
        # BUG-PY-12-D: passo com todos os NaN é situação esperada (ex.: SW
        # logo após inicialização, antes do primeiro registro radiativo).
        # nanmean/nanpercentile sobre slice 100% NaN é INTENCIONAL aqui:
        # devolve NaN, que o matplotlib trata como gap natural na curva.
        # Suprimimos os warnings em loop interno para manter a saída limpa.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            means = np.nanmean(flat, axis=1)
            p2    = np.nanpercentile(flat, 2,  axis=1)
            p98   = np.nanpercentile(flat, 98, axis=1)

        ax.fill_between(timestamps, p2, p98, alpha=0.18, color='steelblue', label='P₂–P₉₈')
        ax.plot(timestamps, means, lw=1.8, color='steelblue', label='média')
        ax.xaxis.set_major_formatter(mdates.DateFormatter('%d/%m\n%H:%M'))
        ax.xaxis.set_major_locator(mdates.HourLocator(interval=6))
        ax.set_ylabel(meta['scale_units'], fontsize=9)
        ax.set_title(f"{fname}  —  {meta['long_name']}", fontsize=9)
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8, loc='upper right')

        # BUG-PY-14 (B): escala symlog para campos binários com sinal pequeno.
        # Si_ifrac tem mean ~0.0005: numa escala linear [0, 1] a série aparece
        # como linha reta no zero, tornando o crescimento de gelo ilegível.
        # symlog com linthresh=1e-4 usa escala linear em [-1e-4, 1e-4] e
        # logarítmica fora desse intervalo — torna a curva legível sem distorcer
        # a interpretação física da unidade [0–1].
        if meta.get('binary_field', False):
            max_mean = float(np.nanmax(means)) if np.any(np.isfinite(means)) else 0
            if max_mean < 0.1:
                linthresh = max(max_mean * 0.05, 1e-6)
                ax.set_yscale('symlog', linthresh=linthresh)
                # Adicionar linha de referência no threshold linear
                ax.axhline(linthresh, color='gray', lw=0.6, ls=':', alpha=0.5)
                ax.set_ylabel(f"{meta['scale_units']} (symlog)", fontsize=9)

    for ax in axes[len(available):]:
        ax.set_visible(False)

    fig.suptitle(
        f"MED exportState → MOM6 importState — séries temporais dos fluxos ATM→OCN\n"
        f"{timestamps[0].strftime('%Y-%m-%d %H:%M')} → "
        f"{timestamps[-1].strftime('%Y-%m-%d %H:%M')}"
        f"  |  {len(timestamps)} passos  |  INPE/CGCT/DIMNT",
        fontsize=11)

    outfile = os.path.join(outdir, 'mom6_import_timeseries.png')
    fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print(f"  Série temporal: {outfile}")


# ─── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Validação dos campos importados pelo MOM6+SIS2 (fluxos ATM→OCN do mediador).',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--diagdir', default='diag_import',
                        help='Diretório com mom6_import_*.nc (padrão: diag_import)')
    parser.add_argument('--outdir',  default='diag_import/postproc',
                        help='Saída: CSV e figuras (padrão: diag_import/postproc)')
    parser.add_argument('--field', nargs='+', default=FIELDS,
                        help=f'Campos a processar (padrão: todos os 14 campos MOM6)')

    # Modos
    parser.add_argument('--stats',  action='store_true', help='Estatísticas globais')
    parser.add_argument('--check',  action='store_true', help='Verificação de limites físicos')
    parser.add_argument('--csv',    action='store_true', help='Exportar CSV')
    parser.add_argument('--plot',   action='store_true', help='Gerar mapas e série temporal')
    parser.add_argument('--all',    action='store_true', help='Todos os modos [padrão]')

    # Passos para plotagem
    parser.add_argument('--step',      nargs='+', type=int, default=None)
    parser.add_argument('--all-steps', action='store_true', dest='all_steps')

    args = parser.parse_args()

    if not any([args.stats, args.check, args.csv, args.plot, args.all]):
        args.all = True
    if args.all:
        args.stats = args.check = args.csv = args.plot = True

    print()
    print('═' * 70)
    print('  MONAN-A 2.0 — Validação de campos importados MOM6 (ATM→OCN)')
    print('  INPE / CGCT / DIMNT — GT Acoplamento de Modelos  (v8.2)')
    print('═' * 70)
    print(f"  Diagnósticos : {os.path.abspath(args.diagdir)}")
    print(f"  Saída        : {os.path.abspath(args.outdir)}")
    print(f"  Campos       : {', '.join(args.field)}")
    print()

    files = find_diag_files(args.diagdir)
    print(f"  Arquivos MOM6 diag : {len(files)}")
    print(f"  Primeiro           : {os.path.basename(files[0])}")
    print(f"  Último             : {os.path.basename(files[-1])}")
    print()

    timestamps, fields, lat, lon, attrs = load_diag_files(files, args.field)
    print()

    # Passos para plotagem
    nsteps = len(timestamps)
    if args.step:
        step_indices = [s - 1 for s in args.step]
    elif args.all_steps:
        step_indices = list(range(nsteps))
    else:
        step_every = max(1, nsteps // 8)
        step_indices = list(range(0, nsteps, step_every))
        if (nsteps - 1) not in step_indices:
            step_indices.append(nsteps - 1)
    step_indices = sorted(set(min(max(s, 0), nsteps - 1) for s in step_indices))

    # Exibir atributos globais registrados pelo mediador
    if attrs:
        print("  ┌─ Metadados CF registrados pelo MED_cap_MONAN ─────────────────────")
        for key in ['Conventions', 'title', 'institution', 'source',
                    'valid_time', 'nx_global', 'ny_global', 'petCount']:
            if key in attrs:
                print(f"  │  {key:15s} = {attrs[key]}")
        print(f"  └{'─'*67}\n")

    if args.stats:
        print("  [--stats] Calculando estatísticas...")
        print_stats(timestamps, fields, args.field)

    if args.check:
        print("  [--check] Verificando limites físicos...")
        check_physics(timestamps, fields, args.field)

    if args.csv:
        print("  [--csv] Exportando CSV...")
        os.makedirs(args.outdir, exist_ok=True)
        export_csv(timestamps, fields, args.field, args.outdir)
        print()

    if args.plot:
        n_steps_plot = len(step_indices)
        print(f"  [--plot] Gerando figuras ({n_steps_plot} passo(s))...")
        plot_maps(timestamps, fields, args.field, lat, lon, step_indices, args.outdir)
        plot_timeseries(timestamps, fields, args.field, args.outdir)
        print()

    print('═' * 70)
    print('  Concluído.')
    print('═' * 70)
    print()


if __name__ == '__main__':
    main()
