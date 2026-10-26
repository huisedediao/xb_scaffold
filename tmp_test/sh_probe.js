JSON.stringify({
  newUi: typeof shRecToggle,
  recOn: (typeof shRec !== 'undefined') ? shRec.on : null,
  steps: (typeof shRec !== 'undefined') ? shRec.steps.length : null,
  pending: (typeof shOpPending !== 'undefined') ? shOpPending : null,
  uri: (typeof shUri === 'function') ? shUri() : null,
  img: (function(){ var i=document.getElementById('sh-img'); if(!i) return null; var r=i.getBoundingClientRect(); return {natW:i.naturalWidth, natH:i.naturalHeight, left:r.left, top:r.top, w:r.width, h:r.height, src:(i.src||'').slice(0,32)}; })(),
  activeTab: (function(){ var a=document.querySelector('.tab.active, .tabs .active'); return a ? a.textContent.trim() : null; })()
})
