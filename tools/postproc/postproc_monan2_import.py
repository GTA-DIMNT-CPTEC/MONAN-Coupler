#!/usr/bin/env python3
"""
postproc_monan2_import.py — Diagnóstico dos campos importados pelo MONAN-A 2.0
                            via conector MED→MPAS (So_t, Si_ifrac, Sf_zorl)

Versão 3.2 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Setembro 2026

═══════════════════════════════════════════════════════════════════════════════
CORREÇÕES v3.2
═══════════════════════════════════════════════════════════════════════════════

BUG-16  Marcador de terra por temperatura tornado desnecessário
  Contexto: BUG-14 (abaixo) já registrava que a correção definitiva era o
    lado Fortran gravar _FillValue sobre continente. Isso foi feito
    (MASCARA-CONT-02, mpas_cap_netcdf.F90): monan2_import_*.nc agora mascara
    continente com a máscara nativa do MPAS (xland), não por faixa física, e
    passa a incluir a variável 'ocn_frac' com a fração de células Voronoi
    oceânicas usada nessa decisão.
  Efeito neste script: --land-marker passa a ser DESLIGADO por padrão nos
    arquivos novos, que já chegam com _FillValue real sobre terra. Arquivos
    gerados ANTES desta revisão do acoplador (sem 'ocn_frac') continuam
    precisando do marcador — religue com --legacy-land-marker.

═══════════════════════════════════════════════════════════════════════════════
CORREÇÕES v3.1
═══════════════════════════════════════════════════════════════════════════════

Uma figura para CADA saída NetCDF, sem crescimento de memória
  A v3.0 limitava os mapas a uma amostra (--max-maps 12) porque as camadas dos
  passos a plotar ficavam retidas até o fim da leitura.  Isso deixava o
  anim_monan2_import.py sem quadros suficientes.
  Mudanças:
    • o processamento passou a ter duas passagens de leitura, ambas em fluxo:
      a primeira calcula as estatísticas de todos os passos (nada da série
      fica retido, exceto os campos do último arquivo, de que o localizador
      de listra precisa); a segunda relê os arquivos e desenha um mapa por
      vez (classe RenderizadorMapas), descartando o campo em seguida.  A
      escala de Si_ifrac, que precisa ser a mesma em todos os passos, vem da
      primeira passagem;
    • sem --si-persist, a segunda passagem relê apenas os arquivos que virarão
      figura; com --si-persist ela percorre a sequência completa, porque o
      acumulador depende da ordem, mas mantém só uma camada em memória;
    • o padrão de --max-maps passou de 12 para 0 (sem teto): por padrão sai
      uma figura por arquivo de diagnóstico;
    • --all-steps foi mantido apenas por compatibilidade e não altera nada;
    • --dpi permite reduzir a resolução das figuras.
  Medido em 240 arquivos numa grade 360x180: 240 figuras geradas em 124 s com
  pico de 312 MiB, constante em relação ao número de passos.

═══════════════════════════════════════════════════════════════════════════════
CORREÇÕES v3.0
═══════════════════════════════════════════════════════════════════════════════

BUG-12  Consumo de memória e de tempo proporcional ao número de passos
  Sintoma: o script não conclui quando executado sobre o intervalo completo
    de integração.
  Causa  : duas somadas.
    (a) _load_fonte1/_load_fonte2 empilhavam TODOS os passos em memória
        (np.ma.stack) e plot_maps ainda criava uma segunda pilha completa
        para a persistência simulada de Si_ifrac.
    (b) plot_maps percorria todos os passos sem qualquer amostragem: uma
        figura de três painéis com cartopy por passo de acoplamento.  Numa
        integração de 30 dias com dt_coupling=1 h são 720 figuras.
  Correção: leitura em uma passagem, um arquivo por vez; estatísticas por
    passo guardadas como escalares; apenas os passos a plotar ficam
    residentes como campos 2-D em float32.  Seleção de passos por --step,
    --all-steps, --stride, --tmin/--tmax e teto --max-maps (padrão 12).

BUG-13  Desalinhamento silencioso entre passos e camadas
  Sintoma: figura rotulada com a data errada, ou IndexError, quando algum
    arquivo não contém um dos campos.
  Causa  : os loaders faziam np.ma.stack apenas sobre as camadas presentes
    ("valid"), mas as listas steps e timestamps continham todos os arquivos.
    A partir do primeiro arquivo incompleto, data[campo][i] deixava de
    corresponder a steps[i].
  Correção: passo sem o campo vira lacuna explícita (None) na série, sem
    encolher o eixo temporal, e o script avisa quantos passos foram afetados.

BUG-14  Marcador de terra removia SST oceânica real (buracos nas figuras)
  Sintoma: manchas brancas no mapa de So_t exatamente onde há gelo marinho
    (Ártico, Mar de Weddell, Mar de Ross, Baía de Hudson), propagadas para o
    Sf_zorl pela máscara compartilhada.
  Causa  : o marcador de terra do Sprint A.5 vale 271,35 K, que é o ponto de
    congelamento da água do mar com S≈35.  A tolerância de ±0,02 K descartava
    toda a SST sob gelo marinho, que se acumula justamente nessa faixa.
  Correção: o marcador passa a ser reconhecido por igualdade aproximada com
    tolerância de 1e-4 K (representação float32 do valor gravado), e o número
    de células removidas é reportado.  --no-land-marker desativa a remoção.
  Observação para o lado Fortran: a solução definitiva é o MED gravar
    _FillValue no NetCDF em vez de usar um valor fisicamente válido.

BUG-15  Persistência simulada de Si_ifrac exibida como se fosse dado
  Sintoma: o mapa e a série temporal mostravam um campo de gelo que o modelo
    não produziu, com anotação discreta "[acc]" no canto da figura.
  Causa  : plot_maps aplicava, por padrão, a recorrência
    Si_ifrac(t) = max(Si_ifrac_bruto(t), Si_ifrac(t-1) * 0,95924) para
    compensar o BUG-MEM do Fortran.
  Correção: a persistência passa a ser opcional (--si-persist).  Por padrão o
    script exibe o campo bruto.  Quando ativada, o título de cada painel e o
    rótulo do eixo trazem "persistência simulada", e as tabelas de
    estatísticas e a verificação física continuam usando sempre o campo bruto.

BUG-16  Ausência de dado indistinguível de valor nulo nas figuras
  Correção: cor explícita para célula sem dado (cinza claro) via set_bad() e
    facecolor do eixo; fração de células sem dado impressa no título de cada
    painel.

BUG-17  Falha de rede do cartopy em nó de execução sem internet
  Correção: disponibilidade das feições do Natural Earth testada uma única vez;
    sem elas as figuras são geradas sem contorno de costa, com aviso, em vez
    de abortar na gravação.

BUG-18  FONTE 1 limitada a quatro dígitos e a um único padrão de nome
  Correção: aceita mpas_import_step*.nc com qualquer número de dígitos e
    também monan2_import_YYYYMMDD_HHMMSS.nc, que é o padrão citado pelo
    anim_monan2_import.py.  Com o padrão datado, o carimbo de tempo passa a
    existir também na FONTE 1.

BUG-19  Verificação física ilegível em integrações longas
  Correção: a listagem por passo passa a respeitar --max-rows (padrão 40),
    imprimindo o início e o fim da série e um resumo agregado no meio.

═══════════════════════════════════════════════════════════════════════════════
HISTÓRICO ANTERIOR (resumido)
═══════════════════════════════════════════════════════════════════════════════
  v2.4  BUG-SCATTER-ZORDER: scatter de Si_ifrac acima da camada de terra
  v2.3  BUG-11: scatter overlay para Si_ifrac esparso
  v2.2  BUG-10: escala de Si_ifrac consistente entre passos
  v2.1  BUG-LAND-FONTE2: máscara de terra no So_t e no Sf_zorl inferido
  v2.0  BUG-01..04: rótulo da fonte, coordenadas do NetCDF, fill do Fortran

═══════════════════════════════════════════════════════════════════════════════
Contexto
═══════════════════════════════════════════════════════════════════════════════

O MONAN-A recebe do mediador, a cada passo de acoplamento:
  So_t      SST [K]              — ocean_public%t_surf do MOM6
  Si_ifrac  fração de gelo [0-1] — SIS2 / proxy sigmoide do mom_cap
  So_u      corrente zonal       — inspecionável via log ESMF
  So_v      corrente meridional  — inspecionável via log ESMF
  Sf_zorl   rugosidade [m]       — Charnock+Smith calculado no MED (Sprint C)

Fontes de dados, usadas automaticamente conforme a disponibilidade:

  FONTE 1 — monan2_import_YYYYMMDD_HHMMSS.nc  ou  mpas_import_step*.nc
    Escrita direta do importState do MPAS (write_mpas_import_diag).
    Contém So_t, Si_ifrac e Sf_zorl lidos do próprio importState.

  FONTE 2 — mom6_import_*.nc
    So_t e Si_ifrac lidos diretamente do diagnóstico do mediador.
    Sf_zorl INFERIDO de Foxx_taux/Foxx_tauy via Charnock+Smith:
    u*=√(|τ|/ρ), z₀=α·u*²/g + β·ν/u*

  FONTE 3 — logs/PET0.esmApp.log
    Evidências qualitativas de que Sprint C e mpas_import estão ativos.

═══════════════════════════════════════════════════════════════════════════════
Uso
═══════════════════════════════════════════════════════════════════════════════
  python3 postproc_monan2_import.py                      # todos os modos
  python3 postproc_monan2_import.py --stats              # só estatísticas
  python3 postproc_monan2_import.py --check              # só verificação física
  python3 postproc_monan2_import.py --plot               # só mapas
  python3 postproc_monan2_import.py --log                # só verificação de log
  python3 postproc_monan2_import.py --plot               # uma figura por arquivo
  python3 postproc_monan2_import.py --plot --max-maps 8  # só uma amostra
  python3 postproc_monan2_import.py --tmin 2026-03-29 --tmax 2026-03-31

Dependências obrigatórias: numpy, netCDF4
Dependências opcionais   : matplotlib, cartopy  (para --plot)
"""

