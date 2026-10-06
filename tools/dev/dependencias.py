#!/usr/bin/env python3
"""dependencias.py: dependências entre os fontes Fortran, tiradas dos 'use'.

Um fonte depende de outro quando usa (use) um módulo definido nele. Este
script lê os .F90 de src/, acha em que fonte cada módulo é definido e, a
partir dos 'use' de cada fonte, monta as dependências. Só contam os módulos
do próprio acoplador; os do ESMF, do MPAS, do MOM6, do FMS e do MPI ficam de
fora. Um 'use' dentro de #ifdef conta sempre (a regra fica do lado seguro).

Uso (na raiz do repositório):
  tools/dev/dependencias.py gera [-c]
      escreve src/dependencies.mk, incluído pelo Makefile, com uma regra
      '$(OBJDIR)/<fonte>.o: $(OBJDIR)/<usado>.o ...' por fonte que usa
      outro; com -c não escreve e confere se o arquivo está em dia
  tools/dev/dependencias.py ordem [-s RAIZ] [-i DIR ...]
      fontes compilados fora da Jaci (src/ sem caps/ocean/upstream/ e sem
      main/, mais os de cada DIR), um por linha, numa ordem em que todo
      fonte vem depois dos que ele usa
  tools/dev/dependencias.py objetos [-s RAIZ] [-i DIR ...] PROGRAMA.F90 ...
      objetos (<fonte>.o) de que os programas dependem, direta ou
      indiretamente, na mesma ordem; os próprios programas ficam de fora

    -s RAIZ  raiz da árvore a ler (padrão: a deste script)
    -i DIR   diretório a mais com fontes (ex.: tests/interfaces, as
             interfaces mínimas do MPAS, do MOM6 e do SIS2)

Código de saída: 0 se deu certo (com -c, se o arquivo está em dia); 1 se,
com -c, o arquivo está desatualizado; 2 erro (módulo definido duas vezes,
dependência circular, opção inválida). Escrito para o Python 3.6 da Jaci.
"""
import io
import os
import re
import sys

MODULO = re.compile(r'^\s*module\s+(?!procedure\b|subroutine\b|function\b)(\w+)\s*$', re.I)
USO = re.compile(r'^\s*use\b\s*(,\s*(\w+)\s*)?(::)?\s*(\w+)', re.I)
SAIDA_MK = os.path.join('src', 'dependencies.mk')
SO_NA_JACI = (os.path.join('src', 'caps', 'ocean', 'upstream'), os.path.join('src', 'main'))

CABECALHO = """\
# src/dependencies.mk: dependências entre os fontes do acoplador.
# Gerado por tools/dev/dependencias.py a partir dos 'use' de cada fonte;
# não editar à mão. Depois de mudar um 'use', gerar de novo com
#   tools/dev/dependencias.py gera
# A conferência 'dependencias' do tools/dev/confere-tudo.bash acusa um
# arquivo desatualizado.
"""


class ErroDep(Exception):
    pass


def saida_utf8():
    """Imprime em UTF-8 mesmo com o locale C (Python 3.6 da Jaci)."""
    if sys.stdout.encoding is None or sys.stdout.encoding.lower() != 'utf-8':
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')


def le_fonte(caminho):
    """(módulos definidos, módulos usados) de um fonte, em minúsculas."""
    definidos, usados = [], []
    with io.open(caminho, encoding='utf-8', errors='replace') as f:
        for linha in f:
            codigo = linha.split('!', 1)[0]
            m = MODULO.match(codigo)
            if m:
                definidos.append(m.group(1).lower())
                continue
            m = USO.match(codigo)
            if m and (m.group(2) or '').lower() != 'intrinsic':
                usados.append(m.group(4).lower())
    return definidos, usados


def fontes_em(raiz, diretorio, sem=()):
    """Caminhos (relativos a raiz) dos .F90 de diretorio, em ordem."""
    saida = []
    base = os.path.join(raiz, diretorio)   # diretorio absoluto: join o mantém
    for d, dirs, arqs in os.walk(base):
        rel = os.path.relpath(d, raiz)
        dirs[:] = sorted(x for x in dirs if os.path.join(rel, x) not in sem)
        saida += [os.path.join(rel, a) for a in sorted(arqs) if a.endswith('.F90')]
    return saida


