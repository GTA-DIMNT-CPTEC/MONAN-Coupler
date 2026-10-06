# tests/log-traduzido.sed: mensagens do mediador como a R-FASE13-10 as grava.
#
# Os testes que comparam o log com o de uma versão anterior (bulk,
# completar, malhas, gravadores) passam o log dessa versão por este script (sed -E -f)
# antes da comparação. Cada regra troca o texto antigo de uma mensagem
# pelo novo, sem mexer nos números; assim, a comparação confere que cada
# mensagem continua saindo, no mesmo ponto e com os mesmos valores.
# Mensagens que não mudaram não têm regra.

# MED_cap
s/MED: use_med_to_mpas=true, RouteOcnToAtm ativo/MED: use_med_to_mpas=true: contorno da atmosfera pelo mediador/

# med_bulk_ncar
s/MED: AVISO BUG-CALC-DUU: uocn\/vocn nulos — So_duu10n calculado com vento absoluto/MED: uocn\/vocn nulos: So_duu10n calculado com o vento absoluto/
s/MED Sprint C: Sf_zorl calculado via Charnock \+ Smith/MED: Sf_zorl calculado por Charnock + Smith/
s/MED\(Fase3-ICE\): Fioi_taux\/tauy\/sen\/evap\/lwnet calculados com T_gelo real \(nao mais SST\)/MED: Fioi_taux\/tauy\/sen\/evap\/lwnet calculados com a temperatura do gelo/
s/MED\(Fase3-ICE\): f_tice_atm nao associado — Fioi_\* permanecem no fallback inicial/MED: f_tice_atm nao associado: Fioi_* ficam com o valor inicial/
s/FIX-DIAG-ICESTAB-01: /MED: DIAG ice_stability: /
s/MED\(bulk_ncar\): f_ifrac_atm\/f_alb_\*_ice nao associados — SW usa albedo_ocn constante \(sem Fase 2\/4\)/MED: f_ifrac_atm\/f_alb_*_ice nao associados: onda curta com albedo_ocn constante/

# med_cap_netcdf
s/MED: mom6_output\.nml nao encontrado — diag import desabilitado/MED: mom6_output.nml nao encontrado: diag import desabilitado/
s/MED: mom6_output\.nml lido — diag import = /MED: mom6_output.nml lido: diag import = /
s/MED:med_write_import_fields: ERRO NetCDF /MED: med_write_import_fields: erro NetCDF /
s/MED:med_write_import_fields: AVISO — mascara So_omask vazia ou indisponivel; continentes NAO serao/MED: med_write_import_fields: mascara So_omask vazia ou indisponivel; continentes nao serao/
s/MED:med_write_import_fields: AVISO — campo "/MED: med_write_import_fields: campo "/
s/MED:med_write_import_fields: (MPI comm|dimensoes|escrito)/MED: med_write_import_fields: \1/
s/MED B-DIAGMASK-01: mascara do diagnostico — oceano /MED: mascara do diagnostico: oceano /

# med_diag e somas de bits (diag_bitsum)
s/FIX-DIAG-BITSUM-01: etapa4 Si_ifrac ausente do exportState; etapa NAO medida/MED: DIAG ice_fraction bitsum etapa4: Si_ifrac ausente do exportState; etapa nao medida/
s/FIX-DIAG-BITSUM-01: etapa1 Si_ifrac_sis2 ORIGEM pre-regrid /MED: DIAG ice_fraction bitsum etapa1 origem /
s/FIX-DIAG-BITSUM-01: etapa2 f_ifrac_atm DESTINO pos-regrid /MED: DIAG ice_fraction bitsum etapa2 pos-interpolacao /
s/FIX-DIAG-BITSUM-01: etapa3 f_ifrac_atm pos-extrapolacao /MED: DIAG ice_fraction bitsum etapa3 pos-extrapolacao /
s/FIX-DIAG-BITSUM-01: etapa4 Si_ifrac exportState para MPAS /MED: DIAG ice_fraction bitsum etapa4 exportState /

