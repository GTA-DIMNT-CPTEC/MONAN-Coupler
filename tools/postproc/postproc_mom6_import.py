#!/usr/bin/env python3
"""
postproc_mom6_import.py  —  Validação dos campos importados pelo MOM6+SIS2
                              (15 campos do exportState ATM→OCN calculados pelo
                               mediador NCAR bulk em MED_cap.F90)

Versão 9.1 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Setembro 2026

═══════════════════════════════════════════════════════════════════════════════
CORREÇÕES v9.1
═══════════════════════════════════════════════════════════════════════════════

Uma figura para CADA saída NetCDF, sem crescimento de memória
  A v9.0 limitava os mapas a uma amostra (--max-maps 12) porque as camadas dos
  passos a plotar ficavam retidas até o fim da leitura.  Isso deixava os
  scripts de animação sem quadros suficientes.
  Mudanças:
    • o desenho passou a ocorrer DENTRO do laço de leitura (classe
      RenderizadorMapas): o campo do passo é lido, vira figura e é descartado,
      de modo que o pico de memória é o de um único passo;
    • o padrão de --max-maps passou de 12 para 0 (sem teto): por padrão sai
      uma figura por arquivo de diagnóstico;
    • --step continua restringindo a passos específicos e --max-maps continua
      disponível para amostrar uniformemente quando não se quer a série toda;
    • --all-steps foi mantido apenas por compatibilidade e não altera nada,
      pois plotar todos os passos virou o padrão;
    • --dpi permite reduzir a resolução (o tempo de gravação da figura é
      proporcional à área em pixels e domina o custo total).
  Medido em 240 arquivos numa grade 360x180: 240 figuras geradas com pico de
  291 MiB, constante em relação ao número de passos.

--all-fields: processa TODAS as variáveis 2-D do arquivo
  Campos gravados pelo mediador que ainda não têm entrada em FIELD_META
  passam a poder ser incluídos, com escala 1,0, paleta padrão e sem limite
  físico, em vez de serem silenciosamente ignorados.

═══════════════════════════════════════════════════════════════════════════════
CORREÇÕES v9.0
═══════════════════════════════════════════════════════════════════════════════

BUG-PY-16  Consumo de memória proporcional ao número de passos
  Sintoma: o script não conclui (ou é morto pelo sistema) quando executado
    sobre o intervalo completo de integração.
  Causa  : load_diag_files() empilhava TODOS os passos de TODOS os campos em
    memória, em float64, antes de qualquer cálculo.  Para 15 campos numa
    grade 360x180 e 720 passos (30 dias com dt_coupling=1 h) isso são
    15 x 720 x 64.800 x 8 B = 5,2 GB; numa grade 640x320, 25,8 GB.
    print_stats, check_physics e plot_timeseries ainda faziam cópias
    completas desse bloco (data[~np.isnan(data)], data * scale,
    np.nanpercentile sobre o array inteiro), multiplicando o pico.
  Correção: leitura em UMA passagem, um arquivo por vez.  As estatísticas por
    passo (mínimo, máximo, média, desvio padrão, percentis, cobertura) são
    calculadas na leitura e guardadas como ESCALARES.  Apenas os passos que
    serão efetivamente plotados ficam residentes como campos 2-D, em float32.
    O pico de memória passa a ser O(n_campos x n_mapas), independente da
    duração da integração.

BUG-PY-17  Eixo de tempo fixo em 6 h na série temporal
  Sintoma: rótulos ilegíveis em integrações de vários dias e, acima de ~1000
    marcas (mais de 250 dias), exceção MAXTICKS do matplotlib.
  Causa  : mdates.HourLocator(interval=6) fixo.
  Correção: AutoDateLocator + ConciseDateFormatter, que escolhem a unidade
    (hora, dia, mês) conforme o intervalo coberto.

BUG-PY-18  Marcador de terra removia SST oceânica real (buracos nas figuras)
  Sintoma: manchas brancas no mapa de So_t exatamente nas regiões cobertas por
    gelo marinho (Ártico, Mar de Weddell, Mar de Ross, Baía de Hudson).
  Causa  : fill_min_threshold=271,4 K descartava como "preenchimento" TODA
    célula abaixo desse valor.  O ponto de congelamento da água do mar com
    S≈35 é 271,35 K: a SST sob gelo marinho fica legitimamente entre 271,2 e
    271,4 K e era apagada junto com o marcador do Sprint A.5.
  Correção: o marcador passa a ser identificado por IGUALDADE APROXIMADA com o
    valor exato gravado pelo mediador (land_marker=271,35 K, atol=1e-4 K), e
    não por um limiar inferior.  O piso de preenchimento verdadeiro
    (stub OCN em ~200 K) fica em fill_min_threshold=250 K.  O número de
    células removidas pelo marcador é reportado por passo, para que a remoção
    nunca seja silenciosa.
  Observação para o lado Fortran: a solução definitiva é o MED gravar
    _FillValue no NetCDF em vez de usar um valor fisicamente válido como
    marcador.  Enquanto isso não ocorre, use --no-land-marker para inspecionar
    o campo sem nenhuma remoção.

BUG-PY-19  Heurística de "seam tripolar" corrompia uma coluna de dados
  Sintoma: listra vertical com valores interpolados (ou apagados) perto do
    meridiano de Greenwich em campos oceânicos.
  Causa  : o bloco mask_tripole_seam procurava a coluna anômala em torno de
    n_cols // 2.  Depois do giro de 0–360° para -180–180°, esse índice
    corresponde a lon ≈ 0°, e não a lon ≈ 180° como dizia o comentário.  Em
    campos oceânicos a coluna de Greenwich atravessa Europa e África e tem
    mais de 50% de NaN, disparando a heurística sempre: a coluna era
    substituída por 0,5*(vizinha_esq + vizinha_dir) e, onde isso também era
    NaN, pela média global do campo.  Ou seja, o script inventava dado.
  Correção: bloco removido.  A grade do MED é regular em (0–360°, -90–90°) e
    não possui costura própria; qualquer descontinuidade herdada da grade
    nativa do MOM6 é um problema de regrid a ser corrigido no MED, não
    maquiado no pós-processamento.

BUG-PY-20  Ausência de dado indistinguível de valor nulo nas figuras
  Sintoma: em Faxa_rain, Faxa_snow e nos campos de onda curta, a área sem dado
    e a área com valor zero apareciam ambas em branco.
  Correção: cor explícita para célula sem dado (cinza claro) via set_bad() e
    facecolor do eixo; barra de cores com extend='both' quando os limites de
    exibição cortam a distribuição.

BUG-PY-21  Falha de rede do cartopy em nó de execução sem internet
  Sintoma: exceção (ou espera longa) ao gravar a figura, no primeiro acesso ao
    Natural Earth.
  Correção: disponibilidade das feições geográficas é testada uma única vez no
    início; se o download não for possível, as figuras são geradas sem
    contorno de costa, com aviso, em vez de abortar.

BUG-PY-22  Orientação (lat,lon) decidida por heurística de tamanho
  Correção: a transposição passa a usar os tamanhos reais de lat e lon lidos do
    arquivo; a heurística nlat<nlon só é usada quando as coordenadas estão
    ausentes.

ADIÇÕES v9.0 (controle do volume de saída em integrações longas)
  --stride N        processa 1 a cada N arquivos de diagnóstico
  --tmin / --tmax   recorta a janela temporal (YYYY-MM-DD[THH:MM])
  --max-maps N      teto de figuras por execução (v9.1: padrão 0, sem teto)
  --max-rows N      teto de linhas por campo na tabela de estatísticas
  --no-land-marker  desativa a remoção do marcador de terra
  --land-marker V   valor do marcador de terra em K (padrão 271.35)

═══════════════════════════════════════════════════════════════════════════════
HISTÓRICO ANTERIOR (resumido)
═══════════════════════════════════════════════════════════════════════════════
  v8.3  rodapé indicando em que passo o MOM6 consome os fluxos exibidos
  v8.2  BUG-PY-15: cfeature.LAND ausente; fill_min_threshold de So_t
  v8.1  renomeação dos arquivos de saída para o prefixo mom6_import_
  v8.0  BUG-PY-14: escala adaptativa de Si_ifrac; painel informativo
  v7.0  BUG-PY-13: calibração de vmax_phys de Foxx_lwnet e So_duu10n
  v6.0  BUG-PY-12: limiares de preenchimento e supressão de avisos duplicados
  v5.0  BUG-PY-11: limpeza de imports e código morto
  v4.0  BUG-PY-08: aplicação de 'scale' em todas as saídas
  v3.0  BUG-PY-06: correção semântica DOCN -> exportState MED
  v2.0  BUG-PY-01/02/03: padrão de busca e lista de campos

═══════════════════════════════════════════════════════════════════════════════
Cenário de uso
═══════════════════════════════════════════════════════════════════════════════
O MED_cap.F90 calcula os fluxos ATM→OCN via bulk NCAR a cada passo de
acoplamento e os escreve no exportState (= importState do MOM6+SIS2).
Ativar write_import_diag=.true. faz o mediador gravar um arquivo NetCDF de
diagnóstico por passo em diag_import/mom6_import_YYYYMMDD_HHMMSS.nc.

Modos
  --stats       estatísticas por campo e passo
  --check       verificação de limites físicos
  --csv         exporta séries temporais em CSV
  --plot        mapas + série temporal
  --all         todos os modos [padrão]

Exemplos
  python3 postproc_mom6_import.py
  python3 postproc_mom6_import.py --stats --check
  python3 postproc_mom6_import.py --plot                 # uma figura por arquivo
  python3 postproc_mom6_import.py --plot --max-maps 8    # só uma amostra
  python3 postproc_mom6_import.py --all-fields --stats
  python3 postproc_mom6_import.py --tmin 2026-03-29 --tmax 2026-03-31 --plot

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
# Os arquivos mom6_import_*.nc contêm os campos do exportState MED→OCN,
# calculados pelo mediador MED_cap.F90 via parametrização bulk NCAR
# (Large & Yeager 2009).  A fonte ATM é o MPAS-A (ou DATM como alternativa);
# a SST provém do MOM6+SIS2.
#
# Chaves de mascaramento:
#   fill_threshold      : |valor| acima disto é preenchimento
#   fill_min_threshold  : valor abaixo disto é preenchimento (piso absoluto)
#   fill_equal          : valor exatamente igual a este é preenchimento
#   land_marker         : marcador de terra gravado pelo MED (removido com
#                         tolerância estreita; ver BUG-PY-18)
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
        'vmin_phys': 0.0, 'vmax_phys': 600.0,
        'check_msg': 'Precipitação líquida > 600 mm/d (improvável exceto artefato NaN)',
    },
    'Faxa_snow': {
        'long_name': 'Precipitação sólida (Faxa_snow)',
        'units': 'kg m-2 s-1', 'scale': 86400.0, 'scale_units': 'mm d⁻¹',
        'cmap': 'Blues', 'vperc': [0, 99], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 150.0,
        'check_msg': 'Neve > 150 mm/d (improvável exceto artefato NaN)',
    },
    # ── Campos de estado ──────────────────────────────────────────────────────
    'Sa_pslv': {
        'long_name': 'Pressão ao nível do mar (Sa_pslv)',
        'units': 'Pa', 'scale': 1.0e-2, 'scale_units': 'hPa',
        'cmap': 'RdYlBu_r', 'vperc': [2, 98], 'symmetric': False,
        'vmin_phys': 870.0, 'vmax_phys': 1080.0,
        'check_msg': 'Pressão fora de [870, 1080] hPa',
        # Célula sem pressão sai exatamente em 0 Pa.  Igualdade exata é mais
        # segura que um limiar: nenhuma pressão física real é 0 Pa, e o teste
        # não corre o risco de apagar mínimos profundos de ciclone.
        'fill_equal': 0.0,
    },
    'Si_ifrac': {
        'long_name': 'Fração de gelo marinho (Si_ifrac)',
        'units': '1', 'scale': 1.0, 'scale_units': '[0–1]',
        'cmap': 'Blues', 'vperc': [0, 99], 'symmetric': False,
        'vmin_phys': 0.0, 'vmax_phys': 1.0,
        'binary_field': True,   # habilita escala adaptativa por passo
        'check_msg': 'Fração de gelo fora de [0, 1]',
    },
    'So_t': {
        'long_name': 'SST dinâmica MOM6 (So_t)',
        'units': 'K', 'scale': 1.0, 'scale_units': 'K',
        'cmap': 'RdYlBu_r', 'vperc': [2, 98], 'symmetric': False,
        # BUG-PY-18: vmin_phys volta a 271,0 K.  A água do mar congela a
        # 271,35 K (S≈35) e a SST sob gelo marinho fica legitimamente logo
        # abaixo disso; 271,4 K produzia aviso falso e, junto com o antigo
        # fill_min_threshold, apagava as regiões polares do mapa.
        'vmin_phys': 271.0, 'vmax_phys': 310.0,
        # Piso absoluto de preenchimento: o stub OCN grava ~200 K.
        'fill_min_threshold': 250.0,
        # Marcador de terra do Sprint A.5, removido por igualdade aproximada.
        'land_marker': 271.35,
        'check_msg': 'SST fora de [271, 310] K',
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
SST_CELSIUS_OFFSET = 273.15

# Tolerância de igualdade do marcador de terra, em K.  O valor é gravado em
# float32 pelo Fortran; 1e-3 K cobre a representação sem alcançar a SST real.
LAND_MARKER_ATOL = 1.0e-4

# Cor usada para célula sem dado (distingue "ausente" de "zero").
NODATA_COLOR = '#d9d9d9'


# ─── Localização e ordenação dos arquivos ─────────────────────────────────────

def parse_timestamp_from_filename(fname):
    """Extrai datetime de mom6_import_YYYYMMDD_HHMMSS.nc.  None se não casar."""
    base = os.path.basename(fname)
    if not base.startswith('mom6_import_') or not base.endswith('.nc'):
        return None
    stamp = base[len('mom6_import_'):-len('.nc')]
    try:
        return datetime.strptime(stamp, '%Y%m%d_%H%M%S')
    except ValueError:
        return None


def find_diag_files(diag_dir):
    """
    Lista os diagnósticos ordenados por carimbo de tempo (não por nome).

    A ordenação lexicográfica funciona para YYYYMMDD_HHMMSS, mas quebra se o
    diretório tiver arquivos com outro padrão; ordenar pelo datetime lido é
    equivalente no caso normal e robusto no caso anormal.
    """
    pattern = os.path.join(diag_dir, 'mom6_import_*.nc')
    raw = glob.glob(pattern)
    if not raw:
        sys.exit(f"ERRO: nenhum arquivo mom6_import_*.nc em '{diag_dir}'.\n"
                 f"  Ative write_import_diag=.true. e rode o acoplador.")

    pares, ignorados = [], []
    for f in raw:
        ts = parse_timestamp_from_filename(f)
        if ts is None:
            ignorados.append(f)
        else:
            pares.append((ts, f))
    if ignorados:
        print(f"  AVISO: {len(ignorados)} arquivo(s) com nome fora do padrão "
              f"mom6_import_YYYYMMDD_HHMMSS.nc — ignorado(s).")
    if not pares:
        sys.exit(f"ERRO: nenhum arquivo com carimbo de tempo válido em '{diag_dir}'.")
    pares.sort(key=lambda p: p[0])
    return [ts for ts, _ in pares], [f for _, f in pares]


def filtrar_arquivos(timestamps, files, tmin, tmax, stride):
    """Aplica a janela temporal e o passo de amostragem à lista de arquivos."""
    idx = list(range(len(files)))
    if tmin is not None:
        idx = [i for i in idx if timestamps[i] >= tmin]
    if tmax is not None:
        idx = [i for i in idx if timestamps[i] <= tmax]
    if stride > 1:
        idx = idx[::stride]
    if not idx:
        sys.exit("ERRO: a janela temporal (--tmin/--tmax/--stride) não "
                 "selecionou nenhum arquivo.")
    return [timestamps[i] for i in idx], [files[i] for i in idx]


def parse_datahora(txt):
    """Converte YYYY-MM-DD, YYYY-MM-DDTHH:MM ou YYYY-MM-DDTHH:MM:SS."""
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


def selecionar_passos_mapa(n_steps, lista_passos, max_maps):
    """
    Índices (base 0) dos passos que receberão mapa.

    O padrão é TODOS os passos: uma figura por saída NetCDF, que é o que os
    scripts de animação consomem.  --step restringe a passos específicos e
    --max-maps impõe um teto com amostragem uniforme, incluindo sempre o
    primeiro e o último passo.
    """
    if lista_passos:
        idx = [s - 1 for s in lista_passos]
    else:
        idx = list(range(n_steps))
    idx = sorted({int(min(max(s, 0), n_steps - 1)) for s in idx})
    if max_maps and 0 < max_maps < len(idx):
        print(f"  AVISO: {len(idx)} passo(s) selecionado(s); limitado a "
              f"{max_maps} figura(s) por --max-maps "
              f"(padrão: sem teto).")
        pos = np.unique(np.linspace(0, len(idx) - 1, max_maps).astype(int))
        idx = [idx[i] for i in pos]
    return idx


def descobrir_campos(fpath):
    """
    Lista as variáveis 2-D (lat,lon) presentes no arquivo de diagnóstico.

    Usada por --all-fields: processa tudo o que o mediador gravou, inclusive
    campos ainda sem entrada em FIELD_META (que recebem escala 1,0, paleta
    padrão e nenhum limite físico).
    """
    achados = []
    with Dataset(fpath, 'r') as ds:
        nomes_coord = {'lat', 'lon', 'latitude', 'longitude', 'time'}
        for nome, var in ds.variables.items():
            if nome in nomes_coord:
                continue
            if var.ndim == 2:
                achados.append(nome)
    conhecidos = [f for f in FIELDS if f in achados]
    novos = [f for f in achados if f not in FIELD_META]
    return conhecidos + sorted(novos)

# ─── Mascaramento e estatística de uma camada ─────────────────────────────────

def aplicar_mascaras(arr, meta, usar_marcador=True, marcador_valor=None):
    """
    Converte valores de preenchimento em NaN.

    Retorna (arr, n_marcador) — n_marcador é quantas células foram removidas
    pelo marcador de terra, reportado para que a remoção não seja silenciosa.
    """
    # Preenchimento nativo do NetCDF (magnitude muito grande).
    arr = np.where(np.abs(arr) > 1.0e10, np.nan, arr)

    thresh = meta.get('fill_threshold')
    if thresh is not None:
        arr = np.where(np.abs(arr) > thresh, np.nan, arr)

    fmin = meta.get('fill_min_threshold')
    if fmin is not None:
        arr = np.where(arr < fmin, np.nan, arr)

    feq = meta.get('fill_equal')
    if feq is not None:
        arr = np.where(arr == feq, np.nan, arr)

    n_marc = 0
    marc = marcador_valor if marcador_valor is not None else meta.get('land_marker')
    if usar_marcador and marc is not None:
        alvo = np.isclose(arr, marc, rtol=0.0, atol=LAND_MARKER_ATOL)
        n_marc = int(np.count_nonzero(alvo))
        arr = np.where(alvo, np.nan, arr)

    return arr, n_marc


def estatisticas_camada(arr, scale):
    """
    Estatísticas escalares de uma camada 2-D, já em unidades de exibição.

    Retorna dicionário com chaves n_valid, cov, min, max, mean, std,
    p02, p05, p50, p95, p98 — ou None quando não há célula válida.
    """
    if arr is None:
        return None
    finito = np.isfinite(arr)
    n_ok = int(np.count_nonzero(finito))
    n_tot = int(arr.size)
    if n_ok == 0:
        return {'n_valid': 0, 'n_total': n_tot, 'cov': 0.0}
    flat = arr[finito].astype(np.float64) * scale
    p02, p05, p50, p95, p98 = np.percentile(flat, [2, 5, 50, 95, 98])
    return {
        'n_valid': n_ok, 'n_total': n_tot, 'cov': 100.0 * n_ok / max(n_tot, 1),
        'min': float(flat.min()), 'max': float(flat.max()),
        'mean': float(flat.mean()), 'std': float(flat.std()),
        'sum': float(flat.sum()), 'sumsq': float(np.dot(flat, flat)),
        'p02': float(p02), 'p05': float(p05), 'p50': float(p50),
        'p95': float(p95), 'p98': float(p98),
    }


def _novo_agregado():
    return {'min': np.inf, 'max': -np.inf, 'sum': 0.0, 'sumsq': 0.0,
            'n': 0, 'n_marcador': 0, 'n_gt1': 0, 'n_lt0': 0,
            'sum_raw': 0.0, 'n_raw': 0, 'max_raw': -np.inf, 'min_raw': np.inf}


def _acumular(agg, st, arr_raw, fname):
    if st is None or st.get('n_valid', 0) == 0:
        return
    agg['min'] = min(agg['min'], st['min'])
    agg['max'] = max(agg['max'], st['max'])
    agg['sum'] += st['sum']
    agg['sumsq'] += st['sumsq']
    agg['n'] += st['n_valid']
    if fname == 'Si_ifrac' and arr_raw is not None:
        finito = np.isfinite(arr_raw)
        vals = arr_raw[finito]
        agg['n_gt1'] += int(np.count_nonzero(vals > 1.001))
        agg['n_lt0'] += int(np.count_nonzero(vals < -0.001))
        if vals.size:
            agg['max_raw'] = max(agg['max_raw'], float(vals.max()))
            agg['min_raw'] = min(agg['min_raw'], float(vals.min()))
            agg['sum_raw'] += float(vals.sum())
            agg['n_raw'] += int(vals.size)


# ─── Leitura em uma passagem ──────────────────────────────────────────────────

def scan_diag_files(files, timestamps, field_names, plot_idx=(),
                    renderer=None, usar_marcador=True, marcador_valor=None,
                    verbose=True):
    """
    Percorre os arquivos UMA vez, calculando estatísticas por passo.

    Quando um renderizador é fornecido, o mapa do passo é desenhado e gravado
    ainda dentro do laço, com o campo já em memória; nada da série fica
    retido.  É isso que permite gerar uma figura para CADA saída NetCDF sem
    que o consumo de memória cresça com a duração da integração.

    Retorna (stats, agg, lat, lon, attrs, n_marcador_por_passo)
      stats : {campo: [dict_por_passo, ...]}      (escalares, já escalados)
      agg   : {campo: agregado global}
    """
    plot_idx = set(plot_idx)
    stats = {f: [] for f in field_names}
    agg = {f: _novo_agregado() for f in field_names}
    marcador_passo = []
    lat = lon = None
    attrs = {}
    ausentes = {f: 0 for f in field_names}
    n = len(files)
    n_mapas = len(plot_idx)
    i_mapa = 0

    for k, fpath in enumerate(files):
        if verbose and (n <= 20 or k % max(1, n // 20) == 0 or k == n - 1):
            pct = 100.0 * (k + 1) / n
            print(f"\r  Lendo diagnósticos: {k+1:5d}/{n}  ({pct:5.1f}%)",
                  end='', flush=True)

        campos_passo = {}
        with Dataset(fpath, 'r') as ds:
            if lat is None:
                v_lat = ds.variables.get('lat', ds.variables.get('latitude'))
                v_lon = ds.variables.get('lon', ds.variables.get('longitude'))
                lat = np.array(v_lat[:], dtype=float) if v_lat is not None else None
                lon = np.array(v_lon[:], dtype=float) if v_lon is not None else None
                for a in ds.ncattrs():
                    attrs[a] = getattr(ds, a)

            n_marc_passo = 0
            for fname in field_names:
                meta = FIELD_META.get(fname, {})
                if fname not in ds.variables:
                    ausentes[fname] += 1
                    stats[fname].append(None)
                    campos_passo[fname] = None
                    continue

                var = ds.variables[fname]
                arr = np.array(var[:], dtype=np.float64)

                # _FillValue declarado: comparação relativa (o valor típico
                # -9.99e20 nunca casaria com tolerância absoluta).
                fill = getattr(var, '_FillValue', None)
                if fill is not None:
                    arr = np.where(np.isclose(arr, float(fill), rtol=1e-3, atol=0),
                                   np.nan, arr)

                arr, n_marc = aplicar_mascaras(arr, meta, usar_marcador,
                                               marcador_valor)
                n_marc_passo += n_marc

                arr = orientar_lat_lon(arr, lat, lon)
                st = estatisticas_camada(arr, meta.get('scale', 1.0))
                stats[fname].append(st)
                _acumular(agg[fname], st, arr, fname)
                agg[fname]['n_marcador'] += n_marc
                campos_passo[fname] = arr

            marcador_passo.append(n_marc_passo)

        if renderer is not None and k in plot_idx:
            if verbose:
                print()
            i_mapa += 1
            renderer.render(k, timestamps[k], campos_passo, lat, lon,
                            i_mapa, n_mapas)
        del campos_passo

    if verbose:
        print()

    for fname, n_aus in ausentes.items():
        if 0 < n_aus < n:
            print(f"  AVISO: campo '{fname}' ausente em {n_aus} de {n} arquivos "
                  f"— os passos sem o campo aparecem como lacuna, sem "
                  f"deslocamento da série.")

    return stats, agg, lat, lon, attrs, marcador_passo


def orientar_lat_lon(arr, lat, lon):
    """
    Garante orientação (nlat, nlon).

    O Fortran declara a variável com [dimid_lon, dimid_lat]; conforme a versão
    do escritor, a leitura pode chegar como (nlon, nlat).  A decisão usa os
    tamanhos reais de lat e lon; a heurística nlat<nlon só entra quando as
    coordenadas não estão disponíveis (BUG-PY-22).
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


