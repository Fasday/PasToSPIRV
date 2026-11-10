# PasToSPIRV

**Компилятор Pascal-шейдеров в SPIR-V для Vulkan, написанный на Delphi.**

Самостоятельный инструмент для вычислительных и явно выбранных графических шейдеров, не привязанный к
конкретному приложению или движку.

```text
Pascal-подмножество → лексер/парсер → типизированное дерево → SPIR-V → драйвер Vulkan → GPU
```

## Статус

Ветка разработки **1.4.1**: default **compute-vulkan1.0**, optional
**compute-vulkan1.1** / **compute-vulkan1.2** и компонент компиляции из памяти.
Явные стадии `[Vertex]` и `[Fragment]` описаны в [graphics.md](docs/graphics.md).
Компилятор напрямую записывает бинарный
SPIR-V: он не переводит исходник в GLSL и не вызывает сторонний компилятор.

Уже поддерживаются:

- compute entry point `procedure Main` и размер рабочей группы;
- vertex/fragment entry point, явные locations/built-ins, интерполяция, depth output,
  discard, fine derivatives и структурированный ordered pixel interlock;
- `Integer`, `Cardinal`, `Single`, локальный `Boolean`;
- optional Vulkan12: `Byte`, `Word`, `Int64`, `UInt64`, `Double`, native small storage;
- optional [Vulkan11](docs/vulkan11.md): те же типы и операции с явными требованиями к расширениям устройства;
- `Integer2/3/4`, `Cardinal2/3/4`, `Single2/3/4`, конструкторы и компоненты `.X/.Y/.Z/.W`;
- storage buffers с явными descriptor set/binding и правами доступа;
- один push-constant блок с записями, статическими массивами и векторами;
- именованные записи/массивы, вложенные поля и индексы, `Default(Type)`;
- `GlobalInvocationID.X`, `.Y`, `.Z`;
- арифметика, сравнения, битовые операции и числовые преобразования;
- `begin/end`, присваивания, `if/then/else`, `while/do`, `for/to/downto`;
- `Exit`, `Break/Continue`, `repeat/until`, `case/of/else` с диапазонами;
- inline `var`/`const`, `for var`, `A, B: T`, локальные `const`, `Inc/Dec`,
  `Low/High/Length/SizeOf`, `Ord/Odd/Sqr/Succ/Pred`, вызов без `()`;
- сокращённые `and/or` как в Delphi, полное вычисление — `{$B+}`/`{$BOOLEVAL ON}`;
- перечисления, `set of`, `in`/`not in`, if-выражения Delphi 13, swizzles `.XY`/`.RGB`,
  многомерные массивы, константы записей/векторов, `forward`, `overload`, вложенные подпрограммы;
- функции со скалярными/векторными/составными значениями, value-параметры и `Result`;
- процедуры, const value-параметры и настоящие local `var/out` в Vulkan12;
- доступ к ресурсам/built-ins из root helpers и read-only constant array tables;
- `Min`, `Max`, `Abs`, `Clamp`, `Dot`, `Sqrt`;
- bitcasts, Round/Trunc/Floor/Ceil/RoundEven, IsNan/IsInfinite, Ldexp, FindMSB/LSB;
- модуль `lib/SoftDouble.pasm`: деление Double с правильным округлением, побитово как x86-64 SSE2;
- диагностика с номером строки/столбца и проверка инициализации переменных;
- проверенный `std430` layout, JSON v2 и генерация Delphi-unit с явным padding;
- declaration-модули `.pasm`, `uses`, текстовые `{$I}`/`{$INCLUDE}` и карта исходных строк;
- граф зависимостей с SHA-256 и пример одних `.inc`, компилируемых Delphi для CPU и PasToSPIRV для GPU;
- скалярные `const`, константные выражения и квалификаторы `Module.Function/Type/Constant`;
- 32-битные атомики, shared-массивы и ограниченные workgroup/memory barriers;
- четыре типа storage image, float Texture2D/Sampler с явным LOD;
- пакетная сборка, проверяемый кеш и безопасная целочисленная оптимизация `-O1`.

