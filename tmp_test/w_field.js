(function(){
  document.getElementById('in-watch-ms').value = '200';
  document.getElementById('in-watch-cond').value = 'count % 10 == 0';
  var rows = document.querySelectorAll('#in-tree-body div');
  for (var i = 0; i < rows.length; i++) {
    var t = rows[i].innerText || '';
    if (/^count\s/.test(t)) {
      var a = rows[i].querySelector('a[onclick^="inWatchField("]');
      if (!a) return 'no-watch-link:' + t;
      a.click();
      return 'watch-clicked:' + t;
    }
  }
  return 'count-row-not-found';
})()
