# T-4 — Accessibility не видит уже выданный доступ

## Дефект и причина

Accessibility уже был разрешён, но повторное включение не меняет статус и окно остаётся открытым. Журнал `artifacts/t4-permission-log.txt` фиксирует Allowed для `local.bocchi.smartpet`, после чего проверка старого cdhash `15080125…` завершается `-67050` и `Failed to match existing code requirement`. Текущий bundle имеет другой ad-hoc DR `95a454…`. Bundle ID тот же, идентичность подписи изменилась при пересборке. Валидных существующих code-signing identities нет.

## Критический путь до изменения

Сборка должна сохранять криптографическую идентичность между разными бинарниками: local certificate/key в отдельном игнорируемом keychain проекта, без установки доверия в system/login keychain и без identifier-only DR. Проверка работает с двумя настоящими Mach-O вариантами: при старом ad-hoc requirement второй отклоняется, при новой подписи оба проходят один DR, посторонний signer отклоняется. Сначала bounded smoke инструментов и восстановления keychain search list; затем повторная сборка с тем же keychain и полный gate.

Окно должно закрываться при фактически наблюдаемом переходе Accessibility false → true. Runtime-проверка меняет только явно названное внешнее permission fixture и проверяет настоящий NSWindow: denied остаётся видимым, granted скрывает окно, Screen Recording для AX-режима не требуется. Возврат старого поведения обязан дать red. Ручное открытие настройки при уже разрешённом AX должно оставаться доступным.

TCC не изменяется программно, разрешения не нажимаются инструментом. Старую запись, связанную с ad-hoc сборкой, потребуется один раз удалить и выдать доступ финальной стабильной сборке вручную. Реальный grant/live AX без этого не объявляется подтверждённым.

## Реализация и проверки

- `scripts/sign-app.py` хранит единственную RSA-2048 code-signing identity в `.local-signing/` (directory 0700, files 0600, gitignored). PEM private key и PKCS#12 существуют только в task-owned temporary directory на время создания и удаляются после импорта. Секреты не выводятся. Срок сертификата — до октября 2036; смена сертификата потребует новой выдачи доступа.
- DR привязан к `certificate leaf` SHA-1 fingerprint **и** `local.bocchi.smartpet`; identifier-only правило и ad-hoc fallback отсутствуют. Пересоздание незавершённой identity автоматически не выполняется. Подпись сериализована lock-файлом; команды имеют timeout. Ключи не добавляются в system/login keychain и сертификату не выдаётся trust.
- `codesign` требует keychain в user search list даже с `--keychain`. На время подписи добавляется только project keychain, в `finally` удаляется только своя запись с сохранением других текущих entries и блокируется свой keychain. `artifacts/t4-keychains-before.txt` и `artifacts/t4-keychains-after.txt` побайтно совпали: остался только исходный login keychain. При аварийном завершении процесса `SIGKILL` finally не гарантируется; следующий запуск уберёт свою запись после подписи.
- `scripts/check-signing.py`: 8 PASS, 0 FAIL — исходный ad-hoc DR принимает A и отвергает другой B; новый DR одинаков при разных CDHash A/B, совпадает с DR production `.app`, принимает обе подписи своего сертификата, отвергает ad-hoc с тем же identifier и сохраняется при повторной подписи. Это настоящий `clang`/Mach-O/`codesign`, без fake signing.
- UI red: отключение auto-dismiss даёт `FAIL: observed Accessibility grant dismisses setup without Screen Recording`, 5 PASS/1 FAIL. Исходный файл восстановлен побайтно с совпадающими SHA (`artifacts/t4-ui-red.log`, `artifacts/t4-ui-mutation.json`). Итоговый runtime проходит denied → denied → AX-only grant → скрыто и ручное повторное открытие с уже разрешённым AX → видно.
- `./scripts/check.sh` завершился exit 0: 14 XCTest, 52 runtime, 8 signing, 5 launch, 0 failures; release/plist/codesign прошли. Лог `artifacts/t4-final-check.log`. Финальная `.app` подписана `Bocchi Smart Pet Local Signing`, DR содержит pinned leaf certificate и identifier.
- Возврат production-вызова в `build-app.sh` на старую ad-hoc подпись даёт `SIGNING-CHECK RESULT: FAIL: packaged app uses the persistent project requirement`. Build script восстановлен побайтно (совпадающие SHA); затем повторён полный green. Артефакты `artifacts/t4-packaged-red.log`, `artifacts/t4-packaged-mutation.json`.
- Повторное независимое ревью подтвердило устранение packaged-app test gap, полноту red/green, стабильный DR и privacy; остаточных findings кода не заявлено.
- После ручного удаления старой записи и добавления текущей `.app` журнал `artifacts/t4-after-user-grant.log` показывает новый Accessibility `Allowed` с pinned certificate DR; `artifacts/t4-new-process-permission.log` подтверждает совпадение этого DR (`status: 0`) и `ReqResult(Auth Right: Allowed (System Set))` для нового процесса. Приложение запущено из исходного `dist/`, файлы в Applications не перемещались. Чужие AX-деревья и экран для этой проверки не читались.

## Найденные дефекты

1. Ad-hoc подпись меняла identity между сборками и оставляла разрешение старому cdhash — заменена устойчивой криптографической подписью.
2. Повторный permission prompt не может исправить stale grant — в UI/README дана разовая замена записи через «−»/«+» с точным путём.
3. Окно не реагировало на фактически выданный доступ — auto-dismiss только при наблюдаемом false → true; ручное открытие с уже выданным доступом сохраняется.
4. Независимое ревью выявило test-evidence gap: signing fixtures не защищали production вызов signer в build-app. Добавлена проверка DR именно готовой `.app`; целевая мутация возврата ad-hoc в build-app дала red, script восстановлен побайтно и полный gate повторён.

## Blocked / deferred и откат

- Настоящий новый Accessibility grant подтверждён после ручной замены записи. Сохранение этого grant через следующую сборку именно в TCC ещё не проверено; криптографическая стабильность проверена. Live-сценарии размещения остаются в [T-2](T-2-minimal-capture.md#blocked--deferred). При запуске с уже выданным доступом setup открыт для управления; размещение начинается после «Закрыть и начать».
- Запрос хоста на screen/audio доступ можно отклонить: эта задача не требует screen-доступа хоста. В диагностике T-4 screen/audio capture не вызывался; инициатор системного запроса не установлен. Собственный capture Боччи использует `capturesAudio=false`; её пиксельный режим остаётся отдельным opt-in.
- Остановка — меню ♪ → «Завершить Боччи». Откат кода — revert отдельного коммита T-4 и пересборка; старый ad-hoc дефект вернётся. Не удалять `.local-signing/` при откате: это материал восстановления identity. Автозапуск/системное доверие/TCC программно не менялись.

## Первоисточники

- [Apple TN3127: code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
- [Apple TN2206: self-signed identities и собственные certificate anchors](https://developer.apple.com/library/archive/technotes/tn2206/).
- [Apple Code Signing Guide: leaf certificate requirements не требуют системного trust](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
- [Apple DTS: ad-hoc подпись теряет privacy identity при пересборке](https://developer.apple.com/forums/thread/819406).
- Локальный первоисточник `man codesign`, разделы `--keychain`, `SIGNING IDENTITIES`.
