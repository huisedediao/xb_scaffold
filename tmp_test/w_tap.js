(function(){
  var tab = document.querySelector('.tab[data-tab="shot"]');
  tab.click();
  var remote = document.getElementById('sh-remote');
  if (remote && !remote.checked) { remote.checked = true; remote.dispatchEvent(new Event('change', {bubbles:true})); }
  document.querySelector('#page-shot button[onclick="shRefresh()"]').click();
  setTimeout(function(){
    var img = document.getElementById('sh-img');
    function pt(type, x, y){
      var r = img.getBoundingClientRect();
      var cx = r.left + x * r.width / img.naturalWidth;
      var cy = r.top + y * r.height / img.naturalHeight;
      img.dispatchEvent(new PointerEvent(type, {clientX: cx, clientY: cy, bubbles: true, cancelable: true, pointerId: 7, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1}));
    }
    pt('pointerdown', 452, 129);
    setTimeout(function(){ pt('pointerup', 452, 129); }, 60);
  }, 1400);
  return 'tap scheduled';
})()
