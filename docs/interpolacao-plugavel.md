# Interpolação plugável (src/regrid)

Toda interpolação entre grades feita pelo acoplador passa por um único conjunto de módulos, em `src/regrid/`. O objetivo é que trocar ou acrescentar um esquema de interpolação (por exemplo, o método do MPASSIT) não exija procurar chamadas espalhadas pelo código.

## Onde a interpolação acontece

| Local | Situação |
| --- | --- |
| Mediador (`MED_cap.F90`, `med_cap_methods.F90`, `med_bulk_ncar.F90`) | Usa o framework: seis rotas com nome (tabela abaixo) |
| Cap atmosférico (`mpas_cell_binning.F90`, chamado por `state_set_field_1d` no adaptador `mpas_adapter.F90`) | Interpolação própria da malha Voronoi para a grade de 1 grau (vizinho mais próximo com espalhamento). É o ponto de entrada natural do esquema `mpassit`; a troca muda resultados e depende de decisão científica |
| Conectores NUOPC | Interpolação automática entre componentes, hoje entre grades iguais. Um conector especializado que use o framework só será necessário quando as grades passarem a diferir |

## Rotas do mediador

| Rota | De, para | Métodos (em ordem) | Máscara | Reserva |
| --- | --- | --- | --- | --- |
| `atm2ocn` | ATM, OCN | nearest_stod | não | não |
| `ocn2atm` | OCN, ATM | bilinear | não | não |
| `ocn2atm_sst` | OCN, ATM | conserve, bilinear | terra | `ocn2atm` |
| `ocn2atm_ice` | OCN, ATM | conserve, bilinear | terra | `ocn2atm` |
| `ocn2atm_landmask` | OCN, ATM | nearest_stod | não | não |
| `atm2ocn_ice` | ATM, OCN | conserve, nearest_stod | não | `atm2ocn` |

As configurações reproduzem exatamente as chamadas ESMF que existiam antes: mesmos métodos, mesmas máscaras, soma no destino (`srcTermProcessing = 0`) e ordem fixa (`termorder = srcseq`).

## Estrutura

O desenho segue o padrão Estratégia: cada esquema é um tipo que estende o tipo abstrato `regridder_t` e implementa três operações.

```fortran
type, abstract :: regridder_t
  type(regrid_spec_t) :: spec
contains
  procedure(setup_i),   deferred :: setup     ! pesos ou route handle, uma vez
  procedure(execute_i), deferred :: execute   ! interpolação, a cada passo
  procedure(release_i), deferred :: release
  procedure, non_overridable     :: apply     ! confere o setup e chama execute
end type
```

| Módulo | Papel |
| --- | --- |
| `regrid_base` | `regridder_t`, `regrid_spec_t`, `regrid_fill_t`, o preenchimento por vizinhança (`neighbor_fill`), a interface dos construtores (`regridder_ctor`) e a leitura das opções em texto (`regrid_option_real`, `regrid_option_int`, `regrid_options_check`) |
| `regrid_esmf` | Esquema `esmf`: pesos calculados pelo ESMF, com cadeia de métodos |
| `regrid_weights` | Esquema `weights_file`: pesos lidos de arquivo SCRIP/ESMF (variáveis `row`, `col`, `S`) |
| `regrid_mpassit` | Esquema `mpassit` e `mpas_mesh_create` (malha ESMF a partir das células Voronoi do MPAS) |
| `regrid_weights_base` | Base dos esquemas de pesos (`weights_regridder_t`): o esquema escreve só `compute_weights`, com arrays do Fortran (desde a R-FASE11-23) |
| `regrid_idw` | Esquema `idw` (inverso da distância), escrito sobre a base de pesos; é o modelo de esquema (desde a R-FASE11-23) |
| `regrid_schemes` | Lista dos esquemas do acoplador: uma linha por esquema, com o nome e o construtor (desde a R-FASE11-23) |
| `regrid_registry` | Catálogo de esquemas: nome e rotina que cria uma instância; lê a lista de `regrid_schemes` na primeira consulta |
| `regrid_manager` | Rotas com nome, rota de reserva e substituição da configuração de uma rota (`regrid_override_t`, argumento `overrides` de `add`; o mediador passa o `&nuopc_regrid` do `nuopc.input`) |

Uso num componente:

```fortran
call is%regrid%add('ocn2atm_sst', regrid_spec('conserve,bilinear', mask_src=.true.), &
                   sst_ocn, sst_atm, rc, fallback='ocn2atm')      ! uma vez
call is%regrid%apply('ocn2atm_sst', sst_ocn, sst_atm, rc)          ! a cada passo
```

Cada rota guarda a configuração com que foi criada. O `apply` do `regrid_manager` faz, nesta ordem: a interpolação, com o `zero_total` da rota (zerar o destino inteiro antes, ou só os pontos alcançados); o preenchimento por vizinhança dos pontos fora da faixa válida (`spec%fill`, um `regrid_fill_t`, em cada DE local); e a troca de NaN no destino (`nan_value` em `regrid_spec`). As três usam a configuração da rota pedida, mesmo quando ela usa a interpolação da reserva. Argumentos opcionais de `apply`: `zero_total` e `fill` substituem os da rota nesta chamada; `n_invalid` e `n_left` devolvem quantos pontos estavam fora da faixa antes do preenchimento e quantos ficaram com o valor fixo, somados nos DEs locais (-1 quando não houve preenchimento). Até a R-FASE11-13, o preenchimento era feito por `regridder_t%apply`, com as opções da rota que interpola, só no primeiro DE local e sem contagens; nenhuma rota o usava. No mediador, as rotas são criadas por `create_route` (`med_cap_methods`), com a configuração da tabela `ROUTES` do mapa de acoplamento (`src/coupling/cpl_map.F90`) e as substituições do `&nuopc_regrid`, que `create_route` lê de `coupler_config` e passa a `add` (argumento `overrides`); o framework não lê o `nuopc.input`, e pode ser usado e testado sem ele.

