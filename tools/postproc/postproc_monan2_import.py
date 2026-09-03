#!/usr/bin/env python3
"""
postproc_monan2_import.py — Diagnóstico dos campos importados pelo MONAN-A 2.0
                           via conector MED→MPAS (So_t, Si_ifrac, Sf_zorl)

INPE / CGCT / DIMNT — GT Acoplamento de Modelos — v2.3 (Maio 2026)

CORREÇÕES v2.3
═══════════════════════════════════════════════════════════════════════════════
  BUG-11 (mapas Si_ifrac em branco — células esparsas invisíveis em pcolormesh)
    pcolormesh renderiza células de 1°×1° como pixels de ~1-2 px na escala
    do mapa global.  Com apenas 38–107 células de gelo ativas, os mapas
    Si_ifrac aparecem essencialmente em branco mesmo com dados presentes.
    Solução: quando n < ICE_SCATTER_THRESHOLD (2000 células), um scatter
    overlay com marcadores de tamanho fixo (ICE_SCATTER_SIZE=18 pt²) é
    desenhado sobre o pcolormesh, garantindo legibilidade independente da
    esparsidade do campo.  O pcolormesh é mantido para consistência visual.


    Quando SST é bootstrap (uniforme ≈ 271.35 K), o Si_ifrac do mesmo passo
    contém o estado de restart do SIS2 — não dado de acoplamento real.
    coverage_fraction() retornava (1.0, 0.0) pois Si_ifrac do restart NÃO é
    uniforme (tem distribuição espacial real do arquivo de restart). Porém
    "100% dinâmico" é enganoso: os 7918 fragmentos de gelo visíveis refletem
    a condição inicial do SIS2, que desaparece na primeira troca NUOPC.
    Solução: _is_bootstrap_step() detecta se So_t é uniforme no passo i;
    quando verdadeiro, Si_ifrac recebe anotação "restart SIS2 (t=0)" em laranja
    no canto inferior esquerdo.

  BUG-10 (escala de cores Si_ifrac inconsistente entre passos)
    BUG-02 (v2.2) usava escala adaptativa POR PASSO: passo 01:00 com gelo do
    restart (max=1.0) ficava com vmax=1.0, enquanto passos 02:00–05:00 com
    poucos fragmentos de gelo reais adaptavam para vmax≈0.12.  Impossível
    comparar visualmente a evolução temporal do campo.
    Solução: vmax_si_global pré-calculado excluindo passos de bootstrap; usado
    de forma consistente em todos os passos. Si_ifrac do restart aparece mais
    saturada que os passos reais — comportamento fisicamente correto.

  ADIÇÃO: anotação "n=xxxx cél > ICE_THR | max=x.xxx" no canto inferior
    direito do painel Si_ifrac. Informa quantas células oceânicas excedem
    o limiar definido por IFRAC_ICE_ANN_THR = 0.01, e o valor máximo do
    campo. Complementa a anotação de cobertura no canto esquerdo.

CORREÇÕES v2.1 (BUG-LAND-FONTE2):
  • So_t  — fill de terra (271.35 K, marcador Sprint A.5) agora mascarado
             antes de plotar: patches dark-blue nos trópicos eliminados.
  • Sf_zorl — máscara de terra do So_t propagada para a inferência
              Charnock+Smith: patches dark-red (z₀ inflacionado por
              Foxx_taux/tauy anômalos sobre terra) eliminados.
  • _load_fonte2 — retorno prematuro corrigido (3→4 valores); lat/lon
              extraídos dos arquivos MED (coords antes sempre None).

═══════════════════════════════════════════════════════════════════════════════
Contexto
═══════════════════════════════════════════════════════════════════════════════

O MONAN-A recebe 5 campos do mediador a cada passo de acoplamento:
  So_t      SST [K]              — ocean_public%t_surf do MOM6
  Si_ifrac  fração de gelo [0-1] — SIS2 / proxy sigmoide do mom_cap
  So_u      corrente zonal       — inspecionável via log ESMF
  So_v      corrente meridional  — inspecionável via log ESMF
  Sf_zorl   rugosidade [m]       — Charnock+Smith calculado no MED (Sprint C)

Este script suporta duas fontes de dados, usadas automaticamente conforme
a disponibilidade:

  FONTE 1 — mpas_import_step????.nc  (escrita direta em mpas_cap_methods.F90)
    Ativa quando write_import_diag=.true. em &nuopc_docn do nuopc.input
    e o executável foi compilado com o módulo de diagnóstico de importação.
    Contém So_t, Si_ifrac e Sf_zorl lidos diretamente do importState MPAS.

  FONTE 2 — mom6_import_*.nc  (inferência a partir dos fluxos MED→OCN)
    Sempre disponível após uma rodada com write_import_diag=.true. no MED.
    So_t e Si_ifrac lidos diretamente. Sf_zorl INFERIDO de Foxx_taux/Foxx_tauy
    via fórmula Charnock+Smith: u*=√(|τ|/ρ), z₀=α·u*²/g + β·ν/u*

  FONTE 3 — logs/PET0.esmApp.log  (evidências qualitativas)
    Confirma que Sprint C (Sf_zorl dinâmico) e mpas_import estão ativos.

═══════════════════════════════════════════════════════════════════════════════
Uso
═══════════════════════════════════════════════════════════════════════════════
  python3 postproc_monan2_import.py                      # todos os modos
  python3 postproc_monan2_import.py --stats              # só estatísticas
  python3 postproc_monan2_import.py --check              # só verificação física
  python3 postproc_monan2_import.py --plot               # só mapas
  python3 postproc_monan2_import.py --log                # só verificação de log
  python3 postproc_monan2_import.py --diagdir diag_import --outdir diag_import/postproc

Dependências obrigatórias: numpy, netCDF4
Dependências opcionais   : matplotlib, cartopy  (para --plot)
"""

import sys
import os
import glob
import argparse
from datetime import datetime, timedelta

import numpy as np

try:
    from netCDF4 import Dataset
except ImportError:
    sys.exit("ERRO: netCDF4 não encontrado. Instalar: pip install --user netCDF4")

# ─── Constantes físicas (Charnock + Smith 1988) ───────────────────────────────
_ALPHA = 0.018          # constante de Charnock
_BETA  = 0.11           # constante de Smith
_G     = 9.81           # m/s²
_NU    = 1.5e-5         # viscosidade cinemática do ar [m²/s]
_RHO   = 1.225          # densidade do ar [kg/m³]
_USTAR_MIN = 1e-4       # evita divisão por zero


def _masked_to_float(x):
    """Converte um escalar masked (np.ma) para float sem emitir UserWarning.

    Quando uma operação de redução (mean/max/min) é aplicada a um array
    inteiramente mascarado, o resultado é np.ma.masked.  A chamada direta
    float(np.ma.masked) funciona, mas emite UserWarning porque o valor
    subjacente é indefinido.  np.ma.filled() substitui o sentinel por NaN
    antes da conversão, eliminando o aviso.

    Parâmetros
    ----------
    x : escalar ou np.ma.MaskedConstant
        Resultado de .mean(), .max() ou .min() sobre um MaskedArray.

    Retorno
    -------
    float : valor numérico, ou NaN se o elemento estava mascarado.
    """
    return float(np.ma.filled(x, fill_value=np.nan))


def _infer_z0(taux, tauy):
    """Infere Sf_zorl de Foxx_taux/Foxx_tauy via Charnock+Smith."""
    tau   = np.sqrt(np.maximum(taux**2 + tauy**2, 0.0))
    ustar = np.sqrt(tau / _RHO)
    ustar = np.maximum(ustar, _USTAR_MIN)
    z0    = _ALPHA * ustar**2 / _G + _BETA * _NU / ustar
    # Aplicar os mesmos clamps do mpas_import
    z0    = np.clip(z0, 1e-5, 0.1)
    return z0


# ─── Metadados dos campos ─────────────────────────────────────────────────────

