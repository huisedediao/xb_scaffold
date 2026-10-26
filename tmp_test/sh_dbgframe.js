(function(){
  try {
    var x = new XMLHttpRequest(); x.open('GET', '/', false); x.send();
    var html = x.responseText;
    var f = document.createElement('iframe'); f.style.display = 'none';
    document.body.appendChild(f);
    var d = f.contentWindow.document; d.open();
    d.write('<scr' + 'ipt>window.onerror=function(m,s,l,c){parent.__err=m+" @"+l+":"+c;};</scr' + 'ipt>');
    d.write(html); d.close();
    window.__dbgFrame = f;
    return 'written len=' + html.length;
  } catch (e) { return 'ERR ' + e; }
})()
