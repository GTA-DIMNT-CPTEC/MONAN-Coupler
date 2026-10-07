# Conformidade do MONAN-Coupler com o DTN-01

Levantamento de 28/09/2026, sobre o código da tag `fase5-07-validada` (commit `e61ab1c` na Jaci). Referência: Documento Técnico Normativo DTN-01 v0.1.0, "Padrão de Codificação para o MONAN" (GCC/DIMNT/INPE, 8 jul. 2025). O DTN-01 separa as regras em mandatórias (prefixo `M.`) e recomendadas (prefixo `R.`).

## 1. Resumo

A refatoração das fases 1 a 5 já atende boa parte do DTN-01:

- não há comandos obsoletos (`common`, `data`, `equivalence`, `double precision`, `pause`);
- todo módulo tem `implicit none`;
- não há `goto`, `print` nem `include`;
- as constantes estão num módulo único;
- os erros informam arquivo e linha;
- o NetCDF passa por um módulo comum;
- a compilação com `-Wconversion -Wimplicit-interface -Wextra` não dá nenhum aviso de conversão implícita nem de interface implícita.

O código ainda não está conforme o DTN-01. Há dois tipos de desvio:

1. **Forma.** A mais visível é a indentação: o código usa 2 espaços, e o DTN-01 exige 4 (regra mandatória). Também faltam o espaçamento, a separação entre procedimentos e os cabeçalhos FORD completos. Nenhuma dessas correções altera resultados, mas todas mexem em muitas linhas.
2. **Convenções de nomes.** O DTN-01 pede camelCase em sub-rotinas, PascalCase em funções, e prefixos `t_`, `c_` e `p_`. Adotá-las exigiria renomear quase tudo, e parte dos nomes é fixada pelo ESMF/NUOPC.

Poucos itens podem mudar resultados (classe C). Esses dependem de decisão e não entram em etapa de limpeza.

Nenhuma rotina de terceiros foi avaliada. MPAS, MOM6, SIS2, FMS, ESMF e os arquivos de `src/caps/ocean/upstream/` ficam fora do escopo.

## 2. Escopo e método

- **Fontes:** 33 arquivos Fortran próprios em `src/` (18 318 linhas): 32 módulos e 1 programa, 264 sub-rotinas e 35 funções.
- **Auditoria automática:** o roteiro da skill de refatoração e um levantamento em Python que retira comentários e literais de texto antes de procurar os padrões.
- **Compilação local:** `tools/dev/compila-local.bash` com avisos extras (`-Wextra -Wconversion -Wimplicit-interface -Wimplicit-procedure -Wcharacter-truncation -Wmaybe-uninitialized`).
- **Leitura de conferência:** todas as ocorrências das regras com poucos casos foram lidas. Nas regras com muitos casos, foi lida uma amostra.
- **Classes de risco:**
  - **A:** não muda o código gerado.
  - **B:** estrutural; deve dar bit a bit, mas precisa de rodada.
  - **C:** pode mudar resultados.

## 3. O que já está conforme

| Regra | Situação |
|---|---|
| M.CF.comandos_obsoletos (`common`, `data`, `equivalence`, `double precision`, `pause`) | nenhuma ocorrência |
| M.CO.implict_none | 33 de 33 unidades |
| M.FC.indentação (tabulação) | nenhuma tabulação |
| R.CF.conformidade | Fortran 2003/2008 sem `BLOCK`, aceito pela seção de conflitos da skill |
| R.CO.gfortran_compatível, R.CO.f90 | compila em gfortran; extensão `.F90` |
| R.CO.goto_continue (`goto`) | nenhum `goto` |
| R.CO.stop | um só ponto de parada (`error stop` em `esmApp.F90`); os demais erros sobem por `ChkErr` |
| R.CO.tratamento_erro | `ChkErr` recebe `__LINE__` e `__FILE__` (358 usos) |
| R.CO.conversões_tipo | nenhum aviso de `-Wconversion` |
| R.CO.procedure_expert, R.CO.laços_grandes | nenhuma rotina própria acima de 150 linhas de código, exceto `config_read` (declarações de namelist) |
| R.ES.write_print | nenhum `print` |
| R.ES.unit_automático | as duas aberturas de arquivo usam `newunit=` |
| R.ES.netcdf | NetCDF por `nc_writer_mod` |
| R.MR.modconstants | `coupler_constants_mod` |
| R.MR.módulos_include | nenhum `include` |
| R.MR.módulos_genéricos | `coupler_utils_mod`, `nc_writer_mod`, `mpi_allreduce_*` |
| R.DO.markdown | documentação em `docs/*.md` |
| R.DO.comentários_óbvios | comentários limpos nas fases 3 e 5 |

## 4. Não conformidades

### 4.1 Mandatórias

