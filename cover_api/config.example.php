<?php
declare(strict_types=1);

return [
    // 建议在服务器环境变量中配置；也可以直接把密钥填在这里。
    'lastfm_api_key' => getenv('LASTFM_API_KEY') ?: '',
    'openrouter_api_key' => getenv('OPENROUTER_API_KEY') ?: '',

    // 结构化曲库都失败时，让 DeepSeek 联网寻找原始发行封面。
    'openrouter_search_model' => '~deepseek/deepseek-flash-latest',
    // 纯英文歌词逐行翻译为简体中文，服务器和播放器都会缓存结果。
    'openrouter_translation_model' => '~openai/gpt-sol-latest',
    // 首次缺失译文时联网参考已有译文；按歌曲缓存搜索（含空结果）七天。
    // OpenRouter 搜索额外收费；关闭后仍按歌曲语境做自然翻译。
    'translation_reference_search' => true,
    'translation_timeout_seconds' => 60,
    // Asia/Shanghai 每日零点重置；缓存命中不计数，分批翻译同一首只算一次。
    'translation_daily_song_limit' => 5,
    // 模型有地区限制时可填已有中转地址或代理；默认保持直连 OpenRouter。
    'openrouter_chat_url' => getenv('OPENROUTER_CHAT_URL') ?: 'https://openrouter.ai/api/v1/chat/completions',
    'openrouter_proxy' => getenv('OPENROUTER_PROXY') ?: '',

    // 对外部署时建议设置访问令牌，避免别人消耗你的 OpenRouter 额度。
    'access_token' => getenv('COVER_API_TOKEN') ?: '',
    'cache_dir' => __DIR__ . '/cache',
    'cache_ttl_days' => 365,
    'request_timeout_seconds' => 15,
    'max_image_bytes' => 12 * 1024 * 1024,
    // 正式服务器应保持 true；只有系统缺少 CA 根证书时才临时关闭。
    'verify_tls' => true,
    'app_url' => getenv('COVER_API_APP_URL') ?: '',
];
