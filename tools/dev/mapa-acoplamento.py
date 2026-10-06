#!/usr/bin/env python3
"""mapa-acoplamento.py: gera docs/acoplamento.md a partir do mapa de acoplamento.

Lê as tabelas de src/coupling/cpl_fields.F90 (FIELDS),
src/coupling/cpl_map.F90 (GRIDS, EXCHANGES, EXPORTS e ROUTES) e
src/shared/coupler_config.F90 (COUPLER_MODES) e escreve uma versão legível
do mapa em Markdown: combinações de componentes aceitas, resumo dos
conectores por configuração, trocas de cada conector, trocas dentro dos componentes,
exportações dos modelos, rotas do mediador, malhas e dicionário de campos. O Fortran é a fonte; o Markdown é gerado e
não deve ser editado à mão.

Também confere o que o compilador não confere: textos mais longos que o
campo que os recebe (o Fortran cortaria sem erro, só com aviso).

Uso (na raiz do repositório):
  tools/dev/mapa-acoplamento.py [-c] [-s RAIZ] [-o SAIDA]
    -c        não escreve: confere se SAIDA está igual ao que seria gerado
    -s RAIZ   raiz do repositório (padrão: a deste script)
    -o SAIDA  arquivo gerado (padrão: RAIZ/docs/acoplamento.md)

Código de saída: 0 se gerou (ou, com -c, se o arquivo está em dia);
1 se, com -c, o arquivo está desatualizado; 2 erro de leitura ou texto
longo demais.

Escrito para o Python 3.6 da Jaci (sem dataclasses nem capture_output).
"""
import collections
import io
import os
import re
import sys

# Configurações conferidas por tests/unit/test_cpl_map.F90, na mesma ordem.
# Todas precisam ser aceitas pela tabela COUPLER_MODES (conferido em gera).
CONFIGS = collections.OrderedDict([
    ('producao',      dict(datm=False, docn=False, med_to_mpas=True,  sis2=True)),
    ('mom6_sem_sis2', dict(datm=False, docn=False, med_to_mpas=True,  sis2=False)),
    ('mpas_docn',     dict(datm=False, docn=True,  med_to_mpas=False, sis2=False)),
    ('datm_mom6',     dict(datm=True,  docn=False, med_to_mpas=True,  sis2=False)),
    ('datm_docn',     dict(datm=True,  docn=True,  med_to_mpas=False, sis2=False)),
])

CONDITIONS = {
    'mpas':        lambda c: not c['datm'],
    'datm':        lambda c: c['datm'],
    'mom6':        lambda c: not c['docn'],
    'docn':        lambda c: c['docn'],
    'med_to_mpas': lambda c: c['med_to_mpas'],
    'ocn_to_mpas': lambda c: not c['med_to_mpas'],
    'sis2':        lambda c: c['sis2'],
}

PARES = [('ATM', 'MED'), ('OCN', 'MED'), ('ICE', 'MED'),
         ('MED', 'OCN'), ('MED', 'ICE'), ('MED', 'ATM'), ('OCN', 'ATM')]


class ErroMapa(Exception):
    pass


def saida_utf8():
    """Imprime em UTF-8 mesmo com o locale C (Python 3.6 da Jaci)."""
    if sys.stdout.encoding is None or sys.stdout.encoding.lower() != 'utf-8':
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')


def separa(linha):
    """Código da linha sem o comentário, respeitando as aspas."""
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


def instrucoes(texto):
    """Instruções do fonte, com as continuações juntadas e sem comentários."""
    saida, buf = [], ''
    for linha in texto.split('\n'):
        s = separa(linha).strip()
        if not s:
            continue
        if s.startswith('&'):
            s = s[1:]
        if s.endswith('&'):
            buf += s[:-1]
            continue
        saida.append(buf + s)
        buf = ''
    return saida


def divide(s):
    """Divide s nas vírgulas de nível zero, fora de aspas e parênteses."""
    partes, atual, prof, aspa = [], '', 0, None
    for c in s:
        if aspa:
            atual += c
            if c == aspa:
                aspa = None
            continue
        if c in "'\"":
            aspa = c
        elif c in '([':
            prof += 1
        elif c in ')]':
            prof -= 1
        if c == ',' and prof == 0:
            partes.append(atual.strip())
            atual = ''
        else:
            atual += c
    if atual.strip():
        partes.append(atual.strip())
    return partes


