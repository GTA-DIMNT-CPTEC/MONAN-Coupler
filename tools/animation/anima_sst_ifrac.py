#!/usr/bin/env python3
"""
anima_sst_ifrac.py — Gerador de GIF animado para diagnósticos SST/Si_ifrac
===========================================================================

Gera um GIF animado a partir das figuras produzidas por analisa_sst_ifrac.py:

  • diff_consec_*.png  — Diferença entre passos consecutivos δ(t) = campo(t) − campo(t−1)
  • anomalia_*.png     — Anomalia em relação ao instante inicial Δ(t) = campo(t) − campo(t₀)

INPE / CGCT / DIMNT — GT Acoplamento MONAN — Maio 2026

Dependências:
  pip install Pillow          (leitura/escrita de GIF — obrigatório)
  pip install imageio[ffmpeg] (opcional: exportação MP4)

Uso básico:
  python3 anima_sst_ifrac.py                           # diff_consec (padrão)
  python3 anima_sst_ifrac.py --tipo anomalia           # mapas de anomalia
  python3 anima_sst_ifrac.py --fps 2 --loop 0          # 2 fps, loop infinito
  python3 anima_sst_ifrac.py --escala 0.5              # reduz 50% (GIF menor)
  python3 anima_sst_ifrac.py --outfile meu_diag.gif    # nome personalizado
  python3 anima_sst_ifrac.py --mp4                     # também exporta MP4
  python3 anima_sst_ifrac.py --dir resultados/         # diretório de entrada
"""

import sys
import os
import glob
import re
import argparse
from pathlib import Path
from datetime import datetime

# ─── Verificação de dependências ─────────────────────────────────────────────

try:
    from PIL import Image
except ImportError:
    sys.exit(
        '\nERRO: Pillow não encontrado.\n'
        'Instale com:  pip install Pillow\n'
    )


# ─── Constantes ──────────────────────────────────────────────────────────────

VERSION = '1.0'

# Padrões de nome de arquivo gerados por analisa_sst_ifrac.py
PADROES = {
    'diff':     'diff_consec_*.png',
    'anomalia': 'anomalia_*.png',
}

# Regex para extrair o timestamp do nome do arquivo (YYYYMMDD_HHMMSS)
RE_TIMESTAMP = re.compile(r'(\d{8}_\d{6})')

# Diretório de saída padrão (mesmo usado por analisa_sst_ifrac.py)
DIR_PADRAO = os.path.join('diag_import', 'sst_ifrac_diag')


# ─── Funções auxiliares ───────────────────────────────────────────────────────

def _sep(char='═', n=70):
    print(char * n)


def _header():
    _sep()
    print(f'  Animação SST / Si_ifrac  —  v{VERSION}')
    print('  INPE / CGCT / DIMNT — GT Acoplamento MONAN')
    _sep()
    print()


def _extrair_timestamp(caminho: str):
    """
    Extrai o datetime do nome do arquivo.
    Retorna datetime ou None (usado para ordenação).
    """
    m = RE_TIMESTAMP.search(os.path.basename(caminho))
    if m:
        try:
            return datetime.strptime(m.group(1), '%Y%m%d_%H%M%S')
        except ValueError:
            pass
    return None


def _localizar_frames(dirpath: str, padrao: str) -> list[str]:
    """
    Localiza e ordena os arquivos PNG pelo timestamp no nome.
    Retorna lista de caminhos em ordem cronológica.
    """
    arquivos = sorted(
        glob.glob(os.path.join(dirpath, padrao)),
        key=lambda p: (_extrair_timestamp(p) or datetime.min, p),
    )
    return arquivos


def _redimensionar(img: Image.Image, escala: float) -> Image.Image:
    """Redimensiona a imagem mantendo a proporção."""
    if escala == 1.0:
        return img
    w = int(img.width  * escala)
    h = int(img.height * escala)
    return img.resize((w, h), Image.LANCZOS)


def _info_frames(caminhos: list[str]):
    """Imprime tabela com informações de cada frame."""
    print(f'  {"#":>4}  {"Arquivo":<45}  {"Data/hora":>19}')
    print('  ' + '─' * 73)
    for k, c in enumerate(caminhos, 1):
        ts = _extrair_timestamp(c)
        ts_str = ts.strftime('%Y-%m-%d %H:%M:%S') if ts else '—'
        nome   = os.path.basename(c)
        # Truncar nome se muito longo
        if len(nome) > 44:
            nome = nome[:41] + '...'
        print(f'  {k:>4}  {nome:<45}  {ts_str:>19}')
    print()


# ─── Geração do GIF ──────────────────────────────────────────────────────────

