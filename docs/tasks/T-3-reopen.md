# T-3 — открытие уже запущенной Боччи

## Дефект

Повторный Finder/open не показывает окно. На исходной версии процесс остаётся жив, sample показывает обычный AppKit run loop, но видимых окон процесса нет. AppDelegate не обрабатывает reopen AppleEvent; startup показывает setup только при отсутствии Accessibility. Для LSUIElement/accessory приложения повторное открытие не даёт наблюдаемого результата.

## Критический путь до изменения

Реальный вход — запущенный bundle через LaunchServices, повторный `/usr/bin/open` того же .app. Checker запускает обычный NSApplication/AppDelegate в паузе, чтобы не читать чужие интерфейсы и пиксели. Он закрывает своё окно, посылает настоящий reopen через open и проверяет видимость/key/activation того же window object и процесса. Второй цикл проходит при видимом pet NSPanel: hasVisibleWindows не должен мешать восстановлению setup. Прямой вызов delegate не считается доказательством доставки события.

Сначала checker запускается на исходной логике и должен дать red; затем тот же сценарий — green с исправлением. Логи находятся в artifacts/t3-*. Разрешения не запрашиваются и не меняются. После изменения выполняются существующие unit/runtime гейты, сборка bundle и независимое ревью. UI после открытия должен быть управляемым, без автоматического возобновления захвата.

## Изменение и доказательство

- Внешнее начальное состояние разрешений передаётся через initializer; тест использует явно названный granted-Accessibility fixture, обычный запуск — реальный `.current`. TCC не меняется; setup и heartbeat продолжают показывать реальные preflight-статусы.
- `AppDelegate.applicationShouldHandleReopen` вызывает уже существующий `showSetup()` независимо от `hasVisibleWindows` и возвращает `false`, поскольку событие обработано. Холодный запуск тоже всегда показывает setup. Закрытие настройки и режимы размещения продолжают работать прежним путём.
- `LaunchCheck` использует обычный lifecycle приложения с приостановленным размещением; чужие AX-деревья и пиксели не читаются. Checker не вызывает delegate напрямую, ждёт завершения своего `open` и проверяет идентичность, видимость, key и activation окна.
- До исправления `artifacts/t3-reopen-red.log`: 2 FAIL — окно не возвращается без окон и при видимой собственной NSPanel. После исправления `artifacts/launch-check.log`: 5 PASS, 0 FAIL. Полный `./scripts/check.sh` (`artifacts/t3-final-check.log`) завершился exit 0: 14 XCTest, 48 runtime и 5 launch проверок; release/plist/codesign прошли.
- Обычный запуск финальной сборки без тестового флага: `artifacts/t3-normal-launch.log`, один активный процесс и одно видимое окно ожидаемого размера. Проверены только метаданные собственных окон, без screenshot/AX/CUA.
- Возврат старого startup-условия при granted-Accessibility fixture дал `FAIL: initial launch shows setup` и общий FAIL (1 failed); оба reopen остались PASS. Артефакты `artifacts/t3-startup-red.log`, `artifacts/t3-startup-mutation.json` подтверждают чувствительность к регрессии и побайтное восстановление App.swift с совпадающими SHA. Холодный запуск с реально выданным Accessibility отдельно не проверялся; этот внешний OS-статус заменён fixture, TCC не менялся.
- Повторное независимое ревью проверило устранение test-evidence gap, red/green и privacy; остаточных findings кода не заявлено.

## Найденные дефекты и ограничения

1. Живой LSUIElement без окон игнорировал повторное открытие — добавлен reopen handler.
2. При уже выданном Accessibility холодный запуск не давал обычного окна — setup показывается всегда.
3. Перед `check.sh` нужно завершить другие экземпляры Боччи: LaunchServices выбирает работающий экземпляр по bundle, поэтому конкурирующая копия может получить тестовый reopen. Checker завершается, не закрывая чужой экземпляр.
4. Первоначальный launch-check зависел от реального AX=false и не ловил возврат старого startup-условия — после независимого ревью добавлен начальный granted-Accessibility fixture; целевая регрессия даёт red.

## Blocked / deferred и откат

Live AX/Screen smoke остаётся в [T-2](T-2-minimal-capture.md#blocked--deferred); этот фикс доказывает открытие приложения, но не размещение над чужими интерфейсами. TCC и пользовательские разрешения не менялись. Для остановки — меню ♪ → «Завершить Боччи». Для отката кода — revert отдельного коммита T-3 и повторная сборка; исходная сборка снова будет иметь описанный дефект reopen.

## Первоисточник

[Apple: applicationShouldHandleReopen(_:hasVisibleWindows:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)) — событие reopen и возврат после собственной обработки.
