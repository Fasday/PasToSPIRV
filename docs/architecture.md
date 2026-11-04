# Архитектура и план

## Текущая цепочка

```text
CompileFile: UTF-8 files → PTS.SourceLoader → mapped root + dependency-ordered modules
Compile: source string (no source filesystem resolution)
  → TLexer (original-file positions)
  → TParser: syntax + scopes + value/aggregate typing + definite assignment
  → PTS.Layout: std430 size/alignment/offset/stride
  → TShaderModule: types + resources + functions with typed trees
  → PTS.Profile: explicit target/features check
  → TSPIRVWriter: binary SPIR-V 1.0 (optional Vulkan12: SPIR-V 1.3)
  → TCompilationResult: SPIRV bytes + reflection JSON + optional Delphi bindings
```

Типизированное дерево — начальная форма IR. Отдельного SSA/низкоуровневого
оптимизирующего IR пока нет. Локальные переменные представлены SPIR-V Function
variables, а не самостоятельно построенными Phi-узлами. Ветвления и циклы
порождают структурированные selection/loop merge блоки.

Функции получают скалярные/векторные/составные `OpFunctionParameter`, копируемые в локальные
Function variables для обычной семантики изменяемых value-параметров. Вызовы
выдаются как `OpFunctionCall`, возврат — `OpReturnValue` из локального `Result`.
`OpTypeFunction` кешируется по полной сигнатуре, не дублируется для разных имён.
Root helpers могут обращаться к видимым GPU-ресурсам с access checking. Ацикличность
графа вызовов (с `forward` и вложенными подпрограммами) проверяет `CheckCallGraph` после
разбора. Переменные, используемые вложенными подпрограммами, становятся Private
OpVariable уровня модуля: без рекурсии у функции одна активация. Сводки
`CaptureReads/CaptureWrites` вложенных подпрограмм используются анализом инициализации
в местах вызова.

`PTS.References` описывает специализации var/out: вместо запрещённого Function
access-chain pointer в OpFunctionCall передаются memory-object root и dynamic
indices. Callee строит путь к полю из своего pointer parameter. Поэтому сохраняются
алиасы/overlapping fields, без копирования туда-обратно и без VariablePointers.
`PTS.FlowAnalysis` строит CFG для Exit/Break/Continue/repeat/case и reference calls:
must-initialization вычисляется пересечением состояний с учётом loop back-edges.
Для прежнего structured subset остаётся проверенный summary checker `PTS.Analysis`.

Модули — declaration-only `.pasm`, не Delphi units. `PTS.SourceLoader`
разворачивает own-line include, разрешает заголовки `module/uses`, проверяет циклы,
неоднозначность и budgets. Файлы читаются однократно в рамках вызова с SHA-256
сырых байтов. `TSourceDocument.Origins` отображает строки развёрнутого текста
обратно в физический файл; заголовки маскируются пробелами без сдвига координат.

Library-декларации разбираются до entry file в общем AST. Имена экспортов индексируются
по `(module,name)`, own names приоритетны, ambiguity требует qualifier. У функций и named type references
сохраняется module owner. Parser проверяет доступность через собственные/transitive
`uses`, поэтому посторонний ранний импорт shader не создаёт неявную зависимость.
Видимые объявления не затеняются; локальные имена не зависят от несвязанных модулей.

`PTS.Types` описывает встроенные типы, их компонентный тип и ширину; frontend
проверяет размерность независимо от числовых преобразований. Неявный scalar
broadcast разрешён в арифметике и соответствующих intrinsics, но не в присваиваниях.
Векторы представлены `OpTypeVector`, конструкторы — `OpCompositeConstruct`,
чтение компоненты — `OpCompositeExtract`, запись — Function `OpAccessChain`.
Частично инициализированных векторов нет: перед записью компоненты требуется
инициализация всего значения. Векторные сравнения `=/<>` сворачиваются через
внутренние Boolean-векторы и `OpAll/OpAny` к одному `Boolean`.