| Regra | Ocorrências | Onde | Classe | Observação |
|---|---|---|---|---|
| M.FC.indentação (4 espaços) | 4 271 de 11 319 linhas de código com recuo que não é múltiplo de 4 | todos os arquivos | A | o padrão do projeto é 2 espaços |
| M.CF.comandos_obsoletos (`save`) | 69 declarações | 63 em variáveis de módulo; 6 em variáveis locais | B nas de módulo; C nas locais | em Fortran 2008 toda variável de módulo já é persistente, então nas 63 de módulo o atributo é redundante |
| M.CF.palavras_reservadas (maiúsculas) | 1 (`DO iCell = ...`) | `mpas_atm_model.F90`, laço de injeção do contorno | A | trecho herdado do MPAS, com `endif`, `.gt.` e espaços no fim da linha |
| M.CO.intent | 103 argumentos de tipo derivado sem `intent` | pontos de entrada NUOPC (`gcomp`, `importState`, `exportState`, `clock`) em 7 caps e no driver | B | o DTN-01 dispensa tipos derivados; a assinatura segue o padrão do NUOPC; nenhum argumento de tipo intrínseco sem `intent` |
| M.CO.variáveis_inicialização | não medido | | C | inicializar variáveis antes indefinidas pode mudar resultados |
| M.CO.arrays_automáticos (todo `allocate` com `deallocate`) | 166 `allocate`, 70 `deallocate` | | B | a maioria dos alocáveis sem `deallocate` é local (liberada na saída) ou estado do componente que vive a rodada toda |
| M.FC.snake_case | 388 de 3 154 variáveis em camelCase | sobretudo nomes do ESMF/NUOPC (`exportState`, `petCount`, `localPet`, `currTime`) | B | |

### 4.2 Recomendadas de codificação e conformidade (CF, CO)

| Regra | Ocorrências | Onde | Classe | Observação |
|---|---|---|---|---|
| R.CF.kind | 3 fontes próprios compilados com `-fdefault-real-8` (`mom_cap_MONAN`, `sis_cap_MONAN`, `time_utils`); 8 declarações `real` sem `kind` | `coupler_config.F90` (6), `mpas_cap_netcdf.F90` (2) | C | `cfg_zorl_default = 0.01` em precisão simples vira 0.0099999998 quando passa para `r8` |
| R.CO.laços_colapsado | 4 `endif` | `mpas_atm_model.F90` | A | mesmo trecho herdado |
| R.CO.goto_continue (`continue`) | 1 | `coupler_config.F90:354`, ramo vazio de `if` | B | inverter a condição |
| R.CO.retorno_função | 14 funções sem `result(...)` | `nc_writer`, `coupler_config`, `regrid_manager`, `regrid_registry`, `coupler_utils` (`ChkErr`), `mpas_cap_netcdf` | B | |
| R.CO.variáveis_ponteiro_null | 185 ponteiros locais sem `=> null()` | todos os caps e o mediador | B | ver o alerta da seção 5.2 |
| R.CO.alocação_memória_check | 156 de 166 `allocate` sem `allocated()` antes | | B | útil só para o estado de módulo; em locais recém-declarados é redundante |
| R.CO.especificadores_erro_IO | teste `ios < 0` para fim de grupo de namelist | `coupler_config.F90` | B | trocar por `is_iostat_end(ios)` |
| R.CO.operandos_precisão_numérica | 1 candidato | `MED_cap.F90:2922`, `count(p_ifrac_raw == 0.0)` | C | contagem proposital de zeros exatos num diagnóstico; manter |
| R.CO.números_argumentos, R.CO.variáveis_inicialização_tipo | não medido | | C | |
| R.CO.variáveis_inicialização_valor | 6 variáveis locais com `save` e valor inicial | `MED_cap` (3), `mpas_atm_model`, `sis_cap_MONAN`, `regrid_registry` | C | estado entre chamadas proposital; só sai levando o estado para o módulo |

### 4.3 Recomendadas de documentação (DO)

| Regra | Situação | Classe |
|---|---|---|
| R.DO.cabeçalho_módulos | 31 de 33 arquivos com cabeçalho `!>`/`!!`, mas nenhum com os campos pedidos (autor, e-mail, data, versão, histórico, licença). O repositório é GPLv3 (`LICENSE`), mas nenhum fonte traz o aviso | A |
| R.DO.cabeçalho_funções, R.DO.cabeçalho_subrotinas | 78 de 299 procedimentos sem nenhum comentário FORD; os demais sem os campos formais | A |
| R.DO.ford (argumentos com `!!` e unidade) | parcial: comum nos tipos e constantes, raro nos argumentos | A |
| R.DO.comentários_bloco (equações em LaTeX) | parcial: a física bulk cita as referências, mas não escreve as equações | A |

### 4.4 Recomendadas de formatação (FC)

