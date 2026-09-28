# Changelog — Coupler-Install

Histórico de versões do instalador do sistema acoplado
**MONAN-A 2.0 × MOM6+SIS2** (NUOPC-ESMF 8.9.1).
INPE / CGCT / DIMNT — GT Acoplamento de Modelos.

O formato segue, de modo simplificado, *Keep a Changelog*; as datas são
aproximadas (iterações de desenvolvimento, Jun a Jul 2026).

## [Não lançado]

- **Gravador `monan_export_*.nc` dividido em etapas; último `BLOCK` retirado (R-FASE8-03).** Terceira etapa da fase 8 e primeira das revisões de rotinas longas. Nenhum cálculo muda.
  - `export_write_netcdf` (`mpas_cap_netcdf.F90`, 148 linhas de código) misturava três assuntos: a coordenação do passo, a definição do arquivo NetCDF e a interpolação dos campos. Fica só com a coordenação (inventário do `exportState`, chamadas às etapas, fechamento do arquivo), e a criação e a definição do arquivo (atributos globais, lat, lon, time, uma variável por campo, eixos) vão, sem mudança, para a nova rotina `define_export_file`, que só o PET 0 chama. As mensagens de erro usam o mesmo prefixo, recebido por argumento.
  - `write_export_fields` passa a alocar os seus próprios buffers (`sendBuf` em todos os PETs, `grid_2d` no PET 0) e perde os argumentos que só serviam de variável de trabalho (`sendBuf`, `grid_2d`, `ncstat`, `varid`); `nLocal` e `mpiComm` passam a `intent(in)` e `fldnames` a vetor comum com `intent(in)`.
  - A leitura de reserva de um campo do `exportState` (posto 1 ou 2) vira a rotina `read_export_field_local`. Com isso sai o `BLOCK` que declarava o vetor auxiliar `flat`, registrado na R-FASE7-03: não resta nenhum `BLOCK` em `src/`, como pede a convenção do README.
  - Código morto retirado: `allCounts`, `displs` e `recvBuf` eram alocados e copiados a cada passo, mas nunca lidos (a interpolação usa só as coordenadas locais guardadas por `netcdf_init_coords`). O comentário da etapa foi ajustado a isso.
  - Conferências locais: `confere-tudo.bash -i HEAD` com compilação, avisos, literais (273, iguais), regrid, física bulk, grade atmosférica e testes com valor esperado sem falhas; gravadores iguais byte a byte, inclusive os `monan_export_*.nc`, cujo caso de teste passa pelo caminho de reserva com campos de posto 2 (o antigo `BLOCK`). As diferenças de instruções são só declarações, cabeçalhos e chamadas das rotinas novas, os argumentos retirados e o código morto acima.
  - Indicadores: rotinas de 294 para 296; rotinas com mais de 100 linhas de código de 10 para 9; `mpas_cap_netcdf.F90` passa a ser o maior arquivo (1 440 linhas).

- **Modelo atmosférico dividido em inicialização, passo e fluxos (R-FASE8-02).** Segunda etapa da fase 8. Nenhuma instrução muda: as rotinas mudaram de arquivo inteiras, com os comentários que as precedem, na mesma ordem.
  - `mpas_atm_model.F90` passa de 1 589 para 605 linhas e fica com os pontos de entrada chamados pelo cap (`mpas_atm_init`, `mpas_atm_init_sfc`, `mpas_atm_run`, `mpas_atm_final`) e com a troca de halos do passo (`exchange_surface_halos`).
  - `mpas_atm_setup.F90` (novo, módulo `mpas_atm_setup_mod`) recebe as onze etapas da inicialização: `setup_mpas_domain`, `setup_mpas_streams` (com `mesh_filename_for_bootstrap`, `parse_streams_xml` e `atm_add_stream_attributes`), `bind_mesh_fields`, `bind_diag_fields` (com `warn_if_null`), `setup_wind_fallback`, `init_flux_buffers` e `init_boundary_arrays`. São públicas só as sete que `mpas_atm_init` chama.
  - `mpas_atm_fluxes.F90` (novo, módulo `mpas_atm_fluxes_mod`) recebe `compute_instantaneous_fluxes` e as duas constantes que só ela usa (`RHO_AIR_SFC` e `VMIN`, com os mesmos valores).
  - O cabeçalho de `mpas_atm_model.F90` fica só com os nomes que as rotinas restantes usam; cada módulo novo importa só os seus.
  - `Makefile` e `tools/dev/compila-local.bash` com os dois fontes novos; `docs/conferencias-locais.md` os cita entre os fontes que compilam aqui com as interfaces mínimas do MPAS.
  - Conferências locais: `confere-tudo.bash -i HEAD` com compilação, avisos (nenhum nos fontes novos), literais (182, iguais no total), regrid, gravadores, física bulk, grade atmosférica e testes com valor esperado sem falhas. As 32 diferenças de instruções são só de estrutura de módulo (`module`, `use`, `public`, `private`, `implicit none`, `contains`). Nenhum teste local executa estes fontes; a conferência deles é a rodada na Jaci.
  - Indicadores: arquivos com mais de 1 000 linhas de 7 para 6; maior arquivo de 1 589 para 1 404 linhas (`mom_cap_MONAN.F90`).
  - Registrado no roteiro: ainda passam de 1 200 linhas `mom_cap_MONAN.F90`, `mpas_cap_netcdf.F90`, `sis_cap_MONAN.F90` e `mpas_cap_methods.F90`, que a fase 8 não previa dividir.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase8-02-validada`).

- **Mediador dividido em módulos por assunto (R-FASE8-01).** Primeira etapa da fase 8. Nenhuma instrução muda: as rotinas mudaram de arquivo inteiras, com os comentários que as precedem, na mesma ordem.
  - `MED_cap.F90` passa de 3 379 para 1 001 linhas e fica com o ciclo de vida NUOPC: `SetServices`, as fases de inicialização (com as etapas de `InitializeDataComplete` que esperam e publicam a SST) e `MediatorAdvance`. As demais 38 rotinas vão para seis módulos novos em `src/mediator/`:

    | Módulo | Assunto | Rotinas | Públicas |
    | --- | --- | --- | --- |
    | `med_init` | grades ATM e OCN, verificação dos cantos, campos dos componentes e internos, rotas de interpolação | 8 | `create_atm_grid`, `create_ocn_grid`, `realize_component_fields`, `create_internal_fields`, `idc_create_routes` |
    | `med_flux` | forçante atmosférica (MPAS ou DATM), recolhimento na grade ATM, fluxos nativos do MONAN-A, zeragem dos fluxos | 7 | `get_atm_forcing`, `gather_atm_forcing`, `local_atm_bounds`, `apply_native_fluxes`, `zero_med_fluxes` |
    | `med_ocean` | SST, máscara de oceano, correntes e fração de gelo do OISST na grade ATM | 6 | `update_ocean_fields_on_atm_grid`, `regrid_ocean_currents`, `update_ice_fraction_from_docn` |
    | `med_ice` | gelo do SIS2 na grade ATM (a rotina principal e as suas oito etapas) | 9 | `update_ice_fields_on_atm_grid` |
    | `med_export` | exportação para os componentes, zeragem sobre terra, carimbo de tempo | 6 | `export_to_components`, `stamp_export_fields` |
    | `med_diag` | resumo da forçante e somas de bits de `Si_ifrac` no log | 2 | `log_atm_forcing_summary`, `log_ifrac_export_bitsum` |

  - As dependências seguem uma ordem só, sem ciclos: `med_diag` e `med_ice` não usam nenhum módulo novo; `med_ocean` usa `med_ice`; `med_init` usa `med_ocean`; `med_flux` usa `med_diag`; `MED_cap` usa todos. Cada módulo tem `private` padrão, lista só as rotinas que outros usam e importa só os nomes de que precisa. O cabeçalho de `MED_cap.F90` perde os nomes que não usava mais (constantes da física bulk, `use mpi`, `use netcdf`, entre outros).
  - `Makefile` e `tools/dev/compila-local.bash` com os seis fontes novos e as dependências entre eles. `README.md` e `docs/ferramentas.md` apontam os arquivos novos.
  - Ferramentas, para etapas que mudam código de arquivo:
    - `confere-literais.py` soma os literais de todos os arquivos conferidos; se só mudaram de arquivo, cada um mostra quantos saíram e entraram e o total decide.
    - `confere-instrucoes.py` aceita vários arquivos e compara a soma (arquivo novo conta como vazio na referência); `confere-tudo.bash -i` passa a usar essa soma.
    - `compila-local.bash -a`: um fonte da lista ausente na versão compilada não conta como falha. Os testes de comparação (`gravadores`, `bulk`, `grade`) e a conferência de avisos usam essa opção para a versão de referência, que não tem os fontes novos.
  - Conferências locais: `confere-tudo.bash -i HEAD` com compilação, avisos (nenhum nos fontes novos), literais (433, iguais no total), regrid, gravadores, física bulk, grade atmosférica e testes com valor esperado sem falhas. As 73 diferenças de instruções são só de estrutura de módulo (`module`, `use`, `public`, `private`, `implicit none`, `contains`), conferidas uma a uma; nenhuma instrução executável mudou.
  - Indicadores: maior arquivo de 3 381 para 1 589 linhas (`mpas_atm_model.F90`, próxima etapa); rotinas continuam 294.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase8-01-validada`).

- **Marcas de primeira vez e contadores no estado interno (R-FASE7-06).** Última etapa da fase 7. Nenhum cálculo muda.
  - Oito variáveis que guardavam valor entre chamadas passam para o estado interno do componente a que pertencem, com os mesmos valores iniciais e alteradas nos mesmos pontos:

    | Antes | Onde | Agora |
    | --- | --- | --- |
    | `n_gate_tries` (local com `save`) | `idc_wait_for_sst`, `MED_cap.F90` | `is%run%n_gate_tries` |
    | `raw_sst_diag_done` (local com `save`) | `MediatorAdvance`, `MED_cap.F90` | `is%run%raw_sst_diag_done` |
    | `first_call_diag` (local com `save`) | `log_atm_forcing_summary`, `MED_cap.F90` | `is%run%first_forcing_summary`, passado por `gather_atm_forcing` |
    | `med_ifrac_init_done` (de módulo) | `MED_cap.F90` | `is%run%ifrac_init_done` |
    | `first_write_diag` (de módulo) | `med_cap_netcdf.F90` | `is%run%first_import_write`, passado a `gather_field_global` |
    | `first_coupling_call` (local com `save`) | `mpas_atm_run`, `mpas_atm_model.F90` | `atm_state%first_coupling_call` |
    | `si_ifrac_mem` e `si_ifrac_mem_valid` (de módulo) | `mom_cap_MONAN.F90` | `is%ifrac_mem%field` e `is%ifrac_mem%valid` (novo tipo `si_ifrac_memory_t`), passados a `set_si_ifrac_from_file` e `compute_si_ifrac_proxy` |
    | `logged_once` (local com `save`) | `CheckImportTolerant`, `sis_cap_MONAN.F90` | `check_import_logged` no estado interno do cap do gelo |

  - O mediador ganha o subtipo `med_run_flags_t` (`is%run`) para essas marcas. `idc_wait_for_sst` passa a receber também `is`.
  - Fica de fora, de propósito, a marca `done` de `register_builtins` (`regrid_registry.F90`), com a tabela de esquemas do mesmo módulo: é o registro de esquemas de interpolação da biblioteca, compartilhado por todos os componentes, e não estado de um componente.
  - Cap do gelo: as três listas de nomes de campos (`import_names_atm`, `import_names_ocn`, `export_names`) eram variáveis de módulo inicializadas e nunca alteradas; passam a ser constantes (`parameter`), com os mesmos valores.
  - As constantes de texto não mudam (as mensagens `si_ifrac_mem_valid=T/F` e `si_ifrac_mem salvo` do log continuam iguais).
  - Conferências locais: `confere-tudo.bash HEAD` sem falhas. `mom_cap_MONAN.F90` e `sis_cap_MONAN.F90` compilam aqui com as interfaces mínimas, mas nenhum teste local os executa.
  - Indicadores: variáveis locais com `save` explícito de 6 para 1; variáveis de módulo privadas de 9 para 2 (a tabela de esquemas de `regrid_registry` e o seu contador).
  - Com esta etapa, a fase 7 fica completa: nenhum módulo próprio guarda em variável de módulo o estado de um componente.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase7-06-validada`). Fase 7 concluída.

- **Cap atmosférico: estado interno ESMF (R-FASE7-05).** Quinta etapa da fase 7, acrescentada na R-FASE7-03. Nenhum cálculo muda.
  - `mpas_cap_MONAN.F90` ganha o tipo `mpas_cap_state_t`, guardado no próprio componente com `ESMF_GridCompSetInternalState` (como já faz o mediador) e recuperado em cada fase pela nova rotina `get_cap_state`. Ele reúne o que eram variáveis de módulo: `atm_public`, `atm_state` e `atm_bnd` (ponteiros, alocados em `InitializeRealize` como antes), a grade do cap, o gravador `diag_export` e o contador `step_count`, com o mesmo valor inicial (0).
  - O relógio do diagnóstico de importação, que eram sete variáveis de módulo de `mpas_cap_netcdf.F90` (`g_diag_yr` a `g_diag_sc` e o contador `g_diag_step`), vira o tipo público `mpas_import_diag_clock_t`, guardado no estado do cap (`diag_clock`). `set_mpas_diag_clock`, `write_mpas_import_diag` e `mpas_import` o recebem como primeiro argumento, e `define_import_diag_file` recebe o contador para o atributo `step`.
  - `test_writers.F90` passa um `mpas_import_diag_clock_t` às duas chamadas de `write_mpas_import_diag`.
  - Conferências locais: `confere-tudo.bash HEAD` sem falhas (gravadores, com os `monan2_import_*.nc`, iguais byte a byte; constantes de texto iguais).
  - Indicadores: variáveis de módulo privadas de 22 para 9 (restam, entre outras, a memória de `Si_ifrac` do cap do oceano, as marcas de primeira chamada `med_ifrac_init_done` e `first_write_diag` e a tabela de esquemas de `regrid_registry`; as de estado de componente vão, com as seis variáveis locais com `save`, na próxima etapa); rotinas de 293 para 294 (`get_cap_state`).
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase7-05-validada`).

- **Modelo atmosférico: estado do MPAS no `mpas_atm_state_type` (R-FASE7-04).** Quarta etapa da fase 7. Nenhum cálculo muda.
  - As 26 variáveis de módulo de `mpas_atm_model.F90` passam a ser componentes de `mpas_atm_state_type` (`mpas_atm_types.F90`), o estado que o cap já guardava e passava a `mpas_atm_init`, `mpas_atm_run` e `mpas_atm_final`: o domínio MPAS (`g_domain` vira `atm_state%domain`), os ponteiros para os campos dos pools (`pool_*`), os acumulados do passo anterior (`prev_*`) e os buffers em unidades instantâneas apontados por `mpas_atm_public_type` (`*_inst`, `*_buf`). Os nomes perdem só o prefixo `g_`.
  - `g_mpi_comm` era uma cópia de `atm_state%mpi_comm`, gravada na mesma linha; saiu, e `mpas_framework_init_phase1` recebe `atm_state%mpi_comm`.
  - As rotinas internas que usavam o estado passam a recebê-lo por argumento: `setup_mpas_streams`, `parse_streams_xml`, `bind_diag_fields`, `setup_wind_fallback`, `init_flux_buffers` e `compute_instantaneous_fluxes`.
  - Os buffers eram variáveis com atributo `TARGET`, porque `mpas_atm_public_type` aponta para eles. Agora são componentes do estado, que o cap aloca por ponteiro; o argumento `atm_state` tem `target` nas rotinas que associam esses ponteiros ou que leem e escrevem os buffers (`mpas_atm_init`, `setup_wind_fallback`, `init_flux_buffers`, `mpas_atm_run`, `compute_instantaneous_fluxes`, `mpas_atm_final`). Assim o compilador continua sabendo que os buffers podem ser alterados pelos ponteiros, como antes.
  - `mpas_atm_types.F90` passa a usar `domain_type` de `mpas_derived_types`.
  - As constantes de texto não mudam (a mensagem `buffers g_u10_buf/g_v10_buf alocados` fica como está).
  - Conferências locais: `confere-tudo.bash HEAD` sem falhas. `mpas_atm_model.F90` compila aqui com as interfaces mínimas do MPAS, mas nenhum teste local o executa; a conferência dele é a rodada na Jaci.
  - Indicadores: variáveis de módulo privadas de 48 para 22.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase7-04-validada`).

- **Cap atmosférico: gravador `monan_export_*.nc` com estado próprio (R-FASE7-03).** Terceira etapa da fase 7. Nenhum cálculo muda.
  - As 18 variáveis de módulo do gravador em `mpas_cap_netcdf.F90` (grade de saída `NLON`, `NLAT`, `GRID_RES`, `DLON`, `DLAT` e `OUTPUT_DIR`; coordenadas globais; decomposição MPI salva; campos MPAS guardados) passam a ser componentes do tipo público `mpas_diag_export_t`, com os mesmos valores iniciais.
  - O objeto é criado pelo cap (`g_diag_export`, em `mpas_cap_MONAN.F90`) e passado como primeiro argumento a `netcdf_config_set`, `netcdf_init_coords`, `netcdf_push_raw_field` e `export_write_netcdf`, e a `mpas_export`, que guarda os campos. As rotinas internas `write_export_fields` e `voronoi_accum_local` o recebem como `intent(in)`.
  - O cap ainda guarda o objeto numa variável de módulo, como já faz com `g_atm_public`, `g_atm_state`, `g_atm_bnd` e `g_grid`: o roteiro supunha que o cap atmosférico tinha estado interno ESMF, e não tem. Foi acrescentada a etapa R-FASE7-05 para criá-lo; ela também leva para lá o relógio do diagnóstico de importação (`g_diag_*`), que fica em `mpas_cap_netcdf` por enquanto.
  - Registrado para depois (sem mudança agora): as coordenadas globais reunidas no PET 0 por `netcdf_init_coords` (`lon_global`, `lat_global`) não são lidas por nenhuma rotina; e `write_export_fields` ainda tem um `BLOCK`, contra a convenção do README.
  - Testes: `test_writers.F90` passa a chamar também `export_write_netcdf` (grade de 2°, dois campos guardados, um deles com valor acima do limiar de descarte, e um campo lido do `exportState` pelo caminho de reserva; duas escritas), gravando em `out_mpas_export`, que `compara-gravadores.bash` passa a comparar. Até aqui `export_write_netcdf` só era conferida pela rodada na Jaci. Nesta etapa a versão de referência não tem esse caso; a comparação foi feita uma vez com um programa de teste adaptado à interface antiga: os 8 arquivos NetCDF (inclusive os 2 `monan_export_*.nc`) e o log do ESMF saíram iguais byte a byte.
  - `test_mpas_export.F90` passa um `mpas_diag_export_t` sem coordenadas a `mpas_export` (nada é guardado, como antes).
  - Conferências locais: compilação, avisos, regrid, física bulk, grade atmosférica e testes com valor esperado sem falhas; constantes de texto iguais em todos os fontes de `src/` (só o programa de teste ganhou constantes); gravadores iguais byte a byte na comparação acima.
  - Indicadores: variáveis de módulo privadas de 65 para 48.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase7-03-validada`).