## Como acrescentar um esquema

Desde a R-FASE11-23, o caminho mais curto é um esquema de pesos, a partir do modelo `src/regrid/regrid_idw.F90`:

1. Copiar `regrid_idw.F90` para `src/regrid/regrid_<nome>.F90` e trocar `idw` pelo nome do esquema no módulo, no tipo e no construtor.
2. Escrever `compute_weights`. Ela recebe os pontos de origem (todos, ordenados pelo índice global) e os de destino (os locais), com longitude e latitude em graus, máscara e índice global, e devolve três arrays: o fator, o índice de origem e o índice de destino de cada peso. Não usa o ESMF: a base (`weights_regridder_t`) guarda os pesos no ESMF (`ESMF_FieldSMMStore`, com `srcTermProcessing = 0`), aplica-os na ordem do índice de origem (`termorder = srcseq`), o que dá o mesmo resultado, bit a bit, com qualquer número de processos, e os libera.
3. Ler as opções com `regrid_option_real` e `regrid_option_int` e recusar as desconhecidas com `regrid_options_check`.
4. Acrescentar uma linha na lista de `src/regrid/regrid_schemes.F90` (`call registra('<nome>', new_<nome>, rc)`) e gerar de novo as dependências (`tools/dev/dependencias.py gera`); todo `.F90` de `src/regrid/` é compilado, sem lista de fontes no `Makefile`.
5. Conferir com `tests/regrid/compara-esquema.bash <nome> '<opções>'` (seção 3 de `docs/conferencias-locais.md`).
6. Selecioná-lo para uma rota: nas colunas `scheme` e `options` de `ROUTES` (`src/coupling/cpl_map.F90`; `options` no mesmo formato de `regrid_options`, `'chave=valor,...'`), ou só no `nuopc.input`, para experimentar:

```fortran
&nuopc_regrid
  regrid_route(1)   = 'ocn2atm'
  regrid_scheme(1)  = 'idw'
  regrid_options(1) = 'vizinhos=4,expoente=2'
/
```

Limites da base de pesos: campos em `ESMF_Grid` de um tile, com coordenadas no centro das células e um DE por processo; a máscara de origem é a da grade (`ESMF_GRIDITEM_MASK`), como no esquema `esmf`. Os pesos calculados ficam no esquema (`factors`, `src_index`, `dst_index`) e podem ser gravados no formato SCRIP/ESMF e lidos depois pelo esquema `weights_file`, com resultado idêntico.

Um esquema que não é só de pesos (como o `mpassit`, que corrige os pontos não alcançados depois da interpolação) estende `regridder_t` e implementa `setup`, `execute` e `release`; o teste `tests/regrid/identity_scheme.F90` é um exemplo mínimo, e tem também um esquema de pesos mínimo (`identity_weights_t`). Um programa pode ainda registrar um esquema próprio sem mexer na lista, com `call regrid_register('meu_esquema', novo_meu_esquema, rc)`, como os testes.

## MPASSIT

O MPASSIT é um programa e não uma biblioteca: guarda estado em variáveis globais e não pode ser chamado de dentro do acoplador. O esquema `mpassit` reproduz o seu método:

1. a origem é um `ESMF_Mesh` cujos elementos são as células de Voronoi do MPAS (`verticesOnCell`, `lonVertex`, `latVertex`, `lonCell`, `latCell`), montado por `mpas_mesh_create`;
2. o método depende da classe do campo: `integer` usa vizinho mais próximo, `accumulated` usa conservativo e `continuous` usa bilinear;
3. pontos do destino fora da malha recebem o valor de ausência `spec%fill%vfill`.

Pesos gerados pelo próprio MPASSIT (ou pelo `ESMF_RegridWeightGen`) podem ser usados diretamente pelo esquema `weights_file`.

## Testes

```bash
export ESMFMKFILE=...        # esmf.mk do ESMF instalado
make test NP=2               # na raiz do repositório
```

Os testes verificam: bilinear dentro da tolerância; cadeia de métodos; rota de reserva; pesos de arquivo idênticos, bit a bit, ao cálculo online; esquema externo registrado em tempo de execução; preenchimento por vizinhança; esquema `mpassit` numa malha poligonal sintética, com valor de ausência fora da malha; e, com uma origem regional, que a rota de reserva usa o `zero_total`, o preenchimento por vizinhança e a troca de NaN da rota pedida; que o preenchimento pela rota dá, bit a bit, o mesmo campo e as mesmas contagens que `neighbor_fill` chamado à parte depois da interpolação, também com o preenchimento passado na chamada; e que ele vem antes da troca de NaN. Desde a R-FASE11-23, também: a base de pesos com pesos de identidade copia o campo, bit a bit; o `idw` com `vizinhos=1` dá o mesmo campo, bit a bit, que o `nearest_stod` do ESMF; o `idw` padrão erra menos de 3e-2; opção desconhecida e valor inválido são recusados; a leitura das opções em texto; e os pesos do `idw` gravados em arquivo e lidos pelo `weights_file` dão o mesmo campo, bit a bit. Passam com 1, 2, 3 e 4 processos. O script `tests/regrid/compara-esquema.bash` confere um esquema contra uma referência, com 1 e com vários processos (seção 2.15 de `docs/conferencias-locais.md`).
