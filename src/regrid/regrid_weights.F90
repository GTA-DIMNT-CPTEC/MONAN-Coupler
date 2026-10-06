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
  use coupler_log_mod, only : COMP_REGRID, log_error, log_info
  use regrid_base_mod, only : regridder_t

  implicit none
  private

  public :: weights_file_regridder_t
  public :: new_weights

  type, extends(regridder_t) :: weights_file_regridder_t
    type(ESMF_RouteHandle) :: rh
  contains
    procedure :: setup   => weights_setup
    procedure :: execute => weights_execute
    procedure :: release => weights_release
  end type weights_file_regridder_t

contains

  !> @brief Construtor usado pela lista de esquemas (regrid_schemes.F90).
  subroutine new_weights(r)
    class(regridder_t), allocatable, intent(out) :: r
    allocate(weights_file_regridder_t :: r)
  end subroutine new_weights

  !> @brief setup do esquema 'weights_file': lê os pesos de spec%weights_file e
  !! cria o route handle (ESMF_FieldSMMStore); arquivo ausente é erro.
  subroutine weights_setup(this, src, dst, rc)
    class(weights_file_regridder_t), intent(inout) :: this
    type(ESMF_Field),                intent(inout) :: src, dst
    integer,                         intent(out)   :: rc

    integer :: srcTermProcessing
    logical :: exists

    inquire(file=trim(this%spec%weights_file), exist=exists)
    if (.not. exists) then
      call log_error(COMP_REGRID, 'rota '//trim(this%label)//': arquivo de pesos ' // &
        'inexistente: '//trim(this%spec%weights_file))
      rc = ESMF_FAILURE
      return
    end if

    srcTermProcessing = 0
    call ESMF_FieldSMMStore(src, dst, trim(this%spec%weights_file), this%rh, &
      srcTermProcessing=srcTermProcessing, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    this%method_used = 'weights_file'
    this%ready = .true.
    call log_info(COMP_REGRID, 'rota '//trim(this%label)//' pronta, pesos de '// &
      trim(this%spec%weights_file))
  end subroutine weights_setup

  !> @brief execute do esquema 'weights_file': produto matriz esparsa
  !! (ESMF_FieldSMM) na ordem do índice de origem.
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

  !> @brief release do esquema 'weights_file': libera o route handle, se criado.
  subroutine weights_release(this, rc)
    class(weights_file_regridder_t), intent(inout) :: this
    integer,                         intent(out)   :: rc

    rc = ESMF_SUCCESS
    if (this%ready) call ESMF_FieldSMMRelease(this%rh, rc=rc)
    this%ready = .false.
  end subroutine weights_release

end module regrid_weights_mod
