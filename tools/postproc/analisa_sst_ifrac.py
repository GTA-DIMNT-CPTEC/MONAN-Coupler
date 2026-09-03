#!/usr/bin/env python3
"""
analisa_sst_ifrac.py  —  Diagnóstico de evolução temporal de SST e fração de gelo
                          marinho (Si_ifrac) ao longo da integração do modelo.

Versão 1.4 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

═══════════════════════════════════════════════════════════════════════════════
Correções v1.4
═══════════════════════════════════════════════════════════════════════════════
  BUG-6 (mapas de anomalia e diff_consec brancos — outlier domina colorscale)
    O limite do colormap era calculado como np.ma.abs(campo).max().  Basta
    uma célula outlier com Δ ≈ 8–10 K para que TwoSlopeNorm mapeie todo o
    oceano (bulk < 0,5 K) para branco, tornando os mapas dos passos 3–6
    visualmente vazios.
    Solução: _robust_limit() usa np.percentile(|campo|, ROBUST_PERCENTILE=99.5)
    como limite visual; o máximo absoluto ainda é reportado no título com o
    prefixo "⚠ outlier:" quando lim_abs > 2× lim_robusto.

  BUG-7 (série temporal com escala Y comprimida — analise_timeseries sem idx0)
    analise_timeseries não recebia idx0, então o passo 1 (SST = 271 K,
    sst_default) dominava o eixo Y e comprimia a variação real (292–293 K)
    numa faixa invisível.  O mesmo ocorria no painel de desvio-padrão.
    Solução: idx0 adicionado como parâmetro; ajuste de ylim aplicado ao
    intervalo dos passos reais (idx0 em diante), com margem relativa.

  BUG-8 (spike do passo 0 visível no gráfico de métricas — piso 1.0 km²)
    Em analise_metricas, a margem Y tinha piso fixo de 1.0 km².  Quando a
    área real de gelo é ≈ 0 km², esse piso expandia ylim até 1 km², incluindo
    o spike do passo sst_default (step 1) na janela visível.
    Solução: margem agora é relativa ao intervalo real dos dados (max(intervalo
    × 0.15, |vmax| × 0.05, 0.01)); o piso fixo de 1.0 foi removido.

═══════════════════════════════════════════════════════════════════════════════
Correções v1.2
═══════════════════════════════════════════════════════════════════════════════
  BUG-5 (mapas em branco — campo congelado)
    O DOCN envia o mesmo valor OISST diário em todos os passos
    horários. δ = 0 K é mapeado para branco no colormap RdBu_r,
    produzindo mapas visualmente vazios sem indicação ao usuário.
    Solução: _is_frozen() detecta campos sem variação e
    _annotate_frozen() escreve aviso legível sobre o mapa;
    _plot_field() usa fundo azul-claro (#d0e8f5) para o oceano.

  BUG-3 (referência de anomalia degenerada)
    O passo 1 contém SST = sst_default = 271.35 K (campo não preenchido).
    Usar passo 1 como t₀ produzia Δ ≈ 21 K uniforme em todo o oceano,
    saturando a escala de cores e tornando os mapas visualmente brancos.
    Solução: _find_first_real_step() detecta automaticamente o primeiro
    passo com std espacial > 0.1 K e usa-o como referência t₀.

  BUG-4 (diferença consecutiva no par sst_default → real)
    O par passo 1→2 capturava a transição sst_default → OISST real,
    produzindo δ ≈ 21 K (artefato, não sinal físico). Solução: loop
    analise_diff_consecutiva inicia em max(1, idx0+1).

  MELHORIA: escala Y dos gráficos de métricas
    O outlier do passo 1 (sst_default) comprimia a variação real para
    uma faixa invisível. Os eixos Y agora são ajustados ao intervalo
    dos passos reais (idx0 em diante), com margem de 15 %.

═══════════════════════════════════════════════════════════════════════════════
Correções v1.1
═══════════════════════════════════════════════════════════════════════════════
  BUG-1 (mascaramento catastrófico)
    Na grade Voronoi do MPAS, o diagnóstico monan2_import_*.nc é escrito
    ANTES de o conector OCN→ATM preencher o campo So_t.  Todas as células
    (terra E oceano) têm So_t = sst_default = 271.35 K.  A detecção de
    terra por limiar  |v − 271.35| < 1e−3  mascarava TUDO.

    Solução: detecção por variância temporal.  Células constantes ao longo
    de TODOS os passos E próximas do valor-padrão são classificadas como
    terra/default.  Se após isso > 99 % do campo ainda estiver mascarado
    (campo genuinamente não preenchido), o mascaramento de terra é desabilitado
    e o script emite um aviso.

  BUG-2 (coordenadas MPAS)
    A grade Voronoi do MPAS usa 'latCell'/'lonCell', não 'lat'/'lon'.
    Adicionado suporte a esses nomes.

  MELHORIA: avisos UserWarning de conversão masked→nan suprimidos via
    warnings.catch_warnings; verificação de np.ma.count() antes de float().

═══════════════════════════════════════════════════════════════════════════════
Estratégias implementadas
═══════════════════════════════════════════════════════════════════════════════
1. SÉRIE TEMPORAL DE ESTATÍSTICAS ESCALARES
   Plota min / média / max / desvio-padrão ao longo do tempo.

2. CAMPO DE ANOMALIA  Δ(t) = campo(t) − campo(t₀)
   Remove o gradiente espacial dominante; escala divergente centrada em zero.

3. DIFERENÇA ENTRE PASSOS CONSECUTIVOS  δ(t) = campo(t) − campo(t−1)
   Revela onde e quando o campo mudou.

4. MÉTRICAS INTEGRADAS
   Área total com gelo (km²), SST média pesada pela área oceânica,
   área de gelo novo e de fusão entre passos consecutivos.

═══════════════════════════════════════════════════════════════════════════════
Fontes de dados
═══════════════════════════════════════════════════════════════════════════════
  FONTE 1 — monan2_import_YYYYMMDD_HHMMSS.nc  (mpas_cap_netcdf.F90)
  FONTE 2 — mom6_import_YYYYMMDD_HHMMSS.nc    (med_cap_netcdf.F90)

═══════════════════════════════════════════════════════════════════════════════
Uso
═══════════════════════════════════════════════════════════════════════════════
  python3 analisa_sst_ifrac.py                        # todas as análises
  python3 analisa_sst_ifrac.py --timeseries           # só série temporal
  python3 analisa_sst_ifrac.py --anomaly              # só mapas de anomalia
  python3 analisa_sst_ifrac.py --diff                 # só diferença consecutiva
  python3 analisa_sst_ifrac.py --metrics              # só métricas integradas
  python3 analisa_sst_ifrac.py --diagdir diag_import --outdir resultados/
  python3 analisa_sst_ifrac.py --debug                # imprime info dos campos
"""