def chamadas(s, nome):
    """Argumentos (texto) de cada chamada nome(...) em s, na ordem."""
    saida, i = [], 0
    padrao = re.compile(r'\b' + nome + r'\s*\(', re.I)
    while True:
        m = padrao.search(s, i)
        if not m:
            return saida
        j, prof, aspa = m.end(), 1, None
        while prof:
            c = s[j]
            if aspa:
                if c == aspa:
                    aspa = None
            elif c in "'\"":
                aspa = c
            elif c == '(':
                prof += 1
            elif c == ')':
                prof -= 1
            j += 1
        saida.append(s[m.end():j - 1])
        i = j


def texto(v, consts=None):
    """Valor de um argumento: texto sem aspas, ou a expressão como está.

    Com consts (constantes de texto do fonte), resolve também o nome de uma
    constante e a concatenação ('a' // NOME) de textos entre aspas e de
    constantes."""
    v = v.strip()
    if consts is not None and (v in consts or len(concatenacao(v)) > 1):
        valores = []
        for p in concatenacao(v):
            if len(p) >= 2 and p[0] == p[-1] and p[0] in "'\"":
                valores.append(p[1:-1])
            elif p in consts:
                valores.append(consts[p])
            else:
                return v
        return ''.join(valores)
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    return v


def concatenacao(s):
    """Partes de s separadas por '//' fora de aspas."""
    partes, atual, aspa, i = [], '', None, 0
    while i < len(s):
        c = s[i]
        if aspa:
            if c == aspa:
                aspa = None
        elif c in "'\"":
            aspa = c
        elif s.startswith('//', i):
            partes.append(atual.strip())
            atual, i = '', i + 2
            continue
        atual += c
        i += 1
    partes.append(atual.strip())
    return partes


def constantes_texto(instrs):
    """Constantes de texto declaradas (character(len=*), parameter :: NOME = 'x')."""
    c = {}
    for s in instrs:
        m = re.match(r"character\s*\(\s*len\s*=\s*\*\s*\)\s*,\s*parameter\s*::\s*(\w+)\s*=\s*(.*)$",
                     s, re.I)
        if m:
            c[m.group(1)] = texto(m.group(2), c)
    return c


def componentes(instrs, tipo, params):
    """Componentes (nome, comprimento ou None, padrão) do tipo derivado."""
    dentro, saida = False, []
    for s in instrs:
        if re.match(r'type\s*(,[^:]*)?::\s*' + tipo + r'\s*$', s, re.I):
            dentro = True
            continue
        if dentro and re.match(r'end\s*type', s, re.I):
            return saida
        if dentro:
            m = re.match(r'(.*?)::\s*(\w+)\s*(?:=\s*(.*))?$', s)
            if not m:
                continue
            comp = None
            mlen = re.search(r'character\s*\(\s*len\s*=\s*(\w+)\s*\)', m.group(1), re.I)
            if mlen:
                comp = int(params.get(mlen.group(1), mlen.group(1)))
            saida.append((m.group(2), comp, texto(m.group(3) or '')))
    raise ErroMapa('tipo ' + tipo + ' não encontrado')


def parametros_inteiros(instrs):
    """Parâmetros inteiros declarados (NOME = número)."""
    p = {}
    for s in instrs:
        m = re.match(r'integer\s*,\s*parameter\s*::\s*(.*)$', s, re.I)
        if m:
            for parte in divide(m.group(1)):
                m2 = re.match(r'(\w+)\s*=\s*(\d+)$', parte)
                if m2:
                    p[m2.group(1)] = m2.group(2)
    return p


def vetores_texto(instrs):
    """Vetores de texto constantes (grupos de campos do mapa):
    'character(len=...), parameter :: NOME(*) = [character(len=...) :: itens]',
    em que cada item é um texto entre aspas ou um vetor declarado antes."""
    v = {}
    for s in instrs:
        m = re.match(r'character\s*\([^)]*\)\s*,\s*parameter\s*::\s*(\w+)\s*\(\s*\*\s*\)\s*=\s*'
                     r'\[\s*(?:character\s*\([^)]*\)\s*::)?(.*)\]\s*$', s, re.I)
        if not m:
            continue
        itens = []
        for item in divide(m.group(2)):
            if item in v:
                itens += v[item]
            else:
                itens.append(texto(item))
        v[m.group(1)] = itens
    return v


