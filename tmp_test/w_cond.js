(function(){
  var rows = document.querySelectorAll('#tl-body .tl-watch');
  var hit = null;
  for (var i = rows.length - 1; i >= 0; i--) {
    if ((rows[i].innerText || '').indexOf('条件命中') >= 0) { hit = rows[i]; break; }
  }
  if (!hit) return 'no-cond-row';
  hit.click();
  var opens = document.querySelectorAll('#tl-body .tl-watch.tl-open');
  var out = [];
  for (var j = 0; j < opens.length; j++) {
    var det = opens[j].nextElementSibling;
    if (det && det.classList.contains('tl-detail') && (opens[j].innerText||'').indexOf('条件命中') >= 0) {
      out = Array.prototype.map.call(det.querySelectorAll('a'), function(a){ return (a.getAttribute('href')||'') + ' | ' + a.textContent; });
      return JSON.stringify({text: det.innerText.slice(0, 220), links: out});
    }
  }
  return 'detail-not-found';
})()
