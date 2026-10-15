# T-7 — осмысленный выбор свободной области после T-6

Политика переселения при любом pan и пересмотра безопасной позиции при любом изменении карты заменена в [T-9](T-9-stable-scroll.md). Поиск самого просторного места применяется при необходимости нового размещения.

## Проблема и критический путь до изменения

T-6 показал: Боччи переезжает при приближении курсора, но в остальных случаях остаётся в правом углу. Mocked AX snapshot и переданный вручную contentMoved доказывали только часть пути. Не подтверждены доставка настоящего pan-события и сохранение запрета при изменении native window metadata.

Нужно сначала получить диагностический trace из самой подписанной .app через LaunchServices: тип mouse/scroll события, визуальная настройка и реальные permission booleans, прежнее/новое размещение, количество activity areas, причина их сброса. Не читать клавиши, AX text/values/URL или пиксели ради диагностики; не менять разрешения или сохранённую visual preference. Отдельный trace mode сохраняет обычную visual preference, в отличие от прежней AX-only диагностики. Начальные setup/TCC не запрашиваются.

Гипотеза по коду: input добавляет старую точку, но refresh очищает activityAreas при любом изменении windows, включая перестановку/служебное окно. Нужен regression на реальном session→panel пути, где между pan и refresh меняется metadata внешнего окна. Для подтверждённого исправления — red на исходном коде и green, независимое ревью и релевантный gate. Поведение живого WebGL-приложения не объявлять готовым по одним fixtures.


## Принятый контракт

Дефект состоит в постоянном размещении в правом углу, а не только в обработке pan. Код PlacementEngine действительно выбирает первую свободную точку снизу справа, а previous earlyreturn сохраняет её. Исправление должно выбирать центр наиболее просторной свободной прямоугольной области; сохранять точку только при неизменной карте препятствий. Произвольное блуждание по таймеру не требуется.

Связанные слои: Engine + unit tests (bounded grid, histogram O(cells), existing valid-previous contract); Session (rerank по изменению bounds/obstacle map, сохранение relocation через metadata churn); visual admission (предпочитать просторный unknown canvas с локальной проверкой при opt-in вместо безусловного known AX кармана; после local rejects использовать известную AX альтернативу до full capture); App diagnostic flags/events; real runtime NSPanel fixtures; README/backlog/отчёт. Настройки, разрешения и зависимости не включать автоматически.

До реализации зафиксированы два runtime regression: просторный левый фон против маленького допустимого нижнего правого кармана после изменения карты; pan + изменение не влияющего на карту native window list. Red выполняется на замороженном baseline в artifacts/t7-baseline/ с отдельным scratch build, чтобы независимые изменения исполнителей не подменили базовый код. Visual boundary отдельно проверит unknown room против known кармана и ограничение полного захвата.

Переключение effective visualAllowed также считается сменой условий поиска: включение opt-in на уже показанном AX-кармане должно немедленно пересмотреть позицию. Runtime fixture сначала показывает known strip без capture, затем включает visual на том же snapshot и проверяет переход в локально проверенный просторный canvas.


## Реализация

Engine сохраняет готовую безопасную previous по прежнему контракту. При новом поиске существующая difference-mask ограниченной сетки преобразуется в histogram свободных origin-клеток; monotonic stack находит самый большой физический свободный прямоугольник с учётом pet footprint, затем выбирается его центральная grid-точка. Сложность O(grid cells + obstacles × log(axis size)); вложенного cells×obstacles нет. Сетка остаётся ограниченной примерно 1025 точками по оси; шаг обычно 4 pt, на больших дисплеях больше.

Session передаёт previous только при неизменных bounds, AX obstacle/unknown map и effective visualAllowed. Изменение карты или включение визуальной проверки пересматривает даже безопасную прежнюю точку. Неизменный интерфейс остаётся стабильным. Одно добавление/перестановка native window metadata при неизменной карте не заставляет заново центрировать pet.

В visual mode preferred выбирается по hard obstacles/activity/cursor. Если он AX-known, снимка нет; если unknown — работает существующая локальная проверка. После отклонения кандидата следующий known candidate тоже публикуется без снимка. После трёх local rejects поиск известной AX альтернативы предшествует полному кадру. Сохраняются 5s watcher, 10% change, generation/TTL, одна full map за поиск и минимум 10s между full maps. AX-only режим не объявляет unknown свободным.

Relocation input выставляет relocationPending, когда добавил прежнее placement. Ближайший relevant snapshot сохраняет ban через metadata window churn; смена usable bounds всегда очищает его. Флаг consume-ится только после relevant inspect; последующая обычная смена сцены очищает activityAreas по прежнему контракту.