- **Mediador: estado interno agrupado por assunto (R-FASE7-02).** Segunda etapa da fase 7. Nenhum cálculo muda.
  - `MED_InternalState` deixa de ser uma lista de 49 componentes soltos e passa a ter seis subtipos, declarados e públicos em `med_cap_types.F90`. A tabela mostra onde foi parar cada componente.

    | Subtipo (componente de `is`) | Conteúdo | Nomes antigos |
    | --- | --- | --- |
    | `med_ocn_flux_fields_t` (`is%ocn_flx`) | o que vai para o oceano: fluxos do bulk sobre água aberta (Foxx_*) e campos repassados | `f_taux_atm` a `f_swidf_atm`, `f_rain_atm`, `f_snow_atm`, `f_pslv_atm`, `f_duu10n_atm` |
    | `med_ocn_fields_t` (`is%ocn`) | estado do oceano na grade ATM | `f_sst_atm`, `f_uocn_atm` e `f_vocn_atm` (agora `u` e `v`), `f_omask_atm`, `landmask_done` (agora `omask_done`) |
    | `med_ice_fields_t` (`is%ice`) | gelo: fração, temperatura de pele, fluxos Fioi_* e albedos por banda | `f_ifrac_atm`, `f_tice_atm`, `f_*_ice`, `f_alb_*_ice` (agora `alb_*`) |
    | `med_sfc_fields_t` (`is%sfc`) | superfície vista pela atmosfera | `f_zorl_atm`, `f_coszen_atm`, `f_albedo_atm`, `f_tsfc_atm` |
    | `med_par_t` (`is%par`) | comunicador MPI e PETs | `mpi_comm` (agora `comm`), `local_pet`, `pet_count` |
    | `med_diag_config_t` (`is%diag`) | diagnóstico de importação | `write_import_diag` e `import_diag_dir` (agora `write_import` e `import_dir`) |

    As grades (`atm_grid`, `ocn_grid`), as rotas (`regrid`) e as duas opções (`use_mpas_atm`, `use_med_to_mpas`) continuam no primeiro nível. Os comentários de cada campo foram levados para o subtipo. Os campos ficaram agrupados pelo destino (oceano, gelo, atmosfera), e não por tipo de grandeza como previa o roteiro, porque é assim que o `Advance` e a exportação os percorrem.
  - Saiu o componente `ocn_mask_atm(:,:)`, alocável e sem uso em nenhum fonte.
  - Primeira rotina que recebe só o que usa: `med_read_import_config(is%diag)`. As demais continuam recebendo `is`; passar só o subtipo necessário acompanha a divisão do `MED_cap.F90` na fase 8.
  - As constantes de texto não mudam; as mensagens de log que citam os nomes antigos (por exemplo `[MED-DIAG] f_sst_atm`) ficam como estão, porque os scripts de análise as reconhecem.
  - Testes: `test_bulk_ncar.F90` e `test_writers.F90` usam os nomes novos. Como já feito para os gravadores na R-FASE7-01, `compara-bulk.bash` e `compara-grade-atm.bash` passam a ligar a versão antiga ao programa de teste do commit de referência e a nova ao da árvore de trabalho.
  - Conferências locais: `confere-tudo.bash HEAD` sem falhas (física bulk, gravadores e grade atmosférica iguais byte a byte; constantes de texto iguais). Indicadores sem mudança.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase7-02-validada`).

- **Mediador: estado de comunicação e de diagnóstico no estado interno (R-FASE7-01).** Primeira etapa da fase 7 do roteiro de código limpo. Nenhum cálculo muda.
  - `med_cap_types.F90` passa a ter `private` como padrão, com a lista explícita do que é público: os tipos `MED_InternalState` e `MED_InternalStateWrapper`, as constantes físicas e os parâmetros do bulk e as listas de campos. A constante `u_FILE_u`, sem uso, deixa de ser exportada.
  - As cinco variáveis de módulo com `save` (`med_mpi_comm`, `med_local_pet`, `med_pet_count`, `med_write_import_diag` e `med_import_diag_dir`) viram os componentes `mpi_comm`, `local_pet`, `pet_count`, `write_import_diag` e `import_diag_dir` do `MED_InternalState`, com os mesmos valores iniciais (-1, `.false.` e `'diag_import'`) e preenchidos no mesmo momento (`InitializeRealize`). O módulo fica sem variáveis.
  - `med_read_import_config(is)` grava a configuração no estado interno. O comunicador chega por argumento a `gather_atm_forcing`, `allreduce_atm_tile` e `gather_field_global`, e o número de PETs a `define_import_file` (atributo `petCount`); `substitute_native_fluxes` e `gather_ocean_mask` usam o `is` que já recebiam.
  - Corrigido o comentário de `atm_grid`, que dava a grade ATM como 640×320; ela é 360×180.
  - Testes: `tests/writers/test_writers.F90` preenche os componentes do estado interno no lugar das variáveis de módulo. Para que uma etapa possa mudar a interface dos gravadores, `compara-gravadores.bash` passa a ligar a versão antiga ao `test_writers.F90` do commit de referência e a nova ao da árvore de trabalho; os dados sintéticos são os mesmos.
  - Conferências locais: `confere-tudo.bash HEAD` sem falhas; gravadores com os 6 arquivos NetCDF e as mensagens do log iguais byte a byte; constantes de texto iguais.
  - Indicadores: variáveis de módulo públicas de 5 para 0; as demais contagens não mudam (o maior arquivo, `MED_cap.F90`, passa de 3 379 para 3 381 linhas).
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase7-01-validada`).

- **Testes com valor esperado da grade do cap atmosférico (R-FASE6-03).** Terceira etapa da fase 6. Nenhum cálculo muda.
  - Novo `tests/unit/test_grade_atm.F90`, com 20 casos, sem MPI, para as duas etapas de cálculo de `map_cells_to_regular_grid`. `bin_cells_local`: duas células na mesma caixa, longitude negativa (coluna 360), latitudes de 90° e -90° (linhas 180 e 1), célula além de `n` ignorada, soma e contagem totais. `fill_empty_bins`: média dos vizinhos preenchidos, vizinha ainda vazia que não conta, caixa recém-preenchida usada na mesma passada, longitude periódica, borda norte, zero passadas e grade toda vazia. Os valores esperados do preenchimento foram calculados em aritmética exata para o campo f(i, j) = i + 1000 j.
  - O teste registra um comportamento atual: na borda norte, a linha 181 vira a própria linha 180, e os vizinhos (i-1, 180) e (i+1, 180) contam duas vezes na média. Mudar isso altera resultados e fica para uma decisão própria.
  - `mpas_cap_methods.F90`: `bin_cells_local` e `fill_empty_bins` passam a ser públicas, para os testes; é a única mudança no fonte (`confere-instrucoes.py`: só a declaração `public`); constantes de texto iguais. `roda-unitarios.bash` passa a ligar também os objetos do cap atmosférico.
  - Conferido ao contrário: tirar a longitude periódica do preenchimento, tirar a volta da longitude para [0°, 360°), arredondar a latitude em vez de truncar, mudar a marca 0,5 das caixas preenchidas e ignorar o `n` fizeram o teste falhar, uma de cada vez.
  - Conferências locais: `confere-tudo.bash HEAD` sem falhas.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase6-03-validada`). Com ela, a fase 6 está concluída.

- **Testes com valor esperado das fórmulas da física bulk (R-FASE6-02).** Segunda etapa da fase 6. Nenhum cálculo muda.
  - Novo `tests/unit/test_formulas_bulk.F90`, com 26 casos: `ice_temp_eff` (dentro, nos limites e fora da faixa (180 K; 273,16 K]), `louis_stability` (estável, neutro, instável, piso 0,05 e teto 3 do fator) e `ocean_direct_albedo` (sol a pino, noite, latitudes de 60,5° e 78,5°, declinação de 0,4 rad; piso de 0,03 do albedo). Os valores esperados foram calculados à parte, da fórmula publicada (Louis, 1979; Briegleb et al., 1986), em precisão de 40 algarismos, e a comparação usa tolerância relativa de 1e-12. Diferente dos testes de regressão, que comparam duas versões, estes conferem se o código calcula o que a fórmula diz.
  - Novo `tests/unit/roda-unitarios.bash`, que compila a árvore de trabalho, liga e executa cada `tests/unit/test_*.F90`; incluído no `confere-tudo.bash` como a conferência `unitarios`.
  - `med_bulk_ncar.F90`: `ice_temp_eff`, `louis_stability` e `ocean_direct_albedo` passam a ser públicas, para os testes. É a única mudança no fonte (`confere-instrucoes.py`: só a declaração `public` acrescentada); constantes de texto iguais.
  - Conferido ao contrário: cinco alterações de propósito no código (limite `<=` trocado por `<`, coeficiente do fator de Louis, expoente 1,7 do albedo, teto do fator, sinal da longitude no ângulo horário) fizeram o teste falhar, uma de cada vez.
  - Conferências locais: `confere-tudo.bash HEAD` sem falhas (compilação, avisos, literais, regrid, gravadores, física bulk, grade atmosférica e os testes novos).
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase6-02-validada`).

