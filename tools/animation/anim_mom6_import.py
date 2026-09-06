#!/usr/bin/env python3
"""
anim_mom6_import.py  —  Animação da evolução dos passos de acoplamento ATM→OCN
                         a partir dos mapas PNG gerados por postproc_mom6_import.py

Versão 1.2 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Set 2026

CORREÇÕES v1.2
  • BUG-ANIM-SIZE: quadros de tamanhos diferentes (PNGs com bbox_inches='tight')
    faziam o GIF "tremer" e quebravam o MP4. Todos os quadros passam a ser
    normalizados à MESMA dimensão (compostos sobre tela branca) antes de montar.
  • BUG-ANIM-MP4: o MP4 usava o concat demuxer com os PNGs originais (falhava
    com quadros de dimensão variável). Agora normaliza e codifica uma sequência
    numerada via image2 — dimensão constante e ordem determinística.
  • Novos parâmetros: --max-width (reduz o tamanho do arquivo) e --no-optimize.
  Observação 1: a ESCALA de cor consistente entre quadros é responsabilidade do
  postproc (v8.4). Observação 2: para uma animação COMPLETA, rode antes
  postproc_mom6_import.py --plot --all-steps (sem isso, o postproc plota apenas
  ~8 passos amostrados e a animação fica com poucos quadros e "saltos").

═══════════════════════════════════════════════════════════════════════════════
Contexto
═══════════════════════════════════════════════════════════════════════════════
O script postproc_mom6_import.py gera, para cada passo de acoplamento selecionado,
um mapa multi-painel com os 14 campos ATM→OCN calculados pelo mediador
MED_cap.F90 (bulk NCAR Large & Yeager 2009).  Esses mapas são gravados como:

  <outdir>/mom6_import_YYYYMMDD_HHMMSS.png

Este script lê esses PNGs em ordem cronológica e gera uma animação (GIF ou MP4)
que permite visualizar a evolução temporal dos campos ao longo do experimento.

═══════════════════════════════════════════════════════════════════════════════
Modos de saída
═══════════════════════════════════════════════════════════════════════════════
  GIF  — padrão; requer apenas Pillow (pip install Pillow)
  MP4  — requer ffmpeg acessível no PATH

═══════════════════════════════════════════════════════════════════════════════
Exemplos de uso
═══════════════════════════════════════════════════════════════════════════════
  # GIF com todos os quadros disponíveis, 1 FPS (padrão):
  python3 anim_mom6_import.py

  # GIF mais rápido, 1 quadro a cada 2 disponíveis:
  python3 anim_mom6_import.py --fps 2 --every 2

  # MP4 a 3 FPS em diretório personalizado:
  python3 anim_mom6_import.py --format mp4 --fps 3 --indir diag_import/figs

  # Animar apenas os passos 1, 5 e 10:
  python3 anim_mom6_import.py --step 1 5 10

  # Arquivo de saída explícito:
  python3 anim_mom6_import.py --outfile resultados/animacao_fase2.gif

═══════════════════════════════════════════════════════════════════════════════
Dependências
═══════════════════════════════════════════════════════════════════════════════
  Obrigatória : Pillow ≥ 9.0    (para GIF)  — pip install --user Pillow
  Opcional    : ffmpeg no PATH  (para MP4)  — module load ffmpeg  (Jaci)
"""

import os
import sys
import glob
import argparse
import subprocess
import tempfile
from datetime import datetime


# ─── Metadados do script ───────────────────────────────────────────────────────

PROG_VERSION = '1.2'

# Padrão de nome dos PNGs gerados por postproc_mom6_import.py (v8.1+):
#   mom6_import_YYYYMMDD_HHMMSS.png
PNG_PATTERN  = 'mom6_import_????????_??????.png'


# ─── Utilitários de terminal ──────────────────────────────────────────────────

def print_header(indir, outfile, fps, fmt, n_frames):
    """Cabeçalho informativo padronizado."""
    print()
    print('═' * 70)
    print('  MONAN-A 2.0 — Animação dos passos de acoplamento (ATM→OCN)')
    print(f'  INPE / CGCT / DIMNT — GT Acoplamento de Modelos  (v{PROG_VERSION})')
    print('═' * 70)
    print(f"  Entrada  : {os.path.abspath(indir)}")
    print(f"  Saída    : {os.path.abspath(outfile)}")
    print(f"  Formato  : {fmt.upper()}  |  FPS: {fps}  |  Quadros: {n_frames}")
    print()