FIELD_META = {
    'So_t': {
        'long_name':   'SST dinâmica MOM6 (So_t)',
        'scale_units': 'K',
        'scale':       1.0,
        'cmap':        'RdBu_r',
        # Faixa de PLOT estreitada à banda onde a SST tem gradiente real
        # (água do mar congelando ~271,4 K até trópicos ~303 K). A faixa
        # anterior (271–305) coincidia com os extremos físicos e saturava
        # quase todo o oceano nos limites da colorbar, escondendo estruturas
        # (Kuroshio, Gulf Stream, ressurgências). vmin/vmax_phys (validação)
        # permanecem largos; só a escala visual foi ajustada.
        'vmin_plot':   273.0,
        'vmax_plot':   303.0,
        'vmin_phys':   270.0,
        'vmax_phys':   310.0,
        'stub_value':  298.0,    # cfg_sst_default (bootstrap t=0)
        'stub_tol':    0.01,
    },
    'Si_ifrac': {
        'long_name':   'Fração de gelo marinho (Si_ifrac)',
        'scale_units': '[0-1]',
        'scale':       1.0,
        'cmap':        'Blues',
        'vmin_plot':   0.0,
        'vmax_plot':   1.0,
        'vmin_phys':   0.0,
        'vmax_phys':   1.0,
        # stub_value=None: zero é valor físico válido (oceano sem gelo).
        # Bootstrap detectado apenas pela verificação de campo uniforme.
        'stub_value':  None,
        'stub_tol':    1e-6,
    },
    'Sf_zorl': {
        'long_name':   'Rugosidade superficial Charnock+Smith (Sf_zorl)',
        'scale_units': 'm',
        'scale':       1.0,
        'cmap':        'YlOrRd',
        'vmin_plot':   1e-5,
        'vmax_plot':   1e-2,
        'vmin_phys':   1e-5,    # Z0_MIN — clamp em mpas_import
        'vmax_phys':   0.1,     # Z0_MAX — clamp em mpas_import
        'stub_value':  0.01,    # zorl_default anterior ao Sprint C
        'stub_tol':    1e-5,
        'calm_max':    5e-4,    # mar calmo: z0 < 5e-4 m (vento < 10 m/s)
        'storm_min':   1e-3,    # tempestade: z0 > 1e-3 m (vento > 15 m/s)
    },
}

FIELDS = list(FIELD_META.keys())

# ─── Métrica de cobertura dinâmica (apoio ao diagnóstico) ─────────────────────
# Uma célula está "no default" se |valor − stub_value| <= COVER_TOL; a fração
# complementar é a cobertura dinâmica. ADICIONALMENTE, um campo espacialmente
# UNIFORME (peak-to-peak ≈ 0) não carrega informação dinâmica — é o estado de
# bootstrap t=0 (ex.: So_t = 271,35 K, Sf_zorl = 0,01 m, antes da 1ª troca
# oceânica) — e por isso recebe cobertura dinâmica = 0%, independentemente do
# valor constante. Sem essa verificação, um campo uniforme em valor ≠ stub
# (como So_t bootstrap = 271,35 ≠ 298) seria erroneamente lido como 100%.
# Si_ifrac removido de COVER_TOL: zero é valor físico válido.
COVER_TOL = {'So_t': 0.05, 'Sf_zorl': 5e-4}

# Limiar de Si_ifrac para contar células com gelo na anotação do mapa
IFRAC_ICE_ANN_THR = 0.01

# Quando o número de células com Si_ifrac > IFRAC_ICE_ANN_THR for inferior
# a ICE_SCATTER_THRESHOLD, pcolormesh renderiza células de 1°×1° como pixels
# essencialmente invisíveis na escala do mapa global.  Neste caso, um scatter
# overlay com marcadores maiores é adicionado sobre o pcolormesh para tornar
# as células de gelo legíveis no diagnóstico.
ICE_SCATTER_THRESHOLD = 2000   # células; acima disto, pcolormesh é suficiente
ICE_SCATTER_SIZE      = 80     # tamanho do marcador scatter [pt²] — visível em mapa global


def _is_bootstrap_step(data, step_idx):
    """
    Retorna True se o passo step_idx está em modo bootstrap (pré-acoplamento).

    Critério: So_t é espacialmente uniforme (std ≈ 0), indicando que o acoplador
    ainda não escreveu o campo oceânico real.  Quando verdadeiro, Si_ifrac do
    mesmo passo contém o estado de restart do SIS2 — não dado de acoplamento.
    """
    arr_sot = data.get('So_t')
    if arr_sot is None:
        return False
    layer = arr_sot[step_idx] * FIELD_META['So_t']['scale']
    return is_uniform(layer, 'So_t')


def _flat_valid(layer):
    """Vetor 1-D dos valores válidos (descarta máscara)."""
    return (layer.compressed() if hasattr(layer, 'compressed')
            else np.asarray(layer).ravel())


def is_uniform(layer, fname):
    """True se o campo é espacialmente uniforme (sem variação dinâmica)."""
    flat = _flat_valid(layer)
    if flat.size == 0:
        return True
    tol = COVER_TOL.get(fname, FIELD_META[fname].get('stub_tol', 1e-6))
    return float(np.ptp(flat)) <= tol


def coverage_fraction(layer, fname):
    """
    Fração de células válidas com dado DINÂMICO (≠ default).

    Retorna (frac_dinamica, frac_default) em [0,1].
    - Campo uniforme (bootstrap t=0)        → (0.0, 1.0)
    - Campo sem stub definido, não uniforme → (1.0, 0.0)
    """
    flat = _flat_valid(layer)
    if flat.size == 0:
        return (0.0, 0.0)
    # Uniforme = sem informação espacial dinâmica (bootstrap), 0% cobertura.
    if is_uniform(layer, fname):
        return (0.0, 1.0)
    stub = FIELD_META[fname].get('stub_value')
    if stub is None:
        # Campo onde zero é valor físico válido (ex.: Si_ifrac).
        # Se chegou aqui, o campo já passou pelo teste is_uniform → não-uniforme
        # → dado é dinâmico.
        return (1.0, 0.0)
    tol = COVER_TOL.get(fname, FIELD_META[fname].get('stub_tol', 1e-6))
    frac_default = float(np.mean(np.abs(flat - stub) <= tol))
    return 1.0 - frac_default, frac_default


def _field_key(label):
    """
    Normaliza um label de campo para a chave de FIELD_META.

    Exemplos:
      'Sf_zorl'                          → 'Sf_zorl'
      'Sf_zorl (inferido de Foxx_taux/tauy)' → 'Sf_zorl'
      'So_t (FONTE 1)'                   → 'So_t'
    """
    key = label.split('(')[0].strip()
    return key if key in FIELD_META else label


# ─── FONTE 1: mpas_import_step????.nc ────────────────────────────────────────

def _load_fonte1(diagdir):
    """
    Carrega mpas_import_step????.nc — escrita direta do importState MPAS.

    BUG-01 (corrigido): fonte_label usava o padrão glob '????' literal.
                        Agora armazena os passos reais para o label.
    BUG-03 (corrigido): coordenadas lat/lon lidas diretamente do NetCDF
                        (evita desalinhamento de 0.5° ao recalcular com linspace).
    BUG-04 (corrigido): fill_value -9.99e+20 mascarado defensivamente;
                        masked_invalid cobre NaN/Inf, mas não valores grandes
                        que não estejam registrados no _FillValue do netCDF4.

    Retorna (steps, data, timestamps, coords) ou (None, None, None, None).
      coords = {'lat': array 1D, 'lon': array 1D}
    """
    pattern = os.path.join(diagdir, 'mpas_import_step????.nc')
    files   = sorted(glob.glob(pattern))
    if not files:
        return None, None, None, None

    steps  = []
    data   = {f: [] for f in FIELDS}
    tss    = []
    coords = None   # extraído do primeiro arquivo

    _FILL_THR = 1e19   # limiar defensivo para fill values do Fortran (-9.99e+20)

    for fpath in files:
        step = int(os.path.basename(fpath)
                   .replace('mpas_import_step', '').replace('.nc', ''))
        steps.append(step)
        tss.append(None)   # timestamps não disponíveis neste formato

        with Dataset(fpath) as nc:
            # BUG-03: ler coordenadas do arquivo (lat/lon com half-offset Fortran)
            if coords is None:
                lat_nc = (nc.variables['lat'][:] if 'lat' in nc.variables
                          else None)
                lon_nc = (nc.variables['lon'][:] if 'lon' in nc.variables
                          else None)
                if lat_nc is not None and lon_nc is not None:
                    coords = {'lat': np.asarray(lat_nc),
                              'lon': np.asarray(lon_nc)}

            for fname in FIELDS:
                if fname in nc.variables:
                    arr = nc.variables[fname][:]

                    # BUG-04: mascaramento defensivo do fill_value Fortran
                    arr = np.ma.masked_where(np.abs(arr) > _FILL_THR, arr)

                    # BUG-03: garantir orientação (lat, lon) — (nlat, nlon)
                    # O Fortran define var com [dimid_lon, dimid_lat], então
                    # o netCDF4 lê como shape (nlat, nlon) — já correto.
                    # Transposição defensiva: se nlat < nlon (o esperado para
                    # grades globais), a orientação já está correta; só transpõe
                    # se a primeira dimensão for maior (caso imprevisto).
                    if arr.ndim == 2 and arr.shape[0] > arr.shape[1]:
                        arr = arr.T

                    arr = np.ma.masked_invalid(arr)
                    data[fname].append(arr)
                else:
                    data[fname].append(None)

    result = {}
    for fname in FIELDS:
        valid = [d for d in data[fname] if d is not None]
        result[fname] = np.ma.stack(valid, axis=0) if valid else None

    return steps, result, tss, coords


