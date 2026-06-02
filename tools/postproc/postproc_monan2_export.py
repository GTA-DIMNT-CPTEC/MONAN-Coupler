#!/usr/bin/env python3
"""
postproc_monan2_export.py  —  Pós-processamento dos campos CMEPS exportados
                              pelo cap NUOPC do MONAN-A 2.0 (MPAS-A 8.3)

Versão 2.5 — compatível com mpas_cap_netcdf_mod v2.9 (campos instantâneos).
             GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

Correções v2.5 (13/05/2026):
  [E5] load_all_steps — import redundante de Dataset removido (já importado no
       nível do módulo). A instrução 'from netCDF4 import Dataset as _DS' dentro
       da função criava um segundo vínculo desnecessário ao mesmo objeto.
  [E6] _default_fields em main() — construção simplificada com list comprehension
       única; comentário de contagem atualizado para refletir os campos presentes.

Correções v2.4 (20/04/2026):
  [E4] main() — step_indices padrão gerava apenas 3 mapas (primeiro, meio,
       último). Corrigido: novo argumento --all-steps para mapas de TODOS os
       passos; padrão sem flag: ~8 passos uniformemente espaçados + último.
       --stats e --csv sempre processavam todos os passos (sem alteração).

Correções v2.3 (20/04/2026):
  [E1] plot_maps — ramos if/else idênticos (código morto) → simplificado.
  [E2] fill_latlon_gaps — comentários de direção do np.roll incorretos → corrigidos.
  [E3] _get_plot_norm — extend logic expandida: distingue neither/max/both
       com base em vmin_fixed, vmax_fixed e symmetric.
  [B-28] field_outlier_threshold — Sa_u10m/v10m: 10 m/s → 150 m/s.
       Ventos > 10 m/s são fisicamente normais (alísios, jatos, ciclones);
       o limiar anterior filtrava 2.6% dos bins, subestimando σ_cap em 7%.
       (mpas_cap_netcdf.F90 v2.9 já inclui essa correção)
             GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Abril 2026

Todos os campos no NetCDF v2.5 já estão em unidades instantâneas:
  Faxa_swdn/lwdn : W/m²       (média do intervalo de acoplamento)
  Faxa_prec      : kg/m²/s    (média do intervalo de acoplamento)
  Faxa_taux/tauy : N/m²       (ρ·ust²·(u,v)/|V10|, instantâneo)
  Sa_*           : unidades nativas MPAS, instantâneos

O mpas_cap_netcdf_mod v2.5 corrige quatro bugs em relação à v2.4:
  [1] XADREZ: interpola Voronoi→1° no PET0 (inalterado).
  [2] ACUMULADOS: Faxa_swdn/lwdn/prec convertidos em mpas_atm_model.F90
      como incrementos do intervalo (÷dt_coupling), não médias desde t=0 (÷elapsed_s).
  [3] PRECIPITAÇÃO: rainnc + rainc (convectiva) — antes apenas rainnc.
  [4] STRESS: Faxa_taux/tauy calculados de ust (diag_physics), antes nulos.

Estrutura do arquivo NetCDF lido:
  dimensions: lat(181), lon(360)
  variables : lat(lat) [degrees_north], lon(lon) [degrees_east],
              time (escalar, seconds since start_time),
              <campo>(lat,lon) em unidades instantâneas corrigidas.

Modos:
  --stats      estatísticas globais por campo e passo (todos os N passos)
  --csv        séries temporais em CSV (um arquivo por campo + consolidado)
  --plot        mapas pcolormesh para passos selecionados + série temporal
  --all         todos os modos [padrão]
  --all-steps   com --plot: gerar mapa para CADA passo (1–N)

Exemplos:
  python3 postproc_monan2_export.py                          # todos os modos, ~8 mapas
  python3 postproc_monan2_export.py --all-steps              # mapa para cada passo (1–48)
  python3 postproc_monan2_export.py --step 1 24 48 --plot   # passos específicos
  python3 postproc_monan2_export.py --field Sa_tbot_mpas Faxa_swdn_mpas --plot
  python3 postproc_monan2_export.py --stats --csv            # sem plotagem
  python3 postproc_monan2_export.py --datadir /outro/caminho/diag_export
  python3 postproc_monan2_export.py --outdir /outro/caminho/postproc

Dependências obrigatórias : numpy, netCDF4
Dependências opcionais    : matplotlib, cartopy  (para --plot)

Instalação no Jaci:
  module load cray-python
  pip install --user numpy netCDF4 matplotlib cartopy
"""

import sys
import os
import glob
import argparse
import csv
from datetime import datetime

import numpy as np

try:
    from netCDF4 import Dataset
except ImportError:
    sys.exit("ERRO: netCDF4 não encontrado.  pip install --user netCDF4")

