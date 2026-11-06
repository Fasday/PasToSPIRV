# Контракт compute-языка 1.x

PasToSPIRV — самостоятельный **ограниченный compute-компилятор**. Номер 1.x
фиксирует перечисленный ниже профиль, а не означает полноту Delphi, GLSL, всех
Vulkan-возможностей или готовый runtime для приложений.

## Версионированные поверхности

- Source language 1.3: подмножество в `language.md`, `extended.md`, `modules.md`, `gpu.md`.
- Default target: SPIR-V 1.0 / Vulkan 1.0, compute entry Main.
  С 1.3.3 внешнее имя SPIR-V можно задать через `--entry-point` / project `entry_point` /
  последний параметр API `AEntryPointName`; исходная процедура остаётся `Main`.
  По умолчанию ничего не меняется. Хост использует reflection `entry_point` как `pName`.
  Explicit `[Vulkan12]`: SPIR-V 1.3 / Vulkan 1.2, новые scalar/storage types.
- Reflection ABI: `format_version=2`, std430 bytes. Потребители проверяют версию
  и не трактуют неизвестные descriptor types как storage buffers.
- Project JSON: format_version=1, строгие свойства, описанные в `build.md`.
- Library API: `Compile` без source filesystem I/O, `CompileFile` с явным поиском,
  `CompileResolved` без передачи ownership `TSourceProgram`. Результаты в памяти.

Для 1.x добавления планируются совместимыми, без молчаливого изменения числового
контракта, layout, memory scope или существующего descriptor type. Ломающие
изменения должны иметь отдельную версию/явный режим. Source type IDs и generated
`TPTS_TypeN` не являются постоянными идентификаторами между компиляциями.

## Что проверено

- Delphi 13 Win64, Vulkan SDK spirv-val для Vulkan 1.0, CPU/CLI/API регрессии.
- Реальное выполнение на доступном AMD Vulkan device: арифметика, layout,
  реальные общие `.inc`, atomics, shared reduction/barriers, storage images,
  nearest/linear sampling и O0/O1 equivalence.
- Отдельно компилируется generated Delphi ABI unit. Cache тестируется на
  invalidation, повреждении outputs/cache, новой ambiguity и input/output collision.
- Checkouts с одинаковой логической структурой не должны получать абсолютные
  filesystem paths в SPIR-V/reflection/bindings. Диагностика содержит локальные пути.

Это не сертификация всех GPU/драйверов. NVIDIA/Intel и другие Delphi targets
не объявляются проверенными без фактического запуска соответствующей матрицы.
Host проверяет Vulkan format features, workgroup/shared limits, descriptor ranges,
memory requirements и synchronization. Нет автоматической защиты от OOB/races.

## Явные ограничения

Нет Delphi classes/strings/interfaces/exceptions/heap, полноценных Delphi units,
рекурсии, `with`, методов/операторов записей, вариантных записей,
матриц, nonzero array lower bounds, image arrays/depth/cube/MSAA,
64-bit/float atomics, integer sampled textures и других shader stages.
Shared — одномерные scalar arrays; workgroup Barrier — только без if/loops в Main.
Добавлены helper procedures, Exit/Break/Continue/repeat/case, constant array tables
и optional Vulkan12 var/out. Ссылки только на function-local lvalues; доступ к
глобальным ресурсам из root helpers проверяет access qualifiers.

Const — finite scalar expressions из литералов/предыдущих констант, арифметики,
сравнений и numeric casts, плюс typed static array initializers; не произвольное
compile-time выполнение Pascal. С 1.3 есть константы записей и векторов.
С 1.0.1 Win64 parsing/constant evaluation выполняется с nearest SSE rounding,
без FTZ/DAZ, с masked exceptions; полный MXCSR вызывающего кода восстанавливается
в finally. Это не устанавливает режимы исполнения GPU: GPU denormals/NaN/rounding
не объявляются побитово эквивалентными CPU. Shared
source examples задают CPU wrapper flags и проверяют эквивалентность выбранных алгоритмов.

## Перед использованием

### Миграция с 0.5

