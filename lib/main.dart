import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:media_kit/media_kit.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audio_service/audio_service.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

const String appBuildTime = String.fromEnvironment('BUILD_TIME', defaultValue: '终极后台保活版');
const String appAuthor = "NAS Car Player";

late Player globalPlayer;
late MediaKitAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    MediaKit.ensureInitialized();
    globalPlayer = Player();

    audioHandler = await AudioService.init(
      builder: () => MediaKitAudioHandler(globalPlayer),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.nascarplayer.channel.audio',
        androidNotificationChannelName: 'NAS Car Player',
        androidNotificationOngoing: true,
        androidShowNotificationBadge: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
        androidResumeOnClick: true,
      ),
    ) as MediaKitAudioHandler;

    runApp(const NasCarPlayerApp());
  } catch (e, stackTrace) {
    runApp(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black87,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(40),
          child: Text(
              "引擎启动崩溃了，请拍照报错信息:\n\n$e\n\n$stackTrace",
              style: const TextStyle(color: Colors.redAccent, fontSize: 20, height: 1.5)
          ),
        ),
      ),
    ));
  }
}

class NasCarPlayerApp extends StatelessWidget {
  const NasCarPlayerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NAS Car Player', debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(primaryColor: const Color(0xFF1ED760)),
      home: const MainHomeScreen(),
    );
  }
}

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});
  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _hasOverlayPermission = false;
  int currentLeftScreen = 0;
  bool isLoading = false;
  List<String> realNasSongs = [];
  Set<String> _cachedFiles = {};
  String? _slidingSongName; // 当前正在滑动的歌曲名称

  String currentPlayingSong = "等待播放", currentArtist = "私人乐库", _currentFileName = "";
  bool isPlaying = false;
  int _loopMode = 0;
  List<String> _shuffledPlaylist = []; // 随机播放列表
  int _currentIndexInShuffled = -1; // 当前在随机列表中的位置

  String defaultCoverUrl = "https://images.unsplash.com/photo-1493225457124-a1a2a5ea3eb8?q=80&w=600&auto=format&fit=crop";
  late String currentCoverUrl;

  String _currentTimeString = "12:00";
  Duration _currentPosition = Duration.zero, _totalDuration = Duration.zero;
  Timer? _clockTimer, _screenSaverTimer, _playbackSaveTimer;
  bool _isLargeMode = false;

  List<Map<String, dynamic>> parsedLyrics = [];
  int _currentLyricIndex = 0;
  List<GlobalKey> _lyricKeys = [], _miniLyricKeys = [];

  final ScrollController _lyricScrollController = ScrollController();
  final ScrollController _miniLyricScrollController = ScrollController();
  final ScrollController _playlistScrollController = ScrollController();

  late AnimationController _spinController;
  Color _lyricHighlightColor = const Color(0xFF1ED760), _bottomGlowColor = const Color(0xFFE2EFE9);

  late SharedPreferences _prefs;
  List<Map<String, dynamic>> webdavAccounts = [];
  Map<String, dynamic>? activeAccount;
  Map<String, dynamic>? playingAccount;

  double _uiScale = 1.3, _btnScale = 1.0, _lyricOffset = 0.0;
  static const platform = MethodChannel('com.nascarplayer/app_retain');
  static const mediaChannel = MethodChannel('com.nascarplayer/media_control');
  double s(double value) => value * _uiScale;

  double _lyricFontSize = 50.0, _maxCacheGB = 2.0;
  int _screenSaverTimeout = 8, _bootDelay = 5;
  bool _autoPlay = false, _showStatusBar = false, _startOnBoot = false, _startOtherAppOnBoot = false;
  String _bootOtherAppPackage = '', _bootOtherAppLabel = '';
  int _bootOtherAppDelay = 10;

  DateTime _lastEventTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkOverlayPermission();
    currentCoverUrl = defaultCoverUrl;
    _initClock(); _initPrefsAndState();

    _spinController = AnimationController(vsync: this, duration: const Duration(seconds: 10))..repeat();
    _spinController.stop();

    // 设置audioHandler的回调，用于处理MediaSession的切歌事件
    audioHandler.onNextCallback = () {
      if (_checkDebounce()) return;
      _playNextSong(manual: true);
      _resetScreenSaverTimer();
    };
    audioHandler.onPrevCallback = () {
      if (_checkDebounce()) return;
      _playPrevSong();
      _resetScreenSaverTimer();
    };

    globalPlayer.stream.playing.listen((p) {
      if (mounted) {
        setState(() => isPlaying = p);
        if (p) _spinController.repeat(); else _spinController.stop();
      }
    });

    globalPlayer.stream.position.listen((pos) { if (mounted) { setState(() => _currentPosition = pos); _updateLyricScroll(pos); } });
    globalPlayer.stream.duration.listen((dur) {
      if (mounted) setState(() => _totalDuration = dur);
      audioHandler.updateDuration(dur);
    });
    globalPlayer.stream.completed.listen((c) { if (c) _playNextSong(manual: false); });

    // 方案 A: 全局硬件键盘监听（拦截方向盘 KeyEvent）
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);

    // 方案 C: 监听原生 Android MethodChannel 转发的媒体按键
    mediaChannel.setMethodCallHandler((call) async {
      if (call.method == 'onMediaButton') {
        String key = call.arguments;
        if (key == 'NEXT' || key == 'PLAY_PAUSE' || key == 'PLAY') {
          if (key == 'NEXT') {
            if (_checkDebounce()) return;
            _playNextSong(manual: true);
            _resetScreenSaverTimer();
          } else {
            _togglePlayPause();
          }
        } else if (key == 'PREVIOUS') {
          if (_checkDebounce()) return;
          _playPrevSong();
          _resetScreenSaverTimer();
        } else if (key == 'PAUSE') {
          if (isPlaying) globalPlayer.pause();
        }
      }
    });
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.mediaTrackNext) {
        if (_checkDebounce()) return true;
        _playNextSong(manual: true);
        _resetScreenSaverTimer();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious) {
        if (_checkDebounce()) return true;
        _playPrevSong();
        _resetScreenSaverTimer();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
        _togglePlayPause();
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _playbackSaveTimer?.cancel();
    _lyricScrollController.dispose(); _miniLyricScrollController.dispose(); _playlistScrollController.dispose();
    _spinController.dispose(); super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkOverlayPermission();
    }
  }

  Future<void> _checkOverlayPermission() async {
    try {
      final bool result = await platform.invokeMethod('checkOverlayPermission');
      if (mounted) setState(() => _hasOverlayPermission = result);
    } catch (_) {}
  }

  bool _checkDebounce() {
    final now = DateTime.now();
    if (now.difference(_lastEventTime).inMilliseconds < 400) return true;
    _lastEventTime = now;
    return false;
  }

  void _togglePlayPause() {
    _resetScreenSaverTimer();
    globalPlayer.playOrPause();
  }

  void _toggleLoopMode() {
    setState(() {
      _loopMode = (_loopMode + 1) % 3;
      if (_loopMode == 2) {
        _generateShuffledPlaylist();
      }
    });
    _prefs.setInt('loopMode', _loopMode);
    _resetScreenSaverTimer();
  }

  Future<void> _initPrefsAndState() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _uiScale = _prefs.getDouble('uiScale') ?? 1.5;
      _btnScale = _prefs.getDouble('btnScale') ?? 1.0;
      _lyricFontSize = _prefs.getDouble('lyricFontSize') ?? 50.0;
      _screenSaverTimeout = _prefs.getInt('screenSaverTimeout') ?? 8;
      _autoPlay = _prefs.getBool('autoPlay') ?? false;
      _showStatusBar = _prefs.getBool('showStatusBar') ?? false;
      _maxCacheGB = _prefs.getDouble('maxCacheGB') ?? 2.0;
      _startOnBoot = _prefs.getBool('startOnBoot') ?? false;
      _startOtherAppOnBoot = _prefs.getBool('startOtherAppOnBoot') ?? false;
      _bootOtherAppPackage = _prefs.getString('bootOtherAppPackage') ?? '';
      _bootOtherAppLabel = _prefs.getString('bootOtherAppLabel') ?? '';
      _bootOtherAppDelay = _prefs.getInt('bootOtherAppDelay') ?? 10;
      _bootDelay = _prefs.getInt('bootDelay') ?? 5;
      _loopMode = _prefs.getInt('loopMode') ?? 0;

      String? accJson = _prefs.getString('webdavAccounts');
      if (accJson != null) webdavAccounts = jsonDecode(accJson).cast<Map<String, dynamic>>();
    });

    _applyStatusBar(); _updateCachedFilesList();

    _playbackSaveTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (isPlaying && _currentFileName.isNotEmpty) {
        _prefs.setString('lastFileName', _currentFileName); _prefs.setInt('lastPosition', _currentPosition.inMilliseconds);
        if (activeAccount != null) _prefs.setString('lastAccount', jsonEncode(activeAccount));
      }
    });

    if (_autoPlay) {
      String? lfn = _prefs.getString('lastFileName'), lacc = _prefs.getString('lastAccount');
      int lpos = _prefs.getInt('lastPosition') ?? 0;
      if (lfn != null && lacc != null) {
        activeAccount = jsonDecode(lacc); await fetchSongsFromWebDav(silent: true);
        if (realNasSongs.contains(lfn)) { await playNasSong(lfn); globalPlayer.seek(Duration(milliseconds: lpos)); }
      }
    }

    bool isFirstLaunch = _prefs.getBool('isFirstLaunch') ?? true;
    if (isFirstLaunch) WidgetsBinding.instance.addPostFrameCallback((_) { _showFirstLaunchSetupDialog(); });

    if (_startOtherAppOnBoot && _bootOtherAppPackage.isNotEmpty) {
      Future.delayed(Duration(seconds: _bootOtherAppDelay), () {
        _launchAppByPackage(_bootOtherAppPackage);
      });
    }
  }

  Future<void> _launchAppByPackage(String packageName) async {
    try { await platform.invokeMethod('launchAppByPackage', {'packageName': packageName}); } catch (_) {}
  }

  Future<void> _showAppPickerDialog() async {
    List<Map<String, dynamic>> apps = [];
    try {
      final List<dynamic> result = await platform.invokeMethod('listInstalledApps');
      apps = result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {}
    if (!mounted || apps.isEmpty) return;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.95), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(s(24))),
          title: Text('\u9009\u62e9\u8981\u542f\u52a8\u7684\u5e94\u7528', style: TextStyle(fontSize: s(26), fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite, height: MediaQuery.of(context).size.height * 0.6,
            child: ListView.builder(
              shrinkWrap: true, itemCount: apps.length,
              itemBuilder: (context, index) {
                final app = apps[index]; final bool isSelected = app['packageName'] == _bootOtherAppPackage;
                return ListTile(
                  leading: Icon(Icons.android, color: isSelected ? Colors.blueAccent : Colors.black54, size: s(36)),
                  title: Text(app['label'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))),
                  subtitle: Text(app['packageName'], style: TextStyle(fontSize: s(18))),
                  selected: isSelected, selectedTileColor: Colors.blueAccent.withOpacity(0.1),
                  trailing: isSelected ? Icon(Icons.check_circle, color: Colors.blueAccent, size: s(32)) : null,
                  onTap: () {
                    setState(() { _bootOtherAppPackage = app['packageName']; _bootOtherAppLabel = app['label']; });
                    _prefs.setString('bootOtherAppPackage', _bootOtherAppPackage);
                    _prefs.setString('bootOtherAppLabel', _bootOtherAppLabel);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() { _bootOtherAppPackage = ''; _bootOtherAppLabel = ''; });
                _prefs.setString('bootOtherAppPackage', ''); _prefs.setString('bootOtherAppLabel', '');
                Navigator.pop(context);
              },
              child: Text('\u6e05\u9664\u9009\u62e9', style: TextStyle(fontSize: s(22), color: Colors.redAccent)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: Text('\u5173\u95ed', style: TextStyle(fontSize: s(22)))),
          ],
        );
      },
    );
  }

  void _showFirstLaunchSetupDialog() {
    showDialog(context: context, barrierDismissible: false, builder: (context) { return StatefulBuilder(builder: (context, setDialogState) { return AlertDialog(backgroundColor: Colors.white.withOpacity(0.95), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), title: FittedBox(fit: BoxFit.scaleDown, child: Text("🎉 欢迎使用 NAS Car Player", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [Text("由于车机屏幕比例与分辨率差异巨大，\n请先滑动下方滑块，观察背后界面的变化\n调整到您觉得最舒服的大小：", style: TextStyle(fontSize: 18, height: 1.5, color: Colors.black87), textAlign: TextAlign.center), SizedBox(height: 30), FittedBox(fit: BoxFit.scaleDown, child: Row(children: [Text("全局缩放: ", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: Colors.black87)), SizedBox(width: 250, child: Slider(value: _uiScale, min: 0.8, max: 2.5, divisions: 17, activeColor: Colors.blueAccent, onChanged: (val) { setDialogState(() { _uiScale = val; }); setState(() { _uiScale = val; }); })), SizedBox(width: 65, child: Text("${_uiScale.toStringAsFixed(1)}x", style: TextStyle(fontSize: 20, color: Colors.black87)))]))])), actions: [Center(child: FittedBox(fit: BoxFit.scaleDown, child: ElevatedButton(style: ElevatedButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 40, vertical: 16), backgroundColor: Colors.blueAccent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: () { _prefs.setDouble('uiScale', _uiScale); _prefs.setBool('isFirstLaunch', false); Navigator.pop(context); }, child: Text("调整好了，进入车机！", style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)))))]); }); });
  }

  void _applyStatusBar() { SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: _showStatusBar ? SystemUiOverlay.values : [SystemUiOverlay.bottom]); }
  void _initClock() { _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() { _currentTimeString = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}"; }); }); }
  void _resetScreenSaverTimer() { _screenSaverTimer?.cancel(); if (currentLeftScreen != 2 || _isLargeMode || _screenSaverTimeout == 0) return; _screenSaverTimer = Timer(Duration(seconds: _screenSaverTimeout), () { if (mounted && currentLeftScreen == 2) setState(() => _isLargeMode = true); }); }

  Future<void> _updateCachedFilesList() async {
    try { final dir = await getApplicationDocumentsDirectory(); final cacheDir = Directory('${dir.path}/nas_cache'); if (cacheDir.existsSync() && mounted) setState(() => _cachedFiles = cacheDir.listSync().whereType<File>().map((f) => f.path.split(Platform.pathSeparator).last).toSet()); } catch (_) {}
  }

  Future<void> _deleteCacheFile(String fileName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/nas_cache');
      final file = File('${cacheDir.path}/$fileName');
      if (file.existsSync()) {
        await file.delete();
        _updateCachedFilesList();
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<String> _getPlayableUrl(String songName, String remoteUrl, String auth) async {
    try { final cacheDir = Directory('${(await getApplicationDocumentsDirectory()).path}/nas_cache'); if (!cacheDir.existsSync()) cacheDir.createSync(); final File localFile = File('${cacheDir.path}/$songName'); if (localFile.existsSync() && localFile.lengthSync() > 0) return localFile.path; _backgroundDownloadAndLimit(songName, remoteUrl, auth, cacheDir, localFile); return remoteUrl; } catch (e) { return remoteUrl; }
  }

  void _backgroundDownloadAndLimit(String songName, String remoteUrl, String auth, Directory cacheDir, File localFile) async {
    try { await Dio().download(remoteUrl, localFile.path, options: Options(headers: {'Authorization': auth})); _updateCachedFilesList(); final files = cacheDir.listSync().whereType<File>().toList(); double totalSize = 0; for (var f in files) totalSize += f.lengthSync(); double limitBytes = _maxCacheGB * 1024 * 1024 * 1024; if (totalSize > limitBytes) { files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync())); for (var f in files) { if (totalSize <= limitBytes) break; totalSize -= f.lengthSync(); f.deleteSync(); } _updateCachedFilesList(); } } catch (_) {}
  }

  void _generateShuffledPlaylist() {
    _shuffledPlaylist = List.from(realNasSongs);
    _shuffledPlaylist.shuffle();
    _currentIndexInShuffled = -1;
  }

  void _playNextSong({bool manual = false}) {
    if (realNasSongs.isEmpty) return;
    
    if (_loopMode == 2) {
      // 随机播放模式
      if (_shuffledPlaylist.isEmpty || _shuffledPlaylist.length != realNasSongs.length) {
        _generateShuffledPlaylist();
      }
      _currentIndexInShuffled = (_currentIndexInShuffled + 1) % _shuffledPlaylist.length;
      playNasSong(_shuffledPlaylist[_currentIndexInShuffled]);
    } else {
      // 顺序播放或单曲循环模式
      int idx = realNasSongs.indexOf(_currentFileName);
      if (idx == -1) idx = 0;
      int next = (_loopMode == 1 && !manual) ? idx : (idx + 1) % realNasSongs.length;
      playNasSong(realNasSongs[next]);
    }
  }

  void _playPrevSong() {
    if (realNasSongs.isEmpty) return;
    
    if (_loopMode == 2) {
      // 随机播放模式
      if (_shuffledPlaylist.isEmpty || _shuffledPlaylist.length != realNasSongs.length) {
        _generateShuffledPlaylist();
      }
      _currentIndexInShuffled = (_currentIndexInShuffled - 1 + _shuffledPlaylist.length) % _shuffledPlaylist.length;
      playNasSong(_shuffledPlaylist[_currentIndexInShuffled]);
    } else {
      // 顺序播放或单曲循环模式
      int idx = realNasSongs.indexOf(_currentFileName);
      int prev = idx == -1 ? 0 : (idx - 1 + realNasSongs.length) % realNasSongs.length;
      playNasSong(realNasSongs[prev]);
    }
  }

  void _scrollToCurrentSong() {
    if (realNasSongs.isEmpty || _currentFileName.isEmpty) return; int index = realNasSongs.indexOf(_currentFileName);
    if (index != -1) { WidgetsBinding.instance.addPostFrameCallback((_) { if (_playlistScrollController.hasClients) { double itemHeight = s(114.0); double viewportHeight = _playlistScrollController.position.viewportDimension; double targetOffset = (index * itemHeight) - (viewportHeight / 2) + (itemHeight / 2); _playlistScrollController.animateTo(targetOffset.clamp(0.0, _playlistScrollController.position.maxScrollExtent), duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic); } }); }
  }

  Future<void> _updatePalette(String imageUrl) async {
    try { final palette = await PaletteGenerator.fromImageProvider(NetworkImage(imageUrl), maximumColorCount: 20); Color? targetColor = palette.vibrantColor?.color ?? palette.dominantColor?.color; if (targetColor != null) { HSLColor hsl = HSLColor.fromColor(targetColor); bool isDullOrGrey = hsl.saturation < 0.3 || hsl.lightness < 0.15 || hsl.lightness > 0.85; if (isDullOrGrey) { _lyricHighlightColor = const Color(0xFF1ED760); _bottomGlowColor = const Color(0xFF1ED760).withOpacity(0.15); } else { _lyricHighlightColor = hsl.withLightness((hsl.lightness - 0.25).clamp(0.0, 1.0)).toColor(); _bottomGlowColor = targetColor.withOpacity(0.25); } } else { _lyricHighlightColor = const Color(0xFF1ED760); _bottomGlowColor = const Color(0xFF1ED760).withOpacity(0.15); } if (mounted) setState(() {}); } catch (_) { if (mounted) setState(() { _lyricHighlightColor = const Color(0xFF1ED760); _bottomGlowColor = const Color(0xFF1ED760).withOpacity(0.15); }); }
  }

  void _parseRawLrcText(String text) {
    parsedLyrics.clear(); _currentLyricIndex = 0; String cleanText = text.replaceAll(r'\n', '\n'); RegExp timeTagRegExp = RegExp(r'\[(\d{2,}):(\d{2})(?:[:.](\d+))?');
    for (var line in cleanText.split('\n')) { var match = timeTagRegExp.firstMatch(line); if (match != null) { int min = int.parse(match.group(1)!), sec = int.parse(match.group(2)!); int ms = match.group(3) != null ? int.parse(match.group(3)!.padRight(3, '0').substring(0, 3)) : 0; String pureLyric = line.replaceAll(RegExp(r'\[.*?\]|<.*?>'), '').trim(); if (pureLyric.isNotEmpty) parsedLyrics.add({'time': Duration(minutes: min, seconds: sec, milliseconds: ms), 'text': pureLyric}); } }
    if (parsedLyrics.isEmpty) parsedLyrics.add({'time': Duration.zero, 'text': '纯音乐 / 暂无滚动歌词'}); else parsedLyrics.sort((a, b) => a['time'].compareTo(b['time']));
    _lyricKeys = List.generate(parsedLyrics.length, (i) => GlobalKey()); _miniLyricKeys = List.generate(parsedLyrics.length, (i) => GlobalKey());
    if (_lyricScrollController.hasClients) _lyricScrollController.jumpTo(0); if (_miniLyricScrollController.hasClients) _miniLyricScrollController.jumpTo(0);
  }

  void _updateLyricScroll(Duration currentPos) {
    if (parsedLyrics.isEmpty) return; Duration adjustedPos = Duration(milliseconds: currentPos.inMilliseconds + (_lyricOffset * 1000).toInt()); int newIndex = 0;
    for (int i = 0; i < parsedLyrics.length; i++) { if (adjustedPos >= parsedLyrics[i]['time']) newIndex = i; else break; }
    if (newIndex != _currentLyricIndex) {
      setState(() => _currentLyricIndex = newIndex);
      void animateToKey(GlobalKey key, ScrollController ctrl, double estLineHeight, double align) { if (key.currentContext != null) { Scrollable.ensureVisible(key.currentContext!, alignment: align, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic); } else { if (ctrl.hasClients) { ctrl.jumpTo((newIndex * estLineHeight).clamp(0.0, ctrl.position.maxScrollExtent)); } WidgetsBinding.instance.addPostFrameCallback((_) { if (key.currentContext != null) { Scrollable.ensureVisible(key.currentContext!, alignment: align, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic); } }); } }
      double largeEstHeight = _lyricFontSize * 1.5 + s(36.0); double miniEstHeight = s(22.0) * 1.5 + s(18.0);
      if (_lyricKeys.isNotEmpty && newIndex < _lyricKeys.length) animateToKey(_lyricKeys[newIndex], _lyricScrollController, largeEstHeight, _isLargeMode ? 0.25 : 0.5);
      if (_miniLyricKeys.isNotEmpty && newIndex < _miniLyricKeys.length) animateToKey(_miniLyricKeys[newIndex], _miniLyricScrollController, miniEstHeight, 0.5);
    }
  }

  Future<String?> _fetchApiLrc(Dio dio, String title, String artist) async { try { var res = await dio.get("https://tools.rangotec.com/api/anon/lrc", queryParameters: {"title": title, "artist": artist, "od": "asc"}); var data = res.data is String ? jsonDecode(res.data) : res.data; if (data['code'] == 200 && data['data'] != null && data['data'].isNotEmpty) return data['data'][0]['lrc']; } catch (_) {} return null; }
  Future<String?> _fetchApiCover(Dio dio, String title, String artist) async { try { var res = await dio.get("https://itunes.apple.com/search", queryParameters: {"term": "$artist $title".trim(), "limit": 1, "entity": "song", "country": "cn"}); var data = res.data is String ? jsonDecode(res.data) : res.data; if (data['resultCount'] > 0) return data['results'][0]['artworkUrl100'].replaceAll('100x100bb.jpg', '600x600bb.jpg'); } catch (_) {} return null; }

  Future<void> fetchLyricAndCover(String songName) async {
    if (activeAccount == null) return; String pureName = songName.replaceAll(RegExp(r'\.[^.]+$'), ''); String auth = "Basic ${base64Encode(utf8.encode("${activeAccount!['user']}:${activeAccount!['pwd']}"))}";
    String? finalLrc; bool isLocal = false;
    try { var response = await Dio().get("${activeAccount!['url']}${Uri.encodeComponent(pureName)}.lrc", options: Options(headers: {'Authorization': auth})); finalLrc = response.data.toString(); isLocal = true; } catch (_) {}
    var apiDio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 5)))..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => HttpClient()..badCertificateCallback = (c, h, p) => true);
    String cleanName = pureName.replaceAll(RegExp(r'\[.*?\]|\(.*?\)|【.*?】|（.*?）'), '').trim(); String t1 = cleanName, a1 = "", t2 = "", a2 = "";
    if (cleanName.contains('-')) { var p = cleanName.split('-'); a1 = p[0].trim(); t1 = p[1].trim(); t2 = p[0].trim(); a2 = p[1].trim(); }
    if (!isLocal) { finalLrc = await _fetchApiLrc(apiDio, t1, a1); if ((finalLrc == null || finalLrc.isEmpty) && t2.isNotEmpty) finalLrc = await _fetchApiLrc(apiDio, t2, a2); if (finalLrc == null || finalLrc.isEmpty) finalLrc = await _fetchApiLrc(apiDio, cleanName, ""); if (finalLrc != null && finalLrc.isNotEmpty) { _parseRawLrcText("[00:01.00]歌词由 千古八方API 提供\n$finalLrc"); } else { _parseRawLrcText("[00:01.00]感谢使用 \n[00:02.00]暂无本地歌词，且未匹配到网络词库"); } } else { _parseRawLrcText("[00:01.00]感谢使用 \n${finalLrc!}"); }
    String? finalCover = await _fetchApiCover(apiDio, t1, a1); if (finalCover == null && t2.isNotEmpty) finalCover = await _fetchApiCover(apiDio, t2, a2); if (finalCover == null) finalCover = await _fetchApiCover(apiDio, cleanName, "");

    setState(() { currentCoverUrl = (finalCover != null && finalCover.startsWith("http")) ? finalCover : defaultCoverUrl; });
    _updatePalette(currentCoverUrl);

    audioHandler.updateCurrentSong(currentPlayingSong, currentArtist, currentCoverUrl);
  }

  Future<void> fetchSongsFromWebDav({bool silent = false}) async {
    if (activeAccount == null) return; if (!silent) setState(() => isLoading = true); String auth = "Basic ${base64Encode(utf8.encode("${activeAccount!['user']}:${activeAccount!['pwd']}"))}";
    try { var response = await Dio().request(activeAccount!['url'], options: Options(method: 'PROPFIND', headers: {'Authorization': auth, 'Depth': '1'})); RegExp regExp = RegExp(r'<D:href>([^<]+\.(mp3|flac|wav|m4a|aac))<\/D:href>', caseSensitive: false); Iterable<Match> matches = regExp.allMatches(response.data.toString()); List<String> tempSongs = []; for (var match in matches) { String cleanName = Uri.decodeComponent(match.group(1) ?? "").split('/').last.replaceAll('&amp;', '&'); if (cleanName.isNotEmpty && !tempSongs.contains(cleanName)) tempSongs.add(cleanName); } setState(() { realNasSongs = tempSongs; isLoading = false; if (_loopMode == 2) _generateShuffledPlaylist(); }); _updateCachedFilesList(); } catch (e) { if (!silent) setState(() => isLoading = false); }
  }

  Future<void> playNasSong(String songName) async {
    if (activeAccount == null) return; playingAccount = activeAccount; String rawAuth = "Basic ${base64Encode(utf8.encode("${activeAccount!['user']}:${activeAccount!['pwd']}"))}"; String remoteUrl = "${activeAccount!['url']}${Uri.encodeFull(songName)}";
    setState(() { currentCoverUrl = defaultCoverUrl; _currentFileName = songName; }); _lyricOffset = _prefs.getDouble('lyricOffset_$songName') ?? 0.0; _parseRawLrcText("[00:00.00]正在检索本地缓存与网络词库...");

    // 💡 修复3：前置占位。在开始缓慢的网络请求前，立刻告诉系统我们正在切歌，并保持缓冲状态，防止系统认为焦点死亡
    String pure = songName.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll(RegExp(r'\[.*?\]|\(.*?\)|【.*?】|（.*?）'), '');
    if (pure.contains('-')) { var p = pure.split('-'); currentArtist = p[0].trim(); currentPlayingSong = p[1].trim(); }
    else { currentPlayingSong = pure.trim(); currentArtist = "私人乐库"; }

    audioHandler.updateCurrentSong(currentPlayingSong, currentArtist, currentCoverUrl);
    audioHandler.forceBuffering(); // 关键！强制告诉系统“我在加载”，锁死焦点

    fetchLyricAndCover(songName);

    try {
      String playPath = await _getPlayableUrl(songName, remoteUrl, rawAuth);
      await globalPlayer.open(Media(playPath, httpHeaders: playPath.startsWith('http') ? {'Authorization': rawAuth} : {}));
      setState(() {
        currentLeftScreen = 2; _isLargeMode = false;
      });

      _resetScreenSaverTimer();
    } catch (_) {}
  }

  String _printDuration(Duration d) => "${d.inMinutes.remainder(60).toString().padLeft(2, "0")}:${d.inSeconds.remainder(60).toString().padLeft(2, "0")}";

  Widget _buildScrollingLyrics(BuildContext context, {bool isMini = false}) {
    return ShaderMask(
      shaderCallback: (Rect bounds) => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent], stops: [0.0, 0.05, 0.95, 1.0]).createShader(bounds), blendMode: BlendMode.dstIn,
      child: ListView.builder(
        cacheExtent: 99999, controller: isMini ? _miniLyricScrollController : _lyricScrollController, padding: EdgeInsets.symmetric(vertical: isMini ? s(90.0) : MediaQuery.of(context).size.height / 3.5), physics: const BouncingScrollPhysics(), itemCount: parsedLyrics.length,
        itemBuilder: (context, index) {
          bool isCurrent = index == _currentLyricIndex;
          return AnimatedDefaultTextStyle(duration: const Duration(milliseconds: 300), style: TextStyle(fontSize: isCurrent ? (isMini ? s(24) : (_isLargeMode ? _lyricFontSize + s(6) : _lyricFontSize)) : (isMini ? s(20) : (_isLargeMode ? _lyricFontSize - s(8) : _lyricFontSize - s(10))), fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal, color: isCurrent ? _lyricHighlightColor : (isMini ? Colors.black45 : Colors.black87), height: 1.5), child: Container(key: isMini ? _miniLyricKeys[index] : _lyricKeys[index], padding: EdgeInsets.symmetric(vertical: isMini ? s(9.0) : s(18.0)), alignment: isMini ? Alignment.center : Alignment.centerLeft, child: Text(parsedLyrics[index]['text'])));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double sidebarWidth = (currentLeftScreen == 2 && _isLargeMode) ? 0 : s(390);
    return PopScope(
        canPop: false, onPopInvokedWithResult: (bool didPop, dynamic result) { if (didPop) return; platform.invokeMethod('sendToBackground'); },
        child: Scaffold(
            body: Stack(
              children: [
                AnimatedContainer(duration: const Duration(milliseconds: 800), decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [const Color(0xFFF2F6F9), const Color(0xFFF2F6F9), _bottomGlowColor], stops: const [0.0, 0.4, 1.0]))),
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 350), curve: Curves.easeInOut, width: sidebarWidth, decoration: BoxDecoration(color: Colors.white.withOpacity(0.35)), clipBehavior: Clip.antiAlias,
                      child: SizedBox(
                        width: s(390),
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: s(36), horizontal: s(24)),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              GestureDetector(onTap: () { setState(() { currentLeftScreen = 0; _isLargeMode = false; }); _screenSaverTimer?.cancel(); }, child: Row(children: [Icon(Icons.music_note, color: Colors.blueAccent, size: s(54)), SizedBox(width: s(12)), Text('NAS 乐库', style: TextStyle(color: Colors.black87, fontSize: s(30), fontWeight: FontWeight.bold))])),
                              Expanded(child: AnimatedAlign(duration: const Duration(milliseconds: 600), curve: Curves.easeInOut, alignment: (currentPlayingSong == "等待播放" && !isPlaying) ? Alignment.center : Alignment.topCenter, child: Column(mainAxisSize: MainAxisSize.min, children: [SizedBox(height: s(15)), RotationTransition(turns: _spinController, child: Container(width: s(160), height: s(160), decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black26, blurRadius: s(20), offset: Offset(0, s(8)))], image: DecorationImage(image: NetworkImage(currentCoverUrl), fit: BoxFit.cover)), child: Center(child: Container(width: s(40), height: s(40), decoration: BoxDecoration(color: Colors.white.withOpacity(0.8), shape: BoxShape.circle))))), SizedBox(height: s(15)), Text(currentPlayingSong, style: TextStyle(fontSize: s(30), fontWeight: FontWeight.bold, color: Colors.black87), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center), Text(currentArtist, style: TextStyle(fontSize: s(20), color: Colors.black54)), if (currentPlayingSong != "等待播放") Expanded(child: GestureDetector(onTap: () { setState(() { currentLeftScreen = 2; _isLargeMode = false; _resetScreenSaverTimer(); }); }, child: Container(margin: EdgeInsets.symmetric(vertical: s(12)), child: _buildScrollingLyrics(context, isMini: true))))]))),
                              Container(padding: EdgeInsets.symmetric(horizontal: s(6), vertical: s(12)), decoration: BoxDecoration(color: Colors.white.withOpacity(0.5), borderRadius: BorderRadius.circular(s(45))), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [IconButton(icon: Icon(_loopMode == 0 ? Icons.repeat : (_loopMode == 1 ? Icons.repeat_one : Icons.shuffle)), iconSize: s(33) * _btnScale, color: Colors.black87, onPressed: _toggleLoopMode), IconButton(icon: const Icon(Icons.skip_previous), iconSize: s(45) * _btnScale, color: Colors.black87, onPressed: () { _resetScreenSaverTimer(); _playPrevSong(); }), IconButton(icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled), iconSize: s(64) * _btnScale, color: _lyricHighlightColor, onPressed: () { _resetScreenSaverTimer(); globalPlayer.playOrPause(); }), IconButton(icon: const Icon(Icons.skip_next), iconSize: s(45) * _btnScale, color: Colors.black87, onPressed: () { _resetScreenSaverTimer(); _playNextSong(manual: true); })])),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (sidebarWidth > 0) Container(width: 1, color: Colors.black12),
                    Expanded(child: IndexedStack(index: currentLeftScreen == 2 ? 2 : currentLeftScreen, children: [ _buildNasDashboard(), _buildSongListView(), _buildQQMusicUnifiedStage(), _buildSettingsScreen() ])),
                  ],
                ),
              ],
            )
        )
    );
  }

  Widget _buildNasDashboard() {
    return Padding(
      padding: EdgeInsets.all(s(36.0)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('我的资源', style: TextStyle(fontSize: s(36), fontWeight: FontWeight.bold, color: Colors.black87)), SizedBox(height: s(36)),
          Expanded(child: GridView.builder(gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.4, crossAxisSpacing: s(24), mainAxisSpacing: s(24)), itemCount: webdavAccounts.length + 1, itemBuilder: (context, index) { if (index == webdavAccounts.length) return _buildDashboardCard(title: '系统设置 ⚙️', subtitle: '添加云盘与偏好设置', onTap: () { setState(() { currentLeftScreen = 3; }); }); var acc = webdavAccounts[index]; return _buildDashboardCard(title: '${acc['name']} ☁️', subtitle: activeAccount == acc && realNasSongs.isNotEmpty ? '已挂载 / 共 ${realNasSongs.length} 首歌' : '点击连接挂载', onTap: () { activeAccount = acc; fetchSongsFromWebDav(); setState(() { currentLeftScreen = 1; }); }); }))
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, leading: IconButton(icon: Icon(Icons.arrow_back, color: Colors.black87, size: s(36)), onPressed: () { setState(() { currentLeftScreen = 0; }); }), title: Text('系统设置', style: TextStyle(color: Colors.black87, fontSize: s(28), fontWeight: FontWeight.bold))),
      body: ListView(
        padding: EdgeInsets.all(s(48)),
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("已配置的 WebDAV 节点", style: TextStyle(fontSize: s(26), fontWeight: FontWeight.bold, color: Colors.blueAccent)), ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black87, padding: EdgeInsets.symmetric(horizontal: s(24), vertical: s(12))), icon: Icon(Icons.add, size: s(28)), label: Text("添加", style: TextStyle(fontSize: s(24))), onPressed: () => _showAddWebDAVDialog())]),
          SizedBox(height: s(24)),
          ...webdavAccounts.asMap().entries.map((entry) { int idx = entry.key; var acc = entry.value; return Card(color: Colors.white.withOpacity(0.6), elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(s(12))), child: ListTile(contentPadding: EdgeInsets.all(s(12)), leading: Icon(Icons.cloud_queue, color: Colors.blueAccent, size: s(36)), title: Text(acc['name'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(26))), subtitle: Text(acc['url'], style: TextStyle(fontSize: s(20))), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: Icon(Icons.edit, color: Colors.black54, size: s(36)), onPressed: () => _showAddWebDAVDialog(editIndex: idx)), IconButton(icon: Icon(Icons.delete, color: Colors.redAccent, size: s(36)), onPressed: () { setState(() { if (activeAccount == webdavAccounts[idx]) activeAccount = null; webdavAccounts.removeAt(idx); _prefs.setString('webdavAccounts', jsonEncode(webdavAccounts)); }); })]))); }).toList(),
          SizedBox(height: s(48)), Text("播放与显示偏好", style: TextStyle(fontSize: s(26), fontWeight: FontWeight.bold, color: Colors.blueAccent)),
          Padding(padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)), child: Row(children: [Text("全局 UI 缩放: ", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), Expanded(child: Slider(value: _uiScale, min: 0.8, max: 2.5, divisions: 17, activeColor: Colors.blueAccent, onChanged: (val) { setState(() { _uiScale = val; }); _prefs.setDouble('uiScale', val); _updateCachedFilesList(); })), Text("${_uiScale.toStringAsFixed(1)}x", style: TextStyle(fontSize: s(20)))])),
          Padding(padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)), child: Row(children: [Text("全局按钮缩放: ", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), Expanded(child: Slider(value: _btnScale, min: 0.5, max: 3.0, divisions: 25, activeColor: Colors.blueAccent, onChanged: (val) { setState(() { _btnScale = val; }); _prefs.setDouble('btnScale', val); })), Text("${_btnScale.toStringAsFixed(1)}x", style: TextStyle(fontSize: s(20)))])),
          SwitchListTile(title: Text("断电记忆自动播放", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), subtitle: Text("启动时自动从上次断电位置继续播放", style: TextStyle(fontSize: s(20))), value: _autoPlay, onChanged: (val) { setState(() => _autoPlay = val); _prefs.setBool('autoPlay', val); }),
          SwitchListTile(title: Text("隐藏系统顶部状态栏", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), subtitle: Text("开启后顶栏隐藏，但保留空调导航底栏", style: TextStyle(fontSize: s(20))), value: !_showStatusBar, onChanged: (val) { setState(() => _showStatusBar = !val); _prefs.setBool('showStatusBar', !val); _applyStatusBar(); }),

          ListTile(
            title: Text("后台唤醒权限 (悬浮窗)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))),
            subtitle: Text(
              _hasOverlayPermission ? "✅ 已获得授权，支持在后台强制拉起界面" : "❌ 未授权，开机自动拉起大概率会被系统拦截",
              style: TextStyle(fontSize: s(20), color: _hasOverlayPermission ? Colors.green : Colors.redAccent),
            ),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _hasOverlayPermission ? Colors.grey : Colors.blueAccent,
                padding: EdgeInsets.symmetric(horizontal: s(24), vertical: s(12)),
              ),
              onPressed: () async {
                if (!_hasOverlayPermission) {
                  await platform.invokeMethod('requestOverlayPermission');
                }
              },
              child: Text(_hasOverlayPermission ? "已授权" : "去授权", style: TextStyle(color: Colors.white, fontSize: s(20), fontWeight: FontWeight.bold)),
            ),
          ),
          Divider(color: Colors.black12),

          SwitchListTile(title: Text("开机自动运行", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), subtitle: Text("通电开机后，在后台自动拉起本播放器", style: TextStyle(fontSize: s(20))), value: _startOnBoot, onChanged: (val) { setState(() => _startOnBoot = val); _prefs.setBool('startOnBoot', val); }),
          if (_startOnBoot) Padding(padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(4)), child: Row(children: [Text("自启延迟时间: ", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24), color: Colors.black54)), Expanded(child: Slider(value: _bootDelay.toDouble(), min: 0.0, max: 60.0, divisions: 60, activeColor: Colors.blueAccent.withOpacity(0.7), onChanged: (val) { setState(() => _bootDelay = val.toInt()); _prefs.setInt('bootDelay', val.toInt()); })), SizedBox(width: s(80), child: Text("$_bootDelay 秒", style: TextStyle(fontSize: s(22), fontWeight: FontWeight.bold), textAlign: TextAlign.right))])),
          SizedBox(height: s(48)),
          Text('\u542f\u52a8\u5176\u4ed6\u5e94\u7528', style: TextStyle(fontSize: s(26), fontWeight: FontWeight.bold, color: Colors.blueAccent)),
          SwitchListTile(
            title: Text('\u542f\u52a8\u65f6\u62c9\u8d77\u5176\u4ed6\u5e94\u7528', style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))),
            subtitle: Text('\u5f00\u542f\u540e\uff0c\u5e94\u7528\u542f\u52a8\u540e\u81ea\u52a8\u6253\u5f00\u4e0b\u65b9\u9009\u5b9a\u7684\u5e94\u7528', style: TextStyle(fontSize: s(20))),
            value: _startOtherAppOnBoot,
            onChanged: (val) { setState(() => _startOtherAppOnBoot = val); _prefs.setBool('startOtherAppOnBoot', val); },
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
            child: Row(children: [
              Text('\u76ee\u6807\u5e94\u7528: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))),
              Expanded(child: Text(_bootOtherAppLabel.isNotEmpty ? _bootOtherAppLabel : '\u672a\u9009\u62e9', style: TextStyle(fontSize: s(22), color: _bootOtherAppLabel.isNotEmpty ? Colors.black87 : Colors.black38), overflow: TextOverflow.ellipsis)),
              SizedBox(width: s(16)),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black87, padding: EdgeInsets.symmetric(horizontal: s(20), vertical: s(10))),
                icon: Icon(Icons.apps, size: s(28)),
                label: Text('\u9009\u62e9\u5e94\u7528', style: TextStyle(fontSize: s(22))),
                onPressed: () => _showAppPickerDialog(),
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
            child: Row(children: [
              Text('\u542f\u52a8\u5ef6\u8fdf: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))),
              Expanded(child: Slider(value: _bootOtherAppDelay.toDouble(), min: 1.0, max: 30.0, divisions: 29, activeColor: Colors.blueAccent, onChanged: (val) { setState(() => _bootOtherAppDelay = val.toInt()); _prefs.setInt('bootOtherAppDelay', val.toInt()); })),
              SizedBox(width: s(80), child: Text("${_bootOtherAppDelay}s", style: TextStyle(fontSize: s(22), fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
            ]),
          ),

          Padding(padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)), child: Row(children: [Text("自动进入大屏: ", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), Expanded(child: Slider(value: _screenSaverTimeout.toDouble(), min: 0.0, max: 60.0, divisions: 60, activeColor: Colors.blueAccent, onChanged: (val) { setState(() { _screenSaverTimeout = val.toInt(); }); _prefs.setInt('screenSaverTimeout', val.toInt()); _resetScreenSaverTimer(); })), Text(_screenSaverTimeout == 0 ? "不自动切换" : "$_screenSaverTimeout s", style: TextStyle(fontSize: s(20)))])),
          Padding(padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)), child: Row(children: [Text("大屏歌词字号: ", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), Expanded(child: Slider(value: _lyricFontSize, min: 30.0, max: 100.0, activeColor: Colors.blueAccent, onChanged: (val) { setState(() => _lyricFontSize = val); _prefs.setDouble('lyricFontSize', val); })), Text(_lyricFontSize.toInt().toString(), style: TextStyle(fontSize: s(20)))])),
          Padding(padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)), child: Row(children: [Text("最大离线缓存 (GB): ", style: TextStyle(fontWeight: FontWeight.bold, fontSize: s(24))), Expanded(child: Slider(value: _maxCacheGB, min: 0.5, max: 20.0, divisions: 39, activeColor: Colors.blueAccent, onChanged: (val) { setState(() => _maxCacheGB = val); _prefs.setDouble('maxCacheGB', val); })), Text(_maxCacheGB.toStringAsFixed(1), style: TextStyle(fontSize: s(20)))])),

          SizedBox(height: s(60)),
          Divider(color: Colors.black12, height: s(60)),
          Center(
            child: Column(
              children: [
                Text(appAuthor, style: TextStyle(fontSize: s(22), fontWeight: FontWeight.bold, color: Colors.black54)),
                SizedBox(height: s(8)),
                Text("Build: $appBuildTime", style: TextStyle(fontSize: s(18), color: Colors.black38, fontFamily: 'monospace')),
                SizedBox(height: s(40)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showAddWebDAVDialog({int? editIndex}) {
    var acc = editIndex != null ? webdavAccounts[editIndex] : null; TextEditingController nameCtrl = TextEditingController(text: acc?['name'] ?? ""), urlCtrl = TextEditingController(text: acc?['url'] ?? ""), userCtrl = TextEditingController(text: acc?['user'] ?? ""), pwdCtrl = TextEditingController(text: acc?['pwd'] ?? "");
    showDialog(context: context, builder: (context) { return AlertDialog(title: Text(editIndex == null ? "添加 WebDAV" : "修改 WebDAV", style: TextStyle(fontSize: s(24))), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: nameCtrl, style: TextStyle(fontSize: s(20)), decoration: const InputDecoration(labelText: "显示名称 (例: 家里群晖)")), TextField(controller: urlCtrl, style: TextStyle(fontSize: s(20)), decoration: const InputDecoration(labelText: "URL (需以 / 结尾)")), TextField(controller: userCtrl, style: TextStyle(fontSize: s(20)), decoration: const InputDecoration(labelText: "用户名")), TextField(controller: pwdCtrl, style: TextStyle(fontSize: s(20)), obscureText: true, decoration: const InputDecoration(labelText: "密码"))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text("取消", style: TextStyle(fontSize: s(20)))), ElevatedButton(onPressed: () { setState(() { var newAcc = {"name": nameCtrl.text, "url": urlCtrl.text, "user": userCtrl.text, "pwd": pwdCtrl.text}; if (editIndex != null) { webdavAccounts[editIndex] = newAcc; if (activeAccount == acc) activeAccount = newAcc; } else { webdavAccounts.add(newAcc); } _prefs.setString('webdavAccounts', jsonEncode(webdavAccounts)); }); Navigator.pop(context); }, child: Text("保存", style: TextStyle(fontSize: s(20))))]); });
  }

  Widget _buildSongListView() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.black87, size: s(36)),
          onPressed: () { setState(() { currentLeftScreen = 0; _slidingSongName = null; }); },
        ),
        title: Text(activeAccount != null ? activeAccount!['name'] : '群晖歌单',
          style: TextStyle(color: Colors.black87, fontSize: s(28), fontWeight: FontWeight.bold)),
      ),
      body: isLoading ? const Center(child: CircularProgressIndicator()) : GestureDetector(
        onTap: () {
          // 点击空白区域关闭滑动状态
          if (_slidingSongName != null) {
            setState(() => _slidingSongName = null);
          }
        },
        child: ListView.builder(
          controller: _playlistScrollController,
          itemCount: realNasSongs.length,
          itemBuilder: (context, index) {
            String songName = realNasSongs[index];
            bool isCurrent = songName == _currentFileName;
            bool isCached = _cachedFiles.contains(songName);
            bool isSliding = _slidingSongName == songName;
            String nasName = activeAccount != null ? activeAccount!['name'] : '未知云盘';

            Widget songItem = Container(
              height: s(114.0),
              color: isCurrent ? _lyricHighlightColor.withOpacity(0.12) : Colors.transparent,
              child: Center(
                child: ListTile(
                  leading: SizedBox(
                    width: s(48),
                    child: isCurrent
                      ? Icon(Icons.equalizer, color: _lyricHighlightColor, size: s(36))
                      : Text('${index + 1}', style: TextStyle(fontSize: s(24), color: Colors.black54), textAlign: TextAlign.center),
                  ),
                  title: Text(songName.replaceAll(RegExp(r'\.[^.]+$'), ''),
                    style: TextStyle(fontSize: s(26), fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                      color: isCurrent ? _lyricHighlightColor : Colors.black87)),
                  subtitle: Text(isCached ? '来自 $nasName / 已缓存' : '来自 $nasName',
                    style: TextStyle(fontSize: s(18), color: isCurrent ? _lyricHighlightColor.withOpacity(0.7) : Colors.black54)),
                  trailing: Icon(isCurrent ? Icons.pause_circle_outline : Icons.play_circle_outline,
                    color: isCurrent ? _lyricHighlightColor : Colors.black87, size: s(36)),
                  onTap: () {
                    if (isSliding) {
                      setState(() => _slidingSongName = null);
                    } else {
                      playNasSong(songName);
                    }
                  },
                ),
              ),
            );

            if (!isCached) return songItem;

            return GestureDetector(
              onHorizontalDragUpdate: (details) {
                if (details.delta.dx < -5 && !isSliding) {
                  setState(() => _slidingSongName = songName);
                } else if (details.delta.dx > 5 && isSliding) {
                  setState(() => _slidingSongName = null);
                }
              },
              child: Stack(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    margin: EdgeInsets.only(right: isSliding ? s(120) : 0),
                    child: songItem,
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    right: isSliding ? 0 : s(-120),
                    top: 0,
                    bottom: 0,
                    width: s(120),
                    child: GestureDetector(
                      onTap: () {
                        showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('清除缓存', style: TextStyle(fontSize: s(24))),
                            content: Text('确定要清除「${songName.replaceAll(RegExp(r'\.[^.]+$'), '')}」的缓存吗？',
                              style: TextStyle(fontSize: s(22))),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消', style: TextStyle(fontSize: s(20)))),
                              TextButton(onPressed: () => Navigator.pop(context, true), child: Text('清除', style: TextStyle(fontSize: s(20), color: Colors.redAccent))),
                            ],
                          ),
                        ).then((confirmed) {
                          if (confirmed == true) {
                            _deleteCacheFile(songName);
                            setState(() => _slidingSongName = null);
                          }
                        });
                      },
                      child: Container(
                        color: Colors.redAccent,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.delete, color: Colors.white, size: s(32)),
                              SizedBox(height: s(4)),
                              Text('清除缓存', style: TextStyle(color: Colors.white, fontSize: s(16))),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildQQMusicUnifiedStage() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque, onTap: () { setState(() { _isLargeMode = !_isLargeMode; _resetScreenSaverTimer(); }); },
        child: Stack(
          children: [
            Positioned(left: s(30), top: s(30), child: IconButton(icon: Icon(Icons.arrow_back_ios, color: Colors.black87, size: s(36)), onPressed: () { setState(() { currentLeftScreen = 1; _screenSaverTimer?.cancel(); _scrollToCurrentSong(); }); })),
            AnimatedPositioned(duration: const Duration(milliseconds: 450), curve: Curves.easeInOut, right: s(75), bottom: _isLargeMode ? s(75) : s(225), width: _isLargeMode ? s(240) : s(220), height: _isLargeMode ? s(240) : s(220), child: AnimatedOpacity(duration: const Duration(milliseconds: 300), opacity: _isLargeMode ? 1.0 : 0.0, child: RotationTransition(turns: _isLargeMode ? _spinController : const AlwaysStoppedAnimation(0), child: AnimatedContainer(duration: const Duration(milliseconds: 450), decoration: BoxDecoration(borderRadius: BorderRadius.circular(s(300)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: s(25), offset: Offset(0, s(10)))], image: DecorationImage(image: NetworkImage(currentCoverUrl), fit: BoxFit.cover)), child: Center(child: Container(width: s(45), height: s(45), decoration: BoxDecoration(color: Colors.white.withOpacity(0.8), shape: BoxShape.circle))))))),
            AnimatedPositioned(duration: const Duration(milliseconds: 450), curve: Curves.easeInOut, left: s(75), top: _isLargeMode ? s(85) : s(90), bottom: _isLargeMode ? s(60) : s(240), width: s(750), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(currentPlayingSong, style: TextStyle(fontSize: _isLargeMode ? s(40) : s(34), fontWeight: FontWeight.bold, color: Colors.black87)), Text(currentArtist, style: TextStyle(fontSize: s(18), color: Colors.black54)), SizedBox(height: s(15)), Expanded(child: _buildScrollingLyrics(context, isMini: false))])),
            AnimatedPositioned(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut, left: s(75), right: s(75), bottom: _isLargeMode ? s(-180) : s(30), child: AnimatedOpacity(duration: const Duration(milliseconds: 300), opacity: _isLargeMode ? 0.0 : 1.0, child: Column(children: [Row(children: [Text(_printDuration(_currentPosition), style: TextStyle(color: Colors.black54, fontSize: s(18))), Expanded(child: Slider(value: _totalDuration.inMilliseconds > 0 ? _currentPosition.inMilliseconds.toDouble() : 0.0, min: 0.0, max: _totalDuration.inMilliseconds > 0 ? _totalDuration.inMilliseconds.toDouble() : 1.0, activeColor: Colors.black87, inactiveColor: Colors.black12, onChanged: (value) { _resetScreenSaverTimer(); globalPlayer.seek(Duration(milliseconds: value.toInt())); })), Text(_printDuration(_totalDuration), style: TextStyle(color: Colors.black54, fontSize: s(18)))]), FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(icon: Icon(_loopMode == 0 ? Icons.repeat : (_loopMode == 1 ? Icons.repeat_one : Icons.shuffle)), iconSize: s(42) * _btnScale, color: Colors.black87, onPressed: _toggleLoopMode), SizedBox(width: s(36)), IconButton(icon: const Icon(Icons.skip_previous), iconSize: s(64) * _btnScale, color: Colors.black87, onPressed: () { _resetScreenSaverTimer(); _playPrevSong(); }), SizedBox(width: s(24)), IconButton(icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled), iconSize: s(100) * _btnScale, color: _lyricHighlightColor, onPressed: () { _resetScreenSaverTimer(); globalPlayer.playOrPause(); }), SizedBox(width: s(24)), IconButton(icon: const Icon(Icons.skip_next), iconSize: s(64) * _btnScale, color: Colors.black87, onPressed: () { _resetScreenSaverTimer(); _playNextSong(manual: true); }), SizedBox(width: s(36)), IconButton(icon: const Icon(Icons.timer), iconSize: s(42) * _btnScale, color: Colors.black87, onPressed: () { _resetScreenSaverTimer(); _showLyricOffsetDialog(); }), SizedBox(width: s(24)), IconButton(icon: const Icon(Icons.queue_music), iconSize: s(42) * _btnScale, color: Colors.black87, onPressed: () async { if (playingAccount != null && activeAccount != playingAccount) { setState(() { activeAccount = playingAccount; }); await fetchSongsFromWebDav(silent: true); } setState(() { currentLeftScreen = 1; _isLargeMode = false; }); _screenSaverTimer?.cancel(); Future.delayed(const Duration(milliseconds: 300), () => _scrollToCurrentSong()); })]))]))),
            AnimatedPositioned(duration: const Duration(milliseconds: 450), curve: Curves.easeInOut, right: s(75), top: _isLargeMode ? s(35) : s(-240), child: AnimatedOpacity(duration: const Duration(milliseconds: 300), opacity: _isLargeMode ? 1.0 : 0.0, child: Text(_currentTimeString, style: TextStyle(fontSize: s(160), fontWeight: FontWeight.w200, color: Colors.black87, fontFamily: 'monospace')))),
          ],
        ),
      ),
    );
  }

  void _showLyricOffsetDialog() {
    showDialog(context: context, builder: (context) { return StatefulBuilder(builder: (context, setDialogState) { return AlertDialog(backgroundColor: Colors.white.withOpacity(0.9), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(s(24))), title: Center(child: Text("单曲歌词微调", style: TextStyle(fontSize: s(24), fontWeight: FontWeight.bold))), content: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(icon: Icon(Icons.fast_rewind, size: s(48), color: Colors.black87), onPressed: () { setDialogState(() { if (_lyricOffset > -30.0) _lyricOffset -= 0.2; }); _prefs.setDouble('lyricOffset_$_currentFileName', _lyricOffset); setState(() { _currentLyricIndex = -1; }); _updateLyricScroll(_currentPosition); }), SizedBox(width: s(120), child: Text("${_lyricOffset > 0 ? '+' : ''}${_lyricOffset.toStringAsFixed(1).replaceAll('.0', '')}s", style: TextStyle(fontSize: s(32), fontWeight: FontWeight.bold, color: _lyricHighlightColor), textAlign: TextAlign.center)), IconButton(icon: Icon(Icons.fast_forward, size: s(48), color: Colors.black87), onPressed: () { setDialogState(() { if (_lyricOffset < 30.0) _lyricOffset += 0.2; }); _prefs.setDouble('lyricOffset_$_currentFileName', _lyricOffset); setState(() { _currentLyricIndex = -1; }); _updateLyricScroll(_currentPosition); })]), actions: [Center(child: TextButton(onPressed: () => Navigator.pop(context), child: Text("完成", style: TextStyle(fontSize: s(22), color: Colors.blueAccent))))]); }); });
  }

  Widget _buildDashboardCard({required String title, required String subtitle, required VoidCallback onTap}) {
    return GestureDetector(onTap: onTap, child: Container(decoration: BoxDecoration(color: Colors.white.withOpacity(0.55), borderRadius: BorderRadius.circular(s(24)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: s(15), offset: Offset(0, s(6)))]), padding: EdgeInsets.all(s(24)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [Text(title, style: TextStyle(fontSize: s(28), fontWeight: FontWeight.bold, color: Colors.black87)), SizedBox(height: s(8)), Text(subtitle, style: TextStyle(fontSize: s(20), color: Colors.black54))])));
  }
}

