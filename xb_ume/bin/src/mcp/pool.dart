// 服务池：最多 5 个 MCP 实例，每个实例带一个绑定标识（`b-7f3a9c21`）。
//
// 客户端永远只连**池入口**（默认 46140，见 router.dart）。入口按「连接」分配后端：
//   1. 这条连接已经绑着某个槽 → 续期，继续用它（当前会话不丢）；
//   2. 有槽空闲（没人绑 / 绑定过期 / 进程已死）→ 绑给它，**杀掉残留进程、
//      拉起一个全新实例**（严格模式：一个绑定 = 一个干净进程）；
//   3. 没有空闲但池没满 → 拉起新实例再绑；
//   4. 5 个都被别人绑着 → 不创建，直接回「需要排队」（谁占着 / 在干什么 / 还剩多久）。
//
// 严格模式：解绑就停掉实例，重绑一定是新进程。理由：会话选择、场景运行状态、
// 租约归属都只在原进程里，复用会让下一个人看到上一个人留下的状态（场景状态
// 还是进程级全局）。代价是每次重绑多一次拉起（实测约 1.3 秒）。
//
// 绑定 = 一条带 TTL 的记录：默认 10 分钟，每次工具调用续期，进程退出即失效。
// 落盘 $XB_UME_HOME/pool/slot-<n>.json；GUI 是单文件部署、不 import bin/src，
// 它直接读同一份目录，所以字段名必须一致。
//
// 读-改-写用 $XB_UME_HOME/pool/.lock 独占文件保护：入口、5 个实例、GUI 都会碰
// 这几个文件，没锁会出现「两个连接抢到同一个槽」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../device/live_store.dart' show pidAlive;
import '../paths.dart';
import 'client_scope.dart' show shortMcpClient;

/// 池上限：一台机器同时最多几个 MCP 实例。
const int kPoolMax = 5;

/// 绑定默认有效期；每次工具调用续期。
const Duration kPoolBindingTtl = Duration(minutes: 10);

/// 续期写盘的最小间隔：工具调用很密，但没必要每次都写文件。
const Duration kPoolRenewMinGap = Duration(seconds: 20);

/// 池上限（可用 XB_UME_POOL_MAX 覆盖，1..9；端口段 46140-46149 只有 10 个）。
int poolMax() {
  final v = int.tryParse(Platform.environment['XB_UME_POOL_MAX'] ?? '');
  if (v == null) return kPoolMax;
  return v < 1 ? 1 : (v > 9 ? 9 : v);
}

/// 池实例默认名字：pool-1..pool-5。
String poolSlotName(int slot) => 'pool-$slot';

/// 绑定标识（给人和 AI 引用：「我绑在 b-7f3a9c21」）。
String newBindingId() =>
    'b-${Random().nextInt(0x1000000).toRadixString(16).padLeft(6, '0')}';

/// 一个槽 = 一个 MCP 实例 + 可能的一条绑定。
class PoolSlot {
  PoolSlot({
    required this.slot,
    this.name = '',
    this.port = 0,
    this.pid = 0,
    this.bindingId = '',
    this.owner = '',
    this.client = '',
    this.boundAt,
    this.renewedAt,
    this.ttlMs = 600000,
    this.note = '',
    this.error = '',
    this.running = false,
  });

  final int slot;

  /// 实例名（pool-<n>）；还没拉起时为空。
  final String name;
  final int port;
  final int pid;

  /// 绑定标识；空串 = 这个槽没人绑。
  final String bindingId;

  /// 绑给谁（人读）：`Qoder（…b3f2a1）`。
  final String owner;

  /// 绑给哪条连接（HTTP = 入口签发的 Mcp-Session-Id）。
  ///
  /// 入口按连接分配，所以「同一个 AI 开两个窗口」= 两条连接 = 两个槽：
  /// 这里存的是连接标识，不是客户端名字。
  final String client;

  final DateTime? boundAt;
  final DateTime? renewedAt;
  final int ttlMs;

  /// 最近一次用它干了什么（工具名），排队提示里给对面看。
  final String note;

  /// 拉起失败原因（有值时这个槽不可用）。
  final String error;

