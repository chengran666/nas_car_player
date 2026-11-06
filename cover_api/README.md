# NasPlayer 封面与歌词翻译中转 API

接口按以下顺序寻找封面，并把最终图片缓存到服务器磁盘：

1. iTunes Search（中国大陆、台湾、香港、美国）
2. Last.fm
3. Deezer（优先获取 1000×1000 封面）
4. MusicBrainz + Cover Art Archive
5. OpenRouter 联网寻找原始发行封面

双歌手会同时尝试组合名和每位歌手，例如 `金莎、林俊杰` 会依次查询组合名、`金莎`、`林俊杰`。

## 部署

需要 PHP 8.1+ 和 cURL、mbstring、SQLite3 扩展。首次部署时将服务端文件上传到 PHP 网站目录，并从配置样例创建实际配置：

```bash
cp config.example.php config.php
```

编辑 `config.php`，至少填写：

```php
'lastfm_api_key' => '你的 Last.fm API Key',
'openrouter_api_key' => '你的 OpenRouter API Key',
```

也可以通过服务器环境变量 `LASTFM_API_KEY` 和 `OPENROUTER_API_KEY` 配置。升级已有站点时保留实际 `config.php` 与缓存，Git 中只提交 `config.example.php`。旧配置中的 `access_token` 可以移除，旧客户端携带的请求头会被忽略。

配置的 `openrouter_search_model` 只负责联网搜索和筛选候选，不再生成图片。AI 搜索结果必须来自允许的音乐图片 CDN，并通过实际图片格式检测后才会缓存。

确保 PHP 对 `cache` 目录具有写权限。Nginx 加载 `nginx-downloads.conf` 以阻止访问配置与内部缓存，Apache 使用 `.htaccess`。

如果服务器提示 `unable to get local issuer certificate`，应优先安装或配置系统 CA 根证书。也可以暂时在 `config.php` 中设置 `'verify_tls' => false` 排查，但正式公网服务器建议保持 TLS 校验。

## 调用

接口默认直接返回图片，可以作为播放器封面 URL：

```text
https://你的域名/cover_api/?title=被风吹过的夏天&artist=金莎、林俊杰
```

调试时可返回 JSON 元数据：

```text
https://你的域名/cover_api/?title=被风吹过的夏天&artist=金莎、林俊杰&format=json
```

请求可加 `refresh=1` 重新查询。公开接口按 PHP 的 `REMOTE_ADDR` 限制每分钟和每日次数。代理部署时，在 Web 服务器上配置可信代理的真实客户端 IP。超过额度返回 HTTP 429 和 `Retry-After`，每日额度按北京时间零点重置。

| 接口 | 单 IP 每分钟 | 单 IP 每日 | 全站每日 |
| --- | ---: | ---: | ---: |
| 自动封面 | 40 | 800 | — |
| 封面候选及预览 | 120 | 1200 | — |
| 读取歌词与封面选择 | 60 | 1200 | — |
| 提交选择 | 8 | 60 | 600 |
| 歌词翻译 | 30 | 240 | — |
| OpenRouter 封面搜索调用 | 3 | 12 | 100 |
| OpenRouter 歌词翻译调用 | 15 | 100 | 200 |

在服务端的 `api_rate_limits` 配置中可覆盖默认值，键名见 `src/ApiRateLimiter.php`。翻译仍另外按每设备和每 IP 各 5 首新歌计算，已有译文只消耗普通接口的请求额度。

## 接入 Flutter 播放器

播放器默认访问 `https://mp3.whzxc.com/`。使用自建服务时，在构建时传入地址：

```bash
flutter build apk --release \
  --dart-define=COVER_PROXY_URL=https://你的域名/cover_api/ \
  --dart-define=LYRIC_TRANSLATION_API_URL=https://你的域名/cover_api/lyrics.php
```

播放器优先调用封面中转服务，失败时尝试客户端的公开曲库。


## 英文歌词翻译

把更新后的 `lyrics.php` 和 `src/LyricTranslationService.php` 一并上传。播放器检测到纯英文歌词后，会向以下接口提交逐行歌词：

```text
POST https://你的域名/lyrics.php
Content-Type: application/json
```

服务端使用 OpenRouter，默认翻译模型为 `~openai/gpt-sol-latest`，跟随 Sol 系列最新模型。可在 `config.php` 中指定模型，部署时保留现有服务器配置；播放器隐藏服务地址设置。