Составной тип представлен тегом `stComposite` и невладеющей ссылкой на descriptor
записи/массива. Descriptor хранит поля/element type и вычисленный layout; module
владеет всеми descriptors. Псевдонимы сохраняют ссылку, отдельные объявления
имеют разную идентичность. Структуры/массивы выдаются как `OpTypeStruct/OpTypeArray`,
`Default(Type)` — как `OpConstantNull`. Адресуемые поля/индексы используют
`OpAccessChain`; поля/литеральные индексы rvalue — `OpCompositeExtract`.

Внешние resource wrappers отделены от пользовательских типов: `BufferBlock`
у SSBO-обёртки runtime array, `Block` у push-обёртки с единственным member offset 0.
В Vulkan12 SSBO использует StorageBuffer storage class и Block. Native Byte/Word
не превращаются в 32-битные RMW. Aliased явно декорирует overlapping views.
Пользовательская запись не получает `Block`, поэтому один тип можно одновременно
использовать в буфере, push constants и функции без запрещённой вложенности блоков.
`Offset/ArrayStride` добавляются для типов, достижимых из внешних ресурсов;
Boolean в них отклоняется frontend. Локальные Boolean-агрегаты остаются логическими.

`PTS.ConstEval` вычисляет определённые scalar const expressions. Тот же evaluator
используется O1 только для integral/Boolean деревьев без float, calls и resource
effects. Типы деклараций проверяются после вычисления constant value, поэтому
положительная целая формула адаптируется к Cardinal как литерал. Undefined runtime
arithmetic не сворачивается; undefined const declaration отвергается.

`PTS.Features` задаёт typed image formats и invocation built-ins. GPU operations
имеют отдельные IR kinds: атомики не могут оказаться обычными arithmetic nodes,
opaque image/sampler values не становятся byte-buffer payload. Workgroup barriers
проверяются синтаксически по control depth Main. Подробный контракт — [gpu.md](gpu.md).

`Dot` использует `OpDot`. Остальная математика использует стандартный SPIR-V
набор GLSL.std.450; это импорт инструкций для драйвера, **не** сторонний компилятор
и не перевод в GLSL. Знаковый `Abs` реализован через `SNegate/SLessThan/Select`,
чтобы явно сохранить модульное поведение минимального `Integer`. Импорт
GLSL.std.450 ленивый, отдельная секция перед memory model. Его нет в модулях,
которым достаточно core-инструкций.

У `for` обе границы выдаются до входа в цикл и присваивания счётчику.
В loop header один Boolean `OpPhi` выбирает условие первой/следующей итерации.
Continue-блок проверяет достижение последнего значения до выбора следующего
счётчика. Поэтому выход не зависит от переполнения при инкременте максимума или
декременте минимума. Чтение счётчика после цикла запрещает frontend до нового
присваивания. Анализ инициализации учитывает и появление, и потерю инициализации
из-за вложенных `for` на всех ветвлениях и циклах.

## Файлы

