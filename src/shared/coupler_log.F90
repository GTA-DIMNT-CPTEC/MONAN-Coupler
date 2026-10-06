!> @file coupler_log.F90
!! @brief Registro do acoplador com níveis (aviso, informação, depuração).
!!
!! Toda mensagem do acoplador vai para o log do ESMF (PET*.ESMF_LogFile).
!! Este módulo acrescenta um nível a cada mensagem e decide, pela chave
!! log_level de &nuopc_driver (cfg_log_level), se ela é gravada:
!!
!! | nível pedido | log_warning | log_info | log_debug |
!! |--------------|-------------|----------|-----------|
!! | warning      | grava       | não      | não       |
!! | info (padrão)| grava       | grava    | não       |
!! | debug        | grava       | grava    | grava     |
!!
!! Avisos saem com severidade WARNING no log do ESMF; informação e
!! depuração, com INFO. A mensagem é gravada como "<comp>: <texto>", em que
!! <comp> é uma das marcas COMP_* abaixo, para que se saiba de que
!! componente ela veio.
!!
!! Diagnósticos caros (somas de bits, varreduras de campo) devem ser
!! protegidos por log_debug_enabled(), para que não sejam nem calculados
!! fora do nível de depuração.
!!
!! Exemplo:
!!   call log_info(COMP_MED, 'MediatorAdvance concluido')
!!   if (log_debug_enabled()) call diag_caro(campo)
module coupler_log_mod

  use ESMF,               only: ESMF_LogWrite, ESMF_LOGMSG_INFO, ESMF_LOGMSG_WARNING
  use coupler_config_mod, only: cfg_log_level

  implicit none
  private

  !> Marcas dos componentes, no início de cada mensagem
  character(len=*), parameter, public :: COMP_ATM = 'ATM'
  character(len=*), parameter, public :: COMP_OCN = 'OCN'
  character(len=*), parameter, public :: COMP_ICE = 'ICE'
  character(len=*), parameter, public :: COMP_MED = 'MED'
  character(len=*), parameter, public :: COMP_DRV = 'ESM'

  !> Níveis, do mais restrito ao mais detalhado
  integer, parameter :: LEVEL_WARNING = 1
  integer, parameter :: LEVEL_INFO    = 2
  integer, parameter :: LEVEL_DEBUG   = 3

  public :: log_warning, log_info, log_debug, log_debug_enabled

contains

  !> Nível pedido em cfg_log_level (já validado e em minúsculas pela
  !! leitura do nuopc.input); um valor desconhecido conta como info.
  integer function requested_level()
    select case (trim(cfg_log_level))
    case ('warning')
      requested_level = LEVEL_WARNING
    case ('debug')
      requested_level = LEVEL_DEBUG
    case default
      requested_level = LEVEL_INFO
    end select
  end function requested_level

  !> Aviso: gravado em qualquer nível, com severidade WARNING.
  !! @param[in] comp  marca do componente (COMP_*)
  !! @param[in] msg   texto da mensagem
  subroutine log_warning(comp, msg)
    character(len=*), intent(in) :: comp
    character(len=*), intent(in) :: msg
    call ESMF_LogWrite(comp//': '//msg, ESMF_LOGMSG_WARNING)
  end subroutine log_warning

  !> Informação: gravada nos níveis info e debug.
  !! @param[in] comp  marca do componente (COMP_*)
  !! @param[in] msg   texto da mensagem
  subroutine log_info(comp, msg)
    character(len=*), intent(in) :: comp
    character(len=*), intent(in) :: msg
    if (requested_level() >= LEVEL_INFO) &
      call ESMF_LogWrite(comp//': '//msg, ESMF_LOGMSG_INFO)
  end subroutine log_info

  !> Depuração: gravada só no nível debug.
  !! @param[in] comp  marca do componente (COMP_*)
  !! @param[in] msg   texto da mensagem
  subroutine log_debug(comp, msg)
    character(len=*), intent(in) :: comp
    character(len=*), intent(in) :: msg
    if (log_debug_enabled()) &
      call ESMF_LogWrite(comp//': '//msg, ESMF_LOGMSG_INFO)
  end subroutine log_debug

  !> Verdadeiro se log_level='debug'; protege diagnósticos caros.
  logical function log_debug_enabled()
    log_debug_enabled = requested_level() >= LEVEL_DEBUG
  end function log_debug_enabled

end module coupler_log_mod