新译文按歌曲信息与请求内歌词上下文理解隐喻、情绪和人称，避免生硬逐字翻译。默认 `translation_reference_search: true`：首次需要新译文时，在同一次模型请求中用 OpenRouter `web` 插件（Exa，最多 3 个结果）参考该歌曲已有的中英对照译文；只有原文明确对应才参考，没有可靠结果时由模型忠实翻译，不把记忆当作检索来源。仍要求每个原文标识恰好返回一次，不合并、错位或加入原文没有的意象。

参考搜索额外收费，记录在 `cache/lyrics_references_v1/`；按模型、歌曲名和歌手共享缓存 7 天，后续批次/设备复用，空结果和失败也缓存以限制重复搜索。只从提供商的 HTTPS 引用注解保存参考摘录，模型自行输出的网址不作为证据。搜索插件不可用时自动重试普通语境翻译；配置设为 `false` 可以关闭搜索。每日设备/IP 限额在任何收费请求前检查，已有逐行译文命中不搜索、不调用模型。旧译文保留，提示词升级不会自动删除缓存或重翻。需部署更新的 `nginx-downloads.conf` 阻止直接访问参考缓存目录。

新版接口返回 `schema_version: 3` 和 `lines` 数组，每项包含原文 SHA-256 `id`、`source`、`translation`。客户端依据原文标识配对，不依赖数组顺序。为兼容旧客户端，仍返回按请求顺序排列的 `translations` 数组。

服务端在 `cache/lyrics_lines_v3/` **按模型、目标语言、规范化原文行**缓存，不绑定歌曲名、歌手或时间戳。只把缓存缺失的行小批量提交给模型，重复副歌只翻译一次。每行有独立缓存锁，多个请求按固定顺序获取锁。旧版整首缓存不被复用。

客户端将原 LRC 和 `.lrc.translations.json` 行缓存分开保存，更换歌词、微调时间后重新配对。已经有译文的行不重翻；部分请求失败仍显示已有译文。在“选择歌词”窗口可点击“重试翻译”，仅补缺失的行。歌词、逐行译文与封面都属于歌曲缓存，删除缓存会一并删除。

## 手动选择封面

新接口按来源单独查询，不把多个来源混在一个请求中：

```text
GET /covers.php?title=歌曲名&artist=歌手&source=itunes
GET /covers.php?title=歌曲名&artist=歌手&source=lastfm
GET /covers.php?title=歌曲名&artist=歌手&source=deezer
GET /covers.php?title=歌曲名&artist=歌手&source=musicbrainz
GET /covers.php?title=歌曲名&artist=歌手&source=community&duration=200&device_id=设备识别码
```

响应 `candidates` 包含 `id`、`source`、`title`、`artist`、`album`、匹配评分。每个来源独立缓存七天，`refresh=1` 强制重新查询。来源搜索独立并行查询多个歌手变体，客户端不承担搜索计算。

选择后的图片通过本站代理，`id` 必须来自对应歌曲和来源的候选列表：

```text
GET /covers.php?title=歌曲名&artist=歌手&source=itunes&action=image&id=候选标识
```

追加 `preview=1` 使用小缩略图。播放器只加载可见候选的预览，选定后才下载完整封面。播放工具栏“选择封面”或**长按圆盘**可打开选择窗口，保存后离线可用，旧自动查询不会覆盖手动选择。

“其他用户选择”（`source=community`）直接读取服务端已保存的图片，不请求外部封面源。同一图片按内容去重，最多返回 24 项；请求设备自身不计入人数。候选 `id` 为图片内容的 SHA-256，图片请求同样携带 `duration` 和 `device_id`，避免不同录音版本混用。返回 `votes`、`origin_source`，不返回设备标识或缓存文件路径。没有设备统计的旧共享封面标为“历史共享选择”。有 GD 时为可见项按需生成并缓存 256 像素缩略图（过大的图或无 GD 时保留原图）。打开来源只读取统计，不会增加选择人数；手动选定后按现有流程保存个人选择并计票。

新版使用 `POST /covers.php` 查询其他用户的封面，JSON 字段为 `source: community`、`title`、`artist`、`duration`、`device_id`、可选 `lyrics`（当前缓存的原始歌词，最大 256KB，不能使用客户端叠加 AI 译文后的显示文本）。歌词放在请求体。普通播放的默认封面恢复逻辑保持不变，扩展匹配只用于手动选择列表。

