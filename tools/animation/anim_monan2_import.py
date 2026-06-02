#!/usr/bin/env python3
"""
anim_monan2_import.py  —  Animação da evolução dos campos importados pelo MONAN-A 2.0
                           (OCN→ATM via conector MED→MPAS: So_t, Si_ifrac, Sf_zorl)
                           a partir dos mapas PNG gerados por postproc_monan2_import.py

Versão 1.0 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

═══════════════════════════════════════════════════════════════════════════════
Contexto
═══════════════════════════════════════════════════════════════════════════════
O script postproc_monan2_import.py gera, para cada passo de acoplamento,
um mapa multi-painel com os campos OCN→ATM importados pelo MONAN-A 2.0
(So_t, Si_ifrac, Sf_zorl) lidos de:

  FONTE 1 — monan2_import_YYYYMMDD_HHMMSS.nc  (escrita direta, v4.19+)
  FONTE 2 — mom6_import_YYYYMMDD_HHMMSS.nc    (inferência dos fluxos MED→OCN)

Os mapas são gravados em dois sub-formatos, dependendo da disponibilidade
do carimbo de tempo:

  Nominal  : <outdir>/monan2_import_YYYYMMDD_HHMMSS.png
  Fallback : <outdir>/monan2_import_NNNN.png  (contador de passo)

Este script lê esses PNGs em ordem cronológica (ou numérica no fallback)
e gera uma animação GIF ou MP4 que permite visualizar a evolução temporal
dos campos So_t, Si_ifrac e Sf_zorl ao longo do experimento.

═══════════════════════════════════════════════════════════════════════════════
Modos de saída
═══════════════════════════════════════════════════════════════════════════════
  GIF  — padrão; requer apenas Pillow (pip install Pillow)
  MP4  — requer ffmpeg acessível no PATH

═══════════════════════════════════════════════════════════════════════════════
Exemplos de uso
═══════════════════════════════════════════════════════════════════════════════
  # GIF com todos os quadros disponíveis, 1 FPS (padrão):
  python3 anim_monan2_import.py

  # GIF mais rápido, 1 quadro a cada 2 disponíveis:
  python3 anim_monan2_import.py --fps 2 --every 2

  # MP4 a 3 FPS em diretório personalizado:
  python3 anim_monan2_import.py --format mp4 --fps 3 --indir diag_import/figs

  # Animar apenas os passos 1, 5 e 10:
  python3 anim_monan2_import.py --step 1 5 10

  # Arquivo de saída explícito:
  python3 anim_monan2_import.py --outfile resultados/animacao_monan2.gif

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


# ─── Metadados do script ──────────────────────────────────────────────────────

PROG_VERSION = '1.0'

# Padrões de nome dos PNGs gerados por postproc_monan2_import.py:
#   Nominal  : monan2_import_YYYYMMDD_HHMMSS.png  (timestamp de simulação)
#   Fallback : monan2_import_NNNN.png              (contador de passo)
PNG_PATTERN_TS  = 'monan2_import_????????_??????.png'
PNG_PATTERN_CNT = 'monan2_import_????.png'


# ─── Utilitários de terminal ──────────────────────────────────────────────────

def print_header(indir, outfile, fps, fmt, n_frames):
    """Cabeçalho informativo padronizado."""
    print()
    print('═' * 70)
    print('  MONAN-A 2.0 — Animação dos campos importados (OCN→ATM)')
    print(f'  INPE / CGCT / DIMNT — GT Acoplamento de Modelos  (v{PROG_VERSION})')
    print('═' * 70)
    print(f"  Entrada  : {os.path.abspath(indir)}")
    print(f"  Saída    : {os.path.abspath(outfile)}")
    print(f"  Formato  : {fmt.upper()}  |  FPS: {fps}  |  Quadros: {n_frames}")
    print()


def print_progress(current, total, label=None):
    """Barra de progresso em linha única (sem quebra de linha).

    Parâmetros
    ----------
    current : índice do quadro atual (base 1)
    total   : total de quadros
    label   : string opcional exibida à direita (timestamp ou número do passo)
    """
    frac    = current / max(total, 1)
    bar_len = 40
    filled  = int(bar_len * frac)
    bar     = '█' * filled + '░' * (bar_len - filled)
    suffix  = f'  {label}' if label else ''
    print(f"\r  [{bar}] {current:3d}/{total}{suffix}", end='', flush=True)


# ─── Descoberta e filtragem de arquivos ───────────────────────────────────────

def _parse_ts(fname):
    """Tenta extrair datetime de monan2_import_YYYYMMDD_HHMMSS.png.
    Retorna datetime ou None."""
    base   = os.path.basename(fname)
    ts_str = base.replace('monan2_import_', '').replace('.png', '')
    try:
        return datetime.strptime(ts_str, '%Y%m%d_%H%M%S')
    except ValueError:
        return None


def _parse_cnt(fname):
    """Tenta extrair inteiro de monan2_import_NNNN.png.
    Retorna int ou None."""
    base = os.path.basename(fname)
    raw  = base.replace('monan2_import_', '').replace('.png', '')
    try:
        return int(raw)
    except ValueError:
        return None


def find_png_files(indir):
    """Busca PNGs gerados por postproc_monan2_import.py no diretório indicado.

    Tenta o sub-formato nominal (timestamp) primeiro; em seguida o fallback
    por contador de passo. Retorna lista de tuplas (filepath, label) ordenada
    cronologicamente ou numericamente, onde label é uma string legível
    (data/hora ou "passo NNNN").

    Encerra o script com mensagem de erro se nenhum arquivo for encontrado.
    """
    # ── Sub-formato nominal (timestamp) ──────────────────────────────────────
    raw_ts = sorted(glob.glob(os.path.join(indir, PNG_PATTERN_TS)))
    if raw_ts:
        frames = []
        for fpath in raw_ts:
            ts = _parse_ts(fpath)
            if ts is None:
                print(f"  AVISO: timestamp não reconhecido em "
                      f"'{os.path.basename(fpath)}' — ignorado.")
                continue
            frames.append((fpath, ts.strftime('%Y-%m-%d %H:%M')))
        if frames:
            return frames

    # ── Sub-formato fallback (contador de passo) ─────────────────────────────
    raw_cnt = sorted(glob.glob(os.path.join(indir, PNG_PATTERN_CNT)))
    if raw_cnt:
        frames = []
        for fpath in raw_cnt:
            n = _parse_cnt(fpath)
            if n is None:
                print(f"  AVISO: número de passo não reconhecido em "
                      f"'{os.path.basename(fpath)}' — ignorado.")
                continue
            frames.append((fpath, f'passo {n:04d}'))
        if frames:
            return frames

    # ── Nenhum arquivo encontrado ─────────────────────────────────────────────
    sys.exit(
        f"\nERRO: nenhum arquivo PNG encontrado em '{indir}'.\n"
        f"  Padrões buscados:\n"
        f"    {PNG_PATTERN_TS}   (nominal — timestamp)\n"
        f"    {PNG_PATTERN_CNT}  (fallback — contador de passo)\n"
        f"  Execute postproc_monan2_import.py --plot primeiro para gerar as figuras.\n"
    )


def select_frames(all_frames, step_list, every_n):
    """Filtra a lista de quadros conforme --step ou --every.

    Parâmetros
    ----------
    all_frames : lista completa de (filepath, label)
    step_list  : índices em base 1 (ou None para usar todos)
    every_n    : usar 1 a cada N quadros (1 = sem filtragem)

    Retorna lista filtrada de (filepath, label).
    """
    if step_list:
        # --step tem prioridade sobre --every
        indices = sorted(set(i - 1 for i in step_list))
        indices = [i for i in indices if 0 <= i < len(all_frames)]
        return [all_frames[i] for i in indices]

    if every_n > 1:
        return all_frames[::every_n]

    return all_frames


# ─── Geração de GIF ───────────────────────────────────────────────────────────

def make_gif(frames, outfile, fps, loop):
    """Gera GIF animado a partir dos quadros PNG usando Pillow.

    Parâmetros
    ----------
    frames  : lista de (filepath, label)
    outfile : caminho do arquivo GIF de saída
    fps     : quadros por segundo
    loop    : número de repetições (0 = infinito)
    """
    try:
        from PIL import Image
    except ImportError:
        sys.exit(
            "\nERRO: Pillow não encontrado.\n"
            "  Instale com:  pip install --user Pillow\n"
            "  Alternativa:  module load pillow  (se disponível no Jaci)\n"
        )

    duration_ms = max(1, int(round(1000.0 / fps)))   # ms por quadro

    print(f"  Carregando {len(frames)} quadros em memória...")
    images = []
    for i, (fpath, label) in enumerate(frames, start=1):
        print_progress(i, len(frames), label)
        try:
            img = Image.open(fpath).convert('RGB')
            images.append(img)
        except Exception as exc:
            print(f"\n  AVISO: falha ao carregar '{os.path.basename(fpath)}': "
                  f"{exc} — quadro ignorado.")

    print()   # finaliza a linha da barra de progresso

    if not images:
        sys.exit("\nERRO: nenhuma imagem carregada com sucesso.\n")

    print(f"  Gravando GIF ({duration_ms} ms/quadro, loop={loop})...")

    # Pillow: o primeiro quadro define paleta e metadados; os demais são anexados.
    # optimize=False: evita redução de paleta que pode degradar campos coloridos.
    images[0].save(
        outfile,
        format='GIF',
        append_images=images[1:],
        save_all=True,
        duration=duration_ms,
        loop=loop,
        optimize=False,
    )

    size_mb = os.path.getsize(outfile) / 1024 ** 2
    print(f"  ✓ GIF gravado  |  {len(images)} quadros  |  "
          f"{fps} FPS  |  {size_mb:.1f} MB\n")


# ─── Geração de MP4 ───────────────────────────────────────────────────────────

def check_ffmpeg():
    """Verifica se o ffmpeg está acessível no PATH.
    Encerra o script com mensagem útil se não estiver disponível.
    """
    try:
        subprocess.run(['ffmpeg', '-version'], capture_output=True, check=True)
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


def make_mp4(frames, outfile, fps):
    """Gera vídeo MP4 (H.264) a partir dos quadros PNG usando ffmpeg.

    Usa o concat demuxer do ffmpeg para evitar cópia/renomeação temporária
    dos PNGs. Codec libx264 com pix_fmt yuv420p garante compatibilidade
    máxima com players e visualizadores científicos.

    Parâmetros
    ----------
    frames  : lista de (filepath, label)
    outfile : caminho do arquivo MP4 de saída
    fps     : quadros por segundo
    """
    check_ffmpeg()

    duration_s = 1.0 / max(fps, 0.01)   # duração por quadro em segundos

    # O concat demuxer exige um arquivo de lista com pares "file / duration".
    # O último arquivo deve ser repetido sem "duration" (requisito do ffmpeg).
    with tempfile.NamedTemporaryFile(
            mode='w', suffix='_concat.txt',
            delete=False, encoding='utf-8') as tmp:
        list_path = tmp.name
        for fpath, _ in frames:
            abs_path = os.path.abspath(fpath).replace("'", r"'\''")
            tmp.write(f"file '{abs_path}'\n")
            tmp.write(f"duration {duration_s:.6f}\n")
        # Último quadro repetido sem duration (obrigatório pelo demuxer)
        if frames:
            abs_last = os.path.abspath(frames[-1][0]).replace("'", r"'\''")
            tmp.write(f"file '{abs_last}'\n")

    try:
        print(f"  Codificando MP4 com ffmpeg (CRF=20, H.264)...")
        cmd = [
            'ffmpeg',
            '-y',                              # sobrescrever sem perguntar
            '-f', 'concat',                    # entrada via lista de arquivos
            '-safe', '0',                      # permitir caminhos absolutos
            '-i', list_path,
            # H.264 exige largura e altura pares
            '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
            '-c:v', 'libx264',
            '-crf',  '20',                     # qualidade: 0=lossless … 51=péssimo
            '-preset', 'medium',               # velocidade vs compressão
            '-pix_fmt', 'yuv420p',             # compatibilidade com players
            '-movflags', '+faststart',         # índice no início (streaming web)
            '-loglevel', 'error',              # suprimir saída verbosa
            outfile,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"\nERRO ffmpeg (código {result.returncode}):")
            for line in result.stderr.strip().splitlines()[-30:]:
                print(f"  {line}")
            sys.exit(1)

        size_mb = os.path.getsize(outfile) / 1024 ** 2
        print(f"  ✓ MP4 gravado  |  {len(frames)} quadros  |  "
              f"{fps} FPS  |  {size_mb:.1f} MB\n")

    finally:
        try:
            os.unlink(list_path)
        except OSError:
            pass


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description=(
            'Gera animação GIF ou MP4 dos campos importados pelo MONAN-A 2.0 '
            '(OCN→ATM) a partir dos PNGs produzidos por postproc_monan2_import.py.'
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # ── Caminhos ──────────────────────────────────────────────────────────────
    parser.add_argument(
        '--indir', default='diag_import/postproc',
        help=(
            'Diretório contendo os arquivos monan2_import_*.png '
            '(padrão: diag_import/postproc)'
        ),
    )
    parser.add_argument(
        '--outfile', default=None,
        help=(
            'Arquivo de saída. Se omitido, usa <indir>/monan2_import_animation.<fmt>. '
            'Exemplo: resultados/animacao_monan2.gif'
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

    # ── Arquivo de saída ──────────────────────────────────────────────────────
    outfile = args.outfile or os.path.join(
        args.indir, f'monan2_import_animation.{args.fmt}'
    )
    os.makedirs(os.path.dirname(os.path.abspath(outfile)), exist_ok=True)

    # ── Cabeçalho ─────────────────────────────────────────────────────────────
    print_header(args.indir, outfile, args.fps, args.fmt, len(frames))
    print(f"  Quadros disponíveis : {len(all_frames)}")
    print(f"  Quadros selecionados: {len(frames)}")
    print(f"  Intervalo           : {frames[0][1]} → {frames[-1][1]}")
    print()

    # ── Geração da animação ───────────────────────────────────────────────────
    if args.fmt == 'gif':
        make_gif(frames, outfile, args.fps, args.loop)
    else:
        make_mp4(frames, outfile, args.fps)

    # ── Rodapé ────────────────────────────────────────────────────────────────
    print('═' * 70)
    print(f'  Animação concluída: {os.path.abspath(outfile)}')
    print('═' * 70)
    print()


if __name__ == '__main__':
    main()
