#!/usr/bin/env python3
"""
anim_mom6_import.py  —  Animação da evolução dos passos de acoplamento ATM→OCN
                         a partir dos mapas PNG gerados por postproc_mom6_import.py

Versão 1.1 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

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

PROG_VERSION = '1.1'

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

def make_gif(frames, outfile, fps, loop):
    """
    Gera um GIF animado a partir dos quadros PNG usando Pillow.

    Parâmetros
    ----------
    frames  : lista de (filepath, datetime)
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
    for i, (fpath, ts) in enumerate(frames, start=1):
        print_progress(i, len(frames), ts)
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

    # Pillow: o primeiro quadro define paleta e metadados; os demais são annexados.
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


def make_mp4(frames, outfile, fps):
    """
    Gera um vídeo MP4 (H.264) a partir dos quadros PNG usando ffmpeg.

    Estratégia: o concat demuxer do ffmpeg lê uma lista de arquivos e durações,
    evitando cópia/renomeação temporária dos PNGs.  O codec libx264 com
    pix_fmt yuv420p garante compatibilidade máxima com players e
    visualizadores científicos (JupyterLab, VLC, navegadores).

    Parâmetros
    ----------
    frames  : lista de (filepath, datetime)
    outfile : caminho do arquivo MP4 de saída
    fps     : quadros por segundo
    """
    check_ffmpeg()

    duration_s = 1.0 / max(fps, 0.01)   # duração por quadro em segundos

    # O concat demuxer exige um arquivo de lista com pares "file / duration"
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
            '-y',                              # sobrescrever arquivo de saída sem perguntar
            '-f', 'concat',                    # entrada via lista de arquivos
            '-safe', '0',                      # permitir caminhos absolutos na lista
            '-i', list_path,
            # Garantir dimensões pares: H.264 exige largura e altura pares
            '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
            '-c:v', 'libx264',
            '-crf',  '20',                     # qualidade: 0=lossless … 51=péssimo
            '-preset', 'medium',               # velocidade de codificação vs compressão
            '-pix_fmt', 'yuv420p',             # compatibilidade com players não-científicos
            '-movflags', '+faststart',         # mover índice para o início (streaming web)
            '-loglevel', 'error',              # suprimir saída verbosa; mostrar apenas erros
            outfile,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"\nERRO ffmpeg (código {result.returncode}):")
            # Exibir as últimas 30 linhas do stderr para diagnóstico
            for line in result.stderr.strip().splitlines()[-30:]:
                print(f"  {line}")
            sys.exit(1)

        size_mb = os.path.getsize(outfile) / 1024 ** 2
        print(f"  ✓ MP4 gravado  |  {len(frames)} quadros  |  "
              f"{fps} FPS  |  {size_mb:.1f} MB\n")

    finally:
        # Remover arquivo de lista temporário independentemente de erros
        try:
            os.unlink(list_path)
        except OSError:
            pass


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
        make_gif(frames, outfile, args.fps, args.loop)
    else:
        make_mp4(frames, outfile, args.fps)

    # ── Rodapé ───────────────────────────────────────────────────────────────
    print('═' * 70)
    print(f'  Animação concluída: {os.path.abspath(outfile)}')
    print('═' * 70)
    print()


if __name__ == '__main__':
    main()
