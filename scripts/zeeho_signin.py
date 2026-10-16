#!/usr/bin/env python3
"""极核每日签到。

流程对齐 https://github.com/MonicaGmm/zeeho-quanx 的 zeeho_checkin.js：
  GET baseInfo → GET /H5/signin（看 lastTime 是否今天）→ 未签则 POST /H5/signin
  → 再 GET /H5/signin 回查 lastTime（不信任 POST 的 code）。
  2026-10-11 起签到接口迁到 /cfmotoservermine/H5/，并换发 H5 appId；
  旧路径或旧 appId 会被网关拦成 30125 permit error。车辆接口仍走原生 tapi 密钥。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import ssl
import sys
import time
import uuid
from datetime import datetime
from http.cookiejar import CookieJar
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPSHandler, Request, build_opener, HTTPCookieProcessor

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "config" / "local.json"
LOG_DIR = ROOT / "logs"
LOG_DIR.mkdir(exist_ok=True)
WIDGET_DIR = Path.home() / "Library/Application Support/ZeehoSignin"
WIDGET_STATUS = WIDGET_DIR / "status.json"

UA = (
    "Mozilla/5.0 (Linux; Android 9; SM-G9500 Build/PPR1.180610.011; wv) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.125 "
    "Mobile Safari/537.36 Zeeho/3.0.4 (samsung SM-G9500 Build/9)"
)
ZEEHO_UA = (
    "MOBILE|Android|9|ZEEHO_APP|3.0.4|samsung SM-G9500|360*740|"
    "34cd9884-8171-41e8-a965-b10d042cae4f|4g|AndroidOS"
)
OK_CODES = {"10000", "0", "200"}
RETRY = 2
TAPI_VEHICLE = "https://tapi.zeehoev.com/v1.0/app/cfmotoserverapp/vehicleHomePage/"
# 2026-10-10 服务端换发的 H5 通道密钥（与原生 tapi 的 app_id 不是同一套）
H5_APP_ID = "AiTXmBrm"
H5_APP_SECRET = "70c2c7458ab88ca9504ad0521f170075bc91f2f7"
H5_SIGNIN = "/cfmotoservermine/H5/signin"
H5_SIGNIN_INFO = "/cfmotoservermine/H5/signin/info"
TOKEN_UUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


def log(msg: str) -> None:
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line)
    with (LOG_DIR / "signin.log").open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def load_config() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"缺少配置: {CONFIG_PATH}")
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def normalize_token(raw: str) -> str:
    text = (raw or "").strip().strip('"').strip("'")
    if text.lower().startswith("bearer "):
        text = text[7:].strip()
    found = TOKEN_UUID.search(text)
    if found:
        return found.group(0)
    if "token=" in text.lower():
        for part in re.split(r"[&?]", text):
            if part.lower().startswith("token="):
                return normalize_token(part.split("=", 1)[1])
    return text


def save_token(raw: str, extra: dict[str, Any] | None = None) -> str:
    token = normalize_token(raw)
    if not token:
        raise SystemExit("Token 为空")
    if not CONFIG_PATH.exists():
        raise SystemExit(f"缺少配置: {CONFIG_PATH}")
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    cfg["token"] = token
    tokens = cfg.get("tokens")
    if isinstance(tokens, list) and tokens:
        cfg["tokens"][0] = token
    elif isinstance(tokens, list):
        cfg["tokens"] = [token]
    if extra:
        cfg.update(extra)
    CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    log("已写入新 Token 到 config/local.json")
    return token


def emit_result(ok: bool, message: str) -> int:
    line = "RESULT " + json.dumps({"ok": ok, "message": message}, ensure_ascii=False)
    print(line, flush=True)
    print(line, file=sys.stderr, flush=True)
    return 0 if ok else 1


def load_tokens(cfg: dict[str, Any]) -> list[str]:
    raw = cfg.get("tokens") or cfg.get("token") or ""
    if isinstance(raw, list):
        items = raw
    else:
        items = str(raw).replace(",", "\n").splitlines()
    return [str(x).strip() for x in items if str(x).strip()]


def cfmoto_sign(app_id: str, app_secret: str, query: str, body: str) -> tuple[str, str]:
    nonce = str(uuid.uuid4())
    ts = str(int(time.time() * 1000))
    raw = f"{query}{body}appId={app_id}&nonce={nonce}&timestamp={ts}{app_secret}"
    digest = hashlib.md5(hashlib.sha1(raw.encode()).hexdigest().encode()).hexdigest()
    param = f"appId={app_id}&nonce={nonce}&timestamp={ts}"
    return digest, param


def is_ok(json_body: Any) -> bool:
    if not isinstance(json_body, dict):
        return False
    code = json_body.get("code", json_body.get("status"))
    return str(code) in OK_CODES


def write_widget_status(payload: dict[str, Any]) -> None:
    WIDGET_DIR.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    WIDGET_STATUS.write_text(text, encoding="utf-8")
    (LOG_DIR / "widget.json").write_text(text, encoding="utf-8")
    log(f"已写小组件状态 {WIDGET_STATUS}")


class Client:
    def __init__(self, cfg: dict[str, Any]) -> None:
        self.cfg = cfg
        self.jar = CookieJar()
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        self.opener = build_opener(HTTPCookieProcessor(self.jar), HTTPSHandler(context=ctx))

    def h5_creds(self) -> tuple[str, str]:
        return (
            str(self.cfg.get("h5_app_id") or H5_APP_ID),
            str(self.cfg.get("h5_app_secret") or H5_APP_SECRET),
        )

    def _headers(self, token: str, query: str, body: str) -> dict[str, str]:
        app_id, secret = self.h5_creds()
        sign, param = cfmoto_sign(app_id, secret, query, body)
        return {
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "User-Agent": UA,
            "Zeeho-User-Agent": ZEEHO_UA,
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json;charset=UTF-8",
            "Cfmoto-X-Sign": sign,
            "Cfmoto-X-Sign-Type": "0",
            "Cfmoto-X-Param": param,
            "Referer": f"{self.cfg['base_url']}/activity/signin",
            "Origin": self.cfg["base_url"],
        }

    def request(self, method: str, path: str, token: str, params: dict[str, str] | None = None) -> dict[str, Any]:
        query = urlencode(params or {}, doseq=True)
        body = "" if method in {"GET", "DELETE"} else ""
        url = self.cfg["base_url"] + path
        if query:
            url = f"{url}?{query}"
        data = None if method in {"GET", "DELETE"} else body.encode("utf-8")
        req = Request(url, data=data, headers=self._headers(token, query, body), method=method)
        try:
            with self.opener.open(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                status = resp.status
        except HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            status = e.code
            log(f"HTTP {status} {method} {path} {raw[:500]}")
        except URLError as e:
            log(f"网络错误 {method} {path}: {e}")
            return {"status": 0, "json": None, "raw": "", "err": str(e)}
        log(f"{method} {path}{'?' + query if query else ''} -> {status} {raw[:800]}")
        try:
            parsed = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            parsed = None
        return {"status": status, "json": parsed, "raw": raw}

    def request_retry(self, method: str, path: str, token: str, params: dict[str, str] | None = None) -> dict[str, Any]:
        last: dict[str, Any] = {"status": 0, "json": None, "raw": ""}
        for attempt in range(RETRY + 1):
            last = self.request(method, path, token, params)
            bad = last["status"] == 0 or last["status"] >= 500 or last["json"] is None
            if not bad:
                return last
            if attempt < RETRY:
                log(f"第 {attempt + 1} 次重试 {method} {path}…")
                time.sleep(1.5)
        return last

    def warmup(self) -> None:
        url = f"{self.cfg['base_url']}/activity/signin"
        req = Request(url, headers={"User-Agent": UA})
        try:
            with self.opener.open(req, timeout=30) as resp:
                resp.read()
            log(f"warmup {url} ok cookies={[c.name for c in self.jar]}")
        except Exception as e:
            log(f"warmup 失败（继续）: {e}")

    def tapi_get(self, url: str, token: str) -> dict[str, Any]:
        return self.tapi_request("GET", url, token=token)

    def tapi_request(
        self,
        method: str,
        url: str,
        token: str | None = None,
        json_body: dict[str, Any] | None = None,
        authorization: str | None = None,
    ) -> dict[str, Any]:
        nonce = uuid.uuid4().hex[:16] + str(int(time.time() * 1000))
        ts = str(int(time.time() * 1000))
        app_id = self.cfg["app_id"]
        secret = self.cfg["app_secret"]
        param = f"appId={app_id}&nonce={nonce}&timestamp={ts}"
        parsed = urlsplit(url)
        pre = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
        if parsed.query:
            pairs = sorted(
                (tuple(x.split("=", 1)) if "=" in x else (x, ""))
                for x in parsed.query.split("&")
            )
            pre += "?" + "&".join(f"{k}={quote(v, safe='~')}" for k, v in pairs)
        # 原生拦截器：签名不含 body（与 MX10085 HA 集成一致）
        pre += param + secret
        sig = hashlib.md5(hashlib.sha1(pre.encode()).hexdigest().encode()).hexdigest()
        headers = {
            "appId": app_id,
            "nonce": nonce,
            "timestamp": ts,
            "signature": sig,
            "Cfmoto-X-Param": param,
            "Cfmoto-X-Sign": sig,
            "Cfmoto-X-Sign-Type": "0",
            "Content-Type": "application/json; charset=UTF-8",
            "User-Agent": "okhttp/4.9.2",
            "Accept": "*/*",
        }
        if authorization:
            headers["Authorization"] = authorization
        elif token:
            headers["Authorization"] = f"Bearer {token}"
        data = None
        if method not in {"GET", "DELETE"} and json_body is not None:
            data = json.dumps(json_body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        req = Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                status = resp.status
        except HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            status = e.code
            log(f"HTTP {status} {method} {urlsplit(url).path} {raw[:240]}")
        except URLError as e:
            log(f"网络错误 {method} {url}: {e}")
            return {"status": 0, "json": None, "raw": "", "err": str(e)}
        try:
            parsed_json = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            parsed_json = None
        return {"status": status, "json": parsed_json, "raw": raw}


def _num(value: Any) -> float | None:
    if value in (None, "", "--"):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_vehicle(payload: Any) -> dict[str, Any] | None:
    if not isinstance(payload, dict) or not is_ok(payload):
        return None
    data = payload.get("data")
    if isinstance(data, list):
        vehicle = data[0] if data else None
    else:
        vehicle = data
    if not isinstance(vehicle, dict):
        return None
    lock = str(vehicle.get("headLockState") or "")
    charge = str(vehicle.get("chargeState") or "")
    loc = vehicle.get("location") if isinstance(vehicle.get("location"), dict) else {}
    battery = _num(vehicle.get("bmssoc"))
    range_km = _num(vehicle.get("hmiRidableMile"))
    mileage = _num(vehicle.get("totalRideMile"))
    return {
        "vehicleName": vehicle.get("vehicleName") or vehicle.get("vehicleType") or "",
        "vehiclePicUrl": vehicle.get("vehiclePicUrl") or "",
        "battery": int(battery) if battery is not None else None,
        "rangeKm": int(range_km) if range_km is not None else None,
        "mileageKm": mileage,
        "lockText": "已锁" if lock == "1" else "未锁" if lock == "0" else "未知",
        "chargeText": "充电中" if charge == "1" else "未充电" if charge == "0" else "未知",
        "rideState": vehicle.get("rideState") or vehicle.get("onlineStatus") or "",
        "signal": vehicle.get("gsmRxLevValue") or "",
        "locationTime": str(loc.get("locationTime") or "").strip(),
    }


def fetch_vehicle(client: Client, token: str) -> dict[str, Any] | None:
    last: dict[str, Any] = {"json": None}
    for attempt in range(RETRY + 1):
        last = client.tapi_get(TAPI_VEHICLE, token)
        if last.get("json") is not None and last.get("status", 0) < 500:
            break
        if attempt < RETRY:
            time.sleep(1.5)
    parsed = parse_vehicle(last.get("json"))
    if parsed:
        log(
            f"车辆 {parsed.get('vehicleName')} 电量{parsed.get('battery')}% "
            f"续航{parsed.get('rangeKm')}km 里程{parsed.get('mileageKm')} "
            f"{parsed.get('lockText')} {parsed.get('rideState')}"
        )
    else:
        log("车辆主页未取到有效数据")
    return parsed


def run_one(client: Client, token: str, idx: int, today: str, status_only: bool, force: bool) -> dict[str, Any]:
    tag = f"账号{idx + 1}"
    result: dict[str, Any] = {
        "tag": tag,
        "ok": False,
        "dup": False,
        "tokenInvalid": False,
        "msg": "",
        "nickName": "",
        "avatar": "",
        "userId": "",
        "phone": "",
        "lastTime": None,
        "continueDays": None,
        "integral": None,
        "totalIntegral": None,
        "signedToday": False,
        "posted": False,
    }

    r1 = client.request_retry("GET", "/cfmotoservermine/baseInfo", token)
    if r1["json"] is None:
        result["msg"] = f"请求发不出去 HTTP {r1['status']}" + (f"（{r1.get('err')}）" if r1.get("err") else "")
        return result
    if r1["status"] in {401, 403} or (
        isinstance(r1["json"], dict) and r1["json"].get("error") == "invalid_token"
    ):
        result["tokenInvalid"] = True
        result["msg"] = "Token 失效，请从 App 抓包后粘贴 Authorization"
        return result
    if is_ok(r1["json"]):
        data = r1["json"].get("data") or {}
        result["nickName"] = data.get("nickName") or ""
        result["avatar"] = data.get("avatar") or ""
        result["userId"] = str(data.get("id") or "")
        result["phone"] = str(data.get("phone") or "")
        if result["nickName"]:
            result["tag"] = f"账号{idx + 1}({result['nickName']})"

    r2 = client.request_retry("GET", H5_SIGNIN, token)
    if r2["status"] in {401, 403}:
        result["tokenInvalid"] = True
        result["msg"] = "Token 失效，请从 App 抓包后粘贴 Authorization"
        return result
    if is_ok(r2["json"]):
        summary = r2["json"].get("data") or {}
        last = summary.get("lastTime") or ""
        result["lastTime"] = last
        result["continueDays"] = summary.get("continueDays")
        result["userId"] = str(summary.get("userId") or result["userId"])

    r_info = client.request_retry(
        "GET",
        H5_SIGNIN_INFO,
        token,
        {"month": f"{int(today[:4])}-{int(today[5:7])}"},
    )
    if is_ok(r_info["json"]):
        info = r_info["json"].get("data") or {}
        try:
            result["integral"] = int(info["integral"]) if info.get("integral") not in (None, "") else None
        except (TypeError, ValueError):
            result["integral"] = info.get("integral")

    r_total = client.request_retry("GET", "/cfmotoservermine/integral/totalIntegral", token)
    if is_ok(r_total["json"]):
        total = r_total["json"].get("data") or {}
        raw_total = total.get("integralTotal")
        try:
            result["totalIntegral"] = int(raw_total) if raw_total not in (None, "") else None
        except (TypeError, ValueError):
            result["totalIntegral"] = raw_total

    if is_ok(r2["json"]):
        last = result["lastTime"] or ""
        if str(last).startswith(today):
            result["ok"] = True
            result["dup"] = True
            result["signedToday"] = True
            result["msg"] = f"今日已签到（连续 {result['continueDays']} 天）"
            if status_only or not force:
                return result

    if status_only:
        result["msg"] = result["msg"] or "今日未签到"
        return result

    r3 = client.request_retry("POST", H5_SIGNIN, token)
    result["posted"] = True
    post_code = ""
    post_msg = ""
    if isinstance(r3["json"], dict):
        post_code = str(r3["json"].get("code", ""))
        post_msg = str(r3["json"].get("message") or r3["json"].get("msg") or "")
    if r3["json"] is None:
        result["msg"] = f"HTTP {r3['status']} 返回非 JSON"
        return result

    r4 = client.request_retry("GET", H5_SIGNIN, token)
    last2 = ""
    if is_ok(r4["json"]):
        summary = r4["json"].get("data") or {}
        last2 = str(summary.get("lastTime") or "")
        result["lastTime"] = last2
        result["continueDays"] = summary.get("continueDays")
    if last2.startswith(today):
        result["ok"] = True
        result["signedToday"] = True
        if post_code in OK_CODES or post_code == "":
            result["dup"] = False
            result["msg"] = f"签到成功（连续 {result['continueDays']} 天）"
        else:
            result["dup"] = True
            result["msg"] = f"今日已签到（连续 {result['continueDays']} 天）"
        return result

    result["ok"] = False
    result["msg"] = "签到未生效：" + (post_msg or "未知") + (f" (code {post_code})" if post_code else "")
    return result


def summarize(accounts: list[dict[str, Any]]) -> tuple[str, bool]:
    total = len(accounts)
    ok_count = sum(1 for a in accounts if a.get("ok"))
    all_dup = ok_count > 0 and all(a.get("dup") for a in accounts if a.get("ok"))
    if any(a.get("tokenInvalid") for a in accounts) and ok_count == 0:
        return "Token 失效", False
    if ok_count == 0:
        return f"签到失败 (0/{total})", False
    if all_dup:
        return f"今日已签到 ({ok_count}/{total})", True
    if ok_count == total:
        return f"签到成功 ({ok_count}/{total})", True
    return f"部分成功 ({ok_count}/{total})", True


def run(force: bool, status_only: bool) -> int:
    cfg = load_config()
    today = datetime.now().strftime("%Y-%m-%d")
    tokens = load_tokens(cfg)
    log(f"==== 开始签到 today={today} force={force} status_only={status_only} accounts={len(tokens)} ====")
    if not tokens:
        write_widget_status(
            {
                "ok": False,
                "title": "未配置 Token",
                "message": "请在 config/local.json 填写 token",
                "error": "未配置 Token",
                "signedToday": False,
                "tokenInvalid": True,
                "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            }
        )
        log("未配置 Token")
        return 1

    client = Client(cfg)
    client.warmup()
    accounts = [run_one(client, tk, i, today, status_only, force) for i, tk in enumerate(tokens)]
    for acc in accounts:
        log(f"{acc['tag']} → {'成功' if acc['ok'] else '失败'} {acc['msg']}")

    title, overall_ok = summarize(accounts)
    primary = accounts[0]
    if primary.get("phone"):
        cfg = load_config()
        if cfg.get("phone") != primary["phone"]:
            cfg["phone"] = primary["phone"]
            CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    vehicle = None
    if not primary.get("tokenInvalid"):
        vehicle = fetch_vehicle(client, tokens[0])
    payload = {
        "ok": overall_ok,
        "title": title,
        "message": "\n".join(f"{a['tag']}: {a['msg']}" for a in accounts),
        "error": None if overall_ok else primary.get("msg"),
        "today": today,
        "userId": primary.get("userId") or "",
        "phone": primary.get("phone") or load_config().get("phone") or "",
        "nickName": primary.get("nickName") or "",
        "avatar": primary.get("avatar") or "",
        "signedToday": bool(primary.get("signedToday")),
        "lastTime": primary.get("lastTime"),
        "continueDays": primary.get("continueDays"),
        "integral": primary.get("totalIntegral"),
        "totalIntegral": primary.get("totalIntegral"),
        "signinIntegral": primary.get("integral"),
        "tokenInvalid": bool(primary.get("tokenInvalid")),
        "posted": bool(primary.get("posted")),
        "vehicle": vehicle,
        "accounts": accounts,
        "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }
    (LOG_DIR / "last.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    write_widget_status(payload)
    log("==== 结束 ====")
    return 0 if overall_ok or status_only else 1


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--force", action="store_true")
    p.add_argument("--status-only", action="store_true")
    p.add_argument("--set-token", metavar="TOKEN", help="写入新 Token 并立刻查询状态")
    args = p.parse_args()
    if args.set_token is not None:
        save_token(args.set_token)
        return emit_result(True, "Token 已保存")
    return run(args.force, args.status_only)


if __name__ == "__main__":
    sys.exit(main())
