#!/usr/bin/env python3
"""Gera os supergrids sintéticos do teste de mom6_supergrid_mod.

Escreve, no diretório dado, três arquivos no formato do ocean_hgrid.nc do
FRE-NCtools e os converte em NetCDF com ncgen:

  hgrid.nc     supergrid de 21 x 15 pontos (grade T de 10 x 7), com
               longitudes de -329,6 a 93,3 graus, que exercitam a passagem
               para [0, 360), e linhas e colunas inclinadas, para que um
               erro de índice (par/ímpar, i/j trocados) apareça nos valores
  impar.nc     dimensões nx = 21 e ny = 15 ímpares, que geram o aviso de
               mom6_supergrid_dims
  sem_xy.nc    as mesmas dimensões de hgrid.nc, mas com as variáveis
               chamadas lon e lat, o que faz a leitura falhar

Os valores saem de fórmulas fechadas e são gravados com 10 casas decimais,
para que o teste seja o mesmo em qualquer máquina. Só usa a biblioteca
padrão do Python; exige o ncgen (pacote netcdf-bin).

Uso: tests/supergrid/gera-supergrid.py DIRETORIO
"""
import os
import subprocess
import sys

NXP, NYP = 21, 15


def lon(i, j):
    return -329.6 + 18.0 * i + 62.9 * j / 14.0


def lat(i, j):
    return -83.0 + 0.18 * i + 170.0 * j / 14.0


def valores(func):
    vals = ['%.10f' % func(i, j) for j in range(NYP) for i in range(NXP)]
    return ', '.join(vals)


def grava(diretorio, nome, nx, ny, var_x, var_y):
    cdl = ('netcdf %s {\ndimensions: nyp = %d ; nxp = %d ; nx = %d ; ny = %d ;\n'
           'variables: double %s(nyp, nxp) ; double %s(nyp, nxp) ;\n'
           'data:\n %s = %s ;\n %s = %s ;\n}\n'
           % (nome, NYP, NXP, nx, ny, var_x, var_y,
              var_x, valores(lon), var_y, valores(lat)))
    arq_cdl = os.path.join(diretorio, nome + '.cdl')
    with open(arq_cdl, 'w') as arq:
        arq.write(cdl)
    subprocess.run(['ncgen', '-o', os.path.join(diretorio, nome + '.nc'), arq_cdl], check=True)
    os.remove(arq_cdl)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    diretorio = sys.argv[1]
    os.makedirs(diretorio, exist_ok=True)
    grava(diretorio, 'hgrid', NXP - 1, NYP - 1, 'x', 'y')
    grava(diretorio, 'impar', NXP, NYP, 'x', 'y')
    grava(diretorio, 'sem_xy', NXP - 1, NYP - 1, 'lon', 'lat')


if __name__ == '__main__':
    main()