App `--trace-placement` использует обычные сохранённые visual preference и реальные разрешения; `--diagnose-placement` остаётся принудительно AX-only. Trace пропускает стартовое setup, ограничивает content-movement лог двумя строками в секунду и пишет смены исхода/позиции, category reset и permission booleans. Клавиши, modifiers, текст, URL, AX values, названия/ID чужих окон, пиксели и аудио в trace отсутствуют. Разрешения и сохранённые preferences не меняются.

## Доказательства и проверка

- Замороженный baseline с отдельным scratch build: runtime roomiest regression — 26 PASS / 1 FAIL (artifacts/t7-roomiest-baseline-red.log), native window churn regression — 39 PASS / 1 FAIL (artifacts/t7-churn-baseline-red.log). Это настоящий session→engine→NSPanel с внешними OS snapshot fixtures; исходная реализация воспроизводит оба дефекта.
- Четыре целевые мутации Session с побайтным восстановлением: без map-based rerank — 26 PASS / 1 FAIL; возврат known-AX-first priority — 64 PASS / 1 FAIL; сохранение previous при visual mode toggle — 64 PASS / 1 FAIL; удаление no-capture для следующего известного кандидата — 66 PASS / 1 FAIL. Каждая падает на целевом поведении (artifacts/t7-mutation-{rerank,visual-priority,mode-toggle,known-capture}.log). Итоговый Session SHA256 8313ac86705b4fc564e138827d554532be1f997ca0b1978927bab39e25958e2d.
- Unit-проверки центра чистого экрана, просторного фона против небольшого углового кармана, узкого exact-fit corridor, stable previous, negative coordinates, bounds/padding на 100 deterministic randomized сценах и invalid/dense input. Runtime дополнительно проверяет новый выбор после изменения карты, ban через metadata churn, visual-off AX strip → visual-on roomy canvas на том же snapshot, safe AX fallback до full map и отсутствие лишнего capture у known next candidate.
- Финальный ./scripts/check.sh exit 0: **16 XCTest + 79 runtime + 8 signing + 5 LaunchServices = 108 проверок, 0 failures**, release/plist/codesign прошли (artifacts/t7-final-check.log). Gate выполнен после восстановления всех mutations.
- Release hot-path benchmark, 8K (7680×4320), по 5 прогонов: empty scene median 8.26ms/max 9.27ms; 20k obstacles median 7.05ms/max 10.04ms (artifacts/t7-engine-bench.log). Измерение текущего Mac, не внешний SLA. Постоянные сеточные массивы не выросли по порядку памяти.
- Native LaunchServices trace (artifacts/t7-live-trace.log): AX=true, **screen=false, visualOptIn=false**. Initial stale result discarded, затем shown AX-only вне прежнего угла. Настоящее NSEvent scrollWheel type22 получено монитором: contentMoved=1, cursorCollision=0, следующий scroll вызвал ещё одно размещение. Сайт/приложение источника не записывались, поэтому это доказательство реальной доставки scroll и relocation, а не отдельный smoke WebGL-приложения. Метаданные собственных окон подтверждают одну on-screen panel84×156layer25 (artifacts/t7-own-panel.log).
- Независимое ревью выявило лишний crop следующего AX-known candidate; исправление и чувствительный regression включены в итоговый gate. Полный итог ревью — artifacts/t7-review.md.

## Blocked / deferred и откат

Ручная оценка новой позиции остаётся открытой. Реальное распознавание пустого фона внутри WebGL-приложения и конкретных JS controls не подтверждено: native trace показал выключенные visual preference и Screen Recording. Для этого включается «Включить визуальную проверку» в настройке самой Bocchi Smart Pet и вручную выдаётся Screen Recording через macOS; доступ ChatGPT не требуется. В этой работе скриншоты рабочего стола не делались. Новая input-monitoring/keyboard permission не нужна и не запрашивалась.

Метаданные AX могут не описывать custom control; pixel analysis тоже не гарантирует любой canvas. Полная cross-app/Spaces матрица остаётся отложенной. Режим самопроизвольного блуждания не добавлялся: стабильная карта сохраняет удачное место.

Оставлен один подписанный process с --trace-placement, без принудительного visual-off и без стартовой модалки; stderr внутри artifacts/t7-live-trace.log. В Applications ничего не перемещалось, TCC/настройки/автозапуск не менялись. Откат — revert отдельного коммита T-7 и сборка с сохранённой .local-signing/.