- **Conferências locais num comando só e indicadores de código limpo (R-FASE6-01).** Primeira etapa da fase 6 do roteiro de código limpo. Nenhum fonte Fortran muda.
  - `tools/dev/confere-tudo.bash [-i] [-t LISTA] [REV]`: executa a compilação local da árvore de trabalho e da versão `REV` (e falha se algum fonte tiver mais avisos que antes), a conferência das constantes de texto, os testes do framework de interpolação (`tests/regrid`) e os três testes de regressão (gravadores, física bulk, grade do cap atmosférico); com `-i`, exige instruções idênticas em todo `.F90` alterado. Termina com um resumo OK/FALHOU/PULADO e a tabela de indicadores; sai com código 1 se algo falhou. Leva cerca de seis minutos. Conferido ao contrário: uma variável sem uso acrescentada a `nc_writer.F90` faz falhar `avisos` e `instrucoes`.
  - `tools/dev/indicadores.py [-l] [VERSAO ...]`: mede os indicadores do roteiro (arquivos com mais de 1 000 linhas, rotinas com mais de 100 e de 150 linhas de código, variáveis de módulo públicas, protegidas e privadas, variáveis locais com `save` explícito ou implícito, trechos repetidos de 6 linhas, comentários com marcas de histórico), uma coluna por versão, em Markdown.
  - Documentação: `docs/roteiro-codigo-limpo.md` (roteiro das fases 6 a 10, com indicadores e metas), `docs/conformidade-dtn01.md` (levantamento de conformidade com o DTN-01, deixado para depois do roteiro), seções 2.0 e 2.7 e nova ordem de conferências em `docs/conferencias-locais.md`, catálogo em `docs/ferramentas.md`, `README.md` e `docs/estado-do-projeto.md`.
  - Correção (R-FASE6-01-FIX01): `indicadores.py`, `confere-literais.py` e `confere-instrucoes.py` usavam `subprocess.run(capture_output=..., text=...)`, do Python 3.7, e o `python3` do sistema na Jaci é o 3.6 (`TypeError: __init__() got an unexpected keyword argument 'capture_output'`). As chamadas ao git passam por uma função `git()` com `stdout=subprocess.PIPE` e decodificação UTF-8 explícita, e a saída padrão é forçada a UTF-8, para os acentos não quebrarem com o locale C. Conferido com `vermin -t=3.6-` (versão mínima 3.6) e com `LC_ALL=C`; os resultados dos três scripts são os mesmos.
  - Validação: na Jaci, `indicadores.py` com o Python 3.6 do sistema deu os mesmos valores para `fase5-07-validada` e para a árvore de trabalho; rodada com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase6-01-validada`).
  - Indicadores de partida (tag `fase5-07-validada`): 33 arquivos Fortran, 18 285 linhas (11 319 de código); 7 arquivos com mais de 1 000 linhas (o maior com 3 379); 293 rotinas, 10 com mais de 100 linhas de código e 1 com mais de 150 (`config_read`, 267); 5 variáveis de módulo públicas, 51 protegidas e 65 privadas; 6 variáveis locais com `save` explícito e 71 com `save` implícito; 87 trechos repetidos; 6 comentários com marcas de histórico (nenhuma de fato: versões do OISST e uma constante de texto).

- **Scripts de `tools/` sem marcas de histórico nos comentários (R-FASE5-07).** Sétima etapa da fase 5. Só comentários e docstrings mudam: nenhuma instrução, nenhuma constante de texto impressa pelos scripts e nada do código Fortran.
  - Os blocos de histórico dos cabeçalhos de onze scripts Python (`postproc_mom6_import.py`, `postproc_monan2_import.py`, `postproc_monan2_export.py`, `postproc_monan2_standalone.py`, `analisa_comparacao.py`, `analisa_sst_ifrac.py`, `anim_mom6_import.py`, `anim_monan2_import.py`, `anima_sst_ifrac.py`, `analisa_balanceamento_pets.py` e `mede_smt.py`) foram movidos, sem alteração, para o novo `docs/historico-scripts.md`. No lugar ficou uma linha que aponta para ele. Como vários desses scripts usam a docstring como texto de ajuda (`--help`), a ajuda ficou mais curta e sem o histórico.
  - Nos demais comentários, saíram os identificadores de correção usados como prefixo (`BUG-PY-nn:`, `B-XXX-nn:`, `FIX E1`, `[N1]`), as datas, as versões dos scripts e dos módulos Fortran e as menções a "Sprint" e "Fase"; textos do tipo "antes fazia X, agora faz Y" foram reescritos para descrever o comportamento atual. As referências que apontam para uma explicação em `docs/` foram mantidas, agora com o documento indicado (por exemplo, `B-SEQINIT-01` no CHANGELOG).
  - Corrigido o cabeçalho de `postproc_mom6_import.py`, que dava a grade dos arquivos `mom6_import_*.nc` como 640 x 320; a grade é a ATM interna do mediador, 360 x 180.
  - Ficaram, de propósito: as versões do driver usadas para nomear formatos de linha de log que os scripts reconhecem (`<= v14.19` e `v14.20+`, em `analisa_balanceamento_pets.py`, `mede_smt.py` e `test-concurrent.bash`) e os nomes de diagnóstico gravados pelo mediador (`FIX-DIAG-*`), que são constantes de texto.
  - Marcas de histórico nos comentários (contagem de linhas com identificador de correção, versão, data, "Sprint" ou "Fase"): 268 para 9 nos scripts Python e 37 para 7 nos scripts bash; as que restam são as do item anterior e uma referência a `docs/uso-linha-base.md`.
  - Conferências locais: para cada script Python, a árvore sintática com as docstrings apagadas é idêntica à do commit anterior (o código e todas as outras constantes de texto são os mesmos); para cada script bash, as linhas que não são comentário são idênticas (fora dois comentários finais de linha com só um identificador) e `bash -n` passa; `confere-literais.py` sem diferenças.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (tag `fase5-07-validada`).

- **Mediador: `InitializeDataComplete` e `blend_albedo_with_ice` em etapas (R-FASE5-06).** Nenhum cálculo muda.
  - `InitializeDataComplete` (`MED_cap`) passou de 278 linhas (160 de código) para 103 (48 de código). Etapas novas: `idc_check_atm_field` (campo de referência da grade ATM), `idc_create_routes` (fase A: rotas `atm2ocn` e `ocn2atm`, correntes), `idc_init_export_fields` (valores iniciais do exportState), `sst_has_physical_values` (o gate "carimbo não é dado", com o `ESMF_VMAllReduce`), `idc_wait_for_sst` (pede outra iteração do laço de dependência de dados; o contador de tentativas, com `save`, foi junto), `idc_publish_initial_sst` (fase B: correntes e SST de t=0) e `idc_stamp_export` (carimbo com startTime). A sequência de chamadas, a coletiva do gate e os códigos de retorno são os mesmos. A variável `atm_field` passou para `idc_check_atm_field`, e variáveis locais sem uso saíram.
  - `blend_albedo_with_ice` (`med_bulk_ncar`) passou de 194 linhas (153 de código) para 55 (45 de código). As quatro bandas de onda curta, antes quatro laços quase iguais, passaram a uma rotina só, `sw_band`, chamada por banda com a fração da banda, o albedo do gelo e dois indicadores: se a banda é direta (albedo da água aberta pelo zênite, `ocean_direct_albedo`, Briegleb 1986) e se é a primeira (que atribui o albedo de banda larga; as demais somam). O caso sem dado de gelo virou `sw_band_fallback`. As expressões e a ordem das operações são as mesmas. O argumento `fptr`, que só servia de variável de trabalho, saiu da interface, e os ponteiros de trabalho passam a ser anulados antes de cada `ESMF_FieldGet` (antes, os três da primeira banda, declarados com `=> null()`, ficavam com a associação da chamada anterior; isso só faria diferença se um campo interno não existisse, o que não ocorre).
  - Conferências locais: `tests/bulk/compara-bulk.bash HEAD` idêntico (conferido que acusa diferença quando uma banda direta é tratada como difusa); `confere-instrucoes.py` em `MED_cap.F90` só com chamadas, declarações e cabeçalhos novos; constantes de texto iguais; compilação local sem avisos. `InitializeDataComplete` não tem teste local: a rodada na Jaci o confere.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02.

- **Cap atmosférico: `map_cells_to_regular_grid` em etapas (R-FASE5-05).** Nenhum cálculo muda.
  - `map_cells_to_regular_grid` (`mpas_cap_methods`), que leva os valores das células MPAS à grade regular 360 x 180, passou de 300 linhas (192 de código) para 57 (40 de código). Etapas novas, procedimentos de módulo com `intent`: `bin_cells_local` (soma e contagem locais por caixa de 1 grau), `mpas_mpi_comm` (comunicador do componente, com as mesmas mensagens de erro), `ordered_sum_bcast` (soma entre PETs em ordem de rank, `MPI_Gather` e `MPI_Bcast`, com a explicação de por que não se usa `MPI_Allreduce`), `fill_empty_bins` (preenchimento das caixas vazias, com a mesma ordem de laços), `log_fill_marker` e `log_dup_diag` (os dois diagnósticos do log) e `copy_to_local_grid` (cópia para a porção local, da convenção [0°,360°) para [-180°,180°)). A ordem das coletivas do MPI e das operações de ponto flutuante é a mesma. Variáveis locais sem uso saíram, e `lon_rad`/`lat_rad` deixaram de ser opcionais nesta rotina (quem a chama já confere que estão presentes).
  - Novo teste de regressão: `tests/atmgrid/test_mpas_export.F90` e `tests/atmgrid/compara-grade-atm.bash REV`, que executa `mpas_export` da versão de um commit e da árvore de trabalho com as mesmas células sintéticas e compara os campos na grade, a linha `MPAS-DIAG` e as mensagens do log. Nesta etapa, tudo saiu idêntico; conferido que o teste acusa diferença quando a ordem da soma entre PETs ou a ordem das linhas no preenchimento é invertida.
  - Conferências locais: constantes de texto iguais; compilação local sem avisos novos. Documentação: `docs/conferencias-locais.md`, README e `docs/estado-do-projeto.md` (R-FASE5-04 validada).
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02.

- **Comentários do cap atmosférico e de `src/shared` sem marcas de histórico (R-FASE5-04).** Quarta etapa da fase 5. Só comentários mudam: nenhuma instrução e nenhuma constante de texto do código.
  - Arquivos: `mpas_cap_MONAN.F90`, `mpas_cap_methods.F90`, `mpas_cap_netcdf.F90`, `mpas_atm_model.F90`, `mpas_atm_types.F90`, `DATM_cap.F90`, `diag_bitsum.F90`, `mom6_supergrid.F90` e os três arquivos `mpi_allreduce_*.F90`.
  - Os históricos de versão dos cabeçalhos de `mpas_cap_MONAN` (7.0 a 9.2) e `mpas_cap_netcdf` (2.5 a 3.0) foram resumidos neste CHANGELOG; no lugar, cada cabeçalho descreve o que o arquivo faz. Saíram "Fase 2/2.6/4b", "FIX v5.2", "BUG FIX v2.8", "W1/W2/W3-FIX", "CORRECAO N", "(modo concurrent, v13.x)", "v7.6)", "correção Maio 2026" e as datas de medições.
  - Documentação desatualizada corrigida: `mpas_create_grid` citava a grade 640x320 do mediador e a fórmula antiga de decomposição; `state_get_field_1d` e `state_set_field_1d` tinham blocos `@brief` duplicados e uma nota de "trabalho futuro" já feita (o campo é reunido no PET 0 e difundido); o fluxo MPI de `mpas_cap_netcdf` citava `voronoi_to_latlon`, que não existe mais; `voronoi_accum_local` e `netcdf_push_raw_field` tinham a documentação de outras rotinas; o cabeçalho de `mpas_cap_MONAN` dava o nome `mpas_cap.F90`. Texto com codificação corrompida em `mpas_cap_methods` foi corrigido.
  - `DATM_cap.F90`: os comentários diziam que a época do JRA55 fora corrigida para 00:00, mas o código usa 01:30; os comentários agora descrevem o que o código faz (ver a pendência no estado do projeto). O DATM não entra na configuração de validação.
  - Conferências locais: `confere-instrucoes.py` sem diferenças nos onze arquivos; `confere-literais.py` com as constantes de texto iguais; compilação local sem avisos novos.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02.

- **Comentários dos caps do oceano e do gelo sem marcas de histórico (R-FASE5-03).** Terceira etapa da fase 5. Só comentários mudam: nenhuma instrução e nenhuma constante de texto do código.
  - Arquivos: `mom_cap_MONAN.F90`, `sis_cap_MONAN.F90`, `DOCN_cap.F90` e `docn_cap_netcdf.F90`.
  - `mom_cap_MONAN.F90`: o histórico das versões 2.0 a 2.6 saiu do cabeçalho e foi resumido neste CHANGELOG (seção "Histórico do cap do oceano"); no lugar, o cabeçalho descreve os três modos da fração de gelo exportada e a persistência. Saíram as marcas `[C1]` a `[C13]`, `[v14.4]`, "(v2.6)", "(v14.21)", "Alternativa 1" e ".5.1". A documentação da sigmoide descrevia `DT_TRANS` = 0,5 K e frazil binário e estava antes da rotina errada; foi reescrita com os valores atuais (2,0 K, frazil contínuo, persistência) e posta antes de `compute_si_ifrac_proxy`. Saíram três blocos de documentação de rotinas que não existem mais (malha ESMF e grade lat-lon regular do oceano).
  - `sis_cap_MONAN.F90`: saíram "FIX", "TODO-VERIFICAR", "Fase 2/3/4" (trocados pelo nome do grupo de campos), "(Ago 2026)", "(, Set/2026)" e a data da bateria de diagnóstico; o bloco "Historico de correcoes" de `export_si_ifrac`, que repetia o bloco seguinte, saiu. A documentação de `import_forcing` dizia que `coszen` não tinha fonte no mediador; hoje vem de `Faxa_coszen`. O comentário de `u_star` aponta a decisão em aberto registrada em `docs/estado-do-projeto.md`.
  - `DOCN_cap.F90` e `docn_cap_netcdf.F90`: linha de versão do cabeçalho e marca "(modo concurrent, v13.1)".
  - Conferências locais: `confere-instrucoes.py` sem diferenças nos quatro arquivos; `confere-literais.py` com as constantes de texto iguais; compilação local sem avisos novos.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02.

- **Comentários do mediador sem marcas de histórico (R-FASE5-02).** Segunda etapa da fase 5 (limpeza). Só comentários mudam: nenhuma instrução e nenhuma constante de texto do código.
  - Arquivos: `MED_cap.F90`, `med_cap_types.F90`, `med_bulk_ncar.F90`, `med_cap_methods.F90` e `med_cap_netcdf.F90` (juntos, de 5598 para 5439 linhas).
  - Saíram dos comentários as marcas de versão (v2.5, v4, v13.0, v14.20, v14.21 e outras), datas (Maio, Ago e Set de 2026), os nomes "Fase 2", "Fase 3", "Fase 4" e "Fase 4b" do acoplamento (trocados pelo nome do que cada grupo de campos é: umidade e neve opcionais, fluxos do gelo, onda curta do gelo, temperatura composta), "Alternativa 1", "Opção 1", "CORRECAO N", "FIX", "REVERT PARCIAL" e as linhas "Versão 1.0" dos cabeçalhos. Os fragmentos que sobraram de limpezas anteriores (como "v13.0): anuncia", "Em.1.1" e "mascara.5.1") viraram frases completas, e dois caracteres corrompidos foram corrigidos.
  - Comentários desatualizados reescritos com o comportamento atual: a decomposição das grades (um DE por PET, por `grid_regdecomp`, no lugar da fórmula antiga com exemplos de 640x320 e 512 PETs), as rotas de interpolação pelo nome (`ocn2atm`, `ocn2atm_ice`, `atm2ocn_ice`, no lugar dos antigos `rh_*`), os modos da fração de gelo do OISST, a máscara de terra por `So_omask` e a temperatura composta `Sx_tsfc`. O aviso para conferir a assinatura de `ESMF_GridCreate1PeriDim` saiu (o código compila e roda com o ESMF 8.9.1), assim como o comentário sobre um `BLOCK` que já não existe.
  - Conferências locais: `confere-instrucoes.py` sem diferenças nos cinco arquivos; `confere-literais.py` com as constantes de texto iguais; compilação local, teste da física bulk e teste dos gravadores idênticos.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02.

- **`nuopc.input` sem histórico nos comentários (R-FASE5-01).** Primeira etapa da fase 5 (limpeza). Nenhum valor do `nuopc.input` muda e nenhum fonte Fortran muda.
  - `nuopc.input`: o cabeçalho com o histórico de versões (v10.0 a v12.0) e as marcas `[N1]` a `[N8]`, `[N-B1]` e `Sprint` saíram dos comentários (o histórico fica neste CHANGELOG); os comentários passam a citar o módulo que lê o arquivo (`coupler_config_mod`, no lugar de `mpas_cap_config_mod`), o driver `esm.F90` (no lugar de `esm_MONAN.F90`) e o módulo do cap atmosférico (`mpas_cap_MONAN_mod`); as referências a versões antigas (v14.19, v14.20) e aos nomes "Fase 1" e "Fase 2" do acoplamento saíram; os grupos passam a ser numerados de 1 a 9, sem o "1b".
  - A nota "ESTADO" do grupo `&nuopc_petlayout`, que dava o caminho do `Si_ifrac` do SIS2 até o MPAS como não validado e dizia que o mediador copiava o campo ponto a ponto, foi substituída pela descrição atual: o mediador interpola `Si_ifrac_sis2` pela rota `ocn2atm_ice` (conservativa, com máscara de terra e extrapolação por vizinhança), e o caminho está validado. Resolve a pendência registrada na entrada do componente de gelo.
  - `run/run_esmApp.jaci`: saiu o aviso "o caminho Si_ifrac ICE→MPAS ainda não foi validado", impresso na verificação antes de cada submissão.
  - Documentação: `docs/estado-do-projeto.md`, com o levantamento e a sequência da fase 5.
  - Validação: valores do `nuopc.input` iguais aos da linha de base; rodada na Jaci com PASS, 73 arquivos iguais à R-NOFMA-02, já sem o aviso na verificação da submissão.

- **`nuopc.input` com a configuração de validação (R-FASE4-08).** O `nuopc.input` do repositório passa a ter as contagens de PETs usadas nos experimentos de reprodutibilidade e na linha de base de validação: `atm_pet_count = 128` e `ocn_pet_count = 20` (antes 32 e 4), com `ice_pet_count = 4`, num total de 152 PETs. Os demais valores já eram iguais aos desses experimentos. Os comentários do repositório, mais novos que os da cópia usada nos experimentos (grupo `&nuopc_regrid`, descrição correta de `mesh_ocn`, chaves obsoletas retiradas), foram mantidos. Nenhum fonte Fortran muda; a validação usa a cópia do `nuopc.input` guardada na linha de base, que não é afetada.
  - Documentação: `docs/estado-do-projeto.md` (R-FASE4-07 validada; a troca pelo `mpi_f08` passa a opcional, sem número de etapa) e a versão 4 do relatório técnico (RPQ).
  - Validação: sem os comentários, o arquivo tem os mesmos valores da cópia guardada na linha de base R-NOFMA-02 (a única diferença é o grupo `&nuopc_regrid` vazio, sem efeito).

- **Cap do gelo: `InitializeRealize` em etapas e `intent` refinados (R-FASE4-07).** Nenhum cálculo muda.
  - `InitializeRealize` (`sis_cap_MONAN`) passou de 338 linhas (202 de código) para 36 (26 de código). Etapas novas, procedimentos de módulo com `intent`: `init_sis2` (FMS, calendário, listas de PETs, tempos, `ice_model_init`, `diag_manager_set_time_end_infra` e `share_ice_domains`, na mesma ordem), `create_ice_grid` (grade ESMF com a decomposição do SIS2 e coordenadas do `ocean_hgrid.nc`), `ice_category_count`, `realize_ice_fields` e `alloc_ice_boundaries`. A liberação explícita dos arrays locais da decomposição saiu (eles são liberados na saída da rotina).
  - `intent` refinados: `advance_ice_slow` recebe o estado como `pointer, intent(in)`; `import_forcing`, `export_si_ifrac`, `export_si_albedo` e `export_si_tskin` recebem `gcomp` como `intent(in)`; em `broadcast_to_cat` e `broadcast_to_cat_neg`, o destino passou de `intent(inout)` (por precaução) para `intent(out)`, porque é todo sobrescrito.
  - Removidos: a variável `fld` sem uso em `import_forcing` e as importações sem uso `mpp_get_domain_npes`, `mpp_get_pelist` e `mpp_pe`. O cabeçalho do arquivo, que ainda o descrevia como rascunho escrito sem compilador, e os comentários de histórico do início do módulo e da inicialização foram reescritos com o motivo de cada escolha.
  - Novas interfaces mínimas do SIS2 (`tests/interfaces/sis_stubs.F90`) e `mpp_pe` e `AGRID` em `mom_stubs.F90`: com elas, `tools/dev/compila-local.bash` passa a compilar também o `sis_cap_MONAN.F90`. Validadas compilando com elas a versão anterior do arquivo. Constantes de texto iguais.
  - Documentação: `docs/conferencias-locais.md` e `docs/estado-do-projeto.md` (R-FASE4-06 validada; R-FASE4-08 em avaliação, sem ganho de desempenho).
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (a rodada usa o SIS2 dinâmico).

- **`WriteDOCNDiag` em etapas (R-FASE4-06).** Passou de 244 linhas (210 de código) para 53 (42 de código). Etapas novas, procedimentos de módulo com `intent`: `docn_epoch_seconds` (segundos desde a época dos dados), `docn_time_len` (tamanho da dimensão de tempo, antes repetido para a SST, o gelo e as correntes), `docn_time_indices` (instantes vizinhos, também repetido três vezes), `interp_docn_sst`, `interp_docn_ice`, `interp_docn_currents` e `write_docn_diag_file`. A busca da dimensão de tempo continua como era: `'time'`, `'Time'` e, só para a SST, `'TIME'`; sem ela, o número de instantes continua sendo `huge` para a SST, o da SST para o gelo e 1 para as correntes. Nenhum cálculo muda.
  - Simplificações sem efeito no resultado: o desvio `goto 99` e a liberação manual dos arrays viraram `return` (os arrays locais `allocatable` são liberados na saída da rotina); as variáveis `nlon_diag` e `nlat_diag`, cópias de `nx` e `ny`, saíram. Os literais `'time'` e `'Time'` aparecem duas vezes a menos cada, porque a busca da dimensão ficou num só lugar; as demais constantes de texto são iguais.
  - O teste dos gravadores (`tests/writers/`) passou a cobrir o `WriteDOCNDiag`, que a rodada da linha de base não executa: três chamadas, com configurações `&nuopc_docn` lidas por `config_read` e arquivos de dados sintéticos gravados pelo próprio teste (sem e com correntes, gelo em fração e em porcentagem, nomes `time`, `Time` e `TIME` para a dimensão de tempo, valores ausentes e arquivo de SST ausente). Os arquivos da versão antiga e da nova saíram idênticos byte a byte; conferido que o teste acusa diferença quando o limite das correntes é alterado.
  - Documentação: `docs/conferencias-locais.md` e `docs/estado-do-projeto.md` (R-FASE4-05 validada e R-FASE4-06).
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02 (a rodada não passa pelo DOCN; confirma a compilação e o restante do acoplador).

- **Gelo na grade ATM e fluxos sobre o gelo em etapas (R-FASE4-05).** Nenhum cálculo muda.
  - `update_ice_fields_on_atm_grid` (`MED_cap`) passou de 353 linhas (222 de código) para 66 (50 de código). Etapas novas, procedimentos de módulo com `intent`: `add_ice_route` (máscara So_omask e criação da rota `ocn2atm_ice`), `fill_ice_sentinels`, `log_ice_source` (ICESRC-01 e checksum da etapa 1), `log_ice_destination` (ICESRC-02 e checksum da etapa 2), `log_ifrac_raw` (ICEMASK-02), `regrid_ice_member` (albedos e Si_t_sis2), `extrapolate_ice_field` e `check_ice_geography` (ICEGEO-01). A ordem das operações e o encadeamento do código de retorno `rc_ice` entre o preenchimento com a sentinela, os diagnósticos e a interpolação da fração ficaram iguais.
  - `compute_ice_fluxes` (`med_bulk_ncar`) passou de 269 linhas (224 de código) para 60 (51 de código). O número de Richardson e o fator de estabilidade de Louis (1979), que se repetiam em quatro laços, viraram o procedimento `louis_stability`, e a temperatura efetiva do gelo, repetida em cinco, a função `ice_temp_eff`; as expressões são as mesmas, sem nenhuma operação trocada de ordem. Etapas novas: `ice_wind_stress` (usada para taux e para tauy), `ice_sensible_heat` (com o diagnóstico ICESTAB-01), `ice_evaporation`, `ice_longwave` e `log_ice_flux_check` (ICEFLUX-01). Os parâmetros `Z_REF`, `LOUIS_B`, `LOUIS_C`, `STAB_FAC_MIN`, `STAB_FAC_MAX` e `IFRAC_MIN_FIOI`, com os mesmos valores, passaram a ser do módulo.
  - Instruções sem efeito removidas: em `compute_ice_fluxes`, o argumento `wspd` (o valor final não era usado por `calc_bulk_ncar`) e a atribuição `rc_ice2 = ESMF_SUCCESS`, que nunca era lida; em `update_ice_fields_on_atm_grid`, a atribuição `rc_ice = ESMF_SUCCESS` depois do ICEMASK-02, sempre sobrescrita em seguida. Comentários longos com histórico viraram cabeçalhos das etapas.
  - Constantes de texto: iguais. O literal `'ocn2atm_ice'` aparece quatro vezes a menos, porque as cinco interpolações dos albedos e de Si_t_sis2 passaram a uma única chamada dentro de `regrid_ice_member`.
  - Novo teste de regressão da física bulk: `tests/bulk/test_bulk_ncar.F90` e `tests/bulk/compara-bulk.bash REV`, que executa `calc_bulk_ncar` da versão de um commit e da árvore de trabalho com os mesmos dados sintéticos e compara todos os campos bit a bit. Nesta etapa, os campos saíram idênticos; conferido que o teste acusa diferença quando `STAB_FAC_MAX` é alterado.
  - `.gitignore`: acrescentado `bin/` (executável gerado pelo `make`).
  - Documentação: `docs/conferencias-locais.md`, `docs/ferramentas.md`, `README.md` e `docs/estado-do-projeto.md`. O estado registra a validação da R-FASE4-04, o envio do ramo ao GitHub e as decisões de 27/09/2026 (pedido de integração adiado; verificação automática de compilação fora da sequência, porque o repositório não usa GitHub Actions), com a renumeração das etapas seguintes.
  - Validação: rodada na Jaci com PASS, 73 arquivos iguais à linha de base R-NOFMA-02.

- **Conferências locais no repositório (R-FASE4-04).** As conferências feitas antes de cada rodada na Jaci, que até aqui existiam só no ambiente de trabalho do assistente, passam a fazer parte do repositório. Nenhum fonte Fortran de `src/` muda.
  - `tools/dev/compila-local.bash`: compila os fontes do acoplador fora da Jaci, na ordem e com as opções de aviso e de ponto flutuante do Makefile, contra um ESMF local (`ESMFMKFILE`).
  - `tests/interfaces/`: interfaces mínimas do MPAS (`mpas_stubs.F90`) e do MOM6/FMS (`mom_stubs.F90`), só com tipos e assinaturas, para compilar `mpas_atm_model.F90`, `mom_cap_MONAN.F90` e `time_utils.F90` sem as bibliotecas dos modelos. Foram validadas compilando com elas as versões anteriores dos arquivos.
  - `tools/dev/confere-literais.py`: compara as constantes de texto (mensagens de log, nomes de campos e atributos, formatos) dos fontes alterados com as de um commit.
  - `tools/dev/confere-instrucoes.py`: compara as instruções de um fonte, sem comentários nem espaços, com as de um commit; usado nas etapas que só movem código.
  - `tests/writers/`: programa de teste dos gravadores `med_write_import_fields` e `write_mpas_import_diag` e o script `compara-gravadores.bash`, que executa a versão de um commit e a da árvore de trabalho com os mesmos dados sintéticos e compara os arquivos byte a byte. Conferido que acusa diferença quando um limite do binning é alterado.
  - Documentação: novo `docs/conferencias-locais.md`; `README.md`, `docs/ferramentas.md`, `docs/validacao-refatoracao.md` e `docs/estado-do-projeto.md` (seção 8 com a sequência dos próximos passos). Registrada a validação da R-FASE4-03 e a versão 3 do relatório técnico (RPQ).
  - Validação: como nenhum fonte de `src/` muda, a etapa foi validada pela compilação completa na Jaci, sem erros (tag `fase4-04-validada`), sem rodada.

- **`MediatorAdvance` em etapas (R-FASE4-03).** Passou de 648 linhas (308 de código) para 244 (97 de código). Novas etapas, procedimentos de módulo com `intent`: `med_stamp_time` (instante que rotula o resultado do passo), `get_atm_forcing` (forçantes do MPAS, ou do DATM como reserva, com os valores padrão de umidade e neve), `gather_atm_forcing` e `allreduce_atm_tile` (forçantes reunidos na grade ATM global), `local_atm_bounds`, `apply_native_fluxes` (fluxos nativos do MONAN-A no lugar dos do bulk) e `log_ifrac_export_bitsum`. Nenhum cálculo muda: os nove `MPI_Allreduce(SUM)` são os mesmos, na mesma ordem e sobre os mesmos dados; as mensagens de log e as constantes de texto são as mesmas.
  - Saem instruções sem efeito: os ponteiros `uocn` e `vocn`, que eram anulados e nunca usados; as associações `uas => uas_g` (e as dos outros sete campos), que não eram lidas depois, pois o bulk recebe os arrays globais diretamente; o atributo `target` desses arrays, que só servia a essas associações; e um comentário que descrevia um diagnóstico de importação que não existe mais neste arquivo.
  - Conferência local: `MED_cap.F90` compila sem aviso com ESMF 8.9.1; a comparação das instruções antes e depois mostra só as chamadas e declarações novas e as remoções acima.
  - Validação na Jaci (rodada R-FASE4-03): 73 arquivos iguais à linha de base R-NOFMA-02, 0 só com metadados diferentes, PASS.

- **Anotação de linha de base congelada e aviso de comparação não feita (R-FASE4-02).** Só scripts e documentação; nenhum fonte Fortran muda.
  - Novo `tools/dev/anota-linha-base.bash`: acrescenta uma observação, com data e usuário, ao `MANIFEST.txt` de uma linha de base congelada e atualiza só a soma dele no `SHA256SUMS`, devolvendo a proteção contra escrita. Com `-r`, registra a soma de um `MANIFEST.txt` já editado à mão, desde que ele seja o único arquivo que não confere; se outro arquivo mudou, recusa. Motivo: na validação da R-FASE4-01, uma observação escrita à mão no MANIFEST da R-NOFMA-02 fez o `compara-linha-base.bash` parar antes de comparar, e a saída mostrava só `./MANIFEST.txt: FAILED`.
  - `valida_rodada.bash compara`: quando o `compara-linha-base.bash` sai com código 2 (comparação não feita), diz isso com clareza, mostra o erro e, se só o `MANIFEST.txt` mudou, sugere o `anota-linha-base.bash -r`. O `compara` passa a sair com o código da comparação (0 PASS, 1 FAIL, 2 comparação não feita); antes saía sempre com 0.
  - Documentação: `docs/uso-linha-base.md` (anotar uma base congelada), `docs/validacao-refatoracao.md`, `docs/ferramentas.md`, `docs/estado-do-projeto.md` e README. O README passa a citar a R-NOFMA-02 como linha de base de referência (ainda citava a R-NOFMA-01).
  - Conferido com uma linha de base de teste, como usuário sem privilégios: anotação com `-m`, registro com `-r`, recusa quando uma saída foi alterada, e as três saídas do `compara` (PASS, comparação não feita e FAIL).

- **Rotinas longas divididas em etapas (R-FASE4-01).** As quatro rotinas da pendência 7 do `docs/estado-do-projeto.md` passam a ser uma sequência curta de chamadas a procedimentos de módulo com argumentos explícitos e `intent` declarado. Nenhum cálculo muda: as instruções são as mesmas, só mudaram de procedimento; as mensagens de log e os textos gravados nos arquivos também são os mesmos.

  | Rotina | Linhas antes | Linhas depois | Etapas |
  | --- | --- | --- | --- |
  | `med_write_import_fields` (`med_cap_netcdf.F90`) | 358 | 115 | `local_field_shape`, `define_import_file`, `gather_ocean_mask`, `internal_field_ptr`, `gather_field_global` |
  | `write_mpas_import_diag` (`mpas_cap_netcdf.F90`) | 383 | 146 | `gather_boundary_member`, `define_import_diag_file`, `write_import_diag_fields`, `bin_masked_field`, `binarize_ocean_mask`, `log_mask_coverage` |
  | `mpas_atm_init` (`mpas_atm_model.F90`) | 572 | 72 | `setup_mpas_domain`, `setup_mpas_streams`, `bind_mesh_fields`, `bind_diag_fields`, `setup_wind_fallback`, `init_flux_buffers`, `init_boundary_arrays` |
  | `InitializeRealize` do oceano (`mom_cap_MONAN.F90`) | 388 | 70 | `init_fms_time`, `get_ocean_domain`, `alloc_ice_ocean_boundary`, `create_ocean_grid`, `realize_ocean_fields` |

  - `med_write_import_fields`: sai a leitura das coordenadas da grade (`ESMF_GridGetCoord`), cujo resultado não era usado. Os desvios `goto 999` viram retornos das etapas; o tratamento de erro é o mesmo (fecha o arquivo, registra `ERRO NetCDF` e devolve sucesso).
  - `write_mpas_import_diag`: os sete vetores reunidos no PET 0 passam a ser colunas de um único buffer, indexadas pelas constantes `IMP_*`; o limiar `OMASK_MIN` passa a constante do módulo. Sai a variável `ts_str`, que era escrita e nunca lida.
  - `mpas_atm_init` e `InitializeRealize` do oceano, que só compilam na Jaci: os trechos foram movidos sem alteração de instruções, conferido pela comparação das instruções antes e depois (só aparecem as chamadas e declarações novas). Saem sete variáveis sem uso do `InitializeRealize` (`dirs`, `param_file`, `n`, `isd`, `ied`, `jsd`, `jed`) e o comentário que descrevia a construção por `ESMF_Mesh`, abandonada.
  - Conferência local: os fontes que não dependem das bibliotecas dos modelos compilam sem aviso com ESMF 8.9.1; `mpas_atm_model.F90` e `mom_cap_MONAN.F90` foram compilados contra interfaces mínimas do MPAS, MOM6 e FMS, validadas antes com a versão anterior dos arquivos. Um programa de teste com 4 PETs e dados sintéticos chamou os dois gravadores com o código antigo e com o novo: os quatro arquivos NetCDF gravados são idênticos byte a byte, e as mensagens de log também.
  - Validação na Jaci (rodada R-FASE4-01, 152 PETs, 24 passos): 73 arquivos iguais à linha de base R-NOFMA-02, 0 só com metadados diferentes, PASS.

- **Documentação de passagem (R-FASE3-04).** Novo `docs/estado-do-projeto.md`, com o ambiente, as etapas validadas, as linhas de base, o roteiro de validação, as armadilhas encontradas e as pendências. O `valida_rodada.bash` e o roteiro de validação passam a usar a linha de base R-NOFMA-02 como padrão.

- **Comentários sem marcas de histórico (R-FASE3-03).** Retiradas de 482 linhas de comentário, em 17 arquivos, as marcas de correção e de etapa (`FIX B-OCNGRID-01`, `BUG-NC-03`, `B-45`, `Sprint A (Maio 2026)` e semelhantes), que já estão neste CHANGELOG e no histórico do git. O texto explicativo foi mantido; linhas que só continham a marca foram removidas. Conferido arquivo a arquivo que as instruções de código, descontados espaços e comentários, são as mesmas de antes; mensagens de log não foram alteradas.
  - `valida_rodada.bash compara`: mostra sempre a linha de contagem e o veredito PASS/FAIL, com um resumo, por prefixo de arquivo, dos arquivos que diferem só nos metadados.

- **Módulo comum dos gravadores NetCDF (R-FASE3-02).** Novo `src/shared/nc_writer.F90` com `nc_create`, `nc_global_header`, `nc_def_latlon`, `nc_def_field2d` e `nc_ok` (falha do NetCDF registrada no log com a mensagem de `nf90_strerror`). Os quatro gravadores de diagnóstico passam a usá-lo para criar o arquivo, gravar o cabeçalho CF, definir os eixos e definir os campos: exportação da atmosfera e diagnóstico de importação da atmosfera (`mpas_cap_netcdf.F90`), importação do oceano no mediador (`med_cap_netcdf.F90`) e oceano de dados (`docn_cap_netcdf.F90`). Os dados gravados não mudam. Nos metadados:
  - diagnóstico de importação da atmosfera e oceano de dados: `lat` e `lon` ganham `long_name`, `standard_name` e `axis`, como já tinham os outros dois gravadores;
  - oceano de dados: ganha o atributo global `source`, e a dimensão `lat` passa a ser definida antes de `lon`;
  - nos demais casos muda só a ordem dos atributos.

- **Calendário do gravador NetCDF do cap atmosférico pelo ESMF (R-FASE3-01).** O instante inicial gravado em `time:units` ("seconds since ...") dos arquivos `monan_export_*.nc` era calculado por uma conta manual de datas que não recuava para o mês anterior: com o instante atual em 1º de abril e 1 dia decorrido, gravava "2026-04-00"; em 2 de abril com 3 dias, "2026-04--1". Passa a ser calculado com `ESMF_Time` e calendário gregoriano (`start_time_from_elapsed`); saem `datetime_add_seconds` e `is_leap_year`. Conferido contra a conta antiga em 8 casos: resultado igual quando o intervalo não cruza o início do mês (caso da linha de base), correto quando cruza. Só o atributo `units` da variável `time` muda, e só nesses casos.
  - `compute_instantaneous_fluxes` (`mpas_atm_model.F90`): `n` e `atm_public` passam a `intent(in)`, porque só são lidos.

- **Inicialização do mediador e mapeamento do cap atmosférico em etapas (R-FASE2B-03).**
  - `InitializeRealize` do mediador passou de 359 para 62 linhas de código próprias, com as etapas `create_atm_grid`, `create_ocn_grid`, `realize_component_fields` e `create_internal_fields`, procedimentos de módulo com argumentos explícitos. A decomposição da grade em blocos por PET, que estava escrita duas vezes (grade ATM e grade OCN), virou a função `grid_regdecomp`.
  - `state_set_field_1d` do cap atmosférico passou de 243 para 106 linhas: o mapeamento das células do MPAS para a grade regular (acumulação, redução entre processos, média, preenchimento de lacunas e cópia para o campo local) virou o procedimento `map_cells_to_regular_grid`, com 7 argumentos; as 40 variáveis de trabalho passaram a ser locais dele.
  - Nas etapas que podem terminar com erro, o `rc` volta a indicar sucesso no fim normal da etapa, e quem chama confere o `rc` logo depois da chamada. O comportamento é o de antes: um erro interrompe a rotina que chamou a etapa, e um `rc` de falha tolerado dentro dela não interrompe.

- **Constantes e grade do MOM6 num só lugar (R-FASE2B-02).** Validado sem mudança de resultado: os valores e tipos são os mesmos de antes.
  - Novo `src/shared/coupler_constants.F90`: grade atmosférica do mediador (`ATM_NX` = 360, `ATM_NY` = 180, antes repetida como `NLON`, `NX_G`, `NX_ATM_ZEN`, `NX_MED_ATM` em cinco arquivos), constantes físicas (gravidade, 0 °C, congelamento da água do mar, densidade e calor específico do ar, calor latente, Stefan-Boltzmann, coeficientes da pressão de vapor), `RAD2DEG`, `FILL_VALUE_R8` e `SI_IFRAC_DECAY`. Constantes de mesmo nome e valor diferente (π com 15 algarismos no ângulo zenital; as de `mpas_atm_model.F90`, em precisão do MPAS) ficaram onde estavam, registradas no fim do módulo.
  - Novo `src/shared/mom6_supergrid.F90`: leitura das dimensões, dos centros e dos cantos da grade T do MOM6 a partir do `ocean_hgrid.nc`. Substitui as duas cópias que existiam, `MED_*` em `MED_cap.F90` e `ICE_*` em `sis_cap_MONAN.F90`, que só diferiam nas mensagens de log; o prefixo das mensagens passa a ser um argumento.
  - `tools/dev/valida_rodada.bash`: prepara, submete e compara uma rodada de validação, um comando por vez. Recusa um executável com código de outra instalação. `docs/validacao-refatoracao.md` passa a usá-lo.
  - `run_esmApp.jaci --check` (B-RUN-EXE-02): avisa quando o executável contém código de outra instalação.
  - Correção (R-FASE2B-02-FIX01): com o executável certo, o `grep` dessa verificação não encontra nada e devolve 1; sob `set -euo pipefail` isso encerrava o `--check` logo após a linha do executável, sem mensagem.

- **Procedimentos de módulo com argumentos explícitos (R-FASE2B-01).** Os procedimentos internos criados na eliminação dos BLOCKs passaram a procedimentos de módulo: cada um declara na própria assinatura o que recebe, com `intent(in)` para o que só lê e `intent(inout)` para o que altera (conferido pelo compilador). Variáveis que só um procedimento usava passaram a ser locais dele. Afeta `MED_cap.F90`, `med_bulk_ncar.F90`, `med_cap_netcdf.F90`, `mpas_cap_methods.F90`, `mpas_cap_netcdf.F90`, `mpas_atm_model.F90` e `sis_cap_MONAN.F90`. Nos dois últimos, que não compilam fora da Jaci, os argumentos que não são ponteiros ficaram `intent(inout)`.
  - `MediatorAdvance` dividido em etapas nomeadas: `zero_med_fluxes`, `update_ocean_fields_on_atm_grid`, `update_ice_fraction_from_docn`, `export_to_components` e `stamp_export_fields`, além das que já existiam. Passou de 495 para 310 linhas de código próprias (eram 1 257 antes da refatoração).
  - `compara-linha-base.bash -e`: ignora as saídas que a rodada grava na raiz (`MONAN_DIAG_*.nc`, `reprodiag.nc` e outras), também em linhas de base antigas.
  - `mpas_atm_final`: removida variável sem uso (`ierr`).

- **Compilação sem FMA e ferramentas de validação (R-FASE2A-02).** O código do acoplador passa a ser compilado com `-ffp-contract=off` (variável `FP_CONTRACT` do Makefile 16.1; `make FP_CONTRACT=fast` religa). Motivo: a validação da R-FASE2A-01 mostrou que, com a fusão de multiplicação e soma ligada, a reorganização do código muda o último bit do resultado sem mudar nenhum cálculo. Compilados sem FMA, o código de `ea10fb6` e o da fase 2A deram resultado idêntico nos 73 arquivos comparados. Custo medido: nenhum (142,5 s sem FMA, 144,4 s com, rodada de 1 dia com 152 PETs). A linha de base de referência passa a ser a R-NOFMA-01; a R-REF-00 fica como registro da compilação com FMA. Roteiro em `docs/validacao-refatoracao.md`.
  - `cria-linha-base.bash` (B-BASE-ENTRADA-01): saídas dos modelos gravadas na raiz (`MONAN_DIAG_*.nc`, `ice.nc`, `ocean_month.nc`, `sea_ice_geometry.nc`, `ocean.stats.nc`) e o `reprodiag.nc` deixam de entrar em `entrada/CHECKSUMS.txt`; entradas conhecidas da raiz (`MOM_IC.nc`, `tempsalt.nc`, `ucur.nc`, `vcur.nc` e outras) deixam de gerar aviso de arquivo sem classificação.
  - `compara-linha-base.bash`: opção `-e` confere as entradas pela soma registrada na linha de base.
  - `tests/regrid/Makefile`: o alvo `run` usa o `mpiexec` do Cray PALS quando existir. `regrid_base.F90`: sem o aviso de variável possivelmente não inicializada.
- **Executável alternativo no job PBS (R-RUN-EXE-01).** O `ESMAPP_BIN` era lido só na submissão; o job, que executa o `run_esmApp.jaci` de novo, voltava ao `bin/esmApp`. A variável passa a ir no `#PBS -v`. O cabeçalho do log lia uma variável nunca definida e mostrava `Executável = ?`; agora mostra o caminho e a data do executável usado.
- **Parser de streams do MPAS (R-FASE2A-01-FIX01).** A eliminação do BLOCK em `mpas_atm_init` deixou um bloco `interface` no meio das instruções executáveis (erro de compilação). O trecho virou o procedimento `parse_streams_xml`.
- **Opções do MOM6 e comparação sem estouro de memória (R-FASE1-01-FIX02).** No Makefile, as opções do MOM6 (`-fdefault-real-8`) eram repassadas pelo `make` às dependências dos objetos do MOM6; com `make -j`, fontes do acoplador podiam ser compilados com elas. Os fontes do MOM6 passaram a ter regra própria. O `compara-linha-base.bash` guardava a saída do `nccmp` numa variável e estourava a memória do bash quando o arquivo inteiro diferia (B-CMP-MEM-01).
- **RunSequence truncada (R-FASE1-01-FIX01).** Passado direto como argumento, o construtor `[character(len=...) :: ...]` teve o comprimento reduzido pelo gfortran ao do primeiro elemento, e `MPAS` virou `MPA` (`key does not exist: MPA`). As linhas passam a ser montadas numa variável. A contagem de passos voltou a sair sem espaços, e as mensagens de configuração passaram a ser escritas só pelo processo 0.
- **Validação na Jaci das fases 1 e 2A.** Fase 1: duas rodadas, PASS contra a R-REF-00. Fase 2A: com FMA, duas rodadas idênticas entre si e diferentes da base; sem FMA, PASS contra a rodada original também sem FMA.

