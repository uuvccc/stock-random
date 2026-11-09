# -*- coding: utf-8 -*-
"""
随机 A 股行情 Flask 服务
- 启动时一次性加载全 A 股代码/名称到内存
- /api/random-five 随机抽取 5 只，获取实时行情
- host=0.0.0.0:8080，局域网可访问
"""
import random
import logging
import math
from concurrent.futures import ThreadPoolExecutor, as_completed

import akshare as ak
import pandas as pd
from flask import Flask, jsonify, render_template, request

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
# 实时行情抓取：逐只调用 stock_bid_ask_em（单只约 0.1s），5 只并发
# 全市场接口 stock_zh_a_spot_em 实测要一分钟级，不适合每次请求都调
# ---------------------------------------------------------------------------
_quote_item_map = {
    # 统一字段名 -> stock_bid_ask_em 返回的 item 名
    "最新价": "最新",
    "涨跌幅": "涨幅",
    "成交量": "总手",
    "换手率": "换手",
}

_QUOTE_TIMEOUT = 10.0  # 单只请求软超时（秒），防止某只卡死拖垮整个请求


def _to_float(v) -> float | None:
    try:
        return float(v) if v is not None and pd.notna(v) else None
    except (TypeError, ValueError):
        return None


def _fetch_one_quote(code: str) -> dict | None:
    """拉单只个股实时行情，返回统一字段；失败返回 None。"""
    try:
        df = ak.stock_bid_ask_em(symbol=code)
        if df is None or df.empty:
            return None
        kv = dict(zip(df["item"], df["value"]))
        item = {"代码": code}
        for field, key in _quote_item_map.items():
            item[field] = _to_float(kv.get(key))
        return item
    except Exception as exc:
        log.warning("个股行情获取失败 %s: %s", code, exc)
        return None


def fetch_realtime_quotes(codes: list[str]) -> dict[str, dict]:
    """
    返回 {code: {代码, 名称, 最新价, 涨跌幅, 成交量, 换手率}}
    获取失败的个股直接不出现。
    """
    result: dict[str, dict] = {}
    workers = max(1, min(5, len(codes)))
    pool = ThreadPoolExecutor(max_workers=workers)
    futures = {pool.submit(_fetch_one_quote, c): c for c in codes}
    try:
        for fut in as_completed(futures, timeout=_QUOTE_TIMEOUT):
            code = futures[fut]
            try:
                item = fut.result()
            except Exception as exc:
                log.warning("个股行情异常 %s: %s", code, exc)
                continue
            if item is None:
                continue
            # 名称从 ALL_STOCKS 缓存补
            item["名称"] = next((n for c, n in ALL_STOCKS if c == code), "")
            result[code] = item
    except TimeoutError:
        log.warning("实时行情整体超时（%ds），已返回 %d 只", _QUOTE_TIMEOUT, len(result))
    finally:
        # 不等待卡住的线程，立即返回已拿到的结果
        pool.shutdown(wait=False, cancel_futures=True)

    log.info("实时行情获取完成，命中 %d / 请求 %d", len(result), len(codes))
    return result


# ---------------------------------------------------------------------------
# 评分：换手率（健康区间） + 成交量（绝对值，单位：手）
# 综合分 = 换手率 70% + 成交量 30%；星级由综合分映射
# ---------------------------------------------------------------------------
_TURNOVER_CURVE = [
    (0.0, 10.0),   # 几乎没换手
    (0.5, 30.0),
    (1.0, 45.0),
    (2.0, 65.0),
    (3.0, 80.0),
    (5.0, 95.0),
    (8.0, 100.0),  # 活跃但不极端
    (15.0, 70.0),  # 偏过热
    (25.0, 45.0),
    (40.0, 20.0),  # 极端换手
]

# 成交量按对数刻度映射（1 手 = 100 股）：
# 5000 手 20 分、1 万手 35 分、5 万手 60 分、20 万手 80 分、100 万手 95 分
_VOLUME_CURVE = [
    (1e3, 0.0),
    (5e3, 20.0),
    (1e4, 35.0),
    (5e4, 60.0),
    (2e5, 80.0),
    (1e6, 95.0),
    (3e6, 100.0),
]

_STAR_LEVELS = [
    (85.0, 5, "极热"),
    (70.0, 4, "活跃"),
    (55.0, 3, "温和"),
    (40.0, 2, "平淡"),
    (0.0, 1, "冷清"),
]


