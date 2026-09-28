#!/usr/bin/env python3
"""indicadores.py: mede os indicadores de código limpo dos fontes Fortran.

Mede, nos fontes próprios de src/ (sem src/caps/ocean/upstream/), os
indicadores do roteiro de código limpo (docs/roteiro-codigo-limpo.md):
tamanho dos arquivos e das rotinas, estado guardado em variáveis de módulo,
variáveis locais que conservam valor entre chamadas, trechos repetidos e
marcas de histórico nos comentários. Serve para acompanhar a evolução do
código de uma etapa para a outra; não decide se uma etapa está certa.

Uso (na raiz do repositório):
  tools/dev/indicadores.py [-l] [VERSAO ...]
    VERSAO   commit (ex.: HEAD, fase5-07-validada) ou "." para a árvore de
             trabalho; várias versões viram colunas da tabela (padrão: ".")
    -l       lista também os itens de cada indicador (arquivos, rotinas,
             variáveis, trechos repetidos), para a última versão pedida

Saída: uma tabela em Markdown, pronta para o CHANGELOG. Código de saída 0,
ou 2 se uma versão não existir.

Como se mede:
  linhas de código   linhas que não são brancas nem só comentário;
  rotina             subroutine ou function com corpo (fora de interface);
  estado de módulo   variável declarada na parte de especificação de um
                     módulo, fora de tipos derivados, que não é parameter;
                     "pública" se visível fora do módulo, "protegida" se
                     public com protected (configuração só de leitura);
  save local         variável de rotina com save, explícito ou implícito
                     (valor na declaração, inclusive ponteiro => null());
  trecho repetido    janela de 6 linhas de código normalizadas (sem
                     comentários, espaços e maiúsculas; ignoradas as
                     declarações, use, end e chamadas a ChkErr) com mais de
                     200 caracteres, que aparece em mais de um lugar;
  marca de histórico comentário com FIX, TODO-, Sprint, [N1], versões como
                     v2.5 ou datas.
"""
import collections
import re
import subprocess
import sys

LIMITE_ARQUIVO = 1000
JANELA = 6

RE_ROTINA = re.compile(
    r'\s*(?:(?:pure|elemental|recursive|impure|module)\s+)*'
    r'(?:(?:integer|real|logical|character|complex|type|class)\b[^!]*?\s+)?'
    r'(subroutine|function)\s+(\w+)', re.I)
RE_FIM_ROTINA = re.compile(r'\s*end\s*(subroutine|function)\b', re.I)
RE_DECL = re.compile(
    r'\s*(integer|real|logical|character|complex|type\s*\(|class\s*\(|procedure\s*\()'
    r'(.*?)::(.*)$', re.I)
RE_MARCA = re.compile(
    r'\bFIX\b(?!-DIAG)|TODO-|Sprint|\[[NEBS]\d+\]|\bv\d+\.\d+\b|\d{2}/\d{2}/\d{4}|'
    r'\b(Jan|Fev|Mar|Abr|Mai|Jun|Jul|Ago|Set|Out|Nov|Dez)[a-z]*/?\s?20\d\d')


def separa(linha):
    """Devolve (código sem comentário, comentário), respeitando as aspas."""
    aspa = None
    for i, c in enumerate(linha):
        if aspa:
            if c == aspa:
                aspa = None
        elif c in "'\"":
            aspa = c
        elif c == '!':
            return linha[:i], linha[i:]
    return linha, ''


def fontes(versao):
    """Lista de (caminho, texto) dos fontes próprios da versão pedida."""
    if versao == '.':
        nomes = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard',
                                'src'], capture_output=True, text=True).stdout.split()
        ler = lambda f: open(f, encoding='utf-8', errors='replace').read()
    else:
        nomes = subprocess.run(['git', 'ls-tree', '-r', '--name-only', versao, 'src'],
                               capture_output=True, text=True).stdout.split()
        ler = lambda f: subprocess.run(['git', 'show', f'{versao}:{f}'],
                                       capture_output=True, text=True).stdout
    saida = []
    for f in sorted(set(nomes)):
        if f.endswith('.F90') and '/upstream/' not in f:
            try:
                saida.append((f, ler(f)))
            except FileNotFoundError:
                pass
    return saida


def nomes_declarados(entidades):
    """Nomes de uma lista de entidades de declaração (a :: b(3) = 1, c)."""
    s, prof, atual, partes = entidades, 0, '', []
    for c in s:
        if c in '([':
            prof += 1
        elif c in ')]':
            prof -= 1
        if c == ',' and prof == 0:
            partes.append(atual)
            atual = ''
        else:
            atual += c
    partes.append(atual)
    saida = []
    for p in partes:
        m = re.match(r'\s*(\w+)', p)
        if m:
            saida.append((m.group(1).lower(), '=' in p.replace('==', '')))
    return saida


