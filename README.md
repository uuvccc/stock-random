# stock-random

A small Flask web app that picks five A-share (Chinese stock market) tickers at random and shows their live quotes. It is meant for quick browsing and fun, not for trading decisions.

## Features

- Loads the full A-share code/name list once at startup and keeps it in memory
- `GET /api/random-five` samples five distinct tickers and returns live quotes
- Fetches all-market real-time data from East Money (via `akshare`) in a single batch instead of one request per ticker — faster and much less likely to be rate limited
- Graceful degradation: tickers with no available quote are still returned with empty fields, and a failed quote fetch never crashes the request
- Mobile-friendly single page UI with a "换一批" (refresh) button; price/change is colored red for gains and green for losses, following the Chinese market convention

## Tech stack

- Python 3.10+ (`str | None` and built-in generic type hints are used)
- [Flask](https://flask.palletsprojects.com/)
- [akshare](https://akshare.akfamily.xyz/) — A-share data source
- pandas

## Getting started

Install dependencies:

```bash
pip install flask akshare pandas
```

Start the server:

```bash
python app.py
```

Then open <http://localhost:8080>. The server binds to `0.0.0.0:8080`, so other devices on the same LAN can reach it via `http://<your-ip>:8080`.

On startup the app pulls the full A-share list, which can take a few seconds. If that request fails, the app still starts but the API returns HTTP 503 until a successful load (restart the process to retry).

## API

### `GET /`

Serves the web UI.

### `GET /api/random-five`

Returns five randomly sampled tickers with live quotes.

```json
{
  "ok": true,
  "requested": 5,
  "fetched": 4,
  "stocks": [
    {
      "代码": "600000",
      "名称": "浦发银行",
      "最新价": 7.21,
      "涨跌幅": 1.26,
      "成交量": 32541200.0,
      "换手率": 0.41
    }
  ]
}
```

- `requested` is always `5`; `fetched` is how many of them actually had a quote
- Fields may be `null` when the quote was unavailable for that ticker
- If the stock list has not been loaded yet, the endpoint returns HTTP 503 with `{"ok": false, "msg": "..."}`

## Project structure

```
stock-random/
├── app.py              # Flask app: stock list cache, quote fetching, routes
└── templates/
    └── index.html      # Single-page UI (vanilla JS, no build step)
```

Key pieces in [app.py](app.py):

- `load_all_stocks()` — builds the in-memory `(code, name)` list at startup
- `fetch_realtime_quotes()` — one-shot all-market quote fetch, filtered down to the sampled codes
- `api_random_five()` — sampling plus response assembly

## Notes

- Column names returned by `akshare` vary between versions; the code maps several common aliases (e.g. `代码` / `symbol` / `code`) to stay compatible.
- Data source is East Money and may be delayed or temporarily unavailable. Quotes are not guaranteed to be real-time.
- For learning and personal use only. Nothing here is financial advice.

## Troubleshooting

- **Page says "网络异常，请检查后端是否启动"** — the Flask server is not running or the browser cannot reach it.
- **API returns 503** — the A-share list failed to load at startup. Check the console log and your network access to East Money, then restart.
- **All quotes are `null`** — the real-time endpoint failed or was rate limited; click "换一批" to retry later.