# ─── Estatísticas ─────────────────────────────────────────────────────────────

def print_stats(timestamps, stats, field_names, max_rows=40):
    """Tabela por campo e passo, em unidades de exibição."""
    hdr = "══" * 50
    print(f"\n{hdr}")
    print("  ESTATÍSTICAS — MED exportState → MOM6 importState (fluxos ATM→OCN)")
    print(f"{hdr}\n")

    n = len(timestamps)
    if max_rows and n > max_rows:
        metade = max_rows // 2
        mostrar = list(range(metade)) + list(range(n - metade, n))
        corte = metade
    else:
        mostrar = list(range(n))
        corte = None

    for fname in field_names:
        serie = stats.get(fname)
        if not serie or all(s is None for s in serie):
            continue
        meta = FIELD_META.get(fname, {'long_name': fname, 'scale_units': '?'})
        print(f"  ┌─ {fname}  —  {meta['long_name']}  [{meta['scale_units']}]")
        print(f"  │  {'Passo':6s}  {'Data/hora':22s}  {'Mínimo':>12s}  {'Máximo':>12s}"
              f"  {'Média':>12s}  {'DesvPad':>10s}  {'Cobert.':>8s}")
        print(f"  │  {'─'*94}")

        for pos, k in enumerate(mostrar):
            if corte is not None and pos == corte:
                print(f"  │  {'...':6s}  ({n - max_rows} passo(s) omitido(s); "
                      f"use --max-rows 0 para listar todos)")
            st = serie[k]
            ts_txt = timestamps[k].strftime('%Y-%m-%d %H:%M')
            if st is None:
                print(f"  │  {k+1:6d}  {ts_txt:22s}  {'(campo ausente)':>50s}")
                continue
            if st['n_valid'] == 0:
                print(f"  │  {k+1:6d}  {ts_txt:22s}"
                      f"  {'(sem dados)':>50s}  {st['cov']:>7.1f}%")
                continue
            print(f"  │  {k+1:6d}  {ts_txt:22s}"
                  f"  {st['min']:12.4f}  {st['max']:12.4f}"
                  f"  {st['mean']:12.4f}  {st['std']:10.4f}  {st['cov']:>7.1f}%")

        # Agregado da série: média e desvio padrão ponderados pelo número de
        # células válidas de cada passo (equivale a tratar todos os pontos
        # de todos os passos como uma amostra única, sem materializá-la).
        n_tot = sum(s['n_valid'] for s in serie if s and s.get('n_valid'))
        if n_tot > 0:
            soma = sum(s['sum'] for s in serie if s and s.get('n_valid'))
            somaq = sum(s['sumsq'] for s in serie if s and s.get('n_valid'))
            media = soma / n_tot
            var = max(somaq / n_tot - media * media, 0.0)
            gmin = min(s['min'] for s in serie if s and s.get('n_valid'))
            gmax = max(s['max'] for s in serie if s and s.get('n_valid'))
            print(f"  │  {'─'*94}")
            print(f"  │  {'SÉRIE':6s}  {'(todos os passos)':22s}"
                  f"  {gmin:12.4f}  {gmax:12.4f}"
                  f"  {media:12.4f}  {np.sqrt(var):10.4f}")
        print(f"  └{'─'*96}\n")


