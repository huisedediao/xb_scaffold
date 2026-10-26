(function(){
  var rows = document.querySelectorAll('#tl-body .tl-watch');
  var last = rows[rows.length - 1];
  var info = {n: rows.length, html: last ? last.outerHTML.slice(0, 220) : ''};
  if (last) last.click();
  info.details = document.querySelectorAll('#tl-body .tl-detail').length;
  info.open = document.querySelectorAll('#tl-body .tl-watch.tl-open').length;
  return JSON.stringify(info);
})()