import sys
import os
import glob
import argparse
import warnings
from datetime import datetime

import numpy as np

try:
    from netCDF4 import Dataset
except ImportError:
    sys.exit('ERRO: netCDF4 não encontrado.  pip install --user netCDF4')


# ─── Constantes ──────────────────────────────────────────────────────────────

VERSION        = '1.4'
T_FILL_LAND    = 271.35     # valor-padrão de terra/default para SST [K]
T_FILL_TOL     = 2.0        # tolerância ampla para detectar células default [K]
IFRAC_MIN_ICE  = 0.15       # limiar mínimo para considerar célula com gelo
EARTH_R_KM     = 6371.0     # raio médio da Terra [km]
MASK_WARN_FRAC = 0.99       # fração máxima mascarada antes de aviso
FROZEN_THRESHOLD = 1e-5     # abaixo deste valor (unidade do campo) o campo é
                             # considerado congelado e o mapa é omitido
ROBUST_PERCENTILE = 99.5    # percentil de |campo| usado como limite do colormap;
                             # evita que células outlier dominem a escala de cores
                             # e produzam mapas visualmente brancos


# ─── Utilitários de terminal ─────────────────────────────────────────────────

def _sep(char='═', width=70):
    print(char * width)

def _header():
    _sep()
    print('  MONAN-A 2.0 — Diagnóstico de evolução SST / Si_ifrac')
    print(f'  INPE / CGCT / DIMNT — GT Acoplamento de Modelos  (v{VERSION})')
    _sep()
    print()


# ─── Leitura de campos de um Dataset aberto ──────────────────────────────────

# Nomes aceitos para coordenadas (lat/lon), SST e fração de gelo
_LAT_NAMES = ('lat', 'latitude', 'nav_lat', 'latCell', 'TLAT', 'geolat')
_LON_NAMES = ('lon', 'longitude', 'nav_lon', 'lonCell', 'TLON', 'geolon')
_SST_NAMES = ('So_t', 'sst', 'SST', 'sea_surface_temperature')
_ICE_NAMES = ('Si_ifrac', 'ifrac', 'ice_fraction', 'aice', 'AICE')


def _read_coord(ds, names):
    """Retorna o primeiro array de coordenada encontrado, ou None."""
    for name in names:
        if name in ds.variables:
            return ds.variables[name][:]
    return None


def _read_field(ds, names):
    """Retorna array 2-D ou 1-D (sem dim. temporal) do primeiro nome achado."""
    for name in names:
        if name in ds.variables:
            arr = ds.variables[name][:]
            # Remove dimensão de tempo unitária: (1,N) → (N,) ou (1,NY,NX) → (NY,NX)
            if arr.ndim >= 2 and arr.shape[0] == 1:
                arr = arr[0]
            return arr, name
    return None, None


def _debug_ds(ds, fpath):
    """Imprime variáveis e atributos básicos do arquivo (modo --debug)."""
    print(f'  [debug] {os.path.basename(fpath)}')
    for vname, var in ds.variables.items():
        fill = getattr(var, '_FillValue', '—')
        try:
            data = var[:]
            mn = float(np.ma.min(data)) if np.ma.count(data) > 0 else float('nan')
            mx = float(np.ma.max(data)) if np.ma.count(data) > 0 else float('nan')
            frac = np.mean(np.ma.getmaskarray(data))
            print(f'    {vname:30s}  shape={str(var.shape):20s}'
                  f'  fill={fill}  min={mn:.4g}  max={mx:.4g}'
                  f'  mask={100*frac:.1f}%')
        except Exception as exc:
            print(f'    {vname:30s}  [erro: {exc}]')
    print()


# ─── Leitura de dados ────────────────────────────────────────────────────────

def _load_fonte(diagdir, pattern, ts_fmt, fonte_label, debug=False):
    """
    Lê arquivos NetCDF de diagnóstico e retorna listas de campos SST e gelo.
    Genérico para FONTE 1 e FONTE 2.
    """
    files = sorted(glob.glob(os.path.join(diagdir, pattern)))
    if not files:
        return None

    sst_list, ice_list, ts_list = [], [], []
    lat, lon = None, None

    for fpath in files:
        try:
            with Dataset(fpath) as ds:

                if debug and not sst_list:   # imprime só no primeiro arquivo
                    _debug_ds(ds, fpath)

                # Coordenadas (lidas apenas no primeiro arquivo)
                if lat is None:
                    lat = _read_coord(ds, _LAT_NAMES)
                    lon = _read_coord(ds, _LON_NAMES)

                # Campos
                sst_arr, sst_name = _read_field(ds, _SST_NAMES)
                ice_arr, ice_name = _read_field(ds, _ICE_NAMES)

                if sst_arr is None or ice_arr is None:
                    continue

                if debug and not sst_list:
                    print(f'  [debug] SST lida de "{sst_name}", '
                          f'gelo de "{ice_name}"')

                # Timestamp a partir do nome do arquivo
                base = os.path.basename(fpath)
                try:
                    ts = datetime.strptime(base, ts_fmt)
                except ValueError:
                    ts = None

                sst_list.append(np.ma.array(sst_arr, copy=True))
                ice_list.append(np.ma.array(ice_arr, copy=True))
                ts_list.append(ts)

        except Exception as exc:
            if debug:
                print(f'  [debug] erro em {fpath}: {exc}')
            continue

    if not sst_list:
        return None
    return sst_list, ice_list, ts_list, lat, lon, fonte_label


