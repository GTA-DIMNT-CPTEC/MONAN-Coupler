!> @file diag_bitsum.F90
!! @brief Soma de verificação exata, por PET, de campos reais (diagnóstico de
!! reprodutibilidade bit a bit).
!!
! Checksum EXATO de campos reais, POR PET, para diagnostico de
! reprodutibilidade bit a bit.
!
! POR QUE. Os diagnosticos FIX-DIAG-ICESRC-01/-02 imprimem 17 algarismos,
! precisao suficiente, mas so' o PET 0 e' recolhido. A bateria de 22/09/2026
! achou diferencas de exatamente 1 ulp no Si_ifrac recebido pelo MPAS
! (1573 pontos, r1 x r4, 01h) fora da fatia do PET 0.
!
! COMO. Cada valor e' lido como inteiro de 64 bits (transfer), separado em
! duas metades de 32 bits, e as metades sao somadas em inteiro. Soma de
! inteiros e' exata e nao depende da ordem: o resultado so' muda se algum
! bit de algum ponto mudar.
!
! POR QUE NAO HA REDUCAO ENTRE PETs. No MediatorAdvance, os PETs sem pedaco
! da grade atmosferica retornam cedo (bloco localDeCount_med == 0). Uma
! chamada coletiva depois desse ponto travaria o job. Aqui cada PET grava a
! sua parte no proprio log (logs/PETnn.esmApp.log), e o mede-taxa-repro.sh
! junta as linhas de todos os PETs. Bonus: a diferenca aparece localizada
! por PET, isto e', por regiao do dominio.
!
! LIMITES.
!  - Seguro ate' 2**31 pontos por pedaco (cada metade < 2**32).
!  - Nao detecta dois pontos que TROCAM de valor entre si. Entre execucoes
!    com a mesma decomposicao isso nao ocorre na pratica.
!
! SAIDA. Uma linha por chamada, no log de cada PET que chega ao ponto:
!   FIX-DIAG-BITSUM-01: <rotulo> n=<pontos> hi=<soma alta> lo=<soma baixa>
! com " ERRO=<k>" no fim se algum pedaco local nao pode ser lido.
module diag_bitsum_mod

  use, intrinsic :: iso_fortran_env, only: int64, real64
  use ESMF

  implicit none
  private

  public :: diag_bitsum_log

  interface diag_bitsum_log
    module procedure bitsum_log_1d
    module procedure bitsum_log_2d
    module procedure bitsum_log_field
  end interface diag_bitsum_log

  character(len=*), parameter :: PREFIXO = 'FIX-DIAG-BITSUM-01'