| Regra | Ocorrências | Classe | Observação |
|---|---|---|---|
| R.FC.comandos_linha (sem `;`) | 451 linhas | A | quase todas com o padrão `call x(..., rc); if (ChkErr(rc, __LINE__, __FILE__)) return` |
| R.FC.linha_limite (132) | 20 linhas acima de 132; 65 entre 101 e 132 | A | as 20 são a tabela `select case` de metadados em `med_cap_netcdf.F90`, com vários comandos por linha |
| R.FC.início_procedure | 288 de 299 procedimentos sem a linha `! ` com 60 ou mais `-` | A | o projeto usa `!===` ou nada |
| R.FC.comentários_espaço_branco | 206 comentários sem espaço após `!` | A | quase todos são linhas separadoras `!====` |
| R.FC.espaços_branco_linha_vazia | 5 | A | mesmo trecho herdado |
| R.FC.operadores_lógicos | 1 (`.gt.`) | A | mesmo trecho herdado |
| R.FC.camelcase, R.FC.pascalcase | 198 sub-rotinas e 34 funções em snake_case | B | ver seção 5.1 |
| R.FC.tipos_prefixo (`t_`) | 22 tipos derivados, nenhum com `t_`; o projeto usa o sufixo `_t` ou `_type` | B | |
| R.CO.constantes_parameter e R.CO.constantes_não_físicas (`c_`, `p_`) | 16 constantes em `coupler_constants` e 136 `parameter` em outros 20 arquivos, nenhuma com prefixo | B | |
| R.FC.identificadores_simples, R.FC.identificadores_variáveis | 749 declarações com nomes de 1 ou 2 letras (`rc` 177, `is` 64, `i`, `j`, `k`, `n`); contadores sem `_cnt` | B | `rc` é o nome padrão do ESMF |
| R.FC.identificadores_módulos (`modNome`) | sufixo `_mod` | B | ver seção 5.1 |

### 4.5 Recomendadas de modularidade (MR)

| Regra | Ocorrências | Classe | Observação |
|---|---|---|---|
| R.MR.módulos_use (`only`) | 40 `use` sem `only` | B | 26 de `ESMF`, `NUOPC` e `NUOPC_*`, que exportam centenas de símbolos; os demais de `netcdf`, `mpi` e módulos próprios |
| R.MR.módulo_private | 1 módulo sem `private` padrão (`med_cap_types_mod`) | B | |
| R.MR.constante_identificação_rotinas | nenhum `p_source_name`/`p_procedure_name` | B | `ChkErr` já recebe arquivo e linha |
| R.MR.módulos_variáveis_encapsulamento | estado de componente em variáveis de módulo públicas em parte dos caps (por exemplo, `med_cap_types`) | B | |
| R.MR.módulos_inicialização | inicialização feita pelas fases do NUOPC, sem rotina `init...` que devolva 0 | B | |

## 5. Dispensas propostas

### 5.1 Conflitos com o projeto e com o ESMF/NUOPC

Estas regras seguem a tabela de conflitos da skill. Proponho registrá-las como dispensadas no `README.md`, com a justificativa abaixo:

| Regra | Justificativa |
|---|---|
| R.FC.camelcase, R.FC.pascalcase, R.FC.identificadores_módulos, R.FC.tipos_prefixo, prefixos `c_`/`p_` | Renomear quase todos os procedimentos, módulos, tipos e constantes muda símbolos, `.mod` e Makefile em todo o código, sem ganho para o resultado. Os pontos de entrada NUOPC (`SetServices`, `ModelAdvance`, `InitializeP0` etc.) não podem mudar. Proposta: manter snake_case e os sufixos do projeto no código existente, e decidir se o código novo segue o DTN-01 ou o projeto. |
| M.FC.snake_case nos nomes do ESMF/NUOPC | `exportState`, `importState`, `petCount`, `localPet` seguem a documentação do ESMF; renomeá-los afasta o código dos exemplos oficiais. |
| M.CO.intent nos argumentos dos pontos de entrada | A interface é definida pelo NUOPC; o DTN-01 já dispensa tipos derivados. |
| R.MR.módulos_use com `ESMF` e `NUOPC` | Listar em `only` os símbolos do ESMF usados em cada cap daria listas de dezenas de nomes. Proposta: exigir `only` em `netcdf`, `mpi` e nos módulos próprios. |
| R.MR.constante_identificação_rotinas | `ChkErr(rc, __LINE__, __FILE__)` já identifica arquivo e linha, e as mensagens de log levam o nome do componente. |
| R.CO.stop com `StopExecution` | `ChkErr` e o tratamento de erro do ESMF cumprem o papel. |
| R.MR.módulos_inicialização | A inicialização segue as fases do NUOPC. |

### 5.2 Alerta sobre ponteiros com `=> null()`