def _build_land_mask(sst_list):
    """
    Constrói máscara de terra/default de forma robusta.

    Algoritmo:
    1. Coleta a máscara automática do netCDF4 (_FillValue) de todos os passos.
    2. Células cujo desvio-padrão temporal é praticamente zero E cujo valor
       está próximo de T_FILL_LAND são classificadas como terra/default.
    3. Se o resultado mascarar > MASK_WARN_FRAC do domínio, o campo provavelmente
       não foi preenchido pelo acoplador: emite aviso e usa apenas a máscara
       automática do netCDF4.

    Retorna: (land_mask, campo_nao_preenchido)
    """
    n = len(sst_list)

    # Máscara netCDF4 acumulada (union de todos os passos)
    nc_mask = np.zeros(sst_list[0].shape, dtype=bool)
    for s in sst_list:
        nc_mask |= np.ma.getmaskarray(s)

    # Dados brutos (sem máscara) para análise de variância temporal
    raw = np.array([np.ma.getdata(s) for s in sst_list])   # (n, ncells...)

    # Desvio-padrão temporal por célula
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        std_t = np.std(raw, axis=0)

    # Células constantes no tempo E próximas do valor-padrão → terra/default
    near_default = np.abs(raw[0] - T_FILL_LAND) < T_FILL_TOL
    is_constant  = std_t < 1e-6
    thresh_mask  = near_default & is_constant

    land_mask = nc_mask | thresh_mask

    frac = np.sum(land_mask) / land_mask.size
    campo_nao_preenchido = False

    if frac > MASK_WARN_FRAC:
        # Campo aparentemente não preenchido — desabilitar mascaramento de terra
        campo_nao_preenchido = True
        print(f'  AVISO  : {100*frac:.1f}% das células seriam mascaradas '
              f'({100*(1-frac):.2f}% válidas).')
        print(f'  CAUSA  : campo So_t provavelmente não preenchido pelo acoplador')
        print(f'           (todos os valores ≈ {T_FILL_LAND} K = sst_default).')
        print(f'  AÇÃO   : mascaramento de terra desabilitado; '
              f'usando apenas máscara automática do netCDF4.')
        print()
        land_mask = nc_mask   # recua para a máscara mais conservadora

    return land_mask, campo_nao_preenchido



# ─── Detecção do primeiro passo com campo real ────────────────────────────────

def _is_frozen(field, threshold=None):
    """
    Retorna True se o campo for considerado congelado (sem variação espacial).

    Um campo é congelado quando todos os valores oceânicos são idênticos
    (ex.: DOCN enviando o mesmo OISST diário em todos os passos horários).
    Isso faz δ = 0 K que o colormap RdBu_r renderiza como branco, tornando
    o mapa visualmente indistinguível do fundo.
    """
    if threshold is None:
        threshold = FROZEN_THRESHOLD
    abs_max = _safe_stat(lambda a: float(np.ma.abs(a).max()), field)
    return np.isnan(abs_max) or abs_max < threshold


def _annotate_frozen(ax, msg='campo congelado\n(sem variação no período)'):
    """Escreve aviso sobre campo congelado no centro do eixo."""
    ax.text(0.5, 0.5, msg,
            ha='center', va='center', transform=ax.transAxes,
            fontsize=11, color='gray', style='italic',
            bbox=dict(facecolor='white', edgecolor='lightgray',
                      boxstyle='round,pad=0.4', alpha=0.85))


def _find_first_real_step(sst_list, std_threshold=0.1):
    """
    Retorna o índice do primeiro passo onde SST tem variação espacial real.

    Passos com campo ainda não preenchido (SST = sst_default em todo o domínio)
    têm desvio-padrão espacial ≈ 0.  O primeiro passo com std > std_threshold
    é considerado o início do regime real de acoplamento.

    Parâmetro
    ---------
    std_threshold : float
        Limiar de std espacial abaixo do qual o campo é considerado uniforme/default.
        0.1 K é um valor conservador; campos oceânicos reais têm std ≫ 1 K.
    """
    for i, sst in enumerate(sst_list):
        std_val = _safe_stat(np.ma.std, sst)
        if not np.isnan(std_val) and std_val > std_threshold:
            return i
    return 0   # fallback: usar passo 0 se todos parecerem uniformes


