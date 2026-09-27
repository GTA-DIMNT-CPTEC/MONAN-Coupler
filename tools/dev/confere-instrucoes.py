#!/usr/bin/env python3
"""confere-instrucoes.py: compara as instruções de um fonte Fortran entre versões.

Numa etapa que só move código (dividir uma rotina em etapas, por exemplo),
as instruções continuam as mesmas; mudam só as chamadas e declarações das
etapas novas. Este script junta as linhas de continuação, retira comentários,
espaços e diferença de maiúsculas, e compara o conjunto de instruções (com
repetição) de um fonte num commit com o da árvore de trabalho.

Uso (na raiz do repositório):
  tools/dev/confere-instrucoes.py REV arquivo
    REV       commit de referência (ex.: HEAD)
    arquivo   fonte a conferir

Saída: as instruções removidas e as acrescentadas. Toda instrução removida
tem de ser explicada (código morto anunciado, trecho que virou chamada); as
acrescentadas devem ser só chamadas, declarações, cabeçalhos e retornos das
etapas novas. A comparação ignora a ordem: a ordem das operações, em
especial das coletivas do MPI, é conferida na leitura do diff.
"""
import collections
import re
import subprocess
import sys


def sem_comentario(linha):
    s, aspa = '', None
    for c in linha:
        if aspa:
            s += c
            if c == aspa:
                aspa = None
        elif c in "'\"":
            aspa = c
            s += c
        elif c == '!':
            break
        else:
            s += c
    return s.strip()


def instrucoes(texto):
    saida, buf = [], ''
    for linha in texto.split('\n'):
        s = sem_comentario(linha)
        if s.startswith('#'):          # diretiva do pré-processador
            saida.append(s)
            continue
        if not s:
            continue
        if s.startswith('&'):
            s = s[1:].strip()
        if s.endswith('&'):
            buf += s[:-1].strip() + ' '
            continue
        buf += s
        for parte in re.split(r';(?=(?:[^\'"]|\'[^\']*\'|"[^"]*")*$)', buf):
            parte = re.sub(r'\s+', '', parte).lower()
            if parte:
                saida.append(parte)
        buf = ''
    return collections.Counter(saida)


def main():
    if len(sys.argv) != 3 or sys.argv[1] in ('-h', '--help'):
        print(__doc__)
        return 2
    rev, f = sys.argv[1], sys.argv[2]
    if subprocess.run(['git', 'rev-parse', '--verify', '--quiet', rev + '^{commit}'],
                      capture_output=True).returncode != 0:
        print(f'ERRO: commit {rev!r} não encontrado', file=sys.stderr)
        return 2
    antes = instrucoes(subprocess.run(['git', 'show', f'{rev}:{f}'],
                                      capture_output=True, text=True).stdout)
    depois = instrucoes(open(f, encoding='utf-8', errors='replace').read())
    print('== removidas')
    for s, k in sorted((antes - depois).items()):
        print(f'   ({k}) {s}')
    print('== acrescentadas')
    for s, k in sorted((depois - antes).items()):
        print(f'   ({k}) {s}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
