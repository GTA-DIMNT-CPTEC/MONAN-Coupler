#!/usr/bin/env python3
"""confere-camadas.py: confere que os 'use' de src/ respeitam as camadas.

A arquitetura do acoplador tem camadas: a base e os serviços comuns
(src/shared), o framework de interpolação (src/regrid), a descrição do
acoplamento (src/coupling), os componentes (o mediador e os caps), o driver
e o programa principal. Uma camada só depende das de baixo, e um componente
não depende de outro. A tabela CAMADAS, abaixo, dá a camada e o componente
de cada fonte, pelo caminho; vale a primeira linha que casa.

Três regras, conferidas nos 'use' entre módulos do próprio acoplador (os do
ESMF, do MPAS, do MOM6, do FMS e do MPI ficam de fora):
  1. um fonte não usa módulo de camada de cima;
  2. um componente não usa módulo de outro componente (o cap do MOM6 e o
     DOCN são componentes diferentes, embora no mesmo diretório; o cap
     modelo de src/caps/template conta como um componente);
  3. o framework de interpolação e a descrição do acoplamento não leem as
     variáveis globais de coupler_config (nomes cfg_*): recebem a
     configuração como argumento, e assim podem ser usados e testados sem
     o nuopc.input; tipos, tabelas e funções puras de coupler_config valem.
Um fonte que nenhuma linha da tabela cobre também é acusado.

Uso (na raiz do repositório):
  tools/dev/confere-camadas.py [-s RAIZ]
    -s RAIZ  raiz da árvore a ler (padrão: a deste script)

Código de saída: 0 se nada foi encontrado; 1 caso contrário; 2 erro.
Escrito para o Python 3.6 da Jaci.
"""
import fnmatch
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dependencias  # noqa: E402

# (padrão do caminho a partir de src/, camada, nome da camada, componente)
CAMADAS = [
    ('shared/*',            0, 'base e serviços comuns', ''),
    ('regrid/*',            1, 'interpolação', ''),
    ('coupling/*',          2, 'descrição do acoplamento', ''),
    ('mediator/*',          3, 'componentes', 'mediador'),
    ('caps/atmos/DATM_*',   3, 'componentes', 'DATM'),
    ('caps/atmos/*',        3, 'componentes', 'MONAN-A'),
    ('caps/ocean/DOCN_*',   3, 'componentes', 'DOCN'),
    ('caps/ocean/docn_*',   3, 'componentes', 'DOCN'),
    ('caps/ocean/*',        3, 'componentes', 'MOM6'),
    ('caps/ice/*',          3, 'componentes', 'SIS2'),
    ('caps/template/*',     3, 'componentes', 'cap modelo'),
    ('driver/*',            4, 'driver', ''),
    ('main/*',              5, 'programa principal', ''),
]

# Camadas que recebem a configuração como argumento (regra 3)
SEM_CONFIG_GLOBAL = (1, 2)
MODULO_CONFIG = 'coupler_config_mod'
GLOBAL_CONFIG = re.compile(r'^cfg_\w+$', re.I)
USO_CONFIG = re.compile(r'^\s*use\s*(?:,\s*\w+\s*)?(?:::)?\s*' + MODULO_CONFIG +
                        r'\b\s*(,\s*only\s*:(.*))?$', re.I)


def classifica(caminho):
    """(camada, nome da camada, componente) do fonte, ou None."""
    rel = os.path.relpath(caminho, 'src').replace(os.sep, '/')
    for padrao, camada, nome, comp in CAMADAS:
        if fnmatch.fnmatch(rel, padrao):
            return camada, nome, comp
    return None


def instrucoes(caminho):
    """Instruções do fonte, sem comentários e com as continuações juntas."""
    saida, atual = [], ''
    with io.open(caminho, encoding='utf-8', errors='replace') as f:
        for linha in f:
            codigo = linha.split('!', 1)[0].rstrip()
            if atual:
                codigo = codigo.lstrip()
                if codigo.startswith('&'):
                    codigo = codigo[1:]
            if codigo.endswith('&'):
                atual += codigo[:-1]
                continue
            saida.append(atual + codigo)
            atual = ''
    if atual:
        saida.append(atual)
    return saida


def globais_lidas(caminho):
    """Nomes cfg_* de coupler_config que o fonte usa (ou '*' sem only)."""
    nomes = []
    for inst in instrucoes(caminho):
        m = USO_CONFIG.match(inst)
        if not m:
            continue
        if not m.group(1):
            nomes.append('*')
            continue
        for item in m.group(2).split(','):
            nome = item.split('=>')[-1].strip()
            if GLOBAL_CONFIG.match(nome):
                nomes.append(nome)
    return nomes


def main():
    dependencias.saida_utf8()
    args = sys.argv[1:]
    raiz = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if args[:1] == ['-s'] and len(args) == 2:
        raiz = args[1]
    elif args:
        print(__doc__)
        return 2
    try:
        caminhos = dependencias.fontes_em(raiz, 'src')
        deps, caminho_de = dependencias.grafo(raiz, caminhos)
    except dependencias.ErroDep as erro:
        print('ERRO: {}'.format(erro))
        return 2

    problemas = []
    classe = {}
    for nome in sorted(caminho_de, key=str.lower):
        classe[nome] = classifica(caminho_de[nome])
        if classe[nome] is None:
            problemas.append('{}: fonte fora da tabela CAMADAS'.format(caminho_de[nome]))

    for nome in sorted(caminho_de, key=str.lower):
        if classe[nome] is None:
            continue
        camada, nome_camada, comp = classe[nome]
        for usado in deps[nome]:
            if classe[usado] is None:
                continue
            c_usado, nome_usado, comp_usado = classe[usado]
            if c_usado > camada:
                problemas.append('{}: usa {} ({}), camada de cima de {}'.format(
                    caminho_de[nome], usado, nome_usado, nome_camada))
            elif comp and comp_usado and comp != comp_usado:
                problemas.append('{}: o componente {} usa {}, do componente {}'.format(
                    caminho_de[nome], comp, usado, comp_usado))
        if camada in SEM_CONFIG_GLOBAL:
            lidas = globais_lidas(os.path.join(raiz, caminho_de[nome]))
            if lidas:
                problemas.append('{}: lê variáveis globais de coupler_config ({}); '
                                 'a configuração deve chegar por argumento'.format(
                                     caminho_de[nome], ', '.join(lidas)))

    print('{} fontes, {} linhas na tabela de camadas'.format(len(caminho_de), len(CAMADAS)))
    for p in problemas:
        print('  ' + p)
    if problemas:
        print('{} problema(s)'.format(len(problemas)))
        return 1
    print('camadas respeitadas')
    return 0


if __name__ == '__main__':
    sys.exit(main())
