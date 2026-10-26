(function(){
  var open = document.querySelector('#tl-body .tl-watch.tl-open');
  if (!open) return 'no-open';
  var det = open.nextElementSibling;
  var ok = det && det.classList.contains('tl-detail');
  var links = ok ? Array.prototype.map.call(det.querySelectorAll('a'), function(a){ return (a.getAttribute('href')||'') + ' | ' + a.textContent; }) : [];
  return JSON.stringify({detail: ok, text: ok ? det.innerText.slice(0, 240) : '', links: links});
})()
