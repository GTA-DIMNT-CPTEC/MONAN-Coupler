# Histórico dos scripts de pós-processamento e ferramentas

Este arquivo guarda, sem alteração, os blocos de histórico que ficavam
no cabeçalho (docstring) dos scripts Python de `tools/`. Eles foram
retirados do código na etapa R-FASE5-07 para que o cabeçalho descreva
apenas o que o script faz hoje. As referências a versões, datas e
identificadores de correção (BUG-PY-nn, B-nn, [En], [Nn]) são as da
época em que cada texto foi escrito.

O histórico do código Fortran está em `docs/CHANGELOG.md`.

## `tools/postproc/postproc_mom6_import.py`

```text
Versão 8.6 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Set 2026

HISTÓRICO DE CORREÇÕES
  v8.6 — Limiares de sen/evap alinhados ao fluxo nativo do MPAS-A (Set 2026):
    • BUG-PY-20: Foxx_sen e Foxx_evap entregues ao MOM6 são os fluxos de
      superfície NATIVOS do MPAS-A (MED_cap.F90 Fase 3 sobrescreve o bulk NCAR
      SEM reaplicar clamp), e legitimamente atingem −400…−600 W/m² (sensível) e
      ~25–40 mm/d (latente) em células de corrente de contorno oeste sob ar
      frio. Os limiares antigos (±500 W/m², [−15,200] mm/d) marcavam esses
      extremos físicos como avisos. Alargados para ±800 W/m² e [−40,200] mm/d.
      (Não é clamp de física — apenas o limiar do diagnóstico.)

  v8.5 — Diagnóstico ponderado por área (Set 2026):
    • BUG-ICE-MEAN-LABEL: a linha "média sobre células c/ gelo" do --check
      mostrava, na verdade, a média sobre TODO o oceano (oceano sem gelo é 0.0,
      não fill), dando ~0,16. Agora calcula a média REAL só sobre células com
      gelo (conc≥0,15).
    • BUG-AREA-WEIGHT: numa grade lat/lon, médias/contagens simples super-
      representam os polos (células pequenas e numerosas), inflando SST fria e
      cobertura de gelo. O --check passa a reportar, com peso cos(lat): a SST
      média por área e a cobertura de gelo em % de ÁREA do oceano (≥15% e ≥50%),
      ao lado dos valores por célula. check_physics agora recebe 'lat'.

  v8.4 — Revisão dos scripts de diagnóstico/animação (Set 2026):
    • BUG-PY-16: So_t deixava BURACOS BRANCOS nos polos. O mascaramento usava
                 fill_min_threshold=271.4 K, que apagava água do mar real perto
                 do congelamento (sob o gelo marinho, SST ~271,2–271,4 K) —
                 justamente a borda do gelo. Agora mascara APENAS o marcador-
                 stub pontual (271,35 K ± tol); a terra já vem da máscara real
                 do MOM6 (Sx_omask). vmin_phys recuado 271,4 → 271,0 K.
    • BUG-PY-17: --plot ABORTAVA (URLError) em nó HPC sem internet, pois
                 cfeature.LAND/COASTLINE baixam os shapefiles Natural Earth no
                 desenho. Agora testa a disponibilidade uma vez e, se offline,
                 gera os mapas sem contornos em vez de abortar.
    • BUG-PY-18: escala de cor recalculada POR PASSO (percentis do passo) —
                 causa raiz do GIF "pulsante" e incomparável. Agora vmin/vmax
                 são GLOBAIS (calculados uma vez sobre todos os passos) e a
                 mesma cor significa o mesmo valor em toda a animação.
    • BUG-PY-19: savefig(bbox_inches='tight') gerava PNGs de tamanhos distintos
                 entre passos, fazendo a animação tremer. Removido (figsize fixo
                 + constrained_layout → quadros idênticos).
  v8.2 — BUG-PY-15 (Maio 2026):
    • BUG-PY-15 (A/C): cfeature.LAND ausente em plot_maps.
                 A função adicionava apenas COASTLINE e BORDERS, sem preencher
                 o interior dos continentes.  Isso gerava dois artefatos visuais:
                 1. Patches brancos (NaN transparente sobre fundo branco da figura)
                    em campos oceânicos — Foxx_lwnet, onda curta e precipitação —
                    onde a grade não calcula fluxos sobre terra.
                 2. So_duu10n e outros campos atmosféricos exibiam dados de vento
                    calculados sobre terra sem nenhuma máscara geográfica, tornando
                    o mapa difícil de interpretar.
                 Correção: cfeature.LAND desenhada em zorder=5 (acima do
                 pcolormesh em zorder=1); COASTLINE e BORDERS elevados para
                 zorder=6, mantendo-se visíveis sobre a máscara de terra.
    • BUG-PY-15 (B): fill_min_threshold de So_t elevado de 270.0 K para 271.4 K.
                 O marcador-stub do Sprint A.5 coloca pontos de terra/gelo em
                 271.35 K — acima do limiar antigo (270 K) e por isso não
                 mascarado.  Isso gerava patches azuis retangulares em áreas
                 oceânicas no mapa de SST.
                 271.4 K captura 271.35 K sem mascarar SST oceânica real,
                 cujo mínimo observado é ≈ 271.8 K.
                 vmin_phys atualizado consistentemente para 271.4 K.

  v8.1 — Renomeação de arquivos de saída (Maio 2026):
    • Mapas por passo : import_YYYYMMDD_HHMMSS.png  → mom6_import_YYYYMMDD_HHMMSS.png
    • Série temporal  : import_timeseries.png        → mom6_import_timeseries.png
    Padrão agora consistente com o prefixo dos arquivos NetCDF de entrada
    (mom6_import_*.nc) e com o script de animação anim_mom6_import.py.
  v8.0 — BUG-PY-14 (Maio 2026):
    • BUG-PY-14 (A): Si_ifrac — escala adaptativa em plot_maps.
                 O campo Si_ifrac é binário (0 ou 1). Com vmax=1.0 (padrão),
                 as células polares com gelo (~0.05% da área) são visualmente
                 invisíveis numa projeção global. Detecta automaticamente
                 campos binários (max=1, p95=0) e aplica:
                   vmax_efetivo = max(mean * 30, 0.005)
                 tornando o gelo visível com colorbar interpretável.
                 Paleta alterada para 'Blues' (intensidade de gelo) e
                 annotation com área de gelo estimada.
    • BUG-PY-14 (B): Si_ifrac — série temporal com eixo Y adaptativo.
                 Com escala linear [0, 1], a curva de Si_ifrac (mean ~0.0005)
                 aparece como linha reta no zero. Aplica escala simétrica-log
                 (symlog com linthresh=1e-4) quando o sinal está abaixo de
                 0.1, tornando o crescimento de gelo legível.
    • BUG-PY-14 (C): So_t passo all-NaN — subplot informativo em vez de vazio.
                 Quando So_t é 100% NaN num passo (passo 1: campo indisponível
                 antes do primeiro avanço do MOM6), o subplot era pulado com
                 'continue', deixando espaço em branco desorientador.
                 Agora exibe painel cinza com texto "Campo indisponível /
                 aguardando primeiro passo MOM6" para clareza diagnóstica.
    • BUG-PY-14 (D): So_t — mascaramento do seam tripolar.
                 A grade MOM6 (tripolar) tem uma descontinuidade de longitude
                 que aparece como linha branca vertical no mapa após o roll
                 de 0→360° para -180→180°. Aplica máscara automática de
                 descontinuidade: células onde |Δlon_vizinho| > 90° são
                 mascaradas como NaN antes do pcolormesh, eliminando o artefato
                 sem alterar os dados físicos.
    • BUG-PY-13 (C) rev.2: So_duu10n — vmax_phys calibrado de 900 para 1600 m²/s².
                 Experimentos reais mostram máximos de 967–1459 m²/s² (|ΔV| ≈ 31–38 m/s)
                 em ciclones extratropicais e furacões presentes no campo MPAS — valores
                 fisicamente legítimos que disparavam falsos positivos com 900 m²/s².
                 1600 m²/s² ≡ |ΔV| ≤ 40 m/s: teto físico real para vento em superfície
                 oceânica; acima disso configura artefato numérico.
                 check_msg atualizado para informar o limite e a ação sugerida.

  v7.0 — BUG-PY-13 (Maio 2026):
    • BUG-PY-13 (A): Foxx_lwnet — vmax_phys elevado de 100 W/m² para 150 W/m².
    • BUG-PY-13 (B): So_t — vmin_phys reduzido de 271.0 K para 270.0 K.
    • BUG-PY-13 (C): So_duu10n — vmax_phys inicial de 400 → 900 m²/s² (v7.0),
                 corrigido para 1600 m²/s² em v7.1 após calibração experimental.

  v6.0 — BUG-PY-12 (Maio 2026):
    • BUG-PY-12 (A): fill_min_threshold de So_t elevado de 200 K para 270 K.
                 O stub OCN coloca cells de terra/gelo em ~200.0049 K — logo
                 ACIMA do limiar antigo (200.0 K), provocando os warnings:
                   "⚠ So_t: min=200.0049 < 271.0 [K]" a cada execução.
                 Com 270 K, todos os pontos terra/fill viram NaN antes da
                 estatística e o aviso só aparece se houver SST de fato
                 anômala (a abaixo do ponto de congelamento da água do mar).
    • BUG-PY-12 (B): check_physics suprime aviso redundante de SST em °C.
                 Antes, a falha em K e a derivada em °C geravam DOIS avisos:
                   "⚠ So_t: min=200.0 < 271.0 [K]"
                   "⚠ So_t − 273.15 = [-73.15, 31.19] °C — ..."
                 sobre o MESMO problema. Agora a verificação em °C só roda
                 (e só reporta confirmação ✓) quando a verificação em K já
                 passou.
    • BUG-PY-12 (C): plot_maps silencia RuntimeWarning de slice 100% NaN.
                 np.nanpercentile sobre passo com todos NaN gerava warning
                 "All-NaN slice encountered" mesmo já havendo fallback para
                 limites físicos. Bloco encapsulado em warnings.catch_warnings.
    • BUG-PY-12 (D): plot_timeseries idem — RuntimeWarning de nanmean e
                 nanpercentile sobre slices 100% NaN são intencionais (geram
                 gap natural no matplotlib) e foram silenciados.
    • BUG-PY-12 (E): print_stats agora exibe coluna "Cobert." (percentual
                 de pontos válidos por passo). Permite identificar passos
                 com baixa cobertura de dados — útil para entender quando
                 (sem dados) ou min/max suspeitamente pequenos aparecem.

  v5.0 — BUG-PY-11 / CLEANUP (Maio 2026):
    • BUG-PY-11 (A): imports não utilizados removidos.
                 'timedelta' e 'date' importados mas nunca referenciados.
                 Removidos para clareza e conformidade com PEP 8.
    • BUG-PY-11 (B): código morto em compute_expected_interp.
                 Ternário 'x if hasattr(ts, "date") else y' tinha ramo else
                 inalcançável (ts é sempre datetime → possui .date()).
                 Simplificado para chamada direta: (ts.date() - epoch_date).
    • BUG-PY-11 (C): comentário mal-indentado em plot_maps.
                 Linha '# BUG-PY-07: scale aplicado...' estava dentro do bloco
                 'if flat.size == 0: continue' (código morto). Movido para
                 fora do bloco condicional.

  v4.0 — BUG-PY-08 (Maio 2026):
    • BUG-PY-08 (A/B/C/D/E): scale não aplicado em nenhuma função de saída.
                 print_stats, plot_maps, plot_timeseries e export_csv exibiam
                 dados em unidades SI (kg/m²/s, Pa) com labels de scale_units
                 (mm/d, hPa). Colorbars mostravam 1e-8 em vez de W/m².
                 Corrigido: layer *= scale antes de calcular vmin/vmax/plot.
                 Limites físicos de Faxa_rain/Faxa_snow corrigidos para mm/d.

  v3.0 — BUG-PY-06 (Maio 2026):
    • BUG-PY-06: Referências semânticas ao DOCN corrigidas em todo o script.
                 Os campos dos arquivos mom6_import_*.nc são fluxos ATM→OCN
                 calculados pelo mediador MED_cap.F90 (bulk NCAR), NÃO
                 campos exportados pelo DOCN_cap (So_t, Si_ifrac, So_u, So_v).
                 Corrigido: nome CSV, título de plot, comentários, docstrings.

  v2.0 — BUG-PY-01/02/03 (Maio 2026):
    • BUG-PY-01: padrão de busca corrigido de docn_import_*.nc → mom6_import_*.nc
    • BUG-PY-02: remoção de prefixo corrigida (docn_import_ → mom6_import_)
    • BUG-PY-03: FIELD_META e FIELDS atualizados dos campos DOCN (So_t, Si_ifrac,
                 So_u, So_v) para os 14 campos do exportState MED→OCN:
                 Foxx_taux/tauy, Foxx_sen, Foxx_evap, Foxx_lwnet,
                 Foxx_swnet_vdr/vdf/idr/idf, Faxa_rain/snow,
                 Sa_pslv, Si_ifrac, So_duu10n.
```

