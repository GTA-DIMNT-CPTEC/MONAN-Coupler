#!/usr/bin/env python3
"""confere-curto-circuito.py: procura guardas que contam com curto-circuito.

O Fortran não garante que, em 'a .and. b', o termo b deixe de ser avaliado
quando a é falso. Uma guarda como

    if (associated(p) .and. p(1) > 0) ...
    if (allocated(v) .and. size(v) >= n) ...
    if (present(x) .and. size(x) >= n) ...
    y = merge(p(i), 0.0, associated(p))

pode, portanto, ler um ponteiro nulo, um vetor não alocado ou um argumento
ausente. A forma segura é separar o teste em dois if aninhados.

Este script lê os fontes Fortran e acusa toda instrução em que um nome
testado por associated(), allocated() ou present() é usado na mesma
expressão: indexado (nome(...)) ou passado a size(), lbound(), ubound() ou
shape(). Num if, só a condição é examinada; nas demais instruções
(atribuições, chamadas), a instrução inteira. Textos entre aspas e
comentários são ignorados.

Uso (na raiz do repositório):
  tools/dev/confere-curto-circuito.py [arquivo ou diretório ...]
    padrão: src/, sem src/caps/ocean/upstream/ (fontes do MOM6)

Código de saída: 0 se nada foi encontrado; 1 caso contrário.
Escrito para o Python 3.6 da Jaci.
"""
import io
import os
import re
import sys

GUARDA = re.compile(r'\b(associated|allocated|present)\s*\(\s*([A-Za-z_][\w%]*)\s*[,)]', re.I)
INICIO_IF = re.compile(r'^\s*(?:\w+\s*:\s*)?(?:else\s*)?if\s*\(|^\s*do\s+while\s*\(', re.I)


def saida_utf8():
    """Imprime em UTF-8 mesmo com o locale C (Python 3.6 da Jaci)."""
    if sys.stdout.encoding is None or sys.stdout.encoding.lower() != 'utf-8':
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')


def sem_textos(linha):
    """Linha sem o comentário e com os textos entre aspas trocados por ''."""
    saida, aspa = [], None
    for c in linha:
        if aspa:
            if c == aspa:
                aspa = None
                saida.append(c)
            continue
        if c in "'\"":
            aspa = c
            saida.append(c)
        elif c == '!':
            break
        else:
            saida.append(c)
    return ''.join(saida)


def instrucoes(texto):
    """(número da primeira linha, instrução) com as continuações juntadas."""
    buf, inicio = '', 0
    for n, linha in enumerate(texto.split('\n'), 1):
        s = sem_textos(linha).strip()
        if not s:
            continue
        if not buf:
            inicio = n
        if s.startswith('&'):
            s = s[1:]
        if s.endswith('&'):
            buf += s[:-1] + ' '
            continue
        buf += s
        for parte in buf.split(';'):
            if parte.strip():
                yield inicio, parte.strip()
        buf = ''


def condicao(instr):
    """A condição de um if/else if/do while, ou None."""
    m = INICIO_IF.match(instr)
    if not m:
        return None
    nivel, i = 1, m.end()
    while i < len(instr) and nivel:
        if instr[i] == '(':
            nivel += 1
        elif instr[i] == ')':
            nivel -= 1
        i += 1
    return instr[m.end():i - 1]


def achados(instr):
    """Nomes guardados e usados na mesma expressão da instrução."""
    expr = condicao(instr)
    if expr is None:
        expr = instr
    nomes = []
    for g in GUARDA.finditer(expr):
        nome = re.escape(g.group(2))
        resto = expr[:g.start()] + ' ' + expr[g.end():]
        uso = re.compile(r'(?<![\w%])' + nome + r'\s*\(|\b(?:size|lbound|ubound|shape)\s*\(\s*'
                         + nome + r'\s*[,)]', re.I)
        if uso.search(resto) and g.group(2) not in nomes:
            nomes.append(g.group(2))
    return nomes


def fontes(alvos):
    for alvo in alvos:
        if os.path.isfile(alvo):
            yield alvo
            continue
        for raiz, dirs, arqs in os.walk(alvo):
            dirs[:] = sorted(d for d in dirs if os.path.join(raiz, d) !=
                             os.path.join('src', 'caps', 'ocean', 'upstream'))
            for a in sorted(arqs):
                if a.lower().endswith(('.f90', '.f')):
                    yield os.path.join(raiz, a)


def main():
    saida_utf8()
    args = sys.argv[1:]
    if any(a in ('-h', '--help') for a in args):
        print(__doc__)
        return 0
    total = 0
    for arq in fontes(args or ['src']):
        with io.open(arq, encoding='utf-8', errors='replace') as f:
            texto = f.read()
        for n, instr in instrucoes(texto):
            nomes = achados(instr)
            if nomes:
                total += 1
                print('{}:{}: {} usado na mesma expressão que o testa: {}'.format(
                    arq, n, ', '.join(nomes), instr[:120]))
    if total:
        print('{} instrução(ões) contam com curto-circuito do .and.; separar em if aninhados'.format(total))
        return 1
    print('nenhuma guarda conta com curto-circuito')
    return 0


if __name__ == '__main__':
    sys.exit(main())
