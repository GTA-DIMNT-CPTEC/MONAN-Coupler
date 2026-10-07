#!/usr/bin/env python3
"""confere-exportacao.py: todo campo que o mediador exporta é preenchido.

A conferência do mapa (cpl_check) compara o que os componentes anunciam com o
mapa, mas não verifica se o mediador de fato preenche cada campo que exporta.
Um campo que o mediador exporta sem ter de onde tirar o valor seria
entregue com o valor inicial, sem erro.

A exportação (med_export) percorre os campos que chegam a MED@ocn_med pela
rota 'atm2ocn' no mapa e tira cada um do registro de campos internos
(tabela MED_FIELDS, em src/mediator/med_cap_types.F90); os demais são
preenchidos explicitamente, pelo nome.

Este script lê o mapa de acoplamento (EXCHANGES, pelo leitor de
tools/dev/mapa-acoplamento.py), a tabela MED_FIELDS e os fontes de
src/mediator/, e confere, nos dois sentidos, que:
  - todo campo que sai do mediador por conector, em alguma configuração,
    chega a MED@ocn_med pela rota 'atm2ocn' e está em MED_FIELDS, ou é
    preenchido explicitamente em src/mediator/ por
    RegridOrCopy(<campo interno>, exportState, "<nome>", ...) ou por
    ESMF_StateGet(exportState, itemName="<nome>", ...);
  - todo campo coberto assim sai do mediador por conector no mapa;
  - todo campo que chega a MED@ocn_med pela rota 'atm2ocn' está em
    MED_FIELDS (sem isso, a exportação para com erro).

Uso (na raiz do repositório):
  tools/dev/confere-exportacao.py [-s RAIZ]

Código de saída: 0 se os dois conjuntos coincidem; 1 se não; 2 erro de
leitura. Escrito para o Python 3.6 da Jaci.
"""
import glob
import importlib.util
import io
import os
import re
import sys

PREENCHE = re.compile(r'\bRegridOrCopy\s*\(\s*[^,]+,\s*exportState\s*,\s*["\'](\w+)["\']', re.I)
PEGA = re.compile(r'\bESMF_StateGet\s*\(\s*exportState\s*,\s*itemName\s*=\s*["\'](\w+)["\']', re.I)
TABELA = re.compile(r"\bmed_field_spec_t\s*\(\s*'(\w+)'", re.I)


def saida_utf8():
    """Imprime em UTF-8 mesmo com o locale C (Python 3.6 da Jaci)."""
    if sys.stdout.encoding is None or sys.stdout.encoding.lower() != 'utf-8':
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')


def leitor_do_mapa(raiz):
    """Módulo tools/dev/mapa-acoplamento.py (o nome tem hífen)."""
    caminho = os.path.join(raiz, 'tools', 'dev', 'mapa-acoplamento.py')
    spec = importlib.util.spec_from_file_location('mapa_acoplamento', caminho)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def preenchidos(raiz):
    """Nomes preenchidos por RegridOrCopy no exportState, com o arquivo."""
    nomes = {}
    for arq in sorted(glob.glob(os.path.join(raiz, 'src', 'mediator', '*.F90'))):
        with io.open(arq, encoding='utf-8') as f:
            texto = f.read()
        # junta as continuações e tira os comentários de linha inteira
        linhas = [l for l in texto.split('\n') if not l.lstrip().startswith('!')]
        texto = re.sub(r'&\s*\n\s*&?', ' ', '\n'.join(linhas))
        for padrao in (PREENCHE, PEGA):
            for m in padrao.finditer(texto):
                nomes.setdefault(m.group(1), os.path.relpath(arq, raiz))
    return nomes


def campos_internos(raiz):
    """Nomes de acoplamento da tabela MED_FIELDS (med_cap_types.F90)."""
    with io.open(os.path.join(raiz, 'src', 'mediator', 'med_cap_types.F90'), encoding='utf-8') as f:
        return set(TABELA.findall(f.read()))


def main():
    saida_utf8()
    args = sys.argv[1:]
    if any(a in ('-h', '--help') for a in args):
        print(__doc__)
        return 0
    raiz = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
    if len(args) == 2 and args[0] == '-s':
        raiz = args[1]
    elif args:
        print('ERRO: opção inválida: ' + ' '.join(args), file=sys.stderr)
        return 2
    mapa = leitor_do_mapa(raiz)
    try:
        trocas = mapa.le_mapa(raiz)['EXCHANGES']
    except mapa.ErroMapa as e:
        print('ERRO: ' + str(e), file=sys.stderr)
        return 2
    exportados = sorted({x['field'] for x in trocas
                         if x['via'] == 'conector' and mapa.comp(x['src']) == 'MED'})
    internos = campos_internos(raiz)
    pela_rota = {x['field'] for x in trocas
                 if x['via'] == 'atm2ocn' and x['dst'] == 'MED@ocn_med'}
    feitos = dict(preenchidos(raiz))
    for n in sorted(pela_rota & internos):
        feitos.setdefault(n, 'laço de exportação (rota atm2ocn, MED_FIELDS)')
    sem_registro = sorted(pela_rota - internos)
    sem_preenchimento = [n for n in exportados if n not in feitos]
    fora_do_mapa = sorted(n for n in feitos if n not in exportados)
    for n in sem_registro:
        print('SEM REGISTRO       {}: chega a MED@ocn_med pela rota atm2ocn, mas não está '
              'em MED_FIELDS (med_cap_types.F90)'.format(n))
    for n in sem_preenchimento:
        print('SEM PREENCHIMENTO  {}: sai do mediador por conector no mapa, mas não é '
              'exportado pelo laço nem preenchido pelo nome em src/mediator/'.format(n))
    for n in fora_do_mapa:
        print('FORA DO MAPA       {}: preenchido por {}, mas não sai do mediador por '
              'conector no mapa'.format(n, feitos[n]))
    if sem_registro or sem_preenchimento or fora_do_mapa:
        return 1
    print('{} campos exportados pelo mediador, todos preenchidos ({} pelo laço da rota '
          'atm2ocn)'.format(len(exportados), len(pela_rota & internos)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
