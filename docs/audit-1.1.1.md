# Аудит 1.1.0 → 1.1.1

Проверен compiler PasToSPIRV, без переноса или изменения consuming renderer.
Области: новые scalar types/casts, constant typing, var/out, CFG definite assignment,
specialization, portable SPIR-V limits, ABI и числовые границы. Compiler остаётся
Delphi-only и выдаёт бинарный SPIR-V напрямую.

## Подтверждённые находки и исправления

| ID | Уровень | Ошибка | Исправление |
|---|---|---|---|
| N-1 | высокий | Шесть допустимых casts выдавали невалидный OpUConvert: Byte/Word→Integer/Int64, Cardinal→Int64, UInt64→Integer | Сначала unsigned width conversion, затем signed bitcast. Валидация всех 64 пар scalar types в O0/O1 |
| N-2 | высокий | Явный cast unary/binary constant tree мог снова стать адаптируемым; typed unsigned minimum ошибочно разрешал unary minus | Отдельный ExplicitType marker, сохранение типа дерева и special minimum только для нетипизированных literals/constants |
| N-3 | средний | Вывод типа больших нетипизированных integer operands зависел от порядка, в том числе при одинаковой 64-битной ширине | Согласование ширины и корректная граница signed диапазона без изменения 32-битных правил |
| R-1 | средний | Var проверялся при захвате адреса, до вычисления последующих value arguments, которые могли его инициализировать | Проверка целого var перед входом в callee, после evaluation всех аргументов; out того же вызова не считается предварительной инициализацией |
| R-2 | средний | Reference specialization сворачивала floating expression в индекс при O0/O1 | Floating runtime indices остаются expressions и передаются в специализацию как значения; проверяется сохранение OpFDiv |
| B-1 | средний | Большие case/function signatures выдавали невалидный SPIR-V; OpSwitch мог переполнить word count | Portable limits: 16383 case pairs, 255 function parameters, включая expanded dynamic indices. Общий Emit guard на 65535 words; case lookup/накопление сделаны линейными вместо квадратичных |
| T-1 | тестовый эталон | CPU reference неверно выдавал sentinel у Floor/Ceil на верхней границе Integer | Округление через bounded Int64 с последующей проверкой Integer range; добавлены boundary samples и независимый Fraction-эталон |

Для B-1 отвергаются oversize source/calls, а не изменяется семантика. Ошибки
возвращаются с source position до записи артефактов; существующие outputs сохраняются.
Граничные допустимые case/signatures также проверяются, чтобы не подменять
исправление запретом всех больших конструкций.

## Независимые проверки

- `tests/audit11.ps1`: 8×8 cast matrix, small/wide intrinsics, typed-cast/unsigned
  negation regressions, var/out evaluation order, floating reference index,
  case/parameter budgets. Каждая успешная compilation проходит spirv-val.
- `tests/audit_flow.py`: независимый explicit-state interpreter, не переписанный
  CFG solver. Перебирает initialization states и break/continue/return paths,
  включая loop back-edges, out calls и late initialization. Принятые программы
  дополнительно валидируются как SPIR-V, отвергнутые должны иметь source error.
- `tests/audit_extended_gpu.py`: independent integer/Fraction oracle для casts,
  8/16/32/64-bit modular operations, div/mod, masked shifts, reference aliases,
  argument order и loop endpoints. Не требует Python packages.
- `tests/vulkan_extended.py`: дополнительно сохраняет сравнение с настоящим
  Delphi Win64; его CPU reference исправлен отдельно от compiler.

## Результаты на проверенной машине

Delphi 13 Win64, Vulkan SDK tools, AMD Radeon RX 9070 XT:

- Полный suite: **1139 checks**, включая Vulkan 1.0/1.2 validation.
- Binary64: **250** midpoint/tie/sticky/overflow cases независимого Fraction oracle.
- Flow: **500** cases (seed 811033) и **2000** (seed 811035), каждый в O0/O1.
- Extended GPU audit: **286720** результатов, **10 dispatches**, O0/O1,
  count=1024, seed=811037; включён Khronos validation layer.
- Прежний Vulkan smoke (50 основных/reference dispatches, плюс thumbnail checks),
  extended Delphi-reference probes (8 dispatches) и numeric audit
  (256 trees × 3 modes, 3 dispatches) также прошли.

Это не независимый аудит другим разработчиком/агентом, не proof всех программ и
не qualification всех GPU/драйверов. Несколько фиксированных seeds не заменяют
проверку конкретного алгоритма.

## Double division: подтверждённый предел, не замаскированный PASS

Отдельная диагностика сравнивает native Double OpFDiv с точно округлённой дробью.
На указанной AMD-карте: **1089/4096** bit differences, максимум **1 ULP**, одинаково
при O0/O1 (seed 811037). Эти различия **не** засчитываются как bit-exact passes:
Vulkan native division имеет более слабый accuracy contract. StrictFloat controls
и NoContraction не превращают его в software correctly-rounded division.

Для алгоритма с обязательной побитовой CPU-эквивалентностью деление надо реализовать
и проверить отдельно в software arithmetic. Такая библиотека и перенос рендера
в этом аудите не выполнялись.

## Воспроизведение

```powershell
.\scripts\build.ps1
.\scripts\test.ps1 -SkipBuild
python .\tests\audit_flow.py --count 2000 --seed 811035
python .\tests\audit_extended_gpu.py --count 1024 --seed 811037
python .\tests\vulkan_smoke.py --require-shared-cpu
python .\tests\vulkan_extended.py
python .\tests\audit_numeric_gpu.py --count 256
```

Для layer validation задайте VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation перед
GPU-командой. Не пересобирайте compiler EXE параллельно с его запусками: Windows
блокирует работающий файл. Generated sources/artifacts разделены по seed/count
под `build/`; несовпадение сохраняет воспроизводимый исходник там же.
