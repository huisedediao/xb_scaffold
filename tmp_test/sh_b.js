(function(){
  var sel = document.getElementById('vmsel');
  sel.value = 'port:56819';
  sel.dispatchEvent(new Event('change', {bubbles:true}));
  var btns = Array.prototype.slice.call(document.querySelectorAll('#page-shot button'));
  var b = btns.filter(function(x){ return x.textContent.indexOf('刷新截图') >= 0; })[0];
  if (b) b.click();
  return 'selected+refresh';
})()
