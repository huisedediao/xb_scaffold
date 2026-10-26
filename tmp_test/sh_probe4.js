JSON.stringify({
  n: document.scripts.length,
  lens: Array.prototype.map.call(document.scripts, function(s){ return (s.src ? 'src:'+s.src : 'inline') + ':' + s.textContent.length; }),
  hasShRec: Array.prototype.some.call(document.scripts, function(s){ return s.textContent.indexOf('shRecToggle') >= 0; }),
  hasAai: Array.prototype.some.call(document.scripts, function(s){ return s.textContent.indexOf('aiStop') >= 0; }),
  connectType: typeof connect,
  wsType: typeof ws
})
