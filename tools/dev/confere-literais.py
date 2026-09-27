#!/usr/bin/env python3
"""confere-literais.py: compara as constantes de texto dos fontes Fortran.

Mensagens de log, nomes de campos, atributos NetCDF e formatos são lidos por
ferramentas e comparados entre rodadas; numa refatoração, não devem mudar.
Este script extrai os literais de texto (fora dos comentários) de cada fonte
num commit e na árvore de trabalho e compara as duas listas, com repetição.

Uso (na raiz do repositório):
  tools/dev/confere-literais.py REV [arquivo ...]
    REV       commit de referência (ex.: HEAD, fase4-03-validada)
    arquivo   fontes a conferir (padrão: os .F90 alterados desde REV)

Código de saída: 0 se nenhum literal sumiu ou apareceu; 1 caso contrário.
Diferenças esperadas (literal de código morto removido, por exemplo) devem
ser conferidas uma a uma e anunciadas no CHANGELOG.
"""
import collections
import subprocess
import sys


def literais(texto):
    """Literais entre aspas simples ou duplas, fora de comentários."""
    saida = []
    for linha in texto.split('\n'):
        i, n = 0, len(linha)
        while i < n:
            c = linha[i]
            if c == '!':
                break
            if c in "'\"":
                aspa, j, s = c, i + 1, ''
                while j < n:
                    if linha[j] == aspa:
                        if j + 1 < n and linha[j + 1] == aspa:   # aspa dobrada
                            s += aspa
                            j += 2
                            continue
                        break
                    s += linha[j]
                    j += 1
                saida.append(s)
                i = j + 1
                continue
            i += 1
    return saida


def no_commit(rev, caminho):
    r = subprocess.run(['git', 'show', f'{rev}:{caminho}'], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ''


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ('-h', '--help'):
        print(__doc__)
        return 2
    rev = sys.argv[1]
    if subprocess.run(['git', 'rev-parse', '--verify', '--quiet', rev + '^{commit}'],
                      capture_output=True).returncode != 0:
        print(f'ERRO: commit {rev!r} não encontrado', file=sys.stderr)
        return 2
    arquivos = sys.argv[2:] or subprocess.run(
        ['git', 'diff', '--name-only', rev, '--', '*.F90'],
        capture_output=True, text=True).stdout.split()
    iguais = True
    for f in arquivos:
        antes = collections.Counter(literais(no_commit(rev, f)))
        try:
            depois = collections.Counter(literais(open(f, encoding='utf-8', errors='replace').read()))
        except FileNotFoundError:
            depois = collections.Counter()
        sumiram, novos = antes - depois, depois - antes
        if sumiram or novos:
            iguais = False
            print(f'== {f}: DIFEREM')
            for s, k in sorted(sumiram.items()):
                print(f'   - ({k}) {s!r}')
            for s, k in sorted(novos.items()):
                print(f'   + ({k}) {s!r}')
        else:
            print(f'== {f}: iguais ({sum(antes.values())} literais)')
    return 0 if iguais else 1


if __name__ == '__main__':
    sys.exit(main())
