# T-5 — Боччи скрыта после «Закрыть и начать»

## Критический путь до изменения

Accessibility для текущей certificate-pinned подписи подтверждён реальным TCC. После закрытия setup процесс остаётся жив, но питомец не появляется. Existing runtime fixtures не доказывали обработку настоящего AX-дерева приложения. Вероятные причины: incomplete AX snapshot превращает окно целиком в unknown или актуальный результат постоянно отбрасывается.

Сначала категориальная диагностика из самого подписанного `.app`: обычные App.tick → SystemInspector → PlacementSession → NSPanel, без текста/URL/AX values, без screen/audio capture и host AX. Флаг диагностики пропускает setup и принудительно отключает visual fallback только для этого запуска. Сохраняются причина обхода и исход размещения, затем исправляется подтверждённая причина. Возврат дефекта должен дать red на сохранённом внешнем AX fixture через реальную логику, затем green. Повторная сборка с тем же DR также проверяет сохранение реального grant.

Unknown запрещено просто игнорировать: иначе незамеченный текст/кнопки станут допустимым местом. Рабочие файлы и логи остаются в проекте. Приложение не перемещается в Applications.

## Подтверждённая причина и исправление

1. Первый live trace показал `frame unavailable, role=AXGroup` → `needsVisualAccess`. Обязательная рамка у структурного контейнера обрывала обход прежде дочерних текстов/кнопок. Общий traversal теперь использует четыре внешние AX-read границы; непустой контейнер обходится через детей без требования собственной рамки.
2. Этого оказалось недостаточно: реальный leaf `AXGroup` имел **успешно прочитанную рамку 0×0**, которую прежняя валидация смешивала с отсутствующей геометрией. `artifacts/t5-frame-trace-stderr.log` показывает нулевую площадь, `expired=0`, более 570 оставшихся узлов. Значит это не исчерпание бюджета. Новый `AccessibilityFrame` различает `visible`, `empty` и `unavailable`.
3. Нулевая площадь допустима для структурного leaf с успешно прочитанным пустым children. Отсутствующая/повреждённая рамка, zero-sized obstacle/unknown, отрицательные и NaN размеры по-прежнему закрывают окно как unknown. Непустые структурные контейнеры сохраняют обход детей, включая выступающие за их нулевую рамку элементы. Никакие unknown-области не объявлены свободными.
4. Попутно исправлено голодание admission: общий `invalidate()` больше не сбрасывает время последнего пользовательского ввода; настоящий `input()` продолжает это делать. Удалены только `kAXValueChanged` subscriptions, поскольку значения не читаются и их controls уже защищены целиком. Layout/focus/create/move/resize/destroy и периодический AX refresh сохранены. Stale generation/current-context проверки не ослаблены.

## Проверка и доказательства

- Внешний AX fixture задаёт структурную группу без рамки, соседний пустой контейнер 0×0, настоящие bounds текстов и кнопки. Тот же `inspectTree`, что используется production AX adapter, строит препятствия; `PlacementSession` показывает реальный NSPanel вне текста/кнопки. Любой pixel capture в этом пути вызывает FAIL. Отдельно проверены missing/zero obstacle, missing/zero unknown role, пустой контейнер без геометрии, отрицательные и nonfinite frames.
- Мутация возврата обязательного frame для структурного контейнера дала 20 PASS/1 FAIL. Мутация смешивания `empty` и `unavailable` тоже дала 20 PASS/1 FAIL на AX-only placement. Источники восстановлены побайтно с совпадающими SHA. Артефакты: `artifacts/t5-structural-red.log`, `artifacts/t5-structural-mutation.json`, `artifacts/t5-zero-frame-red.log`, `artifacts/t5-zero-frame-mutation.json`.
- Промежуточный live-прогон после одного structural fix ещё давал `needsVisualAccess` и COUNT=0 (`artifacts/t5-live-after-stderr.log`, `artifacts/t5-own-panel-live.log`); он не считался успешным.
- После исправления 0×0: `artifacts/t5-zero-fixed-live.log` содержит `shown(visual: false) AX=true`, 17 obstacles. `artifacts/t5-zero-own-panel.log` подтверждает ровно одно on-screen окно размером 84×156. Это собственная pet panel; setup в диагностическом запуске не показывается. Проверены только метаданные собственного окна, без пикселей или имён чужих окон.
- Реальный AX grant сохранён через новые сборки с изменённым кодом и тем же certificate-pinned DR: нативный inspector возвращает AX=true и читает реальные AX bounds без повторного запроса доступа.
- Финальный `./scripts/check.sh` завершился exit 0: 14 XCTest, 59 runtime, 8 signing и 5 LaunchServices проверок, 0 failures; release/plist/codesign прошли (`artifacts/t5-final-check.log`). После gate-пересборки повторный запуск реального приложения снова дал `shown(visual: false) AX=true` и одно on-screen окно (`artifacts/t5-final-live.log`, `artifacts/t5-final-own-panel.log`). Начальный stale результат был отброшен, после стабилизации сцены опубликована новая позиция.
- Независимое ревью проверило окончательный source, обе red/green мутации, границы `.empty/.unavailable`, полный gate и финальный live показ; остаточных findings кода не заявлено.

## Диагностика

`--diagnose-placement` использует обычный App.tick/session/overlay, пропускает setup и принудительно запрещает visual fallback для этого запуска. Только при изменении outcome в stderr выводятся категория и числа windows/obstacles/unknown. Значения текста, URL, идентификаторы чужих окон и пиксели не читаются/не сохраняются. Временные подробные AX trace-логи из кода удалены; входные live-логи сохранены в `artifacts/`.

## Blocked / deferred и откат

Показ на текущем реальном экране подтверждён. Полная матрица Safari/Chrome, Space/fullscreen, unsupported notification delivery и гарантированное размещение в любом custom canvas не проверены. Интерфейс, который не публикует достаточно AX-геометрии, по-прежнему может скрывать питомца без opt-in visual fallback. Лимиты 128 windows, 600 AX nodes, 220ms, 25ms IPC не увеличены. Screen/audio capture и запись чужих AX-значений в диагностике отсутствовали.

Откат — revert отдельного коммита T-5 и повторная сборка; сертификат `.local-signing/` сохраняется. Остановка приложения через меню ♪. Фоновые log-stream ожидатели завершились по timeout.
