# T-23 — посадка при записи экрана и перемещение без телепортации

Посадка на край окна срабатывает не всегда, а во время записи экрана после
Cmd+Shift+5 — никогда. Отдельно иногда виден мгновенный
переезд, особенно по вертикали. Панель запуска записи уже скрыта.
Исходная точка: T-21/T-22 установлены и отправлены в origin/main.

## Скоуп файлов

Диагностика `SystemInspector.swift`, `ScreenAnalyzer.swift`,
`PlacementSession.swift`, `Overlay.swift`, `SupportGeometry.swift` и существующих
native checks. Реализацию ограничить доказанной причиной; PNG не меняются.

## Приёмка

- Выбор действительно подходящей видимой опоры работает и во время записи
  экрана. Системные индикаторы не должны превращать всю сцену в препятствие;
  реальные перекрытия, текст, controls и физически недоступные края остаются
  запрещёнными. Не игнорировать окна по одному имени процесса.
- Для отказа посадки по живым metadata/logs понятна конкретная причина.
  Проверить ручной drag, обычный поиск и изменение окон, чтобы не спутать
  намеренное сохранение ручного положения с ошибкой опоры.
- Автономное перемещение видимой Боччи между допустимыми позициями проходит
  через промежуточные координаты X и Y. Прямое следование за пользовательским
  drag/двигающейся опорой и необходимое скрытие при опасном месте — отдельные
  сценарии; не ломать их ради общего запрета мгновенных обновлений.

## Проверки

Сначала зафиксировать реальный entry → затронутые слои → видимый итог каждого
подтверждённого дефекта. Для исправления — RED на прежнем коде и GREEN через
настоящие PlacementSession/PetOverlay/NSPanel. Внешние fake только для metadata,
capture, clock и pointer; не подменять решения геометрии/сессии/движения.
Проверить записи on/off доступными metadata/logs без нового host screenshot,
без самостоятельного запуска записи и без изменения TCC. Отдельно не считать
текущий снимок metadata доказательством активной записи без подтверждения.

Полный `scripts/check.sh`, независимое ревью, прежняя подпись и native smoke.
Артефакты: `artifacts/20261017_164400_placement_recording/`.

### Подтверждённый runtime-путь Screen Recording

Во время записи реальные CGWindow metadata содержали fullscreen-окно системного
процесса `Screenshot` с `alpha=1` и recording layer. Процесс разрешился в bundle
`com.apple.screencaptureui` по каноническому пути
`/System/Library/CoreServices/screencaptureui.app`. В native trace это
окно закрыло реальные hosts: `supports=0`, `matchedHosts=0`, причина
`realHostsOccluded`.

Исправление допускает исключение из foreground occlusion только при совпадении
всей системной identity: bundle, канонический системный путь, `alpha=1`, fullscreen
bounds, ожидаемый recording layer и shape. Произвольное окно
по имени процесса, toolbar, чужое translucent/opaque окно, неверные identity,
layer или shape не игнорируются. Runtime-проверка проводит metadata через decode →
visibility → perch support → `PlacementSession` → `NSPanel`; внешние fake-границы —
источник CGWindow metadata, process-identity resolver, AX `SystemSnapshot` и capture,
если сценарий его использует. Codex не запускал запись, не менял TCC и не делал
host screenshot.

Промежуточная приёмка recording path: native-проверка при включённой записи дала
10/10 посадок и ещё три последовательных follow на window `94019`; доказательства
сохранены в `native-recording-verification.md`. Полный gate перед cross-display
исправлением: `full-check-release.log`, 383 passed / 0 failed. Независимое ревью
этой части — PASS.

### Зафиксированный runtime-путь follow shortcut

Реальный вход исправления: повторный `PlacementSession.refresh` для уже сидящей
Боччи, где опубликован тот же внутренний `SupportID`, но его bounds изменились.
Затронутые production-слои: `SupportGeometry.choose` сохраняет attachment identity →
`PlacementSession` сравнивает новый support и owner window с последним принятым
attachment baseline → `PetOverlay`
либо синхронно выполняет `followPerch`, либо запускает существующий `perch(at:)` →
настоящий `NSPanel` проходит промежуточные координаты и `SpriteView` снова садится.

Внешние fake-границы runtime-проверки — только AX snapshot, локальный capture и
clock; `SupportGeometry`, session, overlay, AppKit panel/timer и sprite остаются
production. RED старого поведения: тот же internal support сдвигается только по Y
внутри неизменного owner window и сразу оказывается в destination без movement.
GREEN: такой сдвиг запускает approach с реальной промежуточной frame; неизменный
placement и одинаковый перенос support вместе с owner window остаются мгновенным
seated follow. Stale inspect/capture не может заменить accepted baseline: после
accepted A → stale B повторный B всё ещё распознаётся как owner follow. Safety hide
и запрет `move` из hidden panel не меняются.

