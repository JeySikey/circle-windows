# Текущая итерация: Windows 0.10.0 (кандидат)

Фокус пользователя — Windows: дизайн, навигация и отзывчивость. Основой служит подтверждённая версия 0.9.0. Подробности, ограничения и порядок проверки — `docs/UI-0.10.0.md`; результаты локальных проверок — `docs/validation/`. Старые утверждения handoff о падающих тестах модерации и неработающем updater относятся к состоянию до предоставленного успешного CI 0.9.0 и подтверждения пользователя.

# Circle Windows — исходный репозиторий для Codex

Восстановлен **полный Flutter-проект 0.9.0** наложением патчей на базовый полный ZIP 0.6.0. Итог включает последнее изменение `test/desktop_command_moderation_test.dart` (`pump` после ввода текста) из предыдущего обсуждения. **После этого hotfix успешная сборка не подтверждена.**

Рабочие файлы: `lib/`, `test/`, `tool/`, `.github/workflows/windows.yml`, `installer/Circle.iss`, `pubspec.yaml`, `assets/`. Папка `windows/` отсутствует в исходных ZIP и создаётся командой `flutter create --platforms=windows --project-name=circle_windows .` в workflow. Не интерпретировать это как отсутствие самого Flutter-приложения.

Сначала сравнить с актуальной удалённой веткой GitHub и сверить версию/контракт сервера. Не переписывать новые коммиты поверх восстановленного ZIP без анализа diff. Далее: `flutter pub get`, `flutter analyze`, `flutter test`, Windows build, Inno Setup, unit+integration updater.

История требований и инцидентов — в `docs/codex/CODEX_HANDOFF.md` и в общем `codex-handoff`.
