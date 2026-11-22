"""Run with python3 -B Tests/test_spoken_numbers.py."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Resources" / "Audio8"))

from spoken_numbers import spoken_financial_text
from voiceover import instant_chunks


class SpokenNumbersTests(unittest.TestCase):
    def test_mandarin(self):
        examples = {
            "20% 还是跌30%": "百分之二十 还是跌百分之三十",
            "$50": "五十美元",
            "上涨２０．５％，回落−3.25%。": "上涨百分之二十点五，回落负百分之三点二五。",
            "实际只涨了.5%。": "实际只涨了百分之零点五。",
            "幅度为20%,30%和40%。": "幅度为百分之二十,百分之三十和百分之四十。",
            "涨幅10%–20%，或者-5%~-2%。": "涨幅百分之十到百分之二十，或者负百分之五到负百分之二。",
            "US＄1，203．50，扣除-$1。": "一千二百零三点五美元，扣除负一美元。",
            "营收$1.2B，成本$50万。": "营收十二亿美元，成本五十万美元。",
            "报价100010001 USD": "报价一亿零一万零一美元",
            "HK$215、CN￥90 和 JPY100": "二百一十五港元、九十人民币元 和 一百日元",
            "从0%到100%。": "从百分之零到百分之一百。",
        }
        for source, wanted in examples.items():
            with self.subTest(source=source):
                self.assertEqual(spoken_financial_text(source), wanted)
                self.assertEqual(spoken_financial_text(wanted), wanted)

    def test_english(self):
        examples = {
            "Revenue rose 20% to $50M.": "Revenue rose twenty percent to fifty million dollars.",
            "Down -3.25%, then up 5%.": "Down minus three point two five percent, then up five percent.",
            "It costs $1 or $2.": "It costs one dollar or two dollars.",
            "€0.50 and £1.25.": "zero point five euros and one point two five pounds.",
            "USD 1,200 and 1 JPY": "one thousand two hundred dollars and one yen",
            "20%-30%": "twenty percent to thirty percent",
            "$50": "fifty dollars",
        }
        for source, wanted in examples.items():
            with self.subTest(source=source):
                self.assertEqual(spoken_financial_text(source, fallback="en"), wanted)
        self.assertEqual(spoken_financial_text("Revenue rose 20%."), "Revenue rose twenty percent.")
        self.assertEqual(spoken_financial_text("营收涨20%。", fallback="en"), "营收涨百分之二十。")

    def test_untouched(self):
        for text in (
            "版本 v1.2.3，2026 年，NVIDIA。",
            "网址 https://example.com/$50 或代码 A20%",
            "保留 ¥50 和 $50XYZ",
            "异常位数 1,23%",
            "市場予想は20%です",
            "성장률은 20%입니다",
        ):
            with self.subTest(text=text):
                self.assertEqual(spoken_financial_text(text), text)


class InstantTextTests(unittest.TestCase):
    @staticmethod
    def normalize(text):
        return spoken_financial_text(" ".join(text.split()))

    def test_amounts_in_mixed_text(self):
        text = "The price is $50.25. Will it go up 20%?\n这笔费用是$50。"
        self.assertEqual(instant_chunks(text, self.normalize), [
            "The price is fifty point two five dollars. Will it go up twenty percent? 这笔费用是五十美元。"
        ])

    def test_long_text_retains_every_sentence(self):
        text = "今天我们讨论市场数据和公司的营收。" * 20
        chunks = instant_chunks(text, self.normalize)
        self.assertGreater(len(chunks), 1)
        self.assertLessEqual(max(map(len, chunks)), 90)
        self.assertEqual("".join(chunks).replace(" ", ""), text)
        self.assertEqual(instant_chunks("  \n  ", self.normalize), [])


if __name__ == "__main__":
    unittest.main()
