// 会话 / 启动租约：跨 MCP 实例（跨进程）的唯一互斥点。
//
// 为什么需要文件租约：「一 AI 一个 MCP 进程」之后，「当前会话」天然按进程隔离，
// 但两个进程仍可能驱动同一个 app（点按 / 热重载 / 场景回放），或抢同一个项目的
// flutter run（force 重启会顶掉对方的会话）。进程内互斥挡不住这些，所以把
// 「谁在驱动」落到 $XB_UME_HOME/leases/<key>.json：
//   - 写操作前 acquire：空闲就静默拿到；被别人持有则返回 holder（谁、什么时候
//     续期、还有多久过期），由工具层给出可读的 busy 报错；
//   - 每次写操作 renew，默认 10 分钟 TTL——AI 崩了 / 忘释放也不会把会话锁死；
//   - release 立即释放；换会话时释放其余租约；
//   - 持有者 pid 不存活视为过期（进程退出即失效）。
// 读操作不碰租约：第二个 AI 可以只读旁观（截图 / 时间线 / 断点状态），
// 这样「别人正在排查，我看看现象」不会被挡住。
//
// 读-改-写用同名 .lock 独占文件保护，避免两个进程同时 acquire 都成功。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../device/live_store.dart' show pidAlive;
import '../paths.dart';
import 'client_scope.dart' show currentMcpClient, shortMcpClient;

/// 租约默认有效期；每次写操作续期。
const Duration kDefaultLeaseTtl = Duration(minutes: 10);

/// 租约 key 落盘名：[key] 里可能有 `:` `/` 等，统一换成 `_`。
String leaseKeySafe(String raw) =>
    raw.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