# ─── Verificação de limites físicos ───────────────────────────────────────────

def check_physics(agg, field_names, usar_marcador=True):
    print("\n  ┌─ VERIFICAÇÃO FÍSICA ─────────────────────────────────────────────────")
    ok_count = warn_count = 0

    for fname in field_names:
        meta = FIELD_META.get(fname, {})
        a = agg.get(fname)
        if a is None or a['n'] == 0:
            if meta.get('optional', False):
                print(f"  │  ℹ {fname}: campo opcional não presente")
            continue

        vmin = meta.get('vmin_phys')
        vmax = meta.get('vmax_phys')
        sunits = meta.get('scale_units', meta.get('units', ''))
        fmin_s, fmax_s = a['min'], a['max']

        if vmin is not None and fmin_s < vmin:
            print(f"  │  ⚠ {fname}: min={fmin_s:.4f} < {vmin}  [{sunits}] — "
                  f"{meta.get('check_msg','')}")
            warn_count += 1
        elif vmax is not None and fmax_s > vmax:
            print(f"  │  ⚠ {fname}: max={fmax_s:.4f} > {vmax}  [{sunits}] — "
                  f"{meta.get('check_msg','')}")
            warn_count += 1
        else:
            print(f"  │  ✓ {fname}: [{fmin_s:.4f}, {fmax_s:.4f}] [{sunits}] "
                  f"dentro de [{vmin}, {vmax}]")
            ok_count += 1

    # SST em °C: relatada apenas quando a verificação em K passou, para não
    # emitir dois avisos sobre o mesmo problema.
    a_sst = agg.get('So_t')
    if a_sst and a_sst['n'] > 0:
        meta_st = FIELD_META['So_t']
        ok_k = (a_sst['min'] >= meta_st['vmin_phys']
                and a_sst['max'] <= meta_st['vmax_phys'])
        if ok_k:
            c_min = a_sst['min'] - SST_CELSIUS_OFFSET
            c_max = a_sst['max'] - SST_CELSIUS_OFFSET
            c_med = a_sst['sum'] / a_sst['n'] - SST_CELSIUS_OFFSET
            if c_min >= -2.5 and c_max <= 42.0:
                print(f"  │  ✓ So_t em °C: [{c_min:.2f}, {c_max:.2f}] "
                      f"(média {c_med:.2f}) — conversão consistente")
                ok_count += 1
        if usar_marcador and a_sst['n_marcador'] > 0:
            print(f"  │  ℹ So_t: {a_sst['n_marcador']} célula(s) removida(s) como "
                  f"marcador de terra ({FIELD_META['So_t']['land_marker']} K).")
            print(f"  │     Use --no-land-marker para ver o campo sem remoção; "
                  f"a correção definitiva é gravar _FillValue no MED.")

    a_ice = agg.get('Si_ifrac')
    if a_ice and a_ice['n'] > 0:
        if a_ice['n_gt1'] == 0 and a_ice['n_lt0'] == 0:
            print("  │  ✓ Si_ifrac: clamping [0,1] verificado — sem valores fora do intervalo")
            ok_count += 1
        else:
            print(f"  │  ⚠ Si_ifrac: {a_ice['n_gt1']} valores > 1 e "
                  f"{a_ice['n_lt0']} < 0 — clamping incompleto")
            warn_count += 1
        ice_max = a_ice['max_raw']
        ice_mean = a_ice['sum_raw'] / max(a_ice['n_raw'], 1)
        if ice_max < 0.05:
            print(f"  │  ⚠ Si_ifrac: max={ice_max:.4f} < 0.05 — DUPLA divisão por 100.")
            print("  │     Definir datocn_ice_pct=.false. em nuopc.input")
            warn_count += 1
        elif ice_max > 1.05:
            print(f"  │  ⚠ Si_ifrac: max={ice_max:.4f} > 1.05 — dados em % sem /100.")
            print("  │     Definir datocn_ice_pct=.true. em nuopc.input")
            warn_count += 1
        else:
            print(f"  │  ✓ Si_ifrac: max={ice_max:.4f} — escala [0,1] correta "
                  f"(média global {ice_mean:.4f})")
            ok_count += 1

    print(f"  └─ {ok_count} OK, {warn_count} avisos\n")
    return warn_count == 0


