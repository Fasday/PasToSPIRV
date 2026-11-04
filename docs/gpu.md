# GPU compute profiles

Цель — SPIR-V 1.0 / Vulkan 1.0, entry point `Main`. Это вычислительный профиль,
не полный Delphi, не все GPU-возможности и не готовый Vulkan runtime.

По умолчанию профиль сохранён. Явный `[Vulkan12]` добавляет SPIR-V 1.3 / Vulkan 1.2,
Byte/Word native storage, Int64/UInt64/Double и var/out. `[StrictFloat]` запрашивает
IEEE modes; host проверяет reflection `required_features` и float-controls properties.
`[Aliased]` обозначает перекрывающиеся storage-buffer views, не устраняя races.
Root helpers могут обращаться к видимым ресурсам/built-ins; atomics/barriers
сохраняют Main-only ограничения (вложенные подпрограммы Main — не Main). Перечисления
и множества в ресурсах не допускаются. Подробнее: [extended.md](extended.md).

## Атомики

```pascal
Previous := AtomicAdd(Counts[Index], 1);
Previous := AtomicExchange(Values[0], 20);
Previous := AtomicCompareExchange(Values[0], 20, 30);
```

- Только скалярные `Integer`/`Cardinal`, адресуемые в ReadWrite storage buffer
  или shared array. Скалярное поле/компонента внутри buffer допустимы.
- Возвращается **старое** значение. CompareExchange принимает `(Target, Compare, NewValue)`.
  При несовпадении target не меняется; возвращается фактическое старое значение.
- Вызов можно использовать отдельно, отбросив результат. Операции доступны только
  из `Main`; value-функции не получают скрытый доступ к ресурсам.
- Память: **relaxed**, Device scope для SSBO, Workgroup scope для shared.
  Атомарность не равна публикации/упорядочиванию других данных. Нет float/64-bit atomics.
- ReadOnly/WriteOnly не годятся для RMW. Обычное сложение не превращается в atomic автоматически.

Примеры: `examples/atomic_histogram.pas`, `tests/fixtures/atomic_values.pas`.

## Shared memory и синхронизация

```pascal
const BlockSize = 64;
type TScratch = array[0..BlockSize - 1] of Cardinal;
var
  [Shared] Scratch: TScratch;
```

- Одномерные статические массивы `Integer`, `Cardinal`, `Single`; без bindings,
  buffer access атрибутов, записей и векторных элементов. Сумма — максимум 16 KiB.
- Именованный тип shared-массива можно использовать и во внешних ресурсах. Для
  Workgroup-переменной компилятор выдаёт отдельный тип без `ArrayStride`
  (Vulkan запрещает explicit layout в Workgroup storage) и поэлементно
  преобразует значение при копировании всего массива в shared/из shared.
- Shared принадлежит одной рабочей группе. Начальное содержимое **не определено**;
  автор kernel должен организовать инициализацию и не допускать гонок.
- `Barrier;` / `Barrier()` — execution scope Workgroup, memory scope Workgroup,
  AcquireRelease + WorkgroupMemory. Это синхронизирует только группу и её shared memory.
- В 1.0 `Barrier` разрешён в `Main` только **вне всех `if`, `while`, `for`**.
  Даже `if True then Barrier` запрещено. Неусловный вложенный `begin/end` допустим.
  Это намеренная консервативная проверка, не полный анализ uniformity/завершения.
- В 1.1 запрет охватывает также repeat/case; Main с workgroup Barrier не может
  содержать Exit. Это всё ещё не доказательство отсутствия гонок или завершения.
- `BufferMemoryBarrier` — Device scope, AcquireRelease + UniformMemory;
  `ImageMemoryBarrier` — Device scope, AcquireRelease + ImageMemory.
  Это memory barriers без rendezvous. Между всеми группами execution-barrier нет.
- Нет автоматической защиты от data races, deadlocks, слишком долгих циклов
  или межгрупповых алгоритмов без корректного host dispatch/synchronization.

Built-ins только для чтения:

| Имя | Тип |
|---|---|
| `GlobalInvocationID` | Cardinal3 |
| `LocalInvocationID` | Cardinal3 |
| `LocalInvocationIndex` | Cardinal |
| `WorkgroupID` | Cardinal3 |
| `NumWorkgroups` | Cardinal3 |

Default local size — 64,1,1. Host обязан проверить размеры группы и shared memory
против лимитов устройства. `examples/shared_reduce.pas` — unrolled reduction
с барьерами между стадиями, включая неполную последнюю группу.

## Storage images

```pascal
var
  [Binding(0,0), ReadOnly] SourceImage: Image2D_R32UInt;
  [Binding(0,1), WriteOnly] DestinationImage: Image2D_R32UInt;
```

| Shader type | Vulkan format | Значение ImageLoad/ImageStore |
|---|---|---|
| Image2D_R32UInt | R32_UINT | Cardinal4 (полезный канал X) |
| Image2D_R32Int | R32_SINT | Integer4 (полезный канал X) |
| Image2D_RGBA32Float | R32G32B32A32_SFLOAT | Single4 |
| Image2D_RGBA8 | R8G8B8A8_UNORM | Single4, нормализованные каналы |

- `ImageSize(Image)` → Integer2.
- `ImageLoad(Image, Position)` → вектор из таблицы.
- `ImageStore(Image, Position, Value)` — отдельный оператор без результата.
- Position — Integer2/Cardinal2. Нельзя читать WriteOnly/писать ReadOnly.
  По умолчанию storage image ReadWrite. Binding/set уникальны среди всех descriptors.
- Это opaque resources, не массивы байтов и не аргументы пользовательских функций.
  Нет arrayed/multisample/depth/cube images, image atomics или неизвестных storage formats.
- Границы, format features, layout transitions, image views и host synchronization
  проверяет/задаёт приложение. Автоматических bounds checks и переходов layout нет.

Пример: `examples/storage_image.pas`. Тесты загружают/выгружают реальные optimal-tiling
изображения через transfer staging, проверяют все четыре заявленных формата.

## Sampled textures

```pascal
var
  [Binding(0,0)] SourceTexture: Texture2D;
  [Binding(0,1)] LinearSampler: Sampler;
// В Main:
Pixel := SampleLevel(SourceTexture, LinearSampler, UV, Lod);
```

- Texture2D — отдельный sampled-image descriptor с float/normalized sample type;
  Sampler — отдельный sampler descriptor. Не combined-image-sampler.
- UV — Single2, Lod — Single, результат — Single4. В compute нет скрытых derivatives:
  sampling всегда с **явным LOD**.
- Filter, addressing, mipmaps, min/max LOD и допустимый image format задаёт host.
  Nearest и linear проверены; linear требует соответствующего format feature.
- Нет integer/depth/cube/array textures, comparison sampling или неявного LOD.
  Texture2D не записывается через ImageStore.

Пример: `examples/sample_texture.pas`. GPU-тест проверяет nearest и bilinear
sampling, а не только создание pipeline.

## Reflection и bindings

Schema ABI остаётся v2. Добавлены `images`, `textures`, `samplers`, `shared`,
`workgroup_memory_bytes`, `uses_workgroup_barrier`, `profile`, `language_version`,
`optimization`. У image есть descriptor type, binding/set, Vulkan format и access.
У sampled texture/sampler — отдельные descriptor types. Shared не объявляет
host ABI и не требует Vulkan descriptor.

Generated Delphi unit оставляет packed value types только для буферов/push constants;
для opaque descriptors выдаются binding/set константы, не фиктивные record-пиксели.
Верхнеуровневый `layout=std430` относится только к внешним **байтовым** ресурсам.