def load_data(diagdir, debug=False):
    """Carrega SST e Si_ifrac priorizando FONTE 1, depois FONTE 2."""

    result = _load_fonte(
        diagdir,
        pattern    = 'monan2_import_????????_??????.nc',
        ts_fmt     = 'monan2_import_%Y%m%d_%H%M%S.nc',
        fonte_label= 'FONTE 1 (monan2_import_*.nc)',
        debug      = debug,
    )
    if result is None:
        result = _load_fonte(
            diagdir,
            pattern    = 'mom6_import_????????_??????.nc',
            ts_fmt     = 'mom6_import_%Y%m%d_%H%M%S.nc',
            fonte_label= 'FONTE 2 (mom6_import_*.nc)',
            debug      = debug,
        )
    if result is None:
        sys.exit(
            f'\nERRO: nenhum arquivo de diagnóstico encontrado em \'{diagdir}\'.\n'
            'Necessário: monan2_import_*.nc  ou  mom6_import_*.nc\n'
            'Ativar com write_import_diag=.true. em &nuopc_docn do nuopc.input\n'
        )

    sst_list, ice_list, ts_list, lat, lon, fonte = result
    n = len(sst_list)

    print(f'  Fonte de dados     : {fonte}')
    print(f'  Passos carregados  : {n}')
    if ts_list[0]:
        print(f'  Primeiro           : {ts_list[0].strftime("%Y-%m-%d %H:%M")}')
    if ts_list[-1]:
        print(f'  Último             : {ts_list[-1].strftime("%Y-%m-%d %H:%M")}')

    # Informações sobre o campo bruto (antes do mascaramento)
    raw0 = np.ma.getdata(sst_list[0]).ravel()
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        print(f'  SST bruta passo 1  : min={raw0.min():.3f} K  '
              f'max={raw0.max():.3f} K  '
              f'média={raw0.mean():.3f} K  '
              f'[{raw0.size} células]')
    print()

    # Construir máscara de terra
    land_mask, nao_preenchido = _build_land_mask(sst_list)

    # Aplicar máscara
    for i in range(n):
        sst_list[i] = np.ma.masked_where(land_mask, sst_list[i])
        ice_list[i] = np.ma.masked_where(land_mask, ice_list[i])

    # Verificar células válidas após mascaramento
    n_validas = int(np.sum(~land_mask))
    n_total   = land_mask.size
    print(f'  Células válidas    : {n_validas:,} / {n_total:,} '
          f'({100*n_validas/n_total:.2f}%)')
    if n_validas == 0:
        print()
        print('  AVISO: zero células válidas — as estatísticas serão NaN.')
        print('  Dica : use --debug para inspecionar as variáveis do arquivo.')
        print('         Considere usar FONTE 2 (mom6_import_*.nc) se disponível.')
    print()

    # Detectar primeiro passo com campo real (não sst_default)
    idx0 = _find_first_real_step(sst_list)
    if idx0 > 0:
        ts0 = ts_list[idx0].strftime('%Y-%m-%d %H:%M') if ts_list[idx0] else f'passo {idx0+1}'
        print(f'  Referência t₀      : passo {idx0+1} ({ts0})  '
              f'[passos 1..{idx0} com sst_default ignorados]')
        print()

    return sst_list, ice_list, ts_list, lat, lon, fonte, nao_preenchido, idx0


# ─── Utilitário: estatística segura ──────────────────────────────────────────

def _safe_stat(func, arr):
    """Calcula func(arr) sem emitir UserWarning para arrays totalmente mascarados."""
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        if np.ma.count(arr) == 0:
            return float('nan')
        return float(func(arr))


def _robust_limit(field, percentile=None):
    """
    Limite de colormap baseado em percentil, robusto a outliers.

    Usa o percentil `ROBUST_PERCENTILE` de |campo| no lugar do máximo absoluto.
    Isso evita que uma ou poucas células com valores extremos (ex.: 8–10 K num
    campo cujo bulk varia < 0,5 K) dominem o intervalo vmin/vmax e produzam
    mapas visualmente em branco.

    Retorna o valor do percentil, ou NaN se o campo estiver totalmente mascarado.
    """
    if percentile is None:
        percentile = ROBUST_PERCENTILE
    compressed = np.ma.compressed(np.ma.abs(field))
    if compressed.size == 0:
        return float('nan')
    return float(np.percentile(compressed, percentile))


# ─── Análise 1: Série temporal de estatísticas ───────────────────────────────