- **Interpolação plugável (R-REGRID-01).** Novo diretório `src/regrid/` com um tipo abstrato `regridder_t` e três esquemas: `esmf` (pesos calculados pelo ESMF, com cadeia de métodos), `weights_file` (pesos SCRIP/ESMF lidos de arquivo) e `mpassit` (método do MPASSIT: malha ESMF a partir das células Voronoi do MPAS, método por classe de campo, valor de ausência fora da malha). Um catálogo (`regrid_registry`) permite registrar esquemas novos sem alterar o restante do código, e um gerenciador de rotas (`regrid_manager`) dá nome a cada interpolação, com rota de reserva. Grupo opcional `&nuopc_regrid` em `nuopc.input` troca o esquema de uma rota sem recompilar. Testes em `tests/regrid/` (`make test`). Ver `docs/interpolacao-plugavel.md`.
  - O mediador passa a interpolar só por seis rotas nomeadas (`atm2ocn`, `ocn2atm`, `ocn2atm_sst`, `ocn2atm_ice`, `ocn2atm_landmask`, `atm2ocn_ice`), com as mesmas configurações das chamadas ESMF anteriores. Saem os seis route handles e quatro indicadores do estado interno, as três cópias do regrid das correntes (agora `regrid_ocean_currents`), a cópia inline do preenchimento por vizinhança da SST e `NeighborFillExtrapolate` (agora `neighbor_fill`, único).
  - Mudança de comportamento: a chamada de regrid de `Si_ifrac` em `med_bulk_ncar.F90` (caminho legado, sem SIS2) passa a usar a ordem de soma fixa (`termorder = srcseq`), como todas as outras; antes usava a ordem livre, não reprodutível.
