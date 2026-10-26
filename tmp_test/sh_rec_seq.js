(function(){
  var img = document.getElementById('sh-img');
  function pt(type, x, y){
    var r = img.getBoundingClientRect();
    var cx = r.left + x * r.width / img.naturalWidth;
    var cy = r.top + y * r.height / img.naturalHeight;
    img.dispatchEvent(new PointerEvent(type, {clientX: cx, clientY: cy, bubbles: true, cancelable: true, pointerId: 7, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1}));
  }
  function tap(x, y){
    pt('pointerdown', x, y);
    setTimeout(function(){ pt('pointerup', x, y); }, 50);
  }
  function input(text){
    var el = document.getElementById('sh-input');
    el.value = text;
    el.nextElementSibling.click();
  }
  document.getElementById('sh-rec-btn').click();
  var t = 0;
  function at(ms, fn){ t += ms; setTimeout(fn, t); }
  at(400, function(){ tap(317,129); });       // Login Demo
  at(800, function(){ tap(400,239); });       // 账号输入框
  at(500, function(){ input('demo'); });
  at(500, function(){ tap(400,299); });       // 密码输入框
  at(500, function(){ input('123456'); });
  at(500, function(){ tap(400,357); });       // 登录
  return 'scheduled btn=' + document.getElementById('sh-rec-btn').textContent + ' remote=' + document.getElementById('sh-remote').checked;
})()
