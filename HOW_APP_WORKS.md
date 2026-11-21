# How HJDev Trading Works (simple words)

_Last updated: 21 Nov 2026 — full rewrite of lib_

## 1. App opens
- The app checks: "Was I logged in TODAY?" If yes, it takes you
  straight to the Watchlist. If no, you log in from the Login tab.

## 2. Login (Login tab)
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

## 5. Paper trading (Practice tab)
- On any watchlist row you can tap BUY (Paper) or SELL (Paper).
  The trade fills instantly at the live price and is saved in the
  phone's local database only. Nothing is sent to Kotak.
- **Orders** page: every paper trade, with booked profit/loss.
- **Portfolio** page: what you hold now, with live profit/loss and
  an EXIT button.

## File map
- `main.dart` — app start + theme
- `screens/home_screen.dart` — bottom tabs (Watchlist/Practice/Login)
- `screens/login/` — login screen
- `screens/watchlists/` — watchlist + search screens
- `screens/practice/` — orders + portfolio
- `services/kotak_api.dart` — login, session, price API
- `services/scrip_master_service.dart` — daily stock-list download
- `services/index_feed_service.dart` — live NIFTY/SENSEX feed
- `services/paper_broker.dart` — paper buy/sell + holdings maths
- `db/app_db.dart` — local database (watchlists, stocks, paper trades)
- `models/` — plain data classes
