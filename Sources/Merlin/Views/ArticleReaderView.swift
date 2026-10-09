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
  // Stelle, die nur kommentiert (nicht markiert) wurde. Der Server legt sie
  // mit dem ersten Kommentar an und entfernt sie mit dem letzten.
  const COMMENT_COLOR='comment';

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

  // Verfasser-Farbe vom Server (#rrggbb); alles andere wird ignoriert.
  function authorColorOf(h){
    return h&&typeof h.authorColor==='string'&&/^#[0-9a-f]{6}$/i.test(h.authorColor)?h.authorColor:null;
  }

  function wrapRange(range,color,hlId,author){
    if(range.collapsed)return;
    const colorDef=COLORS.find(c=>c.id===color)||COLORS[0];
    const makeSpan=()=>{
      const s=document.createElement('mark');
      s.className='merlin-highlight';s.dataset.highlightId=String(hlId);s.dataset.highlightColor=color;
      // Kommentierte Stelle: nur unterstrichen (in der Farbe des Verfassers),
      // Text und Hintergrund bleiben. Nur Einzel-Eigenschaften: die Kurzform
      // -webkit-text-decoration setzte in WebKit Farbe und Dicke zurück
      // (schwarze, dünne Linie).
      if(color===COMMENT_COLOR){
        s.style.cssText='background-color:transparent;color:inherit;text-decoration-line:underline;-webkit-text-decoration-line:underline;text-decoration-color:var(--mh-author,#c2410c);-webkit-text-decoration-color:var(--mh-author,#c2410c);text-decoration-thickness:2px;text-underline-offset:3px;box-decoration-break:clone;-webkit-box-decoration-break:clone;cursor:pointer;';
        if(author)s.style.setProperty('--mh-author',author);
        return s;
      }
      // All five highlight swatches are light pastels, so the text needs a
      // fixed dark colour rather than `color:inherit` — in the dark reader
      // theme, inherited text is near-white and unreadable on a light
      // highlight background. #1c1c1e matches the app's own light-theme
      // text colour (see textColor(for:) below).
      s.style.cssText='background-color:'+colorDef.hex+';color:#1c1c1e;border-radius:2px;padding:0 1px;box-decoration-break:clone;-webkit-box-decoration-break:clone;cursor:pointer;';
      if(author)s.style.setProperty('--mh-author',author);
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
      if(!r.collapsed)wrapRange(r,h.color,h.id,authorColorOf(h));
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
      hasHighlight:selectedHighlightId!==null,
      highlightId:selectedHighlightId!==null?String(selectedHighlightId):null
    });
  }

  function clearNativeSelectionToolbar(){
    window.webkit.messageHandlers.selectionToolbar.postMessage({cleared:true});
  }

  // `comment`: nach dem Speichern gleich den Kommentar-Dialog für die neue
  // Markierung öffnen (Knopf "Kommentieren" in der nativen Leiste).
  function applyHighlight(color,comment){
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
      window.webkit.messageHandlers.highlights.postMessage({action:'create',data:{highlightedText:text,startXpath:sx,startOffset:startOffset,endXpath:ex,endOffset:endOffset,color:color,tempId:tempId,comment:!!comment}});
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
  // Löschen über die id statt über die Auswahl: nach der Rückfrage "Markierung
  // hat Kommentare" kann die Auswahl schon weg sein.
  window.merlinDeleteHighlightFromNative=function(id){
    id=String(id);
    if(selectedHighlightId!==null&&String(selectedHighlightId)===id){selectedHighlightId=null;pendingRange=null;window.getSelection()?.removeAllRanges();}
    removeHighlightSpans(id);
    window.webkit.messageHandlers.highlights.postMessage({action:'delete',id:id});
    flushDeferred();
  };
  function openCommentsFor(id){
    id=String(id);
    const text=Array.from(document.querySelectorAll('mark.merlin-highlight[data-highlight-id="'+id+'"]')).map(e=>e.textContent).join('');
    window.webkit.messageHandlers.highlights.postMessage({action:'openComments',id:id,text:text});
  }

  // Knopf "Kommentieren": an einer bestehenden Markierung deren Kommentare
  // öffnen. An einer frischen Auswahl wird noch nichts eingefärbt: Swift
  // bekommt nur die Position und öffnet das Kommentarfeld. Erst der
  // abgeschickte Kommentar legt die (unterstrichene) Stelle an.
  window.merlinCommentFromNative=function(){
    if(selectedHighlightId!==null){
      const id=String(selectedHighlightId);
      selectedHighlightId=null;pendingRange=null;
      window.getSelection()?.removeAllRanges();
      openCommentsFor(id);
      return;
    }
    const range=pendingRange;pendingRange=null;
    if(!range||range.collapsed)return;
    const sx=getXPath(range.startContainer),ex=getXPath(range.endContainer);
    if(!sx||!ex)return;
    const text=range.toString().trim();if(!text)return;
    window.getSelection()?.removeAllRanges();
    window.webkit.messageHandlers.highlights.postMessage({action:'commentAnchor',data:{highlightedText:text,startXpath:sx,startOffset:range.startOffset,endXpath:ex,endOffset:range.endOffset}});
    flushDeferred();
  };

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
    flushDeferred();
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
        flushDeferred();
      },250);
    }
  });

  document.addEventListener('click',e=>{
    const mark=e.target.closest('mark.merlin-highlight');
    // Unterstrichene Kommentarstelle: gleich die Kommentare öffnen, es gibt
    // keine Farbe zu ändern.
    if(mark){e.preventDefault();if(mark.dataset.highlightColor===COMMENT_COLOR)openCommentsFor(mark.dataset.highlightId);else selectHighlight(mark);}
    // Toggle floating back button unless the tap landed on a link, highlight or inline player
    if(!e.target.closest('a,merlin-inline-player')&&!mark){
      window.webkit.messageHandlers.toggleUI.postMessage({});
    }
  });

  // ── Neu zeichnen bei Push (Kommentare/Gast-Markierungen) ──────────────
  // Der Server schickt bei jeder Änderung die vollständige Liste. Gezeichnet
  // wird dann von Grund auf: alle Marks auspacken, Liste neu setzen. Solange
  // eine Auswahl offen ist oder eine eigene Markierung noch auf ihre id wartet
  // (tmp_…), wird die Liste nur vorgemerkt – sonst gingen Auswahl bzw. die
  // gerade gesetzte Markierung verloren.
  let deferredHighlights=null,commentCounts={};

  function hasPendingWork(){
    return pendingRange!==null||selectedHighlightId!==null||
      document.querySelector('mark.merlin-highlight[data-highlight-id^="tmp_"]')!==null;
  }

  function unwrapAllMarks(){
    const parents=new Set();
    document.querySelectorAll('mark.merlin-highlight').forEach(el=>{
      const p=el.parentNode;if(!p)return;
      while(el.firstChild)p.insertBefore(el.firstChild,el);
      p.removeChild(el);parents.add(p);
    });
    parents.forEach(p=>{if(p.isConnected)p.normalize();});
  }

  function renderHighlights(highlights){
    unwrapAllMarks();
    // In Erstellungsreihenfolge setzen (wie der Web-Reader): die XPaths einer
    // Markierung wurden im DOM berechnet, in dem alle älteren Markierungen
    // schon als <mark> standen. Liegt im selben Absatz davor schon eine,
    // zeigt der Pfad z. B. auf text()[3] – im unmarkierten DOM gibt es den
    // nicht, die Markierung verschwand beim nächsten Neuzeichnen.
    const order=h=>{const n=Number(h.id);return Number.isFinite(n)?n:Infinity;};
    highlights.slice().sort((a,b)=>order(a)-order(b)).forEach(restoreHighlight);
    applyCommentCounts();
  }

  // Zähler-Plakette am letzten Stück jeder kommentierten Markierung (CSS
  // ::after, ändert also weder Text noch XPaths).
  function applyCommentCounts(){
    document.querySelectorAll('mark.merlin-highlight[data-comment-count]').forEach(el=>{delete el.dataset.commentCount;});
    Object.keys(commentCounts).forEach(id=>{
      const n=commentCounts[id];if(!n)return;
      const spans=document.querySelectorAll('mark.merlin-highlight[data-highlight-id="'+id+'"]');
      if(spans.length)spans[spans.length-1].dataset.commentCount=String(n);
    });
  }

  function flushDeferred(){
    if(deferredHighlights===null||hasPendingWork())return;
    const list=deferredHighlights;deferredHighlights=null;
    renderHighlights(list);
  }

  (function(){
    const st=document.createElement('style');
    st.textContent='mark.merlin-highlight[data-comment-count]::after{content:attr(data-comment-count);display:inline-block;margin-left:3px;padding:0 5px;min-width:8px;border-radius:8px;background:var(--mh-author,#1c1c1e);color:#fff;font-size:0.68em;font-weight:700;line-height:1.5;text-align:center;vertical-align:super;}';
    (document.head||document.documentElement).appendChild(st);
  })();

  window.merlinApplyHighlights=highlights=>{
    if(hasPendingWork()){deferredHighlights=highlights;return;}
    renderHighlights(highlights);
  };
  window.merlinSetCommentState=(highlights,counts)=>{
    commentCounts=counts||{};
    if(highlights)window.merlinApplyHighlights(highlights);
    applyCommentCounts();
  };
  // `saved`: die gerade gespeicherte Markierung – fehlt sie in einer
  // vorgemerkten (älteren) Liste, kommt sie dazu, statt kurz zu verschwinden.
  window.merlinUpdateTempId=(tempId,realId,saved)=>{
    document.querySelectorAll('mark.merlin-highlight[data-highlight-id="'+tempId+'"]').forEach(el=>{el.dataset.highlightId=String(realId);});
    if(saved&&deferredHighlights!==null&&!deferredHighlights.some(h=>String(h.id)===String(realId))){
      deferredHighlights=deferredHighlights.concat([saved]);
    }
    flushDeferred();
  };
})();
"""#

// MARK: – Image tap JS (tapping any img sends index + all srcs to Swift)

private let merlinImageTapJS: String = #"""
(function(){
  function wire(img,getAll){
    if(img.dataset.merlinTap)return;
    if(img.closest('.merlin-yt-embed'))return; // Thumbnail eines YouTube-Platzhalters — eigene Handhabung in merlinYoutubeTapJS
    if(img.closest('merlin-support-box'))return; // Icon der Support-Infobox: kein Artikelbild, keine Lightbox
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
  function all(){return Array.from(document.querySelectorAll('img')).filter(function(i){return !i.closest('.merlin-yt-embed')&&!i.closest('merlin-support-box')&&!i.closest('.merlin-inline-media--playable');});}
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
// original <iframe> posts the video id (+ optional start time) and the card's
// rect to Swift, which lays a native WKWebView (top-level navigation, see
// YouTubePlayerView.swift) exactly over the card — so the video plays inline
// in the reader (nesting the YouTube iframe inside THIS file://-origin page
// instead was tried first and silently failed: WKWebView doesn't reliably
// honour CSP frame-ancestors for a file:// parent, and even a permissive
// frame-ancestors left the frame blank instead of erroring).
//
// The card keeps reserving the space. While a card is active, layout changes
// (font size, late-loading images, rotation) re-post its rect as `youtubeRect`
// so the native overlay follows it. The WebView itself never scrolls, so the
// rect is document-absolute, which is also its position inside the WebView.
private let merlinYoutubeTapJS: String = #"""
(function(){
  var active=null;
  function rectOf(card){
    var r=card.getBoundingClientRect();
    return {x:r.left+window.scrollX,y:r.top+window.scrollY,w:r.width,h:r.height};
  }
  function report(){
    if(!active)return;
    var r=rectOf(active);
    window.webkit.messageHandlers.youtubeRect.postMessage(r);
  }
  document.querySelectorAll('.merlin-yt-embed').forEach(function(card){
    card.addEventListener('click',function(e){
      e.stopPropagation();
      e.preventDefault();
      active=card;
      var r=rectOf(card);
      window.webkit.messageHandlers.youtubeTap.postMessage({
        id: card.dataset.ytId || '',
        start: card.dataset.ytStart || '',
        x:r.x,y:r.y,w:r.w,h:r.h
      });
    });
  });
  var last='';
  new ResizeObserver(function(){
    if(!active)return;
    var r=rectOf(active), key=[r.x,r.y,r.w,r.h].join(',');
    if(key===last)return;
    last=key;
    report();
  }).observe(document.body);
  window.addEventListener('resize',report);
})();
"""#

// MARK: – Inline media JS (Videos mitten im Text)
//
// Der Server (InlineMediaService in merlin-nextcloud) ersetzt Videos mitten im
// Artikeltext (z. B. den ARD-Player bei rbb24.de) durch
//
//   <figure class="merlin-inline-media">
//     <img src="Vorschaubild">
//     <div class="merlin-inline-media-source" data-media-kind data-media-delivery data-media-src>
//       <a class="merlin-inline-media-fallback-link">Zum Video</a>
//     </div>
//     <figcaption>…</figcaption>
//   </figure>
//
// Wie src/inline-media.js im Web legt dieses Skript auf jede solche Figure einen
// Player (natives <video>/<audio> von WebKit, spielt mp4 und HLS ohne hls.js)
// mit dem Vorschaubild als Poster. Bild, Marker und figcaption bleiben im DOM
// und werden nur per CSS ausgeblendet; der Player steckt in einem eigenen
// Element <merlin-inline-player>, das den Tag-Zähler der Highlight-XPaths
// (getXPath/resolveXPath) für img/div/figcaption nicht verschiebt. Scheitert
// die Wiedergabe, verschwindet der Player wieder und Bild samt "Zum Video"-Link
// (öffnet die Quelle über onLinkTapped) sind wieder sichtbar.
private let merlinInlineMediaJS: String = #"""
(function(){
  var PLAYABLE='merlin-inline-media--playable';
  document.querySelectorAll('figure.merlin-inline-media').forEach(function(figure){
    if(figure.querySelector('merlin-inline-player'))return;
    var source=figure.querySelector('div.merlin-inline-media-source[data-media-kind]');
    if(!source)return;
    var kind=source.getAttribute('data-media-kind');
    var delivery=source.getAttribute('data-media-delivery');
    var src=source.getAttribute('data-media-src')||'';
    // Gleiche Prüfung wie parseMediaMarker() im Web: nur https-Dateien/HLS.
    if((kind!=='video'&&kind!=='audio')||(delivery!=='file'&&delivery!=='hls')||src.indexOf('https://')!==0)return;

    var media=document.createElement(kind);
    media.controls=true;
    media.preload='none';
    media.setAttribute('playsinline','');
    media.setAttribute('webkit-playsinline','');
    var poster=figure.querySelector('img');
    if(kind==='video'&&poster&&(poster.currentSrc||poster.src))media.poster=poster.currentSrc||poster.src;
    media.src=src;

    var player=document.createElement('merlin-inline-player');
    player.className='merlin-inline-player--'+kind;
    player.appendChild(media);
    figure.insertBefore(player,figure.firstChild);
    figure.classList.add(PLAYABLE);

    media.addEventListener('error',function(){
      if(player.parentNode)player.parentNode.removeChild(player);
      figure.classList.remove(PLAYABLE);
    },{once:true});
  });
})();
"""#

// MARK: – Image debug overlay JS (injected only in developer mode)

private let merlinDebugJS: String = #"""
(function(){
  var S=document.createElement('style');
  S.textContent=
    '.mdbg-wrap{margin:8px 0}'+
    '.mdbg{font:11px/1.7 "SF Mono",Menlo,monospace;padding:8px 10px;border-radius:0 0 8px 8px;'+
      'background:#0a0a0c!important;color:#f2f2f7!important;word-break:break-all;border-top:2px solid #30d158}'+
    '.mdbg.net{border-top-color:#ff9f0a}'+
    '.mdbg.err{border-top-color:#ff453a}'+
    '.mdbg-row{display:flex;gap:6px;margin-bottom:3px}'+
    '.mdbg-k{color:#c7c7cc!important;white-space:nowrap;flex-shrink:0;font-weight:700}'+
    '.mdbg-v{color:#ffffff!important;word-break:break-all}'+
    '.mdbg-v.ok{color:#32d74b!important}.mdbg-v.net{color:#ffb340!important}.mdbg-v.err{color:#ff6961!important}'+
    // iOS data detectors auto-wrap URLs in the log values in <a> tags; the
    // reader's global `a{color:...!important}` rule (higher source order,
    // same specificity as a bare element selector) would otherwise repaint
    // them near-black, so force-inherit the panel's own colors here.
    '.mdbg a{color:inherit!important;text-decoration:none!important}'+
    '.mdbg-badge{display:inline-block;padding:2px 7px;border-radius:3px;'+
      'font-weight:700;font-size:10px;letter-spacing:.5px;margin-bottom:6px}'+
    '.bl{background:#32d74b;color:#000}.bn{background:#ffb340;color:#000}.be{background:#ff6961;color:#000}';
  document.head.appendChild(S);

  function row(k,v,c){
    return '<div class="mdbg-row"><span class="mdbg-k">'+k+'</span>'
          +'<span class="mdbg-v'+(c?' '+c:'')+'">'+v+'</span></div>';
  }

  function addPanel(img){
    if(img.dataset.merlinDbg)return;
    if(img.closest('merlin-support-box'))return; // Icon der Support-Infobox: kein Artikelbild
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

  document.querySelectorAll('img').forEach(addPanel);
  new MutationObserver(function(ms){
    ms.forEach(function(m){
      m.addedNodes.forEach(function(n){
        if(n.nodeType!==1)return;
        if(n.tagName==='IMG')addPanel(n);
        else if(n.querySelectorAll)n.querySelectorAll('img').forEach(addPanel);
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
// Mit `tint` wird das Glas in dieser Farbe getönt (z. B. Akzentfarbe des Users);
// unterhalb von iOS 26 dient sie dann als Flächenfarbe.
private struct ReaderBarGlassBackground: ViewModifier {
    let topSeparator:   Bool
    let unionID:        String
    let namespace:      Namespace.ID
    let bgColor:        Color
    let separatorColor: Color
    let tint:           Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(glass, in: Rectangle())
                .glassEffectUnion(id: unionID, namespace: namespace)
        } else {
            content
                .background {
                    (tint ?? bgColor).opacity(0.97)
                        .overlay(alignment: .top) {
                            if topSeparator { separatorColor.frame(height: 0.5) }
                        }
                }
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        // Volle Deckkraft würde das Glas komplett einfärben und die
        // Transparenz schlucken – daher nur teilweise tönen.
        if let tint { return .regular.tint(tint.opacity(0.45)).interactive() }
        return .regular.interactive()
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
        separatorColor: Color,
        tint: Color? = nil
    ) -> some View {
        modifier(ReaderBarGlassBackground(
            topSeparator: topSeparator, unionID: unionID, namespace: namespace,
            bgColor: bgColor, separatorColor: separatorColor, tint: tint))
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
    /// id der angetippten Markierung (Zahl oder noch "tmp_…"), nil bei einer
    /// frischen Textauswahl.
    var highlightId: String?

    var hasHighlight: Bool { highlightId != nil }
}

/// Native, screen-edge-docked replacement for the old text-anchored colour
/// picker. Deliberately large — full screen width, generous touch targets —
/// since it no longer needs to hug the selection.
private struct HighlightToolbarView: View {
    let hasHighlight: Bool
    /// Knopf "Kommentieren" zeigen (nur wenn der Server Kommentare kann).
    let showComment: Bool
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
    let onComment: () -> Void
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

    /// Buttons after the separator: comment (if supported) and delete (when
    /// a highlight is selected).
    private var trailingCount: Int { (showComment ? 1 : 0) + (hasHighlight ? 1 : 0) }

    /// Number of fixed-size circles in the row (colours plus trailing buttons).
    private var circleCount: Int { Self.colors.count + trailingCount }
    private var gapCount: Int { circleCount - 1 + (trailingCount > 0 ? 1 : 0) }

    /// Shrinks circles + spacing uniformly so the row always fits
    /// `availableWidth`, instead of overflowing off-screen once the delete
    /// button is added. Never scales *up* past the ideal size on wide
    /// screens — `min(1, …)`.
    private var scale: CGFloat {
        let usable = max(availableWidth - Self.horizontalPadding * 2, 0)
        let separator = trailingCount > 0 ? Self.separatorWidth : 0
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
                if trailingCount > 0 {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: Self.separatorWidth, height: circleDiameter * 0.625)
                }
                if showComment {
                    Button(action: onComment) {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: circleDiameter, height: circleDiameter)
                            .overlay(
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 18 * scale, weight: .semibold))
                                    .foregroundStyle(.primary)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("articleReader.comments.comment"))
                }
                if hasHighlight {
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

    /// Löscht eine bestimmte Markierung (nach der Rückfrage, ob ihre
    /// Kommentare mit verschwinden sollen – die Auswahl kann dann schon weg sein).
    func deleteHighlight(id: String) {
        guard let data = try? JSONEncoder().encode(id),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript(
            "window.merlinDeleteHighlightFromNative && window.merlinDeleteHighlightFromNative(\(json))")
    }

    /// Knopf "Kommentieren" in der Leiste.
    func comment() {
        webView?.evaluateJavaScript(
            "window.merlinCommentFromNative && window.merlinCommentFromNative()")
    }

    /// "Im Text zeigen": scrollt den Reader zur Markierung und lässt sie kurz
    /// aufblinken. Der WebView scrollt nie selbst (siehe makeUIView); die
    /// Lage im Dokument wird daher in die äußere UIScrollView umgerechnet.
    func reveal(highlightId id: Int) async {
        guard let webView else { return }
        let js = """
        (function(){var ms=document.querySelectorAll('mark.merlin-highlight[data-highlight-id="\(id)"]');if(!ms.length)return -1;\
        ms.forEach(function(m){m.style.outline='2px solid #f59e0b';m.style.outlineOffset='1px';});\
        setTimeout(function(){ms.forEach(function(m){m.style.outline='';m.style.outlineOffset='';});},1600);\
        var r=ms[0].getBoundingClientRect();return r.top+window.scrollY;})()
        """
        // -1 statt null: ein nil-Ergebnis verträgt die async-Variante von
        // evaluateJavaScript nicht auf allen iOS-Versionen.
        guard let top = try? await webView.evaluateJavaScript(js) as? Double, top >= 0 else { return }
        var view: UIView? = webView.superview
        while let v = view {
            if let scroll = v as? UIScrollView {
                let point = webView.convert(CGPoint(x: 0, y: top), to: scroll)
                let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
                let target = min(max(0, point.y - scroll.bounds.height / 3), maxOffset)
                scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                return
            }
            view = v.superview
        }
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
    /// video id, an optional start-time in seconds (both from rewriteYouTubeEmbeds)
    /// and the card's frame in the WebView's coordinate space.
    var onYouTubeTapped: ((String, Int?, CGRect) -> Void)?  = nil
    /// Called when the active YouTube card moved/resized after layout changes.
    var onYouTubeRectChanged: ((CGRect) -> Void)?   = nil
    /// Called when the text selection settles. `rect` is in the WebView's own
    /// (document-absolute, non-scrolling) coordinate space — see the comment
    /// on `scrollOffset` below for why. The SwiftUI layer adds this WebView's
    /// own on-screen frame to get a true screen position for its native
    /// `HighlightToolbarView` overlay. `highlightId` is set when the
    /// selection is an existing highlight (tapped to edit/delete/comment it).
    var onSelectionChanged: ((CGRect, String?) -> Void)? = nil
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
    /// JS, das die Support-Infobox zwischen zwei Absätze setzt. Bewusst NICHT Teil von `html`: käme sie
    /// über den HTML-String, würde deren spätes Eintreffen (Einzelabruf) die Seite neu laden und
    /// Scrollposition/Highlights zurücksetzen. Wird nach dem Laden bzw. bei Änderung direkt ausgeführt.
    var supportBoxScript: String? = nil
    /// Kommentar-Dialog für eine Markierung öffnen (id, markierter Text) –
    /// nach "Kommentieren" an einer neuen oder bestehenden Markierung.
    var onOpenComments: ((Int, String) -> Void)? = nil
    /// "Kommentieren" an einer frischen Auswahl: Kommentarfeld für diese
    /// Stelle öffnen. Die Stelle selbst entsteht erst mit dem Kommentar.
    var onCommentAnchor: ((CommentAnchor) -> Void)? = nil
    /// Eine eigene Markierung wurde angelegt oder gelöscht.
    var onHighlightsChanged: (() -> Void)? = nil
    /// Stand von `CommentStore.revision`; ändert er sich, holt der WebView
    /// über `commentScript` Markierungen und Kommentar-Zähler neu. Getrennt
    /// vom Skript selbst, damit nicht bei jedem Scroll-Frame JSON gebaut wird.
    var commentRevision: Int = 0
    var commentScript: (() -> String?)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(articleId: articleId)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber]
        // Inline-Videos im Text (merlinInlineMediaJS) im Artikel abspielen statt beim Start sofort
        // ins Vollbild zu springen; Vollbild bleibt über die Player-Steuerung erreichbar.
        config.allowsInlineMediaPlayback = true
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
            WeakMessageHandler(context.coordinator), name: "youtubeRect")
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
        context.coordinator.onYouTubeRectChanged = onYouTubeRectChanged
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

        context.coordinator.supportBoxScript = supportBoxScript
        context.coordinator.applySupportBoxIfReady(to: webView)

        context.coordinator.onOpenComments = onOpenComments
        context.coordinator.onCommentAnchor = onCommentAnchor
        context.coordinator.onHighlightsChanged = onHighlightsChanged
        if context.coordinator.commentRevision != commentRevision {
            context.coordinator.commentRevision = commentRevision
            context.coordinator.commentStateScript = commentScript?()
            if context.coordinator.pageLoaded, let script = context.coordinator.commentStateScript {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        let newHash = html.hashValue
        guard context.coordinator.loadedHTMLHash != newHash else { return }
        context.coordinator.loadedHTMLHash = newHash
        // Neue Seite: die Box muss nach deren didFinish erneut gesetzt werden.
        context.coordinator.pageLoaded = false
        context.coordinator.appliedSupportBoxScript = nil

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
        var supportBoxScript: String?
        var appliedSupportBoxScript: String?
        var pageLoaded = false
        var onLinkTapped:   ((URL) -> Void)?
        var onToggleUI:     (() -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?
        var onImageTapped:  ((Int, [String]) -> Void)?
        var onYouTubeTapped: ((String, Int?, CGRect) -> Void)?
        var onYouTubeRectChanged: ((CGRect) -> Void)?
        var onSelectionChanged: ((CGRect, String?) -> Void)?
        var onSelectionCleared: (() -> Void)?
        var onOpenComments: ((Int, String) -> Void)?
        var onCommentAnchor: ((CommentAnchor) -> Void)?
        var onHighlightsChanged: (() -> Void)?
        var commentRevision = 0
        /// Letztes Skript aus `CommentStore.webViewScript()`; wird nach jedem
        /// Seitenladen erneut ausgeführt.
        var commentStateScript: String?
        var lastScrollOffset: CGFloat = 0
weak var webView:   WKWebView?

        init(articleId: Int) {
            self.articleId = articleId
        }

        /// Liest {x,y,w,h} (Zahlen, CSS-px = Punkte) aus einer JS-Nachricht.
        private static func rect(from body: [String: Any]) -> CGRect? {
            guard let x = (body["x"] as? NSNumber)?.doubleValue,
                  let y = (body["y"] as? NSNumber)?.doubleValue,
                  let w = (body["w"] as? NSNumber)?.doubleValue,
                  let h = (body["h"] as? NSNumber)?.doubleValue,
                  w > 0, h > 0 else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }

        /// Führt `supportBoxScript` genau einmal je Seitenladung aus (das Skript ist idempotent, das Flag
        /// spart nur redundante evaluateJavaScript-Aufrufe bei jedem SwiftUI-Update).
        func applySupportBoxIfReady(to webView: WKWebView) {
            guard pageLoaded, let script = supportBoxScript, script != appliedSupportBoxScript else { return }
            appliedSupportBoxScript = script
            webView.evaluateJavaScript(script, completionHandler: nil)
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
                guard let rect = Self.rect(from: body) else { return }
                DispatchQueue.main.async { [weak self] in self?.onYouTubeTapped?(id, start, rect) }
                return
            }

            if message.name == "youtubeRect",
               let body = message.body as? [String: Any],
               let rect = Self.rect(from: body) {
                DispatchQueue.main.async { [weak self] in self?.onYouTubeRectChanged?(rect) }
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
                    let highlightId = body["highlightId"] as? String
                    let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                    DispatchQueue.main.async { [weak self] in self?.onSelectionChanged?(rect, highlightId) }
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
                let wantsComment = data["comment"] as? Bool ?? false

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
                            let savedJSON = (try? JSONEncoder().encode(saved)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                            await MainActor.run {
                                webView?.evaluateJavaScript(
                                    "merlinUpdateTempId(\(tempIdJSON), \(saved.id), \(savedJSON))",
                                    completionHandler: nil)
                            }
                        }
                        let savedId = saved.id
                        DispatchQueue.main.async { [weak self] in
                            self?.onHighlightsChanged?()
                            if wantsComment { self?.onOpenComments?(savedId, text) }
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
                            DispatchQueue.main.async { [weak self] in self?.onHighlightsChanged?() }
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

            case "commentAnchor":
                guard let data       = body["data"]             as? [String: Any],
                      let text       = data["highlightedText"]  as? String,
                      let startXpath = data["startXpath"]       as? String,
                      let startOff   = data["startOffset"]      as? Int,
                      let endXpath   = data["endXpath"]         as? String,
                      let endOff     = data["endOffset"]        as? Int
                else { return }
                let anchor = CommentAnchor(
                    highlightedText: text,
                    startXpath: startXpath,
                    startOffset: startOff,
                    endXpath: endXpath,
                    endOffset: endOff)
                DispatchQueue.main.async { [weak self] in self?.onCommentAnchor?(anchor) }

            case "openComments":
                // Noch nicht gespeicherte Markierung (tmp_…): keine id, an
                // der ein Kommentar hängen könnte.
                guard let rawId = body["id"] as? String, let highlightId = Int(rawId) else { return }
                let text = body["text"] as? String ?? ""
                DispatchQueue.main.async { [weak self] in self?.onOpenComments?(highlightId, text) }

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
               scheme == "http" || scheme == "https" || url == RecognizedTextEvent.linkURL {
                decisionHandler(.cancel)
                onLinkTapped?(url)
            } else {
                decisionHandler(.allow)
            }
        }

        // Page load complete: restore saved highlights.
        // Height is reported exclusively by the ResizeObserver injected in buildReaderHTML.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            applySupportBoxIfReady(to: webView)
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
                if !highlights.isEmpty,
                   let jsonData = try? JSONEncoder().encode(highlights),
                   let jsonStr  = String(data: jsonData, encoding: .utf8) {
                    await MainActor.run {
                        webView?.evaluateJavaScript(
                            "if(typeof merlinApplyHighlights==='function'){merlinApplyHighlights(\(jsonStr))}",
                            completionHandler: nil)
                    }
                }
                // Danach den (meist neueren) Stand aus dem Kommentar-Kanal
                // inkl. Gast-Markierungen und Zählern drüberlegen.
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let script = self?.commentStateScript else { return }
                    webView?.evaluateJavaScript(script, completionHandler: nil)
                }
            }
        }
    }
}

// MARK: – Kommentare im Reader

/// Was der Kommentar-Dialog beim Öffnen zeigt: die Threads einer Markierung
/// (`highlightId`), alle (nil) oder – mit `anchor` – das Feld für den ersten
/// Kommentar an einer noch nicht angelegten Stelle.
struct CommentFocus: Identifiable {
    let id = UUID()
    let highlightId: Int?
    let quote: String?
    var anchor: CommentAnchor? = nil
}

/// Kommentar-Dialog, Push-Kanal-Lebenszyklus und die Rückfrage vor dem
/// Entfernen einer kommentierten Markierung. Als eigener Modifier, damit der
/// ohnehin lange Modifier-Stapel von ArticleReaderView.body für den
/// Type-Checker nicht weiter wächst.
private struct ReaderCommentsModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    let articleId: Int
    let store: CommentStore
    @Binding var focus: CommentFocus?
    @Binding var highlightToDelete: String?
    let actions: HighlightActionHandler

    func body(content: Content) -> some View {
        content
            .sheet(item: $focus) { focus in
                CommentsSheet(
                    store: store,
                    initialHighlightId: focus.highlightId,
                    initialQuote: focus.quote,
                    initialAnchor: focus.anchor,
                    onShowInText: { highlightId in
                        self.focus = nil
                        Task {
                            // Erst nach dem Zuklappen scrollen, sonst greift
                            // der Offset nicht (Sheet-Animation).
                            try? await Task.sleep(for: .milliseconds(450))
                            await actions.reveal(highlightId: highlightId)
                        }
                    })
            }
            .task(id: articleId) {
                store.start(articleId: articleId)
            }
            .onDisappear {
                store.stop()
            }
            .onChange(of: scenePhase) { _, new in
                // Im Hintergrund keine Verbindung halten; beim Zurückkommen
                // neu abfragen und verbinden. (Der Weg zurück führt über
                // .inactive, ein Vergleich mit `old == .background` griffe nie.)
                if new == .background {
                    store.stop()
                    wasInBackground = true
                } else if new == .active, wasInBackground {
                    wasInBackground = false
                    store.reconnect()
                }
            }
            .confirmationDialog(
                L("articleReader.comments.deleteHighlightTitle"),
                isPresented: .init(get: { highlightToDelete != nil }, set: { if !$0 { highlightToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(L("articleReader.comments.removeHighlight"), role: .destructive) {
                    if let id = highlightToDelete { actions.deleteHighlight(id: id) }
                    highlightToDelete = nil
                }
                Button(L("common.cancel"), role: .cancel) { highlightToDelete = nil }
            } message: {
                Text(L("articleReader.comments.deleteHighlightMessage"))
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
    @ObservedObject var audio: AudioPlaybackService
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
    /// Termin aus dem erkannten Text eines Bildes (Link unter „Erkannter Text“).
    @State private var eventSuggestion:    RecognizedTextEvent? = nil
    @State private var youtubePlayerState: YouTubePlayerState? = nil
    @State private var showTagSheet        = false
    /// Umbenennen-Dialog für Datei-Einträge (siehe RenameFileAlert).
    @State private var renameArticle: Article? = nil
    @State private var showReportSheet     = false
    @State private var showShareLinkSheet  = false
    /// Kommentare und Markierungen des Artikels, live per Push (nur Nextcloud).
    @State private var comments = CommentStore()
    /// Offener Kommentar-Dialog (nil = zu).
    @State private var commentFocus: CommentFocus? = nil
    /// Rückfrage vor dem Entfernen einer Markierung, an der Kommentare hängen.
    @State private var highlightToDelete: String? = nil
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
    /// Lokal (nicht persistiert) — Nutzer hat den generischen Bezahlartikel-Hinweis (`isPaywalled`,
    /// Domain OHNE Login-Unterstützung, siehe PaywallSubscribeBanner) für diese Ansicht weggewischt.
    @State private var paywallSubscribeBannerDismissed = false
    /// Abo-/Spendenlink der Quelle für die Infobox im Text; kommt nur vom Einzelabruf, nicht aus der Liste.
    @State private var supportBox: SupportBox?
    /// Über `GET /articles/{id}/media` aufgelöste Audio-Quelle (kurzlebige Streams, Artikel ohne Marker).
    /// Quellen, die direkt im Content-Marker stehen, kennt `audioSource` synchron.
    @State private var fetchedAudioSource: AudioSource?
    /// Verbindet bottomBar + Piper-Panel zu einer einzigen Liquid-Glass-Form
    /// (ab iOS 26 – siehe `ReaderBarGlassBackground`).
    @Namespace private var bottomGlassNamespace
    @AppStorage("merlin_accent_progress_color") private var accentColorHex:  String = "#FF3B30"
    @AppStorage("merlin_developer_mode")        private var developerMode:   Bool   = false

    private var current: Article {
        viewModel.articles.first { $0.id == article.id } ?? article
    }

    /// Fasst alle Einstellungen zusammen, die die Reader-HTML neu laden lassen.
    private var appearanceKey: String {
        "\(fontSize)|\(theme.rawValue)|\(readerFont.rawValue)|\(lineHeight)"
    }

    /// Inline-Player exakt über der angetippten Vorschaukarte. Der WebView scrollt nicht
    /// selbst, das Overlay scrollt also mit dem Artikel mit. Als eigene Property, damit
    /// `body` für den Type-Checker klein genug bleibt.
    @ViewBuilder
    private var youtubeOverlay: some View {
        if let yps = youtubePlayerState {
            YouTubePlayerView(state: yps)
                .frame(width: yps.rect.width, height: yps.rect.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .offset(x: yps.rect.minX, y: yps.rect.minY)
        }
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

                    if !current.isPDF, let source = audioSource {
                        audioPlayerCard(source: source)
                    }

                    if NativeVideoHost.matches(current.url) {
                        NativeVideoPlayerCard(articleId: current.id,
                                              posterURL: current.imageUrl.flatMap(URL.init(string:)))
                    }

                    if current.isPDF, let pdfURL = current.pdfSourceURL {
                        // PDF-Artikel: der Server speichert nur die URL; die PDF wird hier geladen und
                        // seitenweise im äußeren ScrollView gerendert (Fortschritt/Restore bleiben so intakt).
                        PDFArticleView(sourceURL: pdfURL, availableWidth: viewportWidth)
                        // Datei-Einträge: Metadaten aus dem Content (dort zeigt sie sonst die
                        // Web-Ansicht, die bei PDFs nicht gerendert wird).
                        if current.fileId != nil, let content = current.content,
                           let metadata = FileMetadataParser.parse(content) {
                            FileMetadataSection(title: metadata.title, groups: metadata.groups)
                        }
                    } else if let content = current.content, !content.isEmpty {
                        ArticleWebView(
                            html: buildReaderHTML(content: current.fileId != nil
                                                      ? RecognizedTextEvent.addingEventLink(to: content, label: L("fileText.createEvent"))
                                                      : content,
                                                  fontSize: fontSize,
                                                  theme: theme, font: readerFont, lineHeight: lineHeight,
                                                  developerMode: developerMode),
                            articleId:      current.id,
                            onLinkTapped:   { url in
                                if url == RecognizedTextEvent.linkURL {
                                    eventSuggestion = RecognizedTextEvent.recognizedText(in: content)
                                        .flatMap { RecognizedTextEvent.detect(in: $0) }
                                } else {
                                    tappedLinkURL = url
                                }
                            },
                            onHeightChange: { h in webViewHeight = max(200, h) },
                            onImageTapped:  { idx, srcs in
                                lightboxState = LightboxState(initialIndex: idx, imageURLs: srcs)
                            },
                            onYouTubeTapped: { videoId, start, rect in
                                youtubePlayerState = YouTubePlayerState(videoId: videoId, startSeconds: start, rect: rect)
                            },
                            onYouTubeRectChanged: { rect in
                                youtubePlayerState?.rect = rect
                            },
                            onSelectionChanged: { rect, highlightId in
                                let screenRect = CGRect(
                                    x: webViewScreenFrame.minX + rect.minX,
                                    y: webViewScreenFrame.minY + rect.minY,
                                    width: rect.width,
                                    height: rect.height)
                                toolbarScrollBaseline = scrollOffset
                                showHighlightToolbar(
                                    SelectionToolbarState(screenRect: screenRect, highlightId: highlightId),
                                    animation: .spring(response: 0.35, dampingFraction: 0.82))
                            },
                            onSelectionCleared: {
                                toolbarScrollBaseline = nil
                                hideHighlightToolbar()
                            },
                            actionHandler: highlightActions,
                            scrollOffset: scrollOffset,
                            supportBoxScript: supportBox.flatMap { Self.supportBoxScript(for: $0, seed: current.id) },
                            onOpenComments: { highlightId, text in
                                hideHighlightToolbar()
                                commentFocus = CommentFocus(highlightId: highlightId, quote: text)
                            },
                            onCommentAnchor: { anchor in
                                hideHighlightToolbar()
                                commentFocus = CommentFocus(highlightId: nil, quote: anchor.highlightedText, anchor: anchor)
                            },
                            onHighlightsChanged: {
                                Task { await comments.refresh() }
                            },
                            commentRevision: comments.revision,
                            commentScript: { [comments] in comments.webViewScript() }
                        )
                        .frame(height: max(300, webViewHeight))
                        // Inline-Player exakt über der angetippten Vorschaukarte. Der WebView
                        // scrollt nicht selbst, das Overlay scrollt also mit dem Artikel mit.
                        .overlay(alignment: .topLeading) { youtubeOverlay }
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
                    } else if let domain = current.requiresLoginDomain {
                        VStack(spacing: 16) {
                            Image(systemName: "lock.trianglebadge.exclamationmark")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)
                            Text(String(format: L("articleReader.paywallBanner.message"), domain))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Button(L("articleReader.paywallBanner.connectButton")) {
                                showSiteCredentialsSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                retryAfterPaywall()
                            } label: {
                                if isRetryingAfterPaywall {
                                    ProgressView()
                                } else {
                                    Text(L("articleReader.paywallBanner.retryButton"))
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isRetryingAfterPaywall)
                            if let url = URL(string: current.url) {
                                Link(L("articleReader.sideMenu.openInBrowser"), destination: url)
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else if current.isPaywalled {
                        VStack(spacing: 16) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)
                            Text(L("articleReader.paywallSubscribeBanner.message"))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            if let subscribeUrl = current.paywallSubscribeUrl, let url = URL(string: subscribeUrl) {
                                Link(L("articleReader.paywallSubscribeBanner.subscribeButton"), destination: url)
                                    .buttonStyle(.borderedProminent)
                            }
                            Button(L("articleReader.paywallSubscribeBanner.archiveButton")) {
                                archiveFromPaywallBanner()
                            }
                            .buttonStyle(.bordered)
                            if let url = URL(string: current.url) {
                                Link(L("articleReader.sideMenu.openInBrowser"), destination: url)
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else if let domain = current.unsupportedSiteDomain {
                        // UnsupportedSiteException server-seitig: die Domain liefert
                        // grundsätzlich keinen scrapbaren Artikeltext (reine JS-SPA/
                        // Bild-Viewer wie PressReader) - kein Retry-Button, da ein
                        // erneuter Versuch am selben Ergebnis nichts ändert.
                        VStack(spacing: 16) {
                            Image(systemName: "xmark.octagon")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)
                            Text(String(format: L("articleReader.unsupportedSiteBanner.message"), domain))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            if let url = URL(string: current.url) {
                                Link(L("articleReader.sideMenu.openInBrowser"), destination: url)
                                    .buttonStyle(.bordered)
                            }
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
            // Liquid Glass richtet sich nach dem colorScheme der Umgebung (System);
            // hier stattdessen dem Reader-Theme folgen, damit die Bars beim
            // Light/Dark-Wechsel im Reader mitgehen.
            .environment(\.colorScheme, readerIsDark ? .dark : .light)
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
                    showComment: comments.isAvailable,
                    dockTop: dockTop,
                    edgeInset: dockTop ? safeAreaTop : safeAreaBottom,
                    availableWidth: viewportWidth,
                    bgColor: readerBgColor,
                    onColor: { colorId in
                        highlightActions.applyColor(colorId)
                        hideHighlightToolbar()
                    },
                    onComment: {
                        highlightActions.comment()
                        hideHighlightToolbar()
                    },
                    onDelete: {
                        // Hängen Kommentare an der Markierung, erst nachfragen:
                        // die Threads bleiben mit dem zitierten Text erhalten,
                        // die Stelle im Text ist aber weg.
                        if let id = toolbar.highlightId, let numeric = Int(id),
                           comments.count(forHighlight: numeric) > 0 {
                            highlightToDelete = id
                        } else {
                            highlightActions.deleteSelected()
                        }
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
        // Geänderte Darstellung lädt die Reader-HTML neu; die JS-Referenz auf die aktive
        // YouTube-Karte geht dabei verloren, das Overlay hätte keine Position mehr.
        .onChange(of: appearanceKey) { _, _ in youtubePlayerState = nil }
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
        .sheet(item: $eventSuggestion) { suggestion in
            EventEditSheet(suggestion: suggestion) { eventSuggestion = nil }
                .ignoresSafeArea()
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
        // ── Audio-Quelle (Player statt Hero Image) ──────────────────────────
        .task(id: "\(current.id)|\(current.content == nil)|\(current.category ?? "")") {
            guard MediaMarker.inlineAudioSource(from: current.content) == nil, !current.isPDF else { return }
            fetchedAudioSource = await MediaMarker.resolveAudio(for: current)
        }
        // ── Support-Infobox (Abo-/Spendenlink) ──────────────────────────────
        .task(id: current.id) {
            supportBox = nil
            supportBox = (try? await MerlinAPI.shared.getArticle(current.id))?.supportBox
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
        .renameFileAlert(article: $renameArticle, viewModel: viewModel)
        .sheet(isPresented: $showShareLinkSheet, onDismiss: {
            // Link angelegt/widerrufen: der Push-Kanal endet ohne Link
            // (`.closed`) und muss danach neu verbunden werden.
            comments.reconnect()
        }) {
            ShareLinkSheet(articleId: current.id, commentsAvailable: comments.isAvailable)
        }
        // ── Kommentare ─────────────────────────────────────────────────────
        .modifier(ReaderCommentsModifier(
            articleId: current.id,
            store: comments,
            focus: $commentFocus,
            highlightToDelete: $highlightToDelete,
            actions: highlightActions))
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
            } else if let domain = current.requiresLoginDomain, !paywallBannerDismissed,
                      let content = current.content, !content.isEmpty {
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
            } else if current.isPaywalled, !paywallSubscribeBannerDismissed,
                      let content = current.content, !content.isEmpty {
                PaywallSubscribeBanner(
                    subscribeUrl: current.paywallSubscribeUrl,
                    onSubscribe: {
                        if let subscribeUrl = current.paywallSubscribeUrl, let url = URL(string: subscribeUrl) {
                            UIApplication.shared.open(url)
                        }
                    },
                    onArchive: { archiveFromPaywallBanner() },
                    onDismiss: { paywallSubscribeBannerDismissed = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current.isPaywalled)
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

    /// Archiviert den aktuellen Artikel aus dem PaywallSubscribeBanner heraus und schliesst den
    /// Reader danach, analog zum "Archivieren"-Eintrag im Seitenmenü (siehe dort).
    private func archiveFromPaywallBanner() {
        let snapshot = current
        guard !snapshot.isArchived else { return }
        Task { await viewModel.toggleArchive(snapshot) }
        dismiss()
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

    /// Effektives Hell/Dunkel des Readers (Theme-Override oder System).
    private var readerIsDark: Bool {
        (theme == .dark) || (theme == .auto && colorScheme == .dark)
    }

    /// Lesbare Vordergrundfarbe auf der Akzentfläche (weiß, bei sehr hellen Akzenten dunkel).
    private var onAccentHex: String {
        let s = accentColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return "#ffffff" }
        func lin(_ c: UInt32) -> Double {
            let x = Double(c) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin(v >> 16 & 0xff) + 0.7152 * lin(v >> 8 & 0xff) + 0.0722 * lin(v & 0xff)
        return l > 0.35 ? "#1c1c1e" : "#ffffff"
    }

    /// Tonstufen Akzent → Reader-Hintergrund: (Höhe, Akzentanteil). Muss zum CSS in buildReaderHTML passen.
    private static let accentSteps: [(height: CGFloat, amount: Double)] =
        [(14, 0.75), (12, 0.55), (10, 0.35), (8, 0.15)]

    // MARK: – Audio-Player (ersetzt das Hero Image)

    /// Audio-Quelle des Artikels: Marker im Content (synchron) oder per `/media` aufgelöst.
    private var audioSource: AudioSource? {
        MediaMarker.inlineAudioSource(from: current.content) ?? fetchedAudioSource
    }

    private var hasNativeAudio: Bool { audioSource != nil && !current.isPDF }

    /// Bildunterschrift des führenden Hero Images, die der Audio-Player selbst anzeigt.
    private var audioCaption: String? {
        guard let content = current.content else { return nil }
        return MediaMarker.splitLeadingHero(from: MediaMarker.stripMarker(from: injectHeroImageIfNeeded(into: content))).caption
    }

    private func audioPlayerCard(source: AudioSource) -> some View {
        let accent = Color(hexString: accentColorHex) ?? .red
        let steps: [(height: CGFloat, color: Color)] = Self.accentSteps.map { step in
            (height: step.height,
             color: accent.mix(with: readerBgColor, by: 1 - step.amount, in: .perceptual))
        }
        return AudioPlayerCard(
            audio: audio,
            article: current,
            source: source,
            coverURL: current.imageUrl.flatMap(URL.init(string:)),
            caption: audioCaption,
            accent: accent,
            onAccent: Color(hexString: onAccentHex) ?? .white,
            design: readerFont.swiftUIDesign,
            steps: steps
        )
    }

    /// Entfernt bei aktivem Audio-Player das führende Hero Image (Cover + Bildunterschrift zeigt
    /// der Player) sowie den Medien-Marker samt „Zum Audio“-Link aus dem Artikeltext.
    private func stripAudioPlayerElements(in content: String) -> String {
        guard hasNativeAudio else { return content }
        return MediaMarker.splitLeadingHero(from: MediaMarker.stripMarker(from: content)).rest
    }

    /// Aufmacher-Video eines Textartikels (Medien-Marker mit `kind == video`): legt den Player
    /// über `merlinInlineMediaJS` auf das Hero Image, siehe `MediaMarker.promoteHeroVideo(in:)`.
    /// ARD/ZDF/Arte haben ihren eigenen nativen Player (NativeVideoPlayerCard).
    private func promoteHeroVideo(in content: String) -> String {
        guard !NativeVideoHost.matches(current.url), !current.isPDF else { return content }
        return MediaMarker.promoteHeroVideo(in: content)
    }

    /// true, wenn der WebView-Inhalt direkt mit dem Titelbild beginnt – dann setzt das CSS
    /// Fläche + Tonstufen fort, sonst zeichnet der native Header die Stufen.
    private var readerLeadsWithHero: Bool {
        guard let content = current.content, !content.isEmpty,
              !NativeVideoHost.matches(current.url) else { return false }
        let head = injectHeroImageIfNeeded(into: content)
            .drop(while: \.isWhitespace).prefix(8).lowercased()
        return head.hasPrefix("<figure") || head.hasPrefix("<img")
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

    // MARK: – Native article header (Plakat-Header mit Tonstufen)

    @ViewBuilder
    private var articleHeader: some View {
        let accent   = Color(hexString: accentColorHex) ?? .red
        let onAccent = Color(hexString: onAccentHex) ?? .white
        let design   = readerFont.swiftUIDesign

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: safeAreaTop + 12)

                VStack(alignment: .leading, spacing: 18) {

                    // ── Topline: Site links, erster Tag rechts, 2px-Linie darunter ──
                    let hasSite = !current.displaySiteName.isEmpty
                    if hasSite || !current.tags.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if hasSite {
                                let site = Text(current.displaySiteName)
                                if let url = URL(string: current.url) {
                                    Button { tappedLinkURL = url } label: { site }
                                        .buttonStyle(.plain)
                                } else { site }
                            }
                            Spacer(minLength: 0)
                            if let tag = current.tags.first {
                                Text(tag.name).lineLimit(1)
                            }
                        }
                        .font(.system(size: 11, weight: .bold, design: design))
                        .tracking(2.0)
                        .foregroundStyle(onAccent)
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) { onAccent.frame(height: 2) }
                    }

                    // ── Titel ──
                    Text(current.displayTitle)
                        .font(.system(size: CGFloat(fontSize) * 2.1, weight: .heavy, design: design))
                        .tracking(-1)
                        .foregroundStyle(onAccent)
                        .fixedSize(horizontal: false, vertical: true)

                    // ── Teaser ──
                    if let ex = current.excerpt, !ex.isEmpty {
                        Text(ex)
                            .font(.system(size: CGFloat(fontSize), weight: .medium, design: design))
                            .foregroundStyle(onAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // ── Metazeile: 2px-Linie darüber (Gegenstück zur Topline), niemals zweizeilig ──
                    if !infoCardCells.isEmpty {
                        metaLineRow(onAccent: onAccent, design: design)
                            .padding(.top, 8)
                            .overlay(alignment: .top) { onAccent.frame(height: 2) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 22)
            }
            .background(accent)

            // ── Tonstufen nur, wenn kein Titelbild im WebView die Fläche fortsetzt
            //    (und der native Audio-Player sie nicht selbst unter dem Cover zeichnet) ──
            if !readerLeadsWithHero && !hasNativeAudio {
                ForEach(Self.accentSteps.indices, id: \.self) { i in
                    let step = Self.accentSteps[i]
                    Rectangle()
                        .fill(accent.mix(with: readerBgColor, by: 1 - step.amount, in: .perceptual))
                        .frame(height: step.height)
                }
                Color.clear.frame(height: 16)
            }
        }
    }

    /// Metazeile als HStack einzelner Segmente: Autor kann getrunkiert werden
    /// (Flyout zeigt vollen Namen), „Erschienen“ öffnet per Tap das
    /// Gespeichert-am-Flyout. Feste Segmente (Lesezeit, Datum, Trennpunkte)
    /// behalten immer ihre volle Breite — der Autor weicht zuerst, damit die
    /// Zeile nie zweizeilig wird.
    @ViewBuilder
    private func metaLineRow(onAccent: Color, design: Font.Design) -> some View {
        let cells = infoCardCells
        let font  = Font.system(size: 11, weight: .bold, design: design)

        HStack(spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { idx, cell in
                metaLineSegment(cell: cell, font: font, design: design, onAccent: onAccent)
                if idx < cells.count - 1 {
                    Text("·")
                        .font(font)
                        .foregroundStyle(onAccent)
                        .fixedSize()
                        // Punkt hinter dem Autor nur bei Trunkierung sichtbar; per
                        // opacity statt Entfernen, damit das Layout (und damit die
                        // Trunkierungs-Erkennung) stabil bleibt.
                        .opacity(cell.kind == .author && !authorIsTruncated ? 0 : 1)
                }
            }
        }
        .tracking(1.0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metaLineSegment(cell: (kind: InfoCardKind, label: String, value: String),
                                  font: Font, design: Font.Design, onAccent: Color) -> some View {
        let text = (cell.kind == .author ? "\(cell.label) \(cell.value)" : cell.value)

        switch cell.kind {
        case .author:
            // Mit Profil-Link (authorUrl) ist der Name unterstrichen und öffnet per Tap
            // den Link-Dialog; ist er trunkiert, zeigt der Tap zuerst den vollen Namen.
            let profileURL = current.authorProfileURL
            Button {
                if authorIsTruncated { showAuthorFlyout = true }
                else if let profileURL { tappedLinkURL = profileURL }
            } label: {
                (Text("\(cell.label) ") + Text(cell.value).underline(profileURL != nil))
                    .font(font)
                    .foregroundStyle(onAccent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .background(
                        GeometryReader { visibleProxy in
                            Text(text)
                                .font(font)
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
            .buttonStyle(.plain)
            .onPreferenceChange(AuthorTruncationKey.self) { authorIsTruncated = $0 }
            .popover(isPresented: $showAuthorFlyout) {
                Group {
                    if let profileURL {
                        Button {
                            showAuthorFlyout = false
                            // Erst das Popover schließen, dann den Link-Dialog zeigen.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                tappedLinkURL = profileURL
                            }
                        } label: {
                            (Text("\(cell.label) ") + Text(cell.value).underline())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(text)
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: design))
                .foregroundStyle(readerFgColor)
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)

        case .published:
            if let saved = shortDate(current.createdAt) {
                Button { showSavedAtFlyout = true } label: {
                    Text(text).font(font).foregroundStyle(onAccent).lineLimit(1)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: $showSavedAtFlyout) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(InfoCardKind.saved.displayLabel)
                            .font(.system(size: 10, weight: .semibold, design: design))
                            .tracking(1.0)
                            .foregroundStyle(readerFgMutedColor)
                        Text(saved)
                            .font(.system(size: 13, weight: .semibold, design: design))
                            .foregroundStyle(readerFgColor)
                    }
                    .padding(14)
                    .presentationCompactAdaptation(.popover)
                }
            } else {
                Text(text).font(font).foregroundStyle(onAccent).lineLimit(1).fixedSize()
            }

        default:
            Text(text).font(font).foregroundStyle(onAccent).lineLimit(1).fixedSize()
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
                // PDF-Artikel haben keinen Text (Vorlesen) und keine Schrift-/Theme-Einstellungen.
                if !current.isPDF {
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
                }

                menuDivider

                // ── Teilen & Links ────────────────────────────────────────────
                // Datei-Einträge teilen die Datei selbst, sonst den Link.
                ArticleShareLink(article: current) {
                    menuRowContent(icon: "square.and.arrow.up", label: L("articleReader.sideMenu.share"))
                }
                .simultaneousGesture(TapGesture().onEnded {
                    showSideMenu = false
                })

                if let url = URL(string: current.url) {
                    menuRow(icon: "safari", label: L("articleReader.sideMenu.openInBrowser")) {
                        showSideMenu = false
                        UIApplication.shared.open(url)
                    }

                    let strippedURL = current.url
                        .replacingOccurrences(of: "https://", with: "")
                        .replacingOccurrences(of: "http://", with: "")
                    if !current.isPDF, let archiveURL = URL(string: "https://archive.ph/" + strippedURL) {
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

                    if comments.isAvailable {
                        let count = comments.totalCount
                        menuRow(icon: "text.bubble",
                                label: count > 0
                                    ? String(format: L("articleReader.comments.countLabel"), count)
                                    : L("articleReader.comments.title")) {
                            showSideMenu = false
                            commentFocus = CommentFocus(highlightId: nil, quote: nil)
                        }
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

                if current.fileId != nil {
                    menuRow(icon: "pencil", label: L("fileRename.menu")) {
                        showSideMenu = false
                        renameArticle = current
                    }
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
        // Glas in der Akzentfarbe des Users getönt; Icons in der dazu
        // lesbaren Vordergrundfarbe (wie Titelbereich/AudioPlayerCard).
        let accent   = Color(hexString: accentColorHex) ?? .red
        let onAccent = Color(hexString: onAccentHex) ?? .white
        return HStack(spacing: 0) {

            // ── Button 1: Back ────────────────────────────────────────────────
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(onAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            onAccent.opacity(0.25).frame(width: 0.5)

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
                    .foregroundStyle(onAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            onAccent.opacity(0.25).frame(width: 0.5)

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
                .foregroundStyle(onNavigateNext != nil ? onAccent : onAccent.opacity(0.35))
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
            bgColor: readerBgColor, separatorColor: readerSeparatorColor,
            tint: accent)
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
    /// Swift, das darauf mit einem nativen Inline-Player (`YouTubePlayerView`)
    /// als Overlay exakt über der Karte reagiert.
    ///
    /// Grund für den Umweg über eine native WebView statt eines
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
    ///
    /// Also handles the case where the `<img>` already failed to load and was
    /// replaced by the error placeholder (see `makePlaceholder` in
    /// `buildReaderHTML`): that placeholder carries the original remote URL in
    /// `data-merlin-original-src` precisely so this later, successful catch-up
    /// download can still find and undo it by re-inserting a real `<img>` —
    /// otherwise the `querySelectorAll('img')` swap below would find nothing,
    /// since the `<img>` element itself no longer exists in the DOM.
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
        document.querySelectorAll('.merlin-img-placeholder').forEach(function(ph){
          if (ph.dataset.merlinOriginalSrc === \(remoteJSON)) {
            var img = document.createElement('img');
            img.setAttribute('src', \(localJSON));
            img.setAttribute('alt', '');
            if (ph.parentNode) ph.parentNode.replaceChild(img, ph);
          }
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

    // MARK: – Support-Infobox

    /// JS für die Support-Infobox ("Dir gefällt der Artikel von …? Überlege ein Abo abzuschließen oder zu
    /// spenden"), gleiche Platzierungslogik wie `insertSupportBox` im Nextcloud-Web-Reader: nach einem
    /// pseudo-zufälligen Top-Level-`<p>` (Seed = Artikel-ID, damit die Position stabil bleibt), nur ab
    /// 4 Absätzen. Als eigenes Element `<merlin-support-box>` gesetzt: der XPath-Zähler der Highlights
    /// (`getXPath`) zählt Geschwister je Tag-Name, ein unbekannter Tag verschiebt daher keinen Index
    /// des Artikeltextes und Highlights lösen weiter plattformübergreifend gleich auf.
    static func supportBoxScript(for box: SupportBox, seed: Int) -> String? {
        func httpURL(_ s: String?) -> String? {
            guard let s, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return u.absoluteString
        }
        let subscribeURL = httpURL(box.subscribeUrl)
        let donationsURL = httpURL(box.donationsUrl)
        guard subscribeURL != nil || donationsURL != nil else { return nil }

        // Reihenfolge der Links = Reihenfolge der %@ in der Vorlage (Abo vor Spende, in DE und EN gleich).
        let links: [[String: String]]
        let template: String
        switch (subscribeURL, donationsURL) {
        case let (.some(sub), .some(don)):
            template = L("articleReader.supportBox.both")
            links = [["href": sub, "label": L("articleReader.supportBox.subscribeLabel")],
                     ["href": don, "label": L("articleReader.supportBox.donateLabel")]]
        case let (.some(sub), .none):
            template = L("articleReader.supportBox.subscribeOnly")
            links = [["href": sub, "label": L("articleReader.supportBox.subscribeLabel")]]
        case let (.none, .some(don)):
            template = L("articleReader.supportBox.donateOnly")
            links = [["href": don, "label": L("articleReader.supportBox.donateLabel")]]
        default:
            return nil
        }

        let accent = box.accentColor.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
            ? box.accentColor : "#FF3B30"
        var config: [String: Any] = [
            "seed": String(seed),
            "accent": accent,
            "title": String(format: L("articleReader.supportBox.title"), box.siteName),
            "template": template,
            "links": links,
        ]
        // Icon der konkreten Artikelseite; nur http(s), sonst fehlt der Schlüssel (kein Icon).
        if let iconURL = httpURL(box.iconUrl) { config["iconUrl"] = iconURL }
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return nil }

        return "(function(cfg){" + #"""
          var old=document.querySelector('merlin-support-box'); if(old) old.remove();
          // Readability liefert den Text meist in einem äußeren <div>/<article>: Container mit den
          // meisten direkten <p>-Kindern wählen (ggf. <body>), nicht in Zitaten/Listen/Figures/Infoboxen.
          var ps=[];
          var cs=[document.body].concat(Array.prototype.slice.call(document.body.querySelectorAll('div,section,article,main')));
          cs.forEach(function(c){
            if(c!==document.body&&c.closest('blockquote,figure,ul,ol,table,aside,.merlin-infobox,merlin-support-box'))return;
            var list=Array.prototype.filter.call(c.children,function(e){return e.tagName==='P'&&e.textContent.trim()!=='';});
            if(list.length>ps.length)ps=list;
          });
          if(ps.length<4) return;
          var h=0x811c9dc5>>>0, s=cfg.seed;
          for(var i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,0x01000193);}
          var idx=1+((h>>>0)%(ps.length-2));
          var box=document.createElement('merlin-support-box');
          box.setAttribute('role','note');
          box.style.cssText='display:flex;align-items:stretch;gap:0.9em;margin:1.5em 0;padding:0.85em 1em;border-left:4px solid '+cfg.accent+';border-radius:0 8px 8px 0;background:rgba(128,128,128,0.1);background:color-mix(in srgb,'+cfg.accent+' 12%,transparent);font-size:0.93em;line-height:1.6;-webkit-user-select:none;user-select:none;';
          // Zwei Spalten: links das Icon der Seite über die volle Höhe der Box (fehlt es, entfällt die
          // Spalte), rechts Titel und Satz.
          if(cfg.iconUrl){
            var icon=document.createElement('img');
            icon.alt=''; icon.referrerPolicy='no-referrer';
            // Inline-Stil schlägt die globalen img-Regeln (margin, max-width, height, border-radius);
            // align-self:stretch + height:auto macht die Spalte so hoch wie die Box.
            icon.style.cssText='display:block;flex:none;align-self:stretch;width:2.5em;height:auto;max-width:2.5em;min-height:0;margin:0;padding:0.3em;box-sizing:border-box;object-fit:contain;border-radius:6px;';
            // Kaputtes/blockiertes Icon: weglassen, die Box bleibt vollständig.
            icon.addEventListener('error',function(){icon.remove();});
            icon.src=cfg.iconUrl;
            box.appendChild(icon);
          }
          var body=document.createElement('div');
          // Text in der rechten Spalte vertikal zentriert (Flex-Spalte statt align-content, das für
          // Block-Container erst in neueren WebKit-Versionen greift), ohne Absatzabstände.
          body.style.cssText='flex:1;min-width:0;display:flex;flex-direction:column;justify-content:center;';
          var title=document.createElement('div');
          title.style.cssText='font-weight:600;margin:0;';
          title.textContent=cfg.title;
          body.appendChild(title);
          var text=document.createElement('div');
          text.style.cssText='margin:0;';
          var parts=cfg.template.split('%@');
          for(var j=0;j<parts.length;j++){
            if(parts[j]) text.appendChild(document.createTextNode(parts[j]));
            var l=cfg.links[j];
            if(j<parts.length-1 && l){
              var a=document.createElement('a');
              a.href=l.href; a.textContent=l.label;
              a.style.cssText='color:inherit;font-weight:600;text-decoration:underline;text-decoration-color:'+cfg.accent+';text-decoration-thickness:2px;text-underline-offset:2px;';
              text.appendChild(a);
            }
          }
          body.appendChild(text);
          box.appendChild(body);
          ps[idx].after(box);
        """# + "})(" + json + ");"
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

        // Am Ende des Artikels noch einmal „Autor, Medium“ (z. B. „Max Muster, taz.de“).
        let footerBylineHTML: String = {
            // Mit Profil-Link (authorUrl) wird der Autorname verlinkt.
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "&", with: "&amp;")
                 .replacingOccurrences(of: "<", with: "&lt;")
                 .replacingOccurrences(of: ">", with: "&gt;")
                 .replacingOccurrences(of: "\"", with: "&quot;")
            }
            var parts: [String] = []
            if let author = current.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                if let profileURL = current.authorProfileURL {
                    parts.append("<a href=\"\(esc(profileURL.absoluteString))\">\(esc(author))</a>")
                } else {
                    parts.append(esc(author))
                }
            }
            let site = current.displaySiteName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !site.isEmpty { parts.append(esc(site)) }
            guard !parts.isEmpty else { return "" }
            return "<div class=\"merlin-footer-byline\">\(parts.joined(separator: ", "))</div>"
        }()

        let bg             = isSepia ? "#f4ecd8" : (effectiveDark ? "#000000" : "#ffffff")
        let fg             = isSepia ? "#3b2f1e" : (effectiveDark ? "#e5e5ea" : "#1c1c1e")
        let fgMuted        = isSepia ? "#7a6350" : (effectiveDark ? "#98989d" : "#6e6e73")
        let accent         = accentColorHex
        let onAccent       = onAccentHex
        let imgPlaceholderBg = isSepia ? "#e8d9be" : (effectiveDark ? "#2c2c2e" : "#f2f2f7")
        // Lokalisierter Platzhaltertext als JS-String-Literal (JSON-kodiert, "</" entschärft,
        // damit eine Übersetzung weder das Literal noch den <script>-Block beenden kann).
        let imgPlaceholderText: String = {
            let text = L("articleReader.imagePlaceholder.unavailable")
            guard let data = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
                  let json = String(data: data, encoding: .utf8) else { return "''" }
            return json.replacingOccurrences(of: "</", with: "<\\/")
        }()

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
            /* Der Server (normalizeQuotes) legt die Quellenangabe als <cite> ins
               blockquote. Nur ein Folgeabsatz, der ausschließlich aus einem <cite>
               besteht, gilt als Attribution - ein normaler Absatz nach einem Zitat
               darf nicht wie ein Zitatgeber aussehen. */
            blockquote + p:has(> cite:only-child) {
              display: block;
              width: 100%;
              text-align: center !important;
              font-family: \(ReaderFont.system.cssValue);
              font-size: 0.85em;
              color: \(accentColorHex);
            }
            blockquote + p:has(> cite:only-child) cite, blockquote + p:has(> cite:only-child) cite * { font-style: normal; }
            blockquote cite em, blockquote cite strong { font-style: normal; }
            pre, code {
              background: \(effectiveDark ? "#2c2c2e" : "#f2f2f7");
              border-radius: 6px; font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em;
            }
            code { padding: 2px 5px; }
            pre { padding: 12px; overflow-x: auto; }
            pre code { background: none; padding: 0; }
            figure { margin: 1em 0 0; }
            figure:first-child { margin-top: 0; }
            figure img { display: block; margin-bottom: 0; }
            figcaption { font-size: 0.75em; line-height: 1.4; color: \(accentColorHex); text-align: left; margin-top: 2px; margin-bottom: 1em; }
            /* ── Titelbild auf Akzentfläche, randlos, danach Tonstufen ── */
            body > figure:first-child,
            body > img:first-child {
              display: block;
              width: calc(100% + 40px) !important;
              max-width: none !important;
              margin: 0 -20px 0 !important;
              background: \(accent);
              border-radius: 0 !important;
            }
            body > figure:first-child img {
              width: 100%; margin: 0 !important; border-radius: 0 !important;
            }
            body > figure:first-child figcaption {
              margin: 0; padding: 10px 20px 14px;
              color: \(onAccent);
              font-size: 11px; font-weight: 700; letter-spacing: 1px;
            }
            /* Bildquelle (vom Server als <cite> markiert): nicht fett, kursiv, halbtransparent */
            figcaption cite { font-weight: 400; font-style: italic; opacity: 0.5; }
            figcaption cite * { font-weight: inherit; font-style: inherit; }
            body > figure:first-child::after {
              content: ""; display: block; height: 44px;
              background: linear-gradient(to bottom,
                color-mix(in oklch, \(accent) 75%, \(bg)) 0 14px,
                color-mix(in oklch, \(accent) 55%, \(bg)) 14px 26px,
                color-mix(in oklch, \(accent) 35%, \(bg)) 26px 36px,
                color-mix(in oklch, \(accent) 15%, \(bg)) 36px 44px);
            }
            /* nacktes <img> ohne <figure>: Stufen per box-shadow */
            body > img:first-child {
              margin-bottom: 44px !important;
              box-shadow:
                0 14px 0 color-mix(in oklch, \(accent) 75%, \(bg)),
                0 26px 0 color-mix(in oklch, \(accent) 55%, \(bg)),
                0 36px 0 color-mix(in oklch, \(accent) 35%, \(bg)),
                0 44px 0 color-mix(in oklch, \(accent) 15%, \(bg));
            }
            /* p { margin: 0 0 1em } setzt margin-top explizit auf 0 — ohne diese
               Regel klebt der erste Textblock direkt am Bild darüber (img selbst
               hat zwar margin-bottom, figure aber bewusst nicht, siehe oben). */
            img + p, figure + p { margin-top: 1em; }
            hr { border: none; border-top: 1px solid \(effectiveDark ? "#2c2c2e" : "#e5e5ea"); margin: 2em 0; }
            ul, ol { padding-left: 1.5em; }
            li { margin-bottom: 0.3em; }
            table { border-collapse: collapse; width: 100%; font-size: 0.9em; overflow-x: auto; display: block; }
            th, td { padding: 8px 12px; border: 1px solid \(effectiveDark ? "#3a3a3c" : "#d1d1d6"); text-align: left; }
            th { background: \(effectiveDark ? "#2c2c2e" : "#f2f2f7"); font-weight: 600; }
            /* Metadaten unter Dateien aus „Merlin Dateien“ (MerlinFileService::metadataHtml). */
            .merlin-file-metadata { margin-top: 2.5em; font-size: 0.8em; }
            .merlin-file-metadata details { margin: 0.75em 0; }
            .merlin-file-metadata summary { font-weight: 600; }
            .merlin-file-metadata table { display: table; table-layout: fixed; margin-top: 0.5em; }
            .merlin-file-metadata th { width: 38%; font-weight: 500; background: none; opacity: 0.7; }
            .merlin-file-metadata th, .merlin-file-metadata td { padding: 5px 8px; vertical-align: top; overflow-wrap: anywhere; }
            /* Erkannter Text (OCR) und Termin-Link darunter (RecognizedTextEvent). */
            .merlin-file-text { margin-top: 2em; }
            .merlin-file-event a {
              display: inline-block; padding: 8px 16px; border-radius: 999px;
              background: \(accent); color: \(onAccent) !important; text-decoration: none;
              font-size: 0.9em; font-weight: 600;
            }
            .merlin-infobox {
              background: \(isSepia ? "#e8d9be" : (effectiveDark ? "#1e2d3d" : "#f0f7ff"));
              border-left: 4px solid \(accent);
              border-radius: 0 8px 8px 0;
              padding: 14px 16px;
              margin: 1.5em 0;
              font-size: 0.93em;
              line-height: 1.6;
              color: \(fg);
            }
            .merlin-infobox > *:first-child { margin-top: 0; }
            .merlin-infobox > *:last-child  { margin-bottom: 0; }
            .merlin-infobox a { color: \(accent) !important; text-decoration-color: \(accent)80; }
            /* Instagram-/X-/Bluesky-Embeds (siehe ContentExtractorService.swift,
               isAllowedWidgetScriptSrc()) rendern sich nach dem Laden ihres
               Widget-Skripts selbst neu - der generische blockquote-Style oben
               (zentriert, kursiv, Serif, Akzentfarbe - als Pull-Quote gedacht)
               würde nur bis zum Laden sichtbar sein und dann falsch wirken,
               deshalb hier zurückgesetzt. */
            blockquote.instagram-media, blockquote.twitter-tweet, blockquote.bluesky-embed {
              margin: 1em 0; padding: 0; text-align: left;
              font-family: -apple-system, sans-serif; font-size: 1em;
              font-style: normal; line-height: normal; color: \(fg);
            }
            blockquote.instagram-media p, blockquote.twitter-tweet p, blockquote.bluesky-embed p {
              margin: 0 0 0.4em; text-align: left !important;
            }
            /* Mastodon-Post-Karte (siehe MastodonPostResolverService/
               buildMastodonThreadHtml()): kein Drittanbieter-Widget wie
               Instagram/X/Bluesky (föderiert, kein zentraler Embed-Host),
               sondern eigenes, statisches Markup - braucht deshalb echtes
               Styling statt nur eines Platzhalter-Resets. */
            .merlin-mastodon-post {
              display: block;
              border: 1px solid \(effectiveDark ? "#3a3a3c" : "#d1d1d6");
              border-radius: 8px; padding: 14px 16px; margin: 1.5em 0; color: \(fg);
            }
            .merlin-footer-byline {
              margin-top: 32px; padding-top: 16px;
              border-top: 1px solid rgba(127,127,127,0.25);
              font-size: 0.9em; font-style: italic; color: \(fgMuted);
            }
            .merlin-footer-byline a { color: inherit !important; }
            .merlin-mastodon-post + .merlin-mastodon-post { margin-top: 8px; }
            .merlin-mastodon-post__header {
              display: flex; align-items: center; gap: 10px;
              text-decoration: none; color: \(fg); margin-bottom: 10px;
            }
            .merlin-mastodon-post__avatar {
              width: 40px; height: 40px; border-radius: 50%;
              object-fit: cover; flex-shrink: 0; margin: 0;
            }
            .merlin-mastodon-post__author {
              display: flex; flex-direction: column; line-height: 1.3; min-width: 0;
            }
            .merlin-mastodon-post__name {
              font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
            }
            .merlin-mastodon-post__handle {
              color: \(fgMuted); font-size: 0.9em; overflow: hidden;
              text-overflow: ellipsis; white-space: nowrap;
            }
            .merlin-mastodon-post__content p { margin: 0.5em 0; }
            .merlin-mastodon-post__content p:first-child { margin-top: 0; }
            .merlin-mastodon-post__content p:last-child { margin-bottom: 0; }
            .merlin-mastodon-post__media {
              display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
              gap: 6px; margin-top: 10px;
            }
            .merlin-mastodon-post__media-item {
              width: 100%; height: 140px; object-fit: cover; border-radius: 6px; margin: 0;
            }
            /* Videos mitten im Text (siehe merlinInlineMediaJS): sobald der Player
               steht, ersetzt er Vorschaubild und "Zum Video"-Link. */
            figure.merlin-inline-media.merlin-inline-media--playable > img,
            figure.merlin-inline-media.merlin-inline-media--playable > .merlin-img-placeholder,
            figure.merlin-inline-media.merlin-inline-media--playable > .mdbg-wrap,
            figure.merlin-inline-media.merlin-inline-media--playable > .merlin-inline-media-source {
              display: none;
            }
            figure.merlin-inline-media > .merlin-inline-media-source {
              margin: 4px 0 1em; font-size: 0.85em;
            }
            merlin-inline-player { display: block; margin: 8px 0 0; }
            merlin-inline-player video {
              display: block; width: 100%; height: auto;
              aspect-ratio: auto 16 / 9; max-height: 125vw;
              background: #000; border-radius: 8px; object-fit: contain;
            }
            merlin-inline-player audio { display: block; width: 100%; }
            body > figure.merlin-inline-media:first-child merlin-inline-player { margin: 0; }
            body > figure.merlin-inline-media:first-child merlin-inline-player video { border-radius: 0; }
            body > figure.merlin-inline-media:first-child > .merlin-inline-media-source { padding: 0 20px; }
          </style>
        </head>
        <body>
          \(rewriteYouTubeEmbeds(in: stripAudioPlayerElements(in: promoteHeroVideo(in: stripHeroImageIfShownAsVideoCover(in: rewriteImageURLs(in: injectHeroImageIfNeeded(into: promoteLazyImageAttributes(in: content))))))))\(footerBylineHTML)
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
          <script>\(merlinInlineMediaJS)</script>
          <script>
          (function(){
            var PH_BG = '\(imgPlaceholderBg)';
            var PH_FG = '\(fgMuted)';
            var PH_TEXT = \(imgPlaceholderText);
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
              ph.className = 'merlin-img-placeholder';
              // Original-URL merken: fetchMissingContentImages() lädt dasselbe Bild
              // im Hintergrund mit korrektem Referer nach (siehe swapImageSrcJS) -
              // ohne diese Markierung würde der Swap ins Leere laufen, weil das
              // <img>-Element hier bereits aus dem DOM entfernt wurde.
              ph.dataset.merlinOriginalSrc = img.getAttribute('src') || '';
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
              ph.innerHTML = PH_SVG;
              var label = document.createElement('span');
              label.style.cssText = 'font-size:12px;color:' + PH_FG + ';text-align:center;padding:0 12px';
              label.textContent = PH_TEXT;
              ph.appendChild(label);
              if (img.parentNode) img.parentNode.replaceChild(ph, img);
            }

            function attachError(img) {
              if (img.dataset.merlinPhAttached) return;
              // Icon der Support-Infobox: kein Artikelbild, hat einen eigenen Umgang mit Ladefehlern
              // (wird einfach entfernt, siehe supportBoxScript) statt des großen Platzhalters.
              if (img.closest && img.closest('merlin-support-box')) return;
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
    /// Eltern-Tag für neu angelegte Tags; `nil` = oberste Ebene.
    @State private var newTagParentId: Int?     = nil

    private var tree: TagTree { TagTree(allTags) }

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

                    // Existing tags as an indented tree (sub-tags below their parent)
                    if !allTags.isEmpty {
                        TagTreeSelectionList(tree: tree, selection: $selectedTagIds)
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
                                        selectedTagIds = tree.selecting(tag.id, in: selectedTagIds)
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

                    // Eltern-Tag für die neuen Tags (verschachtelte Tags)
                    if !allTags.isEmpty,
                       !pendingTags.isEmpty || !newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TagParentPicker(tree: tree, selection: $newTagParentId)
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
                let created = (try? await MerlinAPI.shared.resolveTagIds(for: pendingTags, parentId: newTagParentId)) ?? []
                created.forEach { finalIds.insert($0) }
                // Neue Unter-Tags ziehen ihren Eltern-Tag mit, wie beim Antippen.
                if !created.isEmpty, let parent = newTagParentId {
                    finalIds = tree.selecting(parent, in: finalIds)
                }
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

// MARK: – Paywall subscribe banner

/// Nicht-blockierender Hinweis: zeigt, dass der Artikel per generischem Content-Filter-Marker
/// als Bezahlartikel erkannt wurde (`Article.isPaywalled`), dessen Domain KEINE
/// Login-Unterstützung hat (sonst zeigte `PaywallWarningBanner` oben stattdessen den
/// Zugangsdaten-Hinweis). Merlin kann den Artikel nicht automatisch freischalten - der Nutzer
/// entscheidet zwischen Abo abschliessen (falls eine URL hinterlegt ist) und Archivieren.
private struct PaywallSubscribeBanner: View {
    let subscribeUrl: String?
    let onSubscribe: () -> Void
    let onArchive: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                Text(L("articleReader.paywallSubscribeBanner.message"))
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
                if subscribeUrl != nil {
                    Button(L("articleReader.paywallSubscribeBanner.subscribeButton"), action: onSubscribe)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                Button(L("articleReader.paywallSubscribeBanner.archiveButton"), action: onArchive)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
    }
}