**Пока нет:** полноценных Delphi units, матриц, `with`, методов записей, 64-bit/float atomics,
geometry/tessellation/mesh stages и произвольного препроцессора. Статические массивы только
с нулевой нижней границей; рекурсивные/вариантные записи не поддерживаются.
Общий CPU/GPU-пример использует явно ограниченный скалярный/POD-код;
это не автоматический перенос обычного Delphi-приложения.

Полный scope и проверенные среды — [docs/compatibility.md](docs/compatibility.md).
1.x не означает весь Delphi/GLSL или сертификацию всех GPU.
Новые типы, `[Vulkan12]`, `[StrictFloat]`, `[Aliased]` и их ограничения —
[docs/extended.md](docs/extended.md). Рендеры/приложения автоматически не переносятся.

## Сборка

Требуется установленный **Delphi с Win64-компилятором**. Проверено на Delphi 13
(dcc64 37.0); совместимость с более ранними версиями пока не проверена.

```powershell
.\scripts\build.ps1
```

Скрипт использует `BDS` или ищет Delphi в реестре. Путь можно задать явно:

```powershell
.\scripts\build.ps1 -DelphiRoot 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
```

Результат: `build\bin\PasToSPIRV.exe`. Для работы собранного компилятора
Vulkan SDK, Vulkan-драйвер и Python **не нужны**. Для открытия в IDE используется
`source\PasToSPIRV.dpr`, целевая платформа — Windows 64-bit.

Сборка под Win32 даёт тот же SPIR-V; модули компилятора также компилируются для
Linux, macOS, iOS и Android (на этих хостах тесты не запускаются):

```powershell
.\scripts\build.ps1 -Target win32 -CompilerName dcc32 -OutputDirectory .\build\win32
```

## Использование

```powershell
.\build\bin\PasToSPIRV.exe compile .\examples\scale.pas -o .\build\shaders\scale.spv
```

Будут созданы:

- `build\shaders\scale.spv` — бинарный SPIR-V 1.0 для Vulkan 1.0;
- `build\shaders\scale.json` — entry point, local size, bindings и layout параметров.

Слово `compile` необязательно. Без `-o` результат сохраняется рядом с исходником.
Путь JSON можно изменить через `--reflection <path>`.

Исходник шейдера можно назвать `shader.pasm`: расширение entry-файла не ограничено.
В отличие от подключаемого модуля, entry-файл содержит `procedure Main` и не имеет
заголовка `module`. Для хоста, который ожидает имя `main` в SPIR-V:

```powershell
.\build\bin\PasToSPIRV.exe compile shader.pasm --entry-point main -o .\build\shader.spv
```

В исходнике по-прежнему `procedure Main`; меняется только внешнее имя. Оно сохраняется
с учётом регистра в SPIR-V и reflection (`entry_point`), откуда хост берёт `pName`.

### Подключаемые модули и исходники

Для компиляции внутри приложения доступен невизуальный Delphi-компонент
`PTS.Component.TShaderCompilerComponent`. Он принимает текст шейдера и `.pasm`
зависимостей из памяти, не обращаясь к файловой системе и внешнему компилятору.
API, ресурсы и диагностика описаны в [docs/runtime.md](docs/runtime.md).

```powershell
.\build\bin\PasToSPIRV.exe compile .\examples\modules_compute.pas -I .\examples\modules -o .\build\modules.spv
```

Shader объявляет `uses SharedTypes, SharedMath, SharedBits;`. Каждый подключаемый модуль `.pasm` содержит
`module Name;`, зависимости и только constants/types/functions/procedures; include подключает общий `.inc`.
Повторные импорты и diamond-зависимости не дублируют объявления. Циклы, пропущенные
зависимости и неоднозначные пути диагностируются явно. Это минимальная модульность,
не поддержка Delphi `unit/interface/implementation`. Подробности — [docs/modules.md](docs/modules.md).

