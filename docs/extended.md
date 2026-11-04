# Язык 1.1: расширенный compute-профиль

Компилятор выдаёт SPIR-V напрямую, без GLSL/glslang. Профиль по умолчанию —
**SPIR-V 1.0 / Vulkan 1.0**. Новый профиль выбирается явно в исходнике:

```pascal
[Vulkan12, StrictFloat, LocalSize(16, 16, 1)]
procedure Main;
begin
end;
```

`Vulkan12` означает SPIR-V 1.3 для Vulkan 1.2. Необязательный `StrictFloat` требует
`Vulkan12`. Оба атрибута допустимы только на Main. Reflection содержит `profile`,
`target_env`, `spirv_version`, `strict_float` и массив `required_features`.
Host проверяет и включает device features; compiler не выбирает GPU и не меняет
настройки Vulkan. Старые исходники не переключаются на Vulkan 1.2 автоматически.

## Скалярные типы и арифметика

В `Vulkan12` добавлены **Byte, Word, Int64, UInt64, Double**: настоящие SPIR-V типы,
не упакованные 32-битные элементы. Новые типы пока скалярные, без vector-вариантов.

- Integer operations имеют модульную семантику ширины типа: 8/16/32/64 бит.
  Это не автоматическое продвижение Byte/Word в Delphi Integer.
- `div` округляет к нулю; знаковый `mod` сохраняет знак делимого. Деление на ноль
  и `Low(signed) div -1` остаются неопределёнными.
- `shr` всегда **логический**, в том числе для Int64. Счётчик сдвига маскируется
  через `width-1`. Для знакового заполнения есть `ArithmeticShiftRight`.
- Типизированные целые разных типов смешиваются только через явный cast.
  Нетипизированные integer literals/constants адаптируются только при представимости.
  Выражение из нетипизированных констант вычисляется в своём типе (обычно Integer,
  по модулю 2^32). Если оно при этом **обернулось** (переполнение, сдвиг на счётчик
  ≥ ширины, unsigned `not`, `shr` отрицательного), неявное преобразование в другой
  целый тип запрещено с диагностикой: `L: Int64 := 100000 * 100000` — ошибка,
  пишите `Int64(100000) * 100000`. Присваивание в тот же тип сохраняет прежнюю
  модульную семантику 1.0 (`I := 2147483647 + 1`). Обёрнутая нетипизированная
  `const` сохраняет свой узкий тип и сама не расширяется.
  Явное сужение сохраняет младшие биты, расширение signed сохраняет знак.
- Литералы до 32 бит сохраняют прежние типы; большие получают Int64 или UInt64.
  Максимум — `$FFFFFFFFFFFFFFFF`. `-9223372036854775808` поддерживается.
- Обычный real literal остаётся Single. Суффикс **d** задаёт Double: `0.5d`,
  `1e-300d`. Binary64 округляется один раз из точного decimal (subnormal/ties-to-even).
  `Double(0.1)` — cast уже округлённого Single; используйте `0.1d` для binary64 literal.
- Double распространяется на смешанное float-выражение. Неявное Double→Single
  запрещено. `/` даёт Double при Double-операндах, иначе сохраняет Single-контракт.
  `Min/Max/Abs/Clamp/Sqrt` поддерживают Double.

std430 sizes/alignments: Byte 1/1, Word 2/2, Int64/UInt64/Double 8/8. Внешние записи,
массивы, reflection и generated Delphi bindings используют общий `PTS.Layout`.
Boolean в ресурсах запрещён рекурсивно. Atomics остаются 32-битными, shared memory
сохраняет прежний ограниченный профиль.

## Числовые intrinsics

| Вызов | Контракт |
|---|---|
| `SingleToBits(Single)` / `BitsToSingle(Cardinal)` | Побитовая интерпретация 32 бит |
| `DoubleToBits(Double)` / `BitsToDouble(UInt64)` | Побитовая интерпретация 64 бит |
| `RoundEven(X)` | Тот же Single/Double, nearest-even |
| `Round(X)` / `Trunc(X)` | Int64, nearest-even / toward zero |
| `Floor(X)` / `Ceil(X)` | Integer, округление вниз / вверх |
| `IsNan(X)` / `IsInfinite(X)` | Boolean для scalar Single/Double |
| `Ldexp(X, Exponent)` | X того же float-типа × 2^Exponent; Exponent: Integer |
| `FindMSB(X)` / `FindLSB(X)` | Integer для Integer/Cardinal; для нуля -1 |
| `ArithmeticShiftRight(X, Count)` | Integer/Int64, знаковый сдвиг с masked count |

`Round/Trunc/Floor/Ceil` проверяют округлённое значение до integer conversion.
NaN, infinity и выход за диапазон дают `Low(Int64)` / `Low(Integer)`. Это отдельный
определённый контракт intrinsics; обычный float→integer cast вне диапазона всё ещё
не имеет гарантии. `FindMSB` отрицательного Integer ищет старший бит, отличный
от знакового, как SPIR-V FindSMsb. Bitcasts не выполняют numeric conversion.

### StrictFloat — не универсальная CPU/GPU эквивалентность

Для используемых float-разрядностей запрашиваются `DenormPreserve`,
`SignedZeroInfNanPreserve`, `RoundingModeRTE`; отдельные float `+ - * /` сохраняют
`NoContraction`. Host проверяет properties, включая правила
`denormBehaviorIndependence` / `roundingModeIndependence`.