# ─── FONTE 2: mom6_import_*.nc (inferência) ──────────────────────────────────

# Marcador de terra inserido pelo Sprint A.5 no MED (T_FILL = 271.35 K).
# Células com So_t nesse valor são terra e NÃO devem ser plotadas nem usadas
# para inferir Sf_zorl via Charnock+Smith.
_LAND_FILL_K   = 271.35   # K  — ponto de congelamento da água do mar, S≈35
_LAND_FILL_TOL =   0.02   # K  — tolerância: ±20 mK cobre arredondamento float32


def _load_fonte2(diagdir):
    """
    Carrega mom6_import_*.nc e lê/infere os três campos diagnósticos.

    - So_t     : lido diretamente; fill de terra (271.35 K) mascarado.
    - Si_ifrac : lido diretamente.
    - Sf_zorl  : INFERIDO de Foxx_taux/Foxx_tauy via Charnock+Smith;
                 máscara de terra do So_t propagada para evitar z₀ inflacionado.

    BUG-LAND-FONTE2 (corrigido):
      O diagnóstico mom6_import_*.nc é escrito pelo MED antes da zeragem
      de terra do Sprint A.5.1 (RouteAtmToOcn). Portanto:
        • So_t = 271.35 K em células de terra → vmin_plot=273 K → saturam
          no azul mais escuro do RdBu_r, produzindo patches dark-blue.
        • Foxx_taux/tauy têm valores anômalos em células de terra (bulk
          NCAR rodou sobre SST=271.35 K) → z₀ inflacionado via Charnock
          → patches dark-red no mapa de Sf_zorl.
      Correção: mascarar fill de terra no So_t e propagar essa máscara
      para a inferência de z₀.

    BUG-COORDS-FONTE2 (corrigido):
      coords era sempre None (código nunca extraía lat/lon do arquivo).
      Agora extrai as variáveis 'lat'/'lon' do primeiro arquivo, igual
      à FONTE 1, habilitando diagnósticos geográficos em check_physics.

    BUG-RETURN-FONTE2 (corrigido):
      Retorno prematuro usava 3 valores; agora retorna 4 (consistente
      com _load_fonte1 e com o unpack em load_data).

    Retorna (steps, data, timestamps, coords) ou (None, None, None, None).
    """
    pattern = os.path.join(diagdir, 'mom6_import_????????_??????.nc')
    files   = sorted(glob.glob(pattern))
    if not files:
        return None, None, None, None   # BUG-RETURN-FONTE2: era 3 valores

    steps  = []
    data   = {f: [] for f in FIELDS}
    tss    = []
    coords = None

    for fpath in files:
        base   = os.path.basename(fpath)         # mom6_import_YYYYMMDD_HHMMSS.nc
        ts_str = base[len('mom6_import_'):-3]    # YYYYMMDD_HHMMSS
        try:
            ts = datetime.strptime(ts_str, '%Y%m%d_%H%M%S')
        except ValueError:
            ts = None
        steps.append(len(steps) + 1)
        tss.append(ts)

        with Dataset(fpath) as nc:

            # BUG-COORDS-FONTE2: extrair lat/lon do arquivo (primeira vez).
            # Os arquivos mom6_import_*.nc gerados pelo MED têm variáveis
            # 'lat' e 'lon' iguais às do mpas_import_step*.nc (grade 360×180).
            if coords is None:
                lat_nc = (nc.variables['lat'][:] if 'lat' in nc.variables
                          else None)
                lon_nc = (nc.variables['lon'][:] if 'lon' in nc.variables
                          else None)
                if lat_nc is not None and lon_nc is not None:
                    coords = {'lat': np.asarray(lat_nc),
                              'lon': np.asarray(lon_nc)}

            # ── So_t ────────────────────────────────────────────────────────
            # BUG-LAND-FONTE2: mascarar fill de terra ANTES de armazenar.
            # A máscara gerada aqui é reutilizada para Sf_zorl (mesmo passo).
            so_t_land_mask = None
            if 'So_t' in nc.variables:
                arr = nc.variables['So_t'][:]
                if arr.ndim == 2 and arr.shape[0] > arr.shape[1]:
                    arr = arr.T
                arr_raw = np.asarray(arr, dtype=float)
                # Células com So_t ≈ 271.35 K são terra (marcador Sprint A.5).
                so_t_land_mask = np.abs(arr_raw - _LAND_FILL_K) < _LAND_FILL_TOL
                arr = np.ma.masked_where(so_t_land_mask, arr)
                arr = np.ma.masked_invalid(arr)
                data['So_t'].append(arr)
            else:
                data['So_t'].append(None)

            # ── Si_ifrac ────────────────────────────────────────────────────
            if 'Si_ifrac' in nc.variables:
                arr = nc.variables['Si_ifrac'][:]
                if arr.ndim == 2 and arr.shape[0] > arr.shape[1]:
                    arr = arr.T
                data['Si_ifrac'].append(np.ma.masked_invalid(arr))
            else:
                data['Si_ifrac'].append(None)

            # ── Sf_zorl (inferido) ──────────────────────────────────────────
            # BUG-LAND-FONTE2: propagar máscara de terra do So_t para z₀.
            # O bulk NCAR no MED roda em TODAS as células (terra + oceano).
            # Sobre terra (SST=271.35 K) produz Foxx_taux/tauy anômalos
            # → u* alta → z₀ inflacionado pelo Charnock → patches dark-red.
            if 'Foxx_taux' in nc.variables and 'Foxx_tauy' in nc.variables:
                taux = nc.variables['Foxx_taux'][:]
                tauy = nc.variables['Foxx_tauy'][:]
                if taux.ndim == 2 and taux.shape[0] > taux.shape[1]:
                    taux = taux.T
                    tauy = tauy.T
                z0 = _infer_z0(np.array(taux), np.array(tauy))
                # Aplicar máscara de terra derivada do So_t deste mesmo passo.
                if so_t_land_mask is not None:
                    z0 = np.ma.masked_where(so_t_land_mask, z0)
                z0 = np.ma.masked_invalid(z0)
                data['Sf_zorl'].append(z0)
            else:
                data['Sf_zorl'].append(None)

    result = {}
    for fname in FIELDS:
        valid = [d for d in data[fname] if d is not None]
        result[fname] = np.ma.stack(valid, axis=0) if valid else None

    return steps, result, tss, coords


# ─── Carregamento unificado ───────────────────────────────────────────────────