def grafo(raiz, caminhos):
    """{fonte: [fontes que ele usa]} e {fonte: caminho}; fonte = nome sem .F90."""
    onde, info, caminho_de = {}, {}, {}
    for c in caminhos:
        nome = os.path.splitext(os.path.basename(c))[0]
        if nome in caminho_de:
            raise ErroDep('dois fontes com o nome {}: {} e {}'.format(nome, caminho_de[nome], c))
        caminho_de[nome] = c
        definidos, usados = le_fonte(os.path.join(raiz, c))
        info[nome] = usados
        for mod in definidos:
            if mod in onde:
                raise ErroDep('módulo {} definido em {} e em {}'.format(mod, onde[mod], nome))
            onde[mod] = nome
    deps = {}
    for nome, usados in info.items():
        deps[nome] = sorted({onde[u] for u in usados if u in onde and onde[u] != nome},
                            key=str.lower)
    return deps, caminho_de


def em_ordem(deps, nomes, caminho_de):
    """nomes em ordem topológica; empate resolvido pelo caminho do fonte."""
    pendentes = set(nomes)
    feitos, ordem = set(), []
    while pendentes:
        prontos = [n for n in pendentes if all(d in feitos for d in deps[n])]
        if not prontos:
            raise ErroDep('dependência circular entre: ' + ', '.join(sorted(pendentes)))
        n = min(prontos, key=lambda x: caminho_de[x].lower())
        ordem.append(n)
        feitos.add(n)
        pendentes.discard(n)
    return ordem


def fecho(deps, iniciais):
    """Todos os fontes de que os iniciais dependem, direta ou indiretamente."""
    vistos, pilha = set(), list(iniciais)
    while pilha:
        n = pilha.pop()
        for d in deps[n]:
            if d not in vistos:
                vistos.add(d)
                pilha.append(d)
    return vistos


def texto_mk(deps):
    linhas = [CABECALHO]
    for nome in sorted(deps, key=str.lower):
        if deps[nome]:
            linhas.append('$(OBJDIR)/{}.o: {}\n'.format(
                nome, ' '.join('$(OBJDIR)/{}.o'.format(d) for d in deps[nome])))
    return ''.join(linhas)


def main():
    saida_utf8()
    args = sys.argv[1:]
    if not args or args[0] in ('-h', '--help'):
        print(__doc__)
        return 0 if args else 2
    acao, args = args[0], args[1:]
    raiz = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
    confere, extras, programas = False, [], []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '-c' and acao == 'gera':
            confere = True
        elif a in ('-s', '-i') and i + 1 < len(args) and acao in ('ordem', 'objetos'):
            if a == '-s':
                raiz = os.path.abspath(args[i + 1])
            else:
                extras.append(args[i + 1])
            i += 1
        elif acao == 'objetos' and not a.startswith('-'):
            programas.append(os.path.abspath(a))
        else:
            print('ERRO: opção inválida: ' + a, file=sys.stderr)
            return 2
        i += 1
    try:
        if acao == 'gera':
            deps, _ = grafo(raiz, fontes_em(raiz, 'src'))
            texto = texto_mk(deps)
            destino = os.path.join(raiz, SAIDA_MK)
            if confere:
                try:
                    with io.open(destino, encoding='utf-8') as f:
                        atual = f.read()
                except OSError:
                    atual = None
                if atual == texto:
                    print('{}: em dia com os fontes'.format(SAIDA_MK))
                    return 0
                print('{}: DESATUALIZADO; gere de novo com tools/dev/dependencias.py gera'.format(SAIDA_MK))
                return 1
            with io.open(destino, 'w', encoding='utf-8') as f:
                f.write(texto)
            print('{} gerado ({} regras)'.format(SAIDA_MK, sum(1 for d in deps.values() if d)))
            return 0
        if acao not in ('ordem', 'objetos'):
            print('ERRO: ação desconhecida: ' + acao, file=sys.stderr)
            return 2
        caminhos = fontes_em(raiz, 'src', SO_NA_JACI)
        for d in extras:
            caminhos += fontes_em(raiz, d)
        if acao == 'objetos':
            caminhos += [os.path.relpath(p, raiz) for p in programas]
        # o mesmo arquivo pode vir de -i e da lista de programas
        unicos, vistos = [], set()
        for c in caminhos:
            r = os.path.realpath(os.path.join(raiz, c))
            if r not in vistos:
                vistos.add(r)
                unicos.append(c)
        caminhos = unicos
        deps, caminho_de = grafo(raiz, caminhos)
        if acao == 'ordem':
            print('\n'.join(em_ordem(deps, list(deps), caminho_de)))
            return 0
        progs = [os.path.splitext(os.path.basename(p))[0] for p in programas]
        if not progs:
            print('ERRO: objetos exige ao menos um programa', file=sys.stderr)
            return 2
        precisos = fecho(deps, progs) - set(progs)
        print(' '.join(n + '.o' for n in em_ordem(deps, list(deps), caminho_de) if n in precisos))
        return 0
    except ErroDep as e:
        print('ERRO: ' + str(e), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
