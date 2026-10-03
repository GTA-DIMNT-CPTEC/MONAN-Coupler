#!/usr/bin/env python3
"""renomeia-identificadores.py: troca nomes de identificadores Fortran por uma tabela.

Usado na fase 12 (nomes em inglês). Cada etapa tem uma tabela em
tools/dev/nomes/ com uma troca por linha:

    nome_antigo   new_name
    nome_local    local_name   src/regrid/,tests/regrid/
    @arquivo  caminho/antigo.F90  caminho/novo.F90

O nome antigo e o novo são identificadores Fortran (sem diferença de
maiúsculas). Um terceiro campo opcional limita a troca aos arquivos cujo
caminho começa por um dos prefixos (para nomes locais comuns, como campo,
que outras etapas trocam nas suas áreas). A linha "@arquivo" renomeia um
fonte (git mv).

Regras da troca, nos fontes Fortran (.F90 e .inc de src/ e tests/):
  - no código, todo identificador da tabela é trocado, preservando a
    caixa (NOME vira NEW_NAME, nome vira new_name);
  - textos entre aspas nunca mudam (mensagens, nomes de campos, valores das
    tabelas do mapa, opções);
  - nos comentários, só os nomes que não se confundem com palavras comuns:
    os que têm sublinhado, os escritos em CamelCase e, escritos em
    maiúsculas, os que a tabela traz em maiúsculas (os nomes das tabelas do
    mapa, como TROCAS). Um nome de uma palavra só, como entregar, fica como
    está no comentário e é revisto à mão.
Nos scripts (.py, .bash, .sh) e Makefiles, só os nomes com sublinhado, em
todo o arquivo (nomes em maiúsculas ali podem ser variáveis do script ou
textos de saída). Nos textos (.md, .txt), também, e, entre crases, os nomes sem
sublinhado das trocas que valem em todos os arquivos; nos blocos de código
Fortran dos textos, a regra dos fontes. Em prosa, um nome
colado a um hífen (parte de um nome de arquivo) não muda. O histórico
(docs/CHANGELOG.md e docs/historico/) e as tabelas não mudam. O resultado nos arquivos que não
são fontes Fortran deve ser lido no diff.

Uso (na raiz do repositório):
  tools/dev/renomeia-identificadores.py aplica TABELA [TABELA ...]
      aplica as trocas na árvore de trabalho
  tools/dev/renomeia-identificadores.py confere REV TABELA [TABELA ...]
      confere, sem alterar nada:
        1. colisões: em nenhuma unidade de escopo de REV (procedimento, ou
           cabeçalho de módulo ou programa) que usa um nome antigo como
           entidade pode ser visível o nome novo (na própria unidade ou nas
           que a contêm), nem dois antigos podem virar o mesmo nome; o nome
           novo não pode ser uma função intrínseca do Fortran. Componentes
           de tipo (depois de %) e palavras-chave de argumento (nome=) não
           contam como entidades;
        2. equivalência: cada fonte de REV, com as trocas aplicadas só ao
           código, tem de ser igual, símbolo a símbolo, ao fonte da árvore
           de trabalho (comentários e espaços não contam; textos entre
           aspas têm de ser idênticos).
      Código de saída 0 se tudo confere.

  tools/dev/renomeia-identificadores.py traduz REV DIR
      aplica, aos fontes Fortran de uma cópia de REV extraída em DIR (por
      git archive), as tabelas de tools/dev/nomes/ que ainda não existiam
      em REV. Serve aos testes de regressão que compilam REV com o programa
      de teste da árvore de trabalho (tests/malhas, tests/completar,
      tests/docn): a cópia traduzida é REV com os nomes de hoje.

Quem tem trabalho num ramo antigo pode usar "aplica" com as tabelas de
tools/dev/nomes/ para trazer o seu ramo para os nomes novos.

INPE / CGCT / DIMNT, GT Acoplamento de Modelos.
"""
import io
import os
import re
import subprocess
import sys

FORTRAN_EXT = ('.F90', '.f90', '.inc')
TEXT_EXT = ('.md', '.py', '.bash', '.sh', '.txt')
TEXT_NAMES = ('Makefile',)
IDENT = re.compile(r'[A-Za-z][A-Za-z0-9_]*')
UPPER_IN_PROSE = set()   # nomes que a tabela traz em maiúsculas
THIS = 'tools/dev/renomeia-identificadores.py'

