#!/usr/bin/env python3
"""Gera os arquivos sintéticos do teste do oceano de dados (DOCN).

Escreve, no diretório dado, os textos CDL de três arquivos numa grade de
72 x 36 pontos e 10 instantes diários, e os converte em NetCDF com ncgen:

  sst.nc   variável sst  (°C), com valores abaixo de 0 e acima de 29
  ice.nc   variável icec (%), com valores abaixo de 0 e acima de 100,
           para exercitar a conversão de porcentagem e o limite a [0, 1]
  cur.nc   variáveis uo e vo (m/s), com pontos de preenchimento (-999) e
           valores de 12 m/s, que o DOCN descarta como preenchimento

Os valores saem de fórmulas fechadas, sem números aleatórios, para que o
teste seja o mesmo em qualquer máquina. Só usa a biblioteca padrão do
Python; exige o ncgen (pacote netcdf-bin).

Uso: tests/docn/gera-dados-docn.py DIRETORIO
"""
import math
import os
import subprocess
import sys

NT, NY, NX = 10, 36, 72


def campo(nome_var, func):
    """Valores de uma variável (tempo, lat, lon) em texto CDL."""
    vals = []
    for t in range(NT):
        for j in range(NY):
            for i in range(NX):
                vals.append('%.10f' % func(t, j, i))
    linhas = [', '.join(vals[k:k + 12]) for k in range(0, len(vals), 12)]
    return ' %s =\n  %s ;\n' % (nome_var, ',\n  '.join(linhas))


def sst(t, j, i):
    lat = -87.5 + 5.0 * j
    lon = 2.5 + 5.0 * i
    return (28.5 * math.cos(math.radians(lat)) - 1.2
            + 0.8 * math.sin(math.radians(2.0 * lon) + 0.3 * t))


def gelo(t, j, i):
    lat = -87.5 + 5.0 * j
    if abs(lat) >= 80.0:
        return 110.0
    if abs(lat) >= 60.0:
        return 100.0 * (abs(lat) - 60.0) / 20.0 + 5.0 * math.sin(0.5 * t + 0.2 * i)
    return -5.0 if (i + t) % 7 == 0 else 0.0


def corrente_u(t, j, i):
    if j < 3 or j > NY - 4:
        return -999.0                     # sem dado perto dos polos
    if (i, j) in ((10, 18), (30, 20), (50, 12), (60, 25), (5, 15)) and t == 2:
        return 12.0                        # valor de preenchimento a descartar
    return 1.3 * math.sin(math.radians(5.0 * i) + 0.4 * t) * math.cos(math.radians(-87.5 + 5.0 * j))


def corrente_v(t, j, i):
    if j < 3 or j > NY - 4:
        return -999.0
    return 0.9 * math.cos(math.radians(3.0 * i) - 0.2 * t) * math.sin(math.radians(-87.5 + 5.0 * j))


def grava(diretorio, nome, variaveis):
    cabecalho = ('netcdf %s {\ndimensions:\n\ttime = UNLIMITED ;\n\tlat = %d ;\n\tlon = %d ;\n'
                 'variables:\n' % (nome, NY, NX))
    cabecalho += ''.join('\tdouble %s(time, lat, lon) ;\n' % v for v, _ in variaveis)
    corpo = 'data:\n' + ''.join(campo(v, f) for v, f in variaveis) + '}\n'
    cdl = os.path.join(diretorio, nome + '.cdl')
    with open(cdl, 'w') as arq:
        arq.write(cabecalho + corpo)
    subprocess.run(['ncgen', '-o', os.path.join(diretorio, nome + '.nc'), cdl], check=True)
    os.remove(cdl)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    diretorio = sys.argv[1]
    os.makedirs(diretorio, exist_ok=True)
    grava(diretorio, 'sst', [('sst', sst)])
    grava(diretorio, 'ice', [('icec', gelo)])
    grava(diretorio, 'cur', [('uo', corrente_u), ('vo', corrente_v)])


if __name__ == '__main__':
    main()