def load_data(diagdir):
    """
    Tenta FONTE 1 (mpas_import_step*.nc). Se não encontrar, tenta FONTE 2.
    Retorna (steps, data, timestamps, fonte_label, coords).
    BUG-01 (corrigido): label com nome real dos passos.
    """
    steps, data, tss, coords = _load_fonte1(diagdir)
    if steps is not None:
        if len(steps) == 1:
            label = f'FONTE 1 (mpas_import_step{steps[0]:04d}.nc)'
        else:
            label = (f'FONTE 1 (mpas_import_step{steps[0]:04d}'
                     f'..{steps[-1]:04d}.nc, {len(steps)} passos)')
        return steps, data, tss, label, coords

    steps, data, tss, coords = _load_fonte2(diagdir)
    if steps is not None:
        return steps, data, tss, 'FONTE 2 (mom6_import_*.nc — Sf_zorl inferido)', coords

    sys.exit(
        f"\nERRO: nenhum arquivo de diagnóstico encontrado em '{diagdir}'.\n"
        "Necessário pelo menos um dos seguintes:\n"
        "  FONTE 1: mpas_import_step????.nc\n"
        "    → requer compilação com write_mpas_import_diag e\n"
        "      write_import_diag=.true. em &nuopc_docn do nuopc.input\n"
        "  FONTE 2: mom6_import_????????_??????.nc\n"
        "    → requer write_import_diag=.true. em &nuopc_docn do nuopc.input\n"
    )


# ─── Estatísticas ─────────────────────────────────────────────────────────────

def print_stats(steps, data, tss, fonte_label):
    """Imprime tabela de estatísticas por campo e passo."""
    sep = '─' * 91
    eh_fonte2 = 'FONTE 2' in fonte_label

    print()
    print('═' * 72)
    print('  ESTATÍSTICAS — campos na grade MED (360×180) —', fonte_label)
    print('═' * 72)

    for fname in FIELDS:
        meta = FIELD_META[fname]
        arr  = data.get(fname)

        # Label do campo — indica quando é inferência
        if fname == 'Sf_zorl' and eh_fonte2:
            field_label = 'Sf_zorl  —  Rugosidade superficial Charnock+Smith (inferida de Foxx_taux/tauy)'
        else:
            field_label = meta['long_name']

        if arr is None:
            print(f"\n  ┌─ {field_label}  [{meta['scale_units']}]")
            print(f"  │  (sem dados)")
            print(f"  └{'─' * 70}")
            continue

        print(f"\n  ┌─ {field_label}  [{meta['scale_units']}]")
        print(f"  │  {'Passo':>6}  {'Data/hora':<22}  {'Mínimo':>12}  {'Máximo':>12}  "
              f"{'Média':>12}  {'DesvPad':>10}  {'NaN%':>6}")
        print(f"  │  {sep}")

        scale = meta['scale']
        for i, step in enumerate(steps):
            ts_str = tss[i].strftime('%Y-%m-%d %H:%M') if tss[i] else f'passo {step}'
            layer  = arr[i] * scale
            if layer.count() == 0:
                print(f"  │  {step:>6}  {ts_str:<22}  {'(sem dados)':>52}")
                continue
            flat  = layer.compressed()
            nan_pct = 100.0 * (layer.size - layer.count()) / max(layer.size, 1)
            print(f"  │  {step:>6}  {ts_str:<22}  {flat.min():>12.4f}  {flat.max():>12.4f}  "
                  f"{flat.mean():>12.4f}  {flat.std():>10.4f}  {nan_pct:>5.1f}%")

        all_flat = arr.compressed() * scale
        if all_flat.size > 0:
            print(f"  │  {sep}")
            print(f"  │  {'SÉRIE':<6}  {'(todos os passos)':<22}  "
                  f"{all_flat.min():>12.4f}  {all_flat.max():>12.4f}  "
                  f"{all_flat.mean():>12.4f}  {all_flat.std():>10.4f}")
        print(f"  └{'─' * 88}")


# ─── Verificação física ───────────────────────────────────────────────────────

