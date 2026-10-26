(function(){
  return JSON.stringify({
    rec: (document.getElementById('sh-rec-stat')||{}).textContent||'',
    steps: (document.getElementById('sh-steps')||{}).textContent||'',
    remote: !!document.getElementById('sh-remote').checked,
    btn: (document.getElementById('sh-rec-btn')||{}).textContent||''
  });
})()