## `tools/postproc/postproc_monan2_import.py`

```text
CORREÇÕES v2.5 (diagnóstico ponderado por área)
═══════════════════════════════════════════════════════════════════════════════
  BUG-AREA-WEIGHT: numa grade lat/lon, a fração de gelo por CONTAGEM de células
    super-representa os polos (muitas células pequenas) e infla a "cobertura de
    gelo" (dava ~14–16% das células). A verificação física agora reporta também,
    com peso cos(lat): a cobertura de gelo em % de ÁREA do oceano (>50%), a
    concentração média onde há gelo (≥0,15) e a SST média ponderada por área
    (comparável com a climatologia, ~288–292 K), ao lado dos valores por célula.

CORREÇÕES v2.4 (revisão dos scripts de diagnóstico/animação)
═══════════════════════════════════════════════════════════════════════════════
  BUG-GEO-OFFLINE (mapas abortavam em nó HPC sem internet)
    cfeature.LAND/COASTLINE baixam os shapefiles Natural Earth de forma
    PREGUIÇOSA (só no desenho), então --plot ABORTAVA com URLError em nós de
    computação sem acesso à rede (o caso do Jaci). Agora a disponibilidade é
    testada uma vez; se indisponível, os mapas saem SEM contornos, sem abortar.

  BUG-SCALE-PERSTEP (animação com escala de cor incoerente)
    O reajuste robusto de vmin/vmax de So_t usava os percentis DE CADA PASSO —
    cada quadro do GIF tinha uma escala de cor diferente e a evolução ficava
    incomparável. Agora a decisão e os percentis são calculados UMA vez, sobre
    todos os passos, e reutilizados em todos os quadros.

  BUG-PERSIST-DEFAULT (diagnóstico fabricava o campo de gelo)
    A "persistência simulada" de Si_ifrac (max com decaimento entre passos)
    era aplicada POR PADRÃO e plotada como se fosse o campo importado, com
    apenas um discreto "[acc]" na anotação. Um diagnóstico não deve fabricar
    dado: agora o padrão mostra o Si_ifrac REALMENTE importado; a persistência
    simulada passou a ser opt-in via --simulate-persistence.

  BUG-LABEL-FONTE1 (provenância errada no título)
    O rótulo da FONTE 1 dizia sempre "mpas_import_stepNNNN.nc", mesmo quando os
    dados vinham dos arquivos novos monan2_import_YYYYMMDD_HHMMSS.nc. Agora o
    rótulo reflete o nome real dos arquivos lidos.

  BUG-FRAME-SIZE (quadros de tamanhos diferentes)
    savefig(bbox_inches='tight') gerava PNGs de tamanhos ligeiramente distintos
    entre passos, fazendo a animação "tremer". Removido: com figsize fixo os
    quadros saem idênticos.

CORREÇÕES v2.3
═══════════════════════════════════════════════════════════════════════════════
  BUG-11 (mapas Si_ifrac em branco — células esparsas invisíveis em pcolormesh)
    pcolormesh renderiza células de 1°×1° como pixels de ~1-2 px na escala
    do mapa global.  Com apenas 38–107 células de gelo ativas, os mapas
    Si_ifrac aparecem essencialmente em branco mesmo com dados presentes.
    Solução: quando n < ICE_SCATTER_THRESHOLD (2000 células), um scatter
    overlay com marcadores de tamanho fixo (ICE_SCATTER_SIZE=18 pt²) é
    desenhado sobre o pcolormesh, garantindo legibilidade independente da
    esparsidade do campo.  O pcolormesh é mantido para consistência visual.


    Quando SST é bootstrap (uniforme ≈ 271.35 K), o Si_ifrac do mesmo passo
    contém o estado de restart do SIS2 — não dado de acoplamento real.
    coverage_fraction() retornava (1.0, 0.0) pois Si_ifrac do restart NÃO é
    uniforme (tem distribuição espacial real do arquivo de restart). Porém
    "100% dinâmico" é enganoso: os 7918 fragmentos de gelo visíveis refletem
    a condição inicial do SIS2, que desaparece na primeira troca NUOPC.
    Solução: _is_bootstrap_step() detecta se So_t é uniforme no passo i;
    quando verdadeiro, Si_ifrac recebe anotação "restart SIS2 (t=0)" em laranja
    no canto inferior esquerdo.

  BUG-10 (escala de cores Si_ifrac inconsistente entre passos)
    BUG-02 (v2.2) usava escala adaptativa POR PASSO: passo 01:00 com gelo do
    restart (max=1.0) ficava com vmax=1.0, enquanto passos 02:00–05:00 com
    poucos fragmentos de gelo reais adaptavam para vmax≈0.12.  Impossível
    comparar visualmente a evolução temporal do campo.
    Solução: vmax_si_global pré-calculado excluindo passos de bootstrap; usado
    de forma consistente em todos os passos. Si_ifrac do restart aparece mais
    saturada que os passos reais — comportamento fisicamente correto.

  ADIÇÃO: anotação "n=xxxx cél > ICE_THR | max=x.xxx" no canto inferior
    direito do painel Si_ifrac. Informa quantas células oceânicas excedem
    o limiar definido por IFRAC_ICE_ANN_THR = 0.01, e o valor máximo do
    campo. Complementa a anotação de cobertura no canto esquerdo.

CORREÇÕES v2.1 (BUG-LAND-FONTE2):
  • So_t  — fill de terra (271.35 K, marcador Sprint A.5) agora mascarado
             antes de plotar: patches dark-blue nos trópicos eliminados.
  • Sf_zorl — máscara de terra do So_t propagada para a inferência
              Charnock+Smith: patches dark-red (z₀ inflacionado por
              Foxx_taux/tauy anômalos sobre terra) eliminados.
  • _load_fonte2 — retorno prematuro corrigido (3→4 valores); lat/lon
              extraídos dos arquivos MED (coords antes sempre None).
```