def check_physics(steps, data, fonte_label, coords=None):
    """Verifica limites físicos e detecta campo com valor de stub.

    coords (opcional): {'lat': 1D, 'lon': 1D} — habilita diagnósticos
    cientes da geografia (ex.: distinguir sub-congelamento polar normal de
    sub-congelamento anômalo em baixas latitudes).
    """
    eh_fonte2 = 'FONTE 2' in fonte_label
    lat_axis = None
    if coords is not None and coords.get('lat') is not None:
        lat_axis = np.asarray(coords['lat'])
    print()
    print('  ┌─ VERIFICAÇÃO FÍSICA — campos importados MED→MPAS ──────────────────────────')

    n_ok = n_warn = 0

    for fname in FIELDS:
        meta  = FIELD_META[fname]    # acesso sempre pela chave base
        arr   = data.get(fname)

        if arr is None:
            print(f"  │  ✗ {fname}: sem dados")
            n_warn += 1
            continue

        scale  = meta['scale']
        pmin   = meta['vmin_phys'] * scale
        pmax   = meta['vmax_phys'] * scale
        flat   = arr.compressed() * scale
        if flat.size == 0:
            print(f"  │  ✗ {fname}: array vazio")
            n_warn += 1
            continue

        gmin, gmax, gmean, gstd = flat.min(), flat.max(), flat.mean(), flat.std()
        ok = True

        # 1. Limites físicos
        if gmin < pmin or gmax > pmax:
            print(f"  │  ✗ {fname}: [{gmin:.4g}, {gmax:.4g}] {meta['scale_units']} "
                  f"— fora de [{pmin:.4g}, {pmax:.4g}]")
            ok = False

        # 2. Detecção de stub / bootstrap (campo uniforme)
        # Um campo com desvio-padrão ~0 é uniforme: ou é o stub conhecido
        # (valor de bootstrap pré-acoplamento, p.ex. So_t=271,35 K ou
        # Sf_zorl=0,01 m no passo t=0), ou um conector inativo. Detecta-se pela
        # UNIFORMIDADE (gstd≈0), independentemente do valor casar com stub_value
        # — assim o bootstrap t=0 do So_t (271,35 K) também é reconhecido, e não
        # contado como "100% de cobertura dinâmica".
        stub_v = meta.get('stub_value')
        if ok and gstd < 1e-6:
            if stub_v is not None and abs(gmean - stub_v * scale) < 0.1:
                rotulo = f"STUB ({stub_v:.4g} {meta['scale_units']})"
            else:
                rotulo = f"BOOTSTRAP/uniforme ({gmean:.4g} {meta['scale_units']})"
            print(f"  │  ✗ {fname}: campo uniforme — {rotulo}")
            if fname == 'Sf_zorl' and stub_v is not None \
                    and abs(gmean - stub_v * scale) < 0.1:
                print(f"  │     Sprint C não ativo ou Sf_zorl não chegou ao importState MPAS")
            ok = False

        # 3. Diagnósticos específicos por campo
        if fname == 'So_t' and ok:
            # Sub-congelamento da água do mar (< 271,35 K) é FÍSICO em altas
            # latitudes (oceano sob gelo marinho). Só é anômalo em baixas
            # latitudes — ali indicaria padrão de SST deslocado/mal-mapeado.
            # Por isso a checagem é ciente da latitude (quando coords existe).
            FREEZE_K  = 271.35     # congelamento da água salgada (S≈35)
            LAT_POLAR = 55.0       # limite mar de gelo sazonal
            nsteps = arr.shape[0] if arr.ndim == 3 else 1
            for ip in range(nsteps):
                layer2d = (arr[ip] if arr.ndim == 3 else arr) * scale
                flat_p  = layer2d.compressed() if hasattr(layer2d, 'compressed') \
                          else np.asarray(layer2d).ravel()
                if flat_p.size == 0:
                    continue
                if flat_p.std() < 1e-6:
                    print(f"  │  • So_t passo {steps[ip]}: campo uniforme "
                          f"{flat_p.mean():.4g} K (bootstrap t=0) — ignorado nos testes")
                    continue
                cold   = np.ma.filled(layer2d < FREEZE_K, False)
                n_cold = int(np.sum(cold))
                if n_cold == 0:
                    continue
                # Separar polar (normal) de baixa latitude (anômalo) se houver lat.
                if lat_axis is not None and layer2d.ndim == 2 \
                        and lat_axis.size == layer2d.shape[0]:
                    lat2d   = np.broadcast_to(lat_axis[:, None], layer2d.shape)
                    n_polar = int(np.sum(cold & (np.abs(lat2d) >= LAT_POLAR)))
                    n_low   = int(np.sum(cold & (np.abs(lat2d) <  LAT_POLAR)))
                    print(f"  │  • So_t passo {steps[ip]}: {n_cold} células < "
                          f"{FREEZE_K} K — {n_polar} polares (|lat|≥{LAT_POLAR:.0f}°, "
                          f"normal: oceano sob gelo) + {n_low} em baixa latitude")
                    if n_low > 0:
                        frac_low = 100.0 * n_low / flat_p.size
                        print(f"  │  ⚠ So_t passo {steps[ip]}: {n_low} células "
                              f"({frac_low:.2f}%) sub-congelamento em |lat|<"
                              f"{LAT_POLAR:.0f}° — anômalo.")
                        # Diagnóstico de causa só no último passo (evita repetição).
                        if ip == nsteps - 1:
                            # Quão fria? Faixa [270, 271.35) = contaminação por
                            # mistura; < 270 já é capturado pelo filtro do MED.
                            low_band = layer2d[(np.abs(lat2d) < LAT_POLAR) &
                                               np.ma.filled(layer2d < FREEZE_K, False)]
                            if low_band.size > 0:
                                lo = float(np.ma.min(low_band))
                                print(f"  │     Faixa fria tropical: [{lo:.2f}, "
                                      f"{FREEZE_K}) K. Causa provável: regrid "
                                      f"BILINEAR OCN→ATM sem máscara no MED "
                                      f"(rh_ocn2atm), que mistura SST oceânica com "
                                      f"células mascaradas do MOM6 na costa/costura.")
                                print(f"  │     Correção sugerida (decisão de design): "
                                      f"regrid de So_t ciente de máscara "
                                      f"(srcMaskValues/dstFracField) ou NEAREST_STOD "
                                      f"em MED_cap_MONAN.F90 (FieldRegridStore, ~l.886).")
                else:
                    # Sem coords: informativo, sem atribuir causa indevida.
                    frac_cold = 100.0 * n_cold / flat_p.size
                    print(f"  │  • So_t passo {steps[ip]}: {n_cold} células "
                          f"({frac_cold:.1f}%) < {FREEZE_K} K — esperado nas "
                          f"calotas polares (oceano sob gelo).")

        if fname == 'Si_ifrac' and ok:
            frac_ice = float(np.mean(arr.compressed() * scale > 0.5))
            print(f"  │  ✓ Si_ifrac: {frac_ice*100:.3f}% das células com gelo > 50%  "
                  f"(média={gmean:.4f})")

        if fname == 'Sf_zorl' and ok:
            calm_frac  = float(np.mean(flat < meta['calm_max']))
            storm_frac = float(np.mean(flat > meta['storm_min']))
            fonte_nota = '  [inferido de Foxx_taux/tauy]' if eh_fonte2 else ''
            print(f"  │  ✓ Sf_zorl: média={gmean:.2e} m{fonte_nota}")
            print(f"  │     {calm_frac*100:.1f}% < {meta['calm_max']:.0e} m (mar calmo)  |  "
                  f"{storm_frac*100:.1f}% > {meta['storm_min']:.0e} m (vento forte)")
            if abs(gmean - 0.01) < 5e-4:
                print(f"  │  ⚠ Sf_zorl: média ≈ 0.01 m — suspeita de stub "
                      f"(zorl_default = 0.01 m)")
                ok = False

        # ── Cobertura dinâmica POR PASSO (detecta bug de mapeamento) ───────
        # A cobertura é avaliada por passo: passos uniformes (bootstrap t=0)
        # têm 0% e são rotulados como tal; o veredito de cobertura usa o
        # ÚLTIMO passo com dado dinâmico (o mais representativo do acoplamento
        # em regime). Avaliar o array agregado mascararia o bootstrap dentro
        # da variabilidade dos demais passos.
        nsteps = arr.shape[0] if arr.ndim == 3 else 1
        frac_dyn_last = None
        for ip in range(nsteps):
            layer_p = arr[ip] if arr.ndim == 3 else arr
            fd, fdef = coverage_fraction(layer_p * scale, fname)
            tag = '  (bootstrap t=0)' if is_uniform(layer_p * scale, fname) else ''
            print(f"  │  • {fname} passo {steps[ip]}: cobertura dinâmica "
                  f"= {fd*100:.1f}%{tag}")
            if not is_uniform(layer_p * scale, fname):
                frac_dyn_last = fd
        if meta.get('stub_value') is not None and frac_dyn_last is not None:
            if frac_dyn_last < 0.02:
                print(f"  │  ⚠ {fname}: campo no default "
                      f"({meta['stub_value']:.4g} {meta['scale_units']}) — "
                      f"stub (ex.: Si_ifrac/SIS2) ou conector inativo.")
            elif frac_dyn_last < 0.60:
                print(f"  │  ⚠ {fname}: COBERTURA PARCIAL — "
                      f"{(1-frac_dyn_last)*100:.0f}% das células no default e "
                      f"{frac_dyn_last*100:.0f}% com dado real.")
                print(f"  │     Assinatura do bug de mapeamento no import — "
                      f"recompilar mpas_cap_methods.F90 (gather global em "
                      f"state_get_field_1d).")

        # ── Localizador de LISTRA vertical (coluna anômala) ───────────────
        # Uma listra vertical = uma coluna de longitude cujo perfil destoa
        # sistematicamente das vizinhas. Origem típica: fronteira de tile (DE)
        # do g_grid no ESMF_FieldGather/regrid MED (regDecomp(1) tiles → bordas
        # em múltiplos de 360/nx_tiles). Esta rotina crava a longitude exata
        # para confronto com as fronteiras de decomposição. É só diagnóstico —
        # não altera o dado importado.
        if lat_axis is not None and arr.ndim == 3 \
                and coords is not None and coords.get('lon') is not None:
            lon_axis = np.asarray(coords['lon'])
            layer2d  = arr[-1] * scale          # último passo (regime)
            if hasattr(layer2d, 'shape') and layer2d.ndim == 2 \
                    and lon_axis.size == layer2d.shape[1]:
                col_med = np.ma.median(layer2d, axis=0)            # perfil por coluna
                base    = np.ma.median(col_med)
                mad     = np.ma.median(np.ma.abs(col_med - base)) + 1e-30
                z       = np.ma.abs(col_med - base) / (1.4826 * mad)
                susp    = np.where(np.ma.filled(z, 0.0) > 6.0)[0]   # outliers robustos
                if susp.size > 0 and susp.size <= 5:                # poucas colunas = listra
                    lons_str = ', '.join(f"{lon_axis[c]:+.1f}°" for c in susp)
                    print(f"  │  ⚠ {fname}: LISTRA detectada em coluna(s) "
                          f"de longitude {lons_str} (outlier robusto z>6).")
                    print(f"  │     Provável fronteira de tile (DE) do g_grid no "
                          f"gather/regrid MED. Conferir contra 360/regDecomp(1) "
                          f"(p.ex. ±90°,0° se 4 tiles em longitude).")

        if ok:
            print(f"  │  ✓ {fname}: [{gmin:.4g}, {gmax:.4g}] {meta['scale_units']} "
                  f"— dentro de [{pmin:.4g}, {pmax:.4g}]")
            n_ok += 1
        else:
            n_warn += 1

    print(f"  └─ {n_ok} OK, {n_warn} avisos")


# ─── Mapas ────────────────────────────────────────────────────────────────────