# ─── Metadados de exibição dos campos CMEPS ────────────────────────────────────
# scale/scale_units : conversão Pa→hPa, kg/m²/s→mm/h, etc.
# cmap              : colormap matplotlib
# norm              : 'linear' | 'log'  (log usa LogNorm)
# vperc             : [pmin, pmax] percentis para limites da colorbar
# symmetric         : True → vmin=-vmax (campos com sinal)
# CMEPS field names as written by mpas_cap_netcdf_mod (mpas_cap.F90).
# The cap renames fields with suffix _mpas to distinguish MPAS from DATM source.
# Old names (Sa_tbot, Sa_ubot ...) are kept as ALIASES at the end of this dict
# for backwards compatibility with files from pre-_mpas-rename runs.
FIELD_META = {
    # ── Campos primários com sufixo _mpas (cap NUOPC v3+) ──────────────────
    'Sa_pslv_mpas':   {'long_name': 'Pressão ao nível do mar',
                       'units': 'Pa',       'scale': 1e-2,   'scale_units': 'hPa',
                       'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98], 'symmetric': False},
    'Sa_tbot_mpas':   {'long_name': 'Temperatura a 2 m',
                       'units': 'K',        'scale': 1.0,    'scale_units': 'K',
                       'cmap': 'RdYlBu_r',  'norm': 'linear', 'vperc': [2, 98], 'symmetric': False},
    'Sa_u10m_mpas':   {'long_name': 'Vento zonal a 10 m',
                       'units': 'm/s',      'scale': 1.0,    'scale_units': 'm/s',
                       'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98], 'symmetric': True},
    'Sa_v10m_mpas':   {'long_name': 'Vento meridional a 10 m',
                       'units': 'm/s',      'scale': 1.0,    'scale_units': 'm/s',
                       'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98], 'symmetric': True},
    'Sa_shum_mpas':   {'long_name': 'Umidade específica a 2 m',
                       'units': 'kg/kg',    'scale': 1e3,    'scale_units': 'g/kg',
                       'cmap': 'YlGnBu',   'norm': 'linear', 'vperc': [2, 98], 'symmetric': False},
    'Faxa_swdn_mpas': {'long_name': 'Radiação SW descendente',
                       'units': 'W/m²',     'scale': 1.0,    'scale_units': 'W/m²',
                       'cmap': 'YlOrRd',    'norm': 'linear', 'vperc': [0, 99], 'symmetric': False,
                       'fill_gaps': False, 'vmin_fixed': 1.0, 'vmax_fixed': None},
    'Faxa_lwdn_mpas': {'long_name': 'Radiação LW descendente',
                       'units': 'W/m²',     'scale': 1.0,    'scale_units': 'W/m²',
                       'cmap': 'YlOrRd',    'norm': 'linear', 'vperc': [2, 98], 'symmetric': False},
    'Faxa_rain_mpas': {'long_name': 'Precipitação líquida',
                       'units': 'kg/m²/s',  'scale': 3600.0, 'scale_units': 'mm/h',
                       'cmap': 'GnBu',      'norm': 'log',    'vperc': [5, 99], 'symmetric': False,
                       'fill_gaps': False, 'vmin_fixed': 1e-3, 'vmax_fixed': None},
    'Faxa_snow_mpas': {'long_name': 'Precipitação sólida (neve)',
                       'units': 'kg/m²/s',  'scale': 3600.0, 'scale_units': 'mm/h',
                       'cmap': 'PuBu',      'norm': 'log',    'vperc': [5, 99], 'symmetric': False,
                       'fill_gaps': False, 'vmin_fixed': 1e-4, 'vmax_fixed': None},
    # ── Aliases legado — nomes sem _mpas (arquivos antigos e MED exportState) ─
    'Sa_pslv':    {'long_name': 'Pressão ao nível do mar (legado)',
                   'units': 'Pa',       'scale': 1e-2,   'scale_units': 'hPa',
                   'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98],  'symmetric': False},
    'Sa_tbot':    {'long_name': 'Temperatura a 2 m (legado)',
                   'units': 'K',        'scale': 1.0,    'scale_units': 'K',
                   'cmap': 'RdYlBu_r',  'norm': 'linear', 'vperc': [2, 98],  'symmetric': False},
    'Sa_ubot':    {'long_name': 'Vento zonal a 10 m (legado)',
                   'units': 'm/s',      'scale': 1.0,    'scale_units': 'm/s',
                   'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98],  'symmetric': True},
    'Sa_vbot':    {'long_name': 'Vento meridional a 10 m (legado)',
                   'units': 'm/s',      'scale': 1.0,    'scale_units': 'm/s',
                   'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98],  'symmetric': True},
    'Faxa_swdn':  {'long_name': 'Radiação SW descendente (legado)',
                   'units': 'W/m²',     'scale': 1.0,    'scale_units': 'W/m²',
                   'cmap': 'YlOrRd',    'norm': 'linear', 'vperc': [0, 99],  'symmetric': False,
                   'fill_gaps': False, 'vmin_fixed': 1.0, 'vmax_fixed': None},
    'Faxa_lwdn':  {'long_name': 'Radiação LW descendente (legado)',
                   'units': 'W/m²',     'scale': 1.0,    'scale_units': 'W/m²',
                   'cmap': 'YlOrRd',    'norm': 'linear', 'vperc': [2, 98],  'symmetric': False},
    'Faxa_prec':  {'long_name': 'Precipitação total (legado)',
                   'units': 'kg/m²/s',  'scale': 3600.0, 'scale_units': 'mm/h',
                   'cmap': 'GnBu',      'norm': 'log',    'vperc': [5, 99],  'symmetric': False,
                   'fill_gaps': False, 'vmin_fixed': 1e-3, 'vmax_fixed': None},
    'Faxa_taux':  {'long_name': 'Tensão de cisalh. zonal',
                   'units': 'N/m²',     'scale': 1.0,    'scale_units': 'N/m²',
                   'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98],  'symmetric': True},
    'Faxa_tauy':  {'long_name': 'Tensão de cisalh. meridional',
                   'units': 'N/m²',     'scale': 1.0,    'scale_units': 'N/m²',
                   'cmap': 'RdBu_r',    'norm': 'linear', 'vperc': [2, 98],  'symmetric': True},
    'Faxa_lhflx': {'long_name': 'Fluxo calor latente (MED)',
                   'units': 'W/m²',     'scale': 1.0,    'scale_units': 'W/m²',
                   'cmap': 'RdYlBu_r',  'norm': 'linear', 'vperc': [2, 98],  'symmetric': False},
    'Faxa_shflx': {'long_name': 'Fluxo calor sensível (MED)',
                   'units': 'W/m²',     'scale': 1.0,    'scale_units': 'W/m²',
                   'cmap': 'RdYlBu_r',  'norm': 'linear', 'vperc': [2, 98],  'symmetric': False},
}

# Guard contra fill value Fortran = -9.99e+33 (finito — não detectável por np.isfinite)
_FILL_GUARD = 1.0e30


# ─── Leitura ───────────────────────────────────────────────────────────────────

def find_export_files(datadir):
    """Lista ordenada de monan_export_*.nc."""
    files = sorted(glob.glob(os.path.join(datadir, 'monan_export_????????_??????.nc')))
    if not files:
        sys.exit(f"ERRO: nenhum arquivo monan_export_*.nc em '{datadir}'")
    return files


def parse_timestamp(path):
    """Extrai datetime de monan_export_YYYYMMDD_HHMMSS.nc."""
    ts = os.path.basename(path)[len('monan_export_'):-3]   # '20260330_000000'
    return datetime.strptime(ts, '%Y%m%d_%H%M%S')


def load_grid_coords(ncfile):
    """
    Lê lon(360,) e lat(181,) do arquivo gerado pelo módulo v2.4.
    Falha com mensagem clara se o arquivo for de versão anterior.
    """
    with Dataset(ncfile) as nc:
        if 'lon' not in nc.variables or 'lat' not in nc.variables:
            sys.exit(
                "ERRO: variáveis 'lon'/'lat' ausentes no NetCDF.\n"
                "      Arquivo gerado por mpas_cap_netcdf_mod < v2.4?\n"
                "      Recompilar o cap com a versão v2.4 e reexecutar o experimento.")
        lon = np.asarray(nc.variables['lon'][:], dtype=np.float64)
        lat = np.asarray(nc.variables['lat'][:], dtype=np.float64)
    return lon, lat


def _to_float_array(raw, var=None):
    """
    Converte MaskedArray ou ndarray para float64 com fill→NaN.
    Se var for um netCDF4.Variable 2D com dimensões ('lon','lat'),
    transpõe para (lat,lon) = (nlat,nlon) conforme esperado pelo pcolormesh.

    Contexto: Fortran grava grid(NLON,NLAT) com dims=[dimid_lon,dimid_lat].
    Python lê shape (NLON,NLAT) em C-order → transpor para (NLAT,NLON).
    """
    if hasattr(raw, 'filled'):
        arr = np.asarray(raw.filled(np.nan), dtype=np.float64)
    else:
        arr = np.asarray(raw, dtype=np.float64)
    # Guard: fill value Fortran (-9.99e33) é finito
    arr = np.where(np.abs(arr) > _FILL_GUARD, np.nan, arr)
    # Transpor se dims = ('lon','lat') → (NLON,NLAT) → (NLAT,NLON)
    if var is not None and hasattr(var, 'dimensions'):
        if len(var.dimensions) == 2 and \
           var.dimensions[0] == 'lon' and var.dimensions[1] == 'lat':
            arr = arr.T   # (NLON,NLAT) → (NLAT,NLON) = (181,360)
    return arr


def load_step(ncfile, field_names):
    """
    Lê campos e metadados de um arquivo de grade regular.
    Retorna dict com time_s, atributos globais e arrays (nlat, nlon) por campo.
    """
    result = {}
    with Dataset(ncfile) as nc:
        if 'time' in nc.variables:
            result['time_s'] = float(_to_float_array(nc.variables['time'][...]).flat[0])
        for attr in ('elapsed_time_s', 'ncells_global', 'coupling_step', 'grid_resolution'):
            if hasattr(nc, attr):
                result[f'_{attr}'] = getattr(nc, attr)
        for fname in field_names:
            if fname in nc.variables:
                ncvar = nc.variables[fname]
                result[fname] = _to_float_array(ncvar[:], ncvar)
    return result


def load_all_steps(files, field_names):
    """
    Carrega todos os arquivos em arrays (nsteps, nlat, nlon).

    Retorna:
      timestamps : list[datetime]
      time_s     : np.ndarray (nsteps,)
      fields     : dict {field: np.ndarray (nsteps, nlat, nlon)}
      lat, lon   : np.ndarray 1D — eixos da grade regular
    """
    print(f"  Carregando {len(files)} arquivos...")
    timestamps = [parse_timestamp(f) for f in files]

    lon, lat = load_grid_coords(files[0])
    nlat, nlon = len(lat), len(lon)

    # Descobrir quais campos estão no arquivo (auto-detecção).
    # Tenta nome exato; se ausente, tenta variante com/sem sufixo _mpas.
    with Dataset(files[0]) as _nc:          # Dataset já importado no nível do módulo
        nc_vars = set(_nc.variables.keys())

    # Expandir field_names com variações _mpas
    resolved = {}   # nome_canônico -> nome_no_arquivo
    for f in field_names:
        if f in nc_vars:
            resolved[f] = f
        elif f + '_mpas' in nc_vars:
            resolved[f] = f + '_mpas'
        elif f.replace('_mpas', '') in nc_vars and '_mpas' in f:
            resolved[f] = f.replace('_mpas', '')
    # Também incluir campos _mpas não solicitados explicitamente mas presentes
    for v in nc_vars:
        if v not in resolved.values() and v in FIELD_META:
            resolved[v] = v

    # Realocar field_names com nomes canônicos resolvidos
    field_names_resolved = list(resolved.values())
    sample    = load_step(files[0], field_names_resolved)
    available = [f for f in field_names_resolved if f in sample]

    if not available:
        # Fallback: listar todos os campos no arquivo e usar os que estao em FIELD_META
        available = [v for v in nc_vars if v in FIELD_META and v != 'lat' and v != 'lon' and v != 'time']
        sample    = load_step(files[0], available)
        available = [f for f in available if f in sample]
        print(f"  Auto-detectados {len(available)} campos: {available}")

    if len(available) < len(field_names):
        missing = set(field_names) - set(available)
        print(f"  AVISO: campos não encontrados (esperado com nomes _mpas): {sorted(missing)}")

    # Validar shape da grade
    for fname in available:
        shape = sample[fname].shape
        if shape != (nlat, nlon):
            sys.exit(
                f"ERRO: {fname} shape={shape}, esperado ({nlat},{nlon}).\n"
                "      Arquivo de versão anterior (grade Voronoi)?")

    # Alocar e preencher arrays
    fields = {f: np.full((len(files), nlat, nlon), np.nan) for f in available}
    time_s = np.zeros(len(files))

    for i, ncfile in enumerate(files):
        d = load_step(ncfile, available)
        time_s[i] = d.get('time_s', i * 1800.0)
        for f in available:
            if f in d:
                fields[f][i] = d[f]

    print(f"  Grade: lat({nlat}) × lon({nlon})"
          f"  |  {len(available)} campos × {len(files)} passos")
    return timestamps, time_s, fields, lat, lon


# ─── --stats ───────────────────────────────────────────────────────────────────

def print_stats(timestamps, time_s, fields, field_names):
    """Tabela de estatísticas espaciais por campo e por passo."""
    print()
    print('╔' + '═'*84 + '╗')
    print('║{:^84}║'.format(
        'ESTATÍSTICAS — CAMPOS EXPORTADOS MONAN-A 2.0  (grade 1° lat/lon)'))
    print('╚' + '═'*84 + '╝')

    for fname in field_names:
        if fname not in fields:
            continue
        meta  = FIELD_META.get(fname, {'long_name': fname, 'scale': 1.0, 'scale_units': '?'})
        data  = fields[fname] * meta['scale']   # (nsteps, nlat, nlon)
        units = meta['scale_units']
        is_log = meta.get('norm') == 'log'

        print()
        print(f"  ┌─ {fname}  —  {meta['long_name']}  [{units}]")
        print(f"  │  {'Passo':>5}  {'Data/hora':^20}  "
              f"{'Mínimo':>12}  {'Máximo':>12}  {'Média':>12}  {'DesvPad':>10}")
        print(f"  │  {'─'*74}")

        for i, ts in enumerate(timestamps):
            row = data[i].ravel()
            row = row[np.isfinite(row)]
            if is_log:
                row = row[row > 0]
            if len(row) == 0:
                continue
            print(f"  │  {i+1:>5}  {ts.strftime('%Y-%m-%d %H:%M'):^20}"
                  f"  {row.min():>12.4f}  {row.max():>12.4f}"
                  f"  {row.mean():>12.4f}  {row.std():>10.4f}")

        all_v = data[np.isfinite(data)].ravel()
        if is_log:
            all_v = all_v[all_v > 0]
        print(f"  │  {'─'*74}")
        if len(all_v):
            print(f"  │  {'SÉRIE':>5}  {'(todos os passos)':^20}"
                  f"  {all_v.min():>12.4f}  {all_v.max():>12.4f}"
                  f"  {all_v.mean():>12.4f}  {all_v.std():>10.4f}")
        print(f"  └{'─'*75}")
    print()


# ─── --csv ─────────────────────────────────────────────────────────────────────

def export_csv(timestamps, time_s, fields, field_names, outdir):
    """Um CSV por campo com estatísticas espaciais por passo."""
    os.makedirs(outdir, exist_ok=True)
    for fname in field_names:
        if fname not in fields:
            continue
        meta = FIELD_META.get(fname, {'scale': 1.0, 'scale_units': '?'})
        data = fields[fname] * meta['scale']    # (nsteps, nlat, nlon)
        csvf = os.path.join(outdir, f'monan_ts_{fname}.csv')
        u    = meta['scale_units']
        with open(csvf, 'w', newline='', encoding='utf-8') as fh:
            w = csv.writer(fh)
            w.writerow(['passo', 'timestamp', 'elapsed_s',
                        f'min_{u}', f'max_{u}', f'mean_{u}', f'std_{u}', 'n_validos'])
            for i, ts in enumerate(timestamps):
                row = data[i].ravel()
                row = row[np.isfinite(row)]
                if meta.get('norm') == 'log':
                    row = row[row > 0]
                if len(row):
                    w.writerow([i+1, ts.strftime('%Y-%m-%dT%H:%M:%S'), time_s[i],
                                 f'{row.min():.6g}', f'{row.max():.6g}',
                                 f'{row.mean():.6g}', f'{row.std():.6g}', len(row)])
        print(f"  CSV: {csvf}")


def export_summary_csv(timestamps, time_s, fields, field_names, outdir):
    """CSV consolidado: todos os campos × todos os passos."""
    os.makedirs(outdir, exist_ok=True)
    available = [f for f in field_names if f in fields]
    csvf      = os.path.join(outdir, 'monan_export_stats.csv')
    header    = ['passo', 'timestamp', 'elapsed_s']
    for f in available:
        for st in ('min', 'max', 'mean', 'std'):
            header.append(f'{f}_{st}')
    with open(csvf, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for i, ts in enumerate(timestamps):
            row = [i+1, ts.strftime('%Y-%m-%dT%H:%M:%S'), time_s[i]]
            for f in available:
                meta = FIELD_META.get(f, {'scale': 1.0})
                d    = (fields[f][i] * meta['scale']).ravel()
                d    = d[np.isfinite(d)]
                if meta.get('norm') == 'log':
                    d = d[d > 0]
                row += ([f'{d.min():.6g}', f'{d.max():.6g}',
                          f'{d.mean():.6g}', f'{d.std():.6g}']
                        if len(d) else [np.nan, np.nan, np.nan, np.nan])
            w.writerow(row)
    print(f"  CSV consolidado: {csvf}")


# ─── --plot ────────────────────────────────────────────────────────────────────

def fill_latlon_gaps(arr, passes=30):
    """
    Preenche lacunas (NaN) em grade lat/lon 2D por propagação iterativa
    dos vizinhos válidos (4-conectado: N, S, E, W) — apenas numpy, sem scipy.

    Número de passes e largura máxima de gap preenchível:
      Com o spray Fortran 3×3 (NSPAN=1), os gaps de longitude crescem
      com a latitude: ~2° em 75°S, ~4° em 80°S, ~10° em 85°S, ~60° em 89°S.
      Cada par de passes preenche ±1 célula de cada lado do gap.
      30 passes preenchem gaps de até 60 colunas → cobre até lat=89°.

    Correções em relação à versão anterior (4 passes):
      1. Passes: 4 → 30 (cobre gaps polares de até 60° de longitude)
      2. Wrap polar: np.roll(axis=0) conectava polo Sul ao polo Norte.
         Agora as linhas extremas de latitude são mascaradas antes de
         usar como vizinhos (polos não têm vizinhos além de si mesmos).
      3. Parada antecipada: encerra assim que não há mais NaN.

    Parâmetros:
      arr   : array (nlat, nlon), pode conter NaN
      passes: número máximo de iterações (padrão=30)

    Retorna array preenchido; NaN remanescente apenas em regiões sem
    nenhum vizinho válido após todas as iterações (raro após 30 passes).
    """
    filled = arr.copy()
    nlat, nlon = filled.shape

    for _ in range(passes):
        nans = np.isnan(filled)
        if not nans.any():
            break
        sum_v   = np.zeros_like(filled)
        count_v = np.zeros((nlat, nlon), dtype=np.int32)

        # Vizinhos em latitude — sem wrap: os polos (linha 0 e linha -1)
        # não têm vizinhos "além" deles, então mascaramos o overflow.
        for shift in (-1, 1):
            nb = np.roll(filled, shift, axis=0)
            # np.roll(axis=0, shift=-1): desloca PARA CIMA (índice diminui).
            #   nb[0] recebe filled[-1] (polo Sul circula para polo Norte via wrap).
            #   Mascarar nb[0] impede que o polo Sul influencie o polo Norte.
            # np.roll(axis=0, shift=+1): desloca PARA BAIXO (índice aumenta).
            #   nb[-1] recebe filled[0] (polo Norte circula para polo Sul via wrap).
            #   Mascarar nb[-1] impede que o polo Norte influencie o polo Sul.
            if shift == -1:
                nb[0, :]  = np.nan   # polo Sul não pode ser vizinho Norte via wrap
            else:
                nb[-1, :] = np.nan   # polo Norte não pode ser vizinho Sul via wrap
            valid    = np.isfinite(nb)
            sum_v   += np.where(valid, nb, 0.0)
            count_v += valid.astype(np.int32)

        # Vizinhos em longitude — wrap periódico [-180, 180) é fisicamente correto
        for shift in (-1, 1):
            nb    = np.roll(filled, shift, axis=1)
            valid = np.isfinite(nb)
            sum_v   += np.where(valid, nb, 0.0)
            count_v += valid.astype(np.int32)

        fill_mask = nans & (count_v > 0)
        filled = np.where(fill_mask,
                          sum_v / np.where(count_v > 0, count_v, 1),
                          filled)
    return filled


def _get_plot_norm(fname, data_2d):
    """
    Retorna (cmap, norm, vmin, vmax, extend) adaptados ao campo físico.
    data_2d: (nlat, nlon) em unidades de exibição (após scale), pode conter NaN.

    Para campos com 'vmin_fixed' em FIELD_META (ex.: Faxa_prec):
      vmin é fixo e independente dos dados do passo — evita que a colorbar
      salte entre passos quando o campo é esparso (log scale).
    """
    try:
        import matplotlib.colors as mc
    except ImportError:
        v = data_2d[np.isfinite(data_2d)]
        return 'viridis', None, float(v.min()), float(v.max()), 'both'

    meta      = FIELD_META.get(fname, {})
    cmap      = meta.get('cmap', 'viridis')
    norm_type = meta.get('norm', 'linear')
    vperc     = meta.get('vperc', [2, 98])
    symmetric = meta.get('symmetric', False)
    vmin_fx   = meta.get('vmin_fixed', None)   # limiar inferior físico fixo
    vmax_fx   = meta.get('vmax_fixed', None)   # limiar superior físico fixo
    valid     = data_2d[np.isfinite(data_2d)].ravel()

    if norm_type == 'log':
        pos = valid[valid > 0]
        if len(pos) == 0:
            return cmap, None, 0.0, 1.0, 'neither'

        # vmin: preferir valor físico fixo (estável entre passos)
        if vmin_fx is not None:
            vmin = float(vmin_fx)
        else:
            vmin = max(float(np.percentile(pos, max(vperc[0], 1))), 1e-9)

        # vmax: fixo se especificado, senão percentil dinâmico
        if vmax_fx is not None:
            vmax = float(vmax_fx)
        else:
            vmax = float(np.percentile(pos, vperc[1]))
        if vmax <= vmin:
            vmax = vmin * 100

        return cmap, mc.LogNorm(vmin=vmin, vmax=vmax), vmin, vmax, 'max'

    vmin, vmax = float(np.nanpercentile(valid, vperc[0])), \
                 float(np.nanpercentile(valid, vperc[1]))
    # Para campos com vmin_fixed (ex.: Faxa_swdn): usar limiar fixo como vmin.
    # Isso garante colorbar estável entre passos e que células com valor < vmin
    # (artefatos de spray ou ruído) sejam mascaradas como NaN antes de plotar.
    if vmin_fx is not None:
        vmin = float(vmin_fx)
    if vmax_fx is not None:
        vmax = float(vmax_fx)
    if symmetric:
        absmax = max(abs(vmin), abs(vmax))
        vmin, vmax = -absmax, absmax
    # extend:
    #   'both'   → dados estendem acima de vmax e abaixo de vmin (campos sem clipping)
    #   'max'    → dados estendem acima de vmax; abaixo de vmin são NaN (vmin_fixed)
    #   'neither'→ todos os dados dentro do intervalo (raro)
    if vmin_fx is not None and vmax_fx is not None:
        extend = 'neither'
    elif vmin_fx is not None and not symmetric:
        extend = 'max'    # clipping abaixo de vmin (→NaN); dado pode superar vmax
    else:
        extend = 'both'   # percentis: 2% abaixo de vmin, 2% acima de vmax
    return cmap, None, vmin, vmax, extend


def _probe_natural_earth():
    """Verifica disponibilidade dos shapefiles 110m em cache local."""
    try:
        import cartopy.io.shapereader as shr
        for cat, name in [('physical', 'coastline'), ('physical', 'land'),
                          ('physical', 'ocean'),
                          ('cultural', 'admin_0_boundary_lines_land')]:
            if not os.path.isfile(shr.natural_earth('110m', cat, name)):
                return False
        return True
    except Exception:
        return False


def plot_maps(timestamps, fields, field_names, lat, lon, step_indices, outdir):
    """
    Mapas globais com ax.pcolormesh(lon_2d, lat_2d, data) — sem interpolação.

    O NetCDF v2.4 já contém dados na grade regular 1°×1°:
      campos[fname][step] → shape (181, 360) = (nlat, nlon)
    Leitura direta: sem scipy, sem meshfile externo.

    Prioridade de renderização:
      1. cartopy + Natural Earth 110m  (cache local)
      2. cartopy + grade apenas
      3. matplotlib puro
    """
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  AVISO: matplotlib não encontrado — ignorando --plot.")
        print("         pip install --user matplotlib")
        return

    try:
        import cartopy.crs     as ccrs
        import cartopy.feature as cfeature
        HAS_CARTOPY = True
    except ImportError:
        HAS_CARTOPY = False

    if HAS_CARTOPY:
        print("  Natural Earth 110m...", end=' ', flush=True)
        HAS_FEAT = _probe_natural_earth()
        print("OK." if HAS_FEAT else "ausente — somente grade.")
    else:
        HAS_FEAT = False
        print("  AVISO: cartopy não encontrado — mapa sem projeção.")

    os.makedirs(outdir, exist_ok=True)

    # Grade 2D para pcolormesh — meshgrid dos eixos 1D
    lon_2d, lat_2d = np.meshgrid(lon, lat)   # (181, 360) cada

    for fname in field_names:
        if fname not in fields:
            continue
        meta = FIELD_META.get(fname, {
            'long_name': fname, 'scale': 1.0, 'scale_units': '?'})

        for step_i in step_indices:
            if step_i >= len(timestamps):
                continue
            ts         = timestamps[step_i]
            data       = fields[fname][step_i] * meta['scale']   # (nlat, nlon)
            data_plot  = np.where(np.isfinite(data), data, np.nan)

            # Preencher lacunas residuais por propagação de vizinhos válidos.
            # Não aplicar para campos esparsos (fill_gaps=False em FIELD_META):
            # Faxa_taux/tauy e Faxa_prec são fisicamente não-definidos onde não
            # há dados — preencher espalharia valores reais para regiões secas.
            if meta.get('fill_gaps', True):
                data_plot = fill_latlon_gaps(data_plot)

            cmap, norm, vmin, vmax, extend = _get_plot_norm(fname, data_plot)

            # Mascarar valores abaixo de vmin_fixed antes do pcolormesh.
            # Aplicado tanto para campos log (Faxa_prec) quanto lineares (Faxa_swdn):
            #
            # Faxa_prec: spray cria valores artificiais em células secas → fundo falso.
            # Faxa_swdn: spray + fill_gaps propagam SW do terminador para zona noturna.
            #   vmin_fixed=1 W/m² → células noturnas (SW<1 W/m²) ficam brancas (NaN),
            #   preservando a fronteira física dia/noite.
            #
            # Para outros campos com LogNorm sem vmin_fixed: ocultar apenas zeros.
            if meta.get('vmin_fixed') is not None:
                data_plot = np.where(data_plot >= vmin, data_plot, np.nan)
            elif norm is not None:
                data_plot = np.where(data_plot > 0, data_plot, np.nan)

            fig = plt.figure(figsize=(14, 7))

            if HAS_CARTOPY:
                proj = ccrs.PlateCarree()
                ax   = fig.add_subplot(111, projection=proj)
                ax.set_global()

                if HAS_FEAT:
                    for cat, name, fc in [
                        ('physical', 'ocean', '#daeef3'),
                        ('physical', 'land',  '#f5f0e8')]:
                        ax.add_feature(cfeature.NaturalEarthFeature(
                            cat, name, '110m', facecolor=fc, edgecolor='none'), zorder=0)
                else:
                    ax.set_facecolor('#daeef3')

                # pcolormesh direto — grade regular, sem artefatos
                pc = ax.pcolormesh(
                    lon_2d, lat_2d, data_plot,
                    cmap=cmap, norm=norm,
                    vmin=(vmin if norm is None else None),
                    vmax=(vmax if norm is None else None),
                    shading='auto', transform=proj, zorder=5)

                if HAS_FEAT:
                    ax.add_feature(cfeature.NaturalEarthFeature(
                        'physical', 'coastline', '110m',
                        facecolor='none', edgecolor='#222', linewidth=0.7), zorder=10)
                    ax.add_feature(cfeature.NaturalEarthFeature(
                        'cultural', 'admin_0_boundary_lines_land', '110m',
                        facecolor='none', edgecolor='#555',
                        linewidth=0.35, linestyle='--'), zorder=10)

                gl = ax.gridlines(draw_labels=True, linewidth=0.4,
                                  color='gray', alpha=0.5, linestyle='--', zorder=11)
                gl.top_labels   = False
                gl.right_labels = False
                gl.xlabel_style = {'size': 7}
                gl.ylabel_style = {'size': 7}

            else:
                ax = fig.add_subplot(111)
                pc = ax.pcolormesh(
                    lon_2d, lat_2d, data_plot,
                    cmap=cmap, norm=norm,
                    vmin=(vmin if norm is None else None),
                    vmax=(vmax if norm is None else None),
                    shading='auto')
                ax.set_xlabel('Longitude (°)')
                ax.set_ylabel('Latitude (°)')
                ax.set_xlim(-180, 180)
                ax.set_ylim(-90, 90)
                ax.grid(True, alpha=0.4)

            cb = fig.colorbar(pc, ax=ax, orientation='vertical',
                              shrink=0.7, pad=0.02, extend=extend)
            cb.set_label(meta['scale_units'], fontsize=10)

            # Estatísticas do título — calculadas APÓS a máscara de vmin_fixed,
            # portanto refletem apenas precipitação acima do limiar físico.
            valid = data_plot[np.isfinite(data_plot)]
            # FIX E1: ramos if/else eram idênticos (código morto).
            # A filtragem por [vmin, vmax] é correta para ambos os tipos de norma.
            in_range = valid[(valid >= vmin) & (valid <= vmax)]

            if len(in_range) >= 2:
                p2_val  = float(np.percentile(in_range, 2))
                p98_val = float(np.percentile(in_range, 98))
                mean_val = float(in_range.mean())
                stat_str = (f"P₂={p2_val:.3g}  P₉₈={p98_val:.3g}"
                            f"  média={mean_val:.3g} {meta['scale_units']}")
            elif len(in_range) > 0:
                stat_str = f"média={float(in_range.mean()):.3g} {meta['scale_units']}"
            else:
                stat_str = "sem dados na faixa"

            ax.set_title(
                f"{fname}  —  {meta['long_name']}\n"
                f"Passo {step_i+1}  |  {ts.strftime('%Y-%m-%d %H:%M UTC')}"
                f"  |  1.0° lat/lon  |  {stat_str}",
                fontsize=10, pad=10)
            fig.text(0.01, 0.01,
                     'MONAN-A 2.0 / MPAS-A 8.3 — cap NUOPC-ESMF 8.9.1 — INPE/CGCT/DIMNT',
                     fontsize=7, color='gray')

            outfile = os.path.join(outdir, f'monan_{fname}_passo{step_i+1:02d}.png')
            fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
            plt.close(fig)
            print(f"  Figura: {outfile}")


def plot_timeseries(timestamps, fields, field_names, outdir):
    """Painel de séries temporais das médias espaciais globais."""
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

    n, ncols = len(available), 2
    nrows    = (n + 1) // 2
    fig, axes = plt.subplots(nrows, ncols, figsize=(14, 3.5*nrows),
                              sharex=True, constrained_layout=True)
    axes = np.array(axes).flatten()

    for ax, fname in zip(axes, available):
        meta  = FIELD_META.get(fname, {'long_name': fname, 'scale': 1.0, 'scale_units': '?'})
        data  = fields[fname] * meta['scale']           # (nsteps, nlat, nlon)
        flat  = data.reshape(len(timestamps), -1)       # (nsteps, nlat*nlon)
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

    for ax in axes[len(available):]:
        ax.set_visible(False)

    fig.suptitle(
        f"MONAN-A 2.0 / MPAS-A 8.3 — Campos CMEPS exportados (grade 1° lat/lon)\n"
        f"{timestamps[0].strftime('%Y-%m-%d %H:%M')} → "
        f"{timestamps[-1].strftime('%Y-%m-%d %H:%M')}"
        f"  |  {len(timestamps)} passos  |  INPE/CGCT/DIMNT",
        fontsize=11)

    outfile = os.path.join(outdir, 'monan_timeseries.png')
    fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print(f"  Série temporal: {outfile}")


# ─── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Pós-processamento dos campos CMEPS exportados pelo cap NUOPC MONAN-A.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--datadir', default='diag_export',
                        help='Diretório com monan_export_*.nc (padrão: diag_export)')
    parser.add_argument('--outdir',  default='diag_export/postproc',
                        help='Saída: CSV e figuras (padrão: diag_export/postproc)')
    # Campos padrão: primários com sufixo _mpas seguidos pelos aliases legados.
    # dict.fromkeys preserva a ordem de inserção e elimina duplicatas, caso
    # algum nome apareça nas duas condições por alguma adição futura ao dicionário.
    _default_fields = list(dict.fromkeys(
        [k for k in FIELD_META if '_mpas' in k] +
        [k for k in FIELD_META if '_mpas' not in k]
    ))
    parser.add_argument('--field',   nargs='+', default=_default_fields,
                        help='Campos a processar (padrão: todos os campos CMEPS em FIELD_META)')
    parser.add_argument('--step',      nargs='+', type=int, default=None,
                        help='Passos a plotar, base 1 (ex: --step 1 12 24 48)')
    parser.add_argument('--all-steps', action='store_true', dest='all_steps',
                        help='Gerar mapas para TODOS os passos (1–N). '
                             'Por padrão: apenas 1, meio e último')
    parser.add_argument('--stats',   action='store_true',
                        help='Imprimir estatísticas globais')
    parser.add_argument('--csv',     action='store_true',
                        help='Exportar CSV de séries temporais')
    parser.add_argument('--plot',    action='store_true',
                        help='Gerar mapas e série temporal em PNG')
    parser.add_argument('--all',     action='store_true',
                        help='Executar todos os modos [padrão se nenhum especificado]')

    args = parser.parse_args()

    if not any([args.stats, args.csv, args.plot, args.all]):
        args.all = True
    if args.all:
        args.stats = args.csv = args.plot = True

    print()
    print('═' * 70)
    print('  MONAN-A 2.0 — Pós-processamento de Campos CMEPS (grade 1° lat/lon)')
    print('  INPE / CGCT / DIMNT — GT Acoplamento de Modelos')
    print('═' * 70)
    print(f"  Dados  : {os.path.abspath(args.datadir)}")
    print(f"  Saída  : {os.path.abspath(args.outdir)}")
    print(f"  Campos : {', '.join(args.field)}")
    print()

    files   = find_export_files(args.datadir)
    nsteps  = len(files)
    print(f"  Arquivos: {nsteps}"
          f"  ({os.path.basename(files[0])} → {os.path.basename(files[-1])})")
    print()

    # Passos para plotagem
    # --step: seleção explícita (base 1).
    # --all-steps: todos os N passos.
    # padrão (nenhum flag): 1, meio e último — visão rápida do run.
    if args.step:
        step_indices = [s - 1 for s in args.step]
    elif args.all_steps:
        step_indices = list(range(nsteps))   # todos os passos 0..N-1
    else:
        # Padrão: primeiro + cada 3h (a cada 6 passos de 30 min) + último
        # Para run de 24h com dt=30 min: passos 1,7,13,19,25,31,37,43,48
        step_every = max(1, nsteps // 8)     # ~8 mapas representativos
        step_indices = list(range(0, nsteps, step_every))
        if (nsteps - 1) not in step_indices:
            step_indices.append(nsteps - 1)  # garantir o último passo
    step_indices = sorted(set(min(max(s, 0), nsteps - 1) for s in step_indices))

    # Carregamento
    timestamps, time_s, fields, lat, lon = load_all_steps(files, args.field)
    print()

    # Modos
    if args.stats:
        print("  [--stats] Calculando estatísticas...")
        print_stats(timestamps, time_s, fields, args.field)

    if args.csv:
        print("  [--csv] Exportando CSV...")
        os.makedirs(args.outdir, exist_ok=True)
        export_csv(timestamps, time_s, fields, args.field, args.outdir)
        export_summary_csv(timestamps, time_s, fields, args.field, args.outdir)
        print()

    if args.plot:
        n_steps_plot = len(step_indices)
        step_label   = 'todos' if args.all_steps else ', '.join(str(s+1) for s in step_indices)
        print(f"  [--plot] Mapas para {n_steps_plot} passo(s): {step_label}...")
        plot_maps(timestamps, fields, args.field, lat, lon, step_indices, args.outdir)
        plot_timeseries(timestamps, fields, args.field, args.outdir)
        print()

    print('═' * 70)
    print('  Concluído.')
    print('═' * 70)
    print()


if __name__ == '__main__':
    main()
