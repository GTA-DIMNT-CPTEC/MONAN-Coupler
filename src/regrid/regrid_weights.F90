!> @file regrid_weights.F90
!! @brief Esquema 'weights_file': interpolação por pesos lidos de arquivo.
!!
!! Os pesos são calculados fora do acoplador, por qualquer ferramenta que
!! grave o formato SCRIP/ESMF (variáveis row, col e S de dimensão n_s):
!! ESMF_RegridWeightGen, o MPASSIT, scripts próprios. Isso permite usar
!! métodos que o ESMF não calcula durante a execução e reaproveitar pesos
!! caros de calcular. Os índices seguem a numeração sequencial global das
!! grades de origem e destino.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.

module regrid_weights_mod

  use ESMF
  use regrid_base_mod, only : regridder_t

  implicit none
  private

  public :: weights_file_regridder_t

  type, extends(regridder_t) :: weights_file_regridder_t
    type(ESMF_RouteHandle) :: rh
  contains
    procedure :: setup   => weights_setup
    procedure :: execute => weights_execute
    procedure :: release => weights_release
  end type weights_file_regridder_t

contains

  subroutine weights_setup(this, src, dst, rc)
    class(weights_file_regridder_t), intent(inout) :: this
    type(ESMF_Field),                intent(inout) :: src, dst
    integer,                         intent(out)   :: rc

    integer :: srcTermProcessing
    logical :: exists

    inquire(file=trim(this%spec%weights_file), exist=exists)
    if (.not. exists) then
      call ESMF_LogWrite('regrid: rota '//trim(this%label)//': arquivo de pesos ' // &
        'inexistente: '//trim(this%spec%weights_file), ESMF_LOGMSG_ERROR)
      rc = ESMF_FAILURE
      return
    end if

    srcTermProcessing = 0
    call ESMF_FieldSMMStore(src, dst, trim(this%spec%weights_file), this%rh, &
      srcTermProcessing=srcTermProcessing, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    this%method_used = 'weights_file'
    this%ready = .true.
    call ESMF_LogWrite('regrid: rota '//trim(this%label)//' pronta, pesos de '// &
      trim(this%spec%weights_file), ESMF_LOGMSG_INFO)
  end subroutine weights_setup

  subroutine weights_execute(this, src, dst, zero_total, rc)
    class(weights_file_regridder_t), intent(inout) :: this
    type(ESMF_Field),                intent(inout) :: src, dst
    logical,                         intent(in)    :: zero_total
    integer,                         intent(out)   :: rc

    if (zero_total) then
      call ESMF_FieldSMM(src, dst, this%rh, termorderflag=ESMF_TERMORDER_SRCSEQ, &
        zeroregion=ESMF_REGION_TOTAL, rc=rc)
    else
      call ESMF_FieldSMM(src, dst, this%rh, termorderflag=ESMF_TERMORDER_SRCSEQ, &
        zeroregion=ESMF_REGION_SELECT, rc=rc)
    end if
  end subroutine weights_execute

  subroutine weights_release(this, rc)
    class(weights_file_regridder_t), intent(inout) :: this
    integer,                         intent(out)   :: rc

    rc = ESMF_SUCCESS
    if (this%ready) call ESMF_FieldSMMRelease(this%rh, rc=rc)
    this%ready = .false.
  end subroutine weights_release

end module regrid_weights_mod
