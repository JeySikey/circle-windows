# Совместимость с сервером Circle 5.2.3

Исследован исходный `api/mobile.php` из `Circle_5.2.3_FULL(1).zip`. Клиент использует существующие маршруты: `login`, `me`, `logout`, `feed`, `post-create`, `post-upload`, `post-like`, `post-comments`, `post-comment`, `stories`, `story-create`, `story-media`, `post-media`, `profile`, `profile-save`, `profile-posts`, `user-profile`, `friends`, `conversations`, `messages`, `message-upload`, `message-reaction`, `communities`, `community`, `community-feed`, `channel-messages`, `channel-send`, `notifications`, `notification-read`, `mobile-call-history`. Для остальных веб-функций необходим дополнительный контракт API и дальнейшая разработка.

Это не исходники сайта и не ZIP-обновление сайта. В продуктивную PHP-установку ничего копировать не нужно.