# med_exchange
s/MED: IDC — So_t carimbado mas SEM valor fisico/MED: IDC: So_t carimbado mas sem valor fisico/
s/MED: IDC — So_t com /MED: IDC: So_t com /
s/MED: AVISO — So_t sem valores fisicos apos varias iteracoes do laco de dependencia de dados; prosseguindo\./MED: So_t sem valores fisicos apos varias iteracoes do laco de dependencia de dados; prosseguindo. A SST em t=0 pode estar nula: com log_level='debug', inspecione "DIAG sst raw" no passo 1 antes de confiar nos fluxos./
/  A SST em t=0 pode estar nula\. Inspecione /d
s/MED: IDC aguardando So_t do OCN — nova/MED: IDC aguardando So_t do OCN: nova/
s/MED: IDC — regrid So_t->ATM falhou; mantido/MED: IDC: interpolacao de So_t para a ATM falhou; mantido/
s/MED: IDC — RegridOrCopy So_t falhou/MED: IDC: RegridOrCopy So_t falhou/
s/MED: So_omask indisponivel no importState - usando fallback por limiar de SST/MED: So_omask indisponivel no importState: mascara pelo limiar de SST/
s/FIX-DIAG-ICEMASK-01: /MED: DIAG ocean_mask: /
s/MED: RouteOcnToAtm retornou erro — continuando/MED: carimbo do relogio no exportState falhou; continuando/
s/MED RouteOcnToAtm: rota ocn2atm ainda nao criada; pulando/MED: carimbo do relogio: rota ocn2atm ainda nao criada; pulando/
s/MED RouteOcnToAtm: regrid OCN->ATM concluido \(Fase 2\)/MED: exportState carimbado com o tempo do relogio/

# med_export
s/MED: RegridOrCopy Sx_tsfc FALHOU — exportState mantem fallback \(ver FillInternalField f_tsfc_atm\)/MED: RegridOrCopy Sx_tsfc falhou: exportState mantem o valor inicial (FillInternalField de f_tsfc_atm)/
s/MED: RegridOrCopy So_(u|v) FALHOU — exportState mantem zeros/MED: RegridOrCopy So_\1 falhou: exportState mantem zeros/
s/MED: RegridOrCopy Sf_zorl FALHOU — exportState mantem default 0\.01 m/MED: RegridOrCopy Sf_zorl falhou: exportState mantem 0.01 m/
s/MED\(B-TSFC-DUALEXPORT-01\): AVISO — ponteiros de So_t\/Si_t_sis2\/Si_ifrac indisponiveis, Sx_tsfc degradado para SST pura/MED: ponteiros de So_t\/Si_t_sis2\/Si_ifrac indisponiveis: Sx_tsfc so com a SST/
s/MED Sprint A\.5\.1: fluxos zerados em ([0-9]+) celulas de terra \(mascara real So_omask, ver B-LANDMASK-01\)/MED: fluxos zerados em \1 celulas de terra (mascara So_omask)/
s/MED: mascara terra\/oceano real regridada para a grade ATM/MED: mascara terra\/oceano interpolada para a grade ATM/
s/MED: falha no regrid da mascara So_omask; mantido tudo-oceano \(1\.0\)/MED: rota ocn2atm_landmask ausente: mascara mantida em tudo oceano (1.0)/
s/MED B-LANDMASK-01: So_omask indisponivel -- mantendo fallback tudo-oceano \(1\.0\)/MED: So_omask indisponivel: mascara mantida em tudo oceano (1.0)/

# med_flux
s/MED: PET sem dados MPAS locais — skip bulk \(B-45\)/MED: PET sem dados MPAS locais: bulk pulado/
s/MED: Usando MPAS como fonte atmosferica primaria/MED: forcante atmosferica do MPAS/
s/MED: Usando DATM \(JRA55\) como fonte atmosferica \(fallback\)/MED: forcante atmosferica do DATM (JRA55)/
s/MED: Sa_shum_mpas ausente \(Fase 2\) -- usando SHUM_DEFAULT=0\.010 kg\/kg/MED: Sa_shum_mpas ausente: umidade SHUM_OCEAN_DEFAULT/
s/MED: Faxa_snow_mpas ausente \(Fase 2\) -- precipitacao solida = 0\.0/MED: Faxa_snow_mpas ausente: precipitacao solida = 0.0/
s/MED\(Fase3\): fluxos nativos MONAN-A \(sen\/evap\/taux\/tauy\) aplicados sobre o resultado do bulk NCAR/MED: fluxos nativos do MONAN-A (sen\/evap\/taux\/tauy) aplicados sobre o resultado do bulk NCAR/
s/MED\(Fase3\): Faxa_sen\/lat\/taux\/tauy_mpas ausentes -- mantendo bulk NCAR \(calc_bulk_ncar\) para sen\/evap\/taux\/tauy/MED: Faxa_sen\/lat\/taux\/tauy_mpas ausentes: sen\/evap\/taux\/tauy do bulk NCAR/