# ─── Exportação CSV ───────────────────────────────────────────────────────────

def export_csv(timestamps, stats, field_names, outdir):
    os.makedirs(outdir, exist_ok=True)
    consolidated = os.path.join(outdir, 'mom6_import_stats.csv')

    campos = [f for f in field_names
              if stats.get(f) and any(s is not None for s in stats[f])]
    colunas = ['timestamp']
    for f in campos:
        colunas += [f'{f}_min', f'{f}_p05', f'{f}_p95', f'{f}_max',
                    f'{f}_mean', f'{f}_std', f'{f}_cov']

    with open(consolidated, 'w', newline='', encoding='utf-8') as fh:
        writer = csv.DictWriter(fh, fieldnames=colunas)
        writer.writeheader()
        for k, ts in enumerate(timestamps):
            row = {'timestamp': ts.strftime('%Y-%m-%dT%H:%M:%S')}
            for f in campos:
                st = stats[f][k]
                if st is None or st.get('n_valid', 0) == 0:
                    for suf in ('min', 'p05', 'p95', 'max', 'mean', 'std'):
                        row[f'{f}_{suf}'] = 'NaN'
                    row[f'{f}_cov'] = f"{(st or {}).get('cov', 0.0):.2f}"
                    continue
                row[f'{f}_min'] = f"{st['min']:.6f}"
                row[f'{f}_p05'] = f"{st['p05']:.6f}"
                row[f'{f}_p95'] = f"{st['p95']:.6f}"
                row[f'{f}_max'] = f"{st['max']:.6f}"
                row[f'{f}_mean'] = f"{st['mean']:.6f}"
                row[f'{f}_std'] = f"{st['std']:.6f}"
                row[f'{f}_cov'] = f"{st['cov']:.2f}"
            writer.writerow(row)
    print(f"  CSV consolidado : {consolidated}")


