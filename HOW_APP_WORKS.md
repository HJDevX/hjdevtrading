# How HJDev Trading Works (simple words)

_Last updated: 24 Nov 2026 — Dart-style variables inside signals_

## 1. App opens
- The app checks: "Was I logged in TODAY?" If yes, it takes you
  straight to the Watchlist. If no, you log in from the Login tab.

## 2. Login (under the More tab)
1. You saved three things once: Access Token, Mobile Number, UCC.
   They stay saved on the phone.
2. Every morning you type the 6-digit TOTP from the Kotak Neo app
   and press **Verify TOTP**.
3. Then you type your MPIN and press **Login**.
4. Kotak gives the app a "session" (like a one-day pass) plus two
   addresses: one for prices, one for the live index feed.
5. TOTP and MPIN are NEVER saved. The one-day pass is saved, so you
   don't log in again and again the same day.

## 3. The stock list (scrip master)
- Kotak publishes the full list of every stock, future, option and
  commodity every day. The app downloads it (cloud icon on the
  Watchlist tab) and saves it in the phone's local database.
- First open of a new day downloads it automatically.
- Search only finds things from this downloaded list. The app has
  NO stock names built into it.

## 4. Watchlist prices
- Stock/future/option prices come from Kotak's price API, one call
  for up to 50 items, refreshed every 3 seconds.
- NIFTY and SENSEX cannot come from that API (Kotak rejects them
  there), so they come from Kotak's live WebSocket feed — that is
  what the green "Live" dot means.

## 5. Paper trading (Orders + Portfolio tabs)
- On any watchlist row you can tap BUY (Paper) or SELL (Paper).
  The trade fills instantly at the live price and is saved in the
  phone's local database only. Nothing is sent to Kotak.
- **Orders** page: every paper trade, with booked profit/loss.
- **Portfolio** page: what you hold now, with live profit/loss and
  an EXIT button.

## 6. The look (24 Nov 2026)
- The whole app was reskinned to the Zerodha Kite theme: white
  background, Kite blue (#387ed1), grey text, thin divider lines,
  small corners, no shadows. Presentation only — nothing about
  how the app behaves changed.
- Bottom tabs are now **Watchlist / Orders / Portfolio / Signals /
  More**. Orders and Portfolio are the same two Practice pages as
  before, just opened straight from the bottom bar.
- **Funds** (the virtual fund) is no longer a main tab — it lives
  under **More**, together with the Replay Simulator and the
  Kotak Login.
- The **Signals** tab holds YOUR OWN signals, made in the Signal
  Builder (see §7). It is empty until you create one — the old
  Sign 01–04 reference cards are gone from this tab.

## 7. Signals — your own maths language (24 Nov 2026)
- A signal = one stock + one action (BUY or SELL, quantity,
  optional target % and stop-loss %).
- Inside a signal: **indicators**. Each indicator has a weight %.
  Weights are equal by default; raise or lower one and the others
  adjust equally, so the total is always 100%. A lock button
  protects an indicator's %.
- **Variables (Dart-style):** a signal can have named variables —
  give a name, a type and a value, e.g.
  `double stockCurrent = PRICE;`. The types mirror Dart:
  **int** (whole number), **double** (decimal number — Dart's
  name for what other languages call float), **String** (text),
  **bool** (TRUE/FALSE). A number variable's value is a
  calculation (PRICE, PCT_CHANGE(OPEN, PREV_CLOSE)…); a bool
  variable's value is a whole maths line; a String variable
  holds fixed text (not usable inside maths). Variable names
  can be used inside maths lines and inside other variables —
  a variable may use only the variables listed above it, so
  values never chase each other in a circle. A bool variable
  written alone as a line is a complete TRUE/FALSE line.
  Name and type are fixed after creation; values can be
  edited. A variable that is in use cannot be deleted.
- Inside an indicator: **maths lines**. Every line is
  LEFT maths + a compare sign + RIGHT maths, and its answer is
  TRUE or FALSE. Lines are written in the **Stock IDE**, a
  full-screen text editor (the only line editor):
  - Type the line as text, e.g.
    `PCT_CHANGE(OPEN, PREV_CLOSE) >= 0.7`. As you type a word,
    matching terms are suggested — tap one to insert it. Sign
    buttons add >=, ×, ÷ and brackets without hunting the
    keyboard, and example chips fill a starter line in one tap.
  - The **ℹ button** opens the all-terms page: every term in
    the language, grouped by type, with its full name — tap a
    term there to add it to your line. The same page lists the
    compare signs and what each one means.
  - The line is checked as you type; any mistake is explained
    in plain words. **Save rule: a line is saved only when its
    answer is TRUE or FALSE** — a complete line with a compare
    sign. Anything else is refused and stays on the page.
  The two sides must be the same type (price with price, time
  with time…) or one side a plain number — the editor checks
  this while you type and refuses a mixed line.
- Signals are saved as data in the phone's local database
  (DB v9, `signals` table) — never as app code. You can edit,
  delete and switch each signal on/off from the Signals tab.
- **Not live yet:** no engine watches the signals in this step,
  so creating or saving a signal places no trades. The live
  engine (calculate every line on the live price, fire at
  100%) is the next step.

## File map
- `main.dart` — app start + theme
- `screens/home_screen.dart` — bottom tabs (Watchlist/Orders/Portfolio/Signals/More)
- `screens/login/` — login screen (opened from More)
- `screens/watchlists/` — watchlist + search screens
- `screens/practice/` — orders + portfolio
- `screens/signals/` — your saved signals + the Signal Builder
- `screens/more/` — More tab: funds, simulator, login links
- `services/kotak_api.dart` — login, session, price API
- `services/scrip_master_service.dart` — daily stock-list download
- `services/index_feed_service.dart` — live NIFTY/SENSEX feed
- `services/paper_broker.dart` — paper buy/sell + holdings maths
- `db/app_db.dart` — local database (watchlists, stocks, paper trades, signals)
- `models/` — plain data classes