При одинаковых экспортируемых именах используйте `ScalarMath.Transform(...)`.
`const` может задавать размеры массивов и атрибуты: `const BlockSize = 8 * 8;`.

### GPU-ресурсы и batch build

- `examples/atomic_histogram.pas` — конкурентная гистограмма;
- `examples/shared_reduce.pas` — group reduction со shared memory и барьерами;
- `examples/storage_image.pas` — typed image load/store;
- `examples/sample_texture.pas` — float texture sampling с явным LOD.

```powershell
.\build\bin\PasToSPIRV.exe compile .\examples\shared_reduce.pas -O1 -o .\build\reduce.spv
.\build\bin\PasToSPIRV.exe build .\examples\project.json
```

Контракты ресурсов/синхронизации — [docs/gpu.md](docs/gpu.md), project JSON и cache —
[docs/build.md](docs/build.md). Cache повторно разрешает source graph и проверяет
hashes outputs; это не молчаливое доверие timestamp.

Генерация host-описаний ресурсов по тому же layout:

```powershell
.\build\bin\PasToSPIRV.exe compile .\examples\layout_records.pas -o .\build\layout.spv --bindings .\build\LayoutBindings.pas
```

Файл `.pas` содержит packed records, необходимые отступы/слоты массивов, aliases
элементов буферов, константы ABI и `PTS_ValidateLayouts`. Имя файла должно быть
простым Delphi-идентификатором с расширением `.pas`. Файл создаётся только при
явном `--bindings`; по умолчанию по-прежнему выдаются `.spv` и `.json`.

```powershell
.\build\bin\PasToSPIRV.exe --help
.\build\bin\PasToSPIRV.exe --version
```

Коды завершения: `0` — успех, `1` — ошибка исходного шейдера,
`2` — ошибка аргументов, ввода/вывода или внутренняя ошибка.
При ошибке разбора/типов существующие выходные файлы не изменяются.

## Пример

Shader-файл содержит необязательные `uses`/`type`, ресурсы, функции и процедуру `Main`;
обёртка `unit`/`program` не используется. Атрибуты ресурсов — часть диалекта.

```pascal
var
  [Binding(0, 0), ReadOnly]
  InputData: array of Single;

  [Binding(0, 1), WriteOnly]
  OutputData: array of Single;

  [PushConstant]
  Params: record
    Count: Cardinal;
    Scale: Single;
  end;

[LocalSize(64, 1, 1)]
procedure Main;
var
  Index: Cardinal;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
    OutputData[Index] := InputData[Index] * Params.Scale;
end;
```

Аргументы `Binding` — **descriptor set, binding**, в этом порядке.
Массивы в этом примере соответствуют `VK_DESCRIPTOR_TYPE_STORAGE_BUFFER`; шаг элементов — 4 байта.
Push constants в примере: `Count` по смещению 0, `Scale` по смещению 4, всего 8 байт.
Имя entry point для `VkPipelineShaderStageCreateInfo.pName` по умолчанию — **`Main`**,
либо значение `--entry-point` (регистр важен). Оно указано в reflection `entry_point`.

Хост-приложение самостоятельно создаёт Vulkan-ресурсы, передаёт параметры,
задаёт dispatch и обеспечивает синхронизацию. Автоматических проверок границ
буферов нет. Файл `.spv` ещё не является машинным кодом видеокарты — окончательную
компиляцию выполняет драйвер.

### Функции и циклы

Функции объявляются **до `Main`**, вызываемые функции — до вызывающих.
Функция возвращает значение через `Result`; рекурсия и прямой доступ к GPU-ресурсам
из функций запрещены. Нужные значения, включая записи и массивы, передаются параметрами:

```pascal
function ScaleValue(Value, Factor: Single): Single;
begin
  Result := Value * Factor;
end;
```

Полный пример функций с `for` — [examples/functions_for.pas](examples/functions_for.pas).
Счётчик `for` — локальный `Integer`/`Cardinal`; обе границы вычисляются один раз.
Нельзя менять счётчик в теле или читать его после цикла без нового присваивания.

### Векторная математика

```pascal
function Transform(Value: Single3; Factor: Single): Single3;
begin
  Result := Clamp(Value * Factor, -1.0, 1.0);
end;

function LengthOf(Value: Single3): Single;
begin
  Result := Sqrt(Dot(Value, Value));
end;
```

Полный compute-пример — [examples/vector_math.pas](examples/vector_math.pas).
Поддерживаются конструкторы из отдельных компонентов, заполнение одним скаляром,
сочетания скаляров и векторов (`Single4(Position, 1.0)`), преобразования векторов
одинаковой ширины и покомпонентная арифметика.
В арифметике скаляр может распространяться на компоненты вектора; присваивание
скаляра в вектор требует явного конструктора, например `Single3(0)`.

Векторы также доступны в буферах и push constants. Например, значение `Single3`
занимает 12 байт, но шаг его массива — **16**, а не 12 байт.

### Записи и статические массивы

```pascal
type
  TItem = record
    Position: Single3;
    Weight: Single;
    Samples: array[0..1] of Single3;
    Tag: Cardinal;
  end;
```

Для `TItem` смещения полей — **0, 12, 16, 48**, размер/шаг массива — **64**,
выравнивание — **16**. `Weight` использует место после трёх компонентов,
а элементы `Samples` занимают слоты по 16 байт.

Полный пример — [examples/layout_records.pas](examples/layout_records.pas).
Локальную запись перед изменением полей можно обнулить через `Default(TItem)`;
целые записи/массивы копируются и передаются по значению. Внешний ABI вычисляет
компилятор, а не `SizeOf` обычного Delphi record. Подробности и формат JSON —
[docs/layout.md](docs/layout.md).

## Тесты

Для проверок компилятора нужен **Vulkan SDK**: `spirv-val` и `spirv-dis` в `PATH`
либо `VULKAN_SDK`. Наличие GPU для этих тестов необязательно. По умолчанию также
компилируется и выполняется сгенерированный Delphi-unit для проверки размеров и смещений.
Также проверяются source API, разрешение модулей/include и CPU reference общего исходника.

```powershell
.\scripts\test.ps1
```

Проверяются арифметические/логические операции, преобразования, управляющий поток,
вызовы функций, области видимости, запрет рекурсии, `Result`, счётчики `for`,
векторы всех трёх числовых семейств и ширин, intrinsics, ошибки типов,
инициализация, layout ресурсов, диагностика, сохранность выходных
файлов при ошибке и детерминированность. Каждый успешный shader-fixture проходит
`spirv-val --target-env vulkan1.0`.

`-SkipBuild` пропускает пересборку основного компилятора, но не Delphi ABI/API/CPU-тесты.
На машине с готовым `.exe`, но без Delphi их можно явно отключить:
`scripts\test.ps1 -SkipBuild -SkipDelphiTests`. Старый `-SkipHostABI` остаётся alias.
Пропуски отмечаются предупреждениями, не считаются выполненными проверками.

Дополнительно: реальное выполнение примеров через Vulkan с проверкой результата
против CPU-эталона. Нужны 64-битный Python 3.9+, Vulkan loader и compute-устройство
с host-visible/host-coherent памятью; сторонних Python-пакетов нет.

```powershell
python .\tests\vulkan_smoke.py --require-shared-cpu
python .\tests\vulkan_graphics.py
```

