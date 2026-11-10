# Сопоставление Native 0.4.1 и Circle server 5.2.3

Источник: `Circle_5.2.3_FULL(1).zip`, конкретно `api/mobile.php`. Исходники сервера не изменены.

| Возможность | Маршруты | Статус клиента |
|---|---|---|
| Авторизация, TOTP, выход | login, me, logout | Реализован код |
| Лента, реакции, комментарии, ответы | feed, post-create, post-upload, post-like, post-comments, post-comment | Реализован код |
| Истории, медиа | stories, story-create, story-media, post-media | Реализован код изображения/видео |
| Профиль, аватар, обложка, посты | profile, profile-save, avatar-upload, profile-cover, user-profile, profile-posts | Основные экраны, без полного редактора профиля |
| Награды | reward-options, reward-select | Выбор разрешённых наград |
| Друзья | friends | Список и просмотр профилей; заявки/поиск отсутствуют в API |
| Переписка | conversations, messages, message-upload, attachment, message-reaction | Текст, вложения, WAV запись/отправка/воспроизведение, ответы, реакции |
| Сообщества и инвайты | communities, community, community-manage, invite-preview, invite-join, community-feed, community-post-create | Членство по приглашению, новости, базовое управление |
| Текстовые каналы | channel-messages, channel-send, channel-react | Реализован код |
| Звонки LiveKit | mobile-call-start/accept/poll/token/finish/decline, mobile-voice-token | Нативный код; тестов Windows + сервер пока нет |
| Уведомления | notifications, notification-read, notification-settings | Лента и настройки. Нет Windows push |
| Кинозалы | cinema-rooms | Только список (нет серверного API управления сессией) |
| Административная панель | admin-summary | Только статистика и очередь модерации |
| Автообновления | GitHub signed manifest (вне API) | Реализован код, нужна настройка ключа и публикация |

## Что потребует дальнейшего расширения сервера

Полный редактор сообществ (оформление/роли/права/приглашения), модерация и загрузка списков запрещённых слов, управление устройствами, дружеские запросы и поиск, редактирование и удаление постов, репосты, фоновая доставка Windows push, управление совместным просмотром, групповые личные вызовы и весь набор административных страниц. У этих действий нет подтверждённых полноценных Mobile API в архиве 5.2.3.

Не заменять такие функции прямыми SQL-запросами клиента: это нарушило бы модель доступа и безопасность.
