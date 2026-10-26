// 会话选择保持逻辑单测：复刻 refreshDaemon 中选择状态机（选中保持/指纹找回/
// 掉选自愈/回退保指纹/手动清除/刷新恢复）。run 不依赖 DOM/localStorage 真环境。
function mkState() {
  return {
    vmFilter: '', vmFilterFp: '', vmMiss: 0, store: {},
    load() { return this.store.fp || ''; },
    save(fp) { this.vmFilterFp = fp; fp ? (this.store.fp = fp) : delete this.store.fp; },
  };
}
// st: 状态；ss: 当轮会话列表 [{source,fp}]；sel: 选择器动作记录
function poll(st, ss, sel) {
  sel.value = ''; // 模拟真实 DOM：每轮 innerHTML 重建后 value 归位空
  var prev = st.vmFilter, still = null;
  ss.forEach(function (s) { if (s.source === st.vmFilter) still = s; });
  if (still) {
    st.vmMiss = 0;
    if (still.fp) st.save(still.fp);
    sel.value = st.vmFilter;
  } else {
    var restored = st.vmFilterFp ? ss.find(function (s) { return s.fp === st.vmFilterFp; }) : null;
    if (restored) {
      st.vmFilter = restored.source;
      if (restored.fp) st.save(restored.fp);
      sel.value = st.vmFilter;
      st.vmMiss = 0;
    } else if (st.vmFilter && ++st.vmMiss >= 3) {
      st.vmFilter = ''; st.vmMiss = 0; // 回退保指纹
    }
  }
  return { changed: st.vmFilter !== prev, sel: sel.value || '', filter: st.vmFilter, fp: st.vmFilterFp, stored: st.store.fp || '' };
}
var pass = 0, fail = 0;
function ok(cond, name) { cond ? pass++ : (fail++, console.log('FAIL: ' + name)); }

// 1 正常选中保持
var st = mkState(), sel = {};
st.vmFilter = 'a@5678'; st.save('FP-A');
var r = poll(st, [{ source: 'a@5678', fp: 'FP-A' }], sel);
ok(r.filter === 'a@5678' && r.sel === 'a@5678' && r.stored === 'FP-A', '1 选中保持+指纹落盘');

// 2 瞬断 2 轮（<3）不回退
r = poll(st, [], sel);
ok(r.filter === 'a@5678' && r.sel === '' && !r.changed, '2 瞬断轮保持 vmFilter');
r = poll(st, [], sel);
ok(r.filter === 'a@5678', '3 第二轮瞬断仍未回退');

// 3 端口漂移：source 变化但 fp 相同 → 找回并更新
r = poll(st, [{ source: 'a@9999', fp: 'FP-A' }], sel);
ok(r.filter === 'a@9999' && r.changed && r.sel === 'a@9999', '4 指纹找回端口漂移会话');

// 4 缺失 >3 轮回退显示，但指纹保留
r = poll(st, [], sel); r = poll(st, [], sel); r = poll(st, [], sel);
ok(r.filter === '' && r.fp === 'FP-A' && r.stored === 'FP-A', '5 回退显示但指纹保留');

// 5 同一会话回来 → 自动重选（自愈）
r = poll(st, [{ source: 'a@9999', fp: 'FP-A' }], sel);
ok(r.filter === 'a@9999' && r.changed && r.sel === 'a@9999', '6 掉选后自愈');

// 6 手动选「未选择会话」→ 清指纹，会话回来不自动选
st.vmFilter = ''; st.save('');
r = poll(st, [{ source: 'a@9999', fp: 'FP-A' }], sel);
ok(r.filter === '' && r.stored === '', '7 手动取消后不自动选回');

// 7 页面刷新恢复：新状态从 localStorage 读 fp，首轮自动选回
var st2 = mkState(); st2.store.fp = 'FP-A'; st2.vmFilterFp = st2.load();
r = poll(st2, [{ source: 'a@5678', fp: 'FP-A' }], sel);
ok(r.filter === 'a@5678' && r.changed && r.sel === 'a@5678', '8 刷新后按指纹自动选回');

// 8 换了新会话（fp 不同）→ 不误选
var st3 = mkState(); st3.store.fp = 'FP-OLD'; st3.vmFilterFp = st3.load();
r = poll(st3, [{ source: 'b@1111', fp: 'FP-B' }], sel);
ok(r.filter === '', '9 新实例指纹不同不误选');

// 9 手动选另一会话 → 指纹更新为新会话
var st4 = mkState(); st4.vmFilter = 'a@1'; st4.save('FP-A');
r = poll(st4, [{ source: 'a@1', fp: 'FP-A' }, { source: 'b@2', fp: 'FP-B' }], sel);
// 模拟用户在下拉选 b@2（setVmFilter）
st4.vmFilter = 'b@2'; st4.save('FP-B');
r = poll(st4, [{ source: 'b@2', fp: 'FP-B' }], sel);
ok(r.filter === 'b@2' && r.stored === 'FP-B', '10 切换会话指纹跟随');

console.log('PASS ' + pass + ' / FAIL ' + fail);
process.exit(fail ? 1 : 0);