contains

  ! --------------------------------------------------------------------------
  !> Acumula contagem e as duas somas de 32 bits de um trecho contiguo.
  pure subroutine acumula(x, n, s_hi, s_lo)
    real(real64),   intent(in)    :: x(:)
    integer(int64), intent(inout) :: n, s_hi, s_lo

    integer(int64), parameter :: MASK32 = int(z'FFFFFFFF', int64)
    integer(int64) :: b
    integer        :: i

    do i = 1, size(x)
      b    = transfer(x(i), b)
      s_lo = s_lo + iand(b, MASK32)
      s_hi = s_hi + iand(shiftr(b, 32), MASK32)
    end do
    n = n + size(x, kind=int64)
  end subroutine acumula

  ! --------------------------------------------------------------------------
  pure subroutine acumula_2d(x, n, s_hi, s_lo)
    real(real64),   intent(in)    :: x(:,:)
    integer(int64), intent(inout) :: n, s_hi, s_lo
    integer :: j
    do j = 1, size(x, 2)
      call acumula(x(:, j), n, s_hi, s_lo)
    end do
  end subroutine acumula_2d

  ! --------------------------------------------------------------------------
  !> Grava a linha no log deste PET.
  subroutine grava(rotulo, n, s_hi, s_lo, n_err)
    character(len=*), intent(in) :: rotulo
    integer(int64),   intent(in) :: n, s_hi, s_lo
    integer,          intent(in) :: n_err

    character(len=512) :: msg

    if (n_err == 0) then
      write(msg, '(a,": ",a," n=",i0," hi=",i0," lo=",i0)') &
            PREFIXO, trim(rotulo), n, s_hi, s_lo
    else
      write(msg, '(a,": ",a," n=",i0," hi=",i0," lo=",i0," ERRO=",i0)') &
            PREFIXO, trim(rotulo), n, s_hi, s_lo, n_err
    end if
    call ESMF_LogWrite(trim(msg), ESMF_LOGMSG_INFO)
  end subroutine grava

  ! --------------------------------------------------------------------------
  subroutine bitsum_log_1d(rotulo, x, rc)
    character(len=*), intent(in)  :: rotulo
    real(real64),     intent(in)  :: x(:)
    integer,          intent(out) :: rc
    integer(int64) :: n, s_hi, s_lo
    n = 0 ; s_hi = 0 ; s_lo = 0
    call acumula(x, n, s_hi, s_lo)
    call grava(rotulo, n, s_hi, s_lo, 0)
    rc = ESMF_SUCCESS
  end subroutine bitsum_log_1d

  ! --------------------------------------------------------------------------
  subroutine bitsum_log_2d(rotulo, x, rc)
    character(len=*), intent(in)  :: rotulo
    real(real64),     intent(in)  :: x(:,:)
    integer,          intent(out) :: rc
    integer(int64) :: n, s_hi, s_lo
    n = 0 ; s_hi = 0 ; s_lo = 0
    call acumula_2d(x, n, s_hi, s_lo)
    call grava(rotulo, n, s_hi, s_lo, 0)
    rc = ESMF_SUCCESS
  end subroutine bitsum_log_2d

  ! --------------------------------------------------------------------------
  !> ESMF_Field real(8) de posto 1 ou 2, com qualquer numero de pedacos
  !! locais (localDeCount pode ser 0, 1 ou mais). Soma a regiao exclusiva.
  subroutine bitsum_log_field(rotulo, field, rc)
    character(len=*), intent(in)  :: rotulo
    type(ESMF_Field), intent(in)  :: field
    integer,          intent(out) :: rc

    integer                  :: rank, ldec, lde, rc_loc, n_err
    type(ESMF_TypeKind_Flag) :: tk
    real(real64), pointer    :: p1(:), p2(:,:)
    integer(int64)           :: n, s_hi, s_lo

    n = 0 ; s_hi = 0 ; s_lo = 0 ; n_err = 0
    rank = 0 ; ldec = 0

    call ESMF_FieldGet(field, rank=rank, typekind=tk, localDeCount=ldec, rc=rc_loc)
    if (rc_loc /= ESMF_SUCCESS) then
      n_err = n_err + 1
      ldec  = 0
    else if (tk /= ESMF_TYPEKIND_R8 .or. (rank /= 1 .and. rank /= 2)) then
      n_err = n_err + 1
      ldec  = 0
    end if

    do lde = 0, ldec - 1
      if (rank == 1) then
        nullify(p1)
        call ESMF_FieldGet(field, localDe=lde, farrayPtr=p1, rc=rc_loc)
        if (rc_loc == ESMF_SUCCESS .and. associated(p1)) then
          call acumula(p1, n, s_hi, s_lo)
        else
          n_err = n_err + 1
        end if
      else
        nullify(p2)
        call ESMF_FieldGet(field, localDe=lde, farrayPtr=p2, rc=rc_loc)
        if (rc_loc == ESMF_SUCCESS .and. associated(p2)) then
          call acumula_2d(p2, n, s_hi, s_lo)
        else
          n_err = n_err + 1
        end if
      end if
    end do

    call grava(rotulo, n, s_hi, s_lo, n_err)
    rc = ESMF_SUCCESS
  end subroutine bitsum_log_field

end module diag_bitsum_mod