## `tools/postproc/postproc_monan2_export.py`

```text
Versão 2.5 — compatível com mpas_cap_netcdf_mod v2.9 (campos instantâneos).
             GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

Correções v2.5 (13/05/2026):
  [E5] load_all_steps — import redundante de Dataset removido (já importado no
       nível do módulo). A instrução 'from netCDF4 import Dataset as _DS' dentro
       da função criava um segundo vínculo desnecessário ao mesmo objeto.
  [E6] _default_fields em main() — construção simplificada com list comprehension
       única; comentário de contagem atualizado para refletir os campos presentes.

Correções v2.4 (20/04/2026):
  [E4] main() — step_indices padrão gerava apenas 3 mapas (primeiro, meio,
       último). Corrigido: novo argumento --all-steps para mapas de TODOS os
       passos; padrão sem flag: ~8 passos uniformemente espaçados + último.
       --stats e --csv sempre processavam todos os passos (sem alteração).

Correções v2.3 (20/04/2026):
  [E1] plot_maps — ramos if/else idênticos (código morto) → simplificado.
  [E2] fill_latlon_gaps — comentários de direção do np.roll incorretos → corrigidos.
  [E3] _get_plot_norm — extend logic expandida: distingue neither/max/both
       com base em vmin_fixed, vmax_fixed e symmetric.
  [B-28] field_outlier_threshold — Sa_u10m/v10m: 10 m/s → 150 m/s.
       Ventos > 10 m/s são fisicamente normais (alísios, jatos, ciclones);
       o limiar anterior filtrava 2.6% dos bins, subestimando σ_cap em 7%.
       (mpas_cap_netcdf.F90 v2.9 já inclui essa correção)
             GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Abril 2026
```