  /// 这个实例里有没有未结束的自动化场景（worker 定时上报）。
  ///
  /// 回收扫描看到它就只续期、不回收，避免把跑到一半的场景腰斩。
  final bool running;

  DateTime? get expiresAt =>
      renewedAt?.add(Duration(milliseconds: ttlMs));

  int leftMs(DateTime now) =>
      expiresAt == null ? 0 : expiresAt!.difference(now).inMilliseconds;

  bool live(bool Function(int) alive) => pid > 0 && alive(pid);

  /// 绑定是否仍然有效：有标识 + 没过期 + 持有者进程还活着。
  ///
  /// `pid == 0` 是「刚分配、入口正在拉起」的中间态：算有效，否则另一条连接
  /// 会在拉起完成前把这个槽抢走。
  bool isBoundAt(DateTime now, bool Function(int) alive) =>
      bindingId.isNotEmpty &&
      renewedAt != null &&
      now.isBefore(expiresAt!) &&
      (pid == 0 || alive(pid));

  Map<String, Object?> toJson({DateTime? now, bool? mine}) {
    final n = now ?? DateTime.now();
    return <String, Object?>{
      'slot': slot,
      'name': name,
      'port': port,
      'pid': pid,
      'bindingId': bindingId,
      'owner': owner,
      'client': client,
      'boundAt': boundAt?.toIso8601String(),
      'renewedAt': renewedAt?.toIso8601String(),
      'ttlMs': ttlMs,
      'expiresAt': expiresAt?.toIso8601String(),
      if (bindingId.isNotEmpty) 'leftMs': leftMs(n),
      'note': note,
      if (running) 'running': true,
      if (error.isNotEmpty) 'error': error,
      if (mine != null) 'mine': mine,
    };
  }

  PoolSlot copyWith({
    String? name,
    int? port,
    int? pid,
    String? bindingId,
    String? owner,
    String? client,
    DateTime? boundAt,
    DateTime? renewedAt,
    int? ttlMs,
    String? note,
    String? error,
    bool? running,
    bool clearBinding = false,
  }) =>
      PoolSlot(
        slot: slot,
        name: name ?? this.name,
        port: port ?? this.port,
        pid: pid ?? this.pid,
        bindingId: clearBinding ? '' : (bindingId ?? this.bindingId),
        owner: clearBinding ? '' : (owner ?? this.owner),
        client: clearBinding ? '' : (client ?? this.client),
        boundAt: clearBinding ? null : (boundAt ?? this.boundAt),
        renewedAt: clearBinding ? null : (renewedAt ?? this.renewedAt),
        ttlMs: ttlMs ?? this.ttlMs,
        note: note ?? this.note,
        error: error ?? this.error,
        running: running ?? this.running,
      );

  static PoolSlot? parse(int slot, Object? raw) {
    if (raw is! Map) return null;
    return PoolSlot(
      slot: int.tryParse('${raw['slot'] ?? slot}') ?? slot,
      name: '${raw['name'] ?? ''}',
      port: int.tryParse('${raw['port'] ?? ''}') ?? 0,
      pid: int.tryParse('${raw['pid'] ?? ''}') ?? 0,
      bindingId: '${raw['bindingId'] ?? ''}',
      owner: '${raw['owner'] ?? ''}',
      client: '${raw['client'] ?? ''}',
      boundAt: DateTime.tryParse('${raw['boundAt'] ?? ''}'),
      renewedAt: DateTime.tryParse('${raw['renewedAt'] ?? ''}'),
      ttlMs: int.tryParse('${raw['ttlMs'] ?? ''}') ??
          kPoolBindingTtl.inMilliseconds,
      note: '${raw['note'] ?? ''}',
      error: '${raw['error'] ?? ''}',
      running: raw['running'] == true,
    );
  }
}

/// 池仓库：槽位分配、绑定续期、释放、接管。
class PoolStore {
  PoolStore({
    String? home,
    int? max,
    DateTime Function()? now,
    bool Function(int pid)? pidAliveFn,
    void Function(int pid)? killFn,
  })  : home = home ?? xbUmeHome(),
        max = max ?? poolMax(),
        _now = now ?? DateTime.now,
        _alive = pidAliveFn ?? pidAlive,
        _kill = killFn ?? _sigterm;