def plot_maps(steps, data, tss, outdir, fonte_label, coords=None, mask_default=False):
    """Gera mapas para cada passo. BUG-02: escala Si_ifrac adaptativa. BUG-03: coords do NetCDF."""
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.colors as mcolors
        from matplotlib.colors import LogNorm
        try:
            import cartopy.crs as ccrs
            import cartopy.feature as cfeature
            HAS_CARTOPY = True
        except ImportError:
            HAS_CARTOPY = False
            print("  AVISO: cartopy não disponível — mapas sem contornos de costa")
    except ImportError:
        print("  AVISO: matplotlib não disponível — mapas não gerados")
        return

    os.makedirs(outdir, exist_ok=True)
    campos_disponiveis = [f for f in FIELDS if data.get(f) is not None]
    if not campos_disponiveis:
        print("  AVISO: nenhum campo com dados para plotar")
        return

    # ── Pré-cálculo: vmax global de Si_ifrac para escala consistente ──────────
    # Exclui passos de bootstrap (So_t uniforme = pré-acoplamento): o estado de
    # restart do SIS2 pode ter ifrac ≈ 1 em todo o Ártico, inflando a escala e
    # tornando os passos com dado real visualmente incomparáveis.
    vmax_si_global = FIELD_META['Si_ifrac']['vmax_plot']   # padrão: 1.0
    _si_arr = data.get('Si_ifrac')
    if _si_arr is not None:
        real_maxes = []
        for _i in range(len(steps)):
            if _is_bootstrap_step(data, _i):
                continue   # ignora restart SIS2
            _layer_si = _si_arr[_i]
            _flat_si  = (_layer_si.compressed()
                         if hasattr(_layer_si, 'compressed')
                         else np.asarray(_layer_si).ravel())
            if _flat_si.size > 0:
                real_maxes.append(float(np.max(_flat_si)))
        if real_maxes:
            # Usa o máximo real; mínimo de 0.01 para campos com gelo vestigial
            vmax_si_global = max(max(real_maxes), 0.01)

    # ── Pré-cálculo: persistência de Si_ifrac entre passos ────────────────────
    #
    # Contexto: com docn_ice_init_only=.true. (Sprint B.1), o modelo Fortran
    # chama compute_si_ifrac_proxy a partir de t=1 — que reinicia ptr_ifrac=0
    # sem memória do estado OISST de t=0 (7918 células).  Isso produz uma
    # queda abrupta de 7918→38 células no primeiro passo de acoplamento,
    # fisicamente impossível (BUG-MEM no Fortran, corrigido em v2.5).
    #
    # Enquanto o modelo não for recompilado e re-executado com a correção,
    # este bloco SIMULA a persistência no pós-processamento:
    #
    #   Si_ifrac_display(t) = max(Si_ifrac_raw(t),
    #                             Si_ifrac_display(t-1) × SI_IFRAC_VIS_DECAY)
    #
    # onde SI_IFRAC_VIS_DECAY = exp(-dt/τ) com τ=86400 s e dt=3600 s
    # (idêntico ao SI_IFRAC_DECAY do Fortran v2.5).
    # O campo do passo de bootstrap (t=0) inicializa a memória.
    SI_IFRAC_VIS_DECAY = 0.95924    # ≈ exp(-1/24)  — mesmo valor do Fortran
    si_display = None               # lista de arrays acumulados por passo
    if _si_arr is not None:
        si_acc_list  = []
        si_acc_prev  = None
        for _t in range(len(steps)):
            _raw = np.ma.array(_si_arr[_t], copy=True, dtype=float)
            if si_acc_prev is not None:
                # Aplicar decaimento e tomar máximo com o campo bruto
                _decayed = np.ma.array(si_acc_prev * SI_IFRAC_VIS_DECAY)
                _raw = np.ma.maximum(_raw, _decayed)
                # Clamp [0,1]
                np.ma.clip(_raw, 0.0, 1.0, out=_raw)
            si_acc_list.append(_raw)
            si_acc_prev = _raw
        si_display = si_acc_list
        # Atualizar vmax global incluindo os valores acumulados
        for _t in range(len(steps)):
            if _is_bootstrap_step(data, _t):
                continue
            _flat = (si_display[_t].compressed()
                     if hasattr(si_display[_t], 'compressed')
                     else np.asarray(si_display[_t]).ravel())
            if _flat.size > 0:
                vmax_si_global = max(vmax_si_global, float(np.max(_flat)), 0.01)

    ncols = 2
    nrows = (len(campos_disponiveis) + 1) // ncols

    for i, step in enumerate(steps):
        fig_h = 3.5 * nrows + 1.5
        kw = {'projection': ccrs.PlateCarree()} if HAS_CARTOPY else {}
        fig, axes = plt.subplots(nrows, ncols, figsize=(14, fig_h),
                                 subplot_kw=kw if HAS_CARTOPY else None)
        axes = np.array(axes).flatten()

        for ax_idx, fname in enumerate(campos_disponiveis):
            meta  = FIELD_META[fname]
            # Para Si_ifrac, usar o campo com persistência simulada (si_display)
            # em vez do campo bruto — mostra o comportamento esperado após a
            # correção Fortran BUG-MEM, mesmo antes da recompilação do modelo.
            if fname == 'Si_ifrac' and si_display is not None:
                layer = si_display[i] * meta['scale']
            else:
                layer = data[fname][i] * meta['scale']
            ax    = axes[ax_idx]

            nlat, nlon = layer.shape

            # Cobertura dinâmica deste passo (anotada no mapa).
            frac_dyn, _ = coverage_fraction(layer, fname)

            # --mask-default: oculta células no valor default (sem dado dinâmico),
            # tornando visível a faixa de cobertura parcial quando o bug de
            # mapeamento ainda estiver presente (antes de recompilar o cap).
            if mask_default:
                stub = meta.get('stub_value')
                if stub is not None:
                    tol   = COVER_TOL.get(fname, meta.get('stub_tol', 1e-6))
                    layer = np.ma.masked_where(np.abs(layer - stub) <= tol, layer)

            # BUG-03: usar lat/lon do NetCDF; fallback para linspace
            if (coords is not None
                    and len(coords['lat']) == nlat
                    and len(coords['lon']) == nlon):
                lats = coords['lat']
                lons = coords['lon']
            else:
                lats = np.linspace(-90,  90,  nlat)
                lons = np.linspace(-180, 180, nlon)
            lon2d, lat2d = np.meshgrid(lons, lats)

            vmin = meta['vmin_plot'] * meta['scale']
            vmax = meta['vmax_plot'] * meta['scale']

            # Escala robusta: se o passo tem dado dinâmico e a fração de células
            # saturadas nos limites fixos for alta (>20% em qualquer extremo),
            # reajusta vmin/vmax aos percentis 2–98 dos dados válidos. Evita o
            # mapa "tudo no extremo" (ex.: passo bootstrap ou campo concentrado),
            # revelando o gradiente real. Não altera dados nem limites físicos.
            flat_v = layer.compressed() if hasattr(layer, 'compressed') \
                     else np.asarray(layer).ravel()
            uniforme = is_uniform(layer, fname)
            if (not uniforme and flat_v.size > 0 and fname != 'Sf_zorl'):
                sat_lo = float(np.mean(flat_v <= vmin))
                sat_hi = float(np.mean(flat_v >= vmax))
                if sat_lo > 0.20 or sat_hi > 0.20:
                    p2, p98 = np.percentile(flat_v, [2, 98])
                    if p98 > p2:
                        vmin, vmax = float(p2), float(p98)

            # BUG-10 (corrigido): escala Si_ifrac consistente entre passos.
            # BUG-02 (v2.2) usava vmax adaptativo por passo; isso tornava
            # os passos com pouco gelo real (vmax≈0.12) incomparáveis com o
            # passo de restart do SIS2 (vmax=1.0).  Agora usa vmax_si_global
            # pré-calculado excluindo passos de bootstrap.
            if fname == 'Si_ifrac':
                vmax = vmax_si_global
                vmin = 0.0

            norm = (LogNorm(vmin=max(vmin, 1e-6), vmax=vmax)
                    if fname == 'Sf_zorl'
                    else mcolors.Normalize(vmin=vmin, vmax=vmax))

            if HAS_CARTOPY:
                cf = ax.pcolormesh(lon2d, lat2d, layer, norm=norm,
                                   cmap=meta['cmap'], transform=ccrs.PlateCarree(),
                                   shading='auto', zorder=1)
                # BUG-PLOT-LAND: terra DESENHADA ACIMA do dado (zorder alto).
                ax.add_feature(cfeature.LAND, facecolor='lightgray', zorder=5)
                ax.add_feature(cfeature.COASTLINE, linewidth=0.5,
                               edgecolor='black', zorder=6)
                ax.set_global()

                # ── Scatter overlay para Si_ifrac esparso ──────────────────
                # pcolormesh renderiza células de 1°×1° como pixels de ~1-2 px
                # na escala global — invisíveis quando n < ICE_SCATTER_THRESHOLD.
                # Marcadores scatter com tamanho fixo garantem legibilidade.
                #
                # BUG-SCATTER-ZORDER (corrigido v2.4):
                #   zorder=4 colocava o scatter ABAIXO da camada de terra
                #   (cfeature.LAND, zorder=5), que a sobrepunha completamente.
                #   Correção: zorder=8, acima de terra (5) e costa (6).
                if fname == 'Si_ifrac' and not uniforme:
                    flat_si = (layer.compressed()
                               if hasattr(layer, 'compressed')
                               else np.asarray(layer).ravel())
                    n_ice_scatter = int(np.sum(flat_si > IFRAC_ICE_ANN_THR))
                    if 0 < n_ice_scatter < ICE_SCATTER_THRESHOLD:
                        ice_mask_2d = np.ma.filled(
                            layer > IFRAC_ICE_ANN_THR, False)
                        sc_lons = lon2d[ice_mask_2d]
                        sc_lats = lat2d[ice_mask_2d]
                        # np.ma.filled garante valores reais (sem fill_value)
                        # para células de gelo mesmo em masked arrays.
                        sc_vals = np.ma.filled(layer, 0.0)[ice_mask_2d]
                        if sc_lons.size > 0:
                            ax.scatter(sc_lons, sc_lats,
                                       c=sc_vals, cmap=meta['cmap'], norm=norm,
                                       s=ICE_SCATTER_SIZE,
                                       transform=ccrs.PlateCarree(),
                                       edgecolors='steelblue',
                                       linewidths=0.5,
                                       alpha=0.90,
                                       zorder=8)  # acima de terra(5) e costa(6)
            else:
                cf = ax.pcolormesh(lon2d, lat2d, layer, norm=norm,
                                   cmap=meta['cmap'], shading='auto')

            # Rótulo da colorbar: Si_ifrac sempre mostra o vmax efetivo usado
            cbar_lbl = (f"{meta['scale_units']} (vmax={vmax:.3f})"
                        if fname == 'Si_ifrac'
                        else meta['scale_units'])
            plt.colorbar(cf, ax=ax, shrink=0.8, pad=0.02, label=cbar_lbl)

            ts_str = tss[i].strftime('%Y-%m-%d %H:%M') if tss[i] else f'passo {step}'
            # Para Sf_zorl inferida, incluir nota na legenda
            if fname == 'Sf_zorl' and 'FONTE 2' in fonte_label:
                title = f"Sf_zorl (inferido)\n{ts_str}"
            else:
                title = f"{meta['long_name']}\n{ts_str}"
            ax.set_title(title, fontsize=8)

            # ── Anotação inferior esquerda: cobertura / restart ───────────────
            # Si_ifrac em passo de bootstrap: contém restart do SIS2, não dado
            # de acoplamento real → rótulo específico "restart SIS2 (t=0)".
            is_boot_step = _is_bootstrap_step(data, i)
            if fname == 'Si_ifrac' and is_boot_step:
                cov_txt   = 'restart SIS2 (t=0)'
                cov_color = 'darkorange'
            elif uniforme:
                cov_txt, cov_color = 'bootstrap t=0 (uniforme)', 'dimgray'
            else:
                cov_color = 'darkred' if frac_dyn < 0.60 else 'black'
                cov_txt = f"cobertura dinâmica: {frac_dyn*100:.0f}%"
            ax.text(0.01, 0.02, cov_txt,
                    transform=ax.transAxes, fontsize=7, color=cov_color,
                    va='bottom', ha='left', zorder=7,
                    bbox=dict(boxstyle='round,pad=0.2', fc='white',
                              ec=cov_color, alpha=0.75))

            # ── Anotação inferior direita: contagem e máximo de gelo ──────────
            # Informa quantas células oceânicas excedem IFRAC_ICE_ANN_THR e o
            # valor máximo do campo — útil para acompanhar a fusão entre passos.
            if fname == 'Si_ifrac':
                flat_si = layer.compressed() if hasattr(layer, 'compressed') \
                          else np.asarray(layer).ravel()
                n_ice  = int(np.sum(flat_si > IFRAC_ICE_ANN_THR))
                mx_ice = float(flat_si.max()) if flat_si.size > 0 else 0.0
                # Sufixo "acc" indica que o campo usa persistência simulada
                acc_tag = ' [acc]' if (si_display is not None
                                       and not _is_bootstrap_step(data, i)) else ''
                ice_ann = (f'n={n_ice:,} cél > {IFRAC_ICE_ANN_THR:.2f}'
                           f'  |  max={mx_ice:.3f}{acc_tag}')
                ax.text(0.99, 0.02, ice_ann,
                        transform=ax.transAxes, fontsize=7, color='navy',
                        va='bottom', ha='right', zorder=7,
                        bbox=dict(boxstyle='round,pad=0.2', fc='white',
                                  ec='steelblue', alpha=0.75))

        for k in range(len(campos_disponiveis), len(axes)):
            axes[k].set_visible(False)

        ts_str = tss[i].strftime('%Y-%m-%d %H:%M') if tss[i] else f'passo {step}'
        fig.suptitle(
            f"MONAN-A 2.0 — Campos importados MED→MPAS\n"
            f"{ts_str}  |  {fonte_label}  |  INPE/CGCT/DIMNT",
            fontsize=9
        )
        fig.tight_layout()

        ts_tag = tss[i].strftime('%Y%m%d_%H%M%S') if tss[i] else f'step{step:04d}'
        outfile = os.path.join(outdir, f'monan2_import_{ts_tag}.png')
        fig.savefig(outfile, dpi=120, bbox_inches='tight', facecolor='white')
        plt.close(fig)
        print(f"  Figura: {outfile}")