## `tools/postproc/postproc_monan2_standalone.py`

```text
Versão : 1.5 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

Novidades v1.5 (13/05/2026):
  [N4] import 'timezone' removido — importado do módulo datetime mas nunca
       referenciado no corpo do script (PEP 8, F401).
  [N5] load_all_steps — fallback de detecção de nCells protegido com
       tratamento de StopIteration: se nenhuma variável (Time, nCells) existir
       no arquivo, emite mensagem de erro clara em vez de exceção genérica.
  [N6] Docstring de discover_all_fields() aprimorada com exemplo de uso.

Novidades v1.4 (21/04/2026):
  [N1] NOVO argumento --allmaps: gera um mapa por campo por TODOS os passos de
       tempo presentes nos arquivos MONAN_DIAG_*.nc. Complementa --plot, que por
       padrão produz apenas 3 passos (primeiro, meio, último).
       Implica --plot. Pode ser combinado com --field para selecionar campos.
       Uso: python3 postproc_monan2_standalone.py --allmaps
            python3 postproc_monan2_standalone.py --allmaps --field t2m acswdnb

  [N2] NOVO argumento --allfields: descobre automaticamente TODOS os campos
       presentes nos arquivos MONAN_DIAG_*.nc e os processa, mesmo que não
       estejam em FIELD_META. Campos desconhecidos recebem metadados genéricos
       automáticos (cmap viridis, escala linear, percentis [2,98]).
       Pode ser combinado com --allmaps para o processamento completo.
       Uso: python3 postproc_monan2_standalone.py --allfields
            python3 postproc_monan2_standalone.py --allmaps --allfields

  [N3] Função discover_all_fields(): varre o primeiro arquivo MONAN_DIAG e
       retorna todas as variáveis com dimensão (Time, nCells), incluindo as
       que não constam em FIELD_META. Gera metadados genéricos sob demanda.

Correções v1.3 (20/04/2026):
  [S1] CRÍTICO: load_cap_fields — faltava .T antes de .flatten().
       O Fortran grava campo 2D como (NLON,NLAT)=(360,181); sem transposta,
       compare_fields comparava pontos geograficamente distintos ponto-a-ponto.
       Bias/RMSE/corr de TODOS os campos estavam matematicamente errados.
  [S2] compare_fields — __import__('datetime').timedelta → timedelta (já importado).
  [S3] FIELD_META e CAP_MAP — cap_field com nomes legados (Sa_tbot, Sa_pslv...)
       corrigidos para nomes _mpas (Sa_tbot_mpas, Sa_pslv_mpas...).
  [S4] plot_maps — máscara data>0 substituída por data>=norm.vmin para
       consistência com os limites da colorbar em campos log.

Correção v1.2 (13/04/2026):
  Bug voronoi_to_latlon: o algoritmo anterior usava binning simples (1 célula
  → 1 bin, índice lon via floor), enquanto o Fortran mpas_cap_netcdf.F90 usa
  spray adaptativo (1 célula → janela lat ±1 × lon ±nspan_lon, índice lon via
  nint/round). A diferença causava σ SA > σ cap para campos de fluxo (hfx, lh)
  e deslocamento de 0.5° em longitude. Corrigido: voronoi_to_latlon agora
  replica exatamente o spray adaptativo do Fortran (CELL_HALF_DEG=0.60,
  NSPAN_LAT=1, wrap periódico, round em lon).

Correção v1.1 (07/04/2026):
  Bug --compare: campos standalone estão na grade Voronoi (40962 células) e
  campos do cap NUOPC v2.5 estão na grade lat/lon 1°×1° (181×360 = 65160 pontos).
  A comparação direta causava ValueError por shapes incompatíveis (40962,) vs (65160,).
  Correção: voronoi_to_latlon() reprojecta o campo standalone para a grade lat/lon
  do cap antes de calcular bias/RMSE/correlação. Placeholder em load_cap_fields
  corrigido de nCells=40962 para CAP_NCELLS=65160.
```