# ─── Apoio à plotagem ─────────────────────────────────────────────────────────

def preparar_longitude(lon):
    """
    Converte a grade 0→360 em -180→180 e devolve (lon_ordenado, permutação).

    Sem essa conversão os contornos de costa do Natural Earth ficam deslocados
    em relação ao preenchimento.
    """
    lon_plot = np.asarray(lon, dtype=float)
    if lon_plot.size == 0:
        return lon_plot, np.arange(0)
    if lon_plot[0] >= 0 and lon_plot[-1] > 180:
        lon_plot = np.where(lon_plot >= 180, lon_plot - 360, lon_plot)
        idx = np.argsort(lon_plot)
        return lon_plot[idx], idx
    return lon_plot, np.arange(lon_plot.size)


def testar_feicoes_cartopy(cfeature):
    """
    Verifica UMA vez se as feições do Natural Earth estão disponíveis.

    Em nó de execução sem saída para a internet e sem cache local, o download
    ocorre no momento do desenho e derruba a gravação da figura.  Testar antes
    permite gerar as figuras sem contorno de costa, com aviso.
    """
    try:
        next(iter(cfeature.LAND.geometries()))
        return True
    except Exception as exc:                                  # noqa: BLE001
        print(f"  AVISO: feições geográficas do cartopy indisponíveis ({exc.__class__.__name__}).")
        print("         Mapas gerados sem contorno de costa. Para habilitar, "
              "faça o cache do Natural Earth em nó com rede:")
        print("         python3 -c \"import cartopy.feature as cf; "
              "list(cf.LAND.geometries())\"")
        return False


def _cmap_com_nodata(plt, nome):
    """Paleta com cor explícita para célula sem dado (BUG-PY-20)."""
    cmap = plt.get_cmap(nome).copy()
    cmap.set_bad(NODATA_COLOR)
    return cmap