def analisa_arquivo(caminho, texto, res):
    linhas = texto.split('\n')
    if linhas and linhas[-1] == '':
        linhas = linhas[:-1]
    cod = [separa(l) for l in linhas]
    n_cod = sum(1 for c, _ in cod if c.strip())
    res['arquivos'].append((caminho, len(linhas), n_cod))
    res['marcas'] += sum(1 for _, m in cod if m and RE_MARCA.search(m))

    # juntar continuações
    instr, buf, ini = [], '', None
    for i, (c, _) in enumerate(cod, 1):
        s = c.strip()
        if not s and not buf:
            continue
        if s.startswith('&'):
            s = s[1:]
        if ini is None:
            ini = i
        if s.endswith('&'):
            buf += s[:-1] + ' '
            continue
        buf += s
        if buf.strip():
            for parte in buf.split(';'):
                if parte.strip():
                    instr.append((ini, parte.strip()))
        buf, ini = '', None

    pilha, em_interface, em_tipo = [], 0, 0
    modulo, privado, publicos, protegidos, estado = None, False, set(), set(), []
    for n, s in instr:
        low = s.lower()
        if re.match(r'(abstract\s+)?interface\b', low):
            em_interface += 1
            continue
        if re.match(r'end\s*interface\b', low):
            em_interface -= 1
            continue
        if em_interface:
            continue
        m = re.match(r'module\s+(\w+)\s*$', low)
        if m and not pilha:
            modulo, privado, publicos, protegidos, estado = m.group(1), False, set(), set(), []
            continue
        if re.match(r'end\s*module\b', low) and modulo:
            for nome, linha in estado:
                if nome in protegidos:
                    tipo = 'protegida'
                elif nome in publicos or not privado:
                    tipo = 'pública'
                else:
                    tipo = 'privada'
                res['estado_modulo'].append((caminho, linha, nome, tipo))
            modulo = None
            continue
        if re.match(r'contains\b', low):
            continue
        mr = RE_ROTINA.match(s)
        if mr and not re.match(r'\s*end\b', low) and not low.startswith('module procedure'):
            pilha.append((mr.group(2), n))
            continue
        if RE_FIM_ROTINA.match(s) and pilha:
            nome, ini_r = pilha.pop()
            corpo = cod[ini_r - 1:n]
            n_linhas = n - ini_r + 1
            n_codigo = sum(1 for c, _ in corpo if c.strip())
            res['rotinas'].append((caminho, nome, n_linhas, n_codigo))
            continue
        if re.match(r'type\b(?!\s*\()', low) and '::' in low or re.match(r'type\s+\w+\s*$', low):
            if not low.startswith('type is'):
                em_tipo += 1
            continue
        if re.match(r'end\s*type\b', low):
            em_tipo = max(0, em_tipo - 1)
            continue
        if em_tipo:
            continue
        if modulo and not pilha:
            if re.match(r'private\s*$', low):
                privado = True
            mpub = re.match(r'(public|protected)\s*(::)?\s*(.+)$', low)
            if mpub:
                alvo = publicos if mpub.group(1) == 'public' else protegidos
                alvo.update(x.strip() for x in mpub.group(3).split(',') if re.match(r'\w+$', x.strip()))
        d = RE_DECL.match(s)
        if d:
            atrib = (d.group(1) + d.group(2)).lower()
            if 'parameter' in atrib:
                continue
            nomes = nomes_declarados(d.group(3))
            if pilha:
                explicito = re.search(r'\bsave\b', atrib) is not None
                for nome, com_valor in nomes:
                    if explicito or com_valor:
                        res['save_local'].append((caminho, n, pilha[-1][0], nome,
                                                  'explícito' if explicito else 'implícito'))
            elif modulo:
                for nome, _ in nomes:
                    estado.append((nome, n))
                    if re.search(r'\bpublic\b', atrib):
                        (protegidos if 'protected' in atrib else publicos).add(nome)
                    elif re.search(r'\bprivate\b', atrib):
                        pass

    # janelas para trechos repetidos
    norm = []
    for i, (c, _) in enumerate(cod, 1):
        t = re.sub(r'\s+', ' ', c).strip().lower()
        if t and not t.startswith(('end ', 'use ', 'implicit', 'integer', 'real', 'logical',
                                   'character', 'type(', 'type (', 'call chkerr')):
            norm.append((i, t))
    for k in range(len(norm) - JANELA):
        chave = '\n'.join(t for _, t in norm[k:k + JANELA])
        if len(chave) > 200:
            res['janelas'][chave].append((caminho, norm[k][0]))


