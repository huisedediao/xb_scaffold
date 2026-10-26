(function(){
  return JSON.stringify({
    rec: (document.getElementById('sh-rec-stat')||{}).textContent||'',
    steps: (document.getElementById('sh-steps')||{}).innerText||'',
    op: (document.getElementById('sh-op')||{}).textContent||'',
    sel: (document.getElementById('sh-scn-sel')||{}).textContent||'',
    play: (document.getElementById('sh-play')||{}).textContent||''
  });
})()
