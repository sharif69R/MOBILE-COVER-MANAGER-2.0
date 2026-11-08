import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/phone.dart';

/// Outcome of a photo lookup.
/// [source] is one of: official, web, wikipedia, none, offline.
class PhotoResult {
  final String? path;
  final String source;
  const PhotoResult(this.path, this.source);

  bool get found => path != null;
  bool get official => source == 'official';

  String get label {
    switch (source) {
      case 'official':
        return 'Official manufacturer image';
      case 'wikipedia':
        return 'Image from Wikipedia (may not be the back view)';
      case 'web':
        return 'Web image (not confirmed as official)';
      case 'offline':
        return 'No internet connection - photo could not be looked up';
      default:
        return 'No photo found for this model';
    }
  }
}

class _Hit {
  final String url;
  final String? thumb;
  final String source;
  final int score;
  const _Hit(this.url, this.thumb, this.source, this.score);
}

/// Finds one back-panel photo per phone model, saves it on the device and
/// remembers both hits and misses so the internet is only used once per model.
class PhotoService {
  PhotoService(this.db);
  final Database db;

  /// Optional key for Brave Image Search. Supplied at build time with
  /// --dart-define=BRAVE_API_KEY=... (the GitHub workflow does this from the
  /// BRAVE_API_KEY repository secret). Without it the app uses Wikipedia only.
  static const String braveKey = String.fromEnvironment('BRAVE_API_KEY');
  static bool get hasBrave => braveKey.isNotEmpty;

  static const String _ua = 'RepairXZoneCoverManager/1.4 (phone cover inventory app)';
  static const Duration _missTtl = Duration(days: 7);
  static const int _maxParallel = 2;

  static Future<void> createTable(Database db) => db.execute(
      'CREATE TABLE IF NOT EXISTS photo_cache(photo_key TEXT PRIMARY KEY, file TEXT, source TEXT NOT NULL DEFAULT \'\', checked_at INTEGER NOT NULL DEFAULT 0)');

  // ---------------------------------------------------------------- helpers

  static final RegExp _nonAlnumRun = RegExp(r'[^a-z0-9]+');

  static String keyFor(String brand, String model) =>
      ('${brand}_$model').toLowerCase().replaceAll(_nonAlnumRun, '_');

  static String _norm(String text) =>
      text.toLowerCase().replaceAll(_nonAlnumRun, ' ').trim();

  static const Set<String> _noiseTokens = {
    '5g', '4g', '3g', 'lte', 'dual', 'sim', 'global', 'version', 'edition', 'the'
  };

  /// Words that turn one phone into a different phone. A result that mentions
  /// "Pro" must not be used for a phone whose name has no "Pro".
  static const List<String> _variantWords = [
    'pro', 'plus', 'ultra', 'max', 'mini', 'lite', 'fe', 'se', 'neo', 'fold', 'flip', 'note'
  ];

  static const List<String> _rejectWords = [
    'case', 'cases', 'cover', 'covers', 'protector', 'tempered', 'charger', 'cable',
    'skin', 'wallpaper', 'wallpapers', 'holder', 'stand', 'strap', 'adapter'
  ];

  static List<String> _modelTokens(String model) => _norm(model)
      .split(' ')
      .where((t) => t.isNotEmpty && !_noiseTokens.contains(t))
      .toList(growable: false);

  static bool _hasAllTokens(String text, List<String> tokens) {
    if (tokens.isEmpty) return false;
    final padded = ' ${_norm(text)} ';
    return tokens.every((t) => padded.contains(' $t '));
  }

  static bool _hasWord(String paddedNorm, String word) => paddedNorm.contains(' $word ');

