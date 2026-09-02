import SwiftUI
import WebKit
import AVFoundation
import NaturalLanguage
import MediaPlayer

// MARK: – Truncation detection (PreferenceKey for natural vs. available text width)

private struct AuthorTruncationKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: – Highlight JS (raw string — no Swift escaping needed)

private let merlinHighlightJS: String = #"""
(function(){
  const COLORS=[{id:'yellow',hex:'#fde68a'},{id:'green',hex:'#bbf7d0'},{id:'blue',hex:'#bfdbfe'},{id:'pink',hex:'#fbcfe8'},{id:'orange',hex:'#fed7aa'}];

  function getXPath(node){
    const root=document.body;const parts=[];let cur=node;
    while(cur&&cur!==root){
      if(cur.nodeType===3){
        let idx=0,sib=cur.previousSibling;
        while(sib){if(sib.nodeType===3)idx++;sib=sib.previousSibling;}
        parts.unshift('text()['+(idx+1)+']');
      } else {
        const tag=cur.nodeName.toLowerCase();let n=1,sib=cur.previousElementSibling;
        while(sib){if(sib.nodeName.toLowerCase()===tag)n++;sib=sib.previousElementSibling;}
        parts.unshift(tag+'['+n+']');
      }
      cur=cur.parentNode;
    }
    return cur?parts.join('/'):null;
  }

  function resolveXPath(xpath){
    if(!xpath)return null;
    const parts=xpath.split('/');let node=document.body;
    for(const part of parts){
      if(!node)return null;
      const tm=/^text\(\)\[(\d+)\]$/.exec(part);
      if(tm){
        const target=parseInt(tm[1])-1;let count=0,found=null;
        for(const c of node.childNodes){if(c.nodeType===3){if(count++===target){found=c;break;}}}
        node=found;
      } else {
        const em=/^([a-z0-9]+)\[(\d+)\]$/i.exec(part);
        if(!em)return null;
        const tag=em[1].toLowerCase(),idx=parseInt(em[2])-1;let count=0,found=null;
        for(const c of node.children){if(c.nodeName.toLowerCase()===tag){if(count++===idx){found=c;break;}}}
        node=found;
      }
    }
    return node||null;
  }

  function wrapRange(range,color,hlId){
    if(range.collapsed)return;
    const colorDef=COLORS.find(c=>c.id===color)||COLORS[0];
    const makeSpan=()=>{
      const s=document.createElement('mark');
      s.className='merlin-highlight';s.dataset.highlightId=String(hlId);s.dataset.highlightColor=color;
      // All five highlight swatches are light pastels, so the text needs a
      // fixed dark colour rather than `color:inherit` — in the dark reader
      // theme, inherited text is near-white and unreadable on a light
      // highlight background. #1c1c1e matches the app's own light-theme
      // text colour (see textColor(for:) below).
      s.style.cssText='background-color:'+colorDef.hex+';color:#1c1c1e;border-radius:2px;padding:0 1px;box-decoration-break:clone;-webkit-box-decoration-break:clone;cursor:pointer;';
      return s;
    };
    const root=range.commonAncestorContainer.nodeType===3?range.commonAncestorContainer.parentNode:range.commonAncestorContainer;
    const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
    const nodes=[];let n;
    while((n=walker.nextNode())){if(range.intersectsNode(n))nodes.push(n);}
    for(let i=0;i<nodes.length;i++){
      let tn=nodes[i];
      const startOff=(i===0&&tn===range.startContainer)?range.startOffset:0;
      const endOff=(i===nodes.length-1&&tn===range.endContainer)?range.endOffset:tn.length;
      if(startOff>=endOff)continue;
      if(endOff<tn.length)tn.splitText(endOff);
      const slice=startOff>0?tn.splitText(startOff):tn;
      const mark=makeSpan();
      slice.parentNode.insertBefore(mark,slice);
      mark.appendChild(slice);
    }
  }

  function restoreHighlight(h){
    const sn=resolveXPath(h.startXpath),en=resolveXPath(h.endXpath);
    if(!sn||!en)return;
    try{
      const r=document.createRange();r.setStart(sn,h.startOffset);r.setEnd(en,h.endOffset);
      if(!r.collapsed)wrapRange(r,h.color,h.id);
    }catch{}
  }

  let pendingRange=null,selectedHighlightId=null,touching=false;

  // Select the full text range of a highlight span (and all sibling spans
  // sharing the same data-highlight-id) so iOS shows its native selection UI.
  function selectHighlight(mark){
    const id=mark.dataset.highlightId;
    selectedHighlightId=id;
    const spans=Array.from(document.querySelectorAll('mark.merlin-highlight[data-highlight-id="'+id+'"]'));
    if(!spans.length)return;
    try{
      const range=document.createRange();
      range.setStart(spans[0],0);
      const last=spans[spans.length-1];
      range.setEnd(last,last.childNodes.length);
      const sel=window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }catch(e){}
  }

  function removeHighlightSpans(id){
    document.querySelectorAll('mark.merlin-highlight[data-highlight-id="'+id+'"]').forEach(el=>{
      const p=el.parentNode;while(el.firstChild)p.insertBefore(el.firstChild,el);p.removeChild(el);p.normalize();
    });
  }

  // The colour/delete toolbar itself is now a *native* SwiftUI overlay (see
  // ArticleReaderView) so it can dock to a screen edge and survive the
  // SwiftUI ScrollView moving the WebView around underneath it. We only
  // report the selection's bounding rect — in this non-scrolling WebView,
  // getBoundingClientRect() is already in document-absolute space, and the
  // Swift side adds its own on-screen frame to get a true screen position.
  function sendSelectionToNative(){
    if(!pendingRange)return;
    const rect=pendingRange.getBoundingClientRect();
    window.webkit.messageHandlers.selectionToolbar.postMessage({
      top:rect.top,bottom:rect.bottom,left:rect.left,right:rect.right,
      hasHighlight:selectedHighlightId!==null
    });
  }

  function clearNativeSelectionToolbar(){
    window.webkit.messageHandlers.selectionToolbar.postMessage({cleared:true});
  }

  function applyHighlight(color){
    const range=pendingRange;pendingRange=null;
    if(!range||range.collapsed)return;
    // If the user tapped an existing highlight and then chose a colour, delete
    // the old spans first so wrapRange doesn't nest marks inside marks.
    const oldId=selectedHighlightId;selectedHighlightId=null;
    if(oldId!==null)removeHighlightSpans(oldId);
    const sx=getXPath(range.startContainer),ex=getXPath(range.endContainer);
    if(!sx||!ex)return;
    const text=range.toString().trim();if(!text)return;
    const startOffset=range.startOffset;
    const endOffset=range.endOffset;
    const tempId='tmp_'+Date.now();
    wrapRange(range,color,tempId);
    window.getSelection()?.removeAllRanges();
    // Defer the backend call until after the browser has painted the highlight,
    // so the user sees the mark before the network request is sent.
    requestAnimationFrame(()=>{
      if(oldId!==null){
        window.webkit.messageHandlers.highlights.postMessage({action:'delete',id:oldId});
      }
      window.webkit.messageHandlers.highlights.postMessage({action:'create',data:{highlightedText:text,startXpath:sx,startOffset:startOffset,endXpath:ex,endOffset:endOffset,color:color,tempId:tempId}});
    });
  }

  function deleteSelectedHighlight(){
    if(selectedHighlightId===null)return;
    // Send the raw id — it may still be a "tmp_…" placeholder if the
    // highlight hasn't been confirmed by the server yet (parseInt would
    // turn that into NaN and silently drop the message on the Swift side).
    const id=selectedHighlightId;selectedHighlightId=null;
    removeHighlightSpans(id);
    window.webkit.messageHandlers.highlights.postMessage({action:'delete',id:id});
    window.getSelection()?.removeAllRanges();
    pendingRange=null;
  }

  // Called from the native toolbar (HighlightToolbarView) when the user taps
  // a colour swatch or the delete button.
  window.merlinApplyHighlightFromNative=function(color){applyHighlight(color);};
  window.merlinDeleteSelectedHighlightFromNative=function(){deleteSelectedHighlight();};

  // Called from Swift once the outer SwiftUI ScrollView has moved far enough
  // that any live selection no longer points at visible content. Collapsing
  // it here also takes the native WebKit edit menu (Copy / Look Up /
  // Translate) down with it, before WebKit gets a chance to anchor it to an
  // off-screen rect and fall back to its own broken, oversized top-docked
  // presentation. Our own toolbar is native now and is hidden separately —
  // instantly, on any scroll — by Swift; this call is purely a workaround
  // for WebKit's system menu.
  window.merlinCollapseSelectionForScroll=function(){
    const sel=window.getSelection();
    if(sel&&!sel.isCollapsed)sel.removeAllRanges();
    clearTimeout(selTimer);clearTimeout(hideTimer);
    pendingRange=null;selectedHighlightId=null;
    clearNativeSelectionToolbar();
  };

  // Track whether a finger is currently on screen. While touching, we must not
  // clear the selection state even if it briefly collapses (iOS does this when
  // the user drags a selection handle to extend the range).
  document.addEventListener('touchstart',()=>{touching=true;},{passive:true});
  document.addEventListener('touchend',()=>{
    touching=false;
    // Keep the live selection intact on finger-lift — collapsing it here used
    // to kill the native drag handles, making it impossible to grow the
    // selection afterwards. The system edit menu (Copy / Look Up / Translate)
    // can't be suppressed from here (no public WKWebView hook for it), so it
    // may show up alongside our own toolbar; see merlinCollapseSelectionForScroll
    // for how we avoid the worst case of that (an off-screen, broken anchor).
    const sel=window.getSelection();
    if(sel&&!sel.isCollapsed&&sel.rangeCount>0){
      const range=sel.getRangeAt(0);
      if(document.body.contains(range.commonAncestorContainer)){pendingRange=range.cloneRange();}
      clearTimeout(selTimer);
      selTimer=setTimeout(()=>{if(pendingRange)sendSelectionToNative();},200);
    }
  },{passive:true});
  document.addEventListener('touchcancel',()=>{touching=false;},{passive:true});

  // Debounce: track selection changes during drag and notify native once stable.
  // The selection itself is left alone (see touchend above) so the native
  // handles stay draggable while our toolbar lives outside the WebView.
  let selTimer=null,hideTimer=null;
  document.addEventListener('selectionchange',()=>{
    const sel=window.getSelection();
    if(sel&&!sel.isCollapsed&&sel.rangeCount>0){
      const range=sel.getRangeAt(0);
      if(document.body.contains(range.commonAncestorContainer)){
        // A real, live selection exists — cancel any pending hide. Presenting
        // the native edit menu can apparently cause a one-frame collapse/
        // re-selection blip on some iOS versions; without this our toolbar
        // would flash and vanish a moment after appearing.
        clearTimeout(hideTimer);
        pendingRange=range.cloneRange();
        clearTimeout(selTimer);
        selTimer=setTimeout(()=>{if(pendingRange)sendSelectionToNative();},500);
        return;
      }
    }
    clearTimeout(selTimer);
    // Don't clear state while a finger is on screen (iOS can briefly collapse
    // selection mid-drag). Tapping the native toolbar's buttons never touches
    // the WebView, so it can't accidentally trip this debounce.
    if(!touching){
      // Debounce the actual clear: if the selection comes back within the
      // window (see the collapse-blip note above) this gets cancelled and
      // the toolbar never disappears in the first place.
      clearTimeout(hideTimer);
      hideTimer=setTimeout(()=>{
        pendingRange=null;selectedHighlightId=null;
        clearNativeSelectionToolbar();
      },250);
    }
  });

  document.addEventListener('click',e=>{
    const mark=e.target.closest('mark.merlin-highlight');
    if(mark){e.preventDefault();selectHighlight(mark);}
    // Toggle floating back button unless the tap landed on a link or highlight
    if(!e.target.closest('a')&&!mark){
      window.webkit.messageHandlers.toggleUI.postMessage({});
    }
  });

  window.merlinApplyHighlights=highlights=>{
    // Resolve start nodes first so we can sort without repeated XPath lookups
    const items=highlights.map(h=>({h,n:resolveXPath(h.startXpath)})).filter(x=>x.n);
    // Process in reverse document order (last → first) so splitText calls
    // from later highlights don't invalidate XPaths of earlier ones
    items.sort((a,b)=>{const p=a.n.compareDocumentPosition(b.n);return(p&4)?1:(p&2)?-1:0;});
    items.forEach(x=>restoreHighlight(x.h));
  };
  window.merlinUpdateTempId=(tempId,realId)=>{
    document.querySelectorAll('mark.merlin-highlight[data-highlight-id="'+tempId+'"]').forEach(el=>{el.dataset.highlightId=String(realId);});
  };
})();
"""#

// MARK: – Image tap JS (tapping any img sends index + all srcs to Swift)

private let merlinImageTapJS: String = #"""
(function(){
  function wire(img,getAll){
    if(img.dataset.merlinTap)return;
    if(img.closest('.merlin-yt-embed'))return; // Thumbnail eines YouTube-Platzhalters — eigene Handhabung in merlinYoutubeTapJS
    img.dataset.merlinTap='1';
    img.style.cursor='pointer';
    img.addEventListener('click',function(e){
      e.stopPropagation();
      e.preventDefault(); // prevent <a>-wrapped images from triggering link navigation
      var all=getAll();
      var srcs=all.map(function(i){return i.currentSrc||i.src;}).filter(Boolean);
      var idx=all.indexOf(img);
      if(idx<0)idx=0;
      window.webkit.messageHandlers.imageTap.postMessage({index:idx,srcs:srcs});
    });
  }
  function all(){return Array.from(document.querySelectorAll('img')).filter(function(i){return !i.closest('.merlin-yt-embed');});}
  all().forEach(function(img){wire(img,all);});
  new MutationObserver(function(ms){
    ms.forEach(function(m){
      m.addedNodes.forEach(function(n){
        if(n.nodeType!==1)return;
        if(n.tagName==='IMG')wire(n,all);
        else if(n.querySelectorAll)n.querySelectorAll('img').forEach(function(i){wire(i,all);});
      });
    });
  }).observe(document.body,{childList:true,subtree:true});
})();
"""#

// MARK: – YouTube placeholder tap JS
//
// Tapping the thumbnail card rewriteYouTubeEmbeds() left in place of the
// original <iframe> posts the video id (+ optional start time) to Swift,
// which presents a native fullScreenCover with its own top-level WKWebView
// navigation — see YouTubePlayerView.swift for why that's necessary
// (nesting the YouTube iframe inside THIS file://-origin page instead was
// tried first and silently failed: WKWebView doesn't reliably honour CSP
// frame-ancestors for a file:// parent, and even a permissive frame-ancestors
// left the frame blank instead of erroring).
private let merlinYoutubeTapJS: String = #"""
(function(){
  document.querySelectorAll('.merlin-yt-embed').forEach(function(card){
    card.addEventListener('click',function(e){
      e.stopPropagation();
      e.preventDefault();
      window.webkit.messageHandlers.youtubeTap.postMessage({
        id: card.dataset.ytId || '',
        start: card.dataset.ytStart || ''
      });
    });
  });
})();
"""#

// MARK: – Image debug overlay JS (injected only in developer mode)

private let merlinDebugJS: String = #"""
(function(){
  var S=document.createElement('style');
  S.textContent=
    '.mdbg-wrap{margin:8px 0}'+
    '.mdbg{font:10px/1.5 "SF Mono",Menlo,monospace;padding:7px 10px;border-radius:0 0 8px 8px;'+
      'background:rgba(0,0,0,.92)!important;color:#e5e5ea!important;word-break:break-all;border-top:2px solid #30d158}'+
    '.mdbg.net{border-top-color:#ff9f0a}'+
    '.mdbg.err{border-top-color:#ff453a}'+
    '.mdbg-row{display:flex;gap:6px;margin-bottom:2px}'+
    '.mdbg-k{color:rgba(255,255,255,.4);white-space:nowrap;flex-shrink:0}'+
    '.mdbg-v{color:#e5e5ea;word-break:break-all}'+
    '.mdbg-v.ok{color:#30d158}.mdbg-v.net{color:#ff9f0a}.mdbg-v.err{color:#ff453a}'+
    '.mdbg-badge{display:inline-block;padding:1px 6px;border-radius:3px;'+
      'font-weight:700;font-size:9px;letter-spacing:.5px;margin-bottom:5px}'+
    '.bl{background:#30d158;color:#000}.bn{background:#ff9f0a;color:#000}.be{background:#ff453a;color:#fff}';
  document.head.appendChild(S);

  function row(k,v,c){
    return '<div class="mdbg-row"><span class="mdbg-k">'+k+'</span>'
          +'<span class="mdbg-v'+(c?' '+c:'')+'">'+v+'</span></div>';
  }

  function addPanel(img){
    if(img.dataset.merlinDbg)return;
    img.dataset.merlinDbg='1';
    var wrap=document.createElement('div');
    wrap.className='mdbg-wrap';
    var p=document.createElement('div');
    p.className='mdbg';
    var attr=img.getAttribute('src')||'';
    var orig=img.dataset.merlinOriginalSrc||'';
    var isLocal=img.src.startsWith('file://')||(attr&&!attr.startsWith('http')&&!attr.startsWith('//'));
    if(!isLocal)p.classList.add('net');
    var bc=isLocal?'bl':'bn', bl=isLocal?'LOCAL':'REMOTE', vc=isLocal?'ok':'net';
    var h='<span class="mdbg-badge '+bc+'">'+bl+'</span>'
      +row('attr:',attr,vc)
      +row('src:',img.src);
    if(orig)h+=row('orig:',orig);
    p.innerHTML=h;
    function onLoad(){
      var el=p.querySelector('.mdbg-sz');
      var d=img.naturalWidth+'×'+img.naturalHeight+'px';
      if(el)el.textContent=d;
      else p.insertAdjacentHTML('beforeend',
        '<div class="mdbg-row mdbg-sz"><span class="mdbg-k">size:</span>'
        +'<span class="mdbg-v">'+d+'</span></div>');
    }
    function onErr(){
      p.className='mdbg err';
      var b=p.querySelector('.mdbg-badge');
      b.className='mdbg-badge be'; b.textContent='ERROR';
      var probeUrl=img.src;
      if(probeUrl.startsWith('file://')){
        // Local: XHR HEAD to check whether the file actually exists in cache.
        var x=new XMLHttpRequest();
        x.open('HEAD',probeUrl,true);
        x.onload=function(){p.insertAdjacentHTML('beforeend',row('err:',x.status===200?'File found – bad image data':'HTTP '+x.status,'err'));};
        x.onerror=function(){p.insertAdjacentHTML('beforeend',row('err:','Not in cache (file missing)','err'));};
        x.send();
      } else {
        // Remote: try fetch to distinguish CORP/CORS block from plain 4xx/5xx.
        fetch(probeUrl,{method:'HEAD',mode:'no-cors',cache:'no-store'})
          .then(function(){p.insertAdjacentHTML('beforeend',row('err:','Remote – opaque (CORS/CORP?)','err'));})
          .catch(function(e){
            var m=(e&&e.message)?e.message:String(e);
            var reason=m.indexOf('CORP')>-1||m.indexOf('Cross-Origin')>-1?'CORP header blocked':
                       m.indexOf('network')>-1||m.indexOf('Network')>-1?'Network error':
                       'Blocked: '+m.slice(0,60);
            p.insertAdjacentHTML('beforeend',row('err:',reason,'err'));
          });
      }
    }
    if(img.complete){img.naturalWidth>0?onLoad():onErr();}
    else{img.addEventListener('load',onLoad,{once:true});img.addEventListener('error',onErr,{once:true});}
    img.parentNode.insertBefore(wrap,img);
    wrap.appendChild(img);
    wrap.appendChild(p);
  }

  // <video>-Pendant zu addPanel() oben: img feuert 'load'/'error' und trägt
  // naturalWidth/-Height, video dagegen 'loadedmetadata'/'error' und
  // videoWidth/-Height, plus ein eigenes .error.code (MEDIA_ERR_*) statt
  // eines reinen Bool-Fehlerstatus - deshalb eine separate Funktion statt
  // addPanel() zu verzweigen.
  function addVideoPanel(video){
    if(video.dataset.merlinDbg)return;
    video.dataset.merlinDbg='1';
    var wrap=document.createElement('div');
    wrap.className='mdbg-wrap';
    var p=document.createElement('div');
    p.className='mdbg net';
    var attr=video.getAttribute('src')||'';
    var h='<span class="mdbg-badge bn">VIDEO</span>'
      +row('attr:',attr,'net')
      +row('src:',video.currentSrc||video.src)
      +row('inline:',String(video.hasAttribute('playsinline')||'via config'))
      +row('autoplay:',String(video.autoplay)+' / muted:'+String(video.muted));
    p.innerHTML=h;
    function onMeta(){
      var d=video.videoWidth+'×'+video.videoHeight+'px, readyState='+video.readyState;
      p.insertAdjacentHTML('beforeend',row('meta:',d,'ok'));
    }
    function onPlaying(){
      p.insertAdjacentHTML('beforeend',row('playing:','yes','ok'));
    }
    function onErr(){
      p.className='mdbg err';
      var b=p.querySelector('.mdbg-badge');
      b.className='mdbg-badge be'; b.textContent='ERROR';
      var err=video.error;
      var codeNames={1:'ABORTED',2:'NETWORK',3:'DECODE',4:'SRC_NOT_SUPPORTED'};
      var reason=err?(codeNames[err.code]||('code '+err.code))+(err.message?': '+err.message:''):'unknown';
      p.insertAdjacentHTML('beforeend',row('err:',reason,'err'));
    }
    video.addEventListener('loadedmetadata',onMeta,{once:true});
    video.addEventListener('playing',onPlaying,{once:true});
    video.addEventListener('error',onErr,{once:true});
    // Stalled autoplay (kein 'error', aber auch nie 'playing') nach 3s sichtbar
    // machen - genau der Fall, der ohne Debug-Panel wie "zeigt einfach nichts" aussieht.
    setTimeout(function(){
      if(video.paused && !video.ended){
        p.insertAdjacentHTML('beforeend',row('status:','still paused after 3s (readyState='+video.readyState+')','net'));
      }
    },3000);
    if(video.parentNode){
      video.parentNode.insertBefore(wrap,video);
      wrap.appendChild(video);
      wrap.appendChild(p);
    }
  }

  document.querySelectorAll('img').forEach(addPanel);
  document.querySelectorAll('video').forEach(addVideoPanel);
  new MutationObserver(function(ms){
    ms.forEach(function(m){
      m.addedNodes.forEach(function(n){
        if(n.nodeType!==1)return;
        if(n.tagName==='IMG')addPanel(n);
        else if(n.tagName==='VIDEO')addVideoPanel(n);
        else if(n.querySelectorAll){
          n.querySelectorAll('img').forEach(addPanel);
          n.querySelectorAll('video').forEach(addVideoPanel);
        }
      });
    });
  }).observe(document.body,{childList:true,subtree:true});
})();
"""#

// MARK: – Liquid-Glass-Hintergrund für bottomBar + Piper-Panel
//
// Ab iOS 26 ersetzt echtes Glass-Material die bisherige Flat-Color-Fläche.
// `glassEffectUnion` mit gemeinsamer ID verschmilzt beide Bars (sofern beide
// sichtbar sind) im umgebenden `GlassEffectContainer` zu einer einzigen Form –
// genau das "Apple Maps Zoom-Buttons"-Muster für vertikal gestapelte Controls.
// Unterhalb von iOS 26 bleibt exakt die bisherige Optik (readerBgColor +
// Trennlinie) erhalten, damit die App weiterhin ab iOS 18 läuft.
private struct ReaderBarGlassBackground: ViewModifier {
    let topSeparator:   Bool
    let unionID:        String
    let namespace:      Namespace.ID
    let bgColor:        Color
    let separatorColor: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Rectangle())
                .glassEffectUnion(id: unionID, namespace: namespace)
        } else {
            content
                .background {
                    bgColor.opacity(0.97)
                        .overlay(alignment: .top) {
                            if topSeparator { separatorColor.frame(height: 0.5) }
                        }
                }
        }
    }
}

private extension View {
    /// Wendet auf iOS 26 echtes Liquid Glass an (vereint via `unionID` mit
    /// anderen Bars im selben `GlassEffectContainer`); darunter die bisherige
    /// Flat-Color-Optik.
    func readerBarGlassBackground(
        topSeparator: Bool = true,
        unionID: String,
        namespace: Namespace.ID,
        bgColor: Color,
        separatorColor: Color
    ) -> some View {
        modifier(ReaderBarGlassBackground(
            topSeparator: topSeparator, unionID: unionID, namespace: namespace,
            bgColor: bgColor, separatorColor: separatorColor))
    }
}

// MARK: – Weak WKScriptMessageHandler proxy (avoids retain cycle)

private class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(c, didReceive: message)
    }
}

// MARK: – Native highlight toolbar

/// Drives the native highlight toolbar overlay: where the current selection
/// is on screen (so we can pick the edge to dock to) and whether it's an
/// existing highlight (so the delete button shows).
struct SelectionToolbarState: Equatable {
    var screenRect: CGRect
    var hasHighlight: Bool
}

/// Native, screen-edge-docked replacement for the old text-anchored colour
/// picker. Deliberately large — full screen width, generous touch targets —
/// since it no longer needs to hug the selection.
private struct HighlightToolbarView: View {
    let hasHighlight: Bool
    /// true = docked to the top edge, false = bottom edge. Decides which side
    /// gets the extra `edgeInset` padding so the background can extend into
    /// the safe area (notch / home indicator) instead of leaving it bare.
    let dockTop: Bool
    /// The relevant safe-area inset (top or bottom, whichever applies) so the
    /// background fills all the way to the true screen edge while the button
    /// row itself still sits clear of the notch / home indicator.
    let edgeInset: CGFloat
    /// Width of the screen this toolbar is docked to. Used to shrink the
    /// circles below their ideal size on narrower phones instead of letting
    /// the row overflow once the separator + delete button join the five
    /// colours (that's 7 elements wide at full size — fits an iPad, not an
    /// iPhone SE/mini).
    let availableWidth: CGFloat
    let bgColor: Color
    let onColor: (String) -> Void
    let onDelete: () -> Void

    /// Mirrors the COLORS table in merlinHighlightJS — keep these in sync.
    private static let colors: [(id: String, hex: String)] = [
        ("yellow", "#fde68a"), ("green", "#bbf7d0"), ("blue", "#bfdbfe"),
        ("pink", "#fbcfe8"), ("orange", "#fed7aa"),
    ]

    private static let idealDiameter: CGFloat = 48
    private static let idealSpacing:  CGFloat = 22
    private static let separatorWidth: CGFloat = 1
    /// Kept clear on both sides so the circles never touch the true screen
    /// edge, even at full size on a wide iPad.
    private static let horizontalPadding: CGFloat = 24

    /// Number of fixed-size circles in the row (colours, plus the delete
    /// button when a highlight is selected).
    private var circleCount: Int { Self.colors.count + (hasHighlight ? 1 : 0) }
    private var gapCount: Int { circleCount - 1 + (hasHighlight ? 1 : 0) }

    /// Shrinks circles + spacing uniformly so the row always fits
    /// `availableWidth`, instead of overflowing off-screen once the delete
    /// button is added. Never scales *up* past the ideal size on wide
    /// screens — `min(1, …)`.
    private var scale: CGFloat {
        let usable = max(availableWidth - Self.horizontalPadding * 2, 0)
        let separator = hasHighlight ? Self.separatorWidth : 0
        let idealTotal = CGFloat(circleCount) * Self.idealDiameter
            + CGFloat(gapCount) * Self.idealSpacing
            + separator
        guard idealTotal > 0 else { return 1 }
        return min(1, max(0, (usable - separator) / (idealTotal - separator)))
    }

    private var circleDiameter: CGFloat { Self.idealDiameter * scale }
    private var itemSpacing:    CGFloat { Self.idealSpacing  * scale }

    var body: some View {
        VStack(spacing: 10) {
            Text(L("articleReader.highlightToolbar.title"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: itemSpacing) {
                ForEach(Self.colors, id: \.id) { c in
                    Button { onColor(c.id) } label: {
                        Circle()
                            .fill(Color(hexString: c.hex) ?? .yellow)
                            .frame(width: circleDiameter, height: circleDiameter)
                            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2.5))
                    }
                    .buttonStyle(.plain)
                }
                if hasHighlight {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: Self.separatorWidth, height: circleDiameter * 0.625)
                    Button(action: onDelete) {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: circleDiameter, height: circleDiameter)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 18 * scale, weight: .semibold))
                                    .foregroundStyle(.red)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        // Bake the safe-area inset into the content's own bounds (rather than
        // padding the whole view from outside) so the glass/flat background
        // below grows to cover it too — otherwise the strip under the notch
        // or above the home indicator would stay empty/see-through.
        .padding(.top,    dockTop ? edgeInset : 0)
        .padding(.bottom, dockTop ? 0 : edgeInset)
        .modifier(HighlightToolbarBackground(bgColor: bgColor))
    }
}

/// Ab iOS 26 echtes Liquid Glass; darunter eine flache, themenfarbige Fläche
/// (kein `regularMaterial` — das würde bei abweichendem App-Theme z. B. im
/// Dark-Reader-Modus auf einem Light-System-Theme die falsche Tönung ziehen,
/// siehe gleiches Problem bei `ReaderBarGlassBackground`).
private struct HighlightToolbarBackground: ViewModifier {
    let bgColor: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Rectangle())
        } else {
            content.background(
                bgColor.opacity(0.97)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            )
        }
    }
}

// HighlightToolbarView lives entirely in native SwiftUI (outside the
// WKWebView), so it can't call `window.webkit.messageHandlers` directly.
// This object is the other direction of that bridge: it holds a weak
// reference to the WKWebView and turns a colour tap / delete tap into the
// matching `window.merlin…FromNative()` JS call. Kept as a plain reference
// type (not a struct) so ArticleReaderView can hold one stable instance
// across SwiftUI body re-evaluations and hand it to both ArticleWebView and
// HighlightToolbarView.
@MainActor final class HighlightActionHandler {
    weak var webView: WKWebView?

    func applyColor(_ colorId: String) {
        webView?.evaluateJavaScript(
            "window.merlinApplyHighlightFromNative && window.merlinApplyHighlightFromNative('\(colorId)')")
    }

    func deleteSelected() {
        webView?.evaluateJavaScript(
            "window.merlinDeleteSelectedHighlightFromNative && window.merlinDeleteSelectedHighlightFromNative()")
    }
}

// MARK: – WKWebView wrapper

struct ArticleWebView: UIViewRepresentable {
    let html: String
    let articleId: Int
    var onLinkTapped:   ((URL) -> Void)?            = nil
    var onToggleUI:     (() -> Void)?               = nil
    /// Called whenever the HTML content height changes so the outer
    /// SwiftUI ScrollView can resize the fixed frame around this view.
    var onHeightChange: ((CGFloat) -> Void)?        = nil
    /// Called when the user taps an image; delivers tapped index + all src URLs.
    var onImageTapped:  ((Int, [String]) -> Void)?  = nil
    /// Called when the user taps a YouTube placeholder card; delivers the
    /// video id and an optional start-time in seconds (both from rewriteYouTubeEmbeds).
    var onYouTubeTapped: ((String, Int?) -> Void)?  = nil
    /// Called when the text selection settles. `rect` is in the WebView's own
    /// (document-absolute, non-scrolling) coordinate space — see the comment
    /// on `scrollOffset` below for why. The SwiftUI layer adds this WebView's
    /// own on-screen frame to get a true screen position for its native
    /// `HighlightToolbarView` overlay. `hasHighlight` is true when the
    /// selection is an existing highlight (tapped to edit/delete it).
    var onSelectionChanged: ((CGRect, Bool) -> Void)? = nil
    /// Called once the selection is cleared (deliberately, or via the
    /// debounced collapse-blip guard in the JS layer).
    var onSelectionCleared: (() -> Void)?            = nil
    /// Bridge that lets the native HighlightToolbarView call back into the
    /// JS highlight logic (colour pick / delete) without SwiftUI needing a
    /// direct reference to the underlying WKWebView.
    var actionHandler:  HighlightActionHandler?      = nil
    /// Current offset of the outer SwiftUI ScrollView. The WKWebView itself
    /// never scrolls (see makeUIView), so once the user scrolls the reader far
    /// enough, any still-live text selection points at content that's no
    /// longer on screen — WebKit then has no valid anchor for its native edit
    /// menu and falls back to an oversized, top-docked, unanchored menu. We
    /// watch this to collapse the selection before that can happen.
    var scrollOffset:   CGFloat                     = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(articleId: articleId)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber]
        // Ohne diese beiden Flags spielt WKWebView <video autoplay loop muted>
        // (der GIF-Ersatz mancher Blogs, z. B. Ghost/Hugo) nicht inline ab:
        // allowsInlineMediaPlayback defaultet auf false (Playback ginge sonst
        // in Fullscreen), mediaTypesRequiringUserActionForPlayback auf .all
        // (Autoplay ohne Nutzergeste wäre blockiert) – das Element bleibt ohne
        // beide Flags leer/unsichtbar, obwohl das Markup korrekt im DOM steht.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(
            WeakMessageHandler(context.coordinator), name: "highlights")
        config.userContentController.add(
            WeakMessageHandler(context.coordinator), name: "toggleUI")
        config.userContentController.add(
            WeakMessageHandler(context.coordinator), name: "resize")
        config.userContentController.add(
            WeakMessageHandler(context.coordinator), name: "imageTap")
        config.userContentController.add(
            WeakMessageHandler(context.coordinator), name: "youtubeTap")
        config.userContentController.add(
            WeakMessageHandler(context.coordinator), name: "selectionToolbar")
        let wv = WKWebView(frame: .zero, configuration: config)
        // Scrolling is handled by the outer SwiftUI ScrollView.
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.minimumZoomScale = 1.0
        wv.scrollView.maximumZoomScale = 1.0
        wv.navigationDelegate  = context.coordinator
        wv.uiDelegate          = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        context.coordinator.webView = wv
        actionHandler?.webView = wv
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLinkTapped      = onLinkTapped
        context.coordinator.onToggleUI        = onToggleUI
        context.coordinator.onHeightChange    = onHeightChange
        context.coordinator.onImageTapped     = onImageTapped
        context.coordinator.onYouTubeTapped   = onYouTubeTapped
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onSelectionCleared = onSelectionCleared
        context.coordinator.articleId         = articleId
        actionHandler?.webView = webView

        // Collapse any live JS text selection once the reader has scrolled far
        // enough away from it — see the doc comment on `scrollOffset` above.
        // The >20pt threshold just avoids firing on sub-pixel scroll jitter;
        // the JS side is a cheap no-op when nothing is selected anyway.
        if abs(scrollOffset - context.coordinator.lastScrollOffset) > 20 {
            context.coordinator.lastScrollOffset = scrollOffset
            webView.evaluateJavaScript(
                "window.merlinCollapseSelectionForScroll && window.merlinCollapseSelectionForScroll()")
        }

        let newHash = html.hashValue
        guard context.coordinator.loadedHTMLHash != newHash else { return }
        context.coordinator.loadedHTMLHash = newHash

        // Write the HTML to a file inside the image-cache directory so that
        // loadFileURL(allowingReadAccessTo:) grants WKWebView read access to
        // all cached images in the same directory.  loadHTMLString(baseURL:)
        // does NOT give WebKit actual file-system access even with a file://
        // baseURL — only loadFileURL does.
        let cacheDir  = ImageCacheService.shared.cacheDir
        let htmlFile  = cacheDir.appendingPathComponent("_article-\(articleId).html")
        if (try? html.write(to: htmlFile, atomically: true, encoding: .utf8)) != nil {
            webView.loadFileURL(htmlFile, allowingReadAccessTo: cacheDir)
        } else {
            // Fallback: no file-system write access — images may not render.
            webView.loadHTMLString(html, baseURL: cacheDir)
        }
    }

    // MARK: – Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var articleId:      Int
        var loadedHTMLHash: Int    = 0
        var onLinkTapped:   ((URL) -> Void)?
        var onToggleUI:     (() -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?
        var onImageTapped:  ((Int, [String]) -> Void)?
        var onYouTubeTapped: ((String, Int?) -> Void)?
        var onSelectionChanged: ((CGRect, Bool) -> Void)?
        var onSelectionCleared: (() -> Void)?
        var lastScrollOffset: CGFloat = 0
weak var webView:   WKWebView?

        init(articleId: Int) {
            self.articleId = articleId
        }

        // MARK: WKScriptMessageHandler – highlight + toggleUI messages from JS

        func userContentController(_ userContentController: WKUserContentController,
                                    didReceive message: WKScriptMessage) {
            if message.name == "toggleUI" {
                DispatchQueue.main.async { [weak self] in self?.onToggleUI?() }
                return
            }

            if message.name == "resize", let h = message.body as? Double {
                DispatchQueue.main.async { [weak self] in self?.onHeightChange?(CGFloat(h)) }
                return
            }

            if message.name == "imageTap",
               let body  = message.body as? [String: Any],
               let index = body["index"] as? Int,
               let srcs  = body["srcs"]  as? [String] {
                DispatchQueue.main.async { [weak self] in self?.onImageTapped?(index, srcs) }
                return
            }

            if message.name == "youtubeTap",
               let body = message.body as? [String: Any],
               let id   = body["id"] as? String, !id.isEmpty {
                let start = (body["start"] as? String).flatMap { Int($0) }
                DispatchQueue.main.async { [weak self] in self?.onYouTubeTapped?(id, start) }
                return
            }

            if message.name == "selectionToolbar",
               let body = message.body as? [String: Any] {
                if body["cleared"] as? Bool == true {
                    DispatchQueue.main.async { [weak self] in self?.onSelectionCleared?() }
                    return
                }
                if let top    = body["top"]    as? Double,
                   let bottom = body["bottom"] as? Double,
                   let left   = body["left"]   as? Double,
                   let right  = body["right"]  as? Double {
                    let hasHighlight = body["hasHighlight"] as? Bool ?? false
                    let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                    DispatchQueue.main.async { [weak self] in self?.onSelectionChanged?(rect, hasHighlight) }
                }
                return
            }

guard message.name == "highlights",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "create":
                guard let data       = body["data"]             as? [String: Any],
                      let tempId     = data["tempId"]           as? String,
                      let text       = data["highlightedText"]  as? String,
                      let startXpath = data["startXpath"]       as? String,
                      let startOff   = data["startOffset"]      as? Int,
                      let endXpath   = data["endXpath"]         as? String,
                      let endOff     = data["endOffset"]        as? Int,
                      let color      = data["color"]            as? String
                else { return }

                let payload = HighlightCreate(
                    highlightedText: text,
                    startXpath: startXpath,
                    startOffset: startOff,
                    endXpath: endXpath,
                    endOffset: endOff,
                    color: color
                )
                let aid = articleId
                Task { [weak self, weak webView] in
                    guard self != nil else { return }
                    do {
                        let saved = try await MerlinAPI.shared.createHighlight(aid, payload: payload)
                        await HighlightCacheService.shared.upsert(saved)
                        if let encodedTempId = try? JSONEncoder().encode(tempId),
                           let tempIdJSON    = String(data: encodedTempId, encoding: .utf8) {
                            await MainActor.run {
                                webView?.evaluateJavaScript(
                                    "merlinUpdateTempId(\(tempIdJSON), \(saved.id))",
                                    completionHandler: nil)
                            }
                        }
                    } catch {
                        if case MerlinAPIError.networkError = error {
                            // Offline: queue for replay. The mark stays in the
                            // DOM under its "tmp_…" id — `merlinUpdateTempId`
                            // will swap in the real id once the queue drains
                            // and the article is reopened (fresh getHighlights).
                            OfflineHighlightQueue.shared.enqueueCreate(
                                articleId: aid, tempId: tempId, payload: payload)
                        }
                        // Real server errors are intentionally swallowed here —
                        // same fire-and-forget contract as before — but no
                        // longer mask network failures that need retrying.
                    }
                }

            case "delete":
                // Raw id: either a server-confirmed Int (as a string) or a
                // "tmp_…" placeholder for a highlight that never synced yet.
                guard let rawId = body["id"] as? String else { return }
                let aid = articleId

                if let highlightId = Int(rawId) {
                    Task {
                        do {
                            try await MerlinAPI.shared.deleteHighlight(highlightId)
                            await HighlightCacheService.shared.remove(id: highlightId, articleId: aid)
                        } catch {
                            if case MerlinAPIError.networkError = error {
                                // Offline: drop it from the local cache right
                                // away (so it doesn't reappear on a reload
                                // served from cache) and queue the delete for
                                // replay once we're back online.
                                await HighlightCacheService.shared.remove(id: highlightId, articleId: aid)
                                OfflineHighlightQueue.shared.enqueueDelete(articleId: aid, highlightId: highlightId)
                            }
                        }
                    }
                } else {
                    // Never reached the server — cancel the queued create
                    // instead of trying to delete a highlight that doesn't
                    // exist remotely (and would otherwise get resurrected).
                    OfflineHighlightQueue.shared.cancelPendingCreate(tempId: rawId, articleId: aid)
                }

            case "copy":
                if let text = body["text"] as? String, !text.isEmpty {
                    DispatchQueue.main.async { UIPasteboard.general.string = text }
                }

            default: break
            }
        }

        // Intercept link taps – hand them to the SwiftUI layer for the action sheet
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme,
               scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                onLinkTapped?(url)
            } else {
                decisionHandler(.allow)
            }
        }

        // Page load complete: restore saved highlights.
        // Height is reported exclusively by the ResizeObserver injected in buildReaderHTML.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let aid = articleId
            Task { [weak self, weak webView] in
                guard self != nil else { return }
                let highlights: [Highlight]
                if let fetched = try? await MerlinAPI.shared.getHighlights(aid) {
                    // Server is authoritative when reachable — refresh the
                    // offline cache so it never drifts from deletions made
                    // elsewhere.
                    await HighlightCacheService.shared.replaceAll(fetched, for: aid)
                    highlights = fetched
                } else {
                    // Offline (or request failed): fall back to whatever we
                    // last saw, so highlights remain visible without a
                    // connection — mirrors ArticleCacheService's role for
                    // article content.
                    highlights = await HighlightCacheService.shared.highlights(for: aid)
                }
                guard !highlights.isEmpty,
                      let jsonData = try? JSONEncoder().encode(highlights),
                      let jsonStr  = String(data: jsonData, encoding: .utf8) else { return }
                await MainActor.run {
                    webView?.evaluateJavaScript(
                        "if(typeof merlinApplyHighlights==='function'){merlinApplyHighlights(\(jsonStr))}",
                        completionHandler: nil)
                }
            }
        }
    }
}

// MARK: – Scroll position restorer

/// Walks up the UIKit view hierarchy to find the UIScrollView that backs the
/// SwiftUI ScrollView and restores `targetFraction` (relative position 0…1).
/// Uses a Coordinator flag so the restore fires exactly once per instance.
/// Retries every 250 ms (up to 8×), re-placing against the current content size
/// until it stabilises – this covers the window between SwiftUI layout and the
/// WKWebView JS height report (and image reflow growing the content further).
private struct ScrollPositionRestorer: UIViewRepresentable {
    /// Wiederherzustellende Leseposition als Fraktion 0…1 (NICHT als Pixel-Offset:
    /// Pixel variieren mit Erscheinungsbild/Gerät, die Fraktion ist portabel). Der
    /// Ziel-Offset wird bei jedem Versuch gegen die *aktuelle* `contentSize`
    /// berechnet – das skaliert automatisch mit, während Bilder/Reflow die Höhe
    /// noch wachsen lassen.
    let targetFraction: CGFloat
    /// Feuert genau einmal, sobald das erste Placement tatsächlich angewendet
    /// wurde (contentSize > Viewport). Gate für den Save beim Schließen: vorher
    /// steht `scrollProgress` noch auf ~0 und ein Save würde die echte Position
    /// per Last-Write-Wins auf allen Geräten überschreiben (Quick-Close-Race).
    var onApplied: (() -> Void)? = nil

    class Coordinator {
        var hasRestored = false
        var hasNotifiedApplied = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard targetFraction > 0.001, !context.coordinator.hasRestored else { return }
        attempt(from: uiView, coordinator: context.coordinator)
    }

    private func attempt(from uiView: UIView, coordinator: Coordinator, n: Int = 0, lastMax: CGFloat = -1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var v: UIView? = uiView.superview
            while let view = v {
                if let sv = view as? UIScrollView {
                    let maxOffset = sv.contentSize.height - sv.bounds.height
                    // Bei jedem Versuch gegen die aktuelle Höhe neu platzieren – so
                    // bleibt die *relative* Position korrekt, während der Inhalt durch
                    // Bild-Nachladen/Reflow noch wächst.
                    if maxOffset > 0 {
                        sv.setContentOffset(CGPoint(x: 0, y: targetFraction * maxOffset), animated: false)
                        // Ab jetzt zeigt der Reader die Zielposition (relativ zur
                        // aktuellen Höhe) – ein Save beim Schließen ist wieder verlustfrei.
                        if !coordinator.hasNotifiedApplied {
                            coordinator.hasNotifiedApplied = true
                            onApplied?()
                        }
                    }
                    // Fertig, sobald sich die Höhe gegenüber dem letzten Versuch nicht
                    // mehr ändert (zwei stabile Messungen) – oder nach 8 Versuchen.
                    let stable = maxOffset > 0 && abs(maxOffset - lastMax) < 1
                    if stable || n >= 8 {
                        coordinator.hasRestored = true
                    } else {
                        attempt(from: uiView, coordinator: coordinator, n: n + 1, lastMax: maxOffset)
                    }
                    return
                }
                v = view.superview
            }
            // UIScrollView not found anywhere in the hierarchy
            print("[ScrollPositionRestorer] UIScrollView not found in hierarchy (attempt \(n))")
        }
    }
}


// MARK: – Reader view

struct ArticleReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// Low damping on purpose — the highlight toolbar should bounce once on
    /// its way out (visually distinct from the plain slide-in), unlike the
    /// calmer spring used everywhere else in this view.
    fileprivate static let toolbarExitSpring: Animation = .spring(response: 0.4, dampingFraction: 0.62)

    let article: Article
    /// Wiederherzustellende Leseposition als Fraktion 0…1 (vom Aufrufer aus
    /// lokalem + Server-Wert per Last-Write-Wins aufgelöst, siehe ArticleListView).
    let initialFraction: CGFloat
    let viewModel: ArticlesViewModel
    var onNavigateNext: (() -> Void)? = nil

    @ObservedObject var piperTTS: PiperAudioService
    @State private var nearBottom          = false
    @State private var scrollingDown       = false
    @State private var showBottomBar            = true
    @State private var isAudioPlayerMinimized   = false
    @State private var showAppearance      = false
    @State private var scrollProgress:     CGFloat = 0
    @State private var scrollOffset:       CGFloat = 0
    /// Quick-Close-Guard: erst nachdem der ScrollPositionRestorer das erste
    /// Placement angewendet hat, darf der Save in `.onDisappear` laufen –
    /// sonst würde ein sofortiges Schließen ~0 mit neuerem Zeitstempel pushen.
    @State private var restoreApplied = false
    /// Height reported by WKWebView via JS (document.body.scrollHeight).
    @State private var webViewHeight:      CGFloat = 0
    /// Total height of the ScrollView content (header + webview + spacer).
    @State private var totalContentHeight: CGFloat = 0
    /// Measured height of the visible viewport (screen minus safe areas).
    @State private var viewportHeight:     CGFloat = UIScreen.main.bounds.height
    /// Measured width of the visible viewport — lets the highlight toolbar
    /// shrink its colour circles to always fit, instead of overflowing on
    /// narrower phones once the delete button is also shown.
    @State private var viewportWidth:      CGFloat = UIScreen.main.bounds.width
    /// On-screen frame of the ArticleWebView, tracked via `.onGeometryChange`
    /// below. Combined with the WebView-local selection rect reported by JS
    /// (see `onSelectionChanged`), this gives the highlight toolbar a true
    /// screen position even though the WebView itself never scrolls.
    @State private var webViewScreenFrame: CGRect = .zero
    /// Current selection state for the native highlight toolbar. Kept set
    /// (even while hidden) until `hideHighlightToolbar` actually unmounts it
    /// — see that method for why. `toolbarVisible` is the real on/off switch.
    @State private var selectionToolbar:   SelectionToolbarState? = nil
    /// Drives the toolbar's opacity/scale/offset; the animated hide no
    /// longer depends on a removal `.transition`.
    @State private var toolbarVisible = false
    /// Pending unmount scheduled by `hideHighlightToolbar`; cancelled if a
    /// new selection arrives before it fires.
    @State private var toolbarHideWorkItem: DispatchWorkItem? = nil
    /// Throttles `persistScrollProgress()` while scrolling to at most once per
    /// 500ms, so progress is saved continuously instead of only on reader
    /// close / backgrounding. See `scheduleScrollProgressSave()` for why this
    /// is a throttle (nil-check) rather than a cancel-and-reschedule debounce.
    @State private var scrollSaveWorkItem: DispatchWorkItem? = nil
    /// scrollOffset captured at the moment the toolbar last appeared. Any
    /// further scroll — even a single point — folds the toolbar back in
    /// immediately (see the onScrollGeometryChange action below).
    @State private var toolbarScrollBaseline: CGFloat? = nil
    /// Bridge so the native toolbar's buttons can drive the JS highlight
    /// logic. One stable instance for the lifetime of this view.
    @State private var highlightActions = HighlightActionHandler()
    @State private var tappedLinkURL:      URL? = nil
    @State private var lightboxState:      LightboxState? = nil
    @State private var youtubePlayerState: YouTubePlayerState? = nil
    @State private var showTagSheet        = false
    @State private var showReportSheet     = false
    @State private var showShareLinkSheet  = false
    @State private var reportComment       = ""
    @State private var reportSending       = false
    @State private var reportFeedback: ReportFeedback? = nil
    @State private var fontSize:      Int          = PreferencesStore.shared.readerFontSize
    @State private var theme:         ReaderTheme  = PreferencesStore.shared.readerTheme
    @State private var readerFont:    ReaderFont   = PreferencesStore.shared.readerFont
    @State private var lineHeight:    Double        = PreferencesStore.shared.lineHeight
    @State private var progressEdge:  ProgressEdge = PreferencesStore.shared.progressEdge
    @State private var showSideMenu      = false
    @State private var showReminderSheet = false
    @State private var articleReminder: Reminder? = nil
    @State private var showSavedAtFlyout   = false
    @State private var showAuthorFlyout    = false
    @State private var authorIsTruncated   = false
    @State private var safeAreaTop:    CGFloat = 0
    @State private var safeAreaBottom: CGFloat = 0
    @State private var localIsFavorite: Bool = false
    @State private var localIsArchived: Bool = false
    /// Lokal (nicht persistiert) — Nutzer hat die Paywall-Warnung für diese Ansicht weggewischt.
    @State private var paywallBannerDismissed = false
    @State private var showSiteCredentialsSheet = false
    @State private var isRetryingAfterPaywall = false
    /// Verbindet bottomBar + Piper-Panel zu einer einzigen Liquid-Glass-Form
    /// (ab iOS 26 – siehe `ReaderBarGlassBackground`).
    @Namespace private var bottomGlassNamespace
    @AppStorage("merlin_accent_progress_color") private var accentColorHex:  String = "#FF3B30"
    @AppStorage("merlin_developer_mode")        private var developerMode:   Bool   = false

    private var current: Article {
        viewModel.articles.first { $0.id == article.id } ?? article
    }

    // MARK: – Highlight toolbar show/hide
    //
    // `selectionToolbar` is intentionally NOT set back to nil the moment the
    // toolbar should hide. Doing that relies on SwiftUI's removal
    // `.transition`, which on iOS 26 gets cut short or skipped entirely once
    // the toolbar's background uses `.glassEffect()` inside a
    // `GlassEffectContainer` — the glass container appears to own its own
    // (near-instant) add/remove animation and doesn't reliably honour a
    // custom `.transition` on its child. Instead we keep the view mounted,
    // drive the visible hide purely through animatable modifiers
    // (opacity/scale/offset, which always animate reliably), and only
    // unmount it — invisibly, after the animation has finished — so the
    // glass layer isn't paying a continuous compositing cost forever.
    private func showHighlightToolbar(_ state: SelectionToolbarState, animation: Animation) {
        toolbarHideWorkItem?.cancel()
        selectionToolbar = state
        withAnimation(animation) { toolbarVisible = true }
    }

    private func hideHighlightToolbar(animation: Animation = ArticleReaderView.toolbarExitSpring) {
        guard toolbarVisible || selectionToolbar != nil else { return }
        toolbarHideWorkItem?.cancel()
        withAnimation(animation) { toolbarVisible = false }
        // Unmount well after the spring has settled — long enough that the
        // bounce-out never gets cut off, short enough it doesn't linger.
        // ArticleReaderView is a struct, so this closure captures a (cheap)
        // copy of self — but @State's underlying storage is a shared
        // reference box, so the assignment still reaches the live view.
        let work = DispatchWorkItem { selectionToolbar = nil }
        toolbarHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Measure viewport height for accurate scroll progress + nearBottom.
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewportHeight = geo.size.height
                        viewportWidth  = geo.size.width
                        let insets = UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets
                        safeAreaTop    = insets?.top    ?? 0
                        safeAreaBottom = insets?.bottom ?? 0
                    }
                    .onChange(of: geo.size.height) { _, h in viewportHeight = h }
                    .onChange(of: geo.size.width)  { _, w in viewportWidth  = w }
            }
            .ignoresSafeArea()

            // Fill the entire screen with the reader background colour so no
            // white areas bleed through above the top buttons or below the
            // bottom bar when dark / sepia mode is active.
            readerBgColor.ignoresSafeArea()
            // MARK: Content – outer ScrollView owns all scrolling
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Restore saved reading position once content has loaded.
                    if initialFraction > 0.001 {
                        ScrollPositionRestorer(targetFraction: initialFraction,
                                               onApplied: { restoreApplied = true })
                            .frame(width: 1, height: 1)
                            .opacity(0)
                            .allowsHitTesting(false)
                    }

                    articleHeader

                    if NativeVideoHost.matches(current.url) {
                        NativeVideoPlayerCard(articleId: current.id,
                                              posterURL: current.imageUrl.flatMap(URL.init(string:)))
                    }

                    if let content = current.content, !content.isEmpty {
                        ArticleWebView(
                            html: buildReaderHTML(content: content, fontSize: fontSize,
                                                  theme: theme, font: readerFont, lineHeight: lineHeight,
                                                  developerMode: developerMode),
                            articleId:      current.id,
                            onLinkTapped:   { url in tappedLinkURL = url },
                            onHeightChange: { h in webViewHeight = max(200, h) },
                            onImageTapped:  { idx, srcs in
                                lightboxState = LightboxState(initialIndex: idx, imageURLs: srcs)
                            },
                            onYouTubeTapped: { videoId, start in
                                youtubePlayerState = YouTubePlayerState(videoId: videoId, startSeconds: start)
                            },
                            onSelectionChanged: { rect, hasHighlight in
                                let screenRect = CGRect(
                                    x: webViewScreenFrame.minX + rect.minX,
                                    y: webViewScreenFrame.minY + rect.minY,
                                    width: rect.width,
                                    height: rect.height)
                                toolbarScrollBaseline = scrollOffset
                                showHighlightToolbar(
                                    SelectionToolbarState(screenRect: screenRect, hasHighlight: hasHighlight),
                                    animation: .spring(response: 0.35, dampingFraction: 0.82))
                            },
                            onSelectionCleared: {
                                toolbarScrollBaseline = nil
                                hideHighlightToolbar()
                            },
                            actionHandler: highlightActions,
                            scrollOffset: scrollOffset,
                        )
                        .frame(height: max(300, webViewHeight))
                        .onGeometryChange(for: CGRect.self) { geo in
                            geo.frame(in: .global)
                        } action: { _, frame in
                            webViewScreenFrame = frame
                        }
                    } else if current.isProcessing {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text(L("articleReader.noContent.processing"))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text(L("articleReader.noContent.title"))
                                .foregroundStyle(.secondary)
                            Button(L("articleReader.noContent.retry")) {
                                Task { await viewModel.retryExtraction(current) }
                            }
                            .buttonStyle(.borderedProminent)
                            if let url = URL(string: current.url) {
                                Link(L("articleReader.sideMenu.openInBrowser"), destination: url)
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }

                    Color.clear.frame(height: 160) // bottom padding for action bar
                }
            }
            .ignoresSafeArea()
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newY in
                let newOffset = max(0, newY)
                let delta = newOffset - scrollOffset
                let scrollable = totalContentHeight - viewportHeight
                let isNearBottom = scrollable > 0 ? (scrollable - newOffset < 160) : true

                if abs(delta) > 4 {
                    scrollingDown = delta > 0 && newOffset > 40
                    if scrollingDown && !isNearBottom {
                        // Runterscrollen & nicht am Ende → Bar ausblenden
                        withAnimation(.easeInOut(duration: 0.2)) { showBottomBar = false }
                    } else {
                        // Hochscrollen oder am Ende → Bar einblenden
                        withAnimation(.easeInOut(duration: 0.2)) { showBottomBar = true }
                    }
                }
                scrollOffset = newOffset
                if scrollable > 0 {
                    scrollProgress = max(0, min(1, newOffset / scrollable))
                    nearBottom = isNearBottom
                    scheduleScrollProgressSave()
                } else {
                    nearBottom = true
                }

                // Fold the highlight toolbar back in on the very first pixel of
                // scroll after it appeared — it's screen-anchored, not
                // document-anchored, so letting it ride along would mean it
                // drifts away from the selection it belongs to.
                if let baseline = toolbarScrollBaseline, newOffset != baseline {
                    toolbarScrollBaseline = nil
                    hideHighlightToolbar(animation: .spring(response: 0.3, dampingFraction: 0.85))
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height
            } action: { _, h in
                totalContentHeight = h
            }

            // MARK: Right-edge swipe zone – invisible strip that opens the side menu
            HStack(spacing: 0) {
                Spacer()
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 15, coordinateSpace: .local)
                            .onChanged { val in
                                if !showSideMenu && val.translation.width < -15 {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                                        showSideMenu = true
                                    }
                                }
                            }
                    )
            }
            .ignoresSafeArea()

            // MARK: Reading progress bar (edge configurable in Settings)
            if progressEdge != .off {
                GeometryReader { geo in
                    progressBar(in: geo)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.linear(duration: 0.05), value: scrollProgress)
            }

            // MARK: Unified bottom area – action bar sits above speech panel, no overlap
            // Ab iOS 26 verschmelzen beide zu einer einzigen Liquid-Glass-Form
            // (GlassEffectContainer + glassEffectUnion in ReaderBarGlassBackground);
            // darunter bleibt die bisherige Flat-Color-Optik erhalten.
            Group {
                if #available(iOS 26.0, *) {
                    GlassEffectContainer { bottomAreaStack }
                } else {
                    bottomAreaStack
                }
            }
            .ignoresSafeArea(edges: .bottom)

            // MARK: Highlight toolbar – docks to whichever screen edge (top or
            // bottom) is farther from the current selection, so it never
            // covers the text being highlighted. Folds back in instantly on
            // any scroll (handled above in onScrollGeometryChange) and on
            // selection clear (onSelectionCleared).
            if let toolbar = selectionToolbar {
                let dockTop = toolbar.screenRect.midY > viewportHeight / 2
                let toolbarView = HighlightToolbarView(
                    hasHighlight: toolbar.hasHighlight,
                    dockTop: dockTop,
                    edgeInset: dockTop ? safeAreaTop : safeAreaBottom,
                    availableWidth: viewportWidth,
                    bgColor: readerBgColor,
                    onColor: { colorId in
                        highlightActions.applyColor(colorId)
                        hideHighlightToolbar()
                    },
                    onDelete: {
                        highlightActions.deleteSelected()
                        hideHighlightToolbar()
                    })
                    // Only matters for the initial mount (a genuine
                    // insertion each time a new selection starts) — the
                    // animated hide further down doesn't rely on this since
                    // the view stays mounted while it plays.
                    .transition(.move(edge: dockTop ? .top : .bottom).combined(with: .opacity))

                // Liquid Glass needs a GlassEffectContainer to scope its
                // blur/refraction sampling to the toolbar's own bounds —
                // without one it samples against the whole window, which is
                // what made the colour circles look soft/upscaled (same fix
                // as bottomAreaStack above).
                //
                // The hide animation is driven by plain opacity/scale/offset
                // below, NOT by a removal `.transition` — a glass-backed
                // view inside GlassEffectContainer didn't reliably honour a
                // custom removal transition (it either skipped it or cut it
                // short), which is exactly why the bounce-out wasn't
                // visible. Animatable modifiers on a view that stays mounted
                // don't have that problem; `hideHighlightToolbar` unmounts
                // it afterwards, once it's already invisible.
                Group {
                    if #available(iOS 26.0, *) {
                        GlassEffectContainer { toolbarView }
                    } else {
                        toolbarView
                    }
                }
                .opacity(toolbarVisible ? 1 : 0)
                .scaleEffect(toolbarVisible ? 1 : 0.85, anchor: dockTop ? .top : .bottom)
                .offset(y: toolbarVisible ? 0 : (dockTop ? -40 : 40))
                .allowsHitTesting(toolbarVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dockTop ? .top : .bottom)
                .ignoresSafeArea()
            }

            // MARK: Side menu – scrim + drawer
            if showSideMenu {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                            showSideMenu = false
                        }
                    }
                    .transition(.opacity)

                HStack(spacing: 0) {
                    Spacer()
                    sideMenuDrawer
                        .frame(width: 300)
                        .ignoresSafeArea(edges: .vertical)
                        .gesture(
                            DragGesture(minimumDistance: 15, coordinateSpace: .local)
                                .onEnded { val in
                                    if val.translation.width > 15 {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                                            showSideMenu = false
                                        }
                                    }
                                }
                        )
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.3),  value: piperTTS.hasContent)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: showSideMenu)
        .onChange(of: piperTTS.hasContent) { _, hasContent in
            if hasContent { isAudioPlayerMinimized = false }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceSheet(fontSize: $fontSize, theme: $theme, readerFont: $readerFont, lineHeight: $lineHeight,
                            onAccentColorChange: { pushAppearanceToServer() })
                .presentationDetents([.height(460)])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $lightboxState) { ls in
            ImageLightboxView(state: ls) { lightboxState = nil }
                .background(Color.black)
        }
        .fullScreenCover(item: $youtubePlayerState) { yps in
            YouTubePlayerView(state: yps) { youtubePlayerState = nil }
                .background(Color.black)
        }
        .onChange(of: fontSize)    { _, v in
            PreferencesStore.shared.readerFontSize = v
            pushAppearanceToServer()
        }
        .onChange(of: theme)       { _, v in
            PreferencesStore.shared.readerTheme = v
            pushAppearanceToServer()
        }
        .onChange(of: readerFont)  { _, v in
            PreferencesStore.shared.readerFont = v
            pushAppearanceToServer()
        }
        .onChange(of: lineHeight)  { _, v in
            PreferencesStore.shared.lineHeight = v
            pushAppearanceToServer()
        }
        .onAppear {
            localIsFavorite = article.isFavorite
            localIsArchived = article.isArchived
        }
        .onDisappear {
            persistScrollProgress()
        }
        .onChange(of: scenePhase) { old, new in
            // Backgrounding (Home-Button, App-Wechsel, Sperrbildschirm, eingehender
            // Anruf) entfernt die View NICHT aus der Hierarchie – `.onDisappear`
            // feuert also nicht. Ohne diesen Hook geht jeder Fortschritt verloren,
            // den der Nutzer macht, bevor er den Reader regulär schließt (z. B. wenn
            // iOS die App im Hintergrund beendet). Das war vermutlich die Hauptursache
            // für "iOS synced Fortschritt zu selten" im Vergleich zum Web-Client, der
            // alle 500ms während des Scrollens pusht statt nur beim Schließen.
            guard old == .active, new != .active else { return }
            persistScrollProgress()
        }
        .confirmationDialog(
            tappedLinkURL?.absoluteString ?? "",
            isPresented: .init(get: { tappedLinkURL != nil }, set: { if !$0 { tappedLinkURL = nil } }),
            titleVisibility: .visible
        ) {
            if let url = tappedLinkURL {
                Button(L("articleReader.sideMenu.openInBrowser")) {
                    UIApplication.shared.open(url)
                }
                Button(L("articleReader.linkDialog.addToReadingList")) {
                    Task { try? await viewModel.addArticle(url: url.absoluteString) }
                }
                Button(L("common.cancel"), role: .cancel) { tappedLinkURL = nil }
            }
        }
        .sheet(isPresented: $showTagSheet) {
            ArticleTagSheet(
                article: current,
                allTags: viewModel.allTags
            ) { tagIds in
                Task { await viewModel.setTags(for: current, tagIds: tagIds) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // ── Artikel melden ─────────────────────────────────────────────────
        .sheet(isPresented: $showReportSheet, onDismiss: { reportComment = "" }) {
            ReportArticleSheet(
                articleURL:  current.url,
                comment:     $reportComment,
                isSending:   $reportSending,
                feedback:    $reportFeedback,
                onSend:      {
                    Task {
                        reportSending = true
                        do {
                            try await ReportService.shared.report(
                                url:     current.url,
                                comment: reportComment.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            reportFeedback = .success
                        } catch {
                            reportFeedback = .failure(error.localizedDescription)
                        }
                        reportSending = false
                    }
                }
            )
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
        // ── Bilder nachladen, die der Hintergrund-Prefetch verpasst hat ─────
        .task(id: current.id) {
            await fetchMissingContentImages()
        }
        // ── Erinnerungen ───────────────────────────────────────────────────
        .task {
            articleReminder = await ReminderService.shared.reminder(for: article.id)
        }
        .sheet(isPresented: $showReminderSheet, onDismiss: {
            Task { articleReminder = await ReminderService.shared.reminder(for: article.id) }
        }) {
            ReminderSheet(article: current, currentReminder: $articleReminder)
        }
        // ── Öffentlicher Share-Link ──────────────────────────────────────────
        .sheet(isPresented: $showShareLinkSheet) {
            ShareLinkSheet(articleId: current.id)
        }
        // ── Shake-to-undo ──────────────────────────────────────────────────
        .onShake {
            guard viewModel.canUndo else { return }
            Task { await viewModel.undo() }
        }
        .overlay(alignment: .top) {
            if let msg = viewModel.undoToast {
                ReaderUndoToast(message: msg, bgColor: readerBgColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.undoToast)
                    .padding(.top, 8)
            } else if let domain = current.requiresLoginDomain, !paywallBannerDismissed {
                PaywallWarningBanner(
                    domain: domain,
                    isRetrying: isRetryingAfterPaywall,
                    onConnect: { showSiteCredentialsSheet = true },
                    onRetry: { retryAfterPaywall() },
                    onDismiss: { paywallBannerDismissed = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current.requiresLoginDomain)
                .padding(.top, 8)
                .padding(.horizontal, 12)
            }
        }
        .sheet(isPresented: $showSiteCredentialsSheet) {
            SiteCredentialsView(preselectedDomain: current.requiresLoginDomain)
        }
        .listFlyout(viewModel: viewModel, onNavigate: { dismiss() })
    }

    /// Löscht den (an der Paywall gescheiterten) Artikel und legt ihn mit derselben URL neu an,
    /// damit die Extraktion mit den frisch hinterlegten Zugangsdaten erneut versucht wird. Es
    /// gibt bewusst keinen serverseitigen Re-Extraktions-Endpunkt (siehe Plan) – Löschen+Neuanlegen
    /// nutzt ausschließlich bestehende ArticlesViewModel-Funktionen.
    private func retryAfterPaywall() {
        guard !isRetryingAfterPaywall else { return }
        isRetryingAfterPaywall = true
        let snapshot = current
        Task {
            await viewModel.delete(snapshot)
            try? await viewModel.addArticle(url: snapshot.url, tagIds: snapshot.tags.map(\.id))
            isRetryingAfterPaywall = false
            dismiss()
        }
    }

    // MARK: – Helpers

    /// Builds the reading-progress rectangle for the chosen edge.
    @ViewBuilder
    private func progressBar(in geo: GeometryProxy) -> some View {
        let bar = Rectangle().fill(Color(hexString: accentColorHex) ?? .red)
        switch progressEdge {
        case .off:
            EmptyView()
        case .left:
            bar.frame(width: 3, height: geo.size.height * scrollProgress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .right:
            bar.frame(width: 3, height: geo.size.height * scrollProgress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        case .top:
            bar.frame(width: geo.size.width * scrollProgress, height: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .bottom:
            bar.frame(width: geo.size.width * scrollProgress, height: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// Solid background colour that matches the active reader theme.
    /// Used for the bottom bar so it blends with the article content.
    private var readerBgColor: Color {
        let isDark = (theme == .dark) || (theme == .auto && colorScheme == .dark)
        switch theme {
        case .sepia:  return Color(red: 0.957, green: 0.925, blue: 0.847)
        case .dark:   return .black
        case .light:  return .white
        case .auto:   return isDark ? .black : .white
        }
    }

    /// Icon/text foreground colour for UI elements overlaid on the reader background.
    private var readerFgColor: Color {
        let isDark = (theme == .dark) || (theme == .auto && colorScheme == .dark)
        switch theme {
        case .sepia:  return Color(red: 0.231, green: 0.184, blue: 0.118) // #3b2f1e
        case .dark:   return Color(red: 0.898, green: 0.898, blue: 0.918) // #e5e5ea
        case .light:  return Color(red: 0.110, green: 0.110, blue: 0.118) // #1c1c1e
        case .auto:   return isDark
            ? Color(red: 0.898, green: 0.898, blue: 0.918)
            : Color(red: 0.110, green: 0.110, blue: 0.118)
        }
    }

    /// Slightly elevated background for floating UI elements (back button etc.).
    /// Darker than the page background so the button stands out in all themes,
    /// especially in dark mode where readerBgColor is pure black.
    private var readerButtonBgColor: Color {
        let isDark = (theme == .dark) || (theme == .auto && colorScheme == .dark)
        switch theme {
        case .sepia:  return Color(red: 0.82, green: 0.76, blue: 0.66)   // warm mid-tone
        case .dark:   return Color(white: 0.20)                           // elevated dark grey
        case .light:  return .white
        case .auto:   return isDark ? Color(white: 0.20) : .white
        }
    }

    /// Separator colour between bottom-bar buttons, harmonised with the reader theme.
    private var readerSeparatorColor: Color {
        let isDark = (theme == .dark) || (theme == .auto && colorScheme == .dark)
        switch theme {
        case .sepia:  return Color(red: 0.682, green: 0.588, blue: 0.471).opacity(0.45)
        case .dark:   return Color.white.opacity(0.10)
        case .light:  return Color.black.opacity(0.10)
        case .auto:   return isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
        }
    }

    /// Muted foreground colour for secondary text in the native article header.
    private var readerFgMutedColor: Color {
        let isDark = (theme == .dark) || (theme == .auto && colorScheme == .dark)
        switch theme {
        case .sepia:  return Color(red: 0.482, green: 0.388, blue: 0.314) // #7a6350
        case .dark:   return Color(red: 0.596, green: 0.596, blue: 0.604) // #98989d
        case .light:  return Color(red: 0.431, green: 0.431, blue: 0.451) // #6e6e73
        case .auto:   return isDark
            ? Color(red: 0.596, green: 0.596, blue: 0.604)
            : Color(red: 0.431, green: 0.431, blue: 0.451)
        }
    }

    /// Slightly elevated surface for the info card in the article header.
    /// Pops one step off the page background so the card reads as a contained unit.
    private var infoCardBgColor: Color {
        let isDark = (theme == .dark) || (theme == .auto && colorScheme == .dark)
        switch theme {
        case .sepia:  return Color(red: 0.984, green: 0.957, blue: 0.886) // warmer than page
        case .dark:   return Color(white: 0.13)
        case .light:  return .white
        case .auto:   return isDark ? Color(white: 0.13) : .white
        }
    }

    /// Identifiziert eine Info-Card-Zelle unabhängig von ihrer (lokalisierten)
    /// Anzeige-Beschriftung – die Vergleichslogik unten darf nicht von der
    /// jeweils aktiven Sprache abhängen.
    private enum InfoCardKind: Equatable {
        case author, readingTime, published, saved

        var displayLabel: String {
            switch self {
            case .author:      return L("articleReader.labels.author")
            case .readingTime: return L("articleReader.labels.readingTime")
            case .published:   return L("articleReader.labels.published")
            case .saved:       return L("articleReader.labels.saved")
            }
        }
    }

    /// Cells displayed in the article-header info card, in display order.
    /// Empty when the article has no author, reading time, or publish date.
    private var infoCardCells: [(kind: InfoCardKind, label: String, value: String)] {
        var out: [(kind: InfoCardKind, label: String, value: String)] = []
        if let author = current.author, !author.isEmpty {
            out.append((kind: .author, label: InfoCardKind.author.displayLabel, value: author))
        }
        if current.readingTime > 0 {
            out.append((kind: .readingTime, label: InfoCardKind.readingTime.displayLabel, value: "\(current.readingTime) min"))
        }
        if let pub = shortDate(current.publishedAt) {
            out.append((kind: .published, label: InfoCardKind.published.displayLabel, value: pub))
        } else if let saved = shortDate(current.createdAt) {
            out.append((kind: .saved, label: InfoCardKind.saved.displayLabel, value: saved))
        }
        return out
    }

    /// One cell of the article-header info card: small uppercase label + value.
    @ViewBuilder
    private func infoCardCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: readerFont.swiftUIDesign))
                .tracking(1.0)
                .foregroundStyle(readerFgMutedColor)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: readerFont.swiftUIDesign))
                .foregroundStyle(readerFgColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: – Native article header (title + meta + tags + hero)

    @ViewBuilder
    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Top inset: safe area + small breathing room
            Color.clear.frame(height: safeAreaTop + 12)

            VStack(alignment: .leading, spacing: 0) {

                // ── Top row: accent bar + site (uppercase) ──
                let accent = Color(hexString: accentColorHex) ?? .red
                let hasSite = !current.displaySiteName.isEmpty

                if hasSite {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(accent)
                            .frame(width: 28, height: 3)

                        if let url = URL(string: current.url) {
                            Button {
                                tappedLinkURL = url
                            } label: {
                                Text(current.displaySiteName.uppercased())
                                    .font(.system(size: 11, weight: .bold, design: readerFont.swiftUIDesign))
                                    .tracking(2.0)
                                    .foregroundStyle(readerFgColor)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(current.displaySiteName.uppercased())
                                .font(.system(size: 11, weight: .bold, design: readerFont.swiftUIDesign))
                                .tracking(2.0)
                                .foregroundStyle(readerFgColor)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 18)
                }

                // ── Title ──
                Text(current.displayTitle)
                    .font(.system(size: CGFloat(fontSize + 5), weight: .bold, design: readerFont.swiftUIDesign))
                    .foregroundStyle(readerFgColor)
                    .fixedSize(horizontal: false, vertical: true)

                // ── Excerpt ──
                if let ex = current.excerpt, !ex.isEmpty {
                    Text(ex)
                        .font(.system(size: CGFloat(fontSize), design: readerFont.swiftUIDesign))
                        .foregroundStyle(readerFgMutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                // ── Info card: Autor · Lesezeit · Erschienen ──
                let cells = infoCardCells

                if !cells.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { idx, cell in
                            if cell.kind == .author {
                                let valueFont = Font.system(size: 12, weight: .semibold,
                                                            design: readerFont.swiftUIDesign)
                                Button { if authorIsTruncated { showAuthorFlyout = true } } label: {
                                    // Inline infoCardCell so we can attach truncation
                                    // detection directly to the value Text.
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(cell.label)
                                            .font(.system(size: 9, weight: .semibold,
                                                          design: readerFont.swiftUIDesign))
                                            .tracking(1.0)
                                            .foregroundStyle(readerFgMutedColor)
                                        Text(cell.value)
                                            .font(valueFont)
                                            .foregroundStyle(readerFgColor)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            // Measure available (clamped) width via background
                                            // GeometryReader, then compare to the natural
                                            // (fixedSize) width of the same text.
                                            .background(
                                                GeometryReader { visibleProxy in
                                                    Text(cell.value)
                                                        .font(valueFont)
                                                        .fixedSize()
                                                        .hidden()
                                                        .background(
                                                            GeometryReader { fullProxy in
                                                                Color.clear.preference(
                                                                    key: AuthorTruncationKey.self,
                                                                    value: fullProxy.size.width
                                                                         > visibleProxy.size.width + 1
                                                                )
                                                            }
                                                        )
                                                }
                                            )
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .onPreferenceChange(AuthorTruncationKey.self) {
                                    authorIsTruncated = $0
                                }
                                .popover(isPresented: $showAuthorFlyout) {
                                    Text(cell.value)
                                        .font(valueFont)
                                        .foregroundStyle(readerFgColor)
                                        .padding(14)
                                        .presentationCompactAdaptation(.popover)
                                }
                            } else if cell.kind == .published, let saved = shortDate(current.createdAt) {
                                Button { showSavedAtFlyout = true } label: {
                                    infoCardCell(label: cell.label, value: cell.value)
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showSavedAtFlyout) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(InfoCardKind.saved.displayLabel)
                                            .font(.system(size: 10, weight: .semibold, design: readerFont.swiftUIDesign))
                                            .tracking(1.0)
                                            .foregroundStyle(readerFgMutedColor)
                                        Text(saved)
                                            .font(.system(size: 13, weight: .semibold, design: readerFont.swiftUIDesign))
                                            .foregroundStyle(readerFgColor)
                                    }
                                    .padding(14)
                                    .presentationCompactAdaptation(.popover)
                                }
                            } else {
                                infoCardCell(label: cell.label, value: cell.value)
                            }
                            if idx < cells.count - 1 {
                                readerSeparatorColor
                                    .frame(width: 0.5)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(infoCardBgColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(readerSeparatorColor, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 20)
                }

                // ── Tags — centered colored soft pills ──
                if !current.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(current.tags) { tag in
                            let c = tag.color.flatMap { Color(hexString: $0) } ?? Color(.systemGray)
                            Text(tag.name)
                                .font(.system(size: 12, weight: .semibold, design: readerFont.swiftUIDesign))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(c.opacity(0.12))
                                .foregroundStyle(c)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(c.opacity(0.25), lineWidth: 0.5))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                }


            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)



        }
    }

    private func shortDate(_ iso: String?) -> String? {
        guard let s = iso, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ] {
            f.formatOptions = opts
            if let d = f.date(from: s) {
                let df = DateFormatter()
                df.dateStyle = .short
                df.timeStyle = .none
                return df.string(from: d)
            }
        }
        return nil
    }

    // MARK: – Side menu drawer

    private var sideMenuDrawer: some View {
        VStack(spacing: 0) {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Platz für Dynamic Island / Notch
                Color.clear.frame(height: safeAreaTop)

                // ── Navigation ────────────────────────────────────────────────
                menuRow(icon: "chevron.left", label: L("common.back")) {
                    showSideMenu = false
                    dismiss()
                }

                menuDivider

                // ── Aktionen ──────────────────────────────────────────────────
                menuRow(
                    icon: localIsFavorite ? "star.fill" : "star",
                    label: localIsFavorite ? L("articleReader.sideMenu.removeFavorite") : L("articleReader.sideMenu.addFavorite"),
                    tint: localIsFavorite ? .yellow : readerFgColor
                ) {
                    let snapshot = current
                    localIsFavorite.toggle()
                    Task { await viewModel.toggleFavorite(snapshot) }
                }

                // TTS läuft über denselben Proxy-Endpunkt auf Nextcloud und
                // merlin-server (siehe MerlinAPI.ttsStreamURL()).
                menuRow(
                    icon: piperTTS.hasContent ? "speaker.wave.2.fill" : "speaker.wave.2",
                    label: piperTTS.hasContent ? L("articleReader.sideMenu.stopReadAloud") : L("articleReader.sideMenu.startReadAloud"),
                    tint: piperTTS.hasContent ? .accentColor : readerFgColor
                ) {
                    if piperTTS.hasContent {
                        piperTTS.stop()
                    } else {
                        let sampleText = current.excerpt ?? current.title
                        let lang = PiperAudioService.detectLanguage(text: sampleText)
                        let estimated = current.readingTime > 0
                            ? Double(current.readingTime) * 60.0 * 0.7
                            : nil
                        piperTTS.start(articleId: current.id, lang: lang, estimatedSeconds: estimated)
                    }
                    showSideMenu = false
                }

                menuRow(icon: "textformat.size", label: L("articleReader.sideMenu.appearance")) {
                    showSideMenu = false
                    showAppearance = true
                }

                menuDivider

                // ── Teilen & Links ────────────────────────────────────────────
                if let url = URL(string: current.url) {
                    ShareLink(item: url, subject: Text(current.displayTitle)) {
                        menuRowContent(icon: "square.and.arrow.up", label: L("articleReader.sideMenu.share"))
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        showSideMenu = false
                    })

                    menuRow(icon: "safari", label: L("articleReader.sideMenu.openInBrowser")) {
                        showSideMenu = false
                        UIApplication.shared.open(url)
                    }

                    let strippedURL = current.url
                        .replacingOccurrences(of: "https://", with: "")
                        .replacingOccurrences(of: "http://", with: "")
                    if let archiveURL = URL(string: "https://archive.ph/" + strippedURL) {
                        menuRow(icon: "globe", label: L("articleReader.sideMenu.openViaArchive")) {
                            showSideMenu = false
                            UIApplication.shared.open(archiveURL)
                        }
                    }

                    menuRow(icon: "link", label: L("articleReader.sideMenu.copyLink")) {
                        UIPasteboard.general.string = current.url
                        showSideMenu = false
                    }

                    menuRow(icon: "link.badge.plus", label: L("articleReader.sideMenu.publicLink")) {
                        showSideMenu = false
                        showShareLinkSheet = true
                    }
                }

                menuDivider

                // ── Archiv & Tags ─────────────────────────────────────────────
                menuRow(
                    icon: localIsArchived ? "tray.and.arrow.up" : "archivebox",
                    label: localIsArchived ? L("articleReader.sideMenu.moveToReadingList") : L("articleReader.sideMenu.archive")
                ) {
                    let snapshot = current
                    localIsArchived = !snapshot.isArchived
                    showSideMenu = false
                    Task { await viewModel.toggleArchive(snapshot) }
                    if !snapshot.isArchived { dismiss() }
                }

                menuRow(icon: "tag", label: L("articleReader.sideMenu.editTags")) {
                    showSideMenu = false
                    showTagSheet = true
                }

                menuRow(
                    icon: articleReminder != nil ? "bell.fill" : "bell",
                    label: articleReminder != nil ? L("articleReader.sideMenu.editReminder") : L("articleReader.sideMenu.setReminder"),
                    tint: articleReminder != nil ? .orange : readerFgColor
                ) {
                    showSideMenu = false
                    showReminderSheet = true
                }

                menuDivider

                // ── Melden ────────────────────────────────────────────────────
                menuRow(icon: "exclamationmark.bubble", label: L("articleReader.sideMenu.reportArticle")) {
                    reportComment  = ""
                    reportFeedback = nil
                    reportSending  = false
                    showSideMenu   = false
                    showReportSheet = true
                }

                menuDivider

                // ── Löschen (destruktiv) ──────────────────────────────────────
                menuRow(icon: "trash", label: L("common.delete"), tint: .red) {
                    let snapshot = current
                    showSideMenu = false
                    Task { await viewModel.delete(snapshot) }
                    dismiss()
                }

            }
            .padding(.top, 8)
        }

        // ── Merlin-Logo – immer an der Bildschirmkante sichtbar ───────────
        HStack {
            Spacer()
            if let url = Bundle.module.url(forResource: "merlin-logo", withExtension: "png"),
               let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(height: 60)
                    .scaleEffect(x: -1, y: 1)
                    .opacity(0.22)
                    .padding(.trailing, 20)
            }
        }
        .padding(.vertical, 14)
        .padding(.bottom, safeAreaBottom)
        .background(readerBgColor)
        } // VStack
        .background(readerBgColor)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) {
            readerSeparatorColor.frame(width: 0.5)
        }
    }

    /// Einzelne Zeile im Seitenmenü mit Icon + Label.
    @ViewBuilder
    private func menuRow(
        icon: String,
        label: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            menuRowContent(icon: icon, label: label, tint: tint)
        }
        .buttonStyle(.plain)
    }

    /// Layout-Inhalt einer Menü-Zeile (auch als ShareLink-Label verwendbar).
    @ViewBuilder
    private func menuRowContent(icon: String, label: String, tint: Color? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint ?? readerFgColor)
                .frame(width: 26, alignment: .center)
            Text(label)
                .font(.body)
                .foregroundStyle(tint ?? readerFgColor)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var menuDivider: some View {
        readerSeparatorColor
            .frame(height: 0.5)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
    }

    // MARK: – Unified bottom area content (Bar + TTS-Panel, ohne Glass-Wrapper)

    @ViewBuilder
    private var bottomAreaStack: some View {
        VStack(spacing: 0) {
            Spacer()
            if showBottomBar {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if piperTTS.hasContent {
                piperSpeechPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: – Bottom bar
    //
    // Three icon-only buttons, equal width, separated by hairline dividers.
    //
    //  ◀  |  ⬛  |  ⬛›
    //  Back  Archive  Archive
    //        + back   + next
    //
    // Button 3 is dimmed when no next article is available.

    private var bottomBar: some View {
        HStack(spacing: 0) {

            // ── Button 1: Back ────────────────────────────────────────────────
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(readerFgColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            readerSeparatorColor.frame(width: 0.5)

            // ── Button 2: Archive + back ──────────────────────────────────────
            Button {
                let snapshot = current
                if !snapshot.isArchived {
                    Task { await viewModel.toggleArchive(snapshot) }
                }
                dismiss()
            } label: {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(readerFgColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            readerSeparatorColor.frame(width: 0.5)

            // ── Button 3: Archive + next article ──────────────────────────────
            Button {
                let snapshot = current
                if !snapshot.isArchived {
                    Task { await viewModel.toggleArchive(snapshot) }
                }
                onNavigateNext?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "archivebox.fill")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(onNavigateNext != nil ? readerFgColor : readerFgColor.opacity(0.25))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .disabled(onNavigateNext == nil)
        }
        .frame(height: 54)
        .padding(.bottom, piperTTS.hasContent ? 0 : safeAreaBottom)
        // Use the reader's own background colour for all themes so the bar
        // always blends correctly – regularMaterial would pick up the ZStack's
        // background tint which can be wrong when the theme overrides the
        // system colour scheme (e.g. dark reader theme on a light-mode device).
        // Ab iOS 26: echtes Liquid Glass statt Flat-Color (siehe ReaderBarGlassBackground).
        .readerBarGlassBackground(
            unionID: "readerBottomGlass", namespace: bottomGlassNamespace,
            bgColor: readerBgColor, separatorColor: readerSeparatorColor)
    }

    // MARK: – Piper TTS panel

    private var piperSpeechPanel: some View {
        VStack(spacing: 0) {
            readerSeparatorColor.frame(height: 0.5)

            if isAudioPlayerMinimized {
                // ── Minimized: compact bar ────────────────────────────────────
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(readerFgColor.opacity(0.55))

                    // Mini progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(readerFgColor.opacity(0.15))
                                .frame(height: 3)
                            Capsule()
                                .fill(readerFgColor.opacity(0.6))
                                .frame(width: geo.size.width * piperTTS.progress, height: 3)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 3)

                    // Play/pause or spinner
                    if piperTTS.isPlaying || piperTTS.isPaused {
                        Button { piperTTS.togglePlayPause() } label: {
                            Image(systemName: piperTTS.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(readerFgColor)
                                .frame(width: 32, height: 32)
                        }
                    } else if piperTTS.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(readerFgColor)
                            .scaleEffect(0.75)
                            .frame(width: 32, height: 32)
                    }

                    // Expand
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isAudioPlayerMinimized = false
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(readerFgColor.opacity(0.45))
                            .frame(width: 28, height: 32)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .padding(.bottom, safeAreaBottom)
                .readerBarGlassBackground(
                    topSeparator: false, unionID: "readerBottomGlass", namespace: bottomGlassNamespace,
                    bgColor: readerBgColor, separatorColor: readerSeparatorColor)

            } else {
                // ── Expanded: full panel ──────────────────────────────────────
                VStack(spacing: 12) {
                    // Minimize button
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isAudioPlayerMinimized = true
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(readerFgColor.opacity(0.4))
                                .frame(width: 28, height: 24)
                        }
                        .padding(.trailing, 16)
                    }
                    .padding(.top, 4)

                    // ── Loading spinner ──────────────────────────────────────────
                    if piperTTS.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(readerFgColor)
                            Text(piperTTS.loadingStep.isEmpty ? L("articleReader.ttsPanel.preparing") : piperTTS.loadingStep)
                                .font(.subheadline)
                                .foregroundStyle(readerFgColor.opacity(0.7))
                                .animation(.default, value: piperTTS.loadingStep)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                    }

                    // ── Error message ────────────────────────────────────────────
                    if let msg = piperTTS.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(readerFgColor.opacity(0.8))
                                .lineLimit(2)
                            Spacer()
                            Button { piperTTS.stop() } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(readerFgColor.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 40)
                    }

                    // ── Playback controls + progress bar ─────────────────────────
                    if piperTTS.isPlaying || piperTTS.isPaused {
                        // Play / Pause button
                        Button { piperTTS.togglePlayPause() } label: {
                            Image(systemName: piperTTS.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(readerFgColor)
                                .frame(width: 44, height: 44)
                        }

                        // Progress bar
                        VStack(spacing: 4) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(readerFgColor.opacity(0.15))
                                        .frame(height: 4)
                                    Capsule()
                                        .fill(readerFgColor.opacity(0.6))
                                        .frame(width: geo.size.width * piperTTS.progress, height: 4)
                                }
                            }
                            .frame(height: 4)
                            .padding(.horizontal, 20)

                            // Elapsed / total time labels
                            HStack {
                                Text(formatTime(piperTTS.elapsed))
                                Spacer()
                                if let total = piperTTS.totalDuration {
                                    Text(formatTime(total))
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(readerFgColor.opacity(0.45))
                            .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.bottom, safeAreaBottom + 8)
                .readerBarGlassBackground(
                    topSeparator: false, unionID: "readerBottomGlass", namespace: bottomGlassNamespace,
                    bgColor: readerBgColor, separatorColor: readerSeparatorColor)
            }
        }
    }

    /// Throttled `persistScrollProgress()`-Aufruf während des Scrollens (Ziel wie
    /// beim 500ms-`setTimeout` im Web-Client `_handleScroll`: laufend statt nur
    /// beim Schließen/Backgrounden speichern) – bewusst KEIN reines Debounce, das
    /// bei jedem Aufruf abbricht und neu plant. `.onScrollGeometryChange` feuert
    /// während einer Drag-Geste mit bis zu Display-Refreshrate; ein Cancel+Neu-
    /// Allocate des `DispatchWorkItem` (das die komplette, State-reiche View
    /// struct einfängt) auf JEDEM Frame erzeugte spürbaren Main-Thread-Overhead
    /// und dadurch Scroll-Hitches – auf Geräten ohne Home-Button reichte das, um
    /// die System-Geste "nach oben wischen = Home" die Touch-Race gegen die
    /// eigene Scroll-Gestenerkennung gewinnen zu lassen (App verschwindet zum
    /// Homescreen, bleibt aber im Hintergrund am Leben). Der Guard hier macht
    /// aus dem Reset-auf-jedem-Event ein Throttle: nur der erste Aufruf pro
    /// 500ms-Fenster legt ein `DispatchWorkItem` an, alle weiteren sind ein
    /// billiger nil-Check.
    private func scheduleScrollProgressSave() {
        guard scrollSaveWorkItem == nil else { return }
        let workItem = DispatchWorkItem { persistScrollProgress() }
        scrollSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Speichert die aktuelle Leseposition lokal und pusht sie zum Server.
    /// Aufgerufen aus dem debounced Scroll-Handler, aus `.onDisappear`
    /// (regulärer Reader-Schluss) und aus `.onChange(of: scenePhase)` (App wird
    /// backgrounded, ohne dass die View aus der Hierarchie entfernt wird).
    private func persistScrollProgress() {
        scrollSaveWorkItem?.cancel()
        scrollSaveWorkItem = nil
        // Respektiert die `saveProgress`-Einstellung (bisher hatte sie keine
        // Wirkung – sie wurde nur in den Settings gelesen, nie im Reader geprüft).
        guard PreferencesStore.shared.saveProgress else {
            NotificationCenter.default.post(name: .articleProgressDidUpdate, object: article.id)
            return
        }
        // Quick-Close-Guard: Ist eine Wiederherstellung fällig, aber noch nicht
        // angewendet (Reader sofort wieder geschlossen/backgrounded), steht
        // `scrollProgress` noch auf ~0 – ein Save würde die echte Position lokal
        // UND per Last-Write-Wins auf allen Geräten überschreiben. Dann lieber
        // gar nicht speichern: die bestehende Position bleibt gültig.
        guard initialFraction <= 0.001 || restoreApplied else {
            NotificationCenter.default.post(name: .articleProgressDidUpdate, object: article.id)
            return
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let progress = Double(min(max(scrollProgress, 0), 1))
        PreferencesStore.shared.saveScrollProgress(scrollProgress, for: article.id)
        PreferencesStore.shared.saveScrollTimestamp(now, for: article.id)
        NotificationCenter.default.post(name: .articleProgressDidUpdate, object: article.id)
        // Server-Push über die ProgressSyncQueue: persistiert die Position
        // zuerst (überlebt das Schließen/Backgrounden) und versucht sofort zu
        // pushen. Schlägt das offline fehl, bleibt sie vorgemerkt und wird per
        // NWPathMonitor bei Reconnect erneut gesendet (analog SettingsSyncQueue).
        ProgressSyncQueue.shared.enqueue(articleId: article.id, progress: progress, updatedAt: now)
        Task { await ProgressSyncQueue.shared.retryIfNeeded() }
    }

    /// Schreibt alle Appearance-Settings (Theme, Font, FontSize, LineHeight) im Hintergrund auf den Server.
    /// Echte Serverfehler werden still ignoriert – der lokale Zustand bleibt immer die Quelle der
    /// Wahrheit. Netzwerkfehler (z. B. offline) merkt sich `SettingsSyncQueue` jedoch und holt den
    /// Push automatisch nach, sobald die Verbindung zurückkehrt – sonst würden offline geänderte
    /// Einstellungen nie auf anderen Geräten ankommen.
    private func pushAppearanceToServer() {
        Task {
            do {
                try await MerlinAPI.shared.updateSettings(PreferencesStore.shared.toServerDict())
            } catch {
                if case MerlinAPIError.networkError = error {
                    SettingsSyncQueue.shared.markDirty()
                }
            }
        }
    }

    /// Formatiert Millisekunden als m:ss, z.B. 142_000 ms → "2:22".
    private func formatTime(_ ms: Double) -> String {
        let total = max(0, Int(ms / 1000))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: – Hero image injection

    /// Prepends the cached hero image as a `<figure>` block when the first 500
    /// characters of `content` contain no image-related tag (`<img`, `<picture`,
    /// `<figcaption`).  Only fires when the image is already on disk so no
    /// network request is triggered here.
    private func injectHeroImageIfNeeded(into content: String) -> String {
        // Bei ARD/ZDF/Arte dient dasselbe Titelbild bereits als Player-Cover
        // (siehe NativeVideoPlayerCard) - ein zusätzliches Einfügen hier würde es
        // nur gleich wieder per stripHeroImageIfShownAsVideoCover() entfernen.
        guard !NativeVideoHost.matches(current.url) else { return content }

        let prefix     = content.prefix(500).lowercased()
        let hasImage   = prefix.contains("<img")
                      || prefix.contains("<figure")
                      || prefix.contains("<picture")
        guard !hasImage else { return content }

        guard let urlStr   = current.imageUrl,
              let url      = URL(string: urlStr),
              let localURL = ImageCacheService.shared.localURL(for: url)
        else { return content }

        let imgHTML = "<figure><img src=\"\(localURL.lastPathComponent)\" alt=\"\"></figure>\n"
        return imgHTML + content
    }

    /// Entfernt das erste Bild aus dem gerenderten Artikeltext, wenn ARD/ZDF/Arte bereits als
    /// Player-Cover dasselbe Titelbild zeigt (siehe NativeVideoPlayerCard) - sonst erscheint es
    /// doppelt: einmal als Cover, einmal im Text darunter.
    ///
    /// Matched absichtlich NICHT über die exakte Bild-URL (`data-merlin-original-src` vs.
    /// `current.imageUrl`): ARD liefert für dasselbe Foto im Artikeltext oft eine andere
    /// Auflösungs-/Query-Variante als für das separat gespeicherte Teaser-Bild, ein
    /// URL-Abgleich schlug deshalb in der Praxis fehl und blendete gar nichts aus. Da
    /// injectHeroImageIfNeeded() für Video-Artikel ohnehin nichts mehr einfügt, ist das erste
    /// Bild im Text zuverlässig genau das Titelbild, das gescrapte ARD-Seiten selbst voranstellen.
    private func stripHeroImageIfShownAsVideoCover(in content: String) -> String {
        guard NativeVideoHost.matches(current.url),
              let regex = Self.firstImageOrFigureRegex
        else { return content }

        let ns = content as NSString
        guard let match = regex.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)),
              let range = Range(match.range, in: content)
        else { return content }

        var result = content
        result.removeSubrange(range)
        return result
    }

    private static let firstImageOrFigureRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<figure>\s*<img\b[^>]*>\s*(?:<figcaption>.*?</figcaption>\s*)?</figure>|<img\b[^>]*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    // MARK: – Lazy-loading-Fallback

    /// Attribute, unter denen Quellseiten/Scraper das eigentliche Bild-URL
    /// ablegen, wenn sie selbst Lazy-Loading nutzen (`src` bleibt dann leer
    /// oder zeigt auf ein 1×1-Platzhalterpixel, bis JS auf der Originalseite
    /// es beim Scrollen ins Bild nachträgt — was in unserem statischen,
    /// einmal gescrapten Artikel-HTML nie passiert und das Bild sonst auf
    /// Dauer leer/kaputt lässt, siehe `attachError`-Kommentar unten).
    private static let lazyImageAttributes = ["data-src", "data-lazy-src", "data-original", "data-actualsrc"]

    private static let imgTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<img\b[^>]*>"#,
        options: .caseInsensitive
    )

    /// `(?<![\w-])` verhindert, dass z. B. "data-src" fälschlich als "src"
    /// erkannt wird — ohne das Lookbehind matcht `src\s*=` auch das
    /// "src="-Suffix von "data-src=".
    private static let imgSrcAttrRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![\w-])src\s*=\s*"([^"]*)""#,
        options: .caseInsensitive
    )

    private static func attributeValue(named name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\w-])\#(name)\s*=\s*"([^"]*)""#,
            options: .caseInsensitive
        ) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    /// Leer oder ein bekanntes 1×1-/Blank-Platzhalterbild gilt nicht als
    /// "echte" Bildquelle — genau die Fälle, die Lazy-Loading-Bibliotheken
    /// als Stand-in nutzen, bevor das eigentliche `src` per JS nachgetragen wird.
    private static func isUsableImageSrc(_ src: String) -> Bool {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("data:image/gif;base64,R0lGOD") { return false } // klassisches 1×1-GIF
        if trimmed == "data:," || trimmed == "about:blank" { return false }
        return true
    }

    /// Trägt für `<img>`-Tags ohne brauchbares `src` (siehe `isUsableImageSrc`)
    /// den Wert des ersten gefundenen Lazy-Load-Attributs (`lazyImageAttributes`)
    /// in `src` ein. Muss vor `rewriteImageURLs` laufen, sonst greift dessen
    /// Cache-Lookup nie, weil der nur ein bereits vorhandenes `src` umschreibt.
    private func promoteLazyImageAttributes(in content: String) -> String {
        guard let imgRegex = Self.imgTagRegex,
              let srcRegex  = Self.imgSrcAttrRegex else { return content }

        let ns = content as NSString
        var result = content
        let tagMatches = imgRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))

        // Auch hier in umgekehrter Reihenfolge ersetzen, damit Indizes der
        // noch nicht verarbeiteten Treffer gültig bleiben (siehe rewriteImageURLs).
        for tagMatch in tagMatches.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag   = String(result[tagRange])
            let tagNS = tag as NSString
            let srcMatch = srcRegex.firstMatch(in: tag, range: NSRange(location: 0, length: tagNS.length))
            let currentSrc = srcMatch.flatMap { Range($0.range(at: 1), in: tag) }.map { String(tag[$0]) }
            if let currentSrc, Self.isUsableImageSrc(currentSrc) { continue }

            guard let lazyValue = Self.lazyImageAttributes
                .compactMap({ Self.attributeValue(named: $0, in: tag) })
                .first(where: { !$0.isEmpty })
            else { continue }

            let escaped = lazyValue.replacingOccurrences(of: "\"", with: "&quot;")
            var newTag = tag
            if let srcMatch, let valueRange = Range(srcMatch.range(at: 1), in: newTag) {
                // Vorhandenes (leeres/Platzhalter-) src="..." in-place ersetzen.
                newTag.replaceSubrange(valueRange, with: escaped)
            } else {
                // Kein src-Attribut vorhanden — direkt nach "<img" einfügen.
                let insertAt = newTag.index(newTag.startIndex, offsetBy: 4)
                newTag.insert(contentsOf: " src=\"\(escaped)\"", at: insertAt)
            }
            result.replaceSubrange(tagRange, with: newTag)
        }
        return result
    }

    // MARK: – Image URL rewriting

    /// Replaces `src="https://..."` in `<img>` tags with `src="file:///..."`
    /// when the image is available in `ImageCacheService`.  Called synchronously
    /// from `buildReaderHTML`; safe because `localURL(for:)` is `nonisolated`.
    private static let imgSrcRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(<img\b[^>]*\ssrc=")([^"]+)(")"#,
        options: .caseInsensitive
    )


    private func rewriteImageURLs(in content: String) -> String {
        guard let regex = Self.imgSrcRegex else { return content }

        let ns = content as NSString
        var result = content
        // Process in reverse order so string indices remain valid after each replacement.
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard let urlRange   = Range(match.range(at: 2), in: result),
                  let quoteRange = Range(match.range(at: 3), in: result) else { continue }
            let rawStr = String(result[urlRange])
            let urlStr = rawStr
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;",  with: "'")
            guard let url      = URL(string: urlStr),
                  let localURL = ImageCacheService.shared.localURL(for: url) else { continue }
            // quoteRange (closing ") comes after urlRange — process last-first so earlier indices stay valid
            let safeOrig = urlStr.replacingOccurrences(of: "\"", with: "&quot;")
            result.replaceSubrange(quoteRange, with: "\" data-merlin-original-src=\"\(safeOrig)\"")
            result.replaceSubrange(urlRange, with: localURL.lastPathComponent)
        }
        return result
    }

    // MARK: – YouTube-Embed rewriting

    /// Matched ein komplettes `<iframe ...>`-Starttag (kein `</iframe>` nötig,
    /// das Tag trägt alle relevanten Attribute bereits in sich).
    private static let iframeTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<iframe\b[^>]*>"#,
        options: .caseInsensitive
    )

    /// Video-ID (Gruppe 1) + optionaler Query-String (Gruppe 2) aus einer
    /// YouTube-Embed-URL. `-nocookie` optional, weil sanitizeHtml() im Backend
    /// beide Hosts durchlässt (siehe ContentExtractorService::isAllowedYoutubeEmbedSrc).
    private static let youtubeEmbedSrcRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^https://(?:www\.)?youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]+)(?:\?(.*))?$"#,
        options: .caseInsensitive
    )

    /// Ersetzt jedes `<iframe src="https://[www.]youtube[-nocookie].com/embed/ID…">`
    /// durch eine tippbare Vorschau-Karte (`.merlin-yt-embed`, Thumbnail +
    /// Play-Button); `merlinYoutubeTapJS` postet einen `youtubeTap`-Message an
    /// Swift, das darauf mit einem `fullScreenCover` (`YouTubePlayerView`)
    /// reagiert.
    ///
    /// Grund für den Umweg über eine native Sheet-Präsentation statt eines
    /// direkten iframes: Dieser Reader lädt den Artikel-Inhalt über
    /// `loadFileURL` (siehe `updateUIView` oben) – eine `file://`-Origin. Ein
    /// naiv eingebettetes YouTube-`<iframe>` bricht darin mit "Error 153"
    /// ab (kein gültiger Referrer/keine gültige Origin). Der naheliegende
    /// Fix – ein Proxy-`<iframe>` auf der echten https-Domain der Instanz,
    /// selbst wieder eingebettet in diese file://-Seite – scheiterte
    /// ebenfalls: WKWebView wertet CSP `frame-ancestors` für eine
    /// `file://`-Elternseite nicht zuverlässig aus und zeigt dann einfach
    /// nichts (weiße Fläche) statt eines Fehlers. Eine SEPARATE WKWebView
    /// ohne Elternseite (Top-Level-Navigation aus `YouTubePlayerView`) hat
    /// dieses Problem strukturell nicht, weil `X-Frame-Options`/
    /// `frame-ancestors` nur greift, wenn überhaupt eine Elternseite existiert.
    private func rewriteYouTubeEmbeds(in content: String) -> String {
        guard let tagRegex   = Self.iframeTagRegex,
              let srcRegex   = Self.imgSrcAttrRegex,
              let embedRegex = Self.youtubeEmbedSrcRegex
        else { return content }

        let ns = content as NSString
        var result = content
        let tagMatches = tagRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))

        // Rückwärts ersetzen, damit die Indizes noch nicht verarbeiteter
        // Treffer gültig bleiben (siehe rewriteImageURLs).
        for tagMatch in tagMatches.reversed() {
            guard let tagRange = Range(tagMatch.range, in: result) else { continue }
            let tag   = String(result[tagRange])
            let tagNS = tag as NSString

            guard let srcMatch = srcRegex.firstMatch(in: tag, range: NSRange(location: 0, length: tagNS.length)),
                  let srcRange = Range(srcMatch.range(at: 1), in: tag)
            else { continue }

            let decodedSrc = String(tag[srcRange])
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;",  with: "'")
            let decodedNS = decodedSrc as NSString

            guard let embedMatch = embedRegex.firstMatch(in: decodedSrc, range: NSRange(location: 0, length: decodedNS.length)),
                  let idRange = Range(embedMatch.range(at: 1), in: decodedSrc)
            else { continue } // kein YouTube-Embed (die Allowlist im Backend lässt nur diese durch,
                               // aber lokal gecachte/ältere Artikel könnten noch anderes enthalten)

            let videoId = String(decodedSrc[idRange])

            // Startzeit best-effort aus der Original-Query übernehmen
            // (?start=90 oder ?t=90 / ?t=90s — YouTube akzeptiert beide Namen,
            // wir normalisieren auf "start" für den Proxy-Endpunkt).
            var startSeconds: String?
            let startGroupRange = embedMatch.range(at: 2)
            if startGroupRange.location != NSNotFound, let queryRange = Range(startGroupRange, in: decodedSrc) {
                let query = String(decodedSrc[queryRange])
                for pair in query.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, parts[0] == "start" || parts[0] == "t" else { continue }
                    let digits = parts[1].filter(\.isNumber)
                    if !digits.isEmpty { startSeconds = digits; break }
                }
            }

            // i.ytimg.com liefert Thumbnails ohne Referrer-/Origin-Prüfung —
            // anders als der eingebettete Player betrifft das dortige
            // file://-Problem nur <iframe>, nicht <img>.
            let safeVideoId    = videoId.replacingOccurrences(of: "\"", with: "&quot;")
            let safeStartValue = (startSeconds ?? "").replacingOccurrences(of: "\"", with: "&quot;")
            let placeholder = """
            <div class="merlin-yt-embed" data-yt-id="\(safeVideoId)" data-yt-start="\(safeStartValue)" \
            style="position:relative;cursor:pointer;border-radius:8px;overflow:hidden;background:#000;aspect-ratio:16/9;margin:8px 0;">\
            <img src="https://i.ytimg.com/vi/\(safeVideoId)/hqdefault.jpg" alt="" \
            style="width:100%;height:100%;object-fit:cover;display:block;margin:0;border-radius:0;">\
            <div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;">\
            <div style="width:56px;height:56px;border-radius:50%;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;">\
            <svg width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M8 5v14l11-7z"/></svg>\
            </div></div></div>
            """

            result.replaceSubrange(tagRange, with: placeholder)
        }
        return result
    }

    // MARK: – Catch-up fetch for images the bulk prefetch hasn't reached yet
    //
    // `rewriteImageURLs` above only swaps in a local `file://` path when the
    // image is ALREADY in `ImageCacheService` at the moment this HTML is
    // built. Anything not yet cached is left with its original remote
    // `https://` src, which WKWebView then requests directly — WITHOUT the
    // Referer header `ImageCacheService.downloadAndStore` sets specifically
    // to satisfy hotlink protection. Sites that check Referer reject that
    // direct WKWebView request even though the exact same URL downloads fine
    // via our own background prefetch. Since the bulk `prefetch(for:)` job
    // (max. 4 concurrent downloads across ALL unarchived articles) may simply
    // not have reached this article's images yet when the reader opens, we
    // fetch this article's own images here — same Referer-aware
    // `fetchSingle` — and patch any that succeed directly into the live DOM
    // (no full page reload, which would reset scroll position and any
    // in-progress selection/highlight state).

    /// Builds a JSON-safe JS snippet that swaps the `src` of any `<img>` still
    /// pointing at `remote` to the now-cached local filename. Uses
    /// `JSONEncoder` (not manual escaping) for the string literals, matching
    /// the pattern already used for `merlinUpdateTempId` below.
    private nonisolated static func swapImageSrcJS(remote: URL, localFilename: String) -> String? {
        guard let remoteData = try? JSONEncoder().encode(remote.absoluteString),
              let remoteJSON = String(data: remoteData, encoding: .utf8),
              let localData  = try? JSONEncoder().encode(localFilename),
              let localJSON  = String(data: localData, encoding: .utf8)
        else { return nil }
        return """
        document.querySelectorAll('img').forEach(function(img){
          if (img.getAttribute('src') === \(remoteJSON)) { img.setAttribute('src', \(localJSON)); }
        });
        """
    }

    /// Fetches (with correct Referer) every content image not yet on disk and
    /// swaps it into the already-loaded page as each download completes.
    /// Cancelled automatically if the reader closes or the article changes,
    /// since it's driven by `.task(id:)`.
    private func fetchMissingContentImages() async {
        guard let raw = current.content, !raw.isEmpty else { return }
        // Re-run the same lazy-attribute promotion the HTML pipeline uses so
        // we look for the real (post-promotion) URLs, not `data-src` etc.
        let promoted = promoteLazyImageAttributes(in: raw)
        let candidates = ImageCacheService.shared.contentImageURLs(in: promoted)
        guard !candidates.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var slots = 4
            for url in candidates {
                guard !Task.isCancelled else { break }
                // Already cached — buildReaderHTML already picked this one up.
                guard ImageCacheService.shared.localURL(for: url) == nil else { continue }
                if slots == 0 { await group.next(); slots += 1 }
                group.addTask {
                    guard await ImageCacheService.shared.fetchSingle(url: url),
                          let localURL = ImageCacheService.shared.localURL(for: url),
                          let js = Self.swapImageSrcJS(remote: url, localFilename: localURL.lastPathComponent)
                    else { return }
                    await MainActor.run {
                        highlightActions.webView?.evaluateJavaScript(js)
                    }
                }
                slots -= 1
            }
        }
    }

    // MARK: – HTML builder

    private func buildReaderHTML(content: String,
                                 fontSize: Int = 17,
                                 theme: ReaderTheme = .auto,
                                 font: ReaderFont = .system,
                                 lineHeight: Double = 1.6,
                                 developerMode: Bool = false) -> String {
        // Determine effective dark/light based on theme override or system setting
        let effectiveDark: Bool = {
            switch theme {
            case .auto:  return colorScheme == .dark
            case .dark:  return true
            case .light, .sepia: return false
            }
        }()
        let isSepia = theme == .sepia

        let bg             = isSepia ? "#f4ecd8" : (effectiveDark ? "#000000" : "#ffffff")
        let fg             = isSepia ? "#3b2f1e" : (effectiveDark ? "#e5e5ea" : "#1c1c1e")
        let fgMuted        = isSepia ? "#7a6350" : (effectiveDark ? "#98989d" : "#6e6e73")
        let accent         = "#0082c9"
        let imgPlaceholderBg = isSepia ? "#e8d9be" : (effectiveDark ? "#2c2c2e" : "#f2f2f7")

        return """
        <!DOCTYPE html>
        <html lang="de">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
          <style>
            *, *::before, *::after { box-sizing: border-box; max-width: 100%; }
            html, body { overflow-x: hidden; }
            img, video, iframe, embed, object, svg {
              max-width: 100% !important;
              height: auto;
            }
            table {
              max-width: 100% !important;
              display: block;
              overflow-x: auto;
              -webkit-overflow-scrolling: touch;
            }
            pre, code {
              max-width: 100%;
              overflow-x: auto;
              -webkit-overflow-scrolling: touch;
              white-space: pre;
              word-wrap: normal;
            }
            body {
              margin: 0;
              padding: 0 20px 40px;
              background: \(bg);
              color: \(fg);
              font-family: \(font.cssValue);
              font-size: \(fontSize)px;
              line-height: \(String(format: "%.2f", lineHeight));
            }
            h1, h2, h3 { line-height: 1.3; margin-top: 1.6em; margin-bottom: 0.4em; }
            body > *:first-child { margin-top: 0 !important; }
            body > *:first-child > *:first-child { margin-top: 0 !important; }
            h1 { font-size: 1.5em; }
            h2 { font-size: 1.25em; }
            h3 { font-size: 1.1em; }
            p { margin: 0 0 1em; }
            a { color: \(fg) !important; text-decoration: underline; text-decoration-color: \(fgMuted); }
            img { max-width: 100%; height: auto; border-radius: 8px; margin: 8px 0; }
            video { display: block; max-width: 100%; height: auto; border-radius: 8px; margin: 8px 0; }
            blockquote {
              margin: 1.5em 0; padding: 0;
              text-align: center;
              font-family: \(ReaderFont.serif.cssValue);
              font-size: 1.3em;
              font-style: italic;
              line-height: 1.45;
              color: \(accentColorHex);
            }
            blockquote p { margin: 0 0 0.4em; }
            blockquote cite, blockquote footer {
              display: block;
              width: 100%;
              font-family: \(ReaderFont.system.cssValue);
              font-size: 0.6em;
              font-style: normal;
              text-align: center !important;
              margin-top: 0.3em;
              color: \(accentColorHex);
            }
            /* Some sources place the attribution in a paragraph right after the
               blockquote (e.g. <blockquote>…</blockquote><p><cite>Name</cite></p>)
               instead of nesting it inside the blockquote itself. */
            blockquote + p {
              display: block;
              width: 100%;
              text-align: center !important;
              font-family: \(ReaderFont.system.cssValue);
              font-size: 0.85em;
              color: \(accentColorHex);
            }
            blockquote + p cite, blockquote + p cite * { font-style: normal; }
            pre, code {
              background: \(effectiveDark ? "#2c2c2e" : "#f2f2f7");
              border-radius: 6px; font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em;
            }
            code { padding: 2px 5px; }
            pre { padding: 12px; overflow-x: auto; }
            pre code { background: none; padding: 0; }
            figure { margin: 1em 0 0; }
            figure:first-child { margin-top: 0; }
            figure img, figure video { display: block; margin-bottom: 0; }
            figcaption { font-size: 0.75em; line-height: 1.4; color: \(accentColorHex); text-align: left; margin-top: 2px; margin-bottom: 1em; }
            /* p { margin: 0 0 1em } setzt margin-top explizit auf 0 — ohne diese
               Regel klebt der erste Textblock direkt am Bild darüber (img selbst
               hat zwar margin-bottom, figure aber bewusst nicht, siehe oben). */
            img + p, video + p, figure + p { margin-top: 1em; }
            hr { border: none; border-top: 1px solid \(effectiveDark ? "#2c2c2e" : "#e5e5ea"); margin: 2em 0; }
            ul, ol { padding-left: 1.5em; }
            li { margin-bottom: 0.3em; }
            table { border-collapse: collapse; width: 100%; font-size: 0.9em; overflow-x: auto; display: block; }
            th, td { padding: 8px 12px; border: 1px solid \(effectiveDark ? "#3a3a3c" : "#d1d1d6"); text-align: left; }
            th { background: \(effectiveDark ? "#2c2c2e" : "#f2f2f7"); font-weight: 600; }
            .merlin-infobox {
              background: \(isSepia ? "#e8d9be" : (effectiveDark ? "#1e2d3d" : "#f0f7ff"));
              border-left: 4px solid \(isSepia ? "#8b6914" : accent);
              border-radius: 0 8px 8px 0;
              padding: 14px 16px;
              margin: 1.5em 0;
              font-size: 0.93em;
              line-height: 1.6;
              color: \(fg);
            }
            .merlin-infobox > *:first-child { margin-top: 0; }
            .merlin-infobox > *:last-child  { margin-bottom: 0; }
            .merlin-infobox a { color: \(isSepia ? "#8b6914" : accent) !important; text-decoration-color: \(isSepia ? "#8b691480" : "#0082c980"); }
          </style>
        </head>
        <body>
          \(rewriteYouTubeEmbeds(in: stripHeroImageIfShownAsVideoCover(in: rewriteImageURLs(in: injectHeroImageIfNeeded(into: promoteLazyImageAttributes(in: content))))))
          <script>\(merlinHighlightJS)</script>
          <script>
          (function(){
            var t=null;
            var ro=new ResizeObserver(function(){
              clearTimeout(t);
              t=setTimeout(function(){
                window.webkit.messageHandlers.resize.postMessage(document.body.scrollHeight);
              },100);
            });
            ro.observe(document.body);
          })();
          </script>
          \(developerMode ? "<script>\(merlinDebugJS)</script>" : "")
          <script>\(merlinImageTapJS)</script>
          <script>\(merlinYoutubeTapJS)</script>
          <script>
          (function(){
            var PH_BG = '\(imgPlaceholderBg)';
            var PH_FG = '\(fgMuted)';
            var PH_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="'+PH_FG+'" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2.5" ry="2.5"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>';

            function makePlaceholder(img) {
              var attrW = parseInt(img.getAttribute('width'))  || 0;
              var attrH = parseInt(img.getAttribute('height')) || 0;
              // Content width = body clientWidth minus 20 px padding on each side.
              var contentW = document.body.clientWidth - 40;
              // Portrait when original image height exceeds width; otherwise landscape.
              var isPortrait = attrW > 0 && attrH > 0 && attrH > attrW;
              var maxH = Math.round(isPortrait ? contentW * 16 / 9 : contentW * 9 / 16);
              var ph = document.createElement('div');
              ph.style.cssText = [
                'display:flex',
                'flex-direction:column',
                'align-items:center',
                'justify-content:center',
                'gap:8px',
                'background:' + PH_BG,
                'border-radius:8px',
                'margin:8px 0',
                'width:100%',
                'height:' + maxH + 'px',
                'min-height:60px'
              ].join(';');
              ph.innerHTML = PH_SVG + '<span style="font-size:12px;color:'+PH_FG+';text-align:center;padding:0 12px">Webseite verhindert Bilddownload</span>';
              if (img.parentNode) img.parentNode.replaceChild(ph, img);
            }

            function attachError(img) {
              if (img.dataset.merlinPhAttached) return;
              img.dataset.merlinPhAttached = '1';
              if (img.complete && img.naturalWidth === 0 && img.src) {
                makePlaceholder(img);
              } else {
                img.addEventListener('error', function(){ makePlaceholder(img); }, {once:true});
              }
            }

            document.querySelectorAll('img').forEach(attachError);
            new MutationObserver(function(ms){
              ms.forEach(function(m){
                m.addedNodes.forEach(function(n){
                  if(n.tagName==='IMG') attachError(n);
                  else if(n.querySelectorAll) n.querySelectorAll('img').forEach(attachError);
                });
              });
            }).observe(document.body, {childList:true, subtree:true});
          })();
          </script>
        </body>
        </html>
        """
    }
}

// MARK: – Appearance sheet

private struct AppearanceSheet: View {
    @Binding var fontSize:   Int
    @Binding var theme:      ReaderTheme
    @Binding var readerFont: ReaderFont
    @Binding var lineHeight: Double
    var onAccentColorChange: () -> Void = {}

    @AppStorage("merlin_accent_progress_color") private var accentColorHex: String = "#FF3B30"

    private let fontSizes = [13, 15, 17, 19, 21, 24]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            fontSizeRow
            themeRow
            fontRow
            lineHeightRow
            accentColorRow
            Spacer()
        }
        .padding(20)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var fontSizeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("articleReader.appearance.fontSize")).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(fontSizes, id: \.self) { size in
                    Button { fontSize = size } label: {
                        let selected = fontSize == size
                        Text("\(size)")
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    if size != fontSizes.last { Divider() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("articleReader.appearance.theme")).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ReaderTheme.allCases, id: \.self) { t in
                    Button { theme = t } label: {
                        let selected = theme == t
                        VStack(spacing: 4) {
                            Image(systemName: t.systemImage).font(.system(size: 18))
                            Text(t.label).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                            selected ? Color.accentColor : Color(.separator),
                            lineWidth: selected ? 1.5 : 0.5))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fontRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("articleReader.appearance.font")).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ReaderFont.allCases, id: \.self) { f in
                    Button { readerFont = f } label: {
                        let selected = readerFont == f
                        let labelFont: Font = {
                            switch f {
                            case .serif: return .system(.subheadline, design: .serif)
                            case .mono:  return .system(.subheadline, design: .monospaced)
                            default:     return .subheadline
                            }
                        }()
                        Text(f.label)
                            .font(labelFont)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                                selected ? Color.accentColor : Color(.separator),
                                lineWidth: selected ? 1.5 : 0.5))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lineHeightRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("articleReader.appearance.lineSpacing")).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $lineHeight, in: 1.2...2.0, step: 0.1)
                Text(String(format: "%.1f", lineHeight))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var accentColorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("articleReader.appearance.accentColor")).font(.footnote).foregroundStyle(.secondary)
            ColorPicker(selection: Binding(
                get: { Color(hexString: accentColorHex) ?? .red },
                set: { accentColorHex = $0.hexString }
            ), supportsOpacity: false) {
                Text(L("articleReader.appearance.progressAndHighlights"))
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onChange(of: accentColorHex) { _, _ in
                PreferencesStore.shared.accentProgressColorHex = accentColorHex
                onAccentColorChange()
            }
        }
    }


}

// MARK: – Tag editing sheet

struct ArticleTagSheet: View {
    @Environment(\.dismiss) private var dismiss

    let article: Article
    let allTags: [Tag]
    let onSave: (Set<Int>) -> Void

    @State private var selectedTagIds: Set<Int>
    @State private var newTagInput:    String   = ""
    @State private var pendingTags:    [String] = []
    @State private var isSaving:       Bool     = false

    init(article: Article, allTags: [Tag], onSave: @escaping (Set<Int>) -> Void) {
        self.article = article
        self.allTags = allTags
        self.onSave  = onSave
        _selectedTagIds = State(initialValue: Set(article.tags.map { $0.id }))
    }

    private var tagSuggestions: [Tag] {
        let q = newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return allTags.filter {
            !selectedTagIds.contains($0.id) &&
            $0.name.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Existing tags grid
                    if !allTags.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                            ForEach(allTags) { tag in
                                let isSelected = selectedTagIds.contains(tag.id)
                                let chipColor: Color = tag.color.flatMap { Color(hexString: $0) } ?? .accentColor
                                Button {
                                    if isSelected { selectedTagIds.remove(tag.id) }
                                    else          { selectedTagIds.insert(tag.id) }
                                } label: {
                                    HStack(spacing: 6) {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                        }
                                        Text(tag.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(isSelected ? chipColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                                    .foregroundStyle(isSelected ? chipColor : Color.secondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                                        isSelected ? chipColor : Color(.separator),
                                        lineWidth: isSelected ? 1.0 : 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // New tag input
                    HStack {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                        TextField(L("articleReader.tagSheet.newTagPlaceholder"), text: $newTagInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { commitNewTag() }
                        if !newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(L("common.add")) { commitNewTag() }
                                .font(.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Suggestions for matching existing tags
                    if !tagSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tagSuggestions) { tag in
                                    let chipColor: Color = tag.color.flatMap { Color(hexString: $0) } ?? .accentColor
                                    Button {
                                        selectedTagIds.insert(tag.id)
                                        newTagInput = ""
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus").font(.caption2.weight(.semibold))
                                            Text(tag.name).font(.caption).lineLimit(1)
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(chipColor.opacity(0.10))
                                        .foregroundStyle(chipColor)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(chipColor.opacity(0.35), lineWidth: 0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // Pending new tags (will be created on save)
                    if !pendingTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(pendingTags, id: \.self) { name in
                                    HStack(spacing: 4) {
                                        Text(name).font(.caption)
                                        Button { pendingTags.removeAll { $0 == name } } label: {
                                            Image(systemName: "xmark").font(.caption2)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(L("articleReader.tagSheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { save() }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                        .overlay {
                            if isSaving { ProgressView().progressViewStyle(.circular) }
                        }
                }
            }
        }
    }

    private func commitNewTag() {
        let name = newTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !pendingTags.contains(where: { $0.lowercased() == name.lowercased() }),
              !allTags.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { newTagInput = ""; return }
        pendingTags.append(name)
        newTagInput = ""
    }

    private func save() {
        isSaving = true
        Task {
            var finalIds = selectedTagIds
            if !pendingTags.isEmpty {
                let created = (try? await MerlinAPI.shared.resolveTagIds(for: pendingTags)) ?? []
                created.forEach { finalIds.insert($0) }
            }
            onSave(finalIds)
            dismiss()
        }
    }
}

// MARK: – Undo toast (reader variant — theme-aware)

/// Toast banner shown after a successful shake-to-undo inside the article reader.
/// Uses the reader background colour so it blends with the chosen theme.
private struct ReaderUndoToast: View {
    let message: String
    let bgColor: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.title3)
            Text(message)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(bgColor.opacity(0.95), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

// MARK: – Paywall warning banner

/// Nicht-blockierender Warnbanner: zeigt, dass der Artikeltext wegen einer Paywall
/// unvollständig geladen wurde (`Article.requiresLoginDomain` gesetzt – siehe Docblock dort).
/// Bietet direkt einen Weg zum Hinterlegen der Zugangsdaten sowie einen manuellen Retry.
private struct PaywallWarningBanner: View {
    let domain: String
    let isRetrying: Bool
    let onConnect: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                Text(String(format: L("articleReader.paywallBanner.message"), domain))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button(L("articleReader.paywallBanner.connectButton"), action: onConnect)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button {
                    onRetry()
                } label: {
                    if isRetrying {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Text(L("articleReader.paywallBanner.retryButton"))
                    }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRetrying)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
    }
}
