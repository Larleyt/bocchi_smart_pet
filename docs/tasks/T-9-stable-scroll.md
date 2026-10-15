# T-9 — проверять участок после прокрутки, сохранять безопасное место

## Запрос и критический путь до реализации

После перезапуска с разрешениями Боччи всё ещё не видна над ChatGPT; кроме того, любой scroll заставляет её менять место даже над неизменным тёмным фоном. Это два независимых пути: доступ к визуальной проверке и политика переселения.

Native LaunchServices trace текущей подписанной .app: `AX=true screen=false visualOptIn=true`, `needsVisualAccess position=nil` (artifacts/t8-permitted-live.log). Сохранённая visual preference включена. Стабильный designated requirement совпадает с предыдущей сборкой. Программно TCC/настройки не менять; захват через host ChatGPT не использовать. До действующего screen=true визуальный fullscreen не считать исправленным. Статус меню должен явно отличать отсутствие Screen Recording от неизвестной AX-области.

Причина лишнего движения подтверждена production-кодом: PlacementSession.input добавляет lastPlacement в activityAreas при каждом contentMoved; invalidate уничтожает локальный эталон. Значит, даже прежний чистый фон исключается без проверки. Этот контракт T-6/T-7 заменён.

Путь: реальные App event routing и AX notification → PlacementSession.input/invalidate → inspect → локальная PixelSample → PlacementEngine → NSPanel. В regression внешними fixtures являются только AX snapshot, pixels и время; Session/engine/panel остаются production. До реализации новый тест должен упасть на текущем поведении, затем пройти на итоговом коде.

Приёмка: scroll и click→drag без изменения свободного участка сохраняют координаты; после input локальная проверка обязательна даже раньше 5 секунд. Новая преграда, текст/деталь или >=10% delta вызывают переезд. AX-only с прежней безопасной картой не снимает экран. Cursor collision продолжает исключать прежнюю точку. Устаревший async capture не публикуется после нового input/смены условий. Изменение карты вне питомца не должно само по себе переселять её. Реальный отказ захвата скрывает panel.

С полным разрешением pet появляется над приложениями; оставшийся дефект — частое перемещение и исчезновение при обновлении. Мягкая перепроверка должна сохранять последнее показанное окно, включая время задержанного capture. Generation по-прежнему меняется, поэтому старый async результат не публикуется. Подтверждённая опасность, ошибка, pause, смена приложения/Space/экрана/разрешений скрывают сразу. Удаляется независимый App watchdog `lastSuccess > 2.5s`, который гасил pet во время длинного scroll; 2.5s TTL принятия отдельного async результата остаётся. Во время непрерывного жеста проверка ждёт паузы ввода 250ms: прежняя позиция может временно накрывать новый контент, но panel пропускает клики. Это сознательный предел сохранения видимости, а не гарантия актуальной карты во время жеста.

## Проверка и итог

Session сохраняет baseline и последнее видимое окно при мягком invalidate; при этом generation увеличивается, а ближайшая проверка участка обязательна независимо от 5s интервала. AX/window map churn не сбрасывает безопасную позицию. Cursor collision, подтверждённые AX/pixel obstacles и >=10% delta исключают старое место; ошибки и hard reset скрывают panel. App сбрасывает проверку при смене display, приложения/Space и разрешений; самостоятельный watchdog lastSuccess удалён, TTL отдельного inspect/capture 2.5s сохранён. Параметры захвата, аудио, разрешения и зависимости не менялись.

Runtime путь проходит production Session/engine/NSPanel. Проверены неизменный AX-only pan без снимка; click→drag→локальная проверка раньше5s с сохранением координат; изменение pixel delta и новой AX-преграды; изменения карты вне pet; сохранение видимости во время delayed capture; запрет stale publication после нового input; error hide и прежние privacy/unknown/full-map ограничения. Внешние AX/pixels/time явно заменены fixtures.

Полный ./scripts/check.sh exit0: **16 XCTest + 90 runtime + 8 signing + 5 LaunchServices = 119 проверок, 0 failures** (artifacts/t9-final-check.log). Release/plist/codesign прошли.

Native подписанная .app через LaunchServices: AX=true/screen=true/visualOptIn=true, shown(visual:true); повторные локальные проверки delta=0 сохраняют placement (artifacts/t9-final-live.log). Отдельное 30s наблюдение только за геометрией собственного CGWindow: 512 выборок, окно видимо во всех512, исчезновений0, смен позиции0 (artifacts/t9-own-panel-watch.log). Это дискретное наблюдение, не доказательство отсутствия любого субмиллисекундного изменения окна. Длинный scroll без движения и мигания подтверждён ручной проверкой.

Изолированный baseline185ddf2 с новым stable-pan assertion дал **39 passed / 1 failed**; точечная mutation возврата hard hide при каждом invalidate дала **37 passed / 1 failed**. Сырые логи, patches и SHA сохранены в artifacts/20261016_011532_t9_evidence/. Рабочие source/tests/dist при повторе этих отрицательных проверок не менялись.

Независимое ревью запросило отдельную чувствительность к App watchdog: Session-тесты не выполняют App.tick. Для этого в artifacts/20261016_012031_t9_watchdog_replay/ сохранены две подписанные копии с одним общим временным harness. Каждая получает настоящую первую позицию обычным App.tick/inspect/Session/capture и четыре секунды подаёт явно fake external scroll через production App.input каждые50ms, без global events; видимость измеряется на каждом настоящем heartbeat. Единственная разница копий — возврат старого lastSuccess watchdog. Native RED: **21 ticks / 9 hidden / visible=false / stable=true**; GREEN: **21 ticks / 0 hidden / visible=true / stable=true** (red-native.log, green-native.log). Рабочие source/tests/dist не менялись; все10 source/config SHA после replay совпали. Тестовые копии завершились, обычная dist .app восстановлена через LaunchServices с native visual show (artifacts/t9-restored-live.log).

Итог независимого ревью после проверки source, raw logs, patches и SHA: **Ship, findings отсутствуют** (artifacts/t9-review.md). T-9 принята по локальным проверкам, native измерению и ручной проверке.

## Blocked / deferred

Действующие разрешения, native visual show и длинный scroll подтверждены. Полная cross-app/Space матрица и гарантированное распознавание любого custom JS control остаются вне этого исправления. Во время непрерывного жеста до его паузы сохраняется последняя проверенная click-through позиция, поэтому визуальное перекрытие нового контента на этот промежуток возможно.

Откат — revert отдельного коммита этой задачи и пересборка с сохранённой .local-signing/. Приложение остаётся в dist, в Applications не перемещается.
