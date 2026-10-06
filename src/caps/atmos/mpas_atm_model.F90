!> @file mpas_atm_model.F90
!! @brief Interface com o modelo atmosférico MPAS-A 8.3 / MONAN-A 2.0.
!!
!! Interface MONAN-A 2.0: init/run/final + buffers de acoplamento.
!!
!! As etapas ficam em módulos próprios:
!!   mpas_atm_setup.F90   etapas da inicialização (domínio, streams, ponteiros,
!!                        buffers e vetores de contorno)
!!   mpas_atm_fluxes.F90  fluxos instantâneos de superfície a cada passo
!!
!! A sequência de inicialização reproduz a de mpas_subdriver.F, inclusive
!! add_stream_attributes (rotina atm_add_stream_attributes, cópia fiel do
!! upstream, chamada no passo 11a de mpas_atm_init): sem ela, os arquivos
!! diag, history e restart saem só com o atributo file_id.
!! Com -DMPAS_EXTERNAL_ESMF_LIB, mpas_timekeeping.F usa 'use ESMF' (externo).
!! mpas_advance_stop_time controla o relógio INTERNO do MONAN-A (atm_state%%domain%%clock),
!! independente do relógio ESMF do driver. Ambos são necessários.
!!
!! Sequência de inicialização do MONAN-A (confirmada via probe no Jaci):
!!   phase1(external_comm) → atm_setup_core → atm_setup_domain → setup_log →
!!   setup_namelist → phase2 → streamInfo → define_packages → setup_packages →
!!   setup_decompositions → setup_clock → bootstrap_phase1 → stream_mgr_init →
!!   add_stream_attributes → setup_immutable_streams → xml_stream_parser →
!!   bootstrap_phase2 → core_init → extração de ponteiros zero-copy.
!!
!! Assinaturas confirmadas (probe_block_type.bash, Jaci):
!!   core_init     : function(domain, startTimeStamp) result(ierr)  [integer]
!!   core_run      : function(domain) result(ierr)                   [integer]
!!   core_finalize : function(domain) result(ierr)                   [integer]

module mpas_atm_model_mod

  ! Tipos públicos em módulo isolado (sem dependência ESMF externa)
  use mpas_atm_types_mod, only : MPAS_RKIND,             &
                                  mpas_atm_public_type,   &
                                  mpas_atm_state_type,    &
                                  atm_ocean_boundary_type

  use mpas_kind_types,    only : StrKIND
  ! field1DReal (de mpas_field_types.inc, incluido em
  ! mpas_derived_types) e mpas_dmpar_exch_halo_field sao necessarios para
  ! propagar aos halos os campos de contorno injetados pelo acoplador.
  use mpas_dmpar,         only : mpas_dmpar_exch_halo_field
  use mpas_derived_types, only : field1DReal
  use mpas_derived_types, only : mpas_pool_type, MPAS_LOG_CRIT

  use mpas_timekeeping,   only : mpas_advance_stop_time

  use mpas_pool_routines, only : mpas_pool_get_array,        &
                                  mpas_pool_get_subpool,      &
                                  mpas_pool_get_config,       &
                                  mpas_pool_get_field

  ! mpas_log_write confirmado (probe mpas_log.F linha 480)
  use mpas_log,           only : mpas_log_write, mpas_log_info

  use coupler_config_mod,  only : cfg_use_datm,&
                                    cfg_use_docn

  ! Etapas da inicialização e fluxos instantâneos
  use mpas_atm_setup_mod,  only : setup_mpas_domain, setup_mpas_streams,  &
                                   bind_mesh_fields, bind_diag_fields,     &
                                   setup_wind_fallback, init_flux_buffers, &
                                   init_boundary_arrays
  use mpas_atm_fluxes_mod, only : compute_instantaneous_fluxes

  implicit none
  private

  ! O estado do modelo (domínio MPAS, ponteiros para os campos dos pools,
  ! acumulados do passo anterior e buffers de fluxos instantâneos) fica em
  ! mpas_atm_state_type (mpas_atm_types.F90), guardado pelo cap e recebido
  ! como argumento pelas rotinas deste módulo e de mpas_atm_setup_mod e
  ! mpas_atm_fluxes_mod.

  public :: mpas_atm_init
  public :: mpas_atm_run
  public :: mpas_atm_final
  public :: mpas_atm_init_sfc