/// 稳定的短哈希（不依赖 String.hashCode 的实现细节）。
String leaseKeyHash(String raw) {
  var h = 0x811c9dc5;
  for (final c in raw.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  return h.toRadixString(16).padLeft(7, '0');
}

/// 谁在持有租约：一个 MCP 实例（进程）里的**一条客户端连接**。
class LeaseOwner {
  const LeaseOwner({
    required this.instance,
    required this.pid,
    this.port = 0,
    this.client = '',
  });

  final String instance;
  final int pid;

  /// HTTP 实例的端口；stdio 实例为 0。
  final int port;

  /// 同一实例内的连接标识（HTTP = 短 Mcp-Session-Id，stdio = `stdio`）。
  ///
  /// 同一个 AI 开两个窗口连到**同一个**进程时，实例名 / pid / 端口全一样：
  /// 不带这一维，第二次写会被当成「自己续期」而静默放行，两边互相打乱现场。
  final String client;

  Map<String, Object?> toJson() => <String, Object?>{
        'instance': instance,
        'pid': pid,
        'port': port,
        'client': client,
      };

  static LeaseOwner? parse(Object? raw) {
    if (raw is! Map) return null;
    final name = '${raw['instance'] ?? ''}';
    final pid = int.tryParse('${raw['pid'] ?? ''}');
    if (name.isEmpty || pid == null) return null;
    return LeaseOwner(
      instance: name,
      pid: pid,
      port: int.tryParse('${raw['port'] ?? ''}') ?? 0,
      client: '${raw['client'] ?? ''}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LeaseOwner &&
      other.instance == instance &&
      other.pid == pid &&
      other.client == client;

  @override
  int get hashCode => instance.hashCode * 31 + pid * 7 + client.hashCode;
}

/// 租约持有者的可读标识：`claude-a:46140`；同实例内不同连接再加短标记。
///
/// 同一个进程里可能有好几个会话（Qoder 两个窗口都连 46140），光看实例名
/// 分不出是哪条连接在驱动，所以把连接短标识一并显示出来。
String ownerLabel(LeaseOwner o) {
  final head = o.port > 0 ? '${o.instance}:${o.port}' : o.instance;
  final c = o.client;
  if (c.isEmpty || c == 'stdio') return head;
  return '$head（连接 …$c）';
}

/// 一份租约。
class Lease {
  Lease({
    required this.key,
    required this.kind,
    required this.owner,
    required this.note,
    required this.ttlMs,
    required this.acquiredAt,
    required this.renewedAt,
  });

  /// `session-s65296` / `launch-<设备>-<cwd 摘要>`。
  final String key;

  /// session / launch。
  final String kind;

  final LeaseOwner owner;

  /// 最近一次写操作在干什么（tap / hot_reload / scenario_run…）。
  final String note;

  final int ttlMs;
  final DateTime acquiredAt;
  final DateTime renewedAt;

  DateTime get expiresAt => renewedAt.add(Duration(milliseconds: ttlMs));

  /// 到期还剩多少毫秒（已过期则为负）。
  int leftMsAt(DateTime now) => expiresAt.difference(now).inMilliseconds;

  Map<String, Object?> toJson({DateTime? now, String? mine}) => <String, Object?>{
        'key': key,
        'kind': kind,
        'owner': owner.toJson(),
        'note': note,
        'ttlMs': ttlMs,
        'acquiredAt': acquiredAt.toIso8601String(),
        'renewedAt': renewedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        if (now != null) 'leftMs': leftMsAt(now),
        if (mine != null) 'mine': owner.instance == mine,
      };

  static Lease? parse(String key, Object? raw) {
    if (raw is! Map) return null;
    final owner = LeaseOwner.parse(raw['owner']);
    final renewed = DateTime.tryParse('${raw['renewedAt'] ?? ''}');
    if (owner == null || renewed == null) return null;
    return Lease(
      key: '${raw['key'] ?? key}',
      kind: '${raw['kind'] ?? 'session'}',
      owner: owner,
      note: '${raw['note'] ?? ''}',
      ttlMs: int.tryParse('${raw['ttlMs'] ?? ''}') ?? kDefaultLeaseTtl.inMilliseconds,
      acquiredAt: DateTime.tryParse('${raw['acquiredAt'] ?? ''}') ?? renewed,
      renewedAt: renewed,
    );
  }
}

/// acquire 的结果：要么拿到（[lease]），要么被别人占着（[holder]）。
class LeaseAttempt {
  const LeaseAttempt._({this.lease, this.holder});

  factory LeaseAttempt.got(Lease lease) => LeaseAttempt._(lease: lease);

  factory LeaseAttempt.busy(Lease holder) => LeaseAttempt._(holder: holder);

  final Lease? lease;
  final Lease? holder;

  bool get ok => lease != null;
}

/// 租约仓库。一个 MCP 实例持有一个，owner 就是自己。
class LeaseStore {
  LeaseStore({
    required this.instance,
    required this.instancePid,
    this.instancePort = 0,
    String? home,
    DateTime Function()? now,
    bool Function(int pid)? pidAliveFn,
  })  : home = home ?? xbUmeHome(),
        _now = now ?? DateTime.now,
        _alive = pidAliveFn ?? pidAlive;

  final String instance;
  final int instancePid;
  final int instancePort;
  final String home;

  final DateTime Function() _now;
  final bool Function(int pid) _alive;

  /// 自己 = 本实例 + 本条客户端连接（同一实例的两个窗口互不冒充）。
  LeaseOwner get me => LeaseOwner(
        instance: instance,
        pid: instancePid,
        port: instancePort,
        client: shortMcpClient(currentMcpClient),
      );

  Directory get _dir {
    final d = Directory('$home/leases');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  File _fileOf(String key) => File('${_dir.path}/${leaseKeySafe(key)}.json');

  /// 会话租约 key（按会话 id）。
  static String sessionKey(String sessionId) => 'session-$sessionId';

  /// 启动租约 key（按设备 + 项目目录）。两个 AI 拉同一个项目会撞在这里。
  static String launchKey(String deviceId, String cwd) =>
      'launch-$deviceId-${leaseKeyHash(cwd)}';

  /// 读一份租约；已过期（TTL 到 / 持有者进程没了）就当没有并清掉。
  Lease? peek(String key) {
    final l = _read(key);
    if (l == null) return null;
    if (!_alive(l.owner.pid) || !_now().isBefore(l.expiresAt)) {
      _delete(key);
      return null;
    }
    return l;
  }

  /// 本机所有有效租约（已过期的顺手清掉），最近续期的在前。
  List<Lease> list() {
    final out = <Lease>[];
    try {
      for (final e in _dir.listSync()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final key = e.uri.pathSegments.last.replaceAll('.json', '');
        final l = peek(key);
        if (l != null) out.add(l);
      }
    } catch (_) {
      // 目录读不了就当没有租约。
    }
    out.sort((a, b) => b.renewedAt.compareTo(a.renewedAt));
    return out;
  }

  /// 拿租约：自己已持有则续期；空闲则新拿；被别人占着返回 holder。
  ///
  /// [steal] 用于「我明确要接管」；[wait] 给了就轮询等待对方释放（最多等到期限）。
  Future<LeaseAttempt> acquire(
    String key, {
    String kind = 'session',
    String note = '',
    Duration? ttl,
    bool steal = false,
    Duration? wait,
  }) async {
    final deadline = wait == null ? null : _now().add(wait);
    while (true) {
      final a = await _attempt(
        key,
        kind: kind,
        note: note,
        ttl: ttl ?? kDefaultLeaseTtl,
        steal: steal,
      );
      if (a.ok || deadline == null || !_now().isBefore(deadline)) return a;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 续期（只有自己的租约才写）；没有或不归自己返回 null。
  Future<Lease?> renew(String key, {String? note}) async {
    return _withLock(key, () {
      final cur = _read(key);
      if (cur == null || cur.owner != me) return null;
      final now = _now();
      final next = Lease(
        key: cur.key,
        kind: cur.kind,
        owner: me,
        note: note == null || note.isEmpty ? cur.note : note,
        ttlMs: cur.ttlMs,
        acquiredAt: cur.acquiredAt,
        renewedAt: now,
      );
      _write(next);
      return next;
    });
  }

  /// 释放自己的租约；不是自己持有的返回 false（绝不删别人的）。
  Future<bool> release(String key) async {
    return _withLock(key, () {
      final cur = _read(key);
      if (cur == null) return true;
      if (cur.owner != me) return false;
      _delete(key);
      return true;
    });
  }

  /// 释放本实例持有的其余租约（换会话 / 结束调试时用）。
  Future<List<String>> releaseOthers({String? keep}) async {
    final released = <String>[];
    for (final l in list()) {
      if (l.owner != me) continue;
      if (keep != null && l.key == keep) continue;
      if (await release(l.key)) released.add(l.key);
    }
    return released;
  }

  // ── 内部：读 / 写 / 锁 ──

  Lease? _read(String key) {
    final f = _fileOf(key);
    try {
      if (!f.existsSync()) return null;
      return Lease.parse(key, jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return null; // 半截文件 / 手改坏了：当没有，下一次 acquire 会覆盖。
    }
  }

  void _write(Lease l) {
    final f = _fileOf(l.key);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(l.toJson()));
    tmp.renameSync(f.path);
  }

  void _delete(String key) {
    try {
      final f = _fileOf(key);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // 删不掉就等 TTL 过期。
    }
  }

  Future<LeaseAttempt> _attempt(
    String key, {
    required String kind,
    required String note,
    required Duration ttl,
    required bool steal,
  }) async {
    return _withLock(key, () {
      final cur = _read(key);
      final valid = cur != null &&
          _alive(cur.owner.pid) &&
          _now().isBefore(cur.expiresAt);
      if (valid && !steal && cur.owner != me) {
        return LeaseAttempt.busy(cur);
      }
      final now = _now();
      final next = Lease(
        key: key,
        kind: kind,
        owner: me,
        note: note.isEmpty ? (cur?.note ?? '') : note,
        ttlMs: ttl.inMilliseconds,
        // 自己续期时保留最初拿到的时间，便于看清「占了多久」。
        acquiredAt: (valid && cur.owner == me) ? cur.acquiredAt : now,
        renewedAt: now,
      );
      _write(next);
      return LeaseAttempt.got(next);
    });
  }

  /// 独占文件锁：两个进程同时 acquire 时只有一个能进临界区。
  Future<T> _withLock<T>(String key, T Function() body) async {
    final lock = File('${_dir.path}/${leaseKeySafe(key)}.lock');
    var held = false;
    for (var i = 0; i < 100; i++) {
      try {
        lock.createSync(exclusive: true);
        held = true;
        break;
      } on FileSystemException {
        // 上一个持有者崩了会留下陈旧锁：超过 5 秒当作无效。
        try {
          if (_now().difference(lock.lastModifiedSync()) >
              const Duration(seconds: 5)) {
            lock.deleteSync();
            continue;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    try {
      return body();
    } finally {
      if (held) {
        try {
          lock.deleteSync();
        } catch (_) {}
      }
    }
  }
}

/// 「3 分钟前」这类人读描述。
String leaseAgo(DateTime at, {DateTime? now}) {
  final ms = (now ?? DateTime.now()).difference(at).inMilliseconds;
  if (ms < 5000) return '刚刚';
  if (ms < 60000) return '${(ms / 1000).round()} 秒前';
  if (ms < 3600000) return '${(ms / 60000).round()} 分钟前';
  return '${(ms / 3600000).toStringAsFixed(1)} 小时前';
}

/// 「还有 9 分钟」这类剩余时间描述。
String leaseLeft(Lease l, {DateTime? now}) {
  final ms = l.leftMsAt(now ?? DateTime.now());
  if (ms <= 0) return '已过期';
  if (ms < 60000) return '${(ms / 1000).ceil()} 秒';
  return '${(ms / 60000).ceil()} 分钟';
}