- **Eliminação das construções BLOCK (R-DEBLOCK-01).** Os 109 BLOCKs de 12 arquivos foram removidos. Os 20 que correspondiam a etapas completas viraram procedimentos internos com nome (por exemplo `fill_sst_gaps`, `update_ice_fields_on_atm_grid`, `compute_ice_fluxes`, `compute_instantaneous_fluxes`); nos demais, as declarações foram para o início do procedimento. `MediatorAdvance` passou de 1 257 para 496 linhas de código próprias.
  - Correção encontrada na revisão: em `sis_cap_MONAN.F90`, quando `is%ice%part_size` não estava associado, `update_ice_slow_thermo` e `update_ice_dynamics_trans` eram chamados duas vezes no mesmo passo. Agora são chamados uma vez.

- **Refatoração, fase 1 (R-FASE1-01): código morto, duplicação e remendos.** Mudança estrutural, sem alteração intencional dos resultados numéricos. Detalhes e plano das fases seguintes em `docs/refatoracao-fase1.md`.
  - Novos módulos em `src/shared/`: `coupler_utils.F90` (`ChkErr`, `int_to_str`, `real_to_str`, `str_lower`), `coupler_config.F90` (substitui `src/caps/atmos/mpas_cap_config.F90`; módulo `coupler_config_mod`) e `diag_bitsum.F90` (antes colado dentro de `MED_cap.F90`).
  - Removidos por não serem compilados ou chamados: `ocn_comp_NUOPC.F90`, `upstream/mom_cap.F90`, `upstream/mom_cap_time.F90`, `mpas_atm_wrappers.F90` (o cap ATM passa a usar `mpas_atm_model_mod` diretamente), `mpas_cap_utils.F90`, `config_print`, `mpas_atm_resize`, `RegridOptionalCurrent`, `WriteMOM6ImportDiag`, `fms2esmf_time`, `string_to_date`, 36 variáveis locais sem uso e trechos de código comentado.
  - `DOCN_cap.F90` deixa de ter cópias próprias de `ReadGlobalField`, `ReadOcnFieldInterp` e `WriteDOCNDiag` e usa `docn_cap_netcdf_mod` (1287 para 746 linhas). A checagem de data anterior ao epoch, que só existia numa das cópias, foi preservada.
  - 153 blocos de três linhas com `ESMF_LogFoundError` trocados por `if (ChkErr(rc, __LINE__, __FILE__)) return`.
  - `esm.F90` e `esmApp.F90` reescritos: RunSequences como listas curtas, divisão de PETs em rotina própria, configuração lida uma só vez. As mensagens de log lidas por `tools/` foram mantidas.
  - O mediador e o cap ATM leem a configuração diretamente, sem atributos NUOPC intermediários (`use_mpas_atm`, `use_med_to_mpas`, `DumpFields`, `dt_coupling`, `restart_n`, `stop_ymd`, `stop_tod`).
  - `Makefile` 15.0: regra única por padrão (`vpath`), dependências entre módulos completas (faltavam `mom_cap_MONAN -> docn_cap_netcdf`, `mpas_cap_methods -> mpas_cap_netcdf` e `med_bulk_ncar -> config`), sem recompilação forçada (`FORCE`), `MOM6_LIBDIR` obrigatório.
  - Mudanças de comportamento: `write_diag` de `&nuopc_atm` passa a valer (o driver o forçava para falso); grupo do namelist com erro de sintaxe passa a ser erro fatal; `dt_atm <= 0` passa a ser erro fatal; o `userRc` dos componentes passa a ser verificado no `esmApp`; `use_mommesh` e `restart_n` (sem efeito) geram aviso de chave obsoleta; entrada de `CplList` sem espaço para as opções de reprodutibilidade passa a ser erro.

- **Balanceamento de PETs e reprodutibilidade: regra medida.** Execuções de 24/09/2026 com a atmosfera fixa em 128 PETs estabeleceram o que altera o resultado bit a bit. Redistribuir PETs entre oceano e gelo, mantendo o total (128 + 8 + 8 e 128 + 12 + 4, ambos com 144 PETs), não altera nada, nem na atmosfera nem no estado interno do gelo. Mudar o total (128 + 20 + 4, 152 PETs) altera; a causa mais provável é o mediador, que ocupa todos os PETs. Na prática, cada total de PETs é uma configuração própria, que precisa de sua bateria do `mede-taxa-repro.sh`, e oceano e gelo podem ser redistribuídos livremente dentro dele. As mesmas execuções mediram o oceano como gargalo nesta grade (201 s com 8 PETs, 162 s com 12, 117 s com 20, eficiência de cerca de 83%) e reduziram o job de 24 horas simuladas de 234 s para 158 s. Registrado em `docs/uso-analisa-balanceamento.md` (seção 9 e 9.1), `docs/uso-mede-taxa-repro.md` (seção 9) e `docs/ferramentas.md`.

  Documentado também um efeito colateral do `set-nccmp-jaci.bash`: o `module purge` com que ele começa descarrega o módulo do Python, e o `analisa_balanceamento_pets.py`, que exige Python 3.7 ou mais novo, passa a falhar com `SyntaxError: future feature annotations is not defined`.

- **Documentação das ferramentas de execução e de reprodutibilidade.** Novo catálogo `docs/ferramentas.md`, com todas as ferramentas de `run/` e `tools/`, a pergunta que cada uma responde, o guia correspondente e sequências típicas de uso. Três guias novos cobrem as ferramentas que não tinham documentação: `docs/uso-mede-taxa-repro.md` (baterias de reprodutibilidade, com o stream `reprodiag`, os instrumentos, a leitura do relatório, o checksum exato por PET, o arquivamento e os resultados de referência de 22 e 23/09/2026), `docs/uso-duplas-rodadas-repro.md` (`roda-repro-reprodiag.sh`, `roda_repro_producao.sh`, `roda_repro_datm_mom6.sh`, `roda-repro-mpas-standalone.sh` e `set-nccmp-jaci.bash`) e `docs/uso-gen-metis.md`. O README ganhou a seção de reprodutibilidade binária e a tabela de guias.

  Pontos registrados na documentação que ainda pedem ação: o `roda-repro-reprodiag.sh` tem como padrão de `--runner` um caminho absoluto de uma instalação pessoal; o `coleta-contexto-jaci.sh` e o `stream-reprodiag.xml` são usados, mas não estão no repositório.

- **Grade ESMF do gelo pela decomposição do SIS2 (`B-ICE-DECOMP-01`, commit `a9e6935`).** O cap do SIS2 criava a grade ESMF com uma regra própria (fatoração a partir da raiz quadrada do número de PETs) e supunha, sem conferir, que ela coincidia com o `LAYOUT` escolhido pelo SIS2. Com 4 PETs as duas davam 2 × 2; com 8 PETs o SIS2 escolheu 2 × 4 (blocos 90 × 39) e o cap 4 × 2 (blocos 45 × 78), e o `export_si_ifrac` saiu do array do SIS2 na inicialização (`Index '48' of dimension 2 of array 'is' outside of expected range (1:47)`, em todos os PETs do gelo). Agora cada PET obtém os limites globais do seu bloco com `mpp_get_compute_domain`, os PETs trocam essa informação com `ESMF_VMAllGather`, e a nova rotina `ICE_DecompFromBlocks` monta a grade irregular do `ESMF_GridCreate1PeriDim` (tamanhos por coluna e por linha e mapa bloco → PET), validando cobertura e unicidade; uma conferência final compara, em cada PET, o bloco ESMF com o do SIS2. Mesmo princípio do `FIX-GRID-v5` do cap do oceano.

  Validado na jaci com 144 PETs (128 + 8 + 8): com `#override LAYOUT = 4, 2` (grade idêntica à antiga), resultado idêntico bit a bit à bateria anterior; sem o override (SIS2 em 2 × 4), execução completa e resultado idêntico ao da decomposição 4 × 2, inclusive no estado interno do gelo (5430 checksums inteiros das etapas do ciclo do SIS2). O resultado não depende da divisão do domínio do gelo.

- **`analisa_balanceamento_pets.py` v14.22.** A primeira análise com os três componentes (144 PETs, 128 + 8 + 8) mostrou três limitações do relatório, corrigidas:
  - a métrica "Desbalanceamento" comparava o componente mais lento com o mais rápido; com o gelo presente, sempre muito mais leve, dava números sem significado ("razão 55,71x", "5470,8% de tempo ocioso"). Foi substituída pelo tempo que cada componente passa parado esperando o gargalo, na execução concorrente, e pela participação de cada um no total, nos demais casos;
  - a divisão proporcional podia propor contagens que o modelo não aproveita, como 17 ou 31 PETs para o oceano (primos: o MOM6 só divide em faixas finas). O relatório passa a avaliar cada contagem pelo tamanho dos blocos do oceano e do gelo e pelas células MPAS por PET, e mostra um ajuste prático com a contagem viável mais próxima. As grades são detectadas dos arquivos do MOM6 e do nome `x1.<N>.*` do MPAS, ou informadas por `--ocn-grid` e `--atm-cells`; os limites são ajustáveis por `--min-block` e `--min-cells-per-pet`;
  - a coluna "Chamadas Run" somava todos os PETs; passa a mostrar as chamadas por PET.

  O núcleo não mudou: os tempos e a divisão proporcional são idênticos aos da v14.21, e referências JSON gravadas pela versão anterior continuam comparáveis. O JSON ganhou `<comp>_idle_frac` e `suggested_practical_<comp>_pet_count`. Validado com logs sintéticos no formato do ESMF (os tempos da execução de 144 PETs, uma execução sequencial sem gelo com a linha de layout no formato anterior à v14.20, e um JSON de referência da v14.21). Integrado no commit `09346e2`.

- **Máscara de continentes nos diagnósticos de importação (`B-DIAGMASK-01`).** Os arquivos `mom6_import_*.nc` e `monan2_import_*.nc` passam a mascarar os continentes com a máscara **real** do MOM6 (`ocean_grid%mask2dT`), e não mais com substitutos.

  Até aqui, o continente saía do `mom6_import` como **zero** — os fluxos eram zerados pelo Sprint A.5.1 antes do export. Zero é um valor físico legítimo de fluxo: nem o GrADS nem o pós-processamento tinham como distinguir "fluxo nulo sobre oceano calmo" de "aqui não há oceano", e as células de terra entravam nas estatísticas. No `monan2_import` a situação era pior: só havia o filtro `ocean_frac_min` do binning Voronoi, que mede **cobertura de célula Voronoi por bin** e nada diz sobre terra ou oceano.

  A máscara já existia no mediador desde o `B-LANDMASK-01` (`is%f_omask_atm`, regridada de `So_omask`); o que faltava era levá-la aos dois escritores NetCDF. Ela é exportada sob o StandardName novo `Sx_omask` — prefixo `Sx_` porque o MED já *importa* `So_omask` do oceano, e repetir o nome no `exportState` criaria um par homônimo no mesmo componente; mesmo precedente do `Sx_tsfc`. O cap do MPAS a recebe pelo conector MED→MPAS em `atm_bnd%omask`.

  Célula de terra agora sai como `_FillValue`. A própria máscara é gravada na variável `Sx_omask` (1 = oceano, 0 = terra), para que os scripts não precisem readivinhá-la. O corte binário fica sempre no consumidor final — 0,5 no MED e no cap do MPAS, este depois do binning — e nunca no meio do caminho: binarizar entre dois regrids produz escadinha na linha de costa. No mediador o `MPI_Allreduce(MAX)` opera sobre 0/1, que é inequívoco, ao contrário do MAX sobre `FILL_IMP` usado nos campos.

  **A máscara age apenas nos buffers de escrita.** O `exportState` continua com os zeros do Sprint A.5.1: um `_FillValue` que vazasse para lá viraria forçante do MOM6.

  Corrigidos no mesmo passo dois defeitos encontrados durante o trabalho:
  - `mpas_cap_MONAN.F90::init_import_defaults` — `defaults` é dimensionado por `N_IMP` e o laço percorre `1..N_IMP`, mas `defaults(6)` (`Sf_albedo`, Fase 2.6) nunca foi atribuído: o campo era inicializado com o que houvesse na pilha. Agora vale 0,08, o mesmo default de água aberta usado em `mpas_cap_methods.F90` e `mpas_atm_model.F90`.
  - `postproc_monan2_import.py` — a FONTE 1 procurava apenas `mpas_import_step????.nc`, nome legado que o cap não escreve desde a v4.19. O efeito era silencioso: a FONTE 1 nunca encontrava nada e o script caía sempre na FONTE 2, que **infere** `Sf_zorl` por Charnock em vez de ler o valor real. Passa a aceitar `monan2_import_YYYYMMDD_HHMMSS.nc`, com o padrão antigo como retaguarda.

  Na FONTE 2 do mesmo script, a máscara real substitui o marcador de 271,35 K quando o arquivo a traz. Aquela heurística sempre foi frágil: água aberta genuína no ponto de congelamento — justamente a borda do gelo marinho — cai no mesmo valor e era apagada do mapa junto com o continente.

  **Quebra a linha de base por construção:** células de terra mudam de `0.0` para `-9,99e20` e o `nccmp -d` acusa diferença em todos os campos. Comparar somente as células de oceano contra a base congelada, exigir identidade exata ali, e só então recongelar com rótulo novo. Diferença em célula de oceano indica máscara deslocada — provavelmente convenção de longitude, já que o `mom6_import` usa 0 a 360 e o `monan2_import` usa −180 a +180.

  **Não compilado nem executado.** As modificações foram revisadas, não construídas: falta rodar `make` e conferir a fração de oceano registrada no log contra os ~69,2% que o `domain-mom6.bash` reporta para a grade atual.

