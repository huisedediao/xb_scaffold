(function(){
  document.querySelector('.tab[data-tab="instances"]').click();
  setTimeout(function(){
    var row = document.querySelector('#in-watch-list .wrow');
    if (!row) { document.getElementById('in-stat').textContent = 'NO_ROW'; return; }
    var btn = row.querySelector('button');
    btn.click();
  }, 600);
  return 'pause-scheduled';
})()