# med_ice (diagnósticos agora em med_diag)
s/MED\(B-ICEREGRID-01\): Si_ifrac_sis2\/Si_a\*_sis2\/Si_t_sis2 regridados via rh_ocn2atm_ice \+ extrapolacao de vizinhanca/MED: Si_ifrac_sis2, Si_a*_sis2 e Si_t_sis2 interpolados pela rota ocn2atm_ice e completados por vizinhanca/
s/FIX-DIAG-ICESRC-01: Si_ifrac_sis2 \(ORIGEM, pre-regrid\) min=/MED: DIAG ice_fraction source: Si_ifrac_sis2 min=/
s/FIX-DIAG-ICESRC-01: farrayPtr de Si_ifrac_sis2 indisponivel; origem NAO medida/MED: DIAG ice_fraction source: Si_ifrac_sis2 indisponivel; origem nao medida/
s/FIX-DIAG-ICESRC-02: f_ifrac_atm \(DESTINO, pos-regrid\) max=/MED: DIAG ice_fraction destination: max=/
s/FIX-DIAG-ICEMASK-02: ifrac \(bruto, pre-extrapolacao\) min=(.*) \| n_exact_zero=(.*) de n_total=/MED: DIAG ice_fraction raw: min=\1 n_exact_zero=\2 n_total=/
s/FIX-DIAG-ICEGEO-01: ALERTA -- ([0-9]+) celula\(s\) com ifrac>0,05 em \|lat\|<55 \(implausivel\)\. Primeira ocorrencia: lat=/MED: gelo em latitude implausivel: \1 celula(s) com ifrac>0,05 em |lat|<55; primeira: lat=/

# med_init
s/MED B-CONSERVE-01: stagger CORNER da grade (ATM|OCN) preenchido \(sem erro ate aqui\)/MED: stagger CORNER da grade \1 preenchido/
s/FIX-DIAG-CONSERVE02-01: ALERTA -- celula quase degenerada encontrada perto do polo /MED: grade OCN: celula quase degenerada perto do polo /
s/FIX-DIAG-CONSERVE02-01: ALERTA -- salto de longitude muito maior que a media entre vizinhos na linha mais ao norte \(possivel fold mal capturado ou descontinuidade de indice\)/MED: grade OCN: salto de longitude muito maior que a media entre vizinhos na linha mais ao norte (dobra mal capturada ou descontinuidade de indice)/

