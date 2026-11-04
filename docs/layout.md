# GPU layout и Delphi bindings — 0.4

Внешние данные используют **std430**: storage buffers и push constants.
Компилятор не наследует размещение обычных Delphi records, `$A`, размер указателя
или другие настройки хоста. `PTS.Layout` — единый источник размеров/смещений для
SPIR-V, JSON и generated bindings.

## Правила размещения

| Тип | Размер значения | Базовое выравнивание | Шаг массива |
|---|---:|---:|---:|
| `Integer`, `Cardinal`, `Single` | 4 | 4 | 4 |
| Числовой вектор 2 | 8 | 8 | 8 |
| Числовой вектор 3 | 12 | 16 | 16 |
| Числовой вектор 4 | 16 | 16 | 16 |

- Поле начинается на следующем смещении, кратном его выравниванию.
- Выравнивание записи — максимум выравниваний полей; размер округляется вверх
  до этого выравнивания. В отличие от std140, обязательного округления всех
  структур/массивов до 16 нет.
- Шаг массива — размер элемента, округлённый до его выравнивания.
  Статический массив занимает `Length * Stride`, вложенные массивы — по тем же правилам.
- Runtime storage buffer — массив таких элементов со смещением первого элемента 0.
- `Single3` может соседствовать со скаляром по смещению 12. Но самостоятельный
  элемент массива `Single3` всё равно занимает слот 16 байт.
- `Boolean` запрещён во внешних данных на любой глубине. Его локальная
  SPIR-V форма не является внешним сериализуемым ABI.

Пример из [layout_records.pas](../examples/layout_records.pas):

```pascal
type
  TItem = record
    Position: Single3;                 // offset 0, size 12
    Weight: Single;                    // offset 12, size 4
    Samples: array[0..1] of Single3;    // offset 16, size 32, stride 16
    Tag: Cardinal;                     // offset 48, size 4
  end;                                 // size/stride 64, alignment 16
```

В байтах 52..63 — хвостовое выравнивание. Padding не является частью значения:
целое присваивание записи или `Default(Type)` на GPU не обещает его копирования
или обнуления. Сравнивать результаты следует по полям, не по незначащим байтам.

Размер push-constant блока включает хвостовое выравнивание и ограничен 128 байтами
в этой версии. Статический массив ограничен 65536 элементами, статический тип —
16 MiB и глубиной 32. Это пределы компилятора, а не гарантия устройства.

## Отражение ресурсов: JSON v2

**`format_version` изменён с 1 на 2.** Скалярные `set`, `binding`, `array_stride`,
`members[].offset` сохраняют смысл, но теперь нужно учитывать составные типы и
их выравнивание. В корне добавлено `layout: "std430"`.

- `buffers[]`: имя, `descriptor_type`, set/binding, доступ, `element_type`,
  `element_size`, `element_alignment`, `array_stride`, а для агрегата — `type_id`.
- `push_constants[]`: имя, type/type_id, offset, полный size/alignment, stage,
  непосредственные `members` с именами, type/type_id, offset, size и alignment.
- `types[]`: нормализованный граф **внешних** составных типов. Локальные типы,
  не участвующие в ресурсах, здесь отсутствуют.
  - запись: `id`, name, kind=`record`, size/alignment, `members`;
  - массив: `id`, name, kind=`array`, size/alignment, length, lower_bound=0,
    array_stride, element_type, element_size/alignment, опциональный element_type_id.

Ссылки `type_id` и `element_type_id` разрешаются по `types[].id`, **не по индексу
в массиве**. Так можно обходить вложенные записи/массивы без раздувания JSON
копиями одинаковых описаний. Имена встроенных типов канонические (`Single3` и т. п.).
Псевдоним агрегата ссылается на тот же id. Анонимные типы получают служебные имена
`$anonymousN`; id действуют только для конкретного артефакта, не являются
постоянными идентификаторами между сборками.

Начиная с 0.5 file compilation добавляет `sources`, `modules`, `source_dependencies`
для source provenance. Версия ABI остаётся 2; граф исходников не меняет вычисление
layout. Контракт этих дополнительных полей — [modules.md](modules.md).

Например, запись `TItem` ссылается на отдельное описание массива `TWeights` через
поле `Samples.type_id`. Размер `TItem` и шаг буфера совпадут — 64, но у буфера
`array of Single3` `element_size = 12`, `element_alignment = 16`, `array_stride = 16`.
Не подменяйте одно значение другим.