  static const Map<String, List<String>> _officialDomains = {
    'samsung': ['samsung.com', 'samsungmobilepress.com', 'images.samsung.com'],
    'apple': ['apple.com', 'mzstatic.com', 'cdn-apple.com'],
    'oneplus': ['oneplus.com', 'oneplus.net', 'opstatics.com'],
    'xiaomi': ['mi.com', 'appmifile.com', 'mi-img.com'],
    'redmi': ['mi.com', 'appmifile.com', 'mi-img.com'],
    'poco': ['mi.com', 'appmifile.com', 'mi-img.com'],
    'oppo': ['oppo.com'],
    'vivo': ['vivo.com', 'vivofs.com', 'iqoo.com'],
    'iqoo': ['iqoo.com', 'vivo.com', 'vivofs.com'],
    'realme': ['realme.com', 'realme.net'],
    'tecno': ['tecno-mobile.com'],
    'infinix': ['infinixmobility.com'],
    'itel': ['itel-life.com'],
    'honor': ['honor.com', 'honorfile.com'],
    'huawei': ['huawei.com'],
    'google': ['google.com', 'googleusercontent.com', 'withgoogle.com'],
    'motorola': ['motorola.com'],
    'nothing': ['nothing.tech'],
    'asus': ['asus.com'],
    'sony': ['sony.com', 'sony.net'],
    'nokia': ['hmd.com'],
    'hmd': ['hmd.com'],
    'zte': ['zte.com'],
    'nubia': ['nubia.com'],
    'tcl': ['tcl.com'],
    'meizu': ['meizu.com'],
    'lava': ['lavainternational.in'],
  };

  static List<String> _domainsFor(String brand) {
    final b = brand.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    for (final entry in _officialDomains.entries) {
      if (b.contains(entry.key)) return entry.value;
    }
    return const [];
  }

  static bool _isOfficialHost(String host, List<String> domains) =>
      domains.any((d) => host == d || host.endsWith('.$d'));

  static bool _looksLikeImage(List<int> b) {
    if (b.length < 12) return false;
    final jpeg = b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;
    final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
    final webp = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
    return jpeg || png || webp;
  }

