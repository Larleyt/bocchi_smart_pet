# T-6 — переезд после pan и защита JavaScript controls

## Запрос и критический путь до изменения

При pan рабочей поверхности WebGL-приложения Боччи скрывается и не переезжает; правый нижний угол перекрывает активные JS-кнопки. T-5 доказал видимость panel, но не проверял реальный control footprint и relocation. Текущий процесс запущен в диагностике с visual fallback выключенным.

Два конкретных дефекта: input только инвалидирует overlay, а следующий choose предпочитает сохранённый lastPlacement; AXGroup/AXRow с click action обходится как контейнер и защищает лишь текстового ребёнка вместо всей кнопки. Необходимо отличать content movement (scroll/drag, включая middle mouse) от простого click; покинутая точка запрещается через существующие activityAreas. Press-like AX actions должны защищать весь control frame независимо от role.

Путь проверки: внешний AX fixture actionable group + small child label → настоящий inspectTree → SystemSnapshot → PlacementSession → NSPanel вне всего control. Missing/zero frame или error action boundary остаются fail-closed. Pan: initial placement → mouse-down hide → contentMoved drag → неизменный snapshot → другое placement; обычный click сохраняет позицию, cursor collision уводит и после ухода курсора. Целевое отключение action obstacle/relocation должно дать red, после восстановления — green.

Для WebGL/canvas AX геометрия не описывает пустые пиксели внутри рисунка. Неинтерактивное изображение/canvas должно оставаться unknown для opt-in local visual verification, а не становиться гарантированно пустым или сплошным hard obstacle. Тест visual boundary использует явно названный внешний image fixture; настоящий screen/audio capture не включается. Для live проверки внутри canvas потребуется разрешение самой Bocchi Smart Pet, не ChatGPT.


## Итог реализации

`App` различает обычный click, движение курсора и content movement: scroll/left/right/middle drag. `PlacementSession.input` добавляет прежнее placement в существующий список activityAreas (dedupe, максимум восемь) до invalidation. Для pan используется lastPlacement и при уже скрытой panel: mouse-down больше не уничтожает возможность переезда. Cursor collision также исключает старую позицию; простой click её не запрещает. При смене сцены список очищается по прежнему контракту.

`SystemInspector` читает AXUIElementCopyActionNames для структурных/неизвестных ролей. Press/Pick/Confirm/Cancel/Increment/Decrement защищают весь ненулевой frame независимо от role. Ошибка API или невалидная рамка actionable element делают обход incomplete. Названия действий — метаданные; сами действия не выполняются, values/text/URL не читаются. Обычный AXImage стал unknown вместо hard obstacle: это позволяет использовать существующий visual fallback для пустого фона canvas, сохраняя запрет на неизвестную область без opt-in.

Независимое ревью выявило ошибку первого варианта: AXShowMenu на фоне означал бы препятствие размером с весь canvas. ShowMenu исключён из общего классификатора; menu/button/pop-up роли по-прежнему защищены своим role. Фон с одним контекстным меню остаётся unknown для локальной проверки.

Контракт AX API проверен по SDK AXUIElement.h (success возвращает массив, пустой массив означает отсутствие действий) и [документации Apple](https://developer.apple.com/documentation/applicationservices/1462053-axuielementcopyactionnames). Ошибка API не подменяется пустым массивом. Зависимости, бюджеты AX и правила screen/audio capture не менялись.

## Проверка

- Реальный executable и NSPanel: внешний AX fixture → тот же inspectTree → SystemSnapshot → PlacementSession → настоящее окно вне всей рамки кликабельной группы, включая свободное пространство вокруг маленькой label. Внешние границы AX/pixels/time заменены явно; выбор места и публикация остаются production.
- Pan после mouse-down при неизменной AX-карте переезжает; простой click сохраняет safe point; ушедший от Боччи курсор не возвращает её в ту же точку. Маршрут NSEvent включает otherMouseDragged. Отдельно проверены missing/zero frame и action API error.
- Синтетический canvas unknown без opt-in скрывает panel без захвата; после opt-in fixture локальная проверка показывает panel и после pan выбирает другой локально проверенный участок вне JS control. Полный экран для этого сценария не запрашивается. Настоящий screen/audio capture тестом не выполнялся.
- Целевые red: отключение contentMoved в добавлении activity area — 38 PASS / 1 FAIL на pan после mouse-down; удаление AXPress из actions — 40 PASS / 1 FAIL на whole-frame control; возврат AXShowMenu — 46 PASS / 1 FAIL на context-menu canvas. Источники каждый раз восстановлены побайтно. Логи: artifacts/t6-mutation-pan.log, t6-mutation-actions.log, t6-mutation-context-menu.log.
- Финальный ./scripts/check.sh exit 0: **14 XCTest + 73 runtime + 8 signing + 5 LaunchServices = 100 проверок, 0 failures**, release/plist/codesign прошли (artifacts/t6-final-check.log). После последней мутации runtime повторён на восстановленном source: 73 PASS / 0 FAIL (artifacts/t6-final-runtime-green.log).
- Реальная подписанная .app через LaunchServices: AX=true, сначала discarded stale result, затем shown(visual: false), 60 obstacles / 21 unknown; собственная panel ровно одна, 84×156, layer25 (artifacts/t6-final-live.log, t6-final-own-panel.log). Это доказательство native показа, а не обхода конкретных кнопок WebGL-приложения. Прямой запуск бинарника subprocess ранее дал AX=false (artifacts/t6-live-ax.log); поддержанный запуск .app через macOS дал AX=true без повторной выдачи доступа, различие отдельно не исследовалось.
- Независимое ревью итогового source, трёх red и полного gate: Ship, текущих findings нет. Полный отчёт artifacts/t6-review.md. Диагностический процесс завершён; обычный режим запущен из dist без diagnostic flag и принудительного visual-off.

## Blocked / deferred и откат

Ручная проверка живого WebGL-приложения, его реального AX-дерева/JS controls и pan остаётся открытой. Настоящий visual mode и разрешение Screen Recording в этой работе не проверялись. Для поиска фона внутри WebGL visual fallback включается в настройке самой Bocchi Smart Pet; ChatGPT screen/audio permission не требуется. Элементы, которые браузер вообще не публикует через AX, могут остаться нераспознанными; универсальная гарантия обхода любого custom JS интерфейса не заявляется. Матрица других приложений/Spaces остаётся отложенной из T-5.

Откат — revert отдельного коммита T-6 и повторная сборка; .local-signing/ сохраняется. В Applications приложение не перемещалось; TCC программно не менялся.