def print_progress(current, total, ts=None):
    """
    Barra de progresso em linha única (sem quebra de linha).

    Parâmetros
    ----------
    current : índice do quadro atual (base 1)
    total   : total de quadros
    ts      : datetime do quadro atual (opcional — exibido à direita)
    """
    frac    = current / max(total, 1)
    bar_len = 40
    filled  = int(bar_len * frac)
    bar     = '█' * filled + '░' * (bar_len - filled)
    ts_info = f'  {ts.strftime("%Y-%m-%d %H:%M")}' if ts else ''
    print(f"\r  [{bar}] {current:3d}/{total}{ts_info}", end='', flush=True)


# ─── Descoberta e filtragem de arquivos ───────────────────────────────────────

def parse_timestamp_from_filename(fname):
    """
    Extrai datetime de um nome de arquivo no formato mom6_import_YYYYMMDD_HHMMSS.png.

    Retorna datetime se o parse tiver sucesso, ou None em caso de falha.
    """
    base   = os.path.basename(fname)
    ts_str = base.replace('mom6_import_', '').replace('.png', '')
    try:
        return datetime.strptime(ts_str, '%Y%m%d_%H%M%S')
    except ValueError:
        return None


def find_png_files(indir):
    """
    Busca arquivos mom6_import_YYYYMMDD_HHMMSS.png no diretório indicado.

    Retorna lista de tuplas (filepath, datetime) ordenada cronologicamente.
    Encerra o script com mensagem de erro se nenhum arquivo for encontrado.
    """
    pattern = os.path.join(indir, PNG_PATTERN)
    raw     = sorted(glob.glob(pattern))

    if not raw:
        sys.exit(
            f"\nERRO: nenhum arquivo correspondente a '{PNG_PATTERN}' "
            f"encontrado em '{indir}'.\n"
            f"  Execute postproc_mom6_import.py --plot primeiro para gerar as figuras.\n"
        )

    frames = []
    for fpath in raw:
        ts = parse_timestamp_from_filename(fpath)
        if ts is None:
            print(f"  AVISO: timestamp não reconhecido em "
                  f"'{os.path.basename(fpath)}' — ignorado.")
            continue
        frames.append((fpath, ts))

    if not frames:
        sys.exit(
            "\nERRO: nenhum arquivo com timestamp válido encontrado.\n"
            f"  Verifique se os PNGs em '{indir}' seguem o padrão "
            f"mom6_import_YYYYMMDD_HHMMSS.png.\n"
        )

    frames.sort(key=lambda x: x[1])   # ordem cronológica crescente
    return frames


def select_frames(all_frames, step_list, every_n):
    """
    Filtra a lista de quadros conforme --step ou --every.

    Parâmetros
    ----------
    all_frames : lista completa de (filepath, datetime)
    step_list  : lista de índices em base 1 (ou None para usar todos)
    every_n    : usar 1 a cada N quadros (1 = sem filtragem)

    Retorna lista filtrada de (filepath, datetime).
    """
    if step_list:
        # --step tem prioridade sobre --every
        indices = sorted(set(i - 1 for i in step_list))          # base 1 → base 0
        indices = [i for i in indices if 0 <= i < len(all_frames)]
        return [all_frames[i] for i in indices]

    if every_n > 1:
        return all_frames[::every_n]

    return all_frames


# ─── Geração de GIF ───────────────────────────────────────────────────────────

def _load_frames_normalized(frames, max_width=0):
    """Carrega os PNGs e devolve imagens PIL TODAS do mesmo tamanho.

    BUG-ANIM-SIZE (correção): quadros de dimensões diferentes (ex.: PNGs
    antigos gerados com bbox_inches='tight') faziam o GIF "tremer" — Pillow
    fixa o tamanho da tela pelo 1º quadro e reposiciona os demais no canto — e
    QUEBRAVAM a codificação MP4 (libx264 exige dimensão constante). Aqui todos
    os quadros são compostos sobre uma tela branca do MAIOR tamanho encontrado.
    Opcionalmente reduz a largura para max_width (mantém proporção)."""
    from PIL import Image
    loaded = []
    for i, (fpath, ts) in enumerate(frames, start=1):
        print_progress(i, len(frames), ts)
        try:
            loaded.append(Image.open(fpath).convert('RGB'))
        except Exception as exc:
            print(f"\n  AVISO: falha ao carregar '{os.path.basename(fpath)}': "
                  f"{exc} — quadro ignorado.")
    print()
    if not loaded:
        sys.exit("\nERRO: nenhuma imagem carregada com sucesso.\n")

    W = max(im.width for im in loaded)
    H = max(im.height for im in loaded)
    norm = []
    for im in loaded:
        if im.size != (W, H):
            canvas = Image.new('RGB', (W, H), 'white')
            canvas.paste(im, (0, 0))
            im = canvas
        norm.append(im)

    if max_width and W > max_width:
        newW = int(max_width)
        newH = int(round(H * newW / W))
        newH -= newH % 2
        norm = [im.resize((newW, newH), Image.LANCZOS) for im in norm]
        print(f"  Redimensionado: {W}x{H} → {newW}x{newH}")
    return norm


