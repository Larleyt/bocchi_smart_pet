# Backlog

| ID | Задача | Статус |
|---|---|---|
| T-1 | [Локальный питомец с размещением вне текста и кнопок](docs/tasks/T-1-smart-placement.md) | Локально: 9 unit + 26 runtime проверок прошли; live-сценарий blocked до разрешений macOS. Подход к захвату пересматривается в T-2. |
| T-2 | [Системные данные прежде пикселей и понятные разрешения](docs/tasks/T-2-minimal-capture.md) | Реализовано; локальные гейты 14 unit + 48 runtime + release/codesign прошли. Blocked: live AX/Screen smoke после ручных разрешений macOS. |
| T-3 | [Окно при запуске и повторном открытии](docs/tasks/T-3-reopen.md) | Исправлено; real LaunchServices red → green, 5 launch + 14 unit + 48 runtime проверок прошли; обычный запуск имеет видимое активное окно. |
| T-4 | [Стабильная подпись и переход после выдачи Accessibility](docs/tasks/T-4-permission-identity.md) | Реализовано; 14 unit + 52 runtime + 8 signing + 5 launch проверок прошли. Реальный Accessibility grant текущей подписи подтверждён TCC. Deferred: сохранение grant после следующей сборки и live placement smoke. |