# ─── Mapas ────────────────────────────────────────────────────────────────────

class RenderizadorMapas:
    """
    Desenha e grava o mapa multi-painel de UM passo por vez.

    O objeto guarda apenas o que é constante entre os passos (coordenadas,
    disponibilidade do cartopy, paletas).  O campo do passo é recebido, usado
    e descartado, de modo que gerar uma figura para cada saída NetCDF não faz
    o consumo de memória crescer com o número de passos.
    """

    def __init__(self, field_names, outdir, coupling_mode=None, dpi=130):
        self.field_names = field_names
        self.outdir = outdir
        self.coupling_mode = coupling_mode
        self.dpi = dpi
        self.disponivel = False
        self.n_geradas = 0
        self._preparado = False
        self.plt = None
        self.ccrs = None
        self.cfeature = None
        self.usa_cartopy = False
        self.tem_feicoes = False

        try:
            import matplotlib
            matplotlib.use('Agg')
            import matplotlib.pyplot as plt
        except ImportError:
            print("  matplotlib não disponível — mapas ignorados.")
            return
        self.plt = plt
        self.disponivel = True

        try:
            import cartopy.crs as ccrs
            import cartopy.feature as cfeature
            self.ccrs, self.cfeature = ccrs, cfeature
            self.usa_cartopy = True
        except ImportError:
            print("  AVISO: cartopy não disponível — mapas sem contornos de costa")

    # ── Preparação única, quando as coordenadas ficam conhecidas ─────────────
    def _preparar(self, lat, lon):
        os.makedirs(self.outdir, exist_ok=True)
        self.lon_plot, self.idx_sorted = preparar_longitude(lon)
        self.LON2D, self.LAT2D = np.meshgrid(self.lon_plot,
                                             np.asarray(lat, dtype=float))
        self.tem_feicoes = (testar_feicoes_cartopy(self.cfeature)
                            if self.usa_cartopy else False)
        self._cache_cmap = {}
        self._preparado = True

    def _cmap(self, nome):
        if nome not in self._cache_cmap:
            self._cache_cmap[nome] = _cmap_com_nodata(self.plt, nome)
        return self._cache_cmap[nome]

    def _moldura(self, ax):
        if not self.usa_cartopy:
            return
        if self.tem_feicoes:
            # Terra acima do dado: campo oceânico não deixa buraco branco no
            # continente e campo atmosférico não exibe valor sobre terra.
            ax.add_feature(self.cfeature.LAND, facecolor='lightgray', zorder=5)
            ax.add_feature(self.cfeature.COASTLINE, linewidth=0.5,
                           edgecolor='black', zorder=6)
            ax.add_feature(self.cfeature.BORDERS, linewidth=0.3, linestyle=':',
                           edgecolor='gray', zorder=6)
        ax.set_extent([-180, 180, -90, 90], self.ccrs.PlateCarree())

    # ── Um passo ─────────────────────────────────────────────────────────────
    def render(self, k, ts, campos, lat, lon, i_mapa=0, n_mapas=0):
        if not self.disponivel:
            return
        if lon is None or lat is None:
            if not self._preparado:
                print("  AVISO: coordenadas ausentes — mapas ignorados.")
                self.disponivel = False
            return
        if not self._preparado:
            self._preparar(lat, lon)

        plt = self.plt
        presentes = [f for f in self.field_names if f in campos]
        if not presentes:
            return
        ncols = 2
        nrows = (len(presentes) + 1) // 2

        kw = {'projection': self.ccrs.PlateCarree()} if self.usa_cartopy else {}
        fig, axes = plt.subplots(nrows, ncols, figsize=(14, 4 * nrows),
                                 subplot_kw=kw if self.usa_cartopy else None,
                                 constrained_layout=True)
        axes = np.array(axes).flatten()

        for ax_i, fname in enumerate(presentes):
            meta = FIELD_META.get(fname, {'long_name': fname, 'scale_units': '?',
                                          'cmap': 'viridis', 'vperc': [2, 98],
                                          'symmetric': False})
            ax = axes[ax_i]
            ax.set_facecolor(NODATA_COLOR)   # ausência de dado nunca é branca
            layer = campos.get(fname)

            if layer is not None and layer.ndim == 2 \
                    and layer.shape[1] == self.idx_sorted.size:
                layer = layer[:, self.idx_sorted]

            sc_plot = meta.get('scale', 1.0)
            layer_plt = None if layer is None else np.asarray(layer, dtype=float) * sc_plot
            flat = (np.array([]) if layer_plt is None
                    else layer_plt[np.isfinite(layer_plt)])

            if flat.size == 0:
                ax.text(0.5, 0.5,
                        "Campo indisponível neste passo\n"
                        "(aguardando primeiro avanço MOM6)",
                        ha='center', va='center', transform=ax.transAxes,
                        fontsize=9, color='#555555',
                        bbox=dict(boxstyle='round,pad=0.4', fc='white',
                                  ec='#aaaaaa', alpha=0.85))
                ax.set_title(f"{fname} — {meta['long_name']}\n"
                             f"{ts.strftime('%Y-%m-%d %H:%M')}  (passo {k+1})",
                             fontsize=9)
                self._moldura(ax)
                continue

            phys_min = meta.get('vmin_phys')
            phys_max = meta.get('vmax_phys')

            # Percentis: em campo simétrico o zero exato costuma ser
            # preenchimento residual e distorce o percentil; em campo não
            # simétrico o zero é física legítima.
            if meta.get('symmetric', False):
                arr_perc = np.where(layer_plt == 0.0, np.nan, layer_plt)
            else:
                arr_perc = layer_plt

            ice_area_info = ''
            if meta.get('binary_field', False) and flat.max() > 0.9:
                perc95 = float(np.nanpercentile(flat, 95))
                mean_f = float(np.nanmean(flat))
                if perc95 < 0.01 and mean_f > 0:
                    perc98 = float(np.nanpercentile(flat, 98))
                    vmin = 0.0
                    vmax = min(max(mean_f * 30, 0.005, perc98 * 2.0), 1.0)
                    n_ice = int(np.sum(flat >= 0.5))
                    ice_area_info = (f" | ~{n_ice} cél. "
                                     f"({100*n_ice/max(flat.size,1):.3f}%)")
                else:
                    vmin, vmax = 0.0, 1.0
            else:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", RuntimeWarning)
                    vmin = float(np.nanpercentile(arr_perc, meta['vperc'][0]))
                    vmax = float(np.nanpercentile(arr_perc, meta['vperc'][1]))
                if not (np.isfinite(vmin) and np.isfinite(vmax)):
                    vmin = phys_min if phys_min is not None else -1.0
                    vmax = phys_max if phys_max is not None else 1.0

                if meta.get('symmetric', False):
                    v = max(abs(vmin), abs(vmax))
                    if phys_max is not None:
                        v = min(v, phys_max)
                    if v < 1e-12:
                        v = phys_max if phys_max is not None else 1.0
                    vmin, vmax = -v, v
                else:
                    if phys_min is not None:
                        vmin = max(vmin, phys_min)
                    if phys_max is not None:
                        vmax = min(vmax, phys_max)
                    if abs(vmax - vmin) < 1e-12:
                        if phys_max is not None and phys_max > vmin:
                            vmax = phys_max
                        else:
                            vmax = vmin + max(abs(vmin) * 0.01, 1e-6)

            campo_ma = np.ma.masked_invalid(layer_plt)
            pk = dict(cmap=self._cmap(meta['cmap']), vmin=vmin, vmax=vmax,
                      shading='nearest', zorder=1)
            if self.usa_cartopy:
                im = ax.pcolormesh(self.LON2D, self.LAT2D, campo_ma,
                                   transform=self.ccrs.PlateCarree(), **pk)
            else:
                im = ax.pcolormesh(self.LON2D, self.LAT2D, campo_ma, **pk)
            self._moldura(ax)

            # extend indica que há valores além dos limites de exibição.
            abaixo = bool(np.any(flat < vmin))
            acima = bool(np.any(flat > vmax))
            extend = ('both' if abaixo and acima else
                      'min' if abaixo else 'max' if acima else 'neither')
            plt.colorbar(im, ax=ax, orientation='vertical',
                         label=meta['scale_units'], fraction=0.025, pad=0.02,
                         extend=extend)

            n_falta = int(np.count_nonzero(~np.isfinite(layer_plt)))
            frac_falta = 100.0 * n_falta / max(layer_plt.size, 1)
            ax.set_title(f"{fname} — {meta['long_name']}\n"
                         f"{ts.strftime('%Y-%m-%d %H:%M')}  (passo {k+1})"
                         f"{ice_area_info}  |  sem dado: {frac_falta:.1f}%",
                         fontsize=9)

        for ax in axes[len(presentes):]:
            ax.set_visible(False)

        fig.suptitle(
            f"MED exportState → MOM6 importState — Fluxos ATM→OCN\n"
            f"Passo {k+1}  |  {ts.strftime('%Y-%m-%d %H:%M')}  |  "
            f"MONAN-A 2.0 / INPE/CGCT/DIMNT",
            fontsize=11)
        fig.text(0.5, 0.005, consumption_note(self.coupling_mode, k),
                 ha='center', va='bottom', fontsize=8, color='0.35')

        outfile = os.path.join(self.outdir,
                               f"mom6_import_{ts.strftime('%Y%m%d_%H%M%S')}.png")
        fig.savefig(outfile, dpi=self.dpi, facecolor='white')
        plt.close(fig)
        self.n_geradas += 1
        prefixo = f"  [{i_mapa:5d}/{n_mapas}]" if n_mapas else "  "
        print(f"{prefixo} Figura: {outfile}")