| Путь | Назначение |
|---|---|
| `source/PasToSPIRV.dpr` | Аргументы CLI, файлы, диагностика, коды завершения |
| `source/PTS.Diagnostics.pas` | Координаты и ошибки исходника |
| `source/PTS.Source.pas` | Документы, origin maps, прочитанные файлы и dependency graph |
| `source/PTS.SourceLoader.pas` | File API frontend: include/modules, поиск, snapshots и budgets |
| `source/PTS.ConstEval.pas` | Constant evaluation и консервативный O1 |
| `source/PTS.Analysis.pas` | Definite assignment с учётом обратных рёбер циклов |
| `source/PTS.FloatLiteral.pas` | Точное округление decimal → binary32 |
| `source/PTS.Names.pas` | Зарезервированные идентификаторы и предел длины |
| `source/PTS.Features.pas` | Built-ins и storage image formats |
| `source/PTS.Project.pas` | Batch preflight, snapshot-based cache, artifact hashing |
| `source/PTS.Lexer.pas` | Токены, комментарии, литералы |
| `source/PTS.Types.pas` | Встроенные типы и descriptors записей/массивов |
| `source/PTS.Layout.pas` | std430 calculator и проверка внешних типов |
| `source/PTS.IR.pas` | Типы и владеющие узлы IR |
| `source/PTS.Parser.pas` | Разбор, проверка типов, инициализация, ресурсы |
| `source/PTS.SPIRV.pas` | Прямое формирование инструкций, ID и секций модуля |
| `source/PTS.Compiler.pas` | Библиотечная точка входа и координация |
| `source/PTS.Reflection.pas` | JSON v2 с графом внешних типов |
| `source/PTS.Bindings.pas` | Генерация packed Delphi ABI-описаний |
| `scripts/build.ps1` | Сборка dcc64 без внешнего compiler backend |
| `scripts/test.ps1` | CLI-регрессии, ошибки, opcodes, reflection, spirv-val |
| `tests/vectors.ps1` | Матрица векторных типов, операций, intrinsics и диагностик |
| `tests/layout.ps1` | Независимые std430-эталоны, типы, ABI/CLI-регрессии |
| `tests/BindingsCheck.dpr` | Компиляция/выполнение generated host layout |
| `tests/modules.ps1` | Поиск, циклы, видимость, позиции, fingerprints и релокация |
| `tests/SourceAPICheck.dpr` | Проверка string/file API и координат include |
| `tests/SharedSourceCheck.dpr` | Настоящий Delphi reference из общих `.inc` |
| `tests/release.ps1` | Constants/qualified names/GPU diagnostics/O1/cache |
| `tests/vulkan_images.py` | Image uploads/layout transitions/copies/sampling CPU references |
| `tests/benchmark.py` | Wall-clock CLI benchmark, не kernel throughput |
| `tests/vulkan_smoke.py` | Необязательная реальная Vulkan-проверка примеров |

`TShaderCompiler.Compile(Source)` не читает и не пишет файлы. Вызывающий код получает
`TCompilationResult.SPIRV: TBytes`, `Reflection: string` и опциональный `Bindings: string`,
либо `EShaderError` с координатами исходника. Это позволяет использовать компилятор в сторонних
инструментах без зависимости от CLI или какого-либо приложения-потребителя.

Для host unit используется `TShaderCompiler.Compile(Source, 'LayoutBindings')`;
без второго аргумента `Bindings` пуст. Compiler генерирует всё в память до
записи выходных файлов. При IO-ошибке запись набора файлов не транзакционная;
при ошибке исходника существующие артефакты не изменяются.

`CompileFile(FileName, IncludeDirectories, BindingsUnit)` читает source graph и
возвращает тот же результат в памяти, без записи outputs. String API остаётся
самостоятельным: `uses`/include в нём дают явную ошибку о необходимости file mode.
`TSourcePosition.FileName` дополняет Line/Column, ошибки из `.inc` не привязываются
ложно к entry file. Source loader не является filesystem sandbox; см. [modules.md](modules.md).

Модуль владеет descriptors типов, ресурсами и списком функций (включая `Main`). Каждая функция владеет
параметрами, локальными переменными, неявным `Result` в списке locals и телом.
Узлы выражений/операторов владеют дочерними узлами и аргументами вызова;
ссылки на переменные, callee и entry point — невладеющие. Backend не изменяет IR.
`TParser` и `TSPIRVWriter` создаются заново для каждой компиляции.

Backend раскладывает инструкции по секциям: capabilities, imports, memory model,
entry points/execution modes, debug names, annotations, types/constants/globals,
functions. Выход детерминирован, без времени сборки и абсолютных путей исходника.

## Reflection v2 и host bindings

Рядом с `.spv` сохраняется JSON с полями:

- `format_version = 2`, `layout = std430`, `compiler`, `compiler_version`;
- `target_env`, `spirv_version`, `stage`, `entry_point`;
- `local_size`: три компонента;
- `types`: граф внешних записей/массивов с id, size/alignment, fields/array stride;
- `buffers`: имя, descriptor type, set/binding, тип/id элемента, size/alignment, stride, access;
- `push_constants`: имя, type/id, offset, size/alignment, stage, поля с type/id/offset/size/alignment.
- В file mode дополнительно `sources` с raw SHA-256/логическими путями, `modules`
  в dependency order и `source_dependencies` с from/to/kind/исходными координатами.
  Это additive provenance, ABI остаётся v2; абсолютные build paths не сохраняются.