  final String home;
  final int max;
  final DateTime Function() _now;
  final bool Function(int pid) _alive;

  /// 回收实例用：只发 SIGTERM 到精确 pid，绝不按名字/命令行杀（本机常驻
  /// 用户自己的 flutter 工具进程，模式匹配容易误伤）。
  final void Function(int pid) _kill;

  static void _sigterm(int pid) {
    try {
      Process.killPid(pid, ProcessSignal.sigterm);
    } catch (_) {}
  }

  Directory get _dir {
    final d = Directory('$home/pool');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  File _file(int slot) => File('${_dir.path}/slot-$slot.json');

  // ── 读 ──

  /// 1..max 的完整槽位视图（缺文件的补空槽，不落盘）。
  List<PoolSlot> list() {
    final out = <PoolSlot>[];
    for (var i = 1; i <= max; i++) {
      out.add(_read(i) ?? PoolSlot(slot: i));
    }
    return out;
  }

  PoolSlot? _read(int slot) {
    try {
      final f = _file(slot);
      if (!f.existsSync()) return null;
      return PoolSlot.parse(slot, jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return null; // 半截文件 / 手改坏了：当空槽，下一次绑定会覆盖。
    }
  }

  /// 这条连接绑在哪个槽（没有则 null；返回的记录可能已过期，用 [isBound] 判断）。
  PoolSlot? mine(String client) {
    if (client.isEmpty) return null;
    for (final s in list()) {
      if (s.bindingId.isNotEmpty && s.client == client) return s;
    }
    return null;
  }

  bool isBound(PoolSlot s) => s.isBoundAt(_now(), _alive);

  List<PoolSlot> boundSlots() => list().where(isBound).toList();

  /// 最久没续期的那个绑定（steal 默认目标）。
  PoolSlot? oldestBound() {
    final b = boundSlots();
    if (b.isEmpty) return null;
    b.sort((x, y) => (x.renewedAt ?? DateTime(0))
        .compareTo(y.renewedAt ?? DateTime(0)));
    return b.first;
  }

  /// 池状态（工具 / 入口 / GUI 共用一份结构）。
  Map<String, Object?> status({String? mine}) {
    final now = _now();
    final slots = <Map<String, Object?>>[];
    var bound = 0;
    for (final s in list()) {
      final isMine = mine != null && mine.isNotEmpty && s.client == mine;
      final b = s.isBoundAt(now, _alive);
      if (b) bound++;
      slots.add(<String, Object?>{
        ...s.toJson(now: now, mine: isMine),
        'state': b ? 'bound' : (s.live(_alive) ? 'idle' : 'empty'),
      });
    }
    return <String, Object?>{
      'max': max,
      'bound': bound,
      'free': max - bound,
      'slots': slots,
    };
  }

  // ── 写 ──

  /// 分配：自己已绑 → 续期；否则挑一个空闲槽并绑上；没有空闲返回 null（池满）。
  ///
  /// 严格模式：空闲槽不继承上一个连接留下的进程。残留进程先杀掉，返回的槽
  /// `pid` 一定是 0，由调用方拉起全新的 worker（场景状态/订阅/租约都只在原
  /// 进程里，复用等于把上一个人的状态交给下一个人）。
  Future<PoolSlot?> allocate({
    required String owner,
    required String client,
    String note = '',
  }) async {
    return _withLock(() {
      final now = _now();
      final slots = list();
      for (final s in slots) {
        if (client.isEmpty || s.bindingId.isEmpty || s.client != client) continue;
        // 有场景在跑的槽即使绑定过期也续上（等它跑完再收）。
        if (s.running || s.isBoundAt(now, _alive)) {
          return _renewLocked(s, owner: owner, note: note, now: now);
        }
        // 过期绑定不复活：落到下面按空闲槽处理（残留进程会被杀掉）。
      }
      final free = slots.where((s) => !s.isBoundAt(now, _alive)).toList();
      if (free.isEmpty) return null;
      // 优先空着 / 进程已死的槽（不用杀活的），按槽号从小到大。
      var target = free.firstWhere(
        (s) => s.pid == 0 || !_alive(s.pid),
        orElse: () => free.first,
      );
      if (target.pid > 0) {
        _kill(target.pid);
        target = PoolSlot(slot: target.slot, name: target.name, ttlMs: target.ttlMs);
        _write(target);
      }
      return _bindLocked(target, owner: owner, client: client, note: note, now: now);
    });
  }

  /// 把指定槽绑给 [client]：接管（steal）/ 指定槽时用。
  Future<PoolSlot?> bindTo(
    int slot, {
    required String owner,
    required String client,
    String note = '',
    bool killWorker = false,
  }) async {
    if (slot < 1 || slot > max) return null;
    return _withLock(() {
      var s = _read(slot) ?? PoolSlot(slot: slot);
      if (killWorker && s.pid > 0) {
        _kill(s.pid);
        s = PoolSlot(slot: slot, name: s.name, ttlMs: s.ttlMs);
      }
      return _bindLocked(s, owner: owner, client: client, note: note, now: _now());
    });
  }

  /// 补上 worker 的端口与 pid（拉起成功后调用）。
  Future<void> attachWorker(
    int slot, {
    required String name,
    required int port,
    required int pid,
  }) async {
    await _withLock(() {
      final s = _read(slot);
      if (s == null) return;
      _write(s.copyWith(name: name, port: port, pid: pid, error: ''));
    });
  }

  /// 记录拉起失败（这个槽仍可被下一次分配尝试）。
  Future<void> markError(int slot, String error) async {
    await _withLock(() {
      final s = _read(slot);
      if (s == null) return;
      _write(s.copyWith(pid: 0, port: 0, error: error));
    });
  }

  /// 续期：只有绑定的持有者能续；写盘按 [kPoolRenewMinGap] 限频。
  Future<PoolSlot?> renewFor(String client, {String note = ''}) async {
    if (client.isEmpty) return null;
    return _withLock(() {
      final s = mine(client);
      if (s == null) return null;
      return _renewLocked(s, owner: s.owner, note: note, now: _now());
    });
  }

  /// 释放这条连接的绑定，并停掉实例（严格模式：下次重绑一定是新进程）。
  Future<bool> releaseFor(String client, {bool stopWorker = true}) async {
    if (client.isEmpty) return false;
    return _withLock(() {
      final s = mine(client);
      if (s == null) return false;
      if (stopWorker && s.pid > 0) _kill(s.pid);
      _write(PoolSlot(slot: s.slot, name: s.name, ttlMs: s.ttlMs));
      return true;
    });
  }

  /// 释放指定槽（force 时不看是谁的，GUI / steal 用）；默认连着进程一起停。
  Future<bool> releaseSlot(
    int slot, {
    bool force = false,
    String client = '',
    bool stopWorker = true,
  }) async {
    if (slot < 1 || slot > max) return false;
    return _withLock(() {
      final s = _read(slot);
      if (s == null) return false;
      if (!force &&
          s.bindingId.isNotEmpty &&
          (client.isEmpty || s.client != client)) {
        return false;
      }
      if (stopWorker && s.pid > 0) _kill(s.pid);
      _write(PoolSlot(slot: s.slot, name: s.name, ttlMs: s.ttlMs));
      return true;
    });
  }

  /// worker 上报自己槽里有没有未结束的自动化场景。
  Future<void> markRunning(int slot, bool running) async {
    if (slot < 1 || slot > max) return;
    await _withLock(() {
      final s = _read(slot);
      if (s == null || s.running == running) return;
      _write(s.copyWith(running: running));
    });
  }

  /// 回收扫描：过期绑定 / 残留进程 / 已死进程一律清掉，槽归零。
  ///
  /// 有场景在跑的槽只滚动续期、不回收（否则跑到一半的自动化会被腰斩）。
  /// 入口每 30 秒调一次；返回这一轮收了几个槽。
  Future<int> sweep() async {
    return _withLock(() {
      final now = _now();
      var n = 0;
      for (final s in list()) {
        if (s.running) {
          if (s.bindingId.isNotEmpty && s.renewedAt != null) {
            _write(s.copyWith(renewedAt: now));
          }
          continue;
        }
        if (s.isBoundAt(now, _alive)) continue;
        if (s.bindingId.isEmpty && s.pid == 0 && s.error.isEmpty) continue;
        if (s.pid > 0) _kill(s.pid);
        _write(PoolSlot(slot: s.slot, name: s.name, ttlMs: s.ttlMs));
        n++;
      }
      return n;
    });
  }

  // ── 内部 ──

  PoolSlot _bindLocked(
    PoolSlot s, {
    required String owner,
    required String client,
    required String note,
    required DateTime now,
  }) {
    final next = s.copyWith(
      bindingId: newBindingId(),
      owner: owner.isEmpty ? '未署名客户端' : owner,
      client: client,
      boundAt: now,
      renewedAt: now,
      ttlMs: _ttl.inMilliseconds,
      note: note,
      error: '',
    );
    _write(next);
    return next;
  }

  PoolSlot _renewLocked(
    PoolSlot s, {
    required String owner,
    required String note,
    required DateTime now,
  }) {
    final fresh = s.renewedAt != null &&
        now.difference(s.renewedAt!) < kPoolRenewMinGap;
    // 限频：20 秒内不再写盘（note 最多滞后 20 秒，对排队提示够用）。
    if (fresh) return s;
    final next = s.copyWith(
      owner: owner.isEmpty ? s.owner : owner,
      renewedAt: now,
      note: note.isEmpty ? s.note : note,
    );
    _write(next);
    return next;
  }

  Duration get _ttl {
    final ms = int.tryParse(Platform.environment['XB_UME_BIND_TTL_MS'] ?? '');
    if (ms == null || ms <= 0) return kPoolBindingTtl;
    return Duration(milliseconds: ms);
  }

  void _write(PoolSlot s) {
    final f = _file(s.slot);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(s.toJson(now: _now())));
    tmp.renameSync(f.path);
  }

  /// 独占文件锁：入口 / 5 个实例 / GUI 同时改池时只有一个能进临界区。
  Future<T> _withLock<T>(T Function() body) async {
    final lock = File('${_dir.path}/.lock');
    var held = false;
    for (var i = 0; i < 100; i++) {
      try {
        lock.createSync(exclusive: true);
        held = true;
        break;
      } on FileSystemException {
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

/// 「还有 9 分钟」这类剩余时间描述。
String poolLeft(DateTime? expiresAt, {DateTime? now}) {
  if (expiresAt == null) return '已过期';
  final ms = expiresAt.difference(now ?? DateTime.now()).inMilliseconds;
  if (ms <= 0) return '已过期';
  if (ms < 60000) return '${(ms / 1000).ceil()} 秒';
  return '${(ms / 60000).ceil()} 分钟';
}

/// 单个槽的一行描述（工具输出 / GUI 提示共用）。
String poolSlotLine(Map<String, Object?> slot, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final no = slot['slot'];
  final name = '${slot['name'] ?? ''}';
  final port = int.tryParse('${slot['port'] ?? 0}') ?? 0;
  final where = name.isEmpty
      ? (port > 0 ? '$port' : '未启动')
      : (port > 0 ? '$name:$port' : name);
  final mine = slot['mine'] == true;
  final b = '${slot['bindingId'] ?? ''}';
  final running = slot['running'] == true;
  if (b.isEmpty) {
    return '槽 $no  $where  ·  空闲${running ? '（有场景在跑，暂不回收）' : ''}';
  }
  final left = poolLeft(DateTime.tryParse('${slot['expiresAt'] ?? ''}'), now: n);
  final note = '${slot['note'] ?? ''}';
  final err = '${slot['error'] ?? ''}';
  return '槽 $no  $where  ·  $b  ${slot['owner']}${mine ? '（你）' : ''}'
      '${note.isEmpty ? '' : ' · 在 $note'}${running ? ' · 跑着场景' : ''} · 还剩 $left'
      '${err.isEmpty ? '' : ' · 拉起失败：$err'}';
}

/// 池满时的排队说明：谁占着、在干什么、还剩多久、三条出路。
///
/// 入口（router.dart）与工具（xbume_pool）共用这一份文案，避免两边说得不一样。
String poolBusyText(PoolStore pool, {String? mineClient}) {
  final st = pool.status(mine: mineClient);
  final now = DateTime.now();
  final slots = (st['slots'] as List<Object?>).cast<Map<String, Object?>>();
  final bound = slots.where((s) => '${s['bindingId'] ?? ''}'.isNotEmpty).toList();
  final sb = StringBuffer();
  sb.writeln('服务池已满（${st['bound']}/${st['max']} 个实例都被别的会话绑着），'
      '这次没有分到实例。');
  for (final s in bound) {
    sb.writeln('· ${poolSlotLine(s, now: now)}');
  }
  DateTime? soonest;
  for (final s in bound) {
    final at = DateTime.tryParse('${s['expiresAt'] ?? ''}');
    if (at == null) continue;
    if (soonest == null || at.isBefore(soonest)) soonest = at;
  }
  sb.writeln('三条出路：');
  sb.writeln('1) 等：它们不再调用工具约 ${kPoolBindingTtl.inMinutes} 分钟后自动回池'
      '（最近一个${poolLeft(soonest)}后就能用），到时再试一次；');
  sb.writeln('2) 让对面收工：对方 xbume_pool{"op":"release"} 立刻空出它的槽；');
  sb.writeln('3) 确认对面已停手：xbume_pool{"op":"steal","slot":N} 接管最久没动的那个。');
  return sb.toString().trimRight();
}

/// 池操作的可读结果（工具与入口共用）。
///
/// [client] 是这条连接的标识（入口签发的 Mcp-Session-Id / stdio）；
/// [owner] 是给人和 AI 看的名字（`Qoder（…b3f2a1）`）。
Future<String> poolOpText({
  required PoolStore pool,
  required String client,
  required String owner,
  required String op,
  int? slot,
  int entryPort = 0,
  DateTime? now,
}) async {
  final n = now ?? DateTime.now();
  switch (op) {
    case 'release':
      final ok = await pool.releaseFor(client);
      return ok
          ? '已释放你的绑定，并停掉了那个实例。下次调用会重新拉起一个全新实例'
              '（约 1~2 秒），当前会话需要重新 xbume_use_session。'
          : '你当前没有绑定任何实例（xbume_pool{"op":"status"} 查看池状态）。';
    case 'steal':
      var target = slot;
      if (target == null) {
        final oldest = pool.oldestBound();
        if (oldest == null) return '池里没有别人绑着的实例，不需要接管。';
        target = oldest.slot;
      }
      if (target < 1 || target > pool.max) {
        return '槽 $target 不存在（1..${pool.max}）。';
      }
      final prev = pool.list()[target - 1];
      final got = await pool.bindTo(
        target,
        owner: owner,
        client: client,
        note: 'steal',
        killWorker: true,
      );
      if (got == null) return '槽 $target 接管失败。';
      final was = prev.bindingId.isEmpty
          ? '空槽'
          : '${prev.bindingId} ${prev.owner}';
      return '已接管槽 $target（原属 $was），原实例已停掉，下一次调用会给你拉起全新实例。\n'
          '对面下一次调用会看到「已被接管」，需要重新分配或另开一个。';
    case 'status':
    default:
      final st = pool.status(mine: client);
      final slots = (st['slots'] as List<Object?>).cast<Map<String, Object?>>();
      final sb = StringBuffer();
      sb.writeln('服务池 ${st['max']} 个槽 · 已绑 ${st['bound']} · 空闲 ${st['free']}'
          '${entryPort > 0 ? ' · 入口 $entryPort' : ''}'
          ' · 绑定 ${kPoolBindingTtl.inMinutes} 分钟不续期就回池');
      for (final s in slots) {
        sb.writeln('· ${poolSlotLine(s, now: n)}');
      }
      final mySlot = slots.firstWhere(
        (s) => s['mine'] == true,
        orElse: () => const <String, Object?>{},
      );
      if (mySlot.isEmpty) {
        sb.writeln('你：还没绑定实例（下一次工具调用会自动分配）。');
      } else {
        sb.writeln('你：槽 ${mySlot['slot']}（${mySlot['bindingId']}）。');
      }
      return sb.toString().trimRight();
  }
}

/// 短连接标识（`…b3f2a1`），与 [shortMcpClient] 一致，便于对账。
String poolShortClient(String raw) => shortMcpClient(raw);