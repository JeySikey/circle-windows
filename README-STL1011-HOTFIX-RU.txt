Circle Windows 0.11.0 — исправление сборки Visual Studio 2026 / STL1011

Это точечный патч GitHub Actions. Не меняет приложение, API сайта, ключи Ed25519 и номер версии.

ФАЙЛЫ:
1. .github/workflows/windows.yml — добавлены этап и тест совместимости C++ plugin.
2. tool/enable_windows_notification_coroutines.py — добавляет временный MSVC define в windows/CMakeLists.txt после `flutter create`.
3. tool/test_windows_notification_coroutines.py — проверяет идемпотентность, CRLF и наследование определения дочерним CMake-плагином.

ПРИМЕНЕНИЕ:
Распакуй архив в корень существующего репозитория Circle Windows, сохраняя структуру путей.
Замени только перечисленные файлы. Commit changes → Actions → Circle Windows build.

ПРИЧИНА:
MSVC 14.51 (Visual Studio 2026) прекращает сборку некоторых старых native plugins с STL1011 из-за заголовка <experimental/coroutine>. Флаг _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS — временная совместимость, не окончательное исправление стороннего C++ плагина.

НЕ ПОДТВЕРЖДЕНО:
Windows-компиляция на GitHub и отображение toast на реальной Windows требуют отдельного теста.
В будущем стоит обновить сам плагин, когда он перейдёт на стандартный C++20 <coroutine>.
