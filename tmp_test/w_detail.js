(function(){
  var rows = document.querySelectorAll('#tl-body .tl-watch');
  if (!rows.length) return 'no-watch-rows';
  rows[rows.length - 1].click();
  var d = document.querySelectorAll('#tl-body .tl-detail');
  var t = d.length ? d[d.length - 1] : null;
  if (!t) return 'no-detail';
  var links = Array.prototype.map.call(t.querySelectorAll('a'), function(a){ return a.getAttribute('href') + ' | ' + a.textContent; });
  return JSON.stringify({text: (t.innerText || '').slice(0, 260), links: links});
})()