def mede(versao):
    res = {'arquivos': [], 'rotinas': [], 'estado_modulo': [], 'save_local': [],
           'janelas': collections.defaultdict(list), 'marcas': 0}
    for caminho, texto in fontes(versao):
        analisa_arquivo(caminho, texto, res)
    rep = {k: v for k, v in res['janelas'].items() if len(v) > 1}
    res['repetidos'] = rep
    return res


def tabela(versoes, medidas):
    def arq(r):
        return r['arquivos']

    linhas = [
        ('Arquivos Fortran', lambda r: len(arq(r))),
        ('Linhas totais', lambda r: sum(a[1] for a in arq(r))),
        ('Linhas de código', lambda r: sum(a[2] for a in arq(r))),
        (f'Arquivos com mais de {LIMITE_ARQUIVO} linhas',
         lambda r: sum(1 for a in arq(r) if a[1] > LIMITE_ARQUIVO)),
        ('Maior arquivo (linhas)', lambda r: max((a[1] for a in arq(r)), default=0)),
        ('Rotinas', lambda r: len(r['rotinas'])),
        ('Rotinas com mais de 100 linhas de código', lambda r: sum(1 for x in r['rotinas'] if x[3] > 100)),
        ('Rotinas com mais de 150 linhas de código', lambda r: sum(1 for x in r['rotinas'] if x[3] > 150)),
        ('Maior rotina (linhas de código)', lambda r: max((x[3] for x in r['rotinas']), default=0)),
        ('Variáveis de módulo públicas', lambda r: sum(1 for x in r['estado_modulo'] if x[3] == 'pública')),
        ('Variáveis de módulo protegidas', lambda r: sum(1 for x in r['estado_modulo'] if x[3] == 'protegida')),
        ('Variáveis de módulo privadas', lambda r: sum(1 for x in r['estado_modulo'] if x[3] == 'privada')),
        ('Variáveis locais com save explícito', lambda r: sum(1 for x in r['save_local'] if x[4] == 'explícito')),
        ('Variáveis locais com save implícito', lambda r: sum(1 for x in r['save_local'] if x[4] == 'implícito')),
        ('Trechos repetidos (janelas de 6 linhas)', lambda r: len(r['repetidos'])),
        ('Comentários com marcas de histórico', lambda r: r['marcas']),
    ]
    cab = ['Indicador'] + [('árvore de trabalho' if v == '.' else f'`{v}`') for v in versoes]
    out = ['| ' + ' | '.join(cab) + ' |', '| ' + ' | '.join(['---'] * len(cab)) + ' |']
    for nome, f in linhas:
        out.append('| ' + ' | '.join([nome] + [str(f(m)) for m in medidas]) + ' |')
    return '\n'.join(out)


def lista(r):
    out = ['', f'## Arquivos com mais de {LIMITE_ARQUIVO} linhas', '']
    for c, n, k in sorted(r['arquivos'], key=lambda a: -a[1]):
        if n > LIMITE_ARQUIVO:
            out.append(f'- `{c}`: {n} linhas ({k} de código)')
    out += ['', '## Rotinas com mais de 100 linhas de código', '']
    for c, nome, n, k in sorted(r['rotinas'], key=lambda x: -x[3]):
        if k > 100:
            out.append(f'- `{nome}` ({c}): {k} de código, {n} no total')
    out += ['', '## Variáveis de módulo públicas', '']
    for c, n, nome, t in r['estado_modulo']:
        if t == 'pública':
            out.append(f'- `{nome}` ({c}:{n})')
    out += ['', '## Variáveis locais com save', '']
    for c, n, rot, nome, t in r['save_local']:
        out.append(f'- `{nome}` em `{rot}` ({c}:{n}), {t}')
    out += ['', '## Trechos repetidos, por grupo de arquivos', '']
    grupos = collections.Counter()
    for v in r['repetidos'].values():
        grupos[tuple(sorted({c.split('/')[-1] for c, _ in v}))] += 1
    for g, k in grupos.most_common():
        out.append(f'- {k} janela(s): ' + ', '.join(f'`{x}`' for x in g))
    return '\n'.join(out)


def main():
    args = [a for a in sys.argv[1:] if a != '-l']
    if any(a in ('-h', '--help') for a in args):
        print(__doc__)
        return 0
    versoes = args or ['.']
    for v in versoes:
        if v != '.' and subprocess.run(['git', 'rev-parse', '--verify', '--quiet', v + '^{commit}'],
                                       capture_output=True).returncode != 0:
            print(f'ERRO: versão {v!r} não encontrada', file=sys.stderr)
            return 2
    medidas = [mede(v) for v in versoes]
    print(tabela(versoes, medidas))
    if '-l' in sys.argv[1:]:
        print(lista(medidas[-1]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
