#!/usr/bin/env python3
"""Score the Romajime conversion engine against the prompt-history corpus.

Pipeline per sentence:
  original Japanese --(romajime-cli --reverse)--> typed romaji + expected kana
  typed romaji --(romajime-cli --kana-only)--> engine kana
  compare normalized(engine kana) vs normalized(expected kana)

Outputs a summary (exact-match rate, character error rate), appends it to
eval/history.jsonl, and writes the worst failures to eval/failures.tsv.

usage: run_eval.py [--cli PATH] [--limit N] [--kanji N]
"""

import argparse
import datetime
import json
import random
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

EVAL_DIR = Path(__file__).parent
CORPUS = EVAL_DIR / "corpus_ja.txt"
CACHE = EVAL_DIR / "corpus.tsv"
HISTORY = EVAL_DIR / "history.jsonl"
FAILURES = EVAL_DIR / "failures.tsv"
DEFAULT_CLI = EVAL_DIR.parent / "DerivedData/Build/Products/Debug/romajime-cli"


def run_cli(cli, args, text):
    result = subprocess.run(
        [str(cli), *args], input=text, capture_output=True, text=True, timeout=120
    )
    if result.returncode != 0:
        raise RuntimeError(f"romajime-cli failed: {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def normalize(text):
    """Comparison key: NFKC, katakana->hiragana, no spaces/punctuation."""
    text = unicodedata.normalize("NFKC", text)
    folded = []
    for ch in text:
        code = ord(ch)
        if 0x30A1 <= code <= 0x30F6:  # katakana -> hiragana
            ch = chr(code - 0x60)
        folded.append(ch)
    text = "".join(folded)
    return re.sub(r"[\s。、.,!?!?ー・「」()()\[\]:;:;]", "", text)


def edit_distance(a, b):
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def build_cases(cli, limit):
    """Reverse-transliterate the corpus, cached in corpus.tsv."""
    sentences = [s for s in CORPUS.read_text(encoding="utf-8").splitlines() if s.strip()]
    if limit:
        sentences = sentences[:limit]

    cached = {}
    if CACHE.exists():
        for line in CACHE.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                cached[parts[2]] = (parts[0], parts[1])

    cases = []
    new = 0
    for original in sentences:
        if original in cached:
            romaji, kana = cached[original]
        else:
            payload = json.loads(run_cli(cli, ["--reverse", "--json"], original))
            romaji, kana = payload["romaji"], payload["kana"]
            cached[original] = (romaji, kana)
            new += 1
        if romaji.strip():
            cases.append({"original": original, "romaji": romaji, "kana": kana})
    with CACHE.open("w", encoding="utf-8") as f:
        for original, (romaji, kana) in cached.items():
            f.write(f"{romaji}\t{kana}\t{original}\n")
    if new:
        print(f"reverse-transliterated {new} new sentences", file=sys.stderr)
    return cases


def eval_kana(cli, cases):
    # One CLI call per case keeps newlines unambiguous; batch via single
    # process would be faster but corpus sizes here are small.
    results = []
    for case in cases:
        got = run_cli(cli, ["--kana-only", "--no-memory"], case["romaji"])
        expected_n, got_n = normalize(case["kana"]), normalize(got)
        distance = edit_distance(expected_n, got_n)
        cer = distance / max(1, len(expected_n))
        results.append({**case, "got": got, "exact": expected_n == got_n, "cer": cer})
    return results


def eval_kanji(cli, cases, sample, timeout=15):
    picked = random.Random(0).sample(cases, min(sample, len(cases)))
    scores = []
    for case in picked:
        try:
            got = run_cli(cli, ["--no-memory", "--timeout", str(timeout)], case["romaji"])
        except (RuntimeError, subprocess.TimeoutExpired):
            continue
        expected_n, got_n = normalize(case["original"]), normalize(got)
        scores.append(edit_distance(expected_n, got_n) / max(1, len(expected_n)))
    return scores


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--limit", type=int, default=0, help="cap corpus size")
    parser.add_argument("--kanji", type=int, default=0, help="also LLM-convert N random samples")
    args = parser.parse_args()

    if not CORPUS.exists():
        sys.exit("eval/corpus_ja.txt not found — run `just eval-collect` first")

    cases = build_cases(args.cli, args.limit)
    results = eval_kana(args.cli, cases)

    exact = sum(r["exact"] for r in results)
    mean_cer = sum(r["cer"] for r in results) / max(1, len(results))
    summary = {
        "timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
        "cases": len(results),
        "kana_exact_rate": round(exact / max(1, len(results)), 4),
        "kana_mean_cer": round(mean_cer, 4),
    }

    if args.kanji:
        scores = eval_kanji(args.cli, cases, args.kanji)
        if scores:
            summary["kanji_samples"] = len(scores)
            summary["kanji_mean_cer"] = round(sum(scores) / len(scores), 4)

    failures = sorted((r for r in results if not r["exact"]), key=lambda r: -r["cer"])
    with FAILURES.open("w", encoding="utf-8") as f:
        f.write("cer\tromaji\texpected_kana\tgot\toriginal\n")
        for r in failures:
            f.write(
                "\t".join(
                    [f"{r['cer']:.3f}"]
                    + [v.replace("\t", " ").replace("\n", "\\n") for v in (r["romaji"], r["kana"], r["got"], r["original"])]
                )
                + "\n"
            )

    with HISTORY.open("a", encoding="utf-8") as f:
        f.write(json.dumps(summary, ensure_ascii=False) + "\n")

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\nfailures: {len(failures)} -> {FAILURES}", file=sys.stderr)


if __name__ == "__main__":
    main()