# ─── Série temporal ───────────────────────────────────────────────────────────

def plot_timeseries(timestamps, stats, field_names, outdir):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
    except ImportError:
        return

    os.makedirs(outdir, exist_ok=True)
    available = [f for f in field_names
                 if stats.get(f) and any(s is not None for s in stats[f])]
    if not available:
        return

    nrows = (len(available) + 1) // 2
    fig, axes = plt.subplots(nrows, 2, figsize=(14, 3.5 * nrows),
                             sharex=True, constrained_layout=True)
    axes = np.array(axes).flatten()

    def _serie(fname, chave):
        return np.array([np.nan if (s is None or s.get('n_valid', 0) == 0)
                         else s[chave] for s in stats[fname]], dtype=float)

    for ax, fname in zip(axes, available):
        meta = FIELD_META.get(fname, {'long_name': fname, 'scale_units': '?'})
        means = _serie(fname, 'mean')
        p02 = _serie(fname, 'p02')
        p98 = _serie(fname, 'p98')

        ax.fill_between(timestamps, p02, p98, alpha=0.18, color='steelblue',
                        label='P₂–P₉₈')
        ax.plot(timestamps, means, lw=1.6, color='steelblue', label='média')
        ax.set_ylabel(meta['scale_units'], fontsize=9)
        ax.set_title(f"{fname}  —  {meta['long_name']}", fontsize=9)
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8, loc='upper right')

        # BUG-PY-14 (B): escala symlog para campos quase binários com sinal
        # pequeno, senão a curva de Si_ifrac fica colada no zero.
        if meta.get('binary_field', False):
            finitos = means[np.isfinite(means)]
            max_mean = float(finitos.max()) if finitos.size else 0.0
            if 0 < max_mean < 0.1:
                linthresh = max(max_mean * 0.05, 1e-6)
                ax.set_yscale('symlog', linthresh=linthresh)
                ax.axhline(linthresh, color='gray', lw=0.6, ls=':', alpha=0.5)
                ax.set_ylabel(f"{meta['scale_units']} (symlog)", fontsize=9)

    # BUG-PY-17: localizador automático — o intervalo pode ser de horas a meses.
    locator = mdates.AutoDateLocator(minticks=4, maxticks=9)
    formatter = mdates.ConciseDateFormatter(locator)
    for ax in axes[:len(available)]:
        ax.xaxis.set_major_locator(locator)
        ax.xaxis.set_major_formatter(formatter)

    for ax in axes[len(available):]:
        ax.set_visible(False)

    fig.suptitle(
        f"MED exportState → MOM6 importState — séries temporais dos fluxos ATM→OCN\n"
        f"{timestamps[0].strftime('%Y-%m-%d %H:%M')} → "
        f"{timestamps[-1].strftime('%Y-%m-%d %H:%M')}"
        f"  |  {len(timestamps)} passos  |  INPE/CGCT/DIMNT",
        fontsize=11)

    outfile = os.path.join(outdir, 'mom6_import_timeseries.png')
    fig.savefig(outfile, dpi=130, facecolor='white')
    plt.close(fig)
    print(f"  Série temporal: {outfile}")


# ─── Modo de acoplamento ──────────────────────────────────────────────────────

