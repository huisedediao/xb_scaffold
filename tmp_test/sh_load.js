(function(){
  var sel = document.getElementById('sh-scn-sel');
  sel.value = 'login-remote';
  var loadBtn = Array.prototype.filter.call(document.querySelectorAll('#page-shot button'), function(x){ return x.textContent === '载入'; })[0];
  if (loadBtn) loadBtn.click();
  return 'load-clicked val=' + sel.value;
})()