## `tools/postproc/analisa_comparacao.py`

```text
Versão : 1.4 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Maio 2026

Histórico:
  v1.4 (13/05/2026):
    [N1] quality_badge — guarda contra sigma_cap negativo (improvável mas defensivo).
    [N2] load_csv — mensagem de erro aprimorada ao encontrar CSV vazio.
    [N3] build_table — variável 'sratio' renomeada para 'sflag' para evitar
         ambiguidade com o valor numérico da razão calculado em row_line.
    [N4] Versão do script alinhada com demais scripts de pós-processamento.
  v1.3 (25/04/2026):
    [N1] Caminho CSV atualizado: diag_export/postproc/ (era postproc_standalone/).
    [N2] argparse com --help, --csv, --no-interp.
    [N3] Tratamento explícito de FileNotFoundError e CSV malformado.
    [N4] encoding=utf-8 em open(); fallback latin-1 para CSVs antigos.
    [N5] Notas de interpretação atualizadas para Experimentos 4.2-5.x
         (DOCN modo netcdf, 9 OK 0 avisos — SST variável via OISST v2.1).
    [N6] Novos campos Sa_shum_mpas e Faxa_snow_mpas na tabela de thresholds.
    [N7] Coluna sigma_ratio com flag (≈ dentro 5%, ↑ SA maior, ↓ cap maior).
    [N8] Coluna Q (qualidade: ❶ excelente ❷ muito bom ❸ bom ❹ revisar).
  v1.2 (21/04/2026):
    [N1] SST corrigida de 298 K para 290 K (OCN stub mom_cap.F90 v1.0).
    [N2] Interpretação acswdnb atualizada para bias negativo correto.
    [N3] Classificação de qualidade por faixa de Corr.
    [N4] Razão sigma_SA/sigma_cap para diagnóstico de variabilidade espacial.
```