返回顺序为：歌名、歌手和歌词精确匹配 → 歌名歌手精确匹配 → 歌词精确但歌曲信息有差异 → 模糊匹配。同一等级按其他设备最后选择的人数排序，票数不能让模糊结果超过精确结果；相同图片跨歌曲出现时保留最强匹配，不累加跨歌曲票数。歌名和歌手统一简繁、大小写、标点、双歌手顺序。歌词忽略时间与 LRC 元数据标签，使用正文指纹及最多 256 个不同歌词行的指纹比较；常见短词或短句不会作为跨歌曲识别依据。歌曲信息一致但歌词明显不同会降为需核对的模糊结果。不同录音时长、现场/伴奏/混音/不插电版本不混用。

每项返回 `match_type`、`match_label` 和图片原记录的 `lookup_title`、`lookup_artist`、`lookup_duration`。预览与原图下载必须使用这些 lookup 参数，而保存个人选择仍使用正在播放歌曲的信息。旧客户端继续用 GET，仅返回原来的同歌名歌手结果；新版客户端连接尚未更新的服务器，POST 收到 405 后自动回退 GET。

首次手动查询会建立 `cache/song_selections_v1/cover-search-v1.json`，迁移已有个人和匿名记录。后续查询只读索引，选择提交后仅重算对应歌曲；索引不保存歌词正文或设备标识。不会在播放切歌时扫描全库，也不产生外部 API/AI 费用。部署更新时不要删除已有选择缓存。

自动 iTunes 封面也使用候选缓存，只接受歌名与歌手均匹配的结果；不同歌手的同名曲可供手选，但不会自动选用。新自动缓存采用 v3 标识，避免复用服务端旧的错误封面。

## 保存与复用手动选择

部署 `selections.php`、`src/SongSelectionService.php` 以及更新的 `index.php`、`src/CoverService.php`。

`GET /selections.php?title=歌曲名&artist=歌手&duration=秒数` 返回 `selection`，未命中为 `null`。`selection.lyrics` 保存完整歌词正文、候选标识和内容版本；`selection.cover` 保存所选图片元数据和内容版本。读取图片使用同一参数加 `action=image&revision=封面内容版本`。

`POST /selections.php` 提交 JSON：`title`、`artist`、`duration`、`kind`（`lyrics` 或 `cover`）、`choice`。歌词正文使用 `choice.text`；封面使用 `choice.image_base64` 和候选信息。服务端验证图片格式，保存独立副本，候选列表过期不会影响已选封面。自动封面接口也优先返回手动选择。

播放器启动时读取一次 `ANDROID_ID`，用固定应用前缀生成 SHA-256 `device_id`。读取、提交、所选图片和普通封面接口都携带相同的 `device_id`（64 位小写十六进制）。服务端按设备和歌曲保存最后选择。每种资源分别按“本设备选择 → 选择人数最多的公共结果 → 早期未分设备的默认记录”恢复。提交需要设备码，无设备码的请求仍可读取公共结果。

同一设备对同一歌曲、同一种资源只有一票，改选时自动撤销原票，重复提交和普通播放不会加票。同票保持现有默认稳定，歌词与封面分别统计。公共结果带 `selection_scope: community` 和 `votes`，正文与图片都直接使用服务器已保存的副本，不再请求上游。首次访问某首歌曲会自动迁移历史设备选择；后续只读取 `community-*.defaults.json` 小索引，手动选择时才更新统计，不在每次播放时扫描所有设备。整个 `cache/song_selections_v1/` 必须禁止网站直接访问（部署 `nginx-downloads.conf` 并重载 Nginx），资源通过限流的接口读取。

同一设备、安卓用户和 APK 签名下卸载重装后可恢复，无需注册或 Google 服务。恢复出厂设置、更换用户或签名可能改变标识。标识异常时只保存本地选择，不回退成公共写入。公开接口通过设备码区分偏好。设备码由客户端提供，可被知道该值的调用方复用。自动候选、图片内容副本和逐行翻译缓存仍可共享，避免重复请求及存储。

选择永久保存在 `cache/song_selections_v1/`，不参与候选的七天过期。歌曲名与歌手统一大小写、空白、简繁和双歌手顺序；保留版本词，并允许时长三秒以内的差异。多个录音版本且请求无时长时不自动猜测。歌词和封面分开更新，以文件锁和原子写入保证互不覆盖。