def plot_timeseries(steps, data, tss, outdir, fonte_label):
    """Gera série temporal das médias globais."""
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        return

    os.makedirs(outdir, exist_ok=True)
    campos_disponiveis = [f for f in FIELDS if data.get(f) is not None]
    if not campos_disponiveis:
        return

    fig, axes = plt.subplots(len(campos_disponiveis), 1,
                             figsize=(10, 4 * len(campos_disponiveis)),
                             sharex=True)
    if len(campos_disponiveis) == 1:
        axes = [axes]

    x_vals = [tss[i] if tss[i] else i + 1 for i in range(len(steps))]

    for ax, fname in zip(axes, campos_disponiveis):
        meta   = FIELD_META[fname]
        scale  = meta['scale']

        # Para Si_ifrac, aplicar a mesma persistência simulada do plot_maps,
        # para que a série temporal reflita o comportamento esperado com BUG-MEM fix.
        if fname == 'Si_ifrac':
            SI_IFRAC_VIS_DECAY = 0.95924
            arr_acc = []
            prev    = None
            for t in range(len(steps)):
                raw_t = np.ma.array(data[fname][t], copy=True, dtype=float)
                if prev is not None:
                    raw_t = np.ma.maximum(raw_t,
                                          np.ma.array(prev * SI_IFRAC_VIS_DECAY))
                    np.ma.clip(raw_t, 0.0, 1.0, out=raw_t)
                arr_acc.append(raw_t)
                prev = raw_t
            arr = arr_acc
        else:
            arr = data[fname]

        # _masked_to_float: usa np.ma.filled(x, NaN) em vez de float() direto,
        # evitando UserWarning quando o passo está totalmente mascarado (t=0).
        means  = [_masked_to_float((arr[i] * scale).mean()) for i in range(len(steps))]
        maxs   = [_masked_to_float((arr[i] * scale).max())  for i in range(len(steps))]
        mins   = [_masked_to_float((arr[i] * scale).min())  for i in range(len(steps))]

        ax.fill_between(x_vals, mins, maxs, alpha=0.15, color='steelblue',
                        label='min-max')
        ax.plot(x_vals, means, 'o-', color='steelblue', lw=1.8, ms=5,
                label='média global')

        stub = meta.get('stub_value')
        if stub is not None:
            ax.axhline(stub * scale, color='red', ls='--', lw=1,
                       label=f'stub = {stub * scale:.4g} {meta["scale_units"]}')

        if fname == 'Sf_zorl':
            ax.set_yscale('log')

        title = meta['long_name']
        if fname == 'Sf_zorl' and 'FONTE 2' in fonte_label:
            title += ' (inferido de Foxx_taux/tauy)'
        ax.set_title(title, fontsize=9)
        ax.set_ylabel(meta['scale_units'], fontsize=9)
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)

    axes[-1].set_xlabel('Tempo')
    fig.suptitle(
        f'MONAN-A 2.0 — Série temporal MED→MPAS\n{fonte_label}  |  INPE/CGCT/DIMNT',
        fontsize=10
    )
    fig.tight_layout()

    outfile = os.path.join(outdir, 'monan2_import_timeseries.png')
    fig.savefig(outfile, dpi=120, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print(f"  Série temporal: {outfile}")


# ─── Verificação de log ───────────────────────────────────────────────────────

def check_log(logfile):
    """Verifica evidências do conector MED→MPAS no log ESMF."""
    print()
    print(f"  {'─' * 70}")
    print(f"  [FONTE 3] Verificação do log ESMF")
    print(f"  {'─' * 70}")
    print(f"  Log: {logfile}")

    if not os.path.isfile(logfile):
        print(f"  AVISO: log não encontrado — '{logfile}'")
        return

    padroes = {
        'sprint_c':            'Sprint C: Sf_zorl calculado via Charnock',
        'importacao_completa': '(So_t + Si_ifrac + So_u + So_v + Sf_zorl)',
        'route_ocn_atm':       'RouteOcnToAtm: regrid OCN->ATM concluido',
        # A rotina registra "(write_mpas_import_diag): escrito <arquivo>" no log
        # ESMF (subname entre parênteses) e/ou "[DIAG-IMPORT] mpas_import_step"
        # em stdout. Detectamos por SUBSTRING do nome da rotina, robusto à
        # pontuação (parênteses) e ao texto ao redor.
        'diag_escrito':     '[DIAG-IMPORT] mpas_import_step',
        'diag_escrito_leg': 'write_mpas_import_diag',
    }

    labels = {
        'sprint_c':            '"Sprint C: Sf_zorl calculado via Charnock+Smith"',
        'importacao_completa': '"(So_t + Si_ifrac + So_u + So_v + Sf_zorl)"',
        'route_ocn_atm':       '"RouteOcnToAtm: regrid OCN->ATM concluido"',
        'diag_escrito':     '"[DIAG-IMPORT] mpas_import_step" (stdout v4.13+)',
        'diag_escrito_leg': '"write_mpas_import_diag: escrito" (ESMF log)',
    }

    found   = {k: [] for k in padroes}
    # BUG-06: buscar também em stdout do mpirun (write(*,...) vai para stdout)
    logfiles_busca = [logfile]
    for pat in ('logs/PET*.STDOUT', 'logs/stdout*', 'logs/mpirun*.log'):
        logfiles_busca.extend(glob.glob(pat))
    seen_lf = set()
    logfiles_busca = [f for f in logfiles_busca if not (f in seen_lf or seen_lf.add(f))]

    for lf in logfiles_busca:
        if not os.path.isfile(lf):
            continue
        with open(lf, 'r', errors='replace') as f:
            for i, line in enumerate(f, 1):
                for key, pat in padroes.items():
                    if pat in line:
                        found[key].append((i, line.rstrip()))

    for key in ('sprint_c', 'importacao_completa', 'route_ocn_atm'):
        n = len(found[key])
        status = '✓' if n > 0 else '✗'
        print(f"  {status} {labels[key]:52s}: {n} ocorrência(s)")
    n_diag = len(found['diag_escrito']) + len(found.get('diag_escrito_leg', []))
    status = '✓' if n_diag > 0 else '✗'
    lbl_diag = '"write_mpas_import_diag" (stdout ou ESMF log)'
    print(f"  {status} {lbl_diag:52s}: {n_diag} ocorrência(s)")

    n_sprint = len(found['sprint_c'])
    n_import = len(found['importacao_completa'])
    if n_sprint > 0:
        print(f"  ✓ Sprint C ativo ({n_sprint} passos confirmados)")
    if n_import > 0:
        print(f"  ✓ Importação Sf_zorl no MPAS confirmada ({n_import} passos)")

    # Mostrar até 5 exemplos de cada padrão encontrado
    for key in ('sprint_c', 'importacao_completa'):
        for lineno, text in found[key][:5]:
            print(f"    L{lineno}: {text}")

    if n_sprint == 0:
        print("  ⚠  Sprint C não encontrado — MED pode estar usando versão anterior")
        print("     sem parametrização Charnock+Smith. Recompilar com MED_cap_MONAN.F90")
        print("     atualizado.")
    if n_import == 0:
        print("  ⚠  mpas_import não encontrado — verificar se mpas_cap_methods.F90")
        print("     está compilado com a versão atualizada.")
    if n_diag == 0:
        print("  ⚠  write_mpas_import_diag não localizado por string no log.")
        print("     Observação: se os arquivos mpas_import_step*.nc existem em")
        print("     diag_import/, a rotina ESTÁ rodando (a ausência no log é só")
        print("     falha de correspondência de texto, não de execução).")
        print("     Para confirmar a VERSÃO compilada, verifique o atributo global")
        print("     'source'/'code_version' dos NetCDF: ncdump -h mpas_import_step0003.nc")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Diagnóstico dos campos importados pelo MONAN-A via MED→MPAS.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument('--diagdir', default='diag_import',
                        help='Diretório com diagnósticos (padrão: diag_import)')
    parser.add_argument('--outdir',  default='diag_import/postproc',
                        help='Saída: figuras (padrão: diag_import/postproc)')
    parser.add_argument('--logfile', default='logs/PET0.esmApp.log',
                        help='Log ESMF (padrão: logs/PET0.esmApp.log)')
    parser.add_argument('--stats',  action='store_true', help='Estatísticas por passo')
    parser.add_argument('--check',  action='store_true', help='Verificação física')
    parser.add_argument('--plot',   action='store_true', help='Mapas e série temporal')
    parser.add_argument('--log',    action='store_true', help='Verificar log ESMF')
    parser.add_argument('--mask-default', dest='mask_default', action='store_true',
                        help='Oculta células no valor default nos mapas '
                             '(evidencia cobertura parcial / bug de import)')
    args = parser.parse_args()

    run_all = not (args.stats or args.check or args.plot or args.log)

    print()
    print('══' * 36)
    print('  Diagnóstico MED→MPAS: So_t | Si_ifrac | Sf_zorl')
    print('  INPE / CGCT / DIMNT — GT Acoplamento MONAN  (v2.0)')
    print('══' * 36)

    # FONTE 3 primeiro: verifica log independentemente dos dados
    if run_all or args.log:
        check_log(args.logfile)

    # Carregar dados (FONTE 1 ou FONTE 2)
    if run_all or args.stats or args.check or args.plot:
        print()
        print(f"  {'─' * 70}")
        print(f"  Carregando dados de '{args.diagdir}'...")

        steps, data, tss, fonte_label, coords = load_data(args.diagdir)

        print(f"  {'─' * 70}")
        print(f"  Fonte               : {fonte_label}")
        print(f"  Arquivos encontrados: {len(steps)} passo(s)")
        ts_ini = tss[0].strftime('%Y-%m-%d %H:%M:%S') if tss[0] else str(steps[0])
        ts_fim = tss[-1].strftime('%Y-%m-%d %H:%M:%S') if tss[-1] else str(steps[-1])
        print(f"  Período             : {ts_ini} → {ts_fim}")

        if run_all or args.stats:
            print_stats(steps, data, tss, fonte_label)

        if run_all or args.check:
            check_physics(steps, data, fonte_label, coords)

        if run_all or args.plot:
            print(f"\n  Gerando figuras ({len(steps)} passo(s))...")
            os.makedirs(args.outdir, exist_ok=True)
            plot_maps(steps, data, tss, args.outdir, fonte_label, coords,
                      mask_default=args.mask_default)
            plot_timeseries(steps, data, tss, args.outdir, fonte_label)

    print()
    print('══' * 36)
    print('  Concluído.')
    print('══' * 36)
    print()


if __name__ == '__main__':
    main()