def make_gif(frames, outfile, fps, loop, max_width=0, optimize=True):
    """
    Gera um GIF animado a partir dos quadros PNG usando Pillow.

    Parâmetros
    ----------
    frames    : lista de (filepath, datetime)
    outfile   : caminho do arquivo GIF de saída
    fps       : quadros por segundo
    loop      : número de repetições (0 = infinito)
    max_width : largura máxima em px (0 = sem redução)
    optimize  : otimização de paleta do Pillow (reduz o tamanho do arquivo)
    """
    try:
        from PIL import Image  # noqa: F401  (valida a dependência cedo)
    except ImportError:
        sys.exit(
            "\nERRO: Pillow não encontrado.\n"
            "  Instale com:  pip install --user Pillow\n"
            "  Alternativa:  module load pillow  (se disponível no Jaci)\n"
        )

    duration_ms = max(1, int(round(1000.0 / fps)))   # ms por quadro

    print(f"  Carregando {len(frames)} quadros em memória...")
    images = _load_frames_normalized(frames, max_width=max_width)

    print(f"  Gravando GIF ({duration_ms} ms/quadro, loop={loop})...")
    images[0].save(
        outfile,
        format='GIF',
        append_images=images[1:],
        save_all=True,
        duration=duration_ms,
        loop=loop,
        optimize=optimize,
    )

    size_mb = os.path.getsize(outfile) / 1024 ** 2
    print(f"  ✓ GIF gravado  |  {len(images)} quadros  |  "
          f"{fps} FPS  |  {size_mb:.1f} MB")
    if size_mb > 20:
        print("  ⚠ GIF grande (>20 MB). Use --max-width 1400 para reduzir, "
              "ou --format mp4 (bem menor).")
    print()


# ─── Geração de MP4 ───────────────────────────────────────────────────────────

def check_ffmpeg():
    """
    Verifica se o ffmpeg está acessível no PATH.
    Encerra o script com mensagem útil se não estiver disponível.
    """
    try:
        subprocess.run(
            ['ffmpeg', '-version'],
            capture_output=True,
            check=True,
        )
    except FileNotFoundError:
        sys.exit(
            "\nERRO: ffmpeg não encontrado no PATH.\n"
            "  Jaci  : module load ffmpeg\n"
            "  Ubuntu: sudo apt install ffmpeg\n"
            "  Conda : conda install -c conda-forge ffmpeg\n"
            "  Alternativa: use --format gif (requer apenas Pillow).\n"
        )
    except subprocess.CalledProcessError as exc:
        sys.exit(f"\nERRO: ffmpeg retornou código {exc.returncode}.\n")


def make_mp4(frames, outfile, fps, max_width=0):
    """
    Gera um vídeo MP4 (H.264) a partir dos quadros PNG usando ffmpeg.

    BUG-ANIM-MP4 (correção): a versão anterior usava o concat demuxer com os
    PNGs originais. Quando os quadros tinham tamanhos diferentes (o caso com
    bbox_inches='tight'), o libx264 falhava ou gerava vídeo corrompido. Agora
    os quadros são NORMALIZADOS ao mesmo tamanho (via Pillow) e gravados em uma
    sequência temporária numerada, codificada com o demuxer image2 — garantindo
    dimensão constante e ordem determinística.

    Parâmetros
    ----------
    frames    : lista de (filepath, datetime)
    outfile   : caminho do arquivo MP4 de saída
    fps       : quadros por segundo
    max_width : largura máxima em px (0 = sem redução)
    """
    check_ffmpeg()

    images = _load_frames_normalized(frames, max_width=max_width)
    tmpdir = tempfile.mkdtemp(prefix='anim_mp4_')
    try:
        for idx, im in enumerate(images):
            im.save(os.path.join(tmpdir, f'frame_{idx:05d}.png'))

        print(f"  Codificando MP4 com ffmpeg (CRF=20, H.264)...")
        cmd = [
            'ffmpeg', '-y',
            '-framerate', f'{fps}',
            '-i', os.path.join(tmpdir, 'frame_%05d.png'),
            '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
            '-c:v', 'libx264',
            '-crf', '20',
            '-preset', 'medium',
            '-pix_fmt', 'yuv420p',
            '-movflags', '+faststart',
            '-loglevel', 'error',
            outfile,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"\nERRO ffmpeg (código {result.returncode}):")
            for line in result.stderr.strip().splitlines()[-30:]:
                print(f"  {line}")
            sys.exit(1)

        size_mb = os.path.getsize(outfile) / 1024 ** 2
        print(f"  ✓ MP4 gravado  |  {len(images)} quadros  |  "
              f"{fps} FPS  |  {size_mb:.1f} MB\n")
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


