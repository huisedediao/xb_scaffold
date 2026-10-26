(function(){
  document.getElementById('in-watch-ms').value = '200';
  document.getElementById('in-watch-cond').value = '';
  var rows = document.querySelectorAll('#in-tree-body div');
  for (var i = 0; i < rows.length; i++) {
    var t = rows[i].innerText || '';
    if (/^count\s/.test(t)) {
      var a = rows[i].querySelector('a[onclick^="inWatchField("]');
      if (!a) return 'no-link';
      a.click();
      return 'clicked';
    }
  }
  return 'no-row';
})()