- **Componente de gelo marinho (SIS2) integrado ao acoplador.** O SIS2 passa a existir como componente NUOPC próprio (`src/caps/ice/sis_cap_MONAN.F90`), com os conectores `MED -> ICE` e `ICE -> MED`, e não como subcomponente embutido no oceano via `combined_ice_ocean_driver`. Controlado por `use_sis2_dynamic` em `&nuopc_petlayout`; com a chave desligada (o padrão) nada é criado e o sistema é idêntico ao anterior.

  A lógica de partição de PETs foi **reescrita**, e não copiada da origem. Lá o gelo só existia dentro do ramo `if (is_concurrent)`, porque os eixos temporal e espacial ainda estavam colapsados em um só. Aqui ela vive sobre o eixo `pet_layout`, o que faz duas combinações passarem a funcionar: `shared` com gelo, e a sequência sequencial com gelo. Quando o gelo está desligado, `nIce` vale 0 e as contas recaem exatamente na divisão em dois blocos anterior, o que permite exigir saída NetCDF byte-idêntica ao baseline como teste de regressão.

  Regras acrescentadas, no mesmo princípio que motivou a correção do split: configuração lida e jogada fora sem aviso passa a ser erro. `ice_pet_count > 0` exige `use_sis2_dynamic`; `use_sis2_dynamic` exige `use_docn = .false.`; em `split` com gelo, `ice_pet_count` precisa ser explícito, porque o `select` do PBS é montado antes de o driver executar.

  **Pendência conhecida:** o caminho do `Si_ifrac` real do ICE até o MPAS não foi validado. O mediador copia `Si_ifrac_sis2` ponto a ponto, e a cópia só está correta se as grades coincidirem; falta um regrid dedicado, análogo ao `rh_ocn2atm` do `So_t`. Há guarda de formato que preserva o valor anterior e registra aviso quando as formas divergem. Tratar como recurso em avaliação.

- **Relógio compartilhado entre componentes (defeito grave).** `ESMF_Clock` é um tipo por referência. As rotinas que registram componentes passavam `driverClock` direto para `ESMF_GridCompSet`, o que fazia todos os componentes apontarem para o mesmo relógio físico. Como o NUOPC avança o relógio associado a cada componente depois do respectivo `Advance`, com três componentes Model o mesmo relógio recebia até três avanços por ciclo de `dt_coupling`. O sintoma observado foi a escrita de `monan2_import` passar de horária para a cada três horas: exatamente o fator 3 previsto.

  Cada componente e cada conector passa a receber uma cópia independente, criada com `ESMF_ClockCreate(driverClock, rc=rc)`. Ao acrescentar um componente ou conector novo, use `AddModelCompWithClock` ou `AddConnectorWithClock` em vez de chamar `NUOPC_DriverAddComp` diretamente: assim a cópia do relógio vem junto, sem depender de alguém lembrar de repetir o bloco.

- **Origem errada da fração de gelo no cap do SIS2.** O cap lia `Ice%part_size`, campo de fachada do acoplador preenchido apenas no caminho de acoplamento rápido, que nesta configuração permanece zerado. O estado real vive em `Ice%sCS%IST%part_size`, que é o que o próprio SIS2 usa para calcular área e massa; esse tem halos e categorias com base 0, então o deslocamento de índices passou a ser derivado da grade do próprio SIS2. A fórmula também mudou: era `1 - part_size(:,:,1)`, tratando o índice 1 como água aberta, quando o índice 1 é categoria de gelo.

- **`SharePolicyField="share"` indevido na exportação do cap do gelo.** Era o único campo de exportação do sistema a usar essa política. O campo saía correto da origem e chegava zerado ao mediador. Removida na exportação, alinhando ao cap do oceano, que usa `share` apenas nas importações. Do lado do mediador a política foi mantida, porque ali todos os campos de importação a usam e funcionam.

- **Contagem de passos com calendário aproximado (`esmApp.F90`).** O número de passos era estimado com aritmética manual, usando 365 dias por ano e 30 dias por mês, e esse número servia de limite do laço de execução. Para o intervalo de 2026-03-29 a 2026-04-30 dava 31 dias em vez de 32, porque março tem 31 dias, e a simulação parava cerca de 24 h antes da data final configurada. Passou a ser derivado do próprio intervalo ESMF (`stopTime - startTime`), que já respeita o calendário Gregoriano.

- **BUG-NC-06: `So_u`, `So_v` e `Sf_zorl` gravados apenas com `_FillValue`.** Os três campos faziam parte de `export_names` e por isso ganhavam variável no `mom6_import_*.nc`, com dimensões e atributos, mas não constavam de nenhum dos dois `select case` de `med_cap_netcdf.F90`. Caíam no `case default` e eram pulados pelo `cycle` antes de qualquer escrita.

  O modo de falha é o que torna o caso instrutivo: o arquivo passava por `q file` parecendo saudável, com as 18 variáveis listadas, e só se revelava ao tentar plotar, quando o GrADS respondia *all undefined values*. Valor ausente e valor zerado são coisas diferentes, e confundir os dois levou a investigar o oceano e a rotação de grade sem necessidade. O único sinal disponível antes disso era o `long_name` genérico das três variáveis, herdado do mesmo `case default`.

  Corrigido nos dois `select case`, com os campos internos `is%f_uocn_atm`, `is%f_vocn_atm` e `is%f_zorl_atm`. O `case default` passou a registrar aviso no log em vez de pular em silêncio. Conferido por script que os 18 nomes de `export_names` têm mapeamento.

- **Terceiro bloco de nós no `run_esmApp.jaci`.** Com `pet_layout = 'split'` e gelo ativo, o script pedia ao PBS apenas `ATM + OCN` processos, enquanto o `mpiexec` era lançado com o total. Para `-n 8` com atm=4, ocn=2, ice=2 o pedido era de 6 slots para 8 PETs, e o trabalho falharia na largada com mensagem do PALS sem relação aparente com gelo. O bloco do ICE entra no `select` e a opção `--ppn-ice` foi acrescentada por simetria. A ordem dos blocos segue a das faixas de rank atribuídas em `esm.F90`.

- **Endurecimento: o mediador declarava `InitializeDataComplete` sem verificar
  o dado (B-SEQINIT-01, revisto).** O `MED_cap.F90` marcava
  `InitializeDataComplete = "true"` na primeira chamada, incondicionalmente, e
  `NUOPC_IsAtTime` não era invocado em lugar nenhum do projeto. O laço de
  resolução de dependência de dados do driver NUOPC encerrava então após uma
  única passagem, e a correção da inicialização passava a depender inteiramente
  de o oceano já ter escrito `So_t` naquele instante.

  `InitializeDataComplete` foi dividida em duas fases. A fase A (geometria: os
  dois `FieldRegridStore` e a zeragem do `exportState`) roda uma única vez,
  guardada por `is%rh_created`. Entre as duas há um gate: `NUOPC_IsAtTime(So_t,
  startTime)` e, desde a revisão abaixo, também contagem global de células com
  SST em [270,310] K. Enquanto o dado não chega, o mediador declara
  `InitializeDataProgress="true"` e `InitializeDataComplete="false"`, forçando
  nova passagem do laço. A fase B faz o regrid de `So_u`/`So_v`, o regrid de
  `So_t` para `f_sst_atm` e publica a SST de t=0 no `exportState`, de modo que o
  `MED -> MPAS` da mesma passagem entregue SST física em vez de zero.

  **Comportamento observado (2026-08-14, rodadas de 8 PETs em ambos os modos).**
  O gate fecha exatamente uma vez, e o faz igualmente em `sequential` e em
  `concurrent`. Nos dois casos o `DataInitialize` do mediador é chamado ~75 ms
  antes do `InitializeDataComplete` do oceano. A conclusão é que **o laço não
  percorre a `RunSequence`**: ele chama os componentes na ordem de registro, e
  em `SetModelServices` os `NUOPC_DriverAddComp` aparecem como MPAS, MED, OCN —
  o mediador antes do oceano, independentemente do `coupling_mode`.

  Isso corrige uma afirmação anterior desta entrada, que atribuía a espera à
  ordem dos elementos da `RunSequence` e sustentava que o modo concorrente
  funcionava "por acidente de ordenação". Era falso: os dois modos se comportam
  igual neste ponto.

  Registre-se também o escopo real do ganho. Não houve sintoma observado que
  este gate corrija: em ambos os modos o `So_t` do passo 1 já saía correto
  antes dele, porque o conector `OCN -> MED` no topo do passo entrega o campo
  que o `mom_export` do oceano escreveu na inicialização. O gate é defesa contra
  a janela t=0 — o `MED -> MPAS` emitido durante a própria inicialização — e
  contra futuras mudanças de ordem de registro. É prática NUOPC correta, não a
  correção de um defeito flagrado.

  Uma otimização possível, deliberadamente **não** aplicada: registrar o OCN
  antes do MED faria o gate abrir já na primeira passagem. O laço converge em
  duas passagens de qualquer modo, o custo é de microssegundos, e mexer na ordem
  de registro de um driver que funciona não se paga.

- **Endurecimento: o gate aceitava campo carimbado e vazio.** O `mom_cap` aplica
  `NUOPC_SetTimestamp` a todos os campos do `exportState` em laço cego sobre o
  `itemNameList`, sem verificar quais o `mom_export` preencheu; um `So_t` nulo
  passaria no `NUOPC_IsAtTime`. O `MED_cap.F90` passa a exigir também valor
  fisicamente plausível, contando globalmente (`ESMF_VMAllReduce` sobre a VM do
  mediador) as células em [270,310] K — global porque um DE pode legitimamente
  conter apenas terra e gelo. Após cinco iterações sem dado físico, emite aviso
  alto e prossegue. O aviso é deliberado, e não aborto: o comportamento do laço
  de dependência de dados só foi caracterizado empiricamente, e derrubar
  execuções que hoje funcionam com base em modelo incompleto seria imprudente.

- **`mom_cap_MONAN.F90`: chamada de `ocean_model_init_sfc` antes do
  `mom_export` de t=0.** Acrescentada por precaução, **não** por defeito
  observado. A leitura estática sugeria que `ocean_public%t_surf` nunca era
  preenchido, já que a chamada de `convert_state_to_ocean_type` dentro de
  `ocean_model_init` está guardada por `if (present(gas_fields_ocn))` e o cap
  invoca `ocean_model_init` sem esse argumento. A medição desmentiu: o `So_t`
  bruto chega ao mediador com até 303,8 K, ou seja `t_surf` é preenchido por
  alguma via não identificada. A chamada é idempotente e inofensiva; quem
  preferir árvore mínima pode omiti-la sem consequência.

- **Correção: evaporação saturada quando `psl` é nula (BUG-CALC-06).** Em
  `med_bulk_ncar.F90`, o denominador de `qsat` era `max(psl(i,j), 1.0)` — uma
  proteção contra divisão por zero que produz resultado absurdo em vez de pular
  a célula: com `psl = 0` o divisor vira 1 Pa em lugar de ~101325 Pa, `qsat` sai
  cinco ordens de grandeza alto e `Foxx_evap` satura no clamp de +1e-4 kg/m²/s
  no globo inteiro. O fluxo saturado não ficava no diagnóstico: em
  `coupling_mode='sequential'` o `MED -> OCN` o entregava ao MOM6 antes do
  avanço do oceano. Acrescentada a guarda `if (psl(i,j) < 5.0e4) cycle`,
  simétrica às de `lwdn` (BUG-CALC-03) e `tas` (BUG-CALC-04); pressão ao nível
  do mar nunca desce de ~870 hPa, então 500 hPa é limiar seguro para ausência de
  dado. Confirmado nas figuras de 2026-08-14: `Foxx_evap` zerado no passo 1 e
  fisicamente correto (±8 mm/d, máximos subtropicais) no passo 2.

- **Documentado: o primeiro passo de acoplamento é incompleto nos dois modos.**
  Em `sequential` o mediador é o 3º elemento da `RunSequence` e calcula os
  fluxos antes do primeiro avanço do MPAS; radiação, precipitação e pressão saem
  nulas no passo 1, enquanto momento e calor sensível já são válidos. Em
  `concurrent` o mediador é o último e o arquivo do passo 1 sai completo, mas a
  forçante que o oceano de fato consumiu naquela hora é o `exportState` zerado da
  inicialização, que não aparece em figura alguma. As duas situações são
  simétricas; nenhum dos modos entrega forçante completa na primeira hora. A
  partir do passo 2 tudo está completo, e uma hora de radiação nula é desprezível
  frente à inércia térmica da camada de mistura — daí a opção por documentar em
  vez de chamar radiação na inicialização do MPAS.

- **`postproc_mom6_import.py` v8.3: rodapé de consumo por modo.** A mesma figura
  "passo N" significa coisas diferentes — em `sequential` mostra os fluxos que o
  MOM6 consome naquele passo; em `concurrent`, os do passo seguinte. Comparar
  passo 1 com passo 1 entre modos é erro, e custou uma investigação inteira. O
  script passa a ler `coupling_mode` da `nuopc.input` e anotar o pareamento
  correto (sequencial N+1 × concorrente N) no rodapé de cada figura.

- **Correção (`test-*.bash`): aborto silencioso do `wait` sob `set -e`.** A
  detecção de fim de processo era `wait "$pid" 2>/dev/null; ec=$?`. Como comando
  isolado, um retorno diferente de zero dispara o `set -e` e encerra o script
  antes de `ec` ser avaliado — sem veredito, sem análise, sem mensagem. O único
  caso que os testes existem para diagnosticar era o único que não conseguiam
  relatar. Reescrito como `ec=0; wait "$pid" 2>/dev/null || ec=$?`, e acrescentado
  aviso aos 2 s com as primeiras linhas do stdout, já que morte instantânea é
  lançador recusado ou ambiente incompleto, nunca deadlock.

- **Correção (`test-sequential-split.bash`): faltava a guarda de `LAYOUT` do
  MOM6.** O pré-check validava a partição METIS do MPAS mas não o requisito
  simétrico do oceano. Com `pet_layout='split'` o MOM6 recebe exatamente
  `ocn_pet_count` PETs, e o `mpp_define_domains` aborta se `LAYOUT(1)*LAYOUT(2)`
  não bater — o job morria em ~1 s num rank do bloco OCN, com mensagem que não
  mencionava PET nem LAYOUT, e as verificações seguintes produziam diagnósticos
  enganosos. O script agora lê `LAYOUT` do `MOM_input` e aborta no nó de login,
  sugerindo `--ocn` e `-n` coerentes. Acrescentadas também as formas curtas
  `-q`/`-A`, alinhadas ao `qsub`.

- **Correção (`run_esmApp.jaci`): partição METIS e `select` heterogêneo presos
  ao modo, não ao layout.** Duas decisões consultavam `coupling_mode` quando o
  que importava era `pet_layout`: o dimensionamento da partição METIS do MPAS
  (`atm_pet_count` em split, `-n` em shared) e a guarda `CONC_PER_COMP`, que
  emite o `select` com blocos de nós só-ATM e só-OCN. Com `sequential + split`
  as duas erravam. A guarda `atm_pet_count + ocn_pet_count == -n`, antes restrita
  a `concurrent`, passa a valer para qualquer split. Acrescentada validação de
  `pet_layout` desconhecido e da combinação `concurrent + shared`, ambas com
  aborto ainda no nó de login, e uma linha `ACOPL` ao banner de dentro do job:
  sem ela, um tempo de parede anotado hoje seria ambíguo depois, já que 2176
  PETs podem significar quatro configurações com custos bem diferentes.

- **Correção (`MED_cap.F90`): último `ESMF_VMGetGlobal` dentro de rotina de
  componente.** Em `fill_ifrac_from_oisst`, o `ESMF_VMBroadcast` do arquivo
  OISST era coletivo sobre a VM **global**. Hoje isso funciona por coincidência,
  porque o mediador roda em todos os PETs nos dois layouts, mas era o único
  ponto que não recebera a correção aplicada em `DATM_cap.F90`, `DOCN_cap.F90` e
  `docn_cap_netcdf.F90` na v13.1. Trocado por `ESMF_VMGetCurrent`, que devolve a
  VM do componente e torna `rootPet=0` local ao MED. O modo de falha evitado é
  deadlock, não erro: se o mediador algum dia ganhar uma `petList` própria, os
  PETs de fora nunca entrariam no broadcast e os de dentro ficariam bloqueados.

- **Correção (`esm.F90`): `rc` de `config_read` descartado.** A chamada em
  `SetModelServices` gravava o retorno em `rc`, que a chamada NUOPC seguinte
  sobrescrevia antes de qualquer teste. Um `rc = 2` — configuração inválida —
  passava despercebido nesse ponto. Passa a usar variável própria (`cfg_rc`) e a
  abortar com mensagem no log ESMF.

- **Novo: `test-sequential-split.bash`.** Smoke test da combinação
  `sequential + split`, ao lado do `test-concurrent.bash` e no mesmo padrão de
  duas fases (submissão no nó de login, execução dentro do job). Além das
  verificações herdadas — partição aplicada, inicialização dos três componentes,
  primeiro passo sem deadlock nos coletivos —, inclui a que distingue os dois
  modos: as janelas `Run` de ATM e OCN não podem se sobrepor no tempo. A
  necessidade é direta: `sequential + split` e `concurrent + split` produzem
  exatamente os mesmos conjuntos de PETs, e só os carimbos de tempo dos logs
  separam um do outro; sem essa checagem, um erro que montasse a *RunSequence*
  concorrente passaria como sucesso. A medição une as janelas de cada bloco de
  PETs (as de PETs irmãos se sobrepõem entre si, e isso é esperado) e mede a
  interseção das duas uniões, com tolerância ajustável por `--overlap-tol`.
  Requer `python3` no nó de execução; sem ele a verificação é pulada com aviso,
  e as demais seguem valendo. O teste também avisa quando falta o
  `x1.*.graph.info.part.<atm>`, cuja ausência apareceria como `initfail` sem
  indicar a causa.

- **Correção (`test-concurrent.bash`): baseline quebrado pela nova validação.**
  O `--baseline` gerava uma config `sequential` **com** `atm_pet_count` e
  `ocn_pet_count`, que passou a ser erro. O `gen_config` ganhou um terceiro
  argumento (`layout`) e zera as contagens em `shared`. Os marcadores de log
  procurados foram atualizados para o formato novo (`layout SPLIT (execucao
  CONCURRENT)`), mantendo o antigo por alternativa, para que o mesmo teste sirva
  na comparação com binários anteriores.

- **Correção (`analisa_balanceamento_pets.py`): detecção de modo cega ao novo
  formato de log.** As expressões procuravam `modo CONCURRENT` / `modo
  SEQUENTIAL`, que deixaram de existir. Passa a ler os dois eixos separadamente,
  aceitando também o formato antigo. Duas mudanças de conteúdo, e não só de
  sintaxe: a ressalva de extrapolação da partição sugerida passou a depender do
  *layout* (é `shared` que mede cada componente com todos os PETs, e portanto
  extrapola; `sequential + split` já fornece medidas de uma partição real); e a
  execução deixou de ser inferida quando não anunciada, porque conjuntos
  disjuntos de PETs não distinguem sequencial de concorrente, e assumir
  concorrente faria o relatório anunciar um ganho de tempo de parede
  possivelmente inexistente.