def analise_timeseries(sst_list, ice_list, ts_list, outdir, idx0=0):
    """
    Gera série temporal de min/média/max/desvio-padrão para SST e Si_ifrac.

    idx0 : índice do primeiro passo com campo real (sst_default ignorado).
           Usado para ajustar o eixo Y ao intervalo dos passos válidos,
           evitando que o valor de bootstrap (271 K) comprima a escala.
    """
    print('  [1] Série temporal de estatísticas escalares...')

    n = len(sst_list)
    x = [ts_list[i] if ts_list[i] else i + 1 for i in range(n)]

    # Calcular estatísticas
    stats = {}
    for nome, lst in [('SST (K)', sst_list), ('Si_ifrac [0-1]', ice_list)]:
        means = [_safe_stat(np.ma.mean, lst[i]) for i in range(n)]
        mins  = [_safe_stat(np.ma.min,  lst[i]) for i in range(n)]
        maxs  = [_safe_stat(np.ma.max,  lst[i]) for i in range(n)]
        stds  = [_safe_stat(np.ma.std,  lst[i]) for i in range(n)]
        stats[nome] = dict(means=means, mins=mins, maxs=maxs, stds=stds)

    # Tabela no terminal
    _sep('─')
    print(f'  {"Passo":>5}  {"Tempo":>16}  '
          f'{"SST média(K)":>12}  {"SST std":>8}  '
          f'{"ifrac média":>11}  {"ifrac max":>10}')
    _sep('─')
    for i in range(n):
        ts_str = ts_list[i].strftime('%Y-%m-%d %H:%M') if ts_list[i] else '—'
        sm  = stats['SST (K)']['means'][i]
        sst = stats['SST (K)']['stds'][i]
        im  = stats['Si_ifrac [0-1]']['means'][i]
        ix  = stats['Si_ifrac [0-1]']['maxs'][i]
        sm_s  = f'{sm:12.4f}'  if not np.isnan(sm)  else f'{"nan":>12}'
        sst_s = f'{sst:8.4f}'  if not np.isnan(sst) else f'{"nan":>8}'
        im_s  = f'{im:11.6f}'  if not np.isnan(im)  else f'{"nan":>11}'
        ix_s  = f'{ix:10.6f}'  if not np.isnan(ix)  else f'{"nan":>10}'
        print(f'  {i+1:>5}  {ts_str:>16}  {sm_s}  {sst_s}  {im_s}  {ix_s}')
    _sep('─')
    print()

    # Gráfico
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
    except ImportError:
        print('  (matplotlib não disponível — pulando gráfico)\n')
        return

    os.makedirs(outdir, exist_ok=True)
    fig, axes = plt.subplots(2, 2, figsize=(14, 8), constrained_layout=True)

    campos = [
        ('SST (K)',        sst_list, 'steelblue', 'SST dinâmica MOM6 (So_t)'),
        ('Si_ifrac [0-1]', ice_list, 'royalblue', 'Fração de gelo (Si_ifrac)'),
    ]
    for col, (nome, lst, cor, titulo) in enumerate(campos):
        st = stats[nome]

        ax = axes[0, col]
        ax.fill_between(x, st['mins'], st['maxs'],
                        alpha=0.15, color=cor, label='min–max')
        ax.plot(x, st['means'], 'o-', color=cor, lw=2, ms=5, label='média global')
        if isinstance(x[0], datetime):
            ax.xaxis.set_major_formatter(mdates.DateFormatter('%d/%m %H:%M'))
            fig.autofmt_xdate(rotation=30)
        ax.set_title(f'{titulo}\nMín / Média / Máx', fontsize=9)
        ax.set_ylabel(nome.split()[1])
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)
        # Ajustar escala Y aos passos reais (exclui sst_default em idx0-1)
        if idx0 > 0 and len(st['mins']) > idx0:
            mins_r = [v for v in st['mins'][idx0:] if not np.isnan(v)]
            maxs_r = [v for v in st['maxs'][idx0:] if not np.isnan(v)]
            if mins_r and maxs_r:
                span   = max(maxs_r) - min(mins_r)
                margem = max(span * 0.10, abs(max(maxs_r)) * 0.005, 0.1)
                ax.set_ylim(min(mins_r) - margem, max(maxs_r) + margem)

        ax = axes[1, col]
        ax.plot(x, st['stds'], 's-', color='darkorange', lw=1.8, ms=5)
        if isinstance(x[0], datetime):
            ax.xaxis.set_major_formatter(mdates.DateFormatter('%d/%m %H:%M'))
        ax.set_title('Desvio-padrão espacial\n(heterogeneidade do campo)', fontsize=9)
        ax.set_ylabel(f'std  [{nome.split()[1]}]')
        ax.grid(True, alpha=0.3)
        # Ajustar escala Y do std aos passos reais
        if idx0 > 0 and len(st['stds']) > idx0:
            stds_r = [v for v in st['stds'][idx0:] if not np.isnan(v)]
            if stds_r:
                vmax_s = max(stds_r)
                margem = max(vmax_s * 0.15, 0.05)
                ax.set_ylim(0, vmax_s + margem)

    fig.suptitle(
        'MONAN-A 2.0 — Evolução temporal: SST e Fração de Gelo\n'
        'INPE/CGCT/DIMNT  |  GT Acoplamento de Modelos',
        fontsize=10,
    )
    outfile = os.path.join(outdir, 'sst_ifrac_timeseries.png')
    fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print(f'  Gráfico: {outfile}\n')


# ─── Análise 2: Campo de anomalia Δ(t) = campo(t) − campo(t₀) ───────────────

def analise_anomalia(sst_list, ice_list, ts_list, lat, lon, outdir, idx0=0):
    """
    Plota campo(t) − campo(t₀) para cada passo de acoplamento.

    idx0 : índice do primeiro passo com campo real (referência t₀).
           Passos anteriores (sst_default) são ignorados.
    """
    print('  [2] Mapas de anomalia  Δ(t) = campo(t) − campo(t₀)...')

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        from matplotlib.colors import TwoSlopeNorm
    except ImportError:
        print('  (matplotlib não disponível — pulando mapas)\n')
        return

    os.makedirs(outdir, exist_ok=True)

    # Referência: primeiro passo com campo real
    sst0    = sst_list[idx0].copy()
    ice0    = ice_list[idx0].copy()
    ts0_str = (ts_list[idx0].strftime('%Y-%m-%d %H:%M')
               if ts_list[idx0] else f'passo {idx0+1}')
    print(f'  Referência t₀: passo {idx0+1}  ({ts0_str})')

    lon2d, lat2d, use_cartopy = _prep_grid(lat, lon)

    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature
        HAS_CARTOPY = True
    except ImportError:
        HAS_CARTOPY = False
        use_cartopy = False

    n_frozen_sst = 0
    n_frozen_ice = 0
    for i in range(idx0 + 1, len(sst_list)):
        d_sst = sst_list[i] - sst0
        d_ice = ice_list[i] - ice0
        ts_str = ts_list[i].strftime('%Y-%m-%d %H:%M') if ts_list[i] else f'passo {i+1}'

        sst_frozen = _is_frozen(d_sst)
        ice_frozen = _is_frozen(d_ice)
        if sst_frozen: n_frozen_sst += 1
        if ice_frozen: n_frozen_ice += 1

        fig, axes_row = plt.subplots(
            1, 2, figsize=(14, 5),
            subplot_kw={'projection': ccrs.Robinson()} if use_cartopy and HAS_CARTOPY else {},
            constrained_layout=True,
        )

        for ax, d_field, titulo, unidade, cmap, lim_min, frozen in [
            (axes_row[0], d_sst, 'ΔSST  (So_t)', 'K',     'RdBu_r', 0.01, sst_frozen),
            (axes_row[1], d_ice, 'ΔSi_ifrac',    '[0-1]', 'BrBG',   1e-4, ice_frozen),
        ]:
            # Limite absoluto (informativo) e limite robusto (escala visual)
            lim_abs = _safe_stat(lambda a: float(np.ma.abs(a).max()), d_field)
            lim_rob = _robust_limit(d_field)
            if np.isnan(lim_rob):
                lim_rob = lim_abs
            limite = max(lim_min, lim_rob if not np.isnan(lim_rob) else lim_min)
            if np.isnan(limite):
                limite = lim_min

            # Aviso de outlier: exibido no título quando lim_abs >> escala visual
            outlier_str = ''
            if (not np.isnan(lim_abs) and not np.isnan(lim_rob)
                    and lim_abs > 2.0 * max(lim_rob, lim_min)):
                outlier_str = f'  ⚠ outlier: máx|Δ|={lim_abs:.4g} {unidade}'

            norm = TwoSlopeNorm(vcenter=0.0, vmin=-limite, vmax=limite)
            _plot_field(ax, d_field, lon2d, lat2d, norm, cmap,
                        use_cartopy and HAS_CARTOPY)
            if frozen:
                _annotate_frozen(ax, f'campo congelado\nmáx|Δ| < {FROZEN_THRESHOLD:.0e} {unidade}')
            ax.set_title(
                f'{titulo}  —  {ts_str}\n'
                f'(relativo a t₀ = {ts0_str};  máx|Δ| = {limite:.4g} {unidade})'
                f'{outlier_str}',
                fontsize=8,
            )
            plt.colorbar(_get_scalar_mappable(ax), ax=ax,
                         shrink=0.75, pad=0.02, label=unidade)

        fig.suptitle(
            f'Anomalia em relação a t₀ = {ts0_str}  |  {ts_str}\n'
            'MONAN-A 2.0 — INPE/CGCT/DIMNT',
            fontsize=9,
        )
        tag = ts_list[i].strftime('%Y%m%d_%H%M%S') if ts_list[i] else f'step{i+1:04d}'
        outfile = os.path.join(outdir, f'anomalia_{tag}.png')
        fig.savefig(outfile, dpi=120, bbox_inches='tight', facecolor='white')
        plt.close(fig)
        print(f'  Anomalia passo {i+1:>3}: {outfile}')
    if n_frozen_sst > 0:
        print(f'  (SST congelada em {n_frozen_sst} passos — '
              f'DOCN envia OISST diário constante dentro do dia)')
    if n_frozen_ice > 0:
        print(f'  (Si_ifrac congelada em {n_frozen_ice} passos)')
    print()