def tabela_fortran(instrs, tipo, nome, params, arquivo, consts=None):
    """Linhas da tabela 'type(tipo), parameter[, public] :: nome(*) = [...]'.

    Uma passagem '(tipo(GRUPO(i), ...), i = 1, size(GRUPO))', em que GRUPO é
    um vetor de texto do fonte (vetores_texto), vira uma linha por elemento
    do grupo, na ordem do grupo, como o compilador a expande."""
    comps = componentes(instrs, tipo, params)
    grupos = vetores_texto(instrs)
    for s in instrs:
        if re.match(r'type\s*\(\s*' + tipo + r'\s*\)\s*,\s*parameter\s*(,\s*public\s*)?::\s*'
                    + nome + r'\b', s, re.I):
            linhas = []
            for args in chamadas(s, tipo):
                partes = divide(args)
                valores = [None]
                mg = re.match(r'(\w+)\s*\(\s*\w+\s*\)$', partes[0]) if partes else None
                if mg and mg.group(1) in grupos:
                    valores = grupos[mg.group(1)]
                for valor0 in valores:
                    linha = collections.OrderedDict((c, d) for c, _, d in comps)
                    for k, a in enumerate(partes):
                        m = re.match(r'(\w+)\s*=(?!=)\s*(.*)$', a, re.S)
                        if m and m.group(1) in linha:
                            chave, valor = m.group(1), texto(m.group(2), consts)
                        elif k == 0 and valor0 is not None:
                            chave, valor = comps[0][0], valor0
                        else:
                            chave, valor = comps[k][0], texto(a, consts)
                        linha[chave] = valor
                    for c, comp, _ in comps:
                        if comp is not None and len(linha[c].encode('utf-8')) > comp:
                            raise ErroMapa('{}: {}: "{}" tem mais de {} caracteres'.format(
                                arquivo, c, linha[c], comp))
                    linhas.append(linha)
            return linhas
    raise ErroMapa('{}: tabela {} não encontrada'.format(arquivo, nome))


def le_mapa(raiz):
    """Lê FIELDS, GRIDS, EXCHANGES, EXPORTS, GAPS, ROUTES e COUPLER_MODES dos fontes."""
    tabelas = {}
    for arquivo, itens in (('src/shared/coupler_config.F90', [('coupler_mode_t', 'COUPLER_MODES')]),
                           ('src/coupling/cpl_fields.F90', [('cpl_field_t', 'FIELDS')]),
                           ('src/coupling/cpl_map.F90', [('cpl_grid_ref_t', 'GRIDS'),
                                                          ('cpl_exchange_t', 'EXCHANGES'),
                                                          ('cpl_export_t', 'EXPORTS'),
                                                          ('cpl_gap_t', 'GAPS'),
                                                          ('cpl_route_t', 'ROUTES')])):
        caminho = os.path.join(raiz, arquivo)
        try:
            with open(caminho, encoding='utf-8') as f:
                instrs = instrucoes(f.read())
        except OSError as e:
            raise ErroMapa('não foi possível ler {}: {}'.format(caminho, e))
        params = parametros_inteiros(instrs)
        if arquivo.endswith('cpl_map.F90'):
            # CPL_NAME_LEN vem de cpl_fields
            params.setdefault('CPL_NAME_LEN', tabelas['_params_fields']['CPL_NAME_LEN'])
        elif arquivo.endswith('cpl_fields.F90'):
            tabelas['_params_fields'] = params
        for tipo, nome in itens:
            tabelas[nome] = tabela_fortran(instrs, tipo, nome, params, arquivo,
                                           constantes_texto(instrs))
    return tabelas


def vale(troca, cfg):
    conds = [c.strip() for c in troca['when'].split(',') if c.strip()]
    for c in conds:
        if c not in CONDITIONS:
            raise ErroMapa('condição desconhecida: ' + c)
    return all(CONDITIONS[c](cfg) for c in conds)


def comp(ponto):
    return ponto.split('@')[0]


