(function(){
  var i=document.getElementById('sh-img'); var r=i.getBoundingClientRect();
  return JSON.stringify({vis:i.style.display, natW:i.naturalWidth, natH:i.naturalHeight, left:r.left, top:r.top, w:r.width, h:r.height, meta:(document.getElementById('sh-meta')||{}).textContent||'', op:(document.getElementById('sh-op')||{}).textContent||''});
})()
