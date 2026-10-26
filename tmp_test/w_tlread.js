(function(){
  var rows = document.querySelectorAll('#tl-body .tl-watch');
  var text = rows.length ? rows[rows.length - 1].innerText : '';
  var first = rows.length ? rows[0].innerText : '';
  var cb = document.getElementById('tl-t-watch');
  return JSON.stringify({watchRows: rows.length, first: first.slice(0, 120), last: text.slice(0, 160), cb: cb ? cb.checked : null, stat: (document.getElementById('tl-stat')||{}).textContent});
})()