- **Documentação: `nuopc.input`, README e demais documentos sincronizados.** O
  Grupo 7 da `nuopc.input` foi reescrito com a tabela das quatro combinações e
  as duas regras (soma igual a `-n` em split; contagens zeradas em shared), e o
  bloco ativo ganhou `pet_layout = 'split'`, que é o que torna coerentes o
  `atm_pet_count = 2048` e o `ocn_pet_count = 128` que já estavam ali. A §6.2 do
  README do `MONAN-Coupler` foi reescrita em
  `README-secao-6.2-atualizada.md` (o arquivo alvo pertence à outra árvore).
  Ajustadas ainda as menções a "modo concurrent" em `domain-mom6.md`,
  `domain-mom6.bash` e `mascara-cap-nuopc.md`, onde o que se descrevia era, na
  verdade, o efeito do *layout*.

- **Documentação: seções de Conclusão em `SMT-Jaci.md` e
  `MULTINO-run_esmApp.md`.** Os dois documentos terminavam direto no glossário,
  sem fechar a narrativa antes do material de referência. Acrescentada, em cada
  um, uma seção **Conclusão** entre o corpo técnico e o glossário, com as
  seções seguintes renumeradas (`SMT-Jaci.md`: Glossário passa a ser a seção
  11 e Referências internas a 12; `MULTINO-run_esmApp.md`: Glossário passa a
  ser a seção 10). Nenhuma referência cruzada de seção, em nenhum documento,
  apontava para os números antigos, então a renumeração não quebrou nada.
- **Correção de tradução: `alocação preguiçosa` → `alocação por demanda`.**
  A tradução literal de *lazy allocation* soava informal e não é o termo
  consagrado na literatura de sistemas operacionais em português. Corrigido em
  `SMT-Jaci.md` e neste changelog, mantendo `(*lazy allocation*)` como
  referência entre parênteses nos dois casos.
- **Documentação: `README.md` sincronizado com `docs/`.** A árvore de estrutura
  ainda listava apenas `CHANGELOG.md` e `notas-standalone.md` em `docs/`, quando
  o diretório já reúne seis documentos. Acrescentada a seção **Documentação**,
  com uma tabela do assunto de cada arquivo e um roteiro de "por onde começar"
  por tarefa, além da ressalva de que os scripts descritos em
  `MULTINO-run_esmApp.md` e `SMT-Jaci.md` pertencem à árvore do `MONAN-Coupler`,
  e não a este repositório. Nova seção **Depois de instalar**, que encaminha do
  `bin/esmApp` recém-construído até a primeira submissão, com os três pontos que
  costumam surpreender: a contabilidade de `ncpus` em cores físicos, a partição
  METIS dimensionada por `atm_pet_count` no modo concurrent e a incompatibilidade
  do `mask_table` com o cap NUOPC. Travessões removidos, conforme o padrão do
  projeto.
- **Documentação: nova nota técnica `SMT-Jaci.md`.** Registra a caracterização
  do SMT nos nós de cálculo do Jaci e a medição do seu efeito sobre o sistema
  acoplado, em onze seções: o mecanismo do SMT, a caracterização do hardware com
  os comandos e as saídas obtidas, a contabilidade das filas com a verificação
  experimental por `qsub`, a metodologia da medição, os resultados em tempo de
  parede e em tempo de máquina, a interpretação por componente, as limitações de
  escopo, as decisões decorrentes, o procedimento de reprodução, um glossário e
  as referências internas. Toda a aritmética das tabelas foi conferida.
- **Novo (`run_esmApp.jaci`): `TOPO` e `REGIME` no banner de dentro do job.** As
  duas linhas existiam apenas no resumo impresso no nó de login, que não é
  capturado pela diretiva `#PBS -o` e, portanto, não chegava ao
  `esmApp_run.log`. Sem elas, a autoverificação do `mede_smt.py` ficava inerte
  justamente nas duas checagens mais fortes. O banner do job passa a imprimir a
  topologia derivada do `PBS_NODEFILE` e o regime de ocupação do core. Quando o
  `PBS_NODEFILE` não é legível, o regime é declarado `indeterminado`, e o
  `mede_smt.py` pula a verificação com aviso em vez de acusar troca de
  diretórios. As expressões do `mede_smt.py` passam a aceitar tanto `TOPO:`
  quanto `TOPO =`, cobrindo os dois formatos.
- **Novo (`run_esmApp.jaci`): procedência do build no banner do job.** Um tempo
  de parede anotado hoje não era reproduzível depois, por não haver registro de
  qual revisão do código nem de qual ESMF o produziram. O banner passa a
  imprimir a revisão (`git describe --tags --always --dirty` do
  `COUPLER_ROOT`), a versão do ESMF (lida de `ESMF_VERSION_STRING` no
  `ESMFMKFILE`) e a data de compilação do executável. Tudo tolerante a
  ausência: fora de um clone git, sem `git` no `PATH` ou sem `esmf.mk`, o campo
  vira `?` em vez de interromper o job.
- **Correção (documentação): diagrama impossível na seção 4 do
  `MULTINO-run_esmApp.md`.** O exemplo do nó misto usava `atm=512, ocn=128`,
  mas 512 é múltiplo de 256 e a distribuição natural já sai alinhada, de modo
  que o nó misto ilustrado não pode ocorrer. Substituído por `atm=384,
  ocn=128`, em que a mistura de fato acontece, e acrescentada a observação de
  que a consolidação custa um nó a mais (de dois para três) e de que os blocos
  de 192 ainda atravessam a fronteira NUMA de 128 cores, que é a razão de o
  `plan-layout.py` marcar 384 como quebrado.
- **Documentação: escopo do resultado do SMT.** Acrescentada a subseção
  explicitando que os 11,2% valem para 512 PETs, malha `x1.40962` e modo
  `sequential`, e não são propriedade do sistema. Como o mecanismo é disputa
  pelo cache L2, subdomínios menores (por exemplo com 2176 PETs) podem reduzir
  ou inverter a penalidade, enquanto a malha `x1.163842` a agravaria. Registrada
  também a hipótese não testada de `--ppn-atm 256` com `--ppn-ocn 512` no modo
  concurrent. Novo slide "O que ainda não sabemos" na apresentação, com as
  quatro ressalvas.
- **Novo (`plan-layout.py`): alinhamento com os dois patamares de limite do
  `run_esmApp.jaci`.** O planejador mantinha um único `--ppn-max`, enquanto o
  script já separava `PPN_PHYS` de `PPN_HARD`, e por isso podia imprimir um
  `select` que o script recusaria. Como a razão de existir do planejador é que
  o `select` impresso seja idêntico ao submetido, a divergência atacava a
  premissa da ferramenta. Passa a ter `PPN_PHYS_DEFAULT = 256` e
  `PPN_HARD_DEFAULT = 512`, com `--allow-smt` e a mesma guarda aplicada a
  `--ppn-max`, `--ppn-atm` e `--ppn-ocn`, além da linha `regime` na saída, nos
  modos concurrent e sequential. Corrigido também o texto de ajuda de
  `--ppn-ocn`, que anunciava padrão 128 quando o valor é 256.
- **Novo (`mede_smt.py`): autoverificação a partir do conteúdo dos logs.** O
  script confiava apenas no nome do diretório: trocar `logs.A` por `logs.B`
  inverteria a conclusão sem qualquer sinal, num resultado que passou a
  sustentar uma decisão de projeto. Passa a extrair o modo de acoplamento da
  linha `ESM: modo ...` do log de PET e, quando o banner do job estiver
  presente no diretório, a topologia e o regime de ocupação do core. Com isso
  aborta quando A e B têm números de PETs diferentes, quando os modos divergem,
  quando as rodadas de uma configuração usam números de nós distintos e,
  sobretudo, quando o `REGIME` declarado contradiz a configuração, indicando
  diretórios trocados. Avisa quando as rodadas estão em `CONCURRENT`, modo em
  que o teste do SMT é confundido pelo balanceamento entre os blocos. O número
  de nós lido do banner prevalece sobre `--nos-a` e `--nos-b`, com aviso.
  Verificações ausentes são puladas, nunca inventadas.
- **Novo utilitário (`mede_smt.py`): comparação controlada do efeito do SMT.**
  Lê os logs de PET das rodadas com e sem uso do SMT (padrão `logs.A1..A3` e
  `logs.B1..B3`) e emite a tabela comparativa por componente, com a razão B/A,
  além de CSV (`--csv`) e gráfico de barras (`--grafico`). Segue o critério já
  adotado nas notas técnicas do grupo: **soma** das durações dos pares
  `Run intro` / `Run extro` dentro de cada passo, e não média por chamada, para
  não subestimar componentes que subciclam; e **máximo entre os PETs**, e não
  média, porque o grupo é limitado pelo processo mais lento na barreira
  coletiva. O primeiro passo é descartado por padrão (`--descartar`), por conter
  alocação por demanda e o custo inicial dos conectores. O casamento dos
  marcadores exige o ponto final da linha, o que descarta as linhas de
  `StateLog`, que repetem o texto `Run intro` seguido de `{IS}:` e não delimitam
  a chamada. Avisa sobre marcadores órfãos e sobre divergência no número de
  pares entre PETs, truncando no mínimo comum. O veredito é declarado
  inconclusivo quando a diferença não supera a dispersão das repetições.
  **Normalização pelo número de nós.** Na primeira versão o script comparava
  apenas *wall-clock time*, o que embute um confundimento sério: com o mesmo
  número de PETs, B usa metade dos nós de A e, portanto, metade dos cores
  físicos, de modo que B seria 2,00 vezes mais lento mesmo com SMT
  perfeitamente neutro. O efeito atribuível ao SMT é o excesso sobre esse
  fator. O script passa a reportar também o custo em **nó vezes segundo por
  passo** (opções `--nos-a` e `--nos-b`), que é a grandeza comparável entre as
  duas configurações, e o veredito separa *wall-clock time* de custo de máquina.
  **Propagação de erro corrigida.** A incerteza da razão era calculada como
  `(dp_A + dp_B) / media_A`, dividindo o desvio de B pela média de A. Como B e A
  têm magnitudes diferentes por construção (B é cerca de duas vezes maior), isso
  inflava o ruído: os 12,5% relatados eram, de fato, 7,7% em soma linear ou 5,4%
  em quadratura. O cálculo passa a dividir cada desvio pela sua própria média, e
  o veredito ganhou o estado intermediário `MARGINAL`, para efeitos que superam
  o critério em quadratura mas não a soma linear.
  Na medição de 06/08/2026 (512 PETs, três repetições), o *wall-clock time* deu
  B/A = 2,22, mas o custo de máquina deu 1,11, com sinais opostos por
  componente: MED 0,97 e OCN 0,86, que se beneficiam do SMT por terem mais
  espera de memória, contra MPAS 1,20, penalizado por já saturar a FPU. Como o
  MPAS responde por cerca de 69% do passo, o saldo é negativo, e o efeito de
  11,2% supera a incerteza de 7,7%.
  O reconhecimento dos logs aceita tanto `PET000.esmApp.log`, que é o nome
  gerado pelo ESMF no Jaci, quanto `PET000_esmApp.log`, variante que aparece
  após transferências, e exige o número do PET no nome, o que descarta o
  `esmApp_run.log` presente no mesmo diretório. A ordenação é numérica, e não
  lexicográfica. A opção `--padrao` permite informar outro glob, e a mensagem de
  erro passa a distinguir diretório inexistente de diretório sem logs
  reconhecidos, listando o que encontrou.
- **Novo (`run_esmApp.jaci`): `--allow-smt` e limite de PET/nó parametrizado.**
  A constante única `PPN_MAX=256` colapsava dois conceitos distintos, o que o
  hardware aceita e o que se recomenda, e por isso impedia qualquer medição do
  efeito do SMT. Passam a existir `PPN_PHYS=256` (cores físicos, limite
  recomendado e padrão) e `PPN_HARD=512` (CPUs lógicas, limite absoluto do
  hardware). Valores de `--ppn` entre 257 e 512 exigem `--allow-smt` e, sem a
  opção, o script aborta explicando que acima de 256 cada core passa a receber
  dois ranks. Acima de 512 o erro é o limite do hardware, com ou sem a opção. O
  modo automático (`--ppn 0`) nunca ultrapassa `PPN_PHYS`, de modo que o padrão
  jamais entra em SMT por acidente. O resumo de topologia ganhou a linha
  `REGIME`, que registra se o job rodou com um rank por core ou com SMT ativo:
  sem ela, um *wall-clock time* anotado hoje seria ambíguo depois, já que 512 PETs
  podem significar dois nós ou um nó com SMT. A guarda de fila não precisou de
  ajuste, pois compara `NPES` com `resources_max.ncpus` e a aritmética fecha nos
  dois regimes.
- **Correção (`run_esmApp.jaci`): partição METIS dimensionada pelo número
  errado em modo concurrent.** Com `-n 2176` e `atm_pet_count = 2048` o
  pré-check exigia `x1.*.graph.info.part.2176` em vez de `.part.2048`, que
  estava presente no diretório do experimento. A lógica de escolha estava
  correta (sequential usa `-n`, concurrent usa `atm_pet_count`); o defeito era
  a leitura da `nuopc.input`, que caía silenciosamente para `sequential` em
  três situações:
  - **Caixa do valor.** `_nuopc_get` usava `grep -i` para a chave mas comparava
    o valor com `== "concurrent"`, sensível a maiúsculas. `'CONCURRENT'` ou
    `'Concurrent'`, ambos válidos em namelist Fortran, viravam sequential. O
    valor passa a ser normalizado para minúsculas.
  - **Ausência de escopo de grupo.** A busca era global no arquivo, com
    `head -1`, então uma ocorrência de `coupling_mode` anterior ao
    `&nuopc_petlayout` (grupo antigo, bloco de exemplo) vencia a definição
    real. Novo `_nuopc_get_in`, que lê a chave **dentro** do grupo indicado,
    insensível a caixa, ignorando comentários `!` e aceitando os terminadores
    `/` e `&end`, com recuo para a busca global em `nuopc.input` legados sem o
    grupo.
  - **Recuo silencioso.** Um `coupling_mode` com erro de digitação virava
    sequential sem qualquer sinal. Agora é erro explícito, listando os valores
    aceitos.
  Acrescentadas duas linhas `INFO` informando de onde saiu o número de
  partições (`atm_pet_count` em concurrent, `-n` em sequential), e a mensagem
  de partição faltante passa a listar as partições presentes no diretório,
  distinguindo "falta gerar" de "dimensionado pelo número errado".
- **Execução multinó no `run_esmApp.jaci`: contabilidade de `ncpus` e posse do
  nó.** O gerador do `.pbs` deriva a topologia de `-n` (`NNODES x PPN`,
  `place=...`), substituindo o antigo `select=1`, que prendia qualquer job a um
  único nó. O levantamento do sítio (`lscpu`, `pbsnodes -a`, `qstat -Qf`,
  05/08/2026) fixou os parâmetros: o nó de cálculo `cn-0001..cn-0104` tem
  **256 cores físicos** (2 sockets x 128 Zen5) com SMT ligado, expondo 512 CPUs
  lógicos e ~754 GB, e o `pbsnodes` reporta `resources_available.ncpus = 512`.
  O limite das filas, porém, é contado em **cores físicos**: a `pesqextra`
  declara `resources_max.ncpus = 7680` para `resources_max.nodes = 30`, isto é
  256 por nó, e os jobs em execução aparecem com `ncpus/nodect = 256`. Logo o
  `select` mantém `ncpus = mpiprocs = PPN <= 256`; pedir `ncpus = 512` gastaria
  o limite da fila em dobro e limitaria o job a 15 nós em vez de 30.
  - **`place=scatter:excl` passa a ser o padrão** (antes `scatter`). Reservando
    256 num nó que anuncia 512 lógicos, o `scatter` puro deixa metade do nó
    aparentemente livre e autoriza o PBS a alocar outro job ali, com disputa de
    memória e de largura de banda no mesmo socket. Com `:excl` o nó é exclusivo
    e o SMT fica ocioso, que é o desejado para MPAS/MOM6.
  - **Guarda de fila.** Constantes `QUEUE_LIMITS_*` e a rotina `_queue_guard`
    conferem NPES, número de nós e *walltime* contra o `resources_max` da fila
    antes do `qsub`, abortando com mensagem explícita. Fila desconhecida gera
    aviso e prossegue. Limite prático do acoplado na `pesqextra`:
    30 nós x 256 PET/nó = 7680 PETs, coincidindo com o `resources_max.ncpus`.
  - **Padrão de 256 PET/nó** (nó físico cheio, 1 rank por core, sem SMT) e
    **sem reserva de memória**: `--mem` e `--mem-per-pet` são opcionais, e a
    resposta a OOM (`exit 137/143`) é reduzir `--ppn` ou reservar `--mem`.
    Novas opções `--ppn`, `--place`, `--mem`, `--mem-per-pet`.
  - **Modo concurrent com consolidação por componente:** `select` heterogêneo
    alinhado a fronteiras de nó, de modo que nenhum nó fique misto (ATM+OCN);
    opções `--ppn-atm`, `--ppn-ocn` e `--pet-order`.
  - **Nós auxiliares documentados:** `aux01..aux10`, com `ncpus = 256` e
    ~1,5 TB, alcançados pela fila `aux` (`worktype = aux`). Destinam-se a pré e
    pós-processamento (geração de malha, particionamento METIS), não ao
    acoplado. O roteamento entre classes de nó é feito pelo recurso `worktype`,
    o que explica o `Qlist` vazio no `pbsnodes`.
- **Novo utilitário (`plan-layout.py`): planejador de topologia.** Reproduz,
  fora do job, a lógica de consolidação do `run_esmApp.jaci`, imprimindo o
  mesmo `select`, para escolher `atm_pet_count` e `ocn_pet_count` antes de
  editar a `nuopc.input`. Modos `--atm/--ocn`, `--total` com `--ratio`,
  `--sweep`, `--suggest` e `--sequential`. Acompanha a mesma tabela de limites
  de fila (opção `--queue`, padrão `pesqextra`), com o status `excede fila` na
  varredura. Corrigido o padrão de `--ppn-ocn 0`, que resolvia para metade do
  nó em vez de nó cheio, divergindo do `run_esmApp.jaci`.
