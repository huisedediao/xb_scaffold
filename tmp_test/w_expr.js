(function(){
  document.querySelector('.tab[data-tab="instances"]').click();
  document.getElementById('in-watch-expr').value = 'DateTime.now().second';
  document.getElementById('in-watch-ms').value = '500';
  document.getElementById('in-watch-cond').value = '';
  setTimeout(function(){
    document.querySelector('#page-instances button[onclick="inWatchExpr()"]').click();
  }, 500);
  return 'expr-scheduled';
})()
