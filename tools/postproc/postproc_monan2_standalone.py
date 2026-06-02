#!/usr/bin/env python3
"""
postproc_monan2_standalone.py — Pós-processamento do MONAN-A 2.0 Standalone
                                (arquivos MONAN_DIAG_*.nc)

Versão : 1.5 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

Novidades v1.5 (13/05/2026):
  [N4] import 'timezone' removido — importado do módulo datetime mas nunca
       referenciado no corpo do script (PEP 8, F401).
  [N5] load_all_steps — fallback de detecção de nCells protegido com
       tratamento de StopIteration: se nenhuma variável (Time, nCells) existir
       no arquivo, emite mensagem de erro clara em vez de exceção genérica.
  [N6] Docstring de discover_all_fields() aprimorada com exemplo de uso.

Novidades v1.4 (21/04/2026):
  [N1] NOVO argumento --allmaps: gera um mapa por campo por TODOS os passos de
       tempo presentes nos arquivos MONAN_DIAG_*.nc. Complementa --plot, que por
       padrão produz apenas 3 passos (primeiro, meio, último).
       Implica --plot. Pode ser combinado com --field para selecionar campos.
       Uso: python3 postproc_monan2_standalone.py --allmaps
            python3 postproc_monan2_standalone.py --allmaps --field t2m acswdnb

  [N2] NOVO argumento --allfields: descobre automaticamente TODOS os campos
       presentes nos arquivos MONAN_DIAG_*.nc e os processa, mesmo que não
       estejam em FIELD_META. Campos desconhecidos recebem metadados genéricos
       automáticos (cmap viridis, escala linear, percentis [2,98]).
       Pode ser combinado com --allmaps para o processamento completo.
       Uso: python3 postproc_monan2_standalone.py --allfields
            python3 postproc_monan2_standalone.py --allmaps --allfields

  [N3] Função discover_all_fields(): varre o primeiro arquivo MONAN_DIAG e
       retorna todas as variáveis com dimensão (Time, nCells), incluindo as
       que não constam em FIELD_META. Gera metadados genéricos sob demanda.

Correções v1.3 (20/04/2026):
  [S1] CRÍTICO: load_cap_fields — faltava .T antes de .flatten().
       O Fortran grava campo 2D como (NLON,NLAT)=(360,181); sem transposta,
       compare_fields comparava pontos geograficamente distintos ponto-a-ponto.
       Bias/RMSE/corr de TODOS os campos estavam matematicamente errados.
  [S2] compare_fields — __import__('datetime').timedelta → timedelta (já importado).
  [S3] FIELD_META e CAP_MAP — cap_field com nomes legados (Sa_tbot, Sa_pslv...)
       corrigidos para nomes _mpas (Sa_tbot_mpas, Sa_pslv_mpas...).
  [S4] plot_maps — máscara data>0 substituída por data>=norm.vmin para
       consistência com os limites da colorbar em campos log.

Correção v1.2 (13/04/2026):
  Bug voronoi_to_latlon: o algoritmo anterior usava binning simples (1 célula
  → 1 bin, índice lon via floor), enquanto o Fortran mpas_cap_netcdf.F90 usa
  spray adaptativo (1 célula → janela lat ±1 × lon ±nspan_lon, índice lon via
  nint/round). A diferença causava σ SA > σ cap para campos de fluxo (hfx, lh)
  e deslocamento de 0.5° em longitude. Corrigido: voronoi_to_latlon agora
  replica exatamente o spray adaptativo do Fortran (CELL_HALF_DEG=0.60,
  NSPAN_LAT=1, wrap periódico, round em lon).

Correção v1.1 (07/04/2026):
  Bug --compare: campos standalone estão na grade Voronoi (40962 células) e
  campos do cap NUOPC v2.5 estão na grade lat/lon 1°×1° (181×360 = 65160 pontos).
  A comparação direta causava ValueError por shapes incompatíveis (40962,) vs (65160,).
  Correção: voronoi_to_latlon() reprojecta o campo standalone para a grade lat/lon
  do cap antes de calcular bias/RMSE/correlação. Placeholder em load_cap_fields
  corrigido de nCells=40962 para CAP_NCELLS=65160.

Lê os arquivos MONAN_DIAG_G_MOD_GFS_*.nc gerados pelo SMIOL do MONAN-A 8.3
e produz estatísticas, CSVs e mapas para validação científica.

  Modos de operação:
    --stats    : estatísticas globais (min/max/média/std) por campo e por passo
    --csv      : exporta séries temporais em CSV
    --plot     : mapas cartopy para passos selecionados + série temporal
    --allmaps  : mapas cartopy para TODOS os passos (implica --plot)
    --allfields: descobre e processa TODOS os campos nos arquivos DIAG
    --compare  : compara com monan_export_*.nc do cap NUOPC
    --all      : equivalente a --stats --csv --plot (padrão)

  Exemplos:
    # Processamento padrão (stats + csv + plot 3 passos, campos FIELD_META)
    python3 postproc_monan2_standalone.py

    # Mapas para TODOS os 48 passos, campos padrão
    python3 postproc_monan2_standalone.py --allmaps

    # Mapas para TODOS os passos, TODOS os campos disponíveis nos DIAG
    python3 postproc_monan2_standalone.py --allmaps --allfields

    # Campos específicos em todos os passos
    python3 postproc_monan2_standalone.py --allmaps --field t2m acswdnb lh

    # Descobrir e listar todos os campos disponíveis nos DIAG (sem gerar mapas)
    python3 postproc_monan2_standalone.py --allfields --stats

    # Fluxo completo: stats + csv + todos os mapas + todos os campos
    python3 postproc_monan2_standalone.py --all --allmaps --allfields

    # Outros modos
    python3 postproc_monan2_standalone.py --stats
    python3 postproc_monan2_standalone.py --plot --step 1 24 48
    python3 postproc_monan2_standalone.py --compare --capdir diag_export/
    python3 postproc_monan2_standalone.py --initfile /caminho/x1.40962.init.nc

  Pré-requisitos:
    1. MONAN_DIAG_*.nc no diretório de trabalho (ou --diagdir)
    2. x1.40962.init.nc no mesmo diretório (ou --initfile) — para latCell/lonCell
    3. (para --compare) monan_export_*.nc em diag_export/ (ou --capdir)

  Dependências:
    module load cray-python
    pip install --user numpy netCDF4 matplotlib cartopy
"""

import sys
import os
import glob
import argparse
import csv
from datetime import datetime, timedelta

import numpy as np

try:
    from netCDF4 import Dataset
except ImportError:
    sys.exit("ERRO: netCDF4 não encontrado. Instalar: pip install --user netCDF4")

# ─── Grade lat/lon do cap NUOPC (mpas_cap_netcdf.F90 v2.5) ──────────────────
# Deve ser idêntico ao definido em mpas_cap_netcdf.F90:
#   NLON = 360  (-180° a +179°, passo 1°)
#   NLAT = 181  ( -90° a  +90°, passo 1°)
CAP_NLAT = 181
CAP_NLON = 360
CAP_NCELLS = CAP_NLAT * CAP_NLON   # 65160 — tamanho dos campos no monan_export_*.nc