def malha(ponto):
    return ponto.split('@')[1] if '@' in ponto else ''


def md_tabela(cab, linhas):
    out = ['| ' + ' | '.join(cab) + ' |', '| ' + ' | '.join(['---'] * len(cab)) + ' |']
    for l in linhas:
        out.append('| ' + ' | '.join(str(x) if x != '' else ' ' for x in l) + ' |')
    return out


def codigo(s):
    return '`{}`'.format(s) if s else ''


def numero(v):
    """Literal Fortran legível: sem o kind e sem o '.0' final."""
    v = v.strip()
    if not re.match(r'[-+]?[\d.]', v):
        return '`{}`'.format(v)   # constante com nome
    v = re.sub(r'_\w+$', '', v)
    return re.sub(r'\.0$', '', v)


def preenchimento(expr):
    """regrid_fill_t(...) em texto: faixa válida, valor fixo e passadas."""
    if not expr or expr == 'regrid_fill_t()':
        return ''
    args = {}
    for a in divide(chamadas(expr, 'regrid_fill_t')[0]):
        m = re.match(r'(\w+)\s*=\s*(.*)$', a)
        if m:
            args[m.group(1)] = m.group(2)
    partes = ['faixa {} a {}, valor {}'.format(numero(args.get('vmin', '0')),
                                               numero(args.get('vmax', '0')),
                                               numero(args.get('vfill', '0'))),
              '{} passadas'.format(args.get('max_iter', '15'))]
    if 'skip_fraction' in args:
        partes.append('fração {}'.format(numero(args['skip_fraction'])))
    if args.get('overflow_to_fill', '').lower() == '.true.':
        partes.append('acima da faixa vira o valor')
    return '; '.join(partes)


def quando_md(q):
    return ', '.join('`{}`'.format(c.strip()) for c in q.split(',') if c.strip()) or 'sempre'


