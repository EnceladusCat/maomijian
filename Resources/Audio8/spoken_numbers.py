"""Expand financial notation for Audio8 before tokenization."""

import re

_DIGITS = "0123456789０１２３４５６７８９"
_SIGNS = r"+\-＋－−"
_INTEGER = rf"(?:[{_DIGITS}]{{1,3}}(?:[,，][{_DIGITS}]{{3}})+|[{_DIGITS}]+)"
_FRACTION = rf"[.．][{_DIGITS}]+"
_NUMBER = rf"(?:[{_SIGNS}]\s*)?(?:{_INTEGER}(?:{_FRACTION})?|{_FRACTION})"
_PERCENT = r"\s*[%％]"
_CURRENCY = r"US[$＄]|USD|HK[$＄]|HKD|CN[¥￥]|CNY|RMB|JP[¥￥]|JPY|EUR|GBP|[$＄€£]"
# A number next to a percent sign or a known currency is safe to read aloud.
# Keep version strings, identifiers and unfinished currency notation intact.
_LEFT = rf"(?<![A-Za-z_{_DIGITS}.．{_SIGNS}])(?<![{_DIGITS}][,，])"
_RIGHT = rf"(?![A-Za-z_{_DIGITS}]|[.．,，][{_DIGITS}])"
_FINANCE = re.compile(
    rf"(?P<url>https?://[^\s，。；！？]+)|"
    rf"{_LEFT}(?P<range_start>{_NUMBER}){_PERCENT}\s*[-–—~～]\s*"
    rf"(?P<range_end>{_NUMBER}){_PERCENT}|"
    rf"{_LEFT}(?P<percent>{_NUMBER}){_PERCENT}|"
    rf"{_LEFT}(?P<sign>[{_SIGNS}]\s*)?(?P<prefix>{_CURRENCY})\s*"
    rf"(?P<amount>{_NUMBER})(?P<scale>[KMBT]|万亿|亿|万)?{_RIGHT}|"
    rf"{_LEFT}(?P<quantity>{_NUMBER})\s*(?P<suffix>USD|HKD|CNY|RMB|JPY|EUR|GBP){_RIGHT}",
    re.IGNORECASE,
)
_HAN = re.compile(r"[㐀-鿿\U00020000-\U000323AF]")
_OTHER_CJK = re.compile(r"[ぁ-ヿ가-힣]")
_FOLD = str.maketrans("０１２３４５６７８９．，＋－−＄￥", "0123456789.,+--$¥")
_ZH_DIGITS = "零一二三四五六七八九"
_EN_SMALL = (
    "zero one two three four five six seven eight nine ten eleven twelve thirteen "
    "fourteen fifteen sixteen seventeen eighteen nineteen"
).split()
_EN_TENS = "zero ten twenty thirty forty fifty sixty seventy eighty ninety".split()
_SCALE = {"K": 3, "M": 6, "B": 9, "T": 12, "万": 4, "亿": 8, "万亿": 12}
_CURRENCIES = {
    "USD": ("美元", "dollar", "dollars"),
    "HKD": ("港元", "Hong Kong dollar", "Hong Kong dollars"),
    "CNY": ("人民币元", "yuan", "yuan"),
    "JPY": ("日元", "yen", "yen"),
    "EUR": ("欧元", "euro", "euros"),
    "GBP": ("英镑", "pound", "pounds"),
}
_CURRENCY_CODES = {
    "$": "USD", "US$": "USD", "HK$": "HKD", "CN¥": "CNY", "RMB": "CNY",
    "JP¥": "JPY", "€": "EUR", "£": "GBP",
}


