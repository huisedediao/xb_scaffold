(function(){
  document.querySelector('.tab[data-tab="shot"]').click();
  var sel = document.getElementById('vmsel');
  var opts = Array.prototype.map.call(sel.options, function(o){ return {v:o.value, t:o.textContent}; });
  return JSON.stringify({val: sel.value, opts: opts, tip: (document.getElementById('sh-tip')||{}).textContent || '', pageVisible: document.getElementById('page-shot').className});
})()