- **Documentação.** Novo `docs/MULTINO-run_esmApp.md` (hardware do sítio,
  contabilidade de `ncpus`, topologia sequential e concurrent, tabela de filas
  e limites, planejador, boas práticas e glossário) e as subseções
  correspondentes no `README-MONAN-Coupler.md`. Acrescentado o critério de
  alinhamento NUMA: com 2 domínios de 128 cores por nó, cortes de
  `atm_pet_count`/`ocn_pet_count` em múltiplos de 128 mantêm cada componente
  dentro de sockets inteiros.
- **Correção (`mom_cap_MONAN.F90`): campos de importação sem estampilha de
  tempo.** No primeiro passo de acoplamento, o `CheckImportTolerant` comparava
  o `TimeStamp` de cada campo importado sem que ele tivesse sido definido: na
  RunSequence o OCN roda antes do conector MED para OCN, e o
  `NUOPC_GetTimestamp` do NUOPC 8.9.1 retorna `ESMF_SUCCESS` sem preencher o
  `ESMF_Time` (não existe o argumento `isValid=`). O resultado eram dois
  `ERROR` por campo (`ESMF_TimeLT` e `ESMF_TimeGT`, "Object Set or SetDefault
  method not called"), 28 linhas por execução com 14 campos importados. Sem
  efeito numérico, mas poluindo o log e mascarando erros reais. A
  `InitializeDataComplete` passa a estampilhar os campos de importação com
  `startTime`, como já fazia com os de exportação.
- **Correção (`domain-mom6.bash`): saída incoerente em `--no-mask`.** A coluna
  `PETs` da tabela de candidatos era sempre calculada como
  `NIPROC * NJPROC - Nmask`, mesmo em `--no-mask`, exibindo 121 para o `16x8`
  quando o resultado efetivo, informado três linhas abaixo, era 128. Agora a
  coluna respeita o modo, o rótulo da coluna de blocos secos alterna entre
  `MASCAR.` (eliminados) e `SECOS` (mantidos), e uma nota sob a tabela explicita
  que em `--no-mask` a contagem é informativa. Corrigido também o exemplo do
  `--help` e do cabeçalho, que apresentava `--target-eff` como receita para um
  run concorrente, justamente a configuração incompatível com o cap; o exemplo
  do acoplado passa a usar `--no-mask --pes N`, e o do `--target-eff` fica
  identificado como standalone. Colunas documentadas em `docs/domain-mom6.md`,
  seção 7.2.
- **Ressalva em aberto (`domain-mom6.bash`): convenção de fronteiras difere da
  do FMS.** O script distribui as sobras da divisão nos primeiros blocos; o
  `mpp_compute_extent` as distribui simetricamente (`Y-AXIS = 53 52 53` para
  158 pontos em 3 blocos, contra `53 53 52` do script). As fronteiras internas
  ficam deslocadas em um ponto e o conjunto de blocos secos pode divergir: em
  `15x9` o script marca `(8,8)` onde o FMS teria `(9,7)`. **No acoplado com
  `--no-mask` o efeito é nulo** (nenhum `mask_table` é lido); no uso standalone,
  porém, um bloco com oceano pode ser mascarado por engano. A distribuição
  simétrica está comprovada pelo log, mas o algoritmo exato ainda não foi
  conferido contra o fonte do `mpp_domains_mod`. Documentado em
  `docs/domain-mom6.md`, seção 5.
- **Documentação.** Novo `docs/mascara-cap-nuopc.md`, explicação didática e
  autocontida do problema da máscara: glossário PE/PET/DE, por que o split de
  comunicador não está envolvido, a diferença entre representação densa e
  esparsa no ESMF, como reconhecer o sintoma e as duas rotas de correção do
  cap, com a estimativa de ganho por número de PETs. A seção 2 do
  `docs/domain-mom6.md` foi reduzida a um resumo com ponteiro para ele.
- **Correção (incidente do LAYOUT 43x3, 22/07/2026).** Run de 256 PETs em modo
  concorrente (128 ATM + 128 OCN) abortava com SIGSEGV no PET 171 logo após
  `COMPLETED MOM INITIALIZATION`. Causa: o `mask_table` gerado para
  `LAYOUT = 43, 3` remove o bloco `(1,3)` da decomposição, e o cap NUOPC do
  MOM6 monta o `deBlockList` do `ESMF_Grid` apenas com os domínios dos PETs
  vivos. O espaço de índices `[1..180] x [1..158]` fica com um buraco de
  5 x 53 células; `ESMF_DistGridCreate` e `ESMF_GridCreate` aceitam em
  silêncio, e a falha só emerge no conector `OCN-TO-MED`, em
  `ESMF_GridToMesh`: `ESMCI_Mesh.C, line:1786: Bad processor number!`.
  - Configuração corrigida: `LAYOUT = 16, 8` (produto exato = 128 PETs do OCN)
    com `MASKTABLE` comentado em `MOM_input` e `SIS_input`.
  - `domain-mom6.bash`: **filtro de forma** com `--min-tile` (padrão 9, que é
    `2*NIHALO+1`, o halo do domínio `MOM_MOSAIC`) e `--max-aspect` (padrão
    4,0). O `43x3` tinha blocos de 4,2 pontos, menores que o próprio halo, e
    passava sem qualquer alerta.
  - `domain-mom6.bash`: a varredura do `--target-eff` deixa de aceitar o
    primeiro `EFF` que bate. O novo modo `scan` do awk devolve todos os pares
    de fatores aprovados no filtro para cada nº de blocos, e vence o de melhor
    forma em **toda** a faixa. Na grade 180 x 158, o alvo 128 passa a resolver
    para `15x9` (blocos de 12,0 x 17,6; nmask = 7) em vez de `43x3`.
  - `domain-mom6.bash`: novo `--no-mask`, que escolhe o melhor `LAYOUT` com
    produto exatamente igual aos PETs do oceano e não gera `mask_table`,
    comentando com `!` uma diretiva `MASKTABLE` remanescente nos arquivos de
    entrada. É o único modo compatível com o cap NUOPC atual.
  - `domain-mom6.bash`: aviso explícito sempre que um `mask_table` com
    `nmask > 0` é produzido, indicando que ele serve ao MOM6+SIS2 standalone,
    não ao acoplado.
  - Pendência em `mom_cap_MONAN.F90`: para suportar `mask_table`, o
    `deBlockList` precisa cobrir todo o espaço de índices, com DEs adicionais
    para os blocos mascarados mapeados a PETs existentes via `petMap`
    (o `ESMF_DELayout` aceita mais de um DE por PET).
- **Novo utilitário (`domain-mom6.bash`): decomposição de domínio do MOM6+SIS2.**
  Calcula um `LAYOUT` (NIPROC, NJPROC) equilibrado e gera o `mask_table` do FMS,
  eliminando os blocos 100% terra. Os PETs efetivos passam a ser
  `EFF = NIPROC * NJPROC - Nmask`, valor que deve casar com os PETs que o
  oceano realmente recebe (o total do run em `sequential`; apenas
  `ocn_pet_count` em `concurrent`), evitando o erro fatal
  `fms2_io(parse_mask_table_2d): mpp_npes() .NE. layout(1)*layout(2) - nmask`.
  - Três modos: `--pes N` (fatora N e ordena os candidatos por razão de aspecto,
    divisão exata e tamanho mínimo de bloco), `--layout NI,NJ` (explícito) e
    `--target-eff N` (varre `--pes N..N+search-range` até obter `EFF` exato,
    já que o nº de blocos mascarados depende da **forma** do `LAYOUT`, não só
    do produto).
  - Implementação **100% shell**: `ncdump` (módulo `cray-netcdf`) e `awk`
    (POSIX), sem dependência de Python, numpy ou netCDF4. Não depende do
    `COUPLER_ROOT` nem do ESMF: opera apenas sobre a topografia.
  - Núcleo: **soma de prefixos 2D** (imagem integral) do campo binário de
    oceano, construída uma única vez; a contagem de oceano em cada bloco
    candidato custa O(1), o que viabiliza a varredura do `--target-eff`.
  - Detecção automática da variável (`depth`, `D`, `wet`, `mask`, ou
    `--depth-var`) e das dimensões pelas duas últimas da declaração (robusto a
    `ny,nx` / `lat,lon` / `grid_y,grid_x`). Limiar de oceano por `--min-depth`
    para profundidade e 0,5 para máscara.
  - Integração opcional com o experimento: `--input-dir` copia o `mask_table`
    para `INPUT/`; `--mom-input`/`--sis-input` reescrevem `LAYOUT` e
    `MASKTABLE` com backup `.bak.<timestamp>`; `--dry-run` suprime cópia e
    edição (o `mask_table`, sendo o próprio resultado do cálculo, ainda é
    gravado). Avisos para blocos pequenos, divisão inexata e `Nmask = 0`.
  - Reaproveita o `include.bash` do instalador para o log padronizado, com
    *fallback* próprio quando ausente.
- **Documentação.** Novo `docs/domain-mom6.md` (algoritmo detalhado: soma de
  prefixos, escore dos candidatos, formato do `mask_table`, custo e armadilhas)
  e `README.md` com a subseção "Decomposição de domínio do MOM6+SIS2", logo
  após as partições METIS do MPAS, mais as entradas correspondentes na árvore
  de estrutura e na tabela "Onde mexer".

- **Correção (ESMF externo no MONAN-A).** A etapa 1 falhava ao compilar
  `mpas_timekeeping.F` (`timeStringISOFrac`/`h=` não reconhecidos) porque o
  `-DMPAS_EXTERNAL_ESMF_LIB` resolvia `use ESMF` para o *stub* interno do MPAS
  (`src/external/esmf_time_f90`) em vez do ESMF 8.9.1 real. O Makefile do
  MONAN-Model só injeta o ESMF real quando `ESMF_MOD` e `ESMF_LIBDIR` estão no
  ambiente — e os scripts não as exportavam.
  - `sites/site-jaci.bash` e `sites/site-template.bash`: passam a **derivar e
    exportar** `ESMF_MOD` (dir do `esmf.mod`, via `ESMF_F90COMPILEPATHS`) e
    `ESMF_LIBDIR` (dir da `libesmf`, via `-L` de `ESMF_F90LINKPATHS`, com
    *fallback* no diretório do próprio `esmf.mk`) — fonte única, em bloco
    auto-contido (vale também para `source run/setenv-gnu.bash`). Não se usa a
    variável `ESMF_LIBDIR` do `esmf.mk`: ela não existe em todo build do ESMF.
  - `1-monan.bash`: deixa de recalcular; apenas **verifica** as variáveis
    (`check_var`) e aborta com mensagem clara se faltarem.
  - `2-mom.bash`: **consome** o `ESMF_LIBDIR` do sítio para o `LD_LIBRARY_PATH`;
    `ESMF_APPSDIR` passa a ser tolerante a vazio (apenas avisa). O helper
    `_esmf_mk` é mantido para as flags canônicas do cap NUOPC (Passo 3).
- **Correção (toolchain GNU na etapa 3 e no rebuild manual).** O `make all` do
  acoplador falhava com o `ftn` acionando o compilador Cray (CCE) e rejeitando
  os flags GNU do Makefile (`-mcmodel=small`, `-ffree-line-length-none`,
  `-fallow-argument-mismatch`, …). Causa: o `run/setenv-gnu.bash` só definia
  caminhos (não carregava módulos) e fazia `unset MODULES_MONAN`; como cada
  etapa roda em subprocesso, o `PrgEnv-gnu` das etapas 1-2 não persistia.
  - `run/setenv-gnu.bash` (repo `MONAN-Coupler`): passa a **carregar os módulos**
    (`module purge` + `MODULES_MONAN` do sítio — PrgEnv-gnu + hdf5 + netcdf +
    parallel-netcdf + METIS) logo após o *source* da config, antes do
    `PNETCDF_DIR`. Como é *sourced*, os módulos persistem na sessão — isso conserta
    também o **rebuild manual** do README (`source run/setenv-gnu.bash && make`).
    Opt-out: `export SETENV_NO_MODULES=1`. (Entregue como `setenv-gnu.patch`.)
  - `3-coupler.bash`: **delega** os módulos ao setenv (sem `load_modules`
    redundante) e adiciona uma **guarda de toolchain** — confere `PE_ENV=GNU`
    (var padrão do Cray PE) após o *source* e aborta cedo, com mensagem clara, se
    o `PrgEnv-gnu` não estiver ativo (ex.: setenv-gnu.bash desatualizado).
- Organização: `docs/` (changelog + notas), `sites/site-template.bash`
  (esqueleto para nova máquina) e `Makefile` fino (atalhos: `make`,
  `make download`, `make build`, `make check`, `make help`).
- Passos renomeados (nomes mais curtos, sem "install" redundante):
  `1-install-monan.bash`→`1-monan.bash`, `2-install-mom.bash`→`2-mom.bash`,
  `3-install-coupler.bash`→`3-coupler.bash`.

## Histórico do cap atmosférico (`mpas_cap_MONAN.F90`, versões 7.0 a 9.2, e `mpas_cap_netcdf.F90`, versões 2.5 a 3.0, Maio 2026)

Resumo do histórico que ficava nos cabeçalhos dos arquivos, retirado na R-FASE5-04.

- **`mpas_cap_MONAN` 7.0**: protocolo NUOPC completo via `NUOPC_CompDerive` (InitializeAdvertise, InitializeDataComplete). **7.1**: `mpas_atm_resize` eliminado (ESMF e MPAS usam decomposições distintas). **7.2**: coordenadas do NetCDF por `lonCell(1:n_local)`, sem `ownedElemCoords` (double-free no ESMF 8.9.1 em Cray/gfortran).
- **`mpas_cap_MONAN` 8.0**: importação estendida de So_t para So_t, Si_ifrac, So_u e So_v (antes gelo e correntes usavam valores fixos). **9.0**: importação de Sf_zorl (Charnock + Smith no mediador), no lugar de `cfg_zorl_default` = 0,01 m. **9.2**: `set_mpas_diag_clock` passou para `mpas_cap_netcdf`. Depois vieram Sf_albedo, Sx_omask e a troca de So_t por Sx_tsfc.
- **`mpas_cap_netcdf` 2.5**: conversão dos campos acumulados movida para `mpas_atm_model.F90` (a divisão pelo tempo total desde t=0 dava a média errada depois do primeiro passo) e limiar de outlier de Faxa_taux/tauy de 1e4 para 10 N/m². **2.6**: timestamp duplo em `export_write_netcdf` corrigido (usa o currTime de ModelRun). **2.8**: decomposição MPI salva em `netcdf_init_coords` e reutilizada na escrita. **3.0**: `write_mpas_import_diag`, `set_mpas_diag_clock` e `voronoi_to_grid` vieram de `mpas_cap_methods.F90`.

## Histórico do cap do oceano (`mom_cap_MONAN.F90`, versões 2.0 a 2.6, Maio 2026)

Resumo do histórico que ficava no cabeçalho do arquivo, retirado na R-FASE5-03.

- **2.0**: acoplamento real com o MOM6, no lugar do stub sintético (SST constante de 290 K).
- **2.1**: `Si_ifrac` por uma sigmoide da SST, no lugar do proxy binário (gelo onde frazil > 0 ou SST ≤ T_freeze). **2.1.1**: guarda por `mask2dT` (continentes com `Si_ifrac` = 0).
- **2.2**: com `use_docn_ice`, `Si_ifrac` lido do arquivo OISST (`set_si_ifrac_from_file`, interpolação temporal por `ReadOcnFieldInterp`); a sigmoide fica como alternativa.
- **2.3**: `docn_ice_init_only`: OISST só em t=0 e, depois, a sigmoide da SST dinâmica do MOM6.
- **2.4**: largura da sigmoide `DT_TRANS` de 0,5 K para 2,0 K (com 0,5 K, a SST polar de 278 a 282 K logo após o primeiro passo zerava o proxy) e contribuição do frazil contínua, `min(1, frazil/100 W/m²)`, no lugar da binária.
- **2.5**: persistência entre passos, `Si_ifrac(t) = max(proxy(t), Si_ifrac(t-1) × SI_IFRAC_DECAY)`; sem ela, o gelo do OISST caía de 7918 para 38 células no primeiro passo.
- **2.6**: `si_ifrac_mem` salvo depois do preenchimento do campo e fora da guarda de PET, e logs que confirmam se a persistência está ativa.

## v14.15 — Jun 2026

- Repositório do instalador renomeado de `MONAN-Coupler-install` para
  **`Coupler-Install`**.
- Configuração de sítio de sessão movida para `<COUPLER_ROOT>/run/setenv-site.bash`
  (remove a necessidade de um diretório `install/` na árvore do acoplador).
- `setenv-gnu.bash` endurecido: refaz a busca da config quando `SITE_ENV`
  aponta para arquivo inexistente (evita herdar valor obsoleto de um `source`
  anterior que falhou).

## v14.14 — Jun 2026

- Renomeação dos pontos de entrada: `bootstrap.bash`→**`install.bash`**
  (baixa + instala) e `install-all.bash`→**`build.bash`** (só as 3 etapas).
- Biblioteca de funções `install-libs.bash`→**`include.bash`** (é *sourced*).
- Layout organizado: `sites/` (configs por máquina) e `templates/` (mkmf).

## v14.13 — Jun 2026

- Instalador separado em repositório próprio, independente do sistema acoplado.
- `MONAN-Model` e `MOM6-examples` passam a ser **submódulos** do `MONAN-Coupler`
  (clone recursivo na branch `develop`).
- `install.bash` faz o download recursivo do sistema e dispara a instalação.
- Resolvedores tolerantes a layout (`resolve_coupler_root`, `resolve_site_env`,
  `resolve_mkmf_template`) e busca de submódulos (`ensure_model_tree`).

## Anterior — Jun 2026

- Reestruturação de caminhos para o layout multi-modelo
  (`models/atmos/MONAN-Model`, `models/ocean/MOM6-examples`).
- Pipeline de instalação em três etapas (MONAN-A, MOM6+SIS2, acoplador).
