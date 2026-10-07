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

Quando um trecho muda de arquivo (divisão de um módulo, por exemplo), as
listas de cada arquivo diferem, mas a soma de todos os arquivos conferidos
continua igual. Nesse caso o script avisa que os literais só mudaram de
arquivo e termina com sucesso.

Código de saída: 0 se nenhum literal sumiu ou apareceu, no total dos arquivos
conferidos; 1 caso contrário.
Diferenças esperadas (literal de código morto removido, por exemplo) devem
ser conferidas uma a uma e anunciadas no CHANGELOG.
"""
import collections
import io
import subprocess
import sys


def git(*args):
    """Executa o git e devolve (código de saída, saída em texto UTF-8).

    Usa só recursos do Python 3.6 (o python3 do sistema na Jaci): sem
    capture_output nem text, e com a decodificação feita aqui, porque com o
    locale C o Python 3.6 decodificaria a saída como ASCII."""
    r = subprocess.run(['git'] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout.decode('utf-8', 'replace')


def saida_utf8():
    """Garante saídas em UTF-8 (no Python 3.6 com locale C elas são ASCII)."""
    if (sys.stdout.encoding or '').lower().replace('-', '') != 'utf8':
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8',
                                      errors='replace', line_buffering=True)
    if (sys.stderr.encoding or '').lower().replace('-', '') != 'utf8':
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8',
                                      errors='replace', line_buffering=True)


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
    codigo, texto = git('show', f'{rev}:{caminho}')
    return texto if codigo == 0 else ''


def main():
    saida_utf8()
    if len(sys.argv) < 2 or sys.argv[1] in ('-h', '--help'):
        print(__doc__)
        return 2
    rev = sys.argv[1]
    if git('rev-parse', '--verify', '--quiet', rev + '^{commit}')[0] != 0:
        print(f'ERRO: commit {rev!r} não encontrado', file=sys.stderr)
        return 2
    arquivos = sys.argv[2:] or git('diff', '--name-only', '--no-renames', rev, '--', '*.F90')[1].split()
    iguais = True
    total_antes, total_depois = collections.Counter(), collections.Counter()
    relatorio = []   # (arquivo, antes, sumiram, novos)
    for f in arquivos:
        antes = collections.Counter(literais(no_commit(rev, f)))
        try:
            depois = collections.Counter(literais(open(f, encoding='utf-8', errors='replace').read()))
        except FileNotFoundError:
            depois = collections.Counter()
        total_antes += antes
        total_depois += depois
        sumiram, novos = antes - depois, depois - antes
        if sumiram or novos:
            iguais = False
        relatorio.append((f, antes, sumiram, novos))
    so_mudaram = not iguais and total_antes == total_depois
    for f, antes, sumiram, novos in relatorio:
        if not (sumiram or novos):
            print(f'== {f}: iguais ({sum(antes.values())} literais)')
        elif so_mudaram:
            print(f'== {f}: {sum(sumiram.values())} saíram, '
                  f'{sum(novos.values())} entraram (mudança de arquivo)')
        else:
            print(f'== {f}: DIFEREM')
            for s, k in sorted(sumiram.items()):
                print(f'   - ({k}) {s!r}')
            for s, k in sorted(novos.items()):
                print(f'   + ({k}) {s!r}')
    if so_mudaram:
        print(f'== total dos {len(arquivos)} arquivos: iguais '
              f'({sum(total_antes.values())} literais); só mudaram de arquivo')
        iguais = True
    return 0 if iguais else 1


if __name__ == '__main__':
    sys.exit(main())