# med_ocean
s/MED B-OCNGRID-02 DIAG: So_t BRUTO \(OCN, DE local\) i=\[/MED: DIAG sst raw: DE local i=[/
s/(PET[0-9]+) +sst_raw\(i1,j1\)=/\1 MED: DIAG sst raw: sst_raw(i1,j1)=/
s/MED\(B\.1\.1\): Si_ifrac decaimento aplicado \(SI_IFRAC_DECAY_MED=0\.9592\)/MED: Si_ifrac: decaimento SI_IFRAC_DECAY aplicado/
s/MED Sprint A\.5\.2: Si_ifrac zerado em ([0-9]+) celulas terra \(mascara T_FILL_LAND\)/MED: Si_ifrac zerado em \1 celulas de terra (SST no marcador de terra)/
s/MED: Si_ifrac regridado do SIS2 \+ mascara terra \(A\.5\.2\)/MED: Si_ifrac interpolado pela rota ocn2atm, com a mascara de terra/
s/MED: Si_ifrac calculado via limiar SST \(fallback — Sprint A\.5\.2\)/MED: Si_ifrac calculado pelo limiar de SST/
s/MED\(Alt1\): f_ifrac_atm preenchido de /MED: f_ifrac_atm preenchido de /

# ---- R-FASE13-11: caps dos modelos ----

# DATM_cap
s/DATM ReadJRAFieldInterp: currTime anterior ao epochTime!/DATM: ReadJRAFieldInterp: currTime anterior ao epochTime/
s/(PET[0-9]+ +)ReadGlobalField: /\1DATM: ReadGlobalField: /

# rotinas dos caps do MPAS: nome sem parênteses, com a marca ATM
s/(PET[0-9]+ +)\((mpas_import|mpas_export|mpas_create_grid|state_diagnose|state_get_field_1d|state_set_field_1d|write_mpas_import_diag|netcdf_init_coords|export_write_netcdf)\): /\1ATM: \2: /

# mpas_adapter
s/ATM: mpas_import: importacao Fase 2 concluida /ATM: mpas_import: importacao concluida /
s/ATM: mpas_create_grid: ESMF_Grid 360x180 criada \(sem MOAB\)/ATM: mpas_create_grid: ESMF_Grid 360x180 criada/
s/(PET[0-9]+) +([A-Za-z]+_[A-Za-z0-9_]+  min=)/\1 ATM:   \2/

# mpas_cap_MONAN
s/mpas_cap: SetServices concluido \(v7\.0 NUOPC_CompDerive\)/ATM: SetServices concluido/
s/\(mpas_cap:InitializeAdvertise\): anunciados/ATM: InitializeAdvertise: anunciados/
s/\(mpas_cap:verify_import_connected\): todos/ATM: verify_import_connected: todos/
s/(PET[0-9]+ +)\(mpas_cap:[A-Za-z0-9_]+\): /\1ATM: /

# mpas_cap_netcdf
s/ATM: netcdf_init_coords: ([0-9]+) células — interpolação lat\/lon ativa/ATM: netcdf_init_coords: \1 celulas; interpolacao lat\/lon ativa/

# mpas_cell_binning
s/(PET[0-9]+ +)##### BUG-SPARSE-02 v7\.6 ATIVO ##### campo=/\1ATM: DIAG cell_binning fill: campo=/
s/ATM: state_set_field_1d: falha (ESMF_VMGetCurrent|ESMF_VMGet mpiCommunicator) no gather Voronoi \(state_set_field_1d\)/ATM: state_set_field_1d: falha \1 no gather Voronoi/
s/ATM: state_set_field_1d: falha ESMF_VMGet mpiCommunicator no gather Voronoi \(state_set_field_1d\)/ATM: state_set_field_1d: falha ESMF_VMGet mpiCommunicator no gather Voronoi/

# mpas_import_diag
s/(PET[0-9]+ +)B-DIAGMASK-01: monan2_import mascarado — oceano /\1ATM: mascara do diagnostico do monan2_import: oceano /

# sis_cap_MONAN e sis_cap_fields
s/ICE\(SIS2\): B-ICE-DECOMP-01 - grade ESMF /ICE: grade ESMF /
s/ICE\(SIS2\): AVISO — Ice%part_size nao associado apos ice_model_init; usando ncat=1 como fallback \(provavelmente ERRADO, precisa investigar\)/ICE: Ice%part_size nao associado apos ice_model_init; usando ncat=1 (provavelmente errado)/
s/ICE\(SIS2\): Faxa_coszen nao encontrado no importState — is%aib%coszen permanece 0 \(mediador antigo\?\)/ICE: Faxa_coszen nao encontrado no importState: is%aib%coszen permanece 0/
s/ICE\(SIS2\): Ice%sCS nao associado \(slow ice PE ausente\?\) — Si_ifrac=0/ICE: Ice%sCS nao associado (slow ice PE ausente?): Si_ifrac=0/
s/ICE\(SIS2\): Ice%part_size\/albedo_\* nao associados — Si_a\*_sis2 = fallback constante/ICE: Ice%part_size\/albedo_* nao associados: Si_a*_sis2 constantes/
s/ICE\(SIS2\): Ice%part_size\/t_surf nao associados — Si_t_sis2 = fallback \(ponto de congelamento\)/ICE: Ice%part_size\/t_surf nao associados: Si_t_sis2 no ponto de congelamento/
s/ICE\(SIS2\): /ICE: /

# DOCN_cap e docn_cap_netcdf
s/DOCN: AVISO: WriteDOCNDiag falhou — continuando/DOCN: WriteDOCNDiag falhou; continuando/
s/DOCN: AVISO: falha uo — corrente zonal = 0/DOCN: falha uo: corrente zonal = 0/
s/DOCN: AVISO: falha vo — corrente meridional = 0/DOCN: falha vo: corrente meridional = 0/
s/ReadGlobalField DOCN: ERRO B-59 — ordem de eixos incompativel! /DOCN: ReadGlobalField: ordem de eixos incompativel. /
s/ReadGlobalField DOCN: /DOCN: ReadGlobalField: /
s/DOCN ReadOcnFieldInterp: /DOCN: ReadOcnFieldInterp: /
s/(PET[0-9]+ +)WriteDOCNDiag: (.*) \[B-58v2\]$/\1DOCN: WriteDOCNDiag: \2/
s/(PET[0-9]+ +)WriteDOCNDiag: /\1DOCN: WriteDOCNDiag: /

# mom_cap_MONAN e mom_si_ifrac
s/OCN\(MOM6\): domínio local /OCN: dominio local /
s/OCN\(MOM6\): PET land-only — mesh com 0 elementos/OCN: PET so com terra: mesh com 0 elementos/
s/OCN: ERRO — ntiles \/= 1 não suportado em ESMF_Grid/OCN: ntiles \/= 1 nao suportado em ESMF_Grid/
s/OCN\(MOM6\): ocean_model_init_sfc — t_surf/OCN: ocean_model_init_sfc: t_surf/
s/OCN\(MOM6\): IDC — SST/OCN: IDC: SST/
s/OCN\(MOM6\): CheckImport WARNING — timestamp fora da janela ±dt para campo /OCN: CheckImport: carimbo de tempo fora da janela +-dt para o campo /
s/OCN\(Alt1\): ERRO ReadOcnFieldInterp/OCN: set_si_ifrac_from_file: ReadOcnFieldInterp falhou/
s/OCN\(Alt1\): si_ifrac_mem salvo — bounds=/OCN: si_ifrac_mem salvo: bounds=/
s/OCN\(MOM6\): Si_ifrac sem ocean_grid — retornando zeros/OCN: Si_ifrac sem ocean_grid: zeros/
s/OCN\(proxy\): si_ifrac_mem_valid=T — aplicando persistencia/OCN: si_ifrac_mem_valid=T: aplicando persistencia/
s/OCN\(proxy\): si_ifrac_mem_valid=F — sem persistencia/OCN: si_ifrac_mem_valid=F: sem persistencia/
s/OCN\(MOM6\): Si_ifrac via sigmoide DT_TRANS=2K \+ frazil contínuo \(v2\.3\)/OCN: Si_ifrac pela sigmoide DT_TRANS=2K + frazil continuo/
s/OCN\((MOM6|Alt1)\): /OCN: /

# ---- R-FASE13-12: driver, coupling, regrid e shared ----

# mom6_supergrid (marca do componente no lugar do rótulo)
s/MED B-OCNGRID-01 DIAG: DE /MED: DIAG supergrid tcoords: DE /
s/ICE\(SIS2\) DIAG: DE /ICE: DIAG supergrid tcoords: DE /
s/MOM6 supergrid DIAG: DE /OCN: DIAG supergrid tcoords: DE /
s/(PET[0-9]+ +)([A-Z]) DIAG: DE /\1\2: DIAG supergrid tcoords: DE /
s/MED B-(OCNGRID|CONSERVE)-01: /MED: /
s/MOM6 supergrid: /OCN: /
s/: AVISO - nx\/ny impar em /: nx\/ny impar em /

# driver, cpl_check e regrid
s/ESM: ERRO particao split invalida: /ESM: particao split invalida: /
s/ESM: ([0-9]+) entrada\(s\) de CplList sem espaco para as opcoes/ESM: \1 entrada(s) de CplList sem espaco para as opcoes/
s/para o metodo do mapa; aumentar len em cpl_escreve_metodos/para o metodo do mapa; aumentar len em cpl_write_methods/
s/(PET[0-9]+ +)cpl_check: conferencia do mapa com /\1ESM: cpl_check: conferencia do mapa com /
s/(PET[0-9]+ +)mpas_mesh_create: /\1regrid: mpas_mesh_create: /