## `tools/animation/anim_mom6_import.py`

```text
Versão 1.2 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Set 2026

CORREÇÕES v1.2
  • BUG-ANIM-SIZE: quadros de tamanhos diferentes (PNGs com bbox_inches='tight')
    faziam o GIF "tremer" e quebravam o MP4. Todos os quadros passam a ser
    normalizados à MESMA dimensão (compostos sobre tela branca) antes de montar.
  • BUG-ANIM-MP4: o MP4 usava o concat demuxer com os PNGs originais (falhava
    com quadros de dimensão variável). Agora normaliza e codifica uma sequência
    numerada via image2 — dimensão constante e ordem determinística.
  • Novos parâmetros: --max-width (reduz o tamanho do arquivo) e --no-optimize.
  Observação 1: a ESCALA de cor consistente entre quadros é responsabilidade do
  postproc (v8.4). Observação 2: para uma animação COMPLETA, rode antes
  postproc_mom6_import.py --plot --all-steps (sem isso, o postproc plota apenas
  ~8 passos amostrados e a animação fica com poucos quadros e "saltos").
```

## `tools/animation/anim_monan2_import.py`

```text
Versão 1.1 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Set 2026

CORREÇÕES v1.1
  • BUG-ANIM-SIZE: quadros de tamanhos diferentes (PNGs com bbox_inches='tight')
    faziam o GIF "tremer" e quebravam o MP4. Todos os quadros passam a ser
    normalizados à MESMA dimensão (compostos sobre tela branca) antes de montar.
  • BUG-ANIM-MP4: o MP4 usava o concat demuxer com os PNGs originais (falhava
    com quadros de dimensão variável). Agora normaliza e codifica uma sequência
    numerada via image2 — dimensão constante e ordem determinística.
  • Novos parâmetros: --max-width (reduz o tamanho do arquivo) e --no-optimize.
    optimize=True passou a ser o padrão do GIF (arquivos bem menores).
  Observação: a ESCALA de cor consistente entre quadros é responsabilidade do
  postproc (v2.4); rode postproc_monan2_import.py --plot antes deste script.
```

## `tools/animation/anima_sst_ifrac.py`

```text
INPE / CGCT / DIMNT — GT Acoplamento MONAN — Set 2026 (v1.1)

Correções v1.1
  • BUG-ANIM-SIZE: quadros de tamanhos diferentes faziam o GIF "tremer".
    Agora todos os quadros são normalizados à mesma dimensão antes de montar.
  Observação: a ESCALA de cor consistente entre quadros (colorbar) e a correção
  da colorbar desconectada são responsabilidade do analisa_sst_ifrac.py (v1.5);
  rode-o antes deste script.
```

## `tools/coupler/analisa_balanceamento_pets.py`

```text
INPE / CGCT / DIMNT - Grupo de Trabalho para Acoplamento de Modelos - v14.22

--------------------------------------------------------------------------
ALTERAÇÕES (23/09/2026) - v14.22
--------------------------------------------------------------------------
Revisão depois da primeira análise com três componentes (144 PETs, 128 +
8 + 8), que expôs três limitações:

  - A métrica "Desbalanceamento" comparava o componente mais lento com o
    mais rápido. Com dois componentes (atmosfera e oceano) isso media o
    desequilíbrio que interessa; com o gelo presente, que é sempre muito
    mais leve, o número explodia ("razão 55,71x", "5470,8% ocioso") e não
    dizia nada. Foi substituída pelo tempo que CADA componente passa
    esperando o gargalo (execução concorrente) ou pela participação de cada
    um no tempo total (execução sequencial ou layout compartilhado).

  - A divisão proporcional podia propor contagens que o modelo não
    aproveita, como 17 ou 31 PETs para o oceano (números primos obrigam o
    MOM6 a cortar o domínio em faixas finas). O relatório agora avalia cada
    contagem, atual e sugerida, pelo tamanho dos blocos do oceano e do gelo
    e pelo número de células MPAS por PET, e mostra um "ajuste prático" com
    a contagem viável mais próxima. As grades são lidas de
    MOM_parameter_doc.all, MOM_input ou MOM_override (NIGLOBAL, NJGLOBAL) e
    do nome dos arquivos 'x1.<N>.*' do MPAS, ou informadas por --ocn-grid e
    --atm-cells. Os limites são ajustáveis por --min-block e
    --min-cells-per-pet.

  - A coluna "Chamadas Run" somava todos os PETs (3072 = 128 PETs x 24
    trocas, para a atmosfera). Passou a mostrar as chamadas por PET.

O JSON ganhou os campos '<comp>_idle_frac' e
'suggested_practical_<comp>_pet_count'; os campos anteriores não mudaram, e
referências gravadas por versões anteriores continuam comparáveis.

--------------------------------------------------------------------------
ALTERAÇÕES (Set/2026) - COMPONENTE DE GELO
--------------------------------------------------------------------------
Até a v14.20 o script conhecia apenas MPAS, OCN e MED. Com `use_sis2_dynamic`
ligado, o SIS2 recebe um terceiro bloco de PETs, e o tempo dele não entrava na
tabela, nem no desbalanceamento, nem na divisão sugerida; os PETs do gelo
apenas não apareciam. Passaram a ser tratados:

  - a faixa `ICE=PET[a..b]`, que o `esm.F90` acrescenta na MESMA linha de
    layout depois do bloco de oceano, quando o gelo está ativo;
  - o rótulo `ICE` nos pares `Run intro.`/`Run extro.`;
  - a inclusão do componente na tabela, no cálculo do mais lento e do mais
    rápido, no ganho contra a soma serial, no CSV, no JSON e no gráfico;
  - a divisão de PETs entre TRÊS componentes.

Um componente sem PETs atribuídos é tratado como AUSENTE, e não como presente
com tempo zero: some da tabela e da divisão. A distinção importa porque tempo
zero num componente presente é sintoma de log truncado, e merece aparecer.

A divisão de PETs passou a usar o método do maior resto sobre a quota cheia,
com piso de 1 PET por componente ativo. Com dois componentes o resultado é
idêntico ao da fórmula anterior; verificado contra o caso de referência.
```

