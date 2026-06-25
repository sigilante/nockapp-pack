/+  *http, sprite
/=  *  /common/wrapper
=>
|%
::  Klondike Solitaire. All game logic in the Hoon kernel.
::
::  Card model: a card is a @ud in 0..51.
::    suit = (div card 13)   0=hearts 1=diamonds 2=clubs 3=spades
::    rank = (mod card 13)   0=A 1=2 ... 9=10 10=J 11=Q 12=K
::  Color: hearts/diamonds (suit<2) are RED; clubs/spades (suit>=2) are BLACK.
::
+$  card  @ud
::  +$ pile: one tableau column.
::    down: face-down cards, head = topmost face-down.
::    up:   face-up cards, head = card nearest the down pile, last = exposed top.
::          A movable run is a suffix of `up`.
::
+$  pile  [down=(list card) up=(list card)]
::  +$ loc: a board location.
::
+$  loc
  $%  [%waste ~]
      [%tab i=@ud]            ::  tableau column 0..6
      [%found i=@ud]          ::  foundation 0..3
  ==
+$  sel  (unit [src=loc i=@ud])
::  +$ game: the whole board, one versioned noun.
::
+$  game
  $:  stock=(list card)              ::  face-down draw pile, head = next to draw
      waste=(list card)              ::  face-up discard, head = exposed top
      tabs=(list pile)               ::  exactly 7 tableau columns
      founds=(list (list card))      ::  exactly 4 foundations, head=bottom last=top
      =sel
      moves=@ud
  ==
+$  server-state  [%0 game=game]
::  suit/rank/color helpers
::
++  suit  |=(c=card (div c 13))
++  rank  |=(c=card (mod c 13))
++  red   |=(c=card (lth (suit c) 2))             ::  hearts/diamonds red
::  +suit-name: css suit token.
::
++  suit-name
  |=  c=card
  ^-  tape
  ?+  (suit c)  "spades"
    %0  "hearts"
    %1  "diamonds"
    %2  "clubs"
    %3  "spades"
  ==
::  +rank-name: css rank token A,2..10,J,Q,K.
::
++  rank-name
  |=  c=card
  ^-  tape
  =/  r  (rank c)
  ?+  r  (scow %ud +(r))
    %0   "A"
    %9   "10"
    %10  "J"
    %11  "Q"
    %12  "K"
  ==
::  +card-class: the css class "<suit>-<rank>" for a face-up card.
::
++  card-class
  |=  c=card
  ^-  tape
  "{(suit-name c)}-{(rank-name c)}"
::  list helpers ---------------------------------------------------------------
::  +rear: last element of a non-empty list (callers guard against ~).
::
++  rear
  |=  l=(list card)
  ^-  card
  ?~  l  !!
  ?~  t.l  i.l
  $(l t.l)
::  +snip: all but the last element.
::
++  snip
  |=  l=(list card)
  ^-  (list card)
  ?~  l  ~
  ?~  t.l  ~
  [i.l $(l t.l)]
::  +shuffle: Fisher-Yates of 0..51 seeded from entropy `eny`.
::    The `og` rng is stubbed at this stdlib, so we derive a fresh pseudo-random
::    number per step from sha-256 of [eny step], matching the minesweeper pattern.
::
++  shuffle
  |=  eny=@
  ^-  (list card)
  =/  arr  `(list card)`(gulf 0 51)
  =/  n  52
  =/  i  0
  |-  ^-  (list card)
  ?:  (gte i (dec n))  arr
  =/  span  (sub n i)
  =/  r  (mod (shax (add (mul eny 1.000.003) i)) span)
  =/  j  (add i r)
  =/  vi  (snag i arr)
  =/  vj  (snag j arr)
  =.  arr  (snap arr i vj)
  =.  arr  (snap arr j vi)
  $(i +(i))
::  +deal: build a fresh game from a shuffled deck.
::    Tableau col k (0..6) gets k+1 cards; the last is face-up.
::
++  deal
  |=  eny=@
  ^-  game
  =/  deck  (shuffle eny)
  =|  tabs=(list pile)
  =/  k  0
  =/  rest  deck
  |-  ^-  game
  ?:  =(7 k)
    [stock=rest waste=~ tabs=(flop tabs) founds=~[~ ~ ~ ~] sel=~ moves=0]
  =/  cnt  +(k)
  =/  these  (scag cnt rest)
  =.  rest  (slag cnt rest)
  =/  up=(list card)  ~[(rear these)]
  =/  down=(list card)  (snip these)
  $(tabs [[down up] tabs], k +(k))