def gera(t):
    trocas, rotas, campos, malhas = t['EXCHANGES'], t['ROUTES'], t['FIELDS'], t['GRIDS']
    exporta = t['EXPORTS']
    out = [
        '# Mapa de acoplamento do MONAN-Coupler',
        '',
        'Arquivo gerado por `tools/dev/mapa-acoplamento.py` a partir de',
        '`src/coupling/cpl_fields.F90` e `src/coupling/cpl_map.F90`. Não editar à',
        'mão: mudar o Fortran e gerar de novo. A consistência das tabelas é',
        'conferida por `tests/unit/test_cpl_map.F90`; a arquitetura está em',
        '`docs/arquitetura-acoplamento.md`.',
        '',
        'O mapa descreve o acoplamento que o código faz hoje. O mediador e os caps',
        'dos cinco modelos anunciam e realizam os campos a partir dele, na ordem',
        'das linhas de `EXCHANGES` (importação) e de `EXPORTS` (exportação).',
        '',
        '{} campos, {} malhas, {} trocas, {} exportações e {} rotas.'.format(
            len(campos), len(malhas), len(trocas), len(exporta), len(rotas)),
        '',
        '## 1. Configurações',
        '',
        'Cada troca vale numa lista de condições (coluna `when`), escolhidas',
        'pelas chaves do grupo `&nuopc_mode` do `nuopc.input`:',
        '',
    ]
    out += md_tabela(['Condição', 'Vale quando'], [
        ['`mpas` / `datm`', 'componente atmosférico é o MONAN-A / o DATM (`use_datm`)'],
        ['`mom6` / `docn`', 'componente oceânico é o MOM6 / o DOCN (`use_docn`)'],
        ['`med_to_mpas` / `ocn_to_mpas`',
         'contorno oceânico da atmosfera pelo mediador / direto do oceano (`use_med_to_mpas`)'],
        ['`sis2`', 'gelo dinâmico (`use_sis2_dynamic`)'],
    ])
    modos = t['COUPLER_MODES']
    chaves = ('datm', 'docn', 'med_to_mpas', 'sis2')

    def situacao(cfg):
        for m in modos:
            if all((m[k].lower() == '.true.') == cfg[k] for k in chaves):
                return m['status']
        raise ErroMapa('combinação ausente de COUPLER_MODES: {}'.format(cfg))

    for n, cfg in CONFIGS.items():
        if situacao(cfg) == 'recusada':
            raise ErroMapa('configuração {} recusada em COUPLER_MODES'.format(n))
    sim = {'.true.': 'T', '.false.': 'F'}
    out += [
        '',
        'As quatro chaves formam 16 combinações. A tabela `COUPLER_MODES`',
        '(`src/shared/coupler_config.F90`) diz o que acontece com cada uma, e é',
        'consultada pela leitura do `nuopc.input` e pelo mapa: `suportada` é a',
        'produção, com ou sem o SIS2; `nao_validada` é aceita com aviso no início',
        'da rodada; `recusada` para a rodada na leitura, e a nota é a mensagem.',
        'Os valores padrão das chaves formam a configuração de produção.',
        '',
    ]
    out += md_tabela(['`use_datm`', '`use_docn`', '`use_med_to_mpas`', '`use_sis2_dynamic`',
                      'Situação', 'Nota'],
                     [[sim[m[k].lower()] for k in chaves] + [codigo(m['status']), m['note']]
                      for m in modos])
    out += ['', 'Campos por conector em cada configuração conferida pelo teste:', '']
    nomes = list(CONFIGS)
    linhas = []
    for o, d in PARES:
        linhas.append(['{} para {}'.format(o, d)] + [
            sum(1 for x in trocas if x['via'] == 'conector' and vale(x, CONFIGS[n])
                and comp(x['src']) == o and comp(x['dst']) == d) for n in nomes])
    out += md_tabela(['Conector'] + ['`{}`'.format(n) for n in nomes], linhas)
    out += [
        '',
        '`producao` é a configuração de validação (MONAN-A, MOM6 e SIS2, contorno',
        'pelo mediador). O driver não registra o DATM: as trocas com `datm`',
        'descrevem o que o cap do DATM anuncia, e a conferência do mapa',
        'interrompe uma rodada com `use_datm`.',
        '',
        'Lacunas conhecidas (tabela `GAPS`): campos que um componente anuncia',
        'na importação e que, na configuração indicada, não têm origem. A',
        'conferência do mapa as registra como aviso, e não como diferença; nas',
        'lacunas do MONAN-A, o cap atmosférico interrompe a rodada por conta',
        'própria.',
        '',
    ]
    out += md_tabela(['Campo', 'Ponto', 'Quando', 'Motivo'],
                     [[codigo(x['field']), codigo(x['point']), quando_md(x['when']),
                       x['reason']] for x in t['GAPS']])
    out += [
        '',
        '## 2. Trocas por conector',
        '',
        'A coluna "Método" é o método de interpolação do conector NUOPC para o',
        'campo (coluna `method` de `EXCHANGES`), que o driver escreve na `CplList`',
        'como `remapmethod` (`cpl_write_methods`, em `src/coupling/cpl_check.F90`).',
        '',
    ]
    for o, d in PARES:
        sel = [x for x in trocas if x['via'] == 'conector'
               and comp(x['src']) == o and comp(x['dst']) == d]
        if not sel:
            continue
        out += ['### {} para {}'.format(o, d), '']
        out += md_tabela(['Campo', 'De', 'Para', 'Método', 'Quando'],
                         [[codigo(x['field']), codigo(x['src']), codigo(x['dst']),
                           codigo(x['method']), quando_md(x['when'])] for x in sel])
        out.append('')
    out += ['## 3. Trocas dentro dos componentes', '',
            'Passagens entre duas malhas do mesmo componente: código próprio do cap',
            '(`cap`) ou rota do mediador.', '']
    sel = [x for x in trocas if x['via'] != 'conector']
    out += md_tabela(['Campo', 'De', 'Para', 'Meio', 'Quando'],
                     [[codigo(x['field']), codigo(x['src']), codigo(x['dst']),
                       codigo(x['via']), quando_md(x['when'])] for x in sel])
    out += ['', '## 4. Exportações dos modelos', '',
            'Campos que cada modelo anuncia no estado de exportação, na ordem do',
            'anúncio. Um campo exportado pode não ter consumidor (o conector só leva',
            'os que o destino importa); a conferência do mapa os lista como aviso.',
            '"Consumido em" diz em quais configurações conferidas o campo sai por',
            'algum conector.', '']
    linhas = []
    for e in exporta:
        usos = [n for n in nomes if vale(e, CONFIGS[n]) and any(
            x['via'] == 'conector' and x['field'] == e['field'] and x['src'] == e['point']
            and vale(x, CONFIGS[n]) for x in trocas)]
        linhas.append([codigo(e['field']), codigo(e['point']), quando_md(e['when']),
                       ', '.join('`{}`'.format(n) for n in usos) or 'nenhuma'])
    out += md_tabela(['Campo', 'Ponto', 'Quando', 'Consumido em'], linhas)
    out += ['', '## 5. Rotas do mediador', '',
            'Toda rota tem quatro etapas: preparar (máscara, pontos sem valor),',
            'interpolar (métodos, reserva, esquema), completar (preenchimento por',
            'vizinhança) e limitar (troca de NaN). Coluna vazia: etapa desligada.',
            '"Campos" é o número de campos que passam pela rota em EXCHANGES.', '']
    linhas = []
    for r in rotas:
        usos = sorted({x['field'] for x in trocas if x['via'] == r['name']})
        limites = []
        if r['nan_to'] != 'CPL_UNSET':
            limites.append('NaN para {}'.format(numero(r['nan_to'])))
        linhas.append([codigo(r['name']), '{} para {}'.format(r['src'], r['dst']),
                       r['methods'].replace(',', ', '), codigo(r['mask']),
                       codigo(r['fallback']), r['no_value'], preenchimento(r['fill']),
                       ', '.join(limites), r['create'], len(usos)])
    out += md_tabela(['Rota', 'Malhas', 'Métodos', 'Máscara', 'Reserva', 'Sem valor',
                      'Completar', 'Limitar', 'Criar', 'Campos'], linhas)
    out += ['', 'Esquema de todas as rotas: `{}` (trocável no grupo `&nuopc_regrid`).'.format(
        '`, `'.join(sorted({r['scheme'] for r in rotas}))), '',
        '## 6. Malhas', '']
    out += md_tabela(['Malha', 'Componente', 'Tipo', 'Descrição'],
                     [[codigo(m['name']), m['component'], m['grid_type'], m['description']]
                      for m in malhas])
    out += ['', '## 7. Campos', '',
            'Nome longo e nome CF são os atributos `long_name` e `standard_name` que os',
            'gravadores de diagnóstico do mediador e da exportação do MONAN-A escrevem',
            '(`cpl_field_attributes`); campo sem nome longo sai com os atributos padrão.', '']
    out += md_tabela(['Campo', 'Unidade', 'Sinal', 'Descrição', 'Nome longo', 'Nome CF'],
                     [[codigo(c['name']), c['units'], c['sign_conv'], c['description'],
                       c['long_name'], codigo(c['cf_name'])]
                      for c in campos])
    out.append('')
    return '\n'.join(out)


