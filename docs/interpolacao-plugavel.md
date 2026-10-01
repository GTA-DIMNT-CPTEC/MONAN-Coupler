# Interpolação plugável (src/regrid)

Toda interpolação entre grades feita pelo acoplador passa por um único conjunto de módulos, em `src/regrid/`. O objetivo é que trocar ou acrescentar um esquema de interpolação (por exemplo, o método do MPASSIT) não exija procurar chamadas espalhadas pelo código.

## Onde a interpolação acontece

| Local | Situação |
| --- | --- |
| Mediador (`MED_cap.F90`, `med_cap_methods.F90`, `med_bulk_ncar.F90`) | Usa o framework: seis rotas com nome (tabela abaixo) |
| Cap atmosférico (`mpas_cell_binning.F90`, `state_set_field_1d`) | Interpolação própria da malha Voronoi para a grade de 1 grau (vizinho mais próximo com espalhamento). É o ponto de entrada natural do esquema `mpassit`; a troca muda resultados e depende de decisão científica |
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
  procedure, non_overridable     :: apply     ! execute + preenchimento por vizinhança
end type
```

| Módulo | Papel |
| --- | --- |
| `regrid_base` | `regridder_t`, `regrid_spec_t`, `regrid_fill_t` e o preenchimento por vizinhança (`neighbor_fill`) |
| `regrid_esmf` | Esquema `esmf`: pesos calculados pelo ESMF, com cadeia de métodos |
| `regrid_weights` | Esquema `weights_file`: pesos lidos de arquivo SCRIP/ESMF (variáveis `row`, `col`, `S`) |
| `regrid_mpassit` | Esquema `mpassit` e `mpas_mesh_create` (malha ESMF a partir das células Voronoi do MPAS) |
| `regrid_registry` | Catálogo de esquemas: nome e rotina que cria uma instância |
| `regrid_manager` | Rotas com nome, rota de reserva e troca por `nuopc.input` (`&nuopc_regrid`) |

Uso num componente:

```fortran
call is%regrid%add('ocn2atm_sst', regrid_spec('conserve,bilinear', mask_src=.true.), &
                   sst_ocn, sst_atm, rc, fallback='ocn2atm')      ! uma vez
call is%regrid%apply('ocn2atm_sst', sst_ocn, sst_atm, rc)          ! a cada passo
```

Cada rota guarda a configuração com que foi criada. Em `apply`, o `zero_total` (zerar o destino inteiro antes da interpolação, ou só os pontos alcançados) e a troca de NaN no destino (`nan_value` em `regrid_spec`, aplicada depois da interpolação e do preenchimento por vizinhança) vêm da rota pedida, mesmo quando ela usa a interpolação da reserva; o argumento opcional `zero_total` de `apply` ainda pode substituir o da rota. No mediador, as rotas são criadas por `cria_rota` (`med_cap_methods`), com a configuração da tabela `ROTAS` do mapa de acoplamento (`src/coupling/cpl_map.F90`).

## Como acrescentar um esquema

1. Criar um módulo com um tipo que estende `regridder_t` e implementa `setup`, `execute` e `release`.
2. Registrá-lo: `call regrid_register('meu_esquema', novo_meu_esquema, rc)`, ou incluí-lo em `register_builtins` (em `regrid_registry.F90`) se for de uso geral.
3. Selecioná-lo para uma rota em `nuopc.input` (`regrid_scheme(k) = 'meu_esquema'`).

O teste `tests/regrid/identity_scheme.F90` é um exemplo mínimo completo.

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

Os testes verificam: bilinear dentro da tolerância; cadeia de métodos; rota de reserva; pesos de arquivo idênticos, bit a bit, ao cálculo online; esquema externo registrado em tempo de execução; preenchimento por vizinhança; esquema `mpassit` numa malha poligonal sintética, com valor de ausência fora da malha; e, com uma origem regional, que a rota de reserva usa o `zero_total` e a troca de NaN da rota pedida. Passam com 1, 2, 3 e 4 processos.