def gerar_gif(
    caminhos:  list[str],
    outfile:   str,
    fps:       float = 1.0,
    loop:      int   = 0,
    escala:    float = 1.0,
    otimizar:  bool  = True,
) -> dict:
    """
    Gera o GIF animado a partir de uma lista de arquivos PNG.

    Parâmetros
    ----------
    caminhos  : lista de caminhos PNG ordenados cronologicamente
    outfile   : caminho do arquivo GIF de saída
    fps       : quadros por segundo (padrão: 1.0)
    loop      : 0 = loop infinito; N = repetir N vezes; 1 = sem loop
    escala    : fator de escala da imagem (0.5 = metade do tamanho)
    otimizar  : aplica otimização de paleta Pillow (reduz tamanho do GIF)

    Retorna
    -------
    dict com estatísticas: n_frames, largura, altura, duracao_s, tamanho_mb
    """
    duracao_ms = int(1000.0 / fps)  # Pillow usa milissegundos por frame

    print(f'  Carregando {len(caminhos)} frame(s)...', end='', flush=True)
    frames = []
    for caminho in caminhos:
        img = Image.open(caminho).convert('RGBA')
        img = _redimensionar(img, escala)
        # GIF suporta paleta de 256 cores; converter de RGBA → P (paleta)
        # com dithering mínimo para manter qualidade científica.
        img_p = img.convert(
            'P',
            palette=Image.ADAPTIVE,
            colors=256,
        )
        frames.append(img_p)

    print(f' OK  ({frames[0].width}×{frames[0].height} px)')

    # Garantir que o diretório de saída existe
    os.makedirs(os.path.dirname(os.path.abspath(outfile)), exist_ok=True)

    print(f'  Escrevendo GIF: {outfile}', end='', flush=True)
    frames[0].save(
        outfile,
        format='GIF',
        save_all=True,
        append_images=frames[1:],
        duration=duracao_ms,
        loop=loop,
        optimize=otimizar,
        disposal=2,  # restaura fundo entre frames (evita artefatos)
    )
    print(' OK')

    tamanho_mb = os.path.getsize(outfile) / (1024 ** 2)

    return {
        'n_frames':   len(frames),
        'largura':    frames[0].width,
        'altura':     frames[0].height,
        'duracao_s':  len(frames) / fps,
        'tamanho_mb': tamanho_mb,
    }


# ─── Exportação opcional MP4 ─────────────────────────────────────────────────

def gerar_mp4(caminhos: list[str], outfile: str, fps: float, escala: float):
    """
    Exporta os frames como MP4 usando imageio[ffmpeg].
    Requer: pip install imageio[ffmpeg]
    """
    try:
        import imageio
    except ImportError:
        print('  AVISO: imageio não encontrado — MP4 ignorado.')
        print('         Instale com: pip install imageio[ffmpeg]')
        return

    import numpy as np

    print(f'  Escrevendo MP4: {outfile}', end='', flush=True)
    with imageio.get_writer(outfile, fps=fps, codec='libx264',
                            quality=8, macro_block_size=1) as writer:
        for caminho in caminhos:
            img = Image.open(caminho).convert('RGB')
            img = _redimensionar(img, escala)
            writer.append_data(np.array(img))
    print(' OK')


# ─── Relatório final ─────────────────────────────────────────────────────────

def _relatorio(stats: dict, outfile: str, fps: float, loop: int, escala: float):
    """Exibe resumo da animação gerada."""
    _sep('─')
    print(f'  GIF gerado com sucesso:')
    print()
    print(f'    Arquivo       : {os.path.abspath(outfile)}')
    print(f'    Resolução     : {stats["largura"]} × {stats["altura"]} px'
          + (f'  (escala {escala:.0%})' if escala != 1.0 else ''))
    print(f'    Frames        : {stats["n_frames"]}')
    print(f'    FPS           : {fps:.1f}  ({1000/fps:.0f} ms/frame)')
    duracao = stats['duracao_s']
    print(f'    Duração       : {duracao:.1f} s  ({duracao/60:.1f} min)')
    loop_str = 'infinito' if loop == 0 else (f'{loop}×' if loop > 1 else 'sem loop')
    print(f'    Loop          : {loop_str}')
    print(f'    Tamanho       : {stats["tamanho_mb"]:.1f} MB')
    print()
    _sep('─')
    print()