  // ------------------------------------------------------- concurrency gate

  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> _acquire() async {
    if (_active < _maxParallel) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future; // the slot is handed over, _active stays the same
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  DateTime _nextBrave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _braveRejected = false;

  /// Last reason Brave could not be used, shown in the photo viewer.
  String? braveProblem;

  /// Brave's entry plans allow about one request per second.
  Future<void> _braveThrottle() async {
    final now = DateTime.now();
    final start = _nextBrave.isAfter(now) ? _nextBrave : now;
    _nextBrave = start.add(const Duration(milliseconds: 1100));
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  // ------------------------------------------------------------ file + cache

  Directory? _photoDir;
  Future<Directory> _dir() async {
    final existing = _photoDir;
    if (existing != null) return existing;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'official_phone_photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _photoDir = dir;
    return dir;
  }

  Future<PhotoResult?> _readCache(String key) async {
    final rows = await db.query('photo_cache', where: 'photo_key = ?', whereArgs: [key], limit: 1);
    final dir = await _dir();
    if (rows.isNotEmpty) {
      final row = rows.first;
      final file = row['file'] as String?;
      if (file != null && file.isNotEmpty) {
        final f = File(p.join(dir.path, file));
        if (await f.exists() && await f.length() > 0) {
          return PhotoResult(f.path, (row['source'] as String?) ?? 'web');
        }
      } else {
        final checked = (row['checked_at'] as int?) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - checked;
        if (age >= 0 && age < _missTtl.inMilliseconds) return const PhotoResult(null, 'none');
      }
    }
    // Photos saved by older versions of the app live in the same folder.
    final legacy = File(p.join(dir.path, '$key.img'));
    if (await legacy.exists() && await legacy.length() > 0) {
      await _writeCache(key, '$key.img', 'web');
      return PhotoResult(legacy.path, 'web');
    }
    return null;
  }

  Future<void> _writeCache(String key, String? file, String source) => db.insert(
        'photo_cache',
        {
          'photo_key': key,
          'file': file,
          'source': source,
          'checked_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Forget "no photo found" answers so they are searched again.
  Future<void> clearMisses() => db.delete('photo_cache', where: 'file IS NULL');

  // ------------------------------------------------------------------ lookup

  final Map<String, Future<PhotoResult>> _inflight = {};

  Future<PhotoResult> lookup(String brand, String model, {bool force = false}) {
    final key = keyFor(brand, model);
    if (force) _inflight.remove(key);
    final existing = _inflight[key];
    if (existing != null) return existing;
    final task = _resolve(key, brand, model, force);
    _inflight[key] = task;
    task.whenComplete(() {
      _inflight.remove(key);
    });
    return task;
  }

  Future<PhotoResult> _resolve(String key, String brand, String model, bool force) async {
    try {
      if (!force) {
        final cached = await _readCache(key);
        if (cached != null) return cached;
      }
      await _acquire();
      try {
        var networkProblem = false;
        final hits = <_Hit>[];

        if (hasBrave && !_braveRejected) {
          try {
            hits.addAll(await _searchBrave(brand, model));
          } catch (_) {
            networkProblem = true;
          }
        }
        if (hits.isEmpty) {
          try {
            hits.addAll(await _searchDuckDuckGo(brand, model));
          } catch (_) {
            networkProblem = true;
          }
        }
        if (hits.isEmpty) {
          try {
            hits.addAll(await _searchFree(brand, model));
          } catch (_) {
            networkProblem = true;
          }
        }

        var tried = 0;
        for (final hit in hits) {
          if (tried++ >= 6) break;
          final file = await _saveImage(key, hit);
          if (file != null) {
            await _writeCache(key, file, hit.source);
            final dir = await _dir();
            return PhotoResult(p.join(dir.path, file), hit.source);
          }
        }

        if (networkProblem && hits.isEmpty) return const PhotoResult(null, 'offline');
        await _writeCache(key, null, '');
        return const PhotoResult(null, 'none');
      } finally {
        _release();
      }
    } catch (_) {
      return const PhotoResult(null, 'offline');
    }
  }

  // ------------------------------------------------------------------- Brave

  Future<List<_Hit>> _searchBrave(String brand, String model) async {
    final name = phoneQueryName(brand, model);
    final domains = _domainsFor(brand);
    final tokens = _modelTokens(model);
    final hits = <_Hit>[];

    hits.addAll(await _braveQuery('"$name" back panel official', brand, tokens, domains));
    final foundOfficial = hits.any((h) => h.source == 'official');
    if (!foundOfficial && domains.isNotEmpty && !_braveRejected) {
      hits.addAll(await _braveQuery('$name back view site:${domains.first}', brand, tokens, domains));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  }

  Future<List<_Hit>> _braveQuery(String query, String brand, List<String> tokens, List<String> domains) async {
    await _braveThrottle();
    final uri = Uri.https('api.search.brave.com', '/res/v1/images/search', {
      'q': query,
      'count': '40',
      'safesearch': 'strict',
      'search_lang': 'en',
    });
    final response = await http.get(uri, headers: {
      'Accept': 'application/json',
      'X-Subscription-Token': braveKey,
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 || response.statusCode == 403) {
      _braveRejected = true; // wrong or expired key: stop spending requests
      braveProblem = 'Brave key rejected (HTTP ${response.statusCode})';
      return const [];
    }
    if (response.statusCode == 429 || response.statusCode == 402) {
      braveProblem = 'Brave limit reached (HTTP ${response.statusCode})';
    }
    if (response.statusCode != 200) throw HttpException('Brave search ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final results = data is Map ? data['results'] : null;
    if (results is! List) return const [];

    final hits = <_Hit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final hit = _scoreResult(raw, brand, tokens, domains);
      if (hit != null) hits.add(hit);
    }
    return hits;
  }

  /// Gives a search result a score, or null when it is clearly the wrong thing.
  _Hit? _scoreResult(Map raw, String brand, List<String> tokens, List<String> domains) {
    final props = raw['properties'];
    final thumbnail = raw['thumbnail'];
    final imageUrl = (props is Map ? props['url'] : null)?.toString() ?? '';
    final thumbUrl = (thumbnail is Map ? thumbnail['src'] : null)?.toString();
    final pageUrl = (raw['url'] ?? '').toString();
    final title = (raw['title'] ?? '').toString();

    final image = Uri.tryParse(imageUrl);
    if (image == null || image.scheme != 'https' || image.host.isEmpty) return null;
    final lowerPath = image.path.toLowerCase();
    if (lowerPath.endsWith('.svg') || lowerPath.endsWith('.gif')) return null;

    final padded = ' ${_norm('$title $pageUrl $imageUrl')} ';

    // Wrong subject: accessories, wallpapers and so on.
    for (final bad in _rejectWords) {
      if (_hasWord(padded, bad)) return null;
    }
    // Must mention every distinctive part of the model name (a15, 14, pro ...).
    if (tokens.isEmpty || !tokens.every((t) => _hasWord(padded, t))) return null;

    var score = 20;
    final brandWord = _norm(brand);
    if (brandWord.isNotEmpty && brandWord != 'other' && _hasWord(padded, brandWord)) score += 10;

    // A different edition (Pro/Plus/Ultra...) of the same family.
    final titleAndPage = ' ${_norm('$title $pageUrl')} ';
    for (final v in _variantWords) {
      if (!tokens.contains(v) && _hasWord(titleAndPage, v)) score -= 60;
    }

    final mentionsBack = _hasWord(padded, 'back') || _hasWord(padded, 'rear');
    if (mentionsBack) {
      score += 25;
    } else if (_hasWord(padded, 'front')) {
      score -= 10;
    }

    var official = false;
    if (domains.isNotEmpty) {
      final pageHost = Uri.tryParse(pageUrl)?.host.toLowerCase() ?? '';
      final imageOfficial = _isOfficialHost(image.host.toLowerCase(), domains);
      final pageOfficial = _isOfficialHost(pageHost, domains);
      if (imageOfficial) score += 60;
      if (pageOfficial) score += 40;
      official = imageOfficial || pageOfficial;
    }

    final width = props is Map ? props['width'] : null;
    if (width is num && width < 200) score -= 20;

    if (score < 45) return null;
    return _Hit(imageUrl, (thumbUrl != null && thumbUrl.startsWith('https://')) ? thumbUrl : null,
        official ? 'official' : 'web', score);
  }

  // ------------------------------------------------------ DuckDuckGo (free)

  DateTime _nextDdg = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _ddgThrottle() async {
    final now = DateTime.now();
    final start = _nextDdg.isAfter(now) ? _nextDdg : now;
    _nextDdg = start.add(const Duration(milliseconds: 1500));
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// Free image search with no key. Uses DuckDuckGo's public image endpoint,
  /// which is unofficial and may change. Results go through the same scoring
  /// as Brave, so official manufacturer images still get the green tick.
  Future<List<_Hit>> _searchDuckDuckGo(String brand, String model) async {
    final name = phoneQueryName(brand, model);
    final domains = _domainsFor(brand);
    final tokens = _modelTokens(model);
    final hits = <_Hit>[];

    hits.addAll(await _ddgQuery('$name back panel official', brand, tokens, domains));
    if (!hits.any((h) => h.source == 'official') && domains.isNotEmpty) {
      hits.addAll(await _ddgQuery('$name back view site:${domains.first}', brand, tokens, domains));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  }

  Future<List<_Hit>> _ddgQuery(String query, String brand, List<String> tokens, List<String> domains) async {
    await _ddgThrottle();
    const headers = {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      'Accept-Language': 'en-US,en;q=0.9',
    };
    // Step 1: DuckDuckGo hands out a short-lived token (vqd) for the search.
    final page = await http
        .get(Uri.https('duckduckgo.com', '/', {'q': query, 'iax': 'images', 'ia': 'images'}), headers: headers)
        .timeout(const Duration(seconds: 15));
    if (page.statusCode != 200) throw HttpException('DuckDuckGo ${page.statusCode}');
    final vqd = RegExp(r'vqd=\W?([\d-]+)').firstMatch(page.body)?.group(1);
    if (vqd == null) throw const HttpException('DuckDuckGo token not found');

    // Step 2: the actual image results.
    final response = await http.get(
      Uri.https('duckduckgo.com', '/i.js', {
        'l': 'us-en',
        'o': 'json',
        'q': query,
        'vqd': vqd,
        'f': ',,,,,',
        'p': '1',
      }),
      headers: {...headers, 'Referer': 'https://duckduckgo.com/'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('DuckDuckGo images ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final results = data is Map ? data['results'] : null;
    if (results is! List) return const [];

    final hits = <_Hit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      // Convert to the shape _scoreResult already understands.
      final mapped = <String, dynamic>{
        'title': raw['title'],
        'url': raw['url'],
        'thumbnail': {'src': raw['thumbnail']},
        'properties': {'url': raw['image'], 'width': raw['width']},
      };
      final hit = _scoreResult(mapped, brand, tokens, domains);
      if (hit != null) hits.add(hit);
    }
    return hits;
  }

  // ------------------------------------------------- Wikipedia + Commons (free)

  /// Free, key-less sources. Tries several Wikipedia queries and then
  /// Wikimedia Commons file search, so far more models get a photo than with
  /// a single Wikipedia query. These are NOT official manufacturer images.
  Future<List<_Hit>> _searchFree(String brand, String model) async {
    final hits = <_Hit>[];
    var failures = 0;
    var attempts = 0;
    final name = phoneQueryName(brand, model);
    final tokens = _modelTokens(model);

    final wikiQueries = <String>{name, '$name smartphone', '$brand $model phone'};
    for (final q in wikiQueries) {
      attempts++;
      try {
        final hit = await _searchWikipedia(q, tokens);
        if (hit != null && hits.every((h) => h.url != hit.url)) hits.add(hit);
      } catch (_) {
        failures++;
      }
      if (hits.isNotEmpty) break;
    }

    if (hits.isEmpty) {
      attempts++;
      try {
        hits.addAll(await _searchCommons(name, tokens));
      } catch (_) {
        failures++;
      }
    }
    // Every request failed => most likely no internet connection.
    if (hits.isEmpty && failures == attempts) throw const SocketException('free sources unreachable');
    return hits;
  }

  Future<_Hit?> _searchWikipedia(String query, List<String> tokens) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'search',
      'gsrsearch': query,
      'gsrnamespace': '0',
      'gsrlimit': '8',
      'prop': 'pageimages',
      'piprop': 'thumbnail',
      'pithumbsize': '700',
      'format': 'json',
      'formatversion': '2',
    });
    final response = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('Wikipedia ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final q = data is Map ? data['query'] : null;
    final pages = q is Map ? q['pages'] : null;
    if (pages is! List) return null;

    final sorted = pages.whereType<Map>().toList()
      ..sort((a, b) => ((a['index'] ?? 99) as num).compareTo((b['index'] ?? 99) as num));
    for (final page in sorted) {
      final title = (page['title'] ?? '').toString();
      final thumb = page['thumbnail'];
      final src = (thumb is Map ? thumb['source'] : null)?.toString();
      if (src == null || !src.startsWith('https://')) continue;
      if (!_hasAllTokens(title, tokens)) continue;
      final padded = ' ${_norm(title)} ';
      var otherEdition = false;
      for (final v in _variantWords) {
        if (!tokens.contains(v) && _hasWord(padded, v)) otherEdition = true;
      }
      if (otherEdition) continue;
      return _Hit(src, null, 'wikipedia', 30);
    }
    return null;
  }

  /// Searches Wikimedia Commons image files (many phones have photos there
  /// even when they have no Wikipedia page picture).
  Future<List<_Hit>> _searchCommons(String name, List<String> tokens) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'search',
      'gsrsearch': '$name filetype:bitmap',
      'gsrnamespace': '6',
      'gsrlimit': '12',
      'prop': 'imageinfo',
      'iiprop': 'url|size|mime',
      'iiurlwidth': '700',
      'format': 'json',
      'formatversion': '2',
    });
    final response = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('Commons ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final q = data is Map ? data['query'] : null;
    final pages = q is Map ? q['pages'] : null;
    if (pages is! List) return const [];

    final hits = <_Hit>[];
    for (final page in pages.whereType<Map>()) {
      final title = (page['title'] ?? '').toString();
      final padded = ' ${_norm(title)} ';
      if (!tokens.every((t) => _hasWord(padded, t))) continue;
      if (_rejectWords.any((w) => _hasWord(padded, w))) continue;
      var otherEdition = false;
      for (final v in _variantWords) {
        if (!tokens.contains(v) && _hasWord(padded, v)) otherEdition = true;
      }
      if (otherEdition) continue;
      final infos = page['imageinfo'];
      final info = infos is List && infos.isNotEmpty && infos.first is Map ? infos.first as Map : null;
      if (info == null) continue;
      final mime = (info['mime'] ?? '').toString();
      if (mime != 'image/jpeg' && mime != 'image/png') continue;
      final src = (info['thumburl'] ?? info['url'])?.toString();
      if (src == null || !src.startsWith('https://')) continue;
      var score = 25;
      if (_hasWord(padded, 'back') || _hasWord(padded, 'rear')) score += 20;
      hits.add(_Hit(src, null, 'wikipedia', score));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  }

  // ---------------------------------------------------------------- download

  Future<String?> _saveImage(String key, _Hit hit) async {
    final candidates = <String>[hit.url, if (hit.thumb != null) hit.thumb!];
    for (final url in candidates) {
      try {
        final response = await http.get(Uri.parse(url), headers: {
          'User-Agent': _ua,
          'Accept': 'image/*,*/*;q=0.5',
        }).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) continue;
        final bytes = response.bodyBytes;
        if (bytes.length < 3000 || bytes.length > 8 * 1024 * 1024) continue;
        if (!_looksLikeImage(bytes)) continue;
        final dir = await _dir();
        final name = '$key.img';
        await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
        return name;
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