INTRINSICS = set('''
abs achar acos adjustl adjustr aimag aint all allocated anint any asin associated
atan atan2 bit_size btest ceiling char cmplx conjg cos cosh count cpu_time cshift
date_and_time dble digits dim dot_product dprod eoshift epsilon exp exponent
findloc floor fraction huge iachar iand ibclr ibits ibset ichar ieor index int ior
ishft ishftc is_iostat_end kind lbound len len_trim lge lgt lle llt log log10
logical matmul max maxexponent maxloc maxval merge min minexponent minloc minval
mod modulo move_alloc mvbits nearest new_line nint norm2 not null pack popcnt
precision present product radix random_number random_seed range real repeat
reshape rrspacing scale scan selected_int_kind selected_real_kind set_exponent
shape sign sin sinh size spacing spread sqrt storage_size sum system_clock tan
tanh tiny trailz transfer transpose trim ubound unpack verify
'''.split())


def utf8_output():
    """Saídas em UTF-8 também no Python 3.6 com locale C (Jaci)."""
    for name in ('stdout', 'stderr'):
        stream = getattr(sys, name)
        if (stream.encoding or '').lower().replace('-', '') != 'utf8':
            setattr(sys, name, io.TextIOWrapper(stream.buffer, encoding='utf-8',
                                                errors='replace', line_buffering=True))


