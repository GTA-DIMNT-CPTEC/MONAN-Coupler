!> @file test_supergrid.F90
!! @brief Teste de regressão da leitura do supergrid do MOM6 (mom6_supergrid_mod).
!!
!! Chama as três rotinas públicas do módulo sobre os arquivos sintéticos de
!! tests/supergrid/gera-supergrid.py:
!!   mom6_supergrid_dims     em hgrid.nc, impar.nc (aviso de dimensão ímpar)
!!                           e num arquivo que não existe
!!   mom6_supergrid_tcoords  numa porção local (3:8, 2:6) de hgrid.nc, com e
!!   mom6_supergrid_corners  sem marca, em sem_xy.nc (sem as variáveis x e
!!                           y) e num arquivo que não existe
!! A marca das mensagens é passada por posição, porque o nome do argumento
!! mudou na R-FASE13-12 (tag para comp) e o programa serve às duas versões
!! comparadas. Pede log_level='debug', para que o diagnóstico da leitura dos
!! centros entre no log.
!! Grava em saida.bin, na ordem das chamadas, os códigos de retorno, as
!! dimensões e as coordenadas lidas. As mensagens vão para o log do ESMF
!! (log.txt).
!!
!! Usado por tests/supergrid/compara-supergrid.bash; não entra no executável.
program test_supergrid
  use ESMF
  use mom6_supergrid_mod
  use coupler_config_mod, only : config_read
  implicit none
  real(ESMF_KIND_R8), pointer :: cx(:,:), cy(:,:)
  integer :: rc, u, ni, nj

  call ESMF_Initialize(logkindflag=ESMF_LOGKIND_SINGLE, defaultLogFilename="log.txt", rc=rc)
  open(newunit=u, file='debug.nml', status='replace', action='write')
  write(u,'(A)') '&nuopc_driver'
  write(u,'(A)') "  log_level = 'debug'"
  write(u,'(A)') '/'
  close(u)
  call config_read(rc, 'debug.nml')
  open(newunit=u, file='saida.bin', form='unformatted', access='stream', status='replace')

  call mom6_supergrid_dims('hgrid.nc', ni, nj, rc, 'D');  write(u) rc, ni, nj
  call mom6_supergrid_dims('impar.nc', ni, nj, rc, 'D');  write(u) rc, ni, nj
  call mom6_supergrid_dims('naoexiste.nc', ni, nj, rc);       write(u) rc

  allocate(cx(3:8,2:6), cy(3:8,2:6))
  cx = 0; cy = 0
  call mom6_supergrid_tcoords('hgrid.nc', cx, cy, rc, 'T');  write(u) rc, cx, cy
  cx = 0; cy = 0
  call mom6_supergrid_corners('hgrid.nc', cx, cy, rc, 'C');  write(u) rc, cx, cy
  cx = 0; cy = 0
  call mom6_supergrid_tcoords('hgrid.nc', cx, cy, rc);           write(u) rc, cx, cy
  call mom6_supergrid_tcoords('sem_xy.nc', cx, cy, rc, 'T'); write(u) rc
  call mom6_supergrid_corners('sem_xy.nc', cx, cy, rc, 'C'); write(u) rc
  call mom6_supergrid_tcoords('naoexiste.nc', cx, cy, rc);       write(u) rc
  call mom6_supergrid_corners('naoexiste.nc', cx, cy, rc);       write(u) rc

  close(u)
  call ESMF_Finalize()
end program test_supergrid
