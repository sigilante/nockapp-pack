/+  *http
/=  *  /common/wrapper
=>
|%
::  +$ server-state: the only persistent state is the cumulative count of computations
::  (the SUMS metric). The current input/result are recomputed per request, not stored.
::
+$  server-state  [%0 sums=@ud]
::  +$ scheme: which letter-value system to use.
::
::    %ord = English ordinal: A=1, B=2, ... Z=26.
::    %eq  = English Qaballa (Lees / Liber Trigrammaton): value = 1-based position in the
::           sequence ALWHSDOZKVGRCNYJUFQBMXITEP. See en.wikipedia.org/wiki/English_Qaballa.
::
+$  scheme  ?(%ord %eq)
::  +eq-seq: the English Qaballa cipher order (lowercased). The EQ value of a letter is its
::  1-based index in this cord.
::
++  eq-seq  "alwhsdozkvgrcnyjufqbmxitep"
::  +lower: ASCII-lowercase one char (non-letters pass through unchanged).
::
++  lower
  |=  c=@t
  ^-  @t
  ?:  &((gte c 'A') (lte c 'Z'))  (add c 32)
  c
::  +letter-val: the value of a character under `s`.
::
::    Non-letters (spaces, digits, punctuation) -> 0, so they are skipped by every fold.
::    Case-insensitive. This is THE gematria primitive; everything else folds over it.
::
::    %ord: a/A -> 1, ... z/Z -> 26  ==  (letter - 'a' + 1).
::    %eq:  1-based position of the lowercased letter in eq-seq.
::
++  letter-val
  |=  [s=scheme c=@t]
  ^-  @ud
  =/  is-lo  &((gte c 'a') (lte c 'z'))
  =/  is-hi  &((gte c 'A') (lte c 'Z'))
  ?.  |(is-lo is-hi)  0
  =/  lc  (lower c)
  ?-  s
    %ord  +((sub lc 'a'))
    %eq   +((need (find ~[lc] eq-seq)))
  ==
::  +gematria: sum the letter values across a tape under `s`, skipping non-letters.
::
::    A straight fold: a non-letter contributes 0, so spaces and punctuation are skipped
::    for free. "abc" -> ord 6 / eq 34; "hello world" -> ord 124.
::
++  gematria
  |=  [s=scheme t=tape]
  ^-  @ud
  %+  roll  t
  |=  [c=@t acc=@ud]
  (add acc (letter-val s c))
::  +breakdown: per-letter "x=N" terms for the letters in `t` under `s` (skipping
::  non-letters), joined with spaces. "hi!" %ord -> "h=8 i=9".
::
++  breakdown
  |=  [s=scheme t=tape]
  ^-  tape
  =|  out=tape          ::  accumulated output, reversed segments welded forward
  =/  first  &          ::  are we emitting the first term (no leading space)?
  |-  ^-  tape
  ?~  t  out
  =/  v  (letter-val s i.t)
  ?:  =(0 v)  $(t t.t)  ::  skip non-letters
  =/  term  "{(trip (lower i.t))}={(scow %ud v)}"
  =/  seg  ?:(first term (weld " " term))
  $(t t.t, out (weld out seg), first |)
