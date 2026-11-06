# Пакетная сборка и кеш — project format 1

```json
{
  "format_version": 1,
  "include_directories": ["modules"],
  "optimize": true,
  "entries": [
    {"source": "first.pas", "output": "build/first.spv", "bindings": "build/FirstBindings.pas"},
    {"source": "second.pasm", "output": "build/second.spv", "optimize": false, "entry_point": "main"}
  ]
}
```

```powershell
pastospirv build project.json
pastospirv build project.json --force
```

- Все пути относительно project JSON, не рабочего каталога. Explicit absolute
  paths допустимы; это локальный инструмент, не sandbox.
- 1..256 entries, source/output обязательны. Reflection по умолчанию — `.json`
  рядом с output, bindings опционален, optimize у entry перекрывает общий.
- Необязательный `entry_point` у entry — внешнее имя точки входа SPIR-V (по умолчанию
  `Main`, регистр сохраняется). Процедура исходника всё равно `Main`. Имя —
  ASCII-идентификатор длиной 1..127; пустое значение и другие типы JSON запрещены.
  Проверка всех имён выполняется до записи outputs. В CLI одиночной компиляции
  аналогичная настройка — `--entry-point main`.
- JSON должен иметь правильные типы; неизвестные и **повторяющиеся** свойства —
  ошибка, не игнорируются. Имя bindings unit проверяется по тем же правилам, что
  при генерации, ещё до записи любых артефактов.
- Ошибки конфигурации проекта (JSON, пути, общий бюджет 32 Mi символов, пересечения
  путей) — code 2; ошибки исходников entry, включая их бюджеты, — code 1.
- Сначала загружаются все source graphs и проверяются пересечения путей. Нельзя
  переписать project, любой entry/include/module input или другой output/cache.
  На Windows проверяются также file IDs существующих файлов и canonical destinations
  через junction/symlink directories, а не только строки имён. Ещё не существующие
  outputs сравниваются по ID ближайшего существующего каталога плюс хвосту пути
  без учёта регистра Unicode, поэтому `Ä`/`ä` и loopback UNC-путь к тому же каталогу
  считаются одним назначением. Пути с alternate data streams (`file:stream`)
  отвергаются (так же и в CLI). Это не защита от
  враждебной одновременной подмены filesystem; инструмент не является sandbox.
- На source preflight ошибке outputs не меняются. Вся batch не транзакционная:
  если поздняя семантическая/IO-ошибка возникла после успешной ранней entry,
  её артефакты уже могут быть записаны. Cache записывается после outputs.

## Корректность cache hit

Рядом с output находится `<output>.cache.json`. Key зависит от compiler version,
хеша CLI executable, target, optimization, bindings unit name, внешнего имени точки
входа (с учётом регистра), поиска зависимостей,
сырого содержимого/графа всех прочитанных источников. Абсолютные пути в manifest
не записываются: конфигурация пути может влиять на хеш key, не раскрываться строкой.

Даже при cache hit source graph **разрешается заново**. Новый shadowing module,
пропавший include или неоднозначность не маскируются старым кешем. Для компиляции
используется тот же `TSourceProgram` snapshot, из которого рассчитан key.

Проверяются SHA-256 всех outputs, включая JSON/bindings. Пропавшие/изменённые
артефакты, повреждённый cache, другая сборка compiler дают miss. `--force` всегда
пересобирает. Cache локальный и доверенный, не подписанный remote cache. Перенос
дерева/другие include roots могут дать безопасный miss.

Library `BuildProject` требует непустой compiler identity для cache hits;
при пустом identity компиляция выполняется всегда. CLI использует свой SHA-256.
Программа проекта ограничена 1 MiB JSON и 32 Mi UTF-16 символами развёрнутых sources;
каждая entry также подчиняется лимитам file frontend.

## Оптимизация

`compile ... -O0` — default. `-O1` (project `optimize: true`) — только определённые
скалярные целочисленные/Boolean константные выражения. Не сворачиваются floating
point, вызовы, resource reads, атомики и неопределённая арифметика. Нет fast-math,
перестановки float reductions, удаления побочных эффектов или обещания ускорения GPU.
Const-декларации вычисляются независимо от O0/O1, это часть языка.

```powershell
python .\tests\benchmark.py --iterations 10
```

Отчёт `build/benchmark/results.json` измеряет wall-clock CLI startup + compilation
+ файловый I/O при прогретом filesystem cache и размеры SPIR-V. Это не время kernel
и не сравнение с GLSL/DXC. Оптимизация должна подтверждаться измерениями, не названием O1.
