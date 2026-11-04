# Аудит корректности 1.0 → 1.0.1

Дата: 2026-11-04. Это white-box аудит и воспроизводимые проверки в доступной
Delphi Win64 / AMD Vulkan среде, не независимая сертификация и не формальное доказательство.

Исходный полный набор **771 проверки проходил**. Тем не менее найдены и исправлены
пять классов ошибок. Все filesystem-пробы выполнялись на специально созданных
файлах под `build/audit`, не на пользовательских исходниках.

## Подтверждённые findings

### A1 — потеря исходника через filesystem aliases — высокая

**До исправления:** CLI и batch сравнивали нормализованные строки путей.
Output-hardlink на source и output через directory junction обходили guard:
компиляция завершалась с code 0, исходник заменялся бинарным SPIR-V. Два будущих
output через разные имена одной директории также могли оказаться одним файлом.

**Исправление:** `PTS.FileSafety` запрашивает Windows file identity существующих
файлов и canonical destinations через существующего родителя. CLI и project
preflight проверяют aliases inputs и всех outputs, включая JSON/bindings/cache.
Нет заявлений о защите от hostile concurrent rename/ACL races: это не sandbox,
а запись набора outputs по-прежнему не транзакционная.

**Регрессии:** `tests/AuditFilesCheck.ps1`: compile hardlink, source junction,
дублирующий будущий output через junction, batch hardlink и batch output alias.
После исправления — code 2, исходники сохранены, конфликтующие artifacts не созданы.

### A2 — неверная constant/O1 свёртка большого сдвига — высокая

Независимый arithmetic oracle и реальный Vulkan запуск нашли:

```pascal
1 shl 2147483647
```

По контракту count маскируется `and 31`, результат — `$80000000`. В исходной
Win64 сборке evaluator с UInt64 промежуточным сдвигом и последующим сужением
давал 0 при некоторых counts >=32. `-O0` и `-O1` расходились; ошибка затрагивала
и const declarations. Минимизация сохранена в `tests/fixtures/audit/fold_shift.pas`.

**Исправление:** явный отдельный masked count и 32-битная база сдвига в `PTS.ConstEval`.
Логический правый сдвиг использует такую же нормализацию. Не сделано обобщённого
вывода о причине в Delphi compiler без отдельного анализа его backend.

**Регрессии:** `tests/AuditShiftCheck.dpr` для 31/63/127/255/$7FFFFFFF/$FFFFFFFF;
`tests/audit_numeric_gpu.py` — независимо вычисленные деревья с wraparound,
signed div/mod, unsigned arithmetic и shifts. Каждый набор исполняется как
runtime `-O0`, runtime `-O1` и const declarations, предварительно проходит spirv-val.

### A3 — qualifier терял namespace boundary — средняя/высокая

Пустой `module M;` позволял принять несуществующие экспорты:

- `M.Value` разрешался в локальную переменную;
- `M.Data[0]` — в shader resource;
- `M.GlobalInvocationID.X` — в built-in;
- `M.True` — в Boolean literal;
- `M.record ... end` / `M.array[...]` — в анонимный тип.

**Исправление:** после consumed qualifier разрешён только настоящий export.
Fallback к locals/resources/built-ins/literals/anonymous types запрещён.
Нормальные qualified functions/types/constants и record variables, затеняющие
имя namespace в value context, остаются поддержаны.

**Регрессии:** `tests/fixtures/audit/qualified_*.pas`, `tests/audit.ps1`.
Все неверные обращения теперь source error code 1; artifacts сохраняются.

### A4 — зависимость от FP state вызывающего кода — средняя/высокая

`Compile` одинакового Single-источника при другом MXCSR rounding или FTZ/DAZ
давал разные SPIR-V constants. Вычисления также меняли sticky status flags
вызывающего приложения. В пробе все три проверки были False:
rounding-independent, denormal-independent, caller-state-restored.

**Исправление:** официальный Win64 compiler entry path использует scoped SSE
environment: nearest-even, masked exceptions, FTZ/DAZ off; полный предыдущий
MXCSR восстанавливается в finally, включая parse/evaluation errors.
Это не меняет runtime FP controls GPU и не обещает CPU/GPU float bit equivalence.
Другие host targets этим аудитом не подтверждены.

**Регрессии:** `tests/AuditNumericCheck.dpr` — boundary rounding, subnormal,
сохранение полного MXCSR и error path. Добавлена также проверка аргумента
`CompileResolved(nil)` вместо внутреннего access violation.

### A5 — скрытый shared-state доступ из value helper — средняя

Проверка pure helpers охватывала buffers/push constants, но не новый `vkShared`.
Root helper мог читать/менять shared array, хотя контракт требует передавать
значения и не допускает скрытый GPU resource capture.

**Исправление:** Main-only rule охватывает все GPU resource kinds.
Явная передача array value-copy из Main остаётся разрешена.

**Регрессии:** `hidden_shared.pas`, проверки read/write capture и положительный
пример явной копии shared-значения после barrier.

## Что проверялось

- Type/namespace resolution, lvalue paths, definite assignment и ресурсные access modes.
- Integer evaluator/O1 vs исполняемый SPIR-V, casts, div/mod и masked shifts.
- std430 и typed opaque resources, atomic memory semantics, conservative barriers.
- Source provenance, dependency resolution/cache preflight и output safety.
- Все прежние CLI/API/ABI/CPU regressions и штатные Vulkan scenarios.

## Воспроизведение текущего контрольного прогона

```powershell
.\scripts\test.ps1
python .\tests\vulkan_smoke.py --require-shared-cpu
python .\tests\audit_numeric_gpu.py --count 256
python .\tests\audit_numeric_gpu.py --count 512 --seed 0xC0FFEE
```

Один arithmetic seed генерирует `count` деревьев, по 3 результата на дерево.
Проверка целая, побитовая. Это дополнительный independent oracle, не замена
существующему Delphi-compiled common-source reference.

## Итог контрольного прогона

- **791** CLI/API/ABI/source/optimizer/cache проверки, включая новые audit-регрессии.
- **44** штатных Vulkan dispatches, включая настоящий Delphi CPU reference.
- **768** сгенерированных арифметических деревьев на двух seeds, каждое проверено
  в трёх режимах: **2304 результата**, ещё **6** Vulkan dispatches.
- Все перечисленные проверки после исправлений прошли; это не утверждение о
  полноте покрытия или отсутствии других ошибок.

Seed/count, сгенерированные `.pas`, `cases.json`, `expected.bin` и SPIR-V остаются
под `build/audit-numeric/seed-...-n-...` для повторения и минимизации.

## Остаточные риски / не подтверждено

- Не исчерпывающий fuzzing всех grammar/types/resources; finite random seeds
  не доказывают корректность для всех выражений.
- Нет проверки NVIDIA/Intel, других драйверов/host targets и hostile filesystem races.
- Не доказаны race freedom/halting/deadlock freedom shader-программ.
- Vulkan runtime bounds, optional format features и synchronization host остаются обязанностью приложения.
- Floating runtime behavior, denormals/NaN/rounding разных GPU не объявляются идентичными.

**Вывод:** найденные воспроизводимые ошибки исправлены в 1.0.1, но исходная зелёная
матрица оказалась недостаточной. Нужны постоянный differential fuzzing, cross-vendor
CI и отдельная независимая ревизия перед заявлениями о промышленной зрелости.