def read_coupling_mode(diagdir):
    """
    Le coupling_mode do &nuopc_petlayout da nuopc.input do experimento.

    Procura a nuopc.input subindo a partir de --diagdir.  Devolve 'sequential',
    'concurrent' ou None quando nao encontra.
    """
    cand = []
    d = os.path.abspath(diagdir)
    for _ in range(3):
        cand.append(os.path.join(d, 'nuopc.input'))
        d = os.path.dirname(d)
    for f in cand:
        if not os.path.isfile(f):
            continue
        try:
            with open(f, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    line = line.split('!')[0]
                    if 'coupling_mode' in line and '=' in line:
                        v = line.split('=', 1)[1].strip().strip("'\"").lower()
                        if v in ('sequential', 'concurrent'):
                            return v
        except OSError:
            continue
    return None


def consumption_note(mode, k):
    """
    Rodape que diz em QUE passo o oceano consome os fluxos exibidos.

      sequential : o mediador roda no MEIO do passo, entao os fluxos exibidos
                   sao os que o MOM6 consome NESTE mesmo passo. No passo 1 o
                   mediador ainda nao viu nenhum avanco do MPAS: radiacao,
                   precipitacao e pressao saem nulas.

      concurrent : o mediador roda no FIM do passo, entao os fluxos exibidos
                   so' chegam ao MOM6 no passo SEGUINTE (lag de 1 dt_coupling).

    Comparacao correta entre modos: sequencial passo N+1 x concorrente passo N.
    """
    if mode == 'sequential':
        txt = (f"coupling_mode=sequential — fluxos consumidos pelo MOM6 "
               f"NESTE passo ({k+1})")
        if k == 0:
            txt += ("  |  passo 1: radiacao/precipitacao/pressao nulas "
                    "(mediador roda antes do 1o avanco do MPAS)")
        return txt
    if mode == 'concurrent':
        return (f"coupling_mode=concurrent — fluxos consumidos pelo MOM6 no "
                f"passo {k+2} (lag de 1 dt_coupling)")
    return ("coupling_mode nao identificado — o passo em que o MOM6 consome "
            "estes fluxos depende do modo (ver README, secao 6.2)")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Validação dos campos importados pelo MOM6+SIS2 (fluxos ATM→OCN do mediador).',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)

    parser.add_argument('--diagdir', default='diag_import',
                        help='Diretório com mom6_import_*.nc (padrão: diag_import)')
    parser.add_argument('--outdir', default='diag_import/postproc',
                        help='Saída: CSV e figuras (padrão: diag_import/postproc)')
    parser.add_argument('--field', nargs='+', default=FIELDS,
                        help='Campos a processar (padrão: os catalogados)')
    parser.add_argument('--all-fields', action='store_true', dest='all_fields',
                        help='Processa TODAS as variáveis 2-D do arquivo, '
                             'inclusive as ainda não catalogadas em FIELD_META')

    parser.add_argument('--stats', action='store_true', help='Estatísticas globais')
    parser.add_argument('--check', action='store_true', help='Verificação de limites físicos')
    parser.add_argument('--csv', action='store_true', help='Exportar CSV')
    parser.add_argument('--plot', action='store_true', help='Gerar mapas e série temporal')
    parser.add_argument('--all', action='store_true', help='Todos os modos [padrão]')

    parser.add_argument('--step', nargs='+', type=int, default=None,
                        help='Passos específicos a plotar (base 1). '
                             'Padrão: todos os passos')
    parser.add_argument('--all-steps', action='store_true', dest='all_steps',
                        help='Mantido por compatibilidade: plotar todos os '
                             'passos já é o padrão')

    # Controle de volume em integrações longas
    parser.add_argument('--stride', type=int, default=1,
                        help='Processa 1 a cada N arquivos (padrão: 1)')
    parser.add_argument('--tmin', default=None,
                        help='Início da janela (YYYY-MM-DD[THH:MM])')
    parser.add_argument('--tmax', default=None,
                        help='Fim da janela (YYYY-MM-DD[THH:MM])')
    parser.add_argument('--max-maps', type=int, default=0, dest='max_maps',
                        help='Teto de figuras de mapa por execução '
                             '(padrão: 0 = uma figura por saída NetCDF)')
    parser.add_argument('--dpi', type=int, default=130,
                        help='Resolução das figuras (padrão: 130)')
    parser.add_argument('--max-rows', type=int, default=40, dest='max_rows',
                        help='Teto de linhas por campo na tabela (0 = todas)')

    # Mascaramento
    parser.add_argument('--no-land-marker', action='store_false',
                        dest='land_marker_on',
                        help='Não remover o marcador de terra do So_t')
    parser.add_argument('--land-marker', type=float, default=None,
                        help='Valor do marcador de terra em K (padrão: 271.35)')

    args = parser.parse_args()

    if not any([args.stats, args.check, args.csv, args.plot, args.all]):
        args.all = True
    if args.all:
        args.stats = args.check = args.csv = args.plot = True
    if args.stride < 1:
        sys.exit("ERRO: --stride deve ser >= 1.")

    print()
    print('═' * 70)
    print('  MONAN-A 2.0 — Validação de campos importados MOM6 (ATM→OCN)')
    print('  INPE / CGCT / DIMNT — GT Acoplamento de Modelos  (v9.1)')
    print('═' * 70)
    print(f"  Diagnósticos : {os.path.abspath(args.diagdir)}")
    print(f"  Saída        : {os.path.abspath(args.outdir)}")

    timestamps_all, files_all = find_diag_files(args.diagdir)
    timestamps, files = filtrar_arquivos(
        timestamps_all, files_all,
        parse_datahora(args.tmin), parse_datahora(args.tmax), args.stride)

    if args.all_fields:
        args.field = descobrir_campos(files[0])
        novos = [f for f in args.field if f not in FIELD_META]
        if novos:
            print(f"  Campos não catalogados incluídos por --all-fields: "
                  f"{', '.join(novos)}")
    print(f"  Campos       : {', '.join(args.field)}")
    print()

    print(f"  Arquivos MOM6 diag : {len(files_all)} encontrado(s), "
          f"{len(files)} selecionado(s)")
    print(f"  Primeiro           : {os.path.basename(files[0])}")
    print(f"  Último             : {os.path.basename(files[-1])}")
    if args.stride > 1:
        print(f"  Amostragem         : 1 a cada {args.stride} arquivo(s)")
    print()

    nsteps = len(files)
    step_indices = (selecionar_passos_mapa(nsteps, args.step, args.max_maps)
                    if args.plot else [])

    coupling_mode = read_coupling_mode(args.diagdir)
    if coupling_mode:
        print(f"  coupling_mode      : {coupling_mode}")
        if coupling_mode == 'sequential':
            print("    fluxos exibidos sao consumidos pelo MOM6 no MESMO passo;")
            print("    o passo 1 tem radiacao/precipitacao/pressao nulas (spin-up).")
        else:
            print("    fluxos exibidos sao consumidos pelo MOM6 no passo SEGUINTE")
            print("    (lag de 1 dt_coupling); a forcante do passo 1 nao e' plotada.")
    else:
        print("  coupling_mode      : nao identificado (nuopc.input nao encontrada)")
    print()

    renderer = None
    if args.plot and step_indices:
        print(f"  [--plot] {len(step_indices)} figura(s) de mapa serão geradas "
              f"em {os.path.abspath(args.outdir)}")
        if len(step_indices) > 200:
            print(f"           Volume estimado: ~{len(step_indices)*1.5:.0f} MB "
                  f"e alguns minutos de desenho. Use --max-maps ou --step "
                  f"para reduzir.")
        renderer = RenderizadorMapas(args.field, args.outdir,
                                     coupling_mode=coupling_mode, dpi=args.dpi)

    # Uma única passagem: estatísticas de todos os passos e, para os passos
    # selecionados, a figura desenhada com o campo ainda em memória.
    stats, agg, lat, lon, attrs, marc_passo = scan_diag_files(
        files, timestamps, args.field, step_indices, renderer=renderer,
        usar_marcador=args.land_marker_on, marcador_valor=args.land_marker)

    print(f"  {nsteps} passo(s) processado(s)"
          + (f"; {renderer.n_geradas} figura(s) de mapa gerada(s)."
             if renderer is not None else "."))
    print()

    if attrs:
        print("  ┌─ Metadados CF registrados pelo MED_cap_MONAN ─────────────────────")
        for key in ['Conventions', 'title', 'institution', 'source',
                    'valid_time', 'nx_global', 'ny_global', 'petCount']:
            if key in attrs:
                print(f"  │  {key:15s} = {attrs[key]}")
        print(f"  └{'─'*67}\n")

    if args.stats:
        print("  [--stats] Calculando estatísticas...")
        print_stats(timestamps, stats, args.field, max_rows=args.max_rows)

    if args.check:
        print("  [--check] Verificando limites físicos...")
        check_physics(agg, args.field, args.land_marker_on)

    if args.csv:
        print("  [--csv] Exportando CSV...")
        export_csv(timestamps, stats, args.field, args.outdir)
        print()

    if args.plot:
        plot_timeseries(timestamps, stats, args.field, args.outdir)
        print()

    print('═' * 70)
    print('  Concluído.')
    print('═' * 70)
    print()


if __name__ == '__main__':
    main()