# ─── CLI ─────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        prog='anima_sst_ifrac.py',
        description='Gera GIF animado das figuras de diagnóstico SST/Si_ifrac.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Exemplos:\n'
            '  python3 anima_sst_ifrac.py\n'
            '  python3 anima_sst_ifrac.py --tipo anomalia --fps 2\n'
            '  python3 anima_sst_ifrac.py --escala 0.5 --loop 3\n'
            '  python3 anima_sst_ifrac.py --mp4 --fps 4\n'
        ),
    )

    parser.add_argument(
        '--tipo',
        choices=['diff', 'anomalia'],
        default='diff',
        help=(
            'Tipo de mapa a animar:\n'
            '  diff     — Diferença consecutiva δ(t) = campo(t)−campo(t−1)  [padrão]\n'
            '  anomalia — Anomalia Δ(t) = campo(t)−campo(t₀)'
        ),
    )
    parser.add_argument(
        '--dir',
        default=DIR_PADRAO,
        metavar='DIRETÓRIO',
        help=f'Diretório com as figuras PNG  [padrão: {DIR_PADRAO}]',
    )
    parser.add_argument(
        '--outfile',
        default=None,
        metavar='ARQUIVO.gif',
        help=(
            'Nome do arquivo GIF de saída.\n'
            'Padrão: <dir>/diff_consec_anim.gif ou anomalia_anim.gif'
        ),
    )
    parser.add_argument(
        '--fps',
        type=float,
        default=1.0,
        metavar='N',
        help='Quadros por segundo  [padrão: 1.0]',
    )
    parser.add_argument(
        '--loop',
        type=int,
        default=0,
        metavar='N',
        help='Número de repetições do GIF: 0=infinito, 1=uma vez  [padrão: 0]',
    )
    parser.add_argument(
        '--escala',
        type=float,
        default=1.0,
        metavar='FATOR',
        help='Fator de escala da imagem (ex.: 0.5 para metade)  [padrão: 1.0]',
    )
    parser.add_argument(
        '--sem-otimizar',
        action='store_true',
        dest='sem_otimizar',
        help='Desativa otimização de paleta Pillow (GIF maior, geração mais rápida)',
    )
    parser.add_argument(
        '--mp4',
        action='store_true',
        help='Também exporta MP4 via imageio[ffmpeg]',
    )
    parser.add_argument(
        '--listar',
        action='store_true',
        help='Lista os frames encontrados e encerra sem gerar o GIF',
    )

    return parser.parse_args()


# ─── Ponto de entrada ────────────────────────────────────────────────────────

def main():
    args = parse_args()

    _header()

    # ── Localizar frames ──────────────────────────────────────────────────────
    padrao  = PADROES[args.tipo]
    dirpath = args.dir

    print(f'  Tipo          : {args.tipo}  ({padrao})')
    print(f'  Diretório     : {os.path.abspath(dirpath)}')
    print()

    if not os.path.isdir(dirpath):
        sys.exit(
            f'ERRO: diretório não encontrado: {dirpath}\n'
            f'Verifique se analisa_sst_ifrac.py foi executado antes\n'
            f'ou ajuste --dir para o diretório correto.'
        )

    caminhos = _localizar_frames(dirpath, padrao)

    if not caminhos:
        sys.exit(
            f'ERRO: nenhum arquivo "{padrao}" encontrado em:\n'
            f'  {os.path.abspath(dirpath)}\n\n'
            f'Execute analisa_sst_ifrac.py --diff (ou --anomaly) primeiro.'
        )

    print(f'  {len(caminhos)} frame(s) encontrado(s):')
    print()
    _info_frames(caminhos)

    if args.listar:
        print('  (--listar: encerrando sem gerar GIF)')
        return

    # ── Validação de argumentos ───────────────────────────────────────────────
    if args.fps <= 0:
        sys.exit('ERRO: --fps deve ser positivo.')
    if not (0.1 <= args.escala <= 4.0):
        sys.exit('ERRO: --escala deve estar entre 0.1 e 4.0.')

    # ── Nome do arquivo de saída ──────────────────────────────────────────────
    if args.outfile:
        outfile_gif = args.outfile
    else:
        nome_gif = 'diff_consec_anim.gif' if args.tipo == 'diff' else 'anomalia_anim.gif'
        outfile_gif = os.path.join(dirpath, nome_gif)

    # ── Gerar GIF ─────────────────────────────────────────────────────────────
    print(f'  FPS           : {args.fps:.1f}  ({1000/args.fps:.0f} ms/frame)')
    print(f'  Escala        : {args.escala:.0%}')
    loop_str = 'infinito' if args.loop == 0 else (f'{args.loop}×' if args.loop > 1 else 'sem loop')
    print(f'  Loop          : {loop_str}')
    print(f'  Otimizar      : {"não" if args.sem_otimizar else "sim"}')
    print()

    stats = gerar_gif(
        caminhos  = caminhos,
        outfile   = outfile_gif,
        fps       = args.fps,
        loop      = args.loop,
        escala    = args.escala,
        otimizar  = not args.sem_otimizar,
    )

    # ── Exportar MP4 (opcional) ───────────────────────────────────────────────
    if args.mp4:
        outfile_mp4 = Path(outfile_gif).with_suffix('.mp4')
        gerar_mp4(caminhos, str(outfile_mp4), args.fps, args.escala)

    # ── Relatório ─────────────────────────────────────────────────────────────
    _relatorio(stats, outfile_gif, args.fps, args.loop, args.escala)


if __name__ == '__main__':
    main()