contains

  ! ============================================================================
  !> @brief Inicializa o MONAN-A 2.0.
  !!
  !! Sequência baseada no probe e em mpas_subdriver.F linhas 202/257:
  !!
  !!   1. mpas_framework_init_phase1(dminfo, external_comm=mpi_comm)
  !!      Inicializa dmpar (MPI wrapper) com o comunicador da VM ESMF.
  !!
  !!   2. atm_setup_core(domain%core)
  !!      Registra os procedure pointers core_init/core_run/core_finalize.
  !!      (Deve ser chamado entre phase1 e phase2 — confirmado pelo probe seção 8)
  !!
  !!   3. mpas_framework_init_phase2(domain, calendar=...)
  !!      Lê namelist.atmosphere, decompõe malha, aloca blocklist e pools,
  !!      inicializa clock MPAS-A com config_start_time do namelist.
  !!
  !!   4. Obtém startTimeStamp do clock via mpas_get_clock_time
  !!
  !!   5. ierr = core_init(domain, startTimeStamp)
  !!      Lê init.nc, configura física e integrador. Retorna inteiro.
  !!
  !!   6. Extrai nCells do subpool 'mesh' via blocklist%structs
  !!
  !!   7. Liga ponteiros zero-copy via subpools structs%mesh, structs%diag
  !!
  !! Etapas: setup_mpas_domain (passos 1 a 9), setup_mpas_streams (10 a
  !! 12), core_init, bind_mesh_fields, bind_diag_fields, setup_wind_fallback,
  !! init_flux_buffers e init_boundary_arrays.
  !!
  !! @param mpi_comm  Comunicador MPI inteiro (extraído pelo cap da VM ESMF).
  ! ============================================================================
  subroutine mpas_atm_init(atm_public, atm_state, atm_bnd, &
                            dt_seconds, config_dir, mpi_comm, rc)

    type(mpas_atm_public_type),    intent(inout) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,          intent(in)  :: dt_seconds
    character(len=*), intent(in)  :: config_dir
    integer,          intent(in)  :: mpi_comm
    integer,          intent(out) :: rc

    integer          :: n, nSolve, ierr
    ! StrKIND (=512), nao 64.
    !
    ! Esta variavel e' passada a core_init, cujo dummy e' character(len=*),
    ! logo o comprimento do ATUAL se propaga intacto. Dentro de atm_core_init
    ! ela chega a mpas_get_time, cujo dummy dateTimeString e' declarado com
    ! StrKIND. Com -fcheck=bounds no FFLAGS_OPT de producao, o gfortran
    ! verifica comprimento de caractere em tempo de execucao e aborta:
    !   "Actual string length is shorter than the declared one for dummy
    !    argument 'datetimestring' (64/512)"
    ! Os 64 PETs da atmosfera terminam em Error termination dentro do
    ! mpas_atm_init, antes do primeiro ModelAdvance.
    !
    ! Sem -fcheck=bounds isto nao aborta, mas tambem nao e' inocuo: o
    ! mpas_get_time escreveria ate 512 caracteres sobre um buffer de 64.
    ! Nao ha custo em usar StrKIND: a variavel e' local e usada com trim.
    character(len=StrKIND) :: startTimeStamp
    character(len=256) :: msg

    rc = 0
    atm_state%mpi_comm   = mpi_comm
    atm_state%dt_seconds = dt_seconds
    atm_state%config_dir = trim(config_dir)

    ! Passos 1 a 9: dominio, framework, namelist, pacotes e relogio
    call setup_mpas_domain(atm_state, rc)
    if (rc /= 0) return

    ! Passos 10 a 12: malha, stream manager e streams
    call setup_mpas_streams(atm_state, rc)
    if (rc /= 0) return

    ! ------------------------------------------------------------------
    ! 13. Inicializa o núcleo atmosférico (core_init).
    ! ------------------------------------------------------------------
    startTimeStamp = ''
    ierr = atm_state%domain%core%core_init(atm_state%domain, startTimeStamp)
    if (ierr /= 0) then
      write(msg,'(A,I0)') 'ERRO mpas_atm_init: core_init retornou ierr=', ierr
      call mpas_log_write(trim(msg), messageType=MPAS_LOG_CRIT)
      rc = ierr; return
    end if
    call mpas_log_write('mpas_atm_init: core_init concluido')

    call bind_mesh_fields(atm_public, atm_state, n, nSolve, rc)
    if (rc /= 0) return

    call bind_diag_fields(atm_public, atm_state)
    call setup_wind_fallback(atm_public, atm_state, n)
    call init_flux_buffers(atm_public, atm_state, n)
    call init_boundary_arrays(atm_bnd, n)

    atm_state%initialized = .true.
    ! nSolve = células próprias (sem halos); n = nCells total (com halos).
    ! netcdf_init_coords deve usar nSolve → soma global = 40962.
    write(msg,'(A,I0,A,I0,A)') &
      'mpas_atm_init: OK (', nSolve, ' celulas proprias / ', n, ' com halos — SMIOL ativo)'
    call mpas_log_write(trim(msg))

  end subroutine mpas_atm_init

  ! ============================================================================
  subroutine mpas_atm_init_sfc(atm_public, atm_state, rc)
    type(mpas_atm_public_type), intent(inout) :: atm_public
    type(mpas_atm_state_type),  intent(inout) :: atm_state
    integer,                    intent(out)   :: rc
    rc = 0
    if (.not. atm_state%initialized) then
      write(*,'(A)') 'ERRO mpas_atm_init_sfc: modelo nao inicializado'
      rc = 1; return
    end if
    ! core_init já preencheu o subpool diag com dados do init.nc via SMIOL.
    ! Os ponteiros zero-copy em atm_public já contêm dados válidos.
    call mpas_log_write('mpas_atm_init_sfc: campos t=0 prontos (zero-copy)')
  end subroutine mpas_atm_init_sfc

  ! ============================================================================
  !> @brief Avança o MONAN-A por um intervalo de acoplamento.
  !!
  !! Probe seção 4 / mpas_atm_core.F linha 605:
  !!   function atm_core_run(domain) result(ierr)
  !! core_run é INTEGER FUNCTION — retorna código de erro MPAS.
  !!
  !! I/O (history/restart) via SMIOL/smiolf ocorre automaticamente
  !! conforme alarmes definidos em streams.atmosphere.
  ! ============================================================================
  subroutine mpas_atm_run(atm_public, atm_state, atm_bnd, dt_coupling, rc)

    type(mpas_atm_public_type),    intent(inout) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(in)    :: atm_bnd
    integer,                       intent(in)    :: dt_coupling
    integer,                       intent(out)   :: rc
    type(mpas_pool_type), pointer   :: diag_physicsPool => null()
    type(mpas_pool_type), pointer   :: sfcInputPool => null()
    real(MPAS_RKIND), dimension(:), pointer :: xland_field  => null()
    real(MPAS_RKIND), dimension(:), pointer :: skintemp_field  => null()
    real(MPAS_RKIND), dimension(:), pointer :: sst_field  => null()
    real(MPAS_RKIND), dimension(:), pointer :: ice_field  => null()
    real(MPAS_RKIND), dimension(:), pointer :: zorl_field => null()
    ! sfc_albedo real (Sf_albedo do
    ! mediador) -> physica do MONAN-A, substituindo a climatologia mensal
    ! (config_sfc_albedo=.false. necessario no namelist p/ nao ser
    ! sobrescrito pelo NOAH LSM).
    real(MPAS_RKIND), dimension(:), pointer :: albedo_field => null()
    integer :: n, ierr
    ! limite do laco de injecao. nCellsSolve vive em
    ! atm_public (mpas_atm_types.F90), nao em atm_state.
    integer :: nSolve_inj
    character(len=256) :: msg
    ! na runSeq "OCN -> MED" acontece ANTES de "OCN" avancar
    ! (lag de 1 passo, ver driver/esm.F90). Na 1a chamada de acoplamento de
    ! um COLD START o MOM6 ainda nao rodou nenhum passo dinamico: atm_bnd%sst
    ! chega com o fallback do mediador (bootstrap/T_FILL), nao com dado real.
    ! Em RESTART, porem, o MOM6 ja parte de um estado real (arquivo de
    ! restart) - a atm_bnd%sst da 1a chamada ja e valida, entao NAO se deve
    ! pular a atribuicao nesse caso. Usamos config_do_restart (namelist do
    ! MONAN-A) pra distinguir os dois casos.
    logical, pointer :: config_do_restart => null()
    logical :: is_cold_start

    rc = 0
    n  = atm_state%nCells

    ! a injecao escreve SO nas celulas proprias. Se
    ! nCellsSolve nao tiver sido preenchido em mpas_atm_init, cair para nCells
    ! e' o comportamento antigo (escreve nos halos); isso e' um defeito, nao um
    ! default aceitavel, entao registra em nivel de erro em vez de seguir calado.
    nSolve_inj = atm_public%nCellsSolve
    if (nSolve_inj <= 0 .or. nSolve_inj > n) then
      write(msg,'(A,I0,A,I0,A)') 'mpas_atm_run: B-INJECT-HALO-01 ERRO - ' // &
        'nCellsSolve=', nSolve_inj, ' invalido (nCells=', n, &
        '); injetando ate nCells, halos ficarao inconsistentes'
      write(*,'(A)') trim(msg)
      call mpas_log_write(trim(msg))
      nSolve_inj = n
    end if

    if (.not. atm_state%initialized .or. .not. associated(atm_state%domain)) then
      write(*,'(A)') 'ERRO mpas_atm_run: modelo nao inicializado'
      rc = 1; return
    end if

    ! ------------------------------------------------------------------
    ! Injeta condições de fronteira no subpool 'sfc_input'
    ! Probe seção 7 / mpas_atm_core.F linha 553:
    ! Nomes Registry.xml: sst, iceAreaCell, znt
    ! ------------------------------------------------------------------
    call mpas_pool_get_subpool(atm_state%domain%blocklist%structs, 'sfc_input', sfcInputPool)
    call mpas_pool_get_subpool(atm_state%domain%blocklist%structs, 'diag_physics', diag_physicsPool)

    call mpas_pool_get_config(atm_state%domain%configs, 'config_do_restart', config_do_restart)
    if (associated(config_do_restart)) then
      is_cold_start = .not. config_do_restart
    else
      ! config nao encontrado - assume cold start (mais seguro: no pior caso
      ! so atrasa 1 passo de acoplamento em vez de aplicar um fallback ruim)
      is_cold_start = .true.
    end if

    if (associated(sfcInputPool)) then
      call mpas_pool_get_array(sfcInputPool,'skintemp',skintemp_field)
      call mpas_pool_get_array(sfcInputPool,'xland',xland_field )

      call mpas_pool_get_array(sfcInputPool, 'sst',         sst_field)
      call mpas_pool_get_array(sfcInputPool, 'xice',        ice_field)
      call mpas_pool_get_array(sfcInputPool, 'znt',         zorl_field)
      call mpas_pool_get_array(diag_physicsPool,'z0'        ,zorl_field)
      ! sfc_albedo vive em diag_physics (confirmado no Registry.xml
      ! real do MONAN-Model — mpas_atmphys_driver_lsm.F le/escreve de la,
      ! nao de sfc_input).
      call mpas_pool_get_array(diag_physicsPool, 'sfc_albedo', albedo_field)

      if (associated(xland_field)  .and. allocated(atm_bnd%sst))then
         if (atm_state%first_coupling_call .and. is_cold_start) then
            call mpas_log_write( &
              'mpas_atm_run: B-COLDSTART-01 - 1a chamada de acoplamento em ' // &
              'COLD START, OCN ainda nao avancou nenhum passo - mantendo ' // &
              'sst/skintemp/ice/zorl da condicao inicial do MONAN-A (nao ' // &
              'aplicando atm_bnd)')
         end if
         if(.not. cfg_use_docn .and. .not. cfg_use_datm) then
           ! so entre se nao utilizar dados de sst preescritos 
            ! o laco vai ate nCellsSolve (celulas PROPRIAS),
            ! nao ate nCells (que inclui os halos). O motivo esta em
            ! exchange_surface_halos.
            call inject_ocean_cells(nSolve_inj,                              &
              atm_state%first_coupling_call .and. is_cold_start, atm_bnd,    &
              xland_field, sst_field, skintemp_field, ice_field, zorl_field, &
              albedo_field)
            ! Propaga aos halos os campos injetados (ver exchange_surface_halos).
            if (.not. (atm_state%first_coupling_call .and. is_cold_start)) then
              call exchange_surface_halos(sfcInputPool, diag_physicsPool)
            end if
         endif
      end if
      atm_state%first_coupling_call = .false.
    else
      write(*,'(A)') 'AVISO mpas_atm_run: subpool sfc_input nao encontrado em structs'
    end if

    call mpas_log_write('mpas_atm_run: sfc_input injetado')

    ! mpas_advance_stop_time: avança o stop time do relógio MPAS interno
    ! por exatamente dt_coupling antes de core_run.
    ! Avança o stop time do relógio interno do MONAN-A (atm_state%domain%clock),
    ! independente do relógio ESMF do driver. Controla quantos passos
    ! internos (dt_atm) core_run integra por chamada a mpas_atm_run.
    call mpas_advance_stop_time(atm_state%domain%clock, dt_coupling)

    ! ------------------------------------------------------------------
    ! Ativa mpas_log_info → domain%logInfo antes de core_run.
    ! mpas_subdriver.F linha 414:
    ! Sem isso, mpas_log_write dentro de core_run derreferencia null → SIGSEGV.
    ! ------------------------------------------------------------------
    if (associated(atm_state%domain%logInfo)) mpas_log_info => atm_state%domain%logInfo

    ! ------------------------------------------------------------------
    ! Avança o núcleo: integra passos internos de dt_atm, escreve I/O
    ! via SMIOL conforme streams.atmosphere.
    ! core_run é INTEGER FUNCTION.
    ! ------------------------------------------------------------------
    ierr = atm_state%domain%core%core_run(atm_state%domain)
    if (ierr /= 0) then
      write(msg,'(A,I0)') 'ERRO mpas_atm_run: core_run retornou ierr=', ierr
      write(*,'(A)') trim(msg)
      call mpas_log_write(trim(msg))
      rc = ierr; return
    end if

    call mpas_log_write('mpas_atm_run: core_run concluido')

    ! ------------------------------------------------------------------
    ! Pós-processamento dos campos acumulados e stress superficial.
    !
    ! Os arrays do pool (atm_state%pool_*) foram atualizados por core_run.
    ! Aqui calculam-se os valores instantâneos para o intervalo de
    ! acoplamento e armazenamos nos buffers g_*_inst / atm_state%taux_buf / atm_state%tauy_buf
    ! que são apontados por atm_public%swdn_sfc, lwdn_sfc, prec_total,
    ! taux_sfc, tauy_sfc (configurado em mpas_atm_init).
    !
    ! IMPORTANTE: usar real(dt_coupling, MPAS_RKIND) para evitar perda de
    ! precisão quando MPAS_RKIND = kind(1.0) (single precision).
    ! ------------------------------------------------------------------
    call compute_instantaneous_fluxes(dt_coupling, n, atm_public, atm_state, atm_bnd)

    atm_state%running = .true.

    nullify(sfcInputPool, sst_field, ice_field, zorl_field)
  end subroutine mpas_atm_run

  ! ============================================================================
  !> @brief Copia os campos de contorno do oceano (atm_bnd) para as células
  !! próprias de oceano (xland > 1.5) dos pools do MONAN-A.
  !!
  !! Percorre só as nSolve primeiras células (as próprias); os halos são
  !! trocados depois por exchange_surface_halos. Com skip_first (primeira
  !! chamada de um cold start) nada é copiado.
  ! ============================================================================
  subroutine inject_ocean_cells(nSolve_inj, skip_first, atm_bnd,          &
                                xland_field, sst_field, skintemp_field,  &
                                ice_field, zorl_field, albedo_field)
    integer,                                intent(in)    :: nSolve_inj
    logical,                                intent(in)    :: skip_first
    type(atm_ocean_boundary_type),          intent(in)    :: atm_bnd
    real(MPAS_RKIND), dimension(:), pointer, intent(in)   :: xland_field
    real(MPAS_RKIND), dimension(:), pointer, intent(in)   :: sst_field
    real(MPAS_RKIND), dimension(:), pointer, intent(in)   :: skintemp_field
    real(MPAS_RKIND), dimension(:), pointer, intent(in)   :: ice_field
    real(MPAS_RKIND), dimension(:), pointer, intent(in)   :: zorl_field
    real(MPAS_RKIND), dimension(:), pointer, intent(in)   :: albedo_field
    integer :: iCell

            DO iCell =1, nSolve_inj
               if( xland_field(iCell) .gt. 1.5) then
                  if (.not. skip_first) then
                     if (associated(sst_field)  .and. allocated(atm_bnd%sst)) then
                        sst_field(iCell)  = atm_bnd%sst(iCell)
                        skintemp_field(iCell) = atm_bnd%sst(iCell)
                     end if
                     if (associated(ice_field)  .and. allocated(atm_bnd%ice_fraction)) then
                        ice_field(iCell)  = atm_bnd%ice_fraction(iCell)
                     end if
                     if (associated(zorl_field) .and. allocated(atm_bnd%zorl))  then
                          zorl_field(iCell) = atm_bnd%zorl(iCell)
                     endif
                     ! mesma guarda de
                     ! xland>1.5 (oceano) e atm_state%first_coupling_call/cold-start
                     ! ja usada para sst/ice/zorl acima.
                     if (associated(albedo_field) .and. allocated(atm_bnd%alb)) then
                       albedo_field(iCell) = atm_bnd%alb(iCell)
                     endif
                  end if
               endif
            end do
  end subroutine inject_ocean_cells

  ! ============================================================================
  !> @brief Troca de halo dos campos de contorno injetados pelo acoplador.
  !!
  !! Propaga aos halos os campos de
  !! contorno que acabaram de ser injetados.
  !!
  !! O PROBLEMA. Antes desta correcao o laco de injecao percorria
  !! 1..nCells, que INCLUI as celulas de halo, e escrevia nelas
  !! valores de atm_bnd. Nao havia troca de halo em seguida (a busca
  !! por exch_halo em todo o src/caps nao retornava nada). Cada PET
  !! ficava com uma copia de halo de sst/skintemp/xice/znt/sfc_albedo
  !! inconsistente com o PET dono da celula, e o core_run integrava
  !! sobre contorno inconsistente. No MPAS-A autonomo isso nao
  !! ocorre, porque sst e xice chegam pelo stream manager, que faz a
  !! troca de halo; a injecao do acoplador contornava esse caminho.
  !!
  !! A EVIDENCIA. Numa medicao com dt_coupling=43200, ou
  !! seja, duas janelas de acoplamento, das quais apenas a segunda
  !! injeta (a primeira e' pulada pela guarda):
  !! quatro execucoes identicas, seis pares comparados, SEIS
  !! divergentes, TODOS a partir do registro 73 do reprodiag, que e'
  !! exatamente 12:00, o instante da injecao. Os 72 registros
  !! anteriores, doze horas de integracao, sao bit a bit identicos.
  !! Com zero injecoes (dt_coupling=86400) foram seis pares sem
  !! nenhuma diferenca. Uma unica injecao basta para quebrar a
  !! reprodutibilidade, e a quebra aparece no passo em que ela
  !! ocorre, nao antes.
  !!
  !! O CONSERTO. Escrever apenas nas celulas proprias (nCellsSolve,
  !! ver inject_ocean_cells) e chamar a troca de halo, que e' a mesma
  !! rotina do framework que o stream manager usa. Assim a copia de
  !! halo de cada PET passa a ser, por construcao, igual ao valor do
  !! dono.
  !!
  !! CUSTO. Uma troca de halo por campo por janela de acoplamento,
  !! sobre campos 1D de nCells. Desprezivel ao lado de um passo de
  !! fisica, e paga uma vez por dt_coupling, nao por dt_atm.
  !!
  !! LIMITE CONHECIDO. Isto NAO trata a duplicacao de celulas na
  !! malha ESMF da atmosfera (max_dup=2, avg_dup=1.35 no diagnostico
  !! do mpas_cell_binning), em que a mesma celula fisica recebe
  !! contribuicao do regrid em mais de um PET. Se a divergencia
  !! persistir, esse e' o alvo seguinte, e o conserto e' no cap
  !! (mpas_cap_MONAN.F90 e mpas_cell_binning.F90).
  ! ============================================================================
  subroutine exchange_surface_halos(sfcInputPool, diag_physicsPool)
    type(mpas_pool_type), pointer :: sfcInputPool
    type(mpas_pool_type), pointer :: diag_physicsPool
    type (field1DReal), pointer :: fld_halo => null()
    integer :: i_halo
    character(len=32), parameter :: sfcinput_fields(3) = &
    [ character(len=32) :: 'sst', 'xice', 'skintemp' ]
    character(len=32), parameter :: diagphys_fields(2) = &
    [ character(len=32) :: 'z0', 'sfc_albedo' ]

    do i_halo = 1, size(sfcinput_fields)
      nullify(fld_halo)
      call mpas_pool_get_field(sfcInputPool, &
        trim(sfcinput_fields(i_halo)), fld_halo)
      if (associated(fld_halo)) then
        call mpas_dmpar_exch_halo_field(fld_halo)
      else
        call mpas_log_write('mpas_atm_run: B-INJECT-HALO-01 AVISO - '// &
          'campo '//trim(sfcinput_fields(i_halo))// &
          ' nao encontrado em sfc_input; halo NAO trocado')
      end if
    end do

    do i_halo = 1, size(diagphys_fields)
      nullify(fld_halo)
      call mpas_pool_get_field(diag_physicsPool, &
        trim(diagphys_fields(i_halo)), fld_halo)
      if (associated(fld_halo)) then
        call mpas_dmpar_exch_halo_field(fld_halo)
      else
        call mpas_log_write('mpas_atm_run: B-INJECT-HALO-01 AVISO - '// &
          'campo '//trim(diagphys_fields(i_halo))// &
          ' nao encontrado em diag_physics; halo NAO trocado')
      end if
    end do

    call mpas_log_write('mpas_atm_run: B-INJECT-HALO-01 - halos '// &
      'dos campos de contorno injetados trocados')
  end subroutine exchange_surface_halos

  ! ============================================================================
  !> @brief Finaliza o MONAN-A.
  !!
  !! Probe seção 5 / mpas_atm_core.F linha 1027:
  !!   function atm_core_finalize(domain) result(ierr)
  !! Probe mpas_framework.F linha 165:
  !!   subroutine mpas_framework_finalize(dminfo, domain, io_system)
  !!   io_system é OPCIONAL (mpas_subdriver linha 474 omite).
  !!
  !! Sequência obrigatória com SMIOL:
  !!   nullify(ponteiros zero-copy) → core_finalize → mpas_framework_finalize
  !!   → deallocate(domain)
  ! ============================================================================
  subroutine mpas_atm_final(atm_public, atm_state, atm_bnd, rc)

    type(mpas_atm_public_type),    intent(inout) :: atm_public
    type(mpas_atm_state_type), target, intent(inout) :: atm_state
    type(atm_ocean_boundary_type), intent(inout) :: atm_bnd
    integer,                       intent(out)   :: rc


    rc = 0

    if (.not. atm_state%initialized) then
      call mpas_log_write('mpas_atm_final: nada a finalizar')
      return
    end if

    if (associated(atm_state%domain)) then

      ! IMPORTANTE: core_finalize e mpas_framework_finalize sao OMITIDAS.
      !
      ! core_finalize do MPAS-A (compilado com -DMPAS_EXTERNAL_ESMF_LIB) destroi
      ! internamente objetos ESMF_Time e ESMF_Calendar que o framework NUOPC
      ! ainda precisa para cleanup dos conectores (RouteHandles) apos ModelFinalize.
      ! Chamar core_finalize dentro de ESMF_GridCompFinalize -> SIGSEGV.
      !
      ! Os streams SMIOL ja foram fechados automaticamente no ultimo core_run
      ! (streams.atmosphere define alarm de output/restart). O restart final
      ! pode ser obtido configurando output_alarm no streams.atmosphere.
      !
      ! mpas_framework_finalize tambem omitida pelos mesmos motivos.
      ! A memoria e liberada pelo SO no termino do processo MPI.
      !
      ! Apenas nulifica ponteiros para evitar dangling references:
      nullify(atm_public%latCell,    atm_public%lonCell,  atm_public%areaCell)
      nullify(atm_public%t2m,        atm_public%u10,      atm_public%v10)
      nullify(atm_public%pslv)
      nullify(atm_public%lhflx,      atm_public%shflx)
      nullify(atm_public%swdn_sfc,   atm_public%lwdn_sfc, atm_public%prec_total)
      nullify(atm_public%taux_sfc,   atm_public%tauy_sfc)
      nullify(atm_public%q2m,        atm_public%prec_rain, atm_public%prec_snow)
      nullify(atm_state%pool_acswdnb, atm_state%pool_aclwdnb, atm_state%pool_rainnc, atm_state%pool_rainc)
      nullify(atm_state%pool_snownc,  atm_state%pool_q2,       atm_state%pool_ust)
      atm_state%domain => null()

      write(*,'(A)') 'mpas_atm_final: ponteiros nulificados (ESMF preservado)'
    end if

    ! 4. Desaloca apenas arrays de propriedade deste módulo
    if (allocated(atm_bnd%sst))           deallocate(atm_bnd%sst)
    if (allocated(atm_bnd%ice_fraction))  deallocate(atm_bnd%ice_fraction)
    if (allocated(atm_bnd%uocn))          deallocate(atm_bnd%uocn)
    if (allocated(atm_bnd%vocn))          deallocate(atm_bnd%vocn)
    if (allocated(atm_bnd%zorl))          deallocate(atm_bnd%zorl)
    if (allocated(atm_bnd%alb))           deallocate(atm_bnd%alb)
    if (allocated(atm_bnd%omask))         deallocate(atm_bnd%omask)
    ! Buffers de saída computados (propriedade deste módulo)
    if (allocated(atm_state%prev_acswdnb)) deallocate(atm_state%prev_acswdnb)
    if (allocated(atm_state%prev_aclwdnb)) deallocate(atm_state%prev_aclwdnb)
    if (allocated(atm_state%prev_precip))  deallocate(atm_state%prev_precip)
    if (allocated(atm_state%prev_snow))    deallocate(atm_state%prev_snow)
    if (allocated(atm_state%swdn_inst))    deallocate(atm_state%swdn_inst)
    if (allocated(atm_state%lwdn_inst))    deallocate(atm_state%lwdn_inst)
    if (allocated(atm_state%prec_inst))    deallocate(atm_state%prec_inst)
    if (allocated(atm_state%taux_buf))     deallocate(atm_state%taux_buf)
    if (allocated(atm_state%tauy_buf))     deallocate(atm_state%tauy_buf)
    if (allocated(atm_state%q2m_buf))      deallocate(atm_state%q2m_buf)
    if (allocated(atm_state%prec_rain_buf))deallocate(atm_state%prec_rain_buf)
    if (allocated(atm_state%prec_snow_buf))deallocate(atm_state%prec_snow_buf)
    ! deallocate buffers de fallback de vento (se alocados)
    if (allocated(atm_state%u10_buf))      deallocate(atm_state%u10_buf)
    if (allocated(atm_state%v10_buf))      deallocate(atm_state%v10_buf)
    nullify(atm_state%pool_uZonal, atm_state%pool_vMerid, atm_state%pool_zgrid)

    atm_state%initialized = .false.
    atm_state%running     = .false.

  end subroutine mpas_atm_final

end module mpas_atm_model_mod