# ─── Análise 3: Diferença entre passos consecutivos ──────────────────────────

def analise_diff_consecutiva(sst_list, ice_list, ts_list, lat, lon, outdir, idx0=0):
    """
    Plota campo(t) − campo(t−1) para cada par de passos consecutivos.

    idx0 : índice do primeiro passo com campo real.  Pares envolvendo passos
           anteriores (sst_default) são ignorados.
    """
    print('  [3] Diferença entre passos consecutivos  δ(t) = campo(t) − campo(t−1)...')

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        from matplotlib.colors import TwoSlopeNorm
    except ImportError:
        print('  (matplotlib não disponível — pulando mapas)\n')
        return

    os.makedirs(outdir, exist_ok=True)
    lon2d, lat2d, use_cartopy = _prep_grid(lat, lon)

    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature
        HAS_CARTOPY = True
    except ImportError:
        HAS_CARTOPY = False
        use_cartopy = False

    # Ignorar pares que envolvam passos com sst_default (i-1 < idx0)
    primeiro_par = max(1, idx0 + 1)
    n_frozen_sst = 0
    n_frozen_ice = 0
    for i in range(primeiro_par, len(sst_list)):
        d_sst = sst_list[i] - sst_list[i - 1]
        d_ice = ice_list[i] - ice_list[i - 1]

        ts_prev = ts_list[i-1].strftime('%Y-%m-%d %H:%M') if ts_list[i-1] else f'passo {i}'
        ts_cur  = ts_list[i].strftime('%Y-%m-%d %H:%M')   if ts_list[i]   else f'passo {i+1}'

        fig, axes_row = plt.subplots(
            1, 2, figsize=(14, 5),
            subplot_kw={'projection': ccrs.Robinson()} if use_cartopy and HAS_CARTOPY else {},
            constrained_layout=True,
        )

        sst_frozen = _is_frozen(d_sst)
        ice_frozen = _is_frozen(d_ice)
        if sst_frozen: n_frozen_sst += 1
        if ice_frozen: n_frozen_ice += 1

        for ax, d_field, titulo, unidade, cmap, frozen in [
            (axes_row[0], d_sst, 'δSST  (So_t)', 'K',     'RdBu_r', sst_frozen),
            (axes_row[1], d_ice, 'δSi_ifrac',    '[0-1]', 'BrBG',   ice_frozen),
        ]:
            # Limite absoluto (informativo) e limite robusto (escala visual)
            lim_abs = _safe_stat(lambda a: float(np.ma.abs(a).max()), d_field)
            lim_rob = _robust_limit(d_field)
            if np.isnan(lim_rob):
                lim_rob = lim_abs
            limite = max(1e-6, lim_rob if not np.isnan(lim_rob) else 1e-6)
            if np.isnan(limite):
                limite = 1e-6

            # Aviso de outlier no título quando lim_abs >> escala visual
            outlier_str = ''
            if (not np.isnan(lim_abs) and not np.isnan(lim_rob)
                    and lim_abs > 2.0 * max(lim_rob, 1e-6)):
                outlier_str = f'\n⚠ outlier: máx|δ|={lim_abs:.4g} {unidade}'

            norm = TwoSlopeNorm(vcenter=0.0, vmin=-limite, vmax=limite)
            _plot_field(ax, d_field, lon2d, lat2d, norm, cmap,
                        use_cartopy and HAS_CARTOPY)
            if frozen:
                _annotate_frozen(ax, f'campo congelado\nmáx|δ| < {FROZEN_THRESHOLD:.0e} {unidade}')
            ax.set_title(
                f'{titulo}  —  passo {i+1}\nmáx|δ| = {limite:.4g} {unidade}{outlier_str}',
                fontsize=8,
            )
            plt.colorbar(_get_scalar_mappable(ax), ax=ax,
                         shrink=0.75, pad=0.02, label=unidade)

        fig.suptitle(
            f'Diferença consecutiva  δ(t) = campo(t) − campo(t−1)\n'
            f'{ts_prev}  →  {ts_cur}  |  MONAN-A 2.0 — INPE/CGCT/DIMNT',
            fontsize=9,
        )
        tag = ts_list[i].strftime('%Y%m%d_%H%M%S') if ts_list[i] else f'step{i+1:04d}'
        outfile = os.path.join(outdir, f'diff_consec_{tag}.png')
        fig.savefig(outfile, dpi=120, bbox_inches='tight', facecolor='white')
        plt.close(fig)
        print(f'  Diff passo {i}→{i+1:>3}: {outfile}')
    if n_frozen_sst > 0:
        print(f'  (δSST = 0 em {n_frozen_sst} passos — '
              f'DOCN envia OISST diário constante dentro do dia)')
    if n_frozen_ice > 0:
        print(f'  (δSi_ifrac = 0 em {n_frozen_ice} passos)')
    print()


