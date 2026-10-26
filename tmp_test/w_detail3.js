(function(){
  var rows = document.querySelectorAll('#tl-body .tl-watch');
  var last = rows[rows.length - 1];
  last.click();
  var det = last.nextElementSibling;
  var ok = det && det.classList.contains('tl-detail');
  var links = ok ? Array.prototype.map.call(det.querySelectorAll('a'), function(a){ return (a.getAttribute('href')||'') + ' | ' + a.textContent; }) : [];
  return JSON.stringify({open: document.querySelectorAll('#tl-body .tl-watch.tl-open').length, detail: ok, text: ok ? det.innerText.slice(0, 240) : '', links: links});
})()