Второй скрипт рисует настоящими vertex/fragment pipelines и читает combined textures;
для него нужна очередь с graphics-возможностями. Smoke-тест проверяет масштабирование массива, целочисленный цикл с переполнением
и логическими сдвигами, неполную рабочую группу, неизменность хвоста и `Count = 0`.
Отдельный dispatch проверяет 16 числовых граничных случаев: знаковые `div/mod`,
маскирование количества сдвига, числовые преобразования и wraparound.
Также проверяются функции с параметрами/результатами всех четырёх типов,
неизменность аргументов, векторные параметры/результаты, запись компонентов,
числовые преобразования, NaN и знаковый ноль, пустые и вложенные `for`, однократное
вычисление границ и завершение на крайних значениях `Integer`/`Cardinal`.
Проверяются вложенные `std430` записи/массивы, push constants, все числовые формы
элементов буфера и value-семантика составных типов. Ожидаемые смещения задаются
в тестах независимо от JSON; padding не считается частью значения записи.
Общие `examples/shared/*.inc` компилируются настоящим Delphi CPU reference и GPU
компилятором: целые сравниваются побитово, выбранные конечные `Single` — с допуском
`1e-6`. Нужен свежий `SharedSourceCheck.exe`, который собирает `scripts/test.ps1`.
Без `--require-shared-cpu` отсутствие этого helper явно предупреждается и только
данное сравнение пропускается. Это не обещание эквивалентности любого Delphi-кода.
Это небольшая тестовая обвязка, не готовый runtime для приложений.

## Пример приложения: карандашный эскиз и бенчмарк

[`examples/sketch`](examples/sketch/README.md) — консольное приложение на Delphi:
эскиз изображения (WIC: JPEG/PNG/BMP…) на CPU в 1 поток, на всех ядрах и
compute-шейдером PasToSPIRV на Vulkan. Время меряется `QueryPerformanceCounter`
и Vulkan timestamps. Общая целочисленная математика компилируется обоими
компиляторами, результат GPU сверяется с CPU побитово. Там же GUI-демо на VCL
и FMX; в FMX-демо для сравнения есть штатный фильтр `TFilterPencilStroke`.
Оба GUI также создают цветные **миниатюры (thumbnails)** с сохранением пропорций:
CPU в 1 поток / все ядра, area-фильтр на Vulkan и штатный `TBitmap.CreateThumbnail` в FMX.

```powershell
.\examples\sketch\build.ps1
.\build\bin\SketchBench.exe
.\build\bin\SketchVCL.exe   # или SketchFMX.exe
```

## Документация

- [Поддерживаемый язык и числовые правила](docs/language.md)
- [Расширения 1.1 и optional Vulkan 1.2](docs/extended.md)
- [Профиль Vulkan 1.1](docs/vulkan11.md)
- [Графические стадии, interlock и combined textures](docs/graphics.md)
- [Компиляция из памяти и компонент](docs/runtime.md)
- [SoftDouble: точное деление Double](docs/softdouble.md)
- [Аудит 1.3.3/1.4.0 и исправления 1.4.1](docs/audit-1.4.1.md)
- [Аудит синтаксиса 1.2/1.3 и исправления 1.3.2](docs/audit-1.3.2.md)
- [Аудит расширений и исправления 1.1.1](docs/audit-1.1.1.md)
- [Повторный аудит и исправления 1.1.2](docs/audit-1.1.2.md)
- [Архитектура и следующие этапы](docs/architecture.md)
- [GPU layout, JSON v2 и сгенерированные Delphi bindings](docs/layout.md)
- [Модули, include, source API и общий CPU/GPU-пример](docs/modules.md)
- [GPU atomics/shared/images/samplers](docs/gpu.md)
- [Project build, cache и benchmark](docs/build.md)
- [Контракт и ограничения 1.x](docs/compatibility.md)
- [Аудит корректности и исправления 1.0.1](docs/audit-1.0.1.md)
- [Второй аудит и исправления 1.0.2](docs/audit-1.0.2.md)

Лицензия — MIT, см. [LICENSE](LICENSE).