import sys
import os
import glob
import re
import argparse
from datetime import datetime

import numpy as np

try:
    from netCDF4 import Dataset
except ImportError:
    sys.exit("ERRO: netCDF4 não encontrado. Instalar: pip install --user netCDF4")

# ─── Constantes físicas (Charnock + Smith 1988) ───────────────────────────────
_ALPHA = 0.018          # constante de Charnock
_BETA = 0.11            # constante de Smith
_G = 9.81               # m/s²
_NU = 1.5e-5            # viscosidade cinemática do ar [m²/s]
_RHO = 1.225            # densidade do ar [kg/m³]
_USTAR_MIN = 1e-4       # evita divisão por zero

# Marcador de terra gravado pelo MED (Sprint A.5).  Ver BUG-14: a tolerância
# é estreita de propósito, porque o valor coincide com o ponto de congelamento
# da água do mar e a SST sob gelo marinho fica legitimamente nessa faixa.
_LAND_FILL_K = 271.35
_LAND_FILL_ATOL = 1.0e-4

# Limiar defensivo para valores de preenchimento do Fortran (-9.99e+20).
_FILL_THR = 1e19

# Cor de célula sem dado (distingue "ausente" de "zero").
NODATA_COLOR = '#d9d9d9'


def _infer_z0(taux, tauy):
    """Infere Sf_zorl de Foxx_taux/Foxx_tauy via Charnock+Smith."""
    tau = np.sqrt(np.maximum(taux**2 + tauy**2, 0.0))
    ustar = np.maximum(np.sqrt(tau / _RHO), _USTAR_MIN)
    z0 = _ALPHA * ustar**2 / _G + _BETA * _NU / ustar
    return np.clip(z0, 1e-5, 0.1)


# ─── Metadados dos campos ─────────────────────────────────────────────────────

FIELD_META = {
    'So_t': {
        'long_name': 'SST dinâmica MOM6 (So_t)',
        'scale_units': 'K',
        'scale': 1.0,
        'cmap': 'RdBu_r',
        # Faixa de PLOT estreitada à banda onde a SST tem gradiente real.
        'vmin_plot': 273.0,
        'vmax_plot': 303.0,
        'vmin_phys': 270.0,
        'vmax_phys': 310.0,
        'stub_value': 298.0,    # cfg_sst_default (bootstrap t=0)
        'stub_tol': 0.01,
    },
    'Si_ifrac': {
        'long_name': 'Fração de gelo marinho (Si_ifrac)',
        'scale_units': '[0-1]',
        'scale': 1.0,
        'cmap': 'Blues',
        'vmin_plot': 0.0,
        'vmax_plot': 1.0,
        'vmin_phys': 0.0,
        'vmax_phys': 1.0,
        # stub_value=None: zero é valor físico válido (oceano sem gelo).
        'stub_value': None,
        'stub_tol': 1e-6,
    },
    'Sf_zorl': {
        'long_name': 'Rugosidade superficial Charnock+Smith (Sf_zorl)',
        'scale_units': 'm',
        'scale': 1.0,
        'cmap': 'YlOrRd',
        'vmin_plot': 1e-5,
        'vmax_plot': 1e-2,
        'vmin_phys': 1e-5,    # Z0_MIN — clamp em mpas_import
        'vmax_phys': 0.1,     # Z0_MAX — clamp em mpas_import
        'stub_value': 0.01,   # zorl_default anterior ao Sprint C
        'stub_tol': 1e-5,
        'calm_max': 5e-4,     # mar calmo: z0 < 5e-4 m (vento < 10 m/s)
        'storm_min': 1e-3,    # tempestade: z0 > 1e-3 m (vento > 15 m/s)
    },
}

FIELDS = list(FIELD_META.keys())

# Uma célula está "no default" se |valor − stub_value| <= COVER_TOL; a fração
# complementar é a cobertura dinâmica.  Um campo espacialmente UNIFORME não
# carrega informação dinâmica (bootstrap t=0) e recebe cobertura 0%.
COVER_TOL = {'So_t': 0.05, 'Sf_zorl': 5e-4}

# Limiar de Si_ifrac para contar células com gelo na anotação do mapa.
IFRAC_ICE_ANN_THR = 0.01

# Abaixo deste número de células com gelo, pcolormesh renderiza a célula de
# 1°x1° como um pixel praticamente invisível na escala global; um scatter com
# marcador de tamanho fixo é sobreposto para garantir legibilidade.
ICE_SCATTER_THRESHOLD = 2000
ICE_SCATTER_SIZE = 80

# Persistência simulada de Si_ifrac (opcional, --si-persist): exp(-dt/τ) com
# τ=86400 s e dt=3600 s, idêntico ao SI_IFRAC_DECAY do Fortran v2.5.
SI_IFRAC_VIS_DECAY = 0.95924


# ─── Descoberta da fonte ──────────────────────────────────────────────────────

def descobrir_fonte(diagdir):
    """
    Escolhe a fonte de dados disponível e devolve (fonte, arquivos, carimbos).

    Ordem de preferência:
      1a. monan2_import_YYYYMMDD_HHMMSS.nc  (escrita direta, com carimbo)
      1b. mpas_import_step*.nc              (escrita direta, por contador)
      2.  mom6_import_YYYYMMDD_HHMMSS.nc    (Sf_zorl inferido)

    fonte é uma das strings 'F1_TS', 'F1_STEP', 'F2'.
    carimbos é lista de datetime (ou None quando o padrão não tem data).
    """
    # FONTE 1a
    arqs = sorted(glob.glob(os.path.join(diagdir, 'monan2_import_*.nc')))
    pares = []
    for f in arqs:
        ts = _ts_de_nome(f, 'monan2_import_')
        if ts is not None:
            pares.append((ts, f))
    if pares:
        pares.sort(key=lambda p: p[0])
        return 'F1_TS', [f for _, f in pares], [ts for ts, _ in pares]

    # FONTE 1b
    arqs = glob.glob(os.path.join(diagdir, 'mpas_import_step*.nc'))
    pares = []
    for f in arqs:
        m = re.search(r'mpas_import_step(\d+)\.nc$', os.path.basename(f))
        if m:
            pares.append((int(m.group(1)), f))
    if pares:
        pares.sort(key=lambda p: p[0])
        return 'F1_STEP', [f for _, f in pares], [None] * len(pares)

    # FONTE 2
    arqs = sorted(glob.glob(os.path.join(diagdir, 'mom6_import_*.nc')))
    pares = []
    for f in arqs:
        ts = _ts_de_nome(f, 'mom6_import_')
        if ts is not None:
            pares.append((ts, f))
    if pares:
        pares.sort(key=lambda p: p[0])
        return 'F2', [f for _, f in pares], [ts for ts, _ in pares]

    sys.exit(
        f"\nERRO: nenhum arquivo de diagnóstico encontrado em '{diagdir}'.\n"
        "Necessário pelo menos um dos seguintes:\n"
        "  FONTE 1: monan2_import_YYYYMMDD_HHMMSS.nc ou mpas_import_step*.nc\n"
        "    → requer compilação com write_mpas_import_diag e\n"
        "      write_import_diag=.true. em &nuopc_docn do nuopc.input\n"
        "  FONTE 2: mom6_import_YYYYMMDD_HHMMSS.nc\n"
        "    → requer write_import_diag=.true. em &nuopc_docn do nuopc.input\n"
    )


