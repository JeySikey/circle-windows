## 0.6.1 — исправление обнаружения обновлений и публикации Release (10 ноября 2026)

- Публикация подписанного стабильного GitHub Release автоматически после успешной сборки ветки main/master при увеличении версии.
- Без создания тега вручную: GitHub создаёт тег при первом Release автоматически; существующий тег не перезаписывается.
- Обновления в Actions/Artifacts больше не путаются с опубликованными Releases; при 404 манифеста приложение показывает настоящую причину вместо «Актуальная версия».
- Защита от повторной публикации той же версии, конфликта тегов, отката версии и публикации из закрытого репозитория, из которого клиент не сможет скачать обновление без авторизации.
- Добавлены офлайн-тесты выбора релиза и регрессионный тест 404; сервер Circle 5.2.3 не изменяется.

## 0.6.0 — нативный паритет социальных функций (10 ноября 2026)

- Редактирование собственных публикаций, включение/выключение комментариев, удаление, закрепление в профиле.
- Репосты/отмена репостов с агрегированными счётчиками без N+1 запросов; вкладка «Репосты» в профиле.
- Удаление своего комментария без разрушения дочерних ответов.
- Создание переписки с другом из чужого профиля (проверка дружбы на сервере).
- Загрузка обложки и настройки видимости профиля.
- PHP companion Mobile API 5.2.3 patch 0.6.0, без SQL-миграций и смены данных.
- Обновлены GitHub Actions, инкремент версии и программные проверки.
- Сохранены механизм подписанных обновлений, прежний AppId и основная графитово-золотая концепция.

## CI hotfix 2 — 10 ноября 2026 (версия приложения 0.5.1 без изменений)

- Устранена ошибка GitHub Actions `can't open file tool/test_installer_ci.py`.
- Проверки корректного ожидания Inno Setup, чтения журнала и целостности установленного runtime встроены в `tool/validate_package.py`.
- `windows.yml` запускает единый валидатор и не зависит от отдельного `test_installer_ci.py`.
- Валидатор проверяет наличие всех Python/PowerShell скриптов, которые вызывает Windows workflow, и сообщает конкретный отсутствующий путь.
- `tool/test_installer_ci.py` оставлен для локальных проверок, но для сборки в GitHub не обязателен.
- Параметры ключа, серверный API и код Flutter не менялись.

# История изменений Circle Windows Native

## 0.5.1 CI HOTFIX — корректная проверка Inno Setup

- Проверка установщика использует `Start-Process -Wait -PassThru` и реальный `ExitCode`, вместо неинициализированного `$LASTEXITCODE` для GUI EXE.
- При падении установки CI показывает журнал Inno Setup и сохраняет его как `Circle-Installer-Diagnostics`.
- Проверяется полнота Flutter Runtime до упаковки и установленного runtime после Inno; добавлен регрессионный Python-тест CI.
- Изменения не влияют на серверные данные, API, подписи и версию приложения (`0.5.1`).

## 0.5.1 — GitHub Actions key bootstrap (no local Python)

- Добавлен отдельный workflow `Circle signing key setup` для одноразовой генерации Ed25519 на GitHub Actions.
- Приватный ключ сохраняется прямо в GitHub repository Actions secret через временный fine-grained PAT; ключ не выводится в лог и не попадает в ZIP/артефакты.
- Сценарий запрещает перезапись существующего приватного ключа; основной workflow прекращает сборку, если ключ не настроен, вместо выпуска EXE с неработающим автообновлением.
- Обновлена инструкция GitHub-only; после успешного bootstrap временный PAT необходимо отозвать.
- Проверены Python тесты криптографии и структура релизного ZIP; компиляция Windows остаётся задачей GitHub runner.

## 0.5.0 — GitHub auto-updates, profile hotfix, speed, design

- Проверка новой версии на GitHub Release при старте; подтверждение, потоковая загрузка подписанного ZIP, проверка Ed25519/SHA-256.
- Отдельный безопасный updater в PowerShell: проверка путей, извлечение в staging, подмена каталога после закрытия старого процесса, запуск нового EXE, попытка отката.
- Автоматическое определение репозитория и публичного ключа в GitHub Actions; подпись манифеста из одноразово настроенного GitHub secret.
- Workflow публикует installer + update payload + signed manifest для tag release, проверяет installer и ZIP на Windows runner.
- Обработчик профильного SERVER_ERROR; отдельный минимальный PHP Mobile API hotfix убирает хрупкие зависимости от необязательных таблиц и добавляет запросы в друзья.
- Формы регистрации и восстановления пароля; поиск людей и управление дружбой.
- Отложенная инициализация страниц, списки с ленивой отрисовкой, ограниченный кэш изображений, ленивая загрузка видео/аудио, потоковые файлы, отсутствие наложения long-poll входящих звонков.
- Графитовые/золотые токены, обновлённые панели, поля, профиль, навигация, кнопки и индикация обновлений.
- Подготовлены спецификация обновления, совместимость API, тесты подписи и сборочные сценарии.

**Статус:** статическая и PHP/Python проверка; полноценная компиляция Flutter, запуск на Windows, работа LiveKit и откат на реальном ПК остаются задачами первого теста.

## 0.4.2 — startup fixes

Необязательные Windows сервисы перенесены за первый кадр; проверка Windows runtime; диагностика запуска.

## 0.7.0 — Desktop feature parity expansion

- Added native settings for account security, device/session management, TOTP enrolment and recovery codes.
- Added new community creation, invites, roles, permissions, moderation, voice channels, appearance and icon/banner upload.
- Added direct message editing/deleting/archiving, channel moderation actions and group LiveKit meetings.
- Added native Trust & Safety moderation interface with TXT/DOCX rule imports.
- Refined site-aligned dark/gold UI, soft contextual glow, compact responsive layout and limited avatar cache.
- Added authenticated `api/desktop_ext.php`, server-side permission checks, and Desktop API regression guard. No database migration.
- No change to release signing key; updater maintains GitHub Releases signed runtime ZIP mechanism.