- Пересоберите CLI и все shader artifacts/bindings вместе. ABI schema остаётся 2,
  но новые descriptor categories нельзя считать buffers. Новые top-level поля
  additive; проверяйте `profile`/поддерживаемые вами resource types.
- Same-named module exports теперь легальны. Неоднозначные обращения квалифицируйте
  `Module.Name`. В отражении имя составного типа модуля может быть qualified;
  ссылки по `type_id` надёжнее поиска по старому короткому имени.

### Расширения 1.1

- Профиль по умолчанию не изменился. Новые numerical/storage features требуют
  явного Vulkan12 и включения отражённых `required_features` на устройстве.
- Reflection ABI остаётся v2; новые scalar sizes/alignments заданы std430,
  regenerated bindings проверяются настоящим Delphi compiler.
- Byte/Word/Int64/UInt64/Double и новые intrinsics теперь зарезервированы.
- Суффикс d даёт exact binary64 literals. StrictFloat — явный запрос IEEE modes,
  не универсальное обещание bit-exact GPU division/stdlib/NaN payloads.
- Renderer/application migration не выполняется автоматически. Полный контракт
  и новые ограничения: [extended.md](extended.md).
- Const/resource operation names и новые built-ins зарезервированы. Если старый
  код использовал такие идентификаторы, переименуйте их.
- `Compile`/`CompileFile` сохраняют старые аргументы, добавлен optional optimize.
  `-SkipHostABI` в тестах остаётся alias `-SkipDelphiTests`.

### Изменения 1.2

- **Семантика `and/or` для `Boolean` изменена**: по умолчанию они сокращённые, как
  в Delphi (`{$B-}`). Если правый операнд вызывает функцию с побочными эффектами,
  читает буфер и т. п., он больше не выполняется, когда результат известен по левому.
  Для прежнего полного вычисления поставьте `{$B+}` / `{$BOOLEVAL ON}` в начало файла
  (и модулей — каждый `.pasm` начинается с `{$B-}`). Целочисленные `and/or` не изменились.
- Новые зарезервированные имена: `Ord`, `Sqr`, `Odd`, `Succ`, `Pred`, `Inc`, `Dec`,
  `Low`, `High`, `Length`, `SizeOf`. Переименуйте такие идентификаторы.
- Прежние ошибки стали допустимыми: вызов без `()`, `F := Value` внутри `F`,
  `A, B: T` в var/полях, локальные `const`, inline `var/const`, `for var`, диапазоны `case`.
- Профиль по умолчанию, layout, reflection ABI и числовой контракт не изменились.

### Изменения 1.3

- Добавлены перечисления, `set of`, `in`/`not in`, if-выражения, swizzles, многомерные
  массивы, константы записей и векторов, `forward`, `overload`, вложенные подпрограммы
  и несколько секций `type` подряд. Прежние исходники компилируются без изменений, кроме:
  - новых зарезервированных имён `Include` и `Exclude`;
  - `.R/.G/.B/.A` и многобуквенные селекторы вектора теперь swizzles.
- Перечисления и множества не допускаются в ресурсах, поэтому layout, reflection ABI v2
  и generated bindings не изменились. В reflection `language_version` равен `1.3`.
- Переменные, используемые вложенными подпрограммами, хранятся в Private памяти. Это
  видно в SPIR-V, но не меняет семантику: рекурсия по-прежнему запрещена.

### Проверочный прогон

1. Собрать CLI; выполнить полный `scripts/test.ps1` с Delphi ABI/API/CPU checks.
2. Выполнить `python tests/vulkan_smoke.py --require-shared-cpu` на целевом GPU.
3. Проверить собственные algorithms/edge cases на CPU и GPU, возможности устройства
   и потребление ресурсов. Не переносить сразу большой kernel без эталона.
4. Перегенерировать SPIR-V, reflection и bindings вместе. Не смешивать artifacts
   разных версий/исходников, не редактировать generated layout вручную.

Лицензия — MIT (см. LICENSE). Версия в репозитории не является GitHub release
или обещанием поддержки всех сред.