A regra R.CO.variáveis_ponteiro_null pede ponteiros declarados com `=> null()`. Num ponteiro local, essa forma dá à variável o atributo `save` implícito: a associação da chamada anterior persiste, e a rotina deixa de ser reentrante. Esse efeito foi documentado na fase 4. Para os 185 ponteiros locais, a forma segura é `nullify(p)` no início do corpo, e não a inicialização na declaração. A mesma armadilha vale para R.CO.variáveis_inicialização_valor.

## 6. Itens que podem mudar resultados (classe C)

Nenhum destes entra numa etapa de limpeza. Cada um exige decisão, etapa própria e nova linha de base:

1. **R.CF.kind.**
   - Três fontes próprios são compilados com `-fdefault-real-8`: `mom_cap_MONAN`, `sis_cap_MONAN` e `time_utils`. Tirar a opção muda a precisão de todo `real` e literal sem `kind` desses arquivos.
   - Em `coupler_config.F90`, os valores padrão `cfg_grid_res_deg`, `cfg_sst_default`, `cfg_ice_fraction_default` e `cfg_zorl_default` são `real` de precisão simples. Passá-los a `real(r8)` muda, por exemplo, 0.0099999998 para 0.01 na rugosidade padrão.
2. **`save` em 6 variáveis locais** (contadores e indicadores de "primeira chamada"). Removê-lo exige levar o estado para o módulo. Isso deve dar bit a bit, mas mexe no controle de fluxo.
3. **M.CO.variáveis_inicialização.** Pede um levantamento com `-finit-real=snan -ffpe-trap=invalid` numa rodada de teste; qualquer variável usada antes de definida é um defeito a tratar à parte.
4. **R.CO.números_argumentos e R.CO.variáveis_inicialização_tipo.** Trocar literais sem `kind` por constantes `_r8` muda a precisão quando o literal não é exato em binário.

## 7. Plano de etapas proposto (fase 6)

Numeração provisória, das mais seguras para as que pedem decisão.

| Etapa | Objetivo | Regras | Classe | Conferência |
|---|---|---|---|---|
| R-FASE6-01 | trecho herdado do MPAS em `mpas_atm_model.F90` (`DO`, `endif`, `.gt.`, espaços no fim), `continue` de `coupler_config`, tabela de `med_cap_netcdf` em uma instrução por linha e abaixo de 132 colunas | M.CF.palavras_reservadas, R.CO.laços_colapsado, R.FC.operadores_lógicos, R.FC.espaços_branco_linha_vazia, R.CO.goto_continue, R.FC.linha_limite | A e B | instruções idênticas (exceto o `continue`); literais iguais; rodada |
| R-FASE6-02 | `result(...)` nas 14 funções; `private` padrão em `med_cap_types`; `only` em `netcdf`, `mpi` e módulos próprios; `is_iostat_end` | R.CO.retorno_função, R.MR.módulo_private, R.MR.módulos_use, R.CO.especificadores_erro_IO | B | compilação local, testes de regressão, rodada |
| R-FASE6-03 | `save` redundante fora das 63 variáveis de módulo; `nullify` explícito nos ponteiros locais | M.CF.comandos_obsoletos, R.CO.variáveis_ponteiro_null (pela forma da seção 5.2) | B | instruções; rodada |
| R-FASE6-04 | cabeçalhos FORD de módulo com autor, data, versão, licença GPLv3 e histórico apontando para o CHANGELOG; linha separadora antes de cada procedimento | R.DO.cabeçalho_*, R.FC.início_procedure, R.FC.comentários_espaço_branco | A | instruções idênticas |
| R-FASE6-05 (decisão) | indentação de 4 espaços em todo `src/` | M.FC.indentação | A | instruções idênticas; o diff toca cerca de 40% das linhas |
| R-FASE6-06 (decisão) | uma instrução por linha no padrão `call ...; if (ChkErr(...)) return` (451 linhas) | R.FC.comandos_linha | A | instruções idênticas |
| fora da limpeza | itens da seção 6 | R.CF.kind e outros | C | nova linha de base |

As etapas 05 e 06 são mandatória e recomendada, respectivamente, e não mudam resultados. Mas reescrevem boa parte das linhas, o que dificulta o `git blame` e qualquer ramo paralelo ao `refactor/principal`. Convém decidir se entram antes ou depois da integração ao `develop`.

## 8. Como repetir o levantamento

```bash
ESMFMKFILE=... tools/dev/compila-local.bash   # com -Wconversion -Wimplicit-interface para os avisos extras
grep -rnP '\t' src --include=*.F90 | grep -v upstream
```

O roteiro `auditoria_dtn01.bash` da skill de refatoração dá a contagem por regra. Os números da seção 4 vêm de um levantamento que retira comentários e literais antes de procurar os padrões; esse levantamento pode entrar em `tools/dev/` numa das etapas da fase 6.