::  +new-game: deal seeded from eny.
::
++  new-game  |=(eny=@ (deal eny))
::  legality -------------------------------------------------------------------
::  +tab-ok: can `lo` (the deepest card of a run) land on tableau top `top`?
::    Empty pile takes a King; else descending rank + alternating color.
::
++  tab-ok
  |=  [lo=card top=(unit card)]
  ^-  ?
  ?~  top
    =(12 (rank lo))                       ::  empty: King only
  =/  t  u.top
  ?&  =(+((rank lo)) (rank t))            ::  lo one below t
      !=((red lo) (red t))               ::  alternating color
  ==
::  +found-ok: can single card `c` go on foundation top `f`?
::    Empty foundation takes an Ace; else same suit, ascending.
::
++  found-ok
  |=  [c=card f=(unit card)]
  ^-  ?
  ?~  f
    =(0 (rank c))                         ::  empty: Ace only
  =/  t  u.f
  ?&  =((suit c) (suit t))
      =((rank c) +((rank t)))
  ==
::  +legal-run: is `run` a valid movable sequence (desc, alternating)?
::    A single card is always legal.
::
++  legal-run
  |=  run=(list card)
  ^-  ?
  ?~  run  %.n
  ?~  t.run  %.y
  ?&  =(+((rank i.t.run)) (rank i.run))
      !=((red i.run) (red i.t.run))
      $(run t.run)
  ==
::  +run-at: the run of cards being moved from a source location.
::    waste/foundation: a single card (the top), index ignored.
::    tableau: the suffix of `up` starting at index i (deepest first).
::    ~ if empty/out of range.
::
++  run-at
  |=  [g=game =loc i=@ud]
  ^-  (list card)
  ?-  -.loc
    %waste  ?~(waste.g ~ ~[i.waste.g])
    %found  =/(f (snag i.loc founds.g) ?~(f ~ ~[(rear f)]))
    %tab
      =/  p  (snag i.loc tabs.g)
      ?:  (gte i (lent up.p))  ~
      (slag i up.p)
  ==
::  +won: are all 52 cards on the foundations?
::
++  won
  |=  g=game
  ^-  ?
  =/  total
    %+  roll  founds.g
    |=  [f=(list card) acc=@ud]
    (add acc (lent f))
  =(52 total)