## Генерация host unit

```powershell
.\build\bin\PasToSPIRV.exe compile .\examples\layout_records.pas -o .\build\layout.spv --bindings .\build\LayoutBindings.pas
```

Имя файла — простой Delphi unit identifier: ASCII-буквы/цифры/`_`, первый символ не цифра,
без ключевых слов, пробелов, дефисов и namespace-точек; расширение `.pas`.
Встроенные имена, `System` и префиксы `PTS_`/`TPTS_`/`PTPTS_` зарезервированы
для предотвращения конфликтов с RTL и сгенерированными идентификаторами.
RTL-имена в сгенерированном коде квалифицированы (`System.Byte`, `System.SizeOf`,
`System.NativeUInt`, `System.SysUtils.EInvalidOpException`), поэтому unit может
называться, например, `SizeOf` или `Byte`. Идентификаторы шейдера ограничены 127
символами, так что сгенерированные строки и имена остаются в пределах Delphi.
Каталог может содержать пробелы. В сгенерированном файле:

- числовые векторы `TPTS_Single3` и аналогичные — packed records с X/Y/Z/W;
- `TPTS_TypeN` — записи/статические массивы ресурсов, с явными padding-полями;
- поля пользовательских записей имеют префикс `F_`;
- если array stride больше размера значения, используется packed slot с полем
  `Value` и отступом. Например, статический массив `Single3` индексируется как
  `Samples[I].Value`, а массив `Single2` не требует slot и индексируется напрямую;
- `TPTS_Buffer_<Name>_Element` — **тип слота буфера**, его `SizeOf` равен stride;
- `TPTS_Push_<Name>` — тип push блока;
- константы размера/выравнивания, stride, set/binding и смещений полей;
- `PTS_ValidateLayouts` — проверка `SizeOf` и смещений полей реальным Delphi-компилятором.

Пример на **стороне хоста**, не shader-код:

```pascal
uses LayoutBindings;

var
  Item: TPTS_Buffer_InputData_Element;
  Params: TPTS_Push_Params;
  Vectors: array[0..1] of TPTS_Buffer_VectorData_Element;
begin
  PTS_ValidateLayouts;
  FillChar(Item, SizeOf(Item), 0);
  Item.F_Position.X := 1;
  Item.F_Samples[1].Value.Y := 2;
  Vectors[0].Value.Z := 3; // SizeOf(Vectors[0]) = 16, не 12
  FillChar(Params, SizeOf(Params), 0);
  Params.F_Count := 1;
  Params.F_Scale := 2;
end;
```

Не редактируйте generated unit вручную; пересоздавайте его вместе со SPIR-V.
Для интеграции предпочтительны ресурсные aliases и константы, а не вручную
запомненные `TPTS_TypeN`: номера могут измениться после правки исходника.

**Packed record гарантирует смещения, но не выравнивание внешнего выделения памяти.**
Отдельно проверяются Vulkan memory requirements, диапазоны/смещения descriptors,
`minStorageBufferOffsetAlignment`, допустимые push ranges и синхронизация.
Эти действия остаются обязанностью host-приложения. Готового runtime/allocator
генератор не создаёт. Поддержка проверена с Delphi Win64; это не обещание ABI
неизвестной CPU-платформы или полного совпадения обычных Delphi records.

## Как проверяется ABI

1. Независимые таблицы размеров/смещений в `tests/layout.ps1`, включая vec3+scalar,
   vec2/vec3 arrays, вложенные записи, padding и идентичность типов.
2. Каждый успешный shader проверяется `spirv-val --target-env vulkan1.0`.
3. Генерируется `LayoutBindings.pas`, компилируется `tests/BindingsCheck.dpr`,
   выполняются проверки `SizeOf`, смещений и размеров slots.
4. Vulkan-тесты пакуют данные по заранее заданным смещениям, **не извлечённым
   из JSON**, и сравнивают поля с CPU-эталоном. Проверяются value-параметры,
   nested arrays/push constants, все числовые формы элементов ресурсов и хвосты буферов.

Валидация SPIR-V не заменяет эти проверки: неверные, но допустимо выровненные
смещения способны пройти validator и всё равно нарушить контракт с хостом.