Это **не обещание** побитовой точности всех float operations. Native GPU Double
division, sqrt/ldexp, NaN payloads и другие операции проверяются для конкретного
алгоритма/устройства. Для точного деления при необходимости можно реализовать
software arithmetic через UInt64 и bitcasts. Compiler не подменяет Double на Single
и не вызывает внешние библиотеки/компиляторы.

## Процедуры, ссылки и ресурсы

```pascal
procedure Advance(var Value: Integer; out Previous: Integer);
begin
  Previous := Value;
  Value := Value + 1;
end;
```

- Helpers бывают function/procedure, объявляются до вызова (или через `forward`),
  могут перегружаться и вкладываться (language.md, «Синтаксис 1.3»); рекурсия
  запрещена. Нулевой вызов — `F` или `F()`. Function call отдельным оператором отбрасывает
  результат, но не side effects.
- Обычный параметр остаётся изменяемой копией по значению. `const` — read-only
  value parameter. `var/out` требуют Vulkan12 и имеют **настоящую ссылочную семантику**.
- `var/out` принимают writable function-local lvalues: целые переменные, поля,
  компоненты и динамически индексируемые элементы локальных массивов. Типы и
  идентичность агрегатов совпадают точно. Ресурсы, shared, push constants, константы,
  temporaries и активный for-counter передавать по ссылке нельзя.
- Алиасы сохраняются: `F(A,A)` и `F(R,R.Field)` видят записи друг друга. Нет
  copy-in/copy-out под видом ссылок. Compiler специализирует memory-object root
  и пути к полям, вычисляя dynamic indices один раз в порядке аргументов.
  VariablePointers device feature не нужен. Бюджет — 4096 специализаций.
  У каждой функции максимум 255 параметров, включая дополнительные параметры
  индексов в специализации: большие сигнатуры отклоняются до выдачи артефактов.
- `var` требует initialization до вызова; `out` — присваивания на каждом возврате
  callee. Чтение out до присваивания запрещено. Перед частичной записью в агрегат
  по-прежнему нужна whole-value initialization (`Default(Type)` и т.п.).
  Захват ссылки на целую переменную сам не читает её: более поздний value-аргумент
  может инициализировать её перед входом в callee. Но out того же вызова не делает
  ранее вычисленный value-аргумент или неинициализированный var допустимым.
- Объявленные в shader helpers могут читать/писать видимые buffers, push constants,
  shared, images, textures/samplers и invocation built-ins. ReadOnly/WriteOnly
  сохраняются. Модули остаются declaration-only, без неявного импорта ресурсов
  consuming shader; root helpers объявляются после ресурсов.
- Atomics/barriers остаются Main-only. Workgroup Barrier нельзя помещать внутрь
  if/loop/case. Main, использующий workgroup Barrier, не может содержать Exit.

## Управление потоком и таблицы

Добавлены **Exit, Exit(Value), Break, Continue, repeat/until, case/of/else**.
Exit(Value) разрешён только в function. Case поддерживает до 16383 constant labels, списки
через запятую и (с 1.2) диапазоны `Low..High`, без fall-through. Break относится к циклу, не case;
Continue в repeat переходит к until. Definite assignment учитывает возвраты,
ветви case, break/continue и реальные loop back-edges. После for его counter
нельзя читать без нового присваивания. Недостижимый код проверяется по синтаксису
и типам, но не добавляет ложных требований initialization.

```pascal
type TTable = array[0..3] of Integer;
const Table: TTable = (2, 4, 8, 16);
```

Typed constant tables — статические массивы скаляров/вложенных массивов с точным
числом элементов и runtime indexing в helpers/Main. Это read-only Private storage
со SPIR-V constant initializer, не descriptor. Запись и передача в var/out запрещены.
Константы записей и векторов описаны в language.md; compile-time выполнения функций нет.
Одна размерность constant initializer ограничена 65532 элементами (SPIR-V word count);
остальные бюджеты типов сохраняются.

## Перекрывающиеся buffer views

`[Aliased]` на storage buffers позволяет явно обозначить descriptors одной GPU-памяти
(Byte/Word/Cardinal views и т.п.). Признак отражается в JSON и SPIR-V Aliased.
Все перекрывающиеся views помечаются; host задаёт sizes, offsets, alignment и
synchronization. Атрибут **не делает записи атомарными**, не добавляет barriers и
не разрешает гонки. Native 16-bit store не заменяется 32-bit read-modify-write.

## Проверка

```powershell
.\scripts\build.ps1
.\scripts\test.ps1 -SkipBuild
python .\tests\vulkan_smoke.py --require-shared-cpu
python .\tests\vulkan_extended.py
python .\tests\audit_numeric_gpu.py --count 256
```

Test.ps1 сохраняет Vulkan 1.0 validation старых fixtures и проверяет новые profile
fixtures для Vulkan 1.2 в O0/O1, generated Delphi ABI и (при Python) независимый
Fraction-оракул binary64 midpoint/tie/sticky literals. Extended GPU-тест требует
свежий `ExtendedNumericCheck.exe` из test.ps1 и подходящее устройство. Он сравнивает
числа с настоящим Delphi Win64 и проверяет reference aliases, control flow и native
memory views. Это не сертификация всех GPU/драйверов и не готовый рендер.