def _chinese_integer(value):
    if not value:
        return "零"
    groups = []
    for unit in ("", "万", "亿", "万亿"):
        value, group = divmod(value, 10000)
        groups.append((group, unit))
        if not value:
            break

    pieces = []
    gap = False
    for group, unit in reversed(groups):
        if not group:
            gap = bool(pieces)
            continue
        if gap or (pieces and group < 1000):
            pieces.append("零")
        gap = False
        for divisor, place in ((1000, "千"), (100, "百"), (10, "十"), (1, "")):
            digit, group = divmod(group, divisor)
            if digit:
                if gap:
                    pieces.append("零")
                pieces.append(_ZH_DIGITS[digit] + place)
                gap = False
            elif group and pieces and pieces[-1] != "零":
                gap = True
        pieces.append(unit)
    spoken = "".join(pieces)
    return spoken[1:] if spoken.startswith("一十") else spoken


def _english_integer(value):
    if value < 20:
        return _EN_SMALL[value]
    if value < 100:
        tens, units = divmod(value, 10)
        return _EN_TENS[tens] + ("-" + _EN_SMALL[units] if units else "")
    for size, unit in ((10**15, "quadrillion"), (10**12, "trillion"), (10**9, "billion"),
                       (10**6, "million"), (1000, "thousand"), (100, "hundred")):
        if value >= size:
            count, rest = divmod(value, size)
            words = f"{_english_integer(count)} {unit}"
            return words + (" " + _english_integer(rest) if rest else "")


def _number(value, chinese, shift=0):
    canonical = "".join(value.translate(_FOLD).split()).replace(",", "")
    sign = canonical[0] if canonical.startswith(("-", "+")) else ""
    whole, _, fraction = canonical[len(sign):].partition(".")
    if shift:
        moved = fraction.ljust(shift, "0")
        whole += moved[:shift]
        fraction = moved[shift:]
    whole = whole.lstrip("0") or "0"
    fraction = fraction.rstrip("0")
    if len(whole) > 16 or len(fraction) > 16:
        return None
    integer = int(whole)
    if chinese:
        spoken = _chinese_integer(integer)
        if fraction:
            spoken += "点" + "".join(_ZH_DIGITS[int(digit)] for digit in fraction)
        return ("负" if sign == "-" else "正" if sign == "+" else "") + spoken, integer == 1 and not fraction
    spoken = _english_integer(integer)
    if fraction:
        spoken += " point " + " ".join(_EN_SMALL[int(digit)] for digit in fraction)
    return ("minus " if sign == "-" else "plus " if sign == "+" else "") + spoken, integer == 1 and not fraction


def spoken_financial_text(text, fallback="zh"):
    if _OTHER_CJK.search(text):
        return text
    context = _FINANCE.sub("", text)
    chinese = bool(_HAN.search(context)) or (
        not re.search(r"[A-Za-z]", context) and fallback == "zh"
    )

    def percent(value):
        number = _number(value, chinese)
        if number is None:
            return None
        spoken, _ = number
        if chinese:
            if spoken.startswith(("正", "负")):
                return spoken[0] + "百分之" + spoken[1:]
            return "百分之" + spoken
        return spoken + " percent"

    def replace(match):
        if match["url"]:
            return match[0]
        if match["range_start"]:
            start, end = percent(match["range_start"]), percent(match["range_end"])
            return (("到" if chinese else " to ").join((start, end))
                    if start is not None and end is not None else match[0])
        if match["percent"]:
            return percent(match["percent"]) or match[0]

        value = match["amount"] or match["quantity"]
        if match["sign"]:
            if value[0] in "+-＋－−":
                return match[0]
            value = match["sign"] + value
        tag = (match["prefix"] or match["suffix"]).upper().translate(_FOLD)
        local, singular, plural = _CURRENCIES[_CURRENCY_CODES.get(tag, tag)]
        scale = _SCALE.get((match["scale"] or "").upper(), 0)
        number = _number(value, chinese, scale)
        if number is None:
            return match[0]
        spoken, is_one = number
        return spoken + local if chinese else spoken + " " + (singular if is_one else plural)

    return _FINANCE.sub(replace, text)