## `tools/coupler/mede_smt.py`

```text
ALTERACOES (Set/2026)
---------------------
1. O reconhecimento do modo de acoplamento estava quebrado com binario atual.
   O padrao procurado era "ESM: modo SEQUENTIAL|CONCURRENT", formato ANTERIOR a
   v14.20. Desde a separacao dos dois eixos o driver grava
   "ESM: layout SPLIT (execucao SEQUENTIAL) - ...", que nao casava. Tres
   verificacoes eram puladas em silencio: consistencia de modo entre rodadas,
   igualdade de modo entre A e B, e o aviso de modo concorrente. Os dois
   formatos passaram a ser aceitos.
2. O componente de gelo (SIS2) entrou na ordem de exibicao. O leitor de logs
   sempre foi generico e ja' capturava o rotulo ICE, mas sem estar na lista ele
   caia no rabo alfabetico e vinha antes de MPAS e OCN.
3. Nova verificacao do CONJUNTO DE COMPONENTES entre A e B. Sem ela, uma
   configuracao com gelo comparada contra outra sem gelo passava sem sinal: as
   linhas de componente ausente eram puladas, e a linha TOTAL comparava somas
   de conjuntos diferentes. Num caso de teste com quatro componentes em A e
   tres em B, o custo de maquina saiu 0,977 em vez de 1,062, ou seja, o
   veredito anunciaria melhora de 2,3% onde havia degradacao de 6,2%.
4. Nova verificacao do EIXO ESPACIAL. O experimento exige layout SHARED; com
   split o 'select' e' heterogeneo, cada bloco fecha em nos inteiros e a
   configuracao B nao ocupa um no' so'.
5. A agregacao entre repeticoes passou a usar a intersecao das chaves, para
   que uma divergencia de componentes chegue a' mensagem de erro em vez de
   estourar antes com KeyError.
```

## `tools/postproc/analisa_sst_ifrac.py`

