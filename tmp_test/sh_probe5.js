(function(){
  window.__foo = 123;
  var s2 = document.scripts[2];
  return JSON.stringify({
    foo: window.__foo,
    wsdot: document.getElementById('wsdot').className,
    devs: document.getElementById('hdrdev') ? document.getElementById('hdrdev').options.length : -1,
    selVal: document.getElementById('vmsel') ? document.getElementById('vmsel').value : 'nosel',
    type: s2.type || '(none)',
    nonce: s2.nonce || '',
    csp: !!document.querySelector('meta[http-equiv="Content-Security-Policy"]'),
    evalType: (function(){ try { return window.eval('typeof shRefresh + "," + typeof ws'); } catch(e){ return 'ERR '+e; } })(),
    firstChars: s2.textContent.slice(0,60)
  });
})()