# ─── Análise 4: Métricas integradas ──────────────────────────────────────────

def analise_metricas(sst_list, ice_list, ts_list, lat, lon, outdir, idx0=0):
    """
    Calcula métricas integradas espacialmente ao longo do tempo:
    área total com gelo (km²), SST média pesada pela área oceânica,
    área de gelo novo e de fusão entre passos consecutivos.
    """
    print('  [4] Métricas integradas (área de gelo, SST pesada)...')

    n = len(sst_list)

    # Peso de área por célula (grade regular lat/lon)
    if lat is not None and lat.ndim == 1 and lon is not None and lon.ndim == 1:
        lat_rad  = np.deg2rad(lat)
        cos_lat  = np.cos(lat_rad)
        cos2d    = cos_lat[:, np.newaxis] * np.ones((1, sst_list[0].shape[-1]))
        dlon     = float(abs(lon[1] - lon[0]))
        dlat     = float(abs(lat[1] - lat[0]))
        cell_area = np.deg2rad(dlon) * np.deg2rad(dlat) * EARTH_R_KM**2 * cos2d
    else:
        cell_area = np.ones(sst_list[0].shape)
        print('  (aviso: grade não regular — área em unidades de células)\n')

    area_gelo  = []
    sst_pesada = []
    area_novo  = []
    area_fusao = []

    for i in range(n):
        ice = np.ma.array(ice_list[i])
        sst = np.ma.array(sst_list[i])
        ocean_mask = ~np.ma.getmaskarray(sst)

        # Área com gelo
        ice_mask = (ice > IFRAC_MIN_ICE) & ocean_mask
        area_gelo.append(float(np.sum(cell_area[ice_mask])))

        # SST média pesada
        w = cell_area * ocean_mask.astype(float)
        w_sum = float(np.sum(w))
        sst_pesada.append(
            float(np.sum(np.ma.filled(sst, 0.0) * w)) / w_sum
            if w_sum > 0 else float('nan')
        )

        # Área de gelo novo / fusão
        if i > 0:
            ice_prev = np.ma.array(ice_list[i - 1])
            novo  = (ice > IFRAC_MIN_ICE) & (ice_prev <= IFRAC_MIN_ICE) & ocean_mask
            fusao = (ice_prev > IFRAC_MIN_ICE) & (ice <= IFRAC_MIN_ICE) & ocean_mask
            area_novo.append(float(np.sum(cell_area[novo])))
            area_fusao.append(float(np.sum(cell_area[fusao])))
        else:
            area_novo.append(0.0)
            area_fusao.append(0.0)

    x = [ts_list[i] if ts_list[i] else i + 1 for i in range(n)]

    _sep('─')
    print(f'  {"Passo":>5}  {"Tempo":>16}  '
          f'{"Área gelo (km²)":>16}  '
          f'{"SST pesada (K)":>14}  '
          f'{"Novo (km²)":>11}  '
          f'{"Fusão (km²)":>11}')
    _sep('─')
    for i in range(n):
        ts_str = ts_list[i].strftime('%Y-%m-%d %H:%M') if ts_list[i] else '—'
        sp = sst_pesada[i]
        sp_s = f'{sp:14.4f}' if not np.isnan(sp) else f'{"nan":>14}'
        print(f'  {i+1:>5}  {ts_str:>16}  '
              f'{area_gelo[i]:>16,.0f}  '
              f'{sp_s}  '
              f'{area_novo[i]:>11,.0f}  '
              f'{area_fusao[i]:>11,.0f}')
    _sep('─')
    print()

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
    except ImportError:
        print('  (matplotlib não disponível — pulando gráfico)\n')
        return

    os.makedirs(outdir, exist_ok=True)
    fig, axes = plt.subplots(2, 2, figsize=(14, 8), constrained_layout=True)

    paineis = [
        (axes[0, 0], area_gelo,  'Área total com gelo  (Si_ifrac > 0.15)', 'km²',  'royalblue'),
        (axes[0, 1], sst_pesada, 'SST média pesada por área oceânica',     'K',    'tomato'),
        (axes[1, 0], area_novo,  'Área de congelamento novo (passo a passo)', 'km²', 'navy'),
        (axes[1, 1], area_fusao, 'Área de fusão de gelo (passo a passo)',  'km²',  'darkorange'),
    ]
    for ax, vals, titulo, unidade, cor in paineis:
        ax.plot(x, vals, 'o-', color=cor, lw=2, ms=6)
        ax.fill_between(x, 0, vals, alpha=0.12, color=cor)
        if isinstance(x[0], datetime):
            ax.xaxis.set_major_formatter(mdates.DateFormatter('%d/%m %H:%M'))
            fig.autofmt_xdate(rotation=30)
        ax.set_title(titulo, fontsize=9)
        ax.set_ylabel(unidade)
        ax.grid(True, alpha=0.3)
        # Ajustar escala Y excluindo outlier do passo sst_default (idx0>0)
        if idx0 > 0 and len(vals) > idx0 + 1:
            vals_reais = [v for v in vals[idx0:] if not np.isnan(v)]
            if vals_reais:
                vmin_r = min(vals_reais)
                vmax_r = max(vals_reais)
                intervalo = vmax_r - vmin_r
                # Margem relativa ao intervalo real; sem piso fixo para não
                # incluir o spike do passo sst_default na janela visível
                margem = max(intervalo * 0.15, abs(vmax_r) * 0.05, 0.01)
                ax.set_ylim(max(0, vmin_r - margem), vmax_r + margem)

    fig.suptitle(
        'MONAN-A 2.0 — Métricas integradas: SST e Gelo Marinho\n'
        'INPE/CGCT/DIMNT  |  GT Acoplamento de Modelos',
        fontsize=10,
    )
    outfile = os.path.join(outdir, 'sst_ifrac_metricas.png')
    fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print(f'  Gráfico de métricas: {outfile}\n')


