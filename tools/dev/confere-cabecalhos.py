#!/usr/bin/env python3
"""confere-cabecalhos.py: cabeçalhos Doxygen das rotinas e nomes de @param.

Confere o modelo de cabeçalho do README (convenção "Comentários"):
  1. toda rotina de módulo (subroutine ou function) tem, logo acima, um
     bloco de comentário que começa por '!> @brief';
  2. toda rotina interna (depois do contains de outra rotina) tem, logo
     acima, um bloco que começa por '!>';
  3. todo nome depois de @param é um argumento da rotina que vem logo
     abaixo do bloco (vários nomes separados por vírgula ou barra valem).
Rotinas dentro de interface (abstrata ou não) ficam de fora.

Uso (na raiz do repositório):
  tools/dev/confere-cabecalhos.py [arquivo ou diretório ...]
    padrão: src/, sem src/caps/ocean/upstream/ (fontes do MOM6)

Código de saída: 0 se nada foi encontrado; 1 caso contrário.
Escrito para o Python 3.6 da Jaci.
"""
import io
import os
import re
import sys

DECL = re.compile(r'^\s*(?:(?:pure|elemental|recursive|impure|module)\s+)*'
                  r'(?:(?:real|integer|logical|character|type|complex)[^!]*?\s+)?'
                  r'(?:subroutine|function)\s+(\w+)', re.I)
FIM = re.compile(r'^\s*end\s+(?:subroutine|function)\b', re.I)
INTERFACE = re.compile(r'^\s*(?:abstract\s+)?interface\b', re.I)
FIM_INTERFACE = re.compile(r'^\s*end\s+interface\b', re.I)
PARAM = re.compile(r'^\s*!!?>?\s*@param(?:\[\w+\])?\s+(\S+)')
SEM_FONTE = os.path.join('src', 'caps', 'ocean', 'upstream')


def saida_utf8():
    """Imprime em UTF-8 mesmo com o locale C (Python 3.6 da Jaci)."""
    if sys.stdout.encoding is None or sys.stdout.encoding.lower() != 'utf-8':
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')


def codigo(linha):
    """Parte de código da linha, sem o comentário ('!' fora de aspas)."""
    aspa = None
    for i, c in enumerate(linha):
        if aspa:
            if c == aspa:
                aspa = None
        elif c in "'\"":
            aspa = c
        elif c == '!':
            return linha[:i]
    return linha


def argumentos(linhas, i):
    """Nomes dos argumentos da declaração que começa na linha i (com continuações)."""
    s, j = codigo(linhas[i]), i
    while s.rstrip().endswith('&') and j + 1 < len(linhas):
        j += 1
        s = s.rstrip()[:-1] + codigo(linhas[j]).lstrip().lstrip('&')
    m = re.search(r'\(([^)]*)\)', s)
    return [a.strip().lower() for a in m.group(1).split(',')] if m else []


def confere(caminho):
    """Problemas de um fonte, como textos 'arquivo:linha: descrição'."""
    with io.open(caminho, encoding='utf-8', errors='replace') as f:
        linhas = f.read().split('\n')
    problemas, nivel, params = [], 0, []
    for i, linha in enumerate(linhas):
        m = PARAM.match(linha)
        if m:
            params.append((i + 1, m.group(1)))
            continue
        if re.match(r'^\s*!', linha):
            continue
        s = codigo(linha)
        if FIM.match(s):
            nivel -= 1
            params = []
            continue
        if INTERFACE.match(s):
            nivel += 100
            continue
        if FIM_INTERFACE.match(s):
            nivel -= 100
            continue
        m = DECL.match(s)
        if m and not re.match(r'^\s*end', s, re.I) and 'procedure' not in s.lower():
            nome = m.group(1)
            if nivel < 100:
                j = i - 1
                while j >= 0 and re.match(r'^\s*!', linhas[j]):
                    j -= 1
                primeira = linhas[j + 1].strip() if j + 1 < i else ''
                if nivel == 0 and not primeira.startswith('!> @brief'):
                    problemas.append('{}:{}: rotina de módulo {} sem cabeçalho "!> @brief"'.format(
                        caminho, i + 1, nome))
                elif nivel > 0 and not primeira.startswith('!>'):
                    problemas.append('{}:{}: rotina interna {} sem linha "!>"'.format(
                        caminho, i + 1, nome))
                args = argumentos(linhas, i)
                for ln, texto in params:
                    for p in re.split(r'[,/]', texto.rstrip(',')):
                        p = p.strip().lower()
                        if p and '..' not in p and p not in args:
                            problemas.append('{}:{}: @param {} não é argumento de {}'.format(
                                caminho, ln, p, nome))
            nivel += 1
            params = []
        elif linha.strip():
            params = []
    return problemas


def fontes(alvos):
    """Fontes .F90 dos arquivos e diretórios dados, em ordem."""
    saida = []
    for alvo in alvos:
        if os.path.isdir(alvo):
            for d, dirs, arqs in os.walk(alvo):
                dirs[:] = sorted(x for x in dirs if os.path.join(d, x) != SEM_FONTE)
                saida += [os.path.join(d, a) for a in sorted(arqs) if a.endswith('.F90')]
        else:
            saida.append(alvo)
    return saida


def main():
    saida_utf8()
    lista = fontes(sys.argv[1:] or ['src'])
    problemas = []
    for caminho in lista:
        problemas += confere(caminho)
    for p in problemas:
        print(p)
    if problemas:
        print('{} problema(s) em {} fonte(s)'.format(len(problemas), len(lista)))
        return 1
    print('{} fontes: cabeçalhos e @param conforme o modelo do README'.format(len(lista)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