客户端先使用本地缓存，在后台读取服务端的选择，未命中才走原来的搜索。相同内容版本不会重新下载或重置歌词微调。手动选择自动写入持久待同步记录，封面在独立目录保留图片快照；网络失败在启动或后续播放时重试。仅用户手动选择时提交，普通播放及读取旧缓存不会反向上传覆盖服务端。每次播放在后台查询服务端最后一次成功提交的选择，不缓存查询结果；换设备或重装后根据相同歌曲元数据恢复。删除本地歌曲缓存不会删除服务端选择。

## 验证

```bash
php tests/regression.php
php tests/selection_popularity.php
php tests/community_covers.php
php tests/community_cover_matching.php
php tests/community_cover_matching_http.php
php tests/api_rate_limit_regression.php
php tests/translation_reference.php
```

测试使用模拟翻译和模拟曲库，无需 API Key，也不会产生 OpenRouter 费用。

封面匹配使用 OpenCC 字符表统一简繁体，不修改返回的标题；字符表和 Apache-2.0 许可在 `data/`，部署时需要一起上传。iTunes 四个地区的请求在服务端并行，客户端只发起一次来源查询。

如果 OpenRouter 返回模型地区限制，可在 `config.php` 配置 `openrouter_chat_url`（兼容 OpenRouter 的完整 chat/completions 地址）或 `openrouter_proxy`（HTTP/SOCKS 代理地址）。默认仍直连 OpenRouter，不自动更换指定模型。

当前生产服务使用 **lsai** 的 `/www/wwwroot/cover_api.whzxc.com`。该服务器的 OpenRouter 请求通过本机 HTTP 代理：

```php
'openrouter_proxy' => 'http://127.0.0.1:10809',
'openrouter_translation_model' => '~openai/gpt-sol-latest',
```

也支持 `socks5h://127.0.0.1:10808`，其中 `socks5h` 让代理端解析目标域名。OpenRouter 歌词翻译和 AI 封面搜索使用该代理；Deezer、MusicBrainz、Cover Art Archive / archive.org 的请求和图片也复用代理，iTunes 保持直连。可用 `cover_proxy` 单独覆盖封面代理（空字符串表示封面直连）。配置的代理故障会返回上游请求失败，不自动回退到受地区限制的直连出口。

客户端候选预览通过同一个 Dio 客户端读取二进制图片，再用 `Image.memory` 显示；预览最多三个并发，内存最多缓存 2MB / 16 张，关闭窗口取消请求。失败时显示重试按钮，并记录来源、候选标识和具体原因。

## 应用升级

部署 `updates.php` 和 `tools/publish_update.php`。`GET /updates.php` 返回最新发布版本，尚未发布时 `release` 为 `null`。升级信息与 APK 无需歌曲接口令牌；发布操作只通过 SSH，`tools/publish_update.php` 拒绝 HTTP 调用。

`pubspec.yaml` 的 `+` 后使用“年月日＋当天发布次数”，例如 `1.0.12+2026101202` 表示 2026 年 10 月 12 日的第 2 次发布。日期按北京时间（Asia/Shanghai），末尾两位从 `01` 开始，同日后续为 `02`、`03`；第二天重新从 `01` 开始。次数按正式发布计，同一待发布版本多次修改、重打包、失败重试以及生成不同架构包都不重复计数。发布前确认日期、发布记录和版本码递增；通用与架构包版本码保持完全一致。发布脚本会核对 APK 与当前 pubspec.yaml 是否一致，避免更新版本后误上传旧包。