def git(*args):
    r = subprocess.run(['git'] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout.decode('utf-8', 'replace')


def read_tables(paths):
    """Lê as tabelas: devolve (trocas [(antigo, novo, prefixos)], arquivos
    {antigo: novo}); prefixos é None para uma troca em todos os arquivos."""
    entries, files = [], {}
    for path in paths:
        with open(path, encoding='utf-8') as f:
            for num, line in enumerate(f, 1):
                line = line.split('#', 1)[0].strip()
                if not line:
                    continue
                parts = line.split()
                where = '%s:%d' % (path, num)
                if parts[0] == '@arquivo' and len(parts) == 3:
                    files[parts[1]] = parts[2]
                elif len(parts) in (2, 3) and all(IDENT.fullmatch(p) for p in parts[:2]):
                    prefixes = tuple(parts[2].split(',')) if len(parts) == 3 else None
                    entries.append((parts[0].lower(), parts[1].lower(), prefixes))
                    if parts[0].isupper():
                        UPPER_IN_PROSE.add(parts[0].lower())
                else:
                    sys.exit('ERRO: %s: linha inválida: %s' % (where, line))
    return entries, files


def names_for(entries, path):
    """Trocas que valem para um arquivo: {antigo: novo}; com path None, todas
    (para os textos entre crases)."""
    names = {}
    for old, new, prefixes in entries:
        if path is not None and prefixes is not None and not path.startswith(prefixes):
            continue
        if old in names and names[old] != new:
            if path is None:
                continue      # textos: vale a primeira troca da tabela
            sys.exit('ERRO: %s tem duas trocas em %s' % (old, path))
        names[old] = new
    return names


def split_fortran(text):
    """Divide um fonte Fortran em pedaços (tipo, texto), com tipo 'code',
    'string' ou 'comment'. Um texto entre aspas pode continuar na linha
    seguinte (& no fim da linha)."""
    pieces, buf, kind, quote = [], [], 'code', None
    i, n = 0, len(text)

    def flush(new_kind):
        nonlocal buf, kind
        if buf:
            pieces.append((kind, ''.join(buf)))
        buf, kind = [], new_kind

    while i < n:
        c = text[i]
        if kind == 'code':
            if c in '"\'':
                flush('string')
                quote = c
                buf.append(c)
            elif c == '!':
                flush('comment')
                buf.append(c)
            else:
                buf.append(c)
        elif kind == 'string':
            buf.append(c)
            if c == quote:
                if i + 1 < n and text[i + 1] == quote:
                    buf.append(quote)
                    i += 1
                else:
                    flush('code')
        else:  # comment
            if c == '\n':
                flush('code')
                buf.append(c)
            else:
                buf.append(c)
        i += 1
    flush('code')
    return pieces


def styled(original, new):
    if original.isupper():
        return new.upper()
    if original[:1].isupper() and original[1:].islower():
        return new.capitalize()
    return new


def wanted_in_prose(token, upper=True):
    camel = any(c.isupper() for c in token[1:]) and any(c.islower() for c in token)
    return '_' in token or camel or \
        (upper and token.isupper() and token.lower() in UPPER_IN_PROSE)


PROSE_IDENT = re.compile(r'(?<![-A-Za-z0-9_])[A-Za-z][A-Za-z0-9_]*(?![-A-Za-z0-9_])')


def rename_tokens(text, names, prose, upper=True, align=False):
    """Troca os nomes de um trecho. Em prosa (comentários e textos), um nome
    colado a um hífen é parte de um nome de arquivo e não muda. Com align,
    a diferença de tamanho de cada nome trocado é compensada no próximo
    espaço de duas ou mais colunas da mesma linha, para manter alinhadas as
    colunas seguintes (os :: das declarações, os & das continuações)."""
    pattern = PROSE_IDENT if prose else IDENT
    out, pos, debt = [], 0, 0
    for m in pattern.finditer(text):
        tok = m.group(0)
        new = names.get(tok.lower())
        if new is None or (prose and not wanted_in_prose(tok, upper)):
            continue
        gap = text[pos:m.start()]
        if align and debt:
            gap, debt = pay(gap, debt)
        out.append(gap)
        out.append(styled(tok, new))
        if align:
            debt += len(new) - len(tok)
        pos = m.end()
    rest = text[pos:]
    if align and debt:
        rest, debt = pay(rest, debt)
    out.append(rest)
    return ''.join(out)


def pay(gap, debt):
    """Compensa debt colunas no primeiro espaço de 2 ou mais colunas de gap,
    antes do fim da linha; devolve o trecho e o que sobrou (0 no fim da
    linha, que zera a conta)."""
    line_end = gap.find('\n')
    head = gap if line_end < 0 else gap[:line_end]
    m = re.search(r'  +', head)
    if m:
        width = max(1, len(m.group(0)) - debt)
        head = head[:m.start()] + ' ' * width + head[m.end():]
        debt = 0
    if line_end >= 0:
        return head + gap[line_end:], 0
    return head, debt


def code_span_token(tok, names):
    """Nome entre crases: os que a tabela traz em maiúsculas só mudam
    escritos em maiúsculas (`malhas`, em minúsculas, é outra coisa que
    MALHAS)."""
    new = names.get(tok.lower())
    if new is None or (tok.lower() in UPPER_IN_PROSE and not tok.isupper()):
        return tok
    return styled(tok, new)


def rename_markdown(text, names, every):
    """Texto: fora das crases, a regra dos comentários; entre crases, também
    os nomes sem sublinhado das trocas que valem em todos os arquivos; nos
    blocos de código Fortran (```fortran), a regra dos fontes, com todas as
    trocas da tabela."""
    out = []
    for k, piece in enumerate(re.split(r'(```fortran\n.*?```)', text, flags=re.S)):
        if k % 2 == 1:
            out.append(rename_fortran(piece, every))
        else:
            out.append(rename_inline(piece, names, every))
    return ''.join(out)


def rename_inline(text, names, every):
    out = []
    for k, piece in enumerate(re.split(r'(`[^`\n]*`)', text)):
        out.append(rename_tokens(piece, every, prose=True))
        if k % 2 == 1:
            out[-1] = PROSE_IDENT.sub(lambda m: code_span_token(m.group(0), names), out[-1])
    return ''.join(out)


def rename_fortran(text, names, comments=True):
    out = []
    for kind, piece in split_fortran(text):
        if kind == 'code':
            out.append(rename_tokens(piece, names, prose=False, align=comments))
        elif kind == 'comment' and comments:
            out.append(rename_tokens(piece, names, prose=True, align=True))
        else:
            out.append(piece)
    return ''.join(out)


def code_symbols(text):
    """Símbolos do código (identificadores em minúsculas, textos entre aspas
    intactos e demais caracteres), sem comentários nem espaços; as linhas
    de continuação são juntadas."""
    syms = []
    for kind, piece in split_fortran(text):
        if kind == 'string':
            syms.append(piece)
        elif kind == 'code':
            for m in re.finditer(r'[A-Za-z][A-Za-z0-9_]*|[0-9][0-9A-Za-z_.]*|\S', piece):
                tok = m.group(0)
                if tok == '&':
                    continue
                syms.append(tok.lower() if tok[0].isalpha() else tok)
    return syms


def identifiers(text):
    found = set()
    for kind, piece in split_fortran(text):
        if kind == 'code':
            found.update(t.lower() for t in IDENT.findall(piece))
    return found


UNIT_START = re.compile(
    r'^\s*(?:(?:pure|elemental|impure|recursive|module|integer|logical|real|character|'
    r'type\s*\([^)]*\)|real\s*\([^)]*\)|integer\s*\([^)]*\)|character\s*\([^)]*\)'
    r'|logical\s*\([^)]*\))\s+)*(subroutine|function)\s+([a-z][a-z0-9_]*)', re.I)
HOST_START = re.compile(r'^\s*(module|program)\s+([a-z][a-z0-9_]*)\s*$', re.I)
UNIT_END = re.compile(r'^\s*end\s*(subroutine|function|module|program)\b', re.I)


def statements(text):
    """Instruções do código, sem comentários, com os textos entre aspas
    trocados por "" e as linhas de continuação juntadas."""
    code = ''.join(piece if kind == 'code' else ('""' if kind == 'string' else '')
                   for kind, piece in split_fortran(text))
    code = re.sub(r'&[ \t]*\n[ \t]*&?', ' ', code)
    out = []
    for line in code.split('\n'):
        out.extend(x for x in line.split(';') if x.strip())
    return out


def scoping_units(text):
    """Unidades de escopo de um fonte: o cabeçalho de cada módulo ou programa
    e cada procedimento (inclusive os de blocos de interface), com o pai.
    Para cada unidade, 'tokens' são todos os identificadores dela e
    'entities' os que nomeiam entidades: sem os componentes (depois de %) e
    sem as palavras-chave de argumento (nome= depois de ( ou ,)."""
    units = [{'name': '(arquivo)', 'parent': None, 'tokens': set(), 'entities': set()}]
    stack = [0]
    for st in statements(text):
        if st.lstrip().startswith('#'):
            continue
        m = UNIT_START.match(st) or HOST_START.match(st)
        if m and not re.match(r'^\s*module\s+procedure\b', st, re.I):
            units.append({'name': m.group(2).lower(), 'parent': stack[-1],
                          'tokens': set(), 'entities': set()})
            stack.append(len(units) - 1)
        u = units[stack[-1]]
        for mt in re.finditer(r'(%\s*)?\b([A-Za-z][A-Za-z0-9_]*)\b', st):
            tok = mt.group(2).lower()
            u['tokens'].add(tok)
            if mt.group(1):
                continue
            before = st[:mt.start()].rstrip()
            after = st[mt.end():]
            if before.endswith(('(', ',')) and re.match(r'\s*=(?!=)', after) and not \
                    re.match(r'^\s*(integer|real|logical|character|type|class)\b', st, re.I):
                continue
            u['entities'].add(tok)
        if UNIT_END.match(st) and len(stack) > 1:
            stack.pop()
    return units


def is_fortran(path):
    return path.endswith(FORTRAN_EXT) and (path.startswith('src/') or path.startswith('tests/'))


def is_text(path):
    return path.endswith(TEXT_EXT) or os.path.basename(path) in TEXT_NAMES


def tracked_files(rev=None):
    if rev:
        _, out = git('ls-tree', '-r', '--name-only', rev)
    else:
        _, out = git('ls-files')
    return [p for p in out.splitlines() if p]


def apply(tables):
    entries, files = read_tables(tables)
    for old, new in sorted(files.items()):
        if os.path.exists(old):
            os.makedirs(os.path.dirname(new) or '.', exist_ok=True)
            if subprocess.run(['git', 'mv', old, new]).returncode != 0:
                sys.exit('ERRO: git mv %s %s' % (old, new))
    changed = 0
    for path in tracked_files():
        if not os.path.isfile(path):
            continue
        if path.startswith(('tools/dev/nomes/', 'docs/historico/')) or path in ('docs/CHANGELOG.md', THIS):
            continue
        names = names_for(entries, path)
        if is_fortran(path):
            renamer = lambda t: rename_fortran(t, names)
        elif path.endswith(('.md', '.txt')):
            every = names_for(entries, None)
            names = {o: n for o, n, pre in entries if pre is None}
            renamer = lambda t: rename_markdown(t, names, every)
        elif is_text(path):
            renamer = lambda t: rename_tokens(t, names, prose=True, upper=False)
        else:
            continue
        if not names and not path.endswith(('.md', '.txt')):
            continue
        with open(path, encoding='utf-8') as f:
            text = f.read()
        new_text = renamer(text)
        if new_text != text:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(new_text)
            changed += 1
            print('alterado: %s' % path)
    print('%d arquivos alterados' % changed)


def check(rev, tables):
    entries, files = read_tables(tables)
    problems = 0
    sources = {}
    for path in tracked_files(rev):
        if is_fortran(path):
            _, sources[path] = git('show', '%s:%s' % (rev, path))

    # 1. colisões
    for old, new, _ in entries:
        if new in INTRINSICS:
            print('COLISAO: %s -> %s: nome novo é função intrínseca' % (old, new))
            problems += 1
        if len(new) > 63:
            print('COLISAO: %s -> %s: mais de 63 caracteres' % (old, new))
            problems += 1
    used = set()
    for p, text in sorted(sources.items()):
        names = names_for(entries, files.get(p, p))
        units = scoping_units(text)
        for u in units:
            visible = set(u['entities'])
            a = u['parent']
            while a is not None:
                visible |= units[a]['entities']
                a = units[a]['parent']
            targets = {}
            for old, new in names.items():
                if old not in u['tokens']:
                    continue
                used.add(old)
                if old not in u['entities']:
                    continue          # só componente (%) ou palavra-chave de argumento
                targets.setdefault(new, []).append(old)
                if new in visible:
                    print('COLISAO: %s -> %s: %s (%s) já vê %s' % (old, new, p, u['name'], new))
                    problems += 1
            for new, olds in targets.items():
                if len(olds) > 1:
                    print('COLISAO: %s viram %s em %s (%s)' % (','.join(olds), new, p, u['name']))
                    problems += 1
    # palavras-chave de argumento fora do alcance de uma troca limitada: o
    # argumento mudou de nome, a chamada não (erro de compilação)
    for p, text in sorted(sources.items()):
        names = names_for(entries, files.get(p, p))
        code = ' '.join(statements(text))
        for old, new, prefixes in entries:
            if prefixes is None or old in names:
                continue
            if re.search(r'[(,]\s*' + old + r'\s*=(?!=)', code, re.I):
                print('AVISO: %s aparece como palavra-chave de argumento em %s, fora do alcance da troca' % (old, p))
    for old, new, _ in entries:
        if old not in used:
            print('AVISO: %s não aparece em nenhum fonte de %s em que a troca vale' % (old, rev))

    # 2. equivalência
    new_paths = set()
    for path, text in sorted(sources.items()):
        new_path = files.get(path, path)
        new_paths.add(new_path)
        if not os.path.isfile(new_path):
            print('DIFERENCA: %s (de %s) não existe na árvore de trabalho' % (new_path, path))
            problems += 1
            continue
        with open(new_path, encoding='utf-8') as f:
            current = f.read()
        names = names_for(entries, new_path)
        expected = code_symbols(rename_fortran(text, names, comments=False))
        got = code_symbols(current)
        if expected != got:
            k = next((i for i, (a, b) in enumerate(zip(expected, got)) if a != b),
                     min(len(expected), len(got)))
            print('DIFERENCA: %s: símbolo %d: esperado %r, encontrado %r' % (
                new_path, k, ' '.join(expected[max(0, k - 5):k + 5]),
                ' '.join(got[max(0, k - 5):k + 5])))
            problems += 1
    for path in tracked_files():
        if is_fortran(path) and path not in new_paths and os.path.isfile(path):
            print('AVISO: %s é novo (não vem de %s)' % (path, rev))
    print('%d trocas de nome, %d de arquivo, %d fontes conferidos: %s' % (
        len(entries), len(files), len(sources), 'OK' if problems == 0 else '%d PROBLEMAS' % problems))
    return 0 if problems == 0 else 1


def new_tables(rev):
    """Tabelas de tools/dev/nomes/ da árvore de trabalho que não existem em REV."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    found = []
    folder = os.path.join(root, 'tools', 'dev', 'nomes')
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        rel = 'tools/dev/nomes/' + name
        if not name.endswith('.txt'):
            continue
        r = subprocess.run(['git', '-C', root, 'cat-file', '-e', '%s:%s' % (rev, rel)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            found.append(os.path.join(folder, name))
    return found


def translate(rev, folder):
    tables = new_tables(rev)
    if not tables:
        print('nenhuma tabela nova desde %s: %s fica como está' % (rev, folder))
        return 0
    entries, files = read_tables(tables)
    for old, new in sorted(files.items()):
        src, dst = os.path.join(folder, old), os.path.join(folder, new)
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.rename(src, dst)
    n = 0
    for base, _, names in os.walk(folder):
        for name in names:
            path = os.path.relpath(os.path.join(base, name), folder).replace(os.sep, '/')
            if not is_fortran(path):
                continue
            table = names_for(entries, path)
            if not table:
                continue
            full = os.path.join(base, name)
            with open(full, encoding='utf-8') as f:
                text = f.read()
            new_text = rename_fortran(text, table)
            if new_text != text:
                with open(full, 'w', encoding='utf-8') as f:
                    f.write(new_text)
                n += 1
    print('%s traduzido com %d tabela(s): %d fonte(s) alterado(s)' % (folder, len(tables), n))
    return 0


def main():
    utf8_output()
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == 'aplica':
        apply(args[1:])
        return 0
    if len(args) == 3 and args[0] == 'traduz':
        return translate(args[1], args[2])
    if len(args) >= 3 and args[0] == 'confere':
        return check(args[1], args[2:])
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main())
