# Backlog

| ID | Задача | Статус |
|---|---|---|
| T-1 | [Локальный питомец с размещением вне текста и кнопок](docs/tasks/T-1-smart-placement.md) | Локально: 9 unit + 26 runtime проверок прошли; live-сценарий blocked до разрешений macOS. Подход к захвату пересматривается в T-2. |
| T-2 | [Системные данные прежде пикселей и понятные разрешения](docs/tasks/T-2-minimal-capture.md) | Реализовано; локальные гейты 14 unit + 48 runtime + release/codesign прошли. Blocked: live AX/Screen smoke после ручных разрешений macOS. |
| T-3 | [Окно при запуске и повторном открытии](docs/tasks/T-3-reopen.md) | Исправлено; real LaunchServices red → green, 5 launch + 14 unit + 48 runtime проверок прошли; обычный запуск имеет видимое активное окно. |
| T-4 | [Стабильная подпись и переход после выдачи Accessibility](docs/tasks/T-4-permission-identity.md) | Реализовано; реальный grant подтверждён TCC, его сохранение после новых сборок и AX-only placement подтверждены в T-5. |
| T-5 | [Живой показ после закрытия настройки](docs/tasks/T-5-live-placement.md) | Исправлены frameless/zero-area structural AX groups. Реальное AX-only размещение и on-screen pet panel 84×156 подтверждены; расширенная cross-app/Space матрица deferred. |
| T-6 | [Переезд после pan и защита JavaScript controls](docs/tasks/T-6-relocation-controls.md) | Исправлены relocation после pan и whole-frame AX actions; 100 проверок, 0 failures, 3 red mutations и независимое ревью прошли. Native AX-only показ подтверждён. Live отзыв: cursor relocation работает, общий выбор остаётся в углу; исправление политики выбора продолжается в T-7. Реальные JS controls/visual mode ещё не подтверждены. |
| T-7 | [Осмысленный выбор свободной области после live отзыва](docs/tasks/T-7-live-pan.md) | Roomiest placement, rerank, visual priority и pan ban исправлены; 108 проверок, 0 failures, baseline red + 4 mutations, native scroll→relocation подтверждён. Visual preference/Screen Recording реально выключены; canvas/JS smoke и отзыв о новом месте ожидаются. |
