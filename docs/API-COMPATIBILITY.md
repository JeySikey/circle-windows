# Возможности Circle Windows Native 0.5.0 и сайта Circle 5.2.3

Проверено по доступным исходникам `Circle_5.2.3_FULL(1).zip` и companion hotfix `api/mobile.php`. Действующая база на хостинге и LiveKit в этой среде недоступны — статическое соответствие не равно испытанию.

| Возможность | Mobile API | Состояние нативного клиента |
|---|---|---|
| Вход / 2FA / выход | login, me, logout | Нативный интерфейс, Windows Secure Storage |
| Регистрация и восстановление | register, forgot-password | Нативные формы, письмо зависит от SMTP |
| Главная, реакции | feed, post-create, post-upload, post-like | Нативная лента, публикации, фото/видео |
| Комментарии, ответы | post-comments, post-comment | Нативный интерфейс |
| Истории | stories, story-create, story-media | Просмотр, создание |
| Свой профиль, обложка | profile, profile-save, avatar-upload, profile-cover | Профиль, редактирование, резервный `me` при HTTP 500 |
| Профили и публикации других | user-profile, profile-posts | Профили и лента публикаций |
| Друзья и заявки | friends, friend-requests, people-search, friend-request, friend-respond, friend-remove, friend-request-cancel | Полный базовый цикл; новые маршруты только с серверным hotfix |
| Личные сообщения | conversations, messages, message-upload, attachment, message-reaction | Нативные диалоги, вложения, аудио, реакции, ответы |
| Сообщества, приглашения | communities, community, community-manage, invite-preview, invite-join | Вступление по ссылке, основные разделы |
| Текстовые каналы | channel-messages, channel-send, channel-react | Нативный интерфейс |
| Аудио/видео звонки | mobile-call-* и mobile-voice-token | Интеграционный код LiveKit; на Windows с реальными ключами не проверен |
| Уведомления | notifications, notification-read, notification-settings | В приложении; фоновых Windows Push нет |
| Награды | reward-options, reward-select | Выбор доступных наград |
| Кинозалы | cinema-rooms | Просмотр списка; не управление сеансами |
| Администрирование | admin-summary | Обзор; не полноценная веб-панель |
| Автообновления | GitHub Releases, не сайт | Подписанная проверка, ZIP-замена и перезапуск; реальное Windows испытание требуется |

## Пока не эквивалентно сайту

Расширенная панель модерации, списки запрещённых материалов, обработка фото/видео AI, все настройки ролей сообществ, групповые конференции, управление устройствами, повсеместное редактирование/удаление постов, Windows push и полноценное управление кинозалами не имеют завершённой нативной реализации. Требуют документированных, защищённых Mobile API с проверкой прав на PHP-сервере. Не следует выдавать их за уже готовые.