def _ts_de_nome(fpath, prefixo):
    """Extrai datetime de <prefixo>YYYYMMDD_HHMMSS.nc; None se não casar."""
    base = os.path.basename(fpath)
    if not base.startswith(prefixo) or not base.endswith('.nc'):
        return None
    try:
        return datetime.strptime(base[len(prefixo):-3], '%Y%m%d_%H%M%S')
    except ValueError:
        return None


def rotulo_fonte(fonte, arquivos):
    n = len(arquivos)
    if fonte == 'F1_TS':
        return f'FONTE 1 (monan2_import_*.nc, {n} passos)'
    if fonte == 'F1_STEP':
        p0 = os.path.basename(arquivos[0]).replace('.nc', '')
        p1 = os.path.basename(arquivos[-1]).replace('.nc', '')
        return (f'FONTE 1 ({p0}.nc)' if n == 1
                else f'FONTE 1 ({p0}..{p1}.nc, {n} passos)')
    return f'FONTE 2 (mom6_import_*.nc — Sf_zorl inferido, {n} passos)'


def parse_datahora(txt):
    if txt is None:
        return None
    for fmt in ('%Y-%m-%dT%H:%M:%S', '%Y-%m-%dT%H:%M', '%Y-%m-%d %H:%M:%S',
                '%Y-%m-%d %H:%M', '%Y-%m-%d'):
        try:
            return datetime.strptime(txt, fmt)
        except ValueError:
            continue
    sys.exit(f"ERRO: data/hora '{txt}' não reconhecida "
             f"(use YYYY-MM-DD ou YYYY-MM-DDTHH:MM).")


def filtrar_arquivos(arquivos, carimbos, tmin, tmax, stride):
    """Aplica janela temporal e amostragem."""
    idx = list(range(len(arquivos)))
    if tmin is not None or tmax is not None:
        if all(c is None for c in carimbos):
            print("  AVISO: --tmin/--tmax ignorados — a FONTE em uso não traz "
                  "carimbo de tempo no nome do arquivo.")
        else:
            if tmin is not None:
                idx = [i for i in idx if carimbos[i] is None or carimbos[i] >= tmin]
            if tmax is not None:
                idx = [i for i in idx if carimbos[i] is None or carimbos[i] <= tmax]
    if stride > 1:
        idx = idx[::stride]
    if not idx:
        sys.exit("ERRO: a janela temporal (--tmin/--tmax/--stride) não "
                 "selecionou nenhum arquivo.")
    return [arquivos[i] for i in idx], [carimbos[i] for i in idx]


def selecionar_passos_mapa(n_steps, lista_passos, max_maps):
    """
    Índices (base 0) dos passos que receberão mapa.

    O padrão é TODOS os passos: uma figura por saída NetCDF, que é o que os
    scripts de animação consomem.  --step restringe a passos específicos e
    --max-maps impõe um teto com amostragem uniforme.
    """
    if lista_passos:
        idx = [s - 1 for s in lista_passos]
    else:
        idx = list(range(n_steps))
    idx = sorted({int(min(max(s, 0), n_steps - 1)) for s in idx})
    if max_maps and 0 < max_maps < len(idx):
        print(f"  AVISO: {len(idx)} passo(s) selecionado(s); limitado a "
              f"{max_maps} figura(s) por --max-maps (padrão: sem teto).")
        pos = np.unique(np.linspace(0, len(idx) - 1, max_maps).astype(int))
        idx = [idx[i] for i in pos]
    return idx

# ─── Leitura de um passo ──────────────────────────────────────────────────────

def _ler_var(nc, nome, lat, lon):
    if nome not in nc.variables:
        return None
    arr = np.array(nc.variables[nome][:], dtype=np.float64)
    arr = orientar_lat_lon(arr, lat, lon)
    arr = np.where(np.abs(arr) > _FILL_THR, np.nan, arr)
    return arr


def orientar_lat_lon(arr, lat, lon):
    """
    Garante orientação (nlat, nlon), usando os tamanhos reais das coordenadas.

    O Fortran declara a variável com [dimid_lon, dimid_lat]; conforme a versão
    do escritor a leitura pode chegar transposta.  A heurística nlat<nlon só
    é usada quando as coordenadas não estão disponíveis.
    """
    if arr.ndim != 2:
        return arr
    if lat is not None and lon is not None:
        nlat, nlon = len(lat), len(lon)
        if arr.shape == (nlat, nlon):
            return arr
        if arr.shape == (nlon, nlat):
            return arr.T
        return arr
    return arr.T if arr.shape[0] > arr.shape[1] else arr


def ler_passo(fpath, fonte, coords, usar_marcador=True):
    """
    Lê um arquivo e devolve ({campo: array 2-D ou None}, coords, n_marcador).

    Na FONTE 2 o Sf_zorl é inferido de Foxx_taux/Foxx_tauy, e a máscara de
    terra derivada do So_t é propagada para a inferência: o bulk NCAR roda em
    todas as células, e sobre terra produz tensão anômala que infla o z₀.
    """
    campos = {f: None for f in FIELDS}
    n_marc = 0

    with Dataset(fpath) as nc:
        if coords is None:
            lat_nc = nc.variables['lat'][:] if 'lat' in nc.variables else None
            lon_nc = nc.variables['lon'][:] if 'lon' in nc.variables else None
            if lat_nc is not None and lon_nc is not None:
                coords = {'lat': np.asarray(lat_nc, dtype=float),
                          'lon': np.asarray(lon_nc, dtype=float)}
        lat = coords['lat'] if coords else None
        lon = coords['lon'] if coords else None

        # ── So_t ─────────────────────────────────────────────────────────────
        arr = _ler_var(nc, 'So_t', lat, lon)
        mask_terra = None
        if arr is not None:
            if usar_marcador:
                mask_terra = np.isclose(arr, _LAND_FILL_K, rtol=0.0,
                                        atol=_LAND_FILL_ATOL)
                n_marc = int(np.count_nonzero(mask_terra))
                arr = np.where(mask_terra, np.nan, arr)
            campos['So_t'] = arr

        # ── Si_ifrac ─────────────────────────────────────────────────────────
        campos['Si_ifrac'] = _ler_var(nc, 'Si_ifrac', lat, lon)

        # ── Sf_zorl ──────────────────────────────────────────────────────────
        if fonte in ('F1_TS', 'F1_STEP'):
            campos['Sf_zorl'] = _ler_var(nc, 'Sf_zorl', lat, lon)
        else:
            taux = _ler_var(nc, 'Foxx_taux', lat, lon)
            tauy = _ler_var(nc, 'Foxx_tauy', lat, lon)
            if taux is not None and tauy is not None:
                z0 = _infer_z0(taux, tauy)
                if mask_terra is not None:
                    z0 = np.where(mask_terra, np.nan, z0)
                campos['Sf_zorl'] = z0

    return campos, coords, n_marc


# ─── Estatística de uma camada ────────────────────────────────────────────────

def estatisticas_camada(arr, scale, fname):
    """Escalares de uma camada 2-D, já em unidades de exibição."""
    if arr is None:
        return None
    finito = np.isfinite(arr)
    n_ok = int(np.count_nonzero(finito))
    n_tot = int(arr.size)
    if n_ok == 0:
        return {'n_valid': 0, 'n_total': n_tot, 'cov': 0.0, 'uniforme': True}
    flat = arr[finito] * scale
    ptp = float(flat.max() - flat.min())
    tol = COVER_TOL.get(fname, FIELD_META[fname].get('stub_tol', 1e-6))
    uniforme = ptp <= tol

    stub = FIELD_META[fname].get('stub_value')
    if uniforme:
        frac_dyn = 0.0
    elif stub is None:
        frac_dyn = 1.0
    else:
        frac_dyn = 1.0 - float(np.mean(np.abs(flat - stub) <= tol))

    st = {
        'n_valid': n_ok, 'n_total': n_tot, 'cov': 100.0 * n_ok / max(n_tot, 1),
        'min': float(flat.min()), 'max': float(flat.max()),
        'mean': float(flat.mean()), 'std': float(flat.std()),
        'sum': float(flat.sum()), 'sumsq': float(np.dot(flat, flat)),
        'ptp': ptp, 'uniforme': uniforme, 'frac_dyn': frac_dyn,
    }
    if fname == 'Si_ifrac':
        st['n_ice'] = int(np.count_nonzero(flat > IFRAC_ICE_ANN_THR))
    if fname == 'Sf_zorl':
        meta = FIELD_META['Sf_zorl']
        st['frac_calm'] = float(np.mean(flat < meta['calm_max']))
        st['frac_storm'] = float(np.mean(flat > meta['storm_min']))
    return st