::  routing helpers ------------------------------------------------------------
++  route-is
  |=  [pfx=tape t=tape]
  ^-  ?
  =(`0 (find pfx t))
::  +grab-num: parse the digit run after `key` in tape (0 on miss).
::
++  grab-num
  |=  [key=tape t=tape]
  ^-  @ud
  =/  idx  (find key t)
  ?~  idx  0
  =/  rest  (slag (add u.idx (lent key)) t)
  =/  digs  |-(?~(rest ~ ?:((gte i.rest '0') ?:((lte i.rest '9') [i.rest $(rest t.rest)] ~) ~)))
  ?~  digs  0
  (scan digs dem)
::  +grab-key: parse the lowercase-alpha run after `key` (e.g. src=tab -> "tab").
::
++  grab-key
  |=  [key=tape t=tape]
  ^-  tape
  =/  idx  (find key t)
  ?~  idx  ~
  =/  rest  (slag (add u.idx (lent key)) t)
  |-  ^-  tape
  ?~  rest  ~
  ?:  ?&((gte i.rest 'a') (lte i.rest 'z'))
    [i.rest $(rest t.rest)]
  ~
::  rendering ------------------------------------------------------------------
++  empty-slot
  |=  extra=tape
  ^-  tape
  "<div class=\"slot {extra}\"></div>"
::  +drag-card: a face-up card that is a drag SOURCE (draggable, carries pile+i).
::  `target` says whether it is ALSO a drop target for its pile (data-dst).
::  Tableau cards are (their column carries data-dst anyway, and the exposed card
::  doubles as a target); the WASTE card is NOT -- you can never drop onto the
::  waste, and a draggable element that is also a drop target can, in WebKit,
::  resolve a drop back onto itself (dst="waste"), silently killing the move.
::
++  drag-card
  |=  [c=card pile=tape i=@ud target=?]
  ^-  tape
  =/  is  (scow %ud i)
  =/  dst  ?:(target " data-dst=\"{pile}\"" "")
  ;:  weld
    "<div class=\"card {(card-class c)}\" draggable=\"true\""
    " data-pile=\"{pile}\" data-i=\"{is}\"{dst}></div>"
  ==
::  +drop-zone: wrap inner html in a drop target for destination `dst`.
::
++  drop-zone
  |=  [inner=tape dst=tape]
  ^-  tape
  ;:  weld
    "<div class=\"dropzone\" data-dst=\"{dst}\">"
    inner
    "</div>"
  ==
::  +card-div: a face-up (non-interactive) card sprite div.
::
++  card-div
  |=  c=card
  ^-  tape
  "<div class=\"card {(card-class c)}\"></div>"
::  +back-div: a face-down card sprite div.
::
++  back-div  "<div class=\"card back\"></div>"
::  +is-sel: does the current selection point at [loc i]?
::
++  is-sel
  |=  [g=game =loc i=@ud]
  ^-  ?
  ?~  sel.g  %.n
  &(=(src.u.sel.g loc) =(i.u.sel.g i))
::  +render-tab: one tableau column as stacked cards.
::
++  render-tab
  |=  [g=game k=@ud]
  ^-  tape
  =/  p  (snag k tabs.g)
  =/  src  "tab{(scow %ud k)}"
  ::  whole column empty: a single empty drop-zone slot (accepts a King)
  ?:  &(?=(~ down.p) ?=(~ up.p))
    ;:  weld
      "<div class=\"tabcol\">"
      (drop-zone (empty-slot "tabslot") src)
      "</div>"
    ==
  ::  face-down backs (not draggable)
  =/  downs=tape
    %+  roll  down.p
    |=  [c=card acc=tape]
    (weld acc back-div)
  ::  face-up cards: each is a drag source at its index (and a drop target for
  ::  the column via data-dst on the exposed card).
  =/  ups=tape
    =/  i  0
    =/  u  up.p
    |-  ^-  tape
    ?~  u  ""
    (weld (drag-card i.u src i &) $(u t.u, i +(i)))
  ::  The WHOLE column is a drop target (data-dst on .tabcol), so a drop anywhere
  ::  over the column -- including the offset/overlapping gaps between stacked
  ::  cards -- resolves via closest('[data-dst]') and targets the exposed top.
  ::  (The per-card data-dst on the exposed card is kept too; it's harmless.)
  ;:  weld
    "<div class=\"tabcol\" data-dst=\"{src}\">"
    downs
    ups
    "</div>"
  ==
::  +render: full HTML page.
::
++  render
  |=  g=game
  ^-  (unit octs)
  =/  win  (won g)
  =/  founds-html=tape
    =/  i  0
    =/  fs  founds.g
    |-  ^-  tape
    ?~  fs  ""
    =/  top=tape
      ?~(i.fs (empty-slot "foundslot") (card-div (rear i.fs)))
    (weld (drop-zone top "found{(scow %ud i)}") $(fs t.fs, i +(i)))
  =/  stock-html=tape
    ?~  stock.g
      "<form class=\"cardform\" method=\"POST\" action=\"/draw\"><button type=\"submit\" class=\"cardbtn\"><div class=\"slot recycle\">&#8635;</div></button></form>"
    "<form class=\"cardform\" method=\"POST\" action=\"/draw\"><button type=\"submit\" class=\"cardbtn\">{back-div}</button></form>"
  =/  waste-html=tape
    ?~  waste.g
      (empty-slot "wasteslot")
    (drag-card i.waste.g "waste" 0 |)
  =/  tab-row=tape
    %+  roll  (gulf 0 6)
    |=  [k=@ud acc=tape]
    (weld acc (render-tab g k))
  =/  banner=tape
    ?:  win  "<div class=\"banner win\">YOU WIN! &#127881;</div>"  ""
  =/  selnote=tape
    "Drag a face-up card (or a run) onto a legal pile, or onto a foundation. Click the stock to draw."
  =/  doc=tape
    ;:  weld
      "<!doctype html><html><head><meta charset=\"utf-8\">"
      "<title>NockApp Solitaire</title>"
      "<link rel=\"stylesheet\" href=\"/style.css?v={asset-ver}\">"
      "<script src=\"/app.js?v={asset-ver}\" defer></script>"
      "</head><body>"
      "<h1>NockApp Klondike Solitaire</h1>"
      "<p class=\"sub\">All game logic in the Hoon kernel. Moves: {(scow %ud moves.g)}</p>"
      banner
      "<div class=\"toprow\">"
      "<div class=\"stockwaste\">"
      stock-html
      waste-html
      "</div>"
      "<div class=\"spacer\"></div>"
      "<div class=\"foundations\">"
      founds-html
      "</div>"
      "</div>"
      "<div class=\"tableau\">"
      tab-row
      "</div>"
      "<p class=\"note\">{selnote}</p>"
      "<form method=\"POST\" action=\"/new\"><button type=\"submit\" class=\"newbtn\">New game</button></form>"
      "<p class=\"foot\">Card art reused from the blackjack project.</p>"
      "</body></html>"
    ==
  (to-octs (crip doc))
::  +asset-ver: cache-busting token for /style.css and /app.js. The page HTML is
::  served fresh on every GET, so changing this here immediately changes the asset
::  URLs the browser requests, invalidating the day-long browser cache. BUMP THIS
::  whenever app.js or style.css change, so a redeploy actually reaches the user.
::
++  asset-ver  "4"
::  +stylesheet: the /style.css body, with the data-URI sprite sheet embedded.
::
++  stylesheet
  ^-  tape
  ;:  weld
    base-css
    ".card\{background-image:url('data:image/png;base64,"
    (trip sprite-b64)
    "')}"
  ==
::  +base-css: layout css (a '''-block, so { } are literal and safe).
::
++  base-css
  ^-  tape
  %-  trip
  '''
  body{font-family:-apple-system,Segoe UI,Arial,sans-serif;background:#1d6b3a;color:#fff;margin:0;padding:16px}
  h1{margin:0 0 2px 0;font-size:20px}
  .sub{margin:0 0 10px 0;color:#cdebd6;font-size:13px}
  .note{color:#cdebd6;font-size:13px}
  .foot{color:#9fd0b0;font-size:11px;margin-top:18px}
  .toprow{display:flex;align-items:flex-start;margin-bottom:18px}
  .stockwaste{display:flex;gap:8px}
  .spacer{flex:1}
  .foundations{display:flex;gap:8px}
  .tableau{display:flex;gap:10px;align-items:flex-start}
  .tabcol{display:flex;flex-direction:column;min-width:71px;min-height:96px}
  .tabcol>.card,.tabcol>.dropzone{margin-bottom:-72px}
  .tabcol>.dropzone:last-child{margin-bottom:0}
  .tabcol>.card:last-child{margin-bottom:0}
  .card{width:71px;height:96px;display:block;background-repeat:no-repeat}
  .card.back{background-position:-284px -384px}
  .card[draggable="true"]{cursor:grab}
  .card[draggable="true"]:active{cursor:grabbing}
  .slot{width:71px;height:96px;border:2px dashed rgba(255,255,255,.5);border-radius:6px;box-sizing:border-box;display:flex;align-items:center;justify-content:center;font-size:28px;color:rgba(255,255,255,.7)}
  .dropzone{display:block}
  .dropzone.dragover,.card.dragover{outline:3px solid #ffd54a;outline-offset:-3px;border-radius:6px}
  .stockwaste .cardform{margin:0;padding:0;display:block}
  .stockwaste .cardbtn{margin:0;padding:0;border:0;background:transparent;cursor:pointer;display:block;line-height:0}
  .droptarget{width:71px;height:24px}
  .banner{padding:10px;margin:8px 0;border-radius:8px;font-weight:bold}
  .banner.win{background:#ffd54a;color:#1d6b3a;font-size:18px}
  .newbtn{margin-top:12px;padding:8px 14px;font-size:14px;cursor:pointer;border-radius:6px;border:0;background:#ffd54a;color:#1d6b3a;font-weight:bold}
  .hearts-A{background-position:0 0}.hearts-2{background-position:-71px 0}.hearts-3{background-position:-142px 0}.hearts-4{background-position:-213px 0}.hearts-5{background-position:-284px 0}.hearts-6{background-position:-355px 0}.hearts-7{background-position:-426px 0}.hearts-8{background-position:-497px 0}.hearts-9{background-position:-568px 0}.hearts-10{background-position:-639px 0}.hearts-J{background-position:-710px 0}.hearts-Q{background-position:-781px 0}.hearts-K{background-position:-852px 0}
  .diamonds-A{background-position:0 -96px}.diamonds-2{background-position:-71px -96px}.diamonds-3{background-position:-142px -96px}.diamonds-4{background-position:-213px -96px}.diamonds-5{background-position:-284px -96px}.diamonds-6{background-position:-355px -96px}.diamonds-7{background-position:-426px -96px}.diamonds-8{background-position:-497px -96px}.diamonds-9{background-position:-568px -96px}.diamonds-10{background-position:-639px -96px}.diamonds-J{background-position:-710px -96px}.diamonds-Q{background-position:-781px -96px}.diamonds-K{background-position:-852px -96px}
  .clubs-A{background-position:0 -192px}.clubs-2{background-position:-71px -192px}.clubs-3{background-position:-142px -192px}.clubs-4{background-position:-213px -192px}.clubs-5{background-position:-284px -192px}.clubs-6{background-position:-355px -192px}.clubs-7{background-position:-426px -192px}.clubs-8{background-position:-497px -192px}.clubs-9{background-position:-568px -192px}.clubs-10{background-position:-639px -192px}.clubs-J{background-position:-710px -192px}.clubs-Q{background-position:-781px -192px}.clubs-K{background-position:-852px -192px}
  .spades-A{background-position:0 -288px}.spades-2{background-position:-71px -288px}.spades-3{background-position:-142px -288px}.spades-4{background-position:-213px -288px}.spades-5{background-position:-284px -288px}.spades-6{background-position:-355px -288px}.spades-7{background-position:-426px -288px}.spades-8{background-position:-497px -288px}.spades-9{background-position:-568px -288px}.spades-10{background-position:-639px -288px}.spades-J{background-position:-710px -288px}.spades-Q{background-position:-781px -288px}.spades-K{background-position:-852px -288px}
  '''
::  +app-js: the only JS in the suite. Records the in-flight drag in the browser
::  ({src,i} on dragstart) and on drop submits POST /move?src&i&dst -- the kernel
::  validates + applies the move and returns the re-rendered board. A '''-block, so
::  the JS { } are literal and safe.
::
++  app-js
  ^-  tape
  %-  trip
  '''
  (function(){
    var drag=null;
    function post(src,i,dst){
      var f=document.createElement('form');
      f.method='POST';
      f.action='/move?src='+src+'&i='+i+'&dst='+dst;
      document.body.appendChild(f);
      f.submit();
    }
    document.addEventListener('dragstart',function(e){
      var c=e.target.closest('[data-pile]');
      if(!c){return;}
      drag={src:c.getAttribute('data-pile'),i:c.getAttribute('data-i')};
      if(e.dataTransfer){
        e.dataTransfer.effectAllowed='move';
        // Encode the source in the payload too, so drop never depends on a
        // module-level var that another handler might have cleared.
        e.dataTransfer.setData('text/plain',drag.src+'|'+drag.i);
      }
    });
    document.addEventListener('dragend',function(){drag=null;clearHi();});
    function clearHi(){
      var els=document.querySelectorAll('.dragover');
      for(var k=0;k<els.length;k++){els[k].classList.remove('dragover');}
    }
    document.addEventListener('dragover',function(e){
      var z=e.target.closest('[data-dst]');
      if(!z){return;}
      e.preventDefault();
      if(e.dataTransfer){e.dataTransfer.dropEffect='move';}
      clearHi();z.classList.add('dragover');
    });
    document.addEventListener('drop',function(e){
      var z=e.target.closest('[data-dst]');
      if(!z){clearHi();return;}
      e.preventDefault();
      var src=null,i=null;
      if(drag){src=drag.src;i=drag.i;}
      else if(e.dataTransfer){var p=(e.dataTransfer.getData('text/plain')||'').split('|');if(p.length===2){src=p[0];i=p[1];}}
      if(src===null){clearHi();return;}
      var dst=z.getAttribute('data-dst');
      // Never submit a no-op self-drop (e.g. releasing on the source pile).
      if(dst===src){clearHi();return;}
      post(src,i,dst);
    });
  })();
  '''
::  +sprite-b64: the blackjack sprite sheet, base64-encoded (pure ASCII cord).
::  Defined in /lib/sprite for build hygiene; here we re-export the constant.
::
++  sprite-b64  data:sprite
::  move engine ----------------------------------------------------------------
::  +try-move: validate + perform a move; ~ if illegal.
::
++  try-move
  |=  [g=game src=loc i=@ud run=(list card) dst=loc]
  ^-  (unit game)
  ?~  run  ~                                       ::  empty run: nothing to move
  =/  lo=card  i.run                              ::  deepest card of the run
  ?-    -.dst
      %waste  ~
      %found
    ?.  =(1 (lent run))  ~                        ::  only single cards to foundation
    =/  f  (snag i.dst founds.g)
    =/  top  ?~(f ~ `(rear f))
    ?.  (found-ok lo top)  ~
    =/  g2  (remove-src g src i)
    =/  nf  (snap founds.g2 i.dst (snoc (snag i.dst founds.g2) lo))
    `(post-move g2(founds nf))
  ::
      %tab
    =/  p  (snag i.dst tabs.g)
    =/  top  ?~(up.p ~ `(rear up.p))
    ?.  (tab-ok lo top)  ~
    =/  g2  (remove-src g src i)
    =/  p2  (snag i.dst tabs.g2)
    =/  np=pile  p2(up (weld up.p2 `(list card)`run))
    `(post-move g2(tabs (snap tabs.g2 i.dst np)))
  ==
::  +remove-src: remove the moved run from its source location.
::
++  remove-src
  |=  [g=game src=loc i=@ud]
  ^-  game
  ?-  -.src
    %waste  g(waste ?~(waste.g ~ t.waste.g))
    %found
      =/  f  (snag i.src founds.g)
      g(founds (snap founds.g i.src (snip f)))
    %tab
      =/  p  (snag i.src tabs.g)
      =/  keep  (scag i up.p)                     ::  cards above the run stay
      =/  np=pile  p(up keep)
      =/  np2=pile
        ?:  ?&(?=(~ up.np) ?=(^ down.np))
          [down=(snip down.np) up=~[(rear down.np)]]
        np
      g(tabs (snap tabs.g i.src np2))
  ==
::  +post-move: bump moves, clear selection.
::
++  post-move
  |=  g=game
  ^-  game
  g(sel ~, moves +(moves.g))
--
::
=>
|%
++  moat  (keep server-state)
::
++  inner
  |_  state=server-state
  ::
  ++  load
    |=  arg=server-state
    ^-  server-state
    arg
  ::
  ++  peek
    |=  =path
    ^-  (unit (unit *))
    ~
  ::
  ++  poke
    |=  =ovum:moat
    ^-  [(list effect) server-state]
    =/  sof-cau=(unit cause)  ((soft cause) cause.input.ovum)
    ?~  sof-cau
      ~&  "cause incorrectly formatted!"
      !!
    =/  [id=@ uri=@t =method headers=(list header) body=(unit octs)]  +.u.sof-cau
    ::  Boot default: if no tableau dealt yet, deal a fresh game seeded from eny.
    =/  g=game
      ?:  =(7 (lent tabs.game.state))  game.state
      (new-game eny.input.ovum)
    =/  ok
      |=  b=game
      ^-  [(list effect) server-state]
      ~>  %slog.[0 leaf+"metric: moves={<moves.b>}"]
      [~[[%res id %200 ['content-type' 'text/html']~ (render b)]] state(game b)]
    ?+    method  [~[[%res id %400 ~ ~]] state]
        %'GET'
      =/  uri-tape  (trip uri)
      ::  /style.css: the sprite stylesheet, cached by the browser for a day.
      ?:  (route-is "/style.css" uri-tape)
        :_  state(game g)
        :~  :*  %res  id  %200
                :~  ['content-type' 'text/css']
                    ['cache-control' 'public, max-age=86400']
                ==
                (to-octs (crip stylesheet))
        ==  ==
      ::  /app.js: the tiny drag-and-drop layer, cached by the browser for a day.
      ?:  (route-is "/app.js" uri-tape)
        :_  state(game g)
        :~  :*  %res  id  %200
                :~  ['content-type' 'application/javascript']
                    ['cache-control' 'public, max-age=86400']
                ==
                (to-octs (crip app-js))
        ==  ==
      ::  any other GET: render the board (also surfaces the metric)
      ~>  %slog.[0 leaf+"metric: moves={<moves.g>}"]
      [~[[%res id %200 ['content-type' 'text/html']~ (render g)]] state(game g)]
    ::
        %'POST'
      =/  uri-tape  (trip uri)
      ::  /new: fresh deal
      ?:  (route-is "/new" uri-tape)
        (ok (new-game eny.input.ovum))
      ::  /draw: stock -> waste (recycle waste -> stock when stock empty)
      ?:  (route-is "/draw" uri-tape)
        =/  b=game
          ?~  stock.g
            g(stock (flop waste.g), waste ~, sel ~, moves +(moves.g))
          g(waste [i.stock.g waste.g], stock t.stock.g, sel ~, moves +(moves.g))
        (ok b)
      ::  /move?src=<loc>&i=<idx>&dst=<loc>: ATOMIC drag-and-drop move.
      ::  Parses both endpoints, validates + applies via try-move, re-renders.
      ::  The kernel is the sole authority; JS only carried the in-flight drag.
      ?:  (route-is "/move" uri-tape)
        =/  src-tape  (grab-key "src=" uri-tape)
        =/  spidx  (grab-num "src=tab" uri-tape)
        =/  sfidx  (grab-num "src=found" uri-tape)
        =/  idx  (grab-num "i=" uri-tape)
        =/  dst-tape  (grab-key "dst=" uri-tape)
        =/  dpidx  (grab-num "dst=tab" uri-tape)
        =/  dfidx  (grab-num "dst=found" uri-tape)
        =/  src=(unit loc)
          ?:  =("waste" src-tape)  `[%waste ~]
          ?:  =("tab" src-tape)    `[%tab spidx]
          ?:  =("found" src-tape)  `[%found sfidx]
          ~
        =/  dst=(unit loc)
          ?:  =("tab" dst-tape)    `[%tab dpidx]
          ?:  =("found" dst-tape)  `[%found dfidx]
          ~
        ?:  ?|(?=(~ src) ?=(~ dst))  (ok g(sel ~))
        ?:  =(u.src u.dst)  (ok g(sel ~))
        =/  run  (run-at g u.src idx)
        ?:  ?|(?=(~ run) !(legal-run run))  (ok g(sel ~))
        =/  moved  (try-move g u.src idx run u.dst)
        ?~  moved  (ok g(sel ~))                     ::  illegal: board unchanged
        (ok u.moved)
      ::  /sel?src=<loc>&i=<idx>: select a source card/run
      ?:  (route-is "/sel" uri-tape)
        =/  src-tape  (grab-key "src=" uri-tape)
        =/  idx  (grab-num "i=" uri-tape)
        =/  pidx  (grab-num "src=tab" uri-tape)
        =/  fidx  (grab-num "src=found" uri-tape)
        =/  loc=(unit loc)
          ?:  =("waste" src-tape)  `[%waste ~]
          ?:  =("tab" src-tape)    `[%tab pidx]
          ?:  =("found" src-tape)  `[%found fidx]
          ~
        ?~  loc  (ok g(sel ~))
        =/  run  (run-at g u.loc idx)
        ?:  ?|(?=(~ run) !(legal-run run))
          (ok g(sel ~))
        (ok g(sel `[u.loc idx]))
      ::  /to?dst=<loc>: attempt to move the selection
      ?:  (route-is "/to" uri-tape)
        ?~  sel.g  (ok g)
        =/  dst-tape  (grab-key "dst=" uri-tape)
        =/  dpidx  (grab-num "dst=tab" uri-tape)
        =/  dfidx  (grab-num "dst=found" uri-tape)
        =/  dst=(unit loc)
          ?:  =("tab" dst-tape)    `[%tab dpidx]
          ?:  =("found" dst-tape)  `[%found dfidx]
          ~
        ?~  dst  (ok g(sel ~))
        =/  src  src.u.sel.g
        =/  i    i.u.sel.g
        =/  run  (run-at g src i)
        ?:  ?=(~ run)  (ok g(sel ~))
        ?:  =(src u.dst)  (ok g(sel ~))
        =/  moved  (try-move g src i run u.dst)
        ?~  moved  (ok g(sel ~))
        (ok u.moved)
      ::  unknown POST
      [~[[%res id %404 ~ ~]] state]
    ==
  --
--
((moat |) inner)