# ─── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description=(
            'Gera animação GIF ou MP4 da evolução dos passos de acoplamento '
            'a partir dos PNGs produzidos por postproc_mom6_import.py.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # ── Caminhos ──────────────────────────────────────────────────────────────
    parser.add_argument(
        '--indir', default='diag_import/postproc',
        help=(
            'Diretório contendo os arquivos mom6_import_YYYYMMDD_HHMMSS.png '
            '(padrão: diag_import/postproc)'
        ),
    )
    parser.add_argument(
        '--outfile', default=None,
        help=(
            'Arquivo de saída. Se omitido, usa <indir>/mom6_import_animation.<fmt>. '
            'Exemplo: resultados/minha_animacao.gif'
        ),
    )

    # ── Formato e velocidade ──────────────────────────────────────────────────
    parser.add_argument(
        '--format', choices=['gif', 'mp4'], default='gif',
        dest='fmt',
        help='Formato de saída: gif (padrão, requer Pillow) ou mp4 (requer ffmpeg)',
    )
    parser.add_argument(
        '--fps', type=float, default=1.0,
        help=(
            'Quadros por segundo (padrão: 1.0). '
            'Valores típicos: 0.5 (lento) a 4.0 (rápido)'
        ),
    )
    parser.add_argument(
        '--loop', type=int, default=0,
        metavar='N',
        help=(
            'Número de repetições do GIF (padrão: 0 = infinito). '
            'Use 1 para reprodução única. Ignorado para MP4.'
        ),
    )

    # ── Seleção de quadros ────────────────────────────────────────────────────
    parser.add_argument(
        '--step', nargs='+', type=int, default=None,
        metavar='N',
        help=(
            'Incluir apenas os quadros de índice N (base 1, separados por espaço). '
            'Exemplo: --step 1 5 10 20'
        ),
    )
    parser.add_argument(
        '--every', type=int, default=1,
        metavar='N',
        help=(
            'Usar 1 a cada N quadros disponíveis (padrão: 1 = todos). '
            'Exemplo: --every 3 usa quadros 1, 4, 7, ...'
        ),
    )
    parser.add_argument(
        '--max-width', type=int, default=0, dest='max_width', metavar='PX',
        help=('Largura máxima em pixels (0 = sem redução). Reduz bastante o '
              'tamanho do GIF/MP4. Ex.: --max-width 1400'),
    )
    parser.add_argument(
        '--no-optimize', action='store_false', dest='optimize',
        help='Desativa a otimização de paleta do GIF (arquivos maiores).',
    )

    args = parser.parse_args()

    # ── Validações básicas ────────────────────────────────────────────────────
    if args.fps <= 0:
        sys.exit("\nERRO: --fps deve ser um valor positivo.\n")

    if args.every < 1:
        sys.exit("\nERRO: --every deve ser >= 1.\n")

    # ── Descoberta dos PNGs ───────────────────────────────────────────────────
    all_frames = find_png_files(args.indir)

    # ── Filtragem de quadros ──────────────────────────────────────────────────
    frames = select_frames(all_frames, args.step, args.every)

    if not frames:
        sys.exit(
            "\nERRO: nenhum quadro selecionado após filtragem.\n"
            f"  Total disponível: {len(all_frames)} quadros.\n"
            "  Verifique os parâmetros --step e --every.\n"
        )

    # ── Arquivo de saída ─────────────────────────────────────────────────────
    if args.outfile:
        outfile = args.outfile
    else:
        outfile = os.path.join(args.indir, f'mom6_import_animation.{args.fmt}')

    os.makedirs(os.path.dirname(os.path.abspath(outfile)), exist_ok=True)

    # ── Cabeçalho ─────────────────────────────────────────────────────────────
    print_header(args.indir, outfile, args.fps, args.fmt, len(frames))

    # Resumo dos quadros selecionados
    print(f"  Quadros disponíveis : {len(all_frames)}")
    print(f"  Quadros selecionados: {len(frames)}")
    print(f"  Intervalo temporal  : "
          f"{frames[0][1].strftime('%Y-%m-%d %H:%M')} → "
          f"{frames[-1][1].strftime('%Y-%m-%d %H:%M')}")
    print()

    # ── Geração da animação ───────────────────────────────────────────────────
    if args.fmt == 'gif':
        make_gif(frames, outfile, args.fps, args.loop,
                 max_width=args.max_width, optimize=args.optimize)
    else:
        make_mp4(frames, outfile, args.fps, max_width=args.max_width)

    # ── Rodapé ───────────────────────────────────────────────────────────────
    print('═' * 70)
    print(f'  Animação concluída: {os.path.abspath(outfile)}')
    print('═' * 70)
    print()


if __name__ == '__main__':
    main()
