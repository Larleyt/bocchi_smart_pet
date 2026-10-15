# T-8 — Боччи скрыта в полноэкранном ChatGPT

## Проблема и критический путь до реализации

В fullscreen ChatGPT pet исчезает. Текущий подписанный процесс жив; trace повторяет needsVisualAccess position=nil AX=true screen=false visualOptIn=false. Код сознательно скрывает NSPanel, когда не находит AX-known области, но сводный trace не объясняет происхождение unknown.

Первый шаг — диагностические категории в том же production SystemInspector: window-match/budget/unknown role/container/read failure, role и AXError без текста/values/URL/клавиш/пикселей. Диагностика выполняется самой подписанной .app через LaunchServices; не использовать host screen/audio permission, не менять TCC или visual preference. Сохранить бюджеты и fail-closed до установления причины.

Исправление выбирается по подтверждённому native trace. Тест должен пройти реальный inspectTree → SystemSnapshot → PlacementSession → NSPanel с внешней fake AX-read boundary, сохранить защиту текстов/кнопок и unknown, воспроизвести исходный отказ до изменения и пройти после. Случаи failure/error, missing frame, unknown custom content и бюджет не объявлять пустым фоном ради показа. После — релевантный gate, независимое ревью и native показ в текущем развёрнутом окне: AX-only при полноценном дереве, иначе local visual после явного opt-in и ручного Screen Recording; конкретную живую причину и остаточные ограничения записать здесь.


## Подтверждённая native причина

Trace из самой подписанной .app, без host AX/screen permission: окно [0,30,2560,1410] успешно сопоставлено с AX window. Доступны три native controls и AXGroup с успешным пустым children. `framed_empty_container=1:AXGroup`, remainingNodes=589, примерно 5ms: ни node cap, ни 220ms timeout, ни window mismatch основного окна не являются причиной. Меню macOS даёт отдельные маленькие no-match области сверху; основной непрозрачный group делает unknown почти весь рабочий экран (artifacts/t8-live-before.log).

Проверены только публичные metadata relationships: AXChildrenInNavigationOrder возвращает успешный пустой массив; AXContents и AXVisibleChildren — noValue (-25212). Attribute names содержат ChromeAXNodeId, но значения DOM/text/title/URL/description не читались. NSWorkspace подтверждает foreground bundle com.openai.codex с Codex Framework.framework. Проверка стандартного AXManualAccessibility: query unsupported; единственная documented Electron setter-попытка возвратила attributeUnsupported (-25205), состояние приложения не изменено. Private AXEnhancedUserInterface не использовался. App-scoped point hit-test возвращает AXScrollArea без читаемого Children; finite sampling не доказывает безопасность остального group. Логи: artifacts/t8-alternatives-live.log, t8-hit-live.log, t8-request-live.log.

Это ограничение опубликованной структуры окна, не основание объявить непрозрачный group пустым фоном. По публичным Apple contracts navigation order — те же children в другом порядке, Contents — неполная convenience subset, VisibleChildren — видимое subset; ими нельзя безопасно заменить полную карту. Источники: [Apple navigation order](https://developer.apple.com/documentation/appkit/nsaccessibility-c.protocol/accessibilitychildreninnavigationorder?language=objc), локальные SDK AXAttributeConstants.h/NSAccessibilityConstants.h. Documented vendor request проверен по [Electron Accessibility](https://www.electronjs.org/docs/latest/tutorial/accessibility).

## Итог подготовленной части

Оставлена компактная reason-диагностика в SystemInspector + trace подключён к текущему App mode. Категории различают пустой container, unknown role, unsupported children, ошибки/лимиты и window-match. Native AXError для action query сохраняется. При trace=false дополнительные диагностические AX-запросы не выполняются; callbacks nil. Включение trace не читает text/value/URL и не меняет приём размещения. Сводка дедуплицируется по категориям/ролям и не повторяется каждый tick.

Широкие временные probes, attribute enumeration, hit-test и AXManualAccessibility write полностью удалены из итогового source. Их источник сохранён только в artifacts/t8-expanded-diagnostic-source.swift для воспроизводимости. Бюджеты, размеры pet, unknown/fail-closed и существующий visual fallback не ослаблены. Для реального fullscreen сейчас нужен уже реализованный local visual path и ручной доступ к пикселям; сам диагностический diff не исправляет отсутствие публичного дерева.

Runtime regression повторяет реальный shape: AXWindow → три кнопки + большой AXGroup без детей. Весь обычный traversal/Session/NSPanel production; только внешние AX reads/pixels заменены fixtures. Без visual result должен остаться needsVisualAccess, capturecount0, exact reason empty-container/AXGroup. После explicit visualAllowed на том же snapshot один локальный fixture crop показывает реальный panel. Это проверка механизма fallback, не доказательство живого pixel mode.

Целевая mutation удаления empty-container trace дала 63 PASS / 1 FAIL на соответствующем диагностическом regression; source восстановлен побайтно, SHA256 5638cb6fb8c1dc526d5dd4d4f13f32928539ef2cc2f4ac1cf326c78db81a35b7. Лог artifacts/t8-mutation-diagnostic-red.log. Финальный ./scripts/check.sh exit0: **16 XCTest + 81 runtime + 8 signing + 5 LaunchServices = 110 проверок, 0 failures**, release/plist/codesign прошли (artifacts/t8-final-check.log).

Независимое ревью artifacts/t8-review.md подтвердило privacy/fail-closed кода и отдельно отметило незавершённость цели: нельзя считать Боччи восстановленной без native shown(visual:true). Критерий AX-only show скорректирован по реальному ограничению AX provider, без ослабления запрета на неизвестное содержимое.

## Проверка после ручной выдачи доступа

После ручной выдачи полного доступа и перезапуска .app показ над приложениями восстановлен. После сборки T-9 заново запущенная через LaunchServices подписанная .app подтверждает `AX=true screen=true visualOptIn=true`, затем `shown(visual:true)`; повторные локальные проверки дают delta=0 и сохраняют координаты (artifacts/t9-final-live.log). AX по-прежнему сообщает empty-container/AXGroup: показ обеспечен реальной локальной визуальной проверкой, а не объявлением unknown пустым фоном.

Размещение после ручного разрешения восстановлено. Кадры обрабатываются самой .app в памяти; аудио выключено. Доступ требуется именно local.bocchi.smartpet; ChatGPT host permission не использовался. TCC и visual preference инструментом не менялись. Оставшиеся частые переселения и мигание при refresh выделены в [T-9](T-9-stable-scroll.md).

## Blocked / deferred

Полная матрица других приложений, нескольких дисплеев и native Spaces остаётся отложенной в T-5. Диагностика не доказывает полноту распознавания любого custom UI.

Приложение остаётся в dist, в Applications не перемещалось; автозапуск не менялся. Откат diagnostics — revert отдельного коммита T-8; .local-signing/ сохранить. Оставлена текущая подписанная .app с trace mode без стартового setup.
