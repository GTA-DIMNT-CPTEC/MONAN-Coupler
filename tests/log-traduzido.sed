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