修改代码后只更新本地版本，不自动上传或部署；用户明确要求发布时，才运行 `build_apk.bat` 并在项目目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\publish_update.ps1 -Notes "本次更新说明"
# 或从 UTF-8 文本文件读取较长的更新说明
powershell -ExecutionPolicy Bypass -File .\publish_update.ps1 -NotesFile .\release-notes.txt
```

脚本默认上传 `build/app/outputs/flutter-apk/app-release.apk` 到 SSH 配置中的 `lsai`，网站目录为 `/www/wwwroot/cover_api.whzxc.com`。也可用 `-ApkPath` 指定通用包。脚本核对包名、APK 签名和现有 `android/signing/player.keystore`；服务器核对文件大小和 SHA-256，拒绝相同/较低版本与单架构包。保留按版本命名的旧 APK，最后才原子替换 `updates/latest.json`，上传中断不影响已发布版本。失败的 `.incoming-*.apk` 可以手动清理。

客户端启动 20 秒后异步检查，不阻塞播放。设置底部也有“检查更新”，手动检查可再次提示被暂时忽略的版本。用户确认后才下载；下载可取消，采用流式 SHA-256 校验，再核对 APK 包名、递增版本、签名。Android 8+ 首次需要允许播放器安装应用；返回后自动继续打开系统安装界面，仍需点击系统的安装确认。覆盖安装保留播放器设置和缓存，不需要卸载。取消授权或安装后可点击“继续安装已下载的更新”。下载文件存放在应用私有缓存，系统可能回收，丢失时重新下载即可。

部分车机的系统设置经过修改，安装授权页可能无法按标准地址打开。客户端依次尝试应用专用授权页、未知来源列表、安全设置、应用详情和系统设置；备用页面需要手动找到“安装未知应用”，选择“车机NAS播放器”并允许。系统安装先尝试 APK 查看入口，再尝试安装包入口，并通过 FileProvider 和 ClipData 提供只读权限。入口失败显示中文说明，不在界面显示 Java 异常代码；应用日志记录失败阶段，Android 的 `NasPlayerUpdate` 日志记录具体入口与异常。备用入口不会跳过系统授权或安装确认，也不能绕过车机厂商的安装限制。

如果车机无法授权应用内安装，可在下载完成、安装失败或播放器设置中选择“保存到下载文件夹”。播放器复用已下载的 APK，核对包名、版本和签名后导出。Android 10 及以上优先直接写入公共下载目录，Android 9 使用系统另存为界面并建议下载目录。保存后在车机文件管理器中打开 APK，按系统提示确认覆盖安装。部分车机可能要求给文件管理器授予安装权限；没有系统另存为界面时，可以从下载站手动下载。

发布 APK 必须保留当前包名和签名。签名私钥无需购买，但请备份 `android/signing/player.keystore`；丢失或改换签名无法覆盖安装，也可能改变设备偏好识别码。新客户端升级功能需要先手动安装一次，此后可在应用里升级。


## 下载站点与多架构发布

公网地址为 `https://mp3.whzxc.com/`，物理目录仍为 `/www/wwwroot/cover_api.whzxc.com`。
根地址展示下载页面，有 `title` 参数的请求仍走原有封面 API。客户端的封面、选择同步、翻译、升级默认全部使用新域名；旧版已保存的翻译地址会自动迁移。

运行 `build_apk.bat` 生成通用与三个分架构包后：

```powershell
.\publish_update.ps1 -IncludeSplitApks -Notes '更新内容'
```

发布前验证全部安装包的包名、版本和签名。服务器验证全部文件的 SHA-256 和架构后，才更新最新版本信息。下载页面优先使用浏览器提供的架构信息，无法确认时推荐通用包；点击安装包链接才开始下载，也可以手动选择架构或历史版本。应用内升级优先选择与设备兼容的架构小包，找不到时使用通用包。

Gradle 会将通用与分架构包的版本码统一，避免 Flutter 默认的架构偏移导致通用升级包被识别为旧版本。现在沿用这一机制，版本码改为 `yyyyMMddNN`；旧版的 `7014` 等版本码继续保留在已发布 APK 和历史记录中，新版本可直接覆盖升级。

## 翻译日限额

默认每个客户端和每个来源 IP 每天各允许翻译 5 首不同歌曲（任一限额用完则拒绝新的歌曲），按北京时间零点重置。设备标识沿用客户端 ANDROID_ID 的应用专用 SHA-256；旧客户端没有设备标识时仍受 IP 限制。来源地址使用 PHP 的 REMOTE_ADDR，不信任客户端传入的 X-Forwarded-For。

只有逐行缓存缺失、需要调用 OpenRouter 时才计数，已有缓存不限。歌曲按规范化歌名与歌手识别，分批、重播、切换歌词不重复计算歌曲数；每首每天最多 250 个不同待翻译行、75000 字节，每个未缓存行最多尝试三次，防止用同一歌名无限提交文本。请求模型之前原子预约额度，失败也保留预约。超限返回 HTTP 429 和 Retry-After，客户端保留原文与已有译文并提示。

`config.php` 可选设置 `translation_daily_song_limit`，默认 5。计数保存在 `cache/translation_quota/`，Nginx 应禁止直接访问该目录及 `updates/` 下的点文件。部署时不要覆盖已有 config.php 或清空缓存。

回归验证：`php tests/quota_regression.php`、`php tests/update_regression.php`、`php tests/regression.php`。