### Зафиксированный runtime-путь cross-display teleport

Реальный вход — `AppDelegate.tick`: cursor перемещается на другой живой дисплей,
`currentContext` возвращает новый `DisplayContext`, после чего production policy
решает, можно ли оставить старую панель видимой до проверки нового места. Внешние
fake runtime-проверки — только old/new display contexts, живой display inventory,
AX snapshot, capture и clock. Дальше работают настоящие `PlacementSession`,
`PlacementEngine`, `PetOverlay`, Timer и `NSPanel`.

До исправления App вызывал hard invalidate при `sameDisplay=false`, а session ещё
раз делал `orderOut` при `screenChanged`. Поэтому проверенный target доходил до
`PetOverlay.move` со скрытой панелью: guard отказывал и fallback `publish` мгновенно
переставлял frame. Live trace показывает большой переход через
`action=publish visible=0`.

Новый контракт разделяет очистку display-specific state и видимость. Cross-display
сбрасывает verification/manual/escape/attachment/reject state, но сохраняет старую
панель только когда она видима и внешний `NSScreen` inventory всё ещё содержит
старые точные display id и bounds. Новый target сначала проходит обычную AX/pixel
проверку, затем `move` показывает реальные промежуточные X и Y. Исчезнувший или
изменившийся display, permission/visual-mode change, metadata error, unsafe target и
`noSpace` сохраняют hard hide. Выбор дисплея под cursor и hidden-move guard не
меняются.

Чувствительность: прежний `keepingVisible=false` обязан дать RED до refresh/move;
восстановленный `screenChanged orderOut` обязан дать отдельный RED после начала
refresh. GREEN проходит production display-retarget policy → session → настоящий
panel и заканчивает movement в проверенном target.

Фактические результаты: первый RED — 16 passed / 1 failed на сохранении старой
панели; второй RED — 17 passed / 1 failed на начале движения после
`screenChanged`; итоговый self-test — 343 passed / 0 failed. Логи:
`cross-display-red.log`, `cross-display-screenchanged-red.log` и
`cross-display-green.log`.

### Runtime-путь live follow при пользовательском drag окна

Реальный вход — уже установленный global monitor получает
`leftMouseDragged`, пока Боччи сидит на attachment. Production-цепь:
`AppDelegate.input` → ограниченный 30 Hz single-window CG metadata read →
`PlacementSession` проверяет чистый перенос owner/support/placement, текущий
display/usable bounds и foreground окна из последнего полного context →
существующий `PetOverlay.followPerch` двигает настоящий `NSPanel`.

Во время drag запрещены AX traversal и capture. Перенос считается временным
пользовательским движением, а не новой pixel verification: старый baseline
очищается и не получает свежий timestamp. Каждый drag сохраняет существующий
quiet guard; после release обычный refresh обязан заново проверить AX/support и
локальные пиксели. Unchanged owner остаётся обычным content drag. Missing или
повторно использованный window ID, wrong PID, resize, выход за display/usable,
смена дисплея и foreground occlusion отсоединяют Боччи в standing на текущей
позиции с повторной полной проверкой после release; после неё работает обычный
approach.

Targeted CG metadata read ограничен 60 Hz: hardware drag sample через 5 ms
остаётся throttled до внешнего reader, а sample через 20 ms уже переносит
настоящий panel. Замер существующего reader (`p95=0.108 ms`) оставляет большой
запас внутри 16.7 ms; изменение не добавляет Timer, AX traversal или capture.
Чувствительность: прежний 30 Hz guard обязан дать RED на 20 ms follow, сохраняя
GREEN на 5 ms throttle.

Ручная live-проверка подтвердила устойчивую посадку не менее 10 секунд.
Live-follow до отпускания окна также подтверждён, но отмечено небольшое
запаздывание; 60 Hz delta адресует этот
наблюдаемый остаток без изменения post-release verification.

Внешние fake runtime-проверки — single-window metadata reader, clock и
post-release capture. Session, геометрия, overlay и `NSPanel` настоящие. RED
отключает targeted follow: промежуточный panel frame до release отсутствует.
GREEN требует промежуточные native frames, ноль capture во время drag, throttle
до reader, fresh capture после release и отказ принятия transient позиции при
проваленной финальной проверке.