def voronoi_to_latlon(data_v, lon_v, lat_v,
                      nlat=CAP_NLAT, nlon=CAP_NLON):
    """
    Reprojecta campo Voronoi (nCells,) → grade regular (nlat, nlon).

    Replica exatamente o algoritmo voronoi_to_latlon do Fortran em
    mpas_cap_netcdf.F90 v2.6:
      - Índices centrais via round/nint (ilon, ilat)
      - Spray adaptativo em longitude: nspan_lon = ceil(CELL_HALF_DEG /
        (max(cos(lat), 0.009) * DLON)) + 1, limitado a NLON/2
      - Spray fixo em latitude: NSPAN_LAT = 1
      - Wrap periódico em longitude (±180°)
      - Fill value: NaN nos bins sem contribuição

    Compatível com a saída de mpas_cap_netcdf.F90 v2.6
    (lat de -90° a +90°, lon de -180° a +179°, passo 1°).

    Parâmetros
    ----------
    data_v : np.ndarray (nCells,)   campo na grade Voronoi
    lon_v  : np.ndarray (nCells,)   longitudes em graus
    lat_v  : np.ndarray (nCells,)   latitudes  em graus

    Retorna
    -------
    np.ndarray (nlat, nlon) com NaN nos bins vazios.
    """
    # Parâmetros idênticos ao Fortran
    DLON         = 1.0
    DLAT         = 1.0
    NSPAN_LAT    = 1
    CELL_HALF_DEG = 0.60           # meia-largura da célula Voronoi em graus
    COS_LAT_MIN  = 0.009           # sin(0.5°) — evita nspan_lon → ∞ no polo
    FILL_VALUE   = np.nan

    grid  = np.full((nlat, nlon), FILL_VALUE, dtype=np.float64)
    acc   = np.zeros((nlat, nlon), dtype=np.float64)
    cnt   = np.zeros((nlat, nlon), dtype=np.int32)

    deg2rad = np.pi / 180.0

    for k in range(len(data_v)):
        val = data_v[k]
        if not np.isfinite(val):
            continue

        # Normalizar longitude para [-180, 180)
        lon_norm = lon_v[k]
        while lon_norm >= 180.0:
            lon_norm -= 360.0
        while lon_norm < -180.0:
            lon_norm += 360.0

        # Índices centrais (0-indexed, equivalente ao Fortran 1-indexed - 1)
        ilon_c = int(round((lon_norm + 180.0) / DLON))     # nint → round
        ilat_c = int(round((lat_v[k]  +  90.0) / DLAT))
        ilon_c = min(max(ilon_c, 0), nlon - 1)
        ilat_c = min(max(ilat_c, 0), nlat - 1)

        # Spray adaptativo em longitude (compensa convergência dos meridianos)
        cos_lat  = max(abs(np.cos(lat_v[k] * deg2rad)), COS_LAT_MIN)
        nspan_lon = min(int(CELL_HALF_DEG / (cos_lat * DLON)) + 1, nlon // 2)
        nspan_lon = max(nspan_lon, NSPAN_LAT)

        # Acumular em janela (2*NSPAN_LAT+1) × (2*nspan_lon+1)
        for dj in range(-NSPAN_LAT, NSPAN_LAT + 1):
            ilat2 = min(max(ilat_c + dj, 0), nlat - 1)
            for di in range(-nspan_lon, nspan_lon + 1):
                ilon2 = (ilon_c + di) % nlon   # wrap periódico
                acc[ilat2, ilon2] += val
                cnt[ilat2, ilon2] += 1

    mask = cnt > 0
    grid[mask] = acc[mask] / cnt[mask].astype(np.float64)
    return grid   # (nlat, nlon)


# ─── Metadados dos campos do MONAN_DIAG ──────────────────────────────────────
#
# acum=True  → campo acumulado desde t=0; derivar instantâneo = Δ/dt
# acum=False → campo instantâneo; usar diretamente
#
FIELD_META = {
    # Temperatura e umidade superficiais
    't2m':             {'long_name': 'Temperatura a 2 m',             'units': 'K',
                        'scale': 1.0,    'scale_units': 'K',      'acum': False,
                        'cmap': 'RdYlBu_r', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': 'Sa_tbot_mpas'},
    'q2':              {'long_name': 'Umidade específica a 2 m',      'units': 'kg/kg',
                        'scale': 1e3,   'scale_units': 'g/kg',   'acum': False,
                        'cmap': 'YlGnBu', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': 'Sa_shum_mpas'},  # Fase 2 — pool diag_physics%q2
    # Vento superficial
    'u10':             {'long_name': 'Vento zonal a 10 m',            'units': 'm/s',
                        'scale': 1.0,   'scale_units': 'm/s',    'acum': False,
                        'cmap': 'RdBu_r', 'norm': 'linear', 'vperc': [2, 98], 'sym': True,
                        'cap_field': 'Sa_u10m_mpas'},
    'v10':             {'long_name': 'Vento meridional a 10 m',       'units': 'm/s',
                        'scale': 1.0,   'scale_units': 'm/s',    'acum': False,
                        'cmap': 'RdBu_r', 'norm': 'linear', 'vperc': [2, 98], 'sym': True,
                        'cap_field': 'Sa_v10m_mpas'},
    # Pressão
    'mslp':            {'long_name': 'Pressão ao nível do mar',       'units': 'Pa',
                        'scale': 1e-2,  'scale_units': 'hPa',    'acum': False,
                        'cmap': 'RdBu_r', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': 'Sa_pslv_mpas'},
    'surface_pressure':{'long_name': 'Pressão superficial',           'units': 'Pa',
                        'scale': 1e-2,  'scale_units': 'hPa',    'acum': False,
                        'cmap': 'RdBu_r', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': None},
    # Fluxos superficiais (instantâneos)
    'hfx':             {'long_name': 'Fluxo calor sensível (sup.)',   'units': 'W/m²',
                        'scale': 1.0,   'scale_units': 'W/m²',   'acum': False,
                        'cmap': 'RdYlBu_r', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': None},  # bulk MED, nao no exportState MPAS
    'lh':              {'long_name': 'Fluxo calor latente',           'units': 'W/m²',
                        'scale': 1.0,   'scale_units': 'W/m²',   'acum': False,
                        'cmap': 'RdYlBu_r', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': None},  # bulk MED, nao no exportState MPAS
    # Radiação (acumulada — derivar instantâneo por Δ/dt)
    'acswdnb':         {'long_name': 'Rad. SW desc. sup. (acum.→inst.)', 'units': 'W/m²',
                        'scale': 1.0,   'scale_units': 'W/m²',   'acum': True,
                        'cmap': 'YlOrRd', 'norm': 'linear', 'vperc': [0, 99], 'sym': False,
                        'cap_field': 'Faxa_swdn_mpas'},
    'aclwupb':         {'long_name': 'Rad. LW up. sup. (acum.→inst.)', 'units': 'W/m²',
                        'scale': 1.0,   'scale_units': 'W/m²',   'acum': True,
                        'cmap': 'YlOrRd', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': None},
    # Precipitação (acumulada mm → taxa kg/m²/s)
    'rainnc':          {'long_name': 'Prec. grade acum. (→ mm/h)',    'units': 'mm',
                        'scale': 1.0,   'scale_units': 'mm/h',   'acum': True,
                        'cmap': 'GnBu',  'norm': 'log', 'vperc': [50, 99], 'sym': False,
                        'cap_field': None},
    'rainc':           {'long_name': 'Prec. convectiva acum. (→ mm/h)', 'units': 'mm',
                        'scale': 1.0,   'scale_units': 'mm/h',   'acum': True,
                        'cmap': 'GnBu',  'norm': 'log', 'vperc': [50, 99], 'sym': False,
                        'cap_field': None},
    'snownc':          {'long_name': 'Neve estratiforme acum. (→ mm/h)', 'units': 'mm',
                        'scale': 1.0,   'scale_units': 'mm/h',   'acum': True,
                        'cmap': 'Blues', 'norm': 'log', 'vperc': [50, 99], 'sym': False,
                        'cap_field': 'Faxa_snow_mpas'},  # Fase 2 — Δsnownc/dt [kg/m²/s]
    # Diagnósticos atmosféricos
    'cape':            {'long_name': 'CAPE',                          'units': 'J/kg',
                        'scale': 1.0,   'scale_units': 'J/kg',   'acum': False,
                        'cmap': 'YlOrRd', 'norm': 'linear', 'vperc': [0, 99], 'sym': False,
                        'cap_field': None},
    'precipw':         {'long_name': 'Água precipitável',             'units': 'kg/m²',
                        'scale': 1.0,   'scale_units': 'kg/m²',  'acum': False,
                        'cmap': 'YlGnBu', 'norm': 'linear', 'vperc': [2, 98], 'sym': False,
                        'cap_field': None},
}


def meta_for_unknown(fname):
    """
    Gera metadados genéricos para campos não catalogados em FIELD_META.

    Aplica heurísticas baseadas no nome do campo para escolher cmap e escala:
      - Campos de temperatura/pressão: RdYlBu_r
      - Campos de fluxo/radiação: YlOrRd
      - Campos de vento: RdBu_r (simétrico)
      - Campos de precipitação/umidade: GnBu
      - Demais: viridis
    """
    fname_lower = fname.lower()

    # Heurística de colormap/simetria baseada no nome
    if any(k in fname_lower for k in ('t2', 'temp', 'theta', 'tsk', 'tsfc', 'tslb')):
        cmap, sym = 'RdYlBu_r', False
    elif any(k in fname_lower for k in ('pres', 'psfc', 'slp', 'mslp', 'p_')):
        cmap, sym = 'RdBu_r', False
    elif any(k in fname_lower for k in ('u10', 'v10', 'u_', 'v_', 'umet', 'vmet', 'wind')):
        cmap, sym = 'RdBu_r', True
    elif any(k in fname_lower for k in ('sw', 'lw', 'rad', 'flux', 'hfx', 'qfx', 'lh')):
        cmap, sym = 'YlOrRd', False
    elif any(k in fname_lower for k in ('rain', 'prec', 'snow', 'q2', 'qvapor', 'hum')):
        cmap, sym = 'GnBu', False
    else:
        cmap, sym = 'viridis', False

    # Escala log para campos de precipitação
    norm = 'log' if any(k in fname_lower for k in ('rain', 'snow', 'prec')) else 'linear'
    vperc = [50, 99] if norm == 'log' else [2, 98]

    return {
        'long_name':   fname,          # usar o nome bruto como rótulo
        'units':       '?',
        'scale':       1.0,
        'scale_units': '?',
        'acum':        False,          # tratar como instantâneo por padrão
        'cmap':        cmap,
        'norm':        norm,
        'vperc':       vperc,
        'sym':         sym,
        'cap_field':   None,
        '_auto':       True,           # flag: metadados gerados automaticamente
    }


def discover_all_fields(files):
    """
    Varre o primeiro arquivo MONAN_DIAG e retorna TODOS os nomes de variáveis
    com dimensão (Time, nCells) — incluindo os que não estão em FIELD_META.

    Retorna
    -------
    tuple (all_fields, known_fields, new_fields) onde:
      all_fields   : list[str]  todos os campos com dim (Time, nCells)
      known_fields : list[str]  campos presentes em FIELD_META
      new_fields   : list[str]  campos ausentes de FIELD_META (recebem meta_for_unknown)
    """
    all_fields = []
    with Dataset(files[0]) as nc:
        for vname, var in nc.variables.items():
            # Aceitar dim (Time, nCells) ou (Time, nCells) com qualquer nCells
            if (len(var.dimensions) == 2
                    and var.dimensions[0] == 'Time'
                    and 'nCells' in var.dimensions[1]):
                all_fields.append(vname)

    # Excluir variáveis de coordenada que possam ter essa dimensão
    _coord_vars = {'latCell', 'lonCell', 'xCell', 'yCell', 'zCell',
                   'areaCell', 'indexToCellID'}
    all_fields = [f for f in all_fields if f not in _coord_vars]

    known_fields = [f for f in all_fields if f in FIELD_META]
    new_fields   = [f for f in all_fields if f not in FIELD_META]

    return all_fields, known_fields, new_fields


# ─── Utilitários ─────────────────────────────────────────────────────────────

def find_diag_files(diagdir):
    """Encontra e ordena arquivos MONAN_DIAG_*.nc pelo campo Time (CF)."""
    pattern = os.path.join(diagdir, 'MONAN_DIAG_*.nc')
    files = sorted(glob.glob(pattern))
    if not files:
        sys.exit(f"ERRO: nenhum arquivo MONAN_DIAG_*.nc em '{diagdir}'")

    # Ordenar pelo valor de Time (segundos CF) dentro de cada arquivo
    def get_time(path):
        try:
            with Dataset(path) as nc:
                return float(nc.variables['Time'][0])
        except Exception:
            return 0.0

    files.sort(key=get_time)
    return files


def load_coords(initfile):
    """
    Carrega latCell e lonCell do x1.NNNNN.init.nc (em radianos) e converte
    para graus. latCell/lonCell não estão no MONAN_DIAG.
    """
    if not os.path.isfile(initfile):
        sys.exit(
            f"ERRO: arquivo de coordenadas não encontrado: '{initfile}'\n"
            f"       Especificar com --initfile /caminho/x1.40962.init.nc"
        )
    with Dataset(initfile) as nc:
        if 'latCell' not in nc.variables:
            sys.exit(f"ERRO: 'latCell' não encontrado em '{initfile}'")
        lat = np.degrees(nc.variables['latCell'][:])
        lon = np.degrees(nc.variables['lonCell'][:])
    lon = np.where(lon > 180, lon - 360, lon)   # normaliza para [-180, 180)
    print(f"  Coordenadas carregadas: {len(lat):,} células | "
          f"lat [{lat.min():.1f}, {lat.max():.1f}] | "
          f"lon [{lon.min():.1f}, {lon.max():.1f}]")
    return lon, lat


def get_time_from_file(path):
    """
    Retorna (datetime, float_seconds) do campo Time CF do arquivo.
    Time:units = "seconds since YYYY-MM-DD HH:MM:SS"
    """
    with Dataset(path) as nc:
        t_var = nc.variables['Time']
        t_val = float(t_var[0])
        # Parsear "seconds since YYYY-MM-DD HH:MM:SS"
        units_str = t_var.units  # ex: "seconds since 2026-03-29 00:00:00"
        since_str = units_str.replace('seconds since ', '').strip()
        since_dt  = datetime.strptime(since_str, '%Y-%m-%d %H:%M:%S')
        valid_dt  = since_dt + timedelta(seconds=t_val)
    return valid_dt, t_val


def detect_available_fields(files, requested):
    """
    Verifica quais campos de 'requested' estão presentes no primeiro arquivo.
    Retorna lista dos disponíveis e avisa sobre ausentes.

    Campos em 'requested' que não constam em FIELD_META são aceitos desde que
    estejam no arquivo — receberão metadados genéricos via meta_for_unknown().
    """
    with Dataset(files[0]) as nc:
        present = set(nc.variables.keys())
    available = [f for f in requested if f in present]
    missing   = [f for f in requested if f not in present]
    if missing:
        print(f"  AVISO: campos não encontrados no arquivo: {missing}")

    # Registrar metadados automáticos para campos desconhecidos que foram
    # encontrados — evita KeyError em load_all_steps, print_stats, etc.
    for fname in available:
        if fname not in FIELD_META:
            FIELD_META[fname] = meta_for_unknown(fname)

    return available


def derive_instantaneous(data_now, data_prev, dt_s, meta):
    """
    Converte campo acumulado em instantâneo.
    - Radiação (W/m²): Δacum / dt → já em W/m² (unidade do arquivo é incorreta,
      mas a operação Δ/dt é correta pois a integral da média em W/m² por dt segundos
      resulta em W·s/m² ≡ J/m²; portanto Δ/dt → W/m²)
    - Precipitação (mm acum): Δmm/dt → mm/s → × 1000/1000 = mm/h (× 3600/dt)
    Valores negativos (erro numérico de acumulação) são zerados.
    """
    delta = data_now - data_prev
    delta = np.where(delta < 0, 0.0, delta)  # acumulado nunca decresce
    inst  = delta / dt_s                      # → por segundo

    if meta.get('scale_units') in ('mm/h',):
        inst = inst * 3600.0                  # mm/s → mm/h

    return inst


def load_all_steps(files, field_names):
    """
    Carrega todos os passos. Campos acumulados são derivados para instantâneos.
    Retorna:
      timestamps : list[datetime]
      elapsed_s  : np.ndarray (nsteps,)
      fields     : dict {name: np.ndarray (nsteps, nCells)}
      dt_s_arr   : np.ndarray (nsteps,) — dt em segundos por passo
    """
    print(f"  Carregando {len(files)} arquivos...")
    timestamps = []
    elapsed_s  = []
    raw        = {f: [] for f in field_names}   # dados brutos (acumulados incluídos)

    for path in files:
        dt_obj, t_s = get_time_from_file(path)
        timestamps.append(dt_obj)
        elapsed_s.append(t_s)
        with Dataset(path) as nc:
            for fname in field_names:
                if fname in nc.variables:
                    raw[fname].append(nc.variables[fname][0, :].data.astype(np.float64))
                else:
                    # Campo ausente neste passo: determinar nCells pelo primeiro campo
                    # com dimensão (Time, nCells) encontrado no arquivo.
                    try:
                        nCells = next(
                            len(nc.variables[k][0]) for k in nc.variables
                            if nc.variables[k].dimensions == ('Time', 'nCells')
                        )
                    except StopIteration:
                        sys.exit(
                            f"ERRO: nenhuma variável (Time, nCells) encontrada em '{path}'.\n"
                            "       Verificar se o arquivo é um MONAN_DIAG válido."
                        )
                    raw[fname].append(np.full(nCells, np.nan))

    elapsed_s = np.array(elapsed_s)

    # Calcular dt por passo (s) — passo 0 usa dt do passo 1 (sem passo anterior)
    dt_s_arr = np.zeros(len(files))
    if len(files) > 1:
        dt_s_arr[1:] = np.diff(elapsed_s)
        dt_s_arr[0]  = dt_s_arr[1]
    else:
        dt_s_arr[0]  = 1800.0   # default 30 min

    # Montar arrays e derivar acumulados
    fields = {}
    for fname in field_names:
        stack = np.stack(raw[fname], axis=0)   # (nsteps, nCells)
        meta  = FIELD_META.get(fname, {})
        if meta.get('acum', False):
            inst = np.full_like(stack, np.nan)
            inst[0] = stack[0] / max(dt_s_arr[0], 1.0)  # passo 0: acum desde t=0 / dt
            for i in range(1, len(files)):
                dt = max(dt_s_arr[i], 1.0)
                inst[i] = derive_instantaneous(stack[i], stack[i-1], dt, meta)
            fields[fname] = inst
        else:
            fields[fname] = stack * meta.get('scale', 1.0)

    nCells = next(iter(fields.values())).shape[1]
    print(f"  {len(field_names)} campos × {len(files)} passos × {nCells:,} células carregados.")
    return timestamps, elapsed_s, fields, dt_s_arr


# ─── Modo --stats ─────────────────────────────────────────────────────────────

def print_stats(timestamps, fields, field_names):
    sep = '─' * 88
    print()
    print('╔' + '═' * 86 + '╗')
    print('║{:^86}║'.format('ESTATÍSTICAS — MONAN-A STANDALONE (MONAN_DIAG)'))
    print('╚' + '═' * 86 + '╝')

    for fname in field_names:
        if fname not in fields:
            continue
        meta  = FIELD_META.get(fname, {'long_name': fname, 'scale_units': '?'})
        data  = fields[fname]
        units = meta['scale_units']

        print()
        print(f"  ┌─ {fname}  —  {meta['long_name']}  [{units}]"
              + ("  [acumulado→inst.]" if meta.get('acum') else ""))
        print(f"  │  {'Passo':>5}  {'Data/hora':^20}  {'Mínimo':>12}  {'Máximo':>12}  "
              f"{'Média':>12}  {'DesvPad':>10}")
        print(f"  │  {sep[:75]}")

        for i, ts in enumerate(timestamps):
            row = data[i, :]
            v   = row[np.isfinite(row)]
            if len(v) == 0:
                continue
            if meta.get('norm') == 'log':
                v = v[v > 0]
            if len(v) == 0:
                continue
            print(f"  │  {i+1:>5}  {ts.strftime('%Y-%m-%d %H:%M'):^20}"
                  f"  {v.min():>12.4f}  {v.max():>12.4f}"
                  f"  {v.mean():>12.4f}  {v.std():>10.4f}")

        all_v = data[np.isfinite(data)]
        if meta.get('norm') == 'log':
            all_v = all_v[all_v > 0]
        print(f"  │  {sep[:75]}")
        if len(all_v):
            print(f"  │  {'SÉRIE':>5}  {'(todos os passos)':^20}"
                  f"  {all_v.min():>12.4f}  {all_v.max():>12.4f}"
                  f"  {all_v.mean():>12.4f}  {all_v.std():>10.4f}")
        print(f"  └{'─' * 76}")
    print()


# ─── Modo --csv ───────────────────────────────────────────────────────────────

def export_csv(timestamps, elapsed_s, fields, field_names, outdir):
    os.makedirs(outdir, exist_ok=True)

    # CSV consolidado (uma linha por passo, todos os campos)
    available = [f for f in field_names if f in fields]
    csvfile   = os.path.join(outdir, 'monan_standalone_stats.csv')
    header    = ['passo', 'timestamp', 'elapsed_s']
    for f in available:
        for stat in ('min', 'max', 'mean', 'std'):
            header.append(f'{f}_{stat}')

    with open(csvfile, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for i, ts in enumerate(timestamps):
            row = [i + 1, ts.strftime('%Y-%m-%dT%H:%M:%S'), elapsed_s[i]]
            for f in available:
                meta = FIELD_META.get(f, {})
                d    = fields[f][i, :]
                d    = d[np.isfinite(d)]
                if meta.get('norm') == 'log':
                    d = d[d > 0]
                if len(d):
                    row += [d.min(), d.max(), d.mean(), d.std()]
                else:
                    row += [np.nan, np.nan, np.nan, np.nan]
            w.writerow(row)

    print(f"  CSV consolidado : {csvfile}")

    # CSV por campo (série temporal de estatísticas globais)
    for fname in available:
        meta  = FIELD_META.get(fname, {'scale_units': '?'})
        units = meta['scale_units']
        csvf  = os.path.join(outdir, f'monan_standalone_ts_{fname}.csv')
        with open(csvf, 'w', newline='', encoding='utf-8') as fh:
            w = csv.writer(fh)
            w.writerow(['passo', 'timestamp', 'elapsed_s',
                        f'min_{units}', f'max_{units}', f'mean_{units}', f'std_{units}'])
            for i, ts in enumerate(timestamps):
                d = fields[fname][i, :]
                d = d[np.isfinite(d)]
                if meta.get('norm') == 'log':
                    d = d[d > 0]
                if len(d):
                    w.writerow([i + 1, ts.strftime('%Y-%m-%dT%H:%M:%S'), elapsed_s[i],
                                d.min(), d.max(), d.mean(), d.std()])
        print(f"  CSV série       : {csvf}")


# ─── Modo --plot ──────────────────────────────────────────────────────────────

def _get_plot_norm(fname, data):
    """Retorna (cmap, norm, vmin, vmax, extend) para o campo."""
    import matplotlib.colors as mcolors

    meta      = FIELD_META.get(fname, {})
    cmap      = meta.get('cmap', 'viridis')
    norm_type = meta.get('norm', 'linear')
    vperc     = meta.get('vperc', [2, 98])
    sym       = meta.get('sym', False)

    valid = data[np.isfinite(data)]

    if norm_type == 'log':
        pos  = valid[valid > 0]
        if len(pos) == 0:
            return cmap, None, 0, 1, 'neither'
        vmin = max(np.percentile(pos, max(vperc[0], 1)), 1e-4)
        vmax = np.percentile(pos, vperc[1])
        if vmax <= vmin:
            vmax = vmin * 100
        norm = mcolors.LogNorm(vmin=vmin, vmax=vmax)
        return cmap, norm, vmin, vmax, 'max'

    vmin, vmax = np.nanpercentile(valid, [vperc[0], vperc[1]])
    if sym:
        absmax = max(abs(vmin), abs(vmax))
        vmin, vmax = -absmax, absmax
    return cmap, None, vmin, vmax, 'both'


def _probe_natural_earth():
    """Verifica se os shapefiles Natural Earth 110m estão em cache."""
    try:
        import cartopy.io.shapereader as shpreader
        for cat, name in [
            ('physical', 'coastline'), ('physical', 'land'),
            ('physical', 'ocean'), ('cultural', 'admin_0_boundary_lines_land'),
        ]:
            path = shpreader.natural_earth(resolution='110m',
                                           category=cat, name=name)
            if not os.path.isfile(path):
                return False
        return True
    except Exception:
        return False


def _draw_cartopy_background(fig, pos, has_features):
    import cartopy.crs     as ccrs
    import cartopy.feature as cfeature

    proj = ccrs.PlateCarree()
    ax   = fig.add_subplot(pos, projection=proj)
    ax.set_global()

    if has_features:
        res = '110m'
        ax.add_feature(cfeature.NaturalEarthFeature(
            'physical', 'ocean', res, facecolor='#daeef3', edgecolor='none'), zorder=0)
        ax.add_feature(cfeature.NaturalEarthFeature(
            'physical', 'land',  res, facecolor='#f5f0e8', edgecolor='none'), zorder=1)
    else:
        ax.set_facecolor('#daeef3')

    return ax, proj


def _add_cartopy_overlay(ax, has_features):
    import cartopy.feature as cfeature

    if has_features:
        res = '110m'
        ax.add_feature(cfeature.NaturalEarthFeature(
            'physical', 'coastline', res,
            facecolor='none', edgecolor='#222222', linewidth=0.7), zorder=10)
        ax.add_feature(cfeature.NaturalEarthFeature(
            'cultural', 'admin_0_boundary_lines_land', res,
            facecolor='none', edgecolor='#555555',
            linewidth=0.35, linestyle='--'), zorder=10)

    gl = ax.gridlines(draw_labels=True, linewidth=0.4,
                      color='gray', alpha=0.6, linestyle='--', zorder=11)
    gl.top_labels   = False
    gl.right_labels = False
    gl.xlabel_style = {'size': 7}
    gl.ylabel_style = {'size': 7}


def plot_maps(timestamps, fields, field_names, lon, lat, step_indices, outdir,
              show_progress=False):
    """
    Mapas cartopy (scatter) para os campos e passos selecionados.

    Parâmetros
    ----------
    timestamps    : list[datetime]
    fields        : dict {nome: np.ndarray (nsteps, nCells)}
    field_names   : lista de campos a plotar
    lon, lat      : coordenadas Voronoi em graus (nCells,)
    step_indices  : lista de índices (base 0) dos passos a plotar
    outdir        : diretório de saída
    show_progress : se True, exibe barra de progresso simples (útil para --allmaps)
    """
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  AVISO: matplotlib não encontrado — ignorando --plot.")
        return

    try:
        import cartopy.crs as ccrs
        HAS_CARTOPY = True
    except ImportError:
        HAS_CARTOPY = False

    if HAS_CARTOPY:
        print("  Verificando dados Natural Earth 110m...", end=' ', flush=True)
        HAS_FEATURES = _probe_natural_earth()
        print("OK." if HAS_FEATURES else "indisponível — mapa com grade apenas.")
    else:
        HAS_FEATURES = False

    os.makedirs(outdir, exist_ok=True)

    # s=25 → cobertura completa para x1.40962 em figura 14×7 pol a 130 DPI
    PT_SIZE = 25

    n_total   = len([f for f in field_names if f in fields]) * len(step_indices)
    n_done    = 0

    for fname in field_names:
        if fname not in fields:
            continue
        meta = FIELD_META.get(fname, {'long_name': fname,
                                       'scale_units': '?', 'acum': False})
        # Indicador visual para campos com metadados automáticos
        auto_tag = '  [meta auto]' if meta.get('_auto') else ''

        for step_i in step_indices:
            if step_i >= len(timestamps):
                continue
            ts   = timestamps[step_i]
            data = fields[fname][step_i, :]
            cmap, norm, vmin, vmax, extend = _get_plot_norm(fname, data)

            # FIX S4: preservar zeros em campos lineares; para log, usar vmin
            if norm is not None and hasattr(norm, 'vmin'):
                data_plot = np.where(data >= norm.vmin, data, np.nan)
            else:
                data_plot = data

            fig = plt.figure(figsize=(14, 7))

            if HAS_CARTOPY:
                ax, proj = _draw_cartopy_background(fig, 111, HAS_FEATURES)
                sc = ax.scatter(
                    lon, lat, c=data_plot,
                    s=PT_SIZE, marker='.', linewidths=0,
                    cmap=cmap, norm=norm,
                    vmin=(vmin if norm is None else None),
                    vmax=(vmax if norm is None else None),
                    transform=proj, zorder=5)
                _add_cartopy_overlay(ax, HAS_FEATURES)
            else:
                ax = fig.add_subplot(111)
                sc = ax.scatter(lon, lat, c=data_plot,
                                s=PT_SIZE, linewidths=0,
                                cmap=cmap, norm=norm,
                                vmin=(vmin if norm is None else None),
                                vmax=(vmax if norm is None else None))
                ax.set_xlabel('Longitude (°)')
                ax.set_ylabel('Latitude (°)')
                ax.set_xlim(-180, 180)
                ax.set_ylim(-90, 90)
                ax.grid(True, alpha=0.4, zorder=10)

            cb = fig.colorbar(sc, ax=ax, shrink=0.7, pad=0.02, extend=extend)
            cb.set_label(meta['scale_units'], fontsize=10)

            valid = data[np.isfinite(data)]
            pos   = valid[valid > 0] if meta.get('norm') == 'log' else valid
            n_str = (f"mín={np.nanmin(data):.3g}  máx={np.nanmax(data):.3g}"
                     f"  média={np.nanmean(pos):.3g} {meta['scale_units']}"
                     if len(pos) else "sem dados")
            acum_tag = "  [acum→inst.]" if meta.get('acum') else ""
            ax.set_title(
                f"{fname}  —  {meta['long_name']}{acum_tag}{auto_tag}\n"
                f"Passo {step_i+1}  |  {ts.strftime('%Y-%m-%d %H:%M UTC')}  |  {n_str}",
                fontsize=11, pad=10)

            fig.text(0.01, 0.01,
                     'MONAN-A 2.0 Standalone — INPE/CGCT/DIMNT',
                     fontsize=7, color='gray')

            outfile = os.path.join(outdir, f'standalone_{fname}_passo{step_i+1:02d}.png')
            fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
            plt.close(fig)

            n_done += 1
            if show_progress:
                pct = 100 * n_done / max(n_total, 1)
                print(f"  [{n_done:>4}/{n_total}  {pct:5.1f}%]  {outfile}")
            else:
                print(f"  Figura: {outfile}")


def plot_timeseries(timestamps, fields, field_names, outdir):
    """Painel com séries temporais de médias globais."""
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

    n     = len(available)
    ncols = 2
    nrows = (n + 1) // 2
    fig, axes = plt.subplots(nrows, ncols, figsize=(14, 3.5 * nrows),
                             sharex=True, constrained_layout=True)
    axes = np.array(axes).flatten()

    for ax, fname in zip(axes, available):
        meta  = FIELD_META.get(fname, {'long_name': fname, 'scale_units': '?'})
        data  = fields[fname]
        means = np.nanmean(data, axis=1)
        mins  = np.nanmin(data,  axis=1)
        maxs  = np.nanmax(data,  axis=1)

        ax.fill_between(timestamps, mins, maxs,
                        alpha=0.18, color='steelblue', label='min–máx global')
        ax.plot(timestamps, means, lw=1.8, color='steelblue', label='média global')
        ax.xaxis.set_major_formatter(mdates.DateFormatter('%d/%m\n%H:%M'))
        ax.xaxis.set_major_locator(mdates.HourLocator(interval=6))
        acum_tag = ' [acum→inst.]' if meta.get('acum') else ''
        ax.set_ylabel(meta['scale_units'], fontsize=9)
        ax.set_title(f"{fname}  —  {meta['long_name']}{acum_tag}", fontsize=9)
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8, loc='upper right')

    for ax in axes[len(available):]:
        ax.set_visible(False)

    fig.suptitle(
        f"MONAN-A 2.0 Standalone — Séries Temporais\n"
        f"{timestamps[0].strftime('%Y-%m-%d %H:%M')} → "
        f"{timestamps[-1].strftime('%Y-%m-%d %H:%M')}  |  "
        f"x1.40962 (~120 km)  |  INPE/CGCT/DIMNT",
        fontsize=11)

    outfile = os.path.join(outdir, 'standalone_timeseries.png')
    fig.savefig(outfile, dpi=130, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print(f"  Série temporal: {outfile}")


# ─── Modo --compare ───────────────────────────────────────────────────────────

# Mapeamento standalone → cap NUOPC
#
# IMPORTANTE: o cap NUOPC (mpas_cap.F90) renomeia os campos com sufixo _mpas
# para distinguir a fonte MPAS do DATM. Os nomes nos arquivos monan_export_*.nc
# sao os nomes do exportState ESMF, que incluem o sufixo.
#
# Faxa_shflx e Faxa_lhflx sao calculados pelo MED_cap (formula bulk NCAR) e
# NAO estao no exportState do MPAS cap — portanto nao estao nos NetCDF.
# Para compara-los seria necessario escrever o MED exportState separadamente.
CAP_MAP = {
    # Derivado de FIELD_META: mantido sincronizado automaticamente.
    # Contém apenas campos com cap_field != None (disponíveis no exportState MPAS).
    f_sa: meta['cap_field']
    for f_sa, meta in FIELD_META.items()
    if meta.get('cap_field') is not None
}
# CAP_MAP resultante (campos com cap_field mapeado):
#   t2m       → Sa_tbot_mpas
#   u10       → Sa_u10m_mpas
#   v10       → Sa_v10m_mpas
#   mslp      → Sa_pslv_mpas
#   acswdnb   → Faxa_swdn_mpas
#   q2        → Sa_shum_mpas    (Fase 2 — requer bl_mynn_in ou bl_ysu_in)
#   snownc    → Faxa_snow_mpas  (Fase 2 — requer mp_thompson_in ou mp_wsm6_in)
# Campos bulk MED (lh, hfx) e diagnósticos sem cap_field ficam excluídos.


def load_cap_fields(capdir, field_names_cap):
    """
    Carrega campos do cap NUOPC de monan_export_*.nc.

    Os arquivos v2.5 têm campos em grade lat/lon 1°×1° (181×360 = 65160 pontos),
    não na grade Voronoi. O argumento nCells foi removido — o tamanho correto
    é CAP_NCELLS = CAP_NLAT × CAP_NLON.

    Retorna dict {campo_cap: np.ndarray (nsteps, CAP_NCELLS)}, timestamps_cap.
    """
    pattern   = os.path.join(capdir, 'monan_export_????????_??????.nc')
    cap_files = sorted(glob.glob(pattern))
    if not cap_files:
        sys.exit(f"ERRO: nenhum monan_export_*.nc em '{capdir}'")

    timestamps = []
    raw = {f: [] for f in field_names_cap}

    for path in cap_files:
        with Dataset(path) as nc:
            # Parsear timestamp do nome do arquivo
            base   = os.path.basename(path)           # monan_export_YYYYMMDD_HHMMSS.nc
            ts_str = base[len('monan_export_'):-3]    # YYYYMMDD_HHMMSS
            ts_dt  = datetime.strptime(ts_str, '%Y%m%d_%H%M%S')
            timestamps.append(ts_dt)
            for fname in field_names_cap:
                # Tentar nome exato; se ausente, tentar variante sem sufixo _mpas
                # (para compatibilidade com arquivos de runs anteriores)
                found_name = fname
                if fname not in nc.variables:
                    alt = fname.replace('_mpas', '')
                    if alt in nc.variables:
                        found_name = alt
                if found_name in nc.variables:
                    # BUG FIX S1: o Fortran grava campo 2D com dims [dimid_lon, dimid_lat],
                    # resultando em shape (NLON, NLAT) = (360, 181) ao leitura em Python.
                    # voronoi_to_latlon retorna (NLAT, NLON) = (181, 360) em ordem lat-maior.
                    # Sem .T, flatten() produz ord. lon-maior → mismatch espacial ponto-a-ponto
                    # em compare_fields: cap_flat[i] ≠ sa_flat[i] exceto no índice 0.
                    # A transposta alinha ambos para lat-maior antes de flatten. Corr/RMSE/bias
                    # eram calculados entre pontos geograficamente distintos.
                    _arr = nc.variables[found_name][:]
                    _dims = nc.variables[found_name].dimensions
                    if len(_dims) == 2 and _dims[0] == 'lon' and _dims[1] == 'lat':
                        _arr = _arr.T   # (NLON,NLAT) → (NLAT,NLON): alinha com voronoi_to_latlon
                    raw[fname].append(_arr.flatten().astype(np.float64))
                else:
                    # campo ausente: placeholder NaN (detectado e pulado no compare)
                    raw[fname].append(np.full(CAP_NCELLS, np.nan))

    fields_cap = {f: np.stack(raw[f], axis=0) for f in field_names_cap}
    return timestamps, fields_cap


def compare_fields(timestamps_sa, fields_sa, timestamps_cap, fields_cap,
                   field_pairs, lon, lat, outdir):
    """
    Compara campos standalone vs cap: calcula bias, RMSE e correlação global.

    Os campos standalone estão na grade Voronoi (nCells,); os campos do cap
    estão na grade lat/lon 1°×1° (CAP_NLAT × CAP_NLON = CAP_NCELLS,).
    A comparação é feita reprojetando o campo standalone para a mesma grade
    lat/lon via voronoi_to_latlon() antes de calcular as métricas.

    field_pairs: list de (campo_standalone, campo_cap)
    lon, lat   : coordenadas Voronoi em graus, shape (nCells,)
    """
    import csv

    os.makedirs(outdir, exist_ok=True)

    # Mapear timestamps para índices coincidentes
    ts_sa_set  = {ts: i for i, ts in enumerate(timestamps_sa)}
    ts_cap_set = {ts: i for i, ts in enumerate(timestamps_cap)}
    common     = sorted(set(timestamps_sa) & set(timestamps_cap))

    if not common:
        print("  AVISO: nenhum timestamp em comum entre standalone e cap.")
        return

    print(f"  {len(common)} passos em comum para comparação.")
    print(f"  Grade standalone : Voronoi {next(iter(fields_sa.values())).shape[1]:,} células")
    print(f"  Grade cap NUOPC  : lat/lon {CAP_NLAT}×{CAP_NLON} = {CAP_NCELLS:,} pontos")
    print(f"  Método           : voronoi_to_latlon (binning 1°×1°) antes de comparar")

    csvfile = os.path.join(outdir, 'comparacao_standalone_cap.csv')
    with open(csvfile, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['passo', 'timestamp',
                    'campo_standalone', 'campo_cap',
                    'n_bins_validos',
                    'bias_global', 'rmse_global', 'corr_global',
                    'std_standalone', 'std_cap'])

        # Detectar dt de acoplamento do cap (s) a partir dos timestamps
        if len(timestamps_cap) > 1:
            dt_cap_s = (timestamps_cap[1] - timestamps_cap[0]).total_seconds()
        else:
            dt_cap_s = 1800.0

        # Detectar dt do standalone (s)
        if len(timestamps_sa) > 1:
            dt_sa_s = (timestamps_sa[1] - timestamps_sa[0]).total_seconds()
        else:
            dt_sa_s = 10800.0

        # Número de passos cap a agregar para cobrir o intervalo do standalone
        n_agg = max(1, round(dt_sa_s / dt_cap_s))

        print(f"  dt standalone    : {dt_sa_s/3600:.1f}h | dt cap: {dt_cap_s/3600:.1f}h | agregação: {n_agg} passo(s) cap por step standalone")

        for step_num, ts in enumerate(common, 1):
            i_sa  = ts_sa_set[ts]
            i_cap = ts_cap_set[ts]

            for f_sa, f_cap in field_pairs:
                if f_sa not in fields_sa or f_cap not in fields_cap:
                    continue

                d_sa_v = fields_sa[f_sa][i_sa, :]        # (nCells,)  — Voronoi

                # Para campos acumulados (acum=True), a comparação correta requer
                # que o cap seja agregado no mesmo intervalo temporal do standalone.
                # Ex.: standalone dt=3h, cap dt=1h → agregar 3 passos cap.
                # Isso garante que ambos representem a MESMA janela temporal.
                meta_sa = FIELD_META.get(f_sa, {})
                if meta_sa.get('acum', False) and n_agg > 1:
                    # Média dos n_agg passos cap que cobrem (ts - dt_sa, ts]
                    cap_indices = [j for j in range(len(timestamps_cap))
                                   if timestamps_cap[j] <= ts and
                                   timestamps_cap[j] > ts - timedelta(seconds=dt_sa_s)]   # timedelta: importado no topo
                    if cap_indices:
                        d_cap = np.mean(fields_cap[f_cap][cap_indices, :], axis=0)
                    else:
                        d_cap = fields_cap[f_cap][i_cap, :]
                else:
                    d_cap  = fields_cap[f_cap][i_cap, :]     # (CAP_NCELLS,) — lat/lon

                # Reprojetar standalone Voronoi → grade lat/lon 1°×1° do cap
                d_sa_grid = voronoi_to_latlon(d_sa_v, lon, lat)   # (CAP_NLAT, CAP_NLON)
                d_sa_flat = d_sa_grid.flatten()                    # (CAP_NCELLS,)

                # Normalizar d_cap para as mesmas unidades que d_sa.
                # fields_sa tem scale já aplicado em load_all_steps();
                # fields_cap é carregado em unidades brutas do arquivo.
                scale      = FIELD_META.get(f_sa, {}).get('scale', 1.0)
                d_cap_norm = d_cap * scale

                # Filtrar: NaN/Inf do standalone (voronoi_to_latlon usa NaN)
                # E FILL_VALUE do cap (-9.99e33) que e finito mas invalido
                CAP_FILL_THR = 1.0e30   # qualquer |valor| > 1e30 e fill value
                mask = (np.isfinite(d_sa_flat) & np.isfinite(d_cap_norm)
                        & (np.abs(d_sa_flat) < CAP_FILL_THR)
                        & (np.abs(d_cap_norm) < CAP_FILL_THR))
                n_valid = mask.sum()
                if n_valid < 10:
                    print(f"  AVISO: {f_sa}/{f_cap} passo {step_num} — "
                          f"apenas {n_valid} bins válidos, pulando.")
                    continue

                diff = d_sa_flat[mask] - d_cap_norm[mask]
                bias = np.mean(diff)
                rmse = np.sqrt(np.mean(diff ** 2))
                std_sa  = np.std(d_sa_flat[mask])
                std_cap = np.std(d_cap_norm[mask])
                if std_sa > 0 and std_cap > 0:
                    corr = float(np.corrcoef(d_sa_flat[mask],
                                             d_cap_norm[mask])[0, 1])
                else:
                    corr = np.nan

                w.writerow([step_num, ts.strftime('%Y-%m-%dT%H:%M:%S'),
                            f_sa, f_cap, n_valid,
                            f'{bias:.4f}', f'{rmse:.4f}', f'{corr:.4f}',
                            f'{std_sa:.4f}', f'{std_cap:.4f}'])

    print(f"  Comparação CSV  : {csvfile}")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Pós-processamento do MONAN-A 2.0 Standalone (MONAN_DIAG_*.nc).',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    # ── Caminhos ──────────────────────────────────────────────────────────────
    parser.add_argument('--diagdir',  default='.',
                        help='Diretório com MONAN_DIAG_*.nc  (padrão: .)')
    parser.add_argument('--initfile', default='x1.40962.init.nc',
                        help='Arquivo init.nc com latCell/lonCell  (padrão: x1.40962.init.nc)')
    parser.add_argument('--outdir',   default='diag_export/postproc',
                        help='Diretório de saída  (padrão: diag_export/postproc/)')
    parser.add_argument('--capdir',   default='diag_export',
                        help='Diretório com monan_export_*.nc para --compare  (padrão: diag_export/)')

    # ── Seleção de campos e passos ────────────────────────────────────────────
    parser.add_argument('--field', nargs='+', default=None,
                        help=(
                            'Campos a processar (padrão: todos em FIELD_META). '
                            'Use --allfields para descobrir campos extras nos DIAG. '
                            'Exemplos: --field t2m lh acswdnb'))
    parser.add_argument('--step',  nargs='+', type=int, default=None,
                        help='Passos a plotar em --plot, base 1  (padrão: 1, meio, último)')

    # ── Modos de operação ──────────────────────────────────────────────────────
    parser.add_argument('--stats',   action='store_true',
                        help='Estatísticas globais (min/max/média/std) por campo e passo')
    parser.add_argument('--csv',     action='store_true',
                        help='Exporta séries temporais em CSV')
    parser.add_argument('--plot',    action='store_true',
                        help='Mapas para passos selecionados (padrão: 1, meio, último)')
    parser.add_argument('--compare', action='store_true',
                        help='Compara com cap NUOPC (monan_export_*.nc) — requer --capdir')
    parser.add_argument('--all',     action='store_true',
                        help='stats + csv + plot  (padrão se nenhum modo especificado)')

    # ── NOVOS argumentos v1.4 ─────────────────────────────────────────────────
    parser.add_argument(
        '--allmaps',
        action='store_true',
        help=(
            'Gera um mapa por campo por TODOS os passos de tempo disponíveis '
            'nos arquivos MONAN_DIAG_*.nc. Implica --plot. '
            'Os mapas são salvos em <outdir>/allmaps/ com nome '
            'standalone_<campo>_passo<NN>.png. '
            'Combine com --field para restringir campos. '
            'Exemplo: --allmaps  --field t2m acswdnb'
        ))
    parser.add_argument(
        '--allfields',
        action='store_true',
        help=(
            'Descobre e processa TODOS os campos com dimensão (Time, nCells) '
            'presentes nos arquivos MONAN_DIAG, além dos catalogados em '
            'FIELD_META. Campos desconhecidos recebem metadados automáticos '
            '(cmap, escala e limites por heurística de nome). '
            'Pode ser combinado com qualquer modo de operação. '
            'Exemplo: --allfields --stats  (lista sem gerar mapas)'
        ))

    args = parser.parse_args()

    # ── Lógica de ativação de modos ───────────────────────────────────────────
    # --allmaps implica --plot
    if args.allmaps:
        args.plot = True

    # Se nenhum modo explícito, ativar --all
    if not any([args.stats, args.csv, args.plot, args.compare, args.all]):
        args.all = True
    if args.all:
        args.stats = args.csv = args.plot = True

    # ── Cabeçalho ─────────────────────────────────────────────────────────────
    print()
    print('═' * 70)
    print('  MONAN-A 2.0 Standalone — Pós-processamento MONAN_DIAG')
    print('  INPE / CGCT / DIMNT — GT Acoplamento de Modelos  (v1.4)')
    print('═' * 70)
    print(f"  Diretório DIAG : {os.path.abspath(args.diagdir)}")
    print(f"  Arquivo init   : {args.initfile}")
    print(f"  Saída          : {os.path.abspath(args.outdir)}")

    # ── Descoberta de campos ───────────────────────────────────────────────────
    files = find_diag_files(args.diagdir)
    print(f"  Arquivos DIAG  : {len(files)}")
    print(f"  Primeiro       : {os.path.basename(files[0])}")
    print(f"  Último         : {os.path.basename(files[-1])}")

    # --allfields: descobrir todos os campos disponíveis nos DIAG
    if args.allfields:
        all_f, known_f, new_f = discover_all_fields(files)
        if new_f:
            print(f"\n  [--allfields] {len(new_f)} campo(s) extra(s) encontrado(s) "
                  f"(além dos {len(known_f)} em FIELD_META):")
            for fn in new_f:
                print(f"    + {fn}  [meta auto]")
        else:
            print(f"\n  [--allfields] Nenhum campo extra — "
                  f"todos os {len(known_f)} campos já estão em FIELD_META.")

        # Se --field não foi explicitamente fornecido, usar todos os descobertos
        if args.field is None:
            field_list = all_f
        else:
            # --field explícito tem precedência; adicionar apenas o que foi pedido
            field_list = args.field
    else:
        # Sem --allfields: usar apenas FIELD_META (ou --field explícito)
        field_list = args.field if args.field is not None else list(FIELD_META.keys())

    print(f"  Campos         : {len(field_list)} ({', '.join(field_list[:8])}"
          f"{'...' if len(field_list) > 8 else ''})")
    print()

    # ── Coordenadas ───────────────────────────────────────────────────────────
    print("  Carregando coordenadas...")
    lon, lat = load_coords(args.initfile)
    print()

    # ── Verificar disponibilidade dos campos nos arquivos ─────────────────────
    available = detect_available_fields(files, field_list)
    if not available:
        sys.exit("ERRO: nenhum dos campos solicitados está presente nos arquivos.")

    # ── Carregar todos os passos ───────────────────────────────────────────────
    timestamps, elapsed_s, fields, dt_s_arr = load_all_steps(files, available)
    nsteps = len(timestamps)

    # ── Índices de passos para --plot (subconjunto) ───────────────────────────
    # Para --plot sem --allmaps: padrão 3 passos
    step_indices_plot = ([s - 1 for s in args.step]
                         if args.step
                         else [0, nsteps // 2, nsteps - 1])
    step_indices_plot = [s for s in step_indices_plot if 0 <= s < nsteps]

    # Para --allmaps: TODOS os passos
    step_indices_all = list(range(nsteps))

    print()

    # ── Modo --stats ──────────────────────────────────────────────────────────
    if args.stats:
        print("  [--stats] Calculando estatísticas...")
        print_stats(timestamps, fields, available)

    # ── Modo --csv ────────────────────────────────────────────────────────────
    if args.csv:
        print("  [--csv] Exportando CSV...")
        export_csv(timestamps, elapsed_s, fields, available, args.outdir)
        print()

    # ── Modo --plot (subconjunto de passos) ───────────────────────────────────
    if args.plot and not args.allmaps:
        print(f"  [--plot] Gerando figuras (passos {[s+1 for s in step_indices_plot]})...")
        plot_maps(timestamps, fields, available, lon, lat,
                  step_indices_plot, args.outdir,
                  show_progress=False)
        plot_timeseries(timestamps, fields, available, args.outdir)
        print()

    # ── Modo --allmaps (TODOS os passos) ──────────────────────────────────────
    if args.allmaps:
        allmaps_dir = os.path.join(args.outdir, 'allmaps')
        n_mapas = len(available) * len(step_indices_all)
        print(f"  [--allmaps] Gerando {n_mapas} mapas "
              f"({len(available)} campo(s) × {nsteps} passo(s)) → {allmaps_dir}/")
        print(f"  Progresso:")
        plot_maps(timestamps, fields, available, lon, lat,
                  step_indices_all, allmaps_dir,
                  show_progress=True)
        # Série temporal sempre gerada junto com --allmaps (resume a série completa)
        print(f"  [--allmaps] Série temporal...")
        plot_timeseries(timestamps, fields, available, allmaps_dir)
        print(f"  [--allmaps] Concluído: {n_mapas} mapas em {allmaps_dir}/")
        print()

    # ── Modo --compare ────────────────────────────────────────────────────────
    if args.compare:
        print("  [--compare] Comparando com cap NUOPC...")
        pairs = [(f_sa, CAP_MAP[f_sa]) for f_sa in available if f_sa in CAP_MAP]
        if not pairs:
            print("  AVISO: nenhum campo com equivalente no cap disponível.")
        else:
            cap_field_names = [p[1] for p in pairs]
            ts_cap, fields_cap = load_cap_fields(args.capdir, cap_field_names)
            compare_fields(timestamps, fields, ts_cap, fields_cap,
                           pairs, lon, lat, args.outdir)
        print()

    print('═' * 70)
    print('  Concluído.')
    print('═' * 70)
    print()


if __name__ == '__main__':
    main()