def _interp(x: float, points: list[tuple[float, float]]) -> float:
    """分段线性插值，超出两端时取端点值。"""
    if x <= points[0][0]:
        return points[0][1]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return points[-1][1]


def _turnover_score(turnover: float | None) -> float | None:
    """换手率 0-100 分：3%~8% 为健康活跃区间，过低或过高都扣分。"""
    if turnover is None or turnover < 0:
        return None
    return _interp(float(turnover), _TURNOVER_CURVE)


def _volume_score(volume: float | None) -> float | None:
    """成交量 0-100 分：按手数取对数映射，量越大分越高。"""
    if volume is None or volume < 0:
        return None
    if volume == 0:
        return 0.0
    curve = [(math.log10(x), y) for x, y in _VOLUME_CURVE]
    return _interp(math.log10(volume), curve)


def score_stocks(stocks: list[dict]) -> None:
    """就地写入 成交量评分 / 换手率评分 / 综合评分 / 星级 / 评级。"""
    for stock in stocks:
        vol_score = _volume_score(stock.get("成交量"))
        turn_score = _turnover_score(stock.get("换手率"))
        stock["成交量评分"] = round(vol_score) if vol_score is not None else None
        stock["换手率评分"] = round(turn_score) if turn_score is not None else None

        parts = []
        if turn_score is not None:
            parts.append((turn_score, 0.7))
        if vol_score is not None:
            parts.append((vol_score, 0.3))

        if not parts:
            stock["综合评分"] = None
            stock["星级"] = None
            stock["评级"] = "无数据"
            continue

        # 缺失某项时按剩余权重归一化
        total_weight = sum(w for _, w in parts)
        score = sum(v * w for v, w in parts) / total_weight
        stock["综合评分"] = round(score)

        for threshold, stars, label in _STAR_LEVELS:
            if score >= threshold:
                stock["星级"] = stars
                stock["评级"] = label
                break


# ---------------------------------------------------------------------------
# 建议：仅供学习参考的简化规则 —— 综合评分 × 涨跌幅
# 买入：综合评分 ≥ 75（活跃/极热）且 涨跌幅 ≥ 0
# 卖出：涨跌幅 < -2（弱势），或 综合评分 < 35（冷清）
# 不动：其他
# ---------------------------------------------------------------------------
def advice_stocks(stocks: list[dict]) -> None:
    """就地写入 建议 / 建议原因。"""
    for s in stocks:
        score = s.get("综合评分")
        pct = s.get("涨跌幅")
        has_data = score is not None and pct is not None

        if not has_data:
            s["建议"] = "—"
            s["建议原因"] = "行情数据不全"
            continue

        if score >= 75 and pct >= 0:
            s["建议"] = "买入"
            s["建议原因"] = f"{score}分·活跃且上涨"
        elif pct < -2:
            s["建议"] = "卖出"
            s["建议原因"] = f"跌{pct:.1f}%·弱势"
        elif score < 35:
            s["建议"] = "卖出"
            s["建议原因"] = f"{score}分·冷清"
        else:
            s["建议"] = "不动"
            s["建议原因"] = f"{score}分·温和"


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

    # 1) 先从收藏里挑（前端传 ?favorites=code1,code2,...），上限 5 只
    favs_raw = request.args.get("favorites", "")
    fav_codes: list[str] = []
    if favs_raw:
        known = {c for c, _ in ALL_STOCKS}
        for c in favs_raw.split(","):
            if len(fav_codes) >= 5:
                break
            c = c.strip()
            if c and c in known and c not in fav_codes:
                fav_codes.append(c)

    # 2) 剩余名额随机补足
    need = max(0, 5 - len(fav_codes))
    picks: list[tuple[str, str]] = []
    if fav_codes:
        fav_map = {c: n for c, n in ALL_STOCKS if c in fav_codes}
        for c in fav_codes:
            picks.append((c, fav_map[c]))

    if need > 0:
        # 排除已在收藏里的
        pool = [(c, n) for c, n in ALL_STOCKS if c not in fav_codes]
        extra = random.sample(pool, min(need, len(pool))) if pool else []
        picks.extend(extra)

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

    score_stocks(stocks_out)
    advice_stocks(stocks_out)

    ok_count = sum(1 for s in stocks_out if s["最新价"] is not None)
    return jsonify({
        "ok": True,
        "requested": 5,
        "fetched": ok_count,
        "favorites": fav_codes,
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
