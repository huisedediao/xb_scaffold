(function(){
  var img = document.getElementById('sh-img');
  var r = img.getBoundingClientRect();
  function cx(x){ return r.left + x * r.width / img.naturalWidth; }
  function cy(y){ return r.top + y * r.height / img.naturalHeight; }
  function pe(type, x, y){
    img.dispatchEvent(new PointerEvent(type, {clientX: cx(x), clientY: cy(y), bubbles: true, cancelable: true, pointerId: 9, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1}));
  }
  pe('pointerdown', 400, 500);
  setTimeout(function(){ pe('pointermove', 400, 420); }, 120);
  setTimeout(function(){ pe('pointermove', 400, 340); }, 240);
  setTimeout(function(){ pe('pointerup', 400, 300); }, 360);
  return 'drag-dispatched remote=' + document.getElementById('sh-remote').checked;
})()