Чувствительность подтверждена точечным отключением production-вызова
`followPerch`: 244 passed / 1 failed на проверке промежуточного положения
настоящего `NSPanel`. Восстановленный код проходит 353 passed / 0 failed; targeted
metadata отвергает offscreen, wrong-ID и wrong-PID окно, а session отдельно
проверяет missing owner, resize, foreground occlusion и выход за экран.

### Зафиксированный runtime-путь same-monitor forced relocation

Реальный вход — `contentMoved` либо новый AX snapshot делает текущее видимое
положение недопустимым: известное AX-препятствие пересекает placement или локальный
pixel capture перестаёт подтверждать прежнее место. Production-цепь остаётся
`PlacementSession.refresh` → `PlacementEngine` → `PetOverlay.move` → Timer →
`SpriteView` и настоящий `NSPanel`. Внешние fake-границы runtime-проверки — только
AX snapshot, capture, clock, pointer и `current`; геометрия, session, movement и
panel не подменяются.

До исправления обе ветки заранее вызывали `orderOut`: первая при AX collision,
вторая после неуспешной pixel verification. Безопасный новый endpoint затем
доходил до `show`, но hidden-move guard отклонял движение и fallback `publish`
мгновенно менял frame. Live trace показал вертикальный переход через
`action=publish visible=0`; сценарий воспроизводился повторно.

Новый контракт оставляет неподвижный unsafe origin видимым только на ограниченное
время поиска и после принятия безопасного endpoint запускает существующий `move`
с промежуточными X/Y. Одноразовый deadline реально срабатывает через 2.5 секунды,
даже если внешний capture suspended. Он скрывает панель и освобождает session лишь
если это всё ещё тот же refresh token и тот же неподвижный origin, а новый
drag/movement или publication не приняли ownership. Обычный `contentMoved` делает
подвисший capture stale, но не продлевает показ уже доказанного unsafe origin;
ручной drag/drop и hard retarget отзывают token. Поздний результат старого capture
не может очистить ownership нового refresh или скрыть новое состояние. Accepted
move отменяет deadline. Stale inspect/capture при неизменном unsafe origin, capture
error и итоговый `noSpace` сохраняют hard hide. Endpoint по-прежнему проходит
обычные AX/pixel проверки;
маршрут через временное перекрытие не объявляется безопасным и pathfinding не
добавляется.

AX collision фиксируется сразу после принятия snapshot и обновления session
bookkeeping, до поиска perch. Поэтому альтернативная внутренняя опора, требующая
pixel capture, не может обойти deadline подвисшим capture. Чувствительная проверка
начинается с видимой free pose, добавляет пересекающее её AX-препятствие и
pixel-requiring perch, подвешивает именно perch capture и требует hide/release через
2.5 секунды; поздний sample не меняет опубликованное после deadline состояние.

Чувствительность фиксируют две независимые мутации: возврат раннего `orderOut` в
AX-collision ветку обязан сломать AX forced-relocation, а возврат `orderOut` после
pixel verification — pixel forced-relocation. GREEN требует для обоих случаев
видимую панель, реальные промежуточные X и Y и проверенный endpoint; отдельно
проверяются `noSpace`, error, stale, suspended capture deadline и live-follow.

Фактические результаты: AX `orderOut` mutation — 20 passed / 1 failed на старте
видимого relocation; pixel `orderOut` mutation — 23 passed / 1 failed на том же
контракте после pixel activity; event-route mutation
`leftMouseDragged` → `rightMouseDragged` — 258 passed / 1 failed. Восстановленный
старый порядок AX deadline дал 27 passed / 1 failed на suspended alternative perch;
mutation held-left guard в `true` — 265 passed / 1 failed. Восстановленный единый
source state прошёл 377 passed / 0 failed, включая suspended capture, stale
`contentMoved`, manual ownership cancellation, held-left quiet interval и
существующий live-follow. Release compile завершился с exit 0.
Логи, mutation sources/diffs и SHA-256: `teleport-red-*.log`,
`teleport-green-final-p2.log`, `teleport-mutation-*.{swift,diff}` и
`teleport-source-hashes-final.txt`.

### Runtime-контракт transient AX loss принятой оконной опоры

Реальный вход — очередной `PlacementSession.refresh` для уже принятой native
window-edge attachment не находит её в `SystemSnapshot.supports`, хотя текущий
CG snapshot всё ещё содержит то же непрозрачное окно. Recovery разрешён только
для attachment без `elementToken`: текущие `WindowRegion` обязаны заново
подтвердить точные window ID и PID, прежние width/height, видимую верхнюю грань
через `SystemInspector.visibility` и `SystemInspector.perchSupport`, а placement
должен быть ровно прежним placement, перенесённым на delta текущих и принятых
owner bounds. Новые unknown CG окна не становятся кандидатами, internal support
без AX identity не восстанавливается, persistent cache не добавляется.

