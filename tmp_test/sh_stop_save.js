(function(){
  var b = document.getElementById('sh-rec-btn');
  if (b.textContent.indexOf('停止') >= 0) b.click();
  document.getElementById('sh-scn-name').value = 'login-remote';
  var saveBtn = Array.prototype.filter.call(document.querySelectorAll('#page-shot button'), function(x){ return x.textContent === '保存场景'; })[0];
  if (saveBtn) saveBtn.click();
  return 'stopped+saved';
})()