::  +route-is: does request uri `t` name route `pfx`? `find` returns a (unit @ud) (index of
::  the match), so a route matches when its literal sits at index 0.
::
++  route-is
  |=  [pfx=tape t=tape]
  ^-  ?
  =(`0 (find pfx t))
::  +from-hex: a single hex digit char -> (unit @), else ~.
::
++  from-hex
  |=  c=@t
  ^-  (unit @)
  ?:  &((gte c '0') (lte c '9'))  `(sub c '0')
  ?:  &((gte c 'a') (lte c 'f'))  `(add 10 (sub c 'a'))
  ?:  &((gte c 'A') (lte c 'F'))  `(add 10 (sub c 'A'))
  ~
::  +decode: percent- + plus-decode one url-encoded value.
::
::    application/x-www-form-urlencoded: '+' means space, '%XX' is a byte. Anything malformed
::    is passed through literally. There is no de-purl in this stdlib, so we hand-roll it.
::
++  decode
  |=  t=tape
  ^-  tape
  ?~  t  ~
  ?:  =('+' i.t)  [' ' $(t t.t)]       ::  '+' -> space
  ?.  =('%' i.t)  [i.t $(t t.t)]
  ::  '%XX': need two hex digits
  ?~  t.t   [i.t ~]
  ?~  t.t.t  [i.t i.t.t ~]
  =/  hi  (from-hex i.t.t)
  ?~  hi  [i.t $(t t.t)]               ::  not hex -> pass '%' through
  =/  lo  (from-hex i.t.t.t)
  ?~  lo  [i.t $(t t.t)]
  =/  byte=@  (add (mul 16 u.hi) u.lo)
  [`@t`byte $(t t.t.t.t)]
::  +split: split a tape on a single delimiter char into a list of tapes.
::
++  split
  |=  [del=@t t=tape]
  ^-  (list tape)
  =|  cur=tape          ::  current field, reversed
  =|  acc=(list tape)   ::  finished fields, reversed
  |-  ^-  (list tape)
  ?~  t
    (flop [(flop cur) acc])
  ?:  =(del i.t)
    $(t t.t, cur ~, acc [(flop cur) acc])
  $(t t.t, cur [i.t cur])
::  +field: pull the decoded value of `key` from a url-encoded `key=val&...` blob.
::
::    Used for both the POST body and the query string. Returns ~ if the key is absent.
::    Stops the value at '&' (split handles that) and percent/plus-decodes it.
::
++  field
  |=  [key=tape blob=tape]
  ^-  (unit tape)
  =/  pairs=(list tape)  (split '&' blob)
  =/  want  (weld key "=")
  |-  ^-  (unit tape)
  ?~  pairs  ~
  =/  p  i.pairs
  ?:  =(want (scag (lent want) p))
    `(decode (slag (lent want) p))
  $(pairs t.pairs)
::  +grab-word: pull the submitted phrase from query string + body (query takes precedence,
::  then body). Both are url-encoded `w=...` blobs. Returns "" if absent in both.
::
++  grab-word
  |=  [uri=tape body=tape]
  ^-  tape
  =/  q
    ::  drop everything up to and including the first '?', if any
    =/  i  (find "?" uri)
    ?~  i  uri
    (slag +(u.i) uri)
  =/  fromq  (field "w" q)
  ?^  fromq  u.fromq
  =/  fromb  (field "w" body)
  ?^  fromb  u.fromb
  ""
::  +esc: minimal HTML-escape for echoing user input safely into the page.
::
++  esc
  |=  t=tape
  ^-  tape
  ?~  t  ~
  =/  c  i.t
  =/  rep
    ?:  =('&' c)  "&amp;"
    ?:  =('<' c)  "&lt;"
    ?:  =('>' c)  "&gt;"
    ?:  =('"' c)  "&quot;"
    (trip c)
  (weld rep $(t t.t))
::  +css: the page stylesheet. A '''-block cord is LITERAL (no { } tape interpolation), so
::  CSS braces are safe here -- unlike "..." tapes.
::
++  css
  ^-  tape
  %-  trip
  '''
  body{font-family:system-ui,monospace;background:#1e1e2e;color:#cdd6f4;text-align:center;padding:1em}
  h1{margin-bottom:0}
  p{color:#bac2de}
  .word{font-size:22px;color:#f9e2af;margin:0.4em 0}
  .scheme{margin:1em auto;max-width:44em}
  .label{font-size:16px;color:#bac2de;letter-spacing:1px}
  .total{font-size:40px;font-weight:bold;color:#a6e3a1;margin:0.1em 0}
  .breakdown{margin:0.2em auto;max-width:44em;color:#89b4fa;font-size:15px;word-break:break-word}
  form{margin:1.4em 0}
  input{font-size:22px;padding:8px 12px;width:16em;text-align:center;border:2px solid #585b70;background:#181825;color:#cdd6f4;border-radius:6px}
  button{font-size:18px;padding:9px 18px;margin-left:6px;cursor:pointer;border:0;border-radius:6px;background:#a6e3a1;color:#1e1e2e;font-weight:bold}
  .note{margin-top:1.6em;color:#7f849c;font-size:14px}
  '''
::  +scheme-html: render one labeled scheme block (label, total, per-letter breakdown).
::
++  scheme-html
  |=  [label=tape s=scheme word=tape]
  ^-  tape
  =/  brk  (breakdown s word)
  ;:  weld
    "<div class=\"scheme\">"
    "<div class=\"label\">{label}</div>"
    "<div class=\"total\">{(scow %ud (gematria s word))}</div>"
    ?~  brk  "<div class=\"breakdown\">(no letters)</div>"
    "<div class=\"breakdown\">{brk}</div>"
    "</div>"
  ==
::  +render: full HTML page. `word` is the (already-decoded) submitted phrase; `shown` is
::  whether the result blocks should appear (false on first GET). Both schemes are shown.
::
++  render
  |=  [word=tape shown=?]
  ^-  (unit octs)
  =/  result=tape
    ?.  shown  ""
    ;:  weld
      "<div class=\"word\">{(esc word)}</div>"
      (scheme-html "English ordinal" %ord word)
      (scheme-html "English Qaballa" %eq word)
    ==
  =/  doc=tape
    ;:  weld
      "<!doctype html><html><head><meta charset=\"utf-8\">"
      "<title>gematria</title><style>"
      css
      "</style></head><body>"
      "<h1>NockApp Gematria</h1>"
      "<p>Letter sums under two schemes: English ordinal (A=1 ... Z=26) and English Qaballa (the ALWHSDOZKVGRCNYJUFQBMXITEP cipher). Spaces and other non-letters are skipped. All logic runs in the Hoon kernel.</p>"
      "<form method=\"POST\" action=\"/sum\">"
      "<input name=\"w\" autocomplete=\"off\" autofocus placeholder=\"word or phrase\" value=\"{(esc word)}\">"
      "<button type=\"submit\">Sum</button></form>"
      result
      "<p class=\"note\">e.g. \"abc\" = ordinal 6, EQ 34; \"hello world\" = ordinal 124</p>"
      "</body></html>"
    ==
  (to-octs (crip doc))
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
    ?+    method  [~[[%res id %400 ~ ~]] state]
        %'GET'
      ::  landing page: no result block, just the form.
      ~>  %slog.[0 leaf+"metric: sums={<sums.state>}"]
      [~[[%res id %200 ['content-type' 'text/html']~ (render "" |)]] state]
    ::
        %'POST'
      =/  uri-tape  (trip uri)
      ?.  (route-is "/sum" uri-tape)
        ::  unknown POST route
        [~[[%res id %404 ~ ~]] state]
      =/  body-tape  ?~(body "" (trip q.u.body))
      =/  word   (grab-word uri-tape body-tape)
      =/  ord    (gematria %ord word)
      =/  eq     (gematria %eq word)
      =/  next   +(sums.state)
      ~>  %slog.[0 leaf+"metric: sums={<next>} ord={<ord>} eq={<eq>}"]
      :_  state(sums next)
      ~[[%res id %200 ['content-type' 'text/html']~ (render word &)]]
    ==
  --
--
((moat |) inner)