# ─── Helpers de plotagem ──────────────────────────────────────────────────────

def _prep_grid(lat, lon):
    """Prepara grade 2D para pcolormesh; retorna (lon2d, lat2d, use_cartopy)."""
    if lat is not None and lon is not None and lat.ndim == 1 and lon.ndim == 1:
        lon2d, lat2d = np.meshgrid(lon, lat)
        return lon2d, lat2d, True
    if lat is not None and lon is not None and lat.ndim == 2:
        return lon, lat, True
    return None, None, False


def _plot_field(ax, field, lon2d, lat2d, norm, cmap, use_cartopy):
    """Plota campo 2D no eixo ax com ou sem projeção Cartopy."""
    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature
    except ImportError:
        use_cartopy = False

    if use_cartopy and lon2d is not None:
        # Fundo azul-claro para o oceano (evita branco invisível quando δ≈0)
        ax.set_facecolor('#d0e8f5')
        cf = ax.pcolormesh(lon2d, lat2d, field,
                           norm=norm, cmap=cmap,
                           transform=ccrs.PlateCarree(), shading='auto')
        ax.add_feature(cfeature.LAND, facecolor='lightgray', zorder=5)
        ax.add_feature(cfeature.COASTLINE, linewidth=0.4, edgecolor='black', zorder=6)
        ax.set_global()
    elif lon2d is not None:
        ax.pcolormesh(lon2d, lat2d, field, norm=norm, cmap=cmap, shading='auto')
    else:
        ax.imshow(field, norm=norm, cmap=cmap, origin='lower', aspect='auto')


def _get_scalar_mappable(ax):
    """Retorna o último ScalarMappable do eixo para colorbar."""
    import matplotlib.cm as cm
    for c in reversed(ax.collections):
        if hasattr(c, 'get_array'):
            return c
    return cm.ScalarMappable()


# ─── CLI ─────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description='Diagnóstico de evolução temporal de SST e Si_ifrac',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Exemplos:\n'
            '  python3 analisa_sst_ifrac.py                    # todas as análises\n'
            '  python3 analisa_sst_ifrac.py --timeseries       # só série temporal\n'
            '  python3 analisa_sst_ifrac.py --anomaly          # só anomalia Δ(t)\n'
            '  python3 analisa_sst_ifrac.py --diff             # só diferença δ(t)\n'
            '  python3 analisa_sst_ifrac.py --metrics          # só métricas integradas\n'
            '  python3 analisa_sst_ifrac.py --debug            # inspeciona variáveis\n'
        ),
    )
    parser.add_argument('--diagdir',    default='diag_import',
                        help='diretório com arquivos de diagnóstico NetCDF')
    parser.add_argument('--outdir',     default='diag_import/sst_ifrac_diag',
                        help='diretório de saída para figuras e tabelas')
    parser.add_argument('--timeseries', action='store_true')
    parser.add_argument('--anomaly',    action='store_true')
    parser.add_argument('--diff',       action='store_true')
    parser.add_argument('--metrics',    action='store_true')
    parser.add_argument('--debug',      action='store_true',
                        help='imprime variáveis e atributos do primeiro arquivo')
    return parser.parse_args()


# ─── Ponto de entrada ────────────────────────────────────────────────────────

def main():
    args = parse_args()

    run_all = not any([args.timeseries, args.anomaly, args.diff, args.metrics])
    if run_all:
        args.timeseries = args.anomaly = args.diff = args.metrics = True

    _header()
    print(f'  Diagnósticos : {os.path.abspath(args.diagdir)}')
    print(f'  Saída        : {os.path.abspath(args.outdir)}')
    print()

    sst_list, ice_list, ts_list, lat, lon, fonte, nao_preenchido, idx0 = \
        load_data(args.diagdir, debug=args.debug)

    os.makedirs(args.outdir, exist_ok=True)

    if nao_preenchido:
        print('  NOTA: campo So_t não preenchido — série temporal e métricas')
        print('  mostrarão NaN ou zeros.  Verifique a lógica de acoplamento.')
        print()

    if args.timeseries:
        analise_timeseries(sst_list, ice_list, ts_list, args.outdir, idx0=idx0)

    if args.metrics:
        analise_metricas(sst_list, ice_list, ts_list, lat, lon, args.outdir, idx0=idx0)

    if args.anomaly:
        analise_anomalia(sst_list, ice_list, ts_list, lat, lon, args.outdir, idx0=idx0)

    if args.diff:
        analise_diff_consecutiva(sst_list, ice_list, ts_list, lat, lon, args.outdir, idx0=idx0)

    _sep()
    print('  Concluído.')
    _sep()
    print()


if __name__ == '__main__':
    main()