def main():
    saida_utf8()
    args = sys.argv[1:]
    if any(a in ('-h', '--help') for a in args):
        print(__doc__)
        return 0
    confere, raiz, saida = False, os.path.normpath(os.path.join(os.path.dirname(
        os.path.abspath(__file__)), '..', '..')), None
    i = 0
    while i < len(args):
        if args[i] == '-c':
            confere = True
        elif args[i] in ('-s', '-o') and i + 1 < len(args):
            if args[i] == '-s':
                raiz = args[i + 1]
            else:
                saida = args[i + 1]
            i += 1
        else:
            print('ERRO: opção inválida: ' + args[i], file=sys.stderr)
            return 2
        i += 1
    saida = saida or os.path.join(raiz, 'docs', 'acoplamento.md')
    try:
        md = gera(le_mapa(raiz))
    except ErroMapa as e:
        print('ERRO: ' + str(e), file=sys.stderr)
        return 2
    if confere:
        try:
            with open(saida, encoding='utf-8') as f:
                atual = f.read()
        except OSError:
            atual = None
        if atual == md:
            print('{}: em dia com o mapa'.format(saida))
            return 0
        print('{}: DESATUALIZADO; gere de novo com tools/dev/mapa-acoplamento.py'.format(saida))
        return 1
    with open(saida, 'w', encoding='utf-8') as f:
        f.write(md)
    print('{} gerado'.format(saida))
    return 0


if __name__ == '__main__':
    sys.exit(main())
