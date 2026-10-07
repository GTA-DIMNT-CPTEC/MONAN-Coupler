!> @file time_utils.F90
!! @brief Conversão de tempo do ESMF para o FMS (usado pelos caps do MOM6 e do SIS2).
!!
!! Compilado com as opções do MOM6 (real de 8 bytes), pois depende do FMS.
!!
!! INPE / CGCT / DIMNT, GT Acoplamento de Modelos.
module time_utils_mod

  use time_manager_mod, only : time_type, set_time, set_date
  use ESMF,             only : ESMF_Time, ESMF_TimeGet, ESMF_TimeInterval, &
                               ESMF_TimeIntervalGet
  use coupler_utils_mod, only : ChkErr

  implicit none
  private

  public :: esmf2fms_time

  !> Converte data (ESMF_Time) ou intervalo (ESMF_TimeInterval) para o tipo do FMS.
  interface esmf2fms_time
    module procedure esmf2fms_date
    module procedure esmf2fms_interval
  end interface esmf2fms_time

contains

  !> @brief Instante ESMF no time_type do FMS (set_date, ao segundo).
  function esmf2fms_date(time) result(fms_time)
    type(ESMF_Time), intent(in) :: time
    type(time_type)             :: fms_time
    integer :: yy, mm, dd, h, m, s, rc

    call ESMF_TimeGet(time, yy=yy, mm=mm, dd=dd, h=h, m=m, s=s, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fms_time = set_date(yy, mm, dd, h, m, s)
  end function esmf2fms_date

  !> @brief Intervalo ESMF no time_type do FMS (set_time, em segundos inteiros).
  function esmf2fms_interval(timestep) result(fms_time)
    type(ESMF_TimeInterval), intent(in) :: timestep
    type(time_type)                     :: fms_time
    integer :: s, rc

    call ESMF_TimeIntervalGet(timestep, s=s, rc=rc)
    if (ChkErr(rc, __LINE__, __FILE__)) return
    fms_time = set_time(s, 0)
  end function esmf2fms_interval

end module time_utils_mod