Даже при совпавшей metadata recovery всегда требует `visualAllowed` и свежий
локальный `capturePerch` в рамках существующих refresh token и 2.5-second
deadline. Текущие AX obstacles, activity/rejected placements, foreground
occlusion, pixel obstacles, изменение fingerprint и отсутствие непрерывного
support edge отклоняют recovery. Window gone, wrong ID/PID, resize, translucent
window и visual opt-out остаются обычным detach/hide/search путём; stale crop
discarded по существующему token-контракту и не публикует новое состояние.
После принятия обновляются те же attachment и verification, что и при обычной
опоре; отдельного таймера и общего CG-only источника опор нет.

Runtime-проверка использует настоящий `PlacementSession`, `SupportGeometry`,
`PetOverlay`, Timer, `SpriteView` и `NSPanel`; fake только AX/CG snapshot,
capture, clock и `current`. RED на прежнем коде: после принятой оконной опоры
snapshot с тем же exact window, но без `supports`, отсоединяет panel и не делает
edge crop. GREEN требует один свежий crop и сохранённую посадку; отрицательные
сценарии покрывают missing/wrong identity, resize/opacity/occlusion, visual-off,
AX и pixel obstacle, activity, missing edge, stale и internal attachment.
Чувствительность отдельно отключает обязательный fresh crop и edge gate.

Фактический RED прежней логики — 224 passed / 1 failed: exact CG owner без AX
support отсоединял уже сидящую Боччи и не выполнял свежий edge crop. Мутация,
разрешающая reuse прежнего crop, дала 224 / 1; мутация, снимающая edge gate,
дала 241 / 1. Старый 30 Hz live-follow guard дал отдельный RED 294 / 1 на
20 ms owner sample, при этом 5 ms sample остался throttled. Финальный общий
self-test на восстановленном permanent Inspector — 407 passed / 0 failed;
release compile завершился с exit 0. Это отдельный self-test-процесс, а не
native proof установленного приложения; финальный signed gate и relaunch у root.

## Приёмка на установленном приложении и ограничения

Ручная проверка подтвердила устойчивую посадку не менее 10 секунд и следование
за окном до отпускания мыши. Отдельный дефект рамки приложения не подтвердился,
специального правила для него нет. Небольшие рывки
сопровождения адресованы повышением ограничения с 30 до 60 Hz: 5 ms событие
отсекается до metadata I/O, 20 ms событие двигает настоящий NSPanel. Визуальная
плавность именно после повышения частоты ещё не подтверждена.

В native trace установленной промежуточной сборки зафиксированы обычные и
cross-display `action=move visible=1`
с последующими `movementEnded`. Это дополняет проверки промежуточных X/Y
настоящего NSPanel; журнал сам по себе не заменяет визуальную приёмку.

Safety hide остаётся намеренным: если свежий sample уже обнаружил obstacle,
а поиск нового места затем стал stale, завершился ошибкой или `noSpace`,
Боччи скрывается. После следующей успешной проверки допустимо повторное появление.
Именно такой путь виден в `native-integrated.log`: свежий obstacle,
`discarded`, затем `publish visible=0`. Это не прямой перенос видимой панели;
сохранять уже опасную позу через новые циклы поиска не стали.

Независимое ревью итоговых source SHA — PASS, без открытых замечаний;
`artifacts/20261017_164400_placement_recording/independent-review.md`.

## Итоговая проверка и сборка

Полный `scripts/check.sh` завершился с exit 0: 34 XCTest + 407 native runtime +
8 signing + 6 LaunchServices = **455 проверок, 0 ошибок**, обязательных skip нет.
Финальный лог — `full-check-final.log`; сводка — `final-verification.md`
в каталоге артефактов этой задачи. Проверенные исходники совпадают с SHA
независимого ревью; временная Inspector trace удалена.

Подписанная `.app` обновлена и запущена через LaunchServices.
Прежний bundle ID и designated requirement сохранены.
`native-final.log` подтверждает `AX=true screen=true visualOptIn=true`,
`shown(visual: true)` и повторные успешные проверки. Read-only CG metadata
подтверждают видимую panel ожидаемого размера.
Новых разрешений и переустановки не потребовалось.

Откат — отдельный revert коммита T-23 и пересборка с прежним локальным signer;
`.local-signing` и TCC не изменять.

## Blocked / deferred

Плавность после перехода на 60 Hz ещё не оценена.
T-18 AX-only остаётся отдельно. Новые анимации, полный планировщик маршрутов и
изменения разрешений не входят в эту правку.
