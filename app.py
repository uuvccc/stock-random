# -*- coding: utf-8 -*-
"""
随机 A 股行情 Flask 服务
- 启动时一次性加载全 A 股代码/名称到内存
- /api/random-five 随机抽取 5 只，获取实时行情
- host=0.0.0.0:8080，局域网可访问
"""
import random
import logging

import akshare as ak
import pandas as pd
from flask import Flask, jsonify, render_template

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

app = Flask(__name__)

# ---------------------------------------------------------------------------
# 内存缓存：全 A 股列表 [(code, name), ...]，启动时加载一次
# ---------------------------------------------------------------------------
ALL_STOCKS: list[tuple[str, str]] = []


def load_all_stocks() -> list[tuple[str, str]]:
    """启动时拉取全部 A 股代码、名称。失败则返回空列表，不崩溃。"""
    try:
        df = ak.stock_info_a_code_name()
        if df is None or df.empty:
            log.warning("ak.stock_info_a_code_name() 返回空 DataFrame")
            return []

        # 字段名根据 akshare 版本可能略有差异，兼容两种常见命名
        col_code = "code" if "code" in df.columns else "代码"
        col_name = "name" if "name" in df.columns else "名称"

        stocks: list[tuple[str, str]] = []
        for _, row in df.iterrows():
            code = str(row[col_code]).strip()
            name = str(row[col_name]).strip()
            if code and name:
                stocks.append((code, name))

        log.info("加载全 A 股列表成功，共 %d 只", len(stocks))
        return stocks

    except Exception as exc:
        log.exception("加载全 A 股列表失败: %s", exc)
        return []


# ---------------------------------------------------------------------------
# 实时行情抓取：一次性拉取东方财富全市场实时行情，再按代码筛选
# （批量拉比逐只请求稳得多，也省频率）
# ---------------------------------------------------------------------------
_realtime_columns_map = {
    # 统一字段名 -> akshare 可能的列名（按优先级）
    "代码": ["代码", "symbol", "code"],
    "最新价": ["最新价", "current", "现价"],
    "涨跌幅": ["涨跌幅", "changepercent", "涨跌幅(%)"],
    "成交量": ["成交量", "volume"],
    "换手率": ["换手率", "turnover", "换手率(%)"],
}


def _pick_col(df: pd.DataFrame, candidates: list[str]) -> str | None:
    for c in candidates:
        if c in df.columns:
            return c
    return None


def fetch_realtime_quotes(codes: list[str]) -> dict[str, dict]:
    """
    返回 {code: {代码, 名称, 最新价, 涨跌幅, 成交量, 换手率}}
    获取失败的个股直接不出现。
    """
    result: dict[str, dict] = {}
    try:
        df = ak.stock_zh_a_spot_em()
        if df is None or df.empty:
            log.warning("stock_zh_a_spot_em 返回空")
            return result

        col_code = _pick_col(df, _realtime_columns_map["代码"])
        col_price = _pick_col(df, _realtime_columns_map["最新价"])
        col_pct = _pick_col(df, _realtime_columns_map["涨跌幅"])
        col_vol = _pick_col(df, _realtime_columns_map["成交量"])
        col_turn = _pick_col(df, _realtime_columns_map["换手率"])

        if col_code is None:
            log.error("实时行情表找不到代码列，实际列: %s", list(df.columns))
            return result

        code_set = set(codes)
        for _, row in df.iterrows():
            try:
                code = str(row[col_code]).strip()
                if code not in code_set:
                    continue
                item = {"代码": code}
                if col_price is not None:
                    item["最新价"] = float(row[col_price]) if pd.notna(row[col_price]) else None
                if col_pct is not None:
                    item["涨跌幅"] = float(row[col_pct]) if pd.notna(row[col_pct]) else None
                if col_vol is not None:
                    item["成交量"] = float(row[col_vol]) if pd.notna(row[col_vol]) else None
                if col_turn is not None:
                    item["换手率"] = float(row[col_turn]) if pd.notna(row[col_turn]) else None
                # 名称从 ALL_STOCKS 缓存补，避免实时表列名差异
                name = next((n for c, n in ALL_STOCKS if c == code), "")
                item["名称"] = name
                result[code] = item
            except Exception as exc:
                log.warning("解析单行行情失败: %s", exc)
                continue

        log.info("实时行情获取完成，命中 %d / 请求 %d", len(result), len(codes))
    except Exception as exc:
        log.exception("获取实时行情异常: %s", exc)
    return result


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html")


@app.get("/api/random-five")
def api_random_five():
    if not ALL_STOCKS:
        return jsonify({"ok": False, "msg": "股票列表尚未加载完成，请稍后重试"}), 503

    # 随机抽 5 只（去重，不足 5 只则返回实际数量）
    sample_size = min(5, len(ALL_STOCKS))
    picks = random.sample(ALL_STOCKS, sample_size)
    codes = [c for c, _ in picks]

    quotes = fetch_realtime_quotes(codes)

    # 把没取到行情的也带上（仅代码名称），前端可区分
    stocks_out = []
    for code, name in picks:
        q = quotes.get(code)
        if q:
            stocks_out.append(q)
        else:
            stocks_out.append({
                "代码": code,
                "名称": name,
                "最新价": None,
                "涨跌幅": None,
                "成交量": None,
                "换手率": None,
            })

    ok_count = sum(1 for s in stocks_out if s["最新价"] is not None)
    return jsonify({
        "ok": True,
        "requested": 5,
        "fetched": ok_count,
        "stocks": stocks_out,
    })


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
def _warmup():
    global ALL_STOCKS
    ALL_STOCKS = load_all_stocks()


if __name__ == "__main__":
    _warmup()
    log.info("Flask 启动，监听 0.0.0.0:8080")
    app.run(host="0.0.0.0", port=8080, debug=False)