class MediaKitAudioHandler extends BaseAudioHandler with SeekHandler {
  final Player player;
  MediaItem? _currentMediaItem;

  // 回调函数，用于通知UI层执行切歌操作
  void Function()? onNextCallback;
  void Function()? onPrevCallback;

  MediaKitAudioHandler(this.player) {
    // 启动时立刻塞入一个默认焦点，告诉 Android 系统这里有个活跃的媒体服务
    _currentMediaItem = const MediaItem(
      id: 'init',
      title: '等待播放',
      artist: 'NAS Car Player',
    );
    mediaItem.add(_currentMediaItem!);
    _broadcastState(false);

    player.stream.playing.listen((playing) {
      _broadcastState(playing);
    });
    player.stream.position.listen((position) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position,
      ));
    });
  }

  void _broadcastState(bool playing) {
    playbackState.add(playbackState.value.copyWith(
      playing: playing,
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {
        MediaAction.seek,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.playPause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      processingState: AudioProcessingState.ready,
      updatePosition: player.state.position,
      bufferedPosition: player.state.position,
      speed: 1.0,
    ));
  }

  // 切歌加载期间强制保持缓冲状态，保持媒体焦点
  void forceBuffering() {
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.buffering,
    ));
  }

  @override
  Future<void> play() async {
    await player.play();
    _broadcastState(true);
  }

  @override
  Future<void> pause() async {
    await player.pause();
    _broadcastState(false);
  }

  @override
  Future<void> playPause() async {
    await player.playOrPause();
    _broadcastState(player.state.playing);
  }

  @override
  Future<void> seek(Duration position) async => await player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    return super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // 不调用 stop() 和 exit(0)
    // BYD 等车机在切换应用时可能触发 onTaskRemoved，如果退出进程则 MediaSession 被销毁
    // 保持进程存活，让 MediaSession 持续响应后台方向盘多媒体按键
  }

  @override
  Future<void> skipToNext() async {
    if (onNextCallback != null) onNextCallback!();
  }

  @override
  Future<void> skipToPrevious() async {
    if (onPrevCallback != null) onPrevCallback!();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        await player.playOrPause();
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  Future<void> updateCurrentSong(String title, String artist, String coverUrl) async {
    _currentMediaItem = MediaItem(
      id: title,
      title: title,
      artist: artist,
      artUri: Uri.parse(coverUrl),
    );
    mediaItem.add(_currentMediaItem!);
  }

  Future<void> updateDuration(Duration duration) async {
    if (_currentMediaItem != null) {
      _currentMediaItem = _currentMediaItem!.copyWith(duration: duration);
      mediaItem.add(_currentMediaItem!);
    }
  }
}