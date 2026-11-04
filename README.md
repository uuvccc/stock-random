# stock-random

A small Flask web app that picks five A-share (Chinese stock market) tickers at random and shows their live quotes. It is meant for quick browsing and fun, not for trading decisions.

## Features

- Loads the full A-share code/name list once at startup and keeps it in memory
- `GET /api/random-five` samples five distinct tickers and returns live quotes
- Fetches quotes per ticker via `ak.stock_bid_ask_em` (~0.1s each), 5 in parallel with a thread pool, so one refresh takes about 0.1–0.2s
- Per-request hard timeout (10s): stuck fetches are dropped and partial results are returned immediately
- Graceful degradation: tickers with no available quote are still returned with empty fields, and a failed quote fetch never crashes the request
- Mobile-friendly single page UI with a "换一批" (refresh) button; price/change is colored red for gains and green for losses, following the Chinese market convention
- Each sampled ticker gets a volume/turnover score and a 1–5 star rating (`成交量评分`, `换手率评分`, `综合评分`, `星级`, `评级`)

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
      "成交量": 452300.0,
      "换手率": 1.62,
      "成交量评分": 88,
      "换手率评分": 57,
      "综合评分": 66,
      "星级": 3,
      "评级": "温和"
    }
  ]
}
```

- `requested` is always `5`; `fetched` is how many of them actually had a quote
- Fields may be `null` when the quote was unavailable for that ticker (`综合评分` / `星级` are `null` and `评级` is `无数据` when both inputs are missing)
- If the stock list has not been loaded yet, the endpoint returns HTTP 503 with `{"ok": false, "msg": "..."}`

### Scoring

Each ticker is rated on two metrics, then mapped to 1–5 stars:

- **换手率评分 (0–100, weight 70%)** — piecewise curve peaking at 3%–8% turnover; very low turnover (illiquid) and extreme turnover (>15%, overheated) both lose points
- **成交量评分 (0–100, weight 30%)** — log-scaled by volume in lots (`手`, 1 lot = 100 shares); 1万手 ≈ 35, 5万手 ≈ 60, 20万手 ≈ 80, 100万手+ ≈ 95+
- **综合评分** = 0.7 × turnover score + 0.3 × volume score (weights renormalized if one value is missing)
- **星级**: ≥85 → 5★ 极热, ≥70 → 4★ 活跃, ≥55 → 3★ 温和, ≥40 → 2★ 平淡, else 1★ 冷清

## Project structure

```
stock-random/
├── app.py              # Flask app: stock list cache, quote fetching, routes
└── templates/
    └── index.html      # Single-page UI (vanilla JS, no build step)
```

Key pieces in [app.py](app.py):

- `load_all_stocks()` — builds the in-memory `(code, name)` list at startup
- `fetch_realtime_quotes()` — fetches each sampled ticker via `stock_bid_ask_em` in parallel threads, with a 10s overall timeout
- `api_random_five()` — sampling plus response assembly

## Notes

- Column names returned by `akshare` vary between versions; the code maps several common aliases (e.g. `代码` / `symbol` / `code`) to stay compatible.
- Data source is East Money and may be delayed or temporarily unavailable. Quotes are not guaranteed to be real-time.
- For learning and personal use only. Nothing here is financial advice.

## Troubleshooting

- **Page says "网络异常，请检查后端是否启动"** — the Flask server is not running or the browser cannot reach it.
- **API returns 503** — the A-share list failed to load at startup. Check the console log and your network access to East Money, then restart.
- **All quotes are `null`** — the real-time endpoint failed or was rate limited; click "换一批" to retry later.
