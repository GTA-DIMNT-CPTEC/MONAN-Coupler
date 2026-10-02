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
    os que têm sublinhado e, escritos em maiúsculas, os que a tabela traz em
    maiúsculas (os nomes das tabelas do mapa, como TROCAS).
Nos scripts (.py, .bash, .sh) e Makefiles, vale a regra dos comentários em
todo o arquivo. Nos textos (.md, .txt), também, e, entre crases, os nomes sem
sublinhado das trocas que valem em todos os arquivos. Em prosa, um nome
colado a um hífen (parte de um nome de arquivo) não muda. O histórico
(docs/CHANGELOG.md) e as tabelas não mudam. O resultado nos arquivos que não
são fontes Fortran deve ser lido no diff.

Uso (na raiz do repositório):
  tools/dev/renomeia-identificadores.py aplica TABELA [TABELA ...]
      aplica as trocas na árvore de trabalho
  tools/dev/renomeia-identificadores.py confere REV TABELA [TABELA ...]
      confere, sem alterar nada:
        1. colisões: em nenhum fonte de REV que contém um nome antigo pode
           existir o nome novo, nem dois antigos com o mesmo nome novo; o
           nome novo não pode ser uma função intrínseca do Fortran;
        2. equivalência: cada fonte de REV, com as trocas aplicadas só ao
           código, tem de ser igual, símbolo a símbolo, ao fonte da árvore
           de trabalho (comentários e espaços não contam; textos entre
           aspas têm de ser idênticos).
      Código de saída 0 se tudo confere.

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


def wanted_in_prose(token):
    return '_' in token or (token.isupper() and token.lower() in UPPER_IN_PROSE)


PROSE_IDENT = re.compile(r'(?<![-A-Za-z0-9_])[A-Za-z][A-Za-z0-9_]*(?![-A-Za-z0-9_])')


def rename_tokens(text, names, prose):
    """Troca os nomes de um trecho. Em prosa (comentários e textos), um nome
    colado a um hífen é parte de um nome de arquivo e não muda."""
    def repl(m):
        tok = m.group(0)
        new = names.get(tok.lower())
        if new is None or (prose and not wanted_in_prose(tok)):
            return tok
        return styled(tok, new)
    return (PROSE_IDENT if prose else IDENT).sub(repl, text)


def rename_markdown(text, names, every):
    """Texto: fora das crases, a regra dos comentários; entre crases, também
    os nomes sem sublinhado das trocas que valem em todos os arquivos."""
    out = []
    for k, piece in enumerate(re.split(r'(`[^`\n]*`)', text)):
        out.append(rename_tokens(piece, every, prose=True))
        if k % 2 == 1:
            out[-1] = PROSE_IDENT.sub(
                lambda m: styled(m.group(0), names[m.group(0).lower()])
                if m.group(0).lower() in names else m.group(0), out[-1])
    return ''.join(out)


def rename_fortran(text, names, comments=True):
    out = []
    for kind, piece in split_fortran(text):
        if kind == 'code':
            out.append(rename_tokens(piece, names, prose=False))
        elif kind == 'comment' and comments:
            out.append(rename_tokens(piece, names, prose=True))
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
        if path.startswith('tools/dev/nomes/') or path == 'docs/CHANGELOG.md':
            continue
        names = names_for(entries, path)
        if is_fortran(path):
            renamer = lambda t: rename_fortran(t, names)
        elif path.endswith(('.md', '.txt')):
            every = names_for(entries, None)
            names = {o: n for o, n, pre in entries if pre is None}
            renamer = lambda t: rename_markdown(t, names, every)
        elif is_text(path):
            renamer = lambda t: rename_tokens(t, names, prose=True)
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
    present = {path: identifiers(text) for path, text in sources.items()}
    used = set()
    for p, ids in sorted(present.items()):
        names = names_for(entries, files.get(p, p))
        targets = {}
        for old, new in names.items():
            if old not in ids:
                continue
            used.add(old)
            targets.setdefault(new, []).append(old)
            if new in ids:
                print('COLISAO: %s -> %s: %s já tem %s' % (old, new, p, new))
                problems += 1
        for new, olds in targets.items():
            if len(olds) > 1:
                print('COLISAO: %s viram %s em %s' % (','.join(olds), new, p))
                problems += 1
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


def main():
    utf8_output()
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == 'aplica':
        apply(args[1:])
        return 0
    if len(args) >= 3 and args[0] == 'confere':
        return check(args[1], args[2:])
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main())