Точность этого описания важна не меньше SPIR-V: хосту нужны те же bindings,
размеры и смещения. Произвольный Delphi record не считается автоматически
совместимым с GPU layout. В этой версии типизированное объявление является
единым источником для backend и JSON; регрессии проверяют layout, а smoke-тест
использует JSON при создании descriptor bindings.

Опциональный `--bindings` выдаёт Delphi-unit с явными padding/array slots,
ресурсными aliases и `PTS_ValidateLayouts`. Полный контракт — [layout.md](layout.md).
Manifest нескольких entry points и specialization constants пока отсутствуют.
Потребители обязаны проверять версию схемы; формат v1 не описывает составной ABI.

В 0.4 все внешние типы используют calculator std430. Размер значения, базовое
выравнивание и stride различаются: vec3 имеет 12/16/16 байт соответственно.
Статические пределы и запрет Boolean проверяются до генерации ресурсов.

## Проверка корректности

1. Frontend отклоняет неподдерживаемое и типовые ошибки до записи файлов.
2. Каждая положительная регрессия проверяется `spirv-val --target-env vulkan1.0`.
3. Для критичных операций проверяются opcodes: `SRem`, логический `shr`,
   маскирование shift count, числовые conversions, `FunctionCall/Parameter`, `Phi`.
   Отдельная матрица покрывает все 9 векторных типов, числовые преобразования,
   конструкторы, компоненты и скалярные/векторные intrinsics.
4. Реальный Vulkan smoke сравнивает результаты с CPU-эталоном, включая
   переполнение, неполную группу и защиту границ через `if`, а также отдельно
   проверяет граничные случаи `div/mod`, сдвигов и преобразований. Дополнительно
   проверяются value-параметры, скалярные возвраты, вложенные вызовы, пустые и
   вложенные `for`, захват границ и завершение на крайних значениях счётчиков.
   Векторные тесты проверяют value-параметры/результаты, запись компонентов,
   broadcast, знаковый минимум `Abs`, NaN, знаковый ноль и сохранность хвостов.
5. ABI сравнивается с независимыми std430-таблицами, затем generated Delphi-unit
   компилируется и выполняется для проверки `SizeOf` и offsets. Отдельные Vulkan
   тесты используют заранее упакованные bytes с фиксированными смещениями,
   не строят эталон из отражения компилятора.
6. Source pipeline проверяется на циклах, diamonds, повторных include, неоднозначности,
   module visibility, UTF-8/оригинальных координатах, лимитах и релокации checkout.
   Реальные общие `.inc` компилируются Delphi CPU reference и PasToSPIRV; Vulkan
   результат сравнивается побитово для integers и с допуском для выбранных `Single`.

Валидный SPIR-V сам по себе не доказывает эквивалентность алгоритма CPU/GPU.
Текущие smoke-примеры также не являются полным доказательством числовой
совместимости. Для переноса алгоритмов эмуляции нужны дифференциальные тесты
с граничными и случайными входами на целевых GPU.

## Следующие этапы

Функции и `for` реализованы в 0.2, векторы/intrinsics — в 0.3,
std430/составные типы/bindings — в 0.4, source modules/include и проверенный
общий CPU/GPU-пример — в 0.5.
В 1.0 добавлены constants/qualified exports, 32-bit atomics, ограниченные shared
memory/barriers, typed storage images/explicit-LOD sampling, batch/cache и O1.
Это ограниченный стабильный профиль, не вся первоначально возможная GPU-функциональность.

Дальнейшие расширения определяются реальными use cases: cross-vendor CI,
дополнительные форматы/optional capabilities, private exports, более точный
uniformity analysis, diagnostics/debug tooling и измеренные оптимизации.

Оптимизация и расширение до vertex/fragment стадий идут после устойчивого
контракта и тестов. Развитие компилятора не зависит от конкретного приложения.
