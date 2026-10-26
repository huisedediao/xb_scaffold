(function(){
  var b = Array.prototype.filter.call(document.querySelectorAll('#page-shot button'), function(x){ return x.textContent.indexOf('回放当前步骤') >= 0; })[0];
  if (b) b.click();
  return 'play-clicked';
})()