```text
Versão 1.5 — GT Acoplamento de Modelos / INPE/CGCT/DIMNT — Set 2026

═══════════════════════════════════════════════════════════════════════════════
Correções v1.5 (revisão diagnóstico/animação)
═══════════════════════════════════════════════════════════════════════════════
  BUG-COLORBAR (colorbar desconectada dos mapas — viridis 0–1)
    A colorbar era obtida raspando ax.collections (_get_scalar_mappable). Em
    algumas versões de matplotlib/cartopy isso devolvia a coleção da FEIÇÃO de
    terra/costa (adicionada após o pcolormesh) em vez do dado, produzindo uma
    barra "viridis 0–1" que NÃO correspondia às cores RdBu_r/BrBG plotadas —
    o leitor não conseguia interpretar os valores de δ/Δ. Agora _plot_field
    RETORNA o mappable (QuadMesh) e a colorbar é feita a partir dele.

  BUG-SCALE (escala de cor incoerente entre quadros da animação)
    Cada mapa de δ/Δ usava o percentil 99,5 DAQUELE passo como limite de cor,
    então a escala mudava a cada quadro do GIF e a evolução ficava incomparável.
    Agora o limite é GLOBAL: calculado uma vez sobre todos os passos e reutilizado
    em todos os quadros (o máx|δ| de cada passo continua anotado no título).

  BUG-OFFLINE (--anomaly/--diff abortavam em nó HPC sem internet)
    cfeature.LAND/COASTLINE baixam os shapefiles Natural Earth no desenho; em nó
    de computação sem internet o script abortava com URLError (só funcionava no
    nó de login). Agora testa a disponibilidade uma vez e, se offline, gera os
    mapas sem contornos em vez de abortar.

  BUG-RAWSTATS (linha "SST bruta" contaminada pelo _FillValue)
    min/média saíam como -9,99e20 porque o valor de preenchimento entrava na
    conta. Agora descarta preenchimento/NaN (|v|>1e19, máscara netCDF) e reporta
    quantas células foram descartadas.

  BUG-FRAME-SIZE (quadros de tamanhos diferentes tremiam na animação)
    savefig(bbox_inches='tight') nos mapas de δ/Δ gerava PNGs de tamanhos
    distintos. Removido (figsize fixo → quadros idênticos).

═══════════════════════════════════════════════════════════════════════════════
Correções v1.4
═══════════════════════════════════════════════════════════════════════════════
  BUG-6 (mapas de anomalia e diff_consec brancos — outlier domina colorscale)
    O limite do colormap era calculado como np.ma.abs(campo).max().  Basta
    uma célula outlier com Δ ≈ 8–10 K para que TwoSlopeNorm mapeie todo o
    oceano (bulk < 0,5 K) para branco, tornando os mapas dos passos 3–6
    visualmente vazios.
    Solução: _robust_limit() usa np.percentile(|campo|, ROBUST_PERCENTILE=99.5)
    como limite visual; o máximo absoluto ainda é reportado no título com o
    prefixo "⚠ outlier:" quando lim_abs > 2× lim_robusto.

  BUG-7 (série temporal com escala Y comprimida — analise_timeseries sem idx0)
    analise_timeseries não recebia idx0, então o passo 1 (SST = 271 K,
    sst_default) dominava o eixo Y e comprimia a variação real (292–293 K)
    numa faixa invisível.  O mesmo ocorria no painel de desvio-padrão.
    Solução: idx0 adicionado como parâmetro; ajuste de ylim aplicado ao
    intervalo dos passos reais (idx0 em diante), com margem relativa.

  BUG-8 (spike do passo 0 visível no gráfico de métricas — piso 1.0 km²)
    Em analise_metricas, a margem Y tinha piso fixo de 1.0 km².  Quando a
    área real de gelo é ≈ 0 km², esse piso expandia ylim até 1 km², incluindo
    o spike do passo sst_default (step 1) na janela visível.
    Solução: margem agora é relativa ao intervalo real dos dados (max(intervalo
    × 0.15, |vmax| × 0.05, 0.01)); o piso fixo de 1.0 foi removido.

═══════════════════════════════════════════════════════════════════════════════
Correções v1.2
═══════════════════════════════════════════════════════════════════════════════
  BUG-5 (mapas em branco — campo congelado)
    O DOCN envia o mesmo valor OISST diário em todos os passos
    horários. δ = 0 K é mapeado para branco no colormap RdBu_r,
    produzindo mapas visualmente vazios sem indicação ao usuário.
    Solução: _is_frozen() detecta campos sem variação e
    _annotate_frozen() escreve aviso legível sobre o mapa;
    _plot_field() usa fundo azul-claro (#d0e8f5) para o oceano.

  BUG-3 (referência de anomalia degenerada)
    O passo 1 contém SST = sst_default = 271.35 K (campo não preenchido).
    Usar passo 1 como t₀ produzia Δ ≈ 21 K uniforme em todo o oceano,
    saturando a escala de cores e tornando os mapas visualmente brancos.
    Solução: _find_first_real_step() detecta automaticamente o primeiro
    passo com std espacial > 0.1 K e usa-o como referência t₀.

  BUG-4 (diferença consecutiva no par sst_default → real)
    O par passo 1→2 capturava a transição sst_default → OISST real,
    produzindo δ ≈ 21 K (artefato, não sinal físico). Solução: loop
    analise_diff_consecutiva inicia em max(1, idx0+1).

  MELHORIA: escala Y dos gráficos de métricas
    O outlier do passo 1 (sst_default) comprimia a variação real para
    uma faixa invisível. Os eixos Y agora são ajustados ao intervalo
    dos passos reais (idx0 em diante), com margem de 15 %.

═══════════════════════════════════════════════════════════════════════════════
Correções v1.1
═══════════════════════════════════════════════════════════════════════════════
  BUG-1 (mascaramento catastrófico)
    Na grade Voronoi do MPAS, o diagnóstico monan2_import_*.nc é escrito
    ANTES de o conector OCN→ATM preencher o campo So_t.  Todas as células
    (terra E oceano) têm So_t = sst_default = 271.35 K.  A detecção de
    terra por limiar  |v − 271.35| < 1e−3  mascarava TUDO.

    Solução: detecção por variância temporal.  Células constantes ao longo
    de TODOS os passos E próximas do valor-padrão são classificadas como
    terra/default.  Se após isso > 99 % do campo ainda estiver mascarado
    (campo genuinamente não preenchido), o mascaramento de terra é desabilitado
    e o script emite um aviso.

  BUG-2 (coordenadas MPAS)
    A grade Voronoi do MPAS usa 'latCell'/'lonCell', não 'lat'/'lon'.
    Adicionado suporte a esses nomes.

  MELHORIA: avisos UserWarning de conversão masked→nan suprimidos via
    warnings.catch_warnings; verificação de np.ma.count() antes de float().
```