def _novo_agregado():
    return {'min': np.inf, 'max': -np.inf, 'sum': 0.0, 'sumsq': 0.0, 'n': 0}


def _acumular(agg, st):
    if st is None or st.get('n_valid', 0) == 0:
        return
    agg['min'] = min(agg['min'], st['min'])
    agg['max'] = max(agg['max'], st['max'])
    agg['sum'] += st['sum']
    agg['sumsq'] += st['sumsq']
    agg['n'] += st['n_valid']


def _contagem_frio(arr, lat_axis, freeze_k, lat_polar):
    """(n_frio, n_polar, n_baixa_lat, min_baixa_lat) para o campo So_t."""
    if arr is None:
        return 0, 0, 0, np.nan
    frio = np.isfinite(arr) & (arr < freeze_k)
    n_frio = int(np.count_nonzero(frio))
    if n_frio == 0 or lat_axis is None or arr.ndim != 2 \
            or lat_axis.size != arr.shape[0]:
        return n_frio, 0, 0, np.nan
    lat2d = np.broadcast_to(np.asarray(lat_axis)[:, None], arr.shape)
    polar = frio & (np.abs(lat2d) >= lat_polar)
    baixa = frio & (np.abs(lat2d) < lat_polar)
    n_baixa = int(np.count_nonzero(baixa))
    lo = float(arr[baixa].min()) if n_baixa else np.nan
    return n_frio, int(np.count_nonzero(polar)), n_baixa, lo


# ─── Leitura em uma passagem ──────────────────────────────────────────────────

def scan_arquivos(arquivos, fonte, usar_marcador=True, verbose=True):
    """
    Primeira passagem: percorre os arquivos calculando estatísticas por passo.

    Nada da série fica retido: só os campos do ÚLTIMO arquivo permanecem em
    memória, porque o localizador de listra precisa de uma camada 2-D.  O
    consumo de memória é, portanto, independente da duração da integração.

    Retorna (stats, agg, campos_ultimo, coords, diag)
    """
    stats = {f: [] for f in FIELDS}
    agg = {f: _novo_agregado() for f in FIELDS}
    ausentes = {f: 0 for f in FIELDS}
    campos_ultimo = {}
    frio = []
    n_marcador = 0
    coords = None

    n = len(arquivos)
    for k, fpath in enumerate(arquivos):
        if verbose and (n <= 20 or k % max(1, n // 20) == 0 or k == n - 1):
            print(f"\r  Lendo diagnósticos: {k+1:5d}/{n}  "
                  f"({100.0*(k+1)/n:5.1f}%)", end='', flush=True)

        campos, coords, n_marc = ler_passo(fpath, fonte, coords, usar_marcador)
        n_marcador += n_marc

        for fname in FIELDS:
            arr = campos[fname]
            if arr is None:
                ausentes[fname] += 1
            st = estatisticas_camada(arr, FIELD_META[fname]['scale'], fname)
            stats[fname].append(st)
            _acumular(agg[fname], st)

        lat_axis = coords['lat'] if coords else None
        frio.append(_contagem_frio(campos['So_t'], lat_axis, 271.35, 55.0))
        if k == n - 1:
            campos_ultimo = campos

    if verbose:
        print()

    for fname, n_aus in ausentes.items():
        if 0 < n_aus < n:
            print(f"  AVISO: campo '{fname}' ausente em {n_aus} de {n} arquivos "
                  f"— esses passos ficam como lacuna, sem deslocar a série "
                  f"(BUG-13).")

    diag = {'n_marcador': n_marcador, 'frio': frio, 'ausentes': ausentes}
    return stats, agg, campos_ultimo, coords, diag

# ─── Estatísticas ─────────────────────────────────────────────────────────────

def _rotulo_passo(tss, i):
    return tss[i].strftime('%Y-%m-%d %H:%M') if tss[i] else f'passo {i+1}'


def print_stats(stats, tss, fonte_label, max_rows=40):
    """Tabela de estatísticas por campo e passo."""
    sep = '─' * 91
    eh_fonte2 = 'FONTE 2' in fonte_label
    n = len(tss)

    print()
    print('═' * 72)
    print('  ESTATÍSTICAS — campos na grade MED —', fonte_label)
    print('═' * 72)

    if max_rows and n > max_rows:
        metade = max_rows // 2
        mostrar = list(range(metade)) + list(range(n - metade, n))
        corte = metade
    else:
        mostrar = list(range(n))
        corte = None

    for fname in FIELDS:
        meta = FIELD_META[fname]
        serie = stats.get(fname) or []
        if fname == 'Sf_zorl' and eh_fonte2:
            field_label = ('Sf_zorl  —  Rugosidade superficial Charnock+Smith '
                           '(inferida de Foxx_taux/tauy)')
        else:
            field_label = meta['long_name']

        if not serie or all(s is None for s in serie):
            print(f"\n  ┌─ {field_label}  [{meta['scale_units']}]")
            print("  │  (sem dados)")
            print(f"  └{'─' * 70}")
            continue

        print(f"\n  ┌─ {field_label}  [{meta['scale_units']}]")
        print(f"  │  {'Passo':>6}  {'Data/hora':<22}  {'Mínimo':>12}  {'Máximo':>12}  "
              f"{'Média':>12}  {'DesvPad':>10}  {'Cobert.':>8}")
        print(f"  │  {sep}")

        for pos, i in enumerate(mostrar):
            if corte is not None and pos == corte:
                print(f"  │  {'...':>6}  ({n - max_rows} passo(s) omitido(s); "
                      f"use --max-rows 0 para listar todos)")
            st = serie[i]
            rot = _rotulo_passo(tss, i)
            if st is None:
                print(f"  │  {i+1:>6}  {rot:<22}  {'(campo ausente)':>52}")
                continue
            if st['n_valid'] == 0:
                print(f"  │  {i+1:>6}  {rot:<22}  {'(sem dados)':>52}")
                continue
            print(f"  │  {i+1:>6}  {rot:<22}  {st['min']:>12.4f}  {st['max']:>12.4f}  "
                  f"{st['mean']:>12.4f}  {st['std']:>10.4f}  {st['cov']:>7.1f}%")

        validos = [s for s in serie if s and s.get('n_valid')]
        if validos:
            n_tot = sum(s['n_valid'] for s in validos)
            media = sum(s['sum'] for s in validos) / n_tot
            var = max(sum(s['sumsq'] for s in validos) / n_tot - media**2, 0.0)
            print(f"  │  {sep}")
            print(f"  │  {'SÉRIE':<6}  {'(todos os passos)':<22}  "
                  f"{min(s['min'] for s in validos):>12.4f}  "
                  f"{max(s['max'] for s in validos):>12.4f}  "
                  f"{media:>12.4f}  {np.sqrt(var):>10.4f}")
        print(f"  └{'─' * 88}")


# ─── Verificação física ───────────────────────────────────────────────────────

def check_physics(stats, agg, tss, fonte_label, coords, diag,
                  usar_marcador=True, max_rows=40):
    """Verifica limites físicos, uniformidade, cobertura e frio anômalo."""
    eh_fonte2 = 'FONTE 2' in fonte_label
    n = len(tss)
    print()
    print('  ┌─ VERIFICAÇÃO FÍSICA — campos importados MED→MPAS ──────────────────────────')

    n_ok = n_warn = 0
    limite_lista = max_rows if max_rows else n

    for fname in FIELDS:
        meta = FIELD_META[fname]
        a = agg[fname]
        serie = stats[fname]

        if a['n'] == 0:
            print(f"  │  ✗ {fname}: sem dados")
            n_warn += 1
            continue

        scale = meta['scale']
        pmin, pmax = meta['vmin_phys'] * scale, meta['vmax_phys'] * scale
        gmin, gmax = a['min'], a['max']
        gmean = a['sum'] / a['n']
        gstd = np.sqrt(max(a['sumsq'] / a['n'] - gmean**2, 0.0))
        ok = True

        # 1. Limites físicos
        if gmin < pmin or gmax > pmax:
            print(f"  │  ✗ {fname}: [{gmin:.4g}, {gmax:.4g}] {meta['scale_units']} "
                  f"— fora de [{pmin:.4g}, {pmax:.4g}]")
            ok = False

        # 2. Campo uniforme em toda a série (stub ou conector inativo)
        stub_v = meta.get('stub_value')
        if ok and gstd < 1e-6:
            if stub_v is not None and abs(gmean - stub_v * scale) < 0.1:
                rotulo = f"STUB ({stub_v:.4g} {meta['scale_units']})"
            else:
                rotulo = f"BOOTSTRAP/uniforme ({gmean:.4g} {meta['scale_units']})"
            print(f"  │  ✗ {fname}: campo uniforme — {rotulo}")
            if fname == 'Sf_zorl' and stub_v is not None \
                    and abs(gmean - stub_v * scale) < 0.1:
                print("  │     Sprint C não ativo ou Sf_zorl não chegou ao importState MPAS")
            ok = False

        # 3. Diagnósticos por campo
        if fname == 'So_t' and ok:
            _relatar_frio(diag['frio'], tss, limite_lista)
            if usar_marcador and diag['n_marcador'] > 0:
                print(f"  │  ℹ So_t: {diag['n_marcador']} célula(s) removida(s) como "
                      f"marcador de terra ({_LAND_FILL_K} K, ±{_LAND_FILL_ATOL} K).")
                print("  │     Use --no-land-marker para inspecionar sem remoção; "
                      "a correção definitiva é gravar _FillValue no MED.")

        if fname == 'Si_ifrac' and ok:
            n_ice_tot = sum(s.get('n_ice', 0) for s in serie if s)
            n_val_tot = sum(s['n_valid'] for s in serie if s and s.get('n_valid'))
            print(f"  │  ✓ Si_ifrac: {100.0*n_ice_tot/max(n_val_tot,1):.3f}% das "
                  f"células-passo com gelo > {IFRAC_ICE_ANN_THR}  (média={gmean:.4f})")

        if fname == 'Sf_zorl' and ok:
            calm = np.mean([s['frac_calm'] for s in serie if s and 'frac_calm' in s])
            storm = np.mean([s['frac_storm'] for s in serie if s and 'frac_storm' in s])
            nota = '  [inferido de Foxx_taux/tauy]' if eh_fonte2 else ''
            print(f"  │  ✓ Sf_zorl: média={gmean:.2e} m{nota}")
            print(f"  │     {calm*100:.1f}% < {meta['calm_max']:.0e} m (mar calmo)  |  "
                  f"{storm*100:.1f}% > {meta['storm_min']:.0e} m (vento forte)")
            if abs(gmean - 0.01) < 5e-4:
                print("  │  ⚠ Sf_zorl: média ≈ 0.01 m — suspeita de stub "
                      "(zorl_default = 0.01 m)")
                ok = False

        # 4. Cobertura dinâmica por passo (resumida em séries longas)
        _relatar_cobertura(fname, serie, tss, limite_lista, meta)

        if ok:
            print(f"  │  ✓ {fname}: [{gmin:.4g}, {gmax:.4g}] {meta['scale_units']} "
                  f"— dentro de [{pmin:.4g}, {pmax:.4g}]")
            n_ok += 1
        else:
            n_warn += 1

    print(f"  └─ {n_ok} OK, {n_warn} avisos")


def _relatar_frio(frio, tss, limite):
    """
    Sub-congelamento da água do mar (< 271,35 K) é físico em altas latitudes
    (oceano sob gelo marinho) e anômalo em baixas latitudes, onde indicaria
    mistura de SST com célula mascarada no regrid OCN→ATM.
    """
    n = len(frio)
    passos_anom = [i for i, (nf, npo, nb, lo) in enumerate(frio) if nb > 0]
    if not passos_anom:
        n_polar_tot = sum(npo for _, npo, _, _ in frio)
        if n_polar_tot:
            print(f"  │  • So_t: {n_polar_tot} célula-passo(s) < 271.35 K, todas "
                  f"em |lat| ≥ 55° (normal: oceano sob gelo).")
        return

    print(f"  │  ⚠ So_t: sub-congelamento em baixa latitude em "
          f"{len(passos_anom)} de {n} passo(s).")
    for i in passos_anom[:max(1, limite // 8)]:
        nf, npo, nb, lo = frio[i]
        print(f"  │     passo {i+1} ({_rotulo_passo(tss, i)}): {nf} célula(s) "
              f"< 271.35 K — {npo} polares + {nb} em |lat| < 55° "
              f"(mínimo {lo:.2f} K)")
    if len(passos_anom) > max(1, limite // 8):
        print(f"  │     ... e mais {len(passos_anom) - max(1, limite // 8)} passo(s).")
    print("  │     Causa provável: regrid BILINEAR OCN→ATM sem máscara no MED "
          "(rh_ocn2atm),")
    print("  │     que mistura SST oceânica com células mascaradas do MOM6 na "
          "costa/costura.")
    print("  │     Correção sugerida: regrid de So_t ciente de máscara "
          "(srcMaskValues/dstFracField)")
    print("  │     ou NEAREST_STOD em MED_cap_MONAN.F90 (FieldRegridStore).")


def _relatar_cobertura(fname, serie, tss, limite, meta):
    """Cobertura dinâmica por passo, resumida quando a série é longa."""
    idx_validos = [i for i, s in enumerate(serie) if s and s.get('n_valid')]
    if not idx_validos:
        return
    if len(idx_validos) <= limite:
        alvos = idx_validos
    else:
        metade = max(1, limite // 4)
        alvos = idx_validos[:metade] + idx_validos[-metade:]

    for pos, i in enumerate(alvos):
        if len(alvos) < len(idx_validos) and pos == max(1, limite // 4):
            print(f"  │  • {fname}: ... {len(idx_validos) - len(alvos)} passo(s) "
                  f"intermediário(s) omitido(s)")
        st = serie[i]
        tag = '  (bootstrap t=0)' if st['uniforme'] else ''
        print(f"  │  • {fname} passo {i+1}: cobertura dinâmica "
              f"= {st['frac_dyn']*100:.1f}%{tag}")

    dinamicos = [serie[i]['frac_dyn'] for i in idx_validos
                 if not serie[i]['uniforme']]
    if meta.get('stub_value') is not None and dinamicos:
        frac_last = dinamicos[-1]
        if frac_last < 0.02:
            print(f"  │  ⚠ {fname}: campo no default "
                  f"({meta['stub_value']:.4g} {meta['scale_units']}) — "
                  f"stub ou conector inativo.")
        elif frac_last < 0.60:
            print(f"  │  ⚠ {fname}: COBERTURA PARCIAL — "
                  f"{(1-frac_last)*100:.0f}% das células no default e "
                  f"{frac_last*100:.0f}% com dado real.")
            print("  │     Assinatura do bug de mapeamento no import — "
                  "recompilar mpas_cap_methods.F90")
            print("  │     (gather global em state_get_field_1d).")


def detectar_listra(layer, coords, fname):
    """
    Localiza coluna de longitude cujo perfil destoa sistematicamente das
    vizinhas.  Origem típica: fronteira de tile (DE) do g_grid no gather ou
    regrid do MED.  É apenas diagnóstico; não altera o dado.
    """
    if layer is None or coords is None or coords.get('lon') is None:
        return
    lon_axis = np.asarray(coords['lon'])
    if layer.ndim != 2 or lon_axis.size != layer.shape[1]:
        return
    with np.errstate(invalid='ignore'):
        col_med = np.nanmedian(layer, axis=0)
    if not np.any(np.isfinite(col_med)):
        return
    base = np.nanmedian(col_med)
    mad = np.nanmedian(np.abs(col_med - base)) + 1e-30
    z = np.abs(col_med - base) / (1.4826 * mad)
    susp = np.where(np.nan_to_num(z, nan=0.0) > 6.0)[0]
    if 0 < susp.size <= 5:
        lons = ', '.join(f"{lon_axis[c]:+.1f}°" for c in susp)
        print(f"  │  ⚠ {fname}: LISTRA detectada em coluna(s) de longitude "
              f"{lons} (outlier robusto z>6).")
        print("  │     Provável fronteira de tile (DE) do g_grid no gather/regrid "
              "MED. Conferir contra 360/regDecomp(1).")


# ─── Apoio à plotagem ─────────────────────────────────────────────────────────

def preparar_longitude(lon):
    """Converte grade 0→360 em -180→180 e devolve (lon_ordenado, permutação)."""
    lon_plot = np.asarray(lon, dtype=float)
    if lon_plot.size == 0:
        return lon_plot, np.arange(0)
    if lon_plot[0] >= 0 and lon_plot[-1] > 180:
        lon_plot = np.where(lon_plot >= 180, lon_plot - 360, lon_plot)
        idx = np.argsort(lon_plot)
        return lon_plot[idx], idx
    return lon_plot, np.arange(lon_plot.size)


def testar_feicoes_cartopy(cfeature):
    """Verifica uma única vez se o Natural Earth está acessível (BUG-17)."""
    try:
        next(iter(cfeature.LAND.geometries()))
        return True
    except Exception as exc:                                  # noqa: BLE001
        print(f"  AVISO: feições geográficas do cartopy indisponíveis "
              f"({exc.__class__.__name__}). Mapas sem contorno de costa.")
        print("         Para habilitar, faça o cache em nó com rede: "
              "python3 -c \"import cartopy.feature as cf; list(cf.LAND.geometries())\"")
        return False


def _cmap_com_nodata(plt, nome):
    cmap = plt.get_cmap(nome).copy()
    cmap.set_bad(NODATA_COLOR)
    return cmap


# ─── Mapas ────────────────────────────────────────────────────────────────────

class RenderizadorMapas:
    """
    Desenha e grava o mapa multi-painel de UM passo por vez.

    O objeto guarda apenas o que é constante entre os passos (paletas, escala
    de Si_ifrac, disponibilidade do cartopy).  O campo do passo é recebido,
    usado e descartado, de modo que gerar uma figura para cada saída NetCDF
    não faz o consumo de memória crescer com o número de passos.
    """

    def __init__(self, outdir, fonte_label, stats, vmax_si, mask_default=False,
                 si_persist=False, dpi=120):
        self.outdir = outdir
        self.fonte_label = fonte_label
        self.stats = stats
        self.vmax_si = vmax_si
        self.mask_default = mask_default
        self.si_persist = si_persist
        self.dpi = dpi
        self.disponivel = False
        self.n_geradas = 0
        self._preparado = False
        self.plt = None
        self.mcolors = None
        self.LogNorm = None
        self.ccrs = None
        self.cfeature = None
        self.usa_cartopy = False
        self.tem_feicoes = False

        try:
            import matplotlib
            matplotlib.use('Agg')
            import matplotlib.pyplot as plt
            import matplotlib.colors as mcolors
            from matplotlib.colors import LogNorm
        except ImportError:
            print("  AVISO: matplotlib não disponível — mapas não gerados")
            return
        self.plt, self.mcolors, self.LogNorm = plt, mcolors, LogNorm
        self.disponivel = True

        try:
            import cartopy.crs as ccrs
            import cartopy.feature as cfeature
            self.ccrs, self.cfeature = ccrs, cfeature
            self.usa_cartopy = True
        except ImportError:
            print("  AVISO: cartopy não disponível — mapas sem contornos de costa")

    def _preparar(self, coords):
        os.makedirs(self.outdir, exist_ok=True)
        if coords:
            self.lon_plot, self.idx_sorted = preparar_longitude(coords['lon'])
            self.lat = np.asarray(coords['lat'], dtype=float)
        else:
            self.lon_plot = self.idx_sorted = self.lat = None
        self.tem_feicoes = (testar_feicoes_cartopy(self.cfeature)
                            if self.usa_cartopy else False)
        self._cache_cmap = {}
        self._preparado = True

    def _cmap(self, nome):
        if nome not in self._cache_cmap:
            self._cache_cmap[nome] = _cmap_com_nodata(self.plt, nome)
        return self._cache_cmap[nome]

    def render(self, i, ts, campos, coords, i_mapa=0, n_mapas=0):
        if not self.disponivel:
            return
        if not self._preparado:
            self._preparar(coords)

        plt = self.plt
        presentes = [f for f in FIELDS if campos.get(f) is not None]
        if not presentes:
            return
        ncols = 2
        nrows = (len(presentes) + 1) // ncols
        fig_h = 3.5 * nrows + 1.5
        kw = {'projection': self.ccrs.PlateCarree()} if self.usa_cartopy else {}
        fig, axes = plt.subplots(nrows, ncols, figsize=(14, fig_h),
                                 subplot_kw=kw if self.usa_cartopy else None)
        axes = np.array(axes).flatten()

        for ax_idx, fname in enumerate(presentes):
            meta = FIELD_META[fname]
            ax = axes[ax_idx]
            ax.set_facecolor(NODATA_COLOR)
            layer = np.asarray(campos[fname], dtype=float) * meta['scale']
            usar_acc = bool(fname == 'Si_ifrac' and self.si_persist)

            nlat, nlon = layer.shape
            if self.idx_sorted is not None and nlon == self.idx_sorted.size:
                layer = layer[:, self.idx_sorted]
                lons, lats = self.lon_plot, self.lat
            else:
                lats = np.linspace(-90, 90, nlat)
                lons = np.linspace(-180, 180, nlon)
            lon2d, lat2d = np.meshgrid(lons, lats)

            if self.mask_default:
                stub = meta.get('stub_value')
                if stub is not None:
                    tol = COVER_TOL.get(fname, meta.get('stub_tol', 1e-6))
                    layer = np.where(np.abs(layer - stub) <= tol, np.nan, layer)

            flat = layer[np.isfinite(layer)]
            st = self.stats[fname][i]
            uniforme = bool(st['uniforme']) if st else True
            frac_dyn = float(st['frac_dyn']) if st and st.get('n_valid') else 0.0

            vmin = meta['vmin_plot'] * meta['scale']
            vmax = meta['vmax_plot'] * meta['scale']

            # Escala robusta: se mais de 20% das células saturam num extremo,
            # reajusta aos percentis 2–98 para revelar o gradiente real.
            if (not uniforme) and flat.size > 0 and fname != 'Sf_zorl':
                if float(np.mean(flat <= vmin)) > 0.20 \
                        or float(np.mean(flat >= vmax)) > 0.20:
                    p2, p98 = np.percentile(flat, [2, 98])
                    if p98 > p2:
                        vmin, vmax = float(p2), float(p98)

            if fname == 'Si_ifrac':
                vmin, vmax = 0.0, self.vmax_si

            norm = (self.LogNorm(vmin=max(vmin, 1e-6), vmax=vmax)
                    if fname == 'Sf_zorl'
                    else self.mcolors.Normalize(vmin=vmin, vmax=vmax))

            cmap = self._cmap(meta['cmap'])
            campo_ma = np.ma.masked_invalid(layer)
            pk = dict(norm=norm, cmap=cmap, shading='nearest', zorder=1)

            if self.usa_cartopy:
                cf = ax.pcolormesh(lon2d, lat2d, campo_ma,
                                   transform=self.ccrs.PlateCarree(), **pk)
                if self.tem_feicoes:
                    ax.add_feature(self.cfeature.LAND, facecolor='lightgray',
                                   zorder=5)
                    ax.add_feature(self.cfeature.COASTLINE, linewidth=0.5,
                                   edgecolor='black', zorder=6)
                ax.set_global()

                # Gelo esparso: célula de 1°x1° vira pixel invisível na escala
                # global; marcador de tamanho fixo garante legibilidade.
                if fname == 'Si_ifrac' and not uniforme and flat.size:
                    n_ice = int(np.count_nonzero(flat > IFRAC_ICE_ANN_THR))
                    if 0 < n_ice < ICE_SCATTER_THRESHOLD:
                        cheio = np.nan_to_num(layer, nan=0.0)
                        mask2d = cheio > IFRAC_ICE_ANN_THR
                        if mask2d.any():
                            ax.scatter(lon2d[mask2d], lat2d[mask2d],
                                       c=cheio[mask2d], cmap=cmap, norm=norm,
                                       s=ICE_SCATTER_SIZE,
                                       transform=self.ccrs.PlateCarree(),
                                       edgecolors='steelblue', linewidths=0.5,
                                       alpha=0.90, zorder=8)
            else:
                cf = ax.pcolormesh(lon2d, lat2d, campo_ma, **pk)

            cbar_lbl = (f"{meta['scale_units']} (vmax={vmax:.3f})"
                        if fname == 'Si_ifrac' else meta['scale_units'])
            plt.colorbar(cf, ax=ax, shrink=0.8, pad=0.02, label=cbar_lbl)

            rot = ts.strftime('%Y-%m-%d %H:%M') if ts else f'passo {i+1}'
            titulo = meta['long_name']
            if fname == 'Sf_zorl' and 'FONTE 2' in self.fonte_label:
                titulo = 'Sf_zorl (inferido)'
            if usar_acc:
                titulo += ' — persistência simulada'
            n_falta = int(np.count_nonzero(~np.isfinite(layer)))
            ax.set_title(f"{titulo}\n{rot}  |  sem dado: "
                         f"{100.0*n_falta/max(layer.size,1):.1f}%", fontsize=8)

            # Anotação inferior esquerda: cobertura ou restart.
            if fname == 'Si_ifrac' and _bootstrap(self.stats, i):
                cov_txt, cov_color = 'restart SIS2 (t=0)', 'darkorange'
            elif uniforme:
                cov_txt, cov_color = 'bootstrap t=0 (uniforme)', 'dimgray'
            else:
                cov_color = 'darkred' if frac_dyn < 0.60 else 'black'
                cov_txt = f"cobertura dinâmica: {frac_dyn*100:.0f}%"
            ax.text(0.01, 0.02, cov_txt, transform=ax.transAxes, fontsize=7,
                    color=cov_color, va='bottom', ha='left', zorder=7,
                    bbox=dict(boxstyle='round,pad=0.2', fc='white',
                              ec=cov_color, alpha=0.75))

            # Anotação inferior direita: contagem e máximo de gelo.
            if fname == 'Si_ifrac' and flat.size:
                n_ice = int(np.count_nonzero(flat > IFRAC_ICE_ANN_THR))
                tag = ' [persist. simulada]' if usar_acc else ''
                ax.text(0.99, 0.02,
                        f'n={n_ice:,} cél > {IFRAC_ICE_ANN_THR:.2f}  |  '
                        f'max={float(flat.max()):.3f}{tag}',
                        transform=ax.transAxes, fontsize=7, color='navy',
                        va='bottom', ha='right', zorder=7,
                        bbox=dict(boxstyle='round,pad=0.2', fc='white',
                                  ec='steelblue', alpha=0.75))

        for k in range(len(presentes), len(axes)):
            axes[k].set_visible(False)

        rot = ts.strftime('%Y-%m-%d %H:%M') if ts else f'passo {i+1}'
        fig.suptitle(
            f"MONAN-A 2.0 — Campos importados MED→MPAS\n"
            f"{rot}  |  {self.fonte_label}  |  INPE/CGCT/DIMNT", fontsize=9)
        fig.tight_layout()

        ts_tag = ts.strftime('%Y%m%d_%H%M%S') if ts else f'step{i+1:04d}'
        outfile = os.path.join(self.outdir, f'monan2_import_{ts_tag}.png')
        fig.savefig(outfile, dpi=self.dpi, facecolor='white')
        plt.close(fig)
        self.n_geradas += 1
        prefixo = f"  [{i_mapa:5d}/{n_mapas}]" if n_mapas else "  "
        print(f"{prefixo} Figura: {outfile}")


def render_mapas(arquivos, fonte, carimbos, plot_idx, renderer,
                 usar_marcador=True, si_persist=False, verbose=True):
    """
    Segunda passagem: relê os arquivos e desenha um mapa por passo selecionado.

    Sem persistência simulada, só os arquivos que virarão figura precisam ser
    relidos.  Com ela, o acumulador exige a sequência completa, então todos os
    arquivos são percorridos, mas apenas uma camada acumulada fica em memória.

    Retorna a lista de estatísticas do campo acumulado (ou None em cada passo
    quando a persistência está desativada), usada pela série temporal.
    """
    plot = set(plot_idx)
    indices = range(len(arquivos)) if si_persist else sorted(plot)
    stats_acc = [None] * len(arquivos)
    coords = None
    si_prev = None
    i_mapa = 0
    n_mapas = len(plot)

    for k in indices:
        campos, coords, _ = ler_passo(arquivos[k], fonte, coords, usar_marcador)

        if si_persist:
            raw = campos['Si_ifrac']
            if raw is not None:
                if si_prev is not None and si_prev.shape == raw.shape:
                    raw = np.clip(np.fmax(raw, si_prev * SI_IFRAC_VIS_DECAY),
                                  0.0, 1.0)
                si_prev = raw
            if si_prev is not None:
                stats_acc[k] = estatisticas_camada(si_prev, 1.0, 'Si_ifrac')
                campos = dict(campos)
                campos['Si_ifrac'] = si_prev

        if k in plot:
            i_mapa += 1
            renderer.render(k, carimbos[k], campos, coords, i_mapa, n_mapas)

    return stats_acc


def _bootstrap(stats, i):
    """
    True quando o passo i está em modo bootstrap (pré-acoplamento).

    Critério: So_t espacialmente uniforme, indicando que o acoplador ainda não
    escreveu o campo oceânico real.  Nesse passo o Si_ifrac contém o estado de
    restart do SIS2, e não dado de acoplamento.
    """
    serie = stats.get('So_t')
    if not serie or i >= len(serie) or serie[i] is None:
        return False
    return bool(serie[i].get('uniforme', False))


# ─── Série temporal ───────────────────────────────────────────────────────────

def plot_timeseries(stats, tss, outdir, fonte_label, si_persist=False,
                    stats_acc=None):
    """Série temporal das médias globais, com faixa mínimo-máximo."""
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
    except ImportError:
        return

    os.makedirs(outdir, exist_ok=True)
    campos = [f for f in FIELDS
              if stats.get(f) and any(s and s.get('n_valid') for s in stats[f])]
    if not campos:
        return

    fig, axes = plt.subplots(len(campos), 1, figsize=(10, 4 * len(campos)),
                             sharex=True)
    axes = np.atleast_1d(axes)

    tem_data = all(t is not None for t in tss)
    x_vals = tss if tem_data else list(range(1, len(tss) + 1))

    def _serie(serie, chave):
        return np.array([np.nan if (s is None or not s.get('n_valid'))
                         else s[chave] for s in serie], dtype=float)

    for ax, fname in zip(axes, campos):
        meta = FIELD_META[fname]
        usar_acc = (fname == 'Si_ifrac' and si_persist and stats_acc)
        serie = stats_acc if usar_acc else stats[fname]

        means = _serie(serie, 'mean')
        maxs = _serie(serie, 'max')
        mins = _serie(serie, 'min')

        ax.fill_between(x_vals, mins, maxs, alpha=0.15, color='steelblue',
                        label='mínimo-máximo')
        ax.plot(x_vals, means, 'o-', color='steelblue', lw=1.8, ms=4,
                label='média global')

        stub = meta.get('stub_value')
        if stub is not None:
            ax.axhline(stub * meta['scale'], color='red', ls='--', lw=1,
                       label=f"stub = {stub * meta['scale']:.4g} "
                             f"{meta['scale_units']}")

        if fname == 'Sf_zorl':
            ax.set_yscale('log')

        titulo = meta['long_name']
        if fname == 'Sf_zorl' and 'FONTE 2' in fonte_label:
            titulo += ' (inferido de Foxx_taux/tauy)'
        if usar_acc:
            titulo += ' — persistência simulada'
        ax.set_title(titulo, fontsize=9)
        ax.set_ylabel(meta['scale_units'], fontsize=9)
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)

    if tem_data:
        # Localizador automático: o intervalo pode ir de horas a meses.
        locator = mdates.AutoDateLocator(minticks=4, maxticks=9)
        axes[-1].xaxis.set_major_locator(locator)
        axes[-1].xaxis.set_major_formatter(mdates.ConciseDateFormatter(locator))
        axes[-1].set_xlabel('Tempo')
    else:
        axes[-1].set_xlabel('Passo de acoplamento')

    fig.suptitle(
        f'MONAN-A 2.0 — Série temporal MED→MPAS\n{fonte_label}  |  INPE/CGCT/DIMNT',
        fontsize=10)
    fig.tight_layout()

    outfile = os.path.join(outdir, 'monan2_import_timeseries.png')
    fig.savefig(outfile, dpi=120, facecolor='white')
    plt.close(fig)
    print(f"  Série temporal: {outfile}")


# ─── Verificação de log ───────────────────────────────────────────────────────

def check_log(logfile):
    """Verifica evidências do conector MED→MPAS no log ESMF."""
    print()
    print(f"  {'─' * 70}")
    print("  [FONTE 3] Verificação do log ESMF")
    print(f"  {'─' * 70}")
    print(f"  Log: {logfile}")

    if not os.path.isfile(logfile):
        print(f"  AVISO: log não encontrado — '{logfile}'")
        return

    padroes = {
        'sprint_c': 'Sprint C: Sf_zorl calculado via Charnock',
        'importacao_completa': '(So_t + Si_ifrac + So_u + So_v + Sf_zorl)',
        'route_ocn_atm': 'RouteOcnToAtm: regrid OCN->ATM concluido',
        # A rotina registra "(write_mpas_import_diag): escrito <arquivo>" no
        # log ESMF e/ou "[DIAG-IMPORT] mpas_import_step" em stdout.
        'diag_escrito': '[DIAG-IMPORT] mpas_import_step',
        'diag_escrito_leg': 'write_mpas_import_diag',
    }
    labels = {
        'sprint_c': '"Sprint C: Sf_zorl calculado via Charnock+Smith"',
        'importacao_completa': '"(So_t + Si_ifrac + So_u + So_v + Sf_zorl)"',
        'route_ocn_atm': '"RouteOcnToAtm: regrid OCN->ATM concluido"',
        'diag_escrito': '"[DIAG-IMPORT] mpas_import_step" (stdout v4.13+)',
        'diag_escrito_leg': '"write_mpas_import_diag: escrito" (ESMF log)',
    }

    found = {k: [] for k in padroes}
    logfiles_busca = [logfile]
    for pat in ('logs/PET*.STDOUT', 'logs/stdout*', 'logs/mpirun*.log'):
        logfiles_busca.extend(glob.glob(pat))
    vistos = set()
    logfiles_busca = [f for f in logfiles_busca
                      if not (f in vistos or vistos.add(f))]

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
        print(f"  {'✓' if n else '✗'} {labels[key]:52s}: {n} ocorrência(s)")
    n_diag = len(found['diag_escrito']) + len(found['diag_escrito_leg'])
    lbl_diag = '"write_mpas_import_diag" (stdout ou ESMF log)'
    print(f"  {'✓' if n_diag else '✗'} {lbl_diag:52s}: {n_diag} ocorrência(s)")

    n_sprint = len(found['sprint_c'])
    n_import = len(found['importacao_completa'])
    if n_sprint:
        print(f"  ✓ Sprint C ativo ({n_sprint} passos confirmados)")
    if n_import:
        print(f"  ✓ Importação Sf_zorl no MPAS confirmada ({n_import} passos)")

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
        print("     Se os arquivos de diagnóstico existem em diag_import/, a rotina")
        print("     ESTÁ rodando (a ausência no log é falha de correspondência de")
        print("     texto, não de execução). Para confirmar a VERSÃO compilada,")
        print("     verifique o atributo global 'source': ncdump -h <arquivo>.nc")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Diagnóstico dos campos importados pelo MONAN-A via MED→MPAS.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument('--diagdir', default='diag_import',
                        help='Diretório com diagnósticos (padrão: diag_import)')
    parser.add_argument('--outdir', default='diag_import/postproc',
                        help='Saída: figuras (padrão: diag_import/postproc)')
    parser.add_argument('--logfile', default='logs/PET0.esmApp.log',
                        help='Log ESMF (padrão: logs/PET0.esmApp.log)')
    parser.add_argument('--stats', action='store_true', help='Estatísticas por passo')
    parser.add_argument('--check', action='store_true', help='Verificação física')
    parser.add_argument('--plot', action='store_true', help='Mapas e série temporal')
    parser.add_argument('--log', action='store_true', help='Verificar log ESMF')
    parser.add_argument('--mask-default', dest='mask_default', action='store_true',
                        help='Oculta células no valor default nos mapas')

    parser.add_argument('--step', nargs='+', type=int, default=None,
                        help='Passos específicos a plotar (base 1). '
                             'Padrão: todos os passos')
    parser.add_argument('--all-steps', action='store_true', dest='all_steps',
                        help='Mantido por compatibilidade: plotar todos os '
                             'passos já é o padrão')
    parser.add_argument('--stride', type=int, default=1,
                        help='Processa 1 a cada N arquivos (padrão: 1)')
    parser.add_argument('--tmin', default=None,
                        help='Início da janela (YYYY-MM-DD[THH:MM])')
    parser.add_argument('--tmax', default=None,
                        help='Fim da janela (YYYY-MM-DD[THH:MM])')
    parser.add_argument('--max-maps', type=int, default=0, dest='max_maps',
                        help='Teto de figuras de mapa por execução '
                             '(padrão: 0 = uma figura por saída NetCDF)')
    parser.add_argument('--dpi', type=int, default=120,
                        help='Resolução das figuras (padrão: 120)')
    parser.add_argument('--max-rows', type=int, default=40, dest='max_rows',
                        help='Teto de linhas por campo nas listagens (0 = todas)')

    # v3.2 (BUG-16): desligado por padrão — ver nota no cabeçalho do arquivo.
    parser.set_defaults(land_marker_on=False)
    parser.add_argument('--legacy-land-marker', action='store_true',
                        dest='land_marker_on',
                        help='Religa o marcador de terra por temperatura '
                             '(271.35 K) — use apenas em arquivos gerados '
                             'antes da máscara real de continente (sem '
                             "variável 'ocn_frac')")
    parser.add_argument('--no-land-marker', action='store_false',
                        dest='land_marker_on',
                        help='Mantido por compatibilidade; sem efeito desde '
                             'a v3.2, já que o marcador vem desligado por padrão')
    parser.add_argument('--si-persist', action='store_true', dest='si_persist',
                        help='Aplica a persistência simulada de Si_ifrac nas '
                             'figuras (compensa o BUG-MEM do Fortran; o campo '
                             'exibido deixa de ser o dado bruto)')

    args = parser.parse_args()
    run_all = not (args.stats or args.check or args.plot or args.log)
    if args.stride < 1:
        sys.exit("ERRO: --stride deve ser >= 1.")

    print()
    print('══' * 36)
    print('  Diagnóstico MED→MPAS: So_t | Si_ifrac | Sf_zorl')
    print('  INPE / CGCT / DIMNT — GT Acoplamento de Modelos  (v3.1)')
    print('══' * 36)

    # FONTE 3 primeiro: verifica log independentemente dos dados.
    if run_all or args.log:
        check_log(args.logfile)

    if not (run_all or args.stats or args.check or args.plot):
        print()
        print('══' * 36)
        print('  Concluído.')
        print('══' * 36)
        print()
        return

    print()
    print(f"  {'─' * 70}")
    print(f"  Carregando dados de '{args.diagdir}'...")

    fonte, arquivos, carimbos = descobrir_fonte(args.diagdir)
    arquivos, carimbos = filtrar_arquivos(
        arquivos, carimbos, parse_datahora(args.tmin),
        parse_datahora(args.tmax), args.stride)
    fonte_label = rotulo_fonte(fonte, arquivos)

    nsteps = len(arquivos)
    step_indices = (selecionar_passos_mapa(nsteps, args.step, args.max_maps)
                    if (run_all or args.plot) else [])

    # Primeira passagem: estatísticas de todos os passos, sem reter a série.
    stats, agg, campos_ultimo, coords, diag = scan_arquivos(
        arquivos, fonte, usar_marcador=args.land_marker_on)

    print(f"  {'─' * 70}")
    print(f"  Fonte               : {fonte_label}")
    print(f"  Arquivos            : {nsteps} passo(s) selecionado(s)")
    if args.stride > 1:
        print(f"  Amostragem          : 1 a cada {args.stride} arquivo(s)")
    ini = _rotulo_passo(carimbos, 0)
    fim = _rotulo_passo(carimbos, nsteps - 1)
    print(f"  Período             : {ini} → {fim}")
    if run_all or args.plot:
        sufixo = ('(uma por saída NetCDF)' if len(step_indices) == nsteps
                  else f'de {nsteps} saída(s) NetCDF')
        print(f"  Figuras de mapa     : {len(step_indices)} {sufixo}")
    if args.si_persist:
        print("  Si_ifrac            : persistência simulada ATIVA nas figuras "
              "(estatísticas seguem o dado bruto)")

    if run_all or args.stats:
        print_stats(stats, carimbos, fonte_label, max_rows=args.max_rows)

    if run_all or args.check:
        check_physics(stats, agg, carimbos, fonte_label, coords, diag,
                      usar_marcador=args.land_marker_on, max_rows=args.max_rows)
        # Localizador de listra: aplicado ao último passo, única camada 2-D
        # mantida em memória pela primeira passagem.
        for fname in FIELDS:
            camada = campos_ultimo.get(fname)
            if camada is not None:
                detectar_listra(np.asarray(camada, dtype=float), coords, fname)

    stats_acc = None
    if run_all or args.plot:
        print(f"\n  Gerando figuras ({len(step_indices)} passo(s))...")
        if len(step_indices) > 200:
            print(f"  Volume estimado: ~{len(step_indices)*0.6:.0f} MB e alguns "
                  f"minutos de desenho. Use --max-maps ou --step para reduzir.")
        os.makedirs(args.outdir, exist_ok=True)

        # Escala de Si_ifrac consistente entre passos, calculada na primeira
        # passagem.  O passo de bootstrap (restart do SIS2) só entra quando a
        # persistência simulada está ativa, porque só então o campo do restart
        # é propagado para os passos seguintes.
        vmax_si = FIELD_META['Si_ifrac']['vmax_plot']
        reais = [st['max'] for j, st in enumerate(stats['Si_ifrac'])
                 if st and st.get('n_valid')
                 and (args.si_persist or not _bootstrap(stats, j))]
        if reais:
            vmax_si = max(max(reais), 0.01)

        renderer = RenderizadorMapas(args.outdir, fonte_label, stats, vmax_si,
                                     mask_default=args.mask_default,
                                     si_persist=args.si_persist, dpi=args.dpi)
        # Segunda passagem: relê e desenha, um passo por vez.
        stats_acc = render_mapas(arquivos, fonte, carimbos, step_indices,
                                 renderer, usar_marcador=args.land_marker_on,
                                 si_persist=args.si_persist)
        print(f"  {renderer.n_geradas} figura(s) de mapa gerada(s).")
        plot_timeseries(stats, carimbos, args.outdir, fonte_label,
                        si_persist=args.si_persist, stats_acc=stats_acc)

    print()
    print('══' * 36)
    print('  Concluído.')
    print('══' * 36)
    print()


if __name__ == '__main__':
    main()
